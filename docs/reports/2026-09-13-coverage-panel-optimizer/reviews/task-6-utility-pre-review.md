# Task 6 utility pre-review

Read-only inspection on 2026-09-13 of native commit `7b6148b6f80d70052fa2ed8aa3a44d4def3e8954` over `39aea29d2776d0aa43615cf8931917763a602682`, scoped to `scripts/benchmark_coverage.py` and `tests/lge/test_benchmark_coverage.py`, against `task-6-brief.md` and `task-6-preflight.md`.

No important defect identified in the supported benchmark path. This is a utility pre-read, not final Task 6 or whole-branch approval. Documentation commits, final HLA evidence, and the final report remain pending.

The retained utility invokes the actual `search_assignments` core with an explicitly abstract graph oracle. The deterministic target fixture has the declared greedy 260-base candidate and two disjoint 150-base alternatives, with only the two intended same-target graph edges. Search and independent validation remain separate: the latter checks identity, duplicates, pool range, declared graph conflicts, full-span bounds, and literal full/interior interval unions. The known all-B+C alternative is separately checked. The result retains search options, limits, completed work, stop reason, objective metadata, assignments, oracle calls, and independent validation. It does not claim chemistry, MSA, or panel-v1 biological validation.

Output creation refuses existing directories, including the second-invocation case covered by the focused tests. The normal success/failure finalization path records exact argv, resolved settings, runtime/native-kernel/source identity, start/end stability, logs/status, and actual final output sizes and hashes; output descriptors use relative paths. Tests exercise a small four-target example, expected repair behavior, work metadata, provenance byte integrity, and preservation of an existing output directory.

Reporting qualifications: `peakPythonAllocatedBytes` is the traced process allocation peak after `tracemalloc.reset_peak()`, including retained baseline allocations, not incremental search-only allocation. RSS is correctly labeled a cumulative process maximum; its per-run sample occurs after the independent validation. The final report should retain these qualifications and should not compare the two readings as isolated fresh-process memory measurements.

No tests or biological workloads were run during this pre-read, to avoid disturbing the timed HLA runs. Previously reported test outcomes have not been independently rerun here. No production or test files were edited.

Whole-branch review preparation also read the native publication/provenance lifecycle, LGE options/capability/native-output/publication boundary, and `task-2-root-boundary-check.md`. Resolved Task 4 and Task 5 findings were not reopened absent new breakage. The final review must identify the eventual completed commits and run artifacts before giving a verdict.
