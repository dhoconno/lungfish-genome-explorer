# SQLite-Backed Classifier Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace JSON manifests with SQLite databases for TaxTriage, EsViritu, and Kraken2 batch/multi-sample views, built by CLI with post-build cleanup, providing instant loading and correct unique reads.

**Architecture:** Each tool gets a Database class (raw sqlite3 C API, following NvdDatabase/NaoMgsDatabase patterns), a CLI `build-db` subcommand (ArgumentParser, JSON event progress), and a VC `configureFromDatabase()` method. The app checks for the `.sqlite` file on open — if missing, shows a placeholder and runs the CLI build as a background subprocess via the Operations Panel. Post-build cleanup removes intermediate pipeline files.

**Tech Stack:** Swift 6.2, raw sqlite3 C API (import SQLite3), ArgumentParser CLI, AppKit VCs, samtools for BAM dedup

**Spec:** `docs/superpowers/specs/2026-04-07-sqlite-backed-classifier-views-design.md`

**Decomposition:** This plan covers all three tools in sequence. Each tool's tasks (Database → CLI → VC → Cleanup) are independent and can be implemented in any order, but the recommended order is TaxTriage → EsViritu → Kraken2 (decreasing complexity).

---

## File Map

### New Files
- `Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift` — SQLite database class
- `Sources/LungfishIO/Formats/EsViritu/EsVirituDatabase.swift` — SQLite database class
- `Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift` — SQLite database class
- `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — CLI `build-db` command with taxtriage/esviritu/kraken2 subcommands
- `Sources/LungfishApp/Views/Metagenomics/DatabaseBuildPlaceholderView.swift` — Placeholder viewport shown during DB build
- `Tests/LungfishIOTests/TaxTriageDatabaseTests.swift` — Database unit tests
- `Tests/LungfishIOTests/EsVirituDatabaseTests.swift` — Database unit tests
- `Tests/LungfishIOTests/Kraken2DatabaseTests.swift` — Database unit tests
- `Tests/LungfishCLITests/BuildDbCommandTests.swift` — CLI integration tests
- `Tests/Fixtures/taxtriage-mini/` — Test fixtures (3 samples)
- `Tests/Fixtures/esviritu-mini/` — Test fixtures (3 samples)
- `Tests/Fixtures/kraken2-mini/` — Test fixtures (3 samples)

### Modified Files
- `Sources/LungfishCLI/LungfishCLI.swift` — Register `BuildDbCommand`
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` — Route to DB-backed display
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` — Add `configureFromDatabase()`
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` — Add `configureFromDatabase()`
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` — Add `configureFromDatabase()`
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift` — DB-aware display method
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift` — DB-aware display method
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` — DB-aware display method

---

## Phase 1: Test Fixtures

### Task 1: Create Test Fixtures from Real Data

Extract minimal test data from the existing TaxTriage, EsViritu, and Kraken2 results. These fixtures are committed to the repo and used by all subsequent tests.

**Files:**
- Create: `Tests/Fixtures/taxtriage-mini/` directory structure
- Create: `Tests/Fixtures/esviritu-mini/` directory structure
- Create: `Tests/Fixtures/kraken2-mini/` directory structure

- [ ] **Step 1: Create TaxTriage mini fixture**

Create a minimal TaxTriage result directory with 3 samples. Extract from `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18/`:

```bash
FIXTURE_DIR="Tests/Fixtures/taxtriage-mini"
mkdir -p "$FIXTURE_DIR/report/multiqc_data"
mkdir -p "$FIXTURE_DIR/combine"
mkdir -p "$FIXTURE_DIR/minimap2"

# Extract first 3 samples + header from confidence file
SAMPLES="SRR35517702|SRR35517703|SRR35517705"
SRC="/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18"

# Confidence TSV (header + 3 samples' rows)
head -1 "$SRC/report/multiqc_data/multiqc_confidences.txt" > "$FIXTURE_DIR/report/multiqc_data/multiqc_confidences.txt"
grep -E "$SAMPLES" "$SRC/report/multiqc_data/multiqc_confidences.txt" >> "$FIXTURE_DIR/report/multiqc_data/multiqc_confidences.txt"

# Per-sample gcfmap files
for S in SRR35517702 SRR35517703 SRR35517705; do
    cp "$SRC/combine/$S.combined.gcfmap.tsv" "$FIXTURE_DIR/combine/" 2>/dev/null || true
done

# Minimal BAMs — extract just 2 contigs per sample to keep small
for S in SRR35517702 SRR35517703 SRR35517705; do
    BAM="$SRC/minimap2/$S.$S.dwnld.references.bam"
    if [ -f "$BAM" ]; then
        # Get first 2 reference names from the BAM
        REFS=$(samtools idxstats "$BAM" 2>/dev/null | head -2 | cut -f1 | tr '\n' ' ')
        samtools view -h -o "$FIXTURE_DIR/minimap2/$S.$S.dwnld.references.bam" "$BAM" $REFS 2>/dev/null
        samtools index "$FIXTURE_DIR/minimap2/$S.$S.dwnld.references.bam" 2>/dev/null
    fi
done
```

Verify the fixture: `wc -l "$FIXTURE_DIR/report/multiqc_data/multiqc_confidences.txt"` should show header + sample rows.

- [ ] **Step 2: Create EsViritu mini fixture**

```bash
FIXTURE_DIR="Tests/Fixtures/esviritu-mini"
SRC="/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/esviritu-batch-2026-04-06T20-46-01"

for S in SRR35517702 SRR35517703 SRR35517705; do
    mkdir -p "$FIXTURE_DIR/$S/${S}_temp"
    # Detection TSV
    cp "$SRC/$S/$S.detected_virus.info.tsv" "$FIXTURE_DIR/$S/" 2>/dev/null || true
    # Coverage windows
    cp "$SRC/$S/$S.virus_coverage_windows.tsv" "$FIXTURE_DIR/$S/" 2>/dev/null || true
    # Assembly summary
    cp "$SRC/$S/$S.detected_virus.assembly_summary.tsv" "$FIXTURE_DIR/$S/" 2>/dev/null || true
    # Minimal BAM — first 2 contigs only
    BAM="$SRC/$S/${S}_temp/$S.third.filt.sorted.bam"
    if [ -f "$BAM" ]; then
        REFS=$(samtools idxstats "$BAM" 2>/dev/null | head -2 | cut -f1 | tr '\n' ' ')
        samtools view -h -o "$FIXTURE_DIR/$S/${S}_temp/$S.third.filt.sorted.bam" "$BAM" $REFS 2>/dev/null
        samtools index "$FIXTURE_DIR/$S/${S}_temp/$S.third.filt.sorted.bam" 2>/dev/null
    fi
done
```

- [ ] **Step 3: Create Kraken2 mini fixture**

```bash
FIXTURE_DIR="Tests/Fixtures/kraken2-mini"
SRC="/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/kraken2-batch-2026-04-06T20-45-49"

for S in SRR35517702 SRR35517703 SRR35517705; do
    mkdir -p "$FIXTURE_DIR/$S"
    # Kreport file (small, ~272KB)
    cp "$SRC/$S/classification.kreport" "$FIXTURE_DIR/$S/" 2>/dev/null || true
    # Result sidecar
    cp "$SRC/$S/classification-result.json" "$FIXTURE_DIR/$S/" 2>/dev/null || true
done
```

- [ ] **Step 4: Verify fixtures and commit**

```bash
# Verify sizes are reasonable (< 5MB total per fixture set)
du -sh Tests/Fixtures/taxtriage-mini/ Tests/Fixtures/esviritu-mini/ Tests/Fixtures/kraken2-mini/

git add Tests/Fixtures/taxtriage-mini/ Tests/Fixtures/esviritu-mini/ Tests/Fixtures/kraken2-mini/
git commit -m "test: add mini test fixtures for TaxTriage, EsViritu, and Kraken2 SQLite tests"
```

---

## Phase 2: TaxTriage SQLite

### Task 2: TaxTriageDatabase — Schema and CRUD

**Files:**
- Create: `Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift`
- Create: `Tests/LungfishIOTests/TaxTriageDatabaseTests.swift`

- [ ] **Step 1: Write the database class with schema creation**

Create `TaxTriageDatabase` following the `NvdDatabase` pattern exactly. Key details:
- Use raw `import SQLite3` (NOT a library)
- Class: `public final class TaxTriageDatabase: @unchecked Sendable`
- Thread-safe text binding: use `withCString` + `SQLITE_TRANSIENT` destructor pattern (copy from NvdDatabase)
- Schema matches the spec's `taxonomy_rows` table + `metadata` table
- `create(at:rows:metadata:progress:)` static method: deletes existing, creates schema, bulk inserts in transaction, creates indices, reports progress
- `init(at:)` opens existing DB read-only
- `fetchRows(samples:)` returns `[TaxTriageTaxonomyRow]` filtered by sample IN clause
- `fetchSamples()` returns `[(sample: String, organismCount: Int)]`
- `fetchMetadata()` returns `[String: String]`

The row struct:
```swift
public struct TaxTriageTaxonomyRow: Sendable {
    public let sample: String
    public let organism: String
    public let taxId: Int?
    public let status: String?
    public let tassScore: Double
    public let readsAligned: Int
    public let uniqueReads: Int?
    public let pctReads: Double?
    public let pctAlignedReads: Double?
    public let coverageBreadth: Double?
    public let meanCoverage: Double?
    public let meanDepth: Double?
    public let confidence: String?
    public let k2Reads: Int?
    public let parentK2Reads: Int?
    public let giniCoefficient: Double?
    public let meanBaseQ: Double?
    public let meanMapQ: Double?
    public let mapqScore: Double?
    public let disparityScore: Double?
    public let minhashScore: Double?
    public let diamondIdentity: Double?
    public let k2DisparityScore: Double?
    public let siblingsScore: Double?
    public let breadthWeightScore: Double?
    public let hhsPercentile: Double?
    public let isAnnotated: Bool?
    public let annClass: String?
    public let microbialCategory: String?
    public let highConsequence: Bool?
    public let isSpecies: Bool?
    public let pathogenicSubstrains: String?
    public let sampleType: String?
    public let bamPath: String?
    public let bamIndexPath: String?
    public let primaryAccession: String?
    public let accessionLength: Int?
}
```

Read `NvdDatabase.swift` for the exact sqlite3 C API patterns to follow: pragma setup, transaction management, prepared statement lifecycle, progress callback, safe text binding with `SQLITE_TRANSIENT`.

- [ ] **Step 2: Write database unit tests**

```swift
// Tests/LungfishIOTests/TaxTriageDatabaseTests.swift
import XCTest
@testable import LungfishIO

final class TaxTriageDatabaseTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCreateAndOpen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [makeTestRow(sample: "s1", organism: "Virus A", tassScore: 0.95, readsAligned: 100)]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "test"])
        XCTAssertEqual(try db.fetchRows(samples: ["s1"]).count, 1)
    }

    func testFetchRowsFiltersBySample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", organism: "Virus A", tassScore: 0.9, readsAligned: 100),
            makeTestRow(sample: "s2", organism: "Virus B", tassScore: 0.8, readsAligned: 200),
            makeTestRow(sample: "s3", organism: "Virus C", tassScore: 0.7, readsAligned: 300),
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let s1Only = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(s1Only.count, 1)
        XCTAssertEqual(s1Only[0].organism, "Virus A")

        let s1s2 = try db.fetchRows(samples: ["s1", "s2"])
        XCTAssertEqual(s1s2.count, 2)

        let all = try db.fetchRows(samples: ["s1", "s2", "s3"])
        XCTAssertEqual(all.count, 3)
    }

    func testFetchSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", organism: "A", tassScore: 0.9, readsAligned: 100),
            makeTestRow(sample: "s1", organism: "B", tassScore: 0.8, readsAligned: 200),
            makeTestRow(sample: "s2", organism: "A", tassScore: 0.7, readsAligned: 300),
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 2)
        let s1 = samples.first { $0.sample == "s1" }
        XCTAssertEqual(s1?.organismCount, 2)
    }

    func testMetadataRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try TaxTriageDatabase.create(at: dbURL, rows: [], metadata: [
            "tool_version": "1.2.3",
            "created_at": "2026-04-07",
        ])
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool_version"], "1.2.3")
        XCTAssertEqual(meta["created_at"], "2026-04-07")
    }

    func testUniqueReadsStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", organism: "V", tassScore: 1.0, readsAligned: 500, uniqueReads: 350)
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].uniqueReads, 350)
    }

    func testBAMPathStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", organism: "V", tassScore: 1.0, readsAligned: 500,
                              bamPath: "/path/to/sample.bam", bamIndexPath: "/path/to/sample.bam.csi",
                              primaryAccession: "NC_045512.2", accessionLength: 29903)
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].bamPath, "/path/to/sample.bam")
        XCTAssertEqual(fetched[0].bamIndexPath, "/path/to/sample.bam.csi")
        XCTAssertEqual(fetched[0].primaryAccession, "NC_045512.2")
        XCTAssertEqual(fetched[0].accessionLength, 29903)
    }

    func testEmptyDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try TaxTriageDatabase.create(at: dbURL, rows: [], metadata: [:])
        XCTAssertEqual(try db.fetchRows(samples: []).count, 0)
        XCTAssertEqual(try db.fetchSamples().count, 0)
    }

    // MARK: - Helpers

    private func makeTestRow(
        sample: String, organism: String, tassScore: Double, readsAligned: Int,
        uniqueReads: Int? = nil, bamPath: String? = nil, bamIndexPath: String? = nil,
        primaryAccession: String? = nil, accessionLength: Int? = nil
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: nil, status: nil,
            tassScore: tassScore, readsAligned: readsAligned, uniqueReads: uniqueReads,
            pctReads: nil, pctAlignedReads: nil, coverageBreadth: nil,
            meanCoverage: nil, meanDepth: nil, confidence: nil,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil,
            disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil,
            microbialCategory: nil, highConsequence: nil, isSpecies: nil,
            pathogenicSubstrains: nil, sampleType: nil,
            bamPath: bamPath, bamIndexPath: bamIndexPath,
            primaryAccession: primaryAccession, accessionLength: accessionLength
        )
    }
}
```

- [ ] **Step 3: Run tests to verify they fail, then implement, then verify pass**

Run: `swift test --filter TaxTriageDatabaseTests`

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift \
      Tests/LungfishIOTests/TaxTriageDatabaseTests.swift
git commit -m "feat: add TaxTriageDatabase with SQLite schema, CRUD, and tests"
```

---

### Task 3: TaxTriage CLI `build-db` Command

**Files:**
- Create: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift` (register command)

- [ ] **Step 1: Create the BuildDbCommand with TaxTriage subcommand**

```swift
// Sources/LungfishCLI/Commands/BuildDbCommand.swift
import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct BuildDbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-db",
        abstract: "Build SQLite databases from classifier results",
        subcommands: [
            TaxTriageSubcommand.self,
            EsVirituSubcommand.self,
            Kraken2Subcommand.self,
        ]
    )
}
```

The TaxTriage subcommand:
```swift
extension BuildDbCommand {
    struct TaxTriageSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "taxtriage",
            abstract: "Build SQLite database from TaxTriage results"
        )

        @Argument(help: "Path to the TaxTriage result directory")
        var resultDir: String

        @Flag(name: .long, help: "Force rebuild even if database exists")
        var force: Bool = false

        @Flag(name: .customLong("no-cleanup"), help: "Skip post-build cleanup of intermediate files")
        var noCleanup: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let resultURL = URL(fileURLWithPath: resultDir)
            let dbURL = resultURL.appendingPathComponent("taxtriage.sqlite")

            // Skip if exists (unless --force)
            if !force && FileManager.default.fileExists(atPath: dbURL.path) {
                print("Database already exists at \(dbURL.path). Use --force to rebuild.")
                return
            }

            // 1. Parse confidence TSV
            // 2. For each sample: locate BAM, parse gcfmap, resolve accessions
            // 3. For each (sample, organism): compute unique reads from BAM
            // 4. Build rows and create database
            // 5. Post-build cleanup (unless --no-cleanup)
        }
    }
}
```

Read the actual TaxTriage directory structure to implement the parsing:
- Confidence file at `report/multiqc_data/multiqc_confidences.txt`
- GCFmap files at `combine/<sample>.combined.gcfmap.tsv`
- BAMs at `minimap2/<sample>.<sample>.dwnld.references.bam`
- BAM indices at `.csi` or `.bai`

The unique reads computation uses `AlignmentDataProvider.fetchReads()` + position-strand dedup (same logic as `deduplicatedReadCount(from:)` in the existing code). Read the existing implementation to extract the dedup logic into a reusable function.

- [ ] **Step 2: Register in LungfishCLI.swift**

Add `BuildDbCommand.self` to the `subcommands` array.

- [ ] **Step 3: Write CLI integration test**

Create test that runs the build-db command against the mini fixture:
```swift
// Tests/LungfishCLITests/BuildDbCommandTests.swift
func testBuildDbTaxTriage() async throws {
    let fixtureDir = TestFixtures.taxTriageMini  // path to Tests/Fixtures/taxtriage-mini
    let tmpDir = makeTempDir()
    defer { cleanup(tmpDir) }

    // Copy fixture to temp (so we don't modify the original)
    try FileManager.default.copyItem(at: fixtureDir, to: tmpDir.appendingPathComponent("taxtriage"))
    let resultDir = tmpDir.appendingPathComponent("taxtriage")

    // Run the command
    var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path])
    try await cmd.run()

    // Verify DB was created
    let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

    // Verify contents
    let db = try TaxTriageDatabase(at: dbURL)
    let rows = try db.fetchRows(samples: [])  // all samples
    XCTAssertGreaterThan(rows.count, 0)

    let samples = try db.fetchSamples()
    XCTAssertEqual(samples.count, 3)  // 3 samples in fixture
}
```

- [ ] **Step 4: Run tests, implement, verify**

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Sources/LungfishCLI/LungfishCLI.swift \
      Tests/LungfishCLITests/BuildDbCommandTests.swift
git commit -m "feat: add lungfish build-db taxtriage CLI command"
```

---

### Task 4: TaxTriage Post-Build Cleanup

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`

- [ ] **Step 1: Add cleanup logic to TaxTriage subcommand**

After successful DB creation, if `--no-cleanup` is not set:
```swift
private func performCleanup(resultURL: URL) {
    let fm = FileManager.default
    var freedBytes: Int64 = 0

    // Delete count/ directory (raw FASTQ copies)
    let countDir = resultURL.appendingPathComponent("count")
    if let size = directorySize(countDir) {
        try? fm.removeItem(at: countDir)
        freedBytes += size
        print("Removed count/ (\(formatBytes(size)))")
    }

    // Delete fastp/ FASTQ files only (keep .html and .json QC reports)
    let fastpDir = resultURL.appendingPathComponent("fastp")
    if fm.fileExists(atPath: fastpDir.path) {
        let contents = try? fm.contentsOfDirectory(at: fastpDir, includingPropertiesForKeys: [.fileSizeKey])
        for file in contents ?? [] {
            if file.pathExtension == "fastq" || file.pathExtension == "gz" || file.lastPathComponent.hasSuffix(".fastp.fastq.gz") {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? fm.removeItem(at: file)
                freedBytes += Int64(size)
            }
        }
        print("Removed fastp FASTQ files")
    }

    // Delete intermediate pipeline directories
    for dirname in ["filterkraken", "get", "map", "samtools", "bedtools", "top", "mergedsubspecies", "mergedkrakenreport"] {
        let dir = resultURL.appendingPathComponent(dirname)
        if let size = directorySize(dir) {
            try? fm.removeItem(at: dir)
            freedBytes += size
            print("Removed \(dirname)/ (\(formatBytes(size)))")
        }
    }

    print("Total space freed: \(formatBytes(freedBytes))")
}
```

- [ ] **Step 2: Write cleanup test**

```swift
func testTaxTriageCleanupRemovesIntermediateFiles() async throws {
    // Create a fake result dir with count/, fastp/, etc.
    // Run build-db
    // Verify count/ is gone, minimap2/ is kept, report/ is kept
}

func testTaxTriageNoCleanupPreservesAll() async throws {
    // Same but with --no-cleanup
    // Verify all directories preserved
}
```

- [ ] **Step 3: Run tests, verify, commit**

```bash
git commit -m "feat: add post-build cleanup for TaxTriage (removes ~33GB intermediate files)"
```

---

### Task 5: TaxTriage VC — configureFromDatabase

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] **Step 1: Add `configureFromDatabase` method to TaxTriageResultViewController**

This replaces both `configure(result:)` for multi-sample and `configureBatchGroup()`:

```swift
func configureFromDatabase(_ db: TaxTriageDatabase) {
    self.taxTriageDatabase = db

    // Fetch all samples
    let sampleList = try? db.fetchSamples()
    sampleIds = sampleList?.map(\.sample).sorted() ?? []

    // Build sample entries for picker
    sampleEntries = sampleIds.map { sid in
        let count = sampleList?.first(where: { $0.sample == sid })?.organismCount ?? 0
        return TaxTriageSampleEntry(
            id: sid,
            displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: nil),
            organismCount: count
        )
    }
    samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleIds))

    // Populate flat table from DB query
    reloadFromDatabase()

    // Show flat table, hide old UI
    sampleFilterControl.isHidden = true
    batchOverviewView.isHidden = true
    organismTableView.isHidden = true
    batchFlatTableView.isHidden = false
    splitView.isHidden = false

    // Wire row selection → miniBAM using BAM path from row data
    batchFlatTableView.onRowSelected = { [weak self] row in
        // Row is a TaxTriageMetric — but we need BAM path from DB row
        // Store DB rows alongside metrics for lookup
    }
}

private func reloadFromDatabase() {
    guard let db = taxTriageDatabase else { return }
    let selectedSamples = Array(samplePickerState.selectedSamples)
    let dbRows = (try? db.fetchRows(samples: selectedSamples)) ?? []

    // Convert DB rows to display format for the flat table
    // The flat table uses TaxTriageMetric — convert or change table to use DB rows directly
}
```

Key decision: The `BatchTaxTriageTableView` currently uses `TaxTriageMetric` as its row type. For DB mode, either:
(a) Convert `TaxTriageTaxonomyRow` → `TaxTriageMetric` for display, or
(b) Change the table to accept `TaxTriageTaxonomyRow` directly

Option (a) is simpler — write a converter. The BAM path data stays in a parallel dictionary keyed by row identity.

- [ ] **Step 2: Update display routing in MainSplitViewController**

In `displayTaxTriageResultFromSidebar` and `displayBatchGroup`:
```swift
// Check for SQLite database first
let dbURL = resultURL.appendingPathComponent("taxtriage.sqlite")
if FileManager.default.fileExists(atPath: dbURL.path) {
    let db = try TaxTriageDatabase(at: dbURL)
    let vc = TaxTriageResultViewController()
    let ttView = vc.view  // force loadView
    vc.configureFromDatabase(db)
    // ... add to hierarchy, wire inspector
    return
}

// No DB — show placeholder and trigger build
showDatabaseBuildPlaceholder(tool: "TaxTriage", resultURL: resultURL)
```

- [ ] **Step 3: Write integration test**

```swift
func testConfigureFromDatabasePopulatesTable() throws {
    // Create DB from fixture data
    // Create VC, call configureFromDatabase
    // Verify flat table has rows
    // Verify sample picker state
}
```

- [ ] **Step 4: Run tests, implement, verify, commit**

```bash
git commit -m "feat: add configureFromDatabase to TaxTriageResultViewController"
```

---

### Task 6: Database Build Placeholder Viewport

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/DatabaseBuildPlaceholderView.swift`

- [ ] **Step 1: Create the placeholder view**

An NSView that shows:
- Centered icon (`NSImageView` with SF Symbol `gearshape.2`)
- Title: "Building database for {tool} results..."
- Subtitle: "Check the Operations Panel for progress."
- Optional "Retry" button (shown on failure)

Follow the existing multi-selection placeholder pattern (centered `NSStackView`).

```swift
@MainActor
final class DatabaseBuildPlaceholderView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    var onRetry: (() -> Void)?

    func configure(tool: String) {
        titleLabel.stringValue = "Building database for \(tool) results…"
        subtitleLabel.stringValue = "Check the Operations Panel for progress."
        retryButton.isHidden = true
    }

    func showError(_ message: String) {
        titleLabel.stringValue = "Database build failed"
        subtitleLabel.stringValue = message
        retryButton.isHidden = false
    }
}
```

- [ ] **Step 2: Wire the placeholder into the display flow**

In `MainSplitViewController`, when no DB exists:
1. Show the placeholder in the viewport
2. Run `lungfish build-db taxtriage <dir>` via Operations Panel
3. When complete, replace placeholder with DB-backed view
4. On failure, show error in placeholder

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: add DatabaseBuildPlaceholderView for missing SQLite databases"
```

---

## Phase 3: EsViritu SQLite

### Task 7: EsVirituDatabase — Schema and CRUD

Same pattern as Task 2 but for EsViritu. Schema matches the spec's `detection_rows` table.

**Files:**
- Create: `Sources/LungfishIO/Formats/EsViritu/EsVirituDatabase.swift`
- Create: `Tests/LungfishIOTests/EsVirituDatabaseTests.swift`

Row struct:
```swift
public struct EsVirituDetectionRow: Sendable {
    public let sample: String
    public let virusName: String
    public let description: String?
    public let contigLength: Int?
    public let segment: String?
    public let accession: String
    public let assembly: String
    public let assemblyLength: Int?
    public let kingdom: String?
    public let phylum: String?
    public let tclass: String?
    public let torder: String?
    public let family: String?
    public let genus: String?
    public let species: String?
    public let subspecies: String?
    public let rpkmf: Double?
    public let readCount: Int
    public let uniqueReads: Int?
    public let coveredBases: Int?
    public let meanCoverage: Double?
    public let avgReadIdentity: Double?
    public let pi: Double?
    public let filteredReadsInSample: Int?
    public let bamPath: String?
    public let bamIndexPath: String?
}
```

Follow exact same test patterns as Task 2.

- [ ] Steps: Write tests → Implement → Verify → Commit

```bash
git commit -m "feat: add EsVirituDatabase with SQLite schema, CRUD, and tests"
```

---

### Task 8: EsViritu CLI `build-db` Subcommand

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`

Add `EsVirituSubcommand` to `BuildDbCommand`. Build flow:
1. Enumerate sample subdirectories
2. Parse `<sample>.detected_virus.info.tsv` per sample
3. Locate BAM at `<sample>_temp/<sample>.third.filt.sorted.bam`
4. Compute unique reads per (sample, accession) from BAM
5. Write to `esviritu.sqlite`
6. Cleanup: remove fastp reports, readstats, consensus FASTAs

- [ ] Steps: Write tests → Implement → Verify → Commit

```bash
git commit -m "feat: add lungfish build-db esviritu CLI command with cleanup"
```

---

### Task 9: EsViritu VC — configureFromDatabase

Same pattern as Task 5 but for `EsVirituResultViewController`.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] Steps: Write tests → Implement → Verify → Commit

```bash
git commit -m "feat: add configureFromDatabase to EsVirituResultViewController"
```

---

## Phase 4: Kraken2 SQLite

### Task 10: Kraken2Database — Schema and CRUD

**Files:**
- Create: `Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift`
- Create: `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`

Simplest of the three — no BAMs, no unique reads. Row struct:
```swift
public struct Kraken2ClassificationRow: Sendable {
    public let sample: String
    public let taxonName: String
    public let taxId: Int
    public let rank: String?
    public let rankDisplayName: String?
    public let readsDirect: Int
    public let readsClade: Int
    public let percentage: Double
}
```

- [ ] Steps: Write tests → Implement → Verify → Commit

```bash
git commit -m "feat: add Kraken2Database with SQLite schema, CRUD, and tests"
```

---

### Task 11: Kraken2 CLI `build-db` Subcommand

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`

Build flow:
1. Enumerate sample subdirectories
2. Parse `classification.kreport` per sample via `KreportParser`
3. Flatten tree to rows (same as `BatchClassificationRow.fromTree`)
4. Write to `kraken2.sqlite`
5. Cleanup: remove `classification.kraken` and `classification.kraken.idx.sqlite` (saves ~1 GB/sample)

- [ ] Steps: Write tests → Implement → Verify → Commit

```bash
git commit -m "feat: add lungfish build-db kraken2 CLI command with cleanup"
```

---

### Task 12: Kraken2 VC — configureFromDatabase

Same pattern as Tasks 5 and 9 but for `TaxonomyViewController`.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] Steps: Write tests → Implement → Verify → Commit

```bash
git commit -m "feat: add configureFromDatabase to TaxonomyViewController for batch Kraken2"
```

---

## Phase 5: Integration & Regression

### Task 13: Full Integration Test

**Files:**
- Modify: `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`

- [ ] **Step 1: End-to-end test for each tool**

For each tool (TaxTriage, EsViritu, Kraken2):
1. Start with fixture directory (no DB)
2. Run `build-db` CLI command
3. Verify DB created with correct row counts
4. Open DB, create VC, call `configureFromDatabase`
5. Verify flat table populated
6. Verify sample picker works
7. Verify BAM paths present in rows (TaxTriage, EsViritu)
8. Verify cleanup removed correct files

- [ ] **Step 2: Regression tests**

- Unique reads in table match unique reads in miniBAM
- No viewport bounce (configureFromDatabase sets correct UI state immediately)
- Single-sample Kraken2 tree view still works (no DB used)
- Placeholder shown when DB missing
- `--force` flag rebuilds DB

- [ ] **Step 3: Run full test suite and commit**

```bash
swift test
git commit -m "test: add end-to-end integration and regression tests for SQLite-backed classifier views"
```

---

### Task 14: Remove Legacy JSON Manifest Code

After all DB-backed views are working, clean up the replaced code.

**Files to clean up:**
- `TaxTriageResultViewController.swift` — Remove `configureBatchGroup()`, `enableMultiSampleFlatTableMode()`, `scheduleBatchPerSampleUniqueReadComputation()`, `persistDeduplicatedReadCounts()`, `syncUniqueReadsToFlatTable()`, `perSampleDeduplicatedReadCounts`, JSON manifest loading/saving
- `EsVirituResultViewController.swift` — Remove `configureBatch()`, `scheduleBatchUniqueReadComputation()`, `persistBatchUniqueReads()`, JSON manifest loading/saving
- `TaxonomyViewController.swift` — Remove `configureBatch()`, kreport-based batch row construction
- `MetagenomicsBatchResultStore.swift` — Remove `TaxTriageBatchManifest`, `EsVirituBatchAggregatedManifest` types and save/load methods
- Remove "Recompute Unique Reads" button from both VCs

**Keep:** `BatchTableView` base class and subclasses (still used for display), Inspector sections, sample picker.

- [ ] Steps: Remove code → Run tests → Verify no regressions → Commit

```bash
git commit -m "refactor: remove legacy JSON manifest code replaced by SQLite databases"
```
