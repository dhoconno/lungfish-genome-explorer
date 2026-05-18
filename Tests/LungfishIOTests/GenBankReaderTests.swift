// GenBankReaderTests.swift - Tests for GenBank file parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GenBankReaderTests: XCTestCase {

    private func writeTemporaryGenBank(_ content: String) throws -> URL {
        let testFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("genbank-reader-\(UUID().uuidString).gb")
        try content.write(to: testFile, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: testFile)
        }
        return testFile
    }

    func testStreamingImplementationDoesNotReadAheadOrMaterializeWholeFile() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishIO/Formats/GenBank/GenBankReader.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let parseFileSyncBody = try XCTUnwrap(source.slice(from: "private func parseFileSync", to: "private func parseRecord"))
        let recordsBody = try XCTUnwrap(source.slice(from: "public func records()", to: "private func makeRecordScanner"))

        XCTAssertFalse(parseFileSyncBody.contains("readToEnd()"), "parseFileSync must stream records instead of reading the whole file")
        XCTAssertFalse(parseFileSyncBody.contains("components(separatedBy: .newlines)"), "parseFileSync must not split the whole file into all lines")
        XCTAssertTrue(recordsBody.contains("AsyncThrowingStream(unfolding:"))
        XCTAssertFalse(recordsBody.contains("Task {"), "records() must not launch an eager producer task that can run ahead of the consumer")
    }

    func testRecordsStreamsGeneratedMultiRecordFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("generated-multi-record-\(UUID().uuidString).gb")
        let recordCount = 128
        let content = (1...recordCount).map { index in
            """
            LOCUS       STREAM\(String(format: "%04d", index))              12 bp    DNA     linear   UNK 01-JAN-2024
            DEFINITION  Generated streaming record \(index).
            ACCESSION   STREAM\(String(format: "%04d", index))
            VERSION     STREAM\(String(format: "%04d", index)).1
            FEATURES             Location/Qualifiers
                 source          1..12
                                 /organism="synthetic construct"
            ORIGIN
                    1 atgcatgcatgc
            //
            """
        }.joined(separator: "\n")

        try content.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let reader = try GenBankReader(url: testFile)
        var streamedNames: [String] = []
        for try await record in reader.records() {
            streamedNames.append(record.locus.name)
        }

        XCTAssertEqual(streamedNames.count, recordCount)
        XCTAssertEqual(streamedNames.first, "STREAM0001")
        XCTAssertEqual(streamedNames.last, "STREAM0128")
    }

    func testReadAllSyncHandlesCRLFAndCROnlyRecordBoundaries() throws {
        let records = [
            minimalRecord(name: "CRLF001", accession: "CRLF001"),
            minimalRecord(name: "CRONLY1", accession: "CRONLY1")
        ]

        for separator in ["\r\n", "\r"] {
            let testFile = try writeTemporaryGenBank(records.joined(separator: separator))
            let reader = try GenBankReader(url: testFile)
            let parsed = try reader.readAllSync()

            XCTAssertEqual(parsed.map(\.locus.name), ["CRLF001", "CRONLY1"])
            XCTAssertEqual(parsed.map(\.sequence.length), [12, 12])
        }
    }

    func testReadAllSyncHandlesChunkBoundaryWithinLongFeatureLine() throws {
        let longNote = String(repeating: "streaming-boundary-", count: 4_200)
        let content = """
        LOCUS       LONG001                 12 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Long feature line crosses the reader chunk boundary.
        ACCESSION   LONG001
        VERSION     LONG001.1
        FEATURES             Location/Qualifiers
             source          1..12
                             /organism="synthetic construct"
             gene            1..12
                             /note="\(longNote)"
        ORIGIN
                1 atgcatgcatgc
        //
        \(minimalRecord(name: "NEXT001", accession: "NEXT001"))
        """
        let testFile = try writeTemporaryGenBank(content)

        let reader = try GenBankReader(url: testFile)
        let parsed = try reader.readAllSync()

        XCTAssertEqual(parsed.map(\.locus.name), ["LONG001", "NEXT001"])
        let gene = try XCTUnwrap(parsed[0].annotations.first { $0.type == .gene })
        XCTAssertEqual(gene.note, longNote)
    }

    /// Tests reading a real GenBank file downloaded from NCBI
    func testReadKF015279() async throws {
        // This test file should exist in test-data/
        let testFileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-data/KF015279.gb")

        guard FileManager.default.fileExists(atPath: testFileURL.path) else {
            throw XCTSkip("Test file not present at \(testFileURL.path); drop KF015279.gb into test-data/ to enable.")
        }

        let reader = try GenBankReader(url: testFileURL)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1, "Should have exactly one record")

        let record = records[0]

        // Check locus info
        XCTAssertEqual(record.locus.name, "KF015279", "Locus name should be KF015279")
        XCTAssertEqual(record.locus.length, 5425, "Sequence length should be 5425 bp")
        XCTAssertEqual(record.locus.moleculeType, .dna, "Should be DNA")
        XCTAssertEqual(record.locus.topology, .linear, "Should be linear")

        // Check definition
        XCTAssertTrue(record.definition?.contains("Acheta domestica densovirus") ?? false,
                      "Definition should mention Acheta domestica densovirus")

        // Check accession
        XCTAssertEqual(record.accession, "KF015279")

        // Check sequence
        XCTAssertEqual(record.sequence.length, 5425, "Sequence should have 5425 bases")
        XCTAssertGreaterThan(record.sequence.length, 0, "Sequence should not be empty")

        // Check annotations - should have at least some features
        XCTAssertGreaterThan(record.annotations.count, 0, "Should have annotations/features")

        // Look for known features
        let hasSource = record.annotations.contains { $0.type == .source }
        let hasGene = record.annotations.contains { $0.type == .gene }
        let hasCDS = record.annotations.contains { $0.type == .cds }

        XCTAssertTrue(hasSource, "Should have a source feature")
        XCTAssertTrue(hasGene, "Should have gene features")
        XCTAssertTrue(hasCDS, "Should have CDS features")

        print("✅ Successfully parsed KF015279.gb:")
        print("   - Locus: \(record.locus.name) (\(record.locus.length) bp)")
        print("   - Sequence length: \(record.sequence.length)")
        print("   - Annotations: \(record.annotations.count)")
    }

    /// Tests that the reader throws on invalid files
    func testInvalidFileThrows() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let badFile = tempDir.appendingPathComponent("invalid.gb")

        try "This is not a valid GenBank file".write(to: badFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: badFile) }

        let reader = try GenBankReader(url: badFile)

        // Should either throw or return empty records
        do {
            let records = try await reader.readAll()
            XCTAssertTrue(records.isEmpty, "Should return no valid records for invalid file")
        } catch {
            // Also acceptable - throwing on invalid format
        }
    }

    /// Tests parsing of minimal valid GenBank content
    func testMinimalGenBank() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("minimal.gb")

        let content = """
        LOCUS       TEST001                 100 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Test sequence.
        ACCESSION   TEST001
        VERSION     TEST001.1
        ORIGIN
                1 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
               61 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
        //
        """

        try content.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let reader = try GenBankReader(url: testFile)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1)
        let record = records[0]

        XCTAssertEqual(record.locus.name, "TEST001")
        XCTAssertEqual(record.locus.length, 100)
        XCTAssertEqual(record.accession, "TEST001")
        XCTAssertEqual(record.sequence.length, 100)
    }

    private func minimalRecord(name: String, accession: String) -> String {
        """
        LOCUS       \(name)                 12 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Minimal generated sequence.
        ACCESSION   \(accession)
        VERSION     \(accession).1
        FEATURES             Location/Qualifiers
             source          1..12
                             /organism="synthetic construct"
        ORIGIN
                1 atgcatgcatgc
        //
        """
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let startRange = range(of: startMarker),
              let endRange = range(of: endMarker, range: startRange.upperBound..<endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
