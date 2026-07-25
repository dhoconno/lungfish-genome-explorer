import AppKit
import XCTest
@testable import LungfishCore
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

    func testCommandCopyUsesVisibleDetailValues() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        try await vc.testSelectContig(named: "contig_7")
        await waitUntil {
            !vc.testDetailContainer.isHidden &&
                vc.testDetailPane.currentHeaderText == "contig_7 annotated header"
        }

        vc.testCopyVisibleDetailValue(identifier: "assembly-result-detail-length")
        XCTAssertEqual(pasteboard.lastString, "8 bp")
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

    func testAssemblyPrimaryTypographyUpdatesLiveAndPreservesTableAndSplitState() async throws {
        try await preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()

            let vc = AssemblyResultViewController()
            vc.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)
            try await vc.configureForTesting(result: makeAssemblyResult())
            vc.view.layoutSubtreeIfNeeded()

            let identity = ObjectIdentifier(vc)
            let baselineSummaryFont = vc.testSummaryStrip.testValueFontPointSize(
                identifier: "assembly-result-summary-assembler"
            )
            let baselineSummaryHeight = vc.testSummaryStrip.testHeight
            let baselineEmptyFont = vc.testEmptyStateFontPointSize
            let baselineRowHeight = vc.testContigTableView.testTableView.rowHeight
            let splitOrientation = vc.testSplitView.isVertical
            let arrangedSubviews = vc.testSplitView.arrangedSubviews.map(ObjectIdentifier.init)
            let widths = vc.testContigTableView.testTableView.tableColumns.map(\.width)
            let typographyApplyCount = vc.testTypographyApplicationCount

            settings.contentTextSizePreference = .custom(200)
            settings.save()
            vc.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(ObjectIdentifier(vc), identity)
            XCTAssertEqual(
                vc.testSummaryStrip.testValueFontPointSize(
                    identifier: "assembly-result-summary-assembler"
                ),
                baselineSummaryFont * 2,
                accuracy: 0.01
            )
            XCTAssertGreaterThan(vc.testSummaryStrip.testHeight, baselineSummaryHeight)
            XCTAssertGreaterThan(vc.testSummaryStrip.testRowCount, 1)
            XCTAssertEqual(vc.testEmptyStateFontPointSize, baselineEmptyFont * 2, accuracy: 0.01)
            XCTAssertGreaterThan(vc.testContigTableView.testTableView.rowHeight, baselineRowHeight)
            XCTAssertEqual(vc.testSplitView.isVertical, splitOrientation)
            XCTAssertEqual(
                vc.testSplitView.arrangedSubviews.map(ObjectIdentifier.init),
                arrangedSubviews
            )
            XCTAssertTrue(
                zip(vc.testContigTableView.testTableView.tableColumns.map(\.width), widths)
                    .allSatisfy { $0 > $1 }
            )
            XCTAssertEqual(vc.testTypographyApplicationCount, typographyApplyCount + 1)

            let readableHeaderTooltips = Dictionary(
                uniqueKeysWithValues: vc.testContigTableView.testTableView.tableColumns.map {
                    ($0.identifier.rawValue, $0.headerToolTip)
                }
            )
            XCTAssertEqual(readableHeaderTooltips["length"], "Length (bp)")
            XCTAssertEqual(readableHeaderTooltips["share"], "Share of Assembly (%)")
            XCTAssertEqual(readableHeaderTooltips["preview"], "Sequence Preview")

            settings.contentTextSizePreference = .custom(100)
            settings.save()
            vc.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                vc.testSummaryStrip.testValueFontPointSize(
                    identifier: "assembly-result-summary-assembler"
                ),
                baselineSummaryFont,
                accuracy: 0.01
            )
            XCTAssertEqual(vc.testSummaryStrip.testHeight, baselineSummaryHeight, accuracy: 0.01)
            XCTAssertEqual(vc.testSummaryStrip.testRowCount, 1)
            XCTAssertEqual(vc.testEmptyStateFontPointSize, baselineEmptyFont, accuracy: 0.01)
            XCTAssertEqual(vc.testContigTableView.testTableView.rowHeight, baselineRowHeight, accuracy: 0.01)
            XCTAssertEqual(vc.testContigTableView.testTableView.tableColumns.map(\.width), widths)
            XCTAssertEqual(vc.testTypographyApplicationCount, typographyApplyCount + 2)
        }
    }

    func testSummaryOptionalMetricsCreatedAtLargeSizeUseCurrentTypographyAndReadableValues() async throws {
        try await preservingContentTextSizePreference {
            let settings = AppSettings.shared
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

            settings.contentTextSizePreference = .custom(100)
            settings.save()
            let vc = AssemblyResultViewController()
            vc.view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
            try await vc.configureForTesting(result: initialResult)
            let baseline = vc.testSummaryStrip.testValueFontPointSize(
                identifier: "assembly-result-summary-assembler"
            )

            settings.contentTextSizePreference = .custom(200)
            settings.save()
            try await vc.configureForTesting(result: baseResult)
            vc.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                vc.testSummaryStrip.testValueFontPointSize(
                    identifier: "assembly-result-summary-version"
                ),
                baseline * 2,
                accuracy: 0.01
            )
            XCTAssertEqual(
                vc.testSummaryStrip.testValueFontPointSize(
                    identifier: "assembly-result-summary-wall-time"
                ),
                baseline * 2,
                accuracy: 0.01
            )
            XCTAssertEqual(
                vc.testSummaryStrip.testAccessibilityValue(
                    identifier: "assembly-result-summary-version"
                ),
                "4.0.0"
            )
            XCTAssertTrue(vc.testSummaryStrip.testFieldsAllowWrapping)
        }
    }

    func testDetailTypographyReflowsAndPreservesSequenceSelectionAndScroll() {
        preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()

            let pane = AssemblyContigDetailPane(
                frame: NSRect(x: 0, y: 0, width: 520, height: 540)
            )

            let longSequence = (0..<240)
                .map { index in "\(index): AACCGGTTAACCGGTTAACCGGTTAACCGGTT" }
                .joined(separator: "\n")
            pane.showSingleSelection(
                record: AssemblyContigRecord(
                    rank: 1,
                    name: "NODE_1",
                    header: "NODE_1 long annotated header that must remain readable without truncation",
                    lengthBP: 8_000,
                    gcPercent: 50,
                    shareOfAssemblyPercent: 100,
                    previewSequence: "AACCGGTT"
                ),
                fastaPreview: longSequence
            )
            pane.layoutSubtreeIfNeeded()

            let baselineSequenceFont = pane.testSequenceFontPointSize
            let baselineMinimumHeight = pane.testSequenceMinimumHeight
            let baselineApplyCount = pane.testTypographyApplicationCount
            let selection = NSRange(location: 120, length: 24)
            pane.testSetSequenceSelection(selection)
            pane.testSetSequenceScrollOrigin(NSPoint(x: 0, y: 180))
            let scrollOrigin = pane.testSequenceScrollOrigin

            settings.contentTextSizePreference = .custom(200)
            settings.save()
            pane.layoutSubtreeIfNeeded()

            XCTAssertEqual(pane.testSequenceFontPointSize, baselineSequenceFont * 2, accuracy: 0.01)
            XCTAssertTrue(pane.testSequenceFontIsFixedPitch)
            XCTAssertGreaterThan(pane.testSequenceMinimumHeight, baselineMinimumHeight)
            XCTAssertEqual(pane.testMetricsRowCount, 2)
            XCTAssertEqual(pane.testSequenceSelectedRange, selection)
            XCTAssertEqual(pane.testSequenceScrollOrigin.y, scrollOrigin.y, accuracy: 0.01)
            XCTAssertEqual(pane.testTypographyApplicationCount, baselineApplyCount + 1)
            XCTAssertEqual(pane.testTitleMaximumNumberOfLines, 0)
            XCTAssertEqual(pane.testTitleLineBreakMode, .byWordWrapping)

            settings.contentTextSizePreference = .custom(100)
            settings.save()
            pane.layoutSubtreeIfNeeded()

            XCTAssertEqual(pane.testSequenceFontPointSize, baselineSequenceFont, accuracy: 0.01)
            XCTAssertEqual(pane.testSequenceMinimumHeight, baselineMinimumHeight, accuracy: 0.01)
            XCTAssertEqual(pane.testMetricsRowCount, 1)
            XCTAssertEqual(pane.testSequenceSelectedRange, selection)
            XCTAssertEqual(pane.testTypographyApplicationCount, baselineApplyCount + 2)
        }
    }

    func testSummaryAndDetailUseResolvedSystemMetricsAndAvailableNarrowWidth() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .system
            settings.save()
            let provider = FixedAssemblyPreferredFontProvider(pointSize: 24)

            let strip = AssemblySummaryStrip(
                frame: NSRect(x: 0, y: 0, width: 420, height: 400)
            )
            strip.testSetContentPreferredFontProvider(provider)
            strip.configure(result: try makeAssemblyResult(), pasteboard: RecordingPasteboard())
            strip.frame.size.width = 420
            strip.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(strip.testRowCount, 1)
            XCTAssertTrue(strip.testRowsFillAvailableWidth)
            XCTAssertTrue(strip.testContentFramesAreContained)
            XCTAssertFalse(strip.testHasAmbiguousLayout)
            XCTAssertGreaterThanOrEqual(strip.testHeight, strip.testMeasuredContentHeight)

            let pane = AssemblyContigDetailPane(
                frame: NSRect(x: 0, y: 0, width: 360, height: 640)
            )
            pane.testSetContentPreferredFontProvider(provider)
            pane.showMultiSelection(
                summary: AssemblyContigSelectionSummary(
                    selectedContigCount: 12,
                    totalSelectedBP: 123_456_789,
                    longestContigBP: 98_765_432,
                    shortestContigBP: 1_234,
                    lengthWeightedGCPercent: 51.25
                ),
                fastaPreview: ">selection\nAACCGGTT\n"
            )
            pane.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(pane.testMetricsRowCount, 1)
            XCTAssertTrue(pane.testMetricFramesAreContained)
            XCTAssertLessThanOrEqual(pane.testSequenceMinimumHeight, 180)
            XCTAssertLessThan(pane.testSequenceMinimumPriority, .required)
            XCTAssertFalse(pane.testHasAmbiguousLayout)
        }
    }

    func testAssemblyHeaderWidthsAdaptAndRecoverWithoutOverwritingUserWidth() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()
            let table = AssemblyContigTableView(
                frame: NSRect(x: 0, y: 0, width: 900, height: 360)
            )
            let shareColumn = try XCTUnwrap(
                table.testTableView.tableColumns.first {
                    $0.identifier.rawValue == "share"
                }
            )
            shareColumn.width = 137
            let baselineMinimum = shareColumn.minWidth

            settings.contentTextSizePreference = .custom(200)
            settings.save()

            let enlargedWidth = shareColumn.width
            let enlargedMinimum = shareColumn.minWidth
            XCTAssertGreaterThan(enlargedWidth, 137)
            XCTAssertGreaterThan(enlargedMinimum, baselineMinimum)
            XCTAssertGreaterThanOrEqual(
                enlargedWidth,
                ceil(shareColumn.headerCell.cellSize.width + 20)
            )

            settings.contentTextSizePreference = .custom(100)
            settings.save()

            XCTAssertEqual(shareColumn.width, 137, accuracy: 0.01)
            XCTAssertEqual(shareColumn.minWidth, baselineMinimum, accuracy: 0.01)

            let systemProvider = FixedAssemblyPreferredFontProvider(pointSize: 26)
            settings.contentTextSizePreference = .system
            settings.save()
            table.setContentPreferredFontProvider(systemProvider)
            XCTAssertGreaterThan(shareColumn.width, 137)
            XCTAssertGreaterThanOrEqual(
                shareColumn.width,
                ceil(shareColumn.headerCell.cellSize.width + 20)
            )
        }
    }

    func testDetailMetricAccessibilityLabelsAndFullValuesFollowSelectionContext() {
        let pane = AssemblyContigDetailPane(
            frame: NSRect(x: 0, y: 0, width: 520, height: 640)
        )

        pane.showEmptyState(contigCount: 2)
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-length"),
            .init(label: "Contig length", value: "Not available")
        )

        pane.showSingleSelection(
            record: AssemblyContigRecord(
                rank: 7,
                name: "contig_7",
                header: "contig_7 complete header",
                lengthBP: 123_456,
                gcPercent: 51.25,
                shareOfAssemblyPercent: 12.5,
                previewSequence: "AACCGGTT"
            ),
            fastaPreview: ">contig_7\nAACCGGTT\n"
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-length"),
            .init(label: "Contig length", value: "123456 bp")
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-gc"),
            .init(label: "Contig GC percent", value: "51.2%")
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-rank"),
            .init(label: "Contig rank", value: "#7")
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-share"),
            .init(label: "Share of assembly", value: "12.50% of assembly")
        )

        pane.showMultiSelection(
            summary: AssemblyContigSelectionSummary(
                selectedContigCount: 3,
                totalSelectedBP: 222_222,
                longestContigBP: 111_111,
                shortestContigBP: 22_222,
                lengthWeightedGCPercent: 49.75
            ),
            fastaPreview: ">selection\nAACCGGTT\n"
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-length"),
            .init(label: "Selected total length", value: "222222 bp total")
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-gc"),
            .init(label: "Selected weighted GC percent", value: "49.8% weighted GC")
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-rank"),
            .init(label: "Selected longest contig", value: "Longest: 111111 bp")
        )
        XCTAssertEqual(
            pane.testMetricAccessibility(identifier: "assembly-result-detail-share"),
            .init(label: "Selected shortest contig", value: "Shortest: 22222 bp")
        )
    }

    func testSequenceFirstResponderSurvivesTypographyRoundTripInSafeHostWindow() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()
            let pane = AssemblyContigDetailPane(
                frame: NSRect(x: 0, y: 0, width: 520, height: 640)
            )
            pane.showSingleSelection(
                record: AssemblyContigRecord(
                    rank: 1,
                    name: "contig",
                    header: "contig",
                    lengthBP: 8,
                    gcPercent: 50,
                    shareOfAssemblyPercent: 100
                ),
                fastaPreview: (0..<100).map { "\($0) AACCGGTT" }.joined(separator: "\n")
            )

            try withSafeAssemblyHostWindow(content: pane, size: pane.frame.size) { window in
                pane.layoutSubtreeIfNeeded()
                XCTAssertTrue(window.makeFirstResponder(pane.testSequenceView))
                let responder = try XCTUnwrap(window.firstResponder)
                pane.testSetSequenceSelection(NSRange(location: 12, length: 8))
                pane.testSetSequenceScrollOrigin(NSPoint(x: 0, y: 100))

                settings.contentTextSizePreference = .custom(200)
                settings.save()
                pane.layoutSubtreeIfNeeded()
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(responder))
                XCTAssertEqual(pane.testSequenceSelectedRange, NSRange(location: 12, length: 8))

                settings.contentTextSizePreference = .custom(100)
                settings.save()
                pane.layoutSubtreeIfNeeded()
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(responder))
                XCTAssertEqual(pane.testSequenceSelectedRange, NSRange(location: 12, length: 8))
            }
        }
    }

    func testAlignmentAndAssemblyFixedFontInventoryIsDurableAndExcludesScientificZoom() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let inventory = try String(
            contentsOf: root.appendingPathComponent(
                "docs/verification/2026-07-25-alignment-assembly-content-typography-inventory.md"
            ),
            encoding: .utf8
        )

        for source in [
            "AlignmentResultViewController.swift",
            "AssemblyContigDetailPane.swift",
            "AssemblyContigTableView.swift",
            "AssemblyResultViewController.swift",
            "AssemblySummaryStrip.swift",
        ] {
            XCTAssertTrue(inventory.contains(source), "Missing inventory entry for \(source)")
        }
        XCTAssertTrue(inventory.contains("BAM pileup"))
        XCTAssertTrue(inventory.contains("scientific zoom"))
        XCTAssertTrue(inventory.contains("ContentTypography"))
    }
}

@MainActor
private func preservingContentTextSizePreference<T>(
    _ body: () async throws -> T
) async rethrows -> T {
    let settings = AppSettings.shared
    let original = settings.contentTextSizePreference
    defer {
        settings.contentTextSizePreference = original
        settings.save()
    }
    return try await body()
}

@MainActor
private func preservingContentTextSizePreference<T>(
    _ body: () throws -> T
) rethrows -> T {
    let settings = AppSettings.shared
    let original = settings.contentTextSizePreference
    defer {
        settings.contentTextSizePreference = original
        settings.save()
    }
    return try body()
}

@MainActor
private struct FixedAssemblyPreferredFontProvider: ContentPreferredFontProviding {
    let pointSize: CGFloat

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }
}

@MainActor
private func withSafeAssemblyHostWindow<T>(
    content: NSView,
    size: NSSize,
    _ body: (NSWindow) throws -> T
) rethrows -> T {
    try autoreleasepool {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer {
            _ = window.makeFirstResponder(nil)
            content.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        return try body(window)
    }
}
