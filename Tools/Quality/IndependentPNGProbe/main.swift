import Foundation
import ImageCraftCore
import ImageCraftImageIO

private enum ProbeError: Error { case invalidArguments }

private func classify(_ error: any Error) -> String {
  if let error = error as? PNGIndependentRGBA8Error { return "PNGIndependentRGBA8Error.\(String(describing: error))" }
  if let error = error as? ImageCraftError { return "ImageCraftError.\(String(describing: error))" }
  if let error = error as? ImagePackedPixelContractError { return "ImagePackedPixelContractError.\(String(describing: error))" }
  return String(reflecting: error)
}

guard (6...7).contains(CommandLine.arguments.count),
  let width = Int(CommandLine.arguments[2]),
  let height = Int(CommandLine.arguments[3]),
  let operationBudget = Int(CommandLine.arguments[4])
else { throw ProbeError.invalidArguments }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[5])
let colorPolicy: ImageColorPolicy
switch CommandLine.arguments.count == 7 ? CommandLine.arguments[6] : "preserveSource" {
case "preserveSource":
  colorPolicy = .preserveSource
case "convertToSRGB":
  colorPolicy = .convertToSRGB
default:
  throw ProbeError.invalidArguments
}
let data = try Data(contentsOf: input)
let limits = DecodeLimits(
  maximumEncodedBytes: max(1, data.count),
  maximumDimension: max(width, height),
  maximumPixelCount: max(1, width * height),
  maximumFrameCount: 1,
  maximumMetadataBytes: 1_024,
  maximumAuxiliaryAttachments: 0,
  allowedFormats: [.png]
)
let request = ImageDecodeRequest(
  target: try TargetPixels(width: width, height: height),
  contentMode: .fit,
  colorPolicy: colorPolicy
)
let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: operationBudget)

do {
  let ledger = try decoder.resourceLedger(data: data, request: request, limits: limits)
  let packed = try decoder.decode(data: data, request: request, limits: limits)
  let bytes = packed.data
  try bytes.write(to: output, options: .atomic)
  let operation = ledger.operationPeak.bytesUpperBound
  let transfer = ledger.transferredOutput.bytesUpperBound
  let packedColorEncoding: String
  let packedEmbeddedICCByteCount: Int
  let packedCICP: Any
  switch packed.colorEncoding {
  case .sRGB:
    packedColorEncoding = "sRGB"
    packedEmbeddedICCByteCount = 0
    packedCICP = NSNull()
  case .embeddedICC(let profile):
    packedColorEncoding = "embeddedICC"
    packedEmbeddedICCByteCount = profile.count
    packedCICP = NSNull()
  case .cicp(let cicp):
    packedColorEncoding = "cICP"
    packedEmbeddedICCByteCount = 0
    packedCICP = [
      "colorPrimaries": Int(cicp.colorPrimaries),
      "transferFunction": Int(cicp.transferFunction),
      "matrixCoefficients": Int(cicp.matrixCoefficients),
      "videoFullRangeFlag": Int(cicp.videoFullRangeFlag),
    ]
  }
  let report: [String: Any] = [
    "schemaVersion": 1,
    "status": "success",
    "width": width,
    "height": height,
    "byteCount": bytes.count,
    "operationByteChargeUpperBound": operation as Any,
    "transferredByteChargeUpperBound": transfer as Any,
    "packedTransferredByteCharge": packed.transferredByteCharge,
    "packedColorEncoding": packedColorEncoding,
    "packedEmbeddedICCByteCount": packedEmbeddedICCByteCount,
    "packedCICP": packedCICP,
    "packedSourceColorProfile": packed.sourceColorProfile.rawValue,
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
