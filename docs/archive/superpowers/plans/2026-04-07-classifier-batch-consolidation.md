# Classifier Batch Consolidation & Critical Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate EsViritu and TaxTriage display to batch-only (single-sample becomes a filter of batch view), fix all 5 critical findings from adversarial code review, and make Kraken2 single-sample build-db work for root-layout results.

**Architecture:** (1) EsViritu/TaxTriage pipelines always write batch-style layouts (even for single sample runs, result dir contains per-sample subdirs). (2) Sidebar batch child items set the picker state and display the batch view filtered to a single sample — no separate single-sample display path. (3) EsViritu BAM paths stored as full relative paths from result root (`<sample>/<sample>_temp/<sample>.third.filt.sorted.bam`). (4) EsViritu cleanup moves BAMs to persistent `bams/` directory before deleting `_temp/`. (5) Router walks up one level when given a per-sample subdir. (6) `updateUniqueReadsInDB` takes an explicit `updateAccessionLength: Bool` parameter so EsViritu (which stores `contig_length` at parse time) opts out. (7) Kraken2 single-sample build-db handles root-level kreport files in addition to subdirectory layouts.

**Tech Stack:** Swift 6.2, raw sqlite3 C API, ArgumentParser CLI, AppKit VCs, samtools

**Spec:** `docs/superpowers/specs/2026-04-07-sqlite-backed-classifier-views-design.md`

**Predecessor plan:** `docs/superpowers/plans/2026-04-07-db-only-classifier-views.md`

---

## File Map

### Modified Files — CLI
- `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — 6 changes:
  - EsViritu: store full relative BAM path (include sample prefix)
  - EsViritu: move BAMs to `bams/` dir before cleanup deletes `_temp/`
  - EsViritu: `updateUniqueReadsInDB` call passes `updateAccessionLength: false`
  - EsViritu: bamPathResolver stops pre-pending sample (path already contains it)
  - Kraken2: support root-level kreport fallback for single-sample layouts
  - Generic: `updateUniqueReadsInDB` gains `updateAccessionLength: Bool` parameter

### Modified Files — App Pipeline
- `Sources/LungfishApp/App/AppDelegate.swift` — 2 changes:
  - `runEsViritu` writes to batch-style layout (single sample in a subdir)
  - `runTaxTriage` writes to batch-style layout (single sample in a subdir)

### Modified Files — Sidebar + Routing
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` — attach `sampleId` to batch child sidebar items for filter-to-one routing; generalize TaxTriage batch handling (treat any `taxtriage-*` as a batch).
- `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift` — when `route(for:)` returns nil, try walking up one level and returning route for the parent classifier directory.
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` — when routing a batch child (sample subdir), display the parent batch view and set sample picker state to only that sample.

### Modified Files — VC
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` — delete `configure(result:)` single-sample path and all its helpers; VC now only supports DB-backed batch mode.
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` — delete `configure(result:config:)` single-sample path and all its helpers.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift` — delete `displayEsVirituResult(_:config:)`.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift` — delete `displayTaxTriageResult(_:config:sampleId:)`.

### New Tests
- `Tests/LungfishCLITests/BuildDbCommandKraken2SingleSampleTests.swift` — Kraken2 root-layout parsing
- `Tests/LungfishCLITests/BuildDbCommandEsVirituPathTests.swift` — EsViritu stores full relative BAM path
- `Tests/LungfishCLITests/BuildDbCommandEsVirituCleanupTests.swift` — cleanup preserves BAMs
- `Tests/LungfishAppTests/ClassifierDatabaseRouterParentWalkTests.swift` — router walks up one level
- `Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift` — extend existing file with batch-child test

---

## Task Order & Rationale

Tasks are ordered so each layer's dependencies are in place before it's touched:
1. **CLI schema/parse fixes first** — tests are pure and fast
2. **Router update** — small isolated change
3. **Pipeline changes** — ensures future runs have correct layout
4. **Sidebar + routing** — wires the new picker-filter flow
5. **VC legacy removal** — delete code after nothing calls it

---

## Task 1: CLI — Kraken2 Root-Layout Single-Sample Support

Add fallback to parse a root-level `*.kreport` when no sample subdirs contain `classification.kreport`. Kraken2 retains its single-sample view (per user direction) so this must work.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — `parseSampleDirectories` in Kraken2 subcommand
- Create: `Tests/LungfishCLITests/BuildDbCommandKraken2SingleSampleTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LungfishCLITests/BuildDbCommandKraken2SingleSampleTests.swift
import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandKraken2SingleSampleTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("K2SingleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Root-layout kreport (no subdirs) — build-db must still produce rows.
    func testKraken2RootLayoutSingleSample() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resultDir = tmpDir.appendingPathComponent("kraken2-2026-01-15T11-00-00")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        // Minimal 3-line kreport (root + 2 taxa) — tab-separated
        let kreport = """
         50.00\t500\t100\tR\t1\troot
         40.00\t400\t200\tD\t2\t  Bacteria
         20.00\t200\t200\tS\t562\t    Escherichia coli
        """
        let kreportURL = resultDir.appendingPathComponent("reads.kreport")
        try kreport.write(to: kreportURL, atomically: true, encoding: .utf8)

        // Run build-db
        var cmd = try BuildDbCommand.Kraken2Subcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // Verify DB was created with non-zero rows
        let dbURL = resultDir.appendingPathComponent("kraken2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let db = try Kraken2Database(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 1, "Should produce exactly 1 sample from root-level kreport")
        XCTAssertGreaterThan(samples[0].taxonCount, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuildDbCommandKraken2SingleSampleTests`
Expected: FAIL — `build-db kraken2` produces 0 rows because `parseSampleDirectories` only scans subdirs.

- [ ] **Step 3: Add root-layout fallback to Kraken2 parseSampleDirectories**

In `Sources/LungfishCLI/Commands/BuildDbCommand.swift`, find `parseSampleDirectories` inside `Kraken2Subcommand` (around line 1307). Replace the method body:

```swift
func parseSampleDirectories(
    resultURL: URL
) throws -> (rows: [Kraken2ClassificationRow], sampleMetadata: [String: String]) {
    let fm = FileManager.default
    let contents = try fm.contentsOfDirectory(
        at: resultURL,
        includingPropertiesForKeys: [.isDirectoryKey]
    )

    var allRows: [Kraken2ClassificationRow] = []
    var sampleMetadata: [String: String] = [:]

    // First pass: batch layout — sample subdirectories containing classification.kreport
    var foundSubdirKreports = false
    for dir in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }

        let sampleId = dir.lastPathComponent
        guard !sampleId.hasPrefix(".") else { continue }

        let kreportURL = dir.appendingPathComponent("classification.kreport")
        guard fm.fileExists(atPath: kreportURL.path) else { continue }

        foundSubdirKreports = true
        let (rows, tree) = try parseKreport(at: kreportURL, sampleId: sampleId)
        allRows.append(contentsOf: rows)
        sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
        sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
        sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"
    }

    if foundSubdirKreports {
        return (allRows, sampleMetadata)
    }

    // Fallback: single-sample root layout — look for any *.kreport at resultURL
    let rootKreports = contents
        .filter { $0.pathExtension == "kreport" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard let kreportURL = rootKreports.first else {
        return ([], [:])
    }

    // Derive sample ID from kreport filename (drop .kreport extension)
    let sampleId = kreportURL.deletingPathExtension().lastPathComponent
    let (rows, tree) = try parseKreport(at: kreportURL, sampleId: sampleId)
    allRows.append(contentsOf: rows)
    sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
    sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
    sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"

    return (allRows, sampleMetadata)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BuildDbCommandKraken2SingleSampleTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishCLITests/BuildDbCommandKraken2SingleSampleTests.swift
git commit -m "feat: Kraken2 build-db supports root-layout single-sample kreports"
```

---

## Task 2: CLI — EsViritu Stores Full Relative BAM Path

Fix EsViritu to store `<sample>/<sample>_temp/<sample>.third.filt.sorted.bam` (full relative from result root) instead of `<sample>_temp/...` (relative from sample dir). This makes path resolution consistent with TaxTriage and matches the VC's expectation.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — EsViritu `parseDetectionTSV` bam path construction + `bamPathResolver` in `run`
- Create: `Tests/LungfishCLITests/BuildDbCommandEsVirituPathTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LungfishCLITests/BuildDbCommandEsVirituPathTests.swift
import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandEsVirituPathTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVPathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stored bam_path should include sample prefix so VC can resolve it
    /// directly against the result directory (same convention as TaxTriage).
    func testEsVirituBamPathIncludesSamplePrefix() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resultDir = tmpDir.appendingPathComponent("esviritu-batch-2026-01-15T15-00-00")
        let sampleDir = resultDir.appendingPathComponent("sample1")
        let tempDir = sampleDir.appendingPathComponent("sample1_temp")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Minimal BAM placeholder (content doesn't matter for path test)
        let bamURL = tempDir.appendingPathComponent("sample1.third.filt.sorted.bam")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data())

        // Minimal detection TSV with 1 row
        let header = "sample_ID\tname\tdescription\tlength\tsegment\taccession\tassembly\tassembly_length\tkingdom\tphylum\tclass\torder\tfamily\tgenus\tspecies\tsubspecies\trpkmf\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tpi\tfiltered_reads_in_sample"
        let row = "sample1\tVirusA\tdesc\t100\t\tNC_001\tGCA_001\t1000\tVirK\tVirP\tVirC\tVirO\tVirF\tVirG\tVirS\t\t1.0\t10\t50\t2.5\t99.0\t0.01\t1000"
        try "\(header)\n\(row)".write(
            to: sampleDir.appendingPathComponent("sample1.detected_virus.info.tsv"),
            atomically: true, encoding: .utf8)

        // Run build-db with --no-cleanup so BAM is preserved for inspection
        var cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "--no-cleanup", "-q"])
        try await cmd.run()

        let dbURL = resultDir.appendingPathComponent("esviritu.sqlite")
        let db = try EsVirituDatabase(at: dbURL)
        let rows = try db.fetchRows(samples: ["sample1"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows[0].bamPath,
            "sample1/sample1_temp/sample1.third.filt.sorted.bam",
            "bam_path must include sample prefix"
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuildDbCommandEsVirituPathTests`
Expected: FAIL — `bamPath` is `"sample1_temp/sample1.third.filt.sorted.bam"` (no sample prefix).

- [ ] **Step 3: Change EsViritu parseDetectionTSV to store full relative path**

In `Sources/LungfishCLI/Commands/BuildDbCommand.swift`, find the EsViritu `parseDetectionTSV` helper (search for `let bamRelative = "\(sampleName)_temp/`). Change the bamRelative construction:

```swift
// Before:
let bamRelative = "\(sampleName)_temp/\(sampleName).third.filt.sorted.bam"

// After (full relative from result root):
let bamRelative = "\(sampleName)/\(sampleName)_temp/\(sampleName).third.filt.sorted.bam"
```

Also update the `.bai`/`.csi` suffix stored in `bamIndexPath` — the existing code appends `.bai` or `.csi` to `bamRelative`, which is now already the full path, so no further change needed there.

- [ ] **Step 4: Update EsViritu bamPathResolver closure**

Still in the EsViritu subcommand `run()`, find `updateUniqueReadsInDB(... bamPathResolver: ...)`. The current closure appends the sample name; since the path now already includes it, simplify:

```swift
// Before:
bamPathResolver: { resultURL, sample, bamRelPath in
    // EsViritu BAM paths are relative to the sample subdirectory
    resultURL.appendingPathComponent(sample).appendingPathComponent(bamRelPath).path
},

// After:
bamPathResolver: { resultURL, _, bamRelPath in
    // EsViritu BAM paths are relative to the result directory root
    resultURL.appendingPathComponent(bamRelPath).path
},
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter BuildDbCommandEsVirituPathTests`
Expected: PASS

- [ ] **Step 6: Run existing tests to ensure nothing else broke**

Run: `swift test --filter BuildDbCommand`
Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishCLITests/BuildDbCommandEsVirituPathTests.swift
git commit -m "fix: EsViritu build-db stores full relative BAM path from result root"
```

---

## Task 3: CLI — EsViritu Preserves BAMs Across Cleanup

Move BAMs from `<sample>/<sample>_temp/` into `<sample>/bams/` before cleanup deletes `_temp/`. Update the stored `bamPath`/`bamIndexPath` to reflect the new location. This ensures re-running `build-db` after cleanup still finds BAMs, and the GUI-triggered auto-build works end-to-end.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — EsViritu `run()` and `parseDetectionTSV`
- Create: `Tests/LungfishCLITests/BuildDbCommandEsVirituCleanupTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LungfishCLITests/BuildDbCommandEsVirituCleanupTests.swift
import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandEsVirituCleanupTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// After build-db runs cleanup, the BAM referenced by the DB must still exist on disk.
    func testEsVirituBamPreservedAfterCleanup() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resultDir = tmpDir.appendingPathComponent("esviritu-batch-2026-01-15T15-00-00")
        let sampleDir = resultDir.appendingPathComponent("sample1")
        let tempDir = sampleDir.appendingPathComponent("sample1_temp")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Put a placeholder BAM + index in _temp (build-db doesn't parse the BAM)
        let bamURL = tempDir.appendingPathComponent("sample1.third.filt.sorted.bam")
        let baiURL = tempDir.appendingPathComponent("sample1.third.filt.sorted.bam.bai")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data("BAM".utf8))
        FileManager.default.createFile(atPath: baiURL.path, contents: Data("BAI".utf8))

        // Minimal detection TSV
        let header = "sample_ID\tname\tdescription\tlength\tsegment\taccession\tassembly\tassembly_length\tkingdom\tphylum\tclass\torder\tfamily\tgenus\tspecies\tsubspecies\trpkmf\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tpi\tfiltered_reads_in_sample"
        let row = "sample1\tVirusA\tdesc\t100\t\tNC_001\tGCA_001\t1000\tVirK\tVirP\tVirC\tVirO\tVirF\tVirG\tVirS\t\t1.0\t10\t50\t2.5\t99.0\t0.01\t1000"
        try "\(header)\n\(row)".write(
            to: sampleDir.appendingPathComponent("sample1.detected_virus.info.tsv"),
            atomically: true, encoding: .utf8)

        // Run with default cleanup enabled
        var cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // _temp/ should be gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path),
                       "_temp/ should be removed by cleanup")

        // The stored bam_path from the DB should still point to a file that exists
        let db = try EsVirituDatabase(at: resultDir.appendingPathComponent("esviritu.sqlite"))
        let rows = try db.fetchRows(samples: ["sample1"])
        XCTAssertEqual(rows.count, 1)
        let storedBam = rows[0].bamPath!
        let absolute = resultDir.appendingPathComponent(storedBam).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute),
                      "BAM at stored path must exist after cleanup: \(absolute)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuildDbCommandEsVirituCleanupTests`
Expected: FAIL — cleanup removes `_temp/` including the BAM, stored path points to deleted file.

- [ ] **Step 3: Update EsViritu `parseDetectionTSV` to target the `bams/` location**

In `Sources/LungfishCLI/Commands/BuildDbCommand.swift`, change the bamRelative construction again (Task 2 set it to `sample1/sample1_temp/...`; now make it `sample1/bams/...`):

```swift
// Resolve BAM path in persistent `bams/` location
let bamBasename = "\(sampleName).third.filt.sorted.bam"
let bamRelative = "\(sampleName)/bams/\(bamBasename)"

// BAM may still be in _temp/ at parse time — we relocate it below if present
let tempBamURL = sampleDir.appendingPathComponent("\(sampleName)_temp")
    .appendingPathComponent(bamBasename)
let persistentBamURL = sampleDir.appendingPathComponent("bams")
    .appendingPathComponent(bamBasename)

var bamPath: String?
var bamIndexPath: String?
if FileManager.default.fileExists(atPath: tempBamURL.path)
    || FileManager.default.fileExists(atPath: persistentBamURL.path) {
    bamPath = bamRelative
    // Index: prefer .bai then .csi, check either temp or persistent location
    for ext in [".bai", ".csi"] {
        let tempIdxURL = URL(fileURLWithPath: tempBamURL.path + ext)
        let persistentIdxURL = URL(fileURLWithPath: persistentBamURL.path + ext)
        if FileManager.default.fileExists(atPath: tempIdxURL.path)
            || FileManager.default.fileExists(atPath: persistentIdxURL.path) {
            bamIndexPath = bamRelative + ext
            break
        }
    }
}
```

- [ ] **Step 4: Add a BAM relocation step in EsViritu run() before cleanup**

In `EsVirituSubcommand.run()`, after `updateUniqueReadsInDB(...)` returns and before `performCleanup(...)`, add:

```swift
// Relocate BAMs from <sample>/<sample>_temp/ to <sample>/bams/ so cleanup
// can remove _temp/ without deleting files referenced by the DB.
relocateEsVirituBAMs(resultURL: resultURL)
```

Add the new method inside the EsViritu subcommand struct:

```swift
/// Moves `*.third.filt.sorted.bam{,.bai,.csi}` from each sample's `_temp/`
/// directory into a sibling `bams/` directory so post-build cleanup can
/// remove `_temp/` without breaking DB-referenced BAM paths.
private func relocateEsVirituBAMs(resultURL: URL) {
    let fm = FileManager.default
    guard let sampleDirs = try? fm.contentsOfDirectory(
        at: resultURL, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return }

    for sampleDir in sampleDirs {
        let isDir = (try? sampleDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }
        let sampleName = sampleDir.lastPathComponent
        guard !sampleName.hasPrefix(".") else { continue }

        let tempDir = sampleDir.appendingPathComponent("\(sampleName)_temp")
        let bamsDir = sampleDir.appendingPathComponent("bams")
        guard fm.fileExists(atPath: tempDir.path) else { continue }

        let bamBasename = "\(sampleName).third.filt.sorted.bam"
        let sourceURLs = [
            tempDir.appendingPathComponent(bamBasename),
            tempDir.appendingPathComponent(bamBasename + ".bai"),
            tempDir.appendingPathComponent(bamBasename + ".csi"),
        ]

        // Only create bams/ if we have something to move
        let movable = sourceURLs.filter { fm.fileExists(atPath: $0.path) }
        guard !movable.isEmpty else { continue }
        try? fm.createDirectory(at: bamsDir, withIntermediateDirectories: true)

        for source in movable {
            let dest = bamsDir.appendingPathComponent(source.lastPathComponent)
            // If destination already exists (re-run), skip
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.moveItem(at: source, to: dest)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter BuildDbCommandEsVirituCleanupTests`
Expected: PASS

Run: `swift test --filter BuildDbCommandEsVirituPathTests`
Expected: FAIL — the path test from Task 2 now expects `sample1/sample1_temp/...` but the new code stores `sample1/bams/...`. Update that test's expected string:

```swift
XCTAssertEqual(
    rows[0].bamPath,
    "sample1/bams/sample1.third.filt.sorted.bam",
    "bam_path must include sample prefix and resolve to persistent bams/ dir"
)
```

Re-run: `swift test --filter BuildDbCommandEsVirituPathTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishCLITests/BuildDbCommandEsVirituCleanupTests.swift \
      Tests/LungfishCLITests/BuildDbCommandEsVirituPathTests.swift
git commit -m "fix: EsViritu build-db relocates BAMs to bams/ so cleanup preserves them"
```

---

## Task 4: CLI — `updateUniqueReadsInDB` Gains `updateAccessionLength` Parameter

`detection_rows` table has no `accession_length` column. The current code attempts `UPDATE detection_rows SET accession_length = ...` which silently fails to prepare. Make the accession-length update opt-in per table.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — `updateUniqueReadsInDB` signature + callers

- [ ] **Step 1: Add parameter to `updateUniqueReadsInDB`**

In `Sources/LungfishCLI/Commands/BuildDbCommand.swift`, find `private func updateUniqueReadsInDB`. Add `updateAccessionLength: Bool` parameter:

```swift
private func updateUniqueReadsInDB(
    dbPath: String,
    table: String,
    sampleCol: String,
    accessionCol: String,
    bamPathCol: String,
    resultURL: URL,
    bamPathResolver: (URL, String, String) -> String,
    updateAccessionLength: Bool,
    quiet: Bool
) {
    // ... existing body ...
```

- [ ] **Step 2: Gate the accession_length block**

Wrap the existing accession_length update block with the new flag:

```swift
// Update accession_length column for rows that have a primary_accession
if updateAccessionLength && !refLengths.isEmpty {
    let lenSQL = "UPDATE \(table) SET accession_length = ? WHERE rowid = ?"
    // ... existing prepare/bind/step logic unchanged ...
}
```

- [ ] **Step 3: Update TaxTriage caller (passes `updateAccessionLength: true`)**

In `TaxTriageSubcommand.run()`, update the call:

```swift
updateUniqueReadsInDB(
    dbPath: dbURL.path,
    table: "taxonomy_rows",
    sampleCol: "sample",
    accessionCol: "primary_accession",
    bamPathCol: "bam_path",
    resultURL: resultURL,
    bamPathResolver: { resultURL, _, bamRelPath in
        resultURL.appendingPathComponent(bamRelPath).path
    },
    updateAccessionLength: true,
    quiet: globalOptions.quiet
)
```

- [ ] **Step 4: Update EsViritu caller (passes `updateAccessionLength: false`)**

In `EsVirituSubcommand.run()`, update the call. Note the closure was changed in Task 2 to not prepend sample:

```swift
updateUniqueReadsInDB(
    dbPath: dbURL.path,
    table: "detection_rows",
    sampleCol: "sample",
    accessionCol: "accession",
    bamPathCol: "bam_path",
    resultURL: resultURL,
    bamPathResolver: { resultURL, _, bamRelPath in
        resultURL.appendingPathComponent(bamRelPath).path
    },
    updateAccessionLength: false,
    quiet: globalOptions.quiet
)
```

- [ ] **Step 5: Build and run existing tests**

Run: `swift build --build-tests 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test --filter BuildDbCommand`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/BuildDbCommand.swift
git commit -m "fix: gate accession_length update by updateAccessionLength flag (EsViritu opts out)"
```

---

## Task 5: App Pipeline — EsViritu Single-Sample Writes Batch Layout

Change `runEsViritu` to create a batch-style result directory (`esviritu-batch-<timestamp>/<sampleName>/`) even for a single sample, so there's only one display path.

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift` — `runEsViritu` around line 5174

- [ ] **Step 1: Update runEsViritu to create batch-style layout**

Find `runEsViritu(config:viewerController:)`. Replace the analysis-directory creation block:

```swift
// Before:
if let projectURL = mainWindowController?.mainSplitViewController?.sidebarController?.currentProjectURL {
    if let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: "esviritu", in: projectURL) {
        config.outputDirectory = analysisDir
    }
}

// After:
if let projectURL = mainWindowController?.mainSplitViewController?.sidebarController?.currentProjectURL {
    if let batchDir = try? AnalysesFolder.createAnalysisDirectory(
        tool: "esviritu", in: projectURL, isBatch: true
    ) {
        let sampleSubdir = batchDir.appendingPathComponent(config.sampleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
        config.outputDirectory = sampleSubdir
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift
git commit -m "feat: runEsViritu writes batch-style layout for consistent display path"
```

---

## Task 6: App Pipeline — TaxTriage Single-Sample Writes Batch Layout

Same change for TaxTriage. TaxTriage pipeline internally writes to sample subdirectories even for single-sample runs, but the top-level dir name is `taxtriage-<timestamp>` not `taxtriage-batch-<timestamp>`. Rename to match the batch convention so `AnalysesFolder.isBatch` returns true.

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift` — `runTaxTriage` around line 5851

- [ ] **Step 1: Update runTaxTriage to create batch-style layout**

Find `runTaxTriage(config:viewerController:)`. Replace the analysis-directory creation:

```swift
// Before:
if let projectURL = mainWindowController?.mainSplitViewController?.sidebarController?.currentProjectURL {
    if let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: "taxtriage", in: projectURL) {
        config.outputDirectory = analysisDir
    }
}

// After:
if let projectURL = mainWindowController?.mainSplitViewController?.sidebarController?.currentProjectURL {
    if let batchDir = try? AnalysesFolder.createAnalysisDirectory(
        tool: "taxtriage", in: projectURL, isBatch: true
    ) {
        config.outputDirectory = batchDir
    }
}
```

Note: TaxTriage's underlying pipeline writes its own internal sample structure under `outputDirectory`, so we don't need to create a sample subdirectory ourselves.

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift
git commit -m "feat: runTaxTriage writes to taxtriage-batch-* directory for consistent layout"
```

---

## Task 7: Router — Parent-Walk for Batch Child Subdirectories

`ClassifierDatabaseRouter.route(for:)` currently returns nil when given a sample subdirectory like `<batch-root>/SRR35517702/`. Add a fallback: if the direct match returns nil AND the parent directory matches, return the parent's route (with an extra `sampleId` field identifying the child).

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift`
- Modify: `Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift` — add tests

- [ ] **Step 1: Write failing test for parent walk**

Append to `Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift`:

```swift
// MARK: - Parent walk (batch child subdirs)

func testRoute_batchChildResolvesToParentBatch() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let batchDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
    let sampleDir = batchDir.appendingPathComponent("SRR35517702")
    try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: batchDir.appendingPathComponent("esviritu.sqlite").path,
        contents: Data())

    let route = ClassifierDatabaseRouter.route(for: sampleDir)
    XCTAssertNotNil(route)
    XCTAssertEqual(route?.tool, "esviritu")
    XCTAssertEqual(route?.sampleId, "SRR35517702")
    XCTAssertNotNil(route?.databaseURL)
    XCTAssertEqual(route?.databaseURL?.path, batchDir.appendingPathComponent("esviritu.sqlite").path)
}

func testRoute_topLevelHasNoSampleId() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let batchDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
    try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: batchDir.appendingPathComponent("esviritu.sqlite").path,
        contents: Data())

    let route = ClassifierDatabaseRouter.route(for: batchDir)
    XCTAssertNotNil(route)
    XCTAssertNil(route?.sampleId, "top-level route should not carry a sampleId")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClassifierDatabaseRoutingTests`
Expected: FAIL — `Route` has no `sampleId` field, and parent walk not implemented.

- [ ] **Step 3: Add sampleId to Route and implement parent walk**

Replace the contents of `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift`:

```swift
import Foundation

/// Centralized routing logic for classifier result directories.
///
/// Determines whether a directory is a classifier result and whether it has
/// a pre-built SQLite database. Handles both top-level result directories and
/// per-sample subdirectories (walks up one level).
enum ClassifierDatabaseRouter {

    /// A routing decision for a classifier result directory.
    struct Route {
        /// Tool identifier used by the CLI (e.g. "taxtriage", "esviritu", "kraken2").
        let tool: String
        /// Human-readable tool name for UI display.
        let displayName: String
        /// URL of the SQLite database file, or `nil` if no DB exists yet.
        let databaseURL: URL?
        /// URL of the top-level classifier result directory (the one matching a tool prefix).
        let resultURL: URL
        /// Optional sample identifier when the input URL pointed at a per-sample subdir.
        let sampleId: String?
    }

    private static let toolDefinitions: [(prefix: String, dbName: String, tool: String, displayName: String)] = [
        ("taxtriage",      "taxtriage.sqlite", "taxtriage", "TaxTriage"),
        ("esviritu",       "esviritu.sqlite",  "esviritu",  "EsViritu"),
        ("kraken2",        "kraken2.sqlite",   "kraken2",   "Kraken2"),
        ("classification", "kraken2.sqlite",   "kraken2",   "Kraken2"),
    ]

    /// Checks whether `url` is a classifier result directory or a per-sample
    /// subdirectory inside one.
    ///
    /// - If `url` matches a tool prefix directly, returns a top-level `Route`
    ///   (`sampleId = nil`).
    /// - If `url`'s parent matches a tool prefix, returns a `Route` with
    ///   `sampleId = url.lastPathComponent` and `resultURL` pointing at the parent.
    /// - Otherwise returns nil.
    static func route(for url: URL) -> Route? {
        if let direct = routeDirect(for: url) {
            return direct
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, parent.lastPathComponent != "" else { return nil }
        if var parentRoute = routeDirect(for: parent) {
            parentRoute = Route(
                tool: parentRoute.tool,
                displayName: parentRoute.displayName,
                databaseURL: parentRoute.databaseURL,
                resultURL: parentRoute.resultURL,
                sampleId: url.lastPathComponent
            )
            return parentRoute
        }
        return nil
    }

    /// Direct match: `url.lastPathComponent` has a known tool prefix.
    private static func routeDirect(for url: URL) -> Route? {
        let dirName = url.lastPathComponent
        for def in toolDefinitions where dirName.hasPrefix(def.prefix) {
            let dbURL = url.appendingPathComponent(def.dbName)
            let exists = FileManager.default.fileExists(atPath: dbURL.path)
            return Route(
                tool: def.tool,
                displayName: def.displayName,
                databaseURL: exists ? dbURL : nil,
                resultURL: url,
                sampleId: nil
            )
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClassifierDatabaseRoutingTests`
Expected: All pass (11 tests: 9 existing + 2 new).

If existing tests fail because they destructure `Route` without the new `resultURL`/`sampleId` fields, update them to ignore those fields (they can use `route?.tool`, `route?.databaseURL` only — Swift structs don't require destructuring all fields).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift \
      Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift
git commit -m "feat: router walks up to parent dir for batch child subdirectories"
```

---

## Task 8: Sidebar — Propagate sampleId via userInfo

Update sidebar batch child item creation to set `userInfo["sampleId"]` so the selection handler can find which sample to filter to.

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` — `buildBatchAnalysisItem` (lines 1268–1316)

- [ ] **Step 1: Add sampleId to EsViritu child items**

In `buildBatchAnalysisItem`, find the EsViritu `case "esviritu":` block. Change the `SidebarItem` init:

```swift
let childItem = SidebarItem(
    title: record.sampleId,
    type: .esvirituResult,
    icon: "e.circle",
    children: [],
    url: resultURL,
    subtitle: esvirituResultTitle(for: resultURL)
)
childItem.userInfo["sampleId"] = record.sampleId
```

Do the same in the filesystem-fallback branch (`buildBatchChildrenFromFilesystem`) — that helper also creates child items. Find its signature and pass the sample name through:

```swift
buildBatchChildrenFromFilesystem(
    info: info, groupItem: groupItem,
    sidecarCheck: EsVirituResult.exists,
    itemType: .esvirituResult,
    icon: "e.circle"
)
```

In `buildBatchChildrenFromFilesystem` itself (find it with grep), after creating the child `SidebarItem`, add:

```swift
childItem.userInfo["sampleId"] = childItem.title
```

(The title is already the sample directory name — same value.)

- [ ] **Step 2: Add sampleId to Kraken2 child items**

In the `case "kraken2":` block, same edit:

```swift
let childItem = SidebarItem(
    title: record.sampleId,
    type: .classificationResult,
    icon: "k.circle",
    children: [],
    url: resultURL,
    subtitle: classificationResultTitle(for: resultURL)
)
childItem.userInfo["sampleId"] = record.sampleId
```

- [ ] **Step 3: Generalize TaxTriage batch handling**

TaxTriage dirs don't currently have a dedicated case in `buildBatchAnalysisItem` — they fall through to `default:`. Add an explicit TaxTriage case that creates per-sample children from subdirectories and sets `sampleId`:

Find the `default:` branch in `buildBatchAnalysisItem`. Add a `case "taxtriage":` branch before it:

```swift
case "taxtriage":
    // TaxTriage always writes sample subdirectories. Create children for each.
    buildBatchChildrenFromFilesystem(
        info: info, groupItem: groupItem,
        sidecarCheck: { _ in true },
        itemType: .taxTriageResult,
        icon: "t.circle"
    )
```

The existing `buildBatchChildrenFromFilesystem` change in Step 1 propagates `sampleId` automatically.

- [ ] **Step 4: Build verification**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "feat: sidebar propagates sampleId on batch child items for filter-to-one routing"
```

---

## Task 9: MainSplitViewController — Batch Child Filters Picker State

When a batch child (sample subdir) is selected, display the parent batch view and then set the sample picker state to contain only that sample. The existing Inspector picker state + filter handler will update the table automatically.

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` — `routeClassifierDisplay` and each VC's state update

- [ ] **Step 1: Update routeClassifierDisplay to handle sampleId**

Find `private func routeClassifierDisplay(url: URL)` in MainSplitViewController. Replace its body:

```swift
/// Routes a classifier result directory through the DB router.
///
/// If the URL is a top-level result → loads batch view.
/// If the URL is a per-sample subdir → loads batch view then filters the picker to that sample.
/// If DB missing → shows auto-build placeholder.
/// If not a classifier → logs and no-ops.
private func routeClassifierDisplay(url: URL) {
    guard let route = ClassifierDatabaseRouter.route(for: url) else {
        logger.warning("routeClassifierDisplay: Not a classifier directory: \(url.lastPathComponent, privacy: .public)")
        return
    }

    if route.databaseURL != nil {
        displayBatchGroup(at: route.resultURL)
        if let sampleId = route.sampleId {
            filterBatchViewToSingleSample(sampleId: sampleId)
        }
    } else {
        showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: route.resultURL)
    }
}

/// After a batch view loads, constrain the sample picker to a single sample.
private func filterBatchViewToSingleSample(sampleId: String) {
    // Try each classifier VC that may be active.
    if let taxTriageVC = viewerController.taxTriageViewController {
        taxTriageVC.samplePickerState?.selectedSamples = [sampleId]
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
        return
    }
    if let esVirituVC = viewerController.esVirituViewController {
        esVirituVC.samplePickerState?.selectedSamples = [sampleId]
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
        return
    }
    if let taxonomyVC = viewerController.taxonomyViewController {
        taxonomyVC.samplePickerState?.selectedSamples = [sampleId]
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
        return
    }
}
```

Note: `Notification.Name.metagenomicsSampleSelectionChanged` already exists — it's the notification the VCs observe to reload when the picker changes. Search for it if you're unsure of the exact name.

- [ ] **Step 2: Verify notification name**

Run: `grep -r "metagenomicsSampleSelectionChanged" Sources/ | head -5`
Expected: At least 3 matches (declaration + observers). If the name differs, update the posts above to match.

- [ ] **Step 3: Build verification**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift
git commit -m "feat: batch child selection filters batch view picker to single sample"
```

---

## Task 10: VC — Delete EsViritu Single-Sample configure(result:)

Per the user's architectural decision, EsViritu has no distinct single-sample view. Delete the legacy file-based `configure(result:)` method and its helpers from the VC. The ViewerViewController extension also loses its `displayEsVirituResult(_:config:)` wrapper (if still present).

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`

- [ ] **Step 1: Find all callers of the legacy EsViritu single-sample display**

Run these greps to catalog what must be updated or removed:

```bash
grep -rn "EsVirituResultViewController" Sources/
grep -rn "displayEsVirituResult" Sources/
grep -rn "\.configure(result:" Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift
```

Expected findings:
- `EsVirituResultViewController.configure(result:)` called from `ViewerViewController+EsViritu.displayEsVirituResult(_:config:)`
- `displayEsVirituResult(_:config:)` called from AppDelegate completion handlers after `runEsViritu` finishes

- [ ] **Step 2: Delete `configure(result:)` and its helpers**

In `EsVirituResultViewController.swift`, delete:
- `public func configure(result: EsVirituResult, ...)` and its body
- Private helpers called only from this method (search for each helper and confirm it has no other callers before deleting)
- `showDetectionDetail` or similar methods that only exist for the single-sample UI path
- The `detectionTableView` if it's only used by single-sample mode (check `isBatchMode` branches)

**Do not delete**: `configureFromDatabase`, `reloadFromDatabase`, `applyBatchSampleFilter`, any property or method used at runtime after configure completes.

After deleting, run `swift build 2>&1 | tail -5` — the compiler will flag any stray references.

- [ ] **Step 3: Delete `displayEsVirituResult(_:config:)` from ViewerViewController+EsViritu.swift**

Find and delete the method `func displayEsVirituResult(_ result: EsVirituResult, config: EsVirituConfig?)`. Keep `displayEsVirituFromDatabase(db:resultURL:)`.

- [ ] **Step 4: Fix AppDelegate callers**

After `runEsViritu` completes, the code likely calls `viewerController.displayEsVirituResult(ioResult, config: pipelineResult.config)`. Replace these calls with a sidebar reload (the user manually clicks the new result after reload, same as SPAdes/minimap2 pipelines):

```swift
// Before:
viewerController.displayEsVirituResult(ioResult, config: pipelineResult.config)

// After:
mainWindowController?.mainSplitViewController?.sidebarController?.reloadFromFilesystem()
```

(`reloadFromFilesystem()` is the same sidebar reload method already used by other pipelines — see existing calls around line 6280 of AppDelegate.swift.)

- [ ] **Step 5: Build verification**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Test verification**

Run: `swift test --filter EsViritu`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift \
      Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift \
      Sources/LungfishApp/App/AppDelegate.swift
git commit -m "refactor: remove EsViritu single-sample display path (batch-only)"
```

---

## Task 11: VC — Delete TaxTriage Single-Sample configure(result:)

Same surgery for TaxTriage.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

- [ ] **Step 1: Find all callers**

```bash
grep -rn "TaxTriageResultViewController" Sources/
grep -rn "displayTaxTriageResult" Sources/
grep -rn "\.configure(result:" Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift
```

- [ ] **Step 2: Delete `configure(result:config:)` and its helpers**

Delete from `TaxTriageResultViewController.swift`:
- `public func configure(result: TaxTriageResult, config: TaxTriageConfig?, sampleId: String?)` and its body
- Single-sample-only helpers: `enableMultiSampleFlatTableMode`, `rebuildSampleFilterSegments`, `buildTableRows(organisms:metrics:)`, etc. — check each for call sites
- `organismTableView` if only used in single-sample mode (keep if still referenced from DB-mode code)
- BLAST wiring that's only reachable from single-sample path

**Do not delete**: `configureFromDatabase`, `reloadFromDatabase`, `applyBatchGroupFilter`, anything used at runtime.

- [ ] **Step 3: Delete `displayTaxTriageResult(_:config:sampleId:)` from ViewerViewController+TaxTriage.swift**

Find and delete the method. Keep `displayTaxTriageFromDatabase(db:resultURL:)`.

- [ ] **Step 4: Fix AppDelegate callers**

Replace post-run calls with sidebar reload (same pattern as Task 10 Step 4).

- [ ] **Step 5: Build verification**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Test verification**

Run: `swift test --filter TaxTriage`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift \
      Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift \
      Sources/LungfishApp/App/AppDelegate.swift
git commit -m "refactor: remove TaxTriage single-sample display path (batch-only)"
```

---

## Task 12: Rebuild Real Databases and Manual Verification

After the code changes, rebuild the real-data databases and verify end-to-end behavior.

**No file changes.**

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with NNN tests passed`

- [ ] **Step 2: Rebuild real databases**

First regenerate BAMs for EsViritu by re-running the EsViritu pipeline on at least one sample (because current real data has cleaned-up BAMs). OR if that's impractical, skip EsViritu rebuild and test with TaxTriage which still has BAMs.

```bash
.build/debug/lungfish-cli build-db taxtriage \
    "/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18" \
    --force
```

Expected output includes:
- `Updated accession lengths for NNNN organisms`
- `Updated unique reads for NNNN/MMMM organisms`
- SARS-CoV-2 in SRR35520576 should show ~88K unique reads (single-end dedup, position+strand)

- [ ] **Step 3: Verify DB content**

```bash
sqlite3 /Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18/taxtriage.sqlite \
  "SELECT sample, organism, reads_aligned, unique_reads, accession_length FROM taxonomy_rows WHERE sample='SRR35520576' AND organism LIKE '%Severe acute%'"
```

Expected: unique_reads is in the tens of thousands (not 600K), accession_length is 29903.

- [ ] **Step 4: Manual GUI test**

Launch the app, and for each scenario verify:
1. Click TaxTriage top-level → loads batch view, shows 149 samples in picker
2. Click a sample child under TaxTriage → loads batch view filtered to that one sample
3. Click an organism in the TaxTriage flat table → miniBAM pane displays reads aligned to that accession
4. Kraken2 batch → same flow; single-sample child filters picker
5. Open a single-sample Kraken2 result from a root-layout fixture (use `Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/`) → build-db CLI succeeds and the view loads

- [ ] **Step 5: Final verification commit**

```bash
git commit --allow-empty -m "verify: manual testing of batch-only classifier views complete"
```
