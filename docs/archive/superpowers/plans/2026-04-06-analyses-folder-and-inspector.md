# Analyses Folder, Bundle Persistence Fixes, and Inspector Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move analysis outputs to a project-level `Analyses/` folder, fix single-sample sidebar reload bugs, add analysis history to the FASTQ Inspector, and create comprehensive test fixtures for all analysis types.

**Architecture:** New `AnalysesFolder` manager (LungfishIO) handles directory creation/listing. `AnalysisManifestStore` (LungfishIO) maintains per-bundle `analyses-manifest.json` with lazy pruning. Wizard sheets no longer control output paths — AppDelegate overrides them to use `Analyses/`. Sidebar replaces per-tool `derivatives/` scanning with a flat `Analyses/` scan. Inspector gets a new "Analyses" section reading the manifest.

**Tech Stack:** Swift 6.2, macOS 26, SPM, SwiftUI (Inspector), AppKit (Sidebar), XCTest

**Spec:** `docs/superpowers/specs/2026-04-06-analyses-folder-and-inspector-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/LungfishIO/Bundles/AnalysesFolder.swift` | `Analyses/` directory creation, listing, timestamp parsing |
| `Sources/LungfishIO/Bundles/AnalysisManifest.swift` | `AnalysisManifestEntry`, `AnalysisManifest`, `AnalysisManifestStore` |
| `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift` | Inspector UI for analysis history |
| `Tests/Fixtures/analyses/` (tree) | Analysis result fixture directories |
| `Tests/LungfishIntegrationTests/TestAnalysisFixtures.swift` | Type-safe fixture accessors |
| `Tests/LungfishIOTests/AnalysesFolderTests.swift` | Unit tests for AnalysesFolder |
| `Tests/LungfishIOTests/AnalysisManifestTests.swift` | Unit tests for manifest load/save/prune |
| `Tests/LungfishIntegrationTests/AnalysesMigrationTests.swift` | Migration integration tests |
| `Tests/LungfishIntegrationTests/AnalysesSidebarTests.swift` | Sidebar scanning integration tests |

### Modified Files
| File | Change |
|------|--------|
| `Sources/LungfishApp/App/AppDelegate.swift` | Add `reloadFromFilesystem()` calls; redirect output directories to `Analyses/`; record manifest entries |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | Add `collectAnalyses()`, replace `derivatives/` analysis scanning with `Analyses/` scanning, add `.analysisResult` item type |
| `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` | Wire up AnalysesSection view model |
| `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` | Add analyses manifest to DocumentSectionViewModel |
| `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift` | Make `SPAdesAssemblyResult` Codable, add `save/load/exists` |
| `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift` | Make `Minimap2Result` Codable, add `save/load/exists` |
| `Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift` | Add `summaryParameters()` |
| `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift` | Add `summaryParameters()` |
| `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift` | Add `summaryParameters()` |

---

## Task 1: Create Test Fixtures

**Files:**
- Create: `Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00/esviritu-result.json`
- Create: `Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00/testSample.detected_virus.info.tsv`
- Create: `Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00/testSample.tax_profile.tsv`
- Create: `Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00/testSample.virus_coverage_windows.tsv`
- Create: `Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00/.lungfish-provenance.json`
- Create: `Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/classification-result.json`
- Create: `Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/reads.kreport`
- Create: `Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/reads.kraken`
- Create: `Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/reads.bracken`
- Create: `Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00/taxtriage-result.json`
- Create: `Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00/sample_report.tsv`
- Create: `Tests/Fixtures/analyses/spades-2026-01-15T13-00-00/contigs.fasta`
- Create: `Tests/Fixtures/analyses/spades-2026-01-15T13-00-00/spades.log`
- Create: `Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00/sample.sorted.bam`
- Create: `Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00/sample.sorted.bam.bai`
- Create: `Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00/` (batch structure)
- Create: `Tests/Fixtures/analyses/analyses-manifest.json`
- Create: `Tests/LungfishIntegrationTests/TestAnalysisFixtures.swift`

- [ ] **Step 1: Create EsViritu fixture directory**

Create `Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00/` with structurally correct files.

`esviritu-result.json` — must match `PersistedEsVirituResult` from `EsVirituPipeline.swift:237-248`:
```json
{
    "config": {
        "inputFiles": ["testSample_R1.fastq.gz"],
        "isPairedEnd": false,
        "sampleName": "testSample",
        "outputDirectory": "esviritu-2026-01-15T10-00-00",
        "databasePath": "/databases/esviritu",
        "qualityFilter": true,
        "minReadLength": 50,
        "threads": 4
    },
    "detectionPath": "testSample.detected_virus.info.tsv",
    "assemblyPath": null,
    "taxProfilePath": "testSample.tax_profile.tsv",
    "coveragePath": "testSample.virus_coverage_windows.tsv",
    "virusCount": 2,
    "runtime": 45.3,
    "toolVersion": "1.0.0",
    "provenanceId": "550E8400-E29B-41D4-A716-446655440000",
    "savedAt": "2026-01-15T10:00:00Z"
}
```

`testSample.detected_virus.info.tsv` — real column headers from EsViritu output:
```tsv
virus_name	taxid	accession	num_reads	num_contigs	genome_coverage	avg_depth	ref_length
SARS-CoV-2	2697049	NC_045512.2	1500	3	0.95	25.4	29903
Influenza A virus	11320	NC_007366.1	200	1	0.45	5.2	13588
```

`testSample.tax_profile.tsv`:
```tsv
taxid	name	rank	reads	proportion
2697049	Severe acute respiratory syndrome coronavirus 2	species	1500	0.75
11320	Influenza A virus	species	200	0.10
0	unclassified	no rank	300	0.15
```

`testSample.virus_coverage_windows.tsv`:
```tsv
accession	start	end	depth	coverage
NC_045512.2	1	1000	30.5	1.0
NC_045512.2	1001	2000	22.1	0.98
```

`.lungfish-provenance.json`:
```json
{
    "provenanceId": "550E8400-E29B-41D4-A716-446655440000",
    "tool": "esviritu",
    "version": "1.0.0",
    "timestamp": "2026-01-15T10:00:00Z",
    "inputFiles": ["testSample_R1.fastq.gz"]
}
```

- [ ] **Step 2: Create Kraken2 fixture directory**

Create `Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/` with:

`classification-result.json` — must match `PersistedClassificationResult` from `ClassificationResult.swift:299-308`:
```json
{
    "config": {
        "goal": "profile",
        "inputFiles": ["reads_R1.fastq.gz"],
        "isPairedEnd": false,
        "databaseName": "standard",
        "databaseVersion": "2024-01",
        "databasePath": "/databases/kraken2/standard",
        "confidence": 0.0,
        "minimumHitGroups": 2,
        "threads": 4,
        "memoryMapping": false,
        "quickMode": false,
        "outputDirectory": "kraken2-2026-01-15T11-00-00"
    },
    "reportPath": "reads.kreport",
    "outputPath": "reads.kraken",
    "brackenPath": "reads.bracken",
    "runtime": 30.1,
    "toolVersion": "2.1.3",
    "provenanceId": "660E8400-E29B-41D4-A716-446655440001",
    "savedAt": "2026-01-15T11:00:00Z"
}
```

`reads.kreport` — valid Kraken2 6-column format:
```tsv
 45.00	4500	4500	U	0	unclassified
 55.00	5500	0	R	1	root
 54.50	5450	0	D	10239	  Viruses
 50.00	5000	0	F	11118	    Coronaviridae
 50.00	5000	5000	S	2697049	      Severe acute respiratory syndrome coronavirus 2
```

`reads.kraken` — valid per-read output (10 rows):
```
C	read001	2697049	150	2697049:120 0:30
C	read002	2697049	150	2697049:100 0:50
C	read003	2697049	150	2697049:150
C	read004	2697049	150	2697049:130 0:20
C	read005	2697049	150	2697049:110 0:40
U	read006	0	150	0:150
U	read007	0	150	0:150
U	read008	0	150	0:150
U	read009	0	150	0:150
U	read010	0	150	0:150
```

`reads.bracken` — valid Bracken format:
```tsv
name	taxonomy_id	taxonomy_lvl	kraken_assigned_reads	added_reads	new_est_reads	fraction_total_reads
Severe acute respiratory syndrome coronavirus 2	2697049	S	5000	300	5300	0.9636
Influenza A virus	11320	S	100	100	200	0.0364
```

- [ ] **Step 3: Create TaxTriage fixture directory**

Create `Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00/` with:

`taxtriage-result.json` — match `TaxTriageResult` fields from `TaxTriageResult.swift:34-202`. Note: TaxTriage uses absolute URLs, so use placeholder paths:
```json
{
    "config": {
        "samples": [{"name": "testSample", "fastq1": "/tmp/testSample_R1.fastq.gz"}],
        "database": "nt",
        "threads": 4,
        "outputDirectory": "/tmp/taxtriage-2026-01-15T12-00-00"
    },
    "runtime": 120.5,
    "exitCode": 0,
    "outputDirectory": "/tmp/taxtriage-2026-01-15T12-00-00",
    "reportFiles": ["/tmp/taxtriage-2026-01-15T12-00-00/sample_report.tsv"],
    "metricsFiles": [],
    "kronaFiles": [],
    "logFile": null,
    "traceFile": null,
    "allOutputFiles": ["/tmp/taxtriage-2026-01-15T12-00-00/sample_report.tsv"],
    "deduplicatedReadCounts": {"SARS-CoV-2": 500, "Influenza A": 100},
    "perSampleDeduplicatedReadCounts": null,
    "sourceBundleURLs": null,
    "savedAt": "2026-01-15T12:00:00Z"
}
```

`sample_report.tsv`:
```tsv
organism	reads	confidence
SARS-CoV-2	500	0.95
Influenza A	100	0.80
```

- [ ] **Step 4: Create SPAdes and Minimap2 fixture directories**

Create `Tests/Fixtures/analyses/spades-2026-01-15T13-00-00/` with:

`contigs.fasta` — two small contigs:
```fasta
>NODE_1_length_500_cov_25.4
ATGCGTACGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGA
>NODE_2_length_300_cov_15.1
GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAG
```

`spades.log` — truncated:
```
Command line: spades.py --isolate -1 reads_R1.fastq.gz -o output
System information:
  SPAdes version: 3.15.5
  Python version: 3.10.0
Assembly finished.
```

`assembly-result.json` — NEW sidecar format (will be defined in Task 4):
```json
{
    "schemaVersion": 1,
    "contigsPath": "contigs.fasta",
    "scaffoldsPath": null,
    "graphPath": null,
    "logPath": "spades.log",
    "totalContigs": 2,
    "n50": 500,
    "totalLength": 800,
    "toolVersion": "3.15.5",
    "runtime": 123.4,
    "provenanceId": "770E8400-E29B-41D4-A716-446655440002",
    "savedAt": "2026-01-15T13:00:00Z"
}
```

Create `Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00/` with:

`sample.sorted.bam` — minimal BAM file (just a header). Create a placeholder text file (tests check sidecar loading, not BAM parsing):
```
(binary BAM placeholder — 0 bytes is fine for sidecar round-trip tests)
```

`sample.sorted.bam.bai` — same, placeholder.

`alignment-result.json` — NEW sidecar format:
```json
{
    "schemaVersion": 1,
    "bamPath": "sample.sorted.bam",
    "baiPath": "sample.sorted.bam.bai",
    "totalReads": 10000,
    "mappedReads": 9500,
    "unmappedReads": 500,
    "toolVersion": "2.28",
    "runtime": 45.2,
    "provenanceId": "880E8400-E29B-41D4-A716-446655440003",
    "savedAt": "2026-01-15T14:00:00Z"
}
```

- [ ] **Step 5: Create batch EsViritu fixture**

Create `Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00/` with:

```
esviritu-batch-2026-01-15T15-00-00/
├── esviritu-batch-manifest.json
├── esviritu-batch-summary.tsv
├── sample1/
│   ├── esviritu-result.json
│   └── sample1.detected_virus.info.tsv
└── sample2/
    ├── esviritu-result.json
    └── sample2.detected_virus.info.tsv
```

`esviritu-batch-manifest.json` — match `MetagenomicsBatchResultStore` format (search codebase for the struct):
```json
{
    "header": {
        "tool": "esviritu",
        "version": "1.0.0",
        "sampleCount": 2,
        "startedAt": "2026-01-15T15:00:00Z",
        "completedAt": "2026-01-15T15:05:00Z"
    },
    "samples": [
        {"sampleId": "sample1", "resultDirectory": "sample1", "status": "completed", "virusCount": 1},
        {"sampleId": "sample2", "resultDirectory": "sample2", "status": "completed", "virusCount": 0}
    ]
}
```

`esviritu-batch-summary.tsv`:
```tsv
sample_id	status	virus_count	runtime_seconds
sample1	completed	1	20.5
sample2	completed	0	18.2
```

Each sample subdirectory gets its own `esviritu-result.json` (same structure as Step 1, with appropriate sample names).

- [ ] **Step 6: Create sample analyses-manifest.json**

Create `Tests/Fixtures/analyses/analyses-manifest.json` — this represents what would live inside a `.lungfishfastq` bundle:

```json
{
    "schemaVersion": 1,
    "analyses": [
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "tool": "esviritu",
            "timestamp": "2026-01-15T10:00:00Z",
            "analysisDirectoryName": "esviritu-2026-01-15T10-00-00",
            "displayName": "EsViritu Detection",
            "parameters": {
                "sampleName": "testSample",
                "minReadLength": 50,
                "qualityFilter": true
            },
            "summary": "2 viruses detected in 2 families",
            "status": "completed"
        },
        {
            "id": "660E8400-E29B-41D4-A716-446655440001",
            "tool": "kraken2",
            "timestamp": "2026-01-15T11:00:00Z",
            "analysisDirectoryName": "kraken2-2026-01-15T11-00-00",
            "displayName": "Kraken2 Classification",
            "parameters": {
                "database": "standard",
                "confidence": 0.0,
                "minimumHitGroups": 2
            },
            "summary": "5500 of 10000 reads classified",
            "status": "completed"
        },
        {
            "id": "DEADBEEF-0000-0000-0000-000000000000",
            "tool": "esviritu",
            "timestamp": "2026-01-10T08:00:00Z",
            "analysisDirectoryName": "esviritu-2026-01-10T08-00-00",
            "displayName": "EsViritu Detection",
            "parameters": {
                "sampleName": "testSample"
            },
            "summary": "1 virus detected",
            "status": "completed"
        }
    ]
}
```

Note: The third entry (`DEADBEEF...`) references `esviritu-2026-01-10T08-00-00` which does NOT exist in the fixture tree — this is intentionally stale for pruning tests.

- [ ] **Step 7: Create TestAnalysisFixtures.swift**

Create `Tests/LungfishIntegrationTests/TestAnalysisFixtures.swift`:

```swift
import Foundation

/// Type-safe accessors for analysis result test fixtures.
///
/// Fixtures live in `Tests/Fixtures/analyses/` and mirror the exact folder
/// structure of real analysis outputs with minimal but structurally correct data.
///
/// Usage:
/// ```swift
/// let sidecar = TestAnalysisFixtures.esvirituResult
///     .appendingPathComponent("esviritu-result.json")
/// let data = try Data(contentsOf: sidecar)
/// ```
public enum TestAnalysisFixtures {

    // MARK: - Base URL

    /// Root of the analyses fixture tree.
    public static let fixturesRoot: URL = {
        // Strategy 1: SPM resource bundle (used by swift test)
        if let bundleURL = Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("analyses") {
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                return bundleURL
            }
        }
        // Strategy 2: Walk up from source file
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/analyses")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("Cannot locate Tests/Fixtures/analyses/. Run from a test target.")
    }()

    // MARK: - Individual Analysis Directories

    /// EsViritu single-sample result fixture.
    public static var esvirituResult: URL {
        fixture("esviritu-2026-01-15T10-00-00")
    }

    /// Kraken2 classification result fixture.
    public static var kraken2Result: URL {
        fixture("kraken2-2026-01-15T11-00-00")
    }

    /// TaxTriage result fixture.
    public static var taxTriageResult: URL {
        fixture("taxtriage-2026-01-15T12-00-00")
    }

    /// SPAdes assembly result fixture.
    public static var spadesResult: URL {
        fixture("spades-2026-01-15T13-00-00")
    }

    /// Minimap2 alignment result fixture.
    public static var minimap2Result: URL {
        fixture("minimap2-2026-01-15T14-00-00")
    }

    /// EsViritu batch result fixture.
    public static var esvirituBatchResult: URL {
        fixture("esviritu-batch-2026-01-15T15-00-00")
    }

    // MARK: - Sample Manifest

    /// Sample `analyses-manifest.json` with 3 entries (one stale for pruning tests).
    public static var sampleManifest: URL {
        let url = fixturesRoot.appendingPathComponent("analyses-manifest.json")
        precondition(
            FileManager.default.fileExists(atPath: url.path),
            "Test fixture missing: analyses/analyses-manifest.json"
        )
        return url
    }

    // MARK: - Temp Project Helper

    /// Creates a temporary project directory with the fixture analyses
    /// copied into an `Analyses/` folder and a fake `.lungfishfastq` bundle
    /// containing the sample manifest.
    ///
    /// Caller is responsible for deleting the returned URL in tearDown.
    public static func createTempProject() throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("test-analyses-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Copy fixture analyses into Analyses/
        let analysesDir = tempDir.appendingPathComponent("Analyses")
        try fm.createDirectory(at: analysesDir, withIntermediateDirectories: true)

        let fixtureDirs = [
            "esviritu-2026-01-15T10-00-00",
            "kraken2-2026-01-15T11-00-00",
            "taxtriage-2026-01-15T12-00-00",
            "spades-2026-01-15T13-00-00",
            "minimap2-2026-01-15T14-00-00",
            "esviritu-batch-2026-01-15T15-00-00",
        ]
        for dirName in fixtureDirs {
            let src = fixturesRoot.appendingPathComponent(dirName)
            let dst = analysesDir.appendingPathComponent(dirName)
            try fm.copyItem(at: src, to: dst)
        }

        // Create a fake FASTQ bundle with the sample manifest
        let bundleDir = tempDir.appendingPathComponent("testSample.lungfishfastq")
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try fm.copyItem(
            at: sampleManifest,
            to: bundleDir.appendingPathComponent("analyses-manifest.json")
        )

        return tempDir
    }

    // MARK: - Private

    private static func fixture(_ name: String) -> URL {
        let url = fixturesRoot.appendingPathComponent(name)
        precondition(
            FileManager.default.fileExists(atPath: url.path),
            "Test fixture missing: analyses/\(name). Ensure Tests/Fixtures/analyses/ is populated."
        )
        return url
    }
}
```

- [ ] **Step 8: Verify fixtures are accessible**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds (fixtures are in the `LungfishIntegrationTests` target which has `.copy("Fixtures")`)

- [ ] **Step 9: Commit fixtures**

```bash
git add Tests/Fixtures/analyses/ Tests/LungfishIntegrationTests/TestAnalysisFixtures.swift
git commit -m "test: add comprehensive analysis result fixtures for all tool types

Mirrors exact folder structure of EsViritu, Kraken2, TaxTriage, SPAdes,
and Minimap2 outputs. Includes batch fixture and sample analyses-manifest.json
with intentionally stale entry for pruning tests."
```

---

## Task 2: AnalysesFolder Manager

**Files:**
- Create: `Sources/LungfishIO/Bundles/AnalysesFolder.swift`
- Create: `Tests/LungfishIOTests/AnalysesFolderTests.swift`

- [ ] **Step 1: Write failing tests for AnalysesFolder**

Create `Tests/LungfishIOTests/AnalysesFolderTests.swift`:

```swift
import XCTest
@testable import LungfishIO

final class AnalysesFolderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-analyses-folder-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - url(for:)

    func testURLCreatesDirectoryIfMissing() throws {
        let url = try AnalysesFolder.url(for: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "Analyses")
    }

    func testURLReturnsExistingDirectory() throws {
        let existing = tempDir.appendingPathComponent("Analyses")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let url = try AnalysesFolder.url(for: tempDir)
        XCTAssertEqual(url.path, existing.path)
    }

    // MARK: - createAnalysisDirectory(tool:in:date:)

    func testCreateAnalysisDirectoryFormatsTimestamp() throws {
        // 2026-04-06 14:30:00 UTC
        let date = Date(timeIntervalSince1970: 1775398200)
        let url = try AnalysesFolder.createAnalysisDirectory(
            tool: "esviritu", in: tempDir, date: date
        )
        XCTAssertTrue(url.lastPathComponent.hasPrefix("esviritu-"))
        XCTAssertTrue(url.lastPathComponent.contains("2026"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCreateAnalysisDirectoryIsBatchAware() throws {
        let url = try AnalysesFolder.createAnalysisDirectory(
            tool: "kraken2", in: tempDir, isBatch: true
        )
        XCTAssertTrue(url.lastPathComponent.hasPrefix("kraken2-batch-"))
    }

    // MARK: - listAnalyses(in:)

    func testListAnalysesFindsAllTypes() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        // Create some fake analysis directories
        for name in ["esviritu-2026-01-15T10-00-00", "kraken2-2026-01-15T11-00-00", "spades-2026-01-15T13-00-00"] {
            try FileManager.default.createDirectory(
                at: analysesDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 3)
    }

    func testListAnalysesParseToolAndTimestamp() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.first?.tool, "esviritu")
        XCTAssertFalse(analyses.first?.isBatch ?? true)
    }

    func testListAnalysesDetectsBatch() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-batch-2026-01-15T15-00-00"),
            withIntermediateDirectories: true
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertTrue(analyses.first?.isBatch ?? false)
    }

    func testListAnalysesIgnoresNonAnalysisDirectories() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("random-folder"),
            withIntermediateDirectories: true
        )
        try "not an analysis".write(
            to: analysesDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 0)
    }

    func testListAnalysesReturnsEmptyForMissingFolder() throws {
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 0)
    }

    // MARK: - Timestamp formatting

    func testTimestampFormat() {
        let formatted = AnalysesFolder.formatTimestamp(
            Date(timeIntervalSince1970: 1775398200)
        )
        // Should be ISO8601 with dashes instead of colons
        XCTAssertFalse(formatted.contains(":"))
        XCTAssertTrue(formatted.contains("T"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnalysesFolderTests 2>&1 | tail -10`
Expected: Compilation error — `AnalysesFolder` not defined.

- [ ] **Step 3: Implement AnalysesFolder**

Create `Sources/LungfishIO/Bundles/AnalysesFolder.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.lungfish.browser", category: "AnalysesFolder")

/// Manages the project-level `Analyses/` directory where analysis results
/// (classifications, assemblies, alignments) are stored.
///
/// Each analysis run gets a timestamped subdirectory:
/// `Analyses/{tool}-{yyyy-MM-dd'T'HH-mm-ss}/`
public enum AnalysesFolder {
    public static let directoryName = "Analyses"

    // MARK: - Known Tool Names

    /// Recognized analysis tool identifiers used in directory naming.
    public static let knownTools: Set<String> = [
        "esviritu", "kraken2", "taxtriage", "minimap2",
        "spades", "megahit", "naomgs", "nvd",
    ]

    // MARK: - Directory Management

    /// Returns the `Analyses/` URL for a project, creating the directory if needed.
    public static func url(for projectURL: URL) throws -> URL {
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            logger.info("Created Analyses directory at \(dir.path, privacy: .public)")
        }
        return dir
    }

    /// Creates a new timestamped analysis subdirectory.
    ///
    /// - Parameters:
    ///   - tool: Lowercase tool name (e.g., "esviritu", "kraken2").
    ///   - projectURL: The project root directory.
    ///   - isBatch: Whether this is a batch run (inserts "-batch-" in the name).
    ///   - date: Timestamp for the directory name. Defaults to now.
    /// - Returns: URL of the created directory.
    public static func createAnalysisDirectory(
        tool: String,
        in projectURL: URL,
        isBatch: Bool = false,
        date: Date = Date()
    ) throws -> URL {
        let analysesDir = try url(for: projectURL)
        let timestamp = formatTimestamp(date)
        let dirName = isBatch ? "\(tool)-batch-\(timestamp)" : "\(tool)-\(timestamp)"
        let dir = analysesDir.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logger.info("Created analysis directory: \(dirName, privacy: .public)")
        return dir
    }

    // MARK: - Listing

    /// Lists all analysis directories in the project's `Analyses/` folder.
    ///
    /// Returns an empty array if `Analyses/` does not exist.
    public static func listAnalyses(in projectURL: URL) throws -> [AnalysisDirectoryInfo] {
        let analysesDir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: analysesDir.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: analysesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var results: [AnalysisDirectoryInfo] = []
        for childURL in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            if let info = parseDirectoryName(childURL.lastPathComponent, url: childURL) {
                results.append(info)
            }
        }

        return results.sorted { $0.timestamp > $1.timestamp } // newest first
    }

    // MARK: - Timestamp Formatting

    /// Formats a date as `yyyy-MM-dd'T'HH-mm-ss` (filesystem-safe ISO8601).
    public static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// Parses a timestamp string in `yyyy-MM-dd'T'HH-mm-ss` format.
    public static func parseTimestamp(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)
    }

    // MARK: - Types

    /// Describes a discovered analysis directory.
    public struct AnalysisDirectoryInfo: Sendable {
        public let url: URL
        public let tool: String
        public let timestamp: Date
        public let isBatch: Bool
    }

    // MARK: - Private

    /// Parses a directory name like "esviritu-2026-01-15T10-00-00" or
    /// "kraken2-batch-2026-01-15T11-00-00" into tool + timestamp + batch flag.
    private static func parseDirectoryName(_ name: String, url: URL) -> AnalysisDirectoryInfo? {
        // Try batch pattern first: {tool}-batch-{timestamp}
        for tool in knownTools {
            let batchPrefix = "\(tool)-batch-"
            if name.hasPrefix(batchPrefix) {
                let timestampStr = String(name.dropFirst(batchPrefix.count))
                if let date = parseTimestamp(timestampStr) {
                    return AnalysisDirectoryInfo(url: url, tool: tool, timestamp: date, isBatch: true)
                }
            }
        }
        // Try single pattern: {tool}-{timestamp}
        for tool in knownTools {
            let prefix = "\(tool)-"
            if name.hasPrefix(prefix) {
                let timestampStr = String(name.dropFirst(prefix.count))
                if let date = parseTimestamp(timestampStr) {
                    return AnalysisDirectoryInfo(url: url, tool: tool, timestamp: date, isBatch: false)
                }
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnalysesFolderTests 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/AnalysesFolder.swift Tests/LungfishIOTests/AnalysesFolderTests.swift
git commit -m "feat: add AnalysesFolder manager for project-level Analyses/ directory

Creates timestamped analysis directories, lists/parses existing ones,
and handles batch vs single-sample naming conventions."
```

---

## Task 3: AnalysisManifest and AnalysisManifestStore

**Files:**
- Create: `Sources/LungfishIO/Bundles/AnalysisManifest.swift`
- Create: `Tests/LungfishIOTests/AnalysisManifestTests.swift`

- [ ] **Step 1: Write failing tests for AnalysisManifestStore**

Create `Tests/LungfishIOTests/AnalysisManifestTests.swift`:

```swift
import XCTest
@testable import LungfishIO

final class AnalysisManifestTests: XCTestCase {
    private var tempDir: URL!
    private var bundleDir: URL!
    private var projectDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-manifest-\(UUID().uuidString)")
        projectDir = tempDir
        bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        try! FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Load

    func testLoadReturnsEmptyForMissingFile() {
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 0)
    }

    func testLoadReturnsEmptyForCorruptFile() throws {
        let manifestURL = bundleDir.appendingPathComponent(AnalysisManifest.filename)
        try "{ broken json".write(to: manifestURL, atomically: true, encoding: .utf8)
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 0)
    }

    // MARK: - Record + Round-trip

    func testRecordAndLoad() throws {
        let entry = AnalysisManifestEntry(
            id: UUID(),
            tool: "esviritu",
            timestamp: Date(),
            analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu Detection",
            parameters: ["sampleName": .string("testSample")],
            summary: "2 viruses detected",
            status: .completed
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleDir)

        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 1)
        XCTAssertEqual(manifest.analyses.first?.tool, "esviritu")
        XCTAssertEqual(manifest.analyses.first?.summary, "2 viruses detected")
    }

    func testRecordAppendsToExisting() throws {
        let entry1 = AnalysisManifestEntry(
            id: UUID(), tool: "esviritu", timestamp: Date(),
            analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu", parameters: [:],
            summary: "first", status: .completed
        )
        let entry2 = AnalysisManifestEntry(
            id: UUID(), tool: "kraken2", timestamp: Date(),
            analysisDirectoryName: "kraken2-2026-01-15T11-00-00",
            displayName: "Kraken2", parameters: [:],
            summary: "second", status: .completed
        )
        try AnalysisManifestStore.recordAnalysis(entry1, bundleURL: bundleDir)
        try AnalysisManifestStore.recordAnalysis(entry2, bundleURL: bundleDir)

        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 2)
    }

    // MARK: - Pruning

    func testPruneRemovesStaleEntries() throws {
        // Create an analysis directory that exists
        let analysesDir = try AnalysesFolder.url(for: projectDir)
        let existingDir = analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00")
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        // Record two entries: one with existing dir, one without
        let good = AnalysisManifestEntry(
            id: UUID(), tool: "esviritu", timestamp: Date(),
            analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu", parameters: [:],
            summary: "exists", status: .completed
        )
        let stale = AnalysisManifestEntry(
            id: UUID(), tool: "kraken2", timestamp: Date(),
            analysisDirectoryName: "kraken2-DOES-NOT-EXIST",
            displayName: "Kraken2", parameters: [:],
            summary: "stale", status: .completed
        )
        try AnalysisManifestStore.recordAnalysis(good, bundleURL: bundleDir)
        try AnalysisManifestStore.recordAnalysis(stale, bundleURL: bundleDir)

        // Load triggers pruning
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 1)
        XCTAssertEqual(manifest.analyses.first?.tool, "esviritu")

        // Verify the file on disk was updated (re-saved without stale entry)
        let reloaded = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(reloaded.analyses.count, 1)
    }

    // MARK: - Parameters encoding

    func testParametersRoundTrip() throws {
        let entry = AnalysisManifestEntry(
            id: UUID(), tool: "esviritu", timestamp: Date(),
            analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "Test",
            parameters: [
                "sampleName": .string("SRR123"),
                "minReads": .int(10),
                "minCoverage": .double(1.5),
                "qualityFilter": .bool(true),
            ],
            summary: "test", status: .completed
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleDir)
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        let params = manifest.analyses.first!.parameters
        XCTAssertEqual(params["sampleName"]?.stringValue, "SRR123")
        XCTAssertEqual(params["minReads"]?.intValue, 10)
        XCTAssertEqual(params["minCoverage"]?.doubleValue, 1.5)
        XCTAssertEqual(params["qualityFilter"]?.boolValue, true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnalysisManifestTests 2>&1 | tail -10`
Expected: Compilation error — types not defined.

- [ ] **Step 3: Implement AnalysisManifest types and store**

Create `Sources/LungfishIO/Bundles/AnalysisManifest.swift`:

```swift
import Foundation
import os
import LungfishWorkflow  // for AnyCodableValue

private let logger = Logger(subsystem: "com.lungfish.browser", category: "AnalysisManifest")

// MARK: - Data Types

/// A single analysis entry in a FASTQ bundle's analysis manifest.
public struct AnalysisManifestEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let tool: String
    public let timestamp: Date
    public let analysisDirectoryName: String
    public let displayName: String
    public let parameters: [String: AnyCodableValue]
    public let summary: String
    public let status: AnalysisStatus

    public enum AnalysisStatus: String, Codable, Sendable {
        case completed
        case failed
    }

    public init(
        id: UUID = UUID(),
        tool: String,
        timestamp: Date = Date(),
        analysisDirectoryName: String,
        displayName: String,
        parameters: [String: AnyCodableValue] = [:],
        summary: String,
        status: AnalysisStatus = .completed
    ) {
        self.id = id
        self.tool = tool
        self.timestamp = timestamp
        self.analysisDirectoryName = analysisDirectoryName
        self.displayName = displayName
        self.parameters = parameters
        self.summary = summary
        self.status = status
    }
}

/// The root structure of `analyses-manifest.json` stored in each `.lungfishfastq` bundle.
public struct AnalysisManifest: Codable, Sendable {
    public static let filename = "analyses-manifest.json"
    public var schemaVersion: Int = 1
    public var analyses: [AnalysisManifestEntry]

    public init(analyses: [AnalysisManifestEntry] = []) {
        self.analyses = analyses
    }
}

// MARK: - Store

/// Reads, writes, and prunes `analyses-manifest.json` files in FASTQ bundles.
public enum AnalysisManifestStore {

    /// Load the manifest for a FASTQ bundle, pruning entries whose
    /// analysis directories no longer exist on disk.
    ///
    /// Returns an empty manifest if the file is missing or corrupt.
    public static func load(bundleURL: URL, projectURL: URL) -> AnalysisManifest {
        let fileURL = bundleURL.appendingPathComponent(AnalysisManifest.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AnalysisManifest()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var manifest = try decoder.decode(AnalysisManifest.self, from: data)

            let pruned = pruneStaleEntries(manifest: &manifest, projectURL: projectURL)
            if pruned > 0 {
                logger.info("Pruned \(pruned) stale manifest entries from \(bundleURL.lastPathComponent, privacy: .public)")
                try? save(manifest, to: bundleURL)
            }

            return manifest
        } catch {
            logger.warning("Failed to load analysis manifest from \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return AnalysisManifest()
        }
    }

    /// Append a new analysis entry and save atomically.
    public static func recordAnalysis(_ entry: AnalysisManifestEntry, bundleURL: URL) throws {
        let fileURL = bundleURL.appendingPathComponent(AnalysisManifest.filename)
        var manifest: AnalysisManifest

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(AnalysisManifest.self, from: data)
        } else {
            manifest = AnalysisManifest()
        }

        manifest.analyses.append(entry)
        try save(manifest, to: bundleURL)
        logger.info("Recorded \(entry.tool, privacy: .public) analysis in \(bundleURL.lastPathComponent, privacy: .public)")
    }

    /// Remove entries whose analysis directories are missing.
    /// Returns the count of pruned entries.
    @discardableResult
    public static func pruneStaleEntries(
        manifest: inout AnalysisManifest,
        projectURL: URL
    ) -> Int {
        let analysesDir = projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        let before = manifest.analyses.count
        manifest.analyses.removeAll { entry in
            let dir = analysesDir.appendingPathComponent(entry.analysisDirectoryName)
            return !FileManager.default.fileExists(atPath: dir.path)
        }
        return before - manifest.analyses.count
    }

    // MARK: - Private

    private static func save(_ manifest: AnalysisManifest, to bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let fileURL = bundleURL.appendingPathComponent(AnalysisManifest.filename)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

**Important dependency note:** This file imports `LungfishWorkflow` for `AnyCodableValue`. Check if `LungfishIO` already depends on `LungfishWorkflow` in `Package.swift`. If not, move `AnyCodableValue` to `LungfishCore` or `LungfishIO` to avoid a circular dependency. The simpler fix is to duplicate the small enum in LungfishIO — it's 30 lines. Name it `AnalysisParameterValue` to avoid collision:

```swift
/// Heterogeneous parameter value for analysis manifest entries.
public enum AnalysisParameterValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .double(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}
```

Use `AnalysisParameterValue` instead of `AnyCodableValue` in `AnalysisManifestEntry.parameters`, and remove the `LungfishWorkflow` import. Update the test accordingly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnalysisManifestTests 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/AnalysisManifest.swift Tests/LungfishIOTests/AnalysisManifestTests.swift
git commit -m "feat: add AnalysisManifestStore for per-bundle analysis history tracking

Manages analyses-manifest.json in FASTQ bundles. Supports record, load,
and lazy pruning of stale entries whose directories no longer exist."
```

---

## Task 4: SPAdes and Minimap2 Result Sidecars

**Files:**
- Modify: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/SPAdesResultSidecarTests.swift`
- Create: `Tests/LungfishWorkflowTests/Alignment/Minimap2ResultSidecarTests.swift`

- [ ] **Step 1: Write failing test for SPAdes result sidecar**

Create `Tests/LungfishWorkflowTests/Assembly/SPAdesResultSidecarTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow

final class SPAdesResultSidecarTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-spades-sidecar-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        let result = SPAdesAssemblyResult(
            contigsPath: tempDir.appendingPathComponent("contigs.fasta"),
            scaffoldsPath: tempDir.appendingPathComponent("scaffolds.fasta"),
            graphPath: nil,
            logPath: tempDir.appendingPathComponent("spades.log"),
            paramsPath: nil,
            statistics: AssemblyStatistics(totalContigs: 42, n50: 15000, totalLength: 29903),
            spadesVersion: "3.15.5",
            wallTimeSeconds: 123.4,
            commandLine: "spades.py --isolate",
            exitCode: 0
        )

        try result.save(to: tempDir)
        XCTAssertTrue(SPAdesAssemblyResult.exists(in: tempDir))

        let loaded = try SPAdesAssemblyResult.load(from: tempDir)
        XCTAssertEqual(loaded.statistics.totalContigs, 42)
        XCTAssertEqual(loaded.statistics.n50, 15000)
        XCTAssertEqual(loaded.spadesVersion, "3.15.5")
    }

    func testExistsReturnsFalseForMissingFile() {
        XCTAssertFalse(SPAdesAssemblyResult.exists(in: tempDir))
    }
}
```

- [ ] **Step 2: Write failing test for Minimap2 result sidecar**

Create `Tests/LungfishWorkflowTests/Alignment/Minimap2ResultSidecarTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow

final class Minimap2ResultSidecarTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-minimap2-sidecar-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        let result = Minimap2Result(
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10000,
            mappedReads: 9500,
            unmappedReads: 500,
            wallClockSeconds: 45.2
        )

        try result.save(to: tempDir, toolVersion: "2.28")
        XCTAssertTrue(Minimap2Result.exists(in: tempDir))

        let loaded = try Minimap2Result.load(from: tempDir)
        XCTAssertEqual(loaded.totalReads, 10000)
        XCTAssertEqual(loaded.mappedReads, 9500)
    }

    func testExistsReturnsFalseForMissingFile() {
        XCTAssertFalse(Minimap2Result.exists(in: tempDir))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter "SPAdesResultSidecarTests|Minimap2ResultSidecarTests" 2>&1 | tail -10`
Expected: Compilation errors — `save`/`load`/`exists` not defined.

- [ ] **Step 4: Implement SPAdes result persistence**

In `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`, add after the `SPAdesAssemblyResult` struct (line ~144):

```swift
// MARK: - Result Persistence

private let assemblyResultFilename = "assembly-result.json"

extension SPAdesAssemblyResult {
    /// Persisted representation with relative paths.
    struct PersistedAssemblyResult: Codable, Sendable {
        let schemaVersion: Int
        let contigsPath: String
        let scaffoldsPath: String?
        let graphPath: String?
        let logPath: String
        let totalContigs: Int
        let n50: Int
        let totalLength: Int
        let toolVersion: String?
        let runtime: TimeInterval
        let commandLine: String
        let provenanceId: UUID?
        let savedAt: Date
    }

    public func save(to directory: URL) throws {
        let sidecar = PersistedAssemblyResult(
            schemaVersion: 1,
            contigsPath: contigsPath.lastPathComponent,
            scaffoldsPath: scaffoldsPath?.lastPathComponent,
            graphPath: graphPath?.lastPathComponent,
            logPath: logPath.lastPathComponent,
            totalContigs: statistics.totalContigs,
            n50: statistics.n50,
            totalLength: statistics.totalLength,
            toolVersion: spadesVersion,
            runtime: wallTimeSeconds,
            commandLine: commandLine,
            provenanceId: UUID(),
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: directory.appendingPathComponent(assemblyResultFilename), options: .atomic)
    }

    public static func load(from directory: URL) throws -> SPAdesAssemblyResult {
        let fileURL = directory.appendingPathComponent(assemblyResultFilename)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(PersistedAssemblyResult.self, from: data)
        return SPAdesAssemblyResult(
            contigsPath: directory.appendingPathComponent(sidecar.contigsPath),
            scaffoldsPath: sidecar.scaffoldsPath.map { directory.appendingPathComponent($0) },
            graphPath: sidecar.graphPath.map { directory.appendingPathComponent($0) },
            logPath: directory.appendingPathComponent(sidecar.logPath),
            paramsPath: nil,
            statistics: AssemblyStatistics(
                totalContigs: sidecar.totalContigs,
                n50: sidecar.n50,
                totalLength: sidecar.totalLength
            ),
            spadesVersion: sidecar.toolVersion,
            wallTimeSeconds: sidecar.runtime,
            commandLine: sidecar.commandLine,
            exitCode: 0
        )
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(assemblyResultFilename).path
        )
    }
}
```

**Note:** Check if `AssemblyStatistics` exists and has these fields. If not, adapt the struct accordingly. The test creates it with `(totalContigs:n50:totalLength:)` — make sure that init exists.

- [ ] **Step 5: Implement Minimap2 result persistence**

In `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift`, add after `Minimap2Result` struct (line ~238):

```swift
// MARK: - Result Persistence

private let alignmentResultFilename = "alignment-result.json"

extension Minimap2Result {
    struct PersistedAlignmentResult: Codable, Sendable {
        let schemaVersion: Int
        let bamPath: String
        let baiPath: String
        let totalReads: Int
        let mappedReads: Int
        let unmappedReads: Int
        let toolVersion: String
        let runtime: Double
        let provenanceId: UUID?
        let savedAt: Date
    }

    public func save(to directory: URL, toolVersion: String) throws {
        let sidecar = PersistedAlignmentResult(
            schemaVersion: 1,
            bamPath: bamURL.lastPathComponent,
            baiPath: baiURL.lastPathComponent,
            totalReads: totalReads,
            mappedReads: mappedReads,
            unmappedReads: unmappedReads,
            toolVersion: toolVersion,
            runtime: wallClockSeconds,
            provenanceId: UUID(),
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: directory.appendingPathComponent(alignmentResultFilename), options: .atomic)
    }

    public static func load(from directory: URL) throws -> Minimap2Result {
        let fileURL = directory.appendingPathComponent(alignmentResultFilename)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(PersistedAlignmentResult.self, from: data)
        return Minimap2Result(
            bamURL: directory.appendingPathComponent(sidecar.bamPath),
            baiURL: directory.appendingPathComponent(sidecar.baiPath),
            totalReads: sidecar.totalReads,
            mappedReads: sidecar.mappedReads,
            unmappedReads: sidecar.unmappedReads,
            wallClockSeconds: sidecar.runtime
        )
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(alignmentResultFilename).path
        )
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "SPAdesResultSidecarTests|Minimap2ResultSidecarTests" 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift Tests/LungfishWorkflowTests/Assembly/SPAdesResultSidecarTests.swift Tests/LungfishWorkflowTests/Alignment/Minimap2ResultSidecarTests.swift
git commit -m "feat: add result sidecar persistence for SPAdes and Minimap2

assembly-result.json and alignment-result.json follow the same pattern
as esviritu-result.json and classification-result.json."
```

---

## Task 5: Config summaryParameters() Methods

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift` (SPAdesAssemblyConfig)
- Modify: `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift` (Minimap2Config)
- Create: `Tests/LungfishWorkflowTests/Metagenomics/ConfigSummaryParametersTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LungfishWorkflowTests/Metagenomics/ConfigSummaryParametersTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO  // for AnalysisParameterValue

final class ConfigSummaryParametersTests: XCTestCase {

    func testEsVirituConfigSummary() throws {
        let config = EsVirituConfig(
            inputFiles: [URL(fileURLWithPath: "/tmp/r1.fq")],
            isPairedEnd: false,
            sampleName: "SRR123",
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            databasePath: URL(fileURLWithPath: "/db"),
            qualityFilter: true,
            minReadLength: 50,
            threads: 4
        )
        let params = config.summaryParameters()
        XCTAssertEqual(params["sampleName"]?.stringValue, "SRR123")
        XCTAssertEqual(params["qualityFilter"]?.boolValue, true)
        XCTAssertEqual(params["minReadLength"]?.intValue, 50)
        // Should not contain paths
        XCTAssertNil(params["outputDirectory"])
        XCTAssertNil(params["databasePath"])
    }

    func testClassificationConfigSummary() throws {
        let config = try ClassificationConfig.parse([
            // Use parse or direct init — adapt to whatever the config requires
        ])
        // If direct init is complex, test via a known fixture config instead
        // The key assertion: parameters include database, confidence, minimumHitGroups
        // but NOT paths
    }

    func testMinimap2ConfigSummary() {
        let config = Minimap2Config(
            inputFiles: [URL(fileURLWithPath: "/tmp/r1.fq")],
            referenceURL: URL(fileURLWithPath: "/tmp/ref.fa"),
            preset: .shortRead,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            sampleName: "sample1"
        )
        let params = config.summaryParameters()
        XCTAssertEqual(params["preset"]?.stringValue, "sr")
        XCTAssertEqual(params["sampleName"]?.stringValue, "sample1")
        XCTAssertNil(params["referenceURL"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigSummaryParametersTests 2>&1 | tail -5`
Expected: Compilation error — `summaryParameters()` not defined.

- [ ] **Step 3: Implement summaryParameters() on each config**

Add to `EsVirituConfig.swift`:
```swift
import LungfishIO  // for AnalysisParameterValue

extension EsVirituConfig {
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        var params: [String: AnalysisParameterValue] = [
            "sampleName": .string(sampleName),
            "qualityFilter": .bool(qualityFilter),
            "minReadLength": .int(minReadLength),
            "threads": .int(threads),
            "isPairedEnd": .bool(isPairedEnd),
        ]
        return params
    }
}
```

Add to `ClassificationConfig.swift`:
```swift
import LungfishIO

extension ClassificationConfig {
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "goal": .string(goal.rawValue),
            "database": .string(databaseName),
            "confidence": .double(confidence),
            "minimumHitGroups": .int(minimumHitGroups),
            "threads": .int(threads),
            "memoryMapping": .bool(memoryMapping),
        ]
    }
}
```

Add to `TaxTriageConfig.swift` (adapt field names to actual struct):
```swift
import LungfishIO

extension TaxTriageConfig {
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "database": .string(database),
            "threads": .int(threads),
        ]
    }
}
```

Add to `SPAdesAssemblyConfig` in `SPAdesAssemblyPipeline.swift`:
```swift
import LungfishIO

extension SPAdesAssemblyConfig {
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "mode": .string(mode.rawValue),
            "threads": .int(threads),
            "memoryGB": .int(memoryGB),
            "minContigLength": .int(minContigLength),
            "careful": .bool(careful),
        ]
    }
}
```

Add to `Minimap2Config` in `Minimap2Pipeline.swift`:
```swift
import LungfishIO

extension Minimap2Config {
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "preset": .string(preset.rawValue),
            "sampleName": .string(sampleName),
            "threads": .int(threads),
            "isPairedEnd": .bool(isPairedEnd),
        ]
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ConfigSummaryParametersTests 2>&1 | tail -10`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "feat: add summaryParameters() to all analysis config types

Returns key parameters suitable for display in the Inspector analysis
history section. Excludes paths and internal-only fields."
```

---

## Task 6: Sidebar Reload Bug Fix

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

- [ ] **Step 1: Add reloadFromFilesystem() to single-sample EsViritu**

In `AppDelegate.swift`, find `runEsViritu(config:viewerController:)` (line ~5097). In the success completion handler (the `DispatchQueue.main.async { MainActor.assumeIsolated {` block around line 5183), add after the `displayEsVirituResult` call:

```swift
                        viewerController.displayEsVirituResult(capturedResult, config: capturedConfig)
                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.mainWindowController?.mainSplitViewController?
                            .sidebarController.reloadFromFilesystem()
```

- [ ] **Step 2: Add reloadFromFilesystem() to single-sample Kraken2**

In `runClassification(config:viewerController:)` (line ~4941). In the success handler (around line 5038), add after `displayTaxonomyResult`:

```swift
                        viewerController.displayTaxonomyResult(result)
                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.mainWindowController?.mainSplitViewController?
                            .sidebarController.reloadFromFilesystem()
```

- [ ] **Step 3: Add reloadFromFilesystem() to single-sample TaxTriage**

In `runTaxTriage(config:viewerController:)` (line ~5695). In the success handler (around line 5760), add after `BatchRunHistory.recordRun`:

```swift
                        BatchRunHistory.recordRun(result: capturedResult, config: capturedConfig)
                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.mainWindowController?.mainSplitViewController?
                            .sidebarController.reloadFromFilesystem()
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift
git commit -m "fix: add sidebar reload after single-sample EsViritu, Kraken2, and TaxTriage runs

Batch variants already called reloadFromFilesystem() but single-sample
paths did not, causing result bundles to not appear in the sidebar until
the next manual refresh."
```

---

## Task 7: Redirect Pipeline Output to Analyses/

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`

- [ ] **Step 1: Override output directory in AppDelegate.runEsViritu (single-sample)**

In `AppDelegate.runEsViritu(config:viewerController:)`, before the `Task.detached` block (around line 5110), add logic to redirect the output directory. The key change: instead of using the config's outputDirectory (which points to `derivatives/`), create an analysis directory in `Analyses/`:

```swift
    private func runEsViritu(config: EsVirituConfig, viewerController: ViewerViewController) {
        // Redirect output to project-level Analyses/ folder
        var config = config
        if let projectURL = mainWindowController?.mainSplitViewController?.sidebarController.currentProjectURL {
            if let analysisDir = try? AnalysesFolder.createAnalysisDirectory(
                tool: "esviritu", in: projectURL
            ) {
                config = EsVirituConfig(
                    inputFiles: config.inputFiles,
                    isPairedEnd: config.isPairedEnd,
                    sampleName: config.sampleName,
                    outputDirectory: analysisDir,
                    databasePath: config.databasePath,
                    qualityFilter: config.qualityFilter,
                    minReadLength: config.minReadLength,
                    threads: config.threads
                )
            }
        }
        // ... rest of method unchanged
```

**Important:** The config struct must be re-created because `outputDirectory` is `let`, not `var`. Look at the actual init parameters and adapt. If `EsVirituConfig` has more fields than shown here, include them all.

- [ ] **Step 2: Override output directory in AppDelegate.runClassification (single-sample)**

Same pattern for `runClassification(config:viewerController:)`. Create the analysis directory and reconstruct the config with the new output path.

- [ ] **Step 3: Override output directory in AppDelegate.runTaxTriage**

Same pattern for `runTaxTriage(config:viewerController:)`.

- [ ] **Step 4: Override output in batch methods**

For `runEsVirituBatch` and `runClassificationBatch`, the batch root directory also needs to point to `Analyses/`. Use `AnalysesFolder.createAnalysisDirectory(tool:in:isBatch:true)`.

- [ ] **Step 5: Override SPAdes assembly output**

In the SPAdes run method (around line 4064), change:
```swift
// OLD:
outputDirectory = projectURL.appendingPathComponent("Assemblies", isDirectory: true)
// NEW:
outputDirectory = try? AnalysesFolder.createAnalysisDirectory(tool: "spades", in: projectURL)
```

- [ ] **Step 6: Override Minimap2 output**

In the minimap2 run method, similarly redirect to `Analyses/`.

- [ ] **Step 7: Record manifest entries after each pipeline completes**

In each single-sample completion handler (EsViritu, Kraken2, TaxTriage), after the pipeline completes and the sidecar is saved, add manifest recording. You need access to the source FASTQ bundle URL — check if it's available from the config or needs to be threaded through.

For EsViritu (in the success handler):
```swift
// Record in analysis manifest
if let bundleURL = config.inputFiles.first?.deletingLastPathComponent() {
    let entry = AnalysisManifestEntry(
        tool: "esviritu",
        analysisDirectoryName: config.outputDirectory.lastPathComponent,
        displayName: "EsViritu Detection",
        parameters: config.summaryParameters(),
        summary: "\(capturedResult.detections.count) viruses detected in \(capturedResult.detectedFamilyCount) families",
        status: .completed
    )
    try? AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
}
```

Similar patterns for Kraken2 and TaxTriage.

- [ ] **Step 8: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 9: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift
git commit -m "feat: redirect all analysis outputs to project-level Analyses/ folder

EsViritu, Kraken2, TaxTriage, SPAdes, and Minimap2 now write results to
Analyses/tool-timestamp/ directories. Each completion records an entry
in the source FASTQ bundle's analyses-manifest.json."
```

---

## Task 8: Sidebar Analyses/ Scanning

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Create: `Tests/LungfishIntegrationTests/AnalysesSidebarTests.swift`

- [ ] **Step 1: Write failing test for collectAnalyses()**

Create `Tests/LungfishIntegrationTests/AnalysesSidebarTests.swift`:

```swift
import XCTest
@testable import LungfishIO

final class AnalysesSidebarTests: XCTestCase {
    func testListAnalysesWithFixtures() throws {
        let project = try TestAnalysisFixtures.createTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let analyses = try AnalysesFolder.listAnalyses(in: project)
        // 5 single + 1 batch = 6 directories
        XCTAssertEqual(analyses.count, 6)

        let tools = Set(analyses.map(\.tool))
        XCTAssertTrue(tools.contains("esviritu"))
        XCTAssertTrue(tools.contains("kraken2"))
        XCTAssertTrue(tools.contains("taxtriage"))
        XCTAssertTrue(tools.contains("spades"))
        XCTAssertTrue(tools.contains("minimap2"))

        // Verify sorted newest first
        for i in 0..<(analyses.count - 1) {
            XCTAssertGreaterThanOrEqual(analyses[i].timestamp, analyses[i + 1].timestamp)
        }
    }

    func testBatchDetection() throws {
        let project = try TestAnalysisFixtures.createTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let analyses = try AnalysesFolder.listAnalyses(in: project)
        let batches = analyses.filter(\.isBatch)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.tool, "esviritu")
    }
}
```

- [ ] **Step 2: Run test to verify it passes (AnalysesFolder already exists)**

Run: `swift test --filter AnalysesSidebarTests 2>&1 | tail -10`
Expected: PASS (this uses the already-implemented AnalysesFolder).

- [ ] **Step 3: Add `analysisResult` to SidebarItemType**

In `SidebarViewController.swift` (line ~2929), add:
```swift
    case analysisResult  // Analysis result in Analyses/ folder
```

- [ ] **Step 4: Add collectAnalyses() method**

In `SidebarViewController.swift`, add a new method:

```swift
    /// Scans the project's `Analyses/` folder for result directories and builds
    /// a flat list of sidebar items sorted by timestamp (newest first).
    private func collectAnalyses(in projectURL: URL) -> [SidebarItem] {
        guard let analyses = try? AnalysesFolder.listAnalyses(in: projectURL) else { return [] }

        return analyses.compactMap { info in
            // Skip in-progress analyses
            guard !OperationMarker.isInProgress(info.url) else { return nil }

            let icon = analysisIcon(for: info.tool)
            let title = analysisDisplayTitle(for: info)

            return SidebarItem(
                title: title,
                type: .analysisResult,
                icon: icon,
                children: [],
                url: info.url,
                subtitle: AnalysesFolder.formatTimestamp(info.timestamp)
            )
        }
    }

    private func analysisIcon(for tool: String) -> String {
        switch tool {
        case "esviritu": return "e.circle"
        case "kraken2": return "k.circle"
        case "taxtriage": return "t.circle"
        case "spades", "megahit": return "s.circle"
        case "minimap2": return "m.circle"
        case "naomgs": return "n.circle"
        default: return "circle"
        }
    }

    private func analysisDisplayTitle(for info: AnalysesFolder.AnalysisDirectoryInfo) -> String {
        let toolName: String
        switch info.tool {
        case "esviritu": toolName = "EsViritu"
        case "kraken2": toolName = "Kraken2"
        case "taxtriage": toolName = "TaxTriage"
        case "spades": toolName = "SPAdes"
        case "minimap2": toolName = "Minimap2"
        case "naomgs": toolName = "NAO-MGS"
        default: toolName = info.tool.capitalized
        }
        return info.isBatch ? "\(toolName) Batch" : toolName
    }
```

- [ ] **Step 5: Replace derivatives/ analysis scanning with Analyses/ scanning**

In `buildSidebarTree(from:isRoot:)` (around lines 940-965), remove the analysis-specific scanning from the FASTQ bundle children loop. Replace the block that scans `derivatives/` for classification, esviritu, taxtriage, naomgs, and nvd results.

Replace lines 940-965:
```swift
            // OLD: Scan for classification/esviritu/taxtriage/naomgs/nvd results
            // inside the bundle and its derivatives/.
```

with nothing — analysis results no longer live inside FASTQ bundles.

Then, in `buildRootItems(from:)`, add an "Analyses" group node:

```swift
    private func buildRootItems(from projectURL: URL) -> [SidebarItem] {
        // ... existing code ...

        // Add Analyses group if the directory exists
        let analysesChildren = collectAnalyses(in: projectURL)
        if !analysesChildren.isEmpty {
            let analysesGroup = SidebarItem(
                title: "Analyses",
                type: .folder,
                icon: "flask",
                children: analysesChildren,
                url: projectURL.appendingPathComponent(AnalysesFolder.directoryName)
            )
            items.insert(analysesGroup, at: 0) // top of the list
        }

        return items
    }
```

- [ ] **Step 6: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Tests/LungfishIntegrationTests/AnalysesSidebarTests.swift
git commit -m "feat: add Analyses/ scanning to sidebar, replace derivatives/ analysis scanning

New flat 'Analyses' group at top of sidebar. Analysis results no longer
appear nested under FASTQ bundles. FASTQ-to-FASTQ derivatives (trim,
filter, demux) remain under bundles."
```

---

## Task 9: Inspector Analysis History Section

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

- [ ] **Step 1: Create AnalysesSection view**

Create `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`:

```swift
import SwiftUI
import LungfishIO

/// Inspector section showing analysis history for a FASTQ bundle.
struct AnalysesSection: View {
    let analyses: [AnalysisManifestEntry]
    var onNavigate: ((AnalysisManifestEntry) -> Void)?

    var body: some View {
        Section {
            if analyses.isEmpty {
                Text("No analyses performed yet. Use the Operations panel to run classifications, assemblies, or alignments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(analyses) { entry in
                    AnalysisRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onNavigate?(entry)
                        }
                }
            }
        } header: {
            HStack {
                Text("Analyses")
                if !analyses.isEmpty {
                    Text("(\(analyses.count))")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AnalysisRow: View {
    let entry: AnalysisManifestEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon)
                .foregroundStyle(toolColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.displayName)
                        .font(.body)
                    Spacer()
                    Text(relativeTimestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(absoluteTimestamp)
                }
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !entry.parameters.isEmpty {
                    Text(parameterSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var toolIcon: String {
        switch entry.tool {
        case "esviritu": return "e.circle.fill"
        case "kraken2": return "k.circle.fill"
        case "taxtriage": return "t.circle.fill"
        case "spades", "megahit": return "s.circle.fill"
        case "minimap2": return "m.circle.fill"
        default: return "circle.fill"
        }
    }

    private var toolColor: Color {
        switch entry.tool {
        case "esviritu": return .green
        case "kraken2": return .blue
        case "taxtriage": return .purple
        case "spades", "megahit": return .orange
        case "minimap2": return .teal
        default: return .gray
        }
    }

    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.timestamp, relativeTo: Date())
    }

    private var absoluteTimestamp: String {
        entry.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    private var parameterSummary: String {
        entry.parameters
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                switch value {
                case .string(let v): return "\(key): \(v)"
                case .int(let v): return "\(key): \(v)"
                case .double(let v): return "\(key): \(String(format: "%.1f", v))"
                case .bool(let v): return "\(key): \(v ? "yes" : "no")"
                }
            }
            .joined(separator: ", ")
    }
}
```

- [ ] **Step 2: Add analyses data to DocumentSectionViewModel**

In `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`, add to `DocumentSectionViewModel`:

```swift
    // MARK: - Analyses History
    var analysisManifestEntries: [AnalysisManifestEntry] = []
    var projectURL: URL?

    func updateAnalysisManifest(bundleURL: URL?, projectURL: URL?) {
        self.projectURL = projectURL
        guard let bundleURL, let projectURL else {
            analysisManifestEntries = []
            return
        }
        let manifest = AnalysisManifestStore.load(bundleURL: bundleURL, projectURL: projectURL)
        analysisManifestEntries = manifest.analyses.sorted { $0.timestamp > $1.timestamp }
    }
```

- [ ] **Step 3: Wire AnalysesSection into DocumentSection view**

In the `DocumentSection` SwiftUI view (wherever the section body is defined), add the `AnalysesSection` after the existing sections:

```swift
    AnalysesSection(
        analyses: viewModel.analysisManifestEntries,
        onNavigate: { entry in
            // Navigate to analysis result — will be wired to viewer controller
            viewModel.navigateToAnalysis?(entry)
        }
    )
```

Add a navigation callback to `DocumentSectionViewModel`:
```swift
    var navigateToAnalysis: ((AnalysisManifestEntry) -> Void)?
```

- [ ] **Step 4: Wire InspectorViewController to update analyses on bundle selection**

In `InspectorViewController.swift`, find where `documentSectionViewModel` is updated when a FASTQ bundle is selected. Add:

```swift
documentSectionViewModel.updateAnalysisManifest(
    bundleURL: bundleURL,
    projectURL: sidebarController?.currentProjectURL
)
```

- [ ] **Step 5: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift Sources/LungfishApp/Views/Inspector/InspectorViewController.swift
git commit -m "feat: add Analyses history section to FASTQ Inspector

Shows analysis history with tool icons, timestamps, summaries, and
parameters. Clicking an entry navigates to the analysis result."
```

---

## Task 10: Migration from derivatives/ to Analyses/

**Files:**
- Create: `Sources/LungfishIO/Bundles/AnalysesMigration.swift`
- Create: `Tests/LungfishIntegrationTests/AnalysesMigrationTests.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift` (call migration on project open)

- [ ] **Step 1: Write failing migration tests**

Create `Tests/LungfishIntegrationTests/AnalysesMigrationTests.swift`:

```swift
import XCTest
@testable import LungfishIO

final class AnalysesMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-migration-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMigrateEsVirituFromDerivatives() throws {
        // Set up: bundle with derivatives/esviritu-abc123/esviritu-result.json
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("esviritu-abc123")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)

        // Copy fixture sidecar
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.esvirituResult
                .appendingPathComponent("esviritu-result.json"),
            to: derivDir.appendingPathComponent("esviritu-result.json")
        )

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 1)

        // Verify moved to Analyses/
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "esviritu")

        // Verify original removed from derivatives
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivDir.path))

        // Verify manifest created in bundle
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: tempDir)
        XCTAssertEqual(manifest.analyses.count, 1)
    }

    func testMigrateDoesNotMoveFASTQDerivatives() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let fastqDeriv = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("trimmed.lungfishfastq")
        try FileManager.default.createDirectory(at: fastqDeriv, withIntermediateDirectories: true)

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 0)

        // FASTQ derivative still in place
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastqDeriv.path))
    }

    func testMigrateIsIdempotent() throws {
        // Already has Analyses/ — should not duplicate
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true
        )

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnalysesMigrationTests 2>&1 | tail -10`
Expected: Compilation error — `AnalysesMigration` not defined.

- [ ] **Step 3: Implement AnalysesMigration**

Create `Sources/LungfishIO/Bundles/AnalysesMigration.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.lungfish.browser", category: "AnalysesMigration")

/// Migrates analysis results from the legacy `derivatives/` location
/// inside FASTQ bundles to the project-level `Analyses/` folder.
public enum AnalysesMigration {

    /// Analysis directory prefixes that should be migrated.
    private static let analysisPrefixes = [
        "classification-", "esviritu-", "taxtriage-",
        "naomgs-", "nvd-",
    ]

    /// Tool name extracted from a directory prefix.
    private static func toolForPrefix(_ prefix: String) -> String {
        switch prefix {
        case "classification-": return "kraken2"
        case "esviritu-": return "esviritu"
        case "taxtriage-": return "taxtriage"
        case "naomgs-": return "naomgs"
        case "nvd-": return "nvd"
        default: return prefix.replacingOccurrences(of: "-", with: "")
        }
    }

    /// Scans all FASTQ bundles in the project for analysis results in `derivatives/`
    /// and moves them to `Analyses/`.
    ///
    /// - Returns: Number of directories migrated.
    @discardableResult
    public static func migrateProject(at projectURL: URL) throws -> Int {
        let fm = FileManager.default
        var migratedCount = 0

        // Find all .lungfishfastq bundles
        guard let projectContents = try? fm.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for bundleURL in projectContents {
            guard bundleURL.pathExtension.lowercased() == "lungfishfastq" else { continue }

            let derivativesDir = bundleURL.appendingPathComponent("derivatives")
            guard fm.fileExists(atPath: derivativesDir.path) else { continue }

            guard let derivContents = try? fm.contentsOfDirectory(
                at: derivativesDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for childURL in derivContents {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let name = childURL.lastPathComponent

                // Check if this is an analysis directory (not a .lungfishfastq derivative)
                guard let matchedPrefix = analysisPrefixes.first(where: { name.hasPrefix($0) }) else {
                    continue
                }

                // Determine timestamp from sidecar's savedAt field
                let timestamp = extractTimestamp(from: childURL) ?? Date()
                let tool = toolForPrefix(matchedPrefix)
                let newDirName = "\(tool)-\(AnalysesFolder.formatTimestamp(timestamp))"

                // Move to Analyses/
                let analysesDir = try AnalysesFolder.url(for: projectURL)
                let destination = analysesDir.appendingPathComponent(newDirName)

                guard !fm.fileExists(atPath: destination.path) else {
                    logger.info("Migration: \(newDirName) already exists, skipping")
                    continue
                }

                try fm.moveItem(at: childURL, to: destination)
                logger.info("Migrated \(name) -> Analyses/\(newDirName, privacy: .public)")

                // Record in analysis manifest
                let entry = AnalysisManifestEntry(
                    tool: tool,
                    timestamp: timestamp,
                    analysisDirectoryName: newDirName,
                    displayName: displayName(for: tool),
                    summary: "Migrated from derivatives/"
                )
                try? AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)

                migratedCount += 1
            }
        }

        if migratedCount > 0 {
            logger.info("Migration complete: moved \(migratedCount) analysis directories to Analyses/")
        }
        return migratedCount
    }

    // MARK: - Private

    private static func extractTimestamp(from analysisDir: URL) -> Date? {
        // Try to read savedAt from known sidecar files
        let sidecarNames = [
            "esviritu-result.json",
            "classification-result.json",
            "taxtriage-result.json",
        ]
        for name in sidecarNames {
            let sidecarURL = analysisDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: sidecarURL) else { continue }
            // Quick extraction of savedAt field
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let savedAtString = json["savedAt"] as? String {
                let formatter = ISO8601DateFormatter()
                return formatter.date(from: savedAtString)
            }
        }
        return nil
    }

    private static func displayName(for tool: String) -> String {
        switch tool {
        case "esviritu": return "EsViritu Detection"
        case "kraken2": return "Kraken2 Classification"
        case "taxtriage": return "TaxTriage Analysis"
        case "naomgs": return "NAO-MGS Import"
        case "nvd": return "NVD Analysis"
        default: return tool.capitalized
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnalysesMigrationTests 2>&1 | tail -10`
Expected: All PASS.

- [ ] **Step 5: Wire migration into project open**

In `AppDelegate.swift`, find where the project is opened/loaded and the sidebar is populated. Add a migration call before the sidebar reload:

```swift
// In the project open path, before reloadFromFilesystem():
if let projectURL = sidebarController?.currentProjectURL {
    try? AnalysesMigration.migrateProject(at: projectURL)
}
```

The exact location depends on how projects are opened — search for `reloadFromFilesystem` calls in the project-open flow.

- [ ] **Step 6: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishIO/Bundles/AnalysesMigration.swift Tests/LungfishIntegrationTests/AnalysesMigrationTests.swift Sources/LungfishApp/App/AppDelegate.swift
git commit -m "feat: auto-migrate analysis results from derivatives/ to Analyses/ on project open

Scans FASTQ bundles for legacy classification/esviritu/taxtriage/naomgs/nvd
directories in derivatives/, moves them to Analyses/ with timestamp naming,
and creates analyses-manifest.json entries."
```

---

## Task 11: Create Feature Branch and Run Full Test Suite

- [ ] **Step 1: Create feature branch**

```bash
git checkout -b feature/analyses-folder-and-inspector
```

Note: This should actually be done FIRST before any implementation. If following this plan in order, cherry-pick all commits onto the new branch, or start the branch before Task 1.

- [ ] **Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass including new ones. Watch for:
- Existing tests that relied on analysis results being in `derivatives/`
- Import errors from `AnalysisParameterValue` being in LungfishIO but used in LungfishWorkflow tests

- [ ] **Step 3: Fix any failures**

Address compilation or test failures. Common issues:
- Test targets that import `LungfishIO` but don't list it as a dependency in Package.swift
- Existing sidebar tests that expected classification/esviritu items under FASTQ bundles
- Config tests that need the new `summaryParameters()` import

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "fix: resolve test failures from Analyses folder migration"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Part 1: Sidebar reload bug fix → Task 6
- [x] Part 2.1-2.3: AnalysesFolder → Task 2
- [x] Part 2.4: SPAdes/Minimap2 sidecars → Task 4
- [x] Part 2.5: Pipeline output directory changes → Task 7
- [x] Part 3: Analysis manifest → Task 3
- [x] Part 4: Inspector section → Task 9
- [x] Part 5: Sidebar changes → Task 8
- [x] Part 6: Migration → Task 10
- [x] Test fixtures → Task 1
- [x] Config summaryParameters → Task 5

**Placeholder scan:** No TBDs, TODOs, or "implement later" found.

**Type consistency:**
- `AnalysesFolder` used consistently across Tasks 2, 3, 7, 8, 10
- `AnalysisManifestEntry` / `AnalysisManifestStore` used consistently across Tasks 3, 7, 9, 10
- `AnalysisParameterValue` used in Tasks 3, 5, 9 (replacing `AnyCodableValue`)
- `summaryParameters()` returns `[String: AnalysisParameterValue]` consistently
- `SPAdesAssemblyResult.save/load/exists` and `Minimap2Result.save/load/exists` follow same pattern
