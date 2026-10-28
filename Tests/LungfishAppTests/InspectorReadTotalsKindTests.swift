import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// The Inspector's Total Mapped and Total Unmapped rows say what they count (row
/// MAPPED-READS-FALLBACK-UNLABELLED). Reads come from flagstat's `primary` lines. A database without them has
/// idxstats alignment records, which count a supplementary alignment again beside its read, and the two are
/// never added into one number.
@MainActor
final class InspectorReadTotalsKindTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-read-totals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("bundle.lungfishref/alignments", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var bundleURL: URL { tempDir.appendingPathComponent("bundle.lungfishref", isDirectory: true) }

    private static var fixtureDatabase: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mapping/supplementary-one-contig/fixture.lungfishref/alignments/fixture-track.stats.db")
    }

    private func track(_ id: String) -> AlignmentTrackInfo {
        AlignmentTrackInfo(
            id: id, name: id,
            sourcePath: "alignments/\(id).sorted.bam",
            indexPath: "alignments/\(id).sorted.bam.bai",
            metadataDBPath: "alignments/\(id).stats.db"
        )
    }

    /// A track whose database holds idxstats records and the flagstat lines before samtools 1.9, none of them `primary`.
    private func addAlignmentOnlyTrack(_ id: String, mapped: Int64, unmapped: Int64) throws {
        let database = try AlignmentMetadataDatabase.create(at: bundleURL.appendingPathComponent("alignments/\(id).stats.db"))
        database.addChromosomeStats(chromosome: "chr1", length: 29_903, mapped: mapped, unmapped: unmapped)
        database.addFlagStat(category: "total", qcPass: mapped + unmapped, qcFail: 0)
        database.addFlagStat(category: "mapped", qcPass: mapped, qcFail: 0)
    }

    /// A track whose database is the supplementary fixture's: 10 mapped and 1 unmapped reads, 12 mapped records.
    private func addReadTrack(_ id: String) throws {
        try FileManager.default.copyItem(
            at: Self.fixtureDatabase, to: bundleURL.appendingPathComponent("alignments/\(id).stats.db")
        )
    }

    private func loadedViewModel(_ tracks: [AlignmentTrackInfo]) -> ReadStyleSectionViewModel {
        let manifest = BundleManifest(
            name: "Totals",
            identifier: "bundle.totals",
            source: SourceInfo(organism: "Test organism", assembly: "fixture", database: "Test"),
            alignments: tracks
        )
        let viewModel = ReadStyleSectionViewModel()
        viewModel.loadStatistics(from: ReferenceBundle(url: bundleURL, manifest: manifest))
        return viewModel
    }

    func testTotalsOfADatabaseWithoutPrimaryLinesAreLabelledAlignments() throws {
        try addAlignmentOnlyTrack("only", mapped: 91_148, unmapped: 1_000)
        let viewModel = loadedViewModel([track("only")])

        XCTAssertEqual(viewModel.totalMappedReads, 91_148, "the idxstats sum is still the number to show")
        XCTAssertEqual(viewModel.totalUnmappedReads, 1_000)
        XCTAssertTrue(viewModel.totalMappedLabel.contains("alignments"), "the row says what it counts: \(viewModel.totalMappedLabel)")
        XCTAssertTrue(viewModel.totalUnmappedLabel.contains("alignments"), viewModel.totalUnmappedLabel)
        let note = try XCTUnwrap(viewModel.alignmentCountsNote, "words say what these totals count and what to try next")
        XCTAssertTrue(note.contains("again"), "the note tells the person what to try next: \(note)")
        XCTAssertFalse(note.contains("supplementary"), "the note uses no SAM term: \(note)")
        XCTAssertTrue(note.contains("more than one place"), "the note says plainly why alignments count high: \(note)")
    }

    func testTotalsOfADatabaseWithPrimaryLinesStayReadsWithNoNote() throws {
        try addReadTrack("fixture")
        let viewModel = loadedViewModel([track("fixture")])

        XCTAssertEqual(viewModel.totalMappedReads, 10)
        XCTAssertEqual(viewModel.totalUnmappedReads, 1)
        XCTAssertEqual(viewModel.totalMappedLabel, "Total Mapped")
        XCTAssertEqual(viewModel.totalUnmappedLabel, "Total Unmapped")
        XCTAssertNil(viewModel.alignmentCountsNote)
        XCTAssertTrue(viewModel.alignmentOnlyRows.isEmpty)
    }

    /// Reads of one track and records of another were added into one Total Mapped, 10 reads and 100 records read 110.
    func testReadsAndAlignmentRecordsOfTwoTracksAreNotAddedIntoOneTotal() throws {
        try addReadTrack("fixture")
        try addAlignmentOnlyTrack("only", mapped: 100, unmapped: 5)
        let viewModel = loadedViewModel([track("fixture"), track("only")])

        XCTAssertEqual(viewModel.totalMappedReads, 10, "the reads of the track that has read counts, and nothing added")
        XCTAssertEqual(viewModel.totalUnmappedReads, 1)
        XCTAssertEqual(
            viewModel.alignmentOnlyRows.map(\.value), [100, 5],
            "the records of the other track are shown apart, as alignments"
        )
        XCTAssertTrue(viewModel.alignmentOnlyRows.allSatisfy { $0.label.contains("alignments") })
        let note = try XCTUnwrap(viewModel.alignmentCountsNote)
        XCTAssertTrue(note.contains("listed separately"), "the note says plainly that the alignments are kept apart: \(note)")
    }

    /// An idxstats `*` row holds the unmapped records that have no reference. `populateFromIdxstats` skips it and flagstat's
    /// total less its mapped gives them back, so the alignment totals read 12 mapped and 1 unmapped, the numbers the header
    /// shows. They read 12 and 0 with a mapped share of 100.0 (review of lane MAPPED, B1).
    func testAlignmentTotalsCountTheUnmappedRecordsOfIdxstatsStarRow() throws {
        let database = try AlignmentMetadataDatabase.create(at: bundleURL.appendingPathComponent("alignments/only.stats.db"))
        database.populateFromIdxstats("PX392161\t2280\t12\t0\n*\t0\t0\t1\n")
        database.populateFromFlagstat("13 + 0 in total (QC-passed reads + QC-failed reads)\n12 + 0 mapped (92.31% : N/A)\n")
        let viewModel = loadedViewModel([track("only")])

        XCTAssertEqual(viewModel.totalMappedReads, 12)
        XCTAssertEqual(viewModel.totalUnmappedReads, 1, "the unmapped record that has no reference is counted")
        XCTAssertEqual(String(format: "%.1f", try XCTUnwrap(viewModel.mappedPercent)), "92.3")
        XCTAssertTrue(viewModel.totalMappedLabel.contains("alignments"), viewModel.totalMappedLabel)
    }

    /// A database with flagstat's lines and no per-sequence rows holds a measured count, which the header and `bundle list`
    /// read from flagstat's `mapped` and `total` lines. The Inspector read 0 and 0 for it.
    func testAlignmentTotalsOfADatabaseWithOnlyFlagstatLinesAreFlagstatsCounts() throws {
        let database = try AlignmentMetadataDatabase.create(at: bundleURL.appendingPathComponent("alignments/only.stats.db"))
        database.populateFromFlagstat("13 + 0 in total (QC-passed reads + QC-failed reads)\n12 + 0 mapped (92.31% : N/A)\n")
        let viewModel = loadedViewModel([track("only")])

        XCTAssertEqual(viewModel.totalMappedReads, 12)
        XCTAssertEqual(viewModel.totalUnmappedReads, 1)
        XCTAssertTrue(viewModel.totalMappedLabel.contains("alignments"), viewModel.totalMappedLabel)
    }
}
