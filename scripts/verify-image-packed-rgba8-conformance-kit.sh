#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 ConformanceKits/ImagePackedRGBA8/v1/run.py \
    --backend-package-path "$ROOT/Fixtures/PackedRGBA8Conformance" \
    --backend-product ImageCraftPackedRGBA8ConformanceFixture \
    --factory-source Fixtures/PackedRGBA8Conformance/ConformanceFactory.swift \
    --output .artifacts/conformance/image-packed-rgba8-v1/report.json \
    --work-directory .artifacts/conformance/image-packed-rgba8-v1/work
