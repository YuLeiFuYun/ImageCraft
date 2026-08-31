import Foundation
import ImageCraftImageIO

private struct IndependentBaselineGrayscaleEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let input: IndependentBaselineGrayscaleEvidenceInput
  let output: IndependentBaselineGrayscaleEvidenceOutput
  let decoder: IndependentBaselineGrayscaleEvidenceDecoder
  let thresholdMinusOneRejectedBeforeDecodeAllocation: Bool
}

private struct IndependentBaselineGrayscaleEvidenceInput: Codable {
  let byteCount: Int
  let sha256: String
  let width: Int
  let height: Int
}

private struct IndependentBaselineGrayscaleEvidenceOutput: Codable {
  let byteCount: Int
  let sha256: String
}

private struct IndependentBaselineGrayscaleEvidenceDecoder: Codable {
  let fixedScratchByteCount: Int
  let operationByteCharge: Int
  let decodedMCUCount: Int
  let restartIntervalMCUs: Int
}

func writeIndependentBaselineGrayscaleEvidence(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  let frame = try JPEGFrameSamplingGeometry.inspect(data)
  guard frame.codingMode == .baselineDCT,
    frame.samplingMode == .singleComponent,
    frame.precision == 8
  else { throw EvidenceError.invalidArguments }
  let outputBytes = frame.width * frame.height
  let exactCharge = outputBytes + JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount

  var thresholdMinusOneRejected = false
  if exactCharge > 0 {
    do {
      _ = try JPEGIndependentBaselineGrayscaleDecoder(
        maximumOperationByteCharge: exactCharge - 1
      ).decode(data)
    } catch JPEGIndependentBaselineGrayscaleError.operationBudgetExceeded(
      let requiredBytes,
      let maximumBytes
    ) where requiredBytes == exactCharge && maximumBytes == exactCharge - 1 {
      thresholdMinusOneRejected = true
    }
  }
  guard thresholdMinusOneRejected else { throw EvidenceError.invalidArguments }

  let decoded = try JPEGIndependentBaselineGrayscaleDecoder(
    maximumOperationByteCharge: exactCharge
  ).decode(data)
  guard decoded.width == frame.width,
    decoded.height == frame.height,
    decoded.pixels.count == outputBytes,
    decoded.operationByteCharge == exactCharge,
    decoded.fixedScratchByteCount == JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount
  else { throw EvidenceError.invalidArguments }
  try decoded.pixels.write(to: output, options: .atomic)

  let report = IndependentBaselineGrayscaleEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-baseline-grayscale-jpeg-v1",
    input: IndependentBaselineGrayscaleEvidenceInput(
      byteCount: data.count,
      sha256: sha256(data),
      width: frame.width,
      height: frame.height
    ),
    output: IndependentBaselineGrayscaleEvidenceOutput(
      byteCount: decoded.pixels.count,
      sha256: sha256(decoded.pixels)
    ),
    decoder: IndependentBaselineGrayscaleEvidenceDecoder(
      fixedScratchByteCount: decoded.fixedScratchByteCount,
      operationByteCharge: decoded.operationByteCharge,
      decodedMCUCount: decoded.decodedMCUCount,
      restartIntervalMCUs: decoded.restartIntervalMCUs
    ),
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
