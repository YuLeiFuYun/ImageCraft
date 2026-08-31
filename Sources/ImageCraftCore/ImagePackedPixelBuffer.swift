import Foundation

package enum ImagePackedSampleStorage: String, Codable, Hashable, Sendable {
    case uint8
    case uint16

    package var bytesPerSample: Int {
        switch self {
        case .uint8: 1
        case .uint16: 2
        }
    }
}

package enum ImagePackedChannelLayout: String, Codable, Hashable, Sendable {
    case rgb
    case rgba

    package var channelCount: Int {
        switch self {
        case .rgb: 3
        case .rgba: 4
        }
    }
}

package enum ImagePackedAlphaAssociation: String, Codable, Hashable, Sendable {
    case none
    case straight
    case premultiplied
}

package enum ImagePackedMultibyteByteOrder: String, Codable, Hashable, Sendable {
    case littleEndian
}

/// Backend-neutral packed-pixel format description used by qualification values.
///
/// Sample storage, channel layout, alpha association and multibyte byte order are independent
/// contract dimensions. Eight-bit samples have no byte-order field; multibyte samples require one.
package struct ImagePackedPixelFormat: Codable, Equatable, Hashable, Sendable {
    package let sampleStorage: ImagePackedSampleStorage
    package let channelLayout: ImagePackedChannelLayout
    package let alphaAssociation: ImagePackedAlphaAssociation
    package let multibyteByteOrder: ImagePackedMultibyteByteOrder?

    package init?(
        sampleStorage: ImagePackedSampleStorage,
        channelLayout: ImagePackedChannelLayout,
        alphaAssociation: ImagePackedAlphaAssociation,
        multibyteByteOrder: ImagePackedMultibyteByteOrder?
    ) {
        switch sampleStorage {
        case .uint8:
            guard multibyteByteOrder == nil else { return nil }
        case .uint16:
            guard multibyteByteOrder != nil else { return nil }
        }
        switch channelLayout {
        case .rgb:
            guard alphaAssociation == .none else { return nil }
        case .rgba:
            guard alphaAssociation != .none else { return nil }
        }
        self.sampleStorage = sampleStorage
        self.channelLayout = channelLayout
        self.alphaAssociation = alphaAssociation
        self.multibyteByteOrder = multibyteByteOrder
    }

    private enum CodingKeys: String, CodingKey {
        case sampleStorage
        case channelLayout
        case alphaAssociation
        case multibyteByteOrder
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sampleStorage = try container.decode(ImagePackedSampleStorage.self, forKey: .sampleStorage)
        let channelLayout = try container.decode(ImagePackedChannelLayout.self, forKey: .channelLayout)
        let alphaAssociation = try container.decode(
            ImagePackedAlphaAssociation.self,
            forKey: .alphaAssociation
        )
        let multibyteByteOrder = try container.decodeIfPresent(
            ImagePackedMultibyteByteOrder.self,
            forKey: .multibyteByteOrder
        )
        guard let validated = Self(
            sampleStorage: sampleStorage,
            channelLayout: channelLayout,
            alphaAssociation: alphaAssociation,
            multibyteByteOrder: multibyteByteOrder
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid packed pixel format invariant"
                )
            )
        }
        self = validated
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleStorage, forKey: .sampleStorage)
        try container.encode(channelLayout, forKey: .channelLayout)
        try container.encode(alphaAssociation, forKey: .alphaAssociation)
        try container.encodeIfPresent(multibyteByteOrder, forKey: .multibyteByteOrder)
    }

    package var bytesPerPixel: Int {
        sampleStorage.bytesPerSample * channelLayout.channelCount
    }

    package static let rgb8 = Self(
        sampleStorage: .uint8,
        channelLayout: .rgb,
        alphaAssociation: .none,
        multibyteByteOrder: nil
    )!

    package static let rgba8Premultiplied = Self(
        sampleStorage: .uint8,
        channelLayout: .rgba,
        alphaAssociation: .premultiplied,
        multibyteByteOrder: nil
    )!

    package static let rgba16StraightLittleEndian = Self(
        sampleStorage: .uint16,
        channelLayout: .rgba,
        alphaAssociation: .straight,
        multibyteByteOrder: .littleEndian
    )!
}

/// Source significant-bit metadata kept separate from packed output layout.
///
/// The channel model describes channels physically stored by the encoded source. A synthesized
/// output alpha channel (for example RGB/gray+tRNS normalized to RGBA) is therefore never mistaken
/// for source alpha provenance. Values are relative to `sampleBitDepth`, not the output container.
package struct ImagePackedSourceSignificantBits: Equatable, Sendable {
    package enum Channels: Equatable, Sendable {
        case grayscale(gray: UInt8)
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
        case grayscaleAlpha(gray: UInt8, alpha: UInt8)
        case rgba(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    }

    package let sampleBitDepth: UInt8
    package let channels: Channels

    package init?(sampleBitDepth: UInt8, channels: Channels) {
        guard sampleBitDepth > 0 else { return nil }
        let values: [UInt8]
        switch channels {
        case .grayscale(let gray):
            values = [gray]
        case .rgb(let red, let green, let blue):
            values = [red, green, blue]
        case .grayscaleAlpha(let gray, let alpha):
            values = [gray, alpha]
        case .rgba(let red, let green, let blue, let alpha):
            values = [red, green, blue, alpha]
        }
        guard values.allSatisfy({ $0 > 0 && $0 <= sampleBitDepth }) else { return nil }
        self.sampleBitDepth = sampleBitDepth
        self.channels = channels
    }

    package var sourceHasStoredAlpha: Bool {
        switch channels {
        case .grayscale, .rgb: false
        case .grayscaleAlpha, .rgba: true
        }
    }

    package var gray: UInt8? {
        switch channels {
        case .grayscale(let gray), .grayscaleAlpha(let gray, _): gray
        case .rgb, .rgba: nil
        }
    }

    package var red: UInt8? {
        switch channels {
        case .rgb(let red, _, _), .rgba(let red, _, _, _): red
        case .grayscale, .grayscaleAlpha: nil
        }
    }

    package var green: UInt8? {
        switch channels {
        case .rgb(_, let green, _), .rgba(_, let green, _, _): green
        case .grayscale, .grayscaleAlpha: nil
        }
    }

    package var blue: UInt8? {
        switch channels {
        case .rgb(_, _, let blue), .rgba(_, _, let blue, _): blue
        case .grayscale, .grayscaleAlpha: nil
        }
    }

    package var alpha: UInt8? {
        switch channels {
        case .grayscaleAlpha(_, let alpha), .rgba(_, _, _, let alpha): alpha
        case .grayscale, .rgb: nil
        }
    }
}

package enum ImagePackedPixelContractError: Error, Equatable, Sendable {
    case unclassifiedColorState
    case invalidBuffer
    case invalidColorEncoding
    case rasterizationUnavailable
}

/// Coding-independent color signaling for packed RGB samples.
///
/// Packed RGB(A) values require the identity RGB matrix code point (`0`). The range flag is
/// preserved as the encoded 0/1 value because it changes sample interpretation; a backend may
/// qualify only a subset of otherwise valid primaries/transfer tuples.
public struct ImagePackedCICPColorEncoding: Equatable, Sendable {
    public let colorPrimaries: UInt8
    public let transferFunction: UInt8
    public let matrixCoefficients: UInt8
    public let videoFullRangeFlag: UInt8

    public init?(
        colorPrimaries: UInt8,
        transferFunction: UInt8,
        matrixCoefficients: UInt8,
        videoFullRangeFlag: UInt8
    ) {
        guard matrixCoefficients == 0, videoFullRangeFlag <= 1 else { return nil }
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.matrixCoefficients = matrixCoefficients
        self.videoFullRangeFlag = videoFullRangeFlag
    }

    public var isFullRange: Bool { videoFullRangeFlag == 1 }
}

/// Exact PNG mDCV stored integers. Chromaticities use 0.00002 units; luminance uses 0.0001 nit.
package struct ImagePackedMasteringDisplayColorVolume: Equatable, Sendable {
    package let redX: UInt16
    package let redY: UInt16
    package let greenX: UInt16
    package let greenY: UInt16
    package let blueX: UInt16
    package let blueY: UInt16
    package let whiteX: UInt16
    package let whiteY: UInt16
    package let maximumLuminanceScaledBy10000: UInt32
    package let minimumLuminanceScaledBy10000: UInt32

    package init?(
        redX: UInt16,
        redY: UInt16,
        greenX: UInt16,
        greenY: UInt16,
        blueX: UInt16,
        blueY: UInt16,
        whiteX: UInt16,
        whiteY: UInt16,
        maximumLuminanceScaledBy10000: UInt32,
        minimumLuminanceScaledBy10000: UInt32
    ) {
        guard maximumLuminanceScaledBy10000 <= 0x7fff_ffff,
            minimumLuminanceScaledBy10000 <= 0x7fff_ffff
        else { return nil }
        self.redX = redX
        self.redY = redY
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
        self.whiteX = whiteX
        self.whiteY = whiteY
        self.maximumLuminanceScaledBy10000 = maximumLuminanceScaledBy10000
        self.minimumLuminanceScaledBy10000 = minimumLuminanceScaledBy10000
    }
}

/// Exact PNG cLLI stored integers, in 0.0001 nit units. Zero remains an explicit unknown value.
package struct ImagePackedContentLightLevel: Equatable, Sendable {
    package let maximumContentLightLevelScaledBy10000: UInt32
    package let maximumFrameAverageLightLevelScaledBy10000: UInt32

    package init?(
        maximumContentLightLevelScaledBy10000: UInt32,
        maximumFrameAverageLightLevelScaledBy10000: UInt32
    ) {
        guard maximumContentLightLevelScaledBy10000 <= 0x7fff_ffff,
            maximumFrameAverageLightLevelScaledBy10000 <= 0x7fff_ffff
        else { return nil }
        self.maximumContentLightLevelScaledBy10000 = maximumContentLightLevelScaledBy10000
        self.maximumFrameAverageLightLevelScaledBy10000 = maximumFrameAverageLightLevelScaledBy10000
    }
}

/// Static HDR metadata is orthogonal to color encoding and does not imply tone mapping.
package struct ImagePackedHDRStaticMetadata: Equatable, Sendable {
    package let masteringDisplayColorVolume: ImagePackedMasteringDisplayColorVolume?
    package let contentLightLevel: ImagePackedContentLightLevel?

    package init?(
        masteringDisplayColorVolume: ImagePackedMasteringDisplayColorVolume?,
        contentLightLevel: ImagePackedContentLightLevel?
    ) {
        guard masteringDisplayColorVolume != nil || contentLightLevel != nil else { return nil }
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevel = contentLightLevel
    }
}

/// Backend-neutral color state for codec-owned packed RGB samples. Keeping embedded ICC bytes as a
/// value avoids transferring an opaque `CGColorSpace` ownership claim across backends.
public enum ImagePackedPixelColorEncoding: Equatable, Sendable {
    case sRGB
    case embeddedICC(Data)
    case cicp(ImagePackedCICPColorEncoding)

    public var retainedByteCharge: Int {
        switch self {
        case .sRGB, .cicp: 0
        case .embeddedICC(let data): data.count
        }
    }

    package func isConsistent(with sourceColorProfile: SourceColorProfile) -> Bool {
        switch self {
        case .sRGB:
            // Output may have been converted from any qualified source color authority.
            return true
        case .embeddedICC(let profile):
            return !profile.isEmpty && sourceColorProfile == .embeddedICC
        case .cicp:
            // `SourceColorProfile` has no cICP case; `.unknown` distinguishes a qualified
            // non-profile color authority from both an absent profile and an embedded ICC.
            return sourceColorProfile == .unknown
        }
    }
}

/// Qualification representation for codec-owned, tightly packed RGB8 pixels with no synthesized
/// alpha channel. Color interpretation remains an independent required value: exact RGB bytes alone
/// are insufficient to classify source or output color semantics.
package struct ImagePackedRGB8: Equatable, Sendable {
    package let data: Data
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let bytesPerRow: Int
    package let colorEncoding: ImagePackedPixelColorEncoding
    package let sourceColorProfile: SourceColorProfile
    package let format = ImagePackedPixelFormat.rgb8

    package init?(
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        colorEncoding: ImagePackedPixelColorEncoding,
        sourceColorProfile: SourceColorProfile
    ) {
        guard pixelWidth > 0,
            pixelHeight > 0,
            colorEncoding.isConsistent(with: sourceColorProfile)
        else { return nil }
        let row = pixelWidth.multipliedReportingOverflow(by: format.bytesPerPixel)
        guard !row.overflow else { return nil }
        let total = row.partialValue.multipliedReportingOverflow(by: pixelHeight)
        guard !total.overflow, data.count == total.partialValue else { return nil }
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerRow = row.partialValue
        self.colorEncoding = colorEncoding
        self.sourceColorProfile = sourceColorProfile
    }

    package var pixelByteCharge: Int { data.count }

    package var transferredByteCharge: Int {
        let total = data.count.addingReportingOverflow(colorEncoding.retainedByteCharge)
        return total.overflow ? Int.max : total.partialValue
    }
}

/// Backend-neutral representation for codec-owned, tightly packed RGBA8 pixels.
///
/// Bytes are RGBA channel order, 8 bits/channel, premultiplied alpha, top-to-bottom logical rows,
/// and `bytesPerRow == pixelWidth * 4`. The value contract is independent of whether a particular
/// producer has bounded or framework-private operation costs; callers must use the producer's
/// resource authority separately.
public struct ImagePackedRGBA8: Equatable, Sendable {
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bytesPerRow: Int
    public let colorEncoding: ImagePackedPixelColorEncoding
    public let sourceColorProfile: SourceColorProfile
    package let format = ImagePackedPixelFormat.rgba8Premultiplied

    public init?(
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        colorEncoding: ImagePackedPixelColorEncoding,
        sourceColorProfile: SourceColorProfile
    ) {
        guard pixelWidth > 0,
            pixelHeight > 0,
            colorEncoding.isConsistent(with: sourceColorProfile)
        else { return nil }
        let row = pixelWidth.multipliedReportingOverflow(by: 4)
        guard !row.overflow else { return nil }
        let total = row.partialValue.multipliedReportingOverflow(by: pixelHeight)
        guard !total.overflow, data.count == total.partialValue else { return nil }
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerRow = row.partialValue
        self.colorEncoding = colorEncoding
        self.sourceColorProfile = sourceColorProfile
    }

    public var pixelByteCharge: Int { data.count }

    public var transferredByteCharge: Int {
        let total = data.count.addingReportingOverflow(colorEncoding.retainedByteCharge)
        return total.overflow ? Int.max : total.partialValue
    }
}

/// Qualification representation for codec-owned, tightly packed straight RGBA16 samples.
///
/// Each channel is an unsigned 16-bit value stored little-endian. Alpha is straight/unassociated so
/// exact source-domain RGB samples remain recoverable when alpha is neither zero nor full scale.
/// Logical rows are top-to-bottom and `bytesPerRow == pixelWidth * 8`.
package struct ImagePackedRGBA16Straight: Equatable, Sendable {
    package let data: Data
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let bytesPerRow: Int
    package let colorEncoding: ImagePackedPixelColorEncoding
    package let sourceColorProfile: SourceColorProfile
    package let sourceSignificantBits: ImagePackedSourceSignificantBits?
    package let hdrStaticMetadata: ImagePackedHDRStaticMetadata?
    package let format = ImagePackedPixelFormat.rgba16StraightLittleEndian

    package init?(
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        colorEncoding: ImagePackedPixelColorEncoding,
        sourceColorProfile: SourceColorProfile,
        sourceSignificantBits: ImagePackedSourceSignificantBits? = nil,
        hdrStaticMetadata: ImagePackedHDRStaticMetadata? = nil
    ) {
        guard pixelWidth > 0, pixelHeight > 0,
            colorEncoding.isConsistent(with: sourceColorProfile),
            sourceSignificantBits?.sampleBitDepth == nil || sourceSignificantBits?.sampleBitDepth == 16
        else { return nil }
        let row = pixelWidth.multipliedReportingOverflow(by: format.bytesPerPixel)
        guard !row.overflow else { return nil }
        let total = row.partialValue.multipliedReportingOverflow(by: pixelHeight)
        guard !total.overflow, data.count == total.partialValue else { return nil }
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerRow = row.partialValue
        self.colorEncoding = colorEncoding
        self.sourceColorProfile = sourceColorProfile
        self.sourceSignificantBits = sourceSignificantBits
        self.hdrStaticMetadata = hdrStaticMetadata
    }

    package var pixelByteCharge: Int { data.count }

    package var transferredByteCharge: Int {
        let total = data.count.addingReportingOverflow(colorEncoding.retainedByteCharge)
        return total.overflow ? Int.max : total.partialValue
    }
}
