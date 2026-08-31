import Foundation
import ImageCraftImageIO

func writeAPNGCheckpointInteropEncode(
  input: URL,
  width: Int,
  height: Int,
  output: URL
) throws {
  let source = try Data(contentsOf: input, options: [.mappedIfSafe])
  let blob = try APNGCompressedCheckpointInterop.encode(
    straightAlphaRGBA: source,
    width: width,
    height: height
  )
  try blob.write(to: output, options: .atomic)
  print(output.path)
}

func writeAPNGCheckpointInteropDecode(
  input: URL,
  output: URL
) throws {
  let blob = try Data(contentsOf: input, options: [.mappedIfSafe])
  let decoded = try APNGCompressedCheckpointInterop.decode(blob)
  try decoded.straightAlphaRGBA.write(to: output, options: .atomic)
  let metadata = [
    "width": decoded.width,
    "height": decoded.height,
    "byteCount": decoded.straightAlphaRGBA.count,
  ]
  let metadataData = try JSONSerialization.data(
    withJSONObject: metadata,
    options: [.sortedKeys]
  )
  FileHandle.standardError.write(metadataData)
  FileHandle.standardError.write(Data([0x0A]))
  print(output.path)
}
