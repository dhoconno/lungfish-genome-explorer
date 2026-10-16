import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// Quit waits for an annotation edit that is still publishing (2.11 S35, review fix 1).
///
/// The edit renames `annotations.json` and then its record away from the main thread, so the
/// main thread is free in between. A Quit that ended the process there would leave a new file
/// beside the record of the edit before it.
@MainActor
final class ProjectTaskTerminationRegistryAnnotationEditTests: XCTestCase {
    func testTerminationWaitsForAnAnnotationEditThatIsPublishing() async throws {
        let root = try TestTempDirectory.make(prefix: "termination-annotation-edit")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root)
        let store = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "analyst",
            seedBuiltInSmartCohorts: true
        )

        store.beginEdit({ try await store.setSampleStatus(.reviewed, sample: "Animal-1") }, onFailure: { XCTFail("\($0)") })
        let pendingWhileSaving = ProjectTaskTerminationRegistry.hasPendingTasks
        await ProjectTaskTerminationRegistry.cancelAndWait()
        let pendingAfterQuitWait = ProjectTaskTerminationRegistry.hasPendingTasks
        let savedBytes = try? Data(contentsOf: annotationURL(bundle))
        // A run where Quit did not wait leaves the edit writing, so it ends before the folder goes.
        await waitForAnnotationEdits()

        XCTAssertTrue(pendingWhileSaving, "Quit would not see an annotation edit that is still saving")
        XCTAssertFalse(pendingAfterQuitWait)
        let file = try GenotypeAnnotationSidecar.decode(
            try XCTUnwrap(savedBytes, "annotations.json was not written when the Quit wait returned")
        )
        XCTAssertEqual(file.sampleStatusFlags.map(\.sample), ["Animal-1"])
        XCTAssertEqual(file.sampleStatusFlags.map(\.value), [.reviewed])
    }

    func testCancelAndWaitReturnsAtOnceWithNoEditInFlight() async {
        await waitForAnnotationEdits()
        XCTAssertFalse(ProjectTaskTerminationRegistry.hasPendingTasks)
        let started = ContinuousClock.now

        await ProjectTaskTerminationRegistry.cancelAndWait()

        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "Quit waited with no annotation edit saving")
        XCTAssertFalse(ProjectTaskTerminationRegistry.hasPendingTasks)
    }

    /// A stalled volume cannot block Quit. The wait ends at its deadline with the edit still running.
    func testWaitForAnnotationEditsToSaveGivesUpAtItsDeadline() async throws {
        let root = try TestTempDirectory.make(prefix: "termination-annotation-edit")
        defer { TestTempDirectory.cleanup(root) }
        let store = try GenotypeAnnotationStore(
            bundleURL: try makeBundle(in: root),
            author: "analyst",
            seedBuiltInSmartCohorts: true
        )
        let hold = EditHold()
        store.beginEdit({ await hold.wait() }, onFailure: { XCTFail("\($0)") })
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits)

        await GenotypeResultViewController.waitForAnnotationEditsToSave(timeout: .milliseconds(200))

        XCTAssertTrue(
            GenotypeResultViewController.isSavingAnnotationEdits,
            "the wait ended with the edit still running, so it ended at its deadline"
        )
        hold.release()
        await waitForAnnotationEdits()
        XCTAssertFalse(GenotypeResultViewController.isSavingAnnotationEdits)
    }

    // MARK: - Helpers

    /// An edit that keeps running until the test releases it.
    @MainActor
    private final class EditHold {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func wait() async {
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeBundle(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("Fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(
            to: url.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return url
    }

    private func annotationURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }
}
