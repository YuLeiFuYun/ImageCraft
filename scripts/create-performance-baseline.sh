#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

OUTPUT=${1:?usage: scripts/create-performance-baseline.sh OUTPUT [ITERATIONS] [PROCESS_REPETITIONS]}
ITERATIONS=${2:-7}
PROCESS_REPETITIONS=${3:-3}
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
REPORT="$TMPDIR_ROOT/report.json"

scripts/capture-performance-evidence.sh "$REPORT" "$ITERATIONS" "$PROCESS_REPETITIONS"
Tools/Performance/create_performance_baseline.py \
    --report "$REPORT" \
    --output "$OUTPUT"
