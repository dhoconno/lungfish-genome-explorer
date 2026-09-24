import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class AnnotationDrawerSizingTests: XCTestCase {
    func testSizingAllowsDrawerToCollapseToItsDivider() {
        XCTAssertEqual(
            AnnotationDrawerSizing.clampedHeight(proposed: -100, availableContentHeight: 920),
            AnnotationDrawerSizing.dividerHeight
        )
    }

    func testSizingLeavesAReachableDividerForTheViewerAtMaximumHeight() {
        XCTAssertEqual(
            AnnotationDrawerSizing.clampedHeight(proposed: 1_000, availableContentHeight: 920),
            912
        )
    }

    func testDrawerChromeCompressesWithoutShrinkingTheDivider() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        let drawer = AnnotationTableDrawerView()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(drawer)
        NSLayoutConstraint.activate([
            drawer.topAnchor.constraint(equalTo: host.topAnchor),
            drawer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            drawer.heightAnchor.constraint(equalToConstant: AnnotationDrawerSizing.dividerHeight),
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(drawer.dragHandle.frame.height, AnnotationDrawerSizing.dividerHeight)
        XCTAssertEqual(drawer.dragHandle.frame.maxY, drawer.bounds.maxY, accuracy: 0.5)
    }

    func testDividerAdvertisesSplitterRoleAndDragInstructions() {
        let divider = DrawerDividerView()

        XCTAssertTrue(divider.isAccessibilityElement())
        XCTAssertEqual(divider.accessibilityRole(), .splitter)
        XCTAssertEqual(divider.accessibilityHelp(), "Drag vertically to resize the annotation table drawer.")
    }

    func testViewerLayoutReclampsDrawerWhenEnclosingPaneShrinks() {
        let viewer = ViewerViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 96),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewer
        window.setContentSize(NSSize(width: 800, height: 96))
        window.contentView?.layoutSubtreeIfNeeded()

        let heightConstraint = viewer.view.heightAnchor.constraint(equalToConstant: 500)
        viewer.annotationDrawerView = AnnotationTableDrawerView()
        viewer.annotationDrawerHeightConstraint = heightConstraint
        viewer.isAnnotationDrawerOpen = true

        viewer.viewDidLayout()

        XCTAssertEqual(heightConstraint.constant, AnnotationDrawerSizing.dividerHeight,
                       "view=\(viewer.view.bounds), ruler=\(viewer.enhancedRulerView.bounds.height), gene=\(viewer.geneTabBarView.bounds.height), status=\(viewer.statusBar.bounds.height), safe=\(viewer.view.safeAreaInsets.top)")
    }

    func testUnattachedViewerKeepsPersistedDrawerHeightUntilGeometryIsAvailable() {
        let viewer = ViewerViewController()
        _ = viewer.view
        let heightConstraint = viewer.view.heightAnchor.constraint(equalToConstant: 250)
        viewer.annotationDrawerView = AnnotationTableDrawerView()
        viewer.annotationDrawerHeightConstraint = heightConstraint

        viewer.viewDidLayout()

        XCTAssertEqual(heightConstraint.constant, 250)
    }

    func testOpeningOversizedPersistedDrawerKeepsItsBottomEdgeVisible() throws {
        // UserDefaults.standard resolves to the app's real bundle identity
        // (com.lungfish.browser) inside `xctest`, so a test must never write
        // through it (TST-10). Use a suite-specific instance instead, injected
        // via ViewerViewController.annotationDrawerDefaults, and remove that
        // suite's persistent domain in teardown rather than mutating a saved
        // real-world value.
        let suiteName = "lungfish-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let key = "annotationDrawerHeight"
        defaults.set(10_000.0, forKey: key)
        XCTAssertEqual(defaults.double(forKey: key), 10_000.0)

        let viewer = ViewerViewController()
        viewer.annotationDrawerDefaults = defaults
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewer
        window.setContentSize(NSSize(width: 800, height: 300))
        window.contentView?.layoutSubtreeIfNeeded()

        viewer.toggleAnnotationDrawer()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        viewer.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(viewer.isAnnotationDrawerOpen)
        XCTAssertEqual(try XCTUnwrap(viewer.annotationDrawerBottomConstraint).constant, 0)
        XCTAssertLessThan(try XCTUnwrap(viewer.annotationDrawerHeightConstraint).constant, 10_000)
    }
}
