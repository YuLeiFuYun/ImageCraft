/// Why a resource phase cannot currently publish a trustworthy total byte upper bound.
///
/// Unknown is an explicit contract state. A caller must not substitute a tight-pixel estimate,
/// logical byte count, or observed RSS sample for one of these missing bounds.
public enum ImageDecodeResourceUnknownReason: String, Codable, Hashable, Sendable {
    /// A framework object is retained across calls and its private allocations are not bounded.
    case frameworkPrivateRetainedState
    /// The framework may allocate private transient state while the decode operation is running.
    case frameworkPrivateOperationAllocation
    /// The framework chooses the returned image row stride/backing allocation.
    case frameworkChosenOutputLayout
    /// Preserve-source output still depends on framework-derived color state whose retained payload
    /// cannot be reduced to a known value-level charge.
    case frameworkChosenOutputColorState
}

/// A phase is either fully byte-charge-bounded or explicitly unknown for one causal reason.
///
/// The bound is an admission-accounting charge for payload bytes whose ownership and size the codec
/// can prove. It is deliberately not a process-RSS theorem: allocator bookkeeping, object headers,
/// VM page rounding, framework code/data and unrelated caches are outside this charge.
public enum ImageDecodeResourceBound: Codable, Equatable, Sendable {
    case bounded(Int)
    case unknown(ImageDecodeResourceUnknownReason)

    public var bytesUpperBound: Int? {
        switch self {
        case .bounded(let bytes): bytes
        case .unknown: nil
        }
    }
}

/// Package-scoped resource accounting shared by concrete decode backends and qualification tools.
///
/// The ledger separates three ownership phases instead of collapsing them into one "memory"
/// number:
///
/// - bytes retained by the codec between calls;
/// - the total codec-owned peak while the next decode operation is executing;
/// - payload-byte charge transferred to the caller after an output is published.
///
/// `retainedKnownBytes` remains useful even when a phase total is unknown. It is a partial owned
/// byte count, not a substitute for the corresponding `ImageDecodeResourceBound`.
public enum ImageDecodeResourcePhase: String, Codable, CaseIterable, Hashable, Sendable {
    case retainedBetweenCalls
    case operationPeak
    case transferredOutput
}

/// Who determines the published pixel backing layout for resource-accounting purposes.
/// This is deliberately separate from the public interoperability representation: a `CGImage`
/// adapter can still wrap a codec-owned RGBA8 payload while exposing different pixel-format
/// semantics from a framework-native `CGImage`.
public enum ImageDecodeOutputLayoutAuthority: String, Codable, Hashable, Sendable {
    case none
    case frameworkChosen
    case codecOwnedRGB8
    case codecOwnedRGBA8
    case codecOwnedStraightRGBA16LE
}

public struct ImageDecodeResourceLedgerSnapshot: Codable, Equatable, Sendable {
    public let retainedKnownBytes: Int
    public let retainedBetweenCalls: ImageDecodeResourceBound
    public let operationPeak: ImageDecodeResourceBound
    public let transferredOutput: ImageDecodeResourceBound
    public let outputLayoutAuthority: ImageDecodeOutputLayoutAuthority
    public let isTerminal: Bool

    public init?(
        retainedKnownBytes: Int,
        retainedBetweenCalls: ImageDecodeResourceBound,
        operationPeak: ImageDecodeResourceBound,
        transferredOutput: ImageDecodeResourceBound,
        outputLayoutAuthority: ImageDecodeOutputLayoutAuthority = .frameworkChosen,
        isTerminal: Bool = false
    ) {
        guard retainedKnownBytes >= 0,
            Self.isValid(retainedBetweenCalls, minimumKnownBytes: retainedKnownBytes),
            Self.isValid(operationPeak, minimumKnownBytes: retainedKnownBytes),
            Self.isValid(transferredOutput, minimumKnownBytes: 0)
        else { return nil }
        if isTerminal {
            guard retainedKnownBytes == 0,
                retainedBetweenCalls == .bounded(0),
                operationPeak == .bounded(0),
                transferredOutput == .bounded(0)
            else { return nil }
        }
        self.retainedKnownBytes = retainedKnownBytes
        self.retainedBetweenCalls = retainedBetweenCalls
        self.operationPeak = operationPeak
        self.transferredOutput = transferredOutput
        self.outputLayoutAuthority = outputLayoutAuthority
        self.isTerminal = isTerminal
    }

    public static var terminal: Self {
        Self(
            retainedKnownBytes: 0,
            retainedBetweenCalls: .bounded(0),
            operationPeak: .bounded(0),
            transferredOutput: .bounded(0),
            outputLayoutAuthority: .none,
            isTerminal: true
        )!
    }

    public func bound(for phase: ImageDecodeResourcePhase) -> ImageDecodeResourceBound {
        switch phase {
        case .retainedBetweenCalls: retainedBetweenCalls
        case .operationPeak: operationPeak
        case .transferredOutput: transferredOutput
        }
    }

    public func bytesUpperBound(for phase: ImageDecodeResourcePhase) -> Int? {
        bound(for: phase).bytesUpperBound
    }

    /// Composes one codec phase with payload bytes that remain owned by the caller for the same
    /// lifetime. Typical inputs are the encoded source retained by a one-shot host, or previously
    /// published outputs kept alive while a later operation runs. Caller-owned bytes are added only
    /// at this host boundary; they are not reassigned to the codec ledger.
    ///
    /// Unknown codec authority stays unknown with the original causal reason. Addition saturates at
    /// `Int.max` rather than wrapping. A negative caller charge is invalid and returns `nil`.
    public func coexistenceBound(
        for phase: ImageDecodeResourcePhase,
        callerRetainedBytes: Int
    ) -> ImageDecodeResourceBound? {
        guard callerRetainedBytes >= 0 else { return nil }
        switch bound(for: phase) {
        case .bounded(let bytes):
            return .bounded(Self.saturatedAdding(bytes, callerRetainedBytes))
        case .unknown(let reason):
            return .unknown(reason)
        }
    }

    /// Adds caller-owned outputs that may coexist with a new codec operation. This keeps previous
    /// preview/final surfaces charged to their current owner instead of assigning them back to the
    /// codec after publication.
    public func branchCoexistenceBound(
        callerRetainedOutputBytes: Int
    ) -> ImageDecodeResourceBound? {
        coexistenceBound(
            for: .operationPeak,
            callerRetainedBytes: callerRetainedOutputBytes
        )
    }

    package static func saturatedAdding(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func isValid(
        _ bound: ImageDecodeResourceBound,
        minimumKnownBytes: Int
    ) -> Bool {
        switch bound {
        case .bounded(let bytes): bytes >= minimumKnownBytes
        case .unknown: true
        }
    }
}

/// Optional public resource-authority surface for an already-created prepared decode token.
///
/// The returned ledger covers state retained by the decoder for this preparation, the next decode
/// operation, and the output transfer. It does not describe or bound the earlier `prepare(...)` or
/// progressive preparation-creation operation itself. `nil` means the decoder no longer owns a
/// matching live token (for example after consumption or discard). Hard-bounded hosts must inspect
/// and honor any `.unknown` phase before consuming the preparation.
public protocol PreparedImageResourceInspecting: PreparedImageDecoding {
    func preparationResourceLedger(
        _ preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) -> ImageDecodeResourceLedgerSnapshot?
}
