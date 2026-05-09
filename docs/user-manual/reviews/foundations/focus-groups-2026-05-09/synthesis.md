# Foundations focus group synthesis

**Date:** 2026-05-09
**Method:** Four parallel focus groups, five personas each, reading the eight foundations chapters as a unit. Raw reports in sibling files: `01-undergraduates.md`, `02-phd-students.md`, `03-early-career.md`, `04-power-users.md`.

This synthesis converts the raw reactions into a revision plan for the foundations chapters. Reviews of all twenty personas converged on a small number of cross-cutting issues; this document lists them in priority order with the recommended fix for each.

## High-priority fixes (every group flagged)

### 1. Chapters 6, 7, 8 do not feel like foundations

Every group except the power-user group flagged this independently. Chapters 1-5 read as a tight unit teaching viral-genomics file formats and concepts. Chapters 6-8 read as a separate "Getting Started with the App" unit and break the conceptual flow.

**Fix.** Restructure the manual so chapters 6-8 move to a new Part 1.5 called "Getting Started with the App" or fold them into Part II's first workflow chapters as preflight checks. Foundations becomes purely conceptual: genome, reads, amplicon vs shotgun, alignment, variants/VCF. The Lungfish-specific scaffolding (project, plugin packs, provenance) is its own Getting Started part.

Alternative: keep them in foundations but rename the part as "Foundations and Setup" so the structural shift is signposted, and add a clear divider at the end of Chapter 5 saying "what follows is Lungfish-specific orientation."

### 2. The "1-based, inclusive" treatment is repeated too many times

Chapter 1 introduces it. Chapter 4 (POS column) repeats it. Chapter 5 (POS column again) repeats it a third time. Multiple personas were annoyed by the third occurrence.

**Fix.** Define once in Chapter 1, then in later chapters write "POS is 1-based (see Chapter 1)" rather than re-introducing the concept. Cross-link rather than repeat.

### 3. MAPQ is used in Chapter 4 before being defined

Three personas across two groups noticed.

**Fix.** Add a one-sentence definition at first use in Chapter 4 (something like "MAPQ is the mapper's confidence score for a read's placement, where 0 is no confidence and 60 is high"), and add an entry to the glossary.

### 4. Vocabulary mismatch with stated audience

Foundation chapters declare `audience: bench-scientist`, but Chapter 1 uses codon, amino acid, spike protein, leucine, arginine without definitions; Chapter 3 uses Ct without defining it; Chapter 5 introduces diploid/haploid in an order that confuses programmer-background readers; Chapter 4 dumps a SAM flag value with a parenthetical decoding but no explanation that flags are bitwise.

**Fix.** Audit each chapter against the declared audience and add inline glosses or footnotes. Specific corrections needed:
- Chapter 1: gloss "codon", "amino acid", "spike protein" at first use, or move the L452R example to a later sub-section after biology vocabulary has been introduced
- Chapter 3: define Ct (cycle threshold) at first use
- Chapter 5: introduce haploid before diploid in the GT explanation, since readers who know diploid are exactly the ones who don't need the section
- Chapter 4: explain that SAM flags are bitwise integers and that `99 = 1+2+32+64` is the decoded sum

### 5. The CIGAR example in Chapter 4 has a factual error

Power-user group flagged this most precisely. The example uses `5S140M5S` with `NNNNNACGTGTCTCTGCCG ... NNNNN` as the read sequence. Soft-clipped bases retain their original base calls; they are not replaced with N. This is a real factual error a clinical consultant or tool developer would notice immediately.

**Fix.** Replace the N-padded example with a real example showing soft-clipped bases retaining their original sequence. Add a note explaining what soft-clipping actually does (marks bases as non-analyzable, keeps them in the file).

### 6. iVar QUAL/FILTER attribution is wrong

Chapter 5 says "A QUAL of `.` means the caller did not score the row, which is common for iVar (iVar reports filters explicitly and leaves QUAL empty)." Two power-user reviewers (a consultant and a tool developer) pointed out that iVar emits a TSV with no QUAL column at all; whatever Lungfish writes in the QUAL slot is Lungfish's converter choice, not iVar's.

**Fix.** Reword to: "When Lungfish converts iVar's TSV to VCF, it leaves QUAL empty because iVar does not compute a Phred-scaled probability. Other Lungfish callers (LoFreq, Medaka) populate QUAL." Same correction for the FILTER vocabulary section: name it as Lungfish-conventional cross-caller normalization, not as native iVar/LoFreq filter names.

## Medium-priority fixes (multiple groups flagged)

### 7. Wastewater is repeatedly punted with no forward link

Chapter 5 explicitly defers wastewater "to a later chapter." Multiple early-career and PhD personas, several of whom do wastewater for a living, found this frustrating. The forward reference is to a chapter that does not yet have a name.

**Fix.** Either name the specific chapter the forward reference points at (probably the future intra-host minor variants chapter, which doesn't exist yet, or the existing classification chapters), or add a paragraph in Chapter 5 with the actual wastewater-relevant content: that for mixed populations the AF distribution becomes informative as a frequency spectrum rather than a per-position binary classification.

### 8. Citations and version pinning are absent

Three personas across PhD and power-user groups independently wanted DOIs or version numbers for minimap2, iVar, LoFreq, the ARTIC scheme, and the canonical academic papers (Quick 2017 ARTIC, Grubaugh 2019 iVar, Wilm 2012 LoFreq, Li 2018 minimap2, Ewing & Green 1998 Phred, hts-specs VCF/SAM specs).

**Fix.** Add a `## Further reading` section to each foundations chapter with relevant DOIs and links. Or maintain a single bibliography file (`bibliography.md`) that chapters reference by anchor.

### 9. Adjacent-tool integration is unstated

Pangolin, Nextclade, viralrecon, GATK, GISAID — these are tools the reader will integrate with. Foundations reads as if Lungfish is the entire pipeline. Several PhD and surveillance personas wanted explicit statements: "Lungfish does not assign Pango lineages; export the consensus FASTA to Pangolin" and "Lungfish does not run nf-core; the Snakemake export is the equivalent."

**Fix.** Add a "What Lungfish does not do" subsection in Chapter 6 or as part of Chapter 8's reproducibility chapter, naming the major adjacent tools and how to hand off to them.

### 10. The reproducibility chapter overpromises on environment pinning

Power-user group: clinical-validation consultants and CI/CD engineers both flagged that "plugin pack version" is not equivalent to a full conda lockfile. Without a lock, transitive dependency drift can cause non-bit-identical outputs between machines.

**Fix.** Chapter 8 already has a limitations section. Strengthen it: explicitly say "the plugin pack version pins our recipe but not the resolved environment; for clinical validation you need the OCI image digest or a generated conda lock file." Add a forward reference to where containerization is documented, or admit that it isn't yet and put it on the planning roadmap.

### 11. Multi-sample and batch processing are absent

Surveillance and core-facility personas (Daniel, Chris, Priya from early-career) all flagged that the project model is single-sample. A 96-sample batch from a public health lab, a 10-sample wastewater run, or a multi-investigator core facility all need a story.

**Fix.** Add a paragraph or short subsection to Chapter 6 on multi-sample projects: when to use one project per sample vs one project per batch, and forward-reference the batch import chapter (R01) for the mechanics.

### 12. Methods Section export needs a "review before submitting" warning

Two power-user personas (PI, consultant) independently flagged that the Methods Section export will get pasted verbatim into papers and validation packets. Without a banner warning that this is a draft, mistakes will propagate.

**Fix.** Chapter 8: add a "this is a draft, read it before submitting" callout in the Methods Section export discussion. Recommend a human review pass.

## Low-priority fixes (one group or one persona)

### 13. Scope statement missing or buried

PhD persona Maya (microbiology, bacterial pathogenesis) read three chapters before learning bacteria are out of scope. The opening paragraph of Chapter 1 should state the scope upfront.

**Fix.** Add one sentence to the very first paragraph of Chapter 1: "This manual is for viral genomics. Bacterial WGS, eukaryotic genomics, and human disease variants are adjacent fields where the file formats are similar but the workflows differ; this manual focuses on viral applications."

### 14. The "So what should you do with this?" refrain divides reviewers

Three of five early-career personas, two of five undergrads, and one PhD persona found the closing-sentence pattern annoying or patronizing. Two found it appropriate.

**Fix.** Keep the pattern but vary the wording. Don't use the literal phrase "so what should you do with this?" in every chapter. Sometimes "the practical takeaway is..." or "in practice..." or just a clean topic sentence.

### 15. Estimated reading minutes are too low

All five early-career personas took longer than the front-matter `estimated_reading_min` suggested, especially Chapter 5 (10 min stated, 25-40 min actual for the more concept-heavy readers).

**Fix.** Bump `estimated_reading_min` on each chapter by 30-50%, or split the longer chapters (Chapter 5) into two pages.

### 16. Chapter 7's "you will not need to type a single conda command" is muddled

Power-user persona Robin and undergrad persona Sam both flagged that the chapter says you don't need conda commands and then shows several `lungfish conda install` commands. The relationship between `lungfish conda` and actual `conda` is not crisp.

**Fix.** Reword Chapter 7's intro to say "you will not need to learn conda's full command surface; `lungfish conda install --pack <name>` wraps it." Then make the wrapper relationship explicit.

### 17. R203K/G204R lineage attribution is loose

Power-user PhD persona Tomás (epidemiology, lineage assignment) flagged in the pilot focus groups that R203K/G204R is a B.1.1 signature inherited by Omicron, not "Omicron's signature." This survives in a couple of foundations passes.

**Fix.** Tighten any reference to be precise: "first seen in B.1.1 (Alpha-precursor), inherited by most Omicron sublineages including this isolate."

### 18. Platform comparison table is dated

Power-user persona Marcus flagged that "Oxford Nanopore Q10-Q25 raw" is dated; modern R10.4.1 simplex is Q20+ and duplex Q30+.

**Fix.** Update Chapter 2's platform table to reflect 2025-2026 chemistry.

### 19. Inconsistency on imported-vs-downloaded provenance

Undergraduate persona Aaliyah caught that Chapter 1 implies all references in a project carry full provenance, while Chapter 6 distinguishes Imports/ from Downloads/ and clarifies imports have provenance only as far back as the local copy.

**Fix.** Reword Chapter 1's provenance line to "every downloaded reference carries provenance metadata" or "every reference carries some provenance, but downloads carry network provenance and imports carry filesystem provenance." Cross-link to Chapter 6.

### 20. Influenza/segmented genomes underdeveloped

PhD persona Daniel (influenza virologist) flagged that Chapter 1 mentions segmented genomes briefly and never returns. The running example never expands beyond SARS-CoV-2.

**Fix.** This is a structural choice. The pilot manual is SARS-CoV-2-focused on purpose. But add a one-sentence acknowledgement in Chapter 1 that the multi-segment case has a separate workflow not covered here, and forward-reference where it would land if/when it ships.

## Things to keep (universally praised)

The following landed well and should survive any revision:

- Chapter 5's haploid AF section is the strongest piece of writing in the foundations. All twenty personas praised it.
- Chapter 5's two-row PASS/ft contrast worked as a competence builder. Four of five undergrad personas felt confident reading a VCF afterward.
- Chapter 3's "phantom variants from a wrong primer scheme" landed for clinical, surveillance, and research readers. The most-quoted line: "Picking the wrong scheme is the single most common cause of phantom variants."
- The variant-notation breakdown in Chapter 1 (`MN908947.3:21618 C>T`) is praised as a competence checkpoint.
- The provenance sidecar in Chapter 8 is the standout reason senior readers would adopt the tool.
- Chapter 7's "why conda not pip" rationale is the only place CS-background readers had seen the explanation given respectfully.
- The fixture-tied numbers (86,281 read pairs, 30 KB reference, etc.) ground every chapter in something real.

## What this means for the rest of the manual

The foundations focus groups establish the editorial rules that should also govern Part II. Two patterns we want to enforce going forward:

1. **Scope statement at the top of every chapter.** "This chapter covers X; for adjacent topic Y see chapter Z." Some chapters in Part II already do this; we should standardize.
2. **No vocabulary load-bearing without inline gloss.** Every term that the audience tier might not know gets a one-sentence definition at first use. The glossary is the long form; inline is the short form.
3. **Citation surface.** Each chapter that names a tool should link to the tool's paper or docs. We do not have this yet anywhere in Part II.
4. **Forward references must resolve.** "Covered later" is acceptable only if the chapter being pointed at exists or is committed to the TOC.
