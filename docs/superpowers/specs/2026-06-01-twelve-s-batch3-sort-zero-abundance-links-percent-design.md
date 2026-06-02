# 12S Viewport Batch 3: Default Sort, Hide Zero Rows, Abundance-Based also_matches, Species Links, % Column

Date: 2026-06-01
Status: Approved design
Owners: `LungfishTwelveSUI` (leaf) + `LungfishWorkflow` (read classifier/workflow) + `LungfishApp` (glue), reusing existing patterns.

## Problem / Requests

1. **Default sort** should always be number-of-reads descending.
2. **Hide all-zero rows**: do not show a species row whose read count is 0 across all currently-shown samples.
3. **Abundance-based `also_matches`**: when a read's 12S sequence is identical between two species (e.g. human with 1000 reads and *Pan troglodytes* with an identical 12S), group it with the more abundant species rather than calling it the rarer one — analogous to the chimera "abundant explanation wins" rule.
4. **Right-click species actions**: "Learn More About <species>" (open NCBI Taxonomy) and "View Photo of <species>" (open Wikipedia), in the browser.
5. **% column**: a column showing each species' mapped reads as a percentage of all exact-match reads across all 12S species in that sample.

## Decisions (locked during brainstorming)

1. **Reassignment lives at COUNT time** in the read classifier/workflow (not display-time): cross-species identical-sequence ambiguous reads are assigned to the most-abundant candidate species. Durable, written into the bundle + exports.
2. **Species links open the browser immediately, no per-click confirmation** (user-authorized in chat; see memory `feedback-external-link-opening`). NCBI by taxid with a name-search fallback; Wikipedia by scientific name. No in-app image fetching.

## Key Findings (grounding)

- **Default sort** is already `totalExactReads` descending in `TwelveSAmpliconResultViewController.applyDefaultSortIfNeeded()`. Item #1 is largely satisfied; this spec makes it robust (re-assert on every `configure`, not only when empty) and ensures it remains the default after mode/sample changes.
- **Read assignment is count-time.** `TwelveSAmpliconReadClassifier.classify(readSequence:)` returns `.exact/.ambiguous/.unresolved`; `resolveExactMatches` already collapses *same-species* identical sequences (longest-wins) but returns `.ambiguous(targetIDs:)` for *cross-species* ties (`TwelveSAmpliconReadClassifier.swift:175–210`). `TwelveSAmpliconMatchingWorkflow.classifyInputs()` (lines 279–293) currently routes `.ambiguous` reads into `unresolvedCounts`, **discarding the candidate target IDs** (the `case .ambiguous:` binding is dropped at line 286).
- **`sampleExactReadTotals[sampleID]`** = total exact-match reads across ALL species for that sample (from `TwelveSAmpliconSampleResult.exactMatchReads`). This is the correct denominator for the % column. The detail pane already computes `percentOfSampleExactReads = sampleCounts[sid] / sampleExactReadTotals[sid] * 100`.
- **External-link idiom exists**: `NSWorkspace.shared.open(url)` with `https://www.ncbi.nlm.nih.gov/datasets/taxonomy/<taxid>/` (TaxonomyViewController) and `.../nuccore/<accession>` (NvdResultViewController). Taxids are on `TwelveSScientificNameCountRow.taxids`.
- **No image infra** — Wikipedia-in-browser avoids needing any.

## Design

### Change 1 + 2 + 5 — Leaf UI (no data change)

All three are display-layer changes in `TwelveSTargetTableView` / `TwelveSAmpliconResultViewController`.

**Default sort (1).** `applyDefaultSortIfNeeded()` becomes `applyDefaultSort()` and is called unconditionally from `configure(result:)` after building rows, setting targets to `totalExactReads` desc and unresolved to `readCount` desc. (Users can still re-sort; this only sets the initial/default order, and we no longer skip it when a descriptor happens to exist from a prior bundle.)

**Hide all-zero rows (2).** In `applyFilters`, after the display-state predicate (and the existing sample-subset drop), also drop any target row whose summed reads across the **shown** samples is 0:
- shown samples = the selected sample subset if a strict subset is active, else all samples.
- predicate: `TwelveSRowAggregator.totalExactReads(row, selected: shownSampleIDs) > 0` (when no picker is wired, fall back to `row.totalExactReads > 0`).
This is unconditional (not a toggle) per the request. A species with reads only in a non-shown sample correctly disappears until that sample is shown again.

**% column (5).** Add a fixed column `samplePercentOfTotal` — but it is **per-sample**, so it belongs in the per-sample matrix block, parallel to the reads column. Extend `TwelveSSampleMatrixColumns`:
- new id form `sample::<sampleID>::pct`
- `pctValue(row, sampleID)` = `count(forSample:) / sampleExactReadTotals[sampleID] * 100`, formatted `"%.1f%%"` (empty/`"0.0%"` when denominator 0).
- `setSampleColumns` gains a `showPercent: Bool` (defaulting the same way reads do — auto for ≤8 samples, toggle via the Sample Columns menu). Column title `"<sample> % of sample"`.
- `cellContent`/`columnValue`/`compareRows`/`columnTypeHints` route `.pct` as numeric (compare on the computed Double).

(The single-sample case still gets one `% of sample` column, which directly answers "what fraction of this sample's 12S reads is this species.")

### Change 3 — Abundance-based cross-species reassignment (count time)

`LungfishWorkflow`. Two-pass within `classifyInputs`:

1. **Pass A (unchanged classification).** Classify unique sequences. Retain, for each `.ambiguous` sequence, its candidate `targetIDs` (stop discarding them): add `classified.ambiguousCandidates: [String: [String]]` (normalizedSequence → candidate targetIDs) and keep accumulating those reads into `unresolvedCounts` for now.
2. **Pass B (abundance reassignment).** After Pass A, compute per-species exact-read totals from `countsByTarget` (map each targetID → species via the target table's `scientificNameKey`, sum across samples). Then for each ambiguous sequence with candidates spanning multiple species:
   - Map candidate targetIDs → candidate species; look up each species' Pass-A exact total.
   - If exactly one species has the strict maximum total **and** that maximum is `> 0` and beats the runner-up by the policy margin, reassign: move that sequence's per-sample reads out of `unresolvedCounts` and into `countsByTarget[canonicalTargetID]` (canonical = the candidate target of the winning species; if several, longest reference sequence then smallest targetID, matching `resolveExactMatches`). Also add those reads to `exactReadsBySample` and remove from `ambiguousReadsBySample`.
   - **Tie / no-winner** (all candidates 0, or a tie for the max): leave as ambiguous/unresolved (current behavior). No guessing without an abundance signal.
   - **Policy margin**: require the winner's total strictly greater than every other candidate species' total (a plurality, like chimera). Document that "1000 vs identical-seq pan with 0 own exact reads" → human wins; "500 vs 500" → stays ambiguous.
   - Record reassignments in the workflow's provenance/log (count of reads moved, and per ambiguous sequence the from→to species) so the decision is auditable, mirroring chimera logging.

This changes counts only for genuinely abundance-resolvable cross-species ties; everything else is unchanged. Existing bundles are unaffected until re-run (acceptable; data-level correctness is the goal). A focused unit test drives the classifier+workflow with a synthetic dataset (human 1000 reads exact + an ambiguous human/pan sequence) and asserts the ambiguous reads land on human.

**Pure, testable core.** Extract the reassignment as a pure function
`TwelveSAbundanceReassigner.reassign(ambiguousCandidates:unresolvedCounts:countsByTarget:speciesForTarget:canonicalTargetForSpecies:) -> (countsByTarget, unresolvedCounts, moves)` so it is unit-tested without running the FASTQ reader.

### Change 4 — Right-click species links (leaf + browser)

`TwelveSSpeciesLinks` (pure URL builders, leaf, unit-tested):
- `ncbiTaxonomyURL(taxid: String?, scientificName: String) -> URL`:
  - taxid present → `https://www.ncbi.nlm.nih.gov/datasets/taxonomy/<taxid>/`
  - else → `https://www.ncbi.nlm.nih.gov/datasets/taxonomy/?term=<percent-encoded scientificName>`
- `wikipediaURL(scientificName: String) -> URL` → `https://en.wikipedia.org/wiki/<scientificName with spaces→underscores, percent-encoded>`

Context menu (`TwelveSCopyMenuProvider.populateTargetMenu`): when exactly one target row is selected, append a separator + **"Learn More About <species>"** and **"View Photo of <species>"**. Each item carries the built URL and, via the existing `TwelveSCopyActionTarget` closure mechanism, calls a leaf callback `onOpenURLRequested: ((URL) -> Void)?` on the VC. The VC's default wiring opens immediately with `NSWorkspace.shared.open(url)` (the leaf may call `NSWorkspace` directly — `AppKit` is available in the leaf — so no App glue is strictly required; but expose `onOpenURLRequested` so the App can override/log if desired). No confirmation prompt (authorized).

Menu items use the row's `scientificName` for the label and `taxids.first` for the NCBI taxid.

## Edge Cases

- **No taxid** → NCBI name search (handled by the builder).
- **Scientific name with spaces/odd characters** → percent-encoded; Wikipedia uses underscore-for-space then encodes.
- **Multi-row selection** → species links omitted (they're single-species actions); copy items remain.
- **% column denominator 0** (sample with no exact reads) → shows `0.0%`.
- **Hide-zero interaction with filters** → zero-row drop runs after display-state + sample-subset filters, before kernel free-text/column filters narrow further. Re-evaluated on sample-selection change so showing/hiding samples re-includes/excludes rows correctly.
- **Reassignment determinism** → candidate ordering and canonical pick are deterministic (sorted IDs, longest-then-smallest-ID), so results are reproducible.
- **Reassignment must not double-count** → reads are *moved* (subtracted from unresolved, added to the target), asserted by a conservation test (total reads in == out).

## Testing (phased TDD; green bar)

- **Leaf unit:** `% of sample` value + compare + numeric hint; default-sort applied on configure; all-zero rows dropped (and reappear when the sample is reselected); `TwelveSSpeciesLinks` URL builders (taxid, no-taxid name search, Wikipedia encoding); context menu shows the two species items only for single selection.
- **Workflow unit:** `TwelveSAbundanceReassigner.reassign` — human-wins case, tie stays ambiguous, all-zero stays ambiguous, read conservation; plus a higher-level classifier+workflow test on a synthetic dataset.
- **App:** species-link callback opens (verify the URL passed to a `onOpenURLRequested` seam, not the real browser).
- **Regression:** existing 12S leaf/Inspector/workflow tests + full suite stay green (failures ⊆ environmental/skipped; swift-testing 0).
- **GUI smoke (binding):** default sort reads-desc; no all-zero rows; the % column; right-click → Learn More opens NCBI, View Photo opens Wikipedia; (if a suitable bundle exists) an also_matches case folds into the abundant species after re-run.

## Files Expected to Change

Workflow:
- `Sources/LungfishWorkflow/TwelveS/TwelveSAbundanceReassigner.swift` (new, pure)
- `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift` (retain ambiguous candidates; call reassigner; provenance log)

Leaf:
- `Sources/LungfishTwelveSUI/TwelveSSampleMatrixColumns.swift` (add `.pct` kind + value)
- `Sources/LungfishTwelveSUI/TwelveSTargetTableView.swift` (pct column routing; `showPercent`)
- `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift` (default sort on configure; hide-zero filter; pct in rebuildSampleColumns + Sample Columns menu; `onOpenURLRequested`)
- `Sources/LungfishTwelveSUI/TwelveSSpeciesLinks.swift` (new, pure URL builders)
- `Sources/LungfishTwelveSUI/TwelveSCopyMenuProvider.swift` (species menu items)

App:
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift` (wire `onOpenURLRequested` → `NSWorkspace.shared.open`, or rely on the leaf default)

Tests: new `TwelveSAbundanceReassignerTests`, `TwelveSSpeciesLinksTests`; additions to `TwelveSSampleMatrixColumnsTests`, `TwelveSTableViewTests`, `TwelveSCopyMenuTests`.

## Rollout

1. Default sort + hide-zero + % column (leaf-only, immediate).
2. Species links (leaf URL builders + menu + open).
3. Count-time abundance reassignment (workflow, pure-core TDD).
4. Full suite + GUI smoke.
