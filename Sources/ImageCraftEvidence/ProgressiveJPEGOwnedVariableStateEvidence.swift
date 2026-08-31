import Foundation
import ImageCraftImageIO

private struct ProgressiveJPEGOwnedVariableStateEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let input: ProgressiveJPEGOwnedVariableStateEvidenceInput
  let plan: JPEGProgressiveOwnedVariableStatePlan
  let exactBudgetAccepted: Bool
  let thresholdMinusOneRejectedBeforeAllocation: Bool
  let allBuffersAligned: Bool
  let allBuffersInitiallyZero: Bool
}

private struct ProgressiveJPEGOwnedVariableStateEvidenceInput: Codable {
  let byteCount: Int
  let sha256: String
}

func writeProgressiveJPEGOwnedVariableStateEvidence(input: URL) throws {
  let data = try Data(contentsOf: input)
  let plan = try JPEGProgressiveOwnedVariableStatePlan.inspect(data)
  let exactArena = try JPEGProgressiveOwnedVariableStateArena(
    plan: plan,
    maximumBytes: plan.totalVariableStateBytes
  )

  var allAligned = true
  var allZero = true
  for layout in plan.buffers {
    let buffer = try exactArena.buffer(role: layout.role, componentIndex: layout.componentIndex)
    guard let baseAddress = buffer.baseAddress else {
      allAligned = false
      allZero = false
      continue
    }
    if UInt(bitPattern: baseAddress) % UInt(JPEGProgressiveOwnedVariableStatePlan.rowAlignmentBytes) != 0 {
      allAligned = false
    }
    if !buffer.allSatisfy({ $0 == 0 }) {
      allZero = false
    }
  }

  var thresholdMinusOneRejected = false
  if plan.totalVariableStateBytes > 0 {
    do {
      _ = try JPEGProgressiveOwnedVariableStateArena(
        plan: plan,
        maximumBytes: plan.totalVariableStateBytes - 1
      )
    } catch JPEGProgressiveOwnedVariableStateArenaError.budgetExceeded(
      let requiredBytes,
      let maximumBytes
    ) where requiredBytes == plan.totalVariableStateBytes
      && maximumBytes == plan.totalVariableStateBytes - 1
    {
      thresholdMinusOneRejected = true
    }
  }

  let report = ProgressiveJPEGOwnedVariableStateEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: "imagecraft-progressive-jpeg-owned-variable-state-v1",
    input: ProgressiveJPEGOwnedVariableStateEvidenceInput(
      byteCount: data.count,
      sha256: sha256(data)
    ),
    plan: plan,
    exactBudgetAccepted: true,
    thresholdMinusOneRejectedBeforeAllocation: thresholdMinusOneRejected,
    allBuffersAligned: allAligned,
    allBuffersInitiallyZero: allZero
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = try encoder.encode(report)
  guard let json = String(data: payload, encoding: .utf8) else {
    throw EvidenceError.invalidArguments
  }
  print(json)
}
