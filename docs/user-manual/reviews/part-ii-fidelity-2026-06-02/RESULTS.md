# Part II+ documentation fidelity pass: results

**Date:** 2026-06-02
**Scope:** Every chapter of the LGE user manual *except* Foundations (which had
already been carefully reviewed). That is sections 02-sequences, 03-reads,
04-alignments, 05-variants, 06-classification, 06-human-germline-variants,
07-assembly, 08-workflows, and the appendices: 50 existing chapters plus 1 new
chapter.
**Method:** Ground-truth extraction from the app, then three iterative rounds of
simulated-reader review and expert-editor revision, then a final brand and
verification pass. Run autonomously with the project's established documentation
review process and style guide.

## What you need to do when you are back

Two spec files are waiting for you. Both are followable top to bottom.

1. **[SCREENSHOT-SPEC.md](SCREENSHOT-SPEC.md)** lists every screenshot the
   revised chapters need: 89 shot entries, about 60 of them new captures, 7
   flagged Priority 1 (the new and most-rewritten chapters), and about 20 that
   probably already exist in `shots/captured/2026-05-09/` and only need
   verifying against the corrected text. It gives the exact menu path, fixture,
   and app state for each, and it flags two practical constraints: the shot
   runner has no click action, so dialogs and wizards must be hand-driven to the
   target state, and the worked-example FASTQ is not committed, so you must run
   `fixtures/sarscov2-srr36291587/regenerate.sh` before the mapped/trimmed/called
   bundles exist. The single highest-value capture is `nvd-result-viewport` (the
   brand-new Novel Virus Diagnostics viewport).

2. **[ILLUSTRATIONS-SPEC.md](ILLUSTRATIONS-SPEC.md)** proposes 6 new conceptual
   cartoons (cross-caller agreement, consensus calling, the NVD discovery
   concept, the classifier-strategy contrast, joint-genotyping at the 50-sample
   boundary, and the Workflow Builder typed-port chain), each written as a
   ready-to-paste `illustrations.yaml` entry with a palette-correct, fact-checked
   brief. The highest-value one is `cross-caller-agreement`.

Nothing else requires you. The chapters are corrected, lint-clean, and
internally consistent now.

## The headline finding

Your hypothesis was correct and the drift was larger than a spot check would
suggest. The drafted chapters described many features that do not exist, used
many wrong menu paths and tool names, and omitted whole shipped features. The
review process below caught and corrected them against the actual Swift source
and the live `lungfish-cli` v0.5.0-alpha11 binary, which served as the arbiter
of truth throughout.

The most consequential corrections:

- **Two chapters described features that do not exist and were rewritten around
  the real workflow.** Cross-caller comparison (05-variants/03) had no comparison
  view, no intersection or union export, and an invented LoFreq options dialog;
  it now teaches reading two callers in one auto-aggregated table by the `Source`
  column, with `bcftools isec` for programmatic set operations. Consensus and
  lineage (05-variants/05) described a consensus FASTA output that the variant
  caller never writes; it now points at the three real consensus paths (the Viral
  Recon wizard, `lungfish msa consensus`, and the Inspector preview) and keeps the
  accurate hand-off to Pangolin and Nextclade.
- **Two classification chapters were rewritten.** NAO-MGS (06-classification/05)
  described a run path and a longitudinal time-series viewport that do not ship;
  it is import-only and now says so, crediting SecureBio's pipeline. BLAST
  verification (06-classification/06) described a BLAST tab, a representative-read
  picker, and a local-database selector that do not exist; the real feature is a
  BLAST Verify button that submits an auto-selected read sample to NCBI.
- **A whole shipped feature had zero coverage.** Novel Virus Diagnostics (NVD) has
  a CLI, an Import Center card, and its own contig-keyed BLAST viewport, and was
  entirely undocumented. A new chapter (06-classification/08) now covers it.
- **The Workflow Builder chapter was substantially rewritten.** Its palette
  category names were all invented, several node types did not exist, and its
  flagship reads-to-variants worked example was not buildable today (the node
  types do not exist, the native runner supports only the five FASTQ-preprocessing
  ops, and the example's graph shape violates the linear-chain constraint). The
  chapter now uses the real seven palette categories and the runnable VSP2 FASTQ
  chain as its worked example, and is honest that the Builder is currently scoped
  to FASTQ preprocessing.
- **The GATK germline section was de-staled.** All four chapters claimed the
  feature was dry-run-only and "coming soon"; in fact every `lungfish gatk`
  subcommand runs GATK4 for real under an `--execute` flag, with preview as the
  default. The chapters now document the real preview-versus-execute model and the
  omitted GUI HaplotypeCaller path.
- **The CLI reference was the worst-drifted chapter and was rebuilt.** Eight
  commands were renamed or removed (for example `classify` is really `conda
  classify`, `extract-contigs` is really `extract contigs`), eight flag
  signatures were corrected (for example `markdup` marks in place and takes a
  positional path, not `--in`/`--out`), and fourteen entirely-absent top-level
  commands were added, with a 43-row alphabetical command index that is now
  set-equal to the binary. Several of these were verified by running the binary.
- **A systematic menu-path error ran through every operation chapter.** The real
  pattern is `Tools > FASTQ/FASTA Operations > <Category>...` then pick the
  operation from a list inside the dialog, not a four-level per-operation submenu.
  There is no "Workflows" menu, no "Reads" menu, no per-tool Classification
  submenu, and no `Tools > Infer Tree`. Every wrong path was corrected.
- **Wrong tools and defaults were corrected throughout.** Decontamination uses
  Deacon and bbduk (not the documented RiboDetector and fastp); the viral caller
  roster is five callers defaulting to LoFreq (not three); SPAdes has no `--viral`
  mode; the Kraken2 confidence default is 0.2; the QIAseq scheme is 223 amplicons
  and 563 primers; and more.

A per-section, code-cited inventory of every gap is in
[ground-truth/](ground-truth/) (9 maps, the arbiter the reviewers and editors
worked against).

## How the work was structured

1. **Ground truth (Phase 0).** Nine `code-cartographer` agents read the Swift
   source and the live CLI binary and produced a reality map per section: what
   each chapter claims versus what the code does, features described but
   nonexistent, and app features missing from the docs. See
   [ground-truth/](ground-truth/).
2. **Round 1.** Nine simulated-reader focus groups (biologist personas from
   novice to power-user) read each section against its ground-truth map and
   produced a prioritized synthesis ([round-1/](round-1/)). Nine
   `bioinformatics-educator` editors then applied the fixes, including the four
   rewrites and the new NVD chapter ([round-1/](round-1/) drove the chapter
   edits).
3. **Round 2.** Readers re-read the revised chapters, verified each Round 1 fix
   actually landed (the CLI reviewer ran the binary), and caught residual issues;
   editors applied the corrections ([round-2/](round-2/)).
4. **Round 3.** A cross-chapter consistency audit, an adversarial fidelity
   skeptic re-checking the rewrites against the binary, and a final reader
   accessibility panel ([round-3/](round-3/)); editors applied the cross-chapter
   fixes and a voice/consistency polish; a `brand-copy-editor` pass closed it out.

This mirrors the process the Foundations chapters went through, extended across
the rest of the manual.

## What changed, by the numbers

- 51 chapter files modified, 1 new chapter created (Novel Virus Diagnostics),
  plus the glossary and the mkdocs nav. About 3,200 insertions and 2,200
  deletions across the chapters.
- The GLOSSARY gained or corrected entries (ORF, Ct, Freyja, NVD, BQSR, GVCF,
  GenomicsDB, Joint genotyping; corrected variant-caller and NAO-MGS).
- The new chapter is wired into the nav (`build/mkdocs.yml`).
- About 11,700 lines of review artifacts were produced (ground-truth maps, three
  rounds of reviews, and the two specs), preserved under this directory for
  audit.

## Verification (all green)

- **Lint:** every touched chapter passes the house linter (em-dash, bullet-cap,
  voice, palette, typography, written-identity, frontmatter,
  primer-before-procedure). Exit 0, zero warnings.
- **Links:** zero broken internal cross-references across the whole manual. A
  pre-existing dangling link in Foundations (08-provenance, which pointed a
  "coming later" placeholder at the repo README) was repaired to the now-existing
  workflows export chapter.
- **Shot markers:** every active `<!-- SHOT: id -->` marker has a matching
  `shots[]` frontmatter entry.
- **Frontmatter:** all chapters keep `lead_approved: false` and `brand_reviewed:
  false`. The lead (you) and the brand pass approve later; nothing here
  self-approved.

## Residual known gaps (intentionally left)

- **Screenshots and illustrations are specs, not captures.** They require the
  running app and your hand. That is the two action items above.
- **A few runtime-only details are marked needs-human-check** in the ground-truth
  maps (exact on-screen labels that can only be confirmed against a running
  build, a couple of fixture-dependent numbers like a specific coverage figure).
  These are noted in the relevant review files and do not affect any procedure.
- **`features.yaml` is still incomplete.** It has no classification entries yet,
  which is why the consensus chapter's `features_refs` is empty rather than
  pointing at a consensus feature id. That is a Code Cartographer follow-up, noted
  inline in 05-variants/05.
- **`brand_reviewed` stays false everywhere.** The Round 3 brand pass polished the
  rewritten and new chapters for voice, but the formal brand gate is yours to set.

## Where everything lives

```
docs/user-manual/reviews/part-ii-fidelity-2026-06-02/
  RESULTS.md            <- this file
  SCREENSHOT-SPEC.md    <- action item 1
  ILLUSTRATIONS-SPEC.md <- action item 2
  ground-truth/         <- 9 per-section reality maps (the arbiter)
  round-1/  round-2/  round-3/   <- the iterative review record
```
