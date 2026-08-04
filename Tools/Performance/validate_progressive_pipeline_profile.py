#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

EXPECTED_VERSION = "imagecraft-progressive-pipeline-profile-v1"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def percentile(sorted_values: list[int], numerator: int, denominator: int) -> int:
    rank = max(1, (len(sorted_values) * numerator + denominator - 1) // denominator)
    return sorted_values[min(len(sorted_values) - 1, rank - 1)]


def duration_statistics(values: list[int]) -> dict[str, int]:
    require(values, "duration statistics require values")
    ordered = sorted(values)
    return {
        "minimumNanoseconds": ordered[0],
        "medianNanoseconds": percentile(ordered, 50, 100),
        "p90Nanoseconds": percentile(ordered, 90, 100),
        "maximumNanoseconds": ordered[-1],
        "meanNanoseconds": sum(values) // len(values),
    }


def expected_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    reference = samples[0]
    chunk_count = len(reference["chunks"])
    chunks = []
    for index in range(chunk_count):
        peers = [sample["chunks"][index] for sample in samples]
        first = peers[0]
        static_fields = (
            "chunkIndex",
            "chunkByteCount",
            "cumulativeByteCount",
            "generation",
            "generationSourceByteCount",
        )
        for peer in peers[1:]:
            for field in static_fields:
                require(peer.get(field) == first.get(field), f"chunk {index} drifted at {field}")
        entry: dict[str, Any] = {
            "chunkIndex": first["chunkIndex"],
            "chunkByteCount": first["chunkByteCount"],
            "cumulativeByteCount": first["cumulativeByteCount"],
            "appendDuration": duration_statistics(
                [peer["appendDurationNanoseconds"] for peer in peers]
            ),
        }
        if "generation" in first:
            entry["generation"] = first["generation"]
            entry["generationSourceByteCount"] = first["generationSourceByteCount"]
            handoffs = [peer["mainActorHandoffNanoseconds"] for peer in peers]
            entry["mainActorHandoff"] = duration_statistics(handoffs)
        chunks.append(entry)

    generation_chunks = [chunk for chunk in reference["chunks"] if "generation" in chunk]
    return {
        "generationCount": len(generation_chunks),
        "generationSequence": [chunk["generation"] for chunk in generation_chunks],
        "generationSourceByteCounts": [
            chunk["generationSourceByteCount"] for chunk in generation_chunks
        ],
        "chunks": chunks,
        "finishDuration": duration_statistics(
            [sample["finishDurationNanoseconds"] for sample in samples]
        ),
        "finalDecodeDuration": duration_statistics(
            [sample["finalDecodeDurationNanoseconds"] for sample in samples]
        ),
        "finalMainActorHandoff": duration_statistics(
            [sample["finalMainActorHandoffNanoseconds"] for sample in samples]
        ),
        "finalAnalysisHashDuration": duration_statistics(
            [sample["finalAnalysisHashDurationNanoseconds"] for sample in samples]
        ),
        "totalDuration": duration_statistics(
            [sample["totalDurationNanoseconds"] for sample in samples]
        ),
    }


def validate(profile: dict[str, Any]) -> None:
    require(profile.get("schemaVersion") == 1, "unsupported profile schema")
    require(profile.get("profileVersion") == EXPECTED_VERSION, "wrong profile version")
    require(profile.get("buildConfiguration") == "release", "profile is not Release")
    require(profile.get("warmupIterations") == 1, "unexpected warmup count")
    iterations = profile.get("iterations")
    samples = profile.get("samples")
    require(isinstance(iterations, int) and 1 <= iterations <= 20, "invalid iteration count")
    require(isinstance(samples, list) and len(samples) == iterations, "sample count mismatch")
    require(isinstance(profile.get("chunkSizeBytes"), int) and profile["chunkSizeBytes"] > 0, "invalid chunk size")
    require(isinstance(profile.get("encodedByteCount"), int) and profile["encodedByteCount"] > 0, "invalid encoded size")
    require(isinstance(profile.get("encodedSHA256"), str) and len(profile["encodedSHA256"]) == 64, "invalid encoded digest")
    require(profile.get("handoffBoundary") == "detached orchestration to MainActor.run; not Core Animation or GPU presentation", "handoff boundary drifted")

    expected_chunk_count = (
        profile["encodedByteCount"] + profile["chunkSizeBytes"] - 1
    ) // profile["chunkSizeBytes"]
    require(profile.get("chunkCount") == expected_chunk_count, "declared chunk count mismatch")

    final_hashes = set()
    final_sizes = set()
    for sample_index, sample in enumerate(samples):
        chunks = sample.get("chunks")
        require(isinstance(chunks, list) and len(chunks) == expected_chunk_count, f"sample {sample_index}: chunk count mismatch")
        cumulative = 0
        generations = []
        for chunk_index, chunk in enumerate(chunks):
            require(chunk.get("chunkIndex") == chunk_index, f"sample {sample_index}: chunk index mismatch")
            byte_count = chunk.get("chunkByteCount")
            require(isinstance(byte_count, int) and 0 < byte_count <= profile["chunkSizeBytes"], f"sample {sample_index}: invalid chunk bytes")
            cumulative += byte_count
            require(chunk.get("cumulativeByteCount") == cumulative, f"sample {sample_index}: cumulative bytes mismatch")
            require(isinstance(chunk.get("appendDurationNanoseconds"), int) and chunk["appendDurationNanoseconds"] >= 0, f"sample {sample_index}: invalid append duration")
            if "generation" in chunk:
                generation = chunk["generation"]
                require(isinstance(generation, int) and generation > 0, f"sample {sample_index}: invalid generation")
                require(chunk.get("generationSourceByteCount") == cumulative, f"sample {sample_index}: generation source boundary mismatch")
                require(isinstance(chunk.get("mainActorHandoffNanoseconds"), int) and chunk["mainActorHandoffNanoseconds"] >= 0, f"sample {sample_index}: invalid handoff")
                generations.append(generation)
            else:
                require("generationSourceByteCount" not in chunk, f"sample {sample_index}: orphan generation source count")
                require("mainActorHandoffNanoseconds" not in chunk, f"sample {sample_index}: orphan handoff")
        require(cumulative == profile["encodedByteCount"], f"sample {sample_index}: encoded body incomplete")
        require(generations == list(range(1, len(generations) + 1)), f"sample {sample_index}: generation sequence mismatch")
        require(1 <= len(generations) <= 4, f"sample {sample_index}: invalid generation count")
        for field in (
            "finishDurationNanoseconds",
            "finalDecodeDurationNanoseconds",
            "finalMainActorHandoffNanoseconds",
            "finalAnalysisHashDurationNanoseconds",
            "totalDurationNanoseconds",
        ):
            require(isinstance(sample.get(field), int) and sample[field] >= 0, f"sample {sample_index}: invalid {field}")
        digest = sample.get("finalPixelRGBSHA256")
        require(isinstance(digest, str) and len(digest) == 64, f"sample {sample_index}: invalid final digest")
        final_hashes.add(digest)
        final_sizes.add((sample.get("finalPixelWidth"), sample.get("finalPixelHeight")))

    require(len(final_hashes) == 1, "final pixels drifted")
    require(len(final_sizes) == 1, "final dimensions drifted")
    require(profile.get("summary") == expected_summary(samples), "profile summary is not reproducible")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", type=Path)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text(encoding="utf-8"))
    validate(profile)
    print(f"Progressive pipeline profile passed: {args.profile}")


if __name__ == "__main__":
    main()
