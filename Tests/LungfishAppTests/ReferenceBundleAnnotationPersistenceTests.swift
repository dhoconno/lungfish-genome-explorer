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
