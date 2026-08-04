#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
from typing import Any

FRAME_INTERVAL_NS = 16_666_667


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def percentile(sorted_values: list[int], numerator: int, denominator: int) -> int:
    rank = max(1, (len(sorted_values) * numerator + denominator - 1) // denominator)
    return sorted_values[min(len(sorted_values) - 1, rank - 1)]


def statistics(values: list[int]) -> dict[str, int]:
    require(values, "statistics require values")
    ordered = sorted(values)
    return {
        "minimumNanoseconds": ordered[0],
        "medianNanoseconds": percentile(ordered, 50, 100),
        "p90Nanoseconds": percentile(ordered, 90, 100),
        "maximumNanoseconds": ordered[-1],
        "meanNanoseconds": sum(values) // len(values),
    }


def count_statistics(values: list[int]) -> dict[str, int]:
    require(values, "count statistics require values")
    ordered = sorted(values)
    return {
        "minimum": ordered[0],
        "median": percentile(ordered, 50, 100),
        "p90": percentile(ordered, 90, 100),
        "maximum": ordered[-1],
        "meanMicrounits": sum(values) * 1_000_000 // len(values),
    }


def transfer_duration_ns(byte_count: int, bits_per_second: int) -> int:
    return (byte_count * 8 * 1_000_000_000 + bits_per_second - 1) // bits_per_second


def arrival_times(
    chunks: list[dict[str, Any]],
    first_chunk_delay_ns: int,
    bits_per_second: int,
) -> list[int]:
    arrivals = [first_chunk_delay_ns]
    for chunk in chunks[1:]:
        arrivals.append(arrivals[-1] + transfer_duration_ns(chunk["chunkByteCount"], bits_per_second))
    return arrivals


def next_frame_deadline(timestamp_ns: int) -> int:
    return (timestamp_ns // FRAME_INTERVAL_NS + 1) * FRAME_INTERVAL_NS


def present_candidates(
    candidates: list[dict[str, Any]],
    policy: str,
    cancellation_ns: int | None = None,
) -> dict[str, Any]:
    visible = [candidate for candidate in candidates if cancellation_ns is None or candidate["acceptedNs"] < cancellation_ns]
    if policy == "immediate":
        presented = [dict(candidate, presentedNs=candidate["acceptedNs"]) for candidate in visible]
        return {"presented": presented, "superseded": []}

    require(policy == "frame-coalesced-60hz", f"unknown policy {policy}")
    by_deadline: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for candidate in visible:
        deadline = next_frame_deadline(candidate["acceptedNs"])
        if cancellation_ns is not None and deadline >= cancellation_ns:
            continue
        by_deadline[deadline].append(candidate)

    presented = []
    superseded = []
    for deadline in sorted(by_deadline):
        group = by_deadline[deadline]
        winner = group[-1]
        presented.append(dict(winner, presentedNs=deadline))
        superseded.extend(group[:-1])
    presented_ids = {(entry["kind"], entry.get("generation"), entry["acceptedNs"]) for entry in presented}
    for candidate in visible:
        identity = (candidate["kind"], candidate.get("generation"), candidate["acceptedNs"])
        deadline = next_frame_deadline(candidate["acceptedNs"])
        if identity not in presented_ids and candidate not in superseded and (
            cancellation_ns is None or deadline < cancellation_ns
        ):
            superseded.append(candidate)
    return {"presented": presented, "superseded": superseded}


def buffered_byte_peak(
    chunks: list[dict[str, Any]],
    arrivals: list[int],
    decode_ends: list[int],
) -> int:
    events: list[tuple[int, int, int]] = []
    for index, chunk in enumerate(chunks):
        events.append((arrivals[index], 0, chunk["chunkByteCount"]))
        events.append((decode_ends[index], 1, -chunk["chunkByteCount"]))
    current = 0
    maximum = 0
    for _, _, delta in sorted(events):
        current += delta
        maximum = max(maximum, current)
    return maximum


def simulate_complete_iteration(
    sample: dict[str, Any],
    network: dict[str, Any],
    policy: str,
) -> dict[str, Any]:
    chunks = sample["chunks"]
    arrivals = arrival_times(chunks, network["firstChunkDelayNanoseconds"], network["bitsPerSecond"])
    starts: list[int] = []
    ends: list[int] = []
    previous_end = 0
    candidates: list[dict[str, Any]] = []
    for index, chunk in enumerate(chunks):
        start = max(arrivals[index], previous_end)
        end = start + chunk["appendDurationNanoseconds"]
        starts.append(start)
        ends.append(end)
        previous_end = end
        if "generation" in chunk:
            candidates.append(
                {
                    "kind": "preview",
                    "generation": chunk["generation"],
                    "sourceByteCount": chunk["generationSourceByteCount"],
                    "generatedNs": end,
                    "acceptedNs": end + chunk["mainActorHandoffNanoseconds"],
                }
            )

    final_start = max(arrivals[-1], ends[-1])
    finish_end = final_start + sample["finishDurationNanoseconds"]
    final_generated = finish_end + sample["finalDecodeDurationNanoseconds"]
    final_accepted = final_generated + sample["finalMainActorHandoffNanoseconds"]
    candidates.append(
        {
            "kind": "final",
            "generatedNs": final_generated,
            "acceptedNs": final_accepted,
        }
    )
    presentation = present_candidates(candidates, policy)
    presented = presentation["presented"]
    preview_candidates = [candidate for candidate in candidates if candidate["kind"] == "preview"]
    preview_presented = [candidate for candidate in presented if candidate["kind"] == "preview"]
    final_presented = next(candidate for candidate in presented if candidate["kind"] == "final")
    first_preview = preview_presented[0] if preview_presented else None
    queue_delays = [starts[index] - arrivals[index] for index in range(len(chunks))]
    return {
        "completed": True,
        "networkCompleteNs": arrivals[-1],
        "finalGeneratedNs": final_generated,
        "finalAcceptedNs": final_accepted,
        "finalPresentedNs": final_presented["presentedNs"],
        "firstPreviewGeneratedNs": preview_candidates[0]["generatedNs"] if preview_candidates else None,
        "firstPreviewAcceptedNs": preview_candidates[0]["acceptedNs"] if preview_candidates else None,
        "firstPreviewPresentedNs": first_preview["presentedNs"] if first_preview else None,
        "progressiveVisibleWindowNs": final_presented["presentedNs"] - first_preview["presentedNs"] if first_preview else 0,
        "generatedPreviewCount": len(preview_candidates),
        "presentedPreviewCount": len(preview_presented),
        "supersededPreviewCount": len([entry for entry in presentation["superseded"] if entry["kind"] == "preview"]),
        "presentedPreviewGenerations": [entry["generation"] for entry in preview_presented],
        "maximumDecodeQueueDelayNs": max(queue_delays),
        "meanDecodeQueueDelayNs": sum(queue_delays) // len(queue_delays),
        "maximumBufferedNetworkBytes": buffered_byte_peak(chunks, arrivals, ends),
        "decoderIdleBeforeFinalNs": max(0, arrivals[-1] - ends[-1]),
        "finalAfterNetworkCompleteNs": final_presented["presentedNs"] - arrivals[-1],
    }


def simulate_cancelled_iteration(
    sample: dict[str, Any],
    network: dict[str, Any],
    policy: str,
) -> dict[str, Any]:
    cancel_ns = network["cancellationDeadlineNanoseconds"]
    chunks = sample["chunks"]
    arrivals = arrival_times(chunks, network["firstChunkDelayNanoseconds"], network["bitsPerSecond"])
    starts: list[int] = []
    ends: list[int] = []
    previous_end = 0
    candidates: list[dict[str, Any]] = []
    for index, chunk in enumerate(chunks):
        start = max(arrivals[index], previous_end)
        end = start + chunk["appendDurationNanoseconds"]
        starts.append(start)
        ends.append(end)
        previous_end = end
        if start >= cancel_ns:
            break
        if "generation" in chunk:
            candidates.append(
                {
                    "kind": "preview",
                    "generation": chunk["generation"],
                    "sourceByteCount": chunk["generationSourceByteCount"],
                    "generatedNs": end,
                    "acceptedNs": end + chunk["mainActorHandoffNanoseconds"],
                }
            )

    arrived_indices = [index for index, arrival in enumerate(arrivals) if arrival <= cancel_ns]
    started_indices = [index for index, start in enumerate(starts) if start < cancel_ns]
    in_flight = next(
        (index for index in started_indices if starts[index] < cancel_ns < ends[index]),
        None,
    )
    cancellation_complete = ends[in_flight] if in_flight is not None else cancel_ns
    decoder_received = sum(chunks[index]["chunkByteCount"] for index in started_indices)
    network_received = sum(chunks[index]["chunkByteCount"] for index in arrived_indices)
    post_cancel_append_work = ends[in_flight] - cancel_ns if in_flight is not None else 0
    generated_after_request = [
        candidate
        for candidate in candidates
        if cancel_ns < candidate["generatedNs"] <= cancellation_complete
    ]
    presentation = present_candidates(candidates, policy, cancellation_ns=cancel_ns)
    preview_presented = [entry for entry in presentation["presented"] if entry["kind"] == "preview"]
    pending_suppressed = [
        candidate
        for candidate in candidates
        if candidate["acceptedNs"] < cancel_ns
        and next_frame_deadline(candidate["acceptedNs"]) >= cancel_ns
        and policy == "frame-coalesced-60hz"
    ]
    return {
        "completed": False,
        "cancellationRequestedNs": cancel_ns,
        "cancellationCompletedNs": cancellation_complete,
        "cancellationBlockingNs": cancellation_complete - cancel_ns,
        "networkReceivedByteCount": network_received,
        "decoderReceivedByteCount": decoder_received,
        "bufferedBytesDiscarded": max(0, network_received - decoder_received),
        "appendWorkAfterCancellationRequestNs": post_cancel_append_work,
        "previewGeneratedAfterCancellationRequestCount": len(generated_after_request),
        "generatedPreviewCount": len(candidates),
        "presentedPreviewCount": len(preview_presented),
        "supersededOrFencedPreviewCount": len(candidates) - len(preview_presented),
        "pendingPreviewSuppressedAtCancellationCount": len(pending_suppressed),
        "presentedPreviewGenerations": [entry["generation"] for entry in preview_presented],
    }


def summarize_case(samples: list[dict[str, Any]]) -> dict[str, Any]:
    duration_fields = [
        "networkCompleteNs",
        "finalGeneratedNs",
        "finalAcceptedNs",
        "finalPresentedNs",
        "firstPreviewGeneratedNs",
        "firstPreviewAcceptedNs",
        "firstPreviewPresentedNs",
        "progressiveVisibleWindowNs",
        "maximumDecodeQueueDelayNs",
        "meanDecodeQueueDelayNs",
        "decoderIdleBeforeFinalNs",
        "finalAfterNetworkCompleteNs",
        "cancellationRequestedNs",
        "cancellationCompletedNs",
        "cancellationBlockingNs",
        "appendWorkAfterCancellationRequestNs",
    ]
    count_fields = [
        "generatedPreviewCount",
        "presentedPreviewCount",
        "supersededPreviewCount",
        "maximumBufferedNetworkBytes",
        "networkReceivedByteCount",
        "decoderReceivedByteCount",
        "bufferedBytesDiscarded",
        "previewGeneratedAfterCancellationRequestCount",
        "supersededOrFencedPreviewCount",
        "pendingPreviewSuppressedAtCancellationCount",
    ]
    summary: dict[str, Any] = {
        "sampleCount": len(samples),
        "completionCount": sum(1 for sample in samples if sample["completed"]),
    }
    for field in duration_fields:
        values = [sample[field] for sample in samples if field in sample and sample[field] is not None]
        if values:
            summary[field] = statistics(values)
    for field in count_fields:
        values = [sample[field] for sample in samples if field in sample]
        if values:
            summary[field] = count_statistics(values)
    generation_sequences = [sample.get("presentedPreviewGenerations", []) for sample in samples]
    summary["presentedPreviewGenerationSequences"] = generation_sequences
    return summary


def validate_profile(profile: dict[str, Any]) -> None:
    require(profile["schemaVersion"] == 1, "unsupported profile schema")
    require(profile["profileVersion"] == "imagecraft-progressive-pipeline-profile-v1", "wrong profile version")
    require(profile["buildConfiguration"] == "release", "profile is not Release")
    require(profile["samples"], "profile has no samples")
    reference = profile["samples"][0]
    for sample in profile["samples"]:
        require(len(sample["chunks"]) == profile["chunkCount"], "chunk count mismatch")
        require(sample["finalPixelRGBSHA256"] == reference["finalPixelRGBSHA256"], "final pixel drift")
        require(
            [chunk.get("generation") for chunk in sample["chunks"]]
            == [chunk.get("generation") for chunk in reference["chunks"]],
            "generation boundary drift",
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile-16k", type=Path, required=True)
    parser.add_argument("--profile-32k", type=Path, required=True)
    args = parser.parse_args()

    profile_16k = json.loads(args.profile_16k.read_text(encoding="utf-8"))
    profile_32k = json.loads(args.profile_32k.read_text(encoding="utf-8"))
    validate_profile(profile_16k)
    validate_profile(profile_32k)
    require(profile_16k["encodedSHA256"] == profile_32k["encodedSHA256"], "profiles use different inputs")
    require(profile_16k["chunkSizeBytes"] == 16_384, "wrong 16K profile")
    require(profile_32k["chunkSizeBytes"] == 32_768, "wrong 32K profile")

    networks = [
        {
            "id": "decode-pressure-80mbps-32k",
            "profile": profile_32k,
            "bitsPerSecond": 80_000_000,
            "firstChunkDelayNanoseconds": 10_000_000,
            "cancellationDeadlineNanoseconds": 25_000_000,
        },
        {
            "id": "network-dominant-4mbps-16k",
            "profile": profile_16k,
            "bitsPerSecond": 4_000_000,
            "firstChunkDelayNanoseconds": 50_000_000,
            "cancellationDeadlineNanoseconds": 180_000_000,
        },
    ]
    policies = ["immediate", "frame-coalesced-60hz"]
    cases = []
    for network in networks:
        profile = network["profile"]
        network_public = {key: value for key, value in network.items() if key != "profile"}
        for policy in policies:
            complete_samples = [
                simulate_complete_iteration(sample, network, policy)
                for sample in profile["samples"]
            ]
            cases.append(
                {
                    "caseID": f"{network['id']}--{policy}--complete",
                    "network": network_public,
                    "presentationPolicy": policy,
                    "cancellationMode": "none",
                    "samples": complete_samples,
                    "summary": summarize_case(complete_samples),
                }
            )
            cancelled_samples = [
                simulate_cancelled_iteration(sample, network, policy)
                for sample in profile["samples"]
            ]
            cases.append(
                {
                    "caseID": f"{network['id']}--{policy}--cancel",
                    "network": network_public,
                    "presentationPolicy": policy,
                    "cancellationMode": "fence-presentation-at-request; session-cancel-completes-after-in-flight-append",
                    "samples": cancelled_samples,
                    "summary": summarize_case(cancelled_samples),
                }
            )

    output = {
        "schemaVersion": 1,
        "simulationVersion": "imagecraft-progressive-pipeline-simulation-v1",
        "frameIntervalNanoseconds": FRAME_INTERVAL_NS,
        "input": {
            "encodedSHA256": profile_16k["encodedSHA256"],
            "encodedByteCount": profile_16k["encodedByteCount"],
            "sourceID": profile_16k["sourceID"],
            "scanScriptID": profile_16k["scanScriptID"],
            "profile16KCaseID": profile_16k["caseID"],
            "profile32KCaseID": profile_32k["caseID"],
        },
        "modelBoundary": {
            "measured": [
                "per-chunk ImageIO append duration",
                "generation byte boundary",
                "detached-task to MainActor.run handoff duration",
                "finish duration",
                "final full decode duration",
            ],
            "simulated": [
                "exact encoded-byte arrival times",
                "decode queue backlog",
                "60 Hz host-decision coalescing",
                "presentation cancellation fence",
                "in-flight append cancellation blocking",
            ],
            "notMeasured": [
                "URLSession or kernel networking",
                "Core Animation commit",
                "GPU presentation",
                "display-link callback",
                "energy",
            ],
        },
        "cases": cases,
    }
    print(json.dumps(output, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
