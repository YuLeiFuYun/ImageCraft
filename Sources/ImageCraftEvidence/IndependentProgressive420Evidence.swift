import Foundation
import ImageCraftImageIO

private enum IndependentProgressive420EvidenceError: Error {
  case invariantViolation(String)
}

private struct IndependentProgressive420EvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let width: Int
  let height: Int
  let scanCount: Int
  let outputByteCount: Int
  let outputSHA256: String
  let coefficientByteCount: Int
  let coefficientSHA256: String
  let statePlan: JPEGIndependentProgressive420StatePlan
  let operationByteCharge: Int
  let thresholdMinusOneRejectedBeforeStateAllocation: Bool
}

func writeIndependentProgressive420Evidence(
  input: URL,
  output: URL,
  coefficientsOutput: URL
) throws {
  let data = try Data(contentsOf: input)
  let statePlan = try JPEGIndependentProgressive420StatePlan.inspect(data)
  let pixels = statePlan.width.multipliedReportingOverflow(by: statePlan.height)
  guard !pixels.overflow else {
    throw IndependentProgressive420EvidenceError.invariantViolation("pixel count overflow")
  }
  let outputBytes = pixels.partialValue.multipliedReportingOverflow(by: 3)
  guard !outputBytes.overflow else {
    throw IndependentProgressive420EvidenceError.invariantViolation("RGB byte count overflow")
  }
  let exactCharge = outputBytes.partialValue.addingReportingOverflow(statePlan.totalStateBytes)
  guard !exactCharge.overflow, exactCharge.partialValue > 0 else {
    throw IndependentProgressive420EvidenceError.invariantViolation("operation charge overflow")
  }

  var thresholdMinusOneRejected = false
  do {
    _ = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: exactCharge.partialValue - 1
    ).decode(data)
  } catch JPEGIndependentProgressive420Error.operationBudgetExceeded(
    let requiredBytes,
    let maximumBytes
  ) where requiredBytes == exactCharge.partialValue
    && maximumBytes == exactCharge.partialValue - 1
  {
    thresholdMinusOneRejected = true
  }
  guard thresholdMinusOneRejected else {
    throw IndependentProgressive420EvidenceError.invariantViolation(
      "threshold-minus-one was not rejected by operation admission"
    )
  }

  var coefficientData = Data()
  let decoded = try JPEGIndependentProgressive420Decoder(
    maximumOperationByteCharge: exactCharge.partialValue
  ).decode(data) { coefficients in
    coefficientData = Data(
      bytes: coefficients.baseAddress!,
      count: coefficients.count * MemoryLayout<Int16>.stride
    )
  }
  guard decoded.width == statePlan.width,
    decoded.height == statePlan.height,
    decoded.rgb.count == outputBytes.partialValue,
    decoded.statePlan == statePlan,
    decoded.operationByteCharge == exactCharge.partialValue,
    coefficientData.count == statePlan.coefficientStateBytes
  else {
    throw IndependentProgressive420EvidenceError.invariantViolation(
      "decoded output/state report disagrees with precomputed state plan"
    )
  }
  try decoded.rgb.write(to: output, options: .atomic)
  try coefficientData.write(to: coefficientsOutput, options: .atomic)

  let report = IndependentProgressive420EvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-progressive-jpeg-420-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    width: decoded.width,
    height: decoded.height,
    scanCount: decoded.scanCount,
    outputByteCount: decoded.rgb.count,
    outputSHA256: sha256(decoded.rgb),
    coefficientByteCount: coefficientData.count,
    coefficientSHA256: sha256(coefficientData),
    statePlan: decoded.statePlan,
    operationByteCharge: decoded.operationByteCharge,
    thresholdMinusOneRejectedBeforeStateAllocation: thresholdMinusOneRejected
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw IndependentProgressive420EvidenceError.invariantViolation(
      "JSON report was not valid UTF-8"
    )
  }
  print(json)
}
