import Darwin
import Foundation
import ImageCraftCore

struct EncodedImageSecurityInspection: Sendable {
    let format: EncodedImageFormat
    let metadataByteCount: Int
    let sourceColorProfile: SourceColorProfile
    let embeddedICCProfile: Data?
}

/// 在调用 ImageIO 前扫描容器结构，限制元数据、帧和尾随载荷。
/// 检查器只接受能够完整证明终止标记与长度边界的 PNG/JPEG/GIF 数据。
enum EncodedImageSecurityInspector {
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let jpegSignature: [UInt8] = [0xFF, 0xD8]
    private static let gif87aSignature = Array("GIF87a".utf8)
    private static let gif89aSignature = Array("GIF89a".utf8)
    private static let jpegICCSignature = Array("ICC_PROFILE\u{0}".utf8)

    private static let pngIEND: UInt32 = 0x4945_4E44
    private static let pngICCP: UInt32 = 0x6943_4350
    private static let pngEXIF: UInt32 = 0x6558_4966
    private static let pngITXT: UInt32 = 0x6954_5874
    private static let pngTEXT: UInt32 = 0x7445_5874
    private static let pngZTXT: UInt32 = 0x7A54_5874
    private static let pngSRGB: UInt32 = 0x7352_4742

    static func inspect(
        _ data: Data,
        maximumMetadataBytes: Int
    ) throws -> EncodedImageSecurityInspection {
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            if hasPrefix(bytes, pngSignature) {
                return try inspectPNG(bytes, maximumMetadataBytes: maximumMetadataBytes)
            }
            if hasPrefix(bytes, jpegSignature) {
                return try inspectJPEG(bytes, maximumMetadataBytes: maximumMetadataBytes)
            }
            if hasPrefix(bytes, gif87aSignature) || hasPrefix(bytes, gif89aSignature) {
                return try inspectGIF(bytes, maximumMetadataBytes: maximumMetadataBytes)
            }
            throw ImageCraftError.unsupportedFormat
        }
    }

    private static func inspectPNG(
        _ bytes: UnsafeBufferPointer<UInt8>,
        maximumMetadataBytes: Int
    ) throws -> EncodedImageSecurityInspection {
        var offset = pngSignature.count
        var metadataBytes = 0
        var sourceColorProfile = SourceColorProfile.absent
        var foundEnd = false

        while offset < bytes.count {
            guard let length = readUInt32BE(bytes, at: offset),
                let type = readUInt32BE(bytes, at: offset + 4)
            else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            let payloadLength = Int(length)
            let chunkSpan = payloadLength.addingReportingOverflow(12)
            guard !chunkSpan.overflow else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            let chunkEnd = offset.addingReportingOverflow(chunkSpan.partialValue)
            guard !chunkEnd.overflow, chunkEnd.partialValue <= bytes.count else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }

            switch type {
            case pngICCP, pngEXIF, pngITXT, pngTEXT, pngZTXT:
                metadataBytes = try adding(metadataBytes, payloadLength)
                guard metadataBytes <= maximumMetadataBytes else {
                    throw ImageCraftError.metadataLimitExceeded
                }
            default:
                break
            }
            if type == pngICCP {
                sourceColorProfile = .embeddedICC
            } else if type == pngSRGB, sourceColorProfile == .absent {
                sourceColorProfile = .standardSRGB
            }

            offset = chunkEnd.partialValue
            if type == pngIEND {
                foundEnd = true
                break
            }
        }
        guard foundEnd, offset == bytes.count else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return EncodedImageSecurityInspection(
            format: .png,
            metadataByteCount: metadataBytes,
            sourceColorProfile: sourceColorProfile,
            embeddedICCProfile: nil
        )
    }

    private struct JPEGInspectionState {
        var offset: Int
        var metadataBytes = 0
        var sourceColorProfile = SourceColorProfile.absent
        var iccChunkCount: Int?
        var iccChunkRanges: [Int: Range<Int>] = [:]
        var isInsideScan = false
        var foundEnd = false
    }

    private static func inspectJPEG(
        _ bytes: UnsafeBufferPointer<UInt8>,
        maximumMetadataBytes: Int
    ) throws -> EncodedImageSecurityInspection {
        var state = JPEGInspectionState(offset: jpegSignature.count)
        while state.offset < bytes.count {
            let marker = try consumeJPEGMarker(bytes, state: &state)
            if marker == 0xD9 {
                state.foundEnd = true
                break
            }
            try validateJPEGStandaloneMarker(marker)
            if marker == 0x01 { continue }
            let segmentEnd = try jpegSegmentEnd(bytes, offset: state.offset)
            try inspectJPEGSegment(
                marker: marker,
                bytes: bytes,
                segmentEnd: segmentEnd,
                maximumMetadataBytes: maximumMetadataBytes,
                state: &state
            )
            state.offset = segmentEnd
            state.isInsideScan = marker == 0xDA
        }
        guard state.foundEnd, state.offset == bytes.count else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return EncodedImageSecurityInspection(
            format: .jpeg,
            metadataByteCount: state.metadataBytes,
            sourceColorProfile: state.sourceColorProfile,
            embeddedICCProfile: try assembledJPEGICCProfile(
                bytes,
                chunkCount: state.iccChunkCount,
                chunkRanges: state.iccChunkRanges,
                maximumMetadataBytes: maximumMetadataBytes
            )
        )
    }

    private static func consumeJPEGMarker(
        _ bytes: UnsafeBufferPointer<UInt8>,
        state: inout JPEGInspectionState
    ) throws -> UInt8 {
        let next =
            try state.isInsideScan
            ? nextJPEGMarkerInScan(bytes, from: state.offset)
            : nextJPEGMarker(bytes, from: state.offset)
        state.offset = next.nextOffset
        state.isInsideScan = false
        return next.marker
    }

    private static func validateJPEGStandaloneMarker(_ marker: UInt8) throws {
        guard marker != 0xD8, !(0xD0...0xD7).contains(marker) else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
    }

    private static func jpegSegmentEnd(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: Int
    ) throws -> Int {
        guard let rawLength = readUInt16BE(bytes, at: offset), rawLength >= 2 else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let end = offset.addingReportingOverflow(Int(rawLength))
        guard !end.overflow, end.partialValue <= bytes.count else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return end.partialValue
    }

    private static func inspectJPEGSegment(
        marker: UInt8,
        bytes: UnsafeBufferPointer<UInt8>,
        segmentEnd: Int,
        maximumMetadataBytes: Int,
        state: inout JPEGInspectionState
    ) throws {
        let payloadLength = segmentEnd - state.offset - 2
        if (0xE0...0xEF).contains(marker) || marker == 0xFE {
            state.metadataBytes = try adding(state.metadataBytes, payloadLength)
            guard state.metadataBytes <= maximumMetadataBytes else {
                throw ImageCraftError.metadataLimitExceeded
            }
        }
        guard marker == 0xE2 else { return }
        try recordJPEGICCChunk(
            bytes,
            payloadStart: state.offset + 2,
            segmentEnd: segmentEnd,
            state: &state
        )
    }

    private static func recordJPEGICCChunk(
        _ bytes: UnsafeBufferPointer<UInt8>,
        payloadStart: Int,
        segmentEnd: Int,
        state: inout JPEGInspectionState
    ) throws {
        guard hasPrefix(bytes, jpegICCSignature, at: payloadStart, limit: segmentEnd) else {
            return
        }
        let signatureEnd = payloadStart + jpegICCSignature.count
        let headerEnd = signatureEnd.addingReportingOverflow(2)
        guard !headerEnd.overflow, headerEnd.partialValue <= segmentEnd else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let sequence = Int(bytes[signatureEnd])
        let count = Int(bytes[signatureEnd + 1])
        guard count > 0, sequence > 0, sequence <= count else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        if let existingCount = state.iccChunkCount {
            guard existingCount == count else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
        } else {
            state.iccChunkCount = count
        }
        guard state.iccChunkRanges[sequence] == nil else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        state.iccChunkRanges[sequence] = headerEnd.partialValue..<segmentEnd
        state.sourceColorProfile = .embeddedICC
    }

    private static func assembledJPEGICCProfile(
        _ bytes: UnsafeBufferPointer<UInt8>,
        chunkCount: Int?,
        chunkRanges: [Int: Range<Int>],
        maximumMetadataBytes: Int
    ) throws -> Data? {
        guard let count = chunkCount else { return nil }
        guard chunkRanges.count == count else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let ranges = try orderedJPEGICCRanges(count: count, chunkRanges: chunkRanges)
        var totalBytes = 0
        for range in ranges {
            totalBytes = try adding(totalBytes, range.count)
            guard totalBytes <= maximumMetadataBytes else {
                throw ImageCraftError.metadataLimitExceeded
            }
        }
        guard totalBytes > 0 else { throw ImageCraftError.metadataLimitExceeded }
        var profile = Data()
        profile.reserveCapacity(totalBytes)
        for range in ranges { profile.append(contentsOf: bytes[range]) }
        return profile
    }

    private static func orderedJPEGICCRanges(
        count: Int,
        chunkRanges: [Int: Range<Int>]
    ) throws -> [Range<Int>] {
        try (1...count).map { sequence in
            guard let range = chunkRanges[sequence] else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            return range
        }
    }

    private static func nextJPEGMarker(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from initialOffset: Int
    ) throws -> (marker: UInt8, nextOffset: Int) {
        var offset = initialOffset
        guard offset < bytes.count, bytes[offset] == 0xFF else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
        guard offset < bytes.count, bytes[offset] != 0x00 else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return (bytes[offset], offset + 1)
    }

    private static func nextJPEGMarkerInScan(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from initialOffset: Int
    ) throws -> (marker: UInt8, nextOffset: Int) {
        guard let baseAddress = bytes.baseAddress else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        var offset = initialOffset
        while offset < bytes.count {
            let remaining = bytes.count - offset
            guard
                let markerAddress = Darwin.memchr(
                    baseAddress.advanced(by: offset),
                    Int32(0xFF),
                    remaining
                )
            else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            offset = baseAddress.distance(
                to: UnsafeRawPointer(markerAddress).assumingMemoryBound(to: UInt8.self)
            )
            while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
            guard offset < bytes.count else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            let marker = bytes[offset]
            offset += 1
            if marker == 0x00 || (0xD0...0xD7).contains(marker) { continue }
            return (marker, offset)
        }
        throw ImageCraftError.unsupportedOrCorruptImage
    }

    private static func inspectGIF(
        _ bytes: UnsafeBufferPointer<UInt8>,
        maximumMetadataBytes: Int
    ) throws -> EncodedImageSecurityInspection {
        guard bytes.count >= 13 else { throw ImageCraftError.unsupportedOrCorruptImage }
        var offset = 13
        let packed = bytes[10]
        if packed & 0x80 != 0 {
            let tableSize = 3 * (1 << (Int(packed & 0x07) + 1))
            offset = try advancing(offset, by: tableSize, limit: bytes.count)
        }
        var metadataBytes = 0
        while offset < bytes.count {
            let marker = bytes[offset]
            offset += 1
            switch marker {
            case 0x3B:
                guard offset == bytes.count else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                return EncodedImageSecurityInspection(
                    format: .gif,
                    metadataByteCount: metadataBytes,
                    sourceColorProfile: .absent,
                    embeddedICCProfile: nil
                )
            case 0x21:
                guard offset < bytes.count else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                offset += 1
                let result = try skipSubBlocks(bytes, from: offset)
                metadataBytes = try adding(metadataBytes, result.payloadBytes)
                guard metadataBytes <= maximumMetadataBytes else {
                    throw ImageCraftError.metadataLimitExceeded
                }
                offset = result.nextOffset
            case 0x2C:
                offset = try advancing(offset, by: 9, limit: bytes.count)
                let localPacked = bytes[offset - 1]
                if localPacked & 0x80 != 0 {
                    let tableSize = 3 * (1 << (Int(localPacked & 0x07) + 1))
                    offset = try advancing(offset, by: tableSize, limit: bytes.count)
                }
                offset = try advancing(offset, by: 1, limit: bytes.count)
                offset = try skipSubBlocks(bytes, from: offset).nextOffset
            default:
                throw ImageCraftError.unsupportedOrCorruptImage
            }
        }
        throw ImageCraftError.unsupportedOrCorruptImage
    }

    private static func skipSubBlocks(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from initialOffset: Int
    ) throws -> (nextOffset: Int, payloadBytes: Int) {
        var offset = initialOffset
        var payloadBytes = 0
        while true {
            guard offset < bytes.count else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 { return (offset, payloadBytes) }
            offset = try advancing(offset, by: length, limit: bytes.count)
            payloadBytes = try adding(payloadBytes, length)
        }
    }

    private static func hasPrefix(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ prefix: [UInt8],
        at offset: Int = 0,
        limit: Int? = nil
    ) -> Bool {
        guard offset >= 0 else { return false }
        let upperBound = limit ?? bytes.count
        let end = offset.addingReportingOverflow(prefix.count)
        guard !end.overflow, end.partialValue <= upperBound, upperBound <= bytes.count else {
            return false
        }
        for index in prefix.indices where bytes[offset + index] != prefix[index] {
            return false
        }
        return true
    }

    private static func readUInt16BE(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32BE(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ImageCraftError.metadataLimitExceeded }
        return result.partialValue
    }

    private static func advancing(_ offset: Int, by count: Int, limit: Int) throws -> Int {
        let result = offset.addingReportingOverflow(count)
        guard !result.overflow, result.partialValue <= limit else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return result.partialValue
    }
}
