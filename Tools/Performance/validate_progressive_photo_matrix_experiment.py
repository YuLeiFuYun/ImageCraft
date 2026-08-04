#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import subprocess
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_progressive_experiment import (  # noqa: E402
    ROOT,
    canonical_source_identity,
    resolve_repository_path,
    sha256,
    validate_git_binding,
)

EXPECTED_COMMIT = "75acd9279304077ba4ba44fe42af1b03aa8009fe"
EXPECTED_TREE = "33d535515b11cd42eaae94648e556b6b6d7f35f5"
EXPECTED_EXPERIMENT_ID = "progressive-jpeg-real-photo-scan-matrix-v1"
EXPECTED_MATRIX_VERSION = "imagecraft-progressive-photo-matrix-v1"
EXPECTED_EVIDENCE_VERSION = "imagecraft-progressive-photo-corpus-v1"
EXPECTED_CHUNK_SIZES = (1_024, 32_768)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expected_raw_names(manifest: dict[str, Any]) -> set[str]:
    return {
        f"{variant['id']}--chunk-{chunk}-{suffix}.json"
        for variant in manifest["variants"]
        for chunk in EXPECTED_CHUNK_SIZES
        for suffix in ("a", "b")
    }


def expected_scaled_ratio(value: int, multiplier: int, divisor: int) -> int:
    require(value >= 0 and divisor > 0, "invalid fixed-point ratio input")
    return value * multiplier // divisor


def validate_metrics(
    case_id: str,
    generation: dict[str, Any],
    expected_channel_count: int,
) -> None:
    metrics = generation.get("metricsAgainstFinal", {})
    channel_count = metrics.get("channelCount")
    require(channel_count == expected_channel_count, f"{case_id}: channel count mismatch")
    different = metrics.get("differentChannelCount")
    maximum = metrics.get("maximumAbsoluteError")
    absolute_sum = metrics.get("absoluteErrorSum")
    squared_sum = metrics.get("squaredErrorSum")
    require(isinstance(different, int) and 0 <= different <= channel_count, f"{case_id}: invalid different-channel count")
    require(isinstance(maximum, int) and 0 <= maximum <= 255, f"{case_id}: invalid maximum error")
    require(isinstance(absolute_sum, int) and 0 <= absolute_sum <= 255 * channel_count, f"{case_id}: invalid absolute-error sum")
    require(isinstance(squared_sum, int) and 0 <= squared_sum <= 255 * 255 * channel_count, f"{case_id}: invalid squared-error sum")
    expected_mae = expected_scaled_ratio(absolute_sum, 1_000_000, channel_count)
    expected_mse = expected_scaled_ratio(squared_sum, 1_000_000, channel_count)
    require(metrics.get("meanAbsoluteErrorMicrounits") == expected_mae, f"{case_id}: MAE is not reproducible")
    require(metrics.get("meanSquaredErrorMicrounits") == expected_mse, f"{case_id}: MSE is not reproducible")
    mse = squared_sum / channel_count
    expected_psnr = 999.0 if mse == 0 else 10.0 * math.log10((255.0 * 255.0) / mse)
    require(metrics.get("psnrMicrodecibels") == round(expected_psnr * 1_000_000), f"{case_id}: PSNR is not reproducible")
    coverages = [
        metrics.get("absoluteErrorAtMost8PPM"),
        metrics.get("absoluteErrorAtMost16PPM"),
        metrics.get("absoluteErrorAtMost32PPM"),
        metrics.get("absoluteErrorAtMost64PPM"),
    ]
    require(all(isinstance(value, int) and 0 <= value <= 1_000_000 for value in coverages), f"{case_id}: invalid coverage")
    require(coverages == sorted(coverages), f"{case_id}: error coverage is not monotone")
    require(isinstance(generation.get("pixelRGBSHA256"), str) and len(generation["pixelRGBSHA256"]) == 64, f"{case_id}: missing pixel digest")


def validate_case(report: dict[str, Any], manifest_hash: str) -> None:
    case_id = report.get("caseID", "unknown")
    require(report.get("schemaVersion") == 1, f"{case_id}: unsupported schema")
    require(report.get("evidenceVersion") == EXPECTED_EVIDENCE_VERSION, f"{case_id}: evidence version mismatch")
    require(report.get("buildConfiguration") == "release", f"{case_id}: not a Release capture")
    require(report.get("manifestSHA256") == manifest_hash, f"{case_id}: manifest mismatch")
    require(report.get("chunkSizeBytes") in EXPECTED_CHUNK_SIZES, f"{case_id}: unexpected chunk size")
    encoded_count = report.get("encodedByteCount")
    chunk_size = report["chunkSizeBytes"]
    require(isinstance(encoded_count, int) and encoded_count > 0, f"{case_id}: invalid encoded count")
    require(report.get("chunkCount") == (encoded_count + chunk_size - 1) // chunk_size, f"{case_id}: chunk count mismatch")
    require(isinstance(report.get("encodedSHA256"), str) and len(report["encodedSHA256"]) == 64, f"{case_id}: missing encoded digest")
    width = report.get("outputPixelWidth")
    height = report.get("outputPixelHeight")
    require(isinstance(width, int) and width > 0 and isinstance(height, int) and height > 0, f"{case_id}: invalid output dimensions")
    require(isinstance(report.get("finalPixelRGBSHA256"), str) and len(report["finalPixelRGBSHA256"]) == 64, f"{case_id}: missing final pixel digest")
    generations = report.get("generations")
    require(isinstance(generations, list) and 1 <= len(generations) <= 4, f"{case_id}: invalid generation count")
    require([item.get("generation") for item in generations] == list(range(1, len(generations) + 1)), f"{case_id}: generation sequence mismatch")
    source_counts = [item.get("sourceByteCount") for item in generations]
    require(all(isinstance(value, int) and 0 < value <= encoded_count for value in source_counts), f"{case_id}: invalid generation byte count")
    require(source_counts == sorted(source_counts) and len(set(source_counts)) == len(source_counts), f"{case_id}: generation byte counts are not strict")
    for generation in generations:
        source_count = generation["sourceByteCount"]
        require(source_count == encoded_count or source_count % chunk_size == 0, f"{case_id}: generation is not on an append boundary")
        require(generation.get("encodedByteFractionPPM") == source_count * 1_000_000 // encoded_count, f"{case_id}: byte fraction mismatch")
        validate_metrics(case_id, generation, width * height * 3)


def derive_findings(cases: list[dict[str, Any]]) -> dict[str, Any]:
    generation_distribution: dict[str, dict[str, dict[str, int]]] = defaultdict(lambda: defaultdict(dict))
    for script_id in sorted({case["scanScriptID"] for case in cases}):
        for chunk in EXPECTED_CHUNK_SIZES:
            counts = Counter(
                len(case["generations"])
                for case in cases
                if case["scanScriptID"] == script_id and case["chunkSizeBytes"] == chunk
            )
            generation_distribution[script_id][str(chunk)] = {
                str(count): frequency for count, frequency in sorted(counts.items())
            }

    last_preview_ranges: dict[str, dict[str, dict[str, int]]] = {}
    for script_id in sorted({case["scanScriptID"] for case in cases}):
        last = [case["generations"][-1] for case in cases if case["scanScriptID"] == script_id]
        last_preview_ranges[script_id] = {
            "encodedByteFractionPPM": {
                "minimum": min(item["encodedByteFractionPPM"] for item in last),
                "maximum": max(item["encodedByteFractionPPM"] for item in last),
            },
            "psnrMicrodecibels": {
                "minimum": min(item["metricsAgainstFinal"]["psnrMicrodecibels"] for item in last),
                "maximum": max(item["metricsAgainstFinal"]["psnrMicrodecibels"] for item in last),
            },
            "meanAbsoluteErrorMicrounits": {
                "minimum": min(item["metricsAgainstFinal"]["meanAbsoluteErrorMicrounits"] for item in last),
                "maximum": max(item["metricsAgainstFinal"]["meanAbsoluteErrorMicrounits"] for item in last),
            },
            "maximumAbsoluteError": {
                "minimum": min(item["metricsAgainstFinal"]["maximumAbsoluteError"] for item in last),
                "maximum": max(item["metricsAgainstFinal"]["maximumAbsoluteError"] for item in last),
            },
        }

    by_variant: dict[tuple[str, str], dict[int, dict[str, Any]]] = defaultdict(dict)
    for case in cases:
        by_variant[(case["sourceID"], case["scanScriptID"])][case["chunkSizeBytes"]] = case
    comparisons = []
    for (source_id, script_id), schedules in sorted(by_variant.items()):
        require(set(schedules) == set(EXPECTED_CHUNK_SIZES), "missing chunk schedule comparison")
        small = schedules[1_024]
        large = schedules[32_768]
        common = min(len(small["generations"]), len(large["generations"]))
        per_generation = []
        for index in range(common):
            left = small["generations"][index]
            right = large["generations"][index]
            per_generation.append(
                {
                    "generation": index + 1,
                    "encodedByteFractionDifferencePPM": abs(left["encodedByteFractionPPM"] - right["encodedByteFractionPPM"]),
                    "psnrDifferenceMicrodecibels": abs(left["metricsAgainstFinal"]["psnrMicrodecibels"] - right["metricsAgainstFinal"]["psnrMicrodecibels"]),
                    "meanAbsoluteErrorDifferenceMicrounits": abs(left["metricsAgainstFinal"]["meanAbsoluteErrorMicrounits"] - right["metricsAgainstFinal"]["meanAbsoluteErrorMicrounits"]),
                    "pixelRGBExactMatch": left["pixelRGBSHA256"] == right["pixelRGBSHA256"],
                }
            )
        comparisons.append(
            {
                "sourceID": source_id,
                "scanScriptID": script_id,
                "generationCountChunk1024": len(small["generations"]),
                "generationCountChunk32768": len(large["generations"]),
                "generationCountEqual": len(small["generations"]) == len(large["generations"]),
                "commonGenerationCount": common,
                "perGeneration": per_generation,
            }
        )

    case_map = {case["caseID"]: case for case in cases}
    landscape_luma = case_map[
        "landscape-coconino-sunflowers--luma-frontloaded-v1--chunk-1024"
    ]["generations"][-1]
    landscape_default_small = case_map[
        "landscape-coconino-sunflowers--default-successive-v1--chunk-1024"
    ]["generations"][-1]
    landscape_default_large = case_map[
        "landscape-coconino-sunflowers--default-successive-v1--chunk-32768"
    ]["generations"][-1]
    cow_default_small = case_map[
        "animal-usda-cow-sunset--default-successive-v1--chunk-1024"
    ]
    cow_default_large = case_map[
        "animal-usda-cow-sunset--default-successive-v1--chunk-32768"
    ]
    counterexamples = {
        "lumaFrontloadedNearEndCanRemainFarFromFinal": {
            "caseID": "landscape-coconino-sunflowers--luma-frontloaded-v1--chunk-1024",
            "lastGeneration": landscape_luma,
        },
        "sameGenerationOrdinalCanChangeMateriallyWithChunkOvershoot": {
            "sourceID": "landscape-coconino-sunflowers",
            "scanScriptID": "default-successive-v1",
            "generation": landscape_default_small["generation"],
            "chunk1024": landscape_default_small,
            "chunk32768": landscape_default_large,
            "psnrDifferenceMicrodecibels": abs(
                landscape_default_small["metricsAgainstFinal"]["psnrMicrodecibels"]
                - landscape_default_large["metricsAgainstFinal"]["psnrMicrodecibels"]
            ),
        },
        "chunkScheduleCanChangeGenerationCount": {
            "sourceID": "animal-usda-cow-sunset",
            "scanScriptID": "default-successive-v1",
            "generationCountChunk1024": len(cow_default_small["generations"]),
            "generationCountChunk32768": len(cow_default_large["generations"]),
        },
    }
    return {
        "generationCountDistribution": {
            script: dict(chunks) for script, chunks in generation_distribution.items()
        },
        "lastPreviewRangesByScanScript": last_preview_ranges,
        "chunkScheduleComparisons": comparisons,
        "counterexamples": counterexamples,
    }


def rebuild_aggregate(manifest_path_text: str, raw_paths: list[Path]) -> dict[str, Any]:
    completed = subprocess.run(
        [
            sys.executable,
            str(ROOT / "Tools/Performance/aggregate_progressive_photo_matrix.py"),
            "--manifest",
            manifest_path_text,
            *[str(path) for path in raw_paths],
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def validate(path: Path) -> None:
    experiment = json.loads(path.read_text(encoding="utf-8"))
    require(experiment.get("schemaVersion") == 1, "unsupported photo-matrix experiment schema")
    require(experiment.get("experimentID") == EXPECTED_EXPERIMENT_ID, "unexpected photo-matrix experiment identity")

    artifacts = experiment.get("artifacts", {})
    require(set(artifacts) == {"manifest", "aggregate", "rawReports"}, "photo-matrix artifact set mismatch")
    manifest_meta = artifacts["manifest"]
    manifest_path = resolve_repository_path(manifest_meta["path"])
    require(sha256(manifest_path) == manifest_meta.get("sha256"), "photo corpus manifest digest mismatch")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(manifest.get("corpusVersion") == "progressive-real-photo-v1", "photo corpus version mismatch")

    aggregate_meta = artifacts["aggregate"]
    aggregate_path = resolve_repository_path(aggregate_meta["path"])
    require(sha256(aggregate_path) == aggregate_meta.get("sha256"), "photo matrix aggregate digest mismatch")
    aggregate = json.loads(aggregate_path.read_text(encoding="utf-8"))
    require(aggregate.get("matrixVersion") == EXPECTED_MATRIX_VERSION, "photo matrix version mismatch")

    raw_meta = artifacts["rawReports"]
    expected_names = expected_raw_names(manifest)
    require(set(raw_meta) == expected_names, "photo matrix raw artifact set mismatch")
    raw_paths: dict[str, Path] = {}
    raw_bytes: dict[str, bytes] = {}
    for name, metadata in raw_meta.items():
        report_path = resolve_repository_path(metadata["path"])
        require(sha256(report_path) == metadata.get("sha256"), f"raw report digest mismatch: {name}")
        raw_paths[name] = report_path
        raw_bytes[name] = report_path.read_bytes()
        validate_case(json.loads(raw_bytes[name]), manifest_meta["sha256"])
    for name in sorted(expected_names):
        if not name.endswith("-a.json"):
            continue
        other = name[:-7] + "-b.json"
        require(raw_bytes[name] == raw_bytes[other], f"repeated execution drifted: {name}")

    rebuilt = rebuild_aggregate(manifest_meta["path"], [raw_paths[name] for name in sorted(raw_paths)])
    require(aggregate == rebuilt, "photo matrix aggregate is not reproducible")

    implementation = experiment.get("implementation", {})
    require(implementation.get("commit") == EXPECTED_COMMIT, "unexpected photo-matrix implementation commit")
    require(implementation.get("commitTree") == EXPECTED_TREE, "unexpected photo-matrix implementation tree")
    require(implementation.get("cleanWorktreeAtCapture") is True, "photo matrix capture was not clean")
    identity_path = resolve_repository_path(implementation["sourceIdentityReportPath"])
    require(sha256(identity_path) == implementation.get("sourceIdentityReportSHA256"), "photo matrix source-identity digest mismatch")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    require(canonical_source_identity(identity) == identity.get("sourceIdentitySHA256"), "photo matrix source identity is inconsistent")
    expected_identity = {
        "sourceIdentitySchemaVersion": identity["schemaVersion"],
        "sourceIdentityID": identity["identityID"],
        "sourceIdentityFileCount": identity["fileCount"],
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
    }
    for field, value in expected_identity.items():
        require(implementation.get(field) == value, f"photo matrix implementation mismatch: {field}")
    validate_git_binding(EXPECTED_COMMIT, EXPECTED_TREE, identity)

    environment = experiment.get("environment", {})
    for field in ("runtime", "environment", "decoderFingerprint"):
        require(environment.get(field) == aggregate.get(field), f"photo matrix environment drifted at {field}")

    methodology = experiment.get("methodology", {})
    expected_methodology = {
        "matrixVersion": EXPECTED_MATRIX_VERSION,
        "evidenceVersion": EXPECTED_EVIDENCE_VERSION,
        "buildConfiguration": "release",
        "sourceCount": 4,
        "scanScriptCount": 3,
        "chunkSizesBytes": list(EXPECTED_CHUNK_SIZES),
        "caseCount": 24,
        "executionsPerCase": 2,
        "reference": "complete ImageIO decode of the same encoded JPEG",
        "analysisSurface": "deterministic sRGB RGB8 channel metrics",
        "timingMeasured": False,
    }
    require(methodology == expected_methodology, "photo matrix methodology drifted")

    expected_findings = derive_findings(aggregate["cases"])
    require(experiment.get("findings") == expected_findings, "photo matrix findings are not reproducible")

    interpretation = experiment.get("interpretation", {})
    require("descriptive" in interpretation.get("ruleTiming", ""), "photo matrix must disclose descriptive rule timing")
    require(interpretation.get("generationOrdinalHasCrossSessionQualityMeaning") is False, "generation ordinal must not acquire cross-session quality semantics")
    require(interpretation.get("psnrIsPerceptualUsabilityProof") is False, "PSNR must not be treated as usability proof")

    decision = experiment.get("decision", {})
    require(decision.get("passed") is True, "photo matrix structural qualification failed")
    require(decision.get("qualification") == "evidence matrix is reproducible; no scan policy is universally qualified", "photo matrix qualification drifted")
    require(decision.get("supportedClaims") and decision.get("unsupportedClaims"), "photo matrix claim boundary is incomplete")
    require(experiment.get("remainingEvidence"), "photo matrix remaining evidence is missing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    validate(args.experiment)
    print(f"Progressive JPEG real-photo matrix passed: {args.experiment}")


if __name__ == "__main__":
    main()
