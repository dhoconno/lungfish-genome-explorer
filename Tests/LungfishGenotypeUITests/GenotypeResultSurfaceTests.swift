// GenotypeResultSurfaceTests.swift - The genotype result viewer as a ViewportHost surface (Phase 3.2 lane GENO)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeResultSurfaceTests: XCTestCase {
    private let kind = SurfaceKind.bundle(.genotypeResult)

    /// The load adopts the controller the App made, and the host installs it before `show` returns.
    func testTheHostInstallsTheAdoptedControllerBeforeShowReturns() throws {
        let (host, parent) = makeHost()
        let controller = GenotypeResultViewController()

        host.show(kind: kind, input: controller)

        let surface = try XCTUnwrap(host.activeViewport as? GenotypeResultSurface)
        XCTAssertEqual(surface.surfaceKind, kind)
        XCTAssertTrue(surface.controller === controller)
        XCTAssertTrue(surface.viewController === controller)
        XCTAssertTrue(controller.parent === parent)
        XCTAssertTrue(controller.view.superview === parent.view)
    }

    /// The removal's work runs on every removal, another genotype result's show and a clear alike, and the App's
    /// callback sees the controller with its own callbacks still attached.
    func testEveryRemovalRunsTheWorkItsOwnKindIncluded() throws {
        let (host, parent) = makeHost()
        var removed: [GenotypeResultViewController] = []
        var attachedAtCallback: [Bool] = []
        func watch(_ surface: GenotypeResultSurface) {
            surface.onWillDeactivate = {
                removed.append($0)
                attachedAtCallback.append($0.onSelectionStateChanged != nil)
            }
        }
        let first = GenotypeResultViewController()
        first.onSelectionStateChanged = { _ in }
        host.show(kind: kind, input: first)
        watch(try XCTUnwrap(host.activeViewport as? GenotypeResultSurface))

        let second = GenotypeResultViewController()
        second.onSelectionStateChanged = { _ in }
        host.show(kind: kind, input: second)
        XCTAssertEqual(removed, [first], "a genotype result replaced by another runs the work")
        XCTAssertNil(first.onSelectionStateChanged, "the replaced viewer's callbacks are cut")
        XCTAssertNotNil(second.onSelectionStateChanged)
        watch(try XCTUnwrap(host.activeViewport as? GenotypeResultSurface))

        host.clear()
        XCTAssertEqual(removed, [first, second])
        XCTAssertEqual(attachedAtCallback, [true, true], "the App's callback runs before the callbacks are cut")
        XCTAssertNil(second.onSelectionStateChanged)
        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty, "the host holds its parent weakly, so the test keeps it")
    }

    /// An input of another type is refused with words, and nothing is installed.
    func testAnInputOfAnotherTypeIsRefused() async {
        let (host, parent) = makeHost()

        let outcome = await host.show(kind: kind, input: "a string").value

        guard case .failed(let error) = outcome else {
            return XCTFail("the host installed a surface for the wrong input: \(outcome)")
        }
        XCTAssertNotNil((error as? any LocalizedError)?.errorDescription)
        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty)
    }

    private func makeHost() -> (ViewportHost, NSViewController) {
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let registry = SurfaceRegistry()
        registry.register(kind, factory: GenotypeResultSurface.factory())
        addTeardownBlock { _ = parent }
        return (ViewportHost(registry: registry, containerView: parent.view, parentController: parent), parent)
    }
}
