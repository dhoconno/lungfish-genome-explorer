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
