---
title: The Viral Recon Wizard
chapter_id: 04-alignments/05-viral-recon-wizard
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 01-foundations/07-plugin-packs, 03-reads/02-downloading-from-sra, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming]
estimated_reading_min: 15
task: Run the nf-core/viralrecon pipeline from a four-control wizard so one SARS-CoV-2 amplicon sample yields an alignment, variant calls, a consensus genome, and lineage assignments in one pass.
tags: [alignments, workflows, viralrecon, nf-core, nextflow, amplicon, consensus, sars-cov-2]
tools: [nextflow, nf-core/viralrecon, bowtie2, ivar, bcftools, pangolin, nextclade]
parameters_refs: [workflow.viral-recon]
entry_points:
  - "Tools > Mapping > Viral Recon..."
  - "CLI: lungfish-cli workflow run nf-core/viralrecon"
shots:
  - id: viral-recon-menu-item
    caption: "The open Tools > Mapping submenu, with Viral Recon... as its fifth item below minimap2, BWA-MEM2, Bowtie2, and BBMap."
  - id: viral-recon-wizard-overview
    caption: "The Viral Recon sheet, showing the Viral Recon header and its Docker Desktop note above the Inputs, Primer Scheme, Minimum mapped reads, collapsed Advanced, and Readiness sections."
  - id: viral-recon-advanced-open
    caption: "The Advanced disclosure expanded, showing the annotation note, the Choose GFF... button, and the Extra parameters field with its schema-checking caption."
  - id: viral-recon-inspector-outputs
    caption: "The Inspector after a finished run, headed by the sample name and listing the Consensus, Lineage, and Quality sections with one row per output file."
illustrations:
  - id: viral-recon-flow
    brief: "A left-to-right pipeline flow on a Cream background. Boxes in order, joined by Deep Ink arrows, read 'FASTQ reads', 'Bowtie2 maps', 'iVar trims primers', 'iVar calls variants (AF 0.25 or more)', 'bcftools writes the consensus (AF 0.75 or more, depth under 10 masked as N)', then two boxes side by side, 'Pangolin lineage' and 'Nextclade clade'. Under each output a small Lungfish Creamsicle tag names where it appears in LGE, 'Viral Recon Alignment track', '<sample> Variants track and the Variants tab', 'Consensus section of the Inspector', 'Lineage section of the Inspector'. IBM Plex Mono for the tool names."

glossary_refs: [alignment-track, amplicon, amplicon-dropout, bam, checksum, consensus-fasta, container, coverage-breadth, depth, docker, inspector, ivar, lineage, mosdepth, multiqc, nextflow, nf-core, operations-panel, paired-end, pipeline, primer-scheme, provenance, reference-bundle, required-setup-pack, run-bundle, sample-sheet, shotgun, table-drawer, vcf]
features_refs: [align.viral-recon]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

A [pipeline](../../GLOSSARY.md#pipeline) is a fixed chain of analysis steps that runs from start to finish without stopping to ask you anything. You supply reads at one end and collect an alignment, a list of variants, a consensus genome, and quality reports at the other. This chapter covers the Viral Recon wizard in Lungfish Genome Explorer (LGE), which runs one such pipeline on SARS-CoV-2 amplicon reads.

The pipeline is [nf-core/viralrecon](../../GLOSSARY.md#nf-core), an openly published workflow that rebuilds a virus's genome sequence from reads compared against a known reference. nf-core is a community that curates pipelines written in [Nextflow](../../GLOSSARY.md#nextflow), a language for describing analysis steps and the files passed between them. LGE pins release 3.0.0 of the pipeline, meaning it always runs that exact version, so the same reads give the same answer months apart.

Five programs do the main work inside the pipeline, and each owns one step.

| Program | What it contributes |
|---|---|
| Bowtie2 | Places each read where it best matches the reference |
| [iVar](../../GLOSSARY.md#ivar) | Cuts primer bases off the read ends, then calls the variant positions |
| BCFtools | Writes the [consensus genome](../../GLOSSARY.md#consensus-fasta), the sample's own sequence with its variants applied |
| Pangolin | Assigns the consensus a SARS-CoV-2 [lineage](../../GLOSSARY.md#lineage) name |
| Nextclade | Assigns the same consensus a clade, a branch of the virus family tree, under a second naming system |

<!-- ILLUSTRATION: viral-recon-flow -->

The wizard asks for a primer scheme and a minimum read count, keeps two more options under Advanced, shows a Platform control only when it cannot tell the machine, and settles everything else for you. It reads the sequencing platform from the read bundle, writes the [sample sheet](../../GLOSSARY.md#sample-sheet) that tells the pipeline which read files belong to which sample, fetches the reference genome, and stages the primer files. When the run finishes, LGE copies the outputs into your project and adds the alignment and the variants as tracks over one [reference bundle](../../GLOSSARY.md#reference-bundle). A track is one layer of data drawn along a genome.

The wizard handles one virus and one library design. The reference is always the Wuhan-Hu-1 genome `MN908947.3`, the GenBank record SARS-CoV-2 results are reported against, so the pane has no reference control. The trailing `.3` is the version of that record. An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome. The examples here are SARS-CoV-2 because the pipeline is viral by design and the wizard accepts no other organism.

So use the wizard when your sample is SARS-CoV-2 amplicon material and you want the standard analysis in one pass, and use the separate mapping, primer-trimming, and variant-calling chapters for any other virus or for a shotgun library.

## Why you would do this

Running each step by hand teaches you what it does, and this part has taken that route with this same run. [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) placed the reads, [Primer Trimming an Alignment](03-primer-trimming.md) trimmed them, and [Call the trimmed amplicon track with iVar](../05-variants/01-calling-variants-from-amplicons.md#call-the-trimmed-amplicon-track-with-ivar) calls them. A pipeline offers something else, which is sameness from one sample to the next.

Consider a laboratory sequencing twenty SARS-CoV-2 samples a week for public-health surveillance. The comparison that matters is between samples. If sample 7 was mapped with different settings from sample 12, a difference between their consensus genomes could be biology or could be the settings, and nothing tells you which. A pipeline puts every sample through identical steps with identical parameters, so a difference in the output reflects a difference in the sample.

The pipeline also writes outputs you would probably not build by hand. [Amplicon dropout](../../GLOSSARY.md#amplicon-dropout) happens when one amplicon fails to amplify, so no reads cover that stretch of the genome and the variant caller reports nothing there. On screen, a stretch with no reads looks the same as a stretch that matched the reference perfectly. The per-amplicon coverage table is what tells the two apart. The consensus also arrives with a Pangolin lineage and a Nextclade clade, which is the form surveillance databases expect.

This chapter's example is SRR36291587, a public SARS-CoV-2 run prepared with the QIAseq Direct amplicon kit and sequenced on an Illumina machine. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. This run holds 85,199 read pairs.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` under `Imports`, so the SRA download below is done. To fetch the reads yourself instead, follow the rest of this section.

This chapter uses the sarscov2-srr36291587 fixture. Its reads are not stored on GitHub, so download them into your project from the SRA as accession `SRR36291587`, as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows. [The sarscov2-srr36291587 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587) holds only the `MN908947.3` reference, its GFF3 annotation, and expected variant files, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. You do not need to download them here, because the wizard fetches its own reference.

This pipeline runs its tools in containers, so Docker Desktop must be installed and running for the whole analysis, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains.

Nextflow arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE.

The first run downloads two things over the internet. LGE fetches the `MN908947.3` reference into the project's `Downloads` folder if the project does not already hold it, and Nextflow pulls the pipeline and its container images. Both are kept afterwards, so later runs skip them. Expect a first run on a laptop to take tens of minutes, most of it spent downloading containers. Later runs are faster.

## Procedure

### Opening the wizard

1. Click the SRR36291587 read bundle once in the sidebar to select it. The wizard takes the selected bundles as its input. With nothing selected, its Readiness line reads "Select at least one FASTQ bundle."

2. Choose **Tools > Mapping > Viral Recon...**. It sits among the mappers because it produces an alignment as they do. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

    <!-- SHOT: viral-recon-menu-item -->

3. Read the pane from the top. A heading reads Viral Recon, with the line "SARS-CoV-2 consensus and variant analysis from FASTQ bundles. Requires Docker Desktop." beneath it. Below sit the Inputs, Primer Scheme, and Minimum mapped reads sections, then a collapsed Advanced disclosure, then the Readiness line. A disclosure is a section that stays closed until you click its triangle.

    <!-- SHOT: viral-recon-wizard-overview -->

### Filling in the controls

1. Check the **Inputs** section. One selected bundle shows its path inside the project, and several show a count such as "3 FASTQ bundles selected." A line beneath reads `Platform: Illumina` or `Platform: Oxford Nanopore`, taken from the bundle's own record of the machine. A **Platform** control appears here only when that record is missing. Selecting Illumina and Nanopore bundles together is refused with a message asking you to split the run by platform. For each Illumina bundle a caption says how its reads reach the pipeline. The SRR36291587 bundle stores each read pair as two neighbouring records in one file, which is called an [interleaved](../../GLOSSARY.md#interleaved-fastq) file, so its caption reads that the interleaved pairs will be split into R1/R2 and run paired-end. LGE does that split inside the run and hands the pipeline the two files it expects, `fastq_1` and `fastq_2`. A bundle that mixes merged single reads with pairs runs single-end instead, and its caption turns into a warning saying so.

2. In the **Primer Scheme** section, open the **Scheme** menu and choose **QIAseq Direct SARS-CoV-2 with Booster A (Built-in)**, the kit this library was prepared with. The menu starts empty, reading "Choose a scheme…", with a caption asking for the scheme the amplicons were made with, and Run stays disabled until you pick one. LGE ships eight SARS-CoV-2 schemes, listed in [Shipped schemes](../appendices/primer-schemes.md#shipped-schemes). The menu marks them (Built-in) and adds any scheme in the project's own Primer Schemes folder, marked (Project). Under the menu a caption names the scheme's reference accession, its primer count, and its amplicon count. Compare those counts with your kit's documentation and with the Shipped schemes table, because a wrong scheme trims the wrong positions and nothing on screen warns you.

3. Leave **Minimum mapped reads** at 1000.

4. Leave **Advanced** collapsed. It holds a replacement annotation file and a field for extra pipeline parameters, and a standard run needs neither. The picture shows it opened so you can see what is inside.

    <!-- SHOT: viral-recon-advanced-open -->

5. Read the **Readiness** line. When everything is set it reads "Ready to run Viral Recon." and Run is enabled. When something is missing it names only the first problem, working through inputs, platform, scheme, minimum mapped reads, and extra parameters in that order, so a second message can appear after you fix the first.

### Watching the run

Click **Run**. LGE first writes a run bundle named `viralrecon.lungfishrun` into the project's `Analyses/` folder, and a repeat run gets `viralrecon-2.lungfishrun`. A [run bundle](../../GLOSSARY.md#run-bundle) records the run before it starts, as [Running External Workflows](../08-workflows/03-running-external-workflows.md#reading-the-results) explains. This one holds the sample sheet, the staged primer files, and every parameter the wizard passed.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled Viral Recon. Its detail line names the platform, the sample count, and the reference, then reports whether the reference was downloaded or found in the project. Click the row's **Log** button to read the pipeline's own messages as they arrive. To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it.

Keep LGE open and the Mac awake until the row finishes. The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. For this wizard that folder is `viralrecon-<timestamp>`. A run over several samples writes one `viralrecon-batch-<timestamp>` folder instead, with one subfolder per sample.

## Settings

The pane has five settings. Scheme and Minimum mapped reads sit in plain view, Platform appears only when the bundles do not record their machine, and Annotation and Extra parameters live inside the Advanced disclosure.

**Platform.** Tells the pipeline which kind of sequencing machine produced the reads, because short paired Illumina reads and long Nanopore reads pass through different steps. The default is Illumina, and the control appears only when the selected bundles do not record their own platform, so most runs never show it. Set it by hand when the Inputs section says it could not detect an Illumina or Oxford Nanopore platform, which happens when reads were copied out of their bundle and lost that record. On the command line this is `--param platform=illumina` or `--param platform=nanopore`.

**Scheme.** Sits in the Primer Scheme section and names the set of PCR primers that amplified the virus, so the pipeline knows where each amplicon starts and ends and can cut the primer bases off the reads. There is no default. The menu reads "Choose a scheme…" until you pick one, and the Readiness line reads "Select a SARS-CoV-2 primer scheme." meanwhile. Pick the scheme your kit used on every run, because primer bases are copies of the primer rather than of the sample, and a wrong scheme leaves them in place to fake variant calls at the amplicon edges. On the command line this is `--param primer_bed=<path>`, together with `--param primer_left_suffix` and `--param primer_right_suffix`.

**Minimum mapped reads:.** Sets how many reads must align to the SARS-CoV-2 genome before a sample is analysed, and a sample with fewer is dropped rather than given a consensus built on too little evidence. The default is 1000, and the arrows beside the number move it in steps of 100 between 1 and 1,000,000. Lower it for low-titre samples, meaning samples carrying very little virus, when a partial consensus is still useful, and raise it when you would rather have no result than one full of unknown bases. On the command line this is `--param min_mapped_reads`.

**Annotation.** Points the run at a GFF3 file, a gene annotation listing where each gene sits on the genome, so variants are reported against named genes. The default is none, because the reference LGE downloads already carries its own GFF3 annotation, as the note above the **Choose GFF...** button says. Choose a file only when you hold a curated annotation that differs from the reference's own, and click **Clear** to return to the default. On the command line this is `--param gff`.

**Extra parameters.** Passes further viralrecon parameters to the pipeline, each written as two dashes, the name, a space, and the value, so `--variant_caller bcftools --skip_fastqc true` sets two. The default is empty, and each name is checked against the pipeline's own parameter list before the run starts, so a misspelling is refused at the pane rather than minutes into the run. Use it for a pipeline option the pane does not show, after reading the published list at https://nf-co.re/viralrecon/3.0.0/parameters. On the command line this is `--param`.

The field refuses every parameter the wizard sets from its own controls, among them `input`, `outdir`, `platform`, `protocol`, `genome`, `fasta`, `gff`, and the four `primer_` parameters, with a message saying the wizard sets it. It also refuses `skip_freyja` and `skip_freyja_boot`, because the pipeline pins Freyja to a container built for Intel processors whose bootstrap step fails on Apple Silicon Macs. Assembly and Kraken 2 are skipped by default, and `--skip_assembly false` or `--skip_kraken2 false` turns them back on. The wizard also passes `max_cpus`, set to your Mac's core count up to 8, and `max_memory`, set to `8.GB`, and you may override both here. Before the first run has downloaded the pipeline there is no parameter list to check against, so only `variant_caller`, `consensus_caller`, `min_mapped_reads`, `max_cpus`, `max_memory`, and the skip parameters are accepted.

## Reading the results

A run leaves three items under `Analyses/`. The `viralrecon.lungfishrun` run bundle records how the run was set up, `viralrecon-results-<code>` is the pipeline's raw output, and `viralrecon-<timestamp>` is the result to open. Click the `viralrecon-<timestamp>` folder in the sidebar. The viewport opens the copy of the `MN908947.3` reference bundle inside it, with two tracks drawn along the same positions. A [BAM](../../GLOSSARY.md#bam) file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. The [alignment track](../../GLOSSARY.md#alignment-track), named Viral Recon Alignment, is the primer-trimmed BAM the variant caller read, so the reads you look at and the calls you read are the same evidence. For a batch run, click one sample's subfolder instead, since the batch folder itself shows only a prompt to pick a sample.

The second track holds the iVar variant calls and is named after the sample, ending in Variants. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#what-it-is) covers.

The rest of the run is catalogued in the [Inspector](../../GLOSSARY.md#inspector), headed by the sample name and a count of outputs. Files are grouped by what they answer rather than by the folder the pipeline wrote them to, with the most interpreted result first. A section appears only when it has files. Clicking a row opens that file in the Mac's default application for its type.

<!-- SHOT: viral-recon-inspector-outputs -->

| Section | Rows | What each row holds |
|---|---|---|
| Consensus | Consensus Sequence | The sample's own genome as a FASTA file |
| Lineage | Pangolin Lineage, Nextclade Clade | Two independent naming assignments for that genome |
| Quality | Run Quality Summary | One row per sample with read counts, coverage, and variant totals |
| Quality | Coverage Depth by Amplicon, Coverage Depth Across Genome | The [mosdepth](../../GLOSSARY.md#mosdepth) tables of read depth per amplicon and along the genome |
| Quality | Read Trimming Report, Full Run Report | The read-trimming page and the [MultiQC](../../GLOSSARY.md#multiqc) page combining every step, both opening in your web browser |

The result folder keeps its own copies of the consensus, lineage, and report files in `consensus/`, `lineage/`, and `reports/`, so the Inspector still works after the raw output is cleaned up. The pipeline's raw output tree stays untouched beside it in `Analyses/viralrecon-results-<code>/`.

The consensus in the Consensus section is a variants-applied consensus, the reference with the sample's confident changes written in. The pipeline writes a change into it only when at least three quarters of the reads carry it, and it masks as `N` every position with fewer than 10 reads, which is how dropout shows up in the sequence. [Pileup consensus versus variants-applied consensus](../05-variants/05-consensus-and-lineage.md#pileup-consensus-versus-variants-applied-consensus) sets this kind beside the pileup consensus LGE's Consensus tab builds.

## Reading the lineage calls

A [lineage](../../GLOSSARY.md#lineage) is a named subgroup within a viral species, defined by a characteristic set of variants. Two naming systems label SARS-CoV-2 genomes, and the pipeline runs one program for each on the consensus. Neither reads the reads. Each compares the consensus with its own reference tree of named genomes and reports the branch it fits best, so a consensus full of `N` gives a vaguer or failed call.

Pangolin names Pango lineages. A Pango name is letters followed by numbers joined by dots, and each dot is one step down the family tree, so `BQ.1.23` is a branch inside `BQ.1`. Long chains are shortened to a new letter pair, an alias, so `BQ.1` stands for a branch several steps down inside Omicron's BA.5. Nextclade names Nextstrain clades, coarser groups written as a year and a letter with a common name in brackets, such as `22E (Omicron)`, which is the clade that holds BQ.1. Nextclade also reports a Pango name of its own and quality flags for the consensus, such as missing data and frameshifts.

LGE lists both reports in the Inspector's Lineage section and opens them in the Mac's default application for a comma-separated file, such as Numbers or Excel. It does not read the lineage out of them for you. In Pangolin's file, `<sample>.pangolin.csv`, read the `lineage` column for the call, `qc_status` for whether Pangolin trusted the consensus, and `note` for how the call was made. In Nextclade's file, which sits in the same section, read `clade` for the Nextstrain clade, `Nextclade_pango` for its own Pango name, and `qc.overallStatus` for its quality verdict. Nextclade writes these files with semicolons between the columns, so choose semicolon as the separator if the spreadsheet puts each row in one cell.

Trust a lineage call as far as three checks allow. The two tools should agree at the level of the larger branch, such as Omicron BA.5 descendants, even when their finest labels differ. Both quality verdicts should be good. And the call should fit what else you know about the sample, such as its collection date. For this run expect both tools to place the genome in Omicron. EsViritu's closest match for these reads is an Omicron BQ.1.23 genome, `OP400692.1`, as [Running EsViritu](../06-classification/03-running-esviritu.md#the-reference-run) shows. That match names only the nearest known genome, so any Omicron call from Pangolin and Nextclade agrees with it. Lineage definitions are revised as new genomes arrive, so record the tool and data versions with every call. Pangolin's report carries its own in its version columns, and the run's provenance names the pipeline release that pinned both tools. A sample holding a mixture of lineages, such as wastewater, needs [Running Freyja](../06-classification/07-running-freyja.md) instead, because one consensus can name only one lineage.

## What good looks like

Work through three checks in order. A failure at one makes the checks after it meaningless.

First, confirm the sample was kept. A sample with fewer mapped reads than Minimum mapped reads produces no consensus, so an empty or missing Consensus section usually means the pipeline set the sample aside on purpose. Run Quality Summary shows how many reads mapped.

Second, read the per-amplicon coverage. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Every amplicon should carry reads. An amplicon at or near zero depth is dropout, and the stretch under it has no evidence either way, so an absence of variant calls there means nothing. No fixed cut-off applies, so compare each amplicon with the others in the same run and treat one far below its neighbours as suspect. Dropout is common in surveillance material and is not by itself a reason to discard a sample, but it limits what you can say about that region.

Third, read the lineage calls as [Reading the lineage calls](#reading-the-lineage-calls) describes. The pipeline's own Freyja step, which estimates a mix of lineages in one sample, is always skipped here, and LGE runs Freyja separately as [Running Freyja](../06-classification/07-running-freyja.md) explains. The run's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads, holds every parameter the wizard passed.

## Comparing with the manual route

This part took SRR36291587 through the same steps by hand, and setting the two results side by side shows what the pipeline decided for you. The table compares them.

| Step | By hand in this manual | In Viral Recon |
|---|---|---|
| Mapping | minimap2 with the Short-read preset | Bowtie2 in its local, very sensitive mode, which also soft-clips read ends that do not fit |
| Primer trim | `ivar trim` with the QIAseq Direct scheme, the scheme you chose | `ivar trim` with the scheme you chose |
| Variant calls | iVar at LGE's Minimum Allele Frequency of 0.05 and Minimum Depth of 10 | iVar at 0.25 and 10 |
| Consensus | [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md), from the pileup | bcftools, changes at 0.75 or more written into the reference, depth under 10 masked |

The variant threshold is the difference you will see first. On the hand-called track, 81 of the 93 rows sit at an allele frequency of 0.8 or more, one sits at 0.50 at position 27,415, and 11 fall below 0.2, as [Call the trimmed amplicon track with iVar](../05-variants/01-calling-variants-from-amplicons.md#call-the-trimmed-amplicon-track-with-ivar) reports. The pipeline leaves out every change carried by fewer than a quarter of the reads, so expect its Variants table to hold the fixed changes and few or none of those eleven. Neither is wrong. The pipeline is built to report the genome's consensus changes, and the hand route at 0.05 is built to show minority changes too. Positions where the two disagree beyond that threshold are where the mappers placed reads differently, usually next to an insertion or deletion, and the alignment viewport shows which placement the reads support.

To compare call by call, open the pipeline's `<sample> Variants` track and your own iVar track one after the other and sort each by `Position` in the Variants table, as [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md) shows.

## On the command line

The block below repeats the procedure, reusing the sample sheet and primer files the wizard staged in its run bundle, and it follows the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Every flag of `workflow run` is listed in [Workflows](../appendices/cli-reference.md#workflows) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/SARS-CoV-2 Amplicons.lungfish"
RUN="$PROJECT/Analyses/viralrecon.lungfishrun"

lungfish-cli workflow run nf-core/viralrecon \
  --executor docker \
  --version 3.0.0 \
  --input "$RUN/inputs/samplesheet.csv" \
  --results-dir "$PROJECT/Analyses/viralrecon-results-cli" \
  --expected-output "$PROJECT/Analyses/viralrecon-results-cli" \
  --bundle-root "$PROJECT/Analyses" \
  --param platform=illumina \
  --param protocol=amplicon \
  --param genome=MN908947.3 \
  --param primer_bed="$RUN/inputs/primers/primers.bed" \
  --param primer_fasta="$RUN/inputs/primers/primers.fasta" \
  --param primer_left_suffix=_LEFT \
  --param primer_right_suffix=_RIGHT \
  --param variant_caller=ivar \
  --param consensus_caller=bcftools \
  --param min_mapped_reads=1000 \
  --param skip_assembly=true \
  --param skip_kraken2=true \
  --cpus 8 \
  --memory 8.GB
```

Two differences change what you get. The wizard hands the pipeline its own downloaded copy of the reference with `--param fasta=` and `--param gff=`, where the block names the genome with `--param genome=`. The command also stops at the raw output tree and the run bundle, because only the app builds the viewable result folder with its tracks and Inspector catalogue. Instead of a samplesheet, `--input` also takes the `.lungfishfastq` bundle itself, as in `--input "$PROJECT/Imports/SRR36291587.lungfishfastq"`, and the command then builds the samplesheet the wizard would build, splitting interleaved pairs the same way and recording the decision in the run bundle's `inputs/read-pairing.json`. On a Mac with fewer than eight cores, set `--cpus` to your core count.

## Next

This is the last chapter in Alignments. Continue to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), the first chapter of Variants, which calls both routes' alignments by hand, the HG002 shotgun track with bcftools and LoFreq and this run's primer-trimmed track with iVar, and shows what each caller assumes about your sample.
