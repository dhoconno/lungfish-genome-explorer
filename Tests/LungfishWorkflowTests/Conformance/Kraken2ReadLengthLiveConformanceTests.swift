// Kraken2ReadLengthLiveConformanceTests.swift - The live form of the kraken2 facts that the read check rests on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane READ-IDENTITY, fix round (BIO SF3). Extract and BLAST Matching Reads compare each read of a Kraken2
// result with the name and length that kraken2 recorded (BIO-READ-IDENTITY 4.1). The check is only as right as three
// facts about the real tool, and the unit tests write their per-read lines by hand. Under `--paired` the ID is the
// fragment name and the length column reads `L|L`. An unpaired run keeps `/1` and `/2` in the ID and gives one length
// a mate. A single read beside a header-only mate, as the read set planner stages a merged read, reads `L|0`. This
// class runs the managed kraken2 on the Kraken2 Viral database with reads cut from the shared SARS-CoV-2 fixture,
// states each fact on the line kraken2 wrote, and extracts from the result with `ClassifierReadResolver`, whose check
// would refuse a result that disagreed with the files.
//
// A missing tool or database is a skip. With LUNGFISH_REQUIRE_TOOLS=1 both are hard failures.

import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class Kraken2ReadLengthLiveConformanceTests: XCTestCase {

    /// Six fragments of mate `x/1` with 40 bases and mate `x/2` with 38 bases, in an R1 and an R2 file, run with
    /// `--paired`: one line a fragment, its ID the fragment name and its length column `40|38`.
    func testPairedRunWritesLLAndDropsTheMateSuffix() async throws {
        let database = try await viralDatabase()
        let scratch = try ConformanceFixtures.tempDir("kraken2-read-length-paired")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pairs = try fixturePairs(count: 6, mate1: 40, mate2: 38)
        let r1 = scratch.appendingPathComponent("sample_R1.fastq")
        let r2 = scratch.appendingPathComponent("sample_R2.fastq")
        try Self.fastq(pairs.indices.map { ("x\($0)/1", pairs[$0].mate1) }).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(pairs.indices.map { ("x\($0)/2", pairs[$0].mate2) }).write(to: r2, atomically: true, encoding: .utf8)
        let config = ClassificationConfig(
            inputFiles: [r1, r2], isPairedEnd: true, databaseName: "Viral", databasePath: database,
            outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
        )

        let result = try await ClassificationPipeline().classify(config: config)

        let lines = try perReadLines(of: result)
        XCTAssertEqual(lines.map(\.id).sorted(), pairs.indices.map { "x\($0)" }.sorted(), "one line a fragment, named without /1")
        XCTAssertEqual(Set(lines.map(\.length)), ["40|38"], "L|L, the length of mate 1 and of mate 2: \(lines)")
        try await assertExtractionMatches(config, lines: lines, in: scratch) { placed in placed.count * 2 }
    }

    /// The same fragments in one interleaved file, run without `--paired`: a line a mate, the ID keeping `/1` and
    /// `/2`, and one length a line.
    func testUnpairedRunKeepsTheSuffixAndOneLengthAMate() async throws {
        let database = try await viralDatabase()
        let scratch = try ConformanceFixtures.tempDir("kraken2-read-length-unpaired")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pairs = try fixturePairs(count: 6, mate1: 40, mate2: 38)
        let interleaved = scratch.appendingPathComponent("interleaved.fastq")
        try Self.fastq(pairs.indices.flatMap { [("x\($0)/1", pairs[$0].mate1), ("x\($0)/2", pairs[$0].mate2)] })
            .write(to: interleaved, atomically: true, encoding: .utf8)
        let config = ClassificationConfig(
            inputFiles: [interleaved], isPairedEnd: false, databaseName: "Viral", databasePath: database,
            outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
        )

        let result = try await ClassificationPipeline().classify(config: config)

        let lines = try perReadLines(of: result)
        var expected: [String: String] = [:]
        for index in pairs.indices {
            expected["x\(index)/1"] = "40"
            expected["x\(index)/2"] = "38"
        }
        XCTAssertEqual(lines.count, expected.count, "a line a mate: \(lines)")
        XCTAssertEqual(Dictionary(lines.map { ($0.id, $0.length) }, uniquingKeysWith: { first, _ in first }), expected)
        // Extract keeps both mates of a fragment when either mate is at the taxon (`keepReadPairs`), so the reads are
        // two for each fragment that has a line at the taxon.
        try await assertExtractionMatches(config, lines: lines, in: scratch) { placed in
            Set(placed.map { Self.fragment($0.id) }).count * 2
        }
    }

    /// A file of six merged reads beside the pairs, as the read set planner stages them with a header-only mate:
    /// the pairs read `40|38` and each merged read `60|0`.
    func testASingleReadBesideAHeaderOnlyMateGivesLZero() async throws {
        let database = try await viralDatabase()
        let scratch = try ConformanceFixtures.tempDir("kraken2-read-length-merged")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pairs = try fixturePairs(count: 6, mate1: 40, mate2: 38)
        let merged = try fixtureSequences("test_1.fastq.gz").reversed().filter { $0.count >= 60 }.prefix(6).map { String($0.prefix(60)) }
        XCTAssertEqual(merged.count, 6, "the fixture holds six reads of at least 60 bases")
        let r1 = scratch.appendingPathComponent("sample_R1.fastq")
        let r2 = scratch.appendingPathComponent("sample_R2.fastq")
        let single = scratch.appendingPathComponent("merged.fastq")
        try Self.fastq(pairs.indices.map { ("x\($0)/1", pairs[$0].mate1) }).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(pairs.indices.map { ("x\($0)/2", pairs[$0].mate2) }).write(to: r2, atomically: true, encoding: .utf8)
        try Self.fastq(merged.indices.map { ("m\($0)", merged[$0]) }).write(to: single, atomically: true, encoding: .utf8)
        var config = ClassificationConfig(
            inputFiles: [r1, r2], isPairedEnd: true, databaseName: "Viral", databasePath: database,
            outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
        )
        config.singleReadFiles = [single]

        let result = try await ClassificationPipeline().classify(config: config)

        let lines = try perReadLines(of: result)
        XCTAssertEqual(lines.count, 12, "six pairs and six merged reads: \(lines)")
        XCTAssertEqual(Set(lines.filter { $0.id.hasPrefix("x") }.map(\.length)), ["40|38"])
        XCTAssertEqual(Set(lines.filter { $0.id.hasPrefix("m") }.map(\.length)), ["60|0"], "L|0, the merged read and an empty mate")
        try await assertExtractionMatches(config, lines: lines, in: scratch) { placed in
            placed.map { $0.length.hasSuffix("|0") ? 1 : 2 }.reduce(0, +)
        }
    }

    // MARK: - Helpers

    /// One line of the per-read output: classified or not, the ID, the taxon and the length column.
    private struct PerReadLine: CustomStringConvertible {
        let status: String
        let id: String
        let taxId: Int
        let length: String

        var description: String { "\(status)\t\(id)\t\(taxId)\t\(length)" }
    }

    /// The managed kraken2 and the Viral database, or a skip (a failure with LUNGFISH_REQUIRE_TOOLS=1).
    private func viralDatabase() async throws -> URL {
        _ = try await ToolAvailability.require("kraken2", environment: "kraken2")
        return try await ToolAvailability.requireDatabase({ try await ConformanceFixtures.viralKrakenDB() }, name: "Kraken2 Viral")
    }

    /// The fragment a read ID names, without the `/1` or `/2` that an unpaired run keeps.
    private static func fragment(_ id: String) -> String {
        id.hasSuffix("/1") || id.hasSuffix("/2") ? String(id.dropLast(2)) : id
    }

    /// Extracts the busiest taxon of `lines` with its own reads from the result in `config.outputDirectory` and
    /// asserts that Extract returns the reads the per-read output names for it: `readsOf` gives the reads that the
    /// lines placed at the taxon stand for. Extract's read check refuses a result whose files disagree with the names
    /// and lengths kraken2 wrote, so a refusal fails the test here.
    private func assertExtractionMatches(
        _ config: ClassificationConfig, lines: [PerReadLine], in scratch: URL, readsOf: ([PerReadLine]) -> Int
    ) async throws {
        let classified = lines.filter { $0.status == "C" }
        let counts = Dictionary(grouping: classified, by: \.taxId).mapValues(\.count)
        let taxId = try XCTUnwrap(
            counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key,
            "kraken2 classified none of the fragments: \(lines)"
        )
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2, resultPath: config.outputDirectory, selections: [ClassifierRowSelector(taxIds: [taxId])],
            options: ExtractionOptions(taxonScope: .exact), destination: .file(scratch.appendingPathComponent("taxon.fastq"))
        )
        let expected = readsOf(classified.filter { $0.taxId == taxId })
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(outcome.readCount, expected, "the reads of the taxon \(taxId) the per-read output names")
    }

    /// The lines of the per-read output a result keeps, beside it as `.kraken.gz` or as the plain file.
    private func perReadLines(of result: ClassificationResult) throws -> [PerReadLine] {
        let candidates = [result.outputURL, result.outputURL.appendingPathExtension("gz")]
        let url = try XCTUnwrap(
            candidates.first { FileManager.default.fileExists(atPath: $0.path) }, "no per-read output beside the result"
        )
        let text = url.pathExtension == "gz" ? try gunzip(url) : try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count >= 4, let taxId = Int(fields[2]) else { return nil }
            return PerReadLine(status: String(fields[0]), id: String(fields[1]), taxId: taxId, length: String(fields[3]))
        }
    }

    /// `count` fragments cut from the shared SARS-CoV-2 pairs, so that the Viral database classifies them: the first
    /// `mate1` bases of an R1 read and the first `mate2` bases of its R2 mate, from reads at least that long.
    private func fixturePairs(count: Int, mate1: Int, mate2: Int) throws -> [(mate1: String, mate2: String)] {
        let pairs = zip(try fixtureSequences("test_1.fastq.gz"), try fixtureSequences("test_2.fastq.gz"))
            .filter { $0.count >= mate1 && $1.count >= mate2 }
            .prefix(count)
            .map { (mate1: String($0.prefix(mate1)), mate2: String($1.prefix(mate2))) }
        XCTAssertEqual(pairs.count, count, "the fixture holds \(count) pairs with reads of \(mate1) and \(mate2) bases")
        return Array(pairs)
    }

    /// The sequence of every record of a gzip FASTQ of the shared SARS-CoV-2 fixture.
    private func fixtureSequences(_ name: String) throws -> [String] {
        let lines = try gunzip(ConformanceFixtures.sarscov2.appendingPathComponent(name))
            .split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 1, to: lines.count, by: 4).map { String(lines[$0]) }
    }

    private func gunzip(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip -dc \(url.lastPathComponent)")
        return String(decoding: data, as: UTF8.self)
    }

    private static func fastq(_ records: [(String, String)]) -> String {
        records.map { "@\($0.0)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
    }
}
