import Foundation
import ImageCraftImageIO

private struct IndependentBaseline444EvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let width: Int
  let height: Int
  let outputByteCount: Int
  let outputSHA256: String
  let restartIntervalMCUs: Int
  let decodedMCUCount: Int
  let fixedScratchByteCount: Int
  let operationByteCharge: Int
  let thresholdMinusOneRejectedBeforeDecodeAllocation: Bool
}

func writeIndependentBaseline444Evidence(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  let frame = try JPEGFrameSamplingGeometry.inspect(data)
  guard frame.codingMode == .baselineDCT,
    frame.samplingMode == .threeComponent444,
    frame.precision == 8
  else { throw EvidenceError.invalidArguments }
  let pixels = frame.width.multipliedReportingOverflow(by: frame.height)
  guard !pixels.overflow else { throw EvidenceError.invalidArguments }
  let outputBytes = pixels.partialValue.multipliedReportingOverflow(by: 3)
  guard !outputBytes.overflow else { throw EvidenceError.invalidArguments }
  let exactCharge = outputBytes.partialValue.addingReportingOverflow(
    JPEGIndependentBaseline444Decoder.fixedScratchByteCount
  )
  guard !exactCharge.overflow, exactCharge.partialValue > 0 else {
    throw EvidenceError.invalidArguments
  }

  var thresholdMinusOneRejected = false
  do {
    _ = try JPEGIndependentBaseline444Decoder(
      maximumOperationByteCharge: exactCharge.partialValue - 1
    ).decode(data)
  } catch JPEGIndependentBaseline444Error.operationBudgetExceeded(
    let requiredBytes,
    let maximumBytes
  ) where requiredBytes == exactCharge.partialValue
    && maximumBytes == exactCharge.partialValue - 1
  {
    thresholdMinusOneRejected = true
  }
  guard thresholdMinusOneRejected else { throw EvidenceError.invalidArguments }

  let decoded = try JPEGIndependentBaseline444Decoder(
    maximumOperationByteCharge: exactCharge.partialValue
  ).decode(data)
  guard decoded.width == frame.width,
    decoded.height == frame.height,
    decoded.rgb.count == outputBytes.partialValue,
    decoded.fixedScratchByteCount == JPEGIndependentBaseline444Decoder.fixedScratchByteCount,
    decoded.operationByteCharge == exactCharge.partialValue
  else { throw EvidenceError.invalidArguments }
  try decoded.rgb.write(to: output, options: .atomic)

  let report = IndependentBaseline444EvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-baseline-jpeg-444-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    width: frame.width,
    height: frame.height,
    outputByteCount: decoded.rgb.count,
    outputSHA256: sha256(decoded.rgb),
    restartIntervalMCUs: decoded.restartIntervalMCUs,
    decodedMCUCount: decoded.decodedMCUCount,
    fixedScratchByteCount: decoded.fixedScratchByteCount,
    operationByteCharge: decoded.operationByteCharge,
    thresholdMinusOneRejectedBeforeDecodeAllocation: thresholdMinusOneRejected
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
