// BundleTrackListingAndProgressTests.swift - `bundle info` / `bundle list` show alignment tracks; `map` progress is line-oriented off a TTY
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO

final class BundleTrackListingAndProgressTests: XCTestCase {
    private var manifest: BundleManifest {
        BundleManifest(
            name: "Fixture",
            identifier: "test.fixture",
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln_1",
                    name: "Sample A reads",
                    sourcePath: "alignments/aln_1.sorted.bam",
                    indexPath: "alignments/aln_1.sorted.bam.bai",
                    mappedReadCount: 12_345
                ),
                AlignmentTrackInfo(
                    id: "aln_2",
                    name: "Sample B reads",
                    format: .cram,
                    sourcePath: "alignments/aln_2.cram",
                    indexPath: "alignments/aln_2.cram.crai"
                ),
            ]
        )
    }

    func testBundleInfoTableListsAlignmentTracks() {
        let formatter = TerminalFormatter(useColors: false)
        XCTAssertEqual(BundleAlignmentTrackListing.tableHeaders, ["ID", "Name", "Format", "Mapped Reads", "Path"])
        XCTAssertEqual(
            BundleAlignmentTrackListing.tableRows(manifest.alignments, formatter: formatter),
            [
                ["aln_1", "Sample A reads", "bam", formatter.number(12_345), "alignments/aln_1.sorted.bam"],
                ["aln_2", "Sample B reads", "cram", "-", "alignments/aln_2.cram"],
            ]
        )
    }

    func testBundleListLinesAndJSONListAlignmentTracks() throws {
        let formatter = TerminalFormatter(useColors: false)
        XCTAssertEqual(
            BundleAlignmentTrackListing.listLines(manifest.alignments, formatter: formatter),
            [
                "aln_1: Sample A reads (bam, \(formatter.number(12_345)) mapped reads) alignments/aln_1.sorted.bam",
                "aln_2: Sample B reads (cram) alignments/aln_2.cram",
            ]
        )

        let data = try JSONEncoder().encode(BundleTrackList(manifest: manifest))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["alignments"] as? [String], ["aln_1", "aln_2"])
        XCTAssertEqual(object["annotations"] as? [String], [])
    }

    func testMapProgressIsOneLinePerUpdateOffATerminal() {
        XCTAssertEqual(MapProgressLine.render("Mapping reads", isTerminal: true), "\rMapping reads")
        XCTAssertEqual(MapProgressLine.render("Mapping reads", isTerminal: false), "Mapping reads\n")
    }

    // MARK: - Reads, not supplementary alignment records

    /// A bundle written before this release keeps the idxstats sum in its manifest, 12 for the supplementary fixture
    /// whose 11 reads hold 10 mapped reads and 2 supplementary alignments. The stats database holds flagstat's counts.
    func testBundleInfoListsMappedReadsFromTheStatsDatabaseOverTheManifest() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        let command = try BundleInfoSubcommand.parse(["--no-color", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let row = try XCTUnwrap(output.split(separator: "\n").first { $0.contains("fixture-track") }, output)
        let cells = row.split(separator: " ").map(String.init)
        XCTAssertTrue(cells.contains("10"), "Mapped Reads reads 10 reads: \(row)")
        XCTAssertFalse(cells.contains("12"), "not the manifest's 12 alignment records: \(row)")
    }

    func testBundleListShowsMappedReadsFromTheStatsDatabaseOverTheManifest() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        let command = try BundleListSubcommand.parse(["--no-color", "--tracks", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        XCTAssertTrue(output.contains("fixture-track: Original (bam, 10 mapped reads)"), output)
    }

    /// The JSON form of `bundle info` prints the manifest, so it printed the idxstats sum a bundle written before this
    /// release keeps there, 12, for a track whose stats database holds 10 mapped reads. Scripts read this form.
    func testBundleInfoJSONPrintsReadsFromTheStatsDatabaseOverTheManifest() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        let command = try BundleInfoSubcommand.parse(["--format", "json", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], output)
        let manifest = try XCTUnwrap(object["manifest"] as? [String: Any], output)
        let track = try XCTUnwrap((manifest["alignments"] as? [[String: Any]])?.first, output)
        XCTAssertEqual(track["mapped_read_count"] as? Int, 10, "10 mapped reads, not the manifest's 12 alignment records")
        XCTAssertEqual(track["unmapped_read_count"] as? Int, 1)
        XCTAssertEqual(track["source_path"] as? String, "alignments/fixture-track.sorted.bam")
        let bases = try XCTUnwrap(object["mapped_read_count_basis"] as? [String: String], "each count says what it counts: \(output)")
        XCTAssertEqual(bases["fixture-track"], "reads")
    }

    // MARK: - A count says what it counts and where it comes from

    /// A stats database that cannot be read gives no flagstat count, so the listing falls back to the manifest's count.
    /// The fallback was silent, and a manifest from before this release holds the idxstats sum, 12 for 10 reads.
    func testBundleListSaysTheCountIsFromTheManifestWhenTheStatsDatabaseIsDamaged() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        try Data("not a database".utf8).write(to: bundleURL.appendingPathComponent("alignments/fixture-track.stats.db"))
        let command = try BundleListSubcommand.parse(["--no-color", "--tracks", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.contains("fixture-track:") }.map(String.init), output)
        XCTAssertTrue(line.contains("12"), "the manifest's number is still the number to show: \(line)")
        XCTAssertTrue(line.contains("manifest"), "the line says the count is the manifest's: \(line)")
        XCTAssertFalse(line.contains("12 mapped reads"), "an unreadable database gives no read count: \(line)")
    }

    func testBundleInfoSaysTheCountIsFromTheManifestWhenTheStatsDatabaseIsMissing() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("alignments/fixture-track.stats.db"))
        let command = try BundleInfoSubcommand.parse(["--no-color", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let row = try XCTUnwrap(output.split(separator: "\n").first { $0.contains("fixture-track") }.map(String.init), output)
        XCTAssertTrue(row.contains("12"), "the manifest's number is still the number to show: \(row)")
        XCTAssertTrue(row.contains("manifest"), "the row says the count is the manifest's: \(row)")
    }

    /// A database with idxstats and flagstat's `mapped` line but no `primary` lines holds alignment records.
    func testBundleListLabelsAlignmentsWhenTheStatsDatabaseHasNoPrimaryLines() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        let databaseURL = bundleURL.appendingPathComponent("alignments/fixture-track.stats.db")
        try FileManager.default.removeItem(at: databaseURL)
        do {
            let database = try AlignmentMetadataDatabase.create(at: databaseURL)
            database.addChromosomeStats(chromosome: "fixture1", length: 1_000, mapped: 12, unmapped: 0)
            database.addFlagStat(category: "total", qcPass: 13, qcFail: 0)
            database.addFlagStat(category: "mapped", qcPass: 12, qcFail: 0)
        }
        let command = try BundleListSubcommand.parse(["--no-color", "--tracks", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.contains("fixture-track:") }.map(String.init), output)
        XCTAssertTrue(line.contains("12 mapped alignments"), "alignment records are labelled as such: \(line)")
        XCTAssertFalse(line.contains("mapped reads"), "alignment records are no reads: \(line)")
    }

    /// `bundle info --format json` keeps `mapped_read_count` and says beside it what each count counts (review of lane MAPPED, F3).
    func testBundleInfoJSONSaysTheCountIsTheManifestsWhenTheStatsDatabaseIsMissing() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("alignments/fixture-track.stats.db"))
        let command = try BundleInfoSubcommand.parse(["--format", "json", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], output)
        let track = try XCTUnwrap(((object["manifest"] as? [String: Any])?["alignments"] as? [[String: Any]])?.first, output)
        XCTAssertEqual(track["mapped_read_count"] as? Int, 12, "the key keeps its meaning and the manifest's number")
        let bases = try XCTUnwrap(object["mapped_read_count_basis"] as? [String: String], output)
        XCTAssertEqual(bases["fixture-track"], "manifest", "a script can tell the manifest's copy from reads")
    }

    func testBundleInfoJSONSaysAlignmentsWhenTheStatsDatabaseHasNoPrimaryLines() async throws {
        let bundleURL = try makeBundleWithSupplementaryTrack()
        let databaseURL = bundleURL.appendingPathComponent("alignments/fixture-track.stats.db")
        try FileManager.default.removeItem(at: databaseURL)
        do {
            let database = try AlignmentMetadataDatabase.create(at: databaseURL)
            database.addChromosomeStats(chromosome: "fixture1", length: 1_000, mapped: 12, unmapped: 0)
            database.addFlagStat(category: "total", qcPass: 13, qcFail: 0)
            database.addFlagStat(category: "mapped", qcPass: 12, qcFail: 0)
        }
        let command = try BundleInfoSubcommand.parse(["--format", "json", bundleURL.path])
        let output = try await captureStandardOutput { try await command.run() }

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], output)
        let bases = try XCTUnwrap(object["mapped_read_count_basis"] as? [String: String], output)
        XCTAssertEqual(bases["fixture-track"], "alignments", "alignment records are no reads, and a script can see it")
    }

    /// A copy of the fixture's viewer bundle (stats database, BAM and index) with a manifest that lists the track
    /// with the old idxstats counts, as a bundle written before this release does.
    private func makeBundleWithSupplementaryTrack() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-mapped-reads-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtureBundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mapping/supplementary-one-contig/fixture.lungfishref", isDirectory: true)
        let bundleURL = folder.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureBundle, to: bundleURL)
        let manifest = BundleManifest(
            name: "Fixture",
            identifier: "test.fixture",
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            alignments: [
                AlignmentTrackInfo(
                    id: "fixture-track",
                    name: "Original",
                    sourcePath: "alignments/fixture-track.sorted.bam",
                    indexPath: "alignments/fixture-track.sorted.bam.bai",
                    metadataDBPath: "alignments/fixture-track.stats.db",
                    mappedReadCount: 12,
                    unmappedReadCount: 1
                ),
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        // Flush what earlier tests left in the buffer before the redirect. A process that runs many classes with
        // stdout on a file or a pipe keeps their text there, and it would reach this pipe ahead of the JSON.
        fflush(stdout)
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
