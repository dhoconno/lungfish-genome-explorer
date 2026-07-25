# Genotype View Accessibility and Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task by task.
> Every task uses test-driven development and receives an independent spec
> review followed by an independent code-quality review before the next task.

**Goal:** Deliver editable and responsive genotype matrix filters, correct
sample/allele search and row selection, selection-aware row/column visibility,
genotype-only cohort capability handling, and app-wide scalable primary
list/detail typography.

**Architecture:** Persist a System-or-custom content-size preference in Core and
resolve semantic fonts and adaptive table geometry in LungfishKit. Split the
genotype matrix into an immutable base projection plus cheap derived visibility,
build one invalidatable search index for all genotype lenses, and model manual
row/column visibility with stable include/exclude identities. Keep all changes
as view state and preserve the existing annotation and scientific provenance
paths unchanged.

**Tech stack:** Swift 6, AppKit, SwiftUI, Observation, Swift concurrency,
XCTest, Swift Package Manager.

## Global constraints

- This feature does not mutate genotype calls, scientific input, annotations,
  or workbook content.
- No visibility, search, threshold, or text-size action adds an annotation
  audit entry.
- Existing comment and false-positive/false-negative behavior remains
  unchanged.
- Primary content fonts never resolve below 10 points and remain usable through
  200 percent.
- Sequence/base-coordinate canvas text remains controlled by scientific zoom.
- Matrix selection, scroll position, sorting, column order, and column widths
  survive filter and text-size changes.
- Search/support filters apply to the visible matrix; only visibility actions
  use the current selection.
- Manual visibility state is stable-ID based and local to one open controller.
- Deterministic operation counts are release gates; wall-clock measurements are
  representative benchmarks with documented budgets, not the sole correctness
  assertion.
- Every new user-visible control receives an accessibility label and stable test
  identifier.

---

## Task 1: Content-size preference and shared semantic typography

**Files**

- Modify: `Sources/LungfishCore/Models/AppSettings.swift`
- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Create: `Sources/LungfishKit/ContentTypography.swift`
- Create: `Sources/LungfishKit/ContentTypographySwiftUI.swift`
- Create: `Sources/LungfishKit/AccessibilityAnnouncementPoster.swift`
- Modify: `Tests/LungfishCoreTests/AppSettingsTests.swift`
- Create: `Tests/LungfishKitTests/ContentTypographyTests.swift`

**Interfaces**

- `ContentTextSizePreference`: `.system` or a custom supported percentage.
- `AppSettings.contentTextSizePreference`.
- `.contentTextSizeDidChange`.
- `ContentTypography`: semantic roles, resolved AppKit font, table/header row
  height, next larger/smaller preference, and a 10-point floor.
- A SwiftUI environment/modifier bridge backed by the same semantic roles.
- Injectable preferred-font provider and accessibility-announcement poster.
- A runtime monitor that re-resolves System-mode font signatures on application
  activation and posts `.contentTextSizeDidChange` only when the signature
  changed.

- [ ] Add failing persistence/migration/reset/clamp tests. Old AppSettings JSON
  must decode to `.system`; malformed percentages normalize to a supported
  stop.
- [ ] Add failing typography tests for System/custom resolution, weight and
  monospaced preservation, 10-point floor, 90/100/125/150/175/200 stops,
  adaptive row heights, SwiftUI live updates, noncompounding behavior, and
  larger/smaller boundary behavior. System + Larger becomes 125 percent;
  System + Smaller becomes 90 percent; Default restores System.
- [ ] Add failing tests with an injectable preferred-font provider proving that
  app reactivation in System mode emits one update only when the resolved font
  signature changes.
- [ ] Run:

  ```bash
  swift test --skip-update --filter 'AppSettingsTests|ContentTypographyTests'
  ```

  Confirm RED for the missing model/resolver.
- [ ] Implement Codable preference migration in the AppSettings snapshot,
  include it in Appearance reset, and post the narrow notification only when
  the normalized preference changes.
- [ ] Implement the MainActor AppKit resolver and SwiftUI bridge in LungfishKit
  from semantic preferred/system font baselines. Do not inspect undocumented
  UserDefaults. Add the activation monitor and deterministic injectable
  announcement poster.
- [ ] Re-run the focused tests and `git diff --check`.
- [ ] Commit: `feat: add scalable content typography`

---

## Task 2: Appearance settings, View menu, and responder actions

**Files**

- Modify: `Sources/LungfishApp/Views/Settings/AppearanceSettingsTab.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+MenuActions.swift`
- Modify: `Tests/LungfishAppTests/SettingsAndImportXCUIReadinessTests.swift`
- Modify or create: `Tests/LungfishAppTests/MainMenuStructureTests.swift`

**Interfaces**

- Appearance setting: System plus the six custom percentages.
- View submenu: Larger (`⌥⌘+`), Smaller (`⌥⌘−`), Default (`⌥⌘0`).
- Menu actions update AppSettings, save once, announce the resulting value, and
  validate disabled state at bounds.

- [ ] Write failing source/structure and action tests for labels, shortcuts,
  accessibility IDs, persistence, bounds, and reset.
- [ ] Run focused tests and confirm RED.
- [ ] Add the Appearance picker/control and menu submenu without changing the
  existing scientific Zoom commands.
- [ ] Route commands through AppDelegate to the shared preference and post an
  accessibility announcement with `System` or the percentage.
- [ ] Run focused tests plus `git diff --check`.
- [ ] Commit: `feat: expose content text size controls`

---

## Task 3: Shared and non-genotype primary list/detail adoption

**Files**

- Modify: `Sources/LungfishKit/BatchTableView.swift`
- Modify: `Sources/LungfishKit/MetadataColumnController.swift`
- Modify primary result content in:
  - `Sources/LungfishAlignmentUI/AlignmentResultViewController.swift`
  - `Sources/LungfishAssemblyUI/AssemblyContigDetailPane.swift`
  - `Sources/LungfishAssemblyUI/AssemblyContigTableView.swift`
  - `Sources/LungfishAssemblyUI/AssemblyResultViewController.swift`
  - `Sources/LungfishAssemblyUI/AssemblySummaryStrip.swift`
  - `Sources/LungfishEsVirituUI/BatchEsVirituTableView.swift`
  - `Sources/LungfishEsVirituUI/EsVirituDetailPane.swift`
  - `Sources/LungfishEsVirituUI/EsVirituResultViewController.swift`
  - `Sources/LungfishEsVirituUI/ViralDetectionTableView.swift`
  - `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift`
  - `Sources/LungfishNaoMgsUI/NaoMgsResultViewController+ResultViewport.swift`
  - `Sources/LungfishNvdUI/NvdResultViewController.swift`
  - `Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift`
  - `Sources/LungfishTaxTriageUI/BatchTaxTriageTableView.swift`
  - `Sources/LungfishTaxTriageUI/StrainComparisonView.swift`
  - `Sources/LungfishTaxTriageUI/TaxTriageBatchOverviewView.swift`
  - `Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift`
  - `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift`
  - `Sources/LungfishTwelveSUI/TwelveSTargetTableView.swift`
  - `Sources/LungfishTwelveSUI/TwelveSUnresolvedTableView.swift`
- Modify relevant tests in `Tests/LungfishKitTests` and each leaf UI test target.

**Behavior**

- Shared tables update search/cell/header fonts and row/header heights live.
- Subclass font overrides are semantic roles or are rescaled from a recorded
  base font; repeated notifications never compound the scale.
- Primary result labels/detail text update live and wrap or expand where needed.
- Scientific renderers based on pixels-per-base, phylogenetic geometry, tape
  geometry, or sequence zoom remain unchanged unless they are ordinary
  list/detail text.

- [ ] Add failing shared-table tests for live 100→200→100 transitions,
  noncompounding fonts, metadata cells, row-height recovery, and preserved
  selection/sort.
- [ ] Create a checked-in test coverage inventory that classifies every fixed
  font in the listed result modules as primary content (adopt now), control
  chrome, or zoom/geometry-driven scientific rendering (explicit exclusion).
- [ ] Add a 100→200→100 live-update and geometry assertion for every primary
  surface, using a shared-path proof only when a leaf supplies no font override;
  add an explicit leaf test whenever it does.
- [ ] Implement notification observation with deterministic teardown and a
  reusable `applyContentTypography()` hook.
- [ ] Replace primary fixed list/detail fonts with semantic resolver calls and
  make fixed-height detail regions adaptive.
- [ ] Execute and review this task in three independently reviewed commits:
  (a) shared `BatchTableView`/metadata adoption, (b) Alignment/Assembly/
  Phylogenetics/12S, and (c) EsViritu/NAO-MGS/NVD/TaxTriage. Run after each:

  ```bash
  swift test --skip-update --filter 'ContentTypography|BatchTableView|Alignment|Assembly|EsViritu|NaoMgs|Nvd|Phylogenetic|TaxTriage|TwelveS'
  ```

- [ ] Inspect warnings for ambiguous constraints, run `git diff --check`, and
  use commits: `feat: scale shared result tables`,
  `feat: scale genomics result content`, and
  `feat: scale metagenomics result content`.

---

## Task 4: Genotype content typography and Inspector control

**Files**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeQuickFilterBarView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeOutlineView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultTableView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeKnownAlleleDetailView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeKnownAlleleOverviewView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateAlleleDetailView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCohortSummaryPanelView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleDetailSheet.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeHaplotypeDefinitionMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Modify: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Behavior**

- The View inspector shows `A− / value / A+ / Default`.
- Matrix, outline, search, ordinary haplotype table, and known/candidate detail
  content update live.
- Matrix row/header geometry, row chiclet hit areas, comment folds, semantic
  frames, and selection brackets remain aligned through 200 percent.
- Detail labels wrap/expand; long biological text is not clipped.

- [ ] Add failing ViewModel/control tests for labels, accessibility, steps,
  bounds, and global preference changes.
- [ ] Add failing matrix/outline/detail layout tests at System, 90, 150, and 200
  percent, including selection and comment/review semantic geometry.
- [ ] Audit every fixed font in `Sources/LungfishGenotypeUI`, record
  primary-content adoption or a zoom/geometry/control-chrome exclusion, and add
  100→200→100 tests for every primary surface or its proven shared path.
- [ ] Implement the inspector control through AppSettings and adopt shared
  typography throughout genotype list/detail content.
- [ ] Run the focused display and viewport suites, `git diff --check`, and
  commit: `feat: scale genotype result content`

---

## Task 5: Editable threshold drafts and coalesced commits

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeNumericFilterDraft.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`
- Create or modify:
  `Tests/LungfishGenotypeUITests/GenotypeNumericFilterDraftTests.swift`

**Interfaces**

- Locale-aware integer and decimal draft models.
- Commit triggers: 200 ms idle, Return, Tab/focus loss, or Stepper.
- Escape restores committed value.
- Invalid input is never published; bounds clamp at commit.
- One coalescer owns cancellation and publishes only the latest valid draft.
- Stable identifiers and accessibility state expose label, current value,
  minimum/maximum help, increment/decrement actions, and invalid-draft
  validation description for both fields and steppers.

**Checkpoint rule:** This commit is an internal TDD checkpoint and is not
launchable/user-ready until Task 6 removes the synchronous rebuild path.

- [ ] Write failing deterministic draft tests using an injectable scheduler/
  clock for empty drafts, paste, locale decimal separators, invalid input,
  Return, focus loss, Escape, clamping, immediate visible Stepper value, and
  latest-value coalescing.
- [ ] Add explicit AX tests for stable identifiers, label/value/bounds,
  increment/decrement actions, invalid-entry help/description, and one
  validation announcement through the injectable poster.
- [ ] Write failing Inspector structure tests for numeric field plus labels-
  hidden Stepper and “0 = Off.”
- [ ] Run focused tests and confirm RED.
- [ ] Implement the isolated draft/coalescer model and SwiftUI fields. Avoid
  sleeping in tests.
- [ ] Run focused tests and `git diff --check`.
- [ ] Commit: `feat: add editable genotype support thresholds`

---

## Task 6: Cached matrix base projection and narrow display-state updates

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeMatrixBaseProjection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Create:
  `Tests/LungfishGenotypeUITests/GenotypeMatrixBaseProjectionTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces**

- Immutable base rows contain stable row identity, full sample support, display
  allele/reference search fields, read counts, and precomputed support fractions
  for each denominator.
- Derived threshold pass returns threshold-surviving rows/support without
  calling `result.locusSummaries` or `result.supportFraction`.
- DEBUG counters expose base-projection builds, derived filter passes, full
  table reloads, column rebuilds, layout applications, unrelated lens rebuilds,
  maximum derived-pass duration, and commit-to-visible settling time.

- [ ] Write failing base-projection correctness tests comparing cached
  derivation with the legacy result for zero and nonzero read/percent
  thresholds, both denominators, known rows, candidates, and zero/absent
  support.
- [ ] Write a 52-sample × 120-row rapid-draft regression and a separate
  150-sample column stress fixture. For twenty drafts followed by one idle
  settle, assert exactly one base build total, one derived pass after the
  counter reset, zero column rebuilds, zero Anchor/Consumer rebuilds, zero
  layout applications, one pinned-table and one sample-table reload at most,
  latest value displayed, and stable selection/sort/scroll/order/width.
- [ ] Instrument each derived pass and commit-to-visible settling. Record
  aggregate and maximum intervals in both the normal Debug test configuration
  and a Release benchmark run. Deterministic counters are CI assertions; Debug
  uses a 500 ms catastrophic ceiling to detect hangs, while the verification
  report must demonstrate the approved Release budgets of maximum main-thread
  pass ≤50 ms and visible settle ≤100 ms on the representative fixture.
- [ ] Implement base projection creation/invalidation and cheap derived filter.
  Rebuild only for result, candidate/reference projection, or candidate display
  setting changes.
- [ ] Narrow `applyDisplayStateImmediately` so matrix-only changes do not
  rebuild other lenses or reapply unchanged layout.
- [ ] Re-run focused projection/viewport tests and compare benchmark to the
  baseline recorded in this worktree.
- [ ] Commit: `perf: cache genotype matrix projection`

---

## Task 7: Shared genotype search index and corrected routing

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeSearchIndex.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeQuickFilterBarView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeSearchIndexTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces**

- Search result independently identifies sample identity/metadata matches,
  projected row matches, allele carriers, and haplotype carriers.
- Genotype-only placeholder: “Search samples or alleles…”.
- Haplotyped placeholder: “Search samples, alleles, or haplotypes…”.
- Three-or-more-character normalized matching retains Unicode letters/digits,
  uppercases, and preserves order.

- [ ] Write failing index tests using an internal raw ID displayed as
  `Mafa-A1*007:01`, queries `A1*007`, `A1 007`, `A1007`, sample queries
  `CR1178`/`1178`, metadata, haplotype carrier, and short punctuation cases.
- [ ] Add controller integration tests:
  - `CR1178` and `1178` yield identical two sample columns and all their rows;
  - a coincidental allele containing `1178` does not collapse sample-mode rows;
  - `A1*007` filters displayed rows while retaining active columns;
  - Outline/Review retain allele/haplotype carrier filtering;
  - genotype-only search performs no haplotype work;
  - the capability-specific placeholder and accessibility label match the
    approved lens/result contract.
- [ ] Add invalidation tests for result/reference, metadata, annotation/comment,
  and haplotype override changes.
- [ ] Implement the one index and remove the controller/matrix's divergent
  routing decisions.
- [ ] Add empty-result copy, Escape behavior, active-genotype `⌘F`, stable
  accessibility ID/label, and capability-specific placeholder. Assert the empty
  message includes recovery guidance, is exposed/announced once per state
  transition through the injectable poster, and never steals search focus.
- [ ] Run search/viewport tests and `git diff --check`.
- [ ] Commit: `fix: unify genotype sample and allele search`

Task 8 adds the manual-visibility composition regression after that state model
exists; Task 7 does not depend on future visibility behavior.

---

## Task 8: Row selection semantics and stable visibility model

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeMatrixVisibilityState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Create:
  `Tests/LungfishGenotypeUITests/GenotypeMatrixVisibilityStateTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces**

- Row and sample dimensions each have an optional include set and exclude set.
- Show Only replaces include and clears exclude; Hide unions exclude; Show All
  clears one dimension; Reset clears both.
- Selection summaries deduplicate stable rows/samples and describe rows,
  columns, rectangles, and mixed selections.
- Row chiclets and custom sample-column header selectors both expose button/
  checkbox semantics, label, selected value, press action, focus behavior, and
  selection notifications through accessibility.
- Mutable visibility ownership remains in each matrix/controller. Only an
  immutable selection/visibility capability snapshot is published to the
  Inspector; include/exclude sets never enter reapplied
  `GenotypeResultDisplayState`.

- [ ] Write failing pure-state set-algebra tests, including hidden-after-
  show-only, empty result, stable identity, row/cell/column/mixed expansion, and
  reset.
- [ ] Add rendered row chiclet and column-header selector tests for single,
  Command, Shift, and VoiceOver press selection. Assert a cell-only selection
  does not select either whole dimension.
- [ ] Add focus recovery, selection pruning, VoiceOver value/action, layout/
  selection notification, and announcement tests.
- [ ] Implement the row-selector predicate fix and visibility state using stable
  row/sample IDs, replacing the legacy selected-only allowlists.
- [ ] Preserve sort/scroll/column geometry and expose a testable selection
  summary/capability snapshot.
- [ ] Add a two-controller test proving visibility state does not leak between
  windows/controllers for the same or different bundle.
- [ ] After the model exists, add the deferred regression proving search and
  threshold changes compose with—not clear—manual visibility.
- [ ] Run visibility/viewport tests and `git diff --check`.
- [ ] Commit: `feat: add matrix row and column visibility`

---

## Task 9: Inspector and context-menu visibility commands

**Files**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify:
  `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
- Modify: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Behavior**

- Inspector shows scope/selection copy, Rows…, Columns…, and Reset Visibility.
- No-selection guidance says visibility uses selection and filters use the
  visible matrix.
- Context menu shows counted row/column commands, mixed-selection submenus, and
  Show All Rows and Columns when active.
- Annotation/review commands stay in a separate group.

- [ ] Write failing ViewModel/Inspector tests for summaries, enabled/disabled
  states, exact/pluralized labels, stable identifiers, action routing, and
  recovery status.
- [ ] Write failing immutable context-menu builder tests for row, column, cell,
  mixed, right-click retargeted, hidden, and empty-selection states.
- [ ] Implement Inspector menus and equivalent context submenus through the
  Task 8 visibility model.
- [ ] Post exactly one injectable accessibility announcement after each
  completed visibility change and test focus recovery when the focused target
  is hidden.
- [ ] Verify right-click menu construction remains side-effect-free and
  matrix-scan-free after the existing target selection step.
- [ ] Run display/viewport tests and `git diff --check`.
- [ ] Commit: `feat: expose matrix visibility commands`

---

## Task 10: Haplotype capability gating

**Files**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify:
  `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Modify: `Tests/LungfishAppTests/InspectorProvenanceTabTests.swift`
- Modify: `Tests/LungfishAppTests/GenotypeSampleMetadataImportTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeSmartCohortSectionTests.swift`

**Behavior**

- Document state explicitly reports haplotyping capability.
- Smart Cohorts and its divider are absent in genotype-only results.
- Persisted sidecar cohorts remain byte-for-byte untouched by hiding the UI.
- Transitioning to genotype-only clears/ignores an active in-memory cohort and
  avoids building cohort subjects.

- [ ] Add failing document rendering/state tests for genotype-only versus
  haplotyped results, exact section-plus-adjacent-divider absence, disabled
  actions, and sidecar preservation. Pre-seed and write the sidecar before
  recording comparison bytes so first-open built-in cohort seeding cannot
  invalidate the assertion.
- [ ] Add failing controller tests for active-cohort clearing and zero cohort
  subject rebuilds in genotype-only mode.
- [ ] Implement capability routing and conditional section/divider rendering.
- [ ] Run focused inspector/viewport tests and `git diff --check`.
- [ ] Commit: `fix: hide smart cohorts without haplotypes`

---

## Task 11: Integration, accessibility, performance, and regression gate

**Files**

- Modify: `docs/superpowers/specs/2026-07-25-genotype-view-accessibility-and-filtering-design.md`
  only if implementation-required clarifications preserve the reviewed contract.
- Create:
  `docs/verification/2026-07-25-genotype-view-accessibility-and-filtering.md`
- Modify user-facing help only where an existing View/filter topic requires it.

- [ ] Run all task-focused suites together:

  ```bash
  swift test --skip-update --filter 'AppSettingsTests|ContentTypographyTests|GenotypeResultDisplaySectionTests|GenotypeNumericFilterDraftTests|GenotypeMatrixBaseProjectionTests|GenotypeSearchIndexTests|GenotypeMatrixVisibilityStateTests|GenotypeResultViewportTests|GenotypeAnnotationStoreTests|GenotypeSmartCohortSectionTests|InspectorProvenanceTabTests|GenotypeSampleMetadataImportTests'
  ```

- [ ] Run all leaf UI targets affected by typography and the relevant app/core/
  kit regression suites.
- [ ] Run the prior annotation/workbook gate to prove no regression:

  ```bash
  swift test --skip-update --filter 'GenotypeCurrentWorkbookInputFingerprintTests|GenotypeWorkbookRevisionServiceTests|FastqGenotypingCommandTests|GenotypeCurrentWorkbookUpdateExecutionServiceTests|GenotypeCurrentWorkbookSyncCoordinatorTests|MappingViewportRoutingTests'
  ```

- [ ] Run the closest viewport-export, annotation-context-menu, workbook
  snapshot/service, and genotype viewport export suites before the full suite;
  visibility/filter context and shared context-menu routing must receive an
  early regression signal.

- [ ] Run the full package test suite.
- [ ] Build the debug application with:

  ```bash
  scripts/build-app.sh --configuration debug
  test -x build/Debug/Lungfish.app/Contents/MacOS/Lungfish
  /usr/bin/codesign --verify --deep --strict --verbose=4 build/Debug/Lungfish.app
  ```

- [ ] Manually inspect System, 90, 100, 150, and 200 percent in Light/Dark,
  Increase Contrast, Differentiate Without Color, and a non-default accent
  color. While System is selected, change macOS Accessibility > Display > Text
  Size with Lungfish inactive, reactivate it, and verify live refresh.
- [ ] With VoiceOver and keyboard-only input, traverse and activate row/column
  selectors, threshold fields, Inspector/context menus, Escape/Tab commits, and
  focus recovery after hiding the focused target.
- [ ] Reproduce `CR1178`, `1178`, and `A1*007`; test row/column hide/show and
  genotype-only Inspector state.
- [ ] Record deterministic counters, maximum/aggregate timing, test counts/
  durations, build result, identifier coverage, AX announcements/
  notifications, and manual inspection in the verification document.
- [ ] Run `git diff --check` and verify the worktree is clean after committing:
  `docs: record genotype view verification`.
- [ ] Request final independent specification and code-quality reviews. Resolve
  every Blocker/Important finding with a regression test and repeat the affected
  gates.

## Final handoff

- Build a fresh Debug app from this worktree.
- Quit every other running Lungfish instance.
- Launch only the new worktree Debug app for user testing.
- Report the branch, commit, app path, test evidence, benchmark comparison, and
  any intentionally excluded zoom-driven scientific renderers.
