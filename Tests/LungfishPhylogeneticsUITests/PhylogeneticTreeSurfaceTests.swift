// PhylogeneticTreeSurfaceTests.swift - The tree viewer as a ViewportHost surface (Phase 3.2 lane PHYLO)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishPhylogeneticsUI

@MainActor
final class PhylogeneticTreeSurfaceTests: XCTestCase {
    private let kind = SurfaceKind.bundle(.phylogeneticTree)
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "PhyloSurface")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// The load builds the viewer from the bundle's URL, and the host installs it before `show` returns.
    func testTheHostInstallsTheTreeBeforeShowReturns() throws {
        let (host, parent) = makeHost()
        let bundle = try makeTreeBundle(named: "one")

        host.show(kind: kind, input: bundle)

        let surface = try XCTUnwrap(host.activeViewport as? PhylogeneticTreeSurface)
        let controller = try XCTUnwrap(surface.controller)
        XCTAssertEqual(surface.surfaceKind, kind)
        XCTAssertEqual(controller.bundleURL, bundle)
        XCTAssertTrue(surface.viewController === controller)
        XCTAssertTrue(controller.parent === parent)
        XCTAssertTrue(controller.view.superview === parent.view)
    }

    /// A bundle that does not read fails the show with the file's own error, and nothing is installed.
    func testABundleThatDoesNotReadFailsWithTheFilesOwnError() throws {
        let (host, parent) = makeHost()
        let bundle = try makeTreeBundle(named: "damaged")
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("manifest.json"))

        host.show(kind: kind, input: bundle)

        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty)
        guard case .failed(let error) = host.lastOutcome else {
            return XCTFail("the show of a damaged bundle must fail, got \(String(describing: host.lastOutcome))")
        }
        XCTAssertEqual(error as? PhylogeneticTreeBundleError, .missingBundleFile("manifest.json"))
    }

    /// The removal cuts both callbacks and runs the hook on every removal, another tree's show and a clear alike, since
    /// the App gives the new tree's blocks only after its show. The test keeps the controller the host let go, since
    /// the question is what a controller that something else still holds can reach.
    func testEveryRemovalCutsTheCallbacksAndRunsTheHookItsOwnKindIncluded() throws {
        let (host, parent) = makeHost()
        var hooks: [String] = []
        host.show(kind: kind, input: try makeTreeBundle(named: "first"))
        let firstSurface = try XCTUnwrap(host.activeViewport as? PhylogeneticTreeSurface)
        let first = try XCTUnwrap(firstSurface.controller)
        first.onSelectionStateChanged = { _ in }
        first.onTreeBundleOperationRequested = { _ in }
        firstSurface.onWillDeactivate = { hooks.append("first") }

        host.show(kind: kind, input: try makeTreeBundle(named: "second"))

        XCTAssertEqual(hooks, ["first"], "a tree replaced by another runs its hook")
        XCTAssertNil(first.onSelectionStateChanged, "the replaced tree kept its selection callback")
        XCTAssertNil(first.onTreeBundleOperationRequested, "the replaced tree kept its operation callback")
        let secondSurface = try XCTUnwrap(host.activeViewport as? PhylogeneticTreeSurface)
        let second = try XCTUnwrap(secondSurface.controller)
        second.onSelectionStateChanged = { _ in }
        second.onTreeBundleOperationRequested = { _ in }
        secondSurface.onWillDeactivate = { hooks.append("second") }

        host.clear()

        XCTAssertEqual(hooks, ["first", "second"])
        XCTAssertNil(second.onSelectionStateChanged)
        XCTAssertNil(second.onTreeBundleOperationRequested)
        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty, "the host holds its parent weakly, so the test keeps it")
    }

    /// An input of another type is refused with words, and nothing is installed.
    func testAnInputOfAnotherTypeIsRefused() {
        let (host, parent) = makeHost()

        host.show(kind: kind, input: "not a bundle URL")

        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty)
        guard case .failed(let error) = host.lastOutcome else {
            return XCTFail("the show of a wrong input must fail, got \(String(describing: host.lastOutcome))")
        }
        XCTAssertEqual(error as? SurfaceError, .unexpectedInput(kind: kind, expected: "URL"))
    }

    private func makeHost() -> (ViewportHost, NSViewController) {
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let registry = SurfaceRegistry()
        registry.register(kind, factory: PhylogeneticTreeSurface.factory())
        let host = ViewportHost(registry: registry, containerView: parent.view, parentController: parent)
        return (host, parent)
    }

    /// A small tree bundle, made by the same importer a person's import runs.
    private func makeTreeBundle(named name: String) throws -> URL {
        let source = root.appendingPathComponent("\(name).nwk")
        try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(to: source, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("\(name).lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: source, to: bundle)
        return bundle
    }
}
