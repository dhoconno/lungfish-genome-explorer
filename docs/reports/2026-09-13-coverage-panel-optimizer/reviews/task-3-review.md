## Spec Compliance

- ❌ Issues found: the required three-pool repooling regression is not established by `tests/lge/test_coverage_search.py:183`; a focused comparison proves its entire improvement occurs during construction, with zero accepted repairs. Other reviewed Task 3 requirements are implemented.
- ⚠️ Scientific candidate identity/discovery correctness and output-bundle provenance span Tasks 1/2 and native integration; this search-only diff neither rewrites those contracts nor writes artifacts. The controller's independent native probe is separate evidence, not a claim of full HLA coverage.

## Strengths

- `primalscheme3/panel/coverage_search.py:170`: the seven-term objective uses merged interval coverage, normalized shortfall, actual unique oligo burden, pool imbalance, and length deviation in the specified order. Canonical symmetric pool signatures resolve ties.
- `primalscheme3/panel/coverage_search.py:265`, `:272`, `:371`: fixed unary checks and canonical symmetric pair checks are lazy and memoized; complete per-target queues advance beyond the bounded frontier. Explicit attempt/move limits and wall-cutoff limitations are serialized rather than presented as exhaustive search.
- `primalscheme3/panel/coverage_search.py:483`, `:508`: cleanup and one/two-neighbor trials rebuild state, enforce caps and pair/unary validity, and retain only improving feasible incumbents. Relocation and refill code is present; the issue below is that its three-pool acceptance test does not exercise it.
- `primalscheme3/panel/coverage_search.py:616`, `:712`: supplied baselines are checked, the empty incumbent remains available, and the native wrapper always creates the scientific oracle and independently validates the result. A rejected proposal records diagnostics, returns a freshly validated baseline/empty fallback, and recomputes final objective/per-target metadata.
- `tests/lge/test_coverage_search.py:139`, `:365`, `:424`, `:461`: independently enumerated objectives, a real scientific 260-to-300 repair fixture, poisoned-search rejection, and a two-blocker replacement provide substantive coverage. No abstract oracle is passed through the native wrapper.

## Issues

### Critical (Must Fix)

- None.

### Important (Should Fix)

- `tests/lge/test_coverage_search.py:183`: `test_three_pool_repool_preserves_displaced_coverage` does not prove a repool opportunity is solved by repair. Running this exact graph/baseline with `starts=1` and `repair_rounds=0` already selects all five candidates, with A/B/C in pool 0, D in pool 1, E in pool 2. With one repair round it returns the identical assignment and `repairs_accepted=0`; objective history contains only baseline/construction phases. This explicitly required regression would pass if relocation repair were broken or removed. Replace or strengthen the fixture so construction alone leaves a demonstrably inferior incumbent and repair must relocate selected candidates to attain the independently checked better objective. Assert the no-repair result, the improved result, and the necessary feasible relocation/repair evidence, rather than final coverage alone.

### Minor (Nice to Have)

- `.superpowers/sdd/2026-09-13-coverage-panel-optimizer/task-3-report.md:137`: the approved regression run reports two warnings, identified at line 149 as pre-existing Typer/Click deprecations. These are inherited test-output noise rather than a Task 3 regression; track separately and do not broaden this task to fix unrelated dependencies.

## Assessment

**Task quality:** Needs fixes.

**Counts:** 0 Critical, 1 Important, 1 Minor.

**Reasoning:** Production selection, bounds, repair state, deterministic ordering, and scientific final-validation fallback are coherent and comply with the scoped requirements. Approval is blocked on the missing actual three-pool relocation regression; no additional consequential production defect was found.

## Checks

- Read the task brief, report, authoritative search/specificity requirements, and complete review diff. Initial combined tool output was truncated during cleanup; recovered the unread remainder from the diff file. No changed production file was read separately, and no external implementation code was inspected.
- Ran one focused in-memory Python comparison using the existing three-pool test graph/baseline with repair rounds 0 and 1. Both returned `[('A', 0), ('B', 0), ('C', 0), ('D', 1), ('E', 2)]`, `repairs_accepted=0`, and identical construction-only improvement histories. This directly resolves the named risk that the repooling test could pass without repooling.
- No broad suites, redundant test reruns, git mutations, production edits, or delegates.
