// AppProvenanceExportSelectionTests.swift - File > Export > Provenance follows the sidebar selection through the real window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

/// The 2026-10-10 GUI walk, without the screen.
///
/// A GFF3 with its sidecar is selected and loaded, and then README.md is selected. The
/// viewer shows README.md through a Quick Look style preview that never resets
/// `viewerController.currentDocument`, so the GFF3 stays the viewer's document. The export
/// resolver must follow the sidebar selection. It used to offer the GFF3's record while the
/// Provenance tab read Missing for README.md.
///
/// The pure choice has its own tests in `AppProvenanceExportSourceResolverTests`. This test
/// pins that the app hands the resolver the real viewer and the real sidebar selection.
@MainActor
final class AppProvenanceExportSelectionTests: XCTestCase {
    private static let timeout: Duration = .seconds(30)

    func testPreviewedReadmeIsNotExportedAsTheViewedGFF3() async throws {
        _ = NSApplication.shared

        let scratch = try TestTempDirectory.make(prefix: "provenance-export-selection")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Walk.lungfish", isDirectory: true)
        let folder = project.appendingPathComponent("Bare Run Check", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gff3 = folder.appendingPathComponent("MN908947.3.gff3")
        let sidecar = folder.appendingPathComponent("MN908947.3.gff3.lungfish-provenance.json")
        for url in [gff3, sidecar] {
            try FileManager.default.copyItem(
                at: ProvenanceDisplayFixtures.sarscov2Directory.appendingPathComponent(url.lastPathComponent),
                to: url
            )
        }
        let readme = project.appendingPathComponent("README.md")
        try "# Walk\n\nNotes for the bare run check.\n".write(to: readme, atomically: true, encoding: .utf8)

        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        let split: MainSplitViewController = controller.mainSplitViewController
        split.loadViewIfNeeded()
        let previews = RecordingFilePreviewRenderer.install(on: split.viewerController)
        DocumentManager.shared.mirrorProjectSession(controller.projectSession)
        defer {
            split.sidebarController.closeProject()
            DocumentManager.shared.closeActiveProject()
        }
        let sidebar: SidebarViewController = split.sidebarController
        sidebar.openProject(at: project)

        // The GFF3 is selected and viewed. The viewer and the selection agree.
        guard sidebar.selectItem(forURL: gff3) else { return XCTFail("The sidebar has no row for the GFF3.") }
        let viewed = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            split.viewerController.currentDocument?.url.canonicalFilePath == gff3.canonicalFilePath
        }
        guard viewed else { return XCTFail("The viewer never showed the GFF3.") }
        guard case .resolved(let gff3Source) = delegate.currentProvenanceExportResolution() else {
            return XCTFail("The viewed GFF3 has a record beside it, so the export must resolve.")
        }
        XCTAssertEqual(gff3Source.selectedURL.canonicalFilePath, gff3.canonicalFilePath)
        XCTAssertEqual(gff3Source.sourceSidecarURL.canonicalFilePath, sidecar.canonicalFilePath)

        // README.md is selected. The preview replaces the viewport, and the viewer keeps the
        // GFF3 as its current document.
        guard sidebar.selectItem(forURL: readme) else { return XCTFail("The sidebar has no row for README.md.") }
        let previewed = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            previews.renderedURLs.contains { $0.canonicalFilePath == readme.canonicalFilePath }
        }
        guard previewed else { return XCTFail("The viewer never previewed README.md.") }
        XCTAssertEqual(
            split.viewerController.currentDocument?.url.canonicalFilePath, gff3.canonicalFilePath,
            "The preview is expected to leave the GFF3 as the viewer's document. That is the stale state under test."
        )

        // The export follows the selection. README.md has no record, so nothing is offered.
        switch delegate.currentProvenanceExportResolution() {
        case .unresolvedSelection(let url):
            XCTAssertEqual(url.canonicalFilePath, readme.canonicalFilePath)
        case .resolved(let source):
            XCTFail("The export offered the record of \(source.selectedURL.lastPathComponent) for README.md.")
        case .noCurrentSource:
            XCTFail("The export found no source although README.md is selected.")
        }
    }
}
