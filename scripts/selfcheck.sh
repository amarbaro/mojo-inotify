#!/usr/bin/env bash
# The gate must fail on a wrong runner: stand-ins that drop a line, reorder, or vary per run.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/mutants
O=$PWD/tools/oracle.py
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > ".work/mutants/$1"; chmod +x ".work/mutants/$1"; }
mk drop   "python3 -I $O \"\$1\" | head -n -2; echo 'drained 0 events 0 bytes'"
mk swap   "python3 -I $O \"\$1\" | sed 's/CLOSE_WRITE/CLOSE_NOWRITE/'"
mk flaky  "python3 -I $O \"\$1\"; echo \$RANDOM"
mk silent "python3 -I $O \"\$1\" | grep -v '^w/f '"
for m in drop swap flaky silent; do
  if CASES=.work/mutants/$m scripts/check.sh > .work/mutants/$m.out 2>&1; then echo "FAIL selfcheck: mutant $m passed the gate"; exit 1; fi
  grep -q '^FAIL oracle' .work/mutants/$m.out || { echo "FAIL selfcheck: mutant $m failed for another reason"; cat .work/mutants/$m.out; exit 1; }
done
CASES=tools/oracle.py scripts/check.sh | tail -1
echo "PASS selfcheck (4 mutants rejected)"
