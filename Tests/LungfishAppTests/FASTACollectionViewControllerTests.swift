import XCTest
import LungfishKit
import LungfishTestSupport
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
            ["Extract Sequence…", "Verify with BLAST…", "Copy Name", "Copy Sequence", "Copy FASTA", "Export FASTA…", "Extract to New Bundle…", "Align with MAFFT…", "Run Operation…"]
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
        vc.testInvokeContextMenuItem(titled: "Copy Name")
        XCTAssertEqual(pasteboard.lastString, "seq2")
        vc.testInvokeContextMenuItem(titled: "Copy Sequence")
        XCTAssertEqual(pasteboard.lastString, "ATATAT")

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
        vc.testInvokeContextMenuItem(titled: "Copy Names")
        XCTAssertEqual(pasteboard.lastString, "seq1\nseq2")
        vc.testInvokeContextMenuItem(titled: "Copy Sequences")
        XCTAssertEqual(pasteboard.lastString, "AACCGGTT\nATATAT")
    }

    func testAnnotatedContextActionsForwardAnnotationsForSelectedSequences() throws {
        let vc = FASTACollectionViewController()
        var extracted: (names: [String], annotations: [String: [String]])?
        var bundled: (names: [String], annotations: [String: [String]])?
        vc.onExtractSequenceWithAnnotationsRequested = { sequences, annotations in
            extracted = (sequences.map(\.name), annotations.mapValues { $0.map(\.name) })
        }
        vc.onCreateBundleWithAnnotationsRequested = { sequences, annotations in
            bundled = (sequences.map(\.name), annotations.mapValues { $0.map(\.name) })
        }
        _ = vc.view
        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AACCGGTT"),
                try makeSequence(name: "seq2", bases: "ATATAT")
            ],
            annotations: [
                SequenceAnnotation(type: .gene, name: "gene1", chromosome: "seq1", start: 1, end: 4),
                SequenceAnnotation(type: .gene, name: "gene2", chromosome: "seq2", start: 0, end: 3)
            ],
            sourceNames: [:]
        )

        vc.testSelectRows([1])
        vc.testInvokeContextMenuItem(titled: "Extract Sequence…")
        vc.testInvokeContextMenuItem(titled: "Extract to New Bundle…")

        XCTAssertEqual(extracted?.names, ["seq2"])
        XCTAssertEqual(extracted?.annotations, ["seq2": ["gene2"]])
        XCTAssertEqual(bundled?.names, ["seq2"])
        XCTAssertEqual(bundled?.annotations, ["seq2": ["gene2"]])
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

    // MARK: - Keyboard and accessibility

    private func makeHostedController(sequenceCount: Int = 3) throws -> (FASTACollectionViewController, NSWindow) {
        _ = NSApplication.shared
        let vc = FASTACollectionViewController()
        vc.onExtractSequenceRequested = { _ in }
        vc.onBlastRequested = { _ in }
        vc.onExportRequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onAlignWithMAFFTRequested = { _ in }
        vc.onRunOperationRequested = { _ in }
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let bases = ["AACCGGTT", "ATATAT", "GGGGCCCC"]
        vc.configure(
            sequences: try (0..<sequenceCount).map { try makeSequence(name: "seq\($0 + 1)", bases: bases[$0 % bases.count]) },
            annotations: [],
            sourceNames: [:]
        )
        vc.view.layoutSubtreeIfNeeded()
        vc.testTableView.layoutSubtreeIfNeeded()
        return (vc, window)
    }

    func testReturnOpensTheSelectedSequenceLikeADoubleClick() throws {
        let (vc, window) = try makeHostedController()
        defer { window.close() }
        var opened: [String] = []
        vc.onOpenSequence = { sequence, _ in opened.append(sequence.name) }
        vc.testSelectRows([1])

        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        vc.testTableView.keyDown(with: returnEvent)
        XCTAssertEqual(opened, ["seq2"])

        vc.testSelectRows([])
        vc.testTableView.keyDown(with: returnEvent)
        XCTAssertEqual(opened, ["seq2"], "Return with no selection opens nothing")
    }

    func testRowsPublishTheSharedFASTAActionsOnceAndInParityWithTheContextMenu() throws {
        let (vc, window) = try makeHostedController()
        defer { window.close() }
        vc.testSelectRows([0])

        let rows = AccessibilityRowProbe.rowProxies(of: vc.testTableView)
        XCTAssertEqual(rows.count, 3)
        let expected = ["Extract Sequence\u{2026}", "Verify with BLAST\u{2026}", "Copy Name", "Copy Sequence", "Copy FASTA", "Export FASTA\u{2026}", "Extract to New Bundle\u{2026}", "Run Operation\u{2026}"]
        XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(rows[0]), expected)
        for served in AccessibilityRowProbe.servedCellActionNames(rows[0]) {
            XCTAssertEqual(served, expected, "the AX server lists each action once")
        }

        // With two rows selected the selected rows offer the plural titles and
        // Align with MAFFT, the unselected row keeps its single-row set, and
        // the context menu (every command enabled) has a cell action for each
        // of its commands.
        vc.testSelectRows([0, 1])
        vc.testUpdateContextMenu(clickedRow: 0)
        let multi = AccessibilityRowProbe.rowProxies(of: vc.testTableView)
        let selectedRowActions = AccessibilityRowProbe.firstCellActionNames(multi[0])
        XCTAssertTrue(selectedRowActions.contains("Align with MAFFT\u{2026}"))
        XCTAssertTrue(selectedRowActions.contains("Copy Names"))
        XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(multi[2]), expected)
        ContextMenuParityAssert.assertParity(
            contextMenu: vc.testContextMenu,
            cellActionNames: selectedRowActions,
            mainMenu: MainMenu.createMainMenu()
        )
    }

    func testRowActionsReachAnOutOfProcessAXClient() throws {
        try XCTSkipUnless(AXProcessProbe.isAvailable, "process is not trusted for accessibility")
        let (vc, window) = try makeHostedController()
        window.orderFront(nil)
        defer { window.close() }
        let pasteboard = RecordingPasteboard()
        vc.testSetPasteboard(pasteboard)
        var extracted: [[String]] = []
        vc.onExtractSequenceRequested = { extracted.append($0.map(\.name)) }

        let listed = AXProcessProbe.rowCellActionNames(row: 2)
        let names = try XCTUnwrap(listed, "the server lists the row's cell")
        XCTAssertTrue(names.contains("Copy Name"), "\(names)")
        XCTAssertEqual(Set(names).count, names.count, "each action listed once: \(names)")
        XCTAssertTrue(AXProcessProbe.performRowCellAction("Copy Name", row: 2))
        XCTAssertEqual(pasteboard.lastString, "seq3")
        vc.testSelectRows([0, 1])
        XCTAssertTrue(AXProcessProbe.performRowCellAction("Extract Sequence\u{2026}", row: 2))
        XCTAssertEqual(extracted.last, ["seq3"], "an unselected row is targeted alone")
    }

    func testCellActionsTargetTheRowTheCellShowsNow() throws {
        let (vc, window) = try makeHostedController()
        defer { window.close() }
        let pasteboard = RecordingPasteboard()
        vc.testSetPasteboard(pasteboard)
        var extracted: [[String]] = []
        vc.onExtractSequenceRequested = { extracted.append($0.map(\.name)) }

        let rows = AccessibilityRowProbe.rowProxies(of: vc.testTableView)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: rows[2]))
        XCTAssertEqual(pasteboard.lastString, "seq3")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy FASTA", in: rows[1]))
        XCTAssertEqual(pasteboard.lastString, ">seq2\nATATAT\n")

        // An action on a row outside the selection targets that row alone;
        // on a selected row it acts on the whole selection.
        vc.testSelectRows([0, 1])
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract Sequence\u{2026}", in: rows[2]))
        XCTAssertEqual(extracted.last, ["seq3"])
        vc.testSelectRows([0, 1])
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract Sequence\u{2026}", in: rows[0]))
        XCTAssertEqual(extracted.last, ["seq1", "seq2"])

        // Sort descending so the recycled cells show other sequences.
        vc.testSort(column: "name", ascending: false)
        vc.testTableView.layoutSubtreeIfNeeded()
        let sorted = AccessibilityRowProbe.rowProxies(of: vc.testTableView)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: sorted[0]))
        XCTAssertEqual(pasteboard.lastString, "seq3")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: sorted[2]))
        XCTAssertEqual(pasteboard.lastString, "seq1")
    }

    func testMenuBarRowCommandsFollowTheSelection() throws {
        let (vc, window) = try makeHostedController()
        defer { window.close() }
        let pasteboard = RecordingPasteboard()
        vc.testSetPasteboard(pasteboard)
        var opened: [String] = []
        vc.onOpenSequence = { sequence, _ in opened.append(sequence.name) }
        var blasted: [String] = []
        vc.onBlastRequested = { blasted = $0.map(\.name) }
        var bundled: [String] = []
        vc.onCreateBundleRequested = { bundled = $0.map(\.name) }

        func item(_ selector: Selector) -> NSMenuItem { NSMenuItem(title: "", action: selector, keyEquivalent: "") }
        let copyName = item(#selector(ResultRowMenuActions.copySelectedRowName(_:)))
        let copySequence = item(#selector(ResultRowMenuActions.copySelectedRowSequence(_:)))
        let copyFASTA = item(#selector(ResultRowMenuActions.copySelectedRowFASTA(_:)))
        let blast = item(#selector(ResultRowMenuActions.blastVerifySelectedRow(_:)))
        let bundle = item(#selector(ResultRowMenuActions.extractSelectedRowsToNewBundle(_:)))
        let activate = item(#selector(ResultRowMenuActions.activateSelectedRow(_:)))

        vc.testSelectRows([])
        for menuItem in [copyName, copySequence, copyFASTA, blast, bundle, activate] {
            XCTAssertFalse(vc.validateMenuItem(menuItem), "\(menuItem.action!) with nothing selected")
        }

        vc.testSelectRows([1])
        for menuItem in [copyName, copySequence, copyFASTA, blast, bundle, activate] {
            XCTAssertTrue(vc.validateMenuItem(menuItem), "\(menuItem.action!) with one row selected")
        }
        vc.copySelectedRowName(nil)
        XCTAssertEqual(pasteboard.lastString, "seq2")
        vc.copySelectedRowSequence(nil)
        XCTAssertEqual(pasteboard.lastString, "ATATAT")
        vc.copySelectedRowFASTA(nil)
        XCTAssertEqual(pasteboard.lastString, ">seq2\nATATAT\n")
        vc.blastVerifySelectedRow(nil)
        XCTAssertEqual(blasted, ["seq2"])
        vc.extractSelectedRowsToNewBundle(nil)
        XCTAssertEqual(bundled, ["seq2"])
        vc.activateSelectedRow(nil)
        XCTAssertEqual(opened, ["seq2"])

        vc.testSelectRows([0, 2])
        XCTAssertFalse(vc.validateMenuItem(activate), "Open Row opens one sequence")
        XCTAssertTrue(vc.validateMenuItem(copyName))
        vc.copySelectedRowName(nil)
        XCTAssertEqual(pasteboard.lastString, "seq1\nseq3")

        vc.onBlastRequested = nil
        XCTAssertFalse(vc.validateMenuItem(blast), "no BLAST handler wired")
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
