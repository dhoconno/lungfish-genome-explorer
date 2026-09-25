---
title: Primer Trimming an Alignment
chapter_id: 04-alignments/03-primer-trimming
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 03-reads/04-trimming-and-filtering, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/02-reading-an-alignment]
estimated_reading_min: 14
task: Soft-clip amplicon primer bases out of an aligned BAM using a primer scheme, so a variant caller never reads primer sequence as sample sequence.
tags: [alignments, primer-trim, amplicon, ivar, primer-scheme, artic, qiaseq]
tools: [ivar, samtools]
parameters_refs: [bam.primer-trim]
entry_points:
  - "Inspector > Analysis > Primer Trim > Primer-trim BAM..."
  - "CLI: lungfish-cli bam primer-trim"
shots:
  - id: primer-trim-scheme-menu
    caption: "The Primer Trim dialog with the Primer Scheme menu open, showing the eight schemes under the Built-in heading."
  - id: primer-trim-dialog-target
    caption: "The Primer Trim dialog opened on the human demo alignment before choosing a matching scheme, showing the Alignment Track menu, empty Output Track Name field, and note that reads without matching primers are retained."
  - id: primer-trim-track-result
    caption: "The sidebar after the run, showing the new track named minimap2 Mapping, a bullet, Primer-trimmed, and the scheme name in parentheses."
illustrations: []
glossary_refs: [alignment-track, amplicon, bam, bed, checksum, cigar, coverage, ivar, operations-panel, pileup, primer, primer-scheme, primer-trim, provenance, reference-bundle, soft-clip, variant-caller, plugin-pack, inspector, phred-score]
features_refs: [bam.primer-trim]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. Every read from such a protocol begins and ends inside a [primer](../../GLOSSARY.md#primer), a short piece of laboratory-made DNA. Those end bases were written by whoever designed the primer, not copied from your sample, so they have to go before variant calling.

Primer trimming can happen at two stages. Trimming raw reads before mapping is covered in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md). This chapter covers the other stage, trimming reads that are already mapped to a reference. Lungfish Genome Explorer (LGE) packages a scheme as a `.lungfishprimers` folder holding a [BED](../../GLOSSARY.md#bed) file of primer positions and a manifest naming the protocol and the reference genome the primers were designed against.

Given the scheme, LGE runs the trimmer from [iVar](../../GLOSSARY.md#ivar), an amplicon toolkit, over the [BAM](../../GLOSSARY.md#bam) file of mapped reads. The trimmer looks at where each read starts and ends, works out which primer produced it, and soft-clips that many bases at each end. A [soft clip](../../GLOSSARY.md#soft-clip) is a stretch at a read end that stays in the file but is left out of the pileup, written as `S` in the read's [CIGAR](../../GLOSSARY.md#cigar) string, as [The CIGAR string](../01-foundations/04-alignment-files.md#the-cigar-string) explains. For example, clipping a 22-base primer off a read aligned as `150M`, 150 matched bases, turns its CIGAR into `22S128M`. The bases stay in the file at full length. A [variant caller](../../GLOSSARY.md#variant-caller), the program that reports where your sample differs from the reference, simply skips the `S` bases when it builds its [pileup](../../GLOSSARY.md#pileup).

LGE writes the clipped reads to a new [alignment track](../../GLOSSARY.md#alignment-track) beside the original, so the untrimmed alignment stays available for comparison. If you mapped amplicon reads and variant calling is next, trim now.

This chapter uses a SARS-CoV-2 dataset, because every primer scheme that ships with LGE is a SARS-CoV-2 scheme. A human or macaque amplicon panel trims the same way once you import its scheme.

## Why you would do this

An untrimmed amplicon alignment invents variants. Every read a primer started carries the primer's own letters across its footprint, whatever the sample's sequence is underneath. Primer schemes are designed against one reference genome, and primers often carry deliberate mismatches so they keep binding as a virus mutates. Wherever a primer's letters disagree with the sample, every read across that footprint reports the primer's base.

The variant caller then sees a column where nearly every read carries the same alternate base at good quality, and calls a confident difference. That call is wrong and hard to catch. It reproduces on every rerun, sits under deep coverage, and passes the usual quality checks. Its only tell is location, since such calls cluster at amplicon ends.

Trimming removes the problem at its source. There is a second reason too. iVar's own variant caller expects trimmed input, and LGE records the trim with the track, so the variant-calling dialog confirms it for you.

This chapter works through SRR36291587, a public QIAseq Direct SARS-CoV-2 amplicon library of 85,199 paired-end Illumina read pairs from the NCBI Sequence Read Archive, mapped to the Wuhan-Hu-1 reference `MN908947.3`.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` and the `MN908947.3` reference bundle this section brings in, so start from the mapping step below. To fetch the data yourself instead, follow the rest of this section.

This chapter uses the sarscov2-srr36291587 fixture. Download `MN908947.3.fasta` from [the sarscov2-srr36291587 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The reads are not in that folder. Download them from the Sequence Read Archive as accession `SRR36291587`, as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows.

Import the FASTA as a reference and map the reads to it with minimap2, as [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) shows. The mapping result under `Analyses/` holds the alignment track this chapter trims. On the reference run, minimap2 placed 99.3% of the read records. An amplicon library mapped to its own reference should land well above 90%. Below that, check the reference and the sample before you trim, because trimming fixes neither.

Install the `variant-calling` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries iVar 1.4.4, the version behind this chapter's figures. Until it is installed, the dialog's Readiness line names the missing pack and Run stays disabled.

## Procedure

The worked example trims the minimap2 alignment with the built-in QIAseq Direct scheme, the scheme this library was prepared with.

### Open the dialog and pick a scheme

1. Click the mapping result under `Analyses/` in the sidebar. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.
2. Open the Inspector's **Analysis** section and click its **Primer Trim** tab, one of the six [Analysis tabs](02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs).
3. Click **Primer-trim BAM...**. The Primer Trim dialog opens with four sections, Primer Scheme, Target, Advanced Options, and Readiness.
4. Open the **Primer Scheme** menu and choose **QIAseq Direct SARS-CoV-2 with Booster A**. Eight schemes sit under the heading Built-in, and schemes you imported into the project sit under In This Project. LGE ships eight SARS-CoV-2 schemes, listed in [Shipped schemes](../appendices/primer-schemes.md#shipped-schemes). For your own run, take the scheme name from the amplicon kit you prepared the library with, never from a guess at the menu.

    <!-- SHOT: primer-trim-scheme-menu -->

The **Choose Scheme...** button beside the menu opens a scheme stored outside the project, such as a `.lungfishprimers` folder a collaborator sent you. To build a scheme LGE does not ship, see [Primer Schemes](../appendices/primer-schemes.md).

### Set the target and run

<!-- SHOT: primer-trim-dialog-target -->

1. Read the **Alignment Track** menu in the Target section. LGE fills it with the first eligible track in the bundle, meaning the first sorted, indexed BAM, not necessarily the track you clicked. Check that it names the one you meant.
2. Read the **Output Track Name** field. LGE fills it with the source track's name, a bullet, "Primer-trimmed", and the scheme name in parentheses, giving `minimap2 Mapping • Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)`. Keep it or shorten it.
3. Leave **Advanced Options** collapsed. Its four iVar values suit a standard run, and the Settings section explains each.
4. Check the **Readiness** line at the foot of the sheet. With a scheme, a track, and a name set, it reads "Ready to trim using QIAseq Direct SARS-CoV-2 with Booster A." Otherwise it names what is missing and Run stays disabled.
5. Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled `Primer-trimming with QIAseq Direct SARS-CoV-2 with Booster A`. When it finishes, the new track appears beside the source track.

    <!-- SHOT: primer-trim-track-result -->

Under the Target section the dialog notes that reads without matching primers are retained and asks you to review downstream quality control before variant calling. That warns you in advance that reads with no primer are kept, as [Reading the results](#reading-the-results) explains. If another operation is already running on the bundle, an alert titled "Operation in Progress" names it. If the trim itself fails, an alert titled "Primer Trim Failed" carries the tool's message.

## Settings

The first three settings sit in plain view. The last four live inside Advanced Options.

**Primer Scheme.** Names the primer set your library was built with, so LGE knows where each primer sits. There is no default, because no scheme fits every library, and Run stays disabled until you pick one. Always set it to the scheme your wet-lab protocol used, since the wrong scheme trims the wrong bases. On the command line this is `--scheme`.

**Alignment Track.** Chooses which alignment the primer bases are clipped from. The default is the first eligible track in the bundle, not necessarily the one you clicked. Check it and change it whenever the bundle holds more than one alignment. On the command line this is `--alignment-track`.

**Output Track Name.** Names the new track trimming produces, since the source track is never modified. The default is the source name, a bullet, "Primer-trimmed", and the scheme name in parentheses, which is long but says exactly what the track is. Shorten it for a tidier sidebar, and note that a name already in use is refused rather than overwritten. On the command line this is `--name`.

**Minimum read length after trim.** Discards any read left shorter than this once primer bases and low-quality ends are clipped. The default is 30 bases, because a much shorter read matches too many places to be worth keeping. Lower it only when your amplicons are short enough that trimming leaves little behind. On the command line this is `--ivar-min-length`.

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand.

**Minimum quality.** Sets the quality floor for the sliding-window quality trim iVar runs alongside primer removal. The default is 20. Raise it toward 30 when the run's quality was high and you want only very confident bases in the pileup. On the command line this is `--ivar-min-quality`.

**Sliding window width.** Sets how many neighbouring bases iVar averages as it walks in from each read end, cutting where the average quality in that window first falls below the minimum. The default is 4, wide enough that one bad base does not cut an otherwise good read short. Widen it only for long reads whose quality drifts down slowly. On the command line this is `--ivar-sliding-window`.

**Primer offset.** Shifts every primer coordinate by this many bases before trimming, to correct a scheme whose coordinates are consistently displaced from your reference. The default is 0, right whenever the scheme and the alignment agree, which is the normal case. Use it only once you have shown that a trusted scheme's coordinates are off by a fixed amount, which first shows up as a low trim rate. On the command line this is `--ivar-primer-offset`.

## Reading the results

Select the new track and look at the reads. They sit exactly where they sat before, because trimming moves nothing. What changes is the ends. Where the untrimmed track showed matched bases running flush to each amplicon boundary, the trimmed track shows short lightened runs, the soft-clipped primer footprints. If you do not see them, turn on **Show soft-clipped sequence** in View Settings, as [Reading an Alignment](02-reading-an-alignment.md#settings) describes.

Some soft clipping was there before the trim, since minimap2 clips read ends that do not fit the reference. On the reference run, soft-clipped bases made up 9.4% of mapped bases before trimming and 26.0% after. Most of the difference is the primers. The rest is the low-quality read ends that iVar's quality trim clips in the same pass.

The number of records also falls, for two reasons. Reads are not dropped for lacking a primer. They are dropped when the quality trim leaves them shorter than **Minimum read length after trim**, and unmapped reads are not written to the trimmed track. iVar reports all of this in the run's log in the Operations Panel, in lines of this form:

```text
Trimmed primers from <percent> (<count>) of reads.
<percent> (<count>) of reads were quality trimmed below the minimum length of 30 bp and were not written to file.
<percent> (<count>) of reads started outside of primer regions. Since the -e flag was given, these reads were written to file.
<count> unmapped reads were not written to file.
```

The first line is the trim rate, the share of reads in which iVar found a primer to clip. On the reference run it was 99.2%. The second counts reads discarded for falling under the minimum length. The third counts reads that began outside every primer footprint and were kept, because LGE always passes iVar's `-e` option, which is what the dialog's note promised. The fourth counts unmapped reads, which a trimmed alignment has no use for. iVar may add a line about reads whose insert size is smaller than their read length. Insert size is the length of the original DNA fragment between the outer ends of the two mates, so that line means the fragment was shorter than the read, so the sequencer read past its end, which is expected on a short-amplicon library.

The record of the run sits in two places in the Inspector. The new track's provenance block holds the three steps, `ivar trim`, `samtools sort`, and `samtools index`, each behind a **Show command** button. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. The **Primer-trim Derivation** group in the alignment section names the scheme and its version, the accession its coordinates were written against, and the iVar version. When you later call variants with iVar on this track, the checkbox "This BAM has already been primer-trimmed for iVar." is already ticked and greyed out, with the date and scheme name beneath it.

## What good looks like

Check the trim rate first, because it tells you whether the scheme was right. A correct scheme against a well-tiled amplicon library reaches the high nineties, as the reference run's 99.2% does. Treat anything below about 90% as a reason to stop and check the scheme. The soft-clipped share of bases is only a second opinion.

A wrong scheme is silent. The same alignment trimmed with the ARTIC SARS-CoV-2 V3 scheme, a real scheme for a different protocol, ran to completion with no error or warning. Its trim rate was only 22.1%, and most reads started outside every primer region. Nothing in the window flags this, so the trim rate in the log is your only check. Read it every time.

Confirm the reference the scheme was built against. Each scheme's manifest names an accession and may list equivalent ones. All eight bundled schemes name both `MN908947.3` and `NC_045512.2`, which are the same SARS-CoV-2 genome deposited twice, once by the submitting group and once in NCBI's curated reference collection. An alignment mapped to either one works with any bundled scheme. A scheme you imported yourself names only the accessions you gave it, so a BAM whose sequence carries a different name will not match.

Finally, confirm the new track sits beside the untrimmed one rather than replacing it, and that you carry the trimmed track into iVar variant calling. If the Call Variants dialog's primer-trim checkbox is empty there, the wrong track is selected.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli bam primer-trim \
  --bundle "Analyses/minimap2-<timestamp>/MN908947.3.lungfishref" \
  --alignment-track <track id> \
  --scheme "Primer Schemes/QIASeqDIRECT-SARS2.lungfishprimers" \
  --name "minimap2 Mapping • Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)"
```

`--alignment-track` takes the track's identifier, a short string beginning `aln_` that the window does not show, rather than its display name. `lungfish-cli bundle list` on the bundle prints the tracks it holds. The four Advanced Options take the same defaults as the dialog, 30, 20, 4, and 0. The trimmed BAM lands in the bundle's `alignments/primer-trimmed` folder by either route, because the dialog runs this same command.

## Next

Continue to [Alignment Quality](04-alignment-quality.md) for the coverage and duplicate checks, remembering that amplicon data skips duplicate marking, or go straight to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) to call variants from the trimmed track.
