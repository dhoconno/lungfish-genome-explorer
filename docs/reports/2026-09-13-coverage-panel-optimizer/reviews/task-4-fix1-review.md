# Task 4 fix round 1 review

Reviewed only `cbcdde0..8e1adcf`, the original two findings, Task 4 brief, and fix report, with adjacent source reads needed to trace the changed boundaries. No production edits, delegates, biological runs, dependency/managed-environment changes, or broad test reruns.

- Original P1: **ADDRESSED**.
- Original P2: **NOT ADDRESSED fully**; its literal examples are fixed, but the same numeric boundary remains incomplete.
- Spec compliance: **FAIL pending the remaining P2 validation cases**.
- Code quality: **NEEDS FIXES** for the same incomplete validation inventory.
- Important new breakage introduced by the fix diff: **none identified**. The finding below is a remaining part of original P2, not an algorithm review expansion.

## P1 — ADDRESSED: current invocation owns failure finalization

`panel_main.py` now creates per-invocation state, marks output ownership only after coverage preflight and non-force existing-directory refusal, and invokes outer failure finalization only for an owned, unfinished invocation. File existence no longer substitutes for current-run finalization. `coverage_pipeline.py` marks finalized only after the current success/failure finalizer completes.

Consequently an early discovery failure in a forced rerun replaces stale success provenance with this attempt's failure and current final-byte descriptors. Unsupported-mode and non-force calls return before ownership, so they preserve existing output bytes. The new tests cover stale success, current argv/input identity, every final output hash/size and exact inventory, plus byte-preserving refusals. The surrounding provenance routine flushes logging before inventory. No remaining P1 issue was found within this fix scope.

## P2 — NOT ADDRESSED fully: raw scientific validation still permits lossy values and late rejection

Location: `primalscheme3/core/config.py:140–166` (new raw coverage guards), `:224–252` (new effective range/finite guards), and existing `:354–357` coercion through which these guards still pass values.

The fix correctly rejects fractional new optimizer integers, boolean/fractional listed coverage integers, raw booleans in the listed scientific floats, nonfinite values, and out-of-range base frequency. It keeps existing scientific legacy coercion isolated. However, the new coverage-specific validation inventory is incomplete:

1. `primer_homopolymer_max=True` is absent from the raw integer guard and silently becomes integer `1`, changing a real scientific constraint.
2. `primer_max_walk=1.7` is absent from the raw integer guard and silently becomes integer `1`, changing the discovery walk limit.
3. `editdist_max=2` passes the new raw integer check but has no supported-value check. `ConstraintProfile.from_config` rejects it with `panel-v1 supports the existing single-mismatch policy only`, yet native profile construction remains after discovery and catalogue output in `coverage_pipeline.py`. This is still a public-boundary rejection occurring too late.
4. `primer_hairpin_th_max=51.9` passes the newly added scientific-float guard but resolves to integer `51`: the field is annotated float while its default is integer `51`, and `assign_kwargs` selects coercion using the current value's runtime type. The finite check sees the already-truncated result. This is the same lossy-validation gap, even though this field was included in the new list. Fractional scientific thresholds must be retained accurately for coverage (or explicitly rejected by a declared contract), while historical legacy coercion remains unchanged.

Required completion: inventory numeric values actually consumed by coverage discovery and the published profile; validate their raw types, finite values, and supported ranges before generic lossy coercion or output ownership. Check runtime default types as well as annotations. Put unsupported profile-setting failures such as editdist policy at the pre-discovery boundary. Preserve the existing legacy coercion and programmatic mismatch-product-size API. Add direct Python regressions for the four cases above, retaining the existing CLI NaN and ownership regressions.

## Reviewer evidence

Two small read-only `.venv/bin/python - <<'PY'` probes constructed `Config` using otherwise valid coverage options:

```python
options = dict(
    selection_algorithm='coverage',
    amplicon_size=200, amplicon_size_min=150, amplicon_size_max=280,
    amplicon_size_metric='reference-span', mismatch_product_size=2000,
)
```

The first constructed each configuration and attempted `ConstraintProfile.from_config`:

```text
editdist_max: raw=2, resolved=2
late profile rejection: panel-v1 supports the existing single-mismatch policy only
primer_homopolymer_max: raw=True, resolved=1
primer_max_walk: raw=1.7, resolved=1
```

The second checked effective hairpin threshold types after the coordinator identified the default-type mismatch:

```text
coverage primer_hairpin_th_max: raw=51.9, resolved=51, resolved_type=int
coverage primer_hairpin_th_max: raw=-0.5, resolved=0, resolved_type=int
legacy primer_hairpin_th_max=51.9 resolves 51
```

The negative example demonstrates truncation toward zero; this review does not invent a new permissible hairpin-temperature range. The loss of the requested fractional value is sufficient evidence.

Accepted supplied verification, not reviewer reruns:

- `.venv/bin/python -m pytest tests/lge/test_coverage_cli.py -q`: 44 passed, 2 warnings.
- `.venv/bin/python -m pytest tests/lge -q`: 136 passed, 3 warnings.
- Scoped Ruff check, format check, compileall, and diff checks passed, as recorded in `task-4-fix1-report.md`.

These green tests support the addressed examples but do not cover the remaining numeric cases above. No test or code file was changed by this review; only this ignored scratch report was written.
