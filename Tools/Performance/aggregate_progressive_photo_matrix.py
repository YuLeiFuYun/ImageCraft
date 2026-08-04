#!/usr/bin/env python3
import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("reports", type=Path, nargs="+")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    manifest_hash = sha256(args.manifest)
    expected = {
        f"{variant['id']}--chunk-{chunk_size}"
        for variant in manifest["variants"]
        for chunk_size in (1024, 32768)
    }
    grouped: dict[str, list[dict]] = defaultdict(list)
    for path in args.reports:
        report = json.loads(path.read_text(encoding="utf-8"))
        require(report["evidenceVersion"] == "imagecraft-progressive-photo-corpus-v1", f"wrong version: {path}")
        require(report["manifestSHA256"] == manifest_hash, f"manifest mismatch: {path}")
        grouped[report["caseID"]].append(report)

    require(set(grouped) == expected, "report cross product is incomplete")
    canonical_reports = []
    for case_id in sorted(grouped):
        pair = grouped[case_id]
        require(len(pair) == 2, f"expected deterministic pair for {case_id}")
        require(canonical(pair[0]) == canonical(pair[1]), f"non-deterministic report for {case_id}")
        canonical_reports.append(pair[0])

    reference = canonical_reports[0]
    for report in canonical_reports[1:]:
        require(report["runtime"] == reference["runtime"], "runtime mismatch")
        require(report["decoderFingerprint"] == reference["decoderFingerprint"], "decoder mismatch")
        require(report["environment"] == reference["environment"], "environment mismatch")

    final_by_source: dict[str, set[str]] = defaultdict(set)
    output_size_by_source: dict[str, set[tuple[int, int]]] = defaultdict(set)
    encoded_by_variant: dict[tuple[str, str], set[tuple[int, str]]] = defaultdict(set)
    for report in canonical_reports:
        final_by_source[report["sourceID"]].add(report["finalPixelRGBSHA256"])
        output_size_by_source[report["sourceID"]].add(
            (report["outputPixelWidth"], report["outputPixelHeight"])
        )
        encoded_by_variant[(report["sourceID"], report["scanScriptID"])].add(
            (report["encodedByteCount"], report["encodedSHA256"])
        )
        require(
            1 <= len(report["generations"]) <= 4,
            f"invalid generation count: {report['caseID']}",
        )
        require(
            [entry["generation"] for entry in report["generations"]]
            == list(range(1, len(report["generations"]) + 1)),
            f"non-contiguous generations: {report['caseID']}",
        )

    require(all(len(values) == 1 for values in final_by_source.values()), "scan scripts changed final ImageIO pixels")
    require(all(len(values) == 1 for values in output_size_by_source.values()), "output size changed across scripts")
    require(all(len(values) == 1 for values in encoded_by_variant.values()), "chunk schedule changed encoded identity")

    result = {
        "schemaVersion": 1,
        "matrixVersion": "imagecraft-progressive-photo-matrix-v1",
        "manifest": {
            "path": str(args.manifest),
            "sha256": manifest_hash,
            "corpusVersion": manifest["corpusVersion"],
        },
        "runtime": reference["runtime"],
        "decoderFingerprint": reference["decoderFingerprint"],
        "environment": reference["environment"],
        "design": {
            "sourceCount": len(manifest["sources"]),
            "scanScriptCount": len(manifest["scanScripts"]),
            "chunkSizesBytes": [1024, 32768],
            "deterministicRunsPerCase": 2,
            "caseCount": len(canonical_reports),
        },
        "crossChecks": {
            "completeSourceScriptChunkCrossProduct": True,
            "pairedReportsByteIdentical": True,
            "finalPixelsEqualAcrossScriptsAndChunksPerSource": True,
            "encodedIdentityEqualAcrossChunksPerVariant": True,
        },
        "cases": canonical_reports,
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
