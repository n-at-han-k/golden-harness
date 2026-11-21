#!/usr/bin/env python3
"""Group methods into classes and apply Ruby naming. Self-contained.

Two jobs that ast-grep cannot do.

GROUPING. discovery.cpp defines 20 methods as `void ProcessDirectoryJob::foo()`
at namespace scope, all belonging to ONE class. ast-grep rewriters cannot group
across sibling matches -- each is rewritten independently -- so emitting the
wrapper per method gives one `class X ... end` per method. transform.yml tags
each def with `# @class <Scope>` and this collects them under one wrapper.

NAMING. The golden renames nearly every identifier, and none of the targets are
valid C++, so none of it can run as a C++ -> C++ rule:

    _currentFolder          -> @current_folder
    _currentFolder._server  -> @current_folder.server
    startAsyncServerQuery   -> start_async_server_query
    NormalQuery             -> :normal_query
    isHidden()              -> hidden?
    a->b                    -> a.b
    QTimer::singleShot      -> QTimer.singleShot
"""
from __future__ import annotations

import pathlib
import re
import sys

CLASS_TAG = re.compile(r"^(\s*)# @class (\S+)\s*$")

# Misspellings in discovery.cpp that the golden spells correctly. Listed so
# the correction is a declared decision rather than an invisible one.
SOURCE_TYPOS = {
    "_qVueryServer": "_queryServer",
    "qVueryServer": "queryServer",
    "_shouldDiscoverLocaly": "_shouldDiscoverLocally",
    "shouldDiscoverLocaly": "shouldDiscoverLocally",
}

# PascalCase class names only. Methods are NOT listed here: every camelCase
# method snake_cases, including Qt's -- `QTimer::singleShot` becomes
# `QTimer.single_shot`. Keeping a method name here was a violation of the rule.
KEEP = {
    "QTimer", "QFile", "QFileInfo", "QString", "QByteArray", "QUrl", "QObject",
    "QDateTime", "QVariant", "QStringList", "QJsonObject", "QThreadPool",
    "QLatin1Char", "QLatin1String", "QStringLiteral", "QByteArrayLiteral",
    "QHash", "QMap", "QSet", "QVector", "QList", "QDebug", "QDir", "QUuid",
    "Struct", "Hash", "Array", "String", "Integer", "Float", "Log", "Entry",
    "true", "false", "nil", "self", "new",
}

# No is/has -> `?` conversion. The golden keeps the prefix on both sides:
#   is_hidden = e.local_entry&.is_hidden
# An earlier version converted them and produced `hidden? = ...`, which is a
# syntax error, since a `?` cannot appear in a Ruby local variable name.
# `?` is added only through METHOD_MAP, for the query methods whose Ruby
# spelling carries one.

# Qt/STL method names with a direct Ruby equivalent. The golden shows
# `filename.start_with?('.')` for what C++ writes as a QLatin1Char comparison.

def snake(name: str) -> str:
    if "_" in name and not re.search(r"[a-z][A-Z]", name):
        return name if not name.isupper() else name.lower()
    out = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name)
    out = re.sub(r"(?<=[A-Z])([A-Z][a-z])", r"_\1", out)
    return out.lower()


def rename(name: str) -> str:
    """Plain snake_case. No predicate `?`, no Qt-to-Ruby method mapping.

    The golden keeps the C++ names: `is_hidden`, `is_directory`, `is_valid`,
    `is_sym_link`, `starts_with`. Exactly one `?` appears in the whole golden,
    against a dozen `is_*` names that keep their prefix, so a predicate rule
    would be wrong far more often than right.

    It also cannot be applied safely: a `?` is legal in a Ruby method name but
    not in a local variable or a parameter, so an `isHidden` local became
    `hidden? = ...` and the file stopped parsing. A Qt method map was removed
    for a related reason -- `at -> []` rewrote the licence text
    "(at your option)" into "([] your option)".
    """
    return name if name in KEEP else snake(name)


def apply_log_categories(text: str, categories: dict[str, str]) -> str:
    """`Log.info(lcDisco)` -> `Log.info("sync.discovery")`.

    All that is left of the old fold_log_streams. The `<<` chain itself is now
    folded by transform.yml's s-log rewriter, structurally, over the
    binary_expression tree -- the text regex that used to do it was bounded to
    one line and silently left a wrapped chain as raw C++.

    What remains here is not a code transformation but a LOOKUP: the category
    identifier is declared once per file by Q_LOGGING_CATEGORY, so resolving it
    needs the whole file, and the value is a plain substitution.
    """
    for ident, name in categories.items():
        text = re.sub(r"(Log\.\w+)\(" + re.escape(ident) + r"\)",
                      lambda m: f'{m.group(1)}("{name}")', text)
    return text


def log_categories(text: str) -> dict[str, str]:
    """lcDisco -> "sync.discovery", from the Q_LOGGING_CATEGORY declaration."""
    out = {}
    for m in re.finditer(r'q_logging_category\("([^,]+),\s*\\?"([^"\\]+)\\?"', text):
        out[m.group(1).strip()] = m.group(2)
    for m in re.finditer(r'Q_LOGGING_CATEGORY\(\s*(\w+)\s*,\s*"([^"]+)"', text):
        out[m.group(1)] = m.group(2)
    return out


def apply_naming(text: str) -> str:
    # Comments are protected from the naming pass entirely. It is textual, so
    # without this the licence header gets snake_cased and method-mapped --
    # observed as "(at your option)" turning into "([] your option)".
    shelf: list[str] = []

    def shelve(m: re.Match) -> str:
        shelf.append(m.group(0))
        return f"\x00C{len(shelf) - 1}\x00"

    text = re.sub(r"(?m)^\s*#.*$", shelve, text)

    for wrong, right in SOURCE_TYPOS.items():
        text = re.sub(r"\b" + re.escape(wrong) + r"\b", right, text)

    # Log streams first: the fold needs the original call and operand names,
    # before snake_casing rewrites them.
    text = apply_log_categories(text, log_categories(text))

    # Drop the carrier declarations prepare.py left for the Qt macros.
    text = re.sub(r"^.*__qt_macro_\d+__\(\).*$\n?", "", text, flags=re.M)

    # `a->b` is `a.b` in Ruby. Done before the member rule, so the arrow does
    # not survive next to an @-prefixed name.
    text = text.replace("->", ".")

    # `NormalQuery` as a bare PascalCase operand of a comparison is an enum
    # value; the golden writes those as symbols.
    text = re.sub(r"(==|!=)\s+([A-Z][a-zA-Z0-9]*)\b",
                  lambda m: f"{m.group(1)} :{snake(m.group(2))}"
                  if m.group(2) not in KEEP else m.group(0), text)
    text = re.sub(r"=\s+([A-Z][a-z][a-zA-Z0-9]*)\s*$",
                  lambda m: f"= :{snake(m.group(1))}"
                  if m.group(1) not in KEEP else m.group(0), text, flags=re.M)

    # Members: `_currentFolder` -> `@current_folder`.
    text = re.sub(r"(?<![\w.@])_([A-Za-z]\w*)",
                  lambda m: "@" + snake(m.group(1)), text)

    # Field access drops the underscore: `@current_folder.server`.
    text = re.sub(r"\.@?_?([A-Za-z]\w*)",
                  lambda m: "." + rename(m.group(1)), text)

    # `QTimer::singleShot` -> `QTimer.singleShot`.
    text = re.sub(r"\b([A-Z]\w*)::([a-z]\w*)", r"\1.\2", text)

    # Parameter lists first, and WITHOUT the predicate rule: `is_directory` is
    # a legal parameter name but `directory?` is not -- a `?` cannot appear in a
    # Ruby parameter. The golden passes `is_hidden` as an argument, confirming
    # the plain snake_case form.
    def params(m: re.Match) -> str:
        names = [snake(a.strip()) if a.strip() not in KEEP else a.strip()
                 for a in m.group(2).split(",") if a.strip()]
        return m.group(1) + "(" + ", ".join(names) + ")"
    text = re.sub(r"^(\s*def [a-z_][a-zA-Z0-9_?!]*)\(([^)]*)\)",
                  params, text, flags=re.M)

    # Remaining camelCase identifiers. The lookahead includes `,` and `)` so
    # arguments inside a call are renamed too, not just the callee.
    text = re.sub(r"\b[a-z][a-zA-Z0-9]*(?=\s*[(.,)\s])",
                  lambda m: rename(m.group(0)), text)

    # A continuation line must not BEGIN with a binary operator. C++ wraps
    # long conditions that way:
    #     !a.should_discover_locally(x)
    #     && (y == z || !a.should_discover_locally(w))
    # but Ruby ends the statement at the first complete expression, so the
    # second line is `Lint/Syntax: unexpected token &&`. That made the whole
    # file unparseable for rubocop -- which means NO cop ran on it at all, and
    # every layout cop looked like it was being ignored. The operator moves to
    # the end of the preceding line.
    text = re.sub(r"\n[ \t]*(&&|\|\||\+|-|\*|/|==|!=|<=|>=|<|>|\.)(?=[ \t])",
                  lambda m: " " + m.group(1), text)

    # Ruby has no statement terminator. A handful of semicolons survive where
    # the `;` is a SIBLING of the rewritten node rather than part of it -- after
    # a struct_specifier, for example -- so no rewriter can consume it.
    text = re.sub(r";\s*$", "", text, flags=re.M)

    # Restore the shelved comments untouched.
    text = re.sub(r"\x00C(\d+)\x00", lambda m: shelf[int(m.group(1))], text)

    # Ruby omits parens on a zero-argument call, and so does the golden:
    # `start_async_server_query`, not `start_async_server_query()`. Applied to
    # EVERY zero-arg call and definition, PascalCase included -- `QChar()` and
    # `Q_UNREACHABLE()` were the only holdouts when this was restricted to
    # lowercase names.
    text = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*[?!]?)\(\)", r"\1", text)

    return text


def group_classes(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    groups: dict[str, list[list[str]]] = {}
    order: list[str] = []
    insert_at: int | None = None
    i = 0
    while i < len(lines):
        m = CLASS_TAG.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        cls = m.group(2)
        if cls not in groups:
            groups[cls] = []
            order.append(cls)
            if insert_at is None:
                insert_at = len(out)
        i += 1
        block, depth, started = [], 0, False
        while i < len(lines):
            line, stripped = lines[i], lines[i].strip()
            if re.match(r"^def\b", stripped):
                depth += 1
                started = True
            elif stripped == "end" and started:
                depth -= 1
                block.append(line)
                i += 1
                if depth == 0:
                    break
                continue
            elif re.match(r"^(if|unless|while|until|case|begin|loop)\b", stripped) \
                    or stripped.endswith(" do") or re.search(r"\bdo \|", stripped):
                depth += 1
            block.append(line)
            i += 1
        groups[cls].append(block)
    if insert_at is None:
        return text
    rendered: list[str] = []
    for cls in order:
        rendered.append(f"class {cls}")
        for block in groups[cls]:
            rendered.extend(block)
            rendered.append("")
        rendered.append("end")
    return "\n".join(out[:insert_at] + rendered + out[insert_at:])


SHEBANG = "#!/usr/bin/env ruby"


def main() -> int:
    src, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    n = 0
    for path in sorted(src.rglob("*")):
        if path.suffix not in (".h", ".hpp", ".cpp", ".cc", ".cxx"):
            continue
        rel = path.relative_to(src)
        target = dest / rel.with_suffix(rel.suffix + ".rb")
        target.parent.mkdir(parents=True, exist_ok=True)
        text = path.read_text(encoding="utf-8", errors="replace")
        text = apply_naming(text)
        text = group_classes(text)
        if not text.startswith(SHEBANG):
            text = SHEBANG + "\n" + text
        target.write_text(text, encoding="utf-8")
        n += 1
    print(f"rubyified {n} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
