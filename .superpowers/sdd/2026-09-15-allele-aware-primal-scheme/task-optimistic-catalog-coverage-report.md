# External finite-catalog availability diagnostic — implementation report

Status: implementation and synthetic verification complete; real A1 execution is intentionally blocked pending independent Astra review.

## External files

- Script: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/optimistic-catalog-coverage-01/optimistic_catalog_coverage.py`
  - SHA-256 `87b9c63c9f3fbb434c340f584c59c445e99cba795736a0ce32ccd9c1dcb9c814`
  - 46,080 bytes
- Tests: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/optimistic-catalog-coverage-01/test_optimistic_catalog_coverage.py`
  - SHA-256 `e19ccfd0bcffcedd6480bbcffdaaf7a436c2406a1ed21d6dddfbf9f0f9e57a8f`
  - 22,213 bytes

No production native, Swift, managed-runtime, GUI, or frozen-matrix files were edited. The completed07 panel and its fresh audit have not yet been read by this script.

## Quantities and scope

The derived report has two separate quantities:

1. **Singleton exact-binding availability** unions canonical, exact, same-row products whose one-forward/one-reverse reference envelope satisfies the authoritative saved minimum and maximum.
2. **Stored-catalog subset relaxation** uses the minimum confirmed binding lengths for a class plus eligible stored forward/reverse extenders at least that long. A deterministic length query proves whether their maximum selected lengths can satisfy the same envelope bounds. Extenders need not bind the class.

The relaxation retains stored-site profile membership, mapped anchor/footprint integrity, saved reference geometry, exact full-primer same-row binding, observed-base masks, and authoritative saved size bounds. It explicitly relaxes subsequent unary and pair scientific validation, specificity and cross-products, self/pair dimers, pooling and overlap, oligo/exposure and amplicon caps, and search scheduling. It is labeled as neither a compatible configuration nor a feasible multiplex panel, and it makes no claim about undiscovered primers, ungenerated lengths, or measured amplification.

Canonical `binding_support` supplies row footprints. Coverage uses row-coordinate interiors intersected with each distinct class's concrete observed positions, so insertions remain countable and N/IUPAC/missing positions receive no exact coverage credit. Target means weight each assessable distinct class once; row aliases and multiplicity remain descriptive. Zero observed denominators remain null. The report states that a class below 95% does not alone rule out a target mean of 95%.

## Completeness and consistency gates

- The gzip catalog is streamed with the standard JSON decoder. No generic full-catalog JSON tree, full `VariantCatalog`, or history SQLite database is loaded.
- Only compact target sites/classes and `(status, row_footprint)` support records are retained. Families are streamed once for the actual calculation.
- Counts include all catalog family records, target and other-target families, every target family/class evaluation, all sites/classes, selected/ledger configurations, and binding-support cache entries.
- Mapped eligible sites must reproduce their reference footprint from the saved target mapping. Every family site must match target, strand, and anchor; all kept sites must share expected reference inner endpoints. Confirmed length variants must share canonical row inner endpoints. Any mismatch fails the report.
- Selected configurations are streamed from the ledger and their exact class coverage is independently reconstructed from selected sites. It must equal the fresh saved validation intervals and be a subset of the relaxation for every class. Either mismatch is fatal.
- Multi-target panels retain whole-panel assignment and ledger counts while selected-coverage reconstruction and selected-family requirements are filtered to the requested target.
- Up to 18 selected-configuration rows report the family's eligible F/R counts, selected F/R IDs, pool/stage, and exact supported class IDs. They explicitly do not infer why an omitted variant was omitted or whether an alternative is feasible.
- A run is labeled complete/upper-bound-within-scope only after the entire target family stream finishes. Cancellation or failure publishes no availability report.

## Provenance

Every run uses a fresh output. It writes an attempt before scientific analysis and a final receipt for success, failure, cancellation, and requested-output conflict. Receipts preserve raw argv and record a reproducible argv/shell command beginning with the hashed matrix10 Python executable and script. They contain cwd, requested and resolved output paths/options, script hash, matrix10 Git/source-file identity (including `coverage_catalog.py`, which implements binding helpers), Python executable/hash/runtime at start and end, every scientific input path/hash/size before and after, timestamps/wall time/status/stderr, output inventories, and source/input/runtime change flags. Input/source/runtime drift converts an apparent success to failure and removes the availability result.

Before analysis, the runner requires a successful unchanged panel receipt, valid saved stage validation, and successful unchanged whole-bundle fresh audit with raw inputs reparsed and the selected primary tier present and valid. The audit's input descriptors are rebound to the current config, catalog, ledger, optimizer, panel receipt, selected stage, assignments, and validation. Applicable files are also rebound to panel-output descriptors. The audit's `validation.json` is rebound to its audit-output descriptor. Detached or stale audit evidence is rejected. The imported `primalscheme3` package must resolve beneath the explicit matrix10 source.

## TDD and verification

The initial focused run failed during collection because the diagnostic script did not exist. The first green run passed four tests covering the nonbinding extender counterexample, no-extension case, exhaustive subset equivalence, and streamed JSON. Additional regressions cover:

- exact same-row binding rather than cross-row F/R support;
- an internal reference gap/row insertion and an internal N in the observed mask;
- duplicate-row class collapse without extra weighting;
- inconsistent mapped anchor/footprint failure;
- complete tiny-bundle family traversal;
- exact selected-coverage reconstruction and mandatory inclusion;
- target-scoped reconstruction in a two-target panel while retaining whole-panel counts;
- stale audit-output and detached audit-input descriptor rejection;
- bounded selected-family diagnostics; and
- success, failure, cancellation, preflight failure, and output-conflict provenance.

Final verification from frozen matrix10's own environment:

```text
.venv/bin/python -m pytest .../test_optimistic_catalog_coverage.py -q
13 passed in 0.52s

.venv/bin/python -m ruff check SCRIPT TEST
All checks passed!

.venv/bin/python -m ruff format --check SCRIPT TEST
2 files already formatted

.venv/bin/python -m py_compile SCRIPT TEST
exit 0
```

The retained focused log is `/tmp/optimistic-catalog-coverage-tests-review3.log`, SHA-256 `e8a03aa5376f00138c772120654eed2dcc3609732b976966954755922810b7e5`.

The exhaustive fixture tries every nonempty forward and reverse subset through production `make_configuration` and `configuration_coverage`. The optimized singleton and relaxation unions match exactly. Its key counterexample has an exact 20/17 pair below the minimum and a longer 25-base forward extender that does not bind the row; singleton coverage is empty while both exhaustive subsets and the optimized relaxation recover the same insertion-aware interior.

## Review gate

No real A1 or full-MHC command has been run. Independent Astra review must approve the two external files and this report before the completed07 A1 command is executed.
