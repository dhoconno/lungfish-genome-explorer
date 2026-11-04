// FASTAIndexEmptyRecordConformanceTests.swift - What a real samtools faidx writes for an empty record (FASTAREAD review, backlog item 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

/// `FASTAIndex.init(url:)` refuses a record with bases and no bases per line. That must never hit an index that a good
/// tool writes. This class runs the real `samtools faidx` and `bgzip` over FASTA files with empty records, found with
/// `BamFixtureBuilder.locateSamtools()` as the other tool tests do, and opens what they write. Measured with samtools
/// 1.24: an empty record in the first or middle place is left out of the index, and a file that ends on an empty
/// record is refused with exit 1 and no index, so no line has length 0 or 0 bases per line.
/// It needs the tools, and fails in place of a skip under `LUNGFISH_REQUIRE_TOOLS=1`.
final class FASTAIndexEmptyRecordConformanceTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = try TestTempDirectory.make(prefix: "FASTAIndexEmptyRecordConformanceTests")
    }

    override func tearDown() async throws {
        if let tempDirectory { TestTempDirectory.cleanup(tempDirectory) }
    }

    // MARK: - Tools

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) throws -> (samtools: String, bgzip: String) {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is required", file: file, line: line)
        }
        let bgzip = URL(fileURLWithPath: samtools).deletingLastPathComponent().appendingPathComponent("bgzip").path
        guard FileManager.default.isExecutableFile(atPath: bgzip) else {
            try ToolAvailability.skipOrFail("bgzip is required beside samtools", file: file, line: line)
        }
        return (samtools, bgzip)
    }

    /// Runs a tool, with its standard output written to `output` when one is given, and returns its exit status.
    private func run(_ executable: String, _ arguments: [String], output: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = Pipe()
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            process.standardOutput = Pipe()
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Every FASTA below has `a`, `b` or `c` as a real record, and `e` followed by a digit as an empty one.
    private let indexed: [(name: String, fasta: String, bases: [String: String])] = [
        ("first", ">e1\n>b\nACGT\n", ["b": "ACGT"]),
        ("middle", ">a\nACGT\n>e2\n>c\nGG\n", ["a": "ACGT", "c": "GG"]),
        ("blank-line", ">a\nACGT\n>e5\n\n>c\nGG\n", ["a": "ACGT", "c": "GG"]),
        ("crlf", ">a\r\nACGT\r\n>e6\r\n>c\r\nGG\r\n", ["a": "ACGT", "c": "GG"]),
    ]

    // MARK: - Tests

    /// samtools leaves the empty record out, so the index it writes opens and reads every real record back.
    func testSamtoolsIndexOfAFastaWithEmptyRecordsOpensAndReads() throws {
        let tools = try requireTools()

        for fixture in indexed {
            let fastaURL = tempDirectory.appendingPathComponent("\(fixture.name).fa")
            try Data(fixture.fasta.utf8).write(to: fastaURL)
            XCTAssertEqual(try run(tools.samtools, ["faidx", fastaURL.path]), 0, "samtools faidx \(fixture.name)")

            let index = try FASTAIndex(url: fastaURL.appendingPathExtension("fai"))
            let reader = try IndexedFASTAReader(url: fastaURL)

            XCTAssertEqual(Set(index.sequenceNames), Set(fixture.bases.keys), "\(fixture.name): the empty record is left out")
            for name in index.sequenceNames {
                let entry = try XCTUnwrap(index.entry(for: name))
                XCTAssertGreaterThan(entry.length, 0, "\(fixture.name) \(name)")
                XCTAssertGreaterThan(entry.lineBases, 0, "\(fixture.name) \(name)")
                let expected = try XCTUnwrap(fixture.bases[name])
                XCTAssertEqual(
                    try reader.fetchSync(region: GenomicRegion(chromosome: name, start: 0, end: entry.length)),
                    expected,
                    "\(fixture.name) \(name)"
                )
            }
        }
    }

    /// The same holds for a bgzip file, which the bgzip readers open with the `.fai` and `.gzi` the tools write.
    func testSamtoolsIndexOfABgzipFastaWithEmptyRecordsOpensAndReads() async throws {
        let tools = try requireTools()
        let fixture = try XCTUnwrap(indexed.first { $0.name == "middle" })
        let fastaURL = tempDirectory.appendingPathComponent("bgzip.fa")
        let gzURL = tempDirectory.appendingPathComponent("bgzip.fa.gz")
        try Data(fixture.fasta.utf8).write(to: fastaURL)
        XCTAssertEqual(try run(tools.bgzip, ["-c", fastaURL.path], output: gzURL), 0, "bgzip")
        XCTAssertEqual(try run(tools.samtools, ["faidx", gzURL.path]), 0, "samtools faidx of the bgzip file")

        let faiURL = gzURL.appendingPathExtension("fai")
        let gziURL = gzURL.appendingPathExtension("gzi")
        let index = try FASTAIndex(url: faiURL)
        let reader = try await BgzipIndexedFASTAReader(url: gzURL, faiURL: faiURL, gziURL: gziURL)
        let syncReader = try SyncBgzipFASTAReader(url: gzURL, faiURL: faiURL, gziURL: gziURL)

        XCTAssertEqual(Set(index.sequenceNames), ["a", "c"])
        let first = try await reader.fetch(region: GenomicRegion(chromosome: "a", start: 0, end: 4))
        XCTAssertEqual(first, "ACGT")
        XCTAssertEqual(try syncReader.fetchSync(region: GenomicRegion(chromosome: "c", start: 0, end: 2)), "GG")
    }

    /// samtools refuses a file that ends on an empty record, and writes no index for the refusal to hit.
    func testSamtoolsRefusesAFastaThatEndsOnAnEmptyRecord() throws {
        let tools = try requireTools()

        for (name, fasta) in [("last", ">a\nACGT\n>e3\n"), ("only", ">e4\n")] {
            let fastaURL = tempDirectory.appendingPathComponent("\(name).fa")
            try Data(fasta.utf8).write(to: fastaURL)

            XCTAssertNotEqual(try run(tools.samtools, ["faidx", fastaURL.path]), 0, "samtools faidx \(name)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fastaURL.appendingPathExtension("fai").path), "\(name) leaves no index")
        }
    }
}
