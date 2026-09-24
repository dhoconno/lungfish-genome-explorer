import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// UX-09 (2026-09-23 best-practices audit): a 12S bundle that fails to load
/// used to call `showNoSequenceSelected()`, which reads exactly like an
/// empty, unselected viewport — the user cannot tell a load failed from
/// having simply not clicked anything. Assembly and Mapping already surface
/// load failures as a status-bar message naming the failure
/// ("Unable to load assembly/mapping result."); 12S should do the same.
@MainActor
final class TwelveSResultLoadFailureTests: XCTestCase {
    func testMalformedTwelveSBundleSurfacesLoadFailureInStatusBar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("twelveS-load-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A directory that exists but is not a well-formed 12S result bundle
        // (no manifest, no sample data) makes `TwelveSAmpliconResultBundle
        // .loadResult` throw, driving the catch path under test.
        let malformedBundleURL = tempDir.appendingPathComponent("not-a-bundle.lungfishref")
        try FileManager.default.createDirectory(at: malformedBundleURL, withIntermediateDirectories: true)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()

        split.displayTwelveSAmpliconResultBundleFromSidebar(at: malformedBundleURL)

        let statusText = split.viewerController.statusBar.positionLabel.stringValue
        XCTAssertEqual(statusText, "Unable to load 12S result.")
        XCTAssertNotEqual(statusText, "No sequence selected")
    }
}
