---
title: Calling Variants
chapter_id: 05-variants/01-calling-variants-from-amplicons
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 01-foundations/05-variants-and-vcf, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming]
estimated_reading_min: 19
task: Call variants from a bundle-owned alignment track with bcftools and LoFreq on shotgun data and with iVar on a primer-trimmed amplicon track.
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
    caption: "The Call Variants dialog with iVar selected on an alignment that has not been primer-trimmed, showing the unticked primer-trim confirmation, the iVar Options section that only iVar displays, and the Readiness line asking you to confirm the BAM was primer-trimmed."
  - id: variants-tab-two-callers
    caption: "The Variants tab of the table drawer with both the bcftools and LoFreq tracks loaded, and the Variant Track column naming which track each row came from."
illustrations: []
glossary_refs: [alignment-track, allele-frequency, amplicon, bam, bcftools, benchmark-vcf, bgzip, codon, depth, filter, genotype, indel, ivar, lofreq, mpileup, phred-score, pileup, ploidy, plugin-pack, primer-scheme, primer-trim, provenance, reference-bundle, required-setup-pack, shotgun, strand-bias, lineage, table-drawer, tabix, variant-caller, vcf]
features_refs: [variants.call]
fixtures_refs: [hg002-chr20, sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Variant calling turns an alignment into a list of differences. A [variant caller](../../GLOSSARY.md#variant-caller) reads a [BAM](../../GLOSSARY.md#bam) file, walks the reference one position at a time, looks at the [pileup](../../GLOSSARY.md#pileup) of read bases stacked over each position, and writes a row wherever the reads disagree with the reference strongly enough. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md) explains its columns. This chapter produces the file.

Lungfish Genome Explorer (LGE) runs the caller for you. You pick an [alignment track](../../GLOSSARY.md#alignment-track), one named BAM already attached to a [reference bundle](../../GLOSSARY.md#reference-bundle), and a caller. After mapping, that bundle is the reference bundle inside the mapping result, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE runs the tool, sorts, compresses, and indexes the output, and files it inside the same bundle as a named [variant track](../../GLOSSARY.md#variant-track). The alignment itself is only read, never changed.

The six callers in the dialog are not six ways of doing the same thing. Each was built around an assumption about how the reads were produced, and three matter here.

- **bcftools** asks which [genotype](../../GLOSSARY.md#genotype) best explains the reads at each position, given how many copies of each chromosome the sample carries, its [ploidy](../../GLOSSARY.md#ploidy). [Choosing a tool](#choosing-a-tool) shows how it decides.
- **LoFreq** estimates how often the instrument misreads a base from the base qualities, the sequencer's confidence in each base, and reports a change when more reads carry it than that error rate predicts. It reports the fraction of reads carrying each change rather than a genotype, which suits samples whose true fractions can be anything, such as a mixed infection or a tumour biopsy.
- **[iVar](../../GLOSSARY.md#ivar)** reports each change carried by more than a fixed fraction of reads. It is written for [amplicon](../../GLOSSARY.md#amplicon) data whose primer bases have already been clipped away.

The other three are Medaka and Clair3, which [Nanopore Variant Calling](04-nanopore-variant-calling.md) covers, and GATK HaplotypeCaller, which [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) covers. Match the caller to how the sample was prepared before you look at a row of output. [Which variant-calling route](../01-foundations/05-variants-and-vcf.md#which-variant-calling-route) sets the whole choice out as a table, including the routes that are not variant calling at all.

This chapter calls both kinds of data the Alignments part prepared. The HG002 shotgun alignment is called with bcftools and LoFreq, and the primer-trimmed SARS-CoV-2 amplicon track from [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) is called with iVar.

## Why you would do this

The example in this chapter is human. [HG002](../../GLOSSARY.md#hg002) is a consenting research participant whose DNA is distributed as a cell line, so laboratories everywhere sequence the same genome. The HG002 chromosome 20 slice holds Illumina reads from that cell line, mapped to a 500 kilobase stretch of chromosome 20. Calling variants on it asks which positions differ from the reference in this person, and the question has a checkable answer.

The fixture ships with a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), 961 calls the Genome in a Bottle consortium produced for HG002 by combining many sequencing platforms and callers. Those calls did not come from the fixture's reads, so they work as an outside answer key. Few real projects offer one, and learning to ask how a call set was checked is easiest where the checking is possible. Every clinical genetics pipeline and population study begins with this step.

The second example is viral. SRR36291587 is a SARS-CoV-2 amplicon run, and calling its primer-trimmed track asks which changes the virus in that sample carries and at what share of the reads, the question surveillance laboratories answer every week.

## Choosing a tool

Check how your library was made and which instrument read it, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows. The caller then follows from what you expect the sample to hold. In a person or a macaque, with two copies of each chromosome, a true variant sits in about half the reads or in nearly all of them, and [genotype-based calling](../../GLOSSARY.md#genotype-based-calling) with bcftools fits. A virus population, a mixed infection, or a tumour can carry a change in any fraction of the reads, and [frequency-based calling](../../GLOSSARY.md#frequency-based-calling) with LoFreq or iVar, which reports that fraction, fits. A caller built for one situation gives confident wrong answers in the other.

**bcftools** scores every genotype the ploidy allows against the reads at each position and writes the best one. Take a diploid position covered by 40 reads, 19 of them reading A where the reference reads G. The genotype `0/1`, a [heterozygous](../../GLOSSARY.md#heterozygous) site where one copy carries A, explains those reads well. The genotype `0/0`, neither copy carrying A, would need 19 sequencing errors, and `1/1`, both copies carrying A, would need 21. The score weighs each base by its quality and each read by how confidently it was mapped. bcftools comes with LGE, is fast, and suits a diploid sample such as HG002 or a haploid one such as a clonal bacterial isolate. It cannot report a minority variant, since no genotype says that a change sits in only 10 percent of the reads. LGE sets a default ploidy from what the bundle records about the organism, and the Ploidy setting overrides it. One ploidy covers every sequence, so a male sample's X and Y chromosomes and the mitochondrion are called diploid too.

**LoFreq** treats each base's quality score as the chance that the base is wrong and asks whether more reads carry a change than error alone would plausibly produce. It was built for virus populations, bacteria, and mixed tumour samples. It needs deep coverage to reach low frequencies, and a systematic error, one the instrument repeats at the same place in many reads, can pass its test. In LGE it calls no indels unless asked, and its default [strand bias](../../GLOSSARY.md#strand-bias) filter, which removes calls whose reads come mostly from one strand, can remove real variants in amplicon data, where reads often cover a position from one strand only.

**iVar** counts only bases at or above a minimum quality, 20 in LGE, and reports every change above a fixed fraction of reads and a fixed depth. It marks each change PASS or not with a simple statistical test, Fisher's exact test, that asks whether the change is more common than the base qualities would explain. Its rules are simple enough to check by hand. It was built for primer-trimmed [amplicon](../../GLOSSARY.md#amplicon) data such as SARS-CoV-2 surveillance panels.

**Viral Recon** is a pipeline rather than a caller. For a SARS-CoV-2 amplicon run it maps, trims primers, calls with iVar, builds a consensus, and assigns a [lineage](../../GLOSSARY.md#lineage), the named branch of the virus family tree, in one run, as [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) shows.

For low-frequency or viral work, depth sets the floor. One study of targeted deep sequencing of SARS-CoV-2 found that detecting every variant at 10, 5, 3, and 1 percent needed at least 250, 500, 1,500, and 10,000 reads of coverage, judged by both the median depth of each sample and the depth at the variant ([Van Poelvoorde and colleagues, 2021](https://doi.org/10.3389/fmicb.2021.747458)). A comparison of six callers on SARS-CoV-2 mixtures found that LoFreq reported the most false positives ([Bassano and colleagues, 2023](https://doi.org/10.1099/mgen.0.000933)). Treat a low-frequency LoFreq call as a lead. Inspect its reads in the viewport, and on primer-trimmed amplicon data confirm it with iVar at a lowered Minimum Allele Frequency before you report it.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| bcftools | Genotypes in diploid or haploid samples | The sample is a person, a macaque, or a clonal isolate | You need changes carried by a minority of reads, or the reads are nanopore |
| LoFreq | Allele fractions in mixed populations | You look for minority variants in deep Illumina data | Coverage is thin, or the reads are from a nanopore run |
| iVar | Primer-trimmed amplicon data | The run is an amplicon panel such as a SARS-CoV-2 scheme | The data are shotgun, or the primers are still on the reads |
| Viral Recon | SARS-CoV-2 amplicon runs, from reads to lineage | You want the standard viral pipeline in one run | The sample is not viral, or Docker Desktop is not available |

This chapter calls HG002, a diploid human shotgun sample, with bcftools, and runs LoFreq beside it for comparison. iVar is not run on HG002, because its reads carry no primers, and it calls the primer-trimmed SARS-CoV-2 track instead. For a person or a macaque on short reads, start with bcftools, and move to [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) for publishable or multi-sample work. For nanopore reads use the callers in [Nanopore Variant Calling](04-nanopore-variant-calling.md). Citations for LoFreq and iVar are in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), bcftools is in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge), and Viral Recon is in [Pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The HG002 calls need the Human Mapping and Variants demo project, opened with **Help > Demo Projects…** as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, and the `HG002 minimap2` alignment that [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) makes in it. The caller only works on a track a bundle owns, never on a loose BAM in a folder. If you marked duplicates in [Alignment Quality](../04-alignments/04-alignment-quality.md), the original track is now named `HG002 minimap2 [unmarked]`, and it is the one to call for this chapter's numbers. To import the files yourself instead, download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains, then import and map them.

The iVar call needs the SARS-CoV-2 Amplicons demo project and the `SRR36291587 minimap2 • Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)` track that [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) makes in it.

bcftools arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. For LoFreq and iVar, install the `variant-calling` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. A caller whose pack is missing still appears in the dialog, greyed out and badged with the tool it lacks, such as "Requires LoFreq". Each call here takes from a few seconds to about twenty on a recent Mac.

## Procedure

### Open the Call Variants dialog

Click the `minimap2-` mapping result under **Analyses** in the sidebar. LGE opens the mapping viewport and loads the reference bundle inside the mapping result, as [Open the mapping result](../04-alignments/01-mapping-reads-to-a-reference.md#open-the-mapping-result) shows. In the [Inspector](../../GLOSSARY.md#inspector), open the **Analysis** tab and click its **Variant Calling** tab, one of the six [Analysis tabs](../04-alignments/02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs), then click **Call Variants...**. The dialog works on the reference bundle inside the mapping result, and the variant tracks it writes land there too.

The dialog opens on the first eligible alignment track in the bundle, not necessarily the one you had in mind, so check the Alignment Track menu before you run.

### Read the dialog before you change anything

A tool sidebar down the left lists the six callers, and **LoFreq** is selected when the dialog opens. The right side is one scrolling pane, and a footer carries a readiness message, a Cancel button, and a Run button.

Five sections stack down that pane for every caller. **Overview** holds the Alignment Track menu and the Output Variant Track Name field. **Thresholds** holds Minimum Allele Frequency and Minimum Depth. A section named for the selected caller comes next, such as "bcftools Settings". **Extra arguments** is a single text field, and **Readiness** repeats the footer's message. Selecting iVar adds an **iVar Options** section that no other caller shows.

<!-- SHOT: call-variants-dialog-bcftools -->

The Thresholds fields filter the output of every caller except GATK HaplotypeCaller. iVar applies them itself while calling. For bcftools, LoFreq, Medaka, and Clair3, LGE runs a filtering step after the caller finishes that removes every row below either threshold, reading the [allele frequency](../../GLOSSARY.md#allele-frequency) and depth each caller writes. This is the threshold filter of [Three kinds of filter](../01-foundations/05-variants-and-vcf.md#three-kinds-of-filter), and unlike a caller's `FILTER` flag it deletes rows rather than marking them. A caller whose VCF lacks the needed value skips that threshold, and the run's [provenance](../../GLOSSARY.md#provenance) records only the thresholds that were applied. The defaults, 0.05 (a change seen in at least one read in twenty) and 10 (at least ten reads covering the position), suit almost every run.

### Call with bcftools

1. Click **bcftools** in the tool sidebar. Its section opens with the line "bcftools will run mpileup and call as an orthogonal cross-check on the selected BAM". Orthogonal means a second opinion reached by a different route, and the wording comes from the app's viral work, where bcftools checks a frequency caller. For a person such as HG002, bcftools is the right first caller.
2. Read the one control, **Ploidy**, offering Haploid and Diploid, with a caption naming the choice LGE made for this bundle and the evidence it used. Here it reads Diploid, which is right for a human sample.
3. Check that the Alignment Track menu names `HG002 minimap2`, or `HG002 minimap2 [unmarked]` after duplicate marking.
4. Replace the Output Variant Track Name, which fills in as the track name, a bullet, and "bcftools", with `HG002 bcftools`, the name the rest of the manual uses. Leave every other field alone and click **Run**.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). LGE indexes the reference, runs [`bcftools mpileup`](../../GLOSSARY.md#mpileup), with its usual cap of 250 reads per position removed so deep amplicon piles are read in full, feeding straight into `bcftools call`, applies the threshold filter, sorts the rows, compresses the file with [`bgzip`](../../GLOSSARY.md#bgzip), indexes it with [`tabix`](../../GLOSSARY.md#tabix), and loads the rows into the database the table filters. When the run finishes, its row ends with "Created variant track HG002 bcftools".

### Call with LoFreq on the same alignment

Open the dialog again and click **LoFreq**. Its section reads "LoFreq is ready to run directly on the selected bundle alignment track." and holds no controls. Replace the output name with `HG002 LoFreq` and click **Run**.

Calling the same alignment twice is not wasted work. The two files disagree, and [Reading the Variants Table](02-reading-the-variant-browser.md) reads that disagreement in the one table both tracks load into.

### Open the results

The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which opens by itself along the bottom of the alignment pane once the bundle holds a variant track, as [Reading the Variants Table](02-reading-the-variant-browser.md#what-it-is) covers. If the mapping viewport is not showing, click the `minimap2-` result again. Both tracks load into the one table, and the **Variant Track** column names the track each row came from.

<!-- SHOT: variants-tab-two-callers -->

### Call the trimmed amplicon track with iVar

iVar assumes amplicon data whose primer bases have been clipped out, and the dialog enforces that assumption. Do not run it on HG002, whose reads are [shotgun](../../GLOSSARY.md#shotgun), made from DNA broken at random, so no primer sits on them. Selecting iVar with an untrimmed BAM leaves the readiness line reading "Confirm the BAM was primer-trimmed before running iVar." and the Run button disabled until you tick the checkbox.

1. In the SARS-CoV-2 Amplicons project, click its `minimap2-` mapping result under **Analyses**, then open **Call Variants...** from the Inspector's **Variant Calling** tab as above.
2. Click **iVar**, and set the Alignment Track menu to the track whose name ends `Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)`.
3. Read the checkbox "This BAM has already been primer-trimmed for iVar." It is ticked and greyed out, with a caption naming the date and the [primer scheme](../../GLOSSARY.md#primer-scheme), because LGE found the [primer-trim](../../GLOSSARY.md#primer-trim) record filed beside the BAM. An empty checkbox means the wrong track is selected.
4. Replace the output name with `SRR36291587 iVar`, leave the thresholds and **iVar Options** at their defaults, and click **Run**.

<!-- SHOT: call-variants-dialog-ivar -->

The run writes 93 rows, 87 single-base substitutions and 6 deletions. Every row's genotype is a bare `1`, the haploid call for a genome carried in one copy, and every `QUAL` reads `.`, because iVar writes no quality score. The `FILTER` column reads `PASS` on 89 rows and `ft` on 4. `ft` means the row failed iVar's own test, Fisher's exact test, that the change is more common than the base qualities would explain, and all four sit at allele frequencies between 0.05 and 0.08. The allele frequencies split cleanly. Of the 93 rows, 81 sit at 0.8 or more, the changes fixed in this virus population. One sits at 0.50, at position 27,415, and 11 fall below 0.2, minority changes that a threshold of 0.05 lets through and a pipeline such as Viral Recon leaves out, as [Comparing with the manual route](../04-alignments/05-viral-recon-wizard.md#comparing-with-the-manual-route) shows. Treat those eleven as leads to inspect in the viewport rather than as results.

When the bundle carries gene annotations, LGE hands them to iVar so that two neighbouring changes inside one [codon](../../GLOSSARY.md#codon), the three bases that encode one amino acid, can be reported as a single row. The merged row names the one amino acid the pair produces, where two separate rows would each name a change that never happened alone. Three tests decide whether a pair merges, tested in order. Both frequencies sit above the Consensus allele frequency setting, or both sit between 0.40 and 0.60, or their gap is smaller than the Merge AF distance setting. So changes at 0.45 and 0.55 merge by the second test whatever the settings say. The Settings entries below explain the two settings. The SARS-CoV-2 Amplicons reference bundle carries no gene annotations, so this run merges nothing, and its VCF header says so in the line `##LungfishNote=GFF unavailable; codon merging skipped`.

## Settings

Every setting in the dialog for the three callers this chapter covers is below. Where a setting behaves differently by caller, the entry says so.

**Alignment Track.** Chooses which alignment the caller reads, and the alignment is only read, never rewritten. The default is the first eligible track in the bundle, meaning a BAM whose file and index are both present, rather than the track you clicked. Change it when the bundle holds more than one alignment, and for iVar always pick the primer-trimmed one. On the command line this is `--alignment-track`.

**Output Variant Track Name.** Names the variant track the run creates, and that name fills the Variant Track column of the Variants tab. The default is the alignment name, a bullet, and the caller name, such as "HG002 minimap2 • bcftools", and a name already in use gets a number added rather than overwriting anything. Change it when you want a shorter or clearer label, as this chapter does with `HG002 bcftools`. On the command line this is `--name`.

**Minimum Allele Frequency.** Sets the smallest fraction of reads that must carry the change for a row to be kept, so 0.05 keeps a change seen in five reads of every hundred. The default is 0.05, and it becomes iVar's own `-t` value, while for the other callers LGE removes rows below it after the caller runs. Lower it toward 0.01 when hunting minority variants in deep amplicon data, and raise it when only near-fixed changes interest you. On the command line this is `--min-af`.

**Minimum Depth.** Sets how many reads must cover a position for a row there to be kept. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. The default is 10, about the thinnest evidence worth calling on, and it becomes iVar's `-m` value while the other callers are filtered after the run. Raise it when coverage is deep and you want only well-supported calls. On the command line this is `--min-depth`.

**This BAM has already been primer-trimmed for iVar..** iVar only. States that the primer bases have been clipped out of this alignment, which iVar assumes without checking. It defaults to off, and to on and locked when LGE finds a primer-trim record beside the BAM. Tick it yourself only when you trimmed the BAM outside LGE, never on an untrimmed amplicon BAM, where every primer position would read as a variant. On the command line this is `--ivar-primer-trimmed`.

**Consensus allele frequency.** iVar only. Sets the frequency above which a change counts as the consensus base, the first test for folding two changes in one codon into one row. The default is 0.75, so only changes present in most reads merge this way. Lower it when a real double change sits at an intermediate frequency and you want it merged. On the command line this is `--ivar-consensus-af`.

**Merge AF distance.** iVar only. Sets how close two neighbouring frequencies must be for their changes to fold into one codon row, the last of the three tests. The default is 0.25, so changes at 0.30 and 0.50 merge while 0.30 and 0.90 do not. Tighten it when unrelated changes are merged, and loosen it when a genuine pair stays split. On the command line this is `--ivar-merge-af-threshold`.

**Minimum ALT quality.** iVar only. Writes `bq` in the FILTER column of a call whose alternate (ALT) bases, the non-reference bases, average below this quality, and keeps the row. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The default is 20, the usual floor for Illumina data, and raising it toward 30 flags more low-quality calls. On the command line this is `--ivar-bad-quality-threshold`.

**Ignore strand bias (recommended for amplicons).** iVar only. Skips the check that a change appears on both DNA strands in similar numbers. It defaults to on, because every read in an amplicon starts at a primer and so lands on that primer's strand, which makes the check flag real variants. Leave it on for amplicon data, which is the only data iVar should see, and turn it off only for an amplicon design in which both strands of every amplicon are read in similar numbers. On the command line the flag is inverted, `--ivar-no-ignore-strand-bias`.

**Ploidy.** Tells bcftools how many copies of each chromosome the sample carries, which decides whether a heterozygous genotype such as `0/1` can be written at all. It appears for bcftools alone, offering Haploid, which passes `--ploidy 1`, and Diploid, which passes `--ploidy 2`. The default comes from the bundle, read from a ploidy note, an NCBI Virus record, a GenBank division, the organism name, or a well-known assembly name such as GRCh38, and it is Haploid when nothing identifies the organism, as the caption then says. Choose Diploid yourself for a human or macaque reference imported under an uninformative name, since a human run that returns almost no `0/1` genotypes was called haploid. On the command line this is `--ploidy`, which takes `1` or `2`, and leaving it off derives the value the way the dialog does.

**Extra arguments.** Passes text straight to the caller without LGE checking it, placed right after `bcftools call`, `lofreq call`, or `ivar variants`. The default is empty, which is right for almost every run. Use it for an option the dialog does not show, such as `--call-indels` to switch on LoFreq's indel calling, which adds a preparation pass over a copy of the BAM. For bcftools it refuses `--ploidy`, and the Readiness line points you to the Ploidy setting instead. On the command line this is `--extra-args`.

## Reading the results

Run with every setting left alone, bcftools writes 1,040 rows at 1,038 positions and LoFreq writes 862 rows at 861 positions. A caller writes a second row at a position where it found a second, different change. Neither caller samples reads at random, so the same alignment, reference, and settings give the same rows every time. The fixture folder also holds a raw bcftools file with 1,056 rows, the count [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md) starts from. The 16 rows between the two are the ones the threshold filter removed for falling below 0.05 or 10, and none of them is a benchmark position.

Of the 1,040 bcftools rows, 859 are single-base substitutions and 181 are [indels](../../GLOSSARY.md#indel), insertions or deletions. All 862 LoFreq rows are substitutions, because LoFreq calls no indels unless asked. The substitutions agree closely, since 850 of the 859 positions where bcftools called one also carry a LoFreq row.

The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains. Every bcftools row reads `.` and every LoFreq row reads `PASS`, which is why the **PASS** chip, a one-click filter button above the table, hides the whole bcftools track, as [Filter with the preset chips](02-reading-the-variant-browser.md#filter-with-the-preset-chips) in Reading the Variants Table shows. The two files also differ in shape. The bcftools VCF carries one sample column, named `HG002.chr20.10.0-10.5Mb` after the read bundle the mapping took its sample name from, holding a [genotype](../../GLOSSARY.md#genotype) on every row, with 617 rows reading `0/1`, 405 reading `1/1`, and 18 reading `1/2`. In `1/2`, `2` is the second alternate allele, so both copies carry a change but not the same one. The LoFreq VCF has no sample column and reports [allele frequency](../../GLOSSARY.md#allele-frequency) in its `INFO` field instead.

Each variant track lives inside the `variants/` folder of the reference bundle inside the mapping result, as a `.vcf.gz` file, its `.vcf.gz.tbi` index, and a `.db` database the table queries, beside a provenance record with the same stem. For the bcftools track these come to about 50 KB, 371 bytes, and 2.4 MB. The shared name is the track id, `vc-` followed by a long identifier LGE assigns. The window does not show it. To see the folder, Control-click the bundle in Finder and choose Show Package Contents.

## What good looks like

Four checks are worth making before you trust a call set.

First, read the row count against the region. LoFreq's 862 rows across 500 kilobases is about one difference every 580 bases, the right order for a human sample, where about one base in a thousand differs from the reference. Single digits would mean a broken alignment or the wrong reference. Tens of thousands would mean sequencing error is being called.

Second, read the FILTER column before you filter on it. A track of all `PASS` and a track of all `.` need different handling, and only one has been judged by anything.

Third, check the calls against the benchmark. Comparing positions only, 954 of the 1,038 positions bcftools called and 808 of the 861 positions LoFreq called match a position in the 961-call benchmark. Out of the benchmark's 961 positions, that is 99 percent for bcftools and 84 percent for LoFreq, and 150 of the 153 benchmark positions LoFreq misses are indels, which it was not asked to call. Most of each caller's own calls match, 92 and 94 percent, which is what a sound call set looks like. A position match is not genotype agreement, and a real accuracy assessment needs a separate benchmarking program such as `hap.py`, which LGE does not ship and this manual does not cover.

Fourth, read the provenance, the record [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads. The bcftools run records version 1.24. The LoFreq run records no usable version, because that program rejects `--version` and the field holds its error message instead.

## On the command line

The block below reproduces the three calls, following the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Every flag of `variants call` is listed in [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference. Put your own mapping result folders and track identifiers in the `BUNDLE` and `--alignment-track` lines. `ls` on a bundle's `alignments` folder prints the identifier as the start of the BAM's file name, `aln_` and eight letters and digits, and a primer-trimmed BAM sits one folder down, in `alignments/primer-trimmed`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
BUNDLE="$PROJECT/Analyses/minimap2-2026-09-27T11-21-19/GRCh38.chr20.10.0-10.5Mb.lungfishref"
ls "$BUNDLE/alignments"

lungfish-cli variants call --bundle "$BUNDLE" \
  --alignment-track aln_93ACDFDA --caller bcftools \
  --min-af 0.05 --min-depth 10 --name "HG002 bcftools"
lungfish-cli variants call --bundle "$BUNDLE" \
  --alignment-track aln_93ACDFDA --caller lofreq \
  --min-af 0.05 --min-depth 10 --name "HG002 LoFreq"

PROJECT="$HOME/Documents/LGE Demo Projects/SARS-CoV-2 Amplicons.lungfish"
BUNDLE="$PROJECT/Analyses/minimap2-2026-09-27T11-23-50/MN908947.3.lungfishref"
ls "$BUNDLE/alignments/primer-trimmed"

lungfish-cli variants call --bundle "$BUNDLE" \
  --alignment-track aln_66AD64A0 --caller ivar --ivar-primer-trimmed \
  --min-af 0.05 --min-depth 10 --name "SRR36291587 iVar"
```

Leave out `--ploidy` and bcftools takes the same derived value the dialog shows, or pass `--ploidy 1` or `--ploidy 2` to set it. The flag is refused for any other caller. The command line has no default thresholds. Leave `--min-af 0.05 --min-depth 10` off and no threshold filter runs, so the counts differ from a window run, which always sends the two field values. The command line does not read the primer-trim record the dialog reads, so an iVar call always needs `--ivar-primer-trimmed`, and without it the command stops with "iVar requires explicit confirmation that primer trimming has already been applied." To see a window run as a command, right-click its row in the Operations Panel and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes, and the copied text carries the track identifier.

## Next

Continue to [Reading the Variants Table](02-reading-the-variant-browser.md), which takes the two HG002 tracks you just made and reads them in the table that shows them. [Nanopore Variant Calling](04-nanopore-variant-calling.md) covers Medaka and Clair3 for long reads, and [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md) starts the HaplotypeCaller route for publishable human calls.
