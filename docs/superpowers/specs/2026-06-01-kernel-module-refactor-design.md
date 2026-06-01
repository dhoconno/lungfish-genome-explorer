# Kernel/Module Refactor: Design Spec

**Date:** 2026-06-01
**Status:** Approved scope — "go all the way including Phylogenetics" (maximal)
**Baseline commit:** `ae131e9d` (alpha10 shipped)
**Supersedes the path-forward section of:** `docs/reports/2026-05-31-modularization-findings.md`

> **Naming + language (user directive, 2026-06-01):** the shared kernel module is named
> **`LungfishKit`** (it was briefly named after AppKit during alpha10; renamed because the
> preferred LGE language is Swift and the kernel must not be named as "the AppKit layer").
> Code principle: PRESERVE existing AppKit on move (behavior-preserving relocation), PREFER
> plain Swift / SwiftUI for any NEW shared abstraction.

## Goal

Turn `LungfishApp` (a 217K-LOC monolith) into a **kernel + leaf-modules** architecture:

- **Kernel (`LungfishKit`)** holds all shared, reusable UI/infrastructure that multiple
  feature surfaces consume. When building a new module, a developer "shops the kernel" for
  what already exists.
- **Leaf modules** (`LungfishTwelveSUI`, and the new ones added here) each own exactly one
  feature surface, depend only on the kernel + lower layers (Core/IO/Workflow), and never
  reference `LungfishApp` or each other.
- **Composition hubs** stay in `LungfishApp` and wire the leaves together.

The payoff is build/test isolation: change a leaf -> recompile and test only that leaf;
change the kernel -> test the kernel and its dependents. SwiftPM per-target test targets
give this for free once the boundaries exist.

## Why this is the right architecture (the user's question: "does this make sense?")

Yes. Today every feature edit recompiles the 217K-LOC monolith and the test suite runs as
one giant pass. A kernel/module split fixes both, and it matches how the team wants to build:
discover reusable code in the kernel, add features as isolated modules. The alpha10 work
already proved the pattern end to end (`LungfishKit` builds standalone; `LungfishTwelveSUI`
is a green leaf with its own test target). This campaign generalizes that pattern across the
whole app.

## Scope decision (approved: maximal)

The dependency audit (see "Verified dependency structure" below) shows a clean difficulty
gradient. Three scope options were considered:

- **B (clean only):** promote the clean UI/util cluster + extract the 7 clean-to-medium
  leaves; defer the two op-pipeline-bound changes.
- **C (+ OperationCenter):** B plus promoting `OperationCenter` into the kernel.
- **Maximal (approved):** C plus untangling and extracting Phylogenetics from the
  FASTQ-operation/dialog pipeline.

**Approved scope = maximal.** Rationale: the user prioritizes completeness over speed, and
wants the kernel to be the true shared substrate (including the operation model). The two
risky boundaries (`OperationCenter` promotion; Phylogenetics extraction) are sequenced LAST,
each as its own reviewed phase with extra verification, because they touch the
operation/import event pipeline — the behavioral core of the app.

## Architectural rule (defines a "cycle")

A module at or below `LungfishApp` (the kernel, or any leaf) may **not** reference a type
**defined in `LungfishApp`**. If feature X needs type T and T is defined in `LungfishApp`,
then either (a) T must first be promoted into the kernel (only if T does not itself drag in
`LungfishApp`-internal dependencies), or (b) the X->T dependency must be inverted (X exposes
a callback/protocol the app satisfies). `LungfishApp` may freely depend on (import) any leaf.

Current dependency graph (verified in `Package.swift:150-186`):
`LungfishKit -> Core/IO/Workflow`; `LungfishTwelveSUI -> Core/IO/Workflow/AppKit`;
`LungfishApp -> Core/IO/Workflow/AppKit/TwelveSUI`; `LungfishCLI -> Core/IO/Workflow` (NOT
AppKit — so kernel-promoted UI types stay invisible to the CLI, which is fine).

## The extraction pattern (proven by the 12S leaf)

A leaf holds VC + display-state + export-service and imports only Core/IO/Workflow/AppKit.
The **glue** (e.g. `ViewerViewController+TwelveS.swift`) stays in `LungfishApp`, imports the
leaf, and wires app services to the VC's **callbacks** (`onUnresolvedBlastRequested`,
`onDisplayStateChanged`, ...). A leaf exposes callbacks; it never reaches up into an App type.

## Verified dependency structure (evidence-backed, 2026-06-01)

Method: per-module type-definition index across `Sources/`, then every load-bearing blocker
confirmed by reading the actual `file:line` (name-only matches from doc comments, string
literals, and same-named nested types like `Mode`/`Row`/`State` were excluded). The
`docs/reports/2026-05-31-modularization-findings.md` "blocked" reasoning is now partly
obsolete because Tier 0 (below) already shipped.

### Tier 0 — already in the kernel (verified, no back-deps)
`ClassifierActionBar`, `MinimumReadsThreshold`, `LungfishCLIRunner`, `CLIBinaryLocator`,
`BlastResultsDrawerTab`, `BlastResultsDrawerContainerView`, `MetagenomicsFilePanelFactory`.

### Kernel promotions needed (each a clean module-move unless noted)
1. **Pure AppKit/SwiftUI leaves:** `LungfishKitControlStyle` (`Views/Shared/`),
   `GenomicSummaryCardBar` (`Views/Shared/`), `ScrollViewSplitPaneContainerView` +
   `SplitPaneFillContainerView` (`Views/Layout/`), `FASTASequenceActionMenuBuilder` +
   `FASTASequenceActionHandlers` (`Views/Shared/`), `ZoomShortcutHandler` (`Views/Shared/`).
2. **Clean util/UI:** `MetagenomicsPaneSizing`, `MetagenomicsPanelLayout`,
   `MetagenomicsDrawerView`, `ClassifierUniqueReads` (all `Views/Metagenomics/`),
   `BlastConfigPopoverView` (`Views/Metagenomics/`), `FASTQDisplayNameResolver`
   (`Services/`), `AppUITestConfiguration` (`App/`).
3. **Protocol split:** extract `SavePanelPresenting` / `DefaultSavePanelPresenter` /
   `DefaultPasteboard` out of `Views/Metagenomics/TaxonomyReadExtractionAction.swift` into a
   kernel file. The action itself uses `OperationCenter` and stays in App until phase 5.
4. **`SequenceViewerView.pinchZoomFactor`** -> kernel helper, then promote
   `MiniBAMViewController` (its only non-kernel blockers are `pinchZoomFactor` and
   `ZoomShortcutHandler`).
5. **`OperationCenter`** (+ op-model types `OperationType`, `OperationLogEntry`,
   `OperationLogLevel`, `OperationRouteContext`, `OperationRetryMetadata`, nested
   `Item`/`Item.State`). Mechanically clean (no `LungfishApp`-internal back-deps; already
   decoupled from `AppDelegate` via `onBundleReady` callbacks; needs only `WindowStateScope`,
   already in the kernel) BUT 45-file blast radius. Its own reviewed phase.
6. **Cross-cutting prerequisite for Genotype + Phylogenetics:** split
   `Inspector/Sections/SelectionSection.swift` (co-defines four features'
   selection states: `MultipleSequenceAlignmentSelectionState`,
   `SequenceRegionSelectionState`, `PhylogeneticTreeSelectionState`,
   `GenotypeResultSelectionState`) into per-feature files before extracting either leaf.

### Leaf extractions, in dependency order (each: own test target, lands green)
1. **Alignment** — `Views/Results/Alignment/AlignmentResultViewController.swift`. Zero
   blockers today; already uses kernel `ResultViewportController`. Easiest.
2. **CzId** — its only non-kernel blocker is `TaxonomyViewController`, which is part of the
   metagenomics hub cluster and is NOT being extracted (it stays in App). Therefore CzId
   **stays in `LungfishApp` in this campaign** (extracting it would require first turning the
   Taxonomy hub into a leaf, which is out of scope). Recorded here for completeness; no Phase 2
   action. Phase 2's leaf is Alignment only.
3. **Assembly** — `Views/Results/Assembly/*`. Needs kernel promotions #1, #2, #3. No
   op-pipeline touch.
4. **Mapping** — `Views/Results/Mapping/*`. Only blocker:
   `ReferenceBundleViewportController` (promote or co-extract).
5. **EsViritu / NAO-MGS / NVD / TaxTriage** — each `Views/Metagenomics/*ResultViewController`.
   Need the full metagenomics-infra promotion set (#1, #2, #4 incl. `MiniBAMViewController`).
   They share infra but not each other's VC classes, so each is its own leaf.
6. **Genotype** — `Views/Results/Genotype/*`. Requires: split
   `GenotypeResultSelectionState` out of `SelectionSection.swift`; move the 9
   `Inspector/Sections/Genotype*Section.swift` files (Genotype-specific) into the leaf;
   place `GenotypeResultDisplayState`/`GenotypeAnnotationStore` in the leaf so App's
   `InspectorViewController` imports them (App depends on the leaf). Medium-high effort
   (bidirectional Genotype<->Inspector knot, confirmed real).
7. **Phylogenetics** — `Views/Viewer/PhylogeneticTreeViewController.swift`,
   `Views/Phylogenetics/IQTree*`. Hardest. Blockers: `FASTQOperationDialogState`
   (op/dialog-pipeline-bound), `DatasetOperationsDialog` + `DatasetOperationSection` +
   `DatasetOperationToolSidebarItem`, `MultipleSequenceAlignmentTreeInferenceRequest`
   (defined in the MSA VC), `ViewerFilePanelFactory`, `LungfishKitControlStyle`,
   `PhylogeneticTreeSelectionState`. Requires inverting the dialog/file-panel dependencies
   (inject via protocol) and resolving `FASTQOperationDialogState`. Done LAST.

### Hubs that STAY in `LungfishApp` (composition roots, verified)
- `ViewerViewController` (9,215 LOC / 18 files) — holds an optional property for every
  feature VC; the viewport-swapping core and home of the per-feature glue extensions.
- `MainSplitViewController` (5,973 LOC / 9 files) — wires the three-pane window; 30
  `OperationCenter` refs; instantiates the batch result VCs.
- `InspectorViewController` (3,728 LOC / 7 files) — adapts to the active feature; composes
  the per-feature inspector sections.
- `SidebarViewController` (4,873 LOC / 4 files) — project-tree/navigation root.
- Metagenomics batch coordination lives in the hubs/services (`MetagenomicsBatchResultStore`
  + hub extensions); the batch *table* infra (`BatchTableView` subclasses) is already in the
  kernel.

Extracting the hubs is explicitly **out of scope** — it would be a different, riskier project.
"Finishing" modularization here means extracting the leaves, not gutting `LungfishApp`.

## Phasing (each phase: full suite green + every module builds standalone + commit)

- **Phase 1 — Clean kernel cluster (promotions #1, #2, #3):** mechanical module-moves of the
  pure AppKit/SwiftUI + clean util types, plus the `SavePanelPresenting` protocol split.
- **Phase 2 — First easy leaf:** Alignment (zero blockers). Proves the leaf pipeline on a
  zero-blocker surface. (CzId stays in App — see leaf-order note 2.)
- **Phase 3 — Mid leaves:** Mapping (after `ReferenceBundleViewportController`), Assembly.
- **Phase 4 — Metagenomics infra + leaves:** promotion #4 (`pinchZoomFactor` +
  `MiniBAMViewController`), then EsViritu, NAO-MGS, NVD, TaxTriage leaves.
- **Phase 5 — OperationCenter promotion (#5):** the 45-file blast-radius move into the
  kernel. Reviewed phase; extra verification of the operation/import pipeline.
- **Phase 6 — SelectionSection split (#6) + Genotype leaf:** untangle the Genotype<->Inspector
  knot; move Genotype-specific inspector sections into the leaf.
- **Phase 7 — Phylogenetics leaf:** invert dialog/file-panel deps, resolve
  `FASTQOperationDialogState`; extract last. Reviewed phase.
- **Phase 8 — Benchmark + release:** re-run `scripts/measure-build-times.sh` vs the
  `ae131e9d` baseline; demonstrate per-module test isolation; bump alpha10->alpha11; build
  notarized DMG + Sparkle appcast; confirm clean local+remote main.

## Testing strategy

- Every leaf gets its own SwiftPM test target (`Tests/Lungfish<Leaf>UITests/`), mirroring
  `Tests/LungfishTwelveSUITests/`.
- Behavior-preservation discipline: for pure module-moves, verify by building (the type
  resolves only if references are satisfied) and by the existing test suite (no test logic
  changes). For dependency inversions (Genotype, Phylogenetics), add/keep tests that exercise
  the callback wiring through the App-side glue.
- After EVERY phase: full suite green (8,841 XCTest + 475 swift-testing, 0 failures is the
  current bar) AND each module builds standalone (`swift build --target <Module>`), proving
  no back-dependency.
- **Serialize all `swift` invocations** — a single `.build/.lock` exists; never run a second
  `swift build`/`swift test` while one is in flight (memory rule).

## Build-benchmark plan

Re-run `scripts/measure-build-times.sh` after Phase 7 and compare to the `ae131e9d`
baseline recorded in `docs/reports/baselines/`. Beyond the standard timings, measure the
**module-scoped incremental rebuild** for an edit confined to an extracted leaf and an edit
confined to the kernel, demonstrating the "test only what changed" payoff that motivated this
work. Record results in a new `docs/reports/2026-06-01-kernel-module-results.md`.

## Risks and mitigations

- **OperationCenter (Phase 5):** highest blast radius. Mitigation: it is mechanically clean
  (verified no App back-deps); move as a pure relocation, rebuild + full suite, code review.
- **Phylogenetics op/dialog pipeline (Phase 7):** behavioral risk in the FASTQ-operation
  dialog. Mitigation: invert via protocol injection rather than moving pipeline types; keep
  the dialog presenter App-side; extract only the VC + options into the leaf.
- **Genotype<->Inspector knot (Phase 6):** Mitigation: move Genotype-specific inspector
  sections into the leaf; App imports the leaf for the display-state types.
- **Half-untangled state:** every phase lands green and is independently shippable; if a
  phase proves harder than scoped, stop at the last green phase and document the remainder
  (the findings-doc principle).
