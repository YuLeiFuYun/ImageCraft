import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let staticPreparationCreationEvidenceVersion =
  "imagecraft-static-preparation-creation-v1"

private struct StaticPreparationCreationSource: Codable {
  let byteCount: Int
  let sha256: String
}

private struct StaticPreparationCreationProbe: Codable {
  let pixelWidth: Int
  let pixelHeight: Int
  let frameCount: Int
  let orientation: UInt32
  let format: String
  let metadataByteCount: Int
  let auxiliaryAttachmentCount: Int
  let sourceColorProfile: String
}

private struct StaticPreparationCreationReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let source: StaticPreparationCreationSource
  let preflightStoreUnchanged: Bool
  let authority: ImageDecodePreparationCreationResourceAuthority
  let preparedProbe: StaticPreparationCreationProbe
  let postTokenResourceLedger: ImageDecodeResourceLedgerSnapshot
  let postTokenRetainedMatchesPreflightResult: Bool
  let postDiscardPreparationLedgerAbsent: Bool
}

func writeStaticPreparationCreationEvidence(input: URL) throws {
  let data = try Data(contentsOf: input)
  let decoder = ImageIOImageDecoder()
  let inspecting: any PreparedImageCreationResourceInspecting = decoder
  let before = decoder.preparationStoreQualificationSnapshot()
  let authority = try inspecting.preparationCreationResourceAuthority(
    data: data,
    limits: .coreV1
  )
  let after = decoder.preparationStoreQualificationSnapshot()
  guard before == after else { throw EvidenceError.invalidArguments }

  let preparation = try inspecting.prepare(data: data, limits: .coreV1)
  let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
  guard let postTokenLedger = decoder.preparationResourceLedger(
    preparation,
    request: request,
    limits: .coreV1
  ) else { throw EvidenceError.invalidArguments }
  let retainedMatches =
    postTokenLedger.retainedKnownBytes == authority.resultingPreparationRetainedKnownBytes
    && postTokenLedger.retainedBetweenCalls
      == authority.resultingPreparationRetainedBetweenCalls
  guard retainedMatches else { throw EvidenceError.invalidArguments }

  let probe = preparation.probe
  decoder.discard(preparation)
  let postDiscardAbsent = decoder.preparationResourceLedger(
    preparation,
    request: request,
    limits: .coreV1
  ) == nil
  guard postDiscardAbsent else { throw EvidenceError.invalidArguments }

  let report = StaticPreparationCreationReport(
    schemaVersion: 1,
    evidenceVersion: staticPreparationCreationEvidenceVersion,
    source: StaticPreparationCreationSource(byteCount: data.count, sha256: sha256(data)),
    preflightStoreUnchanged: true,
    authority: authority,
    preparedProbe: StaticPreparationCreationProbe(
      pixelWidth: probe.pixelWidth,
      pixelHeight: probe.pixelHeight,
      frameCount: probe.frameCount,
      orientation: probe.orientation,
      format: probe.format.rawValue,
      metadataByteCount: probe.metadataByteCount,
      auxiliaryAttachmentCount: probe.auxiliaryAttachmentCount,
      sourceColorProfile: probe.sourceColorProfile.rawValue
    ),
    postTokenResourceLedger: postTokenLedger,
    postTokenRetainedMatchesPreflightResult: retainedMatches,
    postDiscardPreparationLedgerAbsent: postDiscardAbsent
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}
