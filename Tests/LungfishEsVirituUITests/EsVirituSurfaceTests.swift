// EsVirituSurfaceTests.swift - The EsViritu result viewer as a ViewportHost surface (Phase 3.1 lane ESV)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishKit
@testable import LungfishEsVirituUI

@MainActor
final class EsVirituSurfaceTests: XCTestCase {
    private let kind = SurfaceKind.analysis(.esviritu)

    /// The load adopts the controller the App made and configured, and the host installs it before `show` returns
    /// (NAOMGS-ARCH carry item 1).
    func testTheHostInstallsTheAdoptedControllerBeforeShowReturns() throws {
        let (host, parent) = makeHost()
        let controller = EsVirituResultViewController()

        host.show(kind: kind, input: controller)

        let surface = try XCTUnwrap(host.activeViewport as? EsVirituSurface)
        XCTAssertEqual(surface.surfaceKind, kind)
        XCTAssertTrue(surface.controller === controller)
        XCTAssertTrue(surface.viewController === controller)
        XCTAssertTrue(controller.parent === parent)
        XCTAssertTrue(controller.view.superview === parent.view)
    }

    /// The reset runs on every removal, another EsViritu result's show and a clear alike, since the App gives the
    /// new result's block only after its show (NAOMGS-ARCH carry item 2, no skip).
    func testEveryRemovalRunsTheResetItsOwnKindIncluded() throws {
        let (host, parent) = makeHost()
        var resets: [String] = []
        host.show(kind: kind, input: EsVirituResultViewController())
        try XCTUnwrap(host.activeViewport as? EsVirituSurface).onWillDeactivate = { resets.append("first") }

        host.show(kind: kind, input: EsVirituResultViewController())
        XCTAssertEqual(resets, ["first"], "an EsViritu result replaced by another runs its reset")
        try XCTUnwrap(host.activeViewport as? EsVirituSurface).onWillDeactivate = { resets.append("second") }

        host.clear()
        XCTAssertEqual(resets, ["first", "second"])
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
        XCTAssertEqual(error as? SurfaceError, .unexpectedInput(kind: kind, expected: "EsVirituResultViewController"))
    }

    private func makeHost() -> (ViewportHost, NSViewController) {
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let registry = SurfaceRegistry()
        registry.register(kind, factory: EsVirituSurface.factory())
        let host = ViewportHost(registry: registry, containerView: parent.view, parentController: parent)
        return (host, parent)
    }
}
