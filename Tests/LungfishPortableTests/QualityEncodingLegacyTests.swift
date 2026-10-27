// QualityEncodingLegacyTests.swift - The Phred+64 guard refuses old Illumina files and keeps every modern one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishPortable

/// Phase 3.0 lane BIN, fix rounds 2 and 3 (BIO-BIN-QIN, N2, S1). Every storage step now tells BBTools the quality scores
/// are Phred+33 (`qin=33`), so a file in the old Phred+64 encoding (Illumina pipeline 1.3 to 1.7) would be stored 31 too
/// high. `QualityEncoding.looksLikeLegacyPhred64` reads the first 10,000 records and is true when no quality byte is
/// below 64, none is above 105 (`i`), at least one is at or below 69 (`E`) and the mean read length is under 400. LGE's
/// older `detect` is no guard, since it calls a real HiFi read Phred+64 and a real Illumina 1.5 file Phred+33.
final class QualityEncodingLegacyTests: XCTestCase {
    /// 200 reads of 100 bases whose quality bytes run 66 (`B`, Q2) to 104 (`h`, Q40), as Illumina 1.5 wrote them.
    func testIllumina15FileIsRefused() throws {
        let file = try writeFASTQ(reads: 200, length: 100) { read, base in UInt8(66 + (read * 7 + base * 3) % 39) }
        XCTAssertTrue(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// 100 reads of 500 bases at Q31 to Q93 (bytes 64 to 126), 70% of them Q93, the BIO HiFi mix with no score below Q31.
    /// Its bytes are all 64 or more, and the Q93 bytes are above 105, so it is Phred+33.
    func testHiFiAmpliconWithQ93IsKept() throws {
        let file = try writeFASTQ(reads: 100, length: 500) { read, base in
            base % 10 < 7 ? 126 : UInt8(64 + (read * 13 + base * 5) % 62)
        }
        XCTAssertFalse(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// Short Phred+33 reads that hold a score below Q31 (bytes 33 to 74) are modern, whatever the rest holds.
    func testShortReadsWithAScoreBelowQ31AreKept() throws {
        let file = try writeFASTQ(reads: 200, length: 100) { read, base in UInt8(33 + (read * 5 + base * 7) % 42) }
        XCTAssertFalse(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// Reads of 400 bases or more are never taken for Phred+64, even when every byte sits in 66 to 104. The old Illumina
    /// pipelines wrote reads of up to about 150 bases, and a long read set with that range is a modern one.
    func testLongReadsAreKept() throws {
        let file = try writeFASTQ(reads: 100, length: 500) { read, base in UInt8(66 + (read * 7 + base * 3) % 39) }
        XCTAssertFalse(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// An Illumina 1.3 file carries `@` (Q0) and `A` (Q1), so its lowest byte is 64 or 65. 200 reads of 100 bases whose
    /// bytes run 64 (`@`) to 104 (`h`) are refused. The first base of the first read is `@`.
    func testIllumina13FileWithAtSignIsRefused() throws {
        let file = try writeFASTQ(reads: 200, length: 100) { read, base in UInt8(64 + (read * 7 + base * 3) % 41) }
        XCTAssertTrue(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// The edge of the fourth condition. A lowest byte of 69 (`E`, Q5 in Phred+64) is refused.
    func testALowestByteOfEIsRefused() throws {
        let file = try writeFASTQ(reads: 200, length: 100) { read, base in UInt8(69 + (read + base) % 7) }
        XCTAssertTrue(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// The repo's fixtures and wgsim write a constant `I` (Q40, byte 73) on every base. That is Phred+33, and the first
    /// round's three-condition test refused it.
    func testConstantIFixtureIsKept() throws {
        let file = try writeFASTQ(reads: 200, length: 100) { _, _ in UInt8(ascii: "I") }
        XCTAssertFalse(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// Short Phred+33 reads whose scores all sit from Q37 to Q42 (bytes 70 to 75) hold nothing at or below `E` (69), the
    /// byte every Phred+64 file from Illumina 1.3 to 1.7 carries, so they are kept.
    func testPhred33ReadsAtQ37AndAboveAreKept() throws {
        let file = try writeFASTQ(reads: 200, length: 100) { read, base in UInt8(70 + (read + base) % 6) }
        XCTAssertFalse(try QualityEncoding.looksLikeLegacyPhred64(file, launcher: NoChildLauncher()))
    }

    /// A refusal must not send the person to convert a file that is already Phred+33, which would store every score 31
    /// too low.
    func testRefusalWordsWarnAgainstConvertingAModernFile() {
        let words = QualityEncoding.LegacyPhred64Refusal().errorDescription ?? ""
        XCTAssertTrue(words.contains("do not convert it"), words)
        XCTAssertTrue(words.contains("please report the file"), words)
    }

    // MARK: - Helpers

    /// A FASTQ of called bases and the quality byte `quality(read, base)` gives each base.
    private func writeFASTQ(reads: Int, length: Int, quality: (Int, Int) -> UInt8) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QualityEncodingLegacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let bases = Array(String(repeating: "ACGT", count: length / 4 + 1).prefix(length).utf8)
        var bytes: [UInt8] = []
        for read in 0..<reads {
            bytes += Array("@r\(read)\n".utf8)
            bytes += bases
            bytes += Array("\n+\n".utf8)
            bytes += (0..<length).map { quality(read, $0) }
            bytes.append(0x0A)
        }
        let url = folder.appendingPathComponent("reads.fastq")
        try Data(bytes).write(to: url)
        return url
    }
}

/// Plain files need no child, so a test that starts one fails.
private struct NoChildLauncher: PortableChildLauncher {
    struct Refused: Error {}
    func start(_ request: PortableChildRequest) throws -> any PortableChild { throw Refused() }
}
