# Candidate-Only Genotype Viewport Routing

## Problem

A completed full-length ONT MHC genotype bundle can contain scientifically reviewable candidate alleles even when none of its reads produce named-reference genotype calls. The `bc14_Mafa-E.lungfishgenotype` bundle demonstrates this case: its reviewable-row catalog contains 36 rows, including 10 candidate rows with read support, while its named-call CSV contains only a header.

The app currently chooses the Excel preview whenever `result.calls` is empty. That check ignores the bundle's validated reviewable-row catalog and candidate projection, so the app opens `current.xlsx` instead of the native genotype matrix. The genotype controller also defaults call-free results to Outline, which would still be wrong after correcting the outer routing decision.

## Decision

Use the validated reviewable-row catalog as the authoritative signal that a result has native genotype-review content.

A result has native genotype matrix content when either:

- it contains at least one named genotype call; or
- it contains a validated reviewable-row catalog with at least one row.

When native matrix content exists, the app opens the native genotype result viewport and defaults genotype-only results to Matrix. The workbook fallback remains available only for legacy or genuinely empty results that have neither named calls nor reviewable catalog rows.

This rule deliberately does not require a positive read count. A published reviewable row is still useful for false-negative review, comments, and other analyst annotations even when all displayed support values are zero.

## Design

Add one shared, read-only capability on `ONTGenotypeResultBundleData` that answers whether native genotype matrix content exists. Both presentation decisions consume this capability:

1. `MainSplitViewController.shouldPreviewPrimaryWorkbook` uses it to decide between the native genotype viewport and the legacy workbook preview.
2. `GenotypeResultViewController.defaultSummaryViewMode` uses it to select Matrix rather than Outline for genotype-only results.

Keeping the rule on the loaded bundle data avoids duplicating subtly different candidate checks in the app and UI modules. It also relies on the loader's existing checksum, schema, and catalog validation; an absent or invalid catalog is never treated as reviewable content.

No scientific artifacts, workflow recipes, thresholds, genotype calls, or provenance records are changed. Existing bundles are interpreted from their already-published data.

## Compatibility and Failure Behavior

- Existing call-bearing genotype bundles continue to open the native matrix.
- Candidate-only bundles with a nonempty validated catalog open the native matrix.
- Catalog-backed bundles whose rows all have zero support still open the native matrix.
- Legacy call-free bundles without a catalog continue to preview their workbook when one exists.
- Haplotyped results retain their existing routing and default-view behavior.
- Missing or malformed catalog artifacts continue to fail through the existing bundle-integrity checks rather than silently changing presentation.

## Testing

Add focused tests that construct real `ONTGenotypeResultBundleData` values and verify:

- named calls imply native matrix content;
- a nonempty reviewable catalog implies native matrix content when calls are empty;
- an empty catalog does not imply native matrix content;
- workbook preview is suppressed for candidate-only catalog-backed results;
- legacy call-free results still use the workbook fallback;
- candidate-only genotype results default to Matrix;
- existing haplotyped and call-bearing defaults remain unchanged.

The regression test must fail against the current routing predicate before implementation. After the minimal fix, run the relevant IO, app-routing, and genotype viewport tests plus a debug or release build.

## Baseline Note

Before this change, `GenotypeMatrixBaseProjectionTests` pass. Three `GenotypeResultDisplaySectionTests` concerning Audit-versus-Summary normalization fail identically on the feature worktree and unchanged `main`; they are unrelated pre-existing failures and are not part of this fix.
