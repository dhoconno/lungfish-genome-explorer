# Coordinator's Task 6 independent verification

All three completed HLA bundles passed the retained read-only coordinator verifier in `outputs/task6-root-final-verification-2026-09-13`. Its `provenance.json` records exact scripts and argv, Python/runtime identity, every consumed bundle file and nine original human alignment files at start/end, status, wall time, stderr and nine final output descriptors. The coordinator rehashed those descriptors after completion; sources and inputs were unchanged and every exit status was zero.

For each bundle, the verifier checked all 175 wrapper descriptors against final bytes, the exact 176-file bundle inventory, every wrapper output's absolute final stored path/hash/size, all 31 native output descriptors and nine stored native inputs. Native inventory allows only the specifically manifest-listed LGE-derived `ordering-v1.csv` in addition to native-producer files; it does not permit arbitrary extras. It mapped all nine loci through manifest result input IDs and catalogue source indices, compared original alignment snapshots with current human inputs and normalized consumed FASTAs with native input descriptors, checked exact reference sequences and lengths, and independently checked every selected full/interior BED interval and every cloud oligo's sequence, individual footprint, strand and pool. Literal sets of covered bases reproduced all reported full/interior fractions.

| Run | Candidates | Selected | C full / interior | E full / interior |
|---|---:|---:|---:|---:|
| Wide 150–280, 120 seconds | 50,969 | 24 | 46.7757% / 40.6903% | 44.3825% / 36.3045% |
| Narrow 180–220, 120 seconds | 16,376 | 29 | 56.4033% / 44.6866% | 68.8951% / 60.3528% |
| Wide 150–280, 600 seconds | 50,969 | 24 | 46.7757% / 40.6903% | 44.3825% / 36.3045% |

Both wide catalogue semantic digests are `b75e1380a1a73c90a72f469a6e3598c619716aade5ddf02631e383df7d2415ae`; narrow is `f0900d997d87ada27bf9922463cefef3986fb15213e814adabde2109f3c601a0`. Coverage here is reference-coordinate coverage, not an allele amplification percentage. These checks independently verify exported scientific geometry and provenance; they do not duplicate the native biochemical rule engine or establish experimental amplification.

The coordinator also independently checked the final synthetic artifact at `outputs/task6-synthetic-100-target-2026-09-13`: all four output descriptors and exact inventory, source commit `7b6148b6f80d70052fa2ed8aa3a44d4def3e8954`, unchanged source/runtime/inputs, exactly 100 targets/300 candidates/200 conflict edges, unique pool-zero assignments, all spans 150–280, absence of every declared graph conflict and literal unions of 260 versus 300 bases for each target. Greedy selected 100 candidates for 26,000 bases; repair selected 200 for 30,000. Both search metadata records retain abstract-oracle scope and completed status. This establishes the declared combinatorial fixture result only.

Final read-only environment check still reported managed PrimalScheme3 `3.3.0+lge.2`. The original checkout's pre-existing modified `Package.resolved` remains outside both implementation worktrees and was not edited by this task.
