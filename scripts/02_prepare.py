#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys

SECTION = re.compile(
    r'^(?P<indent>[ \t]*)'
    r'(?:(?P<access>public|private|protected)\s+)?'
    r'(?P<kind>Q_SIGNALS|signals|Q_SLOTS|slots)\s*:\s*$')
ACCESS = re.compile(r'^(?P<indent>[ \t]*)(?P<access>public|private|protected)\s*:\s*$')
MEMBER = re.compile(r'^[ \t]*(?![/*#}])[A-Za-z_~\[].*[;{]\s*$')

EXPORT_IN_CLASS = re.compile(
    r'\b(class|struct)\s+(?:OPENCLOUD_[A-Z_]*EXPORT|[A-Z][A-Z0-9_]*_EXPORT)\s+')
EXPORT_BARE = re.compile(r'\b(?:OPENCLOUD_[A-Z_]*EXPORT|[A-Z][A-Z0-9_]*_EXPORT)\s*')
QOBJECT_HOIST = re.compile(
    r'(?P<head>\b(?:class|struct)\s+)(?P<rest>[^{;]*\{\s*)'
    r'(?P<macro>Q_OBJECT|Q_GADGET)\b[ \t]*;?[ \t]*\n')

CARRIER = re.compile(
    r'^(?P<indent>[ \t]*)(?P<macro>Q_LOGGING_CATEGORY|Q_DECLARE_LOGGING_CATEGORY'
    r'|Q_ENUM|Q_ENUMS|Q_FLAG|Q_FLAGS|Q_DECLARE_METATYPE|Q_DECLARE_FLAGS'
    r'|Q_INTERFACES|Q_DECLARE_PRIVATE|Q_DISABLE_COPY)\s*\((?P<args>.*)\)\s*;?\s*$')
QPROPERTY = re.compile(r'^(?P<indent>[ \t]*)Q_PROPERTY\s*\((?P<args>.*)\)\s*$')

DROP_TOKENS = re.compile(r'\b(?:Q_DECL_[A-Z_]+|Q_REQUIRED_RESULT|Q_EMIT|Q_INVOKABLE)\b')

PLATFORM_ON = {"Q_OS_LINUX", "Q_OS_UNIX", "__linux__", "__unix__", "Q_CC_GNU"}
PLATFORM_OFF = {"Q_OS_WIN", "Q_OS_WIN32", "Q_OS_WINDOWS", "_WIN32", "_WIN64",
                "Q_OS_MAC", "Q_OS_MACOS", "Q_OS_DARWIN", "__APPLE__",
                "Q_OS_FREEBSD", "Q_OS_ANDROID", "Q_OS_IOS", "Q_CC_MSVC",
                "_MSC_VER", "OPENCLOUD_HAVE_CFAPI"}


DEFINE = re.compile(
    r'^[ \t]*#[ \t]*define[ \t]+(?P<name>[A-Za-z_]\w*)'
    r'(?:\((?P<params>[^)]*)\))?[ \t]*(?P<body>.*)$')


def split_args(text: str) -> list[str]:
    """Top-level comma split, so a nested call or paren stays in one argument."""
    out, depth, current = [], 0, ''
    for char in text:
        if char in '([':
            depth += 1
        elif char in ')]':
            depth -= 1
        if char == ',' and depth == 0:
            out.append(current.strip())
            current = ''
            continue
        current += char
    out.append(current.strip())
    return [a for a in out if a != '']


def call_span(text: str, start: int) -> tuple[int, str] | None:
    """The argument list beginning at `start`, which must be its `(`."""
    if start >= len(text) or text[start] != '(':
        return None
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1, text[start + 1:i]
    return None


def substitute(body: str, params: list[str], args: list[str]) -> str:
    """Replace every parameter at once.

    One at a time is wrong, and was the bug: `IS_PREFIX_PATH_OR_EQUAL("path",
    "?1")` binds prefix to `"path"`, and substituting that first leaves the
    text `"path"` in the body -- which the NEXT substitution, of the parameter
    named `path`, then matched inside, giving `""?1""`. That is not a string
    literal, so tree-sitter reported 103 ERROR nodes and the emitter silently
    dropped the 23 methods that followed them.
    """
    binding = dict(zip(params, args))
    pattern = re.compile(r'\b(' + '|'.join(re.escape(p) for p in params) + r')\b')
    return pattern.sub(lambda m: binding[m.group(1)], body)


def expand_macros(source: str) -> str:
    """Expand this file's own #define macros, then drop their definitions.

    The preprocessor is the only thing that can do this: neither tree-sitter
    nor ast-grep expands a macro, so `IS_PREFIX_PATH_OF("?1", "path")` reaches
    the emitter as a call to something that does not exist and the Ruby does
    not parse. Qt's own macros are handled above and are left alone here.

    Object-like and function-like forms only, which is all this tree uses. The
    bodies are C string concatenation (`"(" path " > ("  ...`), and adjacent
    literals are left adjacent: the C++ grammar gives them as one
    concatenated_string and the emitter joins them.
    """
    macros: dict[str, tuple[list[str], str]] = {}
    kept: list[str] = []
    for line in source.split('\n'):
        m = DEFINE.match(line)
        if m and not line.rstrip().endswith('\\'):
            name = m.group('name')
            params = split_args(m.group('params')) if m.group('params') is not None else []
            body = m.group('body').strip()
            # An ALL_CAPS object-like macro is a named constant, and the golden
            # keeps it as one rather than inlining its value everywhere. Turned
            # into a declaration so the emitter sees it; a function-like macro
            # has no Ruby form and is expanded below.
            if not params and name.isupper() and body:
                kept.append(f'    const auto {name} = {body};')
                continue
            macros[name] = (params, body)
            continue
        kept.append(line)
    if not macros:
        return '\n'.join(drop_conditionals(kept))

    text = '\n'.join(kept)
    for _ in range(8):                     # nested macros; this tree needs 2
        changed = False
        for name, (params, body) in macros.items():
            pattern = re.compile(r'\b' + re.escape(name) + r'\b')
            out, at = '', 0
            for m in pattern.finditer(text):
                if m.start() < at:
                    continue
                out += text[at:m.start()]
                if not params:
                    out += body
                    at = m.end()
                    changed = True
                    continue
                span = call_span(text, m.end())
                if span is None:
                    out += m.group(0)
                    at = m.end()
                    continue
                end, inner = span
                args = split_args(inner)
                if len(args) != len(params):
                    out += text[m.start():end]
                    at = end
                    continue
                out += substitute(body, params, args)
                at = end
                changed = True
            text = out + text[at:]
        if not changed:
            break
    return '\n'.join(drop_conditionals(text.split('\n')))


def drop_conditionals(lines: list[str]) -> list[str]:
    """Remove the conditionals left after the platform ones are resolved.

    resolve_conditionals above keeps a conditional it cannot evaluate, which is
    right while it is still C++ -- but by here the only ones left are include
    guards and `#ifndef SQLITE_IOERR_SHMMAP`, and a `#ifndef` line reaching the
    emitter comes out as Ruby that does not parse. `#include` and `#pragma` are
    not touched.
    """
    pattern = re.compile(r'^[ \t]*#[ \t]*(if|ifdef|ifndef|else|elif|endif)\b')
    return [line for line in lines if not pattern.match(line)]


def quote(text: str) -> str:
    return text.replace('\\', '\\\\').replace('"', '\\"')


def resolve_conditionals(lines: list[str]) -> list[str]:
    out: list[str] = []
    # stack of (is_platform_conditional, keeping_now, already_taken)
    stack: list[tuple[bool, bool, bool]] = []

    def verdict(expr: str) -> bool | None:
        on = any(re.search(r'\b' + re.escape(n) + r'\b', expr) for n in PLATFORM_ON)
        off = any(re.search(r'\b' + re.escape(n) + r'\b', expr) for n in PLATFORM_OFF)
        if on and not off:
            return True
        if off and not on:
            return False
        return None            # not a platform guard, or mixed: leave alone

    for line in lines:
        m = re.match(r'^\s*#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)$', line)
        if not m:
            if not stack or all(keep for _, keep, _ in stack):
                out.append(line)
            continue
        kind, rest = m.group(1), m.group(2)

        if kind in ("ifdef", "ifndef", "if"):
            v = verdict(rest)
            if v is None:
                stack.append((False, True, False))
                out.append(line)
            else:
                if kind == "ifndef":
                    v = not v
                stack.append((True, v, v))
            continue

        if not stack:
            out.append(line)
            continue
        is_plat, _keep, taken = stack[-1]
        if kind in ("elif", "else"):
            if is_plat:
                v = True if kind == "else" else bool(verdict(rest))
                stack[-1] = (True, (not taken) and v, taken or v)
            else:
                out.append(line)
            continue
        if kind == "endif":
            if not is_plat:
                out.append(line)
            stack.pop()
    return out


def convert(source: str) -> str:
    source = "\n".join(resolve_conditionals(source.split("\n")))
    source = expand_macros(source)
    source = QOBJECT_HOIST.sub(
        lambda m: '{}[[{}]] {}'.format(m.group('head'), m.group('macro').lower(),
                                       m.group('rest')),
        source)
    source = EXPORT_IN_CLASS.sub(r'\1 [[export]] ', source)

    out, section, counter = [], None, 0
    for line in source.split("\n"):
        if ACCESS.match(line):
            section = None
            out.append(line)
            continue
        m = SECTION.match(line)
        if m:
            section = 'signal' if m.group('kind') in ('Q_SIGNALS', 'signals') else 'slot'
            out.append('{}{}:'.format(m.group('indent'), m.group('access') or 'public'))
            continue
        m = QPROPERTY.match(line)
        if m:
            args = m.group('args').strip()
            parts = args.split()
            head, tail = args, ''
            for i, tok in enumerate(parts):
                if tok in ('READ', 'WRITE', 'NOTIFY', 'RESET', 'MEMBER', 'CONSTANT'):
                    head, tail = ' '.join(parts[:i]), ' '.join(parts[i:])
                    break
            counter += 1
            decl = head if len(head.split()) >= 2 else f'int __q_property_{counter}'
            out.append('{}[[q_property("{}")]] {};'.format(
                m.group('indent'), quote(tail), decl))
            continue
        m = CARRIER.match(line)
        if m:
            counter += 1
            out.append('{}[[{}("{}")]] void __qt_macro_{}__();'.format(
                m.group('indent'), m.group('macro').lower(),
                quote(m.group('args').strip()), counter))
            continue
        line = DROP_TOKENS.sub('', line)
        line = EXPORT_BARE.sub('', line)
        if section and MEMBER.match(line) and not line.strip().startswith('['):
            indent = re.match(r'^[ \t]*', line).group(0)
            line = '{}[[{}]] {}'.format(indent, section, line.strip())
        out.append(line)
    return "\n".join(out)


def main() -> int:
    src, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    n = 0
    for path in sorted(src.rglob("*")):
        if path.suffix not in (".h", ".hpp", ".cpp", ".cc", ".cxx"):
            continue
        target = dest / path.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(convert(path.read_text(encoding="utf-8", errors="replace")),
                          encoding="utf-8")
        n += 1
    print(f"prepared {n} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
