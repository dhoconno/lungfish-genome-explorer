import AppKit
import XCTest
@testable import LungfishAssemblyUI
@testable import LungfishWorkflow
import LungfishKit

private enum AssemblyResultViewControllerTestDefaults {
    static let layoutKey = "assemblyPanelLayout"
}

@MainActor
final class AssemblyResultViewControllerTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AssemblyResultViewControllerTestDefaults.layoutKey)
        super.tearDown()
    }

    func testAssemblyViewportUsesSingleResultsTableWithSequencePreviewColumn() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        XCTAssertEqual(
            vc.testContigTableView.testTableView.tableColumns.map(\.title),
            ["#", "Contig", "Length (bp)", "GC %", "Share of Assembly (%)", "Sequence Preview"]
        )
        XCTAssertTrue(vc.testDetailContainer.isHidden)
    }

    func testSingleSelectionProvidesPreviewColumnValue() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        try await vc.testSelectContig(named: "contig_7")

        vc.testCopyVisibleTableValue(row: 0, columnID: "preview")
        XCTAssertEqual(pasteboard.lastString, "AACCGGTT")
    }

    func testSingleSelectionPopulatesDetailPane() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        try await vc.testSelectContig(named: "contig_7")
        await waitUntil {
            !vc.testDetailContainer.isHidden &&
                vc.testDetailPane.currentHeaderText == "contig_7 annotated header"
        }

        XCTAssertEqual(vc.testDetailPane.currentSequenceText, ">contig_7 annotated header\nAACCGGTT\n")
    }

    func testMultiSelectionPopulatesDetailPaneSummary() async throws {
        let records = [
            AssemblyContigRecord(
                rank: 1,
                name: "contig_a",
                header: "contig_a first",
                lengthBP: 8,
                gcPercent: 50,
                shareOfAssemblyPercent: 60,
                previewSequence: "AACCGGTT"
            ),
            AssemblyContigRecord(
                rank: 2,
                name: "contig_b",
                header: "contig_b second",
                lengthBP: 6,
                gcPercent: 33.3,
                shareOfAssemblyPercent: 40,
                previewSequence: "ATATAT"
            ),
        ]
        let summary = AssemblyContigSelectionSummary(
            selectedContigCount: 2,
            totalSelectedBP: 14,
            longestContigBP: 8,
            shortestContigBP: 6,
            lengthWeightedGCPercent: 42.9
        )

        let vc = AssemblyResultViewController()
        _ = vc.view
        vc.catalogLoader = { _ in
            FakeAssemblyContigCatalog(
                records: records,
                sequenceByName: [
                    "contig_a": ">contig_a first\nAACCGGTT\n",
                    "contig_b": ">contig_b second\nATATAT\n",
                ],
                summaryByNames: [Set(["contig_a", "contig_b"]): summary]
            )
        }
        try await vc.configureForTesting(result: makeAssemblyResult())

        try await vc.testSelectContigs(named: ["contig_a", "contig_b"])
        await waitUntil {
            !vc.testDetailContainer.isHidden &&
                vc.testDetailPane.currentSummaryTitle == "2 contigs selected"
        }

        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains(">contig_a first"))
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains(">contig_b second"))
    }

    func testSummaryStripShowsAssemblyMetricsAndSupportsQuickCopy() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-assembler"), "SPAdes")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-read-type"), "Illumina Short Reads")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-contigs"), "2")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-n50"), "8 bp")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-global-gc"), "28.6%")

        vc.testCopySummaryValue(identifier: "assembly-result-summary-assembler")
        XCTAssertEqual(pasteboard.lastString, "SPAdes")
    }

    func testSummaryStripAddsOptionalFieldsWhenLaterResultProvidesThem() async throws {
        let baseResult = try makeAssemblyResult()
        let initialResult = AssemblyResult(
            tool: baseResult.tool,
            readType: baseResult.readType,
            contigsPath: baseResult.contigsPath,
            graphPath: baseResult.graphPath,
            logPath: baseResult.logPath,
            assemblerVersion: nil,
            commandLine: baseResult.commandLine,
            outputDirectory: baseResult.outputDirectory,
            statistics: baseResult.statistics,
            wallTimeSeconds: 0,
            scaffoldsPath: baseResult.scaffoldsPath,
            paramsPath: baseResult.paramsPath
        )

        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: initialResult)
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-version"), "")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-wall-time"), "")

        try await vc.configureForTesting(result: baseResult)
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-version"), "4.0.0")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-wall-time"), "15.0s")
    }

    func testAccessibilityIdentifiersAndContextMenuAreStable() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        XCTAssertEqual(vc.view.accessibilityIdentifier(), "assembly-result-view")
        XCTAssertEqual(vc.testSummaryStrip.accessibilityIdentifier(), "assembly-result-summary-strip")
        XCTAssertEqual(vc.testContigTableView.testSearchField.accessibilityIdentifier(), "assembly-result-search")
        XCTAssertEqual(vc.testContigTableView.testTableView.accessibilityIdentifier(), "assembly-result-contig-table")
        XCTAssertEqual(vc.testActionBar.accessibilityIdentifier(), "assembly-result-action-bar")
        XCTAssertEqual(
            vc.testContextMenuTitles,
            ["Extract Sequence…", "BLAST Contig…", "Copy FASTA", "Export FASTA…", "Create Bundle…"]
        )
    }

    func testSequencePreviewUsesDefaultTableFont() {
        let table = AssemblyContigTableView()
        let record = AssemblyContigRecord(
            rank: 1,
            name: "NODE_1",
            header: "NODE_1 test header",
            lengthBP: 1000,
            gcPercent: 50.7,
            shareOfAssemblyPercent: 100,
            previewSequence: "AACCGGTT"
        )

        let preview = table.cellContent(
            for: NSUserInterfaceItemIdentifier("preview"),
            row: record
        )

        XCTAssertEqual(preview.text, "AACCGGTT")
        XCTAssertNil(preview.font)
    }

    func testBlastWarnsWhenMoreThanFiftyContigsAreSelected() async throws {
        let records = (1...51).map { index in
            AssemblyContigRecord(
                rank: index,
                name: "contig_\(index)",
                header: "contig_\(index) header",
                lengthBP: Int64(1000 + index),
                gcPercent: 50.0,
                shareOfAssemblyPercent: 1.0,
                previewSequence: "AACCGGTT"
            )
        }
        let sequences: [String: String] = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.name, ">\(record.name) header\nAACCGGTT\n")
        })

        let vc = AssemblyResultViewController()
        _ = vc.view
        vc.catalogLoader = { _ in
            FakeAssemblyContigCatalog(records: records, sequenceByName: sequences)
        }
        try await vc.configureForTesting(result: makeAssemblyResult())

        var warning: (title: String, message: String)?
        vc.warningPresenter = { title, message in
            warning = (title, message)
        }

        var didBlast = false
        vc.onBlastVerification = { _ in
            didBlast = true
        }

        try await vc.testSelectContigs(named: records.map { $0.name })
        vc.testTriggerBlast()
        await waitUntil {
            warning != nil
        }

        XCTAssertFalse(didBlast)
        XCTAssertEqual(warning?.title, "Too Many Contigs for BLAST")
        XCTAssertEqual(
            warning?.message,
            "Select 50 contigs or fewer for a single BLAST submission."
        )
    }

    func testConfigureLoadsContigsWhenResultIsMissingFASTAIndex() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        let result = try makeAssemblyResult(writeFASTAIndex: false)
        let indexURL = result.contigsPath.appendingPathExtension("fai")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))

        try await vc.configureForTesting(result: result)

        XCTAssertEqual(vc.testContigTableView.record(at: 0)?.name, "contig_7")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
    }

    func testConfigureIgnoresCancelledLoadThatFinishesLater() async throws {
        let delayedGate = AsyncGate()
        let firstResult = try makeAssemblyResult()
        let secondResult = AssemblyResult(
            tool: .megahit,
            readType: firstResult.readType,
            contigsPath: firstResult.contigsPath,
            graphPath: firstResult.graphPath,
            logPath: firstResult.logPath,
            assemblerVersion: "1.2.9",
            commandLine: "megahit -o \(firstResult.outputDirectory.path)",
            outputDirectory: firstResult.outputDirectory.appendingPathComponent("megahit"),
            statistics: firstResult.statistics,
            wallTimeSeconds: 9,
            scaffoldsPath: firstResult.scaffoldsPath,
            paramsPath: firstResult.paramsPath
        )

        let firstCatalog = FakeAssemblyContigCatalog(
            records: [
                .init(rank: 1, name: "old_contig", header: "old_contig delayed header", lengthBP: 8, gcPercent: 50, shareOfAssemblyPercent: 100)
            ],
            sequenceByName: ["old_contig": ">old_contig delayed header\nAACCGGTT\n"]
        )
        let secondCatalog = FakeAssemblyContigCatalog(
            records: [
                .init(rank: 1, name: "new_contig", header: "new_contig current header", lengthBP: 6, gcPercent: 33.3, shareOfAssemblyPercent: 100)
            ],
            sequenceByName: ["new_contig": ">new_contig current header\nATATAT\n"]
        )

        let vc = AssemblyResultViewController()
        _ = vc.view
        vc.catalogLoader = { result in
            if result.tool == .spades {
                await delayedGate.wait()
                return firstCatalog
            }
            return secondCatalog
        }

        vc.configure(result: firstResult)
        vc.configure(result: secondResult)

        await waitUntil {
            vc.currentResult?.tool == .megahit &&
                vc.testSummaryStrip.value(for: "assembly-result-summary-assembler") == "MEGAHIT" &&
                vc.testContigTableView.record(at: 0)?.name == "new_contig"
        }

        await delayedGate.open()
        await waitUntil {
            vc.currentResult?.tool == .megahit &&
                vc.testContigTableView.record(at: 0)?.name == "new_contig"
        }
    }

    func testCompletedWithNoContigsShowsExplicitEmptyStateAndRemovesBrowsingAffordances() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view

        try await vc.configureForTesting(result: makeEmptyAssemblyResult())

        XCTAssertEqual(vc.testEmptyStateMessage, "Assembly completed, but no contigs were generated.")
        XCTAssertFalse(vc.testEmptyStateView.isHidden)
        XCTAssertTrue(vc.testContigTableView.isHidden)
        XCTAssertEqual(vc.testContigTableView.testTableView.numberOfRows, 0)
        XCTAssertFalse(vc.testActionBar.blastButton.isEnabled)
        XCTAssertFalse(vc.testActionBar.copyButton.isEnabled)
        XCTAssertFalse(vc.testActionBar.exportButton.isEnabled)
        XCTAssertFalse(vc.testActionBar.bundleButton.isEnabled)
    }

    func testCommandCopyUsesVisibleTableValues() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        try await vc.testSelectContig(named: "contig_7")
        vc.testCopyVisibleTableValue(row: 0, columnID: "name")
        XCTAssertEqual(pasteboard.lastString, "contig_7")

        vc.testCopyVisibleTableValue(row: 0, columnID: "preview")
        XCTAssertEqual(pasteboard.lastString, "AACCGGTT")
    }

    func testCommandClickOnVisibleTableCellCopiesScalarValue() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)
        vc.view.layoutSubtreeIfNeeded()

        guard let cell = vc.testContigTableView.testTableView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView,
              let textField = cell.textField else {
            return XCTFail("Expected visible contig cell")
        }

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        textField.mouseDown(with: event)
        XCTAssertEqual(pasteboard.lastString, "contig_7")
    }
}
