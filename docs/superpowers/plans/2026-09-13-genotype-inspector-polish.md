# Genotyping Inspector Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking. User already authorized execution; do not request another design approval.

**Goal:** Deliver a concise, accessible five-tab genotyping Inspector, a MiSeq matrix without a bottom pane, and editable one-way Excel exports.

**Architecture:** Make worksheet editability a renderer presentation change. Centralize bottom-pane visibility around existing workflow identity and viewport state. Reuse native adaptive Inspector presentation patterns while preserving callbacks and data sources; confine broader shared-view changes to genotype context where needed.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest/ViewInspector, embedded Python/openpyxl renderer.

**Spec:** `docs/superpowers/specs/2026-09-13-genotype-inspector-polish-design.md`

## Global Constraints

- Local Debug only. No merge, push, tag, release, cleanup, or other worktree changes.
- Work only in `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/genotype-inspector-polish`, branch `codex/genotype-inspector-polish`, base `3fc2179b8361069d103c40d85aa944c2ba44c7fd`.
- Preserve all scientific QA reports, task ledger, review packages, test logs, and existing caches.
- No inference algorithm, scientific data semantics, or provenance schema changes.
- Every scientific output workflow retains reproducibility provenance: tool/workflow version, exact invocation, resolved options/defaults, runtime, input and final output paths/checksums/sizes, exit status, wall time, useful stderr. Existing export snapshot capture and provenance writing remain authoritative.
- Scope the change to `appliesToHaplotypedMiSeq` plus active Summary / Matrix. The user's clarification expressly preserves the Haplotype Calls editor and excludes the other genotype-only/manual-workbench presentations from this cleanup. No new editor sheet or relocated manual editing UI.
- Do not hide evidence in ONT/general genotype-only or non-matrix views. Do not stop publishing selection to the Inspector when its bottom pane is hidden.
- No parallel Swift compiles. Root baseline must pass before source/test edits. PM assigns one implementation at a time; each implementer owns focused test runs while active. Root owns final packaging.
- Use apply_patch for edits. Implementers do not dispatch subagents. Commit only task files and retain detailed reports in the supplied SDD workspace.

---

### Task 1: Editable workbook presentation

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeWorkbookSnapshot+Script.swift`
- Test: `Tests/LungfishIOTests/GenotypeWorkbookSnapshotTests.swift`

**Interfaces:**
- Consumes: existing `GenotypeWorkbookSnapshot` literal snapshot and renderer payload.
- Produces: unchanged sheet schemas/content, with every worksheet/cell editable. No public Swift interface changes.

- [ ] Extend the existing renderer inspection/assertions to require every worksheet unprotected and populated cells unlocked, including the comment-bearing fixture and absent-content/no-haplotype variant. Replace the current `readOnlyComments` expectation without dropping comment/author assertions. Include actual edit/save/reload evidence in the renderer inspection if the existing helper can express it cleanly.

```python
editable_sheets = all(not sheet.protection.sheet for sheet in workbook.worksheets)
editable_cells = all(not cell.protection.locked for sheet in workbook.worksheets
                     for row in sheet.iter_rows() for cell in row)
```

- [ ] Run `swift test --jobs 4 --skip-update --filter GenotypeWorkbookSnapshotTests` and record the expected editability failure before production changes.
- [ ] In `_finish_sheet`, preserve alignment/header formatting, explicitly unlock cells and remove active sheet/object protection. The essential cell assignment is `cell.protection = Protection(locked=False)`; `sheet.protection.sheet = False` must apply to every generated sheet. Do not change snapshot content, filters, sheet count, formula policy, or provenance.
- [ ] Run the focused suite green. Existing calls/colors/filters/annotations/literal/no-import/provenance assertions must remain. Record test output and self-review in the report.
- [ ] Commit only the two task files with `fix: make genotype Excel worksheets editable`.

### Task 2: MiSeq matrix visibility and native export dialog

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify if the policy is the smallest coherent owner: `Sources/LungfishGenotypeUI/GenotypeResultPresentationPolicy.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportStylingAndMiSeqE2ETests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportArtifactsAndOutlineTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeExcelDialogBehaviorTests.swift`
- Test if policy changes: existing presentation-policy tests found beside these tests.

**Interfaces:**
- Consumes: existing `appliesToHaplotypedMiSeq` presentation policy, `summaryViewMode`, selected lens/evidence/bare-selection state.
- Produces: one authoritative visibility decision at every existing detail-pane update ingress; unchanged published selection and sample-sheet notification. Save panel export completion/capture interfaces stay unchanged.

- [ ] Add/adjust fixture-based tests before production changes: paired haplotyped MiSeq matrix has hidden detail pane initially, after sample/row/cell/allele selection, after clearing, after annotation/display refresh. Haplotype Calls detail/editor returns correctly. Typed genotype-only MiSeq, ONT and general genotype-only remain unchanged; retain `testSelectedFASTARowWithNothingToDetailHidesThePane`'s generic reopen behavior. The existing presentation policy must remain the boundary rather than broadening workflow identity.

```swift
XCTAssertTrue(controller.testingDetailPaneHidden)
// Continue existing selection fixture actions, then repeat the visibility
// assertion and verify testingCurrentSelectionDetailRows still carries identity.
```

- [ ] Add save-panel assertion `XCTAssertNil(panel.accessoryView)` through the existing injected panel presenter; preserve normal extension/name/owner window and cancellation behavior. Run focused tests red with `swift test --jobs 4 --skip-update --filter 'GenotypeResultViewportLayoutTests|GenotypeExcelDialogBehaviorTests'` and the exact containing class of each new test.
- [ ] Centralize matrix suppression and combine it with existing bare-selection/review rules. The matrix must actually be the active summary viewport (`selectedLens == .summary` and matrix mode), not merely a stale stored matrix preference in Review/Audit. Current assignments around `applySummaryViewModeVisibility`, `setDetailPaneSuppressed`, and review updates must all respect the scoped suppression. Do not remove selection publication or call/annotation callbacks. Remove the save-panel static accessory creation only.
- [ ] Preserve Haplotype Calls detail/editor and H1/H2 operations without changing their presentation. Do not relocate genotype-only editors or add a sheet: those manual-workbench workflows are outside this pane-removal scope. Run the changed focused classes green; ensure sample selection publication and existing Edit calls routes remain usable. Record command/log/outcomes and self-review.
- [ ] Commit task files with `fix: keep MiSeq genotype matrices free of the detail pane`.

### Task 3: Consistent compact five-tab Inspector

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift`
- Modify only as required for genotype-scoped style/context: `Sources/LungfishApp/Views/Inspector/LungfishInspectorStyle.swift`, `Sources/LungfishApp/Views/Inspector/InspectorView.swift`, and existing genotype export session presentation state.
- Create a small shared adaptive genotype row helper in `Sources/LungfishGenotypeUI/` only if native `LabeledContent`/`ViewThatFits` composition cannot be reused without duplicating logic across targets.
- Tests: existing genotyping document/display/annotation and Inspector selected/provenance tests; add a focused five-tab mounted-Inspector test file in `Tests/LungfishAppTests/` if existing support is insufficient.

**Interfaces:**
- Consumes: unchanged state objects, callbacks, five-tab routing, typography scale, and export progress/error state from existing code.
- Produces: adaptive concise visual hierarchy without new scientific APIs or removed actions. Task 2 owns the NSSavePanel; do not reintroduce its accessory.

- [ ] Read the five affected tab implementations and tests. For runtime behavioral changes, first add focused assertions that expose removed static export history/prose and preserve accessible action/selection/help behavior. Avoid source-string mirror tests. Reversible layout-only changes use mounted render verification rather than implementation-shaped assertions.
- [ ] Bundle: replace awkward vertically stacked fixed/trailing 118-point labels and similar Samples rows with adaptive native label/value presentation. Keep data selectable/wrapping. Remove last-export filename/reveal/missing-file status and routine disclosure paragraph; keep one Export button with concise one-way help, explicit accessibility hint, disabled/progress and actionable failure state. Persistent success history disappears; do not remove underlying provenance/session capture.
- [ ] Selected Item: apply consistent wrapping metadata presentation. Retain title/subtitle/identity and sample-only Edit calls action; shared allele selection must not acquire sample-edit action.
- [ ] Annotations: compact routine explanation into help/AX hints while keeping selection context, FP/FN eligibility/reasons, comments/authors/timestamps, row/column/cell scope, color/styles, and clear actions. Add explicit names/state for Bold/Italic/color controls where missing.
- [ ] View: align control groups and typography with other tabs; remove duplicated routine threshold/presentation prose into help/AX hints. Preserve display filter meaning and actionable malformed/read-only warnings. Existing controls and ordering remain functional. Fix Percent Basis label compression beside wide segments: a stacked labeled control or native popup is acceptable at narrow widths while preserving exact options and semantics. No label may break into single characters because a neighboring control consumes its width.
- [ ] Provenance: use adaptive wrapping data rows, coherent typography and concise disclosure presentation while preserving summary/warnings/search and every accessible/copyable record. Avoid changing non-genotype Inspector workflows through unscoped style propagation.

```swift
// Native compact rows should retain label/value association and wrapping.
LabeledContent(label) {
    Text(value).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
}
// If horizontal content cannot fit, use a leading label-over-value fallback.
```

- [ ] Run focused tests serially using `swift test --jobs 4 --skip-update --filter` and the concrete changed test class names. Follow existing `PrimerAnalysisInspectorTests`/`PrimerAnalysisDisplaySectionTests` NSHostingView snapshot pattern to save all five tabs at 300 and 420-point widths plus enlarged text into this plan's QA directory. Use populated synthetic fixtures: a selected sample with long identity/allele values, review/comment context, and actual provenance rows rather than only empty states. Make relevant disclosure content visible, including Percent Basis in View; capture extra scroll/expanded states when needed to inspect changed controls. Restore any shared typography/settings after testing. Inspect the rendered PNGs; fix clipping/overlap/unreadable hierarchy, and record actual image paths and results. Test meaningful names/hints/values, keyboard-accessible retained controls, and exact five-tab routes. Do not claim VoiceOver runtime verification from source attributes alone.
- [ ] Record complete test/render evidence and limitations in the report. Commit only task source/tests with `refactor: simplify genotyping Inspector presentation`.

## Final handoff

PM dispatches an independent Astra whole-branch review with spec, ledger, reports, and packaged diff. Resolve review findings under SDD before handoff. Root runs final targeted verification and creates only the local Debug app, preserving the worktree and QA evidence.
