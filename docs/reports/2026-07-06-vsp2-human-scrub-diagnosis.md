# VSP2 Human-Scrub Diagnosis

Date: 2026-07-06

Issue: [#23](https://github.com/dhoconno/lungfish-genome-explorer/issues/23)

## Finding

The shipping VSP2 import path does run the JSON v2 `deacon-scrub` step. The root defect found in this checkout was not a skipped scrub step, but an observability and provenance gap: Deacon's native per-run summary was not retained in the final `.lungfishfastq` bundle, and the recipe provenance could not point at a durable copy of that summary. That made it difficult to distinguish "human scrub did not run" from "Deacon removed detectable human reads, but a downstream classifier still reports a residual human fraction."

The fix records Deacon's JSON summary with `--summary`, copies it into `metadata/recipe-step-artifacts/` in the final bundle, rewrites the recorded argv so replay provenance points at the final stored artifact, and includes the summary artifact as a checksummed provenance output. The app and CLI-facing import log also surface the human-scrub read delta when the recipe step has input and output counts.

## Evidence

Recipe reconciliation showed the shipping `--recipe vsp2` path resolves to `vsp2-target-enrichment` and executes these JSON v2 steps:

1. `fastp-dedup`
2. `fastp-trim`
3. `deacon-scrub`
4. `fastp-merge`
5. `seqkit-length-filter`

The local Deacon install is available at:

```text
/Users/dho/.lungfish/conda/envs/deacon/bin/deacon
```

`deacon filter --help` confirms the relevant runtime defaults and summary option:

```text
--abs-threshold <ABS_THRESHOLD>  default: 2
--rel-threshold <REL_THRESHOLD>  default: 0.01
-d, --deplete
-s, --summary <SUMMARY>
```

The installed human-scrub database is:

```text
/Users/dho/.lungfish/databases/deacon-panhuman/panhuman-1.k31w15.idx
size: 3.1G
sha256: a1577a1026c764c315aeda26023836545e76c62c5867bd50d5ca40518c0a71e6
manifest version: panhuman-1
manifest releaseDate: 2025-04-01
source: https://zenodo.org/records/15118215
```

The focused integration test `FASTQBatchImporterRecipeIntegrationTests/testRunBatchImportVSP2RetainsDeaconSummaryArtifactAndProvenance` performs a real VSP2 import with managed `fastp`, `seqkit`, and `deacon`, then verifies:

- The final bundle contains `metadata/recipe-step-artifacts/2-1-remove-human-reads-vsp2_deacon_summary.json`.
- The summary JSON reports `deplete: true`, a positive `seqs_in`, and a `seqs_removed` field.
- `RecipeAppliedInfo.humanScrubSummary` is available when step counts are present.
- `provenance.json` includes the retained Deacon summary as a checksummed output.
- `durableReplayArgv` points at the final bundle artifact path, not the temporary workspace path.

Verification command:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/weekly-issues-plans --skip-update --filter 'RecipeAppliedInfoSummaryTests|FASTQBatchImporterTests/testRecipeProvenanceIncludesAuxiliaryOutputsWithDurableReplayPaths|RecipeIntegrationTests/testFullVSP2RecipeExecutionCapturesDeaconSummaryArtifact|FASTQBatchImporterRecipeIntegrationTests/testRunBatchImportVSP2RetainsDeaconSummaryArtifactAndProvenance'
```

Result on 2026-07-07: 6 tests passed, 0 failed.

## Residual Human Fraction

This checkout does not include the ORCHARDS dataset or the Kraken2 standard database used in the issue report, so the exact reported 2-5% Kraken2 human fraction could not be reproduced here. The implemented change is intentionally conservative: it does not tighten Deacon thresholds or add a second host-filtering pass without dataset evidence that Deacon is under-removing true human reads. Instead, it preserves Deacon's authoritative depletion summary in the output bundle so the next run on ORCHARDS can compare:

- Deacon `seqs_in` and `seqs_removed` from the retained JSON summary.
- VSP2 recipe read deltas shown in bundle metadata and import logs.
- Downstream Kraken2 human classification fraction.

If Deacon removes the expected human reads but Kraken2 still reports 2-5% human, the remaining fraction is likely a classifier/reporting artifact or conserved sequence signal rather than raw human reads passing through unfiltered. If Deacon's summary shows low removal on human-spiked or ORCHARDS data, the next fix should be a data-backed threshold change or second-pass host filter.

## Decision

Do not change Deacon matching thresholds in this pass. Preserve and surface the run summary first, because missing scientific provenance was the blocking defect for this issue and for later VSP2 debugging.
