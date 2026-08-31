import Foundation
import ImageCraftImageIO

private struct JPEGYCbCrToRGBEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let pixelCount: Int
  let outputByteCount: Int
  let outputSHA256: String
}

func writeJPEGYCbCrToRGBEvidence(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  guard data.count % 3 == 0 else { throw EvidenceError.invalidArguments }
  var result = Data(count: data.count)
  try data.withUnsafeBytes { rawInput in
    let source = rawInput.bindMemory(to: UInt8.self)
    try result.withUnsafeMutableBytes { rawOutput in
      let destination = rawOutput.bindMemory(to: UInt8.self)
      try JPEGYCbCrToRGB.writeInterleavedRGB(
        yCbCr: source,
        destination: destination
      )
    }
  }
  try result.write(to: output, options: .atomic)
  let report = JPEGYCbCrToRGBEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-jpeg-ycbcr-to-rgb-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    pixelCount: data.count / 3,
    outputByteCount: result.count,
    outputSHA256: sha256(result)
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
