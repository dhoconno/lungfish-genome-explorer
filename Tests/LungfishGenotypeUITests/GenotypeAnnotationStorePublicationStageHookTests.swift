import XCTest
import Foundation
import LungfishCore
import LungfishIO
import os
@testable import LungfishGenotypeUI

/// The stage hook that records the thread of each encode, digest and write of a publication
/// (2.11 S35, SWIFT SC3). M2a's defect test reads it to show that no step runs on the main
/// thread, and a Debug build logs it for the GUI walk.
@MainActor
final class GenotypeAnnotationStorePublicationStageHookTests: XCTestCase {
    func testEachEditReportsItsEncodeDigestAndWrite() throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let recorder = StageRecorder()
        let store = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "analyst",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: nil,
            publicationStageObserver: recorder.record
        )

        try store.setSampleStatus(.reviewed, sample: "Animal-1")

        let first = recorder.events
        XCTAssertEqual(Set(first.map(\.stage)), [.encode, .digest, .write])
        XCTAssertEqual(first.first?.stage, .encode)
        XCTAssertEqual(first.last?.stage, .write)
        XCTAssertEqual(first.filter { $0.stage == .write }.count, 1)

        try store.addSampleNote(sample: "Animal-2", body: "second edit")

        let both = recorder.events
        XCTAssertEqual(both.filter { $0.stage == .encode }.count, 2)
        XCTAssertEqual(both.filter { $0.stage == .write }.count, 2)
        XCTAssertEqual(both.last?.stage, .write)
    }

    func testStaleRefusalReportsNoStep() throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try GenotypeAnnotationStore(bundleURL: bundle, author: "seed").publishUnsavedBuiltInSmartCohorts()
        let other = try GenotypeAnnotationStore(bundleURL: bundle, author: "other")
        let recorder = StageRecorder()
        let stale = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "stale",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: nil,
            publicationStageObserver: recorder.record
        )
        try other.setSampleStatus(.reviewed, sample: "Animal-1")

        XCTAssertThrowsError(try stale.addSampleNote(sample: "Animal-2", body: "stale edit"))

        XCTAssertEqual(recorder.events, [])
    }

    func testHookReportsTheThreadEachStepRunsOn() async throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let recorder = StageRecorder()
        let store = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "analyst",
            seedBuiltInSmartCohorts: false,
            publicationFaultInjector: nil,
            publicationStageObserver: recorder.record
        )

        store.reportPublicationStage(.digest)
        await Task.detached { store.reportPublicationStage(.encode) }.value

        XCTAssertEqual(recorder.events, [
            GenotypeAnnotationPublicationStageEvent(stage: .digest, onMainThread: true),
            GenotypeAnnotationPublicationStageEvent(stage: .encode, onMainThread: false),
        ])
    }

    func testStoreWithoutAnObserverReportsToTheDebugLog() throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = try GenotypeAnnotationStore(bundleURL: bundle, author: "analyst")

        #if DEBUG
        XCTAssertNotNil(store.publicationStageObserver)
        #else
        XCTAssertNil(store.publicationStageObserver)
        #endif
    }

    // MARK: - Helpers

    private final class StageRecorder: Sendable {
        private let storage = OSAllocatedUnfairLock<[GenotypeAnnotationPublicationStageEvent]>(initialState: [])

        var events: [GenotypeAnnotationPublicationStageEvent] { storage.withLock { $0 } }

        func record(_ event: GenotypeAnnotationPublicationStageEvent) {
            storage.withLock { $0.append(event) }
        }
    }

    private func makeBundleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(
            to: url.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return url
    }
}
