// DemultiplexPipelineIntegrationTests.swift - Asymmetric demux pipeline integration tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexPipelineIntegrationTests: XCTestCase {

    // Synthetic 24bp barcodes for testing
    private let barcodeA_fwd = "ACGTACGTACGTACGTACGTACGT"
    private let barcodeA_rev = "TGCATGCATGCATGCATGCATGCA"
    private let barcodeB_fwd = "GATCGATCGATCGATCGATCGATC"
    private let barcodeB_rev = "CTAGCTAGCTAGCTAGCTAGCTAG"

    // MARK: - Helpers

    private func rc(_ seq: String) -> String {
        PlatformAdapters.reverseComplement(seq)
    }

    private func randomInsert(length: Int) -> String {
        let bases: [Character] = ["A", "C", "G", "T"]
        return String((0..<length).map { _ in bases[Int.random(in: 0..<4)] })
    }

    /// Creates a temporary uncompressed FASTQ file with the given records.
    private func writeTempFASTQ(records: [(id: String, seq: String)]) throws -> (url: URL, dir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fastqURL = tempDir.appendingPathComponent("test.fastq")
        var content = ""
        for record in records {
            let qual = String(repeating: "I", count: record.seq.count)
            content += "@\(record.id)\n\(record.seq)\n+\n\(qual)\n"
        }
        try content.write(to: fastqURL, atomically: true, encoding: .utf8)
        return (fastqURL, tempDir)
    }

    /// Builds a minimal .lungfishfastq root bundle containing the given FASTQ records.
    private func writeRootBundle(records: [(id: String, seq: String)]) throws -> (bundleURL: URL, fastqFilename: String, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let bundleURL = tempDir.appendingPathComponent("root.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqFilename = "reads.fastq"
        let fastqURL = bundleURL.appendingPathComponent(fastqFilename)
        var content = ""
        for record in records {
            let qual = String(repeating: "I", count: record.seq.count)
            content += "@\(record.id)\n\(record.seq)\n+\n\(qual)\n"
        }
        try content.write(to: fastqURL, atomically: true, encoding: .utf8)
        return (bundleURL, fastqFilename, tempDir)
    }

    /// Makes a read sequence with barcode pattern 1: fwd + insert + rc(rev)
    private func makePattern1(fwd: String, rev: String, insertLength: Int) -> String {
        fwd + randomInsert(length: insertLength) + rc(rev)
    }

    /// Makes a read sequence with barcode pattern 2: rev + insert + rc(fwd)
    private func makePattern2(fwd: String, rev: String, insertLength: Int) -> String {
        rev + randomInsert(length: insertLength) + rc(fwd)
    }

    /// Makes a read sequence with barcode pattern 3: fwd + insert + rev (both forward)
    private func makePattern3(fwd: String, rev: String, insertLength: Int) -> String {
        fwd + randomInsert(length: insertLength) + rev
    }

    /// Makes a read sequence with barcode pattern 4: rc(rev) + insert + rc(fwd) (both RC)
    private func makePattern4(fwd: String, rev: String, insertLength: Int) -> String {
        rc(rev) + randomInsert(length: insertLength) + rc(fwd)
    }

    /// Creates a BarcodeKitDefinition for asymmetric testing.
    private func makeTestKit() -> BarcodeKitDefinition {
        BarcodeKitDefinition(
            id: "test-asymmetric-kit",
            displayName: "Test Asymmetric Kit",
            vendor: "pacbio",
            platform: .pacbio,
            kitType: .custom,
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [
                BarcodeEntry(id: "bcA_fwd", i7Sequence: barcodeA_fwd, i5Sequence: barcodeA_rev),
                BarcodeEntry(id: "bcB_fwd", i7Sequence: barcodeB_fwd, i5Sequence: barcodeB_rev),
            ]
        )
    }

    /// Creates sample assignments for the test kit.
    private func makeSampleAssignments() -> [FASTQSampleBarcodeAssignment] {
        [
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleA",
                sampleName: "Sample A",
                forwardBarcodeID: "bcA_fwd",
                forwardSequence: barcodeA_fwd,
                reverseBarcodeID: nil,
                reverseSequence: barcodeA_rev,
                metadata: [:]
            ),
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleB",
                sampleName: "Sample B",
                forwardBarcodeID: "bcB_fwd",
                forwardSequence: barcodeB_fwd,
                reverseBarcodeID: nil,
                reverseSequence: barcodeB_rev,
                metadata: [:]
            ),
        ]
    }

    // MARK: - Test 1: Correct sample assignment

    func testAsymmetricDemuxAssignsReadsToCorrectSamples() async throws {
        // 10 reads Sample A Pattern 1 + 10 reads Sample A Pattern 2
        // + 10 reads Sample B Pattern 1 + 5 untagged
        var records: [(id: String, seq: String)] = []

        for i in 0..<10 {
            records.append((id: "sA_p1_\(i)", seq: makePattern1(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }
        for i in 0..<10 {
            records.append((id: "sA_p2_\(i)", seq: makePattern2(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }
        for i in 0..<10 {
            records.append((id: "sB_p1_\(i)", seq: makePattern1(fwd: barcodeB_fwd, rev: barcodeB_rev, insertLength: 3000)))
        }
        for i in 0..<5 {
            records.append((id: "untagged_\(i)", seq: randomInsert(length: 3000)))
        }

        let (fastqURL, tempDir) = try writeTempFASTQ(records: records)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastqURL,
            sampleBarcodes: [
                .init(sampleName: "SampleA", forwardSequence: barcodeA_fwd, reverseSequence: barcodeA_rev),
                .init(sampleName: "SampleB", forwardSequence: barcodeB_fwd, reverseSequence: barcodeB_rev),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 35)
        XCTAssertEqual(result.assignedReads, 30)
        XCTAssertEqual(result.unassignedReadCount, 5)

        let sampleA = result.sampleResults.first { $0.sampleName == "SampleA" }
        let sampleB = result.sampleResults.first { $0.sampleName == "SampleB" }
        XCTAssertNotNil(sampleA)
        XCTAssertNotNil(sampleB)
        XCTAssertEqual(sampleA?.readCount, 20)
        XCTAssertEqual(sampleB?.readCount, 10)
    }

    // MARK: - Test 2: All four orientation patterns

    func testAsymmetricDemuxAllFourOrientations() async throws {
        // 5 reads in each of 4 patterns, all for one sample
        var records: [(id: String, seq: String)] = []

        for i in 0..<5 {
            records.append((id: "p1_\(i)", seq: makePattern1(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }
        for i in 0..<5 {
            records.append((id: "p2_\(i)", seq: makePattern2(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }
        for i in 0..<5 {
            records.append((id: "p3_\(i)", seq: makePattern3(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }
        for i in 0..<5 {
            records.append((id: "p4_\(i)", seq: makePattern4(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }

        let (fastqURL, tempDir) = try writeTempFASTQ(records: records)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastqURL,
            sampleBarcodes: [
                .init(sampleName: "SampleA", forwardSequence: barcodeA_fwd, reverseSequence: barcodeA_rev),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 20)
        XCTAssertEqual(result.assignedReads, 20)
        XCTAssertEqual(result.unassignedReadCount, 0)
        XCTAssertEqual(result.sampleResults.count, 1)
        XCTAssertEqual(result.sampleResults[0].readCount, 20)
    }

    // MARK: - Test 3: Minimum insert enforcement

    func testAsymmetricDemuxMinimumInsertEnforced() async throws {
        // 10 reads with short insert (500bp < 2000bp min) + 10 reads with long insert (3000bp)
        var records: [(id: String, seq: String)] = []

        for i in 0..<10 {
            records.append((id: "short_\(i)", seq: makePattern1(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 500)))
        }
        for i in 0..<10 {
            records.append((id: "long_\(i)", seq: makePattern1(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }

        let (fastqURL, tempDir) = try writeTempFASTQ(records: records)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastqURL,
            sampleBarcodes: [
                .init(sampleName: "SampleA", forwardSequence: barcodeA_fwd, reverseSequence: barcodeA_rev),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 20)
        XCTAssertEqual(result.assignedReads, 10, "Only reads with insert >= 2000bp should be assigned")
        XCTAssertEqual(result.unassignedReadCount, 10, "Short-insert reads should be unassigned")
    }

    // MARK: - Test 4: Pipeline-level bundles with preview and read IDs

    func testAsymmetricDemuxBundlesHavePreviewAndReadIDs() async throws {
        // 20 reads for one sample, run through DemultiplexingPipeline
        var records: [(id: String, seq: String)] = []
        for i in 0..<20 {
            records.append((id: "read_\(i)", seq: makePattern1(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }

        let (bundleURL, fastqFilename, tempDir) = try writeRootBundle(records: records)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDir = tempDir.appendingPathComponent("demux-output", isDirectory: true)

        let config = DemultiplexConfig(
            inputURL: bundleURL.appendingPathComponent(fastqFilename),
            sourceBundleURL: bundleURL,
            barcodeKit: makeTestKit(),
            outputDirectory: outputDir,
            symmetryMode: .asymmetric,
            sampleAssignments: [
                FASTQSampleBarcodeAssignment(
                    sampleID: "SampleA",
                    sampleName: "Sample A",
                    forwardBarcodeID: "bcA_fwd",
                    forwardSequence: barcodeA_fwd,
                    reverseBarcodeID: nil,
                    reverseSequence: barcodeA_rev,
                    metadata: [:]
                ),
            ],
            rootBundleURL: bundleURL,
            rootFASTQFilename: fastqFilename,
            minimumInsert: 2000
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(config: config, progress: { _, _ in })

        XCTAssertFalse(result.outputBundleURLs.isEmpty, "Should produce at least one output bundle")

        for bundleOutputURL in result.outputBundleURLs {
            // Verify bundle is a .lungfishfastq directory
            XCTAssertTrue(FASTQBundle.isBundleURL(bundleOutputURL))

            // Verify read-ids.txt exists and is non-empty
            let readIDsURL = bundleOutputURL.appendingPathComponent("read-ids.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: readIDsURL.path), "read-ids.txt should exist")
            let readIDContent = try String(contentsOf: readIDsURL, encoding: .utf8)
            XCTAssertFalse(readIDContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "read-ids.txt should be non-empty")

            // Verify preview.fastq exists and is non-empty
            let previewURL = bundleOutputURL.appendingPathComponent("preview.fastq")
            XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path), "preview.fastq should exist")
            let previewContent = try String(contentsOf: previewURL, encoding: .utf8)
            XCTAssertFalse(previewContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "preview.fastq should be non-empty")

            // Verify derived manifest exists with demuxedVirtual payload
            let manifest = FASTQBundle.loadDerivedManifest(in: bundleOutputURL)
            XCTAssertNotNil(manifest, "Derived manifest should exist")
            if let manifest {
                if case .demuxedVirtual(_, readIDListFilename: let readIDFile, previewFilename: let previewFile, _, _) = manifest.payload {
                    XCTAssertEqual(readIDFile, "read-ids.txt")
                    XCTAssertEqual(previewFile, "preview.fastq")
                } else {
                    XCTFail("Expected .demuxedVirtual payload, got \(manifest.payload)")
                }
            }
        }
    }

    // MARK: - Test 5: Materialization round-trip

    func testAsymmetricDemuxMaterialization() async throws {
        // 15 reads Sample A + 10 reads Sample B, run through DemultiplexingPipeline
        var records: [(id: String, seq: String)] = []
        for i in 0..<15 {
            records.append((id: "sA_\(i)", seq: makePattern1(fwd: barcodeA_fwd, rev: barcodeA_rev, insertLength: 3000)))
        }
        for i in 0..<10 {
            records.append((id: "sB_\(i)", seq: makePattern1(fwd: barcodeB_fwd, rev: barcodeB_rev, insertLength: 3000)))
        }

        let (bundleURL, fastqFilename, tempDir) = try writeRootBundle(records: records)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDir = tempDir.appendingPathComponent("demux-output", isDirectory: true)

        let config = DemultiplexConfig(
            inputURL: bundleURL.appendingPathComponent(fastqFilename),
            sourceBundleURL: bundleURL,
            barcodeKit: makeTestKit(),
            outputDirectory: outputDir,
            symmetryMode: .asymmetric,
            sampleAssignments: makeSampleAssignments(),
            rootBundleURL: bundleURL,
            rootFASTQFilename: fastqFilename,
            minimumInsert: 2000
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(config: config, progress: { _, _ in })

        XCTAssertGreaterThanOrEqual(result.outputBundleURLs.count, 2, "Should have bundles for both samples")

        // Materialize each bundle and verify output has reads
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)

        for bundleOutputURL in result.outputBundleURLs {
            // Use a unique temp directory per bundle to avoid output filename collisions
            let materializeDir = tempDir
                .appendingPathComponent("mat-\(bundleOutputURL.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: materializeDir, withIntermediateDirectories: true)

            let materializedURL = try await materializer.materialize(
                bundleURL: bundleOutputURL,
                tempDirectory: materializeDir,
                progress: { _ in }
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path),
                          "Materialized FASTQ should exist at \(materializedURL.path)")

            let content = try String(contentsOf: materializedURL, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            // Each FASTQ record is 4 lines
            let recordCount = lines.count / 4
            XCTAssertGreaterThan(recordCount, 0, "Materialized FASTQ should contain reads")
        }
    }
}
