import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class FASTACollectionViewControllerTests: XCTestCase {
    func testBlastLoadingUsesSharedDrawerAndCollapsesSelectionDetail() throws {
        let vc = FASTACollectionViewController()
        _ = vc.view
        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([0])

        XCTAssertFalse(vc.testDetailIsCollapsed)
        vc.showBlastLoading(phase: .submitting, requestId: "RID-1")

        XCTAssertTrue(vc.testDetailIsCollapsed)
        XCTAssertTrue(vc.testBlastDrawerIsOpen)
        XCTAssertEqual(vc.testBlastDrawerTab?.presentationStyle, .sequenceBlast)
        guard case .loading(let phase, let requestId) = vc.testBlastDrawerTab?.displayState else {
            return XCTFail("Expected the shared BLAST drawer loading state")
        }
        XCTAssertEqual(phase, .submitting)
        XCTAssertEqual(requestId, "RID-1")
    }

    func testSelectionChangeClosesBlastDrawerAndRestoresFASTASelectionDetail() throws {
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
        vc.testSelectRows([0])
        vc.showBlastResults(makeBlastResult(queryID: "seq1"))

        guard case .results = vc.testBlastDrawerTab?.displayState else {
            return XCTFail("Expected the shared BLAST drawer result state")
        }
        XCTAssertTrue(vc.testBlastDrawerIsOpen)

        vc.testSelectRows([1])

        XCTAssertFalse(vc.testBlastDrawerIsOpen)
        XCTAssertFalse(vc.testDetailIsCollapsed)
        XCTAssertEqual(vc.testDetailText, ">seq2\nATATAT\n")
        XCTAssertGreaterThan(vc.testDetailHeight, 1)
    }

    func testSelectionChangeCancelsLoadingBlastBeforeRestoringFASTASelectionDetail() throws {
        let vc = FASTACollectionViewController()
        var cancellationCount = 0
        vc.onBlastCancelRequested = { cancellationCount += 1 }
        _ = vc.view
        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AACCGGTT"),
                try makeSequence(name: "seq2", bases: "ATATAT")
            ],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([0])
        vc.showBlastLoading(phase: .waiting, requestId: "RID-1")

        vc.testSelectRows([1])

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(vc.testBlastDrawerIsOpen)
        XCTAssertEqual(vc.testDetailText, ">seq2\nATATAT\n")
    }

    func testBlastFailureAndExistingDrawerCallbacksAreForwarded() throws {
        let vc = FASTACollectionViewController()
        var cancelCount = 0
        var rerunCount = 0
        vc.onBlastCancelRequested = { cancelCount += 1 }
        vc.onBlastRerunRequested = { rerunCount += 1 }
        _ = vc.view
        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([0])

        vc.showBlastFailure("Remote BLAST failed")
        XCTAssertTrue(vc.testBlastDrawerIsOpen)
        guard case .empty = vc.testBlastDrawerTab?.displayState else {
            return XCTFail("Expected the shared drawer failure/empty presentation")
        }

        vc.testBlastDrawerTab?.onCancelBlast?()
        vc.testBlastDrawerTab?.onRerunBlast?()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(rerunCount, 1)
    }

    func testChangingCancelHandlerAfterDrawerCreationStillRestoresSelectionDetail() throws {
        let vc = FASTACollectionViewController()
        _ = vc.view
        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([0])
        vc.showBlastLoading(phase: .waiting, requestId: "RID-1")

        var cancellationCount = 0
        vc.onBlastCancelRequested = { cancellationCount += 1 }
        vc.testBlastDrawerTab?.onCancelBlast?()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(vc.testBlastDrawerIsOpen)
        XCTAssertFalse(vc.testDetailIsCollapsed)
        XCTAssertEqual(vc.testDetailText, ">seq1\nAACCGGTT\n")
    }

    func testContextMenuUsesSharedFastaActionSetWhenCallbacksPresent() throws {
        let vc = FASTACollectionViewController()
        vc.onExtractSequenceRequested = { _ in }
        vc.onBlastRequested = { _ in }
        vc.onExportRequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onAlignWithMAFFTRequested = { _ in }
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
            ["Extract Sequence…", "Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Extract to New Bundle…", "Align with MAFFT…", "Run Operation…"]
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

    func testContextActionsUseSelectedRecordsInVisibleOrder() throws {
        let vc = FASTACollectionViewController()
        let pasteboard = RecordingPasteboard()
        vc.testSetPasteboard(pasteboard)
        var captured: [String: [String]] = [:]
        vc.onExtractSequenceRequested = { captured["Extract Sequence…"] = $0.map(\.name) }
        vc.onBlastRequested = { captured["Verify with BLAST…"] = $0.map(\.name) }
        vc.onExportRequested = { captured["Export FASTA…"] = $0.map(\.name) }
        vc.onCreateBundleRequested = { captured["Extract to New Bundle…"] = $0.map(\.name) }
        vc.onAlignWithMAFFTRequested = { captured["Align with MAFFT…"] = $0.map(\.name) }
        vc.onRunOperationRequested = { captured["Run Operation…"] = $0.map(\.name) }
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
        let singleSequenceActions = ["Extract Sequence…", "Verify with BLAST…", "Export FASTA…", "Extract to New Bundle…", "Run Operation…"]
        singleSequenceActions.forEach {
            vc.testInvokeContextMenuItem(titled: $0)
        }
        singleSequenceActions.forEach {
            XCTAssertEqual(captured[$0], ["seq2"], "action: \($0)")
        }
        XCTAssertFalse(vc.testContextMenuItem(titled: "Align with MAFFT…")?.isEnabled ?? true)
        vc.testInvokeContextMenuItem(titled: "Copy FASTA")
        XCTAssertEqual(pasteboard.lastString, ">seq2\nATATAT\n")

        captured.removeAll()
        vc.testSelectRows([1, 0])
        let multiSequenceActions = ["Extract Sequence…", "Verify with BLAST…", "Export FASTA…", "Extract to New Bundle…", "Align with MAFFT…", "Run Operation…"]
        multiSequenceActions.forEach {
            vc.testInvokeContextMenuItem(titled: $0)
        }
        multiSequenceActions.forEach {
            XCTAssertEqual(captured[$0], ["seq1", "seq2"], "action: \($0)")
        }
        vc.testInvokeContextMenuItem(titled: "Copy FASTA")
        XCTAssertEqual(pasteboard.lastString, ">seq1\nAACCGGTT\n\n>seq2\nATATAT\n")
    }

    func testContextMenuReconcilesClickedRowAndKeepsCurrentSelectionWithoutOne() throws {
        let vc = FASTACollectionViewController()
        var capturedNames: [String] = []
        vc.onRunOperationRequested = { capturedNames = $0.map(\.name) }
        _ = vc.view
        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AAAA"),
                try makeSequence(name: "seq2", bases: "CCCC"),
                try makeSequence(name: "seq3", bases: "GGGG")
            ],
            annotations: [],
            sourceNames: [:]
        )

        vc.testSelectRows([0, 1])
        vc.testUpdateContextMenu(clickedRow: 1)
        vc.testInvokeContextMenuItem(titled: "Run Operation…")
        XCTAssertEqual(capturedNames, ["seq1", "seq2"])

        vc.testSelectRows([0, 1])
        vc.testUpdateContextMenu(clickedRow: 2)
        vc.testInvokeContextMenuItem(titled: "Run Operation…")
        XCTAssertEqual(capturedNames, ["seq3"])

        vc.testSelectRows([0, 1])
        vc.testUpdateContextMenu(clickedRow: nil)
        vc.testInvokeContextMenuItem(titled: "Run Operation…")
        XCTAssertEqual(capturedNames, ["seq1", "seq2"])
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

    private func makeBlastResult(queryID: String) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "Selected FASTA sequences",
            taxId: 0,
            readResults: [BlastReadResult(
                id: queryID,
                verdict: .verified,
                topHitOrganism: "Macaca mulatta",
                topHitAccession: "AB123456",
                percentIdentity: 99.5,
                eValue: 0,
                matchesQueriedTaxon: true
            )],
            submittedAt: Date(),
            completedAt: Date(),
            rid: "RID-1",
            blastProgram: "megablast",
            database: "core_nt"
        )
    }
}
