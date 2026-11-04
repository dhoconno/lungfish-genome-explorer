// MHCReferenceBundleSurfaceRouteTests.swift - The MHC reference viewer opens through the surface host (Phase 3.2 lane MHC)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The MHC amplicon reference viewer was the one native viewer that three kinds of route never removed: the
// alignment, tree, classifier and assembly displays all clear their predecessors through
// `hideAlignmentTreeBundleViews()`, which had no MHC line (NET-MHC-HOST-STAYS). The viewer now opens through the
// surface host, and that hide list removes it.
//
// Each test opens an MHC bundle as the sidebar does (`displayContent(for:)`). The route reads the bundle off the
// main actor, so the tests wait by turning the main run loop.

import AppKit
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

/// A surface whose load always fails, so the MHC show never installs.
@MainActor
private final class RefusingMHCSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(.mhcReference) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class MHCReferenceBundleSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var mhcBundle: URL!
    private var secondMHCBundle: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "mhc-surface-route")
        mhcBundle = root.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        secondMHCBundle = root.appendingPathComponent("CYN.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: mhcBundle, name: "MCM")
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: secondMHCBundle, name: "CYN")
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
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// The MHC viewer is the surface host's installed surface, and the host's one child.
    func testTheMHCViewerOpensThroughTheSurfaceHost() {
        openMHCAndWaitForItsViewer(mhcBundle)

        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .bundle(.mhcReference))
        XCTAssertEqual(viewer.children.filter { $0 is NSHostingController<MHCReferenceBundleViewport> }.count, 1)
    }

    /// The hide list that the alignment, tree, classifier and assembly displays share removes the MHC viewer.
    func testTheAlignmentAndTreeHideListRemovesTheMHCViewer() {
        openMHCAndWaitForItsViewer(mhcBundle)

        viewer.hideAlignmentTreeBundleViews()

        XCTAssertNil(viewer.mhcReferenceBundleViewController, "the MHC viewer stayed under the next result")
        XCTAssertTrue(viewer.children.filter { $0 is NSHostingController<MHCReferenceBundleViewport> }.isEmpty)
    }

    /// An MHC viewer that does not open says what happened and what to try, with no internal kind id, and leaves
    /// neither a viewer nor an Inspector document behind.
    func testAnMHCReferenceBundleThatDoesNotOpenSaysWhatToTry() {
        viewer.surfaceHost.registry.register(.bundle(.mhcReference)) { RefusingMHCSurface() }
        controller.displayContent(for: item(mhcBundle))

        let words = { self.viewer.statusBar.positionLabel.stringValue }
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { words().contains("Unable to open the MHC reference bundle.") },
            "the status line never said the bundle did not open: \(words())"
        )
        XCTAssertTrue(words().contains("Select it again."), words())
        XCTAssertFalse(words().contains("bundle:"), "the words name an internal kind id: \(words())")
        XCTAssertNil(viewer.mhcReferenceBundleViewController)
        XCTAssertNil(summary.mhcReferenceBundleDocument, "the Inspector describes a bundle that is not shown")
    }

    // MARK: - Its own kind

    /// A second MHC bundle replaces the first: one viewer, and the Inspector document is the second bundle's.
    func testASecondMHCReferenceBundleReplacesTheFirstAndKeepsItsOwnDocument() throws {
        openMHCAndWaitForItsViewer(mhcBundle)
        let first = try XCTUnwrap(viewer.mhcReferenceBundleViewController)

        controller.displayContent(for: item(secondMHCBundle))
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) {
                self.viewer.mhcReferenceBundleViewController.map { $0 !== first } ?? false
            },
            "the second MHC bundle never replaced the first"
        )

        XCTAssertEqual(viewer.children.filter { $0 is NSHostingController<MHCReferenceBundleViewport> }.count, 1)
        XCTAssertEqual(
            summary.mhcReferenceBundleDocument?.bundleURL?.standardizedFileURL,
            secondMHCBundle.standardizedFileURL
        )
    }

    // MARK: - Helpers

    private var viewer: ViewerViewController { controller.viewerController }

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    private func openMHCAndWaitForItsViewer(_ bundle: URL, file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: item(bundle))
        let shown = waitUntilOnRunLoop(budget: .lookup) { self.viewer.mhcReferenceBundleViewController != nil }
        XCTAssertTrue(shown, "the MHC viewer never opened", file: file, line: line)
    }

    private func item(_ url: URL) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: .mhcReferenceBundle, url: url)
    }
}
