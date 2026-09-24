# Primer pack and MHC validation — 2026-09-24

Status: implementation, scoped reviews, integrated build and recorded native/GUI acceptance complete on `codex/primer-pack-olivar-varvamp`. Kept isolated for review; not merged or released.

## Scope and inputs

The optional `pcr-primer-design` pack adds Olivar 1.3.3 and varVAMP 1.3.2 in separate native arm64 environments, alongside Primer3 2.6.1 and PrimalScheme3-LGE 3.3.0+lge.5. Exact package builds, lock hashes and adapter source checks are recorded in the implementation and execution provenance.

The original `/Users/dho/Desktop/sandbox/mhc-primal-scheme/mhc-primal-scheme.lungfish` is read-only for this work. The validation copy is `/Users/dho/Documents/lungfish-validation/primer-pack-2026-09-24/mhc-primer-validation.lungfish`. All 906 files (358,678,042 bytes) were compared by path, SHA-256 and size during copying; the original was unchanged. Copy script and provenance are retained beside the copy.

The same 11 alignment inputs are used for the baseline comparisons: KIR2DL04, KIR3DL10, KIR3DS, Mamu-A1, Mamu-A2, Mamu-A4, Mamu-B, Mamu-DPA, Mamu-DQB, Mamu-DRB and Mamu-E. They contain 6–12 rows and span 1128–7094 alignment columns. Existing analyses are retained.

## Actual installation and portability

A fresh product-code install of all four tools completed successfully in 379.89 seconds. Product offline export succeeded. A final corrected offline import succeeded in 220 seconds, using archive SHA-256 `f2a435161ff93f378de69bb205ac7d1c0781072d7b9f2cc21ccb2658218db015` (1,102,240,202bytes).

The original installation path was removed. The imported runtime was then moved to a path containing spaces, verified, moved again to its final location, and verified again with all prior paths absent. At both locations, all four launchers passed, both new tools imported from their current environment, and Olivar's MAFFT and BLAST dependencies passed. Exact argv, environment, exit status, timing, log checksums and paths are retained in `runtime-relocation-provenance.json` and 16 per-command logs under the external validation directory. Final runtime: `/Users/dho/Documents/lungfish-validation/primer-pack-2026-09-24/runtime`.

The first archive import exposed 0775→0755 permission normalization: file hashes and sizes were unchanged. Readiness now validates content and executable semantics while import provenance records actual source/destination modes. A subsequent legacy-pack review identified additional compatibility and repair-rollback fixes; those fixes are complete and independently reviewed. Nine targeted migration/rollback/CLI tests passed; the legacy archive behavior is covered by fixtures, separately from the completed current-format native matrix.

## Native MHC execution

`scripts/analysis/validate-primer-pack-mhc.py` invokes the public CLI separately per input/case, records exact commands, exit status, timing and logs, and validates saved bundle hashes, provenance, bounds, identities and probe membership. It does not loosen constraints after failure. Nine synthetic harness tests passed, including input/output alias rejection, failed-command classification and rejecting exit 0 without a valid saved result.

Baseline tiled bounds are 360–440 bp with nominal target 400 bp for all three engines. varVAMP single uses the same bounds. qPCR uses 70–200 bp with nominal 135 bp and an explicit cumulative threshold 0.95. Advanced cases are representative non-default settings, narrower/wider bounds and invalid input constraints; native validation does not imply every possible numerical combination was tested.

Completed baseline results (55 cases):

| Tool/mode | Inputs | Outcome |
|---|---:|---|
| PrimalScheme tiled | 11 | 11 passed |
| Olivar tiled | 11 | 9 passed; Mamu-DQB and Mamu-DRB reported no primer pair within 360–440 bp for a tile. Diagnostics retained; no bounds relaxed. |
| varVAMP single | 11 | 11 passed |
| varVAMP tiled | 11 | 11 passed |
| varVAMP qPCR | 11 | 11 passed, including saved probes |

Thus 53 cases produced valid saved results and two had valid native infeasibility outcomes. Completed reports verified the validation input inventory remained unchanged.

Representative KIR2DL04 advanced cases produced 11 successful designs and three expected invalid-bound rejections: PrimalScheme variant frequency and narrow/wide bounds; Olivar variant frequency, degenerate design, seed and narrow/wide bounds; varVAMP tiled threshold/overlap, single alternatives/ambiguity settings, qPCR probe ambiguity/test count and narrow/wide bounds. Reports are in `advanced-primal-v6`, `advanced-olivar-v7` and `advanced-varvamp-v7`.

Two actual auxiliary-input cases passed using unchanged local MHC compatible-primer and BLAST fixtures. Both outputs were renamed and audited for durable paths, exact options and checksums (`auxiliary-acceptance-v7/report.json`). A two-input varVAMP single request passed with repeated native names correctly distinguished by target identity (`batch-varvamp-single-v6`).

The two-input combined Olivar case exposed duplicate native reference names from identical `primary.aligned.fasta` basenames. Olivar internally keyed results by that name, allowing the second target to overwrite the first. Commit `0798e4e63` now passes the existing unique input UUID title to preprocessing. An actual two-MSA adapter run passed in 17.75 seconds, retaining three assays for KIR2DL04 and four for KIR3DL10, all within bounds. Independent review verified all 42 manifest entries and the exact committed adapter bytes. The final rebuilt public CLI passed both combined (57.7 seconds, two targets, seven assays) and independent (80.6 seconds, one target, three assays) runs using managed runtime preparation. Reports: `final-olivar-combined/report.json` and `final-olivar-independent/report.json`.

The mapping defect was in validation, not native design. A collapsed block can retain its original coordinate width while still representing a lossy gap replacement; Olivar can also emit zero-width generated blocks for removed gap columns. These blocks must remain explicitly non-exact for binding comparison.

## Focused verification

The shared workflow passed 52 focused tests (45 workflow and 7 CLI), plus 35 compatibility tests for existing PrimalScheme publication and bundle behavior. Tests exercised relocation/reopening without Python, qPCR triples, exact result membership, failure evidence, cancelled runs, file tampering and equal/zero-width collapsed projection blocks. The native adapter suite ran 27 host tests: 24 passed and 3 optional native tests were skipped in that host invocation; separate native matrices passed 24/24 for each new tool against both smoke and product-installed environments.

The v6 CLI used for the new-engine MHC runs has SHA-256 `a99cbaf8d56381e681df6fa36268c51a8ce345f9a4706cdc8a8fb503ba0e73fc`; the embedded adapter digest is `86532143d9864dfc728af1823bdb540c063c6dad996208b5211d2a74e7a4e4d9`. Exact tested-source hashes and logs are retained under `task3-v6-verification`. The v7 CLI (SHA-256 `4b67942114367732f034c031c6734adf78eb814628ab127c96af0a5bfb2e88f9`) adds durable auxiliary/default-option provenance fixes. Their covering tests passed: 18 normalization, eight CLI and one amended auxiliary-publication regression. Independent review accepted all three fixes. The latest combined-identity adapter suite ran 28 tests: 25 passed and three opt-in native tests skipped. The final integrated feature workflow suite passed 60/60 tests (18 normalization, 11 options, 23 pipeline, eight CLI). The GUI/export suite executed 77 tests: 74 passed and three optional checks skipped. A fresh mode-default regression passed separately. Native viewer and visual tests passed in their separately recorded runs.

## Evidence and test incidents

Large evidence is retained outside Swift/SDD scratch at `/Users/dho/Documents/lungfish-validation/primer-pack-2026-09-24`. `pack-evidence` retains the exported archive, installation/import logs, adapter contract and detailed task reports. The complete SDD review/acceptance workspace is preserved as `sdd-evidence` (including earlier native snapshots), with its atomic relocation recorded in `sdd-evidence-relocation.json`. The final GUI evidence project is byte-verified at `gui-final-evidence.lungfish` (1,489 files); copy provenance maps its historical private-project paths. The temporary verifier’s 21 modified/new source files and patch are preserved in `verifier-source-snapshot` before removing that owned worktree. The feature worktree remains available.

An early native test supplied an unsupported space-containing managed-storage override. Existing CLI behavior silently fell back to `/Users/dho/.lungfish-stable/conda`, checked Primer3 and attempted PrimalScheme repair before failure/rollback; it did not install Olivar or varVAMP there. A full subsequent verification of the existing PrimalScheme receipt's 37,399 files found zero hash/size/symlink mismatches; there was no pre-test receipt hash, so this is rollback evidence rather than a direct before/after identity proof. Caches may have been accessed. The CLI now rejects an invalid effective storage override before mutation.

One `swift package clean` removed ignored early smoke environments, raw smoke evidence and the first disposable MHC copy from `.build`. The original project and later native acceptance evidence remained intact. The validation copy was recreated and verified outside `.build`; no deleted raw files are claimed retained. A later probe used the incorrect import spelling `Olivar`; correcting it to the installed module `olivar` completed the relocation checks without a product change.

The first portable Debug build (2026.9.40) passed the supported release script's identity, resource and relocation checks. Actual GUI inspection opened native qPCR output, selected a probe, entered binding inspection and zoomed the alignment. All three varVAMP modes appear in the design selector, qPCR requires its explicit threshold, Advanced settings expands, and invalid bounds disable Run. Review identified contextual-export, display-pool, unavailable-binding and related presentation defects; their fixes passed independent review and final integrated checks.

The GUI project's copied session lock initially referred to the original live Preview project. After cancelling the warning and verifying that origin, only the disposable GUI copy's inherited lock was quarantined as `gui-inherited-project.lock`, with copy provenance updated. The original and native acceptance copy locks were left intact. The GUI copy then opened normally.

The tested archive was additionally imported through the product CLI into the previously absent `/Users/dho/.lungfish-debug/conda/envs`, with an explicit destination and no overwrite. All four tools installed in 272.78 seconds. This enabled real GUI dispatch without changing preferences or Preview tools; installation provenance is retained in that root and `gui-debug-pack-install`.

Three actual GUI runs on the disposable KIR2DL04 alignment completed: Olivar basic in 68 seconds, varVAMP qPCR with advanced settings in 113 seconds, and PrimalScheme basic in 87 seconds. All saved bundles passed integrity/provenance/span audits. The qPCR output retained three assays and three probes; its resolved provenance exactly matched the specified threshold, min/nominal/max sizes, probe ambiguity and test count. The original project and native acceptance copy both still matched all 906 initial file hashes in the post-validation audit and again after final GUI checks (`mhc-final-unchanged-audit.json`).

The final Astra whole-branch review identified one important order-pool grouping defect and a minor duplicated binding warning. Both were fixed in `10899052b34a82423073f23c04d9b1611a6c6960`, then accepted in a fresh scoped review. The final focused suite executed 24 tests: 22 passed, two optional skips, zero failures. Pooled ordering now groups by result identity and native pool, while unpooled alternatives keep assay/status/rank labels. Explicit unavailable-projection reasons suppress generic guidance that cannot resolve them.

The supported final build, `python3 scripts/release/release.py debug --portable --jobs 4`, completed with identity, CLI/resource, signature and relocated-app smoke checks passing. `reviewed-debug-artifact.json` records the reviewed app and source identity. Its CLI SHA-256 is `1e76254112c4db3fc185a70069877de07adef32b6fef05a461ccc08df31349d2`, and its adapter digest is `870e0578120c89bc6d5f55b19f7f9201eef2ed7d61df04ab05e82eb5df589f2a`. These are identical to the final combined/independent native acceptance artifact; the last fix changed only app ordering and binding presentation.

A rebuilt ad-hoc Debug signature encountered a macOS Documents permission gate during GUI loading. Read-only diagnosis found the prior grant tied to the previous signature; a direct snapshot regression passed in 3.110 seconds. No OS permissions were changed. A mode-0700 private temporary copy, with byte-verified source-copy provenance, loaded normally and was used for the remaining GUI checks. The original project stayed untouched.

Final live GUI checks passed: tiled→qPCR→tiled defaults (360/400/440 → 70/135/200 → 360/400/440), probe selection/binding, and the alternative-assay context menu without invented pool actions. Contextual exports produced one probe FASTA, its three associated oligos, and a 138 bp reference amplicon with three shifted annotations. Their 44/44/46 provenance entries passed hash, size and final-path audits. The fresh Debug runtime initially lacked core samtools; that first export failed clearly. Installing pinned samtools into Debug only took 22.09 seconds, and the retry passed. This dependency setup and the failed attempt are retained in the evidence.

Two final real GUI order exports passed. Olivar's six oligos remained in two native pools (four and two rows), verified in the actual IDT workbook. varVAMP's nine oligos remained three unpooled assays with three probes, candidate labels and no vendor pool-upload workbook. Both review workbooks and CSVs matched the JSON records, and all 319 provenance file hashes, sizes and final paths matched. See `gui-order-export-audit.json` and `gui-contextual-export-audit.json`.

The Debug app is an ad-hoc local test artifact, not a distributable Preview release. Tests cover software installation, execution, data integrity and interface behavior; they do not establish experimental assay performance or exhaust every numerical option combination.

## Controller decisions and tradeoffs

The following rulings were recorded during implementation and are retained here after scratch cleanup:

1. Tasks 1 and 2 ran in parallel with disjoint source ownership; commits and shared builds were serialized. A mistaken ownership boundary would cost integration and retesting.
2. Launched failures retain restrictive hidden sibling diagnostic directories instead of successful-looking bundles. The tradeoff is diagnostic storage; preflight rejection needs no output directory.
3. Commands use the existing plural `lungfish primers design` root, correcting the plan spelling. A contrary alias expectation would require a documentation/API follow-up.
4. Managed storage retains its existing space-free policy; invalid effective CLI overrides now fail before mutation. Relocated launchers were separately tested with spaces. The deliberate behavior change is an error where the old CLI silently fell back.
5. Native validation evidence moved outside `.build` after the clean incident; no more wholesale clean was used. This costs retained disk space and cannot recover the deleted early raw evidence.
6. Native oligo names are unique per target, with globally unique stable IDs. varVAMP reuses names across independent targets. If consumers assume globally unique names, they must use the saved target/result identities and be retested.
7. A detached verifier allowed independent compilation with exact source hashes and a final integrated feature build. A mismatch would require integration retesting; the temporary verifier's source snapshot is preserved before removal.
8. Additional advanced/batch acceptance could use the exact installed Python path to avoid readiness-lock contention; baseline calls and final product CLI checks kept managed preparation. If runtime preparation changes those outcomes, the advanced cases must be repeated through that path.

