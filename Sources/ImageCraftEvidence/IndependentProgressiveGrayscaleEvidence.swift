import Foundation
import ImageCraftImageIO

private struct IndependentProgressiveGrayscaleEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let width: Int
  let height: Int
  let outputByteCount: Int
  let outputSHA256: String
  let scanCount: Int
  let coefficientStateByteCount: Int
  let fixedStateByteCount: Int
  let operationByteCharge: Int
  let thresholdMinusOneRejectedBeforeStateAllocation: Bool
}

func writeIndependentProgressiveGrayscaleEvidence(input: URL, output: URL) throws {
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
  let stateBytes = coefficientBytes.partialValue.addingReportingOverflow(
    JPEGIndependentProgressiveGrayscaleDecoder.fixedStateByteCount
  )
  guard !stateBytes.overflow else { throw EvidenceError.invalidArguments }
  let exactCharge = outputBytes.partialValue.addingReportingOverflow(stateBytes.partialValue)
  guard !exactCharge.overflow, exactCharge.partialValue > 0 else {
    throw EvidenceError.invalidArguments
  }

  var thresholdMinusOneRejected = false
  do {
    _ = try JPEGIndependentProgressiveGrayscaleDecoder(
      maximumOperationByteCharge: exactCharge.partialValue - 1
    ).decode(data)
  } catch JPEGIndependentProgressiveGrayscaleError.operationBudgetExceeded(
    let requiredBytes,
    let maximumBytes
  ) where requiredBytes == exactCharge.partialValue
    && maximumBytes == exactCharge.partialValue - 1
  {
    thresholdMinusOneRejected = true
  }
  guard thresholdMinusOneRejected else { throw EvidenceError.invalidArguments }

  let decoded = try JPEGIndependentProgressiveGrayscaleDecoder(
    maximumOperationByteCharge: exactCharge.partialValue
  ).decode(data)
  guard decoded.width == frame.width,
    decoded.height == frame.height,
    decoded.pixels.count == outputBytes.partialValue,
    decoded.coefficientStateByteCount == coefficientBytes.partialValue,
    decoded.fixedStateByteCount == JPEGIndependentProgressiveGrayscaleDecoder.fixedStateByteCount,
    decoded.operationByteCharge == exactCharge.partialValue
  else { throw EvidenceError.invalidArguments }
  try decoded.pixels.write(to: output, options: .atomic)

  let report = IndependentProgressiveGrayscaleEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-progressive-grayscale-jpeg-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    width: frame.width,
    height: frame.height,
    outputByteCount: decoded.pixels.count,
    outputSHA256: sha256(decoded.pixels),
    scanCount: decoded.scanCount,
    coefficientStateByteCount: decoded.coefficientStateByteCount,
    fixedStateByteCount: decoded.fixedStateByteCount,
    operationByteCharge: decoded.operationByteCharge,
    thresholdMinusOneRejectedBeforeStateAllocation: thresholdMinusOneRejected
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
