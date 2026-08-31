#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/rfc1950-inflate-comparison-v1/formal-report.json"
PROFILES = ("repetitive-v1", "png-scanline-v1", "incompressible-v1")
EVIDENCE_VERSION = "imagecraft-rfc1950-inflate-comparison-aggregate-v1"


class CaptureError(RuntimeError):
    pass


def run(argv: list[str], *, env: dict[str, str] | None = None, timeout: int = 900) -> str:
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


def source_identity(path: Path) -> dict[str, Any]:
    run(
        [
            sys.executable,
            str(ROOT / "Tools/Identity/capture_source_identity.py"),
            "--output",
            str(path),
        ]
    )
    return json.loads(path.read_text())


def build_release(scratch: Path) -> tuple[Path, dict[str, str]]:
    developer_dir = run([str(ROOT / "scripts/select-xcode.sh")]).strip()
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    run([sys.executable, str(ROOT / "scripts/check-swift-toolchain.py")], env=env)
    run(
        [
            "swift",
            "test",
            "--scratch-path",
            str(scratch),
            "--jobs",
            "1",
        ],
        env=env,
    )
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
    return binary, {"DEVELOPER_DIR": developer_dir}


def capture_one(
    binary: Path,
    profile: str,
    payload_bytes: int,
    iterations: int,
    expected_binary_sha256: str,
) -> dict[str, Any]:
    if sha256_file(binary) != expected_binary_sha256:
        raise CaptureError(f"evidence binary drifted before run for {profile}")
    raw = run(
        [
            str(binary),
            "--rfc1950-inflate-comparison",
            "--profile",
            profile,
            "--bytes",
            str(payload_bytes),
            "--iterations",
            str(iterations),
        ],
        timeout=180,
    )
    if sha256_file(binary) != expected_binary_sha256:
        raise CaptureError(f"evidence binary drifted during run for {profile}")
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as error:
        raise CaptureError(f"invalid evidence JSON for {profile}: {error}") from error
    if report.get("evidenceVersion") != "imagecraft-rfc1950-inflate-comparison-v1":
        raise CaptureError(f"evidence schema drifted for {profile}")
    if report.get("payloadProfile") != profile:
        raise CaptureError(f"payload profile drifted for {profile}")
    if report.get("payloadByteCount") != payload_bytes:
        raise CaptureError(f"payload byte count drifted for {profile}")
    if report.get("iterationsPerImplementation") != iterations:
        raise CaptureError(f"iteration count drifted for {profile}")
    if report.get("warmupIterationsPerImplementation") != 2:
        raise CaptureError(f"warmup count drifted for {profile}")
    if report.get("alternatingOrder") is not True:
        raise CaptureError(f"AB/BA order drifted for {profile}")
    if report.get("streamingExactOutputPreflight") is not True:
        raise CaptureError(f"streaming exact-output preflight failed for {profile}")
    for key in ("pure", "streamingPure", "appleCompression"):
        samples = report[key].get("samplesNanoseconds")
        if not isinstance(samples, list) or len(samples) != iterations or any(
            not isinstance(value, int) or value <= 0 for value in samples
        ):
            raise CaptureError(f"invalid samples for {profile}/{key}")
    return report


def invariant_projection(report: dict[str, Any]) -> dict[str, Any]:
    return {
        "runtime": report["runtime"],
        "environment": report["environment"],
        "payloadProfile": report["payloadProfile"],
        "payloadByteCount": report["payloadByteCount"],
        "payloadSHA256": report["payloadSHA256"],
        "compressedByteCount": report["compressedByteCount"],
        "compressedSHA256": report["compressedSHA256"],
        "firstDeflateBlockType": report["firstDeflateBlockType"],
        "pureAlgorithmicWorkspaceByteChargeUpperBound": report[
            "pureAlgorithmicWorkspaceByteChargeUpperBound"
        ],
        "streamingExactOutputPreflight": report["streamingExactOutputPreflight"],
    }


def aggregate_profile(profile: str, reports: list[dict[str, Any]]) -> dict[str, Any]:
    reference = invariant_projection(reports[0])
    for report in reports[1:]:
        if invariant_projection(report) != reference:
            raise CaptureError(f"process invariant drifted for {profile}")

    pure_medians = [report["pure"]["duration"]["medianNanoseconds"] for report in reports]
    streaming_medians = [
        report["streamingPure"]["duration"]["medianNanoseconds"] for report in reports
    ]
    apple_medians = [
        report["appleCompression"]["duration"]["medianNanoseconds"] for report in reports
    ]
    ratios = [report["pureToAppleMedianRatio"] for report in reports]
    streaming_to_pure_ratios = [report["streamingToPureMedianRatio"] for report in reports]
    streaming_to_apple_ratios = [report["streamingToAppleMedianRatio"] for report in reports]
    return {
        "profile": profile,
        **reference,
        "processCount": len(reports),
        "pureProcessMediansNanoseconds": pure_medians,
        "streamingProcessMediansNanoseconds": streaming_medians,
        "appleProcessMediansNanoseconds": apple_medians,
        "pureToAppleProcessMedianRatios": ratios,
        "streamingToPureProcessMedianRatios": streaming_to_pure_ratios,
        "streamingToAppleProcessMedianRatios": streaming_to_apple_ratios,
        "pureMedianOfProcessMediansNanoseconds": int(statistics.median(pure_medians)),
        "streamingMedianOfProcessMediansNanoseconds": int(statistics.median(streaming_medians)),
        "appleMedianOfProcessMediansNanoseconds": int(statistics.median(apple_medians)),
        "medianPureToAppleProcessRatio": statistics.median(ratios),
        "medianStreamingToPureProcessRatio": statistics.median(streaming_to_pure_ratios),
        "medianStreamingToAppleProcessRatio": statistics.median(streaming_to_apple_ratios),
        "minimumPureToAppleProcessRatio": min(ratios),
        "maximumPureToAppleProcessRatio": max(ratios),
        "rawRuns": reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--payload-bytes", type=int, default=1_048_576)
    parser.add_argument("--iterations", type=int, default=9)
    parser.add_argument("--processes", type=int, default=3)
    args = parser.parse_args()
    if not (1 <= args.processes <= 5):
        raise CaptureError("process count must be in 1...5")
    if not (1 <= args.iterations <= 50):
        raise CaptureError("iteration count must be in 1...50")
    if args.payload_bytes <= 0:
        raise CaptureError("payload byte count must be positive")

    with tempfile.TemporaryDirectory(prefix="imagecraft-rfc1950-capture-") as temp_dir:
        temp = Path(temp_dir)
        before = source_identity(temp / "source-before.json")
        binary, build_environment = build_release(temp / "swiftpm")
        binary_sha256 = sha256_file(binary)

        aggregates: list[dict[str, Any]] = []
        for profile in PROFILES:
            reports = [
                capture_one(
                    binary,
                    profile,
                    args.payload_bytes,
                    args.iterations,
                    binary_sha256,
                )
                for _ in range(args.processes)
            ]
            aggregates.append(aggregate_profile(profile, reports))

        after = source_identity(temp / "source-after.json")
        if before != after:
            raise CaptureError(
                "source identity drifted during RFC1950 capture: "
                f"before={before.get('sourceIdentitySHA256')} "
                f"after={after.get('sourceIdentitySHA256')}"
            )

        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-directional-performance",
            "sourceIdentity": {
                "fileCount": before["fileCount"],
                "sourceIdentitySHA256": before["sourceIdentitySHA256"],
                "stableBeforeAfter": True,
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
            "payloadByteCount": args.payload_bytes,
            "iterationsPerImplementationPerProcess": args.iterations,
            "processesPerProfile": args.processes,
            "profiles": aggregates,
            "claimBoundary": [
                "all timings are local directional observations bound to this exact source/runtime/hardware identity",
                "no post-hoc performance threshold is introduced by this capture",
                "the Apple Compression path is a performance reference, not a semantic authority",
                "streaming exact-byte equality is established before timing; timed streaming samples keep only bounded delivery-count checks while the decoder still validates RFC1950 Adler-32",
                "timed pure and Apple samples verify exact decoded payload before each sample is accepted",
                "resource byte charges are admission-model values and are not RSS measurements",
            ],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "RFC1950 comparison captured: "
            f"source={before['sourceIdentitySHA256']} output={args.output}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
