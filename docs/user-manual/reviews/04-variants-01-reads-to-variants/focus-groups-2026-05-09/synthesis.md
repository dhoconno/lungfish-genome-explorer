# Focus group synthesis: 04-variants/01-reads-to-variants

**Date:** 2026-05-09
**Method:** Four parallel focus groups, five personas each, reading the chapter cold and reporting raw reactions. Raw reports in sibling files: `01-undergraduates.md`, `02-phd-students.md`, `03-early-career.md`, `04-power-users.md`.

This synthesis converts those raw reactions into a revision plan for the pilot chapter and a planning surface for the rest of the manual.

## What every group converged on

These issues showed up in every group:

1. **The "chapter zero" reference is broken.** The chapter assumes a foundations primer introducing VCF columns (CHROM, POS, REF, ALT, FILTER, INFO, FORMAT) that does not exist. Every group flagged it. Two solutions: write the foundations primer first, or fold the column primer into this chapter's preamble. Recommendation: do both. Write a short Foundations chapter on file formats AND give this chapter enough self-contained orientation that it survives without the prerequisite.

2. **"Amplicon" is unglossed and load-bearing.** Undergrads, early-career bench scientists, and even a year-2 microbiology PhD all stalled on "amplicon" appearing without definition. The chapter's "Why this matters" section depends on the reader already understanding the concept. Fix: define amplicon at first use. Consider a short illustrated primer earlier in the manual.

3. **Other unglossed jargon recurs.** soft-clip, pileup, Phred score, strand bias, multiple-testing correction, dynamic threshold, minority-haplotype evidence, allele frequency (in the haploid-viral sense), depth, BAM, FASTQ, primer scheme, paired-end, "preset sr", reference bundle, GFF. Fix: glossary callouts at first use, or a sidebar early in the chapter that defines the working vocabulary.

4. **Screenshots are referenced but absent.** The chapter has eight `<!-- SHOT: id -->` placeholders and frontmatter `shots[]` entries, but the rendered chapter shows no images. Lab manager and clinical tech personas are blocked without the Inspector and Operations Panel screenshots. Fix: capture the planned shots before the chapter ships. Lab manager wants the Operations Panel image specifically.

5. **The "two callers, read the disagreement" framing is wrong for this chapter.** Clinical tech needs a recommendation, not a calibration exercise. Lab manager would not adopt without a default. The user has now asked us to do iVar only in this chapter and defer cross-caller comparison to a later chapter. This aligns with the focus-group signal: a beginner chapter should commit to one caller and explain why, with a small comparison table for "when you'd reach for a different one."

6. **The chapter takes a philosophical voice in the opening that doesn't earn the casual tone.** "A variant call set is the short answer to a long question" gets eye-rolls from power users and confusion from beginners. The framing-paragraph approach is delaying the "what we are about to do" message. Fix: rewrite the opening to lead with what the reader will produce and why a SARS-CoV-2 example is the right teaching vehicle, then go to mechanism.

7. **No QC step.** Bench scientists and core-facility staff both said they would not run this on real data without read-quality, coverage, and contamination checks. Fix: add a "before you trust the result" subsection that names the QC the chapter is currently skipping and points at where it will be covered (a future alignments chapter).

8. **The "bring your own primer scheme" question is real.** Three of five early-career personas use ARTIC, custom wastewater schemes, or non-QIAseq protocols. The chapter mentions the QIASeq scheme is bundled but never says how the reader inspects what's bundled or adds their own. Fix: a short "how to see what schemes ship and add a new one" subsection or a clear pointer to a future chapter, with at minimum a CLI hint.

9. **The GFF reference is hypothetical.** Codon merging is taught as something that "would" happen "if" a real GFF were attached. The user has now agreed we should ship the real `MN908947.3.gff3`, attach it to the fixture, and run the procedure with the merge happening live. Fix: regenerate the fixture with a GFF and rewrite the codon paragraph to describe what actually happened, not a hypothetical.

10. **CLI parity is undermined by ellipses.** Power users want every flag visible. Bench scientists want a single shell block they could pipeline. Fix: append a "everything you just clicked, as a shell script" section after the procedure, with the full CLI for every step.

## Where groups disagreed and how to resolve

- **How much statistics to expose.** Power users want mpileup flags, indelqual, conda env hashes; bench scientists want fewer numbers and clearer "what does this mean for my sample." Resolve: write the body for bench scientists and add a "Power user notes" appendix at the bottom with the deeper machinery. The appendix is opt-in.

- **Whether to recommend a default caller or stay neutral.** Clinical and surveillance readers want a recommendation; researchers want the cross-caller framing. Resolve: in this chapter, recommend iVar with a clear rationale (amplicon protocol = primer-trim-aware caller). Defer the cross-caller chapter. Add a one-paragraph "when iVar isn't the right choice" with explicit pointers to LoFreq and Medaka for their respective regimes.

- **CLI block at end vs per-step CLI.** Resolve: keep per-step CLI footnotes (concrete, locally useful) AND add the full shell block at the bottom (reproducibility, copy-paste). They serve different readers.

## Specific factual corrections that need to land

These came up from the more expert personas and need to be treated as bugs, not editorial preferences:

- **iVar is not a "tuned" caller.** It's a thresholding pipeline on top of `samtools mpileup`. Don't put iVar and LoFreq on equal statistical footing. Describe iVar as "an allele-frequency and quality threshold caller designed for primer-trimmed amplicon data" and LoFreq as "a per-base error model with multiple-testing correction across the genome."

- **LoFreq's "permissive defaults" claim is wrong.** LoFreq is conservative on per-site evidence but permissive on minimum AF (it has no AF threshold by default; it filters on Bonferroni-corrected p-value). Don't conflate AF threshold with overall permissiveness.

- **The codon merge is a Lungfish-converter behavior, not an iVar behavior.** iVar's TSV gets per-position rows; the Lungfish converter does the codon collapse when given a GFF. Attribute correctly so a reader doesn't go file a bug against the wrong project.

- **The R203K/G204R "B.1.1 / Omicron" attribution is loose.** R203K/G204R is a B.1.1 (Alpha-precursor) signature inherited by most Omicron lineages. Either say "first seen in B.1.1, present in most Omicron lineages including this isolate's BA.X assignment" or just say "a substitution at amino acid 203 of the nucleocapsid that is present in this sample."

- **"Lungfish drives every step from the Operations Panel" is wrong.** The Operations Panel monitors progress and history; tools launch from menus and Inspector buttons. Reword to "Lungfish runs every step in the background and shows progress in the Operations Panel."

- **"Variant calling is deterministic on the same inputs with the same caller" needs a hedge.** Multi-threaded callers and unfixed mpileup chunking can produce non-bit-identical output. Soften to "given the same inputs, the same caller version, and the same parameters, you get the same calls."

- **The Inspector section was wrong in the prior draft.** Already fixed: it's now `Analysis > Variant Calling`.

- **`File > Download from NCBI/SRA` was wrong.** Already fixed: it's now `Tools > Search Online Databases > Search NCBI/SRA…`.

## Things the chapter does well, per focus groups

So we don't lose them in the rewrite:

- The disk/time budget paragraph (lifted into multiple personas' SOPs)
- The ENA-first / SRA-Toolkit fallback paragraph (concrete and useful)
- The provenance sidecar mention and the auto-checked primer-trim acknowledgement
- The codon teaching moment at 28881 (loved by mid-tier and senior personas)
- The CLI equivalents under each step (loved by the CS persona, the consultant, the wastewater scientist)
- The honest framing about caller choice mattering (loved by mid-tier and senior personas)

Keep all of these.

## Recommended structure for the rewrite

1. **Opening: what you will build.** One paragraph naming the deliverable (a Lungfish project with a reference, a primer-trimmed alignment, an annotated VCF, opened in the variant browser) and naming the example (SARS-CoV-2 amplicon Illumina reads from a real public sample). No philosophy.

2. **Why a variant call matters here.** One paragraph framing why someone would do this for SARS-CoV-2 specifically: lineage assignment, mutation surveillance, drug-resistance detection, evolutionary tracking. This is the biological motivation the user asked for.

3. **The vocabulary you will need.** A short, friendly definition list (4-6 terms) of: reference genome, sequencing reads (FASTQ), alignment (BAM), variant (VCF), amplicon, primer scheme. Two sentences each, not a glossary entry.

4. **Choosing iVar.** A short subsection: this is amplicon Illumina data, so we use iVar because it expects primer-trimmed input and is designed for amplicon AF thresholds. Then a small comparison table:

   | If your data is | Use | Why |
   |---|---|---|
   | Illumina amplicon (this chapter) | iVar | Primer-trim-aware, AF-threshold caller |
   | Illumina shotgun viral | LoFreq | Per-base error model, no primer assumption |
   | Oxford Nanopore | Medaka | Long-read aware, Nanopore error profile |

5. **Before you start.** Plugin packs, disk/time budget, what you need installed, what hardware. Plain language.

6. **Procedure.** Numbered consistently 1-7 (no restart at 5 → 1). Each step says what you click, what happens, what you see, and what command ran behind it. Screenshots in line.

7. **Quality check.** A short subsection on what to verify before trusting the call set (coverage, primer-trim provenance check, expected read count). What good looks like.

8. **Reading the variants.** The codon-merging story now lands as a real demonstration with the bundled GFF. Position 28881 collapses to one row in the actual fixture VCF.

9. **What this chapter didn't cover.** Honest pointers to: the cross-caller comparison chapter (future), the consensus-FASTA chapter (future), the lineage-assignment chapter (future), the bring-your-own-scheme chapter (future), the QC chapter (future).

10. **The whole thing as a shell script.** Optional appendix for CLI users.

11. **Power user notes.** Optional appendix for the LoFreq-statistician persona: exact mpileup flags, indelqual notes, conda env pinning, provenance sidecar schema.

## What this means for the rest of the manual

The focus groups exposed a broader problem: this chapter cannot stand alone, and the manual has no foundations. We need to plan and stub the full TOC before continuing chapter writing. The next deliverable is a proposed TOC with prereq dependencies and a one-paragraph "what this chapter teaches" summary for each entry, so any future chapter knows what its readers already know. That goes in `docs/user-manual/ARCHITECTURE.md`.

A draft TOC informed by the focus groups:

**Part I: Foundations** (formats and concepts)
- 01-foundations/01-what-is-a-genome — biological setup; reference genomes; coordinates
- 01-foundations/02-sequencing-reads — FASTQ; paired-end; phred quality; what reads look like
- 01-foundations/03-amplicon-vs-shotgun — primers, primer schemes, why amplicons need trimming
- 01-foundations/04-alignment-files — BAM/BAI; what mapping does; soft-clipping
- 01-foundations/05-variants-and-vcf — VCF columns; AF/DP/FILTER/INFO/FORMAT; haploid viral semantics
- 01-foundations/06-the-lungfish-project — projects, bundles, plugin packs, the Operations Panel

**Part II: Working with the app**
- 02-sequences/* — viewing references, GenBank import, FASTA bundles
- 03-alignments/* — mapping reads, QC, primer-trim, alignment review
- 04-variants/* — the pilot chapter (this one), cross-caller comparison, consensus
- 05-classification/* — Kraken2, EsViritu, TaxTriage, NAO-MGS
- 06-assembly/* — SPAdes, MEGAHIT, contig review

**Part III: Reference**
- appendices/keyboard-shortcuts
- appendices/cli-reference
- appendices/troubleshooting
- glossary

The pilot chapter needs Foundations 02-05 to land before it can be read cold. Foundations 03 (amplicon) and 05 (VCF) are the most load-bearing.
