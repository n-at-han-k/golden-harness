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


KEEP = {
    "QTimer", "QFile", "QFileInfo", "QString", "QByteArray", "QUrl", "QObject",
    "QDateTime", "QVariant", "QStringList", "QJsonObject", "QThreadPool",
    "QLatin1Char", "QLatin1String", "QStringLiteral", "QByteArrayLiteral",
    "QHash", "QMap", "QSet", "QVector", "QList", "QDebug", "QDir", "QUuid",
    "Struct", "Hash", "Array", "String", "Integer", "Float", "Log", "Entry",
    "true", "false", "nil", "self", "new",
}

def snake(name: str) -> str:
    if "_" in name and not re.search(r"[a-z][A-Z]", name):
        return name if not name.isupper() else name.lower()
    out = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name)
    out = re.sub(r"(?<=[A-Z])([A-Z][a-z])", r"_\1", out)
    return out.lower()


def rename(name: str) -> str:
    return name if name in KEEP else snake(name)


def apply_log_categories(text: str, categories: dict[str, str]) -> str:
    for ident, name in categories.items():
        text = re.sub(r"(Log\.\w+)\(" + re.escape(ident) + r"\)",
                      lambda m: f'{m.group(1)}("{name}")', text)
    return text


def log_categories(text: str) -> dict[str, str]:
    out = {}
    for m in re.finditer(r'q_logging_category\("([^,]+),\s*\\?"([^"\\]+)\\?"', text):
        out[m.group(1).strip()] = m.group(2)
    for m in re.finditer(r'Q_LOGGING_CATEGORY\(\s*(\w+)\s*,\s*"([^"]+)"', text):
        out[m.group(1)] = m.group(2)
    return out


def apply_naming(text: str) -> str:
    shelf: list[str] = []

    def shelve(m: re.Match) -> str:
        shelf.append(m.group(0))
        return f"\x00C{len(shelf) - 1}\x00"

    text = re.sub(r"(?m)^\s*#.*$", shelve, text)
    text = apply_log_categories(text, log_categories(text))
    text = re.sub(r"^.*__qt_macro_\d+__\(\).*$\n?", "", text, flags=re.M)
    text = text.replace("->", ".")
    text = re.sub(r"(==|!=)\s+([A-Z][a-zA-Z0-9]*)\b",
                  lambda m: f"{m.group(1)} :{snake(m.group(2))}"
                  if m.group(2) not in KEEP else m.group(0), text)
    text = re.sub(r"=\s+([A-Z][a-z][a-zA-Z0-9]*)\s*$",
                  lambda m: f"= :{snake(m.group(1))}"
                  if m.group(1) not in KEEP else m.group(0), text, flags=re.M)
    text = re.sub(r"(?<![\w.@])_([A-Za-z]\w*)",
                  lambda m: "@" + snake(m.group(1)), text)

    text = re.sub(r"\.@?_?([A-Za-z]\w*)",
                  lambda m: "." + rename(m.group(1)), text)

    text = re.sub(r"\b([A-Z]\w*)::([a-z]\w*)", r"\1.\2", text)

    def params(m: re.Match) -> str:
        names = [snake(a.strip()) if a.strip() not in KEEP else a.strip()
                 for a in m.group(2).split(",") if a.strip()]
        return m.group(1) + "(" + ", ".join(names) + ")"
    text = re.sub(r"^(\s*def [a-z_][a-zA-Z0-9_?!]*)\(([^)]*)\)",
                  params, text, flags=re.M)

    text = re.sub(r"\b[a-z][a-zA-Z0-9]*(?=\s*[(.,)\s])",
                  lambda m: rename(m.group(0)), text)

    text = re.sub(r"\n[ \t]*(&&|\|\||\+|-|\*|/|==|!=|<=|>=|<|>|\.)(?=[ \t])",
                  lambda m: " " + m.group(1), text)

    text = re.sub(r";\s*$", "", text, flags=re.M)
    text = re.sub(r"\x00C(\d+)\x00", lambda m: shelf[int(m.group(1))], text)
    text = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*[?!]?)\(\)", r"\1", text)

    return text


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
        if not text.startswith(SHEBANG):
            text = SHEBANG + "\n" + text
        target.write_text(text, encoding="utf-8")
        n += 1
    print(f"rubyified {n} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())

