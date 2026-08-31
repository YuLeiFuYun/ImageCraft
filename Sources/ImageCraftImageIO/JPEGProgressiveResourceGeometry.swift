import Foundation
import ImageCraftCore

package typealias JPEGProgressiveSamplingMode = JPEGFrameSamplingMode

package struct JPEGProgressiveComponentGeometry: Codable, Equatable, Sendable {
  package let componentID: UInt8
  package let horizontalSamplingFactor: Int
  package let verticalSamplingFactor: Int
  package let widthInBlocks: Int
  package let heightInBlocks: Int
  package let paddedWidthInBlocks: Int
  package let paddedHeightInBlocks: Int
  package let coefficientPayloadBytes: Int
}

/// Header-derived resource geometry for the narrow independent progressive-JPEG research domain.
///
/// Frame sampling facts come from `JPEGFrameSamplingGeometry`; this type adds only the logical
/// payloads that are specific to the qualified progressive buffered-image mechanism. It remains
/// deliberately weaker than a process-memory bound: controller objects, allocator headers and
/// alignment, entropy tables, SIMD scratch, output surfaces, color state and source buffering are
/// not silently folded into either byte count below.
package struct JPEGProgressiveResourceGeometry: Codable, Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let precision: Int
  package let samplingMode: JPEGProgressiveSamplingMode
  package let components: [JPEGProgressiveComponentGeometry]
  package let coefficientArrayPayloadBytes: Int
  package let fullScaleFancyRowWorkspaceBytes: Int
  package let fancyVerticalContextRowsRequired: Bool

  package static func inspect(_ data: Data) throws -> Self {
    let frame = try JPEGFrameSamplingGeometry.inspect(data)
    guard frame.codingMode == .progressiveDCT else {
      throw ImageCraftError.progressiveDecodingUnsupported
    }

    let maximumHorizontal = frame.maximumHorizontalSamplingFactor
    let maximumVertical = frame.maximumVerticalSamplingFactor
    let chromaDownsampledWidth: Int?
    if frame.components.count == 3 {
      chromaDownsampledWidth = try ceilDiv(
        try multiplied(frame.width, frame.components[1].horizontalSamplingFactor),
        maximumHorizontal
      )
    } else {
      chromaDownsampledWidth = nil
    }

    let needsVerticalContext: Bool
    switch frame.samplingMode {
    case .threeComponent440:
      needsVerticalContext = true
    case .threeComponent420:
      needsVerticalContext = (chromaDownsampledWidth ?? 0) > 2
    case .singleComponent, .threeComponent444, .threeComponent422:
      needsVerticalContext = false
    }
    let mainRowGroups = needsVerticalContext ? 10 : 8

    var components: [JPEGProgressiveComponentGeometry] = []
    components.reserveCapacity(frame.components.count)
    var coefficientPayload = 0
    var mainWorkspace = 0
    for component in frame.components {
      let widthNumerator = try multiplied(
        frame.width,
        component.horizontalSamplingFactor
      )
      let widthDenominator = try multiplied(maximumHorizontal, 8)
      let widthInBlocks = try ceilDiv(widthNumerator, widthDenominator)
      let heightNumerator = try multiplied(
        frame.height,
        component.verticalSamplingFactor
      )
      let heightDenominator = try multiplied(maximumVertical, 8)
      let heightInBlocks = try ceilDiv(heightNumerator, heightDenominator)
      let paddedWidth = try roundUp(
        widthInBlocks,
        component.horizontalSamplingFactor
      )
      let paddedHeight = try roundUp(
        heightInBlocks,
        component.verticalSamplingFactor
      )
      let blockCount = try multiplied(paddedWidth, paddedHeight)
      let componentCoefficientBytes = try multiplied(blockCount, 128)
      coefficientPayload = try added(coefficientPayload, componentCoefficientBytes)

      let samplesPerRow = try multiplied(widthInBlocks, 8)
      let rowCount = try multiplied(
        component.verticalSamplingFactor,
        mainRowGroups
      )
      mainWorkspace = try added(
        mainWorkspace,
        try multiplied(samplesPerRow, rowCount)
      )
      components.append(
        JPEGProgressiveComponentGeometry(
          componentID: component.componentID,
          horizontalSamplingFactor: component.horizontalSamplingFactor,
          verticalSamplingFactor: component.verticalSamplingFactor,
          widthInBlocks: widthInBlocks,
          heightInBlocks: heightInBlocks,
          paddedWidthInBlocks: paddedWidth,
          paddedHeightInBlocks: paddedHeight,
          coefficientPayloadBytes: componentCoefficientBytes
        )
      )
    }

    var upsamplerWorkspace = 0
    let roundedOutputWidth = try roundUp(frame.width, maximumHorizontal)
    for component in frame.components
    where component.horizontalSamplingFactor != maximumHorizontal
      || component.verticalSamplingFactor != maximumVertical
    {
      upsamplerWorkspace = try added(
        upsamplerWorkspace,
        try multiplied(roundedOutputWidth, maximumVertical)
      )
    }

    return Self(
      width: frame.width,
      height: frame.height,
      precision: frame.precision,
      samplingMode: frame.samplingMode,
      components: components,
      coefficientArrayPayloadBytes: coefficientPayload,
      fullScaleFancyRowWorkspaceBytes: try added(mainWorkspace, upsamplerWorkspace),
      fancyVerticalContextRowsRequired: needsVerticalContext
    )
  }

  private static func ceilDiv(_ value: Int, _ divisor: Int) throws -> Int {
    guard value >= 0, divisor > 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return value / divisor + (value % divisor == 0 ? 0 : 1)
  }

  private static func roundUp(_ value: Int, _ factor: Int) throws -> Int {
    try multiplied(try ceilDiv(value, factor), factor)
  }

  private static func added(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }

  private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }
}
