// MHCReferenceBundleSurfaceTests.swift - The MHC reference viewer as a ViewportHost surface (Phase 3.2 lane MHC)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

@MainActor
final class MHCReferenceBundleSurfaceTests: XCTestCase {
    private let kind = SurfaceKind.bundle(.mhcReference)

    /// The load adopts the controller the display built, and the host installs it before `show` returns.
    func testTheHostInstallsTheAdoptedControllerBeforeShowReturns() throws {
        let (host, parent) = makeHost()
        let controller = makeController()

        host.show(kind: kind, input: controller)

        let surface = try XCTUnwrap(host.activeViewport as? MHCReferenceBundleSurface)
        XCTAssertEqual(surface.surfaceKind, kind)
        XCTAssertTrue(surface.controller === controller)
        XCTAssertTrue(surface.viewController === controller)
        XCTAssertTrue(controller.parent === parent)
        XCTAssertTrue(controller.view.superview === parent.view)
        XCTAssertFalse(surface.isDrawerOpen, "the MHC viewer has no drawer")
    }

    /// A second show and a clear each remove the viewer before it, and nothing stays installed.
    func testEveryRemovalLeavesNoViewerBehind() throws {
        let (host, parent) = makeHost()
        let first = makeController()
        host.show(kind: kind, input: first)

        host.show(kind: kind, input: makeController())
        XCTAssertNil(first.parent, "a second MHC bundle left the first viewer installed")
        XCTAssertEqual(parent.children.count, 1)

        host.clear()
        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty, "the host holds its parent weakly, so the test keeps it")
    }

    /// An input of another type is refused with words, and nothing is installed.
    func testAnInputOfAnotherTypeIsRefused() {
        let (host, parent) = makeHost()

        host.show(kind: kind, input: "not a controller")

        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty)
        guard case .failed(let error) = host.lastOutcome else {
            return XCTFail("the show of a wrong input must fail, got \(String(describing: host.lastOutcome))")
        }
        XCTAssertEqual(
            error as? SurfaceError,
            .unexpectedInput(kind: kind, expected: "NSHostingController<MHCReferenceBundleViewport>")
        )
    }

    // MARK: - Helpers

    private func makeController() -> NSHostingController<MHCReferenceBundleViewport> {
        let model = MHCReferenceBundleViewportModel(
            bundleURL: URL(fileURLWithPath: "/nonexistent/Surface.lungfishmhcref"),
            title: "Surface test",
            fastaText: ">M1\nACGT\n",
            isFastaPreviewTruncated: false,
            fastaFileSize: 9,
            referenceCount: 1,
            definitionSummaries: [],
            embeddedReferenceBundleURL: nil,
            embeddedReferenceManifest: nil,
            warnings: []
        )
        return NSHostingController(rootView: MHCReferenceBundleViewport(model: model, onEditHaplotypes: {}))
    }

    private func makeHost() -> (ViewportHost, NSViewController) {
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let registry = SurfaceRegistry()
        registry.register(kind) { MHCReferenceBundleSurface() }
        let host = ViewportHost(registry: registry, containerView: parent.view, parentController: parent)
        return (host, parent)
    }
}
