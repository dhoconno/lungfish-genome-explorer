# Task 4 fix round 2 review

Reviewed `8e1adcf..a0e3313`, the remaining P2 cases in `task-4-fix1-review.md`, and the second fix report. Scope was the numeric validation changes and their focused regressions only.

- Remaining original P2: **ADDRESSED**.
- Spec compliance: **PASS for this scoped fix review**.
- Code quality: **PASS**.
- Important new breakage in the fix diff: **none identified**.
- P1 ownership/finalization remains **ADDRESSED** from round 1; neither its implementation nor pipeline code changed in this diff.

## Why P2 is addressed

The single typed `_COVERAGE_NUMERIC_OPTIONS` inventory drives both raw validation and effective checks. It separates coverage scientific fields from new selector settings so existing legacy scientific coercion remains unchanged. Coverage normalizes real-valued defaults before the existing runtime-type-based assignment, removing the integer-default truncation problem while retaining finite-value checks.

All four remaining cases are resolved at the appropriate boundary:

1. `primer_homopolymer_max=True` fails raw integer validation before assignment.
2. `primer_max_walk=1.7` fails raw integer validation before assignment.
3. `editdist_max=2` fails the declared single-mismatch constraint during Config construction, before discovery, catalogue writing, or output ownership.
4. `primer_hairpin_th_max=51.9` remains float `51.9` in Config and the serialized immutable ConstraintProfile. Its integer-valued class default no longer truncates this coverage option.

The inventory retains the existing positive/nonnegative and unit-interval constraints, finite checks for reals, and published supported edit-distance policy without introducing arbitrary new scientific ranges. Derived preset values and unsupported experimental settings remain outside the caller-set coverage numeric path. Tests explicitly retain the historical legacy resolutions for fractional hairpin and walk values, boolean homopolymer values, and positive programmatic edit-distance/product-size behavior.

## Verification

Reviewer ran only the four directly relevant regressions:

```text
.venv/bin/python -m pytest tests/lge/test_coverage_cli.py -q -k 'boolean_homopolymer or fractional_primer_walk or unsupported_edit_distance or fractional_hairpin'
4 passed, 44 deselected, 2 warnings in 0.56s
```

The two warnings are existing Typer/Click deprecations. `git diff --name-only 8e1adcf..a0e3313` confirms changes only in `primalscheme3/core/config.py` and `tests/lge/test_coverage_cli.py`; tracked worktree status was clean.

Accepted supplied evidence, not reviewer reruns:

- RED: 4 failed, 44 passed before implementation.
- `.venv/bin/python -m pytest tests/lge/test_coverage_cli.py -q`: 48 passed.
- `.venv/bin/python -m pytest tests/lge -q`: 140 passed.
- Scoped Ruff, format, compileall, and diff checks passed as recorded in `task-4-fix2-report.md`.

No production edits, delegates, full-suite reruns, biological runs, managed changes, installs, or publication. Only this ignored scratch review report was written.
