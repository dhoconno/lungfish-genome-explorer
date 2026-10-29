// NaoMgsSurfaceRouteTests.swift - The NAO-MGS result leaves the Summary with its viewer (Phase 3.1 lane NAOMGS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// NET-UX row 4, INSPECTOR-BLOCK-OWNER. After a NAO-MGS result, a later 12S or FASTQ item kept the NAO-MGS block in
// the Summary, because only the next classifier display cleared it. The NAO-MGS viewer now opens through the surface
// host, and its surface takes its own block out when the host removes it (HOST-ARCH-2 carry list, items 5 to 7).
//
// Each test opens a NAO-MGS result as the sidebar does (`displayContent(for:)`) and waits until the Summary holds its
// block. The result bundles come from the committed virus hits table through the production parser and database
// writer (RoutingSafetyNetFixtures). As in `InspectorResultBlockTests`, the test methods are synchronous and wait by
// turning the main run loop, and only `setUp` is async.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
import LungfishNaoMgsUI

/// A surface whose load always fails, so the NAO-MGS show never installs.
@MainActor
private final class RefusingNaoMgsSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.naomgs) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class NaoMgsSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var naoMgs: URL!
    private var secondNaoMgs: URL!
    private var fastqBundle: URL!

    /// The NAO-MGS result view saves its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "naomgs-surface-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        naoMgs = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-result", in: root).bundle
        secondNaoMgs = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-second", in: root).bundle
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
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A 12S result and a FASTQ bundle, each opened after a NAO-MGS result, hold no NAO-MGS block.
    func testA12SResultOrAFASTQBundleAfterNaoMgsHoldsNoNaoMgsBlock() throws {
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
            openNaoMgsAndWaitForItsBlock()
            controller.displayContent(for: result.item)
            XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { result.isShown() }, "\(result.name) never opened")
            XCTAssertNil(summary.naoMgsManifest, "\(result.name) opened after a NAO-MGS result must hold no NAO-MGS block")
        }
    }

    /// The viewer's teardown takes the NAO-MGS block out, and only that block. A block the incoming route gave
    /// first, such as Operation Details, stays (HOST-ARCH-2 item 6).
    func testTheNaoMgsViewerTakesOnlyItsOwnBlockWhenItLeaves() {
        openNaoMgsAndWaitForItsBlock()
        controller.viewerController.hideNaoMgsView()
        XCTAssertNil(summary.naoMgsManifest, "the NAO-MGS block must leave with the NAO-MGS viewer")

        openNaoMgsAndWaitForItsBlock()
        controller.inspectorController.updateBatchOperationDetails(
            tool: "Kraken2", parameters: [:], timestamp: nil, sourceSamples: []
        )
        controller.viewerController.hideNaoMgsView()
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the leaving NAO-MGS viewer wiped the next result's block")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is NaoMgsResultViewController })
    }

    /// A NAO-MGS viewer that does not open says what happened and what to try, with no internal kind id, and starts
    /// no load (HOST-ARCH-2 item 7).
    func testANaoMgsResultThatDoesNotOpenSaysWhatToTry() {
        controller.viewerController.surfaceHost.registry.register(.analysis(.naomgs)) { RefusingNaoMgsSurface() }
        controller.displayContent(for: item(naoMgs, .naoMgsResult))

        let words = controller.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the NAO-MGS result."), words)
        XCTAssertTrue(words.contains("Select it again."), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is NaoMgsResultViewController })
        XCTAssertNil(summary.naoMgsManifest)
    }

    // MARK: - Its own kind

    /// A second NAO-MGS result replaces the first: one viewer, and the new result's block arrives after the old
    /// viewer took its own out (HOST-ARCH-2 item 5, no skip and no flag).
    func testASecondNaoMgsResultReplacesTheFirstAndKeepsItsOwnBlock() {
        openNaoMgsAndWaitForItsBlock()
        controller.displayContent(for: item(secondNaoMgs, .naoMgsResult))
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { self.summary.naoMgsManifest != nil },
            "the second NAO-MGS result never gave the Summary its block"
        )
        XCTAssertEqual(controller.viewerController.children.filter { $0 is NaoMgsResultViewController }.count, 1)
    }

    // MARK: - Helpers

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    private func openNaoMgsAndWaitForItsBlock(file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: item(naoMgs, .naoMgsResult))
        let loaded = waitUntilOnRunLoop(budget: .lookup) { self.summary.naoMgsManifest != nil }
        XCTAssertTrue(loaded, "the NAO-MGS result never gave the Summary its block", file: file, line: line)
    }

    private func item(_ url: URL, _ type: SidebarItemType) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: type, url: url)
    }
}
