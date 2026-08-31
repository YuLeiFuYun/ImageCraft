import Darwin
import Foundation
import ImageCraftCore

package enum JPEGProgressiveOwnedVariableBufferRole: String, Codable, Hashable, Sendable {
  case coefficientPlane
  case upsamplerRows
  case mainControllerRows
}

package struct JPEGProgressiveOwnedVariableBufferLayout: Codable, Equatable, Sendable {
  package let role: JPEGProgressiveOwnedVariableBufferRole
  package let componentIndex: Int
  package let offset: Int
  package let logicalRowBytes: Int
  package let rowStrideBytes: Int
  package let rowCount: Int
  package let byteCount: Int
}

/// ImageCraft-owned storage plan for the geometry-dependent variable state of the narrow
/// progressive-JPEG research seam.
///
/// This deliberately does not imitate libjpeg's private pool allocator. Coefficient planes are
/// flat padded block rows; sample workspaces use an explicit 64-byte row stride chosen by
/// ImageCraft. Controller structs, entropy/quantization tables, source transport buffering and
/// published output are separate fixed/bounded phases and are not hidden inside this value.
package struct JPEGProgressiveOwnedVariableStatePlan: Codable, Equatable, Sendable {
  package static let rowAlignmentBytes = 64

  package let geometry: JPEGProgressiveResourceGeometry
  package let buffers: [JPEGProgressiveOwnedVariableBufferLayout]
  package let coefficientStorageBytes: Int
  package let logicalRowWorkspaceBytes: Int
  package let rowWorkspaceStorageBytes: Int
  package let totalVariableStateBytes: Int

  package static func inspect(_ data: Data) throws -> Self {
    try make(geometry: JPEGProgressiveResourceGeometry.inspect(data))
  }

  package static func make(geometry: JPEGProgressiveResourceGeometry) throws -> Self {
    let components = geometry.components
    guard !components.isEmpty else { throw ImageCraftError.unsupportedOrCorruptImage }
    guard let maximumHorizontal = components.map(\.horizontalSamplingFactor).max(),
      let maximumVertical = components.map(\.verticalSamplingFactor).max(),
      maximumHorizontal > 0,
      maximumVertical > 0
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    var buffers: [JPEGProgressiveOwnedVariableBufferLayout] = []
    buffers.reserveCapacity(components.count * 2 + 2)
    var cursor = 0
    var coefficientStorage = 0
    var logicalRowWorkspace = 0
    var rowWorkspaceStorage = 0

    for (componentIndex, component) in components.enumerated() {
      let logicalRowBytes = try multiplied(component.paddedWidthInBlocks, 128)
      let byteCount = try multiplied(logicalRowBytes, component.paddedHeightInBlocks)
      guard byteCount == component.coefficientPayloadBytes else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      cursor = try roundUp(cursor, rowAlignmentBytes)
      buffers.append(
        JPEGProgressiveOwnedVariableBufferLayout(
          role: .coefficientPlane,
          componentIndex: componentIndex,
          offset: cursor,
          logicalRowBytes: logicalRowBytes,
          rowStrideBytes: logicalRowBytes,
          rowCount: component.paddedHeightInBlocks,
          byteCount: byteCount
        )
      )
      cursor = try added(cursor, byteCount)
      coefficientStorage = try added(coefficientStorage, byteCount)
    }
    guard coefficientStorage == geometry.coefficientArrayPayloadBytes else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    let roundedOutputWidth = try roundUp(geometry.width, maximumHorizontal)
    for (componentIndex, component) in components.enumerated()
    where component.horizontalSamplingFactor != maximumHorizontal
      || component.verticalSamplingFactor != maximumVertical
    {
      let logicalRowBytes = roundedOutputWidth
      let rowStride = try roundUp(logicalRowBytes, rowAlignmentBytes)
      let rowCount = maximumVertical
      let logicalBytes = try multiplied(logicalRowBytes, rowCount)
      let storageBytes = try multiplied(rowStride, rowCount)
      cursor = try roundUp(cursor, rowAlignmentBytes)
      buffers.append(
        JPEGProgressiveOwnedVariableBufferLayout(
          role: .upsamplerRows,
          componentIndex: componentIndex,
          offset: cursor,
          logicalRowBytes: logicalRowBytes,
          rowStrideBytes: rowStride,
          rowCount: rowCount,
          byteCount: storageBytes
        )
      )
      cursor = try added(cursor, storageBytes)
      logicalRowWorkspace = try added(logicalRowWorkspace, logicalBytes)
      rowWorkspaceStorage = try added(rowWorkspaceStorage, storageBytes)
    }

    let mainRowGroups = geometry.fancyVerticalContextRowsRequired ? 10 : 8
    for (componentIndex, component) in components.enumerated() {
      let logicalRowBytes = try multiplied(component.widthInBlocks, 8)
      let rowStride = try roundUp(logicalRowBytes, rowAlignmentBytes)
      let rowCount = try multiplied(component.verticalSamplingFactor, mainRowGroups)
      let logicalBytes = try multiplied(logicalRowBytes, rowCount)
      let storageBytes = try multiplied(rowStride, rowCount)
      cursor = try roundUp(cursor, rowAlignmentBytes)
      buffers.append(
        JPEGProgressiveOwnedVariableBufferLayout(
          role: .mainControllerRows,
          componentIndex: componentIndex,
          offset: cursor,
          logicalRowBytes: logicalRowBytes,
          rowStrideBytes: rowStride,
          rowCount: rowCount,
          byteCount: storageBytes
        )
      )
      cursor = try added(cursor, storageBytes)
      logicalRowWorkspace = try added(logicalRowWorkspace, logicalBytes)
      rowWorkspaceStorage = try added(rowWorkspaceStorage, storageBytes)
    }

    guard logicalRowWorkspace == geometry.fullScaleFancyRowWorkspaceBytes else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let expectedTotal = try added(coefficientStorage, rowWorkspaceStorage)
    guard cursor == expectedTotal else {
      // All current buffer byte counts are multiples of 64. Keep this invariant explicit so a
      // future source format cannot silently introduce uncharged inter-buffer padding.
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return Self(
      geometry: geometry,
      buffers: buffers,
      coefficientStorageBytes: coefficientStorage,
      logicalRowWorkspaceBytes: logicalRowWorkspace,
      rowWorkspaceStorageBytes: rowWorkspaceStorage,
      totalVariableStateBytes: expectedTotal
    )
  }

  private static func roundUp(_ value: Int, _ alignment: Int) throws -> Int {
    guard value >= 0, alignment > 0, alignment & (alignment - 1) == 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let adjusted = try added(value, alignment - 1)
    return adjusted & ~(alignment - 1)
  }

  private static func added(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }

  private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }
}

package enum JPEGProgressiveOwnedVariableStateArenaError: Error, Equatable, Sendable {
  case invalidBudget
  case budgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case allocationFailed(byteCount: Int)
  case bufferNotFound
}

/// Real package-owned backing for `JPEGProgressiveOwnedVariableStatePlan`.
///
/// Allocation is admitted before `posix_memalign`; the single backing is released synchronously in
/// `deinit`. The arena is intentionally package-scoped and non-Sendable until a decoder state
/// machine owns its actor/thread confinement explicitly.
package final class JPEGProgressiveOwnedVariableStateArena {
  package let plan: JPEGProgressiveOwnedVariableStatePlan
  private let baseAddress: UnsafeMutableRawPointer

  package init(
    plan: JPEGProgressiveOwnedVariableStatePlan,
    maximumBytes: Int
  ) throws {
    guard maximumBytes >= 0 else {
      throw JPEGProgressiveOwnedVariableStateArenaError.invalidBudget
    }
    guard plan.totalVariableStateBytes <= maximumBytes else {
      throw JPEGProgressiveOwnedVariableStateArenaError.budgetExceeded(
        requiredBytes: plan.totalVariableStateBytes,
        maximumBytes: maximumBytes
      )
    }
    var pointer: UnsafeMutableRawPointer?
    let result = posix_memalign(
      &pointer,
      JPEGProgressiveOwnedVariableStatePlan.rowAlignmentBytes,
      max(1, plan.totalVariableStateBytes)
    )
    guard result == 0, let pointer else {
      throw JPEGProgressiveOwnedVariableStateArenaError.allocationFailed(
        byteCount: plan.totalVariableStateBytes
      )
    }
    self.plan = plan
    self.baseAddress = pointer
    if plan.totalVariableStateBytes > 0 {
      memset(pointer, 0, plan.totalVariableStateBytes)
    }
  }

  deinit {
    free(baseAddress)
  }

  package func buffer(
    role: JPEGProgressiveOwnedVariableBufferRole,
    componentIndex: Int
  ) throws -> UnsafeMutableRawBufferPointer {
    guard let layout = plan.buffers.first(where: {
      $0.role == role && $0.componentIndex == componentIndex
    }) else {
      throw JPEGProgressiveOwnedVariableStateArenaError.bufferNotFound
    }
    return UnsafeMutableRawBufferPointer(
      start: baseAddress.advanced(by: layout.offset),
      count: layout.byteCount
    )
  }
}
