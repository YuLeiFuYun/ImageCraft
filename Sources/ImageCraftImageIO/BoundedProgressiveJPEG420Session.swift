import Foundation
import ImageCraftCore

/// Stable public failures specific to the opt-in independent progressive JFIF 4:2:0 session.
public enum BoundedProgressiveJPEG420Error: Error, Equatable, Sendable {
  /// The source is structurally decodable JPEG but uses semantics outside the qualified JFIF 4:2:0 profile.
  case unsupportedSourceSemantics
  /// The codec-owned peak required by the source exceeds the hard budget supplied at initialization.
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
}

/// Opt-in final-only progressive JPEG session backed by ImageCraft's independent JFIF 4:2:0 kernel.
///
/// This surface deliberately publishes no preview `DecodedImage`: `append(_:)` always returns `nil`.
/// It exposes the existing arbitrary-chunk/session lifecycle and an exact codec-owned RGB8 finalization
/// without crossing Core Graphics. Once the complete source is accepted, a bounded host must inspect
/// `packedRGB8FinalizationResourceLedger()` before calling `finishWithPackedRGB8()`. The encoded source
/// remains caller-owned; hosts compose it with codec-owned phases via the ledger's coexistence helper.
///
/// The qualified source domain remains deliberately narrow: progressive 8-bit three-component JFIF
/// using 4:2:0 sampling, the already-qualified scan/progression/table subset, no ICC/Exif/auxiliary color
/// authority, and the hard `DecodeLimits` supplied at initialization. This type does not make the
/// independent kernel the default JPEG backend.
public final class BoundedProgressiveJPEG420Session:
  ProgressiveImagePackedRGB8FinalizingSession,
  @unchecked Sendable
{
  private let implementation: JPEGIndependentProgressive420SessionQualification

  public init(
    maximumCodecOwnedByteCharge: Int,
    limits: DecodeLimits = .coreV1
  ) throws {
    guard maximumCodecOwnedByteCharge > 0 else {
      throw ImageCodecContractError.invalidResourceEstimate
    }
    do {
      implementation = try JPEGIndependentProgressive420SessionQualification(
        maximumCodecOwnedByteCharge: maximumCodecOwnedByteCharge,
        limits: limits,
        previewCadence: .finalOnly
      )
    } catch let error as JPEGIndependentProgressive420Decoder.IncrementalSessionError {
      throw Self.translate(error)
    } catch let error as JPEGIndependentProgressive420Error {
      throw Self.translate(error)
    }
  }

  public var receivedByteCount: Int { implementation.receivedByteCount }

  /// Accepts arbitrary source chunks. The final-only public profile intentionally publishes no preview.
  public func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
    try translated { try implementation.append(chunk) }
  }

  /// Closes the session without transferring the packed final value.
  /// Hosts that need pixels should call `finishWithPackedRGB8()` instead.
  public func finish() throws {
    try translated { try implementation.finish() }
  }

  public func cancel() {
    implementation.cancel()
  }

  public func packedRGB8FinalizationResourceLedger() throws
    -> ImageDecodeResourceLedgerSnapshot?
  {
    try translated { try implementation.packedRGB8FinalizationResourceLedger() }
  }

  public func finishWithPackedRGB8() throws -> ImageProgressivePackedRGB8Finalization {
    try translated { try implementation.finishWithPackedRGB8() }
  }

  private func translated<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as JPEGIndependentProgressive420Decoder.IncrementalSessionError {
      throw Self.translate(error)
    } catch let error as JPEGIndependentProgressive420Error {
      throw Self.translate(error)
    }
  }

  private static func translate(
    _ error: JPEGIndependentProgressive420Decoder.IncrementalSessionError
  ) -> Error {
    switch error {
    case .invalidBudget:
      return ImageCodecContractError.invalidResourceEstimate
    case .codecOwnedBudgetExceeded(let requiredBytes, let maximumBytes):
      return BoundedProgressiveJPEG420Error.operationBudgetExceeded(
        requiredBytes: requiredBytes,
        maximumBytes: maximumBytes
      )
    case .transportWindowExceeded, .pendingTableStateExceeded:
      return BoundedProgressiveJPEG420Error.unsupportedSourceSemantics
    case .sessionTerminal:
      return ImageCraftError.progressiveSessionFinished
    }
  }

  private static func translate(_ error: JPEGIndependentProgressive420Error) -> Error {
    switch error {
    case .unsupportedSourceSemantics:
      return BoundedProgressiveJPEG420Error.unsupportedSourceSemantics
    case .operationBudgetExceeded(let requiredBytes, let maximumBytes):
      return BoundedProgressiveJPEG420Error.operationBudgetExceeded(
        requiredBytes: requiredBytes,
        maximumBytes: maximumBytes
      )
    case .invalidOperationBudget:
      return ImageCodecContractError.invalidResourceEstimate
    case .stateAllocationFailed:
      return ImageCraftError.decodeFailed
    }
  }
}
