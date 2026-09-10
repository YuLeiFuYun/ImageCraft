import Foundation
import ImageCraftCore
import ImageCraftImageIO

/// Deliberately narrow external-package codec used to prove that the conformance kit is not
/// specialized to ImageIOImageDecoder's full descriptor. Pixel work delegates to the public
/// ImageIO decoder; the wrapper remains fail-closed outside its advertised PNG capability.
public struct LimitedPNGImageCodec: ImageCodec {
    private let base: ImageIOImageDecoder

    public let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "dev.imagecraft.fixture.limited-png"),
        implementationVersion: 1,
        decodeProfiles: [
            ImageDecodeCapabilityProfile(
                formats: [.png],
                deliveryModes: [.completeFrame],
                trackModes: [.primaryFrame],
                metadata: [.orientation, .sourceColorProfile],
                dynamicRanges: [.standard],
                outputRepresentations: [.coreGraphicsImage],
                cancellationMode: .operationBoundary
            )
        ]
    )

    public init() {
        self.base = ImageIOImageDecoder()
    }

    public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        let probe = try base.probe(data: data, limits: limits)
        guard probe.format == .png else { throw ImageCraftError.unsupportedFormat }
        return probe
    }

    public func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        guard probe.format == .png else { throw ImageCraftError.unsupportedFormat }
        return try base.decode(
            data: data,
            probe: probe,
            request: request,
            limits: limits
        )
    }

    public func resourceEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) throws -> ImageDecodeResourceEstimate {
        guard probe.format == .png else { throw ImageCraftError.unsupportedFormat }
        return try base.resourceEstimate(probe: probe, request: request)
    }
}
