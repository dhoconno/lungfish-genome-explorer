# Classifier Interface Parity Design

**Date:** 2026-04-02
**Branch:** `feature/classifier-interface-parity`
**Scope:** Bring Kraken2, EsViritu, and TaxTriage classification interfaces to parity with NAO-MGS and NVD upgrades. Add sample metadata management and file attachments to all classifiers.

---

## Problem Statement

NAO-MGS and NVD have inspector-embedded sample pickers, rich toolbar filter controls, and BLAST verification drawers. The other three classifiers (Kraken2, EsViritu, TaxTriage) lack some or all of these features. Additionally, no classifier supports importing/editing sample metadata or attaching arbitrary files — both needed for reproducibility and annotation workflows.

### Current Feature Matrix

| Feature | NAO-MGS | NVD | Kraken2 | EsViritu | TaxTriage |
|---------|---------|-----|---------|----------|-----------|
| Inspector sample picker | Yes | Yes | **No** | **No** | **No** |
| Sample filtering (any) | Popover | Popover | Drawer only | **None** | Segmented ctrl |
| Name/taxon search | Toolbar | Toolbar | In table | In table | **None** |
| BLAST drawer | Yes | Yes | **No** | Yes | Yes |
| Numeric filters (min hits, etc.) | Yes | No | No | No | No |
| Grouping mode toggle | No | Yes (bySample/byTaxon) | No | No | No |
| Sample metadata import | **No** | **No** | **No** | **No** | **No** |
| File attachments | **No** | **No** | **No** | **No** | **No** |

---

## Design

### 1. Unified Sample Picker (`ClassifierSamplePickerView`)

Replace the per-classifier picker pattern (currently `NaoMgsSamplePickerView` and `NvdSamplePickerView`) with a single generic SwiftUI view.

#### Protocol

```swift
protocol ClassifierSampleEntry: Identifiable, Sendable {
    var id: String { get }
    var displayName: String { get }
    var metricLabel: String { get }       // "hits", "reads", "TASS", etc.
    var metricValue: String { get }       // formatted number
    var secondaryMetric: String? { get }  // optional (NVD: "contigs / hits")
}
```

Each classifier provides a concrete entry type:
- **Kraken2:** sample ID, display name, total classified reads
- **EsViritu:** sample ID, display name, detected virus count
- **TaxTriage:** sample ID, display name, organism count or mean TASS
- **NAO-MGS:** sample ID, display name, hit count (replaces existing picker)
- **NVD:** sample ID, display name, contig count + hit count (replaces existing picker)

#### State

```swift
@Observable
public final class ClassifierSamplePickerState: @unchecked Sendable {
    public var selectedSamples: Set<String>  // visible sample IDs

    public init(allSamples: Set<String>) {
        self.selectedSamples = allSamples
    }
}
```

#### View Layout

Two rendering modes controlled by `isInline: Bool`:
- **Inline** (`isInline: true`): Fills available height in Inspector sidebar. No border.
- **Popover** (`isInline: false`): Fixed 360x300, opened from toolbar sample filter button.

Top to bottom:
1. Search field — filters sample list by name substring
2. Select All toggle — checkbox + "Select All (N)" label
3. Scrollable sample list — each row: checkbox, display name (common prefix stripped), right-aligned metric in monospaced font

#### Files

- **New:** `Sources/LungfishApp/Views/Metagenomics/ClassifierSamplePickerView.swift`
- **New:** `Sources/LungfishCore/Models/ClassifierSamplePickerState.swift`
- **Remove:** `NaoMgsSamplePickerView.swift` (replaced), `NvdSamplePickerView.swift` (replaced)
- **Update:** `NaoMgsResultViewController.swift`, `NvdResultViewController.swift` — use new unified types

### 2. Generalized Inspector Wiring

Replace the per-classifier inspector methods with a single generic path.

#### InspectorViewController

One method replaces `updateMetagenomicsSampleState` and `updateNvdSampleState`:

```swift
func updateClassifierSampleState(
    pickerState: ClassifierSamplePickerState,
    entries: [any ClassifierSampleEntry],
    strippedPrefix: String,
    metadata: SampleMetadataStore?
)
```

#### DocumentSectionViewModel

Consolidate NAO-MGS/NVD-specific properties into generic ones:

```swift
// Replace:
//   samplePickerState: NaoMgsSamplePickerState?
//   sampleEntries: [NaoMgsSampleEntry]
//   nvdSamplePickerState: NvdSamplePickerState?
//   nvdSampleEntries: [NvdSampleEntry]
// With:
var classifierPickerState: ClassifierSamplePickerState?
var classifierSampleEntries: [any ClassifierSampleEntry] = []
var classifierStrippedPrefix: String = ""
var sampleMetadataStore: SampleMetadataStore?
```

#### Inspector Document Tab Rendering

One conditional block replaces the two separate NAO-MGS/NVD blocks:

```swift
if let pickerState = viewModel.classifierPickerState,
   !viewModel.classifierSampleEntries.isEmpty {
    // Render ClassifierSamplePickerView(isInline: true)
    // .onChange posts .metagenomicsSampleSelectionChanged
}
```

#### MainSplitViewController

Each classifier's display method calls `updateClassifierSampleState(...)` with its own entry type. Same call signature for all 5 classifiers.

### 3. Sample Metadata Store

New type in LungfishCore for importing, editing, and persisting free-form sample metadata.

#### Data Model

```swift
@Observable
public final class SampleMetadataStore: @unchecked Sendable {
    /// Column names in display order (from TSV/CSV header row)
    public var columnNames: [String]
    /// Key: sample ID (first column value), Value: [columnName: value]
    public var records: [String: [String: String]]
    /// Samples that matched known sample IDs
    public var matchedSampleIds: Set<String>
    /// Samples from TSV that did not match any known sample
    public var unmatchedRecords: [String: [String: String]]
    /// Edits made in-app (for reproducibility sidecar)
    public var edits: [MetadataEdit]
}

public struct MetadataEdit: Codable, Sendable {
    let sampleId: String
    let columnName: String
    let oldValue: String?
    let newValue: String
    let timestamp: Date
}
```

#### Import Flow

1. User clicks "Import Metadata..." in Inspector, or drags CSV/TSV onto metadata section
2. Parse flexibly: detect delimiter (tab vs comma), use first row as headers, first column as sample ID key
3. Match rows to known sample IDs: strip common prefixes, case-insensitive comparison
4. Save original file copy to `bundle/metadata/sample_metadata.tsv`
5. Save edit journal to `bundle/metadata/sample_metadata_edits.json`

#### Inspector Rendering

Below the sample picker in the Document tab:
- Collapsible "Sample Metadata" section with disclosure triangle
- Mini-table: rows = matched samples (in sample picker order), columns = metadata fields
- Click any cell to edit inline (NSTextField overlay)
- Edits auto-save to the JSON sidecar
- Dimmed "Unmatched Samples" subsection for rows that didn't match any known sample

#### Persistence in Bundle

```
bundle/
  metadata/
    sample_metadata.tsv        # Original imported file (immutable after import)
    sample_metadata_edits.json # Edit journal: [{sampleId, column, old, new, timestamp}]
```

On load: apply edits on top of original TSV to reconstruct current state.

#### Universal Search Integration

Extend `ProjectUniversalSearchIndex` to index metadata values. Each value creates a search entry:
- Type: `.sampleMetadata`
- Text: the metadata value (e.g., "Columbia, MO")
- Context: "Sample: Col_44_GH_L_S30, Field: Sewershed Location"
- Navigation: opens the classifier result and selects that sample

### 4. File Attachments

Store arbitrary files inside classification bundles for documentation and reproducibility.

#### Storage

```
bundle/
  attachments/
    protocol_v3.pdf
    lab_notes.txt
    photo_20260402.jpg
```

Files are copied into the bundle (not symlinked). No database — directory listing is the source of truth.

#### Inspector UI

Collapsible "Attachments" section below metadata:
- File list: icon (NSWorkspace icon for file type) + filename + file size + date
- "Attach File..." button → NSOpenPanel (multi-select)
- Drag-and-drop onto section to attach
- Right-click context menu: "Reveal in Finder", "Remove Attachment", "Quick Look"
- Remove moves to trash (reversible), not permanent delete

#### Data Model

```swift
public struct BundleAttachment: Sendable {
    let filename: String
    let fileSize: Int64
    let dateAdded: Date
    let url: URL  // inside bundle/attachments/
}
```

`BundleAttachmentStore` scans `bundle/attachments/` on load and watches for filesystem changes.

### 5. Per-Classifier Gap Fixes

#### Kraken2

- **Add:** Inspector sample picker via unified `ClassifierSamplePickerView`
  - Entry type provides: sample ID, display name, classified read count
  - Wired through `MainSplitViewController.displayClassificationResult()`
- **Add:** BLAST verification drawer (`BlastResultsDrawerTab`)
  - Already exists as shared component, just needs wiring in `TaxonomyViewController`
  - Add drawer toggle button to action bar
- **Keep unchanged:** Sunburst visualization, taxonomy table, keyboard shortcuts, breadcrumb bar

#### EsViritu

- **Add:** Inspector sample picker via unified `ClassifierSamplePickerView`
  - Entry type provides: sample ID, display name, detected virus count
  - For single-sample results: picker shows one entry (still useful for metadata display)
- **Add:** Sample filter button in toolbar (for multi-sample results, if/when supported)
- **Keep unchanged:** Coverage detail pane, virus search field, hierarchical outline view

#### TaxTriage

- **Add:** Inspector sample picker via unified `ClassifierSamplePickerView`
  - Entry type provides: sample ID, display name, organism count
  - Supplements (does not replace) existing segmented control for quick-switch
- **Add:** Organism name search field in toolbar
  - NSSearchField with placeholder "Filter organisms..."
  - Filters `TaxTriageTableRow` by case-insensitive substring match on `organism` field
  - Debounced (200ms) to avoid excessive reloads
- **Keep unchanged:** Batch overview, TASS scoring, segmented control, confidence visualization

### 6. Notification Consolidation

All classifiers use the same notification for sample selection changes:
- `.metagenomicsSampleSelectionChanged` (already exists)

Each result VC observes this notification and calls its own filter/reload method. No new notifications needed.

---

## Non-Goals

- Numeric threshold filters (min hits, min unique reads) for classifiers other than NAO-MGS — these are NAO-MGS-specific due to its data model
- Grouping mode toggle for classifiers other than NVD — NVD's bySample/byTaxon toggle is specific to its contig-based data model
- Database migration for EsViritu or TaxTriage to SQLite — separate concern, not needed for UI parity
- Sunburst chart for non-Kraken2 classifiers — tool-specific visualization

## Testing Strategy

- Unit tests: `ClassifierSamplePickerState` selection/deselection, `SampleMetadataStore` import/edit/persistence
- Integration tests: metadata TSV parsing with various delimiters and edge cases (empty cells, quoted fields, mismatched columns)
- UI verification: manual testing of Inspector rendering across all 5 classifiers
- Regression: existing classification UI tests must continue passing

## Migration

- `NaoMgsSamplePickerView` and `NvdSamplePickerView` replaced by `ClassifierSamplePickerView`
- `NaoMgsSamplePickerState` and `NvdSamplePickerState` replaced by `ClassifierSamplePickerState`
- `DocumentSectionViewModel` properties consolidated (old properties removed)
- All existing functionality preserved through the unified interface
