import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectLockBannerLayoutTests: XCTestCase {
    func testWarningStaysBelowTitlebarAndRemovalRestoresFullSizeLayout() throws {
        let session = ProjectSession()
        let split = MainSplitViewController(projectSession: session)
        let controller = MainWindowContentViewController(projectSession: session, splitViewController: split)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "ProjectLockBannerLayoutTests")
        window.toolbarStyle = .unified
        window.contentViewController = controller
        controller.loadViewIfNeeded()
        let warning = ProjectOpenWarningState(projectURL: nil, lockRecord: nil,
            lockStatus: .unknown, readErrorDescription: String(repeating: "Unknown lock owner. ", count: 30))

        for width: CGFloat in [800, 1400] {
            window.setContentSize(NSSize(width: width, height: 600))
            // Headless windows otherwise expand to the labels' fitting width.
            let widthConstraint = controller.view.widthAnchor.constraint(equalToConstant: width)
            widthConstraint.isActive = true
            defer { widthConstraint.isActive = false }
            controller.updateProjectLockWarningBanner(with: warning)
            controller.view.layoutSubtreeIfNeeded()
            let banner = try XCTUnwrap(descendant(controller.view, identifier: MainWindowAccessibilityID.projectLockBanner))
            let bannerRect = banner.convert(banner.bounds, to: nil)
            XCTAssertGreaterThan(window.contentView!.bounds.height, window.contentLayoutRect.height)
            XCTAssertLessThanOrEqual(bannerRect.maxY, window.contentLayoutRect.maxY + 0.5)
            XCTAssertGreaterThanOrEqual(bannerRect.height, 36)
            XCTAssertEqual(bannerRect.width, width, accuracy: 0.5)

            controller.updateProjectLockWarningBanner(with: .unlocked(projectURL: nil))
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertNil(descendant(controller.view, identifier: MainWindowAccessibilityID.projectLockBanner))
            XCTAssertEqual(split.view.convert(split.view.bounds, to: nil).maxY,
                           controller.view.convert(controller.view.bounds, to: nil).maxY, accuracy: 0.5)
        }
    }

    private func descendant(_ view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.descendant($0, identifier: identifier) }.first
    }
}
