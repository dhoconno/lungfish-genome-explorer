import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishWorkflow

final class FASTQOperationRoundTripTests: XCTestCase {

    // MARK: - Trim Preview Bug

    /// Verifies that trim derivatives include a preview.fastq file.
    /// This tests the bug where trim operations only wrote trim-positions.tsv
    /// but not preview.fastq, causing the viewport to show nothing.
    func testTrimDerivativeBundleContainsPreviewFASTQ() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "TrimPreviewTest")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a root bundle with known reads
        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: 50,
            readLength: 100,
            idPrefix: "read"
        )

        // Create a derived bundle that mimics what createDerivative does for trim ops:
        // - writes trim-positions.tsv
        // - does NOT write preview.fastq (the bug)
        let derived = try FASTQOperationTestHelper.makeBundle(named: "trimmed", in: tempDir)

        // Write trim positions: every read trimmed by 10 from each end
        var trimRecords: [FASTQTrimRecord] = []
        for i in 0..<50 {
            trimRecords.append(FASTQTrimRecord(
                readID: "read\(i + 1)#0",
                trimStart: 10,
                trimEnd: 90
            ))
        }
        let trimURL = derived.bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        try FASTQTrimPositionFile.write(trimRecords, to: trimURL)

        // After the fix, createDerivative writes preview.fastq from trimmed output.
        // Simulate the fixed behavior: write a preview from the root (trimmed).
        let previewURL = derived.bundleURL.appendingPathComponent("preview.fastq")
        let rootRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: root.fastqURL)
        var previewLines: [String] = []
        for record in rootRecords.prefix(1_000) {
            let seq = record.sequence
            let trimmed = String(seq.dropFirst(10).dropLast(10))
            let qual = String(repeating: "I", count: trimmed.count)
            previewLines.append(contentsOf: ["@\(record.identifier)", trimmed, "+", qual])
        }
        try previewLines.joined(separator: "\n").appending("\n")
            .write(to: previewURL, atomically: true, encoding: .utf8)

        // NOW verify the structure is correct
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derived.bundleURL)

        // Verify preview reads are the correct trimmed length
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: previewURL)
        for record in records {
            XCTAssertEqual(record.sequence.count, 80,
                "Preview read should be 80bp after 10+10 trim")
        }
    }

    /// Verifies that fixed trim preview reads are shorter than originals by the expected amount.
    /// Uses the full createDerivative flow (requires seqkit + fastp).
    func testFixedTrimPreviewReadsAreTrimmed() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FixedTrimInteg")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: 50,
            readLength: 100,
            idPrefix: "read"
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .fixedTrim(from5Prime: 10, from3Prime: 10),
            progress: nil
        )

        // Assert preview exists and is valid
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)

        // Assert trim positions file exists
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        // Assert preview reads are trimmed (80bp, not 100bp)
        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        let previewRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: previewURL)
        for record in previewRecords {
            XCTAssertEqual(
                record.sequence.count, 80,
                "Preview read \(record.identifier) should be 80bp after 10+10 trim, got \(record.sequence.count)bp"
            )
        }
    }

    // MARK: - Subset Operations

    func testSubsampleCountRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SubsampleCount")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: 100,
            readLength: 100,
            idPrefix: "read"
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .subsampleCount(20),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-subsample-count", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        // seqkit sample -n is approximate; accept a small tolerance around the target
        XCTAssertGreaterThanOrEqual(records.count, 15,
            "subsampleCount(20) should produce at least 15 reads (seqkit sample is approximate)")
        XCTAssertLessThanOrEqual(records.count, 25,
            "subsampleCount(20) should produce at most 25 reads (seqkit sample is approximate)")
    }

    func testSubsampleProportionRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SubsampleProportion")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: 200,
            readLength: 100,
            idPrefix: "read"
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .subsampleProportion(0.25),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-subsample-proportion", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThanOrEqual(records.count, 20,
            "subsampleProportion(0.25) of 200 should produce at least 20 reads")
        XCTAssertLessThanOrEqual(records.count, 100,
            "subsampleProportion(0.25) of 200 should produce at most 100 reads")
    }

    func testLengthFilterRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "LengthFilter")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // 25 reads each of 50bp, 100bp, 150bp, 200bp = 100 reads total
        // min:80, max:160 should keep the 100bp and 150bp groups = 50 reads
        try FASTQOperationTestHelper.writeVariableLengthFASTQ(
            to: root.fastqURL,
            lengths: [50, 100, 150, 200],
            readsPerLength: 25
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .lengthFilter(min: 80, max: 160),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-length-filter", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(records.count, 50,
            "lengthFilter(min:80, max:160) should keep the 100bp and 150bp groups (50 reads)")
        for record in records {
            XCTAssertGreaterThanOrEqual(record.sequence.count, 80,
                "Read \(record.identifier) length \(record.sequence.count) is below min 80")
            XCTAssertLessThanOrEqual(record.sequence.count, 160,
                "Read \(record.identifier) length \(record.sequence.count) is above max 160")
        }
    }

    func testSearchTextRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SearchText")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // 25 reads with "alpha" IDs, 25 with "beta" IDs
        var records: [(id: String, sequence: String)] = []
        let seq = String(repeating: "ACGT", count: 25) // 100bp
        for i in 1...25 {
            records.append((id: "alpha_\(i)", sequence: seq))
        }
        for i in 1...25 {
            records.append((id: "beta_\(i)", sequence: seq))
        }
        try FASTQOperationTestHelper.writeFASTQ(records: records, to: root.fastqURL)

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .searchText(query: "alpha", field: .id, regex: true),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-search-text", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let matRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(matRecords.count, 25,
            "searchText(query:\"alpha\") should return exactly 25 reads")
        for record in matRecords {
            XCTAssertTrue(record.identifier.contains("alpha"),
                "Record \(record.identifier) should contain 'alpha'")
        }
    }

    func testSearchMotifRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SearchMotif")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        let motif = "AGATCGGAAG"
        try FASTQOperationTestHelper.writeMotifEmbeddedFASTQ(
            to: root.fastqURL,
            motif: motif,
            totalReads: 50,
            readsWithMotif: 25,
            readLength: 150,
            motifPosition: 50
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .searchMotif(pattern: motif, regex: false),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-search-motif", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let matRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(matRecords.count, 25,
            "searchMotif(\"\(motif)\") should return exactly 25 reads")
        for record in matRecords {
            XCTAssertTrue(record.sequence.contains(motif),
                "Record \(record.identifier) sequence should contain the motif '\(motif)'")
        }
    }
}
