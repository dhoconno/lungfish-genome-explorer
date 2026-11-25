---
title: HaplotypeCaller
chapter_id: 06-human-germline-variants/01-haplotype-caller
audience: power-user
prereqs: [06-human-germline-variants/04-reference-packs, 01-foundations/05-variants-and-vcf, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 11
task: Call germline SNVs and indels with GATK HaplotypeCaller from the Call Variants dialog or the command line.
tags: [gatk, haplotypecaller, germline, experimental, cli, gui]
tools: [gatk, whatshap]
parameters_refs: [variants.call-gatk-haplotypecaller, variants.call-gatk-whatshap-phased]
entry_points:
  - "GUI: Tools > Variant Calling > Call Variants… > GATK HaplotypeCaller"
  - "CLI: lungfish-cli variants call --caller gatk"
  - "CLI: lungfish-cli gatk haplotype-caller"
  - "CLI: lungfish-cli variants phase"
shots:
  - id: call-variants-dialog-gatk
    caption: "The Call Variants dialog with GATK HaplotypeCaller selected, showing the tool sidebar, the Overview section's Alignment Track picker and Output Variant Track Name field, the Thresholds fields the GATK tools ignore, and the readiness line in the footer."
illustrations: []
glossary_refs: [alignment-track, bam, benchmark-vcf, depth, genotype, germline, gvcf, haplotype, heterozygous, homozygous, indel, inspector, interval-list, joint-genotyping, local-reassembly, lofreq, phase-set, ploidy, plugin-pack, provenance, qual, read-backed-phasing, read-group, reference-bundle, sequence-dictionary, shotgun, snv, table-drawer, variant-caller, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

GATK HaplotypeCaller is the Broad Institute's [variant caller](../../GLOSSARY.md#variant-caller) for [germline](../../GLOSSARY.md#germline) variation, the differences a person inherited from their parents and carries in every cell. It reads a [BAM](../../GLOSSARY.md#bam), a file with one row per aligned read, and writes a [VCF](../../GLOSSARY.md#vcf), a tab-separated file with one row per position where the sample differs from the reference.

What sets HaplotypeCaller apart is [local reassembly](../../GLOSSARY.md#local-reassembly). A simpler caller judges each position on its own by counting the bases stacked over it. HaplotypeCaller finds stretches where reads disagree, rebuilds the candidate sequences of that stretch from the reads themselves, and scores every read against each candidate. Reassembly costs time and repays it around [indels](../../GLOSSARY.md#indel), insertions or deletions of a few bases, which an aligner often places inconsistently from read to read. HaplotypeCaller is also diploid by default, so it writes genotypes for both copies of each chromosome, which makes it the usual caller for human germline samples. The Call Variants dialog's bcftools also writes diploid genotypes on a human reference, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md#choosing-a-tool) explains, but without reassembly.

### Candidate haplotypes

A [haplotype](../../GLOSSARY.md#haplotype) in its general sense is the set of alleles that sit together along one chromosome copy. HaplotypeCaller borrows the word for something narrower. Its candidate haplotypes are guesses at the sequence of one short stretch, a few hundred bases at most, rebuilt from the reads that cover it. Most are thrown away once the reads have been scored against them. The genotype written for each position is the pair of candidates the reads support best, and nothing in the output names a haplotype. The word keeps its general sense in the phased route below and a third, named sense in [MHC Allele Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#alleles-loci-and-haplotypes).

Lungfish Genome Explorer (LGE) does not reimplement GATK. It assembles the GATK command, runs it in a managed environment, and files the result with a [provenance](../../GLOSSARY.md#provenance) record. Two routes reach it. The Call Variants dialog runs HaplotypeCaller on an [alignment track](../../GLOSSARY.md#alignment-track) that a [reference bundle](../../GLOSSARY.md#reference-bundle) owns and attaches the calls back to that bundle, through the same `lungfish-cli variants call --caller gatk` command you can type. `lungfish-cli gatk haplotype-caller` runs the tool on loose files. Use the dialog when you want calls to read in the window. Use the command line when you will genotype several samples together later, because only the command line writes the [GVCF](../../GLOSSARY.md#gvcf) that step needs, a VCF that also records the caller's confidence at positions where nothing varied.

## Why you would do this

The HG002 chromosome 20 slice is a 500 kilobase window from a real human genome. HG002 is the Genome in a Bottle reference individual, sequenced many times by many methods, so a consensus answer exists for what their variants are. That answer ships beside the reads as a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf) of 961 records. On a fresh patient sample you can only ask whether the output looks plausible. Here you can ask whether it is right. A run on this slice takes under a minute, so you can try a setting and look again.

## Choosing a tool

Check that your reads are short-read shotgun data from one diploid individual, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows, and that this is the route you want, as [Which variant-calling route](../01-foundations/05-variants-and-vcf.md#which-variant-calling-route) sets out. For a person or a macaque the choice then rests on how much the indels matter and whether the sample will later be analysed together with others. LGE offers two callers for short-read diploid calling, bcftools and GATK HaplotypeCaller.

**bcftools** scores each possible genotype at a position against the read bases, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md#choosing-a-tool) explains through an example. It comes with LGE, needs nothing beyond the reference bundle, and finishes quickly, which makes it a good first pass and a useful independent check. It does not rebuild the local sequence from the reads, so around indels it has less to go on than HaplotypeCaller. bcftools itself can call several samples together, but it has no way to add samples later and genotype the whole cohort again.

**GATK HaplotypeCaller** finds stretches where the reads suggest variation, rebuilds candidate haplotypes there by local reassembly, scores every read against every candidate, and only then writes genotypes. The reassembly makes it stronger at indels and at clusters of nearby changes, at a cost in time and memory. It is, along with DeepVariant, which LGE does not ship, the usual caller in published human germline studies. Through a GVCF it supports [joint genotyping](../../GLOSSARY.md#joint-genotyping), which genotypes a growing cohort together so that a position called in one sample is judged in every other sample too. In LGE it sits in the experimental GATK Core (`gatk-core`) [plugin pack](../../GLOSSARY.md#plugin-pack), which stays hidden until you turn on experimental features, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows, and may change between releases. It needs a [sequence dictionary](../../GLOSSARY.md#sequence-dictionary) beside the reference.

Two limits matter for real samples. HaplotypeCaller keeps at most 50 reads that start at the same position, and amplicon reads all start at a primer, so on amplicon data it discards most of the depth unless you type `--max-reads-per-alignment-start 0`, which GATK documents as switching the cap off, in Extra arguments. The dialog also always calls diploid, so for a male sample such as HG002 the X and Y chromosomes outside their shared regions, and the mitochondrion, are called diploid, and calls there need care. This chapter's chromosome 20 slice avoids both.

A third route, GATK followed by WhatsHap, adds phase, which of the nearby variants sit on the same copy of a chromosome. Its dialog entry, GATK + WhatsHap Phased, is switched off in this release, so run it from the command line, as [Use the command line for the phased route](#use-the-command-line-for-the-phased-route) describes.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| bcftools | Fast per-position genotyping | You want a quick answer or a second opinion on one sample | Indels matter, or the cohort will grow and be genotyped again |
| GATK HaplotypeCaller | Diploid germline calls with local reassembly | Results are for publication, indels matter, or samples will be genotyped together | You need a quick check, or the data are amplicon rather than shotgun |
| GATK + WhatsHap | HaplotypeCaller calls with phase added | You need to know which variants share a chromosome copy | You need only genotypes, or want to work in the dialog |

On this chapter's fixture bcftools writes 1,040 rows, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md#reading-the-results) shows, and HaplotypeCaller writes 1,026, against a benchmark of 961. This chapter uses HaplotypeCaller because HG002 is a human shotgun sample and the chapter teaches the route to joint genotyping. For one human or macaque sample and a quick look, bcftools is enough, and for long reads use Clair3 from [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md). GATK4 and WhatsHap are cited in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), bcftools in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge), and DeepVariant in [Other works cited in the manual](../appendices/bibliography.md#other-works-cited-in-the-manual).

## Before you start

Work through [Reference Files for GATK](04-reference-packs.md) first. The dialog route needs only two things from it, the GATK Core (`gatk-core`) pack, installed from **Tools > Plugin Manager…**, and the HG002 mapping result whose track is named `HG002 minimap2`. The rest prepares the `LGE GATK` working folder that the command line below uses.

GATK needs a FASTA index and a [sequence dictionary](../../GLOSSARY.md#sequence-dictionary) beside the reference. The command line reads the FASTA in the working folder, which already has both. The dialog reads the reference inside the bundle that owns the track, which is the reference bundle inside the mapping result, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. That copy has an index but no dictionary, and the run fails without one, so build it there once. Type the lines below into Terminal, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, and see [Finding the program](../appendices/cli-reference.md#finding-the-program) for running `lungfish-cli` there. A Preview copy, named Lungfish Genome Explorer Preview on screen, uses `.lungfish` for `.lungfish-stable` in the `TOOLS=` line, as [Release channels](../01-foundations/06-the-lungfish-project.md#release-channels) shows.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
TOOLS="$HOME/.lungfish-stable/conda/envs"
GATK="$TOOLS/gatk-core/bin/gatk"
cd "$PROJECT/Analyses/minimap2-2026-09-27T11-10-11/GRCh38.chr20.10.0-10.5Mb.lungfishref/genome"
"$GATK" CreateSequenceDictionary -R sequence.fa.gz
ls
```

Replace `minimap2-2026-09-27T11-10-11` with the name of your HG002 mapping result, which the sidebar shows under Analyses. The command writes `sequence.dict` beside the bundle's compressed reference, `sequence.fa.gz`, and `ls` lists the folder so you can see it. LGE never reads that file.

A [read group](../../GLOSSARY.md#read-group) is the `@RG` label in a BAM header naming the sample and library. GATK refuses a BAM without one and uses its sample name as the VCF's sample column. The mapping in Reference Files for GATK set it to `HG002`. A mapping made in the window with every default sets it to the read bundle's name, `HG002.chr20.10.0-10.5Mb`, and that name then heads the sample column instead. The alignment should also be [shotgun](../../GLOSSARY.md#shotgun) data, made from DNA broken at random, for the amplicon reason given in [Choosing a tool](#choosing-a-tool).

Install the Variant Phasing (`phasing`) pack as well for the phased route, from **Tools > Plugin Manager…** as for GATK Core.

## Procedure

### Open the Call Variants dialog

1. Click the HG002 mapping result under Analyses in the sidebar, and wait for the viewport to show the `chr20_10.0-10.5Mb` sequence and ruler. LGE selects the one row of the table of mapped contigs for you, and that loads the reference bundle inside the mapping result, the bundle that owns the `HG002 minimap2` track, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes.
2. Choose **Tools > Variant Calling > Call Variants…**. The same dialog opens from the **Call Variants…** button on the **Variant Calling** tab, one of the [six tabs](../04-alignments/02-reading-an-alignment.md#the-inspector-summary-and-the-analysis-tabs) under the **Analysis** tab of the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window. Both are grayed out until the loaded bundle holds a sorted and indexed BAM track, which a track mapped in LGE already is.

### Select GATK HaplotypeCaller and read the dialog

Click **GATK HaplotypeCaller** in the tool sidebar, whose subtitle reads "Germline SNP and indel calling with standard VCF genotypes." A badge reading "Requires GATK Core Pack" or "Requires GATK4" means the pack, or GATK inside it, is not ready yet.

The right pane holds four sections. **Overview** holds the **Alignment Track** picker and the **Output Variant Track Name** field. **Thresholds** holds **Minimum Allele Frequency** and **Minimum Depth**. **GATK HaplotypeCaller settings** holds only the line "GATK HaplotypeCaller will write a standard genotype VCF for the selected BAM." **Extra arguments** is a single text field, whose grey hint `--call-indels` belongs to [LoFreq](../../GLOSSARY.md#lofreq), another caller in this dialog, and is never sent. The footer's readiness line reads "Ready to run GATK HaplotypeCaller on <track>." once a track is chosen.

<!-- SHOT: call-variants-dialog-gatk -->

The Thresholds fields do nothing for GATK HaplotypeCaller. They drive the threshold filter the other callers' output passes through, which [Three kinds of filter](../01-foundations/05-variants-and-vcf.md#three-kinds-of-filter) describes, but the dialog leaves them out of the command it runs, so they reach neither GATK nor the run's provenance. GATK decides which alleles to write from its own genotype likelihoods, scores for how well the reads fit each possible genotype.

### Run HaplotypeCaller

Check that the Alignment Track picker names `HG002 minimap2`, or `HG002 minimap2 [dup-marked]` after duplicate marking, leave every field alone, and click **Run**. If it names another sample, close the dialog and click another `minimap2-` result. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

The row runs `lungfish-cli variants call --caller gatk`, which runs GATK inside the `gatk-core` environment, writes the VCF to the bundle's `variants/gatk/` folder, and attaches it as a variant track described as "GATK HaplotypeCaller variants from <alignment>". Each call keeps its own run record, and Copy CLI Command on the row copies the command with every value the dialog chose. The dialog always asks for a plain VCF of variant positions, `--emit-ref-confidence NONE`, never a GVCF. That matters only when you combine this sample with others, which [Joint Genotyping](02-joint-genotyping.md) covers and which needs a GVCF from the command line.

### Read the calls in the Variants tab

With the bundle still loaded, the rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#open-the-variants-tab) covers. Every track in the bundle loads into the one table, so rows from an earlier bcftools track join these. The new track is named `HG002 minimap2 • GATK HaplotypeCaller` unless you renamed it. To read it alone, open the Inspector, click its **View** tab, click **Annotations** under **View Settings**, and under **Variant Tracks** clear the box of every other track. Set the **Region / Genome** switch above the table to **Genome**, and the count at the right end of the tab row reads `1,026 variants` for a bundle holding only this track, or `1,026 of` and the total of all its tracks when others are hidden.

### Use the command line for the phased route

The phased route adds WhatsHap, a separate program that reads a set of calls and works out which nearby variants sit on the same copy of a chromosome. The dialog does not list it, so the route takes four steps, two in the app and two in Terminal.

1. Install the Variant Phasing (`phasing`) pack, as Before you start says.
2. Run `lungfish-cli variants phase` from the `LGE GATK` folder, as [On the command line](#on-the-command-line) shows. It runs GATK and then WhatsHap and writes `phased/HG002.phased.vcf.gz`.
3. Run the `tabix` line of that block, which writes an index, only if another program will read the file, since LGE's import does not need it.
4. With the HG002 mapping result still open, import the phased VCF through the **VCF Variants** card of the Import Center, as [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md#open-the-import-center-and-choose-the-vcf) shows.

## Settings

The GATK HaplotypeCaller entry shows five controls. Where the dialog's `variants call` command has a matching flag, the entry names it, with the phased route's flag where that differs.

**Alignment Track.** Chooses which alignment GATK reassembles reads from. The default is the first analysis-ready BAM track the bundle holds, meaning one whose file and index are both present, or its `[dup-marked]` copy when that first track is the `[unmarked]` original of a Mark Duplicates run, and not the alignment on display. Change it when the bundle holds more than one alignment, and prefer whole-genome or exome shotgun data over amplicon data. For the phased route the alignment also decides how much phasing can work, since [read-backed phasing](../../GLOSSARY.md#read-backed-phasing) links two variants only when single reads or read pairs span both. On the command line this is `--alignment-track`, or `--bam` for the phased route.

**Output Variant Track Name.** Names the variant track the run creates, while the VCF itself is saved under a generated file name. The default is the alignment name, a bullet, and the tool name, and a name already in use gets a number added so runs never overwrite each other. Change it when you want a clearer label. On the command line this is `--name`.

**Minimum Allele Frequency.** Has no effect on GATK HaplotypeCaller, because the dialog leaves it out of the command. The field shows 0.05 because the dialog draws it for every caller, and the other callers use it. Leave it alone here.

**Minimum Depth.** Has no effect on GATK HaplotypeCaller, for the same reason. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. The field shows 10 and accepts a whole number or a blank. Leave it alone here.

**Extra arguments.** Passes text straight to GATK without LGE checking it, after the options the dialog sets. The default is empty, which is right for almost every run. Use it for a GATK option the dialog does not set, such as an [interval list](../../GLOSSARY.md#interval-list). It cannot change [ploidy](../../GLOSSARY.md#ploidy), the number of copies of each chromosome, the calling threshold, or any other option the dialog always sends, [listed below](#on-the-command-line), because the dialog sends `--ploidy 2` and `--stand-call-conf 30.0`, which reach GATK as `--sample-ploidy` and `--standard-min-confidence-threshold-for-calling`, and GATK stops with an error when an option is given twice. On the command line this is `--extra-args`, and for the phased route `--extra-gatk-args`, which reaches only the GATK half.

## Reading the results

A finished run on the fixture writes 1,026 rows. The `Type` column judges each row by its first alternate allele, but types a row carrying a `*` allele, VCF's mark for a position an earlier deletion already covers, as `COMPLEX`. On the run recorded for this manual it reads 843 [SNVs](../../GLOSSARY.md#snv), single-base changes, 178 indels, and 5 complex rows, worked out from that run's type tally and this rule, so confirm the SNV and indel counts by clicking the **SNV** chip and then the **Indel** [chip](../05-variants/02-reading-the-variant-browser.md#filter-with-the-preset-chips) and reading the table's count with only the GATK track shown, and the complex rows are the rest of the 1,026.

A [genotype](../../GLOSSARY.md#genotype) of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do. On the recorded run 589 rows read `0/1`, which are [heterozygous](../../GLOSSARY.md#heterozygous), 418 read `1/1`, which are [homozygous](../../GLOSSARY.md#homozygous), and 19 read `1/2`, two different alternate alleles and no reference copy. Heterozygous calls are about 57 percent of the total, which is what a single human sample at this depth looks like, and about 59 percent with the 19 `1/2` rows, whose two copies also differ. With only the GATK track shown, click **Genotypes** in the **Calls / Genotypes** switch, right-click the `GT` header, choose **Filter GT Equals…**, type `0/1`, and click **Apply**, and the count reads `589 genotypes` on the recorded run, after which **Clear Genotype Column Filters** in the same menu removes the filter. Read genotype notation in full in [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md#the-eight-standard-columns-and-what-may-follow-them).

[QUAL](../../GLOSSARY.md#qual) is the caller's confidence that a variant exists at the position, on a logarithmic scale where every 10 points means ten times more confidence, so 30 means about one chance in a thousand of being wrong and a QUAL in the hundreds means the call is essentially certain. There is no fixed pass mark, so judge a QUAL, which the `Quality` column shows, against the other calls in the run. The dialog sends `--stand-call-conf 30.0`, so GATK writes no call below 30. The mean on the recorded run is 903, and strong calls run into the thousands. Check a call whose QUAL sits just above 30 before you trust it.

The mean per-sample depth across the 1,026 called positions is 38, a little below the 44.7 mean across the whole window, probably because GATK discards reads it does not trust before counting.

A GVCF from the same reads looks nothing like this. It has 48,057 rows, 46,858 of them reference blocks, each a run of positions where the sample matched the reference, with GATK's confidence recorded. Only 1,199 rows carry an alternate allele, more than 1,026 because a GVCF keeps candidate positions the genotyping step later declines to call.

The phased route's output has the same 1,026 rows. Where an unphased heterozygous call reads `0/1`, a phased one reads `0|1` or `1|0`. The upright bar marks a call as phased, and the order of the two alleles says which copy carries which within a phase set. On this fixture 373 of the 589 heterozygous calls came back phased, gathered into 125 [phase sets](../../GLOSSARY.md#phase-set), stretches within which the phasing is internally consistent. The 216 that stayed `0/1` had no read spanning them together with a nearby variant.

## What good looks like

Check the sample name first, which the **Samples** tab of the table drawer lists. It should be the read group's sample name, `HG002` from the mapping in Reference Files for GATK, or `HG002.chr20.10.0-10.5Mb` from a window mapping with defaults. Anything else means the wrong alignment was called.

Check the total against the benchmark's 961 records, which [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) attaches beside your calls from `Practice Data/hg002-chr20`. A run of 1,026 is 65 rows, about 7 percent, above it, which is ordinary because the benchmark was built from deeper data by several methods. Equal totals would not show that the same positions were called, which only rows side by side can. Totals of a few dozen rows, or tens of thousands in a file that should not be a GVCF, mean something went wrong upstream.

Check the heterozygous fraction, about 57 percent here. Nearly everything heterozygous usually means two samples are mixed in one BAM. Almost nothing heterozygous usually means ploidy was set to 1, which only a command-line run with `--ploidy 1` can do.

Check that the run finished. The Operations Panel row should end as completed, and the bundle should show the new variant track. A failed run leaves no half-written VCF, because LGE deletes the outputs that run created. The run's provenance record names the GATK version and the exact command, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows.

## On the command line

Run these from the `LGE GATK` working folder with the variables from [Reference Files for GATK](04-reference-packs.md#before-you-start) set. Every `lungfish-cli gatk` command prints the GATK command and stops unless you add `--execute`, while `variants call` runs at once. The CLI Reference lists `variants phase` under [Calling variants](../appendices/cli-reference.md#calling-variants) and `gatk haplotype-caller` under [Human Germline Variants (Experimental)](../appendices/cli-reference.md#human-germline-variants-experimental), and `lungfish-cli variants call --help` lists the GATK flags of `variants call`.

```bash
# The dialog's own call, attached to the bundle that owns the track
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
BUNDLE="$PROJECT/Analyses/minimap2-2026-09-27T11-10-11/GRCh38.chr20.10.0-10.5Mb.lungfishref"
lungfish-cli variants call \
    --bundle "$BUNDLE" \
    --alignment-track "HG002 minimap2" \
    --caller gatk

# A genotyped VCF from loose files in the working folder
cd "$HOME/Documents/LGE GATK"
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam HG002.sorted.bam \
    --output HG002.chr20.vcf.gz \
    --emit-ref-confidence NONE --execute

# The phased route, GATK then WhatsHap, then an index for the result
lungfish-cli variants phase \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam HG002.sorted.bam \
    --output-vcf phased/HG002.phased.vcf.gz \
    --output-dir phased --execute
"$TOOLS/htslib/bin/tabix" -p vcf phased/HG002.phased.vcf.gz
```

Use the same mapping result name as in Before you start. `--alignment-track` takes a track's identifier or, as here, its name when only one track carries it. The `variants call` command takes the values the dialog sends, a plain VCF, `--ploidy 2`, `--pcr-indel-model CONSERVATIVE`, `--stand-call-conf 30.0`, `--max-alternate-alleles 6`, and `--pair-hmm-threads 4`, as its defaults, and `--intervals` restricts it to the regions of a BED file or interval list. One default of `gatk haplotype-caller` differs from the dialog's. It writes a GVCF unless you pass `--emit-ref-confidence NONE`, where the dialog always writes a plain VCF. Its `--ploidy` defaults to 2, as the dialog's does, and setting 1 gives a haploid call set. The phased route always writes genotyped calls, since WhatsHap cannot phase a GVCF. On the recorded run `gatk haplotype-caller` with `--emit-ref-confidence NONE` wrote the same 1,026 rows as the dialog.

## Next

Continue to [Joint Genotyping](02-joint-genotyping.md), which calls HG002's parents as well and genotypes the three together. To read these calls beside the part's other call sets in the window, [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) attaches any VCF to a bundle.
