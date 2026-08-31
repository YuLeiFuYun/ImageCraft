import Darwin
import Foundation
import ImageCraftCore

struct PNGValidatedContainerFacts: Sendable {
    struct Header: Sendable {
        let width: Int
        let height: Int
        let bitDepth: UInt8
        let colorType: UInt8
        let compressionMethod: UInt8
        let filterMethod: UInt8
        let interlaceMethod: UInt8
    }

    struct TruecolorTransparency: Sendable, Equatable {
        let red: UInt16
        let green: UInt16
        let blue: UInt16
    }

    enum SignificantBits: Sendable, Equatable {
        case grayscale(gray: UInt8)
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
        case grayscaleAlpha(gray: UInt8, alpha: UInt8)
        case rgba(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    }

    struct CICP: Sendable, Equatable {
        let colorPrimaries: UInt8
        let transferFunction: UInt8
        let matrixCoefficients: UInt8
        let videoFullRangeFlag: UInt8
    }

    struct MasteringDisplayColorVolume: Sendable, Equatable {
        let redX: UInt16
        let redY: UInt16
        let greenX: UInt16
        let greenY: UInt16
        let blueX: UInt16
        let blueY: UInt16
        let whiteX: UInt16
        let whiteY: UInt16
        let maximumLuminanceScaledBy10000: UInt32
        let minimumLuminanceScaledBy10000: UInt32
    }

    struct ContentLightLevel: Sendable, Equatable {
        let maximumContentLightLevelScaledBy10000: UInt32
        let maximumFrameAverageLightLevelScaledBy10000: UInt32
    }

    let header: Header?
    let ihdrCount: Int
    let ihdrWasFirst: Bool
    let allChunkTypeBytesAreLetters: Bool
    let allChunkReservedBitsAreZero: Bool
    let prePaletteAndIDATChunksAreOrdered: Bool
    let knownPreIDATChunksAreOrdered: Bool
    let firstIDATChunkOffset: Int?
    let idatRunEndOffset: Int?
    let compressedIDATByteCount: Int
    let idatRunIsContiguous: Bool
    let embeddedICCCompressedRange: Range<Int>?
    let iendPayloadLength: Int?
    let hasGamma: Bool
    let hasChromaticities: Bool
    let significantBits: SignificantBits?
    var hasSignificantBits: Bool { significantBits != nil }
    let hasPalette: Bool
    let palettePayloadRange: Range<Int>?
    let hasTransparency: Bool
    let indexedTransparencyPayloadRange: Range<Int>?
    let grayscaleTransparency: UInt16?
    let truecolorTransparency: TruecolorTransparency?
    let hasEXIF: Bool
    let cicp: CICP?
    var hasCICP: Bool { cicp != nil }
    let masteringDisplayColorVolume: MasteringDisplayColorVolume?
    let contentLightLevel: ContentLightLevel?
    var hasHDRMetadata: Bool {
        masteringDisplayColorVolume != nil || contentLightLevel != nil
    }
    let hasAnimationChunks: Bool
    let hasUnknownCriticalChunk: Bool
}

struct EncodedImageSecurityInspection: Sendable {
    let format: EncodedImageFormat
    let metadataByteCount: Int
    let sourceColorProfile: SourceColorProfile
    let embeddedICCProfile: Data?
    /// Exact uncompressed ICC payload bytes when the container syntax itself proves the value
    /// without requiring profile materialization. JPEG APP2 chunking has this property; PNG iCCP
    /// does not when materialization/inflate is intentionally disabled.
    let embeddedICCProfileByteCount: Int?
    let pngContainerFacts: PNGValidatedContainerFacts?

    init(
        format: EncodedImageFormat,
        metadataByteCount: Int,
        sourceColorProfile: SourceColorProfile,
        embeddedICCProfile: Data?,
        embeddedICCProfileByteCount: Int? = nil,
        pngContainerFacts: PNGValidatedContainerFacts? = nil
    ) {
        self.format = format
        self.metadataByteCount = metadataByteCount
        self.sourceColorProfile = sourceColorProfile
        self.embeddedICCProfile = embeddedICCProfile
        self.embeddedICCProfileByteCount =
            embeddedICCProfileByteCount ?? embeddedICCProfile?.count
        self.pngContainerFacts = pngContainerFacts
    }
}

/// 在调用 ImageIO 前扫描容器结构，限制元数据、帧和尾随载荷。
/// 检查器只接受能够完整证明终止标记与长度边界的 PNG/JPEG/GIF 数据。
enum EncodedImageSecurityInspector {
    // libjpeg-turbo's security-oriented scan limiter historically used 500 as the
    // "unreasonably large" progressive-JPEG threshold. Keep this package-internal
    // so the bound protects every ImageIO entry point without pretending that scan
    // count is a stable public DecodeLimits dimension.
    static let maximumJPEGScanCount = 500

    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let jpegSignature: [UInt8] = [0xFF, 0xD8]
    private static let gif87aSignature = Array("GIF87a".utf8)
    private static let gif89aSignature = Array("GIF89a".utf8)
    private static let jpegICCSignature = Array("ICC_PROFILE\u{0}".utf8)

    private static let pngIEND: UInt32 = 0x4945_4E44
    private static let pngIHDR: UInt32 = 0x4948_4452
    private static let pngIDAT: UInt32 = 0x4944_4154
    private static let pngPLTE: UInt32 = 0x504C_5445
    private static let pngHIST: UInt32 = 0x6849_5354
    private static let pngTRNS: UInt32 = 0x7452_4E53
    private static let pngICCP: UInt32 = 0x6943_4350
    private static let pngSBIT: UInt32 = 0x7342_4954
    private static let pngEXIF: UInt32 = 0x6558_4966
    private static let pngITXT: UInt32 = 0x6954_5874
    private static let pngTEXT: UInt32 = 0x7445_5874
    private static let pngZTXT: UInt32 = 0x7A54_5874
    private static let pngSRGB: UInt32 = 0x7352_4742
    private static let pngGAMA: UInt32 = 0x6741_4D41
    private static let pngCHRM: UInt32 = 0x6348_524D
    private static let pngCICP: UInt32 = 0x6349_4350
    private static let pngMDCV: UInt32 = 0x6D44_4356
    private static let pngCLLI: UInt32 = 0x634C_4C49
    private static let pngACTL: UInt32 = 0x6163_544C
    private static let pngFCTL: UInt32 = 0x6663_544C
    private static let pngFDAT: UInt32 = 0x6664_4154

    static func inspect(
        _ data: Data,
        maximumMetadataBytes: Int,
        materializePNGICCProfile: Bool = true,
        materializeJPEGICCProfile: Bool = true
    ) throws -> EncodedImageSecurityInspection {
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            if hasPrefix(bytes, pngSignature) {
                return try inspectPNG(
                    bytes,
                    maximumMetadataBytes: maximumMetadataBytes,
                    materializeICCProfile: materializePNGICCProfile
                )
            }
            if hasPrefix(bytes, jpegSignature) {
                return try inspectJPEG(
                    bytes,
                    maximumMetadataBytes: maximumMetadataBytes,
                    materializeICCProfile: materializeJPEGICCProfile
                )
            }
            if hasPrefix(bytes, gif87aSignature) || hasPrefix(bytes, gif89aSignature) {
                return try inspectGIF(bytes, maximumMetadataBytes: maximumMetadataBytes)
            }
            throw ImageCraftError.unsupportedFormat
        }
    }

    private static func inspectPNG(
        _ bytes: UnsafeBufferPointer<UInt8>,
        maximumMetadataBytes: Int,
        materializeICCProfile: Bool
    ) throws -> EncodedImageSecurityInspection {
        var offset = pngSignature.count
        var metadataBytes = 0
        var sourceColorProfile = SourceColorProfile.absent
        var embeddedICCProfile: Data?
        var embeddedICCCompressedRange: Range<Int>?
        var foundICCP = false
        var foundSRGB = false
        var foundEnd = false
        var chunkIndex = 0
        var header: PNGValidatedContainerFacts.Header?
        var ihdrCount = 0
        var ihdrWasFirst = false
        var allChunkTypeBytesAreLetters = true
        var allChunkReservedBitsAreZero = true
        var prePaletteAndIDATChunksAreOrdered = true
        var knownPreIDATChunksAreOrdered = true
        var sawPLTE = false
        var firstIDATChunkOffset: Int?
        var idatRunEndOffset: Int?
        var compressedIDATByteCount = 0
        var sawIDAT = false
        var closedIDATRun = false
        var idatRunIsContiguous = true
        var iendPayloadLength: Int?
        var hasGamma = false
        var hasChromaticities = false
        var hasPalette = false
        var paletteEntryCount: Int?
        var palettePayloadRange: Range<Int>?
        var foundHIST = false
        var hasTransparency = false
        var indexedTransparencyPayloadRange: Range<Int>?
        var grayscaleTransparency: UInt16?
        var truecolorTransparency: PNGValidatedContainerFacts.TruecolorTransparency?
        var hasEXIF = false
        var cicp: PNGValidatedContainerFacts.CICP?
        var masteringDisplayColorVolume: PNGValidatedContainerFacts.MasteringDisplayColorVolume?
        var contentLightLevel: PNGValidatedContainerFacts.ContentLightLevel?
        var significantBits: PNGValidatedContainerFacts.SignificantBits?
        var hasAnimationChunks = false
        var hasUnknownCriticalChunk = false

        while offset < bytes.count {
            guard let length = readUInt32BE(bytes, at: offset),
                let type = readUInt32BE(bytes, at: offset + 4)
            else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            guard length <= 0x7FFF_FFFF else {
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
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + payloadLength
            guard let storedCRC = readUInt32BE(bytes, at: payloadEnd),
                let computedCRC = PNGCRC32.checksum(
                    bytes,
                    start: offset + 4,
                    count: 4 + payloadLength
                ),
                storedCRC == computedCRC
            else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }

            for typeOffset in (offset + 4)..<(offset + 8) {
                let byte = bytes[typeOffset]
                if !((65...90).contains(byte) || (97...122).contains(byte)) {
                    allChunkTypeBytesAreLetters = false
                }
            }
            guard allChunkTypeBytesAreLetters else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            if bytes[offset + 6] & 0x20 != 0 {
                allChunkReservedBitsAreZero = false
            }
            switch type {
            case pngCHRM, pngCICP, pngGAMA, pngICCP, pngMDCV, pngCLLI, pngSBIT, pngSRGB:
                if sawPLTE || sawIDAT {
                    prePaletteAndIDATChunksAreOrdered = false
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
            case pngEXIF, pngACTL:
                if sawIDAT {
                    knownPreIDATChunksAreOrdered = false
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
            default:
                break
            }
            if chunkIndex == 0, type != pngIHDR {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            if type == pngPLTE { sawPLTE = true }
            if type == pngIHDR {
                guard ihdrCount == 0,
                    chunkIndex == 0,
                    payloadLength == 13,
                    let rawWidth = readUInt32BE(bytes, at: payloadStart),
                    let rawHeight = readUInt32BE(bytes, at: payloadStart + 4)
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                let candidate = PNGValidatedContainerFacts.Header(
                    width: Int(rawWidth),
                    height: Int(rawHeight),
                    bitDepth: bytes[payloadStart + 8],
                    colorType: bytes[payloadStart + 9],
                    compressionMethod: bytes[payloadStart + 10],
                    filterMethod: bytes[payloadStart + 11],
                    interlaceMethod: bytes[payloadStart + 12]
                )
                guard isValidPNGHeader(candidate) else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                ihdrCount = 1
                ihdrWasFirst = true
                header = candidate
            }

            if type == pngIDAT {
                if closedIDATRun {
                    idatRunIsContiguous = false
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                if firstIDATChunkOffset == nil { firstIDATChunkOffset = offset }
                let compressedTotal = compressedIDATByteCount.addingReportingOverflow(payloadLength)
                guard !compressedTotal.overflow else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                compressedIDATByteCount = compressedTotal.partialValue
                idatRunEndOffset = chunkEnd.partialValue
                sawIDAT = true
            } else if sawIDAT {
                closedIDATRun = true
            }

            if type == pngIEND, payloadLength != 0 {
                throw ImageCraftError.unsupportedOrCorruptImage
            }

            switch type {
            case pngGAMA:
                guard !hasGamma,
                    payloadLength == 4,
                    let encodedGamma = readUInt32BE(bytes, at: payloadStart),
                    encodedGamma != 0
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                hasGamma = true
            case pngCHRM:
                guard !hasChromaticities, payloadLength == 32 else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                hasChromaticities = true
            case pngPLTE:
                guard !hasPalette,
                    !hasTransparency,
                    !sawIDAT,
                    payloadLength >= 3,
                    payloadLength <= 768,
                    payloadLength.isMultiple(of: 3)
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                hasPalette = true
                paletteEntryCount = payloadLength / 3
                palettePayloadRange = payloadStart..<payloadEnd
            case pngHIST:
                guard !foundHIST,
                    hasPalette,
                    !sawIDAT,
                    let paletteEntryCount,
                    payloadLength == paletteEntryCount * 2
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                foundHIST = true
            case pngTRNS:
                guard !hasTransparency,
                    !sawIDAT,
                    let header,
                    isValidPNGTransparency(
                        payloadLength: payloadLength,
                        header: header,
                        hasPalette: hasPalette,
                        paletteEntryCount: paletteEntryCount
                    )
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                hasTransparency = true
                if header.colorType == 0 {
                    guard let gray = readUInt16BE(bytes, at: payloadStart) else {
                        throw ImageCraftError.unsupportedOrCorruptImage
                    }
                    grayscaleTransparency = gray
                } else if header.colorType == 2 {
                    guard let red = readUInt16BE(bytes, at: payloadStart),
                        let green = readUInt16BE(bytes, at: payloadStart + 2),
                        let blue = readUInt16BE(bytes, at: payloadStart + 4)
                    else { throw ImageCraftError.unsupportedOrCorruptImage }
                    truecolorTransparency = PNGValidatedContainerFacts.TruecolorTransparency(
                        red: red,
                        green: green,
                        blue: blue
                    )
                } else if header.colorType == 3 {
                    indexedTransparencyPayloadRange = payloadStart..<payloadEnd
                }
            case pngEXIF:
                guard !hasEXIF else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                hasEXIF = true
            case pngCICP:
                guard cicp == nil,
                    payloadLength == 4,
                    bytes[payloadStart + 2] == 0,
                    bytes[payloadStart + 3] <= 1
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                cicp = PNGValidatedContainerFacts.CICP(
                    colorPrimaries: bytes[payloadStart],
                    transferFunction: bytes[payloadStart + 1],
                    matrixCoefficients: bytes[payloadStart + 2],
                    videoFullRangeFlag: bytes[payloadStart + 3]
                )
            case pngMDCV:
                guard masteringDisplayColorVolume == nil,
                    payloadLength == 24,
                    let redX = readUInt16BE(bytes, at: payloadStart),
                    let redY = readUInt16BE(bytes, at: payloadStart + 2),
                    let greenX = readUInt16BE(bytes, at: payloadStart + 4),
                    let greenY = readUInt16BE(bytes, at: payloadStart + 6),
                    let blueX = readUInt16BE(bytes, at: payloadStart + 8),
                    let blueY = readUInt16BE(bytes, at: payloadStart + 10),
                    let whiteX = readUInt16BE(bytes, at: payloadStart + 12),
                    let whiteY = readUInt16BE(bytes, at: payloadStart + 14),
                    let maximumLuminance = readUInt32BE(bytes, at: payloadStart + 16),
                    let minimumLuminance = readUInt32BE(bytes, at: payloadStart + 20),
                    maximumLuminance <= 0x7fff_ffff,
                    minimumLuminance <= 0x7fff_ffff
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                masteringDisplayColorVolume = PNGValidatedContainerFacts.MasteringDisplayColorVolume(
                    redX: redX,
                    redY: redY,
                    greenX: greenX,
                    greenY: greenY,
                    blueX: blueX,
                    blueY: blueY,
                    whiteX: whiteX,
                    whiteY: whiteY,
                    maximumLuminanceScaledBy10000: maximumLuminance,
                    minimumLuminanceScaledBy10000: minimumLuminance
                )
            case pngCLLI:
                guard contentLightLevel == nil,
                    payloadLength == 8,
                    let maximumContentLightLevel = readUInt32BE(bytes, at: payloadStart),
                    let maximumFrameAverageLightLevel = readUInt32BE(bytes, at: payloadStart + 4),
                    maximumContentLightLevel <= 0x7fff_ffff,
                    maximumFrameAverageLightLevel <= 0x7fff_ffff
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                contentLightLevel = PNGValidatedContainerFacts.ContentLightLevel(
                    maximumContentLightLevelScaledBy10000: maximumContentLightLevel,
                    maximumFrameAverageLightLevelScaledBy10000: maximumFrameAverageLightLevel
                )
            case pngSBIT:
                guard significantBits == nil,
                    let header,
                    let parsedSignificantBits = parsePNGSBIT(
                        bytes,
                        payloadStart: payloadStart,
                        payloadLength: payloadLength,
                        header: header
                    )
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                significantBits = parsedSignificantBits
            case pngACTL, pngFCTL, pngFDAT:
                hasAnimationChunks = true
            default:
                let firstTypeByte = bytes[offset + 4]
                if (65...90).contains(firstTypeByte),
                    type != pngIHDR,
                    type != pngPLTE,
                    type != pngIDAT,
                    type != pngIEND
                {
                    hasUnknownCriticalChunk = true
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
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
                guard !foundICCP else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                foundICCP = true
                embeddedICCCompressedRange = try pngICCCompressedRange(
                    bytes,
                    payloadRange: payloadStart..<payloadEnd
                )
            } else if type == pngSRGB {
                guard !foundSRGB,
                    payloadLength == 1,
                    bytes[payloadStart] <= 3
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                foundSRGB = true
            }

            offset = chunkEnd.partialValue
            if type == pngIEND {
                iendPayloadLength = payloadLength
                foundEnd = true
                break
            }
            chunkIndex += 1
        }
        guard foundEnd,
            offset == bytes.count,
            ihdrCount == 1,
            ihdrWasFirst,
            let validatedHeader = header,
            isValidPNGHeader(validatedHeader),
            isValidPNGPalette(
                header: validatedHeader,
                hasPalette: hasPalette,
                paletteEntryCount: paletteEntryCount
            ),
            firstIDATChunkOffset != nil,
            idatRunIsContiguous,
            iendPayloadLength == 0,
            allChunkTypeBytesAreLetters,
            prePaletteAndIDATChunksAreOrdered,
            knownPreIDATChunksAreOrdered,
            !hasUnknownCriticalChunk,
            masteringDisplayColorVolume == nil || cicp != nil
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }

        // PNG Third Edition color-chunk precedence: cICP > iCCP > sRGB > cHRM/gAMA.
        // SourceColorProfile has no cICP or cHRM/gAMA value case, so those authorities publish
        // `.unknown` rather than being mislabeled as absent or as a lower-precedence profile.
        if cicp != nil {
            sourceColorProfile = .unknown
        } else if foundICCP {
            sourceColorProfile = .embeddedICC
            if materializeICCProfile, let embeddedICCCompressedRange {
                embeddedICCProfile = try decodePNGICCProfile(
                    bytes,
                    compressedRange: embeddedICCCompressedRange,
                    maximumByteCount: maximumMetadataBytes
                )
            }
        } else if foundSRGB {
            sourceColorProfile = .standardSRGB
        } else if hasGamma || hasChromaticities {
            sourceColorProfile = .unknown
        } else {
            sourceColorProfile = .absent
        }

        return EncodedImageSecurityInspection(
            format: .png,
            metadataByteCount: metadataBytes,
            sourceColorProfile: sourceColorProfile,
            embeddedICCProfile: embeddedICCProfile,
            pngContainerFacts: PNGValidatedContainerFacts(
                header: header,
                ihdrCount: ihdrCount,
                ihdrWasFirst: ihdrWasFirst,
                allChunkTypeBytesAreLetters: allChunkTypeBytesAreLetters,
                allChunkReservedBitsAreZero: allChunkReservedBitsAreZero,
                prePaletteAndIDATChunksAreOrdered: prePaletteAndIDATChunksAreOrdered,
                knownPreIDATChunksAreOrdered: knownPreIDATChunksAreOrdered,
                firstIDATChunkOffset: firstIDATChunkOffset,
                idatRunEndOffset: idatRunEndOffset,
                compressedIDATByteCount: compressedIDATByteCount,
                idatRunIsContiguous: idatRunIsContiguous,
                embeddedICCCompressedRange: embeddedICCCompressedRange,
                iendPayloadLength: iendPayloadLength,
                hasGamma: hasGamma,
                hasChromaticities: hasChromaticities,
                significantBits: significantBits,
                hasPalette: hasPalette,
                palettePayloadRange: palettePayloadRange,
                hasTransparency: hasTransparency,
                indexedTransparencyPayloadRange: indexedTransparencyPayloadRange,
                grayscaleTransparency: grayscaleTransparency,
                truecolorTransparency: truecolorTransparency,
                hasEXIF: hasEXIF,
                cicp: cicp,
                masteringDisplayColorVolume: masteringDisplayColorVolume,
                contentLightLevel: contentLightLevel,
                hasAnimationChunks: hasAnimationChunks,
                hasUnknownCriticalChunk: hasUnknownCriticalChunk
            )
        )
    }

    static func materializingPNGICCProfile(
        _ inspection: EncodedImageSecurityInspection,
        in data: Data,
        maximumMetadataBytes: Int
    ) throws -> EncodedImageSecurityInspection {
        guard inspection.format == .png else { return inspection }
        guard inspection.sourceColorProfile == .embeddedICC else { return inspection }
        if inspection.embeddedICCProfile != nil { return inspection }
        guard let compressedRange = inspection.pngContainerFacts?.embeddedICCCompressedRange else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let profile = try data.withUnsafeBytes { rawBuffer in
            try decodePNGICCProfile(
                rawBuffer.bindMemory(to: UInt8.self),
                compressedRange: compressedRange,
                maximumByteCount: maximumMetadataBytes
            )
        }
        return EncodedImageSecurityInspection(
            format: inspection.format,
            metadataByteCount: inspection.metadataByteCount,
            sourceColorProfile: inspection.sourceColorProfile,
            embeddedICCProfile: profile,
            pngContainerFacts: inspection.pngContainerFacts
        )
    }

    private static func pngICCCompressedRange(
        _ bytes: UnsafeBufferPointer<UInt8>,
        payloadRange: Range<Int>
    ) throws -> Range<Int> {
        guard payloadRange.lowerBound >= 0,
            payloadRange.upperBound <= bytes.count,
            payloadRange.count >= 4
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        var separator = payloadRange.lowerBound
        while separator < payloadRange.upperBound, bytes[separator] != 0 {
            separator += 1
        }
        let nameLength = separator - payloadRange.lowerBound
        guard (1...79).contains(nameLength),
            separator + 2 <= payloadRange.upperBound,
            bytes[separator] == 0,
            bytes[separator + 1] == 0,
            isValidPNGKeyword(bytes[payloadRange.lowerBound..<separator])
        else { throw ImageCraftError.unsupportedOrCorruptImage }

        let compressedStart = separator + 2
        guard compressedStart < payloadRange.upperBound else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return compressedStart..<payloadRange.upperBound
    }

    private static func decodePNGICCProfile(
        _ bytes: UnsafeBufferPointer<UInt8>,
        compressedRange: Range<Int>,
        maximumByteCount: Int
    ) throws -> Data {
        guard maximumByteCount >= 0,
            compressedRange.lowerBound >= 0,
            compressedRange.upperBound <= bytes.count,
            !compressedRange.isEmpty
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        guard let base = bytes.baseAddress else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let compressed = UnsafeBufferPointer(
            start: base.advanced(by: compressedRange.lowerBound),
            count: compressedRange.count
        )
        let profile: Data
        do {
            profile = try RFC1950BoundedInflate.inflate(
                compressed,
                maximumByteCount: maximumByteCount
            )
        } catch RFC1950BoundedInflateError.outputLimitExceeded {
            throw ImageCraftError.metadataLimitExceeded
        } catch {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        guard isStructurallyValidICCProfile(profile) else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return profile
    }

    private static func isValidPNGKeyword(_ bytes: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        guard let first = bytes.first, let last = bytes.last,
            first != 0x20, last != 0x20
        else { return false }
        var previousWasSpace = false
        for byte in bytes {
            let printableLatin1 = (32...126).contains(byte) || (161...255).contains(byte)
            guard printableLatin1 else { return false }
            if byte == 0x20 {
                guard !previousWasSpace else { return false }
                previousWasSpace = true
            } else {
                previousWasSpace = false
            }
        }
        return true
    }

    private static func isStructurallyValidICCProfile(_ profile: Data) -> Bool {
        guard profile.count >= 132 else { return false }
        let declaredSize =
            Int(profile[0]) << 24
            | Int(profile[1]) << 16
            | Int(profile[2]) << 8
            | Int(profile[3])
        guard declaredSize == profile.count else { return false }
        guard profile[36] == 0x61
            && profile[37] == 0x63
            && profile[38] == 0x73
            && profile[39] == 0x70
        else { return false }

        let tagCount =
            Int(profile[128]) << 24
            | Int(profile[129]) << 16
            | Int(profile[130]) << 8
            | Int(profile[131])
        let tableBytes = tagCount.multipliedReportingOverflow(by: 12)
        guard !tableBytes.overflow else { return false }
        let tableEnd = 132.addingReportingOverflow(tableBytes.partialValue)
        guard !tableEnd.overflow, tableEnd.partialValue <= profile.count else { return false }
        for index in 0..<tagCount {
            let entry = 132 + index * 12
            let offset =
                Int(profile[entry + 4]) << 24
                | Int(profile[entry + 5]) << 16
                | Int(profile[entry + 6]) << 8
                | Int(profile[entry + 7])
            let size =
                Int(profile[entry + 8]) << 24
                | Int(profile[entry + 9]) << 16
                | Int(profile[entry + 10]) << 8
                | Int(profile[entry + 11])
            guard offset >= tableEnd.partialValue,
                offset % 4 == 0,
                size > 0
            else { return false }
            let end = offset.addingReportingOverflow(size)
            guard !end.overflow, end.partialValue <= profile.count else { return false }
        }
        return true
    }

    private struct JPEGInspectionState {
        var offset: Int
        var scanCount = 0
        var metadataBytes = 0
        var sourceColorProfile = SourceColorProfile.absent
        var iccChunkCount: Int?
        var iccChunkRanges: [Int: Range<Int>] = [:]
        var isInsideScan = false
        var foundEnd = false
    }

    private static func inspectJPEG(
        _ bytes: UnsafeBufferPointer<UInt8>,
        maximumMetadataBytes: Int,
        materializeICCProfile: Bool
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
        let iccFacts = try assembledJPEGICCFacts(
            bytes,
            chunkCount: state.iccChunkCount,
            chunkRanges: state.iccChunkRanges,
            maximumMetadataBytes: maximumMetadataBytes,
            materialize: materializeICCProfile
        )
        return EncodedImageSecurityInspection(
            format: .jpeg,
            metadataByteCount: state.metadataBytes,
            sourceColorProfile: state.sourceColorProfile,
            embeddedICCProfile: iccFacts.profile,
            embeddedICCProfileByteCount: iccFacts.byteCount
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
        if marker == 0xDA {
            state.scanCount += 1
            guard state.scanCount <= maximumJPEGScanCount else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
        }
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

    private static func assembledJPEGICCFacts(
        _ bytes: UnsafeBufferPointer<UInt8>,
        chunkCount: Int?,
        chunkRanges: [Int: Range<Int>],
        maximumMetadataBytes: Int,
        materialize: Bool
    ) throws -> (profile: Data?, byteCount: Int?) {
        guard let count = chunkCount else { return (nil, nil) }
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
        guard materialize else { return (nil, totalBytes) }
        var profile = Data()
        profile.reserveCapacity(totalBytes)
        for range in ranges { profile.append(contentsOf: bytes[range]) }
        return (profile, totalBytes)
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

    private static func isValidPNGHeader(_ header: PNGValidatedContainerFacts.Header) -> Bool {
        guard header.width > 0,
            header.height > 0,
            header.width <= 0x7FFF_FFFF,
            header.height <= 0x7FFF_FFFF,
            header.compressionMethod == 0,
            header.filterMethod == 0,
            header.interlaceMethod <= 1
        else { return false }
        switch header.colorType {
        case 0:
            return [1, 2, 4, 8, 16].contains(header.bitDepth)
        case 2:
            return header.bitDepth == 8 || header.bitDepth == 16
        case 3:
            return [1, 2, 4, 8].contains(header.bitDepth)
        case 4, 6:
            return header.bitDepth == 8 || header.bitDepth == 16
        default:
            return false
        }
    }

    private static func isValidPNGPalette(
        header: PNGValidatedContainerFacts.Header,
        hasPalette: Bool,
        paletteEntryCount: Int?
    ) -> Bool {
        switch header.colorType {
        case 0, 4:
            return !hasPalette
        case 3:
            guard hasPalette, let paletteEntryCount else { return false }
            return paletteEntryCount <= (1 << Int(header.bitDepth))
        case 2, 6:
            return true
        default:
            return false
        }
    }

    private static func isValidPNGTransparency(
        payloadLength: Int,
        header: PNGValidatedContainerFacts.Header,
        hasPalette: Bool,
        paletteEntryCount: Int?
    ) -> Bool {
        switch header.colorType {
        case 0:
            return payloadLength == 2
        case 2:
            return payloadLength == 6
        case 3:
            guard hasPalette, let paletteEntryCount else { return false }
            return payloadLength > 0 && payloadLength <= paletteEntryCount
        case 4, 6:
            return false
        default:
            return false
        }
    }

    private static func parsePNGSBIT(
        _ bytes: UnsafeBufferPointer<UInt8>,
        payloadStart: Int,
        payloadLength: Int,
        header: PNGValidatedContainerFacts.Header
    ) -> PNGValidatedContainerFacts.SignificantBits? {
        let expectedLength: Int
        let maximumSignificantBits: UInt8
        switch header.colorType {
        case 0:
            expectedLength = 1
            maximumSignificantBits = header.bitDepth
        case 2:
            expectedLength = 3
            maximumSignificantBits = header.bitDepth
        case 3:
            expectedLength = 3
            maximumSignificantBits = 8
        case 4:
            expectedLength = 2
            maximumSignificantBits = header.bitDepth
        case 6:
            expectedLength = 4
            maximumSignificantBits = header.bitDepth
        default:
            return nil
        }
        guard payloadLength == expectedLength,
            payloadStart >= 0,
            payloadStart + payloadLength <= bytes.count
        else { return nil }
        for index in 0..<payloadLength {
            let value = bytes[payloadStart + index]
            if value == 0 || value > maximumSignificantBits { return nil }
        }
        switch header.colorType {
        case 0:
            return .grayscale(gray: bytes[payloadStart])
        case 2, 3:
            return .rgb(
                red: bytes[payloadStart],
                green: bytes[payloadStart + 1],
                blue: bytes[payloadStart + 2]
            )
        case 4:
            return .grayscaleAlpha(
                gray: bytes[payloadStart],
                alpha: bytes[payloadStart + 1]
            )
        case 6:
            return .rgba(
                red: bytes[payloadStart],
                green: bytes[payloadStart + 1],
                blue: bytes[payloadStart + 2],
                alpha: bytes[payloadStart + 3]
            )
        default:
            return nil
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
