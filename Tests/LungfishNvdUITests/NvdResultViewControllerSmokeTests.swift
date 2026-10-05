import XCTest
import AppKit
@testable import LungfishNvdUI
import LungfishWorkflow
import LungfishIO
import LungfishKit
import LungfishTestSupport

final class NvdResultViewControllerSmokeTests: XCTestCase {
    @MainActor
    func testViewControllerInstantiates() {
        let vc = NvdResultViewController()
        XCTAssertNotNil(vc.view)
    }

    func testNvdLeafDoesNotDependOnMiniBAM() throws {
        let source = try readRepositorySource(atPath: "Sources/LungfishNvdUI/NvdResultViewController.swift")
        XCTAssertFalse(source.contains("MiniBAMViewController"))
    }

    // MARK: - URL-open injection seam

    @MainActor private func makeControllerWithOneRow(accession: String) -> NvdResultViewController {
        let vc = NvdResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [NvdContigRow(
                sampleId: "sample-A", qseqid: "NODE_1", qlen: 100,
                adjustedTaxidName: "Severe acute respiratory syndrome coronavirus 2", adjustedTaxidRank: "species",
                sseqid: accession, stitle: "Reference title", pident: 99.5, evalue: 1e-20, bitscore: 120,
                mappedReads: 10, readsPerBillion: 10_000
            )],
            manifest: NvdManifest(
                experiment: "exp", sampleCount: 1, contigCount: 1, hitCount: 1, blastDbVersion: "db",
                snakemakeRunId: "run", sourceDirectoryPath: "/tmp", samples: [], cachedTopContigs: nil
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/nvd-smoke", isDirectory: true)
        )
        vc.testSelectOutlineRow(0)
        return vc
    }

    @MainActor func testViewAccessionOnNCBIDoesNotCrashForMalformedAccession() {
        let vc = makeControllerWithOneRow(accession: "bad accession with spaces")
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        vc.openSelectedRowOnNCBI(nil)

        // Foundation percent-encodes the spaces, so assert containment rather
        // than exact equality.
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("ncbi.nlm.nih.gov/nuccore"))
    }

    @MainActor func testViewAccessionOnNCBIOpensExactURLForWellFormedAccession() {
        let vc = makeControllerWithOneRow(accession: "NC_045512.2")
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        vc.openSelectedRowOnNCBI(nil)

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].absoluteString, "https://www.ncbi.nlm.nih.gov/nuccore/NC_045512.2")
    }

    @MainActor func testSearchPubMedOpensEncodedURL() {
        let vc = makeControllerWithOneRow(accession: "NC_045512.2")
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        vc.searchPubMedForSelectedRow(nil)

        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("pubmed.ncbi.nlm.nih.gov"))
    }
}
