// NvdSurfaceRouteTests.swift - The NVD result leaves the Summary with its viewer (Phase 3.1 lane NVDV)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// NET-UX row 4, INSPECTOR-BLOCK-OWNER. After an NVD result, a later 12S, reference or FASTQ item kept the NVD block in
// the Summary, because only the next classifier display cleared it. The NVD viewer now opens through the surface host,
// and its surface takes its own block out when the host removes it (NAOMGS-ARCH carry list, items 1 to 3).
//
// Each test opens an NVD result as the sidebar does (`displayContent(for:)`) and waits until the Summary holds its
// block. The result bundles come from the committed BLAST table through the production parser and database writer
// (RoutingSafetyNetFixtures). As in `NaoMgsSurfaceRouteTests`, the test methods are synchronous and wait by turning
// the main run loop, and only `setUp` is async.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishNvdUI

/// A surface whose load always fails, so the NVD show never installs.
@MainActor
private final class RefusingNvdSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.nvd) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class NvdSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var nvd: URL!
    private var secondNvd: URL!
    private var fastqBundle: URL!

    /// The NVD result view saves its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "nvd-surface-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        NvdResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "NvdSurfaceRouteTests").defaults
        nvd = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-result", in: root).bundle
        secondNvd = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-second", in: root).bundle
        fastqBundle = try await RoutingSafetyNetFixtures.fastqBundle(in: root).bundle
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        window.contentViewController = nil
        window = nil
        controller = nil
        NvdResultViewController.testMetadataUserDefaultsOverride = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A 12S result and a FASTQ bundle, each opened after an NVD result, hold no NVD block.
    func testA12SResultOrAFASTQBundleAfterNvdHoldsNoNvdBlock() throws {
        let twelveS = try RoutingSafetyNetFixtures.twelveSResultBundle(in: root).bundle
        let next: [(name: String, item: SidebarItem, isShown: @MainActor () -> Bool)] = [
            ("a 12S result", item(twelveS, .twelveSAmpliconResultBundle), {
                self.controller.viewerController.twelveSAmpliconResultViewController != nil
            }),
            ("a FASTQ bundle", item(fastqBundle, .fastqBundle), {
                self.controller.viewerController.isDisplayingFASTQDataset
            }),
        ]
        for result in next {
            openNvdAndWaitForItsBlock()
            controller.displayContent(for: result.item)
            XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { result.isShown() }, "\(result.name) never opened")
            XCTAssertNil(summary.nvdManifest, "\(result.name) opened after an NVD result must hold no NVD block")
        }
    }

    /// The viewer's teardown takes the NVD block out, and only that block. A block the incoming route gave first,
    /// such as Operation Details, stays (NAOMGS-ARCH item 2).
    func testTheNvdViewerTakesOnlyItsOwnBlockWhenItLeaves() {
        openNvdAndWaitForItsBlock()
        controller.viewerController.clearSurface(ifShowing: .analysis(.nvd))
        XCTAssertNil(summary.nvdManifest, "the NVD block must leave with the NVD viewer")

        openNvdAndWaitForItsBlock()
        controller.inspectorController.updateBatchOperationDetails(
            tool: "Kraken2", parameters: [:], timestamp: nil, sourceSamples: []
        )
        controller.viewerController.clearSurface(ifShowing: .analysis(.nvd))
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the leaving NVD viewer wiped the next result's block")
        XCTAssertNil(installedNvdViewer, "the NVD viewer stayed after its hide")
    }

    /// An NVD viewer that does not open says what happened and what to try, with no internal kind id, and starts no
    /// load (NAOMGS-ARCH item 3).
    func testAnNvdResultThatDoesNotOpenSaysWhatToTry() {
        controller.viewerController.surfaceHost.registry.register(.analysis(.nvd)) { RefusingNvdSurface() }
        controller.displayContent(for: item(nvd, .nvdResult))

        let words = controller.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the NVD result."), words)
        XCTAssertTrue(words.contains("Select it again."), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertNil(installedNvdViewer, "an NVD viewer was installed although its surface refused")
        XCTAssertNil(summary.nvdManifest)
    }

    // MARK: - Its own kind

    /// A second NVD result replaces the first: one viewer, showing the second result, and the new result's block
    /// arrives after the old viewer took its own out (no skip and no flag).
    func testASecondNvdResultReplacesTheFirstAndKeepsItsOwnBlock() {
        openNvdAndWaitForItsBlock()
        controller.displayContent(for: item(secondNvd, .nvdResult))
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) {
                self.summary.nvdManifest != nil
                    && self.installedNvdViewer?.bundleURL?.standardizedFileURL == self.secondNvd.standardizedFileURL
            },
            "the second NVD result never gave the Summary its block"
        )
        XCTAssertEqual(controller.viewerController.children.filter { $0 is NvdResultViewController }.count, 1)
    }

    // MARK: - Helpers

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    /// The NVD viewer among the viewer's children, the host's child included.
    private var installedNvdViewer: NvdResultViewController? {
        controller.viewerController.children.lazy.compactMap { $0 as? NvdResultViewController }.first
    }

    private func openNvdAndWaitForItsBlock(file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: item(nvd, .nvdResult))
        let loaded = waitUntilOnRunLoop(budget: .lookup) { self.summary.nvdManifest != nil }
        XCTAssertTrue(loaded, "the NVD result never gave the Summary its block", file: file, line: line)
    }

    private func item(_ url: URL, _ type: SidebarItemType) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: type, url: url)
    }
}
