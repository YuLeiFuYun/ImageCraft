#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/performance/rfc1950-inflate-comparison-v1/formal-report.json}
python3 Tools/Performance/capture_rfc1950_inflate_comparison.py --output "$OUTPUT"
