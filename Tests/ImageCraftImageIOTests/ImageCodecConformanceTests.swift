import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// 后续 codec 仓库可以逐项复用本文件中的契约测试，而不依赖 ImageIO 私有实现。
final class ImageCodecConformanceTests: XCTestCase {
    func testFiniteCapabilityDomainMatchesIndependentMembershipOracle() {
        let descriptor = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.finite-domain"),
            implementationVersion: 1,
            capabilities: ImageCodecCapabilities(
                formats: [.png, .jpeg],
                deliveryModes: [.completeFrame],
                trackModes: [.primaryFrame],
                metadata: [.orientation, .sourceColorProfile],
                dynamicRanges: [.standard],
                outputRepresentations: [.coreGraphicsImage, .pixelBuffer],
                cancellationMode: .operationBoundary
            )
        )
        let metadataSubsets = allSubsets(ImageDecodeMetadataCapability.allCases)
        var checked = 0

        for format in EncodedImageFormat.allCases {
            for delivery in ImageDecodeDeliveryMode.allCases {
                for track in ImageDecodeTrackMode.allCases {
                    for metadata in metadataSubsets {
                        for range in ImageDecodeDynamicRange.allCases {
                            for output in ImageDecodeOutputRepresentation.allCases {
                                for cancellation in ImageDecodeCancellationMode.allCases {
                                    let request = ImageDecodeCapabilityRequest(
                                        format: format,
                                        deliveryMode: delivery,
                                        trackMode: track,
                                        requiredMetadata: metadata,
                                        dynamicRange: range,
                                        outputRepresentation: output,
                                        cancellationMode: cancellation
                                    )
                                    let expected = independentSupport(
                                        descriptor.capabilities,
                                        request
                                    )
                                    XCTAssertEqual(descriptor.supports(request), expected)
                                    XCTAssertEqual(
                                        descriptor.supportFailure(for: request) == nil,
                                        expected
                                    )
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2_304)
    }

    func testFailurePrecedenceIsStableWhenSeveralCapabilitiesAreMissing() {
        let descriptor = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.failure-order"),
            implementationVersion: 1,
            capabilities: ImageCodecCapabilities(
                formats: [.png],
                deliveryModes: [.completeFrame],
                trackModes: [.primaryFrame],
                metadata: [.orientation],
                dynamicRanges: [.standard],
                outputRepresentations: [.coreGraphicsImage],
                cancellationMode: .operationBoundary
            )
        )
        let hostile = ImageDecodeCapabilityRequest(
            format: .gif,
            deliveryMode: .progressiveGenerations,
            trackMode: .animatedSequence,
            requiredMetadata: [.frameTiming, .highDynamicRange],
            dynamicRange: .high,
            outputRepresentation: .planarPixels,
            cancellationMode: .interruptible
        )
        XCTAssertEqual(descriptor.supportFailure(for: hostile), .format(.gif))

        let sameFormat = ImageDecodeCapabilityRequest(
            format: .png,
            deliveryMode: .progressiveGenerations,
            trackMode: .animatedSequence,
            requiredMetadata: [.frameTiming, .highDynamicRange],
            dynamicRange: .high,
            outputRepresentation: .planarPixels,
            cancellationMode: .interruptible
        )
        XCTAssertEqual(
            descriptor.supportFailure(for: sameFormat),
            .deliveryMode(.progressiveGenerations)
        )
    }

    func testCapabilitySupersetMonotonicityAcrossEveryFiniteRequest() {
        let subset = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.subset"),
            implementationVersion: 1,
            capabilities: ImageCodecCapabilities(
                formats: [.png],
                deliveryModes: [.completeFrame],
                trackModes: [.primaryFrame],
                metadata: [.orientation],
                dynamicRanges: [.standard],
                outputRepresentations: [.coreGraphicsImage],
                cancellationMode: .operationBoundary
            )
        )
        let superset = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.superset"),
            implementationVersion: 1,
            capabilities: ImageCodecCapabilities(
                formats: Set(EncodedImageFormat.allCases),
                deliveryModes: Set(ImageDecodeDeliveryMode.allCases),
                trackModes: Set(ImageDecodeTrackMode.allCases),
                metadata: Set(ImageDecodeMetadataCapability.allCases),
                dynamicRanges: Set(ImageDecodeDynamicRange.allCases),
                outputRepresentations: Set(ImageDecodeOutputRepresentation.allCases),
                cancellationMode: .interruptible
            )
        )

        for request in finiteRequests() where subset.supports(request) {
            XCTAssertTrue(superset.supports(request))
        }
    }

    func testConservativeResourceCompositionIsCommutativeMonotoneAndIdempotent() throws {
        let values = [1, 2, 4, 255, 4_096, Int.max]
        for a in values {
            let aa = try ImageDecodeResourceEstimate.conservativeMaximum(
                genericBytes: a,
                backendBytes: a
            ).workingSetBytes
            XCTAssertEqual(aa, a)
            for b in values {
                let ab = try ImageDecodeResourceEstimate.conservativeMaximum(
                    genericBytes: a,
                    backendBytes: b
                ).workingSetBytes
                let ba = try ImageDecodeResourceEstimate.conservativeMaximum(
                    genericBytes: b,
                    backendBytes: a
                ).workingSetBytes
                XCTAssertEqual(ab, max(a, b))
                XCTAssertEqual(ab, ba)
                XCTAssertGreaterThanOrEqual(ab, a)
                XCTAssertGreaterThanOrEqual(ab, b)
            }
        }
    }

    func testImageIOProbeFormatsAreContainedInAdvertisedCapabilities() throws {
        let decoder = ImageIOImageDecoder()
        for (type, expected) in [
            (UTType.png.identifier as CFString, EncodedImageFormat.png),
            (UTType.jpeg.identifier as CFString, EncodedImageFormat.jpeg),
            (UTType.gif.identifier as CFString, EncodedImageFormat.gif),
        ] {
            let data = try makeConformanceImage(type: type)
            let probe = try decoder.probe(data: data, limits: .coreV1)
            XCTAssertEqual(probe.format, expected)
            XCTAssertTrue(
                decoder.codecDescriptor.supports(
                    ImageDecodeCapabilityRequest(format: probe.format)
                )
            )
        }
    }

    func testCodecFingerprintSeparatesEveryIdentityDimension() {
        let capabilities = ImageCodecCapabilities(
            formats: Set(EncodedImageFormat.allCases),
            deliveryModes: [.completeFrame],
            trackModes: [.primaryFrame],
            metadata: [.orientation, .sourceColorProfile],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
        let base = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.a"),
            implementationVersion: 1,
            contractVersion: 1,
            capabilities: capabilities
        )
        let identifier = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.b"),
            implementationVersion: 1,
            contractVersion: 1,
            capabilities: capabilities
        )
        let implementation = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.a"),
            implementationVersion: 2,
            contractVersion: 1,
            capabilities: capabilities
        )
        let contract = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.a"),
            implementationVersion: 1,
            contractVersion: 2,
            capabilities: capabilities
        )
        XCTAssertEqual(
            Set([
                base.cacheFingerprint,
                identifier.cacheFingerprint,
                implementation.cacheFingerprint,
                contract.cacheFingerprint,
            ]).count,
            4
        )
    }

    func testImageIOFailsClosedForReservedFutureSemantics() {
        let descriptor = ImageIOImageDecoder().codecDescriptor
        XCTAssertEqual(
            descriptor.supportFailure(
                for: ImageDecodeCapabilityRequest(
                    format: .jpeg,
                    deliveryMode: .progressiveGenerations
                )
            ),
            .deliveryMode(.progressiveGenerations)
        )
        XCTAssertEqual(
            descriptor.supportFailure(
                for: ImageDecodeCapabilityRequest(
                    format: .gif,
                    trackMode: .animatedSequence,
                    requiredMetadata: [.frameTiming]
                )
            ),
            .trackMode(.animatedSequence)
        )
        XCTAssertEqual(
            descriptor.supportFailure(
                for: ImageDecodeCapabilityRequest(
                    format: .png,
                    requiredMetadata: [.highDynamicRange],
                    dynamicRange: .high
                )
            ),
            .metadata(.highDynamicRange)
        )
        XCTAssertEqual(
            descriptor.supportFailure(
                for: ImageDecodeCapabilityRequest(
                    format: .png,
                    outputRepresentation: .planarPixels
                )
            ),
            .outputRepresentation(.planarPixels)
        )
    }

    private func finiteRequests() -> [ImageDecodeCapabilityRequest] {
        var requests: [ImageDecodeCapabilityRequest] = []
        for format in EncodedImageFormat.allCases {
            for delivery in ImageDecodeDeliveryMode.allCases {
                for track in ImageDecodeTrackMode.allCases {
                    for metadata in allSubsets(ImageDecodeMetadataCapability.allCases) {
                        for range in ImageDecodeDynamicRange.allCases {
                            for output in ImageDecodeOutputRepresentation.allCases {
                                for cancellation in ImageDecodeCancellationMode.allCases {
                                    requests.append(
                                        ImageDecodeCapabilityRequest(
                                            format: format,
                                            deliveryMode: delivery,
                                            trackMode: track,
                                            requiredMetadata: metadata,
                                            dynamicRange: range,
                                            outputRepresentation: output,
                                            cancellationMode: cancellation
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        return requests
    }

    private func allSubsets<Element: Hashable>(_ values: [Element]) -> [Set<Element>] {
        (0..<(1 << values.count)).map { mask in
            Set(
                values.enumerated().compactMap { index, value in
                    mask & (1 << index) == 0 ? nil : value
                })
        }
    }

    private func independentSupport(
        _ capabilities: ImageCodecCapabilities,
        _ request: ImageDecodeCapabilityRequest
    ) -> Bool {
        capabilities.formats.contains(request.format)
            && capabilities.deliveryModes.contains(request.deliveryMode)
            && capabilities.trackModes.contains(request.trackMode)
            && request.requiredMetadata.isSubset(of: capabilities.metadata)
            && capabilities.dynamicRanges.contains(request.dynamicRange)
            && capabilities.outputRepresentations.contains(request.outputRepresentation)
            && capabilities.cancellationMode.rawValue >= request.cancellationMode.rawValue
    }
}

private func makeConformanceImage(type: CFString) throws -> Data {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
