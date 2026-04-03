# Classifier Bug Fixes and Action Bar Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 6 bugs (sidebar collapse, panel layout, overdraw, materialized name, metadata UI) and unify the bottom action bar across all 5 classifiers with shared BLAST Verify, Export, and Provenance buttons.

**Architecture:** A shared `ClassifierActionBar` NSView replaces 5 per-classifier inner classes. Bug fixes are independent and done first. The action bar is created as a standalone file, then each classifier VC is migrated to use it.

**Tech Stack:** Swift 6.2, AppKit (NSView, NSOutlineView, NSSplitView, NSButton), SwiftUI (provenance popovers), `@MainActor`, NotificationCenter, UserDefaults KVO

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift` | Shared bottom action bar with core buttons + extensibility |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsProvenanceView.swift` | SwiftUI provenance popover for NAO-MGS |
| `Sources/LungfishApp/Views/Metagenomics/NvdProvenanceView.swift` | SwiftUI provenance popover for NVD |

### Modified Files
| File | Changes |
|------|---------|
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | Preserve expansion state across reloads |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` | Panel layout observer, adopt ClassifierActionBar |
| `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` | Panel layout observer, adopt ClassifierActionBar, remove Re-run |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` | Panel layout observer, adopt ClassifierActionBar, remove Re-run |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Adopt ClassifierActionBar, add provenance |
| `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` | Adopt ClassifierActionBar, add provenance |
| `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift` | Add `sampleDisplayName` property |
| `Sources/LungfishApp/AppDelegate.swift` | Set `sampleDisplayName` during materialization |
| `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` | Add "Import Metadata..." button |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | Pass BundleAttachmentStore + auto-load metadata for all 5 classifiers |

### Removed
| Item | Reason |
|------|--------|
| `TaxonomyActionBar.swift` | Replaced by ClassifierActionBar |
| Inner class `EsVirituActionBar` in EsVirituResultViewController.swift | Replaced |
| Inner class `TaxTriageActionBar` in TaxTriageResultViewController.swift | Replaced |
| Inner class `NaoMgsActionBar` in NaoMgsResultViewController.swift | Replaced |
| Inner class `NvdActionBar` in NvdResultViewController.swift | Replaced |

---

## Task 1: Sidebar Expansion State Preservation

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`

- [ ] **Step 1: Read the current reloadFromFilesystem method**

Read `SidebarViewController.swift` and find the `reloadFromFilesystem()` method (~line 672) and `reloadOutlineView()` (~line 507). Understand the full flow: `FileSystemWatcher` callback → `reloadFromFilesystem()` → `rootItems = buildRootItems(...)` → `reloadOutlineView()` → expand root folders.

The problem: `reloadData()` resets all expansion state. Only root-level folders are re-expanded (line 698-700). Nested expanded items collapse.

- [ ] **Step 2: Add expansion state save/restore methods**

Add two private methods to `SidebarViewController`:

```swift
/// Collect URLs of all currently expanded items (recursive).
private func saveExpandedItemURLs() -> Set<URL> {
    var expanded = Set<URL>()
    func collectExpanded(items: [SidebarItem]) {
        for item in items {
            if outlineView.isItemExpanded(item), let url = item.url {
                expanded.insert(url.standardizedFileURL)
            }
            if outlineView.isItemExpanded(item) {
                collectExpanded(items: item.children)
            }
        }
    }
    collectExpanded(items: rootItems)
    return expanded
}

/// Re-expand items whose URLs match the saved set (recursive).
private func restoreExpandedItemURLs(_ urls: Set<URL>) {
    func restoreExpanded(items: [SidebarItem]) {
        for item in items {
            if let url = item.url, urls.contains(url.standardizedFileURL) {
                outlineView.expandItem(item)
                restoreExpanded(items: item.children)
            }
        }
    }
    restoreExpanded(items: rootItems)
}
```

- [ ] **Step 3: Modify reloadFromFilesystem to preserve expansion**

In `reloadFromFilesystem()`, BEFORE `rootItems = buildRootItems(from: projectURL)`, save expansion state. AFTER the existing root-level expansion loop, restore nested expansion:

Change from:
```swift
// Reload the outline view
reloadOutlineView()

// Expand all folders at root level
for item in rootItems where item.type == .folder {
    outlineView.expandItem(item)
}
```

To:
```swift
// Save expansion state before reload
let expandedURLs = saveExpandedItemURLs()

// Reload the outline view
reloadOutlineView()

// Expand all folders at root level
for item in rootItems where item.type == .folder {
    outlineView.expandItem(item)
}

// Restore nested expansion state
restoreExpandedItemURLs(expandedURLs)
```

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "fix: preserve sidebar disclosure triangle expansion state across filesystem reloads"
```

---

## Task 2: Panel Layout Toggle for Kraken2, EsViritu, TaxTriage

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`

- [ ] **Step 1: Read the NAO-MGS reference implementation**

Read `NaoMgsResultViewController.swift` and find:
- The notification observer for `.metagenomicsLayoutSwapRequested` (~line 1383)
- The `handleLayoutSwapRequested` method (~line 1398)
- The `applyLayoutPreference()` method (~line 1414-1451)

This is the working reference. It:
1. Observes `Notification.Name.metagenomicsLayoutSwapRequested`
2. Reads `UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")`
3. Checks if current arrangement already matches (early return if so)
4. Saves split ratio, removes both subviews, re-adds in new order
5. Restores inverse ratio, adjusts subviews

- [ ] **Step 2: Add layout swap to TaxonomyViewController**

In `TaxonomyViewController.swift`, in the `viewDidLoad()` or `loadView()` method, add the notification observer:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleLayoutSwapRequested),
    name: .metagenomicsLayoutSwapRequested,
    object: nil
)
```

Add the handler and layout method. You need to identify which two views are in the split view (sunburst container and table container). Read the `loadView()` or `setupUI()` method to find the split view and its subviews. Then implement `applyLayoutPreference()` following the NAO-MGS pattern exactly, substituting the correct subview references.

```swift
@objc private func handleLayoutSwapRequested(_ notification: Notification) {
    applyLayoutPreference()
}

private func applyLayoutPreference() {
    let tableOnLeft = UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")
    // Identify the split view and its two subviews
    // Check which is currently first
    // Swap if needed, preserve ratio
    // Follow exact NAO-MGS pattern
}
```

- [ ] **Step 3: Add layout swap to EsVirituResultViewController**

Same pattern. In `viewDidLoad()` or `loadView()`, add the notification observer. Implement `applyLayoutPreference()` for EsViritu's split view (detail pane and detection table).

- [ ] **Step 4: Add layout swap to TaxTriageResultViewController**

Same pattern. TaxTriage has a split view with miniBAM viewer and organism table.

- [ ] **Step 5: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix: panel layout toggle now works for Kraken2, EsViritu, and TaxTriage"
```

---

## Task 3: Fix "Materialized" Sample Name

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishApp/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`

- [ ] **Step 1: Add sampleDisplayName to ClassificationConfig**

In `ClassificationConfig.swift`, add a new mutable property:

```swift
/// Human-readable sample name for display. When classification runs on a
/// materialized virtual FASTQ, this preserves the original bundle's sidebar name
/// instead of showing "materialized".
public var sampleDisplayName: String?
```

Add it near the other mutable properties (after `inputFiles`). No changes to the initializer needed — it defaults to nil.

- [ ] **Step 2: Set sampleDisplayName during materialization**

In `AppDelegate.swift`, find the code that calls `materializeInputFilesIfNeeded()` or `materializeDatasetFASTQ()` for classification. This is around line 4664. BEFORE the materialization mutates the config's `inputFiles`, capture the display name from the FASTQ bundle:

```swift
// Before materialization: capture display name from bundle sidebar title
if config.sampleDisplayName == nil {
    let bundleName = bundle.url.deletingPathExtension().lastPathComponent
    config.sampleDisplayName = bundleName
}
```

The exact variable name for the bundle depends on context — read the surrounding code. The bundle URL's last path component (minus extension) gives the sidebar display name.

- [ ] **Step 3: Use sampleDisplayName in TaxonomyViewController**

In `TaxonomyViewController.swift`, find where the Kraken2 sample picker entry is created (from our Task 6 work). Change:

```swift
// OLD:
let sampleName = result.config?.inputFiles.first?.deletingPathExtension().lastPathComponent ?? "Unknown"

// NEW:
let sampleName = result.config?.sampleDisplayName
    ?? result.config?.inputFiles.first?.deletingPathExtension().lastPathComponent
    ?? "Unknown"
```

This prefers the display name, falls back to input file name.

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix: use original bundle display name instead of 'materialized' for Kraken2 sample name"
```

---

## Task 4: ClassifierActionBar

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift`

- [ ] **Step 1: Create ClassifierActionBar.swift**

```swift
// ClassifierActionBar.swift — Unified bottom action bar for all classifier result views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Shared bottom action bar for all classifier result views.
///
/// Provides core buttons (BLAST Verify, Export, Provenance) present for all classifiers,
/// plus a slot for classifier-specific custom buttons inserted between Export and the
/// center info label.
///
/// Layout (36pt height):
/// ```
/// | 8pt | [BLAST Verify] 6pt [Export] 6pt [Custom...] | flex info text | [Provenance ⓘ] | 12pt |
/// ```
@MainActor
final class ClassifierActionBar: NSView {

    // MARK: - Core Buttons

    let blastButton: NSButton = {
        let btn = NSButton()
        btn.title = "BLAST Verify"
        btn.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BLAST Verify")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isEnabled = false
        return btn
    }()

    let exportButton: NSButton = {
        let btn = NSButton()
        btn.title = "Export"
        btn.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    let infoLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    let provenanceButton: NSButton = {
        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Pipeline Info")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageOnly
        btn.controlSize = .small
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    // MARK: - Callbacks

    var onBlastVerify: (() -> Void)?
    var onExport: (() -> Void)?
    var onProvenance: ((NSButton) -> Void)?

    // MARK: - Custom Buttons

    private var customButtons: [NSButton] = []
    private var layoutConstraints: [NSLayoutConstraint] = []

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Public API

    /// Insert a custom button after Export, before the info label.
    func addCustomButton(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        customButtons.append(button)
        addSubview(button)
        rebuildLayout()
    }

    /// Update the center info label text.
    func updateInfoText(_ text: String) {
        infoLabel.stringValue = text
    }

    /// Enable/disable BLAST button.
    func setBlastEnabled(_ enabled: Bool) {
        blastButton.isEnabled = enabled
    }

    // MARK: - Setup

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        // Separator at top
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Core subviews
        addSubview(blastButton)
        addSubview(exportButton)
        addSubview(infoLabel)
        addSubview(provenanceButton)

        // Actions
        blastButton.target = self
        blastButton.action = #selector(blastTapped)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        provenanceButton.target = self
        provenanceButton.action = #selector(provenanceTapped)

        // Height
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        rebuildLayout()
    }

    private func rebuildLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        // Build left-to-right chain: BLAST → Export → [custom...] → infoLabel
        var allLeftButtons: [NSButton] = [blastButton, exportButton] + customButtons

        var constraints: [NSLayoutConstraint] = []

        // First button: 8pt from leading
        constraints.append(allLeftButtons[0].leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8))
        constraints.append(allLeftButtons[0].centerYAnchor.constraint(equalTo: centerYAnchor))

        // Chain remaining buttons
        for i in 1..<allLeftButtons.count {
            constraints.append(allLeftButtons[i].leadingAnchor.constraint(equalTo: allLeftButtons[i - 1].trailingAnchor, constant: 6))
            constraints.append(allLeftButtons[i].centerYAnchor.constraint(equalTo: centerYAnchor))
        }

        // Info label: after last button
        let lastButton = allLeftButtons.last!
        constraints.append(infoLabel.leadingAnchor.constraint(equalTo: lastButton.trailingAnchor, constant: 12))
        constraints.append(infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor))

        // Provenance button: right side
        constraints.append(provenanceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12))
        constraints.append(provenanceButton.centerYAnchor.constraint(equalTo: centerYAnchor))

        // Info label trailing: must not overlap provenance
        constraints.append(infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: provenanceButton.leadingAnchor, constant: -12))

        layoutConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Actions

    @objc private func blastTapped(_ sender: NSButton) {
        onBlastVerify?()
    }

    @objc private func exportTapped(_ sender: NSButton) {
        onExport?()
    }

    @objc private func provenanceTapped(_ sender: NSButton) {
        onProvenance?(sender)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/ClassifierActionBar.swift
git commit -m "feat: add shared ClassifierActionBar with BLAST Verify, Export, and Provenance"
```

---

## Task 5: NVD and NAO-MGS Provenance Views

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/NaoMgsProvenanceView.swift`
- Create: `Sources/LungfishApp/Views/Metagenomics/NvdProvenanceView.swift`

- [ ] **Step 1: Read the existing TaxonomyProvenanceView as reference**

Read `Sources/LungfishApp/Views/Metagenomics/TaxonomyProvenanceView.swift` and `EsVirituProvenanceView` (in EsVirituResultViewController.swift ~line 1162) to understand the SwiftUI provenance view pattern: labeled rows, 320pt width, presented as NSPopover from button.

- [ ] **Step 2: Create NaoMgsProvenanceView.swift**

```swift
// NaoMgsProvenanceView.swift — Pipeline metadata popover for NAO-MGS results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

/// SwiftUI view displaying NAO-MGS pipeline provenance metadata.
struct NaoMgsProvenanceView: View {
    let manifest: NaoMgsManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NAO-MGS Pipeline Info")
                .font(.headline)

            Divider()

            provenanceRow("Source", manifest.sourceFilePath)
            provenanceRow("Import Date", formatDate(manifest.importDate))
            provenanceRow("Format Version", manifest.formatVersion)
            provenanceRow("Hit Count", "\(manifest.hitCount)")
            provenanceRow("Taxon Count", "\(manifest.taxonCount)")
            if let top = manifest.topTaxon {
                provenanceRow("Top Taxon", top)
            }
            if let version = manifest.workflowVersion {
                provenanceRow("Workflow Version", version)
            }
            provenanceRow("Fetched Accessions", "\(manifest.fetchedAccessions.count)")
        }
        .padding(12)
        .frame(width: 320)
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 3: Create NvdProvenanceView.swift**

```swift
// NvdProvenanceView.swift — Pipeline metadata popover for NVD results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

/// SwiftUI view displaying NVD pipeline provenance metadata.
struct NvdProvenanceView: View {
    let manifest: NvdManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NVD Pipeline Info")
                .font(.headline)

            Divider()

            provenanceRow("Experiment", manifest.experiment)
            provenanceRow("Import Date", formatDate(manifest.importDate))
            provenanceRow("Format Version", manifest.formatVersion)
            provenanceRow("Samples", "\(manifest.sampleCount)")
            provenanceRow("Contigs", "\(manifest.contigCount)")
            provenanceRow("Hits", "\(manifest.hitCount)")
            if let dbVersion = manifest.blastDbVersion {
                provenanceRow("BLAST DB Version", dbVersion)
            }
            if let runId = manifest.snakemakeRunId {
                provenanceRow("Snakemake Run ID", runId)
            }
            provenanceRow("Source Directory", manifest.sourceDirectoryPath)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsProvenanceView.swift Sources/LungfishApp/Views/Metagenomics/NvdProvenanceView.swift
git commit -m "feat: add provenance views for NAO-MGS and NVD classifiers"
```

---

## Task 6: Migrate Kraken2 to ClassifierActionBar

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Collections.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Blast.swift`
- Remove: `Sources/LungfishApp/Views/Metagenomics/TaxonomyActionBar.swift`

- [ ] **Step 1: Read the current TaxonomyActionBar usage**

Read `TaxonomyViewController.swift` to find:
- Where `TaxonomyActionBar` is instantiated
- Where it's added to the view hierarchy
- What callbacks are wired (onExtractSequences, onToggleCollections, onToggleBlastResults)
- How `updateSelection` is called

Also read `TaxonomyViewController+Collections.swift` and `TaxonomyViewController+Blast.swift` to find references to `actionBar`.

- [ ] **Step 2: Replace TaxonomyActionBar with ClassifierActionBar**

In `TaxonomyViewController.swift`:

1. Change the `actionBar` property type from `TaxonomyActionBar` to `ClassifierActionBar`:
```swift
private lazy var actionBar: ClassifierActionBar = {
    let bar = ClassifierActionBar()
    return bar
}()
```

2. Add the Collections custom button:
```swift
let collectionsButton = NSButton()
collectionsButton.title = "Collections"
collectionsButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Collections")
collectionsButton.bezelStyle = .accessoryBarAction
collectionsButton.imagePosition = .imageLeading
collectionsButton.controlSize = .small
collectionsButton.font = .systemFont(ofSize: 11)
collectionsButton.setButtonType(.pushOnPushOff)
collectionsButton.setContentHuggingPriority(.required, for: .horizontal)
collectionsButton.target = self
collectionsButton.action = #selector(collectionsToggleTapped)
actionBar.addCustomButton(collectionsButton)
```

3. Wire callbacks:
```swift
actionBar.onBlastVerify = { [weak self] in self?.blastVerifyCurrentSelection() }
actionBar.onExport = { [weak self] in self?.showExportMenu() }
actionBar.onProvenance = { [weak self] sender in self?.showProvenance(from: sender) }
```

4. Update any `actionBar.updateSelection(...)` calls to `actionBar.updateInfoText(...)`.

5. Update any `actionBar.extractButton` references. The extract button is no longer in the action bar (deferred to Group C). Remove the extract button wiring. The "Extract Sequences" functionality remains accessible via right-click context menu.

- [ ] **Step 3: Update TaxonomyViewController+Collections.swift**

Replace references to `actionBar.collectionsButton` with the stored `collectionsButton` property on the VC (or find it via `actionBar.customButtons`).

- [ ] **Step 4: Update TaxonomyViewController+Blast.swift**

Replace references to `actionBar.blastResultsButton` with the BLAST drawer toggle from the existing drawer tab system.

- [ ] **Step 5: Delete TaxonomyActionBar.swift**

```bash
git rm Sources/LungfishApp/Views/Metagenomics/TaxonomyActionBar.swift
```

- [ ] **Step 6: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 7: Run tests**

Run: `swift test --filter ClassificationUITests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: migrate Kraken2 to ClassifierActionBar, fix bottom bar overdraw"
```

---

## Task 7: Migrate EsViritu to ClassifierActionBar

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`

- [ ] **Step 1: Read the current EsVirituActionBar**

Find the inner class `EsVirituActionBar` (~line 992). Understand what callbacks exist and how `updateSelection` works.

- [ ] **Step 2: Replace EsVirituActionBar with ClassifierActionBar**

1. Delete the inner `EsVirituActionBar` class (entire block, ~lines 992-1160).

2. Change the `actionBar` property:
```swift
private lazy var actionBar: ClassifierActionBar = {
    let bar = ClassifierActionBar()
    return bar
}()
```

3. Wire callbacks:
```swift
actionBar.onBlastVerify = { [weak self] in self?.blastVerifyCurrentSelection() }
actionBar.onExport = { [weak self] in self?.showExportMenu() }
actionBar.onProvenance = { [weak self] sender in self?.showProvenance(from: sender) }
```

4. **Remove Re-run button** — do NOT add it as a custom button.

5. Replace `actionBar.updateSelection(...)` calls with `actionBar.updateInfoText(...)`. Format the info text the same way the old bar did.

6. Wire provenance to show the existing `EsVirituProvenanceView` in an NSPopover.

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: migrate EsViritu to ClassifierActionBar, remove Re-run button"
```

---

## Task 8: Migrate TaxTriage to ClassifierActionBar

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`

- [ ] **Step 1: Read the current TaxTriageActionBar**

Find the inner class `TaxTriageActionBar` (~line 2698). Note: it has Export, Re-run, Open Report, Related, and Provenance.

- [ ] **Step 2: Replace TaxTriageActionBar with ClassifierActionBar**

1. Delete the inner `TaxTriageActionBar` class.

2. Change the `actionBar` property to `ClassifierActionBar`.

3. Add Open Report as a custom button:
```swift
let openReportButton = NSButton()
openReportButton.title = "Open Report"
openReportButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open Report")
openReportButton.bezelStyle = .accessoryBarAction
openReportButton.imagePosition = .imageLeading
openReportButton.controlSize = .small
openReportButton.font = .systemFont(ofSize: 11)
openReportButton.setContentHuggingPriority(.required, for: .horizontal)
openReportButton.target = self
openReportButton.action = #selector(openExternalTapped)
actionBar.addCustomButton(openReportButton)
```

4. Wire core callbacks:
```swift
actionBar.onBlastVerify = { [weak self] in self?.blastVerifyCurrentSelection() }
actionBar.onExport = { [weak self] in self?.showExportMenu() }
actionBar.onProvenance = { [weak self] sender in self?.showProvenance(from: sender) }
```

5. **Remove Re-run button** — do NOT add as custom button.

6. Replace `actionBar.updateSelection(...)` calls with `actionBar.updateInfoText(...)`.

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: migrate TaxTriage to ClassifierActionBar, remove Re-run button"
```

---

## Task 9: Migrate NAO-MGS to ClassifierActionBar

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`

- [ ] **Step 1: Read the current NaoMgsActionBar**

Find the inner class `NaoMgsActionBar` (~line 2024). It only has Export.

- [ ] **Step 2: Replace NaoMgsActionBar with ClassifierActionBar**

1. Delete the inner `NaoMgsActionBar` class.

2. Change the `actionBar` property to `ClassifierActionBar`.

3. Wire callbacks:
```swift
actionBar.onBlastVerify = { [weak self] in self?.blastVerifyCurrentSelection() }
actionBar.onExport = { [weak self] in self?.showExportMenu() }
actionBar.onProvenance = { [weak self] sender in self?.showProvenance(from: sender) }
```

4. Wire provenance to show `NaoMgsProvenanceView` in an NSPopover. Pattern:
```swift
private func showProvenance(from button: NSButton) {
    guard let manifest = naoMgsManifest else { return }
    let popover = NSPopover()
    popover.contentViewController = NSHostingController(rootView: NaoMgsProvenanceView(manifest: manifest))
    popover.behavior = .transient
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
}
```

5. Replace `actionBar.updateSelection(...)` / `actionBar.updateSelectionRow(...)` with `actionBar.updateInfoText(...)`.

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: migrate NAO-MGS to ClassifierActionBar, add provenance"
```

---

## Task 10: Migrate NVD to ClassifierActionBar

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`

- [ ] **Step 1: Read the current NvdActionBar**

Find the inner class `NvdActionBar` (~line 1876). It has BLAST Verify and Export.

- [ ] **Step 2: Replace NvdActionBar with ClassifierActionBar**

1. Delete the inner `NvdActionBar` class.

2. Change the `actionBar` property to `ClassifierActionBar`.

3. Wire callbacks:
```swift
actionBar.onBlastVerify = { [weak self] in self?.blastVerifyCurrentSelection() }
actionBar.onExport = { [weak self] in self?.showExportMenu() }
actionBar.onProvenance = { [weak self] sender in self?.showProvenance(from: sender) }
```

4. Wire provenance to show `NvdProvenanceView` in an NSPopover:
```swift
private func showProvenance(from button: NSButton) {
    guard let manifest = nvdManifest else { return }
    let popover = NSPopover()
    popover.contentViewController = NSHostingController(rootView: NvdProvenanceView(manifest: manifest))
    popover.behavior = .transient
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
}
```

5. Replace `actionBar.updateSelection(...)` with `actionBar.updateInfoText(...)`.

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: migrate NVD to ClassifierActionBar, add provenance"
```

---

## Task 11: Wire Metadata Import and Attachments in Inspector

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] **Step 1: Add "Import Metadata..." button to Inspector**

In `InspectorViewController.swift`, in the `MetagenomicsResultSummarySection` SwiftUI body, AFTER the classifier sample picker block and BEFORE the metadata section, add a button that shows when no metadata is loaded:

```swift
if viewModel.sampleMetadataStore == nil {
    Divider().padding(.vertical, 4)
    Button("Import Metadata\u{2026}") {
        importMetadata()
    }
    .controlSize(.small)
}
```

Add the `importMetadata()` method to `InspectorViewController` (not the SwiftUI view — use a callback or notification):

```swift
private func importMetadata() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.message = "Select a CSV or TSV file with sample metadata"

    guard let window = self.view.window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
        guard response == .OK, let url = panel.url else { return }
        self?.handleMetadataImport(from: url)
    }
}
```

The `handleMetadataImport` method needs to:
1. Read the file data
2. Get known sample IDs from `documentSectionViewModel.classifierSampleEntries`
3. Create `SampleMetadataStore(csvData:knownSampleIds:)`
4. Set `documentSectionViewModel.sampleMetadataStore`
5. If a bundle URL is available, persist to `bundle/metadata/`

- [ ] **Step 2: Pass BundleAttachmentStore from MainSplitViewController**

In `MainSplitViewController.swift`, at each of the 5 classifier wiring call sites, create and pass a `BundleAttachmentStore`:

For NAO-MGS (~line 1947):
```swift
self.inspectorController?.updateClassifierSampleState(
    pickerState: placeholderVC.samplePickerState,
    entries: placeholderVC.sampleEntries,
    strippedPrefix: placeholderVC.strippedPrefix,
    attachments: BundleAttachmentStore(bundleURL: bundleURL)
)
```

For NVD (~line 2037): same pattern with `bundleURL`.

For Kraken2, EsViritu, TaxTriage: use their result directory URL. Check each call site to find the available URL variable.

Also auto-load metadata if `bundle/metadata/sample_metadata.tsv` exists:
```swift
let knownIds = Set(placeholderVC.sampleEntries.map(\.id))
let metadata = SampleMetadataStore.load(from: bundleURL, knownSampleIds: knownIds)
self.inspectorController?.updateClassifierSampleState(
    pickerState: ...,
    entries: ...,
    strippedPrefix: ...,
    metadata: metadata,
    attachments: BundleAttachmentStore(bundleURL: bundleURL)
)
```

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: wire metadata import button and attachment stores for all classifiers"
```

---

## Task 12: Final Build and Test Verification

- [ ] **Step 1: Full build**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (151+ tests across 31+ suites)

- [ ] **Step 3: Run classifier-specific tests**

Run: `swift test --filter ClassificationUITests && swift test --filter SidebarFilterTests && swift test --filter ClassificationConfigMutabilityTests`
Expected: All pass

- [ ] **Step 4: Verify no stale references to old action bar types**

Search for old type names that should no longer exist:
- `TaxonomyActionBar` (the class, not the file reference in git)
- `EsVirituActionBar`
- `TaxTriageActionBar`
- `NaoMgsActionBar`
- `NvdActionBar`

Run: `grep -r "EsVirituActionBar\|TaxTriageActionBar\|NaoMgsActionBar\|NvdActionBar" Sources/ --include="*.swift" | head -5`
Expected: No results (all replaced by ClassifierActionBar)
