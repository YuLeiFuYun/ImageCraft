import Foundation
import ImageCraftImageIO

private struct IndependentProgressive420ScanGeneration: Codable {
  let scanNumber: Int
  let byteCount: Int
  let sha256: String
  let fileName: String
}

private struct IndependentProgressive420ScanEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let inputByteCount: Int
  let inputSHA256: String
  let width: Int
  let height: Int
  let scanCount: Int
  let operationByteCharge: Int
  let outputBackingReusedAcrossScans: Bool
  let finalOutputSHA256: String
  let generations: [IndependentProgressive420ScanGeneration]
}

func writeIndependentProgressive420ScanEvidence(
  input: URL,
  outputDirectory: URL
) throws {
  let data = try Data(contentsOf: input)
  let statePlan = try JPEGIndependentProgressive420StatePlan.inspect(data)
  let pixelCount = statePlan.width.multipliedReportingOverflow(by: statePlan.height)
  guard !pixelCount.overflow else { throw EvidenceError.invalidArguments }
  let outputByteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
  guard !outputByteCount.overflow else { throw EvidenceError.invalidArguments }
  let operationByteCharge = outputByteCount.partialValue.addingReportingOverflow(
    statePlan.totalStateBytes
  )
  guard !operationByteCharge.overflow, operationByteCharge.partialValue > 0 else {
    throw EvidenceError.invalidArguments
  }

  try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
  )
  var generations: [IndependentProgressive420ScanGeneration] = []
  var outputBackingAddress: UInt?
  var outputBackingReusedAcrossScans = true
  let decoded = try JPEGIndependentProgressive420Decoder(
    maximumOperationByteCharge: operationByteCharge.partialValue
  ).decode(
    data,
    scanPreviewObserver: { scanNumber, pixels in
      guard let baseAddress = pixels.baseAddress,
        pixels.count == outputByteCount.partialValue
      else { throw EvidenceError.invalidArguments }
      let address = UInt(bitPattern: baseAddress)
      if let outputBackingAddress {
        outputBackingReusedAcrossScans = outputBackingReusedAcrossScans
          && outputBackingAddress == address
      } else {
        outputBackingAddress = address
      }
      let generation = Data(bytes: baseAddress, count: pixels.count)
      let fileName = String(format: "scan-%03d.rgb", scanNumber)
      try generation.write(
        to: outputDirectory.appendingPathComponent(fileName),
        options: .atomic
      )
      generations.append(
        IndependentProgressive420ScanGeneration(
          scanNumber: scanNumber,
          byteCount: generation.count,
          sha256: sha256(generation),
          fileName: fileName
        )
      )
    },
    finalCoefficientObserver: nil
  )
  guard outputBackingReusedAcrossScans,
    generations.map(\.scanNumber) == Array(1...decoded.scanCount),
    generations.count == decoded.scanCount,
    generations.last?.sha256 == sha256(decoded.rgb)
  else { throw EvidenceError.invalidArguments }

  let report = IndependentProgressive420ScanEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-independent-progressive-jpeg-420-scans-v1",
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    width: decoded.width,
    height: decoded.height,
    scanCount: decoded.scanCount,
    operationByteCharge: decoded.operationByteCharge,
    outputBackingReusedAcrossScans: outputBackingReusedAcrossScans,
    finalOutputSHA256: sha256(decoded.rgb),
    generations: generations
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
