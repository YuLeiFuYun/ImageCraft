import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let progressiveJPEGPreparationCreationEvidenceVersion =
  "imagecraft-progressive-jpeg-preparation-creation-v1"

private struct ProgressiveJPEGPreparationCreationSource: Codable {
  let byteCount: Int
  let sha256: String
}

private struct ProgressiveJPEGPreparationCreationReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let source: ProgressiveJPEGPreparationCreationSource
  let chunkByteCount: Int
  let chunkCount: Int
  let inputProfile: String
  let preflightProgress: String
  let preflightWasNonConsuming: Bool
  let operationResourceLedger: ImageDecodeResourceLedgerSnapshot
  let resultingPreparationRetainedKnownBytes: Int
  let resultingPreparationRetainedBetweenCalls: ImageDecodeResourceBound
  let finalizationSourceByteCount: Int
  let postTokenResourceLedger: ImageDecodeResourceLedgerSnapshot
  let preparationLedgerMatchesPreflightResult: Bool
  let sessionTerminalResourceLedger: ImageDecodeResourceLedgerSnapshot
  let postDiscardPreparationLedgerAbsent: Bool
}

func writeProgressiveJPEGPreparationCreationEvidence(input: URL) throws {
  let data = try Data(contentsOf: input)
  let decoder = ImageIOImageDecoder()
  let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
  let session = try decoder.makeProgressiveSession(
    format: .jpeg,
    request: request,
    limits: .coreV1
  )
  guard let creating =
    session as? any ProgressiveImagePreparationCreationResourceInspectingSession,
    let qualifying = session as? any ImageProgressiveSessionQualifying
  else { throw EvidenceError.invalidArguments }

  let chunkByteCount = 17
  var offset = 0
  var chunkCount = 0
  while offset < data.count {
    let end = min(data.count, offset + chunkByteCount)
    _ = try session.append(data.subdata(in: offset..<end))
    chunkCount += 1
    offset = end
  }

  let beforePreflight = qualifying.qualificationSnapshot
  guard beforePreflight.progress == .finalReady,
    beforePreflight.inputProfile == .arbitraryChunk,
    beforePreflight.receivedByteCount == data.count
  else { throw EvidenceError.invalidArguments }
  guard let authority = try creating.preparationCreationResourceAuthority() else {
    throw EvidenceError.invalidArguments
  }
  let afterPreflight = qualifying.qualificationSnapshot
  guard beforePreflight == afterPreflight else { throw EvidenceError.invalidArguments }

  let finalization = try creating.finishWithPreparation()
  guard finalization.sourceByteCount == data.count else { throw EvidenceError.invalidArguments }
  guard let postTokenLedger = decoder.preparationResourceLedger(
    finalization.preparation,
    request: request,
    limits: .coreV1
  ) else { throw EvidenceError.invalidArguments }
  let preparationLedgerMatchesPreflightResult =
    postTokenLedger.retainedKnownBytes == authority.resultingPreparationRetainedKnownBytes
    && postTokenLedger.retainedBetweenCalls
      == authority.resultingPreparationRetainedBetweenCalls
  guard preparationLedgerMatchesPreflightResult else { throw EvidenceError.invalidArguments }
  let terminal = qualifying.qualificationSnapshot
  guard terminal.progress == .terminal, terminal.resourceLedger.isTerminal else {
    throw EvidenceError.invalidArguments
  }

  decoder.discard(finalization.preparation)
  let postDiscardPreparationLedgerAbsent = decoder.preparationResourceLedger(
    finalization.preparation,
    request: request,
    limits: .coreV1
  ) == nil
  guard postDiscardPreparationLedgerAbsent else { throw EvidenceError.invalidArguments }

  let report = ProgressiveJPEGPreparationCreationReport(
    schemaVersion: 1,
    evidenceVersion: progressiveJPEGPreparationCreationEvidenceVersion,
    source: ProgressiveJPEGPreparationCreationSource(
      byteCount: data.count,
      sha256: sha256(data)
    ),
    chunkByteCount: chunkByteCount,
    chunkCount: chunkCount,
    inputProfile: "arbitraryChunk",
    preflightProgress: "finalReady",
    preflightWasNonConsuming: true,
    operationResourceLedger: authority.operationResourceLedger,
    resultingPreparationRetainedKnownBytes:
      authority.resultingPreparationRetainedKnownBytes,
    resultingPreparationRetainedBetweenCalls:
      authority.resultingPreparationRetainedBetweenCalls,
    finalizationSourceByteCount: finalization.sourceByteCount,
    postTokenResourceLedger: postTokenLedger,
    preparationLedgerMatchesPreflightResult: preparationLedgerMatchesPreflightResult,
    sessionTerminalResourceLedger: terminal.resourceLedger,
    postDiscardPreparationLedgerAbsent: postDiscardPreparationLedgerAbsent
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}
