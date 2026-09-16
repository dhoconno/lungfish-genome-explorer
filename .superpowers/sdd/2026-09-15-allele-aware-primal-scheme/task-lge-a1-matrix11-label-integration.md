# Production LGE A1 matrix11 label integration

Date: 2026-09-16 America/Chicago (receipts use UTC)
Status: passed
Scope: one normal `lungfish-cli primers design primalscheme3` workflow against the original six-row Mamu-A1 `.lungfishmsa`, using the existing immutable discovery cache and the frozen matrix11 native executable, followed by text/JSON inspection, history, and a fresh audit. This was an engineering integration with a 60-second selector budget, not a search-quality or biological baseline run.

## Outcome

The production wrapper reused the complete A1 discovery cache without discovery fallback, preserved all six source-row labels and stable LGE row IDs, published the native and derived label maps with final-path provenance, and produced a bundle that passed saved inspection, history, and fresh native audit.

- Result ID: `F61458CD-4513-4DDF-ADE7-232C853A4773`
- Analysis ID: `72C5ADD7-8A44-4965-AA84-1EC0121F05B7`
- Discovery reused: `true`
- Actual discovery workers: `0` globally and for every target/profile
- Target, observed rows, and distinct classes: `1`, `6`, `6`
- Selected amplicons/assignments: `22`
- Modeled mean coverage: `0.6807121517609077`
- Allowed intended products: `528`
- Allowed secondary products: `2442`
- Fresh audit: `valid: true`, `raw_inputs_reparsed: true`, exact audited stage set `{strict}`
- Label audit: `{advertised: true, valid: true, path: allele-label-map.json, targets: 1, rows: 6, classes: 6}`
- Source bundle unchanged: `true`
- Discovery cache unchanged: `true`

Retained root:

`/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01`

Primary outputs:

- LGE bundle: `design.lungfishprimeranalysis`
- Strict history query: `history-query`
- Fresh audit: `fresh-audit`
- Exact outer command receipts and stdout/stderr: `execution`
- Input/cache inventories before and after: `input-snapshot-before.json`, `input-snapshot-after.json`
- Independent assertions: `verification.json`

## Immutable identities

### LGE wrapper

- Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli`
- Label bridge commit under test: `6a5a2f2e9`
- CLI: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli`
- CLI SHA-256: `a3c3f917680d87e3c1e837b64d2260f23ef04d9d78d350367650b0670f05cb90`
- CLI size: `183702912` bytes

### Frozen native matrix11

- Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11`
- Commit: `236e74af6b186367fd66f15e73b558a0c3e44a74`
- Executable: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11/.venv/bin/primalscheme3`
- Entry-point SHA-256: `1918d1f4e47d178060af3c7f6785e6a544ec8a4792172fe76205b924e17657a1`
- Entry-point size: `383` bytes
- Capability source digest: `326e51fc62de3e206447668a7f19dcf9b0c3c3fbdcd02cadd88cb86dd28d8e80`

### Source and cache

- Source `.lungfishmsa`: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-fixture-snapshot-v3/snapshot/source-inputs/C64AA855-086A-4BBB-8AB7-803F0FAC0212/source.lungfishmsa`
- Source inventory: 13 files, `613515` bytes
- Source aligned FASTA SHA-256: `668a009c6e5adf706dca189100f0e0d5e3df63d68ced96865cfb73ad2f67e13e`
- Cache: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-discovery-cache-01`
- Cache inventory: 7 files, `5384968141` bytes

The after snapshot exactly matched every source and cache relative path, size, and SHA-256 from the before snapshot.

## Exact design command

Working directory:

`/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli`

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli primers design primalscheme3 \
  --msa /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-fixture-snapshot-v3/snapshot/source-inputs/C64AA855-086A-4BBB-8AB7-803F0FAC0212/source.lungfishmsa \
  --output /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/design.lungfishprimeranalysis \
  --grouping combined \
  --primalscheme3-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11/.venv/bin/primalscheme3 \
  --selection-algorithm allele-coverage --preset allele-balanced-v1 \
  --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 \
  --pool-count 2 --minimum-base-frequency 0 --core-count 4 \
  --terminal-gap-policy observed-only --dimer-score=-26 --panel-mode equal \
  --coverage-metric observed-allele-primer-trimmed --coverage-target 0.95 \
  --optimizer-seed 0 --optimizer-starts 4 --optimizer-repair-rounds 2 --optimizer-time-limit 60 \
  --mispriming-product-size 2000 --candidate-profiles union \
  --reuse-discovery /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-discovery-cache-01 \
  --variant-selection subsets --search-effort standard-v1 --phase-scheduling serial \
  --intended-product-policy concrete-designated-sites --allele-weighting distinct-observed \
  --discovery-length-mode first-compatible --specificity-terminal-k 17 \
  --secondary-product-policy ordered-disjoint-concrete-designated-sites/v1 \
  --subset-beam-width 16 --subset-expansion-limit 256 --exchange-width 2 \
  --salvage off --primary-tier strict \
  --work-frontier-candidates 64 --work-construction-candidate-attempts 2048 \
  --work-repair-candidate-probes-per-round 128 --work-repair-neighborhoods-per-round 256 \
  --work-repair-trials-per-round 256 --work-pool-lookahead-candidates 4 \
  --work-cleanup-moves-per-round 64 --work-families-per-refresh 16
```

- Exit: `0`
- Outer wall time: `433.1152899169829` seconds
- stderr: empty
- stdout SHA-256: `1fc6cf2da272e5cc00cc6ae24d67d5616876c658d14df39f7804b95dcfc0bac0`

The resolved configuration retained strict-only selection with salvage off, two pools, observed-only terminal-gap behavior, union profiles with subset variants, both concrete zero-credit product policies, standard-v1 effort, serial scheduling, and the exact requested limits above.

## Retained initial invocation failure

The first wrapper invocation passed the negative dimer value as two tokens, `--dimer-score -26`. Swift ArgumentParser rejected it before native execution and explained that the value must be attached to the option. That complete failed attempt is retained as `execution/design-attempt-01.{json,stdout,stderr}`:

- Exit: `64`
- Wall time: `0.0648951658513397` seconds
- stderr size: `250` bytes
- stderr SHA-256: `8be2cef0cb06eaebaf21c078c5b7f4ac2b5c4ca9f024bde9f6145c30ca7eec23`

The successful command used `--dimer-score=-26`. The failed attempt created no scientific output and did not mutate the source or cache.

## Human labels and stable identities

The derived display map joins each exact native row to the source `.lungfishmsa` metadata. Source order is preserved:

| Source row | Human original label | Stable LGE row ID | Native row ID |
|---:|---|---|---|
| 1 | `NHP01865 Mamu-A1*001:01:01:01, A1 locus allele.` | `row-000001-bc14c26ba2` | `row-f8d2df7e45c995ef2b087555ce57e43b87c4c0d7ca45fef9a24873753f6d6493` |
| 2 | `NHP01866 Mamu-A1*002:01:01:01, A1 locus allele.` | `row-000002-0dc0c8c930` | `row-032c4cce3745f56b150617bc9c78ec4ff261bd257f87e88773bee57ea6789e66` |
| 3 | `NHP01879 Mamu-A1*016:01:01:01, A1 locus allele.` | `row-000003-622fd4146e` | `row-2c728e9fd002e8e8fceebcf54a5f8ef8879495294a13ab1e8a459a7204cbacff` |
| 4 | `NHP01884 Mamu-A1*011:01:01:01, A1 locus allele.` | `row-000004-0d07e9200d` | `row-3e02cdf13edc78eb7517c4b5a305454107d92714bc86f3d1110dc1c03f2460da` |
| 5 | `NHP01885 Mamu-A1*028:01:01:01, A1 locus allele.` | `row-000005-7ec287903f` | `row-59e4c70462a57da19487e3519b4f901c29c6ff59176113f37212852d5e4c8957` |
| 6 | `NHP01890 Mamu-A1*004:01:01:01, A1 locus allele.` | `row-000006-1b7a9c3a7c` | `row-fef171949ed1dd4c059da809ed7b305405923013941d946acf847344b665a3f8` |

Text inspection contained every human label beside both its stable LGE ID and native row ID. JSON inspection retained the verified manifest. The transform provenance consumes and hashes, at their final stored paths, the native label map, panel optimizer, saved audit validation, native stored FASTA, normalized LGE row map, and `.lungfishmsa` source-row metadata.

Key final hashes:

- Bundle manifest: `d31c972571e73dc026d71ad16727cb78ba87968f5016fdb14bb5ec06b35f574b`
- Derived label map: `df6593f4cba6953b5fc5e4d8e2e2ad4848f0b27305f6b299bdea258e56519890`
- Derived label provenance: `2e54d92fd1d88ea0c17eb4b127072ec93f2d5c0b51c3baa6a027164cf7d5430e`

## Inspection, history, and audit commands

### Text inspection

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli primers analysis inspect /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/design.lungfishprimeranalysis
```

- Exit `0`; wall time `2.8184221249539405` seconds; stderr empty.

### JSON inspection

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli primers analysis inspect /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/design.lungfishprimeranalysis --json
```

- Exit `0`; wall time `2.5940920000430197` seconds; stderr empty.

### Strict history query

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli primers analysis history /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/design.lungfishprimeranalysis --result-id F61458CD-4513-4DDF-ADE7-232C853A4773 --primalscheme3-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11/.venv/bin/primalscheme3 --output /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/history-query --stage strict --limit 20
```

- Exit `0`; wall time `77.42987991683185` seconds; stderr empty.
- `history-query/lungfish-provenance.json` retains the wrapper command, runtime, inputs, outputs, hashes, sizes, status, wall time, and stderr descriptor.

### Fresh saved-bundle audit

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli primers analysis audit /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/design.lungfishprimeranalysis --result-id F61458CD-4513-4DDF-ADE7-232C853A4773 --primalscheme3-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11/.venv/bin/primalscheme3 --output /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-a1-matrix11-label-integration-01/fresh-audit
```

- Exit `0`; wall time `134.32024087500758` seconds; stderr empty.
- `fresh-audit/lungfish-provenance.json` retains the corresponding complete wrapper receipt.

## Independent verification

`verification.json` reports `status: passed`. It checked:

- the six exact source-metadata joins in source order;
- normalized headers, LGE row maps, stable LGE IDs, native IDs, and distinct class membership;
- human-label visibility in text inspection and the JSON manifest;
- cache reuse, zero discovery workers, exact requested/resolved controls, strict-only stage, and salvage off;
- six observed classes, 22 assignments, modeled coverage, and both product-report counts;
- history and fresh-audit success, raw-input reparsing, and the exact audited stage set;
- native capability/source identity and final-path transform provenance inputs and hashes;
- source bundle and discovery cache byte identity before and after;
- retention of the failed first invocation and every completed follow-up command receipt.

Before writing the verifier output, the retained root contained 96 regular files and `5728555401` bytes. The bundle and its copied immutable discovery evidence account for most of that size.

## Interpretation and remaining limits

- This run establishes the production LGE/native cache-reuse, label-publication, inspection, history, audit, and provenance path on the real six-row A1 input.
- The 60-second selector limit and narrow standard caps were chosen to bound integration cost. The 68.0712% result must not be compared as a quality preset, baseline, or final scientific panel.
- Cache reuse avoids rediscovery but still validates and copies complete immutable evidence. That behavior explains the several-minute workflow and multi-gigabyte retained bundle.
- Modeled exact-binding coverage and the native product classifications concern the supplied aligned rows and recorded specificity model. They do not establish laboratory amplification or whole-genome specificity.
- Human labels are display metadata. Coverage, classes, assignments, cache identity, and audit decisions continue to use stable scientific IDs.
- This command-line validation does not exercise the GUI or a managed native installation.
