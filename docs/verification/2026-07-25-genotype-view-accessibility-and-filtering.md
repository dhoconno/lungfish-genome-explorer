# Genotype View Accessibility and Filtering Verification

**Date:** 2026-07-25

**Branch:** `codex/genotype-view-accessibility-filters`

## Scope

This verification covers editable genotype thresholds, shared content text
sizes, responsive matrix projection, genotype-only capability gating, unified
sample/allele search, row-selection parity, and selection-based row/column
visibility in the viewport and Inspector.

All of these controls are view state. Search, thresholds, text size, and manual
visibility must not mutate scientific calls, annotations, workbook state, or
bundle provenance. Explicit analyst annotation mutations remain writable,
audited, and provenance-recorded.

## Independent Review

The specification, implementation stages, and completed implementation received
independent UX, accessibility, architecture, performance, workbook, and
provenance reviews.

The final review found and resolved:

- genotype-only viewport and Inspector configuration seeding built-in
  haplotype cohorts and thereby rewriting `annotations.json`;
- a threshold Stepper publishing every autorepeat event;
- an empty threshold draft remaining blank after its idle callback and later
  focus loss;
- a TaxTriage table cell using prohibited explicit layer backing;
- a missing completed-pipeline Release benchmark; and
- a per-query reconstruction of the search row-to-carrier map.

Final cross-review reported no Blocker or Important findings. Two accepted
test-hardening minors do not affect production behavior: the benchmark's
nonempty `Mafa` query produces an all-row constraint to preserve worst-row
workload, and the carrier-map reuse test is supplemented by static inspection
showing that the dictionary is constructed only in `GenotypeSearchIndex.init`.

## Functional and Regression Gates

All commands ran from the isolated feature worktree.

| Gate | Result |
| --- | --- |
| Feature, genotype viewport, Inspector, accessibility, and exact AppKit safety suites | 576 passed, 0 failed |
| Workbook, annotation, CLI, synchronization, and routing suites | 217 passed, 0 failed |
| Alignment, assembly, EsViritu, Nao-MGS, NVD, and phylogenetics UI suites | 79 passed, 0 failed |
| TaxTriage UI target | 34 passed, 0 failed |
| TwelveS UI target | 75 passed, 1 optional local-fixture benchmark skipped, 0 failed |
| LungfishKit target | 56 passed, 0 failed |

The feature gate includes:

- native text-field and Stepper editing, clamping, keyboard commit, Escape,
  VoiceOver values, and empty-draft focus-loss recovery;
- first-click-immediate Stepper publication with 20-event autorepeat reduced to
  the first and latest matrix updates;
- cancellation of pending numeric work on bundle switch, Inspector clear, and
  deinitialization;
- `CR1178`, `1178`, and normalized allele substring search;
- immutable cached search indexes and row-to-carrier maps;
- row and column selection indicators, visibility commands, context menus,
  Inspector routing, selection revalidation, no-op behavior, focus retention,
  and two-window isolation;
- genotype-only Smart Cohort omission;
- recursive byte equality for genotype-only viewport and Inspector opens;
- retained explicit comment audit records and canonical annotation provenance;
  and
- no workbook dirty/full-update state from view-only actions.

The workbook gate includes 85 crash-safe workbook revision tests and 49
viewport routing/current-workbook synchronization tests. It verifies immutable
input fingerprints, annotations, false-positive/false-negative formatting,
native comments, publication locking, update-and-view behavior, audit history,
and canonical provenance.

## Optimized Performance

The complete pipeline benchmark configures a 52-sample by 120-row result,
activates a nonempty shared allele search, hides one row and one sample column,
then submits 20 rapid threshold drafts. It requires one latest derived pass and
one visible settle, retains search and manual visibility, and compares every
bundle file recursively before and after, including `annotations.json`,
provenance, and `current.xlsx`.

Strict optimized invocation:

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 \
  swift test -c release -Xswiftc -DDEBUG \
  --filter 'GenotypeResultViewportTests/testRapidThresholdPipelineWithSearchAndManualVisibilityMeetsBudgetsWithoutMutation'
```

Three direct optimized runs passed:

| Measurement | Observed range | Budget |
| --- | ---: | ---: |
| Derived projection | 19.85–20.25 ms | no more than 50 ms |
| Commit to visible | 22.11–23.06 ms | no more than 100 ms |

The Debug catastrophic guard also passed at approximately 52.2–52.6 ms derived
and 13.5–25.3 ms visible.

## Complete-Package Diagnostic

The monolithic `swift test --skip-update` run completed the Swift Testing half
with 547 tests in 68 suites passing. Its single long-lived XCTest process again
terminated during AppKit teardown with `EXC_BAD_ACCESS` in
`objc_release` / `_NSWindowTransformAnimation.dealloc` while Core Animation
flushed an autorelease pool. The crash report is:

```text
~/Library/Logs/DiagnosticReports/xctest-2026-07-25-115354.ips
```

This matches the previously observed test-runner animation teardown failure.
The same XCTest coverage relevant to this feature completed in the isolated
gates above, including the exact prohibited-layer safety test and all affected
leaf UI targets.

## Manual Acceptance

The final packaging gate builds and signs the debug application from this
worktree before launching it for analyst acceptance. Manual visual checks then
remain for the live application: System and custom text sizes, Light/Dark and
accessibility appearances, keyboard/VoiceOver traversal, representative
searches, and row/column visibility workflows.
