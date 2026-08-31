import Accelerate
import Darwin
import Foundation

struct APNGOwnedPlaybackPolicy: Equatable, Sendable {
  static let bounded1024 = APNGOwnedPlaybackPolicy(
    decodePolicy: .bounded1024,
    checkpointPolicy: .bounded1024,
    decompressorWorkspaceBytes: 256 * 1_024
  )

  let decodePolicy: APNGRawSubrectDecodePolicy
  let checkpointPolicy: APNGCompressedCheckpointPolicy
  let decompressorWorkspaceBytes: Int

  func validate() throws {
    try decodePolicy.validate()
    try checkpointPolicy.validate()
    guard decompressorWorkspaceBytes >= 0,
      decompressorWorkspaceBytes <= 1 * 1_024 * 1_024
    else { throw APNGCompressedCheckpointError.invalidPolicy }
  }
}

struct APNGOwnedPlaybackDiagnostics: Equatable, Sendable {
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

struct APNGOwnedStraightAlphaPlayback: Sendable {
  let encodedImage: APNGEncodedSubrectImage
  let policy: APNGOwnedPlaybackPolicy
  let diagnostics: APNGOwnedPlaybackDiagnostics

  private let checkpointStore: APNGCompressedCheckpointStore
  private let semanticReplayStarts: [Int]

  init(
    encodedData: Data,
    policy: APNGOwnedPlaybackPolicy = .bounded1024
  ) throws {
    try policy.validate()
    let image = try APNGRawSubrectDecoder.parseEncoded(
      encodedData,
      policy: policy.decodePolicy
    )
    let encodedPayloadBytes = try image.frames.reduce(into: 0) { total, frame in
      let next = total.addingReportingOverflow(frame.compressedPayload.count)
      guard !next.overflow else {
        throw APNGCompressedCheckpointError.retainedBudgetExceeded
      }
      total = next.partialValue
    }
    guard encodedPayloadBytes <= policy.checkpointPolicy.maximumRetainedBytes else {
      throw APNGCompressedCheckpointError.retainedBudgetExceeded
    }
    let availableCheckpointBytes =
      policy.checkpointPolicy.maximumRetainedBytes - encodedPayloadBytes
    let storePolicy = APNGCompressedCheckpointPolicy(
      maximumCanvasDimension: policy.checkpointPolicy.maximumCanvasDimension,
      maximumRetainedBytes: availableCheckpointBytes,
      maximumReplayFrames: policy.checkpointPolicy.maximumReplayFrames,
      maximumCheckpointBlobRatioPPM: policy.checkpointPolicy
        .maximumCheckpointBlobRatioPPM
    )
    var store = try APNGCompressedCheckpointStore(
      frameCount: image.frames.count,
      width: image.canvasWidth,
      height: image.canvasHeight,
      policy: storePolicy
    )
    let semanticReplayStarts = try Self.persistentSemanticReplayStarts(for: image)
    let canvasBytes = try Self.canvasByteCount(
      width: image.canvasWidth,
      height: image.canvasHeight
    )
    var maximumRawSubrectBytes = 0
    var maximumPreviousBytes = 0
    for encodedFrame in image.frames {
      let frameBytes = try Self.canvasByteCount(
        width: encodedFrame.control.width,
        height: encodedFrame.control.height
      )
      maximumRawSubrectBytes = max(maximumRawSubrectBytes, frameBytes)
      if encodedFrame.control.disposal == 2 {
        maximumPreviousBytes = max(maximumPreviousBytes, frameBytes)
      }
    }
    if image.frames.count > storePolicy.maximumReplayFrames {
      var canvas = Data(repeating: 0, count: canvasBytes)
      var latestCheckpointFrameIndex = 0
      for index in image.frames.indices {
        if index > 0 {
          let replayStart = max(
            latestCheckpointFrameIndex,
            semanticReplayStarts[index]
          )
          let replayFrameCount = index - replayStart + 1
          if replayFrameCount > storePolicy.maximumReplayFrames {
            try store.insert(preFrameStraightAlphaRGBA: canvas, at: index)
            latestCheckpointFrameIndex = index
          }
        }
        let frame = try image.decodeFrame(at: index)
        _ = try Self.render(
          frame,
          canvas: &canvas,
          canvasWidth: image.canvasWidth,
          canvasHeight: image.canvasHeight,
          materializeOutput: false
        )
      }
    }
    let semanticReplayResetCount = semanticReplayStarts.indices.dropFirst().reduce(into: 0) {
      count, index in
      if semanticReplayStarts[index] > semanticReplayStarts[index - 1] { count += 1 }
    }
    let maximumResolvedReplayFrames = try image.frames.indices.reduce(into: 0) { maximum, index in
      let resolution = try store.resolve(
        targetFrameIndex: index,
        semanticReplayStart: semanticReplayStarts[index]
      )
      maximum = max(maximum, resolution.replayFrameCount)
    }
    let retained = encodedPayloadBytes.addingReportingOverflow(store.retainedBytes)
    guard !retained.overflow else {
      throw APNGCompressedCheckpointError.retainedBudgetExceeded
    }
    let working = try Self.addingWithoutOverflow(
      [
        canvasBytes,
        maximumRawSubrectBytes,
        maximumPreviousBytes,
        policy.decompressorWorkspaceBytes,
      ]
    )
    let peak = try Self.addingWithoutOverflow(
      [retained.partialValue, working, canvasBytes]
    )
    encodedImage = image
    self.policy = policy
    checkpointStore = store
    self.semanticReplayStarts = semanticReplayStarts
    diagnostics = APNGOwnedPlaybackDiagnostics(
      encodedFramePayloadBytes: encodedPayloadBytes,
      retainedCheckpointBytes: store.retainedBytes,
      retainedBytes: retained.partialValue,
      retainedCheckpointCount: store.retainedCheckpointCount,
      maximumReplayFrames: storePolicy.maximumReplayFrames,
      semanticReplayResetCount: semanticReplayResetCount,
      maximumResolvedReplayFrames: maximumResolvedReplayFrames,
      canvasRGBABytes: canvasBytes,
      maximumRawSubrectRGBABytes: maximumRawSubrectBytes,
      maximumPreviousSaveRGBABytes: maximumPreviousBytes,
      materializedOutputRGBABytes: canvasBytes,
      decompressorWorkspaceBytes: policy.decompressorWorkspaceBytes,
      modeledPeakBytesUpperBound: peak
    )
  }

  func frame(at targetFrameIndex: Int) throws -> Data {
    guard
      let frame = try frames(
        in: targetFrameIndex..<(targetFrameIndex + 1)
      ).first
    else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    return frame
  }

  func frames(in range: Range<Int>) throws -> [Data] {
    guard !range.isEmpty,
      range.lowerBound >= 0,
      range.upperBound <= encodedImage.frames.count
    else { throw APNGCompressedCheckpointError.invalidFrameIndex }
    let resolution = try checkpointStore.resolve(
      targetFrameIndex: range.lowerBound,
      semanticReplayStart: semanticReplayStarts[range.lowerBound]
    )
    let canvasBytes = diagnostics.canvasRGBABytes
    var canvas =
      try checkpointStore.decode(resolution)
      ?? Data(repeating: 0, count: canvasBytes)
    var outputs: [Data] = []
    outputs.reserveCapacity(range.count)
    for index in resolution.checkpointFrameIndex..<range.upperBound {
      let frame = try encodedImage.decodeFrame(at: index)
      if let output = try Self.render(
        frame,
        canvas: &canvas,
        canvasWidth: encodedImage.canvasWidth,
        canvasHeight: encodedImage.canvasHeight,
        materializeOutput: range.contains(index)
      ) {
        outputs.append(output)
      }
    }
    guard outputs.count == range.count else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    return outputs
  }

  private static func persistentSemanticReplayStarts(
    for image: APNGEncodedSubrectImage
  ) throws -> [Int] {
    var persistentStart = 0
    var starts: [Int] = []
    starts.reserveCapacity(image.frames.count)
    for (index, frame) in image.frames.enumerated() {
      let control = frame.control
      let fullCanvas =
        control.xOffset == 0 && control.yOffset == 0
        && control.width == image.canvasWidth
        && control.height == image.canvasHeight
      if fullCanvas, control.blend == 0, control.disposal != 2 {
        persistentStart = index
      }
      guard persistentStart <= index else {
        throw APNGCompressedCheckpointError.invalidFrameIndex
      }
      starts.append(persistentStart)
      if fullCanvas, control.disposal == 1 {
        persistentStart = index + 1
      }
    }
    return starts
  }

  private static func render(
    _ frame: APNGRawSubrectFrame,
    canvas: inout Data,
    canvasWidth: Int,
    canvasHeight: Int,
    materializeOutput: Bool
  ) throws -> Data? {
    guard canvas.count == canvasWidth * canvasHeight * 4 else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    let control = frame.control
    let previous =
      control.disposal == 2
      ? extractRegion(canvas, canvasWidth: canvasWidth, control: control)
      : nil
    if control.blend == 0 {
      copySource(
        frame.straightAlphaRGBA,
        into: &canvas,
        canvasWidth: canvasWidth,
        control: control
      )
    } else {
      blendSourceOver(
        frame.straightAlphaRGBA,
        into: &canvas,
        canvasWidth: canvasWidth,
        control: control
      )
    }
    let output: Data?
    if materializeOutput {
      output = try premultipliedOutput(
        canvas,
        width: canvasWidth,
        height: canvasHeight
      )
    } else {
      output = nil
    }
    switch control.disposal {
    case 0:
      break
    case 1:
      clearRegion(&canvas, canvasWidth: canvasWidth, control: control)
    case 2:
      guard let previous else {
        throw APNGRawSubrectDecodeError.decodedByteCountMismatch
      }
      restoreRegion(
        &canvas,
        canvasWidth: canvasWidth,
        control: control,
        bytes: previous
      )
    default:
      throw APNGRawSubrectDecodeError.invalidFrameControl
    }
    return output
  }

  private static func copySource(
    _ source: Data,
    into canvas: inout Data,
    canvasWidth: Int,
    control: APNGRawSubrectFrameControl
  ) {
    let rowBytes = control.width * 4
    source.withUnsafeBytes { sourceRaw in
      canvas.withUnsafeMutableBytes { canvasRaw in
        guard let sourceBase = sourceRaw.baseAddress,
          let canvasBase = canvasRaw.baseAddress
        else { return }
        for row in 0..<control.height {
          let sourceOffset = row * rowBytes
          let destinationOffset =
            ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
          memcpy(
            canvasBase.advanced(by: destinationOffset),
            sourceBase.advanced(by: sourceOffset),
            rowBytes
          )
        }
      }
    }
  }

  private static func blendSourceOver(
    _ source: Data,
    into canvas: inout Data,
    canvasWidth: Int,
    control: APNGRawSubrectFrameControl
  ) {
    source.withUnsafeBytes { sourceRaw in
      canvas.withUnsafeMutableBytes { canvasRaw in
        let sourceBytes = sourceRaw.bindMemory(to: UInt8.self)
        let canvasBytes = canvasRaw.bindMemory(to: UInt8.self)
        var sourceOffset = 0
        for row in 0..<control.height {
          var destinationOffset =
            ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
          for _ in 0..<control.width {
            let sourceAlpha = Int(sourceBytes[sourceOffset + 3])
            if sourceAlpha == 255 {
              canvasBytes[destinationOffset] = sourceBytes[sourceOffset]
              canvasBytes[destinationOffset + 1] = sourceBytes[sourceOffset + 1]
              canvasBytes[destinationOffset + 2] = sourceBytes[sourceOffset + 2]
              canvasBytes[destinationOffset + 3] = 255
            } else if sourceAlpha != 0 {
              let destinationAlpha = Int(canvasBytes[destinationOffset + 3])
              if destinationAlpha == 0 {
                canvasBytes[destinationOffset] = sourceBytes[sourceOffset]
                canvasBytes[destinationOffset + 1] = sourceBytes[sourceOffset + 1]
                canvasBytes[destinationOffset + 2] = sourceBytes[sourceOffset + 2]
                canvasBytes[destinationOffset + 3] = UInt8(sourceAlpha)
              } else {
                let inverseAlpha = 255 - sourceAlpha
                let alphaNumerator =
                  sourceAlpha * 255 + destinationAlpha * inverseAlpha
                canvasBytes[destinationOffset] = overChannel(
                  source: sourceBytes[sourceOffset],
                  sourceAlpha: sourceAlpha,
                  destination: canvasBytes[destinationOffset],
                  destinationAlpha: destinationAlpha,
                  inverseAlpha: inverseAlpha,
                  alphaNumerator: alphaNumerator
                )
                canvasBytes[destinationOffset + 1] = overChannel(
                  source: sourceBytes[sourceOffset + 1],
                  sourceAlpha: sourceAlpha,
                  destination: canvasBytes[destinationOffset + 1],
                  destinationAlpha: destinationAlpha,
                  inverseAlpha: inverseAlpha,
                  alphaNumerator: alphaNumerator
                )
                canvasBytes[destinationOffset + 2] = overChannel(
                  source: sourceBytes[sourceOffset + 2],
                  sourceAlpha: sourceAlpha,
                  destination: canvasBytes[destinationOffset + 2],
                  destinationAlpha: destinationAlpha,
                  inverseAlpha: inverseAlpha,
                  alphaNumerator: alphaNumerator
                )
                canvasBytes[destinationOffset + 3] = UInt8(
                  min(255, alphaNumerator / 255)
                )
              }
            }
            sourceOffset += 4
            destinationOffset += 4
          }
        }
      }
    }
  }

  @inline(__always)
  private static func overChannel(
    source: UInt8,
    sourceAlpha: Int,
    destination: UInt8,
    destinationAlpha: Int,
    inverseAlpha: Int,
    alphaNumerator: Int
  ) -> UInt8 {
    let numerator =
      Int(source) * sourceAlpha * 255
      + Int(destination) * destinationAlpha * inverseAlpha
    return UInt8(min(255, numerator / alphaNumerator))
  }

  private static func extractRegion(
    _ canvas: Data,
    canvasWidth: Int,
    control: APNGRawSubrectFrameControl
  ) -> Data {
    let rowBytes = control.width * 4
    var result = Data(count: rowBytes * control.height)
    canvas.withUnsafeBytes { canvasRaw in
      result.withUnsafeMutableBytes { resultRaw in
        guard let canvasBase = canvasRaw.baseAddress,
          let resultBase = resultRaw.baseAddress
        else { return }
        for row in 0..<control.height {
          let sourceOffset =
            ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
          memcpy(
            resultBase.advanced(by: row * rowBytes),
            canvasBase.advanced(by: sourceOffset),
            rowBytes
          )
        }
      }
    }
    return result
  }

  private static func clearRegion(
    _ canvas: inout Data,
    canvasWidth: Int,
    control: APNGRawSubrectFrameControl
  ) {
    let rowBytes = control.width * 4
    canvas.withUnsafeMutableBytes { canvasRaw in
      guard let canvasBase = canvasRaw.baseAddress else { return }
      for row in 0..<control.height {
        let offset =
          ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
        memset(canvasBase.advanced(by: offset), 0, rowBytes)
      }
    }
  }

  private static func restoreRegion(
    _ canvas: inout Data,
    canvasWidth: Int,
    control: APNGRawSubrectFrameControl,
    bytes: Data
  ) {
    let rowBytes = control.width * 4
    bytes.withUnsafeBytes { sourceRaw in
      canvas.withUnsafeMutableBytes { canvasRaw in
        guard let sourceBase = sourceRaw.baseAddress,
          let canvasBase = canvasRaw.baseAddress
        else { return }
        for row in 0..<control.height {
          let destinationOffset =
            ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
          memcpy(
            canvasBase.advanced(by: destinationOffset),
            sourceBase.advanced(by: row * rowBytes),
            rowBytes
          )
        }
      }
    }
  }

  private static func premultipliedOutput(
    _ canvas: Data,
    width: Int,
    height: Int
  ) throws -> Data {
    let rowBytesResult = width.multipliedReportingOverflow(by: 4)
    let expectedBytesResult = rowBytesResult.partialValue.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0,
      !rowBytesResult.overflow,
      !expectedBytesResult.overflow,
      canvas.count == expectedBytesResult.partialValue
    else { throw APNGRawSubrectDecodeError.decodedByteCountMismatch }

    var output = Data(count: canvas.count)
    let error = canvas.withUnsafeBytes { canvasRaw in
      output.withUnsafeMutableBytes { outputRaw -> vImage_Error in
        guard let sourceAddress = canvasRaw.baseAddress,
          let destinationAddress = outputRaw.baseAddress
        else { return kvImageNullPointerArgument }
        var source = vImage_Buffer(
          data: UnsafeMutableRawPointer(mutating: sourceAddress),
          height: vImagePixelCount(height),
          width: vImagePixelCount(width),
          rowBytes: rowBytesResult.partialValue
        )
        var destination = vImage_Buffer(
          data: destinationAddress,
          height: vImagePixelCount(height),
          width: vImagePixelCount(width),
          rowBytes: rowBytesResult.partialValue
        )
        return vImagePremultiplyData_RGBA8888(
          &source,
          &destination,
          vImage_Flags(kvImageDoNotTile)
        )
      }
    }
    guard error == kvImageNoError else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    return output
  }

  private static func canvasByteCount(width: Int, height: Int) throws -> Int {
    let pixels = width.multipliedReportingOverflow(by: height)
    guard !pixels.overflow else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
    guard !bytes.overflow else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    return bytes.partialValue
  }

  private static func addingWithoutOverflow(_ values: [Int]) throws -> Int {
    var total = 0
    for value in values {
      let next = total.addingReportingOverflow(value)
      guard !next.overflow else {
        throw APNGCompressedCheckpointError.retainedBudgetExceeded
      }
      total = next.partialValue
    }
    return total
  }
}

package struct APNGOwnedPlaybackInteropDiagnostics: Sendable {
  package let encodedFramePayloadBytes: Int
  package let retainedCheckpointBytes: Int
  package let retainedBytes: Int
  package let retainedCheckpointCount: Int
  package let maximumReplayFrames: Int
  package let semanticReplayResetCount: Int
  package let maximumResolvedReplayFrames: Int
  package let canvasRGBABytes: Int
  package let maximumRawSubrectRGBABytes: Int
  package let maximumPreviousSaveRGBABytes: Int
  package let materializedOutputRGBABytes: Int
  package let decompressorWorkspaceBytes: Int
  package let modeledPeakBytesUpperBound: Int
}

package struct APNGOwnedPlaybackInteropResult: Sendable {
  package let canvasWidth: Int
  package let canvasHeight: Int
  package let numPlays: UInt32
  package let firstAnimationFrameUsesIDAT: Bool
  package let frames: [Data]
  package let diagnostics: APNGOwnedPlaybackInteropDiagnostics
}

/// Package-only evidence seam for the unpublished owned APNG playback prototype.
package enum APNGOwnedPlaybackInterop {
  package static func decodeAll(_ encodedData: Data) throws -> APNGOwnedPlaybackInteropResult {
    let playback = try APNGOwnedStraightAlphaPlayback(encodedData: encodedData)
    let frames = try playback.frames(in: playback.encodedImage.frames.indices)
    let diagnostics = playback.diagnostics
    return APNGOwnedPlaybackInteropResult(
      canvasWidth: playback.encodedImage.canvasWidth,
      canvasHeight: playback.encodedImage.canvasHeight,
      numPlays: playback.encodedImage.numPlays,
      firstAnimationFrameUsesIDAT: playback.encodedImage.firstAnimationFrameUsesIDAT,
      frames: frames,
      diagnostics: APNGOwnedPlaybackInteropDiagnostics(
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
      )
    )
  }
}
