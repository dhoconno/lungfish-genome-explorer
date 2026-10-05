// MSADistanceMatrixPaneTests.swift - pane model and pane view (rulings P1, P5, P8, U7, U8, U10)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishIO
import LungfishKit
import LungfishTestSupport

/// Holds a compute call until the test opens it.
actor ComputeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class MSADistanceMatrixPaneTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "MSADistanceMatrixPaneTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let records = [
        MSAAlignedRecord(name: "alpha", sequence: "ACGTACGTAC"),
        MSAAlignedRecord(name: "beta", sequence: "ACGTACGTTT"),
        MSAAlignedRecord(name: "gamma", sequence: "ACGAACGTAC"),
    ]

    // MARK: Model

    func testStaleResultForOldOptionsIsDropped() async throws {
        let gate = ComputeGate()
        let model = MSADistanceMatrixPaneModel(defaults: defaults, compute: { records, options in
            if options.model == .identity {
                await gate.wait()
            }
            return try MSADistanceMatrix(records: records, options: options)
        })
        model.load(records: records, alphabet: .nucleotide)
        XCTAssertEqual(model.status, .computing)
        model.model = .pDistance
        await waitUntil { model.status == .ready }
        XCTAssertEqual(model.matrix?.options.model, .pDistance)

        await gate.open()
        await waitUntil { model.droppedResultCount == 1 }
        XCTAssertEqual(model.droppedResultCount, 1)
        XCTAssertEqual(model.matrix?.options.model, .pDistance, "the identity result arrived late and was dropped")
        XCTAssertEqual(model.status, .ready)
    }

    func testOptionsPersistGloballyAndFallBackForTheAlphabet() {
        let first = MSADistanceMatrixPaneModel(defaults: defaults)
        first.model = .k2p
        first.gaps = .complete
        first.order = .averageLinkage
        first.fixedUnitRange = true
        first.showsValues = false
        XCTAssertEqual(defaults.string(forKey: "msaDistanceMatrix.model"), "k2p")
        XCTAssertEqual(defaults.string(forKey: "msaDistanceMatrix.gaps"), "complete")
        XCTAssertEqual(defaults.string(forKey: "msaDistanceMatrix.order"), "average-linkage")

        let second = MSADistanceMatrixPaneModel(defaults: defaults)
        XCTAssertEqual(second.model, .k2p)
        XCTAssertEqual(second.gaps, .complete)
        XCTAssertEqual(second.order, .averageLinkage)
        XCTAssertTrue(second.fixedUnitRange)
        XCTAssertFalse(second.showsValues)
        XCTAssertFalse(second.isFixedUnitRangeAvailable, "k2p is a corrected distance")
        XCTAssertFalse(second.usesFixedUnitRange)

        second.load(records: [], alphabet: .protein)
        XCTAssertFalse(second.availableModels.contains(.k2p))
        XCTAssertEqual(second.effectiveModel, .identity)
        XCTAssertEqual(second.options.model, .identity)
        XCTAssertEqual(second.options.alphabet, .protein)
    }

    func testTooManyRowsSkipsComputeButKeepsExport() async {
        let model = MSADistanceMatrixPaneModel(defaults: defaults, compute: { _, _ in
            XCTFail("compute must not run over the inline limit")
            throw CancellationError()
        })
        model.maxRowsForInlineMatrix = 2
        model.load(records: records, alphabet: .nucleotide)
        XCTAssertEqual(model.status, .tooManyRows(3))
        XCTAssertTrue(model.canExport)
        XCTAssertNil(model.matrix)
    }

    func testComputeFailureIsReported() async {
        let model = MSADistanceMatrixPaneModel(defaults: defaults)
        model.gaps = .complete
        model.load(records: [
            MSAAlignedRecord(name: "a", sequence: "A-"),
            MSAAlignedRecord(name: "b", sequence: "-A"),
        ], alphabet: .nucleotide)
        await waitUntil { if case .failed = model.status { return true } else { return false } }
        guard case .failed(let message) = model.status else { return XCTFail("expected failure, got \(model.status)") }
        XCTAssertFalse(message.isEmpty)
    }

    func testLoadBundleUsesTheInjectedLoaderOffMain() async {
        let records = self.records
        let model = MSADistanceMatrixPaneModel(defaults: defaults, loadRecords: { _ in records })
        model.load(bundleURL: URL(fileURLWithPath: "/tmp/none.lungfishmsa"), alphabet: .nucleotide)
        await waitUntil { model.status == .ready }
        XCTAssertEqual(model.matrix?.names, ["alpha", "beta", "gamma"])
    }

    // MARK: Pane view

    private func readyPane(order: MSADistanceOrder = .alignment, pasteboard: RecordingPasteboard = RecordingPasteboard()) async -> MSADistanceMatrixPaneView {
        let model = MSADistanceMatrixPaneModel(defaults: defaults)
        model.order = order
        let pane = MSADistanceMatrixPaneView(pasteboard: pasteboard, model: model)
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        pane.load(records: records, alphabet: .nucleotide)
        await waitUntil { model.status == .ready }
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    func testCopyMatrixEqualsTheMatrixTSV() async throws {
        let pasteboard = RecordingPasteboard()
        let pane = await readyPane(order: .averageLinkage, pasteboard: pasteboard)
        let expected = try MSADistanceMatrix(records: records, options: pane.model.options).tsv
        pane.gridView.copyMatrix(nil)
        XCTAssertEqual(pasteboard.strings, [expected])
        XCTAssertEqual(pane.matrixTSV, expected)
    }

    func testCallbacksUseRecordIndicesThroughTheOrderPermutation() async throws {
        let pane = await readyPane(order: .averageLinkage)
        let matrix = try XCTUnwrap(pane.model.matrix)
        var revealed: (Int, Int)?
        var selected: IndexSet?
        var focused: (MSAPairDetail?, String, String)?
        pane.onRevealPair = { revealed = ($0, $1) }
        pane.onSequencesSelected = { selected = $0 }
        pane.onFocusedPairChanged = { focused = ($0, $1, $2) }

        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 0, column: 1)) }
        XCTAssertEqual(selected, IndexSet([matrix.recordIndices[0], matrix.recordIndices[1]]))
        XCTAssertEqual(focused?.1, matrix.names[0])
        XCTAssertEqual(focused?.2, matrix.names[1])
        XCTAssertEqual(focused?.0, matrix.detail(row: 0, column: 1))
        XCTAssertTrue(pane.footerLabel.stringValue.hasPrefix("\(matrix.names[0]) vs \(matrix.names[1]), identity "))

        pane.gridView.revealPairInAlignment(nil)
        XCTAssertEqual(revealed?.0, matrix.recordIndices[0])
        XCTAssertEqual(revealed?.1, matrix.recordIndices[1])
    }

    func testReverseSyncMapsRecordIndicesToDisplayRows() async throws {
        let pane = await readyPane(order: .averageLinkage)
        let matrix = try XCTUnwrap(pane.model.matrix)
        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 0, column: 0)) }
        pane.reflectAlignmentSelection(IndexSet([2]))
        let position = try XCTUnwrap(matrix.recordIndices.firstIndex(of: 2))
        XCTAssertTrue(pane.gridView.selection.cells.isEmpty)
        XCTAssertEqual(pane.gridView.selection.selectedSequences, IndexSet([position]))
        XCTAssertEqual(pane.rowHeaderView.selectedSequences, IndexSet([position]))
    }

    func testExportPassesTheOnScreenOptions() async {
        let pane = await readyPane(order: .averageLinkage)
        var exported: MSADistanceOptions?
        pane.onExportRequested = { exported = $0 }
        pane.gridView.exportDistanceMatrix(nil)
        XCTAssertEqual(exported, MSADistanceOptions(model: .identity, gaps: .pairwise, order: .averageLinkage, alphabet: .nucleotide))
    }

    func testModelPopupListsOnlyModelsValidForTheAlphabet() async {
        let model = MSADistanceMatrixPaneModel(defaults: defaults)
        let pane = MSADistanceMatrixPaneView(pasteboard: RecordingPasteboard(), model: model)
        pane.load(records: [MSAAlignedRecord(name: "p1", sequence: "MKV"), MSAAlignedRecord(name: "p2", sequence: "MKL")], alphabet: .protein)
        XCTAssertEqual(pane.modelPopup.itemTitles, MSADistanceModel.models(for: .protein).map(\.displayName))
        XCTAssertFalse(pane.modelPopup.itemTitles.contains(MSADistanceModel.k2p.displayName))
        pane.modelPopup.selectItem(withTitle: MSADistanceModel.poisson.displayName)
        pane.modelPopup.sendAction(pane.modelPopup.action, to: pane.modelPopup.target)
        XCTAssertEqual(model.model, .poisson)
        XCTAssertFalse(pane.fixedRangeCheckbox.isEnabled)
        XCTAssertEqual(pane.fixedRangeCheckbox.accessibilityHelp(), MSADistanceMatrixPaneView.fixedRangeUnavailableHelp)
    }

    func testTooManyRowsShowsMessageAndExportButton() {
        let model = MSADistanceMatrixPaneModel(defaults: defaults)
        let pane = MSADistanceMatrixPaneView(pasteboard: RecordingPasteboard(), model: model)
        pane.maxRowsForInlineMatrix = 2
        pane.load(records: records, alphabet: .nucleotide)
        XCTAssertFalse(pane.statusStack.isHidden)
        XCTAssertEqual(
            pane.statusLabel.stringValue,
            "This alignment has 3 sequences. The matrix shows up to 2. Export computes the full matrix."
        )
        XCTAssertFalse(pane.statusExportButton.isHidden)
        XCTAssertTrue(pane.scrollView.isHidden)
    }

    func testKeyViewOrderEndsAtTheGrid() {
        let pane = MSADistanceMatrixPaneView(pasteboard: RecordingPasteboard(), model: MSADistanceMatrixPaneModel(defaults: defaults))
        var order: [NSView] = [pane.modelPopup]
        while let next = order.last?.nextKeyView, order.count < 12 { order.append(next) }
        XCTAssertTrue(order.last === pane.gridView)
        XCTAssertTrue(order[1] === pane.gapsPopup)
        XCTAssertTrue(order[2] === pane.orderPopup)
    }

    func testLegendIsOneStaticText() async {
        let pane = await readyPane()
        XCTAssertEqual(pane.legendView.accessibilityRole(), .staticText)
        let label = pane.legendView.accessibilityLabel() ?? ""
        XCTAssertTrue(label.hasPrefix("Colour scale, identity, "))
        XCTAssertTrue(label.hasSuffix("n/a means no comparable sites. Infinity means saturated."))
    }

    func testTypographyChangeRelayoutsGridAndHeaders() async {
        let pane = await readyPane()
        let provider = FixedSizeFontProvider(pointSize: 13)
        pane.contentPreferredFontProvider = provider
        pane.applyTypography()
        let side = pane.gridView.cellSide
        let count = pane.typographyApplicationCount
        provider.pointSize = 26
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.typographyApplicationCount, count + 1)
        XCTAssertGreaterThan(pane.gridView.cellSide, side)
        XCTAssertEqual(pane.rowHeaderView.cellSide, pane.gridView.cellSide)
        XCTAssertEqual(pane.columnHeaderView.cellSide, pane.gridView.cellSide)
    }
}

final class MSADistanceValueFormatParityTests: XCTestCase {
    func testFullFormatMatchesTheCLIFormatter() {
        for value in [0.0, 1.0, 0.9985123, 0.123456789, Double.nan, Double.infinity] {
            XCTAssertEqual(MSADistanceValueFormat.full(value), MSADistanceMatrix.formatValue(value))
        }
    }
}
