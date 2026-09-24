---
title: HaplotypeCaller
chapter_id: 06-human-germline-variants/01-haplotype-caller
audience: power-user
prereqs: [01-foundations/05-variants-and-vcf, 01-foundations/07-plugin-packs]
estimated_reading_min: 30
task: Call germline SNPs and indels with GATK HaplotypeCaller from the CLI or the GUI.
tags: [gatk, haplotypecaller, germline, preview, cli, gui]
tools: [gatk, whatshap]
parameters_refs: [variants.call-gatk-haplotypecaller, variants.call-gatk-whatshap-phased]
entry_points:
  - "GUI: Tools > Call Variants... > GATK HaplotypeCaller"
  - "CLI: lungfish-cli gatk haplotype-caller"
  - "CLI: lungfish-cli variants phase"
shots:
  - id: call-variants-dialog-gatk
    caption: "The Call Variants dialog with GATK HaplotypeCaller selected, showing the tool sidebar, the Overview section's Alignment Track picker and Output Variant Track Name field, the Thresholds fields the GATK tools ignore, and the readiness line in the footer."
  - id: operations-panel-gatk-run
    caption: "The Operations panel row for a finished GATK HaplotypeCaller run, expanded to show the GATK command and the provenance the run recorded."
illustrations: []
glossary_refs: [alignment-track, bam, benchmark-vcf, depth, filter, format, genotype, genotype-quality, germline, gvcf, haplotype, indel, info, joint-genotyping, local-reassembly, phase-set, ploidy, plugin-pack, provenance, read-backed-phasing, read-group, reference-bundle, sequence-dictionary, snv, table-drawer, variant-caller, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

GATK HaplotypeCaller is the Broad Institute's [variant caller](../../GLOSSARY.md#variant-caller) for [germline](../../GLOSSARY.md#germline) variation, meaning the differences a person inherited from their parents and carries in every cell. It reads a [BAM](../../GLOSSARY.md#bam) file, which is the compressed binary record of where each sequencing read landed on a reference genome, and writes a [VCF](../../GLOSSARY.md#vcf) file listing the positions where that person's DNA differs from the reference. The reference is one agreed-on sequence for the species that every sample is compared against, so a variant is always a difference from that shared yardstick rather than a difference from another person.

What makes HaplotypeCaller different from a simpler caller is [local reassembly](../../GLOSSARY.md#local-reassembly). A simple caller walks the reference one position at a time and counts the bases stacked above it, so it judges every position on its own. HaplotypeCaller instead finds stretches where the reads disagree with each other, throws away the original alignment across that stretch, rebuilds the candidate sequences from the reads themselves, and then scores each read against those rebuilt candidates. Each rebuilt candidate is a [haplotype](../../GLOSSARY.md#haplotype), one possible version of that stretch of chromosome, which is where the tool gets its name. This costs more time and it repays the cost around [indels](../../GLOSSARY.md#indel), which are insertions or deletions of a few bases, because an aligner asked to place one read at a time often puts the same insertion in slightly different spots on different reads, and reassembly resolves the disagreement. An aligner is the program that decides where each read belongs on the reference.

Lungfish Genome Explorer (LGE) does not reimplement any of that. It assembles the GATK command, runs GATK inside a managed software environment, and files the result with a [provenance](../../GLOSSARY.md#provenance) record, which is the saved account of exactly what ran. A managed software environment is a private folder of tools that LGE installs and keeps separate from everything else on your Mac, so GATK cannot collide with software you installed yourself and you never have to set it up by hand. Two routes reach it. The Call Variants dialog runs HaplotypeCaller on an [alignment track](../../GLOSSARY.md#alignment-track) that a [reference bundle](../../GLOSSARY.md#reference-bundle) already owns and attaches the calls back to that bundle. The command line runs the same tool on loose files and gives you nine more related GATK commands around it, which the last section of this chapter lists.

So what should you do with this? If you want variants attached to a bundle so you can read them in the window, use the dialog. If you are calling several samples that you intend to genotype together later, use the command line, because only the command line writes the [GVCF](../../GLOSSARY.md#gvcf) that step needs, meaning a VCF that also records how confident the caller was at the positions where nothing varied.

## Why you would do this

The HG002 chromosome 20 slice is a half-megabase window from a real human genome, meaning 500,000 bases out of the roughly 64 million on chromosome 20, so about one part in 130 of that one chromosome. HG002 is the Genome in a Bottle reference individual, a person whose genome has been sequenced many times by many methods so that a consensus answer exists for what their variants actually are. That consensus ships beside the reads as a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf). A person carries something on the order of one to two thousand differences from the reference in every megabase of DNA, so a window this size should hold hundreds rather than tens or millions, and the benchmark holds 961 records over it.

Having a known answer changes what a run is for. On a fresh patient sample you can only ask whether the output looks plausible. Here you can ask whether it is right, because 961 rows of truth sit next to it. That is why this chapter calls a human sample rather than a virus, and why the checks at the end compare counts against the benchmark rather than against intuition.

A run on this slice takes well under a minute, so you can try a setting, look at the result, and try another.

## Before you start

You need a project open, which is the folder LGE keeps all of your data and results in. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This feature is experimental. Turn on **Show Experimental Features** in **Settings > Advanced** before you look for it. Experimental here describes the LGE surface around the tool rather than the calls themselves, since the calls come from GATK unchanged, and what it warns you about is that the dialog, its labels, and its defaults may move between releases. One entry described below does not run at all, and Step 5 says so plainly.

This chapter uses the HG002 chromosome 20 slice. Download the files `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. On that page, click a filename and then the Download raw file button, since the page itself only previews the file. No GitHub account is needed to download them. The FASTA is the reference sequence, one long stretch of chromosome 20 written out base by base. The two FASTQ files are the raw reads from the sequencer, each read stored with a quality score for every base, split into read 1 and read 2 because each DNA fragment was read from both ends.

### Map the reads first

What this chapter needs in the project is the alignment those reads produce, not the reads themselves. Import the FASTA with **File > Import Center...** and the two FASTQ files the same way, then map them with **Tools > Mapping > minimap2...** as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes. Accept every default in that wizard, including the Short-read preset it picks for these files.

That leaves a reference bundle carrying an alignment track. A bundle is the reference sequence plus everything later derived from it, and a track is one such derived layer, so the sidebar shows the bundle with the new alignment nested underneath it once mapping succeeds. That alignment track is what the Call Variants dialog reads. The dialog can only use a track inside a bundle, never a BAM file sitting loose in a folder.

### Three things GATK needs from the alignment

Two of these stop a run cold, the sequence dictionary and the read group, and the third only affects how good the answers are.

The reference FASTA needs a [sequence dictionary](../../GLOSSARY.md#sequence-dictionary) beside it, a small `.dict` file listing each contig and its length. LGE never creates that file, and GATK refuses to start without it, so make it once per reference before you run anything. Both routes need it, the dialog exactly as much as the command line, because both hand GATK the same bare FASTA. Open the Terminal application, change to the folder holding your reference, and run this one command.

```bash
~/.lungfish/conda/envs/gatk-core/bin/gatk CreateSequenceDictionary -R GRCh38.chr20.10.0-10.5Mb.fasta
```

That writes a `.dict` file beside the FASTA and you never touch it again. Install the GATK Core pack first, which the next subsection covers, since this line calls GATK directly rather than through `lungfish-cli`. The command names the program by its full path because the pack keeps its copy at `~/.lungfish/conda/envs/gatk-core/bin/gatk` and does not add it to the folders your shell searches, so a bare `gatk` is not found. The tilde stands for your home folder and is typed exactly as printed.

The BAM needs a [read group](../../GLOSSARY.md#read-group), which is a header line naming the sample the reads came from, because GATK refuses to run without one and uses that name as the sample column of the VCF. The alignment LGE's mapper produces carries one already, so there is nothing for you to do here. You can see the value LGE will write in the Map Reads wizard's **Read Group** disclosure, in its **Sample** field, which reads `HG002` on this fixture.

The alignment should also be shotgun rather than amplicon data. Shotgun sequencing breaks the DNA at random and reads the pieces, so reads start at random positions across the whole target. Amplicon sequencing amplifies chosen stretches with primers, so every read in a stretch starts and ends at the same two places. HaplotypeCaller's reassembly assumes randomly placed reads, so it suits shotgun data and misjudges amplicon data. This fixture is shotgun, and its library was prepared without a PCR amplification step, which matters for one setting described later.

### Install the plugin pack

The tools arrive in [plugin packs](../../GLOSSARY.md#plugin-pack), which are groups of third-party programs LGE installs on request. HaplotypeCaller needs the `gatk-core` pack and the phased route needs `phasing` as well. Install both from **Tools > Plugin Manager...** (Cmd-Shift-B) with experimental features turned on, since both packs are marked experimental and the Plugin Manager is the only place that shows them. Installing `gatk-core` places the `gatk` program at the full path the sequence dictionary command above uses.

## Procedure

### Step 1. Open the Call Variants dialog

Select the reference bundle in the sidebar and choose **Tools > Call Variants...**. The same dialog opens from the Inspector's **Variant Calling** tab, where a **Call Variants...** button sits.

Two conditions stop the dialog before it appears. The bundle needs at least one analysis-ready BAM track, and without one an alert reading "No Analysis-Ready BAM Tracks" opens instead. Analysis-ready means a BAM alignment that has been sorted into reference order and given an index, which is a companion file letting a tool jump straight to one region instead of reading the whole file. The mapping step in Before you start produces both automatically, so a track you mapped in LGE is already analysis-ready and there is nothing for you to do. If another operation currently holds the bundle, an "Operation in Progress" alert opens instead. Wait for that operation to finish and try again.

### Step 2. Select GATK HaplotypeCaller and read the dialog

Click **GATK HaplotypeCaller** in the tool sidebar on the left, where its one-line subtitle reads "Germline SNP and indel calling with standard VCF genotypes." Two badges can appear on that row instead, and both mean the same thing for you. "Requires GATK Core Pack" means the pack is not installed at all, and "Requires GATK4" means the pack is installed but GATK itself is not ready inside it. Either way the fix is the Plugin Manager route given in [Before you start](#install-the-plugin-pack).

The right side is a pane that scrolls, holding four sections one under another.

- **Overview** holds an Alignment Track picker and an Output Variant Track Name field. The name field fills itself in as the track name, then a bullet character, then the tool name, so a track called `hg002-minimap2` produces `hg002-minimap2 • GATK HaplotypeCaller`.
- **Thresholds** holds Minimum Allele Frequency and Minimum Depth.
- The section named for the tool holds no controls at all, only the line "GATK HaplotypeCaller will write a standard genotype VCF for the selected BAM."
- **Extra arguments** is a single text field.

The footer carries the readiness line, which reads "Ready to run GATK HaplotypeCaller on <track>." once a track is chosen, along with Cancel and Run.

<!-- SHOT: call-variants-dialog-gatk -->

The Thresholds section needs reading twice, because it is the most common source of confusion in this dialog for the GATK tools. Both fields are drawn for every caller in the list, and neither reaches GATK. Typing 0.20 into Minimum Allele Frequency before a HaplotypeCaller run does not make GATK apply a 20 percent floor. GATK decides which alleles to emit from its own genotype likelihoods, which are GATK's own probabilities that each possible genotype is the right one, and the two numbers are discarded when the run starts. They reach neither GATK nor the provenance record, so do not go looking for them there afterwards. Every other field in this dialog does take effect, and Extra arguments is the only route from here to a setting GATK actually reads.

### Step 3. Run and watch the Operations panel

Check that the Alignment Track picker names your minimap2 track, leave every field alone, and click **Run**.

The Operations panel opens and shows the run. LGE builds the GATK command, runs it inside the `gatk-core` environment, writes the VCF to `variants/gatk/<track-id>.vcf.gz` inside the bundle, loads the rows into a small SQLite database beside it so the table can filter quickly, and attaches all of it to the bundle as a named variant track described as "GATK HaplotypeCaller variants from <alignment>". The track id in that path is generated by LGE and you never need to type or even see it, and the SQLite database is an internal index that the Variants tab queries for you and that you never open yourself. A run that is taking too long can be cancelled from the Operations panel row.

<!-- SHOT: operations-panel-gatk-run -->

The dialog and the command line use different defaults for one setting. The dialog always asks GATK for a VCF listing variant positions only, and the command line asks instead for a GVCF, which additionally records how confident the caller was at every position that matched the reference. Nothing in this chapter asks you to change that, so a reader working in the window should accept the dialog's choice and read on. It matters only if you later want to combine this sample with others, which is the [Joint Genotyping](02-joint-genotyping.md) chapter's subject, and that route needs a GVCF from the command line.

### Step 4. Read the calls in the Variants tab

Click the reference bundle in the sidebar again. What has changed since Step 1 is that the bundle now holds a variant track, and the [table drawer](../../GLOSSARY.md#table-drawer) opens once such a track exists, sliding up from the bottom of the viewport, which is the large panel where LGE draws your data. The new track loads into the drawer's **Variants** tab. Click a column header to sort by that column, and click the **Presets** button above the table to reveal the filter chips, which are small buttons that switch one filter on or off. [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md) covers both in full.

### Step 5. Use the command line for the phased route

A second entry, **GATK + WhatsHap Phased**, sits in the same tool list with the subtitle "Phase-aware HaplotypeCaller plus WhatsHap command plan." WhatsHap is a separate program, not part of GATK, that reads an existing set of calls and works out which nearby variants sit on the same copy of a chromosome. This entry needs the `phasing` pack alongside `gatk-core`.

Do not run this entry from the dialog in this release. Use the command shown in the last section of this chapter instead, which does the same job and works. Selecting the entry here and clicking Run raises an alert titled "Variant Calling Not Ready" and writes nothing. The dialog builds its two-step plan correctly, but no other part of the app reads that plan, so the launcher finds nothing to run. This is a defect rather than a setting you can change, and no value you type will get past it.

## Settings

The GATK HaplotypeCaller entry and the GATK + WhatsHap Phased entry show the same five controls, so each paragraph below covers both and names the difference where one exists. The five, in the order they appear, are Alignment Track, Output Variant Track Name, Minimum Allele Frequency, Minimum Depth, and Extra arguments.

**Alignment Track.** Chooses which alignment GATK reassembles reads from. The default is the first analysis-ready BAM alignment track the bundle holds, whichever track you opened the dialog from. Any analysis-ready BAM track in that bundle is allowed, so change it whenever the bundle holds more than one alignment, and prefer a whole-genome or exome alignment over an amplicon one. A whole-genome library covers the entire genome, an exome library covers only the protein-coding parts, and an amplicon library covers a handful of chosen stretches. The first two are shotgun data and suit HaplotypeCaller, whose reassembly assumes randomly placed reads, and this chapter's fixture is a whole-genome library. On the phased entry this choice also decides whether phasing can work at all, since [read-backed phasing](../../GLOSSARY.md#read-backed-phasing) only connects two variants when single reads or read pairs span both. On the command line this is `--bam`.

**Output Variant Track Name.** Names the variant track the run creates, while the VCF itself always lands under the bundle's `variants/gatk` folder with a generated identifier for a filename. The default is the alignment name, then a bullet, then the tool name, and the app appends a number when that name is already taken, so repeated runs never overwrite each other silently. Change it when you want a shorter or more descriptive label than the generated one. This setting has no command-line flag.

**Minimum Allele Frequency.** Sets a frequency floor that the GATK entries never use. GATK decides which alleles to emit from its own genotype likelihoods, and this number is discarded when the run starts rather than passed along or recorded, so the value has no effect whatever on a GATK run. The field still shows a default of 0.05 and still accepts a decimal between 0 and 1 or a blank, because it is drawn for every caller in the list and other callers do read it. Leave it alone on both GATK entries and use Extra arguments if you need a threshold GATK will honour. This setting has no command-line flag.

**Minimum Depth.** Sets a [depth](../../GLOSSARY.md#depth) floor that the GATK entries never use, depth being the number of reads covering a position. The number is discarded when the run starts rather than passed along or recorded, so like Minimum Allele Frequency it changes nothing about a GATK run. The field shows a default of 10 and accepts any whole number or a blank. Leave it alone on both GATK entries and use Extra arguments for a threshold GATK will actually apply. This setting has no command-line flag.

**Extra arguments.** Adds your own arguments to the GATK command the dialog assembles, written exactly as GATK expects them, and this is the only route from inside the dialog to a GATK setting. The default is empty and any HaplotypeCaller flags are allowed. Use it to restrict a run to an interval list, or to set [ploidy](../../GLOSSARY.md#ploidy) on a sample that is not diploid. Ploidy is how many copies of each chromosome the sample carries, and diploid means the two copies a human autosome has, so a haploid sample wants the single string `--sample-ploidy 1` typed into this field. On the GATK HaplotypeCaller entry this is `--extra-args` on the command line, and on the phased entry it is `--extra-gatk-args`, which reaches only the calling half of the plan since the dialog offers no equivalent for the WhatsHap half.

### Command-line only settings for HaplotypeCaller

Nine more settings exist on `lungfish-cli gatk haplotype-caller` and have no control in the dialog. A reader working only in the window can skip this subsection and the next one, since neither changes anything the dialog can reach.

**`--emit-ref-confidence`.** Chooses whether the run writes a GVCF, which records confidence at every position including the ones that match the reference, or a plain VCF listing variant positions only. The default is `GVCF`, and `NONE` is the other accepted value, with anything else falling back to `GVCF` rather than raising an error, so check your spelling when you meant `NONE`. Change it to `NONE` when you want a finished single-sample VCF now, and leave it at `GVCF` when the sample is destined for [joint genotyping](../../GLOSSARY.md#joint-genotyping), meaning calling many samples together as one cohort rather than one at a time. The dialog always asks for `NONE`.

**`--ploidy`.** Sets how many copies of each chromosome the sample carries, which decides which genotypes GATK is allowed to write. The default is 2, correct for a human autosome, where 1 suits a virus or a haploid organism. Change it for a non-diploid sample or for most of the male X chromosome, which carries only one copy.

**`--intervals`.** Restricts the run to the regions listed in a BED file or interval list rather than calling the whole reference. The default is none, so the whole reference is called, and any BED, interval-list, or contig path is accepted. Use it for exome data or any targeted panel, where it is much faster than calling everything.

**`--pcr-indel-model`.** Tells GATK how much insertion and deletion noise to expect from the library's PCR step, which changes how readily it calls a short indel. A library is the prepared pool of DNA fragments that went into the sequencer, and PCR-free means that pool was made without an amplification step, which is how this chapter's fixture was prepared. The default is `CONSERVATIVE`, which suits an ordinary PCR-based library. Change it to `NONE` for a PCR-free library, where the conservative model would otherwise discard real indels as amplification artifacts.

**`--stand-call-conf`.** Sets the confidence score a call must reach before GATK emits it, on the same Phred scale as the QUAL column described under Reading the results. The default is 30.0, which on that scale means about a one in a thousand chance the call is wrong, a low and permissive bar next to the hundreds and thousands that real calls on this fixture reach. This threshold applies only when the run is not writing a GVCF, because in GVCF mode GATK defers the decision to the joint-genotyping step. Raise it for a stricter list of calls, lower it when you would rather filter later than lose a real variant now.

**`--max-alternate-alleles`.** Caps how many different alternate bases GATK will consider at a single position, which bounds how much work a messy position can cost. Reaching the cap is not an error, and GATK keeps the best alternates it found and drops the rest, so the risk is a quietly missing allele rather than a failed run. The default is 6, high enough that ordinary human positions never reach it. Lower it only when a run slows to a crawl on repetitive regions.

**`--pair-hmm-threads`.** Sets how many threads the read-to-haplotype scoring step uses, threads being parallel workers running at the same time, and that step is where most of a HaplotypeCaller run's time goes. The default is 4 and it is always emitted, in the dialog as well as on the command line, where the two defaults happen to coincide. Read your Mac's core count from **Apple menu > About This Mac**, and raise this no higher than about half of it so the rest of the machine stays responsive.

**`--execute`.** Actually runs GATK through the managed pack, where without it the command is only constructed and printed. The default is off, which is why a first command prints and stops rather than calling anything. Add it once you have read the printed command and want the real output.

**`--dry-run`.** Lets you inspect a command inside a script that otherwise always passes `--execute`, by printing the command preview and stopping. The default is off, and passing it alongside `--execute` still produces a preview, since `--dry-run` takes priority whenever both are present.

### Command-line only settings for the phased route

Six settings exist on `lungfish-cli variants phase` and have no control in the dialog.

**`--output-dir`.** Chooses where the written command plan and its provenance record land. The default is the folder holding the output VCF, so a plan written without it sits beside its own result. Set it when you want plans and provenance collected somewhere separate from the data.

**`--sample`.** Names the sample WhatsHap should phase, for a VCF that carries more than one. The default is none, which is correct for a single-sample VCF like the one this plan's first step produces. Set it only when you point the plan at a multi-sample VCF.

**`--threads`.** Does not work in this release, so treat the phased route as single-threaded and leave this flag off. It is documented as setting the GATK scoring threads, with a default of 1, but a run passing `--threads 4` still prints and records `--native-pair-hmm-threads 1`, and the plan file, the provenance record, and the executed command all show 1 whatever you pass. The cause is that `lungfish-cli` already carries a global `--threads` option, which takes the value before the phase command ever sees it.

**`--extra-whatshap-args`.** Adds your own arguments to the WhatsHap phase command, the second half of the plan. The default is none, and the dialog offers no equivalent. Use it to reach a WhatsHap option the plan does not set, such as its indel handling.

**`--execute`.** Actually runs GATK and WhatsHap through the managed packs, where without it the plan is written and printed but neither tool runs. The default is off, so this command previews by default exactly as the `gatk` commands do. Add it once you have read the printed plan.

**`--dry-run`.** Writes and prints the command plan without running either tool. The default is off, and it takes priority over `--execute` when both are present. Use it to inspect the plan inside a script that otherwise always executes.

The phased plan also fixes two things you cannot change. It always calls with `-ERC NONE`, since WhatsHap needs genotyped calls rather than a GVCF, and it always writes its intermediate unphased calls to `gatk-unphased.vcf.gz` in the output directory.

## Reading the results

A finished run on the HG002 chromosome 20 slice writes 1,026 rows, of which 844 are [SNVs](../../GLOSSARY.md#snv), single-base changes, and 182 are indels. Those are the Variants tab's own Type counts, which judge each row by its first alternate allele, and they add to the 1,026 the tab reports. A tally made with `bcftools` instead reads 843 and 184, because one row here carries both a substitution and an insertion as its two alternate alleles and `bcftools` counts that row under both of its type headings.

The [genotype](../../GLOSSARY.md#genotype) is the first per-sample field on each row and it says which two copies of the position this person carries. It is written as two numbers with a slash between them, where 0 means the reference base and 1 means the first alternate. So `0/1` is one reference copy and one alternate copy, which is a heterozygous site, and `1/1` is two alternate copies, which is homozygous. On this fixture 589 rows read `0/1`, another 418 read `1/1`, and a further 19 read `1/2`, meaning two different non-reference alleles and no reference copy at all. Heterozygous calls are therefore 589 of 1,026, which is about 57 percent, and a ratio near or somewhat above one to one is what a single human sample at this depth looks like. A run that returned almost no heterozygous calls would suggest the sample is not what you think it is.

QUAL is the caller's confidence that a variant exists at all at this position, on the Phred scale, where the score rises as the chance of being wrong falls, so 30 means about one in a thousand and 60 means about one in a million. Higher is more confident, and there is no fixed pass mark, so judge a QUAL against the other calls in the same run and against the benchmark rather than against a number this chapter could give you. The mean QUAL across this fixture is 903, and individual strong calls run into the thousands, with the first row of the file reading 2175.06. Check a call whose QUAL is in the low tens before you trust it.

Two depth figures describe this run and they measure different things. The mean of the per-sample FORMAT DP field across the 1,026 called positions is 38, and the mean read depth across the whole 500 kilobase window, read from the alignment rather than from the calls, is 44.7. The gap is expected. Variant positions average a little lower than the window as a whole because the caller discards reads it does not trust before it counts, and because positions where the reads disagree tend to be harder to cover in the first place. A region under 10 is too thin to call a variant with confidence.

A GVCF looks nothing like this and the difference catches people out. The same reads written as a GVCF give 48,057 rows, because 46,858 of them are reference blocks, each one a run of consecutive positions where the sample matched the reference and GATK is recording how sure it was. Only 1,199 rows carry an alternate allele, which is more than the 1,026 in the genotyped VCF because a GVCF also keeps candidate positions that the genotyping step later looked at and did not call. Opening a GVCF expecting a variant list is the most common confusion in this part of the manual, and the row count is the giveaway.

The phased route's output has the same 1,026 rows and one extra thing in the genotype field. Where an unphased heterozygous call reads `0/1`, a phased one reads `0|1` or `1|0`, and the upright bar says WhatsHap worked out which copy of the chromosome each allele sits on. On this fixture 373 of the 589 heterozygous calls came back phased, 188 as `0|1` and 185 as `1|0`, gathered into 125 [phase sets](../../GLOSSARY.md#phase-set). A phase set is a stretch within which the phasing is internally consistent, and two variants in different phase sets tell you nothing about each other. Judge that rate against other samples you run on the same read length rather than against a fixed target, since how much of a sample phases depends on how far apart its variants sit and how far a read pair reaches. The 216 heterozygous calls that stayed `0/1` are the ones where no single read covered the variant together with a nearby one. The 19 `1/2` calls stay unphased as well and are not counted in either the 373 or the 216.

## What good looks like

Check the sample name first. The VCF's sample column should carry the name from the BAM's read group, which is `HG002` here, and a VCF whose sample column reads something unexpected means the wrong alignment was called.

Check the total against the benchmark. This fixture ships a benchmark VCF holding 961 records over the same window, and a HaplotypeCaller run returning 1,026 is close to it. The benchmark is the measure here, not a range this chapter could invent, so compare your total to 961 and treat a difference of a few percent as ordinary. Some difference is expected and not a fault, because the benchmark was built from deeper data by several methods. A run returning a few dozen rows, or tens of thousands, has gone wrong somewhere upstream.

Check the heterozygous fraction, which is 589 of 1,026 here, about 57 percent, and should sit near or somewhat above half on a human sample. A run where nearly everything is heterozygous usually means two samples are mixed in one BAM. A run with almost no heterozygous calls usually means ploidy was set to 1, which can only happen on a command-line run, since the dialog never sets ploidy and always leaves it at 2.

Check that the run finished cleanly. In the window, the Operations panel row for the run should end as completed rather than failed, and the sidebar should show the new variant track under the bundle. On the command line a successful `--execute` prints two lines, the GATK exit code and the path to the provenance record. A failed one prints neither, raises an error, exits nonzero, and still writes a provenance record with a failed status, so the error messages GATK printed as it stopped are recorded there for you to read. LGE also deletes the outputs that run created, leaving anything that existed beforehand untouched, so a failure does not leave a half-written VCF for the next step to pick up.

Read the provenance record before you rely on a number. Click the new variant track in the sidebar and the Inspector shows it, holding the exact GATK command, the environment it ran in, the inputs and outputs with their checksums and sizes, the exit status, the elapsed time, and the error output GATK produced. On this fixture the record reports about 23 seconds elapsed for the calling step.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the dialog cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application. One thing here is not optional, the sequence dictionary command, which both routes need and which [Before you start](#three-things-gatk-needs-from-the-alignment) gives as a required step.

Every `lungfish-cli gatk` command builds and prints a GATK command without running anything. Add `--execute` to run it. That is the habit worth keeping, because reading the command back before it runs is the point of the wrapper.

The commands below name files by their bare filenames, so run them from the folder holding your reference and your BAM. The BAM is the alignment the mapping step produced. LGE writes it inside the reference bundle, under the bundle's own folder in your project, and the `hg002-minimap2.bam` below is a copy of that file placed beside the reference for these examples.

```bash
# Install the tool, since the experimental pack id is not
# resolvable by 'conda install --pack'
lungfish-cli conda install gatk4 --env gatk-core

# Preview. Prints the GATK command and stops.
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output HG002.chr20.g.vcf.gz

# Run it. Writes the GVCF, its index, and a provenance record.
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output HG002.chr20.g.vcf.gz \
    --execute

# The same reads as a genotyped VCF, which is what the dialog asks for
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output HG002.chr20.vcf.gz \
    --emit-ref-confidence NONE \
    --execute
```

The pack id for `--pack` is not resolvable for an experimental pack, which is why the install command above names the tool `gatk4` and its environment instead. `lungfish-cli conda install --pack gatk-core` fails, reporting `gatk-core` as an unknown tool pack, because the command-line installer only resolves the packs it lists publicly and experimental packs are not among them. The Plugin Manager route in Before you start has no such limit and is the one to prefer.

The preview prints one line, and reading it is worth a moment because it is what GATK will receive.

```text
gatk HaplotypeCaller -R GRCh38.chr20.10.0-10.5Mb.fasta -I hg002-minimap2.bam -O HG002.chr20.g.vcf.gz --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 -ERC GVCF
```

LGE renames two of GATK's own flags and offers them under its names, so two spellings in that line differ from the options that produced them. GVCF mode appears as GATK's short form `-ERC GVCF` where LGE spells it `--emit-ref-confidence`, and the thread count appears as `--native-pair-hmm-threads` where LGE spells it `--pair-hmm-threads`. Nothing has gone wrong, and both lines mean the same thing.

Anything the promoted options do not cover goes through `--extra-args`. LGE splits the quoted string into separate arguments and appends them to the end of the GATK command unchanged. A string it cannot split is rejected before anything runs, reporting an unterminated quote, and the only way to produce that is to open a quote inside the string and never close it. Writing `--annotation 'Coverage` with one apostrophe and no matching one is the whole of it.

```bash
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output HG002.chr20.g.vcf.gz \
    --intervals target.bed \
    --extra-args "--annotation Coverage" \
    --execute
```

The phased route is a separate command that runs two tools in order, and it is the working way to reach phasing since the dialog's entry does not run.

```bash
lungfish-cli variants phase \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output-vcf phased/HG002.phased.vcf.gz \
    --output-dir phased \
    --execute

# Index the phased VCF, since 'variants phase' does not
tabix -p vcf phased/HG002.phased.vcf.gz
```

That run prints both commands, then "Phased variant calling complete." It writes the phased VCF, the intermediate `gatk-unphased.vcf.gz` and its index, a `phased-variant-command-plan.json` recording the plan, and a provenance record covering both steps. On this fixture the whole thing took 26 seconds, 23 in GATK and 3 in WhatsHap. The phased VCF is the one output written without an index, which is why the `tabix` line above follows it, since any tool that reads one region rather than the whole file needs that index first.

Three programs used here come from outside `lungfish-cli` itself. `wc`, which counts lines, ships with macOS and is always there. `bcftools` and `tabix` do not, and LGE keeps each of them in a managed environment of its own rather than in the GATK pack, so install them with `lungfish-cli conda install bcftools` and `lungfish-cli conda install htslib`, the second of which is the package `tabix` lives in. The counting commands below are optional extras that check a result rather than produce one.

```bash
# Count the rows, and count how many heterozygous calls came back phased
bcftools view -H HG002.chr20.vcf.gz | wc -l
bcftools query -f '[%GT]\n' phased/HG002.phased.vcf.gz | grep -c '|'
```

Nine more GATK subcommands sit alongside `haplotype-caller` under `lungfish-cli gatk`, covering joint genotyping, filtering, selecting, table export, base quality recalibration, duplicate marking, SAM validation, left-alignment, and metrics collection. Each takes `--execute` and `--dry-run` the same way.

## Next

[Joint Genotyping](02-joint-genotyping.md) takes a GVCF and combines it with GVCFs from other samples into one cohort VCF, which is the step that makes the GVCF default worth having. That chapter needs a GVCF, which only the command-line route above produces, since the dialog always asks for a plain VCF instead. [Filtering, Selecting and Metrics](03-filtering-selecting-and-metrics.md) covers what to do with the calls once they exist. [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md) covers the table that displays a track attached from the dialog.
