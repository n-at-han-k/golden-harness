#!/usr/bin/env python3
"""Diff the generated Ruby for discovery.cpp against the hand-written golden.

This is the acceptance test for the whole transliteration. discovery.cpp.rb was
written by hand to show exactly what the output should look like; if the
pipeline cannot reproduce it, nothing else about the pipeline matters.

The golden covers the first two methods (start and process), roughly the first
130 lines of a 1320-line, 20-method file, so it is a PREFIX target: the
generated output should agree with it line for line up to where the golden
stops, and then keep going.

What this reports
-----------------
  * line-by-line agreement on the golden's range, after normalising whitespace
  * the first divergence, which is the thing to fix next
  * a per-feature checklist, because a raw line diff says "92 lines differ"
    without saying which TRANSFORMATION is missing -- and the whole point of
    the golden is to enumerate the transformations

The feature checks are derived from reading the golden against the C++ source.
They are what actually drives the rule work.

It does NOT run the pipeline. Taskfile.yml does that, one task per stage,
and hands the result here:

    task                                      the pipeline, ending in this
    task compare                              just this, on the last run's output
    python3 scripts/compare.py --generated FILE
    python3 scripts/compare.py --generated FILE --features
"""
from __future__ import annotations

import argparse
import difflib
import pathlib
import re
import os
import shutil
import subprocess
import sys

SCRIPTS = pathlib.Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
GOLDEN = ROOT / "discovery.cpp.rb"
SOURCE = ROOT / "discovery.cpp"
# Inside the project, not /tmp. rubocop resolves .rubocop.yml relative to the
# file it inspects, so staging under /tmp silently used rubocop's DEFAULT config
# and inserted `# frozen_string_literal: true`, shifting the whole diff. Keeping
# the work here also leaves every pipeline stage on disk to inspect.
WORK = ROOT / "tmp"

# Each entry: (label, regex that must appear in the generated output, example
# from the golden). Derived by reading the golden against discovery.cpp, and
# ordered roughly by how mechanical the transformation is.
FEATURES: list[tuple[str, str, str]] = [
    ("shebang",
     r"^#!/usr/bin/env ruby",
     "#!/usr/bin/env ruby"),
    ("block comment -> #",
     r"^# Copyright \(C\) by",
     "/* Copyright... */  ->  # Copyright..."),
    ('local #include -> require_relative',
     r'^require_relative "discovery"',
     '#include "discovery.h"  ->  require_relative "discovery"  (no extension)'),
    ("system #include -> require",
     r'^require "algorithm"',
     '#include <algorithm>  ->  require "algorithm"'),
    ("Qt #include lowercased",
     r'^require "qfile"',
     '#include <QFile>  ->  require "qfile"'),
    ("namespace -> module",
     r"^module OCC",
     "namespace OCC {  ->  module OCC"),
    ("qualified method -> class + def",
     r"^\s*class ProcessDirectoryJob",
     "void ProcessDirectoryJob::start()  ->  class ProcessDirectoryJob / def start"),
    ("method def",
     r"^\s*def start",
     "def start()"),
    ("member -> @snake_case",
     r"@current_folder",
     "_currentFolder  ->  @current_folder"),
    ("member field access",
     r"@current_folder\.server",
     "_currentFolder._server  ->  @current_folder.server"),
    ("camelCase call -> snake_case",
     r"start_async_server_query",
     "startAsyncServerQuery()  ->  start_async_server_query"),
    ("enum constant -> symbol",
     r":normal_query",
     "NormalQuery  ->  :normal_query"),
    ("is_* keeps its prefix",
     r"\bis_hidden\b",
     "isHidden()  ->  is_hidden  (NOT hidden? -- see rubyify.rename)"),
    ("qCInfo -> Log.info block",
     r'Log\.info\("sync\.discovery"\)\s*\{',
     'qCInfo(lcDisco) << ...  ->  Log.info("sync.discovery") { ... }'),
    ("stream -> interpolation",
     r'#\{@current_folder\.server\}',
     '<< _currentFolder._server  ->  #{@current_folder.server}'),
    ("struct -> Struct.new",
     r"Entr\w*\s*=\s*Struct\.new",
     "struct Entries {...}  ->  Entry = Struct.new(..., keyword_init: true)"),
    ("std::map -> Hash with default block",
     r"Hash\.new\s+do\s*\|",
     "std::map<QString,Entries> entries  ->  Hash.new do |hash, key|"),
    ("range-for -> each do",
     r"\.each\s+do\s*\|",
     "for (auto &e : coll)  ->  coll.each do |e|"),
    ("lambda -> block",
     r"list_files_in_path\(.*\)\s*\{\s*\|rec\|",
     "listFilesInPath(x, [&](rec){...})  ->  list_files_in_path(x) { |rec| ... } "
     "(braces, since do/end binds to the outermost call)"),
    ("OC_ASSERT -> raise",
     r"^\s*raise\b",
     "OC_ASSERT(...)  ->  raise"),
    ("continue -> next",
     r"^\s*next\b",
     "continue  ->  next"),
    ("no safe navigation",
     r"\be\.local_entry\.is_hidden\b",
     "e.localEntry.isHidden()  ->  e.local_entry.is_hidden  (no &.)"),
    ("expressions kept verbatim",
     r'f\.first\[0\] == "\."',
     'f.first[0] == QLatin1Char(\'.\')  ->  f.first[0] == "."'),
    (":: -> . on call",
     r"QTimer\.single_shot",
     "QTimer::singleShot  ->  QTimer.single_shot"),
    ("end for class/module",
     r"(?m)^\s*end\s*$",
     "closing } of namespace  ->  end"),
]


def rubocop_format(text: str, tag: str) -> str:
    """Run `rubocop -A` over a snippet and return the formatted result.

    Applied to the golden AND the generated output so both sides are laid out
    identically -- otherwise the diff is dominated by indentation the generator
    was never trying to control. Both files are left in tmp/ afterwards.
    """
    WORK.mkdir(parents=True, exist_ok=True)
    f = WORK / f"{tag}.formatted.rb"
    f.write_text(text)
    subprocess.run(["bundle", "exec", "rubocop", "-A",
                    "-c", str(ROOT / ".rubocop.yml"),
                    "--fail-level", "fatal", "--format", "quiet", str(f)],
                   capture_output=True, text=True, cwd=ROOT)
    return f.read_text()


def normalise(line: str) -> str:
    """Collapse whitespace. rubocop has already settled layout; this only
    guards against a trailing-space difference surviving it."""
    return re.sub(r"\s+", " ", line.strip())


# Where the pipeline's last stage leaves the generated Ruby, for when
# --generated is not given.
DEFAULT_GENERATED = ROOT / "tmp" / "5-ruby" / "libsync" / "discovery.cpp.rb"


def report_features(generated: str) -> tuple[int, int]:
    rows = []
    for label, pattern, example in FEATURES:
        ok = bool(re.search(pattern, generated, re.M)) if generated else False
        rows.append((ok, label, example))
    done = sum(1 for ok, _, _ in rows if ok)
    width = max(len(label) for _, label, _ in rows)
    print(f"{'':2} {'transformation':{width}}  example")
    print("-" * (width + 60))
    for ok, label, example in rows:
        print(f"{'ok' if ok else '..':2} {label:{width}}  {example}")
    print("-" * (width + 60))
    print(f"   {done}/{len(rows)} transformations present")
    return done, len(rows)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generated", type=pathlib.Path,
                    help=f"the generated Ruby (default: {DEFAULT_GENERATED})")
    # The golden is per-source: discovery.cpp has discovery.cpp.rb and
    # discovery.cpp.full has discovery.cpp.full.rb. Without this the full run
    # was scored against the TRIMMED golden, so it always reported a divergence
    # at line 131 -- where the trimmed golden simply stops -- and exited 1 on a
    # run that had in fact reproduced its own golden exactly.
    ap.add_argument("--golden", type=pathlib.Path, default=GOLDEN,
                    help=f"the hand-written target (default: {GOLDEN.name})")
    ap.add_argument("--features", action="store_true",
                    help="only print the transformation checklist")
    ap.add_argument("--context", type=int, default=3)
    args = ap.parse_args()

    golden_path = args.golden
    if not golden_path.exists():
        print(f"error: {golden_path} missing", file=sys.stderr)
        return 2

    produced = args.generated or DEFAULT_GENERATED
    if not produced.exists():
        print(f"error: {produced} missing -- run `task` first", file=sys.stderr)
        report_features("")
        return 1
    generated = produced.read_text()

    if args.features:
        done, total = report_features(generated)
        return 0 if done == total else 1

    golden_lines = rubocop_format(golden_path.read_text(), "golden").split("\n")
    gen_lines = rubocop_format(generated, "generated").split("\n")

    # The golden is a prefix target: compare only as far as it goes.
    span = len(golden_lines)
    g_norm = [normalise(l) for l in golden_lines]
    o_norm = [normalise(l) for l in gen_lines[:span]]

    matcher = difflib.SequenceMatcher(None, g_norm, o_norm)
    ratio = matcher.ratio()
    same = sum(block.size for block in matcher.get_matching_blocks())

    print(f"golden:     {len(golden_lines)} lines  ({golden_path.name})")
    print(f"generated:  {len(gen_lines)} lines")
    print(f"agreement:  {same}/{span} lines  ({100 * ratio:.1f}% similarity)")
    print()

    first = None
    for i, (a, b) in enumerate(zip(g_norm, o_norm)):
        if a != b:
            first = i
            break
    if first is None and len(gen_lines) == len(golden_lines):
        print("golden fully reproduced")
    elif first is None:
        print(f"golden reproduced as a prefix "
              f"({len(golden_lines)} of {len(gen_lines)} lines)")
    elif first is not None:
        print(f"first divergence at golden line {first + 1}:")
        lo = max(0, first - args.context)
        for i in range(lo, min(span, first + args.context + 1)):
            mark = ">>" if i == first else "  "
            print(f"  {mark} golden    {i+1:4}| {golden_lines[i]}")
            if i < len(gen_lines):
                print(f"  {mark} generated {i+1:4}| {gen_lines[i]}")
    print()
    report_features(generated)
    return 0 if first is None else 1


if __name__ == "__main__":
    sys.exit(main())
