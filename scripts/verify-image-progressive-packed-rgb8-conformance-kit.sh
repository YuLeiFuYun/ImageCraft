#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 ConformanceKits/ImageProgressivePackedRGB8/v1/run.py \
    --backend-package-path "$ROOT/Fixtures/ProgressivePackedRGB8Conformance" \
    --backend-product ImageCraftProgressivePackedRGB8ConformanceFixture \
    --factory-source Fixtures/ProgressivePackedRGB8Conformance/ConformanceFactory.swift \
    --output .artifacts/conformance/image-progressive-packed-rgb8-v1/report.json \
    --work-directory .artifacts/conformance/image-progressive-packed-rgb8-v1/work
