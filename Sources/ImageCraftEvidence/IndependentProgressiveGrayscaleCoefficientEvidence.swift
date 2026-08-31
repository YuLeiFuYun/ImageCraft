import Foundation
import ImageCraftImageIO

private struct IndependentProgressiveGrayscaleCoefficientEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let width: Int
  let height: Int
  let scanCount: Int
  let coefficientByteCount: Int
  let coefficientSHA256: String
  let finalPixelByteCount: Int
  let finalPixelSHA256: String
  let decoderOperationByteCharge: Int
  let evidenceSerializationChunkBytes: Int
}

func writeIndependentProgressiveGrayscaleCoefficientEvidence(
  input: URL,
  output: URL
) throws {
  let data = try Data(contentsOf: input)
  let frame = try JPEGFrameSamplingGeometry.inspect(data)
  guard frame.codingMode == .progressiveDCT,
    frame.samplingMode == .singleComponent,
    frame.precision == 8
  else { throw EvidenceError.invalidArguments }

  let blocksAcross = frame.width / 8 + (frame.width % 8 == 0 ? 0 : 1)
  let blocksDown = frame.height / 8 + (frame.height % 8 == 0 ? 0 : 1)
  let blockCount = blocksAcross.multipliedReportingOverflow(by: blocksDown)
  guard !blockCount.overflow else { throw EvidenceError.invalidArguments }
  let coefficientBytes = blockCount.partialValue.multipliedReportingOverflow(by: 128)
  guard !coefficientBytes.overflow else { throw EvidenceError.invalidArguments }
  let outputBytes = frame.width.multipliedReportingOverflow(by: frame.height)
  guard !outputBytes.overflow else { throw EvidenceError.invalidArguments }
  let total = outputBytes.partialValue.addingReportingOverflow(coefficientBytes.partialValue)
  guard !total.overflow else { throw EvidenceError.invalidArguments }
  let operation = total.partialValue.addingReportingOverflow(
    JPEGIndependentProgressiveGrayscaleDecoder.fixedStateByteCount
  )
  guard !operation.overflow else { throw EvidenceError.invalidArguments }

  FileManager.default.createFile(atPath: output.path, contents: nil)
  let handle = try FileHandle(forWritingTo: output)
  defer { try? handle.close() }
  let serializationChunkBytes = 4096
  var observedCoefficientCount = 0
  let decoded = try JPEGIndependentProgressiveGrayscaleDecoder(
    maximumOperationByteCharge: operation.partialValue
  ).decode(data) { coefficients in
    observedCoefficientCount = coefficients.count
    var chunk = Data()
    chunk.reserveCapacity(serializationChunkBytes)
    for coefficient in coefficients {
      let raw = UInt16(bitPattern: coefficient)
      chunk.append(UInt8(raw & 0xFF))
      chunk.append(UInt8((raw >> 8) & 0xFF))
      if chunk.count >= serializationChunkBytes {
        try handle.write(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty {
      try handle.write(contentsOf: chunk)
    }
  }
  try handle.synchronize()

  let expectedCoefficientCount = coefficientBytes.partialValue / 2
  guard observedCoefficientCount == expectedCoefficientCount else {
    throw EvidenceError.invalidArguments
  }
  let coefficientData = try Data(contentsOf: output)
  guard coefficientData.count == coefficientBytes.partialValue else {
    throw EvidenceError.invalidArguments
  }
  let report = IndependentProgressiveGrayscaleCoefficientEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-progressive-grayscale-coefficients-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    width: frame.width,
    height: frame.height,
    scanCount: decoded.scanCount,
    coefficientByteCount: coefficientData.count,
    coefficientSHA256: sha256(coefficientData),
    finalPixelByteCount: decoded.pixels.count,
    finalPixelSHA256: sha256(decoded.pixels),
    decoderOperationByteCharge: decoded.operationByteCharge,
    evidenceSerializationChunkBytes: serializationChunkBytes
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
