import Foundation

/// Shared PNG chunk CRC implementation for static and animated container validation.
///
/// PNG CRC covers the four type bytes followed by the chunk payload. Range validation is kept in
/// this helper so malformed container offsets fail closed instead of reaching unchecked indexing.
enum PNGCRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
    }
    return crc
  }

  static func checksum(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    count: Int
  ) -> UInt32? {
    guard start >= 0, count >= 0 else { return nil }
    let end = start.addingReportingOverflow(count)
    guard !end.overflow, end.partialValue <= bytes.count else { return nil }
    var crc = UInt32.max
    for index in start..<end.partialValue {
      let tableIndex = Int((crc ^ UInt32(bytes[index])) & 0xFF)
      crc = table[tableIndex] ^ (crc >> 8)
    }
    return crc ^ UInt32.max
  }

  static func checksum(_ data: Data, start: Int, count: Int) -> UInt32? {
    data.withUnsafeBytes { raw in
      checksum(raw.bindMemory(to: UInt8.self), start: start, count: count)
    }
  }
}
