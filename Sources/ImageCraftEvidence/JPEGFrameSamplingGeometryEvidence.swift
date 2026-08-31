import Foundation
import ImageCraftImageIO

private struct JPEGFrameSamplingGeometryEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let input: JPEGFrameSamplingGeometryEvidenceInput
  let geometry: JPEGFrameSamplingGeometry
}

private struct JPEGFrameSamplingGeometryEvidenceInput: Codable {
  let byteCount: Int
  let sha256: String
}

func writeJPEGFrameSamplingGeometryEvidence(input: URL) throws {
  let data = try Data(contentsOf: input)
  let geometry = try JPEGFrameSamplingGeometry.inspect(data)
  let report = JPEGFrameSamplingGeometryEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-jpeg-frame-sampling-geometry-v1",
    input: JPEGFrameSamplingGeometryEvidenceInput(
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
