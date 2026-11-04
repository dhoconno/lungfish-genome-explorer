// ViewportHostTopPinTests.swift - Where the host pins a surface's top (Phase 3.2 lane VCF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit

/// A surface with no load, whose only question is where its top goes.
@MainActor
private final class TopPinSurface: ResultViewport {
    let controller = NSViewController()
    let asksForSafeArea: Bool

    init(asksForSafeArea: Bool) {
        self.asksForSafeArea = asksForSafeArea
        controller.view = NSView()
    }

    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .view(.vcfDataset) }
    var pinsTopToSafeArea: Bool { asksForSafeArea }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {}
}

@MainActor
final class ViewportHostTopPinTests: XCTestCase {
    /// The container has a 40 point safe area at its top, as a window's toolbar gives the viewer. A surface that asks
    /// starts below it, and one that does not starts at the container's edge.
    func testASurfaceThatAsksForTheSafeAreaStartsBelowItAndOthersAtTheEdge() throws {
        let parent = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.additionalSafeAreaInsets = NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0)
        parent.view = container
        var asks = true
        let registry = SurfaceRegistry()
        registry.register(.view(.vcfDataset)) { TopPinSurface(asksForSafeArea: asks) }
        let host = ViewportHost(registry: registry, containerView: container, parentController: parent)

        host.show(kind: .view(.vcfDataset), input: ())
        container.layoutSubtreeIfNeeded()
        let below = try XCTUnwrap(host.activeViewport, "a load that does not suspend is installed before show returns")
        XCTAssertEqual(below.viewController.view.frame.maxY, 260, accuracy: 0.5, "the surface starts under the safe area")

        asks = false
        host.show(kind: .view(.vcfDataset), input: ())
        container.layoutSubtreeIfNeeded()
        let edge = try XCTUnwrap(host.activeViewport)
        XCTAssertEqual(edge.viewController.view.frame.maxY, 300, accuracy: 0.5, "a surface that did not ask left the edge")
    }
}
