---
title: Mapping Reads to a Reference
chapter_id: 04-alignments/01-mapping-reads-to-a-reference
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 01-foundations/04-alignment-files, 03-reads/01-importing-fastq]
estimated_reading_min: 25
task: Map sequencing reads onto a reference genome and attach the resulting BAM to the reference bundle as an alignment track.
tags: [alignments, mapping, minimap2, bwa-mem2, bowtie2, bbmap, illumina, nanopore]
tools: [minimap2, bwa-mem2, bowtie2, bbmap, samtools]
parameters_refs: [map.minimap2, map.bwa-mem2, map.bowtie2, map.bbmap, import.bam]
entry_points:
  - "Tools > Mapping > minimap2..."
  - "Tools > Mapping > BWA-MEM2..."
  - "Tools > Mapping > Bowtie2..."
  - "Tools > Mapping > BBMap..."
  - "File > Import Center... (Cmd-Shift-I) > Alignments > BAM/CRAM Alignments"
  - "CLI: lungfish-cli map, lungfish-cli bam adopt-mapping, lungfish-cli import bam"
shots:
  - id: tools-mapping-submenu
    caption: "The open Tools > Mapping submenu, showing its five items, minimap2..., BWA-MEM2..., Bowtie2..., BBMap..., and Viral Recon...."
  - id: mapping-wizard-overview
    caption: "The Map Reads (minimap2) wizard with the HG002 reference and the Short-read preset chosen, the Input Compatibility readout reporting a match, and the collapsed Read Group and Advanced Settings disclosures beneath it."
  - id: mapping-wizard-advanced
    caption: "The Advanced Settings disclosure of the mapping wizard, expanded to show the Threads, Secondary alignments, Supplementary, Min mapping quality, and Extra arguments controls."
  - id: alignment-inspector-stats
    caption: "The Inspector for the new alignment track, showing Total Mapped, Total Unmapped, Mapped %, Chromosomes, and Est. Coverage above the collapsed Flag Statistics list."
illustrations: []
glossary_refs: [bam, mapping, alignment, mapper, soft-clip, supplementary-alignment, mapq, read-group, flagstat, primary-alignment, secondary-alignment, properly-paired, coverage-breadth, mapping-preset, plugin-pack, reference-bundle, provenance]
features_refs: [map]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Mapping takes two things, a collection of sequencing reads and a reference genome, and works out where along that reference each read came from. A read is one short stretch of sequence the instrument reported, a few hundred bases long for the data in this chapter. Lungfish Genome Explorer (LGE) records the answer as a [BAM](../../GLOSSARY.md#bam) file, a compressed binary container holding one row per aligned read. Each row carries the read's sequence, the reference position it was placed at, which strand it matched, and a confidence score called [MAPQ](../../GLOSSARY.md#mapq) saying how sure the program was about the placement.

The program that does the placing is called a [mapper](../../GLOSSARY.md#mapper). LGE ships four of them, minimap2, BWA-MEM2, Bowtie2, and BBMap, and minimap2 is the default. Every one of them takes the same inputs and writes the same kind of BAM, so switching mappers changes the answers a little rather than changing what you get back. On the worked example below, the four mappers land within one percentage point of each other, and the comparison table under Reading the results shows exactly how far apart they sit.

Two things about the output matter for everything that follows. The BAM comes out sorted by reference position, so the rows run in genome order rather than in the order the reads arrived. It also comes out with a companion index file beside it, ending in `.bai`. LGE writes that index for you and keeps it next to the BAM inside the project, so you never create it, open it, or move it yourself. The index is what lets a viewer jump straight to any coordinate without reading the whole file, which is why the alignment viewport can show you position 250,000 of chromosome 20 instantly rather than after a long scan.

The entry point in the window is a two-part choice. You select the reads in the sidebar first. Then you choose a mapper from **Tools > Mapping**, which opens the wizard already knowing both facts. The reads come from your sidebar selection, and the mapper comes from the menu item you chose. Neither is a control inside the wizard, which is the part that catches people out.

In practice, with reads and a reference already in your project, select the reads, choose the mapper from the Tools menu, set the reference and the preset, and click Run.

## Why you would do this

Reads on their own tell you almost nothing. A single 250-base read from a human sample is a fragment of sequence with no address. It could be from chromosome 20, or from a repeat, a stretch of sequence the genome carries in many near-identical copies. Identical copies give the mapper no way to choose between them, and nothing in the FASTQ file says which copy the read came from. Mapping gives every read an address, and once reads have addresses you can stack them.

Stacking is what makes the rest of this manual possible. When forty reads all sit over the same position and thirty-eight of them read A where the reference reads G, that is evidence of a real difference between your sample and the reference rather than one instrument error. Variant calling, consensus building, coverage checking, and primer trimming all read that stack. None of them can run until mapping has built it.

This chapter works through the HG002 chromosome 20 slice, a pair of Illumina read files from a well-characterized human genome. The slice holds 45,574 read pairs. A read pair is two reads sequenced from the two ends of one DNA fragment, so 45,574 pairs is 91,148 reads in total. They are drawn from a 500 kb window of chromosome 20, where kb means kilobases, so the window is 500,000 bases long. Its matching reference file holds that same window and nothing else, which is why the run finishes quickly rather than taking as long as a whole human genome would. Every number this chapter quotes came from a real run of the four mappers on 2026-09-06.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice, which is a fixture, the sample data set this manual works its examples against. Download the files `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. On that page, click a filename and then the Download raw file button, since the page itself only previews the file. No GitHub account is needed to download them.

Both pieces have to be inside the project before the wizard will run. Import the two FASTQ files as described in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md), and import the FASTA as a reference, which [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) covers. Importing the FASTA produces a [reference bundle](../../GLOSSARY.md#reference-bundle), a `.lungfishref` folder under the project's `Reference Sequences/`. The Finder shows that folder as a single item rather than something you open, which is normal on a Mac. The bundle is what the mapping result will be attached to, so it is the thing you need, not the loose FASTA.

Three of the four mappers, minimap2, BWA-MEM2, and Bowtie2, arrive in the `read-mapping` [plugin pack](../../GLOSSARY.md#plugin-pack), which LGE installs on request rather than up front. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and install that pack before you start. Installing downloads the three programs, so you need an internet connection, and the Plugin Manager shows progress while it works. BBMap is the exception. It comes from the BBTools environment in the Required Setup pack, so it is present as soon as a project can open at all.

## Procedure

The wizard has five sections stacked top to bottom, **Reference**, **Preset**, **Read Group**, **Input Compatibility**, and **Advanced Settings**. minimap2 titles the second section **Preset** and the other three mappers title the same section **Mode**, so you will see one name or the other on your own screen, never both. The two sections the wizard always asks you for are the reference and the preset. Read Group and Advanced Settings sit below them as collapsed disclosures, and both are optional, since every default inside them is sensible for an ordinary run. The numbered steps below therefore touch only three of the five sections.

Skip the next paragraph if you selected only one read bundle, which is what the steps below assume. A read bundle is the sidebar item holding one sample's imported reads.

Select more than one read bundle before you open the wizard and a sixth section appears between Preset and Read Group, asking whether to run each bundle separately or pool them into one. In that state the editable Read Group fields are replaced by a note reading "Each bundle gets its own read group, derived automatically from its sample name."

<!-- SHOT: tools-mapping-submenu -->

1. In the sidebar, click the `HG002.chr20.10.0-10.5Mb` read bundle so it is the selected item.
2. Choose **Tools > Mapping** from the menu bar, then choose the mapper you want, **minimap2...** (the default), **BWA-MEM2...**, **Bowtie2...**, or **BBMap...**. The wizard opens, titled "Map Reads (minimap2)" for the default choice.
3. Under **Reference**, click the picker and choose `GRCh38.chr20.10.0-10.5Mb`. The picker lists every reference bundle already in the project, and the path of the one you picked appears beneath it. To map against a FASTA that is not in the project, click **Browse...** below the picker and select the file instead.
4. Under **Preset**, leave it on **Short-read**. The wizard already chose it for you by reading the first reads in the file. Change the setting yourself and the wizard stops guessing, so your choice stands for the rest of this wizard session no matter what else you touch.
5. Check the **Input Compatibility** readout below the preset. A good reading ends in a line beginning with the word Ready. Then click **Run**.

<!-- SHOT: mapping-wizard-overview -->

The Input Compatibility readout is the check worth pausing on. It prints three lines describing what LGE found in your reads, followed by a verdict. For the fixture with minimap2 it reads exactly this.

```text
Detected format: FASTQ
Detected reads: Illumina short reads
Observed max read length: 250 bp
Ready: minimap2 is compatible with Illumina short reads.
```

When the preset and the reads do not agree, the verdict line turns into a refusal instead of that Ready sentence, and the Run button stays disabled until you fix the mismatch.

Once you click Run, the wizard closes and a row appears in the Operations panel at the bottom of the project window, labelled `Map Reads (minimap2): HG002.chr20.10.0-10.5Mb`. Open the panel with **Operations > Show Operations Panel** (Cmd-Shift-P) if it is not already showing. Expand the row and you see the underlying pipeline with its resolved command line at each step. For minimap2 that is five steps, the mapper itself, then `samtools view` to drop records, then `samtools sort`, `samtools index`, and `samtools flagstat`. The records the filter drops are the ones the Advanced Settings you chose exclude, so with the defaults it drops secondary alignments and keeps everything else. The mapper writes a SAM file, which is the plain-text form of a BAM holding the same rows uncompressed. The filter step consumes it and the pipeline then deletes it, so the intermediate never lands in your project.

When every step turns green, the alignment track has been attached to the reference bundle. A step that fails turns red instead and stops the run, leaving its error text in the expanded row. Expand the reference bundle in the sidebar and the new track sits under it, named "minimap2 Mapping", the mapper's name followed by the word Mapping. You can rename it. The mapping run's own output folder sits under the project's `Analyses/`, in a subfolder named for the mapper followed by the date and time the run started, such as `Analyses/minimap2-2026-09-06T13-45-12/` for a run at 13:45:12 on 6 September 2026.

## Settings

Every setting below appears in all four mapping wizards, which are the same sheet with a different header and a different set of preset choices. The mapper is not one of the settings, because the menu item you clicked already chose it.

**Reference.** Names the genome the reads are lined up against, and every coordinate in the resulting alignment is a position in this sequence, so a different reference gives entirely different coordinates. It defaults to the first reference the app finds in the project, which is a convenience rather than a judgement, and it accepts any reference sequence in the project or a FASTA you pick with Browse.... Change it whenever the reads came from a different organism or a different strain than the one the picker happened to select first, and read the path the wizard prints under the picker to confirm you have the right one before you run. On the command line this is `--reference`.

**Preset.** Tells minimap2 what kind of sequence it is being handed so it can pick scoring rules that match. Long-read machines trade accuracy for length, so short accurate reads and long noisy reads need very different error tolerances. It defaults to Short-read, and it offers Short-read, Assembly-to-assembly, Spliced CDS/cDNA, Oxford Nanopore, PacBio HiFi, and PacBio CLR, of which only Short-read applies to Illumina data. Match it to the machine that made your reads rather than to the organism, since the wizard only guesses from the first reads in the file and the guess can be wrong. On the command line this is `--preset`.

**Mode.** Is the same control under a different name, shown by BWA-MEM2, Bowtie2, and BBMap in place of minimap2's Preset. For BWA-MEM2 and Bowtie2 it defaults to Short-read and offers nothing else, because both programs are built for Illumina-length reads, so a picker holding one option is expected rather than a sign that anything failed to load. For BBMap it defaults to Standard and offers Standard and PacBio, and you switch to PacBio when the reads came off a PacBio instrument and are thousands of bases long. On the command line this is `--preset`.

**Run Mode.** Decides whether several selected read sets each get their own alignment or all get poured into one. Combine only when the selected files really are pieces of one library, for example two sequencing runs of the same tube, because pouring them together loses any way to tell which read came from which sample and the automatic per-bundle read groups apply only to separate runs. It defaults to Run separately per bundle, which is almost always what you want, and the alternative is Combine all inputs and run once. This setting has no command-line flag. `lungfish-cli map` already treats all the inputs of one invocation as one sample's reads, so you run it once per sample instead.

The next five settings sit inside the collapsed **Read Group** disclosure. A [read group](../../GLOSSARY.md#read-group) is a labelled block in the BAM header, written as an `@RG` line, saying which sample, library, instrument, and lane the reads came from. LGE fills in every field for you, so the five entries below are reference material. Read them only when a downstream tool asks you for a specific value. Tools that group reads by sample read these fields, joint variant callers among them, which are callers that examine several samples at once instead of one at a time. The bracketed flag in each label is the command-line name of that field, not something you type into the window.

**ID (--rg-id).** Writes a read-group identifier into the alignment file so downstream tools can tell one batch of reads from another, and it is a label rather than a filter. It defaults to the sample name taken from the input file, and it accepts any text without spaces, since the BAM header format uses whitespace to separate one field from the next and a space here would split the value in two. Set it when you plan to merge this alignment with others and need each batch to stay distinguishable. On the command line this is `--rg-id`.

**Sample (--rg-sm).** Records which biological sample the reads came from, and joint variant callers group reads by this field, so two files sharing a sample name are treated as one individual. It defaults to the sample name taken from the input file, and it accepts any text. Set it to your real specimen identifier when the file name is not one. On the command line this is `--rg-sm`.

**Library (--rg-lb).** Records which sequencing library the reads came from, which is what duplicate marking compares against. Duplicate marking is the later step that flags reads which are copies of one original fragment rather than independent evidence, and two reads can only be copies if they came from the same library. It defaults to the sample name taken from the input file, and it accepts any text. Set it when one sample was prepared as two separate libraries and you want duplicates judged within each. On the command line this is `--rg-lb`.

**Platform (--rg-pl).** Records the sequencing technology, and some variant callers change their error model based on it. It is filled in from the preset you chose rather than left blank, so a short-read preset writes `ILLUMINA`, Oxford Nanopore writes `ONT`, the PacBio presets write `PACBIO`, splice mode writes `CDNA`, and assembly mode writes `ASSEMBLY`. The value shows in this field while the wizard is open, and after the run it lives only inside the BAM header. Correct it when the preset guessed a platform that does not match your instrument. Change the preset afterwards and the field rewrites itself to the new preset's value, but only while it still holds the old preset's value, so anything you typed in yourself is left alone. On the command line this is `--rg-pl`.

**Platform unit (--rg-pu).** Records the exact flow cell and lane the reads came off, which makes it the finest-grained batch label in the read group. It defaults to the sample name taken from the input file, and it accepts any text. Fill it when you are chasing a run-specific artifact and need to separate lanes. On the command line this is `--rg-pu`.

The last five settings sit inside the collapsed **Advanced Settings** disclosure. They decide which alignments survive into the finished BAM and let you hand raw options to the mapper. The defaults suit almost every run.

<!-- SHOT: mapping-wizard-advanced -->

**Threads:.** Sets how many pieces of the mapping job run at the same time, so more threads finish sooner but leave less of the machine for anything else. The wizard already fills in the right number for your own Mac, which is its count of processor cores, and the stepper will not let you set more, so there is nothing to look up. Lower it when you want to keep working in other applications while a large run finishes. On the command line this is `--threads`.

**Secondary alignments:.** Keeps the extra places a read could also have come from rather than only its best one, and repeated regions produce many of these. The checkbox is off by default, because a [secondary alignment](../../GLOSSARY.md#secondary-alignment) inflates read counts and confuses most downstream tools. Turn it on when you are studying repeats or gene families and need to see every plausible placement. Each mapper asks for them in its own way, and LGE sets the right option for whichever mapper you chose and records it in the run's provenance file, so there is nothing for you to type. On the command line this is `--secondary`.

**Supplementary:.** Keeps the leftover pieces of a read that spans a break, where one part lands in one place and the rest lands elsewhere, which is the signature of a structural rearrangement. Ticked keeps those [supplementary alignments](../../GLOSSARY.md#supplementary-alignment) and unticked drops them, and the box is ticked by default, so the default preserves the split-read evidence. Turn it off only when a downstream tool chokes on split records. On the command line this is `--no-supplementary`, which is worded the opposite way round to the checkbox, since passing it drops the records that leaving the box ticked keeps.

**Min mapping quality:.** Throws away any read the mapper was not confident it placed correctly, judged by [MAPQ](../../GLOSSARY.md#mapq), the per-read confidence score where 0 means the mapper could not choose between two or more locations and 60 means it found one clearly best location. It defaults to 0, which keeps everything, and the stepper accepts 0 to 60 whichever mapper you chose, though 60 is reached in practice only by minimap2 and BWA-MEM2, while Bowtie2 and BBMap scale their scores lower and top out below it. Raise it to about 20 when repeated sequence is putting reads in the wrong place, which shows in the viewport as a pile of low-MAPQ reads over one spot carrying variants that no neighbouring region supports. On the command line this is `--min-mapq`.

**Extra arguments.** Passes options straight through to the mapper untouched, and nothing in the app checks that they make sense. It is empty by default, and it accepts any option of the mapper you chose, written the way you would type it at a command line. Use it only when a published protocol names a flag the wizard does not expose, and watch the field as you type, because LGE checks the text on every keystroke and unreadable text both blocks Run and appears as an orange message in the footer, the strip along the bottom edge of the sheet. On the command line this is `--extra-args`.

The field's placeholder text is the fastest hint at what each mapper accepts. It reads `--eqx -N 5` for minimap2, `-M -Y` for BWA-MEM2, `--very-sensitive -N 1` for Bowtie2, and `minid=0.97 local=t` for BBMap.

For the record, the option LGE adds for you when Secondary alignments is ticked differs by mapper, `-k 10` for Bowtie2 and `secondary=t` for BBMap rather than one shared flag. You never type either one.

### Importing an alignment somebody else made

An alignment that already exists as a BAM, CRAM, or SAM file does not need mapping at all. Use **File > Import Center...** (Cmd-Shift-I), open the Alignments tab, and drop the file on the BAM/CRAM Alignments card. That card has no settings beyond the file panel, so there is nothing to configure. The importer indexes the alignment, collects per-chromosome and per-read-group statistics, and works out which reference assembly the file's own header declares, without asking you to confirm it. A CRAM stays a CRAM, sorted and indexed in place with a `.crai` index beside it, and only a SAM is normalised to a sorted, indexed BAM. On the command line this is `lungfish-cli import bam`, which takes `--name` to set the track's display name and `--output-dir` to name the project it lands in.

## Reading the results

Click the new alignment track in the sidebar and the Inspector fills with statistics measured from the finished BAM.

<!-- SHOT: alignment-inspector-stats -->

Five numbers sit at the top. Total Mapped is how many alignment records were placed on the reference. A record is one row of the BAM, and it is not quite the same thing as a read, because a read that the mapper splits across two places contributes two rows. The Flag Statistics list below settles the difference for this fixture. Total Unmapped is how many records were not placed. Mapped % is the first as a percentage of the two together, drawn as a bar beneath the figure. Chromosomes counts the reference sequences the BAM's header names, which is 1 for this fixture because the reference holds only the chromosome 20 slice. Est. Coverage is a rough estimate of average depth across that sequence, and it appears only when the alignment has a single contig, so a whole-genome reference shows no such row. It is worked out as the mapped record count times an assumed read length of 150 bases, divided by the length of the reference. On 250-base reads such as this fixture's it therefore understates the real depth by about two fifths, which is a defect in this release rather than a fact about your data.

For the fixture mapped with minimap2 those five read 90,990, 213, 99.8%, 1, and 27.3x. Depth is the number of reads covering a single position, and it is a different measurement from breadth, which counts how many positions carry any read at all. The true mean depth on the HG002 slice is 44.7x, which the `mapping-result.json` described below and the coverage label in the alignment viewport both report, and it sits inside the 30x to 50x band a human genome project usually aims for. Read the Inspector's 27.3x as the 150-base estimate of that same figure. A region under 10x is too thin to call a variant with confidence.

Below the five sits a collapsed **Flag Statistics** list. Expand it for the raw [flagstat](../../GLOSSARY.md#flagstat) categories, meaning the counts `samtools flagstat` produces by tallying the flag bits on every record. Flag bits are a small set of yes-or-no markers each record carries, recording things like whether the record was placed at all and whether its mate landed nearby. Four of the categories are worth reading. Here is the whole set for the fixture run, and the numbers behind the paragraph that follows.

| Flag Statistics category | Count for the fixture |
|---|---|
| total | 91,203 |
| primary | 91,148 |
| supplementary | 55 |
| primary mapped | 90,935 |
| properly paired | 90,414 |

Read them in that order. The total of 91,203 is larger than the 91,148 reads you imported, which looks wrong until you notice the supplementary row. Fifty-five reads were split across two places on the reference and so contributed a second record each. Subtracting those gives 91,148, the [primary alignments](../../GLOSSARY.md#primary-alignment), which is one record per read and the honest count of the reads themselves. Of those, 90,935 were placed somewhere. The same 55 supplementary records explain why that figure sits below the Inspector's Total Mapped of 90,990, since Total Mapped counts every placed record and primary mapped counts only one per read. Each is 99.77% of its own total, 90,935 out of 91,148 primary records and 90,990 out of 91,203 records overall, so the two percentages agree to two decimal places without being the same fraction. The [properly paired](../../GLOSSARY.md#properly-paired) count of 90,414 is how many pairs landed at a sensible distance apart and pointing at each other as the library preparation intended. Out of the 91,148 paired reads that is 99.19%, a sign of a clean library.

Every mapping run also writes a `mapping-result.json` beside the BAM, in the run's own folder under `Analyses/`, carrying figures the Inspector does not show. Among them is [coverage breadth](../../GLOSSARY.md#coverage-breadth), the fraction of reference positions with at least one read on them. For this run it is 99.994%, meaning almost every position of the 500 kb slice carries reads. To reach it without a terminal, right-click the alignment track in the sidebar, choose Show in Finder, and read the file in any text editor.

### What the four mappers give you on the same reads

All four ran on the identical fixture with their default settings. The table records what each returned, so you can see how much the choice actually moves. Median MAPQ is the middle confidence score of all the placed reads, so half the reads scored above it and half below. The Records column counts every record the mapper wrote, unmapped ones included, which is why Bowtie2's 91,148 records still contains 907 reads it could not place. Your own run's median MAPQ is in the `mapping-result.json` described above rather than in the Inspector.

| Mapper | Records | Mapped | Mapped % | Mean depth | Median MAPQ |
|---|---|---|---|---|---|
| minimap2 | 91,203 | 90,990 | 99.77% | 44.7x | 60 |
| BWA-MEM2 | 91,317 | 91,239 | 99.91% | 44.8x | 60 |
| Bowtie2 | 91,148 | 90,241 | 99.00% | 44.8x | 42 |
| BBMap | 91,148 | 90,658 | 99.46% | 45.0x | 45 |

The record counts differ because the mappers disagree about how many split reads to report. minimap2 emitted 55 supplementary records and BWA-MEM2 emitted 169, while Bowtie2 and BBMap emitted none at all and so land on the input's own 91,148. The mapped percentages sit within a percentage point of each other, and mean depth is the same to within a third of a read. What separates them here is median MAPQ, where minimap2 and BWA-MEM2 both reach 60 while Bowtie2 reports 42 and BBMap 45, because the four programs scale that confidence score differently rather than because their placements are worse. That scaling is why a Min mapping quality cutoff does not mean the same thing across all four. A cutoff of 20 is a mild filter under minimap2 or BWA-MEM2 and a harsher one under Bowtie2 or BBMap, so set it against the mapper you actually ran.

The practical reading is that on clean human short-read data against a correct reference, the mapper choice barely matters. minimap2 is the default and is a defensible pick for almost any project. BWA-MEM2 is what most production human resequencing pipelines call, so reach for it when you are reproducing one. Bowtie2 is worth naming when a published protocol names it. BBMap tolerates more sequence error, so it is worth a second run when another mapper reports a mapping rate you did not expect.

## What good looks like

Four checks tell you a mapping run went the way you meant it to.

Confirm the mapping rate against the reference you chose. For human reads against the matching human reference, Mapped % should sit above 99%, and all four mappers clear that on the fixture. A rate under 50% almost always means the wrong reference, so confirm the bundle really is the genome you sequenced rather than a related organism. A preset mismatch is the second possibility, since Oxford Nanopore reads run against the Short-read preset mostly fail to map because the error profile is wrong. The third applies once you move past a clean human sample like this one. A sample that holds more than one organism, such as a swab where a pathogen sits in a background of human reads, maps only the fraction that matches whichever reference you chose. Run classification first to find out what is actually in the sample, which [What Is Read Classification](../06-classification/01-what-is-classification.md) covers.

Confirm the depth is enough for what comes next. A mean depth of 44.7x on this fixture is comfortable for variant calling, and the Inspector's Est. Coverage of 27.3x is the same run seen through the 150-base assumption. Anything under about 10x leaves too little evidence to separate a real difference from an instrument error.

Confirm the total against your read count. The Flag Statistics total should equal the reads you imported plus however many supplementary records the mapper emitted, and never less. A total well below your read count means reads were dropped, which happens when Min mapping quality was raised or when the reads and the reference genuinely do not correspond.

Confirm the paired counts when the reads are paired. Properly paired near 100% is healthy. A failed run shows as a red row in the Operations panel, and expanding it prints the failure text, which for a pairing problem names mismatched read names or different read counts in the two files. That is the mark of a truncated download, a file that opens and looks complete but stops short of its full length with no error to warn you. Compare the file size against the figure the download page lists, or simply download the pair again from its original source and re-import it.

Two more habits are worth keeping. LGE records the resolved tool version in the [provenance](../../GLOSSARY.md#provenance) sidecar of every mapping run, which is `mapping-provenance.json` sitting in the run's folder under `Analyses/` beside the result file described earlier, and it opens in a text editor like any other. If you re-run the same operation after a plugin pack update and the alignments come back slightly different, read the sidecar's version fields. The fixture runs above used minimap2 2.31 with samtools 1.24. A minor mapper release now and then nudges [soft-clip](../../GLOSSARY.md#soft-clip) boundaries by a base or two. A soft clip is an end of a read the mapper left unaligned while placing the rest, so moving its boundary shifts where the alignment is judged to start or stop. That is harmless for variant calling but leaves two BAMs that are not byte for byte identical.

## On the command line

This section is optional. Everything above happens in the window, and nothing later in this manual requires you to have run a command. The command-line flags named in the Settings section are there for reference too, so you never have to type one to use the wizard.

Mapping from the command line takes two commands rather than one, and both are required. `lungfish-cli map` runs the mapper and writes its results into a directory. `lungfish-cli bam adopt-mapping` then attaches that directory's BAM to a reference bundle, which is the step that makes the track appear in the sidebar. A backslash at the end of a line means the command continues on the next line, so each block below is one command however many lines it spans.

The GUI's preset labels and the command line's `--preset` tokens are not the same strings, so the table below pairs them before the commands that need them.

| Data type | Wizard label | `--preset` token |
|---|---|---|
| Illumina short reads | Short-read | `sr` |
| Oxford Nanopore long reads | Oxford Nanopore | `map-ont` |
| PacBio HiFi (CCS) long reads | PacBio HiFi | `map-hifi` |
| PacBio CLR (older long reads) | PacBio CLR | `map-pb` |
| Assembly or assembled contigs | Assembly-to-assembly | `asm5` |

A contig, in that last row, is one continuous stretch of sequence built by joining overlapping reads together.

Two flags in the first command have no counterpart in the window. `--paired` tells the command line that the two files are the R1 and R2 halves of one pair, which the wizard works out on its own from the reads you selected. `--mapper` names the program, which the wizard takes from the menu item you clicked. Replace the project path in the second command with the path to your own project, since the one shown is the demo project this manual builds and is not created anywhere in this chapter.

```bash
# Map the fixture pair with minimap2.
lungfish-cli map \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --reference ~/Downloads/GRCh38.chr20.10.0-10.5Mb.fasta \
  --paired --mapper minimap2 --preset sr \
  --sample-name HG002 \
  -o ~/Downloads/hg002-mapping

# Attach the result to the reference bundle as a track.
lungfish-cli bam adopt-mapping \
  --bundle "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref" \
  --mapping-result ~/Downloads/hg002-mapping \
  --name "minimap2 Mapping"
```

The first command prints its settings, then the same figures the Inspector shows. For the fixture it reported 91,203 total reads, 90,990 mapped at 99.77%, 213 unmapped, and a 4.8 second runtime on a 14-core Apple Silicon machine. Read that runtime as a figure from one run on one machine rather than a promise. How long your own run takes rises with the number of reads and the size of the reference, so a whole human genome takes far longer than this 500 kb slice. The second command prints one line, `Attached alignment track 'minimap2 Mapping' (aln_86981CC7) to bundle.`

Two tokens fall outside the preset table above because they belong to BBMap rather than minimap2. `bbmap-standard` is the Standard mode and the one BBMap falls back to when you omit the flag, and `bbmap-pacbio` is its PacBio mode. minimap2 also offers `splice` for spliced transcript alignment, shown in the wizard as Spliced CDS/cDNA.

Four details of `map` are worth knowing. `--reference` wants a FASTA file rather than a bundle, so pass the FASTA. A `.lungfishref` path does work whenever LGE can pull the bundle's primary FASTA out of it, but when a bundle path is rejected, pass the FASTA file sitting inside that bundle instead. Multiple input files are treated as one sample's reads, so run the command once per sample rather than handing it a whole folder. `--format json` and `--format tsv` print the run summary for a script to read instead of a person. `--mapper` chooses among `minimap2`, `bwa-mem2`, `bowtie2`, and `bbmap`, which is the choice the menu item makes for you in the window.

The adoption step mints its own track identifier, of the form `aln_` followed by eight characters, and the `aln_86981CC7` above is one. Pass `--track-id` to set that identifier yourself when a script needs a stable handle for the track it just attached. Adopting moves the BAM and its index into the bundle, so the mapping folder no longer holds them afterwards, and the folder keeps only the summary and provenance files.

Both routes write a provenance sidecar, recording the command that ran, the version of each tool it called, and checksums of the files involved.

## Next

Continue to [Reading an Alignment](02-reading-an-alignment.md) to open the BAM in the alignment viewport and read the pileup you just built.
