// ReferenceBundleAnnotationPersistenceTests.swift - FEA-03/UX-01 regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference bundles are the primary viewing mode, and `currentDocument` is explicitly nil
// for them (ViewerViewController.swift:3641, "Bundle replaces regular document"). Before
// this fix, `AppDelegate.handleAnnotationDeleted`/`handleAnnotationUpdated` guarded on
// `currentDocument` and returned early for bundle-mode annotations, so the viewer's
// "Delete Annotation" menu item and the Inspector's edit/delete controls looked like they
// worked (selection cleared, a "cannot be undone" confirmation was shown) but silently
// changed nothing on disk. These tests drive the same two notifications those UI entry
// points post, against a real `.lungfishref` bundle fixture, and assert the SQLite
// annotation database on disk is actually mutated and the mutation survives a bundle
// reopen.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishKit

@MainActor
final class ReferenceBundleAnnotationPersistenceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleAnnotationPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Delete

    func testViewerContextMenuDeleteConfirmationPersistsToBundleAndSurvivesReopen() async throws {
        let bundleURL = try makeBundleWithAnnotationTrack(named: "M1")
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        try windowController.mainSplitViewController.viewerController.displayBundle(at: bundleURL, mode: .browse)

        let annotation = try annotationFromDatabase(bundleURL: bundleURL, trackID: "imported", name: "geneA")

        // This is exactly what `SequenceViewerView.deleteAnnotationAction` posts (including
        // the window-state scope every real notification carries, per
        // `windowScopedUserInfo`), minus the confirmation sheet (already covered by the
        // alert wiring added alongside this fix). The scope is included explicitly --
        // rather than relying on `AppDelegate.activeMainWindowController()`'s
        // `NSApp.keyWindow` fallback -- so this test resolves the intended window
        // regardless of what other tests running in the same process left key.
        NotificationCenter.default.post(
            name: .annotationDeleted,
            object: windowController.mainSplitViewController.viewerController.viewerView,
            userInfo: [
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.windowStateScope: windowController.projectSession.windowStateScope,
            ]
        )

        try await waitForAnnotationRowCount(bundleURL: bundleURL, trackID: "imported", expected: 0)

        // The fixture's "imported" track has exactly one row, so deleting it also removes
        // the now-empty track and its database file
        // (`SequenceAnnotationTrackWorkflow.deleteAnnotations`'s `removedTrack` path) --
        // reopening a deleted file would fail, so assert the track is gone from the
        // manifest instead, which is the actually-persisted state to verify.
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertTrue(manifest.annotations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("annotations/imported.db").path
        ))

        withExtendedLifetime(delegate) {}
    }

    func testInspectorDeleteConfirmationPersistsToBundle() async throws {
        let bundleURL = try makeBundleWithAnnotationTrack(named: "M1")
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        try windowController.mainSplitViewController.viewerController.displayBundle(at: bundleURL, mode: .browse)

        let annotation = try annotationFromDatabase(bundleURL: bundleURL, trackID: "imported", name: "geneA")

        // This is exactly what `InspectorViewController+Editing.handleAnnotationDeletedFromInspector`
        // posts after the SwiftUI "cannot be undone" confirmationDialog is accepted
        // (`InspectorViewController.windowScopedUserInfo` adds the same window-state scope
        // key real production notifications carry).
        NotificationCenter.default.post(
            name: .annotationDeleted,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.changeSource: "inspector",
                NotificationUserInfoKey.windowStateScope: windowController.projectSession.windowStateScope,
            ]
        )

        try await waitForAnnotationRowCount(bundleURL: bundleURL, trackID: "imported", expected: 0)
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Update

    func testInspectorRenamePersistsToBundleAndSurvivesReopen() async throws {
        let bundleURL = try makeBundleWithAnnotationTrack(named: "M1")
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        try windowController.mainSplitViewController.viewerController.displayBundle(at: bundleURL, mode: .browse)

        var annotation = try annotationFromDatabase(bundleURL: bundleURL, trackID: "imported", name: "geneA")
        annotation.name = "renamed-gene"
        annotation.type = .cds

        // This is exactly what `SelectionSection.commitChangesImmediately` posts via
        // `onAnnotationUpdated` / `InspectorViewController+Editing.handleAnnotationUpdatedFromInspector`.
        NotificationCenter.default.post(
            name: .annotationUpdated,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.changeSource: "inspector",
                NotificationUserInfoKey.windowStateScope: windowController.projectSession.windowStateScope,
            ]
        )

        let dbURL = bundleURL.appendingPathComponent("annotations/imported.db")
        try await waitFor {
            let rows = try AnnotationDatabase(url: dbURL).queryForTable(limit: 10)
            return rows.first?.name == "renamed-gene" && rows.first?.type == "CDS"
        }

        // Reopen from disk to prove this isn't just an in-memory cache update.
        let reopened = try AnnotationDatabase(url: dbURL).queryForTable(limit: 10)
        XCTAssertEqual(reopened.first?.name, "renamed-gene")
        XCTAssertEqual(reopened.first?.type, "CDS")
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Selection is not an edit (regression)

    /// Regression for the live-reproduced bug: simply SELECTING an annotation in the
    /// drawer/viewer -- which the Inspector's SelectionSectionViewModel.select(annotation:)
    /// mirrors into its editable `name`/`type`/`color`/`notes` fields for display -- must
    /// never itself post `.annotationUpdated`. Before the fix, a SwiftUI onChange firing
    /// on the next render pass (after `select(annotation:)` already returned and reset
    /// `isUpdatingFromSelection` back to `false`) could commit the just-loaded, unchanged
    /// values right back as an "edit", starting an OperationCenter "Update Annotation" item
    /// and rewriting genome.db for a no-op.
    func testSelectingAnnotationInSelectionSectionViewModelPostsNoUpdate() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "geneA",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 2, end: 9)]
        )
        let vm = SelectionSectionViewModel()
        var updates: [SequenceAnnotation] = []
        vm.onAnnotationUpdated = { updates.append($0) }

        vm.select(annotation: annotation)

        // Simulate what a SwiftUI onChange would do if it fired the loaded value back
        // through the commit path even though nothing was actually edited -- this is
        // exactly the shape of the bug: the view's onChange handler calls `commitChanges()`
        // / `commitColorChange()` with `viewModel.name`/`.type`/`.color` already equal to
        // what `select(annotation:)` just populated.
        vm.commitChanges()
        vm.commitColorChange()

        XCTAssertTrue(updates.isEmpty, "Selecting an annotation must not commit an update when nothing changed")
    }

    /// Same regression, exercised through the real notification path and a real bundle:
    /// posting `.annotationUpdated` with an annotation identical to what the viewer already
    /// has cached must not create an OperationCenter item or touch the SQLite file on disk.
    func testAnnotationUpdatedNotificationIsNoOpWhenAnnotationIsUnchanged() async throws {
        let bundleURL = try makeBundleWithAnnotationTrack(named: "M1")
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        try windowController.mainSplitViewController.viewerController.displayBundle(at: bundleURL, mode: .browse)

        let annotation = try annotationFromDatabase(bundleURL: bundleURL, trackID: "imported", name: "geneA")

        // Seed the viewer's bundle-mode annotation cache directly with the same value the
        // Inspector would have loaded, rather than waiting on the async fetch pipeline
        // (`fetchAnnotationsAsync`) to populate it non-deterministically. This is exactly
        // the cache `AppDelegate.handleAnnotationUpdated`'s no-op guard consults via
        // `SequenceViewerView.currentAnnotation(withID:)`.
        windowController.mainSplitViewController.viewerController.viewerView.cachedBundleAnnotations = [annotation]

        let dbURL = bundleURL.appendingPathComponent("annotations/imported.db")
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.modificationDate] as? Date

        NotificationCenter.default.post(
            name: .annotationUpdated,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.changeSource: "inspector",
                NotificationUserInfoKey.windowStateScope: windowController.projectSession.windowStateScope,
            ]
        )

        // Give any (incorrectly) spawned Task a chance to run before asserting nothing
        // happened -- there is no positive condition to wait for, so a short fixed delay
        // is the only option; the assertions below are what actually catch a regression.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(
            OperationCenter.shared.activeItems.isEmpty,
            "Selecting/redisplaying an unchanged annotation must not start an OperationCenter item"
        )
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter, "genome.db must not be rewritten for a no-op update")

        let rows = try AnnotationDatabase(url: dbURL).queryForTable(limit: 10)
        XCTAssertEqual(rows.first?.name, "geneA")
        withExtendedLifetime(delegate) {}
    }

    /// Two rapid genuine updates (e.g. a fast retype) must never leave an operation stuck
    /// `.running`/0% holding the bundle lock -- every path through
    /// `persistReferenceBundleAnnotationUpdate` must end the operation exactly once, and a
    /// delete afterward must succeed rather than being refused as "Bundle Busy".
    func testRapidSuccessiveUpdatesLeaveNoRunningOperationAndBundleUnlocked() async throws {
        let bundleURL = try makeBundleWithAnnotationTrack(named: "M1")
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        try windowController.mainSplitViewController.viewerController.displayBundle(at: bundleURL, mode: .browse)

        let original = try annotationFromDatabase(bundleURL: bundleURL, trackID: "imported", name: "geneA")
        windowController.mainSplitViewController.viewerController.viewerView.cachedBundleAnnotations = [original]

        var first = original
        first.name = "first-rename"
        var second = original
        second.name = "second-rename"

        let userInfoBase: [String: Any] = [
            NotificationUserInfoKey.changeSource: "inspector",
            NotificationUserInfoKey.windowStateScope: windowController.projectSession.windowStateScope,
        ]

        NotificationCenter.default.post(
            name: .annotationUpdated,
            object: nil,
            userInfo: userInfoBase.merging([NotificationUserInfoKey.annotation: first]) { _, new in new }
        )
        NotificationCenter.default.post(
            name: .annotationUpdated,
            object: nil,
            userInfo: userInfoBase.merging([NotificationUserInfoKey.annotation: second]) { _, new in new }
        )

        // The two `Task { ... }`s posted above both start on the main actor before either
        // reaches its first `await`, so they run FIFO up to that suspension point: the
        // first Task's `OperationCenter.begin(...)` (synchronous, on the main actor) wins
        // the bundle lock before the second Task's `begin()` call ever runs, so the second
        // update is refused ("Bundle Busy") rather than racing the first to disk. Only the
        // first rename is therefore expected to land.
        let dbURL = bundleURL.appendingPathComponent("annotations/imported.db")
        try await waitFor {
            // The workflow briefly recreates/rewrites this file mid-mutation, so an open
            // failure here means "poll again shortly", not "the test has failed" --
            // `waitFor` will still time out and fail if the file never settles.
            guard let rows = try? AnnotationDatabase(url: dbURL).queryForTable(limit: 10) else { return false }
            return rows.first?.name == "first-rename"
        }

        // No operation left running/holding the lock, for either the winning update or
        // the one refused as "Bundle Busy".
        try await waitFor {
            OperationCenter.shared.activeItems.allSatisfy { $0.targetBundleURL?.standardizedFileURL != bundleURL.standardizedFileURL }
        }
        XCTAssertTrue(OperationCenter.shared.canStartOperation(on: bundleURL))

        // A delete right afterward must succeed rather than being refused as "Bundle Busy",
        // proving the lock was actually released.
        let toDelete = try annotationFromDatabase(bundleURL: bundleURL, trackID: "imported", name: "first-rename")
        NotificationCenter.default.post(
            name: .annotationDeleted,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.annotation: toDelete,
                NotificationUserInfoKey.changeSource: "inspector",
                NotificationUserInfoKey.windowStateScope: windowController.projectSession.windowStateScope,
            ]
        )
        try await waitForAnnotationRowCount(bundleURL: bundleURL, trackID: "imported", expected: 0)

        withExtendedLifetime(delegate) {}
    }

    // MARK: - Fixtures

    private func makeMainWindowAndDelegate() throws -> (MainWindowController, AppDelegate) {
        let delegate = AppDelegate()
        let directory = tempRoot.appendingPathComponent("window-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: directory.appendingPathComponent("windows.json"))

        // `createAndShowMainWindow` (not a bare `MainWindowController()` + manually
        // assigning `delegate.mainWindowController`) registers the controller in
        // `AppDelegate.mainWindowControllers`, not just the singular
        // `mainWindowController` property. That registration is required for
        // `AppDelegate.controller(forWindowStateScopeID:)` -- and so for
        // `viewerController(for:)` -- to resolve a notification carrying an explicit
        // `windowStateScope` (as every real annotation-edit notification does) to THIS
        // window rather than falling through to `NSApp.keyWindow`, which is unreliable
        // when other test files in the same process leave windows behind.
        let windowController = delegate.createAndShowMainWindow()
        _ = windowController.window

        // `handleAnnotationDeleted`/`handleAnnotationUpdated` are private `@objc` methods
        // normally wired by `AppDelegate.registerNotifications()` from
        // `applicationDidFinishLaunching`. This test hook registers just those two
        // observers, so the test exercises the real production selectors without driving
        // the full NSApplication launch sequence (menu install, tool management, etc).
        delegate.registerAnnotationNotificationObserversForTesting()
        addTeardownBlock {
            NotificationCenter.default.removeObserver(delegate)
            windowController.close()
        }

        return (windowController, delegate)
    }

    /// Builds a `.lungfishref` bundle with one SQLite-backed annotation track ("imported"),
    /// matching the shape `ReferenceBundleAnnotationImportService` produces.
    private func makeBundleWithAnnotationTrack(named name: String) throws -> URL {
        let bundleURL = tempRoot.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        try ">chr1\nACGTACGTACGTACGTACGTACGTACGTACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "chr1\t33\t6\t33\t34\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let bedURL = tempRoot.appendingPathComponent("\(name)-import.bed")
        try "chr1\t2\t9\tgeneA\t0\t+\t2\t9\t0,0,0\t1\t7,\t0,\tgene\tID=geneA;gene=geneA\n".write(
            to: bedURL,
            atomically: true,
            encoding: .utf8
        )
        let dbURL = annotationsDir.appendingPathComponent("imported.db")
        let featureCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        XCTAssertEqual(featureCount, 1)

        var manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 33,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 33, offset: 6, lineBases: 33, lineWidth: 34)
                ]
            )
        )
        manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "imported",
            name: "Imported",
            path: "annotations/imported.db",
            databasePath: "annotations/imported.db",
            annotationType: .custom,
            featureCount: featureCount,
            source: "test"
        ))
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// Reads the annotation directly out of the bundle's SQLite database and stamps the
    /// same qualifiers `SequenceViewerView+Rendering.fetchAnnotationsAsync` and
    /// `AnnotationDatabaseRecord.toAnnotation()` stamp onto every bundle-backed annotation
    /// the viewer or Inspector would actually hand to `AppDelegate`
    /// (`annotation_db_track_id`, `annotation_db_row_id`).
    private func annotationFromDatabase(bundleURL: URL, trackID: String, name: String) throws -> SequenceAnnotation {
        let dbURL = bundleURL.appendingPathComponent("annotations/\(trackID).db")
        let db = try AnnotationDatabase(url: dbURL)
        let record = try XCTUnwrap(db.queryForTable(limit: 10).first { $0.name == name })
        var annotation = record.toAnnotation()
        annotation.qualifiers["annotation_db_track_id"] = AnnotationQualifier(trackID)
        return annotation
    }

    private func waitForAnnotationRowCount(bundleURL: URL, trackID: String, expected: Int) async throws {
        try await waitFor {
            let dbURL = bundleURL.appendingPathComponent("annotations/\(trackID).db")
            guard FileManager.default.fileExists(atPath: dbURL.path) else { return expected == 0 }
            return try AnnotationDatabase(url: dbURL).queryForTable(limit: 10).count == expected
        }
    }

    /// The AppDelegate handlers dispatch the actual persistence through an unstructured
    /// `Task { @MainActor in ... }` (so the notification-posting call site never blocks on
    /// the CLI-backed workflow's file I/O). Poll briefly for the on-disk effect instead of
    /// assuming synchronous completion.
    private func waitFor(
        // A CLI subprocess spawn plus real file I/O under the full parallel
        // unit tier's 13,000+ concurrent xctest processes can starve this
        // unstructured Task of scheduling time well past a short budget
        // (TST-10); 5s was observed to time out under that load even though
        // the mutation completes correctly once it runs.
        timeout: TimeInterval = 20,
        _ predicate: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the annotation mutation to persist")
    }
}
