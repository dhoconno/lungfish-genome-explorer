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

    @MainActor func testViewAccessionOnNCBIDoesNotCrashForMalformedAccession() {
        let vc = NvdResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "View on NCBI", action: nil, keyEquivalent: "")
        item.representedObject = "bad accession with spaces"
        vc.contextViewAccessionOnNCBI(item)

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

        let item = NSMenuItem(title: "View on NCBI", action: nil, keyEquivalent: "")
        item.representedObject = "NC_045512.2"
        vc.contextViewAccessionOnNCBI(item)

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].absoluteString, "https://www.ncbi.nlm.nih.gov/nuccore/NC_045512.2")
    }

    @MainActor func testSearchPubMedOpensEncodedURL() {
        let vc = NvdResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "Search PubMed", action: nil, keyEquivalent: "")
        item.representedObject = "Severe acute respiratory syndrome coronavirus 2"
        vc.contextSearchPubMed(item)

        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("pubmed.ncbi.nlm.nih.gov"))
    }
}
