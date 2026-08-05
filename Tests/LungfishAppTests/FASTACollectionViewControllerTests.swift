import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class FASTACollectionViewControllerTests: XCTestCase {
    func testContextMenuUsesSharedFastaActionSetWhenCallbacksPresent() throws {
        let vc = FASTACollectionViewController()
        vc.onExtractSequenceRequested = { _ in }
        vc.onBlastRequested = { _ in }
        vc.onExportRequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onRunOperationRequested = { _ in }
        _ = vc.view

        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([0])

        XCTAssertEqual(
            vc.testContextMenuTitles.filter { !$0.isEmpty },
            ["Extract Sequence…", "Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Create Bundle…", "Align with MAFFT…", "Run Operation…"]
        )
    }

    func testRunOperationContextActionUsesSelectedSequences() throws {
        let vc = FASTACollectionViewController()
        var capturedNames: [String] = []
        vc.onRunOperationRequested = { sequences in
            capturedNames = sequences.map(\.name)
        }
        _ = vc.view

        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AACCGGTT"),
                try makeSequence(name: "seq2", bases: "ATATAT")
            ],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([1])
        vc.testInvokeContextMenuItem(titled: "Run Operation…")

        XCTAssertEqual(capturedNames, ["seq2"])
    }

    func testCollectionOmitsMiniMapAndStartsWithCollapsedDetail() throws {
        let vc = FASTACollectionViewController()
        _ = vc.view
        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )

        XCTAssertFalse(vc.testColumnIdentifiers.contains("minimap"))
        XCTAssertTrue(vc.testDetailIsCollapsed)
        XCTAssertEqual(vc.testDetailText, "")
    }

    func testDetailShowsMultipleSelectedRecordsInVisibleOrder() throws {
        let vc = FASTACollectionViewController()
        _ = vc.view
        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AACCGGTT"),
                try makeSequence(name: "seq2", bases: "ATATAT")
            ],
            annotations: [],
            sourceNames: [:]
        )

        vc.testSelectRows([0, 1])

        XCTAssertFalse(vc.testDetailIsCollapsed)
        XCTAssertEqual(vc.testDetailText, ">seq1\nAACCGGTT\n\n>seq2\nATATAT\n")
    }

    func testDetailFollowsFilteredAndSortedVisibleOrder() throws {
        let vc = FASTACollectionViewController()
        _ = vc.view
        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AAAA"),
                try makeSequence(name: "excluded", bases: "CCCC"),
                try makeSequence(name: "seq2", bases: "TTTT")
            ],
            annotations: [],
            sourceNames: [:]
        )

        vc.testSelectRows([0, 2])
        vc.testFilter("seq")
        vc.testSort(column: "name", ascending: false)

        XCTAssertEqual(vc.testDetailText, ">seq2\nTTTT\n\n>seq1\nAAAA\n")
    }

    func testClearingSelectionRestoresPreviousDetailHeight() throws {
        let vc = FASTACollectionViewController()
        _ = vc.view
        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        vc.view.frame.size = NSSize(width: 800, height: 600)
        vc.view.layoutSubtreeIfNeeded()
        vc.testSelectRows([0])
        vc.testSetDetailHeight(180)
        vc.testSelectRows([])
        XCTAssertTrue(vc.testDetailIsCollapsed)

        vc.testSelectRows([0])
        XCTAssertEqual(vc.testDetailHeight, 180, accuracy: 1)
    }

    func testSelectionDetailTextOccupiesTheScrollableDocumentArea() throws {
        let detail = FASTASelectionDetailView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 180)
        )
        detail.setSequences([try makeSequence(name: "seq1", bases: "AACCGGTT")])
        detail.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(detail.subviews.compactMap { $0 as? NSScrollView }.first)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertGreaterThanOrEqual(textView.frame.width, scrollView.contentSize.width)
        XCTAssertGreaterThanOrEqual(textView.frame.height, scrollView.contentSize.height)
    }

    private func makeSequence(name: String, bases: String) throws -> Sequence {
        try Sequence(name: name, alphabet: .dna, bases: bases)
    }
}
