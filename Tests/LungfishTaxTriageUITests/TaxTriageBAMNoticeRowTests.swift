// TaxTriageBAMNoticeRowTests.swift - The action bar says so when a row's BAM is a file that a fit of its name gave the sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FIX-T2-VIEW-BIO 3.1 (BIO-WALK-T2-VIEW, S1 rare). When a sample has no BAM of its own, `build-db taxtriage` records a file of
// `minimap2/` whose name fits it, and `minimap2/S1_2.bam` can hold sample S1_2's reads. The view takes the words from one
// layer, `ClassifierReadResolver.taxTriageRecordedBAMNotice`, and shows them in the action bar's line and tooltip and in
// the alignment request that the Inspector reads. The layer has its own tests. These hold the calls that carry the words to
// the bar. A row of a fitted sample shows them, and a row of a sample with its own BAM takes them back. No window is shown.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishTaxTriageUI

/// Records the alignments a result view asks for, as the App's detached viewer would receive them.
@MainActor
private final class RecordedAlignmentViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []
    override init() {
        super.init()
        // Like the App's viewer, whose header gives its view a minimum height, this view cannot shrink below 31 pt.
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

@MainActor
final class TaxTriageBAMNoticeRowTests: XCTestCase {

    /// The words of `taxTriageScanNotice` for sample S1 and the file `S1_2.bam` of a marked fit.
    private static let markedNotice = "Sample S1's own BAM was not found when Lungfish built this result's database, so "
        + "Lungfish read S1_2.bam, a file in the minimap2 folder whose name fits it. "
        + "If that file belongs to another sample, put S1's own BAM back, delete taxtriage.sqlite in "
        + "the result folder and select the result again so that Lungfish builds the database anew."

    /// The start of the words for a database that a build before 2026.11.6 made, which holds no `fitted_bam_samples` key.
    private static let olderBuildStart = "This result's database was built by a version of Lungfish before 2026.11.6"

    // MARK: - A marked fit

    /// S1 has no BAM of its own, so the database records `S1_2.bam` for it and marks the fit. Selecting S1's row puts the
    /// words in the bar's line and tooltip and in the request that the Inspector reads. Selecting S2's row, whose BAM is
    /// its own, takes the tooltip back and leaves no words in the line or in the request.
    func testSelectingARowOfAFittedSampleShowsTheNoticeAndAnotherRowTakesItBack() throws {
        let fixture = try Fixture(marking: ["S1"])
        defer { fixture.cleanUp() }
        let seen = try walk(fixture, resultURL: fixture.root)

        XCTAssertEqual(seen.s1.line, Self.markedNotice)
        XCTAssertEqual(seen.s1.tip, Self.markedNotice)
        XCTAssertEqual(seen.s1.requestNotice, Self.markedNotice, "the Inspector's row reads the same words")
        for other in [seen.s2, seen.s2Again] {
            XCTAssertNil(other.tip, "S2 has a BAM of its own, so the tooltip is empty")
            XCTAssertNotEqual(other.line, Self.markedNotice)
            XCTAssertNil(other.requestNotice)
        }
    }

    /// The view and BLAST Verify get the result folder, and a folder URL that ends with no slash is still the folder
    /// (FIX-T2-VIEW-BIO 3.2). The words come up for it as they do for the URL with the slash.
    func testAFolderUrlWithNoTrailingSlashShowsTheNoticeToo() throws {
        let fixture = try Fixture(marking: ["S1"])
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.rootWithoutSlash.hasDirectoryPath, "the test needs a folder URL that ends with no slash")
        let seen = try walk(fixture, resultURL: fixture.rootWithoutSlash)

        XCTAssertEqual(seen.s1.line, Self.markedNotice)
        XCTAssertEqual(seen.s1.tip, Self.markedNotice)
        XCTAssertNil(seen.s2Again.tip)
    }

    // MARK: - A database with no key

    /// A database that a build before 2026.11.6 made holds no `fitted_bam_samples` key, so a recorded BAM under neither of
    /// the sample's own names may be another sample's. S1's row says so in the first sentence of the refusal Extract Reads
    /// gives, and S2's row says nothing.
    func testARowOfASampleInADatabaseWithNoKeyShowsTheOlderBuildWords() throws {
        let fixture = try Fixture(marking: nil)
        defer { fixture.cleanUp() }
        let seen = try walk(fixture, resultURL: fixture.root)

        XCTAssertTrue(seen.s1.line.hasPrefix(Self.olderBuildStart), seen.s1.line)
        XCTAssertEqual(seen.s1.tip, seen.s1.line, "the tooltip carries all of the words")
        XCTAssertEqual(seen.s1.requestNotice, seen.s1.line, "the Inspector's row reads the same words")
        for other in [seen.s2, seen.s2Again] {
            XCTAssertNil(other.tip)
            XCTAssertFalse(other.line.hasPrefix(Self.olderBuildStart), other.line)
            XCTAssertNil(other.requestNotice)
        }
    }

    // MARK: - Walk

    /// What the action bar's line, the line's tooltip and the latest alignment request held once a row had settled.
    private struct Seen {
        let line: String
        let tip: String?
        let requestNotice: String?
    }

    /// Selects a row of S2, then of S1, then of S2 again, and reads the bar and the request after each. The wait ends on the
    /// alignment request of the selected sample, which the view asks for after it has written the bar's line.
    private func walk(_ fixture: Fixture, resultURL: URL) throws -> (s2: Seen, s1: Seen, s2Again: Seen) {
        let recorder = RecordedAlignmentViewer()
        let vc = makeController(fixture, resultURL: resultURL, recorder: recorder)
        func seen(afterSelecting sample: String) throws -> Seen {
            try select(sample: sample, in: vc) { recorder.requests.last?.sample.canonicalID == sample }
            let label = vc.testActionBar.infoLabel
            return Seen(
                line: label.stringValue, tip: label.toolTip, requestNotice: recorder.requests.last?.presentation.bamNotice
            )
        }
        let s2 = try seen(afterSelecting: "S2")
        let s1 = try seen(afterSelecting: "S1")
        let s2Again = try seen(afterSelecting: "S2")
        return (s2, s1, s2Again)
    }

    private func makeController(
        _ fixture: Fixture, resultURL: URL, recorder: RecordedAlignmentViewer
    ) -> TaxTriageResultViewController {
        let vc = TaxTriageResultViewController()
        isolateLayouts(vc)
        vc.classifierAlignmentViewerFactory = { recorder }
        _ = vc.view
        vc.configureFromDatabase(fixture.database, resultURL: resultURL)
        // A ceiling, not a speed check. The rows load on a detached task and the wait ends as soon as they show.
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testBatchFlatTableView.displayedRows.count == 2 },
            "the rows did not load"
        )
        return vc
    }

    /// Selects the flat-table row of `sample` and runs the loop until `settled` holds.
    private func select(
        sample: String, in vc: TaxTriageResultViewController, until settled: () -> Bool
    ) throws {
        let rows = vc.testBatchFlatTableView.displayedRows
        let index = try XCTUnwrap(rows.firstIndex { $0.sample == sample }, "no row of \(sample) in the flat table")
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup, settled), "the selection of \(sample) did not settle")
    }

    // MARK: - Fixture

    /// A result folder of two samples. S1 has no BAM of its own, so its row records `minimap2/S1_2.bam`, a file whose
    /// name fits it and that can belong to another sample. S2's row records its own `minimap2/S2.bam`. The BAMs are
    /// placeholders, since the words are made from names and the database and no BAM is read.
    @MainActor
    private struct Fixture {
        let root: URL
        let rootWithoutSlash: URL
        let database: TaxTriageDatabase

        /// `fitted` is what the metadata key `fitted_bam_samples` lists, or nil for a database that holds no such key.
        init(marking fitted: [String]?) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaxTriageBAMNoticeRow-\(UUID().uuidString)", isDirectory: true)
            rootWithoutSlash = URL(fileURLWithPath: root.path, isDirectory: false)
            let folder = root.appendingPathComponent("minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["S1_2.bam", "S2.bam"] {
                try Data([0x1F, 0x8B]).write(to: folder.appendingPathComponent(name))
                try Data().write(to: folder.appendingPathComponent(name + ".bai"))
            }
            var metadata = ["tool": "TaxTriage"]
            if let fitted {
                metadata[TaxTriageDatabase.fittedBAMSamplesMetadataKey] =
                    TaxTriageDatabase.fittedBAMSamplesMetadataValue(fitted)
            }
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: [
                    Self.row(sample: "S1", bamPath: "minimap2/S1_2.bam"),
                    Self.row(sample: "S2", bamPath: "minimap2/S2.bam"),
                ],
                metadata: metadata
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(sample: String, bamPath: String) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
                uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
                meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
                meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
                diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
                hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
                isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
                bamPath: bamPath, bamIndexPath: bamPath + ".bai",
                primaryAccession: "NC_1001", accessionLength: 10_000
            )
        }
    }
}
