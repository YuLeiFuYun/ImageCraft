#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import tempfile
from typing import Any

from capture_fovea_derived_raster_host_qualification import (
    QualificationError,
    capture_imagecraft_identity,
    copy_fovea,
    git_head,
    mechanism_audit,
    parse_fovea_host_contract,
    rebind_imagecraft,
    run,
    sha256_file,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = ROOT / "ConformanceKits/ImagePackedRGB8/v1/Fixtures"
FIXTURE_MANIFEST = FIXTURE_ROOT / "manifest.json"
DEFAULT_OUTPUT = (
    ROOT
    / ".artifacts/performance/baseline-packed-rgb8-fovea-host-v2/formal-report.json"
)
EVIDENCE_VERSION = "imagecraft-fovea-baseline-packed-rgb8-host-v2"
REPORT_SCHEMA_VERSION = 2
RUN_LABEL = "v2"
QUALIFICATION_SCOPE = "the finite public baseline color sampling union"
EXPECTED_CASES = [
    {
        "id": "baseline-jfif-444-23x13",
        "sampling": "4:4:4",
        "width": 23,
        "height": 13,
        "file": "reference-baseline-jfif-444-23x13.jpg",
        "expectedRGB8File": "reference-baseline-jfif-444-23x13.rgb",
        "sourceByteCount": 613,
        "packedByteCount": 897,
        "sourceSHA256": "ccdb8b4b5058c8529bd570f7267f0dcfa038f3556ba6156241f37a9865490719",
        "packedSHA256": "f3b0edfdac3b5eedc3b5f27e79644baf3c449ed3968720429fb34ea0df899a14",
        "operationPeakBytes": 1601,
    },
    {
        "id": "baseline-jfif-422-23x13",
        "sampling": "4:2:2",
        "width": 23,
        "height": 13,
        "file": "reference-baseline-jfif-422-23x13.jpg",
        "expectedRGB8File": "reference-baseline-jfif-422-23x13.rgb",
        "sourceByteCount": 552,
        "packedByteCount": 897,
        "sourceSHA256": "6e0901315f1ea40df35139af4df40a456a6a9bb6a0423a7d92fe190c92b19e3f",
        "packedSHA256": "56608f195b45873b2157f4dc6505798ab4c080dd297a35f5b0214151ab54ee1e",
        "operationPeakBytes": 3073,
    },
    {
        "id": "baseline-jfif-420-23x13",
        "sampling": "4:2:0",
        "width": 23,
        "height": 13,
        "file": "reference-baseline-jfif-420-23x13.jpg",
        "expectedRGB8File": "reference-baseline-jfif-420-23x13.rgb",
        "sourceByteCount": 856,
        "packedByteCount": 897,
        "sourceSHA256": "218392f142ad2f1bcf5280ecc1f82ded3152ecfa65fdcde23a6ff2c07f405585",
        "packedSHA256": "c7807abef8ee1d20dcdaa4953e0767518aab1485578dca5a9ae7c0bb3d146861",
        "operationPeakBytes": 3777,
    },
]


def validated_cases() -> list[dict[str, Any]]:
    if not FIXTURE_MANIFEST.is_file():
        raise QualificationError(f"missing packed RGB8 fixture manifest: {FIXTURE_MANIFEST}")
    manifest = json.loads(FIXTURE_MANIFEST.read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("fixtureSetID") != "IMAGECRAFT-PACKED-RGB8-FIXTURES-V1":
        raise QualificationError("packed RGB8 fixture manifest identity drifted")
    items = manifest.get("fixtures")
    if not isinstance(items, list):
        raise QualificationError("packed RGB8 fixture matrix is missing")
    by_id = {item.get("id"): item for item in items if isinstance(item, dict)}
    if len(by_id) != len(items):
        raise QualificationError("packed RGB8 fixture matrix contains duplicate or invalid IDs")
    result: list[dict[str, Any]] = []
    for expected in EXPECTED_CASES:
        item = by_id.get(expected["id"])
        if not isinstance(item, dict):
            raise QualificationError(f"missing packed RGB8 fixture: {expected['id']}")
        exact_fields = {
            "sampling": expected["sampling"],
            "file": expected["file"],
            "expectedRGB8File": expected["expectedRGB8File"],
            "format": "jpeg",
            "width": expected["width"],
            "height": expected["height"],
            "sourceByteCount": expected["sourceByteCount"],
            "expectedRGB8ByteCount": expected["packedByteCount"],
            "exactOperationByteCharge": expected["operationPeakBytes"],
            "sha256": expected["sourceSHA256"],
            "expectedRGB8SHA256": expected["packedSHA256"],
        }
        for key, value in exact_fields.items():
            if item.get(key) != value:
                raise QualificationError(
                    f"fixture manifest drift at {expected['id']}.{key}: "
                    f"expected {value!r}, got {item.get(key)!r}"
                )
        source = FIXTURE_ROOT / expected["file"]
        oracle = FIXTURE_ROOT / expected["expectedRGB8File"]
        if (
            not source.is_file()
            or source.stat().st_size != expected["sourceByteCount"]
            or sha256_file(source) != expected["sourceSHA256"]
        ):
            raise QualificationError(f"source fixture bytes drifted: {expected['id']}")
        if (
            not oracle.is_file()
            or oracle.stat().st_size != expected["packedByteCount"]
            or sha256_file(oracle) != expected["packedSHA256"]
        ):
            raise QualificationError(f"RGB oracle bytes drifted: {expected['id']}")
        bound = dict(expected)
        bound["source"] = source
        result.append(bound)
    return result


def swift_string(value: str) -> str:
    return json.dumps(value)


def swift_test_source(cases: list[dict[str, Any]]) -> str:
    case_literals = []
    for item in cases:
        source_base64 = base64.b64encode(Path(item["source"]).read_bytes()).decode("ascii")
        case_literals.append(
            "Case(\n"
            f"                id: {swift_string(item['id'])},\n"
            f"                sampling: {swift_string(item['sampling'])},\n"
            f"                sourceBase64: {swift_string(source_base64)},\n"
            f"                sourceByteCount: {item['sourceByteCount']},\n"
            f"                sourceSHA256: {swift_string(item['sourceSHA256'])},\n"
            f"                packedSHA256: {swift_string(item['packedSHA256'])},\n"
            f"                width: {item['width']},\n"
            f"                height: {item['height']},\n"
            f"                packedByteCount: {item['packedByteCount']},\n"
            f"                operationPeakBytes: {item['operationPeakBytes']}\n"
            "            )"
        )
    joined_cases = ",\n            ".join(case_literals)
    return f'''import AkashicCore
import CryptoKit
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class BaselinePackedRGB8HostQualificationV2Tests: XCTestCase {{
    private struct Case {{
        let id: String
        let sampling: String
        let sourceBase64: String
        let sourceByteCount: Int
        let sourceSHA256: String
        let packedSHA256: String
        let width: Int
        let height: Int
        let packedByteCount: Int
        let operationPeakBytes: Int
    }}

    func testCurrentImageCraftPackedSamplingUnionRoundTripsThroughFoveaAndAkashic() async throws {{
        let cases = [
            {joined_cases}
        ]
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-baseline-packed-rgb8-v2-\\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        defer {{ try? FileManager.default.removeItem(at: storeRoot) }}
        let limits = DerivedRasterStoreLimits(
            softTotalBytes: 64 * 1024 * 1024,
            maximumBlobBytes: 16 * 1024 * 1024,
            maximumWriteBytesPerWindow: 1024 * 1024 * 1024,
            writeBudgetWindowNanoseconds: 60_000_000_000
        )
        var store: AkashicDerivedRasterStore? = try await AkashicDerivedRasterStore.open(
            root: storeRoot,
            limits: limits
        )
        let format = DerivedRasterContainer.formatIdentity
        var caseReceipts: [[String: Any]] = []
        var records: [String: DerivedRasterRecord] = [:]
        var packedByID: [String: Data] = [:]

        for item in cases {{
            let source = try XCTUnwrap(Data(base64Encoded: item.sourceBase64))
            XCTAssertEqual(source.count, item.sourceByteCount, item.id)
            XCTAssertEqual(sha256(source), item.sourceSHA256, item.id)

            let decoder: any ImagePackedRGB8Decoding = try BoundedBaselineJPEGDecoder(
                maximumOperationByteCharge: item.operationPeakBytes
            )
            let request = ImageDecodeRequest(
                target: try TargetPixels(width: item.width, height: item.height),
                contentMode: .fit,
                colorPolicy: .convertToSRGB,
                dynamicRange: .standard
            )
            let probe = try decoder.probe(data: source, limits: .coreV1)
            XCTAssertEqual(probe.pixelWidth, item.width, item.id)
            XCTAssertEqual(probe.pixelHeight, item.height, item.id)
            XCTAssertEqual(probe.format, .jpeg, item.id)
            XCTAssertEqual(probe.sourceColorProfile, .absent, item.id)
            XCTAssertEqual(probe.sourceBitsPerComponent, 8, item.id)
            let ledger = try decoder.packedRGB8ResourceLedger(
                data: source,
                request: request,
                limits: .coreV1
            )
            XCTAssertEqual(ledger.operationPeak, .bounded(item.operationPeakBytes), item.id)
            XCTAssertEqual(ledger.transferredOutput, .bounded(item.packedByteCount), item.id)
            XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8, item.id)
            XCTAssertEqual(
                ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: source.count),
                .bounded(item.operationPeakBytes + item.sourceByteCount),
                item.id
            )

            let packed = try decoder.decodePackedRGB8(
                data: source,
                request: request,
                limits: .coreV1
            )
            XCTAssertEqual(packed.pixelWidth, item.width, item.id)
            XCTAssertEqual(packed.pixelHeight, item.height, item.id)
            XCTAssertEqual(packed.bytesPerRow, item.width * 3, item.id)
            XCTAssertEqual(packed.data.count, item.packedByteCount, item.id)
            XCTAssertEqual(sha256(packed.data), item.packedSHA256, item.id)
            XCTAssertEqual(packed.colorEncoding, .sRGB, item.id)
            XCTAssertEqual(packed.sourceColorProfile, .absent, item.id)

            let container = try DerivedRasterContainer.encode(
                pixelData: packed.data,
                width: packed.pixelWidth,
                height: packed.pixelHeight
            )
            let containerSHA = sha256(container)
            let decoded = try DerivedRasterContainer.decode(
                container,
                expectedContainerDigestHex: containerSHA
            )
            XCTAssertEqual(decoded.pixelData, packed.data, item.id)

            let record = try DerivedRasterRecord(
                artifactKeyDigest: sha256(Data("baseline-packed-rgb8-host-v2-artifact-\\(item.id)".utf8)),
                baseKeyDigest: sha256(Data("baseline-packed-rgb8-host-v2-base-\\(item.id)".utf8)),
                variantKeyDigest: sha256(Data("baseline-packed-rgb8-host-v2-variant-\\(item.id)".utf8)),
                namespaceFingerprint: StorageNamespaceFingerprint(namespace: "host-qualification-v2"),
                namespaceGeneration: 1,
                containerContentID: BlobDigest.sha256(of: container).canonicalString,
                containerByteCount: container.count,
                formatIdentifier: format.identifier,
                formatSemanticVersion: format.semanticVersion,
                pixelLayoutFingerprint: format.pixelLayoutFingerprint,
                pixelDigestHex: sha256(packed.data),
                pixelWidth: packed.pixelWidth,
                pixelHeight: packed.pixelHeight,
                createdAt: Date(timeIntervalSinceReferenceDate: 2_000)
            )
            try await store?.commit(container: container, record: record)
            let loadedValue = try await store?.load(
                artifactKeyDigest: record.artifactKeyDigest,
                namespaceFingerprint: record.namespaceFingerprint,
                namespaceGeneration: record.namespaceGeneration
            )
            let loaded = try XCTUnwrap(loadedValue)
            let loadedDecoded = try DerivedRasterContainer.decode(
                loaded.container,
                expectedContainerDigestHex: sha256(loaded.container)
            )
            XCTAssertEqual(loadedDecoded.pixelData, packed.data, item.id)

            records[item.id] = record
            packedByID[item.id] = packed.data
            caseReceipts.append([
                "id": item.id,
                "sampling": item.sampling,
                "sourceByteCount": source.count,
                "sourceSHA256": sha256(source),
                "packedByteCount": packed.data.count,
                "packedSHA256": sha256(packed.data),
                "pixelWidth": packed.pixelWidth,
                "pixelHeight": packed.pixelHeight,
                "bytesPerRow": packed.bytesPerRow,
                "operationPeakBytes": item.operationPeakBytes,
                "transferredOutputBytes": item.packedByteCount,
                "sourcePlusOperationPeakBytes": item.operationPeakBytes + item.sourceByteCount,
                "containerByteCount": container.count,
                "containerSHA256": containerSHA,
                "akashicLoadExact": loadedDecoded.pixelData == packed.data,
            ])
        }}

        store = nil
        await Task.yield()
        let reopened = try await AkashicDerivedRasterStore.open(root: storeRoot, limits: limits)
        for index in caseReceipts.indices {{
            let id = try XCTUnwrap(caseReceipts[index]["id"] as? String)
            let record = try XCTUnwrap(records[id])
            let packed = try XCTUnwrap(packedByID[id])
            let reopenedValue = try await reopened.load(
                artifactKeyDigest: record.artifactKeyDigest,
                namespaceFingerprint: record.namespaceFingerprint,
                namespaceGeneration: record.namespaceGeneration
            )
            let reopenedArtifact = try XCTUnwrap(reopenedValue)
            let reopenedDecoded = try DerivedRasterContainer.decode(
                reopenedArtifact.container,
                expectedContainerDigestHex: sha256(reopenedArtifact.container)
            )
            XCTAssertEqual(reopenedDecoded.pixelData, packed, id)
            caseReceipts[index]["akashicReopenExact"] = reopenedDecoded.pixelData == packed
        }}

        let receiptURL = try XCTUnwrap(
            ProcessInfo.processInfo.environment["IMAGECRAFT_FOVEA_BASELINE_PACKED_V2_RECEIPT"]
        )
        let receipt: [String: Any] = [
            "formatIdentifier": format.identifier,
            "formatSemanticVersion": format.semanticVersion,
            "pixelLayoutFingerprint": format.pixelLayoutFingerprint,
            "cases": caseReceipts,
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receiptURL), options: .atomic)
    }}

    private func sha256(_ data: Data) -> String {{
        SHA256.hash(data: data).map {{ String(format: "%02x", $0) }}.joined()
    }}
}}
'''


def validate_receipt(
    receipt: dict[str, Any],
    host_contract: dict[str, object],
    cases: list[dict[str, Any]],
) -> None:
    for key in ("formatIdentifier", "formatSemanticVersion", "pixelLayoutFingerprint"):
        expected = host_contract[key]
        if receipt.get(key) != expected:
            raise QualificationError(
                f"host receipt mismatch at {key}: expected {expected!r}, got {receipt.get(key)!r}"
            )
    observed_cases = receipt.get("cases")
    if not isinstance(observed_cases, list) or len(observed_cases) != len(cases):
        raise QualificationError("host receipt case cardinality mismatch")
    observed_by_id = {
        item.get("id"): item for item in observed_cases if isinstance(item, dict)
    }
    for item in cases:
        observed = observed_by_id.get(item["id"])
        if not isinstance(observed, dict):
            raise QualificationError(f"missing host receipt case: {item['id']}")
        expected = {
            "sampling": item["sampling"],
            "sourceByteCount": item["sourceByteCount"],
            "sourceSHA256": item["sourceSHA256"],
            "packedByteCount": item["packedByteCount"],
            "packedSHA256": item["packedSHA256"],
            "pixelWidth": item["width"],
            "pixelHeight": item["height"],
            "bytesPerRow": item["width"] * 3,
            "operationPeakBytes": item["operationPeakBytes"],
            "transferredOutputBytes": item["packedByteCount"],
            "sourcePlusOperationPeakBytes": item["operationPeakBytes"] + item["sourceByteCount"],
            "akashicLoadExact": True,
            "akashicReopenExact": True,
        }
        for key, value in expected.items():
            if observed.get(key) != value:
                raise QualificationError(
                    f"host receipt mismatch at {item['id']}.{key}: "
                    f"expected {value!r}, got {observed.get(key)!r}"
                )
        if not isinstance(observed.get("containerByteCount"), int) or observed["containerByteCount"] <= 120:
            raise QualificationError(f"Fovea container byte count is implausibly small: {item['id']}")
        digest = observed.get("containerSHA256")
        if not isinstance(digest, str) or len(digest) != 64 or any(
            c not in "0123456789abcdef" for c in digest
        ):
            raise QualificationError(f"Fovea container digest is malformed: {item['id']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fovea-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    cases = validated_cases()
    fovea_root = args.fovea_root.resolve()
    if not (fovea_root / "Package.swift").is_file():
        parser.error("--fovea-root is not a Swift package")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="imagecraft-fovea-baseline-packed-v2-") as directory:
        temporary = Path(directory)
        identity_before = capture_imagecraft_identity(temporary / "imagecraft-before.json")
        fovea_before = mechanism_audit(fovea_root)
        host_contract = parse_fovea_host_contract(
            fovea_root / "Sources/FoveaCore/DerivedRasterContainer.swift"
        )

        fovea_copy = temporary / "Fovea"
        copy_fovea(fovea_root, fovea_copy)
        if mechanism_audit(fovea_copy) != fovea_before:
            raise QualificationError("Fovea mechanism bytes changed while materializing copy")
        rebind = rebind_imagecraft(fovea_copy / "Package.swift")

        injected_test = (
            fovea_copy / "Tests/FoveaTests/BaselinePackedRGB8HostQualificationV2Tests.swift"
        )
        injected_test.write_text(swift_test_source(cases))
        receipt_path = temporary / "host-receipt-v2.json"

        developer = run([str(ROOT / "scripts/select-xcode.sh")], cwd=ROOT, timeout=30).stdout.strip()
        if not developer:
            raise QualificationError("Xcode selection returned an empty developer path")
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = developer
        env["IMAGECRAFT_FOVEA_BASELINE_PACKED_V2_RECEIPT"] = str(receipt_path)
        swift = run(["xcrun", "--find", "swift"], cwd=ROOT, env=env, timeout=30).stdout.strip()
        completed = run(
            [
                swift,
                "test",
                "--package-path",
                str(fovea_copy),
                "-j",
                "3",
                "--filter",
                "BaselinePackedRGB8HostQualificationV2Tests",
            ],
            cwd=fovea_copy,
            env=env,
            timeout=1200,
        )
        if "Executed 1 test, with 0 failures" not in completed.stdout:
            raise QualificationError("Fovea host qualification v2 test did not execute exactly once")
        if not receipt_path.is_file():
            raise QualificationError("Fovea host qualification v2 did not write a runtime receipt")
        receipt = json.loads(receipt_path.read_text())
        validate_receipt(receipt, host_contract, cases)

        if mechanism_audit(fovea_root) != fovea_before:
            raise QualificationError("base Fovea mechanism source changed during qualification")
        identity_after = capture_imagecraft_identity(temporary / "imagecraft-after.json")
        if identity_before != identity_after:
            raise QualificationError("ImageCraft source identity changed during host qualification")

        report = {
            "schemaVersion": REPORT_SCHEMA_VERSION,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-host-composition-qualified",
            "claimBoundary": [
                f"The current public BoundedBaselineJPEGDecoder decodes every frozen source in {QUALIFICATION_SCOPE} to exact tight RGB8 under its preflightable bounded one-shot ledger.",
                "Each exact packed RGB8 value is re-encoded by the current Fovea DerivedRasterContainer into Fovea's host-owned chunked-LZFSE RGB8 v7 format; neither ImageCraft JPEG bytes nor its source payload format become the persisted Fovea container.",
                "Every generated Fovea container is committed to the current Akashic-backed Fovea store, loaded and decoded, then loaded again after store reopen with exact RGB equality.",
                "Fovea baseline mechanism sources are hash-bound and never mutated; only a temporary package copy is rebound to the current ImageCraft source tree and receives a test-only host adapter.",
                f"This is host-composition qualification for {QUALIFICATION_SCOPE}, not adoption into Fovea's production baseline pipeline, not a public derived-raster API, and not physical-device/RSS qualification.",
            ],
            "imageCraftSourceIdentity": {
                "sourceIdentitySHA256": identity_before["sourceIdentitySHA256"],
                "fileCount": identity_before["fileCount"],
                "stableBeforeAfter": True,
            },
            "imageCraftFixtures": [
                {
                    "id": item["id"],
                    "sampling": item["sampling"],
                    "path": str(Path(item["source"]).relative_to(ROOT)),
                    "byteCount": item["sourceByteCount"],
                    "sha256": item["sourceSHA256"],
                    "expectedWidth": item["width"],
                    "expectedHeight": item["height"],
                    "expectedPackedByteCount": item["packedByteCount"],
                    "expectedPackedSHA256": item["packedSHA256"],
                    "expectedOperationPeakBytes": item["operationPeakBytes"],
                }
                for item in cases
            ],
            "fovea": {
                "root": str(fovea_root),
                "gitHEAD": git_head(fovea_root),
                "mechanismIdentitySHA256": fovea_before["identitySHA256"],
                "mechanismFiles": fovea_before["files"],
                "hostContainerContract": host_contract,
                "temporaryImageCraftRebind": rebind,
                "baseWorktreeMutated": False,
                "testOnlyAdapterInjectedIntoTemporaryCopy": True,
            },
            "runtimeReceipt": receipt,
            "summary": {
                "qualifiedSamplingModes": [item["sampling"] for item in cases],
                "caseCount": len(cases),
                "allPackedDecodeExact": all(
                    observed.get("packedSHA256") == expected["packedSHA256"]
                    for expected in cases
                    for observed in receipt["cases"]
                    if observed.get("id") == expected["id"]
                ),
                "allFoveaContainerRoundTripExact": all(
                    item.get("akashicLoadExact") is True
                    and item.get("akashicReopenExact") is True
                    for item in receipt["cases"]
                ),
                "hostFormatRemainsFoveaOwned": receipt["formatIdentifier"]
                == host_contract["formatIdentifier"],
            },
        }
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            f"Fovea baseline-packed RGB8 host qualification {RUN_LABEL} passed: "
            f"cases={len(cases)} source={identity_before['sourceIdentitySHA256']} "
            f"fovea={git_head(fovea_root)} output={args.output}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
