// NaoMgsGzipReadPinTests.swift - The NAO-MGS gzip readers, pinned before they move to ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Phase 2.13 lane 13.06 (M1). `NaoMgsResultParser.validateHeader` reads the first line of a `.tsv.gz` and stops the
/// decompressor, and `NaoMgsDatabase.createStreaming` reads a `.tsv.gz` in 4 MiB chunks. Both pass at the base and
/// unchanged after the gzip child moves onto ToolProcess.
final class NaoMgsGzipReadPinTests: XCTestCase {
    private var tempDir: URL!

    private static let header = [
        "sample", "seq_id", "aligner_taxid_lca", "query_seq", "query_qual", "prim_align_genome_id_all",
        "prim_align_ref_start", "prim_align_edit_distance", "query_len", "prim_align_query_rc",
        "prim_align_pair_status", "prim_align_subject_title",
    ].joined(separator: "\t")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-gzip-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func row(_ index: Int, padding: Int) -> String {
        let taxon = index % 2 == 0 ? 82658 : 11320
        return "S1\tread\(index)\t\(taxon)\tACGTACGT\tIIIIIIII\tX86557.1\t\(5 + index % 50)\t0\t8\tFalse\tCP\t"
            + String(repeating: "v", count: padding)
    }

    private func table(rows: Int, padding: Int) -> String {
        Self.header + "\n" + (0..<rows).map { row($0, padding: padding) }.joined(separator: "\n") + "\n"
    }

    // MARK: validateHeader

    func testValidateHeaderReadsOnlyTheFirstLineOfAGzipAndLeavesNoChild() async throws {
        let gz = try GzipPinSupport.gzip(table(rows: 8_000, padding: 900), in: tempDir, named: "big-hits.tsv")
        let valid = try await NaoMgsResultParser().validateHeader(at: gz)
        XCTAssertTrue(valid)
        let gone = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(100)) {
            GzipPinSupport.gzipChildCount(for: gz) == 0
        }
        XCTAssertTrue(gone, "no gzip child outlives the header read")
    }

    func testValidateHeaderTakesTheFirstNonBlankLineOfAShortGzip() async throws {
        let blanksFirst = try GzipPinSupport.gzip("\n\n" + Self.header, in: tempDir, named: "blanks.tsv")
        let valid = try await NaoMgsResultParser().validateHeader(at: blanksFirst)
        XCTAssertTrue(valid)
        let headerOnly = try GzipPinSupport.gzip(Self.header + "\n", in: tempDir, named: "header-only.tsv")
        let alsoValid = try await NaoMgsResultParser().validateHeader(at: headerOnly)
        XCTAssertTrue(alsoValid)
    }

    func testValidateHeaderWordsForAnEmptyAWrongAndAMissingFile() async throws {
        let parser = NaoMgsResultParser()
        let empty = try GzipPinSupport.gzip("", in: tempDir, named: "empty.tsv")
        do {
            _ = try await parser.validateHeader(at: empty)
            XCTFail("an empty gzip has no header")
        } catch let error as NaoMgsError {
            XCTAssertTrue("\(error)".contains("File is empty or header line is blank"), "\(error)")
        }
        let wrong = try GzipPinSupport.gzip("foo\tbar\n1\t2\n", in: tempDir, named: "wrong.tsv")
        do {
            _ = try await parser.validateHeader(at: wrong)
            XCTFail("a header without the required columns is refused")
        } catch is NaoMgsError {
        }
        let missing = tempDir.appendingPathComponent("missing.tsv.gz")
        do {
            _ = try await parser.validateHeader(at: missing)
            XCTFail("a missing file is refused")
        } catch let error as NaoMgsError {
            XCTAssertTrue("\(error)".contains("fileNotFound"), "\(error)")
        }
    }

    // MARK: createStreaming

    private func summary(of databaseURL: URL) throws -> (hits: [Int], unique: [Int]) {
        let rows = try NaoMgsDatabase(at: databaseURL).fetchTaxonSummaryRows()
        return (rows.map(\.hitCount).sorted(), rows.map(\.uniqueReadCount).sorted())
    }

    func testCreateStreamingFromAGzipGivesTheRowsOfThePlainFile() async throws {
        let text = table(rows: 45_000, padding: 70)
        XCTAssertGreaterThan(text.utf8.count, 4 * 1_048_576, "the file crosses the reader's 4 MiB chunk")
        let plain = tempDir.appendingPathComponent("plain.tsv")
        try text.write(to: plain, atomically: true, encoding: .utf8)
        let gz = try GzipPinSupport.gzip(text, in: tempDir, named: "hits.tsv")

        let plainDB = tempDir.appendingPathComponent("plain.sqlite")
        let gzDB = tempDir.appendingPathComponent("gzip.sqlite")
        _ = try await NaoMgsDatabase.createStreaming(at: plainDB, from: [plain])
        _ = try await NaoMgsDatabase.createStreaming(at: gzDB, from: [gz])

        let fromPlain = try summary(of: plainDB)
        let fromGzip = try summary(of: gzDB)
        XCTAssertEqual(fromGzip.hits, fromPlain.hits)
        XCTAssertEqual(fromGzip.unique, fromPlain.unique)
        XCTAssertEqual(fromGzip.hits.reduce(0, +), 45_000)
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: gz), 0)
    }

    func testCreateStreamingFromATruncatedGzipKeepsTheRowsGzipDelivered() async throws {
        let gz = try GzipPinSupport.gzip(table(rows: 6_000, padding: 70), in: tempDir, named: "whole.tsv")
        let cut = try GzipPinSupport.truncated(gz, removing: 30, as: "cut.tsv.gz")
        let database = tempDir.appendingPathComponent("cut.sqlite")
        _ = try await NaoMgsDatabase.createStreaming(at: database, from: [cut])
        let total = try summary(of: database).hits.reduce(0, +)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(total, 6_000)
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: cut), 0)
    }
}
