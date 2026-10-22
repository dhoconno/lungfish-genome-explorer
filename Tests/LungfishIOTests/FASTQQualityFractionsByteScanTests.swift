// FASTQQualityFractionsByteScanTests.swift - the byte-level Q20/Q30 scan counts exactly what record parsing counted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// The import's exact Q20/Q30 pass parsed every record of the final FASTQ
/// into a `FASTQRecord`, about 50 MB/s, so a VSP2 bundle of ~100 GB spent
/// half an hour on it. The scan now counts quality bytes as they stream past.
/// Every count here is checked against that record path, which stays the
/// reference: same encoding detected per file, same bases, same thresholds.
final class FASTQQualityFractionsByteScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-quality-byte-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// Phred+33 records that exercise the reader's rules: a wrapped sequence,
    /// a wrapped quality whose second line starts with '@' (Q31) and another
    /// with '+' (Q10), blank lines between records, an empty read, and Q2 to
    /// Q41 values on either side of both thresholds.
    private static let phred33Text = [
        "@r1 first", "ACGTACGTAC", "+", "IIIII55###",
        "",
        "@r2 wrapped", "ACGTA", "CGTAC", "GT", "+r2 wrapped", "?????", "@@++", "+J5",
        "@r3 empty", "", "+", "",
        "", "",
        "@r4", "GGGG", "+", "4?5>",
    ].joined(separator: "\n") + "\n"

    /// Phred+64: every byte at or above '@' and some above 'h', so the
    /// reader detects phred+64 and Q20 is 'T', Q30 is '^'.
    private static let phred64Text = [
        "@p1", "ACGTACGTAC", "+", "iiiii^^TTS",
        "@p2", "ACGT", "+", "SRQ@",
    ].joined(separator: "\n") + "\n"

    private func write(_ text: String, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func gzip(_ url: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-f", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return url.appendingPathExtension("gz")
    }

    /// The count the scan made before it read bytes: every record parsed,
    /// every quality value decoded with the file's detected encoding.
    private func recordCount(_ urls: [URL]) async throws -> FASTQQualityFractions {
        var bases: Int64 = 0, q20: Int64 = 0, q30: Int64 = 0
        let reader = FASTQReader(validateSequence: false)
        for url in urls {
            for try await record in reader.records(from: url) {
                bases += Int64(record.quality.count)
                for index in 0..<record.quality.count {
                    let q = record.quality.qualityAt(index)
                    if q >= 20 { q20 += 1 }
                    if q >= 30 { q30 += 1 }
                }
            }
        }
        return FASTQQualityFractions(baseCount: bases, q20Count: q20, q30Count: q30)
    }

    // MARK: - The scan matches the record count

    func testPhred33FileWithWrappedBlankAndEmptyRecordsMatchesTheRecordCount() async throws {
        let url = try write(Self.phred33Text, name: "phred33.fastq")
        let reference = try await recordCount([url])
        XCTAssertEqual(reference.baseCount, 26, "the fixture holds 26 bases")

        let scanned = try await FASTQQualityFractions.scan(url)

        XCTAssertEqual(scanned, reference)
    }

    func testCRLFLineEndingsAndNoFinalNewlineMatchTheRecordCount() async throws {
        let text = String(Self.phred33Text.dropLast()).replacingOccurrences(of: "\n", with: "\r\n")
        let url = try write(text, name: "crlf.fastq")

        let scanned = try await FASTQQualityFractions.scan(url)
        let reference = try await recordCount([url])

        XCTAssertEqual(scanned, reference)
    }

    func testGzipInputMatchesTheRecordCount() async throws {
        let url = try gzip(try write(Self.phred33Text, name: "phred33.fastq"))

        let scanned = try await FASTQQualityFractions.scan(url)
        let reference = try await recordCount([url])

        XCTAssertEqual(scanned, reference)
    }

    func testEachFileDetectsItsOwnEncoding() async throws {
        let phred64 = try write(Self.phred64Text, name: "phred64.fastq")
        let phred33 = try gzip(try write(Self.phred33Text, name: "phred33.fastq"))
        let reference = try await recordCount([phred64, phred33])
        let phred64Only = try await recordCount([phred64])
        XCTAssertEqual(phred64Only.q30Count, 7, "phred+64 was detected")

        let scanned = try await FASTQQualityFractions.scan([phred64, phred33])

        XCTAssertEqual(scanned, reference)
    }

    /// A chunk can end anywhere, inside a header, a quality line or a CRLF.
    func testEveryChunkBoundaryGivesTheSameCount() async throws {
        let text = Self.phred33Text.replacingOccurrences(of: "\n@r4", with: "\r\n@r4")
        let reference = try await recordCount([try write(text, name: "chunks.fastq")])
        let bytes = Array(text.utf8)

        for chunkSize in [1, 2, 3, 5, 8, 13, bytes.count] {
            var counter = FASTQQualityByteCounter()
            var start = 0
            while start < bytes.count {
                let end = min(start + chunkSize, bytes.count)
                try bytes[start..<end].withUnsafeBytes { try counter.consume($0) }
                start = end
            }
            XCTAssertEqual(try counter.finish(), reference, "chunk size \(chunkSize)")
        }
    }

    /// The record reader refused any line over 1,000,000 characters, so the
    /// import fell back to seqkit's rounded values for such reads.
    func testAReadLongerThanTheRecordReaderLineLimitIsCounted() async throws {
        let length = 1_100_000
        let text = "@long\n" + String(repeating: "A", count: length) + "\n+\n"
            + String(repeating: "I", count: length - 10) + String(repeating: "5", count: 5)
            + String(repeating: "#", count: 5) + "\n"
        let url = try write(text, name: "long.fastq")

        let scanned = try await FASTQQualityFractions.scan(url)

        XCTAssertEqual(scanned, FASTQQualityFractions(
            baseCount: Int64(length), q20Count: Int64(length - 5), q30Count: Int64(length - 10)
        ))
    }

    // MARK: - Malformed input still fails, so callers keep seqkit's values

    func testQualityLongerThanItsSequenceThrows() async throws {
        let url = try write("@r\nACGT\n+\nIIIII\n", name: "long-quality.fastq")
        await assertScanThrows(url)
    }

    func testARecordCutShortThrows() async throws {
        let url = try write("@r\nACGT\n+\nII", name: "truncated.fastq")
        await assertScanThrows(url)
    }

    func testAHeaderWithoutItsAtSignThrows() async throws {
        let url = try write("r\nACGT\n+\nIIII\n", name: "no-at.fastq")
        await assertScanThrows(url)
    }

    private func assertScanThrows(_ url: URL, line: UInt = #line) async {
        do {
            _ = try await FASTQQualityFractions.scan(url)
            XCTFail("expected the scan of \(url.lastPathComponent) to throw", line: line)
        } catch {}
    }
}
