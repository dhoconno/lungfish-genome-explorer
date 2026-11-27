# ARCHITECTURE, Lungfish User Manual

**Ownership.** Documentation Lead only.

This file holds the chapter scopes, audience tiers, editorial rules, and
the rationale behind each chapter's placement.

## Status (2026-05-09)

Sub-project 1 delivered one pilot chapter, then at
`04-variants/01-reads-to-variants`. The 2026-05-09 focus-group review, filed
under `reviews/04-variants-01-reads-to-variants/focus-groups-2026-05-09/`,
found that the pilot could not stand alone. Every audience tier needed
foundations material before the variants chapter was readable cold. That
revision planned the full manual, named every chapter, and recorded the
prerequisite graph so authors knew what readers already knew when they
arrived.

## Status (2026-09-06)

The 2026-09 fidelity and accessibility campaign rewrote every chapter to the
template in `STYLE.md` against the 2026.9.13 Preview build, added
`parameters.yaml`, switched fixtures to human and macaque data, and
recaptured screenshots. Editorial rule 5, screenshots at gate 2, is in force
again. The audience for every chapter is the undergraduate reader described
in `STYLE.md`. The three tiers below remain as labels that describe how much
a reader already knows, not how the chapter is written. A tier label only
tells authors which background they may mention without a gloss.

## Status (2026-09-24)

The owner asked for a review that makes every chapter of the Lungfish
Genome Explorer (LGE) manual correct, accessible, free of repetition, and
narrow in scope. The inventories found the same
explanations written out in many places. The FASTQ summary cards appeared in
three chapters with identical numbers. Plugin pack installation appeared in
at least ten. Provenance and checksums appeared in most task chapters. The
FILTER lesson on the HG002 fixture appeared in four.

This revision fixes scope by assigning each shared concept one owning
chapter and heading. Every other chapter writes a one-sentence gloss and a
link. The working plan with the standard gloss sentences, the per-chapter
contracts, and the lane assignment lives outside the repository in the
review scratchpad as `SCOPE-MAP.md`. The durable record is the Chapter
scopes table below, which later campaigns update rather than replace. Where
the older Table of contents section further down disagrees with that table,
the table wins, and `build/mkdocs.yml` remains the menu of chapters readers see.

Five rules from this revision stay in force.

1. No chapter file is renamed or moved. Tests pin two chapter paths and
   `help-ids.yaml` resolves in-app help to chapter ids, so scope changes by
   cutting text rather than by moving files.
2. Defects are listed once, in the known-defects registry in
   `appendices/troubleshooting.md`, with the build each was verified on.
   A task chapter mentions a defect in one sentence only where it blocks
   the procedure, and it never names a build number.
3. `## On the command line` holds one shell block that reproduces the
   procedure. Flag catalogues live in `appendices/cli-reference.md`.
4. Settings shared by every operation in a chapter, such as Output Strategy,
   Threads, and Extra arguments, are documented once per chapter in the
   standard wording that `01-foundations/06-the-lungfish-project.md` owns.
5. Numbers from the SRR36291587 fixture come from the rebuilt fixture's
   measured facts, since the earlier copy had lost its second mates.

Three structural fixes land with this revision. `02-sequences/03` is
retitled Extracting Sequences, because it never compared sequences.
`09-genotyping/04` is rebuilt to the chapter template. The haplotype
placeholder stubs in `09-genotyping/01` to `03` are deleted under editorial
rule 2.

## Status (2026-09-27)

The textbook revision made the manual one course from start to finish as
well as a reference. Part 10, Primer Design, joined the nav menu and the
scopes table with a settings appendix. Foundations now opens with the
project chapter, which owns getting LGE, the release channels, the demo
projects, the Tools menu map, and the convention every On the command line
block follows. A downloadable demo project with finished results, Human
Mapping and Variants (with results), replaced the project readers used to
build from a script in Terminal, and the script-built project survives only
as the screenshot project in the contributor notes of its fixture folder.

The nav order changed while every file kept its path, as rule 1
below requires. Foundations reads 06, 01, 02, 03, 04, 05, 07, 08.
Alignments reads 01, 02, 04, 03, 05, so the shotgun chapters come
together. Human Germline Variants (Experimental) follows Variants and opens
with its reference-files chapter. Classification reads 01, 02, 03, 04, 06,
10, 07, 08, 05, 09, so the runnable tools come before the imports. The
part titles "Human Germline Variants (Experimental)" and "MHC Allele
Genotyping" and the two assembly chapter titles are the ones every link
uses.

Three more rules from this revision are recorded in `STYLE.md`. Task
chapters have no Troubleshooting section. Procedure headings are task
phrases that name the tool. Percentages are written "95 percent" in prose
and "95%" in tables and code.

## Status (2026-11-21)

The owner asked on 2026-11-21 that the manual and its screenshots reflect
every change of Phases 1 to 5 (direction O181), followed by a copy edit with
a second model and then tutorials and references. The last full rewrite was
against Preview 2026.9.13. Four inventories in the refresh scratchpad list
about 280 user-visible changes since then, and the per-chapter work list is
`CHAPTER-MAP.md` beside them, as `SCOPE-MAP.md` was for the 2026-09-24
revision. The Chapter scopes table below stays the durable record.

Facts now come, in order, from the newest published Preview's packaged app
and its `lungfish-cli --help` tree, the Swift source at the lane's base,
`parameters.yaml`, and `features.yaml`, which the Code Cartographer
refreshed to 133 rows. The copy of `Lungfish Preview.app` installed in
`/Applications` is older and is not used. A surface that the text-in-views
job (ux-text) changes is described and captured only on the Preview that
job publishes.

Stage B runs each chapter through the Opus-Sol loop of the refresh's
process design. Sol's edited text becomes the prose, and Opus objects only
for a wrong fact, a broken binding rule, or a conflict with the scopes and
structure in this file.

Phase 5 added RNA-seq, which had no chapter. It gets a part of its own,
`11-rna-seq/`, with five chapters that cover bulk counts, single-cell
counts, and the cell map. Three other topics get new chapters.
`02-sequences/06` imports Geneious and other application exports.
`03-reads/09` takes Demultiplex Barcodes out of the nanopore chapter,
because it now serves every platform with three engines and a chance
floor, and `03-reads/07` keeps run folders, the read type, and the Fluidigm
split. `08-workflows/04` owns running a step on a Linux machine or an
HTCondor pool, which the FASTQ, RNA-seq, and single-cell plan cards share.
Workflow packages and nf-core pipelines need no new chapter, since
`08-workflows/03` and the task chapters already own them. A Tutorials
section of ten hands-on chapters, one per demo project or RNA-seq fixture,
joins the nav before Reference.

Five rules from this revision stay in force.

1. Every count names its unit, such as reads, fragments, or alignment
   records, because Phases 2 to 5 changed what mapping, Kraken 2, EsViritu,
   TaxTriage, NVD, and NAO-MGS count. The Glossary entry for fragment owns
   the difference between a read and a fragment.
2. An on-screen label is quoted exactly as the app shows it, in bold. The
   cell map keeps British labels such as **Colour by**, and the prose around
   them stays in US English.
3. A tutorial opens with `## What it is`, which states its learning goals.
   Each step ends with an expected result taken from a recorded
   `lungfish-cli` run on the fixture or from a test, and each question
   carries its answer in a collapsible `??? question` block. The tutorial
   template joins `STYLE.md` before the first tutorial lane, with the
   coordinator's agreement.
4. Conceptual reading lives in a Further reading part of
   `appendices/bibliography.md`, grouped by chapter, and each chapter's
   `## Next` section links its group, so the chapter template gains no
   section. Every citation resolves through doi.org or PubMed with a
   matching title.
5. Rule 1 of 2026-09-24 still holds. New chapters take new paths, the
   demultiplexing split cuts text from `03-reads/07` rather than moving a
   file, and the two `help-ids.yaml` rows for ONT import keep pointing at
   `03-reads/07`.

## Chapter scopes

Each row is a contract. A chapter covers its scope and nothing else, and it
is the only chapter that explains the topics in its last column in full.

| Path | Scope | Owns |
|---|---|---|
| 01-foundations/01-what-is-a-genome | What a genome, a reference genome, and a coordinate are, on the HBB record | Reference genome, 1-based coordinate, contig names, genome shapes, reference choice |
| 01-foundations/02-sequencing-reads | What a read and a FASTQ file are, pairing, Phred scores, platform differences | FASTQ record, paired-end reads, Phred scores |
| 01-foundations/03-amplicon-vs-shotgun | Shotgun, amplicon, and enrichment libraries and why amplicon reads need primer trimming | Amplicon, primer, primer scheme concept, shotgun |
| 01-foundations/04-alignment-files | What a BAM row records, CIGAR, indexes, coverage, pileup, strand | BAM, MAPQ, CIGAR and soft clips, depth and breadth, pileup, strand bias |
| 01-foundations/05-variants-and-vcf | What a variant is and how to read a VCF file | VCF columns, QUAL, INFO, FORMAT, genotype notation, FILTER semantics |
| 01-foundations/06-the-lungfish-project | Getting LGE, the project, the window, and the app chrome every chapter assumes | System requirements, release channels, first launch and updates, opening a project, demo projects and fixtures, sidebar folders, where results land, bundles and tracks, the Tools menu map, Import Center, operation dialogs and their shared settings, Inspector, Operations Panel, the On the command line path convention, the Selection menu, Copy CLI Command and the command behind each Operations row, the No Project Open alert, failure alerts and Show Details, File > Export > Image |
| 01-foundations/07-plugin-packs | Installing and managing packs, databases, experimental features, specialized workflows, and container prerequisites | Plugin packs and pack ids, Required Setup, experimental features, turning on a specialized workflow, databases, the container runtime, offline pack installation, the Storage tab of Settings and Reclaim Duplicate Space |
| 01-foundations/08-provenance-and-reproducibility | Reading, signing, and verifying a provenance record | Provenance, checksum, the Inspector Provenance section, reading a lineage, affected-result warnings and the band above the viewer, the Runtime section of a Linux run |
| 02-sequences/01-importing-and-viewing | Importing a reference and an annotation track and reading them in the sequence viewport | Sequence viewport, Go to Location, translation tool, manual annotation |
| 02-sequences/02-downloading-from-ncbi | Downloading a record from NCBI or Pathoplexus as a reference bundle | Database Browser search, accession substitution |
| 02-sequences/03-extracting-and-comparing | Extracting regions and features, marking open reading frames, exporting sequences, and merging reference bundles | Extract Sequence, Find ORFs, Export Sequences, Merge Into New Bundle |
| 02-sequences/04-aligning-sequences | Building, reading, and exporting a MAFFT alignment | MSA and the MSA viewport |
| 02-sequences/05-building-trees | Inferring, reading, re-rooting, and pruning an IQ-TREE tree | Tree terms, Newick, the tree viewport |
| 02-sequences/06-importing-application-exports | Importing a Geneious archive or another application's export folder as reference and annotation bundles | The Geneious Export card, application export kinds, what an export import keeps and leaves out |
| 03-reads/01-importing-fastq | Importing FASTQ files or an unmapped ONT BAM, pairing, sample sheets, sample metadata | Pairing rules, processing recipes, sample metadata |
| 03-reads/02-downloading-from-sra | Downloading an SRA run as a read bundle | SRA accessions, ENA and Toolkit fallback |
| 03-reads/03-quality-control | Reading a FASTQ bundle's summary cards, charts, and Reads tab | FASTQ viewport, summary cards, sparklines |
| 03-reads/04-trimming-and-filtering | The six Trimming and Filtering operations | Read-level primer trimming, length filtering |
| 03-reads/05-decontamination | The five Decontamination operations | Host, rRNA, contaminant, entropy, and duplicate removal at read level |
| 03-reads/06-subsetting-and-extraction | The five Search and Subsetting operations | Virtual bundles and materialization |
| 03-reads/07-ont-runs | Importing an ONT run folder, setting the read type of an older ONT bundle, and splitting a Fluidigm library | MinKNOW run folders and their barcode folders, ONT read type, ONT Fluidigm Sample Split |
| 03-reads/08-read-processing | The six Read Processing operations plus interleave and deinterleave | Read merging, insert size, orientation |
| 03-reads/09-demultiplexing-barcodes | Splitting a pooled read bundle into one bundle per sample with Demultiplex Barcodes, on every platform | Barcodes, barcode kits and custom definitions, the Read Names, Cutadapt, and Exact Bare Barcode engines, dual indexes, the chance floor, Keep Unchecked Samples, the Demux tab and Detect Barcodes, barcode scout |
| 04-alignments/01-mapping-reads-to-a-reference | Running a mapper and reading the alignment statistics | Mapper choice, presets, read groups, Est. Coverage, Flag Statistics |
| 04-alignments/02-reading-an-alignment | Reading the alignment viewport, its View Settings, and region extraction | Coverage curve, read display budget, Inspector Analysis tabs, what an exported alignment figure draws |
| 04-alignments/03-primer-trimming | Primer-trimming a mapped alignment with iVar | Alignment-level primer trimming, trim rate |
| 04-alignments/04-alignment-quality | Marking duplicates without deleting the unmarked tracks, filtering an alignment, exporting a deduplicated bundle | Duplicate marking, duplicate rate |
| 04-alignments/05-viral-recon-wizard | Running nf-core/viralrecon on SARS-CoV-2 amplicon reads | The Viral Recon wizard |
| 05-variants/01-calling-variants-from-amplicons | Running bcftools, LoFreq, and iVar from the Call Variants dialog | Caller choice, the Call Variants dialog |
| 05-variants/02-reading-the-variant-browser | The Variants tab and exporting rows with variants query | Table drawer, chips, Search Builder, caller comparison |
| 05-variants/04-nanopore-variant-calling | Calling ONT variants with Medaka or Clair3 | Model choice for ONT callers |
| 05-variants/05-consensus-and-lineage | Extracting a consensus sequence from an alignment | Consensus sequence, N masking |
| 05-variants/06-importing-existing-vcfs | Importing an existing VCF onto a bundle or as a variant-only bundle | VCF import paths |
| 06-classification/01-what-is-classification | What classification answers and which classifier to pick | Taxon, rank, lowest common ancestor, runnable versus imported tools |
| 06-classification/02-running-kraken2 | Running Kraken 2 with Bracken and reading the taxonomy viewport | k-mers and minimizers, taxonomy viewport, read extraction by taxon, the classifier action bar every classifier viewport shares |
| 06-classification/03-running-esviritu | Running EsViritu and reading viral coverage | Viral coverage evidence |
| 06-classification/04-running-taxtriage | Running TaxTriage and reading the TASS score | Sample roles, TASS score |
| 06-classification/05-running-nao-mgs | Importing NAO-MGS results and reading the taxon viewport | NAO-MGS import |
| 06-classification/06-blast-verification | Verifying a classifier hit with NCBI BLAST | BLAST interpretation |
| 06-classification/07-running-freyja | Running Freyja demix from the command line | Lineage demixing |
| 06-classification/08-importing-cz-id-results | Importing a CZ ID taxon report | CZ ID import |
| 06-classification/09-novel-virus-detection | Importing NVD results and reading contig BLAST matches | NVD import, RPB |
| 06-classification/10-twelve-s-metabarcoding | Running the 12S exact-match workflow | 12S matching, unresolved clusters |
| 06-human-germline-variants/01-haplotype-caller | Calling germline variants with GATK HaplotypeCaller | HaplotypeCaller and the phased route |
| 06-human-germline-variants/02-joint-genotyping | Combining GVCFs into a cohort VCF | Joint genotyping |
| 06-human-germline-variants/03-filtering-selecting-and-metrics | The post-calling GATK steps | Hard filters, Ti/Tv and GATK metrics |
| 06-human-germline-variants/04-reference-packs | Building the reference companion files GATK needs and running BQSR | FASTA index, sequence dictionary, known sites, intervals |
| 07-assembly/01-when-to-assemble | Whether to assemble and which assembler to pick | De novo assembly, assembler choice, N50 and L50 |
| 07-assembly/02-running-spades | Running SPAdes, MEGAHIT, or SKESA and reading any assembly result | Contig table, Assembly Context |
| 07-assembly/03-running-flye-or-hifiasm | Running Flye or hifiasm and diagnosing doubled circular contigs | Long-read assembly, circular overshoot |
| 07-assembly/04-extracting-contigs | Turning selected contigs into a reference bundle | Create Bundle from contigs |
| 08-workflows/02-exporting-as-nextflow-or-snakemake | Exporting a run record as a script, workflow, methods text, or JSON | Provenance export |
| 08-workflows/03-running-external-workflows | Linking, enabling, and running a workflow package | Workflow Library, run bundles |
| 08-workflows/04-running-on-a-linux-machine | Writing a plan folder for a Linux machine or an HTCondor pool, running it there, and adopting the returned run into the project | Plan folders, staging folders and staged reads, `run-local.sh`, HTCondor submit files and held jobs, the FASTQ Plan for a Linux Machine and Linux Run Result cards, adopting a run |
| 09-genotyping/01-what-is-mhc-genotyping | What MHC genotyping answers and which workflow to use | Allele, locus, haplotype, allele naming, retained reads |
| 09-genotyping/02-running-genotyping | Running the two MHC genotyping workflows | Genotyping dialogs, bbmerge and DRB merging |
| 09-genotyping/03-reading-the-genotype-comparison | Reading and annotating the genotype matrix | Support status, percent basis, matrix filters |
| 09-genotyping/04-haplotype-definitions-and-export | Exporting genotype results to Excel, CSV, TSV, and LabKey | Genotype export |
| 10-primer-design/01-what-is-primer-design | What primer design answers and which engine to pick | Primer properties, melting temperature, GC clamp, primer dimers, degenerate bases and their cost, pools and tiling, qPCR and dPCR chemistry, in-silico versus bench checks, why MHC is a hard primer target |
| 10-primer-design/02-designing-a-pcr-assay | Designing one conventional PCR assay with Primer3 | Primer3 procedure, template and target choice |
| 10-primer-design/03-designing-a-tiled-amplicon-scheme | Designing a tiled amplicon scheme with PrimalScheme, Olivar, or varVAMP | Tiled scheme design, coverage of a variable target |
| 10-primer-design/04-designing-qpcr-and-dpcr-assays | Designing qPCR and dPCR assays with a probe or an intercalating dye | Probe design, testing the lineage assay for specificity |
| 10-primer-design/05-reviewing-and-ordering-primers | Reviewing a primer analysis, saving a scheme, and ordering oligos | The primer analysis viewer, Save as Primer Scheme, order export, bench validation |
| 11-rna-seq/01-what-is-rna-seq | What RNA-seq measures, how bulk and single-cell libraries differ, and which counting route to pick | Transcript and gene expression, read counts and library size, CPM and TPM, biological replicates, reference sets, the counting route choice (salmon, STAR, featureCounts, or counts another tool made), not-host share, the RNA-seq submenu |
| 11-rna-seq/02-counting-bulk-reads | Installing or building a reference set, counting reads with salmon on the Mac, planning salmon or STAR for a Linux machine, and importing counts another tool made | Reference set and salmon index, the RNA-seq Reference Sets section of Plugin Manager, Count Reads per Gene, the Existing Bulk RNA-seq Counts card, the settings of the RNA-seq plan and adopt sheets |
| 11-rna-seq/03-reading-and-exporting-bulk-counts | Reading a bulk RNA-seq result, its quality table, and its sample correlation, and exporting counts for DESeq2, edgeR, and limma | Bulk view, RNA-seq quality numbers, sample correlation, Export Counts and Analysis Scripts, design and contrast, batch correction |
| 11-rna-seq/04-single-cell-counts | Importing Cell Ranger or STARsolo counts, planning a STARsolo run, reading the single-cell view, pseudobulking cells, and exporting for Seurat and Scanpy | Cell barcode, count matrix, rank plot, ambient RNA and the not-host flags, the Existing Single-cell Counts card, STARsolo presets, Pseudobulk RNA-seq Cells, the Seurat and Scanpy export |
| 11-rna-seq/05-the-cell-map | Importing or computing a cell embedding, and reading, coloring, and selecting cells on the cell map | Embedding, UMAP, t-SNE and PCA, clusters and Leiden, Import Embedding, `rnaseq cell-map compute`, coloring by label or gene, cell selection, Save Selection as Labels Table, Pseudobulk Selected Cells |
| tutorials/01-from-a-gene-to-a-tree | A hands-on run through the `genes-and-sequences` demo project, from the HBB record to a primate alignment and a tree | Its learning goals, questions, and answers |
| tutorials/02-human-reads-to-variants | The `human-reads` and `human-mapping-and-variants` demo projects, from HG002 reads to a checked variants table | Its learning goals, questions, and answers |
| tutorials/03-sars-cov-2-amplicons | The `sarscov2-amplicons` demo project through primer trimming, variant calling, and Viral Recon | Its learning goals, questions, and answers |
| tutorials/04-clinical-metagenome | The `pathogen-detection` demo project through classification and BLAST verification | Its learning goals, questions, and answers |
| tutorials/05-long-reads-and-assembly | The `long-reads-and-assembly` demo project through long-read assembly and nanopore variant calling | Its learning goals, questions, and answers |
| tutorials/06-macaque-mhc-genotyping | The `mhc-genotyping` demo project, from amplicon reads to an exported genotype matrix | Its learning goals, questions, and answers |
| tutorials/07-designing-primers | The `primer-design` demo project through a PCR assay, a tiled scheme, and an order sheet | Its learning goals, questions, and answers |
| tutorials/08-twelve-s-metabarcoding | The `twelve-s-metabarcoding` demo project through 12S matching and unresolved clusters | Its learning goals, questions, and answers |
| tutorials/09-bulk-rna-seq | The bulk RNA-seq fixture, from reads to counts exported for DESeq2 | Its learning goals, questions, and answers |
| tutorials/10-single-cell-and-the-cell-map | The pbmc_1k_v3 fixture, from imported counts to a pseudobulk of cells selected on the cell map | Its learning goals, questions, and answers |
| appendices/cli-reference | Syntax and flags of every lungfish-cli command | Finding the program, every flag list |
| appendices/file-formats | Structure of every file and bundle format | Bundle layouts, provenance sidecar schema, coordinate conventions |
| appendices/keyboard-shortcuts | Every keyboard shortcut | Shortcut notation |
| appendices/power-user-notes | Exact tool arguments and the limits on repeating a run | Wrapped-tool argument lists |
| appendices/primer-schemes | The primer scheme bundle format and the shipped schemes | Shipped scheme catalogue |
| appendices/primer-design-settings | Every setting of Primer3, PrimalScheme, Olivar, and varVAMP | Engine settings not used by a Part 10 procedure |
| appendices/shared-projects | Project locks, read-only state, and bundle migration | Project locks |
| appendices/tool-versions | Pinned versions of every tool, pipeline, and database | Version tables |
| appendices/bibliography | Citing the tools a run used and citing LGE, and the further reading for each chapter | Citations, the Further reading part grouped by chapter |
| appendices/06-running-in-ci | Running the command line unattended on a CI runner | CI provisioning |
| appendices/ai-assistant | The bring-your-own-key Assistant tab | The Assistant |
| appendices/troubleshooting | Symptom lookup and the known-defects registry | Failed-run debugging, known defects |
| chapters/README | Contributor index of the chapters tree, not a reader chapter | Nothing |

## Audience tiers

Each chapter declares one of three tiers in its frontmatter.

| Tier | Reader |
|---|---|
| `bench-scientist` | The default. A scientist with biology training and little or no computational analysis, who knows lab vocabulary but not bioinformatics vocabulary. |
| `analyst` | A scientist who has run pipelines other people built, or done comparable work in Geneious, CLC, IGV, or an in-house pipeline, and is comfortable with file formats and the shell. |
| `power-user` | A developer or computational biologist building or validating their own pipelines, who reads source, checks flags, and benchmarks. |

Most chapters target `bench-scientist`. Deeper chapters are `analyst`, and
the CLI reference and reproducibility appendices are `power-user`.

## Editorial rules from the focus groups

These rules apply to every chapter.

| Rule | Requirement |
|---|---|
| 1. Define a term at first use | Gloss each term inline in one short sentence the first time a chapter uses it, with the full definition in the Glossary. This covers amplicon, BAM, FASTQ, VCF, primer scheme, pileup, soft clip, Phred score, allele frequency, depth, strand bias, reference bundle, plugin pack, and GFF among others. |
| 2. Promise only what exists | Never offer a future feature or a future chapter as the answer to a real question. If a feature is missing, say so plainly. |
| 3. Tool comparison tables | Wherever a chapter picks one tool among several, a small table names the alternatives and when each is preferred. |
| 4. Real ancillary files | Every GFF, primer scheme, or metadata sheet a chapter mentions ships with the fixture and is used in the procedure. |
| 5. Screenshots at gate 2 | A chapter without its declared shots does not pass review. |
| 6. Command-line parity once, at the end | A chapter that walks a window procedure ends with one shell block reproducing it, and the full flag list lives in the CLI reference. |
| 7. Why before how | A biological motivation tied to the chapter's example precedes every procedure. |
| 8. Quality check before done | Every workflow chapter ends with a short "What good looks like" section naming the checks to apply before trusting the output. |

## Retrieval surface (in-app documentation rules)

The manual is also the knowledge base for the in-app AI assistant and for
contextual help. A user asking a question inside LGE, such as what a dialog
does or what a primer scheme is, expects an answer grounded in the manual
without leaving the app. These rules keep chapters retrievable.

| Rule | Requirement |
|---|---|
| 1. Self-describing sections | Every H2 and H3 makes sense when surfaced alone by a search. Name the tool, file, or step rather than writing "this dialog" or "that step". |
| 2. Structured frontmatter | Every chapter declares `tags`, `tools`, `entry_points` (mirroring `features.yaml`), and a one-sentence imperative `task`, beside `chapter_id`, `audience`, `prereqs`, `glossary_refs`, `features_refs`, `fixtures_refs`, `shots`, `estimated_reading_min`, `brand_reviewed`, and `lead_approved`. |
| 3. Stable glossary anchors | Each `GLOSSARY.md` term declares an explicit `{#anchor}` matching its `glossary_refs` slug. Chapters link `../../GLOSSARY.md#<slug>`, and the app deep-links to the same anchor. |
| 4. Language-tagged code blocks | `bash` for shell, `text` only for sample output, plus content tags such as `vcf`, `fastq`, `gff`, and `json`. |
| 5. Help ids | Every dialog, viewport, and major Inspector section declares a `help_id`, and `help-ids.yaml`, owned by the Code Cartographer, resolves each to a chapter anchor for the app's help affordance. |
| 6. Author for retrieval | No backreference chains such as "as we saw earlier". Each section opens with a noun phrase naming its subject. |
| 7. Inline definitions echo the Glossary | An inline gloss uses the Glossary entry's wording, so the two never disagree. |

## Table of contents

The chapter list, with each chapter's scope, is the `## Chapter scopes`
table above, and the published order is the `nav` block of
`build/mkdocs.yml`. After the 2026-11-21 refresh lands, the nav menu has
fourteen sections after the home page. Twelve hold chapters, one holds the
tutorials, and one holds the reference appendices. Until then it has
twelve, eleven of chapters and one of reference appendices.

The refresh places its new files in the nav as follows. Sequences reads
01, 06, 02, 03, 04, 05, so both import chapters come first. Reads (FASTQ)
reads 01 to 07, then 09, then 08, so demultiplexing follows the nanopore
chapter. Workflows reads 02, 03, 04. RNA-seq follows Assembly and comes
before Workflows. Tutorials follows Primer Design and comes before
Reference.

| Section | Folders | Role |
|---|---|---|
| Foundations | `01-foundations/` | Getting LGE and the concept and format primers every later chapter assumes |
| Sequences | `02-sequences/` | Reference sequences, imports from other applications, extraction, multiple sequence alignment, and trees |
| Reads (FASTQ) | `03-reads/` | Read import, download, quality control, read-level processing, and demultiplexing |
| Alignments | `04-alignments/` | Mapping, reading and checking alignments, primer trimming, Viral Recon |
| Variants | `05-variants/` | Variant calling, the variants table, consensus, VCF import |
| Human Germline Variants (Experimental) | `06-human-germline-variants/` | GATK germline calling. It shares the `06-` prefix with Classification by design |
| Classification | `06-classification/` | Read classification, BLAST verification, 12S metabarcoding, result imports |
| Assembly | `07-assembly/` | De novo assembly and contig extraction |
| RNA-seq | `11-rna-seq/` | Counting bulk and single-cell RNA-seq, reading and exporting counts, and the cell map. It comes before Workflows in the nav although its folder number is higher |
| Workflows | `08-workflows/` | Provenance export, workflow packages, and runs on a Linux machine or an HTCondor pool. Numbering starts at 02 because the removed builder chapter was 01 |
| MHC Allele Genotyping | `09-genotyping/` | Amplicon MHC genotyping and genotype export |
| Primer Design | `10-primer-design/` | PCR, tiled amplicon, qPCR, and dPCR primer design |
| Tutorials | `tutorials/` | Hands-on runs through a demo project or fixture, with learning goals, expected results, and questions with answers |
| Reference | `appendices/` and `GLOSSARY.md` | Look-up material, including the CLI reference, file formats, tool versions, troubleshooting, and the glossary |

## Prerequisite graph

Chapters declare their prerequisites in frontmatter `prereqs`. The graph
drawn for the original pilot, `05-variants/01`, is kept as the
reference example.

```
F01 → F02 → F03 → A01 → A03 → V01
       ↓           ↓
       F04 → F05 ──┴→ V01
F06 → F07 → V01
F08 ────────→ V01 (optional but recommended)
S02 ────────→ V01 (the NCBI download step)
R02 ────────→ V01 (the SRA download step)
```

A reader entering V01 cold needs F01 to F07, plus S02 and R02 for the
download steps, and V01's `## Before you start` names each.

The chapters the 2026-11-21 refresh adds use the same shorthand, with F
for Foundations, S for Sequences, R for Reads, W for Workflows, and N for
RNA-seq, each followed by the file number.

```
F06 → S01 → S06
F02 → R01 → R07
      R01 → R09
      R01 → W04 ← F08
F01 → N01 → N02 → N03
F07 ──────→ N02          (the RNA-Seq Analysis pack)
R01 ──────→ N02
      N01 → N04 → N05
F07 ────────────→ N05    (the Single-Cell Analysis pack, for cell-map compute only)
W04 ┈┈┈┈┈┈→ N02, N04     (the Linux plan sections only)
```

W04 is a side trip for N02 and N04, which name it in the plan section
rather than in `prereqs`, since a reader can count reads on the Mac without
it. R07 is a side trip for R09 for the same reason. Each tutorial lists F06
and every chapter its steps link as `prereqs`. T09 adds N01 to N03, and T10
adds N01, N04, and N05. A tutorial teaches no concept a chapter owns. It
links the owning heading instead.

## Resolved planning decisions (2026-05-09)

| Decision | Detail |
|---|---|
| Foundations as short standalone pages | Web-first presentation favours short pages with stable anchors other chapters can deep-link to. Each foundations page ends with a next pointer, and the PDF build assembles them in nav order. The home page lists each page's reading time from its frontmatter. |
| Schematic illustrations | Chapters and the home page, `index.md`, carry `<!-- ILLUSTRATION: id -->` markers paired with `illustrations.yaml`, which records the brief, palette, and size. Illustrations live in `assets/illustrations-imagegen/<part>/<chapter>/`, and the home page's in `assets/illustrations-imagegen/index/`. `build/hooks/shots.py` renders a marker once its image exists and leaves the comment in place until then. |
| Tool-choice tables are Markdown tables | Superseded on 2026-09-26 by the four-column table in `STYLE.md` (Tool, Built for, Choose it when, Choose something else when), which every Choosing a tool section uses. Markdown tables render in both the web and PDF builds. |
