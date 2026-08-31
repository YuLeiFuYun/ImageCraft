import CoreGraphics
import Foundation
import ImageIO

struct ProbeReport: Codable {
  let schemaVersion: UInt16
  let mode: String
  let allowFloat: Bool
  let width: Int
  let height: Int
  let bitsPerComponent: Int
  let bitsPerPixel: Int
  let bytesPerRow: Int
}

enum ProbeError: Error {
  case invalidArguments
  case sourceCreationFailed
  case propertiesUnavailable
  case imageCreationFailed
  case renderFailed
}

func renderRGBA8(_ image: CGImage) throws -> Data {
  let width = image.width
  let height = image.height
  let bytesPerRow = width * 4
  var bytes = Data(count: bytesPerRow * height)
  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
    guard let context = CGContext(
      data: raw.baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard rendered else { throw ProbeError.renderFailed }
  return bytes
}

let arguments = CommandLine.arguments
if arguments.count != 5 {
  throw ProbeError.invalidArguments
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let mode = arguments[3]
let allowFloat: Bool
switch arguments[4] {
case "true": allowFloat = true
case "false": allowFloat = false
default: throw ProbeError.invalidArguments
}
let data = try Data(contentsOf: input)
let sourceOptions = [
  kCGImageSourceShouldCache: false,
  kCGImageSourceShouldAllowFloat: allowFloat,
] as CFDictionary
guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
  throw ProbeError.sourceCreationFailed
}
let image: CGImage
switch mode {
case "direct":
  let options = [
    kCGImageSourceShouldCache: true,
    kCGImageSourceShouldAllowFloat: allowFloat,
  ] as CFDictionary
  guard let created = CGImageSourceCreateImageAtIndex(source, 0, options) else {
    throw ProbeError.imageCreationFailed
  }
  image = created
case "thumbnail":
  guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
    as? [CFString: Any],
    let width = properties[kCGImagePropertyPixelWidth] as? Int,
    let height = properties[kCGImagePropertyPixelHeight] as? Int
  else { throw ProbeError.propertiesUnavailable }
  let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: false,
    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceShouldAllowFloat: allowFloat,
  ]
  guard let created = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
    throw ProbeError.imageCreationFailed
  }
  image = created
default:
  throw ProbeError.invalidArguments
}
let rgba = try renderRGBA8(image)
try rgba.write(to: output, options: .atomic)
let report = ProbeReport(
  schemaVersion: 1,
  mode: mode,
  allowFloat: allowFloat,
  width: image.width,
  height: image.height,
  bitsPerComponent: image.bitsPerComponent,
  bitsPerPixel: image.bitsPerPixel,
  bytesPerRow: image.bytesPerRow
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let payload = try encoder.encode(report)
print(String(decoding: payload, as: UTF8.self))
