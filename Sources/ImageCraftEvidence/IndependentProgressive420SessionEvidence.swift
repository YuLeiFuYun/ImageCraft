import Foundation
import ImageCraftCore
import ImageCraftImageIO

private enum IndependentProgressive420SessionEvidenceError: Error {
  case invalidSchedule(String)
  case invariantViolation(String)
}

private struct IndependentProgressive420SessionSourceFacts: Codable {
  let byteCount: Int
  let sha256: String
  let maximumEntropyScanByteCount: Int
  let restartMarkerCount: Int
}

private struct IndependentProgressive420SessionScheduleReport: Codable {
  let id: String
  let chunkCount: Int
  let smallestChunkByteCount: Int
  let largestChunkByteCount: Int
  let completedScans: [Int]
}

private struct IndependentProgressive420SessionReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let source: IndependentProgressive420SessionSourceFacts
  let width: Int
  let height: Int
  let scanCount: Int
  let statePlan: JPEGIndependentProgressive420StatePlan
  let previewCadence: String
  let schedule: IndependentProgressive420SessionScheduleReport
  let transportCapacityBytes: Int
  let maximumMarkerSegmentEncodedBytes: Int
  let maximumMarkerSemanticUnitBytes: Int
  let maximumACFirstTransactionBitCount: Int
  let maximumInterleavedDCFirstTransactionBitCount: Int
  let maximumACRefineTransactionBitCount: Int
  let maximumEntropyTransactionEncodedBytes: Int
  let preFrameTableStateByteCount: Int
  let rollbackCoefficientBytes: Int
  let dummyCoefficientScratchByteCount: Int
  let initialRetainedByteCharge: Int
  let actualInitialRetainedByteCharge: Int
  let operationScratchByteCharge: Int
  let frameQuantizationSourceByteCount: Int
  let progressionStateByteCount: Int
  let persistentBaseFixedStateByteCount: Int
  let maximumHuffmanTablePayloadByteCount: Int
  let maximumHuffmanStateByteCount: Int
  let persistentBaseStateByteCount: Int
  let persistentStateByteCount: Int
  let renderScratchByteCount: Int
  let finalSamplePlaneByteCount: Int
  let finalSampleMaterializationScratchByteCount: Int
  let retainedByteChargeBeforeFinish: Int
  let maximumRetainedByteChargeBeforeFinish: Int
  let operationPeakByteCharge: Int
  let maximumObservedTransportBytes: Int
  let retainedPreFrameTableBytesBeforeFinish: Int
  let maximumObservedPreFrameTableBytes: Int
  let retainedFrameQuantizationSourceBytesBeforeFinish: Int
  let maximumObservedFrameQuantizationSourceBytes: Int
  let retainedHuffmanTableBytesBeforeFinish: Int
  let maximumObservedHuffmanTableBytes: Int
  let finalHuffmanTableBytesBeforeCompaction: Int
  let observedPreviewCount: Int
  let previewBackingWasStable: Bool
  let acceptedEncodedBytes: Int
  let reclaimedEncodedBytes: Int
  let retainedTransportBytesBeforeFinish: Int
  let preFinishResourceLedger: ImageDecodeResourceLedgerSnapshot
  let finalRGBByteCount: Int
  let finalRGBSHA256: String
  let completeDecoderRGBSHA256: String
  let finalMatchesCompleteDecoder: Bool
  let terminalResourceLedger: ImageDecodeResourceLedgerSnapshot
}

func writeIndependentProgressive420SessionEvidence(
  input: URL,
  scheduleID: String,
  previewCadenceID: String
) throws {
  let data = try Data(contentsOf: input)
  let sourceFacts = try inspectProgressiveSessionSourceFacts(data)
  let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
  let pixelCount = plan.width.multipliedReportingOverflow(by: plan.height)
  guard !pixelCount.overflow else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation("pixel count overflow")
  }
  let outputByteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
  guard !outputByteCount.overflow else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation("RGB byte count overflow")
  }
  let referenceCharge = outputByteCount.partialValue.addingReportingOverflow(plan.totalStateBytes)
  guard !referenceCharge.overflow else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation("reference charge overflow")
  }
  let reference = try JPEGIndependentProgressive420Decoder(
    maximumOperationByteCharge: referenceCharge.partialValue
  ).decode(data)

  let cadence: JPEGIndependentProgressive420Decoder.IncrementalSessionPreviewCadence
  switch previewCadenceID {
  case "every-completed-scan":
    cadence = .everyCompletedScan
  case "final-only":
    cadence = .finalOnly
  default:
    throw IndependentProgressive420SessionEvidenceError.invalidSchedule(
      "unsupported preview cadence: \(previewCadenceID)"
    )
  }

  let chunks = try progressiveSessionChunks(data: data, scheduleID: scheduleID)
  guard !chunks.isEmpty else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation("empty chunk schedule")
  }
  let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
    .requiredOperationPeakByteCharge(
      statePlan: plan,
      outputByteCount: outputByteCount.partialValue,
      previewCadence: cadence
    )
  let maximumRetainedCharge: Int
  switch cadence {
  case .everyCompletedScan:
    maximumRetainedCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .retainedByteChargeAfterFrame(
        statePlan: plan,
        outputByteCount: outputByteCount.partialValue
      )
  case .finalOnly:
    maximumRetainedCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .retainedByteChargeBeforeFinalOnlyFinish(statePlan: plan)
  }
  let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
    maximumCodecOwnedByteCharge: sessionCharge,
    previewCadence: cadence
  )
  let initial = session.snapshot()
  guard initial.phase == .awaitingHeader,
    initial.codecOwnedByteCharge
      == JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes,
    initial.retainedPreFrameTableBytes == 0,
    initial.maximumObservedPreFrameTableBytes == 0
  else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation(
      "initial session state does not prove empty dynamic pre-frame table ownership"
    )
  }

  var completedScans: [Int] = []
  var smallestChunk = Int.max
  var largestChunk = 0
  var observedPreviewCount = 0
  var firstPreviewBackingAddress: UInt?
  var previewBackingWasStable = true
  for chunk in chunks {
    smallestChunk = min(smallestChunk, chunk.count)
    largestChunk = max(largestChunk, chunk.count)
    let newlyCompleted = try session.append(chunk)
    completedScans.append(contentsOf: newlyCompleted)
    if cadence == .everyCompletedScan, !newlyCompleted.isEmpty {
      try session.withCurrentPreview { scan, pixels in
        guard scan == newlyCompleted.last, let baseAddress = pixels.baseAddress else {
          throw IndependentProgressive420SessionEvidenceError.invariantViolation(
            "preview generation does not match completed scan"
          )
        }
        let address = UInt(bitPattern: baseAddress)
        if let firstPreviewBackingAddress {
          previewBackingWasStable = previewBackingWasStable && address == firstPreviewBackingAddress
        } else {
          firstPreviewBackingAddress = address
        }
        observedPreviewCount += 1
      }
    }
  }
  let preFinish = session.snapshot()
  let retainedCharge = preFinish.codecOwnedByteCharge
  guard let finalHuffmanTableBytesBeforeCompaction =
    preFinish.finalHuffmanTableBytesBeforeCompaction,
    preFinish.phase == .complete,
    preFinish.acceptedEncodedBytes == data.count,
    preFinish.reclaimedEncodedBytes == data.count,
    preFinish.retainedTransportBytes == 0,
    preFinish.retainedPreFrameTableBytes == 0,
    preFinish.retainedFrameQuantizationSourceBytes == 0,
    preFinish.retainedHuffmanTableBytes == 0,
    retainedCharge == outputByteCount.partialValue,
    preFinish.maximumObservedFrameQuantizationSourceBytes > 0,
    preFinish.maximumObservedFrameQuantizationSourceBytes
      <= JPEGIndependentProgressive420Decoder.IncrementalSession.frameQuantizationSourceByteCount,
    preFinish.completedScanCount == reference.scanCount,
    completedScans == Array(1...reference.scanCount),
    preFinish.statePlan == plan,
    preFinish.codecOwnedByteCharge == retainedCharge,
    preFinish.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls) == retainedCharge,
    preFinish.resourceLedger.bytesUpperBound(for: .operationPeak) == sessionCharge
  else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation(
      "pre-finish session state does not prove complete input reclamation"
    )
  }

  let streamed = try session.finish()
  let terminal = session.snapshot()
  let matches = streamed.rgb == reference.rgb
  guard matches,
    streamed.width == reference.width,
    streamed.height == reference.height,
    streamed.scanCount == reference.scanCount,
    streamed.statePlan == reference.statePlan,
    streamed.operationByteCharge == sessionCharge,
    terminal.resourceLedger == ImageDecodeResourceLedgerSnapshot.terminal,
    terminal.codecOwnedByteCharge == 0,
    terminal.retainedTransportBytes == 0
  else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation(
      "streamed final state does not match complete decoder or reclaim terminal state"
    )
  }

  let report = IndependentProgressive420SessionReport(
    schemaVersion: 17,
    evidenceVersion: "imagecraft-independent-progressive-jpeg-420-session-v17",
    source: sourceFacts,
    width: streamed.width,
    height: streamed.height,
    scanCount: streamed.scanCount,
    statePlan: streamed.statePlan,
    previewCadence: previewCadenceID,
    schedule: IndependentProgressive420SessionScheduleReport(
      id: scheduleID,
      chunkCount: chunks.count,
      smallestChunkByteCount: smallestChunk,
      largestChunkByteCount: largestChunk,
      completedScans: completedScans
    ),
    transportCapacityBytes: JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes,
    maximumMarkerSegmentEncodedBytes: JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSegmentEncodedBytes,
    maximumMarkerSemanticUnitBytes: JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSemanticUnitBytes,
    maximumACFirstTransactionBitCount: JPEGIndependentProgressive420Decoder.IncrementalSession.maximumACFirstTransactionBitCount,
    maximumInterleavedDCFirstTransactionBitCount: JPEGIndependentProgressive420Decoder.IncrementalSession.maximumInterleavedDCFirstTransactionBitCount,
    maximumACRefineTransactionBitCount: JPEGIndependentProgressive420Decoder.IncrementalSession.maximumACRefineTransactionBitCount,
    maximumEntropyTransactionEncodedBytes: JPEGIndependentProgressive420Decoder.IncrementalSession.maximumEntropyTransactionEncodedBytes,
    preFrameTableStateByteCount: JPEGIndependentProgressive420Decoder.IncrementalSession.preFrameTableStateByteCount,
    rollbackCoefficientBytes: JPEGIndependentProgressive420Decoder.IncrementalSession.rollbackCoefficientBytes,
    dummyCoefficientScratchByteCount: JPEGIndependentProgressive420Decoder.IncrementalSession.dummyCoefficientScratchByteCount,
    initialRetainedByteCharge: JPEGIndependentProgressive420Decoder.IncrementalSession.initialRetainedByteCharge,
    actualInitialRetainedByteCharge: initial.codecOwnedByteCharge,
    operationScratchByteCharge: JPEGIndependentProgressive420Decoder.IncrementalSession.operationScratchByteCharge,
    frameQuantizationSourceByteCount: JPEGIndependentProgressive420Decoder.IncrementalSession.frameQuantizationSourceByteCount,
    progressionStateByteCount: JPEGIndependentProgressive420StatePlan.progressionStateByteCount,
    persistentBaseFixedStateByteCount: JPEGIndependentProgressive420StatePlan.persistentBaseFixedStateByteCount,
    maximumHuffmanTablePayloadByteCount: JPEGIndependentProgressive420StatePlan.maximumHuffmanTablePayloadByteCount,
    maximumHuffmanStateByteCount: JPEGIndependentProgressive420StatePlan.maximumHuffmanStateByteCount,
    persistentBaseStateByteCount: plan.persistentBaseStateBytes,
    persistentStateByteCount: plan.persistentStateBytes,
    renderScratchByteCount: plan.renderScratchBytes,
    finalSamplePlaneByteCount: try JPEGIndependentProgressive420Decoder.IncrementalSession
      .finalSamplePlaneByteCount(statePlan: plan),
    finalSampleMaterializationScratchByteCount:
      JPEGIndependentProgressive420Decoder.IncrementalSession
        .finalSampleMaterializationScratchByteCount,
    retainedByteChargeBeforeFinish: retainedCharge,
    maximumRetainedByteChargeBeforeFinish: maximumRetainedCharge,
    operationPeakByteCharge: sessionCharge,
    maximumObservedTransportBytes: preFinish.maximumObservedTransportBytes,
    retainedPreFrameTableBytesBeforeFinish: preFinish.retainedPreFrameTableBytes,
    maximumObservedPreFrameTableBytes: preFinish.maximumObservedPreFrameTableBytes,
    retainedFrameQuantizationSourceBytesBeforeFinish:
      preFinish.retainedFrameQuantizationSourceBytes,
    maximumObservedFrameQuantizationSourceBytes:
      preFinish.maximumObservedFrameQuantizationSourceBytes,
    retainedHuffmanTableBytesBeforeFinish: preFinish.retainedHuffmanTableBytes,
    maximumObservedHuffmanTableBytes: preFinish.maximumObservedHuffmanTableBytes,
    finalHuffmanTableBytesBeforeCompaction: finalHuffmanTableBytesBeforeCompaction,
    observedPreviewCount: observedPreviewCount,
    previewBackingWasStable: previewBackingWasStable,
    acceptedEncodedBytes: preFinish.acceptedEncodedBytes,
    reclaimedEncodedBytes: preFinish.reclaimedEncodedBytes,
    retainedTransportBytesBeforeFinish: preFinish.retainedTransportBytes,
    preFinishResourceLedger: preFinish.resourceLedger,
    finalRGBByteCount: streamed.rgb.count,
    finalRGBSHA256: sha256(streamed.rgb),
    completeDecoderRGBSHA256: sha256(reference.rgb),
    finalMatchesCompleteDecoder: matches,
    terminalResourceLedger: terminal.resourceLedger
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation("report is not UTF-8")
  }
  print(json)
}

private func progressiveSessionChunks(data: Data, scheduleID: String) throws -> [Data] {
  if scheduleID == "single-byte" {
    return data.map { Data([$0]) }
  }
  if scheduleID == "whole-file" {
    return [data]
  }
  if scheduleID == "split-restart-markers" {
    var boundaries: [Int] = []
    if data.count >= 2 {
      for offset in 0..<(data.count - 1)
      where data[offset] == 0xFF && (0xD0...0xD7).contains(data[offset + 1])
      {
        boundaries.append(offset + 1)
      }
    }
    guard !boundaries.isEmpty else {
      throw IndependentProgressive420SessionEvidenceError.invalidSchedule(
        "split-restart-markers requires at least one RST marker"
      )
    }
    boundaries.append(data.count)
    var chunks: [Data] = []
    var start = 0
    for end in boundaries where end > start {
      chunks.append(data.subdata(in: start..<end))
      start = end
    }
    return chunks
  }
  let prefix = "fixed-"
  if scheduleID.hasPrefix(prefix),
    let byteCount = Int(scheduleID.dropFirst(prefix.count)),
    byteCount > 0
  {
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + byteCount)
      chunks.append(data.subdata(in: offset..<end))
      offset = end
    }
    return chunks
  }
  throw IndependentProgressive420SessionEvidenceError.invalidSchedule(
    "unsupported chunk schedule: \(scheduleID)"
  )
}

private func inspectProgressiveSessionSourceFacts(
  _ data: Data
) throws -> IndependentProgressive420SessionSourceFacts {
  guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
    throw IndependentProgressive420SessionEvidenceError.invariantViolation("input is not JPEG")
  }
  var offset = 2
  var maximumEntropyScanByteCount = 0
  var restartMarkerCount = 0
  while offset < data.count {
    guard data[offset] == 0xFF else {
      throw IndependentProgressive420SessionEvidenceError.invariantViolation(
        "expected structural marker at \(offset)"
      )
    }
    while offset < data.count, data[offset] == 0xFF { offset += 1 }
    guard offset < data.count else {
      throw IndependentProgressive420SessionEvidenceError.invariantViolation("truncated marker")
    }
    let marker = data[offset]
    offset += 1
    if marker == 0xD9 {
      guard offset == data.count else {
        throw IndependentProgressive420SessionEvidenceError.invariantViolation("JPEG trailing bytes")
      }
      return IndependentProgressive420SessionSourceFacts(
        byteCount: data.count,
        sha256: sha256(data),
        maximumEntropyScanByteCount: maximumEntropyScanByteCount,
        restartMarkerCount: restartMarkerCount
      )
    }
    if marker == 0x01 || (0xD0...0xD7).contains(marker) {
      if (0xD0...0xD7).contains(marker) { restartMarkerCount += 1 }
      continue
    }
    guard offset + 2 <= data.count else {
      throw IndependentProgressive420SessionEvidenceError.invariantViolation("truncated segment")
    }
    let length = Int(data[offset]) << 8 | Int(data[offset + 1])
    guard length >= 2, offset + length <= data.count else {
      throw IndependentProgressive420SessionEvidenceError.invariantViolation("invalid segment")
    }
    let segmentEnd = offset + length
    if marker != 0xDA {
      offset = segmentEnd
      continue
    }
    let entropyStart = segmentEnd
    var cursor = entropyStart
    while cursor < data.count {
      if data[cursor] != 0xFF {
        cursor += 1
        continue
      }
      let markerStart = cursor
      while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
      guard cursor < data.count else {
        throw IndependentProgressive420SessionEvidenceError.invariantViolation("truncated entropy")
      }
      let code = data[cursor]
      if code == 0x00 {
        cursor += 1
        continue
      }
      if (0xD0...0xD7).contains(code) {
        restartMarkerCount += 1
        cursor += 1
        continue
      }
      maximumEntropyScanByteCount = max(
        maximumEntropyScanByteCount,
        markerStart - entropyStart
      )
      offset = markerStart
      break
    }
  }
  throw IndependentProgressive420SessionEvidenceError.invariantViolation("missing EOI")
}
