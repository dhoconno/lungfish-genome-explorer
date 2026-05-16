# Wave 3 AppKit Modal Actors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce remaining legacy AppKit `runModal` and main-actor hop anti-patterns in a small, enumerated Slice E surface with semantic tests.

**Architecture:** Keep existing AppKit view controllers and presenters in place, but extract small decision helpers where alert responses can be tested without launching UI. Window-presented alerts continue to use completion-handler sheets; synchronous `runModal` is retained only for no-window synchronous gates with explicit `runModal-legacy-allowed because ...` comments.

**Tech Stack:** Swift, XCTest, AppKit, Swift Concurrency, Swift Package Manager.

---

## Inventory

Command:

```bash
rg -n '\.runModal\(|Task \{ @MainActor|await MainActor\.run' Sources/LungfishApp Tests/LungfishAppTests
```

Current production findings in the Slice E ownership area:

- `Sources/LungfishApp/Services/ReferenceBundleAnnotationImportConfigurationPresenter.swift:126` has a no-window `alert.runModal()` fallback with an existing exception comment.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift:1862` has a no-window confirmation fallback for derived alignment removal.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift:2089` uses `Task { @MainActor [weak self] in` to load variant-calling catalog data before presenting a dialog.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift:2425` uses `Task { @MainActor [weak self] in` to load primer-trim dialog dependencies before presenting a dialog.
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift:656` has a no-window prompt fallback for workflow naming.
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift:705` has a no-window run-binding fallback.
- `Sources/LungfishApp/Views/Assembly/AssemblyRuntimePreflight.swift:63` has a no-window warning fallback.
- `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift:337` and `:569` use `Task { @MainActor in` inside workflow completion paths.
- `Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift:343`, `:348`, `:355`, `:369`, `:373`, and `:380` use `await MainActor.run` from detached/background storage work.
- `Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift:206`, `:229`, and `:251` use `Task { @MainActor in` for view-model actions.

Out of scope by owner instruction:

- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` remains Worker A owned.
- `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift` remains Worker B owned.
- `Sources/LungfishApp/Views/Metagenomics/CzIdImportSheet.swift` and `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift` remain Worker F owned.

## Slice Spec

Modify only this small set if feasible:

- `Sources/LungfishApp/Services/ReferenceBundleAnnotationImportConfigurationPresenter.swift`
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift`
- `Sources/LungfishApp/Views/Assembly/AssemblyRuntimePreflight.swift`
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`
- Settings tabs under `Sources/LungfishApp/Views/Settings/` if changes remain straightforward and testable.
- `Tests/LungfishAppTests/AppKitConcurrencyModalSafetyTests.swift`
- New focused semantic tests in `Tests/LungfishAppTests/` for extracted helpers.

Keep existing UI behavior. Do not restyle dialogs, move feature workflows, or introduce UI automation.

## TDD / Red-Test Plan

### Task 1: Modal Response Semantics

**Files:**

- Modify: `Sources/LungfishApp/Services/ReferenceBundleAnnotationImportConfigurationPresenter.swift`
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyRuntimePreflight.swift`
- Create or modify: `Tests/LungfishAppTests/AppKitModalPresenterSemanticsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@MainActor
func testReferenceAnnotationPresenterBuildsConfigurationOnlyForImportResponse() {
    let bundleURL = URL(fileURLWithPath: "/tmp/project/ref.lungfishref")
    XCTAssertEqual(
        ReferenceBundleAnnotationImportConfigurationPresenter.configurationForTest(
            response: .alertFirstButtonReturn,
            selectedBundleURL: bundleURL,
            trackID: "  gene_track  ",
            trackName: "  Genes  "
        ),
        ReferenceBundleAnnotationImportConfiguration(
            bundleURL: bundleURL,
            trackID: "gene_track",
            trackName: "Genes"
        )
    )
    XCTAssertNil(
        ReferenceBundleAnnotationImportConfigurationPresenter.configurationForTest(
            response: .alertSecondButtonReturn,
            selectedBundleURL: bundleURL,
            trackID: "ignored",
            trackName: "ignored"
        )
    )
}

@MainActor
func testAssemblyRuntimePreflightUsesSheetWhenWindowExistsAndLegacyFallbackOnlyWithoutWindow() {
    XCTAssertEqual(
        AssemblyRuntimePreflight.presentationModeForTest(hasWindow: true),
        .sheet
    )
    XCTAssertEqual(
        AssemblyRuntimePreflight.presentationModeForTest(hasWindow: false),
        .legacySynchronousFallback
    )
}
```

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter AppKitModalPresenterSemanticsTests
```

Expected: fail to compile because the test hooks and semantic enum do not exist.

- [ ] **Step 3: Implement minimal helpers**

Add internal, testable pure helpers that are used by production completion handlers:

```swift
static func makeConfiguration(
    response: NSApplication.ModalResponse,
    selectedBundleURL: URL?,
    trackID: String,
    trackName: String
) -> ReferenceBundleAnnotationImportConfiguration?
```

and:

```swift
enum PresentationMode: Equatable {
    case sheet
    case legacySynchronousFallback
}

static func presentationMode(hasWindow: Bool) -> PresentationMode
```

- [ ] **Step 4: Run green tests**

Run:

```bash
swift test --filter AppKitModalPresenterSemanticsTests
```

Expected: pass.

### Task 2: Workflow Builder Prompt Semantics

**Files:**

- Modify: `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift`
- Modify: `Tests/LungfishAppTests/AppKitModalPresenterSemanticsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@MainActor
func testWorkflowNamePromptAcceptsTrimmedNonEmptyFirstButtonOnly() {
    XCTAssertEqual(
        WorkflowBuilderViewController.workflowNamePromptResultForTest(
            response: .alertFirstButtonReturn,
            rawName: "  Assembly QC  "
        ),
        "Assembly QC"
    )
    XCTAssertNil(
        WorkflowBuilderViewController.workflowNamePromptResultForTest(
            response: .alertFirstButtonReturn,
            rawName: "   "
        )
    )
    XCTAssertNil(
        WorkflowBuilderViewController.workflowNamePromptResultForTest(
            response: .alertSecondButtonReturn,
            rawName: "Assembly QC"
        )
    )
}
```

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter AppKitModalPresenterSemanticsTests
```

Expected: fail to compile because the workflow prompt helper does not exist.

- [ ] **Step 3: Implement minimal helper and wire existing alert handler through it**

Add:

```swift
static func workflowNamePromptResult(
    response: NSApplication.ModalResponse,
    rawName: String
) -> String?
```

Use it from `promptForWorkflowName` so the semantic test covers production behavior.

- [ ] **Step 4: Run green tests**

Run:

```bash
swift test --filter AppKitModalPresenterSemanticsTests
```

Expected: pass.

### Task 3: Narrow Source Guards

**Files:**

- Modify: `Tests/LungfishAppTests/AppKitConcurrencyModalSafetyTests.swift`
- Modify: selected production files only as needed by the red output.

- [ ] **Step 1: Write failing inventory tests**

Replace the broad `runModal` sweep with an explicit allow-list:

```swift
let allowedLegacyRunModalSites: [String: Set<Int>] = [
    "Sources/LungfishApp/Services/ReferenceBundleAnnotationImportConfigurationPresenter.swift": [126],
    "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift": [1862],
    "Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift": [656, 705],
    "Sources/LungfishApp/Views/Assembly/AssemblyRuntimePreflight.swift": [63],
]
```

The line numbers may shift during implementation; the final assertion should report the actual unexpected path and line and require the nearby `runModal-legacy-allowed because` comment for every allowed site.

- [ ] **Step 2: Run red source guard**

Run:

```bash
swift test --filter AppKitConcurrencyModalSafetyTests
```

Expected: fail until the allow-list reflects all intentionally retained call sites or production comments are fixed.

- [ ] **Step 3: Keep only concrete legacy fallbacks**

For each retained `runModal`, verify that the code path lacks a presenter window and that the method must complete a synchronous gate or callback. Update comments only where needed.

- [ ] **Step 4: Run green source guard**

Run:

```bash
swift test --filter AppKitConcurrencyModalSafetyTests
```

Expected: pass.

### Task 4: Main-Actor Cleanup Where Feasible

**Files:**

- Modify: `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`
- Modify: `Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift`
- Modify: `Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift`
- Modify: `Tests/LungfishAppTests/AppKitConcurrencyModalSafetyTests.swift`

- [ ] **Step 1: Write failing targeted source tests**

Extend the targeted unsafe-hop scan only for files this slice owns, avoiding Worker A/B/F files:

```swift
let scannedPaths = [
    "Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift",
    "Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift",
    "Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift",
]
```

Expected violations should be concrete and actionable, not a whole-app ban.

- [ ] **Step 2: Run red source tests**

Run:

```bash
swift test --filter AppKitConcurrencyModalSafetyTests
```

Expected: fail on the current owned `Task { @MainActor` or `await MainActor.run` occurrences.

- [ ] **Step 3: Convert obvious cases**

Use direct `@MainActor` methods when the enclosing type is main-actor isolated. Use `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` from nonisolated callbacks when a completion must hop to AppKit. Leave any unclear cases untouched and out of the targeted guard with a residual-risk note.

- [ ] **Step 4: Run green source tests**

Run:

```bash
swift test --filter AppKitConcurrencyModalSafetyTests
```

Expected: pass.

## Implementation Plan

1. Add `Tests/LungfishAppTests/AppKitModalPresenterSemanticsTests.swift` with the red tests for reference annotation, assembly preflight, and workflow builder prompt semantics.
2. Run `swift test --filter AppKitModalPresenterSemanticsTests` and capture the red compile/test output.
3. Add minimal internal helpers to the production files and wire existing completion handlers through them.
4. Run `swift test --filter AppKitModalPresenterSemanticsTests` and keep iterating until green.
5. Update `AppKitConcurrencyModalSafetyTests` from broad modal scanning toward explicit allowed legacy sites with required reason comments.
6. Run `swift test --filter AppKitConcurrencyModalSafetyTests` and capture red output.
7. Adjust owned source comments or small actor-hop conversions until the guard passes.
8. Run the full required verification commands.
9. Commit only this slice from `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/wave3-appkit-modal-actors`.

## Verification Commands

```bash
swift test --filter AppKitConcurrencyModalSafetyTests
swift test --filter AppKitModalPresenterSemanticsTests
swift build --product Lungfish
git diff --check
```

## Residual Risks

- Some `Task { @MainActor` occurrences are lifecycle task handles, delayed UI work, or explicitly owned by other workers; this slice will not rewrite them.
- Source-line allow-lists are intentionally pragmatic but can churn when nearby code moves; the test will still require a concrete exception comment at every retained legacy modal call.
- `runModal` fallbacks with no presenter window remain because returning without a choice would silently drop user-initiated workflows.
- Semantic tests verify response mapping and presentation-mode decisions, not visual AppKit layout.
