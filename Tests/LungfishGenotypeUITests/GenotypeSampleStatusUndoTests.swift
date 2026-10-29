import XCTest
import AppKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport

/// Ruling U15. A status audit entry records the status it replaced, and the
/// three sample status commands (Mark Sample Reviewed, Mark Sample Confirmed
/// and Flag Sample for Review) can be undone and redone.
@MainActor
final class GenotypeSampleStatusUndoTests: GenotypeResultViewportTestCase {
    private let sample = "AnimalA"

    // MARK: - Audit trail in the store

    func testSetSampleStatusRecordsThePriorStatusInBefore() async throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )

        try await store.setSampleStatus(.needsReview, sample: "AnimalA")
        try await store.setSampleStatus(.confirmed, sample: "AnimalA")
        try await store.setSampleStatus(.reviewed, sample: "AnimalB")

        let audits = store.sidecar.auditLog.filter { $0.action == "setSampleStatus" }
        XCTAssertEqual(audits.map(\.sample), ["AnimalA", "AnimalA", "AnimalB"])
        XCTAssertEqual(audits.map(\.before), [nil, "needsReview", nil])
        XCTAssertEqual(audits.map(\.after), ["needsReview", "confirmed", "reviewed"])
        XCTAssertEqual(try persistedSidecar(bundleURL).auditLog, store.sidecar.auditLog)
    }

    func testSetCallStatusRecordsThePriorStatusOfTheSameSlot() async throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )

        try await store.setCallStatus(.needsReview, sample: "AnimalA", locus: "MHC-A", slot: .h1)
        try await store.setCallStatus(.confirmed, sample: "AnimalA", locus: "MHC-A", slot: .h2)
        try await store.setCallStatus(.reviewed, sample: "AnimalA", locus: "MHC-A", slot: .h1)

        let audits = store.sidecar.auditLog.filter { $0.action == "setCallStatus" }
        XCTAssertEqual(audits.map(\.slot), [.h1, .h2, .h1])
        XCTAssertEqual(audits.map(\.before), [nil, nil, "needsReview"])
        XCTAssertEqual(audits.map(\.after), ["needsReview", "confirmed", "reviewed"])
    }

    func testClearSampleStatusRemovesTheFlagAndRecordsTheRemovedStatus() async throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )
        try await store.setSampleStatus(.confirmed, sample: "AnimalA")
        try await store.setSampleStatus(.reviewed, sample: "AnimalB")

        try await store.clearSampleStatus(sample: "AnimalA", author: "second analyst")

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

    func testClearSampleStatusLeavesASampleWithoutAFlagAlone() async throws {
        let bundleURL = try makeBundleDirectory()
        defer { TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent()) }
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )
        try await store.setSampleStatus(.reviewed, sample: "AnimalB")
        let sidecarBefore = store.sidecar
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let bytesBefore = try Data(contentsOf: annotationURL)

        try await store.clearSampleStatus(sample: "AnimalA")

        XCTAssertEqual(store.sidecar, sidecarBefore)
        XCTAssertEqual(try Data(contentsOf: annotationURL), bytesBefore)
    }

    // MARK: - A refused edit (2.11 S35 M2b, N3, UX 7, BIO 4)

    /// The store's own sentence when another window saved the bundle first. The alert keeps it in its details
    /// and its body states the same fact. Sentence case, and no colon or semicolon inside a sentence (UX 7).
    static let staleRefusalWords =
        "The genotype annotations changed in another process. Reload the bundle before saving this edit."

    /// A sample status edit that finds the bundle changed by another window is refused. Its Undo
    /// goes, the person reads the stale alert, and the other window's edit and every earlier edit stay.
    ///
    /// Red without the takeback (2.11 S35 review fix 3). With
    /// `GenotypeResultViewController+SampleStatusUndo.swift` as it was before the takeback, where the
    /// Undo targets the controller and `onFailure` removes nothing, this test fails once, at the
    /// `canUndo` assertion. The alert, file and view assertions around it pass.
    func testAStaleSampleStatusEditTakesBackItsUndoAndDropsNoEdit() async throws {
        let fixture = try await makeHostedController(priorStatus: .needsReview)
        defer { fixture.tearDown() }
        var alerts: [FailureReport] = []
        fixture.controller.testingSetSheetAlertHandler { alerts.append($0) }
        defer { fixture.controller.testingSetSheetAlertHandler(nil) }
        let otherWindow = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "second analyst",
            seedBuiltInSmartCohorts: false
        )
        try await otherWindow.setSampleStatus(.confirmed, sample: "AnimalB")
        let fileBefore = try persistedSidecar(fixture.bundleURL)
        XCTAssertFalse(fixture.undoManager.canUndo)

        // As in the app, the event's undo group closes before the edit's publication ends.
        fixture.undoManager.beginUndoGrouping()
        fixture.controller.markSelectedSampleReviewed(nil)
        fixture.undoManager.endUndoGrouping()
        await waitForAnnotationEdits()

        XCTAssertEqual(alerts.map(\.title), ["Could not change the sample status"])
        XCTAssertEqual(alerts.first?.details?.hasPrefix(Self.staleRefusalWords), true, "The store's sentence goes to the details")
        XCTAssertFalse(fixture.undoManager.canUndo, "A refused edit takes its Undo back (N3)")
        XCTAssertEqual(try persistedSidecar(fixture.bundleURL), fileBefore)
        XCTAssertEqual(status(of: sample, in: fileBefore), .needsReview)
        XCTAssertEqual(status(of: "AnimalB", in: fileBefore), .confirmed)
        let shown = try XCTUnwrap(fixture.controller.annotationStore)
        XCTAssertEqual(status(of: "AnimalB", in: shown.sidecar), .confirmed, "The view adopts the other window's edit")
        let words = Self.staleRefusalWords
        XCTAssertFalse(words.contains(":") || words.contains(";"))
        XCTAssertEqual(words.first.map { $0.isUppercase }, true)
    }

    /// The alert of that refusal names the failed step in its title, words what happened and the next step in its
    /// body, and keeps the error's own sentence in the details (ALERT-PRESENTER, Phase 3.1). Red at the base, where
    /// the seam handed over the raw error and its sentence was the whole alert.
    func testAStaleSampleStatusEditAlertNamesTheStepAndKeepsTheRawErrorInTheDetails() async throws {
        let fixture = try await makeHostedController(priorStatus: .needsReview)
        defer { fixture.tearDown() }
        var alerts: [NSAlert] = []
        fixture.controller.testingSetSheetAlertHandler { alerts.append(Self.alertAPersonReads(for: $0)) }
        defer { fixture.controller.testingSetSheetAlertHandler(nil) }
        let otherWindow = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "second analyst",
            seedBuiltInSmartCohorts: false
        )
        try await otherWindow.setSampleStatus(.confirmed, sample: "AnimalB")

        fixture.undoManager.beginUndoGrouping()
        fixture.controller.markSelectedSampleReviewed(nil)
        fixture.undoManager.endUndoGrouping()
        await waitForAnnotationEdits()

        XCTAssertEqual(alerts.map(\.messageText), ["Could not change the sample status"])
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(
            alert.informativeText,
            "The genotype annotations changed in another process, so this edit was not applied.\n\n"
                + "Reload the bundle, then change the sample status again."
        )
        let details = try XCTUnwrap(alert.accessoryView as? FailureDetailsView)
        XCTAssertTrue(details.textView.string.hasPrefix(Self.staleRefusalWords))
    }

    /// The alert a person reads for what the seam hands over, a report at the head and the raw error before it.
    @MainActor
    private static func alertAPersonReads(for presented: Any) -> NSAlert {
        if let report = presented as? FailureReport {
            return FailurePresenter.alert(for: report)
        }
        return NSAlert(error: (presented as? Error) ?? NSError(domain: "unexpected", code: 0))
    }

    /// The review commands hold while an edit publishes, so a second command cannot start from a
    /// status that is not saved yet (2.11 S35 review fix 7, plan S2).
    func testReviewCommandsAreDisabledWhileAnEditPublishes() async throws {
        let fixture = try await makeHostedController(priorStatus: .needsReview)
        defer { fixture.tearDown() }
        let item = NSMenuItem(
            title: "Mark Sample Reviewed",
            action: #selector(GenotypeResultViewController.markSelectedSampleReviewed(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(fixture.controller.validateMenuItem(item), "The command is available while no edit publishes")

        fixture.undoManager.beginUndoGrouping()
        fixture.controller.markSelectedSampleReviewed(nil)
        fixture.undoManager.endUndoGrouping()

        XCTAssertFalse(fixture.controller.validateMenuItem(item), "The command holds while its edit publishes")
        await waitForAnnotationEdits()
        XCTAssertTrue(fixture.controller.validateMenuItem(item), "The command is available again once the edit ends")
        XCTAssertEqual(status(of: sample, in: try persistedSidecar(fixture.bundleURL)), .reviewed)
    }

    // MARK: - Undo and Redo of the sample status commands

    func testMarkSampleReviewedUndoesToNoStatusAndRedoes() async throws {
        try await assertUndoAndRedo(
            priorStatus: nil,
            command: { $0.markSelectedSampleReviewed(nil) },
            status: .reviewed,
            actionName: "Mark Sample Reviewed"
        )
        await waitForAnnotationEdits()
    }

    func testMarkSampleConfirmedUndoesToNoStatusAndRedoes() async throws {
        try await assertUndoAndRedo(
            priorStatus: nil,
            command: { $0.markSelectedSampleConfirmed(nil) },
            status: .confirmed,
            actionName: "Mark Sample Confirmed"
        )
        await waitForAnnotationEdits()
    }

    func testFlagSampleForReviewUndoesToNoStatusAndRedoes() async throws {
        try await assertUndoAndRedo(
            priorStatus: nil,
            command: { $0.flagSelectedSampleNeedsReview(nil) },
            status: .needsReview,
            actionName: "Flag Sample for Review"
        )
        await waitForAnnotationEdits()
    }

    func testMarkSampleReviewedUndoesToThePriorStatusAndRedoes() async throws {
        try await assertUndoAndRedo(
            priorStatus: .needsReview,
            command: { $0.markSelectedSampleReviewed(nil) },
            status: .reviewed,
            actionName: "Mark Sample Reviewed"
        )
        await waitForAnnotationEdits()
    }

    func testMarkSampleConfirmedUndoesToThePriorStatusAndRedoes() async throws {
        try await assertUndoAndRedo(
            priorStatus: .reviewed,
            command: { $0.markSelectedSampleConfirmed(nil) },
            status: .confirmed,
            actionName: "Mark Sample Confirmed"
        )
        await waitForAnnotationEdits()
    }

    func testFlagSampleForReviewUndoesToThePriorStatusAndRedoes() async throws {
        try await assertUndoAndRedo(
            priorStatus: .confirmed,
            command: { $0.flagSelectedSampleNeedsReview(nil) },
            status: .needsReview,
            actionName: "Flag Sample for Review"
        )
        await waitForAnnotationEdits()
    }

    func testCommandThatKeepsTheStatusRegistersNoUndo() async throws {
        let fixture = try await makeHostedController(priorStatus: .reviewed)
        defer { fixture.tearDown() }

        await performAsOneUserEvent(fixture.undoManager) {
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
        await waitForAnnotationEdits()
        XCTAssertEqual(try persistedSidecar(fixture.bundleURL), sidecar)
    }

    func testUndoWritesToTheBundleTheCommandChangedAfterTheViewerMovesOn() async throws {
        let fixture = try await makeHostedController(priorStatus: .reviewed)
        defer { fixture.tearDown() }
        await performAsOneUserEvent(fixture.undoManager) {
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
        await waitForAnnotationEdits()

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
    func testUndoAfterTheViewerReopensTheSameBundleKeepsItsStoreCurrent() async throws {
        let fixture = try await makeHostedController(priorStatus: .reviewed)
        defer { fixture.tearDown() }
        await performAsOneUserEvent(fixture.undoManager) {
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
        await waitForAnnotationEdits()
        await performAsOneUserEvent(fixture.undoManager) {
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
    ) async throws {
        let fixture = try await makeHostedController(priorStatus: priorStatus)
        defer { fixture.tearDown() }
        var refreshedStatuses: [GenotypeAnnotationSidecar.StatusValue?] = []
        let reviewedSample = sample
        fixture.controller.onAnnotationSidecarChanged = { sidecar in
            refreshedStatuses.append(
                sidecar.sampleStatusFlags.first { $0.sample == reviewedSample }?.value
            )
        }
        let auditCountBefore = try persistedSidecar(fixture.bundleURL).auditLog.count

        await performAsOneUserEvent(fixture.undoManager) { command(fixture.controller) }

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
        await waitForAnnotationEdits()

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
        await waitForAnnotationEdits()

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
    ) async throws -> HostedController {
        let bundleURL = try makeBundleDirectory()
        let seed = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "first analyst")
        if let priorStatus {
            try await seed.setSampleStatus(priorStatus, sample: sample)
        } else {
            // The tests read the sidecar before the first command, so the
            // bundle starts with the sidecar the viewer would show.
            try await seed.publishUnsavedBuiltInSmartCohorts()
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

    /// The command registers its Undo in the event and its edit publishes after `body` returns
    /// (2.11 S35 M2a), so the event ends once the edit has.
    private func performAsOneUserEvent(_ undoManager: UndoManager, _ body: () -> Void) async {
        undoManager.beginUndoGrouping()
        body()
        await waitForAnnotationEdits()
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
