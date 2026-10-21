// TaxTriageDatabaseModeTests.swift - Database-mode actions, overview grid and sample stepping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every production TaxTriage result opens through `configureFromDatabase`.
// These tests cover the actions that used to depend on the never-set
// `taxTriageResult` / `taxTriageConfig` / `metrics` in that mode, the
// organism-by-sample overview grid, View > Next/Previous/All Samples, the
// flat table's contamination flags and confidence tooltips, the action bar
// BLAST popover, and the alignment pane after a Sample Filter change.

import XCTest
import AppKit
import SwiftUI
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit
import LungfishTestSupport

@MainActor
private final class RecordingEvidenceViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []
    override init() {
        super.init()
        // Like the App's detached viewer, whose header gives its view a
        // required minimum height, this view cannot shrink below 31 pt.
        // (The App-level TaxTriageSampleFilterAlignmentPaneTests drives the
        // real viewer, which is what reproduced the stuck 31 pt pane.)
        let view = NSView()
        let chrome = NSView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: view.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chrome.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 31),
        ])
        viewController.view = view
    }
    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() {}
}

/// A project-window stand-in that owns a scope, so a viewport shown in its window
/// accepts window events that carry it. LungfishKitTestSupport has the shared copy,
/// but this test target does not link it.
@MainActor
private final class ProjectWindowStandIn: NSWindowController, WindowStateScopeOwner {
    let windowStateScope = WindowStateScope()
}

@MainActor
final class TaxTriageDatabaseModeTests: XCTestCase {

    // MARK: - 1. Sidecar-driven actions

    func testSidecarIsLoadedAndRelocatedOntoTheResultFolder() throws {
        let fixture = try Fixture(writeSidecar: true, storedOutputDirectory: "/Volumes/Elsewhere/old-run")
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let result = try XCTUnwrap(vc.testResult, "configureFromDatabase must load taxtriage-result.json")
        XCTAssertEqual(result.outputDirectory.standardizedFileURL.path, fixture.root.standardizedFileURL.path)
        XCTAssertEqual(
            result.reportFiles.map { $0.standardizedFileURL.path },
            [fixture.root.appendingPathComponent("sample-1/report/sample-1.odr.pdf").standardizedFileURL.path]
        )
        XCTAssertEqual(result.config.samples.map(\.sampleId), ["sample-1", "sample-2"])
    }

    func testOpenReportOpensTheSelectedRowsSamplePDFThenHTML() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        var opened: [URL] = []
        vc.reportOpener = { opened.append($0) }

        let sample2Row = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex { $0.sample == "sample-2" })
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(sample2Row)
        vc.testingOpenReportButton.performClick(nil)
        XCTAssertEqual(opened.last?.lastPathComponent, "sample-2.odr.html", "sample-2 has only an HTML report")

        let sample1Row = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex { $0.sample == "sample-1" })
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(sample1Row)
        vc.testingOpenReportButton.performClick(nil)
        XCTAssertEqual(
            opened.last?.standardizedFileURL.path,
            fixture.root.appendingPathComponent("sample-1/report/sample-1.odr.pdf").standardizedFileURL.path
        )
    }

    func testCopySummaryProvenanceAndBatchReportWorkFromTheSidecar() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let summary = try XCTUnwrap(vc.summaryTextForCopy())
        XCTAssertTrue(summary.contains("TaxTriage pipeline completed successfully"), summary)
        XCTAssertTrue(summary.contains("Samples shown: 2 of 2 (sample-1, sample-2)"), summary)
        XCTAssertTrue(summary.contains("Organism rows shown: 4"), summary)

        let menu = vc.buildExportMenu()
        let reportItem = try XCTUnwrap(menu.items.first { $0.title == "Export Batch Report\u{2026}" })
        XCTAssertTrue(vc.validateMenuItem(reportItem))
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Copy Summary" })
        XCTAssertTrue(vc.validateMenuItem(copyItem))
    }

    func testBatchReportIsDisabledWithoutASidecar() throws {
        let fixture = try Fixture(writeSidecar: false)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        XCTAssertNil(vc.testResult)
        let reportItem = try XCTUnwrap(vc.buildExportMenu().items.first { $0.title == "Export Batch Report\u{2026}" })
        XCTAssertFalse(vc.validateMenuItem(reportItem))
        XCTAssertNotNil(vc.summaryTextForCopy(), "Copy Summary still describes the database rows")
    }

    func testDelimitedExportWritesTheFlatTableRows() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let table = vc.testBatchFlatTableView
        let tsv = TaxTriageResultsExport.buildDelimitedExport(
            rows: table.displayedRows,
            totalReadsByKey: table.totalReadsByKey,
            uniqueReadsByKey: table.uniqueReadsByKey,
            contaminationRiskOrganismKeys: table.contaminationRiskOrganismKeys,
            metadataHeaders: [],
            metadataValuesBySample: [:],
            separator: "\t"
        )
        let lines = tsv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, tsv)
        XCTAssertEqual(
            lines[0],
            "Sample\tOrganism\tTASS Score\tReads\tUnique Reads\tCoverage\tConfidence\tTax ID\tRank\tAbundance\tContamination Risk"
        )
        XCTAssertTrue(lines.contains { $0.hasPrefix("sample-1\tAlpha virus\t0.9100\t42\t21\t") }, tsv)

        XCTAssertEqual(table.displayedRows.count, 4)
        let csvItem = try XCTUnwrap(vc.buildExportMenu().items.first { $0.title == "Export as CSV\u{2026}" })
        XCTAssertTrue(vc.validateMenuItem(csvItem))
    }

    // MARK: - 2. Overview grid, segmented filter, flat-table flags

    func testAllSamplesShowsTheOverviewGridAndChoosingItAgainReturnsToTheList() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        XCTAssertFalse(vc.testSampleFilterControl.isHidden, "two samples show the segmented sample filter")
        XCTAssertEqual(vc.testSampleFilterControl.segmentCount, 3)
        XCTAssertEqual(vc.testSampleFilterControl.label(forSegment: 0), "All Samples")
        XCTAssertEqual(vc.testSampleFilterControl.selectedSegment, -1, "a multi-sample list selects no segment")

        vc.selectAllSamplesOverview(nil)
        fixture.waitForRows(vc) { $0.count == 4 }

        XCTAssertTrue(vc.isShowingDatabaseOverview)
        XCTAssertFalse(vc.testBatchOverviewView.isHidden)
        XCTAssertTrue(vc.testBatchFlatTableView.isHidden)
        XCTAssertEqual(vc.testSampleFilterControl.selectedSegment, 0)
        XCTAssertNotNil(vc.testBatchOverviewView.testingRowIndex(organism: "Alpha virus"))
        XCTAssertEqual(vc.testBatchOverviewView.testingSampleCountLabel(row: 0), "2/2")

        let allItem = NSMenuItem(title: "All Samples", action: #selector(TaxTriageResultViewController.selectAllSamplesOverview(_:)), keyEquivalent: "0")
        XCTAssertTrue(vc.validateMenuItem(allItem))
        XCTAssertEqual(allItem.state, .on)

        vc.selectAllSamplesOverview(nil)
        XCTAssertFalse(vc.isShowingDatabaseOverview)
        XCTAssertTrue(vc.testBatchOverviewView.isHidden)
        XCTAssertFalse(vc.testBatchFlatTableView.isHidden)
        XCTAssertTrue(vc.validateMenuItem(allItem))
        XCTAssertEqual(allItem.state, .off)
    }

    func testSampleSegmentTicksOneSampleInTheInspectorFilter() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        vc.testSampleFilterControl.selectedSegment = 2
        _ = vc.testSampleFilterControl.sendAction(vc.testSampleFilterControl.action, to: vc.testSampleFilterControl.target)
        fixture.waitForRows(vc) { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-2" } }

        XCTAssertEqual(vc.samplePickerState.selectedSamples, ["sample-2"])
        XCTAssertEqual(Set(vc.testBatchFlatTableView.displayedRows.map(\.organism)), ["Gamma virus", "Alpha virus"])
        XCTAssertEqual(vc.testSampleFilterControl.selectedSegment, 2)
    }

    func testOverviewValueOpensThatSampleAndSelectsTheOrganism() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        vc.selectAllSamplesOverview(nil)

        vc.testBatchOverviewView.onCellSelected?("Alpha virus", "sample-2")
        fixture.waitForRows(vc) { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-2" } }

        XCTAssertFalse(vc.isShowingDatabaseOverview)
        XCTAssertEqual(vc.samplePickerState.selectedSamples, ["sample-2"])
        XCTAssertEqual(vc.testBatchFlatTableView.selectedMetrics().map(\.organism), ["Alpha virus"])
    }

    func testFlatTableFlagsNegativeControlOrganismsAndUsesConfidenceColumnTooltips() throws {
        let fixture = try Fixture(writeSidecar: true, negativeControl: "sample-2")
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        let table = vc.testBatchFlatTableView
        let deadline = Date().addingTimeInterval(30)
        while table.contaminationRiskOrganismKeys.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let alpha = try XCTUnwrap(table.displayedRows.firstIndex { $0.sample == "sample-1" && $0.organism == "Alpha virus" })
        let beta = try XCTUnwrap(table.displayedRows.firstIndex { $0.organism == "Beta virus" })
        XCTAssertEqual(table.testCellText(row: alpha, columnID: "tt_organism").primary, "\u{26A0} Alpha virus")
        XCTAssertEqual(table.testCellText(row: beta, columnID: "tt_organism").primary, "Beta virus")
        XCTAssertEqual(
            table.cellToolTip(for: NSUserInterfaceItemIdentifier("tt_organism"), row: table.displayedRows[alpha]),
            "Contamination risk: detected in negative control sample\nAlpha virus"
        )
        XCTAssertEqual(table.cellTextColor(for: NSUserInterfaceItemIdentifier("tt_organism"), row: table.displayedRows[alpha]), .systemOrange)

        // Beta: TASS 0.76 labelled High by TaxTriage's threshold call. The
        // tooltip must agree with the Confidence column, not the 0.80 band.
        let betaTip = table.cellToolTip(for: NSUserInterfaceItemIdentifier("tt_tassScore"), row: table.displayedRows[beta])
        XCTAssertEqual(betaTip, "High confidence: passes TaxTriage's TASS threshold. Strong taxonomic signal.")
        XCTAssertEqual(table.testCellText(row: beta, columnID: "tt_confidence").primary, "High")
    }

    /// The TASS Score header must describe the rule the cells apply (the
    /// row's own TaxTriage call first, fixed bands only as a fallback), and
    /// both TASS Score columns must share it.
    func testTassScoreHeaderTooltipStatesTheThresholdRule() throws {
        let tip = TaxTriageConfidenceBand.headerToolTip
        XCTAssertTrue(tip.contains("TaxTriage's own High / Medium / Low call"))
        XCTAssertTrue(tip.contains("threshold"))
        XCTAssertTrue(tip.contains("High below 0.80"))
        XCTAssertTrue(tip.contains("Rows without a call fall back to fixed bands"))
        XCTAssertTrue(tip.contains("0.40 to 0.80 Medium"))

        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let batchColumn = try XCTUnwrap(
            vc.testBatchFlatTableView.testTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("tt_tassScore"))
        )
        XCTAssertEqual(batchColumn.headerToolTip, tip)

        let organismColumn = try XCTUnwrap(
            vc.testOrganismTableView.testingTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("tassScore"))
        )
        XCTAssertEqual(organismColumn.headerToolTip, tip)
    }

    func testConfidenceBandFollowsTheLabelAndFallsBackToScoreBands() {
        XCTAssertEqual(TaxTriageConfidenceBand(label: "High", tassScore: 0.75), .high)
        XCTAssertEqual(TaxTriageConfidenceBand(label: "Medium", tassScore: 0.79), .medium)
        XCTAssertEqual(TaxTriageConfidenceBand(label: nil, tassScore: 0.79), .medium)
        XCTAssertEqual(TaxTriageConfidenceBand(label: nil, tassScore: 0.80), .high)
        XCTAssertEqual(TaxTriageConfidenceBand(label: nil, tassScore: 0.39), .low)
        XCTAssertEqual(
            TaxTriageConfidenceBand.toolTip(label: nil, tassScore: 0.85),
            "High confidence (TASS 0.80 or higher): strong taxonomic signal."
        )
        XCTAssertEqual(
            TaxTriageConfidenceBand.toolTip(label: "Low", tassScore: 0.1),
            "Low confidence (TASS below 0.40): weak signal, may be noise or contamination."
        )
    }

    // MARK: - 3. View > Next / Previous / All Samples

    func testSampleSteppingDrivesTheInspectorSampleFilterAndValidates() throws {
        let fixture = try Fixture(writeSidecar: true)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        let next = NSMenuItem(title: "Next Sample", action: #selector(TaxTriageResultViewController.selectNextSample(_:)), keyEquivalent: "]")
        let previous = NSMenuItem(title: "Previous Sample", action: #selector(TaxTriageResultViewController.selectPreviousSample(_:)), keyEquivalent: "[")

        XCTAssertTrue(vc.validateMenuItem(next))
        XCTAssertTrue(vc.validateMenuItem(previous))

        vc.selectNextSample(nil)
        fixture.waitForRows(vc) { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-1" } }
        XCTAssertEqual(vc.samplePickerState.selectedSamples, ["sample-1"])
        XCTAssertFalse(vc.validateMenuItem(previous), "sample-1 is the first sample")
        XCTAssertTrue(vc.validateMenuItem(next))
        XCTAssertTrue(vc.testBatchOverviewView.isHidden, "stepping never shows the overview grid")

        vc.selectNextSample(nil)
        fixture.waitForRows(vc) { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-2" } }
        XCTAssertEqual(vc.samplePickerState.selectedSamples, ["sample-2"])
        XCTAssertFalse(vc.validateMenuItem(next), "sample-2 is the last sample")
        XCTAssertTrue(vc.validateMenuItem(previous))

        vc.selectPreviousSample(nil)
        fixture.waitForRows(vc) { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-1" } }
        XCTAssertEqual(vc.samplePickerState.selectedSamples, ["sample-1"])
        XCTAssertEqual(vc.testSummaryBar.cards.first { $0.label == "Organisms" }?.value, "2")
    }

    func testSampleSteppingIsDisabledForASingleSampleResult() throws {
        let fixture = try Fixture(writeSidecar: false, samples: ["sample-1"])
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        for action in [
            #selector(TaxTriageResultViewController.selectNextSample(_:)),
            #selector(TaxTriageResultViewController.selectPreviousSample(_:)),
            #selector(TaxTriageResultViewController.selectAllSamplesOverview(_:)),
        ] {
            XCTAssertFalse(vc.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        vc.selectAllSamplesOverview(nil)
        XCTAssertFalse(vc.isShowingDatabaseOverview)
        XCTAssertTrue(vc.testBatchOverviewView.isHidden)
        XCTAssertFalse(vc.testBatchFlatTableView.isHidden)
    }

    // MARK: - 4. Action bar BLAST Verify opens the read-count popover

    func testActionBarBlastVerifyOpensTheReadCountPopoverInsteadOfSubmitting() throws {
        let fixture = try Fixture(writeSidecar: false)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        var submitted: [Int] = []
        vc.onBlastVerification = { _, readCount, _, _, _ in submitted.append(readCount) }
        var presented: (taxon: String, reads: Int, anchor: NSView, onRun: (Int) -> Void)?
        vc.blastConfigPopoverPresenter = { taxon, reads, anchor, onRun in
            presented = (taxon, reads, anchor, onRun)
        }

        let alpha = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex { $0.organism == "Alpha virus" && $0.sample == "sample-1" })
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(alpha)
        vc.testActionBar.blastButton.performClick(nil)

        XCTAssertEqual(submitted, [], "BLAST Verify must not submit before the user confirms a read count")
        let popover = try XCTUnwrap(presented)
        XCTAssertEqual(popover.taxon, "Alpha virus")
        XCTAssertEqual(popover.reads, 42)
        XCTAssertTrue(popover.anchor === vc.testActionBar.blastButton)

        popover.onRun(20)
        XCTAssertEqual(submitted, [20])
    }

    func testActionBarBlastVerifyDefaultPresenterShowsTheSharedPopover() throws {
        let fixture = try Fixture(writeSidecar: false)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        var submitted: [Int] = []
        vc.onBlastVerification = { _, readCount, _, _, _ in submitted.append(readCount) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()

        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(0)
        vc.testActionBar.blastButton.performClick(nil)

        let popover = try XCTUnwrap(vc.activeBlastConfigPopover)
        XCTAssertTrue(popover.contentViewController is NSHostingController<BlastConfigPopoverView>)
        XCTAssertEqual(submitted, [])
        popover.close()
    }

    // MARK: - 5. Alignment pane after a Sample Filter change (List Over Detail)

    func testSampleFilterChangeKeepsTheAlignmentPaneDrawableForTheSelectedRow() throws {
        let fixture = try Fixture(writeSidecar: false)
        defer { fixture.cleanUp() }
        let defaults = makeTestDefaultsSuite(prefix: "TaxTriageDatabaseModeTests").defaults
        defaults.set(MetagenomicsPanelLayout.stacked.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)

        let recorder = RecordingEvidenceViewer()
        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = defaults
        vc.classifierAlignmentViewerFactory = { recorder }
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        // The viewport observes the sample selection of the project window that shows it.
        let projectWindow = ProjectWindowStandIn(window: window)
        window.contentViewController = vc
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            withExtendedLifetime(projectWindow) {}
        }
        vc.configureFromDatabase(fixture.database, resultURL: fixture.root)
        window.layoutIfNeeded()
        fixture.waitForRows(vc) { $0.count == 4 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        func selectAndAssert(sample: String, organism: String, contig: String, _ context: String) throws {
            let index = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex {
                $0.sample == sample && $0.organism == organism
            }, context)
            vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            window.layoutIfNeeded()
            vc.view.layoutSubtreeIfNeeded()
            // The request can arrive after a detached BAM-length read, so wait for
            // it instead of a fixed spin; the loop ends as soon as it is recorded.
            let requestDeadline = Date().addingTimeInterval(30)
            while Date() < requestDeadline,
                  recorder.requests.last.map({ $0.bamURL != fixture.bamURL(for: sample) || $0.contig.name != contig }) ?? true {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()

            let request = try XCTUnwrap(recorder.requests.last, context)
            XCTAssertEqual(request.bamURL, fixture.bamURL(for: sample), context)
            XCTAssertEqual(request.contig.name, contig, context)
            let evidenceView = try XCTUnwrap(vc.testingEvidenceView, context)
            XCTAssertTrue(evidenceView.isDescendant(of: vc.testLeftPaneContainer), context)
            XCTAssertFalse(evidenceView.isHiddenOrHasHiddenAncestor, context)
            XCTAssertFalse(vc.testingIsDetailPaneCollapsed, context)
            XCTAssertGreaterThanOrEqual(
                vc.testingDetailPaneExtent, 250,
                "\(context): the alignment pane must be re-expanded, not left at a sliver"
            )
            XCTAssertGreaterThanOrEqual(evidenceView.frame.height, 250, context)
        }

        try selectAndAssert(sample: "sample-1", organism: "Alpha virus", contig: "NC_1001", "before the filter change")

        // Untick sample-2 in the Inspector Sample Filter.
        vc.samplePickerState.selectedSamples = ["sample-1"]
        NotificationCenter.default.post(
            name: .metagenomicsSampleSelectionChanged,
            object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: projectWindow.windowStateScope)
        )
        fixture.waitForRows(vc) { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-1" } }
        try selectAndAssert(sample: "sample-1", organism: "Beta virus", contig: "NC_1002", "after unticking a sample")
        try selectAndAssert(sample: "sample-1", organism: "Alpha virus", contig: "NC_1001", "after reselecting a row")

        // Tick it again.
        vc.samplePickerState.selectedSamples = ["sample-1", "sample-2"]
        NotificationCenter.default.post(
            name: .metagenomicsSampleSelectionChanged,
            object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: projectWindow.windowStateScope)
        )
        fixture.waitForRows(vc) { $0.count == 4 }
        try selectAndAssert(sample: "sample-2", organism: "Gamma virus", contig: "NC_2001", "after ticking it again")

        // A multi-row selection hides the evidence view behind a
        // placeholder; a later single row must get it back.
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        try selectAndAssert(sample: "sample-1", organism: "Alpha virus", contig: "NC_1001", "after a multi-row selection")
    }

    // MARK: - 6. A row opens its own sample's reference and nobody else's (13.66, F-BTT2)

    /// A controller over `fixture` whose alignment viewer is `recorder`, with the rows loaded and the table's
    /// first selection settled, so `recorder.requests` holds only what a later selection adds.
    private func makeRecordedController(
        _ fixture: Fixture, recorder: RecordingEvidenceViewer
    ) -> TaxTriageResultViewController {
        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = makeTestDefaultsSuite(prefix: "TaxTriageDatabaseModeTests").defaults
        vc.classifierAlignmentViewerFactory = { recorder }
        _ = vc.view
        vc.configureFromDatabase(fixture.database, resultURL: fixture.root)
        fixture.waitForRows(vc) { $0.count == 4 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return vc
    }

    /// Selects the flat-table row of `sample` and `organism`, then spins the run loop until `settled` holds.
    /// The wait ends the moment the condition holds, with a 30 s ceiling.
    private func selectRow(
        of vc: TaxTriageResultViewController, sample: String, organism: String, until settled: () -> Bool
    ) throws {
        let index = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex {
            $0.sample == sample && $0.organism == organism
        }, "\(sample) \(organism) is not in the flat table")
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        let deadline = Date().addingTimeInterval(30)
        while !settled(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A guard, green at the base. Two samples that hold one taxon at different primary accessions open each
    /// its own: sample-2's Alpha virus opens NC_2002 on sample-2's BAM and sample-1's opens NC_1001 on sample-1's.
    func testASharedTaxonOpensEachSamplesOwnAccession() throws {
        let fixture = try Fixture(writeSidecar: false)
        defer { fixture.cleanUp() }
        let recorder = RecordingEvidenceViewer()
        let vc = makeRecordedController(fixture, recorder: recorder)

        for (sample, contig) in [("sample-2", "NC_2002"), ("sample-1", "NC_1001")] {
            try selectRow(of: vc, sample: sample, organism: "Alpha virus") {
                recorder.requests.last.map { $0.bamURL == fixture.bamURL(for: sample) && $0.contig.name == contig } ?? false
            }
            let request = try XCTUnwrap(recorder.requests.last, sample)
            XCTAssertEqual(request.bamURL, fixture.bamURL(for: sample), sample)
            XCTAssertEqual(request.contig.name, contig, sample)
            XCTAssertEqual(request.sample.canonicalID, sample, sample)
        }
    }

    /// The defect, red at the base. sample-2 holds Alpha virus (taxID 1001) with no primary accession, as build-db
    /// writes it when the sample's gcfmap has no match, while sample-1 holds the same taxon at NC_1001. At the base
    /// the row opened sample-2's BAM at NC_1001, the other sample's contig and stored length.
    func testARowWithNoAccessionOfItsOwnOpensNoOtherSamplesContig() throws {
        let fixture = try Fixture(writeSidecar: false, sample2AlphaAccession: nil)
        defer { fixture.cleanUp() }
        let recorder = RecordingEvidenceViewer()
        let vc = makeRecordedController(fixture, recorder: recorder)

        try selectRow(of: vc, sample: "sample-1", organism: "Alpha virus") {
            recorder.requests.last?.contig.name == "NC_1001"
        }
        XCTAssertEqual(recorder.requests.last?.bamURL, fixture.bamURL(for: "sample-1"), "the row with an accession opens its own")
        XCTAssertFalse(vc.testingIsDetailPaneCollapsed, "the pane is open before the row with no accession is selected")

        let requestsBefore = recorder.requests.count
        try selectRow(of: vc, sample: "sample-2", organism: "Alpha virus") {
            recorder.requests.count > requestsBefore || vc.testingIsDetailPaneCollapsed
        }
        let added = recorder.requests.dropFirst(requestsBefore).map { "\($0.contig.name) on \($0.bamURL.lastPathComponent)" }
        XCTAssertEqual(added, [], "a row with no accession of its own opens no reference, its own or another sample's")
        XCTAssertTrue(vc.testingIsDetailPaneCollapsed, "a row with no accession of its own collapses the alignment pane")
    }

    /// The defect on the BLAST Verify side, red at the base. The same row passes the host no accession, so the
    /// app says "No reference accessions available for BLAST verification." where it sent sample-1's NC_1001
    /// with sample-2's BAM. The closure is called once for a row with no accessions, since the app words the refusal.
    func testBlastVerifyOfARowWithNoAccessionOfItsOwnSendsNoOtherSamplesAccession() throws {
        let fixture = try Fixture(writeSidecar: false, sample2AlphaAccession: nil)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()
        fixture.waitForRows(vc) { $0.count == 4 }
        var sent: [(sample: String?, readCount: Int, accessions: [String]?, bamURL: URL?)] = []
        vc.onBlastVerification = { organism, readCount, accessions, bamURL, _ in
            sent.append((organism.sample, readCount, accessions, bamURL))
        }

        let metric = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.first {
            $0.sample == "sample-2" && $0.organism == "Alpha virus"
        })
        vc.testBatchFlatTableView.onBlastVerifyRequested?(metric, 3)

        XCTAssertEqual(sent.count, 1, "the request reaches the host once, which words what it lacks")
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.sample, "sample-2")
        XCTAssertEqual(request.readCount, 3)
        XCTAssertEqual(request.bamURL, fixture.bamURL(for: "sample-2"), "the request still names the row's own BAM")
        XCTAssertEqual(request.accessions ?? [], [], "no other sample's accession goes to BLAST")
    }

    /// A pin, green at the base. The third caller of the lookup is the Extract Reads selectors. With the Alpha virus rows
    /// of both samples selected and sample-2's row holding no accession of its own, only sample-1's NC_1001 is sent,
    /// under sample-1, and no selector for sample-2 carries it.
    func testExtractReadsOfRowsAcrossSamplesSendsEachSamplesOwnAccessionsOnly() throws {
        let fixture = try Fixture(writeSidecar: false, sample2AlphaAccession: nil)
        defer { fixture.cleanUp() }
        let vc = makeRecordedController(fixture, recorder: RecordingEvidenceViewer())
        var captured: [ClassifierRowSelector]?
        vc.onExtractReadsRequested = { _, _, selectors, _ in captured = selectors }

        let rows = vc.testBatchFlatTableView.displayedRows
        let first = try XCTUnwrap(rows.firstIndex { $0.sample == "sample-1" && $0.organism == "Alpha virus" })
        let second = try XCTUnwrap(rows.firstIndex { $0.sample == "sample-2" && $0.organism == "Alpha virus" })
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet([first, second]), byExtendingSelection: false)
        let deadline = Date().addingTimeInterval(30)
        while !vc.testActionBar.extractButton.isEnabled, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(vc.testActionBar.extractButton.isEnabled)
        vc.testActionBar.extractButton.performClick(nil)

        XCTAssertEqual(captured, [ClassifierRowSelector(sampleId: "sample-1", accessions: ["NC_1001"], taxIds: [])])
    }

    /// A mixed selection. Sample-2's Alpha virus row has no accession of its own, so Extract Reads leaves it out. The
    /// summary counts all three selected rows and names that one, and the other two go out under sample-1.
    func testExtractReadsSummaryCountsRowsAndNamesTheRowLeftOut() throws {
        let fixture = try Fixture(writeSidecar: false, sample2AlphaAccession: nil)
        defer { fixture.cleanUp() }
        let vc = makeRecordedController(fixture, recorder: RecordingEvidenceViewer())
        var captured: [ClassifierRowSelector]?
        vc.onExtractReadsRequested = { _, _, selectors, _ in captured = selectors }
        let rows = vc.testBatchFlatTableView.displayedRows
        let picks = [("sample-1", "Alpha virus"), ("sample-1", "Beta virus"), ("sample-2", "Alpha virus")]
        let indexes = try picks.map { pick in try XCTUnwrap(rows.firstIndex { $0.sample == pick.0 && $0.organism == pick.1 }) }
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
        let deadline = Date().addingTimeInterval(30)
        while !vc.testActionBar.extractButton.isEnabled, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let summary = vc.extractReadsSelectionSummary
        XCTAssertEqual(summary.rowCount, 3)
        XCTAssertEqual(
            summary.leftOutNotice,
            "1 selected row is left out because Alpha virus in sample-2 has no reference accession of its own."
        )
        vc.testActionBar.extractButton.performClick(nil)
        XCTAssertEqual(captured?.count, 1)
        XCTAssertEqual(captured?.first?.sampleId, "sample-1")
        XCTAssertEqual(captured?.first?.accessions.sorted(), ["NC_1001", "NC_1002"])
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let database: TaxTriageDatabase
        let samples: [String]

        /// `sample2AlphaAccession` is the primary accession of sample-2's Alpha virus row. Pass nil for the row
        /// build-db writes with a NULL accession, which the page snapshot leaves out of the accession maps.
        init(
            writeSidecar: Bool,
            storedOutputDirectory: String? = nil,
            negativeControl: String? = nil,
            samples: [String] = ["sample-1", "sample-2"],
            sample2AlphaAccession: String? = "NC_2002"
        ) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("TaxTriageDatabaseMode-\(UUID().uuidString)", isDirectory: true)
            self.samples = samples
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for sample in samples {
                let minimap = root.appendingPathComponent("\(sample)/minimap2", isDirectory: true)
                try fm.createDirectory(at: minimap, withIntermediateDirectories: true)
                try Data().write(to: minimap.appendingPathComponent("\(sample).bam"))
                try Data().write(to: minimap.appendingPathComponent("\(sample).bam.bai"))
                try fm.createDirectory(
                    at: root.appendingPathComponent("\(sample)/report", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            if samples.contains("sample-1") {
                try Data("%PDF-1.4\n".utf8).write(to: root.appendingPathComponent("sample-1/report/sample-1.odr.pdf"))
                try Data("<html></html>".utf8).write(to: root.appendingPathComponent("sample-1/report/sample-1.odr.html"))
            }
            if samples.contains("sample-2") {
                try Data("<html></html>".utf8).write(to: root.appendingPathComponent("sample-2/report/sample-2.odr.html"))
            }

            // Beta (TASS 0.76) is "High" by TaxTriage's threshold call even
            // though it is below the fixed 0.80 band.
            var rows = [
                Self.row(sample: "sample-1", organism: "Alpha virus", taxId: 1001, tass: 0.91, reads: 42, confidence: "High", accession: "NC_1001"),
                Self.row(sample: "sample-1", organism: "Beta virus", taxId: 1002, tass: 0.76, reads: 24, confidence: "High", accession: "NC_1002"),
            ]
            if samples.contains("sample-2") {
                rows.append(Self.row(sample: "sample-2", organism: "Gamma virus", taxId: 2001, tass: 0.50, reads: 12, confidence: "Medium", accession: "NC_2001"))
                rows.append(Self.row(sample: "sample-2", organism: "Alpha virus", taxId: 1001, tass: 0.20, reads: 3, confidence: "Low", accession: sample2AlphaAccession))
            }
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: rows,
                metadata: ["tool": "taxtriage"]
            )

            if writeSidecar {
                let stored = storedOutputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root
                let config = TaxTriageConfig(
                    samples: samples.map {
                        TaxTriageSample(
                            sampleId: $0,
                            fastq1: stored.appendingPathComponent("\($0).fastq.gz"),
                            isNegativeControl: $0 == negativeControl
                        )
                    },
                    outputDirectory: stored
                )
                let result = TaxTriageResult(
                    config: config,
                    runtime: 61,
                    exitCode: 0,
                    outputDirectory: stored,
                    reportFiles: [stored.appendingPathComponent("sample-1/report/sample-1.odr.pdf")]
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(to: root.appendingPathComponent("taxtriage-result.json"))
            }
        }

        func bamURL(for sample: String) -> URL {
            root.appendingPathComponent("\(sample)/minimap2/\(sample).bam")
        }

        @MainActor
        func makeController() -> TaxTriageResultViewController {
            let vc = TaxTriageResultViewController()
            vc.classifierAlignmentViewerFactory = { RecordingEvidenceViewer() }
            _ = vc.view
            vc.configureFromDatabase(database, resultURL: root)
            waitForRows(vc) { !$0.isEmpty }
            return vc
        }

        @MainActor
        func waitForRows(
            _ vc: TaxTriageResultViewController,
            file: StaticString = #filePath,
            line: UInt = #line,
            until condition: ([TaxTriageMetric]) -> Bool
        ) {
            // A ceiling, not a speed check: the loop returns as soon as rows appear
            // (about 0.15 s alone). Rows load on a detached task, which a loaded unit
            // tier on the 20-core Mac Studio once left unscheduled for over 10 s.
            let deadline = Date().addingTimeInterval(60)
            while !condition(vc.testBatchFlatTableView.displayedRows) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(condition(vc.testBatchFlatTableView.displayedRows), "rows did not load", file: file, line: line)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(
            sample: String,
            organism: String,
            taxId: Int,
            tass: Double,
            reads: Int,
            confidence: String,
            accession: String?
        ) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: sample,
                organism: organism,
                taxId: taxId,
                status: nil,
                tassScore: tass,
                readsAligned: reads,
                uniqueReads: reads / 2,
                pctReads: nil,
                pctAlignedReads: nil,
                coverageBreadth: 50,
                meanCoverage: nil,
                meanDepth: nil,
                confidence: confidence,
                k2Reads: nil,
                parentK2Reads: nil,
                giniCoefficient: nil,
                meanBaseQ: nil,
                meanMapQ: nil,
                mapqScore: nil,
                disparityScore: nil,
                minhashScore: nil,
                diamondIdentity: nil,
                k2DisparityScore: nil,
                siblingsScore: nil,
                breadthWeightScore: nil,
                hhsPercentile: nil,
                isAnnotated: nil,
                annClass: nil,
                microbialCategory: nil,
                highConsequence: nil,
                isSpecies: nil,
                pathogenicSubstrains: nil,
                sampleType: nil,
                bamPath: "\(sample)/minimap2/\(sample).bam",
                bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
                primaryAccession: accession,
                accessionLength: 10_000
            )
        }
    }
}
