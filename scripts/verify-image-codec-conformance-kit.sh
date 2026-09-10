#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 ConformanceKits/ImageCodec/v1/run.py \
    --codec-package-path "$ROOT/Fixtures/CodecConformance" \
    --codec-product ImageCraftCodecConformanceFixture \
    --factory-source Fixtures/CodecConformance/ConformanceFactory.swift \
    --output .artifacts/conformance/image-codec-v1/imageio-report.json \
    --work-directory .artifacts/conformance/image-codec-v1/imageio-work

python3 ConformanceKits/ImageCodec/v1/run.py \
    --codec-package-path "$ROOT/Fixtures/LimitedCodecConformance" \
    --codec-product LimitedCodecConformanceFixture \
    --factory-source Fixtures/LimitedCodecConformance/ConformanceFactory.swift \
    --output .artifacts/conformance/image-codec-v1/limited-report.json \
    --work-directory .artifacts/conformance/image-codec-v1/limited-work
