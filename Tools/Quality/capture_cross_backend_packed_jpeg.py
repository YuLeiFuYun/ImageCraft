#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/CrossBackendJPEG/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/quality/cross-backend-packed-jpeg-v1/report.json"
EVIDENCE_VERSION = "imagecraft-cross-backend-packed-jpeg-v1"


class CaptureError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def run(
    argv: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    timeout: int = 600,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise CaptureError(
            f"command failed ({result.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise CaptureError(f"expected JSON object: {path}")
    return value


def parse_json_stdout(result: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CaptureError(f"{label} emitted invalid JSON: {error}\n{result.stdout}") from error
    if not isinstance(value, dict):
        raise CaptureError(f"{label} emitted non-object JSON")
    return value


def git_identity(path: Path, *, require_tree: str | None = None) -> dict[str, Any]:
    revision = run(["git", "rev-parse", "HEAD"], cwd=path).stdout.strip()
    tree = run(["git", "rev-parse", "HEAD^{tree}"], cwd=path).stdout.strip()
    status = run(["git", "status", "--porcelain"], cwd=path).stdout.splitlines()
    result = {
        "path": str(path),
        "revision": revision,
        "tree": tree,
        "clean": not status,
        "dirtyPaths": status,
    }
    if require_tree is not None and tree != require_tree:
        raise CaptureError(f"git tree drifted for {path}: expected={require_tree} actual={tree}")
    return result


def require_external_identity(profile: dict[str, Any]) -> dict[str, Any]:
    external = profile["externalInputs"]
    jpeg_spec = external["axiomRasterCodecJPEG"]
    jpeg_root = (ROOT / jpeg_spec["relativePath"]).resolve()
    jpeg_identity = git_identity(jpeg_root, require_tree=jpeg_spec["tree"])
    if jpeg_identity["revision"] != jpeg_spec["revision"]:
        raise CaptureError("AxiomRasterCodecJPEG revision drifted")
    if jpeg_spec.get("cleanRequired") and not jpeg_identity["clean"]:
        raise CaptureError("AxiomRasterCodecJPEG must be clean")
    fixture_manifest = jpeg_root / jpeg_spec["fixtureManifest"]
    if sha256_file(fixture_manifest) != jpeg_spec["fixtureManifestSHA256"]:
        raise CaptureError("AxiomRasterCodecJPEG fixture manifest drifted")

    raster_spec = external["axiomRaster"]
    raster_root = (ROOT / raster_spec["relativePath"]).resolve()
    raster_identity = git_identity(raster_root)
    if raster_identity["revision"] != raster_spec["revision"]:
        raise CaptureError("AxiomRaster revision drifted")
    if raster_spec.get("cleanRequired") and not raster_identity["clean"]:
        raise CaptureError("AxiomRaster must be clean")

    fixture_hashes: dict[str, str] = {}
    for fixture in profile["fixtures"]:
        path = jpeg_root / fixture["relativePath"]
        actual = sha256_file(path)
        if actual != fixture["sha256"]:
            raise CaptureError(
                f"fixture drifted: {fixture['id']} expected={fixture['sha256']} actual={actual}"
            )
        fixture_hashes[fixture["id"]] = actual

    return {
        "axiomRasterCodecJPEG": jpeg_identity,
        "axiomRaster": raster_identity,
        "fixtureManifest": {
            "path": str(fixture_manifest),
            "sha256": sha256_file(fixture_manifest),
        },
        "fixtureSHA256": fixture_hashes,
    }


def capture_imagecraft_source_identity(destination: Path) -> dict[str, Any]:
    run(
        [
            sys.executable,
            str(ROOT / "Tools/Identity/capture_source_identity.py"),
            "--output",
            str(destination),
        ]
    )
    return load_json(destination)


def build_imagecraft_evidence() -> Path:
    developer_dir = run([str(ROOT / "scripts/select-xcode.sh")]).stdout.strip()
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    run([sys.executable, str(ROOT / "scripts/check-swift-toolchain.py")], env=env)
    run(["swift", "build", "-c", "release", "--product", "ImageCraftEvidence"], env=env)
    bin_dir = Path(run(["swift", "build", "-c", "release", "--show-bin-path"], env=env).stdout.strip())
    binary = bin_dir / "ImageCraftEvidence"
    if not binary.is_file():
        raise CaptureError(f"ImageCraftEvidence binary missing: {binary}")
    return binary


def build_axiom_probe() -> Path:
    manifest = ROOT / "Tools/Quality/AxiomPackedProbe/Cargo.toml"
    env = dict(os.environ)
    target = ROOT / ".build/cross-backend-packed-jpeg/cargo-target"
    env["CARGO_TARGET_DIR"] = str(target)
    run(["cargo", "build", "--manifest-path", str(manifest), "--release", "--locked"], env=env)
    binary = target / "release/imagecraft-axiom-packed-probe"
    if not binary.is_file():
        raise CaptureError(f"Axiom packed probe binary missing: {binary}")
    return binary


def djpeg_identity(spec: dict[str, Any]) -> tuple[Path, str]:
    executable = shutil.which(spec["executable"])
    if executable is None:
        raise CaptureError(f"missing {spec['executable']}")
    result = run([executable, "-version"])
    version = (result.stdout + result.stderr).strip()
    if version != spec["version"]:
        raise CaptureError(f"djpeg version drifted: expected={spec['version']!r} actual={version!r}")
    return Path(executable), version


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    offset = 0

    def token() -> bytes:
        nonlocal offset
        while offset < len(data):
            if data[offset : offset + 1] == b"#":
                while offset < len(data) and data[offset] != 0x0A:
                    offset += 1
            elif chr(data[offset]).isspace():
                offset += 1
            else:
                break
        start = offset
        while offset < len(data) and not chr(data[offset]).isspace():
            offset += 1
        if start == offset:
            raise CaptureError(f"invalid PPM token in {path}")
        return data[start:offset]

    if token() != b"P6":
        raise CaptureError(f"djpeg output is not P6 PPM: {path}")
    width = int(token())
    height = int(token())
    maximum = int(token())
    if maximum != 255:
        raise CaptureError(f"unexpected PPM sample maximum: {maximum}")
    while offset < len(data) and chr(data[offset]).isspace():
        offset += 1
    pixels = data[offset:]
    expected = width * height * 3
    if len(pixels) != expected:
        raise CaptureError(f"PPM payload length mismatch: expected={expected} actual={len(pixels)}")
    return width, height, pixels


def rgba_to_rgb(data: bytes) -> bytes:
    if len(data) % 4:
        raise CaptureError("RGBA payload is not pixel aligned")
    return bytes(value for index, value in enumerate(data) if index % 4 != 3)


def all_alpha_opaque(data: bytes) -> bool:
    return len(data) % 4 == 0 and all(data[index] == 255 for index in range(3, len(data), 4))


def source_pattern(width: int, height: int, pattern: str) -> bytes:
    output = bytearray()
    for y in range(height):
        for x in range(width):
            red = (37 * x + 11 * y + (x * y) % 23) % 256
            green = (13 * x + 41 * y + 7 * (x ^ y)) % 256
            blue = (19 * x + 29 * y + (3 * x + 5 * y) % 31) % 256
            if pattern == "formula-v1-gray":
                gray = (77 * red + 150 * green + 29 * blue + 128) >> 8
                output.extend((gray, gray, gray))
            elif pattern == "formula-v1-rgb":
                output.extend((red, green, blue))
            else:
                raise CaptureError(f"unsupported source pattern: {pattern}")
    return bytes(output)


def vertical_flip_rgb(data: bytes, width: int, height: int) -> bytes:
    row = width * 3
    if len(data) != row * height:
        raise CaptureError("source RGB payload length mismatch")
    return b"".join(data[y * row : (y + 1) * row] for y in reversed(range(height)))


def permute_rgb(data: bytes, permutation: tuple[int, int, int]) -> bytes:
    if len(data) % 3:
        raise CaptureError("RGB payload is not pixel aligned")
    output = bytearray(len(data))
    for offset in range(0, len(data), 3):
        pixel = data[offset : offset + 3]
        output[offset : offset + 3] = bytes(pixel[index] for index in permutation)
    return bytes(output)


def difference_metrics(actual: bytes, reference: bytes) -> dict[str, Any]:
    if len(actual) != len(reference) or not actual:
        raise CaptureError("metric payload length mismatch")
    differences = [abs(left - right) for left, right in zip(actual, reference)]
    squared = sum(value * value for value in differences)
    mse = squared / len(differences)
    return {
        "sampleCount": len(differences),
        "differentSampleCount": sum(value != 0 for value in differences),
        "maximumAbsoluteChannelError": max(differences),
        "meanAbsoluteChannelError": sum(differences) / len(differences),
        "meanSquaredError": mse,
        "psnrDB": None if mse == 0 else 10.0 * math.log10((255.0 * 255.0) / mse),
        "totalAbsoluteChannelError": sum(differences),
    }


def mse_only(actual: bytes, reference: bytes) -> float:
    if len(actual) != len(reference) or not actual:
        raise CaptureError("MSE payload length mismatch")
    return sum((left - right) ** 2 for left, right in zip(actual, reference)) / len(actual)


def spatial_contract_sanity(output: bytes, source: bytes, width: int, height: int, pattern: str) -> dict[str, Any]:
    correct_mse = mse_only(output, source)
    flipped_mse = mse_only(output, vertical_flip_rgb(source, width, height))
    row_order_pass = correct_mse < flipped_mse

    channel_order_pass = True
    permutation_mse: dict[str, float] = {"RGB": correct_mse}
    if pattern == "formula-v1-rgb":
        for permutation in itertools.permutations((0, 1, 2)):
            label = "".join("RGB"[index] for index in permutation)
            candidate = mse_only(output, permute_rgb(source, permutation))
            permutation_mse[label] = candidate
        best = min(permutation_mse, key=permutation_mse.get)
        channel_order_pass = best == "RGB"
    return {
        "rowOrderCorrectMSE": correct_mse,
        "rowOrderVerticalFlipMSE": flipped_mse,
        "topToBottomPreferred": row_order_pass,
        "channelPermutationMSE": dict(sorted(permutation_mse.items())),
        "rgbChannelOrderPreferred": channel_order_pass,
        "passed": row_order_pass and channel_order_pass,
    }


def assert_imagecraft_contract(
    report: dict[str, Any],
    profile: dict[str, Any],
    fixture: dict[str, Any],
    rgba: bytes,
) -> None:
    expected = profile["imageCraftContract"]
    contract = report.get("contract", {})
    for field in ("id", "channelOrder", "bitsPerChannel", "alphaMode", "rowOrder", "colorEncoding"):
        if contract.get(field) != expected[field]:
            raise CaptureError(f"ImageCraft packed contract drifted for {fixture['id']}: {field}")
    if report.get("input", {}).get("sha256") != fixture["sha256"]:
        raise CaptureError(f"ImageCraft input identity drifted for {fixture['id']}")
    if report.get("input", {}).get("format") != "jpeg" or report.get("input", {}).get("orientation") != 1:
        raise CaptureError(f"ImageCraft fixture normalization drifted for {fixture['id']}")
    output = report.get("output", {})
    width = fixture["width"]
    height = fixture["height"]
    expected_bytes = width * height * 4
    if (
        output.get("pixelWidth") != width
        or output.get("pixelHeight") != height
        or output.get("byteCount") != expected_bytes
        or contract.get("bytesPerRow") != width * 4
        or contract.get("transferredByteCharge") != expected_bytes
        or output.get("sha256") != sha256_bytes(rgba)
        or output.get("allAlphaOpaque") is not True
        or not all_alpha_opaque(rgba)
    ):
        raise CaptureError(f"ImageCraft packed layout/alpha drifted for {fixture['id']}")


def assert_axiom_contract(report: dict[str, Any], fixture: dict[str, Any], rgba: bytes) -> None:
    width = fixture["width"]
    height = fixture["height"]
    expected_bytes = width * height * 4
    if (
        report.get("backend") != fixture["expectedAxiomBackend"]
        or report.get("implementation") != "AxiomRasterCodecJPEG.NativeScalar"
        or report.get("pixelContract") != "RGBA8-opaque-top-to-bottom-tight"
        or report.get("width") != width
        or report.get("height") != height
        or report.get("bytesPerRow") != width * 4
        or report.get("byteCount") != expected_bytes
        or report.get("allAlphaOpaque") is not True
        or len(rgba) != expected_bytes
        or not all_alpha_opaque(rgba)
    ):
        raise CaptureError(f"Axiom packed contract drifted for {fixture['id']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--imagecraft-binary", type=Path)
    parser.add_argument("--axiom-probe-binary", type=Path)
    args = parser.parse_args()

    profile = load_json(args.profile.resolve())
    if profile.get("schemaVersion") != 1 or profile.get("profileID") != "imagecraft-axiom-packed-jpeg-v1":
        raise CaptureError("cross-backend profile drifted")
    if profile["qualificationBoundary"].get("productionSecondBackendMayQualify") is not False:
        raise CaptureError("profile may not authorize production qualification")

    with tempfile.TemporaryDirectory(prefix="imagecraft-cross-backend-") as temporary:
        temp = Path(temporary)
        source_before_path = temp / "source-before.json"
        source_after_path = temp / "source-after.json"
        source_before = capture_imagecraft_source_identity(source_before_path)
        external_before = require_external_identity(profile)

        imagecraft_binary = args.imagecraft_binary.resolve() if args.imagecraft_binary else build_imagecraft_evidence()
        axiom_binary = args.axiom_probe_binary.resolve() if args.axiom_probe_binary else build_axiom_probe()
        if not imagecraft_binary.is_file() or not axiom_binary.is_file():
            raise CaptureError("missing comparator binary")

        djpeg_spec = profile["externalInputs"]["libjpegTurbo"]
        djpeg, djpeg_version = djpeg_identity(djpeg_spec)
        jpeg_root = (ROOT / profile["externalInputs"]["axiomRasterCodecJPEG"]["relativePath"]).resolve()

        cases: list[dict[str, Any]] = []
        for fixture in profile["fixtures"]:
            case_root = temp / fixture["id"]
            case_root.mkdir()
            input_path = jpeg_root / fixture["relativePath"]
            imagecraft_rgba_path = case_root / "imagecraft.rgba"
            axiom_rgba_path = case_root / "axiom.rgba"
            djpeg_ppm_path = case_root / "djpeg.ppm"

            imagecraft_result = run(
                [
                    str(imagecraft_binary),
                    "--packed-rgba-export",
                    str(input_path),
                    "--output",
                    str(imagecraft_rgba_path),
                ],
                timeout=120,
            )
            imagecraft_report = parse_json_stdout(imagecraft_result, "ImageCraftEvidence")
            axiom_result = run([str(axiom_binary), str(input_path), str(axiom_rgba_path)], timeout=120)
            axiom_report = parse_json_stdout(axiom_result, "Axiom packed probe")
            run(
                [
                    str(djpeg),
                    "-strict",
                    "-rgb",
                    "-pnm",
                    "-outfile",
                    str(djpeg_ppm_path),
                    str(input_path),
                ],
                timeout=120,
            )

            imagecraft_rgba = imagecraft_rgba_path.read_bytes()
            axiom_rgba = axiom_rgba_path.read_bytes()
            assert_imagecraft_contract(imagecraft_report, profile, fixture, imagecraft_rgba)
            assert_axiom_contract(axiom_report, fixture, axiom_rgba)
            ppm_width, ppm_height, djpeg_rgb = read_ppm(djpeg_ppm_path)
            if (ppm_width, ppm_height) != (fixture["width"], fixture["height"]):
                raise CaptureError(f"djpeg geometry drifted for {fixture['id']}")

            imagecraft_rgb = rgba_to_rgb(imagecraft_rgba)
            axiom_rgb = rgba_to_rgb(axiom_rgba)
            source_rgb = source_pattern(fixture["width"], fixture["height"], fixture["sourcePattern"])
            pairwise = difference_metrics(imagecraft_rgb, axiom_rgb)
            legacy = profile["legacyT68PixelGate"]
            legacy_pass = (
                pairwise["maximumAbsoluteChannelError"] <= legacy["maximumAbsoluteChannelError"]
                and pairwise["meanAbsoluteChannelError"] <= legacy["maximumMeanAbsoluteChannelError"]
            )
            imagecraft_sanity = spatial_contract_sanity(
                imagecraft_rgb,
                source_rgb,
                fixture["width"],
                fixture["height"],
                fixture["sourcePattern"],
            )
            axiom_sanity = spatial_contract_sanity(
                axiom_rgb,
                source_rgb,
                fixture["width"],
                fixture["height"],
                fixture["sourcePattern"],
            )
            representation_pass = imagecraft_sanity["passed"] and axiom_sanity["passed"]
            if not representation_pass:
                raise CaptureError(f"packed representation spatial/channel sanity failed for {fixture['id']}")

            cases.append(
                {
                    "id": fixture["id"],
                    "sampling": fixture["sampling"],
                    "fixture": {
                        "path": fixture["relativePath"],
                        "sha256": fixture["sha256"],
                        "byteCount": input_path.stat().st_size,
                        "width": fixture["width"],
                        "height": fixture["height"],
                        "sourcePattern": fixture["sourcePattern"],
                    },
                    "representationContract": {
                        "passed": representation_pass,
                        "imageCraft": imagecraft_sanity,
                        "axiom": axiom_sanity,
                    },
                    "imageCraft": {
                        "observation": imagecraft_report,
                        "rgbaSHA256": sha256_bytes(imagecraft_rgba),
                    },
                    "axiom": {
                        "observation": axiom_report,
                        "rgbaSHA256": sha256_bytes(axiom_rgba),
                    },
                    "libjpegTurbo": {
                        "rgbSHA256": sha256_bytes(djpeg_rgb),
                    },
                    "reconstructionDiagnostics": {
                        "imageCraftVsAxiom": pairwise,
                        "imageCraftVsLibjpegTurbo": difference_metrics(imagecraft_rgb, djpeg_rgb),
                        "axiomVsLibjpegTurbo": difference_metrics(axiom_rgb, djpeg_rgb),
                        "imageCraftVsSourcePattern": difference_metrics(imagecraft_rgb, source_rgb),
                        "axiomVsSourcePattern": difference_metrics(axiom_rgb, source_rgb),
                        "libjpegTurboVsSourcePattern": difference_metrics(djpeg_rgb, source_rgb),
                    },
                    "legacyT68PixelGate": {
                        "passed": legacy_pass,
                        "maximumAbsoluteChannelError": legacy["maximumAbsoluteChannelError"],
                        "maximumMeanAbsoluteChannelError": legacy["maximumMeanAbsoluteChannelError"],
                    },
                }
            )

        source_after = capture_imagecraft_source_identity(source_after_path)
        source_stable = source_before == source_after
        if not source_stable:
            raise CaptureError(
                "ImageCraft source identity drifted during cross-backend capture: "
                f"before={source_before.get('sourceIdentitySHA256')} "
                f"after={source_after.get('sourceIdentitySHA256')}"
            )
        external_after = require_external_identity(profile)
        if external_before != external_after:
            raise CaptureError("external source identity drifted during capture")

        representation_pass = all(case["representationContract"]["passed"] for case in cases)
        legacy_pass_count = sum(case["legacyT68PixelGate"]["passed"] for case in cases)
        binaries_built_by_capture = args.imagecraft_binary is None and args.axiom_probe_binary is None
        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": (
                "source-bound-representation-contract-pressure"
                if binaries_built_by_capture
                else "functional-smoke-unverified-binary-binding"
            ),
            "profile": {
                "path": str(args.profile.resolve()),
                "sha256": sha256_file(args.profile.resolve()),
                "profileID": profile["profileID"],
            },
            "sourceIdentity": {
                "fileCount": source_before["fileCount"],
                "sourceIdentitySHA256": source_before["sourceIdentitySHA256"],
                "stableBeforeAfter": True,
            },
            "externalInputs": {
                **external_before,
                "libjpegTurbo": {
                    "path": str(djpeg),
                    "version": djpeg_version,
                    "mode": djpeg_spec["mode"],
                },
            },
            "binaries": {
                "imageCraftEvidence": {
                    "path": str(imagecraft_binary),
                    "sha256": sha256_file(imagecraft_binary),
                },
                "axiomPackedProbe": {
                    "path": str(axiom_binary),
                    "sha256": sha256_file(axiom_binary),
                },
            },
            "summary": {
                "fixtureCount": len(cases),
                "allRepresentationContractsPass": representation_pass,
                "legacyT68PixelGatePassedFixtureCount": legacy_pass_count,
                "legacyT68PixelGateFailedFixtureCount": len(cases) - legacy_pass_count,
                "legacyT68PixelGateAllPass": legacy_pass_count == len(cases),
                "binariesBuiltByCapture": binaries_built_by_capture,
                "formalSourceBoundExecution": binaries_built_by_capture,
                "productionSecondBackendQualified": False,
                "productionQualificationBlockedBy": (
                    "no independently justified preregistered lossy JPEG reconstruction policy; "
                    "this experiment does not widen T68's frozen pixel thresholds"
                ),
            },
            "cases": cases,
            "claimBoundary": [
                "packed representation semantics are evaluated separately from lossy JPEG reconstruction equality",
                "pairwise pixel deltas and source/libjpeg fidelity metrics are observations, not post-hoc qualification thresholds",
                "the legacy T68 pixel gate is retained unchanged and may remain negative",
                "AxiomRasterCodecJPEG and AxiomRaster are clean read-only pinned inputs",
                "Fovea is not read or modified by this capture",
                "this report does not qualify or publish a production second backend",
                "provided comparator binaries produce functional smoke evidence only; formal source-bound execution requires binaries rebuilt by this capture",
            ],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Cross-backend packed JPEG: "
            f"representation={representation_pass} legacyPixel={legacy_pass_count}/{len(cases)} "
            f"source={source_before['sourceIdentitySHA256']} output={args.output}"
        )
        return 0 if representation_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
