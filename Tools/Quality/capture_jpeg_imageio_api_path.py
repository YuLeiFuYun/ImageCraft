#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_libjpeg_progressive_suspension import (
    CaptureError,
    ROOT,
    capture_source_identity,
    parse_json_stdout,
    parse_ppm_rgb,
    run,
    sha256_bytes,
    sha256_file,
)
from capture_progressive_jpeg_cross_backend_sampling import compare_rgb_to_opaque_rgba
from capture_progressive_jpeg_imcu_chroma_context import GENERATOR_SOURCE, build_c_tool


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGImageIOAPIPath/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/jpeg-imageio-api-path-v1.json"
PROBE_SOURCE = ROOT / "Tools/Quality/ImageIODirectJPEGProbe/main.swift"


def build_probe(temp: Path) -> Path:
    output = temp / "imageio-direct-jpeg-probe"
    run(
        [
            "xcrun",
            "swiftc",
            "-O",
            str(PROBE_SOURCE),
            "-o",
            str(output),
        ]
    )
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-JPEG-IMAGEIO-API-PATH-V1":
        raise CaptureError("unexpected JPEG ImageIO API-path profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-jpeg-imageio-api-path-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError("djpeg is unavailable")
        generator = build_c_tool(
            temp,
            GENERATOR_SOURCE,
            "raw-chroma-signal-generator",
            jpeg_prefix,
        )
        probe = build_probe(temp)

        case_results: list[dict[str, Any]] = []
        for case in profile["generatedCases"]:
            case_id = str(case["id"])
            coding_mode = str(case["codingMode"])
            sampling = str(case["sampling"])
            generated = temp / f"{case_id}.jpg"
            generator_completed = run(
                [str(generator), sampling, str(generated), coding_mode]
            )
            if generator_completed.stderr.strip():
                raise CaptureError(
                    f"raw component generator emitted diagnostics: {case_id}: "
                    f"{generator_completed.stderr.strip()}"
                )
            generator_report = parse_json_stdout(generator_completed, f"generator {case_id}")
            if generator_report.get("codingMode") != coding_mode:
                raise CaptureError(f"generated coding mode drifted: {case_id}")

            reference_ppm = temp / f"{case_id}.reference.ppm"
            reference_completed = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_completed.stderr.strip():
                raise CaptureError(
                    f"djpeg emitted diagnostics: {case_id}: {reference_completed.stderr.strip()}"
                )
            width, height, reference_rgb = parse_ppm_rgb(reference_ppm)

            variant_results: list[dict[str, Any]] = []
            canonical_rgba: bytes | None = None
            canonical_id: str | None = None
            for variant in profile["variants"]:
                variant_id = str(variant["id"])
                mode = str(variant["mode"])
                allow_float = bool(variant["allowFloat"])
                rgba_path = temp / f"{case_id}-{variant_id}.rgba"
                completed = run(
                    [
                        str(probe),
                        str(generated),
                        str(rgba_path),
                        mode,
                        "true" if allow_float else "false",
                    ]
                )
                if completed.stderr.strip():
                    raise CaptureError(
                        f"ImageIO direct probe emitted diagnostics: {case_id}/{variant_id}: "
                        f"{completed.stderr.strip()}"
                    )
                observation = parse_json_stdout(
                    completed,
                    f"ImageIO direct probe {case_id}/{variant_id}",
                )
                rgba = rgba_path.read_bytes()
                if (
                    observation.get("width") != width
                    or observation.get("height") != height
                    or len(rgba) != width * height * 4
                    or observation.get("mode") != mode
                    or observation.get("allowFloat") is not allow_float
                ):
                    raise CaptureError(
                        f"ImageIO API-path output contract drifted: {case_id}/{variant_id}"
                    )
                differential = compare_rgb_to_opaque_rgba(reference_rgb, rgba)
                if differential["allAlphaOpaque"] is not True:
                    raise CaptureError(
                        f"ImageIO API-path output alpha is not opaque: {case_id}/{variant_id}"
                    )
                if canonical_rgba is None:
                    canonical_rgba = rgba
                    canonical_id = variant_id
                elif rgba != canonical_rgba:
                    raise CaptureError(
                        f"ImageIO API-path variants differ bytewise: {case_id}: "
                        f"canonical={canonical_id} variant={variant_id}"
                    )
                variant_results.append(
                    {
                        "id": variant_id,
                        "mode": mode,
                        "allowFloat": allow_float,
                        "observation": observation,
                        "rgba8SHA256": sha256_bytes(rgba),
                        "againstLibjpeg": differential,
                    }
                )

            case_results.append(
                {
                    "id": case_id,
                    "codingMode": coding_mode,
                    "sampling": sampling,
                    "input": {
                        "byteCount": generated.stat().st_size,
                        "sha256": sha256_bytes(generated.read_bytes()),
                    },
                    "generator": generator_report,
                    "variants": variant_results,
                    "allVariantsByteIdentical": True,
                    "canonicalRGBA8SHA256": sha256_bytes(canonical_rgba or b""),
                    "libjpegRGBSHA256": sha256_bytes(reference_rgb),
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during JPEG ImageIO API-path capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-jpeg-imageio-api-path-v1",
            "status": "source-bound-api-path-negative-result",
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
                "djpegSHA256": sha256_file(djpeg),
                "generatorSHA256": sha256_file(generator),
                "generatorSourceSHA256": sha256_file(GENERATOR_SOURCE),
                "imageIODirectProbeSHA256": sha256_file(probe),
                "imageIODirectProbeSourceSHA256": sha256_file(PROBE_SOURCE),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": case_results,
            "summary": {
                "caseCount": len(case_results),
                "variantCountPerCase": len(profile["variants"]),
                "allVariantsByteIdentical": all(
                    bool(case["allVariantsByteIdentical"]) for case in case_results
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "JPEG ImageIO API-path capture passed: "
            f"cases={len(case_results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
