// TransientViewportOverlayClearingTests.swift - Stale viewport overlay/content clearing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reproduced in the GUI (2026-08-23): a TaxTriage "Database build failed"
// overlay stayed visible in the center pane after the user selected a DIFFERENT
// analysis (an EsViritu batch) in the sidebar. The overlay was added as a raw
// subview of the viewer's view, so ViewerViewController.clearViewport() — which
// only hides the child viewports it knows about — never removed it.
//
// The same class of bug covers bundle-hosted child viewports (12S amplicon,
// genotype, MHC reference bundle) that clearViewport() did not hide, leaving a
// debounced-away or deleted bundle rendered in the viewport.

import XCTest
import AppKit
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishGenotypeUI
@testable import LungfishTwelveSUI

@MainActor
final class TransientViewportOverlayClearingTests: XCTestCase {

    private func makeController() -> (MainSplitViewController, NSWindow) {
        let controller = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func attachOverlay(to controller: MainSplitViewController) -> NSView {
        let overlay = DatabaseBuildPlaceholderView()
        overlay.showError("Build failed: boom")
        let contentView = controller.viewerController.view
        contentView.addSubview(overlay)
        controller.registerTransientViewportOverlay(overlay)
        return overlay
    }

    // MARK: - Selection change clears the overlay

    func testOverlayIsClearedWhenADifferentItemIsDisplayed() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let overlay = attachOverlay(to: controller)
        XCTAssertNotNil(overlay.superview)
        XCTAssertEqual(controller.attachedTransientViewportOverlayCount, 1)

        // Selecting a different analysis begins a new display request.
        controller.beginDisplayRequest(
            identity: controller.contentSelectionIdentity(
                url: URL(fileURLWithPath: "/tmp/esviritu-batch-2026-08-23"),
                kind: "esvirituResult"
            )
        )

        XCTAssertNil(
            overlay.superview,
            "A stale error overlay must not survive a change of displayed content"
        )
        XCTAssertEqual(controller.attachedTransientViewportOverlayCount, 0)
    }

    func testOverlayIsClearedWhenSelectionIsCleared() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let overlay = attachOverlay(to: controller)
        XCTAssertNotNil(overlay.superview)

        controller.invalidateDisplayRequest()

        XCTAssertNil(
            overlay.superview,
            "Clearing the selection must tear down transient viewport overlays"
        )
    }

    func testOverlaySurvivesRedisplayOfTheSameIdentity() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let identity = controller.contentSelectionIdentity(
            url: URL(fileURLWithPath: "/tmp/taxtriage-batch-2026-08-23"),
            kind: "databaseBuild:taxtriage"
        )
        controller.beginDisplayRequest(identity: identity)
        let overlay = attachOverlay(to: controller)

        // Re-entering the same display request (e.g. the placeholder's own
        // retry) must not tear down the overlay it just installed.
        controller.beginDisplayRequest(identity: identity)

        XCTAssertNotNil(
            overlay.superview,
            "Re-displaying the same content must not remove its own overlay"
        )
    }

    func testClearTransientViewportStateIsIdempotent() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let overlay = attachOverlay(to: controller)
        controller.clearTransientViewportState()
        controller.clearTransientViewportState()

        XCTAssertNil(overlay.superview)
        XCTAssertEqual(controller.attachedTransientViewportOverlayCount, 0)
    }

    // MARK: - Deletion of the displayed item

    func testDisplayedContentWasRemovedFromDiskTracksTheBackingFile() throws {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        controller.beginDisplayRequest(
            identity: controller.contentSelectionIdentity(url: directory, kind: "taxTriageResult")
        )
        XCTAssertFalse(
            controller.displayedContentWasRemovedFromDisk,
            "An item that still exists is not a deletion"
        )

        try FileManager.default.removeItem(at: directory)

        XCTAssertTrue(
            controller.displayedContentWasRemovedFromDisk,
            "A deleted displayed item must be recognised so the viewport can be blanked"
        )
    }

    func testNoActiveSelectionIsNotTreatedAsRemoval() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.invalidateDisplayRequest()

        XCTAssertFalse(controller.displayedContentWasRemovedFromDisk)
    }

    // MARK: - Sidebar deletion detection

    func testAllSelectionURLsRemovedFromDiskDetectsRealDeletion() throws {
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-exists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertTrue(SidebarViewController.allSelectionURLsRemovedFromDisk([missing]))
        XCTAssertFalse(SidebarViewController.allSelectionURLsRemovedFromDisk([existing]))
        XCTAssertFalse(
            SidebarViewController.allSelectionURLsRemovedFromDisk([existing, missing]),
            "Transient churn on part of a multi-selection must not count as a deletion"
        )
        XCTAssertFalse(
            SidebarViewController.allSelectionURLsRemovedFromDisk([]),
            "An empty prior selection is not a deletion"
        )
    }

    // MARK: - clearViewport covers every child viewport

    func testClearViewportTearsDownTheTwelveSAmpliconBundleViewport() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let viewer: ViewerViewController = controller.viewerController
        let child = TwelveSAmpliconResultViewController()
        viewer.addChild(child)
        viewer.view.addSubview(child.view)
        viewer.twelveSAmpliconResultViewController = child

        viewer.clearViewport(statusMessage: "No sequence selected")

        XCTAssertNil(
            viewer.twelveSAmpliconResultViewController,
            "clearViewport must hide the 12S amplicon bundle viewport, or a debounced-away bundle stays on screen"
        )
        XCTAssertNil(child.view.superview)
    }

    func testClearViewportTearsDownTheGenotypeBundleViewport() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let viewer: ViewerViewController = controller.viewerController
        let child = GenotypeResultViewController()
        viewer.addChild(child)
        viewer.view.addSubview(child.view)
        viewer.genotypeResultViewController = child

        viewer.clearViewport(statusMessage: "No sequence selected")

        XCTAssertNil(
            viewer.genotypeResultViewController,
            "clearViewport must hide the genotype bundle viewport"
        )
        XCTAssertNil(child.view.superview)
    }

    func testClearViewportLeavesNoChildViewportBehind() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let viewer: ViewerViewController = controller.viewerController
        viewer.twelveSAmpliconResultViewController = {
            let child = TwelveSAmpliconResultViewController()
            viewer.addChild(child)
            viewer.view.addSubview(child.view)
            return child
        }()
        viewer.genotypeResultViewController = {
            let child = GenotypeResultViewController()
            viewer.addChild(child)
            viewer.view.addSubview(child.view)
            return child
        }()

        viewer.clearViewport(statusMessage: "No sequence selected")

        XCTAssertNil(viewer.taxTriageViewController)
        XCTAssertNil(viewer.esVirituViewController)
        XCTAssertNil(viewer.taxonomyViewController)
        XCTAssertNil(viewer.assemblyResultController)
        XCTAssertNil(viewer.activeMappingViewportController)
        XCTAssertNil(viewer.twelveSAmpliconResultViewController)
        XCTAssertNil(viewer.genotypeResultViewController)
        XCTAssertNil(viewer.mhcReferenceBundleViewController)
    }
}
