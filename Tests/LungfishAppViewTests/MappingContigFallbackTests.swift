import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

/// Walk finding WF-4. The mapping contig table showed the mapped-read count of the track's
/// stats database (idxstats, which counts supplementary records) beside zeros for depth,
/// breadth, MAPQ and identity that nobody measured. These tests open the fixture in
/// `Tests/Fixtures/mapping/supplementary-one-contig` (10 primary mapped reads, 2
/// supplementary records and 1 unmapped read, so idxstats says 12 and flagstat 12 of 13)
/// and check that the table shows the record's rows or the builder's rows and nothing else.
@MainActor
final class MappingContigFallbackTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping_contig_fallback_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    /// Values that differ from the record's on purpose, so a test can tell the builder's rows
    /// from the record's rows.
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

    // MARK: - The builder fails

    func testBuilderFailureKeepsTheRecordsRowsAndSaysSo() async throws {
        let (viewport, result) = try openFixture { _, _, _ in throw MeasureFailure() }
        await viewport.mappingRowsRefreshTask?.value

        let record = try XCTUnwrap(result.contigs.first)
        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 1)
        let shown = try XCTUnwrap(viewport.testContigTableView.record(at: 0))
        XCTAssertEqual(shown.mappedReads, 10, "an idxstats count that includes supplementary records reads 12")
        XCTAssertEqual(shown.meanDepth, record.meanDepth)
        XCTAssertEqual(shown.coverageBreadth, record.coverageBreadth)
        XCTAssertEqual(shown.medianMAPQ, record.medianMAPQ)
        XCTAssertEqual(shown.meanIdentity, record.meanIdentity)
        XCTAssertGreaterThan(shown.meanDepth, 0)
        XCTAssertGreaterThan(shown.coverageBreadth, 0)
        XCTAssertGreaterThan(shown.medianMAPQ, 0)
        XCTAssertGreaterThan(shown.meanIdentity, 0)
        XCTAssertTrue(
            viewport.testSummaryText.contains(
                "Could not measure the alignment statistics for Original: samtools coverage failed for the fixture"
            ),
            "the summary bar reads: \(viewport.testSummaryText)"
        )
    }

    func testCopyRowAsTSVWritesTheRecordsMeanDepth() async throws {
        let (viewport, result) = try openFixture { _, _, _ in throw MeasureFailure() }
        await viewport.mappingRowsRefreshTask?.value
        let record = try XCTUnwrap(result.contigs.first)

        let pasteboard = TSVPasteboard()
        viewport.testContigTableView.scalarPasteboard = pasteboard
        viewport.testContigTableView.copy(nil)

        let lines = try XCTUnwrap(pasteboard.lastString).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "a header and the one contig row")
        let titles = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let fields = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let depthColumn = try XCTUnwrap(titles.firstIndex(of: "Mean Depth"))
        let readsColumn = try XCTUnwrap(titles.firstIndex(of: "Mapped Reads"))
        XCTAssertEqual(fields[readsColumn], "10")
        XCTAssertEqual(fields[depthColumn], String(record.meanDepth))
    }

    // MARK: - While the builder runs

    func testWhileTheBuilderRunsTheMappingsOwnTrackShowsTheRecordsRows() async throws {
        let gate = BuilderGate()
        defer { gate.open() }
        let (viewport, result) = try openFixture { _, _, _ in
            await gate.wait()
            return [Self.measuredRow]
        }
        try await waitUntil { gate.arrivals == 1 }

        let record = try XCTUnwrap(result.contigs.first)
        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 1)
        let shown = try XCTUnwrap(viewport.testContigTableView.record(at: 0))
        XCTAssertEqual(shown.mappedReads, 10)
        XCTAssertEqual(shown.meanDepth, record.meanDepth)
        XCTAssertEqual(shown.medianMAPQ, record.medianMAPQ)
        XCTAssertEqual(viewport.testSummaryText, "minimap2 Mapping — 10 / 11 reads mapped (90.9%)")

        let refresh = try XCTUnwrap(viewport.mappingRowsRefreshTask)
        gate.open()
        await refresh.value
        XCTAssertEqual(viewport.testContigTableView.record(at: 0)?.meanDepth, Self.measuredRow.meanDepth)
    }

    func testWhileTheBuilderRunsAnotherTrackShowsNoRows() async throws {
        let gate = BuilderGate()
        defer { gate.open() }
        let (viewport, _) = try openFixture(originalSourcePath: "/elsewhere/reads/other.sorted.bam") { _, _, _ in
            await gate.wait()
            return [Self.measuredRow]
        }
        try await waitUntil { gate.arrivals == 1 }

        XCTAssertEqual(
            viewport.testContigTableView.displayedRows.map(\.mappedReads), [],
            "a track that is not the mapping's own has no measured rows yet"
        )
        XCTAssertEqual(viewport.testSummaryText, "Original — 10 / 11 reads mapped (90.9%)")

        let refresh = try XCTUnwrap(viewport.mappingRowsRefreshTask)
        gate.open()
        await refresh.value
        XCTAssertEqual(viewport.testContigTableView.displayedRows.map(\.mappedReads), [10])
    }

    // MARK: - The header

    func testHeaderCountsPrimaryReadsAndNotAlignmentRecords() async throws {
        let (viewport, _) = try openFixture { _, _, _ in [Self.measuredRow] }
        await viewport.mappingRowsRefreshTask?.value

        XCTAssertEqual(
            viewport.testSummaryText, "Original — 10 / 11 reads mapped (90.9%)",
            "flagstat mapped and total (12 and 13) count the supplementary records"
        )
    }

    func testBuilderIsGivenThePrimaryReadTotalForTheMappedPercentage() async throws {
        var totals: [Int] = []
        let (viewport, _) = try openFixture { _, totalReads, _ in
            totals.append(totalReads)
            return [Self.measuredRow]
        }
        await viewport.mappingRowsRefreshTask?.value

        XCTAssertEqual(totals, [11])
    }

    // MARK: - All Alignments

    func testAllAlignmentsShowsTheBuildersRowsNotTheStatsDatabaseCounts() async throws {
        let (viewport, _) = try openFixture(originalSourcePath: "/elsewhere/reads/other.sorted.bam") { _, _, _ in
            [Self.measuredRow]
        }
        await viewport.mappingRowsRefreshTask?.value

        viewport.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.visibleAlignmentTrackID: ""])
        await viewport.mappingRowsRefreshTask?.value

        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 1)
        let shown = try XCTUnwrap(viewport.testContigTableView.record(at: 0))
        XCTAssertEqual(shown.alignmentTrackID, "fixture-track")
        XCTAssertEqual(shown.mappedReads, 10)
        XCTAssertEqual(shown.meanDepth, Self.measuredRow.meanDepth)
        XCTAssertEqual(shown.coverageBreadth, Self.measuredRow.coverageBreadth)
        XCTAssertEqual(shown.medianMAPQ, Self.measuredRow.medianMAPQ)
        XCTAssertEqual(shown.meanIdentity, Self.measuredRow.meanIdentity)
        XCTAssertEqual(viewport.testSummaryText, "minimap2 Mapping — 10 / 11 reads mapped (90.9%)")
    }

    func testAllAlignmentsReusesTheRecordsRowsForTheMappingsOwnTrack() async throws {
        var builderCalls = 0
        let (viewport, result) = try openFixture { _, _, _ in
            builderCalls += 1
            return [Self.measuredRow]
        }
        await viewport.mappingRowsRefreshTask?.value
        let callsAtOpen = builderCalls

        viewport.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.visibleAlignmentTrackID: ""])
        await viewport.mappingRowsRefreshTask?.value

        let record = try XCTUnwrap(result.contigs.first)
        XCTAssertEqual(builderCalls, callsAtOpen, "the record already holds the rows of its own BAM")
        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 1)
        let shown = try XCTUnwrap(viewport.testContigTableView.record(at: 0))
        XCTAssertEqual(shown.alignmentTrackID, "fixture-track")
        XCTAssertEqual(shown.mappedReads, 10)
        XCTAssertEqual(shown.meanDepth, record.meanDepth)
        XCTAssertEqual(shown.coverageBreadth, record.coverageBreadth)
        XCTAssertEqual(shown.medianMAPQ, record.medianMAPQ)
        XCTAssertEqual(shown.meanIdentity, record.meanIdentity)
    }

    func testAllAlignmentsShowsNoRowsAndSaysSoWhenTheBuilderFailsForAnotherTrack() async throws {
        let (viewport, _) = try openFixture(originalSourcePath: "/elsewhere/reads/other.sorted.bam") { _, _, _ in
            throw MeasureFailure()
        }
        await viewport.mappingRowsRefreshTask?.value

        viewport.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.visibleAlignmentTrackID: ""])
        await viewport.mappingRowsRefreshTask?.value

        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 0)
        XCTAssertTrue(
            viewport.testSummaryText.contains(
                "Could not measure the alignment statistics for Original: samtools coverage failed for the fixture"
            ),
            "the summary bar reads: \(viewport.testSummaryText)"
        )
    }

    // MARK: - The mapping's own BAM

    func testOwnBAMIsRecognisedByItsFolderAndFileName() {
        let result = URL(fileURLWithPath: "/Projects/A.lungfish/Analyses/minimap2-2026-10-24/sample.sorted.bam")
        func isOwn(_ path: String?) -> Bool {
            AlignmentTrackStatsSnapshot.isImported(fromPath: path, resultBAM: result)
        }

        XCTAssertTrue(isOwn("/Projects/A.lungfish/Analyses/minimap2-2026-10-24/sample.sorted.bam"))
        XCTAssertTrue(
            isOwn("/Volumes/Clone/B.lungfish/Analyses/minimap2-2026-10-24/sample.sorted.bam"),
            "a project that was moved or cloned keeps the folder and the file name"
        )
        XCTAssertTrue(
            isOwn("@/Analyses/minimap2-2026-10-24/sample.sorted.bam"),
            "a saved project stores the BAM path relative to the project as @/..."
        )
        XCTAssertFalse(
            isOwn("/Projects/A.lungfish/Analyses/minimap2-2026-10-24/v.lungfishref/alignments/fixture-track.sorted.bam"),
            "a filtered track names the track it was made from"
        )
        XCTAssertFalse(
            isOwn("/Projects/A.lungfish/Analyses/minimap2-2026-10-25/sample.sorted.bam"),
            "another run of the same sample"
        )
        XCTAssertFalse(isOwn(nil))
        XCTAssertFalse(isOwn(""))
        XCTAssertFalse(AlignmentTrackStatsSnapshot.isImported(fromPath: "/a/b/sample.sorted.bam", resultBAM: nil))
    }

    // MARK: - Fixture

    /// The fixture folder copied under a fresh temporary folder of the same name, with the
    /// viewer bundle's manifest and genome files that the fixture leaves to the test.
    private func openFixture(
        originalSourcePath: String? = nil,
        builder: @escaping (URL, Int, Set<String>) async throws -> [MappingContigSummary]
    ) throws -> (MappingResultViewController, MappingResult) {
        let directory = tempDir.appendingPathComponent("supplementary-one-contig", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixtureFolder, to: directory)
        try writeViewerBundleManifest(in: directory)
        if let originalSourcePath {
            let database = try AlignmentMetadataDatabase.openForUpdate(
                at: directory.appendingPathComponent("fixture.lungfishref/alignments/fixture-track.stats.db")
            )
            database.setFileInfo("original_source_path", value: originalSourcePath)
        }
        let result = try MappingResult.load(from: directory)
        let viewport = MappingResultViewController()
        _ = viewport.view
        viewport.setAlignmentTrackSummaryBuilderForTesting(builder)
        viewport.configureForTesting(result: result, resultDirectoryURL: directory)
        return (viewport, result)
    }

    private static var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mapping/supplementary-one-contig", isDirectory: true)
    }

    private func writeViewerBundleManifest(in directory: URL) throws {
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
                    mappedReadCount: 12,
                    unmappedReadCount: 1
                )
            ]
        )
        try manifest.save(to: bundleURL)
    }

    /// Returns as soon as `predicate` holds, or fails the test when the budget runs out.
    private func waitUntil(
        timeout: TimeInterval = WaitBudget.standard.seconds,
        predicate: @MainActor @escaping () -> Bool
    ) async throws {
        let held = await LungfishTestSupport.waitUntil(timeout: .seconds(timeout)) { predicate() }
        if !held {
            XCTFail("Timed out waiting for condition")
        }
    }
}

private struct MeasureFailure: LocalizedError {
    var errorDescription: String? { "samtools coverage failed for the fixture" }
}

/// Holds a stubbed summary build until the test opens it, so a test can look at the table
/// while the build runs.
private final class BuilderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var arrivals: Int { lock.withLock { arrived } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumesNow = lock.withLock { () -> Bool in
                arrived += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumesNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let held = waiters
            waiters = []
            return held
        }
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private final class TSVPasteboard: PasteboardWriting {
    private(set) var lastString: String?

    func setString(_ string: String) {
        lastString = string
    }
}
