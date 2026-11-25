---
title: Mapping Reads to a Reference
chapter_id: 04-alignments/01-mapping-reads-to-a-reference
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 01-foundations/04-alignment-files, 03-reads/01-importing-fastq]
estimated_reading_min: 30
task: Map sequencing reads onto a reference genome with one of four mappers and read the alignment statistics of the BAM it produces.
tags: [alignments, mapping, minimap2, bwa-mem2, bowtie2, bbmap, illumina, nanopore]
tools: [minimap2, bwa-mem2, bowtie2, bbmap, samtools]
parameters_refs: [map.minimap2, map.bwa-mem2, map.bowtie2, map.bbmap, import.bam]
entry_points:
  - "Tools > Mapping > minimap2…"
  - "Tools > Mapping > BWA-MEM2…"
  - "Tools > Mapping > Bowtie2…"
  - "Tools > Mapping > BBMap…"
  - "File > Import Center… (Cmd-Shift-I) > Alignments > BAM/CRAM Alignments"
  - "Inspector > Bundle > Run Settings"
  - "CLI: lungfish-cli map, lungfish-cli bam adopt-mapping, lungfish-cli import bam"
shots:
  - id: tools-mapping-submenu
    caption: "The Tools menu with its Mapping submenu open, listing the minimap2, BWA-MEM2, Bowtie2, and BBMap items."
  - id: mapping-wizard-overview
    caption: "The FASTQ/FASTA Operations dialog with minimap2 chosen, the chr20_10.0-10.5Mb reference and the Short-read preset selected, HG002 minimap2 in the Track name field, and the Input Compatibility readout reporting Ready."
  - id: mapping-wizard-advanced
    caption: "The Advanced Settings disclosure of the mapping dialog, expanded to show the Threads, Secondary alignments, Supplementary, Min mapping quality, and Extra arguments controls."
  - id: mapping-summary-bar-reference-count
    caption: "The summary bar of a mapping onto a reference with many sequences, where a count of the reference sequences that have alignments follows the count of mapped reads."
  - id: alignment-inspector-stats
    caption: "The Alignment Summary of the HG002 minimap2 track in the Inspector, counting reads with Total Mapped 90.9K, Total Unmapped 213, Mapped % 99.8%, Chromosomes 1, and Mean Depth 44.7x."
illustrations: []
glossary_refs: [read, fragment, reference-genome, kilobase, bam, mapping, alignment, mapper, mapq, soft-clip, cigar, supplementary-alignment, secondary-alignment, primary-alignment, read-group, flagstat, properly-paired, depth, coverage-breadth, mapping-preset, paired-end, contig, contig-reference, track, mark-duplicates, plugin-pack, required-setup-pack, reference-bundle, import-center, inspector, provenance, checksum, minimizer, read-merging, interleaved-fastq]
features_refs: [map, import.bam]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## Two routes through this part

The five chapters of Alignments serve two kinds of library, and you need only the chapters for yours. [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md) explains the difference. Both routes start here and continue with [Reading an Alignment](02-reading-an-alignment.md).

| Your library | Chapters in order | Demo project | Then |
|---|---|---|---|
| Shotgun, DNA broken at random, such as a human genome | Mapping Reads to a Reference, Reading an Alignment, [Alignment Quality](04-alignment-quality.md) | Human Mapping and Variants | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) with bcftools or LoFreq |
| Amplicon, a target copied in PCR pieces, such as a SARS-CoV-2 panel | Mapping Reads to a Reference, Reading an Alignment, [Primer Trimming an Alignment](03-primer-trimming.md) | SARS-CoV-2 Amplicons | [Call the trimmed amplicon track with iVar](../05-variants/01-calling-variants-from-amplicons.md#call-the-trimmed-amplicon-track-with-ivar), or [The Viral Recon Wizard](05-viral-recon-wizard.md) for the whole SARS-CoV-2 pipeline in one run |

The nav lists Alignment Quality before Primer Trimming, so a shotgun reader can stop after the third chapter and move to Variants. An amplicon reader skips Alignment Quality, because duplicate marking is wrong for amplicon data, as that chapter explains. This chapter's example is the shotgun route. Its procedure works the same way on the amplicon run, which [Primer Trimming an Alignment](03-primer-trimming.md) maps as its first step.

## What it is

Mapping takes a set of sequencing reads and a reference genome and works out where along the reference each read came from. A [read](../../GLOSSARY.md#read) is the sequence a sequencer gets from one DNA [fragment](../../GLOSSARY.md#fragment), a piece of the sample's DNA, with a quality score for each base, and the reads in this chapter are up to 250 bases long. A [reference genome](../../GLOSSARY.md#reference-genome) is a finished genome sequence for the species, used as the shared map every sample is compared against. The program that does the placing is called a [mapper](../../GLOSSARY.md#mapper). Lungfish Genome Explorer (LGE) offers four of them, minimap2, BWA-MEM2, Bowtie2, and BBMap, and minimap2 is the default.

LGE writes the answer as a BAM file. A [BAM](../../GLOSSARY.md#bam) file holds one row, called a record, for each aligned read, with an index beside it that lets a viewer jump to any position. Each record notes where the read landed, on which strand, and how sure the mapper was. [MAPQ](../../GLOSSARY.md#mapq) is the mapper's confidence in where it placed a read, from 0 for a read that fits several places equally to 60 for one clear placement, as [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records) explains. LGE sorts the records into genome order and writes the index for you.

All four mappers take the same inputs and write the same kind of BAM. Switching mappers nudges the numbers rather than changing what you get back, and on clean human data the four land within one percentage point of each other.

In practice, select your reads, choose a mapper from **Tools > Mapping**, pick the reference and the preset, and click **Run**.

## Why you would do this

A read on its own has no address. A 250-base read from a human sample could come from chromosome 20, or from a repeat, a stretch of sequence the genome carries in many near-identical copies, and nothing in the read file says which. Mapping gives every read an address, and reads with addresses can be stacked.

The rest of this manual reads that stack. When 40 reads sit over one position and 38 of them read A where the reference reads G, that is evidence of a real difference in your sample rather than one instrument error. Variant calling, consensus building, coverage checks, and primer trimming all start from it, so none of them can run until mapping has built it.

This chapter maps reads from HG002, a man whose genome the Genome in a Bottle consortium has sequenced and checked many times over, which makes his data a common test set. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. The fixture holds 45,574 read pairs, so 91,148 reads, all drawn from a 500 kb window of chromosome 20. A kb is a [kilobase](../../GLOSSARY.md#kilobase), a thousand bases, so the window is about 500,000 bases long (500,001 exactly, since both end positions are included). The matching reference holds that window and nothing else, which is why the run takes seconds rather than hours.

## Choosing a tool

Check which instrument made your reads and how long they are, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows. Those two facts and the size of the reference pick the mapper, and for most readers the answer is minimap2.

**minimap2** indexes only [minimizers](../../GLOSSARY.md#minimizer), a small, evenly spaced sample of the short words in the genome, so even a whole human genome is indexed in minutes. [Three ways to match a read](../06-classification/01-what-is-classification.md#three-ways-to-match-a-read) shows a word lookup. For each read it finds shared words that fall in the same order along read and genome, then aligns the gaps between them base by base. Its presets cover Illumina, nanopore, and PacBio reads, and for nanopore reads it is the only mapper LGE offers. It is built for reads of about 100 bases or longer.

**BWA-MEM2** is a faster rewrite of BWA-MEM, the mapper most published human resequencing pipelines name, with the same alignments by its authors' account. It finds exact matches in a compressed copy of the genome and extends each into a local alignment, which may leave a poorly matching read end unaligned as a [soft clip](../../GLOSSARY.md#soft-clip). For FASTQ reads LGE offers it only for Illumina reads. Building its index for a human or macaque genome takes about 85 GB of memory by its documentation's figure of 28 GB per gigabase, so a typical Mac cannot build one.

**Bowtie2** uses a similar index but by default aligns each read end to end, placing every base with nothing soft-clipped. Protocols for ChIP-seq and ATAC-seq, which find where proteins sit on DNA and where DNA is open, often name it, as does Viral Recon. Typing `--local` in Extra arguments switches it to local alignment. For FASTQ reads LGE offers it only for Illumina reads.

**BBMap**, part of the BBTools suite that comes with LGE, aligns each read across its whole length and by default accepts a match at about 76 percent identity. That helps when the sample differs from the reference, such as a bacterial strain that differs from the reference strain, but a loose match is also an easier wrong match, so check the extra placements. BBMap cuts reads longer than 500 bases, or 6,000 in PacBio mode, into pieces mapped separately, so LGE refuses longer reads in each mode rather than let them be split.

**minimap2 or BWA-MEM2?** For Illumina reads of 100 bases or longer, choose minimap2. On this chapter's reads the two placed almost the same share of reads with the same median [MAPQ](../../GLOSSARY.md#mapq), as [What the four mappers give you on the same reads](#what-the-four-mappers-give-you-on-the-same-reads) shows, and the minimap2 documentation reports it as about three times as fast as BWA-MEM on such reads. Choose BWA-MEM2 only to match a published pipeline that names it, or for reads shorter than about 100 bases, and only on a small reference such as a virus, a bacterium, or one chromosome. LGE rebuilds the index at the start of every run and keeps none, which on a whole mammalian genome makes the index build the slowest part of the run.

For macaque samples, map to a rhesus macaque reference such as Mmul_10 rather than relying on a tolerant mapper against a human one. If your bundle mixes [merged reads](../../GLOSSARY.md#read-merging) with still-paired mates, every mapper keeps the remaining mates paired and maps the merged reads as single reads. minimap2 and BWA-MEM2 read both kinds in one stream, Bowtie2 takes the mates and the merged reads as separate files, and BBMap maps the pairs and the merged reads in two runs and joins the two results into one BAM. Short-read RNA sequencing needs a splice-aware mapper, one that can split a read across an intron, and LGE has none for short reads.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| minimap2 | Any read type of about 100 bases or more | You are unsure, the reads are long, or the reference is a whole genome | Reads are under about 100 bases, or a protocol names another mapper |
| BWA-MEM2 | Illumina short reads | A published pipeline names it and the reference is small | The reference is a whole mammalian genome |
| Bowtie2 | Illumina short reads, end to end | A protocol names it, such as ChIP-seq or ATAC-seq | The reference is a whole mammalian genome |
| BBMap | Short reads, and PacBio reads up to 6,000 bases | The sample differs noticeably from the reference | Reads run past 500 bases in Standard mode |

This chapter maps HG002's Illumina reads with minimap2, the default and a good fit for human short reads. Citations for minimap2, BWA-MEM2, and Bowtie2 are in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), and BBMap is cited as BBTools in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` reads under `Imports` and the `GRCh38.chr20.10.0-10.5Mb` reference bundle under `Reference Sequences`, so only the plugin pack remains. To import the files yourself instead, follow the rest of this section.

This chapter uses the hg002-chr20 fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the two FASTQ files as one paired sample, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes. Import the FASTA as a reference, as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) describes. That import makes a [reference bundle](../../GLOSSARY.md#reference-bundle), the folder LGE keeps a reference sequence in, and the mapper reads the reference from it.

Install the `read-mapping` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It holds minimap2, BWA-MEM2, and Bowtie2. BBMap arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE, as [First launch and the Welcome window](../01-foundations/06-the-lungfish-project.md#first-launch-and-the-welcome-window) shows.

No container software is needed. The numbers in this chapter came from minimap2 2.31 and samtools 1.24, and the minimap2 run takes under twenty seconds on a recent Mac.

## Procedure

**Tools > Mapping** opens the FASTQ/FASTA Operations dialog with the mapper you chose already selected in its tool list. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. Its settings pane stacks six sections, **Reference**, **Preset**, **Output Track**, **Read Group**, **Input Compatibility**, and **Advanced Settings**. minimap2 calls the second section Preset, while BWA-MEM2, Bowtie2, and BBMap call it Mode. Read Group and Advanced Settings start collapsed, and their defaults suit an ordinary run.

<!-- SHOT: tools-mapping-submenu -->

### Map the HG002 reads with minimap2

1. In the sidebar, click the `HG002.chr20.10.0-10.5Mb` read bundle under `Imports`.
2. Choose **Tools > Mapping > minimap2…**. The dialog opens with minimap2 selected in the tool list on the left.
3. Under **Reference**, choose the `GRCh38.chr20.10.0-10.5Mb` bundle. The picker may list it as `chr20_10.0-10.5Mb`, the name of the one sequence inside the bundle, as [What "bundle" means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains, and the bundle's path appears under the picker.
4. Leave **Preset** on **Short-read**, minimap2's starting preset, which suits these Illumina reads. Below it, in the **Output Track** section, replace `minimap2 Mapping` in the **Track name (--track-name)** field with `HG002 minimap2`. [Naming the alignment track](#naming-the-alignment-track) says why.
5. Check that the **Input Compatibility** readout ends in a line that starts with Ready, then click **Run**.

For the fixture the Input Compatibility readout says this.

```text
Detected format: FASTQ
Detected reads: Illumina short reads
Observed max read length: 250 bp
Ready: minimap2 is compatible with Illumina short reads.
```

<!-- SHOT: mapping-wizard-overview -->

The first three lines report what LGE found in the reads. When the preset and the reads do not match, the last line turns orange and names the mismatch instead. Run stays available, because the read class only chooses defaults, and the mapper uses the preset you chose. Run is disabled only for a combination the mapper cannot run, such as FASTA and FASTQ inputs in one run, or reads longer than BBMap accepts in the chosen mode. Reads whose platform LGE could not tell take the preset their read length suggests, with a note that the defaults are not tuned to a platform.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row's title reads `Map Reads (minimap2): HG002.chr20.10.0-10.5Mb`. When the run finishes, its detail line reads `Mapping complete: 90935/91148 reads mapped`, the reads placed out of all the reads in the bundle. The row runs the `lungfish-cli map` command, and **Copy CLI Command** in the row's context menu copies it, as [On the command line](#on-the-command-line) explains.

The result appears in the sidebar under **Analyses** as one row, named `minimap2-` followed by the date and time the run began, such as `minimap2-2026-09-27T11-21-19`. Its folder on disk holds the sorted BAM, its index, a summary file called `mapping-result.json`, and a copy of the `GRCh38.chr20.10.0-10.5Mb` reference bundle with the new alignment track attached. This manual calls that copy **the reference bundle inside the mapping result**, and every later chapter that reads, filters, or calls variants on the alignment works on it. The bundle under `Reference Sequences` is left exactly as it was. [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) draws the layout.

### Open the mapping result

1. Click the `minimap2-` row under **Analyses**. The viewport becomes the mapping viewport. A summary line at the top reads `minimap2 Mapping — 90,935 / 91,148 reads mapped (99.8%)`, with a **Focus** button at its right.
2. Read the table at the right of the viewport. It has one row for each reference sequence that has alignments, here the one row for `chr20_10.0-10.5Mb`, and LGE selects the first row for you.
3. Read the pane at the left. It shows the reference bundle inside the mapping result, with the `HG002 minimap2` track drawn under the sequence. Click **Focus** to give that pane the whole viewport, and **Back** to return.

With the mapping result selected, the [Inspector](../../GLOSSARY.md#inspector) describes the run and the reference bundle inside it, and its **Analysis** tab acts on that bundle. [The mapping table](#the-mapping-table) reads the table, and [Reading an Alignment](02-reading-an-alignment.md) reads the picture in the pane.

### Naming the alignment track

A track is an alignment or variant file attached inside a reference bundle and drawn under its sequence, as the glossary entry for [track](../../GLOSSARY.md#track) says, and each track has a name you choose. LGE fills the **Track name (--track-name)** field with the mapper's name followed by "Mapping", so every minimap2 run you ever make is called "minimap2 Mapping" unless you change it. A name that says whose reads these are, such as `HG002 minimap2`, tells two alignments apart in the track pickers of later dialogs and in the Variants table's `Variant Track` column, where each caller's track name starts from this one. This manual calls the HG002 track `HG002 minimap2` everywhere, and the Human Mapping and Variants (with results) demo project uses the same name. The name is also recorded in the run's [provenance](../../GLOSSARY.md#provenance). On the command line it is `--track-name`.

### Import an alignment somebody else made

A BAM or CRAM file that already exists needs no mapping. LGE attaches it as a new track to the reference bundle the viewport shows, so first click the reference bundle the file was aligned against in the sidebar. Without one, LGE stops with the alert "No Bundle Loaded". Then open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. On its **Alignments** tab, click the **BAM/CRAM Alignments** card and choose the file, or drop the file on the card, which has no settings. LGE indexes the file, collects its per-chromosome and read-group statistics, and names the new track after the file. The Operations Panel row runs `lungfish-cli import bam`, so **Copy CLI Command** works there too.

## Settings

Every setting below appears for all four mappers. The mapper itself is not a setting, because the menu item or the tool list chooses it.

**Reference.** Names the genome the reads are lined up against, so every coordinate in the result is a position in this sequence. It defaults to the first reference LGE finds in the project, which is a convenience rather than a judgment, and **Browse…** picks a FASTA file from outside the project instead. Change it whenever the reads came from a different organism or strain than the one the picker chose, and read the path under the picker before you run. On the command line this is `--reference`.

**Preset.** Tells minimap2 what kind of sequence it is being handed, because short accurate reads and long, less accurate reads need different scoring rules. It starts on Short-read, or on whatever the first reads in the file suggest, and it stops guessing once you change it yourself. Match it to the machine that made your reads, using the table below, since a guess from the first few reads can be wrong. On the command line this is `--preset`.

**Mode.** Plays the part of Preset for BWA-MEM2, Bowtie2, and BBMap. BWA-MEM2 and Bowtie2 offer only Short-read, because both are built for Illumina reads, so a control with one choice is expected, while BBMap defaults to Standard. Choose BBMap's PacBio mode only for long PacBio reads thousands of bases long. On the command line this is `--preset`.

The table pairs each kind of read with its minimap2 preset and the token the command line uses for it. cDNA is DNA copied from RNA, so it carries spliced genes with their introns removed. A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads.

| Your sequences | Preset | `--preset` token |
|---|---|---|
| Illumina short reads | Short-read | `sr` |
| Oxford Nanopore long reads | Oxford Nanopore | `map-ont` |
| PacBio HiFi long reads | PacBio HiFi | `map-hifi` |
| Older PacBio CLR long reads | PacBio CLR | `map-pb` |
| cDNA mapped against a genome | Spliced CDS/cDNA | `splice` |
| Contigs from a closely related genome | Assembly-to-assembly | `asm5` |

Two presets have limits the names do not show. Assembly-to-assembly is minimap2's `asm5`, which the minimap2 manual reserves for genomes whose average difference is not much above 0.1 percent, about the difference between two people, so it does not suit macaque contigs against a human reference. Spliced CDS/cDNA is minimap2's `splice`, meant for long cDNA reads and for direct-RNA reads, RNA read by a nanopore instrument without first being copied. minimap2's `lr:hq` preset for the most accurate recent nanopore reads is not offered, so use Oxford Nanopore for every nanopore run.

**Track name (--track-name).** Names the alignment track the BAM becomes inside the reference bundle inside the mapping result, a name every later track picker shows. The default is the mapper's name followed by "Mapping", such as "minimap2 Mapping", which says how the reads were placed but not whose reads they are. Type a name that identifies the sample, as [Naming the alignment track](#naming-the-alignment-track) explains. On the command line this is `--track-name`.

**Run Mode.** Appears only when you select more than one read bundle, and decides whether each bundle gets its own alignment or all of them are pooled into one. The default is **Run separately per bundle**, which keeps samples apart and gives each bundle its own read group, so the Read Group fields give way to the note "Each bundle gets its own read group, derived automatically from its sample name." Choose **Combine all inputs, run once** only when the bundles are pieces of one library, such as two sequencing runs of the same tube, because the pooled BAM keeps no record of which read came from which bundle. This setting has no command-line flag.

A pooled run keeps each bundle's own read pairs and never pairs one bundle's reads with another's, even when their names look like the two mates of one sample. It stops before mapping when the bundles cannot share one run, and the failed row names the bundles of each kind. That happens for bundles of read pairs beside bundles of single reads, long reads beside short reads, pairs kept in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file beside pairs kept as R1 and R2 files, and compressed files beside uncompressed ones. Bundles that each hold both read pairs and single reads, such as merged reads, stop too, with the words "These inputs cannot be pooled into one run, because a pool keeps the pairs of its inputs only when every input holds read pairs." Map such bundles with **Run separately per bundle**.

Two or more files from inside one bundle count as that bundle, which LGE reads once, and the run's log says "Several inputs lie in the same bundle, so each bundle is read once, as the bundle". Two loose FASTQ files named as the R1 and R2 of one sample, outside any bundle, are a different case. They map as a pair, and the copied command carries `--paired`.

The next five settings sit inside the collapsed **Read Group** disclosure. A [read group](../../GLOSSARY.md#read-group) is the `@RG` line in a BAM header that names the sample, library, instrument, and lane the reads came from, and every read in the file carries the ID of its read group. Joint variant callers, which call several samples at once, use it to tell samples apart, and duplicate marking uses it to tell libraries apart. LGE fills in every field, so change one only when a downstream tool or a collaborator asks for a specific value. After the run the Inspector's Read Groups list shows what ended up in the file. The flag in each label is the command-line name of that field, not something you type into the window.

**ID (--rg-id).** Writes the read-group identifier, the label each read carries to say which batch it belongs to. It defaults to the sample name and should not contain spaces, because some downstream tools mishandle them. Set it when you plan to merge this alignment with others and need each batch to stay distinguishable. On the command line this is `--rg-id`.

**Sample (--rg-sm).** Records which biological sample the reads came from, and joint variant callers treat every read group sharing one sample name as one individual. It defaults to the sample name LGE takes from the read bundle. Set it to your real specimen identifier when the bundle name is not one. On the command line this is `--rg-sm`.

**Library (--rg-lb).** Records which sequencing library the reads came from, where a library is one batch of DNA fragments prepared for the sequencer. It defaults to the sample name, which is right when each sample has one library, since [duplicate marking](../../GLOSSARY.md#mark-duplicates) only compares reads within one library. Set it when one sample was prepared as two libraries and you want duplicates judged within each. On the command line this is `--rg-lb`.

**Platform (--rg-pl).** Records the sequencing technology, which some variant callers use to choose an error model. LGE fills it from the preset, writing `ILLUMINA` for Short-read and BBMap Standard, `ONT` for Oxford Nanopore, `PACBIO` for the PacBio choices, `CDNA` for Spliced CDS/cDNA, and `ASSEMBLY` for Assembly-to-assembly, and it rewrites the field when you change the preset unless you typed your own value. Correct it when that value does not match your instrument. On the command line this is `--rg-pl`.

**Platform unit (--rg-pu).** Records the flow cell and lane the reads came off, the finest batch label a read group holds. It defaults to the sample name, because LGE has no flow-cell details to fill in. Fill it when you are chasing a problem confined to one lane and need to keep lanes apart. On the command line this is `--rg-pu`.

The last five settings sit inside the collapsed **Advanced Settings** disclosure. They decide which alignments survive into the finished BAM, and the defaults suit almost every run.

<!-- SHOT: mapping-wizard-advanced -->

**Threads.** Sets how many processor cores the mapper uses at once. The default is every core your Mac has, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Secondary alignments.** Keeps a [secondary alignment](../../GLOSSARY.md#secondary-alignment) for each other place a read could also have come from, and repeated regions produce many of them. It is off by default, because secondary records inflate counts and confuse most downstream tools. Turn it on when you study repeats or gene families and need to see every plausible placement. On the command line this is `--secondary`.

**Supplementary.** Keeps the [supplementary alignment](../../GLOSSARY.md#supplementary-alignment) records of a read split across two places, one part here and the rest elsewhere, which is how a structural rearrangement such as a large deletion shows up in the reads. It is checked by default, so that split-read evidence stays in the file. Uncheck it only when a downstream tool fails on split records. On the command line this is `--no-supplementary`.

**Min mapping quality.** Drops every read whose MAPQ falls below this number from the BAM itself, unlike the two later MAPQ controls that [Three MAPQ cutoffs](04-alignment-quality.md#three-mapq-cutoffs) compares. The default is 0, which keeps everything, and the control accepts 0 to 60. Raise it to about 20 when reads from repeats are landing in the wrong place, which shows as a pile of low-MAPQ reads carrying variants that no neighboring region supports, and remember that one cutoff is stricter for some mappers than for others, as [What the four mappers give you on the same reads](#what-the-four-mappers-give-you-on-the-same-reads) explains. On the command line this is `--min-mapq`.

**Extra arguments.** Passes text straight to the mapper without LGE checking it. The default is empty, which is right for almost every run. Use it only for a mapper option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

LGE checks only that the Extra arguments text splits cleanly into separate options. Text it cannot split turns orange under the field and blocks Run. The gray placeholder in the field shows a sample for each mapper, `--eqx -N 5` for minimap2, `-M -Y` for BWA-MEM2, `--very-sensitive -N 1` for Bowtie2, and `minid=0.97 local=t` for BBMap.

## Reading the results

Click the `minimap2-` result under **Analyses**. The mapping viewport reports the run in its summary line and table, and the Inspector reports it on its **Bundle** tab. Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. The Bundle tab lists the run's own sections first, **Run Inputs**, **Run Settings**, **Alignment Tracks**, and **Output Files**. Below them sit **Alignment Summary**, **Read Groups**, and **Flag Statistics**, which describe the BAM itself.

One idea makes every count below readable. A read is the sequence read from one fragment, or from one end of it, and a record is one row of the BAM. Most reads get exactly one record, called the [primary alignment](../../GLOSSARY.md#primary-alignment). A read that the mapper splits across two places also gets a supplementary record. So a count of records runs a little higher than a count of reads. The mapping table, Run Settings, and the Alignment Summary count reads, so a split read counts once, while most Flag Statistics rows count records.

### The mapping table

The summary line above the table gives the reads placed out of all the reads in the run, and their share as a percentage. The table has one row for each reference sequence that has alignments, and every number in it is measured from the BAM. The first four columns, **Sample**, **Track**, **Contig**, and **Length**, say which sample, track, and [reference sequence](../../GLOSSARY.md#contig-reference) a row describes and how long the sequence is. The rest read like this.

| Column | What it shows |
|---|---|
| Mapped Reads | Reads placed on this sequence, each read counted once |
| % Mapped | Mapped Reads as a share of all the reads in the run |
| Mean Depth | The average [depth](../../GLOSSARY.md#depth), the number of reads covering a position, over every position of the sequence |
| Coverage Breadth | The share of the sequence's positions with at least one read, its [coverage breadth](../../GLOSSARY.md#coverage-breadth) |
| Median MAPQ | The middle MAPQ of the reads placed on this sequence |
| Mean Identity | The share of the placed reads' aligned bases that match the reference |

For the fixture's one row, Mapped Reads is 90,935 and Mean Depth is 44.7. A reference sequence with no alignments at all is left out of the table. When the reference holds more than one sequence and some have none, the summary line adds a count such as "94 of 905,628 reference sequences have alignments". Hold the pointer over that count to see how many sequences were left out of the list.

<!-- SHOT: mapping-summary-bar-reference-count -->

### The Alignment Summary

<!-- SHOT: alignment-inspector-stats -->

The Alignment Summary counts reads, taken from samtools' tally of the BAM. The Inspector rounds any count of 1,000 or more to thousands with one decimal place, so 90,935 reads show as 90.9K.

| Label | What it counts | Fixture value |
|---|---|---|
| Track | The alignment track the counts describe | HG002 minimap2 |
| Total Mapped | Reads placed on the reference, each read counted once | 90.9K, which is 90,935 |
| Total Unmapped | Reads the mapper could not place | 213 |
| Mapped % | Total Mapped as a share of all reads, drawn as a bar beneath | 99.8% |
| Chromosomes | Reference sequences the BAM names | 1 |
| Mean Depth | The measured mean depth over the one reference sequence | 44.7x |

Mean Depth comes from `samtools coverage`, which counts the placed reads over every position, leaving out secondary and supplementary records and marked duplicates, and averages over the whole sequence. It is the same figure as the mapping table's Mean Depth and the `meanDepth` value in `mapping-result.json`. The row appears only when the reference holds a single sequence, and it can appear a moment after the other rows. For a reference of many sequences, such as a whole genome, take depth from the mapping table's Mean Depth column instead. Output Files lists `mapping-result.json` with a Reveal in Finder button, and it opens in any text editor. How much depth is enough, and how to read depth position by position, is covered in [The coverage curve](02-reading-an-alignment.md#the-coverage-curve).

A track whose statistics hold no read counts shows alignment records instead. Its labels then end in (alignments), such as **Total Mapped (alignments)**, and a note under them says to run the mapping or import the alignment again to count its reads. When such a track is the one the mapping viewport shows, its summary line says alignments mapped rather than reads mapped.

### Run Settings

Run Settings, on the **Bundle** tab, lists the mapper, the preset, the main settings you chose, the mapper and samtools versions, and four counts from `mapping-result.json`. These four count reads, as the Alignment Summary does.

| Row | Fixture value |
|---|---|
| Mapped Reads | 90935 |
| Unmapped Reads | 213 |
| Total Reads | 91148 |
| Mapped Rate | 99.8% |

Total Reads matches the 91,148 reads you imported, which is the first thing to check after any run. Mapped Reads matches the Alignment Summary's Total Mapped, since both count reads.

The Paired End row reads `Yes (interleaved)` for this run, because the bundle keeps both mates in one interleaved file, each read followed by its mate, and minimap2 pairs them as it reads. All four mappers pair a file like this one. On a bundle that mixes merged reads with pairs, the row reads `Yes (pairs; merged reads mapped as single reads)` for all four mappers, as [Choosing a tool](#choosing-a-tool) explains.

Below the rows, Run Settings lists each command the run ran, under its tool's name, such as minimap2 or samtools sort. Click a step's arrow to show the whole command, with every path inside the project written relative to the project. The copy icon beside a step copies that step, and **Copy All Steps** copies every step. Copied commands carry every path in full, so they also run outside the project.

### Flag Statistics

Expand the collapsed **Flag Statistics** list for the raw [flagstat](../../GLOSSARY.md#flagstat) counts. `samtools flagstat` makes them by tallying the flags on every record, where a flag is a set of yes-or-no markers such as mapped, paired, or supplementary. Unlike the sections above, most of its rows count records. Five rows tell the story, and the last column gives the exact figure behind each rounded one.

| Row | What it counts | Inspector shows | Exact count |
|---|---|---|---|
| total | Every record in the BAM | 91.2K | 91,203 |
| primary | One record per read | 91.1K | 91,148 |
| supplementary | Extra records for split reads | 55 | 55 |
| primary mapped | Reads placed somewhere | 90.9K | 90,935 |
| properly paired | Reads whose mate landed where the library says it should | 90.4K | 90,414 |

Read them top to bottom. The total is 55 higher than the number of reads you imported, and the supplementary row accounts for exactly those 55 records. Take them away and you reach primary, 91,148, one record per read. Of those reads, 90,935 were placed, which is 99.77 percent. The Alignment Summary's Total Mapped matches primary mapped, because both count reads. The list's mapped row, 90,990, counts records, so it includes the 55 supplementary records.

A read is [properly paired](../../GLOSSARY.md#properly-paired) when its mate landed on the same sequence, facing it, at about the distance the fragments in the library were cut to. Here that is 90,414 of 91,148 reads, 99.19 percent, the mark of a clean library. Rows such as secondary and duplicates read 0 for this run, because the default settings drop secondary records and nothing has marked duplicates yet.

### What the four mappers give you on the same reads

All four mappers ran on the identical fixture with their default settings, each handed the interleaved bundle as pairs. The first three number columns count alignment records, as Flag Statistics does. Records is the Flag Statistics total, Mapped records counts the records placed, and Mapped % is their share of all records. Properly paired is the Flag Statistics share described above. Median MAPQ is the middle MAPQ of all placed reads, so half scored above it and half below.

| Mapper | Records | Mapped records | Mapped % | Properly paired | Mean depth | Median MAPQ |
|---|---|---|---|---|---|---|
| minimap2 | 91,203 | 90,990 | 99.77% | 99.19% | 44.7x | 60 |
| BWA-MEM2 | 91,322 | 91,244 | 99.91% | 99.76% | 44.8x | 60 |
| Bowtie2 | 91,148 | 90,241 | 99.00% | 82.22% | 44.8x | 42 |
| BBMap | 91,148 | 90,655 | 99.46% | 98.91% | 45.0x | 45 |

The record counts differ because the mappers disagree about how many split reads to report. minimap2 wrote 55 supplementary records and BWA-MEM2 wrote 174, while Bowtie2 and BBMap wrote none and so land on the input's own 91,148 records, one per read. Take a mapper's supplementary records away from its Mapped records and you have its mapped reads, such as 90,990 less 55, or 90,935 reads, for minimap2. The mapped percentages sit within one percentage point of each other, and mean depth agrees to within a third of a read.

Bowtie2's low properly paired share is a setting, not a failure. By default it accepts a pair only when the fragment is at most 500 bases long, its `-X` option, and about 15 percent of this library's fragments are longer, judged from the minimap2 alignment. Both mates of such a pair are still placed, so Mapped records hardly moves. Type `-X 1000` in Extra arguments when a Bowtie2 run on a long-insert library reports far fewer proper pairs than you expect.

Median MAPQ is where they part company, and the reason is scaling, not placement. Each mapper puts its confidence on its own scale. minimap2 and BWA-MEM2 give a clear placement 60. Bowtie2's scale stops at 42, so a read it is certain of scores 42. BBMap's scores also ran lower on these reads, with a median of 45. A Min mapping quality cutoff therefore means different things for different mappers. A cutoff of 20 is a mild filter under minimap2 or BWA-MEM2 and a stricter one under Bowtie2 or BBMap. Set any cutoff against the mapper you actually ran, and never compare MAPQ values between mappers.

For clean human short reads against the right reference, the choice of mapper barely matters to the result. What differs is what each mapper can run on and how large a reference it handles, which [Choosing a tool](#choosing-a-tool) covers. BBMap tolerates more mismatches than the other three, so a second run with it is worth trying when another mapper reports a mapping rate you did not expect.

## What good looks like

Check the mapping rate against the reference you chose. For human reads against the matching human reference, Mapped Rate should sit above 99 percent, and all four mappers clear that on the fixture. A rate under 50 percent usually means the wrong reference, so confirm the bundle really is the genome you sequenced. A preset mismatch is the second suspect, since nanopore reads run through the Short-read preset mostly fail to map. A third cause applies to samples that hold more than one organism, such as a swab where a pathogen sits among human reads, because only the fraction matching your reference maps. [What Is Read Classification](../06-classification/01-what-is-classification.md) shows how to find out what a sample holds.

Check the totals against your read count. Total Reads in Run Settings should equal the reads you imported, and the Flag Statistics total should equal that count plus the supplementary and secondary records, never less. A total below your read count means reads were dropped, which happens when Min mapping quality was raised.

Check the pairing when the reads are paired. Properly paired near 100 percent is healthy. Two loose FASTQ files mapped as a pair are compared before anything runs, and a run that stops with "Paired FASTQ mates do not match" or "Paired FASTQ mates are out of step" usually means one file was cut short during download or sorted on its own. A failed run turns its row red and opens an alert that names the failed step, says what happened, and suggests what to try. [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from the row.

Check depth with Mean Depth. The fixture's 44.7x is comfortable for calling variants in a human sample.

The run's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads, holds the command and every tool version. If a re-run after a plugin pack update gives a slightly different BAM, compare the Mapper Version rows in Run Settings first. A new mapper release sometimes moves a soft clip by a base or two. A [soft clip](../../GLOSSARY.md#soft-clip) is a stretch at a read end that stays in the file but is left out of the pileup, written as `S` in the read's [CIGAR](../../GLOSSARY.md#cigar) string, as [The CIGAR string](../01-foundations/04-alignment-files.md#the-cigar-string) explains. That change is harmless for variant calling.

## On the command line

The block below maps the demo project's reads exactly as the procedure does, following the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Every flag of `map` is listed in [Mapping and alignment tracks](../appendices/cli-reference.md#mapping-and-alignment-tracks) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"

lungfish-cli map "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq" \
  --reference "$PROJECT/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref" \
  --project "$PROJECT" \
  --mapper minimap2 --preset sr \
  --track-name "HG002 minimap2"
```

With `--project`, the command writes the same result the window writes, a `minimap2-<timestamp>` folder under `Analyses/` holding the BAM and the reference bundle inside the mapping result with the `HG002 minimap2` track attached, and it prints the folder's path at the end. It reads the pairing from the read bundle, as the window does, so a bundle needs no `--paired`. Two loose FASTQ files do need `--paired`, because without it the command maps them as unrelated single reads, and `--paired` refuses any number of files other than two. Without `--preset`, the command follows the read class of the input, as the window does, and a preset that does not suit the reads prints a warning and still runs. `--no-viewer-bundle` leaves out the reference bundle copy when you want only the BAM.

Every Map Reads run in the window is this same command. **Copy CLI Command** on the run's row in the Operations Panel copies it with every value the window chose spelled out, including `--output-dir`, `--sample-name`, the five read-group flags, and `--threads`. That copy ends in `--format json`, which makes the command print one line of JSON for each progress event, for LGE to read. Leave that flag off to get the readable report.

The track's BAM sits inside the copy as `alignments/aln_` followed by eight letters and digits and `.sorted.bam`, such as `aln_93ACDFDA.sorted.bam`, and the mapper's own copy of the BAM stays at the top of the result folder as `HG002.chr20.10.0-10.5Mb.sorted.bam`. The track's copy is an APFS clone of that file, a copy the Mac's file system shares with the original until one of them changes, so it takes almost no extra disk space and is not sorted a second time. On a disk that cannot make clones, LGE writes a full copy instead. The eight characters, the track's identifier, differ on every run, and later command-line chapters take them from `lungfish-cli bundle list` or from the `Track ID` line `lungfish-cli map` prints.

## Next

Continue to [Reading an Alignment](02-reading-an-alignment.md) to open the BAM in the alignment viewport and read the pileup you just built.
