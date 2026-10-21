#!/usr/bin/env bash
# The gate. Each scenario in tests/scenarios runs twice in fresh dirs under .work/run through
# $CASES (default: build tests/cases.mojo to .work/cases) and twice through the Python oracle;
# all four outputs must be identical. Then the API test and the example.
# CASES=tools/oracle.py proves the gate with the oracle as its own stand-in.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
mkdir -p .work
M=.venv/bin/mojo
command -v python3 >/dev/null || { echo "FAIL setup: python3 (the oracle) not found"; exit 1; }
CASES=${CASES:-.work/cases}
if [[ $CASES == .work/cases ]]; then
  $M build -I src tests/cases.mojo -o .work/cases 2>.work/build.err || { echo "FAIL build: tests/cases.mojo"; cat .work/build.err; exit 1; }
fi
[[ -x $CASES ]] || { echo "FAIL setup: CASES=$CASES is not an executable"; exit 1; }
CASES=$(realpath "$CASES")
rm -rf .work/run
n=0
for s in tests/scenarios/*.txt; do
  name=$(basename "$s" .txt)
  for i in 1 2; do
    for who in impl oracle; do
      d=.work/run/$name.$who.$i
      mkdir -p "$d"
      if [[ $who == impl ]]; then cmd=("$CASES"); else cmd=(python3 -I "$ROOT/tools/oracle.py"); fi
      (cd "$d" && "${cmd[@]}" "$ROOT/$s" > out 2> err) || { echo "FAIL run: $name ($who, run $i)"; cat "$d/err"; exit 1; }
    done
  done
  for f in impl.2 oracle.1 oracle.2; do
    diff ".work/run/$name.impl.1/out" ".work/run/$name.$f/out" > .work/oracle.diff || {
      echo "FAIL oracle: $name impl.1 differs from $f"; head -20 .work/oracle.diff; exit 1; }
  done
  echo "oracle: $name identical ($(grep -c . ".work/run/$name.impl.1/out") lines, 2 runs each)"
  n=$((n + 1))
done
rm -rf .work/api .work/quick
$M run -I src tests/api.mojo || { echo "FAIL api: tests/api.mojo"; exit 1; }
$M run -I src examples/quickstart.mojo > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
echo "PASS all"
