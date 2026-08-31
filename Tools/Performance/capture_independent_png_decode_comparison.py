#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentPNGPerformance/v1/profile.json"
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/performance/independent-png-decode-comparison-v1/formal-report.json"
)
EVIDENCE_VERSION = "imagecraft-independent-png-decode-comparison-aggregate-v1"
RUN_EVIDENCE_VERSION = "imagecraft-independent-png-decode-comparison-v1"


class CaptureError(RuntimeError):
    pass


def run(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = 900,
) -> str:
    completed = subprocess.run(
        argv,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed.stdout


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def build_release(scratch: Path) -> tuple[Path, dict[str, str], dict[str, str]]:
    developer_dir = run([str(ROOT / "scripts/select-xcode.sh")]).strip()
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    run([sys.executable, str(ROOT / "scripts/check-swift-toolchain.py")], env=env)
    run(["swift", "test", "--scratch-path", str(scratch), "--jobs", "1"], env=env)
    run(
        [
            "swift",
            "build",
            "-c",
            "release",
            "--scratch-path",
            str(scratch),
            "--product",
            "ImageCraftEvidence",
            "--jobs",
            "1",
        ],
        env=env,
    )
    bin_dir = Path(
        run(
            ["swift", "build", "-c", "release", "--scratch-path", str(scratch), "--show-bin-path"],
            env=env,
        ).strip()
    )
    binary = bin_dir / "ImageCraftEvidence"
    if not binary.is_file():
        raise CaptureError(f"missing ImageCraftEvidence binary: {binary}")
    return binary, env, {"DEVELOPER_DIR": developer_dir}


def parse_run(
    binary: Path,
    case: dict[str, Any],
    png: Path,
    operation_budget_bytes: int,
    iterations: int,
    env: dict[str, str],
    expected_binary_sha256: str,
) -> dict[str, Any]:
    if sha256_file(binary) != expected_binary_sha256:
        raise CaptureError(f"evidence binary drifted before run for {case['id']}")
    raw = run(
        [
            str(binary),
            "--independent-png-decode-comparison",
            str(png),
            "--width",
            str(case["width"]),
            "--height",
            str(case["height"]),
            "--operation-budget",
            str(operation_budget_bytes),
            "--iterations",
            str(iterations),
        ],
        env=env,
        timeout=180,
    )
    if sha256_file(binary) != expected_binary_sha256:
        raise CaptureError(f"evidence binary drifted during run for {case['id']}")
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as error:
        raise CaptureError(f"invalid evidence JSON for {case['id']}: {error}") from error
    if report.get("evidenceVersion") != RUN_EVIDENCE_VERSION:
        raise CaptureError(f"evidence version drifted for {case['id']}")
    if report.get("pixelWidth") != case["width"] or report.get("pixelHeight") != case["height"]:
        raise CaptureError(f"dimension drifted for {case['id']}")
    if report.get("iterationsPerImplementation") != iterations:
        raise CaptureError(f"iteration count drifted for {case['id']}")
    if report.get("warmupIterationsPerImplementation") != 2:
        raise CaptureError(f"warmup count drifted for {case['id']}")
    if report.get("alternatingOrder") is not True:
        raise CaptureError(f"alternating order drifted for {case['id']}")
    if report.get("exactPackedOutputMatch") is not True:
        raise CaptureError(f"packed output did not match exactly for {case['id']}")
    if report.get("independentOperationBudgetBytes") != operation_budget_bytes:
        raise CaptureError(f"operation budget drifted for {case['id']}")
    for key in ("independent", "imageIO"):
        samples = report[key].get("samplesNanoseconds")
        if not isinstance(samples, list) or len(samples) != iterations or any(
            not isinstance(value, int) or value <= 0 for value in samples
        ):
            raise CaptureError(f"invalid samples for {case['id']}/{key}")
    operation_bound = report.get("independentOperationByteChargeUpperBound")
    if not isinstance(operation_bound, int) or not (
        0 < operation_bound <= operation_budget_bytes
    ):
        raise CaptureError(f"invalid operation bound for {case['id']}")
    return report


def invariant_projection(report: dict[str, Any]) -> dict[str, Any]:
    return {
        "runtime": report["runtime"],
        "environment": report["environment"],
        "imageIODecoderFingerprint": report["imageIODecoderFingerprint"],
        "inputByteCount": report["inputByteCount"],
        "inputSHA256": report["inputSHA256"],
        "pixelWidth": report["pixelWidth"],
        "pixelHeight": report["pixelHeight"],
        "outputByteCount": report["outputByteCount"],
        "outputSHA256": report["outputSHA256"],
        "independentOperationBudgetBytes": report["independentOperationBudgetBytes"],
        "independentOperationByteChargeUpperBound": report[
            "independentOperationByteChargeUpperBound"
        ],
    }


def aggregate_case(case: dict[str, Any], reports: list[dict[str, Any]]) -> dict[str, Any]:
    reference = invariant_projection(reports[0])
    for report in reports[1:]:
        if invariant_projection(report) != reference:
            raise CaptureError(f"process invariant drifted for {case['id']}")
    independent_medians = [
        report["independent"]["duration"]["medianNanoseconds"] for report in reports
    ]
    imageio_medians = [report["imageIO"]["duration"]["medianNanoseconds"] for report in reports]
    ratios = [report["independentToImageIOMedianRatio"] for report in reports]
    return {
        "id": case["id"],
        "sourceFormat": case.get("sourceFormat", "rgba8"),
        "filters": case["filters"],
        "splitIDAT": case["splitIDAT"],
        **reference,
        "processCount": len(reports),
        "independentProcessMediansNanoseconds": independent_medians,
        "imageIOProcessMediansNanoseconds": imageio_medians,
        "independentToImageIOProcessMedianRatios": ratios,
        "independentMedianOfProcessMediansNanoseconds": int(statistics.median(independent_medians)),
        "imageIOMedianOfProcessMediansNanoseconds": int(statistics.median(imageio_medians)),
        "medianIndependentToImageIOProcessRatio": statistics.median(ratios),
        "minimumIndependentToImageIOProcessRatio": min(ratios),
        "maximumIndependentToImageIOProcessRatio": max(ratios),
        "rawRuns": reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--iterations", type=int, default=9)
    parser.add_argument("--processes", type=int, default=3)
    args = parser.parse_args()
    if not (1 <= args.processes <= 5):
        raise CaptureError("process count must be in 1...5")
    if not (1 <= args.iterations <= 50):
        raise CaptureError("iteration count must be in 1...50")

    profile = json.loads(args.profile.read_text())
    cases = profile.get("successCases")
    if profile.get("schemaVersion") != 1 or not isinstance(cases, list) or not cases:
        raise CaptureError("invalid performance profile")
    if profile.get("hostileCases") != []:
        raise CaptureError("performance profile must not contain hostile cases")
    case_ids = [case.get("id") for case in cases]
    if any(not isinstance(case_id, str) or not case_id for case_id in case_ids):
        raise CaptureError("performance profile case IDs must be non-empty strings")
    if len(case_ids) != len(set(case_ids)):
        raise CaptureError("performance profile case IDs must be unique")
    operation_budget_bytes = profile.get("operationBudgetBytes")
    if not isinstance(operation_budget_bytes, int) or operation_budget_bytes <= 0:
        raise CaptureError("performance profile must define a positive operationBudgetBytes")

    with tempfile.TemporaryDirectory(prefix="imagecraft-independent-png-performance-") as temp_dir:
        temp = Path(temp_dir)
        before = capture_source_identity(temp / "source-before.json")
        binary, env, build_environment = build_release(temp / "swiftpm")
        binary_sha256 = sha256_file(binary)

        corpus = temp / "corpus"
        run(
            [
                sys.executable,
                str(ROOT / "Tools/Quality/generate_independent_png_corpus.py"),
                "--profile",
                str(args.profile),
                "--output-dir",
                str(corpus),
            ],
            env=env,
        )
        manifest_path = corpus / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("profileID") != profile.get("profileID"):
            raise CaptureError("generated corpus profile drifted")
        generated_by_id = {case["id"]: case for case in manifest["successCases"]}

        aggregates: list[dict[str, Any]] = []
        for case in cases:
            generated = generated_by_id.get(case["id"])
            if generated is None:
                raise CaptureError(f"missing generated case: {case['id']}")
            if generated.get("sourceFormat", "rgba8") != case.get("sourceFormat", "rgba8"):
                raise CaptureError(f"generated source format drifted for {case['id']}")
            png = corpus / generated["path"]
            reports = [
                parse_run(
                    binary,
                    case,
                    png,
                    operation_budget_bytes,
                    args.iterations,
                    env,
                    binary_sha256,
                )
                for _ in range(args.processes)
            ]
            aggregate = aggregate_case(case, reports)
            if aggregate["inputSHA256"] != generated["pngSHA256"]:
                raise CaptureError(f"input hash drifted for {case['id']}")
            aggregates.append(aggregate)

        after = capture_source_identity(temp / "source-after.json")
        if before != after:
            raise CaptureError(
                "source identity drifted during independent PNG performance capture: "
                f"before={before.get('sourceIdentitySHA256')} "
                f"after={after.get('sourceIdentitySHA256')}"
            )

        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-directional-performance",
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
                "caseCount": len(aggregates),
            },
            "binary": {
                "path": str(binary),
                "sha256": binary_sha256,
                "builtByCapture": True,
                "stableAcrossRuns": True,
            },
            "qualificationPreflight": {
                "swiftTestJobs": 1,
                "scope": "full-package",
                "passed": True,
            },
            "buildEnvironment": build_environment,
            "pythonVersion": platform.python_version(),
            "iterationsPerImplementationPerProcess": args.iterations,
            "processesPerCase": args.processes,
            "cases": aggregates,
            "claimBoundary": profile["claimBoundary"],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Independent PNG decode comparison captured: "
            f"source={before['sourceIdentitySHA256']} output={args.output}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
