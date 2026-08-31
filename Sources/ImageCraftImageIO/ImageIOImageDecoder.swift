import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

/// Package-only switch used to qualify whether prepared decode should retain framework state.
/// The public decoder uses the bounded pure-value mode; retained source exists only as an A/B
/// qualification control and must not be treated as the production resource contract.
package enum ImageIOPreparationRetentionMode: String, Codable, Sendable {
    case retainedSource
    case encodedDataOnly
}

package struct ImageIOPreparationStoreQualificationSnapshot: Equatable, Sendable {
    package let entryCount: Int
    package let reservationCount: Int
    package let maximumEntryCount: Int
    package let retainedKnownByteCharge: Int
    package let maximumRetainedKnownByteCharge: Int

    package init(
        entryCount: Int,
        reservationCount: Int,
        maximumEntryCount: Int,
        retainedKnownByteCharge: Int,
        maximumRetainedKnownByteCharge: Int
    ) {
        self.entryCount = entryCount
        self.reservationCount = reservationCount
        self.maximumEntryCount = maximumEntryCount
        self.retainedKnownByteCharge = retainedKnownByteCharge
        self.maximumRetainedKnownByteCharge = maximumRetainedKnownByteCharge
    }
}

/// 基于 ImageIO、支持目标尺寸的光栅图像探测与解码器。

public struct ImageIOImageDecoder: ImageCodec, InstrumentedPreparedImageDecoding,
    PreparedImageResourceInspecting, PreparedImageCreationResourceInspecting
{
    private let preparations: ImageIOPreparationStore
    private let preparationRetentionMode: ImageIOPreparationRetentionMode
    private let outputMaterializationMode: ImageIOOutputMaterializationMode

    /// 当前 Image I/O 适配器只承诺完整主帧、SDR 和 Core Graphics 输出。
    /// GIF 多帧容器可以被安全探测，但该适配器尚未公开动画时间轴语义。
    public let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "dev.fovea.imageio"),
        implementationVersion: 5,
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

    /// 使用默认 prepared-store 聚合预算创建 Image I/O 解码器。
    public init() {
        self.init(preparationLimits: .coreV1)
    }

    /// 使用独立于单输入 `DecodeLimits` 的 prepared-store 聚合预算创建解码器。
    public init(preparationLimits: ImageDecodePreparationLimits) {
        self.preparations = ImageIOPreparationStore(limits: preparationLimits)
        self.preparationRetentionMode = .encodedDataOnly
        self.outputMaterializationMode = .frameworkNative
    }

    /// Qualification-only initializer for comparing opaque source reuse with bounded data-only
    /// retention. This is intentionally not public API.
    package init(
        qualificationPreparationRetentionMode: ImageIOPreparationRetentionMode,
        preparationLimits: ImageDecodePreparationLimits = .coreV1,
        outputMaterializationMode: ImageIOOutputMaterializationMode = .frameworkNative
    ) {
        self.preparations = ImageIOPreparationStore(limits: preparationLimits)
        self.preparationRetentionMode = qualificationPreparationRetentionMode
        self.outputMaterializationMode = outputMaterializationMode
    }

    package func preparationStoreQualificationSnapshot()
        -> ImageIOPreparationStoreQualificationSnapshot
    {
        preparations.qualificationSnapshot()
    }

    /// 检查有界编码数据，但不分配最终光栅缓冲区。
    public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try inspect(data: data, limits: limits).probe
    }

    public func preparationCreationResourceAuthority(
        data: Data,
        limits: DecodeLimits
    ) throws -> ImageDecodePreparationCreationResourceAuthority {
        guard data.count <= limits.maximumEncodedBytes else {
            throw ImageCraftError.encodedBytesExceeded
        }
        // Reuse the package's pure-value security scanner, but deliberately avoid ICC
        // materialization. This preflight may validate/scan the encoded value, but it must not
        // create ImageIO framework state merely to decide whether a later creation operation is
        // hard-admissible.
        let securityInspection = try EncodedImageSecurityInspector.inspect(
            data,
            maximumMetadataBytes: limits.maximumMetadataBytes,
            materializePNGICCProfile: false,
            materializeJPEGICCProfile: false
        )
        guard limits.allowedFormats.contains(securityInspection.format) else {
            throw ImageCraftError.unsupportedFormat
        }

        let operationLedger = ImageDecodeResourceLedgerSnapshot(
            retainedKnownBytes: 0,
            retainedBetweenCalls: .bounded(0),
            operationPeak: .unknown(.frameworkPrivateOperationAllocation),
            transferredOutput: .bounded(0),
            outputLayoutAuthority: .none
        )!
        var resultingKnownBytes = data.count
        let resultingRetained: ImageDecodeResourceBound
        switch preparationRetentionMode {
        case .retainedSource:
            resultingRetained = .unknown(.frameworkPrivateRetainedState)
        case .encodedDataOnly:
            if securityInspection.sourceColorProfile == .embeddedICC {
                if let exactICCBytes = securityInspection.embeddedICCProfileByteCount {
                    resultingKnownBytes = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
                        data.count,
                        exactICCBytes
                    )
                    resultingRetained = .bounded(resultingKnownBytes)
                } else {
                    resultingRetained = .bounded(
                        ImageDecodeResourceLedgerSnapshot.saturatedAdding(
                            data.count,
                            limits.maximumMetadataBytes
                        )
                    )
                }
            } else {
                resultingRetained = .bounded(data.count)
            }
        }
        guard let authority = ImageDecodePreparationCreationResourceAuthority(
            operationResourceLedger: operationLedger,
            resultingPreparationRetainedKnownBytes: resultingKnownBytes,
            resultingPreparationRetainedBetweenCalls: resultingRetained
        ) else { throw ImageCraftError.decodeFailed }
        return authority
    }

    /// 安全探测输入并保留一次性可复用的纯值容器事实；底层 ImageIO source 不跨调用驻留。
    public func prepare(
        data: Data,
        limits: DecodeLimits
    ) throws -> ImageDecodePreparation {
        guard data.count <= limits.maximumEncodedBytes else {
            throw ImageCraftError.encodedBytesExceeded
        }
        let identifier = UUID()
        try preparations.reserve(identifier: identifier, knownByteCharge: data.count)
        do {
            let securityInspection = try inspectContainer(data: data, limits: limits)
            try extendPreparedReservation(
                identifier: identifier,
                securityInspection: securityInspection
            )
            let metadata = try inspectImageSource(
                data: data,
                expectedFormat: securityInspection.format,
                limits: limits
            )
            let inspection = try makeInspection(
                container: securityInspection,
                metadata: metadata,
                limits: limits
            )
            let preparation = ImageDecodePreparation(
                identifier: identifier,
                probe: inspection.probe
            )
            try preparations.commitReservation(
                identifier: identifier,
                data: data,
                source: inspection.source,
                probe: inspection.probe,
                sourceColorSpace: inspection.sourceColorSpace,
                securityInspection: inspection.container,
                limits: limits,
                retentionMode: preparationRetentionMode
            )
            return preparation
        } catch {
            preparations.cancelReservation(identifier: identifier)
            throw error
        }
    }

    package func prepareWithDiagnostics(
        data: Data,
        limits: DecodeLimits
    ) throws -> InstrumentedImageDecodePreparation {
        guard data.count <= limits.maximumEncodedBytes else {
            throw ImageCraftError.encodedBytesExceeded
        }
        let identifier = UUID()
        try preparations.reserve(identifier: identifier, knownByteCharge: data.count)
        do {
            let containerStarted = DispatchTime.now().uptimeNanoseconds
            let securityInspection = try inspectContainer(data: data, limits: limits)
            let containerDuration = DispatchTime.now().uptimeNanoseconds &- containerStarted
            try extendPreparedReservation(
                identifier: identifier,
                securityInspection: securityInspection
            )
            let result = try inspectWithDiagnostics(
                data: data,
                securityInspection: securityInspection,
                limits: limits,
                containerInspectionNanoseconds: containerDuration
            )
            let preparation = ImageDecodePreparation(
                identifier: identifier,
                probe: result.inspection.probe
            )
            try preparations.commitReservation(
                identifier: identifier,
                data: data,
                source: result.inspection.source,
                probe: result.inspection.probe,
                sourceColorSpace: result.inspection.sourceColorSpace,
                securityInspection: result.inspection.container,
                limits: limits,
                retentionMode: preparationRetentionMode
            )
            return InstrumentedImageDecodePreparation(
                preparation: preparation,
                diagnostics: result.diagnostics
            )
        } catch {
            preparations.cancelReservation(identifier: identifier)
            throw error
        }
    }

    private func extendPreparedReservation(
        identifier: UUID,
        securityInspection: EncodedImageSecurityInspection
    ) throws {
        switch preparationRetentionMode {
        case .retainedSource:
            return
        case .encodedDataOnly:
            try preparations.extendReservation(
                identifier: identifier,
                additionalKnownByteCharge: securityInspection.embeddedICCProfile?.count ?? 0
            )
        }
    }

    /// 消费 preparation，复用已验证容器事实并重建短生命周期 ImageIO source 完成目标解码。
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
        switch entry.retention {
        case .retainedSource(let source, let sourceColorSpace):
            return try decode(
                source: source,
                probe: entry.probe,
                sourceColorSpace: sourceColorSpace,
                request: request,
                limits: limits
            )
        case .encodedDataOnly(let securityInspection):
            let inspection = try inspect(
                data: entry.data,
                securityInspection: securityInspection,
                limits: limits
            )
            guard inspection.probe == entry.probe else { throw ImageCraftError.probeMismatch }
            return try decode(
                source: inspection.source,
                probe: inspection.probe,
                sourceColorSpace: inspection.sourceColorSpace,
                request: request,
                limits: limits
            )
        }
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

        let source: CGImageSource
        let probe: ImageProbe
        let sourceColorSpace: CGColorSpace?
        let repeatedPreparationDiagnostics: ImageDecodePreparationDiagnostics?
        switch entry.retention {
        case .retainedSource(let retainedSource, let retainedSourceColorSpace):
            // preparation 已经完成容器、类型、帧数和属性验证；一次性令牌直接复用
            // 同一个不可变 CGImageSource，避免第二次解析和第二次数据源构造。
            source = retainedSource
            probe = entry.probe
            sourceColorSpace = retainedSourceColorSpace
            repeatedPreparationDiagnostics = nil
        case .encodedDataOnly(let securityInspection):
            // Resource-bounded qualification mode deliberately releases CGImageSource after
            // prepare. Decode recreates framework source state, but reuses the already-validated
            // pure-value container inspection bound to the store-owned immutable Data value.
            let result = try inspectWithDiagnostics(
                data: entry.data,
                securityInspection: securityInspection,
                limits: limits
            )
            guard result.inspection.probe == entry.probe else {
                throw ImageCraftError.probeMismatch
            }
            source = result.inspection.source
            probe = result.inspection.probe
            sourceColorSpace = result.inspection.sourceColorSpace
            repeatedPreparationDiagnostics = result.diagnostics
        }

        let geometry = decodeGeometry(probe: probe, request: request, limits: limits)
        let rasterStarted = DispatchTime.now().uptimeNanoseconds
        let raster = try createRaster(source: source, geometry: geometry)
        let rasterDuration = DispatchTime.now().uptimeNanoseconds &- rasterStarted

        let postProcessingStarted = DispatchTime.now().uptimeNanoseconds
        let image = try finalizeDecodedImage(
            raster,
            probe: probe,
            sourceColorSpace: sourceColorSpace,
            request: request,
            limits: limits
        )
        let postProcessingDuration =
            DispatchTime.now().uptimeNanoseconds &- postProcessingStarted
        return InstrumentedDecodedImage(
            image: image,
            diagnostics: ImageDecodeExecutionDiagnostics(
                repeatedPreparationDiagnostics: repeatedPreparationDiagnostics,
                sourceCreationNanoseconds:
                    repeatedPreparationDiagnostics?.imageSourceCreationNanoseconds ?? 0,
                sourceTypeNanoseconds:
                    repeatedPreparationDiagnostics?.imageSourceTypeNanoseconds ?? 0,
                frameCountNanoseconds:
                    repeatedPreparationDiagnostics?.imageFrameCountNanoseconds ?? 0,
                rasterCreationNanoseconds: rasterDuration,
                postProcessingNanoseconds: postProcessingDuration
            )
        )
    }

    /// 释放尚未消费的 ImageIO preparation；重复调用安全无效。
    public func discard(_ preparation: ImageDecodePreparation) {
        preparations.remove(identifier: preparation.identifier)
    }

    public func preparationResourceLedger(
        _ preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) -> ImageDecodeResourceLedgerSnapshot? {
        guard let entry = preparations.peek(identifier: preparation.identifier),
            entry.probe == preparation.probe,
            entry.limits == limits
        else { return nil }
        let retainedBound: ImageDecodeResourceBound
        switch entry.retention {
        case .retainedSource:
            retainedBound = .unknown(.frameworkPrivateRetainedState)
        case .encodedDataOnly:
            retainedBound = .bounded(entry.retainedKnownByteCharge)
        }
        let transferredOutput: ImageDecodeResourceBound
        switch outputMaterializationMode {
        case .frameworkNative:
            transferredOutput = .unknown(.frameworkChosenOutputLayout)
        case .ownedRGBA8:
            transferredOutput = ownedOutputTransferBound(entry: entry, request: request)
        }
        return ImageDecodeResourceLedgerSnapshot(
            retainedKnownBytes: entry.retainedKnownByteCharge,
            retainedBetweenCalls: retainedBound,
            operationPeak: .unknown(.frameworkPrivateOperationAllocation),
            transferredOutput: transferredOutput,
            outputLayoutAuthority:
                outputMaterializationMode == .ownedRGBA8 ? .codecOwnedRGBA8 : .frameworkChosen
        )
    }

    private func ownedOutputTransferBound(
        entry: ImageIOPreparationStore.Entry,
        request: ImageDecodeRequest
    ) -> ImageDecodeResourceBound {
        let pixelCharge = ImageIOOwnedRGBAOutputMaterializer.maximumPayloadByteCharge(
            probe: entry.probe,
            request: request
        )
        switch request.colorPolicy {
        case .convertToSRGB:
            return .bounded(pixelCharge)
        case .preserveSource:
            switch entry.probe.sourceColorProfile {
            case .absent, .standardSRGB:
                return .bounded(pixelCharge)
            case .embeddedICC:
                guard case .encodedDataOnly(let securityInspection) = entry.retention,
                    let profile = securityInspection.embeddedICCProfile
                else {
                    return .unknown(.frameworkChosenOutputColorState)
                }
                return .bounded(
                    ImageDecodeResourceLedgerSnapshot.saturatedAdding(
                        pixelCharge,
                        profile.count
                    )
                )
            case .unknown:
                return .unknown(.frameworkChosenOutputColorState)
            }
        }
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

    /// Package-only packed-pixel producer. `ImagePackedRGBA8` value semantics are independently
    /// cross-backend qualified; producer rollout remains separate until a public packed-output
    /// capability/descriptor can preserve this backend's resource authority instead of bypassing it.
    package func decodePackedRGBA8(
        data: Data,
        request: ImageDecodeRequest,
        limits: DecodeLimits = .coreV1
    ) throws -> ImagePackedRGBA8 {
        let inspection = try inspect(data: data, limits: limits)
        let geometry = decodeGeometry(probe: inspection.probe, request: request, limits: limits)
        let raster = try createRaster(source: inspection.source, geometry: geometry)
        let image = try finalizeDecodedImage(
            raster,
            probe: inspection.probe,
            sourceColorSpace: inspection.sourceColorSpace,
            request: request,
            limits: limits,
            materializationMode: .frameworkNative
        )
        return try ImageIOOwnedRGBAOutputMaterializer.materializePacked(
            image,
            colorEncoding: try packedColorEncoding(
                sourceProfile: inspection.probe.sourceColorProfile,
                embeddedICCProfile: inspection.container.embeddedICCProfile,
                policy: request.colorPolicy
            )
        )
    }

    private func packedColorEncoding(
        sourceProfile: SourceColorProfile,
        embeddedICCProfile: Data?,
        policy: ImageColorPolicy
    ) throws -> ImagePackedPixelColorEncoding {
        switch policy {
        case .convertToSRGB:
            return .sRGB
        case .preserveSource:
            switch sourceProfile {
            case .absent, .standardSRGB:
                return .sRGB
            case .embeddedICC:
                guard let embeddedICCProfile else {
                    throw ImagePackedPixelContractError.invalidBuffer
                }
                return .embeddedICC(embeddedICCProfile)
            case .unknown:
                throw ImagePackedPixelContractError.unclassifiedColorState
            }
        }
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
        limits: DecodeLimits,
        materializationMode: ImageIOOutputMaterializationMode? = nil
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
            return try materializeOutputIfNeeded(
                DecodedImage(cgImage: image, sourceColorProfile: probe.sourceColorProfile),
                mode: materializationMode ?? outputMaterializationMode
            )
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
            return try materializeOutputIfNeeded(
                DecodedImage(cgImage: cropped, sourceColorProfile: probe.sourceColorProfile),
                mode: materializationMode ?? outputMaterializationMode
            )
        }
    }

    private func materializeOutputIfNeeded(
        _ image: DecodedImage,
        mode: ImageIOOutputMaterializationMode
    ) throws -> DecodedImage {
        switch mode {
        case .frameworkNative:
            return image
        case .ownedRGBA8:
            return try ImageIOOwnedRGBAOutputMaterializer.materialize(image)
        }
    }

    private struct Inspection {
        let container: EncodedImageSecurityInspection
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

    private func inspect(
        data: Data,
        securityInspection: EncodedImageSecurityInspection,
        limits: DecodeLimits
    ) throws -> Inspection {
        try validatePreparedSecurityInspection(
            securityInspection,
            dataByteCount: data.count,
            limits: limits
        )
        let metadata = try inspectImageSource(
            data: data,
            expectedFormat: securityInspection.format,
            limits: limits
        )
        return try makeInspection(
            container: securityInspection,
            metadata: metadata,
            limits: limits
        )
    }

    private func inspectWithDiagnostics(
        data: Data,
        limits: DecodeLimits
    ) throws -> InstrumentedInspection {
        let containerStarted = DispatchTime.now().uptimeNanoseconds
        let securityInspection = try inspectContainer(data: data, limits: limits)
        let containerDuration = DispatchTime.now().uptimeNanoseconds &- containerStarted
        return try inspectWithDiagnostics(
            data: data,
            securityInspection: securityInspection,
            limits: limits,
            containerInspectionNanoseconds: containerDuration
        )
    }

    private func inspectWithDiagnostics(
        data: Data,
        securityInspection: EncodedImageSecurityInspection,
        limits: DecodeLimits
    ) throws -> InstrumentedInspection {
        try validatePreparedSecurityInspection(
            securityInspection,
            dataByteCount: data.count,
            limits: limits
        )
        return try inspectWithDiagnostics(
            data: data,
            securityInspection: securityInspection,
            limits: limits,
            containerInspectionNanoseconds: 0
        )
    }

    private func inspectWithDiagnostics(
        data: Data,
        securityInspection: EncodedImageSecurityInspection,
        limits: DecodeLimits,
        containerInspectionNanoseconds: UInt64
    ) throws -> InstrumentedInspection {
        let creationStarted = DispatchTime.now().uptimeNanoseconds
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, sourceOptions(format: securityInspection.format))
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        let creationDuration = DispatchTime.now().uptimeNanoseconds &- creationStarted

        let sourceTypeStarted = DispatchTime.now().uptimeNanoseconds
        guard sourceFormat(source) == securityInspection.format else {
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
            container: securityInspection,
            metadata: metadata,
            limits: limits
        )
        let validationDuration = DispatchTime.now().uptimeNanoseconds &- validationStarted
        return InstrumentedInspection(
            inspection: inspection,
            diagnostics: ImageDecodePreparationDiagnostics(
                containerInspectionNanoseconds: containerInspectionNanoseconds,
                imageSourceCreationNanoseconds: creationDuration,
                imageSourceTypeNanoseconds: sourceTypeDuration,
                imageFrameCountNanoseconds: frameCountDuration,
                imagePropertiesReadNanoseconds: propertiesDuration,
                probeValidationNanoseconds: validationDuration
            )
        )
    }

    private func validatePreparedSecurityInspection(
        _ securityInspection: EncodedImageSecurityInspection,
        dataByteCount: Int,
        limits: DecodeLimits
    ) throws {
        guard dataByteCount <= limits.maximumEncodedBytes else {
            throw ImageCraftError.encodedBytesExceeded
        }
        guard limits.allowedFormats.contains(securityInspection.format) else {
            throw ImageCraftError.unsupportedFormat
        }
        guard securityInspection.metadataByteCount <= limits.maximumMetadataBytes else {
            throw ImageCraftError.metadataLimitExceeded
        }
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
            container: container,
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
    enum Retention {
        case retainedSource(CGImageSource, CGColorSpace?)
        case encodedDataOnly(EncodedImageSecurityInspection)
    }

    struct Entry {
        let data: Data
        let probe: ImageProbe
        let limits: DecodeLimits
        let retention: Retention
        let retainedKnownByteCharge: Int
    }

    private let lock = NSLock()
    private let limits: ImageDecodePreparationLimits
    private var entries: [UUID: Entry] = [:]
    private var reservations: [UUID: Int] = [:]
    private var retainedKnownByteCharge = 0

    init(limits: ImageDecodePreparationLimits) {
        self.limits = limits
    }

    func reserve(identifier: UUID, knownByteCharge: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard knownByteCharge > 0,
            entries[identifier] == nil,
            reservations[identifier] == nil
        else { throw ImageCraftError.decodeFailed }
        let nextCharge = retainedKnownByteCharge.addingReportingOverflow(knownByteCharge)
        guard entries.count + reservations.count < limits.maximumEntryCount,
            !nextCharge.overflow,
            nextCharge.partialValue <= limits.maximumRetainedByteCharge
        else { throw ImageCraftError.preparedStateBudgetExceeded }
        reservations[identifier] = knownByteCharge
        retainedKnownByteCharge = nextCharge.partialValue
    }

    func extendReservation(identifier: UUID, additionalKnownByteCharge: Int) throws {
        guard additionalKnownByteCharge >= 0 else { throw ImageCraftError.decodeFailed }
        guard additionalKnownByteCharge > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let current = reservations[identifier] else { throw ImageCraftError.decodeFailed }
        let extended = current.addingReportingOverflow(additionalKnownByteCharge)
        let nextCharge = retainedKnownByteCharge.addingReportingOverflow(additionalKnownByteCharge)
        guard !extended.overflow,
            !nextCharge.overflow,
            nextCharge.partialValue <= limits.maximumRetainedByteCharge
        else { throw ImageCraftError.preparedStateBudgetExceeded }
        reservations[identifier] = extended.partialValue
        retainedKnownByteCharge = nextCharge.partialValue
    }

    func cancelReservation(identifier: UUID) {
        lock.lock()
        if let charge = reservations.removeValue(forKey: identifier) {
            retainedKnownByteCharge -= charge
        }
        lock.unlock()
    }

    func commitReservation(
        identifier: UUID,
        data: Data,
        source: CGImageSource,
        probe: ImageProbe,
        sourceColorSpace: CGColorSpace?,
        securityInspection: EncodedImageSecurityInspection,
        limits: DecodeLimits,
        retentionMode: ImageIOPreparationRetentionMode
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let reservedCharge = reservations[identifier], entries[identifier] == nil
        else { throw ImageCraftError.decodeFailed }
        let expectedCharge: Int
        do {
            expectedCharge = try Self.knownByteCharge(
                data: data,
                securityInspection: securityInspection,
                retentionMode: retentionMode
            )
        } catch {
            reservations.removeValue(forKey: identifier)
            retainedKnownByteCharge -= reservedCharge
            throw error
        }
        guard expectedCharge == reservedCharge else {
            reservations.removeValue(forKey: identifier)
            retainedKnownByteCharge -= reservedCharge
            throw ImageCraftError.decodeFailed
        }
        reservations.removeValue(forKey: identifier)
        entries[identifier] = Entry(
            data: data,
            probe: probe,
            limits: limits,
            retention: Self.retention(
                source: source,
                sourceColorSpace: sourceColorSpace,
                securityInspection: securityInspection,
                mode: retentionMode
            ),
            retainedKnownByteCharge: reservedCharge
        )
    }

    func insert(
        identifier: UUID,
        data: Data,
        source: CGImageSource,
        probe: ImageProbe,
        sourceColorSpace: CGColorSpace?,
        securityInspection: EncodedImageSecurityInspection,
        limits: DecodeLimits,
        retentionMode: ImageIOPreparationRetentionMode
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let entryCharge = try Self.knownByteCharge(
            data: data,
            securityInspection: securityInspection,
            retentionMode: retentionMode
        )
        let nextCharge = retainedKnownByteCharge.addingReportingOverflow(entryCharge)
        guard entries[identifier] == nil, reservations[identifier] == nil else {
            throw ImageCraftError.decodeFailed
        }
        guard entries.count + reservations.count < self.limits.maximumEntryCount,
            !nextCharge.overflow,
            nextCharge.partialValue <= self.limits.maximumRetainedByteCharge
        else {
            throw ImageCraftError.preparedStateBudgetExceeded
        }
        entries[identifier] = Entry(
            data: data,
            probe: probe,
            limits: limits,
            retention: Self.retention(
                source: source,
                sourceColorSpace: sourceColorSpace,
                securityInspection: securityInspection,
                mode: retentionMode
            ),
            retainedKnownByteCharge: entryCharge
        )
        retainedKnownByteCharge = nextCharge.partialValue
    }

    private static func knownByteCharge(
        data: Data,
        securityInspection: EncodedImageSecurityInspection,
        retentionMode: ImageIOPreparationRetentionMode
    ) throws -> Int {
        let extraKnownBytes: Int
        switch retentionMode {
        case .retainedSource:
            extraKnownBytes = 0
        case .encodedDataOnly:
            extraKnownBytes = securityInspection.embeddedICCProfile?.count ?? 0
        }
        let value = data.count.addingReportingOverflow(extraKnownBytes)
        guard !value.overflow else { throw ImageCraftError.preparedStateBudgetExceeded }
        return value.partialValue
    }

    private static func retention(
        source: CGImageSource,
        sourceColorSpace: CGColorSpace?,
        securityInspection: EncodedImageSecurityInspection,
        mode: ImageIOPreparationRetentionMode
    ) -> Retention {
        switch mode {
        case .retainedSource:
            return .retainedSource(source, sourceColorSpace)
        case .encodedDataOnly:
            return .encodedDataOnly(securityInspection)
        }
    }

    func take(identifier: UUID) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: identifier) else { return nil }
        retainedKnownByteCharge -= entry.retainedKnownByteCharge
        return entry
    }

    func remove(identifier: UUID) {
        lock.lock()
        if let entry = entries.removeValue(forKey: identifier) {
            retainedKnownByteCharge -= entry.retainedKnownByteCharge
        }
        lock.unlock()
    }

    func peek(identifier: UUID) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[identifier]
    }

    func qualificationSnapshot() -> ImageIOPreparationStoreQualificationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ImageIOPreparationStoreQualificationSnapshot(
            entryCount: entries.count,
            reservationCount: reservations.count,
            maximumEntryCount: limits.maximumEntryCount,
            retainedKnownByteCharge: retainedKnownByteCharge,
            maximumRetainedKnownByteCharge: limits.maximumRetainedByteCharge
        )
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
        return ImageIOProgressiveSession(
            decoder: self,
            request: request,
            limits: limits
        )
    }

    private final class ImageIOProgressiveSession: ProgressiveImageFinalizingSession,
        ProgressiveImageDecodedImageResourceFinalizingSession,
        ProgressiveImagePreparationResourceInspectingSession,
        ProgressiveImagePreparationCreationResourceInspectingSession,
        ProgressiveImageEarlyPreparingSession, ImageProgressiveSessionQualifying, @unchecked Sendable
    {
        private enum FrameKind {
            case unknown
            case baseline
            case progressive
        }

        private struct JPEGState {
            private static let iccSignature = Array("ICC_PROFILE\u{0}".utf8)

            var frameKind: FrameKind = .unknown
            var scanCount = 0
            var completedScanCount = 0
            var foundEnd = false
            var embeddedICCProfileByteCount: Int { iccChunkCount == nil ? 0 : iccPayloadBytes }
            private var offset = 0
            private var insideScan = false
            private var sawStart = false
            private var iccChunkCount: Int?
            private var iccSeenCount = 0
            private var iccPayloadBytes = 0
            private var iccSeen0: UInt64 = 0
            private var iccSeen1: UInt64 = 0
            private var iccSeen2: UInt64 = 0
            private var iccSeen3: UInt64 = 0

            var consumedThrough: Int { offset }

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
                        try validateICCCompletion()
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
                        if marker.value == 0xE2 {
                            try recordICCChunk(
                                data,
                                payloadStart: marker.payloadOffset + 2,
                                segmentEnd: end
                            )
                        }
                        offset = end
                        if marker.value == 0xDA {
                            scanCount += 1
                            guard scanCount <= EncodedImageSecurityInspector.maximumJPEGScanCount else {
                                throw ImageCraftError.unsupportedOrCorruptImage
                            }
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

            private mutating func recordICCChunk(
                _ data: Data,
                payloadStart: Int,
                segmentEnd: Int
            ) throws {
                guard payloadStart >= 0, segmentEnd >= payloadStart else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                guard segmentEnd - payloadStart >= Self.iccSignature.count else { return }
                for index in Self.iccSignature.indices {
                    guard data[payloadStart + index] == Self.iccSignature[index] else { return }
                }

                let headerEnd = payloadStart + Self.iccSignature.count + 2
                guard headerEnd <= segmentEnd else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                let sequence = Int(data[payloadStart + Self.iccSignature.count])
                let count = Int(data[payloadStart + Self.iccSignature.count + 1])
                guard count > 0, sequence > 0, sequence <= count else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                if let existing = iccChunkCount {
                    guard existing == count else {
                        throw ImageCraftError.unsupportedOrCorruptImage
                    }
                } else {
                    iccChunkCount = count
                }
                guard markICCSequenceIfNew(sequence) else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }

                let chunkBytes = segmentEnd - headerEnd
                let nextTotal = iccPayloadBytes.addingReportingOverflow(chunkBytes)
                guard !nextTotal.overflow else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                iccPayloadBytes = nextTotal.partialValue
                iccSeenCount += 1
            }

            private mutating func markICCSequenceIfNew(_ sequence: Int) -> Bool {
                let bitIndex = sequence - 1
                let wordIndex = bitIndex / 64
                let mask = UInt64(1) << UInt64(bitIndex % 64)
                switch wordIndex {
                case 0:
                    guard iccSeen0 & mask == 0 else { return false }
                    iccSeen0 |= mask
                case 1:
                    guard iccSeen1 & mask == 0 else { return false }
                    iccSeen1 |= mask
                case 2:
                    guard iccSeen2 & mask == 0 else { return false }
                    iccSeen2 |= mask
                case 3:
                    guard iccSeen3 & mask == 0 else { return false }
                    iccSeen3 |= mask
                default:
                    return false
                }
                return true
            }

            private func validateICCCompletion() throws {
                guard let count = iccChunkCount else { return }
                guard iccSeenCount == count, iccPayloadBytes > 0 else {
                    throw ImageCraftError.unsupportedOrCorruptImage
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
        private let modeledOwnedOperationBytes: Int
        private let maximumTightRGBABytes: Int
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
        private var hasProducedPreview = false
        private var finalFactsStable = false
        private var lastProgress: ImageProgressiveQualificationProgress = .needMoreInput

        init(
            decoder: ImageIOImageDecoder,
            request: ImageDecodeRequest,
            limits: DecodeLimits
        ) {
            self.decoder = decoder
            self.request = request
            self.limits = limits
            let decodeBytes = ImageDecodeWorkingSetEstimator.maximumModeledPixelWorkingSetBytes(
                limits: limits
            )
            let operationBytes = limits.maximumEncodedBytes.addingReportingOverflow(decodeBytes)
            self.modeledOwnedOperationBytes =
                operationBytes.overflow ? Int.max : operationBytes.partialValue
            self.maximumTightRGBABytes =
                ImageDecodeWorkingSetEstimator.maximumTightRGBABytes(limits: limits)
        }

        var receivedByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return totalReceivedBytes
        }

        var qualificationSnapshot: ImageProgressiveQualificationSnapshot {
            lock.lock()
            defer { lock.unlock() }
            let allFacts = Set(ImageProgressiveSemanticFact.allCases)
            let stableFacts = finalFactsStable ? allFacts : []
            let tentativeFacts = hasProducedPreview && !finalFactsStable ? allFacts : []
            let semanticState: ImageProgressivePreviewSemanticState
            if finalFactsStable {
                semanticState = .finalStable
            } else if hasProducedPreview {
                semanticState = .provisionalNoncacheable
            } else {
                semanticState = .none
            }
            let resourceLedger: ImageDecodeResourceLedgerSnapshot
            if lastProgress == .terminal {
                resourceLedger = .terminal
            } else {
                resourceLedger = activeResourceLedgerLocked()
            }
            return ImageProgressiveQualificationSnapshot(
                inputProfile: jpegState.frameKind == .progressive ? .arbitraryChunk : nil,
                progress: lastProgress,
                receivedByteCount: totalReceivedBytes,
                consumedThrough: jpegState.consumedThrough,
                retainFrom: 0,
                retainedEncodedBytes: data.count,
                maximumRetainedEncodedBytes: limits.maximumEncodedBytes,
                modeledOwnedOperationBytes: modeledOwnedOperationBytes,
                maximumTightRGBABytes: maximumTightRGBABytes,
                retainsOpaqueFrameworkStateBetweenCalls: false,
                resourceLedger: resourceLedger,
                stableFacts: stableFacts,
                tentativeFacts: tentativeFacts,
                previewSemanticState: semanticState
            )
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

            do {
                try jpegState.consume(data)
                guard !jpegState.foundEnd || jpegState.consumedThrough == data.count else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                guard jpegState.frameKind != .baseline else {
                    throw ImageCraftError.progressiveDecodingUnsupported
                }
                lastProgress = jpegState.foundEnd ? .finalReady : .madeProgress
                guard jpegState.frameKind == .progressive,
                    !jpegState.foundEnd,
                    shouldAttemptPreview(completedScanCount: jpegState.completedScanCount)
                else { return nil }

                // 不跨 append 保留 ImageIO 的不透明 incremental state。需要预览时从当前
                // 完整前缀重建临时 source；retained scan-checkpoint evidence 已证明 fresh 与
                // sequential incremental source 在受测 progressive JPEG checkpoint 上像素一致。
                let source = makeSource(isFinal: false)
                guard let image = try makePreview(source: source) else { return nil }
                hasProducedPreview = true

                let generation = nextGeneration
                let nextGeneration = generation.addingReportingOverflow(1)
                guard !nextGeneration.overflow else { throw ImageCraftError.decodeFailed }
                self.nextGeneration = nextGeneration.partialValue
                return ImageProgressiveDecodeGeneration(
                    image: image,
                    generation: generation,
                    sourceByteCount: totalReceivedBytes
                )
            } catch {
                // Once bytes have been accepted into this session, a parser/capability/output invariant
                // failure is not a retryable admission decision. Make the failure terminal immediately so
                // the session cannot retain governed input indefinitely or accept a contradictory suffix.
                transitionToTerminalFailureLocked()
                throw error
            }
        }

        func finish() throws {
            lock.lock()
            defer { lock.unlock() }
            _ = try completeSourceLocked()
            lastProgress = .terminal
        }

        func finishWithPreparation() throws -> ImageProgressiveDecodePreparationFinalization {
            lock.lock()
            defer { lock.unlock() }
            return try finishWithPreparationLocked()
        }

        func preparationFinalizationResourceLedger() throws
            -> ImageDecodeResourceLedgerSnapshot?
        {
            lock.lock()
            defer { lock.unlock() }
            return try preparationCreationResourceAuthorityLocked()?.operationResourceLedger
        }

        func preparationCreationResourceAuthority() throws
            -> ImageProgressivePreparationCreationResourceAuthority?
        {
            lock.lock()
            defer { lock.unlock() }
            return try preparationCreationResourceAuthorityLocked()
        }

        private func preparationCreationResourceAuthorityLocked() throws
            -> ImageProgressivePreparationCreationResourceAuthority?
        {
            guard !isCancelled else { throw ImageCraftError.progressiveSessionCancelled }
            guard !isFinished else { throw ImageCraftError.progressiveSessionFinished }
            guard jpegState.frameKind == .progressive,
                jpegState.foundEnd,
                lastProgress == .finalReady
            else { return nil }
            let resultingKnownBytes = try preparationRetainedKnownByteChargeLocked()
            let resultingRetained: ImageDecodeResourceBound
            switch decoder.preparationRetentionMode {
            case .retainedSource:
                resultingRetained = .unknown(.frameworkPrivateRetainedState)
            case .encodedDataOnly:
                resultingRetained = .bounded(resultingKnownBytes)
            }
            let operationLedger = ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: data.count,
                retainedBetweenCalls: .bounded(data.count),
                operationPeak: .unknown(.frameworkPrivateOperationAllocation),
                transferredOutput: .bounded(0),
                outputLayoutAuthority: .none
            )!
            guard let authority = ImageProgressivePreparationCreationResourceAuthority(
                operationResourceLedger: operationLedger,
                resultingPreparationRetainedKnownBytes: resultingKnownBytes,
                resultingPreparationRetainedBetweenCalls: resultingRetained
            ) else { throw ImageCraftError.decodeFailed }
            return authority
        }

        func finishWithPreparationIfComplete() throws
            -> ImageProgressiveDecodePreparationFinalization?
        {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else { throw ImageCraftError.progressiveSessionCancelled }
            guard !isFinished else { throw ImageCraftError.progressiveSessionFinished }
            try jpegState.consume(data)
            lastProgress = jpegState.foundEnd ? .finalReady : .needMoreInput
            guard jpegState.foundEnd else { return nil }
            return try finishWithPreparationLocked()
        }

        private func finishWithPreparationLocked() throws
            -> ImageProgressiveDecodePreparationFinalization
        {
            let identifier = UUID()
            let reservedKnownBytes = try preparationRetainedKnownByteChargeLocked()
            // Aggregate prepared-store admission is intentionally before completeSourceLocked() or
            // any ImageIO/security reinspection. A store-budget miss is therefore retryable: the
            // caller may discard another preparation and invoke this finalizer again on the same
            // final-ready session.
            try decoder.preparations.reserve(
                identifier: identifier,
                knownByteCharge: reservedKnownBytes
            )
            do {
                let source = try completeSourceLocked(retainingBytes: true)
                defer { data.removeAll(keepingCapacity: false) }
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
                let preparation = ImageDecodePreparation(
                    identifier: identifier,
                    probe: inspection.probe
                )
                try decoder.preparations.commitReservation(
                    identifier: identifier,
                    data: data,
                    source: source,
                    probe: inspection.probe,
                    sourceColorSpace: inspection.sourceColorSpace,
                    securityInspection: inspection.container,
                    limits: limits,
                    retentionMode: decoder.preparationRetentionMode
                )
                finalFactsStable = true
                lastProgress = .terminal
                return ImageProgressiveDecodePreparationFinalization(
                    preparation: preparation,
                    sourceByteCount: totalReceivedBytes
                )
            } catch {
                decoder.preparations.cancelReservation(identifier: identifier)
                transitionToTerminalFailureLocked()
                throw error
            }
        }

        private func preparationRetainedKnownByteChargeLocked() throws -> Int {
            let extraKnownBytes: Int
            switch decoder.preparationRetentionMode {
            case .retainedSource:
                extraKnownBytes = 0
            case .encodedDataOnly:
                extraKnownBytes = jpegState.embeddedICCProfileByteCount
            }
            let value = data.count.addingReportingOverflow(extraKnownBytes)
            guard !value.overflow else { throw ImageCraftError.preparedStateBudgetExceeded }
            return value.partialValue
        }

        func finishWithFinalImage() throws -> ImageProgressiveDecodeFinalization {
            lock.lock()
            defer { lock.unlock() }
            return try finishWithFinalImageLocked()
        }

        func decodedImageFinalizationResourceLedger() throws
            -> ImageDecodeResourceLedgerSnapshot?
        {
            lock.lock()
            defer { lock.unlock() }
            return try decodedImageFinalizationResourceLedgerLocked()
        }

        func finishWithDecodedImageResourceAuthority() throws
            -> ImageProgressiveDecodedImageResourceFinalization
        {
            lock.lock()
            defer { lock.unlock() }
            guard let preflightLedger = try decodedImageFinalizationResourceLedgerLocked() else {
                throw ImageCraftError.unsupportedOrCorruptImage
            }
            let finalization = try finishWithFinalImageLocked()
            return ImageProgressiveDecodedImageResourceFinalization(
                image: finalization.image,
                probe: finalization.probe,
                sourceByteCount: finalization.sourceByteCount,
                materializationResourceLedger: preflightLedger
            )
        }

        private func finishWithFinalImageLocked() throws -> ImageProgressiveDecodeFinalization {
            let source = try completeSourceLocked(retainingBytes: true)
            defer { data.removeAll(keepingCapacity: false) }
            do {
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
                finalFactsStable = true
                lastProgress = .terminal
                return ImageProgressiveDecodeFinalization(
                    image: image,
                    probe: inspection.probe,
                    sourceByteCount: totalReceivedBytes
                )
            } catch {
                transitionToTerminalFailureLocked()
                throw error
            }
        }

        private func decodedImageFinalizationResourceLedgerLocked() throws
            -> ImageDecodeResourceLedgerSnapshot?
        {
            guard !isCancelled else { throw ImageCraftError.progressiveSessionCancelled }
            guard !isFinished else { throw ImageCraftError.progressiveSessionFinished }
            guard jpegState.frameKind == .progressive, jpegState.foundEnd else { return nil }
            return activeResourceLedgerLocked()
        }

        private func activeResourceLedgerLocked() -> ImageDecodeResourceLedgerSnapshot {
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: data.count,
                retainedBetweenCalls: .bounded(data.count),
                operationPeak: .unknown(.frameworkPrivateOperationAllocation),
                transferredOutput: .unknown(.frameworkChosenOutputLayout),
                outputLayoutAuthority: .frameworkChosen
            )!
        }

        private func completeSourceLocked(retainingBytes: Bool = false) throws -> CGImageSource {
            guard !isCancelled else { throw ImageCraftError.progressiveSessionCancelled }
            guard !isFinished else { throw ImageCraftError.progressiveSessionFinished }
            isFinished = true
            do {
                try jpegState.consume(data)
                guard jpegState.frameKind == .progressive, jpegState.foundEnd else {
                    throw ImageCraftError.unsupportedOrCorruptImage
                }
                lastProgress = .finalReady
                let source = makeSource(isFinal: true)
                if !retainingBytes {
                    data.removeAll(keepingCapacity: false)
                }
                return source
            } catch {
                lastProgress = .terminal
                data.removeAll(keepingCapacity: false)
                throw error
            }
        }

        private func makeSource(isFinal: Bool) -> CGImageSource {
            let source = CGImageSourceCreateIncremental(decoder.sourceOptions(format: .jpeg))
            CGImageSourceUpdateData(source, data as CFData, isFinal)
            return source
        }

        func cancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            lastProgress = .terminal
            data.removeAll(keepingCapacity: false)
            lock.unlock()
        }

        private func transitionToTerminalFailureLocked() {
            isFinished = true
            lastProgress = .terminal
            data.removeAll(keepingCapacity: false)
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
