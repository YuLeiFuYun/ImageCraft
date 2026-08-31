#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/quality/cross-backend-packed-jpeg-v1/report.json}
python3 Tools/Quality/capture_cross_backend_packed_jpeg.py --output "$OUTPUT"
