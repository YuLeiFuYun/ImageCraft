#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_libjpeg_progressive_suspension import (
    build_imagecraft_evidence,
    CaptureError,
    ROOT,
    capture_source_identity,
    parse_json_stdout,
    run,
    sha256_bytes,
    sha256_file,
)
from capture_progressive_jpeg_imcu_chroma_context import build_c_tool


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGISlowIDCT/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/jpeg-islow-idct-v1.json"
PROBE_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboCoefficientBlockProbe/main.c"


def write_pgm(path: Path, pattern: str) -> bytes:
    pixels = bytearray(64)
    for y in range(8):
        for x in range(8):
            index = y * 8 + x
            if pattern == "black":
                value = 0
            elif pattern == "white":
                value = 255
            elif pattern == "gray":
                value = 128
            elif pattern == "horizontal-ramp":
                value = x * 36
            elif pattern == "vertical-ramp":
                value = y * 36
            elif pattern == "checker":
                value = 32 if (x + y) & 1 == 0 else 224
            elif pattern == "impulse":
                value = 240 if (x, y) == (3, 4) else 96
            elif pattern == "deterministic-noise":
                value = (x * 37 + y * 71 + (x * y * 19) + 23) & 0xFF
            else:
                raise CaptureError(f"unsupported IDCT source pattern: {pattern}")
            pixels[index] = value
    data = b"P5\n8 8\n255\n" + bytes(pixels)
    path.write_bytes(data)
    return data


def parse_pgm(path: Path) -> bytes:
    data = path.read_bytes()
    if not data.startswith(b"P5"):
        raise CaptureError("djpeg grayscale reference is not binary PGM")
    position = 2
    tokens: list[bytes] = []
    while len(tokens) < 3:
        while position < len(data) and data[position : position + 1].isspace():
            position += 1
        if position < len(data) and data[position] == ord("#"):
            newline = data.find(b"\n", position)
            if newline < 0:
                raise CaptureError("unterminated PGM comment")
            position = newline + 1
            continue
        end = position
        while end < len(data) and not data[end : end + 1].isspace():
            end += 1
        if end == position:
            raise CaptureError("missing PGM header token")
        tokens.append(data[position:end])
        position = end
    width, height, maximum = (int(token) for token in tokens)
    if (width, height, maximum) != (8, 8, 255):
        raise CaptureError("unexpected PGM reference geometry")
    raster_start = len(data) - 64
    if raster_start <= position:
        raise CaptureError("unexpected PGM reference byte count")
    separator = data[position:raster_start]
    if not separator or any(not bytes([value]).isspace() for value in separator):
        raise CaptureError("unexpected PGM header/raster separator")
    pixels = data[raster_start:]
    return pixels


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-JPEG-ISLOW-IDCT-V1":
        raise CaptureError("unexpected JPEG ISLOW IDCT profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-jpeg-islow-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        djpeg = jpeg_prefix / "bin/djpeg"
        if not cjpeg.is_file() or not djpeg.is_file():
            raise CaptureError("pinned cjpeg/djpeg are unavailable")
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if (
            not isinstance(required_version, str)
            or not cjpeg_version.startswith(required_version)
            or not djpeg_version.startswith(required_version)
        ):
            raise CaptureError("jpeg-turbo runtime is outside ISLOW qualification")

        probe = build_c_tool(
            temp,
            PROBE_SOURCE,
            "coefficient-block-probe",
            jpeg_prefix,
        )
        build = run(
            [
                "swift",
                "build",
                "-c",
                "release",
                "--product",
                "ImageCraftEvidence",
                "--jobs",
                "1",
            ],
            cwd=ROOT,
        )
        if "Build complete!" not in build.stdout:
            raise CaptureError("ImageCraftEvidence release build did not report completion")
        imagecraft_evidence = build_imagecraft_evidence()
        if not imagecraft_evidence.is_file():
            raise CaptureError("ImageCraftEvidence release binary is unavailable")

        cases: list[dict[str, Any]] = []
        for pattern in profile["patterns"]:
            source_path = temp / f"{pattern}.pgm"
            source = write_pgm(source_path, str(pattern))
            for quality in profile["qualities"]:
                for coding_mode in profile["codingModes"]:
                    case_id = f"{pattern}-q{quality}-{coding_mode}"
                    jpeg_path = temp / f"{case_id}.jpg"
                    cjpeg_argv = [
                        str(cjpeg),
                        "-grayscale",
                        "-quality",
                        str(quality),
                        "-dct",
                        "int",
                        "-optimize",
                    ]
                    if coding_mode == "progressive":
                        cjpeg_argv.append("-progressive")
                    elif coding_mode != "baseline":
                        raise CaptureError(f"unsupported IDCT coding mode: {coding_mode}")
                    cjpeg_argv.extend(["-outfile", str(jpeg_path), str(source_path)])
                    encoded_completed = run(cjpeg_argv)
                    if encoded_completed.stderr.strip():
                        raise CaptureError(
                            f"cjpeg emitted diagnostics for {case_id}: "
                            f"{encoded_completed.stderr.strip()}"
                        )
                    encoded = jpeg_path.read_bytes()

                    block_path = temp / f"{case_id}.block.bin"
                    probe_completed = run([str(probe), str(jpeg_path), str(block_path)])
                    if probe_completed.stderr.strip():
                        raise CaptureError(
                            f"coefficient probe emitted diagnostics for {case_id}: "
                            f"{probe_completed.stderr.strip()}"
                        )
                    probe_report = parse_json_stdout(
                        probe_completed, f"coefficient probe {case_id}"
                    )
                    block = block_path.read_bytes()
                    if len(block) != 256:
                        raise CaptureError(f"coefficient block payload drifted: {case_id}")
                    if int(probe_report["maximumAbsoluteDequantizedCoefficient"]) > 32767:
                        raise CaptureError(
                            f"generated legal block exceeds current ImageCraft ISLOW domain: "
                            f"{case_id}"
                        )
                    expected_progressive = coding_mode == "progressive"
                    if probe_report.get("progressiveMode") is not expected_progressive:
                        raise CaptureError(f"coefficient coding mode drifted: {case_id}")

                    reference_path = temp / f"{case_id}.reference.pgm"
                    reference_completed = run(
                        [
                            str(djpeg),
                            "-grayscale",
                            "-dct",
                            "int",
                            "-pnm",
                            "-outfile",
                            str(reference_path),
                            str(jpeg_path),
                        ]
                    )
                    if reference_completed.stderr.strip():
                        raise CaptureError(
                            f"djpeg emitted diagnostics for {case_id}: "
                            f"{reference_completed.stderr.strip()}"
                        )
                    reference = parse_pgm(reference_path)

                    imagecraft_path = temp / f"{case_id}.imagecraft.raw"
                    imagecraft_completed = run(
                        [
                            str(imagecraft_evidence),
                            "--jpeg-islow-idct-block",
                            str(block_path),
                            "--output",
                            str(imagecraft_path),
                        ]
                    )
                    if imagecraft_completed.stderr.strip():
                        raise CaptureError(
                            f"ImageCraft ISLOW emitted diagnostics for {case_id}: "
                            f"{imagecraft_completed.stderr.strip()}"
                        )
                    imagecraft_report = parse_json_stdout(
                        imagecraft_completed, f"ImageCraft ISLOW {case_id}"
                    )
                    imagecraft = imagecraft_path.read_bytes()
                    if imagecraft != reference:
                        mismatches = [
                            (index, imagecraft[index], reference[index])
                            for index in range(64)
                            if imagecraft[index] != reference[index]
                        ]
                        raise CaptureError(
                            f"ImageCraft ISLOW differs from libjpeg: {case_id} "
                            f"first={mismatches[:8]}"
                        )
                    if (
                        imagecraft_report.get("evidenceVersion")
                        != "imagecraft-jpeg-islow-idct-block-v1"
                        or imagecraft_report.get("inputSHA256") != sha256_bytes(block)
                        or imagecraft_report.get("outputSHA256") != sha256_bytes(imagecraft)
                        or imagecraft_report.get("workspaceByteCount") != 256
                    ):
                        raise CaptureError(f"ImageCraft ISLOW report drifted: {case_id}")

                    cases.append(
                        {
                            "id": case_id,
                            "pattern": pattern,
                            "quality": quality,
                            "codingMode": coding_mode,
                            "sourcePGMSHA256": sha256_bytes(source),
                            "jpegByteCount": len(encoded),
                            "jpegSHA256": sha256_bytes(encoded),
                            "coefficientBlockSHA256": sha256_bytes(block),
                            "coefficientProbe": probe_report,
                            "referenceRasterSHA256": sha256_bytes(reference),
                            "imageCraftRasterSHA256": sha256_bytes(imagecraft),
                            "imageCraftEvidence": imagecraft_report,
                            "exactLibjpegISlow": True,
                        }
                    )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during ISLOW capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-jpeg-islow-idct-conformance-v1",
            "status": "source-bound-package-kernel-conformance",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "profile": {
                "profileID": profile["profileID"],
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
            },
            "sourceIdentity": {
                "sourceIdentitySHA256": before_hash,
                "fileCount": before.get("fileCount"),
                "stableBeforeAfter": True,
            },
            "runtime": {
                "pythonVersion": platform.python_version(),
                "architecture": platform.machine(),
                "jpegTurboPrefix": str(jpeg_prefix),
                "cjpegVersion": cjpeg_version,
                "djpegVersion": djpeg_version,
                "cjpegSHA256": sha256_file(cjpeg),
                "djpegSHA256": sha256_file(djpeg),
                "probeSHA256": sha256_file(probe),
                "probeSourceSHA256": sha256_file(PROBE_SOURCE),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": cases,
            "summary": {
                "caseCount": len(cases),
                "allExactLibjpegISlow": all(case["exactLibjpegISlow"] for case in cases),
                "maximumAbsoluteDequantizedCoefficient": max(
                    int(case["coefficientProbe"]["maximumAbsoluteDequantizedCoefficient"])
                    for case in cases
                ),
                "patterns": sorted({str(case["pattern"]) for case in cases}),
                "qualities": sorted({int(case["quality"]) for case in cases}),
                "codingModes": sorted({str(case["codingMode"]) for case in cases}),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "JPEG ISLOW IDCT captured: "
            f"cases={len(cases)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
