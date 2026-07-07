# Issue #21 — Run Classification on a Folder of Files — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first**, especially §1.7 (virtual bundles / materialization) — folder-expanded samples may themselves be virtual and must be materialized per-sample before classifying.

**Goal:** Selecting a folder in the sidebar and running a classifier (Kraken2, EsViritu, TaxTriage) runs it on every FASTQ sample in the folder. If subfolders contain additional eligible bundles, the user is asked whether to include them (top-level only vs. traverse subfolders).

**Architecture:** Workflow operations already support folder selection via `WorkflowSidebarInputSelection.resolve(items:projectURL:)`, which walks the sidebar tree, produces `directReadURLs` (top-level bundles) and `recursiveReadURLs` (including subfolders), and reports `additionalDescendantBundleCount` / `hasAdditionalDescendantBundles`. Classification currently bypasses this: it calls `gatherFASTQOperationInputURLs` → `resolveFASTQOperationInputURL(from:)`, which rejects a folder URL (no `.lungfishfastq` extension) and drops it, yielding an empty input list ("No FASTQ/FASTA Inputs Selected"). The fix: route classification input-gathering through the SAME `WorkflowSidebarInputSelection` expansion that workflow operations use, add a subfolder-inclusion prompt when descendants exist, and feed the expanded per-sample URLs to the classification batch path (which already supports multiple configs).

**Tech Stack:** Swift 6.2, AppKit (NSAlert, NSOutlineView), XCTest.

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- Each expanded sample that is a virtual bundle must be materialized before classifying (§1.7). The existing batch classification path already does per-sample materialization — reuse it; do not classify `preview.fastq`.
- OperationCenter: each per-sample classification run reports via `update` + `log` and terminates with `.complete`/`.fail` (batch summary aggregates).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. Selecting a folder with N top-level FASTQ bundles and running Kraken2 / EsViritu / TaxTriage classifies all N samples (batch).
2. If the folder has subfolders containing additional eligible bundles, an NSAlert offers "Top Level Only" vs "Include Subfolders" (and Cancel). Choosing "Include Subfolders" classifies the descendants too.
3. Selecting a folder with zero eligible bundles shows a clear "no FASTQ samples found in folder" message (not a silent no-op or a misleading generic error).
4. Selecting individual FASTQ bundles (existing behavior) still works unchanged.
5. Suite is GREEN.

## Key files

- `Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift` (`resolve(items:projectURL:)` ~lines 110–217; `directFASTQBundleChildren` ~232; `recursiveFASTQBundleChildren` ~236–250; `hasAdditionalDescendantBundles` ~51–53; `additionalDescendantBundleCount` ~201; `subfolderSummaryText` ~67–71) — the pattern to reuse.
- `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` (`gatherFASTQOperationInputURLs` ~191–204; `resolveFASTQOperationInputURLs`/`resolveFASTQOperationInputURL(from:)` ~259–301 — where folders are dropped; classification dialog entry `showFASTQOperationsDialog` ~81–189)
- `Sources/LungfishApp/App/AppDelegate+Classification.swift` (`launchKraken2Classification`/`launchEsVirituDetection`/`launchTaxTriage` ~20–32; batch classification support ~43–54)
- `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift` (`SidebarItemType.folder/.project/.fastqBundle`)
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift` (`selectedFileURLs()`) and a `selectedSidebarItems()`-style accessor (find or add one that returns the `SidebarItem`s, not just URLs)
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift` (NSAlert sheet pattern ~304–356 to mirror)

---

### Task 1: A pure folder-expansion resolver for classification input

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` (add a new static resolver alongside `resolveFASTQOperationInputURLs`)
- Test: `Tests/LungfishAppTests/ClassificationFolderInputTests.swift` (create)

**Interfaces:**
- Consumes: `WorkflowSidebarInputSelection.resolve(items:projectURL:)` and its `directReadURLs`, `recursiveReadURLs`, `additionalDescendantBundleCount`, `hasAdditionalDescendantBundles`.
- Produces:
  ```swift
  struct ClassificationFolderInput {
      let directReadURLs: [URL]        // top-level samples in selected folders + explicitly selected bundles
      let recursiveReadURLs: [URL]     // above + samples in subfolders
      let additionalDescendantCount: Int
      var hasSubfolderBundles: Bool { additionalDescendantCount > 0 }
      var isEmpty: Bool { directReadURLs.isEmpty && recursiveReadURLs.isEmpty }
  }
  static func classificationFolderInput(items: [SidebarItem], projectURL: URL?) -> ClassificationFolderInput
  ```

**Before you start:** Read `WorkflowSidebarInputSelection.resolve` fully. It already produces exactly these lists. This task is a thin adapter so classification can reuse it and so the logic is unit-testable without AppKit.

- [ ] **Step 1: Write the failing test.** Because `SidebarItem` construction may require AppKit context, test at the level of the adapter by injecting a pre-built `WorkflowSidebarInputSelection` (if `resolve` is the only constructor, add an internal memberwise initializer or a test factory). If `SidebarItem` is constructible in tests, build a folder item with two direct `.fastqBundle` children and one subfolder containing one more bundle; assert:

```swift
import XCTest
@testable import LungfishApp

final class ClassificationFolderInputTests: XCTestCase {
    func testFolderWithTopLevelAndSubfolderBundles() {
        let input = AppDelegate.classificationFolderInput(items: [folderItemFixture()], projectURL: nil)
        XCTAssertEqual(input.directReadURLs.count, 2)
        XCTAssertEqual(input.recursiveReadURLs.count, 3)
        XCTAssertEqual(input.additionalDescendantCount, 1)
        XCTAssertTrue(input.hasSubfolderBundles)
        XCTAssertFalse(input.isEmpty)
    }

    func testEmptyFolderIsEmpty() {
        let input = AppDelegate.classificationFolderInput(items: [emptyFolderItemFixture()], projectURL: nil)
        XCTAssertTrue(input.isEmpty)
        XCTAssertFalse(input.hasSubfolderBundles)
    }
}
```
Add `folderItemFixture()` / `emptyFolderItemFixture()` helpers building `SidebarItem`s (mirror how existing sidebar tests construct items — search `Tests/` for `SidebarItem(` usage; if none, construct via the public initializer in `SidebarItem.swift`).

- [ ] **Step 2: Run — expect FAIL** (`classificationFolderInput` missing).

- [ ] **Step 3: Implement the adapter.** In `AppDelegate+ToolsMenu.swift`:

```swift
struct ClassificationFolderInput {
    let directReadURLs: [URL]
    let recursiveReadURLs: [URL]
    let additionalDescendantCount: Int
    var hasSubfolderBundles: Bool { additionalDescendantCount > 0 }
    var isEmpty: Bool { directReadURLs.isEmpty && recursiveReadURLs.isEmpty }
}

static func classificationFolderInput(items: [SidebarItem], projectURL: URL?) -> ClassificationFolderInput {
    let selection = WorkflowSidebarInputSelection.resolve(items: items, projectURL: projectURL)
    return ClassificationFolderInput(
        directReadURLs: selection.directReadURLs,
        recursiveReadURLs: selection.recursiveReadURLs,
        additionalDescendantCount: selection.additionalDescendantBundleCount
    )
}
```
(Match the real property names on `WorkflowSidebarInputSelection` exactly as read in "Before you start".)

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(classification): add folder-expanding input resolver`.

---

### Task 2: Subfolder-inclusion prompt (pure decision + AppKit sheet)

**Files:**
- Create: `Sources/LungfishApp/App/ClassificationFolderPrompt.swift` (pure decision enum + a thin NSAlert presenter)
- Test: `Tests/LungfishAppTests/ClassificationFolderInputTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  enum SubfolderInclusionChoice { case topLevelOnly, includeSubfolders, cancel }
  enum ClassificationFolderPrompt {
      /// Which URL list to use given the user's choice.
      static func readURLs(for choice: SubfolderInclusionChoice, from input: ClassificationFolderInput) -> [URL]?
      // returns nil for .cancel
  }
  ```

- [ ] **Step 1: Write the failing test.**

```swift
    func testChoiceSelectsCorrectURLList() {
        let input = ClassificationFolderInput(
            directReadURLs: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            recursiveReadURLs: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/sub/c")],
            additionalDescendantCount: 1
        )
        XCTAssertEqual(ClassificationFolderPrompt.readURLs(for: .topLevelOnly, from: input)?.count, 2)
        XCTAssertEqual(ClassificationFolderPrompt.readURLs(for: .includeSubfolders, from: input)?.count, 3)
        XCTAssertNil(ClassificationFolderPrompt.readURLs(for: .cancel, from: input))
    }
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** `ClassificationFolderPrompt.swift`:

```swift
import AppKit

enum SubfolderInclusionChoice { case topLevelOnly, includeSubfolders, cancel }

enum ClassificationFolderPrompt {
    static func readURLs(for choice: SubfolderInclusionChoice, from input: ClassificationFolderInput) -> [URL]? {
        switch choice {
        case .topLevelOnly:      return input.directReadURLs
        case .includeSubfolders: return input.recursiveReadURLs
        case .cancel:            return nil
        }
    }

    /// Presents the top-level-vs-subfolders sheet. Calls `completion` with the choice.
    @MainActor
    static func present(for input: ClassificationFolderInput, in window: NSWindow,
                        completion: @escaping (SubfolderInclusionChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Include Subfolders?"
        let n = input.additionalDescendantCount
        alert.informativeText = "This folder's subfolders contain \(n) additional eligible FASTQ \(n == 1 ? "sample" : "samples"). Process only the top-level samples, or include the subfolders?"
        alert.addButton(withTitle: "Include Subfolders")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Top Level Only")        // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                // .alertThirdButtonReturn
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:  completion(.includeSubfolders)
            case .alertSecondButtonReturn: completion(.topLevelOnly)
            default:                       completion(.cancel)
            }
        }
    }
}
```

- [ ] **Step 4: Run — expect PASS** (the pure `readURLs` test; `present` is exercised in GUI verification).

- [ ] **Step 5: Commit** `feat(classification): add subfolder-inclusion prompt`.

---

### Task 3: Route classification input-gathering through folder expansion

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` (`showFASTQOperationsDialog` for `initialCategory == .classification`, and/or `gatherFASTQOperationInputURLs`)
- Modify: `Sources/LungfishApp/App/AppDelegate+Classification.swift` (launch methods for kraken2/esviritu/taxtriage)
- Possibly add: a `selectedSidebarItems()` accessor in `SidebarViewController+OutlineDataSource.swift` returning `[SidebarItem]` (needed because `classificationFolderInput` needs items, not just URLs; `selectedFileURLs()` only returns URLs)

**Interfaces:**
- Consumes: `classificationFolderInput(items:projectURL:)` (Task 1); `ClassificationFolderPrompt` (Task 2); the existing batch classification entry that accepts multiple input URLs / configs (research: `AppDelegate+Classification.swift` batch support ~lines 43–54).
- Produces: classification launched with the expanded list of per-sample bundle URLs.

**Before you start:** Confirm whether the sidebar exposes selected `SidebarItem`s. `selectedFileURLs()` returns URLs; you need the items to call `resolve`. If there is no `selectedSidebarItems()`, add one mirroring `selectedFileURLs()` (iterate `outlineView.selectedRowIndexes`, collect `outlineView.item(atRow:) as? SidebarItem`). Trace the exact batch classification call the launch methods use so you pass the expanded URLs into the SAME path (which already materializes per-sample per §1.7).

- [ ] **Step 1: Write the failing test.** Add an integration-flavored test in `Tests/LungfishAppTests/ClassificationFolderInputTests.swift` that exercises the decision-to-URLs flow the launch method will use (keep it at the pure boundary you built in Tasks 1–2, since the full dialog is AppKit-bound):

```swift
    func testFolderSelectionYieldsBatchInputWhenNoSubfolders() {
        // A folder with only top-level bundles: no prompt needed; use directReadURLs directly.
        let input = ClassificationFolderInput(
            directReadURLs: [URL(fileURLWithPath: "/x/a.lungfishfastq"), URL(fileURLWithPath: "/x/b.lungfishfastq")],
            recursiveReadURLs: [URL(fileURLWithPath: "/x/a.lungfishfastq"), URL(fileURLWithPath: "/x/b.lungfishfastq")],
            additionalDescendantCount: 0)
        XCTAssertFalse(input.hasSubfolderBundles)
        // The launch path uses directReadURLs when there are no descendants:
        XCTAssertEqual(input.directReadURLs.count, 2)
    }
```

- [ ] **Step 2: Run — expect PASS or FAIL** depending on whether this only exercises Task 1 types (it may pass immediately; that is acceptable — its purpose is to lock the "no-subfolder → no prompt" contract that Step 3 must honor). If it passes, proceed; the behavioral change is verified in Step 4 GUI.

- [ ] **Step 3: Wire the launch path.** In `showFASTQOperationsDialog(...)` (classification category) or in each classification launch method:
  1. Get selected sidebar items via `selectedSidebarItems()`.
  2. Compute `let input = AppDelegate.classificationFolderInput(items:projectURL:)`.
  3. If `input.isEmpty` AND a folder was selected → show a clear NSAlert "No FASTQ samples found in the selected folder." and return (satisfies acceptance #3). If no folder was selected (individual bundles / current dataset), fall back to the EXISTING `gatherFASTQOperationInputURLs` path unchanged (satisfies acceptance #4).
  4. If `input.hasSubfolderBundles` → call `ClassificationFolderPrompt.present(for:in:completion:)`; in the completion, resolve `readURLs = ClassificationFolderPrompt.readURLs(for: choice, from: input)`; if nil (cancel) return.
  5. Else (`!hasSubfolderBundles`) → `readURLs = input.directReadURLs`.
  6. Launch classification with `readURLs` through the existing **batch** classification path (multiple samples). The batch path already materializes each virtual bundle before running — do NOT bypass it.

  Keep the change surgical: for individual-bundle selection, behavior must be byte-for-byte the same as today. Only folder selections take the new branch.

- [ ] **Step 4: GUI verification (required — this is the core of the issue).** Build `.build/debug/Lungfish`, launch via computer-use. Test all three cases:
  - Select a folder with 2+ top-level FASTQ bundles → run Kraken2 → confirm both samples classified (batch). Repeat for EsViritu and TaxTriage.
  - Select a folder that also has a subfolder with a bundle → run a classifier → confirm the "Include Subfolders?" sheet appears; choose "Include Subfolders" → confirm the subfolder sample is classified too; re-run and choose "Top Level Only" → confirm the subfolder sample is skipped.
  - Select an empty folder → confirm the "No FASTQ samples found" message.
  - Select a single bundle → confirm classification works exactly as before.
  Screenshot each case.

- [ ] **Step 5: Commit** `fix(classification): expand folder selection to all samples with subfolder prompt`.

---

### Task 4: CLI parity check

**Files:** `Sources/LungfishCLI/Commands/` (classification command — find via `grep -rn "kraken2\|classify\|taxtriage" Sources/LungfishCLI`).

- [ ] **Step 1:** Determine whether the CLI classification command already accepts a directory argument and fans out over contained samples. If it does, add/confirm a test that a directory input classifies all contained bundles, with a `--recursive` flag mirroring the GUI subfolder choice. If it does not, add directory support + `--recursive` flag to match GUI behavior (CLI parity is a binding rule).
- [ ] **Step 2:** Write a failing test for directory fan-out (temp dir with 2 bundles → command enumerates 2). Run — expect FAIL if unsupported.
- [ ] **Step 3:** Implement directory enumeration in the CLI command reusing the same eligible-bundle detection (`FASTQBundle` predicates). Add `--recursive` to include subfolders.
- [ ] **Step 4:** Run — expect PASS. Manual check: `.build/debug/lungfish-cli classify <folder> ...`.
- [ ] **Step 5:** Commit `feat(cli): classify a folder of samples with --recursive`.

---

### Final verification

- [ ] `swift build/test --package-path <worktree> --skip-update` → clean + GREEN.
- [ ] GUI screenshots for folder / subfolder-include / subfolder-toplevel / empty-folder / single-bundle attached to issue #21.
- [ ] CLI folder classification demonstrated.

## Self-review checklist

- Spec coverage: expansion (Task 1), prompt (Task 2), GUI wiring for all 3 classifiers + empty-folder + single-bundle fallback (Task 3), CLI parity (Task 4) → all criteria mapped.
- No placeholders: adapter, prompt, decision helper, and wiring steps all concrete.
- Type consistency: `ClassificationFolderInput`, `SubfolderInclusionChoice`, `ClassificationFolderPrompt.readURLs` used identically across tasks; property names must match the real `WorkflowSidebarInputSelection` (verify before implementing).
- Virtual-bundle safety: expanded samples flow through the existing batch path that materializes each bundle (§1.7) — no `preview.fastq` reaches a classifier.
