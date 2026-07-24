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

- VoiceOver cell descriptions include sample, genotype, locus, evidence, review state, selection state, and scoped comment counts. Drawn markers remain part of a single accessible host instead of becoming independent focus stops.
- Dynamic AppKit colors and larger Increased Contrast geometry are used.
- Visible-cell rendering uses cached row, sample-column, evidence, annotation, and selection dictionaries/sets. Context-menu selection membership is constant-time and performs no evidence/index rebuild.
- Targeted reload counters expose, aggregate, and reset the pinned and sample tables independently.

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
3. Replaced the vacuous menu access-event observer with an immutable cached snapshot boundary and an injected snapshot source. A real spy verifies that actual AppKit menu creation reads that snapshot once, while the production builder accepts only cached value state.
4. Kept representative timings as recorded observations and removed the hard 50 ms ordinary-CI gate.
5. Exposed separate DEBUG full/partial reload counters for both matrix tables and added a row-comment regression proving each pane receives a partial reload and neither receives a full reload.
6. Added a row-ID index so legacy candidate selection disambiguation performs no visible-row scan in the render hot path.
7. Isolated menu-state construction in a pure immutable cached-input builder. The actual `NSMenu` disables AppKit auto-enabling, and a regression calls `NSMenu.update()` to prove a cached disabled command stays disabled.

## Representative Benchmark Record

Fresh full-suite run on 2026-07-24:

| Operation | Targets | Observed wall time |
|---|---:|---:|
| Small selection aggregation | 8 | 0.0000360 s |
| Large selection aggregation | 200 | 0.0004510 s |
| Cached menu construction | 200 | 0.00001299 s |
| Visible redraw | 240 | 0.0265170 s |
| Bulk sidecar application | 200 | 0.0005900 s |

The menu observation was below the 50 ms product target. Timing values are recorded, not used as fragile pass/fail gates. CI assertions remain structural: exact target counts, immutable cached menu input read once by a real spy, unchanged evidence/annotation index build counts, and targeted rather than full reloads.

## Review-Fix Follow-up

The Task 5 review follow-up was completed with a second red-green cycle:

- Added an actual `NSMenu` regression that calls `update()` and verifies `autoenablesItems == false` preserves cached capability state.
- Removed the fake `.fileSystem` event, source-string filesystem scan, and benchmark `fileAccessCount`. Menu acquisition now crosses an injected immutable snapshot boundary, and the production renderer/builder consumes only the cached snapshot.
- Extended cached `Allele Row:` tooltips to every possible native row-comment marker host: genotype, allele-reference, locus, and row selector.
- Replaced aggregate-only reload assertions with independent pinned/sample full and partial counters.
- Replaced the hardcoded marker accessibility count with inspection of the actual rendered cell subtree, proving the containing host exposes exactly one accessibility element.
- Removed the unused `targetIdentity` helper.

## Verification

```text
swift test --skip-update --filter GenotypeResultViewportTests
Executed 255 tests, with 0 failures in 30.443 seconds.

git diff --check
Passed.
```

## Provenance

This task adds viewport behavior and tests; it creates no new scientific data workflow or exported scientific bundle. Menu review/comment mutations are bridged through the existing controller commands and provenance-aware annotation store rather than writing sidecar files directly.

## Remaining Concerns

None identified for Task 5.
