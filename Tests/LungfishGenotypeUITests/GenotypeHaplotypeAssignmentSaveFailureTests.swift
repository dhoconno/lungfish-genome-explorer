import XCTest
import AppKit
import SwiftUI
import ViewInspector
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// A haplotype assignment save that fails must say so where the analyst
/// looks. In the GUI walk of 2026-10-10 a failed Save Assignments left the
/// draft Unsaved with its message in the last row of the card, below the
/// visible part of the detail pane, and a failed Save in the export alert
/// closed the alert with no word at all.
@MainActor
final class GenotypeHaplotypeAssignmentSaveFailureTests: GenotypeResultViewportTestCase {
    private let sample = "SIMULATED-MHC-A-pairs"
    private let genotype = "01_Mafa_A1_001_01"
    private let staleMessage =
        "The genotype annotations changed in another process. Reload the bundle before saving this edit."

    func testAFailedSaveShowsItsMessageInTheHeaderBesideSaveAssignments() throws {
        let card = makeCard(persistenceErrorMessage: staleMessage)

        let header = try card.inspect()
            .find(viewWithAccessibilityIdentifier: "manual-haplotype-header")
        XCTAssertEqual(
            try header.accessibilityLabel().string(),
            "Haplotype assignment save status"
        )
        XCTAssertNoThrow(try header.find(button: "Save Assignments"))
        let error = try header.find(
            viewWithAccessibilityIdentifier: "manual-haplotype-persistence-error"
        )
        XCTAssertEqual(try error.label().title().text().string(), staleMessage)
        XCTAssertEqual(
            try error.accessibilityLabel().string(),
            "Haplotype assignments were not saved. \(staleMessage)"
        )
        XCTAssertNoThrow(try header.find(viewWithAccessibilityIdentifier: "manual-haplotype-retry"))
        XCTAssertNoThrow(try header.find(viewWithAccessibilityIdentifier: "manual-haplotype-reload"))
        XCTAssertEqual(
            try card.inspect().findAll(where: {
                try $0.accessibilityIdentifier() == "manual-haplotype-persistence-error"
            }).count,
            1,
            "the message shows once, in the header"
        )
    }

    /// The message slot also serves a failed Reload, which must not be spoken
    /// as a failed save.
    func testAFailedReloadIsNotSpokenAsNotSaved() throws {
        let reloadMessage = "The annotation sidecar could not be read."
        let card = makeCard(persistenceErrorMessage: reloadMessage, persistenceFailure: .reload)

        let error = try card.inspect().find(
            viewWithAccessibilityIdentifier: "manual-haplotype-persistence-error"
        )
        XCTAssertEqual(try error.label().title().text().string(), reloadMessage)
        XCTAssertEqual(
            try error.accessibilityLabel().string(),
            "Haplotype assignments could not be reloaded. \(reloadMessage)"
        )
    }

    func testEachEditorRecordsWhetherASaveOrAReloadFailed() {
        struct Refusal: LocalizedError {
            var errorDescription: String? { "Sidecar changed elsewhere." }
        }
        let draft = GenotypeManualHaplotypeDraft(
            sample: "Animal-1",
            index: GenotypeManualHaplotypeAssignmentIndex(assignments: [])
        )
        let manual = GenotypeManualHaplotypeEditorModel(
            snapshot: .init(draft: draft, copyCandidates: [], isReadOnly: false),
            onSave: { _ in throw Refusal() },
            onReload: { throw Refusal() },
            announcementPoster: RecordingGenotypeSearchAnnouncements()
        )
        manual.reload()
        XCTAssertEqual(manual.persistenceFailure, .reload)
        manual.updateLabel("WALK3", locus: .a, slot: .h1)
        manual.save()
        XCTAssertEqual(manual.persistenceFailure, .save)

        let snapshot = GenotypeEffectiveHaplotypeEditorModel.Snapshot(
            sample: "Animal-1",
            orderedLoci: ["MHC-A"],
            values: [
                .init(locus: "MHC-A", slot: .h1): "M1A",
                .init(locus: "MHC-A", slot: .h2): "M2A",
            ],
            suggestions: [],
            isReadOnly: false
        )
        let effective = GenotypeEffectiveHaplotypeEditorModel(
            snapshot: snapshot,
            onSave: { _ in throw Refusal() },
            onReload: { throw Refusal() },
            announcementPoster: RecordingGenotypeSearchAnnouncements()
        )
        effective.reload()
        XCTAssertEqual(effective.persistenceFailure, .reload)
        effective.updateLabel("M3A", locus: "MHC-A", slot: .h1)
        effective.save()
        XCTAssertEqual(effective.persistenceFailure, .save)
    }

    func testACardWithoutAFailedSaveShowsNoMessage() throws {
        let card = makeCard(persistenceErrorMessage: nil)

        XCTAssertThrowsError(try card.inspect().find(
            viewWithAccessibilityIdentifier: "manual-haplotype-persistence-error"
        ))
    }

    /// Return saves from any field, so the analyst can save with the card's
    /// header scrolled out of the detail pane. The message still lands in view.
    func testAFailedSaveMessageIsVisibleWithoutScrollingTheDetailPane() throws {
        let fixture = try makeBundleWithSidecar()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = makeManualHaplotypeGuardedController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        controller.configure(result: fixture.result)
        controller.testingShowMatrixTargetSelection([.column(sample: sample)])
        controller.testingUpdateManualHaplotypeLabel("WALK3", locus: .dpb, slot: .h2)
        controller.view.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(
            descendant(of: controller.view, identifier: "manual-haplotype-detail-editor")
        )
        let scrollView = try XCTUnwrap(host.enclosingScrollView)
        let document = try XCTUnwrap(scrollView.documentView)
        let headerTop = {
            host.convert(NSRect(x: 0, y: 0, width: host.bounds.width, height: 1), to: document)
        }
        // SwiftUI sizes the card until scrolling to its end hides the header.
        AccessibilityTreeProbe.waitUntil {
            controller.view.layoutSubtreeIfNeeded()
            return document.bounds.height - scrollView.contentView.bounds.height > headerTop().maxY
        }
        // The analyst scrolled down to the last locus before pressing Return.
        let bottom = NSPoint(x: 0, y: document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: bottom)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertFalse(
            scrollView.contentView.documentVisibleRect.intersects(headerTop()),
            "the card's header starts out of view"
        )
        try writeSidecarFromAnotherProcess(fixture)

        controller.testingSaveManualHaplotypeDraft()
        var frame = NSRect.zero
        let visible = { scrollView.contentView.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5) }
        AccessibilityTreeProbe.waitUntil {
            controller.view.layoutSubtreeIfNeeded()
            guard let region = descendant(
                of: host,
                identifier: "manual-haplotype-persistence-error-region"
            ) else { return false }
            frame = region.convert(region.bounds, to: document)
            return !frame.isEmpty && visible().contains(frame)
        }

        XCTAssertEqual(controller.testingManualHaplotypeEditorPersistenceError, staleMessage)
        XCTAssertFalse(frame.isEmpty, "the message's region is laid out")
        XCTAssertTrue(
            visible().contains(frame),
            "the message at \(frame) lies inside the visible detail pane \(visible())"
        )
    }

    /// The haplotyped MiSeq editor shares the card, so its failed save is
    /// announced the way the manual editor's is.
    func testTheEffectiveEditorAnnouncesAFailedSave() {
        struct Refusal: LocalizedError {
            var errorDescription: String? { "Sidecar changed elsewhere." }
        }
        let announcements = RecordingGenotypeSearchAnnouncements()
        let address = GenotypeEffectiveHaplotypeEditorModel.Address(locus: "MHC-A", slot: .h1)
        let snapshot = GenotypeEffectiveHaplotypeEditorModel.Snapshot(
            sample: "Animal-1",
            orderedLoci: ["MHC-A"],
            values: [
                address: "M1A",
                .init(locus: "MHC-A", slot: .h2): "M2A",
            ],
            suggestions: [],
            isReadOnly: false
        )
        let model = GenotypeEffectiveHaplotypeEditorModel(
            snapshot: snapshot,
            onSave: { _ in throw Refusal() },
            onReload: { snapshot },
            announcementPoster: announcements
        )
        model.updateLabel("M3A", locus: "MHC-A", slot: .h1)

        model.save()

        XCTAssertEqual(model.persistenceErrorMessage, "Sidecar changed elsewhere.")
        XCTAssertEqual(
            announcements.messages,
            ["Could not save haplotype assignments for Animal-1. Sidecar changed elsewhere."]
        )
    }

    // MARK: - Export to Excel

    func testAnExportWhoseSaveFailsSaysTheAssignmentsWereNotSaved() async throws {
        let fixture = try makeBundleWithSidecar()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = makeManualHaplotypeGuardedController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingShowMatrixTargetSelection([.column(sample: sample)])
        controller.testingUpdateManualHaplotypeLabel("WALK3")
        try writeSidecarFromAnotherProcess(fixture)
        controller.testingSetManualHaplotypeDraftDecisionProvider { _ in .save }
        var panels = 0
        controller.excelSavePanelPresenter = { _, _, completion in
            panels += 1
            completion(nil)
        }
        var events: [String] = []
        controller.onExcelExportEvent = { events.append(Self.describe($0)) }

        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            events,
            ["failed: Haplotype assignments were not saved. Use Retry or Reload in the editor, then export again."]
        )
        XCTAssertEqual(panels, 0, "no export sheet opens")
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(controller.testingManualHaplotypeEditorPersistenceError, staleMessage)
    }

    func testCancelInTheExportAlertReportsNothingEvenAfterAFailedSave() async throws {
        let fixture = try makeBundleWithSidecar()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = makeManualHaplotypeGuardedController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingShowMatrixTargetSelection([.column(sample: sample)])
        controller.testingUpdateManualHaplotypeLabel("WALK3")
        try writeSidecarFromAnotherProcess(fixture)
        controller.testingSaveManualHaplotypeDraft()
        XCTAssertEqual(controller.testingManualHaplotypeEditorPersistenceError, staleMessage)
        controller.testingSetManualHaplotypeDraftDecisionProvider { _ in .cancel }
        var panels = 0
        controller.excelSavePanelPresenter = { _, _, completion in
            panels += 1
            completion(nil)
        }
        var events: [String] = []
        controller.onExcelExportEvent = { events.append(Self.describe($0)) }

        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(events, [], "Cancel stops the export without a failure")
        XCTAssertEqual(panels, 0)
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
    }

    func testTheDraftCoordinatorRemembersOnlyAChosenSaveThatFailed() async {
        var saveSucceeds = false
        var discardSucceeds = false
        let coordinator = GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { true },
            save: { saveSucceeds },
            discard: { discardSucceeds }
        )

        let refusedBySave = await coordinator.prepare(for: .export) { .save }
        XCTAssertFalse(refusedBySave)
        XCTAssertTrue(coordinator.lastSaveFailed)

        let refusedByCancel = await coordinator.prepare(for: .export) { .cancel }
        XCTAssertFalse(refusedByCancel)
        XCTAssertFalse(coordinator.lastSaveFailed, "a new decision clears it")

        let refusedByDiscard = await coordinator.prepare(for: .export) { .discard }
        XCTAssertFalse(refusedByDiscard)
        XCTAssertFalse(coordinator.lastSaveFailed, "a failed Discard is not a failed save")

        saveSucceeds = true
        discardSucceeds = true
        let allowedBySave = await coordinator.prepare(for: .export) { .save }
        XCTAssertTrue(allowedBySave)
        XCTAssertFalse(coordinator.lastSaveFailed)
    }

    private static func describe(_ event: GenotypeExcelExportEvent) -> String {
        switch event {
        case .started: return "started"
        case .succeeded(let url): return "succeeded: \(url.lastPathComponent)"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData
    }

    private func makeCard(
        persistenceErrorMessage: String?,
        persistenceFailure: GenotypeHaplotypeAssignmentPersistenceFailure = .save
    ) -> GenotypeHaplotypeAssignmentEditorCard {
        GenotypeHaplotypeAssignmentEditorCard(
            sample: sample,
            completenessSummary: "1 of 14 assigned",
            instruction: "Edit the two manual assignments for each workbook locus.",
            rows: [],
            isDirty: true,
            canSave: true,
            isReadOnly: false,
            readOnlyMessage: nil,
            emptyStateMessage: nil,
            warning: nil,
            persistenceErrorMessage: persistenceErrorMessage,
            persistenceFailure: persistenceFailure,
            accessibilityPrefix: "manual-haplotype",
            typographyModel: .shared,
            compareAndCopyIsEnabled: nil,
            onSave: {},
            onRetry: {},
            onReload: {},
            onChange: { _, _ in },
            onClear: { _ in },
            onRestore: nil,
            onCompareAndCopy: nil
        )
    }

    /// A MiSeq genotype-only bundle with an empty annotations.json, so a save
    /// fails only through what a test does to the file.
    private func makeBundleWithSidecar() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "HaplotypeAssignmentSaveFailure")
        let bundleURL = root.appendingPathComponent(
            "walk-geno.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let kind = GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype
        let manifest = ONTGenotypeResultBundleManifest(
            kind: kind.rawValue,
            workflowKind: kind,
            workflowMode: .genotypeOnly,
            outputName: "walk-geno",
            analysisName: "walk-geno",
            primaryWorkbookPath: "walk-geno.xlsx",
            longSummaryCSVPath: "walk-geno.retained_demux_genotypes.csv",
            sampleSummaryCSVPath: "walk-geno.retained_demux_samples.csv",
            statsJSONPath: "walk-geno.retained_demux_stats.json",
            provenancePath: "walk-geno.retained_demux_provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            .empty(generatedAt: "2026-10-10T17:36:20Z"),
            forBundleAt: bundleURL
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: sample, genotype: genotype, reads: 42),
                makeCall(sample: "SIMULATED-MHC-B-pairs", genotype: genotype, reads: 17),
            ],
            manifest: manifest
        )
        return Fixture(root: root, bundleURL: bundleURL, result: result)
    }

    /// Another writer adds a note after the viewer opened its store, so the
    /// viewer's next save is refused as stale.
    private func writeSidecarFromAnotherProcess(_ fixture: Fixture) throws {
        let other = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Other analyst",
            seedBuiltInSmartCohorts: false
        )
        try other.addSampleNote(sample: sample, body: "Written elsewhere")
    }

    private func descendant(of root: NSView, identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews {
            if let match = descendant(of: subview, identifier: identifier) { return match }
        }
        return nil
    }
}
