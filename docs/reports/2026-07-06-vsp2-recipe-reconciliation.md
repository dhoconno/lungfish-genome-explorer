# VSP2 Recipe Reconciliation

Date: 2026-07-06

This report reconciles the two VSP2 recipe representations before implementing issues #23, #24, and #27.

## Finding

The shipping CLI import path resolves `--recipe vsp2` to the JSON v2 recipe `vsp2-target-enrichment` from `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json`. `ImportFastqCommand.resolveImportRecipe(named:)` maps the `vsp2` alias to `vsp2-target-enrichment`, searches `RecipeRegistryV2.allRecipes()`, and only falls back to `FASTQBatchImporter.resolveRecipe(named:)` if no JSON recipe matches. The GUI import paths that pass `FASTQImportConfiguration.recipeName` also prefer the v2 recipe id, including the Database Browser helper that maps legacy VSP2 selections to the JSON recipe id.

The legacy Swift `ProcessingRecipe.illuminaVSP2TargetEnrichment` still exists and `FASTQBatchImporter.resolveRecipe(named: "vsp2")` still returns it for older callers and tests, but that is not the normal shipping path for `lungfish import fastq --recipe vsp2`.

## Ordered Runtime Steps

The JSON v2 recipe executes through `RecipeEngine` in this order:

1. `fastp-dedup`, labeled `Remove PCR duplicates`
2. `fastp-trim`, labeled `Adapter + quality trim`
3. `deacon-scrub`, labeled `Remove human reads`
4. `fastp-merge`, labeled `Merge overlapping pairs`
5. `seqkit-length-filter`, labeled `Remove short reads`

After the recipe finishes, `FASTQBatchImporter.processSingleSample` always runs the ingestion stage. When `optimizeStorage` is true this stage is labeled `Clumpify + Compress` and uses `FASTQIngestionPipeline` with `skipClumpify: false`; when storage optimization is disabled it is labeled `Compress` and skips clumpify. This means the VSP2 deduplication step is currently `fastp-dedup` inside the JSON recipe, while read reordering/compression clumpification is a separate post-recipe ingestion step.

## Read-Count And Provenance Consequences

The JSON recipe path does not currently produce usable per-step read counts. `RecipeEngine.execute` starts `previousReadCount` as `nil` and records `inputReadCount: previousReadCount` and `outputReadCount: currentOutput.readCount`, but the current VSP2 step executors return `StepOutput(..., readCount: nil)`. This includes `FastpDedupStep` and `DeaconScrubStep`. Therefore #24 cannot rely on existing `RecipeAppliedInfo.stepResults` counts; implementation must add count collection for the JSON recipe path or parse authoritative tool reports before surfacing dedup and scrub deltas.

The post-recipe `Clumpify + Compress` result is appended to `recipeStepResults`, but its `inputReadCount` and `outputReadCount` are also `nil`. If #27 changes the clumping tool, final bundle provenance and resolved/default import options must identify the actual clumping tool and must rehydrate any staging/workspace paths to final bundle payload paths.

## Evidence

Source trace:

- `Sources/LungfishCLI/Commands/ImportFastqCommand.swift` maps `vsp2` to `vsp2-target-enrichment` and resolves via `RecipeRegistryV2.allRecipes()` before legacy fallback.
- `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` dispatches `config.newRecipe` to `RecipeEngine` and appends the post-recipe ingestion step.
- `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json` contains the five-step JSON v2 recipe listed above.
- `Sources/LungfishWorkflow/Recipes/RecipeEngine.swift` records read counts only from `StepOutput.readCount`.
- `Sources/LungfishWorkflow/Recipes/Steps/FastpDedupStep.swift` and `Sources/LungfishWorkflow/Recipes/Steps/DeaconScrubStep.swift` return `StepOutput` without a read count.

Verification command:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/weekly-issues-plans --skip-update --filter ImportFastqE2ETests/testDryRunWithVSP2Recipe
```

Result: pass on 2026-07-06. This confirms the CLI accepts the shipping `--recipe vsp2` path without requiring legacy recipe fallback for dry-run planning.
