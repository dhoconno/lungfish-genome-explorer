# GUI Performance Refactor — Opus Deferrals

Date: 2026-07-02
Context: Fable-only GUI performance refactor
(`docs/superpowers/specs/2026-07-02-fable-gui-perf-refactor-design.md`,
`docs/superpowers/plans/2026-07-02-fable-gui-perf-refactor.md`).

This pass was implemented exclusively with Claude Fable. Per the design, items
that could not be landed safely with Fable — with green tests and adversarial
reviewer sign-off — were STOPPED rather than half-implemented, and are recorded
here for a future Opus pass. Each entry: symptom, location, why it exceeds a
safe Fable change, and a proposed approach.

Phases 1–4 shipped their real wins (see the plan's per-phase gate results). The
two genuinely-architectural items in Phase 5 are deferred; both are documented
below with the analysis that justified deferral. A small number of accepted
Minor follow-ups (surfaced by phase-gate reviewers) are listed at the end.

---

## D1. Off-main sidebar tree scan (Phase 5, Task 24)

**Symptom.** Opening a project runs `SidebarViewController.buildRootItems(from:)`
synchronously on the main actor. It walks the filesystem
(`contentsOfDirectory` + an O(n) per-file `fileExists(isDirectory:)` sort) and
recursively classifies every bundle, blocking the main thread proportional to
project size. Large projects (many bundles / deep Analyses trees / network
volumes) show a perceptible open-time stall.

**Location.** `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`:
`buildRootItems` (:1149) → the recursive `buildSidebarTree(from:isRoot:)`
(:1208) and ~8 fan-out helpers (`buildBatchGroupNodes` :1656, `collectAnalyses`
:1687, `buildAnalysisItem` :1744, `buildBatchAnalysisItem` :1795,
`collectNaoMgsResults` :2054, `collectNvdResults` :2119). Called at :864.

**Why it exceeds a safe Fable change.** The filesystem read and the
`SidebarItem` construction are the *same recursive pass*, not two separable
phases:

1. `SidebarItem` is `public class SidebarItem: NSObject`, `@MainActor`, NOT
   Sendable (`SidebarItem.swift:11`), carrying `var customImage: NSImage?`. It
   cannot be built off-main.
2. Decisively, the scan **renders AppKit `NSImage` badges mid-walk**:
   `buildAnalysisItem`/`buildBatchAnalysisItem`/`collectNaoMgsResults`/`collectNvdResults`
   call `TextBadgeIcon.image(text:size:)` (:1757, :1805, :2084, :2149), which
   runs `NSImage(size:flipped:)` with `NSBezierPath`/`NSColor`/`NSFont`/
   `NSAttributedString.draw` — main-actor drawing produced *inside* the tree
   walk. So "an off-main scan that touches no @MainActor state" is impossible
   without first extracting a Sendable intermediate representation.

There are 23 inline `SidebarItem(...)` construction sites across ~10
mutually-recursive methods. A safe off-main scan requires a parallel immutable
Sendable node tree plus a parallel apply that reconstructs the identical
`SidebarItem` graph — a ~1000-line behavior-preserving rewrite touching every
bundle-classification and result-title path, with real risk of a project-tree
data-integrity regression. That is beyond a safe single Fable change under a
perf ticket.

**Proposed Opus approach (two stages).**
- **Stage A (mechanical, the real work):** introduce an intermediate immutable
  `struct SidebarNode: Sendable { title; type; subtitle; url;
  badge: BadgeDescriptor?; children: [SidebarNode] }`, where `BadgeDescriptor`
  is a Sendable enum (`.symbol(String)` / `.text(String)`) capturing badge
  *intent*, not an `NSImage`. Refactor `buildSidebarTree` + all helpers to
  produce `SidebarNode` (pure filesystem reads, no AppKit). Add one
  `@MainActor func materialize(_ node: SidebarNode) -> SidebarItem` that renders
  `TextBadgeIcon.image` for `.text` badges and sets `userInfo`. Gate this behind
  a golden-tree parity test (SARS-CoV-2 fixture project + a synthetic
  Analyses/FASTQ tree) asserting byte-for-byte tree equality with today's
  builder BEFORE moving anything off-main.
- **Stage B (the actual Task 24):** make the `SidebarNode` builder `nonisolated`
  / run via `Task.detached`; add `sidebarScanGeneration` bumped on each
  project-open/reload; `await` the node tree; on `@MainActor` re-check the
  generation with ZERO `await` between the guard and the `rootItems` mutation
  (the Phase 2 MSA / VariantSection generation-guard discipline), then
  `materialize` + assign + `reloadOutlineView`.

Attempting Stage B without Stage A is the unsafe path. Stage A is where the risk
lives and deserves the golden-tree harness.

---

## D2. Render coordinator — lift viewport fetch scheduling out of `draw(_:)` (Phase 5, Task 25)

**Symptom (architectural, NOT a live perf defect).** The sequence viewport's
`draw(_:)` schedules up to seven async data fetches inline
(`fetchAnnotationsAsync`, `fetchSequenceAsync`, `fetchVariantsAsync`,
`fetchGenotypesAsync`, `fetchDepthAsync`, `fetchConsensusAsync`,
`fetchReadsAsync`). The design spec flagged "fetch scheduling entangled with
drawing" as a target: ideally a render coordinator keyed by a viewport signature
schedules the needed fetches once, outside the draw path, and fetch completion
invalidates only affected track/lane rects.

**Location.** `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift`:
`draw(_:)` (:20) → the seven `fetch*Async` calls at :143, :167, :247, :310,
:367, :403, :428, with the fetch implementations following.

**Why it is DEFERRED rather than done (and why it is low-priority).** The perf
goal this task targeted is **already met** by existing code, and the remaining
change is architectural purity on the app's most delicate code:

1. Every fetch is ALREADY off the main thread and generation-guarded — the
   hard-won `[RUNLOOP_V2]` background-then-main-runloop-commit pattern with
   `*FetchGeneration` stale-result discard and per-region caching. Scheduling
   from `draw()` does not block the main thread.
2. The draw-path scheduling is ALREADY idempotent "request-if-missing": each
   fetch is guarded by coverage + in-flight flags (e.g.
   `needsAnnotations && !annotationsCovered && !isFetchingAnnotations` at :141;
   `!sequenceCovered && !isFetchingBundleData && bundleFetchError == nil` at
   :165). Redraws do NOT re-trigger fetches; a fetch fires only when the cache
   is stale and none is in flight. So the current pattern is correct, not a
   thrash source.
3. Converting to a render coordinator is therefore a behavior-neutral refactor
   of ~700 lines of the most intricate, most-tested drawing code in the app
   (seven interdependent fetches, six generation counters, the delicate
   background→main-runloop dispatch). The regression risk is high and the
   incremental user-visible benefit is low, because the fetches are already
   non-blocking and de-duplicated.

Under the "Fable does what it can, defer the rest" mandate, rewriting working,
guarded, well-tested code for architectural cleanliness — with no measured perf
win — is the wrong risk/reward for a Fable change. It is recorded here so a
future Opus pass can take it on deliberately if the architecture cleanup is
independently wanted.

**Proposed Opus approach.** Introduce a `ViewportRenderCoordinator` keyed by a
viewport signature (visible region + active track set + render options).
`draw(_:)` becomes pure: it reads cached data and, if a track's data is missing
for the current signature, asks the coordinator (which dedupes by signature and
owns the generation counters) rather than calling `fetch*Async` directly. Fetch
completion posts a targeted invalidation for only the affected track/lane rect
instead of `needsDisplay = true` on the whole bounds. Migrate one fetch at a
time behind the coordinator, keeping the existing `[RUNLOOP_V2]` commit +
generation-discard semantics, with a characterization test per fetch asserting
identical cache/redraw behavior before and after. This is a multi-session
refactor with its own spec, not a single ticket.

---

## Accepted Minor follow-ups (non-blocking; surfaced by phase-gate reviewers)

These are small, non-architectural items the phase gates flagged as
non-blocking. They do not require Opus; they are backlog polish.

- **Retired 2026-07-05: GenotypeOutlineView `handleClick` gesture resolution.**
  This entry is no longer a live follow-up. The current virtualized row builder
  assigns the row's sample identifier to the leading click target, and
  `GenotypeOutlineVirtualizationTests.testCallbacksPreservedAfterVirtualization`
  drives the materialized row recognizer through the handler.
- **GenotypeOutlineView cell recycling.** `viewFor` builds a fresh cell per call
  rather than reusing (`makeView(withIdentifier:)`), justified by per-row
  gesture state. Bounded to the visible window, so acceptable; a recycling +
  reconfigure pass would reduce scroll-time allocation churn if Instruments ever
  shows it.
- **"Show all" mass reveal has no paging/spinner.** Revealing all columns on a
  many-hundred-sample cohort instantiates them in one synchronous pass. User-
  opted-in and bounded by the reveal action; a paged reveal or progress
  indicator would harden the interaction at extreme cohort sizes.
- **Rectangle (shift-drag) cell selection in the genotype matrix is bounded by
  the visible column window.** Full-set "select all" is unaffected and "Show
  all" restores the range; noted for completeness.
