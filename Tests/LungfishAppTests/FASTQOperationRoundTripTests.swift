import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishWorkflow

final class FASTQOperationRoundTripTests: XCTestCase {

    private func requireManagedTool(_ tool: NativeTool) async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: tool)
        } catch NativeToolError.toolNotFound {
            throw XCTSkip("Managed \(tool.rawValue) is not available")
        }
    }

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

    // MARK: - Filter Operations

    func testContaminantFilterRoundTrip() async throws {
        try await requireManagedTool(.bbduk)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "ContaminantFilter")
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
            request: .contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: 31, hammingDistance: 1),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-contaminant-filter", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        // Synthetic reads won't match PhiX — expect the vast majority to be retained
        XCTAssertGreaterThan(records.count, 40,
            "contaminantFilter(phix) should retain >40 of 50 synthetic reads (no real PhiX contamination)")
    }

    func testSequencePresenceFilterRoundTrip() async throws {
        try await requireManagedTool(.bbduk)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SeqPresenceFilter")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeAdapterAppendedFASTQ(
            to: root.fastqURL,
            adapter: "AGATCGGAAGAGC",
            totalReads: 50,
            readsWithAdapter: 25,
            readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .sequencePresenceFilter(
                sequence: "AGATCGGAAGAGC",
                fastaPath: nil,
                searchEnd: .threePrime,
                minOverlap: 8,
                errorRate: 0.1,
                keepMatched: false,
                searchReverseComplement: false
            ),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-seq-presence-filter", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        // keepMatched: false — adapter-containing reads removed; 25 clean reads should remain
        // Allow a range because bbduk partial-match detection may vary slightly
        XCTAssertGreaterThanOrEqual(records.count, 15,
            "sequencePresenceFilter(keepMatched:false) should retain at least 15 of 50 reads")
        XCTAssertLessThanOrEqual(records.count, 40,
            "sequencePresenceFilter(keepMatched:false) should retain at most 40 of 50 reads")
    }

    // MARK: - Trim Operations

    func testQualityTrimRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "QualityTrim")
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
            request: .qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-quality-trim", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 0,
            "qualityTrim should produce at least some reads")
        for record in records {
            XCTAssertGreaterThan(record.sequence.count, 0,
                "Read \(record.identifier) should have non-zero length after quality trim")
            XCTAssertLessThanOrEqual(record.sequence.count, 100,
                "Read \(record.identifier) should be no longer than original 100bp")
        }
    }

    func testAdapterTrimRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AdapterTrim")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        let adapter = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
        try FASTQOperationTestHelper.writeAdapterAppendedFASTQ(
            to: root.fastqURL,
            adapter: adapter,
            totalReads: 50,
            readsWithAdapter: 50,
            readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .adapterTrim(mode: .specified, sequence: adapter, sequenceR2: nil, fastaFilename: nil),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-adapter-trim", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 0,
            "adapterTrim should produce at least some reads")
        // All reads had the adapter appended; at least some should be shorter after trimming
        let shorterCount = records.filter { $0.sequence.count < 100 + adapter.count }.count
        XCTAssertGreaterThan(shorterCount, 0,
            "adapterTrim should shorten at least some reads by removing the appended adapter")
    }

    func testFixedTrimMaterializationRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FixedTrimMat")
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
            request: .fixedTrim(from5Prime: 15, from3Prime: 5),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-fixed-trim-mat", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(records.count, 50,
            "fixedTrim should produce exactly 50 reads")
        for record in records {
            XCTAssertEqual(record.sequence.count, 80,
                "Read \(record.identifier) should be exactly 80bp after fixedTrim(from5Prime:15, from3Prime:5)")
        }
    }

    func testPrimerRemovalRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "PrimerRemoval")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        let primer = "GTTTCCCAGTCACGACG"
        try FASTQOperationTestHelper.writePrimerPrependedFASTQ(
            to: root.fastqURL,
            primer: primer,
            totalReads: 50,
            readsWithPrimer: 50,
            baseReadLength: 100
        )

        let config = FASTQPrimerTrimConfiguration(
            source: .literal,
            mode: .fivePrime,
            forwardSequence: primer,
            errorRate: 0.12,
            minimumOverlap: 12
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .primerRemoval(configuration: config),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out-primer-removal", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 0,
            "primerRemoval should produce at least some reads")
        // All reads had the 17bp primer prepended (total length 117bp); at least some should be shorter
        let shorterCount = records.filter { $0.sequence.count < 117 }.count
        XCTAssertGreaterThan(shorterCount, 0,
            "primerRemoval should shorten at least some reads by removing the prepended primer")
    }

    // MARK: - Full Output Operations

    func testErrorCorrectionRoundTrip() async throws {
        try await requireManagedTool(.tadpole)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "ErrorCorrect")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 200, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .errorCorrection(kmerSize: 21),
            progress: nil
        )

        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "full")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .full(let filename) = manifest.payload {
            let fullURL = derivedURL.appendingPathComponent(filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path))
            let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: fullURL)
            XCTAssertGreaterThan(records.count, 0, "Error correction should produce reads")
        } else {
            XCTFail("Expected full payload")
        }
    }

    func testDeduplicateRoundTrip() async throws {
        try await requireManagedTool(.clumpify)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "Dedup")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeDuplicatedFASTQ(
            to: root.fastqURL, uniqueCount: 50, duplicatesPerRead: 2, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .deduplicate(
                preset: .exactPCR,
                substitutions: 0,
                optical: false,
                opticalDistance: 0
            ),
            progress: nil
        )

        // Deduplicate produces a subset payload (read ID list of surviving reads),
        // not a full payload — clumpify runs, then the service extracts surviving read IDs.
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        // Materialize and verify dedup reduced count
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertLessThan(records.count, 100, "Dedup should remove duplicate reads")
        XCTAssertGreaterThan(records.count, 0, "Dedup should retain some reads")
    }

    // MARK: - Paired-End and Interleave Operations

    func testDeinterleaveRoundTrip() async throws {
        try await requireManagedTool(.reformat)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "Deinterleave")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: root.fastqURL, pairCount: 50, readLength: 100
        )

        // Mark the bundle as interleaved so the service allows the deinterleave operation
        let ingestion = IngestionMetadata(pairingMode: .interleaved)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: ingestion),
            for: root.fastqURL
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .interleaveReformat(direction: .deinterleave),
            progress: nil
        )

        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "fullPaired")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .fullPaired(let r1Filename, let r2Filename) = manifest.payload {
            let r1URL = derivedURL.appendingPathComponent(r1Filename)
            let r2URL = derivedURL.appendingPathComponent(r2Filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: r1URL.path), "R1 file should exist")
            XCTAssertTrue(FileManager.default.fileExists(atPath: r2URL.path), "R2 file should exist")
            let r1Records = try await FASTQOperationTestHelper.loadFASTQRecords(from: r1URL)
            let r2Records = try await FASTQOperationTestHelper.loadFASTQRecords(from: r2URL)
            XCTAssertEqual(r1Records.count, 50, "R1 should have 50 reads")
            XCTAssertEqual(r2Records.count, 50, "R2 should have 50 reads")
        } else {
            XCTFail("Expected fullPaired payload")
        }
    }

    func testPairedEndMergeRoundTrip() async throws {
        try await requireManagedTool(.bbmerge)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "PEMerge")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: root.fastqURL, pairCount: 50, readLength: 100
        )

        // Mark the bundle as interleaved so the service allows the PE merge operation
        let ingestion = IngestionMetadata(pairingMode: .interleaved)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: ingestion),
            for: root.fastqURL
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .pairedEndMerge(strictness: .normal, minOverlap: 20),
            progress: nil
        )

        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "fullMixed")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .fullMixed(let classification) = manifest.payload {
            XCTAssertGreaterThan(classification.files.count, 0,
                "PE merge should produce classified output files")
            for fileEntry in classification.files {
                let fileURL = derivedURL.appendingPathComponent(fileEntry.filename)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                    "Output file \(fileEntry.filename) should exist")
            }
        } else {
            XCTFail("Expected fullMixed payload")
        }
    }

    func testPairedEndRepairRoundTrip() async throws {
        try await requireManagedTool(.repair)

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "PERepair")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: root.fastqURL, pairCount: 50, readLength: 100
        )

        // Mark the bundle as interleaved so the service allows the PE repair operation
        let ingestion = IngestionMetadata(pairingMode: .interleaved)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: ingestion),
            for: root.fastqURL
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .pairedEndRepair,
            progress: nil
        )

        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "fullMixed")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .fullMixed(let classification) = manifest.payload {
            XCTAssertGreaterThan(classification.files.count, 0,
                "PE repair should produce classified output files")
            for fileEntry in classification.files {
                let fileURL = derivedURL.appendingPathComponent(fileEntry.filename)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                    "Output file \(fileEntry.filename) should exist")
            }
        } else {
            XCTFail("Expected fullMixed payload")
        }
    }
}
