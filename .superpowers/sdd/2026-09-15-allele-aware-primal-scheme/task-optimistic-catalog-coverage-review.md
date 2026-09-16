# Independent optimistic catalog diagnostic review

## Reviewed package and verification

External script SHA256 `3a578848f2a682834c6c2baecf4b2303ba2604b7dee04c489c4274428a0d801c`; test SHA256 `9efc1fe5f7a011b9e2adbbfb53d4c07218d19d37023461e0480d82f2fa0adaee`, in `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/optimistic-catalog-coverage-01`.

Independently ran frozen matrix10 `.venv/bin/python -m pytest test_optimistic_catalog_coverage.py -q`: **10 passed in0.46s**. Read all1093 script lines and523 test lines. No production edits, real A1 execution, history database access or new scientific runs.

## Scientific calculation

No defect found in the fixed-anchor exact-binding/length-extender calculation. It uses canonical same-row full binding and actual row coordinates, verifies shared reference/row inner endpoints, tests minimum confirmed binding lengths against eligible extender lengths, handles inclusive envelope bounds, and intersects the observed mask. The exhaustive tiny subsets regression includes the nonbinding extender counterexample that makes singleton-only union unsuitable as a ceiling. Complete family iteration, selected reconstruction/equality/inclusion, null denominators, distinct-class weighting and explicit incompatibility relaxations are present. Report language distinguishes a finite stored-catalog upper relaxation from a feasible panel or all-length biological ceiling.

## Findings requiring fix before real execution

### P2 — Bind the saved audit proof to current inputs and output bytes

`_verify_completed_inputs` accepts audit success/valid/raw_inputs_reparsed booleans plus an inputBundle path, but does not verify audit `validation.json` against the audit receipt's `outputs`, or current analyzed panel files against the audit receipt's `inputs`. The successful tiny-bundle fixture even omits both inventories. A stale success receipt or detached audit validation can therefore satisfy the advertised fresh-audit gate. Validate the audit output descriptor and compare the receipt's relevant input descriptors to current verified analyzed files, including panel provenance and selected stage data; require the selected tier in the fresh audit result. This can use descriptor lookup without reading unrelated giant history databases. Add native-shaped receipt fixtures and stale-input/tampered-output negatives.

### P2 — Target-specific selected coverage must exclude other target configurations

`run_analysis` collects selected IDs from all validation assignments, loads all their configurations, then asks the target-only family scan to contain every selected family. A valid multi-target panel with any selection outside --target-id fails. Filter reconstruction/selected-family requirements to configurations whose target matches the requested target, retaining separate whole-panel versus target counts. A two-target selected-panel fixture should demonstrate that each target can be analyzed independently with its own selected coverage inclusion.

## Provenance corrections requested in the same bounded round

- Record a reproducible command using the actual matrix10 Python executable plus script and arguments. The current shellCommand begins with the script's env-python shebang, which can resolve a different runtime. Raw sys.argv can remain separately recorded.
- Include `coverage_catalog.py` in scientific source hashes: canonical binding delegates sequence matching/reverse observation there. Git status alone cannot detect subsequent edits to a dependency already dirty at the beginning.
- Capture/compare runtime at end if claiming unchanged runtime; the current receipt captures it only at start.

Initial verdict: calculation approved in principle, **execution approval held pending these bounded fixes and focused verification**. No scientific policy change requested.

## Final rereview — approved

Approved external script SHA256 `87b9c63c9f3fbb434c340f584c59c445e99cba795736a0ce32ccd9c1dcb9c814` and test SHA256 `e19ccfd0bcffcedd6480bbcffdaaf7a436c2406a1ed21d6dddfbf9f0f9e57a8f`. Independently reran all13 focused tests using the frozen matrix10 venv: **13 passed in0.48s**. Independently rehashed both files before this final verdict.

Both P2 findings are resolved: native-shaped audit input/output inventories bind all analyzed panel artifacts and the audit validation bytes, and selected-tier coverage must be present; target reconstruction now filters selected configurations while reporting whole-panel and target counts separately. New tamper and two-target regressions cover these paths. The source inventory includes the delegated sequence-match dependency, runtime is compared at end, and the reproducible command preserves the lexical absolute virtual-environment executable rather than resolving its symlink to the base interpreter. Binary identity still hashes the target bytes.

No remaining blocking finding. Scientific extension/coverage logic is unchanged from the reviewed version. Approved for the parent-authorized completed07 A1 diagnostic run under this exact script/runtime with its complete receipt and inclusion checks. No real A1 execution was performed as part of review, and approval does not predict95% attainability or simultaneous panel feasibility.
