import XCTest
import AppKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishTestSupport

/// Ruling U15. A status audit entry records the status it replaced, and the
/// three sample status commands (Mark Sample Reviewed, Mark Sample Confirmed
/// and Flag Sample for Review) can be undone and redone.
@MainActor
final class GenotypeSampleStatusUndoTests: GenotypeResultViewportTestCase {
    private let sample = "AnimalA"

    // MARK: - Audit trail in the store

    func testSetSampleStatusRecordsThePriorStatusInBefore() throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )

        try store.setSampleStatus(.needsReview, sample: "AnimalA")
        try store.setSampleStatus(.confirmed, sample: "AnimalA")
        try store.setSampleStatus(.reviewed, sample: "AnimalB")

        let audits = store.sidecar.auditLog.filter { $0.action == "setSampleStatus" }
        XCTAssertEqual(audits.map(\.sample), ["AnimalA", "AnimalA", "AnimalB"])
        XCTAssertEqual(audits.map(\.before), [nil, "needsReview", nil])
        XCTAssertEqual(audits.map(\.after), ["needsReview", "confirmed", "reviewed"])
        XCTAssertEqual(try persistedSidecar(bundleURL).auditLog, store.sidecar.auditLog)
    }

    func testSetCallStatusRecordsThePriorStatusOfTheSameSlot() throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )

        try store.setCallStatus(.needsReview, sample: "AnimalA", locus: "MHC-A", slot: .h1)
        try store.setCallStatus(.confirmed, sample: "AnimalA", locus: "MHC-A", slot: .h2)
        try store.setCallStatus(.reviewed, sample: "AnimalA", locus: "MHC-A", slot: .h1)

        let audits = store.sidecar.auditLog.filter { $0.action == "setCallStatus" }
        XCTAssertEqual(audits.map(\.slot), [.h1, .h2, .h1])
        XCTAssertEqual(audits.map(\.before), [nil, nil, "needsReview"])
        XCTAssertEqual(audits.map(\.after), ["needsReview", "confirmed", "reviewed"])
    }

    func testClearSampleStatusRemovesTheFlagAndRecordsTheRemovedStatus() throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )
        try store.setSampleStatus(.confirmed, sample: "AnimalA")
        try store.setSampleStatus(.reviewed, sample: "AnimalB")

        try store.clearSampleStatus(sample: "AnimalA", author: "second analyst")

        XCTAssertEqual(store.sidecar.sampleStatusFlags.map(\.sample), ["AnimalB"])
        let audit = try XCTUnwrap(store.sidecar.auditLog.last)
        XCTAssertEqual(audit.action, "clearSampleStatus")
        XCTAssertEqual(audit.sample, "AnimalA")
        XCTAssertNil(audit.locus)
        XCTAssertNil(audit.slot)
        XCTAssertEqual(audit.before, "confirmed")
        XCTAssertNil(audit.after)
        XCTAssertEqual(audit.author, "second analyst")
        XCTAssertEqual(try persistedSidecar(bundleURL), store.sidecar)
    }

    func testClearSampleStatusLeavesASampleWithoutAFlagAlone() throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )
        try store.setSampleStatus(.reviewed, sample: "AnimalB")
        let sidecarBefore = store.sidecar
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let bytesBefore = try Data(contentsOf: annotationURL)

        try store.clearSampleStatus(sample: "AnimalA")

        XCTAssertEqual(store.sidecar, sidecarBefore)
        XCTAssertEqual(try Data(contentsOf: annotationURL), bytesBefore)
    }

    // MARK: - Undo and Redo of the sample status commands

    func testMarkSampleReviewedUndoesToNoStatusAndRedoes() throws {
        try assertUndoAndRedo(
            priorStatus: nil,
            command: { $0.markSelectedSampleReviewed(nil) },
            status: .reviewed,
            actionName: "Mark Sample Reviewed"
        )
    }

    func testMarkSampleConfirmedUndoesToNoStatusAndRedoes() throws {
        try assertUndoAndRedo(
            priorStatus: nil,
            command: { $0.markSelectedSampleConfirmed(nil) },
            status: .confirmed,
            actionName: "Mark Sample Confirmed"
        )
    }

    func testFlagSampleForReviewUndoesToNoStatusAndRedoes() throws {
        try assertUndoAndRedo(
            priorStatus: nil,
            command: { $0.flagSelectedSampleNeedsReview(nil) },
            status: .needsReview,
            actionName: "Flag Sample for Review"
        )
    }

    func testMarkSampleReviewedUndoesToThePriorStatusAndRedoes() throws {
        try assertUndoAndRedo(
            priorStatus: .needsReview,
            command: { $0.markSelectedSampleReviewed(nil) },
            status: .reviewed,
            actionName: "Mark Sample Reviewed"
        )
    }

    func testMarkSampleConfirmedUndoesToThePriorStatusAndRedoes() throws {
        try assertUndoAndRedo(
            priorStatus: .reviewed,
            command: { $0.markSelectedSampleConfirmed(nil) },
            status: .confirmed,
            actionName: "Mark Sample Confirmed"
        )
    }

    func testFlagSampleForReviewUndoesToThePriorStatusAndRedoes() throws {
        try assertUndoAndRedo(
            priorStatus: .confirmed,
            command: { $0.flagSelectedSampleNeedsReview(nil) },
            status: .needsReview,
            actionName: "Flag Sample for Review"
        )
    }

    func testCommandThatKeepsTheStatusRegistersNoUndo() throws {
        let fixture = try makeHostedController(priorStatus: .reviewed)
        defer { fixture.tearDown() }

        performAsOneUserEvent(fixture.undoManager) {
            fixture.controller.markSelectedSampleReviewed(nil)
        }

        let sidecar = try persistedSidecar(fixture.bundleURL)
        XCTAssertEqual(status(of: sample, in: sidecar), .reviewed)
        let audit = try XCTUnwrap(sidecar.auditLog.last)
        XCTAssertEqual(audit.before, "reviewed")
        XCTAssertEqual(audit.after, "reviewed")
        // The event's undo group holds no action, so Undo has no name and
        // leaves the bundle alone. AppKit drops such an empty group at the
        // end of a real event.
        XCTAssertEqual(fixture.undoManager.undoActionName, "")
        fixture.undoManager.undo()
        XCTAssertEqual(try persistedSidecar(fixture.bundleURL), sidecar)
    }

    func testUndoWritesToTheBundleTheCommandChangedAfterTheViewerMovesOn() throws {
        let fixture = try makeHostedController(priorStatus: .reviewed)
        defer { fixture.tearDown() }
        performAsOneUserEvent(fixture.undoManager) {
            fixture.controller.markSelectedSampleConfirmed(nil)
        }
        let otherBundleURL = fixture.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("other.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherBundleURL,
            withIntermediateDirectories: true
        )
        fixture.controller.configure(result: makeResult(
            bundleURL: otherBundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(sample: sample)
        ))

        fixture.undoManager.undo()

        let sidecar = try persistedSidecar(fixture.bundleURL)
        XCTAssertEqual(status(of: sample, in: sidecar), .reviewed)
        XCTAssertEqual(sidecar.auditLog.last?.before, "confirmed")
        XCTAssertEqual(sidecar.auditLog.last?.after, "reviewed")
        // The viewer only looked at the other bundle, and looking writes
        // nothing, so Undo left it without a sidecar.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: otherBundleURL).path
        ))
    }

    /// The viewer often reopens the bundle's annotation store. Undo must go
    /// through the store on screen so that store stays in step with the file
    /// and the next command still saves.
    func testUndoAfterTheViewerReopensTheSameBundleKeepsItsStoreCurrent() throws {
        let fixture = try makeHostedController(priorStatus: .reviewed)
        defer { fixture.tearDown() }
        performAsOneUserEvent(fixture.undoManager) {
            fixture.controller.markSelectedSampleConfirmed(nil)
        }
        fixture.controller.configure(result: makeResult(
            bundleURL: fixture.bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(sample: sample)
        ))
        fixture.controller.testingSelectCellEvidence(animalId: sample, locus: "MHC-A")
        var refreshedStatuses: [GenotypeAnnotationSidecar.StatusValue?] = []
        let reviewedSample = sample
        fixture.controller.onAnnotationSidecarChanged = { sidecar in
            refreshedStatuses.append(
                sidecar.sampleStatusFlags.first { $0.sample == reviewedSample }?.value
            )
        }

        fixture.undoManager.undo()
        performAsOneUserEvent(fixture.undoManager) {
            fixture.controller.flagSelectedSampleNeedsReview(nil)
        }

        XCTAssertEqual(refreshedStatuses, [.reviewed, .needsReview])
        let sidecar = try persistedSidecar(fixture.bundleURL)
        XCTAssertEqual(status(of: sample, in: sidecar), .needsReview)
        XCTAssertEqual(
            sidecar.auditLog.suffix(3).map(\.after),
            ["confirmed", "reviewed", "needsReview"]
        )
    }

    // MARK: - Helpers

    private struct HostedController {
        let controller: GenotypeResultViewController
        let window: NSWindow
        let undoManager: UndoManager
        let bundleURL: URL

        @MainActor
        func tearDown() {
            undoManager.removeAllActions()
            window.contentViewController = nil
            TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent())
        }
    }

    /// Runs the command, Undo and Redo, checking the persisted status, the
    /// action names, one audit entry per step and the refresh callback.
    private func assertUndoAndRedo(
        priorStatus: GenotypeAnnotationSidecar.StatusValue?,
        command: (GenotypeResultViewController) -> Void,
        status newStatus: GenotypeAnnotationSidecar.StatusValue,
        actionName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try makeHostedController(priorStatus: priorStatus)
        defer { fixture.tearDown() }
        var refreshedStatuses: [GenotypeAnnotationSidecar.StatusValue?] = []
        let reviewedSample = sample
        fixture.controller.onAnnotationSidecarChanged = { sidecar in
            refreshedStatuses.append(
                sidecar.sampleStatusFlags.first { $0.sample == reviewedSample }?.value
            )
        }
        let auditCountBefore = try persistedSidecar(fixture.bundleURL).auditLog.count

        performAsOneUserEvent(fixture.undoManager) { command(fixture.controller) }

        var sidecar = try persistedSidecar(fixture.bundleURL)
        XCTAssertEqual(status(of: sample, in: sidecar), newStatus, file: file, line: line)
        XCTAssertEqual(sidecar.auditLog.count, auditCountBefore + 1, file: file, line: line)
        assertAudit(
            sidecar.auditLog.last,
            action: "setSampleStatus",
            before: priorStatus?.rawValue,
            after: newStatus.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(fixture.undoManager.canUndo, file: file, line: line)
        XCTAssertEqual(fixture.undoManager.undoActionName, actionName, file: file, line: line)

        fixture.undoManager.undo()

        sidecar = try persistedSidecar(fixture.bundleURL)
        XCTAssertEqual(status(of: sample, in: sidecar), priorStatus, file: file, line: line)
        XCTAssertEqual(
            sidecar.sampleStatusFlags.filter { $0.sample == sample }.count,
            priorStatus == nil ? 0 : 1,
            file: file,
            line: line
        )
        XCTAssertEqual(sidecar.auditLog.count, auditCountBefore + 2, file: file, line: line)
        assertAudit(
            sidecar.auditLog.last,
            action: priorStatus == nil ? "clearSampleStatus" : "setSampleStatus",
            before: newStatus.rawValue,
            after: priorStatus?.rawValue,
            file: file,
            line: line
        )
        XCTAssertFalse(fixture.undoManager.canUndo, file: file, line: line)
        XCTAssertTrue(fixture.undoManager.canRedo, file: file, line: line)
        XCTAssertEqual(fixture.undoManager.redoActionName, actionName, file: file, line: line)

        fixture.undoManager.redo()

        sidecar = try persistedSidecar(fixture.bundleURL)
        XCTAssertEqual(status(of: sample, in: sidecar), newStatus, file: file, line: line)
        XCTAssertEqual(sidecar.auditLog.count, auditCountBefore + 3, file: file, line: line)
        assertAudit(
            sidecar.auditLog.last,
            action: "setSampleStatus",
            before: priorStatus?.rawValue,
            after: newStatus.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(fixture.undoManager.canUndo, file: file, line: line)
        XCTAssertFalse(fixture.undoManager.canRedo, file: file, line: line)
        XCTAssertEqual(fixture.undoManager.undoActionName, actionName, file: file, line: line)

        XCTAssertEqual(
            refreshedStatuses,
            [newStatus, priorStatus, newStatus],
            "command, Undo and Redo each run the status refresh path",
            file: file,
            line: line
        )
    }

    private func assertAudit(
        _ entry: GenotypeAnnotationSidecar.AuditEntry?,
        action: String,
        before: String?,
        after: String?,
        file: StaticString,
        line: UInt
    ) {
        guard let entry else {
            XCTFail("missing audit entry", file: file, line: line)
            return
        }
        XCTAssertEqual(entry.action, action, file: file, line: line)
        XCTAssertEqual(entry.sample, sample, file: file, line: line)
        XCTAssertNil(entry.locus, file: file, line: line)
        XCTAssertNil(entry.slot, file: file, line: line)
        XCTAssertEqual(entry.before, before, file: file, line: line)
        XCTAssertEqual(entry.after, after, file: file, line: line)
        XCTAssertEqual(entry.author, "second analyst", file: file, line: line)
    }

    /// A controller hosted in a window, with the sample selected so the
    /// review commands are enabled. The window's undo manager groups one
    /// command per `performAsOneUserEvent`, as AppKit groups one per event.
    private func makeHostedController(
        priorStatus: GenotypeAnnotationSidecar.StatusValue?
    ) throws -> HostedController {
        let bundleURL = try makeBundleDirectory()
        let seed = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "first analyst")
        if let priorStatus {
            try seed.setSampleStatus(priorStatus, sample: sample)
        } else {
            // The tests read the sidecar before the first command, so the
            // bundle starts with the sidecar the viewer would show.
            try seed.publishUnsavedBuiltInSmartCohorts()
        }
        let controller = makeManualHaplotypeGuardedController()
        controller.annotationAuthorProvider = { "second analyst" }
        controller.testingSetSheetAlertHandler { error in
            XCTFail("Unexpected status alert: \(error)")
        }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(sample: sample)
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.testingSelectCellEvidence(animalId: sample, locus: "MHC-A")
        XCTAssertEqual(controller.reviewCommandTargetSample, sample)
        let undoManager = try XCTUnwrap(controller.view.window?.undoManager)
        undoManager.groupsByEvent = false
        return HostedController(
            controller: controller,
            window: window,
            undoManager: undoManager,
            bundleURL: bundleURL
        )
    }

    private func performAsOneUserEvent(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    private func makeBundleDirectory() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "GenotypeSampleStatusUndo")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return bundleURL
    }

    private func persistedSidecar(_ bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        ))
    }

    private func status(
        of sample: String,
        in sidecar: GenotypeAnnotationSidecar
    ) -> GenotypeAnnotationSidecar.StatusValue? {
        sidecar.sampleStatusFlags.first { $0.sample == sample }?.value
    }
}
