# Multi-Select, Extract FASTQ, and Display Name Consistency

**Date:** 2026-04-03
**Branch:** `feature/classifier-interface-parity` (continuing)
**Scope:** Enable multi-row selection across all classifier taxonomy views, add Extract FASTQ button to all classifiers, and fix display name consistency for virtual FASTQ bundles.

---

## 1. Multi-Row Selection

### Enable Multi-Select

Set `allowsMultipleSelection = true` on all 5 classifier taxonomy views:

| Classifier | View Type | File | Current Line |
|-----------|-----------|------|-------------|
| Kraken2 | NSOutlineView (TaxonomyTableView) | TaxonomyTableView.swift:221 | `false` → `true` |
| EsViritu | NSOutlineView (ViralDetectionTableView) | ViralDetectionTableView.swift:329 | `false` → `true` |
| TaxTriage | NSTableView (TaxTriageOrganismTableView) | TaxTriageResultViewController.swift:~2380 | not set → `true` |
| NAO-MGS | NSTableView | NaoMgsResultViewController.swift:1199 | `false` → `true` |
| NVD | NSOutlineView | NvdResultViewController.swift:891 | `false` → `true` |

### Selection Change Handling

Each VC's existing selection delegate method is modified to handle the multi-selection case:

```swift
func outlineViewSelectionDidChange(_ notification: Notification) {
    let selectedRows = outlineView.selectedRowIndexes
    if selectedRows.count == 1 {
        // Existing single-selection behavior: show detail pane for selected item
        let item = outlineView.item(atRow: selectedRows.first!)
        showDetailPane(for: item)
        actionBar.setBlastEnabled(true)
    } else if selectedRows.count > 1 {
        // Multi-selection: show placeholder in detail pane
        showMultiSelectionPlaceholder(count: selectedRows.count)
        actionBar.setBlastEnabled(false)  // BLAST requires single selection
    } else {
        // No selection
        clearDetailPane()
        actionBar.setBlastEnabled(false)
    }
    updateActionBarInfoText()
}
```

### Detail Pane Multi-Selection Placeholder

When multiple rows are selected, the detail pane (left side of split view) shows:

```
[centered vertically and horizontally]
N items selected
Select a single row to view details
```

Styled: primary text (13pt semibold) + secondary text (11pt, tertiary color). Same pattern for all 5 classifiers.

### Action Bar with Multi-Select

- **BLAST Verify:** Enabled only when exactly 1 row is selected. When disabled due to multi-select, show a tooltip on the button: "Select a single row to use BLAST Verify". When disabled due to no selection, tooltip: "Select a row to use BLAST Verify".
- **Extract FASTQ:** Enabled when 1+ rows selected. Extracts reads for all selected taxa.
- **Export:** Always enabled (exports full table, not selection-dependent).
- **Info label:** Shows "N items selected" when multiple rows selected.

---

## 2. Extract FASTQ

### Button in ClassifierActionBar

Add "Extract FASTQ" as a new core button in `ClassifierActionBar`, positioned between Export and custom buttons:

```
| [BLAST Verify] [Export] [Extract FASTQ] [Custom...] | info text | [ⓘ] |
```

```swift
let extractButton: NSButton = {
    let btn = NSButton()
    btn.title = "Extract FASTQ"
    btn.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Extract FASTQ")
    btn.bezelStyle = .accessoryBarAction
    btn.imagePosition = .imageLeading
    btn.controlSize = .small
    btn.font = .systemFont(ofSize: 11)
    btn.setContentHuggingPriority(.required, for: .horizontal)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.isEnabled = false
    return btn
}()

var onExtractFASTQ: (() -> Void)?
```

Disabled until at least one row is selected.

### BLAST Verify Disabled Tooltip

`ClassifierActionBar.setBlastEnabled` gains a `reason` parameter to explain why the button is disabled:

```swift
func setBlastEnabled(_ enabled: Bool, reason: String? = nil) {
    blastButton.isEnabled = enabled
    blastButton.toolTip = enabled ? "Verify selected taxon with BLAST" : reason
}
```

Callers pass context-specific reasons:
- No selection: `setBlastEnabled(false, reason: "Select a row to use BLAST Verify")`
- Multi-select: `setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")`
- Single selection: `setBlastEnabled(true)`

### Per-Classifier Extraction Strategy

Each classifier provides its own extraction implementation through the `onExtractFASTQ` callback:

#### Kraken2
- **Source:** Per-read classification TSV + original FASTQ files
- **Method:** Existing `TaxonomyExtractionPipeline` — uses `seqkit grep` with read IDs from the classification output
- **Multi-select:** Collect tax IDs from all selected nodes (including children), build union of matching read IDs
- **Already implemented:** `TaxonomyExtractionSheet.swift` handles this. Extend to accept multiple `TaxonNode` selections.

#### EsViritu
- **Source:** BAM file (`{sampleName}.third.filt.sorted.bam`)
- **Method:** `samtools view -b {bamFile} {assemblyAccession1} {assemblyAccession2} ...` then `samtools fastq` to convert
- **Multi-select:** Pass all selected assembly accessions to samtools in one call
- **Requires:** BAM file present (EsViritu must be run with `--keep True`)

#### TaxTriage
- **Source:** Per-sample BAM file (`{sample}.bam`)
- **Method:** Look up reference accession(s) for selected organism(s) via `gcfmapping.tsv`, then `samtools view -b {bamFile} {accessions...}` then `samtools fastq`
- **Multi-select:** Union all reference accessions from selected organisms
- **Note:** Single BAM covers all organisms for a sample

#### NAO-MGS
- **Source:** SQLite database (has full read sequences and qualities)
- **Method:** `NaoMgsDatabase.fetchReadsForAccession(sample:taxId:accession:maxReads:)` returns `AlignedRead` objects with sequences and qualities. Write to FASTQ format directly.
- **Multi-select:** Query for all selected tax IDs, deduplicate by read ID
- **No samtools needed:** Read data is in the database

#### NVD
- **Source:** Per-sample BAM file
- **Method:** `samtools view -b {bamFile} {contigName1} {contigName2} ...` then `samtools fastq`
- **Multi-select:** Pass all selected contig names to samtools
- **Note:** Contigs are the query sequences, not references

### Output

All extraction methods produce a new virtual FASTQ bundle:
- Created in the project's FASTQ directory
- Uses `FASTQDerivedBundleManifest` with `.subset` payload
- Bundle name: `{sourceName}_{taxonOrOrganism}_extract`
- Appears in sidebar after creation
- For paired-end data: produces paired R1/R2 bundles

### Extraction Sheet

Reuse the existing `TaxonomyExtractionSheet` pattern — a SwiftUI sheet confirming the extraction:
- Shows: selected taxa/organisms, estimated read count, output name
- "Include Children" toggle (Kraken2 only — taxonomy is hierarchical)
- "Extract" button triggers the pipeline
- Progress shown in OperationCenter

For non-Kraken2 classifiers, create a simpler `ClassifierExtractionSheet` that shows:
- Selected items (organism names or contig names)
- Source BAM/database path
- Output bundle name (editable)
- "Extract" button

---

## 3. Display Name Consistency

### Problem

Virtual FASTQ bundles have internal names (file paths) that leak into user-facing UI. The sidebar shows correct display names via `FASTQDerivedBundleManifest.name`, but classifiers use raw file path components.

Specific instances:
- TaxTriage segmented control shows raw sample IDs instead of bundle display names
- Classification result headers show "materialized" (fixed in Plan 2, but pattern needs generalization)
- Sample picker entries may show internal IDs

### Solution: Display Name Resolution Utility

Create a utility function in LungfishApp that resolves human-readable names:

```swift
/// Resolves a human-readable display name for a sample or FASTQ bundle.
///
/// Resolution order:
/// 1. FASTQDerivedBundleManifest.name (for virtual FASTQ bundles)
/// 2. Bundle URL last path component minus extension
/// 3. Raw sample ID as fallback
static func resolveDisplayName(
    sampleId: String,
    bundleURL: URL?,
    projectURL: URL?
) -> String
```

This checks if the sample ID corresponds to a known FASTQ bundle in the project, reads its manifest `.name` field, and returns the human-readable name.

### Where to Apply

1. **TaxTriage segmented control:** Replace raw `sampleIds` in segment labels with resolved display names
2. **TaxTriage batch overview headers:** Use display names in the organism×sample matrix
3. **All classifier sample picker entries:** `displayName` on entry types should use resolved names
4. **Classification config headers:** Already fixed for "materialized" in Plan 2; generalize the pattern
5. **Inspector sample filter label:** Show display names, not internal IDs

### Implementation

Add the resolution utility to `Sources/LungfishApp/Services/` or as an extension on the existing `FASTQDerivativeService`.

Each classifier VC calls the utility when building sample entries and UI labels, replacing raw ID usage with resolved names.

---

## Non-Goals

- Extraction for classifiers that lack BAM files (if EsViritu was run without `--keep True`, extraction is unavailable — show disabled button with tooltip explaining why)
- Real-time extraction progress beyond what OperationCenter already shows
- Editing or renaming extracted bundles

## Testing

- Multi-select: manual test — Cmd+Click and Shift+Click in each classifier's taxonomy view, verify detail pane shows placeholder, verify action bar buttons respond correctly
- Extract FASTQ: manual test per classifier — select taxa, click Extract, verify output bundle appears in sidebar
- Display names: manual test — create virtual FASTQ (downsample), run TaxTriage, verify segmented control shows bundle display name not internal ID
