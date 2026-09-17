# Independent v2 checkpoint prefix-join review

## Verdict

**APPROVED** `74102b8effef79f98487b4962c65b112454425d3`, against base `236e74af6b186367fd66f15e73b558a0c3e44a74`. No actionable finding. Reviewed actual HEAD **`74102b8effef79f98487b4962c65b112454425d3`**, the two-file commit diff, implementation brief/report and checkpoint-assessment addendum.

The implementation is the approved narrow physical query substitution. It changes no scientific predicate, source dependency, schema, migration, payload, ID, count, digest, cache policy, durability setting or CLI contract.

## Preserved checks and equivalence

- All three closure checks remain: assessment→evidence, event→assessment and event→parent event. Each retains the same link kind, required source stream, `source.ordinal < source_count`, `target.ordinal >= target_count`, `LIMIT 1`, execution order and rejection exception.
- V2 uses `record_links_int.source_key/target_key` joined to `records.position`. The original v2 compatibility view projects those same rows to canonical IDs. Since `records.position` is the primary key and `records.id` is unique/non-null, the old view-plus-ID joins resolve exactly the same source/target records. Removing those redundant ID resolutions does not change the closure predicate.
- The v1 SQL remains the original ID-based literal. The branch is explicitly `format_version == 2`; existing v1 read/append behavior is untouched.
- Prefix-hash validation, inherited-snapshot requirements, nondecreasing prefix counts, complete/fresh disposition checks and their ordering remain intact. There is no equal-count fast acceptance or validation skip. Full-prefix ordinal corruption still reaches and fails closure validation even when cached count/hash state otherwise matches.
- Dangling rows are not newly accepted: both old and new inner joins omit missing endpoints, while unchanged foreign-key/reload checks reject corrupt physical storage. Changed canonical IDs remain rejected by canonical payload/index verification on reload. Closure validation was not and is not a substitute for those surrounding checks.

## Test assessment and independent execution

The new tests exercise the **production `_validate_checkpoint`**, with trace assertions confirming the physical-v2 and unchanged-v1 SQL paths. They compare old-query verdicts across full, valid truncated and separately invalid evidence/assessment prefixes; exercise parent ordinal corruption at equal full counts; persist/reopen a valid truncated snapshot; compare exact v1/v2 complete snapshots and export digests; and require cold reload rejection of changed unique IDs and dangling references in both formats. Existing storage suites additionally retain inheritance, rollback, insertion faults, canonical hashes and incomplete-tail coverage. This is meaningful coverage for a query-only change; timing assertions would not establish correctness and are appropriately absent.

Independent command, in the mutable native worktree at the reviewed HEAD:

```sh
.venv/bin/python -m pytest -q tests/lge/test_coverage_history.py tests/lge/test_sqlite_coverage_history.py tests/lge/test_integer_coverage_history.py tests/lge/test_v2_checkpoint_prefix_joins.py
```

**60 passed in1.02s**, process exit0. Retained log: `/tmp/v2-prefix-joins-independent-review.log`, SHA256 `4e1eb5ea04dcaa48fad389d2bde76eacadcc4631849216c50fcad481dc52e5c2`, 99bytes. No tracked source edits were present; an unrelated untracked `tests/integration/tmpjjpfndng-schemecreate/` directory was observed and left untouched. Implementer separately reports53 cache/inspection/benchmark tests passing; those were not repeated here.

## Limits

No live cold database/output access, scientific run, frozen source edit or production edit. The active v1 cold history receives no benefit. The SQL algebra supports equivalent results and fewer redundant lookups, not a measured end-to-end speedup. Root retains responsibility for the next frozen full-suite gate.
