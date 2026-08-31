import Foundation
import ImageCraftCore

/// Stable public failures specific to the opt-in bounded PNG producer.
public enum BoundedPNGDecodeError: Error, Equatable, Sendable {
  /// The requested target geometry or color policy is outside the producer's qualified domain.
  case unsupportedRequest
  /// The source is a valid PNG container but uses semantics this bounded producer has not qualified.
  case unsupportedSourceSemantics
  /// The codec-owned operation would exceed the hard budget supplied at initialization.
  case operationBudgetExceeded
}

/// Opt-in PNG decoder that exposes ImageCraft's independently implemented, codec-owned packed
/// RGBA8 path without changing the default ImageIO backend.
///
/// The accepted source domain is deliberately narrower than general PNG. Unsupported color,
/// metadata, animation, HDR, and sample-depth semantics fail closed. Callers state a hard
/// codec-owned operation budget at construction time and can inspect the phase ledger before
/// decoding.
public struct BoundedPNGDecoder: ImagePackedRGBA8Decoding, Sendable {
  public static let codecDescriptor = PNGIndependentRGBA8Decoder.codecDescriptor

  private let implementation: PNGIndependentRGBA8Decoder

  public var codecDescriptor: ImageCodecDescriptor { Self.codecDescriptor }

  public init(maximumOperationByteCharge: Int) throws {
    guard maximumOperationByteCharge > 0 else {
      throw ImageCodecContractError.invalidResourceEstimate
    }
    implementation = PNGIndependentRGBA8Decoder(
      maximumOperationByteCharge: maximumOperationByteCharge
    )
  }

  public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    try translated { try implementation.probe(data: data, limits: limits) }
  }

  public func packedRGBA8ResourceLedger(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> ImageDecodeResourceLedgerSnapshot {
    try translated {
      try implementation.resourceLedger(data: data, request: request, limits: limits)
    }
  }

  public func decodePackedRGBA8(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> ImagePackedRGBA8 {
    try translated { try implementation.decode(data: data, request: request, limits: limits) }
  }

  private func translated<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as PNGIndependentRGBA8Error {
      switch error {
      case .unsupportedRequest:
        throw BoundedPNGDecodeError.unsupportedRequest
      case .unsupportedSourceSemantics:
        throw BoundedPNGDecodeError.unsupportedSourceSemantics
      case .operationBudgetExceeded:
        throw BoundedPNGDecodeError.operationBudgetExceeded
      }
    } catch is ImagePackedPixelContractError {
      // A package-level packed-value invariant escaping this wrapper is an implementation failure,
      // not a source taxonomy callers can act on.
      throw ImageCraftError.decodeFailed
    }
  }
}
