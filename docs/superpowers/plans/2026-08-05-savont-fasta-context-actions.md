# Savont FASTA Context Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development` for each change and `superpowers:verification-before-completion` before handoff. Do not commit until the assigned task is green.

**Goal:** Make all seven shared FASTA row context actions work for one or multiple Savont rows, display BLAST results in the bottom pane, and preserve canonical provenance through every disk-backed selected-sequence workflow.

**Architecture:** Keep `FASTACollectionViewController` as the shared ordinary/Savont FASTA browser. Rebuild its context menu from the actual clicked selection, stage selected records through one provenance-aware materializer, route reference import provenance through the helper boundary, and use the established lazy `BlastResultsDrawerContainerView` ensure/open pattern below the collection split while collapsing the existing `FASTASelectionDetailView` so only one lower presentation is visible.

**Tech Stack:** Swift 6, AppKit, LungfishCore `Sequence` and BLAST services, LungfishKit menu/BLAST views, LungfishWorkflow provenance/build services, XCTest

**Implementation constraint:** Reuse the existing `lungfish-cli extract contigs` command for direct single-source FASTA/Savont reference-bundle creation. Do not add another selector CLI or a new UI surface.

## Global constraints

- Work only in `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/savont-context-actions`.
- Write a failing focused test before implementation and show the failure is for the intended missing behavior.
- Selected records always remain in current visible table order.
- BLAST accepts 1–50 selected rows; MAFFT requires 2 or more.
- No automated test contacts BLAST or another network service.
- Do not weaken or omit provenance to make an operation pass.
- Do not use `try?` or silent returns on scientific output paths.
- Workers do not commit; the Sol lead reviews and integrates only after focused and aggregate tests pass.

---

### Task 1: Dynamic context selection and per-action eligibility (Terra A)

**Files:**
- Modify: `Sources/LungfishKit/FASTASequenceActionMenuBuilder.swift`
- Modify menu/selection callback regions only: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift`
- Modify: `Tests/LungfishAppTests/FASTASequenceActionMenuBuilderTests.swift`
- Modify: `Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift`

- [ ] Add table-driven failing menu-builder tests for selection counts 0, 1, 2, and 51. Assert all actions require a selection, MAFFT requires 2, and BLAST is disabled above 50 with a useful explanation.
- [ ] Add failing controller tests invoking each of the seven menu items with one selected row and two selected rows. Assert exact record identity and visible order.
- [ ] Add failing tests for right-click targeting: clicking inside a multi-selection preserves it; clicking outside replaces it; keyboard/menu invocation with no clicked row uses the current selection.
- [ ] Add an independent `onAlignWithMAFFTRequested` callback and prove it is distinct from generic Run Operation.
- [ ] Make the controller an `NSMenuDelegate`, reconcile `clickedRow`, and rebuild the menu in `menuNeedsUpdate`.
- [ ] Implement action-specific eligibility in the menu builder without changing unrelated callers' action sets.
- [ ] Run `swift test --filter FASTASequenceActionMenuBuilderTests --filter FASTACollectionViewControllerTests`.

**Handoff:** Report tests and exact controller regions changed. Do not touch bottom-pane or host routing code.

---

### Task 2: Provenance-aware selected FASTA materialization (Terra B)

**Files:**
- Modify or split from: `Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/FASTASequenceExtractionDialog.swift`
- Modify staging/error call sites only: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/App/ReferenceImportHelper.swift`
- Modify: `Sources/LungfishApp/Services/ReferenceBundleImportHelperLauncher.swift`
- Modify: `Tests/LungfishAppTests/FASTAOperationCatalogTests.swift`
- Modify: `Tests/LungfishAppTests/ReferenceImportHelperTests.swift`
- Add focused error-presentation tests where the existing test seam permits.

- [ ] Add failing one-record and multi-record tests asserting exact normalized payload, visible order, record count, and base count.
- [ ] Add failing tests that load root `.lungfish-provenance.json` and verify output checksum/size, selected IDs/count, original durable source paths, resolved defaults, success, and nonnegative wall time.
- [ ] Add failing helper tests for repeatable provenance input arguments and forwarding to `ReferenceBundleImportService.importAsReferenceBundle(provenanceInputFiles:)`.
- [ ] Implement one atomic selected-FASTA materializer used by FASTA operation staging and extraction destinations.
- [ ] Extend helper launch/protocol parsing to forward durable provenance input paths so final reference bundles do not depend only on temporary staging.
- [ ] Replace silent staging/export/bundle errors in owned call-site regions with the existing operation failure UI or a focused alert seam.
- [ ] Run `swift test --filter FASTAOperationCatalogTests --filter ReferenceImportHelperTests` plus any new focused extraction/error tests.

**Handoff:** Report the provenance envelope fields verified and the exact `ViewerViewController` methods touched. Do not modify BLAST or MAFFT routing regions.

---

### Task 3: Reuse existing bottom-pane views for BLAST state (Sol/root)

**Files:**
- Modify bottom-pane APIs only: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift`
- Modify: `Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift`

- [ ] Add failing controller tests showing that selection uses the existing `FASTASelectionDetailView`, BLAST loading/results/failure collapse it and open the existing shared drawer below the split, and a later selection change closes the drawer and restores FASTA text at its saved height.
- [ ] Lazily retain one `BlastResultsDrawerContainerView`, following the established `ensureBlastDrawer` and animated `openBlastDrawerIfNeeded` pattern, and set its tab to `.sequenceBlast`; do not create a wrapper, selector, tab bar, nested divider, or new result view.
- [ ] Add controller presentation hooks for loading, results, and failure plus pass-through Cancel/Rerun callbacks already supported by `BlastResultsDrawerTab`.
- [ ] Re-anchor the collection split bottom to the lazily created drawer top, collapse the selected-FASTA detail while the drawer is open, and preserve its last expanded height for restoration.
- [ ] Retain BLAST state while FASTA detail is visible so the next BLAST action can reuse it, but make a row-selection change restore the normal sequence detail.
- [ ] Run `swift test --filter FASTACollectionViewControllerTests --filter BlastResultsDrawerTests`.

---

### Task 4: Host BLAST orchestration and MAFFT routing (Sol/root)

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Add or modify focused Viewer routing tests under `Tests/LungfishAppTests/`.

- [ ] Add an injectable BLAST service seam and operation-dialog presentation seam if none exists.
- [ ] Add failing tests proving BLAST success reaches the originating collection bottom pane, failure is shown, Cancel cancels the active task, Rerun repeats the last request, and stale completion cannot overwrite a later run.
- [ ] Add a failing test proving Align with MAFFT opens FASTA Operations with initial category `.alignment` and tool `.mafft` while Run Operation keeps generic defaults.
- [ ] Track the active task and UUID, map service progress to the bottom pane, and route result/failure only when the UUID is current.
- [ ] Enforce the 50-row BLAST cap at both menu availability and host validation.
- [ ] Run the new Viewer route tests and the focused bottom-pane/controller tests.

---

### Task 5: Integration, regression, and manual acceptance

**Files:**
- Modify only as required by integration findings.

- [ ] Review worker diffs for scope, test quality, concurrency correctness, error visibility, and AGENTS.md provenance compliance.
- [ ] Resolve shared-file edits deliberately; do not overwrite either worker's tests or seams.
- [ ] Run:

```bash
swift test \
  --filter FASTACollectionViewControllerTests \
  --filter FASTASequenceActionMenuBuilderTests \
  --filter FASTAOperationCatalogTests \
  --filter ReferenceImportHelperTests \
  --filter BlastResultsDrawerTests
```

- [ ] Run the broader Lungfish app test target or full `swift test` as time permits, and record any unrelated pre-existing failure separately.
- [ ] Build the debug app.
- [ ] On a real Savont output, exercise each action with one and two selected rows; verify clicked-row selection behavior, BLAST results in the bottom pane, MAFFT preselection, exported/extracted payloads, bundle creation, and provenance sidecars.
- [ ] Inspect staged and durable provenance for original source linkage, checksums, sizes, resolved options, exit status, and wall time.
- [ ] Commit only after all owned focused tests and integration tests are green.

---

### Task 6: Independent-review blockers — durable collection scope and replayable final provenance

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift`
- Modify helper/import provenance APIs only as needed.
- Modify focused Viewer, catalog, helper, and reference-import tests.

- [ ] Add a failing integration test that opens a multi-sequence document while previous viewer state names another source, then proves collection actions use the newly opened document only.
- [ ] Capture durable source URLs at collection display and retain them through drill-down/back navigation; stop deriving collection action provenance from mutable global viewer state.
- [ ] Add failing provenance tests requiring replay argv to name durable source(s) and selected identifier(s).
- [ ] Add a failing end-to-end test that creates a final `.lungfishref`, removes staging, reloads canonical provenance, and proves durable inputs, selected IDs/count, checksums/sizes, and the materialization replay step remain.
- [ ] Rehydrate the selection materialization provenance through the helper/import boundary with the smallest existing-compatible API extension.
- [ ] Route annotated extraction through the same canonical selected-FASTA materializer before annotation attachment.
- [ ] Run the focused source-state, materializer, helper, annotation, and final-bundle provenance tests.

### Task 7: Independent-review blockers — cancellation, naming, and temporary lifecycle

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+ImportCenter.swift`
- Modify selected-FASTA lifecycle code and focused tests.

- [ ] Add a failing BLAST routing test proving explicit Cancel closes the drawer and restores selected FASTA detail.
- [ ] Implement Cancel restoration using the existing detail/drawer views; add no new interface.
- [ ] Add a failing reference-creation test proving `suggestedName` reaches the final preferred bundle name.
- [ ] Forward the preferred name through the existing helper/import path.
- [ ] Add failing lifecycle tests for success and failure of Share, Create Bundle, MAFFT, and generic operation staging.
- [ ] Use the existing project temporary-storage lifecycle so roots stay valid for asynchronous consumers, then become safely removable rather than remaining active.
- [ ] Rerun the aggregate suite, debug build, `git diff --check`, and a final self-review against every independent finding before handoff.
