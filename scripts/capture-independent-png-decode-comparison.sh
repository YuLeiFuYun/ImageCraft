#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/Tools/Performance/capture_independent_png_decode_comparison.py" "$@"
