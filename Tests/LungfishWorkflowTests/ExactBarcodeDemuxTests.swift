import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class ExactBarcodeDemuxTests: XCTestCase {

    // Test barcodes (from PacBio Sequel 16 V3 kit)
    private let bc1003 = "ACACATCTCGTGAGAGT"
    private let bc1016 = "CATAGAGAGATAGTATT"

    // MARK: - Helper

    /// Creates a temporary gzipped FASTQ file with the given records.
    private func writeTempFASTQ(records: [(id: String, seq: String)]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exact-demux-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fastqURL = tempDir.appendingPathComponent("test.fastq")
        var content = ""
        for record in records {
            let qual = String(repeating: "I", count: record.seq.count)
            content += "@\(record.id)\n\(record.seq)\n+\n\(qual)\n"
        }
        try content.write(to: fastqURL, atomically: true, encoding: .utf8)
        return fastqURL
    }

    private func rc(_ seq: String) -> String {
        PlatformAdapters.reverseComplement(seq)
    }

    /// Generates a random DNA insert of the given length.
    private func randomInsert(length: Int) -> String {
        let bases: [Character] = ["A", "C", "G", "T"]
        return String((0..<length).map { _ in bases[Int.random(in: 0..<4)] })
    }

    // MARK: - Tests

    func testPattern1_FwdThenRcRev() async throws {
        // Pattern 1: fwd_bc ... rc(rev_bc)
        let insert = randomInsert(length: 3000)
        let seq = bc1003 + insert + rc(bc1016)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 1)
        XCTAssertEqual(result.assignedReads, 1)
        XCTAssertEqual(result.sampleResults.count, 1)
        XCTAssertEqual(result.sampleResults[0].sampleName, "sample1")
        XCTAssertEqual(result.sampleResults[0].readIDs, ["read1"])
        XCTAssertEqual(result.unassignedReadCount, 0)
    }

    func testPattern2_RevThenRcFwd() async throws {
        // Pattern 2: rev_bc ... rc(fwd_bc)
        let insert = randomInsert(length: 3000)
        let seq = bc1016 + insert + rc(bc1003)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.assignedReads, 1)
        XCTAssertEqual(result.sampleResults[0].readIDs, ["read1"])
    }

    func testPattern3_FwdThenRev_SameOrientation() async throws {
        // Pattern 3: fwd_bc ... rev_bc (both forward — ONT through SMRTbell)
        let insert = randomInsert(length: 3000)
        let seq = bc1003 + insert + bc1016
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.assignedReads, 1)
        XCTAssertEqual(result.sampleResults[0].readIDs, ["read1"])
    }

    func testPattern4_RcRevThenRcFwd_BothRC() async throws {
        // Pattern 4: rc(rev_bc) ... rc(fwd_bc) (both RC)
        let insert = randomInsert(length: 3000)
        let seq = rc(bc1016) + insert + rc(bc1003)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.assignedReads, 1)
        XCTAssertEqual(result.sampleResults[0].readIDs, ["read1"])
    }

    func testMinimumInsertEnforced() async throws {
        // Insert too short (500bp < 2000bp minimum) — should NOT match
        let shortInsert = randomInsert(length: 500)
        let seq = bc1003 + shortInsert + rc(bc1016)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.assignedReads, 0)
        XCTAssertEqual(result.unassignedReadCount, 1)
    }

    func testShortReadSkipped() async throws {
        // Read shorter than 2*barcodeLength + minimumInsert — skipped entirely
        let shortSeq = randomInsert(length: 100)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: shortSeq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 1)
        XCTAssertEqual(result.assignedReads, 0)
        XCTAssertEqual(result.unassignedReadCount, 1)
    }

    func testMultipleSamples() async throws {
        let bc1008 = "ACAGTCGAGCGCTGCGT"
        let bc1009 = "ACACACGCGAGACAGAT"

        let insert = randomInsert(length: 3000)

        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: bc1003 + insert + rc(bc1016)),
            (id: "read2", seq: bc1008 + insert + rc(bc1009)),
            (id: "read3", seq: bc1003 + insert + rc(bc1016)),
            (id: "unmatched", seq: randomInsert(length: 5000)),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample_A", forwardSequence: bc1003, reverseSequence: bc1016),
                .init(sampleName: "sample_B", forwardSequence: bc1008, reverseSequence: bc1009),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 4)
        XCTAssertEqual(result.assignedReads, 3)
        XCTAssertEqual(result.sampleResults.count, 2)
        XCTAssertEqual(result.unassignedReadCount, 1)

        let sampleA = result.sampleResults.first { $0.sampleName == "sample_A" }
        let sampleB = result.sampleResults.first { $0.sampleName == "sample_B" }
        XCTAssertNotNil(sampleA)
        XCTAssertNotNil(sampleB)
        XCTAssertEqual(sampleA?.readCount, 2)
        XCTAssertEqual(sampleA?.readIDs, ["read1", "read3"])
        XCTAssertEqual(sampleB?.readCount, 1)
        XCTAssertEqual(sampleB?.readIDs, ["read2"])
    }

    func testZeroReadSampleOmitted() async throws {
        let insert = randomInsert(length: 3000)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: bc1003 + insert + rc(bc1016)),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "has_reads", forwardSequence: bc1003, reverseSequence: bc1016),
                .init(sampleName: "no_reads", forwardSequence: "AAAAAAAAAAAAAAAA", reverseSequence: "CCCCCCCCCCCCCCCC"),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.sampleResults.count, 1)
        XCTAssertEqual(result.sampleResults[0].sampleName, "has_reads")
    }

    func testPreviewLimitRespected() async throws {
        let insert = randomInsert(length: 3000)
        var records: [(id: String, seq: String)] = []
        for i in 0..<20 {
            records.append((id: "read\(i)", seq: bc1003 + insert + rc(bc1016)))
        }
        let fastq = try writeTempFASTQ(records: records)
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000,
            previewLimit: 5
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.sampleResults[0].readCount, 20)
        XCTAssertEqual(result.sampleResults[0].readIDs.count, 20)
        XCTAssertEqual(result.sampleResults[0].previewRecords.count, 5)
    }

    func testReadIDExtraction() async throws {
        let insert = randomInsert(length: 3000)
        let seq = bc1003 + insert + rc(bc1016)
        let fastq = try writeTempFASTQ(records: [
            (id: "m84100_231201_001_s1/123/ccs runid=abc", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        // Read ID should be extracted without description (first token only)
        XCTAssertEqual(result.sampleResults[0].readIDs, ["m84100_231201_001_s1/123/ccs"])
    }

    func testBaseCountAccumulated() async throws {
        let insert = randomInsert(length: 3000)
        let seq = bc1003 + insert + rc(bc1016)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.sampleResults[0].baseCount, Int64(seq.count))
    }

    func testFASTQRawRecordReadID() {
        let record = FASTQRawRecord(
            header: "@read123 length=100",
            sequence: "ACGT",
            separator: "+",
            quality: "IIII"
        )
        XCTAssertEqual(record.readID, "read123")
        XCTAssertEqual(record.baseCount, 4)
    }

    func testFASTQRawRecordFastqString() {
        let record = FASTQRawRecord(
            header: "@read1",
            sequence: "ACGT",
            separator: "+",
            quality: "IIII"
        )
        XCTAssertEqual(record.fastqString, "@read1\nACGT\n+\nIIII\n")
    }

    func testDemultiplexStepMinimumInsertDefault() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "test-kit")
        XCTAssertEqual(step.minimumInsert, 2000)
    }

    func testExactMatchOnly_SingleMismatchFails() async throws {
        // Mutate one base in the barcode — exact match should fail
        var mutated = Array(bc1003)
        mutated[0] = mutated[0] == "A" ? Character("C") : Character("A")
        let mutatedBC = String(mutated)

        let insert = randomInsert(length: 3000)
        let seq = mutatedBC + insert + rc(bc1016)
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.assignedReads, 0, "Single mismatch should not match with exact matching")
    }

    func testInternalBarcodeSearch() async throws {
        // Barcodes embedded in the middle of the read with flanking sequence
        let flank5 = randomInsert(length: 200)
        let insert = randomInsert(length: 3000)
        let flank3 = randomInsert(length: 200)
        let seq = flank5 + bc1003 + insert + rc(bc1016) + flank3
        let fastq = try writeTempFASTQ(records: [
            (id: "read1", seq: seq),
        ])
        defer { try? FileManager.default.removeItem(at: fastq.deletingLastPathComponent()) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastq,
            sampleBarcodes: [
                .init(sampleName: "sample1", forwardSequence: bc1003, reverseSequence: bc1016)
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.assignedReads, 1, "Internal barcodes should be found")
    }

    // MARK: - CSV Parsing Tests

    func testAsymmetricCSVParseBarcode1Barcode2() throws {
        let csv = "sample_id,barcode_1,barcode_2\nLN94,bc1001,bc1021\nMR10,bc1002,bc1022\n"
        let assignments = try FASTQSampleBarcodeCSV.parse(content: csv, delimiter: ",")
        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments[0].sampleID, "LN94")
        XCTAssertEqual(assignments[0].forwardBarcodeID, "bc1001")
        XCTAssertEqual(assignments[0].reverseBarcodeID, "bc1021")
        XCTAssertEqual(assignments[1].sampleID, "MR10")
        XCTAssertEqual(assignments[1].forwardBarcodeID, "bc1002")
        XCTAssertEqual(assignments[1].reverseBarcodeID, "bc1022")
    }

    func testCSVParseWithCRLFLineEndings() throws {
        let csv = "sample_id,barcode_1,barcode_2\r\nLN94,bc1001,bc1021\r\nMR10,bc1002,bc1022\r\n"
        let assignments = try FASTQSampleBarcodeCSV.parse(content: csv, delimiter: ",")
        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments[0].sampleID, "LN94")
        XCTAssertEqual(assignments[0].forwardBarcodeID, "bc1001")
    }

    func testCSVParseWithCROnlyLineEndings() throws {
        let csv = "sample_id,barcode_1,barcode_2\rLN94,bc1001,bc1021\rMR10,bc1002,bc1022\r"
        let assignments = try FASTQSampleBarcodeCSV.parse(content: csv, delimiter: ",")
        XCTAssertEqual(assignments.count, 2, "CR-only line endings should produce valid rows")
        XCTAssertEqual(assignments[0].sampleID, "LN94")
        XCTAssertEqual(assignments[1].sampleID, "MR10")
    }

    func testAsymmetricCSVExportRoundTrip() throws {
        let original = [
            FASTQSampleBarcodeAssignment(sampleID: "LN94", forwardBarcodeID: "bc1001", reverseBarcodeID: "bc1021"),
            FASTQSampleBarcodeAssignment(sampleID: "MR10", forwardBarcodeID: "bc1002", reverseBarcodeID: "bc1022"),
        ]
        let csv = FASTQSampleBarcodeCSV.exportAsymmetricCSV(original)
        let reimported = try FASTQSampleBarcodeCSV.parse(content: csv, delimiter: ",")
        XCTAssertEqual(reimported.count, 2)
        XCTAssertEqual(reimported[0].sampleID, "LN94")
        XCTAssertEqual(reimported[0].forwardBarcodeID, "bc1001")
        XCTAssertEqual(reimported[0].reverseBarcodeID, "bc1021")
        XCTAssertEqual(reimported[1].sampleID, "MR10")
        XCTAssertEqual(reimported[1].forwardBarcodeID, "bc1002")
        XCTAssertEqual(reimported[1].reverseBarcodeID, "bc1022")
    }

    func testCSVParseBarcode5pBarcode3pAliases() throws {
        let csv = "sample_id,barcode_5p,barcode_3p\nLN94,bc1001,bc1021\n"
        let assignments = try FASTQSampleBarcodeCSV.parse(content: csv, delimiter: ",")
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[0].forwardBarcodeID, "bc1001")
        XCTAssertEqual(assignments[0].reverseBarcodeID, "bc1021")
    }
}
