# Multi-Select, Extract FASTQ, and Display Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable multi-row selection across all classifier taxonomy views, add an Extract FASTQ button to the unified action bar, and fix display name consistency for virtual FASTQ bundles.

**Architecture:** Multi-select is enabled on all 5 NSOutlineView/NSTableView instances. Selection handlers branch on count (0, 1, >1) to update detail pane and action bar. Extract FASTQ is added as a core button in ClassifierActionBar. A display name utility resolves human-readable names from bundle manifests.

**Tech Stack:** Swift 6.2, AppKit (NSOutlineView, NSTableView), SwiftUI (extraction sheet), samtools, seqkit, SQLite, `@MainActor`

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionSheet.swift` | SwiftUI extraction confirmation sheet for non-Kraken2 classifiers |
| `Sources/LungfishApp/Services/FASTQDisplayNameResolver.swift` | Utility to resolve human-readable display names for FASTQ bundles |

### Modified Files
| File | Changes |
|------|---------|
| `Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift` | Add Extract FASTQ button, tooltip reason on BLAST |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift` | Enable multi-select, handle multi-selection in delegate |
| `Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift` | Enable multi-select, handle multi-selection |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` | Multi-select detail pane, extract wiring |
| `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` | Multi-select detail pane, extract wiring |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` | Multi-select, extract wiring, display name fixes |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Multi-select, extract wiring |
| `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` | Multi-select, extract wiring |

---

## Task 1: Add Extract FASTQ Button and BLAST Tooltip to ClassifierActionBar

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift`

- [ ] **Step 1: Read the current ClassifierActionBar.swift**

Read the full file. Current core buttons are: `blastButton`, `exportButton`, `infoLabel`, `provenanceButton`. The `rebuildLayout()` method chains `[blastButton, exportButton] + customButtons`. We need to add `extractButton` between `exportButton` and custom buttons.

- [ ] **Step 2: Add extractButton property**

Add after the `exportButton` property declaration:

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
```

Add callback:
```swift
var onExtractFASTQ: (() -> Void)?
```

- [ ] **Step 3: Update setBlastEnabled to accept reason**

Change from:
```swift
func setBlastEnabled(_ enabled: Bool) {
    blastButton.isEnabled = enabled
}
```

To:
```swift
/// Enable/disable BLAST button with explanatory tooltip when disabled.
func setBlastEnabled(_ enabled: Bool, reason: String? = nil) {
    blastButton.isEnabled = enabled
    blastButton.toolTip = enabled ? "Verify selected taxon with BLAST" : reason
}
```

- [ ] **Step 4: Add setExtractEnabled method**

```swift
/// Enable/disable Extract FASTQ button.
func setExtractEnabled(_ enabled: Bool) {
    extractButton.isEnabled = enabled
}
```

- [ ] **Step 5: Wire extractButton in setupUI**

In `setupUI()`, add `extractButton` to subviews and wire the action:

```swift
addSubview(extractButton)
extractButton.target = self
extractButton.action = #selector(extractTapped)
```

Add the action method:
```swift
@objc private func extractTapped(_ sender: NSButton) {
    onExtractFASTQ?()
}
```

- [ ] **Step 6: Update rebuildLayout to include extractButton**

Change the allLeftButtons array from:
```swift
let allLeftButtons: [NSButton] = [blastButton, exportButton] + customButtons
```
To:
```swift
let allLeftButtons: [NSButton] = [blastButton, exportButton, extractButton] + customButtons
```

- [ ] **Step 7: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift
git commit -m "feat: add Extract FASTQ button and BLAST tooltip reason to ClassifierActionBar"
```

---

## Task 2: Display Name Resolution Utility

**Files:**
- Create: `Sources/LungfishApp/Services/FASTQDisplayNameResolver.swift`

- [ ] **Step 1: Create the utility**

```swift
// FASTQDisplayNameResolver.swift — Resolves human-readable display names for FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Resolves human-readable display names for FASTQ bundles and sample IDs.
///
/// Virtual FASTQ bundles have internal file names (e.g., "materialized.fastq") that
/// should not be shown to users. This utility checks the bundle manifest's `.name`
/// field first, then falls back to the URL's last path component.
enum FASTQDisplayNameResolver {

    /// Resolve a display name for a sample ID.
    ///
    /// Resolution order:
    /// 1. FASTQDerivedBundleManifest.name if the sample ID matches a bundle in the project
    /// 2. Bundle URL's last path component minus extension (e.g., "reads.lungfishfastq" → "reads")
    /// 3. Raw sample ID as fallback
    ///
    /// - Parameters:
    ///   - sampleId: The internal sample identifier
    ///   - projectURL: The project root URL for scanning bundles (optional)
    /// - Returns: A human-readable display name
    static func resolveDisplayName(sampleId: String, projectURL: URL? = nil) -> String {
        // Try to find a matching bundle in the project
        if let projectURL {
            let fm = FileManager.default
            // Scan project directory for .lungfishfastq bundles
            if let enumerator = fm.enumerator(
                at: projectURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) {
                for case let url as URL in enumerator {
                    // Check top-level and one level deep for FASTQ bundles
                    if url.pathExtension == "lungfishfastq" {
                        if let name = manifestDisplayName(bundleURL: url, matchingSampleId: sampleId) {
                            return name
                        }
                    }
                    // Also check one level of subdirectories
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        if let subUrls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                            for subUrl in subUrls where subUrl.pathExtension == "lungfishfastq" {
                                if let name = manifestDisplayName(bundleURL: subUrl, matchingSampleId: sampleId) {
                                    return name
                                }
                            }
                        }
                    }
                }
            }
        }

        return sampleId
    }

    /// Read a bundle's derived manifest and return its display name if the bundle matches the sample ID.
    private static func manifestDisplayName(bundleURL: URL, matchingSampleId: String) -> String? {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(FASTQDerivedBundleManifest.self, from: data) else {
            return nil
        }
        // Match by manifest name or bundle filename (minus extension)
        let bundleName = bundleURL.deletingPathExtension().lastPathComponent
        if sampleId(matches: manifest.name, or: bundleName, against: matchingSampleId) {
            return manifest.name
        }
        return nil
    }

    /// Check if a sample ID matches a bundle (case-insensitive, handles common variations).
    private static func sampleId(matches manifestName: String, or bundleName: String, against sampleId: String) -> Bool {
        let lower = sampleId.lowercased()
        return manifestName.lowercased() == lower
            || bundleName.lowercased() == lower
            || bundleName.lowercased().hasPrefix(lower)
            || lower.hasPrefix(bundleName.lowercased())
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQDisplayNameResolver.swift
git commit -m "feat: add FASTQDisplayNameResolver for human-readable bundle display names"
```

---

## Task 3: Enable Multi-Select Across All Classifiers

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`

- [ ] **Step 1: Enable multi-select in all 5 views**

For each file, find `allowsMultipleSelection = false` (or where it should be set) and change to `true`:

1. **TaxonomyTableView.swift** (~line 221): Change `outlineView.allowsMultipleSelection = false` to `true`
2. **ViralDetectionTableView.swift** (~line 329): Change `outlineView.allowsMultipleSelection = false` to `true`
3. **TaxTriageResultViewController.swift** (~line 2380): In the `TaxTriageOrganismTableView` setup, add `tableView.allowsMultipleSelection = true`
4. **NaoMgsResultViewController.swift** (~line 1199): Change `taxonomyTableView.allowsMultipleSelection = false` to `true`
5. **NvdResultViewController.swift** (~line 891): Change `outlineView.allowsMultipleSelection = false` to `true`

- [ ] **Step 2: Update TaxonomyTableView selection handler for multi-select**

In `TaxonomyTableView.swift`, modify `outlineViewSelectionDidChange`:

```swift
public func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !suppressSelectionCallback else { return }

    let selectedRows = outlineView.selectedRowIndexes
    if selectedRows.count == 1 {
        let row = selectedRows.first!
        guard let node = outlineView.item(atRow: row) as? TaxonNode else {
            onNodeSelected?(tree!.root)
            return
        }
        selectedNode = node
        onNodeSelected?(node)
    } else if selectedRows.count > 1 {
        selectedNode = nil
        onMultipleNodesSelected?(selectedRows.count)
    } else {
        selectedNode = nil
        onNodeSelected?(tree!.root)
    }
}
```

Add the new callback property near `onNodeSelected`:
```swift
var onMultipleNodesSelected: ((Int) -> Void)?
```

- [ ] **Step 3: Update each remaining classifier's selection handler similarly**

For each of EsViritu, TaxTriage, NAO-MGS, NVD: read their selection change delegate method and add multi-select handling. Each needs:
- A `onMultipleSelected: ((Int) -> Void)?` callback (or equivalent)
- The selection handler branches on count: 1 → existing behavior, >1 → fire multi callback, 0 → clear

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: enable multi-row selection across all 5 classifier taxonomy views"
```

---

## Task 4: Multi-Selection Detail Pane and Action Bar Updates

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`

- [ ] **Step 1: Add multi-selection placeholder view helper**

Each classifier needs to show a centered placeholder when multiple rows are selected. Create a reusable helper method. Since all 5 VCs are separate classes (no shared base), add a free function or use a shared NSView factory:

In each VC that has a detail pane, add a private method:

```swift
private func showMultiSelectionPlaceholder(count: Int) {
    // Clear existing detail pane content
    // Show centered placeholder with two labels:
    // Primary: "N items selected" (13pt semibold)
    // Secondary: "Select a single row to view details" (11pt, tertiary)
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false

    let primary = NSTextField(labelWithString: "\(count) items selected")
    primary.font = .systemFont(ofSize: 13, weight: .semibold)
    primary.alignment = .center
    primary.translatesAutoresizingMaskIntoConstraints = false

    let secondary = NSTextField(labelWithString: "Select a single row to view details")
    secondary.font = .systemFont(ofSize: 11)
    secondary.textColor = .tertiaryLabelColor
    secondary.alignment = .center
    secondary.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [primary, secondary])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    // Replace detail pane content with container
    // (implementation varies per VC — read the code to find the detail container)
}
```

- [ ] **Step 2: Wire multi-select in TaxonomyViewController**

Handle the new `onMultipleNodesSelected` callback from TaxonomyTableView:

```swift
taxonomyTableView.onMultipleNodesSelected = { [weak self] count in
    guard let self else { return }
    self.showMultiSelectionPlaceholder(count: count)
    self.sunburstView.selectedNode = nil
    self.actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
    self.actionBar.setExtractEnabled(true)
    self.actionBar.updateInfoText("\(count) taxa selected")
}
```

Update the single-selection handler to set BLAST enabled with no reason:
```swift
self.actionBar.setBlastEnabled(true)
self.actionBar.setExtractEnabled(true)
```

Update the no-selection handler:
```swift
self.actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
self.actionBar.setExtractEnabled(false)
```

- [ ] **Step 3: Wire multi-select in EsViritu, TaxTriage, NAO-MGS, NVD**

Same pattern for each: handle multi-select callback, show placeholder, update BLAST/Extract button states. Read each VC to understand its detail pane structure.

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Run existing tests**

Run: `swift test --filter ClassificationUITests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: multi-selection shows placeholder in detail pane, updates action bar states"
```

---

## Task 5: Classifier Extraction Sheet

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionSheet.swift`

- [ ] **Step 1: Create ClassifierExtractionSheet**

A SwiftUI sheet for non-Kraken2 classifiers. Simpler than `TaxonomyExtractionSheet` — no "Include Children" toggle since non-Kraken2 classifiers don't have taxonomy hierarchies.

```swift
// ClassifierExtractionSheet.swift — Extraction confirmation for non-Kraken2 classifiers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Configuration for classifier-based read extraction.
struct ClassifierExtractionConfig {
    let selectedItems: [String]       // organism names, contig names, or accessions
    let sourceDescription: String     // "BAM file" or "SQLite database"
    let outputName: String            // suggested bundle name
    let extractionMethod: ExtractionMethod

    enum ExtractionMethod {
        case samtoolsView(bamURL: URL, regions: [String])  // samtools view -b bam region1 region2
        case databaseQuery(taxIds: [Int], sampleId: String) // NAO-MGS SQLite query
    }
}

/// SwiftUI sheet confirming a read extraction from a classifier result.
struct ClassifierExtractionSheet: View {
    let selectedItems: [String]
    let sourceDescription: String
    @State private var outputName: String
    let onExtract: (String) -> Void  // passes final output name
    let onCancel: () -> Void

    init(selectedItems: [String], sourceDescription: String, suggestedName: String, onExtract: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.selectedItems = selectedItems
        self.sourceDescription = sourceDescription
        self._outputName = State(initialValue: suggestedName)
        self.onExtract = onExtract
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extract FASTQ")
                .font(.headline)

            Divider()

            // Selected items
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected (\(selectedItems.count)):")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(selectedItems, id: \.self) { item in
                            Text(item)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            // Source
            HStack {
                Text("Source:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sourceDescription)
                    .font(.system(size: 11))
            }

            // Output name
            HStack {
                Text("Output name:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $outputName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Extract") { onExtract(outputName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(outputName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionSheet.swift
git commit -m "feat: add ClassifierExtractionSheet for non-Kraken2 read extraction"
```

---

## Task 6: Wire Extract FASTQ for All Classifiers

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`

- [ ] **Step 1: Wire Extract FASTQ for Kraken2**

In `TaxonomyViewController.swift`, wire the `actionBar.onExtractFASTQ` callback:

```swift
actionBar.onExtractFASTQ = { [weak self] in
    guard let self else { return }
    // Collect all selected nodes
    let selectedRows = self.taxonomyTableView.outlineView.selectedRowIndexes
    let nodes: [TaxonNode] = selectedRows.compactMap { row in
        self.taxonomyTableView.outlineView.item(atRow: row) as? TaxonNode
    }
    guard !nodes.isEmpty else { return }

    if nodes.count == 1 {
        self.presentExtractionSheet(for: nodes[0], includeChildren: false)
    } else {
        // Multi-select: present extraction sheet with all nodes
        self.presentExtractionSheet(for: nodes[0], includeChildren: false)
        // TODO: The existing TaxonomyExtractionSheet takes [TaxonNode] —
        // check if it already supports multiple nodes and pass all of them
    }
}
```

Read `TaxonomyExtractionSheet.swift` — it already takes `selectedNodes: [TaxonNode]`. Pass all selected nodes directly:

```swift
actionBar.onExtractFASTQ = { [weak self] in
    guard let self, let result = self.classificationResult else { return }
    let selectedRows = self.taxonomyTableView.outlineView.selectedRowIndexes
    let nodes: [TaxonNode] = selectedRows.compactMap { row in
        self.taxonomyTableView.outlineView.item(atRow: row) as? TaxonNode
    }
    guard !nodes.isEmpty else { return }
    self.presentExtractionSheet(for: nodes)
}
```

You may need to modify `presentExtractionSheet` to accept `[TaxonNode]` if it currently only accepts a single node. Read the method signature and adapt.

- [ ] **Step 2: Wire Extract FASTQ for EsViritu**

```swift
actionBar.onExtractFASTQ = { [weak self] in
    guard let self else { return }
    let selectedRows = self.detectionTableView.outlineView.selectedRowIndexes
    let accessions: [String] = selectedRows.compactMap { row in
        guard let item = self.detectionTableView.outlineView.item(atRow: row) else { return nil }
        // Extract assembly accession from the item
        // Read EsViritu's outline view data source to determine item type
        return nil // placeholder — read the code
    }
    guard !accessions.isEmpty else { return }
    // Present ClassifierExtractionSheet with accessions
    self.presentExtractionSheet(items: accessions, source: "BAM")
}
```

Read the EsViritu VC to find: how items in the outline view map to accessions, and where the BAM file URL is stored. Then implement `presentExtractionSheet(items:source:)` using `ClassifierExtractionSheet`.

- [ ] **Step 3: Wire Extract FASTQ for TaxTriage**

Similar pattern — get selected organism rows, look up their reference accessions from the mapping files, present extraction sheet.

- [ ] **Step 4: Wire Extract FASTQ for NAO-MGS**

NAO-MGS has read data in SQLite. Get selected tax IDs, present extraction sheet. On confirm, query `NaoMgsDatabase.fetchReadsForAccession()` and write FASTQ.

- [ ] **Step 5: Wire Extract FASTQ for NVD**

Get selected contig names from the outline view, use samtools to extract from BAM.

- [ ] **Step 6: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: wire Extract FASTQ for all 5 classifiers"
```

---

## Task 7: Display Name Fixes

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`

- [ ] **Step 1: Fix TaxTriage segmented control and sample picker display names**

In `TaxTriageResultViewController.swift`, find where `sampleIds` are used to build the segmented control labels (~line 595-604) and sample picker entries. Replace raw sample IDs with resolved display names:

```swift
// Before building picker entries, resolve display names
let resolvedNames: [String: String] = Dictionary(uniqueKeysWithValues: sampleIds.map { id in
    (id, FASTQDisplayNameResolver.resolveDisplayName(sampleId: id, projectURL: projectURL))
})

sampleEntries = sampleIds.map { sampleId in
    let count = metrics.filter { $0.sample == sampleId }.count
    let display = resolvedNames[sampleId] ?? sampleId
    return TaxTriageSampleEntry(id: sampleId, displayName: display, organismCount: count)
}
```

Also update the segmented control segment labels to use resolved names:

```swift
// In rebuildSampleFilterSegments():
for (index, sampleId) in sampleIds.enumerated() {
    let displayName = resolvedNames[sampleId] ?? sampleId
    sampleFilterControl.setLabel(displayName, forSegment: index + 1)
}
```

Note: you'll need to store `resolvedNames` as a property or pass it through, since `rebuildSampleFilterSegments()` may be called separately from `configure()`. Read the code flow to determine the best approach.

- [ ] **Step 2: Fix display names in other classifiers**

For Kraken2, EsViritu, NAO-MGS, NVD: find where sample picker entries are built (from our earlier Task 6-8 work) and replace raw sample IDs with `FASTQDisplayNameResolver.resolveDisplayName(sampleId:projectURL:)`.

Each VC needs access to the project URL. Check if it's already available (e.g., from the result URL — walk up to the `.lungfish` project root) or add it as a parameter.

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "fix: use resolved display names instead of internal IDs across all classifiers"
```

---

## Task 8: Final Build and Test Verification

- [ ] **Step 1: Full build**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Run classifier-specific tests**

Run: `swift test --filter ClassificationUITests && swift test --filter ClassificationConfigMutabilityTests`
Expected: All pass

- [ ] **Step 4: Verify no stale references**

Search for old `allowsMultipleSelection = false` in classifier table views:
Run: `grep -rn "allowsMultipleSelection = false" Sources/LungfishApp/Views/Metagenomics/ --include="*.swift"`
Expected: No results (all changed to `true`)
