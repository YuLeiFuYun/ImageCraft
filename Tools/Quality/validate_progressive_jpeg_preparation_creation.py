#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/ProgressiveJPEGPreparationCreation/v1/profile.json"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def require_terminal(ledger: dict) -> None:
    if not ledger["isTerminal"]:
        raise ValueError("session did not publish terminal resource ledger")
    if int(ledger["retainedKnownBytes"]) != 0:
        raise ValueError("terminal ledger retained known bytes")
    if ledger["outputLayoutAuthority"] != "none":
        raise ValueError("terminal ledger retained output authority")
    for key in ("retainedBetweenCalls", "operationPeak", "transferredOutput"):
        if bounded_value(ledger[key]) != 0:
            raise ValueError(f"terminal ledger retained non-zero {key}")


def validate(profile_path: Path) -> dict:
    profile_path = profile_path.resolve()
    profile = load_json(profile_path)
    if int(profile.get("schemaVersion", 0)) != 1:
        raise ValueError("unsupported preparation-creation profile schema")
    case = profile["case"]
    source = ROOT / case["input"]
    if sha256(source) != case["inputSHA256"]:
        raise ValueError("source hash drift")
    source_bytes = source.stat().st_size
    expected_icc_bytes = int(case["expectedEmbeddedICCProfileByteCount"])
    expected_resulting_known = source_bytes + expected_icc_bytes

    report = load_json(profile_path.parent / case["report"])
    if int(report["schemaVersion"]) != 1:
        raise ValueError("report schema drift")
    if report["evidenceVersion"] != "imagecraft-progressive-jpeg-preparation-creation-v1":
        raise ValueError("evidence version drift")
    if report["source"]["sha256"] != case["inputSHA256"]:
        raise ValueError("report source hash mismatch")
    if int(report["source"]["byteCount"]) != source_bytes:
        raise ValueError("report source byte count mismatch")
    if report["inputProfile"] != "arbitraryChunk":
        raise ValueError("preparation creation lost arbitrary-chunk qualification")
    if report["preflightProgress"] != "finalReady":
        raise ValueError("preparation creation preflight did not occur at finalReady")
    if not report["preflightWasNonConsuming"]:
        raise ValueError("preparation creation preflight consumed or changed the session")
    chunk_bytes = int(profile["chunkByteCount"])
    if int(report["chunkByteCount"]) != chunk_bytes:
        raise ValueError("chunk schedule drift")
    expected_chunks = (source_bytes + chunk_bytes - 1) // chunk_bytes
    if int(report["chunkCount"]) != expected_chunks:
        raise ValueError("chunk count mismatch")

    operation = report["operationResourceLedger"]
    if operation["isTerminal"]:
        raise ValueError("creation operation ledger is terminal")
    if int(operation["retainedKnownBytes"]) != source_bytes:
        raise ValueError("creation operation lost call-boundary encoded bytes")
    if bounded_value(operation["retainedBetweenCalls"]) != source_bytes:
        raise ValueError("creation operation retained bound differs from call-boundary source")
    if unknown_reason(operation["operationPeak"]) != "frameworkPrivateOperationAllocation":
        raise ValueError("creation operation hid framework-private allocation")
    if bounded_value(operation["transferredOutput"]) != 0:
        raise ValueError("preparation creation incorrectly modeled decoder-retained state as transfer")
    if operation["outputLayoutAuthority"] != "none":
        raise ValueError("preparation creation unexpectedly published pixel layout authority")

    if int(report["resultingPreparationRetainedKnownBytes"]) != expected_resulting_known:
        raise ValueError("resulting preparation known retention mismatch")
    if bounded_value(report["resultingPreparationRetainedBetweenCalls"]) != expected_resulting_known:
        raise ValueError("resulting preparation retained bound mismatch")
    if int(report["finalizationSourceByteCount"]) != source_bytes:
        raise ValueError("preparation finalization lost complete-source binding")
    if not report["preparationLedgerMatchesPreflightResult"]:
        raise ValueError("post-token retained authority differs from creation preflight")

    prepared = report["postTokenResourceLedger"]
    if prepared["isTerminal"]:
        raise ValueError("live preparation published terminal ledger")
    if int(prepared["retainedKnownBytes"]) != expected_resulting_known:
        raise ValueError("post-token known retention differs from preflight result")
    if bounded_value(prepared["retainedBetweenCalls"]) != expected_resulting_known:
        raise ValueError("post-token retained bound differs from preflight result")
    if unknown_reason(prepared["operationPeak"]) != "frameworkPrivateOperationAllocation":
        raise ValueError("prepared decode operation incorrectly became bounded")
    if unknown_reason(prepared["transferredOutput"]) != "frameworkChosenOutputLayout":
        raise ValueError("prepared ImageIO output-layout uncertainty drifted")
    if prepared["outputLayoutAuthority"] != "frameworkChosen":
        raise ValueError("prepared ImageIO layout authority drifted")

    require_terminal(report["sessionTerminalResourceLedger"])
    if not report["postDiscardPreparationLedgerAbsent"]:
        raise ValueError("discard did not reclaim prepared-token authority")

    return {
        "sourceByteCount": source_bytes,
        "chunkCount": expected_chunks,
        "operationUnknownReason": unknown_reason(operation["operationPeak"]),
        "resultingPreparationRetainedKnownBytes": expected_resulting_known,
        "preparedOutputUnknownReason": unknown_reason(prepared["transferredOutput"]),
        "postDiscardPreparationLedgerAbsent": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
