import Darwin
import Foundation
import ImageCraftCore

/// Borrowing cursor over one security-validated contiguous PNG IDAT run.
///
/// The encoded PNG remains caller-owned. This cursor advances through IDAT payload ranges without
/// concatenating the compressed zlib body into another `Data` value.
struct PNGValidatedIDATByteCursor: RFC1950StreamingByteCursor {
  let sourceBase: UnsafePointer<UInt8>
  let sourceByteCount: Int
  let runEndOffset: Int
  var nextChunkOffset: Int
  var payloadOffset = 0
  var payloadEndOffset = 0
  private(set) var remainingByteCount: Int

  init(
    sourceBase: UnsafePointer<UInt8>,
    sourceByteCount: Int,
    firstChunkOffset: Int,
    runEndOffset: Int,
    compressedByteCount: Int
  ) throws {
    guard sourceByteCount >= 0,
      firstChunkOffset >= 8,
      runEndOffset > firstChunkOffset,
      runEndOffset <= sourceByteCount,
      compressedByteCount >= 6
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    self.sourceBase = sourceBase
    self.sourceByteCount = sourceByteCount
    self.runEndOffset = runEndOffset
    self.nextChunkOffset = firstChunkOffset
    self.remainingByteCount = compressedByteCount
    guard loadNextChunk() else { throw ImageCraftError.unsupportedOrCorruptImage }
  }

  mutating func readByte() -> UInt8? {
    guard remainingByteCount > 0 else { return nil }
    while payloadOffset == payloadEndOffset {
      guard loadNextChunk() else { return nil }
    }
    guard payloadOffset < payloadEndOffset else { return nil }
    let byte = sourceBase[payloadOffset]
    payloadOffset += 1
    remainingByteCount -= 1
    return byte
  }

  mutating func read(into destination: UnsafeMutableBufferPointer<UInt8>) -> Int {
    guard remainingByteCount > 0,
      destination.count > 0,
      let destinationBase = destination.baseAddress
    else { return 0 }
    var written = 0
    while written < destination.count, remainingByteCount > 0 {
      while payloadOffset == payloadEndOffset {
        guard loadNextChunk() else { return written }
      }
      let available = payloadEndOffset - payloadOffset
      guard available > 0 else { return written }
      let copied = min(destination.count - written, available, remainingByteCount)
      memmove(
        destinationBase.advanced(by: written),
        sourceBase.advanced(by: payloadOffset),
        copied
      )
      payloadOffset += copied
      remainingByteCount -= copied
      written += copied
    }
    return written
  }

  private mutating func loadNextChunk() -> Bool {
    let chunkOffset = nextChunkOffset
    let headerEnd = chunkOffset.addingReportingOverflow(8)
    guard !headerEnd.overflow,
      headerEnd.partialValue <= runEndOffset,
      headerEnd.partialValue <= sourceByteCount
    else { return false }
    let payloadLength = Int(
      UInt32(sourceBase[chunkOffset]) << 24
        | UInt32(sourceBase[chunkOffset + 1]) << 16
        | UInt32(sourceBase[chunkOffset + 2]) << 8
        | UInt32(sourceBase[chunkOffset + 3])
    )
    guard sourceBase[chunkOffset + 4] == 0x49,
      sourceBase[chunkOffset + 5] == 0x44,
      sourceBase[chunkOffset + 6] == 0x41,
      sourceBase[chunkOffset + 7] == 0x54
    else { return false }
    let payloadStart = headerEnd.partialValue
    let payloadEnd = payloadStart.addingReportingOverflow(payloadLength)
    guard !payloadEnd.overflow else { return false }
    let chunkEnd = payloadEnd.partialValue.addingReportingOverflow(4)
    guard !chunkEnd.overflow,
      chunkEnd.partialValue <= runEndOffset,
      chunkEnd.partialValue <= sourceByteCount
    else { return false }
    payloadOffset = payloadStart
    payloadEndOffset = payloadEnd.partialValue
    nextChunkOffset = chunkEnd.partialValue
    return true
  }
}
