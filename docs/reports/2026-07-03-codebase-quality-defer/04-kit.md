# LungfishKit — Deferred Items (Phase 4)

Module: `Sources/LungfishKit/**` (47 files, ~11K LOC). Shared UI/infra kernel.
Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests
(`--filter LungfishKitTests`) -> independent adversarial review -> revert-on-uncertainty
-> commit.

Kit-specific binding invariants (never violate / refactor away):
- **A leaf or the kernel may NEVER reference a type defined in `LungfishApp`** (forbidden
  cycle). Flag any such reference.
- `OperationCenter` is the source-of-truth for the `update()` + `log()` pairing consumed by
  every pipeline op. Preserve its public API and the op-model types
  (`OperationType`/`OperationLogEntry`/`OperationLogLevel`/`OperationRouteContext`/
  `OperationRetryMetadata`).
- macOS 26 API rules (UI-heavy module): NO `NSSplitViewController` delegate methods,
  `lockFocus`, `wantsLayer`, `runModal`, `synchronize`. Do not introduce them; flag existing.
- Background->MainActor dispatch rules; brand colors live here (`LungfishColors`); accent
  Lungfish Orange `#D47B3A`.
- NEVER write the literal `Task {` immediately followed by `@MainActor`.

Big files (audit solo, largest first): BlastResultsDrawerTab (1946),
MiniBAMViewController (1870), LungfishHelpContent (1007), BatchTableView (974),
OperationCenter (731), MetadataColumnController (512). Clusters: the BLAST drawer cluster,
split-pane infra, pickers, small view components.

## Big-file audits (6 largest) — findings

All kernel-clean (no LungfishApp refs) and macOS-26-clean (no runModal/lockFocus/wantsLayer/
synchronize/split-view-delegate). Applies are small; value is in deferred splits.

### Applied (Kit big-file cluster batch)
- `BlastResultsDrawerTab.summaryBar` internal->private (verified: tests import LungfishKit
  NON-@testable, never access it).
- `BlastResultsDrawerTab` guard `case .results(_)` -> `.results` (redundant binding-parens).
- `MetadataColumnController.cellForColumn(_:)` drop redundant `return` (single-expr body).
- `MiniBAMViewController.depthPoints` dead write-only property + its reset in clear()
  (grep-verified never read; private).

### FLAGGED UPWARD — pre-existing rule violation (deferred, NOT introduced by this pass)
- `MetadataColumnController.swift:220-222`: inside the `columnResizeObserver` NotificationCenter
  block, `Task { @MainActor [weak self] in self?.syncDisabledColumnsFromWidths() }` — this IS
  the forbidden GCD/notification-context -> MainActor hop pattern. The project-correct form is
  `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }`
  (columnDidResizeNotification posts on main, so assumeIsolated is valid). DEFERRED because the
  fix is a concurrency BEHAVIOR change (Task yields to a later runloop turn vs assumeIsolated
  runs synchronously) — NOT behavior-preserving. Downstream: fix in a concurrency-scoped pass.

### Concurrency patterns VERIFIED CORRECT (do NOT "fix" — they are not violations)
- `BatchTableView.swift:446` `Task { @MainActor [weak self] in }` — SAME-actor structured
  concurrency on an already-@MainActor class (debounce), not a GCD hop. Correct.
- `MiniBAMViewController`: all background->MainActor hops use the mandated
  `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }`. The
  `loadTask = Task.detached` string is PINNED by
  AppKitConcurrencyModalSafetyTests.testMiniBAMAlignmentLoadingDoesNotInheritMainActor
  (source-string scan) — any MiniBAM split MUST preserve that literal in this exact filename.

### Deferred SPLITS (each its own reviewed pass)
- `BlastResultsDrawerTab.swift` (1946L): +Model / +Setup / +Menus / +Export / +OutlineView.
  Needs private->internal promotion of `hiddenColumnsDefaultsKey`, the column-id
  `NSUserInterfaceItemIdentifier` statics, `outlineItems`, sort state, cell factories.
- `MiniBAMViewController.swift` (1871L): SAFEST first cut = extract `MiniPileupView`
  (~850L, already internal, no VC-private promotion). Intra-VC split needs promoting VC
  drawing/scroll state + must preserve the `loadTask = Task.detached` source-string test.
- `BatchTableView.swift` (974L): +Filter / +Selection — but ALL `@objc`/protocol-conformance
  methods MUST stay on the class header (a generic class can't have `@objc` in an extension;
  documented in-file at lines 82-86).
- `LungfishHelpContent.swift` (1007L): content-data table -> +FASTQ/+BAM/+Classifier content
  extensions (illusory string dedup — content is data, verbatim).

### Deferred DEDUP (AppKit cell/layout, semantics-sensitive)
- BlastResultsDrawerTab `makeParentStatusCell` two branches, `makeParentCell`/`makeChildCell`
  parallel column switches, `applySortDescriptors` vs `sortDescriptorsDidChange` key mapping.
- MetadataColumnController `exportValues` vs `exportValues(for:)` (divergent early-return on
  nil sample); `configureMetadataCell` re-sets font on RECYCLED cells (intentional, keep).
- Cross-file: `formatReadCount` duplicated in TaxTriageBatchOverviewView.swift:599 (leaf).

### Verified NOT dead / NOT tightenable (traps)
- BatchTableView `testSearchField`/`testTableView`/`formatReadCount` (test + leaf consumers).
- MiniBAMViewController `testing*`/`DisplayReadStats`/`MiniPileupView`/`inferReferenceBases`
  etc. all @testable-pinned.
- `blastVerdictDanger` intentionally duplicates `NSColor.lungfishDanger` RGB to keep the
  kernel free of app-level deps (documented).

## Deferred items

_(populated per batch as uncertain changes are reverted)_
