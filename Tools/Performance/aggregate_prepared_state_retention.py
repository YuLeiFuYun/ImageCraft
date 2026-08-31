#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
from pathlib import Path


RAW_VERSION = "imagecraft-prepared-state-retention-v1"
AGGREGATE_VERSION = "imagecraft-prepared-state-retention-aggregate-v1"
NAME_RE = re.compile(
    r"pair-(?P<pair>\d+)-order-(?P<order>[01])-(?P<strategy>retained-source|encoded-data-only)\.json$"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    rank = max(1, int(len(ordered) * fraction + 0.999999999))
    return ordered[min(len(ordered) - 1, rank - 1)]


def summarize(values: list[float]) -> dict[str, float]:
    if not values:
        raise AssertionError("cannot summarize empty values")
    return {
        "minimum": min(values),
        "median": statistics.median(values),
        "p90": percentile(values, 0.90),
        "maximum": max(values),
        "mean": statistics.fmean(values),
    }


def load_raw(path: Path) -> tuple[int, int, str, dict]:
    match = NAME_RE.match(path.name)
    if match is None:
        raise AssertionError(f"unexpected raw report name: {path.name}")
    report = json.loads(path.read_text())
    if report.get("schemaVersion") != 1 or report.get("evidenceVersion") != RAW_VERSION:
        raise AssertionError(f"schema/version mismatch: {path}")
    strategy = match.group("strategy")
    if report.get("strategy") != strategy:
        raise AssertionError(f"strategy/name mismatch: {path}")
    if report.get("warmupIterations") != 3:
        raise AssertionError(f"warmup drift: {path}")
    iterations = report.get("iterations")
    for field in (
        "prepareDuration",
        "decodeDuration",
        "totalDuration",
        "initialInspectionDuration",
        "repeatedInspectionDuration",
    ):
        samples = report[field]["samplesNanoseconds"]
        if len(samples) != iterations or any(value < 0 for value in samples):
            raise AssertionError(f"invalid samples for {field}: {path}")
    classification = report["resourceClassification"]
    encoded_bytes = report["source"]["encodedByteCount"]
    if classification["retainedKnownBytes"] != encoded_bytes:
        raise AssertionError(f"retained-known byte mismatch: {path}")
    expected_retained = (
        "unknown:frameworkPrivateRetainedState"
        if strategy == "retained-source"
        else f"bounded:{encoded_bytes}"
    )
    if classification["retainedBetweenCalls"] != expected_retained:
        raise AssertionError(f"retained classification mismatch: {path}")
    if classification["operationPeak"] != "unknown:frameworkPrivateOperationAllocation":
        raise AssertionError(f"operation classification drift: {path}")
    if classification["transferredOutput"] != "unknown:frameworkChosenOutputLayout":
        raise AssertionError(f"output classification drift: {path}")
    expected_aggregate = classification["retainedKnownBytes"] * report["simultaneousPreparationCount"]
    if classification.get("aggregateRetainedKnownByteCharge") != expected_aggregate:
        raise AssertionError(f"aggregate retained charge mismatch: {path}")
    if classification.get("aggregateMaximumRetainedKnownByteCharge") != expected_aggregate:
        raise AssertionError(f"aggregate retained budget mismatch: {path}")
    repeated = report["repeatedInspectionDuration"]["samplesNanoseconds"]
    if strategy == "retained-source" and any(repeated):
        raise AssertionError(f"source reuse unexpectedly reprepared: {path}")
    if strategy == "encoded-data-only" and any(value <= 0 for value in repeated):
        raise AssertionError(f"data-only decode did not reprepare: {path}")
    return int(match.group("pair")), int(match.group("order")), strategy, report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-identity", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args()

    identity = json.loads(args.source_identity.read_text())
    source_identity_sha = identity.get("sourceIdentitySHA256")
    if not source_identity_sha:
        raise AssertionError("source identity missing digest")

    loaded = [load_raw(path) for path in args.reports]
    if len(loaded) < 4 or len(loaded) % 2:
        raise AssertionError("expected at least two complete AB/BA pairs")
    pairs: dict[int, dict[str, tuple[int, dict]]] = {}
    for pair, order, strategy, report in loaded:
        slot = pairs.setdefault(pair, {})
        if strategy in slot:
            raise AssertionError(f"duplicate strategy in pair {pair}")
        slot[strategy] = (order, report)
    if any(set(slot) != {"retained-source", "encoded-data-only"} for slot in pairs.values()):
        raise AssertionError("incomplete strategy pair")

    reference = loaded[0][3]
    invariant_fields = (
        "runtime",
        "decoderFingerprint",
        "environment",
        "simultaneousPreparationCount",
        "warmupIterations",
        "iterations",
        "source",
        "outputRGBABytes",
        "outputSHA256",
    )
    for _, _, _, report in loaded[1:]:
        for field in invariant_fields:
            if report[field] != reference[field]:
                raise AssertionError(f"cross-process invariant drifted: {field}")

    # Pair order must alternate AB then BA so fixed execution order cannot masquerade as a
    # strategy effect.
    for pair, slot in sorted(pairs.items()):
        retained_order = slot["retained-source"][0]
        data_order = slot["encoded-data-only"][0]
        expected_retained = 0 if pair % 2 == 0 else 1
        if retained_order != expected_retained or data_order != 1 - expected_retained:
            raise AssertionError(f"pair {pair} is not in the required alternating order")

    strategies: dict[str, dict] = {}
    for strategy in ("retained-source", "encoded-data-only"):
        reports = [slot[strategy][1] for _, slot in sorted(pairs.items())]
        strategies[strategy] = {
            "processCount": len(reports),
            "prepareMedianNanoseconds": summarize(
                [r["prepareDuration"]["statistics"]["medianNanoseconds"] for r in reports]
            ),
            "decodeMedianNanoseconds": summarize(
                [r["decodeDuration"]["statistics"]["medianNanoseconds"] for r in reports]
            ),
            "totalMedianNanoseconds": summarize(
                [r["totalDuration"]["statistics"]["medianNanoseconds"] for r in reports]
            ),
            "initialInspectionMedianNanoseconds": summarize(
                [r["initialInspectionDuration"]["statistics"]["medianNanoseconds"] for r in reports]
            ),
            "repeatedInspectionMedianNanoseconds": summarize(
                [r["repeatedInspectionDuration"]["statistics"]["medianNanoseconds"] for r in reports]
            ),
            "preparedRSSDeltaBytes": summarize([r["rss"]["preparedDeltaBytes"] for r in reports]),
            "afterDiscardRSSDeltaBytes": summarize(
                [r["rss"]["afterDiscardDeltaBytes"] for r in reports]
            ),
        }

    paired_total_ratios: list[float] = []
    paired_decode_ratios: list[float] = []
    paired_rss_savings: list[float] = []
    for _, slot in sorted(pairs.items()):
        retained = slot["retained-source"][1]
        data_only = slot["encoded-data-only"][1]
        retained_total = retained["totalDuration"]["statistics"]["medianNanoseconds"]
        data_total = data_only["totalDuration"]["statistics"]["medianNanoseconds"]
        retained_decode = retained["decodeDuration"]["statistics"]["medianNanoseconds"]
        data_decode = data_only["decodeDuration"]["statistics"]["medianNanoseconds"]
        paired_total_ratios.append(data_total / retained_total)
        paired_decode_ratios.append(data_decode / retained_decode)
        paired_rss_savings.append(
            float(retained["rss"]["preparedDeltaBytes"] - data_only["rss"]["preparedDeltaBytes"])
        )

    aggregate = {
        "schemaVersion": 1,
        "evidenceVersion": AGGREGATE_VERSION,
        "sourceIdentity": {
            "fileCount": identity.get("fileCount"),
            "sourceIdentitySHA256": source_identity_sha,
            "reportSHA256": sha256(args.source_identity),
        },
        "methodology": {
            "pairCount": len(pairs),
            "alternatingOrder": True,
            "simultaneousPreparationCount": reference["simultaneousPreparationCount"],
            "warmupIterationsPerProcess": reference["warmupIterations"],
            "timedIterationsPerProcess": reference["iterations"],
            "performanceThresholdPreRegistered": False,
        },
        "invariants": {
            "runtimeStable": True,
            "sourceStable": True,
            "exactOutputDigestStable": True,
            "outputSHA256": reference["outputSHA256"],
            "encodedSHA256": reference["source"]["encodedSHA256"],
            "retainedSourceClassification": "unknown:frameworkPrivateRetainedState",
            "encodedDataOnlyClassification": f"bounded:{reference['source']['encodedByteCount']}",
            "aggregateRetainedKnownByteCharge": (
                reference["resourceClassification"]["retainedKnownBytes"]
                * reference["simultaneousPreparationCount"]
            ),
            "operationClassification": "unknown:frameworkPrivateOperationAllocation",
            "outputClassification": "unknown:frameworkChosenOutputLayout",
        },
        "strategies": strategies,
        "pairedComparison": {
            "dataOnlyToRetainedTotalMedianRatio": summarize(paired_total_ratios),
            "dataOnlyToRetainedDecodeMedianRatio": summarize(paired_decode_ratios),
            "retainedMinusDataOnlyPreparedRSSDeltaBytes": summarize(paired_rss_savings),
        },
        "rawReports": [
            {"path": path.name, "sha256": sha256(path)} for path in sorted(args.reports)
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(aggregate, indent=2, sort_keys=True) + "\n")
    print(json.dumps(aggregate, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
