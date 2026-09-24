---
title: Calling Variants
chapter_id: 05-variants/01-calling-variants-from-amplicons
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 01-foundations/05-variants-and-vcf, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming]
estimated_reading_min: 14
task: Call variants from a bundle-owned alignment track with bcftools and LoFreq, and know when to reach for iVar instead.
tags: [variants, variant-calling, bcftools, lofreq, ivar, vcf, hg002]
tools: [bcftools, lofreq, ivar, samtools, htslib]
parameters_refs: [variants.call-bcftools, variants.call-lofreq, variants.call-ivar]
entry_points:
  - "Tools > Call Variants..."
  - "Inspector > Analysis > Variant Calling > Call Variants..."
  - "CLI: lungfish-cli variants call"
shots:
  - id: call-variants-dialog-bcftools
    caption: "The Call Variants dialog with bcftools selected, showing the tool sidebar on the left and the Overview, Thresholds, and bcftools Settings sections on the right, with the Ploidy control set to Diploid."
  - id: call-variants-dialog-ivar
    caption: "The Call Variants dialog with iVar selected, showing the primer-trim checkbox already ticked and the iVar Options section that only iVar displays."
  - id: variants-tab-two-callers
    caption: "The Variants tab of the table drawer with both the bcftools and LoFreq tracks loaded, and the Variant Track column naming which track each row came from."
illustrations: []
glossary_refs: [alignment-track, allele-frequency, amplicon, bam, bcftools, benchmark-vcf, bgzip, codon, depth, filter, genotype, indel, ivar, lofreq, mpileup, phred-score, pileup, ploidy, plugin-pack, primer-scheme, primer-trim, provenance, reference-bundle, required-setup-pack, shotgun, table-drawer, tabix, variant-caller, vcf]
features_refs: [variants.call]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Variant calling turns an alignment into a list of differences. A [variant caller](../../GLOSSARY.md#variant-caller) reads a [BAM](../../GLOSSARY.md#bam) file, walks the reference one position at a time, looks at the [pileup](../../GLOSSARY.md#pileup) of read bases stacked over each position, and writes a row wherever the reads disagree with the reference strongly enough. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md) explains its columns. This chapter produces the file.

Lungfish Genome Explorer (LGE) runs the caller for you. You pick an [alignment track](../../GLOSSARY.md#alignment-track), one named BAM already attached to a [reference bundle](../../GLOSSARY.md#reference-bundle), and a caller. LGE runs the tool, sorts, compresses, and indexes the output, and files it inside the bundle as a named variant track. The alignment itself is only read, never changed.

The six callers in the dialog are not six ways of doing the same thing. Each was built around an assumption about how the reads were produced, and three matter here.

- **bcftools** asks which [genotype](../../GLOSSARY.md#genotype) best explains the pileup at each position, given how many copies of each chromosome the sample carries, its [ploidy](../../GLOSSARY.md#ploidy). A virus or a mitochondrion has one copy, which makes it haploid, and a human has two, which makes it diploid. LGE picks the ploidy from what the bundle records about the organism, and on a diploid sample bcftools writes `0/1` for a [heterozygous](../../GLOSSARY.md#heterozygous) site, where one copy carries the change, and `1/1` where both do.
- **LoFreq** builds an error model, an estimate of how often the instrument misreads a base, from the base qualities, and reports changes whose reads outnumber that error rate. Base quality is the sequencer's confidence in each base, the Phred score described under Minimum ALT quality below. It reports the fraction of reads carrying each change rather than a genotype, which suits samples whose true fractions can be anything, such as a mixed infection or a tumour biopsy.
- **[iVar](../../GLOSSARY.md#ivar)** reports the observed fraction of reads carrying each change above a fixed threshold. It is written for [amplicon](../../GLOSSARY.md#amplicon) data whose primer bases have already been clipped away.

The other three are Medaka and Clair3, which [Nanopore Variant Calling](04-nanopore-variant-calling.md) covers, and GATK HaplotypeCaller, which [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) covers. Match the caller to how the sample was prepared before you look at a row of output.

## Why you would do this

The worked example is human. HG002 is a consenting research participant whose DNA is distributed as a cell line, so laboratories everywhere sequence the same genome. The HG002 chromosome 20 slice holds Illumina reads from that cell line, mapped to a 500 kilobase stretch of chromosome 20. Calling variants on it asks which positions differ from the reference in this person, and the question has a checkable answer.

The fixture ships with a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), 961 calls the Genome in a Bottle consortium produced for HG002 by combining many sequencing platforms and callers. Those calls did not come from the fixture's reads, so they work as an outside answer key. Few real projects offer one, and learning to ask how a call set was checked is easiest where the checking is possible. Every clinical genetics pipeline and population study begins with this step.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

What the dialog reads is the alignment those files produce. Import the FASTA and the two FASTQ files, then map them with **Tools > Mapping > minimap2...** as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes. That leaves a reference bundle carrying an alignment track named "minimap2 Mapping" by default. The caller only works on a track the bundle owns, never on a loose BAM in a folder.

bcftools arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. For LoFreq and iVar, install the `variant-calling` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. A caller whose pack is missing still appears in the dialog, greyed out and badged with the tool it lacks, such as "Requires LoFreq".

## Procedure

### Step 1. Open the Call Variants dialog

Select the reference bundle in the sidebar, then choose **Tools > Call Variants...**. The menu item is greyed out until a bundle with a usable alignment track is loaded.

A second route opens the same dialog. Click an alignment track in the sidebar, open the Inspector's **Analysis** section and click its **Variant Calling** tab, one of the six [Analysis tabs](../04-alignments/02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs), then click **Call Variants...**. Neither route preselects the track you came from. The dialog opens on the first eligible alignment track, so check the Alignment Track menu before you run.

### Step 2. Read the dialog before you change anything

A tool sidebar down the left lists the six callers, and **LoFreq** is selected when the dialog opens. The right side is one scrolling pane, and a footer carries a readiness message, a Cancel button, and a Run button.

Five sections stack down that pane for every caller. **Overview** holds the Alignment Track menu and the Output Variant Track Name field. **Thresholds** holds Minimum Allele Frequency and Minimum Depth. A section named for the selected caller comes next, such as "bcftools Settings". **Extra arguments** is a single text field, and **Readiness** repeats the footer's message. Selecting iVar adds an **iVar Options** section that no other caller shows.

<!-- SHOT: call-variants-dialog-bcftools -->

The Thresholds fields filter the output of every caller except GATK HaplotypeCaller. iVar applies them itself while calling. For bcftools, LoFreq, Medaka, and Clair3, LGE runs a filtering step after the caller finishes that removes every row below either threshold, reading the allele fraction and depth each caller writes. A caller whose VCF lacks the needed value skips that threshold, and the run's [provenance](../../GLOSSARY.md#provenance) records only the thresholds that were applied. The defaults, 0.05 (a change seen in at least one read in twenty) and 10 (at least ten reads covering the position), suit almost every run.

### Step 3. Call with bcftools

Click **bcftools** in the tool sidebar. Its section opens with the line "bcftools will run mpileup and call as an orthogonal cross-check on the selected BAM", where orthogonal means a second opinion reached by a different route. Under it sits one control, **Ploidy**, offering Haploid and Diploid, with a caption naming the choice LGE made for this bundle and the evidence it used. On the fixture the caption gives Diploid, taken from the assembly name GRCh38 in the bundle's name, and Diploid is right for a human sample. Check that the Alignment Track menu names your minimap2 track. The Output Variant Track Name fills in as "minimap2 Mapping • bcftools". Leave every field alone and click **Run**.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). LGE indexes the reference, runs [`bcftools mpileup`](../../GLOSSARY.md#mpileup) feeding straight into `bcftools call`, applies the threshold filter, sorts the rows, compresses the file with [`bgzip`](../../GLOSSARY.md#bgzip), indexes it with [`tabix`](../../GLOSSARY.md#tabix), and loads the rows into the database the table filters. When the run finishes, its row ends with "Created variant track minimap2 Mapping • bcftools".

### Step 4. Call with LoFreq on the same alignment

Open the dialog again and click **LoFreq**. Its section reads "LoFreq is ready to run directly on the selected bundle alignment track." and holds no controls. The output name fills in as "minimap2 Mapping • LoFreq". Click **Run**.

Calling the same alignment twice is not wasted work. The two files disagree, and [Reading the Variants Table](02-reading-the-variant-browser.md) reads that disagreement in the one table both tracks load into.

### Step 5. Open the results

Click the reference bundle in the sidebar. The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](02-reading-the-variant-browser.md#what-it-is) covers. Both tracks load into the one table, and the **Variant Track** column names the track each row came from.

<!-- SHOT: variants-tab-two-callers -->

### Step 6. Know where iVar belongs

Do not run iVar on this fixture. iVar assumes amplicon data whose primer bases have been clipped out. The HG002 reads are [shotgun](../../GLOSSARY.md#shotgun), made from DNA broken at random, so no primer sits on them. The dialog enforces the assumption. Selecting iVar with an untrimmed BAM leaves the readiness line reading "Confirm the BAM was primer-trimmed before running iVar." and the Run button disabled until you tick the checkbox.

On a track LGE primer-trimmed, the checkbox is already ticked and greyed out, with a caption naming the date and the [primer scheme](../../GLOSSARY.md#primer-scheme). LGE reads that from the [primer-trim](../../GLOSSARY.md#primer-trim) record filed beside the BAM. [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) produces such a track, and it is the right input for iVar.

<!-- SHOT: call-variants-dialog-ivar -->

When the bundle carries gene annotations, LGE hands them to iVar so that two neighbouring changes inside one [codon](../../GLOSSARY.md#codon), the three bases that encode one amino acid, can be reported as a single row. The merged row names the one amino acid the pair produces, where two separate rows would each name a change that never happened alone. Three tests decide whether a pair merges, tested in order. Both frequencies sit above the Consensus allele frequency setting, or both sit between 0.40 and 0.60, or their gap is smaller than the Merge AF distance setting. So changes at 0.45 and 0.55 merge by the second test whatever the settings say. The Settings entries below explain the two settings.

## Settings

Every setting in the dialog for the three callers this chapter covers is below. Where a setting behaves differently by caller, the entry says so.

**Alignment Track.** Chooses which alignment the caller reads, and the alignment is only read, never rewritten. The default is the first eligible track in the bundle, meaning a BAM whose file and index are both present, rather than the track you clicked. Change it when the bundle holds more than one alignment, and for iVar always pick the primer-trimmed one. On the command line this is `--alignment-track`.

**Output Variant Track Name.** Names the variant track the run creates, and that name fills the Variant Track column of the Variants tab. The default is the alignment name, a bullet, and the caller name, such as "minimap2 Mapping • bcftools", and a name already in use gets a number added rather than overwriting anything. Change it when you want a shorter or clearer label. On the command line this is `--name`.

**Minimum Allele Frequency.** Sets the smallest fraction of reads that must carry the change for a row to be kept, so 0.05 keeps a change seen in five reads of every hundred. The default is 0.05, and it becomes iVar's own `-t` value, while for the other callers LGE removes rows below it after the caller runs. Lower it toward 0.01 when hunting minority variants in deep amplicon data, and raise it when only near-fixed changes interest you. On the command line this is `--min-af`.

**Minimum Depth.** Sets how many reads must cover a position for a row there to be kept. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. The default is 10, about the thinnest evidence worth calling on, and it becomes iVar's `-m` value while the other callers are filtered after the run. Raise it when coverage is deep and you want only well-supported calls. On the command line this is `--min-depth`.

**This BAM has already been primer-trimmed for iVar..** States that the primer bases have been clipped out of this alignment, which iVar assumes without checking. It defaults to off, and to on and locked when LGE finds a primer-trim record beside the BAM. Tick it yourself only when you trimmed the BAM outside LGE, never on an untrimmed amplicon BAM, where every primer position would read as a variant. On the command line this is `--ivar-primer-trimmed`.

**Consensus allele frequency.** Sets the frequency above which a change counts as the consensus base, the first test for folding two changes in one codon into one row. The default is 0.75, so only changes present in most reads merge this way. Lower it when a real double change sits at an intermediate frequency and you want it merged. On the command line this is `--ivar-consensus-af`.

**Merge AF distance.** Sets how close two neighbouring frequencies must be for their changes to fold into one codon row, the last of the three tests. The default is 0.25, so changes at 0.30 and 0.50 merge while 0.30 and 0.90 do not. Tighten it when unrelated changes are merged, and loosen it when a genuine pair stays split. On the command line this is `--ivar-merge-af-threshold`.

**Minimum ALT quality.** Writes `bq` in the FILTER column of a call whose alternate (ALT) bases, the non-reference bases, average below this quality, and keeps the row. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The default is 20, the usual floor for Illumina data, and raising it toward 30 flags more low-quality calls. On the command line this is `--ivar-bad-quality-threshold`.

**Ignore strand bias (recommended for amplicons).** Skips the check that a change appears on both DNA strands in similar numbers. It defaults to on, because every read in an amplicon starts at a primer and so lands on that primer's strand, which makes the check flag real variants. Turn it off only for shotgun libraries, where strand imbalance is a real warning sign. On the command line the flag is inverted, `--ivar-no-ignore-strand-bias`.

**Ploidy.** Tells bcftools how many copies of each chromosome the sample carries, which decides whether a heterozygous genotype such as `0/1` can be written at all. It appears for bcftools alone, offering Haploid, which passes `--ploidy 1`, and Diploid, which passes `--ploidy 2`. The default comes from the bundle, read from a ploidy note, an NCBI Virus record, a GenBank division, the organism name, or a well-known assembly name such as GRCh38, and it is Haploid when nothing identifies the organism, as the caption then says. Choose Diploid yourself for a human or macaque reference imported under an uninformative name, since a human run that returns almost no `0/1` genotypes was called haploid. On the command line this is `--ploidy`, which takes `1` or `2`, and leaving it off derives the value the way the dialog does.

**Extra arguments.** Passes text straight to the caller without LGE checking it, placed right after `bcftools call`, `lofreq call`, or `ivar variants`. The default is empty, which is right for almost every run. Use it for an option the dialog does not show, such as `--call-indels` to switch on LoFreq's indel calling, which adds a preparation pass over a copy of the BAM. For bcftools it refuses `--ploidy`, and the Readiness line points you to the Ploidy setting instead. On the command line this is `--extra-args`.

## Reading the results

Run with every setting left alone, bcftools writes 1,040 rows at 1,038 positions and LoFreq writes 862 rows at 861 positions. A caller writes a second row at a position where it found a second, different change. Neither caller samples reads at random, so the same alignment, reference, and settings give the same rows every time.

Of the 1,040 bcftools rows, 859 are single-base substitutions and 181 are [indels](../../GLOSSARY.md#indel), insertions or deletions. All 862 LoFreq rows are substitutions, because LoFreq calls no indels unless asked. The substitutions agree closely, since 850 of the 859 positions where bcftools called one also carry a LoFreq row.

The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains. Every bcftools row reads `.` and every LoFreq row reads `PASS`, which is why the **PASS** chip, a one-click filter button above the table, hides the whole bcftools track, as [Step 4 of Reading the Variants Table](02-reading-the-variant-browser.md#step-4-filter-with-the-preset-chips) shows. The two files also differ in shape. The bcftools VCF carries one sample column, named HG002, holding a [genotype](../../GLOSSARY.md#genotype) on every row, with 617 rows reading `0/1`, 405 reading `1/1`, and 18 reading `1/2`. In `1/2`, `2` is the second alternate allele, so both copies carry a change but not the same one. The LoFreq VCF has no sample column and reports [allele frequency](../../GLOSSARY.md#allele-frequency) in its `INFO` field instead.

Each variant track lives inside the reference bundle's `variants/` folder as a `.vcf.gz` file, its `.vcf.gz.tbi` index, and a `.db` database the table queries, beside a provenance record with the same stem. For the bcftools track these come to about 50 KB, 371 bytes, and 2.4 MB. The shared name is the track id, `vc-` followed by a long identifier LGE assigns. The window does not show it. To see the folder, Control-click the bundle in Finder and choose Show Package Contents.

## What good looks like

Four checks are worth making before you trust a call set.

First, read the row count against the region. LoFreq's 862 rows across 500 kilobases is about one difference every 580 bases, the right order for a human sample, where about one base in a thousand differs from the reference. Single digits would mean a broken alignment or the wrong reference. Tens of thousands would mean sequencing error is being called.

Second, read the FILTER column before you filter on it. A track of all `PASS` and a track of all `.` need different handling, and only one has been judged by anything.

Third, check the calls against the benchmark. Comparing positions only, 954 of the 1,038 positions bcftools called and 808 of the 861 positions LoFreq called match a position in the 961-call benchmark. Out of the benchmark's 961 positions, that is 99 percent for bcftools and 84 percent for LoFreq, and 150 of the 153 benchmark positions LoFreq misses are indels, which it was not asked to call. Most of each caller's own calls match, 92 and 94 percent, which is what a sound call set looks like. A position match is not genotype agreement, and a real accuracy assessment needs a separate benchmarking program such as `hap.py`, which LGE does not ship and this manual does not cover.

Fourth, read the provenance. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. The bcftools run records version 1.24. The LoFreq run records no usable version, because that program rejects `--version` and the field holds its error message instead.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The command below reproduces steps 3 and 4 on a bundle that already carries the minimap2 track. Replace the path with your own, keeping the double quotes.

```bash
BUNDLE="MyProject.lungfish/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref"

for caller in bcftools lofreq; do
  lungfish-cli variants call --bundle "$BUNDLE" \
      --alignment-track hg002-minimap2 --caller "$caller" \
      --min-af 0.05 --min-depth 10 \
      --name "HG002 $caller"
done
```

Leave out `--ploidy` and bcftools takes the same derived value the dialog shows, or pass `--ploidy 1` or `--ploidy 2` to set it. The flag is refused for any other caller. The command line has no default thresholds. Leave `--min-af 0.05 --min-depth 10` off and no threshold filter runs, so the counts differ from a window run, which always sends the two field values. Replace `hg002-minimap2` with the id of your own alignment track. To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes, and the copied text carries the track id.

## Next

[Reading the Variants Table](02-reading-the-variant-browser.md) takes the two tracks you just made and covers the table that shows them. [Nanopore Variant Calling](04-nanopore-variant-calling.md) covers Medaka and Clair3 for long reads.
