import Foundation
import ImageCraftCore

package enum JPEGFrameCodingMode: String, Codable, Hashable, Sendable {
  case baselineDCT
  case progressiveDCT
}

package enum JPEGFrameSamplingMode: String, Codable, Hashable, Sendable {
  case singleComponent
  case threeComponent444
  case threeComponent422
  case threeComponent440
  case threeComponent420
}

package struct JPEGFrameComponentSampling: Codable, Equatable, Sendable {
  package let componentID: UInt8
  package let horizontalSamplingFactor: Int
  package let verticalSamplingFactor: Int
}

/// Immutable SOF-derived JPEG sampling facts shared by resource and quality mechanisms.
///
/// This type intentionally stops at frame geometry.  It does not infer a color model from component
/// IDs or sampling factors, does not inspect scan coding, and does not claim any decoder allocation.
/// `verticalChromaSubsamplingPresent` is therefore structural shorthand for the qualified three-
/// component 4:4:0/4:2:0 patterns, not a YCbCr semantic assertion.
package struct JPEGFrameSamplingGeometry: Codable, Equatable, Sendable {
  package let codingMode: JPEGFrameCodingMode
  package let width: Int
  package let height: Int
  package let precision: Int
  package let samplingMode: JPEGFrameSamplingMode
  package let components: [JPEGFrameComponentSampling]
  package let maximumHorizontalSamplingFactor: Int
  package let maximumVerticalSamplingFactor: Int
  package let outputIMCURowHeight: Int
  package let totalIMCURowCount: Int
  package let internalIMCUBoundaryCount: Int
  package let verticalChromaSubsamplingPresent: Bool
  package let verticalChromaBoundaryAdjacentOutputRowCount: Int

  package static func inspect(_ data: Data) throws -> Self {
    try data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
        throw ImageCraftError.formatMismatch
      }

      var offset = 2
      while offset < bytes.count {
        guard bytes[offset] == 0xFF else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
        guard offset < bytes.count else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let marker = bytes[offset]
        offset += 1
        guard marker != 0x00, marker != 0xD8 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        if marker == 0xD9 || marker == 0xDA {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }

        guard offset + 2 <= bytes.count else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let segmentLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        guard segmentLength >= 2 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let end = offset.addingReportingOverflow(segmentLength)
        guard !end.overflow, end.partialValue <= bytes.count else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }

        if isStartOfFrame(marker) {
          let codingMode: JPEGFrameCodingMode
          switch marker {
          case 0xC0: codingMode = .baselineDCT
          case 0xC2: codingMode = .progressiveDCT
          default: throw ImageCraftError.unsupportedOrCorruptImage
          }
          return try parseSOF(
            bytes,
            lengthOffset: offset,
            segmentEnd: end.partialValue,
            codingMode: codingMode
          )
        }
        offset = end.partialValue
      }
      throw ImageCraftError.unsupportedOrCorruptImage
    }
  }

  private static func isStartOfFrame(_ marker: UInt8) -> Bool {
    switch marker {
    case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
      true
    default:
      false
    }
  }

  private static func parseSOF(
    _ bytes: UnsafeBufferPointer<UInt8>,
    lengthOffset: Int,
    segmentEnd: Int,
    codingMode: JPEGFrameCodingMode
  ) throws -> Self {
    let payloadStart = lengthOffset + 2
    guard payloadStart + 6 <= segmentEnd else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let precision = Int(bytes[payloadStart])
    let height = Int(bytes[payloadStart + 1]) << 8 | Int(bytes[payloadStart + 2])
    let width = Int(bytes[payloadStart + 3]) << 8 | Int(bytes[payloadStart + 4])
    let componentCount = Int(bytes[payloadStart + 5])
    guard precision == 8, width > 0, height > 0, componentCount == 1 || componentCount == 3 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let expectedLength = 8.addingReportingOverflow(componentCount * 3)
    guard !expectedLength.overflow,
      lengthOffset + expectedLength.partialValue == segmentEnd
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    var components: [JPEGFrameComponentSampling] = []
    components.reserveCapacity(componentCount)
    var seenIDs = Set<UInt8>()
    var cursor = payloadStart + 6
    for _ in 0..<componentCount {
      let id = bytes[cursor]
      let sampling = bytes[cursor + 1]
      let horizontal = Int(sampling >> 4)
      let vertical = Int(sampling & 0x0F)
      guard seenIDs.insert(id).inserted,
        (1...4).contains(horizontal),
        (1...4).contains(vertical),
        horizontal * vertical <= 10
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      components.append(
        JPEGFrameComponentSampling(
          componentID: id,
          horizontalSamplingFactor: horizontal,
          verticalSamplingFactor: vertical
        )
      )
      cursor += 3
    }

    let samplingKey = components.map {
      ($0.horizontalSamplingFactor << 4) | $0.verticalSamplingFactor
    }
    let samplingMode: JPEGFrameSamplingMode
    switch samplingKey {
    case [0x11]: samplingMode = .singleComponent
    case [0x11, 0x11, 0x11]: samplingMode = .threeComponent444
    case [0x21, 0x11, 0x11]: samplingMode = .threeComponent422
    case [0x12, 0x11, 0x11]: samplingMode = .threeComponent440
    case [0x22, 0x11, 0x11]: samplingMode = .threeComponent420
    default: throw ImageCraftError.unsupportedOrCorruptImage
    }

    guard let maximumHorizontal = components.map(\.horizontalSamplingFactor).max(),
      let maximumVertical = components.map(\.verticalSamplingFactor).max()
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let outputIMCURowHeight = try multiplied(maximumVertical, 8)
    let totalIMCURowCount = try ceilDiv(height, outputIMCURowHeight)
    let internalIMCUBoundaryCount = max(0, totalIMCURowCount - 1)
    let verticalChromaSubsamplingPresent =
      samplingMode == .threeComponent440 || samplingMode == .threeComponent420
    let boundaryAdjacentRows = verticalChromaSubsamplingPresent
      ? try multiplied(internalIMCUBoundaryCount, 2)
      : 0

    return Self(
      codingMode: codingMode,
      width: width,
      height: height,
      precision: precision,
      samplingMode: samplingMode,
      components: components,
      maximumHorizontalSamplingFactor: maximumHorizontal,
      maximumVerticalSamplingFactor: maximumVertical,
      outputIMCURowHeight: outputIMCURowHeight,
      totalIMCURowCount: totalIMCURowCount,
      internalIMCUBoundaryCount: internalIMCUBoundaryCount,
      verticalChromaSubsamplingPresent: verticalChromaSubsamplingPresent,
      verticalChromaBoundaryAdjacentOutputRowCount: boundaryAdjacentRows
    )
  }

  private static func ceilDiv(_ value: Int, _ divisor: Int) throws -> Int {
    guard value >= 0, divisor > 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return value / divisor + (value % divisor == 0 ? 0 : 1)
  }

  private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }
}
