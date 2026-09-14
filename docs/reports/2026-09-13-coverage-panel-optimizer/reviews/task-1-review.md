### Spec Compliance

- ❌ Issues found: duplicate targets are assigned occurrence suffixes in source-MSA-number order, so source renumbering can change semantic candidate identities and the catalogue digest when otherwise identical target alignments carry different primer pairs. `_target_records` sorts by `msa_index` before assigning `occurrence` (`primalscheme3/panel/coverage_catalog.py:58-69`), then candidates bind their identity to that occurrence-bearing target ID (`primalscheme3/panel/coverage_catalog.py:254-260`). A focused synthetic probe that swapped the source numbers of two duplicate alignments with distinct primer geometries returned `digest_equal False`. Assign duplicate occurrences using a canonical per-MSA scientific signature, such as the sorted candidate geometry/actual-oligo signature, and use source numbering only to order scientifically indistinguishable duplicates.
- ⚠️ Review limitation: this was a Task 1 gate only. I did not inspect downstream tasks or broadly crawl unchanged code, and I did not rerun the routine test suite. The supplied package output truncated the middle of the new catalogue hunk, so I read that changed module directly to complete the review.

### Strengths

- The records are frozen, and the cached `MappingProxyType` ID maps are built once and excluded from equality/hash where appropriate (`primalscheme3/panel/coverage_types.py:44-105`).
- Candidate construction keeps actual 5′-to-3′ reverse oligos, uses first-reference ungapped anchors, requires same-row forward/reverse matches, and keeps native objects outside candidate identity and the semantic payload (`primalscheme3/panel/coverage_catalog.py:178-305`, `primalscheme3/panel/coverage_catalog.py:368-398`).
- Terminal missing cells remain distinct from internal gaps; IUPAC/N observations become uncertainty rather than confirmed support (`primalscheme3/panel/coverage_catalog.py:52-55`, `primalscheme3/panel/coverage_catalog.py:122-175`).
- Serialization uses canonical JSON and deterministic gzip metadata, then reports the SHA-256 and size of the actual compressed bytes (`primalscheme3/panel/coverage_catalog.py:401-427`). The report records 10 focused tests passing and 43 existing LGE tests passing; the two suite warnings are identified as pre-existing Typer deprecations.

### Issues

#### Critical (Must Fix)

None.

#### Important (Should Fix)

- `primalscheme3/panel/coverage_catalog.py:58-69`: duplicate-target occurrence identity depends on source numbering, violating the required semantic invariance to input renumbering. This also changes candidate IDs and the semantic digest through `target_id` at `primalscheme3/panel/coverage_catalog.py:254-260`. Use a canonical scientific tie-break for duplicate alignments and add a regression test with duplicate rows, different primer pairs, and swapped source indices.

#### Minor (Nice to Have)

- `.superpowers/sdd/2026-09-13-coverage-panel-optimizer/task-1-report.md:1`: the scratch implementer report is tracked in the task commit. Remove it from the Git change as already planned; this is housekeeping and does not affect the scientific review.

### Assessment

**Task quality:** Needs fixes

**Reasoning:** The implementation is otherwise cohesive and directly tests the difficult geometry, support, immutability, and deterministic-output contracts. The duplicate-occurrence ordering bug is load-bearing because an allowed metadata-only renumbering changes scientific IDs and the catalogue digest.
