# NAO-MGS Sample-Partitioned Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework NAO-MGS import so multi-sample inputs are partitioned by normalized sample into temporary TSVs, imported sequentially per sample, and assembled back into one final `naomgs-*` bundle.

**Architecture:** Add a streaming partitioner that coalesces rows for the same normalized sample across all resolved source TSVs. Reuse the existing per-sample import path with references disabled for staging imports, then assemble one final `hits.sqlite`, copy per-sample BAMs, fetch references once from merged data, and write the final manifest.

**Tech Stack:** Swift, Foundation, SQLite3, existing Lungfish workflow services, XCTest/Swift Testing integration tests, `lungfish-cli`

---

## File Structure

**Create**

- `Sources/LungfishWorkflow/Metagenomics/NaoMgsSamplePartitioner.swift`
  - Streaming splitter for monolithic files or directories of TSVs.
- `docs/superpowers/plans/2026-04-12-naomgs-sample-partition-import.md`
  - This implementation plan.

**Modify**

- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`
  - Replace monolithic NAO-MGS import flow with partition -> per-sample stage import -> final assembly.
- `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift`
  - Add helpers for creating a final merged database and appending summary rows from per-sample databases.
- `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`
  - Add partitioning and multi-source directory coverage.

**Optional Modify if extraction is cleaner**

- `Sources/LungfishIO/Services/NaoMgsBamMaterializer.swift`
  - Only if a small API adjustment is needed for staged imports or clearer BAM path handling.

---

### Task 1: Add Partitioning Tests First

**Files:**
- Modify: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Write the failing partitioning tests**

Add tests covering:

```swift
@Test
func partitionerSplitsMonolithicTSVByNormalizedSample() async throws {
    let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-")
    defer { try? FileManager.default.removeItem(at: workspace) }

    let source = workspace.appendingPathComponent("virus_hits_final.tsv")
    let content = """
    sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status
    SAMPLE_A_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP
    SAMPLE_A_S1_L002\tread2\t111\tACGT\tIIII\tACC1\t20\t0\t4\tFalse\tCP
    SAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP
    """
    try content.write(to: source, atomically: true, encoding: .utf8)

    let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)
    let result = try NaoMgsSamplePartitioner.partition(inputURLs: [source], outputDirectory: outputDir)

    #expect(result.sampleFiles.count == 2)
    #expect(result.sampleFiles.keys.contains("SAMPLE_A"))
    #expect(result.sampleFiles.keys.contains("SAMPLE_B"))

    let sampleA = try String(contentsOf: result.sampleFiles["SAMPLE_A"]!)
    #expect(sampleA.contains("read1"))
    #expect(sampleA.contains("read2"))
    #expect(!sampleA.contains("read3"))
}

@Test
func partitionerCoalescesOneSampleAcrossMultipleInputTSVs() async throws {
    let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-multi-")
    defer { try? FileManager.default.removeItem(at: workspace) }

    let dir = workspace.appendingPathComponent("input", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status\n"
    try (header + "SAMPLE_A_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP\n")
        .write(to: dir.appendingPathComponent("part1.tsv"), atomically: true, encoding: .utf8)
    try (header + "SAMPLE_A_S1_L002\tread2\t111\tACGT\tIIII\tACC1\t20\t0\t4\tFalse\tCP\nSAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP\n")
        .write(to: dir.appendingPathComponent("part2.tsv"), atomically: true, encoding: .utf8)

    let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)
    let result = try NaoMgsSamplePartitioner.partition(inputURLs: [dir.appendingPathComponent("part1.tsv"), dir.appendingPathComponent("part2.tsv")], outputDirectory: outputDir)

    let sampleA = try String(contentsOf: result.sampleFiles["SAMPLE_A"]!)
    #expect(sampleA.contains("read1"))
    #expect(sampleA.contains("read2"))
    #expect(sampleA.split(separator: "\n").count == 3)
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
swift test --filter NaoMgsImportOptimizationTests
```

Expected:

```text
error: cannot find 'NaoMgsSamplePartitioner' in scope
```

- [ ] **Step 3: Commit the failing tests**

```bash
git add Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "test: add NAO-MGS partitioning coverage"
```

### Task 2: Implement the Streaming Sample Partitioner

**Files:**
- Create: `Sources/LungfishWorkflow/Metagenomics/NaoMgsSamplePartitioner.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Add the partitioner type and result model**

Create the new file with this structure:

```swift
import Foundation
import LungfishIO

struct NaoMgsPartitionResult: Sendable {
    let sampleFiles: [String: URL]
    let totalRows: Int
}

enum NaoMgsSamplePartitioner {
    static func partition(
        inputURLs: [URL],
        outputDirectory: URL
    ) throws -> NaoMgsPartitionResult {
        fatalError("implement in later steps")
    }
}
```

- [ ] **Step 2: Implement the streaming split**

Fill in `partition(...)` so it:

```swift
static func partition(
    inputURLs: [URL],
    outputDirectory: URL
) throws -> NaoMgsPartitionResult {
    let fm = FileManager.default
    try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    var writers: [String: FileHandle] = [:]
    var sampleFiles: [String: URL] = [:]
    var headerLine: String?
    var totalRows = 0

    defer {
        for handle in writers.values {
            try? handle.close()
        }
    }

    func writer(for sample: String) throws -> FileHandle {
        if let existing = writers[sample] { return existing }
        let url = outputDirectory.appendingPathComponent("\(sample).tsv")
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        if let headerLine, let data = headerLine.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
        writers[sample] = handle
        sampleFiles[sample] = url
        return handle
    }

    for inputURL in inputURLs {
        let lines = try String(contentsOf: inputURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if index == 0 {
                if headerLine == nil { headerLine = line + "\n" }
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let normalized = NaoMgsDatabase.normalizeImportedSampleNameForPartitioning(String(fields[0]))
            let handle = try writer(for: normalized)
            try handle.write(contentsOf: Data((line + "\n").utf8))
            totalRows += 1
        }
    }

    return NaoMgsPartitionResult(sampleFiles: sampleFiles, totalRows: totalRows)
}
```

During implementation, replace the `String(contentsOf:)` placeholder with the same chunked plain-text / gzip-capable line streaming approach already used by NAO-MGS import. Keep the normalization helper shared with existing import behavior rather than duplicating a divergent regex.

- [ ] **Step 3: Expose one shared sample-normalization helper**

Extract or add a helper with a stable signature:

```swift
static func normalizeImportedSampleNameForPartitioning(_ raw: String) -> String {
    if let range = raw.range(of: #"_S\d+_L\d+.*$"#, options: .regularExpression) {
        return String(raw[..<range.lowerBound])
    }
    return raw
}
```

Place it in the existing NAO-MGS database/import path where both the partitioner and importer can call it without duplicating logic.

- [ ] **Step 4: Run the partitioning tests to verify they pass**

Run:

```bash
swift test --filter NaoMgsImportOptimizationTests
```

Expected:

```text
Test Suite 'NaoMgsImportOptimizationTests' passed
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/NaoMgsSamplePartitioner.swift Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: partition NAO-MGS imports by sample"
```

### Task 3: Add Final-Database Merge Support

**Files:**
- Modify: `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift`
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Write the failing merge test**

Add a test for merging per-sample staging DBs into one final DB:

```swift
@Test
func mergedDatabaseAppendsSampleScopedSummariesAndMergesReferenceLengths() async throws {
    let workspace = makeTemporaryDirectory(prefix: "naomgs-merge-")
    defer { try? FileManager.default.removeItem(at: workspace) }

    let sampleA = workspace.appendingPathComponent("sampleA.sqlite")
    let sampleB = workspace.appendingPathComponent("sampleB.sqlite")
    let merged = workspace.appendingPathComponent("merged.sqlite")

    try createSyntheticNaoMgsStageDatabase(
        at: sampleA,
        sample: "SAMPLE_A",
        taxId: 111,
        accession: "ACC_SHARED",
        referenceLength: 100
    )
    try createSyntheticNaoMgsStageDatabase(
        at: sampleB,
        sample: "SAMPLE_B",
        taxId: 222,
        accession: "ACC_SHARED",
        referenceLength: 150
    )

    try NaoMgsDatabase.createMergedSummaryDatabase(at: merged, from: [
        .init(sample: "SAMPLE_A", databaseURL: sampleA, bamRelativePath: "bams/SAMPLE_A.bam", bamIndexRelativePath: "bams/SAMPLE_A.bam.bai"),
        .init(sample: "SAMPLE_B", databaseURL: sampleB, bamRelativePath: "bams/SAMPLE_B.bam", bamIndexRelativePath: "bams/SAMPLE_B.bam.bai"),
    ])

    let db = try NaoMgsDatabase(at: merged)
    #expect(try db.fetchTaxonSummaryRows(samples: nil).count == 2)
    #expect(try db.fetchAccessionSummaries(sample: "SAMPLE_A", taxId: 111).count == 1)
    #expect(try db.referenceLength(for: "ACC_SHARED") == 150)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
swift test --filter mergedDatabaseAppendsSampleScopedSummariesAndMergesReferenceLengths
```

Expected:

```text
error: type 'NaoMgsDatabase' has no member 'createMergedSummaryDatabase'
```

- [ ] **Step 3: Implement merged-summary DB creation**

Add a new staging input model and merge API:

```swift
public struct NaoMgsStageDatabaseInput: Sendable {
    public let sample: String
    public let databaseURL: URL
    public let bamRelativePath: String
    public let bamIndexRelativePath: String?
}

public static func createMergedSummaryDatabase(
    at url: URL,
    from stageInputs: [NaoMgsStageDatabaseInput]
) throws {
    // create schema
    // append taxon_summaries
    // append accession_summaries
    // merge reference_lengths with MAX(length)
}
```

Implement the append with explicit SQL transactions and prepared statements. Do not copy `virus_hits`.

- [ ] **Step 4: Update merged taxon rows with BAM metadata**

Ensure the taxon row inserts populate:

```swift
INSERT INTO taxon_summaries (
    sample, tax_id, name, hit_count, unique_read_count,
    avg_identity, avg_bit_score, avg_edit_distance,
    pcr_duplicate_count, accession_count, top_accessions_json,
    bam_path, bam_index_path
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
```

using the per-stage bundle-relative BAM paths supplied in `NaoMgsStageDatabaseInput`.

- [ ] **Step 5: Run the merge tests to verify they pass**

Run:

```bash
swift test --filter NaoMgsImportOptimizationTests
```

Expected:

```text
Test Suite 'NaoMgsImportOptimizationTests' passed
```

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: merge staged NAO-MGS sample databases"
```

### Task 4: Rework NAO-MGS Import To Use Partition -> Stage Import -> Assembly

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Write the failing end-to-end multi-sample test**

Add an integration test:

```swift
@Test
func importNaoMgsDirectoryWithSplitSampleFilesProducesSingleMergedBundle() async throws {
    let workspace = makeTemporaryDirectory(prefix: "naomgs-directory-import-")
    defer { try? FileManager.default.removeItem(at: workspace) }

    let inputDir = workspace.appendingPathComponent("input", isDirectory: true)
    try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

    let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status\n"
    try (header + "SAMPLE_A_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP\n")
        .write(to: inputDir.appendingPathComponent("lane1.tsv"), atomically: true, encoding: .utf8)
    try (header + "SAMPLE_A_S1_L002\tread2\t111\tACGT\tIIII\tACC1\t20\t0\t4\tFalse\tCP\nSAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP\n")
        .write(to: inputDir.appendingPathComponent("lane2.tsv"), atomically: true, encoding: .utf8)

    let outputDir = workspace.appendingPathComponent("imports", isDirectory: true)
    let result = try await MetagenomicsImportService.importNaoMgs(
        inputURL: inputDir,
        outputDirectory: outputDir,
        fetchReferences: false
    )

    let db = try NaoMgsDatabase(at: result.resultDirectory.appendingPathComponent("hits.sqlite"))
    let rows = try db.fetchTaxonSummaryRows(samples: nil)
    #expect(rows.count == 2)
    #expect(rows.contains(where: { $0.sample == "SAMPLE_A" && $0.hitCount == 2 }))
    #expect(rows.contains(where: { $0.sample == "SAMPLE_B" && $0.hitCount == 1 }))
}
```

- [ ] **Step 2: Run the test to verify it fails on the old monolithic path**

Run:

```bash
swift test --filter importNaoMgsDirectoryWithSplitSampleFilesProducesSingleMergedBundle
```

Expected:

```text
FAIL: rows for SAMPLE_A are not coalesced from multiple source TSVs
```

- [ ] **Step 3: Implement the staged import flow**

Replace the top of `importNaoMgs(...)` with:

```swift
let virusHitsFiles = try resolveVirusHitsTSVs(inputURL: inputURL)
let stagingRoot = resultDirectory.appendingPathComponent(".naomgs-import-staging", isDirectory: true)
let partitionDir = stagingRoot.appendingPathComponent("partitioned", isDirectory: true)
let stageImportsDir = stagingRoot.appendingPathComponent("imports", isDirectory: true)

let partition = try NaoMgsSamplePartitioner.partition(
    inputURLs: virusHitsFiles,
    outputDirectory: partitionDir
)

var stageInputs: [NaoMgsStageDatabaseInput] = []
var totalHitCount = 0

for (index, sample) in partition.sampleFiles.keys.sorted().enumerated() {
    progress?(0.10 + (0.55 * Double(index) / Double(max(1, partition.sampleFiles.count))), "Importing sample \(index + 1)/\(partition.sampleFiles.count): \(sample)…")
    let sampleTSV = partition.sampleFiles[sample]!
    let stageResult = try await importNaoMgsSingleSampleStage(
        inputURL: sampleTSV,
        stagingDirectory: stageImportsDir,
        sampleName: sample
    )
    totalHitCount += stageResult.hitCount
    stageInputs.append(stageResult.stageInput)
}
```

Add a private helper result model for stage imports so the top-level method stays readable.

- [ ] **Step 4: Assemble the final bundle from staged imports**

After all stage imports succeed:

```swift
let finalDBURL = resultDirectory.appendingPathComponent("hits.sqlite")
try NaoMgsDatabase.createMergedSummaryDatabase(at: finalDBURL, from: stageInputs)
try copyStageBAMs(into: resultDirectory.appendingPathComponent("bams", isDirectory: true), from: stageInputs)
```

Then compute manifest values from the merged DB rather than from one stage DB.

- [ ] **Step 5: Run the new end-to-end test and the existing NAO-MGS suite**

Run:

```bash
swift test --filter NaoMgsImportOptimizationTests
```

Expected:

```text
Test Suite 'NaoMgsImportOptimizationTests' passed
```

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: stage NAO-MGS imports per sample"
```

### Task 5: Move Reference Fetching To Post-Merge And Verify Cleanup

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`
- Test: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

- [ ] **Step 1: Add failing tests for post-merge reference selection and staging cleanup**

Add focused tests:

```swift
@Test
func mergedReferenceSelectionDeduplicatesSharedAccessionsAcrossSamples() async throws {
    let workspace = makeTemporaryDirectory(prefix: "naomgs-reference-selection-")
    defer { try? FileManager.default.removeItem(at: workspace) }

    let dbURL = workspace.appendingPathComponent("hits.sqlite")
    try createMergedReferenceSelectionFixture(at: dbURL)

    let accessions = try NaoMgsDatabase(at: dbURL).allMiniBAMAccessions()
    #expect(accessions.filter { $0 == "ACC_SHARED" }.count == 1)
}

@Test
func importNaoMgsRemovesStagingDirectoryOnSuccess() async throws {
    let workspace = makeTemporaryDirectory(prefix: "naomgs-cleanup-")
    defer { try? FileManager.default.removeItem(at: workspace) }

    let outputDir = workspace.appendingPathComponent("imports", isDirectory: true)
    let result = try await MetagenomicsImportService.importNaoMgs(
        inputURL: TestFixtures.naomgs.virusHitsTsvGz,
        outputDirectory: outputDir,
        fetchReferences: false
    )

    let staging = result.resultDirectory.appendingPathComponent(".naomgs-import-staging")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter NaoMgsImportOptimizationTests
```

Expected:

```text
FAIL: staging directory still exists or reference selection still occurs too early
```

- [ ] **Step 3: Fetch references once from merged data and clean staging artifacts**

Update the final phase in `importNaoMgs(...)` to:

```swift
let mergedDB = try NaoMgsDatabase.openReadWrite(at: finalDBURL)
let accessions = (try? mergedDB.allMiniBAMAccessions()) ?? []
let fetchedAccessions = fetchReferences
    ? await fetchNaoMgsReferences(accessions: accessions, into: referencesDirectory, progress: progress)
    : []

if !fetchedAccessions.isEmpty {
    let refLengths = try await indexFetchedReferences(in: referencesDirectory)
    try mergedDB.updateReferenceLengths(refLengths)
    try mergedDB.refreshAccessionSummaryReferenceLengths()
}

try? FileManager.default.removeItem(at: stagingRoot)
```

Do not fetch references inside per-sample stage imports.

- [ ] **Step 4: Run the focused tests and one CLI smoke test**

Run:

```bash
swift test --filter NaoMgsImportOptimizationTests
./.build/debug/lungfish-cli import nao-mgs Tests/Fixtures/naomgs/virus_hits_final.tsv.gz --output-dir /tmp/naomgs_plan_smoke --no-fetch-references
```

Expected:

```text
All selected tests pass
NAO-MGS import complete
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "feat: fetch NAO-MGS references after merged assembly"
```

## Self-Review

- Spec coverage:
  - directory input with one sample split across multiple TSVs: covered in Task 1 and Task 4
  - sequential per-sample imports: covered in Task 4
  - single final bundle: covered in Task 3 and Task 4
  - post-merge reference fetch: covered in Task 5
  - cleanup and failure behavior: covered in Task 5
- Placeholder scan:
  - no `TODO`/`TBD` placeholders remain
  - code-touching steps include concrete file paths and code skeletons
- Type consistency:
  - `NaoMgsSamplePartitioner`
  - `NaoMgsPartitionResult`
  - `NaoMgsStageDatabaseInput`
  - `createMergedSummaryDatabase(...)`
  - `importNaoMgsSingleSampleStage(...)`

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-12-naomgs-sample-partition-import.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
