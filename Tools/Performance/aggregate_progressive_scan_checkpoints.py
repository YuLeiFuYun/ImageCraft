#!/usr/bin/env python3
import argparse
from collections import defaultdict
import json
from pathlib import Path


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("reports", type=Path, nargs="+")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    expected = {variant["id"] for variant in manifest["variants"]}
    grouped: dict[str, list[dict]] = defaultdict(list)
    for path in args.reports:
        report = json.loads(path.read_text(encoding="utf-8"))
        require(
            report["evidenceVersion"] == "imagecraft-progressive-scan-checkpoint-v1",
            f"wrong evidence version: {path}",
        )
        grouped[report["caseID"]].append(report)
    require(set(grouped) == expected, "checkpoint report cross product is incomplete")

    reports = []
    for case_id in sorted(grouped):
        pair = grouped[case_id]
        require(len(pair) == 2, f"expected deterministic pair for {case_id}")
        require(canonical(pair[0]) == canonical(pair[1]), f"non-deterministic report for {case_id}")
        reports.append(pair[0])

    reference = reports[0]
    for report in reports[1:]:
        require(report["runtime"] == reference["runtime"], "runtime mismatch")
        require(report["decoderFingerprint"] == reference["decoderFingerprint"], "decoder mismatch")
        require(report["environment"] == reference["environment"], "environment mismatch")

    for report in reports:
        require(len(report["scans"]) == report["declaredScanCount"], f"scan count mismatch: {report['caseID']}")
        for scan in report["scans"]:
            require(scan["checkpoints"], f"missing checkpoints: {report['caseID']}")
            fresh_hashes = {
                item["freshSource"]["pixelRGBSHA256"]
                for item in scan["checkpoints"]
                if item["freshSource"]["rasterAvailable"]
            }
            sequential_hashes = {
                item["sequentialSource"]["pixelRGBSHA256"]
                for item in scan["checkpoints"]
                if item["sequentialSource"]["rasterAvailable"]
            }
            require(len(fresh_hashes) <= 1, f"fresh prefix pixels changed within scan {report['caseID']}:{scan['scan']}")
            require(len(sequential_hashes) <= 1, f"sequential pixels changed within scan {report['caseID']}:{scan['scan']}")
            require(fresh_hashes == sequential_hashes, f"fresh/sequential pixels differ {report['caseID']}:{scan['scan']}")

    result = {
        "schemaVersion": 1,
        "matrixVersion": "imagecraft-progressive-scan-checkpoint-matrix-v1",
        "runtime": reference["runtime"],
        "decoderFingerprint": reference["decoderFingerprint"],
        "environment": reference["environment"],
        "design": {
            "sourceCount": len(manifest["sources"]),
            "scanScriptCount": len(manifest["scanScripts"]),
            "variantCount": len(reports),
            "deterministicRunsPerVariant": 2,
        },
        "crossChecks": {
            "completeSourceScriptCrossProduct": True,
            "pairedReportsByteIdentical": True,
            "freshAndSequentialPixelsEqualAtEveryCheckpoint": True,
            "checkpointPixelsStableWithinEachCompletedScan": True,
        },
        "reports": reports,
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
