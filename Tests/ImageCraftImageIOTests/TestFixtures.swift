import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func makePNG(width: Int = 100, height: Int = 50, red: UInt8 = 255) throws -> Data {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = red
        pixels[index + 1] = 32
        pixels[index + 2] = 64
        pixels[index + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else {
        throw ImageCraftFixtureError.creationFailed
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw ImageCraftFixtureError.creationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ImageCraftFixtureError.creationFailed
    }
    return data as Data
}

enum ImageCraftFixtureError: Error {
    case creationFailed
}
