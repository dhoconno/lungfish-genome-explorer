# Classifier Bug Fixes and Action Bar Unification

**Date:** 2026-04-03
**Branch:** `feature/classifier-interface-parity` (continuing)
**Scope:** Fix 6 bugs and unify the bottom action bar across all 5 classifiers.

---

## Bug Fixes

### 1a. Sidebar Disclosure Triangles Collapsing

**Root cause:** `SidebarViewController.reloadFromFilesystem()` calls `outlineView.reloadData()` on every `FileSystemWatcher` event. `reloadData()` resets NSOutlineView expansion state. Only root-level folders are explicitly re-expanded; nested items lose their state.

**Fix:** Save expanded item state before reload, restore after:

```swift
func reloadOutlineView() {
    let expandedItems = saveExpandedItems()
    outlineView.reloadData()
    restoreExpandedItems(expandedItems)
}
```

Use `outlineView.isItemExpanded(_:)` to walk all visible items and collect expanded ones. After reload, iterate the saved set and call `outlineView.expandItem(_:)`. Match items by URL or identifier, not object identity (outline view creates new items on reload).

**File:** `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`

### 1b. Panel Layout Toggle Not Working (Kraken2, EsViritu, TaxTriage)

**Root cause:** The Panel Layout toggle in the Document Inspector changes `DocumentSectionViewModel.isTableOnLeft` (backed by `UserDefaults`), but Kraken2, EsViritu, and TaxTriage don't observe this change.

**Fix:** In each VC, observe the UserDefaults key `"metagenomicsTableOnLeft"` and swap the NSSplitView subview arrangement:

```swift
UserDefaults.standard.addObserver(self, forKeyPath: "metagenomicsTableOnLeft", options: [.new], context: nil)
```

In `observeValue(forKeyPath:)`:
- Read the new bool value
- Swap the two split view subviews by setting `arrangedSubviews` order

Check how NAO-MGS or NVD implements this (they were built later and likely work) and replicate the pattern.

**Files:**
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`

### 1c. Kraken2 Bottom Bar Overdraw

**Root cause:** The Collections, BLAST Results buttons, and info label overlap in the TaxonomyActionBar. The BLAST Results button was recently added (Task 9) and its constraints may conflict with the existing layout chain.

**Fix:** Rebuild the TaxonomyActionBar constraint chain. Since we're creating a unified `ClassifierActionBar` (Section 2), this fix will be absorbed into that work. The new bar uses proper spacing with no overlapping constraints.

**File:** `Sources/LungfishApp/Views/Metagenomics/TaxonomyActionBar.swift` (will be replaced)

### 1d. "Materialized" Sample Name in Kraken2

**Root cause:** When Kraken2 runs on a virtual FASTQ, `materializeDatasetFASTQ()` creates a temp file named `materialized.fastq`. The `ClassificationConfig.inputFiles` points to this temp file, so `config.inputFiles.first?.deletingPathExtension().lastPathComponent` returns "materialized".

**Fix:** Two changes:

1. **At materialization time** (in `AppDelegate` or wherever `materializeInputFilesIfNeeded()` runs): record the original bundle's display name in the `ClassificationConfig` before passing the materialized file. Add a `sampleDisplayName: String?` property to `ClassificationConfig` that preserves the human-readable name.

2. **At display time** (in `TaxonomyViewController.configure()`): prefer `config.sampleDisplayName` over `config.inputFiles.first?.lastPathComponent` when populating the picker entry.

**Files:**
- `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- `Sources/LungfishApp/AppDelegate.swift` (materialization code)

### 1e. Metadata Import UI Not Visible

**Root cause:** The Inspector sections for metadata and attachments only render when stores are non-nil, but no classifier passes them. There's also no "Import Metadata..." button visible when no metadata exists.

**Fix:**

1. **Always create a `BundleAttachmentStore`** for any classifier result bundle and pass it via `updateClassifierSampleState(... attachments:)`. The store handles empty directories gracefully.

2. **Add "Import Metadata..." button** to the Inspector Document tab that appears when `sampleMetadataStore` is nil. On click:
   - Open `NSOpenPanel` for CSV/TSV files
   - Parse with `SampleMetadataStore(csvData:knownSampleIds:)` using current sample IDs
   - Persist original file to `bundle/metadata/`
   - Set `documentSectionViewModel.sampleMetadataStore`

3. **In each classifier's `MainSplitViewController` wiring**, create and pass a `BundleAttachmentStore` for the result directory.

4. **On load**, check if `bundle/metadata/sample_metadata.tsv` exists and auto-load it into a `SampleMetadataStore`.

**Files:**
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

---

## Unified Action Bar

### ClassifierActionBar

Replace all 5 per-classifier action bar classes with one shared `ClassifierActionBar`:

```swift
@MainActor
final class ClassifierActionBar: NSView {
    // --- Core buttons (all classifiers) ---
    let blastButton: NSButton           // "BLAST Verify" — bolt.fill icon
    let exportButton: NSButton          // "Export" — square.and.arrow.up icon
    let infoLabel: NSTextField          // Center: selected item info text
    let provenanceButton: NSButton      // ⓘ info.circle (right side)

    // --- Callbacks ---
    var onBlastVerify: (() -> Void)?
    var onExport: (() -> Void)?
    var onProvenance: (() -> Void)?

    // --- Extensibility ---
    /// Insert a custom button after Export, before the info label.
    /// Buttons are added in order (left to right).
    func addCustomButton(_ button: NSButton)

    /// Update the info label text (taxon name, read count, etc.).
    func updateInfoText(_ text: String)

    /// Enable/disable BLAST button (disabled when no single row is selected).
    func setBlastEnabled(_ enabled: Bool)
}
```

**Layout (36pt height, matching existing pattern):**

```
| 8pt | [BLAST Verify] 6pt [Export] 6pt [Custom...] | flex info text | [Provenance ⓘ] | 12pt |
```

- Separator NSBox at top
- All buttons: `.accessoryBarAction` bezel style, `.setContentHuggingPriority(.required, for: .horizontal)`
- Info label: 11pt system font, flexes to fill available space
- Provenance button: image-only (`info.circle`), rightmost

### Per-Classifier Customization

| Classifier | Custom Buttons | Removed |
|-----------|----------------|---------|
| **Kraken2** | Collections toggle | — |
| **EsViritu** | — | Re-run button |
| **TaxTriage** | Open Report | Re-run button |
| **NAO-MGS** | — | — |
| **NVD** | — | — |

### Provenance Views for NVD and NAO-MGS

Create `NvdProvenanceView` and `NaoMgsProvenanceView` (SwiftUI) matching the existing pattern:

```
Tool:       [name] v[version]
Database:   [path or name]
Runtime:    [duration]
Input:      [filename]
Samples:    [count]
Date:       [run date]
```

Data sourced from `NvdManifest` and `NaoMgsManifest` respectively — both already contain these fields.

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift`
- Create: `Sources/LungfishApp/Views/Metagenomics/NvdProvenanceView.swift`
- Create: `Sources/LungfishApp/Views/Metagenomics/NaoMgsProvenanceView.swift`
- Remove: Per-classifier action bar inner classes from each VC
- Modify: All 5 result VCs to use `ClassifierActionBar`

---

## Non-Goals (Deferred to Group C+D)

- Multi-row selection in taxonomy views
- "Extract FASTQ" button for all classifiers
- Virtual FASTQ display name consistency throughout the app
- TaxTriage sample filter display name fixes

## Testing

- Sidebar expansion state: manual test — expand nested items, trigger file change, verify they stay expanded
- Panel Layout: manual test — toggle in Inspector, verify split view swaps for all 5 classifiers
- Action bar: manual test — verify BLAST Verify, Export, Info present for all 5; verify Kraken2 has Collections; verify EsViritu has no Re-run
- Materialized name: manual test — run Kraken2 on a downsampled virtual FASTQ, verify sample name shows the subsample name
- Metadata import: manual test — click Import Metadata in Inspector, select TSV, verify table appears
- Provenance: manual test — click ⓘ on NVD and NAO-MGS, verify popover shows pipeline info
