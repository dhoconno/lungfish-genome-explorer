# Coverage panel optimizer delivery report

Date: 2026-09-13

This delivery adds an opt-in, bounded, independently validated coverage selector to
the PrimalScheme3-LGE fork and exposes it through the LGE CLI. Legacy remains the
default and keeps its managed `3.3.0+lge.2` runtime and historical argv. Coverage
requires an explicit unpublished local `3.3.0+lge.3` executable override. No managed
runtime, package pin, GUI, original scientific input, or published release changed.

## Delivered software

The native implementation is on `codex/coverage-panel-optimizer`. Scientific
benchmark execution used clean native commit
`7b6148b6f80d70052fa2ed8aa3a44d4def3e8954`, package version `3.3.0+lge.3`, and
executable SHA-256
`d14068f2278f60aeb344787870dbc229b6100e97c563342447598231fd7be76b`.
The LGE CLI integration benchmark used clean commit
`bc535d90f7c95eaae2c624ff87927a85de692bcd`, Lungfish `2026.9.21`, and CLI
SHA-256 `bb854a543cea0ec773608384c20b6a4e4c4c135b275707bc35d6977dc3785a04`.
The managed executable still reports `3.3.0+lge.2`.

The native branch contains immutable catalogue records, `panel-v1`/
`intended-sites-v1` supplied-MSA compatibility, fresh independent validation,
bounded multistart search and repair, CLI/capability integration, complete
publication provenance, coverage-owned logging, numeric validation, and the
reproducible abstract benchmark utility. LGE adds coverage-only CLI options,
capability negotiation, strict native artifact validation, final stored-path
rehydration, atomic publication and compatibility with historical legacy payloads.
The durable native behavior and command examples are in the fork's
`docs/designs/coverage-panel.md`.

## Resolved coverage contract

Coverage supports fresh linear combined whole-MSA equal panels, first-reference
mapping, explicit resolved reference-span bounds, one or more configured pools,
either `legacy` or `observed-only` terminal gaps, MatchDB enabled, and the `panel-v1`
profile. The native CLI defaults to two pools and `legacy`; the LGE frontend defaults
to two pools and `observed-only`. Defaults are full-span metric, coverage target 0.9,
seed 0, four starts, two repair rounds, 120 search seconds, and a 2,000-base inclusive
specificity product bound. Search time excludes discovery, final validation, LGE
publication and bundle loading. Count caps default to unlimited; high-GC defaults
false. All three HLA benchmark runs used two pools and `observed-only`.

Full-span and primer-trimmed coverage use literal zero-based half-open interval
unions divided by the ungapped first-reference length. The requested minimum and
maximum constrain that first-reference BED envelope. Row-specific product spans are
diagnostic and can differ through indels. Coordinate coverage is distinct from
allele support. Only fully observed joint primer support confirms a row; uncertainty
is retained as diagnostics and never promoted to empirical support. Catalogue
`unknown_rows` are unknown-only, while fresh validation can report uncertainty in a
row that another primer-cloud member confirms.

The new `--mispriming-product-size` CLI option is coverage-only for nonzero values.
Coverage requires a positive value and defaults to 2000. Legacy accepts omitted or
explicit zero and rejects a nonzero new CLI value. Existing programmatic legacy
`Config.mismatch_product_size` callers keep their historical behavior.

## Human HLA benchmark

All runs used the nine original 20-row HLA bundles A, B, C, DPA1, DPB1, DQA1,
DQB1, DRB1 and E; nominal size 200; two pools; default chemistry; minimum base
frequency 0; four cores; full-span target 0.9; seed 0; four starts; two repair rounds;
and `D=2000`. Every original input hash matched the prior audit at start and end.

| Locus | Wide 150–280, 120s full / interior | Wide 150–280, 600s full / interior | Narrow 180–220, 120s full / interior |
| --- | ---: | ---: | ---: |
| A | 42.7140% / 34.7905% | 42.7140% / 34.7905% | 38.6157% / 31.0565% |
| B | 62.6263% / 50.8724% | 62.6263% / 50.8724% | 55.3719% / 47.1993% |
| C | 46.7757% / 40.6903% | 46.7757% / 40.6903% | 56.4033% / 44.6866% |
| DPA1 | 72.9246% / 60.2810% | 72.9246% / 60.2810% | 58.7484% / 48.1481% |
| DPB1 | 77.9923% / 67.5676% | 77.9923% / 67.5676% | 58.9447% / 50.7079% |
| DQA1 | 94.9219% / 88.4115% | 94.9219% / 88.4115% | 90.1042% / 79.6875% |
| DQB1 | 91.4758% / 80.6616% | 91.4758% / 80.6616% | 56.1069% / 45.5471% |
| DRB1 | 68.9139% / 57.9276% | 68.9139% / 57.9276% | 64.9189% / 53.6829% |
| E | 44.3825% / 36.3045% | 44.3825% / 36.3045% | 68.8951% / 60.3528% |

Wide discovery produced 50,969 candidates. The 120-second selector returned 24
assignments after 120.002 search seconds, two starts, two repair rounds and 11
accepted repairs; stop reason was `time-limit`. It recorded 402,036 candidate
attempts, 7,042 intrinsic evaluations, 25,730,304 frontier evaluations, 68,587 pair
evaluations and 516 repair trials. The 600-second run completed all four starts and
eight repair rounds in 251.364 search seconds. It expanded work to 1,069,056
attempts, 9,152 intrinsic evaluations, 68,419,584 frontier evaluations, 115,382 pair
evaluations and 1,808 repair trials, while reaching the same objective and exact
same 24 assignments. Its 522 construction limit hits and eight repair limit hits
show where configured deterministic work bounds ended each unit.

Narrow discovery produced 16,376 candidates. It selected 29 assignments and
completed four starts/eight repair rounds in 91.653 search seconds, with 15 accepted
repairs, 411,648 attempts, 4,921 intrinsic evaluations, 26,345,472 frontier
evaluations, 58,696 pair evaluations and 512 repair trials. Its 201 construction
limit hits and eight repair limit hits show that extending its 120-second timeout
alone cannot add work under the configured starts, rounds and per-unit limits.
Narrow improves C and E relative to wide while its worst locus A is lower. The
lexicographic objective first minimizes worst normalized shortfall and does not
promise that every individual MSA improves.

| Run | Design wall | Native wall | Search | Stop | Assignments | `/usr/bin/time -l` maximum RSS | Peak memory footprint |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| Wide 120 | 158.787s | 153.952s | 120.002s | time-limit | 24 | 1,598,357,504 B | 863,028,520 B |
| Wide 600 | 290.191s | 285.292s | 251.364s | completed | 24 | 2,295,857,152 B | 862,979,344 B |
| Narrow 120 | 124.484s | 120.985s | 91.653s | completed | 29 | 1,165,656,064 B | 358,269,888 B |

The Darwin RSS and footprint values cover each complete LGE command, including
native discovery, selection, validation and publication. They are cumulative
process high-water measurements, not selector-only memory or a sum of simultaneous
processes. The LGE native process timeout is 86,400 seconds; its separate
30-second capability probe does not truncate search. The optimizer timeout values
above are native selector budgets.

The prior audit reported wide C/E full coverage of 84.92%/77.34% with 44 selected
amplicons and narrow C/E of 85.47%/73.63% with 45. Those outputs used historical
legacy discovery/specificity with `D=0`. The new runs use all supplied HLA rows,
`panel-v1`/`intended-sites-v1` and `D=2000`. They are different end-to-end systems
and compatibility profiles, not a controlled selector-only speed or quality
comparison. The new wide result is valid but low coverage; it is not demonstrated
improvement or evidence for making coverage the default.

Exhaustive intrinsic screening of the immutable wide catalogue found 382/1,354 C
candidates valid under the exact full-nine profile. Their literal full-span union is
913/1,101, or 82.9246%, before pair, pool and count constraints. More selector time
or more pools cannot cross that unary ceiling for this fixed catalogue and exact
profile. This is a conditional catalogue/profile bound, not biological
impossibility. E has a 1,036/1,077 (96.1931%) unary union, which does not establish
an achievable scheme. Candidate expansion or a changed profile needs explicit new
scientific evaluation; a future exact or CP-SAT optimizer would still be bounded by
unary feasibility of its input catalogue.

The four configured starts are variants of the same bounded heuristic. A comparison
of distinct selector approaches on this frozen catalogue, exact profile and objective
has been requested as a separate experiment and remains pending. The benchmark in
this report does not establish ensemble behavior.

## Abstract search benchmark

The committed `scripts/benchmark_coverage.py` ran the real `search_assignments`
core on a declared abstract-oracle fixture: 100 independent 300-base targets, 300
interval candidates and 200 same-target overlap edges, with no inter-target graph
conflicts. This did not construct biological MSAs or bypass chemistry in production.

One pool, one start and zero repair rounds selected one 260-base greedy interval per
target, covering 26,000/30,000 bases in 0.420 seconds. One repair round selected the
two disjoint 150-base alternatives per target, covering 30,000/30,000 in 13.053
seconds with 100 accepted repairs. Independent literal interval unions, unique pool
assignments, span constraints and all graph edges passed. The recorded Python peaks
were 2,093,612 and 7,564,431 bytes; `tracemalloc.reset_peak()` does not subtract
retained traced baseline objects. Process RSS values 51,134,464 and 62,652,416 bytes
are cumulative maxima and include validation before sampling. These figures do not
validate 100 biological MSA or wet-lab scalability.

## Artifact verification and provenance

The three successful final bundles are retained locally at:

- `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/primalscheme-panel-fork/outputs/task6-hla-nine-wide-lge-2026-09-13-attempt2/HLA-nine-wide.lungfishprimeranalysis`
- `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/primalscheme-panel-fork/outputs/task6-hla-nine-narrow-lge-2026-09-13/HLA-nine-narrow.lungfishprimeranalysis`
- `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/primalscheme-panel-fork/outputs/task6-hla-nine-wide-600s-lge-2026-09-13/HLA-nine-wide.lungfishprimeranalysis`

Each successful design passed `PrimerAnalysisBundle.load`, which verifies stored
bundle integrity but does not rerun the native biological validator. Independent
Python verification decompressed final catalogue bytes, mapped source indices to the
nine original inputs, checked every manifest/native/stored-input descriptor, all
final paths, catalogue digest cross-links, every selected candidate and primer cloud,
BED geometry, pools, span bounds, and literal full/interior bitset unions. A second
root-owned verifier repeated these checks against all three immutable bundles: each
had 175 LGE wrapper descriptors, 31 native descriptors, nine original/consumed input
links, and only the expected LGE `ordering-v1.csv` beyond native outputs. That audit
and its complete provenance are retained at
`outputs/task6-root-final-verification-2026-09-13` and copied into
`root-independent-checks.md` in this report directory.

Final tree identities were:

| Run | Files | Bytes | Tree SHA-256 |
| --- | ---: | ---: | --- |
| Wide 120 | 176 | 48,831,945 | `8d9782eea9a3d43b8bbadac8d1737c7bd5cd46e5a3ed85291a4972219f53e1d3` |
| Wide 600 | 176 | 48,828,383 | `f58b9ebd04be5b5c049a63033a527a63ecc1e5bccdffabdca4286dec2ddafbbd` |
| Narrow 120 | 176 | 33,005,921 | `02edc68d2d1aae3413122b2f52a15e2dbd9f709c9bb15082d7fbb4f25a1a6a8a` |

Both wide catalogues have semantic digest
`b75e1380a1a73c90a72f469a6e3598c619716aade5ddf02631e383df7d2415ae`
and exact matching C candidate geometry; the narrow catalogue digest is
`f0900d997d87ada27bf9922463cefef3986fb15213e814adabde2109f3c601a0`.
The semantic digest identifies canonical scientific contents even when compressed
publication bytes differ.

The first wide attempt is preserved at
`outputs/task6-hla-nine-wide-lge-2026-09-13`; it failed before science because the
negative dimer value was supplied as a separate CLI token. Attempt 2 used
`--dimer-score=-26.0` and completed science/publication. Its first independent
verifier used obsolete catalogue key names and failed after the immutable bundle was
already complete; the corrected separate audit is retained at
`outputs/task6-hla-nine-wide-recovery-verification-2026-09-13`. No successful design
was rerun to conceal either harness failure.

Every benchmark root retains exact argv and shell command, start/end source and
runtime identity, native extension identities, input and output checksums/sizes,
stdout/stderr, exit status, wall time and `/usr/bin/time -l` output. Source, binaries,
inputs and retained scripts remained stable during the successful runs. The output
roots are ignored and immutable; each runner refuses an existing destination.

## Review record and accepted rulings

The `reviews/` directory contains durable copies of the specificity review, every
Task 1–5 implementation/fix review, the Task 6 utility pre-review, the Task 6 review
and the initial whole-branch review. The scoped documentation fix and final branch
approval remain pending at the time this paragraph is committed.

The following eight ledger rulings are preserved verbatim, including their costs:

Ruling: Reviewers may share the pure compatibility rule implementation with final validation, but final validation must create fresh uncached state and independently recompute coverage — the independence requirement concerns optimizer state, not duplicating rule code — wrong interpretation could conceal a shared scientific rule defect, so literal fixture tests also independently verify rules.

Ruling: Non-N IUPAC sites use explicit set semantics and uncertain rows are reported; only fully observed supported binding contributes confirmed joint rows — avoids treating missing information as empirical support — cost is conservative feasibility on ambiguous alleles.

Ruling: Keep unpublished profile name panel-v1 and record specificity revision intended-sites-v1. Exempt ordered disjoint intended-site cross-combinations on the same jointly supported target row; report them as allowed secondary products. Exempt physical products intended for either of the evaluated candidates regardless of shared-oligo enumeration origin. All other eligible off-anchor/cross-target/overlap products remain conflicts; no third-candidate rescue — unconditional rejection imposed an artificial tiling ceiling and ownership-only enumeration added duplicate-oligo false conflicts — cost is an explicitly tolerated category of longer secondary products, not a claim they cannot amplify. This rule was settled from geometry before observing new benchmark coverage.

Ruling: Catalogue semantic identity hashes canonical scientific target/candidate contents and schema; source indices, filenames, exact output path and runtime worker observations are provenance metadata outside that identity — the same catalogue must remain identifiable under CLI input permutation and relocation — cost is that semantic digest alone does not identify discovery execution, which is separately covered by file SHA and complete provenance.

Ruling: Native default coverage execution uses a deterministic legacy-like construction under new rules, not a fresh unseeded legacy run with identity-hash tie order. optimize_catalog's baseline argument can retain a supplied fixed valid assignment vector, with invalid baselines explicitly rejected. Label the native baseline construction accurately; do not call it the historical legacy output — rerunning the nondeterministic old selector would defeat fixed-input/seed repeatability — cost is no automatic no-regression promise against an unsupplied historical scheme. Existing HLA outputs remain comparison artifacts under their recorded older profile.

Ruling: The new --mispriming-product-size CLI/optimizer option is coverage-only for nonzero values; legacy resolves to historical0 and rejects a nondefault new option. Existing programmatic legacy Config.mismatch_product_size values remain supported — the first CLI delivery should not imply the old checker implements panel-v1 and managedlge.2 cannot accept the new flag — cost is that callers cannot tune the historical checker through this new CLI flag; they retain its existing Config API.

Ruling: Reuse available agents for subsequent scoped reviews or tasks when the platform rejects a fresh reviewer at its thread limit; keep implementation and review authors distinct for each task — allows the authorized plan to continue within the available team — cost is retained prior-task context and possible review bias, mitigated by explicit task briefs, bounded diffs and the earlier independent task reviews.

Ruling: Preserve the native distinction between catalogue unknown-only rows and the fresh validator's broader uncertainty diagnostics. LGE must match confirmed joint rows and product spans, require catalogue unknown-only rows in the fresh diagnostics, and permit additional uncertain rows only among jointly supported rows — exact equality would reject legitimate mixed primer clouds — cost is that LGE verifies this diagnostic relationship without independently reconstructing every uncertain binding; fresh native validation remains authoritative for those details.
