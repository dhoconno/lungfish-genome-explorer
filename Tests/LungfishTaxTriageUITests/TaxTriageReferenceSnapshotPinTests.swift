// TaxTriageReferenceSnapshotPinTests.swift - Pins the reference lengths the TaxTriage viewer reads from a BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.09 M0, the freeze of BIO-TT-ROUTES item 3 (QA 1). The viewer's `parseBamReferenceLengthsSnapshot`
// runs `samtools view -H` for the @SQ lengths, then `idxstats -X <bam> <index>` when the index file exists, then
// `idxstats <bam>`, and keeps the first idxstats attempt that exits 0. Lane 13.09 moves that body into a Workflow
// service, and these pins hold the whole length map the view keeps for each fixture BAM in each index case, and the
// length the production row selection opens a contig at when the database stores none. Every expected map was copied
// from a base run of the managed samtools (samtools 1.24) and passes at the lane base with no Sources edit. Each test
// runs the managed samtools, so it skips without it, and fails under LUNGFISH_REQUIRE_TOOLS=1.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit
import LungfishTestSupport

/// Records every request the view hands its alignment viewer.
@MainActor
private final class SnapshotPinRecordingViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []

    override init() {
        super.init()
        viewController.view = NSView()
    }

    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() {}
}

@MainActor
final class TaxTriageReferenceSnapshotPinTests: XCTestCase {

    private enum IndexCase: String, CaseIterable {
        case external, adjacent, none
    }

    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    private static let sarsCoV2BAM = fixturesRoot.appendingPathComponent("sarscov2/test.paired_end.sorted.bam")

    private static let sarsCoV2Lengths = ["MT192765.1": 29_829]

    /// The whole map of each TaxTriage mini BAM. The base run gives the same map in every index case, since idxstats
    /// reads a BAM with no index by its slow method and its lengths equal the @SQ lengths.
    private static let miniBAMLengths: [String: [String: Int]] = [
        "SRR35517702.SRR35517702.dwnld.references.bam": [
            "NC_004910.1": 2341, "NC_004911.1": 2328, "NC_004912.1": 2225, "NC_004908.1": 1714,
            "NC_004905.2": 1557, "NC_004909.1": 1418, "NC_004907.1": 1025, "NC_004906.1": 890,
            "NC_006577.2": 29926, "NC_007373.1": 2341, "NC_007372.1": 2341, "NC_007371.1": 2233,
            "NC_007366.1": 1762, "NC_007369.1": 1566, "NC_007368.1": 1467, "NC_007367.1": 1027,
            "NC_007370.1": 890, "NC_007455.1": 5299, "NC_009996.1": 7099, "NC_045512.2": 29903,
        ],
        "SRR35517703.SRR35517703.dwnld.references.bam": [
            "NC_004910.1": 2341, "NC_004911.1": 2328, "NC_004912.1": 2225, "NC_004908.1": 1714,
            "NC_004905.2": 1557, "NC_004909.1": 1418, "NC_004907.1": 1025, "NC_004906.1": 890,
            "NC_003045.1": 31028, "NC_007373.1": 2341, "NC_007372.1": 2341, "NC_007371.1": 2233,
            "NC_007366.1": 1762, "NC_007369.1": 1566, "NC_007368.1": 1467, "NC_007367.1": 1027,
            "NC_007370.1": 890, "NC_026144.1": 2115, "NC_045512.2": 29903,
        ],
        "SRR35517705.SRR35517705.dwnld.references.bam": [
            "NC_029119.1": 127_726, "NC_033774.1": 8913, "NC_033773.1": 4711, "NC_033772.1": 3310,
            "NC_053512.1": 70373, "NC_050152.1": 101_660, "NC_043175.1": 4383, "NC_043176.1": 3643,
            "NC_043174.1": 1705, "NC_045512.2": 29903, "NC_074583.1": 4387, "NC_074405.1": 3924,
        ],
    ]

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ManagedToolLocator.managedToolExecutablePath(.samtools) != nil else {
            try ToolAvailability.skipOrFail("the managed samtools is not installed")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageReferenceSnapshotPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - The sarscov2 fixture through the test hook (caller 3)

    func testHeaderLengthsOfTheFixtureBAMWithAnExternalIndex() throws {
        XCTAssertEqual(try lengths(of: Self.sarsCoV2BAM, .external), Self.sarsCoV2Lengths)
    }

    func testHeaderLengthsOfTheFixtureBAMWithAnAdjacentIndex() throws {
        XCTAssertEqual(try lengths(of: Self.sarsCoV2BAM, .adjacent), Self.sarsCoV2Lengths)
    }

    /// The base gives the same map with no index anywhere. The `-X` attempt is skipped, and `idxstats <bam>` still
    /// exits 0 because samtools 1.24 reads a BAM with no index by its slow method.
    func testHeaderLengthsOfTheFixtureBAMWithNoIndex() throws {
        XCTAssertEqual(try lengths(of: Self.sarsCoV2BAM, .none), Self.sarsCoV2Lengths)
    }

    /// The plan row says "per fixture BAM", so each TaxTriage mini BAM runs the same three index cases.
    func testHeaderLengthsOfEachTaxTriageMiniBAMInEveryIndexCase() throws {
        let folder = Self.fixturesRoot.appendingPathComponent("taxtriage-mini/minimap2", isDirectory: true)
        for (name, expected) in Self.miniBAMLengths.sorted(by: { $0.key < $1.key }) {
            for indexCase in IndexCase.allCases {
                let map = try lengths(of: folder.appendingPathComponent(name), indexCase)
                XCTAssertEqual(map, expected, "\(name), \(indexCase.rawValue) index")
            }
        }
    }

    // MARK: - The production row selection (caller 4)

    /// A row whose database stores no accession length makes the view read the BAM, and the contig opens at the
    /// header length.
    func testARowWithNoStoredLengthOpensItsContigAtTheHeaderLength() throws {
        let minimap = root.appendingPathComponent("S1/minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.sarsCoV2BAM, to: minimap.appendingPathComponent("S1.bam"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.sarsCoV2BAM.path + ".bai"),
            to: minimap.appendingPathComponent("S1.bam.bai")
        )
        let database = try TaxTriageDatabase.create(
            at: root.appendingPathComponent("taxtriage.sqlite"),
            rows: [Self.rowWithNoStoredLength()],
            metadata: ["tool": "taxtriage"]
        )

        let recorder = SnapshotPinRecordingViewer()
        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = makeTestDefaultsSuite(prefix: "TaxTriageReferenceSnapshotPinTests").defaults
        vc.classifierAlignmentViewerFactory = { recorder }
        _ = vc.view
        vc.configureFromDatabase(database, resultURL: root)
        let rowsDeadline = Date().addingTimeInterval(30)
        while vc.testBatchFlatTableView.displayedRows.isEmpty && Date() < rowsDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, 1, "rows did not load")
        XCTAssertNil(vc.testAccessionLengths["MT192765.1"], "Precondition failed: the database stores no length")

        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        // The request arrives after the detached BAM read, so wait for it. The loop ends once it is recorded.
        let requestDeadline = Date().addingTimeInterval(30)
        while recorder.requests.isEmpty && Date() < requestDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.contig.name, "MT192765.1")
        XCTAssertEqual(request.contig.expectedLength, 29_829)
        XCTAssertEqual(vc.testAccessionLengths, Self.sarsCoV2Lengths)
    }

    // MARK: - Helpers

    /// Copies `bam` into a fresh folder for the index case, runs the view's test hook on it and returns the whole
    /// map the view keeps.
    private func lengths(of bam: URL, _ indexCase: IndexCase) throws -> [String: Int] {
        let fm = FileManager.default
        let caseRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let minimap = caseRoot.appendingPathComponent("minimap2", isDirectory: true)
        try fm.createDirectory(at: minimap, withIntermediateDirectories: true)
        let bamURL = minimap.appendingPathComponent(bam.lastPathComponent)
        try fm.copyItem(at: bam, to: bamURL)
        let bai = URL(fileURLWithPath: bam.path + ".bai")
        var indexURL: URL?
        switch indexCase {
        case .external:
            let alignment = caseRoot.appendingPathComponent("alignment", isDirectory: true)
            try fm.createDirectory(at: alignment, withIntermediateDirectories: true)
            let external = alignment.appendingPathComponent(bai.lastPathComponent)
            try fm.copyItem(at: bai, to: external)
            indexURL = external
        case .adjacent:
            try fm.copyItem(at: bai, to: URL(fileURLWithPath: bamURL.path + ".bai"))
        case .none:
            break
        }
        if indexCase != .adjacent {
            XCTAssertFalse(fm.fileExists(atPath: bamURL.path + ".bai"), "Precondition failed: an adjacent index exists")
        }
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        vc.testParseBamReferenceLengths(bamURL: bamURL, indexURL: indexURL)
        return vc.testAccessionLengths
    }

    private static func rowWithNoStoredLength() -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: "S1",
            organism: "Severe acute respiratory syndrome coronavirus 2",
            taxId: 2_697_049,
            status: nil,
            tassScore: 0.95,
            readsAligned: 197,
            uniqueReads: 150,
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
            bamPath: "S1/minimap2/S1.bam",
            bamIndexPath: "S1/minimap2/S1.bam.bai",
            primaryAccession: "MT192765.1",
            accessionLength: nil
        )
    }
}
