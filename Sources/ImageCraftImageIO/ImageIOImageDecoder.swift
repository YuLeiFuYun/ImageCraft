import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

/// 基于 ImageIO、支持目标尺寸的光栅图像探测与解码器。

public struct ImageIOImageDecoder: ImageCodec, InstrumentedPreparedImageDecoding {
    private let preparations: ImageIOPreparationStore

    /// 当前 Image I/O 适配器只承诺完整主帧、SDR 和 Core Graphics 输出。
    /// GIF 多帧容器可以被安全探测，但该适配器尚未公开动画时间轴语义。
    public let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "dev.fovea.imageio"),
        implementationVersion: 3,
        capabilities: ImageCodecCapabilities(
            formats: [.png, .jpeg, .gif],
            deliveryModes: [.completeFrame, .progressiveGenerations],
            progressiveFormats: [.jpeg],
            trackModes: [.primaryFrame],
            metadata: [.orientation, .sourceColorProfile],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
    )

    /// 创建可复用一次性安全探测结果的 Image I/O 解码器。
    public init() {
        self.preparations = ImageIOPreparationStore()
    }

    /// 检查有界编码数据，但不分配最终光栅缓冲区。
    public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try inspect(data: data, limits: limits).probe
    }

    /// 安全探测输入并保留可一次性复用的 `CGImageSource`。
    public func prepare(
        data: Data,
        limits: DecodeLimits
    ) throws -> ImageDecodePreparation {
        let inspection = try inspect(data: data, limits: limits)
        let preparation = ImageDecodePreparation(probe: inspection.probe)
        guard
            preparations.insert(
                identifier: preparation.identifier,
                data: data,
                source: inspection.source,
                probe: inspection.probe,
                sourceColorSpace: inspection.sourceColorSpace,
                limits: limits
            )
        else {
            throw ImageCraftError.decodeFailed
        }
        return preparation
    }

    package func prepareWithDiagnostics(
        data: Data,
        limits: DecodeLimits
    ) throws -> InstrumentedImageDecodePreparation {
        let result = try inspectWithDiagnostics(data: data, limits: limits)
        let preparation = ImageDecodePreparation(probe: result.inspection.probe)
        guard
            preparations.insert(
                identifier: preparation.identifier,
                data: data,
                source: result.inspection.source,
                probe: result.inspection.probe,
                sourceColorSpace: result.inspection.sourceColorSpace,
                limits: limits
            )
        else {
            throw ImageCraftError.decodeFailed
        }
        return InstrumentedImageDecodePreparation(
            preparation: preparation,
            diagnostics: result.diagnostics
        )
    }

    /// 消费 preparation，复用已验证 ImageIO source 完成目标解码。
    public func decode(
        preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        guard
            let entry = preparations.take(identifier: preparation.identifier),
            entry.probe == preparation.probe,
            entry.limits == limits
        else {
            throw ImageCraftError.probeMismatch
        }
        return try decode(
            source: entry.source,
            probe: entry.probe,
            sourceColorSpace: entry.sourceColorSpace,
            request: request,
            limits: limits
        )
    }

    package func decodeWithDiagnostics(
        preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> InstrumentedDecodedImage {
        guard
            let entry = preparations.take(identifier: preparation.identifier),
            entry.probe == preparation.probe,
            entry.limits == limits
        else {
            throw ImageCraftError.probeMismatch
        }

        // preparation 已经完成容器、类型、帧数和属性验证；一次性令牌直接复用
        // 同一个不可变 CGImageSource，避免第二次解析和第二次数据源构造。
        let geometry = decodeGeometry(probe: entry.probe, request: request, limits: limits)
        let rasterStarted = DispatchTime.now().uptimeNanoseconds
        let raster = try createRaster(source: entry.source, geometry: geometry)
        let rasterDuration = DispatchTime.now().uptimeNanoseconds &- rasterStarted

        let postProcessingStarted = DispatchTime.now().uptimeNanoseconds
        let image = try finalizeDecodedImage(
            raster,
            probe: entry.probe,
            sourceColorSpace: entry.sourceColorSpace,
            request: request,
            limits: limits
        )
        let postProcessingDuration =
            DispatchTime.now().uptimeNanoseconds &- postProcessingStarted
        return InstrumentedDecodedImage(
            image: image,
            diagnostics: ImageDecodeExecutionDiagnostics(
                sourceCreationNanoseconds: 0,
                sourceTypeNanoseconds: 0,
                frameCountNanoseconds: 0,
                rasterCreationNanoseconds: rasterDuration,
                postProcessingNanoseconds: postProcessingDuration
            )
        )
    }

    /// 释放尚未消费的 ImageIO preparation；重复调用安全无效。
    public func discard(_ preparation: ImageDecodePreparation) {
        preparations.remove(identifier: preparation.identifier)
    }

    /// 使用默认完整显示与色彩策略，朝目标像素框解码。
    public func decode(
        data: Data,
        target: TargetPixels,
        limits: DecodeLimits = .coreV1
    ) throws -> DecodedImage {
        try decode(
            data: data,
            request: ImageDecodeRequest(target: target),
            limits: limits
        )
    }

    /// 根据显式解码请求探测并解码编码数据。
    public func decode(
        data: Data,
        request: ImageDecodeRequest,
        limits: DecodeLimits = .coreV1
    ) throws -> DecodedImage {
        // 便利入口直接复用同一次 inspection；旧路径先 probe，再由 supplied-probe
        // 重载重新 inspect，会重复容器扫描、CGImageSource 构造和属性读取。
        let inspection = try inspect(data: data, limits: limits)
        return try decode(
            source: inspection.source,
            probe: inspection.probe,
            sourceColorSpace: inspection.sourceColorSpace,
            request: request,
            limits: limits
        )
    }

    /// 仅当提供的探测结果仍与已检查位流一致时解码数据。
    public func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits = .coreV1
    ) throws -> DecodedImage {
        let inspection = try inspect(data: data, limits: limits)
        let verifiedProbe = inspection.probe
        guard verifiedProbe == probe else { throw ImageCraftError.probeMismatch }
        return try decode(
            source: inspection.source,
            probe: verifiedProbe,
            sourceColorSpace: inspection.sourceColorSpace,
            request: request,
            limits: limits
        )
    }

    private struct DecodeGeometry {
        let thumbnailSize: Int
    }

    private func decode(
        source: CGImageSource,
        probe: ImageProbe,
        sourceColorSpace: CGColorSpace?,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        let geometry = decodeGeometry(probe: probe, request: request, limits: limits)
        let raster = try createRaster(source: source, geometry: geometry)
        return try finalizeDecodedImage(
            raster,
            probe: probe,
            sourceColorSpace: sourceColorSpace,
            request: request,
            limits: limits
        )
    }

    private func decodeGeometry(
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) -> DecodeGeometry {
        let target = request.target
        let widthScale = Double(target.width) / Double(probe.pixelWidth)
        let heightScale = Double(target.height) / Double(probe.pixelHeight)
        let requestedScale: Double
        switch request.contentMode {
        case .fit:
            requestedScale = min(widthScale, heightScale)
        case .fill:
            requestedScale = max(widthScale, heightScale)
        }
        let scale = min(1, requestedScale)
        let sourceMaximumDimension = max(probe.pixelWidth, probe.pixelHeight)
        let thumbnailSize = max(
            1,
            min(
                limits.maximumDimension,
                Int(floor(Double(sourceMaximumDimension) * scale))
            )
        )
        return DecodeGeometry(thumbnailSize: thumbnailSize)
    }

    private func createRaster(
        source: CGImageSource,
        geometry: DecodeGeometry
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: geometry.thumbnailSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            throw ImageCraftError.decodeFailed
        }
        return thumbnail
    }

    private func finalizeDecodedImage(
        _ thumbnail: CGImage,
        probe: ImageProbe,
        sourceColorSpace: CGColorSpace?,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        let image = try colorNormalizedImage(
            thumbnail,
            sourceColorSpace: sourceColorSpace,
            sourceProfile: probe.sourceColorProfile,
            policy: request.colorPolicy
        )
        try validate(width: image.width, height: image.height, limits: limits)
        let target = request.target
        switch request.contentMode {
        case .fit:
            guard image.width <= target.width, image.height <= target.height else {
                throw ImageCraftError.decodeFailed
            }
            return DecodedImage(cgImage: image, sourceColorProfile: probe.sourceColorProfile)
        case .fill:
            let cropWidth = min(target.width, image.width)
            let cropHeight = min(target.height, image.height)
            let crop = CGRect(
                x: (image.width - cropWidth) / 2,
                y: (image.height - cropHeight) / 2,
                width: cropWidth,
                height: cropHeight
            )
            guard let cropped = image.cropping(to: crop) else {
                throw ImageCraftError.decodeFailed
            }
            try validate(width: cropped.width, height: cropped.height, limits: limits)
            return DecodedImage(cgImage: cropped, sourceColorProfile: probe.sourceColorProfile)
        }
    }

    private struct Inspection {
        let source: CGImageSource
        let probe: ImageProbe
        let sourceColorSpace: CGColorSpace?
    }

    private struct SourceMetadata {
        let source: CGImageSource
        let frameCount: Int
        let properties: [CFString: Any]
    }

    private struct InstrumentedInspection {
        let inspection: Inspection
        let diagnostics: ImageDecodePreparationDiagnostics
    }

    private func inspect(
        data: Data,
        limits: DecodeLimits
    ) throws -> Inspection {
        let container = try inspectContainer(data: data, limits: limits)
        let metadata = try inspectImageSource(
            data: data,
            expectedFormat: container.format,
            limits: limits
        )
        return try makeInspection(
            container: container,
            metadata: metadata,
            limits: limits
        )
    }

    private func inspectWithDiagnostics(
        data: Data,
        limits: DecodeLimits
    ) throws -> InstrumentedInspection {
        let containerStarted = DispatchTime.now().uptimeNanoseconds
        let container = try inspectContainer(data: data, limits: limits)
        let containerDuration = DispatchTime.now().uptimeNanoseconds &- containerStarted

        let creationStarted = DispatchTime.now().uptimeNanoseconds
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, sourceOptions(format: container.format))
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let creationDuration = DispatchTime.now().uptimeNanoseconds &- creationStarted

        let sourceTypeStarted = DispatchTime.now().uptimeNanoseconds
        guard sourceFormat(source) == container.format else {
            throw ImageCraftError.formatMismatch
        }
        let sourceTypeDuration = DispatchTime.now().uptimeNanoseconds &- sourceTypeStarted

        let frameCountStarted = DispatchTime.now().uptimeNanoseconds
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        guard frameCount <= limits.maximumFrameCount else {
            throw ImageCraftError.frameLimitExceeded
        }
        let frameCountDuration = DispatchTime.now().uptimeNanoseconds &- frameCountStarted

        let propertiesStarted = DispatchTime.now().uptimeNanoseconds
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let propertiesDuration = DispatchTime.now().uptimeNanoseconds &- propertiesStarted
        let metadata = SourceMetadata(
            source: source,
            frameCount: frameCount,
            properties: properties
        )

        let validationStarted = DispatchTime.now().uptimeNanoseconds
        let inspection = try makeInspection(
            container: container,
            metadata: metadata,
            limits: limits
        )
        let validationDuration = DispatchTime.now().uptimeNanoseconds &- validationStarted
        return InstrumentedInspection(
            inspection: inspection,
            diagnostics: ImageDecodePreparationDiagnostics(
                containerInspectionNanoseconds: containerDuration,
                imageSourceCreationNanoseconds: creationDuration,
                imageSourceTypeNanoseconds: sourceTypeDuration,
                imageFrameCountNanoseconds: frameCountDuration,
                imagePropertiesReadNanoseconds: propertiesDuration,
                probeValidationNanoseconds: validationDuration
            )
        )
    }

    private func inspectContainer(
        data: Data,
        limits: DecodeLimits
    ) throws -> EncodedImageSecurityInspection {
        guard data.count <= limits.maximumEncodedBytes else {
            throw ImageCraftError.encodedBytesExceeded
        }
        let container = try EncodedImageSecurityInspector.inspect(
            data,
            maximumMetadataBytes: limits.maximumMetadataBytes
        )
        guard limits.allowedFormats.contains(container.format) else {
            throw ImageCraftError.unsupportedFormat
        }
        guard container.metadataByteCount <= limits.maximumMetadataBytes else {
            throw ImageCraftError.metadataLimitExceeded
        }
        return container
    }

    private func inspectImageSource(
        data: Data,
        expectedFormat: EncodedImageFormat,
        limits: DecodeLimits
    ) throws -> SourceMetadata {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, sourceOptions(format: expectedFormat))
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return try inspectImageSource(
            source: source,
            expectedFormat: expectedFormat,
            limits: limits
        )
    }

    private func inspectImageSource(
        source: CGImageSource,
        expectedFormat: EncodedImageFormat,
        limits: DecodeLimits
    ) throws -> SourceMetadata {
        guard sourceFormat(source) == expectedFormat else {
            throw ImageCraftError.formatMismatch
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        guard frameCount <= limits.maximumFrameCount else {
            throw ImageCraftError.frameLimitExceeded
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        return SourceMetadata(
            source: source,
            frameCount: frameCount,
            properties: properties
        )
    }

    private func makeInspection(
        container: EncodedImageSecurityInspection,
        metadata: SourceMetadata,
        limits: DecodeLimits
    ) throws -> Inspection {
        let properties = metadata.properties
        guard let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }

        let propertyMetadataBytes = Self.serializedPropertySize(properties)
        let metadataByteCount = max(container.metadataByteCount, propertyMetadataBytes)
        guard metadataByteCount <= limits.maximumMetadataBytes else {
            throw ImageCraftError.metadataLimitExceeded
        }
        let auxiliaryAttachmentCount = auxiliaryAttachmentCount(in: properties)
        guard auxiliaryAttachmentCount <= limits.maximumAuxiliaryAttachments else {
            throw ImageCraftError.auxiliaryAttachmentLimitExceeded
        }

        let orientation = orientationValue(properties[kCGImagePropertyOrientation])
        let swapsDimensions = (5...8).contains(orientation)
        let width = swapsDimensions ? rawHeight : rawWidth
        let height = swapsDimensions ? rawWidth : rawHeight
        try validate(width: width, height: height, limits: limits)
        let sourceColorSpace: CGColorSpace?
        if let profile = container.embeddedICCProfile {
            guard let colorSpace = CGColorSpace(iccData: profile as CFData),
                colorSpace.model == .rgb
            else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            sourceColorSpace = colorSpace
        } else {
            sourceColorSpace = nil
        }
        return Inspection(
            source: metadata.source,
            probe: try ImageProbe(
                pixelWidth: width,
                pixelHeight: height,
                frameCount: metadata.frameCount,
                orientation: orientation,
                format: container.format,
                metadataByteCount: metadataByteCount,
                auxiliaryAttachmentCount: auxiliaryAttachmentCount,
                sourceColorProfile: container.sourceColorProfile
            ),
            sourceColorSpace: sourceColorSpace
        )
    }

    private func colorNormalizedImage(
        _ image: CGImage,
        sourceColorSpace: CGColorSpace?,
        sourceProfile: SourceColorProfile,
        policy: ImageColorPolicy
    ) throws -> CGImage {
        let interpretedSourceColorSpace = Self.interpretedSourceColorSpace(
            image: image,
            inspectedColorSpace: sourceColorSpace,
            sourceProfile: sourceProfile
        )
        let tagged = try Self.imageByApplyingColorInterpretation(
            interpretedSourceColorSpace,
            to: image
        )

        switch policy {
        case .preserveSource:
            return tagged
        case .convertToSRGB:
            if Self.isSRGB(tagged.colorSpace) { return tagged }
            return try convertedToSRGB(tagged)
        }
    }

    private static func interpretedSourceColorSpace(
        image: CGImage,
        inspectedColorSpace: CGColorSpace?,
        sourceProfile: SourceColorProfile
    ) -> CGColorSpace? {
        switch sourceProfile {
        case .absent, .standardSRGB:
            // 无标签源按稳定 sRGB 解释；不能信任 ImageIO 在剥离容器标签后
            // 偶然保留的色彩空间，否则同一位流在不同 OS 版本上会改变语义。
            return CGColorSpace(name: CGColorSpace.sRGB)
        case .embeddedICC:
            // 容器扫描并重组的 ICC 是更强证据；ImageIO thumbnail 可能丢失、
            // 错标甚至退化为灰度空间。
            return inspectedColorSpace ?? image.colorSpace
        case .unknown:
            return image.colorSpace ?? inspectedColorSpace
        }
    }

    private static func imageByApplyingColorInterpretation(
        _ desiredColorSpace: CGColorSpace?,
        to image: CGImage
    ) throws -> CGImage {
        guard let desiredColorSpace else { return image }
        if Self.colorSpacesMatch(image.colorSpace, desiredColorSpace) { return image }
        if image.colorSpace?.model == desiredColorSpace.model || image.colorSpace == nil {
            return try imageByAssigningColorSpace(desiredColorSpace, to: image)
        }
        return try imageByConverting(image, to: desiredColorSpace)
    }

    private static func colorSpacesMatch(
        _ lhs: CGColorSpace?,
        _ rhs: CGColorSpace?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if CFEqual(lhs, rhs) { return true }
        return (lhs.name as String?) == (rhs.name as String?)
    }

    private static func isSRGB(_ colorSpace: CGColorSpace?) -> Bool {
        guard let colorSpace,
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        else { return false }
        return colorSpacesMatch(colorSpace, srgb)
    }

    package static func imageByAssigningColorSpace(
        _ colorSpace: CGColorSpace,
        to image: CGImage
    ) throws -> CGImage {
        guard let provider = image.dataProvider,
            let tagged = CGImage(
                width: image.width,
                height: image.height,
                bitsPerComponent: image.bitsPerComponent,
                bitsPerPixel: image.bitsPerPixel,
                bytesPerRow: image.bytesPerRow,
                space: colorSpace,
                bitmapInfo: image.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: image.shouldInterpolate,
                intent: image.renderingIntent
            )
        else {
            throw ImageCraftError.decodeFailed
        }
        return tagged
    }

    private func convertedToSRGB(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageCraftError.decodeFailed
        }
        return try Self.imageByConverting(image, to: colorSpace)
    }

    private static func imageByConverting(
        _ image: CGImage,
        to colorSpace: CGColorSpace
    ) throws -> CGImage {
        guard colorSpace.model == .rgb else {
            throw ImageCraftError.decodeFailed
        }
        let rowBytes = image.width.multipliedReportingOverflow(by: 4)
        guard !rowBytes.overflow else { throw ImageCraftError.decodeFailed }
        let alphaInfo: CGImageAlphaInfo
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            alphaInfo = .noneSkipLast
        default:
            alphaInfo = .premultipliedLast
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: alphaInfo.rawValue)
        )
        guard
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes.partialValue,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else { throw ImageCraftError.decodeFailed }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { throw ImageCraftError.decodeFailed }
        return converted
    }

    package static func serializedPropertySize(_ properties: [CFString: Any]) -> Int {
        guard PropertyListSerialization.propertyList(properties, isValidFor: .binary),
            let data = try? PropertyListSerialization.data(
                fromPropertyList: properties,
                format: .binary,
                options: 0
            )
        else { return Int.max }
        return data.count
    }

    private func auxiliaryAttachmentCount(in properties: [CFString: Any]) -> Int {
        // 图像属性字典无需实体化载荷即可公开全部辅助附件；逐类探测既会
        // 遗漏未来新增类型，也会让 Image I/O 对有效图像中每个不存在的附件
        // 分别发出错误。
        guard let attachments = properties[kCGImagePropertyAuxiliaryData] as? [Any] else {
            return 0
        }
        return attachments.count
    }

    private func sourceOptions(format: EncodedImageFormat) -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: typeIdentifier(for: format),
        ] as CFDictionary
    }

    private func typeIdentifier(for format: EncodedImageFormat) -> CFString {
        switch format {
        case .png: "public.png" as CFString
        case .jpeg: "public.jpeg" as CFString
        case .gif: "com.compuserve.gif" as CFString
        }
    }

    private func sourceFormat(_ source: CGImageSource) -> EncodedImageFormat? {
        guard let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.png": return .png
        case "public.jpeg": return .jpeg
        case "com.compuserve.gif": return .gif
        default: return nil
        }
    }

    private func orientationValue(_ value: Any?) -> UInt32 {
        let candidate: UInt32
        if let number = value as? NSNumber {
            candidate = number.uint32Value
        } else if let value = value as? UInt32 {
            candidate = value
        } else if let value = value as? Int, value >= 1 {
            candidate = UInt32(value)
        } else {
            candidate = 1
        }
        return (1...8).contains(candidate) ? candidate : 1
    }

    private func validate(width: Int, height: Int, limits: DecodeLimits) throws {
        guard width > 0, height > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
            throw ImageCraftError.dimensionLimitExceeded
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= limits.maximumPixelCount else {
            throw ImageCraftError.pixelLimitExceeded
        }
    }
}

private final class ImageIOPreparationStore: @unchecked Sendable {
    struct Entry {
        let data: Data
        let source: CGImageSource
        let probe: ImageProbe
        let sourceColorSpace: CGColorSpace?
        let limits: DecodeLimits
    }

    private static let maximumEntryCount = 1_024
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func insert(
        identifier: UUID,
        data: Data,
        source: CGImageSource,
        probe: ImageProbe,
        sourceColorSpace: CGColorSpace?,
        limits: DecodeLimits
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < Self.maximumEntryCount, entries[identifier] == nil else {
            return false
        }
        entries[identifier] = Entry(
            data: data,
            source: source,
            probe: probe,
            sourceColorSpace: sourceColorSpace,
            limits: limits
        )
        return true
    }

    func take(identifier: UUID) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.removeValue(forKey: identifier)
    }

    func remove(identifier: UUID) {
        lock.lock()
        entries.removeValue(forKey: identifier)
        lock.unlock()
    }
}

extension ImageIOImageDecoder: ProgressiveImageDecoding {
    public func makeProgressiveSession(
        format: EncodedImageFormat,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> any ImageProgressiveDecodeSession {
        let capability = ImageDecodeCapabilityRequest(
            format: format,
            deliveryMode: .progressiveGenerations
        )
        guard codecDescriptor.supports(capability), format == .jpeg else {
            throw ImageCraftError.progressiveDecodingUnsupported
        }
        guard request.colorPolicy == .preserveSource else {
            throw ImageCraftError.progressiveDecodingUnsupported
        }
        let source = CGImageSourceCreateIncremental(sourceOptions(format: format))
        return ImageIOProgressiveSession(
            decoder: self,
            source: source,
            request: request,
            limits: limits
        )
    }

    private final class ImageIOProgressiveSession: ProgressiveImageFinalizingSession,
        ProgressiveImagePreparingSession, @unchecked Sendable
    {
        private enum FrameKind {
            case unknown
            case baseline
            case progressive
        }

        private struct JPEGState {
            var frameKind: FrameKind = .unknown
            var scanCount = 0
            var completedScanCount = 0
            var foundEnd = false
            private var offset = 0
            private var insideScan = false
            private var sawStart = false

            mutating func consume(_ data: Data) throws {
                if !sawStart {
                    guard data.count >= 2 else { return }
                    guard data[0] == 0xFF, data[1] == 0xD8 else {
                        throw ImageCraftError.formatMismatch
                    }
                    sawStart = true
                    offset = 2
                }

                while offset < data.count, !foundEnd {
                    if insideScan {
                        guard consumeScanBytes(data) else { return }
                        continue
                    }
                    guard let marker = nextMarker(data) else { return }
                    switch marker.value {
                    case 0xD8:
                        throw ImageCraftError.unsupportedOrCorruptImage
                    case 0xD9:
                        foundEnd = true
                    case 0x01, 0xD0...0xD7:
                        offset = marker.payloadOffset
                    default:
                        guard let end = segmentEnd(
                            data,
                            markerStart: marker.start,
                            payloadOffset: marker.payloadOffset
                        ) else { return }
                        updateFrameKind(marker.value)
                        offset = end
                        if marker.value == 0xDA {
                            scanCount += 1
                            insideScan = true
                        }
                    }
                }
            }

            private mutating func consumeScanBytes(_ data: Data) -> Bool {
                while offset < data.count {
                    guard data[offset] == 0xFF else {
                        offset += 1
                        continue
                    }
                    let markerStart = offset
                    var cursor = offset + 1
                    while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
                    guard cursor < data.count else {
                        offset = markerStart
                        return false
                    }
                    let marker = data[cursor]
                    if marker == 0x00 || (0xD0...0xD7).contains(marker) {
                        offset = cursor + 1
                        continue
                    }
                    completedScanCount += 1
                    insideScan = false
                    offset = markerStart
                    return true
                }
                return false
            }

            private mutating func nextMarker(
                _ data: Data
            ) -> (start: Int, value: UInt8, payloadOffset: Int)? {
                while offset < data.count {
                    while offset < data.count, data[offset] != 0xFF { offset += 1 }
                    guard offset < data.count else { return nil }
                    let markerStart = offset
                    var cursor = offset + 1
                    while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
                    guard cursor < data.count else {
                        offset = markerStart
                        return nil
                    }
                    let marker = data[cursor]
                    offset = cursor + 1
                    if marker == 0x00 { continue }
                    return (markerStart, marker, cursor + 1)
                }
                return nil
            }

            private mutating func updateFrameKind(_ marker: UInt8) {
                if marker == 0xC0 {
                    frameKind = .baseline
                } else if marker == 0xC2 {
                    frameKind = .progressive
                }
            }

            private mutating func segmentEnd(
                _ data: Data,
                markerStart: Int,
                payloadOffset: Int
            ) -> Int? {
                guard payloadOffset + 1 < data.count else {
                    offset = markerStart
                    return nil
                }
                let length = Int(data[payloadOffset]) << 8 | Int(data[payloadOffset + 1])
                guard length >= 2 else {
                    offset = markerStart
                    return nil
                }
                let end = payloadOffset.addingReportingOverflow(length)
                guard !end.overflow else {
                    offset = markerStart
                    return nil
                }
                guard end.partialValue <= data.count else {
                    offset = markerStart
                    return nil
                }
                return end.partialValue
            }
        }

        private let lock = NSLock()
        private let decoder: ImageIOImageDecoder
        private let request: ImageDecodeRequest
        private let limits: DecodeLimits
        private var source: CGImageSource?
        private var data = Data()
        private var totalReceivedBytes = 0
        // 四个几何阈值把预览光栅化从 O(scanCount) 限制为常数上界；
        // 完整正文仍走独立最终解码，因此不需要在 EOI 前追逐每个细化 scan。
        private static let previewScanThresholds = [1, 2, 4, 8]

        private var jpegState = JPEGState()
        private var nextPreviewThresholdIndex = 0
        private var nextGeneration: UInt32 = 1
        private var isFinished = false
        private var isCancelled = false

        init(
            decoder: ImageIOImageDecoder,
            source: CGImageSource,
            request: ImageDecodeRequest,
            limits: DecodeLimits
        ) {
            self.decoder = decoder
            self.source = source
            self.request = request
            self.limits = limits
        }

        var receivedByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return totalReceivedBytes
        }

        func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else { throw ImageCraftError.progressiveSessionCancelled }
            guard !isFinished else { throw ImageCraftError.progressiveSessionFinished }
            guard !chunk.isEmpty else { return nil }

            let nextCount = data.count.addingReportingOverflow(chunk.count)
            guard !nextCount.overflow, nextCount.partialValue <= limits.maximumEncodedBytes else {
                throw ImageCraftError.encodedBytesExceeded
            }
            data.append(chunk)
            totalReceivedBytes = nextCount.partialValue

            try jpegState.consume(data)
            guard jpegState.frameKind != .baseline else {
                throw ImageCraftError.progressiveDecodingUnsupported
            }
            guard jpegState.frameKind == .progressive,
                !jpegState.foundEnd,
                shouldAttemptPreview(completedScanCount: jpegState.completedScanCount)
            else { return nil }

            guard let source else { throw ImageCraftError.progressiveSessionCancelled }
            CGImageSourceUpdateData(source, data as CFData, false)
            guard let image = try makePreview(source: source) else { return nil }

            let generation = nextGeneration
            let nextGeneration = generation.addingReportingOverflow(1)
            guard !nextGeneration.overflow else { throw ImageCraftError.decodeFailed }
            self.nextGeneration = nextGeneration.partialValue
            return ImageProgressiveDecodeGeneration(
                image: image,
                generation: generation,
                sourceByteCount: totalReceivedBytes
            )
        }

        func finish() throws {
            lock.lock()
            defer { lock.unlock() }
            _ = try completeSourceLocked()
        }

        func finishWithPreparation() throws -> ImageProgressiveDecodePreparationFinalization {
            lock.lock()
            defer { lock.unlock() }
            let source = try completeSourceLocked(retainingBytes: true)
            defer {
                self.source = nil
                data.removeAll(keepingCapacity: false)
            }
            let container = try decoder.inspectContainer(data: data, limits: limits)
            guard container.format == .jpeg else { throw ImageCraftError.formatMismatch }
            let metadata = try decoder.inspectImageSource(
                source: source,
                expectedFormat: .jpeg,
                limits: limits
            )
            let inspection = try decoder.makeInspection(
                container: container,
                metadata: metadata,
                limits: limits
            )
            let preparation = ImageDecodePreparation(probe: inspection.probe)
            guard decoder.preparations.insert(
                identifier: preparation.identifier,
                data: data,
                source: source,
                probe: inspection.probe,
                sourceColorSpace: inspection.sourceColorSpace,
                limits: limits
            ) else {
                throw ImageCraftError.decodeFailed
            }
            return ImageProgressiveDecodePreparationFinalization(
                preparation: preparation,
                sourceByteCount: totalReceivedBytes
            )
        }

        func finishWithFinalImage() throws -> ImageProgressiveDecodeFinalization {
            lock.lock()
            defer { lock.unlock() }
            let source = try completeSourceLocked(retainingBytes: true)
            defer {
                self.source = nil
                data.removeAll(keepingCapacity: false)
            }
            let container = try decoder.inspectContainer(data: data, limits: limits)
            guard container.format == .jpeg else { throw ImageCraftError.formatMismatch }
            let metadata = try decoder.inspectImageSource(
                source: source,
                expectedFormat: .jpeg,
                limits: limits
            )
            let inspection = try decoder.makeInspection(
                container: container,
                metadata: metadata,
                limits: limits
            )
            let image = try decoder.decode(
                source: source,
                probe: inspection.probe,
                sourceColorSpace: inspection.sourceColorSpace,
                request: request,
                limits: limits
            )
            return ImageProgressiveDecodeFinalization(
                image: image,
                probe: inspection.probe,
                sourceByteCount: totalReceivedBytes
            )
        }

        private func completeSourceLocked(retainingBytes: Bool = false) throws -> CGImageSource {
            guard !isCancelled else { throw ImageCraftError.progressiveSessionCancelled }
            guard !isFinished else { throw ImageCraftError.progressiveSessionFinished }
            isFinished = true
            do {
                try jpegState.consume(data)
                guard jpegState.frameKind == .progressive, jpegState.foundEnd, let source else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                CGImageSourceUpdateData(source, data as CFData, true)
                if !retainingBytes {
                    self.source = nil
                    data.removeAll(keepingCapacity: false)
                }
                return source
            } catch {
                self.source = nil
                data.removeAll(keepingCapacity: false)
                throw error
            }
        }

        func cancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            source = nil
            data.removeAll(keepingCapacity: false)
            lock.unlock()
        }

        private func shouldAttemptPreview(completedScanCount: Int) -> Bool {
            guard nextPreviewThresholdIndex < Self.previewScanThresholds.count,
                completedScanCount >= Self.previewScanThresholds[nextPreviewThresholdIndex]
            else { return false }
            while nextPreviewThresholdIndex < Self.previewScanThresholds.count,
                completedScanCount >= Self.previewScanThresholds[nextPreviewThresholdIndex]
            {
                nextPreviewThresholdIndex += 1
            }
            return true
        }

        private func makePreview(source: CGImageSource) throws -> DecodedImage? {
            guard CGImageSourceGetStatusAtIndex(source, 0) != .statusInvalidData,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }

            let orientation = decoder.orientationValue(properties[kCGImagePropertyOrientation])
            let swapsDimensions = (5...8).contains(orientation)
            let width = swapsDimensions ? rawHeight : rawWidth
            let height = swapsDimensions ? rawWidth : rawHeight
            let probe = try ImageProbe(
                pixelWidth: width,
                pixelHeight: height,
                frameCount: 1,
                orientation: orientation,
                format: .jpeg,
                sourceColorProfile: .unknown
            )
            try probe.validate(under: limits)
            let geometry = decoder.decodeGeometry(
                probe: probe,
                request: request,
                limits: limits
            )
            guard let raster = try? decoder.createRaster(source: source, geometry: geometry) else {
                return nil
            }
            return try decoder.finalizeDecodedImage(
                raster,
                probe: probe,
                sourceColorSpace: nil,
                request: request,
                limits: limits
            )
        }

    }
}
