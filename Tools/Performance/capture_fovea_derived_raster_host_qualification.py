#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_IMAGECRAFT_REPORTS = ROOT / ".artifacts/performance/derived-raster-host-v6"
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/derived-raster-fovea-host-v1/formal-report.json"
EVIDENCE_VERSION = "imagecraft-fovea-derived-raster-host-v1"

FOVEA_MECHANISM_FILES = (
    "Package.swift",
    "Sources/FoveaCore/DerivedRasterAdmissionPolicy.swift",
    "Sources/FoveaCore/DerivedRasterContainer.swift",
    "Sources/FoveaCore/DerivedRasterCreationCoordinator.swift",
    "Sources/FoveaCore/DerivedRasterLoadCoordinator.swift",
    "Sources/FoveaCore/DerivedRasterPixelBridge.swift",
    "Sources/FoveaCore/DerivedRasterRuntime.swift",
    "Sources/FoveaCore/DerivedRasterRuntimeTypes.swift",
    "Sources/FoveaPersistence/AkashicDerivedRasterStore.swift",
    "Sources/FoveaStorage/DerivedRasterStorage.swift",
    "Tools/FoveaDerivedRasterLab/DerivedRasterBenchmarkSupport.swift",
    "Tools/FoveaDerivedRasterLab/DerivedRasterPixelSupport.swift",
    "Tools/FoveaDerivedRasterLab/DerivedRasterWriteAccountingLab.swift",
    "Tools/FoveaDerivedRasterLab/FoveaDerivedRasterLabMain.swift",
)

FOVEA_COPY_EXCLUDES = frozenset(
    {
        ".git",
        ".build",
        ".scratch",
        ".artifacts",
        ".swiftpm",
        ".workflow",
        "__pycache__",
        ".DS_Store",
    }
)


class QualificationError(RuntimeError):
    pass


def run(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: int = 600,
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
    if completed.returncode != 0:
        raise QualificationError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_sha256(value: object) -> str:
    return sha256_bytes(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )


def capture_imagecraft_identity(output: Path) -> dict[str, Any]:
    run(
        [
            "python3",
            str(ROOT / "Tools/Identity/capture_source_identity.py"),
            "--output",
            str(output),
        ],
        cwd=ROOT,
        timeout=120,
    )
    return json.loads(output.read_text())


def mechanism_audit(root: Path) -> dict[str, Any]:
    entries: list[dict[str, object]] = []
    for relative in FOVEA_MECHANISM_FILES:
        path = root / relative
        if not path.is_file():
            raise QualificationError(f"missing Fovea mechanism source: {relative}")
        entries.append(
            {
                "path": relative,
                "byteCount": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return {
        "identitySHA256": canonical_sha256(entries),
        "files": entries,
    }


def git_head(root: Path) -> str | None:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", value) else None


def copy_fovea(source: Path, destination: Path) -> None:
    def ignored(_: str, names: list[str]) -> set[str]:
        return {name for name in names if name in FOVEA_COPY_EXCLUDES}

    shutil.copytree(source, destination, ignore=ignored)


def rebind_imagecraft(package_manifest: Path) -> dict[str, str]:
    original = package_manifest.read_text()
    pattern = re.compile(
        r'''(?ms)^\s*\.package\(\s*\n\s*url:\s*"https://github\.com/YuLeiFuYun/ImageCraft\.git",\s*\n\s*revision:\s*"([0-9a-f]{40})"\s*\n\s*\),'''
    )
    match = pattern.search(original)
    if match is None:
        raise QualificationError("Fovea ImageCraft remote dependency shape is not recognized")
    local_path = str(ROOT).replace("\\", "\\\\").replace('"', '\\"')
    replacement = f'        .package(name: "ImageCraft", path: "{local_path}"),'
    rebound, count = pattern.subn(replacement, original, count=1)
    if count != 1:
        raise QualificationError("Fovea ImageCraft dependency rebind was ambiguous")
    package_manifest.write_text(rebound)
    return {
        "remoteRevision": match.group(1),
        "originalManifestSHA256": sha256_bytes(original.encode("utf-8")),
        "reboundManifestSHA256": sha256_bytes(rebound.encode("utf-8")),
    }


def parse_fovea_host_contract(container_source: Path) -> dict[str, object]:
    source = container_source.read_text()
    expected_fragments = (
        'identifier: "fovea-chunked-lzfse-rgb8"',
        "semanticVersion: 7",
        'pixelLayoutFingerprint: "rgb8-srgb-tight-chunked-1m-lzfse-v7"',
        "package static let currentSchemaVersion: UInt16 = 7",
        "package static let headerByteCount = 120",
        "package static let decodedChunkByteCount = 1_024 * 1_024",
        "let compressed = try DerivedRasterContainerCodec.compress(",
        "for chunkIndex in compressed.compressedChunkRanges.indices",
    )
    missing = [fragment for fragment in expected_fragments if fragment not in source]
    if missing:
        raise QualificationError("Fovea host contract drifted: " + repr(missing))
    return {
        "formatIdentifier": "fovea-chunked-lzfse-rgb8",
        "formatSemanticVersion": 7,
        "pixelLayoutFingerprint": "rgb8-srgb-tight-chunked-1m-lzfse-v7",
        "containerSchemaVersion": 7,
        "headerByteCount": 120,
        "decodedChunkByteCount": 1_024 * 1_024,
        "compression": "LZFSE-per-decoded-chunk",
        "lazyDecodeEvidenceSourceBound": True,
    }


def load_selector_reports(directory: Path, fixture_root: Path) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.json")):
        report = json.loads(path.read_text())
        name = path.stem
        input_path = fixture_root / f"{name}.jpg"
        if not input_path.is_file():
            raise QualificationError(f"missing selector input fixture: {input_path}")
        if sha256_file(input_path) != report.get("inputSHA256"):
            raise QualificationError(f"selector input digest mismatch: {name}")
        if input_path.stat().st_size != report.get("inputByteCount"):
            raise QualificationError(f"selector input byte count mismatch: {name}")
        targets = report.get("targets")
        if not isinstance(targets, list) or not targets:
            raise QualificationError(f"selector report has no targets: {name}")
        reports.append(
            {
                "name": name,
                "path": path,
                "inputPath": input_path,
                "report": report,
            }
        )
    if not reports:
        raise QualificationError(f"no ImageCraft selector reports found in {directory}")
    return reports


def vector_rows(reports: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for source in reports:
        report = source["report"]
        for target in report["targets"]:
            qualifications = target.get("artifactQualifications")
            if not isinstance(qualifications, list) or len(qualifications) != 3:
                raise QualificationError("selector artifact qualification shape drifted")
            exact_formats = {
                item.get("format")
                for item in qualifications
                if item.get("exactPixelIdentity") is True
            }
            if len(exact_formats) != 3:
                raise QualificationError("selector candidate lost exact-pixel identity")
            selected = target.get("storageEfficientFormat")
            if selected not in exact_formats:
                raise QualificationError("storage selector selected an unqualified format")
            minimum = min(
                (int(item["payloadByteCount"]), str(item["format"]))
                for item in qualifications
            )
            if target.get("storageEfficientPayloadByteCount") != minimum[0] or selected != minimum[1]:
                raise QualificationError("storage selector is not the actual payload minimum")
            rows.append(
                {
                    "source": source,
                    "target": target,
                    "selectorFormat": selected,
                    "selectorPayloadByteCount": minimum[0],
                }
            )
    return rows


def select_representatives(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    representatives: dict[str, dict[str, Any]] = {}
    for row in rows:
        representatives.setdefault(row["selectorFormat"], row)
    return [representatives[key] for key in sorted(representatives)]


def positive_median(report: dict[str, Any], key: str) -> int:
    value = report.get(key)
    if not isinstance(value, dict):
        raise QualificationError(f"Fovea lab missing duration summary: {key}")
    median = value.get("medianNanoseconds")
    if not isinstance(median, int) or median <= 0:
        raise QualificationError(f"Fovea lab duration is not positive: {key}")
    return median


def qualify_vector(
    row: dict[str, Any],
    *,
    binary: Path,
    output_directory: Path,
    iterations: int,
    env: dict[str, str],
) -> dict[str, Any]:
    source = row["source"]
    target = row["target"]
    output = output_directory / (
        f"{source['name']}-{target['requestedWidth']}x{target['requestedHeight']}.json"
    )
    completed = run(
        [
            str(binary),
            "--input",
            str(source["inputPath"]),
            "--output",
            str(output),
            "--target-width",
            str(target["requestedWidth"]),
            "--target-height",
            str(target["requestedHeight"]),
            "--iterations",
            str(iterations),
        ],
        cwd=binary.parent,
        env=env,
        timeout=600,
    )
    if completed.stdout.strip() or completed.stderr.strip():
        raise QualificationError("Fovea lab unexpectedly emitted terminal output")
    report = json.loads(output.read_text())
    expected_input_sha = source["report"]["inputSHA256"]
    if report.get("inputSHA256") != expected_input_sha:
        raise QualificationError("Fovea lab input digest diverged from ImageCraft selector input")
    for key in ("targetWidth", "targetHeight", "outputWidth", "outputHeight"):
        expected = {
            "targetWidth": target["requestedWidth"],
            "targetHeight": target["requestedHeight"],
            "outputWidth": target["outputWidth"],
            "outputHeight": target["outputHeight"],
        }[key]
        if report.get(key) != expected:
            raise QualificationError(f"Fovea geometry mismatch at {key}")
    pixel_match = report.get("outputRGBSHA256") == target.get("directPixelRGBSHA256")
    if not pixel_match:
        raise QualificationError("Fovea/ImageCraft exact RGB digest mismatch")
    lazy_medians = {
        key: positive_median(report, key)
        for key in (
            "lazyCompressedBridgeConstruction",
            "lazyCompressedBridgeDisplayReady",
            "lazyCompressedBridgeW2Materialization",
            "packedRGB24LazyCompressedBridgeW2Materialization",
        )
    }
    persistence_medians = {
        key: positive_median(report, key)
        for key in (
            "akashicLoadAndDecode",
            "akashicLoadDecodeAndDisplayReady",
        )
    }
    if not isinstance(report.get("containerByteCount"), int) or report["containerByteCount"] <= 120:
        raise QualificationError("Fovea host container is implausibly small")
    if not re.fullmatch(r"[0-9a-f]{64}", str(report.get("containerSHA256", ""))):
        raise QualificationError("Fovea host container digest is malformed")
    return {
        "source": source["name"],
        "inputSHA256": expected_input_sha,
        "requestedWidth": target["requestedWidth"],
        "requestedHeight": target["requestedHeight"],
        "outputWidth": target["outputWidth"],
        "outputHeight": target["outputHeight"],
        "outputRGBSHA256": report["outputRGBSHA256"],
        "imageCraftStorageEfficientFormat": row["selectorFormat"],
        "imageCraftStorageEfficientPayloadByteCount": row["selectorPayloadByteCount"],
        "imageCraftReuseDecisions": target["reuseDecisions"],
        "foveaHostContainerByteCount": report["containerByteCount"],
        "foveaHostContainerSHA256": report["containerSHA256"],
        "foveaPNGComparisonByteCount": report["pngByteCount"],
        "exactRGBDigestMatch": pixel_match,
        "lazyBridgeMediansNanoseconds": lazy_medians,
        "akashicPersistenceMediansNanoseconds": persistence_medians,
        "foveaLabReportSHA256": sha256_file(output),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fovea-root", type=Path, required=True)
    parser.add_argument("--selector-reports", type=Path, default=DEFAULT_IMAGECRAFT_REPORTS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument(
        "--representatives-only",
        action="store_true",
        help="run one Fovea host vector per observed ImageCraft storage-selector format",
    )
    args = parser.parse_args()
    if not (1 <= args.iterations <= 20):
        parser.error("--iterations must be within 1...20")

    fovea_root = args.fovea_root.resolve()
    if not (fovea_root / "Package.swift").is_file():
        parser.error("--fovea-root is not a Swift package")
    fixture_root = ROOT / "Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources"
    reports = load_selector_reports(args.selector_reports.resolve(), fixture_root)
    all_rows = vector_rows(reports)
    selector_formats = sorted({row["selectorFormat"] for row in all_rows})
    if len(selector_formats) < 2:
        raise QualificationError("current selector corpus does not exercise content-varying formats")
    rows = select_representatives(all_rows) if args.representatives_only else all_rows

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="imagecraft-fovea-derived-raster-") as directory:
        temporary = Path(directory)
        identity_before = capture_imagecraft_identity(temporary / "imagecraft-before.json")
        fovea_before = mechanism_audit(fovea_root)
        host_contract = parse_fovea_host_contract(
            fovea_root / "Sources/FoveaCore/DerivedRasterContainer.swift"
        )

        fovea_copy = temporary / "Fovea"
        copy_fovea(fovea_root, fovea_copy)
        copied_audit = mechanism_audit(fovea_copy)
        if copied_audit != fovea_before:
            raise QualificationError("Fovea mechanism bytes changed while materializing copy")
        rebind = rebind_imagecraft(fovea_copy / "Package.swift")

        developer = run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            timeout=30,
        ).stdout.strip()
        if not developer:
            raise QualificationError("Xcode selection returned an empty developer path")
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = developer
        swift = run(["xcrun", "--find", "swift"], cwd=ROOT, env=env, timeout=30).stdout.strip()
        run(
            [
                swift,
                "build",
                "--package-path",
                str(fovea_copy),
                "-c",
                "release",
                "--product",
                "FoveaDerivedRasterLab",
                "--jobs",
                "3",
            ],
            cwd=fovea_copy,
            env=env,
            timeout=600,
        )
        bin_path = Path(
            run(
                [swift, "build", "--package-path", str(fovea_copy), "-c", "release", "--show-bin-path"],
                cwd=fovea_copy,
                env=env,
                timeout=120,
            ).stdout.strip()
        )
        binary = bin_path / "FoveaDerivedRasterLab"
        if not binary.is_file():
            raise QualificationError("FoveaDerivedRasterLab binary is missing after build")

        lab_outputs = temporary / "LabReports"
        lab_outputs.mkdir()
        qualified = [
            qualify_vector(
                row,
                binary=binary,
                output_directory=lab_outputs,
                iterations=args.iterations,
                env=env,
            )
            for row in rows
        ]

        if mechanism_audit(fovea_root) != fovea_before:
            raise QualificationError("Fovea mechanism source changed during qualification")
        identity_after = capture_imagecraft_identity(temporary / "imagecraft-after.json")
        if identity_before != identity_after:
            raise QualificationError("ImageCraft source identity changed during qualification")

        format_counts: dict[str, int] = {}
        for row in all_rows:
            format_counts[row["selectorFormat"]] = format_counts.get(row["selectorFormat"], 0) + 1
        qualified_formats = sorted({row["imageCraftStorageEfficientFormat"] for row in qualified})
        if args.representatives_only and qualified_formats != selector_formats:
            raise QualificationError("representative execution missed an observed selector format")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-host-qualification",
            "claimBoundary": [
                "ImageCraft storage-efficient format selection remains a policy/evidence dimension; it does not rename or directly persist an ImageCraft candidate payload as a Fovea container.",
                "Fovea host storage remains its package-owned chunked LZFSE RGB8 v7 container with 1 MiB decoded chunks, proven by exact mechanism-source binding and live host-lab execution.",
                "Exact RGB equality is required between the current ImageCraft selector vector and the current-ImageCraft-rebound Fovea host lab for every executed vector.",
                "Lazy compressed bridge and Akashic-backed load/decode paths must execute with positive measured duration; timing values are observations, not product latency thresholds.",
                "When representativesOnly is true, live host execution covers one vector per observed selector-format bucket while the format-invariant Fovea container contract is source-bound; this is not an exhaustive per-vector performance qualification.",
                "No public derived-surface API or default storage-policy promotion is implied.",
            ],
            "imageCraftSourceIdentity": {
                "sourceIdentitySHA256": identity_before["sourceIdentitySHA256"],
                "fileCount": identity_before["fileCount"],
                "stableBeforeAfter": True,
            },
            "selectorCorpus": {
                "reportDirectory": str(args.selector_reports.resolve().relative_to(ROOT)),
                "sourceReportCount": len(reports),
                "vectorCount": len(all_rows),
                "observedStorageEfficientFormats": selector_formats,
                "formatCounts": format_counts,
            },
            "fovea": {
                "gitHEAD": git_head(fovea_root),
                "mechanismIdentitySHA256": fovea_before["identitySHA256"],
                "mechanismFiles": fovea_before["files"],
                "hostContainerContract": host_contract,
                "temporaryImageCraftRebind": rebind,
                "baseWorktreeMutated": False,
            },
            "execution": {
                "representativesOnly": args.representatives_only,
                "measuredIterationsPerFoveaVector": args.iterations,
                "qualifiedVectorCount": len(qualified),
                "qualifiedSelectorFormats": qualified_formats,
            },
            "vectors": qualified,
            "summary": {
                "allExactRGBDigestsMatch": all(row["exactRGBDigestMatch"] for row in qualified),
                "allObservedSelectorFormatsRepresented": qualified_formats == selector_formats,
                "foveaHostFormatInvariant": True,
                "foveaLazyBridgeExecuted": all(row["lazyBridgeMediansNanoseconds"] for row in qualified),
                "foveaAkashicPersistenceExecuted": all(
                    row["akashicPersistenceMediansNanoseconds"] for row in qualified
                ),
            },
        }
        args.output.write_text(
            json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        )
        print(
            "Fovea derived-raster host qualification passed: "
            f"source={identity_before['sourceIdentitySHA256']} "
            f"selectorVectors={len(all_rows)} hostVectors={len(qualified)} "
            f"formats={','.join(selector_formats)} output={args.output}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
