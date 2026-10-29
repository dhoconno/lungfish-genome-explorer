// SurfaceRegistrationStubTests.swift - A surface registered from a test target opens in the viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Exit check 4 of Phase 3.1. The stub surface and its bundle kind below exist only in
// this test target. Registering the kind on the viewer's surface host is the one line
// it takes, and the viewer then shows it through the path every host surface takes,
// with no App line naming the stub.

import XCTest
import AppKit
@testable import LungfishApp
import LungfishIO
import LungfishKit

/// A bundle kind that no App file names.
private let stubKind = SurfaceKind.bundle(BundleKindID(rawValue: "test-stub-surface"))

@MainActor
final class SurfaceRegistrationStubTests: XCTestCase {
    func testAStubSurfaceRegisteredFromATestTargetOpensAsTheViewersOneChild() throws {
        let viewer = makeViewer()
        XCTAssertFalse(viewer.surfaceHost.registry.isRegistered(stubKind))
        viewer.surfaceHost.registry.register(stubKind) { StubSurface() }

        let stub = try viewer.showSurface(stubKind, input: StubSurface.Input(title: "Stub result"), as: StubSurface.self)

        XCTAssertTrue(viewer.surfaceHost.activeViewport === stub)
        XCTAssertEqual(stub.controller.shownTitle, "Stub result")
        XCTAssertEqual(viewer.children.filter { $0 === stub.controller }.count, 1)
        XCTAssertTrue(stub.controller.view.superview === viewer.view)
        XCTAssertTrue(viewer.viewerView.isHidden, "The genomics viewer hides under the surface")
        XCTAssertTrue(viewer.isNativeBundleViewportInstalled)

        viewer.clearSurface(ifShowing: stubKind)
        XCTAssertNil(viewer.surfaceHost.activeViewport)
        XCTAssertNil(stub.controller.parent)
        XCTAssertNil(stub.controller.view.superview)
        XCTAssertFalse(viewer.viewerView.isHidden, "The genomics viewer comes back when the surface leaves")
        XCTAssertEqual(stub.deactivations, 1)
    }

    func testTheWindowDrawerReadsTheInstalledSurfacesDrawer() throws {
        let viewer = makeViewer()
        viewer.surfaceHost.registry.register(stubKind) { StubSurface() }
        let stub = try viewer.showSurface(stubKind, input: StubSurface.Input(title: "Stub result"), as: StubSurface.self)
        XCTAssertFalse(viewer.isActiveDrawerOpen)

        viewer.toggleAnnotationDrawer()
        XCTAssertTrue(stub.isDrawerOpen, "View > Show Drawer and the toolbar button toggle the installed surface's drawer")
        XCTAssertTrue(viewer.isActiveDrawerOpen, "View > Show Drawer and the toolbar button read the installed surface's drawer")

        viewer.clearSurface(ifShowing: stubKind)
        XCTAssertFalse(viewer.isActiveDrawerOpen)
    }

    func testAnotherHostKindReplacesTheStubSurface() throws {
        let viewer = makeViewer()
        viewer.surfaceHost.registry.register(stubKind) { StubSurface() }
        let stub = try viewer.showSurface(stubKind, input: StubSurface.Input(title: "Stub result"), as: StubSurface.self)

        try viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))

        XCTAssertTrue(viewer.primerAnalysisViewController is PrimerAnalysisHostingController)
        XCTAssertNil(stub.controller.parent)
        XCTAssertEqual(stub.deactivations, 1)
        XCTAssertEqual(viewer.children.filter { $0 is PrimerAnalysisHostingController || $0 === stub.controller }.count, 1)
        viewer.clearViewport()
        XCTAssertNil(viewer.surfaceHost.activeViewport)
    }

    func testAShowOfAKindThatIsNotRegisteredThrowsWordsAndLeavesTheGenomicsViewer() {
        let viewer = makeViewer()
        XCTAssertThrowsError(
            try viewer.showSurface(stubKind, input: StubSurface.Input(title: "Stub result"), as: StubSurface.self)
        ) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertNil(viewer.surfaceHost.activeViewport)
        XCTAssertFalse(viewer.viewerView.isHidden)
    }

    private func makeViewer() -> ViewerViewController {
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        return viewer
    }
}

/// A surface that shows a bare view with the title it was given and has a drawer of its own.
@MainActor
private final class StubSurface: ResultViewport {
    struct Input {
        let title: String
    }

    final class Controller: NSViewController {
        var shownTitle: String?

        override func loadView() {
            view = NSView()
        }
    }

    let controller = Controller()
    private(set) var deactivations = 0
    private var drawerOpen = false

    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { stubKind }
    var isDrawerOpen: Bool { drawerOpen }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        controller.shownTitle = try expectInput(input, as: Input.self).title
    }

    func toggleDrawer() {
        drawerOpen.toggle()
    }

    func willDeactivate() {
        deactivations += 1
    }
}
