import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let independentProgressive420PackedFinalizationEvidenceVersion =
  "imagecraft-independent-progressive-jpeg-420-packed-finalization-v8"

private struct IndependentProgressive420PackedFinalizationSource: Codable {
  let byteCount: Int
  let sha256: String
}

private struct IndependentProgressive420PackedFinalizationPackedValue: Codable {
  let pixelWidth: Int
  let pixelHeight: Int
  let bytesPerRow: Int
  let byteCount: Int
  let sha256: String
  let sampleStorage: String
  let channelLayout: String
  let alphaAssociation: String
  let colorEncoding: String
  let sourceColorProfile: String
  let pixelByteCharge: Int
  let transferredByteCharge: Int
}

private struct IndependentProgressive420PackedFinalizationDecodedValue: Codable {
  let pixelWidth: Int
  let pixelHeight: Int
  let bytesPerRow: Int
  let bitsPerComponent: Int
  let bitsPerPixel: Int
  let alphaInfo: String
  let colorSpaceModel: String
  let sourceColorProfile: String
  let providerByteCount: Int
  let providerSHA256: String
  let copiedPixelPayloadByteCount: Int
  let knownPixelPayloadOperationBytes: Int
  let providerBackingWasShared: Bool
  let resourceLedger: ImageDecodeResourceLedgerSnapshot
}

private struct IndependentProgressive420PackedFinalizationProbeValue: Codable {
  let pixelWidth: Int
  let pixelHeight: Int
  let frameCount: Int
  let orientation: UInt32
  let format: String
  let metadataByteCount: Int
  let auxiliaryAttachmentCount: Int
  let sourceColorProfile: String
}

private struct IndependentProgressive420PackedFinalizationReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let source: IndependentProgressive420PackedFinalizationSource
  let inputProfile: String
  let chunkByteCount: Int
  let chunkCount: Int
  let capabilityDiscoverable: Bool
  let preFinishProgress: String
  let preFinishResourceLedger: ImageDecodeResourceLedgerSnapshot
  let maximumTightRGBABytes: Int
  let retainsOpaqueFrameworkStateBetweenCalls: Bool
  let packed: IndependentProgressive420PackedFinalizationPackedValue
  let finalizationSourceByteCount: Int
  let packedMatchesKernelRGB: Bool
  let wrapperBackingWasShared: Bool
  let decoded: IndependentProgressive420PackedFinalizationDecodedValue
  let decodedResourceFinalizationCapabilityDiscoverable: Bool
  let publicResourceAwareDecodedFinalizationCapabilityAdvertised: Bool
  let publicDecodedFinalizationCapabilityAdvertised: Bool
  let decodedResourceFinalizationPreflightProgress: String
  let decodedResourceFinalizationPreflightWasNonConsuming: Bool
  let decodedResourceFinalizationPreflightLedger: ImageDecodeResourceLedgerSnapshot
  let decodedResourceFinalizationSourceByteCount: Int
  let decodedResourceFinalizationProbe: IndependentProgressive420PackedFinalizationProbeValue
  let decodedResourceFinalizationLedger: ImageDecodeResourceLedgerSnapshot
  let decodedResourceFinalizationProviderSHA256: String
  let decodedResourceFinalizationTerminalLedger: ImageDecodeResourceLedgerSnapshot
  let terminalProgress: String
  let terminalResourceLedger: ImageDecodeResourceLedgerSnapshot
}

func writeIndependentProgressive420PackedFinalizationEvidence(input: URL) throws {
  let data = try Data(contentsOf: input)
  let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
  let pixelCount = plan.width.multipliedReportingOverflow(by: plan.height)
  guard !pixelCount.overflow else { throw EvidenceError.pixelConversionFailed }
  let rgbBytes = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
  guard !rgbBytes.overflow else { throw EvidenceError.pixelConversionFailed }
  let oneShotCharge = plan.totalStateBytes.addingReportingOverflow(rgbBytes.partialValue)
  guard !oneShotCharge.overflow else { throw EvidenceError.pixelConversionFailed }
  let reference = try JPEGIndependentProgressive420Decoder(
    maximumOperationByteCharge: oneShotCharge.partialValue
  ).decode(data)
  let wrappedReference = try JPEGIndependentProgressive420SessionQualification.packedRGB8Value(
    from: reference
  )
  let referenceAddress = reference.rgb.withUnsafeBytes { raw -> UInt? in
    raw.baseAddress.map { UInt(bitPattern: $0) }
  }
  let wrappedAddress = wrappedReference.data.withUnsafeBytes { raw -> UInt? in
    raw.baseAddress.map { UInt(bitPattern: $0) }
  }
  let wrapperBackingWasShared = referenceAddress != nil && referenceAddress == wrappedAddress

  let operationPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
    .requiredOperationPeakByteCharge(
      statePlan: plan,
      outputByteCount: rgbBytes.partialValue,
      previewCadence: .finalOnly
    )
  let adapter = try JPEGIndependentProgressive420SessionQualification(
    maximumCodecOwnedByteCharge: operationPeak,
    previewCadence: .finalOnly
  )
  let session: any ImageProgressiveDecodeSession = adapter
  guard let capability = session as? any ProgressiveImagePackedRGB8FinalizingSession else {
    throw EvidenceError.pixelConversionFailed
  }

  let chunkByteCount = 17
  var chunkCount = 0
  var offset = 0
  while offset < data.count {
    let end = min(data.count, offset + chunkByteCount)
    guard try capability.append(data.subdata(in: offset..<end)) == nil else {
      throw EvidenceError.pixelConversionFailed
    }
    chunkCount += 1
    offset = end
  }
  let ready = adapter.qualificationSnapshot
  guard ready.progress == .finalReady,
    ready.inputProfile == .arbitraryChunk,
    ready.maximumTightRGBABytes == 0,
    !ready.retainsOpaqueFrameworkStateBetweenCalls,
    ready.resourceLedger.outputLayoutAuthority == .codecOwnedRGB8,
    ready.resourceLedger.bytesUpperBound(for: .transferredOutput) == rgbBytes.partialValue
  else { throw EvidenceError.pixelConversionFailed }

  let finalization = try capability.finishWithPackedRGB8()
  let packed = finalization.image
  let terminal = adapter.qualificationSnapshot
  guard finalization.sourceByteCount == data.count,
    packed.data == reference.rgb,
    packed.pixelWidth == plan.width,
    packed.pixelHeight == plan.height,
    packed.bytesPerRow == plan.width * 3,
    packed.colorEncoding == .sRGB,
    packed.sourceColorProfile == .absent,
    packed.pixelByteCharge == rgbBytes.partialValue,
    packed.transferredByteCharge == rgbBytes.partialValue,
    terminal.progress == .terminal,
    terminal.resourceLedger.isTerminal
  else { throw EvidenceError.pixelConversionFailed }

  let materialized = try ImagePackedRGB8DecodedImageMaterializer.materialize(packed)
  let cgImage = materialized.image.cgImage
  guard let providerData = cgImage.dataProvider?.data as Data?,
    providerData == packed.data,
    cgImage.width == packed.pixelWidth,
    cgImage.height == packed.pixelHeight,
    cgImage.bytesPerRow == packed.bytesPerRow,
    cgImage.bitsPerComponent == 8,
    cgImage.bitsPerPixel == 24,
    cgImage.alphaInfo == .none,
    cgImage.colorSpace?.model == .rgb,
    materialized.image.colorDescription.sourceProfile == .absent,
    materialized.providerBackingWasShared,
    materialized.copiedPixelPayloadByteCount == 0,
    materialized.resourceLedger.retainedBetweenCalls == .bounded(0),
    materialized.resourceLedger.operationPeak
      == .unknown(.frameworkPrivateOperationAllocation),
    materialized.resourceLedger.transferredOutput
      == .bounded(packed.transferredByteCharge),
    materialized.resourceLedger.outputLayoutAuthority == .codecOwnedRGB8
  else { throw EvidenceError.pixelConversionFailed }
  let knownPixelPayloadOperationBytes = packed.pixelByteCharge.addingReportingOverflow(
    materialized.copiedPixelPayloadByteCount
  )
  guard !knownPixelPayloadOperationBytes.overflow else {
    throw EvidenceError.pixelConversionFailed
  }

  let resourceAdapter = try JPEGIndependentProgressive420SessionQualification(
    maximumCodecOwnedByteCharge: operationPeak,
    previewCadence: .finalOnly
  )
  let resourceSession: any ImageProgressiveDecodeSession = resourceAdapter
  guard let decodedResourceCapability =
    resourceSession as? any ProgressiveImageDecodedImageResourceFinalizingSession,
    resourceSession as? any ProgressiveImageFinalizingSession == nil
  else { throw EvidenceError.pixelConversionFailed }
  var resourceOffset = 0
  while resourceOffset < data.count {
    let end = min(data.count, resourceOffset + chunkByteCount)
    guard try decodedResourceCapability.append(data.subdata(in: resourceOffset..<end)) == nil else {
      throw EvidenceError.pixelConversionFailed
    }
    resourceOffset = end
  }
  let resourceReady = resourceAdapter.qualificationSnapshot
  guard resourceReady.progress == .finalReady else { throw EvidenceError.pixelConversionFailed }
  let preflightBefore = resourceAdapter.qualificationSnapshot
  guard let decodedResourcePreflight = try decodedResourceCapability
    .decodedImageFinalizationResourceLedger()
  else { throw EvidenceError.pixelConversionFailed }
  let preflightAfter = resourceAdapter.qualificationSnapshot
  guard preflightAfter == preflightBefore,
    decodedResourcePreflight.retainedKnownBytes == resourceReady.resourceLedger.retainedKnownBytes,
    decodedResourcePreflight.retainedBetweenCalls == resourceReady.resourceLedger.retainedBetweenCalls,
    decodedResourcePreflight.operationPeak == materialized.resourceLedger.operationPeak,
    decodedResourcePreflight.transferredOutput == materialized.resourceLedger.transferredOutput,
    decodedResourcePreflight.outputLayoutAuthority == materialized.resourceLedger.outputLayoutAuthority
  else { throw EvidenceError.pixelConversionFailed }
  let decodedResourceFinalization = try decodedResourceCapability
    .finishWithDecodedImageResourceAuthority()
  let decodedResourceProviderData = decodedResourceFinalization.image.cgImage.dataProvider?.data as Data?
  let resourceTerminal = resourceAdapter.qualificationSnapshot
  guard decodedResourceFinalization.sourceByteCount == data.count,
    decodedResourceFinalization.materializationResourceLedger == decodedResourcePreflight,
    decodedResourceProviderData == packed.data,
    decodedResourceFinalization.image.colorDescription.sourceProfile == .absent,
    resourceTerminal.progress == .terminal,
    resourceTerminal.resourceLedger.isTerminal
  else { throw EvidenceError.pixelConversionFailed }

  let report = IndependentProgressive420PackedFinalizationReport(
    schemaVersion: 8,
    evidenceVersion: independentProgressive420PackedFinalizationEvidenceVersion,
    source: IndependentProgressive420PackedFinalizationSource(
      byteCount: data.count,
      sha256: sha256(data)
    ),
    inputProfile: "arbitraryChunk",
    chunkByteCount: chunkByteCount,
    chunkCount: chunkCount,
    capabilityDiscoverable: true,
    preFinishProgress: "finalReady",
    preFinishResourceLedger: ready.resourceLedger,
    maximumTightRGBABytes: ready.maximumTightRGBABytes,
    retainsOpaqueFrameworkStateBetweenCalls: ready.retainsOpaqueFrameworkStateBetweenCalls,
    packed: IndependentProgressive420PackedFinalizationPackedValue(
      pixelWidth: packed.pixelWidth,
      pixelHeight: packed.pixelHeight,
      bytesPerRow: packed.bytesPerRow,
      byteCount: packed.data.count,
      sha256: sha256(packed.data),
      sampleStorage: packed.format.sampleStorage.rawValue,
      channelLayout: packed.format.channelLayout.rawValue,
      alphaAssociation: packed.format.alphaAssociation.rawValue,
      colorEncoding: "sRGB",
      sourceColorProfile: packed.sourceColorProfile.rawValue,
      pixelByteCharge: packed.pixelByteCharge,
      transferredByteCharge: packed.transferredByteCharge
    ),
    finalizationSourceByteCount: finalization.sourceByteCount,
    packedMatchesKernelRGB: packed.data == reference.rgb,
    wrapperBackingWasShared: wrapperBackingWasShared,
    decoded: IndependentProgressive420PackedFinalizationDecodedValue(
      pixelWidth: cgImage.width,
      pixelHeight: cgImage.height,
      bytesPerRow: cgImage.bytesPerRow,
      bitsPerComponent: cgImage.bitsPerComponent,
      bitsPerPixel: cgImage.bitsPerPixel,
      alphaInfo: "none",
      colorSpaceModel: "rgb",
      sourceColorProfile: materialized.image.colorDescription.sourceProfile.rawValue,
      providerByteCount: providerData.count,
      providerSHA256: sha256(providerData),
      copiedPixelPayloadByteCount: materialized.copiedPixelPayloadByteCount,
      knownPixelPayloadOperationBytes: knownPixelPayloadOperationBytes.partialValue,
      providerBackingWasShared: materialized.providerBackingWasShared,
      resourceLedger: materialized.resourceLedger
    ),
    decodedResourceFinalizationCapabilityDiscoverable: true,
    publicResourceAwareDecodedFinalizationCapabilityAdvertised: true,
    publicDecodedFinalizationCapabilityAdvertised: false,
    decodedResourceFinalizationPreflightProgress: "finalReady",
    decodedResourceFinalizationPreflightWasNonConsuming: preflightAfter == preflightBefore,
    decodedResourceFinalizationPreflightLedger: decodedResourcePreflight,
    decodedResourceFinalizationSourceByteCount: decodedResourceFinalization.sourceByteCount,
    decodedResourceFinalizationProbe: IndependentProgressive420PackedFinalizationProbeValue(
      pixelWidth: decodedResourceFinalization.probe.pixelWidth,
      pixelHeight: decodedResourceFinalization.probe.pixelHeight,
      frameCount: decodedResourceFinalization.probe.frameCount,
      orientation: decodedResourceFinalization.probe.orientation,
      format: decodedResourceFinalization.probe.format.rawValue,
      metadataByteCount: decodedResourceFinalization.probe.metadataByteCount,
      auxiliaryAttachmentCount: decodedResourceFinalization.probe.auxiliaryAttachmentCount,
      sourceColorProfile: decodedResourceFinalization.probe.sourceColorProfile.rawValue
    ),
    decodedResourceFinalizationLedger: decodedResourceFinalization.materializationResourceLedger,
    decodedResourceFinalizationProviderSHA256: sha256(decodedResourceProviderData!),
    decodedResourceFinalizationTerminalLedger: resourceTerminal.resourceLedger,
    terminalProgress: "terminal",
    terminalResourceLedger: terminal.resourceLedger
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}
