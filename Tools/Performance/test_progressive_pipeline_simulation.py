#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simulate_progressive_pipeline as simulation  # noqa: E402


class ProgressivePipelineSimulationTests(unittest.TestCase):
    def test_arrival_times_use_exact_transfer_duration(self) -> None:
        chunks = [
            {"chunkByteCount": 100},
            {"chunkByteCount": 200},
            {"chunkByteCount": 50},
        ]
        arrivals = simulation.arrival_times(
            chunks,
            first_chunk_delay_ns=10,
            bits_per_second=80_000_000_000,
        )
        self.assertEqual(arrivals, [10, 30, 35])

    def test_frame_coalescing_keeps_latest_candidate_per_frame(self) -> None:
        candidates = [
            {"kind": "preview", "generation": 1, "acceptedNs": 1_000_000},
            {"kind": "preview", "generation": 2, "acceptedNs": 10_000_000},
            {"kind": "preview", "generation": 3, "acceptedNs": 20_000_000},
            {"kind": "final", "acceptedNs": 21_000_000},
        ]
        result = simulation.present_candidates(
            candidates,
            "frame-coalesced-60hz",
        )
        self.assertEqual(
            [(item["kind"], item.get("generation"), item["presentedNs"]) for item in result["presented"]],
            [
                ("preview", 2, simulation.FRAME_INTERVAL_NS),
                ("final", None, simulation.FRAME_INTERVAL_NS * 2),
            ],
        )
        self.assertEqual(
            [item.get("generation") for item in result["superseded"]],
            [1, 3],
        )

    def test_cancellation_waits_for_in_flight_append_and_fences_late_preview(self) -> None:
        sample = {
            "chunks": [
                {
                    "chunkIndex": 0,
                    "chunkByteCount": 100,
                    "cumulativeByteCount": 100,
                    "appendDurationNanoseconds": 5,
                    "generation": 1,
                    "generationSourceByteCount": 100,
                    "mainActorHandoffNanoseconds": 1,
                },
                {
                    "chunkIndex": 1,
                    "chunkByteCount": 100,
                    "cumulativeByteCount": 200,
                    "appendDurationNanoseconds": 20,
                    "generation": 2,
                    "generationSourceByteCount": 200,
                    "mainActorHandoffNanoseconds": 1,
                },
                {
                    "chunkIndex": 2,
                    "chunkByteCount": 100,
                    "cumulativeByteCount": 300,
                    "appendDurationNanoseconds": 5,
                },
            ],
            "finishDurationNanoseconds": 1,
            "finalDecodeDurationNanoseconds": 1,
            "finalMainActorHandoffNanoseconds": 1,
        }
        network = {
            "firstChunkDelayNanoseconds": 10,
            "bitsPerSecond": 80_000_000_000,
            "cancellationDeadlineNanoseconds": 25,
        }
        result = simulation.simulate_cancelled_iteration(
            sample,
            network,
            "immediate",
        )
        self.assertEqual(result["cancellationCompletedNs"], 40)
        self.assertEqual(result["cancellationBlockingNs"], 15)
        self.assertEqual(result["appendWorkAfterCancellationRequestNs"], 15)
        self.assertEqual(result["previewGeneratedAfterCancellationRequestCount"], 1)
        self.assertEqual(result["presentedPreviewGenerations"], [1])
        self.assertEqual(result["networkReceivedByteCount"], 200)
        self.assertEqual(result["decoderReceivedByteCount"], 200)

    def test_network_dominant_complete_path_has_no_decode_queue(self) -> None:
        sample = {
            "chunks": [
                {
                    "chunkIndex": 0,
                    "chunkByteCount": 100,
                    "cumulativeByteCount": 100,
                    "appendDurationNanoseconds": 2,
                    "generation": 1,
                    "generationSourceByteCount": 100,
                    "mainActorHandoffNanoseconds": 1,
                },
                {
                    "chunkIndex": 1,
                    "chunkByteCount": 100,
                    "cumulativeByteCount": 200,
                    "appendDurationNanoseconds": 2,
                },
            ],
            "finishDurationNanoseconds": 1,
            "finalDecodeDurationNanoseconds": 3,
            "finalMainActorHandoffNanoseconds": 1,
        }
        network = {
            "firstChunkDelayNanoseconds": 10,
            "bitsPerSecond": 8_000_000_000,
        }
        result = simulation.simulate_complete_iteration(
            sample,
            network,
            "immediate",
        )
        self.assertEqual(result["maximumDecodeQueueDelayNs"], 0)
        self.assertEqual(result["maximumBufferedNetworkBytes"], 100)
        self.assertEqual(result["presentedPreviewGenerations"], [1])
        self.assertGreater(result["finalPresentedNs"], result["networkCompleteNs"])


if __name__ == "__main__":
    unittest.main()
