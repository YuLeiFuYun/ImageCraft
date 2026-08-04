#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
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
from validate_progressive_pipeline_profile import validate as validate_profile  # noqa: E402

EXPECTED_COMMIT = "04c8ad2984ef94ad31d4bd386e2d06bdddf58304"
EXPECTED_TREE = "cf2582f1bb5bcd2821dde8dc9b86560d98debfa9"
EXPECTED_EXPERIMENT_ID = "progressive-jpeg-pipeline-simulation-v1"
EXPECTED_PROFILE_VERSION = "imagecraft-progressive-pipeline-profile-v1"
EXPECTED_SIMULATION_VERSION = "imagecraft-progressive-pipeline-simulation-v1"
EXPECTED_CASES = {
    "decode-pressure-80mbps-32k--immediate--complete",
    "decode-pressure-80mbps-32k--immediate--cancel",
    "decode-pressure-80mbps-32k--frame-coalesced-60hz--complete",
    "decode-pressure-80mbps-32k--frame-coalesced-60hz--cancel",
    "network-dominant-4mbps-16k--immediate--complete",
    "network-dominant-4mbps-16k--immediate--cancel",
    "network-dominant-4mbps-16k--frame-coalesced-60hz--complete",
    "network-dominant-4mbps-16k--frame-coalesced-60hz--cancel",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def profile_findings(profile: dict[str, Any]) -> dict[str, Any]:
    summary = profile["summary"]
    decode_median = summary["finalDecodeDuration"]["medianNanoseconds"]
    handoff_median = summary["finalMainActorHandoff"]["medianNanoseconds"]
    return {
        "caseID": profile["caseID"],
        "chunkSizeBytes": profile["chunkSizeBytes"],
        "chunkCount": profile["chunkCount"],
        "iterations": profile["iterations"],
        "generationSequence": summary["generationSequence"],
        "generationSourceByteCounts": summary["generationSourceByteCounts"],
        "finalDecodeDuration": summary["finalDecodeDuration"],
        "finalMainActorHandoff": summary["finalMainActorHandoff"],
        "totalDuration": summary["totalDuration"],
        "finalHandoffToDecodeMedianPPM": handoff_median * 1_000_000 // decode_median,
    }


def derive_findings(
    profile_16k: dict[str, Any],
    profile_32k: dict[str, Any],
    simulation: dict[str, Any],
) -> dict[str, Any]:
    by_id = {case["caseID"]: case for case in simulation["cases"]}
    require(set(by_id) == EXPECTED_CASES, "simulation case set mismatch")
    return {
        "measuredProfiles": {
            "chunk16K": profile_findings(profile_16k),
            "chunk32K": profile_findings(profile_32k),
        },
        "simulationCaseSummaries": {
            case_id: by_id[case_id]["summary"] for case_id in sorted(by_id)
        },
    }


def rebuild_simulation(profile_16k_path: Path, profile_32k_path: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [
            sys.executable,
            str(ROOT / "Tools/Performance/simulate_progressive_pipeline.py"),
            "--profile-16k",
            str(profile_16k_path),
            "--profile-32k",
            str(profile_32k_path),
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def validate_simulation(simulation: dict[str, Any]) -> None:
    require(simulation.get("schemaVersion") == 1, "unsupported simulation schema")
    require(
        simulation.get("simulationVersion") == EXPECTED_SIMULATION_VERSION,
        "unexpected simulation version",
    )
    require(simulation.get("frameIntervalNanoseconds") == 16_666_667, "frame interval drifted")
    cases = simulation.get("cases")
    require(isinstance(cases, list), "simulation cases must be a list")
    by_id = {case.get("caseID"): case for case in cases}
    require(set(by_id) == EXPECTED_CASES and len(by_id) == len(cases), "simulation case set mismatch")
    for case_id, case in by_id.items():
        samples = case.get("samples")
        summary = case.get("summary")
        require(isinstance(samples, list) and len(samples) == 7, f"{case_id}: sample count mismatch")
        require(isinstance(summary, dict) and summary.get("sampleCount") == 7, f"{case_id}: summary count mismatch")
        is_cancel = case_id.endswith("--cancel")
        require(
            summary.get("completionCount") == (0 if is_cancel else 7),
            f"{case_id}: completion count mismatch",
        )
        if is_cancel:
            require(
                case.get("cancellationMode")
                == "fence-presentation-at-request; session-cancel-completes-after-in-flight-append",
                f"{case_id}: cancellation semantics drifted",
            )
        else:
            require(case.get("cancellationMode") == "none", f"{case_id}: unexpected cancellation mode")

    boundary = simulation.get("modelBoundary", {})
    require(
        "Core Animation commit" in boundary.get("notMeasured", [])
        and "GPU presentation" in boundary.get("notMeasured", []),
        "simulation must disclose missing display presentation",
    )
    require(
        "exact encoded-byte arrival times" in boundary.get("simulated", []),
        "simulation must label network arrivals as simulated",
    )


def validate(path: Path) -> None:
    experiment = json.loads(path.read_text(encoding="utf-8"))
    require(experiment.get("schemaVersion") == 1, "unsupported pipeline experiment schema")
    require(experiment.get("experimentID") == EXPECTED_EXPERIMENT_ID, "unexpected pipeline experiment identity")

    artifacts = experiment.get("artifacts", {})
    require(
        set(artifacts) == {"manifest", "profile16K", "profile32K", "simulation"},
        "pipeline artifact set mismatch",
    )
    manifest_meta = artifacts["manifest"]
    manifest_path = resolve_repository_path(manifest_meta["path"])
    require(sha256(manifest_path) == manifest_meta.get("sha256"), "pipeline manifest digest mismatch")

    profile16_meta = artifacts["profile16K"]
    profile16_path = resolve_repository_path(profile16_meta["path"])
    require(sha256(profile16_path) == profile16_meta.get("sha256"), "16K profile digest mismatch")
    profile16 = json.loads(profile16_path.read_text(encoding="utf-8"))
    validate_profile(profile16)

    profile32_meta = artifacts["profile32K"]
    profile32_path = resolve_repository_path(profile32_meta["path"])
    require(sha256(profile32_path) == profile32_meta.get("sha256"), "32K profile digest mismatch")
    profile32 = json.loads(profile32_path.read_text(encoding="utf-8"))
    validate_profile(profile32)

    require(profile16.get("profileVersion") == EXPECTED_PROFILE_VERSION, "16K profile version mismatch")
    require(profile32.get("profileVersion") == EXPECTED_PROFILE_VERSION, "32K profile version mismatch")
    require(profile16.get("chunkSizeBytes") == 16_384, "16K profile chunk size mismatch")
    require(profile32.get("chunkSizeBytes") == 32_768, "32K profile chunk size mismatch")
    require(profile16.get("iterations") == profile32.get("iterations") == 7, "profile iteration count mismatch")
    for field in ("runtime", "environment", "decoderFingerprint", "encodedSHA256", "encodedByteCount"):
        require(profile16.get(field) == profile32.get(field), f"profile identity drifted at {field}")
    require(profile16.get("manifestSHA256") == manifest_meta["sha256"], "16K manifest binding mismatch")
    require(profile32.get("manifestSHA256") == manifest_meta["sha256"], "32K manifest binding mismatch")

    simulation_meta = artifacts["simulation"]
    simulation_path = resolve_repository_path(simulation_meta["path"])
    require(sha256(simulation_path) == simulation_meta.get("sha256"), "simulation digest mismatch")
    simulation = json.loads(simulation_path.read_text(encoding="utf-8"))
    validate_simulation(simulation)
    require(
        simulation == rebuild_simulation(profile16_path, profile32_path),
        "pipeline simulation is not reproducible from profiles",
    )
    require(simulation["input"]["encodedSHA256"] == profile16["encodedSHA256"], "simulation input digest mismatch")

    implementation = experiment.get("implementation", {})
    require(implementation.get("commit") == EXPECTED_COMMIT, "unexpected pipeline implementation commit")
    require(implementation.get("commitTree") == EXPECTED_TREE, "unexpected pipeline implementation tree")
    require(implementation.get("cleanWorktreeAtCapture") is True, "pipeline capture was not clean")
    identity_path = resolve_repository_path(implementation["sourceIdentityReportPath"])
    require(sha256(identity_path) == implementation.get("sourceIdentityReportSHA256"), "pipeline source identity digest mismatch")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    require(canonical_source_identity(identity) == identity.get("sourceIdentitySHA256"), "pipeline source identity is inconsistent")
    for field, value in {
        "sourceIdentitySchemaVersion": identity["schemaVersion"],
        "sourceIdentityID": identity["identityID"],
        "sourceIdentityFileCount": identity["fileCount"],
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
    }.items():
        require(implementation.get(field) == value, f"pipeline implementation mismatch: {field}")
    validate_git_binding(EXPECTED_COMMIT, EXPECTED_TREE, identity)

    environment = experiment.get("environment", {})
    for field in ("runtime", "environment", "decoderFingerprint"):
        require(environment.get(field) == profile16.get(field), f"pipeline environment drifted at {field}")

    methodology = experiment.get("methodology", {})
    require(methodology.get("measuredIterationsPerProfile") == 7, "pipeline methodology iteration count drifted")
    require(methodology.get("warmupIterationsPerProfile") == 1, "pipeline methodology warmup drifted")
    require(methodology.get("profileChunkSizesBytes") == [16_384, 32_768], "pipeline chunk matrix drifted")
    require(methodology.get("mainActorBoundaryIsScreenPresentation") is False, "pipeline must not claim screen presentation")
    require(methodology.get("networkArrivalTimesAreMeasured") is False, "pipeline must label network arrival as simulated")

    expected_findings = derive_findings(profile16, profile32, simulation)
    require(experiment.get("findings") == expected_findings, "pipeline findings are not reproducible")

    interpretation = experiment.get("interpretation", {})
    require(interpretation.get("mainActorHandoffIsScreenPresentation") is False, "pipeline interpretation overclaims presentation")
    require(interpretation.get("simulationIsProductionNetworkProof") is False, "pipeline interpretation overclaims network proof")
    require(interpretation.get("frameCoalescingUniversallyBeneficial") is False, "pipeline interpretation overclaims coalescing")

    decision = experiment.get("decision", {})
    require(decision.get("passed") is True, "pipeline qualification failed")
    require(decision.get("changeCodecThresholds") is False, "pipeline must not silently change codec thresholds")
    require(decision.get("addPresentationPolicyToCodec") is False, "presentation policy must not enter codec boundary")
    require(decision.get("supportedClaims") and decision.get("unsupportedClaims"), "pipeline claim boundary incomplete")
    require(experiment.get("remainingEvidence"), "pipeline remaining evidence missing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    validate(args.experiment)
    print(f"Progressive JPEG pipeline experiment passed: {args.experiment}")


if __name__ == "__main__":
    main()
