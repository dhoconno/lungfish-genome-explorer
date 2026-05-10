# FASTQ Dataset Metadata System: Design Plan

**Date**: 2026-03-25
**Status**: Design phase
**Branch**: (not yet created)
**Scope**: LungfishIO, LungfishWorkflow, LungfishApp

---

## Table of Contents

1. [Overview](#1-overview)
2. [Expert Analysis](#2-expert-analysis)
3. [Metadata Schema](#3-metadata-schema)
4. [Storage Format and Location](#4-storage-format-and-location)
5. [UI: Metadata Editing](#5-ui-metadata-editing)
6. [UI: Bottom Drawer Tab Structure](#6-ui-bottom-drawer-tab-structure)
7. [Filtering in Batch Views](#7-filtering-in-batch-views)
8. [BLAST Results as a Drawer Facet](#8-blast-results-as-a-drawer-facet)
9. [Export with Metadata](#9-export-with-metadata)
10. [Phased Implementation](#10-phased-implementation)
11. [File Inventory](#11-file-inventory)

---

## 1. Overview

This plan adds structured metadata management to FASTQ datasets in Lungfish.
Users associate metadata (sample_name, collection_date, sample_type, etc.)
with `.lungfishfastq` bundles. Metadata drives display labels in batch views,
filtering in multi-sample analyses, and interoperability with NCBI SRA
submission and PHA4GE contextual data standards.

### Current State

- `FASTQBundleCSVMetadata` (in `Sources/LungfishIO/Formats/FASTQ/FASTQBundleCSVMetadata.swift`) already reads/writes `metadata.csv` from `.lungfishfastq` bundles in a key-value or freeform CSV format.
- `TaxTriageResultViewController` already calls `buildSampleLabelsFromCSVMetadata()` to resolve display labels from per-bundle metadata.
- `TaxTriageSample` has `sampleId`, `fastq1`, `fastq2`, `platform`, `isNegativeControl`.
- `FASTQMetadataDrawerView` is a bottom drawer with tabs: Samples, Demux, Primer Trim, Dedup. It manages barcode/demux metadata for individual FASTQ files.
- `TaxaCollectionsDrawerView` is a bottom drawer with tabs: Collections, BLAST Results. It appears in taxonomy (Kraken2) result views.
- `SampleSectionViewModel` in the Inspector handles VCF sample metadata display, editing, import/export, and filtering.
- `TaxTriageBatchOverviewView` renders organism x sample heatmap with contamination risk flagging from negative controls.

### Goals

1. Define a PHA4GE-aligned metadata schema for metagenomics FASTQ samples.
2. Store metadata in `.lungfishfastq` bundles and at folder level.
3. Edit metadata per-dataset (Inspector) and per-folder (sidebar context action).
4. Add a Samples drawer tab to metagenomics result views for filtering.
5. Support FASTQ dataset groups (nested folder structures).
6. Filter batch views (TaxTriage, Kraken2, EsViritu) by metadata facets.
7. Integrate BLAST results as a drawer tab alongside Samples and Collections.
8. Export results with attached metadata.

---

## 2. Expert Analysis

### 2.1 PHA4GE Standards Expert

PHA4GE (Public Health Alliance for Genomic Epidemiology) defines contextual
data specifications for pathogen genomics. The SARS-CoV-2 specification is the
most mature, but the principles generalize to all metagenomics:

**Core principle**: metadata fields should be machine-readable, use controlled
vocabularies where possible, and map to NCBI BioSample attributes for SRA
submission.

**Key reference documents**:
- PHA4GE SARS-CoV-2 Contextual Data Specification v1.6+
- NCBI BioSample Package: Pathogen.env.1.0 (environmental), Pathogen.cl.1.0 (clinical)
- INSDC-standard sample attributes

**Minimum required fields for clinical metagenomics**:

| Field | NCBI BioSample Attribute | Controlled Vocabulary | Required |
|-------|-------------------------|----------------------|----------|
| `sample_name` | `sample_name` | Free text | Yes |
| `sample_type` | `isolation_source` | PHA4GE: Nasopharyngeal swab, Blood, Stool, Wastewater, Environmental swab, ... | Yes |
| `collection_date` | `collection_date` | ISO 8601 (YYYY-MM-DD, YYYY-MM, YYYY) | Yes |
| `geo_loc_name` | `geo_loc_name` | ISO 3166 country:region:locality | Recommended |
| `host` | `host` | NCBI Taxonomy (e.g., Homo sapiens) | Recommended |
| `host_disease` | `host_disease` | Free text or ICD-10 | Optional |
| `purpose_of_sequencing` | `purpose_of_sequencing` | PHA4GE: Diagnostic, Surveillance, Research, ... | Recommended |
| `sequencing_instrument` | `instrument_model` | INSDC: Illumina MiSeq, ONT MinION, ... | Recommended |
| `library_strategy` | `library_strategy` | INSDC: WGS, AMPLICON, RNA-Seq, ... | Recommended |
| `sample_collected_by` | `collected_by` | Free text (lab name) | Recommended |
| `organism` | `organism` | NCBI Taxonomy name or "metagenome" | Recommended |

**Additional fields for batch analysis context**:

| Field | Purpose | Controlled Vocabulary |
|-------|---------|----------------------|
| `sample_role` | Control classification | `test_sample`, `negative_control`, `positive_control`, `environmental_control`, `extraction_blank` |
| `patient_id` | Link samples to patients | Free text (PHI-aware) |
| `run_id` | Sequencing run identifier | Free text |
| `batch_id` | Analysis batch grouping | Free text |
| `plate_position` | Well position on plate | A1-H12 format |

**Interoperability with NCBI SRA**: The metadata CSV should be exportable to
NCBI BioSample TSV format with minimal transformation. Field names should match
BioSample attributes where possible.

### 2.2 Biology End-User Expert

**Typical clinical metagenomics workflow**:

1. **Receive samples** -- 5-30 specimens per sequencing run, usually from one
   clinical site but sometimes multi-site surveillance.
2. **Assign metadata** -- Lab technician fills in a sample sheet (often Excel)
   with patient ID, collection date, sample type, and control designations.
3. **Sequence** -- Run on MiSeq/NextSeq (Illumina) or MinION/PromethION (ONT).
4. **Demultiplex** -- FASTQ files generated per sample barcode.
5. **Analyze** -- Run metagenomics pipeline (Kraken2, TaxTriage, EsViritu).
6. **Interpret** -- Filter results by sample type, look for negcon contamination,
   compare across patients/sites.
7. **Report** -- Export results with metadata for clinical records or public
   health reporting.

**How users think about controls**:
- **Negative Template Control (NTC)**: No-template control, should have zero
  reads. Any organism detected here is a contaminant.
- **Extraction Blank**: Reagent-only control. Organisms here indicate reagent
  contamination (the "kitome").
- **Positive Control**: Known organism at known concentration. Used to validate
  pipeline sensitivity.
- **Environmental Control**: Swab of equipment/surfaces. Used in outbreak
  investigations.
- **Test Sample**: The actual clinical specimen.

Users think in terms of "this run" (all samples from one sequencing run) and
"this patient" (longitudinal samples from one individual). The most common
filtering axes are: sample_role (hide controls), sample_type (only respiratory),
collection_date (date range), and geo_loc_name (site comparison).

**Batch organization patterns**:
- One folder per sequencing run (5-30 `.lungfishfastq` bundles).
- Nested folders: `Project/Run1/Sample*.lungfishfastq`, `Project/Run2/...`.
- Multi-run comparisons: select 2-3 run folders, analyze together.

### 2.3 UI/UX Expert (macOS Desktop)

**Metadata editing models**:

1. **Per-bundle editing** (Inspector): When a single `.lungfishfastq` bundle is
   selected in the sidebar, the Inspector's Document tab shows editable metadata
   fields. This follows the existing VCF `SampleSectionViewModel` pattern.

2. **Folder-level editing** (Sheet): When a folder containing multiple bundles
   is selected, a sheet or popover presents a table where each row is a bundle
   and columns are metadata fields. This is the "sample sheet" editing model.

3. **CSV import/export**: Users import metadata from an existing sample sheet
   (Excel export). The CSV must match sample names to bundle filenames.

**Bottom drawer tab structure for metagenomics views**:

The existing metagenomics drawers should converge on a unified tabbed drawer:

```
+------------------------------------------------------------------+
| [===== Drag Handle =====]                                         |
+------------------------------------------------------------------+
| [Samples] [Collections] [BLAST Results]          [Filter: ____]   |
+------------------------------------------------------------------+
|  (tab content)                                                    |
+------------------------------------------------------------------+
```

- **Samples tab**: Checkbox list of samples with metadata columns. Checking/
  unchecking a sample filters the batch overview and per-sample tables.
  Sample role icons distinguish test vs control samples.
- **Collections tab**: Existing taxa collections browser (from
  `TaxaCollectionsDrawerView`).
- **BLAST Results tab**: Existing BLAST verification results (from
  `BlastResultsDrawerTab`).

**Filtering UX**:
- The Samples tab has a checkbox column. Unchecked samples are excluded from
  the batch overview heatmap and the per-sample selector.
- A "Show Controls" toggle in the header hides/shows negative/positive controls.
- The filter state is local to the view controller and does not persist.
- The `TaxTriageBatchOverviewView.configure()` call receives only the filtered
  sample IDs.

**Single FASTQ to batch transition**:
- When viewing a single FASTQ result, the Samples tab shows just that sample's
  metadata (read-only).
- When viewing a batch result (multi-sample), the Samples tab shows the full
  sample list with filtering controls.
- The tab is always present but the filtering controls appear only when
  `sampleIds.count > 1`.

---

## 3. Metadata Schema

### 3.1 `FASTQSampleMetadata` Struct

New struct in LungfishIO replacing the generic key-value approach with typed
fields that map to PHA4GE/NCBI standards.

**File**: `Sources/LungfishIO/Formats/FASTQ/FASTQSampleMetadata.swift` (new)

```swift
/// PHA4GE-aligned metadata for a FASTQ dataset.
///
/// Maps to NCBI BioSample attributes for SRA submission interoperability.
/// All fields except `sampleName` are optional. Unknown fields are preserved
/// in `customFields` for round-trip fidelity.
public struct FASTQSampleMetadata: Sendable, Codable, Equatable {

    // --- Required ---
    /// Display name for the sample (maps to NCBI `sample_name`).
    public var sampleName: String

    // --- Recommended (PHA4GE Tier 1) ---
    /// Sample type / isolation source (maps to NCBI `isolation_source`).
    /// Suggested values: "Nasopharyngeal swab", "Blood", "Stool", "Wastewater",
    /// "Environmental swab", "Bronchoalveolar lavage".
    public var sampleType: String?

    /// Collection date in ISO 8601 format (YYYY-MM-DD, YYYY-MM, or YYYY).
    public var collectionDate: String?

    /// Geographic location in ISO 3166 format: "country:region:locality".
    public var geoLocName: String?

    /// Host organism (NCBI Taxonomy name, e.g., "Homo sapiens").
    public var host: String?

    /// Host disease or condition (free text or ICD-10).
    public var hostDisease: String?

    /// Purpose of sequencing: "Diagnostic", "Surveillance", "Research", etc.
    public var purposeOfSequencing: String?

    /// Sequencing instrument model (INSDC controlled vocabulary).
    public var sequencingInstrument: String?

    /// Library strategy: "WGS", "AMPLICON", "RNA-Seq", etc.
    public var libraryStrategy: String?

    /// Lab or institution that collected the sample.
    public var sampleCollectedBy: String?

    /// Target organism (NCBI Taxonomy name) or "metagenome".
    public var organism: String?

    // --- Batch context ---
    /// Role of this sample in the analysis batch.
    public var sampleRole: SampleRole

    /// Patient or subject identifier (may contain PHI).
    public var patientId: String?

    /// Sequencing run identifier.
    public var runId: String?

    /// Analysis batch identifier.
    public var batchId: String?

    /// Well position on sequencing plate (e.g., "A1", "H12").
    public var platePosition: String?

    // --- Extensibility ---
    /// Custom key-value fields not covered by the typed properties.
    /// Preserved during CSV round-trip for fields the user adds.
    public var customFields: [String: String]

    public init(sampleName: String) {
        self.sampleName = sampleName
        self.sampleRole = .testSample
        self.customFields = [:]
    }
}

/// Role of a sample in a batch analysis.
///
/// Controls contamination risk flagging and filtering defaults.
public enum SampleRole: String, Sendable, Codable, CaseIterable {
    case testSample = "test_sample"
    case negativeControl = "negative_control"
    case positiveControl = "positive_control"
    case environmentalControl = "environmental_control"
    case extractionBlank = "extraction_blank"

    /// Whether this role represents a control (not a test sample).
    public var isControl: Bool {
        self != .testSample
    }

    /// Human-readable display label.
    public var displayLabel: String {
        switch self {
        case .testSample: return "Test Sample"
        case .negativeControl: return "Negative Control"
        case .positiveControl: return "Positive Control"
        case .environmentalControl: return "Environmental Control"
        case .extractionBlank: return "Extraction Blank"
        }
    }
}
```

### 3.2 CSV Column Mapping

The `metadata.csv` format uses column headers that map to `FASTQSampleMetadata`
fields. The mapping is case-insensitive and supports aliases:

| CSV Column Header(s) | Property | Notes |
|-----------------------|----------|-------|
| `sample_name`, `name`, `label` | `sampleName` | First non-empty match wins |
| `sample_type`, `isolation_source` | `sampleType` | NCBI BioSample alias |
| `collection_date` | `collectionDate` | ISO 8601 |
| `geo_loc_name`, `geographic_location` | `geoLocName` | |
| `host` | `host` | |
| `host_disease` | `hostDisease` | |
| `purpose_of_sequencing` | `purposeOfSequencing` | |
| `instrument_model`, `sequencing_instrument` | `sequencingInstrument` | |
| `library_strategy` | `libraryStrategy` | |
| `collected_by`, `sample_collected_by` | `sampleCollectedBy` | |
| `organism` | `organism` | |
| `sample_role`, `control_type` | `sampleRole` | |
| `patient_id`, `subject_id` | `patientId` | |
| `run_id` | `runId` | |
| `batch_id` | `batchId` | |
| `plate_position`, `well` | `platePosition` | |
| (anything else) | `customFields[header]` | Preserved in round-trip |

### 3.3 Backward Compatibility

`FASTQBundleCSVMetadata` continues to work unchanged. The new
`FASTQSampleMetadata` struct provides a typed overlay:

```swift
extension FASTQSampleMetadata {
    /// Initializes from a legacy `FASTQBundleCSVMetadata` key-value store.
    public init(from legacy: FASTQBundleCSVMetadata) { ... }

    /// Converts back to `FASTQBundleCSVMetadata` for serialization.
    public func toLegacyCSV() -> FASTQBundleCSVMetadata { ... }
}
```

---

## 4. Storage Format and Location

### 4.1 Per-Bundle Storage

Each `.lungfishfastq` bundle stores its metadata in `metadata.csv` at the
bundle root (existing location). The CSV file uses the freeform multi-column
format with PHA4GE-aligned headers.

**Single-sample bundle** (most common):
```
SampleA.lungfishfastq/
  sample.fastq.gz
  sample.lungfish-meta.json
  metadata.csv          <-- one data row
```

`metadata.csv` contents:
```csv
sample_name,sample_type,collection_date,sample_role,geo_loc_name,patient_id
SampleA,Nasopharyngeal swab,2026-01-15,test_sample,USA:Georgia:Atlanta,PT-042
```

### 4.2 Folder-Level Storage

When a folder contains multiple `.lungfishfastq` bundles, a `samples.csv` file
at the folder root provides batch-level metadata for all samples.

```
VSP2_Run_2026-03-20/
  samples.csv           <-- one row per bundle
  SampleA.lungfishfastq/
  SampleB.lungfishfastq/
  NTC.lungfishfastq/
```

`samples.csv` contents:
```csv
sample_name,sample_type,collection_date,sample_role,geo_loc_name,patient_id,run_id
SampleA,Nasopharyngeal swab,2026-01-15,test_sample,USA:GA:Atlanta,PT-042,VSP2-Run-1
SampleB,Blood,2026-01-15,test_sample,USA:GA:Atlanta,PT-043,VSP2-Run-1
NTC,,2026-01-15,negative_control,,NTC,VSP2-Run-1
```

**Resolution rules**:
1. Per-bundle `metadata.csv` takes precedence over folder `samples.csv`.
2. Folder `samples.csv` rows are matched to bundles by `sample_name` column
   matching the bundle directory name (minus `.lungfishfastq` extension).
3. When saving from the folder-level editor, both `samples.csv` and per-bundle
   `metadata.csv` files are updated.

### 4.3 Folder-Level Metadata Model

**File**: `Sources/LungfishIO/Formats/FASTQ/FASTQFolderMetadata.swift` (new)

```swift
/// Manages batch-level sample metadata stored in `samples.csv` at a folder root.
///
/// Each row maps to one `.lungfishfastq` bundle in the folder, matched by
/// `sample_name` column to the bundle directory name.
public struct FASTQFolderMetadata: Sendable, Equatable {
    public static let filename = "samples.csv"

    /// Parsed metadata per sample, keyed by sample name.
    public let samples: [String: FASTQSampleMetadata]

    /// Ordered sample names (preserves CSV row order).
    public let sampleOrder: [String]

    // Load/save/parse methods analogous to FASTQBundleCSVMetadata
    public static func load(from folderURL: URL) -> FASTQFolderMetadata?
    public static func save(_ metadata: FASTQFolderMetadata, to folderURL: URL) throws
    public static func exists(in folderURL: URL) -> Bool
}
```

### 4.4 Integration with TaxTriageSample

`TaxTriageSample` gains a `metadata` property:

```swift
// In TaxTriageConfig.swift
public struct TaxTriageSample {
    public var sampleId: String
    public var fastq1: URL
    public var fastq2: URL?
    public var platform: TaxTriageConfig.Platform
    public var isNegativeControl: Bool  // kept for backward compat

    /// Structured sample metadata, loaded from the FASTQ bundle's metadata.csv.
    /// When present, `isNegativeControl` is derived from `metadata.sampleRole`.
    public var metadata: FASTQSampleMetadata?
}
```

The `isNegativeControl` property becomes a computed convenience:
```swift
extension TaxTriageSample {
    /// True if this sample is any type of negative control.
    public var isAnyNegativeControl: Bool {
        if let metadata {
            return metadata.sampleRole == .negativeControl
                || metadata.sampleRole == .extractionBlank
        }
        return isNegativeControl
    }
}
```

---

## 5. UI: Metadata Editing

### 5.1 Per-Dataset Editing (Document Inspector)

When a `.lungfishfastq` bundle is selected in the sidebar, the Inspector's
Document tab shows a "Sample Metadata" section with editable fields.

**Implementation approach**: Add a new `FASTQMetadataSectionViewModel` and
`FASTQMetadataSection` SwiftUI view in the Inspector, following the exact
pattern of `SampleSectionViewModel` / `SampleSection.swift`.

**File**: `Sources/LungfishApp/Views/Inspector/Sections/FASTQMetadataSection.swift` (new)

```swift
@Observable
@MainActor
public final class FASTQMetadataSectionViewModel {
    var metadata: FASTQSampleMetadata?
    var bundleURL: URL?
    var isEditing: Bool = false
    var isExpanded: Bool = true

    /// Callback to persist metadata changes.
    var onSave: ((_ bundleURL: URL, _ metadata: FASTQSampleMetadata) -> Void)?

    func load(from bundleURL: URL) { ... }
    func save() { ... }
}
```

The SwiftUI view shows:
- **Header**: "Sample Metadata" with Edit/Save toggle button.
- **Required field**: `sample_name` (text field, always visible).
- **Recommended fields**: Disclosure group with `sample_type` (popup),
  `collection_date` (date picker), `geo_loc_name` (text), `host` (text),
  `sample_role` (popup with `SampleRole.allCases`).
- **Optional fields**: Disclosure group with remaining PHA4GE fields.
- **Custom fields**: Key-value list with Add/Remove buttons.
- **Import/Export**: Buttons to import from CSV or export to CSV.

**Wiring**: `InspectorViewController` creates the section view model and
wires it into `InspectorViewModel`. The `MainSplitViewController` calls
`inspectorController.fastqMetadataSectionViewModel.load(from:)` when a
FASTQ bundle is selected.

### 5.2 Folder-Level Editing (Sheet)

When the user right-clicks a folder containing `.lungfishfastq` bundles in
the sidebar, a context menu offers "Edit Sample Metadata...". This opens a
sheet with a table editor.

**File**: `Sources/LungfishApp/Views/Sidebar/FolderMetadataEditorSheet.swift` (new)

The sheet contains:
- An `NSTableView` (or SwiftUI `Table`) with one row per bundle.
- Columns for each `FASTQSampleMetadata` field.
- Editable cells (inline editing).
- Import CSV / Export CSV buttons in the toolbar.
- Save / Cancel buttons.

**Wiring**: `SidebarViewController` handles the context menu action. It
scans the folder for `.lungfishfastq` bundles, loads existing metadata from
`samples.csv` (or per-bundle `metadata.csv` if no folder-level file exists),
and presents the sheet.

On save:
1. Write `samples.csv` to the folder root.
2. Write individual `metadata.csv` to each bundle (so metadata travels with
   the bundle if copied independently).
3. Post a notification so open viewers refresh their labels.

### 5.3 Batch Analysis Wizard Integration

The TaxTriage Wizard Sheet (`TaxTriageWizardSheet.swift`) currently shows
sample rows with an NTC checkbox. Enhance it to:

1. Auto-load metadata from each sample's `.lungfishfastq` bundle.
2. Display `sampleName` (from metadata) as the label instead of the filename.
3. Replace the NTC checkbox with a `SampleRole` popup.
4. Show a read-only summary of metadata fields as a tooltip on each row.

**File to modify**: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`

---

## 6. UI: Bottom Drawer Tab Structure

### 6.1 Unified Metagenomics Drawer

Create a new unified drawer view that hosts all metagenomics drawer tabs.
This replaces the current approach where `TaxaCollectionsDrawerView` is used
only in taxonomy views.

**File**: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift` (new)

```swift
/// Unified bottom drawer for metagenomics result views.
///
/// Hosts three tabs: Samples, Collections, and BLAST Results.
/// The Samples tab provides metadata display and sample filtering for
/// batch analyses. Collections and BLAST Results are carried over from
/// the existing `TaxaCollectionsDrawerView`.
@MainActor
public final class MetagenomicsDrawerView: NSView {

    enum DrawerTab: Int, CaseIterable {
        case samples = 0
        case collections = 1
        case blastResults = 2

        var title: String {
            switch self {
            case .samples: return "Samples"
            case .collections: return "Collections"
            case .blastResults: return "BLAST Results"
            }
        }
    }

    // --- Child views ---
    let dividerView: MetagenomicsDividerView  // reuses divider pattern
    let tabControl: NSSegmentedControl
    let samplesTab: SampleFilterDrawerTab      // new
    let collectionsTab: TaxaCollectionsContentView  // extracted from TaxaCollectionsDrawerView
    let blastResultsTab: BlastResultsDrawerTab  // existing

    // --- Delegate ---
    weak var delegate: MetagenomicsDrawerDelegate?

    // --- Tab switching ---
    func switchToTab(_ tab: DrawerTab)
    func showBlastResults(_ result: BlastVerificationResult)

    // --- Sample filtering ---
    /// Returns the set of currently visible (checked) sample IDs.
    var visibleSampleIds: Set<String>
    /// Called when the user changes sample visibility.
    var onSampleFilterChanged: ((Set<String>) -> Void)?
}
```

### 6.2 Samples Tab

**File**: `Sources/LungfishApp/Views/Metagenomics/SampleFilterDrawerTab.swift` (new)

```swift
/// The Samples tab within the metagenomics drawer.
///
/// Shows a table of samples in the current batch analysis with:
/// - Checkbox column for visibility filtering
/// - Sample name / display label
/// - Sample role icon (test, NTC, positive, environmental, extraction blank)
/// - Key metadata columns (sample_type, collection_date, geo_loc_name)
///
/// When `sampleCount <= 1`, filtering controls are hidden and the tab
/// shows read-only metadata for the single sample.
@MainActor
final class SampleFilterDrawerTab: NSView {

    struct SampleRow {
        let sampleId: String
        let metadata: FASTQSampleMetadata?
        var isVisible: Bool
    }

    private var rows: [SampleRow] = []
    private let tableView = NSTableView()
    private let showControlsToggle = NSButton(checkboxWithTitle: "Show Controls", ...)

    /// Configures the tab with sample data.
    func configure(sampleIds: [String], metadata: [String: FASTQSampleMetadata]) { ... }

    /// Returns visible sample IDs (checked rows).
    var visibleSampleIds: Set<String> { ... }

    /// Called when visibility changes.
    var onFilterChanged: ((Set<String>) -> Void)?
}
```

**Table columns**:

| Column | Width | Content |
|--------|-------|---------|
| Checkbox | 24 | NSButton checkbox, controls visibility |
| Role icon | 24 | SF Symbol: `person.fill` (test), `minus.circle` (NTC), `plus.circle` (pos), `leaf` (env), `flask` (extraction) |
| Sample Name | flex | Display label from metadata, fallback to sampleId |
| Type | 120 | `sampleType` value |
| Date | 90 | `collectionDate` value |
| Location | 100 | `geoLocName` value |

**"Show Controls" toggle**: When unchecked (default for batch views with >1 sample),
hides all rows where `sampleRole.isControl == true`. When checked, shows all rows.

### 6.3 Adoption in Existing View Controllers

Each metagenomics result view controller adopts the unified drawer:

**TaxTriageResultViewController** (`Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`):
- Replace any direct `TaxaCollectionsDrawerView` usage with `MetagenomicsDrawerView`.
- Wire `onSampleFilterChanged` to re-call `configureBatchOverview()` with
  filtered `sampleIds`.

**TaxonomyViewController** (`Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`):
- Replace `TaxaCollectionsDrawerView` with `MetagenomicsDrawerView`.
- The Samples tab shows single-sample metadata (read-only, no filtering).

**EsVirituResultViewController** (`Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`):
- Add `MetagenomicsDrawerView` as a bottom drawer.
- Wire sample filtering for multi-sample EsViritu batch results.

---

## 7. Filtering in Batch Views

### 7.1 Filter Flow

```
User unchecks "NTC" in Samples tab
  |
  v
SampleFilterDrawerTab.onFilterChanged(visibleSampleIds)
  |
  v
TaxTriageResultViewController receives callback
  |
  v
Calls configureBatchOverview() with filtered sampleIds
  |
  v
TaxTriageBatchOverviewView.configure(metrics:sampleIds:...)
  rebuilds table columns for only visible samples
  |
  v
Also updates per-sample selector popup (hides unchecked samples)
```

### 7.2 Filter State

```swift
/// Filter state for batch sample visibility.
///
/// Maintained by the `SampleFilterDrawerTab` and consumed by
/// the parent view controller to filter batch overview data.
struct SampleFilterState: Equatable {
    /// All sample IDs in the batch.
    var allSampleIds: [String]

    /// Sample IDs currently visible (checked in the drawer).
    var visibleSampleIds: Set<String>

    /// Whether control samples are shown.
    var showControls: Bool = false

    /// Returns visible sample IDs respecting the showControls toggle.
    func effectiveVisibleIds(metadata: [String: FASTQSampleMetadata]) -> [String] {
        allSampleIds.filter { id in
            guard visibleSampleIds.contains(id) else { return false }
            if !showControls, let meta = metadata[id], meta.sampleRole.isControl {
                return false
            }
            return true
        }
    }
}
```

### 7.3 Modifications to TaxTriageBatchOverviewView

The `configure(metrics:sampleIds:...)` method already accepts a `sampleIds`
parameter. No changes needed to the batch overview itself; the controller
simply passes the filtered list.

The per-sample selector popup (`NSSegmentedControl` or `NSPopUpButton` in
`TaxTriageResultViewController`) is rebuilt to show only filtered samples.

### 7.4 Metadata-Based Grouping in Batch Overview

Future enhancement: group sample columns by metadata fields (e.g., group by
`geo_loc_name` or `run_id`). This is out of scope for the initial
implementation but the data model supports it.

---

## 8. BLAST Results as a Drawer Facet

### 8.1 Current State

`BlastResultsDrawerTab` already exists as a complete, standalone NSView.
It is currently hosted inside `TaxaCollectionsDrawerView` as one of two tabs.

### 8.2 Migration to Unified Drawer

The `BlastResultsDrawerTab` moves unchanged into the new
`MetagenomicsDrawerView`. The only change is that it becomes the third tab
(index 2) instead of the second tab (index 1).

The `showBlastResults(_:)` method on `MetagenomicsDrawerView` switches to
the BLAST Results tab and populates it, exactly as
`TaxaCollectionsDrawerView.showBlastResults(_:)` does today.

### 8.3 BLAST Tab in Non-Taxonomy Views

For `TaxTriageResultViewController` and `EsVirituResultViewController`, the
BLAST Results tab is present but empty until the user runs a BLAST
verification from those views. The tab shows a placeholder message:
"No BLAST results. Run BLAST verification on a selected organism."

---

## 9. Export with Metadata

### 9.1 CSV/TSV Export

The existing `TaxTriageBatchExporter` gains metadata columns:

**File to modify**: `Sources/LungfishApp/Views/Metagenomics/TaxTriageBatchExporter.swift`

```swift
extension TaxTriageBatchExporter {
    /// Generates organism matrix CSV with metadata header rows.
    ///
    /// The first N rows contain sample metadata (one row per metadata field),
    /// followed by organism data rows. This format is compatible with Excel
    /// and downstream analysis tools.
    static func generateOrganismMatrixCSVWithMetadata(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        metadata: [String: FASTQSampleMetadata],
        negativeControlSampleIds: Set<String>
    ) -> String { ... }
}
```

### 9.2 NCBI BioSample TSV Export

New export function that generates an NCBI BioSample-compatible TSV file
from the batch metadata, for users who want to submit sequences to SRA.

**File**: `Sources/LungfishIO/Formats/FASTQ/NCBIBioSampleExporter.swift` (new)

```swift
/// Exports `FASTQSampleMetadata` to NCBI BioSample submission TSV format.
///
/// The output follows the Pathogen.cl.1.0 or Pathogen.env.1.0 package
/// format depending on sample types present.
public enum NCBIBioSampleExporter {
    public static func export(
        samples: [FASTQSampleMetadata],
        package: BioSamplePackage = .pathogenClinical
    ) -> String { ... }

    public enum BioSamplePackage {
        case pathogenClinical   // Pathogen.cl.1.0
        case pathogenEnvironmental  // Pathogen.env.1.0
    }
}
```

---

## 10. Phased Implementation

### Phase 1: Metadata Schema and Storage (LungfishIO only)

**Estimated scope**: ~400 lines new code, ~50 lines modified.

1. Create `FASTQSampleMetadata` struct with `SampleRole` enum.
   - File: `Sources/LungfishIO/Formats/FASTQ/FASTQSampleMetadata.swift`
2. Create `FASTQFolderMetadata` with load/save/parse.
   - File: `Sources/LungfishIO/Formats/FASTQ/FASTQFolderMetadata.swift`
3. Add CSV column mapping and conversion between `FASTQSampleMetadata`
   and `FASTQBundleCSVMetadata`.
4. Add `metadata` property to `TaxTriageSample`.
   - File: `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift`
5. Unit tests for parsing, round-trip, and backward compatibility.
   - File: `Tests/LungfishIOTests/FASTQSampleMetadataTests.swift`

**Deliverable**: Metadata can be loaded, saved, and round-tripped. No UI changes.

### Phase 2: Per-Dataset Metadata Editing (Inspector)

**Estimated scope**: ~300 lines new code, ~80 lines modified.

1. Create `FASTQMetadataSectionViewModel` and `FASTQMetadataSection` SwiftUI view.
   - File: `Sources/LungfishApp/Views/Inspector/Sections/FASTQMetadataSection.swift`
2. Wire into `InspectorViewModel` and `InspectorViewController`.
   - Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
3. Load metadata when FASTQ bundle is selected in sidebar.
   - Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
4. Tests for the view model.
   - File: `Tests/LungfishAppTests/FASTQMetadataSectionTests.swift`

**Deliverable**: Users can view and edit per-bundle metadata in the Inspector.

### Phase 3: Folder-Level Metadata Editing

**Estimated scope**: ~500 lines new code, ~60 lines modified.

1. Create `FolderMetadataEditorSheet` (NSViewController with table editor).
   - File: `Sources/LungfishApp/Views/Sidebar/FolderMetadataEditorSheet.swift`
2. Add sidebar context menu action "Edit Sample Metadata...".
   - Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
3. CSV import/export in the sheet.
4. Sync folder-level and per-bundle metadata on save.
5. Tests.
   - File: `Tests/LungfishAppTests/FolderMetadataEditorTests.swift`

**Deliverable**: Users can edit metadata for all samples in a folder at once.

### Phase 4: Samples Drawer Tab and Batch Filtering

**Estimated scope**: ~600 lines new code, ~200 lines modified.

1. Create `SampleFilterDrawerTab`.
   - File: `Sources/LungfishApp/Views/Metagenomics/SampleFilterDrawerTab.swift`
2. Create `MetagenomicsDrawerView` (unified tabbed drawer).
   - File: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift`
3. Extract collections content from `TaxaCollectionsDrawerView` into a
   reusable content view (or keep and embed the existing view).
4. Adopt `MetagenomicsDrawerView` in `TaxTriageResultViewController`.
   - Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
5. Wire `onSampleFilterChanged` to filter batch overview.
6. Load per-sample metadata from bundles at batch configuration time.
7. Tests for filtering logic.
   - File: `Tests/LungfishAppTests/SampleFilterDrawerTests.swift`

**Deliverable**: Users can filter which samples appear in TaxTriage batch views.

### Phase 5: Unified Drawer in All Metagenomics Views

**Estimated scope**: ~200 lines modified.

1. Adopt `MetagenomicsDrawerView` in `TaxonomyViewController`.
   - Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
   - Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Collections.swift`
2. Adopt `MetagenomicsDrawerView` in `EsVirituResultViewController`.
   - Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
3. Retire standalone `TaxaCollectionsDrawerView` (or keep as thin wrapper).
4. Ensure BLAST Results tab works from all three contexts.

**Deliverable**: Consistent drawer experience across all metagenomics views.

### Phase 6: Wizard Integration and Export

**Estimated scope**: ~300 lines new code, ~100 lines modified.

1. Enhance TaxTriage Wizard to auto-load and display metadata.
   - Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
2. Replace NTC checkbox with `SampleRole` popup in wizard.
3. Add metadata columns to batch export CSV.
   - Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageBatchExporter.swift`
4. Create NCBI BioSample TSV exporter.
   - File: `Sources/LungfishIO/Formats/FASTQ/NCBIBioSampleExporter.swift`
5. Add "Export BioSample TSV..." menu action.

**Deliverable**: End-to-end metadata workflow from import through analysis to export.

---

## 11. File Inventory

### New Files

| File | Module | Phase | Purpose |
|------|--------|-------|---------|
| `Sources/LungfishIO/Formats/FASTQ/FASTQSampleMetadata.swift` | LungfishIO | 1 | Typed metadata struct + SampleRole enum |
| `Sources/LungfishIO/Formats/FASTQ/FASTQFolderMetadata.swift` | LungfishIO | 1 | Folder-level samples.csv manager |
| `Sources/LungfishIO/Formats/FASTQ/NCBIBioSampleExporter.swift` | LungfishIO | 6 | NCBI BioSample TSV export |
| `Tests/LungfishIOTests/FASTQSampleMetadataTests.swift` | Tests | 1 | Schema + parsing tests |
| `Sources/LungfishApp/Views/Inspector/Sections/FASTQMetadataSection.swift` | LungfishApp | 2 | Inspector section for FASTQ metadata |
| `Tests/LungfishAppTests/FASTQMetadataSectionTests.swift` | Tests | 2 | Inspector section tests |
| `Sources/LungfishApp/Views/Sidebar/FolderMetadataEditorSheet.swift` | LungfishApp | 3 | Folder-level metadata table editor |
| `Tests/LungfishAppTests/FolderMetadataEditorTests.swift` | Tests | 3 | Folder editor tests |
| `Sources/LungfishApp/Views/Metagenomics/SampleFilterDrawerTab.swift` | LungfishApp | 4 | Samples tab for filtering |
| `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift` | LungfishApp | 4 | Unified tabbed drawer |
| `Tests/LungfishAppTests/SampleFilterDrawerTests.swift` | Tests | 4 | Filtering tests |

### Modified Files

| File | Phase | Changes |
|------|-------|---------|
| `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift` | 1 | Add `metadata` property to `TaxTriageSample` |
| `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` | 2 | Wire `FASTQMetadataSectionViewModel` |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | 2 | Load metadata on FASTQ selection |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | 3 | Context menu for folder metadata |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` | 4 | Adopt MetagenomicsDrawerView, wire filtering |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` | 5 | Adopt MetagenomicsDrawerView |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Collections.swift` | 5 | Update collections wiring |
| `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` | 5 | Add drawer |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift` | 6 | Metadata display + SampleRole popup |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageBatchExporter.swift` | 6 | Metadata columns in export |

### Unchanged Files (Referenced)

| File | Relationship |
|------|-------------|
| `Sources/LungfishIO/Formats/FASTQ/FASTQBundleCSVMetadata.swift` | Backward-compatible base; conversion bridge in Phase 1 |
| `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift` | Bundle resolution utilities (no changes) |
| `Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerTab.swift` | Moved into unified drawer, no internal changes |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageBatchOverviewView.swift` | Already accepts filtered sampleIds (no changes) |
| `Sources/LungfishApp/Views/Inspector/Sections/SampleSection.swift` | Pattern reference for the new FASTQMetadataSection |
| `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift` | FASTQ drawer for demux/trim (no changes) |
