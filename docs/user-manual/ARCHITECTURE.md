# ARCHITECTURE, Lungfish User Manual

**Ownership:** Documentation Lead only.

This file holds the final TOC, audience mapping, prerequisite graph, and the
rationale behind every chapter placement.

## Status (2026-05-09)

Sub-project 1 delivered one pilot chapter (`04-variants/01-reads-to-variants`).
The 2026-05-09 focus-group review (`reviews/04-variants-01-reads-to-variants/focus-groups-2026-05-09/`)
established that the pilot cannot stand alone. Every audience tier needs
foundations material before the variants chapter is readable cold. This
revision of `ARCHITECTURE.md` plans the full manual, names every chapter we
intend to ship, and records the prerequisite graph so chapter authors know
what readers already know when they arrive.

## Audience tiers

Three tiers are declared per chapter:

- **bench-scientist** — the default. A scientist with biology training who
  may have done little or no computational analysis. Assumes lab vocabulary,
  not bioinformatics vocabulary.
- **analyst** — a scientist who has run pipelines other people built or
  who has done comparable work in another tool (Geneious, CLC, IGV, or an
  in-house pipeline). Comfortable with file formats, comfortable with the
  shell.
- **power-user** — a developer or computational biologist building or
  validating their own pipelines. Will read source, will check flags, will
  benchmark.

Most chapters target bench-scientist; some are flagged analyst (deeper-dive
chapters) or power-user (CLI reference, reproducibility appendices).

## Editorial rules from the focus groups

These constraints apply to every chapter from this revision forward:

1. **Define a term at first use, every chapter.** No assumed vocabulary.
   Twelve to fifteen common terms (amplicon, BAM, FASTQ, VCF, primer scheme,
   pileup, soft-clip, Phred score, allele frequency, depth, strand bias,
   reference bundle, plugin pack, GFF) must each be glossed inline the first
   time they appear in any chapter. The Glossary holds the full definition;
   the inline gloss is one short sentence.
2. **Promise only what exists.** No chapter promises a future feature or a
   future chapter as the answer to a real question. If a feature is missing,
   say so plainly.
3. **Tool comparison tables for every operation with tool choice.** Variant
   calling, mapping, classification, assembly each have multiple tools.
   Whenever a chapter picks one, a small table names the alternatives and the
   regimes where each is preferred.
4. **Real ancillary files, not hypotheticals.** If the chapter mentions a
   GFF, a primer scheme, a metadata sheet, the fixture ships it and the
   procedure uses it. No "if you had a GFF" prose.
5. **Screenshots required at gate 2.** A chapter without its declared shots
   does not pass review.
6. **CLI parity once at the end.** Every chapter that walks a GUI procedure
   ends with a single shell-block appendix that reproduces the whole
   procedure on the CLI. Per-step CLI footnotes stay; the appendix is added.
7. **WHY before HOW.** Every procedure is preceded by a one- or two-paragraph
   biological motivation tied to the example in the chapter.
8. **Quality check before "done".** Every workflow chapter ends with a short
   "what does good look like" subsection naming the checks the reader should
   apply before trusting the output.

## Retrieval surface (in-app documentation rules)

The manual is also the knowledge base for the in-app AI assistant and for
contextual help. A user asking a question inside Lungfish ("what is this
dialog?", "what's a primer scheme?") expects an answer grounded in the
manual without leaving the app. These rules ensure chapters retrieve well:

1. **Sections must be self-describing.** Every H2 and H3 should make sense
   when surfaced alone by a search. Restate enough context (which tool,
   which file, which step) that the section reads correctly out of order.
   Avoid pronouns whose referents are in the previous paragraph: write
   "the Variant Calling dialog", not "this dialog"; "step 4", not "that
   step".
2. **Frontmatter carries structured metadata for retrieval.** Every
   chapter declares:
   - `tags` — controlled vocabulary (`amplicon`, `variant-calling`, `iVar`,
     `sars-cov-2`, etc.)
   - `tools` — every tool named in the chapter (`ivar`, `minimap2`,
     `samtools`, `lofreq`, `medaka`)
   - `entry_points` — the menu paths and CLI commands the chapter teaches
     (mirroring `features.yaml`)
   - `task` — a one-sentence imperative summary ("Call variants from
     amplicon Illumina reads of a viral genome.")
   in addition to the existing `chapter_id`, `audience`, `prereqs`,
   `glossary_refs`, `features_refs`, `fixtures_refs`, `shots`,
   `estimated_reading_min`, `brand_reviewed`, `lead_approved`.
3. **Glossary entries carry stable anchor IDs.** Each term in
   `GLOSSARY.md` declares an explicit `{#anchor}` ID matching its
   `glossary_refs` slug. Chapters cross-link via
   `[amplicon](../GLOSSARY.md#amplicon)`. The app deep-links to the same
   anchor when the user asks "what's this term?"
4. **Code blocks declare a language.** `bash` for shell, `text` only for
   actual sample output, plus content tags where useful (`vcf`, `fastq`,
   `gff`, `json`). The retrieval layer extracts command examples by
   language tag.
5. **`help-ids.yaml` maps app surfaces to documentation anchors.**
   Every dialog, viewport, and major Inspector section declares a
   `help_id`. The build adds `docs/user-manual/help-ids.yaml`, owned by
   the Code Cartographer, that resolves each `help_id` to a chapter
   anchor (e.g. `BAMVariantCallingDialog → 05-variants/01#calling-with-ivar`).
   The app reads this to drive a "Help on this" affordance.
6. **Author for retrieval.** Avoid backreference chains ("as we saw
   earlier", "this is the same as before"). Each section should lead
   with a noun phrase that names what it is about so chunked indexing
   surfaces it correctly. Example: "Calling variants with iVar against
   a primer-trimmed BAM" beats "Now we run the caller".
7. **Inline definitions echo glossary entries.** When a term gets its
   inline gloss at first use in a chapter, the wording mirrors the
   `GLOSSARY.md` entry. The retrieval layer does not have to disambiguate
   which definition is canonical because they agree by design.

## Table of contents

The TOC has three parts. Part I (Foundations) must land before any Part II
chapter is readable cold. Within Part II, chapters declare prereqs in their
frontmatter; the dependency graph below makes the chains explicit.

### Part I: Foundations

The foundations part is the prerequisite surface for every Part II chapter.
Each foundations chapter is short (5-10 minutes reading), bench-scientist
audience, and ends with "you now know enough to start chapter X."

- **01-foundations/01-what-is-a-genome** — biological setup; what a reference
  genome is; coordinates; chromosomes and contigs; introduces SARS-CoV-2 as
  the running example.
  Prereqs: none. Audience: bench-scientist.
  Teaches: reference genome, coordinate, contig, chromosome.

- **01-foundations/02-sequencing-reads** — what FASTQ files are; what a read
  is; paired-end vs single-end; Phred quality; read length; read count; the
  difference between sequencing data and analysis output.
  Prereqs: 01. Audience: bench-scientist.
  Teaches: FASTQ, read, paired-end, Phred quality, read length.

- **01-foundations/03-amplicon-vs-shotgun** — two ways to sequence: random
  fragmentation and amplicon panels; what a primer scheme is; why amplicon
  data needs primer trimming and shotgun data does not; ARTIC and QIASeq as
  examples.
  Prereqs: 01, 02. Audience: bench-scientist.
  Teaches: amplicon, shotgun, primer, primer scheme, primer trim, soft-clip.

- **01-foundations/04-alignment-files** — what BAM and BAI are; what mapping
  does; coverage; what a pileup is; soft-clipping; why we sort and index;
  introducing IGV-style read views.
  Prereqs: 01, 02. Audience: bench-scientist.
  Teaches: BAM, BAI, alignment, mapping, coverage, pileup, soft-clip
  (deeper than 03), strand.

- **01-foundations/05-variants-and-vcf** — what a variant is; what a VCF
  file is; the columns (CHROM, POS, REF, ALT, QUAL, FILTER, INFO, FORMAT);
  haploid-viral AF semantics ("fraction of reads supporting ALT" not
  per-allele); minimum AF thresholds; FILTER flags.
  Prereqs: 01, 02, 04. Audience: bench-scientist.
  Teaches: variant, VCF, REF, ALT, allele frequency (haploid),
  depth, FILTER, INFO, FORMAT, genotype.

- **01-foundations/06-the-lungfish-project** — projects, the sidebar layout
  (`Imports/`, `Downloads/`, `Reference Sequences/`, `Assemblies/`, `Primer
  Schemes/`); the Welcome window; the Inspector; the Operations Panel; the
  AI Assistant Panel.
  Prereqs: none. Audience: bench-scientist.
  Teaches: project, bundle, Inspector, Operations Panel, sidebar.

- **01-foundations/07-plugin-packs** — what plugin packs are; how to install
  them; how Lungfish uses conda environments; disk and time budgets; checking
  what is installed.
  Prereqs: 06. Audience: bench-scientist.
  Teaches: plugin pack, conda environment, `lungfish conda install`.

- **01-foundations/08-provenance-and-reproducibility** — what provenance
  sidecars are; how to read them; how to export a workflow as a shell
  script, Nextflow, or Snakemake; methods-section export.
  Prereqs: 06. Audience: analyst.
  Teaches: provenance sidecar, methods export, reproducibility.

### Part II: Working with the app

Part II is organised by what the reader is trying to do, not by which tool
they pick. Each chapter is one workflow, and each chapter declares its
foundation prereqs in frontmatter.

#### 02 Sequences

- **02-sequences/01-importing-and-viewing** — drag-drop a FASTA or GenBank
  file; the sequence viewport; the annotation drawer; navigating by gene
  and by location; reverse-complement; translate; Find ORFs with stored
  translation products.
  Prereqs: F01, F06. Audience: bench-scientist.

- **02-sequences/02-downloading-from-ncbi** — Tools > Search Online
  Databases > Search NCBI; saving an accession to a project; making a
  reference bundle; provenance sidecars.
  Prereqs: F06, S01. Audience: bench-scientist.

- **02-sequences/03-extracting-and-comparing** — extracting a region;
  copying as FASTA; comparing two sequences (when this lands).
  Prereqs: S01. Audience: bench-scientist.

- **02-sequences/04-msa-and-trees** — building a multiple sequence
  alignment with MAFFT; viewing an MSA; inferring a tree with IQ-TREE;
  reading a phylogenetic tree.
  Prereqs: F01, F02, S01. Audience: analyst. (Stub for now; ships when
  MSA/tree viewports are documented.)

#### 03 Reads (FASTQ)

- **03-reads/01-importing-fastq** — drag-drop, Import Center, batch import;
  recognising paired files (`_1` / `_2` and `_R1` / `_R2`); naming, sample
  metadata.
  Prereqs: F02, F06. Audience: bench-scientist.

- **03-reads/02-downloading-from-sra** — Tools > Search Online Databases >
  Search SRA; the ENA-first / SRA-Toolkit fallback; downloading paired
  vs single; what the Operations Panel shows.
  Prereqs: F02, F06, F08. Audience: bench-scientist.

- **03-reads/03-quality-control** — Refresh QC Summary (fastp); reading
  the FASTQ viewport sparklines; what good and bad QC look like.
  Prereqs: F02, R01. Audience: bench-scientist.

- **03-reads/04-trimming-and-filtering** — quality trim, adapter removal,
  primer trim, length filter; tool comparison table (fastp vs cutadapt
  semantics).
  Prereqs: F02, F03, R01. Audience: bench-scientist.

- **03-reads/05-decontamination** — removing human reads (Deacon);
  removing rRNA (Deacon / RiboDetector); when to decontaminate and when
  to skip.
  Prereqs: R01. Audience: analyst.

- **03-reads/06-subsetting-and-extraction** — subsample by count or
  proportion; extract reads by ID, motif, or sequence; when to use each.
  Prereqs: R01. Audience: bench-scientist.

- **03-reads/07-ont-runs** — importing ONT run directories; barcoded
  subfolders; orient reads against a reference; long-read vs short-read
  considerations.
  Prereqs: F02, R01. Audience: bench-scientist.

#### 04 Alignments

- **04-alignments/01-mapping-reads-to-a-reference** — the mapping wizard;
  picking minimap2; presets; the alignment track that lands in the bundle.
  Tool comparison: minimap2 vs BWA-MEM2 vs Bowtie2 vs BBMap.
  Prereqs: F02, F03, F04, R01. Audience: bench-scientist.

- **04-alignments/02-reading-an-alignment** — the BAM viewport; coverage
  bars; pileup view; navigating by position; reading depth and strand;
  how a primer-trimmed read renders.
  Prereqs: F04, A01. Audience: bench-scientist.

- **04-alignments/03-primer-trimming** — what amplicon primer trimming
  does and why; the Primer Trim dialog; using a bundled primer scheme;
  bringing your own scheme; the primer-trim provenance sidecar.
  Prereqs: F03, F04, A01, A02. Audience: bench-scientist.

- **04-alignments/04-alignment-quality** — coverage minimums; uniformity;
  duplicate marking (`lungfish markdup`); the QC checks every chapter
  refers back to.
  Prereqs: A01, A02. Audience: analyst.

#### 05 Variants

- **05-variants/01-calling-variants-from-amplicons** — pilot chapter
  (rewritten). End-to-end SARS-CoV-2 amplicon Illumina workflow: NCBI
  reference + GFF download, SRA read download, mapping, primer-trim,
  iVar variant calling with the bundled GFF, variant browser review.
  Tool comparison table picks iVar; defers LoFreq to V03 and Medaka to V04.
  Prereqs: F01-F07, S02, R02, A01, A03. Audience: bench-scientist.

- **05-variants/02-reading-the-variant-browser** — the variant viewport;
  the table drawer; sorting, filtering, smart-filter tokens; the Source
  column; per-variant Inspector detail.
  Prereqs: F05, V01. Audience: bench-scientist.

- **05-variants/03-cross-caller-comparison** — running iVar and LoFreq on
  the same sample; reading the disagreement; when each caller is right;
  the codon-merge teaching moment lands here in detail.
  Prereqs: V01, V02. Audience: analyst.

- **05-variants/04-nanopore-variant-calling** — Medaka against ONT amplicon
  data; what differs from short-read calling; model selection.
  Prereqs: V01, R07. Audience: analyst. (Stub until ONT fixture ships.)

- **05-variants/05-consensus-and-lineage** — consensus FASTA from a VCF;
  attaching to a project; downstream lineage assignment; what Lungfish does
  not do (Pangolin, Nextclade) and how to take the consensus elsewhere.
  Prereqs: V01. Audience: bench-scientist.

- **05-variants/06-importing-existing-vcfs** — drag-drop a VCF; the
  reference-inference logic; matching VCF chromosomes to a Lungfish bundle.
  Prereqs: F05, V02. Audience: bench-scientist.

#### 06 Classification (taxonomy)

- **06-classification/01-what-is-classification** — the question every
  classifier answers; reads → taxa; Kraken2 vs EsViritu vs TaxTriage vs
  NAO-MGS; tool comparison table.
  Prereqs: F02, R01. Audience: bench-scientist.

- **06-classification/02-running-kraken2** — the Kraken2 wizard; database
  install; reading the taxonomy viewport; sunburst, table, breadcrumb;
  read extraction by taxon.
  Prereqs: C01. Audience: bench-scientist.

- **06-classification/03-running-esviritu** — when EsViritu is the right
  tool; running the wizard; reading the result viewport.
  Prereqs: C01. Audience: bench-scientist.

- **06-classification/04-running-taxtriage** — when TaxTriage is the right
  tool; running the wizard; reading the confidence view.
  Prereqs: C01. Audience: bench-scientist.

- **06-classification/05-running-nao-mgs** — wastewater surveillance
  workflow; running the wizard; reading the surveillance result view.
  Prereqs: C01. Audience: analyst.

- **06-classification/06-blast-verification** — verifying a classification
  hit with NCBI BLAST; the BLAST tab in the taxonomy viewport.
  Prereqs: C02 or C03 or C04. Audience: bench-scientist.

- **06-classification/07-running-freyja** — wastewater SARS-CoV-2 lineage
  demixing with Freyja command plans and provenance.
  Prereqs: C01, V01. Audience: analyst.

#### 07 Assembly

- **07-assembly/01-when-to-assemble** — the assembly question; reference-based
  vs de novo; the Lungfish assembly wizard; tool comparison table for
  SPAdes, MEGAHIT, SKESA, Flye, Hifiasm.
  Prereqs: F02, R01. Audience: bench-scientist.

- **07-assembly/02-running-spades** — short-read viral assembly with SPAdes;
  the assembly viewport; contig inspection; N50 and contig stats.
  Prereqs: AS01. Audience: bench-scientist.

- **07-assembly/03-running-flye-or-hifiasm** — long-read assembly with Flye
  or Hifiasm; when each is right.
  Prereqs: AS01, R07. Audience: analyst.

- **07-assembly/04-extracting-contigs** — picking contigs from an assembly;
  deriving a new bundle; using contigs as a reference for downstream
  workflows.
  Prereqs: AS01, AS02. Audience: bench-scientist.

#### 08 Workflows

- **08-workflows/01-the-workflow-builder** — the visual node-graph composer;
  palette, canvas, connections; running a saved workflow.
  Prereqs: F06, F08. Audience: analyst.

- **08-workflows/02-exporting-as-nextflow-or-snakemake** — provenance-driven
  export; methods-section text; sharing pipelines.
  Prereqs: F08, W01. Audience: analyst.

### Part III: Reference

- **appendices/cli-reference** — every `lungfish` subcommand, grouped by
  domain; cross-references the Part II chapter that uses each command.
- **appendices/keyboard-shortcuts** — the full key map.
- **appendices/troubleshooting** — common failures and resolutions; SRA
  download flake; conda env solve drift; missing plugin packs; project
  permissions; bundle migration.
- **appendices/glossary** → see `GLOSSARY.md`.
- **appendices/file-formats** — what every Lungfish bundle file looks like
  (`.lungfishref`, `.lungfishvcf`, `.lungfishmsa`, `.lungfishtree`,
  `.lungfishprimers`).
- **appendices/power-user-notes** — the deeper-dive content stripped out of
  bench-scientist chapters: exact mpileup flags, indelqual handling, env
  pinning, sidecar schema, deterministic-execution caveats.

## Prerequisite graph

The dependency graph for the pilot chapter (`05-variants/01`) is:

```
F01 → F02 → F03 → A01 → A03 → V01
       ↓           ↓
       F04 → F05 ──┴→ V01
F06 → F07 → V01
F08 ────────→ V01 (optional but recommended)
S02 ────────→ V01 (the NCBI download step)
R02 ────────→ V01 (the SRA download step)
```

A reader entering V01 cold needs F01-F07 minimally and S02 + R02 for the
download steps. V01's "Before you start" section names these prerequisites
and links each.

## Pilot chapter (this revision)

The pilot is `chapters/05-variants/01-calling-variants-from-amplicons.md`,
moved and renamed from `04-variants/01-reads-to-variants.md` to fit the
revised TOC numbering. Audience: bench-scientist. Tool: iVar only. Fixture:
`sarscov2-srr36291587` augmented with `MN908947.3.gff3` from NCBI so the
codon-merge teaching moment becomes a real demonstration rather than a
hypothetical.

The pilot's frontmatter declares prereqs F01-F07, S02, R02, A01, A03.
Until those chapters ship, the pilot's "Before you start" section folds
in the minimum vocabulary inline (definitions of FASTQ, BAM, VCF, primer
scheme, plugin pack, project, bundle, Operations Panel, allele frequency,
depth) so the chapter survives without the foundations layer.

## Status of each chapter

| Chapter | Status |
|---|---|
| F01-F08 | not started |
| S01-S04 | not started |
| R01-R07 | not started |
| A01-A04 | not started |
| V01 | written, under revision |
| V02-V06 | not started |
| C01-C06 | not started |
| AS01-AS04 | not started |
| W01-W02 | not started |
| Appendices | not started |

The 2026-05-09 plan ships the V01 rewrite first, with inline minimum-vocabulary
to compensate for missing foundations. The next planning sprint stubs every
chapter listed above (frontmatter + one-paragraph teaching summary) so the
manual's full surface is visible before any further chapter writing begins.

## Resolved planning decisions (2026-05-09)

- **Foundations as short standalone pages, not a booklet.** Web-first
  presentation (MkDocs Material on ReadTheDocs-style hosting) favors
  short pages with stable anchor URLs that other chapters can deep-link
  to. Each foundations page is 5-10 minutes of reading and ends with a
  "next" pointer. The PDF build assembles them in order.
- **Schematic illustrations for foundations chapters.** Foundations
  chapters carry `<!-- ILLUSTRATION: id -->` markers paired with a
  per-chapter `illustrations.yaml` that records brief, palette, and
  target dimension. Briefs are written to the brand-style guide so an
  external image generator can produce them with consistent voice.
  Illustrations live in `assets/illustrations-imagegen/`.
- **Tool-choice tables are markdown tables.** Three columns: "If your
  data is" / "Use" / "Why". Linter-safe; renders cleanly in both web
  and PDF.
- **AI Assistant deferred.** Functionality is currently scoped to VCF
  workflows and will broaden. Defer documenting until the surface is
  stable.
- **V03 (cross-caller comparison) ordering deferred** to the next
  planning round.
