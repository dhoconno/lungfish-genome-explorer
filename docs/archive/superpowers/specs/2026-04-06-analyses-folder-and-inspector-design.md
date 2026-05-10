# Analyses Folder, Bundle Persistence Fixes, and Inspector Integration

**Date:** 2026-04-06
**Status:** Draft

## Problem Statement

Three interrelated issues:

1. **EsViritu (and Kraken2) single-sample bundle persistence regression** — pipelines write result sidecars correctly, but the sidebar never rescans after single-sample runs complete. Batch paths call `reloadFromFilesystem()` but single-sample paths do not.

2. **Analysis results stored inside FASTQ bundles' `derivatives/` folder** — classification/assembly/alignment outputs are co-located with FASTQ-to-FASTQ transforms (trim, filter, demux). This conflates two different concerns. The sidebar exposes raw folder contents rather than curated bundle views.

3. **No analysis history in FASTQ Inspector** — users cannot see which analyses have been run on a FASTQ dataset, when they ran, what parameters were used, or navigate to the results.

## Design

### Part 1: Sidebar Reload Bug Fix

**Root cause:** `AppDelegate.runEsViritu(config:viewerController:)` (line ~5190) and `AppDelegate.runClassification(config:viewerController:)` (line ~5047) do not call `sidebarController.reloadFromFilesystem()` after pipeline completion. The batch variants (`runEsVirituBatch`, `runClassificationBatch`) do.

**Fix:** Add `reloadFromFilesystem()` calls in both single-sample completion handlers, matching the batch pattern:

```swift
AppDelegate.shared?.mainWindowController?.mainSplitViewController?
    .sidebarController.reloadFromFilesystem()
```

Also fix `runTaxTriage` (single-sample, line ~5775) which has the same missing reload.

### Part 2: Analyses/ Folder Structure

#### 2.1 New Top-Level Folder

A new `Analyses/` folder at the project root, managed by an `AnalysesFolder` class in LungfishIO (parallel to `ReferenceSequenceFolder`).

```
project.lungfish/
├── Analyses/
│   ├── esviritu-2026-04-06T14-30-00/
│   │   ├── esviritu-result.json
│   │   ├── SRR35517702.detected_virus.info.tsv
│   │   ├── SRR35517702.tax_profile.tsv
│   │   ├── SRR35517702.virus_coverage_windows.tsv
│   │   └── .lungfish-provenance.json
│   ├── kraken2-2026-04-06T15-00-00/
│   │   ├── classification-result.json
│   │   ├── reads.kreport
│   │   ├── reads.kraken
│   │   └── reads.bracken
│   ├── minimap2-2026-04-07T09-15-00/
│   │   ├── alignment-result.json          (NEW sidecar)
│   │   ├── sample.sorted.bam
│   │   └── sample.sorted.bam.bai
│   └── spades-2026-04-07T10-00-00/
│       ├── assembly-result.json           (NEW sidecar)
│       ├── contigs.fasta
│       ├── scaffolds.fasta
│       └── spades.log
├── Downloads/
├── Imports/
├── Reference Sequences/
├── .tmp/
└── sample.lungfishfastq/
    ├── reads.fastq
    ├── derived.manifest.json
    ├── analyses-manifest.json             (NEW)
    └── derivatives/
        ├── length-filtered.lungfishfastq/
        └── demux/
```

#### 2.2 Folder Naming Convention

```
Analyses/{tool}-{ISO8601-timestamp}/
```

Where:
- `{tool}` is the lowercase tool/workflow name: `esviritu`, `kraken2`, `taxtriage`, `minimap2`, `spades`, `megahit`, `naomgs`
- `{ISO8601-timestamp}` is `yyyy-MM-dd'T'HH-mm-ss` (colons replaced with dashes for filesystem safety)
- Example: `esviritu-2026-04-06T14-30-00`

For batch runs:
```
Analyses/{tool}-batch-{ISO8601-timestamp}/
    ├── {tool}-batch-manifest.json
    ├── {tool}-batch-summary.tsv
    ├── {sampleId1}/
    │   └── {tool}-result.json + outputs
    └── {sampleId2}/
        └── {tool}-result.json + outputs
```

#### 2.3 AnalysesFolder Manager (LungfishIO)

```swift
public final class AnalysesFolder: Sendable {
    public static let directoryName = "Analyses"

    /// Returns the Analyses/ URL for a project, creating the directory if needed.
    public static func url(for projectURL: URL) throws -> URL

    /// Creates a new timestamped analysis subdirectory.
    /// Returns e.g. .../Analyses/esviritu-2026-04-06T14-30-00/
    public static func createAnalysisDirectory(
        tool: String,
        in projectURL: URL,
        date: Date = Date()
    ) throws -> URL

    /// Lists all analysis directories in the project.
    public static func listAnalyses(in projectURL: URL) throws -> [AnalysisDirectoryInfo]

    /// Describes a discovered analysis directory.
    public struct AnalysisDirectoryInfo: Sendable {
        public let url: URL
        public let tool: String
        public let timestamp: Date
        public let isBatch: Bool
    }
}
```

#### 2.4 New Result Sidecars for SPAdes and Minimap2

SPAdes and Minimap2 currently have no result sidecars. Add:

**`assembly-result.json`** (SPAdes/MEGAHIT):
```json
{
    "schemaVersion": 1,
    "config": { /* SPAdesAssemblyConfig */ },
    "contigsPath": "contigs.fasta",
    "scaffoldsPath": "scaffolds.fasta",
    "graphPath": "assembly_graph.gfa",
    "logPath": "spades.log",
    "statistics": { "totalContigs": 42, "n50": 15000, "totalLength": 29903 },
    "toolVersion": "3.15.5",
    "runtime": 123.4,
    "provenanceId": "...",
    "savedAt": "2026-04-06T14:30:00Z"
}
```

**`alignment-result.json`** (Minimap2):
```json
{
    "schemaVersion": 1,
    "config": { /* Minimap2Config */ },
    "bamPath": "sample.sorted.bam",
    "baiPath": "sample.sorted.bam.bai",
    "totalReads": 10000,
    "mappedReads": 9500,
    "unmappedReads": 500,
    "toolVersion": "2.28",
    "runtime": 45.2,
    "provenanceId": "...",
    "savedAt": "2026-04-06T14:30:00Z"
}
```

Follow the existing encoding conventions: `.prettyPrinted`, `.sortedKeys`, ISO8601 dates, relative filenames.

Make `SPAdesAssemblyResult` and `Minimap2Result` Codable and add `save(to:)` / `load(from:)` / `exists(in:)` methods matching the EsViritu/Classification pattern.

#### 2.5 Pipeline Output Directory Changes

Each pipeline's run method must be updated to write results to `Analyses/` instead of `derivatives/`:

| Pipeline | Current Output Location | New Output Location |
|----------|------------------------|---------------------|
| EsViritu | `bundle.lungfishfastq/derivatives/esviritu-{uuid}/` | `project/Analyses/esviritu-{timestamp}/` |
| Kraken2 | `bundle.lungfishfastq/derivatives/classification-{uuid}/` | `project/Analyses/kraken2-{timestamp}/` |
| TaxTriage | `bundle.lungfishfastq/derivatives/taxtriage-{uuid}/` | `project/Analyses/taxtriage-{timestamp}/` |
| SPAdes | `project/Assemblies/` | `project/Analyses/spades-{timestamp}/` |
| Minimap2 | Caller-specified | `project/Analyses/minimap2-{timestamp}/` |

The `AppDelegate` run methods construct the output directory. Change them to call `AnalysesFolder.createAnalysisDirectory(tool:in:)` instead of creating directories inside `derivatives/` or `Assemblies/`.

### Part 3: Analysis Manifest in FASTQ Bundles

#### 3.1 Manifest File

Each `.lungfishfastq` bundle gets an `analyses-manifest.json` that records which analyses have been performed using this dataset as input.

```json
{
    "schemaVersion": 1,
    "analyses": [
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "tool": "esviritu",
            "timestamp": "2026-04-06T14:30:00Z",
            "analysisDirectoryName": "esviritu-2026-04-06T14-30-00",
            "displayName": "EsViritu Detection",
            "parameters": {
                "sampleName": "SRR35517702",
                "minReads": 10,
                "minCoverage": 1.0
            },
            "summary": "3 viruses detected in 2 families",
            "status": "completed"
        },
        {
            "id": "660e8400-e29b-41d4-a716-446655440001",
            "tool": "kraken2",
            "timestamp": "2026-04-06T15:00:00Z",
            "analysisDirectoryName": "kraken2-2026-04-06T15-00-00",
            "displayName": "Kraken2 Classification",
            "parameters": {
                "database": "standard",
                "confidenceThreshold": 0.0,
                "minimumHitGroups": 2
            },
            "summary": "8500 of 10000 reads classified",
            "status": "completed"
        }
    ]
}
```

#### 3.2 AnalysisManifest Manager (LungfishIO)

```swift
public struct AnalysisManifestEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let tool: String
    public let timestamp: Date
    public let analysisDirectoryName: String
    public let displayName: String
    public let parameters: [String: AnyCodableValue /* from LungfishWorkflow/Recipes/Recipe.swift */]
    public let summary: String
    public let status: AnalysisStatus

    public enum AnalysisStatus: String, Codable, Sendable {
        case completed
        case failed
    }
}

public struct AnalysisManifest: Codable, Sendable {
    public static let filename = "analyses-manifest.json"
    public var schemaVersion: Int = 1
    public var analyses: [AnalysisManifestEntry]
}

public final class AnalysisManifestStore: Sendable {
    /// Load the manifest for a FASTQ bundle, pruning entries whose
    /// analysis directories no longer exist on disk.
    public static func load(
        bundleURL: URL,
        projectURL: URL
    ) -> AnalysisManifest

    /// Append a new analysis entry and save atomically.
    public static func recordAnalysis(
        _ entry: AnalysisManifestEntry,
        bundleURL: URL
    ) throws

    /// Remove entries whose analysis directories are missing, re-save.
    /// Called lazily on load.
    public static func pruneStaleEntries(
        manifest: inout AnalysisManifest,
        bundleURL: URL,
        projectURL: URL
    ) -> Int  // returns count of pruned entries
}
```

#### 3.3 Lazy Pruning Strategy

When `AnalysisManifestStore.load()` is called:
1. Read `analyses-manifest.json` from the bundle
2. For each entry, check if `projectURL/Analyses/{analysisDirectoryName}` exists
3. Remove entries where the directory is gone
4. If any were removed, re-save the manifest atomically
5. Return the pruned manifest

This handles deletions from Finder, CLI cleanup, etc. No background watchers or DB triggers needed.

#### 3.4 Pipeline Integration

Each pipeline completion handler in AppDelegate appends to the manifest:

```swift
// After pipeline completes and result sidecar is saved:
let entry = AnalysisManifestEntry(
    id: UUID(),
    tool: "esviritu",
    timestamp: Date(),
    analysisDirectoryName: analysisDir.lastPathComponent,
    displayName: "EsViritu Detection",
    parameters: config.summaryParameters(),
    summary: "\(result.detections.count) viruses detected",
    status: .completed
)
try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
```

Each config type gets a `summaryParameters() -> [String: AnyCodableValue /* from LungfishWorkflow/Recipes/Recipe.swift */]` method that returns the key parameters worth recording (not the full config — just what's meaningful to show in the Inspector).

### Part 4: FASTQ Inspector Analysis History Section

#### 4.1 New Inspector Section

A new "Analyses" section in the Document tab of the FASTQ Inspector, positioned after the existing metadata sections.

**Section header:** "Analyses" with a count badge (e.g., "Analyses (3)")

**Each row contains:**
- Tool icon (colored per tool: Kraken2=blue, EsViritu=green, TaxTriage=purple, etc.)
- Tool display name (e.g., "EsViritu Detection")
- Timestamp (relative: "2 hours ago", absolute on hover)
- One-line summary (e.g., "3 viruses detected in 2 families")
- Key parameters in a subdued caption style (e.g., "minReads: 10, minCoverage: 1.0")
- Clickable — clicking navigates the viewer to that analysis result

**Empty state:** "No analyses performed yet. Use the Operations panel to run classifications, assemblies, or alignments."

#### 4.2 Virtual FASTQ Inspector

Virtual FASTQ bundles (subset, trim, demux) should show their OWN analyses manifest, not the root bundle's. A trim operation + classification on the trimmed data is a separate analysis from a classification on the original data.

However, the Inspector should also show a "Source Dataset" link back to the root bundle, and note if the root bundle has analyses (e.g., "Root dataset has 3 analyses").

#### 4.3 Navigation

When the user clicks an analysis row in the Inspector:
1. Check that the analysis directory still exists (pruning if not)
2. Load the result sidecar from the analysis directory
3. Display it in the viewer using the existing `displayEsVirituResult`/`displayTaxonomyResult`/etc. methods
4. Update the sidebar selection to highlight the analysis

### Part 5: Sidebar Changes

#### 5.1 New "Analyses" Outline Group

Replace the current per-tool scanning in `derivatives/` with a single "Analyses" outline group:

- Scans `project/Analyses/` for subdirectories
- Each directory with a valid result sidecar appears as an item
- Display: tool icon + analysis display name + timestamp
- Flat list (no sub-grouping by tool type)
- Sorted by timestamp, newest first

#### 5.2 What Stays in derivatives/

The `derivatives/` folder continues to hold FASTQ-to-FASTQ transforms:
- Subset/subsample results (`.lungfishfastq` bundles)
- Trim results (`.lungfishfastq` bundles)
- Demux results (`.lungfishfastq` bundles)
- Filter results (`.lungfishfastq` bundles)

These are still scanned and displayed as FASTQ datasets in the sidebar, not as analyses.

#### 5.3 Sidebar Scanning Changes

Remove from `reloadFromFilesystem()`:
- `collectEsVirituResults()` scanning `derivatives/esviritu-*`
- `collectClassificationResults()` scanning `derivatives/classification-*`
- `collectTaxTriageResults()` scanning `derivatives/taxtriage-*`

Add:
- `collectAnalyses()` scanning `Analyses/` using `AnalysesFolder.listAnalyses()`
- For each directory, load the appropriate result sidecar to get display metadata

### Part 6: Migration Strategy

For existing projects with results in `derivatives/`:

1. On project open, scan for `derivatives/classification-*`, `derivatives/esviritu-*`, `derivatives/taxtriage-*`
2. If found, move each to `Analyses/` with the new naming convention (use the sidecar's `savedAt` date for the timestamp)
3. Create/update the `analyses-manifest.json` in the source FASTQ bundle
4. Log the migration

This is a one-time migration. After migration, `derivatives/` only contains FASTQ-to-FASTQ transforms.

Migration runs automatically on project open, before the sidebar scan. This ensures existing results appear under the new Analyses/ group immediately.

## Scope

**In scope for this implementation:**
- Bug fix: sidebar reload after single-sample EsViritu/Kraken2/TaxTriage runs
- `AnalysesFolder` manager
- `AnalysisManifest` + `AnalysisManifestStore`
- Pipeline output directory changes (EsViritu, Kraken2, TaxTriage, SPAdes, Minimap2)
- New result sidecars for SPAdes and Minimap2
- Inspector analysis history section
- Sidebar "Analyses" outline group
- Config `summaryParameters()` methods
- Migration of existing `derivatives/` analysis results to `Analyses/` on project open

**Deferred:**
- Assembly and alignment viewer integration (these pipelines may not be fully wired yet)
- Batch manifest updates for the new folder structure (batch runs follow the same pattern but may need testing)

## Testing

### Test Fixtures

Create a comprehensive set of analysis result fixtures in `Tests/Fixtures/analyses/` that mirror the exact folder structure and file formats of real analysis outputs. Each fixture contains minimal but structurally correct data — real column headers, valid JSON sidecars, and plausible (but tiny) output files.

```
Tests/Fixtures/analyses/
├── esviritu-2026-01-15T10-00-00/
│   ├── esviritu-result.json              (valid sidecar with all fields)
│   ├── testSample.detected_virus.info.tsv (real column headers, 2 rows)
│   ├── testSample.tax_profile.tsv        (real column headers, 3 rows)
│   ├── testSample.virus_coverage_windows.tsv (real column headers, 2 rows)
│   └── .lungfish-provenance.json
├── kraken2-2026-01-15T11-00-00/
│   ├── classification-result.json        (valid sidecar)
│   ├── reads.kreport                     (valid 6-column Kraken2 format, 5 rows)
│   ├── reads.kraken                      (valid per-read format, 10 rows)
│   └── reads.bracken                     (valid Bracken format, 3 rows)
├── taxtriage-2026-01-15T12-00-00/
│   ├── taxtriage-result.json             (valid sidecar)
│   └── sample_report.tsv                 (minimal report)
├── spades-2026-01-15T13-00-00/
│   ├── assembly-result.json              (valid sidecar, NEW format)
│   ├── contigs.fasta                     (2 small contigs)
│   └── spades.log                        (truncated log)
├── minimap2-2026-01-15T14-00-00/
│   ├── alignment-result.json             (valid sidecar, NEW format)
│   ├── sample.sorted.bam                 (empty/minimal BAM header only)
│   └── sample.sorted.bam.bai            (minimal index)
├── esviritu-batch-2026-01-15T15-00-00/
│   ├── esviritu-batch-manifest.json
│   ├── esviritu-batch-summary.tsv
│   ├── sample1/
│   │   ├── esviritu-result.json
│   │   └── sample1.detected_virus.info.tsv
│   └── sample2/
│       ├── esviritu-result.json
│       └── sample2.detected_virus.info.tsv
└── analyses-manifest.json                (sample manifest linking to the above)
```

A `TestAnalysisFixtures.swift` in `Tests/LungfishIntegrationTests/` provides type-safe accessors (parallel to the existing `TestFixtures.swift` for SARS-CoV-2 data):

```swift
enum TestAnalysisFixtures {
    static let fixturesRoot: URL  // Tests/Fixtures/analyses/

    // Individual analysis directories
    static var esvirituResult: URL
    static var kraken2Result: URL
    static var taxTriageResult: URL
    static var spadesResult: URL
    static var minimap2Result: URL
    static var esvirituBatchResult: URL

    // Sample manifest
    static var sampleManifest: URL

    /// Creates a temporary project directory with the fixture analyses
    /// copied into an Analyses/ folder, suitable for testing sidebar
    /// scanning, migration, Inspector loading, etc.
    static func createTempProject() throws -> URL
}
```

### Test Coverage

**AnalysesFolder (unit):**
- Directory creation, listing, timestamp parsing from folder names
- Handling of missing/corrupt directories
- Batch vs single-sample detection

**AnalysisManifestStore (unit):**
- Load/save round-trip with fixture manifest
- Append entry and verify JSON structure
- Prune stale entries (delete a fixture dir, verify entry removed on load)
- Handle missing manifest file (returns empty)
- Handle corrupt manifest file (returns empty, does not crash)

**Result Sidecar round-trips (unit):**
- EsViritu: load fixture `esviritu-result.json`, verify all fields, save and compare
- Kraken2: load fixture `classification-result.json`, verify all fields
- TaxTriage: load fixture `taxtriage-result.json`, verify all fields
- SPAdes: load/save new `assembly-result.json` format against fixture
- Minimap2: load/save new `alignment-result.json` format against fixture

**Sidebar scanning (integration):**
- `collectAnalyses()` discovers all fixture analysis directories
- Correct tool types and timestamps extracted
- Missing sidecar directories are excluded
- In-progress markers are respected

**Migration (integration):**
- Copy fixture EsViritu/Kraken2/TaxTriage dirs into a temp `derivatives/` folder
- Run migration, verify they appear in `Analyses/` with correct naming
- Verify `analyses-manifest.json` created in the FASTQ bundle with correct entries
- Verify `derivatives/` no longer contains the moved directories
- Verify FASTQ-to-FASTQ derivatives (e.g., a `.lungfishfastq` subfolder) are NOT moved

**Inspector (integration):**
- Load manifest from fixture, verify entry count and display metadata
- Navigation: clicking an entry loads the correct result type
- Prune on load: remove a fixture dir, verify stale entry is cleaned up
- Empty state: no manifest file shows empty state message

**Pipeline output directory (integration):**
- Verify pipeline writes to `Analyses/tool-timestamp/` not `derivatives/`
- Verify `analyses-manifest.json` updated after pipeline completion
- Verify sidebar reload is called after single-sample completion

**Config summaryParameters (unit):**
- Each config type returns expected parameter keys and value types
