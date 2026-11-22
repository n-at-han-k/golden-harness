#!/usr/bin/env python3
"""Regression harness for golden-harness.

Layout:
  02-input/<rel>/<name>.<ext>      source case
  01-golden/<rel>/<name>.<ext>.rb  hand-written golden (gated)
  03-output/<rel>/<name>.<ext>.rb  last generated output (artifact)

For every golden, the corresponding input is run through the pipeline and the
normalized output is diffed against the golden. Any difference is a regression.
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INPUT = ROOT / "02-input"
GOLDEN = ROOT / "01-golden"
OUTPUT = ROOT / "03-output"
TMP = ROOT / "tmp"
WORK = TMP / "work"

PIPELINE = [
    ["python3", "scripts/01_build_transform.py"],
    ["python3", "scripts/02_prepare.py", "tmp/work", "tmp/work"],
    ["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/01_alias.yml", "--update-all", "tmp/work"],
    ["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/02_typos.yml", "--update-all", "tmp/work"],
    # simplify fixpoint
    None,
    ["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/04_interp.yml", "--update-all", "tmp/work"],
    ["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/07_transform.yml", "--update-all", "tmp/work"],
    ["python3", "scripts/03_rubyify.py", "tmp/work", "tmp/work"],
    # rubocop
    None,
]


def rel_for_input(path: pathlib.Path) -> pathlib.Path:
    path = path.resolve()
    try:
        return path.relative_to(INPUT.resolve())
    except ValueError:
        pass
    try:
        return path.relative_to(ROOT.resolve())
    except ValueError:
        return pathlib.Path(path.name)


def golden_for(rel: pathlib.Path) -> pathlib.Path:
    return GOLDEN / (str(rel) + ".rb")


def output_for(rel: pathlib.Path) -> pathlib.Path:
    return OUTPUT / (str(rel) + ".rb")


def input_for_golden(golden: pathlib.Path) -> pathlib.Path:
    rel = golden.resolve().relative_to(GOLDEN.resolve())
    # strip trailing .rb -> original name.ext
    name = rel.name
    if not name.endswith(".rb"):
        raise ValueError(f"not a golden rb: {golden}")
    src_name = name[:-3]
    return INPUT / rel.parent / src_name


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd))
    p = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
    if p.stdout:
        sys.stdout.write(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    if check and p.returncode != 0:
        raise subprocess.CalledProcessError(p.returncode, cmd, p.stdout, p.stderr)
    return p


def run_simplify_fixpoint() -> None:
    for i in range(1, 21):
        p = run(
            ["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/03_simplify.yml", "--update-all", "tmp/work"],
            check=False,
        )
        out = (p.stdout or "") + (p.stderr or "")
        if "Applied" not in out:
            print(f"simplify: fixpoint after {i} round(s)")
            return
    print("simplify: reached 20 rounds")


def run_rubocop() -> None:
    run(["bundle", "exec", "rubocop", "-A", "-c", ".rubocop.yml", "tmp/work"], check=False)


CPP_EXTS = {".h", ".hpp", ".cpp", ".cc", ".cxx"}


def work_name(name: str) -> str:
    p = pathlib.Path(name)
    if p.suffix in CPP_EXTS:
        return name
    # handle names like discovery.cpp.full -> discovery.cpp
    if p.suffix == ".full" and pathlib.Path(p.stem).suffix in CPP_EXTS:
        return p.stem
    return name


def pipeline(src: pathlib.Path) -> pathlib.Path:
    rel = rel_for_input(src)
    basename = src.name
    staged_name = work_name(basename)
    staged_rel = rel.parent / staged_name
    if TMP.exists():
        shutil.rmtree(TMP)
    (WORK / staged_rel.parent).mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, WORK / staged_rel)

    run(["python3", "scripts/01_build_transform.py"])
    run(["python3", "scripts/02_prepare.py", "tmp/work", "tmp/work"])
    run(["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/01_alias.yml", "--update-all", "tmp/work"])
    run(["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/02_typos.yml", "--update-all", "tmp/work"])
    run_simplify_fixpoint()
    run(["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/rules/04_interp.yml", "--update-all", "tmp/work"])
    run(["ast-grep", "scan", "-c", "sgconfig.yml", "-r", "scripts/07_transform.yml", "--update-all", "tmp/work"])
    run(["python3", "scripts/03_rubyify.py", "tmp/work", "tmp/work"])
    run_rubocop()

    produced = WORK / staged_rel.parent / (staged_name + ".rb")
    if not produced.exists():
        cands = sorted(WORK.rglob("*.rb"))
        if len(cands) == 1:
            produced = cands[0]
        else:
            raise FileNotFoundError(f"expected generated rb for {src}, found: {cands}")
    out = output_for(rel)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(produced, out)
    return out


def verify_case(src: pathlib.Path, *, bootstrap: bool = False) -> bool:
    rel = rel_for_input(src)
    gold = golden_for(rel)
    out = pipeline(src)
    if bootstrap:
        gold.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(out, gold)
        print(f"BOOTSTRAPPED {gold}")
        return True
    if not gold.exists():
        print(f"FAIL {rel}: missing golden {gold}")
        return False
    p = subprocess.run(
        ["python3", "scripts/04_compare.py", "--generated", str(out), "--golden", str(gold)],
        cwd=ROOT,
    )
    return p.returncode == 0


def all_goldens() -> list[pathlib.Path]:
    if not GOLDEN.exists():
        return []
    return sorted(GOLDEN.rglob("*.rb"))


def cmd_add(src: pathlib.Path) -> int:
    src = src.resolve()
    # preserve relative path under src/ if possible
    repo = ROOT.parent
    try:
        rel = src.relative_to((repo / "src").resolve())
    except Exception:
        rel = pathlib.Path(src.name)
    dst = INPUT / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    print(f"ADDED {dst}")
    print(f"Next: python3 scripts/05_validate.py --case {dst.relative_to(ROOT)} --bootstrap")
    return 0


def oneshot(src: pathlib.Path, dst: pathlib.Path) -> int:
    src = src.resolve()
    dst = dst.resolve()
    out = pipeline(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(out, dst)
    print(f"WROTE {dst}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", help="verify/bootstrap a single 02-input case")
    ap.add_argument("--bootstrap", action="store_true", help="write generated output as 01-golden draft")
    ap.add_argument("--add", help="copy a source file into 02-input")
    ap.add_argument("--oneshot", help="run pipeline on an arbitrary input file")
    ap.add_argument("--output", help="output .rb path for --oneshot")
    args = ap.parse_args()

    if args.add:
        return cmd_add(pathlib.Path(args.add))

    if args.oneshot:
        if not args.output:
            print("--oneshot requires --output", file=sys.stderr)
            return 2
        src = pathlib.Path(args.oneshot)
        if not src.is_absolute():
            src = (ROOT / src).resolve() if not src.exists() else src.resolve()
        if not src.exists():
            print(f"missing input: {src}", file=sys.stderr)
            return 2
        return oneshot(src, pathlib.Path(args.output))

    if args.case:
        src = pathlib.Path(args.case)
        if not src.is_absolute():
            src = (ROOT / src).resolve()
        if not src.exists():
            print(f"missing case: {src}", file=sys.stderr)
            return 2
        ok = verify_case(src, bootstrap=args.bootstrap)
        return 0 if ok else 1

    goldens = all_goldens()
    if not goldens:
        print("no goldens found in 01-golden/")
        return 1
    failed = []
    for g in goldens:
        src = input_for_golden(g)
        rel = g.resolve().relative_to(GOLDEN.resolve())
        if not src.exists():
            print(f"FAIL {rel}: missing input {src}")
            failed.append(str(rel))
            continue
        ok = verify_case(src)
        if not ok:
            failed.append(str(rel))
    print(f"\n{len(goldens)-len(failed)}/{len(goldens)} goldens passed")
    if failed:
        print("Failures:")
        for f in failed:
            print(f" - {f}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
