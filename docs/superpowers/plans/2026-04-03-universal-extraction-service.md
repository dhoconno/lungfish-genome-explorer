# Universal ReadExtractionService Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralize all read extraction (by ID, BAM region, database query), FASTQ source resolution, BAM reference matching, and bundle creation into one universal service.

**Architecture:** A `ReadExtractionService` actor in `LungfishWorkflow/Extraction/` provides three extraction strategies. A `FASTQSourceResolver` actor handles all virtual FASTQ materialization. A `BAMRegionMatcher` encapsulates the multi-strategy reference matching. All existing extraction code in VCs and pipelines migrates to use these services.

**Tech Stack:** Swift 6.2, Swift Concurrency (actors), samtools, seqkit, `NativeToolRunner`, `@Sendable` closures

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift` | Config types for all 3 strategies + result type + metadata |
| `Sources/LungfishWorkflow/Extraction/BAMRegionMatcher.swift` | Multi-strategy BAM @SQ reference matching |
| `Sources/LungfishWorkflow/Extraction/FASTQSourceResolver.swift` | Centralized virtual FASTQ materialization |
| `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift` | Main actor with 3 extraction methods + bundle creation |
| `Tests/LungfishWorkflowTests/Extraction/BAMRegionMatcherTests.swift` | Unit tests for BAM matching strategies |
| `Tests/LungfishWorkflowTests/Extraction/FASTQSourceResolverTests.swift` | Unit tests for FASTQ resolution |
| `Tests/LungfishWorkflowTests/Extraction/ReadExtractionServiceTests.swift` | Integration tests for extraction + bundling |
| `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift` | CLI `lungfish extract reads` with 3 strategy subcommands |

### Modified Files
| File | Changes |
|------|---------|
| `Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift` | Delegate extraction + bundling to ReadExtractionService |
| `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` | Replace inline BAM extraction with service call |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` | Wire extraction to service |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Wire extraction to service |
| `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` | Wire extraction to service |
| `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` | Use service for bundle creation |
| `Sources/LungfishApp/App/AppDelegate.swift` | Use FASTQSourceResolver for materialization |

---

## Task 1: Configuration and Result Types

**Files:**
- Create: `Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift`

- [ ] **Step 1: Create the Extraction directory**

```bash
mkdir -p Sources/LungfishWorkflow/Extraction
mkdir -p Tests/LungfishWorkflowTests/Extraction
```

- [ ] **Step 2: Create ExtractionConfig.swift with all types**

```swift
// ExtractionConfig.swift — Configuration and result types for ReadExtractionService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Extraction Configurations

/// Configuration for read-ID-based extraction (Kraken2 pattern).
///
/// Uses `seqkit grep` to filter FASTQ files by a set of read IDs.
public struct ReadIDExtractionConfig: Sendable {
    /// One or two source FASTQ files (single or paired-end).
    public let sourceFASTQs: [URL]
    /// Read IDs to extract.
    public let readIDs: Set<String>
    /// When true, strip /1 and /2 suffixes from read IDs so both mates are extracted.
    public let keepReadPairs: Bool
    /// Directory for output files.
    public let outputDirectory: URL
    /// Base name for output files (without extension).
    public let outputBaseName: String

    public init(sourceFASTQs: [URL], readIDs: Set<String>, keepReadPairs: Bool = true,
                outputDirectory: URL, outputBaseName: String) {
        self.sourceFASTQs = sourceFASTQs
        self.readIDs = readIDs
        self.keepReadPairs = keepReadPairs
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
    }
}

/// Configuration for BAM-region-based extraction.
///
/// Uses `samtools view` + `samtools fastq` to extract reads aligned to specific regions.
public struct BAMRegionExtractionConfig: Sendable {
    /// The indexed BAM file.
    public let bamURL: URL
    /// Reference names or genomic regions (e.g., "NC_005831.2", "chr1:1000-2000").
    public let regions: [String]
    /// Directory for output files.
    public let outputDirectory: URL
    /// Base name for output files (without extension).
    public let outputBaseName: String

    public init(bamURL: URL, regions: [String], outputDirectory: URL, outputBaseName: String) {
        self.bamURL = bamURL
        self.regions = regions
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
    }
}

/// Configuration for database-based extraction (NAO-MGS pattern).
///
/// Queries a SQLite database for read sequences and writes them to FASTQ.
public struct DatabaseExtractionConfig: Sendable {
    /// Path to the SQLite database.
    public let databaseURL: URL
    /// Sample ID to query.
    public let sampleId: String
    /// Taxonomy IDs to extract reads for.
    public let taxIds: [Int]
    /// Reference accessions to filter by.
    public let accessions: [String]
    /// Maximum reads to extract (nil = all).
    public let maxReads: Int?
    /// Directory for output files.
    public let outputDirectory: URL
    /// Base name for output files (without extension).
    public let outputBaseName: String

    public init(databaseURL: URL, sampleId: String, taxIds: [Int], accessions: [String],
                maxReads: Int? = nil, outputDirectory: URL, outputBaseName: String) {
        self.databaseURL = databaseURL
        self.sampleId = sampleId
        self.taxIds = taxIds
        self.accessions = accessions
        self.maxReads = maxReads
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
    }
}

// MARK: - Extraction Result

/// Result from any extraction method.
public struct ExtractionResult: Sendable {
    /// Extracted FASTQ file(s) — one for single-end, two for paired-end.
    public let fastqURLs: [URL]
    /// Number of reads extracted.
    public let readCount: Int
    /// Whether output is paired-end.
    public let pairedEnd: Bool

    public init(fastqURLs: [URL], readCount: Int, pairedEnd: Bool) {
        self.fastqURLs = fastqURLs
        self.readCount = readCount
        self.pairedEnd = pairedEnd
    }
}

// MARK: - Bundle Metadata

/// Metadata written into extraction output bundles for provenance.
public struct ExtractionMetadata: Sendable, Codable {
    /// Human-readable description of the source (e.g., "Kraken2 classification").
    public let sourceDescription: String
    /// Tool that produced the data being extracted from.
    public let toolName: String
    /// When the extraction was performed.
    public let extractionDate: Date
    /// Tool-specific key-value parameters.
    public let parameters: [String: String]

    public init(sourceDescription: String, toolName: String,
                extractionDate: Date = Date(), parameters: [String: String] = [:]) {
        self.sourceDescription = sourceDescription
        self.toolName = toolName
        self.extractionDate = extractionDate
        self.parameters = parameters
    }
}

// MARK: - BAM Region Match Result

/// Result of matching requested regions against BAM @SQ reference names.
public struct RegionMatchResult: Sendable {
    /// Regions that matched BAM references (ready to pass to samtools).
    public let matchedRegions: [String]
    /// Requested regions that had no match.
    public let unmatchedRegions: [String]
    /// Which matching strategy succeeded.
    public let strategy: MatchStrategy
    /// All reference names found in the BAM header.
    public let bamReferenceNames: [String]

    public enum MatchStrategy: String, Sendable {
        case exact
        case prefix
        case contains
        case fallbackAll
        case noBAM
    }
}

// MARK: - Bundle Naming

/// Builds filesystem-safe bundle names for extraction output.
public enum ExtractionBundleNaming {

    /// Build a bundle name from source display name and selection description.
    ///
    /// Pattern: `{sourceName}_{selectionDescription}_extract`
    /// - Spaces → underscores
    /// - Special characters stripped
    /// - Truncated to 200 chars
    public static func bundleName(source: String, selection: String) -> String {
        let raw = "\(source)_\(selection)_extract"
        let sanitized = raw
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        let truncated = String(sanitized.prefix(200))
        return truncated.isEmpty ? "extraction_result" : truncated
    }
}

// MARK: - Errors

public enum ExtractionError: Error, LocalizedError {
    case noSourceFASTQ
    case emptyReadIDSet
    case bamFileNotFound(URL)
    case bamNotIndexed(URL)
    case noMatchingRegions(requested: [String], available: [String])
    case emptyExtraction
    case seqkitFailed(String)
    case samtoolsFailed(String)
    case databaseQueryFailed(String)
    case bundleCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSourceFASTQ: return "No source FASTQ file available for extraction"
        case .emptyReadIDSet: return "No read IDs provided for extraction"
        case .bamFileNotFound(let url): return "BAM file not found: \(url.lastPathComponent)"
        case .bamNotIndexed(let url): return "BAM file is not indexed: \(url.lastPathComponent)"
        case .noMatchingRegions(let req, let avail):
            return "None of the requested regions (\(req.prefix(3).joined(separator: ", "))) match BAM references (\(avail.prefix(3).joined(separator: ", ")))"
        case .emptyExtraction: return "Extraction produced no reads"
        case .seqkitFailed(let msg): return "seqkit grep failed: \(msg)"
        case .samtoolsFailed(let msg): return "samtools failed: \(msg)"
        case .databaseQueryFailed(let msg): return "Database query failed: \(msg)"
        case .bundleCreationFailed(let msg): return "Bundle creation failed: \(msg)"
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift
git commit -m "feat: add extraction configuration, result, and error types"
```

---

## Task 2: BAM Region Matcher

**Files:**
- Create: `Sources/LungfishWorkflow/Extraction/BAMRegionMatcher.swift`
- Create: `Tests/LungfishWorkflowTests/Extraction/BAMRegionMatcherTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LungfishWorkflowTests/Extraction/BAMRegionMatcherTests.swift
import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("BAMRegionMatcher")
struct BAMRegionMatcherTests {

    @Test("Exact match finds matching regions")
    func exactMatch() {
        let bamRefs = ["NC_005831.2", "NC_001477.1", "NC_012532.1"]
        let result = BAMRegionMatcher.match(
            regions: ["NC_005831.2", "NC_001477.1"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions == ["NC_005831.2", "NC_001477.1"])
        #expect(result.unmatchedRegions.isEmpty)
        #expect(result.strategy == .exact)
    }

    @Test("Prefix match handles version differences")
    func prefixMatch() {
        let bamRefs = ["NC_005831.2_complete_genome", "NC_001477.1_segment_L"]
        let result = BAMRegionMatcher.match(
            regions: ["NC_005831.2"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions == ["NC_005831.2_complete_genome"])
        #expect(result.strategy == .prefix)
    }

    @Test("Contains match finds embedded accessions")
    func containsMatch() {
        let bamRefs = ["ref|NC_005831.2|complete", "ref|NC_001477.1|partial"]
        let result = BAMRegionMatcher.match(
            regions: ["NC_005831.2"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions == ["ref|NC_005831.2|complete"])
        #expect(result.strategy == .contains)
    }

    @Test("Fallback returns all refs when nothing matches")
    func fallback() {
        let bamRefs = ["contig_1", "contig_2", "contig_3"]
        let result = BAMRegionMatcher.match(
            regions: ["NC_005831.2"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions == ["contig_1", "contig_2", "contig_3"])
        #expect(result.strategy == .fallbackAll)
    }

    @Test("Empty refs returns noBAM strategy")
    func emptyRefs() {
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: [])
        #expect(result.matchedRegions.isEmpty)
        #expect(result.strategy == .noBAM)
    }

    @Test("Deduplicates matched regions")
    func deduplication() {
        let bamRefs = ["NC_005831.2"]
        let result = BAMRegionMatcher.match(
            regions: ["NC_005831.2", "NC_005831.2"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BAMRegionMatcherTests 2>&1 | head -10`
Expected: Compilation failure

- [ ] **Step 3: Implement BAMRegionMatcher**

```swift
// Sources/LungfishWorkflow/Extraction/BAMRegionMatcher.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Multi-strategy matcher for BAM @SQ reference names.
///
/// Tries progressively fuzzier matching strategies to find BAM references
/// that correspond to requested extraction regions. All tools that extract
/// reads from BAM (classifiers, mappers, assemblers) use this single matcher.
public enum BAMRegionMatcher {

    /// Match requested regions against BAM reference names.
    ///
    /// Strategies tried in order:
    /// 1. **Exact:** Region equals a reference name
    /// 2. **Prefix:** Region is a prefix of a reference, or vice versa
    /// 3. **Contains:** Region appears anywhere in a reference, or vice versa
    /// 4. **Fallback:** Return all references (BAM may be pre-filtered)
    public static func match(
        regions: [String],
        againstReferences bamRefs: [String]
    ) -> RegionMatchResult {
        guard !bamRefs.isEmpty else {
            return RegionMatchResult(
                matchedRegions: [],
                unmatchedRegions: regions,
                strategy: .noBAM,
                bamReferenceNames: []
            )
        }

        let bamRefSet = Set(bamRefs)
        let uniqueRegions = Array(Set(regions))

        // Strategy 1: Exact match
        let exactMatched = uniqueRegions.filter { bamRefSet.contains($0) }
        if !exactMatched.isEmpty {
            let unmatched = uniqueRegions.filter { !bamRefSet.contains($0) }
            return RegionMatchResult(
                matchedRegions: exactMatched,
                unmatchedRegions: unmatched,
                strategy: .exact,
                bamReferenceNames: bamRefs
            )
        }

        // Strategy 2: Prefix match
        var prefixMatched: [String] = []
        var prefixUnmatched: [String] = []
        for region in uniqueRegions {
            if let ref = bamRefs.first(where: { $0.hasPrefix(region) || region.hasPrefix($0) }) {
                prefixMatched.append(ref)
            } else {
                prefixUnmatched.append(region)
            }
        }
        if !prefixMatched.isEmpty {
            return RegionMatchResult(
                matchedRegions: Array(Set(prefixMatched)),
                unmatchedRegions: prefixUnmatched,
                strategy: .prefix,
                bamReferenceNames: bamRefs
            )
        }

        // Strategy 3: Contains match
        var containsMatched: [String] = []
        var containsUnmatched: [String] = []
        for region in uniqueRegions {
            if let ref = bamRefs.first(where: { $0.contains(region) || region.contains($0) }) {
                containsMatched.append(ref)
            } else {
                containsUnmatched.append(region)
            }
        }
        if !containsMatched.isEmpty {
            return RegionMatchResult(
                matchedRegions: Array(Set(containsMatched)),
                unmatchedRegions: containsUnmatched,
                strategy: .contains,
                bamReferenceNames: bamRefs
            )
        }

        // Strategy 4: Fallback — return all BAM references
        return RegionMatchResult(
            matchedRegions: bamRefs,
            unmatchedRegions: uniqueRegions,
            strategy: .fallbackAll,
            bamReferenceNames: bamRefs
        )
    }

    /// Read @SQ reference names from a BAM header via samtools.
    public static func readBAMReferences(bamURL: URL, runner: NativeToolRunner) async throws -> [String] {
        let result = try await runner.run(.samtools, arguments: ["view", "-H", bamURL.path])
        guard result.isSuccess else {
            throw ExtractionError.samtoolsFailed("Failed to read BAM header: \(result.stderr)")
        }
        return result.stdout.split(separator: "\n")
            .filter { $0.hasPrefix("@SQ") }
            .compactMap { line in
                line.split(separator: "\t")
                    .first(where: { $0.hasPrefix("SN:") })
                    .map { String($0.dropFirst(3)) }
            }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BAMRegionMatcherTests`
Expected: All 6 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Extraction/BAMRegionMatcher.swift Tests/LungfishWorkflowTests/Extraction/BAMRegionMatcherTests.swift
git commit -m "feat: add BAMRegionMatcher with multi-strategy reference matching"
```

---

## Task 3: FASTQSourceResolver

**Files:**
- Create: `Sources/LungfishWorkflow/Extraction/FASTQSourceResolver.swift`
- Create: `Tests/LungfishWorkflowTests/Extraction/FASTQSourceResolverTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LungfishWorkflowTests/Extraction/FASTQSourceResolverTests.swift
import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("FASTQSourceResolver")
struct FASTQSourceResolverTests {

    @Test("Resolves physical FASTQ file directly")
    func physicalFASTQ() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        let resolver = FASTQSourceResolver()
        let resolved = try await resolver.resolve(
            bundleURL: bundleURL,
            tempDirectory: tmp,
            progress: { _, _ in }
        )
        #expect(resolved.count == 1)
        #expect(resolved[0].lastPathComponent == "reads.fastq")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Returns empty for nonexistent bundle")
    func nonexistentBundle() async throws {
        let resolver = FASTQSourceResolver()
        do {
            _ = try await resolver.resolve(
                bundleURL: URL(fileURLWithPath: "/nonexistent.lungfishfastq"),
                tempDirectory: FileManager.default.temporaryDirectory,
                progress: { _, _ in }
            )
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
    }

    @Test("UUID temp file names never contain 'materialized'")
    func tempFileNaming() {
        let name = FASTQSourceResolver.tempFileName(extension: "fastq")
        #expect(!name.contains("materialized"))
        #expect(name.hasSuffix(".fastq"))
        // Should be UUID-based
        #expect(name.count > 10)
    }
}
```

- [ ] **Step 2: Implement FASTQSourceResolver**

```swift
// Sources/LungfishWorkflow/Extraction/FASTQSourceResolver.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Centralized resolver for FASTQ source files.
///
/// Handles physical FASTQs, virtual subsets, trim derivatives, and multi-file
/// bundles. When materialization is needed, temp files use UUIDs — never
/// "materialized.fastq" or other generic names that could leak into user-facing UI.
public actor FASTQSourceResolver {

    public init() {}

    /// Resolve readable FASTQ file(s) for a bundle.
    ///
    /// Resolution order:
    /// 1. Physical FASTQ file in bundle → return directly
    /// 2. `derived.manifest.json` → materialize from root bundle + derivative spec
    /// 3. `source-files.json` → resolve multi-file virtual concatenation
    /// 4. Fallback: scan for any .fastq/.fastq.gz file
    ///
    /// - Parameters:
    ///   - bundleURL: The .lungfishfastq bundle URL
    ///   - tempDirectory: Where to write materialized files (uses UUID names)
    ///   - progress: Progress callback
    /// - Returns: One or two FASTQ file URLs (single/paired-end)
    public func resolve(
        bundleURL: URL,
        tempDirectory: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleURL.path) else {
            throw ExtractionError.noSourceFASTQ
        }

        // Strategy 1: Check for physical FASTQ files
        let physicalFASTQs = try findPhysicalFASTQs(in: bundleURL)
        if !physicalFASTQs.isEmpty {
            return physicalFASTQs
        }

        // Strategy 2: Check for derived manifest (virtual bundle)
        let derivedManifestURL = bundleURL.appendingPathComponent("derived.manifest.json")
        if fm.fileExists(atPath: derivedManifestURL.path) {
            progress(0.1, "Materializing virtual FASTQ\u{2026}")
            return try await materializeFromDerivedManifest(
                bundleURL: bundleURL,
                manifestURL: derivedManifestURL,
                tempDirectory: tempDirectory,
                progress: progress
            )
        }

        // Strategy 3: Check for source-files.json (multi-file)
        let sourceFilesURL = bundleURL.appendingPathComponent("source-files.json")
        if fm.fileExists(atPath: sourceFilesURL.path) {
            return try resolveMultiFile(manifestURL: sourceFilesURL)
        }

        // Strategy 4: Fallback — scan for any FASTQ
        let scanned = try scanForFASTQFiles(in: bundleURL)
        guard !scanned.isEmpty else {
            throw ExtractionError.noSourceFASTQ
        }
        return scanned
    }

    /// Generate a UUID-based temp file name (never "materialized").
    public static func tempFileName(extension ext: String) -> String {
        return "\(UUID().uuidString.prefix(12)).\(ext)"
    }

    // MARK: - Private Helpers

    private func findPhysicalFASTQs(in bundleURL: URL) throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let fastqs = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent.lowercased()
            return (ext == "fastq" || ext == "fq" || ext == "gz")
                && !name.contains("preview")
                && !name.hasPrefix(".")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Filter out preview.fastq (only ~1000 reads for virtual bundles)
        return fastqs.filter { !$0.lastPathComponent.lowercased().contains("preview") }
    }

    private func materializeFromDerivedManifest(
        bundleURL: URL,
        manifestURL: URL,
        tempDirectory: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        // Delegate to FASTQDerivativeService for the actual materialization
        // This wraps the existing service without replacing its internals
        let fm = FileManager.default
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let outputURL = tempDirectory.appendingPathComponent(Self.tempFileName(extension: "fastq"))

        // Use FASTQDerivativeService.shared for materialization
        let materializedURL = try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
            fromBundle: bundleURL,
            tempDirectory: tempDirectory,
            progress: { msg in progress(0.5, msg) }
        )

        return [materializedURL]
    }

    private func resolveMultiFile(manifestURL: URL) throws -> [URL] {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FASTQSourceFileManifest.self, from: data)
        return manifest.files.map { manifestURL.deletingLastPathComponent().appendingPathComponent($0.path) }
    }

    private func scanForFASTQFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "fastq" || ext == "fq" ||
                   (ext == "gz" && (url.deletingPathExtension().pathExtension.lowercased() == "fastq"
                                 || url.deletingPathExtension().pathExtension.lowercased() == "fq"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
```

Note: The implementer must read `FASTQDerivativeService` to verify the `materializeDatasetFASTQ(fromBundle:tempDirectory:progress:)` method signature is correct. Adapt if needed.

- [ ] **Step 3: Run tests**

Run: `swift test --filter FASTQSourceResolverTests`
Expected: All 3 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishWorkflow/Extraction/FASTQSourceResolver.swift Tests/LungfishWorkflowTests/Extraction/FASTQSourceResolverTests.swift
git commit -m "feat: add FASTQSourceResolver for centralized FASTQ source resolution"
```

---

## Task 4: ReadExtractionService

**Files:**
- Create: `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`

- [ ] **Step 1: Read existing extraction code**

Read these files to understand the exact patterns to replicate:
- `TaxonomyExtractionPipeline.swift` — seqkit grep invocation (lines 175-187)
- `EsVirituResultViewController.swift` — samtools view + fastq (lines 857-872)
- `NativeToolRunner` — `.seqkit` and `.samtools` tool references

- [ ] **Step 2: Create ReadExtractionService.swift**

```swift
// Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish", category: "ReadExtractionService")

/// Universal service for extracting reads from any tool's output.
///
/// Provides three extraction strategies:
/// 1. **Read ID filtering** (seqkit grep) — for Kraken2 and other per-read classifiers
/// 2. **BAM region extraction** (samtools view + fastq) — for EsViritu, TaxTriage, mappers, assemblers
/// 3. **Database query** — for NAO-MGS (reads stored in SQLite)
///
/// All strategies produce `ExtractionResult` with FASTQ file URLs. The `createBundle()`
/// method wraps results into a `.lungfishfastq` bundle with proper naming and provenance.
public actor ReadExtractionService {

    private let toolRunner: NativeToolRunner

    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    // MARK: - Strategy 1: Read ID Extraction (seqkit grep)

    /// Extract reads matching a set of read IDs from FASTQ file(s).
    public func extractByReadIDs(
        _ config: ReadIDExtractionConfig,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> ExtractionResult {
        guard !config.readIDs.isEmpty else { throw ExtractionError.emptyReadIDSet }
        guard !config.sourceFASTQs.isEmpty else { throw ExtractionError.noSourceFASTQ }

        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Write read IDs to temp file
        let readIdFile = config.outputDirectory.appendingPathComponent("read_ids.txt")
        let idData = Data(config.readIDs.joined(separator: "\n").utf8)
        try idData.write(to: readIdFile)

        var outputURLs: [URL] = []
        let fileCount = config.sourceFASTQs.count
        var totalReads = 0

        for (index, source) in config.sourceFASTQs.enumerated() {
            let suffix = fileCount > 1 ? "_R\(index + 1)" : ""
            let outputURL = config.outputDirectory.appendingPathComponent(
                "\(config.outputBaseName)\(suffix).fastq"
            )

            let baseProgress = Double(index) / Double(fileCount)
            let phaseSize = 1.0 / Double(fileCount)
            progress(baseProgress + phaseSize * 0.1, "Filtering \(source.lastPathComponent)\u{2026}")

            let args = ["grep", "-f", readIdFile.path, source.path, "-o", outputURL.path, "--threads", "4"]
            let result = try await toolRunner.run(.seqkit, arguments: args, timeout: 7200)
            guard result.isSuccess else {
                throw ExtractionError.seqkitFailed(result.stderr)
            }

            // Count reads in output
            let countResult = try await toolRunner.run(.seqkit, arguments: ["stats", "-T", outputURL.path])
            if let line = countResult.stdout.split(separator: "\n").last {
                let fields = line.split(separator: "\t")
                if fields.count > 3, let count = Int(fields[3].trimmingCharacters(in: .whitespaces)) {
                    totalReads += count
                }
            }

            outputURLs.append(outputURL)
            progress(baseProgress + phaseSize, "Filtered \(source.lastPathComponent)")
        }

        // Clean up temp read ID file
        try? fm.removeItem(at: readIdFile)

        logger.info("Read ID extraction complete: \(totalReads) reads from \(fileCount) file(s)")

        return ExtractionResult(
            fastqURLs: outputURLs,
            readCount: totalReads,
            pairedEnd: fileCount > 1
        )
    }

    // MARK: - Strategy 2: BAM Region Extraction (samtools)

    /// Extract reads from BAM regions using samtools.
    public func extractByBAMRegion(
        _ config: BAMRegionExtractionConfig,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> ExtractionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.bamURL.path) else {
            throw ExtractionError.bamFileNotFound(config.bamURL)
        }
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Read BAM header and match regions
        progress(0.05, "Reading BAM header\u{2026}")
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(bamURL: config.bamURL, runner: toolRunner)
        let matchResult = BAMRegionMatcher.match(regions: config.regions, againstReferences: bamRefs)

        logger.info("BAM has \(bamRefs.count) references. Match strategy: \(matchResult.strategy.rawValue). Matched: \(matchResult.matchedRegions.count)")

        let outputFASTQ = config.outputDirectory.appendingPathComponent("\(config.outputBaseName).fastq")

        if matchResult.strategy == .fallbackAll || matchResult.strategy == .noBAM {
            // Extract ALL reads — no region filter
            progress(0.3, "Extracting all reads from BAM\u{2026}")
            let args = ["fastq", "-0", outputFASTQ.path, config.bamURL.path]
            let result = try await toolRunner.run(.samtools, arguments: args, timeout: 3600)
            guard result.isSuccess else {
                throw ExtractionError.samtoolsFailed(result.stderr)
            }
        } else {
            // Two-step: samtools view → samtools fastq
            let extractedBAM = config.outputDirectory.appendingPathComponent("_extracted.bam")

            progress(0.2, "Extracting \(matchResult.matchedRegions.count) region(s)\u{2026}")
            var viewArgs = ["view", "-b", "-o", extractedBAM.path, config.bamURL.path]
            viewArgs.append(contentsOf: matchResult.matchedRegions)
            let viewResult = try await toolRunner.run(.samtools, arguments: viewArgs, timeout: 3600)
            guard viewResult.isSuccess else {
                throw ExtractionError.samtoolsFailed(viewResult.stderr)
            }

            progress(0.7, "Converting to FASTQ\u{2026}")
            let fastqArgs = ["fastq", "-0", outputFASTQ.path, extractedBAM.path]
            let fastqResult = try await toolRunner.run(.samtools, arguments: fastqArgs, timeout: 3600)
            guard fastqResult.isSuccess else {
                throw ExtractionError.samtoolsFailed(fastqResult.stderr)
            }

            // Clean up intermediate BAM
            try? fm.removeItem(at: extractedBAM)
        }

        // Verify non-empty output
        let attrs = try? fm.attributesOfItem(atPath: outputFASTQ.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        guard fileSize > 0 else {
            throw ExtractionError.emptyExtraction
        }

        // Count reads
        let countResult = try? await toolRunner.run(.seqkit, arguments: ["stats", "-T", outputFASTQ.path])
        var readCount = 0
        if let line = countResult?.stdout.split(separator: "\n").last {
            let fields = line.split(separator: "\t")
            if fields.count > 3, let count = Int(fields[3].trimmingCharacters(in: .whitespaces)) {
                readCount = count
            }
        }

        progress(1.0, "Extraction complete")
        logger.info("BAM extraction complete: \(readCount) reads")

        return ExtractionResult(fastqURLs: [outputFASTQ], readCount: readCount, pairedEnd: false)
    }

    // MARK: - Strategy 3: Database Extraction (NAO-MGS)

    /// Extract reads from a SQLite database.
    ///
    /// Queries the database for reads matching the given tax IDs and accessions,
    /// then writes them to a FASTQ file.
    public func extractFromDatabase(
        _ config: DatabaseExtractionConfig,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> ExtractionResult {
        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        progress(0.1, "Querying database\u{2026}")

        // Open the NAO-MGS database and query reads
        let db = try NaoMgsDatabase(url: config.databaseURL)
        var allReads: [(seqId: String, sequence: String, quality: String)] = []

        for taxId in config.taxIds {
            for accession in config.accessions {
                let reads = try db.fetchReadsForAccession(
                    sample: config.sampleId,
                    taxId: taxId,
                    accession: accession,
                    maxReads: config.maxReads ?? Int.max
                )
                for read in reads {
                    if let seq = read.sequence, let qual = read.qualityString {
                        allReads.append((seqId: read.readName, sequence: seq, quality: qual))
                    }
                }
            }
        }

        progress(0.6, "Writing FASTQ\u{2026}")

        // Deduplicate by read ID
        var seen = Set<String>()
        let uniqueReads = allReads.filter { seen.insert($0.seqId).inserted }

        // Write FASTQ
        let outputFASTQ = config.outputDirectory.appendingPathComponent("\(config.outputBaseName).fastq")
        var fastqContent = ""
        for read in uniqueReads {
            fastqContent += "@\(read.seqId)\n\(read.sequence)\n+\n\(read.quality)\n"
        }
        try Data(fastqContent.utf8).write(to: outputFASTQ)

        progress(1.0, "Extraction complete")
        logger.info("Database extraction complete: \(uniqueReads.count) reads")

        return ExtractionResult(fastqURLs: [outputFASTQ], readCount: uniqueReads.count, pairedEnd: false)
    }

    // MARK: - Bundle Creation

    /// Wrap extracted FASTQ(s) into a .lungfishfastq bundle.
    ///
    /// Creates a properly named bundle with provenance metadata that appears
    /// in the sidebar with an informative display name.
    public func createBundle(
        from result: ExtractionResult,
        sourceName: String,
        selectionDescription: String,
        parentDirectory: URL,
        metadata: ExtractionMetadata
    ) throws -> URL {
        let fm = FileManager.default
        let bundleName = ExtractionBundleNaming.bundleName(source: sourceName, selection: selectionDescription)
        let bundleURL = parentDirectory.appendingPathComponent("\(bundleName).lungfishfastq")

        // Create bundle directory
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Move FASTQ files into bundle
        for fastqURL in result.fastqURLs {
            let dest = bundleURL.appendingPathComponent(fastqURL.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: fastqURL, to: dest)
        }

        // Write extraction metadata sidecar
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: bundleURL.appendingPathComponent("extraction-metadata.json"))

        // Write persisted FASTQ metadata
        let persistedMeta: [String: Any] = [
            "downloadSource": "read-extraction",
            "downloadDate": ISO8601DateFormatter().string(from: Date())
        ]
        let metaData = try JSONSerialization.data(withJSONObject: persistedMeta, options: .prettyPrinted)
        try metaData.write(to: bundleURL.appendingPathComponent(".lungfish-meta.json"))

        logger.info("Created extraction bundle: \(bundleName).lungfishfastq (\(result.readCount) reads)")
        return bundleURL
    }
}
```

Note: The `extractFromDatabase` method references `NaoMgsDatabase` — the implementer must verify the exact method signatures by reading `NaoMgsDatabase.swift`. The `fetchReadsForAccession` return type may need adapting.

- [ ] **Step 3: Build to verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds (may need to adjust imports or method signatures)

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift
git commit -m "feat: add ReadExtractionService with 3 extraction strategies and bundle creation"
```

---

## Task 5: Migrate Kraken2 Extraction

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift`

- [ ] **Step 1: Read both files to understand current flow**

The current flow is:
1. `TaxonomyExtractionPipeline.extract()` builds read ID set + runs seqkit grep → returns `[URL]`
2. `ViewerViewController+Taxonomy.createExtractedFASTQBundleOnMainThread()` wraps output in bundle

- [ ] **Step 2: Update TaxonomyExtractionPipeline to use ReadExtractionService**

Keep `buildReadIdSet()` (Kraken2-specific parsing). Replace the seqkit grep invocation and output handling with a call to `ReadExtractionService.extractByReadIDs()`:

```swift
public func extract(...) async throws -> [URL] {
    // Phase 1: Parse classification output (existing)
    // Phase 2: Build read ID set (existing buildReadIdSet)
    let readIDs = try buildReadIdSet(...)

    // Phase 3: Delegate to ReadExtractionService
    let extractionConfig = ReadIDExtractionConfig(
        sourceFASTQs: config.sourceFiles,
        readIDs: readIDs,
        keepReadPairs: config.keepReadPairs,
        outputDirectory: outputDirectory,
        outputBaseName: config.outputBaseName
    )
    let result = try await ReadExtractionService(toolRunner: toolRunner)
        .extractByReadIDs(extractionConfig, progress: { p, msg in
            progress?(0.3 + p * 0.65, msg)
        })

    return result.fastqURLs
}
```

- [ ] **Step 3: Update ViewerViewController+Taxonomy to use service for bundle creation**

Replace `createExtractedFASTQBundleOnMainThread` with a call to `ReadExtractionService.createBundle()`:

```swift
let service = ReadExtractionService()
let bundleURL = try service.createBundle(
    from: ExtractionResult(fastqURLs: outputURLs, readCount: readCount, pairedEnd: isPairedEnd),
    sourceName: sourceName,  // resolved via FASTQDisplayNameResolver
    selectionDescription: taxonDescription,
    parentDirectory: parentDir,
    metadata: ExtractionMetadata(
        sourceDescription: "Kraken2 classification",
        toolName: "Kraken2",
        parameters: ["taxIds": taxIds.map(String.init).joined(separator: ",")]
    )
)
```

- [ ] **Step 4: Build and run existing tests**

Run: `swift build --build-tests && swift test --filter TaxonomyExtraction 2>&1 | tail -10`
Expected: Build succeeds, existing extraction tests pass

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate Kraken2 extraction to ReadExtractionService"
```

---

## Task 6: Migrate EsViritu Extraction

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`

- [ ] **Step 1: Replace runBamExtractionPipeline with service call**

Delete the inline `runBamExtractionPipeline` method. Replace the `onExtract` callback in `presentExtractionSheet` with:

```swift
onExtract: { [weak self, weak window] outputName in
    guard let self, let window else { return }
    if let attached = window.attachedSheet { window.endSheet(attached) }

    guard let bamURL = self.bamURL else {
        // Show error
        return
    }

    Task {
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: accessions,
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            outputBaseName: outputName
        )
        let service = ReadExtractionService()
        let result = try await service.extractByBAMRegion(config, progress: { p, msg in
            // Report to OperationCenter
        })
        let bundleURL = try service.createBundle(
            from: result,
            sourceName: self.esVirituResult?.sampleId ?? "sample",
            selectionDescription: accessions.first ?? "extract",
            parentDirectory: projectDirectory,
            metadata: ExtractionMetadata(
                sourceDescription: "EsViritu viral detection",
                toolName: "EsViritu"
            )
        )
        // Refresh sidebar
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: migrate EsViritu extraction to ReadExtractionService"
```

---

## Task 7: Migrate TaxTriage, NAO-MGS, NVD Extractions

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`

- [ ] **Step 1: Wire TaxTriage extraction to service**

TaxTriage uses BAM files. Wire the `onExtract` callback to:
1. Look up reference accessions for selected organisms
2. Build `BAMRegionExtractionConfig`
3. Call `ReadExtractionService.extractByBAMRegion()`
4. Call `createBundle()` with organism names as selection description

- [ ] **Step 2: Wire NAO-MGS extraction to service**

NAO-MGS uses SQLite. Wire to:
1. Build `DatabaseExtractionConfig` with selected tax IDs
2. Call `ReadExtractionService.extractFromDatabase()`
3. Call `createBundle()`

- [ ] **Step 3: Wire NVD extraction to service**

NVD uses BAM with contig names. Wire to:
1. Build `BAMRegionExtractionConfig` with contig names
2. Call `ReadExtractionService.extractByBAMRegion()`
3. Call `createBundle()`

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate TaxTriage, NAO-MGS, NVD extraction to ReadExtractionService"
```

---

## Task 8: Migrate AppDelegate Materialization

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

- [ ] **Step 1: Replace materializeInputFilesIfNeeded with FASTQSourceResolver**

Find `materializeInputFilesIfNeeded` (~line 4632). Replace the manual materialization logic with:

```swift
private func resolveInputFiles(
    _ inputFiles: [URL],
    tempDirectory: URL,
    progress: (@Sendable (String) -> Void)? = nil
) async throws -> [URL] {
    let resolver = FASTQSourceResolver()
    var resolved: [URL] = []

    for inputURL in inputFiles {
        // Check if this is a bundle that needs resolution
        if inputURL.pathExtension == "lungfishfastq" || inputURL.deletingLastPathComponent().pathExtension == "lungfishfastq" {
            let bundleURL = inputURL.pathExtension == "lungfishfastq" ? inputURL : inputURL.deletingLastPathComponent()
            let urls = try await resolver.resolve(
                bundleURL: bundleURL,
                tempDirectory: tempDirectory,
                progress: { _, msg in progress?(msg) }
            )
            resolved.append(contentsOf: urls)
        } else {
            resolved.append(inputURL)
        }
    }

    return resolved
}
```

Update all callers of `materializeInputFilesIfNeeded` to use `resolveInputFiles` instead.

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: use FASTQSourceResolver for all input file materialization"
```

---

## Task 9: CLI `lungfish extract reads` Command

**Files:**
- Create: `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/CondaExtractCommand.swift` (deprecation alias)

- [ ] **Step 1: Read existing CLI command patterns**

Read `Sources/LungfishCLI/Commands/CondaExtractCommand.swift` and one other command (e.g., `ClassifyCommand.swift` or `FastqCommand.swift`) to understand:
- How ArgumentParser commands are structured (imports, GlobalOptions, @Argument/@Option/@Flag)
- How they invoke workflow services
- How they're registered in the parent command

- [ ] **Step 2: Create ExtractReadsCommand.swift**

Create `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift` with three strategy modes:

```swift
// ExtractReadsCommand.swift — CLI command for universal read extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

struct ExtractReadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reads",
        abstract: "Extract reads from classification results, BAM alignments, or databases"
    )

    // Strategy selection (mutually exclusive)
    @Flag(name: .long, help: "Extract by read ID list (Kraken2 pattern)")
    var byId = false

    @Flag(name: .long, help: "Extract by BAM region (EsViritu/TaxTriage/mapper pattern)")
    var byRegion = false

    @Flag(name: .long, help: "Extract from SQLite database (NAO-MGS pattern)")
    var byDb = false

    // Read ID strategy options
    @Option(name: .long, help: "File containing read IDs (one per line)")
    var ids: String?

    @Option(name: .long, help: "Source FASTQ file")
    var source: [String] = []

    @Flag(name: .long, inversion: .prefixedNo, help: "Keep read pairs (extract both mates)")
    var keepReadPairs = true

    // BAM region strategy options
    @Option(name: .long, help: "BAM file for region extraction")
    var bam: String?

    @Option(name: .long, help: "Region to extract (repeatable)")
    var region: [String] = []

    // Database strategy options
    @Option(name: .long, help: "SQLite database path")
    var database: String?

    @Option(name: .long, help: "Sample ID for database query")
    var sample: String?

    @Option(name: .long, help: "Taxonomy ID (repeatable)")
    var taxid: [Int] = []

    @Option(name: .long, help: "Accession filter (repeatable)")
    var accession: [String] = []

    @Option(name: .long, help: "Maximum reads to extract")
    var maxReads: Int?

    // Common options
    @Option(name: .shortAndLong, help: "Output FASTQ file path")
    var output: String

    @Flag(name: .long, help: "Wrap output in a .lungfishfastq bundle")
    var bundle = false

    @Option(name: .long, help: "Display name for the output bundle")
    var bundleName: String?

    mutating func run() async throws {
        let service = ReadExtractionService()
        let outputURL = URL(fileURLWithPath: output)
        let outputDir = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent

        let result: ExtractionResult

        if byId {
            guard let idsPath = ids else {
                throw ValidationError("--ids is required for --by-id extraction")
            }
            guard !source.isEmpty else {
                throw ValidationError("--source is required for --by-id extraction")
            }
            let idData = try String(contentsOfFile: idsPath, encoding: .utf8)
            let readIDs = Set(idData.split(separator: "\n").map(String.init))
            let config = ReadIDExtractionConfig(
                sourceFASTQs: source.map { URL(fileURLWithPath: $0) },
                readIDs: readIDs,
                keepReadPairs: keepReadPairs,
                outputDirectory: outputDir,
                outputBaseName: baseName
            )
            result = try await service.extractByReadIDs(config) { progress, msg in
                print("[\(Int(progress * 100))%] \(msg)")
            }

        } else if byRegion {
            guard let bamPath = bam else {
                throw ValidationError("--bam is required for --by-region extraction")
            }
            guard !region.isEmpty else {
                throw ValidationError("--region is required for --by-region extraction")
            }
            let config = BAMRegionExtractionConfig(
                bamURL: URL(fileURLWithPath: bamPath),
                regions: region,
                outputDirectory: outputDir,
                outputBaseName: baseName
            )
            result = try await service.extractByBAMRegion(config) { progress, msg in
                print("[\(Int(progress * 100))%] \(msg)")
            }

        } else if byDb {
            guard let dbPath = database else {
                throw ValidationError("--database is required for --by-db extraction")
            }
            guard let sampleId = sample else {
                throw ValidationError("--sample is required for --by-db extraction")
            }
            guard !taxid.isEmpty else {
                throw ValidationError("--taxid is required for --by-db extraction")
            }
            let config = DatabaseExtractionConfig(
                databaseURL: URL(fileURLWithPath: dbPath),
                sampleId: sampleId,
                taxIds: taxid,
                accessions: accession,
                maxReads: maxReads,
                outputDirectory: outputDir,
                outputBaseName: baseName
            )
            result = try await service.extractFromDatabase(config) { progress, msg in
                print("[\(Int(progress * 100))%] \(msg)")
            }

        } else {
            throw ValidationError("Specify one of --by-id, --by-region, or --by-db")
        }

        print("Extracted \(result.readCount) reads to \(result.fastqURLs.map(\.lastPathComponent).joined(separator: ", "))")

        if bundle {
            let name = bundleName ?? baseName
            let bundleURL = try service.createBundle(
                from: result,
                sourceName: name,
                selectionDescription: "extract",
                parentDirectory: outputDir,
                metadata: ExtractionMetadata(sourceDescription: "CLI extraction", toolName: "lungfish extract reads")
            )
            print("Created bundle: \(bundleURL.lastPathComponent)")
        }
    }
}
```

Register this command under the appropriate parent (read the CLI structure to find where `extract` or similar commands are registered).

- [ ] **Step 3: Update CondaExtractCommand with deprecation warning**

In `CondaExtractCommand.swift`, add at the start of `run()`:

```swift
FileHandle.standardError.write(Data("WARNING: 'lungfish conda extract' is deprecated. Use 'lungfish extract reads --by-id' instead.\n".utf8))
```

- [ ] **Step 4: Update all GUI Operations Panel log messages to show real CLI commands**

In each classifier's extraction callback, replace any `"(CLI command not yet available)"` or placeholder CLI strings with the actual `lungfish extract reads` command. Search across all VCs for these patterns and fix them.

- [ ] **Step 5: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add CLI 'lungfish extract reads' command with 3 strategies, deprecate conda extract"
```

---

## Task 10: Final Build and Test Verification

- [ ] **Step 1: Full build**

Run: `swift build --build-tests 2>&1 | tail -5`

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Run extraction-specific tests**

Run: `swift test --filter "BAMRegionMatcher|FASTQSourceResolver|TaxonomyExtraction" 2>&1 | tail -10`

- [ ] **Step 4: Verify no remaining inline extraction code**

Search for patterns that should have been migrated:
```bash
grep -rn "samtools.*fastq\|seqkit.*grep" Sources/LungfishApp/ --include="*.swift" | grep -v "//.*samtools\|//.*seqkit"
```
Expected: No results in LungfishApp (all extraction via service in LungfishWorkflow)

- [ ] **Step 5: Verify no "(CLI command not yet available)" placeholders**

```bash
grep -rn "not yet available\|CLI command not" Sources/ --include="*.swift"
```
Expected: No results (all operations have real CLI commands)
