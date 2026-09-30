// WorkflowCompletionBundleDisplayTests.swift - A finished Inspector workflow keeps its bundle on screen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// Preview 2026.9.64 click-test: a primer trim started from a mapping result
/// finished, but the window stayed on the mapping viewport and the
/// Inspector's Bundle tab showed the mapping run summary, not the Alignment
/// Tracks list. The completion displayed the reference bundle inside the
/// mapping result, then the sidebar rescan it had requested re-opened the
/// still-selected mapping result row on top of it. Creating a deduplicated
/// bundle had the same completion and lost its new bundle to the source row.
@MainActor
final class WorkflowCompletionBundleDisplayTests: XCTestCase {
    private var tempRoot: URL!
    private var projectURL: URL!
    private var split: MainSplitViewController!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowCompletionDisplay-\(UUID().uuidString)", isDirectory: true)
        projectURL = tempRoot.appendingPathComponent("Amplicons.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SidebarViewController.scanBarrierForTesting = nil
        split?.sidebarController.closeProject()
        split = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    func testPrimerTrimShowsTheBundleInsideTheMappingResultAfterTheSidebarRescan() async throws {
        let resultURL = try AnalysesFolder.createAnalysisDirectory(tool: "minimap2", in: projectURL)
        let bundleURL = try makeBundle(named: "MN908947.3", in: resultURL)
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL
        ).save(to: resultURL)
        AnalysesFolder.markAnalysisComplete(resultURL)

        let sidebar = openProjectSelecting(resultURL)
        split.displayMappingAnalysisFromSidebar(at: resultURL)
        XCTAssertNotNil(split.viewerController.activeMappingViewportController, "precondition")
        XCTAssertNotNil(split.inspectorController.viewModel.documentSectionViewModel.mappingDocument, "precondition")

        try await displayAfterWorkflowAndSettle(bundleURL)

        XCTAssertNil(
            split.viewerController.activeMappingViewportController,
            "the rescan must not re-open the mapping result over the bundle"
        )
        XCTAssertNotNil(split.viewerController.referenceBundleViewportController)
        let document = split.inspectorController.viewModel.documentSectionViewModel
        XCTAssertNil(document.mappingDocument, "the Bundle tab must not show the mapping run summary")
        XCTAssertEqual(document.bundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(split.inspectorController.viewModel.readStyleSectionViewModel.hasAlignmentTracks)
        XCTAssertEqual(
            sidebar.selectedFileURL?.standardizedFileURL, resultURL.standardizedFileURL,
            "the bundle inside a mapping result has no row, so the mapping result stays selected"
        )
    }

    func testDeduplicatedBundleStaysDisplayedAndIsSelectedAfterTheSidebarRescan() async throws {
        let sourceURL = try makeBundle(named: "Reference", in: projectURL)
        let sidebar = openProjectSelecting(sourceURL)
        try split.displayReferenceBundleFromExternalOpen(at: sourceURL)
        let deduplicatedURL = try makeBundle(named: "Reference-deduplicated", in: projectURL)

        try await displayAfterWorkflowAndSettle(deduplicatedURL)

        XCTAssertEqual(
            split.inspectorController.viewModel.documentSectionViewModel.bundleURL?.standardizedFileURL,
            deduplicatedURL.standardizedFileURL,
            "the rescan must not re-open the source bundle over the new one"
        )
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, deduplicatedURL.standardizedFileURL)
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

    /// Runs the shared workflow completion, waits for the sidebar rescan it
    /// starts to apply, then gives anything that rescan scheduled time to land.
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
}
