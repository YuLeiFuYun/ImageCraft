/// Shared checked Adam7 geometry for independent PNG backends.
///
/// This helper owns only pass geometry and byte-count arithmetic. Pixel interpretation, filtering
/// bytes-per-pixel, alpha semantics and output representation remain backend-specific.
enum PNGAdam7Geometry {
  struct Pass: Equatable, Sendable {
    let xStart: Int
    let yStart: Int
    let xStep: Int
    let yStep: Int
    let width: Int
    let height: Int
  }

  private static let descriptors: [(xStart: Int, yStart: Int, xStep: Int, yStep: Int)] = [
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
  ]

  static func passes(width: Int, height: Int) -> [Pass]? {
    guard width > 0, height > 0 else { return nil }
    var result: [Pass] = []
    result.reserveCapacity(descriptors.count)
    for descriptor in descriptors {
      guard let passWidth = sampleCount(
        fullCount: width,
        start: descriptor.xStart,
        step: descriptor.xStep
      ), let passHeight = sampleCount(
        fullCount: height,
        start: descriptor.yStart,
        step: descriptor.yStep
      ) else { return nil }
      if passWidth == 0 || passHeight == 0 { continue }
      result.append(
        Pass(
          xStart: descriptor.xStart,
          yStart: descriptor.yStart,
          xStep: descriptor.xStep,
          yStep: descriptor.yStep,
          width: passWidth,
          height: passHeight
        )
      )
    }
    return result.isEmpty ? nil : result
  }

  static func expectedInflatedByteCount(
    passes: [Pass],
    bytesPerPixel: Int
  ) -> Int? {
    guard !passes.isEmpty, bytesPerPixel > 0 else { return nil }
    var total = 0
    for pass in passes {
      let rowBytes = pass.width.multipliedReportingOverflow(by: bytesPerPixel)
      guard !rowBytes.overflow else { return nil }
      let filteredRowBytes = rowBytes.partialValue.addingReportingOverflow(1)
      guard !filteredRowBytes.overflow else { return nil }
      let passBytes = filteredRowBytes.partialValue.multipliedReportingOverflow(by: pass.height)
      guard !passBytes.overflow else { return nil }
      let next = total.addingReportingOverflow(passBytes.partialValue)
      guard !next.overflow else { return nil }
      total = next.partialValue
    }
    return total
  }

  private static func sampleCount(fullCount: Int, start: Int, step: Int) -> Int? {
    guard fullCount > 0, start >= 0, step > 0 else { return nil }
    guard fullCount > start else { return 0 }
    let remaining = fullCount - start
    let rounded = remaining.addingReportingOverflow(step - 1)
    guard !rounded.overflow else { return nil }
    return rounded.partialValue / step
  }
}
