import XCTest
import Foundation
@testable import LungfishIO

/// Shared utilities for FASTQ operation round-trip tests.
struct FASTQOperationTestHelper {

    // MARK: - Temp Directory

    static func makeTempDir(prefix: String = "FASTQOpTest") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Bundle Creation

    static func makeBundle(
        named name: String,
        in tempDir: URL,
        fastqFilename: String = "reads.fastq"
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = tempDir.appendingPathComponent(
            "\(name).\(FASTQBundle.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent(fastqFilename)
        return (bundleURL, fastqURL)
    }

    // MARK: - Synthetic FASTQ Writing

    /// Writes deterministic FASTQ records with Phred-33 quality scores.
    static func writeSyntheticFASTQ(
        to url: URL,
        readCount: Int = 100,
        readLength: Int = 150,
        idPrefix: String = "read"
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<readCount {
            let id = "\(idPrefix)\(i + 1)"
            var seq = ""
            for j in 0..<readLength {
                seq.append(bases[(i + j) % 4])
            }
            let qual = String(repeating: "I", count: readLength)
            lines.append(contentsOf: ["@\(id)", seq, "+", qual])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes specific FASTQ records from tuples.
    static func writeFASTQ(records: [(id: String, sequence: String)], to url: URL) throws {
        let lines: [String] = records.flatMap { record in
            [
                "@\(record.id)",
                record.sequence,
                "+",
                String(repeating: "I", count: record.sequence.count),
            ]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes FASTQ records with varying read lengths for length filter testing.
    static func writeVariableLengthFASTQ(
        to url: URL,
        lengths: [Int],
        readsPerLength: Int = 25,
        idPrefix: String = "read"
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        var readIndex = 0
        for length in lengths {
            for i in 0..<readsPerLength {
                readIndex += 1
                let id = "\(idPrefix)\(readIndex)"
                var seq = ""
                for j in 0..<length {
                    seq.append(bases[(readIndex + j) % 4])
                }
                let qual = String(repeating: "I", count: length)
                lines.append(contentsOf: ["@\(id)", seq, "+", qual])
            }
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes FASTQ records where some have an embedded motif at a specific position.
    static func writeMotifEmbeddedFASTQ(
        to url: URL,
        motif: String,
        totalReads: Int = 50,
        readsWithMotif: Int = 25,
        readLength: Int = 150,
        motifPosition: Int = 50
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<totalReads {
            let id = "read\(i + 1)"
            var seq = ""
            for j in 0..<readLength {
                seq.append(bases[(i + j) % 4])
            }
            if i < readsWithMotif {
                var chars = Array(seq)
                for (j, c) in motif.enumerated() {
                    if motifPosition + j < chars.count {
                        chars[motifPosition + j] = c
                    }
                }
                seq = String(chars)
            }
            let qual = String(repeating: "I", count: readLength)
            lines.append(contentsOf: ["@\(id)", seq, "+", qual])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes FASTQ records with a known adapter appended to some reads.
    static func writeAdapterAppendedFASTQ(
        to url: URL,
        adapter: String,
        totalReads: Int = 50,
        readsWithAdapter: Int = 25,
        readLength: Int = 100
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<totalReads {
            let id = "read\(i + 1)"
            var seq = ""
            let insertLen = i < readsWithAdapter ? readLength - adapter.count : readLength
            for j in 0..<insertLen {
                seq.append(bases[(i + j) % 4])
            }
            if i < readsWithAdapter {
                seq += adapter
            }
            let qual = String(repeating: "I", count: seq.count)
            lines.append(contentsOf: ["@\(id)", seq, "+", qual])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes FASTQ records with a known primer prepended to some reads.
    static func writePrimerPrependedFASTQ(
        to url: URL,
        primer: String,
        totalReads: Int = 50,
        readsWithPrimer: Int = 50,
        baseReadLength: Int = 100
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<totalReads {
            let id = "read\(i + 1)"
            var seq = ""
            if i < readsWithPrimer {
                seq += primer
            }
            for j in 0..<baseReadLength {
                seq.append(bases[(i + j) % 4])
            }
            let qual = String(repeating: "I", count: seq.count)
            lines.append(contentsOf: ["@\(id)", seq, "+", qual])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - FASTQ Reading

    static func loadFASTQRecords(from url: URL) async throws -> [FASTQRecord] {
        let reader = FASTQReader(validateSequence: false)
        var records: [FASTQRecord] = []
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }

    // MARK: - Assertions

    /// Asserts that preview.fastq exists in a bundle and contains valid, parseable reads.
    static func assertPreviewValid(
        bundleURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: previewURL.path),
            "preview.fastq missing in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
        let records = try await loadFASTQRecords(from: previewURL)
        XCTAssertGreaterThan(
            records.count, 0,
            "preview.fastq has 0 reads in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
    }

    /// Asserts the manifest payload matches the expected type.
    static func assertPayloadType(
        bundleURL: URL,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            XCTFail("No manifest in \(bundleURL.lastPathComponent)", file: file, line: line)
            return
        }
        let payloadDescription: String
        switch manifest.payload {
        case .subset: payloadDescription = "subset"
        case .trim: payloadDescription = "trim"
        case .full: payloadDescription = "full"
        case .fullPaired: payloadDescription = "fullPaired"
        case .fullMixed: payloadDescription = "fullMixed"
        case .fullFASTA: payloadDescription = "fullFASTA"
        case .demuxedVirtual: payloadDescription = "demuxedVirtual"
        case .demuxGroup: payloadDescription = "demuxGroup"
        case .orientMap: payloadDescription = "orientMap"
        }
        XCTAssertEqual(
            payloadDescription, expected,
            "Expected payload \(expected), got \(payloadDescription)",
            file: file, line: line
        )
    }

    /// Asserts trim-positions.tsv exists and has valid content.
    static func assertTrimPositionsValid(
        bundleURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let trimURL = bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trimURL.path),
            "trim-positions.tsv missing in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
        let positions = try FASTQTrimPositionFile.load(from: trimURL)
        XCTAssertFalse(
            positions.isEmpty,
            "trim-positions.tsv is empty in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
    }

    /// Asserts read-ids.txt exists and has valid content.
    static func assertSubsetIDsValid(
        bundleURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let readIDURL = bundleURL.appendingPathComponent("read-ids.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readIDURL.path),
            "read-ids.txt missing in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
        let content = try String(contentsOf: readIDURL, encoding: .utf8)
        let ids = content.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(
            ids.count, 0,
            "read-ids.txt is empty in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
    }
}
