# Selected actual product-length diagnostic — root review approved

## Decision and frozen identity

Root independently reviewed the complete external `product_lengths.py` and reran its two focused tests: **2 passed in0.40s**. Approved for completed, freshly audited native panels. This is a descriptive interpretation tool, not a new scientific policy.

Frozen directory:
`/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/selected-product-lengths-frozen01`

Copied source, tests and implementation notes were compared byte-for-byte with the approved originals. `freeze-manifest.json` records their sizes/hashes and the approval. Verified:

- `product_lengths.py`: `7b6b0d3e857146bb7230d6062b6e7bb75a76c7b00cdba94dae2eab5e718f85e3`
- `test_product_lengths.py`: `360198d094376a2e55ddd10a9eff4a34a0c2a4a0f56ecac17fd7f3245701fcd5`

No scientific run was performed during this freeze. Prior narrow09 smoke remains immutable at `mamu-a1-narrow09-product-lengths-01`; no full11 invocation has occurred.

## Evidence and interpretation

The completed narrow09 smoke reproduced audited exact-binding coverage from selected saved support products intersected with freshly parsed observed ACGT masks. All input/source/runtime identities remained unchanged. Actual full product lengths were177–252bp. Of123 class-product records,118 were within150–250bp and **five were only slightly above the bound, at251–252bp**. These are not demonstrated biological length failures. They occur in two classes; the report records overlapping versus exclusive coverage contributions without double counting.

Reference full-span bounds are intentional. Allele insertions/deletions may produce different row-coordinate lengths. The native metric credits exact same-row primer-trimmed observed bases; it does not establish sequencing read coverage or empirical amplification. No automatic invalidity, PCR failure or revised coverage metric is inferred from this diagnostic.

## Limits and full11 run gate

- Require successful stable native receipts and a fresh raw-input audit covering the requested valid stage; verify all consumed raw/stage/ledger/validation byte bindings.
- Read saved selected products; reconstruct masks/unions only. No specificity/hit search, discovery, thermodynamic evaluation, optimization or history DB read.
- Counts are configuration × selected F/R variant pair × distinct class, with row aliases/multiplicity separately retained. They are not physical molecule frequencies.
- Report both out-of-range union and **exclusive** out-of-range credit; shared coverage cannot be attributed twice.
- The approved helper streams stage ledger records and retains selected records only. A malformed or changed receipt, geometry, reference, class identity or audited union fails closed with a receipt. Input/source changes invalidate success.
- Full11 remains gated on completion and fresh audit. Retain its raw-source/class labels and per-target/class extrema; do not replace this gate with the A1 smoke.
