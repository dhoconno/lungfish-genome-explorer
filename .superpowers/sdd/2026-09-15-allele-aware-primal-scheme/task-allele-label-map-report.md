# Native allele-label map implementation report

Status: native implementation and verification complete; independent corrective review pending.

Native base: `158a4a3a10156efdfcb98eb19ae0f2c5f7841358`

Native commit: `115878f` (`Publish audited allele label mappings`)

Corrective review commit: `236e74a` (`Audit allele labels without loading catalog`)

## Result

New allele-aware panel outputs publish `allele-label-map.json` with schema
`primalscheme3.allele-label-map/v1`. The artifact is explicitly referenced by
`panel-optimizer.json`, included in normal output provenance, and reconstructed
from the saved raw FASTA inputs during a fresh audit.

The map is presentation metadata. It does not participate in target, observed
class, site, configuration, catalog, cache, coverage, objective, ledger, or
history identities. It binds those immutable IDs to the exact consumed FASTA
labels by source occurrence and source row order.

Each source row records:

- source occurrence index and target ID;
- zero-based row index and immutable native row ID;
- a SHA-256 digest of the authoritative parsed row cells;
- the full FASTA description, parsed FASTA record ID, FASTA comment, and native
  normalized record ID.

Each observed class records its immutable class ID, multiplicity, ordered row-ID
aliases, and corresponding consumed FASTA record IDs and descriptions. Identical
sequence rows therefore remain one scientific class while all distinct source
row/header aliases remain visible.

## Validation and compatibility

Generation calls the existing authoritative native MSA parser and rejects any
source occurrence, row count, row order, row content, or normalized-label order
that differs from the catalog. It also hashes and sizes each stored raw input.

Fresh audit requires an exact schema/path reference, an output provenance
descriptor, valid sidecar schema, and byte-for-structure equality with a map
freshly reconstructed from the saved raw inputs and canonical observed classes. Updating only the
forged sidecar's output hash therefore does not bypass the raw-input comparison.

Following independent review, fresh audit constructs this comparison from the
already reparsed authoritative targets plus `canonical_observations(target)`.
It does not load or retain the complete discovery catalog solely for display
metadata. A regression replaces the audit catalog-path helper with a hard
failure and confirms the complete bundle audit still succeeds.

Historical bundles without either the sidecar or optimizer reference remain
valid and report label availability as unknown. An advertised sidecar may not be
missing or detached.

Direct FASTA duplicate normalized record IDs retain the existing native parser
error. Duplicate sequence rows with distinct consumed IDs are supported and are
covered by the new tests. Repeated original display labels beyond the consumed
FASTA layer belong to the later LGE source-row-map enrichment and do not broaden
the native scientific input contract.

## Test-driven evidence

Initial RED checks:

- `pytest -q tests/lge/test_allele_labels.py`: six failures because the new
  module did not exist.
- `pytest -q tests/lge/test_allele_inspection.py -k 'label_map or relocation'`:
  four failures because publication, audit, and historical handling were absent.

Final verification from the native worktree:

```text
.venv/bin/python -m pytest -q \
  tests/lge/test_allele_labels.py \
  tests/lge/test_allele_pipeline.py \
  tests/lge/test_allele_inspection.py \
  tests/lge/test_allele_catalog_cache.py \
  tests/lge/test_allele_publication.py
67 passed in 126.37s
```

This group covers direct construction, multiple targets/inputs, source ordering,
full description versus record ID/comment, duplicate sequence-row class aliases,
renamed current headers over reused discovery, unchanged catalog/row identity,
real cache reuse without rediscovery, relocation, tamper after refreshed output
hash, advertised-map removal, and historical absence.

The final total includes the thin-context regression added during independent
review. Its required RED state failed at the former `_catalog_path` call before
the implementation was changed; the isolated regression plus label-helper tests
then passed 7/7, and label/inspection tests passed 38/38 before the final group.

Static checks:

```text
ruff check: all checks passed
ruff format --check (six touched files before restoring unrelated legacy style): passed
git diff --check: passed
```

## Protected discovery identity

No protected discovery file changed. The final hashes are:

| File | SHA-256 |
|---|---|
| `core/config.py` | `198f1715580afdf8cdb02a985f8f82d6a7f91ecaa90318e269befb50fbb78ca5` |
| `core/digestion.py` | `dae9b85aeb03c06b22ec12fa3dcec44324ef622fd2e6286db8eb124889856ad6` |
| `core/mapping.py` | `bb7c923e9d89e6d562703d9279335dd67bc65cb30b8ff1cbf7b5cbe664a660f3` |
| `core/msa.py` | `a0343d7023637c381a46498cb3340221e05445bc54d5b7400634145bf1b70da7` |
| `core/parallel_discovery.py` | `696f36ef85aac2864c4751b1a316423041cdbef650741da95f699888d2515871` |
| `core/seq_functions.py` | `7f348c5b378193690a8ec01a1eda4f89a8c4785599cce5934e4bdfe9777ba51a` |
| `core/thermo.py` | `9b74900cef48b6f28bd1c51d9a4c5a3bf74bbb4a937ce8d62c4ca52b419d7e7d` |
| `core/variant_thermo.py` | `940d0f333949df2f9d8f496343931e8e6e72ab4e3ce73ff3840914f07b222cff` |
| `panel/allele_coverage.py` | `078fd5fa458b6921d27efef69c9671ea145526454d0939bf84381d81c0bec643` |
| `panel/coverage_discovery.py` | `dc3e530fd7abc567b02da433220fa334f76256e54a07ce2b5fa7fb09a54dedcc` |
| `panel/coverage_types.py` | `6217dcf626bc31b0fc730804d04699c2b5ebaa3accb629002b2d47057dfb2967` |

`panel/coverage_catalog.py` was also left unchanged
(`2c37b0174dd21fc363deb7e1638cb96748ab707ff3142ace0889d2d974360d90`).
The real cache-reuse regression passed, demonstrating that this display-only
publication does not invalidate or alter the protected discovery cache.

## Deferred LGE bridge

After native review, the minimal Swift bridge should consume the audited native
map and join it by `source_msa_index` and `row_index` to the result's ordered
input IDs and saved `<input UUID>-row-map.json`. For `.lungfishmsa` inputs, it
should then join the saved source snapshot's `metadata/source-row-map.json` by
row name to retain `originalName` and stable LGE row ID. The derived artifact
must keep every label layer, be checksummed with its own wrapper provenance, and
remain presentation-only. Old native outputs should report labels unavailable
rather than guess. No Swift files were changed in this task.

No MHC design or other large scientific run was performed.
