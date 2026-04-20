import XCTest
import Foundation
@testable import LungfishIO

/// Shared utilities for FASTQ operation round-trip tests.
struct FASTQOperationTestHelper {

    private static let dnaBases: [Character] = ["A", "C", "G", "T"]

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

    private static func defaultOverlapLength(for readLength: Int) -> Int {
        max(6, min(readLength / 3, readLength - 4))
    }

    private static func deterministicDNA(length: Int, seed: UInt64) -> String {
        var state = seed &+ 0x9e3779b97f4a7c15
        var chars: [Character] = []
        chars.reserveCapacity(length)

        for offset in 0..<length {
            state = state &* 2862933555777941757 &+ 3037000493 &+ UInt64(offset)
            chars.append(dnaBases[Int((state >> 33) & 0x03)])
        }

        return String(chars)
    }

    private static func makePairedReadSequences(
        pairIndex: Int,
        readLength: Int,
        overlapLength: Int
    ) -> (r1: String, r2: String) {
        precondition(readLength >= 8, "Synthetic paired-end fixtures require readLength >= 8")
        precondition(
            overlapLength > 0 && overlapLength < readLength,
            "overlapLength must be between 1 and readLength - 1"
        )

        let insertLength = (readLength * 2) - overlapLength
        let insert = deterministicDNA(length: insertLength, seed: UInt64(pairIndex + 1) &* 7_919)
        let r1 = String(insert.prefix(readLength))
        let r2Forward = String(insert.suffix(readLength))
        let r2 = reverseComplement(r2Forward)
        return (r1, r2)
    }

    /// Writes interleaved paired-end FASTQ (R1, R2, R1, R2, ...) with
    /// deterministic overlapping mate pairs suitable for merge tests.
    static func writeInterleavedPEFASTQ(
        to url: URL,
        pairCount: Int = 50,
        readLength: Int = 100,
        idPrefix: String = "read",
        overlapLength: Int? = nil
    ) throws {
        let effectiveOverlap = overlapLength ?? defaultOverlapLength(for: readLength)
        var lines: [String] = []
        let quality = String(repeating: "I", count: readLength)
        for i in 0..<pairCount {
            let baseID = "\(idPrefix)\(i + 1)"
            let (r1Seq, r2Seq) = makePairedReadSequences(
                pairIndex: i,
                readLength: readLength,
                overlapLength: effectiveOverlap
            )
            lines.append(contentsOf: [
                "@\(baseID)/1", r1Seq, "+", quality,
                "@\(baseID)/2", r2Seq, "+", quality,
            ])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes separate R1 and R2 FASTQ files for paired-end input.
    static func writePairedFASTQ(
        r1URL: URL,
        r2URL: URL,
        pairCount: Int = 50,
        readLength: Int = 100,
        idPrefix: String = "read"
    ) throws {
        var r1Lines: [String] = []
        var r2Lines: [String] = []
        let overlapLength = defaultOverlapLength(for: readLength)
        let quality = String(repeating: "I", count: readLength)
        for i in 0..<pairCount {
            let baseID = "\(idPrefix)\(i + 1)"
            let (r1Seq, r2Seq) = makePairedReadSequences(
                pairIndex: i,
                readLength: readLength,
                overlapLength: overlapLength
            )
            r1Lines.append(contentsOf: [
                "@\(baseID)/1", r1Seq, "+", quality
            ])
            r2Lines.append(contentsOf: [
                "@\(baseID)/2", r2Seq, "+", quality
            ])
        }
        try r1Lines.joined(separator: "\n").appending("\n").write(to: r1URL, atomically: true, encoding: .utf8)
        try r2Lines.joined(separator: "\n").appending("\n").write(to: r2URL, atomically: true, encoding: .utf8)
    }

    /// Writes FASTQ reads with known barcode pairs for demux testing.
    /// Each read has: leftBarcode + insert(insertLength bp) + rc(rightBarcode)
    static func writeBarcodeTaggedFASTQ(
        to url: URL,
        samples: [(name: String, fwdBarcode: String, revBarcode: String, readCount: Int)],
        untaggedCount: Int = 5,
        insertLength: Int = 3000
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        var readIndex = 0

        for sample in samples {
            let rcRev = reverseComplement(sample.revBarcode)
            for i in 0..<sample.readCount {
                readIndex += 1
                let id = "\(sample.name)_read\(i + 1)"
                var insert = ""
                for j in 0..<insertLength { insert.append(bases[(readIndex + j) % 4]) }
                let seq = sample.fwdBarcode + insert + rcRev
                let qual = String(repeating: "I", count: seq.count)
                lines.append(contentsOf: ["@\(id)", seq, "+", qual])
            }
        }

        for i in 0..<untaggedCount {
            readIndex += 1
            let id = "untagged_read\(i + 1)"
            var seq = ""
            for j in 0..<(insertLength + 50) { seq.append(bases[(readIndex + j) % 4]) }
            let qual = String(repeating: "I", count: seq.count)
            lines.append(contentsOf: ["@\(id)", seq, "+", qual])
        }

        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns the reverse complement of a DNA sequence.
    static func reverseComplement(_ seq: String) -> String {
        let complement: [Character: Character] = ["A": "T", "T": "A", "C": "G", "G": "C"]
        return String(seq.reversed().map { complement[$0] ?? $0 })
    }

    /// Writes FASTQ with duplicate reads for deduplication testing.
    static func writeDuplicatedFASTQ(
        to url: URL,
        uniqueCount: Int = 50,
        duplicatesPerRead: Int = 2,
        readLength: Int = 100
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<uniqueCount {
            var seq = ""
            for j in 0..<readLength { seq.append(bases[(i + j) % 4]) }
            let qual = String(repeating: "I", count: readLength)
            for d in 0..<duplicatesPerRead {
                let id = "read\(i + 1)_dup\(d)"
                lines.append(contentsOf: ["@\(id)", seq, "+", qual])
            }
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
