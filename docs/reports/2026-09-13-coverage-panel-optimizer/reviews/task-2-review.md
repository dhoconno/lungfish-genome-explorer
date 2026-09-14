# Task 2 independent review

Reviewed range: `74fe0d6..b46448a` (head `b46448aeda9ed5eb5530aba64ccfb69ac6de0f38`).

## Verdict

- **Spec compliance: PASS** against Task 2's brief and the corrected authoritative `docs/designs/coverage-specificity.md` intended-sites-v1 contract.
- **Code quality: APPROVE.** No concrete consequential correctness, maintainability, or regression issue found in the three new files.
- **Findings: 0 critical, 0 important.** No requested changes.

The ordered, disjoint, jointly supported intended-site cross-combination exception is intentional. The implementation records these products as allowed secondary products and does not add their spans to coverage. It should not be changed back to blanket rejection. Any earlier intended-pair-only plan wording conflicts with the corrected design and is superseded by it; no unresolved plan conflict was found in the supplied Task 2 brief and current design documents.

## Review evidence

Read the task brief, implementation report, supplied review diff, both design documents, all three added files, and the Task 1 support/type implementation plus existing chemistry and mismatch routines needed to evaluate their use.

The implementation preserves target and row occurrence identity, retains cross-MSA hits, searches both orientations of every concrete oligo, and uses actual reverse oligos. Full footprints and facing geometry use the specified ungapped-row coordinates and inclusive full product bound. Self-oligo opposite-orientation products are included. Concrete terminal windows and non-N ambiguous windows follow the disclosed policies; ambiguous or unknown full support cannot create intended signatures.

Declared signatures include row, target, actual endpoint oligos, orientation, and complete anchored footprints. Pair evaluation uses only the evaluated pair's signature union, so shared-oligo enumeration does not turn a proven intended physical product into a conflict. Secondary signatures require ordered disjoint row-level products of those two candidates. No global catalogue or selected-panel exemption state is consulted. Canonical pair ordering and fixed intrinsic/pair predicates preserve symmetry and monotonicity; callers must separately require intrinsic validity as documented.

Candidate checks cover geometry, envelope consistency, reference span bounds, every selected cloud member's length and native thermochemistry, cloud interactions, reconstructed joint support, and intrinsic specificity. Final validation rechecks assignment IDs, uniqueness, integer pool bounds and caps, then reconstructs intrinsic and same-pool pair results using fresh evaluator/checker state. It recomputes full and interior interval unions independently. Sharing pure rules and Task 1's uncached anchor helper is consistent with the explicit independence ruling; no search verdicts or support caches feed final validation.

Profile serialization records specificity revision, secondary-product policy, coordinate and distance conventions, ambiguity and mismatch rules, resolved chemistry, bounds, pools, and caps. The chemistry settings are snapshotted and the existing upper-Tm offset is recorded. These modules return records rather than publishing scientific output; enclosing workflow provenance remains a later integration responsibility.

## Verification

Executed in the fork's existing `.venv`, using only deterministic synthetic fixtures:

```text
.venv/bin/python -m pytest tests/lge/test_coverage_validation.py tests/lge/test_coverage_catalog.py -q
32 passed in 0.26s
```

Additional inline synthetic assertions passed:

- A 23-base primer with a 19-base terminal k-mer and a duplicated 200-base product yields exactly the off-anchor `[300,500)` witness at D=200 and no eligible off-anchor witness at D=199. This independently exercises the full-footprint bound where oligo and terminal lengths differ.
- Five malformed full/interior geometries, including negative anchors, anchors beyond the reference, out-of-reference envelopes and crossed interior bounds, return invalid validation reports without crashing.

No production files or tests were edited. No broad biological fixtures, installations, external publication, or delegates were used.

## Limits of approval

This approves Task 2's supplied-MSA computational contract, not laboratory performance, genomic background specificity, or subsequent search/export integration. The disclosed complete hit/product enumeration can be expensive for repetitive inputs, and final uncached validation intentionally repeats work; those limitations are not hidden correctness defects in this change.
