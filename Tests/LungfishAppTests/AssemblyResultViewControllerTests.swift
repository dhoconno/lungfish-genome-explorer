import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private enum AssemblyResultViewControllerTestDefaults {
    static let layoutKey = "assemblyPanelLayout"
}

@MainActor
final class AssemblyResultViewControllerTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AssemblyResultViewControllerTestDefaults.layoutKey)
        super.tearDown()
    }

    func testUsesStackedLayoutWhenAssemblyPreferenceIsStacked() async throws {
        UserDefaults.standard.set(
            AssemblyPanelLayout.stacked.rawValue,
            forKey: AssemblyResultViewControllerTestDefaults.layoutKey
        )

        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testTableContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testSingleSelectionShowsContigHeaderInfoAndPreviewRows() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        try await vc.testSelectContig(named: "contig_7")

        XCTAssertEqual(vc.testDetailPane.currentHeaderText, "contig_7 annotated header")
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains(">contig_7 annotated header"))
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains("AACCGGTT"))
        XCTAssertTrue(vc.testDetailPane.currentContextText.isEmpty)
        XCTAssertTrue(vc.testDetailPane.currentArtifactsText.isEmpty)
    }

    func testMultiSelectionShowsSelectionSummaryAndPreviewRows() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        try await vc.testSelectContigs(named: ["contig_7", "contig_9"])

        XCTAssertEqual(vc.testDetailPane.currentSummaryTitle, "2 contigs selected")
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains(">contig_7 annotated header"))
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains("AACCGGTT"))
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains(">contig_9 secondary header"))
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains("ATATAT"))
        XCTAssertTrue(vc.testDetailPane.currentContextText.isEmpty)
        XCTAssertTrue(vc.testDetailPane.currentArtifactsText.isEmpty)
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
        XCTAssertEqual(vc.testDetailPane.accessibilityIdentifier(), "assembly-result-detail")
        XCTAssertEqual(vc.testActionBar.accessibilityIdentifier(), "assembly-result-action-bar")
        XCTAssertEqual(vc.testContextMenuTitles, ["Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Create Bundle…"])
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

    func testOlderSelectionTaskCannotOverwriteNewerDetail() async throws {
        let delayedGate = AsyncGate()
        let delayedRecord = AssemblyContigRecord(
            rank: 1,
            name: "old_contig",
            header: "old_contig delayed header",
            lengthBP: 8,
            gcPercent: 50,
            shareOfAssemblyPercent: 57.1
        )
        let currentRecord = AssemblyContigRecord(
            rank: 2,
            name: "new_contig",
            header: "new_contig current header",
            lengthBP: 6,
            gcPercent: 33.3,
            shareOfAssemblyPercent: 42.9
        )
        let fakeCatalog = FakeAssemblyContigCatalog(
            records: [delayedRecord, currentRecord],
            sequenceByName: [
                "old_contig": ">old_contig delayed header\nAACCGGTT\n",
                "new_contig": ">new_contig current header\nATATAT\n",
            ],
            delayedSequenceGates: ["old_contig": delayedGate]
        )

        let vc = AssemblyResultViewController()
        _ = vc.view
        vc.catalogLoader = { _ in fakeCatalog }
        try await vc.configureForTesting(result: makeAssemblyResult())

        vc.testContigTableView.onRowSelected?(delayedRecord)
        vc.testContigTableView.onRowSelected?(currentRecord)

        await waitUntil { vc.testDetailPane.currentHeaderText == "new_contig current header" }

        await delayedGate.open()
        await waitUntil { vc.testDetailPane.currentHeaderText == "new_contig current header" }
    }

    func testCommandCopyUsesVisibleTableAndDetailValues() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        try await vc.testSelectContig(named: "contig_7")
        vc.testCopyVisibleDetailValue(identifier: "assembly-result-detail-length")
        XCTAssertEqual(pasteboard.lastString, "8 bp")

        vc.testCopyVisibleTableValue(row: 0, columnID: "name")
        XCTAssertEqual(pasteboard.lastString, "contig_7")
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
