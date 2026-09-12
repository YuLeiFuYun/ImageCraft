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
FIXTURE = (
    ROOT
    / "Fixtures/ConsumerSmoke/Tests/ImageCraftConsumerSmokeTests/Resources/jpeg-progressive-420.jpg"
)
DEFAULT_OUTPUT = (
    ROOT
    / ".artifacts/performance/progressive-packed-rgb8-fovea-host-v1/formal-report.json"
)
EVIDENCE_VERSION = "imagecraft-fovea-progressive-packed-rgb8-host-v1"
EXPECTED_SOURCE_SHA256 = "f47fd3d50db29b29754b2ec45e10519f0eb2cecbd537d22a24bf6a7883ec9966"
EXPECTED_PACKED_SHA256 = "c7807abef8ee1d20dcdaa4953e0767518aab1485578dca5a9ae7c0bb3d146861"
EXPECTED_SOURCE_BYTES = 787
EXPECTED_PACKED_BYTES = 897
EXPECTED_WIDTH = 23
EXPECTED_HEIGHT = 13
EXPECTED_OPERATION_PEAK = 6590


def swift_test_source(source_base64: str) -> str:
    return f'''import AkashicCore
import CryptoKit
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ProgressivePackedRGB8HostQualificationTests: XCTestCase {{
    func testCurrentImageCraftPackedFinalizerRoundTripsThroughFoveaAndAkashic() async throws {{
        let source = try XCTUnwrap(Data(base64Encoded: "{source_base64}"))
        XCTAssertEqual(source.count, {EXPECTED_SOURCE_BYTES})
        XCTAssertEqual(sha256(source), "{EXPECTED_SOURCE_SHA256}")

        let session = try BoundedProgressiveJPEG420Session(
            maximumCodecOwnedByteCharge: 1 << 20
        )
        var offset = 0
        for chunkSize in [1, 17, 29, 7, 53] {{
            guard offset < source.count else {{ break }}
            let end = min(source.count, offset + chunkSize)
            XCTAssertNil(try session.append(source.subdata(in: offset..<end)))
            offset = end
        }}
        while offset < source.count {{
            let end = min(source.count, offset + 31)
            XCTAssertNil(try session.append(source.subdata(in: offset..<end)))
            offset = end
        }}
        let ledger = try XCTUnwrap(session.packedRGB8FinalizationResourceLedger())
        XCTAssertEqual(ledger.operationPeak, .bounded({EXPECTED_OPERATION_PEAK}))
        XCTAssertEqual(ledger.transferredOutput, .bounded({EXPECTED_PACKED_BYTES}))
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8)
        XCTAssertEqual(
            ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: source.count),
            .bounded({EXPECTED_OPERATION_PEAK + EXPECTED_SOURCE_BYTES})
        )

        let finalization = try session.finishWithPackedRGB8()
        let packed = finalization.image
        XCTAssertEqual(finalization.sourceByteCount, source.count)
        XCTAssertEqual(packed.pixelWidth, {EXPECTED_WIDTH})
        XCTAssertEqual(packed.pixelHeight, {EXPECTED_HEIGHT})
        XCTAssertEqual(packed.bytesPerRow, {EXPECTED_WIDTH * 3})
        XCTAssertEqual(packed.data.count, {EXPECTED_PACKED_BYTES})
        XCTAssertEqual(sha256(packed.data), "{EXPECTED_PACKED_SHA256}")
        XCTAssertEqual(packed.colorEncoding, .sRGB)
        XCTAssertEqual(packed.sourceColorProfile, .absent)

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
        XCTAssertEqual(decoded.pixelData, packed.data)
        XCTAssertEqual(decoded.width, packed.pixelWidth)
        XCTAssertEqual(decoded.height, packed.pixelHeight)

        let format = DerivedRasterContainer.formatIdentity
        let record = try DerivedRasterRecord(
            artifactKeyDigest: sha256(Data("progressive-packed-rgb8-host".utf8)),
            baseKeyDigest: sha256(Data("progressive-packed-rgb8-base".utf8)),
            variantKeyDigest: sha256(Data("progressive-packed-rgb8-variant".utf8)),
            namespaceFingerprint: StorageNamespaceFingerprint(namespace: "host-qualification"),
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

        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-progressive-packed-rgb8-\\(UUID().uuidString.lowercased())")
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
        XCTAssertEqual(loadedDecoded.pixelData, packed.data)
        store = nil
        await Task.yield()

        let reopened = try await AkashicDerivedRasterStore.open(root: storeRoot, limits: limits)
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
        XCTAssertEqual(reopenedDecoded.pixelData, packed.data)

        let receiptURL = try XCTUnwrap(
            ProcessInfo.processInfo.environment["IMAGECRAFT_FOVEA_PROGRESSIVE_PACKED_RECEIPT"]
        )
        let receipt: [String: Any] = [
            "sourceByteCount": source.count,
            "sourceSHA256": sha256(source),
            "packedByteCount": packed.data.count,
            "packedSHA256": sha256(packed.data),
            "pixelWidth": packed.pixelWidth,
            "pixelHeight": packed.pixelHeight,
            "bytesPerRow": packed.bytesPerRow,
            "operationPeakBytes": {EXPECTED_OPERATION_PEAK},
            "transferredOutputBytes": {EXPECTED_PACKED_BYTES},
            "sourcePlusOperationPeakBytes": {EXPECTED_OPERATION_PEAK + EXPECTED_SOURCE_BYTES},
            "containerByteCount": container.count,
            "containerSHA256": containerSHA,
            "formatIdentifier": format.identifier,
            "formatSemanticVersion": format.semanticVersion,
            "pixelLayoutFingerprint": format.pixelLayoutFingerprint,
            "akashicLoadExact": loadedDecoded.pixelData == packed.data,
            "akashicReopenExact": reopenedDecoded.pixelData == packed.data,
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receiptURL), options: .atomic)
    }}

    private func sha256(_ data: Data) -> String {{
        SHA256.hash(data: data).map {{ String(format: "%02x", $0) }}.joined()
    }}
}}
'''


def validate_receipt(receipt: dict[str, Any], host_contract: dict[str, object]) -> None:
    expected = {
        "sourceByteCount": EXPECTED_SOURCE_BYTES,
        "sourceSHA256": EXPECTED_SOURCE_SHA256,
        "packedByteCount": EXPECTED_PACKED_BYTES,
        "packedSHA256": EXPECTED_PACKED_SHA256,
        "pixelWidth": EXPECTED_WIDTH,
        "pixelHeight": EXPECTED_HEIGHT,
        "bytesPerRow": EXPECTED_WIDTH * 3,
        "operationPeakBytes": EXPECTED_OPERATION_PEAK,
        "transferredOutputBytes": EXPECTED_PACKED_BYTES,
        "sourcePlusOperationPeakBytes": EXPECTED_OPERATION_PEAK + EXPECTED_SOURCE_BYTES,
        "formatIdentifier": host_contract["formatIdentifier"],
        "formatSemanticVersion": host_contract["formatSemanticVersion"],
        "pixelLayoutFingerprint": host_contract["pixelLayoutFingerprint"],
        "akashicLoadExact": True,
        "akashicReopenExact": True,
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise QualificationError(
                f"host receipt mismatch at {key}: expected {value!r}, got {receipt.get(key)!r}"
            )
    if not isinstance(receipt.get("containerByteCount"), int) or receipt["containerByteCount"] <= 120:
        raise QualificationError("Fovea container byte count is implausibly small")
    value = receipt.get("containerSHA256")
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise QualificationError("Fovea container digest is malformed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fovea-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    fovea_root = args.fovea_root.resolve()
    if not (fovea_root / "Package.swift").is_file():
        parser.error("--fovea-root is not a Swift package")
    if not FIXTURE.is_file():
        raise QualificationError(f"missing ImageCraft progressive JPEG fixture: {FIXTURE}")
    if FIXTURE.stat().st_size != EXPECTED_SOURCE_BYTES or sha256_file(FIXTURE) != EXPECTED_SOURCE_SHA256:
        raise QualificationError("ImageCraft progressive JPEG fixture identity drifted")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="imagecraft-fovea-progressive-packed-") as directory:
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
            fovea_copy / "Tests/FoveaTests/ProgressivePackedRGB8HostQualificationTests.swift"
        )
        injected_test.write_text(
            swift_test_source(base64.b64encode(FIXTURE.read_bytes()).decode("ascii"))
        )
        receipt_path = temporary / "host-receipt.json"

        developer = run([str(ROOT / "scripts/select-xcode.sh")], cwd=ROOT, timeout=30).stdout.strip()
        if not developer:
            raise QualificationError("Xcode selection returned an empty developer path")
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = developer
        env["IMAGECRAFT_FOVEA_PROGRESSIVE_PACKED_RECEIPT"] = str(receipt_path)
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
                "ProgressivePackedRGB8HostQualificationTests",
            ],
            cwd=fovea_copy,
            env=env,
            timeout=1200,
        )
        if "Executed 1 test, with 0 failures" not in completed.stdout:
            raise QualificationError("Fovea host qualification test did not execute exactly once")
        if not receipt_path.is_file():
            raise QualificationError("Fovea host qualification did not write a runtime receipt")
        receipt = json.loads(receipt_path.read_text())
        validate_receipt(receipt, host_contract)

        if mechanism_audit(fovea_root) != fovea_before:
            raise QualificationError("base Fovea mechanism source changed during qualification")
        identity_after = capture_imagecraft_identity(temporary / "imagecraft-after.json")
        if identity_before != identity_after:
            raise QualificationError("ImageCraft source identity changed during host qualification")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-host-composition-qualified",
            "claimBoundary": [
                "The current public BoundedProgressiveJPEG420Session finalizes the frozen progressive JFIF 4:2:0 source to exact tight RGB8 under its bounded packed-finalization ledger.",
                "The exact packed RGB8 bytes are encoded by the current Fovea DerivedRasterContainer into Fovea's host-owned chunked-LZFSE RGB8 v7 format; ImageCraft JPEG bytes are not persisted as the Fovea derived-raster container.",
                "The generated Fovea container is committed to the current Akashic-backed Fovea store, loaded, decoded, then loaded again after store reopen with exact RGB equality.",
                "Fovea baseline mechanism sources are hash-bound and never mutated; only a temporary package copy is rebound to the current ImageCraft source tree and receives a test-only host adapter.",
                "This is host-composition qualification, not adoption into Fovea's production progressive pipeline, not a public derived-raster API, and not physical-device/RSS qualification.",
            ],
            "imageCraftSourceIdentity": {
                "sourceIdentitySHA256": identity_before["sourceIdentitySHA256"],
                "fileCount": identity_before["fileCount"],
                "stableBeforeAfter": True,
            },
            "imageCraftFixture": {
                "path": str(FIXTURE.relative_to(ROOT)),
                "byteCount": EXPECTED_SOURCE_BYTES,
                "sha256": EXPECTED_SOURCE_SHA256,
                "expectedPackedByteCount": EXPECTED_PACKED_BYTES,
                "expectedPackedSHA256": EXPECTED_PACKED_SHA256,
                "expectedOperationPeakBytes": EXPECTED_OPERATION_PEAK,
            },
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
                "packedFinalizationExact": receipt["packedSHA256"] == EXPECTED_PACKED_SHA256,
                "foveaContainerRoundTripExact": True,
                "akashicLoadExact": receipt["akashicLoadExact"],
                "akashicReopenExact": receipt["akashicReopenExact"],
                "hostFormatRemainsFoveaOwned": receipt["formatIdentifier"]
                == host_contract["formatIdentifier"],
            },
        }
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Fovea progressive-packed RGB8 host qualification passed: "
            f"source={identity_before['sourceIdentitySHA256']} "
            f"fovea={git_head(fovea_root)} "
            f"container={receipt['containerByteCount']}B output={args.output}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
