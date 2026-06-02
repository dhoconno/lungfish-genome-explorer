# 12S Abundance Reassignment — Hardening (per-sample, persisted evidence, configurable threshold)

Date: 2026-06-02
Status: Approved design (expert-adjudicated hardening of the batch-3 count-time reassignment)
Owners: `LungfishWorkflow` (reassigner + workflow + bundle write), `LungfishIO` (manifest/artifacts), `LungfishTwelveSUI` (donor-row visibility), CLI (threshold flag).

## Why

The batch-3 count-time reassignment (`TwelveSAbundanceReassigner` + `applyAbundanceReassignment`) shipped functionally correct (read-conservation verified, full suite green) but a genomics-bioinformatics and a biostatistics expert independently found three structural defects that matter for a species-detection / wastewater-surveillance tool. This spec hardens it. See memory `project-twelve-s-abundance-reassignment` for the full adjudication.

## Decisions (expert-adjudicated)

1. **Per-sample resolution with local-presence-gated pooled fallback.** Choose the winner from each sample's own unambiguous counts. Pool across samples ONLY when a sample has no candidate clearing the local floor, and even then assign to the global winner only if it has `> 0` local presence — never fabricate a detection in a sample with no local signal.
2. **Persist reassignments + keep reassigned reads a distinct channel; never launder into `exact_match_reads`; never silently hide donor species.** Write a `reassignments.tsv` artifact; carry a per-sample `reassignedReads` count separate from `exactMatchReads`; donor species zeroed by reassignment stay visible in the viewport with an explicit annotation.
3. **Configurable threshold; keep the user's "any nonzero lead" as DEFAULT, add a `conservative` profile (≥2× fold ratio AND ≥10-read floor).** The user explicitly chose "any nonzero lead" in chat; we honor it as the default and add the safer named profile rather than overriding. Ties → unassigned, never lexical/random.

Plus three code-review items folded in: integration test for the workflow bookkeeping (M1), `::`-in-sampleID robustness in the matrix column scheme (M2), Wikipedia `/` encoding (L1).

## Design

### A. Reassigner: per-sample + threshold profile (pure)

`TwelveSAbundanceReassigner.reassign` is reworked to decide per `(sequence, sample)`:

```
enum ResolutionPolicy: Equatable, Sendable {
    case anyNonzeroLead                 // default (user's choice): strict plurality, winner > 0
    case conservative(minFoldRatio: Double, absoluteFloor: Int)  // e.g. (2.0, 10)
}
```

`reassign(ambiguousCandidates:unresolvedCounts:countsByTarget:speciesForTarget:canonicalTargetForSpecies:policy:)`:
- Precompute per-species per-sample unambiguous totals `u[species][sample]` from `countsByTarget` via `speciesForTarget`, and global `u[species][•]`.
- For each ambiguous sequence (sorted) and each sample it has reads in:
  - candidate species = distinct species among the sequence's candidate targets; require ≥2 (else skip — single-species residual is the classifier's job).
  - **Tier 1 (per-sample):** rank candidates by `u[species][sample]`; the top passes iff it satisfies `policy` against the runner-up using the sample's own counts (`anyNonzeroLead`: strict-max and `>0`; `conservative`: `top ≥ minFoldRatio × runnerUp` AND `top ≥ absoluteFloor`). If it passes → assign this sample's reads of this sequence to the winner's canonical target.
  - **Tier 2 (pooled fallback):** only if Tier 1 abstains for this sample — pick the global winner by `u[species][•]`; assign this sample's reads to it ONLY if `u[globalWinner][sample] > 0` AND it satisfies the policy globally; otherwise leave this `(sequence, sample)` unassigned.
- Moves are now per `(sequence, sample, toTarget)`; `Move` gains `sample` and `decidedBy: .perSample | .pooled`. Reads not assigned stay in `unresolvedCounts`.
- Conservation unchanged: every read is either moved to exactly one target or remains unresolved; total in == total out (unit-tested).

The default `policy` passed by the workflow is `.anyNonzeroLead`. The CLI exposes `--ambiguity-resolution strict|conservative` (strict = anyNonzeroLead; conservative = `(2.0, 10)`), defaulting to `strict`.

### B. Workflow: distinct reassigned channel + persisted evidence

- `ClassifiedReads` gains `reassignedReadsBySample: [String: Int]` and `reassignmentMoves: [TwelveSAbundanceReassigner.Move]`.
- `applyAbundanceReassignment`: instead of folding moved reads into `exactReadsBySample`, add them to `reassignedReadsBySample` (still subtract from `ambiguousReadsBySample` per sample, since they're no longer ambiguous). Keep crediting `countsByTarget[toTarget]` (so per-species per-sample counts reflect the assignment) BUT also record per-target reassigned reads so the count can be shown as "exact + reassigned." Store `result.moves` in `classified.reassignmentMoves`.
- `TwelveSAmpliconSampleResult` gains `reassignedReads: Int` (default 0 for back-compat). `makeSamples` sets it; `exactMatchReads` now means private-site exact reads only, with reassigned tracked separately; `unresolvedReads = inputReads - exactMatchReads - reassignedReads`. Read-fate JSON gains `reassignedReads`.
- New artifact `reassignments.tsv` (sequence, sample, toSpecies, toTarget, reads, decidedBy, candidateSpecies). Manifest gains optional `reassignmentsTablePath: String?` (nil for pre-existing bundles → loader tolerates absence). Bundle data exposes `reassignments: [TwelveSReassignmentRecord]` (empty when absent).
- Provenance: the `os.Logger` line stays; the tsv is the durable record.

### C. Viewport: keep donor species visible

`TwelveSScientificNameCountRow` / the bundle expose which species were reassignment *donors* (had candidates that lost) and *recipients*. Minimal approach that doesn't bloat the row model: the viewport reads `bundleData.reassignments` and, for the "hide all-zero rows" rule, exempts a species that is a donor (appears in any `candidateSpecies` but is not the `toSpecies`) so a fully-absorbed rare species still shows with `0` reads. Optionally annotate its row (e.g. an "also_matches" / reassignment note) — display-only, no count change. If `reassignments` is empty (old bundle or strict default with no moves), behavior is exactly as today.

### D. Code-review fixes folded in

- **M2 (`::` in sample IDs):** percent-encode the sampleID component when building matrix column IDs in `TwelveSSampleMatrixColumns`, and decode on parse — so a sample literally named `plate::A1` round-trips. Add a test.
- **L1 (Wikipedia `/`):** in `TwelveSSpeciesLinks.wikipediaURL`, also encode `/` (and `#`,`?` already handled) so a name like `X/Y` doesn't create a spurious path segment. Add a test.
- **M1 (integration test):** add a `LungfishWorkflowTests` test with two references sharing an identical core (genuinely `.ambiguous`) plus abundance evidence elsewhere; run the workflow and assert per sample: `exactMatchReads + reassignedReads + unresolvedReads == inputReads`, `ambiguousExactReads >= 0`, and `sum(countsByTarget[*][sample]) == exactMatchReads[sample] + reassignedReads[sample]`. This covers the bookkeeping the unit tests can't reach through the private `classifyInputs`.

## Non-Goals (YAGNI for now; documented in memory)

- Fractional/EM allocation of ambiguous reads (offered as a future mode; hard plurality is the integer special case).
- Unique-fraction normalization of the abundance signal (documented bias; not implemented now).
- FDR/multiplicity control beyond the floor+ratio gate.

## Testing (phased TDD; green bar)

- **Reassigner unit:** per-sample winner differs from global (the X:5000/0, Y:0/800 counterexample → A→X, B→Y); pooled fallback only when local abstains; fallback blocked when global winner has 0 local presence; `conservative` profile floor+ratio (4-vs-3 stays unresolved under conservative, resolves under anyNonzeroLead); ties unassigned; read conservation; `Move` carries sample + decidedBy.
- **Workflow integration (M1):** as above.
- **IO:** `reassignments.tsv` round-trips; manifest optional path tolerated when absent (old bundle loads).
- **Leaf:** donor species not hidden by hide-zero when it appears in `reassignments`; matrix column `::` round-trip (M2); Wikipedia `/` encoding (L1).
- **Regression:** full suite green (failures ⊆ environmental/skipped; swift-testing 0).
- **GUI smoke:** re-profile a 12S dataset with a human/pan-style ambiguity; confirm reassignment, donor row still visible, reassignments.tsv exported; toggle `conservative` via CLI and confirm fewer/no low-margin moves.

## Files Expected to Change

- `Sources/LungfishWorkflow/TwelveS/TwelveSAbundanceReassigner.swift` (per-sample + policy + Move shape)
- `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift` (reassigned channel, persist moves, write reassignments.tsv, samples/read-fate fields, policy from config)
- `Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift` (manifest `reassignmentsTablePath?`, `TwelveSReassignmentRecord`, sample `reassignedReads`, loader)
- `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift` (donor-row exemption in hide-zero)
- `Sources/LungfishTwelveSUI/TwelveSSampleMatrixColumns.swift` (sampleID encode/decode — M2)
- `Sources/LungfishTwelveSUI/TwelveSSpeciesLinks.swift` (`/` encoding — L1)
- CLI 12S command (add `--ambiguity-resolution`, default strict)
- Tests across `LungfishWorkflowTests`, `LungfishTwelveSUITests`, IO tests.

## Rollout

1. Reassigner per-sample + policy (pure, TDD).
2. Workflow reassigned-channel + persisted reassignments.tsv + IO + M1 integration test.
3. Viewport donor-row visibility.
4. CLI `--ambiguity-resolution` flag.
5. M2 + L1 small fixes.
6. Full suite + GUI smoke.
