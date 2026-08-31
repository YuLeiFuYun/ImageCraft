import Foundation
import XCTest

@testable import ImageCraftImageIO

final class JPEGProgressiveOwnedVariableStateTests: XCTestCase {
  func testTiny420PlanOwnsAlignedRowsWithoutAllocatorMagicConstants() throws {
    let plan = try JPEGProgressiveOwnedVariableStatePlan.inspect(
      fixture(named: "jpeg-progressive-420.jpg")
    )

    XCTAssertEqual(plan.coefficientStorageBytes, 1_536)
    XCTAssertEqual(plan.logicalRowWorkspaceBytes, 896)
    XCTAssertEqual(plan.rowWorkspaceStorageBytes, 2_816)
    XCTAssertEqual(plan.totalVariableStateBytes, 4_352)
    XCTAssertEqual(plan.buffers.count, 8)
    XCTAssertTrue(plan.buffers.allSatisfy { $0.offset % 64 == 0 })
    XCTAssertTrue(plan.buffers.allSatisfy { $0.rowStrideBytes % 64 == 0 })
  }

  func testLarge420PlanKeepsProvenGeometryButDropsPrivatePoolOverhead() throws {
    let plan = try JPEGProgressiveOwnedVariableStatePlan.inspect(
      syntheticSOF(width: 1_920, height: 1_285, sampling: [0x22, 0x11, 0x11])
    )

    XCTAssertEqual(plan.coefficientStorageBytes, 7_464_960)
    XCTAssertEqual(plan.logicalRowWorkspaceBytes, 65_280)
    XCTAssertEqual(plan.rowWorkspaceStorageBytes, 65_280)
    XCTAssertEqual(plan.totalVariableStateBytes, 7_530_240)
  }

  func testArenaRejectsBeforeAllocationAndExposesDisjointOwnedBuffers() throws {
    let plan = try JPEGProgressiveOwnedVariableStatePlan.inspect(
      fixture(named: "jpeg-progressive-420.jpg")
    )
    XCTAssertThrowsError(
      try JPEGProgressiveOwnedVariableStateArena(
        plan: plan,
        maximumBytes: plan.totalVariableStateBytes - 1
      )
    ) { error in
      XCTAssertEqual(
        error as? JPEGProgressiveOwnedVariableStateArenaError,
        .budgetExceeded(
          requiredBytes: plan.totalVariableStateBytes,
          maximumBytes: plan.totalVariableStateBytes - 1
        )
      )
    }

    let arena = try JPEGProgressiveOwnedVariableStateArena(
      plan: plan,
      maximumBytes: plan.totalVariableStateBytes
    )
    var ranges: [Range<UInt>] = []
    for layout in plan.buffers {
      let buffer = try arena.buffer(role: layout.role, componentIndex: layout.componentIndex)
      let start = UInt(bitPattern: buffer.baseAddress!)
      XCTAssertEqual(start % 64, 0)
      XCTAssertEqual(buffer.count, layout.byteCount)
      XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
      ranges.append(start..<(start + UInt(buffer.count)))
    }
    for left in ranges.indices {
      for right in ranges.indices where right > left {
        XCTAssertTrue(ranges[left].clamped(to: ranges[right]).isEmpty)
      }
    }
  }

  private func fixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      )
    )
    return try Data(contentsOf: url)
  }

  private func syntheticSOF(width: Int, height: Int, sampling: [UInt8]) -> Data {
    let segmentLength = 8 + 3 * sampling.count
    var bytes = Data([
      0xFF, 0xD8,
      0xFF, 0xC2,
      UInt8((segmentLength >> 8) & 0xFF), UInt8(segmentLength & 0xFF),
      8,
      UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF),
      UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF),
      UInt8(sampling.count),
    ])
    for (index, factors) in sampling.enumerated() {
      bytes.append(UInt8(index + 1))
      bytes.append(factors)
      bytes.append(0)
    }
    return bytes
  }
}
