import XCTest
import AppKit
@testable import LungfishNvdUI
import LungfishWorkflow
import LungfishKit

final class NvdResultViewControllerSmokeTests: XCTestCase {
    @MainActor
    func testViewControllerInstantiates() {
        let vc = NvdResultViewController()
        XCTAssertNotNil(vc.view)
    }

    func testNvdLeafDoesNotDependOnMiniBAM() throws {
        let source = try String(contentsOfFile: "Sources/LungfishNvdUI/NvdResultViewController.swift", encoding: .utf8)
        XCTAssertFalse(source.contains("MiniBAMViewController"))
    }

    // MARK: - URL-open injection seam

    /// Synchronously fires a menu item's action on its target (deterministic in
    /// a headless test, unlike `NSMenu.performActionForItem`). Also lets tests
    /// invoke the VC's `private` `@objc` context-menu handlers from outside the
    /// file: the selector is looked up by name, so Swift access control (which
    /// gates `#selector(...)` expressions but not the `Selector` runtime type)
    /// doesn't block it.
    @MainActor private func fire(_ item: NSMenuItem) {
        _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
    }

    @MainActor func testViewAccessionOnNCBIDoesNotCrashForMalformedAccession() {
        let vc = NvdResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "View on NCBI", action: Selector(("contextViewAccessionOnNCBI:")), keyEquivalent: "")
        item.target = vc
        item.representedObject = "bad accession with spaces"
        fire(item)

        // Foundation percent-encodes the spaces, so assert containment rather
        // than exact equality.
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("ncbi.nlm.nih.gov/nuccore"))
    }

    @MainActor func testViewAccessionOnNCBIOpensExactURLForWellFormedAccession() {
        let vc = NvdResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "View on NCBI", action: Selector(("contextViewAccessionOnNCBI:")), keyEquivalent: "")
        item.target = vc
        item.representedObject = "NC_045512.2"
        fire(item)

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].absoluteString, "https://www.ncbi.nlm.nih.gov/nuccore/NC_045512.2")
    }

    @MainActor func testSearchPubMedOpensEncodedURL() {
        let vc = NvdResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "Search PubMed", action: Selector(("contextSearchPubMed:")), keyEquivalent: "")
        item.target = vc
        item.representedObject = "Severe acute respiratory syndrome coronavirus 2"
        fire(item)

        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("pubmed.ncbi.nlm.nih.gov"))
    }
}
