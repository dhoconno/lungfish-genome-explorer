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
| 01-foundations/06-the-lungfish-project | The project, the window, and the app chrome every chapter assumes | Opening a project, practice data, sidebar folders, where results land, bundles, Import Center, operation dialogs and their shared settings, Inspector, Operations Panel |
| 01-foundations/07-plugin-packs | Installing and managing packs, databases, experimental features, and container prerequisites | Plugin packs and pack ids, Required Setup, experimental features, databases, containers |
| 01-foundations/08-provenance-and-reproducibility | Reading, signing, and verifying a provenance record | Provenance, checksum, the Inspector Provenance section |
| 02-sequences/01-importing-and-viewing | Importing a reference and an annotation track and reading them in the sequence viewport | Sequence viewport, Go to Location, translation tool, manual annotation |
| 02-sequences/02-downloading-from-ncbi | Downloading a record from NCBI or Pathoplexus as a reference bundle | Database Browser search, accession substitution |
| 02-sequences/03-extracting-and-comparing | Extracting regions and features and marking open reading frames | Extract Sequence, Find ORFs |
| 02-sequences/04-aligning-sequences | Building, reading, and exporting a MAFFT alignment | MSA and the MSA viewport |
| 02-sequences/05-building-trees | Inferring, reading, re-rooting, and pruning an IQ-TREE tree | Tree terms, Newick, the tree viewport |
| 03-reads/01-importing-fastq | Importing FASTQ files or an unmapped ONT BAM, pairing, sample sheets, sample metadata | Pairing rules, processing recipes, sample metadata |
| 03-reads/02-downloading-from-sra | Downloading an SRA run as a read bundle | SRA accessions, ENA and Toolkit fallback |
| 03-reads/03-quality-control | Reading a FASTQ bundle's summary cards, charts, and Reads tab | FASTQ viewport, summary cards, sparklines |
| 03-reads/04-trimming-and-filtering | The six Trimming and Filtering operations | Read-level primer trimming, length filtering |
| 03-reads/05-decontamination | The five Decontamination operations | Host, rRNA, contaminant, entropy, and duplicate removal at read level |
| 03-reads/06-subsetting-and-extraction | The five Search and Subsetting operations | Virtual bundles and materialization |
| 03-reads/07-ont-runs | Importing an ONT run folder and demultiplexing | Barcodes, barcode kits, barcode scout |
| 03-reads/08-read-processing | The six Read Processing operations plus interleave and deinterleave | Read merging, insert size, orientation |
| 04-alignments/01-mapping-reads-to-a-reference | Running a mapper and reading the alignment statistics | Mapper choice, presets, read groups, Est. Coverage, Flag Statistics |
| 04-alignments/02-reading-an-alignment | Reading the alignment viewport, its View Settings, and region extraction | Coverage curve, read display budget, Inspector Analysis tabs |
| 04-alignments/03-primer-trimming | Primer-trimming a mapped alignment with iVar | Alignment-level primer trimming, trim rate |
| 04-alignments/04-alignment-quality | Marking duplicates, filtering an alignment, exporting a deduplicated bundle | Duplicate marking, duplicate rate |
| 04-alignments/05-viral-recon-wizard | Running nf-core/viralrecon on SARS-CoV-2 amplicon reads | The Viral Recon wizard |
| 05-variants/01-calling-variants-from-amplicons | Running bcftools, LoFreq, and iVar from the Call Variants dialog | Caller choice, the Call Variants dialog |
| 05-variants/02-reading-the-variant-browser | The Variants tab and exporting rows with variants query | Table drawer, chips, Search Builder, caller comparison |
| 05-variants/04-nanopore-variant-calling | Calling ONT variants with Medaka or Clair3 | Model choice for ONT callers |
| 05-variants/05-consensus-and-lineage | Extracting a consensus sequence from an alignment | Consensus sequence, N masking |
| 05-variants/06-importing-existing-vcfs | Importing an existing VCF onto a bundle or as a variant-only bundle | VCF import paths |
| 06-classification/01-what-is-classification | What classification answers and which classifier to pick | Taxon, rank, lowest common ancestor, runnable versus imported tools |
| 06-classification/02-running-kraken2 | Running Kraken 2 with Bracken and reading the taxonomy viewport | k-mers and minimizers, taxonomy viewport, read extraction by taxon |
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
| 09-genotyping/01-what-is-mhc-genotyping | What MHC genotyping answers and which workflow to use | Allele, locus, haplotype, allele naming, retained reads |
| 09-genotyping/02-running-genotyping | Running the two MHC genotyping workflows | Genotyping dialogs, bbmerge and DRB merging |
| 09-genotyping/03-reading-the-genotype-comparison | Reading and annotating the genotype matrix | Support status, percent basis, matrix filters |
| 09-genotyping/04-haplotype-definitions-and-export | Exporting genotype results to Excel, CSV, TSV, and LabKey | Genotype export |
| appendices/cli-reference | Syntax and flags of every lungfish-cli command | Finding the program, every flag list |
| appendices/file-formats | Structure of every file and bundle format | Bundle layouts, provenance sidecar schema, coordinate conventions |
| appendices/keyboard-shortcuts | Every keyboard shortcut | Shortcut notation |
| appendices/power-user-notes | Exact tool arguments and the limits on repeating a run | Wrapped-tool argument lists |
| appendices/primer-schemes | The primer scheme bundle format and the shipped schemes | Shipped scheme catalogue |
| appendices/shared-projects | Project locks, read-only state, and bundle migration | Project locks |
| appendices/tool-versions | Pinned versions of every tool, pipeline, and database | Version tables |
| appendices/bibliography | Citing the tools a run used and citing LGE | Citations |
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
`build/mkdocs.yml`. The manual has three parts.

| Part | Folders | Role |
|---|---|---|
| I. Foundations | `01-foundations/` | Short concept and format primers that every Part II chapter assumes. |
| II. Working with the app | `02-sequences/` through `09-genotyping/` | One folder per workflow domain. `06-classification/` and `06-human-germline-variants/` share a prefix by design. |
| III. Reference | `appendices/` | Look-up material, including the CLI reference, file formats, tool versions, and troubleshooting. |

## Prerequisite graph

Chapters declare their prerequisites in frontmatter `prereqs`. The graph
drawn for the original pilot, `05-variants/01`, is kept as the worked
example.

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

## Resolved planning decisions (2026-05-09)

| Decision | Detail |
|---|---|
| Foundations as short standalone pages | Web-first presentation favours short pages with stable anchors other chapters can deep-link to. Each foundations page takes 5 to 10 minutes and ends with a next pointer, and the PDF build assembles them in order. |
| Schematic illustrations | Foundations chapters carry `<!-- ILLUSTRATION: id -->` markers paired with `illustrations.yaml`, which records the brief, palette, and size. Illustrations live in `assets/illustrations-imagegen/`. |
| Tool-choice tables are Markdown tables | Three columns, "If your data is", "Use", and "Why", which render in both the web and PDF builds. |
