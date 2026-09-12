#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 ConformanceKits/ImagePackedRGB8/v1/run.py \
    --backend-package-path "$ROOT/Fixtures/PackedRGB8Conformance" \
    --backend-product ImageCraftPackedRGB8ConformanceFixture \
    --factory-source Fixtures/PackedRGB8Conformance/ConformanceFactory.swift \
    --output .artifacts/conformance/image-packed-rgb8-v1/report.json \
    --work-directory .artifacts/conformance/image-packed-rgb8-v1/work
