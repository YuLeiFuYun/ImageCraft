#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentPNG/v3/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/quality/independent-png-v3/formal-report.json"
EVIDENCE_VERSION = "imagecraft-independent-png-conformance-v3"


class CaptureError(RuntimeError):
    pass


def run(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path = ROOT,
    timeout: int = 900,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0 and not allow_failure:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def png_has_chunk(data: bytes, chunk_type: bytes) -> bool:
    if len(chunk_type) != 4 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise CaptureError("invalid PNG while checking chunk authority")
    offset = 8
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise CaptureError("truncated PNG while checking chunk authority")
        if data[offset + 4 : offset + 8] == chunk_type:
            return True
        if data[offset + 4 : offset + 8] == b"IEND":
            return False
        offset = chunk_end
    raise CaptureError("PNG missing IEND while checking chunk authority")


def capture_source_identity(path: Path) -> dict[str, Any]:
    run(
        [
            sys.executable,
            str(ROOT / "Tools/Identity/capture_source_identity.py"),
            "--output",
            str(path),
        ]
    )
    return json.loads(path.read_text())


def premultiply(straight: bytes) -> bytes:
    if len(straight) % 4:
        raise CaptureError("straight RGBA length is not divisible by four")
    output = bytearray(len(straight))
    for offset in range(0, len(straight), 4):
        alpha = straight[offset + 3]
        if alpha == 0:
            output[offset : offset + 3] = b"\x00\x00\x00"
        elif alpha == 255:
            output[offset : offset + 3] = straight[offset : offset + 3]
        else:
            output[offset] = (straight[offset] * alpha + 127) // 255
            output[offset + 1] = (straight[offset + 1] * alpha + 127) // 255
            output[offset + 2] = (straight[offset + 2] * alpha + 127) // 255
        output[offset + 3] = alpha
    return bytes(output)


def swift_flags(developer_dir: str) -> tuple[str, str, list[str]]:
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    swiftc = str(Path(developer_dir) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env).stdout.strip()
    architecture = platform.machine()
    target = f"{architecture}-apple-macos12.0"
    common = [
        "-O",
        "-sdk",
        sdk,
        "-target",
        target,
        "-package-name",
        "ImageCraft",
        "-enable-upcoming-feature",
        "InferIsolatedConformances",
        "-enable-upcoming-feature",
        "NonisolatedNonsendingByDefault",
    ]
    return swiftc, target, common


def build_swift_probe(build: Path, developer_dir: str) -> Path:
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    swiftc, _, common = swift_flags(developer_dir)
    core_sources = sorted(str(path) for path in (ROOT / "Sources/ImageCraftCore").glob("*.swift"))
    imageio_sources = sorted(str(path) for path in (ROOT / "Sources/ImageCraftImageIO").glob("*.swift"))
    core_module = build / "ImageCraftCore.swiftmodule"
    imageio_module = build / "ImageCraftImageIO.swiftmodule"
    core_library = build / "libImageCraftCore.dylib"
    imageio_library = build / "libImageCraftImageIO.dylib"
    run(
        [
            swiftc,
            *common,
            "-parse-as-library",
            "-module-name",
            "ImageCraftCore",
            "-emit-module",
            "-emit-module-path",
            str(core_module),
            "-emit-library",
            "-o",
            str(core_library),
            *core_sources,
        ],
        env=env,
    )
    run(
        [
            swiftc,
            *common,
            "-parse-as-library",
            "-module-name",
            "ImageCraftImageIO",
            "-I",
            str(build),
            "-L",
            str(build),
            "-lImageCraftCore",
            "-emit-module",
            "-emit-module-path",
            str(imageio_module),
            "-emit-library",
            "-o",
            str(imageio_library),
            *imageio_sources,
        ],
        env=env,
    )
    probe = build / "ImageCraftIndependentPNGProbe"
    run(
        [
            swiftc,
            *common,
            "-I",
            str(build),
            "-L",
            str(build),
            "-lImageCraftCore",
            "-lImageCraftImageIO",
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            str(build),
            str(ROOT / "Tools/Quality/IndependentPNGProbe/main.swift"),
            "-o",
            str(probe),
        ],
        env=env,
    )
    return probe


def build_libpng_probe(build: Path) -> tuple[Path, str]:
    config = run(["libpng-config", "--version"])
    version = config.stdout.strip()
    cflags = shlex.split(run(["libpng-config", "--cflags"]).stdout.strip())
    ldflags = shlex.split(run(["libpng-config", "--ldflags"]).stdout.strip())
    binary = build / "libpng-rgba-probe"
    run(
        [
            "cc",
            "-O2",
            "-Wall",
            "-Wextra",
            *cflags,
            str(ROOT / "Tools/Quality/LibPNGRGBAProbe/main.c"),
            *ldflags,
            "-o",
            str(binary),
        ]
    )
    return binary, version


def parse_json_stdout(completed: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CaptureError(f"invalid JSON from {label}: {completed.stdout!r}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    args.profile = args.profile.resolve()
    try:
        args.profile.relative_to(ROOT)
    except ValueError as error:
        raise CaptureError("conformance profile must be inside the ImageCraft source tree") from error
    profile = json.loads(args.profile.read_text())
    schema_version = int(profile.get("schemaVersion", 0))
    if schema_version not in (1, 2, 3):
        raise CaptureError("invalid conformance profile schema")
    evidence_version = f"imagecraft-independent-png-conformance-v{schema_version}"
    if not isinstance(profile.get("successCases"), list) or not profile["successCases"]:
        raise CaptureError("conformance profile must define success cases")
    if not isinstance(profile.get("hostileCases"), list):
        raise CaptureError("conformance profile hostileCases must be a list")
    case_ids = [case.get("id") for case in profile["successCases"] + profile["hostileCases"]]
    if any(not isinstance(case_id, str) or not case_id for case_id in case_ids):
        raise CaptureError("conformance profile case IDs must be non-empty strings")
    if len(case_ids) != len(set(case_ids)):
        raise CaptureError("conformance profile case IDs must be globally unique")
    operation_budget_bytes = profile.get("operationBudgetBytes")
    if not isinstance(operation_budget_bytes, int) or operation_budget_bytes <= 0:
        raise CaptureError("conformance profile must define a positive operationBudgetBytes")

    with tempfile.TemporaryDirectory(prefix="imagecraft-independent-png-") as temp_dir:
        temp = Path(temp_dir)
        build = temp / "build"
        corpus = temp / "corpus"
        outputs = temp / "outputs"
        build.mkdir()
        corpus.mkdir()
        outputs.mkdir()

        before = capture_source_identity(temp / "source-before.json")
        developer_dir = run([str(ROOT / "scripts/select-xcode.sh")]).stdout.strip()
        env = dict(os.environ)
        env["DEVELOPER_DIR"] = developer_dir
        run([sys.executable, str(ROOT / "scripts/check-swift-toolchain.py")], env=env)
        run(
            ["swift", "test", "--scratch-path", str(temp / "swiftpm"), "--jobs", "1"],
            env=env,
        )

        swift_probe = build_swift_probe(build, developer_dir)
        libpng_probe, libpng_version = build_libpng_probe(build)
        run(
            [
                sys.executable,
                str(ROOT / "Tools/Quality/generate_independent_png_corpus.py"),
                "--profile",
                str(args.profile),
                "--output-dir",
                str(corpus),
            ]
        )
        manifest_path = corpus / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("profileID") != profile.get("profileID"):
            raise CaptureError("generated corpus profile drifted")

        success_results: list[dict[str, Any]] = []
        for case in manifest["successCases"]:
            interlace = case.get("interlace", 0)
            if interlace not in (0, 1):
                raise CaptureError(f"success case has invalid PNG interlace method: {case['id']}")
            if interlace == 1 and case.get("sourceFormat", "rgba8") != "rgba8":
                raise CaptureError(f"Adam7 success case is outside qualified RGBA8 slice: {case['id']}")
            if case.get("sourceFormat") == "indexed8":
                indexed_bit_depth = case.get("indexedBitDepth")
                if indexed_bit_depth not in (1, 2, 4, 8):
                    raise CaptureError(
                        f"indexed success case lacks a qualified bit depth: {case['id']}"
                    )
            if case.get("sourceFormat") in ("gray1", "gray2", "gray4", "gray8"):
                grayscale_bit_depth = case.get("grayscaleBitDepth")
                if grayscale_bit_depth not in (1, 2, 4, 8):
                    raise CaptureError(
                        f"grayscale success case lacks a qualified bit depth: {case['id']}"
                    )
            png = corpus / case["path"]
            straight = corpus / case["straightRGBAPath"]
            expected_premultiplied = corpus / case["premultipliedRGBAPath"]
            libpng_output = outputs / f"{case['id']}.libpng.rgba"
            imagecraft_output = outputs / f"{case['id']}.imagecraft.rgba"

            libpng_run = run([str(libpng_probe), str(png), str(libpng_output)])
            libpng_report = parse_json_stdout(libpng_run, f"libpng/{case['id']}")
            expected_color_encoding = str(case.get("expectedColorEncoding", "sRGB"))
            require_libpng_srgb = bool(
                case.get("requireLibPNGSRGBClassification", expected_color_encoding == "sRGB")
            )
            if require_libpng_srgb and libpng_report.get("colorspaceNotSRGB") is not False:
                raise CaptureError(f"libpng did not classify explicit-sRGB source as sRGB: {case['id']}")
            expected_srgb_chunk = case.get("expectedSRGBChunkPresence")
            if expected_srgb_chunk is not None:
                actual_srgb_chunk = png_has_chunk(png.read_bytes(), b"sRGB")
                if actual_srgb_chunk is not bool(expected_srgb_chunk):
                    raise CaptureError(f"PNG sRGB chunk authority drifted: {case['id']}")
            if libpng_report.get("associatedAlpha") is not False:
                raise CaptureError(f"libpng straight-source oracle unexpectedly associated alpha: {case['id']}")
            if libpng_report.get("warningOrError") != 0:
                raise CaptureError(f"libpng emitted warning/error for success case: {case['id']}")
            libpng_bytes = libpng_output.read_bytes()
            source_bytes = straight.read_bytes()
            if libpng_bytes != source_bytes:
                raise CaptureError(f"libpng differs from deterministic source: {case['id']}")
            independently_premultiplied = premultiply(libpng_bytes)
            if independently_premultiplied != expected_premultiplied.read_bytes():
                raise CaptureError(f"premultiply oracle drifted: {case['id']}")

            imagecraft_run = run(
                [
                    str(swift_probe),
                    str(png),
                    str(case["width"]),
                    str(case["height"]),
                    str(operation_budget_bytes),
                    str(imagecraft_output),
                    str(case.get("colorPolicy", "preserveSource")),
                ]
            )
            imagecraft_report = parse_json_stdout(imagecraft_run, f"ImageCraft/{case['id']}")
            if imagecraft_report.get("status") != "success":
                raise CaptureError(f"ImageCraft unexpectedly failed: {case['id']}")
            imagecraft_bytes = imagecraft_output.read_bytes()
            if imagecraft_bytes != independently_premultiplied:
                raise CaptureError(f"ImageCraft packed pixels differ from independent oracle: {case['id']}")
            expected_bytes = int(case["width"]) * int(case["height"]) * 4
            if len(imagecraft_bytes) != expected_bytes:
                raise CaptureError(f"ImageCraft packed byte count drifted: {case['id']}")
            if imagecraft_report.get("transferredByteChargeUpperBound") != expected_bytes:
                raise CaptureError(f"ImageCraft transfer charge drifted: {case['id']}")
            if imagecraft_report.get("packedTransferredByteCharge") != expected_bytes:
                raise CaptureError(f"ImageCraft packed transfer charge drifted: {case['id']}")
            if imagecraft_report.get("outputLayoutAuthority") != "codecOwnedRGBA8":
                raise CaptureError(f"ImageCraft output-layout authority drifted: {case['id']}")
            if imagecraft_report.get("packedColorEncoding") != expected_color_encoding:
                raise CaptureError(f"ImageCraft packed color authority drifted: {case['id']}")
            if imagecraft_report.get("packedEmbeddedICCByteCount") != 0:
                raise CaptureError(f"ImageCraft unexpectedly retained ICC bytes: {case['id']}")
            expected_source_profile = str(
                case.get("expectedSourceColorProfile", "standardSRGB")
            )
            if imagecraft_report.get("packedSourceColorProfile") != expected_source_profile:
                raise CaptureError(f"ImageCraft source color provenance drifted: {case['id']}")
            if expected_color_encoding == "cICP":
                expected_cicp = case.get("cicp")
                actual_cicp = imagecraft_report.get("packedCICP")
                if not isinstance(expected_cicp, list) or len(expected_cicp) != 4:
                    raise CaptureError(f"cICP success case lacks expected tuple: {case['id']}")
                expected_cicp_report = {
                    "colorPrimaries": int(expected_cicp[0]),
                    "transferFunction": int(expected_cicp[1]),
                    "matrixCoefficients": int(expected_cicp[2]),
                    "videoFullRangeFlag": int(expected_cicp[3]),
                }
                if actual_cicp != expected_cicp_report:
                    raise CaptureError(f"ImageCraft cICP tuple drifted: {case['id']}")
            elif imagecraft_report.get("packedCICP") is not None:
                raise CaptureError(f"non-cICP success case published cICP tuple: {case['id']}")
            operation_bound = imagecraft_report.get("operationByteChargeUpperBound")
            if not isinstance(operation_bound, int) or not (
                0 < operation_bound <= operation_budget_bytes
            ):
                raise CaptureError(f"ImageCraft operation bound invalid: {case['id']}")

            success_results.append(
                {
                    "id": case["id"],
                    "sourceFormat": case.get("sourceFormat", "rgba8"),
                    "width": case["width"],
                    "height": case["height"],
                    "filters": case["filters"],
                    "splitIDAT": case["splitIDAT"],
                    "interlace": case.get("interlace", 0),
                    "suggestedPLTE": bool(case.get("suggestedPLTE", False)),
                    "suggestedHIST": bool(case.get("suggestedHIST", False)),
                    "transparentGray16": case.get("transparentGray16"),
                    "transparentRGB16": case.get("transparentRGB16"),
                    "colorPolicy": str(case.get("colorPolicy", "preserveSource")),
                    "expectedColorEncoding": expected_color_encoding,
                    "expectedSourceColorProfile": expected_source_profile,
                    "requireLibPNGSRGBClassification": case.get(
                        "requireLibPNGSRGBClassification"
                    ),
                    "expectedSRGBChunkPresence": case.get("expectedSRGBChunkPresence"),
                    "cicp": case.get("cicp"),
                    "grayscaleBitDepth": case.get("grayscaleBitDepth"),
                    "indexedBitDepth": case.get("indexedBitDepth"),
                    "indexedPaletteEntryCount": case.get("indexedPaletteEntryCount"),
                    "indexedAlphaCount": case.get("indexedAlphaCount"),
                    "pngSHA256": case["pngSHA256"],
                    "straightRGBASHA256": sha256_bytes(source_bytes),
                    "packedRGBASHA256": sha256_bytes(imagecraft_bytes),
                    "libpng": libpng_report,
                    "imageCraft": imagecraft_report,
                    "sourceStraightExact": True,
                    "packedPremultipliedExact": True,
                }
            )

        hostile_results: list[dict[str, Any]] = []
        for case in manifest["hostileCases"]:
            png = corpus / case["path"]
            output = outputs / f"{case['id']}.rgba"
            completed = run(
                [
                    str(swift_probe),
                    str(png),
                    str(case["width"]),
                    str(case["height"]),
                    str(case["operationBudgetBytes"]),
                    str(output),
                ],
                allow_failure=True,
            )
            report = parse_json_stdout(completed, f"hostile/{case['id']}")
            if completed.returncode == 0 or report.get("status") != "error":
                raise CaptureError(f"hostile case did not fail closed: {case['id']}")
            if output.exists():
                raise CaptureError(f"hostile case published bytes: {case['id']}")
            hostile_results.append(
                {
                    "id": case["id"],
                    "mutation": case["mutation"],
                    "pngSHA256": case["pngSHA256"],
                    "error": report.get("error"),
                    "failedClosed": True,
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        if before != after:
            raise CaptureError(
                "source identity drifted during independent PNG capture: "
                f"before={before.get('sourceIdentitySHA256')} "
                f"after={after.get('sourceIdentitySHA256')}"
            )

        report = {
            "schemaVersion": schema_version,
            "evidenceVersion": evidence_version,
            "status": "source-bound-conformance",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "sourceIdentity": {
                "fileCount": before["fileCount"],
                "sourceIdentitySHA256": before["sourceIdentitySHA256"],
                "stableBeforeAfter": True,
            },
            "profile": {
                "path": str(args.profile.relative_to(ROOT)),
                "sha256": sha256_file(args.profile),
                "profileID": profile["profileID"],
            },
            "generatedCorpus": {
                "manifestSHA256": sha256_file(manifest_path),
                "successCaseCount": len(success_results),
                "hostileCaseCount": len(hostile_results),
            },
            "oracles": {
                "libpngVersion": libpng_version,
                "pythonVersion": platform.python_version(),
            },
            "binaries": {
                "imageCraftProbeSHA256": sha256_file(swift_probe),
                "libpngProbeSHA256": sha256_file(libpng_probe),
                "builtInsideCapture": True,
            },
            "operationBudgetBytes": operation_budget_bytes,
            "successCases": success_results,
            "hostileCases": hostile_results,
            "summary": {
                "successCasesExact": len(success_results),
                "hostileCasesFailedClosed": len(hostile_results),
                "representationContractPassed": len(success_results) == len(profile["successCases"]),
                "hostileContractPassed": len(hostile_results) == len(profile["hostileCases"]),
            },
            "claimBoundary": profile["claimBoundary"]
            + [
                "the operation bound is an ImageCraft payload admission charge, not physical RSS",
                "qualification is limited to the exact source formats, ancillary semantics and constraints enumerated by this profile; Adam7 remains limited to the explicit RGBA8+sRGB slice, while 16-bit, other interlaced source types and animated PNG are not promoted by this evidence",
            ],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Independent PNG conformance captured: "
            f"source={before['sourceIdentitySHA256']} output={args.output}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
