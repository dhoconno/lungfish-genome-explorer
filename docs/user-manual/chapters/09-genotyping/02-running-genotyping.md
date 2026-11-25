---
title: Running Amplicon MHC Genotyping
chapter_id: 09-genotyping/02-running-genotyping
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 03-reads/01-importing-fastq, 01-foundations/07-plugin-packs]
estimated_reading_min: 18
task: Genotype macaque MHC amplicon samples against an allele library, assign MCM haplotypes from a definition set, and produce a genotype result bundle.
tags: [genotyping, mhc, amplicon, miseq, ont, macaque, haplotype, savont]
tools: [minimap2, samtools, bbmerge, savont]
parameters_refs: [genotype.miseq-amplicon, genotype.full-length-ont]
entry_points:
  - "Tools > Genotyping > MiSeq Amplicon MHC Genotyping..."
  - "Tools > Genotyping > Full-Length ONT MHC Genotyping..."
  - "Tools > Genotyping > MHC Haplotype Definitions..."
  - "CLI: lungfish-cli fastq genotype-cohort"
  - "CLI: lungfish-cli fastq genotype"
  - "CLI: lungfish-cli fastq full-length-ont-mhc-genotype"
  - "CLI: lungfish-cli fastq ont-pacbio-barcode-demux"
  - "CLI: lungfish-cli fastq mhc-reference-bundle"
  - "CLI: lungfish-cli haplotypes"
shots:
  - id: genotyping-run-dialog
    caption: "The Workflow Operations dialog on MiSeq Amplicon MHC Genotyping with the two demo samples selected, showing the Reference and FASTQ Bundles groups under Inputs and the Report and Run Parameters groups under Primary settings."
  - id: genotyping-analysis-mode
    caption: "The dialog's Haplotyping group with the Analysis Mode picker set to Deterministic haplotyping and the Haplotype Definition group reading Definitions supplied by the selected reference bundle."
  - id: genotyping-advanced-options
    caption: "The Advanced Options disclosure of the MiSeq workflow expanded under Advanced settings, showing the minimap2 arguments field and the Keep Intermediates checkbox above the Directory group."
  - id: haplotype-definition-editor
    caption: "The Haplotype Definition editor on the demo definition set, with the loci listed at the left and the selected locus's haplotype card showing its associated alleles, their Diagnostic checkboxes, and the Require diagnostic alleles stepper."
  - id: genotyping-full-length-dialog
    caption: "The Workflow Operations dialog on Full-Length ONT MHC Genotyping, showing the Length Filter group with Min Length and Max Length, the Call Thresholds group with its Locus % field, the Haplotype Definition group, and the Advanced Options disclosure holding Orient Reference, Forward Primers, and Reverse Primers."
illustrations: []
glossary_refs: [adapter, allele, allele-target, amplicon, bam, bbmerge, blast, bundle, cdna, class-i-mhc, class-ii-mhc, clustering, cohort, consensus-sequence, exon, fasta, fastq, genotype-result-bundle, haplotype, insert-size, ipd-mhc, json, locus, materialization, mcm, mhc, minimap2, miseq, nanopore-sequencing, operations-panel, paired-end, pbaa, plugin-pack, primer, provenance, read, read-merging, reference-bundle, retained-read, sample-depth, savont, virtual-bundle, wall-time, workflow-library]
features_refs: [genotype.amplicon, genotype.full-length-ont-mhc, genotype.haplotype-definitions, genotype.mhc-reference-bundle, cluster.reads]
fixtures_refs: [mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

A genotyping run takes the sequencing reads from one or more animals, one read bundle per animal, and reports which catalogued [MHC](../../GLOSSARY.md#mhc) alleles each animal carries. Lungfish Genome Explorer (LGE) compares every [read](../../GLOSSARY.md#read) against an allele library, a file of known allele sequences, and counts which entries the reads match. Allele names follow the scheme [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. A [retained read](../../GLOSSARY.md#retained-read) matches an [allele target](../../GLOSSARY.md#allele-target), one entry of the allele library, from its first base to its last with no substituted base, the rule [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-counts-as-a-supporting-read) sets out.

The output is a [genotype result bundle](../../GLOSSARY.md#genotype-result-bundle), a `.lungfishgenotype` folder LGE shows as one item. It holds the counts as CSV tables, an Excel workbook, and a [BAM](../../GLOSSARY.md#bam) alignment file of the retained reads.

LGE offers two genotyping operations, and the length of your reads decides which you use. The MiSeq amplicon operation handles short amplicons, reads of a few hundred bases or less, as Illumina [paired-end](../../GLOSSARY.md#paired-end) reads or as short reads from Oxford Nanopore Technologies ([ONT](../../GLOSSARY.md#ont)). The full-length ONT operation handles long [Nanopore](../../GLOSSARY.md#nanopore-sequencing) reads, typically well over a thousand bases, that each span a whole allele, and it first groups near-identical reads into [consensus sequences](../../GLOSSARY.md#consensus-sequence), one cleaned-up sequence standing for each group. Both sit under **Tools > Genotyping** and write the same shape of result.

Either operation can also assign [haplotypes](../../GLOSSARY.md#haplotype) from the allele calls when you give it haplotype definitions, and this chapter's run does. A haplotype definition set is a small [JSON](../../GLOSSARY.md#json) file, structured text that lists, for each region, the haplotypes of one population and the diagnostic alleles that mark each one. [Where haplotype definitions come from](#where-haplotype-definitions-come-from) shows how a set reaches a project.

## Why you would do this

A colony is genotyped before a study starts, for the reasons [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this) gives. The ordinary scale of the work is one plate (the samples prepared together in one multi-well plate and sequenced together), one allele library, and one table at the end.

This chapter runs the MHC Genotyping demo project, two simulated [MCM](../../GLOSSARY.md#mcm) samples, A and B, against a three-allele library that carries an MCM haplotype definition set. The reads were generated error-free from the library, so every number the run reports can be checked against the truth, and the run finishes in seconds. The MHC MiSeq cohort project described in [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this), 30 rhesus macaques matched against the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) Mamu library, supplies the "At scale" figures, the numbers a real plate gives.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the MHC Genotyping demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds everything the run needs, as the table lists.

| Item | Where it sits | What it is |
|---|---|---|
| `SIMULATED-MHC-A-pairs`, `SIMULATED-MHC-B-pairs` | `Imports/` | One read bundle per sample, each holding Illumina read pairs that were not merged at import |
| `SIMULATED-MHC-MCM-teaching.lungfishmhcref` | `Reference allele databases/` | The three-allele library with the MCM haplotype definitions built in |
| `SIMULATED-MHC-annotated-reference` | `Reference Sequences/` | The same three alleles as an ordinary reference bundle, with no definitions |
| `mhc-simulated-mcm-teaching.lungfishhaplotypedef.json` | `Haplotype Definitions/` | The definition set on its own |

The files come from the [mhc-simulated fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated), whose README records how the reads were generated and which public records the three alleles and their haplotypes come from, as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains.

The run needs two kinds of thing in any project. The first is one `.lungfishfastq` read bundle per animal, imported as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes. One bundle holds one animal's reads, and that rule is what keeps the samples apart. The second is the allele library, which the dialog calls the reference. It is a [FASTA](../../GLOSSARY.md#fasta) file with one entry per known allele sequence, and LGE also accepts it as a `.lungfishref` [reference bundle](../../GLOSSARY.md#reference-bundle) or as a `.lungfishmhcref` bundle, which carries haplotype definitions beside the sequences. Click a `.lungfishmhcref` bundle in the sidebar and the Inspector names it an MHC Reference Bundle. The library comes from a database such as IPD-MHC, which [Maccari and colleagues 2017](https://doi.org/10.1093/nar/gkw1050) describe. In most laboratories a prepared one already exists, so ask a colleague which file to use and which IPD-MHC release built it. Any of the three forms genotypes alleles, and a `.lungfishmhcref` bundle is the one to prefer for haplotype calls, since the dialog then needs no further choice.

Install the `read-mapping` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, from **Tools > Plugin Manager…** (Cmd-Shift-B), as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. BBMerge and samtools come with the required Third-Party Tools pack. The full-length ONT operation also needs the `full-length-mhc-genotyping` pack, which supplies Savont and BLAST. MiSeq Amplicon MHC Genotyping is switched on from the start. Full-Length ONT MHC Genotyping is a specialized workflow, which you turn on once in the [Workflow Library](../../GLOSSARY.md#workflow-library) with **Tools > Workflows > Workflow Library…**, as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows, and until then its menu item reads **Enable Full-Length ONT MHC Genotyping…**.

## Procedure

The procedure runs the MiSeq amplicon workflow on the demo project with haplotyping on. [What changes on the full-length ONT route](#6-what-changes-on-the-full-length-ont-route) covers the other workflow.

### Select the samples you want to genotype

Click `SIMULATED-MHC-A-pairs` in the project sidebar, then Cmd-click `SIMULATED-MHC-B-pairs` to add it. Cmd-click adds one row to the selection and Shift-click extends it over a range. A plate is normally read as one [cohort](../../GLOSSARY.md#cohort), a set of samples genotyped and compared together, which gives one table with one column per animal.

Every sample keeps its own read counts and its own column. When you select several bundles, the dialog's **FASTQ Bundles** group shows a **Run Mode** choice. **Combine all inputs, run once (1 result)** is selected, and **Run separately per bundle (2 results)** is dimmed with the note "They will run as one batch." The selected choice's own note says the bundles are pooled into a single input, but for genotyping that means one report, not pooled reads. Each bundle is one sample named for the bundle, whatever files it holds, and every read of it is genotyped. In an Illumina run the name has each character other than a letter, digit, hyphen, or underscore turned into an underscore. Names that differ only in letter case or punctuation, such as `Sample_1` and `sample_1`, stay two samples, and a second bundle with the same cleaned-up name gains `-2` after it, which needs nothing from you. A Nanopore bundle whose reads were imported as several separate files is one sample too, its files joined in the order they were imported. An Illumina bundle from an ordinary paired import is accepted, because LGE stores the pair as one [interleaved](../../GLOSSARY.md#interleaved-fastq) file with each read beside its mate, the read from the other end of its DNA fragment. An Illumina bundle whose reads were imported as several separate chunk files is refused, because its chunks may hold the first and second mates of each pair apart.

### Open the dialog and set the reference

1. Choose **Tools > Genotyping > MiSeq Amplicon MHC Genotyping…**. The Workflow Operations dialog opens with this workflow selected, in the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. The reference and the reads sit under **Inputs**, the run's own settings under **Primary settings**, **Advanced Options** under **Advanced settings**, and **Directory** under **Output**.
2. In the **Reference** group, open the **Project Reference** menu and choose `Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref`. The menu lists only reference bundles, each by its place in the project, and on the demo this bundle arrives already chosen. A FASTA file, loose or stored inside a bundle, is not listed, so for one of those or a library outside the project click **Replace…**, which reads **Choose…** while no reference is set. **Clear** empties the choice.
3. Check that the **FASTQ Bundles** group reads "2 FASTQ bundles selected.", and open **Resolved inputs** beneath it to see the two samples. Under **Primary settings**, **Report Name** arrives filled in as `amplicon-genotyping`. Change it to `simulated-mhc`, the name the later chapters use.

<!-- SHOT: genotyping-run-dialog -->

### Read the mode caption and leave the merge alone

Under **Threads** and **Minimum supporting reads** in the **Run Parameters** group sits a line of gray text. For the demo samples it reads **Illumina sample bundles**, and on a Nanopore plate it reads **ONT sample bundles**. The caption reports what LGE decided from the platform recorded in each bundle's metadata, or from the read lengths when none is recorded, and the dialog has no control to change it. If it names the wrong platform, correct the recorded one as [Correcting a platform label](../03-reads/01-importing-fastq.md#correcting-a-platform-label) describes, or choose the right **Platform** on the import sheet and reimport those reads.

One step happens automatically here, and without it a whole locus goes quietly missing. Before [mapping](../../GLOSSARY.md#mapping), the step that places each read against the allele library, LGE joins the two [mates](../../GLOSSARY.md#mate) of each read pair into one longer fragment wherever they overlap, using [BBMerge](../../GLOSSARY.md#bbmerge). This is [read merging](../../GLOSSARY.md#read-merging), and there is nothing to click. Reads imported with the Illumina Amplicon Merge recipe arrive already merged and are mapped as they are, which is the route [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#choosing-a-tool) advises, since retained fractions compare only between runs whose reads were merged the same way. LGE merges on its own only when it sees the reads as pairs, so pairs imported as single-end files, or whose mates do not overlap, stay unmerged. A bundle of pairs is read whole, meaning every read it holds is genotyped, including a merge bundle that holds merged reads beside the pairs that did not merge. A [virtual bundle](../../GLOSSARY.md#virtual-bundle), which lists its reads rather than holding them, is [materialized](../../GLOSSARY.md#materialization) first, so the run maps every read it lists rather than the short preview it keeps. That holds on the full-length ONT route too, including a virtual bundle of one barcode that [demultiplexing](../../GLOSSARY.md#demultiplex) split out of a pooled run.

The reason is arithmetic. An Illumina sequencer reads each DNA fragment from both ends, and each read is called a mate. The whole fragment, from one end to the other, is the [insert](../../GLOSSARY.md#insert-size). A 2x251 MiSeq kit reads up to 251 bases from each of the two ends. Once the primer and [adapter](../../GLOSSARY.md#adapter) bases, the synthetic sequence added in library preparation, are set aside, one mate covers about 198 bases of the insert, which is 251 minus roughly 53, a typical figure and not a measurement of your plate. That spans a 156-base amplicon from a [class I](../../GLOSSARY.md#class-i-mhc) gene but not a 244-base amplicon from DRB, a [class II](../../GLOSSARY.md#class-ii-mhc) gene. Because a read counts only when it covers its allele target end to end, every DRB allele would receive zero reads without merging. The demo's mates are 150 bases, shorter than all three of its targets, so without merging it would count nothing at all.

LGE reports the merge in the Operations Panel as it happens. On the demo run the message begins "2 of 2 Illumina inputs contain unmerged read pairs.", where the first number counts the samples whose files still hold mate pairs, and goes on to suggest the import recipe, a set of processing steps chosen when reads are imported, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md#settings) describes.

### Turn on Deterministic haplotyping

Below Run Parameters sits a group headed **Haplotyping** with an **Analysis Mode** picker of two segments, **Genotyping only** and **Deterministic haplotyping**. Click **Deterministic haplotyping**, which follows fixed matching rules, so the same input gives the same calls. Because the reference is a `.lungfishmhcref` bundle, the **Haplotype Definition** group that appears names the bundle on a line starting "From bundle", reads "Definitions supplied by the selected reference bundle.", and needs no choice. With an ordinary reference bundle it shows **Assay**, **Species**, and **Definition** menus instead. An assay is one laboratory panel and its analysis, and each menu narrows the next, so set them in order, as [Settings](#settings) describes. **Genotyping only** reports the alleles and their supporting reads without assigning haplotypes, which is all the MiSeq cohort run did.

<!-- SHOT: genotyping-analysis-mode -->

Everything else already holds a sensible value, as [Settings](#settings) lists. The **Advanced Options** disclosure under **Advanced settings** holds a minimap2 arguments field and a Keep Intermediates checkbox.

<!-- SHOT: genotyping-advanced-options -->

### Run it and watch the Operations Panel

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row's message moves through validating the inputs, resolving the reference and tools, merging the read pairs, and mapping with [minimap2](../../GLOSSARY.md#minimap2). It then filters the alignments down to the retained reads, writes the summaries, applies the haplotype definition, and writes the workbook. The demo run takes a few seconds.

When the row turns green, the result appears in the sidebar under `Analyses/Amplicon genotyping results/`. A failed run turns the row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it. A second run with the same report name lands beside the first as `simulated-mhc_1` rather than overwriting it. Click the `.lungfishgenotype` bundle to open it, as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) describes.

### Where haplotype definitions come from

The demo project's definitions arrive inside the `.lungfishmhcref` bundle, which is the form the dialog reads without asking. A definition set can also sit on its own in the project's `Haplotype Definitions/` folder, and the **MHC Haplotype Definitions** window manages both kinds. Open it with **Tools > Genotyping > MHC Haplotype Definitions…** or with the **Manage…** button in the dialog's Haplotype Definition group. A set for your own animals comes from the group that defined the haplotypes, and the window's **Import** button brings their file in. LGE carries one real set, for Mauritian cynomolgus macaques, offered on the command line as `--preset mcm-mhc-miseq` with its allele library. It carries none for rhesus macaques.

The window lists every definition set in the project, with columns for **Definition**, **Assay**, **Species**, **Source**, and **Status**. On the demo project the set "MCM haplotypes for the mhc-simulated reference (teaching set)", with the id `mhc-simulated-mcm-teaching`, the assay `SIMULATED-MHC-three-amplicon`, and the species `MCM`, appears twice. One row comes from the reference bundle, and its **Source** reads **MHC Reference Bundle**. The other is the copy in `Haplotype Definitions/`. Selecting a row shows its details, including the bundle and reference FASTA it belongs to and its loci, here the regions MHC-A, MHC-DR, and MHC-DP. The toolbar's **Import** button brings in a colleague's definition file or a whole `.lungfishmhcref` bundle, and **New** opens the editor on a template with one placeholder locus and haplotype to rewrite. **Export** writes a set kept on its own to a file you can hand on and is dimmed for a set inside a reference bundle. The detail pane offers **Edit**, **Duplicate to Project**, and **Delete**, and for a set inside a bundle also **Replace FASTA...** and **Reveal FASTA**.

To look inside a set, select the row whose **Source** reads **MHC Reference Bundle** and click **Edit**.

<!-- SHOT: haplotype-definition-editor -->

The editor opens in a window titled Haplotype Definition, which you can resize. Its left side lists the loci, each with its number of haplotypes, and the right side shows the selected locus as one card per haplotype. A card keeps two kinds of allele apart. The associated alleles are every allele that belongs with the haplotype, and they take its color in a result when it is called. The ones ticked under **Diagnostic** are the subset the haplotype caller counts, the caller being the LGE step that turns allele counts into haplotype calls, and the stepper above them, which reads **Require 1 of 1 diagnostic alleles** on each demo haplotype, sets how many of them a sample must show. So a definition can color every allele of a haplotype while calling it only from the few that tell haplotypes apart. **Save** stores the definition together with a reference FASTA, chosen in a picker under the cards, and stays dimmed while none is chosen. For a set started with **New**, **Save** builds a new `.lungfishmhcref` bundle in `Reference allele databases/` from that FASTA, which is the window route to building one. **Cancel** closes the editor without saving.

The teaching set gives each region one haplotype and one diagnostic allele, and the haplotype comes from the `/haplotype` field of the public [ENA](../../GLOSSARY.md#ena) record each allele was deposited under, ENA being the European Nucleotide Archive and this being background only.

| Region | Haplotype | Diagnostic allele | Public record |
|---|---|---|---|
| MHC-A | M4 | `Mafa-G_02:31:01:01` | OR823640 |
| MHC-DR | M7 | `Mafa-DRB_W001:03:01:01` | OR823568 |
| MHC-DP | M1 | `Mafa-DPA1_07:02:01:01` | OR823525 |

The G gene sits in the MHC-A region, beside the A genes, which is why the Mafa-G allele marks an MHC-A haplotype. A definition groups genes into regions, which the window calls loci, while a result's **Locus** column names the gene, so one allele reads MHC-A here and MHC-G in the result. A real MCM definition set lists all seven haplotypes, M1 to M7, in each region, with several diagnostic alleles each, which is what lets the caller tell two haplotypes on two chromosome copies apart.


### What changes on the full-length ONT route {#6-what-changes-on-the-full-length-ont-route}

Choose **Tools > Genotyping > Full-Length ONT MHC Genotyping…** when your reads are long Nanopore reads that each span a whole allele. There is no demo project for this route, because the demo reads are Illumina pairs, so use your own reads, one `.lungfishfastq` bundle per animal, split from a pooled run as [On the command line](#on-the-command-line) shows. The Reference, FASTQ Bundles, Report Name, Threads, and Directory groups work as in the procedure above. Four things differ.

First, reads are clustered before anything is compared to the library. [Clustering](../../GLOSSARY.md#clustering) groups near-identical reads and derives one consensus sequence from each group, and the consensus sequences are what get genotyped. Nanopore reads carry a higher per-base error rate than Illumina reads, so a true allele matched read by read would scatter into near-misses. LGE always clusters with [Savont](../../GLOSSARY.md#savont) on this route, and the dialog has no control to pick another program. [pbAA](../../GLOSSARY.md#pbaa), another clustering program, runs only as its own operation. Both also run on their own, without genotyping, as **Tools > Clustering > Savont Clustering…** and **Tools > Clustering > pbAA Amplicon Clustering…**.

Second, a **Length Filter** group holds **Min Length** and **Max Length**, which start at 2000 and 4000 bases and suit a full-length MHC amplicon of roughly 3,000 bases.

Third, a **Call Thresholds** group holds **Locus %**, and a **Haplotype Definition** group is always shown. Both matter only when you pick a definition. Leave the **Definition** menu on **No haplotyping** for genotyping only.

<!-- SHOT: genotyping-full-length-dialog -->

Fourth, the **Advanced Options** disclosure holds three optional pickers for FASTA files, one for an orientation reference and two for forward and reverse primer sequences. LGE fills each one when it finds a file of the expected name anywhere in the project outside bundles, as [Settings](#settings) lists, so a row reading None means it found none. All three names say class I, so for a class II panel, or files named otherwise, click **Choose…** and pick your own.

Each call takes its locus from its allele's record in the library, so the locus is a gene group. The A1 to A6 genes all fall under MHC-A, and an allele named only by an accession, such as `NHP01270`, sits under its gene rather than under a locus of its own.

The full-length workflow does not discard a consensus that matches no library allele. It reports it in one of three ways. A consensus close to a library allele becomes a candidate allele named after its closest library relative. A name ending `_nov` marks one with substituted bases, and the number before it counts them, so `_2nt_nov` means two differences. A name ending `_ext` or `_partial_ext` marks a consensus that matches a shorter library record, such as one holding only the protein-coding part of the gene, and runs past its ends.

Use a reference bundle whose records carry exon annotation, because then a consensus that runs a few bases past an allele's ends, as leftover primer or barcode bases do, stays a known call, one named for the library allele, where a plain FASTA file can name it `_partial_ext`. LGE counts a library allele as complete only when it is a genomic record that keeps the stretches between its exons, and the reference bundle's annotation, its labels for where each part of a gene lies, shows its [exons](../../GLOSSARY.md#exon), the stretches that code for protein, running unbroken from exon 1 to the last exon of its gene with each in-between stretch (intron) labeled. The record must also start at exon 1 and end at the last exon, and carry one coding-sequence label over the whole record that is not marked as open at either end. The last exon depends on the gene, as the table lists, and a record at any other locus is left unknown. A library with no exon annotation leaves completeness unknown, and the provenance record counts how many library alleles were complete, incomplete, or unknown.

| Gene | Last exon |
|---|---|
| Class I gene A, B, C, E, F, G, or I, with or without a number after the letter | 7 or 8 |
| DRA | 5 |
| DRB, DPA, DPB, DQA, or DQB | 6 |

A consensus that aligns too little, too loosely, or equally well to two loci is kept as unnameable rather than forced into a name. A consensus with no usable minimap2 match at all is searched against the library with [BLAST](../../GLOSSARY.md#blast), a sequence search program, and one whose best hit covers at least 70 percent of it, over at least 1,000 bases, at 75 percent identity or more, is reported with that closest allele as a BLAST rescue. These cutoffs are fixed, with no dialog control or command-line flag, and 75 percent identity is loose, since a quarter of the aligned bases may differ. The workbook's Unmatched Alleles sheet lists every unmatched consensus with its closest match, and the bundle keeps them as the FASTA files `candidate_alleles.fasta`, `unnameable_unmatched_clusters.fasta`, and `deduplicated_unmatched_clusters.fasta`.

## Settings

Each control is documented once, with a note of which workflow shows it. Every flag is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference.

**Reference.** Names the allele library every read is compared against, on both workflows, from the **Project Reference** menu of the project's reference bundles or from any file you pick with **Choose…**. It arrives set to a bundle you selected in the sidebar, or else to the first bundle in the menu outside the `Analyses/` folder. Choose the library built for your species and panel, and on the full-length route a full-length library, because an allele missing from the library can never be reported and a short-amplicon library will not match reads that span a whole gene. On the command line this is `--reference`.

**FASTQ Bundles.** Chooses which samples the run genotypes, on both workflows. It arrives holding what you selected in the sidebar, and it accepts `.lungfishfastq` bundles, loose FASTQ files, or a folder of either. Select the whole plate for one comparison table, and run bundles one at a time for separate reports. This setting has no command-line flag, because on the command line you type the bundles after the command's name.

**Run Mode.** Shows how several selected bundles are run, on both workflows, and appears only when two or more are selected. It is fixed on **Combine all inputs, run once (1 result)**, because a genotyping run compares its samples in one table while keeping each sample's reads apart. Run the bundles one at a time when you want a separate report for each. This setting has no command-line flag.

**Include subfolders.** Adds bundles nested inside further folders when you selected a folder that holds them, on both workflows, and appears only then. It is off by default, so a folder contributes only the bundles directly inside it. Turn it on when a sequencing run wrote each sample into its own subfolder. This setting has no command-line flag.

**Report Name.** Names the result bundle and the files inside it, on both workflows. On the MiSeq route it starts as `amplicon-genotyping`. On the full-length route one input gives a name built from that file's name, and several inputs give `full-length-ont-mhc-genotyping`. Change it when the suggested name will not tell you later which plate the run covered. On the command line this is `--output-name`.

**Threads.** Sets how many processor cores the run uses at once, on both workflows. The default is your Mac's processor count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Minimum supporting reads.** Sets the fewest retained reads an allele needs before the haplotype caller counts it as evidence, on the MiSeq workflow. It starts at 1, because an exact full-length match is strict enough that one read means something. It removes no rows from the report files or the workbook, which always list every retained allele, so it matters only with Deterministic haplotyping, where [Reading the results](#reading-the-results) shows it changing a call. On the command line this is `--min-support`.

**Analysis Mode.** Decides whether the run stops at allele calls or goes on to assign haplotypes, as a two-segment picker on the MiSeq workflow. It starts on **Genotyping only**, which reports detected alleles and their supporting reads. **Deterministic haplotyping** also matches the diagnostic alleles to the haplotype definitions you choose. On the command line `--genotype-only` forces genotyping only, and `--haplotype-definition` names a definition set.

**Haplotype Definition.** Chooses the definition set the caller uses through its **Assay**, **Species**, and **Definition** menus, on the MiSeq workflow under Deterministic haplotyping and always on the full-length workflow, and with a `.lungfishmhcref` reference it shows the bundle's own set instead and needs no choice. The menus start on **Choose assay**, **Any species**, and **Choose definition…**, or **No haplotyping** on the full-length workflow, so no haplotypes are called until you pick a set, and on the MiSeq workflow under Deterministic haplotyping **Run** stays dimmed until you pick one or switch to Genotyping only. Pick one only when you want haplotype calls, which [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#haplotype-calls) explains, and use **Manage…** to open the window [Where haplotype definitions come from](#where-haplotype-definitions-come-from) describes. On the command line these are `--haplotype-assay`, `--haplotype-species`, and `--haplotype-definition`, and a `.lungfishmhcref` reference supplies its own definition on both workflows, which on the MiSeq commands `--genotype-only` turns off.

**Locus %.** Sets the smallest share an allele must hold of the sample's retained reads at its own source locus, the gene group its library record names, before the haplotype caller and the workbook use it, on the full-length workflow. The default is 1 percent, which drops stray low-level hits without touching real alleles, whose shares of a gene group typically run from about 5 to 50 percent. Raise it when background clusters are producing extra haplotype matches, and note that it applies only when a haplotype definition is chosen and is fixed into the result, which shows it under **Haplotype Thresholds** in its Audit lens. On the command line this is `--haplotype-min-locus-percent`, whose default there is 0.

**minimap2 arguments.** Passes extra arguments to minimap2 after LGE's own mapping preset, on the MiSeq workflow, inside **Advanced Options**. It starts empty, which is right for almost every run. Use it only for a minimap2 option you have read about in [the minimap2 documentation](https://lh3.github.io/minimap2/minimap2.html). On the command line this is `--extra-args`.

**Keep Intermediates.** Keeps the large working files a run produces instead of deleting them at the end, inside **Advanced Options** on both workflows. It is off by default, as the dialog's own caption recommends, because the merged reads and unfiltered alignments are large and can be regenerated. Turn it on only when a run gave an unexpected result and you want the files behind it. On the command line this is `--keep-intermediates`.

**Min Length.** Sets the shortest read, in bases, kept for clustering after primers are trimmed, on the full-length workflow. It starts at 2000, since shorter reads are usually fragments. Leave it there while your amplicon is longer than 2000 bases, and lower it for a shorter amplicon. On the command line this is `--min-length`.

**Max Length.** Sets the longest read, in bases, kept for clustering after primers are trimmed, on the full-length workflow. It starts at 4000, since longer reads are usually two amplicons joined end to end. Raise it when your amplicon is longer than 4000 bases. On the command line this is `--max-length`.

**Orient Reference.** Supplies a sequence used to turn every read the same way round before clustering, on the full-length workflow, inside **Advanced Options**. Nanopore reads arrive on either DNA strand, so without it clusters can split by strand. It arrives filled when the project holds a file named `MHC_class_I_orient.fasta`, and empty otherwise. On the command line this is `--orient-reference`.

**Forward Primers.** Names the primer sequences trimmed from the start of each read, on the full-length workflow, inside **Advanced Options**, so primer bases are not mistaken for allele differences. It arrives filled when the project holds a file named `MHC_class_I_F.fasta`. Supply it when your reads still carry their PCR [primers](../../GLOSSARY.md#primer). On the command line this is `--forward-primer`.

**Reverse Primers.** Names the primer sequences trimmed from the end of each read, on the full-length workflow, and partners the setting above. It arrives filled when the project holds a file named `MHC_class_I_R.fasta`. Supply it when your reads still carry their PCR primers. On the command line this is `--reverse-primer`.

**Directory.** Chooses where the result bundle is written, on both workflows. It points at `Analyses/Amplicon genotyping results` for the MiSeq route and `Analyses/Full-length ONT MHC genotyping results` for the full-length route. Change it only when the result belongs outside the project. On the command line this is `--output-dir`.

## Reading the results

The run's own numbers tell you whether it worked before you look at one allele call. They live in the bundle's statistics file, `simulated-mhc.retained-demux-stats.json` on the demo, and the workbook. To reach them, right-click the bundle in the project sidebar and choose **Show Package Contents**.

### The demo run

Read the retained fraction first, the share of input reads that passed the end-to-end, zero-substitution test. The demo run, on simulated reads, reports 376 of 376 fragments retained, 100 percent, and each sample 100 percent retained, 204 retained reads for A and 172 for B. The run merges the two mates of each pair into one fragment before matching, so it counts its input in fragments, one per pair, rather than in the 752 records the two mates made up. The **Run Summary** section of the Inspector's **Bundle** tab says so, reading **Total Fragments** and **Retained % of Fragments** on a run that counts fragments, as every MiSeq workflow run on per-animal sample bundles does, and **Total Reads** and **Retained %** on a result that counted reads, such as one from an older version of LGE. If the input count comes out as zero, the run still finishes, and its Operations Panel row warns that the retained percentage is not available and that the genotypes are unaffected.

The run also reports why the other reads were dropped, as four counts of alignments, in `simulated-mhc.retained-demux-stats.json`, where "demux" is left over from an older barcode-splitting mode. An alignment is one read placed against one allele target, so a read that landed on several targets counts several times, and a read that found no place still has a row in the BAM file, marked unmapped. On the demo run only the passed count appears, 376 alignments, because the reads were generated from the library without errors and nothing was dropped. On real data the other three, unmapped, not spanning the target, and spanning it with a mismatch, carry most of the reads, as the MiSeq cohort figures below show.

Each sample's retained reads spread across the three allele targets as the simulation intended.

| Allele target | Record | Locus | Sample A | Sample B |
|---|---|---|---|---|
| `Mafa-G_02:31:01:01` | OR823640 | MHC-G | 120 | 12 |
| `Mafa-DRB_W001:03:01:01` | OR823568 | MHC-DRB | 80 | 60 |
| `Mafa-DPA1_07:02:01:01` | OR823525 | MHC-DPA1 | 4 | 100 |

In the result each allele target's full name carries its record after a vertical bar, as in `Mafa-G_02:31:01:01|OR823640`, the public accession the allele came from.

The haplotype calls sit in `simulated-mhc.haplotype-analysis.json` and in the **Haplotype Calls** view of the genotype result window. Both samples get the same three calls, M4 in the MHC-A region, M7 in MHC-DR, and M1 in MHC-DP, each written with a dash in the second slot, which here means only that the teaching definitions list one haplotype per region, and the status called. [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#haplotype-calls) explains the dash.

**Minimum supporting reads** is the one setting that changes these calls. Rerun with it at 5 and sample A's MHC-DP call becomes `ERR: NO HAP`, meaning no haplotype could be called, because A's only DP allele has 4 reads, below the new floor. Every other call stays the same, and the allele rows and counts do not change, because the setting affects only which alleles count as haplotype evidence.

### At scale, the MiSeq cohort plate

The MiSeq cohort plate shows what the same figures look like on 30 real animals. Its Run Summary reads 1,427,046 under **Total Fragments**, one fragment per read pair, and 682,925 under **Retained Reads**, so **Retained % of Fragments** reads 47.86%. A reproduction on three of its samples retained 47.1 percent of 252,764 fragments. On the whole plate 682,926 alignments passed (45.1 percent of the 1,515,825 counted), 224,134 were unmapped (14.8 percent), 311,892 did not span their allele target end to end (20.6 percent), and 296,873 spanned it with at least one mismatch (19.6 percent). The counts add up to more than the fragments because a fragment that matched several allele targets counts once for each. A large unmapped share points at off-target amplification, PCR copying something other than the intended gene, or at the wrong library. A large not-spanned share points at reads that are too short, which on a MiSeq plate usually means merging did not happen.

Samples produced between 2 and 117 allele rows each, 2,108 in all, for the reason [Duplicated genes and many rows per locus](01-what-is-mhc-genotyping.md#duplicated-genes-and-many-rows-per-locus) gives. Many rows are normal, and the lowest counts probably belong to Low Support samples. The 30-sample run took 415 seconds of [wall time](../../GLOSSARY.md#wall-time), real elapsed time, on one Apple Silicon Mac whose model and memory the manual does not record, and the three-sample reproduction 56 seconds, so read both as orders of magnitude.

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

A full-length ONT run writes its per-allele table as `<name>.full-length-ont-mhc-genotypes.csv` instead. The bundle also keeps copies of some CSV files with underscores in place of hyphens, which hold the same tables, so open the hyphenated names listed above.

Three columns in the per-allele tables mark calls that need a second look. When the allele library holds identical sequences, read in either direction, LGE maps against one representative of each group, the first in the file, and the `ambiguous_with` column of both tables lists every member of the group, separated by semicolons. On the full-length route the column also lists every reference that tied for a cluster's best hit. The full-length table adds `indel_bases`, the inserted plus deleted bases in the supporting hit, the largest among the clusters behind the call, and `review_flag`, which reads `indel` when that count is above zero. A full-length hit with no substitutions stays a known call even when it carries indels, because Nanopore reads often gain or lose a base by chance. In the genotype comparison, selecting such a call's cell makes the Inspector's Selected Item tab show a **Review flag** row and a **Shares reads with** row.

## What good looks like

Read the retained fraction against your own assay. Roughly half of the fragments surviving is normal for a MiSeq panel like the cohort project, because the filter is strict and a real plate carries adapter dimers, two adapters stuck together with no sample DNA between them, and off-target product. Compare later runs against your own first one. A plate that suddenly retains 5 percent where the last one retained 48 has a laboratory problem or a library mismatch, and the four drop counts say which. A run where everything passes, like the demo, is expected only for simulated reads.

Check that every locus the panel covers is present. On the demo run each sample shows all three loci. On a real plate turn on the **Locus** column with the **Columns** button and read down each sample's filled cells for DRB rows, such as `07_Mamu-DRB1_03_03_01_01`. A plate with plenty of class I calls and no DRB rows at all probably means the merge did not happen. Reimport the reads with the Illumina Amplicon Merge recipe and run again.

Check the [sample depth](../../GLOSSARY.md#sample-depth) of every sample before you read its calls, as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#qc-status) shows. LGE's line sits at 1,000 retained reads per sample, and the demo samples, with 204 and 172 retained reads, are deliberately thin.

Check every row whose `review_flag` reads `indel` and every row with an `ambiguous_with` list before you report those alleles. For an `indel` row, look at its inserted or deleted bases in the **Genotyping Evidence BAM** under **Artifacts** in the Bundle tab, and for an `ambiguous_with` row, report the whole group listed. Then open the provenance record from the **Provenance** row under **Artifacts**, which names the allele library the run used, the only place a wrong library shows, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains.

## On the command line

[Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains Terminal, the backslashes, and the `PROJECT` variable below, and the `lungfish-cli` program ships inside LGE, with [Finding the program](../appendices/cli-reference.md#finding-the-program) showing how to run it. Every flag is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/MHC Genotyping.lungfish"

# MiSeq amplicon genotyping with the bundled MCM definitions
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

Pass `--output-dir` a path ending in `.lungfishgenotype`, because on the command line that folder is the result bundle itself, while the window's Directory is the folder that holds bundles. With `--project`, the output folder must sit inside the project, and a path outside it is refused before the run starts. A `.lungfishmhcref` reference supplies its haplotype definitions by itself, and `--genotype-only` turns that off. `fastq genotype-cohort` needs at least two `.lungfishfastq` bundles, while `fastq genotype` takes one sample, loose FASTQ files, or folders. On the full-length route the command line's `--haplotype-min-locus-percent` defaults to 0 where the window's Locus % starts at 1.
Two more commands prepare the inputs. `fastq ont-pacbio-barcode-demux` splits a full-length Nanopore run by its PacBio barcode pairs, one barcode at each end of the amplicon, read from a CSV or TSV sheet with `sample_id`, `barcode_1`, and `barcode_2` columns, into one `.lungfishfastq` bundle per sample for the full-length route, and in the window the PacBio recipe of [Oxford Nanopore Runs](../03-reads/07-ont-runs.md#settings) does the same as you import the run folder. `fastq mhc-reference-bundle` builds a `.lungfishmhcref` bundle from an allele library in FASTA, GenBank, or EMBL format and the definition files you give it with `--haplotype-definition`, and in the window **New** in the MHC Haplotype Definitions window builds one. The `haplotypes` commands manage definition sets, as [Exporting Genotypes](04-haplotype-definitions-and-export.md#on-the-command-line) lists.

## Next

Continue to [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) to open the bundle you just produced and read both its matrix and its haplotype calls.
