import Foundation
import ImageCraftCore
import ImageCraftImageIO

private enum ProbeError: Error { case invalidArguments }

private func classify(_ error: any Error) -> String {
  if let error = error as? PNGIndependentRGBA16Error {
    return "PNGIndependentRGBA16Error.\(String(describing: error))"
  }
  if let error = error as? ImageCraftError { return "ImageCraftError.\(String(describing: error))" }
  if let error = error as? ImagePackedPixelContractError {
    return "ImagePackedPixelContractError.\(String(describing: error))"
  }
  return String(reflecting: error)
}

guard (6...8).contains(CommandLine.arguments.count),
  let width = Int(CommandLine.arguments[2]),
  let height = Int(CommandLine.arguments[3]),
  let operationBudget = Int(CommandLine.arguments[4])
else { throw ProbeError.invalidArguments }
let colorPolicy: ImageColorPolicy
switch CommandLine.arguments.count >= 7 ? CommandLine.arguments[6] : "preserveSource" {
case "preserveSource": colorPolicy = .preserveSource
case "convertToSRGB": colorPolicy = .convertToSRGB
default: throw ProbeError.invalidArguments
}
let maximumMetadataBytes: Int
if CommandLine.arguments.count == 8 {
  guard let parsed = Int(CommandLine.arguments[7]), parsed > 0 else { throw ProbeError.invalidArguments }
  maximumMetadataBytes = parsed
} else {
  maximumMetadataBytes = 1_024
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[5])
let data = try Data(contentsOf: input)
let limits = DecodeLimits(
  maximumEncodedBytes: max(1, data.count),
  maximumDimension: max(width, height),
  maximumPixelCount: max(1, width * height),
  maximumFrameCount: 1,
  maximumMetadataBytes: maximumMetadataBytes,
  maximumAuxiliaryAttachments: 0,
  allowedFormats: [.png]
)
let request = ImageDecodeRequest(
  target: try TargetPixels(width: width, height: height),
  contentMode: .fit,
  colorPolicy: colorPolicy
)
let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: operationBudget)

do {
  let ledger = try decoder.resourceLedger(data: data, request: request, limits: limits)
  let packed = try decoder.decode(data: data, request: request, limits: limits)
  let bytes = packed.data
  try bytes.write(to: output, options: .atomic)
  let sourceSignificantBits: Any
  if let bits = packed.sourceSignificantBits {
    let sourceChannelModel: String
    switch bits.channels {
    case .grayscale:
      sourceChannelModel = "grayscale"
    case .rgb:
      sourceChannelModel = "rgb"
    case .grayscaleAlpha:
      sourceChannelModel = "grayscaleAlpha"
    case .rgba:
      sourceChannelModel = "rgba"
    }
    sourceSignificantBits = [
      "sampleBitDepth": Int(bits.sampleBitDepth),
      "sourceChannelModel": sourceChannelModel,
      "gray": bits.gray.map { Int($0) as Any } ?? NSNull(),
      "red": bits.red.map { Int($0) as Any } ?? NSNull(),
      "green": bits.green.map { Int($0) as Any } ?? NSNull(),
      "blue": bits.blue.map { Int($0) as Any } ?? NSNull(),
      "alpha": bits.alpha.map { Int($0) as Any } ?? NSNull(),
      "sourceHasStoredAlpha": bits.sourceHasStoredAlpha,
    ] as [String: Any]
  } else {
    sourceSignificantBits = NSNull()
  }
  let packedColorEncoding: String
  let embeddedICCBase64: Any
  let embeddedICCByteCount: Int
  let cicpReport: Any
  switch packed.colorEncoding {
  case .sRGB:
    packedColorEncoding = "sRGB"
    embeddedICCBase64 = NSNull()
    embeddedICCByteCount = 0
    cicpReport = NSNull()
  case .embeddedICC(let profile):
    packedColorEncoding = "embeddedICC"
    embeddedICCBase64 = profile.base64EncodedString()
    embeddedICCByteCount = profile.count
    cicpReport = NSNull()
  case .cicp(let cicp):
    packedColorEncoding = "cICP"
    embeddedICCBase64 = NSNull()
    embeddedICCByteCount = 0
    cicpReport = [
      "colorPrimaries": Int(cicp.colorPrimaries),
      "transferFunction": Int(cicp.transferFunction),
      "matrixCoefficients": Int(cicp.matrixCoefficients),
      "videoFullRangeFlag": Int(cicp.videoFullRangeFlag),
    ] as [String: Any]
  }
  let hdrStaticMetadata: Any
  if let metadata = packed.hdrStaticMetadata {
    let masteringDisplay: Any
    if let mastering = metadata.masteringDisplayColorVolume {
      masteringDisplay = [
        "redX": Int(mastering.redX),
        "redY": Int(mastering.redY),
        "greenX": Int(mastering.greenX),
        "greenY": Int(mastering.greenY),
        "blueX": Int(mastering.blueX),
        "blueY": Int(mastering.blueY),
        "whiteX": Int(mastering.whiteX),
        "whiteY": Int(mastering.whiteY),
        "maximumLuminanceScaledBy10000": Int(mastering.maximumLuminanceScaledBy10000),
        "minimumLuminanceScaledBy10000": Int(mastering.minimumLuminanceScaledBy10000),
      ] as [String: Any]
    } else {
      masteringDisplay = NSNull()
    }
    let contentLight: Any
    if let content = metadata.contentLightLevel {
      contentLight = [
        "maximumContentLightLevelScaledBy10000": Int(content.maximumContentLightLevelScaledBy10000),
        "maximumFrameAverageLightLevelScaledBy10000": Int(content.maximumFrameAverageLightLevelScaledBy10000),
      ] as [String: Any]
    } else {
      contentLight = NSNull()
    }
    hdrStaticMetadata = [
      "masteringDisplayColorVolume": masteringDisplay,
      "contentLightLevel": contentLight,
    ] as [String: Any]
  } else {
    hdrStaticMetadata = NSNull()
  }
  let report: [String: Any] = [
    "schemaVersion": 1,
    "status": "success",
    "width": width,
    "height": height,
    "maximumMetadataBytes": maximumMetadataBytes,
    "byteCount": bytes.count,
    "bytesPerRow": packed.bytesPerRow,
    "sampleStorage": packed.format.sampleStorage.rawValue,
    "channelLayout": packed.format.channelLayout.rawValue,
    "alphaAssociation": packed.format.alphaAssociation.rawValue,
    "multibyteByteOrder": packed.format.multibyteByteOrder?.rawValue as Any,
    "operationByteChargeUpperBound": ledger.operationPeak.bytesUpperBound as Any,
    "transferredByteChargeUpperBound": ledger.transferredOutput.bytesUpperBound as Any,
    "packedTransferredByteCharge": packed.transferredByteCharge,
    "packedColorEncoding": packedColorEncoding,
    "sourceColorProfile": packed.sourceColorProfile.rawValue,
    "embeddedICCBase64": embeddedICCBase64,
    "embeddedICCByteCount": embeddedICCByteCount,
    "cicp": cicpReport,
    "hdrStaticMetadata": hdrStaticMetadata,
    "sourceSignificantBits": sourceSignificantBits,
    "outputLayoutAuthority": ledger.outputLayoutAuthority.rawValue,
  ]
  let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
  FileHandle.standardOutput.write(encoded)
  FileHandle.standardOutput.write(Data([0x0A]))
} catch {
  let report: [String: Any] = [
    "schemaVersion": 1,
    "status": "error",
    "error": classify(error),
  ]
  let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
  FileHandle.standardOutput.write(encoded)
  FileHandle.standardOutput.write(Data([0x0A]))
  exit(2)
}
