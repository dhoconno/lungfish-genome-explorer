// TaxTriageControlNoticeTests.swift - What the viewer tells a person about a negative control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTCONTROLS, rows TAXTRIAGE-VIEWER-CONTROL-SILENT and TAXTRIAGE-SELECTION-LEAVES-OUT-CONTROL (BIO backlog 1, 3
// and 7 of the TTBUILDDB review). The exports say `Not checked` for a control that failed or cannot be found, and
// the viewer said nothing, so a blank Risk flag read as a clean control. The overview grid also took its flag from
// the ticked samples, so unticking a control hid what it held, and the grid lost its Risk column when a control
// had no rows.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

/// A project-window stand-in that owns a scope, so a viewport shown in its window accepts the sample selection
/// notification that carries it.
@MainActor
private final class ProjectWindowStandIn: NSWindowController, WindowStateScopeOwner {
    let windowStateScope = WindowStateScope()
}

@MainActor
final class TaxTriageControlNoticeTests: XCTestCase {

    // MARK: - The notice

    func testViewerSaysAControlThatFailedHasNoResult() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC1", true)],
            databaseSamples: ["sample-1", "sample-2"],
            failed: ["NTC1"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about a control that failed")
        XCTAssertTrue(words.contains("Contamination risk is not checked."), words)
        XCTAssertTrue(words.contains("NTC1"), words)
        XCTAssertTrue(words.contains("Run it again, or check it another way, before you rely on these results."), words)
        // UX review, should-fix: the cells stay blank and the list shows no sign, so the strip says what that means.
        XCTAssertTrue(words.hasSuffix("Where no warning sign shows, the risk is not checked."), words)
    }

    /// Row 3. A control whose task Nextflow ignored and that has no rows is not a clean control.
    func testViewerSaysAControlWhoseTaskNextflowIgnoredHasNoResult() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC1", true)],
            databaseSamples: ["sample-1", "sample-2"],
            ignored: ["NTC1"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about a control whose task was ignored")
        XCTAssertTrue(words.contains("The negative control NTC1 failed, so Lungfish has no result for it."), words)
    }

    /// BIO review, should-fix 2. A control that has rows and a skipped step keeps its Yes and No, and the strip says its
    /// results may be incomplete. It did not fail, so the strip does not say that.
    func testViewerSaysAControlWithResultsAndAnIgnoredStepMayBeIncomplete() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC1", true)],
            databaseSamples: ["sample-1", "sample-2", "NTC1"],
            ignored: ["NTC1"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about a control with a skipped step")
        XCTAssertTrue(
            words.contains("A step of the negative control NTC1 (MINIMAP2_ALIGN) stopped with an error that the pipeline skipped"),
            words
        )
        XCTAssertTrue(words.contains("may be incomplete"), words)
        XCTAssertFalse(words.contains("failed"), words)
        // 3.2 TTNOTCHECKED: the files now say Not checked for what this control does not list, so the strip says where no
        // sign shows the risk is not checked (it said nothing here before).
        XCTAssertTrue(words.contains("Contamination risk is only partly checked."), words)
        XCTAssertTrue(words.hasSuffix("Where no warning sign shows, the risk is not checked."), words)
    }

    func testViewerNamesAControlItCannotFindInTheResults() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC 9", true)],
            databaseSamples: ["sample-1", "sample-2", "elsewhere"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about a control it cannot find")
        XCTAssertTrue(words.contains("NTC 9 (named NTC_9 in the results)"), words)
        XCTAssertTrue(words.contains("(elsewhere)"), words)
        XCTAssertTrue(words.contains("Look in the control's own results before you rely on these results."), words)
        XCTAssertTrue(words.hasSuffix("Where no warning sign shows, the risk is not checked."), words)
    }

    func testViewerSaysWhenTwoSampleNamesMeet() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC 1", true), ("NTC_1", false)],
            databaseSamples: ["sample-1", "sample-2", "NTC_1"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about two names that meet")
        XCTAssertTrue(words.contains("NTC 1 and NTC_1 are both named NTC_1 in the results"), words)
        XCTAssertTrue(words.contains("Give each sample a name that stays different"), words)
        // 3.2 TTNOTCHECKED: the control NTC 1 met a sample and the results hold one of the two, so the rows that were kept may
        // be the sample's and the control's No is not known. The files say Not checked and the strip says so.
        XCTAssertTrue(words.hasSuffix("Where no warning sign shows, the risk is not checked."), words)
    }

    /// BIO review, blocker 2. The app's own index build keeps the rows of one of two folders whose names meet and only
    /// logs it (`LungfishCLIRunner.buildClassifierDatabase`), so the strip is where a person can read that a sample's
    /// rows are not in the table. The database holds the one name build-db keeps, `A_1`.
    func testViewerSaysWhenTwoOrdinarySamplesMeetAndTheResultsHoldOne() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("A (1)", false), ("A_1", false)],
            databaseSamples: ["sample-1", "A_1"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about a sample whose rows are left out")
        XCTAssertTrue(words.contains("A (1) and A_1 are both named A_1 in the results"), words)
        XCTAssertTrue(words.contains("the results hold only one sample"), words)
        XCTAssertTrue(words.contains("Give each sample a name that stays different"), words)
    }

    /// Two controls that meet: the dropped one's organisms are gone, so the strip says the risk is only partly checked
    /// and how to read a blank (lane TTNOTCHECKED, UX review SF-1).
    func testViewerSaysWhenTwoControlsMeetAndTheResultsHoldOne() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("NTC 1", true), ("NTC_1", true)],
            databaseSamples: ["sample-1", "NTC_1"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about two controls that meet")
        XCTAssertTrue(words.contains("NTC 1 and NTC_1 are both named NTC_1 in the results"), words)
        XCTAssertTrue(words.contains("the results hold only one sample"), words)
        XCTAssertTrue(words.contains("Contamination risk is only partly checked."), words)
        XCTAssertFalse(words.contains("Contamination risk is not checked."), "an incomplete control is only partly checked: \(words)")
        XCTAssertTrue(words.hasSuffix("Where no warning sign shows, the risk is not checked."), words)
    }

    /// Both samples are in the results under the numbered names the pipeline gives them, so nothing is left out.
    func testViewerSaysNothingWhenTwoSampleNamesMeetAndTheResultsHoldBoth() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("A (1)", false), ("A_1", false)],
            databaseSamples: ["sample-1", "A_1_T1", "A_1_T2"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        XCTAssertNil(vc.testControlsNotRecordedNoticeWords)
    }

    /// A control that ran and found nothing needs no notice.
    func testViewerSaysNothingWhenEveryControlRan() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC1", true)],
            databaseSamples: ["sample-1", "sample-2"]
        )
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        XCTAssertNil(vc.testControlsNotRecordedNoticeWords)
    }

    // MARK: - The overview grid

    /// Backlog 7. A control that ran and holds nothing has no rows, and the Risk column went with it, so nothing on
    /// screen said the run had a control. The column stays whenever the run lists one.
    func testOverviewKeepsItsRiskColumnForAControlThatHasNoRows() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC1", true)],
            databaseSamples: ["sample-1", "sample-2"]
        )
        defer { fixture.cleanUp() }
        let window = Window(fixture)
        defer { window.close() }
        let vc = window.controller

        vc.selectAllSamplesOverview(nil)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testBatchOverviewView.testingRowIndex(organism: "Alpha virus") != nil },
            "the overview grid did not load"
        )
        let columns = vc.testBatchOverviewView.testingTableView.tableColumns.map(\.identifier.rawValue)
        XCTAssertTrue(columns.contains("risk"), "the run lists a control, but the grid has no Risk column: \(columns)")
    }

    /// The grid showed the flag only for the samples ticked, so unticking NTC1 hid that NTC1 holds Alpha virus.
    func testOverviewFlagsWhatAControlHoldsWhenTheControlIsNotTicked() throws {
        let fixture = try Fixture(
            listed: [("sample-1", false), ("sample-2", false), ("NTC1", true)],
            databaseSamples: ["sample-1", "sample-2", "NTC1"]
        )
        defer { fixture.cleanUp() }
        let window = Window(fixture)
        defer { window.close() }
        let vc = window.controller
        let overview = vc.testBatchOverviewView

        func isFlagged() -> Bool {
            guard let row = overview.testingRowIndex(organism: "Alpha virus") else { return false }
            return overview.testingCell(column: "risk", row: row)?.stringValue == "\u{26A0}"
        }

        vc.selectAllSamplesOverview(nil)
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { isFlagged() }, "the grid did not flag what NTC1 holds while NTC1 is ticked")

        vc.samplePickerState.selectedSamples = ["sample-1", "sample-2"]
        NotificationCenter.default.post(
            name: .metagenomicsSampleSelectionChanged,
            object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: window.projectWindow.windowStateScope)
        )
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testBatchFlatTableView.displayedRows.count == 3 },
            "the two ticked samples did not load"
        )
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { isFlagged() },
            "NTC1 holds Alpha virus, but the grid did not flag it once NTC1 was not ticked"
        )
    }

    // MARK: - Helpers

    /// The viewer in a window that owns a scope, which the sample selection notification needs.
    private struct Window {
        let controller: TaxTriageResultViewController
        let window: NSWindow
        let projectWindow: NSWindowController & WindowStateScopeOwner

        @MainActor
        init(_ fixture: Fixture) {
            controller = TaxTriageResultViewController()
            controller.layoutDefaults = TestDefaultsSuite(prefix: "TaxTriageControlNoticeTests").defaults
            _ = controller.view
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                styleMask: [.titled, .resizable, .closable],
                backing: .buffered,
                defer: false
            )
            projectWindow = ProjectWindowStandIn(window: window)
            window.contentViewController = controller
            window.orderFront(nil)
            window.setContentSize(NSSize(width: 1200, height: 900))
            controller.configureFromDatabase(fixture.database, resultURL: fixture.root)
            window.layoutIfNeeded()
            _ = waitUntilOnRunLoop(budget: .lookup) { !controller.testBatchFlatTableView.displayedRows.isEmpty }
        }

        @MainActor
        func close() {
            window.orderOut(nil)
            withExtendedLifetime(projectWindow) {}
        }
    }

    private struct Fixture {
        let root: URL
        let database: TaxTriageDatabase

        /// `listed` are the samples the sidecar lists as typed, with their control mark. `databaseSamples` hold
        /// Alpha virus in the database, and the first of them holds Beta virus too. `failed` are the samples the
        /// sidecar lists as failed.
        init(listed: [(String, Bool)], databaseSamples: [String], failed: [String] = [], ignored: [String] = []) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("TaxTriageControlNotice-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var rows: [TaxTriageTaxonomyRow] = []
            for (index, sample) in databaseSamples.enumerated() {
                rows.append(Self.row(sample: sample, organism: "Alpha virus", taxId: 1001))
                if index == 0 { rows.append(Self.row(sample: sample, organism: "Beta virus", taxId: 1002)) }
            }
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: rows,
                metadata: ["tool": "taxtriage"]
            )
            let config = TaxTriageConfig(
                samples: listed.map {
                    TaxTriageSample(
                        sampleId: $0.0,
                        fastq1: root.appendingPathComponent("\($0.0).fastq.gz"),
                        isNegativeControl: $0.1
                    )
                },
                outputDirectory: root
            )
            try TaxTriageResult(
                config: config,
                runtime: 61,
                exitCode: 0,
                outputDirectory: root,
                ignoredFailures: ignored.map {
                    TaxTriageIgnoredFailure(
                        processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN",
                        processName: "MINIMAP2_ALIGN",
                        taskLabel: "MINIMAP2_ALIGN (\($0))",
                        sampleID: $0,
                        exitCode: 137
                    )
                },
                sampleFailures: failed.map {
                    TaxTriageSampleFailure(
                        sampleID: $0,
                        outputDirectory: root.appendingPathComponent($0),
                        errorDescription: "TaxTriage pipeline failed with exit code 1"
                    )
                }
            ).save()
        }

        @MainActor
        func makeController() -> TaxTriageResultViewController {
            let vc = TaxTriageResultViewController()
            vc.layoutDefaults = TestDefaultsSuite(prefix: "TaxTriageControlNoticeTests").defaults
            _ = vc.view
            vc.configureFromDatabase(database, resultURL: root)
            return vc
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(sample: String, organism: String, taxId: Int) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: sample,
                organism: organism,
                taxId: taxId,
                status: nil,
                tassScore: 0.9,
                readsAligned: 40,
                uniqueReads: 20,
                pctReads: nil,
                pctAlignedReads: nil,
                coverageBreadth: 50,
                meanCoverage: nil,
                meanDepth: nil,
                confidence: "High",
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
                primaryAccession: "NC_\(taxId)",
                accessionLength: 10_000
            )
        }
    }
}
