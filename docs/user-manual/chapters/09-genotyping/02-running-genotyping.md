---
title: Running Amplicon MHC Genotyping
chapter_id: 09-genotyping/02-running-genotyping
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 03-reads/01-importing-fastq, 01-foundations/07-plugin-packs]
estimated_reading_min: 17
task: Genotype macaque MHC amplicon samples against an allele library, assign MCM haplotypes from a definition set, and produce a genotype result bundle.
tags: [genotyping, mhc, amplicon, miseq, ont, macaque, haplotype, savont]
tools: [minimap2, samtools, bbmerge, savont]
parameters_refs: [genotype.miseq-amplicon, genotype.full-length-ont]
entry_points:
  - "Tools > Genotyping > miSeq amplicon MHC genotyping..."
  - "Tools > Genotyping > Full-length ONT MHC genotyping..."
  - "Tools > Haplotype Definitions..."
  - "CLI: lungfish-cli fastq genotype-cohort"
  - "CLI: lungfish-cli fastq genotype"
  - "CLI: lungfish-cli fastq full-length-ont-mhc-genotype"
  - "CLI: lungfish-cli haplotypes"
shots:
  - id: genotyping-run-dialog
    caption: "The Workflow Operations dialog on miSeq amplicon MHC genotyping, showing the Reference group with its Project Reference menu, the FASTQ Bundles group, the Report group with Report Name, and the Run Parameters group with Threads and Minimum supporting reads above the read-only mode caption."
  - id: genotyping-analysis-mode
    caption: "The dialog's Haplotyping group with the Analysis Mode segmented picker set to Deterministic haplotyping, and the Haplotype Definition group reading Definitions supplied by the selected reference bundle."
  - id: genotyping-advanced-options
    caption: "The dialog's Advanced Options disclosure expanded on the miSeq workflow, showing the minimap2 arguments field and the Keep Intermediates checkbox above the Directory group."
  - id: genotyping-full-length-dialog
    caption: "The Workflow Operations dialog on Full-length ONT MHC genotyping, showing the Length Filter group with Min Length and Max Length, the Call Thresholds group with its Locus % field, the Haplotype Definition group, and the Advanced Options disclosure holding Orient Reference, Forward Primers, and Reverse Primers."
illustrations: []
glossary_refs: [adapter, allele, allele-target, amplicon, bam, bbmerge, blast, bundle, cdna, clustering, cohort, consensus-sequence, fasta, fastq, genotype-result-bundle, haplotype, insert-size, ipd-mhc, json, locus, mcm, mhc, minimap2, miseq, nanopore-sequencing, operations-panel, paired-end, pbaa, plugin-pack, primer, provenance, read, read-merging, reference-bundle, retained-read, sample-depth, savont, wall-time, workflow-library]
features_refs: []
fixtures_refs: [mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

A genotyping run takes the sequencing reads from one or more animals, one read bundle per animal, and reports which catalogued [MHC](../../GLOSSARY.md#mhc) alleles each animal carries. Lungfish Genome Explorer (LGE) compares every [read](../../GLOSSARY.md#read) against an allele library, a file of known allele sequences, and counts which entries the reads match. Allele names follow the scheme [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. A [retained read](../../GLOSSARY.md#retained-read) matches an allele target end to end with no substitutions, the rule [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-counts-as-a-supporting-read) sets out.

The output is a [genotype result bundle](../../GLOSSARY.md#genotype-result-bundle), a `.lungfishgenotype` folder LGE shows as one item. It holds the counts as CSV tables, an Excel workbook, and a [BAM](../../GLOSSARY.md#bam) alignment file of the retained reads.

LGE offers two genotyping operations, and your sequencing platform decides which you use. The miSeq amplicon operation handles short amplicons, as Illumina [paired-end](../../GLOSSARY.md#paired-end) reads or as short Oxford Nanopore reads. The full-length ONT operation handles long Oxford [Nanopore](../../GLOSSARY.md#nanopore-sequencing) reads that span a whole allele, and it first groups near-identical reads into [consensus sequences](../../GLOSSARY.md#consensus-sequence), one cleaned-up sequence standing for each group. Both sit under **Tools > Genotyping** and write the same shape of result.

Either operation can also assign [haplotypes](../../GLOSSARY.md#haplotype) from the allele calls when you give it haplotype definitions, and this chapter's run does. A haplotype definition set is a small [JSON](../../GLOSSARY.md#json) file, structured text that lists, for each region, the haplotypes of one population and the diagnostic alleles that mark each one. [Where haplotype definitions come from](#where-haplotype-definitions-come-from) shows how a set reaches a project.

## Why you would do this

A colony is genotyped before a study starts, for the reasons [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this) gives. The ordinary scale of the work is one plate, one allele library, and one table at the end.

This chapter runs the MHC Genotyping demo project, two simulated [MCM](../../GLOSSARY.md#mcm) samples, A and B, against a three-allele library that carries an MCM haplotype definition set. The reads were generated error-free from the library, so every number the run reports can be checked against the truth, and the run finishes in seconds. The Williams MiSeq project described in [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this), 30 rhesus macaques matched against the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) Mamu library, supplies the "At scale" figures, the numbers a real plate gives.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the MHC Genotyping demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds everything the run needs, as the table lists.

| Item | Where it sits | What it is |
|---|---|---|
| `SIMULATED-MHC-A-pairs`, `SIMULATED-MHC-B-pairs` | `Imports/` | One read bundle per sample, each holding Illumina read pairs that were not merged at import |
| `SIMULATED-MHC-MCM-teaching.lungfishmhcref` | `Reference allele databases/` | The three-allele library with the MCM haplotype definitions built in |
| `SIMULATED-MHC-annotated-reference` | `Reference Sequences/` | The same three alleles as an ordinary reference bundle, with no definitions |
| `mhc-simulated-mcm-teaching.lungfishhaplotypedef.json` | `Haplotype Definitions/` | The definition set on its own |

The files come from the [mhc-simulated fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated), whose README records how the reads were generated and which public records the three alleles and their haplotypes come from, as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains.

The run needs two kinds of thing in any project. The first is one `.lungfishfastq` read bundle per animal, imported as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes. One bundle holds one animal's reads, and that rule is what keeps the samples apart. The second is the allele library, which the dialog calls the reference. It is a [FASTA](../../GLOSSARY.md#fasta) file with one entry per known allele sequence, and LGE also accepts it as a `.lungfishref` [reference bundle](../../GLOSSARY.md#reference-bundle) or as a `.lungfishmhcref` bundle, which carries haplotype definitions beside the sequences. In most laboratories the library already exists, so ask a colleague which file to use.

Install the `read-mapping` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The full-length ONT operation also needs the `full-length-mhc-genotyping` pack. Both genotyping items are specialized workflows, so turn the workflow on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows.

## Procedure

The procedure runs the miSeq amplicon workflow on the demo project with haplotyping on. [What changes on the full-length ONT route](#6-what-changes-on-the-full-length-ont-route) covers the other workflow.

### Select the samples you want to genotype

Click `SIMULATED-MHC-A-pairs` in the project sidebar, then Cmd-click `SIMULATED-MHC-B-pairs` to add it. Cmd-click adds one row to the selection and Shift-click extends it over a range. A plate is normally read as one [cohort](../../GLOSSARY.md#cohort), a set of samples genotyped and compared together, which gives one table with one column per animal.

When you select several bundles, the dialog's FASTQ Bundles group says they will run as one batch. That means one report, not pooled reads. Every sample keeps its own read counts and its own column.

### Open the dialog and set the reference

1. Choose **Tools > Genotyping > miSeq amplicon MHC genotyping...**. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, and it opens with this workflow selected.
2. In the **Reference** group, open the **Project Reference** menu, which lists the reference bundles LGE found in the project, and choose `SIMULATED-MHC-MCM-teaching.lungfishmhcref` under Reference allele databases. For a library outside the project, click **Choose…** beside the menu.
3. Check that the **FASTQ Bundles** group lists the two samples. Below it, **Report Name** arrives filled in as `amplicon-genotyping`. Change it to `simulated-mhc`, the name the later chapters use.

<!-- SHOT: genotyping-run-dialog -->

### Read the mode caption and leave the merge alone

Under **Threads** and **Minimum supporting reads** in the **Run Parameters** group sits a line of grey text. For the demo samples it reads **Illumina sample bundles**, and on a Nanopore plate it reads **ONT sample bundles**. The caption reports what LGE decided from the reads' own metadata, and the dialog has no control to change it. If it names the wrong platform, the platform recorded in the bundles when they were imported is wrong, so reimport those reads.

One step happens automatically here, and without it a whole locus goes quietly missing. Before mapping, LGE joins the two mates of each read pair into one longer fragment wherever they overlap, using [BBMerge](../../GLOSSARY.md#bbmerge). This is [read merging](../../GLOSSARY.md#read-merging). There is nothing to click, which is why the heading says to leave it alone. Reads imported with the Illumina Amplicon Merge recipe arrive already merged, and the run skips this step.

The reason is arithmetic. An Illumina run reads each DNA fragment from both ends, and each read is called a mate. The stretch between them is the [insert](../../GLOSSARY.md#insert-size). A 2x251 MiSeq kit reads up to 251 bases from each end, and once the primer and [adapter](../../GLOSSARY.md#adapter) bases, the synthetic sequence added in library preparation, are trimmed from its ends, one mate covers about 198 bases of the insert. That spans a 156-base class I amplicon but not a 244-base DRB amplicon. Because a read counts only when it covers its allele target end to end, every DRB allele would receive zero reads without merging. The demo's mates are 150 bases, shorter than all three of its targets, so without merging it would count nothing at all.

LGE reports the merge in the Operations Panel as it happens. On the demo run the message reads "2 of 2 Illumina inputs contain unmerged read pairs. Merging overlapping pairs before mapping so full-length amplicons (including the 244 bp DRB loci) can be genotyped." and goes on to suggest the import recipe. A recipe is a set of processing steps chosen when reads are imported, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md#settings) describes.

### Turn on Deterministic haplotyping

Below Run Parameters sits a group headed **Haplotyping** with an **Analysis Mode** picker of two segments, **Genotyping only** and **Deterministic haplotyping**. Click **Deterministic haplotyping**. Because the reference is a `.lungfishmhcref` bundle, the **Haplotype Definition** group that appears reads "Definitions supplied by the selected reference bundle." and needs no choice. With an ordinary reference bundle it shows **Assay**, **Species**, and **Definition** menus instead, which [Settings](#settings) describes. **Genotyping only** reports the alleles and their supporting reads without assigning haplotypes, which is all the Williams run did.

<!-- SHOT: genotyping-analysis-mode -->

Everything else already holds a sensible value. **Threads** arrives filled with your Mac's processor count. **Minimum supporting reads** starts at 1. The **Advanced Options** disclosure holds a minimap2 arguments field and a Keep Intermediates checkbox. The **Directory** group already points inside your project.

<!-- SHOT: genotyping-advanced-options -->

### Run it and watch the Operations Panel

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row's message moves through validating the inputs, resolving the reference and tools, merging the read pairs, and mapping with [minimap2](../../GLOSSARY.md#minimap2). It then filters the alignments down to the retained reads, applies the haplotype definition, and writes the summaries and the workbook. The demo run takes a few seconds.

When the row turns green, the result appears in the sidebar under `Analyses/Amplicon genotyping results/`. A failed run turns the row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it. A second run with the same report name lands beside the first as `simulated-mhc_1` rather than overwriting it. Click the `.lungfishgenotype` bundle to open it, as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) describes.

### Where haplotype definitions come from

The demo project's definitions arrive inside the `.lungfishmhcref` bundle, which is the form the dialog reads without asking. A definition set can also reach a project on its own, and the **Haplotype Definitions** window manages both kinds. Open it with **Tools > Haplotype Definitions...** or with the **Manage…** button in the dialog's Haplotype Definition group.

The window lists the definition sets held in the project's reference bundles, with columns for **Definition**, **Assay**, **Species**, **Source**, and **Status**. On the demo project it lists one set, "MCM haplotypes for the mhc-simulated reference (teaching set)", with the id `mhc-simulated-mcm-teaching`, the assay `SIMULATED-MHC-three-amplicon`, and the species `MCM`. Selecting a row shows its details, including the bundle and reference FASTA it belongs to and its loci, here MHC-A, MHC-DR, and MHC-DP. The toolbar's **Import** button brings in a definition file or a whole `.lungfishmhcref` bundle, **New** starts an empty definition, and **Export** writes the selected set to a file. The detail pane's **Edit** button opens a definition for changes.

Each region's entry in the set names its haplotypes and the diagnostic alleles that mark each one. The teaching set gives each region one haplotype, taken from the `/haplotype` field of the public ENA record each allele was deposited under.

| Region | Haplotype | Diagnostic allele | Public record |
|---|---|---|---|
| MHC-A | M4 | `Mafa-G_02:31:01:01` | OR823640 |
| MHC-DR | M7 | `Mafa-DRB_W001:03:01:01` | OR823568 |
| MHC-DP | M1 | `Mafa-DPA1_07:02:01:01` | OR823525 |

The G gene sits in the MHC-A region, beside the A genes, which is why the Mafa-G allele marks an MHC-A haplotype. One haplotype per region is a teaching size. A real MCM definition set lists all seven haplotypes, M1 to M7, in each region, with several diagnostic alleles each, which is what lets the caller tell two haplotypes on two chromosome copies apart.


### What changes on the full-length ONT route {#6-what-changes-on-the-full-length-ont-route}

Choose **Tools > Genotyping > Full-length ONT MHC genotyping...** when your reads are long Nanopore reads that each span a whole allele. The Reference, FASTQ Bundles, Report Name, Threads, and Directory groups work as in the procedure above. Four things differ.

First, reads are clustered before anything is compared to the library. [Clustering](../../GLOSSARY.md#clustering) groups near-identical reads and derives one consensus sequence from each group, and the consensus sequences are what get genotyped. Nanopore reads carry a higher per-base error rate than Illumina reads, so a true allele matched read by read would scatter into near-misses. LGE always clusters with [Savont](../../GLOSSARY.md#savont) on this route. [pbAA](../../GLOSSARY.md#pbaa), another clustering program, is a separate operation whose saved output this workflow can reuse.

Second, a **Length Filter** group holds **Min Length** and **Max Length**, which start at 2000 and 4000 bases and suit a full-length MHC amplicon of roughly 3,000 bases.

Third, a **Call Thresholds** group holds **Locus %**, and a **Haplotype Definition** group is always shown. Both matter only when you pick a definition. Leave the Definition menu on No haplotyping for genotyping only.

<!-- SHOT: genotyping-full-length-dialog -->

Fourth, the **Advanced Options** disclosure holds three optional file pickers, for an orientation reference and for forward and reverse primer sequences. LGE fills each one when it finds a suitable file in the project, so an empty field means it found none.

The full-length workflow does not discard a consensus that matches no library allele. It reports it in one of three ways. A consensus close to a library allele becomes a candidate allele named after its closest library relative. A name ending `_nov` marks one with substituted bases, and the number before it counts them, so `_2nt_nov` means two differences. A name ending `_ext` or `_partial_ext` marks a consensus that matches a shorter library record, such as one holding only the protein-coding part of the gene, and runs past its ends. A consensus that aligns too little, too loosely, or equally well to two loci is kept as unnameable rather than forced into a name. A consensus with no usable minimap2 match at all is searched against the library with [BLAST](../../GLOSSARY.md#blast), a sequence search program, and one whose best hit covers at least 70 percent of it, over at least 1,000 bases, at 75 percent identity or more, is reported with that closest allele as a BLAST rescue. The workbook's Unmatched Alleles sheet lists every unmatched consensus with its closest match, and the bundle keeps them as the FASTA files `candidate_alleles.fasta`, `unnameable_unmatched_clusters.fasta`, and `deduplicated_unmatched_clusters.fasta`.

## Settings

Each control is documented once, with a note of which workflow shows it. Every flag is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference.

**Reference.** Names the allele library every read is compared against, chosen from the **Project Reference** menu of reference bundles in the project, on both workflows. **Choose…**, which reads **Replace…** once a reference is set, picks a library from anywhere on disk, and **Clear** empties the choice. It arrives set to the first MHC reference found in the project, or to nothing when there is none, because an allele missing from this file can never be reported. Choose the library built for your species and panel, and on the full-length route a full-length library, since a short-amplicon library will not match reads that span a whole gene. On the command line this is `--reference`.

**FASTQ Bundles.** Chooses which samples the run genotypes, on both workflows. It arrives holding what you selected in the sidebar, and it accepts `.lungfishfastq` bundles, loose FASTQ files, or a folder of either. Select the whole plate for one comparison table, and run bundles one at a time for separate reports. This setting has no command-line flag, because the command line takes the inputs as bare arguments.

**Include subfolders.** Adds bundles nested inside further folders when you selected a folder, on both workflows. It is off by default, so a folder contributes only the bundles directly inside it. Turn it on when a sequencing run wrote each sample into its own subfolder. This setting has no command-line flag.

**Report Name.** Names the result bundle and the files inside it, on both workflows. On the miSeq route it starts as `amplicon-genotyping`. On the full-length route one input gives a name built from that file's name, and several inputs give `full-length-ont-mhc-genotyping`. Change it when the suggested name will not tell you later which plate the run covered. On the command line this is `--output-name`.

**Threads.** Sets how many processor cores the run uses at once, on both workflows. The default is your Mac's processor count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Minimum supporting reads.** Sets the fewest retained reads an allele needs before the haplotype caller counts it as evidence, on the miSeq workflow. It starts at 1, because an exact full-length match is strict enough that one read means something. It removes no rows from the report files or the workbook, which always list every retained allele, so it matters only with Deterministic haplotyping, where [Reading the results](#reading-the-results) shows it changing a call. On the command line this is `--min-support`.

**Analysis Mode.** Decides whether the run stops at allele calls or goes on to assign haplotypes, as a two-segment picker on the miSeq workflow. It starts on **Genotyping only**, which reports detected alleles and their supporting reads. **Deterministic haplotyping** also matches the diagnostic alleles to the haplotype definitions you choose. On the command line `--genotype-only` forces genotyping only, and `--haplotype-definition` names a definition set.

**Haplotype Definition.** Chooses the haplotype definitions the caller uses, with **Assay**, **Species**, and **Definition** menus and a **Manage…** button that opens the Haplotype Definitions window, which [Where haplotype definitions come from](#where-haplotype-definitions-come-from) describes. It appears on the miSeq workflow under Deterministic haplotyping and always on the full-length workflow, and when the reference is a `.lungfishmhcref` bundle it reads "Definitions supplied by the selected reference bundle." and needs no choice. The default is no definition, so no haplotypes are called. Pick one only when you want haplotype calls, which [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#haplotype-calls) explains. On the command line these are `--haplotype-assay`, `--haplotype-species`, and `--haplotype-definition`, and a `.lungfishmhcref` reference supplies its own definition unless `--genotype-only` is given.

**Locus %.** Sets the smallest share an allele must hold of the sample's retained reads at its own source locus before the haplotype caller uses it, on the full-length workflow. The default is 1 percent, which drops stray low-level hits without touching real alleles. Raise it when background clusters are producing extra haplotype matches. It applies only when a haplotype definition is chosen, and it is fixed into the result, unlike the display filters of the result window. On the command line this is `--haplotype-min-locus-percent`, whose default there is 0.

**minimap2 arguments.** Passes extra arguments to minimap2 after LGE's own mapping preset, on the miSeq workflow, inside **Advanced Options**. It starts empty, which is right for almost every run. Use it only for a minimap2 option you have read about in [the minimap2 documentation](https://lh3.github.io/minimap2/minimap2.html). On the command line this is `--extra-args`.

**Keep Intermediates.** Keeps the large working files a run produces instead of deleting them at the end, inside **Advanced Options** on both workflows. It is off by default, as the dialog's own caption recommends, because the merged reads and unfiltered alignments are large and can be regenerated. Turn it on only when a run gave an unexpected result and you want the files behind it. On the command line this is `--keep-intermediates`.

**Min Length.** Sets the shortest read, in bases, kept for clustering after primers are trimmed, on the full-length workflow. It starts at 2000, since shorter reads are usually fragments. Set it just below your amplicon's true length. On the command line this is `--min-length`.

**Max Length.** Sets the longest read, in bases, kept for clustering after primers are trimmed, on the full-length workflow. It starts at 4000, since longer reads are usually two amplicons joined end to end. Raise it when your amplicon is longer than 4000 bases. On the command line this is `--max-length`.

**Orient Reference.** Supplies a sequence used to turn every read the same way round before clustering, on the full-length workflow, inside **Advanced Options**. Nanopore reads arrive on either DNA strand, so without it clusters can split by strand. It arrives filled when LGE finds an orientation FASTA in the project, and empty otherwise. On the command line this is `--orient-reference`.

**Forward Primers.** Names the primer sequences trimmed from the start of each read, on the full-length workflow, inside **Advanced Options**, so primer bases are not mistaken for allele differences. It arrives filled when LGE finds a forward-primer FASTA in the project. Supply it when your reads still carry their PCR [primers](../../GLOSSARY.md#primer). On the command line this is `--forward-primer`.

**Reverse Primers.** Names the primer sequences trimmed from the end of each read, on the full-length workflow, and partners the setting above. It arrives filled when LGE finds a reverse-primer FASTA in the project. Supply it when your reads still carry their PCR primers. On the command line this is `--reverse-primer`.

**Directory.** Chooses where the result bundle is written, on both workflows. It points at `Analyses/Amplicon genotyping results` for the miSeq route and `Analyses/Full-length ONT MHC genotyping results` for the full-length route. Change it only when the result belongs outside the project. On the command line this is `--output-dir`.

## Reading the results

The run's own numbers tell you whether it worked before you look at one allele call. They live in the bundle's statistics file and the workbook. To reach them, right-click the bundle in the Finder and choose **Show Package Contents**.

### The demo run

Read the retained fraction first, the share of input reads that passed the end-to-end, zero-substitution test. The demo run reports 376 of 376 retained, 100 percent, and each sample 100 percent retained, 204 for A and 172 for B. The run merges the two mates of each pair into one fragment before matching, so it counts its input in fragments, one per pair, rather than in the 752 records the two mates made up. The Run Summary labels say so, reading **Total Fragments** and **Retained % of Fragments** on a run that merged pairs, and **Total Reads** and **Retained %** on one that did not. Compare retained fractions only between runs whose reads were merged the same way.

The run also reports why the other reads were dropped, as four counts of alignments, in `simulated-mhc.retained-demux-stats.json`. An alignment is one read placed against one allele target, so a read that landed on several targets counts several times. On the demo run only the passed count appears, 376, because the reads were generated from the library without errors and nothing was dropped. On real data the other three, unmapped, not spanning the target, and spanning it with a mismatch, carry most of the reads, as the Williams figures below show.

Each sample's retained reads spread across the three allele targets as the simulation intended.

| Allele target | Record | Locus | Sample A | Sample B |
|---|---|---|---|---|
| `Mafa-G_02:31:01:01` | OR823640 | MHC-G | 120 | 12 |
| `Mafa-DRB_W001:03:01:01` | OR823568 | MHC-DRB | 80 | 60 |
| `Mafa-DPA1_07:02:01:01` | OR823525 | MHC-DPA1 | 4 | 100 |

In the result each allele target's full name carries its record after a vertical bar, as in `Mafa-G_02:31:01:01|OR823640`, the public accession the allele came from.

The haplotype calls sit in `simulated-mhc.haplotype-analysis.json` and in the window's Haplotype Calls view. Both samples get the same three calls, M4 in the MHC-A region, M7 in MHC-DR, and M1 in MHC-DP, each written with a dash in the second slot and the status called. [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#haplotype-calls) explains the dash.

**Minimum supporting reads** is the one setting that changes these calls. Rerun with it at 5 and sample A's MHC-DP call becomes `ERR: NO HAP`, meaning no haplotype could be called, because A's only DP allele has 4 reads, below the new floor. Every other call stays the same, and the allele rows and counts do not change, because the setting affects only which alleles count as haplotype evidence.

### At scale, the Williams plate

The Williams plate shows what the same figures look like on 30 real animals. It retained 23.9 percent of 2,854,092 reads, 682,927 in all, and a reproduction on three of its samples gave 23.6 percent of 505,528. Two subsets of one plate agreeing within a third of a percent is what a stable assay looks like. On the whole plate 682,928 alignments passed, 224,134 were unmapped, 311,914 did not span their allele target end to end, and 296,843 spanned it with at least one mismatch. A large unmapped count points at off-target amplification, PCR copying something other than the intended gene, or at the wrong library. A large not-spanned count points at reads that are too short, which on a MiSeq plate usually means merging did not happen.

Samples produced between 2 and 117 allele rows each, 2,109 in all, for the reason [Duplicated genes and many rows per locus](01-what-is-mhc-genotyping.md#duplicated-genes-and-many-rows-per-locus) gives. The reproduction produced 104 rows for `WD1_S148_L001`, the same number the whole-plate run produced for that sample, which is what a deterministic run looks like. The 30-sample run took 329 seconds of [wall time](../../GLOSSARY.md#wall-time), real elapsed time, on the author's Apple Silicon Mac, and the three-sample reproduction 55 seconds, nearly all of it merging and mapping.

### The files in the bundle

The bundle holds these files, where `<name>` is the Report Name.

| File | What it holds |
|---|---|
| `<name>.retained-demux-genotypes.csv` | One row per sample and allele, with its read counts |
| `<name>.retained-demux-samples.csv` | One row per sample, with its retained read count and percentage |
| `<name>.retained-demux-stats.json` | The drop counts and the retained totals |
| `<name>.haplotype-analysis.json` | The haplotype calls, present only when the run carried haplotyping |
| `<name>.xlsx` | The workbook of genotype tables and run statistics |
| `<name>.retained.demuxed.bam` | The retained reads, sorted, with a `.bai` index beside it |

A full-length ONT run writes its per-allele table as `<name>.full-length-ont-mhc-genotypes.csv` instead. The bundle also keeps copies of some CSV files with underscores in place of hyphens, which hold the same tables.

Two columns in these tables mark calls that need a second look. When the allele library holds identical sequences, read in either direction, LGE maps against one representative of each group, the first in the file, and an `ambiguous_with` column lists every member of the group, separated by semicolons. On the full-length route the column also lists every reference that tied for a cluster's best hit. The full-length table adds `indel_bases`, the inserted plus deleted bases in the supporting hit, the largest among the clusters behind the call, and `review_flag`, which reads `indel` when that count is above zero. A full-length hit with no substitutions stays a known call even when it carries indels, because Nanopore reads often gain or lose a base by chance, and the flag marks the call so you can check it.

## What good looks like

Read the retained fraction against your own assay. Roughly a quarter of reads surviving is normal for a MiSeq panel like Williams, because the filter is strict and a real plate carries adapter dimers, two adapters stuck together with no sample DNA between them, and off-target product. Compare later runs against your own first one. A plate that suddenly retains 5 percent where the last one retained 24 has a laboratory problem or a library mismatch, and the four drop counts say which. A run where everything passes, like the demo, is expected only for simulated reads.

Check that every locus the panel covers is present. On the demo run each sample shows all three loci. On a real plate scan the allele names for DRB rows, such as `07_Mamu-DRB1_03_03_01_01`. A plate with plenty of class I calls and no DRB rows at all means the merge did not happen. Reimport the reads with the Illumina Amplicon Merge recipe and run again.

Check the [sample depth](../../GLOSSARY.md#sample-depth) of every sample before you read its calls, as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#qc-status) shows. The demo samples, with 204 and 172 retained reads, are deliberately thin.

Check every row whose `review_flag` reads `indel` and every row with an `ambiguous_with` list before you report those alleles. Then open the provenance record, which names the allele library the run used, the only place a wrong library shows, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every flag is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/MHC Genotyping.lungfish"

# miSeq amplicon genotyping with the bundled MCM definitions
lungfish-cli fastq genotype-cohort \
  "$PROJECT/Imports/SIMULATED-MHC-A-pairs.lungfishfastq" \
  "$PROJECT/Imports/SIMULATED-MHC-B-pairs.lungfishfastq" \
  --reference "$PROJECT/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref" \
  --project "$PROJECT" \
  --output-dir "$PROJECT/Analyses/Amplicon genotyping results/simulated-mhc.lungfishgenotype" \
  --output-name simulated-mhc \
  --min-support 1

# Full-length ONT genotyping of one sample of your own
lungfish-cli fastq full-length-ont-mhc-genotype \
  "$PROJECT/Imports/sample.lungfishfastq" \
  --reference "$PROJECT/Reference Sequences/mhc-full-length.lungfishref" \
  --output-dir "$PROJECT/Analyses/Full-length ONT MHC genotyping results/sample.lungfishgenotype" \
  --output-name sample \
  --min-length 2000 --max-length 4000
```

Pass `--output-dir` a path ending in `.lungfishgenotype`, because on the command line that folder is the result bundle itself, while the window's Directory is the folder that holds bundles. With `--project`, the output folder must sit inside the project, and a path outside it is refused before the run starts. A `.lungfishmhcref` reference supplies its haplotype definitions by itself, and `--genotype-only` turns that off. `fastq genotype-cohort` needs at least two `.lungfishfastq` bundles, while `fastq genotype` takes one sample, loose FASTQ files, or folders. On the full-length route the command line's `--haplotype-min-locus-percent` defaults to 0 where the window's Locus % starts at 1. The demo run took about two seconds from the command line.

## Next

Continue to [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) to open the bundle you just produced and read both its matrix and its haplotype calls.
