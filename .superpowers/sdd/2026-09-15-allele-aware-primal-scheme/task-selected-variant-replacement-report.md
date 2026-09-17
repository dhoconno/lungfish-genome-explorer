# Selected omitted-variant replacement diagnostic — ready for independent review

## Status and verified inventory

External code/tests only; no production or frozen native edits, no history database reads, no new discovery. **Real replacement trials have not run.** The authorized receipt-bound inventory of the completed audited narrow09 panel succeeded in4.8093s, exit0, all source/runtime/input identities unchanged.

The19 selected configurations include3 proper-subset configurations and5 omitted eligible variants (3LEFT,2RIGHT):

| Selected configuration | Display pool | LEFT retained/eligible | RIGHT retained/eligible | Omitted |
|---|---:|---:|---:|---:|
| `SelectionConfiguration-03bade7c4d7da4efeb4c10a1b44eb57cd33f7c262b3c323139abe1620807d65a` |1|5/7|3/3|2|
| `SelectionConfiguration-1550e84522a22e177496260d95bbe140f64ad98029ac9c36990141cc0ec356bd` |2|2/2|2/3|1|
| `SelectionConfiguration-4cf46a82eb3aae7e102f9fe43ca837d918cbc0fe3e7ab8566701933ce3373bff` |2|2/3|4/5|2|

Inventory artifacts: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-narrow09-omitted-variant-inventory-01/`. Summary explicitly records examined0 and inventory-only statuses. Its script bytes are preserved in the frozen review directory below. These counts establish the user's2-of3RIGHT case, but do not establish why any variant was omitted.

## Frozen review package

- Script: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-variant-replacement-frozen01/diagnose.py` — SHA256 `e3061ed3828dfe37704e5b892e08d46b395692bf060b663cea21a3687ae31369`, 19977bytes.
- Tests: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-variant-replacement-frozen01/test_diagnose.py` — SHA256 `725fce7c7cb289650028999c75f67f68082d16e06ea47b46275c812250290739`, 11985bytes.
- Test receipts/logs: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-variant-replacement-verification-01/`.
- Development copies: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-variant-replacement-v1/`.

## Scientific procedure

1. Reuse the hash-pinned, independently reviewed background-panel receipt verifier and streaming catalog reader. Require completed successful panel, whole-primary-tier fresh raw audit, stable outer wrapper output bindings, exact source files/runtime match to running frozen matrix09, and raw stored-input hashes. No externally supplied untrusted Python helper is allowed without its frozen expected hash.
2. Stream selected configurations from the complete ledger. Retain every target/observation and every site in each selected family, with complete family membership. Create an explicitly partial diagnostic projection with **its own** semantic digest; original complete catalog digest is provenance only. Persist projection and selected configuration records. Reparse raw inputs and compare every target and canonical observation.
3. Enumerate omitted eligible sites in deterministic pool/configuration/strand/site-ID order. Record all omissions, with unexamined work-limit statuses. Default16/max1000; this panel needs only5 to be exhaustive over one-site replacements.
4. Before any trial, freshly validate the whole original selected panel against the projection. Require exact coverage/support, assignment/pool, numerical physical-pool exposure, selected-site and allowed/uncertain witness-multiset parity with saved validation. Catalog digest and validation-scope fields necessarily differ; they are not forged to match the original complete catalog. Require original strict policy/profile and goal.
5. For each omitted site, add exactly that site to its family's retained F/R subsets with native `make_configuration`. **Replace** the old assignment with the new ID in the same pool, removing the old configuration from the trial ledger. All other assignments remain fixed. No insertion alongside the old amplicon, no optimization, no pool transfer, no prior trial accumulation.
6. Freshly run `validate_allele_assignments` over the entire replacement panel and all supplied raw rows. Save complete validation JSON.gz plus all fresh evidence/assessment records. Validation `pools` retains every numerical dimer edge, exact score, orientation offsets/scores, kernel, physical sequences, owner configuration/site IDs, active violations and exposure counts; violations preserve specificity witnesses. No failed edge or witness truncation.
7. Report omitted-site binding support for every observed class, rebuilt configuration/assignment IDs, validity/reason counts, and per-class exact-binding coverage before/after/delta. Coverage deltas of invalid panels are explicitly geometric exact-binding deltas, **not feasible coverage**. Compatible additions are labeled `compatible-with-current-panel/omission-cause-not-inferred`; current incompatibility is not asserted to be the historical search decision's cause.

## Verification

TDD initial failure: missing `diagnose` module (`/tmp/replacement-red.log`). Fresh frozen package: **11passed0.77s**, exit0. Ruff check/format passed. Tests cover replacement-versus-insertion, retained pools/other assignments,2-of3RIGHT support gain on only the newly supported row, omitted inventory/work limits, native numerical edge/evidence retention, complete family projection with new digest, witness-multiset/physical exposure/pool parity, hash-pinned helper rejection, retained failure/output-conflict receipts, and changed-input fail-closed behavior. The native numerical regression includes blocked edges and therefore checks retention rather than pretending its synthetic panel is valid.

Exact focused test command:

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix09/.venv/bin/python -m pytest -q /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-variant-replacement-frozen01/test_diagnose.py
```

The real inventory exercised all receipt/source/runtime/raw-row/projection loading with actual audited narrow09 artifacts; it intentionally skipped fresh validation/trials.

## Proposed real command — awaiting root review/authorization

Working directory `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development`:

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix09/.venv/bin/python selected-variant-replacement-frozen01/diagnose.py --panel mamu-a1-cached-narrow09-3600-01 --audit mamu-a1-cached-narrow09-3600-01-audit --execution-receipt mamu-a1-cached-narrow09-3600-01-execution/provenance.json --background-helper fixed-panel-background-screen-frozen01/background_screen.py --stream-helper optimistic-catalog-coverage-frozen01/optimistic_catalog_coverage.py --output mamu-a1-narrow09-one-variant-replacement-01 --max-variants 5
```

Scope limits: five independent one-site extensions of the current selected families/pools only. No multi-site combination, alternative family, pool relocation, global ceiling, experimental amplification, all11 background, or inference of historical omission cause. Each context uses full native validation; no timeout interrupts a kernel. Completed trial files survive later failure, and the receipt marks any failure or source/runtime/input drift. The original panel remains unchanged.


## Completed five-trial results and receipt-bound interpretation

Root independently reviewed the frozen diagnostic and reran its11tests (passed0.85s), then executed all5 independent replacements at `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-narrow09-one-variant-replacement-01`. The scientific diagnostic completed exit0 in31.1218s; baseline parity true; source/runtime/input identities unchanged; no omissions unexamined.

A separate standard-library-only saved-output interpretation was executed without new hit searches or kernel calls:

- Human report: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-narrow09-one-variant-interpretation-02/report.md` (SHA256 `2553e8512735a7800d7f8923c0da577366882809e23263af0f0b51a89a01e456`,14,094bytes).
- Machine-readable exact edges, owners, labels and class deltas: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-narrow09-one-variant-interpretation-02/analysis.json` (SHA256 `ab22b4f4723fef10bfceb23178f35b0936b724b48007110207d1a6234c9ce581`,56,772bytes).
- Separate provenance: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-narrow09-one-variant-interpretation-02/provenance.json`, binds16 consumed files to the original successful diagnostic receipt and checks their bytes again at end; exact argv/runtime/source/outputs/status/time retained. Exit0, identities unchanged,0.754s.
- Interpretation script: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-variant-replacement-analysis-v1/analyze.py`, SHA256 `6c7ef8830fe316bda54cdefffc4d94c1f6bafc376ee208333fd69c4cf48a2c51`. Ruff passes. Assertions independently checked all5 same-pool replacements against original assignments, class interval/count deltas and added-sequence ownership of every new failing edge.

### Findings

| Trial | Original→replacement reference interval | Pool | Original retained/eligible F;R | Current replacement result |
|---|---|---:|---|---|
|1|[2569,2815)→same|1|5/7;3/3|LEFT `AGGCTGATCCTGGAGATCCTTG` blocked by dimer|
|2|[2569,2815)→same|1|5/7;3/3|LEFT `GGCTGATCCTGGAGATCCTTG` blocked by dimer|
|3|[863,1067)→[863,1069)|2|2/2;2/3|RIGHT `TTTGTCTCCCCTCCTTGTGGGA` compatible, zero gain|
|4|[2164,2413)→same|2|2/3;4/5|LEFT `GGTTACTGGGAAGCACCATCC` compatible, zero gain|
|5|[2164,2413)→same|2|2/3;4/5|RIGHT `GGGCGGGATCAGGAAACAT` compatible, zero gain|

Trials1/2 each fail two physical dimer edges with selected partner RIGHT sequences `TCTCCTTCCCCTTCTCCAGG` (score−35.74489925046967) and `TCTCCTTCCCGTTCTCCAGG` (−34.446275623425315), owner configuration84ebe10… at[732,977), pool1. Strict rejection is≤−26. Each would give Mamu-A1*011:01:01:01 +200 observed bases inside that configuration and +67 previously uncovered bases across the panel, row interval[2605,2672); class fraction88.271394477%→90.555744971%. All other classes are unchanged, no losses. These two trial gains are the **same** interval and cannot be summed; neither is a valid-panel gain. The simultaneous `salvage-exposure-budget` reason denotes strict zero-allowed-exposure enforcement, not a salvage run.

Trials3–5 add zero exact covered bases even within their respective selected configuration, with zero loss in all6classes. They have actual exact site support already covered by retained variants. Trial3's worst added-sequence edge is−25.678905754 (three tied existing partner sequences, all reported), which passes. Trial4 worst−24.59178220979649; trial5 worst−19.837988370666668. All partners, coordinates, orientation scores and offsets are in the detailed report/JSON.

Specificity in every replacement-involving unary/pair context passes with zero rejected products and zero uncertainty. Stored allowed-nonexact-intended / secondary context occurrence counts: trials1/2 each40/159; trial3 25/239; trial4 34/223; trial5 30/226. These are check-context certificate occurrence counts, not unique physical products or exact-binding coverage credit. Full witness/evidence remains in each original trial artifact.

**Interpretation:** the real2-of3RIGHT case is compatible and coverage-redundant when expanded; this does not show dimer-forced omission. Two other omitted variants do encounter current strict dimer constraints. Neither observation establishes the optimizer's historical omission cause. All5 tests independently replace one original configuration; no panel is altered, no accumulated multi-addition compatibility is claimed.

The initial derived interpretation directory `...interpretation-01` is retained but superseded by02: inspection caught and corrected a prose claim that every full envelope was unchanged. Trial3 actually extends its outer endpoint1067→1069. Its original/replacement geometry was correct in JSON throughout, and all scientific source experiment files remain unchanged. Initial interpretation source is retained as `selected-variant-replacement-analysis-v1/analyze-initial-retained.py`.
