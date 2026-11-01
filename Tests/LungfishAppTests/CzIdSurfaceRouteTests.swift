// CzIdSurfaceRouteTests.swift - The CZ-ID result opens through the surface host (Phase 3.1 lane CZID)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The CZ-ID viewer now opens through the surface host. A show that does not install, and a result whose files cannot
// be read, say what did not open and what to try, with no internal kind id and no raw error text (NAOMGS-ARCH carry
// item 3, the 21:4x ALERT-C5 addition). View > Show Drawer reaches the Collections drawer of the embedded taxonomy
// view through the host (carry item 9), and the root the host installs is an accessibility group the smoke can find
// (the 19:5x ROBOTS addition).
//
// Each test opens a CZ-ID result as the sidebar does (`displayContent(for:)`), a bundle converted from the committed
// taxon report. As in `Kraken2SurfaceRouteTests`, the test methods are synchronous and wait by turning the main run
// loop.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxonomyUI

/// A surface whose load always fails, so the CZ-ID show never installs.
@MainActor
private final class RefusingCzIdSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.czId) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class CzIdSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var czId: URL!
    private var secondCzId: URL!

    /// The embedded taxonomy view may save its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?
    /// The drawer's open state and height go to this suite, never the standard defaults.
    private var drawerDefaults: TestDefaultsSuite?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "czid-surface-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        let suite = TestDefaultsSuite(prefix: "CzIdSurfaceRouteTests")
        drawerDefaults = suite
        TaxaCollectionsDrawerSeams.defaults = suite.defaults
        let imports = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        czId = try RoutingSafetyNetFixtures.czIdResult(named: "cornea-czid.lungfishtax", in: imports)
        secondCzId = try RoutingSafetyNetFixtures.czIdResult(named: "cornea-czid-2.lungfishtax", in: imports)
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
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.contentViewController = nil
        window = nil
        controller = nil
        TaxaCollectionsDrawerSeams.defaults = .standard
        drawerDefaults = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A CZ-ID viewer that does not open says what happened and what to try, with no internal kind id, and leaves no
    /// CZ-ID child (NAOMGS-ARCH item 3).
    func testACzIdResultThatDoesNotOpenSaysWhatToTry() {
        controller.viewerController.surfaceHost.registry.register(.analysis(.czId)) { RefusingCzIdSurface() }
        controller.displayContent(for: item(czId))

        let viewer = controller.viewerController!
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            viewer.statusBar.positionLabel.stringValue.contains("Unable to open the CZ-ID result.")
        }, "no failure words: \(viewer.statusBar.positionLabel.stringValue)")
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Select it again"), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertFalse(viewer.children.contains { $0 is CzIdResultViewController })
        XCTAssertNil(viewer.installedSurface)
    }

    /// A CZ-ID result whose manifest cannot be read says what did not open and what to try, in the same words, and
    /// opens no alert with the decoder's raw text (the 21:4x addition, ALERT-C5).
    func testACzIdResultWhoseFilesCannotBeReadSaysWhatToTry() throws {
        try Data("{".utf8).write(to: czId.appendingPathComponent("cz-id-manifest.json"))
        controller.displayContent(for: item(czId))

        let viewer = controller.viewerController!
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            viewer.statusBar.positionLabel.stringValue.contains("Unable to open the CZ-ID result.")
        }, "no failure words: \(viewer.statusBar.positionLabel.stringValue)")
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("import it again"), words)
        XCTAssertFalse(words.contains("couldn\u{2019}t be read"), "the words are the decoder's raw text: \(words)")
        XCTAssertNil(window.attachedSheet, "a raw-error alert opened")
        XCTAssertFalse(viewer.children.contains { $0 is CzIdResultViewController })
    }

    /// View > Show Drawer and the toolbar button open and close the Collections drawer of the embedded taxonomy view
    /// through the host, which asks the installed surface first (carry item 9).
    func testShowDrawerTogglesTheCzIdDrawerThroughTheHost() throws {
        let shown = try openCzId(czId)
        let viewer = controller.viewerController!
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .analysis(.czId), "the CZ-ID viewer is not on the host")
        XCTAssertFalse(viewer.isActiveDrawerOpen)

        viewer.toggleAnnotationDrawer()
        XCTAssertEqual(viewer.installedSurface?.isDrawerOpen, true, "the host's surface must answer for the drawer")
        XCTAssertTrue(viewer.isActiveDrawerOpen)
        XCTAssertEqual(shown.taxonomyViewControllerForTesting?.isTaxaCollectionsDrawerOpen, true)

        viewer.toggleAnnotationDrawer()
        XCTAssertEqual(viewer.installedSurface?.isDrawerOpen, false)
        XCTAssertFalse(viewer.isActiveDrawerOpen)
        XCTAssertEqual(shown.taxonomyViewControllerForTesting?.isTaxaCollectionsDrawerOpen, false)
    }

    /// The view switch smoke finds the CZ-ID viewer by `czid-result-view`. AppKit leaves a plain NSView out of the
    /// accessibility tree whatever identifier it carries, so the root the host installs, the view that carries the
    /// identifier, must be an element (3.1 lane ROBOTS).
    func testTheInstalledCzIdRootIsAnAccessibilityGroupTheSmokeCanFind() throws {
        _ = try openCzId(czId)
        let root = controller.viewerController.installedSurface?.viewController.view
        XCTAssertEqual(root?.accessibilityIdentifier(), "czid-result-view")
        XCTAssertEqual(root?.isAccessibilityElement(), true, "a plain NSView root is left out of the accessibility tree")
        XCTAssertEqual(root?.accessibilityRole(), .group)
    }

    // MARK: - Pins

    /// A second CZ-ID result replaces the first: one viewer, a new one (no skip and no flag).
    func testASecondCzIdResultReplacesTheFirst() throws {
        let first = try openCzId(czId)
        controller.displayContent(for: item(secondCzId))
        let viewer = controller.viewerController!
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            viewer.children.contains { $0 is CzIdResultViewController && $0 !== first }
        }, "the second CZ-ID result never opened")
        XCTAssertEqual(viewer.children.filter { $0 is CzIdResultViewController }.count, 1)
    }

    /// The hide that other routes call takes the CZ-ID viewer out and brings the genomics viewer back.
    func testHidingTheCzIdViewerBringsBackTheGenomicsViewer() throws {
        _ = try openCzId(czId)
        let viewer = controller.viewerController!
        XCTAssertTrue(viewer.viewerView.isHidden)

        viewer.hideCzIdView()

        XCTAssertFalse(viewer.children.contains { $0 is CzIdResultViewController })
        XCTAssertNil(viewer.installedSurface)
        XCTAssertFalse(viewer.viewerView.isHidden)
        XCTAssertFalse(viewer.headerView.isHidden)
    }

    // MARK: - Helpers

    /// Opens a CZ-ID result as the sidebar does and returns the viewer it shows.
    private func openCzId(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> CzIdResultViewController {
        controller.displayContent(for: item(url))
        let viewer = controller.viewerController!
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            viewer.children.contains { $0 is CzIdResultViewController }
        }, "the CZ-ID result is shown", file: file, line: line)
        return try XCTUnwrap(
            viewer.children.compactMap { $0 as? CzIdResultViewController }.first, file: file, line: line
        )
    }

    private func item(_ url: URL) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: .czIdResult, url: url)
    }
}
