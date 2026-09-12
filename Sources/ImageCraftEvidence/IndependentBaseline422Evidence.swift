import Foundation
import ImageCraftImageIO

private struct IndependentBaseline422EvidenceReport: Codable {
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
  let stateByteCount: Int
  let operationByteCharge: Int
  let thresholdMinusOneRejectedBeforeDecodeAllocation: Bool
}

func writeIndependentBaseline422Evidence(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  let statePlan = try JPEGIndependentBaseline422StatePlan.inspect(data)
  let pixels = statePlan.width.multipliedReportingOverflow(by: statePlan.height)
  guard !pixels.overflow else { throw EvidenceError.invalidArguments }
  let outputBytes = pixels.partialValue.multipliedReportingOverflow(by: 3)
  guard !outputBytes.overflow else { throw EvidenceError.invalidArguments }
  let exactCharge = outputBytes.partialValue.addingReportingOverflow(statePlan.totalStateBytes)
  guard !exactCharge.overflow, exactCharge.partialValue > 0 else {
    throw EvidenceError.invalidArguments
  }

  var thresholdMinusOneRejected = false
  do {
    _ = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactCharge.partialValue - 1
    ).decode(data)
  } catch JPEGIndependentBaseline422Error.operationBudgetExceeded(
    let requiredBytes,
    let maximumBytes
  ) where requiredBytes == exactCharge.partialValue
    && maximumBytes == exactCharge.partialValue - 1
  {
    thresholdMinusOneRejected = true
  }
  guard thresholdMinusOneRejected else { throw EvidenceError.invalidArguments }

  let decoded = try JPEGIndependentBaseline422Decoder(
    maximumOperationByteCharge: exactCharge.partialValue
  ).decode(data)
  guard decoded.width == statePlan.width,
    decoded.height == statePlan.height,
    decoded.rgb.count == outputBytes.partialValue,
    decoded.statePlan == statePlan,
    decoded.operationByteCharge == exactCharge.partialValue
  else { throw EvidenceError.invalidArguments }
  try decoded.rgb.write(to: output, options: .atomic)

  let report = IndependentBaseline422EvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-baseline-jpeg-422-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    width: statePlan.width,
    height: statePlan.height,
    outputByteCount: decoded.rgb.count,
    outputSHA256: sha256(decoded.rgb),
    restartIntervalMCUs: decoded.restartIntervalMCUs,
    decodedMCUCount: decoded.decodedMCUCount,
    stateByteCount: statePlan.totalStateBytes,
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
