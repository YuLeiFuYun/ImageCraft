#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = (
    ROOT
    / "Evidence/Experiments/IndependentProgressiveJPEG420PackedFinalization/v6/profile.json"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def bounded_value(bound: dict) -> int:
    bounded = bound.get("bounded")
    if not isinstance(bounded, dict) or "_0" not in bounded:
        raise ValueError(f"expected bounded resource value, got {bound!r}")
    return int(bounded["_0"])


def unknown_reason(bound: dict) -> str:
    unknown = bound.get("unknown")
    if not isinstance(unknown, dict) or "_0" not in unknown:
        raise ValueError(f"expected unknown resource value, got {bound!r}")
    return str(unknown["_0"])


def jpeg_marker_facts(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise ValueError("expected JPEG SOI")
    offset = 2
    metadata = 0
    saw_exif_or_xmp = False
    saw_mpf = False
    saw_icc = False
    sof_count = 0
    while offset < len(data):
        if data[offset] != 0xFF:
            raise ValueError(f"expected JPEG marker at {offset}")
        marker_start = offset
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise ValueError("unterminated JPEG marker")
        marker = data[offset]
        offset += 1
        if marker == 0xD9:
            break
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            raise ValueError("truncated JPEG segment length")
        length = int.from_bytes(data[offset : offset + 2], "big")
        if length < 2:
            raise ValueError("invalid JPEG segment length")
        payload_start = offset + 2
        payload_end = offset + length
        if payload_end > len(data):
            raise ValueError("truncated JPEG segment payload")
        payload = data[payload_start:payload_end]
        if 0xE0 <= marker <= 0xEF or marker == 0xFE:
            metadata += len(payload)
        if marker == 0xE1 and (
            payload.startswith(b"Exif\x00\x00")
            or payload.startswith(b"http://ns.adobe.com/xap/1.0/\x00")
            or payload.startswith(b"http://ns.adobe.com/xmp/extension/\x00")
        ):
            saw_exif_or_xmp = True
        if marker == 0xE2:
            saw_mpf = saw_mpf or payload.startswith(b"MPF\x00")
            saw_icc = saw_icc or payload.startswith(b"ICC_PROFILE\x00")
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            sof_count += 1
        if marker != 0xDA:
            offset = payload_end
            continue

        cursor = payload_end
        while cursor < len(data):
            if data[cursor] != 0xFF:
                cursor += 1
                continue
            code_offset = cursor + 1
            while code_offset < len(data) and data[code_offset] == 0xFF:
                code_offset += 1
            if code_offset >= len(data):
                raise ValueError("unterminated entropy marker")
            code = data[code_offset]
            if code == 0x00 or 0xD0 <= code <= 0xD7:
                cursor = code_offset + 1
                continue
            offset = cursor
            break
        else:
            raise ValueError("JPEG scan missing following marker")
        if offset == marker_start:
            raise ValueError("JPEG marker parser made no progress")
    return {
        "metadataByteCount": metadata,
        "sawEXIFOrXMP": saw_exif_or_xmp,
        "sawMPF": saw_mpf,
        "sawICC": saw_icc,
        "sofCount": sof_count,
    }


def validate(profile_path: Path) -> dict:
    profile_path = profile_path.resolve()
    profile = load_json(profile_path)
    schema_version = int(profile.get("schemaVersion", 0))
    if schema_version not in (1, 2, 3, 4, 5, 6, 7, 8):
        raise ValueError("unsupported profile schema")
    case = profile["case"]
    source = ROOT / case["input"]
    expected_source_hash = case["inputSHA256"]
    if sha256(source) != expected_source_hash:
        raise ValueError("source hash drift")

    report = load_json(profile_path.parent / case["report"])
    if int(report["schemaVersion"]) != schema_version:
        raise ValueError("report schema drift")
    expected_evidence_version = (
        f"imagecraft-independent-progressive-jpeg-420-packed-finalization-v{schema_version}"
    )
    if report["evidenceVersion"] != expected_evidence_version:
        raise ValueError("evidence version drift")
    if report["source"]["sha256"] != expected_source_hash:
        raise ValueError("report source hash mismatch")
    if int(report["source"]["byteCount"]) != source.stat().st_size:
        raise ValueError("report source byte count mismatch")
    if not report["capabilityDiscoverable"]:
        raise ValueError("packed finalization capability is not discoverable")
    if report["inputProfile"] != "arbitraryChunk":
        raise ValueError("packed finalization lost arbitrary-chunk input qualification")
    if report["preFinishProgress"] != "finalReady":
        raise ValueError("packed finalization was not reached from final-ready state")
    if report["terminalProgress"] != "terminal":
        raise ValueError("packed finalization did not terminalize the session")
    if int(report["chunkByteCount"]) != int(profile["chunkByteCount"]):
        raise ValueError("chunk schedule drift")
    expected_chunks = (source.stat().st_size + int(profile["chunkByteCount"]) - 1) // int(
        profile["chunkByteCount"]
    )
    if int(report["chunkCount"]) != expected_chunks:
        raise ValueError("chunk count mismatch")
    if int(report["finalizationSourceByteCount"]) != source.stat().st_size:
        raise ValueError("finalization source count is not bound to complete encoded input")
    if int(report["maximumTightRGBABytes"]) != 0:
        raise ValueError("RGB8 qualification incorrectly claimed an RGBA transfer bound")
    if report["retainsOpaqueFrameworkStateBetweenCalls"]:
        raise ValueError("packed qualification retained opaque framework state")
    if not report["packedMatchesKernelRGB"]:
        raise ValueError("standard packed value differs from kernel RGB")
    if not report["wrapperBackingWasShared"]:
        raise ValueError("standard packed wrapper duplicated the RGB payload backing")

    packed = report["packed"]
    for key in ("pixelWidth", "pixelHeight", "bytesPerRow", "byteCount"):
        if int(packed[key]) != int(case[key]):
            raise ValueError(f"packed {key} mismatch")
    if packed["sha256"] != case["outputSHA256"]:
        raise ValueError("packed RGB hash mismatch")
    if packed["sampleStorage"] != "uint8":
        raise ValueError("packed sample storage is not uint8")
    if packed["channelLayout"] != "rgb":
        raise ValueError("packed channel layout is not RGB")
    if packed["alphaAssociation"] != "none":
        raise ValueError("packed RGB unexpectedly claims alpha")
    if packed["colorEncoding"] != "sRGB":
        raise ValueError("profile-absent JFIF output is not classified as sRGB")
    if packed["sourceColorProfile"] != "absent":
        raise ValueError("profile-absent JFIF source was misclassified")
    if int(packed["pixelByteCharge"]) != int(packed["byteCount"]):
        raise ValueError("pixel byte charge does not equal tight RGB payload")
    if int(packed["transferredByteCharge"]) != int(packed["byteCount"]):
        raise ValueError("sRGB packed transfer charge contains an unexplained extra payload")

    prefinish = report["preFinishResourceLedger"]
    if prefinish["isTerminal"]:
        raise ValueError("pre-finish resource ledger is terminal")
    if prefinish["outputLayoutAuthority"] != "codecOwnedRGB8":
        raise ValueError("pre-finish ledger lost codec-owned RGB8 authority")
    if bounded_value(prefinish["transferredOutput"]) != int(packed["transferredByteCharge"]):
        raise ValueError("packed transfer charge disagrees with pre-finish ledger")
    if bounded_value(prefinish["retainedBetweenCalls"]) != int(packed["byteCount"]):
        raise ValueError("final-ready retained charge is not the packed RGB backing")

    terminal = report["terminalResourceLedger"]
    if not terminal["isTerminal"]:
        raise ValueError("terminal ledger missing")
    if terminal["outputLayoutAuthority"] != "none":
        raise ValueError("terminal ledger retains output authority")
    for key in ("retainedBetweenCalls", "operationPeak", "transferredOutput"):
        if bounded_value(terminal[key]) != 0:
            raise ValueError(f"terminal ledger retained non-zero {key}")
    if int(terminal["retainedKnownBytes"]) != 0:
        raise ValueError("terminal ledger retained known bytes")

    if schema_version >= 2:
        historical = load_json(profile_path.parent.parent / "v1" / case["report"])
        for key in (
            "source",
            "inputProfile",
            "chunkByteCount",
            "chunkCount",
            "capabilityDiscoverable",
            "preFinishProgress",
            "preFinishResourceLedger",
            "maximumTightRGBABytes",
            "retainsOpaqueFrameworkStateBetweenCalls",
            "packed",
            "finalizationSourceByteCount",
            "packedMatchesKernelRGB",
            "wrapperBackingWasShared",
            "terminalProgress",
            "terminalResourceLedger",
        ):
            if report[key] != historical[key]:
                raise ValueError(f"v2 changed v1 packed-finalization fact: {key}")

        decoded = report.get("decoded")
        if not isinstance(decoded, dict):
            raise ValueError("v2 missing DecodedImage materialization evidence")
        for key in ("pixelWidth", "pixelHeight", "bytesPerRow"):
            if int(decoded[key]) != int(packed[key]):
                raise ValueError(f"decoded {key} differs from packed authority")
        if int(decoded["bitsPerComponent"]) != int(case["bitsPerComponent"]):
            raise ValueError("decoded bitsPerComponent mismatch")
        if int(decoded["bitsPerPixel"]) != int(case["bitsPerPixel"]):
            raise ValueError("decoded bitsPerPixel mismatch")
        if decoded["alphaInfo"] != "none":
            raise ValueError("decoded CGImage unexpectedly claims alpha")
        if decoded["colorSpaceModel"] != "rgb":
            raise ValueError("decoded CGImage color space is not RGB")
        if decoded["sourceColorProfile"] != "absent":
            raise ValueError("DecodedImage source profile drifted from packed source facts")
        if int(decoded["providerByteCount"]) != int(packed["byteCount"]):
            raise ValueError("CGDataProvider payload size differs from tight packed RGB")
        if decoded["providerSHA256"] != packed["sha256"]:
            raise ValueError("CGDataProvider payload differs from packed RGB")
        copied_payload = int(decoded["copiedPixelPayloadByteCount"])
        if copied_payload != int(case["copiedPixelPayloadByteCount"]):
            raise ValueError("known provider pixel copy size mismatch")
        known_payload_peak = int(decoded["knownPixelPayloadOperationBytes"])
        if known_payload_peak != int(case["knownPixelPayloadOperationBytes"]):
            raise ValueError("known pixel-payload coexistence mismatch")
        if known_payload_peak != int(packed["byteCount"]) + copied_payload:
            raise ValueError("known pixel-payload coexistence does not compose")

        materialization = decoded["resourceLedger"]
        if int(materialization["retainedKnownBytes"]) != 0:
            raise ValueError("materializer retains codec-owned bytes after transfer")
        if bounded_value(materialization["retainedBetweenCalls"]) != 0:
            raise ValueError("materializer retainedBetweenCalls is non-zero")
        if bounded_value(materialization["transferredOutput"]) != int(
            packed["transferredByteCharge"]
        ):
            raise ValueError("materializer transfer bound differs from packed RGB payload")
        if materialization["outputLayoutAuthority"] != "codecOwnedRGB8":
            raise ValueError("materializer lost codec-owned RGB8 layout authority")
        if "bounded" in materialization["operationPeak"]:
            raise ValueError("materializer falsely bounded Core Graphics wrapper allocation")
        if unknown_reason(materialization["operationPeak"]) != "frameworkPrivateOperationAllocation":
            raise ValueError("materializer operation unknown reason drifted")
        if schema_version >= 3:
            if not decoded.get("providerBackingWasShared", False):
                raise ValueError("v3 provider did not retain the packed RGB backing")
            if copied_payload != 0:
                raise ValueError("v3 retained an avoidable second RGB payload")
            if known_payload_peak != int(packed["byteCount"]):
                raise ValueError("v3 known pixel payload is not exactly the shared packed backing")
            historical_v2 = load_json(profile_path.parent.parent / "v2" / case["report"])
            historical_decoded = historical_v2["decoded"]
            for key in (
                "pixelWidth",
                "pixelHeight",
                "bytesPerRow",
                "bitsPerComponent",
                "bitsPerPixel",
                "alphaInfo",
                "colorSpaceModel",
                "sourceColorProfile",
                "providerByteCount",
                "providerSHA256",
                "resourceLedger",
            ):
                if decoded[key] != historical_decoded[key]:
                    raise ValueError(f"v3 changed v2 DecodedImage authority: {key}")
            if int(historical_decoded["copiedPixelPayloadByteCount"]) != int(packed["byteCount"]):
                raise ValueError("v2 historical copy witness drifted")
            if int(historical_decoded["knownPixelPayloadOperationBytes"]) != 2 * int(
                packed["byteCount"]
            ):
                raise ValueError("v2 historical known-payload witness drifted")
        if schema_version >= 4:
            if not report.get("decodedResourceFinalizationCapabilityDiscoverable", False):
                raise ValueError("resource-aware DecodedImage finalization capability is not discoverable")
            if report.get("publicDecodedFinalizationCapabilityAdvertised", True):
                raise ValueError("resource-unknown DecodedImage path was prematurely advertised publicly")
            if int(report["decodedResourceFinalizationSourceByteCount"]) != source.stat().st_size:
                raise ValueError("resource-aware DecodedImage finalization lost source binding")
            if report["decodedResourceFinalizationProviderSHA256"] != packed["sha256"]:
                raise ValueError("resource-aware DecodedImage provider differs from packed RGB")
            if schema_version < 8:
                if report["decodedResourceFinalizationLedger"] != decoded["resourceLedger"]:
                    raise ValueError("resource-aware capability hid or changed materialization authority")
            else:
                capability_ledger = report["decodedResourceFinalizationLedger"]
                materializer_ledger = decoded["resourceLedger"]
                if int(capability_ledger["retainedKnownBytes"]) != int(packed["byteCount"]):
                    raise ValueError("v8 whole-finalization ledger omitted final-ready packed retention")
                if bounded_value(capability_ledger["retainedBetweenCalls"]) != int(packed["byteCount"]):
                    raise ValueError("v8 whole-finalization retained bound differs from packed payload")
                if int(materializer_ledger["retainedKnownBytes"]) != 0:
                    raise ValueError("v8 helper-local materializer unexpectedly retains known bytes")
                if bounded_value(materializer_ledger["retainedBetweenCalls"]) != 0:
                    raise ValueError("v8 helper-local materializer retainedBetweenCalls is non-zero")
                for key in ("operationPeak", "transferredOutput", "outputLayoutAuthority"):
                    if capability_ledger[key] != materializer_ledger[key]:
                        raise ValueError(f"v8 whole-finalization ledger changed materializer authority: {key}")
            capability_ledger = report["decodedResourceFinalizationLedger"]
            if unknown_reason(capability_ledger["operationPeak"]) != "frameworkPrivateOperationAllocation":
                raise ValueError("resource-aware capability lost framework-private operation unknown")
            if bounded_value(capability_ledger["transferredOutput"]) != int(
                packed["transferredByteCharge"]
            ):
                raise ValueError("resource-aware capability transfer bound drifted")
            capability_terminal = report["decodedResourceFinalizationTerminalLedger"]
            if not capability_terminal["isTerminal"]:
                raise ValueError("resource-aware capability did not terminalize")
            if capability_terminal["outputLayoutAuthority"] != "none":
                raise ValueError("resource-aware terminal retained output authority")
            for key in ("retainedBetweenCalls", "operationPeak", "transferredOutput"):
                if bounded_value(capability_terminal[key]) != 0:
                    raise ValueError(f"resource-aware terminal retained non-zero {key}")
            historical_v3 = load_json(profile_path.parent.parent / "v3" / case["report"])
            if report["decoded"] != historical_v3["decoded"]:
                raise ValueError("v4 changed v3 no-copy DecodedImage materialization facts")
        if schema_version >= 5:
            marker_facts = jpeg_marker_facts(source)
            if marker_facts["sawEXIFOrXMP"]:
                raise ValueError("v5 retained source contains excluded EXIF/XMP orientation authority")
            if marker_facts["sawMPF"]:
                raise ValueError("v5 retained source contains excluded MPF auxiliary authority")
            if marker_facts["sawICC"]:
                raise ValueError("v5 retained source contains excluded embedded ICC authority")
            if marker_facts["sofCount"] != 1:
                raise ValueError("v5 retained source does not have one JPEG frame header")
            probe = report.get("decodedResourceFinalizationProbe")
            if not isinstance(probe, dict):
                raise ValueError("v5 missing resource-aware ImageProbe evidence")
            if int(probe["pixelWidth"]) != int(packed["pixelWidth"]):
                raise ValueError("v5 probe width differs from packed output")
            if int(probe["pixelHeight"]) != int(packed["pixelHeight"]):
                raise ValueError("v5 probe height differs from packed output")
            if int(probe["frameCount"]) != 1:
                raise ValueError("v5 probe frame count is not one")
            if int(probe["orientation"]) != 1:
                raise ValueError("v5 probe orientation is not qualified orientation 1")
            if probe["format"] != "jpeg":
                raise ValueError("v5 probe format is not JPEG")
            if int(probe["metadataByteCount"]) != int(marker_facts["metadataByteCount"]):
                raise ValueError("v5 probe metadata count differs from independent marker accounting")
            if int(probe["auxiliaryAttachmentCount"]) != 0:
                raise ValueError("v5 probe claims unsupported auxiliary attachments")
            if probe["sourceColorProfile"] != "absent":
                raise ValueError("v5 probe source profile is not absent")
            historical_v4 = load_json(profile_path.parent.parent / "v4" / case["report"])
            for key in (
                "source",
                "inputProfile",
                "chunkByteCount",
                "chunkCount",
                "capabilityDiscoverable",
                "preFinishProgress",
                "preFinishResourceLedger",
                "maximumTightRGBABytes",
                "retainsOpaqueFrameworkStateBetweenCalls",
                "packed",
                "finalizationSourceByteCount",
                "packedMatchesKernelRGB",
                "wrapperBackingWasShared",
                "decoded",
                "decodedResourceFinalizationCapabilityDiscoverable",
                "publicDecodedFinalizationCapabilityAdvertised",
                "decodedResourceFinalizationSourceByteCount",
                "decodedResourceFinalizationLedger",
                "decodedResourceFinalizationProviderSHA256",
                "decodedResourceFinalizationTerminalLedger",
                "terminalProgress",
                "terminalResourceLedger",
            ):
                if schema_version >= 8 and key == "decodedResourceFinalizationLedger":
                    continue
                if report[key] != historical_v4[key]:
                    raise ValueError(f"v5 changed v4 representation fact: {key}")
        if schema_version >= 6:
            if not report.get("publicResourceAwareDecodedFinalizationCapabilityAdvertised", False):
                raise ValueError("v6 resource-aware DecodedImage capability is not advertised")
            if report.get("publicDecodedFinalizationCapabilityAdvertised", True):
                raise ValueError("v6 prematurely advertised the legacy value-only public finalizer")
            historical_v5 = load_json(profile_path.parent.parent / "v5" / case["report"])
            for key in (
                "source",
                "inputProfile",
                "chunkByteCount",
                "chunkCount",
                "capabilityDiscoverable",
                "preFinishProgress",
                "preFinishResourceLedger",
                "maximumTightRGBABytes",
                "retainsOpaqueFrameworkStateBetweenCalls",
                "packed",
                "finalizationSourceByteCount",
                "packedMatchesKernelRGB",
                "wrapperBackingWasShared",
                "decoded",
                "decodedResourceFinalizationCapabilityDiscoverable",
                "publicDecodedFinalizationCapabilityAdvertised",
                "decodedResourceFinalizationSourceByteCount",
                "decodedResourceFinalizationProbe",
                "decodedResourceFinalizationLedger",
                "decodedResourceFinalizationProviderSHA256",
                "decodedResourceFinalizationTerminalLedger",
                "terminalProgress",
                "terminalResourceLedger",
            ):
                if schema_version >= 8 and key == "decodedResourceFinalizationLedger":
                    continue
                if report[key] != historical_v5[key]:
                    raise ValueError(f"v6 changed v5 representation/probe fact: {key}")
        if schema_version >= 7:
            if report.get("decodedResourceFinalizationPreflightProgress") != "finalReady":
                raise ValueError("v7 resource-aware preflight did not occur at finalReady")
            if not report.get("decodedResourceFinalizationPreflightWasNonConsuming", False):
                raise ValueError("v7 resource-aware preflight consumed or changed the session")
            preflight = report.get("decodedResourceFinalizationPreflightLedger")
            if not isinstance(preflight, dict):
                raise ValueError("v7 missing resource-aware preflight ledger")
            if preflight != report["decodedResourceFinalizationLedger"]:
                raise ValueError("v7 preflight ledger differs from final materialization ledger")
            if unknown_reason(preflight["operationPeak"]) != "frameworkPrivateOperationAllocation":
                raise ValueError("v7 preflight hid framework-private operation allocation")
            if bounded_value(preflight["transferredOutput"]) != int(packed["transferredByteCharge"]):
                raise ValueError("v7 preflight transfer bound differs from packed payload")
            if schema_version == 7:
                if bounded_value(preflight["retainedBetweenCalls"]) != 0:
                    raise ValueError("v7 preflight unexpectedly retains materializer-owned bytes")
                if int(preflight["retainedKnownBytes"]) != 0:
                    raise ValueError("v7 preflight retained known materializer bytes")
            else:
                if bounded_value(preflight["retainedBetweenCalls"]) != int(packed["byteCount"]):
                    raise ValueError("v8 preflight omitted final-ready packed retained bound")
                if int(preflight["retainedKnownBytes"]) != int(packed["byteCount"]):
                    raise ValueError("v8 preflight omitted final-ready packed known bytes")
            if preflight["outputLayoutAuthority"] != "codecOwnedRGB8":
                raise ValueError("v7 preflight lost codec-owned RGB8 layout authority")
            historical_v6 = load_json(profile_path.parent.parent / "v6" / case["report"])
            for key in (
                "source",
                "inputProfile",
                "chunkByteCount",
                "chunkCount",
                "capabilityDiscoverable",
                "preFinishProgress",
                "preFinishResourceLedger",
                "maximumTightRGBABytes",
                "retainsOpaqueFrameworkStateBetweenCalls",
                "packed",
                "finalizationSourceByteCount",
                "packedMatchesKernelRGB",
                "wrapperBackingWasShared",
                "decoded",
                "decodedResourceFinalizationCapabilityDiscoverable",
                "publicResourceAwareDecodedFinalizationCapabilityAdvertised",
                "publicDecodedFinalizationCapabilityAdvertised",
                "decodedResourceFinalizationSourceByteCount",
                "decodedResourceFinalizationProbe",
                "decodedResourceFinalizationLedger",
                "decodedResourceFinalizationProviderSHA256",
                "decodedResourceFinalizationTerminalLedger",
                "terminalProgress",
                "terminalResourceLedger",
            ):
                if schema_version >= 8 and key == "decodedResourceFinalizationLedger":
                    continue
                if report[key] != historical_v6[key]:
                    raise ValueError(f"v7 changed v6 public representation fact: {key}")
        if schema_version >= 8:
            historical_v7 = load_json(profile_path.parent.parent / "v7" / case["report"])
            historical_preflight = historical_v7["decodedResourceFinalizationPreflightLedger"]
            if int(historical_preflight["retainedKnownBytes"]) != 0:
                raise ValueError("v7 historical helper-local retained-known witness drifted")
            if bounded_value(historical_preflight["retainedBetweenCalls"]) != 0:
                raise ValueError("v7 historical helper-local retained bound drifted")
            for key in (
                "source",
                "inputProfile",
                "chunkByteCount",
                "chunkCount",
                "capabilityDiscoverable",
                "preFinishProgress",
                "preFinishResourceLedger",
                "maximumTightRGBABytes",
                "retainsOpaqueFrameworkStateBetweenCalls",
                "packed",
                "finalizationSourceByteCount",
                "packedMatchesKernelRGB",
                "wrapperBackingWasShared",
                "decoded",
                "decodedResourceFinalizationCapabilityDiscoverable",
                "publicResourceAwareDecodedFinalizationCapabilityAdvertised",
                "publicDecodedFinalizationCapabilityAdvertised",
                "decodedResourceFinalizationPreflightProgress",
                "decodedResourceFinalizationPreflightWasNonConsuming",
                "decodedResourceFinalizationSourceByteCount",
                "decodedResourceFinalizationProbe",
                "decodedResourceFinalizationProviderSHA256",
                "decodedResourceFinalizationTerminalLedger",
                "terminalProgress",
                "terminalResourceLedger",
            ):
                if report[key] != historical_v7[key]:
                    raise ValueError(f"v8 changed v7 non-ledger representation fact: {key}")

    summary = {
        "sourceByteCount": source.stat().st_size,
        "chunkCount": expected_chunks,
        "packedByteCount": int(packed["byteCount"]),
        "packedSHA256": packed["sha256"],
        "sourceColorProfile": packed["sourceColorProfile"],
        "colorEncoding": packed["colorEncoding"],
        "wrapperBackingWasShared": report["wrapperBackingWasShared"],
    }
    if schema_version >= 2:
        summary["knownPixelPayloadOperationBytes"] = int(
            report["decoded"]["knownPixelPayloadOperationBytes"]
        )
        summary["materializationOperationUnknownReason"] = unknown_reason(
            report["decoded"]["resourceLedger"]["operationPeak"]
        )
    if schema_version >= 4:
        summary["decodedResourceCapabilityDiscoverable"] = report[
            "decodedResourceFinalizationCapabilityDiscoverable"
        ]
        summary["publicDecodedFinalizationCapabilityAdvertised"] = report[
            "publicDecodedFinalizationCapabilityAdvertised"
        ]
    if schema_version >= 5:
        summary["probeMetadataByteCount"] = int(
            report["decodedResourceFinalizationProbe"]["metadataByteCount"]
        )
        summary["probeOrientation"] = int(
            report["decodedResourceFinalizationProbe"]["orientation"]
        )
    if schema_version >= 6:
        summary["publicResourceAwareDecodedFinalizationCapabilityAdvertised"] = report[
            "publicResourceAwareDecodedFinalizationCapabilityAdvertised"
        ]
    if schema_version >= 7:
        summary["decodedResourceFinalizationPreflightWasNonConsuming"] = report[
            "decodedResourceFinalizationPreflightWasNonConsuming"
        ]
        summary["decodedResourceFinalizationPreflightOperationUnknownReason"] = unknown_reason(
            report["decodedResourceFinalizationPreflightLedger"]["operationPeak"]
        )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
