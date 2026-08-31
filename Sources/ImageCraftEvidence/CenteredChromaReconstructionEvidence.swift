import Foundation
import ImageCraftImageIO

private struct CenteredChromaReconstructionEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let mode: String
  let sourceWidth: Int
  let sourceHeight: Int
  let outputWidth: Int
  let outputHeight: Int
  let inputByteCount: Int
  let inputSHA256: String
  let outputByteCount: Int
  let outputSHA256: String
}

func writeCenteredChromaReconstructionEvidence(
  input: URL,
  output: URL,
  mode: String,
  sourceWidth: Int,
  sourceHeight: Int,
  outputWidth: Int,
  outputHeight: Int
) throws {
  let sourceData = try Data(contentsOf: input)
  guard sourceWidth > 0, sourceHeight > 0, outputWidth > 0, outputHeight > 0 else {
    throw EvidenceError.invalidArguments
  }
  var outputData = Data(count: outputWidth * outputHeight)
  try sourceData.withUnsafeBytes { rawSource in
    let source = rawSource.bindMemory(to: UInt8.self)
    try outputData.withUnsafeMutableBytes { rawOutput in
      let destination = rawOutput.bindMemory(to: UInt8.self)
      switch mode {
      case "h1v2":
        guard outputWidth == sourceWidth else { throw EvidenceError.invalidArguments }
        try JPEGCenteredChromaReconstruction.writeH1V2(
          source: source,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          destination: destination,
          outputHeight: outputHeight
        )
      case "h2v2":
        try JPEGCenteredChromaReconstruction.writeH2V2(
          source: source,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          destination: destination,
          outputWidth: outputWidth,
          outputHeight: outputHeight
        )
      default:
        throw EvidenceError.invalidArguments
      }
    }
  }
  try outputData.write(to: output, options: .atomic)
  let report = CenteredChromaReconstructionEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-centered-chroma-reconstruction-v1",
    mode: mode,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    outputWidth: outputWidth,
    outputHeight: outputHeight,
    inputByteCount: sourceData.count,
    inputSHA256: sha256(sourceData),
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
