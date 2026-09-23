---
title: Calling Variants
chapter_id: 05-variants/01-calling-variants-from-amplicons
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 01-foundations/05-variants-and-vcf, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming]
estimated_reading_min: 24
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
    caption: "The Call Variants dialog with bcftools selected, showing the tool sidebar on the left and the Overview, Thresholds, and bcftools Settings sections on the right."
  - id: call-variants-dialog-ivar
    caption: "The Call Variants dialog with iVar selected, showing the primer-trim checkbox already ticked and the iVar Options section that only iVar displays."
  - id: variants-tab-two-callers
    caption: "The Variants tab of the table drawer with both the bcftools and LoFreq tracks loaded, and the Source column naming which track each row came from."
illustrations: []
glossary_refs: [alignment-track, allele-depth, allele-frequency, amplicon, bam, bcftools, benchmark-vcf, bgzip, codon, depth, filter, format, genotype, indel, info, ivar, lofreq, mpileup, phred-score, pileup, ploidy, plugin-pack, primer-scheme, primer-trim, provenance, ref-alt, reference-bundle, required-setup-pack, shotgun, snv, tabix, table-drawer, variant-caller, vcf]
features_refs: [variants.call]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Variant calling is the step that turns an alignment into a list of differences. A [variant caller](../../GLOSSARY.md#variant-caller) reads a [BAM](../../GLOSSARY.md#bam) file, walks the reference one position at a time, looks at the [pileup](../../GLOSSARY.md#pileup) of read bases stacked over each position, and writes a row whenever the reads disagree with the reference strongly enough to clear its thresholds. The rows go into a [VCF](../../GLOSSARY.md#vcf) file, the standard tab-separated text format described in [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md). That chapter explains the columns. This one produces the file.

Lungfish Genome Explorer (LGE) runs the caller for you. You pick an [alignment track](../../GLOSSARY.md#alignment-track), which is one named BAM already attached to a [reference bundle](../../GLOSSARY.md#reference-bundle), you pick a caller from a list of seven, and LGE stages the inputs, runs the tool, normalises and sorts the output, compresses and indexes it, and files the result back inside the bundle as a named variant track. Nothing you do here modifies the alignment. Calling is a read-only operation on the BAM. The next two paragraphs explain how to choose among the seven.

The seven entries in the tool list are not seven ways of doing the same thing. Each caller was built around an assumption about how the reads were produced, and using the wrong one gives you a file full of confident nonsense. Three of them matter for this chapter. **bcftools** builds a genotype model, which is the list of allele combinations a sample could carry, and asks at each position which of them best explains the pileup. That suits a sample that is [diploid](../../GLOSSARY.md#ploidy), meaning it carries two copies of every chromosome, as a human does. **LoFreq** builds an error model, an estimate of how often the instrument misreads a base, from the base qualities themselves, and asks whether the alternate reads are more numerous than that error rate alone would produce. That suits a sample whose true allele fractions can be anything at all, such as a mixed infection or a tumour biopsy where only some cells carry the change. **[iVar](../../GLOSSARY.md#ivar)** reports the observed fraction of reads carrying each alternate above a fixed threshold, and it is written for [amplicon](../../GLOSSARY.md#amplicon) data that has already had its primer bases clipped away.

The other four are named here so the list holds no surprises. Medaka and Clair3 are for Oxford Nanopore reads, whose errors fall in patterns a short-read caller misreads, and they get their own chapter. GATK HaplotypeCaller and the GATK plus WhatsHap phased plan are human germline tools that sit behind experimental plugin packs. The rule to carry away is short. Match the caller to how the sample was prepared, before you look at a single row of output.

## Why you would do this

The worked example in this chapter is human. HG002 is a real person, a consenting research participant whose DNA is distributed as a cell line so that laboratories everywhere can sequence the same genome. The HG002 chromosome 20 slice holds Illumina reads from that cell line, mapped to a 500 kilobase stretch of chromosome 20, where a kilobase is a thousand bases of DNA. It is the same alignment the mapping chapter produced. Calling variants on it asks a question with a checkable answer. Which positions in these 500 kilobases differ from the reference in this person, and does the answer agree with what an independent, painstakingly curated truth set says about the same person?

That last part is what makes the fixture worth working through. It ships with a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), a set of 961 variant calls that the Genome in a Bottle consortium, a public standards project run out of the United States National Institute of Standards and Technology, produced for HG002 by combining many sequencing platforms and callers over several years. Those 961 calls did not come from the fixture's reads. They are an outside answer key, so a caller you run today can be compared against them. Very few real projects hand you that luxury, and the habit of asking how a call set was checked is worth building on data where the checking is possible.

Beyond the teaching value, the biology is ordinary and useful. A human genome carries roughly one difference from the reference every thousand bases, most of them harmless and shared with millions of other people, a few of them consequential. Variant calling is the step that produces the list you then filter, annotate, and interpret. Every clinical genetics pipeline, every population study, and every association analysis begins here.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice, which is a fixture, the sample data set this manual works its examples against. Download the files `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. On that page, click a filename and then the Download raw file button, since the page itself only previews the file. No GitHub account is needed to download them.

What this chapter needs in the project is not those raw files but the alignment they produce. Import the FASTA with **File > Import Center...** and the two FASTQ files the same way, then map them with **Tools > Mapping > minimap2...** as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes step by step. That leaves a reference bundle carrying an alignment track whose default name that chapter gives as "minimap2 Mapping", and that track is what the Call Variants dialog reads. If your own run named it something else, use whatever name the sidebar shows. A loose BAM sitting in a folder cannot be called from. The caller only ever works on a track the bundle owns.

bcftools needs no extra installation. It arrives in the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one [plugin pack](../../GLOSSARY.md#plugin-pack) LGE cannot run without, so it is present as soon as a project can open. That pack is listed in the Plugin Manager under its own display name, Third-Party Tools, which is the name the disabled badges quote. LoFreq and iVar are different. Both live in the `variant-calling` pack, which LGE installs on request. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and install that pack before you try either. Installing downloads the tools from the internet into a managed environment, so the machine needs to be online, and the pack's row in the Plugin Manager reports its progress and then shows the pack as installed when it is done. A caller whose pack is missing still appears in the dialog's tool list, greyed out and badged with the pack it wants, so bcftools would badge as "Requires Third-Party Tools Pack" and LoFreq as "Requires Variant Calling Pack". You can see what exists without guessing.

## Procedure

### Step 1. Open the Call Variants dialog

Select the reference bundle in the sidebar, then choose **Tools > Call Variants...**. The menu item is always present but it needs a bundle loaded, so choosing it with nothing selected raises an alert reading "No Bundle Loaded" rather than opening anything.

The same dialog has a second route. Click an alignment track in the sidebar, open the Inspector's Analysis section, and inside its **Variant Calling** tab click **Call Variants...**. Use whichever you prefer. The dialog that opens is identical either way. Neither route preselects the track you arrived from, because the dialog always opens on the first eligible alignment track in the bundle, so check the Alignment Track menu before you run.

### Step 2. Read the dialog before you change anything

The dialog is two columns. A tool sidebar runs down the left listing the seven callers, each with a one-line subtitle, and **LoFreq** is selected when the dialog opens. The right side is one pane that scrolls, and a footer bar underneath it carries a readiness message, a Cancel button, and a Run button.

Four sections stack down that pane for every caller. **Overview** holds an Alignment Track menu and an Output Variant Track Name field. **Thresholds** holds Minimum Allele Frequency and Minimum Depth. A section named for the caller you selected comes next, so choosing bcftools titles it "bcftools Settings". **Extra arguments** is a single text field, and **Readiness** repeats the footer's message. Selecting iVar inserts one more section, **iVar Options**, between the caller's own section and Extra arguments. No other caller shows it.

<!-- SHOT: call-variants-dialog-bcftools -->

One thing about the Thresholds section deserves reading twice, because it is the most common source of confusion in this dialog. Those two fields reach iVar and no other caller. For bcftools, LoFreq, Medaka, and Clair3 they are recorded in the run's [provenance](../../GLOSSARY.md#provenance), the saved record of how the run was done that you read later by clicking the finished track and looking at the Inspector, and then ignored. Typing 0.20 into Minimum Allele Frequency before a bcftools run does not make bcftools apply a 20 percent floor. The Settings section below says so for each caller in turn, and the Extra arguments field is the route to a real threshold on the callers that ignore these.

### Step 3. Call with bcftools

Click **bcftools** in the tool sidebar. The section titled "bcftools Settings" carries no controls, only the line "bcftools will run mpileup and call as an orthogonal cross-check on the selected BAM." Orthogonal there means independent, a second opinion arrived at by a different route. Check that the Alignment Track menu names your minimap2 track. The Output Variant Track Name field has filled itself in with the track name, a bullet, and the caller name, giving "minimap2 Mapping • bcftools". Leave every field alone and click **Run**.

The Operations panel opens and shows the steps as they finish. LGE stages a copy of the reference and the BAM into a scratch workspace, indexes the reference with `samtools faidx`, runs [`bcftools mpileup`](../../GLOSSARY.md#mpileup) piped into `bcftools call`, which means the output of the first tool is fed straight into the second without ever being written to disk, then rewrites the VCF header against the reference index, sorts the records, compresses the file with [`bgzip`](../../GLOSSARY.md#bgzip), indexes it with [`tabix`](../../GLOSSARY.md#tabix), and loads the rows into a SQLite database, which is a small local database held in a single file, that the table uses for fast filtering. The run finishes with the line "Variant calling complete".

### Step 4. Call with LoFreq on the same alignment

Open the dialog again and click **LoFreq**, which is where it opens anyway. Its section reads "LoFreq is ready to run directly on the selected bundle alignment track." and holds no controls either. The output name fills in as "minimap2 Mapping • LoFreq". Click **Run**.

Calling the same alignment twice with two callers is not wasted work. The two files disagree, and the last step of [Reading the Variants Table](02-reading-the-variant-browser.md) reads that disagreement in the one table both tracks load into. Having both tracks in the bundle now is what makes that comparison possible.

### Step 5. Open the results

Click the reference bundle in the sidebar. The viewport is the large central area of the window that draws whatever the sidebar has selected, and the [table drawer](../../GLOSSARY.md#table-drawer) is the panel that slides up from its bottom edge. That drawer opens by itself, because the bundle now carries variant tracks. Click its **Variants** tab. Both tracks load into the one table at once, and the **Source** column names the track each row came from. There is no separate variant browser window and no per-track node in the sidebar.

<!-- SHOT: variants-tab-two-callers -->

Sort by clicking a column header. Filtering happens through the **Presets** button above the table, which reveals the filter chips, each chip being a small labelled button you click to switch one filter on or off, and through the Search Builder sheet for anything the chips cannot express. [Reading the Variants Table](02-reading-the-variant-browser.md) covers both in full.

### Step 6. Know where iVar belongs

Do not run iVar on this fixture. iVar assumes its input is amplicon data whose primer bases have been clipped out, and the HG002 reads are [shotgun](../../GLOSSARY.md#shotgun), meaning they come from DNA broken at random rather than from targeted PCR products, so no primer sits on them to clip. The dialog enforces the assumption. Selecting iVar with an untrimmed BAM leaves the readiness line reading "Confirm the BAM was primer-trimmed before running iVar." and the Run button disabled until you tick the checkbox yourself.

On a track that LGE primer-trimmed, the checkbox is already ticked and greyed out, with a caption naming the date and the [primer scheme](../../GLOSSARY.md#primer-scheme) used. That is LGE reading the [primer-trim](../../GLOSSARY.md#primer-trim) record filed beside the BAM, not a default. [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) produces exactly such a track from the SARS-CoV-2 amplicon reads, and that track is the right input for an iVar run. Everything in the Settings section below applies to it.

<!-- SHOT: call-variants-dialog-ivar -->

One iVar behaviour is worth knowing before you meet it. When the bundle carries gene annotations, LGE exports them to a GFF3 file and hands it to iVar, which lets two neighbouring changes inside one [codon](../../GLOSSARY.md#codon), the run of three bases that encodes one amino acid, be reported as a single row rather than two. That matters because the merged row names the one amino acid the pair of changes actually produces, where two separate rows would each name an amino acid change that never happened on its own.

Whether they merge depends on their allele frequencies agreeing, and three tests are tried in turn. The group merges if every frequency in it sits above the Consensus allele frequency setting, or if every frequency sits between 0.40 and 0.60 inclusive, or if the widest gap between neighbouring frequencies is smaller than the Merge AF distance setting. The first and third tests are the two settings documented below. The middle one is fixed in the code, answers to no setting, and fires before the distance test, so a pair sitting inside that band merges no matter what you do to Merge AF distance.

## Settings

Every setting the Call Variants dialog offers is documented here, across all three callers this chapter covers. Where a setting behaves differently depending on which caller is selected, the paragraph says so, because that difference is where most mistakes are made. Each entry ends by naming the command-line flag, which belongs to the optional section at the end of this chapter.

**Alignment Track.** Chooses which alignment the caller reads its evidence from, and the alignment itself is only read, never rewritten. The default is the first eligible track in the bundle's manifest rather than the one you clicked, where eligible means the track is in BAM format and both its BAM file and its index are present on disk, so a track stored as SAM or one whose index went missing never appears in the menu. Change it whenever the bundle holds more than one alignment, and for iVar always point it at the primer-trimmed one, since selecting a track also re-reads the primer-trim record filed beside that track's BAM. On the command line this is `--alignment-track`.

**Output Variant Track Name.** Names the variant track the run creates, and that name becomes the value in the Source column of the Variants tab, which is how you tell two callers apart once both are loaded. The default is the alignment name, then a bullet, then the caller name, so a bcftools run on the fixture proposes "minimap2 Mapping • bcftools", and a name already in use gets a number appended rather than overwriting anything. Change it when you want a shorter or more descriptive label. On the command line this is `--name`.

**Minimum Allele Frequency.** Sets the smallest fraction of reads that must carry an alternate base before the call is reported, so 0.05 means a base seen in five reads of every hundred is kept. The default is 0.05, and it becomes iVar's own `-t` value, but for bcftools and LoFreq it is written into the run's provenance and never passed to the tool, which is why a bcftools run started from this dialog records the value "caller-default" instead. Lower it toward 0.01 for iVar when you are hunting minority variants in a deeply sequenced amplicon, raise it when only near-fixed changes interest you, and leave it alone for bcftools and LoFreq where changing it changes nothing. On the command line this is `--min-af`.

**Minimum Depth.** Sets how many reads must cover a position before a call there is trusted, where [depth](../../GLOSSARY.md#depth) is the number of reads stacked over a single position, which you can read for your own alignment from the coverage track drawn above the reads in the viewport, whose right-hand label reports the maximum and mean depth of the region on screen, and from the Mean Depth column of the mapping run's contig table. The default is 10, which is about the thinnest evidence worth calling on, and as with the frequency it reaches iVar as its `-m` value while bcftools and LoFreq only record it. Raise it for iVar when your coverage is deep and you want only well-supported calls, and for the other two set a real floor through Extra arguments instead, using each tool's own flag. On the command line this is `--min-depth`.

**This BAM has already been primer-trimmed for iVar..** States that the primer bases have been clipped out of this alignment, which iVar assumes without checking, so the run stays blocked until the box is ticked. It defaults to off, and to on and locked when LGE finds a primer-trim record beside the BAM, in which case a caption below names the date and scheme. Tick it yourself only when you trimmed the BAM outside LGE, and never on an untrimmed amplicon BAM, where every primer position would then read as a variant in about half the reads. This setting has no effect on any caller but iVar. On the command line this is `--ivar-primer-trimmed`.

**Consensus allele frequency.** Sets the frequency above which a change counts as the consensus base, and it is the first of the three tests deciding whether two adjacent changes inside one codon are folded into a single VCF row. The default is 0.75, high enough that only changes present in most of the reads merge by this route. Lower it when a real double change sits at an intermediate frequency and you want it merged anyway. On the command line this is `--ivar-consensus-af`.

**Merge AF distance.** Sets how close two adjacent frequencies have to be before their changes are folded into one codon row, and it is the third and last test, catching pairs that clear neither the consensus bar nor the fixed 0.40 to 0.60 band but plainly rise and fall together. The default is 0.25, so two changes at 0.30 and 0.50 merge by this test while one at 0.30 and another at 0.90 do not, and a pair at 0.40 and 0.55 merges before this test is reached because both frequencies sit inside the fixed band. Tighten it when unrelated neighbouring changes are being merged, and loosen it when a genuine pair keeps staying split. On the command line this is `--ivar-merge-af-threshold`.

**Minimum ALT quality.** Marks a call with the `bq` filter flag when the average [Phred](../../GLOSSARY.md#phred-score) quality of the alternate bases falls below this, where a Phred score of 20 means the instrument expects one wrong base in a hundred and 30 means one in a thousand. The default is 20, the conventional floor for Illumina data. Raise it toward 30 when the run's base qualities were high and you want low-quality calls flagged rather than silently accepted. On the command line this is `--ivar-bad-quality-threshold`.

**Ignore strand bias (recommended for amplicons).** Skips the check that a variant appears on both DNA strands in similar numbers, a check that normally catches artifacts. It defaults to on, because amplicon libraries are lopsided by design, since every read in an amplicon starts at the same primer and so lands on whichever strand that primer sits on, which makes the check flag real variants as artifacts rather than the reverse. Turn it off only for shotgun or metagenomic libraries, where strand imbalance really is a warning sign. On the command line the flag is inverted, since it switches the filter on rather than off, so it is `--ivar-no-ignore-strand-bias`.

**Extra arguments.** Inserts your own text straight into the caller's command line, right after the subcommand and ahead of the arguments LGE builds, so it reaches `bcftools call`, `lofreq call`, or `ivar variants` as typed. It defaults to empty, and it is the only route to any bcftools or LoFreq setting the dialog does not expose. Use it to set [ploidy](../../GLOSSARY.md#ploidy) on a haploid genome with `--ploidy 1`, to give LoFreq a real depth floor with `--min-cov 50`, or to switch LoFreq's indel calling on with `--call-indels`, which makes LGE run an extra `lofreq indelqual` pass over a copy of the BAM first, a step that writes per-base quality scores for insertions and deletions into the copy so LoFreq has something to judge them by, and which adds a second pass over the whole alignment to the run. On the command line this is `--extra-args`.

## Reading the results

The fixture gives real numbers to read against. Running both callers on the fixture alignment with every setting left alone produces 1,056 rows from bcftools and 862 rows from LoFreq. Those two runs were made for this chapter with the command-line tool, and their output matches the VCFs committed under the fixture's `expected/variants/` folder row for row. Expect the same numbers on your own machine rather than numbers close to them. Neither caller samples reads at random, so the same alignment, the same reference, and the same settings give the same rows every time, and a run of yours that disagrees means an input differs somewhere.

Take the row counts first. The two callers examined the same 500 kb of the same alignment and disagreed by nearly 200 rows, which is normal and not a defect. Of the 1,056 bcftools rows, 874 are single-base substitutions and 182 are insertions or deletions, counted the way the table's Type column counts them, by each record's first alternate allele. All 862 LoFreq rows are substitutions, because LoFreq calls no [indels](../../GLOSSARY.md#indel) unless you ask it to through Extra arguments. That one difference in default behaviour accounts for most of the gap.

Now the FILTER column, which is where this fixture teaches its sharpest lesson. Every one of the 1,056 bcftools rows has [`FILTER`](../../GLOSSARY.md#filter) set to a bare `.`, and not one says `PASS`, because a default bcftools run applies no hard filter and leaves the column unset for you to judge. Every one of the 862 LoFreq rows says `PASS`, because LoFreq applies its filters while calling and writes out only what survived. The practical consequence lands the first time you touch the Presets chips. The **PASS** chip hides every row whose FILTER is anything but `PASS`, so on the bcftools track it empties the table completely, and only clearing the chip brings the rows back. Read `.` as unjudged rather than as failed, and check what the column actually holds before filtering on it.

The per-sample payload differs too, and the difference is structural rather than cosmetic. The bcftools VCF carries ten columns, the eight standard ones plus a [`FORMAT`](../../GLOSSARY.md#format) column reading `GT:PL:AD` and one sample column named HG002. Those three codes name what the sample column holds, in order. `GT` is the genotype, `PL` is a set of scaled likelihoods saying how badly each possible genotype fits the reads, where 0 marks the best fit and larger numbers mark worse ones, and [`AD`](../../GLOSSARY.md#allele-depth) is the allele depth, the count of reads supporting the reference and the count supporting the alternate. Of its rows, 623 carry the [genotype](../../GLOSSARY.md#genotype) `0/1`, meaning one of this person's two copies of chromosome 20 carries the change, 415 carry `1/1`, meaning both do, and the remaining 18 carry `1/2`, meaning the two copies carry two different alternates at that one position, which brings the three counts to 1,056. The LoFreq VCF has eight columns and no sample column at all, because LoFreq reports [allele frequency](../../GLOSSARY.md#allele-frequency) and depth as [`INFO`](../../GLOSSARY.md#info) fields rather than as genotypes. Neither shape is wrong. They answer different questions, and a downstream tool expecting genotypes will find nothing in the LoFreq file.

One position shows all of this at once. At fixture coordinate 2078 both callers report the same [`REF` and `ALT`](../../GLOSSARY.md#ref-alt), a reference `G` read as `A`, and both read a depth of 62. The tab-separated columns run in the fixed VCF order, so read the block against this header:

```
#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO	FORMAT	HG002
chr20_10.0-10.5Mb	2078	.	G	A	225.417	.	DP=62;...;DP4=0,0,24,27;MQ=60	GT:PL:AD	1/1:255,154,0:0,51
chr20_10.0-10.5Mb	2078	.	G	A	2370	PASS	DP=62;AF=1;SB=0;DP4=0,0,31,31
```

The first data line is bcftools and the second is LoFreq, which stops at `INFO` because it writes no `FORMAT` or sample column. Same position, same alleles, same depth, and everything after that differs. The `QUAL` column in a VCF is the caller's confidence that a variant is really there rather than an artifact, on a scale where larger means more confident, so 225.417 and 2370 both read as confident calls. Each caller computes it its own way, which is why the two numbers cannot be compared against each other. Compare a `QUAL` only against other rows in the same file. The FILTER column is unset in one and `PASS` in the other. bcftools ends with a genotype of `1/1` while LoFreq reports `AF=1`, and those two say the same thing in different languages, that every read at this position carried the alternate. The benchmark VCF agrees with both, calling this position `1/1` from a depth of 1,231 reads gathered across many platforms.

Where the two files sit on disk is worth knowing, because nothing about it is visible in the window. A variant track lives inside the reference bundle, under its `variants/` folder, as three data files sharing one name, beside a provenance sidecar carrying the same stem. A `.vcf.gz`, which is the bgzip-compressed VCF, a `.vcf.gz.tbi`, which is the tabix index letting the viewport fetch one region without reading the whole file, and a `.db`, which is a SQLite copy of the same rows that the Variants tab queries when you sort or filter. The bcftools track from this fixture writes 46 KB, 368 bytes, and 2.2 MB respectively. The database is much the largest of the three, which is the price of a table that filters instantly. That shared name is the track id, a string beginning `vc-` followed by a long identifier that LGE assigns rather than you. It is not shown in the window, so when a command needs it, read it off the filenames in that `variants/` folder, which the command block at the end of this chapter does.

## What good looks like

Four checks are worth making before you trust a call set, and this fixture lets you make all four.

First, read the row count against the size of the region. The fixture covers 500 kb and bcftools called 1,056 rows, which is roughly one difference every 470 bases. That is the right order of magnitude for a human sample, where about one base in a thousand differs from the reference. A count in the single digits would mean the alignment is broken or the wrong reference was used. A count in the tens of thousands would mean the caller is reporting sequencing error.

Second, read the FILTER column before you filter on it. A track of all `PASS` and a track of all `.` need different handling, and only one of them has been judged by anything. Do this by looking at the column itself, not by clicking the PASS chip and drawing conclusions from an empty table.

Third, check the calls against the benchmark where one exists. Comparing positions only, 954 of the 1,053 distinct positions bcftools called match a position in the fixture's 961-call benchmark, and 808 of LoFreq's 861 do. The 1,053 is smaller than the 1,056 rows because a few positions carry more than one row, once for each alternate allele reported there. Both fractions are high, and the shortfall is expected, since a caller reports positions the benchmark deliberately excludes as hard to call. Treat these as position matches and nothing more. They are not genotype agreement, and a real accuracy assessment needs a benchmarking program such as `hap.py`, which lives outside LGE and which LGE does not ship or install, so full accuracy assessment is out of scope for this manual and nothing later in it depends on your running one.

Fourth, read the provenance. Click the variant track and the Inspector shows every step the run took with its exact command line, the tool versions, and checksums of the inputs. The fixture runs recorded bcftools 1.24 from the managed environments. The LoFreq run recorded no version at all, because that binary rejects `--version` and its version field holds the tool's own error message instead, so the 2.1.5 quoted here is a version measured separately rather than one the run wrote down. Both runs record the two threshold fields as "caller-default" whenever the flags were left off, which is the record proving those numbers never reached the tool.

## On the command line

This section is optional. Everything above happens in the window, and nothing later in this manual needs you to have run a command.

The command-line tool calls variants the same way the dialog does, and against the same requirement, that the alignment be a track the bundle already owns. The script below imports the reference, adopts a mapping result as a track, and calls both ways. It is the sequence that produced every number in this chapter.

```bash
# Import the reference, which creates the bundle under Reference Sequences/
lungfish-cli import fasta GRCh38.chr20.10.0-10.5Mb.fasta \
    --name "chr20 10.0-10.5Mb" -o MyProject.lungfish

BUNDLE="MyProject.lungfish/Reference Sequences/chr20_10.0-10.5Mb.lungfishref"

# Attach a mapping run's output to the bundle as a named alignment track
lungfish-cli bam adopt-mapping --bundle "$BUNDLE" \
    --mapping-result mapping/ \
    --name "HG002 minimap2" --track-id hg002-minimap2

# Call with bcftools, then with LoFreq, on that one track
lungfish-cli variants call --bundle "$BUNDLE" \
    --alignment-track hg002-minimap2 \
    --caller bcftools --name "HG002 bcftools"

lungfish-cli variants call --bundle "$BUNDLE" \
    --alignment-track hg002-minimap2 \
    --caller lofreq --name "HG002 LoFreq"

# List the track ids, which are the vc- filenames in the bundle's variants folder
ls "$BUNDLE"/variants/

# Count the rows in a finished track, using one of those ids
bcftools view -H "$BUNDLE"/variants/<track-id>.vcf.gz | wc -l
```

An iVar run on a primer-trimmed track adds the attestation flag and any of the iVar options, none of which are required because each has a default.

```bash
lungfish-cli variants call --bundle "$BUNDLE" \
    --alignment-track <trimmed-track-id> \
    --caller ivar --ivar-primer-trimmed \
    --min-af 0.05 --min-depth 10 \
    --name "SARS-CoV-2 iVar"
```

Two options exist only on the command line. `--format` prints the run summary as text, JSON, or a tab-separated table, where the window always shows text. `--threads` sets how many threads the run may use, where the window always takes the machine's processor count.

## Next

[Reading the Variants Table](02-reading-the-variant-browser.md) takes the two tracks you just made and covers the table that displays them, its columns, its filter chips, the Search Builder, and how to read the two callers against each other. [Nanopore Variant Calling](04-nanopore-variant-calling.md) covers Medaka and Clair3 for long reads.
