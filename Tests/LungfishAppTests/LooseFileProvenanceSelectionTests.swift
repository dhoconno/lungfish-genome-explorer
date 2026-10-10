// LooseFileProvenanceSelectionTests.swift - A loose file's sidecar reaches the Provenance tab on the first selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

/// Selecting a loose file in the sidebar shows the sidecar that sits beside it.
///
/// The 2026-10-10 GUI walk selected `Bare Run Check/MN908947.3.gff3`, a GFF3 with the bare
/// legacy run `lungfish-cli` wrote beside it, and the Provenance tab read "No provenance
/// required". The click pointed the tab at the file and the lookup found the record. About
/// 0.1 s later the document loader published the GFF3 to the viewer and cleared the Inspector,
/// and nothing pointed the tab at the file again. A second selection took the cached branch,
/// which does not clear, so only the first selection lost the record.
///
/// The test drives the real path. It selects each row through the sidebar controller, so the
/// selection notification, the debounced display, the document load and the publish closure
/// all run. The window is never ordered in, so no test double stands in for the viewer.
@MainActor
final class LooseFileProvenanceSelectionTests: XCTestCase {

    /// The load runs on a detached task and the Inspector lookup on another, so the waits
    /// allow for a loaded host. Each wait returns as soon as its condition holds. The module
    /// has its own `waitUntil(timeoutNanoseconds:)` with a short default, so every call here
    /// names the shared helper and passes this timeout.
    private static let timeout: Duration = .seconds(30)

    func testFirstSelectionOfALooseGFF3ShowsItsSidecarAndASecondSelectionKeepsIt() async throws {
        _ = NSApplication.shared

        let scratch = try TestTempDirectory.make(prefix: "loose-file-provenance")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Walk.lungfish", isDirectory: true)
        let folder = project.appendingPathComponent("Bare Run Check", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The real bare legacy run and the GFF3 it describes, copied beside each other.
        let gff3Name = "MN908947.3.gff3"
        let sidecarName = "\(gff3Name).lungfish-provenance.json"
        let gff3 = folder.appendingPathComponent(gff3Name)
        let sidecar = folder.appendingPathComponent(sidecarName)
        for name in [gff3Name, sidecarName] {
            try FileManager.default.copyItem(
                at: ProvenanceDisplayFixtures.sarscov2Directory.appendingPathComponent(name),
                to: folder.appendingPathComponent(name)
            )
        }
        // A second loose file with no record, for the "another row" step.
        let plain = folder.appendingPathComponent("plain.gff3")
        try "##gff-version 3\nchr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1\n"
            .write(to: plain, atomically: true, encoding: .utf8)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        // The app mirrors the front window's session into the document manager. Without it
        // the second selection could not take the cached branch the app takes.
        DocumentManager.shared.mirrorProjectSession(split.projectSession)
        defer {
            split.sidebarController.closeProject()
            DocumentManager.shared.closeActiveProject()
        }
        let sidebar: SidebarViewController = split.sidebarController
        sidebar.openProject(at: project)
        let inspector: InspectorViewController = split.inspectorController
        let provenance = inspector.viewModel.provenanceSectionViewModel

        // First selection. The document is published to the viewer, and then the tab must
        // still hold the record. Before the fix the publish cleared it and the wait below
        // timed out with no current item.
        guard sidebar.selectItem(forURL: gff3) else { return XCTFail("The sidebar has no row for \(gff3Name).") }
        let firstDisplayed = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            split.viewerController.currentDocument?.url.canonicalFilePath == gff3.canonicalFilePath
        }
        guard firstDisplayed else { return XCTFail("The viewer never showed \(gff3Name).") }
        await split.externalDocumentLoadTask?.value
        let firstResolved = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            !provenance.isLoading && provenance.resolvedSidecarURL != nil
        }
        guard firstResolved else {
            return XCTFail(
                "The Provenance tab never resolved the sidecar of \(gff3Name). Current item \(String(describing: provenance.currentItem?.url?.lastPathComponent)), status \(provenance.audit.status)."
            )
        }
        try assertShowsTheRecord(of: gff3, sidecar: sidecar, provenance: provenance, inspector: inspector)

        // Another row. A loose file with no record reads Missing, and the tab does not keep
        // the previous file's record.
        guard sidebar.selectItem(forURL: plain) else { return XCTFail("The sidebar has no row for plain.gff3.") }
        let plainDisplayed = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            split.viewerController.currentDocument?.url.canonicalFilePath == plain.canonicalFilePath
        }
        guard plainDisplayed else { return XCTFail("The viewer never showed plain.gff3.") }
        await split.externalDocumentLoadTask?.value
        let plainSettled = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            !provenance.isLoading && provenance.currentItem?.url?.canonicalFilePath == plain.canonicalFilePath
        }
        guard plainSettled else { return XCTFail("The Provenance tab never targeted plain.gff3.") }
        XCTAssertNil(provenance.resolvedSidecarURL)
        XCTAssertEqual(provenance.audit.status, .missing)

        // Second selection of the GFF3. The document is registered now, so the display takes
        // the cached branch, and the record must still be there.
        guard sidebar.selectItem(forURL: gff3) else { return XCTFail("The sidebar has no row for \(gff3Name).") }
        let secondDisplayed = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            split.viewerController.currentDocument?.url.canonicalFilePath == gff3.canonicalFilePath
        }
        guard secondDisplayed else { return XCTFail("The viewer never showed \(gff3Name) again.") }
        let secondResolved = await LungfishTestSupport.waitUntil(timeout: Self.timeout) {
            !provenance.isLoading && provenance.resolvedSidecarURL != nil
        }
        guard secondResolved else {
            return XCTFail("The Provenance tab lost the sidecar of \(gff3Name) on the second selection.")
        }
        try assertShowsTheRecord(of: gff3, sidecar: sidecar, provenance: provenance, inspector: inspector)
    }

    /// The tab names the file, resolves the sidecar beside it and shows what the file holds.
    private func assertShowsTheRecord(
        of gff3: URL,
        sidecar: URL,
        provenance: ProvenanceInspectorViewModel,
        inspector: InspectorViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            provenance.currentItem?.url?.canonicalFilePath, gff3.canonicalFilePath,
            "The tab targets another file.", file: file, line: line
        )
        XCTAssertEqual(provenance.currentItem?.sidebarType, .annotation, file: file, line: line)
        XCTAssertEqual(
            provenance.resolvedSidecarURL?.canonicalFilePath, sidecar.canonicalFilePath,
            "The tab resolved another sidecar.", file: file, line: line
        )
        // The bare legacy run has no checksum for the NCBI address it fetched from, so the
        // converted record reads Incomplete and not Complete.
        XCTAssertEqual(provenance.audit.status, .incomplete, file: file, line: line)
        XCTAssertEqual(provenance.summary.statusLabel, "Incomplete", file: file, line: line)
        XCTAssertEqual(
            Data(provenance.rawJSON.utf8), try Data(contentsOf: sidecar),
            "Raw JSON is not the sidecar file.", file: file, line: line
        )
        XCTAssertTrue(
            inspector.viewModel.availableTabs.contains(.provenance),
            "The Provenance tab is not offered.", file: file, line: line
        )
    }
}
