import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let packedRGBAExportEvidenceVersion = "imagecraft-packed-rgba-export-v1"
private let packedRGBAContractID = "rgba8-premultiplied-top-to-bottom-tight-v1"

private struct PackedRGBAInputEvidence: Codable {
  let byteCount: Int
  let sha256: String
  let format: String
  let pixelWidth: Int
  let pixelHeight: Int
  let orientation: UInt32
  let sourceColorProfile: String
}

private struct PackedRGBAContractEvidence: Codable {
  let id: String
  let channelOrder: String
  let bitsPerChannel: Int
  let alphaMode: String
  let rowOrder: String
  let colorEncoding: String
  let bytesPerRow: Int
  let transferredByteCharge: Int
}

private struct PackedRGBAOutputEvidence: Codable {
  let pixelWidth: Int
  let pixelHeight: Int
  let byteCount: Int
  let sha256: String
  let allAlphaOpaque: Bool
}

private struct PackedRGBAExportEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let decoderFingerprint: String
  let input: PackedRGBAInputEvidence
  let contract: PackedRGBAContractEvidence
  let output: PackedRGBAOutputEvidence
}

func writePackedRGBAExportEvidence(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  let decoder = ImageIOImageDecoder()
  let probe = try decoder.probe(data: data, limits: .coreV1)
  let request = ImageDecodeRequest(
    target: try TargetPixels(width: probe.pixelWidth, height: probe.pixelHeight),
    contentMode: .fit,
    colorPolicy: .convertToSRGB
  )
  let packed = try decoder.decodePackedRGBA8(
    data: data,
    request: request,
    limits: .coreV1
  )
  guard packed.colorEncoding == .sRGB,
    packed.bytesPerRow == packed.pixelWidth * 4,
    packed.data.count == packed.bytesPerRow * packed.pixelHeight
  else {
    throw EvidenceError.pixelConversionFailed
  }

  let directory = output.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try packed.data.write(to: output, options: .atomic)

  var allAlphaOpaque = true
  packed.data.withUnsafeBytes { rawBuffer in
    let bytes = rawBuffer.bindMemory(to: UInt8.self)
    for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] != 255 {
      allAlphaOpaque = false
      break
    }
  }

  let report = PackedRGBAExportEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: packedRGBAExportEvidenceVersion,
    runtime: .capture(),
    decoderFingerprint: decoder.codecDescriptor.cacheFingerprint,
    input: PackedRGBAInputEvidence(
      byteCount: data.count,
      sha256: sha256(data),
      format: probe.format.rawValue,
      pixelWidth: probe.pixelWidth,
      pixelHeight: probe.pixelHeight,
      orientation: probe.orientation,
      sourceColorProfile: String(describing: probe.sourceColorProfile)
    ),
    contract: PackedRGBAContractEvidence(
      id: packedRGBAContractID,
      channelOrder: "RGBA",
      bitsPerChannel: 8,
      alphaMode: "premultiplied",
      rowOrder: "top-to-bottom",
      colorEncoding: "sRGB",
      bytesPerRow: packed.bytesPerRow,
      transferredByteCharge: packed.transferredByteCharge
    ),
    output: PackedRGBAOutputEvidence(
      pixelWidth: packed.pixelWidth,
      pixelHeight: packed.pixelHeight,
      byteCount: packed.data.count,
      sha256: sha256(packed.data),
      allAlphaOpaque: allAlphaOpaque
    )
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}
