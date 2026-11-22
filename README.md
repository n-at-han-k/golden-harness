# golden-harness

![Golden harness](res/based.png)

Incremental C++ -> Ruby transliteration harness.

## Layout

- `02-input/` - C++ source cases
- `01-golden/` - hand-written golden `.rb` targets (gated regressions)
- `03-output/` - generated output artifacts (gitignored)

## Workflow

```sh
# add a source file from ../src
nix develop --command task add SRC=../src/libsync/foo.cpp

# generate an initial golden draft from current pipeline
nix develop --command task bootstrap SRC=02-input/libsync/foo.cpp

# hand-edit 01-golden/libsync/foo.cpp.rb until correct, then make pipeline match
nix develop --command task verify SRC=02-input/libsync/foo.cpp

# verify all gated goldens (regression gate)
nix develop --command task
```
