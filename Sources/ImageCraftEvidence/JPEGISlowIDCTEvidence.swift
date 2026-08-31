import Foundation
import ImageCraftImageIO

private struct JPEGISlowIDCTEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let coefficientCount: Int
  let quantizationCount: Int
  let workspaceByteCount: Int
  let outputByteCount: Int
  let outputSHA256: String
}

func writeJPEGISlowIDCTEvidence(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  guard data.count == 256 else { throw EvidenceError.invalidArguments }

  var coefficients = [Int16]()
  coefficients.reserveCapacity(64)
  var quantization = [UInt16]()
  quantization.reserveCapacity(64)
  for index in 0..<64 {
    let offset = index * 2
    let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    coefficients.append(Int16(bitPattern: raw))
  }
  for index in 0..<64 {
    let offset = 128 + index * 2
    let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    quantization.append(raw)
  }

  var workspace = [Int32](repeating: 0, count: 64)
  var outputBytes = [UInt8](repeating: 0, count: 64)
  try coefficients.withUnsafeBufferPointer { coefficientBuffer in
    try quantization.withUnsafeBufferPointer { quantizationBuffer in
      try workspace.withUnsafeMutableBufferPointer { workspaceBuffer in
        try outputBytes.withUnsafeMutableBufferPointer { outputBuffer in
          try JPEGISlowIDCT.writeBlock(
            coefficients: coefficientBuffer,
            quantization: quantizationBuffer,
            workspace: workspaceBuffer,
            destination: outputBuffer
          )
        }
      }
    }
  }
  let outputData = Data(outputBytes)
  try outputData.write(to: output, options: .atomic)
  let report = JPEGISlowIDCTEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-jpeg-islow-idct-block-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    coefficientCount: coefficients.count,
    quantizationCount: quantization.count,
    workspaceByteCount: workspace.count * MemoryLayout<Int32>.stride,
    outputByteCount: outputData.count,
    outputSHA256: sha256(outputData)
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
