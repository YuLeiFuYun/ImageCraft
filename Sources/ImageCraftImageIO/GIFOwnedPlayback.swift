import Foundation
import ImageCraftCore

struct GIFOwnedPlaybackDiagnostics: Equatable, Sendable {
  let encodedFramePayloadBytes: Int
  let retainedPaletteBytes: Int
  let retainedBytes: Int
  let canvasIndexBytes: Int
  let materializedOutputRGBABytes: Int
  let lzwWorkspaceBytes: Int
  let modeledPeakBytesUpperBound: Int
}

struct GIFOwnedPlayback: Sendable {
  private struct Frame: Sendable {
    let minimumCodeSize: Int
    let payload: Data
    let palette: Data
    let transparentIndex: Int?
    let isInterlaced: Bool
    let xOffset: Int
    let yOffset: Int
    let width: Int
    let height: Int
    var usesTransparentIndex = false
  }

  let canvasWidth: Int
  let canvasHeight: Int
  let frameCount: Int
  let diagnostics: GIFOwnedPlaybackDiagnostics
  private let frames: [Frame]
  private let requiresReplay: Bool
  private let replayStarts: [Int]

  static func prepareIfSupported(
    data: Data,
    inspection: EncodedAnimationInspection,
    maximumReplayFrames: Int
  ) throws -> Self? {
    guard inspection.container == .gif, inspection.frames.count > 1 else { return nil }
    let requiresReplay = inspection.frames.contains { descriptor in
      descriptor.rect.x != 0 || descriptor.rect.y != 0
        || descriptor.rect.width != inspection.canvasWidth
        || descriptor.rect.height != inspection.canvasHeight
    }
    if requiresReplay {
      guard let first = inspection.frames.first,
        first.rect.x == 0, first.rect.y == 0,
        first.rect.width == inspection.canvasWidth,
        first.rect.height == inspection.canvasHeight,
        inspection.frames.allSatisfy({ $0.disposal == .none })
      else { return nil }
    }

    return try data.withUnsafeBytes { raw -> Self? in
      let bytes = raw.bindMemory(to: UInt8.self)
      guard bytes.count >= 13,
        String(decoding: bytes[0..<6], as: UTF8.self) == "GIF87a"
          || String(decoding: bytes[0..<6], as: UTF8.self) == "GIF89a",
        readUInt16LE(bytes, at: 6) == inspection.canvasWidth,
        readUInt16LE(bytes, at: 8) == inspection.canvasHeight
      else { throw ImageCraftError.animationTimelineInvalid }

      var offset = 13
      let logicalPacked = bytes[10]
      let globalPalette: Data?
      if logicalPacked & 0x80 != 0 {
        let count = 1 << (Int(logicalPacked & 0x07) + 1)
        let byteCount = try multiplied(count, 3)
        let end = try advancing(offset, by: byteCount, limit: bytes.count)
        globalPalette = Data(bytes[offset..<end])
        offset = end
      } else {
        globalPalette = nil
      }

      var parsed: [Frame] = []
      parsed.reserveCapacity(inspection.frames.count)
      var totalPayloadBytes = 0
      var totalPaletteBytes = 0
      var pendingTransparentIndex: Int?

      while offset < bytes.count {
        let marker = bytes[offset]
        offset += 1
        switch marker {
        case 0x3B:
          guard offset == bytes.count, parsed.count == inspection.frames.count else {
            throw ImageCraftError.animationTimelineInvalid
          }
          let pixels = try multiplied(inspection.canvasWidth, inspection.canvasHeight)
          for index in parsed.indices {
            let framePixels = try multiplied(parsed[index].width, parsed[index].height)
            guard
              let validation = validateLZW(
                payload: parsed[index].payload,
                minimumCodeSize: parsed[index].minimumCodeSize,
                expectedPixelCount: framePixels,
                paletteCount: parsed[index].palette.count / 3,
                transparentIndex: parsed[index].transparentIndex
              )
            else { return nil }
            parsed[index].usesTransparentIndex = validation.usesTransparentIndex
          }
          var replayStarts = [Int](repeating: 0, count: parsed.count)
          if requiresReplay {
            guard maximumReplayFrames > 0 else { return nil }
            var currentReset = 0
            var maximumReplaySpan = 0
            for index in parsed.indices {
              let frame = parsed[index]
              let fullCanvas =
                frame.xOffset == 0 && frame.yOffset == 0
                && frame.width == inspection.canvasWidth
                && frame.height == inspection.canvasHeight
              if index == 0 || (fullCanvas && !frame.usesTransparentIndex) {
                currentReset = index
              }
              replayStarts[index] = currentReset
              maximumReplaySpan = max(maximumReplaySpan, index - currentReset + 1)
            }
            guard maximumReplaySpan <= maximumReplayFrames else { return nil }
          }
          let canvasRGBA = try multiplied(pixels, 4)
          let retained = try adding(totalPayloadBytes, totalPaletteBytes)
          let workspace = 4_096 * 2 + 4_096 * 2 + 4_096
          let canvasWorkingBytes = try multiplied(canvasRGBA, requiresReplay ? 2 : 1)
          let peak = try adding([retained, pixels, canvasWorkingBytes, workspace])
          return Self(
            canvasWidth: inspection.canvasWidth,
            canvasHeight: inspection.canvasHeight,
            frameCount: parsed.count,
            diagnostics: GIFOwnedPlaybackDiagnostics(
              encodedFramePayloadBytes: totalPayloadBytes,
              retainedPaletteBytes: totalPaletteBytes,
              retainedBytes: retained,
              canvasIndexBytes: pixels,
              materializedOutputRGBABytes: canvasRGBA,
              lzwWorkspaceBytes: workspace,
              modeledPeakBytesUpperBound: peak
            ),
            frames: parsed,
            requiresReplay: requiresReplay,
            replayStarts: replayStarts
          )

        case 0x21:
          guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
          let label = bytes[offset]
          offset += 1
          if label == 0xF9 {
            guard offset + 6 <= bytes.count, bytes[offset] == 4, bytes[offset + 5] == 0 else {
              throw ImageCraftError.animationTimelineInvalid
            }
            let packed = bytes[offset + 1]
            pendingTransparentIndex = packed & 0x01 != 0 ? Int(bytes[offset + 4]) : nil
            offset += 6
          } else {
            offset = try skipSubBlocks(bytes, from: offset)
          }

        case 0x2C:
          guard parsed.count < inspection.frames.count, offset + 9 <= bytes.count,
            let xOffset = readUInt16LE(bytes, at: offset),
            let yOffset = readUInt16LE(bytes, at: offset + 2),
            let width = readUInt16LE(bytes, at: offset + 4),
            let height = readUInt16LE(bytes, at: offset + 6)
          else { return nil }
          let descriptor = inspection.frames[parsed.count]
          guard xOffset == descriptor.rect.x, yOffset == descriptor.rect.y,
            width == descriptor.rect.width, height == descriptor.rect.height
          else { return nil }
          let packed = bytes[offset + 8]
          let isInterlaced = packed & 0x40 != 0
          offset += 9

          let palette: Data
          if packed & 0x80 != 0 {
            let count = 1 << (Int(packed & 0x07) + 1)
            let byteCount = try multiplied(count, 3)
            let end = try advancing(offset, by: byteCount, limit: bytes.count)
            palette = Data(bytes[offset..<end])
            offset = end
          } else if let globalPalette {
            palette = globalPalette
          } else {
            throw ImageCraftError.animationTimelineInvalid
          }
          guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
          let minimumCodeSize = Int(bytes[offset])
          guard (2...8).contains(minimumCodeSize) else {
            throw ImageCraftError.animationTimelineInvalid
          }
          offset += 1
          let blocks = try collectSubBlocks(bytes, from: offset)
          offset = blocks.nextOffset
          guard !blocks.payload.isEmpty else { throw ImageCraftError.animationTimelineInvalid }
          parsed.append(
            Frame(
              minimumCodeSize: minimumCodeSize,
              payload: blocks.payload,
              palette: palette,
              transparentIndex: pendingTransparentIndex,
              isInterlaced: isInterlaced,
              xOffset: xOffset,
              yOffset: yOffset,
              width: width,
              height: height
            )
          )
          pendingTransparentIndex = nil
          totalPayloadBytes = try adding(totalPayloadBytes, blocks.payload.count)
          totalPaletteBytes = try adding(totalPaletteBytes, palette.count)

        default:
          throw ImageCraftError.animationTimelineInvalid
        }
      }
      throw ImageCraftError.animationTimelineInvalid
    }
  }

  func frames(in range: Range<Int>) throws -> [Data] {
    guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= frames.count else {
      throw ImageCraftError.animationFrameIndexOutOfRange
    }
    if requiresReplay { return try replayedFrames(in: range) }

    let pixelCount = try Self.multiplied(canvasWidth, canvasHeight)
    var result: [Data] = []
    result.reserveCapacity(range.count)
    for index in range {
      let frame = frames[index]
      let indices = try Self.decodeIndices(
        payload: frame.payload,
        minimumCodeSize: frame.minimumCodeSize,
        expectedPixelCount: pixelCount
      )
      result.append(
        try Self.rgba(
          indices: indices,
          palette: frame.palette,
          transparentIndex: frame.transparentIndex,
          width: canvasWidth,
          height: canvasHeight,
          isInterlaced: frame.isInterlaced
        )
      )
    }
    return result
  }

  private func replayedFrames(in range: Range<Int>) throws -> [Data] {
    let canvasPixels = try Self.multiplied(canvasWidth, canvasHeight)
    var canvas = Data(count: try Self.multiplied(canvasPixels, 4))
    var result: [Data] = []
    result.reserveCapacity(range.count)
    let replayStart = replayStarts[range.lowerBound]
    for index in replayStart..<range.upperBound {
      let frame = frames[index]
      let framePixels = try Self.multiplied(frame.width, frame.height)
      let indices = try Self.decodeIndices(
        payload: frame.payload,
        minimumCodeSize: frame.minimumCodeSize,
        expectedPixelCount: framePixels
      )
      try Self.composite(
        indices: indices,
        frame: frame,
        canvas: &canvas,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight
      )
      if range.contains(index) { result.append(canvas) }
    }
    guard result.count == range.count else { throw ImageCraftError.decodeFailed }
    return result
  }

  private static func composite(
    indices: Data,
    frame: Frame,
    canvas: inout Data,
    canvasWidth: Int,
    canvasHeight: Int
  ) throws {
    let framePixels = try multiplied(frame.width, frame.height)
    guard indices.count == framePixels, frame.palette.count >= 6, frame.palette.count % 3 == 0,
      frame.xOffset >= 0, frame.yOffset >= 0,
      frame.xOffset + frame.width <= canvasWidth,
      frame.yOffset + frame.height <= canvasHeight
    else { throw ImageCraftError.decodeFailed }
    let paletteCount = frame.palette.count / 3
    let valid = indices.withUnsafeBytes { indexRaw in
      frame.palette.withUnsafeBytes { paletteRaw in
        canvas.withUnsafeMutableBytes { canvasRaw in
          let source = indexRaw.bindMemory(to: UInt8.self)
          let colors = paletteRaw.bindMemory(to: UInt8.self)
          let destination = canvasRaw.bindMemory(to: UInt8.self)
          for sourcePixel in 0..<framePixels {
            let paletteIndex = Int(source[sourcePixel])
            guard paletteIndex < paletteCount else { return false }
            if frame.transparentIndex == paletteIndex { continue }
            let sourceRow = sourcePixel / frame.width
            let column = sourcePixel - sourceRow * frame.width
            let frameRow =
              frame.isInterlaced
              ? interlacedTargetRow(sourceRow: sourceRow, height: frame.height)
              : sourceRow
            guard frameRow >= 0, frameRow < frame.height else { return false }
            let targetPixel =
              (frame.yOffset + frameRow) * canvasWidth + frame.xOffset + column
            let outputOffset = targetPixel * 4
            let colorOffset = paletteIndex * 3
            destination[outputOffset] = colors[colorOffset]
            destination[outputOffset + 1] = colors[colorOffset + 1]
            destination[outputOffset + 2] = colors[colorOffset + 2]
            destination[outputOffset + 3] = 255
          }
          return true
        }
      }
    }
    guard valid else { throw ImageCraftError.decodeFailed }
  }

  private static func rgba(
    indices: Data,
    palette: Data,
    transparentIndex: Int?,
    width: Int,
    height: Int,
    isInterlaced: Bool
  ) throws -> Data {
    let pixelCount = try multiplied(width, height)
    guard indices.count == pixelCount, palette.count >= 6, palette.count % 3 == 0 else {
      throw ImageCraftError.decodeFailed
    }
    let paletteCount = palette.count / 3
    var rgba = Data(count: try multiplied(pixelCount, 4))
    if !isInterlaced {
      var table = [UInt32](repeating: 0, count: 256)
      palette.withUnsafeBytes { paletteRaw in
        let colors = paletteRaw.bindMemory(to: UInt8.self)
        for paletteIndex in 0..<paletteCount {
          guard transparentIndex != paletteIndex else { continue }
          let colorOffset = paletteIndex * 3
          let packed =
            UInt32(colors[colorOffset])
            | UInt32(colors[colorOffset + 1]) << 8
            | UInt32(colors[colorOffset + 2]) << 16
            | UInt32(255) << 24
          table[paletteIndex] = UInt32(littleEndian: packed)
        }
      }
      let valid = indices.withUnsafeBytes { indexRaw in
        rgba.withUnsafeMutableBytes { rgbaRaw in
          let source = indexRaw.bindMemory(to: UInt8.self)
          let destination = rgbaRaw.bindMemory(to: UInt32.self)
          guard source.count == pixelCount, destination.count == pixelCount else { return false }
          for pixel in 0..<pixelCount {
            let paletteIndex = Int(source[pixel])
            guard paletteIndex < paletteCount else { return false }
            destination[pixel] = table[paletteIndex]
          }
          return true
        }
      }
      guard valid else { throw ImageCraftError.decodeFailed }
      return rgba
    }
    let valid = indices.withUnsafeBytes { indexRaw in
      palette.withUnsafeBytes { paletteRaw in
        rgba.withUnsafeMutableBytes { rgbaRaw in
          let source = indexRaw.bindMemory(to: UInt8.self)
          let colors = paletteRaw.bindMemory(to: UInt8.self)
          let destination = rgbaRaw.bindMemory(to: UInt8.self)
          guard source.count == pixelCount else { return false }
          for sourcePixel in 0..<pixelCount {
            let paletteIndex = Int(source[sourcePixel])
            guard paletteIndex < paletteCount else { return false }
            let sourceRow = sourcePixel / width
            let column = sourcePixel - sourceRow * width
            let targetRow =
              isInterlaced
              ? interlacedTargetRow(sourceRow: sourceRow, height: height)
              : sourceRow
            guard targetRow >= 0, targetRow < height else { return false }
            let outputOffset = (targetRow * width + column) * 4
            if transparentIndex == paletteIndex {
              destination[outputOffset] = 0
              destination[outputOffset + 1] = 0
              destination[outputOffset + 2] = 0
              destination[outputOffset + 3] = 0
            } else {
              let colorOffset = paletteIndex * 3
              destination[outputOffset] = colors[colorOffset]
              destination[outputOffset + 1] = colors[colorOffset + 1]
              destination[outputOffset + 2] = colors[colorOffset + 2]
              destination[outputOffset + 3] = 255
            }
          }
          return true
        }
      }
    }
    guard valid else { throw ImageCraftError.decodeFailed }
    return rgba
  }

  private static func interlacedTargetRow(sourceRow: Int, height: Int) -> Int {
    let pass1Count = (height + 7) / 8
    let pass2Count = height > 4 ? (height + 3) / 8 : 0
    let pass3Count = height > 2 ? (height + 1) / 4 : 0
    if sourceRow < pass1Count { return sourceRow * 8 }
    if sourceRow < pass1Count + pass2Count {
      return 4 + (sourceRow - pass1Count) * 8
    }
    if sourceRow < pass1Count + pass2Count + pass3Count {
      return 2 + (sourceRow - pass1Count - pass2Count) * 4
    }
    return 1 + (sourceRow - pass1Count - pass2Count - pass3Count) * 2
  }

  private struct GIFLZWValidation {
    let usesTransparentIndex: Bool
  }

  private static func validateLZW(
    payload: Data,
    minimumCodeSize: Int,
    expectedPixelCount: Int,
    paletteCount: Int,
    transparentIndex: Int?
  ) -> GIFLZWValidation? {
    payload.withUnsafeBytes { payloadRaw -> GIFLZWValidation? in
      let clearCode = 1 << minimumCodeSize
      let endCode = clearCode + 1
      var codeSize = minimumCodeSize + 1
      var nextCode = endCode + 1
      var reader = GIFLSBBitReader(bytes: payloadRaw.bindMemory(to: UInt8.self))
      var oldCode: Int?
      var outputCount = 0
      var sawEndCode = false
      var usesTransparentIndex = false

      func resetDictionary() {
        codeSize = minimumCodeSize + 1
        nextCode = endCode + 1
        oldCode = nil
      }

      return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 4_096) { lengths in
        withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 4_096) { firstLiterals in
          withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4_096) { transparentFlags in
            for literal in 0..<clearCode {
              lengths[literal] = 1
              firstLiterals[literal] = UInt16(literal)
              transparentFlags[literal] = transparentIndex == literal ? 1 : 0
            }

            while let code = reader.read(bits: codeSize) {
              if code == clearCode {
                resetDictionary()
                continue
              }
              if code == endCode {
                sawEndCode = true
                break
              }
              guard code >= 0, code < 4_096 else { return nil }

              let sequenceLength: Int
              let sequenceFirstLiteral: Int
              let sequenceContainsTransparent: Bool
              if oldCode == nil {
                guard code < clearCode, code < paletteCount else { return nil }
                sequenceLength = 1
                sequenceFirstLiteral = code
                sequenceContainsTransparent = transparentFlags[code] != 0
              } else if code < clearCode {
                guard code < paletteCount else { return nil }
                sequenceLength = 1
                sequenceFirstLiteral = code
                sequenceContainsTransparent = transparentFlags[code] != 0
              } else if code > endCode, code < nextCode {
                guard lengths[code] > 0, Int(firstLiterals[code]) < paletteCount else { return nil }
                sequenceLength = Int(lengths[code])
                sequenceFirstLiteral = Int(firstLiterals[code])
                sequenceContainsTransparent = transparentFlags[code] != 0
              } else if code == nextCode, let oldCode {
                guard lengths[oldCode] > 0, Int(firstLiterals[oldCode]) < paletteCount else {
                  return nil
                }
                sequenceLength = Int(lengths[oldCode]) + 1
                sequenceFirstLiteral = Int(firstLiterals[oldCode])
                sequenceContainsTransparent = transparentFlags[oldCode] != 0
              } else {
                return nil
              }
              usesTransparentIndex = usesTransparentIndex || sequenceContainsTransparent

              let expanded = outputCount.addingReportingOverflow(sequenceLength)
              guard !expanded.overflow, expanded.partialValue <= expectedPixelCount else {
                return nil
              }
              outputCount = expanded.partialValue

              if let oldCode, nextCode < 4_096 {
                let newLength = Int(lengths[oldCode]) + 1
                guard newLength <= UInt16.max, lengths[oldCode] > 0 else { return nil }
                lengths[nextCode] = UInt16(newLength)
                firstLiterals[nextCode] = firstLiterals[oldCode]
                transparentFlags[nextCode] =
                  transparentFlags[oldCode] != 0 || transparentIndex == sequenceFirstLiteral ? 1 : 0
                nextCode += 1
                if nextCode == (1 << codeSize), codeSize < 12 { codeSize += 1 }
              }
              oldCode = code
            }
            guard sawEndCode, outputCount == expectedPixelCount else { return nil }
            return GIFLZWValidation(usesTransparentIndex: usesTransparentIndex)
          }
        }
      }
    }
  }

  private static func decodeIndices(
    payload: Data,
    minimumCodeSize: Int,
    expectedPixelCount: Int
  ) throws -> Data {
    let clearCode = 1 << minimumCodeSize
    let endCode = clearCode + 1
    var codeSize = minimumCodeSize + 1
    var nextCode = endCode + 1
    var output = Data(count: expectedPixelCount)
    var outputCount = 0
    var oldCode: Int?
    var firstCharacter: UInt8 = 0
    var sawEndCode = false

    func resetDictionary() {
      codeSize = minimumCodeSize + 1
      nextCode = endCode + 1
      oldCode = nil
    }

    try payload.withUnsafeBytes { payloadRaw in
      var reader = GIFLSBBitReader(bytes: payloadRaw.bindMemory(to: UInt8.self))
      try output.withUnsafeMutableBytes { outputRaw in
        let destination = outputRaw.bindMemory(to: UInt8.self)
        try withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 4_096) { prefix in
          try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4_096) { suffix in
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4_096) { stack in
              while let rawCode = reader.read(bits: codeSize) {
                if rawCode == clearCode {
                  resetDictionary()
                  continue
                }
                if rawCode == endCode {
                  sawEndCode = true
                  break
                }
                guard rawCode >= 0, rawCode < 4_096 else {
                  throw ImageCraftError.decodeFailed
                }

                let inputCode = rawCode
                var code = rawCode
                if oldCode == nil {
                  guard code < clearCode else { throw ImageCraftError.decodeFailed }
                } else if code > nextCode {
                  throw ImageCraftError.decodeFailed
                }

                if code < clearCode {
                  firstCharacter = UInt8(code)
                  guard outputCount < destination.count else {
                    throw ImageCraftError.decodeFailed
                  }
                  destination[outputCount] = firstCharacter
                  outputCount += 1
                } else {
                  var stackCount = 0
                  if let oldCode, code == nextCode {
                    stack[stackCount] = firstCharacter
                    stackCount += 1
                    code = oldCode
                  } else {
                    guard code < nextCode else { throw ImageCraftError.decodeFailed }
                  }

                  while code >= clearCode {
                    guard code > endCode, code < nextCode, stackCount < stack.count else {
                      throw ImageCraftError.decodeFailed
                    }
                    stack[stackCount] = suffix[code]
                    stackCount += 1
                    code = Int(prefix[code])
                  }
                  guard code >= 0, code < clearCode, code <= UInt8.max,
                    stackCount < stack.count
                  else { throw ImageCraftError.decodeFailed }
                  firstCharacter = UInt8(code)
                  stack[stackCount] = firstCharacter
                  stackCount += 1

                  guard outputCount <= destination.count - stackCount else {
                    throw ImageCraftError.decodeFailed
                  }
                  while stackCount > 0 {
                    stackCount -= 1
                    destination[outputCount] = stack[stackCount]
                    outputCount += 1
                  }
                }

                if let oldCode, nextCode < 4_096 {
                  prefix[nextCode] = UInt16(oldCode)
                  suffix[nextCode] = firstCharacter
                  nextCode += 1
                  if nextCode == (1 << codeSize), codeSize < 12 { codeSize += 1 }
                }
                oldCode = inputCode
              }
            }
          }
        }
      }
    }

    guard sawEndCode, outputCount == expectedPixelCount else {
      throw ImageCraftError.decodeFailed
    }
    return output
  }

  private struct GIFLSBBitReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var byteOffset = 0
    var bitBuffer: UInt32 = 0
    var bufferedBitCount = 0

    mutating func read(bits count: Int) -> Int? {
      guard count > 0, count <= 12 else { return nil }
      while bufferedBitCount < count {
        guard byteOffset < bytes.count else { return nil }
        bitBuffer |= UInt32(bytes[byteOffset]) << bufferedBitCount
        bufferedBitCount += 8
        byteOffset += 1
      }
      let mask = (UInt32(1) << count) - 1
      let value = Int(bitBuffer & mask)
      bitBuffer >>= count
      bufferedBitCount -= count
      return value
    }
  }

  private static func collectSubBlocks(
    _ bytes: UnsafeBufferPointer<UInt8>,
    from initialOffset: Int
  ) throws -> (nextOffset: Int, payload: Data) {
    var offset = initialOffset
    var payload = Data()
    while true {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let length = Int(bytes[offset])
      offset += 1
      if length == 0 { return (offset, payload) }
      let end = try advancing(offset, by: length, limit: bytes.count)
      payload.append(contentsOf: bytes[offset..<end])
      offset = end
    }
  }

  private static func skipSubBlocks(
    _ bytes: UnsafeBufferPointer<UInt8>,
    from initialOffset: Int
  ) throws -> Int {
    var offset = initialOffset
    while true {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let length = Int(bytes[offset])
      offset += 1
      if length == 0 { return offset }
      offset = try advancing(offset, by: length, limit: bytes.count)
    }
  }

  private static func readUInt16LE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> Int? {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
  }

  private static func advancing(_ offset: Int, by count: Int, limit: Int) throws -> Int {
    let value = offset.addingReportingOverflow(count)
    guard count >= 0, !value.overflow, value.partialValue <= limit else {
      throw ImageCraftError.animationTimelineInvalid
    }
    return value.partialValue
  }

  private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
    let value = lhs.multipliedReportingOverflow(by: rhs)
    guard lhs >= 0, rhs >= 0, !value.overflow else {
      throw ImageCraftError.animationTimelineInvalid
    }
    return value.partialValue
  }

  private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
    let value = lhs.addingReportingOverflow(rhs)
    guard lhs >= 0, rhs >= 0, !value.overflow else {
      throw ImageCraftError.animationTimelineInvalid
    }
    return value.partialValue
  }

  private static func adding(_ values: [Int]) throws -> Int {
    try values.reduce(0) { try adding($0, $1) }
  }
}
