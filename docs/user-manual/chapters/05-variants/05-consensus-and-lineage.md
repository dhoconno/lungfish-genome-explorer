---
title: Extracting a Consensus Sequence
chapter_id: 05-variants/05-consensus-and-lineage
audience: bench-scientist
prereqs: [04-alignments/02-reading-an-alignment, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 16
task: Read one sequence out of an alignment's read pile and save it as a FASTA record or a reference bundle.
tags: [variants, consensus, alignment, samtools, fasta]
tools: [samtools]
parameters_refs: [bam.extract-consensus]
entry_points:
  - "Inspector > Analysis > Consensus > Extract Consensus..."
shots:
  - id: analysis-consensus-tab
    caption: "The Inspector's Consensus tab, showing Show consensus track in viewer, the Consensus Mode and Consensus scope pickers, the two toggles, the three evidence sliders with their number fields, and the Extract Consensus... button beneath the divider."
  - id: consensus-masking-sliders
    caption: "The Consensus tab with Hide high-gap sites turned on, revealing the Gap threshold and Masking minimum depth sliders between Consensus minimum depth and Consensus minimum MAPQ."
  - id: consensus-destination-dialog
    caption: "The Extract Sequence dialog showing its four Destination choices, with Save as Bundle selected by default above Save to File..., Copy to Clipboard, and Share..., and the Name field prefilled with the suggested consensus name."
illustrations: []
glossary_refs: [alignment-track, benchmark-vcf, blast, consensus-sequence, contig-reference, depth, coverage-breadth, flag, homozygous, iupac-ambiguity-code, mapq, phred-score, pileup, provenance, provenance-sidecar, read-group, reference-bundle, samtools, variant-caller, checksum]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A [consensus sequence](../../GLOSSARY.md#consensus-sequence) is what you get by reading an alignment downward instead of across. Picture the alignment as a grid. Each read is a row, each reference position is a column, and a [pileup](../../GLOSSARY.md#pileup) is the stack of read bases over one reference position. Ask which base most reads agree on in each column, in order, and you get one sequence that stands for the sample as a whole.

Lungfish Genome Explorer (LGE) builds that sequence in the Inspector's Consensus tab and writes it out with **Extract Consensus...**. The result has one letter per reference position in the stretch you chose. Where the reads gave enough evidence, the letter is the base they carried, which may differ from the reference, because the consensus describes your sample. Where the evidence fell short, the letter is `N`, meaning unknown. A position becomes `N` when too few reads covered it, when the reads disagreed too sharply to settle, or when the reads agree the base is deleted. With ambiguity codes off, as they are by default, the output holds only the four bases and `N`.

"Enough evidence" is where the judgement lives, and the Consensus tab is a set of dials for it. You decide how many reads must cover a position, whether to ignore reads the mapper placed without confidence, whether to ignore bases the sequencer reported without confidence, and whether disagreement is resolved into one winner or written as a letter standing for both. Reads disagree because the two copies of a chromosome carry different bases, or because the sequencer misread one of them. A permissive setting gives few `N` characters and some wrong letters. A strict one gives more `N` characters and more trust in the rest.

Under the surface LGE runs [samtools](../../GLOSSARY.md#samtools), which ships with the app. Treat the consensus as a summary you configure, not a fact you read off, and set the depth floor before you look at the sequence.

This chapter stops at the FASTA record. Lineage assignment happens inside the [Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), and lineage abundances in a mixed sample belong to [Running Freyja](../06-classification/07-running-freyja.md).

## Why you would do this

The next program you want often reads sequences, not alignments. [BLAST](../../GLOSSARY.md#blast), the search that finds known sequences resembling yours, takes a FASTA record. So do tree-building programs and public database deposits. Consensus extraction is the conversion step.

A sequence is also readable in a way a variant list is not. The HG002 chromosome 20 slice is a 500,001-base stretch of human chromosome 20 from HG002, a reference sample laboratories sequence over and over. It comes with a [benchmark call set](../../GLOSSARY.md#benchmark-vcf) of 961 variants in this stretch. Reading those rows tells you what changed. Reading the consensus tells you what the sample is, including the long runs where nothing changed.

The consensus also reports its own uncertainty. A [variant caller](../../GLOSSARY.md#variant-caller) that finds nothing at a position is silent, whether the sample matched the reference or no reads were there. The consensus tells the two apart, a base for a match and an `N` for no evidence, so counting `N` characters measures how much of the sample you observed.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` reads and the `GRCh38.chr20.10.0-10.5Mb` reference bundle this section imports, so map them as the next paragraphs describe. To import the files yourself instead, follow the rest of this section.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

You need an alignment inside a [reference bundle](../../GLOSSARY.md#reference-bundle), because **Extract Consensus...** stays disabled until the bundle holds an [alignment track](../../GLOSSARY.md#alignment-track). If you have not mapped the fixture reads yet, [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) does that, and mapping as it describes should reproduce every number in this chapter. Nothing needs installing, because samtools arrives with the app.

## Procedure

1. Click the alignment track in the sidebar, nested beneath its reference bundle and named "minimap2 Mapping" by default after the mapper, the program that placed each read on the reference. The alignment viewport opens, and the Inspector fills with the alignment's summary. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.
2. Open the Inspector's **Analysis** section and click its **Consensus** tab, one of the six [Analysis tabs](../04-alignments/02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs). The tab opens with a note reading "Adjust consensus evidence settings here. Consensus controls are intentionally separate from View so display settings stay lighter." <!-- SHOT: analysis-consensus-tab -->
3. Leave **Show consensus track in viewer** on, so a consensus row draws above the reads and changes as you move the controls. Set **Consensus scope** to `Whole contig` for the whole slice, a [contig](../../GLOSSARY.md#contig-reference) being one named sequence in the reference.
4. Leave the evidence controls at their defaults for a first pass, **Consensus Mode** on `Bayesian`, **Consensus minimum depth** at 8, both quality floors at 0, and **Hide high-gap sites** off. Each slider has a number field beside it, so you can type an exact value instead of dragging. Turning **Hide high-gap sites** on reveals two more sliders, which the Settings section explains. <!-- SHOT: consensus-masking-sliders -->
5. Click **Extract Consensus...** below the divider. A row titled "Generate Alignment Consensus" appears in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), and a dialog headed Extract Sequence asks where the sequence should go. <!-- SHOT: consensus-destination-dialog --> Keep the default Destination, `Save as Bundle`, which writes a `.lungfishref` bundle that reopens in LGE directly. The other choices are `Save to File...` for a plain FASTA, `Copy to Clipboard`, and `Share...`. The button at the bottom reads Create Bundle, and renames itself Save, Copy, or Share to match your choice. Click it.

If every position in the scope falls below the depth floor, an alert headed "Consensus Contains Only N" appears first and asks whether to continue. Cancel, lower the depth floor to 4, and try again.

## Settings

Every control below sits in the Consensus tab and steers the consensus row drawn in the viewport. The mode, scope, ambiguity codes, and the depth, MAPQ, and base-quality floors also steer the sequence **Extract Consensus...** writes. The display toggle and the three gap-masking controls change only the drawn row. None of them has a command-line flag, because this operation has no command-line equivalent.

**Show consensus track in viewer.** Draws the consensus as its own row above the reads. The default is on, so you can judge a setting by looking at it rather than extracting a file. Turn it off when the viewport is crowded, which changes nothing about what extraction writes. This setting has no command-line flag.

**Consensus Mode.** Chooses how the base at each position is decided. The default is `Bayesian`, which weighs each base by its own quality score, the sequencer's confidence in that base, so a confident base counts for more than a doubtful one, the safer choice on real sequencing data. Switch to `Simple`, a plain majority that ignores quality, when you want a call anyone can reproduce by hand. This setting has no command-line flag.

**Consensus scope.** Decides whether the sequence covers the whole contig or only a stretch you highlighted by dragging across the ruler. The default is `Whole contig`, which a whole-genome deposit or a tree needs. Choose `Selected region` for one gene or amplicon, and highlight the stretch first, because with nothing selected the button greys out above the line "Select a region in the viewer first". This setting has no command-line flag.

**Use IUPAC ambiguity codes.** Writes one letter standing for two or more bases wherever the reads disagree, instead of picking a winner. The default is off, because most downstream tools expect plain `A`, `C`, `G`, and `T`, and an `R` (`A` or `G`) or a `Y` (`C` or `T`) can confuse them. Turn it on when the mixture is itself the finding, such as the positions where a person's two chromosome copies differ, as the [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) entry explains. This setting has no command-line flag.

**Hide high-gap sites.** Masks columns where most reads spanning the position carry a gap rather than a base, since those columns are usually alignment artifacts. The default is off, which suits short accurate reads like this fixture's. Turn it on when a noisy alignment fills the drawn consensus row with gap-heavy columns you do not believe, which also reveals the two sliders below. It does not change the extracted sequence. This setting has no command-line flag.

**Consensus minimum depth.** Sets how many reads must cover a position before LGE calls a base there, writing `N` for anything thinner. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. The default of 8 keeps most of a well-covered genome while refusing the thinnest evidence, and the range is 1 to 50. Raise it to about 20 for a sequence going into a publication or deposit. This setting has no command-line flag.

**Gap threshold.** Sets what share of the spanning reads must carry a gap before a column is masked. The default is 90 percent, so only a column the reads almost unanimously call empty is masked, and the range is 50 to 99 percent. Lower it when obvious artifact columns survive, and note that it appears only while **Hide high-gap sites** is on. This setting has no command-line flag.

**Masking minimum depth.** Sets how many reads must span a position before gap masking may act on it, so a thin pile is never masked on two reads' evidence. The default is 8, matching the depth floor, and the range is 1 to 50. It is rarely worth changing, and it appears only while **Hide high-gap sites** is on. This setting has no command-line flag.

**Consensus minimum MAPQ.** Ignores reads the mapper was not confident it placed. [MAPQ](../../GLOSSARY.md#mapq) is the mapper's confidence in where it placed a read, from 0 for a read that fits several places equally to 60 for one clear placement, as [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records) explains. The default is 0, which applies no floor of its own. The alignment view's **Minimum alignment confidence** slider also applies, and the higher of the two wins. Raise it to about 20 when repeated sequence drags misplaced reads into the consensus. This setting has no command-line flag.

**Consensus minimum base quality.** Ignores individual bases the sequencer called with low confidence. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The default is 0, which uses every base, and the range runs to 60. Raise it to about 20 when the run's quality is poor, knowing that with `Bayesian` mode the cutoff stacks on top of the weighting. This setting has no command-line flag.

Further filters reach the consensus from outside this tab. The **Minimum alignment confidence** slider sets a MAPQ floor, as above. The **Read Inclusion** toggles in the Inspector's view settings for the alignment decide whether duplicate-marked, secondary, and supplementary records are included, a marked record being a read the aligner tagged with a [FLAG](../../GLOSSARY.md#flag), and the read-group choices decide which [read groups](../../GLOSSARY.md#read-group) count. The consensus is built from exactly the reads those settings include. The viewport's depth cap for drawing reads does not reach it. The consensus always uses every read, however deep the pile.

## Reading the results

Run at the defaults with `Whole contig` scope, the fixture gives a sequence 500,001 letters long. Check that first, because it should match the reference exactly. The slice counts both ends of the 10.0 to 10.5 megabase range, which is why it is not the round 500,000 its name suggests.

Of those letters, 498,974 are a plain `A`, `C`, `G`, or `T` and 1,027 are `N`, 0.205 percent of the slice. The `N` positions are where fewer than eight reads covered the position, where the pileup was too conflicted, or where the reads agree on a deletion, so an `N` count is not purely a measure of what you failed to observe.

Comparing the consensus letter by letter against `GRCh38.chr20.10.0-10.5Mb.fasta` finds 337 positions where a called letter differs from the reference. That sits below the benchmark's 961 variants because the two measure different things. A consensus has one letter per reference position, so an insertion or deletion does not show as a differing letter, and a masked `N` is not compared at all. Treat 337 as visible single-letter differences, not a variant count.

The first difference is at position 2,078, counted from the start of the slice, which **Sequence > Go to Location...** (Cmd-L) reaches as `chr20_10.0-10.5Mb:2078`, where the reference carries `G` and the consensus carries `A`. Every read base in the pileup there is `A`, so both of this person's copies of chromosome 20 carry the change, a [homozygous](../../GLOSSARY.md#homozygous) position a consensus should call without hesitation.

Each row below is a run of the fixture alignment with one setting changed from the defaults.

| Setting changed | `N` count | Share of the slice |
|---|---|---|
| None, the defaults | 1,027 | 0.205 percent |
| **Consensus minimum depth** raised to 20 | 5,646 | 1.129 percent |
| **Consensus Mode** set to `Simple` | 1,176 | 0.235 percent |
| **Use IUPAC ambiguity codes** turned on | 361 | 0.072 percent |
| **Consensus minimum MAPQ** raised to 20 | 1,107 | 0.221 percent |

Raising the depth floor to 20 turns 4,619 more positions into `N`, about five times the masking with no change to the data. `Simple` masks 149 more than `Bayesian`, because without quality weighting more columns lack a clear winner. Ambiguity codes mask 666 fewer, because a conflicted column is written as an ambiguity letter instead of `N`. That row is a change of notation, not a gain. The run wrote 549 ambiguity letters, 182 `R`, 191 `Y`, and 176 among `M` (`A` or `C`), `W` (`A` or `T`), `K` (`G` or `T`), and `S` (`C` or `G`).

The settings behind every run are written down. Saving to a file or a bundle records them in the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file kept beside the FASTA, and a bundle carries the same record inside it. Copying to the clipboard logs a summary on the Operations Panel row instead. Both record two fixed policies, shown in the clipboard summary as `Low-depth policy: N` and `Reference-fill policy: never` and in the provenance as `lowDepthPolicy` and `referenceFillPolicy`. LGE never fills a thin position with the reference base, which would read as confirmation of the reference when it is really an absence of evidence. An `N` in the output always means no evidence.

The FASTA header names the sample, the contig, and the word consensus, and a selected-region consensus adds the coordinates.

## What good looks like

First, check the length. A whole-contig consensus should be exactly as long as the contig, 500,001 on this fixture. A shorter sequence means the scope was `Selected region`.

Second, count the `N` characters against what you plan to do next. The fixture's 0.205 percent at the defaults and 1.129 percent at a depth floor of 20 bracket what the settings alone do to a well-covered sample. A share far above that points at the sequencing, not a slider.

Third, look at where the `N` characters sit. Scattered single `N` positions are ordinary noise. An unbroken run of hundreds is a stretch with no usable reads, and the coverage curve in the alignment viewport shows the same gap. No consensus setting fixes that.

Fourth, spot-check a position you already know. On this fixture it is 2,078, `G` in the reference and `A` in every read. On your own data, use any position with a variant call or a Sanger trace behind it. If it comes back as `N` or as the reference base, the filters are stricter than the data supports, and the depth floor is the first to loosen.

Fifth, read the recorded settings rather than your memory of the sliders. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

No `lungfish-cli` command builds a consensus from an alignment's reads. The operation history records this operation as `Lungfish.app alignment consensus`, which names the app rather than a command you can type. The nearest command, `lungfish-cli msa consensus`, builds a consensus from a multiple sequence alignment bundle, where each row is one finished sequence rather than a read.

```bash
lungfish-cli msa consensus my-alignment.lungfishmsa \
  --output consensus.fa --name "HG002 consensus"
```

Its thresholds count sequences, not reads, so none of the Settings above carry over.

## Next

Continue to [Importing Existing VCFs](06-importing-existing-vcfs.md) to read variant calls from an external pipeline. For a consensus genome built end to end from reads with lineage calls attached, see the [Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md). For a mixed sample where one consensus would hide the mixture, see [Running Freyja](../06-classification/07-running-freyja.md).
