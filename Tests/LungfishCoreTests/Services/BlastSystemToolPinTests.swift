// BlastSystemToolPinTests.swift - What BLAST gets from the real gzip and unzip
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// Pins the output of the two system tools that ``BlastService`` runs, so the move of
/// their launches onto ``ToolProcess`` (Phase 2.10 lane S38) changes none of it.
///
/// The tools are the real `/usr/bin/gzip`, `/usr/bin/zip` and `/usr/bin/unzip`, which every
/// Mac has, so these run in the unit tier like the compressed-input tests of `BlastServiceTests`.
final class BlastSystemToolPinTests: XCTestCase {
    private var tempDir: URL!
    private var service: BlastService!

    override func setUp() async throws {
        tempDir = try TestTempDirectory.make(prefix: "blast-system-tool-pins")
        service = BlastService(httpClient: MockHTTPClient())
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(tempDir)
    }

    /// The Kraken output is 3 MB, so the 1 MiB reads of the line stream cut a line twice. Every
    /// line must come through whole, in a scan and in a lookup, as from the same text uncompressed.
    func testGzipKrakenOutputYieldsEveryLineAcrossReadBoundaries() async throws {
        let fixture = BlastSystemToolFixtures.krakenFixture(lines: 16_000)
        let plain = tempDir.appendingPathComponent("classification.kraken")
        try fixture.text.write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(try Data(contentsOf: plain).count, 2 * 1_048_576)
        let gz = tempDir.appendingPathComponent("classification.kraken.gz")
        try await SystemToolProbe.gzip(plain, to: gz)

        let targets: Set<Int> = [562, 11676]
        let fromGzip = try await service.scanKrakenClassificationOutput(gz, targetTaxIds: targets)
        let fromPlain = try await service.scanKrakenClassificationOutput(plain, targetTaxIds: targets)
        XCTAssertEqual(fromGzip.totalClassified, fixture.classifiedCount)
        XCTAssertEqual(fromGzip.matchingReadIds, fixture.ids(taxIds: targets))
        XCTAssertEqual(fromPlain.totalClassified, fromGzip.totalClassified)
        XCTAssertEqual(fromPlain.matchingReadIds, fromGzip.matchingReadIds)

        let wanted = Set(fixture.hitStrings.keys)
        let hitsFromGzip = try await service.lookupKrakenHitStrings(gz, fragmentIds: wanted)
        let hitsFromPlain = try await service.lookupKrakenHitStrings(plain, fragmentIds: wanted)
        XCTAssertTrue(
            hitsFromGzip == fixture.hitStrings,
            "The hit strings of the gzip output differ from the lines written: \(hitsFromGzip.count) of \(fixture.hitStrings.count)"
        )
        XCTAssertTrue(hitsFromPlain == hitsFromGzip, "The plain and the gzip output give different hit strings")
    }

    /// The FASTQ is 9.7 MB, so the 4 MiB reads of the extraction cut a record twice.
    func testGzipFASTQExtractionKeepsEveryMatchedReadAcrossReadBoundaries() async throws {
        let fixture = BlastSystemToolFixtures.fastqFixture(reads: 45_000)
        XCTAssertGreaterThan(fixture.text.utf8.count, 8 * 1_048_576)
        let plain = tempDir.appendingPathComponent("reads.fastq")
        try fixture.text.write(to: plain, atomically: true, encoding: .utf8)
        let gz = tempDir.appendingPathComponent("reads.fastq.gz")
        try await SystemToolProbe.gzip(plain, to: gz)

        let numbers = Array(stride(from: 3, to: 45_000, by: 1_499))
        let found = try await service.extractMatchingSequences(
            from: gz,
            matchingReadIds: Set(numbers.map { "read_\($0)" }),
            isGzip: true
        )
        XCTAssertEqual(found.map(\.id), numbers.map { "read_\($0)" })
        XCTAssertEqual(found.map(\.sequence), numbers.map { fixture.sequences[$0] })
        XCTAssertTrue(found.allSatisfy { $0.mate == nil })
    }

    /// A tool that fails keeps the words the failure has today.
    func testCorruptGzipFailureKeepsItsWords() async throws {
        let gz = tempDir.appendingPathComponent("broken.kraken.gz")
        try Data("not a gzip stream".utf8).write(to: gz)
        do {
            _ = try await service.scanKrakenClassificationOutput(gz, targetTaxIds: [562])
            XCTFail("A file that is not gzip must fail the scan")
        } catch BlastServiceError.inputReadFailed(let message) {
            XCTAssertTrue(
                message.hasPrefix("gzip decompression failed for \(gz.path) with exit status 1: "),
                message
            )
            XCTAssertTrue(message.localizedCaseInsensitiveContains("not in gzip format"), message)
        }
    }

    /// The files the unzip leaves are the members the service reads. Its results come back in
    /// the order of the queries, `RID_2` before `RID_10`, and the manifest and the text file add none.
    func testResultArchiveYieldsEveryQueryInSubmissionOrder() async throws {
        let mock = MockHTTPClient()
        await mock.register(
            pattern: "blast/Blast.cgi",
            response: .init(
                data: try await BlastSystemToolFixtures.resultArchive(in: tempDir),
                headers: ["Content-Type": "application/zip"]
            )
        )

        let results = try await BlastService(httpClient: mock).getResults(rid: "ZIPPIN")

        XCTAssertEqual(results.map(\.queryId), ["read_1", "read_2", "read_10"])
        XCTAssertEqual(results.map(\.queryLength), [10, 20, 100])
    }

    /// An archive that starts like a ZIP but is not one keeps the words of the failure.
    func testBrokenResultArchiveKeepsItsWords() async throws {
        let mock = MockHTTPClient()
        await mock.register(
            pattern: "blast/Blast.cgi",
            response: .init(data: Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x2A, count: 64))
        )
        do {
            _ = try await BlastService(httpClient: mock).getResults(rid: "BROKEN")
            XCTFail("An archive that is not a ZIP must fail")
        } catch BlastServiceError.resultParsingFailed(let message) {
            XCTAssertTrue(message.hasPrefix("ZIP extraction failed (exit "), message)
        }
    }
}
