// VariantDatabaseGzipStreamCharacterizationTests.swift - Pins what the gzip VCF stream feeds the importer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO
import LungfishTestSupport

/// Pins the bytes that `VariantDatabase+RegionExtraction`'s gzip readers hand
/// to the VCF importer, and the database built from them, on the sarscov2
/// fixture and on synthetic inputs that cross the 64 KB pipe buffer.
///
/// The plain-text reader never spawns a process, so a `.vcf.gz` import must
/// build exactly the database its uncompressed twin builds, byte for byte,
/// CR characters included. The fixture digests were recorded on the
/// `Process()` implementation before the move to ToolProcess (Phase 2.2 lane
/// 3B1, finding R7).
final class VariantDatabaseGzipStreamCharacterizationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcf-gzip-characterization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private var fixtures: URL {
        CLITestBinaryResolver.repositoryRoot(containing: #filePath)
            .appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
    }

    func testFixtureContigsComeFromTheGzipHeader() throws {
        XCTAssertEqual(
            try VariantDatabase.contigsInVCFHeader(url: fixtures.appendingPathComponent("test.vcf.gz"), maxChromosomes: 512),
            ["MT192765.1"]
        )
    }

    func testFixtureGzipImportMatchesTheRecordedDatabase() throws {
        let gzDB = tempDirectory.appendingPathComponent("gz.db")
        let plainDB = tempDirectory.appendingPathComponent("plain.db")
        XCTAssertEqual(try VariantDatabase.createFromVCF(vcfURL: fixtures.appendingPathComponent("test.vcf.gz"), outputURL: gzDB), 9)
        XCTAssertEqual(try VariantDatabase.createFromVCF(vcfURL: fixtures.appendingPathComponent("test.vcf"), outputURL: plainDB), 9)
        let gzDump = try Self.dump(gzDB)
        XCTAssertEqual(gzDump, try Self.dump(plainDB))
        XCTAssertEqual(AlignmentDataProviderCharacterizationTests.digest(gzDump), Self.fixtureDatabaseDigest, gzDump)

        let extracted = tempDirectory.appendingPathComponent("extracted.db")
        let written = try VariantDatabase(url: gzDB).extractRegion(
            chromosome: "MT192765.1", start: 1_000, end: 20_000, outputURL: extracted
        )
        let extractedDump = try Self.dump(extracted)
        XCTAssertEqual(
            "\(written) \(AlignmentDataProviderCharacterizationTests.digest(extractedDump))",
            Self.extractedRegionSummary,
            extractedDump
        )
    }

    func testLargeGzipStreamMatchesPlainTextImport() throws {
        let vcf = Self.syntheticVCF(records: 6_000, lineEnding: "\n")
        XCTAssertGreaterThan(vcf.utf8.count, 256 * 1024, "The stream must cross several pipe buffers")
        let (gz, plain) = try writeBoth(vcf, name: "large")
        let gzDB = tempDirectory.appendingPathComponent("large-gz.db")
        let plainDB = tempDirectory.appendingPathComponent("large-plain.db")
        XCTAssertEqual(try VariantDatabase.createFromVCF(vcfURL: gz, outputURL: gzDB), 6_000)
        XCTAssertEqual(try VariantDatabase.createFromVCF(vcfURL: plain, outputURL: plainDB), 6_000)
        XCTAssertEqual(try Self.dump(gzDB), try Self.dump(plainDB))
    }

    /// The gzip reader splits on LF only, as the plain reader does, so a CR
    /// before the LF stays part of the line on both paths.
    func testCRLFGzipStreamKeepsTheSameBytesAsPlainTextImport() throws {
        let vcf = Self.syntheticVCF(records: 50, lineEnding: "\r\n")
        let (gz, plain) = try writeBoth(vcf, name: "crlf")
        let gzDB = tempDirectory.appendingPathComponent("crlf-gz.db")
        let plainDB = tempDirectory.appendingPathComponent("crlf-plain.db")
        let gzCount = try VariantDatabase.createFromVCF(vcfURL: gz, outputURL: gzDB)
        let plainCount = try VariantDatabase.createFromVCF(vcfURL: plain, outputURL: plainDB)
        XCTAssertEqual(gzCount, plainCount)
        XCTAssertEqual(try Self.dump(gzDB), try Self.dump(plainDB))
    }

    func testCancelledGzipStreamStopsAndReportsCancellation() throws {
        let (gz, _) = try writeBoth(Self.syntheticVCF(records: 20_000, lineEnding: "\n"), name: "cancel")
        var lines = 0
        let cancelled = try VariantDatabase.streamGzipLines(url: gz, shouldCancel: { lines >= 10 }) { _ in lines += 1 }
        XCTAssertTrue(cancelled)
        XCTAssertGreaterThanOrEqual(lines, 10)
        XCTAssertLessThan(lines, 20_005, "Cancellation must stop the stream before its end")
    }

    func testHandlerErrorStopsTheGzipStream() throws {
        struct Stop: Error {}
        let (gz, _) = try writeBoth(Self.syntheticVCF(records: 20_000, lineEnding: "\n"), name: "throw")
        var lines = 0
        XCTAssertThrowsError(try VariantDatabase.streamGzipLines(url: gz) { _ in
            lines += 1
            if lines == 5 { throw Stop() }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(lines, 5)
    }

    func testCorruptGzipReportsTheGzipExitCode() throws {
        let corrupt = tempDirectory.appendingPathComponent("corrupt.vcf.gz")
        try Data("this is not gzip data\n".utf8).write(to: corrupt)
        XCTAssertThrowsError(try VariantDatabase.streamGzipLines(url: corrupt) { _ in }) { error in
            XCTAssertEqual(
                error.localizedDescription,
                VariantDatabaseError.createFailed("Failed to decompress corrupt.vcf.gz (gzip exit code 1)").localizedDescription
            )
        }
    }

    // MARK: - Recorded values

    private static let fixtureDatabaseDigest = "4e74f4546772763665b0c681"
    private static let extractedRegionSummary = "6 a4f97caac195f79a954009ce"

    // MARK: - Helpers

    private func writeBoth(_ text: String, name: String) throws -> (gz: URL, plain: URL) {
        let plain = tempDirectory.appendingPathComponent("\(name).vcf")
        try Data(text.utf8).write(to: plain)
        let gz = tempDirectory.appendingPathComponent("\(name).vcf.gz")
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "/usr/bin/gzip -c \"$0\" > \"$1\"", plain.path, gz.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        return (gz, plain)
    }

    private static func syntheticVCF(records: Int, lineEnding: String) -> String {
        var lines = [
            "##fileformat=VCFv4.2",
            "##contig=<ID=chrA,length=10000000>",
            "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tsampleA\tsampleB",
        ]
        for index in 0..<records {
            let alt = ["C", "G", "T", "CA"][index % 4]
            lines.append("chrA\t\(index * 7 + 1)\tv\(index)\tA\t\(alt)\t\(index % 90).5\tPASS\tDP=\(index % 300)\tGT\t0/1\t1/1")
        }
        return lines.joined(separator: lineEnding) + lineEnding
    }

    /// Every row of the tables an import writes, in id order, as text.
    static func dump(_ url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw XCTSkip("Could not open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var out: [String] = []
        for query in [
            "SELECT chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants ORDER BY id",
            "SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields FROM genotypes ORDER BY variant_id, sample_name",
            "SELECT name, display_name, metadata FROM samples ORDER BY name",
            "SELECT key, type, number, description FROM variant_info_defs ORDER BY key",
            "SELECT variant_id, key, value FROM variant_info ORDER BY variant_id, key",
        ] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                out.append("! \(query)")
                sqlite3_finalize(statement)
                continue
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let columns = (0..<sqlite3_column_count(statement)).map { column -> String in
                    guard let text = sqlite3_column_text(statement, column) else { return "NULL" }
                    return String(cString: text).debugDescription
                }
                out.append(columns.joined(separator: "|"))
            }
            sqlite3_finalize(statement)
            out.append("--")
        }
        return out.joined(separator: "\n")
    }
}
