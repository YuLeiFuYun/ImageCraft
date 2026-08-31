#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/quality/independent-png-v3/formal-report.json}
python3 Tools/Quality/capture_independent_png_conformance.py \
    --profile Evidence/Experiments/IndependentPNG/v3/profile.json \
    --output "$OUTPUT"
