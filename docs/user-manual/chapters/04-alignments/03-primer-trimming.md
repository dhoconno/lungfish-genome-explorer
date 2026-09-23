---
title: Primer Trimming an Alignment
chapter_id: 04-alignments/03-primer-trimming
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 03-reads/04-trimming-and-filtering, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/02-reading-an-alignment]
estimated_reading_min: 22
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
    caption: "The sidebar after the run, showing the new track named minimap2 mapping, a bullet, Primer-trimmed, and the scheme name in parentheses."
illustrations: []
glossary_refs: [alignment-track, amplicon, bam, bed, checksum, cigar, coverage, ivar, operations-panel, pileup, primer, primer-scheme, primer-trim, provenance, reference-bundle, soft-clip, variant-caller]
features_refs: [bam.primer-trim]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

Primer trimming can happen at either of two stages. At the read level it works on raw reads before any mapping, and that is the subject of [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md). This chapter covers the other stage, the alignment level, which works on reads that have already been mapped to a reference genome. Either way the goal is the same. Remove the bases that came from a synthetic [primer](../../GLOSSARY.md#primer) rather than from your sample. A primer is a short piece of laboratory-made DNA, usually eighteen to thirty bases long, that binds a chosen spot on the genome and starts the copying reaction that makes an [amplicon](../../GLOSSARY.md#amplicon). An amplicon is one PCR product, and an amplicon sequencing protocol uses a fixed set of primers arranged so their products overlap and cover the whole target genome.

Every read from such a protocol begins and ends inside a primer. Those first and last bases were written by the chemist who designed the primer, not copied from the organism you sequenced. A [primer scheme](../../GLOSSARY.md#primer-scheme) is the list saying where each forward and reverse primer of a protocol lands on the reference genome. Lungfish Genome Explorer (LGE) packages a scheme as a `.lungfishprimers` folder holding a [BED](../../GLOSSARY.md#bed) file of those coordinates, a manifest, and a provenance note. A manifest is a small text file that names what a folder contains, and this one names the protocol and the reference genome the primers were designed against.

Given that list, LGE runs [iVar](../../GLOSSARY.md#ivar) over the [BAM](../../GLOSSARY.md#bam) file of mapped reads. iVar is an amplicon toolkit that contains several programs, and two of them matter here. One trims primers, which is what this chapter uses, and another calls variants, which the next chapter uses. The trimmer looks at where each read starts and ends, works out which primer produced it, and marks that many bases at each end as [soft-clipped](../../GLOSSARY.md#soft-clip).

Soft-clipping does not delete anything. It rewrites part of the read's [CIGAR](../../GLOSSARY.md#cigar) string, the compact code describing how the read lines up with the reference. A CIGAR reads as a run length followed by a letter, so `150M` means a hundred and fifty matched bases in a row. Clipping the first twenty-two bases of that read turns the string into `22S128M`, where `S` marks the clipped stretch and `M` still marks the rest. Only the ends change, and the bases stay in the file at full length. What changes is that a [variant caller](../../GLOSSARY.md#variant-caller), the program that reports where your sample differs from the reference, skips the `S` bases when it builds its [pileup](../../GLOSSARY.md#pileup), the stack of read bases sitting over one reference position.

LGE writes the clipped reads to a new [alignment track](../../GLOSSARY.md#alignment-track) inside the same [reference bundle](../../GLOSSARY.md#reference-bundle) and leaves the original alone, so the untrimmed alignment stays available for comparison. So what should you do with this? If you mapped amplicon reads and variant calling is next, trim them now, before you call.

This chapter is the manual's one alignment-level primer-trimming example, and it uses a SARS-CoV-2 dataset because every primer scheme that ships with LGE is a SARS-CoV-2 scheme and no human amplicon fixture exists in the manual's practice data. The biology of the operation is general. A human or macaque amplicon panel trims the same way once you import its scheme, and read-level primer trimming, covered in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md), works on any organism at all.

## Why you would do this

An untrimmed amplicon alignment invents variants that were never in the sample. Consider one primer sitting at a fixed position on the reference. Every read that primer started carries the primer's own letters across that stretch, whatever the sample's real sequence is underneath. Primer schemes are designed against one particular reference genome, often an early one, and primers are frequently written with deliberate mismatches so they keep binding as an organism drifts. A primer does not need to match perfectly to work. It binds along its whole length, so one or two deliberately mismatched positions still leave enough matching bases to hold, and the mismatch is chosen so the primer keeps binding even after the genome mutates at that spot. Wherever a primer's letters disagree with the reference, every read across that footprint reports the primer's base.

The variant caller then sees a column where nearly every read carries the same alternate base at good quality, and it calls a confident difference. That call is wrong, and it is the kind of wrong that is hard to catch. It reproduces on every rerun, it sits under deep coverage, and it passes the usual quality checks. Its only reliable tell is location, since these calls cluster at amplicon boundaries rather than scattering across the genome.

Trimming removes the problem at its source. The trimmed alignment holds the same reads at the same positions, and the caller simply never reads a primer base. There is a second reason too. iVar's own variant caller expects a primer-trimmed input, and LGE records the trim in the alignment's provenance so the variant-calling dialog can confirm it for you rather than asking you to promise it by hand.

This chapter works through the SRR36291587 SARS-CoV-2 reads, a QIAseq Direct amplicon library of 86,281 paired-end Illumina read pairs from a public NCBI Sequence Read Archive run, mapped to the Wuhan-Hu-1 reference genome `MN908947.3`. Each pair contributes two read records to the alignment, which is why 86,281 pairs become the 172,562 records counted later in this chapter. It is a real clinical-scale amplicon dataset, so the trim rate and the base counts below are the sort of numbers you will see on your own runs rather than the tidy figures a toy dataset gives.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the SRR36291587 SARS-CoV-2 reads. Download the reference file `MN908947.3.fasta` from the manual's practice data files on GitHub at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

and remember where you saved it. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md).

You then need a mapped alignment before you can trim one. Build the reference bundle from `MN908947.3.fasta` and map the reads to it with minimap2, following [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md). That produces the alignment track this chapter trims. The mapping rate is the share of read records that minimap2 placed somewhere on the reference. On the reference run behind this chapter, mapping placed 171,355 of 172,562 read records, which is 99.30%. An amplicon library mapped to its own reference should land well above 90%. Below that, stop and check the mapping before you trim, because a rate that low usually means the reads were mapped to the wrong reference or the library carries a great deal of host or contaminant sequence, and trimming will not fix either.

Primer trimming uses iVar and samtools from the Variant Calling pack, so that pack must be installed before you start. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and install Variant Calling if it is not already present. Installing downloads the tools from the internet, so you need a working connection, and the pack is large enough that the download is not instant. The rest of the app stays usable while it runs, and the Plugin Manager reports progress. Until the pack is ready the dialog's Readiness line reads "Requires Variant Calling Pack" and the Run button stays disabled.

## Procedure

The worked example trims the minimap2 alignment you just built, using the built-in QIAseq Direct scheme, which is the scheme this library was actually prepared with. Every count quoted in this chapter came from a real run on 2026-09-07.

### Opening the dialog and picking a scheme

1. Click the `MN908947.3` reference bundle in the sidebar to select it, then click the alignment track inside it. The Inspector on the right fills with that alignment's details.

2. In the Inspector, open the **Analysis** section and click its **Primer Trim** tab. The Analysis section is a grid of six tabs, reading Filtering, Annotations, Consensus, Primer Trim, Variant Calling, and Export, and it shows only one at a time. The primer-trim button is invisible until you click the fourth of those.

3. Click **Primer-trim BAM...**. The Primer Trim dialog opens, stacking four sections down the sheet in this order. Primer Scheme, Target, Advanced Options, and Readiness.

4. Open the **Primer Scheme** menu. Eight schemes sit under a heading reading Built-in, and any scheme you have imported into this project sits under a second heading reading In This Project. Choose **QIAseq Direct SARS-CoV-2 with Booster A**. For a run of your own, the scheme name is the name of the amplicon kit you prepared the library with, so read it off the kit box or the wet-lab protocol sheet rather than guessing from the menu. A caption beside the **Choose Scheme...** button repeats the name you picked, which is how you confirm the selection took.

    <!-- SHOT: primer-trim-scheme-menu -->

The **Choose Scheme...** button beside that menu opens a file chooser for a scheme stored outside the project, which you need only when a collaborator sends you a `.lungfishprimers` folder you have not imported.

### Setting the target and running

<!-- SHOT: primer-trim-dialog-target -->

1. Read the **Target** section. Its **Alignment Track** menu already names an alignment, because LGE fills it with the first eligible track in the bundle rather than with whichever track you had selected in the sidebar. Check that it names the one you meant. An eligible track is one stored as an indexed BAM. An index is a small companion file that the mapping step writes automatically beside the BAM so a program can jump to one region without reading the whole file, and a track whose index is missing does not appear in this menu at all. If the track you want is absent, run the mapping again rather than hunting for the index, because mapping writes both files together.

2. Read the **Output Track Name** field below it. LGE has already filled it with the source track's name, a bullet, the word Primer-trimmed, and the scheme name in parentheses, giving `minimap2 mapping • Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)`. Leave it or shorten it. A name that matches a track already in the bundle is refused rather than overwritten.

3. Leave **Advanced Options** collapsed. It holds four iVar numbers whose defaults follow iVar's own recommendations for amplicon work, and those defaults suit a standard run, so most readers never open this disclosure at all. The Settings section below explains each of the four, and you open the disclosure only when your kit documentation calls for something different.

4. Check the **Readiness** line at the foot of the sheet. Once a scheme, a track, and a name are all set it reads "Ready to trim using QIAseq Direct SARS-CoV-2 with Booster A." When something is missing it names the missing piece instead, and Run stays disabled.

5. Click **Run**. The dialog closes and a row titled `Primer-trimming with QIAseq Direct SARS-CoV-2 with Booster A` appears in the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P). When it finishes, the new alignment track appears in the sidebar under the same reference bundle.

    <!-- SHOT: primer-trim-track-result -->

Below the Output Track Name field sits a note saying that reads without matching primers are retained and asking you to review downstream quality control before calling variants. That is the dialog telling you in advance that it keeps reads it found no primer for, which the Reading the results section explains. Every field in the sheet also carries its own help popover, so a control whose purpose is unclear will explain itself in place.

If another operation is already running against this bundle, the run is refused with an alert titled Operation in Progress that names the operation holding it. Wait for that one to finish and click Run again. If the trim itself fails, the failure surfaces as an alert titled Primer Trim Failed carrying the message from whichever tool stopped.

## Settings

Every setting the Primer Trim dialog offers is documented below. The first three sit in plain view. The last four live inside Advanced Options and keep their defaults unless you open that disclosure. Each entry ends with a short sentence naming the setting's command-line flag, which belongs to the optional command-line section at the end of this chapter.

**Primer Scheme.** Names the primer set your sequencing library was built with, so LGE knows where on the genome each primer sits. There is no default, because no scheme is correct for every library, and the dialog will not let you run until you pick one. Always set it to the scheme your wet-lab protocol actually used, since trimming with the wrong scheme removes the wrong bases. On the command line this is `--scheme`.

**Alignment Track.** Chooses which alignment the primer bases are clipped out of. The default is the first eligible alignment track in the bundle, which is simply the first one in the manifest and not necessarily the one you clicked in the sidebar. Check it, and change it, whenever the bundle holds more than one alignment. On the command line this is `--alignment-track`.

**Output Track Name.** Names the new alignment that trimming produces, since the source track is never modified. The default is the source track name followed by a bullet, the words Primer-trimmed, and the scheme name in parentheses, which is long but says exactly what the track is and which scheme made it. Shorten it when you want a tidier label in the sidebar, and note that a name already in use is refused rather than overwritten. On the command line this is `--name`.

**Minimum read length after trim.** Discards any read left shorter than this once its primer bases have been clipped away. The default is 30 bases, because a read much shorter than that matches too many places on a genome to be worth keeping. Lower it when your amplicons are short enough that trimming leaves little behind. On the command line this is `--ivar-min-length`.

**Minimum quality.** Sets the quality floor for the sliding-window quality trim iVar runs alongside primer removal. The default is 20, a Phred score meaning the instrument expects one wrong base in a hundred, which is the conventional floor for Illumina data. Raise it toward 30, which is one wrong base in a thousand, when the run's quality was high and you want only very confident bases reaching the pileup. On the command line this is `--ivar-min-quality`.

**Sliding window width.** Sets how many neighbouring bases iVar averages together as it walks in from each read end deciding where to cut. The window is a short frame of that many bases that starts at the read's end and slides inward one base at a time, and iVar cuts where the average quality inside the frame first falls below the minimum. The default is 4, wide enough that one bad base does not truncate an otherwise good read. Change it rarely, and then only to widen the window for long reads whose quality drifts slowly rather than falling off a cliff. On the command line this is `--ivar-sliding-window`.

**Primer offset.** Shifts every primer coordinate by this many bases before the trim runs, which compensates for a scheme whose coordinates are consistently displaced from the reference you mapped against. The default is 0, correct whenever the scheme and the alignment agree on coordinates, which is the normal case. The symptom that points here is a low trim rate from a scheme you have every other reason to trust, since coordinates displaced by a few bases leave iVar looking for primers just beside where they actually sit, so use it only once you have established that your scheme's coordinates are off by a fixed amount. On the command line this is `--ivar-primer-offset`.

## Reading the results

Select the new track and look at the reads in the viewport. They sit exactly where they sat before, because trimming moves nothing. What changed is how the ends are drawn. Where the untrimmed track showed solid matched bases running flush to each amplicon boundary, the trimmed track shows short lighter runs there instead. Those are the soft-clipped primer footprints. If you do not see them, turn on "Show soft-clipped sequence" in the Inspector's **View Settings** section, on its **Reads** tab, because that toggle governs whether clipped bases are drawn at all.

The numbers behind that picture are worth reading directly.

| Measure | Before the trim | After the trim |
|---|---|---|
| Soft-clipped bases | 4,003,827 | 10,641,749 |
| Matched bases | 38,461,970 | 30,340,659 |
| Soft-clipped share of mapped bases | 9.43% | 25.97% |

The starting figure is not primer sequence. It is the ordinary clipping minimap2 does at read ends that do not fit the reference. The trim added roughly 6.6 million newly clipped bases on top of it, and those are the primers. Matched bases fell by more than that, by roughly 8.1 million, and the two changes do not balance because clipping is not the only thing that happened. Reads discarded for falling under the minimum length took their matched bases out of the file entirely, so those bases left the alignment rather than moving into the clipped column.

Read counts change too, and for one specific reason. The alignment held 172,562 records before the trim and 164,704 after it. Reads are not dropped for lacking a primer. They are dropped when the quality trim leaves them shorter than the minimum length, and iVar says so plainly in the operation log.

```text
Trimmed primers from 99.15% (169906) of reads.
3.88% (6651) of reads were quality trimmed below the minimum length of 30 bp and were not written to file.
0.79% (1360) of reads started outside of primer regions. Since the -e flag was given, these reads were written to file.
1207 unmapped reads were not written to file.
```

Those lines are the most useful thing the run produces. The first is the trim rate, the fraction of reads in which iVar found a primer to clip. The second counts reads that fell below **Minimum read length after trim** and were therefore discarded. The third counts reads that began outside every primer footprint, and it confirms LGE keeps them rather than throwing them away, which is what the dialog's own note in the Target section promises. The fourth is just the unmapped reads, which a trimmed alignment has no use for. The `-e` flag named in the third line is what keeps those primerless reads, and LGE always passes it, so it is not a choice you made or can change. iVar prints a fifth line after these four, reading "77.97% (133607) of reads had their insert size smaller than their read length" on the reference run. That one counts read pairs whose fragment was shorter than the read, so the sequencer ran off the end of the fragment and into the opposite adapter. It is expected on a short-amplicon library like this one and is not a fault to chase.

The record of the run is split across two Inspector surfaces. The **Provenance** section for the new track holds the three steps, an `ivar trim` followed by a `samtools sort` and a `samtools index`, each with its exact command line hidden behind a **Show command** button, and it holds a SHA-256 [checksum](../../GLOSSARY.md#checksum) for the source BAM, its index, and the scheme's BED file. A checksum is a short string computed from a file's contents, so comparing it later proves the file you have is the file the run used and not an edited copy. The scheme's manifest name and version, the canonical accession its coordinates were written against, and the iVar version used, 1.4.4 on the reference run, sit instead in the alignment section's **Primer-trim Derivation** group. That [provenance](../../GLOSSARY.md#provenance) travels with the track inside the bundle, and the variant-calling dialog reads it. When you call variants with iVar on this track, the checkbox reading "This BAM has already been primer-trimmed for iVar." is already ticked and greyed out, with the date and scheme name beneath it.

## What good looks like

Check the trim rate first, because it is the single number that tells you whether the scheme was right. The trim rate is the fraction of reads in which iVar found a primer to clip, and it is the check. The soft-clipping percentage of bases only corroborates it, so read the rate and treat the base figure as a second opinion. On the reference run iVar trimmed primers from 99.15% of reads, which is what a correct scheme against a well-tiled amplicon library looks like. A well-matched scheme should reach the high nineties, so treat anything below about 90% as a reason to stop and check the scheme before you trust the trimmed track. A low rate means the scheme and the library disagree.

To show what that failure looks like rather than only describe it, the same alignment was trimmed a second time with the ARTIC SARS-CoV-2 V3 scheme, which is a real SARS-CoV-2 scheme for a different protocol. It ran to completion with no error and no warning of any kind, and produced this instead.

```text
Trimmed primers from 22.13% (37921) of reads.
76.14% (130463) of reads started outside of primer regions. Since the -e flag was given, these reads were written to file.
```

Three quarters of the reads found no primer, and soft-clipping reached only 13.44% of bases rather than 25.97%. Nothing in the interface flags this. A wrong scheme is silent, so the trim rate in the log is your only check, and you should read it every time.

The reference the scheme was built against is the other thing to confirm. Each scheme's manifest names a canonical accession and may also list equivalent ones, and all eight bundled schemes name both `MN908947.3` and `NC_045512.2`, which are the same SARS-CoV-2 genome deposited twice. Duplicate deposits are ordinary rather than a sign of an error, because the same sequence often carries one accession from the group that submitted it and a second from a curated reference collection, and either accession is valid. An alignment mapped to either accession therefore resolves against any bundled scheme. A scheme you imported yourself is where this bites, since it names only the accessions you gave it, and a BAM whose contig carries a different name will not match.

Two further checks close the loop. Confirm the new track appears in the sidebar under the same reference bundle, alongside the untrimmed one rather than replacing it, since the source track surviving is what lets you compare. Then confirm the trimmed track is the one you carry into iVar variant calling, and that the dialog shows its primer-trim acknowledgement already ticked. If the checkbox is empty, the dialog is looking at a track with no primer-trim provenance, which usually means the wrong track is selected.

## On the command line

The same trim runs from the command line against a track inside a reference bundle. You pass the bundle, the source track's identifier, the scheme folder, and a name for the new track. The identifier is the short `aln_` string in the bundle's `manifest.json`, not the display name. It is not shown anywhere in the app, so reading it out of `manifest.json` is the only way to find it, and `lungfish-cli bundle list --tracks` on the bundle prints the tracks it holds.

```bash
lungfish-cli bam primer-trim \
  --bundle "Reference Sequences/MN908947.3.lungfishref" \
  --alignment-track aln_FB68A1C3 \
  --scheme "Primer Schemes/QIASeqDIRECT-SARS2.lungfishprimers" \
  --name "minimap2 mapping • Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)"
```

The four Advanced Options reach the command line as `--ivar-min-length`, `--ivar-min-quality`, `--ivar-sliding-window`, and `--ivar-primer-offset`, and their defaults match the dialog's at 30, 20, 4, and 0. Two flags have no counterpart in the dialog. `--format json` prints the run summary as JSON instead of as plain text. JSON is a structured text format that other programs can read without guessing at layout, which suits a script that needs to read the new track's identifier back. `--target-reference` overrides which contig name in the alignment the scheme is matched against, and it defaults to the scheme's own canonical accession. Reach for it when you mapped to a reference whose contig name differs from every accession the scheme lists.

The trimmed BAM lands in the bundle's `alignments/primer-trimmed` folder beside its index and its provenance sidecar, whether you ran from the dialog or from the command line, because the dialog runs this exact subcommand underneath.

The rest of this section is not terminal-only. To build a scheme LGE does not ship, which you do in the app whether or not you ever use the command line, open **File > Import Center...**, pick the Reference Sequences tab, and use the card titled Primer Scheme, which takes a BED file of primer coordinates and optionally a FASTA of the primer sequences themselves. LGE writes `manifest.json`, `primers.bed`, an optional `primers.fasta`, and `PROVENANCE.md` into `Primer Schemes/<name>.lungfishprimers` in your project. The command line builds the same folder.

```bash
lungfish-cli primers import \
  --bed my-panel.bed \
  --output MyPanel.lungfishprimers \
  --project "My Project.lungfish" \
  --display-name "My Amplicon Panel"
```

Note that `--fasta` on that command takes a FASTA of primer sequences, not the reference genome, and it is optional. None of the eight bundled schemes ships one.

## Next

Continue to [Alignment Quality](04-alignment-quality.md) for the coverage and duplicate checks that come next, or go straight to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) to call variants from the track you just trimmed.
