import SQLite3
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// The header of a mapping result says what its counts count (rows HEADER-READS-MAPPED-100 and
/// MAPPED-READS-FALLBACK-UNLABELLED). These tests open the fixture in
/// `Tests/Fixtures/mapping/supplementary-one-contig` (10 primary mapped reads, 2 supplementary records and
/// 1 unmapped read, so flagstat's `mapped` and `total` lines read 12 of 13) with its stats database edited
/// to hold no total at all, or no `primary` lines.
@MainActor
final class MappingHeaderCountWordsTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping_header_count_words_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    /// 10 mapped reads, which the summary build measured in the BAM itself.
    private static let measuredRow = MappingContigSummary(
        contigName: "fixture1",
        contigLength: 1000,
        mappedReads: 10,
        mappedReadPercent: 90.9,
        meanDepth: 1.25,
        coverageBreadth: 0.5,
        medianMAPQ: 45,
        meanIdentity: 0.95
    )

    // MARK: - No total

    /// A track with no flagstat, no idxstats and no manifest counts has no total. The header made the mapped
    /// count its own total and printed "10 / 10 reads mapped (100.0%)", a percentage nobody measured.
    func testHeaderOfATrackWithNoTotalShowsNoPercentageAndSaysTheTotalIsUnknown() async throws {
        let viewport = try openFixture(
            editingStatsWith: ["DELETE FROM flag_stats", "DELETE FROM chromosome_stats"],
            manifestCountsAreSet: false
        )
        await viewport.mappingRowsRefreshTask?.value

        let text = viewport.testSummaryText
        XCTAssertFalse(text.contains("%"), "no total was measured, so there is no percentage: \(text)")
        XCTAssertFalse(text.contains("10 / 10"), "the mapped count is not its own total: \(text)")
        XCTAssertTrue(text.contains("unknown"), "the words say that the total is unknown: \(text)")
        XCTAssertTrue(text.contains("10"), "the 10 mapped reads the build measured still show: \(text)")
        XCTAssertTrue(text.contains("10 reads mapped"), "the rows of the summary build count primary reads, so the unit is reads: \(text)")
        XCTAssertTrue(viewport.summaryLabel.toolTip?.contains("again") == true, "the tip carries the next step: \(viewport.summaryLabel.toolTip ?? "none")")
    }

    // MARK: - No primary lines

    /// Flagstat's `mapped` and `total` lines count each supplementary alignment again, so a database without the
    /// `primary` lines gives alignment records, 12 of 13 here. The header printed them as reads.
    func testHeaderLabelsAlignmentRecordsWhenFlagstatHasNoPrimaryLines() async throws {
        let viewport = try openFixture(
            editingStatsWith: ["DELETE FROM flag_stats WHERE category LIKE 'primary%'"],
            manifestCountsAreSet: true
        )
        await viewport.mappingRowsRefreshTask?.value

        let text = viewport.testSummaryText
        XCTAssertTrue(text.contains("12 / 13"), "flagstat's mapped and total lines give the numbers: \(text)")
        XCTAssertTrue(text.contains("alignments"), "the numbers are alignment records and the header says so: \(text)")
        XCTAssertFalse(text.contains("reads mapped"), "alignment records are no reads: \(text)")
        XCTAssertTrue(viewport.summaryLabel.toolTip?.contains("more than one place") == true, "the tip says why: \(viewport.summaryLabel.toolTip ?? "none")")
    }

    // MARK: - Fixture

    /// The fixture folder copied under a fresh temporary folder, with the viewer bundle's manifest and genome
    /// files that the fixture leaves to the test, and the stats database edited by `statements`.
    private func openFixture(
        editingStatsWith statements: [String],
        manifestCountsAreSet: Bool
    ) throws -> MappingResultViewController {
        let directory = tempDir.appendingPathComponent("supplementary-one-contig", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixtureFolder, to: directory)
        try writeViewerBundleManifest(in: directory, countsAreSet: manifestCountsAreSet)
        let databasePath = directory.appendingPathComponent("fixture.lungfishref/alignments/fixture-track.stats.db").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(handle, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        let result = try MappingResult.load(from: directory)
        let viewport = MappingResultViewController()
        _ = viewport.view
        viewport.setAlignmentTrackSummaryBuilderForTesting { _, _, _ in [Self.measuredRow] }
        viewport.configureForTesting(result: result, resultDirectoryURL: directory)
        return viewport
    }

    private static var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mapping/supplementary-one-contig", isDirectory: true)
    }

    private func writeViewerBundleManifest(in directory: URL, countsAreSet: Bool) throws {
        let bundleURL = directory.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        for name in ["sequence.fa.gz", "sequence.fa.gz.fai", "sequence.fa.gz.gzi"] {
            try Data().write(to: genomeURL.appendingPathComponent(name))
        }
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "org.test.supplementary-one-contig",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "fixture1", length: 1000, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "fixture-track",
                    name: "Original",
                    sourcePath: "alignments/fixture-track.sorted.bam",
                    indexPath: "alignments/fixture-track.sorted.bam.bai",
                    metadataDBPath: "alignments/fixture-track.stats.db",
                    mappedReadCount: countsAreSet ? 12 : nil,
                    unmappedReadCount: countsAreSet ? 1 : nil
                )
            ]
        )
        try manifest.save(to: bundleURL)
    }
}
