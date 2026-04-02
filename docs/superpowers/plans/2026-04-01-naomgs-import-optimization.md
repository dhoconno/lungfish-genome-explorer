# NAO-MGS Import Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three NAO-MGS import issues: add preview progress indicator, reduce reference fetch from 70k individual requests to a few bulk requests, and clean up partial result directories on cancellation/failure.

**Architecture:** Changes touch the parser (line progress callback), import service (top-5 accession filter + chunked bulk efetch + error wrapping), helper client (expose partial path on error), helper subprocess (emit path in error events), AppDelegate (cleanup on failure), and import sheet (line counter UI). A toy test fixture derived from a real CASPER dataset enables automated functional testing.

**Tech Stack:** Swift 6.2, Swift Testing framework, NCBI Entrez efetch API, SPM test targets

**Spec:** `docs/superpowers/specs/2026-04-01-naomgs-import-optimization-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Tests/Fixtures/naomgs/virus_hits_final.tsv.gz` | Already created | Toy fixture: 35 rows, 4 taxa, 14 accessions |
| `Tests/LungfishIntegrationTests/TestFixtures.swift` | Modify | Add `naomgs` accessor group |
| `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift` | Modify | Add `lineProgress` callback to `parseVirusHits()` |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift` | Modify | Line counter UI in preview section |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift` | Modify | Top-5 accession filter, chunked bulk efetch, `importAborted` error |
| `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift` | Modify | Capture resultPath from error events, new error case |
| `Sources/LungfishApp/App/MetagenomicsImportHelper.swift` | Modify | Emit resultPath in error event |
| `Sources/LungfishApp/App/AppDelegate.swift` | Modify | Cleanup partial directory on failure |
| `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift` | Create | All automated tests for this feature |

---

## Task 1: Test Fixture Accessors

**Files:**
- Modify: `Tests/LungfishIntegrationTests/TestFixtures.swift:90` (before the closing brace of the enum)

- [ ] **Step 1: Add naomgs accessor group to TestFixtures.swift**

In `Tests/LungfishIntegrationTests/TestFixtures.swift`, add a new `naomgs` enum after the `sarscov2` enum closing brace (line 90) and before the `// MARK: - Base URL Resolution` comment (line 92):

```swift
    /// NAO-MGS toy dataset (35 rows, 4 taxa, v2 format).
    ///
    /// Derived from a real CASPER wastewater surveillance dataset.
    /// Designed to test top-5 accession filtering, cross-taxon deduplication,
    /// and pair status variety (CP/UP/DP).
    public enum naomgs {
        private static let dir = "naomgs"

        /// Gzipped virus_hits_final.tsv (35 data rows, v2 column format).
        public static var virusHitsTsvGz: URL { fixture("virus_hits_final.tsv.gz") }

        private static func fixture(_ name: String) -> URL {
            let url = fixturesBaseURL.appendingPathComponent(dir).appendingPathComponent(name)
            precondition(
                FileManager.default.fileExists(atPath: url.path),
                "Test fixture missing: \(dir)/\(name). Run from a test target with .copy(\"Fixtures\") in Package.swift."
            )
            return url
        }
    }
```

Also update the `fixturesBaseURL` Strategy 2 walk-up check (line 113) to also verify the naomgs directory exists. Change:

```swift
            let check = candidate.appendingPathComponent("Fixtures/sarscov2")
```

to:

```swift
            let check = candidate.appendingPathComponent("Fixtures/sarscov2")
```

Actually, no change needed here — the sarscov2 check is sufficient to find the Fixtures directory, and naomgs lives alongside it.

- [ ] **Step 2: Verify fixture is accessible**

Run: `swift build --build-tests 2>&1 | tail -5`

Expected: Build succeeds. The fixture .gz file should be copied into the test bundle automatically since `Tests/Fixtures/` is already declared as `.copy("Fixtures")` in Package.swift.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/TestFixtures.swift
git commit -m "feat: add NAO-MGS toy fixture accessors to TestFixtures"
```

---

## Task 2: Line Progress Callback in Parser

**Files:**
- Modify: `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift:457` (`parseVirusHits` method)
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`:

```swift
// NaoMgsImportOptimizationTests.swift — Tests for NAO-MGS import optimization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO

struct NaoMgsImportOptimizationTests {

    // MARK: - Line Progress Callback

    @Test
    func parseVirusHitsCallsLineProgressCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        var reportedLineCounts: [Int] = []
        let hits = try await parser.parseVirusHits(at: url) { lineCount in
            reportedLineCounts.append(lineCount)
        }

        #expect(hits.count == 35, "Fixture has 35 data rows")
        #expect(!reportedLineCounts.isEmpty, "lineProgress should have been called at least once")
        // Final reported count should be >= 35 (header + 35 data lines = 36 total lines)
        #expect(reportedLineCounts.last! >= 35)
    }

    @Test
    func parseVirusHitsWorksWithoutCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Existing signature still works with no callback
        let hits = try await parser.parseVirusHits(at: url)
        #expect(hits.count == 35)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NaoMgsImportOptimizationTests 2>&1 | tail -20`

Expected: Compilation error — `parseVirusHits` doesn't accept a closure argument yet.

- [ ] **Step 3: Add lineProgress parameter to parseVirusHits**

In `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift`, change the `parseVirusHits` signature (line 457) from:

```swift
    public func parseVirusHits(at url: URL) async throws -> [NaoMgsVirusHit] {
```

to:

```swift
    public func parseVirusHits(
        at url: URL,
        lineProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [NaoMgsVirusHit] {
```

Then, inside the method, after the line `lineNumber += 1` (around line 469), add:

```swift
            if lineProgress != nil, lineNumber % 1000 == 0 {
                lineProgress?(lineNumber)
            }
```

And at the end of the method, just before the `logger.info("Parsed \(hits.count)...")` line (around line 564), add a final progress report:

```swift
        lineProgress?(lineNumber)
```

This ensures the final count is always reported even if total lines aren't a multiple of 1000.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NaoMgsImportOptimizationTests 2>&1 | tail -20`

Expected: Both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: add lineProgress callback to NaoMgsResultParser.parseVirusHits"
```

---

## Task 3: Preview Line Counter UI

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift:68-69` (state), `218-225` (preview UI), `342-389` (scanResults)

- [ ] **Step 1: Add linesScanned state**

In `NaoMgsImportSheet.swift`, add a new `@State` property after line 68 (`@State private var isScanning`):

```swift
    @State private var linesScanned: Int = 0
```

- [ ] **Step 2: Update scanResults to pass lineProgress callback**

In the `scanResults(at:)` method (line 342), reset `linesScanned` at the start alongside other state resets. After line 347 (`sourceFileName = nil`), add:

```swift
        linesScanned = 0
```

Then change the two calls to `parser.parseVirusHits` and `parser.loadResults` to pass a line progress callback. The `scanResults` method currently has two code paths:

For the **file path** (line 360), change:

```swift
                    let hits = try await parser.parseVirusHits(at: url)
```

to:

```swift
                    let hits = try await parser.parseVirusHits(at: url) { count in
                        Task { @MainActor in
                            self.linesScanned = count
                        }
                    }
```

For the **directory path** (line 358), `parser.loadResults(from:)` internally calls `parseVirusHits`. We need to thread the callback through. But `loadResults` doesn't currently accept a `lineProgress` parameter. We have two options: add `lineProgress` to `loadResults`, or restructure `scanResults` to always call `parseVirusHits` directly.

The simpler approach: add `lineProgress` to `loadResults`. In `NaoMgsResultParser.swift`, change `loadResults` (line 578) from:

```swift
    public func loadResults(from directory: URL, sampleName: String? = nil) async throws -> NaoMgsResult {
```

to:

```swift
    public func loadResults(
        from directory: URL,
        sampleName: String? = nil,
        lineProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> NaoMgsResult {
```

And change the internal call (line 608) from:

```swift
        let hits = try await parseVirusHits(at: virusHitsFile)
```

to:

```swift
        let hits = try await parseVirusHits(at: virusHitsFile, lineProgress: lineProgress)
```

Then in `NaoMgsImportSheet.scanResults`, change the directory path (line 358) from:

```swift
                    result = try await parser.loadResults(from: url)
```

to:

```swift
                    result = try await parser.loadResults(from: url) { count in
                        Task { @MainActor in
                            self.linesScanned = count
                        }
                    }
```

- [ ] **Step 3: Update preview section UI**

In the `previewSection` view (lines 218-225), replace the scanning branch:

```swift
            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning results\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
```

with:

```swift
            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if linesScanned > 0 {
                        Text("Scanning\u{2026} \(formatNumber(linesScanned)) lines")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scanning results\u{2026}")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`

Expected: Build succeeds. This is a UI change — manual testing needed to verify appearance.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift
git commit -m "feat: show line counter during NAO-MGS import preview scan"
```

---

## Task 4: Top-5 Accession Filtering

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:536-541`
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `NaoMgsImportOptimizationTests.swift`:

```swift
    // MARK: - Top-5 Accession Filtering

    @Test
    func selectTopAccessionsPerTaxonFiltersCorrectly() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()
        let hits = try await parser.parseVirusHits(at: url)

        let selected = MetagenomicsImportService.selectTopAccessionsPerTaxon(
            hits: hits,
            maxPerTaxon: 5
        )

        // Taxon 28875 has 9 accessions — only top 5 by hit count should be kept
        // Taxon 10941 has 3 — all kept
        // Taxon 2748378 has 2 — all kept
        // Taxon 1187973 has 1 — kept
        // Total unique: 11
        #expect(selected.count == 11, "Expected 11 unique accessions, got \(selected.count): \(selected)")

        // Taxon 28875: KR705168.1 has 4 hits (highest), must be included
        #expect(selected.contains("KR705168.1"))

        // Bottom accessions for taxon 28875 (1 hit each) should NOT be included
        // unless they happen to be in the top 5 after tie-breaking
        let bottom28875 = ["JN258371.1", "KJ752320.1", "KU356637.1"]
        let bottomIncluded = bottom28875.filter { selected.contains($0) }
        #expect(bottomIncluded.isEmpty, "Bottom-ranked 28875 accessions should be filtered out: \(bottomIncluded)")

        // All accessions for taxa with <=5 accessions should be present
        #expect(selected.contains("MH617353.1"), "2748378 accession should be kept")
        #expect(selected.contains("MH617681.1"), "2748378 accession should be kept")
        #expect(selected.contains("LC105580.1"), "10941 accession should be kept")
        #expect(selected.contains("LC105591.1"), "10941 accession should be kept")
        #expect(selected.contains("KP198630.1"), "10941 accession should be kept")
        #expect(selected.contains("JQ776552.1"), "1187973 accession should be kept")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter selectTopAccessionsPerTaxon 2>&1 | tail -20`

Expected: Compilation error — `selectTopAccessionsPerTaxon` doesn't exist yet.

- [ ] **Step 3: Implement selectTopAccessionsPerTaxon**

In `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`, add a new public static method inside the `MetagenomicsImportService` enum (before the closing `}`  on line 559):

```swift
    /// Selects the top N accessions per taxon by hit count, deduplicated across taxa.
    ///
    /// For each taxon, groups hits by `subjectSeqId`, counts hits per accession,
    /// sorts by count descending, and keeps only the top `maxPerTaxon`. The union
    /// across all taxa is returned as a sorted, deduplicated array.
    ///
    /// - Parameters:
    ///   - hits: All virus hits to analyze.
    ///   - maxPerTaxon: Maximum accessions to keep per taxon (default: 5).
    /// - Returns: Sorted array of unique accession IDs.
    public static func selectTopAccessionsPerTaxon(
        hits: [NaoMgsVirusHit],
        maxPerTaxon: Int = 5
    ) -> [String] {
        // Group by taxon
        var taxonHits: [Int: [NaoMgsVirusHit]] = [:]
        for hit in hits where !hit.subjectSeqId.isEmpty {
            taxonHits[hit.taxId, default: []].append(hit)
        }

        var selectedAccessions: Set<String> = []

        for (_, hitsForTaxon) in taxonHits {
            // Count hits per accession
            var accessionCounts: [String: Int] = [:]
            for hit in hitsForTaxon {
                accessionCounts[hit.subjectSeqId, default: 0] += 1
            }

            // Sort by count descending, then alphabetically for deterministic tie-breaking
            let sorted = accessionCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }

            // Keep top N
            for entry in sorted.prefix(maxPerTaxon) {
                selectedAccessions.insert(entry.key)
            }
        }

        return selectedAccessions.sorted()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter selectTopAccessionsPerTaxon 2>&1 | tail -20`

Expected: PASS.

- [ ] **Step 5: Wire up in importNaoMgs**

In `MetagenomicsImportService.importNaoMgs()`, replace lines 539-541:

```swift
            let accessions = Array(Set(result.virusHits.map(\.subjectSeqId).filter { !$0.isEmpty })).sorted()
```

with:

```swift
            let accessions = selectTopAccessionsPerTaxon(hits: result.virusHits, maxPerTaxon: 5)
```

- [ ] **Step 6: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: filter to top-5 accessions per taxon for NAO-MGS reference fetch"
```

---

## Task 5: Chunked Bulk NCBI Fetch

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:783-812` (replace `fetchNaoMgsReferences`)
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Write the FASTA splitting test**

Append to `NaoMgsImportOptimizationTests.swift`:

```swift
    // MARK: - FASTA Splitting

    @Test
    func splitMultiRecordFASTAExtractsRecords() {
        let concatenated = """
        >NC_045512.2 Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1
        ATTAAAGGTTTATACCTTCCCAGGTAACAAACCAACCAACTTTCGATCTCTTGTAGATCTG
        TTCTCTAAACGAACTTTAAAATCTGTGTGGCTGTCACTCGGCTGCATGCTTAGTGCACTCA
        >MH617353.1 Mammarenavirus juquitibense segment L
        CGCACCGGGGATCCTAGGCTTTTAGAGCACATGGATACATAGATCTACTCTCCAAGG
        >KR705168.1 Pepper mottle virus isolate PepMoV-Yolo
        AAATTAAAACAAATTCAATTCAAACAAAGCAATGGG
        TTGGAACCACTTGTACCACTACCC
        """

        let records = MetagenomicsImportService.splitMultiRecordFASTA(concatenated)

        #expect(records.count == 3, "Should find 3 FASTA records, got \(records.count)")
        #expect(records.keys.contains("NC_045512.2"))
        #expect(records.keys.contains("MH617353.1"))
        #expect(records.keys.contains("KR705168.1"))

        // Each record should start with '>' and contain sequence lines
        for (accession, fastaText) in records {
            #expect(fastaText.hasPrefix(">"), "Record for \(accession) should start with '>'")
            let lines = fastaText.split(separator: "\n")
            #expect(lines.count >= 2, "Record for \(accession) should have header + sequence")
        }

        // Multi-line sequence should be preserved
        let pepMottle = records["KR705168.1"]!
        let pepLines = pepMottle.split(separator: "\n")
        #expect(pepLines.count == 3, "PepMoV record should have 1 header + 2 sequence lines")
    }

    @Test
    func splitMultiRecordFASTAHandlesEmptyInput() {
        let records = MetagenomicsImportService.splitMultiRecordFASTA("")
        #expect(records.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter splitMultiRecordFASTA 2>&1 | tail -20`

Expected: Compilation error — `splitMultiRecordFASTA` doesn't exist yet.

- [ ] **Step 3: Implement splitMultiRecordFASTA**

Add to `MetagenomicsImportService` enum in `MetagenomicsImportService.swift` (inside the enum, before the closing brace):

```swift
    /// Splits a concatenated multi-record FASTA string into individual records.
    ///
    /// - Parameter fasta: Concatenated FASTA text (multiple `>` headers).
    /// - Returns: Dictionary mapping accession (first token after `>`) to full FASTA record text.
    public static func splitMultiRecordFASTA(_ fasta: String) -> [String: String] {
        guard !fasta.isEmpty else { return [:] }

        var records: [String: String] = [:]
        var currentAccession: String?
        var currentLines: [String] = []

        for line in fasta.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(">") {
                // Save previous record
                if let acc = currentAccession, !currentLines.isEmpty {
                    records[acc] = currentLines.joined(separator: "\n")
                }
                // Start new record
                let header = line.dropFirst() // Remove '>'
                let accession = header.split(separator: " ", maxSplits: 1).first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                currentAccession = accession.isEmpty ? nil : accession
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        // Save last record
        if let acc = currentAccession, !currentLines.isEmpty {
            records[acc] = currentLines.joined(separator: "\n")
        }

        return records
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter splitMultiRecordFASTA 2>&1 | tail -20`

Expected: Both tests pass.

- [ ] **Step 5: Replace fetchNaoMgsReferences with chunked bulk version**

Replace the entire `fetchNaoMgsReferences` private function (lines 783-812 in `MetagenomicsImportService.swift`) with:

```swift
private func fetchNaoMgsReferences(
    accessions: [String],
    into referencesDirectory: URL,
    progress: (@Sendable (Double, String) -> Void)?
) async -> [String] {
    guard !accessions.isEmpty else { return [] }

    let chunkSize = 200
    let chunks = stride(from: 0, to: accessions.count, by: chunkSize).map {
        Array(accessions[$0..<min($0 + chunkSize, accessions.count)])
    }

    let ncbi = NCBIService()
    var fetched: [String] = []

    for (chunkIndex, chunk) in chunks.enumerated() {
        let chunkLabel = "Fetching references batch \(chunkIndex + 1)/\(chunks.count) (\(chunk.count) accessions)"
        let baseFraction = Double(chunkIndex) / Double(chunks.count)
        progress?(0.70 + (0.28 * baseFraction), chunkLabel)

        do {
            let data = try await ncbi.efetch(
                database: .nucleotide,
                ids: chunk,
                format: .fasta
            )
            guard let fastaText = String(data: data, encoding: .utf8) else { continue }

            let records = MetagenomicsImportService.splitMultiRecordFASTA(fastaText)
            for (accession, recordText) in records {
                let fastaURL = referencesDirectory.appendingPathComponent("\(accession).fasta")
                try? recordText.data(using: .utf8)?.write(to: fastaURL, options: .atomic)
                fetched.append(accession)
            }
        } catch {
            // Fallback: try individual accessions in this chunk (best-effort)
            for (i, accession) in chunk.enumerated() {
                let individualFraction = baseFraction + (Double(i) / Double(accessions.count)) * (1.0 / Double(chunks.count))
                progress?(0.70 + (0.28 * individualFraction), "Fetching \(accession) (fallback)")
                do {
                    let data = try await ncbi.efetch(
                        database: .nucleotide,
                        ids: [accession],
                        format: .fasta
                    )
                    let fastaURL = referencesDirectory.appendingPathComponent("\(accession).fasta")
                    try data.write(to: fastaURL, options: .atomic)
                    fetched.append(accession)
                } catch {
                    // Best effort: skip failed accessions
                }
            }
        }
    }

    let fraction = 1.0
    progress?(0.70 + (0.28 * fraction), "Fetched \(fetched.count)/\(accessions.count) references")
    return fetched
}
```

- [ ] **Step 6: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: chunked bulk NCBI efetch for NAO-MGS reference download"
```

---

## Task 6: importAborted Error Case

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:97-118` (MetagenomicsImportError enum), `400-558` (importNaoMgs method)
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `NaoMgsImportOptimizationTests.swift`:

```swift
    // MARK: - Error Handling

    @Test
    func importAbortedErrorCarriesResultDirectory() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-abort-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        // includeAlignment=true with a hit that has data should create a SAM,
        // but samtools may fail on the tiny test data. Either way, any error
        // after directory creation should be wrapped in importAborted.
        do {
            _ = try await MetagenomicsImportService.importNaoMgs(
                inputURL: sourceFile,
                outputDirectory: outputDirectory,
                sampleName: "ABORT_TEST",
                includeAlignment: true,
                fetchReferences: false
            )
            // If it succeeds (samtools available), that's fine — check the directory exists
            let importsContents = try FileManager.default.contentsOfDirectory(
                at: outputDirectory, includingPropertiesForKeys: nil
            )
            #expect(!importsContents.isEmpty)
        } catch let error as MetagenomicsImportError {
            // If it fails, verify the error carries the directory
            if case .importAborted(let dir, _) = error {
                #expect(FileManager.default.fileExists(atPath: dir.path),
                    "importAborted should reference an existing directory")
            }
            // Other error types are also acceptable (e.g., toolUnavailable)
        }
    }
```

Also add the helper at the bottom of the file:

```swift
private func makeTemporaryDirectory(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

- [ ] **Step 2: Add importAborted error case**

In `MetagenomicsImportService.swift`, add a new case to `MetagenomicsImportError` (after `case toolUnavailable(String)` on line 102):

```swift
    case importAborted(resultDirectory: URL, underlying: Error)
```

Add the corresponding `errorDescription` branch in the switch (after the `toolUnavailable` case):

```swift
        case .importAborted(_, let underlying):
            return "Import aborted: \(underlying.localizedDescription)"
```

- [ ] **Step 3: Wrap errors after directory creation in importNaoMgs**

In the `importNaoMgs` method, after the result directory is created (line 453, `try ensureDirectoryExists(resultDirectory)`), all subsequent errors should be wrapped. The cleanest way: wrap the remainder in a do/catch block.

After line 453 (`try ensureDirectoryExists(resultDirectory)`), add:

```swift
        do {
```

Then before the final `progress?(1.0, ...)` and `return` (around line 549), close the do/catch:

```swift
        } catch {
            throw MetagenomicsImportError.importAborted(
                resultDirectory: resultDirectory,
                underlying: error
            )
        }
```

The full structure becomes:

```swift
        try ensureDirectoryExists(resultDirectory)

        let referencesDirectory = resultDirectory.appendingPathComponent("references", isDirectory: true)
        try ensureDirectoryExists(referencesDirectory)

        do {
            progress?(0.20, "Writing NAO-MGS sidecars...")
            // ... all existing code through reference fetching ...

            progress?(1.0, "NAO-MGS import complete")
            return NaoMgsImportResult(
                resultDirectory: resultDirectory,
                sampleName: normalizedSampleName,
                totalHitReads: result.totalHitReads,
                taxonCount: result.taxonSummaries.count,
                fetchedReferenceCount: fetchedAccessions.count,
                createdBAM: createdBAM
            )
        } catch {
            throw MetagenomicsImportError.importAborted(
                resultDirectory: resultDirectory,
                underlying: error
            )
        }
```

Note: the `ensureDirectoryExists(referencesDirectory)` call should also be inside the do/catch since it's after the result directory exists.

- [ ] **Step 4: Run test to verify it compiles and passes**

Run: `swift test --filter importAbortedError 2>&1 | tail -20`

Expected: PASS (test handles both success and failure paths).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: wrap post-directory errors in importAborted for cleanup"
```

---

## Task 7: Helper Emits resultPath on Error

**Files:**
- Modify: `Sources/LungfishApp/App/MetagenomicsImportHelper.swift:273-291`

- [ ] **Step 1: Update the catch block in MetagenomicsImportHelper**

In `MetagenomicsImportHelper.swift`, replace the catch block (lines 273-291):

```swift
            } catch {
                exitState.value = 1
                emit(Event(
                    event: "error",
                    progress: nil,
                    message: nil,
                    resultPath: nil,
                    sampleName: nil,
                    totalReads: nil,
                    speciesCount: nil,
                    virusCount: nil,
                    taxonCount: nil,
                    fetchedReferenceCount: nil,
                    createdBAM: nil,
                    fileCount: nil,
                    reportEntryCount: nil,
                    error: error.localizedDescription
                ))
            }
```

with:

```swift
            } catch {
                exitState.value = 1
                let partialPath: String?
                if case .importAborted(let dir, _) = error as? MetagenomicsImportError {
                    partialPath = dir.path
                } else {
                    partialPath = nil
                }
                emit(Event(
                    event: "error",
                    progress: nil,
                    message: nil,
                    resultPath: partialPath,
                    sampleName: nil,
                    totalReads: nil,
                    speciesCount: nil,
                    virusCount: nil,
                    taxonCount: nil,
                    fetchedReferenceCount: nil,
                    createdBAM: nil,
                    fileCount: nil,
                    reportEntryCount: nil,
                    error: error.localizedDescription
                ))
            }
```

You'll also need to add the import at the top of the file. Check if `LungfishWorkflow` is already imported — it is (line 5: `import LungfishWorkflow`), so `MetagenomicsImportError` is available.

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/App/MetagenomicsImportHelper.swift
git commit -m "feat: emit partial result directory path in helper error events"
```

---

## Task 8: Client Captures resultPath on Error + Cleanup in AppDelegate

**Files:**
- Modify: `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift:10-28` (error enum), `162-178` (event handling), `234-243` (error building)
- Modify: `Sources/LungfishApp/App/AppDelegate.swift:1302-1313` (catch block)

- [ ] **Step 1: Update MetagenomicsImportHelperClientError**

In `MetagenomicsImportHelperClient.swift`, change the `helperFailed` case (line 13) from:

```swift
    case helperFailed(String)
```

to:

```swift
    case helperFailed(String, partialResultDirectory: URL?)
```

Update the `errorDescription` switch case (around line 21) from:

```swift
        case .helperFailed(let message):
            return "Metagenomics import helper failed: \(message)"
```

to:

```swift
        case .helperFailed(let message, _):
            return "Metagenomics import helper failed: \(message)"
```

Add a convenience computed property after the `errorDescription` computed property:

```swift
    /// The partial result directory that should be cleaned up, if any.
    var partialResultDirectory: URL? {
        if case .helperFailed(_, let dir) = self { return dir }
        return nil
    }
```

- [ ] **Step 2: Capture resultPath from error events**

In the `handleEventLine` closure (around line 162), the `"error"` case currently only stores `helperError`. Update it to also capture `resultPath`:

Find:

```swift
            case "error":
                parseState.withLock { state in
                    state.helperError = event.error ?? event.message ?? "Import helper failed"
                }
```

Replace with:

```swift
            case "error":
                parseState.withLock { state in
                    state.helperError = event.error ?? event.message ?? "Import helper failed"
                    if let path = event.resultPath, !path.isEmpty {
                        state.resultPath = path
                    }
                }
```

- [ ] **Step 3: Include partial path in error**

In the error-building code (around line 234-242), change from:

```swift
        if process.terminationStatus != 0 {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let fallback = "Helper exited with status \(process.terminationStatus)"
            let message = helperError ?? (stderrMessage.isEmpty ? fallback : stderrMessage)
            throw MetagenomicsImportHelperClientError.helperFailed(message)
        }
```

to:

```swift
        if process.terminationStatus != 0 {
            let (helperError, partialPath) = parseState.withLock { ($0.helperError, $0.resultPath) }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let fallback = "Helper exited with status \(process.terminationStatus)"
            let message = helperError ?? (stderrMessage.isEmpty ? fallback : stderrMessage)
            let partialDir = partialPath.map { URL(fileURLWithPath: $0) }
            throw MetagenomicsImportHelperClientError.helperFailed(message, partialResultDirectory: partialDir)
        }
```

- [ ] **Step 4: Add cleanup in AppDelegate**

In `AppDelegate.swift`, in the catch block of `importClassifierResultFromURL` (lines 1302-1313), change:

```swift
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let detail = error.localizedDescription
                        OperationCenter.shared.fail(id: opID, detail: detail)
                        self?.showAlert(
                            title: "\(operationTitle) Failed",
                            message: detail
                        )
                    }
                }
            }
```

to:

```swift
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let detail = error.localizedDescription
                        OperationCenter.shared.fail(id: opID, detail: detail)

                        // Cleanup partial result directory left by failed import
                        if let partialDir = (error as? MetagenomicsImportHelperClientError)?
                            .partialResultDirectory {
                            try? FileManager.default.removeItem(at: partialDir)
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "Cleaned up partial import directory"
                            )
                        }

                        self?.showAlert(
                            title: "\(operationTitle) Failed",
                            message: detail
                        )
                    }
                }
            }
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift Sources/LungfishApp/App/AppDelegate.swift
git commit -m "feat: cleanup partial result directory on NAO-MGS import failure"
```

---

## Task 9: Full Pipeline Integration Test

**Files:**
- Modify: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Add full pipeline test**

Append to `NaoMgsImportOptimizationTests.swift`:

```swift
    // MARK: - Full Pipeline

    @Test
    func importNaoMgsWithFixtureCreatesValidBundle() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-pipeline-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = TestFixtures.naomgs.virusHitsTsvGz
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: url,
            outputDirectory: outputDirectory,
            sampleName: "CASPER_TEST",
            includeAlignment: false,
            fetchReferences: false
        )

        // Verify bundle structure
        let bundle = result.resultDirectory
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("virus_hits.json").path))

        // Verify result metadata
        #expect(result.sampleName == "CASPER_TEST")
        #expect(result.totalHitReads == 35)
        #expect(result.taxonCount == 4)
        #expect(result.createdBAM == false)
        #expect(result.fetchedReferenceCount == 0)

        // Verify manifest content
        let manifestData = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(NaoMgsManifest.self, from: manifestData)
        #expect(manifest.sampleName == "CASPER_TEST")
        #expect(manifest.hitCount == 35)
        #expect(manifest.taxonCount == 4)

        // Verify virus_hits.json content
        let hitsData = try Data(contentsOf: bundle.appendingPathComponent("virus_hits.json"))
        let hitsFile = try JSONDecoder().decode(NaoMgsVirusHitsFile.self, from: hitsData)
        #expect(hitsFile.virusHits.count == 35)
        #expect(hitsFile.taxonSummaries.count == 4)
        // Sorted by hit count descending
        #expect(hitsFile.taxonSummaries[0].taxId == 28875, "Top taxon should be 28875 (20 hits)")
    }

    @Test
    func importNaoMgsWithIdentityFilterReducesHits() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-filter-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = TestFixtures.naomgs.virusHitsTsvGz
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: url,
            outputDirectory: outputDirectory,
            sampleName: "FILTER_TEST",
            minIdentity: 99.5,
            includeAlignment: false,
            fetchReferences: false
        )

        // With a high identity threshold, some hits should be filtered out
        #expect(result.totalHitReads < 35, "Identity filter should reduce hit count")
        #expect(result.totalHitReads >= 0)
    }
```

Note: these tests need the `@testable import LungfishWorkflow` and imports for `NaoMgsManifest` and `NaoMgsVirusHitsFile`. Update the file's imports at the top:

```swift
import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow
```

- [ ] **Step 2: Run all tests**

Run: `swift test --filter NaoMgsImportOptimization 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 3: Run existing tests to verify no regressions**

Run: `swift test --filter MetagenomicsImportServiceTests 2>&1 | tail -20`

Expected: All existing tests still pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "test: add full pipeline integration tests for NAO-MGS import optimization"
```

---

## Task 10: Run Full Test Suite

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -30`

Expected: All tests pass (1397+ existing tests + new tests).

- [ ] **Step 2: If failures, fix and re-run**

Check for any compilation errors or test failures related to the changed method signatures (`parseVirusHits`, `loadResults`, `helperFailed`). Callers of these methods with positional arguments may need updates.

Search for other callers:

```bash
grep -rn "parseVirusHits\|loadResults.*from:" Sources/ Tests/ --include="*.swift" | grep -v ".build/"
```

Verify all call sites still compile (the new parameters have defaults, so existing callers should be fine).

- [ ] **Step 3: Commit any fixes if needed**

```bash
git add -A
git commit -m "fix: address test suite regressions from NAO-MGS import changes"
```
