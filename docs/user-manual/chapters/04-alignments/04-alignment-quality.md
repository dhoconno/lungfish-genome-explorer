---
title: Alignment Quality
chapter_id: 04-alignments/04-alignment-quality
audience: analyst
prereqs: [04-alignments/01-mapping-reads-to-a-reference, 04-alignments/02-reading-an-alignment]
estimated_reading_min: 16
task: Mark PCR duplicates, and derive a filtered alignment track before variant calling.
tags: [alignments, qc, coverage, duplicates, mapq, samtools]
tools: [samtools]
parameters_refs: [bam.mark-duplicates, bam.filter]
entry_points:
  - "Inspector > Analysis > Filtering > Mark Duplicates in Bundle Tracks"
  - "Inspector > Analysis > Filtering > Create Filtered Alignment"
  - "Inspector > Analysis > Export > Create Deduplicated Bundle"
  - "CLI: lungfish-cli bundle mark-duplicates"
  - "CLI: lungfish-cli markdup"
  - "CLI: lungfish-cli bam filter"
shots:
  - id: analysis-filtering-tab
    caption: "The Filtering tab of the Inspector's Analysis tab, showing Mark Duplicates in Bundle Tracks above the divider and the Create Filtered Alignment panel below it."
  - id: filter-panel-controls
    caption: "The Create Filtered Alignment panel with Starting Alignment, the two keep toggles, the Minimum alignment confidence stepper reading MAPQ 20, Duplicate handling, and the Name for New Alignment field."
  - id: analysis-export-tab
    caption: "The Export tab of the Inspector's Analysis tab, showing the Create Deduplicated Bundle button and its two explanatory lines."
illustrations:
  - id: duplicates-shotgun-vs-amplicon
    brief: "Two panels side by side on a Cream background. Left, a shotgun library, reads drawn as bars scattered at random start positions along a reference line, with two reads that start and end at exactly the same bases outlined in Lungfish Creamsicle and labelled 'same start, same end: probably PCR copies of one fragment'. Right, an amplicon library, every read in one amplicon starting at the same primer box and ending at the other, all of them identical in position, labelled 'same start by design: marking would flag nearly all of them'. Title strip reads 'Why duplicate marking suits shotgun data and not amplicon data'. IBM Plex Mono for labels, Deep Ink for text."

glossary_refs: [alignment-track, amplicon, contig-reference, coverage-breadth, depth, duplicate-rate, edit-distance, flagstat, library-prep, mapq, mark-duplicates, pcr-duplicate, percent-identity, phred-score, pileup, primary-alignment, provenance, reference-bundle, secondary-alignment, shotgun, supplementary-alignment, variant-caller, required-setup-pack, inspector, checksum]
features_refs: [bam.mark-duplicates, bam.filter]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter checks whether an alignment is good enough to call variants from. Holding many reads is not the same as holding reads you can trust. Three questions stand between a finished mapping run and a list of variants, and Lungfish Genome Explorer (LGE) gives you a tool for each. Do you have enough reads over the positions you care about? Are those reads independent observations, or copies of one starting molecule? Are they placed confidently enough that a difference from the reference means something?

The first question is about depth. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Depth is written with an x, so 45x means 45 reads on average over each position. A whole human shotgun genome usually aims for an average of 30x to 50x, so that nearly every single position clears the per-position floor of about 10x that [The coverage curve](02-reading-an-alignment.md#the-coverage-curve) explains.

The second question is about [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). Library preparation copies each DNA fragment many times, and the sequencer sometimes reads several copies of one original fragment. Two reads from one starting molecule are one observation, so a program that counts them separately is more confident than the data allows. [Marking duplicates](../../GLOSSARY.md#mark-duplicates) flags the extra copies so later tools can count them once or skip them. LGE uses the `samtools markdup` program for this, which ships with LGE.

The third question is about placement. [MAPQ](../../GLOSSARY.md#mapq) is the mapper's confidence in where it placed a read, from 0 for a read that fits several places equally to 60 for one clear placement, as [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records) explains. A variant supported only by MAPQ 0 reads may belong to a near-identical copy of the sequence somewhere else in the genome.

### Three MAPQ cutoffs

LGE offers three controls that act on MAPQ, and only two of them change a file.

| Control | Where it lives | Range | What it does to your reads |
|---|---|---|---|
| Min mapping quality | Mapping dialog, Advanced Settings | 0 to 60 | Leaves low-MAPQ reads out of the BAM when it is written |
| Minimum alignment confidence | View Settings, Alignment tab | 0 to 60 | Hides low-MAPQ reads on screen only, the BAM is unchanged |
| Minimum alignment confidence | Filtering tab, Create Filtered Alignment | 0 to 255 | Writes a new track without low-MAPQ reads, the source is unchanged |

Each mapper scores on its own scale, so a cutoff of 20 is milder under minimap2 than under Bowtie2, as [What the four mappers give you on the same reads](01-mapping-reads-to-a-reference.md#what-the-four-mappers-give-you-on-the-same-reads) shows.

This chapter covers marking duplicates, deriving a filtered alignment, exporting a deduplicated bundle, and judging the MAPQ spread. Reading the Inspector's alignment summary and Flag Statistics belongs to [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results).

## Why you would do this

Each check exists because the alternative is a wrong answer that looks right. A [variant caller](../../GLOSSARY.md#variant-caller), the program that reports where your sample differs from the reference, will call a change that two reads happen to share at 3x depth, and nothing in its output says the evidence was thin. Reading a duplicate-heavy pile, it counts eight copies of one molecule as eight votes. Reading through a repeat, it calls a variant that belongs to another copy of the sequence, because the reads carrying it were placed at MAPQ 0.

Duplicate handling depends on how the library was built, and the rule reverses between the two common designs.

<!-- ILLUSTRATION: duplicates-shotgun-vs-amplicon -->
 In a [shotgun](../../GLOSSARY.md#shotgun) library the DNA is broken at random, so two reads starting at exactly the same base is a coincidence worth suspecting, and marking is right. In an [amplicon](../../GLOSSARY.md#amplicon) library, where the target is copied in PCR pieces, every read from one amplicon starts at the same primer by design. Duplicate marking would flag most of that data when nothing is wrong, and every count drawn afterwards would be meaningless. So amplicon data skips duplicate marking. If you do not know which design produced your reads, the library kit named on the preparation record settles it.

This chapter's HG002 slice comes from a PCR-free shotgun library, meaning no amplification step copied the fragments before sequencing. That is the case where marking is both appropriate and informative.

Filtering can feel wasteful, since it discards reads you paid for. The point is to hand the caller a set in which every read is an independent, confidently placed observation, so the confidence it reports is one you can quote. LGE never edits the source alignment when it marks or filters. Each step writes a new [alignment track](../../GLOSSARY.md#alignment-track) into the same [reference bundle](../../GLOSSARY.md#reference-bundle), which after mapping is the reference bundle inside the mapping result, so you can compare the old and new tracks side by side.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, and run [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) in it to make the `HG002 minimap2` alignment. To import the files yourself instead, follow the rest of this section.

This chapter uses the hg002-chr20 fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

You also need the alignment that [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) produces with minimap2, since every number below comes from that run. The tools arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE.

## Procedure

### Before you mark duplicates

Three facts about **Mark Duplicates in Bundle Tracks** decide when to click it. First, it works on every unmarked alignment track in the bundle at once, not only the one you selected, and adds a marked copy of each. Second, it keeps every original. Each original track is renamed with `[unmarked]` after its name, and each marked copy is named with `[dup-marked]`, so both versions sit in the bundle and nothing is deleted. Your `HG002 minimap2` track therefore becomes `HG002 minimap2 [unmarked]`, the name later chapters use when they ask for the original. Third, it runs as an ordinary operation. It posts a row titled "Mark Duplicates in Bundle Tracks" in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), where a **Cancel** button stops it, and it will not start while another run is working on the same bundle. An alert headed "Operation in Progress" names that run and asks you to wait.

Run it once per bundle. A second click finds nothing left to mark and says so. When you want a separate bundle holding only reads with the duplicates removed, for example to hand to a collaborator, use **Create Deduplicated Bundle** instead, described below.

### Mark duplicates

1. Click the `minimap2-` mapping result under **Analyses** in the sidebar. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.
2. Open the Inspector's **Analysis** tab and click its **Filtering** tab, one of the six [Analysis tabs](02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs). <!-- SHOT: analysis-filtering-tab -->
3. Click **Mark Duplicates in Bundle Tracks**. A sheet headed "Mark Duplicates in Bundle Tracks?" says that `samtools markdup` runs for each unmarked alignment track in the current bundle, adds a duplicate-marked copy next to it, keeps the originals with an `[unmarked]` suffix, and deletes no files.
4. Click **Mark Duplicates**. While it works, the window shows "Marking duplicates...", the Filtering tab shows "Running duplicate workflow...", and the Operations Panel row reports progress. When it finishes, an alert titled "Duplicate Marking Complete" reports how many tracks were processed, one here.
5. Read the track list. The viewport switches from the mapping viewport to the reference bundle inside the mapping result itself, and **Bundle > Alignment Tracks** in the Inspector lists `HG002 minimap2 [unmarked]`, the original alignment under a new name, and `HG002 minimap2 [dup-marked]`, the marked copy.

Re-read the Flag Statistics list for the marked track. The `duplicates` row now reads 1.7K on the HG002 slice, which is 1,684 exactly, where the original track reads 0. The Inspector rounds any count above a thousand. Clicking the button again brings an alert titled "Duplicate Marking Failed" with the message "Every alignment track in this bundle already has a duplicate-marked version. Nothing to do."

### Derive a filtered alignment

On the same **Filtering** tab, scroll past the divider to the panel that begins "Build a new alignment track from an existing BAM without changing the source track."

<!-- SHOT: filter-panel-controls -->

1. Pick `HG002 minimap2 [dup-marked]` in **Starting Alignment**.
2. For a shotgun library heading into variant calling, leave **Keep mapped reads only** and **Keep one primary alignment per read** on, raise **Minimum alignment confidence** to 20, and set **Duplicate handling** to Hide duplicate-marked reads.
3. Replace the suggested text in **Name for New Alignment** with a name that records what you filtered on.
4. Click **Create Filtered Alignment**. If another run is already working on the bundle, an alert headed "Operation in Progress" names it and asks you to wait. Otherwise watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), where the row is titled "Create Filtered Alignment Track".
5. When the run finishes, LGE switches the view to the new track and shows a "Filtered Alignment Created" alert. Both tracks are listed under **Bundle > Alignment Tracks**. To compare them, switch **Visible Alignment** on the Alignment tab of View Settings from one track to the other, as [Reading an Alignment](02-reading-an-alignment.md#settings) describes.

### Export a deduplicated bundle

Marking flags duplicates without deleting them, which suits a tool that knows to skip flagged reads. When you need a copy with the duplicates actually gone, click the **Export** tab and then **Create Deduplicated Bundle**. A sheet headed "Create Deduplicated Bundle?" explains that this creates a sibling `.lungfishref` bundle with duplicate reads removed from all alignment tracks and leaves the current bundle unmodified. Click **Create Bundle**. The new bundle is named after the current one with `-deduplicated` added, its tracks are named with `[deduplicated]`, and LGE opens it when it is done. Like marking, it runs as an Operations Panel row titled "Create Deduplicated Bundle" that you can cancel, and it waits its turn behind any other run on the bundle.

<!-- SHOT: analysis-export-tab -->

## Settings

The two duplicate buttons open no dialog and have no settings. Everything below belongs to the Create Filtered Alignment panel.

**Starting Alignment.** Chooses which alignment the filtered copy is built from, and that track is left unchanged. The default is the first alignment track in the bundle, right only when the bundle holds one. Change it whenever the bundle holds several and the default is not the one you meant. On the command line this is `--alignment-track`.

**Keep mapped reads only.** Drops reads the mapper could not place anywhere, since they carry no position and add nothing to a [pileup](../../GLOSSARY.md#pileup). It is on by default, because unmapped reads are dead weight in an alignment headed for variant calling. Turn it off to keep them for a later attempt against a different reference. On the command line this is `--mapped-only`.

**Keep one primary alignment per read.** Keeps each read's best placement and drops two kinds of extra row. A [secondary alignment](../../GLOSSARY.md#secondary-alignment) is written when a whole read fits somewhere else equally well, and a [supplementary alignment](../../GLOSSARY.md#supplementary-alignment) when one read is split between two distant places. It is on by default, because counting [primary alignments](../../GLOSSARY.md#primary-alignment) counts reads rather than rows. Turn it off when you are studying repeats or rearrangements and the extra placements are the evidence. On the command line this is `--primary-only`.

**Minimum alignment confidence.** Drops reads whose MAPQ is below the value you set, with a stepper from 0 to 255 shown as "MAPQ N". The default is 0, which keeps every read, as the panel's note "Uses SAM MAPQ. Set to 0 to keep every alignment confidence level." says. Raise it to about 20 to keep only confidently placed reads. On the command line this is `--min-mapq`. The file format allows up to 255, but minimap2 caps its scores at 60, so any value above your mapper's cap removes every read.

**Duplicate handling.** Decides what happens to PCR duplicates, offering Keep all reads, Hide duplicate-marked reads, and Remove duplicate reads. The default is Keep all reads, the safe choice while you have not checked the library design. Choose Hide duplicate-marked reads on an alignment already marked, since it trusts the existing flags, and Remove duplicate reads on one nobody has marked, since it runs the marking itself first. On the command line these are `--exclude-marked-duplicates` and `--remove-duplicates`, which cannot be used together.

**Keep reads with zero mismatches to reference.** Keeps only reads that match the reference perfectly, base for base. It is off by default, and must be for variant work, because it removes exactly the reads that carry the differences a caller looks for. Turn it on only for a strict identity check, such as confirming reads came from the exact sequence you think. On the command line this is `--exact-match`.

**Minimum identity to reference (%).** Keeps only reads matching the reference at least this closely, measured as [percent identity](../../GLOSSARY.md#percent-identity) over the part of the read that aligned. It starts blank, which keeps every read, and is greyed out while zero-mismatch filtering is on. Set about 95 to shed clearly foreign reads, such as a contaminating organism, since the HG002 slice averages 99.4 percent identity. On the command line this is `--min-percent-identity`. Identity asks how well a read matches where it sits, while MAPQ asks how sure the mapper is that it sits in the right place, so a read can pass one and fail the other.

**Name for New Alignment.** Names the filtered track, which is how you tell the two apart afterwards. It arrives filled from the current filters, reading "Mapped primary alignments" with the defaults and "Duplicate-marked reads hidden" with the settings recommended above, and rewrites itself as the filters change. Replace it with a name that records what you filtered on, and note that an empty field blocks the run. On the command line this is `--output-track-name`.

## Reading the results

### What duplicate marking changed

On the HG002 slice, marking flags 1,684 records, 1.85 percent of the 91,148 primary records. That low [duplicate rate](../../GLOSSARY.md#duplicate-rate) is what a PCR-free library should give. The total record count stays at 91,203, because marking sets a flag and deletes nothing.

The Inspector's Est. Coverage does not fall after marking, because it counts every record. The viewport does change. Before marking, no read carried the duplicate flag, so **Include duplicate-marked reads** had nothing to hide. After marking, LGE sets it off, so the newly flagged duplicates drop out of the drawn reads and the coverage curve. Measured position by position, mean depth is 44.72x with every read and 43.90x without the duplicates, a drop of about 2 percent, which is what a 1.85 percent duplicate rate should cost. A shotgun library that loses about 20 percent of its depth this way was over-amplified, and its real depth was always the lower number.

### What filtering changed

Filtering the marked alignment with the settings recommended above leaves 89,107 of 91,203 records. The 2,096 dropped records account for themselves exactly. Each record is counted under the first reason that applied to it, so the rows do not overlap.

| Reason a record was dropped | Records |
|---|---|
| Unmapped | 213 |
| Supplementary | 55 |
| Flagged as a duplicate | 1,684 |
| MAPQ below 20 among the rest | 144 |
| Total dropped | 2,096 |

That is why only 144 low-MAPQ records appear here, although 401 records in the file sit below MAPQ 20. The other 257 were already counted as unmapped, supplementary, or duplicate. The filtered track's mean depth is 43.83x.

Two figures in the filtered track are worth a glance. Its Mapped % reads `100.00%`, as it must once unmapped reads are gone, so read its record count instead to see how much survived. Its properly paired share rises from 99.19 percent to 99.51 percent, because the filter mostly removed awkward reads.

### Where the outputs land

Inside the bundle, a filtered track's BAM goes to `alignments/filtered/`, a duplicate-marked track to `alignments/marked/`, and a deduplicated bundle's tracks to `alignments/deduplicated/` in the new bundle, each with its index and statistics file. The statistics file also records how each track was made. You never need to open these folders yourself.

## What good looks like

Confirm the depth is enough. A mean of 44.7x on this fixture is comfortable. Under about 10x on a shotgun library leaves too little evidence per position, and the fix is more sequencing, not a cleverer filter. Doubling the reads roughly doubles the depth. Depth is an average, so also check coverage breadth and look along the coverage curve for thin stretches, as [The coverage curve](02-reading-an-alignment.md#the-coverage-curve) describes. This slice covers 99.99 percent of its 500,001 bases.

Confirm the duplicate rate matches the library design. Under about 5 percent on a PCR-free shotgun library, like this fixture's 1.85 percent, means plenty of distinct starting molecules. Above about 20 percent on shotgun data means over-amplification, and the depth to believe is the one after duplicates are excluded. Amplicon data runs very high by design, which is why it skips marking.

Confirm the placements are confident. On the HG002 slice, 87,759 of 91,203 records carry the maximum MAPQ of 60 and only 401 fall below 20. So 96 percent sit at the ceiling and under half a percent below this chapter's threshold. There is no published cutoff, so compare your run to this one. A well-matched reference puts most records at the ceiling. A large share at MAPQ 0 means reads fit several places equally, usually in repeats or near-identical duplicated sequence. LGE has no chart of the MAPQ spread. Click single reads and read MAPQ in the Selected Read panel, or turn the reads into a table with **Convert Mapped Reads to Annotations** on the **Annotations** tab and sort by MAPQ.

Confirm the filter dropped what you expected and nothing more. Account for the difference in record counts as the table above does. A filter that removes far more than the flags and thresholds explain usually had a setting stricter than intended, and zero-mismatch filtering is the usual culprit.

## On the command line

The block follows [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and every flag of these commands is listed in [Mapping and alignment tracks](../appendices/cli-reference.md#mapping-and-alignment-tracks) and [Reference bundles](../appendices/cli-reference.md#reference-bundles) in the CLI Reference. Put your own mapping result folder in the `BUNDLE` line, as `ls "$PROJECT/Analyses"` prints it.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
BUNDLE="$PROJECT/Analyses/minimap2-2026-09-27T11-21-19/GRCh38.chr20.10.0-10.5Mb.lungfishref"

# Add a duplicate-marked copy of every track, keeping the originals as [unmarked].
lungfish-cli bundle mark-duplicates "$BUNDLE"

# Copy the bundle with duplicates removed from every track.
lungfish-cli bundle deduplicate-alignments "$BUNDLE"

# Derive the filtered track described above from the marked copy.
lungfish-cli bam filter --bundle "$BUNDLE" \
  --alignment-track aln_7EFF93AA \
  --output-track-name "HG002 filtered (MAPQ 20, primary, no duplicates)" \
  --mapped-only --primary-only --min-mapq 20 --exclude-marked-duplicates
```

`bundle mark-duplicates` does what the Inspector button does and prints the identifier of each marked track it added, such as `Marked tracks added: aln_7EFF93AA`. `--alignment-track` takes that identifier, `aln_` and eight letters and digits that differ on every run, rather than the track's name. The marked BAM is in the bundle's `alignments/marked/` folder under the same identifier.

The separate `lungfish-cli markdup` command works on one BAM file, or on every BAM in a folder, rather than on a bundle's tracks. It also keeps its input. It writes the marked copy beside the input as `<name>.markdup.bam` with its index, or to the file `--output` names, and attaches nothing to a bundle. Only `--in-place` overwrites the input, and it warns that the unmarked file is gone. On the HG002 alignment it reports 1,684 duplicates among 90,990 mapped records, supplementary records included.

## Next

The next chapter, [Primer Trimming an Alignment](03-primer-trimming.md), is for amplicon data, so a shotgun reader with this slice's alignment can go straight on to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), whose bcftools and LoFreq callers suit shotgun data, as [Two routes through this part](01-mapping-reads-to-a-reference.md#two-routes-through-this-part) sets out. Calling Variants reads the original alignment, which after this chapter is named `HG002 minimap2 [unmarked]`, and its numbers come from that track.
