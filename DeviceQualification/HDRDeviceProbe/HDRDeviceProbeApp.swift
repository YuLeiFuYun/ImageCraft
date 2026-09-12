import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO

private let gainMapExpectedBytes = 1_488
private let gainMapExpectedSHA256 = "e5d0836dca09abea8d3ec041be00fa6561fbb811f6fc90b0220d9967c3673eed"
private let sdrExpectedBytes = 1_221
private let sdrExpectedSHA256 = "ddb7d01c6d793c20570e797308594d9115a14ba5e143790d5886ea810cad0dae"
private let resultName = "imagecraft-hdr-device-result.json"
private let failureName = "imagecraft-hdr-device-result.json.failure"

private struct QualificationFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct FixtureIdentity: Codable {
    let bytes: Int
    let sha256: String
}

private struct RasterObservation: Codable {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let isHDRColorSpace: Bool
    let usesExtendedRange: Bool
    let contentHeadroom: Double

    var isGenuineHDR: Bool {
        bitsPerComponent > 8
            && (isHDRColorSpace || usesExtendedRange)
            && contentHeadroom > 1.0
    }
}

private struct GainMapProbeObservation: Codable {
    let auxiliaryAttachmentCount: Int
    let sourceBitsPerComponent: Int
}

private struct HighOutcome: Codable {
    let classification: String
    let raster: RasterObservation?
    let contractError: String?
}

private struct GainMapObservation: Codable {
    let defaultAuxiliaryAdmission: String
    let probe: GainMapProbeObservation
    let standard: RasterObservation
    let high: HighOutcome
    let tinyHigh: HighOutcome
}

private struct QualificationReport: Codable {
    let schemaVersion: Int
    let status: String
    let hardwareReality: String
    let platform: String
    let osVersion: String
    let codecImplementationVersion: UInt32
    let highHEIFAdvertised: Bool
    let sdrFixture: FixtureIdentity
    let gainMapFixture: FixtureIdentity
    let directHDRFixture: FixtureIdentity
    let directHDR: RasterObservation
    let directHDRTinyFit: RasterObservation
    let directHDRTinyFill: RasterObservation
    let gainMap: GainMapObservation
}

private struct FailureReport: Codable {
    let schemaVersion: Int
    let status: String
    let error: String
}

private func fail(_ message: String) throws -> Never {
    throw QualificationFailure(message: message)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        try fail(message)
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func documentsURL() throws -> URL {
    guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        try fail("documents directory unavailable")
    }
    return url
}

private func resetResultFiles() throws {
    let documents = try documentsURL()
    for name in [resultName, failureName] {
        let url = documents.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }
}

private func writeJSON<T: Encodable>(_ value: T, name: String) throws {
    let data = try JSONEncoder().encode(value)
    let url = try documentsURL().appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
}

private func fixtureData(resource: String) throws -> Data {
    guard let url = Bundle.main.url(forResource: resource, withExtension: "heic") else {
        try fail("missing bundled fixture: \(resource).heic")
    }
    return try Data(contentsOf: url, options: .mappedIfSafe)
}

private func observe(_ image: DecodedImage) -> RasterObservation {
    let colorSpace = image.cgImage.colorSpace
    return RasterObservation(
        width: image.pixelWidth,
        height: image.pixelHeight,
        bitsPerComponent: image.pixelFormat.bitsPerComponent,
        isHDRColorSpace: colorSpace?.isHDR() == true,
        usesExtendedRange: colorSpace.map(CGColorSpaceUsesExtendedRange) ?? false,
        contentHeadroom: Double(image.cgImage.contentHeadroom)
    )
}

private func requireGenuineHDR(
    _ observation: RasterObservation,
    width: Int,
    height: Int,
    label: String
) throws {
    try require(observation.width == width && observation.height == height, "\(label) geometry")
    try require(observation.bitsPerComponent > 8, "\(label) precision collapsed")
    try require(
        observation.isHDRColorSpace || observation.usesExtendedRange,
        "\(label) color-space semantic"
    )
    try require(observation.contentHeadroom > 1.0, "\(label) headroom")
}

private func requireHighFailure(_ label: String, _ body: () throws -> Void) throws {
    do {
        try body()
        try fail("\(label) unexpectedly succeeded")
    } catch let error as ImageCodecContractError {
        try require(
            error == .unsupportedCapability(.dynamicRange(.high)),
            "\(label) wrong contract error: \(error)"
        )
    }
}

private func requireAuxiliaryFailure(_ label: String, _ body: () throws -> Void) throws {
    do {
        try body()
        try fail("\(label) unexpectedly succeeded")
    } catch let error as ImageCraftError {
        try require(
            error == .auxiliaryAttachmentLimitExceeded,
            "\(label) wrong auxiliary error: \(error)"
        )
    }
}

private func makeDirectHDRHEIC() throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else {
        try fail("PQ color space unavailable")
    }
    guard let context = CGContext(
        data: nil,
        width: 2,
        height: 1,
        bitsPerComponent: 16,
        bytesPerRow: 16,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
    ) else {
        try fail("direct HDR CGContext unavailable")
    }
    context.setFillColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
    guard let image = context.makeImage(), image.colorSpace?.isHDR() == true else {
        try fail("direct HDR source image unavailable")
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        "public.heic" as CFString,
        1,
        nil
    ) else {
        try fail("direct HDR HEIC destination unavailable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "direct HDR HEIC finalize")
    let data = output as Data
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        try fail("direct HDR ImageIO round trip")
    }
    try require(decoded.bitsPerComponent > 8, "direct HDR host precision")
    try require(
        decoded.colorSpace?.isHDR() == true
            || decoded.colorSpace.map(CGColorSpaceUsesExtendedRange) == true,
        "direct HDR host color-space semantic"
    )
    try require(decoded.contentHeadroom > 1.0, "direct HDR host headroom")
    return data
}

private func characterizeHigh(
    decoder: ImageIOImageDecoder,
    data: Data,
    probe: ImageProbe,
    request: ImageDecodeRequest,
    limits: DecodeLimits,
    label: String
) throws -> HighOutcome {
    do {
        let decoded = try decoder.decode(data: data, probe: probe, request: request, limits: limits)
        let observation = observe(decoded)
        try require(
            observation.isGenuineHDR,
            "\(label) succeeded without genuine HDR output"
        )
        return HighOutcome(classification: "hdr-success", raster: observation, contractError: nil)
    } catch let error as ImageCodecContractError {
        try require(
            error == .unsupportedCapability(.dynamicRange(.high)),
            "\(label) unexpected contract error: \(error)"
        )
        return HighOutcome(
            classification: "fail-closed",
            raster: nil,
            contractError: "unsupportedCapability.dynamicRange.high"
        )
    }
}

private struct LoadedFixtures {
    let sdrData: Data
    let gainMapData: Data
    let sdrIdentity: FixtureIdentity
    let gainMapIdentity: FixtureIdentity
}

private struct DirectHDRControl {
    let identity: FixtureIdentity
    let full: RasterObservation
    let tinyFit: RasterObservation
    let tinyFill: RasterObservation
}

private func validatePhysicalRuntime() throws {
#if targetEnvironment(simulator)
    try fail("physical iPhone required; simulator evidence cannot qualify gain-map HDR")
#else
    if #unavailable(iOS 18.0) {
        try fail("physical qualification requires iOS 18+")
    }
    let types = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    try require(
        types.contains("public.heic") || types.contains("public.heif"),
        "HEIF source is not registered"
    )
#endif
}

private func makeQualifiedDecoder() throws -> (ImageIOImageDecoder, Bool) {
    let decoder = ImageIOImageDecoder()
    try require(
        decoder.codecDescriptor.implementationVersion == 12,
        "unexpected ImageIO implementation version"
    )
    let highAdvertised = decoder.codecDescriptor.supports(
        ImageDecodeCapabilityRequest(format: .heif, dynamicRange: .high)
    )
    try require(highAdvertised, "HEIF high capability is not advertised")
    return (decoder, highAdvertised)
}

private func loadQualifiedFixtures() throws -> LoadedFixtures {
    let sdrData = try fixtureData(resource: "heif-rgba")
    let sdrDigest = sha256Hex(sdrData)
    try require(sdrData.count == sdrExpectedBytes, "SDR fixture byte count drift")
    try require(sdrDigest == sdrExpectedSHA256, "SDR fixture SHA-256 drift")

    let gainMapData = try fixtureData(resource: "heif-iso-gainmap-sdr-hdr")
    let gainMapDigest = sha256Hex(gainMapData)
    try require(gainMapData.count == gainMapExpectedBytes, "gain-map fixture byte count drift")
    try require(gainMapDigest == gainMapExpectedSHA256, "gain-map fixture SHA-256 drift")
    return LoadedFixtures(
        sdrData: sdrData,
        gainMapData: gainMapData,
        sdrIdentity: FixtureIdentity(bytes: sdrData.count, sha256: sdrDigest),
        gainMapIdentity: FixtureIdentity(bytes: gainMapData.count, sha256: gainMapDigest)
    )
}

private func decodeDirectTinyHDR(
    decoder: ImageIOImageDecoder,
    data: Data,
    probe: ImageProbe,
    mode: ImageContentMode,
    label: String
) throws -> RasterObservation {
    let request = ImageDecodeRequest(
        target: try TargetPixels(width: 1, height: 1),
        contentMode: mode,
        colorPolicy: .preserveSource,
        dynamicRange: .high
    )
    let decoded = try decoder.decode(data: data, probe: probe, request: request, limits: .coreV1)
    let observation = observe(decoded)
    try requireGenuineHDR(observation, width: 1, height: 1, label: label)
    return observation
}

private func verifyHighNegativeControls(
    decoder: ImageIOImageDecoder,
    directData: Data,
    directProbe: ImageProbe,
    sdrData: Data
) throws {
    let standard = ImageDecodeRequest(
        target: try TargetPixels(width: 2, height: 1),
        colorPolicy: .preserveSource
    )
    try requireHighFailure("direct HDR standard request") {
        _ = try decoder.decode(data: directData, probe: directProbe, request: standard, limits: .coreV1)
    }
    let converted = ImageDecodeRequest(
        target: try TargetPixels(width: 2, height: 1),
        colorPolicy: .convertToSRGB,
        dynamicRange: .high
    )
    try requireHighFailure("direct HDR high convertToSRGB") {
        _ = try decoder.decode(data: directData, probe: directProbe, request: converted, limits: .coreV1)
    }
    let sdrProbe = try decoder.probe(data: sdrData, limits: .coreV1)
    let sdrHigh = ImageDecodeRequest(
        target: try TargetPixels(width: sdrProbe.pixelWidth, height: sdrProbe.pixelHeight),
        colorPolicy: .preserveSource,
        dynamicRange: .high
    )
    try requireHighFailure("SDR HEIF high request") {
        _ = try decoder.decode(data: sdrData, probe: sdrProbe, request: sdrHigh, limits: .coreV1)
    }
}

private func runDirectHDRControl(
    decoder: ImageIOImageDecoder,
    sdrData: Data
) throws -> DirectHDRControl {
    let data = try makeDirectHDRHEIC()
    let probe = try decoder.probe(data: data, limits: .coreV1)
    try require(probe.format == .heif, "direct HDR probe format")
    try require((probe.sourceBitsPerComponent ?? 0) > 8, "direct HDR probe precision")
    try verifyHighNegativeControls(decoder: decoder, directData: data, directProbe: probe, sdrData: sdrData)

    let request = ImageDecodeRequest(
        target: try TargetPixels(width: 2, height: 1),
        colorPolicy: .preserveSource,
        dynamicRange: .high
    )
    let decoded = try decoder.decode(data: data, probe: probe, request: request, limits: .coreV1)
    let full = observe(decoded)
    try requireGenuineHDR(full, width: 2, height: 1, label: "direct HDR")
    return DirectHDRControl(
        identity: FixtureIdentity(bytes: data.count, sha256: sha256Hex(data)),
        full: full,
        tinyFit: try decodeDirectTinyHDR(
            decoder: decoder, data: data, probe: probe, mode: .fit, label: "direct HDR tiny fit"
        ),
        tinyFill: try decodeDirectTinyHDR(
            decoder: decoder, data: data, probe: probe, mode: .fill, label: "direct HDR tiny fill"
        )
    )
}

private func decodeGainMapStandard(
    decoder: ImageIOImageDecoder,
    data: Data,
    probe: ImageProbe,
    limits: DecodeLimits
) throws -> RasterObservation {
    let request = ImageDecodeRequest(
        target: try TargetPixels(width: 8, height: 4),
        colorPolicy: .preserveSource,
        dynamicRange: .standard
    )
    let decoded = try decoder.decode(data: data, probe: probe, request: request, limits: limits)
    let observation = observe(decoded)
    try require(observation.width == 8 && observation.height == 4, "gain-map standard geometry")
    try require(observation.bitsPerComponent == 8, "gain-map standard precision")
    try require(
        !observation.isHDRColorSpace && !observation.usesExtendedRange,
        "gain-map standard request escaped SDR color space"
    )
    try require(observation.contentHeadroom <= 1.000_001, "gain-map standard request escaped SDR headroom")
    return observation
}

private func runGainMapControl(
    decoder: ImageIOImageDecoder,
    data: Data
) throws -> GainMapObservation {
    try requireAuxiliaryFailure("gain-map default auxiliary admission") {
        _ = try decoder.probe(data: data, limits: .coreV1)
    }
    let limits = DecodeLimits(maximumAuxiliaryAttachments: 1)
    let probe = try decoder.probe(data: data, limits: limits)
    try require(probe.format == .heif, "gain-map probe format")
    try require(probe.auxiliaryAttachmentCount == 1, "gain-map auxiliary attachment count")
    try require(probe.sourceBitsPerComponent == 8, "gain-map source precision")
    let standard = try decodeGainMapStandard(decoder: decoder, data: data, probe: probe, limits: limits)
    let highRequest = ImageDecodeRequest(
        target: try TargetPixels(width: 8, height: 4),
        colorPolicy: .preserveSource,
        dynamicRange: .high
    )
    let tinyRequest = ImageDecodeRequest(
        target: try TargetPixels(width: 1, height: 1),
        colorPolicy: .preserveSource,
        dynamicRange: .high
    )
    return GainMapObservation(
        defaultAuxiliaryAdmission: "auxiliaryAttachmentLimitExceeded",
        probe: GainMapProbeObservation(
            auxiliaryAttachmentCount: probe.auxiliaryAttachmentCount,
            sourceBitsPerComponent: probe.sourceBitsPerComponent ?? -1
        ),
        standard: standard,
        high: try characterizeHigh(
            decoder: decoder, data: data, probe: probe, request: highRequest,
            limits: limits, label: "gain-map high"
        ),
        tinyHigh: try characterizeHigh(
            decoder: decoder, data: data, probe: probe, request: tinyRequest,
            limits: limits, label: "gain-map tiny high"
        )
    )
}

private func runQualification() throws -> QualificationReport {
    try validatePhysicalRuntime()
    let (decoder, highAdvertised) = try makeQualifiedDecoder()
    let fixtures = try loadQualifiedFixtures()
    let direct = try runDirectHDRControl(decoder: decoder, sdrData: fixtures.sdrData)
    let gainMap = try runGainMapControl(decoder: decoder, data: fixtures.gainMapData)
    return QualificationReport(
        schemaVersion: 1,
        status: "pass",
        hardwareReality: "physical",
        platform: "iOS",
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        codecImplementationVersion: decoder.codecDescriptor.implementationVersion,
        highHEIFAdvertised: highAdvertised,
        sdrFixture: fixtures.sdrIdentity,
        gainMapFixture: fixtures.gainMapIdentity,
        directHDRFixture: direct.identity,
        directHDR: direct.full,
        directHDRTinyFit: direct.tinyFit,
        directHDRTinyFill: direct.tinyFill,
        gainMap: gainMap
    )
}
@main
enum HDRDeviceProbeApp {
    static func main() {
        do {
            try resetResultFiles()
            let report = try runQualification()
            try writeJSON(report, name: resultName)
            print(
                "PASS ImageCraft physical HDR qualification gainMapHigh=\(report.gainMap.high.classification) "
                    + "tiny=\(report.gainMap.tinyHigh.classification)"
            )
            fflush(stdout)
            exit(0)
        } catch {
            let message = String(describing: error)
            try? writeJSON(
                FailureReport(schemaVersion: 1, status: "fail", error: message),
                name: failureName
            )
            print("FAIL ImageCraft physical HDR qualification: \(message)")
            fflush(stderr)
            exit(1)
        }
    }
}
