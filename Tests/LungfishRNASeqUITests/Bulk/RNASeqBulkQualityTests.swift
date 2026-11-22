// RNASeqBulkQualityTests.swift - The quality view and the correlation plot show what `rnaseq quality` prints
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The leaf target does not link LungfishCLI, so the expected text is what `RNASeqQualitySubcommand.render()` prints for
// `--format tsv`: `RNASeqQualitySummary.read(resultAt:)` and `RNASeqSampleCorrelation.read(resultAt:)`, then
// `document().tsvText()` (`Sources/LungfishCLI/Commands/RNASeqQualitySubcommand.swift`). The lane's evidence run compares
// the screen with the built `lungfish-cli` itself (`RNASeqBulkEvidenceTests`).

import AppKit
import LungfishIO
import LungfishKit
import XCTest
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

final class RNASeqBulkQualityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-bulk-q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// The cells of a document's TSV text, header first, as `--format tsv` prints them.
    private func cells(_ tsv: String) -> [[String]] {
        tsv.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    @MainActor
    private func loaded(_ controller: RNASeqBulkViewController) throws -> RNASeqBulkQuality {
        guard case .loaded(let quality) = controller.model.quality else {
            throw NSError(domain: "RNASeqBulkQualityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(controller.model.quality)"])
        }
        return quality
    }

    @MainActor
    private func checkQualityAndCorrelationEqualTheCLI(_ url: URL) async throws {
        let controller = try await RNASeqBulkFixtures.show(url)
        let quality = try loaded(controller)
        let cliSamples = cells(try RNASeqQualitySummary.read(resultAt: url).document().tsvText())
        let cliCorrelation = cells(try RNASeqSampleCorrelation.read(resultAt: url).document().tsvText())

        XCTAssertEqual([quality.samples.columns] + quality.samples.rows, cliSamples)
        XCTAssertEqual(controller.numberOfRows(in: controller.qualityTable), cliSamples.count - 1)
        XCTAssertEqual(controller.qualityTable.tableColumns.map(\.headerToolTip), cliSamples[0].map(Optional.some))
        for (row, line) in cliSamples.dropFirst().enumerated() {
            let shown = line.indices.map { column -> String in
                let view = controller.tableView(controller.qualityTable, viewFor: controller.qualityTable.tableColumns[column], row: row)
                return (view as? NSTextField)?.stringValue ?? "<no field>"
            }
            XCTAssertEqual(shown, line, "quality row \(row + 1) on screen")
        }

        XCTAssertEqual([quality.correlationTable.columns] + quality.correlationTable.rows, cliCorrelation)
        XCTAssertEqual(controller.correlationPlot.samples, Array(cliCorrelation[0].dropFirst()))
        XCTAssertEqual(controller.correlationPlot.cells, cliCorrelation.dropFirst().map { Array($0.dropFirst()) },
                       "each square of the plot is a cell of the CLI's correlation table")
    }

    @MainActor
    func testTheQualityAndCorrelationCellsOfSalmonC1EqualRNASeqQuality() async throws {
        try await checkQualityAndCorrelationEqualTheCLI(try RNASeqBulkFixtures.importSalmonC1(into: root))
    }

    @MainActor
    func testTheQualityAndCorrelationCellsOfAResultOnASetEqualRNASeqQuality() async throws {
        try await checkQualityAndCorrelationEqualTheCLI(try RNASeqBulkFixtures.writeNamed(into: root))
    }

    @MainActor
    func testTheWordsOfAnImportAreTheWordsTheCLIWrites() async throws {
        let quality = try loaded(try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.importSalmonC1(into: root)))
        for sample in quality.summary.samples {
            XCTAssertEqual(sample.rRNAPercent, "no rRNA genes annotated", sample.sample)
            XCTAssertEqual(sample.notHostPercent, "Not recorded", "an import names no reference set, \(sample.sample)")
            XCTAssertEqual(sample.globinPercent, "Not recorded", sample.sample)
            XCTAssertEqual(sample.librarySizeSource, "salmon num_processed", sample.sample)
        }
        XCTAssertEqual(quality.samples.columns.map { RNASeqBulkQuality.columnTitles[$0] ?? "<none>" }, [
            "Sample", "Library size", "Library size from", "Mapping rate (%)", "Library type", "Counted",
            "On rRNA genes (%)", "Not host (%)", "On globin genes (%)",
        ])
        XCTAssertEqual(quality.notes.count, 3, "the rule of each share, as the CLI's record states it")
        XCTAssertEqual(
            quality.notes[1], "Not host: Not recorded, since this result names no reference set that says which features are not host.",
            "the note under the table says what the Not host cells say, not that no feature is listed")
        XCTAssertTrue(quality.notes[0].hasPrefix("rRNA genes: annotated rRNA genes, the host genes whose biotype in genes.tsv is rRNA or Mt_rRNA"))
    }

    @MainActor
    func testTheNotHostNoteOfAResultOnASetKeepsTheRecord() async throws {
        let quality = try loaded(try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root)))
        XCTAssertEqual(quality.notes.count, 3)
        XCTAssertEqual(quality.notes[1], "Not host: the 1 feature that the manifest lists under notHost.")
    }

    @MainActor
    func testWhileTheQualityIsReadTheCaptionSaysSoAndThatTheTablesCanBeRead() throws {
        let url = try RNASeqBulkFixtures.writeNamed(into: root)
        guard case .loaded(let result) = RNASeqResultSurface.read(url) else { return XCTFail("the fixture did not load") }
        let controller = RNASeqBulkViewController(model: RNASeqBulkModel())
        controller.configure(result: result, bundleURL: url)
        _ = controller.view
        // A synchronous test never yields the main actor, so the read cannot end before the check.
        XCTAssertEqual(controller.model.quality, .loading)
        func caption(tab: Int, id: String) -> String? {
            RNASeqBulkFixtures.allSubviews(of: controller.tabView.tabViewItems[tab].view ?? NSView())
                .compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id }?.stringValue
        }
        let wait = "the count tables can be read meanwhile."
        XCTAssertEqual(caption(tab: 2, id: "rnaseq-bulk-quality-caption")?.hasSuffix(wait), true, "the Quality tab")
        XCTAssertEqual(caption(tab: 3, id: "rnaseq-bulk-correlation-caption")?.hasSuffix(wait), true, "the Correlation tab")
    }

    @MainActor
    func testThePlotsCaptionNamesTheMeasureAsTheCLIRecordNamesIt() async throws {
        let controller = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.importSalmonC1(into: root))
        let quality = try loaded(controller)
        let caption = quality.correlation.caption
        XCTAssertEqual(quality.correlationTable.facts["measure"], "Pearson r")
        XCTAssertEqual(quality.correlationTable.facts["transform"], "log2(CPM + 1)")
        XCTAssertEqual(caption, "Sample correlation of salmon-c1: Pearson r of log2(CPM + 1) over \(quality.correlation.geneCount) "
            + "features of counts/genes.counts.tsv that the manifest does not list under notHost, with a count above 0 in a sample.")
        let texts = RNASeqBulkFixtures.allSubviews(of: controller.tabView.tabViewItems[3].view ?? NSView())
            .compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(texts.contains(caption), "the caption sits over the plot")
        XCTAssertEqual(controller.correlationPlot.accessibilityLabel(), caption, "VoiceOver reads the caption as the plot's name")
    }

    @MainActor
    func testThePlotHasAKeyboardAndVoiceOverRoute() async throws {
        let controller = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root))
        let plot = controller.correlationPlot
        let quality = try loaded(controller)
        XCTAssertTrue(plot.acceptsFirstResponder)
        let children = try XCTUnwrap(plot.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 9)
        XCTAssertEqual(children[1].accessibilityLabel(), "S1 and S2")
        XCTAssertEqual(children[1].accessibilityValue() as? String, quality.correlationTable.rows[0][2])

        func press(_ key: Int, _ code: UInt16) throws {
            let characters = String(Character(try XCTUnwrap(UnicodeScalar(key))))
            plot.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        try press(NSDownArrowFunctionKey, 125)
        XCTAssertEqual(plot.selected?.row, 0)
        try press(NSRightArrowFunctionKey, 124)
        try press(NSDownArrowFunctionKey, 125)
        XCTAssertEqual(plot.selected.map { [$0.row, $0.column] }, [1, 1])
        try press(NSUpArrowFunctionKey, 126)
        let words = "S1 and S2: \(quality.correlationTable.rows[0][2])"
        XCTAssertEqual(plot.accessibilityValue() as? String, words, "VoiceOver reads the chosen cell")
        let chosen = RNASeqBulkFixtures.allSubviews(of: controller.tabView.tabViewItems[3].view ?? NSView())
            .compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "rnaseq-bulk-correlation-selected" }
        XCTAssertEqual(chosen?.stringValue, words, "the chosen cell's value shows in words under the plot")
        // The shade raises the alpha of a blue over the text background, so a higher value is a stronger blue in both
        // appearances and a darker square only on white.
        let scale = RNASeqBulkFixtures.allSubviews(of: controller.tabView.tabViewItems[3].view ?? NSView())
            .compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "rnaseq-bulk-correlation-scale" }
        XCTAssertEqual(
            scale?.stringValue,
            "On a scale from the lowest value of the table, "
                + "\(try XCTUnwrap(plot.lowestText)), to 1. A grey square reads Not recorded.")
    }

    /// 5.6 Q1. The accessibility elements of the Quality and Correlation tabs in the order VoiceOver reaches them, pinned at
    /// the base of lane TV-SCVIEW so that a later move of words can only replace an entry or add an info button.
    @MainActor
    func testTheQualityAndCorrelationTabsKeepTheirAccessibilityOrder() async throws {
        let controller = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root))
        func pane(_ id: String) throws -> NSView {
            try XCTUnwrap(controller.tabView.tabViewItems.first { ($0.identifier as? String) == id }?.view, id)
        }
        XCTAssertEqual(SCViewAXPin.elements(in: try pane("rnaseq-bulk-tab-quality")), [
            "rnaseq-bulk-quality-caption", "rnaseq-bulk-quality-table", "rnaseq-bulk-quality-notes",
        ])
        XCTAssertEqual(SCViewAXPin.elements(in: try pane("rnaseq-bulk-tab-correlation")), [
            "rnaseq-bulk-correlation-caption", "rnaseq-bulk-correlation-plot",
            "rnaseq-bulk-correlation-selected", "rnaseq-bulk-correlation-scale", "info-rnaseq.bulk.correlationColour",
        ])
    }

    /// 5.6 U2, U3 and UX OBJECT 6. The lowest value and the grey key stay in view at the scale, and the sentence on how to
    /// read the blue squares is one press behind the info button after them. The lane's decided words replace the literals.
    @MainActor
    func testTheScaleStaysInViewAndTheColourSentenceSitsBehindItsInfoButton() async throws {
        let controller = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.tabView.selectTabViewItem(at: controller.tabView.numberOfTabViewItems - 1)
        controller.view.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(controller.tabView.selectedTabViewItem?.view)
        let subviews = RNASeqBulkFixtures.allSubviews(of: pane)
        let button = try XCTUnwrap(subviews.compactMap { $0 as? LungfishInfoButton }.first, "the Correlation tab has its info button")
        addTeardownBlock { @MainActor in
            button.closePopover()
            window.orderOut(nil)
        }
        let scale = try XCTUnwrap(subviews.first { $0.accessibilityIdentifier() == "rnaseq-bulk-correlation-scale" } as? NSTextField)
        XCTAssertEqual(scale.stringValue, "On a scale from the lowest value of the table, "
            + "\(try XCTUnwrap(controller.correlationPlot.lowestText)), to 1. A grey square reads Not recorded.")
        for (view, name) in [(scale as NSView, "the scale line"), (button, "the info button")] {
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "\(name) is hidden")
            XCTAssertGreaterThan(view.bounds.width, 0, "\(name) has no width")
            XCTAssertTrue(pane.bounds.contains(view.convert(view.bounds, to: pane)), "\(name) lies outside the tab")
        }
        XCTAssertEqual(button.accessibilityIdentifier(), "info-rnaseq.bulk.correlationColour")
        XCTAssertEqual(button.accessibilityLabel(), "About the correlation squares")
        XCTAssertEqual(button.accessibilityHelp(), "A stronger blue square is a higher value.")
        XCTAssertFalse(button.refusesFirstResponder, "the button takes keyboard focus")
        _ = button.accessibilityPerformPress()
        XCTAssertTrue(button.isPopoverShown)
        XCTAssertEqual(button.popoverController.text, "A stronger blue square is a higher value.")
    }

    func testTheViewsHelpItemsPassTheCatalogCheck() {
        XCTAssertEqual(LungfishHelpContent.catalogFaults(in: RNASeqBulkHelp.items), [])
    }

    @MainActor
    func testAChangedFileShowsTheRefusalOfRNASeqQualityAndTheTableStillShows() async throws {
        let url = try RNASeqBulkFixtures.writeNamed(into: root)
        guard case .loaded(let result) = RNASeqResultSurface.read(url) else { return XCTFail("the fixture did not load") }
        let counts = url.appendingPathComponent("counts/genes.counts.tsv")
        try (try String(contentsOf: counts, encoding: .utf8) + "\n").write(to: counts, atomically: true, encoding: .utf8)
        let controller = RNASeqBulkViewController(model: RNASeqBulkModel())
        controller.configure(result: result, bundleURL: url)
        _ = controller.view
        await controller.model.qualityRead()
        controller.reloadFromModel()
        let words = RNASeqQualityRefusal.checksumsDiffer(name: "named.lungfishrnaseq", files: ["counts/genes.counts.tsv"]).localizedDescription
        XCTAssertEqual(controller.model.quality, .failed(words))
        XCTAssertEqual(controller.numberOfRows(in: controller.qualityTable), 0, "no number shows from a changed result")
        let texts = RNASeqBulkFixtures.allSubviews(of: controller.tabView.tabViewItems[2].view ?? NSView())
            .compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(texts.contains(words), "the quality tab shows the words of the refusal")
        XCTAssertEqual(controller.numberOfRows(in: controller.countTables[0]), 5, "the table the surface read still shows")
    }
}
