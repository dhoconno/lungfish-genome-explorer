// BgzipIndexedFASTAReaderCRLFTests.swift - SCI-12 CRLF FASTA regression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishIO

/// SCI-12: `BgzipIndexedFASTAReader` stripped only `"\n"`, leaving a stray
/// `"\r"` (and dropping a base per line) when fetching from a
/// Windows-edited, CRLF-terminated FASTA. The fix reuses
/// `FASTAIndex.sequenceText(fromIndexedWindow:)`, which already strips both
/// LF and CR, matching what `samtools faidx` returns.
final class BgzipIndexedFASTAReaderCRLFTests: XCTestCase {

    private func locateTool(named tool: String) -> String? {
        guard let samtoolsPath = BamFixtureBuilder.locateSamtools() else { return nil }
        let candidate = URL(fileURLWithPath: samtoolsPath)
            .deletingLastPathComponent()
            .appendingPathComponent(tool)
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("\(executable) \(arguments.joined(separator: " ")) failed: \(stderr)")
            throw NSError(domain: "BgzipIndexedFASTAReaderCRLFTests", code: 1)
        }
    }

    private func captureOutput(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("\(executable) \(arguments.joined(separator: " ")) failed")
            throw NSError(domain: "BgzipIndexedFASTAReaderCRLFTests", code: 1)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The exact worked example from the audit: for a CRLF FASTA, a fetch
    /// spanning a line break must equal what `samtools faidx` returns, not
    /// leave a stray `\r` with a dropped base.
    func testFetchMatchesSamtoolsFaidxForCRLFFASTA() async throws {
        guard let samtoolsPath = BamFixtureBuilder.locateSamtools(),
              let bgzipPath = locateTool(named: "bgzip") else {
            throw XCTSkip("samtools/bgzip not available in this environment")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BgzipCRLFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 4bp lines with CRLF terminators (Windows-edited FASTA). Unwrapped
        // sequence is "ACGTACGGGGTTAACC" (16bp).
        let fastaURL = dir.appendingPathComponent("crlf.fa")
        let crlf = "\r\n"
        let plainContent = ">chr1\(crlf)ACGT\(crlf)ACGG\(crlf)GGTT\(crlf)AACC\(crlf)"
        try plainContent.data(using: .utf8)!.write(to: fastaURL)

        let bgzURL = dir.appendingPathComponent("crlf.fa.gz")
        // bgzip -c writes to stdout, so capture it into the .gz file directly.
        FileManager.default.createFile(atPath: bgzURL.path, contents: nil)
        let bgzipProcess = Process()
        bgzipProcess.executableURL = URL(fileURLWithPath: bgzipPath)
        bgzipProcess.arguments = ["-c", fastaURL.path]
        let outHandle = try FileHandle(forWritingTo: bgzURL)
        bgzipProcess.standardOutput = outHandle
        try bgzipProcess.run()
        bgzipProcess.waitUntilExit()
        try outHandle.close()
        XCTAssertEqual(bgzipProcess.terminationStatus, 0)

        try run(samtoolsPath, ["faidx", bgzURL.path])

        let faiURL = URL(fileURLWithPath: bgzURL.path + ".fai")
        let gziURL = URL(fileURLWithPath: bgzURL.path + ".gzi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: faiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gziURL.path))

        // Region 0-based [4,14), spanning three CRLF line breaks in the
        // unwrapped 16bp sequence "ACGTACGGGGTTAACC" -> "ACGGGGTTAA".
        // Compared against samtools faidx (1-based closed "5-14") rather
        // than a hand-computed literal, so the test fails loudly if the
        // fixture itself is ever miscounted.
        let region = GenomicRegion(chromosome: "chr1", start: 4, end: 14)
        let expected = try captureOutput(
            samtoolsPath, ["faidx", bgzURL.path, "chr1:5-14"]
        ).split(separator: "\n").dropFirst().joined()
        XCTAssertEqual(expected, "ACGGGGTTAA")
        XCTAssertFalse(expected.contains("\r"))

        let reader = try await BgzipIndexedFASTAReader(url: bgzURL, faiURL: faiURL, gziURL: gziURL)
        let fetched = try await reader.fetch(region: region)

        XCTAssertEqual(fetched, expected, "Bgzip fetch must match samtools faidx for CRLF FASTA input")
        XCTAssertFalse(fetched.contains("\r"), "Fetched sequence must never contain a stray carriage return")

        let syncReader = try SyncBgzipFASTAReader(url: bgzURL, faiURL: faiURL, gziURL: gziURL)
        let fetchedSync = try syncReader.fetchSync(region: region)
        XCTAssertEqual(fetchedSync, expected)
        XCTAssertFalse(fetchedSync.contains("\r"))
    }
}
