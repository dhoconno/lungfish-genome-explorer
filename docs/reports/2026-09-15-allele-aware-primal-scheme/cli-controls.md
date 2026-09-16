# Allele-aware PrimalScheme CLI controls

Development CLI; MHC evaluation is still in progress. Use the isolated native executable. The managed LGE runtime has not been replaced. Current integration verification is pinned to the frozen `matrix10` native source at revision `158a4a3`; substitute the absolute path to that checkout's own `.venv/bin/primalscheme3` in the commands below.

## Starting point

```sh
/absolute/path/to/frozen-matrix10/.venv/bin/primalscheme3 panel-create \
  --msa /absolute/path/target-a.fasta --msa /absolute/path/target-b.fasta \
  --output /absolute/path/new-panel \
  --selection-algorithm allele-coverage --preset allele-balanced-v1 \
  --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 \
  --n-pools 2 --ncores 4
```

Repeat `--msa` for each target. Output must be a new directory. Supply the original aligned sequences, preserving unknown bases and alignment gaps. The preset combines normal and high-GC discovery, gives each distinct observed allele equal weight within its target, and aims for 95% coverage after primer trimming. Coverage is a predicted binding model, not measured amplification success.

## Scientific controls

| Option | Preset | What changing it does |
|---|---|---|
| `--candidate-profiles` | `union` | `normal` or `high-gc` restricts discovery; union retains profile provenance for shared candidates. |
| `--variant-selection` | `subsets` | Allows compatible variants to preserve a partially supported amplicon. `full-cloud` requires every eligible variant in a family and is useful as a comparison. |
| `--coverage-metric` | `observed-allele-primer-trimmed` | Fixed in allele-aware mode. It measures observed concrete bases inside same-row, exact-primer-supported interiors after primer trimming. |
| `--allele-weighting` | `distinct-observed` | Fixed in allele-aware mode. Duplicate rows remain provenance aliases and do not receive extra objective weight. |
| `--phase-scheduling` | `serial` | `reserved` gives the initial seed, construction and repair phases 20%, 40% and 40% shares of the remaining optimizer budget, then divides each repair reservation 20%, 20% and 60% among preparation, cleanup and exchange. |
| `--intended-product-policy` | `exact-supported` | `concrete-designated-sites` permits a nonexact product only when both concrete primer sites are certified on one supplied row for the same designated configuration. Such products receive zero coverage credit. |
| `--coverage-target` | `0.95` | Changes the objective's deficit penalty; it is an aspiration, not a requirement that discards lower-coverage panels. |
| `--amplicon-size`, `--amplicon-size-min`, `--amplicon-size-max` | Explicit bounds required | Defines reference-span geometry. Wider bounds admit more placement alternatives and increase candidate volume. |
| `--n-pools` | `2` | More physical reaction pools can separate conflicts but increase laboratory reactions. |
| `--min-base-freq` | `0` | Increasing it can remove rare allele-specific variants. Frequencies use a fixed anchored row cohort. |
| `--discovery-length-mode` | `first-compatible` | `all` examines all allowed lengths instead of stopping at the first individually compatible length per row, anchor and profile. This can be expensive. |
| `--specificity-terminal-k` | `17` | Changes the terminal seed used for supplied-row specificity screening. Comparisons must account for primer lengths and use a shared eligible catalog. |
| `--mispriming-product-size` | `2000` | Upper product length screened on supplied rows; positive inclusive bound. This mode does not permit disabling screening with zero. |
| `--secondary-product-policy` | `ordered-disjoint-intended-sites` | Keeps the exact ordered-disjoint rule. `reject-secondary-products/v1` rejects secondary products. `ordered-disjoint-concrete-designated-sites/v1` can allow a nonexact secondary product only with a complete four-site certificate. |
| `--max-amplicons`, `--max-amplicons-msa` | Uncapped | Limits physical design size; caps may reduce achievable coverage. |
| `--dimer-score` | `-26` | Fixed for the strict allele-aware tier. A different value is rejected; use the explicitly labeled salvage ladder for bounded experimental relaxation. |

The strict dimer cutoff remains −26. The score is the native numerical score, not free energy or a probability. Chemistry is defined by complete versioned profiles; ad hoc temperature/salt overrides are not silently accepted. Both profiles use the same modeled temperature window. That compatibility does not establish laboratory performance. The legacy `--high-gc` switch is not the dual-profile union; select `--candidate-profiles union` instead. Allele-aware mode also fixes observed-only terminal gaps, equal combined-panel weighting and supplied-MSA specificity screening, so legacy switches that would change those semantics are rejected.

## Search effort

`--search-effort` selects one versioned group of five optimizer defaults:

| Effort | Selector time limit | Starts | Repair rounds | Construction attempts | Families per refresh |
|---|---:|---:|---:|---:|---:|
| `standard-v1` (default) | 120 seconds | 4 | 2 | 2048 | 16 |
| `quality-v1` | 3600 seconds | 8 | 3 | 8192 | 32 |

The time limit is one shared maximum for selector work. Starts and repair rounds are ceilings within that shared budget; selecting `quality-v1` does not promise that all of them finish. Setup, discovery, publication and audit require additional time. Larger budgets may find improvements; they do not prove an optimum, and wall-clock limits can interrupt different work on different machines.

Individual options take precedence over the selected effort even when the explicit value equals a standard default. For example, `--search-effort quality-v1 --optimizer-starts 4` resolves to four starts. The five individual overrides are `--optimizer-time-limit`, `--optimizer-starts`, `--optimizer-repair-rounds`, `--work-construction-candidate-attempts` and `--work-families-per-refresh`. Request provenance records the effort and only the individual overrides actually supplied; resolved provenance records all five final values.

Effort does not change candidate profiles, discovery, coverage target or weighting, variant selection, intended- or secondary-product policy, chemistry, specificity, dimer rules, sizes, pools, amplicon caps, salvage or phase scheduling. `--optimizer-seed` (0), `--subset-beam-width` (16), `--subset-expansion-limit` (256), and `--exchange-width` (2; maximum 2) remain independent controls.

An explicit effort requires an executable advertising the exact versioned effort descriptor. Older saved results without `search_effort` are interpreted as `standard-v1`; omitting the flag keeps the historical defaults and remains compatible with older executables. The frozen `matrix10` example executable elsewhere in this guide advertises this exact descriptor; older executables fail an explicit effort request before design.

The default `--phase-scheduling serial` runs phases in their fixed order against one shared deadline. `--phase-scheduling reserved` applies initial-cycle reservations so earlier seed work cannot consume every phase's initial share; unused time flows to remaining phases and the global deadline never grows. Each published tier records the exact advertised scheduling descriptor and phase-by-phase timing, outcome, objective snapshots, accepted-repair count, work deltas and before/after family cursors. An explicit scheduling option requires an executable that advertises this frozen capability. Saved outputs from before this capability remain readable as legacy serial results.

The default `--intended-product-policy exact-supported` preserves the established specificity rule. `concrete-designated-sites` allows only a nonexact product backed by a complete same-row certificate for both designated primer sites from one configuration. Products involving another target, shifted sites, incomplete or mixed-configuration evidence, or uncertain footprints remain blocked. Allowed intended-product witnesses are reported separately from allowed secondary products with their certificate and zero coverage credit. An explicit policy requires an executable that advertises the frozen intended-product capability; older saved outputs without the field are interpreted as `exact-supported`.

The default `--secondary-product-policy ordered-disjoint-intended-sites` remains stable. The optional `ordered-disjoint-concrete-designated-sites/v1` rule requires one supplied row to certify, in order, the left configuration's forward and reverse sites followed by the right configuration's forward and reverse sites. The outer forward-to-reverse product may be nonexact only through those concrete selected occurrences; it must remain certain and within the configured product bound. Its witness is reported separately with zero coverage credit, so it does not broaden the exact observed-allele coverage metric. The intended-product policy remains independent. Existing outputs without the capability retain the exact default, and the default panel and per-MSA amplicon caps remain uncapped unless `--max-amplicons` or `--max-amplicons-msa` is supplied.

Advanced deterministic work limits are also exposed:

| Option | Standard default | Quality default |
|---|---:|---:|
| `--work-frontier-candidates` | 64 | 64 |
| `--work-construction-candidate-attempts` | 2048 | 8192 |
| `--work-repair-candidate-probes-per-round` | 128 | 128 |
| `--work-repair-neighborhoods-per-round` | 256 | 256 |
| `--work-repair-trials-per-round` | 256 | 256 |
| `--work-pool-lookahead-candidates` | 4 | 4 |
| `--work-cleanup-moves-per-round` | 64 | 64 |
| `--work-families-per-refresh` | 16 | 32 |

`--ncores` controls discovery workers. A verified reused catalog performs no discovery; reports record zero actual discovery workers even when more were requested.

## Optional salvage

Salvage is off by default. Enable `--salvage bounded`. The default exploratory ladder is −28, −30, −32, with at most 8 violating physical dimer edges and 4 incident oligo species per pool, measured cumulatively relative to strict −26. Each tier starts from an accepted incumbent and is freshly audited. Salvage relaxes only the labeled dimer policy; chemistry, specificity, reference-span geometry, overlap, coverage metric and uncertainty handling remain unchanged.

Controls: repeatable `--salvage-threshold`, `--salvage-max-stages` (up to 3), `--salvage-max-edges-per-pool`, `--salvage-max-oligos-per-pool`, and `--salvage-time-limit` (60 seconds per tier). Thresholds must be finite and strictly decreasing from −26. These are bounded experimental policies, not validated destructive-dimer cutoffs. Tighten exposure caps to restrict how many already selected oligos are put at additional modeled risk.

Strict remains the primary exported scheme unless `--primary-tier salvage-1` (or another enabled, successfully validated tier) is explicitly selected. Every completed tier and its measured tradeoffs remains in the output.

## Retained history, audits and reuse

The output retains generated sites, physical oligos, amplicon families, explored exact subsets, raw evidence, assessments, transitions, and stage snapshots. A failed candidate remains discoverable. “Not explored within budget” is distinct from “rejected by a measured constraint.” A compatible subset can remain selected after a conflicting member is removed, with the resulting allele-support loss recorded.

```sh
primalscheme3 panel-history --bundle /absolute/path/panel \
  --target REFERENCE_NAME --region 394:644 --limit 100 \
  --output /absolute/path/new-region-query
primalscheme3 panel-audit --bundle /absolute/path/panel \
  --output /absolute/path/new-audit
primalscheme3 panel-cache --bundle /absolute/path/panel \
  --output /absolute/path/new-discovery-cache
```

History regions are zero-based, half-open reference intervals; pool numbers are one-based. Use entity IDs for exact primer/family/subset histories, stage/profile filters, and offset/limit pagination. Queries and audits produce their own reproducibility receipts outside the source panel.

Add `--reuse-discovery /absolute/path/new-discovery-cache` to a compatible design command. Reuse verifies original target order/content, discovery settings, chemistry and scientific source/runtime fingerprints; incompatible caches fail closed. Copied origin history is explicitly distinguished from the new run's decisions. Reuse does not carry forward an old selection verdict.

All outputs preserve exact invocation, requested and resolved options, versions/runtime, stored paths, hashes/sizes, elapsed time and exit status. Original input paths are provenance origins; retained payloads remain usable after relocation.

## Lungfish CLI adapter

The Lungfish wrapper writes a relocatable `.lungfishprimeranalysis` bundle and keeps the complete native lge.4 directory under `native/<result-id>`. Allele-aware mode requires an explicit frozen executable; it does not fall back to the managed legacy runtime.

```sh
/absolute/path/to/lungfish-cli primers design primalscheme3 \
  --msa /absolute/path/target-a.fasta \
  --msa /absolute/path/target-b.fasta \
  --output /absolute/path/new-analysis.lungfishprimeranalysis \
  --grouping combined \
  --primalscheme3-path /absolute/path/to/frozen-matrix10/.venv/bin/primalscheme3 \
  --selection-algorithm allele-coverage \
  --preset allele-balanced-v1 \
  --candidate-profiles union \
  --phase-scheduling reserved \
  --intended-product-policy exact-supported \
  --secondary-product-policy ordered-disjoint-intended-sites \
  --coverage-target 0.95 \
  --amplicon-size 200 \
  --amplicon-size-min 150 \
  --amplicon-size-max 250 \
  --pool-count 2 \
  --core-count 4
```

Repeat `--msa` in the intended native target order. The output must be a fresh absolute path. The wrapper preserves aligned sequence symbols, including `N` and other IUPAC ambiguity, while normalizing `U` to `T`. It verifies the executable's lge.4 capability, source, Python/runtime and native-kernel identities before accepting the result.

The scientific controls in the tables above are exposed by the wrapper and retain the same meaning. These names differ at the wrapper boundary:

| Native option | Lungfish wrapper option |
|---|---|
| `--n-pools` | `--pool-count` |
| `--ncores` | `--core-count` |
| `--max-amplicons-msa` | `--max-amplicons-per-msa` |
| `--min-base-freq` | `--minimum-base-frequency` |

Use `--max-amplicons` unchanged for the panel-wide cap. Add advanced search, salvage, chemistry and deterministic work controls from the native tables only when the comparison requires them; every requested value and resolved default is recorded. `--min-overlap` applies to independent legacy designs and custom values are rejected in allele-aware mode.

Complete candidate history can make a cold MHC discovery run large and slow. A verified `--reuse-discovery /absolute/path/to/cache` avoids rediscovery, but the new run still validates and copies immutable evidence into its own result before optimization and audit. Filesystem copy-on-write copies remain independently mutable; they are not shared hard links. `--optimizer-time-limit` bounds optimizer search only. It does not bound discovery, audit or publication.

### Inspect, query and re-audit a saved result

First verify the saved bundle and obtain the result UUID. The text view reports the metric, primary tier, profile, and target and per-class covered/observed counts, fractions, deficits and dropout. The JSON view returns the verified manifest and is convenient for extracting `results[].id`.

```sh
/absolute/path/to/lungfish-cli primers analysis inspect \
  /absolute/path/analysis.lungfishprimeranalysis

/absolute/path/to/lungfish-cli primers analysis inspect \
  /absolute/path/analysis.lungfishprimeranalysis --json
```

Pass that UUID explicitly when querying retained decision history or re-running the native audit. Both commands require the same explicit frozen lge.4 executable and a fresh output directory.

```sh
/absolute/path/to/lungfish-cli primers analysis history \
  /absolute/path/analysis.lungfishprimeranalysis \
  --result-id 00000000-0000-0000-0000-000000000000 \
  --primalscheme3-path /absolute/path/to/frozen-matrix10/.venv/bin/primalscheme3 \
  --output /absolute/path/new-history-query \
  --target TARGET_ID --region 394:644 --stage strict --limit 100

/absolute/path/to/lungfish-cli primers analysis audit \
  /absolute/path/analysis.lungfishprimeranalysis \
  --result-id 00000000-0000-0000-0000-000000000000 \
  --primalscheme3-path /absolute/path/to/frozen-matrix10/.venv/bin/primalscheme3 \
  --output /absolute/path/new-audit
```

History requires at least one of `--entity`, `--target`, `--region` or `--stage`; regions are zero-based half-open, pools are one-based, and `--limit` is 1–1000. Audit reparses the source alignments stored inside the selected native result. Add `--tier TIER_ID` only when intentionally limiting the audit to that saved tier.

History and audit leave the source analysis unchanged. Their output directories retain the native `query.json` or `validation.json` and native `provenance.json`, plus `lungfish-provenance.json` for the wrapper invocation. The wrapper receipt binds the selected result, current contained paths, exact wrapper and native argv, executable and runtime identities, requested/resolved options, input and output hashes/sizes, elapsed time, stderr and exit status. After a fresh destination is accepted, failures and cancellation retain the same wrapper receipt and any useful partial native evidence.

## Regional diagnosis during development

The standalone `scripts/diagnose_allele_region.py` script independently audits a completed native panel, reports trimmed coverage for each distinct class in a reference interval, and lists retained and omitted eligible variants in selected families. Each omitted variant has its own class-binding support; that support does not imply a feasible replacement amplicon.

```sh
.venv/bin/python scripts/diagnose_allele_region.py \
  --bundle /absolute/path/completed-native-panel \
  --target-index 3 --region 394:644 \
  --legacy-alternatives /absolute/path/region-alternatives.json \
  --legacy-alternatives /absolute/path/region-alternatives-high-gc.json \
  --max-candidates 16 --history-limit 100 \
  --output /absolute/path/new-region-diagnosis
```

Run this from the isolated native source directory. Index 3 identifies Mamu-A1 only for the documented MHC snapshot order; use the saved target ID for other input orders. The interval is BED `[394,644)`, matching the stored historical alternatives.

Every historical alternative is classified by exact sequence, strand and anchor matches. At most 16 unique matched configurations receive fresh insertion checks per pool by default; `--max-candidates` accepts 0–1000. The report distinguishes unavailable matches, measured rejection and alternatives not evaluated within the limit. Individual insertion checks do not establish joint feasibility or an optimal coverage ceiling. All diagnostics and their provenance are written outside the original panel.
