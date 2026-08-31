import Foundation
import ImageCraftImageIO

private struct APNGOwnedPlaybackFrameEvidence: Codable {
  let index: Int
  let file: String
  let byteCount: Int
  let sha256: String
}

private struct APNGOwnedPlaybackDiagnosticsEvidence: Codable {
  let encodedFramePayloadBytes: Int
  let retainedCheckpointBytes: Int
  let retainedBytes: Int
  let retainedCheckpointCount: Int
  let maximumReplayFrames: Int
  let semanticReplayResetCount: Int
  let maximumResolvedReplayFrames: Int
  let canvasRGBABytes: Int
  let maximumRawSubrectRGBABytes: Int
  let maximumPreviousSaveRGBABytes: Int
  let materializedOutputRGBABytes: Int
  let decompressorWorkspaceBytes: Int
  let modeledPeakBytesUpperBound: Int
}

private struct APNGOwnedPlaybackEvidenceReport: Codable {
  let schemaVersion: Int
  let implementation: String
  let canvasWidth: Int
  let canvasHeight: Int
  let frameCount: Int
  let numPlays: UInt32
  let firstAnimationFrameUsesIDAT: Bool
  let frames: [APNGOwnedPlaybackFrameEvidence]
  let diagnostics: APNGOwnedPlaybackDiagnosticsEvidence
  let claimBoundary: [String]
}

func writeAPNGOwnedPlaybackEvidence(
  input: URL,
  outputDirectory: URL
) throws {
  let encodedData = try Data(contentsOf: input, options: [.mappedIfSafe])
  let result = try APNGOwnedPlaybackInterop.decodeAll(encodedData)
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: outputDirectory.path) {
    try fileManager.removeItem(at: outputDirectory)
  }
  try fileManager.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
  )
  var frames: [APNGOwnedPlaybackFrameEvidence] = []
  frames.reserveCapacity(result.frames.count)
  for (index, bytes) in result.frames.enumerated() {
    let name = String(format: "frame-%03d.rgba", index)
    let url = outputDirectory.appendingPathComponent(name)
    try bytes.write(to: url, options: .atomic)
    frames.append(
      APNGOwnedPlaybackFrameEvidence(
        index: index,
        file: name,
        byteCount: bytes.count,
        sha256: sha256(bytes)
      )
    )
  }
  let diagnostics = result.diagnostics
  let report = APNGOwnedPlaybackEvidenceReport(
    schemaVersion: 1,
    implementation: "imagecraft-owned-apng-straight-alpha-compressed-checkpoint-v1",
    canvasWidth: result.canvasWidth,
    canvasHeight: result.canvasHeight,
    frameCount: result.frames.count,
    numPlays: result.numPlays,
    firstAnimationFrameUsesIDAT: result.firstAnimationFrameUsesIDAT,
    frames: frames,
    diagnostics: APNGOwnedPlaybackDiagnosticsEvidence(
      encodedFramePayloadBytes: diagnostics.encodedFramePayloadBytes,
      retainedCheckpointBytes: diagnostics.retainedCheckpointBytes,
      retainedBytes: diagnostics.retainedBytes,
      retainedCheckpointCount: diagnostics.retainedCheckpointCount,
      maximumReplayFrames: diagnostics.maximumReplayFrames,
      semanticReplayResetCount: diagnostics.semanticReplayResetCount,
      maximumResolvedReplayFrames: diagnostics.maximumResolvedReplayFrames,
      canvasRGBABytes: diagnostics.canvasRGBABytes,
      maximumRawSubrectRGBABytes: diagnostics.maximumRawSubrectRGBABytes,
      maximumPreviousSaveRGBABytes: diagnostics.maximumPreviousSaveRGBABytes,
      materializedOutputRGBABytes: diagnostics.materializedOutputRGBABytes,
      decompressorWorkspaceBytes: diagnostics.decompressorWorkspaceBytes,
      modeledPeakBytesUpperBound: diagnostics.modeledPeakBytesUpperBound
    ),
    claimBoundary: [
      "package-only unpublished prototype",
      "RGBA8 non-interlaced APNG subset only",
      "correctness and modeled byte accounting only",
      "no latency, energy, thermal, or physical-device claim",
      "not connected to the public ImageIO animation decoder",
    ]
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let reportURL = outputDirectory.appendingPathComponent("report.json")
  try encoder.encode(report).write(to: reportURL, options: .atomic)
  print(reportURL.path)
}
