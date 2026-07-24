# Task 5 Report: Accessible Matrix Review Annotations

## Status

Completed.

## Delivered

- False-positive cells render bracketed read counts such as `[42]` with dynamic secondary, italic text while retaining full cell alpha and the original evidence count.
- False-negative cells retain explicit `0` values and use an em dash only when support is absent. Their semantic inner frame is independent of analyst borders, support previews, selection brackets, and comments.
- Review, selection, decorative border, and folded-corner comment layers remain independent in Support, Highlights, and None modes, including when filtered highlights are hidden.
- Row, sample-column, and cell comments draw only at their native scope. Tooltips are cached in stable Allele Row → Sample Column → Cell order.
- Right-click selection behavior, cached-capability menus, keyboard equivalents, disabled-reason parity, row/header comment actions, and supported-cell helpers share one command state.
- The exact compact legend is present:

  `[n] False positive   ▣ False negative   ◥ Comment`

- VoiceOver cell descriptions include sample, genotype, locus, evidence, review state, selection state, and scoped comment counts. Drawn markers add no independent focus stops.
- Dynamic AppKit colors and larger Increased Contrast geometry are used.
- Visible-cell rendering uses cached row, sample-column, evidence, annotation, and selection dictionaries/sets. Context-menu selection membership is constant-time and performs no evidence/index rebuild.
- Targeted reload counters now aggregate and reset both the pinned and sample tables.

## TDD Evidence

The initial semantic tests failed before implementation:

- False-positive text was `42` instead of `[42]`.
- A false-negative without support rendered an empty string instead of `—`.
- New semantic chrome, menu, accessibility, and benchmark test APIs did not compile until their production behavior was implemented.

Focused GREEN runs covered semantic layers, dynamic text, scoped markers/tooltips, Increased Contrast, filtered-highlight independence, right-click selection, cached menu/keyboard state, accessibility, targeted reloads, and the benchmark harness.

## Review Findings Resolved

The independent code review reported five Important findings, then found two residual
structural issues during re-review; all were addressed:

1. Replaced reverse sample-column and selection-array scans in visible-cell rendering with direct dictionaries and a cached target set.
2. Added a visible row-comment marker fallback to the row selector and preserved its containing-cell accessibility description when identity/locus columns are hidden.
3. Replaced the hardcoded menu `fileAccessCount` with an injectable access-event observer used as a real spy seam. Tests observe cached selection/capability access and assert no filesystem event or index rebuild.
4. Kept representative timings as recorded observations and removed the hard 50 ms ordinary-CI gate.
5. Aggregated/reset DEBUG reload counters for both matrix tables and added a row-comment regression covering the pinned and sample panes.
6. Added a row-ID index so legacy candidate selection disambiguation performs no visible-row scan in the render hot path.
7. Isolated menu-state construction in a pure cached-input builder and added a deterministic source-boundary regression that rejects direct file/store/load/read/write calls in menu construction.

## Representative Benchmark Record

Fresh full-suite run on 2026-07-24:

| Operation | Targets | Observed wall time |
|---|---:|---:|
| Small selection aggregation | 8 | 0.0000360 s |
| Large selection aggregation | 200 | 0.0004280 s |
| Cached menu construction | 200 | 0.00000906 s |
| Visible redraw | 240 | 0.0267179 s |
| Bulk sidecar application | 200 | 0.0006349 s |

The menu observation was below the 50 ms product target. Timing values are recorded, not used as fragile pass/fail gates. CI assertions remain structural: exact target counts, zero observed filesystem events during menu construction, unchanged evidence/annotation index build counts, and targeted rather than full reloads.

## Verification

```text
swift test --skip-update --filter GenotypeResultViewportTests
Executed 254 tests, with 0 failures in 30.610 seconds.

git diff --check
Passed.
```

## Provenance

This task adds viewport behavior and tests; it creates no new scientific data workflow or exported scientific bundle. Menu review/comment mutations are bridged through the existing controller commands and provenance-aware annotation store rather than writing sidecar files directly.

## Remaining Concerns

None identified for Task 5.
