# Part II focus group synthesis

**Date:** 2026-05-09
**Method:** Four parallel focus groups, five personas each, reading the 29 Part II chapters as a unit (after reading Foundations 01-08). Raw reports in sibling files.

This synthesis converts the raw reactions into a revision plan. All twenty personas converged on a small set of cross-cutting issues, listed below in priority order with the recommended fix for each.

## High-priority fixes (every group flagged)

### 1. Reference accession inconsistency

The pilot chapter (`05-variants/01`) maps reads to MN908947.3. Several other chapters use MT192765.1 in their worked examples (`04-alignments/02`, `04-alignments/03`, `05-variants/03`, `05-variants/05`). Three of five undergraduate personas, two PhD personas, and the senior staff scientist all flagged this as the single most concrete confusion in Part II. The manual itself preaches reference discipline; the manual's own examples must be consistent.

**Fix.** Pick MN908947.3 (the GenBank accession used in the canonical fixture and the pilot chapter) and convert every chapter to use it. Audit `04-alignments/02`, `04-alignments/03`, `05-variants/03`, `05-variants/05`. Update worked-example accessions, sidebar paths, and Inspector field strings accordingly.

### 2. Vocabulary defined late or out of order

Several terms appear in chapters before they're defined:

- "Soft-clip" used in `03-reads/04` (FASTQ-level primer trim comparison) before it's defined in `04-alignments/02`
- "Supplementary alignment" used in `04-alignments/01` Inspector list, defined briefly only in `04-alignments/02`
- "Amplicon dropout" used as a noun in `04-alignments/04`, defined casually in `04-alignments/02`
- "INSDC" (`02-sequences/02`), "L-INS-i" (`02-sequences/04`), "FAST5/POD5" (`03-reads/07`), "duplex/simplex" (asymmetric definitions in `05-variants/04` and `03-reads/07`)

**Fix.** Audit Foundations + Part II for definition order. Move first-use definitions of soft-clip, supplementary alignment, MAPQ, BAQ, CIGAR, FLAG into Foundations 04 (Alignment Files). Add INSDC, FAST5/POD5, duplex/simplex to the glossary with anchor IDs. Add inline glosses where terms are used before their canonical definition.

### 3. Tool version pinning is nearly absent

Multiple personas across PhD and power-user groups independently flagged that tool versions are not pinned anywhere. iVar, LoFreq, Medaka, Kraken2, MAFFT, IQ-TREE, fastp, minimap2, BWA-MEM2, Pangolin, Nextclade — all named without version numbers in chapter prose. The reproducibility chapter (`F08`) mentions provenance pins versions, but workflow chapters do not.

**Fix.** Add a version reference table to the relevant chapters or to the Power User Notes appendix listing the canonical tool versions Lungfish ships at the current release. Cross-reference the `tool.version` field in provenance sidecars. Avoid hardcoding versions in body prose to prevent doc rot; instead reference "the version recorded in the operation's provenance sidecar" and provide a single appendix table that updates per release.

### 4. Forward references and missing chapters

Several chapters forward-reference content that does not exist or is in a different location:

- `04-alignments/01` mentions "the viral recon wizard" without context
- `02-sequences/02` references R02 as "Importing reads from SRA" but the actual file is `02-downloading-from-sra.md`
- `02-sequences/04`'s "What you will learn" mentions a "Continue to MSAs and Trees" pointer that confused readers
- `05-variants/03` references "the future cross-caller chapter" in a way that suggests it's not the current chapter

**Fix.** Audit every "see chapter X" cross-reference. Confirm the target chapter exists and the title matches. Resolve every "covered later" forward-reference: name the specific chapter or remove the forward-pointer.

### 5. Aspirational chapters are not flagged consistently

`05-variants/04` (Nanopore) labels itself "partially aspirational." `03-reads/07` (ONT runs) walks through a hypothetical run. `07-assembly/03` (Flye/Hifiasm) calls its worked example "representative rather than reproducible byte-for-byte." Power user personas flagged this as a documentation problem; bench-scientist personas did not notice.

**Fix.** Add a banner-style callout at the top of any chapter that is partially aspirational, with the form: "This chapter currently uses a hypothetical example because the matching public fixture is not yet committed. The dialog flow is current; the worked numbers are illustrative." Make the aspirational status explicit so readers can calibrate trust.

### 6. Multi-sample, multi-user, batch concerns are absent

Surveillance and core-facility personas (clinical tech, lab manager, wastewater scientist) all flagged that Part II is written for a single analyst running one sample at a time. Real workflows include 96-well plates, multi-user core facilities, and shared analysis workstations. The CLI examples show fan-out is possible but no chapter walks through it.

**Fix.** Add a new chapter or appendix on multi-sample workflows: how to run the same workflow against many samples, how to use a sample sheet, how to organize a multi-user shared project. The Workflow Builder chapter (`08-workflows/01`) should explicitly cover scatter-across-samples patterns.

### 7. Citations to upstream papers are missing

Three PhD personas and three power-user personas independently wanted DOIs or links to upstream tool papers. Wood (Kraken2), Li (minimap2/BWA), Grubaugh (iVar), Wilm (LoFreq), Bankevich (SPAdes), Nakamura (MAFFT), Minh (IQ-TREE) — none cited anywhere in Part II.

**Fix.** Add a `## Further reading` section or a `references:` frontmatter list to each chapter that names a specific tool. Alternatively, maintain a single bibliography file (`bibliography.md`) that chapters reference by anchor.

## Medium-priority fixes (multiple groups flagged)

### 8. The codon-merge case needs a diagram

Three of five undergraduate personas, multiple PhD personas, and several power users flagged the codon-merge teaching at position 28881-28882 as the single most useful concept in Part II — and also the most damaged by missing screenshots. The chapter references planned shots that have not been captured.

**Fix.** Capture the planned screenshots for `05-variants/01` step 8 and `05-variants/03` codon-merge section. Until those land, add a text-only ASCII diagram of the codon boundary so readers without screenshots can still follow the logic.

### 9. Audience tags are inconsistent

Several chapters tagged `audience: bench-scientist` (e.g., `04-alignments/04`, `04-alignments/01`) feel right at the analyst level. Several chapters tagged `analyst` (e.g., `05-variants/03`) are reachable for advanced bench-scientist readers. Persona 1 (sophomore) explicitly skipped chapters tagged analyst; some of those would have served her.

**Fix.** Audit audience tags for consistency. Establish clearer criteria: bench-scientist = no shell required, no statistics deeper than "fraction of reads"; analyst = comfortable with shell, comfortable with VCF semantics; power-user = comfortable reading source. Re-tag chapters accordingly.

### 10. Network and offline installation are missing

The clinical technologist cannot use bioconda from a firewalled subnet. The wastewater scientist runs headless on a Linux box. The academic RA shares a 256 GB SSD. The 100-200 GB classifier database figure in `06-classification/01` is honest but unactionable without an offline-install or remote-mount chapter.

**Fix.** Add a section to `F07` (Plugin Packs) on offline installation: how to mirror bioconda, how to install behind a proxy, how to share a `~/.lungfish/conda` across machines. This goes hand-in-hand with the Power User Notes appendix.

### 11. Validation language is uneven

`05-variants/01`'s "What does good look like" section is the strongest moment in Part II for the clinical, wastewater, and postdoc personas. Every other workflow chapter would benefit from the same three-bullet sanity-check pattern. The clinical technologist specifically called out the absence of any control-sample, blank, or limit-of-detection language.

**Fix.** Add a "What does good look like" subsection to every workflow chapter following the pattern from `05-variants/01`. Add explicit language about positive controls, negative controls, and reagent blanks in the chapters most likely to be used in clinical settings.

### 12. Sample-name and read-group handling is undocumented

The clinical consultant flagged that no chapter covers `@RG` (read group) configuration. Mapping CLI shows `--sample-name` once but RG fields aren't discussed. Without proper read-group setup, joint variant calling is impossible.

**Fix.** Add a section to `04-alignments/01` (Mapping Reads) explaining read-group requirements and what `--sample-name` configures. Cross-reference from Power User Notes for the full RG syntax.

## Low-priority fixes (one group or one persona)

### 13. The "So what should you do with this?" refrain is overused

Multiple personas flagged it as patronizing. Foundations focus group raised the same concern.

**Fix.** Remove or vary the literal phrase. Replace with topic sentences or with "the practical takeaway is..." constructions.

### 14. Estimated reading minutes are too low

Persona 1 (sophomore) needed 25-40 min for chapters claiming 10-12 min. Foundations focus group raised the same concern.

**Fix.** Bump `estimated_reading_min` on each chapter by 30-50%, or split longer chapters.

### 15. "Hypothetical names confuse"

Personas confused real fixtures (SRR36291587) with hypothetical examples ("ONT-SAMPLE-01", "patient-A.fastq.gz", "Madison MMSD influent"). The hypothetical names appear without being grounded.

**Fix.** Use a consistent visual convention for hypothetical names (e.g., italics or `<placeholder>` style) or label them as hypothetical in the surrounding prose.

### 16. The "Run button always says Run" callout is repeated five times

`06-classification/01`, `06-classification/02`, and others all call this out. Once is enough.

**Fix.** Remove from chapters 02-06 of Classification; keep only the first explanation.

### 17. Tool-choice arguments split along community lines

Marcus (viral surveillance) wants Freyja for wastewater. David (industry) considers EsViritu unfamiliar and wants CZ ID / Pavian. Sarah (clinical) considers GATK absence disqualifying.

**Fix.** Acknowledge the boundary explicitly. The Lungfish toolchain targets viral genomics with a specific community in mind. Add a one-paragraph "what Lungfish does not target" note to `06-classification/01` (no GATK, no Freyja for now, etc.) so power users know what they need elsewhere.

### 18. The four-classifier table is reused three times with slight variations

Appears in `06-classification/01`, `06-classification/03`, `06-classification/05`. Each version is slightly different.

**Fix.** Define the canonical table once in `06-classification/01` and reference it from the per-classifier chapters.

## Things to keep (universally praised)

The following landed well across groups and should survive any revision:

- **The "What it is / Procedure / Interpretation / Next" cadence.** Every persona named a chapter they'd lift directly into a procedure document because the structure is already that of an SOP.
- **The end-of-chapter "shell script equivalent" in `05-variants/01`.** Three of five early-career personas singled it out as the single most valuable artifact.
- **The cross-caller comparison `05-variants/03`.** Praised by all 5 PhD-student personas as the cleanest concise treatment of caller-statistics differences.
- **The codon-merge example at position 28881.** Loved across all four groups as the moment a vague concept (annotation-aware VCF representation) becomes concrete.
- **The provenance sidecar story.** Every power user praised it as best-in-class for commercial bioinformatics software, especially the explicit "what the export does not capture" paragraph in `08-workflows/02`.
- **The "phantom variants from a wrong primer scheme" paragraph in `04-alignments/03`.** The most-quoted single passage across personas: "Picking the wrong scheme is the single most common cause of phantom variants."
- **The format/preset tables** in `02-sequences/01`, `03-reads/01`, `04-alignments/01`, `06-classification/01`, `07-assembly/01`. They consistently replaced multi-paragraph explanations with one decision a reader could make in seconds.

## Action priorities

For the revision pass, prioritize in this order:

1. **Reference accession audit** (high impact, low effort)
2. **Vocabulary order fix and glossary expansion** (high impact, medium effort)
3. **Forward-reference audit** (high impact, low effort)
4. **Aspirational chapter banners** (medium impact, low effort)
5. **Citations / version references** (medium impact, medium effort)
6. **Multi-sample / batch chapter** (high impact, high effort — defer to next sprint)
7. **Validation language** (medium impact, medium effort — depends on which chapters)
8. **Audience tag audit** (medium impact, low effort)
9. **List-cap warning fixes** (low impact, low effort)
10. **Refrain pruning + reading-time bump** (low impact, low effort)
