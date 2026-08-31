import ImageCraftCore
import XCTest

final class ImageDecodeResourceLedgerTests: XCTestCase {
    func testKnownPhaseBoundsRemainSeparated() throws {
        let ledger = try XCTUnwrap(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 1_024,
                retainedBetweenCalls: .bounded(1_024),
                operationPeak: .bounded(8_192),
                transferredOutput: .bounded(4_096)
            )
        )

        XCTAssertEqual(ledger.bytesUpperBound(for: .retainedBetweenCalls), 1_024)
        XCTAssertEqual(ledger.bytesUpperBound(for: .operationPeak), 8_192)
        XCTAssertEqual(ledger.bytesUpperBound(for: .transferredOutput), 4_096)
        XCTAssertEqual(
            ledger.branchCoexistenceBound(callerRetainedOutputBytes: 12_288),
            .bounded(20_480)
        )
        XCTAssertEqual(
            ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: 787),
            .bounded(8_979)
        )
        XCTAssertEqual(
            ledger.coexistenceBound(for: .transferredOutput, callerRetainedBytes: 787),
            .bounded(4_883)
        )
    }

    func testUnknownPhasePreservesReasonInsteadOfInventingAnUpperBound() throws {
        let ledger = try XCTUnwrap(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 1_024,
                retainedBetweenCalls: .unknown(.frameworkPrivateRetainedState),
                operationPeak: .unknown(.frameworkPrivateOperationAllocation),
                transferredOutput: .unknown(.frameworkChosenOutputLayout)
            )
        )

        XCTAssertEqual(ledger.retainedKnownBytes, 1_024)
        XCTAssertEqual(
            ledger.bound(for: .retainedBetweenCalls),
            .unknown(.frameworkPrivateRetainedState)
        )
        XCTAssertNil(ledger.bytesUpperBound(for: .retainedBetweenCalls))
        XCTAssertNil(ledger.bytesUpperBound(for: .operationPeak))
        XCTAssertNil(ledger.bytesUpperBound(for: .transferredOutput))
        XCTAssertEqual(
            ledger.branchCoexistenceBound(callerRetainedOutputBytes: 4_096),
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(
            ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: 787),
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(
            ledger.coexistenceBound(for: .transferredOutput, callerRetainedBytes: 787),
            .unknown(.frameworkChosenOutputLayout)
        )
    }

    func testTerminalSnapshotProvesCodecOwnedReclaim() {
        let ledger = ImageDecodeResourceLedgerSnapshot.terminal

        XCTAssertTrue(ledger.isTerminal)
        XCTAssertEqual(ledger.outputLayoutAuthority, .none)
        XCTAssertEqual(ledger.bytesUpperBound(for: .retainedBetweenCalls), 0)
        XCTAssertEqual(ledger.bytesUpperBound(for: .operationPeak), 0)
        XCTAssertEqual(ledger.bytesUpperBound(for: .transferredOutput), 0)
        XCTAssertEqual(
            ledger.branchCoexistenceBound(callerRetainedOutputBytes: 256),
            .bounded(256)
        )
    }

    func testInvalidOrAmbiguousModelsAreRejected() {
        XCTAssertNil(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 10,
                retainedBetweenCalls: .bounded(9),
                operationPeak: .bounded(10),
                transferredOutput: .bounded(1)
            )
        )
        XCTAssertNil(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 1,
                retainedBetweenCalls: .unknown(.frameworkPrivateRetainedState),
                operationPeak: .bounded(1),
                transferredOutput: .bounded(0),
                isTerminal: true
            )
        )
    }

    func testBranchCoexistenceSaturatesInsteadOfWrapping() throws {
        let ledger = try XCTUnwrap(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 1,
                retainedBetweenCalls: .bounded(1),
                operationPeak: .bounded(Int.max),
                transferredOutput: .bounded(1)
            )
        )
        XCTAssertEqual(
            ledger.branchCoexistenceBound(callerRetainedOutputBytes: 1),
            .bounded(Int.max)
        )
        XCTAssertEqual(
            ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: 1),
            .bounded(Int.max)
        )
        XCTAssertNil(ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: -1))
    }
}
