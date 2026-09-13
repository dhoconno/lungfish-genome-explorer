# MHC primer workflow validation

Validation performed on 2026-09-10 CDT in the isolated `codex/pcr-primer-design` worktree. These are actual application CLI runs on human and macaque MHC records. They verify software execution, stored results, coordinates, annotations and provenance; they do not establish laboratory performance or complete-gene amplification boundaries.

## Inputs and sources

Twelve inputs cover human and *Macaca fascicularis* A, DPA1, DPB1, DQA1, DQB1 and DRB1. Each contains two authentic genomic records, selected in source order with at least 2,500 canonical DNA bases. Every selected record is retained in full, without cropping. Input records range from 2,919 to 11,468 bases. “Full” here means the entire supplied database record, not an independently established biological completeness claim.

Human data came from the official [IPD-IMGT/HLA repository](https://github.com/ANHIG/IMGTHLA/tree/5b915f27f7f620361cf83cb626eeac8a03c0247c), pinned at `5b915f27f7f620361cf83cb626eeac8a03c0247c`. Its license, README and release file are retained. Macaque data came from the application's bundled IPD-MHC genomic source, with its existing provenance copied alongside it.

| Source FASTA | SHA-256 |
| --- | --- |
| Human A_gen | `006a13f261e3bcee9397600b6d3890aa4a8e38f1d08c6144e3c9efc691ed5d13` |
| Human DPA1_gen | `0eb401d2bc16a418f10f0596f91879ec612ee434a55a1f7050a45f934344f73f` |
| Human DPB1_gen | `5d8d463290ac79395b84e2349856da8d23cf7d4375d8ea3cae807cfa29aa74ed` |
| Human DQA1_gen | `8624a3e88e0d8b84aa038af76a43283c372e757d2c8fcdbdcce334d27df5839a` |
| Human DQB1_gen | `7bb3d52ebbea299f68ab59e06cd6e4421b04b0e1151619ebb274c768d439f449` |
| Human DRB1_gen | `d9e05c13eaca329be69f0c0cb1ecd2cdafd56d23dfd233e0c85a659009250376` |
| Bundled IPD-MHC_NHKIR_Mafa_genomic | `94995672131ba233de789267db87da234fc1a2cfe92abbd7030d717a76e20386` |

All twelve alignments were created successfully with the real `lungfish-cli align mafft` workflow, retaining native MSA provenance and source metadata. Acquisition rules, original headers and record indices, hashes, sizes and exact commands are recorded under `.build/mhc-primer-validation/`.

## Executed workflows

Primer3 used the isolated native `primer3_core` 2.6.1 installation. PrimalScheme3 used the isolated 3.3.0 runtime with Python 3.12.11 and conda `primer3-py` 2.3.1 plus the complete hashed wheel lock. Its production installer, receipt validation, `pip check`, version and help probes passed separately. Scientific CLI runs used explicit executable overrides; their provenance does not falsely label these override paths as the user's managed installation.

* **Primer3 conserved MSA mode:** twelve explicit row-zero selections produced 60 pairs with no per-record errors. An independent check verified all 120 returned oligos against the original unmasked template, orientation and excluded binding positions.
* **Primer3 internal oligos:** three macaque MSA selections produced 15 pairs and 15 internal oligos; all 45 oligos passed the same independent checks. A separate raw human HLA-A record produced five pairs and five internal oligos.
* **PrimalScheme3:** eighteen successful CLI workflows cover twelve independent locus schemes, four combined DP/DQ panels and two combined six-locus panels. Each published analysis passed actual CLI integrity inspection. Native BED alternatives, files and reference sequences are retained intact.
* **Annotated reference:** the actual annotation CLI created a human HLA-A reference containing ten primer-binding features and five internal-oligo features. All fifteen retained the correct analysis/result/input links. The exact annotation argv and all three final output descriptors were verified against the stored files' hashes and sizes.

Eight named exemplar entries are retained in `exemplars.json`: for each species, class I uses A, DP uses DPA1+DPB1, DQ uses DQA1+DQB1 and DRB uses DRB1. DP and DQ entries reference both independent outputs and actual combined panels.

The first conserved Primer3 run exposed the native exclusion-list size limit on three macaque inputs. Those initial error results remain preserved. The implementation now encodes excluded binding positions as N only in the native design template, explicitly disallowing N in both primers and internal oligos. The final runs above verify that this removes the tool-format limit while retaining the original sequence and coordinates. No settings were tuned to manufacture a successful assay claim.

## Retained evidence

Paths below are relative to the worktree's `.build/mhc-primer-validation/` directory. Generated sources and results are retained locally rather than added to the application resources.

| Evidence | Path |
| --- | --- |
| Source files, license and acquisition audit | `sources/`, `acquire.py`, `acquisition-provenance.json` |
| Actual MAFFT commands and outputs | `alignment-execution-audit.json`, `alignments/` |
| Named species/exemplar memberships | `exemplars.json` |
| Eighteen PrimalScheme analyses and exact command audit | `primalscheme3/`, `primal-execution-audit.json` |
| Final Primer3 analyses and independent verification | `primer3/mhc-all-nmask.lungfishprimeranalysis`, `primer3/macaque-failing-nmask-internal.lungfishprimeranalysis`, `primer3/nmask-audit/` |
| Annotated reference and link/hash verification | `annotated-references/`, `annotated-reference-execution-audit-2.json` |
| Installed runtime receipt and probes | `runtime/` |

The stock PrimalScheme3 runtime does not identify or expose the earlier custom terminal-gap behavior. That capability remains unavailable; none of these results claims to exercise it.

## Integrated checks

`.build/primer-design-integrated-10.log` records 173 XCTest cases with zero failures and one optional live-installer check skipped, plus 65 Swift Testing cases passing. The live installer check passed in integrated run 9; it was not repeated because the runtime implementation was unchanged. Tests include loading and rendering the actual saved MHC analyses, annotation persistence, engine adapters, managed-pack state and scientific provenance policy.

`.build/primer-debug-contract-tests-final.log` records 52 passing Python release-contract tests. Offscreen design and result images in `.build/primer-design-visual/` were inspected, including both native MHC result views. These checks do not launch the app in the user's account.

The Debug coordinator writes its local app to `build/Debug/Lungfish Debug.app`. Its final build and portability result is separate from the tests above.
