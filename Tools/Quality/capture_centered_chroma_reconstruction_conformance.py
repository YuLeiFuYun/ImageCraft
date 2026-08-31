#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_jpeg_chroma_ground_truth import GENERATOR_SOURCE, has_jfif_app0
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
from capture_progressive_jpeg_imcu_chroma_context import RAW_PROBE_SOURCE, build_c_tool


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/JPEGCenteredChromaReconstruction/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/jpeg-centered-chroma-reconstruction-v1.json"
)
UPSAMPLED_PROBE_SOURCE = (
    ROOT / "Tools/Quality/LibJPEGTurboUpsampledYCbCrProbe/main.c"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if (
        profile.get("profileID")
        != "IMAGECRAFT-JPEG-CENTERED-CHROMA-RECONSTRUCTION-V1"
    ):
        raise CaptureError("unexpected centered chroma reconstruction profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-centered-chroma-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError("pinned djpeg is unavailable")
        version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if not isinstance(required_version, str) or not version.startswith(required_version):
            raise CaptureError("jpeg-turbo runtime is outside centered chroma qualification")

        generator = build_c_tool(
            temp,
            GENERATOR_SOURCE,
            "raw-chroma-ground-truth-generator",
            jpeg_prefix,
        )
        raw_probe = build_c_tool(
            temp,
            RAW_PROBE_SOURCE,
            "raw-ycbcr-probe",
            jpeg_prefix,
        )
        upsampled_probe = build_c_tool(
            temp,
            UPSAMPLED_PROBE_SOURCE,
            "upsampled-ycbcr-probe",
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

        results: list[dict[str, Any]] = []
        for case in profile["cases"]:
            case_id = str(case["id"])
            coding_mode = str(case["codingMode"])
            sampling = str(case["sampling"])
            mode = str(case["mode"])
            generated = temp / f"{case_id}.jpg"
            generated_completed = run(
                [str(generator), sampling, str(generated), coding_mode]
            )
            if generated_completed.stderr.strip():
                raise CaptureError(
                    f"centered chroma generator emitted diagnostics: {case_id}: "
                    f"{generated_completed.stderr.strip()}"
                )
            generator_report = parse_json_stdout(
                generated_completed, f"centered chroma generator {case_id}"
            )
            encoded = generated.read_bytes()
            if not has_jfif_app0(encoded):
                raise CaptureError(f"centered chroma generated JPEG lacks JFIF APP0: {case_id}")

            raw_prefix = temp / f"{case_id}.raw"
            raw_completed = run([str(raw_probe), str(generated), str(raw_prefix)])
            if raw_completed.stderr.strip():
                raise CaptureError(
                    f"centered chroma raw probe emitted diagnostics: {case_id}: "
                    f"{raw_completed.stderr.strip()}"
                )
            raw_report = parse_json_stdout(raw_completed, f"centered chroma raw {case_id}")
            components = raw_report.get("components")
            if not isinstance(components, list) or len(components) != 3:
                raise CaptureError(f"centered chroma raw component report drifted: {case_id}")
            source_width = int(components[1]["width"])
            source_height = int(components[1]["height"])
            cb_path = Path(f"{raw_prefix}-Cb.raw")
            cb = cb_path.read_bytes()
            if len(cb) != source_width * source_height:
                raise CaptureError(f"centered chroma raw Cb shape drifted: {case_id}")

            libjpeg_path = temp / f"{case_id}.libjpeg.cb.raw"
            libjpeg_completed = run(
                [str(upsampled_probe), str(generated), str(libjpeg_path)]
            )
            if libjpeg_completed.stderr.strip():
                raise CaptureError(
                    f"centered chroma libjpeg upsample probe warned: {case_id}: "
                    f"{libjpeg_completed.stderr.strip()}"
                )
            libjpeg_report = parse_json_stdout(
                libjpeg_completed, f"centered chroma libjpeg upsample {case_id}"
            )
            output_width = int(libjpeg_report["width"])
            output_height = int(libjpeg_report["height"])
            libjpeg_cb = libjpeg_path.read_bytes()
            if len(libjpeg_cb) != output_width * output_height:
                raise CaptureError(f"centered chroma libjpeg output shape drifted: {case_id}")

            imagecraft_path = temp / f"{case_id}.imagecraft.cb.raw"
            imagecraft_completed = run(
                [
                    str(imagecraft_evidence),
                    "--jpeg-centered-chroma-reconstruct",
                    str(cb_path),
                    str(imagecraft_path),
                    mode,
                    str(source_width),
                    str(source_height),
                    str(output_width),
                    str(output_height),
                ]
            )
            if imagecraft_completed.stderr.strip():
                raise CaptureError(
                    f"centered chroma ImageCraft primitive warned: {case_id}: "
                    f"{imagecraft_completed.stderr.strip()}"
                )
            imagecraft_report = parse_json_stdout(
                imagecraft_completed, f"centered chroma ImageCraft {case_id}"
            )
            imagecraft_cb = imagecraft_path.read_bytes()
            if imagecraft_cb != libjpeg_cb:
                mismatch = next(
                    (
                        index,
                        imagecraft_cb[index],
                        libjpeg_cb[index],
                    )
                    for index in range(min(len(imagecraft_cb), len(libjpeg_cb)))
                    if imagecraft_cb[index] != libjpeg_cb[index]
                )
                raise CaptureError(
                    f"centered chroma differs from libjpeg: {case_id} mismatch={mismatch}"
                )
            if (
                imagecraft_report.get("evidenceVersion")
                != "imagecraft-centered-chroma-reconstruction-v1"
                or imagecraft_report.get("mode") != mode
                or imagecraft_report.get("inputSHA256") != sha256_bytes(cb)
                or imagecraft_report.get("outputSHA256") != sha256_bytes(imagecraft_cb)
            ):
                raise CaptureError(f"centered chroma ImageCraft report drifted: {case_id}")

            results.append(
                {
                    "id": case_id,
                    "codingMode": coding_mode,
                    "sampling": sampling,
                    "mode": mode,
                    "input": {
                        "jpegByteCount": len(encoded),
                        "jpegSHA256": sha256_bytes(encoded),
                        "postIDCTCbByteCount": len(cb),
                        "postIDCTCbSHA256": sha256_bytes(cb),
                        "sourceWidth": source_width,
                        "sourceHeight": source_height,
                    },
                    "generator": generator_report,
                    "rawProbe": raw_report,
                    "libjpegUpsampledProbe": libjpeg_report,
                    "imageCraftPrimitive": imagecraft_report,
                    "output": {
                        "width": output_width,
                        "height": output_height,
                        "byteCount": len(imagecraft_cb),
                        "sha256": sha256_bytes(imagecraft_cb),
                        "exactLibjpegCb": True,
                    },
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError(
                "ImageCraft source identity changed during centered chroma conformance capture"
            )

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-jpeg-centered-chroma-reconstruction-conformance-v1",
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
                "djpegVersion": version,
                "djpegSHA256": sha256_file(djpeg),
                "generatorSHA256": sha256_file(generator),
                "generatorSourceSHA256": sha256_file(GENERATOR_SOURCE),
                "rawProbeSHA256": sha256_file(raw_probe),
                "rawProbeSourceSHA256": sha256_file(RAW_PROBE_SOURCE),
                "upsampledProbeSHA256": sha256_file(upsampled_probe),
                "upsampledProbeSourceSHA256": sha256_file(UPSAMPLED_PROBE_SOURCE),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": results,
            "summary": {
                "caseCount": len(results),
                "allExactLibjpegCb": all(
                    bool(result["output"]["exactLibjpegCb"]) for result in results
                ),
                "modes": sorted({str(result["mode"]) for result in results}),
                "codingModes": sorted(
                    {str(result["codingMode"]) for result in results}
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "centered chroma reconstruction captured: "
            f"cases={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
