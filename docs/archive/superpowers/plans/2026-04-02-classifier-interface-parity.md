# Classifier Interface Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Kraken2, EsViritu, and TaxTriage classification interfaces to parity with NAO-MGS/NVD by adding a unified inspector sample picker, sample metadata import/editing, file attachments, and missing per-classifier controls.

**Architecture:** A unified `ClassifierSamplePickerView` (SwiftUI) replaces the two existing per-classifier pickers. A single `ClassifierSamplePickerState` observable state class is shared. Inspector wiring is generalized through one method on InspectorViewController. Sample metadata and attachments are stored inside classification bundles.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (NSView/NSOutlineView/NSSplitView), `@Observable` macro, `@MainActor` isolation, NotificationCenter

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/LungfishCore/Models/ClassifierSamplePickerState.swift` | Unified `@Observable` picker state + `ClassifierSampleEntry` protocol |
| `Sources/LungfishApp/Views/Metagenomics/ClassifierSamplePickerView.swift` | Unified SwiftUI picker view (replaces NaoMgs/Nvd pickers) |
| `Sources/LungfishCore/Models/SampleMetadataStore.swift` | Metadata import, storage, editing, persistence |
| `Sources/LungfishApp/Views/Inspector/Sections/SampleMetadataSection.swift` | Inspector SwiftUI section for metadata display/edit |
| `Sources/LungfishApp/Views/Inspector/Sections/AttachmentsSection.swift` | Inspector SwiftUI section for file attachments |
| `Sources/LungfishCore/Models/BundleAttachmentStore.swift` | Attachment file management (copy, list, remove) |
| `Tests/LungfishCoreTests/ClassifierSamplePickerStateTests.swift` | Unit tests for picker state |
| `Tests/LungfishCoreTests/SampleMetadataStoreTests.swift` | Unit tests for metadata import/edit/persistence |
| `Tests/LungfishCoreTests/BundleAttachmentStoreTests.swift` | Unit tests for attachment management |

### Modified Files
| File | Changes |
|------|---------|
| `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` | Replace NAO-MGS/NVD picker properties with unified ones; add metadata/attachment store properties |
| `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` | Replace two update methods with one; render unified picker + metadata + attachments |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | Wire inspector updates for all 5 classifiers |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Adopt unified picker types |
| `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` | Adopt unified picker types |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` | Add picker state, BLAST drawer |
| `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` | Add picker state |
| `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` | Add picker state, organism search field |
| `Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift` | Add `sample_metadata` entity kind + indexing |

### Removed Files
| File | Reason |
|------|--------|
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift` | Replaced by ClassifierSamplePickerView |
| `Sources/LungfishApp/Views/Metagenomics/NvdSamplePickerView.swift` | Replaced by ClassifierSamplePickerView |

---

## Task 1: Unified Picker State and Protocol

**Files:**
- Create: `Sources/LungfishCore/Models/ClassifierSamplePickerState.swift`
- Create: `Tests/LungfishCoreTests/ClassifierSamplePickerStateTests.swift`

- [ ] **Step 1: Write failing tests for ClassifierSamplePickerState**

```swift
// Tests/LungfishCoreTests/ClassifierSamplePickerStateTests.swift
import Testing
@testable import LungfishCore

@Suite("ClassifierSamplePickerState")
struct ClassifierSamplePickerStateTests {

    @Test("Initializes with all samples selected")
    func initSelectsAll() {
        let state = ClassifierSamplePickerState(allSamples: Set(["A", "B", "C"]))
        #expect(state.selectedSamples == Set(["A", "B", "C"]))
    }

    @Test("Toggle removes selected sample")
    func toggleRemove() {
        let state = ClassifierSamplePickerState(allSamples: Set(["A", "B"]))
        state.selectedSamples.remove("A")
        #expect(state.selectedSamples == Set(["B"]))
    }

    @Test("Toggle adds deselected sample")
    func toggleAdd() {
        let state = ClassifierSamplePickerState(allSamples: Set(["A", "B"]))
        state.selectedSamples.remove("A")
        state.selectedSamples.insert("A")
        #expect(state.selectedSamples == Set(["A", "B"]))
    }

    @Test("commonPrefix strips at word boundary")
    func commonPrefixWordBoundary() {
        let names = ["sample_A_001", "sample_A_002", "sample_A_003"]
        let prefix = ClassifierSamplePickerView.commonPrefix(of: names)
        #expect(prefix == "sample_A_")
    }

    @Test("commonPrefix returns empty for single name")
    func commonPrefixSingleName() {
        #expect(ClassifierSamplePickerView.commonPrefix(of: ["onlyone"]) == "")
    }

    @Test("commonPrefix returns empty for no common boundary")
    func commonPrefixNoBoundary() {
        #expect(ClassifierSamplePickerView.commonPrefix(of: ["abc", "abd"]) == "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClassifierSamplePickerStateTests 2>&1 | head -20`
Expected: Compilation failure — `ClassifierSamplePickerState` not found

- [ ] **Step 3: Create ClassifierSamplePickerState.swift**

```swift
// Sources/LungfishCore/Models/ClassifierSamplePickerState.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Protocol for classifier-specific sample entries in the unified picker.
///
/// Each classifier provides a concrete type with its own metric (hit count,
/// read count, TASS score, etc.). The picker view renders `metricValue`
/// right-aligned next to each sample name.
public protocol ClassifierSampleEntry: Identifiable, Sendable where ID == String {
    var id: String { get }
    var displayName: String { get }
    /// Short label for the metric column header (e.g., "hits", "reads", "TASS").
    var metricLabel: String { get }
    /// Formatted metric value (e.g., "1,234").
    var metricValue: String { get }
    /// Optional secondary metric (e.g., NVD shows "contigs / hits").
    var secondaryMetric: String? { get }
}

/// Default implementation: no secondary metric.
extension ClassifierSampleEntry {
    public var secondaryMetric: String? { nil }
}

/// Observable state shared between the sample picker view, toolbar popover,
/// and Inspector embedding.
///
/// Uses `@Observable` instead of raw `Binding<Set<String>>` to ensure
/// SwiftUI views inside `NSHostingController` popovers correctly reflect
/// selection changes across the AppKit/SwiftUI boundary.
@Observable
public final class ClassifierSamplePickerState: @unchecked Sendable {
    public var selectedSamples: Set<String>

    public init(allSamples: Set<String>) {
        self.selectedSamples = allSamples
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClassifierSamplePickerStateTests`
Expected: All 6 tests pass (note: `commonPrefix` tests will fail until Task 2 — that's OK, mark those as pending or move to Task 2)

Actually — `commonPrefix` is on the View, not the state. Move those tests to Task 2. Run the 3 state tests:

Run: `swift test --filter ClassifierSamplePickerStateTests`
Expected: 3 tests pass (init, toggle remove, toggle add)

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Models/ClassifierSamplePickerState.swift Tests/LungfishCoreTests/ClassifierSamplePickerStateTests.swift
git commit -m "feat: add ClassifierSamplePickerState and ClassifierSampleEntry protocol"
```

---

## Task 2: Unified Sample Picker View

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/ClassifierSamplePickerView.swift`

- [ ] **Step 1: Create ClassifierSamplePickerView.swift**

This replaces both `NaoMgsSamplePickerView` and `NvdSamplePickerView`. The view is generic over entry type via `[any ClassifierSampleEntry]`.

```swift
// Sources/LungfishApp/Views/Metagenomics/ClassifierSamplePickerView.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Unified SwiftUI picker for selecting samples across all classifier types.
///
/// Shows a searchable, scrollable checklist. Each row displays the sample's
/// display name and right-aligned metric value. Supports inline embedding
/// in the Inspector or fixed-size popover from a toolbar button.
struct ClassifierSamplePickerView: View {

    let samples: [any ClassifierSampleEntry]
    @Bindable var pickerState: ClassifierSamplePickerState
    @State private var searchText: String = ""
    let strippedPrefix: String
    var isInline: Bool = false

    private var filteredSamples: [any ClassifierSampleEntry] {
        if searchText.isEmpty { return samples }
        return samples.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var allVisibleSelected: Bool {
        let visibleIds = Set(filteredSamples.map(\.id))
        return !visibleIds.isEmpty && visibleIds.isSubset(of: pickerState.selectedSamples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Filter\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Select All toggle
            HStack {
                Toggle(isOn: Binding(
                    get: { allVisibleSelected },
                    set: { newValue in
                        let visibleIds = Set(filteredSamples.map(\.id))
                        if newValue {
                            pickerState.selectedSamples.formUnion(visibleIds)
                        } else {
                            pickerState.selectedSamples.subtract(visibleIds)
                        }
                    }
                )) {
                    Text("Select All")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)

                Spacer()

                Text("\(samples.count) total")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if !strippedPrefix.isEmpty {
                Text("Prefix: \(strippedPrefix)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            Divider()

            // Sample list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredSamples.indices, id: \.self) { index in
                        sampleRow(filteredSamples[index])
                    }
                }
            }
            .frame(maxHeight: isInline ? .infinity : 300)
        }
        .frame(width: isInline ? nil : 360)
    }

    private func sampleRow(_ sample: any ClassifierSampleEntry) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { pickerState.selectedSamples.contains(sample.id) },
                set: { newValue in
                    if newValue {
                        pickerState.selectedSamples.insert(sample.id)
                    } else {
                        pickerState.selectedSamples.remove(sample.id)
                    }
                }
            )) {
                Text(sample.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)

            Spacer()

            if let secondary = sample.secondaryMetric {
                Text(secondary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(sample.metricLabel)
            } else {
                Text(sample.metricValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    /// Computes the longest common prefix across all sample names, breaking at word boundaries.
    static func commonPrefix(of names: [String]) -> String {
        guard let first = names.first, names.count > 1 else { return "" }
        var prefix = first
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) && !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        if let lastSep = prefix.lastIndex(where: { $0 == "_" || $0 == "-" }) {
            prefix = String(prefix[...lastSep])
        } else {
            prefix = ""
        }
        return prefix
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds (the new view is not yet referenced by anything)

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/ClassifierSamplePickerView.swift
git commit -m "feat: add unified ClassifierSamplePickerView"
```

---

## Task 3: Migrate NAO-MGS to Unified Picker

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Remove: `Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift`

- [ ] **Step 1: Create NAO-MGS concrete entry type in NaoMgsResultViewController.swift**

Add at the top of the file (after imports), replacing any local reference to `NaoMgsSampleEntry`:

```swift
/// NAO-MGS sample entry for the unified picker.
struct NaoMgsSampleEntry: ClassifierSampleEntry {
    let id: String
    let displayName: String
    let hitCount: Int

    var metricLabel: String { "hits" }
    var metricValue: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: hitCount)) ?? "\(hitCount)"
    }
}
```

- [ ] **Step 2: Replace NaoMgsSamplePickerState with ClassifierSamplePickerState**

In `NaoMgsResultViewController.swift`, find all references to `NaoMgsSamplePickerState` and replace with `ClassifierSamplePickerState`. The property declaration changes from:

```swift
public let samplePickerState = NaoMgsSamplePickerState()
```

to:

```swift
public var samplePickerState: ClassifierSamplePickerState!
```

And in the `configure()` method where samples are set up, change initialization from `samplePickerState.selectedSamples = selectedSamples` to:

```swift
samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleNames))
```

- [ ] **Step 3: Replace popover picker creation**

Find where `NaoMgsSamplePickerView` is instantiated for the toolbar popover and replace with `ClassifierSamplePickerView`:

```swift
let pickerView = ClassifierSamplePickerView(
    samples: sampleEntries,
    pickerState: samplePickerState,
    strippedPrefix: strippedPrefix,
    isInline: false
)
```

- [ ] **Step 4: Remove NaoMgsSamplePickerView.swift**

```bash
git rm Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift
```

- [ ] **Step 5: Build to verify no compilation errors**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds. All references to old types are resolved.

- [ ] **Step 6: Run existing classification tests**

Run: `swift test --filter ClassificationUITests 2>&1 | tail -10`
Expected: All tests pass (no regression)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: migrate NAO-MGS to unified ClassifierSamplePickerView"
```

---

## Task 4: Migrate NVD to Unified Picker

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Remove: `Sources/LungfishApp/Views/Metagenomics/NvdSamplePickerView.swift`

- [ ] **Step 1: Create NVD concrete entry type in NvdResultViewController.swift**

```swift
/// NVD sample entry for the unified picker.
public struct NvdSampleEntry: ClassifierSampleEntry {
    public let id: String
    public let displayName: String
    public let contigCount: Int
    public let hitCount: Int

    public var metricLabel: String { "Contigs / Hits" }
    public var metricValue: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let c = formatter.string(from: NSNumber(value: contigCount)) ?? "\(contigCount)"
        let h = formatter.string(from: NSNumber(value: hitCount)) ?? "\(hitCount)"
        return "\(c) / \(h)"
    }
    public var secondaryMetric: String? { metricValue }

    public init(id: String, displayName: String, contigCount: Int, hitCount: Int) {
        self.id = id
        self.displayName = displayName
        self.contigCount = contigCount
        self.hitCount = hitCount
    }
}
```

- [ ] **Step 2: Replace NvdSamplePickerState with ClassifierSamplePickerState**

Same pattern as Task 3 Step 2. Change:
```swift
public let samplePickerState = NvdSamplePickerState()
```
to:
```swift
public var samplePickerState: ClassifierSamplePickerState!
```

Initialize in configure: `samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleNames))`

- [ ] **Step 3: Replace popover picker instantiation with ClassifierSamplePickerView**

Same pattern as Task 3 Step 3.

- [ ] **Step 4: Remove NvdSamplePickerView.swift**

```bash
git rm Sources/LungfishApp/Views/Metagenomics/NvdSamplePickerView.swift
```

- [ ] **Step 5: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: migrate NVD to unified ClassifierSamplePickerView"
```

---

## Task 5: Generalize Inspector Wiring

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

- [ ] **Step 1: Replace per-classifier picker properties in DocumentSectionViewModel**

In `DocumentSection.swift`, replace the two picker state sections (lines 112-127):

```swift
// OLD:
// var samplePickerState: NaoMgsSamplePickerState?
// var sampleEntries: [NaoMgsSampleEntry] = []
// var sampleStrippedPrefix: String = ""
// var nvdSamplePickerState: NvdSamplePickerState?
// var nvdSampleEntries: [NvdSampleEntry] = []
// var nvdSampleStrippedPrefix: String = ""

// NEW:
// MARK: - Unified Classifier Sample Picker
/// Shared sample picker state for Inspector-embedded sample selector (all classifiers).
var classifierPickerState: ClassifierSamplePickerState?
/// Sample entries for the unified picker view.
var classifierSampleEntries: [any ClassifierSampleEntry] = []
/// Common prefix stripped from sample display names.
var classifierStrippedPrefix: String = ""
/// Sample metadata store for the current classifier bundle.
var sampleMetadataStore: SampleMetadataStore?
/// Bundle attachment store for the current classifier bundle.
var bundleAttachmentStore: BundleAttachmentStore?
```

Add `import LungfishCore` at the top if not already present.

- [ ] **Step 2: Replace per-classifier update methods in InspectorViewController**

In `InspectorViewController.swift`, replace the two methods (`updateMetagenomicsSampleState` and `updateNvdSampleState`) with one:

```swift
/// Wires unified classifier sample picker state for Inspector-embedded sample selector.
func updateClassifierSampleState(
    pickerState: ClassifierSamplePickerState,
    entries: [any ClassifierSampleEntry],
    strippedPrefix: String,
    metadata: SampleMetadataStore? = nil,
    attachments: BundleAttachmentStore? = nil
) {
    viewModel.documentSectionViewModel.classifierPickerState = pickerState
    viewModel.documentSectionViewModel.classifierSampleEntries = entries
    viewModel.documentSectionViewModel.classifierStrippedPrefix = strippedPrefix
    viewModel.documentSectionViewModel.sampleMetadataStore = metadata
    viewModel.documentSectionViewModel.bundleAttachmentStore = attachments
}
```

Keep the existing `updateNaoMgsManifest` and `updateNvdManifest` methods as-is (they handle classifier-specific metadata, not the picker).

- [ ] **Step 3: Replace per-classifier picker rendering in Inspector Document tab**

In `InspectorViewController.swift`, replace the two separate rendering blocks (NAO-MGS picker at ~line 1529 and NVD picker at ~line 1549) with one unified block:

```swift
if let pickerState = viewModel.classifierPickerState,
   !viewModel.classifierSampleEntries.isEmpty {
    Divider()
        .padding(.vertical, 4)

    VStack(alignment: .leading, spacing: 6) {
        Text("Sample Filter")
            .font(.caption.weight(.semibold))

        ClassifierSamplePickerView(
            samples: viewModel.classifierSampleEntries,
            pickerState: pickerState,
            strippedPrefix: viewModel.classifierStrippedPrefix,
            isInline: true
        )
    }
    .onChange(of: pickerState.selectedSamples) { _, _ in
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
    }
}
```

- [ ] **Step 4: Update MainSplitViewController NAO-MGS wiring**

In `MainSplitViewController.swift`, replace the NAO-MGS inspector call (~line 1914):

```swift
// OLD:
// self.inspectorController?.updateMetagenomicsSampleState(
//     pickerState: placeholderVC.samplePickerState,
//     entries: placeholderVC.sampleEntries,
//     strippedPrefix: placeholderVC.strippedPrefix
// )

// NEW:
self.inspectorController?.updateClassifierSampleState(
    pickerState: placeholderVC.samplePickerState,
    entries: placeholderVC.sampleEntries,
    strippedPrefix: placeholderVC.strippedPrefix
)
```

- [ ] **Step 5: Update MainSplitViewController NVD wiring**

Replace the NVD inspector call (~line 2004):

```swift
// OLD:
// self.inspectorController?.updateNvdSampleState(...)

// NEW:
self.inspectorController?.updateClassifierSampleState(
    pickerState: placeholderVC.samplePickerState,
    entries: placeholderVC.sampleEntries,
    strippedPrefix: placeholderVC.strippedPrefix
)
```

- [ ] **Step 6: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: generalize inspector wiring to unified ClassifierSamplePickerView"
```

---

## Task 6: Add Inspector Picker to Kraken2

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] **Step 1: Add Kraken2 sample entry type and picker state to TaxonomyViewController**

Kraken2 is currently single-sample only. We add a single-entry picker so the inspector has something to display (consistent UX) and it's ready for multi-sample when that's added. Add near the top of the class:

```swift
/// Kraken2 sample entry for the unified picker.
struct Kraken2SampleEntry: ClassifierSampleEntry {
    let id: String
    let displayName: String
    let classifiedReads: Int

    var metricLabel: String { "reads" }
    var metricValue: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: classifiedReads)) ?? "\(classifiedReads)"
    }
}

/// Picker state for Inspector embedding.
public var samplePickerState: ClassifierSamplePickerState!
/// Sample entries for the unified picker.
public var sampleEntries: [Kraken2SampleEntry] = []
/// Common prefix stripped from display names.
public var strippedPrefix: String = ""
```

- [ ] **Step 2: Populate picker state in configure(result:)**

In the `configure(result:)` method (after the tree is loaded), add:

```swift
// Build single-sample picker entry from classification result
let sampleName = result.config?.sampleName ?? result.url.deletingPathExtension().lastPathComponent
sampleEntries = [Kraken2SampleEntry(
    id: sampleName,
    displayName: sampleName,
    classifiedReads: result.tree.classifiedReads
)]
strippedPrefix = ""
samplePickerState = ClassifierSamplePickerState(allSamples: Set([sampleName]))
```

- [ ] **Step 3: Wire inspector in MainSplitViewController**

In `displayClassificationResult(at:)` (~line 1715), after `viewerController.displayTaxonomyResult(result)`, add:

```swift
// Wire sample picker to Inspector
if let taxonomyVC = viewerController.currentMetagenomicsVC as? TaxonomyViewController {
    self.inspectorController?.updateClassifierSampleState(
        pickerState: taxonomyVC.samplePickerState,
        entries: taxonomyVC.sampleEntries,
        strippedPrefix: taxonomyVC.strippedPrefix
    )
}
```

Note: You'll need to check how the viewer controller exposes the current metagenomics VC. It may be through a stored property on ViewerViewController. Inspect `ViewerViewController+Classification.swift` for the pattern — NAO-MGS and NVD store their result VCs for later access.

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add inspector sample picker to Kraken2 taxonomy browser"
```

---

## Task 7: Add Inspector Picker to EsViritu

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] **Step 1: Add EsViritu sample entry type and picker state**

EsViritu is single-sample. Add to `EsVirituResultViewController`:

```swift
/// EsViritu sample entry for the unified picker.
struct EsVirituSampleEntry: ClassifierSampleEntry {
    let id: String
    let displayName: String
    let detectedVirusCount: Int

    var metricLabel: String { "viruses" }
    var metricValue: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: detectedVirusCount)) ?? "\(detectedVirusCount)"
    }
}

public var samplePickerState: ClassifierSamplePickerState!
public var sampleEntries: [EsVirituSampleEntry] = []
public var strippedPrefix: String = ""
```

- [ ] **Step 2: Populate picker state in configure()**

After detections are loaded:

```swift
let sampleName = esVirituResult?.sampleId ?? "Unknown"
let virusCount = assemblies.count
sampleEntries = [EsVirituSampleEntry(
    id: sampleName,
    displayName: sampleName,
    detectedVirusCount: virusCount
)]
strippedPrefix = ""
samplePickerState = ClassifierSamplePickerState(allSamples: Set([sampleName]))
```

- [ ] **Step 3: Wire inspector in MainSplitViewController**

In `displayEsVirituResult(at:)` (~line 1770), after `viewerController.displayEsVirituResult(...)`, add inspector wiring:

```swift
if let esVirituVC = viewerController.currentMetagenomicsVC as? EsVirituResultViewController {
    self.inspectorController?.updateClassifierSampleState(
        pickerState: esVirituVC.samplePickerState,
        entries: esVirituVC.sampleEntries,
        strippedPrefix: esVirituVC.strippedPrefix
    )
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add inspector sample picker to EsViritu viral detection browser"
```

---

## Task 8: Add Inspector Picker and Organism Search to TaxTriage

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

- [ ] **Step 1: Add TaxTriage sample entry type and picker state**

TaxTriage is multi-sample. Add to `TaxTriageResultViewController`:

```swift
/// TaxTriage sample entry for the unified picker.
struct TaxTriageSampleEntry: ClassifierSampleEntry {
    let id: String
    let displayName: String
    let organismCount: Int

    var metricLabel: String { "organisms" }
    var metricValue: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: organismCount)) ?? "\(organismCount)"
    }
}

public var samplePickerState: ClassifierSamplePickerState!
public var sampleEntries: [TaxTriageSampleEntry] = []
public var strippedPrefix: String = ""
```

- [ ] **Step 2: Populate picker state after samples are discovered**

In the configure method, after `sampleIds` are extracted and metrics are parsed:

```swift
let sampleNames = sampleIds
let prefix = ClassifierSamplePickerView.commonPrefix(of: sampleNames)
strippedPrefix = prefix
sampleEntries = sampleIds.map { sampleId in
    let count = metrics.filter { $0.sample == sampleId }.count
    let display = prefix.isEmpty ? sampleId : String(sampleId.dropFirst(prefix.count))
    return TaxTriageSampleEntry(id: sampleId, displayName: display, organismCount: count)
}
samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleIds))
```

- [ ] **Step 3: Observe inspector sample selection changes**

Add an observer for `.metagenomicsSampleSelectionChanged` in `viewDidLoad()`:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleInspectorSampleSelectionChanged),
    name: .metagenomicsSampleSelectionChanged,
    object: nil
)
```

And the handler:

```swift
@objc private func handleInspectorSampleSelectionChanged() {
    guard let pickerState = samplePickerState else { return }
    let visibleSamples = pickerState.selectedSamples
    // Update table to show only organisms from visible samples
    applyFilters()
}
```

This supplements the existing segmented control — both filter the same table.

- [ ] **Step 4: Add organism search field to toolbar**

In the toolbar setup area (where `sampleFilterControl` is created), add an `NSSearchField`:

```swift
private lazy var organismSearchField: NSSearchField = {
    let field = NSSearchField()
    field.placeholderString = "Filter organisms\u{2026}"
    field.controlSize = .small
    field.font = .systemFont(ofSize: 11)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    field.target = self
    field.action = #selector(organismSearchAction)
    return field
}()
```

Add it to the filter bar (NSStackView) alongside the sample segmented control.

Handler:

```swift
private var organismFilterWorkItem: DispatchWorkItem?

@objc private func organismSearchAction(_ sender: NSSearchField) {
    organismFilterWorkItem?.cancel()
    let query = sender.stringValue
    let workItem = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated {
            self?.filterOrganismsByName(query)
        }
    }
    organismFilterWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
}

private func filterOrganismsByName(_ query: String) {
    // Filter allTableRows by organism name substring match
    // Then reload the table
    applyFilters()
}
```

Update `applyFilters()` to incorporate the organism name filter along with the existing sample filter.

- [ ] **Step 5: Wire inspector in MainSplitViewController**

In `displayTaxTriageResultFromSidebar(at:sampleId:)` (~line 1800), after `viewerController.displayTaxTriageResult(...)`, add:

```swift
if let taxTriageVC = viewerController.currentMetagenomicsVC as? TaxTriageResultViewController {
    self.inspectorController?.updateClassifierSampleState(
        pickerState: taxTriageVC.samplePickerState,
        entries: taxTriageVC.sampleEntries,
        strippedPrefix: taxTriageVC.strippedPrefix
    )
}
```

- [ ] **Step 6: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add inspector sample picker and organism search to TaxTriage"
```

---

## Task 9: Add BLAST Drawer to Kraken2

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`

- [ ] **Step 1: Add BlastResultsDrawerTab property**

Add to `TaxonomyViewController`:

```swift
private lazy var blastDrawerTab: BlastResultsDrawerTab = {
    let tab = BlastResultsDrawerTab(frame: .zero)
    tab.translatesAutoresizingMaskIntoConstraints = false
    tab.showEmpty()
    return tab
}()
private var isBlastDrawerOpen = false
```

- [ ] **Step 2: Add drawer toggle to action bar**

In the action bar setup (where export button is), add a "BLAST Results" toggle button:

```swift
let blastButton = NSButton(title: "BLAST Results", target: self, action: #selector(toggleBlastDrawer))
blastButton.controlSize = .small
blastButton.bezelStyle = .toolbar
blastButton.setButtonType(.toggle)
// Add to action bar stack view
```

Handler:

```swift
@objc private func toggleBlastDrawer() {
    isBlastDrawerOpen.toggle()
    if isBlastDrawerOpen {
        // Add blastDrawerTab as bottom pane (similar to how other classifiers do it)
        // Animate height from 0 to 200
        showBottomDrawer(blastDrawerTab, height: 200)
    } else {
        hideBottomDrawer(blastDrawerTab)
    }
}
```

The exact drawer show/hide pattern should match what EsViritu or TaxTriage does. Check `EsVirituResultViewController.swift` for the drawer toggle pattern and replicate it.

- [ ] **Step 3: Wire BLAST verification callback**

The existing `onBlastRequested` callback on `TaxonomyTableView` already fires when a user right-clicks → BLAST on a taxon. Connect it to update the drawer:

```swift
blastDrawerTab.onOpenInBrowser = { url in
    NSWorkspace.shared.open(url)
}
blastDrawerTab.onRerunBlast = { [weak self] in
    self?.rerunLastBlastVerification()
}
```

When a BLAST result arrives (from the existing `BlastService` callback pattern), show it:

```swift
blastDrawerTab.showResults(result)
if !isBlastDrawerOpen {
    toggleBlastDrawer()  // Auto-open drawer when results arrive
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add BLAST verification results drawer to Kraken2 taxonomy browser"
```

---

## Task 10: Sample Metadata Store

**Files:**
- Create: `Sources/LungfishCore/Models/SampleMetadataStore.swift`
- Create: `Tests/LungfishCoreTests/SampleMetadataStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LungfishCoreTests/SampleMetadataStoreTests.swift
import Testing
import Foundation
@testable import LungfishCore

@Suite("SampleMetadataStore")
struct SampleMetadataStoreTests {

    @Test("Parses TSV with tab delimiter")
    func parseTSV() throws {
        let tsv = "Sample\tType\tLocation\nS1\tww\tColumbia\nS2\tww\tJefferson City\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(
            csvData: data,
            knownSampleIds: Set(["S1", "S2", "S3"])
        )
        #expect(store.columnNames == ["Type", "Location"])
        #expect(store.records["S1"]?["Type"] == "ww")
        #expect(store.records["S2"]?["Location"] == "Jefferson City")
        #expect(store.matchedSampleIds == Set(["S1", "S2"]))
        #expect(store.unmatchedRecords.isEmpty)
    }

    @Test("Parses CSV with comma delimiter")
    func parseCSV() throws {
        let csv = "Sample,Type,Location\nS1,ww,Columbia\n"
        let data = Data(csv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.columnNames == ["Type", "Location"])
        #expect(store.records["S1"]?["Type"] == "ww")
    }

    @Test("Unmatched samples go to unmatchedRecords")
    func unmatchedSamples() throws {
        let tsv = "Sample\tType\nS1\tww\nS99\tunknown\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.matchedSampleIds == Set(["S1"]))
        #expect(store.unmatchedRecords["S99"]?["Type"] == "unknown")
    }

    @Test("Case-insensitive sample matching")
    func caseInsensitive() throws {
        let tsv = "Sample\tType\ns1\tww\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.matchedSampleIds == Set(["S1"]))
    }

    @Test("Apply edit records change")
    func applyEdit() throws {
        let tsv = "Sample\tType\nS1\tww\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        store.applyEdit(sampleId: "S1", column: "Type", newValue: "clinical")
        #expect(store.records["S1"]?["Type"] == "clinical")
        #expect(store.edits.count == 1)
        #expect(store.edits[0].oldValue == "ww")
        #expect(store.edits[0].newValue == "clinical")
    }

    @Test("Serialize and deserialize edits JSON")
    func editsPersistence() throws {
        let tsv = "Sample\tType\nS1\tww\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        store.applyEdit(sampleId: "S1", column: "Type", newValue: "clinical")
        let json = try store.editsJSON()
        #expect(json.count > 10)
        // Verify we can decode it
        let decoded = try JSONDecoder().decode([MetadataEdit].self, from: json)
        #expect(decoded.count == 1)
        #expect(decoded[0].newValue == "clinical")
    }

    @Test("Empty cells handled gracefully")
    func emptyCells() throws {
        let tsv = "Sample\tType\tLocation\nS1\t\tColumbia\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.records["S1"]?["Type"] == "")
        #expect(store.records["S1"]?["Location"] == "Columbia")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SampleMetadataStoreTests 2>&1 | head -20`
Expected: Compilation failure

- [ ] **Step 3: Implement SampleMetadataStore**

```swift
// Sources/LungfishCore/Models/SampleMetadataStore.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Tracks a single in-app edit for reproducibility.
public struct MetadataEdit: Codable, Sendable {
    public let sampleId: String
    public let columnName: String
    public let oldValue: String?
    public let newValue: String
    public let timestamp: Date
}

/// Imports, stores, and manages free-form sample metadata from CSV/TSV files.
///
/// Metadata is matched to known sample IDs (case-insensitive). Edits are tracked
/// as a journal for reproducibility and persisted alongside the original file.
@Observable
public final class SampleMetadataStore: @unchecked Sendable {
    /// Column names in display order (excluding the sample ID column).
    public var columnNames: [String]
    /// Matched records: sampleId → [columnName: value].
    public var records: [String: [String: String]]
    /// Sample IDs that matched known samples.
    public var matchedSampleIds: Set<String>
    /// Rows that did not match any known sample.
    public var unmatchedRecords: [String: [String: String]]
    /// Edit journal.
    public private(set) var edits: [MetadataEdit] = []

    /// Parse CSV/TSV data and match to known sample IDs.
    ///
    /// - Parameters:
    ///   - csvData: Raw file data (UTF-8 encoded CSV or TSV)
    ///   - knownSampleIds: Set of sample IDs to match against
    public init(csvData: Data, knownSampleIds: Set<String>) throws {
        guard let text = String(data: csvData, encoding: .utf8) else {
            throw MetadataParseError.invalidEncoding
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first, lines.count > 1 else {
            throw MetadataParseError.noData
        }

        // Detect delimiter: tab preferred, fall back to comma
        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let headers = headerLine.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard headers.count >= 2 else {
            throw MetadataParseError.insufficientColumns
        }

        // First column is sample ID key, rest are metadata columns
        let metadataColumns = Array(headers.dropFirst())
        self.columnNames = metadataColumns

        // Build case-insensitive lookup for known samples
        let knownLookup: [String: String] = Dictionary(
            knownSampleIds.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matched: [String: [String: String]] = [:]
        var unmatched: [String: [String: String]] = [:]
        var matchedIds: Set<String> = []

        for line in lines.dropFirst() {
            let fields = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
            guard let rawId = fields.first else { continue }

            var record: [String: String] = [:]
            for (i, col) in metadataColumns.enumerated() {
                let value = (i + 1) < fields.count ? fields[i + 1] : ""
                record[col] = value
            }

            if let knownId = knownLookup[rawId.lowercased()] {
                matched[knownId] = record
                matchedIds.insert(knownId)
            } else {
                unmatched[rawId] = record
            }
        }

        self.records = matched
        self.matchedSampleIds = matchedIds
        self.unmatchedRecords = unmatched
    }

    /// Apply an edit to a sample's metadata value.
    public func applyEdit(sampleId: String, column: String, newValue: String) {
        let oldValue = records[sampleId]?[column]
        records[sampleId]?[column] = newValue
        edits.append(MetadataEdit(
            sampleId: sampleId,
            columnName: column,
            oldValue: oldValue,
            newValue: newValue,
            timestamp: Date()
        ))
    }

    /// Serialize the edit journal to JSON.
    public func editsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(edits)
    }

    /// Save the original file and edit journal into a bundle's metadata directory.
    public func persist(originalData: Data, to bundleURL: URL) throws {
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try originalData.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"))
        if !edits.isEmpty {
            let json = try editsJSON()
            try json.write(to: metadataDir.appendingPathComponent("sample_metadata_edits.json"))
        }
    }

    /// Load from a bundle's metadata directory if it exists.
    public static func load(from bundleURL: URL, knownSampleIds: Set<String>) -> SampleMetadataStore? {
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        let tsvURL = metadataDir.appendingPathComponent("sample_metadata.tsv")
        guard let data = try? Data(contentsOf: tsvURL) else { return nil }
        guard let store = try? SampleMetadataStore(csvData: data, knownSampleIds: knownSampleIds) else { return nil }
        // Apply saved edits
        let editsURL = metadataDir.appendingPathComponent("sample_metadata_edits.json")
        if let editsData = try? Data(contentsOf: editsURL),
           let savedEdits = try? JSONDecoder().decode([MetadataEdit].self, from: editsData) {
            for edit in savedEdits {
                store.records[edit.sampleId]?[edit.columnName] = edit.newValue
            }
            store.edits = savedEdits
        }
        return store
    }
}

public enum MetadataParseError: Error, LocalizedError {
    case invalidEncoding
    case noData
    case insufficientColumns

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "File is not valid UTF-8 text"
        case .noData: return "File contains no data rows"
        case .insufficientColumns: return "File must have at least 2 columns (sample ID + metadata)"
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SampleMetadataStoreTests`
Expected: All 7 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Models/SampleMetadataStore.swift Tests/LungfishCoreTests/SampleMetadataStoreTests.swift
git commit -m "feat: add SampleMetadataStore for CSV/TSV metadata import and editing"
```

---

## Task 11: Bundle Attachment Store

**Files:**
- Create: `Sources/LungfishCore/Models/BundleAttachmentStore.swift`
- Create: `Tests/LungfishCoreTests/BundleAttachmentStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LungfishCoreTests/BundleAttachmentStoreTests.swift
import Testing
import Foundation
@testable import LungfishCore

@Suite("BundleAttachmentStore")
struct BundleAttachmentStoreTests {

    @Test("Lists files from attachments directory")
    func listFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        let attachDir = tmp.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        try "hello".write(to: attachDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        store.reload()
        #expect(store.attachments.count == 1)
        #expect(store.attachments[0].filename == "notes.txt")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Attach file copies into bundle")
    func attachFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sourceFile = tmp.appendingPathComponent("source.txt")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        try store.attach(fileAt: sourceFile)
        #expect(store.attachments.count == 1)
        #expect(store.attachments[0].filename == "source.txt")
        // Verify file was copied, not moved
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Remove attachment moves to trash")
    func removeAttachment() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString)")
        let attachDir = tmp.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        try "hello".write(to: attachDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let store = BundleAttachmentStore(bundleURL: tmp)
        store.reload()
        #expect(store.attachments.count == 1)

        try store.remove(filename: "notes.txt")
        #expect(store.attachments.isEmpty)

        try FileManager.default.removeItem(at: tmp)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter BundleAttachmentStoreTests 2>&1 | head -20`
Expected: Compilation failure

- [ ] **Step 3: Implement BundleAttachmentStore**

```swift
// Sources/LungfishCore/Models/BundleAttachmentStore.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Describes a file attached to a classification bundle.
public struct BundleAttachment: Sendable {
    public let filename: String
    public let fileSize: Int64
    public let dateAdded: Date
    public let url: URL
}

/// Manages arbitrary file attachments inside a classification bundle.
///
/// Files are stored in `bundle/attachments/`. The directory listing is the
/// source of truth — no separate database or index needed.
@Observable
public final class BundleAttachmentStore: @unchecked Sendable {
    public let bundleURL: URL
    public var attachments: [BundleAttachment] = []

    private var attachmentsDir: URL {
        bundleURL.appendingPathComponent("attachments", isDirectory: true)
    }

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
        reload()
    }

    /// Scan the attachments directory and refresh the list.
    public func reload() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: attachmentsDir.path) else {
            attachments = []
            return
        }
        let urls = (try? fm.contentsOfDirectory(
            at: attachmentsDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        attachments = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            return BundleAttachment(
                filename: url.lastPathComponent,
                fileSize: Int64(values?.fileSize ?? 0),
                dateAdded: values?.creationDate ?? Date(),
                url: url
            )
        }.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    /// Copy a file into the bundle's attachments directory.
    public func attach(fileAt sourceURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        let dest = attachmentsDir.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: sourceURL, to: dest)
        reload()
    }

    /// Move an attachment to the trash (reversible).
    public func remove(filename: String) throws {
        let fileURL = attachmentsDir.appendingPathComponent(filename)
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        reload()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BundleAttachmentStoreTests`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Models/BundleAttachmentStore.swift Tests/LungfishCoreTests/BundleAttachmentStoreTests.swift
git commit -m "feat: add BundleAttachmentStore for file attachments in classification bundles"
```

---

## Task 12: Inspector Metadata and Attachments Sections

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/SampleMetadataSection.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/AttachmentsSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

- [ ] **Step 1: Create SampleMetadataSection SwiftUI view**

```swift
// Sources/LungfishApp/Views/Inspector/Sections/SampleMetadataSection.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Inspector section displaying imported sample metadata with inline editing.
struct SampleMetadataSection: View {
    @Bindable var store: SampleMetadataStore
    @State private var isExpanded = true
    @State private var editingCell: (sampleId: String, column: String)?
    @State private var editText: String = ""

    var body: some View {
        DisclosureGroup("Sample Metadata", isExpanded: $isExpanded) {
            if store.records.isEmpty {
                Text("No metadata imported")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                metadataTable
            }

            if !store.unmatchedRecords.isEmpty {
                unmatchedSection
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var metadataTable: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    Text("Sample")
                        .frame(width: 100, alignment: .leading)
                        .font(.system(size: 10, weight: .semibold))
                    ForEach(store.columnNames, id: \.self) { col in
                        Text(col)
                            .frame(width: 90, alignment: .leading)
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                Divider()

                // Data rows
                ForEach(Array(store.matchedSampleIds.sorted()), id: \.self) { sampleId in
                    HStack(spacing: 0) {
                        Text(sampleId)
                            .frame(width: 100, alignment: .leading)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ForEach(store.columnNames, id: \.self) { col in
                            editableCell(sampleId: sampleId, column: col)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func editableCell(sampleId: String, column: String) -> some View {
        let value = store.records[sampleId]?[column] ?? ""
        let isEditing = editingCell?.sampleId == sampleId && editingCell?.column == column

        return Group {
            if isEditing {
                TextField("", text: $editText, onCommit: {
                    store.applyEdit(sampleId: sampleId, column: column, newValue: editText)
                    editingCell = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .frame(width: 90, alignment: .leading)
            } else {
                Text(value)
                    .font(.system(size: 10))
                    .frame(width: 90, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture {
                        editText = value
                        editingCell = (sampleId, column)
                    }
            }
        }
    }

    private var unmatchedSection: some View {
        DisclosureGroup("Unmatched Samples (\(store.unmatchedRecords.count))") {
            ForEach(Array(store.unmatchedRecords.keys.sorted()), id: \.self) { sampleId in
                Text(sampleId)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 2: Create AttachmentsSection SwiftUI view**

```swift
// Sources/LungfishApp/Views/Inspector/Sections/AttachmentsSection.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import AppKit

/// Inspector section displaying file attachments with add/remove/reveal actions.
struct AttachmentsSection: View {
    @Bindable var store: BundleAttachmentStore
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Attachments", isExpanded: $isExpanded) {
            if store.attachments.isEmpty {
                Text("No files attached")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(store.attachments, id: \.filename) { attachment in
                    attachmentRow(attachment)
                }
            }

            Button("Attach File\u{2026}") {
                attachFile()
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private func attachmentRow(_ attachment: BundleAttachment) -> some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                .resizable()
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatFileSize(attachment.fileSize))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
            }
            Button("Quick Look") {
                NSWorkspace.shared.open(attachment.url)
            }
            Divider()
            Button("Remove Attachment") {
                try? store.remove(filename: attachment.filename)
            }
        }
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                try? store.attach(fileAt: url)
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
```

- [ ] **Step 3: Add metadata and attachments rendering to Inspector Document tab**

In `InspectorViewController.swift`, after the unified sample picker rendering block, add:

```swift
// Sample Metadata section
if let metadataStore = viewModel.sampleMetadataStore {
    Divider().padding(.vertical, 4)
    SampleMetadataSection(store: metadataStore)
}

// Attachments section
if let attachmentStore = viewModel.bundleAttachmentStore {
    Divider().padding(.vertical, 4)
    AttachmentsSection(store: attachmentStore)
}
```

Also add an "Import Metadata..." button if no metadata is loaded yet. This requires knowing the bundle URL (stored in `documentSectionViewModel.bundleURL` or the result directory). The exact wiring depends on how the inspector communicates back to the result VC — use NotificationCenter or a closure callback.

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add sample metadata and attachments sections to Inspector"
```

---

## Task 13: Universal Search for Metadata

**Files:**
- Modify: `Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift`

- [ ] **Step 1: Add metadata indexing method**

Add a new indexer method that scans for `metadata/sample_metadata.tsv` inside classifier bundles and indexes each metadata value:

```swift
/// Index sample metadata values from a classification bundle.
private func indexSampleMetadata(
    at bundleURL: URL,
    entityCount: inout Int,
    attributeCount: inout Int,
    perKindCounts: inout [String: Int]
) throws {
    let tsvURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
    guard FileManager.default.fileExists(atPath: tsvURL.path),
          let data = try? Data(contentsOf: tsvURL) else { return }

    // Parse minimally — just need values for indexing
    guard let text = String(data: data, encoding: .utf8) else { return }
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard let headerLine = lines.first, lines.count > 1 else { return }
    let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
    let headers = headerLine.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
    guard headers.count >= 2 else { return }
    let columns = Array(headers.dropFirst())

    let relPath = bundleURL.lastPathComponent

    for line in lines.dropFirst() {
        let fields = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard let sampleId = fields.first else { continue }

        for (i, col) in columns.enumerated() {
            let value = (i + 1) < fields.count ? fields[i + 1] : ""
            guard !value.isEmpty else { continue }

            let entityId = "sample_metadata:\(relPath):\(sampleId):\(col)"
            let row = EntityRow(
                id: entityId,
                kind: "sample_metadata",
                title: value,
                subtitle: "Sample: \(sampleId), Field: \(col)",
                format: nil,
                relPath: relPath,
                url: bundleURL,
                mtime: nil,
                sizeBytes: nil
            )
            try insertEntity(row, attributes: [
                "sample_id": sampleId,
                "field_name": col,
                "field_value": value
            ], entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
        }
    }
}
```

- [ ] **Step 2: Call the new indexer from existing classifier indexers**

In each of `indexClassificationResult`, `indexEsVirituResult`, `indexTaxTriageResult`, `indexNaoMgsResult`, `indexNvdResult`, add at the end:

```swift
try indexSampleMetadata(at: resultDirectory, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
```

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: index sample metadata values in universal search"
```

---

## Task 14: Run Full Test Suite and Final Verification

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass, including new ClassifierSamplePickerStateTests, SampleMetadataStoreTests, BundleAttachmentStoreTests

- [ ] **Step 2: Run build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with no warnings related to our changes

- [ ] **Step 3: Verify no regressions in existing classification tests**

Run: `swift test --filter ClassificationUITests && swift test --filter SidebarFilterTests && swift test --filter ClassificationConfigMutabilityTests`
Expected: All existing tests pass

- [ ] **Step 4: Final commit if any loose changes**

```bash
git status
# If clean, nothing to commit
# If there are changes, commit them
```
