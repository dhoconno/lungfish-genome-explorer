// TaxTriageNoReferenceRowTests.swift - A TaxTriage row with no recorded reference opens no other organism's reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane TT-FUZZY-NAME (S1, BIO ruling of 2026-10-26). One sample holds "Human papillomavirus type 16"
// with its reference and "Human papillomavirus type 1" with none, since build-db wrote a NULL accession for it.
// The name lookup used to hand the type 1 row the type 16 reference, so Extract Reads, BLAST Verify and the
// alignment pane worked on the reads of type 16 under the name of type 1. Each of them now treats the row as one
// with no reference of its own.

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
final class TaxTriageNoReferenceRowTests: XCTestCase {

    private static let withReference = "Human papillomavirus type 16"
    private static let withoutReference = "Human papillomavirus type 1"
    private static let referenceAccession = "NC_001526.4"

    // MARK: - Extract Reads

    /// Extract on the row alone sends nothing, since the row has no reference, and says why. At the base the
    /// click sent a selector that names NC_001526.4, the reference of type 16.
    func testExtractOfARowWithNoReferenceSendsNoOtherOrganismsAccession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        var sent: [[ClassifierRowSelector]] = []
        vc.onExtractReadsRequested = { _, _, selectors, _ in sent.append(selectors) }
        var notices: [String] = []
        vc.extractNoticePresenter = { title, _, _ in notices.append(title) }

        try select([Self.withoutReference], in: vc) { vc.testActionBar.extractButton.isEnabled }
        XCTAssertEqual(
            vc.extractReadsSelectionSummary.leftOutNotice,
            "1 selected row is left out because Human papillomavirus type 1 in sample-1 has no reference accession of its own."
        )
        vc.testActionBar.extractButton.performClick(nil)

        XCTAssertEqual(
            sent.flatMap { $0 }.flatMap(\.accessions), [],
            "no selector may name an accession for a row that has none of its own"
        )
        XCTAssertEqual(notices, ["Nothing to extract"])
    }

    /// With both rows selected only the row that has a reference goes out, once, and the other is named as left
    /// out. At the base the reference of type 16 went out twice and nothing was left out.
    func testExtractOfBothRowsSendsTheOneReferenceOnceAndNamesTheRowLeftOut() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        var captured: [ClassifierRowSelector]?
        vc.onExtractReadsRequested = { _, _, selectors, _ in captured = selectors }

        try select([Self.withReference, Self.withoutReference], in: vc) { vc.testActionBar.extractButton.isEnabled }
        let summary = vc.extractReadsSelectionSummary
        XCTAssertEqual(summary.rowCount, 2)
        XCTAssertEqual(
            summary.leftOutNotice,
            "1 selected row is left out because Human papillomavirus type 1 in sample-1 has no reference accession of its own."
        )
        vc.testActionBar.extractButton.performClick(nil)

        XCTAssertEqual(
            captured, [ClassifierRowSelector(sampleId: "sample-1", accessions: [Self.referenceAccession], taxIds: [])]
        )
    }

    // MARK: - BLAST Verify

    /// BLAST Verify of the row reaches the host with no accession, which words the refusal, and not with the
    /// accession of type 16 and the reads of type 16 from the BAM.
    func testBlastVerifyOfARowWithNoReferenceSendsNoOtherOrganismsAccession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        var sent: [(accessions: [String]?, bamURL: URL?)] = []
        vc.onBlastVerification = { _, _, accessions, bamURL, _ in sent.append((accessions, bamURL)) }

        let metric = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.first { $0.organism == Self.withoutReference })
        vc.testBatchFlatTableView.onBlastVerifyRequested?(metric, 3)

        XCTAssertEqual(sent.count, 1, "the request reaches the host once, which words what it lacks")
        XCTAssertEqual(sent.first?.bamURL, fixture.bamURL, "the request still names the row's own BAM")
        XCTAssertEqual(sent.first?.accessions ?? [], [], "no other organism's accession goes to BLAST")
    }

    // MARK: - Alignment pane

    /// Selecting the row opens no alignment and closes the pane. At the base it opened NC_001526.4 under the
    /// name of type 1.
    func testARowWithNoReferenceOpensNoOtherOrganismsAlignment() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recorder = RecordedAlignmentViewer()
        let vc = makeController(fixture, recorder: recorder)

        // The row that has a reference opens it, so the viewer holds one request before the other row is selected.
        try select([Self.withReference], in: vc) { recorder.requests.count >= 1 }
        XCTAssertEqual(recorder.requests.map(\.contig.name), [Self.referenceAccession])
        XCTAssertFalse(vc.testingIsDetailPaneCollapsed, "the pane is open for the row that has a reference")

        let before = recorder.requests.count
        try select([Self.withoutReference], in: vc) { recorder.requests.count > before || vc.testingIsDetailPaneCollapsed }
        XCTAssertEqual(
            recorder.requests.dropFirst(before).map(\.contig.name), [],
            "a row with no reference of its own opens no other organism's reference"
        )
        XCTAssertTrue(vc.testingIsDetailPaneCollapsed, "a row with no reference closes the alignment pane")
    }

    // MARK: - Fixture

    private func makeController(
        _ fixture: Fixture, recorder: RecordedAlignmentViewer? = nil
    ) -> TaxTriageResultViewController {
        let vc = TaxTriageResultViewController()
        isolateLayouts(vc)
        if let recorder { vc.classifierAlignmentViewerFactory = { recorder } }
        _ = vc.view
        vc.configureFromDatabase(fixture.database, resultURL: fixture.root)
        // A ceiling, not a speed check. The rows load on a detached task and the wait ends as soon as they show.
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testBatchFlatTableView.displayedRows.count == 2 },
            "the rows did not load"
        )
        return vc
    }

    /// Selects the flat-table rows of `organisms` and runs the loop until `settled` holds.
    private func select(
        _ organisms: [String], in vc: TaxTriageResultViewController, until settled: () -> Bool
    ) throws {
        let rows = vc.testBatchFlatTableView.displayedRows
        let indexes = try organisms.map { name in
            try XCTUnwrap(rows.firstIndex { $0.organism == name }, "\(name) is not in the flat table")
        }
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup, settled), "the selection did not settle")
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let database: TaxTriageDatabase
        let bamURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaxTriageNoReferenceRow-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("sample-1/minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            bamURL = folder.appendingPathComponent("sample-1.bam")
            try Data().write(to: bamURL)
            try Data().write(to: folder.appendingPathComponent("sample-1.bam.bai"))
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: [
                    Self.row(TaxTriageNoReferenceRowTests.withReference, taxId: 333760, tass: 0.9, reads: 40,
                             accession: TaxTriageNoReferenceRowTests.referenceAccession),
                    Self.row(TaxTriageNoReferenceRowTests.withoutReference, taxId: 10566, tass: 0.5, reads: 12,
                             accession: nil),
                ],
                metadata: ["tool": "taxtriage"]
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(
            _ organism: String, taxId: Int, tass: Double, reads: Int, accession: String?
        ) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: "sample-1", organism: organism, taxId: taxId, status: nil, tassScore: tass, readsAligned: reads,
                uniqueReads: reads / 2, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
                meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
                meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
                diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
                hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
                isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
                bamPath: "sample-1/minimap2/sample-1.bam", bamIndexPath: "sample-1/minimap2/sample-1.bam.bai",
                primaryAccession: accession, accessionLength: accession == nil ? nil : 7906
            )
        }
    }
}
