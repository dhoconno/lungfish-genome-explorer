# Subset + Trim Operations Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write integration tests for all 11 subset and trim FASTQ operations, verifying the full round-trip (create → preview → payload → materialize → output), and fix any bugs discovered.

**Architecture:** Each operation gets a test in `FASTQOperationRoundTripTests.swift` (which imports `LungfishApp` for `FASTQDerivativeService.createDerivative()`). Tests use synthetic FASTQ data tailored to each operation's semantics. All tests follow the naming convention `test<OperationName>RoundTrip` so the full regression suite runs with `swift test --filter FASTQOperationRoundTripTests`.

**Tech Stack:** Swift 6.2, XCTest, FASTQDerivativeService, FASTQOperationTestHelper, seqkit, fastp, bbduk, cutadapt

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift` | Add 9 new round-trip tests (fixedTrim already tested) |
| Modify | `Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift` | Add helpers for variable-length and motif-embedded FASTQ generation |
| Modify | `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | Bug fixes if any tests fail |

---

### Task 1: Extend Test Helper with Specialized FASTQ Generators

**Files:**
- Modify: `Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift`

- [ ] **Step 1: Add variable-length FASTQ generator**

Add this method to `FASTQOperationTestHelper`:

```swift
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
                // Embed motif at specified position
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
            // Generate insert sequence (shorter to leave room for adapter)
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
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift
git commit -m "test: add specialized FASTQ generators for operation-specific testing"
```

---

### Task 2: Subsample Count + Proportion Round-Trip Tests

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add subsample count test**

Add to `FASTQOperationRoundTripTests`:

```swift
    // MARK: - Subset Operations

    func testSubsampleCountRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SubsampleCount")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 100, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .subsampleCount(20),
            progress: nil
        )

        // Verify preview and payload
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        // Materialize and verify count
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(records.count, 20, "Subsample count should produce exactly 20 reads")
    }

    func testSubsampleProportionRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SubsampleProp")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 200, readLength: 100
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

        // Materialize and verify approximate count (randomness tolerance)
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        // 25% of 200 = 50, allow wide tolerance for randomness
        XCTAssertGreaterThan(records.count, 20, "Subsample 25% of 200 should produce >20 reads")
        XCTAssertLessThan(records.count, 100, "Subsample 25% of 200 should produce <100 reads")
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testSubsampleCountRoundTrip" 2>&1 | tail -10`
Run: `swift test --filter "FASTQOperationRoundTripTests/testSubsampleProportionRoundTrip" 2>&1 | tail -10`
Expected: Both PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add subsample count and proportion round-trip tests"
```

---

### Task 3: Length Filter Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add length filter test**

```swift
    func testLengthFilterRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "LengthFilter")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // 25 reads at each of 50bp, 100bp, 150bp, 200bp = 100 total
        try FASTQOperationTestHelper.writeVariableLengthFASTQ(
            to: root.fastqURL, lengths: [50, 100, 150, 200], readsPerLength: 25
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

        // Materialize — should have 50 reads (the 100bp and 150bp ones)
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(records.count, 50, "Length filter [80,160] should keep 100bp+150bp reads = 50")
        for record in records {
            XCTAssertGreaterThanOrEqual(record.sequence.count, 80)
            XCTAssertLessThanOrEqual(record.sequence.count, 160)
        }
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testLengthFilterRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add length filter round-trip test"
```

---

### Task 4: Search Text Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add search text test**

```swift
    func testSearchTextRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SearchText")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // Write reads with identifiable ID patterns
        var records: [(id: String, sequence: String)] = []
        let bases: [Character] = ["A", "C", "G", "T"]
        for i in 0..<25 {
            var seq = ""
            for j in 0..<100 { seq.append(bases[(i + j) % 4]) }
            records.append((id: "alpha_\(i + 1)", sequence: seq))
        }
        for i in 0..<25 {
            var seq = ""
            for j in 0..<100 { seq.append(bases[(i + j + 1) % 4]) }
            records.append((id: "beta_\(i + 1)", sequence: seq))
        }
        try FASTQOperationTestHelper.writeFASTQ(records: records, to: root.fastqURL)

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .searchText(query: "alpha", field: .id, regex: false),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")

        // Materialize — should have exactly 25 "alpha" reads
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let output = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(output.count, 25, "Search for 'alpha' should match 25 reads")
        for record in output {
            XCTAssertTrue(record.identifier.contains("alpha"),
                "All matched reads should contain 'alpha' in ID, got \(record.identifier)")
        }
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testSearchTextRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add search text round-trip test"
```

---

### Task 5: Search Motif Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add search motif test**

```swift
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

        // Materialize — should have 25 reads containing the motif
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let output = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(output.count, 25, "Motif search should match 25 reads")
        for record in output {
            XCTAssertTrue(record.sequence.contains(motif),
                "All matched reads should contain motif '\(motif)'")
        }
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testSearchMotifRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add search motif round-trip test"
```

---

### Task 6: Contaminant Filter Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add contaminant filter test**

```swift
    func testContaminantFilterRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "ContamFilter")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 50, readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .contaminantFilter(
                mode: .phix,
                referenceFasta: nil,
                kmerSize: 31,
                hammingDistance: 1
            ),
            progress: nil
        )

        // Synthetic reads won't match PhiX, so all should pass
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        // Materialize — should retain all/most reads (no actual PhiX contamination)
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 40,
            "Synthetic reads should mostly pass PhiX filter (no real contamination)")
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testContaminantFilterRoundTrip" 2>&1 | tail -10`
Expected: PASS (requires bbduk; may fail if BBTools not available — that's acceptable).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add contaminant filter round-trip test"
```

---

### Task 7: Sequence Presence Filter Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add sequence presence filter test**

```swift
    func testSequencePresenceFilterRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "SeqFilter")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        let adapter = "AGATCGGAAGAGC"
        try FASTQOperationTestHelper.writeAdapterAppendedFASTQ(
            to: root.fastqURL,
            adapter: adapter,
            totalReads: 50,
            readsWithAdapter: 25,
            readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .sequencePresenceFilter(
                sequence: adapter,
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

        // Materialize — keepMatched=false means discard reads WITH adapter
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        // Should retain ~25 reads without adapter (exact count depends on bbduk matching)
        XCTAssertGreaterThan(records.count, 15,
            "Should retain most reads without adapter")
        XCTAssertLessThan(records.count, 40,
            "Should have removed reads with adapter")
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testSequencePresenceFilterRoundTrip" 2>&1 | tail -10`
Expected: PASS (requires bbduk).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add sequence presence filter round-trip test"
```

---

### Task 8: Quality Trim Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add quality trim test**

```swift
    // MARK: - Trim Operations

    func testQualityTrimRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "QualityTrim")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // High-quality synthetic reads — quality trim may not change them much
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 50, readLength: 100
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

        // Materialize and verify reads are present and ≤ original length
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 0, "Quality trim should produce reads")
        for record in records {
            XCTAssertLessThanOrEqual(record.sequence.count, 100,
                "Trimmed reads should be ≤ original 100bp")
            XCTAssertGreaterThan(record.sequence.count, 0,
                "Trimmed reads should not be empty")
        }
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testQualityTrimRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add quality trim round-trip test"
```

---

### Task 9: Adapter Trim Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add adapter trim test**

```swift
    func testAdapterTrimRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AdapterTrim")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        // Append Illumina universal adapter to all reads
        let illuminaAdapter = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
        try FASTQOperationTestHelper.writeAdapterAppendedFASTQ(
            to: root.fastqURL,
            adapter: illuminaAdapter,
            totalReads: 50,
            readsWithAdapter: 50,
            readLength: 100
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .adapterTrim(
                mode: .specified,
                sequence: illuminaAdapter,
                sequenceR2: nil,
                fastaFilename: nil
            ),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        // Materialize — reads should be shorter (adapter removed)
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 0, "Adapter trim should produce reads")
        // Reads had 100bp total (67bp insert + 33bp adapter), trim should remove adapter
        let trimmedRecords = records.filter { $0.sequence.count < 100 }
        XCTAssertGreaterThan(trimmedRecords.count, 0,
            "At least some reads should be shorter after adapter removal")
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testAdapterTrimRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add adapter trim round-trip test"
```

---

### Task 10: Primer Removal Round-Trip Test

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

- [ ] **Step 1: Add primer removal test**

```swift
    func testPrimerRemovalRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "PrimerRemoval")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        let primer = "GTTTCCCAGTCACGACG" // 17bp M13 forward primer
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

        // Materialize — reads should be ~100bp (117bp minus 17bp primer)
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertGreaterThan(records.count, 0, "Primer removal should produce reads")
        let trimmedRecords = records.filter { $0.sequence.count < 117 }
        XCTAssertGreaterThan(trimmedRecords.count, 0,
            "At least some reads should be shorter after primer removal")
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testPrimerRemovalRoundTrip" 2>&1 | tail -10`
Expected: PASS (requires cutadapt or bbduk).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add primer removal round-trip test"
```

---

### Task 11: Fixed Trim Materialization Test (Expand SP1 Coverage)

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

SP1 tested preview generation for fixedTrim. This task adds the full materialization round-trip.

- [ ] **Step 1: Add fixed trim materialization test**

```swift
    func testFixedTrimMaterializationRoundTrip() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FixedTrimMat")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 50, readLength: 100
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

        // Materialize and verify exact lengths
        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let matURL = try await materializer.materialize(
            bundleURL: derivedURL, tempDirectory: outDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: matURL)
        XCTAssertEqual(records.count, 50, "All reads should survive fixed trim")
        for record in records {
            XCTAssertEqual(record.sequence.count, 80,
                "Fixed trim 15+5 on 100bp reads should yield 80bp, got \(record.sequence.count)")
        }
    }
```

- [ ] **Step 2: Run to verify**

Run: `swift test --filter "FASTQOperationRoundTripTests/testFixedTrimMaterializationRoundTrip" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add fixed trim materialization round-trip test"
```

---

### Task 12: Full Regression Suite Verification

- [ ] **Step 1: Run the full FASTQ operation test suite**

Run: `swift test --filter "FASTQOperation" 2>&1 | tail -40`
Expected: All tests pass. Note any failures from missing tools (bbduk, cutadapt).

- [ ] **Step 2: Run the full project test suite for regressions**

Run: `swift test 2>&1 | grep -E "passed|failed|Executed" | tail -10`
Expected: All tests pass, zero regressions.

- [ ] **Step 3: List all test methods for verification**

Run: `swift test --list-tests 2>&1 | grep "FASTQOperationRoundTripTests"`
Expected output should include:
```
testSubsampleCountRoundTrip
testSubsampleProportionRoundTrip
testLengthFilterRoundTrip
testSearchTextRoundTrip
testSearchMotifRoundTrip
testContaminantFilterRoundTrip
testSequencePresenceFilterRoundTrip
testQualityTrimRoundTrip
testAdapterTrimRoundTrip
testPrimerRemovalRoundTrip
testFixedTrimMaterializationRoundTrip
testFixedTrimPreviewReadsAreTrimmed (from SP1)
testTrimDerivativeBundleContainsPreviewFASTQ (from SP1)
```

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "test: complete subset + trim operations regression suite"
```

---

## Summary of Deliverables

| # | Test | Operation | Payload |
|---|------|-----------|---------|
| 1 | testSubsampleCountRoundTrip | subsampleCount | subset |
| 2 | testSubsampleProportionRoundTrip | subsampleProportion | subset |
| 3 | testLengthFilterRoundTrip | lengthFilter | subset |
| 4 | testSearchTextRoundTrip | searchText | subset |
| 5 | testSearchMotifRoundTrip | searchMotif | subset |
| 6 | testContaminantFilterRoundTrip | contaminantFilter | subset |
| 7 | testSequencePresenceFilterRoundTrip | sequencePresenceFilter | subset |
| 8 | testQualityTrimRoundTrip | qualityTrim | trim |
| 9 | testAdapterTrimRoundTrip | adapterTrim | trim |
| 10 | testPrimerRemovalRoundTrip | primerRemoval | trim |
| 11 | testFixedTrimMaterializationRoundTrip | fixedTrim | trim |
