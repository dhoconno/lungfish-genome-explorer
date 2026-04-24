# Mapping Consensus Controls, Export, and Raw-SAM Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make mapping analyses expose controllable consensus generation, allow full-contig biological consensus export through the existing FASTA extraction dialog, and delete raw SAM intermediates after successful normalization.

**Architecture:** Keep the embedded mapping viewer isolated from app-wide genomics notifications. Split consensus-calling depth from gap-masking depth in shared read-style state, bridge mapping read-style updates directly from the inspector into `MappingResultViewController` and its embedded viewer, add a small pure builder for full-contig biological consensus export requests, and remove raw SAM files inside the shared normalization success path so all managed mappers inherit the cleanup.

**Tech Stack:** Swift, AppKit, SwiftUI inspector sections, LungfishCore notifications, LungfishIO `AlignmentDataProvider`, LungfishWorkflow managed mapping pipeline, XCTest, `swift test`, `xcodebuild`.

---

## File Structure

### Shared Consensus Settings and Viewer Plumbing

- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift`
- Test: `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`

### Mapping Inspector Bridge and Consensus Export

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingConsensusExportRequestBuilder.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Test: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
- Test: `Tests/LungfishAppTests/MappingConsensusExportRequestBuilderTests.swift`

### Shared Mapping Normalization Cleanup

- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`

This split keeps the settings refactor, mapping-only bridge/export work, and pipeline cleanup independent enough to implement and review in separate commits.

---

## Task 1: Split Consensus Calling Depth from Gap-Masking Depth

**Files:**

- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift`
- Test: `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`

- [ ] **Step 1: Write the failing tests for separate depth settings**

Add these tests to `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`:

```swift
func testDefaultSettingsExposeSeparateConsensusAndMaskingDepths() {
    let vm = ReadStyleSectionViewModel()

    XCTAssertEqual(vm.consensusMinDepth, 8)
    XCTAssertEqual(vm.consensusMaskingMinDepth, 8)
}

func testNotificationUserInfoKeysIncludeConsensusMaskingMinDepth() {
    XCTAssertEqual(
        NotificationUserInfoKey.consensusMaskingMinDepth,
        "consensusMaskingMinDepth"
    )
}
```

- [ ] **Step 2: Run the focused test target and confirm it fails**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter ReadStyleSectionViewModelTests
```

Expected:

- the new test fails because `consensusMaskingMinDepth` and `NotificationUserInfoKey.consensusMaskingMinDepth` do not exist yet

- [ ] **Step 3: Add the new notification key and view-model property**

In `Sources/LungfishCore/Models/Notifications.swift`, add the new user-info key next to the existing consensus keys:

```swift
/// Key for minimum spanning depth required before gap masking is applied.
public static let consensusMaskingMinDepth = "consensusMaskingMinDepth"
```

In `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`, extend `ReadStyleSectionViewModel`:

```swift
/// Minimum spanning depth required before high-gap masking is applied.
public var consensusMaskingMinDepth: Double = 8
```

- [ ] **Step 4: Move the UI to the approved control layout**

Still in `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`, keep `Consensus Min Depth` always visible and add a separate masking slider inside the masking subsection:

```swift
HStack {
    Text("Consensus Min Depth")
    Spacer()
    Text("\(Int(viewModel.consensusMinDepth))")
        .foregroundStyle(.secondary)
        .monospacedDigit()
}
Slider(value: $viewModel.consensusMinDepth, in: 1...50, step: 1)
    .onChange(of: viewModel.consensusMinDepth) { _, _ in
        viewModel.onSettingsChanged?()
    }

if viewModel.consensusMaskingEnabled {
    HStack {
        Text("Masking Min Depth")
        Spacer()
        Text("\(Int(viewModel.consensusMaskingMinDepth))")
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
    Slider(value: $viewModel.consensusMaskingMinDepth, in: 1...50, step: 1)
        .onChange(of: viewModel.consensusMaskingMinDepth) { _, _ in
            viewModel.onSettingsChanged?()
        }
}
```

- [ ] **Step 5: Thread the new setting through inspector payload generation**

In `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`, add the new key to the read-style payload:

```swift
NotificationUserInfoKey.consensusMinDepth: Int(vm.consensusMinDepth),
NotificationUserInfoKey.consensusMaskingMinDepth: Int(vm.consensusMaskingMinDepth),
NotificationUserInfoKey.consensusMinMapQ: Int(vm.consensusMinMapQ),
NotificationUserInfoKey.consensusMinBaseQ: Int(vm.consensusMinBaseQ),
```

In `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`, apply the new key without invalidating consensus fetches when only masking changes:

```swift
if let minDepth = userInfo[NotificationUserInfoKey.consensusMinDepth] as? Int {
    viewerView.consensusMinDepthSetting = max(1, min(500, minDepth))
}
if let maskingMinDepth = userInfo[NotificationUserInfoKey.consensusMaskingMinDepth] as? Int {
    viewerView.consensusMaskingMinDepthSetting = max(1, min(500, maskingMinDepth))
}
```

Keep the cache invalidation trigger tied to `consensusMinDepth`, not `consensusMaskingMinDepth`.

- [ ] **Step 6: Separate fetch-time consensus depth from render-time masking depth**

In `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`, add:

```swift
/// Minimum depth required before a consensus base is emitted.
var consensusMinDepthSetting: Int = 8

/// Minimum spanning depth required before high-gap masking is applied.
var consensusMaskingMinDepthSetting: Int = 8
```

Use `consensusMinDepthSetting` in `currentConsensusOptionsSignature()` and `fetchConsensusAsync()`, and use `consensusMaskingMinDepthSetting` when building the display settings handed to `ReadTrackRenderer`.

In `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift`, rename the masking-side field to match:

```swift
public var consensusMaskingMinDepth: Int = 8
```

and pass that value into the gap-masking path instead of `consensusMinDepth`.

- [ ] **Step 7: Run the tests and confirm they pass**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter ReadStyleSectionViewModelTests
```

Expected:

- `ReadStyleSectionViewModelTests` passes

- [ ] **Step 8: Commit the settings split**

Run:

```bash
git add /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Models/Notifications.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Inspector/InspectorViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/ViewerViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift
git commit -m "feat: split consensus and masking depth controls"
```

---

## Task 2: Bridge Mapping Read-Style State Directly Into the Embedded Viewer

**Files:**

- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Test: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`

- [ ] **Step 1: Write the failing tests for the mapping inspector bridge**

Add this test to `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`:

```swift
func testEmbeddedViewerNotifiesHostWhenReferenceBundleLoads() throws {
    let vc = MappingResultViewController()
    _ = vc.view

    let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
    var deliveredBundle: ReferenceBundle?
    vc.onEmbeddedReferenceBundleLoaded = { deliveredBundle = $0 }

    vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))

    XCTAssertEqual(deliveredBundle?.manifest.name, "Fixture")
}
```

Add this view-model regression test to `Tests/LungfishAppTests/InspectorMappingModeTests.swift`:

```swift
func testMappingModeKeepsSelectionTabAvailableForReadStyleControls() {
    let viewModel = InspectorViewModel()
    viewModel.contentMode = .mapping

    XCTAssertEqual(viewModel.availableTabs, [.document, .selection])
}
```

- [ ] **Step 2: Run the focused mapping tests and confirm the callback test fails**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingResultViewControllerTests|InspectorMappingModeTests'
```

Expected:

- `testEmbeddedViewerNotifiesHostWhenReferenceBundleLoads` fails because `onEmbeddedReferenceBundleLoaded` does not exist yet

- [ ] **Step 3: Add a direct read-style apply seam to `ViewerViewController`**

In `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`, extract the body of `handleReadDisplaySettingsChanged(_:)` into a reusable method:

```swift
func applyReadDisplaySettings(_ userInfo: [AnyHashable: Any]) {
    if let showReads = userInfo[NotificationUserInfoKey.showReads] as? Bool {
        viewerView.showReads = showReads
    }
    if let minDepth = userInfo[NotificationUserInfoKey.consensusMinDepth] as? Int {
        viewerView.consensusMinDepthSetting = max(1, min(500, minDepth))
    }
    if let maskingMinDepth = userInfo[NotificationUserInfoKey.consensusMaskingMinDepth] as? Int {
        viewerView.consensusMaskingMinDepthSetting = max(1, min(500, maskingMinDepth))
    }
    viewerView.needsDisplay = true
}
```

Then make the notification handler call that method:

```swift
@objc private func handleReadDisplaySettingsChanged(_ notification: Notification) {
    guard let userInfo = notification.userInfo else { return }
    applyReadDisplaySettings(userInfo)
}
```

- [ ] **Step 4: Surface embedded-bundle and settings hooks from `MappingResultViewController`**

In `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`, add `import LungfishIO` and then add:

```swift
var onEmbeddedReferenceBundleLoaded: ((ReferenceBundle) -> Void)?

func applyEmbeddedReadDisplaySettings(_ userInfo: [AnyHashable: Any]) {
    embeddedViewerController.applyReadDisplaySettings(userInfo)
}

func notifyEmbeddedReferenceBundleLoadedIfAvailable() {
    if let bundle = embeddedViewerController.viewerView.currentReferenceBundle {
        onEmbeddedReferenceBundleLoaded?(bundle)
    }
}
```

When rebuilding the local annotation index, also notify the host:

```swift
private func rebuildEmbeddedAnnotationSearchIndex() {
    guard let bundle = embeddedViewerController.viewerView.currentReferenceBundle else {
        embeddedViewerController.annotationSearchIndex = nil
        return
    }

    let index = AnnotationSearchIndex()
    let chromosomes = embeddedViewerController.currentBundleDataProvider?.chromosomes ?? []
    index.buildIndex(bundle: bundle, chromosomes: chromosomes)
    embeddedViewerController.annotationSearchIndex = index
    onEmbeddedReferenceBundleLoaded?(bundle)
}
```

- [ ] **Step 5: Make `InspectorViewController` produce a reusable payload instead of assuming global notifications**

In `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`, factor the payload creation into one helper:

```swift
private func makeReadDisplaySettingsPayload(from vm: ReadStyleSectionViewModel) -> [AnyHashable: Any] {
    [
        NotificationUserInfoKey.showReads: vm.showReads,
        NotificationUserInfoKey.maxReadRows: Int(vm.maxReadRows),
        NotificationUserInfoKey.limitReadRows: vm.limitReadRows,
        NotificationUserInfoKey.verticalCompressContig: vm.verticallyCompressContig,
        NotificationUserInfoKey.minMapQ: Int(vm.minMapQ),
        NotificationUserInfoKey.showMismatches: vm.showMismatches,
        NotificationUserInfoKey.showSoftClips: vm.showSoftClips,
        NotificationUserInfoKey.showIndels: vm.showIndels,
        NotificationUserInfoKey.showStrandColors: vm.showStrandColors,
        NotificationUserInfoKey.consensusMaskingEnabled: vm.consensusMaskingEnabled,
        NotificationUserInfoKey.consensusGapThresholdPercent: Int(vm.consensusGapThresholdPercent),
        NotificationUserInfoKey.consensusMinDepth: Int(vm.consensusMinDepth),
        NotificationUserInfoKey.consensusMaskingMinDepth: Int(vm.consensusMaskingMinDepth),
        NotificationUserInfoKey.consensusMinMapQ: Int(vm.consensusMinMapQ),
        NotificationUserInfoKey.consensusMinBaseQ: Int(vm.consensusMinBaseQ),
        NotificationUserInfoKey.showConsensusTrack: vm.showConsensusTrack,
        NotificationUserInfoKey.consensusMode: vm.consensusMode.rawValue,
        NotificationUserInfoKey.consensusUseAmbiguity: vm.consensusUseAmbiguity,
        NotificationUserInfoKey.excludeFlags: vm.computedExcludeFlags,
        NotificationUserInfoKey.selectedReadGroups: vm.selectedReadGroups,
    ]
}
```

Keep the existing `.readDisplaySettingsChanged` posting path for normal genomics mode, but let mapping mode reuse the same payload without broadcasting globally.

- [ ] **Step 6: Wire the mapping shell into the inspector from `MainSplitViewController`**

In `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`, after `viewerController.displayMappingResult(result)`, attach the bridge:

```swift
if let mappingController = viewerController.mappingResultController {
    mappingController.onEmbeddedReferenceBundleLoaded = { [weak self, weak mappingController] bundle in
        guard let self, let mappingController else { return }
        self.inspectorController.updateMappingAlignmentSection(
            from: bundle,
            applySettings: { payload in
                mappingController.applyEmbeddedReadDisplaySettings(payload)
            }
        )
    }
    mappingController.notifyEmbeddedReferenceBundleLoadedIfAvailable()
}
```

Add `updateMappingAlignmentSection(from:applySettings:)` to `InspectorViewController` as a mapping-specific wrapper around `loadStatistics(from:)` plus `onSettingsChanged`.

- [ ] **Step 7: Re-run the mapping-focused tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingResultViewControllerTests|InspectorMappingModeTests'
```

Expected:

- both test files pass

- [ ] **Step 8: Commit the direct bridge**

Run:

```bash
git add /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Inspector/InspectorViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/ViewerViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MappingResultViewControllerTests.swift /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/InspectorMappingModeTests.swift
git commit -m "feat: bridge mapping read-style controls to embedded viewer"
```

---

## Task 3: Add Full-Contig Biological Consensus Export Through the Existing FASTA Dialog

**Files:**

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingConsensusExportRequestBuilder.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift`
- Test: `Tests/LungfishAppTests/MappingConsensusExportRequestBuilderTests.swift`
- Test: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`

- [ ] **Step 1: Write the failing tests for export selection and biological flags**

Create `Tests/LungfishAppTests/MappingConsensusExportRequestBuilderTests.swift` with:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class MappingConsensusExportRequestBuilderTests: XCTestCase {
    func testBuildPrefersSelectedContigAndUsesBiologicalConsensusFlags() {
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            selectedContig: .init(
                contigName: "NC_045512",
                contigLength: 29_903,
                mappedReads: 197,
                mappedReadPercent: 98.5,
                meanDepth: 0.9,
                coverageBreadth: 43.0,
                medianMAPQ: 60.0,
                meanIdentity: 99.5
            ),
            fallbackChromosome: nil,
            consensusMode: .bayesian,
            consensusMinDepth: 12,
            consensusMinMapQ: 0,
            consensusMinBaseQ: 0,
            excludeFlags: 0xD04,
            useAmbiguity: false
        )

        XCTAssertEqual(request.chromosome, "NC_045512")
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 29_903)
        XCTAssertFalse(request.showDeletions)
        XCTAssertTrue(request.showInsertions)
        XCTAssertEqual(request.recordName, "sample NC_045512 consensus")
        XCTAssertEqual(request.suggestedName, "sample-NC_045512-consensus")
    }

    func testBuildFallsBackToVisibleChromosomeWhenNoTableSelectionExists() {
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            selectedContig: nil,
            fallbackChromosome: ChromosomeInfo(name: "chr2", length: 512, offset: 0, lineBases: 80, lineWidth: 81),
            consensusMode: .simple,
            consensusMinDepth: 5,
            consensusMinMapQ: 7,
            consensusMinBaseQ: 9,
            excludeFlags: 0x904,
            useAmbiguity: true
        )

        XCTAssertEqual(request.chromosome, "chr2")
        XCTAssertEqual(request.end, 512)
        XCTAssertEqual(request.mode, .simple)
        XCTAssertTrue(request.useAmbiguity)
    }
}
```

- [ ] **Step 2: Run the export-focused tests and confirm they fail**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingConsensusExportRequestBuilderTests|MappingResultViewControllerTests'
```

Expected:

- the new builder test file fails because `MappingConsensusExportRequestBuilder` does not exist yet

- [ ] **Step 3: Add a small pure builder for export configuration**

Create `Sources/LungfishApp/Views/Results/Mapping/MappingConsensusExportRequestBuilder.swift`:

```swift
import Foundation
import LungfishCore
import LungfishWorkflow

enum MappingConsensusExportRequestBuilderError: Error {
    case noTargetChromosome
}

struct MappingConsensusExportRequest: Equatable {
    let chromosome: String
    let start: Int
    let end: Int
    let recordName: String
    let suggestedName: String
    let mode: AlignmentConsensusMode
    let minDepth: Int
    let minMapQ: Int
    let minBaseQ: Int
    let excludeFlags: UInt16
    let useAmbiguity: Bool
    let showDeletions: Bool
    let showInsertions: Bool
}

enum MappingConsensusExportRequestBuilder {
    static func build(
        sampleName: String,
        selectedContig: MappingContigSummary?,
        fallbackChromosome: ChromosomeInfo?,
        consensusMode: AlignmentConsensusMode,
        consensusMinDepth: Int,
        consensusMinMapQ: Int,
        consensusMinBaseQ: Int,
        excludeFlags: UInt16,
        useAmbiguity: Bool
    ) throws -> MappingConsensusExportRequest {
        if let contig = selectedContig {
            return MappingConsensusExportRequest(
                chromosome: contig.contigName,
                start: 0,
                end: contig.contigLength,
                recordName: "\(sampleName) \(contig.contigName) consensus",
                suggestedName: "\(sampleName)-\(contig.contigName)-consensus",
                mode: consensusMode,
                minDepth: consensusMinDepth,
                minMapQ: consensusMinMapQ,
                minBaseQ: consensusMinBaseQ,
                excludeFlags: excludeFlags,
                useAmbiguity: useAmbiguity,
                showDeletions: false,
                showInsertions: true
            )
        }

        guard let chromosome = fallbackChromosome else {
            throw MappingConsensusExportRequestBuilderError.noTargetChromosome
        }
        return MappingConsensusExportRequest(
            chromosome: chromosome.name,
            start: 0,
            end: Int(chromosome.length),
            recordName: "\(sampleName) \(chromosome.name) consensus",
            suggestedName: "\(sampleName)-\(chromosome.name)-consensus",
            mode: consensusMode,
            minDepth: consensusMinDepth,
            minMapQ: consensusMinMapQ,
            minBaseQ: consensusMinBaseQ,
            excludeFlags: excludeFlags,
            useAmbiguity: useAmbiguity,
            showDeletions: false,
            showInsertions: true
        )
    }
}
```

- [ ] **Step 4: Add the mapping-only inspector action**

In `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`, add two mapping-only fields to the view model:

```swift
public var supportsConsensusExtraction: Bool = false
public var onExtractConsensusRequested: (() -> Void)?
```

Render the button only when the mapping bridge enables it:

```swift
if viewModel.supportsConsensusExtraction {
    Button("Extract Consensus…") {
        viewModel.onExtractConsensusRequested?()
    }
    .disabled(!viewModel.hasAlignmentTracks)
}
```

In `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`, set:

```swift
viewModel.readStyleSectionViewModel.supportsConsensusExtraction = true
viewModel.readStyleSectionViewModel.onExtractConsensusRequested = { [weak self] in
    self?.viewerController?.presentMappingConsensusExtraction()
}
```

and reset `supportsConsensusExtraction` to `false` when clearing mapping state.

- [ ] **Step 5: Build the async export path in the mapping shell**

In `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`, add `import LungfishIO` and then add an async method:

```swift
func buildConsensusExportPayload() async throws -> (records: [String], suggestedName: String) {
    guard let result = currentResult else {
        throw NSError(domain: "Lungfish", code: 1, userInfo: [NSLocalizedDescriptionKey: "No mapping result loaded"])
    }

    let selectedContig = currentSelectedContig()
    let fallbackChromosome = embeddedViewerController.currentBundleDataProvider?
        .chromosomeInfo(named: embeddedViewerController.referenceFrame?.chromosome ?? "")

    let request = try MappingConsensusExportRequestBuilder.build(
        sampleName: result.bamURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
        selectedContig: selectedContig,
        fallbackChromosome: fallbackChromosome,
        consensusMode: embeddedViewerController.viewerView.consensusModeSetting,
        consensusMinDepth: embeddedViewerController.viewerView.consensusMinDepthSetting,
        consensusMinMapQ: embeddedViewerController.viewerView.consensusMinMapQSetting,
        consensusMinBaseQ: embeddedViewerController.viewerView.consensusMinBaseQSetting,
        excludeFlags: embeddedViewerController.viewerView.excludeFlagsSetting,
        useAmbiguity: embeddedViewerController.viewerView.consensusUseAmbiguitySetting
    )

    let provider = try currentPrimaryAlignmentProvider()
    let consensus = try await provider.fetchConsensus(
        chromosome: request.chromosome,
        start: request.start,
        end: request.end,
        mode: request.mode,
        minMapQ: request.minMapQ,
        minBaseQ: request.minBaseQ,
        minDepth: request.minDepth,
        excludeFlags: request.excludeFlags,
        useAmbiguity: request.useAmbiguity,
        showDeletions: request.showDeletions,
        showInsertions: request.showInsertions
    )

    let record = ">\(request.recordName)\n\(consensus.sequence)\n"
    return ([record], request.suggestedName)
}

private func currentSelectedContig() -> MappingContigSummary? {
    let selectedRow = contigTableView.tableView.selectedRow
    guard selectedRow >= 0 else { return nil }
    return contigTableView.record(at: selectedRow)
}

private func currentPrimaryAlignmentProvider() throws -> AlignmentDataProvider {
    guard let provider = embeddedViewerController.currentBundleDataProvider?.alignmentDataProviders.first else {
        throw NSError(domain: "Lungfish", code: 2, userInfo: [NSLocalizedDescriptionKey: "No alignment provider loaded"])
    }
    return provider
}
```

Near this method, add the explicit deferred-work comments:

```swift
// TODO(2026-04-22): Add visible-viewport consensus export.
// TODO(2026-04-22): Add selected-annotation consensus export.
// TODO(2026-04-22): Add selected-region consensus export.
```

- [ ] **Step 6: Reuse the existing FASTA dialog from the viewer host**

In `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`, add:

```swift
func presentMappingConsensusExtraction() {
    guard let controller = mappingResultController else {
        NSSound.beep()
        return
    }

    Task { @MainActor [weak self] in
        do {
            let payload = try await controller.buildConsensusExportPayload()
            self?.presentFASTASequenceExtractionDialog(
                records: payload.records,
                suggestedName: payload.suggestedName
            )
        } catch {
            NSSound.beep()
        }
    }
}
```

Use `ViewerViewController+Extraction.swift` only if you need a small shared FASTA formatting helper. Do not create a second extraction sheet.

- [ ] **Step 7: Add the controller-level regression for export payload delivery**

Extend `Tests/LungfishAppTests/MappingResultViewControllerTests.swift` with a seam that verifies the payload request is built from the selected contig. Add a test like:

```swift
func testConsensusExportUsesSelectedContigNameInSuggestedStem() async throws {
    let vc = MappingResultViewController()
    _ = vc.view
    vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))

    let request = try vc.testBuildConsensusExportRequest()

    XCTAssertEqual(request.chromosome, "beta")
    XCTAssertEqual(request.suggestedName, "example-beta-consensus")
    XCTAssertFalse(request.showDeletions)
    XCTAssertTrue(request.showInsertions)
}
```

Add the matching `testBuildConsensusExportRequest()` helper under the existing `#if DEBUG` test seam in `MappingResultViewController.swift`.

- [ ] **Step 8: Re-run the export-focused tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingConsensusExportRequestBuilderTests|MappingResultViewControllerTests'
```

Expected:

- both test files pass

- [ ] **Step 9: Commit the export feature**

Run:

```bash
git add /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Results/Mapping/MappingConsensusExportRequestBuilder.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Inspector/InspectorViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MappingConsensusExportRequestBuilderTests.swift /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MappingResultViewControllerTests.swift
git commit -m "feat: export mapping consensus through fasta dialog"
```

---

## Task 4: Delete Raw SAM After Successful BAM Normalization and Indexing

**Files:**

- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`

- [ ] **Step 1: Write the failing cleanup tests**

Add these tests to `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`:

```swift
func testNormalizeAlignmentRemovesRawSAMAfterSuccessfulNormalization() async throws {
    let fixture = try SamtoolsFixture()
    defer { fixture.cleanup() }

    let rawSAM = fixture.tempRoot.appendingPathComponent("sample.sam")
    try Data("sam".utf8).write(to: rawSAM)

    let pipeline = ManagedMappingPipeline(
        condaManager: .shared,
        nativeToolRunner: fixture.runner
    )

    _ = try await pipeline.normalizeAlignment(
        rawAlignmentURL: rawSAM,
        outputDirectory: fixture.tempRoot
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: rawSAM.path))
}

func testNormalizeAlignmentKeepsRawSAMWhenSortFails() async throws {
    let fixture = try SamtoolsFixture(failingSubcommand: "sort")
    defer { fixture.cleanup() }

    let rawSAM = fixture.tempRoot.appendingPathComponent("sample.sam")
    try Data("sam".utf8).write(to: rawSAM)

    let pipeline = ManagedMappingPipeline(
        condaManager: .shared,
        nativeToolRunner: fixture.runner
    )

    do {
        _ = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawSAM,
            outputDirectory: fixture.tempRoot
        )
        XCTFail("Expected sort failure")
    } catch {
        XCTAssertTrue(error.localizedDescription.contains("mock sort failure"))
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: rawSAM.path))
}
```

- [ ] **Step 2: Extend the samtools fixture so it can simulate failures**

Still in `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`, update the fixture:

```swift
private struct SamtoolsFixture {
    let tempRoot: URL
    let runner: NativeToolRunner
    let logURL: URL
    let failingSubcommand: String?

    init(failingSubcommand: String? = nil) throws {
        self.failingSubcommand = failingSubcommand
        ...
        try Self.scriptBody(logURL: logURL, failingSubcommand: failingSubcommand)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
    }
}
```

and in the shell script:

```sh
if [ -n "$FAILING_SUBCOMMAND" ] && [ "$subcommand" = "$FAILING_SUBCOMMAND" ]; then
  printf '%s\n' "mock $subcommand failure" >&2
  exit 1
fi
```

Pass `FAILING_SUBCOMMAND` into the script body from Swift.

- [ ] **Step 3: Run the mapping pipeline tests and confirm the cleanup test fails**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter ManagedMappingPipelineTests
```

Expected:

- `testNormalizeAlignmentRemovesRawSAMAfterSuccessfulNormalization` fails because the raw SAM still exists after a successful run

- [ ] **Step 4: Delete the raw SAM only on successful normalization**

In `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`, remove the raw SAM after `samtoolsIndex` and `samtoolsFlagstatCounts` succeed:

```swift
let (totalReads, mappedReads) = try await samtoolsFlagstatCounts(bamURL: sortedBAM)
if fm.fileExists(atPath: tempFilteredBAM.path) {
    try? fm.removeItem(at: tempFilteredBAM)
}
if rawAlignmentURL.pathExtension.lowercased() == "sam",
   fm.fileExists(atPath: rawAlignmentURL.path) {
    try? fm.removeItem(at: rawAlignmentURL)
}
```

Do not move this cleanup above `samtoolsIndex` or above `samtoolsFlagstatCounts`.

- [ ] **Step 5: Re-run the pipeline tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter ManagedMappingPipelineTests
```

Expected:

- `ManagedMappingPipelineTests` passes
- successful SAM normalization removes `sample.sam`
- failing sort leaves `sample.sam` in place

- [ ] **Step 6: Commit the cleanup**

Run:

```bash
git add /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift
git commit -m "fix: remove raw sam after successful mapping normalization"
```

---

## Focused Verification

Run the full focused regression set after all four tasks:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'ReadStyleSectionViewModelTests|MappingResultViewControllerTests|InspectorMappingModeTests|MappingConsensusExportRequestBuilderTests|ManagedMappingPipelineTests'
```

Expected:

- all listed test files pass

Build a fresh Debug app bundle:

```bash
xcodebuild -project /Users/dho/Documents/lungfish-genome-explorer/Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Expected:

- build succeeds
- `/Users/dho/Documents/lungfish-genome-explorer/build/Debug/Lungfish.app` is refreshed

Manual sanity check in the debug build:

- open the mapping analysis bundle
- confirm the row label reads `Consensus`
- confirm `Consensus Min Depth` is visible even with `Hide High-Gap Sites` off
- confirm low-depth positions remain `N`
- click `Extract Consensus…` and verify the existing extraction sheet appears
- confirm the mapping analysis directory no longer retains `<sample>.raw.sam` after a successful run

---

## Completion Criteria

- Mapping-mode inspector controls can adjust consensus settings without re-enabling global embedded-viewer notifications.
- `Consensus Min Depth` and `Masking Min Depth` are distinct settings with distinct behavior.
- The mapping inspector exposes `Extract Consensus…` and routes it through the existing FASTA extraction dialog.
- Consensus export uses biological sequence semantics: insertions included, deleted reference columns omitted, under-covered positions left as `N`.
- Deferred consensus-export scopes are left as code comments near the export entry point.
- Managed mapping runs no longer retain raw SAM files after successful normalization/indexing.
- Focused tests pass and a fresh Debug build is available for review.
