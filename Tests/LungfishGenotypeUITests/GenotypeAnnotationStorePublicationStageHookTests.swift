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
    func testEachEditReportsItsEncodeDigestAndWrite() async throws {
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

        try await store.setSampleStatus(.reviewed, sample: "Animal-1")

        let first = recorder.events
        XCTAssertEqual(Set(first.map(\.stage)), [.encode, .digest, .write])
        XCTAssertEqual(first.first?.stage, .encode)
        XCTAssertEqual(first.last?.stage, .write)
        XCTAssertEqual(first.filter { $0.stage == .write }.count, 1)

        try await store.addSampleNote(sample: "Animal-2", body: "second edit")

        let both = recorder.events
        XCTAssertEqual(both.filter { $0.stage == .encode }.count, 2)
        XCTAssertEqual(both.filter { $0.stage == .write }.count, 2)
        XCTAssertEqual(both.last?.stage, .write)
    }

    /// The defect of 2.11 S35 M2a. Every encode, digest and write of two edits runs away from the main thread.
    func testNoPublicationStepRunsOnTheMainThread() async throws {
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

        try await store.setSampleStatus(.reviewed, sample: "Animal-1")
        try await store.addSampleNote(sample: "Animal-2", body: "second edit")

        XCTAssertEqual(recorder.events.filter { $0.stage == .write }.count, 2)
        XCTAssertEqual(recorder.events.filter(\.onMainThread), [])
    }

    /// The test above drives the two edits that go through `persist`. The matrix transaction, the
    /// candidate display step, the manual haplotype replacement and the call override replay each
    /// build their own closure for the write away from the main thread, so each one reports its
    /// own steps here, with a fresh recorder (2.11 S35 review fix 2). The two replayed edits still
    /// published on the main thread before item 3 of M2a2.
    func testEveryPublicationPathRunsOffTheMainThread() async throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        // A replayed edit starts from the file on disk, so the bundle holds the sidecar the analyst saw.
        try await GenotypeAnnotationStore(bundleURL: bundle, author: "seed").publishUnsavedBuiltInSmartCohorts()

        let matrix = StageRecorder()
        try await makeStore(bundle, recording: matrix).upsertMatrixComment(
            body: "Checked",
            targets: [.column(sample: "Animal-1")],
            author: "analyst"
        )
        assertPublishedOffTheMainThread(matrix, "the matrix transaction")

        let display = StageRecorder()
        try await makeStore(bundle, recording: display).updateMHCCandidateDisplaySettings(
            ONTMHCCandidateDisplaySettings(showKnown: false),
            author: "analyst"
        )
        assertPublishedOffTheMainThread(display, "the candidate display step")

        let manual = StageRecorder()
        _ = try await makeStore(bundle, recording: manual).replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [
                ManualHaplotypeAssignment(
                    sample: "Animal-1",
                    locus: "MHC-A",
                    slot: .h1,
                    label: "H-NEW",
                    colorTokenIndex: 3,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ],
            copySource: nil,
            author: "analyst"
        )
        assertPublishedOffTheMainThread(manual, "the manual haplotype replacement")

        let overrides = StageRecorder()
        _ = try await makeStore(bundle, recording: overrides).mutateCallOverrides(
            [
                CallOverrideMutation(
                    target: .init(sample: "Animal-1", locus: "MHC-A", slot: .h1),
                    baseline: "M1A",
                    after: "M2A",
                    reason: .analystJudgment,
                    rationale: "Reviewed"
                ),
            ],
            author: "analyst",
            analysisIdentity: nil
        )
        assertPublishedOffTheMainThread(overrides, "the call override replay")
    }

    func testStaleRefusalReportsNoStep() async throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try await GenotypeAnnotationStore(bundleURL: bundle, author: "seed").publishUnsavedBuiltInSmartCohorts()
        let other = try GenotypeAnnotationStore(bundleURL: bundle, author: "other")
        let recorder = StageRecorder()
        let stale = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "stale",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: nil,
            publicationStageObserver: recorder.record
        )
        try await other.setSampleStatus(.reviewed, sample: "Animal-1")

        await XCTAssertThrowsErrorInIsolation(try await stale.addSampleNote(sample: "Animal-2", body: "stale edit"))

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

    private func makeStore(_ bundle: URL, recording recorder: StageRecorder) throws -> GenotypeAnnotationStore {
        try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "analyst",
            seedBuiltInSmartCohorts: false,
            publicationFaultInjector: nil,
            publicationStageObserver: recorder.record
        )
    }

    private func assertPublishedOffTheMainThread(
        _ recorder: StageRecorder,
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            recorder.events.contains { $0.stage == .write },
            "\(path) published nothing",
            file: file,
            line: line
        )
        XCTAssertEqual(
            recorder.events.filter(\.onMainThread),
            [],
            "\(path) ran a publication step on the main thread",
            file: file,
            line: line
        )
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
