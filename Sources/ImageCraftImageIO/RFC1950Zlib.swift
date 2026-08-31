import Compression
import Foundation

enum RFC1950ZlibError: Error, Equatable, Sendable {
  case compressionFailed
  case decompressionFailed
  case outputLimitExceeded
}

enum ImageCraftCRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
    }
    return crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    checksum(data, from: 0, to: data.count) ?? 0
  }

  static func checksum(
    _ data: Data,
    from lowerBound: Int,
    to upperBound: Int
  ) -> UInt32? {
    guard lowerBound >= 0,
      upperBound >= lowerBound,
      upperBound <= data.count
    else { return nil }
    var crc = UInt32.max
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var offset = lowerBound
      while offset < upperBound {
        let index = Int((crc ^ UInt32(bytes[offset])) & 0xFF)
        crc = table[index] ^ (crc >> 8)
        offset += 1
      }
    }
    return crc ^ UInt32.max
  }
}

package enum RFC1950Zlib {
  package static func deflate(_ source: Data) throws -> Data {
    var capacity = max(64, source.count + source.count / 8 + 65_536)
    for _ in 0..<4 {
      var rawDeflate = Data(count: capacity)
      let written = rawDeflate.withUnsafeMutableBytes { output in
        source.withUnsafeBytes { input in
          guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
            let inputBase = input.bindMemory(to: UInt8.self).baseAddress
          else { return 0 }
          return compression_encode_buffer(
            outputBase,
            capacity,
            inputBase,
            source.count,
            nil,
            COMPRESSION_ZLIB
          )
        }
      }
      if written > 0 {
        rawDeflate.removeSubrange(written..<rawDeflate.count)
        var zlib = Data([0x78, 0xDA])
        zlib.reserveCapacity(rawDeflate.count + 6)
        zlib.append(rawDeflate)
        appendUInt32BE(adler32(source), to: &zlib)
        return zlib
      }
      let doubled = capacity.multipliedReportingOverflow(by: 2)
      guard !doubled.overflow else { throw RFC1950ZlibError.compressionFailed }
      capacity = doubled.partialValue
    }
    throw RFC1950ZlibError.compressionFailed
  }

  package static func inflate(
    _ source: Data,
    expectedByteCount: Int
  ) throws -> Data {
    guard expectedByteCount > 0, source.count >= 6 else {
      throw RFC1950ZlibError.decompressionFailed
    }
    let compressionMethod = source[0]
    let flags = source[1]
    let header = Int(compressionMethod) * 256 + Int(flags)
    guard compressionMethod & 0x0F == 8,
      compressionMethod >> 4 <= 7,
      header % 31 == 0,
      flags & 0x20 == 0,
      let expectedAdler = readUInt32BE(source, at: source.count - 4)
    else { throw RFC1950ZlibError.decompressionFailed }

    let rawDeflateByteCount = source.count - 6
    var destination = Data(count: expectedByteCount)
    let written = destination.withUnsafeMutableBytes { output in
      source.withUnsafeBytes { input in
        guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
          let inputBase = input.bindMemory(to: UInt8.self).baseAddress
        else { return 0 }
        return compression_decode_buffer(
          outputBase,
          expectedByteCount,
          inputBase.advanced(by: 2),
          rawDeflateByteCount,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    guard written == expectedByteCount,
      adler32(destination) == expectedAdler
    else { throw RFC1950ZlibError.decompressionFailed }
    return destination
  }

  /// Decode an RFC1950 stream when the uncompressed byte count is not encoded by the container.
  /// The caller supplies a hard output ceiling; reaching that ceiling without observing stream end
  /// is a resource-limit failure rather than a corrupt-stream failure.
  package static func inflate(
    _ source: Data,
    maximumByteCount: Int
  ) throws -> Data {
    guard maximumByteCount > 0, source.count >= 6 else {
      throw RFC1950ZlibError.decompressionFailed
    }
    let compressionMethod = source[0]
    let flags = source[1]
    let header = Int(compressionMethod) * 256 + Int(flags)
    guard compressionMethod & 0x0F == 8,
      compressionMethod >> 4 <= 7,
      header % 31 == 0,
      flags & 0x20 == 0,
      let expectedAdler = readUInt32BE(source, at: source.count - 4)
    else { throw RFC1950ZlibError.decompressionFailed }

    let rawDeflateByteCount = source.count - 6
    let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { dummy.deallocate() }
    var stream = compression_stream(
      dst_ptr: dummy,
      dst_size: 0,
      src_ptr: UnsafePointer(dummy),
      src_size: 0,
      state: nil
    )
    guard compression_stream_init(
      &stream,
      COMPRESSION_STREAM_DECODE,
      COMPRESSION_ZLIB
    ) == COMPRESSION_STATUS_OK else {
      throw RFC1950ZlibError.decompressionFailed
    }
    defer { compression_stream_destroy(&stream) }

    return try source.withUnsafeBytes { inputRaw in
      guard let inputBase = inputRaw.bindMemory(to: UInt8.self).baseAddress else {
        throw RFC1950ZlibError.decompressionFailed
      }
      stream.src_ptr = inputBase.advanced(by: 2)
      stream.src_size = rawDeflateByteCount
      let chunkByteCount = min(64 * 1_024, maximumByteCount)
      var chunk = Data(count: chunkByteCount)
      var output = Data()
      output.reserveCapacity(min(maximumByteCount, max(64, source.count * 2)))

      while true {
        let status = chunk.withUnsafeMutableBytes { outputRaw -> compression_status in
          guard let outputBase = outputRaw.bindMemory(to: UInt8.self).baseAddress else {
            return COMPRESSION_STATUS_ERROR
          }
          stream.dst_ptr = outputBase
          stream.dst_size = chunkByteCount
          return compression_stream_process(
            &stream,
            Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
          )
        }
        let produced = chunkByteCount - stream.dst_size
        if produced > 0 {
          let nextCount = output.count.addingReportingOverflow(produced)
          guard !nextCount.overflow, nextCount.partialValue <= maximumByteCount else {
            throw RFC1950ZlibError.outputLimitExceeded
          }
          output.append(chunk.prefix(produced))
        }
        switch status {
        case COMPRESSION_STATUS_END:
          guard stream.src_size == 0,
            !output.isEmpty,
            adler32(output) == expectedAdler
          else { throw RFC1950ZlibError.decompressionFailed }
          return output
        case COMPRESSION_STATUS_OK:
          guard produced > 0 || stream.src_size > 0 else {
            throw RFC1950ZlibError.decompressionFailed
          }
          if output.count == maximumByteCount {
            throw RFC1950ZlibError.outputLimitExceeded
          }
        default:
          throw RFC1950ZlibError.decompressionFailed
        }
      }
    }
  }

  private static func adler32(_ data: Data) -> UInt32 {
    // RFC 1950 permits reducing modulo 65521 in blocks. Keeping the accumulators
    // wide and reducing once per zlib NMAX block avoids two integer divisions for
    // every decoded byte while preserving the exact checksum.
    let modulus = UInt64(65_521)
    let maximumUnreducedBytes = 5_552
    var first = UInt64(1)
    var second = UInt64(0)
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var offset = 0
      while offset < bytes.count {
        let end = min(bytes.count, offset + maximumUnreducedBytes)
        while offset < end {
          first += UInt64(bytes[offset])
          second += first
          offset += 1
        }
        first %= modulus
        second %= modulus
      }
    }
    return UInt32((second << 16) | first)
  }

  private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }
}
