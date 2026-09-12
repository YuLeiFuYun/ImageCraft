#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 ConformanceKits/ImagePackedRGBA16/v1/run.py \
    --backend-package-path "$ROOT/Fixtures/PackedRGBA16Conformance" \
    --backend-product ImageCraftPackedRGBA16ConformanceFixture \
    --factory-source Fixtures/PackedRGBA16Conformance/ConformanceFactory.swift \
    --output .artifacts/conformance/image-packed-rgba16-v1/report.json \
    --work-directory .artifacts/conformance/image-packed-rgba16-v1/work
