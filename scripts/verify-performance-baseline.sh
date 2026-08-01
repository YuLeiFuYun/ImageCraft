#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BASELINE=${1:?usage: scripts/verify-performance-baseline.sh BASELINE}
COUNTS=$(python3 - "$BASELINE" <<'PY'
import json
import sys
baseline = json.load(open(sys.argv[1], encoding="utf-8"))
iterations = {case["iterationsPerProcess"] for case in baseline["cases"]}
repetitions = {case["processRepetitions"] for case in baseline["cases"]}
if len(iterations) != 1 or len(repetitions) != 1:
    raise SystemExit("baseline cases have inconsistent measurement counts")
print(iterations.pop(), repetitions.pop())
PY
)
set -- $COUNTS
ITERATIONS=$1
PROCESS_REPETITIONS=$2
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
REPORT="$TMPDIR_ROOT/report.json"

scripts/capture-performance-evidence.sh "$REPORT" "$ITERATIONS" "$PROCESS_REPETITIONS"
Tools/Performance/verify_performance.py \
    --report "$REPORT" \
    --baseline "$BASELINE"
