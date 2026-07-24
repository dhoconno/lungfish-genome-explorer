# Genotype Matrix Review Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add evidence-gated false-positive/false-negative genotype-cell annotations, editable row/column/cell comments, configurable analyst identity, complete audit/provenance, responsive matrix UX, and equivalent native Excel output.

**Architecture:** Extend the versioned annotation sidecar with target-keyed semantic reviews and deterministic current comments, then expose a cached immutable capability model shared by the inspector, menus, accessibility, and mutation validation. Persist every command atomically through the existing publication coordinator, render semantic layers from indexed state, and make both workbook pipelines consume exact target identities and emit equivalent review formatting, native notes, annotation worksheets, and provenance.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager, embedded Python 3/openpyxl, raw OOXML ZIP generation

## Global Constraints

- A supported genotype cell has raw `passedUniqueReads > 0`; an absent support record or `passedUniqueReads == 0` is unsupported.
- False positive is valid only when every selected target is a supported cell; false negative is valid only when every selected target is an unsupported cell. Mixed or non-cell selections fail atomically.
- Review status never changes genotype calls, read counts, filtering, or haplotype calculations.
- Each exact row, column, or cell target has at most one current editable comment; legacy duplicates resolve without rewriting on load.
- Exact cell identity is locus, genotype, sample, and stable cluster ID when present. Never match workbook rows by genotype text alone when identities can collide.
- The resolved analyst identity is captured at edit time; changing Settings affects only future edits.
- Every scientific mutation and workbook/export transformation records workflow/tool version, reproducible argv, visible options and defaults, runtime identity, final input/output paths, checksums, sizes, exit status, wall time, and useful stderr.
- Provenance must reference the final stored `annotations.json`, view projection, and workbook, never a temporary staging payload.
- Context-menu preparation performs no disk I/O or matrix-wide scans; selection aggregation is linear in selected targets; redraw is limited to affected visible targets.
- Workbook regeneration is coalesced outside the immediate interaction path; normal CI uses deterministic structural performance assertions and records representative benchmark timings without fragile sub-millisecond pass/fail limits.
- False-positive Excel values retain the count as bracketed italic text in gray no lighter than `#767676`; false-negative cells retain explicit zero, leave absent values empty, and receive a thick four-sided border.
- CSV and TSV quantitative values remain unchanged.

---

### Task 1: Sidecar v2 semantic review and current-comment model

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
- Modify: `Sources/LungfishCLI/Commands/GenotypeApplyAnnotationsSubcommand.swift`
- Test: `Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift`
- Test: `Tests/LungfishCLITests/GenotypeSubcommandsTests.swift`

**Interfaces:**
- Produces:
  - `GenotypeAnnotationSidecar.currentSchemaVersion == 2`
  - `MatrixReviewDisposition: String, Codable, CaseIterable, Equatable, Hashable, Sendable`
  - `MatrixReviewAnnotation(target: MatrixTarget, disposition: MatrixReviewDisposition, author: String, timestamp: String)`
  - `GenotypeAnnotationSidecar.matrixReviews: [MatrixReviewAnnotation]`
  - `GenotypeAnnotationSidecar.resolvedMatrixComments: [MatrixTarget: MatrixComment]`
  - `MatrixTarget.stableAuditDescription: String`
- Consumes: Existing `MatrixTarget`, `MatrixComment`, `AuditEntry`, sidecar decoder defaults, and CLI merge/provenance paths.

- [ ] **Step 1: Write failing model and migration tests**

  Add tests named:

  ```swift
  func testVersionOneSidecarDecodesWithNoMatrixReviews()
  func testVersionTwoSidecarRoundTripsStableIdentityReview()
  func testResolvedMatrixCommentsUsesLatestParseableTimestamp()
  func testResolvedMatrixCommentsUsesLastFileOrderForTiesAndUnparseableDates()
  func testStableAuditDescriptionIncludesTargetKindAndStableClusterID()
  ```

  Construct duplicate comments in file order and assert that resolving them does not mutate `matrixComments` or write to disk.

- [ ] **Step 2: Run the focused model tests and confirm the intended failures**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeAnnotationSidecarTests
  ```

  Expected: the new tests fail because schema v2, `matrixReviews`, the disposition types, and deterministic comment resolution do not exist.

- [ ] **Step 3: Implement the v2 schema and deterministic resolver**

  Add the semantic types and optional-decode migration:

  ```swift
  public enum MatrixReviewDisposition: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
      case falsePositive
      case falseNegative
  }

  public struct MatrixReviewAnnotation: Codable, Equatable, Sendable {
      public var target: MatrixTarget
      public var disposition: MatrixReviewDisposition
      public var author: String
      public var timestamp: String
  }
  ```

  Advance the schema, include `matrixReviews` in coding keys, initializers, `empty`, encode/decode, and resolve comments by target using the latest ISO-8601 timestamp with the last array element winning ties or unparseable comparisons. Do not canonicalize during decode.

- [ ] **Step 4: Write failing CLI merge tests**

  Add tests named:

  ```swift
  func testApplyAnnotationsMergesMatrixReviewsByExactTarget()
  func testApplyAnnotationsReplacesMatrixCommentsByExactTarget()
  func testApplyAnnotationsReportsReviewAndCurrentCommentCounts()
  ```

  Include two rows with the same genotype text but different locus or stable cluster ID and assert that only the exact target is replaced. Assert the produced bundle provenance still identifies the final stored sidecar.

- [ ] **Step 5: Run the CLI tests and confirm merge failures**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeSubcommandsTests
  ```

  Expected: the new review count/merge tests fail while existing annotation merge tests continue to pass.

- [ ] **Step 6: Implement exact target-keyed CLI merge semantics**

  Merge `matrixReviews` and `matrixComments` by the full `MatrixTarget`, retain one current value per target, include review/comment category counts, and preserve the existing atomic publication and provenance writer. Preserve unrelated legacy duplicate comments unless their exact target is part of the merge.

- [ ] **Step 7: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeAnnotationSidecarTests
  swift test --skip-update --filter GenotypeSubcommandsTests
  git diff --check
  ```

  Expected: all selected tests pass and `git diff --check` prints nothing.

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift Sources/LungfishCLI/Commands/GenotypeApplyAnnotationsSubcommand.swift Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift Tests/LungfishCLITests/GenotypeSubcommandsTests.swift
  git commit -m "feat: add genotype matrix review schema"
  ```

---

### Task 2: Atomic store operations, eligibility validation, audit, and provenance

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeMatrixReviewCapability.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeMatrixReviewCapabilityTests.swift`

**Interfaces:**
- Consumes: Task 1 review types, `MatrixTarget.stableAuditDescription`, `GenotypeAnnotationPublicationCoordinator`.
- Produces:
  - `GenotypeMatrixEvidenceIndex` with exact-cell `passedUniqueReads` lookup where absence is unsupported.
  - `GenotypeMatrixReviewCapability.evaluate(selection:evidence:reviews:comments:isWritable:)`
  - `GenotypeAnnotationStore.setMatrixReview(_:targets:evidence:author:) async throws`
  - `GenotypeAnnotationStore.clearMatrixReview(targets:author:) async throws`
  - `GenotypeAnnotationStore.upsertMatrixComment(body:targets:author:) async throws`
  - `GenotypeAnnotationStore.removeMatrixComments(targets:author:) async throws`

- [ ] **Step 1: Write failing capability tests**

  Cover exact cells with positive, zero, and absent evidence; all-supported and all-unsupported bulk selections; mixed evidence; row/column/mixed target shapes; current review none/uniform/mixed; comment empty/uniform/mixed; and read-only state. Assert command availability plus exact disabled-reason copy.

- [ ] **Step 2: Run capability tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeMatrixReviewCapabilityTests
  ```

  Expected: compilation fails because the capability and evidence index do not exist.

- [ ] **Step 3: Implement immutable indexed capability evaluation**

  Create value types for selection shape, support summary, uniform/mixed value state, and command availability. Build evidence/review/comment dictionaries only from supplied snapshots; `evaluate` must inspect only selected targets and must not accept URLs, stores, or matrix views.

- [ ] **Step 4: Write failing store mutation tests**

  Add tests for:

  ```swift
  func testSetFalsePositivePublishesAllSupportedCellsOnce()
  func testSetFalseNegativeTreatsAbsentEvidenceAsUnsupported()
  func testMixedEvidenceRejectsEntireMutation()
  func testEvidenceChangedBeforePublishRejectsEntireMutation()
  func testReviewReplacementAndClearAuditBeforeAndAfterValues()
  func testCommentAddEditRemoveUsesOneCurrentValuePerTarget()
  func testFirstLegacyCommentMutationCanonicalizesAndAuditsMissingHistory()
  func testReadOnlyAndStaleRevisionPublishNothing()
  func testEditTimeAuthorAppearsInAnnotationAuditAndProvenance()
  ```

  Assert one publication per command, one operation timestamp, one audit entry per affected target, full exact target identity, eligibility counts/rule in review provenance, complete old/new comment bodies, and final sidecar checksum/size.

- [ ] **Step 5: Run store tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeAnnotationStoreTests
  ```

  Expected: the new atomic review, current-comment, and edit-time author tests fail.

- [ ] **Step 6: Implement store commands through the existing publication coordinator**

  Normalize and deduplicate exact targets, validate all targets before changing the sidecar, resolve the passed author at command creation, capture before/after values, append semantic audit actions, and call the existing atomic `persist`/publication path exactly once. On stale revision, restore the latest sidecar and publish nothing. During a target's first mutation, replace all of that target's legacy comments and append `canonicalizeLegacyMatrixComments` audit entries for superseded values not already represented.

- [ ] **Step 7: Extend provenance edit contexts**

  Record the semantic action, normalized exact targets, before/after payloads, eligibility rule/counts for reviews, visible options/resolved defaults, resolved author, final input/output paths/checksums/sizes, exit status, wall time, runtime identity, and useful error context using the existing provenance builder.

- [ ] **Step 8: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeMatrixReviewCapabilityTests
  swift test --skip-update --filter GenotypeAnnotationStoreTests
  git diff --check
  ```

  Expected: all selected tests pass and every mutation test observes one atomic publication.

- [ ] **Step 9: Commit**

  ```bash
  git add Sources/LungfishGenotypeUI/GenotypeMatrixReviewCapability.swift Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift Tests/LungfishGenotypeUITests/GenotypeMatrixReviewCapabilityTests.swift Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift
  git commit -m "feat: persist audited matrix reviews and comments"
  ```

---

### Task 3: Global analyst identity and inspector routing

**Files:**
- Modify: `Sources/LungfishCore/Models/AppSettings.swift`
- Modify: `Sources/LungfishApp/Views/Settings/GeneralSettingsTab.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorView.swift`
- Modify: `Sources/LungfishApp/Controllers/InspectorViewController+PublicAPI.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishCoreTests/AppSettingsTests.swift`
- Test: `Tests/LungfishAppTests/SettingsAndImportXCUIReadinessTests.swift`

**Interfaces:**
- Consumes: Task 2 store methods accepting an edit-time author.
- Produces:
  - `AppSettings.analystIdentityOverride: String`
  - `AppSettings.resolvedAnalystIdentity(fallback: @autoclosure () -> String = NSUserName()) -> String`
  - Inspector presentation `Saving as: <identity>` and an app-layer callback that opens the General Settings pane.

- [ ] **Step 1: Write failing settings tests**

  Add tests that assert default and empty/whitespace overrides use a supplied fallback, a non-empty override is trimmed and round-trips through the settings snapshot, reset clears it, and two store edits before/after a setting change retain their respective authors.

- [ ] **Step 2: Run the settings tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter AppSettingsTests
  ```

  Expected: the analyst identity properties are missing.

- [ ] **Step 3: Implement persisted resolved identity**

  Add the override to `AppSettings.Snapshot`, backward-compatible decode defaults, `makeSnapshot`, `apply`, save, and general-reset behavior. Trim only when resolving/saving and preserve `NSUserName()` as the default fallback.

- [ ] **Step 4: Write failing app readiness tests**

  Assert the General Settings text field, annotation inspector identity label, and Settings link have stable accessibility identifiers and that production store construction no longer passes `NSUserName()` directly.

- [ ] **Step 5: Run app tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter SettingsAndImportXCUIReadinessTests
  ```

  Expected: accessibility and source-readiness assertions fail.

- [ ] **Step 6: Add Settings and app-layer inspector wiring**

  Add a labeled Analyst identity text field with explanatory fallback copy and save-on-change behavior. Pass resolved identity from the app/controller boundary to edit commands, expose it read-only in the inspector, and route the Settings link through the existing settings-window API without adding a LungfishApp dependency to LungfishGenotypeUI.

- [ ] **Step 7: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter AppSettingsTests
  swift test --skip-update --filter SettingsAndImportXCUIReadinessTests
  rg 'NSUserName\\(\\)' Sources/LungfishGenotypeUI Sources/LungfishApp/Controllers
  git diff --check
  ```

  Expected: tests pass; any remaining direct `NSUserName()` reference is only the approved fallback helper, not store construction.

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/LungfishCore/Models/AppSettings.swift Sources/LungfishApp/Views/Settings/GeneralSettingsTab.swift Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift Sources/LungfishApp/Views/Inspector/InspectorView.swift Sources/LungfishApp/Controllers/InspectorViewController+PublicAPI.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishCoreTests/AppSettingsTests.swift Tests/LungfishAppTests/SettingsAndImportXCUIReadinessTests.swift
  git commit -m "feat: add configurable analyst identity"
  ```

---

### Task 4: Controller command state, exact support indexing, and coalesced publication refresh

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 models, capability evaluator, store commands, and resolved analyst identity.
- Produces:
  - `GenotypeMatrixReviewRequest`
  - `GenotypeMatrixCommentEditRequest` with upsert/remove/replace intent and exact targets
  - View-model capability state shared by inspector, context menu, keyboard actions, and accessibility
  - A raw result-evidence index independent of filtering and display thresholds
  - A real coalescing current-workbook update scheduler

- [ ] **Step 1: Write failing controller/capability tests**

  Add tests proving hidden/filtered cells and display thresholds do not change eligibility; absent records enable false negative; a mixed selection stays all-or-none; inspector and menu consume equal capability values; and evidence is revalidated immediately before store publication.

- [ ] **Step 2: Run viewport/store tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeResultViewportTests
  swift test --skip-update --filter GenotypeAnnotationStoreTests
  ```

  Expected: new command-state and raw-evidence tests fail.

- [ ] **Step 3: Implement exact raw evidence and sidecar indexes**

  Build support from the unfiltered genotype result using full cell identity. Rebuild support only on result replacement and review/comment dictionaries only on sidecar revision. Selection changes aggregate selected targets without scanning rows, columns, the sidecar array, or disk.

- [ ] **Step 4: Implement semantic controller request routing**

  Replace append-only `GenotypeMatrixCommentRequest` behavior with exact upsert/remove/bulk-replace requests. Route review and comment commands through the Task 2 store methods, surface stale/read-only/invalid-selection errors, and reload only affected visible row/header/cell targets after a successful publication.

- [ ] **Step 5: Write failing workbook coalescing tests**

  Add a deterministic scheduler spy asserting that a burst of successful review/comment commands creates one delayed current-workbook update; a failed sidecar publication schedules none; and an update failure retains the successful sidecar plus an actionable retry warning.

- [ ] **Step 6: Implement real coalescing**

  Replace the current cancel-only `scheduleCurrentWorkbookUpdateForMatrixAnnotation()` behavior with a cancellable delay that invokes the existing workbook update path after the final successful mutation. Keep workbook generation off the menu/command path and preserve the previous valid workbook on failure.

- [ ] **Step 7: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeResultViewportTests
  swift test --skip-update --filter GenotypeAnnotationStoreTests
  git diff --check
  ```

  Expected: all tests pass, selection changes do not rebuild indexes, and coalescing tests observe one workbook update.

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift
  git commit -m "feat: route matrix review commands through cached state"
  ```

---

### Task 5: Matrix rendering, context menus, accessibility, and performance structure

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces:**
- Consumes: Task 4 indexed capability and command callbacks.
- Produces:
  - False-positive `[count]` secondary italic rendering
  - False-negative thick inner frame with `0`/em-dash distinction
  - Native-scope folded-corner comment markers
  - Accent selection corner brackets and compact legend
  - Right-click and keyboard actions driven by cached capability state
  - VoiceOver descriptions with evidence, review, selection, and comment-scope counts

- [ ] **Step 1: Write failing semantic rendering tests**

  Add render-state tests for FP bracketed count/italic/secondary color, FN explicit zero vs absent em dash, independent inner/decorative/selection layers, comment markers at only their native row/header/cell scopes, support/highlight/none modes, increased-contrast geometry, and FP/FN coexisting with comments.

- [ ] **Step 2: Run viewport tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeResultViewportTests
  ```

  Expected: new semantic layer and comment-marker assertions fail.

- [ ] **Step 3: Implement indexed semantic rendering**

  Resolve each visible cell via dictionary lookup, format FP text without altering the underlying read count, display FN absent support as an em dash only in the viewport, and draw the semantic inner frame separately from analyst border and selection corner brackets. Use dynamic AppKit colors and increase geometry under `accessibilityDisplayShouldIncreaseContrast`.

- [ ] **Step 4: Write failing command/menu/accessibility tests**

  Cover right-click inside a multi-selection preserving it, outside selecting the clicked target, row/column scoped comment actions, optional support-selection helpers, equal inspector/menu disabled reasons, stable keyboard command state, legend visibility, and complete accessibility descriptions. Add spies proving menu creation performs zero file accesses and no support-index rebuild.

- [ ] **Step 5: Implement context menus, legend, tooltips, and accessibility**

  Construct menus only from the immutable capability snapshot. Cache stable ordered comment tooltip strings as Allele Row, Sample Column, Cell. Use native tooltips without per-cell tracking areas. Make folded-corner markers non-focusable and include their meaning in the containing cell/header accessibility label.

- [ ] **Step 6: Add deterministic targeted-redraw assertions and benchmark harness**

  Extend existing DEBUG reload counters to assert review/comment edits do not call full table reload and selection does not rebuild evidence indexes. Add a representative benchmark test helper that records small/large selection aggregation, menu construction, visible redraw, and bulk sidecar mutation timing without using those timings as fragile ordinary-CI pass/fail gates; assert menu construction has no I/O and target count is linear.

- [ ] **Step 7: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeResultViewportTests
  git diff --check
  ```

  Expected: rendering, menu parity, accessibility, no-I/O, cached-index, and targeted-redraw tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
  git commit -m "feat: render accessible matrix review annotations"
  ```

---

### Task 6: Annotation inspector review controls and scoped comment cards

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5 capability, identity, and semantic command callbacks.
- Produces: Review Annotation group, Appearance disclosure, separate Cell/Allele Row/Sample Column comment cards, and explicit bulk replace behavior.

- [ ] **Step 1: Write failing inspector view-model tests**

  Cover selection target count/type, all-supported/all-unsupported/mixed copy, false-positive/false-negative/clear enablement, read-only reason, current review none/uniform/mixed, `Saving as`, and Settings link callback.

- [ ] **Step 2: Write failing scoped comment tests**

  Cover distinct Cell/Allele Row/Sample Column bodies and metadata; empty Add Comment; populated Save Changes/Remove Comment; bulk empty/uniform/mixed state; and required explicit `Replace Comments on N Targets` intent for mixed or existing values.

- [ ] **Step 3: Run inspector tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeResultDisplaySectionTests
  swift test --skip-update --filter GenotypeResultViewportTests
  ```

  Expected: review controls and scoped comment-card tests fail.

- [ ] **Step 4: Implement the inspector hierarchy**

  Put Review Annotation first, with evidence summary, mutually exclusive semantic actions, clear action, and disabled reason. Render Cell, Allele Row, and Sample Column as separate cards with current body, author, and timestamp. Put existing generic palette/font/border controls under an Appearance disclosure without changing their behavior.

- [ ] **Step 5: Wire add/edit/remove/replace actions and identifiers**

  Emit exact request intents instead of silently replacing mixed values. Add stable accessibility identifiers to review buttons, comment scope cards, bulk replace/remove controls, identity label, Settings link, and Appearance disclosure.

- [ ] **Step 6: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeResultDisplaySectionTests
  swift test --skip-update --filter GenotypeResultViewportTests
  git diff --check
  ```

  Expected: inspector and viewport tests pass with distinct comment scopes and shared command state.

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
  git commit -m "feat: add scoped review annotation inspector"
  ```

---

### Task 7: Current workbook semantic formatting and native notes

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

**Interfaces:**
- Consumes: Sidecar v2 exact targets, resolved current comments, stored sidecar provenance.
- Produces: `current.xlsx` with review formatting, combined native notes, review rows, invalid-record reporting, semantic audit rows, and final workbook provenance.

- [ ] **Step 1: Write failing current-workbook tests**

  Generate fixtures with same genotype labels at different loci/stable IDs and assert:

  ```text
  false positive -> "[42]", italic, font color >= #767676 contrast floor
  false negative explicit zero -> value 0 plus thick border on all sides
  false negative absent -> empty value plus thick border on all sides
  ```

  Also assert an exact annotation does not leak to the colliding row.

- [ ] **Step 2: Write failing native-note and worksheet tests**

  Assert row comments attach to allele labels, column comments to headers, cell comments to intersections, overlapping scopes form one note in Allele Row → Sample Column → Cell order with body/author/timestamp, existing unrelated notes survive, Matrix Annotations includes all review identity fields, and semantic audit actions appear in Audit Log.

- [ ] **Step 3: Write failing invalid-review and provenance tests**

  Insert malformed imported reviews that violate support rules. Assert they remain listed as invalid in Matrix Annotations/Audit Log but do not apply formatting. Assert workbook provenance identifies the final stored `annotations.json` input and final stored workbook output with checksums and sizes.

- [ ] **Step 4: Run workflow tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeWorkbookRevisionServiceTests
  ```

  Expected: review formatting, exact identity, combined-note, invalid-record, and provenance assertions fail.

- [ ] **Step 5: Extend the embedded openpyxl transformation**

  Parse stable ID/locus/sample/genotype from targets, map workbook rows by every available identity component, validate review eligibility against raw workbook evidence, and separate valid/invalid review maps. Apply FP text/font and FN border while preserving empty/zero semantics. Resolve one current comment per target and compose one native note per destination cell with labeled ordered sections without deleting unrelated native notes.

- [ ] **Step 6: Extend annotation/audit worksheets and provenance**

  Write review target kind, locus, genotype, sample, stable cluster ID, disposition, validation status/reason, author, and timestamp. Preserve full semantic audit details. Continue atomic workbook replacement and include the final stored sidecar as an input and final stored workbook as the output.

- [ ] **Step 7: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeWorkbookRevisionServiceTests
  git diff --check
  ```

  Expected: all current-workbook tests pass, including identity collision and invalid review fixtures.

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
  git commit -m "feat: export matrix reviews to current workbook"
  ```

---

### Task 8: View-projection identity and raw OOXML native annotations

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeViewProjection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeViewportExportService.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift`
- Modify: `Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift`
- Test: `Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift`
- Test: `Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift`

**Interfaces:**
- Consumes: Task 1 exact identities and Task 7 Excel semantics.
- Produces:
  - Optional `stableClusterID` in projection rows with legacy JSON decode compatibility
  - Raw OOXML comments parts, VML anchors, sheet relationships, and content types
  - Equivalent full/viewport XLSX review formatting, note composition, worksheets, and provenance

- [ ] **Step 1: Write failing projection identity tests**

  Assert matrix export snapshots retain optional stable cluster ID through serialization, legacy projection JSON without the field still decodes, filtered projections preserve it, and two identical genotype labels at different loci/stable IDs remain distinguishable.

- [ ] **Step 2: Write failing raw OOXML formatting tests**

  Inspect unzipped XML and shared strings/styles to assert FP `[42]` with italic accessible gray, FN thick four-side borders on zero and empty cells, no change to CSV/TSV values, and no identity collision.

- [ ] **Step 3: Write failing native-note package tests**

  Assert generated XLSX contains the required comments XML, authors/comment list, VML drawing with cell anchors, worksheet legacyDrawing, relationship files, and content-type entries. Assert row/column/cell scopes combine once in stable order and coexist with FP/FN formatting.

- [ ] **Step 4: Write failing annotation/audit/provenance tests**

  Assert Matrix Annotations and Audit Log contain semantic review/comment data and exact identities. Assert explicit export provenance contains the durable view-projection sidecar, final stored annotation sidecar, and final XLSX path/checksum/size.

- [ ] **Step 5: Run CLI and app export tests and confirm failure**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeExportSubcommandTests
  swift test --skip-update --filter GenotypeViewportExcelExportTests
  ```

  Expected: projection identity, semantic formatting, native-note package, and provenance assertions fail.

- [ ] **Step 6: Propagate optional stable identity end-to-end**

  Add `stableClusterID: String?` to `GenotypeViewProjection.Row` and `GenotypeViewportExportRow`, emit it from `GenotypeComparisonMatrixView.exportSnapshot`, preserve it in serializers and `filterProjection`, and keep decoding older projection JSON by defaulting the field to nil.

- [ ] **Step 7: Implement equivalent raw OOXML semantic formatting**

  Resolve exact rows/cells using locus/genotype/sample/stable ID. Allocate distinct FP/FN styles without changing underlying sidecar data. Emit empty FN cells so their border exists. Keep full-workbook and view-projection code paths semantically identical.

- [ ] **Step 8: Implement native Excel note package parts**

  For each affected worksheet, emit comments XML with a deduplicated authors list and comment list, VML note shapes with row/column anchors, sheet relationships, worksheet `legacyDrawing`, and content-type overrides/defaults. Compose applicable scopes in Allele Row, Sample Column, Cell order and preserve one note per cell.

- [ ] **Step 9: Extend annotation/audit worksheets and export provenance**

  Emit review identity/disposition/author/timestamp/validation state and semantic audit entries. Ensure the export reads the final stored annotation sidecar and writes provenance only after the final XLSX and durable projection exist with checksums and sizes.

- [ ] **Step 10: Run task verification**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeExportSubcommandTests
  swift test --skip-update --filter GenotypeViewportExcelExportTests
  git diff --check
  ```

  Expected: all CLI/app export tests pass, including raw OOXML relationships and identity collisions.

- [ ] **Step 11: Commit**

  ```bash
  git add Sources/LungfishIO/Bundles/GenotypeViewProjection.swift Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift Sources/LungfishGenotypeUI/GenotypeViewportExportService.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishCLI/Commands/GenotypeExportSubcommand.swift Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift
  git commit -m "feat: export native matrix review annotations"
  ```

---

### Task 9: Integrated acceptance, performance evidence, and provenance audit

**Files:**
- Create: `docs/verification/2026-07-24-genotype-matrix-review-annotations.md`
- Modify if defects are found: files and tests from Tasks 1–8 only

**Interfaces:**
- Consumes: Complete branch implementation.
- Produces: Reproducible verification report with test output summaries, benchmark observations, provenance inspection, and acceptance traceability.

- [ ] **Step 1: Run focused acceptance suites**

  Run:

  ```bash
  swift test --skip-update --filter GenotypeAnnotationSidecarTests
  swift test --skip-update --filter GenotypeMatrixReviewCapabilityTests
  swift test --skip-update --filter GenotypeAnnotationStoreTests
  swift test --skip-update --filter GenotypeResultViewportTests
  swift test --skip-update --filter GenotypeResultDisplaySectionTests
  swift test --skip-update --filter AppSettingsTests
  swift test --skip-update --filter SettingsAndImportXCUIReadinessTests
  swift test --skip-update --filter GenotypeWorkbookRevisionServiceTests
  swift test --skip-update --filter GenotypeExportSubcommandTests
  swift test --skip-update --filter GenotypeViewportExcelExportTests
  ```

  Expected: every selected suite passes with zero failures.

- [ ] **Step 2: Run the full test suite**

  Run:

  ```bash
  swift test --skip-update
  ```

  Expected: the package builds and the full suite completes with zero failures.

- [ ] **Step 3: Record representative performance evidence**

  Run the benchmark helper added in Task 5 using the existing large genotype viewport fixture. Record selection aggregation for small/large sets, menu preparation against the 50 ms product target, visible redraw behavior, and large bulk publication timing/allocation observations. Verify structural counters show no file I/O during menus, no index rebuild on selection, no full reload on targeted edit, and one coalesced workbook update.

- [ ] **Step 4: Inspect produced bundle and workbook provenance**

  For one review mutation, one comment edit, current-workbook regeneration, and explicit viewport export, record the exact audit action/target/before/after/author/timestamp and provenance workflow/version/argv/options/defaults/runtime/input-output paths/checksums/sizes/exit status/wall time. Confirm the paths identify final stored payloads rather than staging files.

- [ ] **Step 5: Write the verification report**

  Create the report with:

  ```markdown
  # Genotype Matrix Review Annotations Verification

  ## Test Results
  ## Eligibility and Atomicity
  ## Matrix UX and Accessibility
  ## Current Workbook
  ## Explicit Viewport Export
  ## Audit and Provenance
  ## Performance Observations
  ## Acceptance-Criteria Traceability
  ```

  Include commands, dates, fixture sizes, pass/fail counts, benchmark observations, and any limitations. Do not claim a criterion without recorded evidence.

- [ ] **Step 6: Run final hygiene checks**

  Run:

  ```bash
  git diff --check
  rg -n 'TBD|TODO|FIXME|implement later|placeholder' docs/verification/2026-07-24-genotype-matrix-review-annotations.md Sources Tests
  git status --short
  ```

  Expected: `git diff --check` is empty, the scan finds no feature placeholders, and status lists only the intended verification report before commit.

- [ ] **Step 7: Commit**

  ```bash
  git add docs/verification/2026-07-24-genotype-matrix-review-annotations.md
  git commit -m "docs: verify genotype matrix review annotations"
  ```
