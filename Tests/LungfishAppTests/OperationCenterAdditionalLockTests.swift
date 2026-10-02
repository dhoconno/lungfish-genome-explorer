import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class OperationCenterAdditionalLockTests: XCTestCase {
    func testOutputLeaseRetainsDurableHistoryTargetAndRemainsHeldUntilCancellationDrains() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = root.appendingPathComponent("attempt.lungfishrun")
        let output = root.appendingPathComponent("results")
        let id = center.begin(title: "Repeat", detail: "Local fixture", operationType: .workflow,
            targetBundleURL: history, additionalLockedBundleURLs: [output, output], cliCommand: nil, onCancel: {}).rowID
        XCTAssertEqual(center.items.first { $0.id == id }?.targetBundleURL, history)
        XCTAssertFalse(center.canStartOperation(on: output))
        center.cancel(id: id)
        XCTAssertFalse(center.canStartOperation(on: history))
        XCTAssertFalse(center.canStartOperation(on: output))
        center.acknowledgeCancellation(id: id)
        XCTAssertTrue(center.canStartOperation(on: history))
        XCTAssertTrue(center.canStartOperation(on: output))
    }

    func testAdditionalOutputLeaseRejectsNestedOverlapInBothDirectionsAndAllowsSiblings() {
        for reversed in [false, true] {
            let center = OperationCenter()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let outer = root.appendingPathComponent("results")
            let inner = outer.appendingPathComponent("child")
            let first = center.begin(title: "First", detail: "Fixture", operationType: .download, targetBundleURL: root.appendingPathComponent("first.lungfishrun"),
                additionalLockedBundleURLs: [reversed ? inner : outer],
                cliCommand: nil).rowID
            let nextHistory = root.appendingPathComponent("second.lungfishrun")
            let refused = center.begin(title: "Nested", detail: "Fixture", operationType: .download, targetBundleURL: nextHistory,
                additionalLockedBundleURLs: [reversed ? outer : inner],
                cliCommand: nil).rowID
            XCTAssertEqual(center.items.first(where: { $0.id == refused })?.state, .failed)
            XCTAssertTrue(center.canStartOperation(on: nextHistory))
            let sibling = center.begin(title: "Sibling", detail: "Fixture", operationType: .download, targetBundleURL: root.appendingPathComponent("third.lungfishrun"),
                additionalLockedBundleURLs: [root.appendingPathComponent("results-other")],
                cliCommand: nil).rowID
            XCTAssertEqual(center.items.first(where: { $0.id == sibling })?.state, .running)
            XCTAssertEqual(center.items.first(where: { $0.id == first })?.state, .running)
        }
    }

    func testActiveTreeLeaseRejectsLaterOrdinaryAncestorAndDescendantWritersThroughDrain() {
        for ordinaryIsAncestor in [false, true] {
            let center = OperationCenter()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let output = root.appendingPathComponent("outputs/results")
            let ordinaryTarget = ordinaryIsAncestor ? output.deletingLastPathComponent() : output.appendingPathComponent("child")
            let history = root.appendingPathComponent("history.lungfishrun")
            let owner = center.begin(title: "Tree owner", detail: "Fixture", operationType: .download, targetBundleURL: history,
                additionalLockedBundleURLs: [output], cliCommand: nil, onCancel: {}).rowID
            XCTAssertFalse(center.canStartOperation(on: ordinaryTarget))
            XCTAssertEqual(center.activeLockHolder(for: ordinaryTarget)?.id, owner)
            let refused = center.begin(
                title: "Ordinary writer",
                detail: "Fixture",
                operationType: .download,
                targetBundleURL: ordinaryTarget,
                cliCommand: nil
            ).rowID
            XCTAssertEqual(center.items.first(where: { $0.id == refused })?.state, .failed)
            XCTAssertEqual(center.activeLockHolder(for: ordinaryTarget)?.id, owner)
            let sibling = output.deletingLastPathComponent().appendingPathComponent("results-other")
            XCTAssertTrue(center.canStartOperation(on: sibling), "Path components, not a string prefix, define overlap")
            let siblingID = center.begin(
                title: "Sibling writer",
                detail: "Fixture",
                operationType: .download,
                targetBundleURL: sibling,
                cliCommand: nil
            ).rowID
            XCTAssertEqual(center.items.first(where: { $0.id == siblingID })?.state, .running)
            center.cancel(id: owner)
            XCTAssertFalse(center.canStartOperation(on: ordinaryTarget), "A cancellation request does not release the tree")
            XCTAssertEqual(center.activeLockHolder(for: ordinaryTarget)?.id, owner)
            center.acknowledgeCancellation(id: owner)
            XCTAssertTrue(center.canStartOperation(on: ordinaryTarget))
            XCTAssertNil(center.activeLockHolder(for: ordinaryTarget))
            XCTAssertTrue(center.canStartOperation(on: history))
            XCTAssertEqual(center.activeLockHolder(for: sibling)?.id, siblingID)
        }
    }

    func testIncomingTreeLeaseRejectsExistingOrdinaryOverlapWithoutAcquiringAnyRequestedKey() {
        for ordinaryIsAncestor in [false, true] {
            let center = OperationCenter()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let output = root.appendingPathComponent("outputs/results")
            let ordinaryTarget = ordinaryIsAncestor ? output.deletingLastPathComponent() : output.appendingPathComponent("child")
            let owner = center.begin(
                title: "Ordinary owner",
                detail: "Fixture",
                operationType: .download,
                targetBundleURL: ordinaryTarget,
                cliCommand: nil
            ).rowID
            let history = root.appendingPathComponent("new.lungfishrun")
            let unrelated = root.appendingPathComponent("unrelated")
            let refused = center.begin(title: "Tree writer", detail: "Fixture", operationType: .download, targetBundleURL: history,
                additionalLockedBundleURLs: [unrelated, output],
                cliCommand: nil).rowID
            XCTAssertEqual(center.items.first(where: { $0.id == refused })?.state, .failed)
            XCTAssertEqual(center.activeLockHolder(for: ordinaryTarget)?.id, owner)
            XCTAssertTrue(center.canStartOperation(on: history))
            XCTAssertTrue(center.canStartOperation(on: unrelated))
            XCTAssertTrue(center.canStartOperation(on: unrelated.appendingPathComponent("child")))
        }
    }

    func testOrdinaryAncestorAndDescendantLocksKeepTheirLegacyExactScopes() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("child")
        let outer = center.begin(
            title: "Outer ordinary",
            detail: "Fixture",
            operationType: .download,
            targetBundleURL: root,
            cliCommand: nil
        ).rowID
        XCTAssertTrue(center.canStartOperation(on: child))
        XCTAssertNil(center.activeLockHolder(for: child))
        let inner = center.begin(
            title: "Inner ordinary",
            detail: "Fixture",
            operationType: .download,
            targetBundleURL: child,
            cliCommand: nil
        ).rowID
        XCTAssertEqual(center.items.first(where: { $0.id == inner })?.state, .running)
        center.complete(id: outer, detail: "Drained", bundleURLs: [])
        XCTAssertTrue(center.canStartOperation(on: root))
        XCTAssertEqual(center.activeLockHolder(for: child)?.id, inner)
    }

    func testDuplicateTargetAndAdditionalURLPromotesTheOneLeaseToTreeScope() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alias = root.appendingPathComponent("placeholder/..")
        let owner = center.begin(title: "Tree owner", detail: "Fixture", operationType: .download, targetBundleURL: root,
            additionalLockedBundleURLs: [alias, root], cliCommand: nil, onCancel: {}).rowID
        let child = root.appendingPathComponent("child")
        XCTAssertEqual(center.activeLockHolder(for: child)?.id, owner)
        center.cancel(id: owner)
        XCTAssertFalse(center.canStartOperation(on: child))
        center.acknowledgeCancellation(id: owner)
        XCTAssertTrue(center.canStartOperation(on: child))
        let ordinary = center.begin(
            title: "New exact owner",
            detail: "Fixture",
            operationType: .download,
            targetBundleURL: root,
            cliCommand: nil
        ).rowID
        XCTAssertEqual(center.activeLockHolder(for: root)?.id, ordinary)
        XCTAssertTrue(center.canStartOperation(on: child), "Released tree scope must not leak into a later exact lease")
    }

    func testConflictingOutputRejectsAllNewLocksWithoutReplacingTheFirstOwner() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("results")
        let firstHistory = root.appendingPathComponent("first.lungfishrun")
        let nextHistory = root.appendingPathComponent("second.lungfishrun")
        let first = center.begin(title: "First", detail: "Local fixture", operationType: .download, targetBundleURL: firstHistory,
            additionalLockedBundleURLs: [output],
            cliCommand: nil).rowID
        let second = center.begin(title: "Second", detail: "Local fixture", operationType: .download, targetBundleURL: nextHistory,
            additionalLockedBundleURLs: [output],
            cliCommand: nil).rowID
        XCTAssertEqual(center.items.first { $0.id == second }?.state, .failed)
        XCTAssertEqual(center.activeLockHolder(for: output)?.id, first)
        XCTAssertTrue(center.canStartOperation(on: nextHistory), "A rejected registration must acquire no partial locks")
        center.complete(id: first, detail: "Done", bundleURLs: [firstHistory])
        XCTAssertTrue(center.canStartOperation(on: output))
    }
}
