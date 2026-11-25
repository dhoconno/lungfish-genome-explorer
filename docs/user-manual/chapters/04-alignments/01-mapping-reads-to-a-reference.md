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
glossary_refs: [read, fragment, reference-genome, kilobase, bam, mapping, alignment, mapper, mapq, soft-clip, cigar, supplementary-alignment, secondary-alignment, primary-alignment, read-group, flagstat, properly-paired, depth, coverage-breadth, mapping-preset, paired-end, contig, contig-reference, track, mark-duplicates, plugin-pack, required-setup-pack, reference-bundle, import-center, inspector, provenance, checksum, minimizer, read-merging, interleaved-fastq, shotgun, amplicon, bundle, pipeline, viewport, sidebar, fasta, container, fixture, intron, mate, operations-panel, library]
features_refs: [map, import.bam]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## Two routes through this part

The five chapters of Alignments serve two kinds of library, and you need only the chapters for yours. [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md) explains the difference, and a whole human genome sample is shotgun, so follow the first row. Both routes start here and continue with [Reading an Alignment](02-reading-an-alignment.md).

| Your library | Chapters in order | Demo project | Then |
|---|---|---|---|
| [Shotgun](../../GLOSSARY.md#shotgun), DNA broken at random, such as a human genome | Mapping Reads to a Reference, Reading an Alignment, [Alignment Quality](04-alignment-quality.md) | Human Mapping and Variants | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) with bcftools or LoFreq |
| [Amplicon](../../GLOSSARY.md#amplicon), a target copied in PCR pieces, such as a SARS-CoV-2 panel | Mapping Reads to a Reference, Reading an Alignment, [Primer Trimming an Alignment](03-primer-trimming.md) | SARS-CoV-2 Amplicons | [Call the trimmed amplicon track with iVar](../05-variants/01-calling-variants-from-amplicons.md#call-the-trimmed-amplicon-track-with-ivar), or [The Viral Recon Wizard](05-viral-recon-wizard.md) for the whole SARS-CoV-2 pipeline in one run |

The nav lists Alignment Quality before Primer Trimming, so a shotgun reader can stop after the third chapter. An amplicon reader skips Alignment Quality, because duplicate marking is wrong for amplicon data. This chapter's example is the shotgun route, and its procedure works the same way on the amplicon run, which [Primer Trimming an Alignment](03-primer-trimming.md) maps as its first step.

## What it is

Mapping takes a set of sequencing reads and a reference genome and works out where along the reference each read came from. A [read](../../GLOSSARY.md#read) is the sequence a sequencer gets from one DNA [fragment](../../GLOSSARY.md#fragment), a piece of the sample's DNA, with a quality score for each base, and the reads in this chapter are up to 250 bases long. A [reference genome](../../GLOSSARY.md#reference-genome) is a finished genome sequence for the species, used as the shared map every sample is compared against. The program that does the placing is called a [mapper](../../GLOSSARY.md#mapper). Lungfish Genome Explorer (LGE) offers four of them, minimap2, BWA-MEM2, Bowtie2, and BBMap, and minimap2 is the default.

LGE writes the answer as a BAM file. A [BAM](../../GLOSSARY.md#bam) file holds one row, called a record, for each aligned read, with an index beside it that lets a viewer jump to any position. Each record notes where the read landed, on which strand, and how sure the mapper was. [MAPQ](../../GLOSSARY.md#mapq) is the mapper's confidence in where it placed a read, from 0 for a read that fits several places equally to 60 for one clear placement, as [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records) explains. The top score depends on the mapper, 60 for minimap2 and BWA-MEM2 but 42 for Bowtie2, so compare a MAPQ only with other runs of the same mapper. LGE sorts the records into genome order and writes the index for you.

All four mappers take the same inputs and write the same kind of BAM, and on clean human data the four land within one percentage point of each other.

In practice, select your reads, choose a mapper from **Tools > Mapping**, pick the reference and the preset, and click **Run**.

## Why you would do this

A read on its own has no address. A 250-base read from a human sample could come from chromosome 20, or from a repeat, a stretch of sequence the genome carries in many near-identical copies, and nothing in the read file says which. Mapping gives every read an address, and reads with addresses can be stacked.

The rest of this manual reads that stack. When 40 reads sit over one position and 38 of them read A where the reference reads G, that is evidence of a real difference in your sample rather than one instrument error. Variant calling, consensus building, coverage checks, and primer trimming all start from the stack.

This chapter maps reads from HG002, a man whose genome the Genome in a Bottle consortium has sequenced and checked many times over, which makes his data a common test set. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one [bundle](../../GLOSSARY.md#bundle), the folder it keeps a dataset in. The fixture holds 45,574 read pairs, so 91,148 reads, all drawn from a 500 kb window of chromosome 20. A kb is a [kilobase](../../GLOSSARY.md#kilobase), a thousand bases, so the window is about 500,000 bases long (500,001 exactly). The matching reference holds that window and nothing else, which is why the run takes seconds rather than hours.

A whole-genome sample changes three things. Its reference is a whole genome, thousands of times longer than this window, so the rule in [Choosing a tool](#choosing-a-tool) picks minimap2. Run time grows with the number of reads and with the length of the reference, and no whole-genome timing was measured for this manual, so watch the run's row in the [Operations Panel](../../GLOSSARY.md#operations-panel), the list of running jobs. Its reference has many sequences, so [The Alignment Summary](#the-alignment-summary) says where to find the overall depth.

## Choosing a tool

Check which instrument made your reads and how long they are, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows. Those two facts and the size of the reference pick the mapper, and for most readers the answer is minimap2.

**minimap2** builds its index, a lookup table that lets each read be found quickly, from only [minimizers](../../GLOSSARY.md#minimizer), a small, evenly spaced sample of the short words in the genome, so even a whole human genome is indexed in minutes. For each read it finds shared words that fall in the same order along read and genome, then aligns the gaps between them base by base. Its presets cover Illumina, nanopore, and PacBio reads, and it is the only mapper with a nanopore preset. It is built for reads of about 100 bases or longer.

**BWA-MEM2** is a faster rewrite of BWA-MEM, the mapper most published human resequencing [pipelines](../../GLOSSARY.md#pipeline) name, where a pipeline is a fixed series of tools, with the same alignments by its authors' account. It finds exact matches in a compressed copy of the genome and extends each into a local alignment, which may leave a poorly matching read end unaligned as a [soft clip](../../GLOSSARY.md#soft-clip). When the reads are not Illumina short reads, the readout turns orange and names the mismatch, and Run stays available. Building its index for a human or macaque genome takes about 85 GB of memory, the RAM that About This Mac lists, by its documentation's figure of 28 GB per gigabase, so a typical Mac cannot build one.

**Bowtie2** uses a similar index but by default aligns each read end to end, placing every base with nothing soft-clipped. Protocols for ChIP-seq and ATAC-seq, which find where proteins sit on DNA and where DNA is open, often name it, as does Viral Recon. Typing `--local` in Extra arguments switches it to local alignment. Like BWA-MEM2, it turns the readout orange for reads that are not Illumina short reads.

**BBMap**, part of the BBTools suite that comes with LGE, aligns each read across its whole length and by default accepts a match at about 76 percent identity, the share of aligned bases that match the reference. The fixture's reads reach 99.4 percent under minimap2, as [The mapping table](#the-mapping-table) shows. A loose match helps when the sample differs from the reference, such as a bacterial strain that differs from the reference strain, but a loose match is also an easier wrong match, so check the extra placements. BBMap cuts reads longer than 500 bases, or 6,000 in PacBio mode, into pieces mapped separately, so LGE refuses longer reads in each mode rather than let them be split.

**minimap2 or BWA-MEM2?** For Illumina reads of 100 bases or longer, choose minimap2. On this chapter's reads the two placed almost the same share of reads with the same median [MAPQ](../../GLOSSARY.md#mapq), as [What the four mappers give you on the same reads](#what-the-four-mappers-give-you-on-the-same-reads) shows, and the minimap2 documentation reports it as about three times as fast as BWA-MEM on such reads. Choose BWA-MEM2 only to match a published pipeline that names it, or for reads shorter than about 100 bases, and only on a small reference such as a virus, a bacterium, or one chromosome. A whole human genome is not a small reference, so this rule sends it to minimap2. LGE rebuilds the index at the start of every run and keeps none, which on a whole mammalian genome makes the index build the slowest part of the run.

For macaque samples, map to a rhesus macaque reference such as Mmul_10 rather than relying on a tolerant mapper against a human one. The next two sentences matter only if your bundle mixes [merged reads](../../GLOSSARY.md#read-merging) with still-paired [mates](../../GLOSSARY.md#mate), and you can skip them otherwise. Every mapper keeps the remaining mates paired and maps the merged reads as single reads. minimap2 and BWA-MEM2 read both kinds together, Bowtie2 takes them as separate files, and BBMap maps them in two runs and joins the results into one BAM. Short-read RNA sequencing needs a splice-aware mapper, one that can split a read across an [intron](../../GLOSSARY.md#intron), and none of these four is one for short reads, so LGE counts RNA-seq reads with salmon, or with STAR on a Linux machine, as the RNA-seq chapters describe.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| minimap2 | Any read type of about 100 bases or more | You are unsure, the reads are long, or the reference is a whole genome | Reads are under about 100 bases, or a protocol names another mapper |
| BWA-MEM2 | Illumina short reads | A published pipeline names it and the reference is small | The reference is a whole mammalian genome |
| Bowtie2 | Illumina short reads, end to end | A protocol names it, such as ChIP-seq or ATAC-seq | The reference is a whole mammalian genome |
| BBMap | Short reads, and PacBio reads up to 6,000 bases | The sample differs noticeably from the reference | Reads run past 500 bases in Standard mode |

This chapter maps HG002's Illumina reads with minimap2, the default and a good fit for human short reads. Citations for minimap2, BWA-MEM2, and Bowtie2 are in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), and BBMap is cited as BBTools in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` reads under `Imports` and the `GRCh38.chr20.10.0-10.5Mb` reference bundle under `Reference Sequences`, so only the plugin pack remains. To work from loose files or your own reads instead, follow the rest of this section.

This chapter uses the hg002-chr20 [fixture](../../GLOSSARY.md#fixture), a small practice data set. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

**Using your own reads.** Reading [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) comes first, because this chapter starts after your reads are in the project. Import the two FASTQ files as one paired sample, as that chapter describes, and import your reference, a [FASTA](../../GLOSSARY.md#fasta) file, as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) describes. For a whole human genome sample, import the whole-genome reference. That import makes a [reference bundle](../../GLOSSARY.md#reference-bundle), the folder LGE keeps a reference sequence in, and the mapper reads the reference from it.

Install the `read-mapping` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The Plugin Manager's **Installed** tab lists what is already there, and [What a missing tool looks like](../01-foundations/07-plugin-packs.md#what-a-missing-tool-looks-like) shows the sign that a tool is absent. It holds minimap2, BWA-MEM2, and Bowtie2. BBMap arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE, as [First launch and the Welcome window](../01-foundations/06-the-lungfish-project.md#first-launch-and-the-welcome-window) shows.

No [container](../../GLOSSARY.md#container) software is needed. The numbers in this chapter came from minimap2 2.31 and samtools 1.24, and the minimap2 run takes under twenty seconds on a recent Mac for this 500 kb slice alone.

## Procedure

**Tools > Mapping** opens the FASTQ/FASTA Operations dialog with the mapper you chose already selected in its tool list. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. Its settings pane stacks six sections, **Reference**, **Preset**, **Output Track**, **Read Group**, **Input Compatibility**, and **Advanced Settings**. minimap2 calls the second section Preset, while BWA-MEM2, Bowtie2, and BBMap call it Mode. Read Group and Advanced Settings start collapsed, shown as a title alone, and their defaults suit an ordinary run. Click the small arrow beside a title to open that section.

<!-- SHOT: tools-mapping-submenu -->

### Map the HG002 reads with minimap2

1. In the [sidebar](../../GLOSSARY.md#sidebar), the list at the left of the window, click the `HG002.chr20.10.0-10.5Mb` read bundle under `Imports`.
2. Choose **Tools > Mapping > minimap2…**. The dialog opens with minimap2 selected in the tool list on the left.
3. Under **Reference**, choose the `GRCh38.chr20.10.0-10.5Mb` bundle. The picker may list it as `chr20_10.0-10.5Mb`, the name of the one sequence inside the bundle, as [What "bundle" means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. Check that the path under the picker ends in `GRCh38.chr20.10.0-10.5Mb.lungfishref`.
4. Leave **Preset** on **Short-read**, minimap2's starting preset, which suits these paired-end Illumina reads. Below it, in the **Output Track** section, replace `minimap2 Mapping` in the **Track name (--track-name)** field with `HG002 minimap2`. [Naming the alignment track](#naming-the-alignment-track) says why.
5. Check that the **Input Compatibility** readout ends in a line that starts with Ready, then click **Run**.

For the fixture the Input Compatibility readout says this.

```text
Detected format: FASTQ
Detected reads: Illumina short reads
Observed max read length: 250 bp
Ready: minimap2 is compatible with Illumina short reads.
```

<!-- SHOT: mapping-wizard-overview -->

The first three lines report what LGE found in the reads, their kind and their longest length. When the preset and the reads do not match, the last line turns orange and names the mismatch instead, and the fix is the preset that matches your reads, from the table under Settings. Run stays available, because the kind of reads only chooses defaults and the mapper uses the preset you chose, so a mismatched preset can leave most reads unmapped, as [What good looks like](#what-good-looks-like) explains. Run is disabled only for a combination the mapper cannot run, such as FASTA and FASTQ inputs in one run, or reads longer than BBMap accepts in the chosen mode.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). When the run finishes, its detail line reads `Mapping complete: 90935/91148 reads mapped`, the reads placed out of all the reads in the bundle. **Copy CLI Command** in the row's context menu copies the `lungfish-cli map` command it runs, as [On the command line](#on-the-command-line) explains.

The result appears in the sidebar under **Analyses** as one row, named `minimap2-` followed by the date and time the run began, such as `minimap2-2026-09-27T11-21-19`. Its folder holds the sorted BAM, its index, a summary file called `mapping-result.json`, and a copy of the `GRCh38.chr20.10.0-10.5Mb` reference bundle with the new alignment track attached. This manual calls that copy **the reference bundle inside the mapping result**, and every later chapter that works on the alignment uses it. The bundle under `Reference Sequences` is left exactly as it was, and [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) draws the layout.

### Open the mapping result

1. Click the `minimap2-` row under **Analyses**. The [viewport](../../GLOSSARY.md#viewport), the main display area, becomes the mapping viewport. A summary line at the top reads `minimap2 Mapping — 90,935 / 91,148 reads mapped (99.8%)`, with a **Focus** button at its right.
2. Read the table at the right of the viewport. It has one row for each reference sequence that has alignments, here the one row for `chr20_10.0-10.5Mb`, and LGE selects the first row for you.
3. Read the pane at the left. It shows the reference bundle inside the mapping result, with the `HG002 minimap2` track drawn under the sequence. Click **Focus** to give that pane the whole viewport, and **Back** to return.

With the mapping result selected, the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window, shows a row of five tabs at its top, **Bundle**, **Selected Item**, **View**, **Analysis**, and **Provenance**. The **Bundle** tab describes the run and the reference bundle inside it. The **Analysis** tab is a separate tab that holds the tools acting on that bundle, such as Call Variants. [The mapping table](#the-mapping-table) reads the table, and [Reading an Alignment](02-reading-an-alignment.md) reads the picture in the pane.

### Naming the alignment track

A track is an alignment or variant file attached inside a reference bundle and drawn under its sequence, as the glossary entry for [track](../../GLOSSARY.md#track) says, and each track has a name you choose. LGE fills the **Track name (--track-name)** field with the mapper's name followed by "Mapping", so every run is called "minimap2 Mapping" unless you change it. A name that says whose reads these are, such as `HG002 minimap2`, tells two alignments apart in the track pickers of later dialogs and in the Variants table's `Variant Track` column, where each caller's track name starts from this one. This manual calls the HG002 track `HG002 minimap2` everywhere. The run's [provenance](../../GLOSSARY.md#provenance) records the name too.

### Import an alignment somebody else made

A BAM or CRAM file that already exists needs no mapping. LGE attaches it as a new track to the reference bundle the viewport shows, so first click the reference bundle the file was aligned against in the sidebar. Without one, LGE stops with the alert "No Bundle Loaded". Then open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. On its **Alignments** tab, click the **BAM/CRAM Alignments** card and choose the file, or drop the file on the card, which has no settings. LGE indexes the file, collects its per-chromosome and read-group statistics, and names the new track after the file, and its Operations Panel row runs `lungfish-cli import bam`.

## Settings

Every setting below appears for all four mappers. The mapper itself is not a setting, because the menu item or the tool list chooses it.

**Reference.** Names the genome the reads are lined up against, so every coordinate in the result is a position in this sequence. It defaults to the first reference LGE finds in the project, so check that it is the one you want, and **Browse…** picks a FASTA file from outside the project instead. Change it whenever the reads came from a different organism or strain than the one the picker chose, and read the path under the picker before you run. On the command line this is `--reference`.

**Preset.** Tells minimap2 what kind of sequence it is being handed, because short accurate reads and long, less accurate reads need different scoring rules. It starts on Short-read, or on the preset the first reads in the file suggest, and it stops choosing for you once you change it yourself. Match it to the machine that made your reads, using the table below, since a guess from the first few reads can be wrong. On the command line this is `--preset`.

**Mode.** Plays the part of Preset for BWA-MEM2, Bowtie2, and BBMap. BWA-MEM2 and Bowtie2 offer only Short-read, because both are built for Illumina reads, so a control with one choice is expected, while BBMap defaults to Standard. Choose BBMap's PacBio mode only for long PacBio reads thousands of bases long. On the command line this is `--preset`.

If your reads are Illumina, leave Preset on Short-read and skip this table and the paragraph after it. The table pairs each kind of read with its minimap2 preset and the token the command line uses for it. cDNA is DNA copied from RNA, so it carries spliced genes with their introns removed. A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads.

| Your sequences | Preset | `--preset` token |
|---|---|---|
| Illumina short reads | Short-read | `sr` |
| Oxford Nanopore long reads | Oxford Nanopore | `map-ont` |
| PacBio HiFi long reads | PacBio HiFi | `map-hifi` |
| Older PacBio CLR long reads | PacBio CLR | `map-pb` |
| cDNA mapped against a genome | Spliced CDS/cDNA | `splice` |
| Contigs from a closely related genome | Assembly-to-assembly | `asm5` |

Two presets have limits the names do not show. Assembly-to-assembly is minimap2's `asm5`, which the minimap2 manual reserves for genomes whose average difference is not much above 0.1 percent, about the difference between two people, so it does not suit macaque contigs against a human reference. Spliced CDS/cDNA is `splice`, meant for long cDNA reads and for direct-RNA reads, RNA read by a nanopore instrument without first being copied. The `lr:hq` preset for the most accurate recent nanopore reads is not offered, so use Oxford Nanopore for every nanopore run.

**Track name (--track-name).** Names the alignment track the BAM becomes inside the reference bundle inside the mapping result, a name every later track picker shows. The default is the mapper's name followed by "Mapping", such as "minimap2 Mapping", which says how the reads were placed but not whose reads they are. Type a name that identifies the sample, as [Naming the alignment track](#naming-the-alignment-track) explains. On the command line this is `--track-name`.

**Run Mode.** Appears only when you select more than one read bundle, and decides whether each bundle gets its own alignment or all of them are pooled into one. The default is **Run separately per bundle**, which keeps samples apart and gives each bundle its own read group, so the Read Group fields give way to the note "Each bundle gets its own read group, derived automatically from its sample name." Choose **Combine all inputs, run once** only when the bundles are pieces of one library, such as two lanes or two sequencing runs of the same tube, because the combined BAM cannot tell afterward which bundle a read came from. Different samples always belong in separate runs. This setting has no command-line flag.

You can skip this paragraph unless you pool bundles. A pooled run keeps each bundle's own read pairs and never pairs one bundle's reads with another's. It stops before mapping, and the failed row names the bundles, when they cannot share one run. That happens for pairs beside single reads, long reads beside short reads, pairs kept in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file beside pairs kept as R1 and R2 files, compressed files beside uncompressed ones, and bundles that each hold both pairs and single reads, such as merged reads. Map such bundles with **Run separately per bundle**. Two or more files from inside one bundle count as that bundle, which LGE reads once. Two loose FASTQ files named as the R1 and R2 of one sample, outside any bundle, are a different case. They map as a pair, and the copied command carries `--paired`.

The next five settings sit inside the collapsed **Read Group** disclosure. A [read group](../../GLOSSARY.md#read-group) is the `@RG` line in a BAM header that names the sample, library, instrument, and lane the reads came from, and every read in the file carries the ID of its read group. Joint variant callers, which call several samples at once, use it to tell samples apart, and duplicate marking uses it to tell libraries apart. LGE fills in every field, so for one sample mapped on its own, leave all five alone unless a downstream tool or a collaborator asks for a specific value. The flag in each label is the command-line name of that field, not something you type into the window.

**ID (--rg-id).** Writes the read-group identifier, the label each read carries to say which batch it belongs to. It defaults to the sample name and should not contain spaces, because some downstream tools mishandle them. Set it when you plan to merge this alignment with others and need each batch to stay distinguishable. On the command line this is `--rg-id`.

**Sample (--rg-sm).** Records which biological sample the reads came from, and joint variant callers treat every read group sharing one sample name as one individual. It defaults to the sample name LGE takes from the read bundle. Set it to your real specimen identifier when the bundle name is not one. On the command line this is `--rg-sm`.

**Library (--rg-lb).** Records which sequencing library the reads came from, where a library is one batch of DNA fragments prepared for the sequencer. It defaults to the sample name, which is right when each sample has one library, since [duplicate marking](../../GLOSSARY.md#mark-duplicates) only compares reads within one library. Set it when one sample was prepared as two libraries and you want duplicates judged within each. On the command line this is `--rg-lb`.

**Platform (--rg-pl).** Records the sequencing technology, which some variant callers use to choose an error model. LGE fills it from the preset, writing `ILLUMINA` for Short-read and BBMap Standard, `ONT` for Oxford Nanopore, `PACBIO` for the PacBio choices, `CDNA` for Spliced CDS/cDNA, and `ASSEMBLY` for Assembly-to-assembly, and it rewrites the field when you change the preset unless you typed your own value. Correct it when that value does not match your instrument. On the command line this is `--rg-pl`.

**Platform unit (--rg-pu).** Records the flow cell, the slide the sequencer reads, and the lane of it that the reads came off, the finest batch label a read group holds. It defaults to the sample name, because LGE has no flow-cell details to fill in. Fill it when you are chasing a problem confined to one lane and need to keep lanes apart. On the command line this is `--rg-pu`.

The last five settings sit inside the collapsed **Advanced Settings** disclosure. They decide which alignments survive into the finished BAM, and the defaults suit almost every run.

<!-- SHOT: mapping-wizard-advanced -->

**Threads.** Sets how many processor cores, the separate processors inside your Mac's chip, the mapper uses at once. The default is every core your Mac has, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run, at the cost of a slower run. On the command line this is `--threads`.

**Secondary alignments.** Keeps the [secondary alignment](../../GLOSSARY.md#secondary-alignment) records a mapper reports for other places a read could also have come from, and repeated regions produce many of them. Switched on, it asks Bowtie2 for up to 10 places per read and tells minimap2 and BBMap to report them, and BWA-MEM2 is given no option for it. Switched off, it drops every secondary record from the finished BAM. It is off by default, because secondary records inflate counts and confuse most downstream tools. Turn it on when you study repeats or gene families and need to see every plausible placement. On the command line this is `--secondary`.

**Supplementary.** Keeps the [supplementary alignment](../../GLOSSARY.md#supplementary-alignment) records of a read split across two places, one part here and the rest elsewhere, which is how a structural rearrangement such as a large deletion shows up in the reads. It is checked by default, so that split-read evidence stays in the file. Uncheck it only when a downstream tool fails on split records. On the command line this is `--no-supplementary`, the flag for the box unchecked.

**Min mapping quality.** Drops every read whose MAPQ falls below this number from the BAM itself, unlike the two later MAPQ controls that [Three MAPQ cutoffs](04-alignment-quality.md#three-mapq-cutoffs) compares. The default is 0, which keeps everything, and the control accepts 0 to 60. Raise it to about 20 when reads from repeats are landing in the wrong place, which [Alignment Quality](04-alignment-quality.md) shows how to see, and remember that one cutoff is stricter for some mappers than for others, as [What the four mappers give you on the same reads](#what-the-four-mappers-give-you-on-the-same-reads) explains. Any value above 0 also drops the unmapped reads, because their MAPQ is 0, so Total Unmapped then reads 0 and Total Reads falls by the same number, and Mapped Rate rises although no read was placed better. On the command line this is `--min-mapq`.

**Extra arguments.** Passes text straight to the mapper without LGE checking it. The default is empty, which is right for almost every run. Leave the box empty unless a protocol or the tool's own documentation gives you an option the dialog does not show. On the command line this is `--extra-args`.

LGE checks only that the Extra arguments text splits cleanly into separate options. Text it cannot split turns orange under the field and blocks Run.

## Reading the results

Click the `minimap2-` result under **Analyses**. The mapping viewport reports the run in its summary line and table, and the Inspector reports it on its **Bundle** tab, the first tab of its row. Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. The Bundle tab lists the run's own sections first, **Run Inputs**, **Run Settings**, **Alignment Tracks**, and **Output Files**. Below them sit **Alignment Summary**, **Read Groups**, and **Flag Statistics**, which describe the BAM itself.

To answer how many reads mapped, use Total Mapped in the Alignment Summary. Mapped Reads in Run Settings and the count in the summary line above the table are the same number, 90,935 on the fixture. A read is the sequence read from one fragment, or from one end of it, and a record is one row of the BAM. Most reads get exactly one record, called the [primary alignment](../../GLOSSARY.md#primary-alignment). Suppose the mapper splits one read across two places. That read gets its primary record and also a supplementary record, so it is one read and two records. The mapping table, Run Settings, and the Alignment Summary count it once, while most Flag Statistics rows count both records.

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

For the fixture's one row, Mapped Reads is 90,935, Mean Depth is 44.7, Coverage Breadth is 100.0 percent, Median MAPQ is 60.0, and Mean Identity is 99.4 percent. This manual gives no cutoff for good values in these columns. For your own data, compare a sequence with the other rows and a sample with other samples mapped the same way, and look first at a row far from the rest.

A reference sequence with no alignments at all is left out of the table. A reference made from a whole genome often lists the chromosomes and then many short unplaced contigs, so most of its sequences can have no reads. When the reference holds more than one sequence and some have none, the summary line adds a count such as "94 of 905,628 reference sequences have alignments". Hold the pointer over that count to see how many sequences were left out of the list.

<!-- SHOT: mapping-summary-bar-reference-count -->

### The Alignment Summary

<!-- SHOT: alignment-inspector-stats -->

The Alignment Summary counts reads, taken from samtools' tally of the BAM. The Inspector shortens a count of 1,000 or more to thousands with one decimal place, and a count of a million or more to millions, so 90,935 reads show as 90.9K.

| Label | What it counts | Fixture value |
|---|---|---|
| Track | The alignment track the counts describe | HG002 minimap2 |
| Total Mapped | Reads placed on the reference, each read counted once | 90.9K, which is 90,935 |
| Total Unmapped | Reads the mapper could not place | 213 |
| Mapped % | Total Mapped as a share of all reads, drawn as a bar beneath | 99.8% |
| Chromosomes | Reference sequences the BAM names | 1 |
| Mean Depth | The measured mean depth over the one reference sequence | 44.7x |

Mean Depth comes from `samtools coverage`, which counts the placed reads over every position and averages over the whole sequence. It leaves out secondary records, supplementary records, and marked duplicates. It is the same figure as the mapping table's Mean Depth and the sequence's `meanDepth` value in `mapping-result.json`. The row appears only when the reference holds a single sequence, and it can appear a moment after the other rows.

For a reference of many sequences, such as a whole genome, the mapping table's Mean Depth column gives one figure for each sequence, and LGE shows no overall figure. To make one, multiply each row's Mean Depth by its Length, add the products, and divide by the sum of the Lengths. That average counts only the sequences in the table, so it leaves out any sequence that had no reads. How much depth a task needs depends on the task. This manual's rule of thumb, from its [Depth](../../GLOSSARY.md#depth) entry, is at least about 10 reads at a position for a confident variant call, and a mean of about 30 across a human genome. [The coverage curve](02-reading-an-alignment.md#the-coverage-curve) shows how to read depth position by position.

Output Files lists the file as **Mapping Result**, a link that reveals `mapping-result.json` in Finder, and the file opens in any text editor.

A track whose statistics hold no read counts shows alignment records instead. Its labels then end in (alignments), such as **Total Mapped (alignments)**, and a note under them says to run the mapping or import the alignment again to count its reads. The summary line says alignments mapped rather than reads mapped.

### Run Settings

Run Settings, on the **Bundle** tab, lists the mapper, the preset, the main settings you chose, the mapper and samtools versions, and four counts from `mapping-result.json`. These four count reads, as the Alignment Summary does.

| Row | Fixture value |
|---|---|
| Mapped Reads | 90935 |
| Unmapped Reads | 213 |
| Total Reads | 91148 |
| Mapped Rate | 99.8% |

Total Reads matches the 91,148 reads you imported, which is the first thing to check after any run. Mapped Reads matches the Alignment Summary's Total Mapped, since both count reads.

The Paired End row reads `Yes (interleaved)` for this run, because the bundle keeps both mates in one interleaved file, each read followed by its mate, and all four mappers pair such a file. On a bundle that mixes merged reads with pairs, the row reads `Yes (pairs; merged reads mapped as single reads)` for all four mappers, as [Choosing a tool](#choosing-a-tool) explains.

Below the rows, Run Settings lists each command the run ran, under its tool's name, such as minimap2 or samtools sort. Click a step's arrow to show the whole command. The copy icon beside a step copies that step, and **Copy All Steps** copies every step with every path in full, so the commands also run outside the project.

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

A read is [properly paired](../../GLOSSARY.md#properly-paired) when its mate landed on the same sequence, facing it, at about the distance the fragments in the [library](../../GLOSSARY.md#library) were cut to. On this fixture most fragments are shorter than 500 bases, as the Bowtie2 note below says, and 90,414 of 91,148 reads are properly paired, 99.19 percent, the mark of a clean library. Rows such as secondary and duplicates read 0 for this run, because the default settings drop secondary records and nothing has marked duplicates yet.

### What the four mappers give you on the same reads

Skip this section unless you are comparing mappers. All four mappers ran on the identical fixture with their default settings, each handed the interleaved bundle as pairs. The first three number columns count alignment records, as Flag Statistics does. Records is the Flag Statistics total, Mapped records counts the records placed, and Mapped % is their share of all records. Properly paired is the Flag Statistics share described above. Median MAPQ is the middle MAPQ of all placed reads, so half scored above it and half below.

| Mapper | Records | Mapped records | Mapped % | Properly paired | Mean depth | Median MAPQ |
|---|---|---|---|---|---|---|
| minimap2 | 91,203 | 90,990 | 99.77% | 99.19% | 44.7x | 60 |
| BWA-MEM2 | 91,322 | 91,244 | 99.91% | 99.76% | 44.8x | 60 |
| Bowtie2 | 91,148 | 90,241 | 99.00% | 82.22% | 44.8x | 42 |
| BBMap | 91,148 | 90,655 | 99.46% | 98.91% | 45.0x | 45 |

The record counts differ because the mappers disagree about how many split reads to report. minimap2 wrote 55 supplementary records and BWA-MEM2 wrote 174, while Bowtie2 and BBMap wrote none and so land on the input's own 91,148 records, one per read. Take a mapper's supplementary records away from its Mapped records and you have its mapped reads, such as 90,990 less 55, or 90,935 reads, for minimap2.

Bowtie2's low properly paired share is a setting, not a failure. By default it accepts a pair only when the fragment is at most 500 bases long, its `-X` option, and about 15 percent of this library's fragments are longer, judged from the minimap2 alignment. Both mates of such a pair are still placed, so Mapped records hardly moves. If you do not know your library's fragment length, ask whoever prepared it, and type `-X 1000` in Extra arguments when a Bowtie2 run reports far fewer proper pairs than you expect.

Median MAPQ is where they part company, and the reason is scaling, not placement. Each mapper puts its confidence on its own scale. minimap2 and BWA-MEM2 give a clear placement 60, Bowtie2's scale stops at 42, and BBMap's median was 45 on these reads. A Min mapping quality cutoff therefore means different things for different mappers. A cutoff of 20 is a mild filter under minimap2 or BWA-MEM2 and a stricter one under Bowtie2 or BBMap, so set any cutoff against the mapper you ran and never compare MAPQ values between mappers.

For clean human short reads against the right reference, the choice of mapper barely matters to the result, and [Choosing a tool](#choosing-a-tool) covers what does differ.

## What good looks like

Check the mapping rate against the reference you chose. For human reads against the matching human reference, Mapped Rate sits above 99 percent on this clean fixture, and all four mappers clear that. This manual has no source for a normal range on a whole real sample, so compare yours with other samples mapped the same way, and a rate far below them is the cue to check the reference first. A rate under 50 percent usually means the wrong reference, so confirm the bundle really is the genome you sequenced. A preset mismatch is the second suspect, since nanopore reads run through the Short-read preset mostly fail to map. A third cause applies to samples that hold more than one organism, such as a swab where a pathogen sits among human reads, because only the fraction matching your reference maps. [What Is Read Classification](../06-classification/01-what-is-classification.md) shows how to find out what a sample holds.

Check the totals against your read count. Total Reads in Run Settings should equal the reads you imported, and the Flag Statistics total should equal that count plus the supplementary and secondary records, never less, so 91,148 reads and 55 supplementary records give 91,203 here. A total below your read count means reads were dropped, which happens when Min mapping quality was raised above 0.

Check the pairing when the reads are paired. Properly paired near 100 percent is healthy. Two loose FASTQ files mapped as a pair are compared before anything runs, and a run that stops with "Paired FASTQ mates do not match" or "Paired FASTQ mates are out of step" names its own cause. The first means the two files hold different numbers of reads, so copy or download both again in full. The second means they list reads in different orders, so use two files from the same run that neither was sorted nor cut down on its own. A failed run turns its row red and opens an alert that names the failed step, says what happened, and suggests what to try. [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from the row.

Check depth with Mean Depth, or with the length-weighted figure that [The Alignment Summary](#the-alignment-summary) describes for a whole genome. The fixture's 44.7x is comfortable for calling variants in a human sample.

The run's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads, holds the command and every tool version. If a re-run after a plugin pack update gives a slightly different BAM, compare the Mapper Version rows in Run Settings first. A new mapper release can move a [soft clip](../../GLOSSARY.md#soft-clip), a stretch at a read end that stays in the file but is left out of the pileup, by a base or two. It is written as `S` in the read's [CIGAR](../../GLOSSARY.md#cigar) string, as [The CIGAR string](../01-foundations/04-alignment-files.md#the-cigar-string) explains, and the change is harmless for variant calling.

## On the command line

Skip this section if you work in the LGE window, because it uses a terminal, a text window that runs typed commands. The block below maps the demo project's reads exactly as the procedure does, following the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Every flag of `map` is listed in [Mapping and alignment tracks](../appendices/cli-reference.md#mapping-and-alignment-tracks) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"

lungfish-cli map "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq" \
  --reference "$PROJECT/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref" \
  --project "$PROJECT" \
  --mapper minimap2 --preset sr \
  --track-name "HG002 minimap2"
```

With `--project`, the command writes the same result the window writes, a `minimap2-<timestamp>` folder under `Analyses/` holding the BAM and the reference bundle inside the mapping result with the `HG002 minimap2` track attached, and it prints the folder's path at the end. It reads the pairing from the read bundle, as the window does, so a bundle needs no `--paired`. Two loose FASTQ files do need `--paired`, because without it the command maps them as unrelated single reads, and `--paired` refuses any number of files other than two. `--no-viewer-bundle` leaves out the reference bundle copy when you want only the BAM.

Every Map Reads run in the window is this same command. **Copy CLI Command** on the run's row in the Operations Panel copies it with every value the window chose spelled out, including `--output-dir`, `--sample-name`, the five read-group flags, and `--threads`. That copy ends in `--format json`, which makes the command print one line of JSON for each progress event, for LGE to read. Leave that flag off to get the readable report.

The track's BAM sits inside the copy as `alignments/aln_` followed by eight letters and digits and `.sorted.bam`, such as `aln_93ACDFDA.sorted.bam`, and the mapper's own copy of the BAM stays at the top of the result folder as `HG002.chr20.10.0-10.5Mb.sorted.bam`. The track's copy is an APFS clone of that file, a copy the Mac's file system shares with the original until one of them changes, so it takes almost no extra disk space. On a disk that cannot make clones, LGE writes a full copy instead. The eight characters, the track's identifier, differ on every run, and later command-line chapters take them from `lungfish-cli bundle list` or from the `Track ID` line `lungfish-cli map` prints.

## Next

Continue to [Reading an Alignment](02-reading-an-alignment.md) to open the BAM in the alignment viewport and read the pileup you just built.
