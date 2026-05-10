# Full Materialization + Special Operations Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write integration tests for all 9 remaining FASTQ operations (full-output, paired, orient, demux), with special emphasis on asymmetric barcode demux regression testing.

**Architecture:** Category A/B tests extend `FASTQOperationRoundTripTests.swift` (needs `LungfishApp`). Demux pipeline tests go in a new `DemultiplexPipelineIntegrationTests.swift` (needs `LungfishWorkflow`). Orient tests go in a new `OrientOperationTests.swift`. All follow the established regression-suite naming convention.

**Tech Stack:** Swift 6.2, XCTest, FASTQDerivativeService, FASTQCLIMaterializer, ExactBarcodeDemux, DemultiplexingPipeline, bbtools, vsearch, cutadapt

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift` | Category A + B round-trip tests |
| Modify | `Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift` | Add interleaved FASTQ + barcode helpers |
| Create | `Tests/LungfishWorkflowTests/DemultiplexPipelineIntegrationTests.swift` | Demux pipeline integration tests |
| Modify | `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | Bug fixes if any tests fail |

---

### Task 1: Add Interleaved and Barcode FASTQ Helpers

**Files:**
- Modify: `Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift`

- [ ] **Step 1: Add interleaved PE FASTQ generator and barcode helpers**

Add these methods to `FASTQOperationTestHelper`:

```swift
    /// Writes interleaved paired-end FASTQ (R1, R2, R1, R2, ...).
    static func writeInterleavedPEFASTQ(
        to url: URL,
        pairCount: Int = 50,
        readLength: Int = 100,
        idPrefix: String = "read"
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<pairCount {
            let baseID = "\(idPrefix)\(i + 1)"
            // R1
            var r1Seq = ""
            for j in 0..<readLength { r1Seq.append(bases[(i + j) % 4]) }
            lines.append(contentsOf: [
                "@\(baseID)/1", r1Seq, "+", String(repeating: "I", count: readLength)
            ])
            // R2
            var r2Seq = ""
            for j in 0..<readLength { r2Seq.append(bases[(i + j + 2) % 4]) }
            lines.append(contentsOf: [
                "@\(baseID)/2", r2Seq, "+", String(repeating: "I", count: readLength)
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
        let bases: [Character] = ["A", "C", "G", "T"]
        var r1Lines: [String] = []
        var r2Lines: [String] = []
        for i in 0..<pairCount {
            let baseID = "\(idPrefix)\(i + 1)"
            var r1Seq = ""
            for j in 0..<readLength { r1Seq.append(bases[(i + j) % 4]) }
            r1Lines.append(contentsOf: [
                "@\(baseID)/1", r1Seq, "+", String(repeating: "I", count: readLength)
            ])
            var r2Seq = ""
            for j in 0..<readLength { r2Seq.append(bases[(i + j + 2) % 4]) }
            r2Lines.append(contentsOf: [
                "@\(baseID)/2", r2Seq, "+", String(repeating: "I", count: readLength)
            ])
        }
        try r1Lines.joined(separator: "\n").appending("\n").write(to: r1URL, atomically: true, encoding: .utf8)
        try r2Lines.joined(separator: "\n").appending("\n").write(to: r2URL, atomically: true, encoding: .utf8)
    }

    /// Writes FASTQ reads with known barcode pairs for demux testing.
    /// Each read has: leftBarcode + insert(3000bp) + rightBarcode
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
                // Pattern 1: fwd ... rc(rev) — standard orientation
                var insert = ""
                for j in 0..<insertLength { insert.append(bases[(readIndex + j) % 4]) }
                let seq = sample.fwdBarcode + insert + rcRev
                let qual = String(repeating: "I", count: seq.count)
                lines.append(contentsOf: ["@\(id)", seq, "+", qual])
            }
        }

        // Untagged reads (no barcodes)
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
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift
git commit -m "test: add interleaved PE, barcode-tagged, and duplicated FASTQ generators"
```

---

### Task 2: Full Single-Output Operation Tests (Category A)

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add full operation tests**

Add a `// MARK: - Full Output Operations` section after the trim operations section:

```swift
    // MARK: - Full Output Operations

    func testErrorCorrectionRoundTrip() async throws {
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

        // Full operations store FASTQ directly — check payload and file
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
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "Dedup")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // 50 unique reads x 2 copies each = 100 total reads
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

        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "full")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .full(let filename) = manifest.payload {
            let fullURL = derivedURL.appendingPathComponent(filename)
            let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: fullURL)
            // Dedup should reduce 100 reads to ~50 (exact PCR dedup)
            XCTAssertLessThan(records.count, 100, "Dedup should remove duplicate reads")
            XCTAssertGreaterThan(records.count, 30, "Should retain most unique reads")
        } else {
            XCTFail("Expected full payload")
        }
    }
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter "FASTQOperationRoundTripTests/testErrorCorrectionRoundTrip" 2>&1 | tail -10`
Run: `swift test --filter "FASTQOperationRoundTripTests/testDeduplicateRoundTrip" 2>&1 | tail -10`
Expected: Both PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add error correction and deduplicate round-trip tests"
```

---

### Task 3: Paired-End and Interleave Operation Tests (Category B)

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

These tests need interleaved paired-end input for merge, repair, and deinterleave. Interleave needs separate R1/R2.

- [ ] **Step 1: Add paired/interleave tests**

Add after the full output operations section:

```swift
    // MARK: - Paired-End and Interleave Operations

    func testDeinterleaveRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "Deinterleave")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // Write interleaved PE FASTQ (50 pairs = 100 reads)
        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: root.fastqURL, pairCount: 50, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .interleaveReformat(direction: .deinterleave),
            progress: nil
        )

        // Deinterleave produces fullPaired payload with R1 and R2
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
            XCTAssertEqual(r1Records.count, r2Records.count, "R1 and R2 should have equal counts")
        } else {
            XCTFail("Expected fullPaired payload")
        }
    }

    func testPairedEndMergeRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "PEMerge")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: root.fastqURL, pairCount: 50, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .pairedEndMerge(strictness: .normal, minOverlap: 20),
            progress: nil
        )

        // PE merge produces fullMixed payload
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "fullMixed")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .fullMixed(let classification) = manifest.payload {
            // Should have at least some output files
            XCTAssertGreaterThan(classification.files.count, 0,
                "PE merge should produce classified output files")
            // Verify files exist on disk
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
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "PERepair")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: root.fastqURL, pairCount: 50, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .pairedEndRepair,
            progress: nil
        )

        // PE repair produces fullMixed payload
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
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter "FASTQOperationRoundTripTests/testDeinterleaveRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add deinterleave, PE merge, and PE repair round-trip tests"
```

---

### Task 4: Asymmetric Demux Pipeline Integration Tests

**Files:**
- Create: `Tests/LungfishWorkflowTests/DemultiplexPipelineIntegrationTests.swift`

This is the critical task for asymmetric barcode regression testing. Tests use `ExactBarcodeDemux` directly (the Swift-native engine) and `DemultiplexingPipeline` for the full flow.

- [ ] **Step 1: Create the demux integration test file**

```swift
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexPipelineIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemuxInteg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    private func rc(_ seq: String) -> String {
        let complement: [Character: Character] = ["A": "T", "T": "A", "C": "G", "G": "C"]
        return String(seq.reversed().map { complement[$0] ?? $0 })
    }

    private func randomInsert(length: Int) -> String {
        let bases: [Character] = ["A", "C", "G", "T"]
        return String((0..<length).map { bases[Int.random(in: 0...3)] })
    }

    private func writeFASTQ(records: [(id: String, seq: String)], to url: URL) throws {
        let lines: [String] = records.flatMap { record in
            ["@\(record.id)", record.seq, "+", String(repeating: "I", count: record.seq.count)]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // Test barcodes (24bp each, like PacBio)
    private let bcA_fwd = "AACCGGTTAACCGGTTAACCGGTT"
    private let bcA_rev = "TTGGCCAATTGGCCAATTGGCCAA"
    private let bcB_fwd = "CCTTAAGGCCTTAAGGCCTTAAGG"
    private let bcB_rev = "GGAATTCCGGAATTCCGGAATTCC"

    // MARK: - Asymmetric Exact-Match Tests

    func testAsymmetricDemuxAssignsReadsToCorrectSamples() async throws {
        let insertLen = 3000
        var records: [(id: String, seq: String)] = []

        // 10 reads for Sample A — Pattern 1: fwd...rc(rev)
        for i in 0..<10 {
            let insert = randomInsert(length: insertLen)
            let seq = bcA_fwd + insert + rc(bcA_rev)
            records.append((id: "sampleA_p1_\(i)", seq: seq))
        }

        // 10 reads for Sample A — Pattern 2: rev...rc(fwd)
        for i in 0..<10 {
            let insert = randomInsert(length: insertLen)
            let seq = bcA_rev + insert + rc(bcA_fwd)
            records.append((id: "sampleA_p2_\(i)", seq: seq))
        }

        // 10 reads for Sample B — Pattern 1: fwd...rc(rev)
        for i in 0..<10 {
            let insert = randomInsert(length: insertLen)
            let seq = bcB_fwd + insert + rc(bcB_rev)
            records.append((id: "sampleB_p1_\(i)", seq: seq))
        }

        // 5 untagged reads (no barcodes)
        for i in 0..<5 {
            let seq = randomInsert(length: insertLen + 50)
            records.append((id: "untagged_\(i)", seq: seq))
        }

        let fastqURL = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(records: records, to: fastqURL)

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastqURL,
            sampleBarcodes: [
                SampleBarcodePair(sampleName: "SampleA", forwardSequence: bcA_fwd, reverseSequence: bcA_rev),
                SampleBarcodePair(sampleName: "SampleB", forwardSequence: bcB_fwd, reverseSequence: bcB_rev),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 35)
        XCTAssertEqual(result.assignedReads, 30, "30 barcode-tagged reads should be assigned")
        XCTAssertEqual(result.unassignedReadCount, 5, "5 untagged reads should be unassigned")

        // Verify per-sample assignment
        let sampleA = result.sampleResults.first { $0.sampleName == "SampleA" }
        let sampleB = result.sampleResults.first { $0.sampleName == "SampleB" }
        XCTAssertNotNil(sampleA)
        XCTAssertNotNil(sampleB)
        XCTAssertEqual(sampleA?.readCount, 20, "Sample A should have 20 reads (10 P1 + 10 P2)")
        XCTAssertEqual(sampleB?.readCount, 10, "Sample B should have 10 reads")
    }

    func testAsymmetricDemuxAllFourOrientations() async throws {
        let insertLen = 3000
        var records: [(id: String, seq: String)] = []

        // Pattern 1: fwd...rc(rev)
        for i in 0..<5 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "p1_\(i)", seq: bcA_fwd + insert + rc(bcA_rev)))
        }

        // Pattern 2: rev...rc(fwd)
        for i in 0..<5 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "p2_\(i)", seq: bcA_rev + insert + rc(bcA_fwd)))
        }

        // Pattern 3: fwd...rev (both forward)
        for i in 0..<5 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "p3_\(i)", seq: bcA_fwd + insert + bcA_rev))
        }

        // Pattern 4: rc(rev)...rc(fwd) (both RC)
        for i in 0..<5 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "p4_\(i)", seq: rc(bcA_rev) + insert + rc(bcA_fwd)))
        }

        let fastqURL = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(records: records, to: fastqURL)

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastqURL,
            sampleBarcodes: [
                SampleBarcodePair(sampleName: "SampleA", forwardSequence: bcA_fwd, reverseSequence: bcA_rev),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 20)
        XCTAssertEqual(result.assignedReads, 20,
            "All 20 reads across 4 orientations should be assigned to SampleA")
        XCTAssertEqual(result.unassignedReadCount, 0)
    }

    func testAsymmetricDemuxMinimumInsertEnforced() async throws {
        var records: [(id: String, seq: String)] = []

        // Insert too short (500bp < 2000bp minimum)
        for i in 0..<10 {
            let shortInsert = randomInsert(length: 500)
            records.append((id: "short_\(i)", seq: bcA_fwd + shortInsert + rc(bcA_rev)))
        }

        // Insert long enough (3000bp > 2000bp minimum)
        for i in 0..<10 {
            let longInsert = randomInsert(length: 3000)
            records.append((id: "long_\(i)", seq: bcA_fwd + longInsert + rc(bcA_rev)))
        }

        let fastqURL = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(records: records, to: fastqURL)

        let config = ExactBarcodeDemuxConfig(
            inputURL: fastqURL,
            sampleBarcodes: [
                SampleBarcodePair(sampleName: "SampleA", forwardSequence: bcA_fwd, reverseSequence: bcA_rev),
            ],
            minimumInsert: 2000
        )

        let result = try await ExactBarcodeDemux.run(config: config, progress: { _, _ in })

        XCTAssertEqual(result.totalReads, 20)
        // Only the 10 long-insert reads should be assigned
        XCTAssertEqual(result.assignedReads, 10,
            "Only reads with insert >= 2000bp should be assigned")
        XCTAssertEqual(result.unassignedReadCount, 10,
            "Short-insert reads should be unassigned")
    }

    func testAsymmetricDemuxBundlesHavePreviewAndReadIDs() async throws {
        let insertLen = 3000
        var records: [(id: String, seq: String)] = []
        for i in 0..<20 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "read_\(i)", seq: bcA_fwd + insert + rc(bcA_rev)))
        }

        let fastqURL = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(records: records, to: fastqURL)

        // Create a root bundle to enable virtual bundle creation
        let rootBundleURL = tempDir.appendingPathComponent("root.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fastqURL, to: rootBundleURL.appendingPathComponent("reads.fastq"))

        let outputDir = tempDir.appendingPathComponent("demux-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let barcodeKit = BarcodeKitDefinition(
            id: "test-asymmetric",
            displayName: "Test Asymmetric Kit",
            vendor: "test",
            platform: .nanopore,
            kitType: .nativeBarcoding,
            barcodes: [
                BarcodeEntry(id: "BC01", i7Sequence: bcA_fwd, i5Sequence: bcA_rev),
            ]
        )

        let sampleAssignments = [
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleA",
                sampleName: "Sample A",
                forwardBarcodeID: "BC01",
                forwardSequence: bcA_fwd,
                reverseBarcodeID: "BC01",
                reverseSequence: bcA_rev
            ),
        ]

        let config = DemultiplexConfig(
            inputURL: fastqURL,
            sourceBundleURL: rootBundleURL,
            barcodeKit: barcodeKit,
            outputDirectory: outputDir,
            symmetryMode: .asymmetric,
            sampleAssignments: sampleAssignments,
            rootBundleURL: rootBundleURL,
            rootFASTQFilename: "reads.fastq"
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(config: config, progress: { _, _ in })

        // Verify per-barcode bundle structure
        XCTAssertGreaterThan(result.outputBundleURLs.count, 0, "Should create at least one bundle")

        for bundleURL in result.outputBundleURLs {
            // Read IDs file
            let readIDURL = bundleURL.appendingPathComponent("read-ids.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: readIDURL.path),
                "Bundle should have read-ids.txt: \(bundleURL.lastPathComponent)")
            let readIDs = try String(contentsOf: readIDURL, encoding: .utf8)
                .split(separator: "\n").filter { !$0.isEmpty }
            XCTAssertGreaterThan(readIDs.count, 0, "read-ids.txt should not be empty")

            // Preview file
            let previewURL = bundleURL.appendingPathComponent("preview.fastq")
            XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
                "Bundle should have preview.fastq: \(bundleURL.lastPathComponent)")

            // Manifest
            let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL)
            XCTAssertNotNil(manifest, "Bundle should have a derived manifest")
            if let manifest {
                if case .demuxedVirtual = manifest.payload {
                    // Expected
                } else {
                    XCTFail("Expected demuxedVirtual payload, got \(manifest.payload)")
                }
            }
        }
    }

    // MARK: - Demux Materialization

    func testAsymmetricDemuxMaterialization() async throws {
        let insertLen = 3000
        var records: [(id: String, seq: String)] = []
        for i in 0..<15 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "read_\(i)", seq: bcA_fwd + insert + rc(bcA_rev)))
        }
        for i in 0..<10 {
            let insert = randomInsert(length: insertLen)
            records.append((id: "readB_\(i)", seq: bcB_fwd + insert + rc(bcB_rev)))
        }

        let fastqURL = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(records: records, to: fastqURL)

        let rootBundleURL = tempDir.appendingPathComponent("root.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fastqURL, to: rootBundleURL.appendingPathComponent("reads.fastq"))

        let outputDir = tempDir.appendingPathComponent("demux-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let barcodeKit = BarcodeKitDefinition(
            id: "test-asymmetric-2",
            displayName: "Test Asymmetric Kit 2",
            vendor: "test",
            platform: .nanopore,
            kitType: .nativeBarcoding,
            barcodes: [
                BarcodeEntry(id: "BC01", i7Sequence: bcA_fwd, i5Sequence: bcA_rev),
                BarcodeEntry(id: "BC02", i7Sequence: bcB_fwd, i5Sequence: bcB_rev),
            ]
        )

        let sampleAssignments = [
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleA", sampleName: "Sample A",
                forwardBarcodeID: "BC01", forwardSequence: bcA_fwd,
                reverseBarcodeID: "BC01", reverseSequence: bcA_rev
            ),
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleB", sampleName: "Sample B",
                forwardBarcodeID: "BC02", forwardSequence: bcB_fwd,
                reverseBarcodeID: "BC02", reverseSequence: bcB_rev
            ),
        ]

        let config = DemultiplexConfig(
            inputURL: fastqURL,
            sourceBundleURL: rootBundleURL,
            barcodeKit: barcodeKit,
            outputDirectory: outputDir,
            symmetryMode: .asymmetric,
            sampleAssignments: sampleAssignments,
            rootBundleURL: rootBundleURL,
            rootFASTQFilename: "reads.fastq"
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(config: config, progress: { _, _ in })

        // Materialize each per-barcode bundle
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        for bundleURL in result.outputBundleURLs {
            let matDir = tempDir.appendingPathComponent("mat-\(bundleURL.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: matDir, withIntermediateDirectories: true)

            let matURL = try await materializer.materialize(
                bundleURL: bundleURL, tempDirectory: matDir, progress: nil
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: matURL.path),
                "Materialized output should exist for \(bundleURL.lastPathComponent)")

            let reader = FASTQReader(validateSequence: false)
            var matRecords: [FASTQRecord] = []
            for try await record in reader.records(from: matURL) {
                matRecords.append(record)
            }
            XCTAssertGreaterThan(matRecords.count, 0,
                "Materialized bundle should contain reads: \(bundleURL.lastPathComponent)")
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds. Fix any type mismatches — `FASTQSampleBarcodeAssignment` uses a synthesized memberwise init and requires a `metadata: [String: String]` parameter (use `[:]`). Verify all struct inits compile before running tests.

- [ ] **Step 3: Run the engine-level tests**

Run: `swift test --filter "DemultiplexPipelineIntegrationTests/testAsymmetricDemuxAssignsReadsToCorrectSamples" 2>&1 | tail -15`
Expected: PASS.

Run: `swift test --filter "DemultiplexPipelineIntegrationTests/testAsymmetricDemuxAllFourOrientations" 2>&1 | tail -15`
Expected: PASS.

Run: `swift test --filter "DemultiplexPipelineIntegrationTests/testAsymmetricDemuxMinimumInsertEnforced" 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 4: Run the pipeline-level tests**

Run: `swift test --filter "DemultiplexPipelineIntegrationTests/testAsymmetricDemuxBundlesHavePreviewAndReadIDs" 2>&1 | tail -15`
Run: `swift test --filter "DemultiplexPipelineIntegrationTests/testAsymmetricDemuxMaterialization" 2>&1 | tail -15`
Expected: Both PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishWorkflowTests/DemultiplexPipelineIntegrationTests.swift
git commit -m "test: add asymmetric demux pipeline integration tests

5 tests covering: multi-sample assignment, all 4 orientation patterns,
minimum insert enforcement, per-barcode bundle structure verification,
and end-to-end materialization of demuxed virtual bundles."
```

---

### Task 5: Full Regression Suite Verification

- [ ] **Step 1: Run all FASTQ operation tests**

Run: `swift test --filter "FASTQOperation" 2>&1 | grep -E "passed|failed|Executed" | tail -15`
Expected: All tests pass.

- [ ] **Step 2: Run demux tests**

Run: `swift test --filter "DemultiplexPipeline" 2>&1 | grep -E "passed|failed|Executed" | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Run full project test suite**

Run: `swift test 2>&1 | grep -E "Test run with|passed|failed" | tail -5`
Expected: All tests pass, zero regressions.

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "test: complete full materialization + special operations regression suite"
```

---

## Summary of Deliverables

| # | Test | Operation | Category |
|---|------|-----------|----------|
| 1 | testErrorCorrectionRoundTrip | errorCorrection | Full |
| 2 | testDeduplicateRoundTrip | deduplicate | Full |
| 3 | testDeinterleaveRoundTrip | deinterleave | Paired |
| 4 | testPairedEndMergeRoundTrip | pairedEndMerge | Paired |
| 5 | testPairedEndRepairRoundTrip | pairedEndRepair | Paired |
| 6 | testAsymmetricDemuxAssignsReadsToCorrectSamples | demux (asymmetric) | Special |
| 7 | testAsymmetricDemuxAllFourOrientations | demux (asymmetric) | Special |
| 8 | testAsymmetricDemuxMinimumInsertEnforced | demux (asymmetric) | Special |
| 9 | testAsymmetricDemuxBundlesHavePreviewAndReadIDs | demux (pipeline) | Special |
| 10 | testAsymmetricDemuxMaterialization | demux (materialization) | Special |

**Not included:** Orient and interleave (non-deinterleave) tests. Orient requires vsearch + a reference FASTA which adds complexity. Interleave (combining R1+R2) requires the source bundle to be detected as having separate R1/R2 files, which needs specific bundle metadata setup. These can be added as follow-up if needed, but the core regression coverage for the 9 operations is solid — especially the demux asymmetric path which was the primary concern.
