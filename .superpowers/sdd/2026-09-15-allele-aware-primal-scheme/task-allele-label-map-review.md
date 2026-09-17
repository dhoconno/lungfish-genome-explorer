# Independent native allele-label map review

## Reviewed slice

Native `115878f` against `158a4a3`. Read all six touched files and the implementation report. No scientific run, protected source edit or Swift change performed by reviewer.

## Scientific and provenance assessment

The new sidecar is correctly separate from scientific records and cache keys. Raw FASTA full description, record ID, comment and normalized native ID are distinct fields; row-index/row-ID joins retain duplicate sequence aliases while the native parser still rejects duplicate normalized record IDs. Input source occurrences and parsed row cells/count/order must match the catalog. Reuse publishes current consumed headers, preserving scientific IDs. Output inventory and optimizer reference bind the sidecar, and fresh audit reconstructs it from saved raw inputs so updating only a forged map's checksum does not bypass verification. Relocation uses stored relative inputs; historical missing-map outputs remain accepted without inventing labels.

The reviewed diff leaves all11 protected discovery files plus `coverage_catalog.py` unchanged (independent `git diff --quiet 158a4a3 115878f -- ...` check). No chemistry, coverage weighting, configuration, history, search or biological identity implementation changed.

## P2 — Avoid loading a complete discovery catalog for label audit

The new label branch calls `VariantCatalog.from_dict(_read(_catalog_path(...)))` solely to access targets/observations, and retains that catalog until the stage loop later loads another. On the multi-million-record catalog this adds an unnecessary full parse and potentially a second full catalog live at once. A nonsemantic display feature should not add that memory cost.

Use a thin display-only context containing the already freshly parsed `_authoritative_targets` plus `canonical_observations(target)` instead. These are the authoritative row/class identities used by science and are already available immediately above the label branch. `build_allele_label_map` requires only `.targets` and `.observations`. This also directly reconstructs aliases from raw data rather than trusting the saved observation mapping. Do not touch the protected helper implementations. Add a regression proving the label-only reconstruction path never asks for a discovery catalog.

Parent independently identified and agreed with this concern; scoped fix requested from Sol. Initial verdict: no scientific binding defect found, final approval pending the bounded memory fix and focused verification.

## Final rereview — approved at236e74a

Approved `236e74af6b186367fd66f15e73b558a0c3e44a74` atop115878f. The label audit now passes freshly reconstructed targets and canonical observations to an explicit thin helper; it no longer loads a complete discovery catalog. Pipeline generation passes the existing catalog's target/class tuples without changing scientific objects. The regression makes `_catalog_path` fail if used during this label audit and passes.

Independent final focused command: `.venv/bin/python -m pytest -q tests/lge/test_allele_labels.py tests/lge/test_allele_inspection.py -k 'label_map or relocation or catalog'` — **14 passed,24 deselected in4.50s**, exit0. Initial115878f review had10 passed in3.62s. Independent diff check again confirms all11 protected discovery sources plus coverage_catalog are unchanged from158a4a3; working tree clean at review.

No remaining blocking finding. Native nonsemantic label publication/audit is approved for parent full-suite/freeze and the separately reviewed LGE bridge. No Swift, real MHC or managed-runtime work was performed by reviewer.
