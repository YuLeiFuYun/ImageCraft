import CryptoKit
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ActualPNGStreamTests: XCTestCase {
  func testPublicBoundedPNGMatchesImageIOOnFrozenActualStream_ACTUAL_PNG_PT_001() throws {
    let fixture = try Data(contentsOf: actualFixtureURL())
    XCTAssertEqual(fixture.count, 51_068)
    XCTAssertEqual(
      sha256(fixture),
      "9bab84fbb5ef61a1d1c75fb2179ce5510c60a8d61dfabd961b96b950f2e80533"
    )

    let limits = DecodeLimits(
      maximumEncodedBytes: fixture.count,
      maximumDimension: 200,
      maximumPixelCount: 40_000,
      maximumFrameCount: 1,
      maximumMetadataBytes: 1_024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.png]
    )
    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 200, height: 200),
      contentMode: .fit,
      colorPolicy: .convertToSRGB
    )
    let bounded = try BoundedPNGDecoder(maximumOperationByteCharge: 2 * 1_024 * 1_024)
    let imageIO = ImageIOImageDecoder()

    let probe = try bounded.probe(data: fixture, limits: limits)
    XCTAssertEqual(probe.pixelWidth, 200)
    XCTAssertEqual(probe.pixelHeight, 200)
    XCTAssertEqual(probe.frameCount, 1)
    XCTAssertEqual(probe.format, .png)
    XCTAssertEqual(probe.sourceColorProfile, .absent)

    let ledger = try bounded.packedRGBA8ResourceLedger(
      data: fixture,
      request: request,
      limits: limits
    )
    XCTAssertEqual(ledger.retainedKnownBytes, 0)
    XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0))
    XCTAssertEqual(ledger.operationPeak, .bounded(222_640))
    XCTAssertEqual(ledger.transferredOutput, .bounded(160_000))
    XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)

    let boundedPixels = try bounded.decodePackedRGBA8(
      data: fixture,
      request: request,
      limits: limits
    )
    let imageIOPixels = try imageIO.decodePackedRGBA8(
      data: fixture,
      request: request,
      limits: limits
    )
    XCTAssertEqual(boundedPixels, imageIOPixels)
    XCTAssertEqual(boundedPixels.data.count, 160_000)
    XCTAssertEqual(
      sha256(boundedPixels.data),
      "7f74a9613312bfebe1108b44c18460aaa456db7f85aa24a7a211a340ea5af84b"
    )
  }

  func testActualStreamManifestFreezesUnmodifiedPublicDomainSource_ACTUAL_PNG_PT_002() throws {
    let manifest = try JSONSerialization.jsonObject(
      with: Data(contentsOf: actualManifestURL())
    ) as? [String: Any]
    let root = try XCTUnwrap(manifest)
    XCTAssertEqual(root["schemaVersion"] as? Int, 1)
    XCTAssertEqual(
      root["fixtureSetID"] as? String,
      "imagecraft-independent-png-actual-stream-v1"
    )
    let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
    let fixture = try XCTUnwrap(cases.first)
    XCTAssertEqual(fixture["repositoryCopyModified"] as? Bool, false)
    XCTAssertEqual(fixture["sourceDerivative"] as? Bool, true)
    XCTAssertEqual(fixture["licenseStatus"] as? String, "public-domain-US-NASA")
    XCTAssertEqual(fixture["compressedIDATByteCount"] as? Int, 50_918)
    XCTAssertEqual(fixture["idatChunkCount"] as? Int, 7)
    XCTAssertEqual(
      fixture["sha256"] as? String,
      "9bab84fbb5ef61a1d1c75fb2179ce5510c60a8d61dfabd961b96b950f2e80533"
    )
  }

  func testPublicBoundedPNGMatchesImageIOOnPngSuiteAdam7IndexedIDAT_ACTUAL_PNG_PT_003() throws {
    let fixtures: [(bitDepth: Int, byteCount: Int, sha256: String, operationPeak: Int)] = [
      (1, 129, "63ab2d47e214715479b569026eb8614a5107b014ea3f327d9aeb0b7c87945021", 65_544),
      (2, 175, "692ddb2ee18794b30ffa0699d7da25f9b345263a460021a5c74efaf05121d3e2", 65_552),
      (4, 309, "fad47320ccca7559719dd49df0ef8071b3ce4e8cd3e29c0566ed7b2fd7388890", 65_568),
      (8, 1_524, "604dcd436e07a4b10bd782020b0a97f27a22c18be5920f222d20c9837423d087", 65_600),
    ]
    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 32, height: 32),
      contentMode: .fit,
      colorPolicy: .preserveSource
    )
    let bounded = try BoundedPNGDecoder(maximumOperationByteCharge: 1 * 1_024 * 1_024)
    let imageIO = ImageIOImageDecoder()

    for expected in fixtures {
      let fixture = try Data(contentsOf: pngSuiteDerivedFixtureURL(bitDepth: expected.bitDepth))
      XCTAssertEqual(fixture.count, expected.byteCount, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(sha256(fixture), expected.sha256, "bitDepth=\(expected.bitDepth)")
      let limits = DecodeLimits(
        maximumEncodedBytes: fixture.count,
        maximumDimension: 32,
        maximumPixelCount: 1_024,
        maximumFrameCount: 1,
        maximumMetadataBytes: 1_024,
        maximumAuxiliaryAttachments: 0,
        allowedFormats: [.png]
      )
      let probe = try bounded.probe(data: fixture, limits: limits)
      XCTAssertEqual(probe.pixelWidth, 32, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(probe.pixelHeight, 32, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(probe.frameCount, 1, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(probe.format, .png, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(probe.sourceColorProfile, .standardSRGB, "bitDepth=\(expected.bitDepth)")

      let ledger = try bounded.packedRGBA8ResourceLedger(
        data: fixture,
        request: request,
        limits: limits
      )
      XCTAssertEqual(ledger.retainedKnownBytes, 0, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0), "bitDepth=\(expected.bitDepth)")
      // 4,096 B final RGBA8 + two maximum packed-index source rows + 61,440 B inflate workspace.
      // Adam7 scatters directly into the final surface and adds no pass-sized allocation.
      XCTAssertEqual(
        ledger.operationPeak,
        .bounded(expected.operationPeak),
        "bitDepth=\(expected.bitDepth)"
      )
      XCTAssertEqual(ledger.transferredOutput, .bounded(4_096), "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8, "bitDepth=\(expected.bitDepth)")

      let boundedPixels = try bounded.decodePackedRGBA8(
        data: fixture,
        request: request,
        limits: limits
      )
      let imageIOPixels = try imageIO.decodePackedRGBA8(
        data: fixture,
        request: request,
        limits: limits
      )
      XCTAssertEqual(boundedPixels, imageIOPixels, "bitDepth=\(expected.bitDepth)")
      XCTAssertEqual(boundedPixels.data.count, 4_096, "bitDepth=\(expected.bitDepth)")
    }
  }

  func testPngSuiteAdam7IndexedInvalidPaletteIndexFailsClosed_ACTUAL_PNG_PT_005() throws {
    let fixture = try Data(contentsOf: pngSuiteDerivedFixtureURL(bitDepth: 8))
    let palette = try XCTUnwrap(try pngChunks(fixture).first(where: { $0.type == "PLTE" }))
    XCTAssertGreaterThan(palette.payload.count, 3)
    let hostile = try replacingPNGChunkPayload(
      fixture,
      type: "PLTE",
      payload: Data(palette.payload.prefix(3))
    )
    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 32, height: 32),
      contentMode: .fit,
      colorPolicy: .preserveSource
    )
    let bounded = try BoundedPNGDecoder(maximumOperationByteCharge: 1 * 1_024 * 1_024)
    XCTAssertThrowsError(
      try bounded.decodePackedRGBA8(data: hostile, request: request, limits: .coreV1)
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
  }

  func testPngSuiteAdam7IndexedFixturePreservesOriginalPLTEAndIDAT_ACTUAL_PNG_PT_004() throws {
    let manifest = try JSONSerialization.jsonObject(
      with: Data(contentsOf: pngSuiteManifestURL())
    ) as? [String: Any]
    let root = try XCTUnwrap(manifest)
    XCTAssertEqual(root["schemaVersion"] as? Int, 2)
    XCTAssertEqual(
      root["fixtureSetID"] as? String,
      "imagecraft-independent-png-adam7-indexed-pngsuite-v2"
    )
    let upstream = try XCTUnwrap(root["upstream"] as? [String: Any])
    XCTAssertEqual(
      upstream["revision"] as? String,
      "8cd768dd0d0063195174d0d01cacbd5a7d1e5605"
    )
    let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 4)
    XCTAssertEqual(cases.compactMap { $0["bitDepth"] as? Int }, [1, 2, 4, 8])
    for item in cases {
      let bitDepth = try XCTUnwrap(item["bitDepth"] as? Int)
      let sourceFacts = try XCTUnwrap(item["source"] as? [String: Any])
      let derivedFacts = try XCTUnwrap(item["derived"] as? [String: Any])
      let source = try Data(contentsOf: pngSuiteSourceFixtureURL(bitDepth: bitDepth))
      let derived = try Data(contentsOf: pngSuiteDerivedFixtureURL(bitDepth: bitDepth))
      XCTAssertEqual(source.count, sourceFacts["byteCount"] as? Int, "bitDepth=\(bitDepth)")
      XCTAssertEqual(sha256(source), sourceFacts["sha256"] as? String, "bitDepth=\(bitDepth)")
      XCTAssertEqual(derived.count, derivedFacts["byteCount"] as? Int, "bitDepth=\(bitDepth)")
      XCTAssertEqual(sha256(derived), derivedFacts["sha256"] as? String, "bitDepth=\(bitDepth)")

      let sourceChunks = try pngChunks(source)
      let derivedChunks = try pngChunks(derived)
      XCTAssertTrue(sourceChunks.map { $0.type }.contains("gAMA"), "bitDepth=\(bitDepth)")
      XCTAssertFalse(derivedChunks.map { $0.type }.contains("gAMA"), "bitDepth=\(bitDepth)")
      XCTAssertFalse(derivedChunks.map { $0.type }.contains("sBIT"), "bitDepth=\(bitDepth)")
      XCTAssertEqual(
        try XCTUnwrap(derivedChunks.first(where: { $0.type == "sRGB" })).payload,
        Data([0]),
        "bitDepth=\(bitDepth)"
      )
      XCTAssertEqual(
        try XCTUnwrap(sourceChunks.first(where: { $0.type == "IHDR" })).payload,
        try XCTUnwrap(derivedChunks.first(where: { $0.type == "IHDR" })).payload,
        "bitDepth=\(bitDepth)"
      )
      XCTAssertEqual(
        try XCTUnwrap(sourceChunks.first(where: { $0.type == "PLTE" })).payload,
        try XCTUnwrap(derivedChunks.first(where: { $0.type == "PLTE" })).payload,
        "bitDepth=\(bitDepth)"
      )
      let sourceIDAT = sourceChunks.filter { $0.type == "IDAT" }.reduce(into: Data()) {
        $0.append($1.payload)
      }
      let derivedIDAT = derivedChunks.filter { $0.type == "IDAT" }.reduce(into: Data()) {
        $0.append($1.payload)
      }
      XCTAssertEqual(sourceIDAT, derivedIDAT, "bitDepth=\(bitDepth)")
      XCTAssertEqual(sourceIDAT.count, sourceFacts["idatByteCount"] as? Int, "bitDepth=\(bitDepth)")
      XCTAssertEqual(sha256(sourceIDAT), sourceFacts["idatSHA256"] as? String, "bitDepth=\(bitDepth)")
      XCTAssertEqual(derivedFacts["sourceIHDRExact"] as? Bool, true)
      XCTAssertEqual(derivedFacts["sourcePLTEExact"] as? Bool, true)
      XCTAssertEqual(derivedFacts["sourceIDATExact"] as? Bool, true)
      XCTAssertEqual(derivedFacts["sourceIENDExact"] as? Bool, true)
      XCTAssertEqual(derivedFacts["modified"] as? Bool, true)
    }
    let license = try String(contentsOf: pngSuiteLicenseURL(), encoding: .utf8)
    XCTAssertTrue(
      license.contains(
        "Permission to use, copy, modify and distribute these images for any\npurpose and without fee is hereby granted."
      )
    )
  }

  func testPublicBoundedPNGMatchesImageIOAcrossPngSuiteAdam7ChannelModels_ACTUAL_PNG_PT_006() throws {
    let manifestData = try Data(contentsOf: pngSuiteAdam7ChannelsManifestURL())
    XCTAssertEqual(manifestData.count, 11_222)
    XCTAssertEqual(
      sha256(manifestData),
      "d38f582a207c0358b54fd11eaa636f9fc16d280c74e34d6dec94be58a02769fb"
    )
    let manifest = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
    XCTAssertEqual(
      manifest["fixtureSetID"] as? String,
      "imagecraft-independent-png-adam7-channels-pngsuite-v1"
    )
    let upstream = try XCTUnwrap(manifest["upstream"] as? [String: Any])
    XCTAssertEqual(
      upstream["revision"] as? String,
      "8cd768dd0d0063195174d0d01cacbd5a7d1e5605"
    )
    let cases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
    XCTAssertEqual(
      cases.compactMap { $0["id"] as? String },
      ["grayscale1", "grayscale2", "grayscale4", "grayscale8", "rgb8", "grayscaleAlpha8", "rgba8"]
    )
    let controls = try XCTUnwrap(manifest["controls"] as? [[String: Any]])
    XCTAssertEqual(controls.count, 1)
    let grayscaleAlphaControl = try XCTUnwrap(controls.first)
    XCTAssertEqual(grayscaleAlphaControl["id"] as? String, "grayscaleAlpha8NonInterlaced")

    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 32, height: 32),
      contentMode: .fit,
      colorPolicy: .preserveSource
    )
    let bounded = try BoundedPNGDecoder(maximumOperationByteCharge: 1 * 1_024 * 1_024)
    let imageIO = ImageIOImageDecoder()
    for item in cases {
      let id = try XCTUnwrap(item["id"] as? String)
      let sourceFacts = try XCTUnwrap(item["source"] as? [String: Any])
      let derivedFacts = try XCTUnwrap(item["derived"] as? [String: Any])
      let sourceFile = try XCTUnwrap(sourceFacts["file"] as? String)
      let derivedFile = try XCTUnwrap(derivedFacts["file"] as? String)
      let source = try Data(
        contentsOf: pngSuiteAdam7ChannelsRootURL().appendingPathComponent(sourceFile)
      )
      let derived = try Data(
        contentsOf: pngSuiteAdam7ChannelsRootURL().appendingPathComponent(derivedFile)
      )
      XCTAssertEqual(source.count, sourceFacts["byteCount"] as? Int, id)
      XCTAssertEqual(sha256(source), sourceFacts["sha256"] as? String, id)
      XCTAssertEqual(derived.count, derivedFacts["byteCount"] as? Int, id)
      XCTAssertEqual(sha256(derived), derivedFacts["sha256"] as? String, id)

      let sourceChunks = try pngChunks(source)
      let derivedChunks = try pngChunks(derived)
      XCTAssertEqual(
        try XCTUnwrap(sourceChunks.first(where: { $0.type == "IHDR" })).payload,
        try XCTUnwrap(derivedChunks.first(where: { $0.type == "IHDR" })).payload,
        id
      )
      let sourceIDAT = sourceChunks.filter { $0.type == "IDAT" }.reduce(into: Data()) {
        $0.append($1.payload)
      }
      let derivedIDAT = derivedChunks.filter { $0.type == "IDAT" }.reduce(into: Data()) {
        $0.append($1.payload)
      }
      XCTAssertEqual(sourceIDAT, derivedIDAT, id)
      XCTAssertEqual(sourceIDAT.count, sourceFacts["idatByteCount"] as? Int, id)
      XCTAssertEqual(sha256(sourceIDAT), sourceFacts["idatSHA256"] as? String, id)
      XCTAssertTrue(sourceChunks.contains(where: { $0.type == "gAMA" }), id)
      XCTAssertFalse(derivedChunks.contains(where: { $0.type == "gAMA" }), id)
      XCTAssertEqual(
        try XCTUnwrap(derivedChunks.first(where: { $0.type == "sRGB" })).payload,
        Data([0]),
        id
      )

      XCTAssertThrowsError(
        try bounded.decodePackedRGBA8(data: source, request: request, limits: .coreV1)
      ) { error in
        XCTAssertEqual(error as? BoundedPNGDecodeError, .unsupportedSourceSemantics, id)
      }
      let limits = DecodeLimits(
        maximumEncodedBytes: derived.count,
        maximumDimension: 32,
        maximumPixelCount: 1_024,
        maximumFrameCount: 1,
        maximumMetadataBytes: 1_024,
        maximumAuxiliaryAttachments: 0,
        allowedFormats: [.png]
      )
      let probe = try bounded.probe(data: derived, limits: limits)
      XCTAssertEqual(probe.pixelWidth, 32, id)
      XCTAssertEqual(probe.pixelHeight, 32, id)
      XCTAssertEqual(probe.sourceColorProfile, .standardSRGB, id)
      let ledger = try bounded.packedRGBA8ResourceLedger(
        data: derived,
        request: request,
        limits: limits
      )
      XCTAssertEqual(
        ledger.operationPeak,
        .bounded(try XCTUnwrap(item["expectedOperationPeakBytes"] as? Int)),
        id
      )
      XCTAssertEqual(ledger.transferredOutput, .bounded(4_096), id)
      XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8, id)
      let boundedPixels = try bounded.decodePackedRGBA8(
        data: derived,
        request: request,
        limits: limits
      )
      let imageIOPixels = try imageIO.decodePackedRGBA8(
        data: derived,
        request: request,
        limits: limits
      )
      if id == "grayscaleAlpha8" {
        let controlSourceFacts = try XCTUnwrap(grayscaleAlphaControl["source"] as? [String: Any])
        let controlDerivedFacts = try XCTUnwrap(grayscaleAlphaControl["derived"] as? [String: Any])
        let controlSourceFile = try XCTUnwrap(controlSourceFacts["file"] as? String)
        let controlDerivedFile = try XCTUnwrap(controlDerivedFacts["file"] as? String)
        let controlSource = try Data(
          contentsOf: pngSuiteAdam7ChannelsRootURL().appendingPathComponent(controlSourceFile)
        )
        let controlDerived = try Data(
          contentsOf: pngSuiteAdam7ChannelsRootURL().appendingPathComponent(controlDerivedFile)
        )
        XCTAssertEqual(controlSource.count, controlSourceFacts["byteCount"] as? Int)
        XCTAssertEqual(sha256(controlSource), controlSourceFacts["sha256"] as? String)
        XCTAssertEqual(controlDerived.count, controlDerivedFacts["byteCount"] as? Int)
        XCTAssertEqual(sha256(controlDerived), controlDerivedFacts["sha256"] as? String)
        let controlSourceChunks = try pngChunks(controlSource)
        let controlDerivedChunks = try pngChunks(controlDerived)
        let controlSourceIDAT = controlSourceChunks.filter { $0.type == "IDAT" }.reduce(into: Data()) {
          $0.append($1.payload)
        }
        let controlDerivedIDAT = controlDerivedChunks.filter { $0.type == "IDAT" }.reduce(into: Data()) {
          $0.append($1.payload)
        }
        XCTAssertEqual(controlSourceIDAT, controlDerivedIDAT)
        XCTAssertTrue(controlSourceChunks.contains(where: { $0.type == "gAMA" }))
        XCTAssertFalse(controlDerivedChunks.contains(where: { $0.type == "gAMA" }))
        XCTAssertEqual(
          try XCTUnwrap(controlDerivedChunks.first(where: { $0.type == "sRGB" })).payload,
          Data([0])
        )
        let controlLimits = DecodeLimits(
          maximumEncodedBytes: controlDerived.count,
          maximumDimension: 32,
          maximumPixelCount: 1_024,
          maximumFrameCount: 1,
          maximumMetadataBytes: 1_024,
          maximumAuxiliaryAttachments: 0,
          allowedFormats: [.png]
        )
        let boundedControl = try bounded.decodePackedRGBA8(
          data: controlDerived,
          request: request,
          limits: controlLimits
        )
        let imageIOControl = try imageIO.decodePackedRGBA8(
          data: controlDerived,
          request: request,
          limits: controlLimits
        )
        XCTAssertEqual(boundedPixels, boundedControl, "GA bounded scan-order invariance")
        XCTAssertEqual(imageIOPixels, imageIOControl, "GA ImageIO scan-order invariance")
      } else {
        XCTAssertEqual(boundedPixels, imageIOPixels, id)
      }
    }

    let license = try String(
      contentsOf: pngSuiteAdam7ChannelsRootURL().appendingPathComponent("PngSuite.LICENSE"),
      encoding: .utf8
    )
    XCTAssertTrue(
      license.contains(
        "Permission to use, copy, modify and distribute these images for any\npurpose and without fee is hereby granted."
      )
    )
  }

  private func actualFixtureURL() -> URL {
    packageRootURL()
      .appendingPathComponent("Evidence/Fixtures/IndependentPNGActual/v1")
      .appendingPathComponent("pale-blue-dot-cropped-2.png")
  }

  private func actualManifestURL() -> URL {
    packageRootURL()
      .appendingPathComponent("Evidence/Fixtures/IndependentPNGActual/v1")
      .appendingPathComponent("manifest.json")
  }

  private func pngSuiteFixtureRootURL() -> URL {
    packageRootURL()
      .appendingPathComponent("Evidence/Fixtures/IndependentPNGAdam7Indexed/v1")
  }

  private func pngSuiteSourceFixtureURL(bitDepth: Int) -> URL {
    pngSuiteFixtureRootURL().appendingPathComponent(
      String(format: "source-basi3p%02d.png", bitDepth)
    )
  }

  private func pngSuiteDerivedFixtureURL(bitDepth: Int) -> URL {
    pngSuiteFixtureRootURL().appendingPathComponent(
      String(format: "basi3p%02d-srgb-idat-preserved.png", bitDepth)
    )
  }

  private func pngSuiteManifestURL() -> URL {
    pngSuiteFixtureRootURL().appendingPathComponent("manifest.json")
  }

  private func pngSuiteLicenseURL() -> URL {
    pngSuiteFixtureRootURL().appendingPathComponent("PngSuite.LICENSE")
  }

  private func pngSuiteAdam7ChannelsRootURL() -> URL {
    packageRootURL()
      .appendingPathComponent("Evidence/Fixtures/IndependentPNGAdam7Channels/v1")
  }

  private func pngSuiteAdam7ChannelsManifestURL() -> URL {
    pngSuiteAdam7ChannelsRootURL().appendingPathComponent("manifest.json")
  }

  private func packageRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func pngChunks(_ data: Data) throws -> [(type: String, payload: Data)] {
    let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    guard data.starts(with: signature) else { throw PNGFixtureError.malformed }
    var offset = signature.count
    var result: [(type: String, payload: Data)] = []
    while offset < data.count {
      guard offset + 12 <= data.count else { throw PNGFixtureError.malformed }
      let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      let payloadStart = offset + 8
      let payloadEnd = payloadStart + length
      guard payloadEnd + 4 <= data.count,
        let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
      else { throw PNGFixtureError.malformed }
      result.append((type, Data(data[payloadStart..<payloadEnd])))
      offset = payloadEnd + 4
      if type == "IEND" {
        guard offset == data.count else { throw PNGFixtureError.malformed }
        return result
      }
    }
    throw PNGFixtureError.malformed
  }

  private func replacingPNGChunkPayload(
    _ data: Data,
    type targetType: String,
    payload replacement: Data
  ) throws -> Data {
    let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    guard data.starts(with: signature), targetType.utf8.count == 4 else {
      throw PNGFixtureError.malformed
    }
    var output = signature
    var offset = signature.count
    var replaced = false
    while offset < data.count {
      guard offset + 12 <= data.count else { throw PNGFixtureError.malformed }
      let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      let payloadStart = offset + 8
      let payloadEnd = payloadStart + length
      guard payloadEnd + 4 <= data.count,
        let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
      else { throw PNGFixtureError.malformed }
      if type == targetType {
        guard !replaced else { throw PNGFixtureError.malformed }
        output.append(contentsOf: pngUInt32Bytes(UInt32(replacement.count)))
        let typeBytes = Data(targetType.utf8)
        output.append(typeBytes)
        output.append(replacement)
        output.append(contentsOf: pngUInt32Bytes(pngCRC32(typeBytes + replacement)))
        replaced = true
      } else {
        output.append(data[offset..<(payloadEnd + 4)])
      }
      offset = payloadEnd + 4
    }
    guard replaced else { throw PNGFixtureError.malformed }
    return output
  }

  private func pngUInt32Bytes(_ value: UInt32) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value >> 24),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value),
    ]
  }

  private func pngCRC32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc & 1) == 0 ? (crc >> 1) : ((crc >> 1) ^ 0xEDB8_8320)
      }
    }
    return crc ^ UInt32.max
  }

  private enum PNGFixtureError: Error {
    case malformed
  }
}
