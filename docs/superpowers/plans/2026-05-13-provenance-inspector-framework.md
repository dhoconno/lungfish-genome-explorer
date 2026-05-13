# Provenance Inspector Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shared right-sidebar Inspector Provenance tab that can browse canonical multi-step provenance for every scientific bundle/result and expose bundle provenance export from the same interface.

**Architecture:** Add a `ProvenanceCoverageMonitor` and `ProvenanceInspectorViewModel` that normalize `ProvenanceEnvelope` into compact summary, warning, lineage, file, invocation, runtime, signature, and raw JSON view data. Wire the Inspector to keep a current `ProvenanceInspectableItem` for sidebar/bundle/result selections and expose `.provenance` in every scientific Inspector content mode, showing a blocking missing/incomplete state when provenance is required but absent. Render the model with one SwiftUI `ProvenanceSection` using existing Lungfish Inspector typography, system colors, `DisclosureGroup`, and menus.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit pasteboard/Finder panels, XCTest, existing `LungfishWorkflow` provenance APIs (`ProvenanceRecorder`, `ProvenanceEnvelopeReader`, `ProvenanceExporter`, `ProvenanceExportFormat`).

---

### Task 1: Provenance Presentation And Coverage Model

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift`
- Test: `Tests/LungfishAppTests/ProvenanceInspectorViewModelTests.swift`

- [ ] **Step 1: Write failing tests for required coverage, missing provenance, complete provenance, and lineage normalization**

```swift
import XCTest
@testable import LungfishApp
import LungfishWorkflow

@MainActor
final class ProvenanceInspectorViewModelTests: XCTestCase {
    func testScientificSidebarTypesRequireProvenance() {
        let monitor = ProvenanceCoverageMonitor()
        let required: [SidebarItemType] = [
            .referenceBundle,
            .multipleSequenceAlignmentBundle,
            .phylogeneticTreeBundle,
            .fastqBundle,
            .primerSchemeBundle,
            .classificationResult,
            .esvirituResult,
            .taxTriageResult,
            .naoMgsResult,
            .nvdResult,
            .czIdResult,
            .analysisResult,
            .alignment,
            .sequence,
            .coverage
        ]

        let missing = required.filter { type in
            monitor.requirement(for: ProvenanceInspectableItem(url: nil, sidebarType: type, contentMode: .empty, displayName: nil)).isNotRequired
        }

        XCTAssertEqual(missing, [])
    }

    func testMissingRequiredProvenanceIsBlockingAndBrowsable() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(item: ProvenanceInspectableItem(url: dir, sidebarType: .fastqBundle, contentMode: .fastq, displayName: "Reads"))

        XCTAssertEqual(viewModel.audit.status, .missing)
        XCTAssertTrue(viewModel.audit.isBlocking)
        XCTAssertTrue(viewModel.shouldShowTab)
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "Missing provenance" })
    }

    func testCompleteEnvelopeBuildsSummaryLineageAndFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("input.fastq")
        let output = dir.appendingPathComponent("output.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("@r\nACG\n+\n!!!\n".utf8).write(to: output)
        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)
        let stepA = ProvenanceStep(toolName: "fastq-import", toolVersion: "1.0", argv: ["fastq-import", input.path], inputs: [inputDescriptor], outputs: [outputDescriptor], exitStatus: 0, wallTimeSeconds: 2)
        let stepB = ProvenanceStep(toolName: "qc", toolVersion: "2.0", argv: ["qc", output.path], inputs: [outputDescriptor], outputs: [outputDescriptor], exitStatus: 0, wallTimeSeconds: 1, dependsOn: [stepA.id])
        let envelope = ProvenanceEnvelope(
            workflowName: "FASTQ Import",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.4.0",
            argv: ["lungfish-cli", "import", input.path],
            options: ProvenanceOptions(explicit: ["quality": .string("strict")], defaults: ["compress": .boolean(true)], resolvedDefaults: ["threads": .integer(4)]),
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [stepA, stepB],
            wallTimeSeconds: 3,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(item: ProvenanceInspectableItem(url: dir, sidebarType: .fastqBundle, contentMode: .fastq, displayName: "Reads"))

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.workflowName, "FASTQ Import")
        XCTAssertEqual(viewModel.summary.stepCount, 2)
        XCTAssertEqual(viewModel.lineageRuns.first?.steps.map(\.toolName), ["fastq-import", "qc"])
        XCTAssertEqual(viewModel.fileRows.map(\.role).sorted(), ["Input", "Output"])
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "quality" && $0.kind == "Explicit" })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProvenanceInspectorViewModelTests`
Expected: FAIL because `ProvenanceCoverageMonitor`, `ProvenanceInspectorViewModel`, and `ProvenanceInspectableItem` do not exist.

- [ ] **Step 3: Implement the model**

Create the model with:
- `ProvenanceInspectableItem`
- `ProvenanceRequirement`
- `ProvenanceAuditStatus`
- `ProvenanceAuditResult`
- `ProvenanceCoverageMonitor`
- `ProvenanceWarningRow`
- `ProvenanceRunSummary`
- `ProvenanceLineageRun`
- `ProvenanceLineageStep`
- `ProvenanceFileRow`
- `ProvenanceOptionRow`
- `ProvenanceRuntimeRow`
- `ProvenanceInspectorViewModel`

Key behavior:
- Required sidebar item types are all scientific bundle/result/data types from the test.
- Required file extensions include `lungfishref`, `lungfishfastq`, `lungfishmsa`, `lungfishtree`, `lungfishprimers`, `bam`, `cram`, `vcf`, `bcf`, `fasta`, `fa`, `fastq`, `fq`, `gz`.
- Scientific content modes `.genomics`, `.mapping`, `.assembly`, `.fastq`, and `.metagenomics` require a tab when a URL is present.
- `audit(_:)` calls `ProvenanceRecorder.findProvenanceEnvelope(for:)`.
- Missing required provenance returns `.missing` and `isBlocking == true`.
- Present provenance validates workflow/tool/version, command/argv, runtime, files, outputs, exit status, wall time, and step requirements.
- Incomplete provenance returns `.incomplete` with warning rows.
- View rows use middle-truncated paths and human-readable file sizes/durations.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProvenanceInspectorViewModelTests`
Expected: PASS.

### Task 2: Inspector Tab Wiring

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/InspectorProvenanceTabTests.swift`

- [ ] **Step 1: Write failing tests for tab availability and selection URL loading**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class InspectorProvenanceTabTests: XCTestCase {
    func testEveryScientificContentModeIncludesProvenanceTab() {
        let modes: [ViewportContentMode] = [.genomics, .mapping, .assembly, .fastq, .metagenomics]
        for mode in modes {
            let viewModel = InspectorViewModel()
            viewModel.contentMode = mode
            XCTAssertTrue(viewModel.availableTabs.contains(.provenance), "Missing provenance tab for \(mode)")
        }
    }

    func testNonScientificEmptyModeDoesNotAddProvenanceByDefault() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .empty
        XCTAssertFalse(viewModel.availableTabs.contains(.provenance))
    }

    func testSidebarSelectionLoadsProvenanceItem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vc = InspectorViewController()
        _ = vc.view
        let item = SidebarItem(title: "Reads", type: .fastqBundle, url: dir)
        vc.testingHandleSidebarSelectionChanged(Notification(name: .sidebarSelectionChanged, object: nil, userInfo: ["item": item]))

        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.url, dir)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .fastqBundle)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.audit.status, .missing)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InspectorProvenanceTabTests`
Expected: FAIL because `.provenance` and `provenanceSectionViewModel` are not wired.

- [ ] **Step 3: Wire the Inspector**

Implement:
- `InspectorTab.provenance = "provenance"` with display label `Provenance` and icon `point.3.connected.trianglepath.dotted`.
- Add `let provenanceSectionViewModel = ProvenanceInspectorViewModel()` to `InspectorViewModel`.
- Add `.provenance` to `.genomics`, `.mapping`, `.assembly`, `.fastq`, `.metagenomics`; keep `.empty` unchanged.
- Add `.provenance` to the scroll tab switch and render `ProvenanceSection(viewModel:)`.
- On sidebar selection, call `provenanceSectionViewModel.load(item:)` with item URL/type/current content mode/display name.
- On bundle/document update APIs (`updateBundleMetadata`, `updateAssemblyDocument`, `updateMappingDocument`, MSA/tree/Nao-MGS/classifier state methods), refresh with the concrete bundle/result URL when available.
- On `clearSelection()`, clear the provenance model.
- If a notification requests tab raw value `"provenance"`, select it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter InspectorProvenanceTabTests`
Expected: PASS.

### Task 3: Provenance SwiftUI Section And Actions

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/ProvenanceSectionSourceTests.swift`

- [ ] **Step 1: Write failing source-structure tests**

```swift
import XCTest

final class ProvenanceSectionSourceTests: XCTestCase {
    func testProvenanceSectionUsesInspectorStyleDisclosureGroupsAndStableAccessibilityIDs() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift")
        XCTAssertTrue(source.contains("DisclosureGroup(\"Run Summary\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Lineage\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Files & Outputs\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Invocation & Options\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Runtime\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Raw JSON\""))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-root\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-run-summary\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-step-list\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-export-menu\")"))
        XCTAssertTrue(source.contains("LungfishInspectorStyle.sectionTitleFont"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProvenanceSectionSourceTests`
Expected: FAIL because `ProvenanceSection.swift` does not exist.

- [ ] **Step 3: Implement `ProvenanceSection`**

Render:
- Top action row with `Menu("Export Provenance...")` listing `ProvenanceExportFormat.allCases`.
- `Copy Command`, `Reveal Sidecar`, `Copy Run ID` buttons when those values exist.
- Blocking missing/incomplete banner using system warning colors only.
- `Run Summary` disclosure with workflow/tool/version/status/sidecar/schema/step counts/durations.
- `Warnings` disclosure when `viewModel.warnings` is non-empty.
- `Lineage` disclosure with searchable run and step hierarchy.
- `Files & Outputs` disclosure with role/path/checksum/size and file action menu.
- `Invocation & Options` disclosure with command, argv, explicit/default/resolved option rows.
- `Runtime`, `Signatures`, and collapsed `Raw JSON`.
- Stable accessibility identifiers from the spec.
- Use `Text`, `Button`, `Menu`, `DisclosureGroup`, `.font(.caption)`, `LungfishInspectorStyle.sectionTitleFont`, and system colors only.

- [ ] **Step 4: Wire export action**

In `InspectorViewController.setupViewModelCallbacks()`, set `viewModel.provenanceSectionViewModel.onExportRequested` to present an `NSOpenPanel` directory picker and call `ProvenanceExporter().exportBundle(...)` with the selected format, current envelope, sidecar URL, source root URL, and `exportArgv`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ProvenanceSectionSourceTests`
Expected: PASS.

### Task 4: Coverage Monitor Integration Tests And Cleanup

**Files:**
- Modify: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
- Modify: `Tests/LungfishAppTests/InspectorAssemblyModeTests.swift`
- Modify: `Tests/LungfishAppTests/ProvenanceInspectorViewModelTests.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` only if inline provenance snippets need wording that points to the generic tab.

- [ ] **Step 1: Update existing Inspector tab expectations**

Change mapping expectations from `Bundle, Selected Item, View, Analysis` to `Bundle, Selected Item, View, Analysis, Provenance`.
Change assembly expectations from document-only to `Bundle, Provenance`.

- [ ] **Step 2: Run relevant app tests**

Run: `swift test --filter InspectorMappingModeTests`
Expected: PASS.

Run: `swift test --filter InspectorAssemblyModeTests`
Expected: PASS.

Run: `swift test --filter ProvenanceInspectorViewModelTests`
Expected: PASS.

- [ ] **Step 3: Run a broader targeted suite**

Run: `swift test --filter LungfishAppTests`
Expected: PASS or report pre-existing unrelated failures with exact failing test names.

- [ ] **Step 4: Verify style and placeholders**

Run: `rg -n "TBD|TODO|FIXME|lorem|coming soon" Sources/LungfishApp/Views/Inspector Tests/LungfishAppTests docs/superpowers/plans/2026-05-13-provenance-inspector-framework.md`
Expected: no new placeholder text from this implementation.

Run: `git diff --check`
Expected: no whitespace errors.
