import Foundation
import ImageCraftImageIO

private struct ProgressiveJPEGResourceGeometryEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let input: ProgressiveJPEGResourceGeometryEvidenceInput
  let geometry: JPEGProgressiveResourceGeometry
}

private struct ProgressiveJPEGResourceGeometryEvidenceInput: Codable {
  let byteCount: Int
  let sha256: String
}

func writeProgressiveJPEGResourceGeometryEvidence(input: URL) throws {
  let data = try Data(contentsOf: input)
  let geometry = try JPEGProgressiveResourceGeometry.inspect(data)
  let report = ProgressiveJPEGResourceGeometryEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-progressive-jpeg-resource-geometry-v1",
    input: ProgressiveJPEGResourceGeometryEvidenceInput(
      byteCount: data.count,
      sha256: sha256(data)
    ),
    geometry: geometry
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
