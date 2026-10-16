// PrimerTrimInspectorAfterRevealTests.swift - The Inspector ends on the bundle a finished workflow shows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U61 (RU5). A finished primer trim or deduplication shows its reference bundle through
// `displayReferenceBundleAfterWorkflow`. It clears the Inspector and sets its provenance target at once and asks
// the sidebar to reveal the bundle's row. The reveal now posts the selection notice, so the Inspector retargets
// a second time on the same bundle when the sidebar lists the row. Each test waits for the reveal to end and
// reads the Inspector, and hashes the result and the bundles before and after, since a display writes nothing.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

@MainActor
final class PrimerTrimInspectorAfterRevealTests: XCTestCase {
    private var tempRoot: URL!
    private var projectURL: URL!
    private var split: MainSplitViewController!
    private var notices: SelectionNoticeRecorder!

    override func setUpWithError() throws {
        tempRoot = try TestTempDirectory.make(prefix: "primer-trim-inspector-reveal")
        projectURL = tempRoot.appendingPathComponent("Amplicons.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        notices = SelectionNoticeRecorder()
    }

    override func tearDownWithError() throws {
        notices.stop()
        SidebarViewController.scanBarrierForTesting = nil
        split?.sidebarController.closeProject()
        split = nil
        if let tempRoot { TestTempDirectory.cleanup(tempRoot) }
    }

    /// A primer trim run from a mapping result writes into the bundle inside it. That bundle has no row, so
    /// the reveal selects nothing and posts nothing, and the Inspector stays on the bundle the display set.
    func testThePrimerTrimDisplayEndsOnTheBundleInsideTheMappingResult() async throws {
        let resultURL = try AnalysesFolder.createAnalysisDirectory(tool: "minimap2", in: projectURL)
        let bundleURL = try makeBundle(named: "MN908947.3", in: resultURL)
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL
        ).save(to: resultURL)
        AnalysesFolder.markAnalysisComplete(resultURL)
        let sidebar = openProjectSelecting(resultURL)
        split.displayMappingAnalysisFromSidebar(at: resultURL)
        notices.watch(sidebar)
        let before = try TreeDigest.of(resultURL)

        try await displayAfterWorkflowAndSettle(bundleURL)

        let inspector = try XCTUnwrap(split.inspectorController)
        XCTAssertEqual(
            inspector.viewModel.provenanceSectionViewModel.currentItem?.url?.standardizedFileURL, bundleURL.standardizedFileURL,
            "the Inspector's provenance target ends on the bundle"
        )
        let document = inspector.viewModel.documentSectionViewModel
        XCTAssertEqual(document.bundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertNil(document.mappingDocument, "the Bundle tab must not show the mapping run summary")
        XCTAssertEqual(notices.paths, [], "a bundle with no row is not revealed, so no selection notice is posted")
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, resultURL.standardizedFileURL)
        XCTAssertEqual(try TreeDigest.of(resultURL), before, "the display and the reveal write nothing into the result or its bundle")
    }

    /// A deduplicated bundle sits beside its source and has a row. The reveal selects the row and posts one
    /// notice, the Inspector retargets on it, and it still ends on the new bundle.
    func testTheDeduplicatedBundleDisplayEndsOnTheBundleAfterTheRevealNotice() async throws {
        let sourceURL = try makeBundle(named: "Reference", in: projectURL)
        let sidebar = openProjectSelecting(sourceURL)
        try split.displayReferenceBundleFromExternalOpen(at: sourceURL)
        let deduplicatedURL = try makeBundle(named: "Reference-deduplicated", in: projectURL)
        notices.watch(sidebar)
        let before = try TreeDigest.of(projectURL)

        try await displayAfterWorkflowAndSettle(deduplicatedURL)

        let selected = await eventually { sidebar.selectedFileURL?.standardizedFileURL == deduplicatedURL.standardizedFileURL }
        XCTAssertTrue(selected, "the reveal never selected the new bundle's row")
        let inspector = try XCTUnwrap(split.inspectorController)
        XCTAssertEqual(notices.paths, [deduplicatedURL.standardizedFileURL.path], "one notice, naming the new bundle")
        XCTAssertEqual(
            inspector.viewModel.provenanceSectionViewModel.currentItem?.url?.standardizedFileURL, deduplicatedURL.standardizedFileURL,
            "the Inspector's provenance target ends on the new bundle"
        )
        XCTAssertEqual(
            inspector.viewModel.documentSectionViewModel.bundleURL?.standardizedFileURL, deduplicatedURL.standardizedFileURL,
            "the Bundle tab ends on the new bundle and not on its source"
        )
        XCTAssertEqual(inspector.viewModel.selectedItem, sidebar.selectedItems().first?.title)
        XCTAssertEqual(try TreeDigest.of(projectURL), before, "the display and the reveal write nothing into the project")
    }

    // MARK: - Helpers

    private func makeBundle(named name: String, in directory: URL) throws -> URL {
        let scratchURL = try MappingRoutingFixture.makeReferenceBundle(
            name: name,
            chromosomes: [.init(name: "MN908947.3", length: 200)]
        )
        defer { try? FileManager.default.removeItem(at: scratchURL.deletingLastPathComponent()) }
        let bundleURL = directory.appendingPathComponent(scratchURL.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: scratchURL, to: bundleURL)
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true
        )
        return bundleURL
    }

    private func openProjectSelecting(_ url: URL) -> SidebarViewController {
        split = MainSplitViewController()
        split.loadViewIfNeeded()
        let sidebar: SidebarViewController = split.sidebarController
        sidebar.openProject(at: projectURL)
        sidebar.detachFilesystemWatcherForTesting()
        XCTAssertTrue(
            sidebar.withSelectionSuppressed { sidebar.selectItem(forURL: url) },
            "precondition: \(url.lastPathComponent) is the selected sidebar row"
        )
        return sidebar
    }

    /// Runs the shared workflow completion, waits for the sidebar rescan it starts to apply, then gives
    /// anything that rescan scheduled time to land.
    private func displayAfterWorkflowAndSettle(_ bundleURL: URL) async throws {
        let (scanReachedApply, signal) = AsyncStream<Void>.makeStream()
        SidebarViewController.scanBarrierForTesting = { signal.yield() }

        try split.displayReferenceBundleAfterWorkflow(at: bundleURL)

        var iterator = scanReachedApply.makeAsyncIterator()
        _ = await iterator.next()
        SidebarViewController.scanBarrierForTesting = nil
        for _ in 0..<50 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Polls `condition` every 10 ms and returns as soon as it holds, or false after 30 seconds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
