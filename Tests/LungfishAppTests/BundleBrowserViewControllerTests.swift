import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class BundleBrowserViewControllerTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bundleBrowserPanelLayout")
        super.tearDown()
    }

    func testSequenceTableHidesAlignmentColumnsWithoutMetricsAndShowsFASTAColumns() {
        let table = BundleBrowserSequenceTableView()
        table.configure(rows: makeSummaryWithoutMetrics().sequences)

        let columnsById = Dictionary(uniqueKeysWithValues: table.testTableView.tableColumns.map { ($0.identifier.rawValue, $0) })

        XCTAssertFalse(columnsById["contig"]?.isHidden ?? true)
        XCTAssertFalse(columnsById["length"]?.isHidden ?? true)
        XCTAssertFalse(columnsById["kind"]?.isHidden ?? true)
        XCTAssertFalse(columnsById["aliases"]?.isHidden ?? true)
        XCTAssertFalse(columnsById["description"]?.isHidden ?? true)
        XCTAssertTrue(columnsById["mappedReads"]?.isHidden ?? false)
        XCTAssertTrue(columnsById["mappedPercent"]?.isHidden ?? false)
    }

    func testSequenceTableUsesMappingViewportFontsForTextAndNumericColumns() {
        let table = BundleBrowserSequenceTableView()
        let row = makeSummaryWithoutMetrics().sequences[0]

        let textCell = table.cellContent(for: NSUserInterfaceItemIdentifier("contig"), row: row)
        let numericCell = table.cellContent(for: NSUserInterfaceItemIdentifier("length"), row: row)

        XCTAssertEqual(textCell.font, .systemFont(ofSize: 12))
        XCTAssertEqual(
            numericCell.font,
            .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )
    }

    func testConfigureSelectsFirstRowAndShowsDetail() {
        let vc = BundleBrowserViewController()
        _ = vc.view

        vc.configure(summary: makeSummary())

        XCTAssertEqual(vc.testDisplayedNames, ["chr1", "chrM"])
        XCTAssertEqual(vc.testSelectedName, "chr1")
        XCTAssertEqual(vc.testDetailLengthText, "200 bp")
    }

    func testFilterMatchesAliasAndDescription() {
        let vc = BundleBrowserViewController()
        _ = vc.view

        vc.configure(summary: makeSummary())
        vc.testSetFilterText("mitochondrion")
        XCTAssertEqual(vc.testDisplayedNames, ["chrM"])

        vc.testSetFilterText("  MT  ")
        XCTAssertEqual(vc.testDisplayedNames, ["chrM"])
    }

    func testOpenCallbackUsesSelectedRow() {
        let vc = BundleBrowserViewController()
        _ = vc.view
        var opened: String?
        vc.onOpenSequence = { opened = $0.name }
        vc.configure(summary: makeSummary())

        vc.testSelectRow(named: "chrM")
        vc.testInvokeOpen()

        XCTAssertEqual(opened, "chrM")
    }

    func testNoSelectionStateDisablesOpenAfterFilterRemovesAllRows() {
        let vc = BundleBrowserViewController()
        _ = vc.view

        vc.configure(summary: makeSummary())
        vc.testSetFilterText("no matches")
        vc.testInvokeOpen()

        XCTAssertNil(vc.testSelectedName)
        XCTAssertEqual(vc.testDetailLengthText, "")
        XCTAssertFalse(vc.testOpenButtonEnabled)
    }

    func testCaptureStateRestoresFilterSelectionAndScrollPosition() {
        let vc = BundleBrowserViewController()
        _ = vc.view
        vc.configure(summary: makeScrollableSummary())
        vc.view.layoutSubtreeIfNeeded()

        vc.testSetFilterText("chr")
        vc.testSelectRow(named: "chr18")
        vc.testSetScrollOriginY(44)

        let captured = vc.captureState()

        let restored = BundleBrowserViewController()
        _ = restored.view
        restored.configure(summary: makeScrollableSummary(), restoredState: captured)

        XCTAssertEqual(restored.testFilterText, "chr")
        XCTAssertEqual(restored.testSelectedName, "chr18")
        XCTAssertEqual(restored.testScrollOriginY, 44, accuracy: 0.5)
    }

    func testCaptureStateClearsSelectedSequenceWhenFilterHasNoMatches() {
        let vc = BundleBrowserViewController()
        _ = vc.view
        vc.configure(summary: makeSummary())

        vc.testSelectRow(named: "chrM")
        vc.testSetFilterText("no matches")

        let captured = vc.captureState()

        XCTAssertEqual(captured.filterText, "no matches")
        XCTAssertNil(captured.selectedSequenceName)
    }

    func testLayoutPreferenceCanPlaceDetailBeforeList() {
        UserDefaults.standard.set(
            BundleBrowserPanelLayout.detailLeading.rawValue,
            forKey: BundleBrowserPanelLayout.defaultsKey
        )

        let vc = BundleBrowserViewController()
        _ = vc.view
        vc.configure(summary: makeNarrowSummaryWithoutMetrics())

        XCTAssertTrue(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testDetailPane)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testListPane)
    }

    func testLayoutPreferenceCanStackListAboveDetail() {
        UserDefaults.standard.set(
            BundleBrowserPanelLayout.stacked.rawValue,
            forKey: BundleBrowserPanelLayout.defaultsKey
        )

        let vc = BundleBrowserViewController()
        _ = vc.view
        vc.configure(summary: makeNarrowSummaryWithoutMetrics())

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testListPane)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailPane)
    }

    func testListLeadingDefaultWidthFitsVisibleColumnsAndGivesRemainderToDetail() {
        UserDefaults.standard.set(
            BundleBrowserPanelLayout.listLeading.rawValue,
            forKey: BundleBrowserPanelLayout.defaultsKey
        )

        let vc = BundleBrowserViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1600, height: 700)
        vc.configure(summary: makeNarrowSummaryWithoutMetrics())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1600, height: 700))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let listWidth = vc.testListPane.frame.width
        let detailWidth = vc.testDetailPane.frame.width
        let visibleColumnsWidth = vc.testVisibleSequenceTableColumnWidth
        let debugContext = "view=\(vc.view.frame) inWindow=\(vc.view.window != nil) split=\(vc.testSplitView.frame) splitBounds=\(vc.testSplitView.bounds) detail=\(detailWidth) requested=\(String(describing: vc.testSplitView.requestedDividerPosition(at: 0)))"

        XCTAssertGreaterThanOrEqual(listWidth, visibleColumnsWidth, debugContext)
        XCTAssertLessThan(listWidth, 560, debugContext)
        XCTAssertGreaterThan(detailWidth, listWidth * 1.8, debugContext)
    }

    func testLiveResizeDelegatePreservesUserMovedVerticalDivider() {
        UserDefaults.standard.set(
            BundleBrowserPanelLayout.listLeading.rawValue,
            forKey: BundleBrowserPanelLayout.defaultsKey
        )

        let vc = BundleBrowserViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        vc.configure(summary: makeSummary())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testListPane.frame.width
        let minimumLeadingWidth: CGFloat = 260
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition = maximumLeadingWidth - initialWidth >= 120
            ? initialWidth + 140
            : max(minimumLeadingWidth, initialWidth - 160)
        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        vc.splitViewDidResizeSubviews(Notification(name: .init("TestBundleSplitResize"), object: vc.testSplitView))

        let movedWidth = vc.testListPane.frame.width
        XCTAssertGreaterThan(Swift.abs(movedWidth - initialWidth), CGFloat(80))

        let oldSize = vc.testSplitView.frame.size
        vc.testSplitView.setFrameSize(NSSize(width: oldSize.width + 180, height: oldSize.height))
        invokeOptionalSplitResizeDelegate(on: vc, splitView: vc.testSplitView, oldSize: oldSize)

        XCTAssertEqual(vc.testListPane.frame.width, movedWidth, accuracy: 2)
    }

    private func makeSummary() -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: 1,
                variantTrackCount: 0,
                alignmentTrackCount: 1,
                totalMappedReads: 300
            ),
            sequences: [
                BundleBrowserSequenceSummary(
                    name: "chr1",
                    displayDescription: "primary contig",
                    length: 200,
                    aliases: ["1"],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: .init(
                        mappedReads: 220,
                        mappedPercent: 73.3,
                        meanDepth: 11.2,
                        coverageBreadth: 97.1,
                        medianMAPQ: 60.0,
                        meanIdentity: 99.1
                    )
                ),
                BundleBrowserSequenceSummary(
                    name: "chrM",
                    displayDescription: "mitochondrion",
                    length: 80,
                    aliases: ["MT"],
                    isPrimary: false,
                    isMitochondrial: true,
                    metrics: .init(
                        mappedReads: 80,
                        mappedPercent: 26.7,
                        meanDepth: 42.0,
                        coverageBreadth: 100.0,
                        medianMAPQ: 60.0,
                        meanIdentity: 99.9
                    )
                )
            ]
        )
    }

    private func makeSummaryWithoutMetrics() -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: 1,
                variantTrackCount: 0,
                alignmentTrackCount: 0,
                totalMappedReads: nil
            ),
            sequences: [
                BundleBrowserSequenceSummary(
                    name: "chr1",
                    displayDescription: "primary contig",
                    length: 200,
                    aliases: ["1"],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: nil
                ),
                BundleBrowserSequenceSummary(
                    name: "chrM",
                    displayDescription: "mitochondrion",
                    length: 80,
                    aliases: ["MT"],
                    isPrimary: false,
                    isMitochondrial: true,
                    metrics: nil
                )
            ]
        )
    }

    private func makeNarrowSummaryWithoutMetrics() -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: 1,
                variantTrackCount: 0,
                alignmentTrackCount: 0,
                totalMappedReads: nil
            ),
            sequences: [
                BundleBrowserSequenceSummary(
                    name: "MF0214_2__h2tg000003l_28523125_35203480",
                    displayDescription: nil,
                    length: 6_680_356,
                    aliases: [],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: nil
                )
            ]
        )
    }

    private func makeScrollableSummary() -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: 1,
                variantTrackCount: 0,
                alignmentTrackCount: 1,
                totalMappedReads: 300
            ),
            sequences: (1...40).map { index in
                BundleBrowserSequenceSummary(
                    name: "chr\(index)",
                    displayDescription: "contig \(index)",
                    length: Int64(index) * 100,
                    aliases: ["\(index)"],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: nil
                )
            }
        )
    }

    private func invokeOptionalSplitResizeDelegate(
        on controller: NSObject,
        splitView: NSSplitView,
        oldSize: NSSize
    ) {
        let selector = NSSelectorFromString("splitView:resizeSubviewsWithOldSize:")
        XCTAssertTrue(controller.responds(to: selector), "Expected custom split live-resize delegate")
        guard let method = controller.method(for: selector) else { return XCTFail("Missing split resize delegate method") }
        typealias ResizeIMP = @convention(c) (AnyObject, Selector, NSSplitView, NSSize) -> Void
        unsafeBitCast(method, to: ResizeIMP.self)(controller, selector, splitView, oldSize)
    }
}
