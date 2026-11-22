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
