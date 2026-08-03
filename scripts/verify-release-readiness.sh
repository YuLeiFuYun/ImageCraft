#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

scripts/verify.sh
scripts/verify-clean-copy.sh
scripts/verify-consumer-package.sh
scripts/verify-platform-matrix.sh
scripts/verify-independent-oracles.sh
scripts/verify-retained-corpus-reproducibility.sh

if [ "${IMAGECRAFT_VERIFY_PERFORMANCE:-0}" = "1" ]; then
    scripts/verify-performance-baseline.sh \
        Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json
fi
