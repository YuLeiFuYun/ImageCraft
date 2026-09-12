#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

import capture_fovea_baseline_packed_rgb8_host_qualification_v2 as engine

engine.DEFAULT_OUTPUT = (
    engine.ROOT
    / ".artifacts/performance/baseline-packed-rgb8-fovea-host-v3/formal-report.json"
)
engine.EVIDENCE_VERSION = "imagecraft-fovea-baseline-packed-rgb8-host-v3"
engine.REPORT_SCHEMA_VERSION = 3
engine.RUN_LABEL = "v3"
engine.QUALIFICATION_SCOPE = "the finite public baseline JFIF union (grayscale + 4:4:4 + 4:2:2 + 4:2:0)"
engine.EXPECTED_CASES = [
    {
        "id": "baseline-jfif-grayscale-19x11",
        "sampling": "grayscale",
        "width": 19,
        "height": 11,
        "file": "reference-baseline-jfif-grayscale-19x11.jpg",
        "expectedRGB8File": "reference-baseline-jfif-grayscale-19x11.rgb",
        "sourceByteCount": 543,
        "packedByteCount": 627,
        "sourceSHA256": "f9f74e388a7dcd740c878c895a3e00b917f8739f3d86f71798742dfe9176f0c7",
        "packedSHA256": "466b5f63a65b4311ce2dfa93e660e4d4a5a71cebfc835388d2006c3489172949",
        "operationPeakBytes": 836,
    },
    *engine.EXPECTED_CASES,
]

if __name__ == "__main__":
    raise SystemExit(engine.main())
