// ENAFASTQDownloadValidatorTests.swift - Tests for ENA FASTQ download validation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// ENA's HTTP mirror occasionally serves an Apache directory listing (HTTP 200,
/// `text/html`) at the path of a FASTQ mate file that is missing from the
/// mirror, while the portal filereport still advertises the file with a size
/// and MD5. Both download paths must reject such bodies instead of staging
/// them as `.fastq.gz` for fastp.
final class ENAFASTQDownloadValidatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ena-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAcceptsGzipBodyMatchingAdvertisedSize() throws {
        let url = try write(Self.gzipFixture, name: "SRR123456_1.fastq.gz")
        XCTAssertNoThrow(
            try ENAFASTQDownloadValidator.validate(
                fileURL: url,
                expectedBytes: Int64(Self.gzipFixture.count)
            )
        )
    }

    func testAcceptsGzipBodyWhenNoSizeAdvertised() throws {
        let url = try write(Self.gzipFixture, name: "SRR123456_1.fastq.gz")
        XCTAssertNoThrow(try ENAFASTQDownloadValidator.validate(fileURL: url, expectedBytes: nil))
    }

    func testRejectsHTMLDirectoryListingServedAsGzip() throws {
        let html = """
        <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
        <html><head><title>Index of /vol1/fastq/SRR355/093/SRR35517993/SRR35517993_2.fastq.gz</title></head>
        <body><h1>Index of /vol1/fastq/SRR355/093/SRR35517993/SRR35517993_2.fastq.gz</h1></body></html>
        """
        let url = try write(Data(html.utf8), name: "SRR35517993_2.fastq.gz")

        XCTAssertThrowsError(
            try ENAFASTQDownloadValidator.validate(fileURL: url, expectedBytes: 105_338_653)
        ) { error in
            guard case ENAFASTQDownloadValidator.Failure.htmlBody(let filename) = error else {
                return XCTFail("Expected htmlBody failure, got \(error)")
            }
            XCTAssertEqual(filename, "SRR35517993_2.fastq.gz")
            XCTAssertTrue(error.localizedDescription.contains("SRR35517993_2.fastq.gz"))
            XCTAssertTrue(error.localizedDescription.lowercased().contains("html"))
        }
    }

    func testRejectsNonGzipBytesUnderGzipName() throws {
        let url = try write(Data("@SRR123456\nACGT\n+\nIIII\n".utf8), name: "SRR123456_1.fastq.gz")

        XCTAssertThrowsError(
            try ENAFASTQDownloadValidator.validate(fileURL: url, expectedBytes: nil)
        ) { error in
            guard case ENAFASTQDownloadValidator.Failure.notGzip(let filename) = error else {
                return XCTFail("Expected notGzip failure, got \(error)")
            }
            XCTAssertEqual(filename, "SRR123456_1.fastq.gz")
        }
    }

    func testRejectsGzipBodyWhoseSizeDiffersFromAdvertised() throws {
        let url = try write(Self.gzipFixture, name: "SRR123456_1.fastq.gz")

        XCTAssertThrowsError(
            try ENAFASTQDownloadValidator.validate(fileURL: url, expectedBytes: 1_000)
        ) { error in
            guard case ENAFASTQDownloadValidator.Failure.sizeMismatch(let filename, let expected, let actual) = error else {
                return XCTFail("Expected sizeMismatch failure, got \(error)")
            }
            XCTAssertEqual(filename, "SRR123456_1.fastq.gz")
            XCTAssertEqual(expected, 1_000)
            XCTAssertEqual(actual, Int64(Self.gzipFixture.count))
        }
    }

    func testRejectsEmptyFile() throws {
        let url = try write(Data(), name: "SRR123456_1.fastq.gz")
        XCTAssertThrowsError(try ENAFASTQDownloadValidator.validate(fileURL: url, expectedBytes: nil)) { error in
            guard case ENAFASTQDownloadValidator.Failure.empty = error else {
                return XCTFail("Expected empty failure, got \(error)")
            }
        }
    }

    func testUncompressedNameSkipsGzipMagicCheck() throws {
        let url = try write(Data("@SRR123456\nACGT\n+\nIIII\n".utf8), name: "SRR123456_1.fastq")
        XCTAssertNoThrow(try ENAFASTQDownloadValidator.validate(fileURL: url, expectedBytes: nil))
    }

    func testExpectedByteCountsAlignWithPortalURLs() throws {
        let record = try Self.record(
            fastqFTP: "ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_2.fastq.gz",
            fastqBytes: "105944318;105338653"
        )
        XCTAssertEqual(
            ENAFASTQDownloadValidator.expectedByteCounts(for: record),
            [105_944_318, 105_338_653]
        )
    }

    func testExpectedByteCountsPadMissingEntriesWithNil() throws {
        let record = try Self.record(
            fastqFTP: "ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_2.fastq.gz",
            fastqBytes: "26"
        )
        XCTAssertEqual(ENAFASTQDownloadValidator.expectedByteCounts(for: record), [26, nil])

        let noSizes = try Self.record(
            fastqFTP: "ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456.fastq.gz",
            fastqBytes: nil
        )
        XCTAssertEqual(ENAFASTQDownloadValidator.expectedByteCounts(for: noSizes), [nil])
    }

    // MARK: - Helpers

    private func write(_ data: Data, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func record(fastqFTP: String, fastqBytes: String?) throws -> ENAReadRecord {
        var payload: [String: Any] = [
            "run_accession": "SRR123456",
            "library_layout": "PAIRED",
            "fastq_ftp": fastqFTP,
        ]
        if let fastqBytes {
            payload["fastq_bytes"] = fastqBytes
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(ENAReadRecord.self, from: data)
    }

    /// gzip of "@SRR123456\nACGT\n+\nIIII\n" (41 bytes).
    static let gzipFixture = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x73, 0x08, 0x0e, 0x0a,
        0x32, 0x34, 0x32, 0x36, 0x31, 0x35, 0xe3, 0x72, 0x74, 0x76, 0x0f, 0xe1, 0xd2, 0xe6,
        0xf2, 0x04, 0x02, 0x2e, 0x00, 0x11, 0x4b, 0x2a, 0x63, 0x17, 0x00, 0x00, 0x00,
    ])
}
