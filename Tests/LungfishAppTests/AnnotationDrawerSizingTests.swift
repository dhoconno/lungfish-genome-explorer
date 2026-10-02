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
        XCTAssertEqual(divider.accessibilityHelp(), "Drag vertically, or press the Up and Down Arrow keys, to resize the annotation table drawer.")
        XCTAssertTrue(divider.acceptsFirstResponder, "the divider takes keyboard focus so the arrow keys can resize the drawer")
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
        // through it. Use a suite-specific instance instead, injected
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
        // The bottom-constraint's animator sets its model value to the target
        // immediately; only the visual layer interpolates. But under heavy
        // parallel-test CPU contention the runloop pump backing the 0.25s
        // NSAnimationContext can itself stall well past a short fixed sleep
        // (wall-clock budgets under load), so poll for the settled
        // value instead of trusting a single fixed-duration wait.
        let bottomConstraint = try XCTUnwrap(viewer.annotationDrawerBottomConstraint)
        let deadline = Date().addingTimeInterval(10)
        while bottomConstraint.constant != 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            viewer.view.layoutSubtreeIfNeeded()
        }

        XCTAssertTrue(viewer.isAnnotationDrawerOpen)
        XCTAssertEqual(bottomConstraint.constant, 0)
        XCTAssertLessThan(try XCTUnwrap(viewer.annotationDrawerHeightConstraint).constant, 10_000)
    }

    // MARK: - Default height and keyboard resizing (2026-10-01)

    func testTooShortOrMissingSavedHeightOpensAtTheDefault() {
        XCTAssertEqual(AnnotationDrawerSizing.restoredHeight(persisted: 0), AnnotationDrawerSizing.defaultHeight)
        XCTAssertEqual(AnnotationDrawerSizing.restoredHeight(persisted: 100), AnnotationDrawerSizing.defaultHeight,
                       "a 100-point drawer showed the Variants filters but no rows")
        XCTAssertEqual(AnnotationDrawerSizing.restoredHeight(persisted: 420), 420)
    }

    private func viewerInWindow(defaults: UserDefaults) -> ViewerViewController {
        let viewer = ViewerViewController()
        viewer.annotationDrawerDefaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [], backing: .buffered, defer: false)
        window.contentViewController = viewer
        window.setContentSize(NSSize(width: 1000, height: 900))
        window.contentView?.layoutSubtreeIfNeeded()
        return viewer
    }

    func testKeyboardAndVoiceOverStepsResizeAndSaveTheDrawer() throws {
        let suiteName = "lungfish-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let viewer = viewerInWindow(defaults: defaults)

        viewer.adjustAnnotationDrawerHeight(by: DrawerDividerView.keyboardStep)
        XCTAssertTrue(viewer.isAnnotationDrawerOpen, "the first step opens a closed drawer")
        let opened = try XCTUnwrap(viewer.annotationDrawerHeightConstraint?.constant)
        XCTAssertEqual(opened, AnnotationDrawerSizing.defaultHeight)

        let handle = try XCTUnwrap(viewer.annotationDrawerView?.dragHandle)
        XCTAssertTrue(handle.accessibilityPerformIncrement())
        XCTAssertEqual(viewer.annotationDrawerHeightConstraint?.constant, opened + DrawerDividerView.keyboardStep)
        XCTAssertEqual(defaults.double(forKey: "annotationDrawerHeight"), Double(opened + DrawerDividerView.keyboardStep))

        XCTAssertTrue(handle.accessibilityPerformDecrement())
        viewer.adjustAnnotationDrawerHeight(by: -DrawerDividerView.keyboardStep)
        XCTAssertEqual(viewer.annotationDrawerHeightConstraint?.constant, opened - DrawerDividerView.keyboardStep)
        XCTAssertEqual(defaults.double(forKey: "annotationDrawerHeight"), Double(opened - DrawerDividerView.keyboardStep))
    }

    func testViewMenuOffersDrawerCommandsWithoutShortcutCollisions() throws {
        _ = NSApplication.shared
        let view = try XCTUnwrap(MainMenu.createMainMenu().items.first { $0.title == "View" }?.submenu)
        let toggle = try XCTUnwrap(view.items.first { $0.action == #selector(ViewMenuActions.toggleAnnotationDrawer(_:)) })
        XCTAssertEqual(toggle.keyEquivalent, "b")
        XCTAssertEqual(toggle.keyEquivalentModifierMask, [.command, .control])
        XCTAssertNotNil(view.items.first { $0.title == "Make Drawer Taller" })
        XCTAssertNotNil(view.items.first { $0.title == "Make Drawer Shorter" })
    }
}
