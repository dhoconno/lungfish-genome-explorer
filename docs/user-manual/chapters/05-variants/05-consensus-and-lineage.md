---
title: Extracting a Consensus Sequence
chapter_id: 05-variants/05-consensus-and-lineage
audience: bench-scientist
prereqs: [04-alignments/02-reading-an-alignment, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 20
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
illustrations:
  - id: pileup-consensus-column
    brief: "An alignment drawn as a grid on a Cream background, the reference sequence along the top row and eight or ten reads as rows beneath it, each column one reference position. Three columns are outlined in Lungfish Creamsicle and read downwards into a consensus row at the bottom. In the first every read shows A, and the consensus letter is A. In the second only three reads cover the position, below the depth floor, and the consensus letter is N. In the third about half the reads show A and half G, and the consensus letter is R, with a small note that R means A or G and appears only with ambiguity codes on. IBM Plex Mono for the letters, Deep Ink text."
glossary_refs: [alignment-track, benchmark-vcf, blast, consensus-sequence, contig-reference, depth, coverage-breadth, flag, homozygous, iupac-ambiguity-code, lineage, mapq, phred-score, pileup, provenance, provenance-sidecar, read-group, reference-bundle, samtools, variant-caller, checksum]
features_refs: []
fixtures_refs: [hg002-chr20, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A [consensus sequence](../../GLOSSARY.md#consensus-sequence) is one sequence that summarises many. This chapter builds the kind you get by reading an alignment downward instead of across. Picture the alignment as a grid. Each read is a row, each reference position is a column, and a [pileup](../../GLOSSARY.md#pileup) is the stack of read bases over one reference position. Ask which base most reads agree on in each column, in order, and you get one sequence that stands for the sample as a whole.

<!-- ILLUSTRATION: pileup-consensus-column -->

Lungfish Genome Explorer (LGE) builds that sequence in the Inspector's Consensus tab and writes it out with **Extract Consensus...**. The result has one letter per reference position in the stretch you chose. Where the reads gave enough evidence, the letter is the base they carried, which may differ from the reference, because the consensus describes your sample. Where the evidence fell short, the letter is `N`, meaning unknown. A position becomes `N` when too few reads covered it, when the reads disagreed too sharply to settle, or when the reads agree the base is deleted. With ambiguity codes off, as they are by default, the output holds only the four bases and `N`. Bases that reads carry between two reference positions, an insertion relative to the reference, have no position of their own, so LGE leaves them out of both the drawn consensus row and the extracted sequence. A sample with a real insertion therefore comes out without it, so check the alignment by eye wherever you expect one.

"Enough evidence" is where the judgement lives, and the Consensus tab is a set of dials for it. You decide how many reads must cover a position, whether to ignore reads the mapper placed without confidence, whether to ignore bases the sequencer reported without confidence, and whether disagreement is resolved into one winner or written as a letter standing for both. Reads disagree because the two copies of a chromosome carry different bases, or because the sequencer misread one of them. A permissive setting gives few `N` characters and some wrong letters. A strict one gives more `N` characters and more trust in the rest.

Under the surface LGE runs [samtools](../../GLOSSARY.md#samtools), which ships with the app. Treat the consensus as a summary you configure, not a fact you read off, and set the depth floor before you look at the sequence.

This chapter stops at the FASTA record. Naming a viral consensus with a lineage is covered in [Reading the lineage calls](../04-alignments/05-viral-recon-wizard.md#reading-the-lineage-calls), and lineage abundances in a mixed sample belong to [Running Freyja](../06-classification/07-running-freyja.md).

### Pileup consensus versus variants-applied consensus

Two different programs are called consensus builders, and they start from different evidence. A pileup consensus, the kind this chapter builds with `samtools consensus`, reads the reads themselves at every position and never looks at a VCF. A variants-applied consensus starts from the reference and writes in the changes a variant caller reported, as `bcftools consensus` does inside [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), which writes a change only when at least three quarters of the reads carry it and masks positions with fewer than 10 reads as `N`.

The two usually agree on a well-covered haploid sample, and they differ in what they do with doubt. A pileup consensus decides every position from its own reads, so a stretch the caller never reported still gets the reads' base, and a thin stretch becomes `N`. A variants-applied consensus copies the reference wherever no call was made, so it is only as good as the call set and the mask that come with it. Use a pileup consensus when you have the alignment in front of you and want the reads to speak for every position. Use the variants-applied one when a pipeline or a public submission standard asks for it, as SARS-CoV-2 surveillance does. The calls you made in [Calling Variants](01-calling-variants-from-amplicons.md) are not an input to this chapter.

## Why you would do this

The next program you want often reads sequences, not alignments. [BLAST](../../GLOSSARY.md#blast), the search that finds known sequences resembling yours, takes a FASTA record. So do tree-building programs and public database deposits. Consensus extraction is the conversion step.

A sequence is also readable in a way a variant list is not. The HG002 chromosome 20 slice is a 500,001-base stretch of human chromosome 20 from HG002, a reference sample laboratories sequence over and over. It comes with a [benchmark call set](../../GLOSSARY.md#benchmark-vcf) of 961 variants in this stretch. Reading those rows tells you what changed. Reading the consensus tells you what the sample is, including the long runs where nothing changed.

The consensus also reports its own uncertainty. A [variant caller](../../GLOSSARY.md#variant-caller) that finds nothing at a position is silent, whether the sample matched the reference or no reads were there. The consensus tells the two apart, a base for a match and an `N` for no evidence, so counting `N` characters measures how much of the sample you observed.

## Choosing a tool

Check whether your sample is haploid or diploid and whether it came from amplicons, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows. The choice then rests on what should happen at a position where the reads disagree, whether it becomes one base, an `N`, or a letter standing for both. The Consensus tab offers two modes of samtools consensus, and for SARS-CoV-2 the Viral Recon pipeline builds a consensus of its own.

**Bayesian** mode, the default, weighs the evidence statistically. At each position it weighs every base by its quality score, lowers the weight of bases that sit next to poor-quality bases, and takes account of how confidently each read was mapped. It allows for a position where the two copies of a chromosome differ, so with ambiguity codes on it writes such a position as a two-base letter. It suits human and macaque samples, and any data whose base qualities mean something. Its weakness is that the decision at one position is hard to reproduce by hand.

On a diploid sample either mode gives a blend of the two chromosome copies, not a [haplotype](../../GLOSSARY.md#haplotype), the sequence of one copy. Where the copies differ the consensus cannot say which base belongs to which copy, and with ambiguity codes off many such positions become `N`. Turn ambiguity codes on to keep those heterozygous sites visible as two-base letters.

**Simple** mode counts one vote for each base in the column and ignores quality scores. It writes the leading base only when at least 75 percent of the reads carry it and writes `N` otherwise, so a position split 60 to 40 becomes `N` rather than the majority base. With ambiguity codes on, a strong second base is written as a two-base letter instead. It is easy to explain and to check by hand, and it suits a haploid sample such as a virus, where a genuinely mixed position is the exception. It struggles where base quality varies a lot, because a doubtful base counts as much as a confident one.

**Viral Recon** builds a variants-applied consensus inside the pipeline, from primer-trimmed reads, and masks stretches with too little coverage before it assigns a [lineage](../../GLOSSARY.md#lineage), the named branch of the virus family tree the genome belongs to. For a SARS-CoV-2 genome headed for a public database, use it rather than this tab.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Bayesian mode | Diploid samples and quality-aware calls | The sample is a person or a macaque, whose two chromosome copies can differ | You need a rule a colleague can check by hand |
| Simple mode | A stated share of reads per base | The sample is haploid and you want a reproducible rule | Base quality varies widely across the reads |
| Viral Recon | SARS-CoV-2 amplicon genomes | The sequence is headed for a lineage call or a public deposit | The sample is not a virus the pipeline supports |

This chapter uses Bayesian mode on [HG002](../../GLOSSARY.md#hg002), a diploid human sample, and [Reading the results](#reading-the-results) shows what Simple mode changes on the same reads. Switch to Simple mode on a primer-trimmed viral alignment, with the depth floor raised to 10, the default of iVar's consensus command, or to 20, the depth below which the ARTIC pipeline masks a position, so that thin and mixed positions become `N` rather than a guess. samtools is cited in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge), and the samtools consensus manual page at <https://www.htslib.org/doc/samtools-consensus.html> describes both modes. Viral Recon is cited in [Pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines), and the ARTIC pipeline in [Other works cited in the manual](../appendices/bibliography.md#other-works-cited-in-the-manual).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` reads and the `GRCh38.chr20.10.0-10.5Mb` reference bundle this section imports, so map them as the next paragraphs describe. To import the files yourself instead, follow the rest of this section.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

You need an alignment inside a [reference bundle](../../GLOSSARY.md#reference-bundle), because **Extract Consensus...** stays disabled until the bundle holds an [alignment track](../../GLOSSARY.md#alignment-track). The `HG002 minimap2` alignment that [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) makes is the one this chapter reads, and mapping as it describes reproduces every number here. The Human Mapping and Variants (with results) demo project already holds it. samtools arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE.

## Procedure

1. Click the `minimap2-` mapping result under **Analyses** in the sidebar. The mapping viewport opens with the `HG002 minimap2` alignment in its lower pane, and the Inspector fills with the run's summary. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.
2. Open the Inspector's **Analysis** tab and click its **Consensus** tab, one of the six [Analysis tabs](../04-alignments/02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs). The tab opens with a note reading "Adjust consensus evidence settings here. Consensus controls are intentionally separate from View so display settings stay lighter." <!-- SHOT: analysis-consensus-tab -->
3. Leave **Show consensus track in viewer** on, so a consensus row draws above the reads and changes as you move the controls. Set **Consensus scope** to `Whole contig` for the whole slice, a [contig](../../GLOSSARY.md#contig-reference) being one named sequence in the reference.
4. Leave the evidence controls at their defaults for a first pass, **Consensus Mode** on `Bayesian`, **Consensus minimum depth** at 8, both quality floors at 0, and **Hide high-gap sites** off. Each slider has a number field beside it, so you can type an exact value instead of dragging. Turning **Hide high-gap sites** on reveals two more sliders, which the Settings section explains. <!-- SHOT: consensus-masking-sliders -->
5. Click **Extract Consensus...** below the divider. A row titled "Generate Alignment Consensus" appears in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), and a dialog headed Extract Sequence asks where the sequence should go. <!-- SHOT: consensus-destination-dialog --> Keep the default Destination, `Save as Bundle`, which writes a `.lungfishref` bundle that reopens in LGE directly. The other choices are `Save to File...` for a plain FASTA, `Copy to Clipboard`, and `Share...`. The button at the bottom reads Create Bundle, and renames itself Save, Copy, or Share to match your choice. Click it.

If every position in the scope falls below the depth floor, an alert headed "Consensus Contains Only N" appears first and asks whether to continue. Cancel, lower the depth floor to 4, and try again.

## Settings

Every control below sits in the Consensus tab and steers the consensus row drawn in the viewport. The mode, scope, ambiguity codes, and the depth, MAPQ, and base-quality floors also steer the sequence **Extract Consensus...** writes. The display toggle and the three gap-masking controls change only the drawn row. None of them has a command-line flag, because this operation has no command-line equivalent.

**Show consensus track in viewer.** Draws the consensus as its own row above the reads. The default is on, so you can judge a setting by looking at it rather than extracting a file. Turn it off when the viewport is crowded, which changes nothing about what extraction writes. This setting has no command-line flag.

**Consensus Mode.** Chooses how the base at each position is decided. The default is `Bayesian`, which weighs each base by its own quality score, the sequencer's confidence in that base, so a confident base counts for more than a doubtful one, the safer choice on real sequencing data. Switch to `Simple`, which ignores quality and writes a base only where at least 75 percent of the reads agree on it, when you want a call anyone can reproduce by hand. This setting has no command-line flag.

**Consensus scope.** Decides whether the sequence covers the whole contig or only a stretch you highlighted by dragging across the ruler. The default is `Whole contig`, which a whole-genome deposit or a tree needs. Choose `Selected region` for one gene or amplicon, and highlight the stretch first, because with nothing selected the button greys out above the line "Select a region in the viewer first". This setting has no command-line flag.

**Use IUPAC ambiguity codes.** Writes one letter standing for two or more bases wherever the reads disagree, instead of picking a winner. The default is off, because most downstream tools expect plain `A`, `C`, `G`, and `T`, and an `R` (`A` or `G`) or a `Y` (`C` or `T`) can confuse them. Turn it on when the mixture is itself the finding, such as the positions where a person's two chromosome copies differ, as the [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) entry explains. This setting has no command-line flag.

**Hide high-gap sites.** Masks columns where most reads spanning the position carry a gap rather than a base, since those columns are usually alignment artifacts. The default is off, which suits short accurate reads like this fixture's. Turn it on when a noisy alignment fills the drawn consensus row with gap-heavy columns you do not believe, which also reveals the two sliders below. It does not change the extracted sequence. This setting has no command-line flag.

**Consensus minimum depth.** Sets how many reads must cover a position before LGE calls a base there, writing `N` for anything thinner. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. The default of 8 is LGE's own starting point rather than a published standard. It sits a little below the 10 reads the Call Variants dialog asks for, and keeps most of a well-covered genome while refusing the thinnest evidence. The range is 1 to 50. Raise it to 10, the depth Viral Recon masks below, or to about 20 for a sequence going into a publication or deposit. This setting has no command-line flag.

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

Raising the depth floor to 20 turns 4,619 more positions into `N`, about five times the masking with no change to the data. `Simple` masks 149 more than `Bayesian`, because it writes `N` wherever fewer than 75 percent of the reads agree, and more columns fall short of that share than fail the Bayesian test. Ambiguity codes mask 666 fewer, because a conflicted column is written as an ambiguity letter instead of `N`. That row is a change of notation, not a gain. The run wrote 549 ambiguity letters, 182 `R`, 191 `Y`, and 176 among `M` (`A` or `C`), `W` (`A` or `T`), `K` (`G` or `T`), and `S` (`C` or `G`).

The settings behind every run are written down. Saving to a file or a bundle records them in the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file kept beside the FASTA, and a bundle carries the same record inside it. Copying to the clipboard logs a summary on the Operations Panel row instead. Both record two fixed policies, shown in the clipboard summary as `Low-depth policy: N` and `Reference-fill policy: never` and in the provenance as `lowDepthPolicy` and `referenceFillPolicy`. LGE never fills a thin position with the reference base, which would read as confirmation of the reference when it is really an absence of evidence. An `N` in the output always means no evidence.

The FASTA header names the sample, the contig, and the word consensus, as in `>HG002.chr20.10.0-10.5Mb chr20_10.0-10.5Mb consensus`. A selected-region consensus adds the 1-based coordinates to the contig and the word selected, as in `chr20_10.0-10.5Mb:2001-3000 selected consensus`.

### The human mitochondrion, a sequence worth reading

A diploid consensus such as HG002's chromosome 20 is a blend of two chromosome copies, so it is a good place to learn the dials and a poor thing to deposit or build a tree from. The human mitochondrial genome is the opposite case. A person carries one mitochondrial sequence in hundreds of copies per cell, so its consensus is a real sequence, the one mitochondrial disease testing, forensic identification, and studies of human migration read.

The Long Reads and Assembly demo project holds HG002's Illumina mitochondrial reads, `HG002.chrM`, beside the `NC_012920.1` reference, the revised Cambridge Reference Sequence (rCRS) that [Nanopore Variant Calling](04-nanopore-variant-calling.md#why-you-would-do-this) introduces. Mapped with minimap2 and the Short-read preset, 19,853 of the 19,916 reads land, at a mean depth of 295. The consensus at this chapter's default settings is 16,569 letters long, exactly the reference's length, and holds a single `N`, at position 3107. The rCRS itself carries an `N` there as a placeholder that keeps the historical numbering, so no read has a base to offer.

The consensus differs from the rCRS at 13 positions, 263, 310, 456, 750, 1438, 4336, 4769, 6800, 8557, 8860, 15175, 15326, and 16304. Raising the depth floor to 20 or switching to `Simple` changes none of them, because every position is deep and unanimous. Twelve are the substitutions the nanopore reads also support in [Nanopore Variant Calling](04-nanopore-variant-calling.md#reading-the-results), including the six near-universal differences from the rCRS and three haplogroup markers. The thirteenth, 310, sits in a run of C bases in the control region, where short reads align least reliably, so look at it in the viewport before you rely on it. The consensus also settles the two nanopore `0/1` calls at 9028 and 14229, where it carries the reference base, as every Illumina read does.

## What good looks like

First, check the length. A whole-contig consensus should be exactly as long as the contig, 500,001 on this fixture. A shorter sequence means the scope was `Selected region`.

Second, count the `N` characters against what you plan to do next. The fixture's 0.205 percent at the defaults and 1.129 percent at a depth floor of 20 bracket what the settings alone do to a well-covered sample. A share far above that points at the sequencing, not a slider.

Third, look at where the `N` characters sit. Scattered single `N` positions are ordinary noise. An unbroken run of hundreds is a stretch with no usable reads, and the coverage curve in the alignment viewport shows the same gap. No consensus setting fixes that.

Fourth, spot-check a position you already know. On this fixture it is 2,078, `G` in the reference and `A` in every read. On your own data, use any position with a variant call or a Sanger trace behind it. If it comes back as `N` or as the reference base, the filters are stricter than the data supports, and the depth floor is the first to loosen.

Fifth, read the recorded settings rather than your memory of the sliders, in the [provenance](../../GLOSSARY.md#provenance) record that [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads.

## On the command line

No `lungfish-cli` command builds a consensus from an alignment's reads, so this chapter has no command block to run. The operation history records the operation as `Lungfish.app alignment consensus`, which names the app rather than a command you can type. The run's provenance records the `samtools` steps LGE ran, which at the default settings on the whole contig take this form, with the file names shortened.

```text
samtools view -b -h -F <flags from Read Inclusion> -o filtered.bam alignment.bam
samtools index filtered.bam
samtools consensus -r chr20_10.0-10.5Mb -a -f FASTA -m bayesian --min-BQ 0 --ff 0 -d 8 --show-del yes --show-ins no filtered.bam
```

`-m simple` replaces `-m bayesian` in Simple mode, `-A` is added for ambiguity codes, `-d` carries the depth floor, and a MAPQ floor above 0 adds `-q` to the first line. LGE then turns every deleted base into `N`. The nearest `lungfish-cli` command, `msa consensus`, builds a consensus from a multiple sequence alignment of finished sequences, whose thresholds count sequences rather than reads, as [CLI Reference](../appendices/cli-reference.md#multiple-sequence-alignments-and-trees) lists.

## Next

Continue to [Importing Existing VCFs](06-importing-existing-vcfs.md) to read variant calls from an external pipeline, such as a benchmark, beside your own. For a consensus genome built end to end from reads with lineage calls attached, see [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md). For a mixed sample where one consensus would hide the mixture, see [Running Freyja](../06-classification/07-running-freyja.md).
