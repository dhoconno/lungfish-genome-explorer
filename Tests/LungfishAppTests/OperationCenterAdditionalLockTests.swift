import Foundation
import XCTest
import LungfishKit

@MainActor
final class OperationCenterAdditionalLockTests: XCTestCase {
    func testOutputLeaseRetainsDurableHistoryTargetAndRemainsHeldUntilCancellationDrains() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = root.appendingPathComponent("attempt.lungfishrun")
        let output = root.appendingPathComponent("results")
        let id = center.start(title: "Repeat", detail: "Local fixture", operationType: .workflow,
            targetBundleURL: history, additionalLockedBundleURLs: [output, output], onCancel: {})
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
            let first = center.start(title: "First", detail: "Fixture", targetBundleURL: root.appendingPathComponent("first.lungfishrun"),
                additionalLockedBundleURLs: [reversed ? inner : outer])
            let nextHistory = root.appendingPathComponent("second.lungfishrun")
            let refused = center.start(title: "Nested", detail: "Fixture", targetBundleURL: nextHistory,
                additionalLockedBundleURLs: [reversed ? outer : inner])
            XCTAssertEqual(center.items.first(where: { $0.id == refused })?.state, .failed)
            XCTAssertTrue(center.canStartOperation(on: nextHistory))
            let sibling = center.start(title: "Sibling", detail: "Fixture", targetBundleURL: root.appendingPathComponent("third.lungfishrun"),
                additionalLockedBundleURLs: [root.appendingPathComponent("results-other")])
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
            let owner = center.start(title: "Tree owner", detail: "Fixture", targetBundleURL: history,
                additionalLockedBundleURLs: [output], onCancel: {})
            XCTAssertFalse(center.canStartOperation(on: ordinaryTarget))
            XCTAssertEqual(center.activeLockHolder(for: ordinaryTarget)?.id, owner)
            let refused = center.start(title: "Ordinary writer", detail: "Fixture", targetBundleURL: ordinaryTarget)
            XCTAssertEqual(center.items.first(where: { $0.id == refused })?.state, .failed)
            XCTAssertEqual(center.activeLockHolder(for: ordinaryTarget)?.id, owner)
            let sibling = output.deletingLastPathComponent().appendingPathComponent("results-other")
            XCTAssertTrue(center.canStartOperation(on: sibling), "Path components, not a string prefix, define overlap")
            let siblingID = center.start(title: "Sibling writer", detail: "Fixture", targetBundleURL: sibling)
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
            let owner = center.start(title: "Ordinary owner", detail: "Fixture", targetBundleURL: ordinaryTarget)
            let history = root.appendingPathComponent("new.lungfishrun")
            let unrelated = root.appendingPathComponent("unrelated")
            let refused = center.start(title: "Tree writer", detail: "Fixture", targetBundleURL: history,
                additionalLockedBundleURLs: [unrelated, output])
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
        let outer = center.start(title: "Outer ordinary", detail: "Fixture", targetBundleURL: root)
        XCTAssertTrue(center.canStartOperation(on: child))
        XCTAssertNil(center.activeLockHolder(for: child))
        let inner = center.start(title: "Inner ordinary", detail: "Fixture", targetBundleURL: child)
        XCTAssertEqual(center.items.first(where: { $0.id == inner })?.state, .running)
        center.complete(id: outer, detail: "Drained", bundleURLs: [])
        XCTAssertTrue(center.canStartOperation(on: root))
        XCTAssertEqual(center.activeLockHolder(for: child)?.id, inner)
    }

    func testDuplicateTargetAndAdditionalURLPromotesTheOneLeaseToTreeScope() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alias = root.appendingPathComponent("placeholder/..")
        let owner = center.start(title: "Tree owner", detail: "Fixture", targetBundleURL: root,
            additionalLockedBundleURLs: [alias, root], onCancel: {})
        let child = root.appendingPathComponent("child")
        XCTAssertEqual(center.activeLockHolder(for: child)?.id, owner)
        center.cancel(id: owner)
        XCTAssertFalse(center.canStartOperation(on: child))
        center.acknowledgeCancellation(id: owner)
        XCTAssertTrue(center.canStartOperation(on: child))
        let ordinary = center.start(title: "New exact owner", detail: "Fixture", targetBundleURL: root)
        XCTAssertEqual(center.activeLockHolder(for: root)?.id, ordinary)
        XCTAssertTrue(center.canStartOperation(on: child), "Released tree scope must not leak into a later exact lease")
    }

    func testConflictingOutputRejectsAllNewLocksWithoutReplacingTheFirstOwner() {
        let center = OperationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("results")
        let firstHistory = root.appendingPathComponent("first.lungfishrun")
        let nextHistory = root.appendingPathComponent("second.lungfishrun")
        let first = center.start(title: "First", detail: "Local fixture", targetBundleURL: firstHistory,
            additionalLockedBundleURLs: [output])
        let second = center.start(title: "Second", detail: "Local fixture", targetBundleURL: nextHistory,
            additionalLockedBundleURLs: [output])
        XCTAssertEqual(center.items.first { $0.id == second }?.state, .failed)
        XCTAssertEqual(center.activeLockHolder(for: output)?.id, first)
        XCTAssertTrue(center.canStartOperation(on: nextHistory), "A rejected registration must acquire no partial locks")
        center.complete(id: first, detail: "Done", bundleURLs: [firstHistory])
        XCTAssertTrue(center.canStartOperation(on: output))
    }
}
