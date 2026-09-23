---
title: Reference Files for GATK
chapter_id: 06-human-germline-variants/04-reference-packs
audience: power-user
prereqs: [01-foundations/07-plugin-packs, 06-human-germline-variants/01-haplotype-caller]
estimated_reading_min: 30
task: Build the companion files GATK germline commands need beside a reference FASTA, and install the GATK Core pack.
tags: [gatk, reference, known-sites, bqsr, sequence-dictionary, plugin-pack]
tools: [gatk, samtools, bcftools]
parameters_refs: []
entry_points:
  - "GUI: Plugin Manager > GATK Core (needs Show Experimental Features)"
  - "GUI: Plugin Manager > Variant Phasing (needs Show Experimental Features)"
  - "CLI: lungfish-cli gatk bqsr --reference <fasta> --bam <bam> --known-sites <vcf> --recal-table <table> --output <bam>"
shots:
  - id: settings-advanced-experimental
    caption: "The Advanced tab of Settings, showing the Show Experimental Features toggle and the warning printed beside it."
  - id: plugin-manager-gatk-packs
    caption: "The Plugin Manager Packs tab with experimental features shown, listing the GATK Core and Variant Phasing cards under Variant Calling with their size estimates and install buttons."
illustrations: []
glossary_refs: [bam, bgzip, bqsr, bundle, checksum, dbsnp, fai, fasta, germline, indel, interval-list, known-sites, phred-score, picard, plugin-pack, provenance-sidecar, read-group, recalibration-table, reference-genome, required-setup-pack, sequence-dictionary, snv, tabix, transition-transversion-ratio, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

!!! note "Preview feature (experimental)"
    GATK germline support in Lungfish Genome Explorer (LGE) is a power-user
    preview. The GATK Core pack is flagged experimental, so check results
    against something you trust before you rely on them.

## What it is

Everything in this chapter is typed into the macOS Terminal application rather than clicked in the LGE window. No dialog exists in LGE for any step below, and the one thing you do in the window is install a plugin pack. Read [HaplotypeCaller](01-haplotype-caller.md) first if you have not, since this chapter assumes its worked example, and Before you start walks through opening a terminal for readers who have never used one.

GATK is the Broad Institute's Genome Analysis Toolkit, the widely used collection of programs for calling and refining [germline](../../GLOSSARY.md#germline) variants, meaning the differences a person inherited from their parents and carries in every cell. "Reference pack" is a convenience name this manual uses for the set of files a GATK germline workflow expects to find on disk. LGE does not track or manage that folder for you. No `lungfish-cli` command installs, downloads, validates, or enforces a reference pack, and no such thing exists in the app's code. `lungfish-cli` is the command-line version of LGE, a program you type at a terminal prompt rather than a menu item in the window. The folder is one you assemble yourself, and its location is typed into each command as ordinary text.

A [reference genome](../../GLOSSARY.md#reference-genome), the agreed sequence that everything else is described against, arrives as a plain [FASTA](../../GLOSSARY.md#fasta) file. That is a text file where a line beginning with a greater-than sign names a sequence and the lines under it hold the bases, meaning the letters A, C, G, and T. GATK will not read a FASTA with no companion files beside it. It wants two small ones that let it find any position quickly and check that every other file you give it describes the same genome.

LGE never builds either companion for a loose FASTA like this one. It does index the FASTA inside a reference [bundle](../../GLOSSARY.md#bundle) when it builds one, a bundle being a folder the Finder shows as a single icon holding a reference and everything derived from it, but that index lives inside the bundle under a different name and is no use to a `gatk` command pointed at your own file. GATK does not build the missing file for you either. It stops with an error instead.

Beyond the reference itself, some GATK steps want a catalogue of positions where human variation is already known and expected. These are the [known sites](../../GLOSSARY.md#known-sites), and they matter for one specific reason. Several GATK steps need to tell a sequencing error apart from a real difference between this person and the reference. You cannot judge your own results using your own results, so the positions where people are already known to differ have to be set aside in advance, and they come from public catalogues rather than from your own data.

So the rule for this chapter is short. Build these files once for each reference genome you work with, keep a note of where each one came from by writing the download address and the date into a plain text file beside the reference, and give every `gatk` command afterwards the full path to each file. A full path, also called an absolute path, is one that starts at the top of the disk and names every folder along the way, such as `/Users/you/Documents/refs/GRCh38.chr20.10.0-10.5Mb.fasta`, so it means the same file whatever folder you happen to be working in.

## Why you would do this

The step that makes the argument clearest is [BQSR](../../GLOSSARY.md#bqsr), which stands for base quality score recalibration and which runs as two GATK programs one after the other. Every base a sequencer reports comes with a [Phred score](../../GLOSSARY.md#phred-score), a number saying how confident the instrument is that it read that base correctly. The scale is logarithmic, so 20 means a one in a hundred chance of being wrong, 30 means one in a thousand, and 60 means one in a million. Instruments report scores that are systematically too high or too low, in patterns that depend on the machine, the run, the position along the read, and the neighbouring bases. BQSR measures those patterns and rewrites the scores to match reality.

Measuring them requires a definition of "wrong". BQSR takes every position where the read disagrees with the reference, calls that a mismatch, and treats mismatches as sequencing errors. That assumption is false at exactly the positions where the person genuinely carries a different base. A human genome is roughly three billion bases long and differs from the reference at about one base in a thousand, so several million positions are genuine differences rather than errors. Correcting the scores from those wrong inputs would make the scores worse rather than better. The known-sites files are the fix. GATK excludes every position listed in them before it counts anything, so the mismatches left over are mostly sequencing errors.

The same logic explains why the other files exist. GATK compares the contig names and lengths in your reference against those in every [VCF](../../GLOSSARY.md#vcf) and [BAM](../../GLOSSARY.md#bam) you give it, and refuses to proceed when they disagree, because silently mixing two builds of a genome, GRCh37 against GRCh38 for example, produces results that look fine and are wrong. A contig here is one continuous stretch of reference sequence, usually a whole chromosome in a human reference. A BAM is the compressed file of sequencing reads already lined up against a reference. The worked runs below use the HG002 chromosome 20 slice, a half-megabase cut-out of a real human genome kept small so runs finish in seconds, and one of those runs fails on precisely that check. The chapter shows that failure deliberately so you can recognise it later, and Step 4 of the worked example below is the command that produces it.

A whole human genome changes the scale but not the method. Every file in this chapter grows roughly six thousand-fold against the slice, so a real BQSR run takes correspondingly longer and its outputs are correspondingly larger, and no figure is quoted here because none was measured.

## Before you start

This chapter is command-line only. If you do your work in the LGE window, there is no dialog for any step here, and nothing in this chapter is reachable except by typing. It is for readers who need the companion files a GATK germline run demands, whether they go on to use the window or not. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application.

### Working in a terminal

Terminal is an application macOS ships with, at **Applications > Utilities > Terminal**, and Spotlight finds it if you press Cmd-Space and type its name. It opens a window with a prompt where you type one command and press Return. This manual assumes macOS throughout, so Cmd means the Command key beside the space bar.

Every command in this chapter runs from the one folder holding your downloaded files, because the commands name those files by their bare names with no folder in front. To move a Terminal window into that folder, type `cd `, with a space after it, then drag the folder from a Finder window onto the Terminal window, which pastes its path, then press Return.

Two pieces of shorthand appear in the commands below. The tilde character, `~`, stands for your home folder, the one carrying your name under Users, and you type it exactly as printed rather than replacing it with anything. The full path form, such as `~/.lungfish/conda/envs/gatk-core/bin/gatk`, is written out in full every time because typing the program's bare name would not work. The shell, which is the program reading what you type at the prompt, only finds a program by its bare name when that program sits in one of a fixed list of folders, and LGE keeps its own tools outside that list.

`lungfish-cli` is different, and is the one program here you can type by bare name. It is the command-line version of LGE, installed onto that list when LGE first runs, and [CLI Reference](../appendices/cli-reference.md) covers where it lives if your shell cannot find it.

Every `lungfish-cli gatk` command in this chapter prints the command it would run and stops there without changing anything on disk. Adding `--execute` to the same command is what makes it run. That applies to the two `bqsr` commands at the end, and not to the `samtools`, `gatk`, and `bcftools` commands, which are the tools' own and run as soon as you press Return.

### The project and the files

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. The project is what the Plugin Manager installs packs into, and it is the only reason you need one here, since the files below do not have to live inside the project folder and the command line writes wherever you point it.

This chapter uses the HG002 chromosome 20 slice. HG002 is a well-characterised reference individual whose genome has been sequenced many times, and the slice is a small cut-out region kept short so every run finishes quickly. You need four files from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

Those four are `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz`, and the alignment `expected/mapping/HG002.sorted.bam` with its index `HG002.sorted.bam.bai`. GitHub offers no download for a single folder, so open the repository's front page at https://github.com/dhoconno/lungfish-genome-explorer, click the green **Code** button, choose **Download ZIP**, double-click the downloaded file to unpack it, and find the folder inside it under `docs/user-manual/fixtures/`. The BAM and its index sit one level deeper than the other two, under `expected/mapping/`, and all four arrive in the same unpacked folder rather than needing anything run to produce them. Put all four in one folder, keeping the names exactly as given, since every command below uses them, and open a Terminal window in that folder as the last subsection described. That BAM was made by mapping the fixture's reads against the FASTA before it was published, so you do not have to map anything here, and [Map the reads first](01-haplotype-caller.md#map-the-reads-first) covers that step if you would rather produce your own.

The fixture also ships `GRCh38.chr20.10.0-10.5Mb.fasta.fai`, the reference index this chapter's first command builds. The two are byte-identical, so you may keep the one that came with the fixture and read the next section rather than running it. Building it once is still worth doing, because it is the shortest way to see where the file comes from.

Exact file sizes vary by a few bytes between machines, and the sequence dictionary's size varies more than the rest for a reason the section on it explains. Treat the byte counts quoted below as the figures from one machine rather than as targets. Only a count of zero, or a file that never appears, signals a problem.

### Install the plugin pack

GATK comes from the GATK Core [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on demand, and it is not installed by default. This feature is experimental. Turn on **Show Experimental Features** in **Settings > Advanced** before you look for it, which is the Advanced tab of the Settings window that opens from **Lungfish Genome Explorer > Settings**. The warning printed beside that toggle is worth reading, because it says experimental features may be incomplete, change without compatibility guarantees, and are not intended for production scientific work.

<!-- SHOT: settings-advanced-experimental -->

With the toggle on, bring the project window to the front and open **Tools > Plugin Manager...** (Cmd-Shift-B), which needs that window frontmost to respond. Find the GATK Core card under the Variant Calling category and install it. Its description reads "GATK4 command construction and dry-run support for human germline workflows". That description is out of date, since the commands in this chapter execute GATK rather than only printing what they would run.

<!-- SHOT: plugin-manager-gatk-packs -->

Budget about 1 GB of free disk for the install. Three figures circulate for it and they measure different things. The card's estimate of about 600 MB is a download estimate the app has not refreshed, the environment measured 887.6 MB on disk once installed on the machine used here, and both are smaller than the headroom a conda install wants while it unpacks. Beside GATK Core sits the Variant Phasing card, which provides WhatsHap for the phasing command and is estimated at 180 MB against a measured 369.9 MB. This chapter does not need Variant Phasing, so leave it alone.

!!! note "Two app defects worth knowing here"
    The Plugin Manager is the only route that installs either pack, which is a defect rather than a design choice. Running `lungfish-cli conda install --pack gatk-core` stops with an unknown-pack error and installs nothing, listing eight packs that exclude it, because the command-line installer only resolves ids it treats as non-experimental. `--pack phasing` fails the same way. Both end with an exit status of 3, the number a command hands back to say how it finished, where zero means success and anything else means it stopped. Separately, the size estimates on both cards understate the installed environments, which is why the figure to budget around is given above rather than read off the card.

The pack installs GATK 4.6.2.0 at `~/.lungfish/conda/envs/gatk-core/bin/gatk`. Two of the files this chapter builds are made with that binary, and the rest with `samtools` and `bcftools`, which both ship in the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) that LGE installs by itself the first time you make a project. You can confirm it on the Plugin Manager's Packs tab, where the Third-Party Tools card under Required Setup shows as installed. The whole set of runs below takes under a minute on the fixture.

## The reference FASTA and its index

The FASTA is the file you already have, and the first companion is its index, a small text file named `<fasta>.fai` that records where each sequence starts inside it. Without the [FAI](../../GLOSSARY.md#fai), a tool wanting one stretch of chromosome 20 would have to read the whole file to find it. With the index it jumps straight there. You create it with `samtools faidx`, run from the folder holding the FASTA.

```bash
~/.lungfish/conda/envs/samtools/bin/samtools faidx GRCh38.chr20.10.0-10.5Mb.fasta
```

That command prints nothing at all when it succeeds, so confirm it by listing the new file, which is the only sign you get.

```bash
ls -l GRCh38.chr20.10.0-10.5Mb.fasta.fai
```

On the fixture that file is 34 bytes holding one line. Its five tab-separated fields are these, in order, and the tab characters render as blank space on the page.

| Field | Value on the fixture | What it is |
|---|---|---|
| 1 | `chr20_10.0-10.5Mb` | The sequence name |
| 2 | `500001` | Its length in bases |
| 3 | `19` | The byte offset where its bases begin, used internally and never checked by you |
| 4 | `50` | Bases per line |
| 5 | `51` | Bytes per line, counting the newline |

The slice is 500,001 bases long, which is the figure every later count in this chapter is measured against. The file's own size follows the length of the sequence name, so a different reference gives a different byte count and only the contents matter.

Skip this file and GATK stops before it looks at any of your data. The error names the file it wanted and links to the Broad Institute's page about reference inputs, which is worth knowing because the message is specific enough to act on without guessing. It appears in the Terminal window, and in the error output the provenance record saves. The `file:///.../` in the middle of it is this manual's shortening of your own folder path, which the real message writes out in full.

```text
A USER ERROR has occurred: Fasta index file file:///.../GRCh38.chr20.10.0-10.5Mb.fasta.fai
for reference file:///.../GRCh38.chr20.10.0-10.5Mb.fasta does not exist. Please see
https://gatk.broadinstitute.org/hc/articles/360035531652-FASTA-Reference-genome-format for help creating it.
```

## The sequence dictionary

The second companion is the [sequence dictionary](../../GLOSSARY.md#sequence-dictionary), a file named `<reference stem>.dict` that lists every contig in the reference with its length and a [checksum](../../GLOSSARY.md#checksum) of its bases. A checksum is a short fingerprint computed from the sequence, so it changes if the sequence changes and stays the same if it does not.

!!! note "The two companion files are named differently"
    The index appends to the whole file name and the dictionary replaces the `.fasta` extension. So a reference called `GRCh38.chr20.10.0-10.5Mb.fasta` needs `GRCh38.chr20.10.0-10.5Mb.fasta.fai` and `GRCh38.chr20.10.0-10.5Mb.dict` sitting in the same folder. Getting this wrong is the most common reason a dictionary GATK cannot find is sitting right beside the reference.

GATK compares every BAM and VCF it reads against the dictionary before it starts work, since each of those files carries its own contig list. You build the dictionary once with [Picard](../../GLOSSARY.md#picard)'s `CreateSequenceDictionary`. Picard is a companion toolkit that ships inside GATK, so it needs no separate install.

```bash
~/.lungfish/conda/envs/gatk-core/bin/gatk CreateSequenceDictionary \
  -R GRCh38.chr20.10.0-10.5Mb.fasta
```

```bash
ls -l GRCh38.chr20.10.0-10.5Mb.dict
```

On the fixture that writes a 251 byte file holding two lines, an `@HD` version line and one `@SQ` line describing the single contig. Of the fields on that `@SQ` line, two are worth checking and the rest are not. `SN:chr20_10.0-10.5Mb` is the contig name and `LN:500001` its length, and those two are what every later error in this chapter turns on. The `M5` checksum, which reads `0bffe5f36c15cdb7069b96a1d4e4a0ef` here, will match on your machine because it is computed from the sequence rather than from anything local. The `UR` field holds the full path of the FASTA the dictionary was built from, so it will differ on your machine and should.

That last field is also why this file's size varies more than the others. A longer path makes a longer file, so a `.dict` of 249 or 252 bytes for this same reference is the same dictionary written somewhere else. Anything within a few tens of bytes of 251 is ordinary, and only an empty file or no file at all means something went wrong.

LGE never creates this file for you on either of its two routes, neither the command line nor the LGE window. The command line does not build it, and neither does the window's Call Variants dialog, which takes its reference from a bundle, and a bundle carries no `.dict` either. A first `--execute` run against a reference without one fails like this.

```text
A USER ERROR has occurred: Fasta dict file file:///.../GRCh38.chr20.10.0-10.5Mb.dict
for reference file:///.../GRCh38.chr20.10.0-10.5Mb.fasta does not exist.
```

## The known-sites files

Known sites reach GATK as [bgzip](../../GLOSSARY.md#bgzip)-compressed VCF files, one per resource, each with a [tabix](../../GLOSSARY.md#tabix) index beside it named `<file>.vcf.gz.tbi`. Bgzip is block compression, meaning it writes the file in independently compressed chunks so an indexed reader can jump straight to one position instead of unpacking everything before it. A file compressed with ordinary gzip carries the same `.gz` ending and will not work here, since nothing can jump inside it.

In real human work the two standard resources are [dbSNP](../../GLOSSARY.md#dbsnp), the NCBI catalogue of known human variants, and the curated Mills and 1000 Genomes indel set, a hand-checked list of common insertions and deletions that exists because dbSNP covers single-base changes far better than it covers indels. Both are published by the Broad Institute in its public GATK resource bundle on Google Cloud Storage, and dbSNP is much the larger of the two, large enough to be worth planning rather than starting casually. Neither file's size has been measured for this manual, so no figure is quoted.

You do not need either file to follow this chapter. Nothing in LGE fetches them, this manual never downloads them, and the worked example below builds a small stand-in from the fixture's own benchmark VCF instead.

The fixture ships that benchmark VCF, a set of calls made independently and treated as an answer key, holding 961 records on the sliced contig. A record is one variant position, and 961 over half a megabase is the expected order of magnitude for a human sample. Those positions serve the same role a real known-sites file serves, which is to name places where a difference from the reference is expected rather than suspicious. Giving it straight to GATK fails, and that failure is the most useful thing in this chapter.

You are meant to trigger this one on purpose, because recognising it later is worth the minute it costs. Run the command below, which points `--known-sites` at the benchmark VCF exactly as it ships.

```bash
lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz \
  --recal-table fails.recal.table \
  --output fails.bam \
  --execute
```

```text
A USER ERROR has occurred: Input files reference and features have incompatible contigs:
Found contigs with the same name but different lengths:
  contig reference = chr20_10.0-10.5Mb / 500001
  contig features = chr20_10.0-10.5Mb / 64444167.
```

The contig names match and the lengths do not. GATK calls the VCF the "features" file in its error text, so that second line is describing the known-sites file you passed. The benchmark file was made against whole chromosome 20, so its header, the block of description lines at the top of the file, still declares that chromosome's full length of 64,444,167 bases, while the sliced reference is 500,001. GATK compares the two and stops. This is the check described earlier doing its job, and it is the single most common reason a known-sites file is rejected.

The fix rewrites that header from the reference index, which is what `bcftools reheader --fai` does, leaving the records untouched. The index has to be rebuilt afterwards because the header changed, and the `-f` on the second line means the old index is overwritten rather than left in place, so there is nothing for you to delete first.

```bash
~/.lungfish/conda/envs/bcftools/bin/bcftools reheader \
  --fai GRCh38.chr20.10.0-10.5Mb.fasta.fai \
  -o known-sites.vcf.gz HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
~/.lungfish/conda/envs/bcftools/bin/bcftools index --tbi -f known-sites.vcf.gz
```

That leaves `known-sites.vcf.gz` at 38,323 bytes with a single contig line of the right length, all 961 records intact, and a 392 byte `.tbi` index. The one of those four to check is the contig length, which the What good looks like section gives a command for, since it is the one that decides whether GATK will accept the file.

Of those records 809 are [SNVs](../../GLOSSARY.md#snv), single-base substitutions, and 152 are [indels](../../GLOSSARY.md#indel), insertions or deletions. Those counts are informational and nothing later depends on them. Splitting the file in two mirrors how dbSNP and Mills are used together in real work, and this chapter never uses the split, so run it only if you want to see it.

```bash
~/.lungfish/conda/envs/bcftools/bin/bcftools view -v snps -Oz \
  -o known-snps.vcf.gz known-sites.vcf.gz
~/.lungfish/conda/envs/bcftools/bin/bcftools view -v indels -Oz \
  -o known-indels.vcf.gz known-sites.vcf.gz
```

Two files reach GATK as two separate `--known-sites` options on the same command, because that option may be written more than once.

```bash
lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites known-snps.vcf.gz \
  --known-sites known-indels.vcf.gz \
  --recal-table HG002.recal.table \
  --output HG002.bqsr.bam
```

Drop the index and GATK stops again, this time naming its own remedy. Running `~/.lungfish/conda/envs/gatk-core/bin/gatk IndexFeatureFile -I known-sites.vcf.gz` writes the `.tbi` if you would rather not use bcftools. The "block-compressed" in its message is the same thing as bgzip.

```text
A USER ERROR has occurred: An index is required but was not found for file
/.../known-sites.vcf.gz. Support for unindexed block-compressed files has been
temporarily disabled. Try running IndexFeatureFile on the input.
```

## The interval list

The last file is optional and small. An [interval list](../../GLOSSARY.md#interval-list) names the stretches of the genome a command should confine itself to, and you pass it with `--intervals`. Write it as a BED file, a tab-separated table of contig name, start, and end. One line covering the first 100 kilobases of the fixture contig, a kilobase being a thousand bases, looks like this, and the file is 27 bytes.

```text
chr20_10.0-10.5Mb	0	100000
```

Work that line through once and the convention holds everywhere. BED counts positions from zero rather than one, and it leaves the end position out. So the `0` is the first base of the contig, the `100000` is one past the last base included, and the line covers exactly 100,000 bases. Counted the way a geneticist would say them out loud, starting at one, that is bases 1 through 100,000.

Make the file in a plain text editor. TextEdit works if you first choose **Format > Make Plain Text**, and any programmer's editor works without that step. Do not use a word processor, which turns the tab characters into layout and the straight quotes into curly ones, and produces a file GATK cannot read. The 27 bytes above assume one trailing newline, so a byte or two either way is your editor's habit rather than a mistake.

Two uses justify keeping one. Exome and targeted-panel experiments only sequenced part of the genome, an exome being the protein-coding portion and a targeted panel a chosen list of genes, so calling or recalibrating outside the captured regions wastes time on positions with no data. The second use applies to any reference. Restricting a run to one region turns a long job into a quick one, which matters most while you are still checking that the command is right.

BQSR runs as two GATK programs in order, and LGE gives `--intervals` to both of them rather than only the first, so the step that measures the correction and the step that applies it see the same region. Adding it to the worked run at the end looks like this.

```bash
lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites known-sites.vcf.gz \
  --intervals first100kb.bed \
  --recal-table HG002.recal.table \
  --output HG002.bqsr.bam \
  --execute
```

## What good looks like

Before you trust a reference folder, check these four things.

1. The `.fai` and the `.dict` both sit beside the FASTA, and the `.dict` names the same contig length the `.fai` does, which for the fixture is 500,001.
2. Every known-sites VCF has a `.tbi` beside it.
3. Every known-sites VCF declares that same contig length in its header.
4. The BAM you plan to recalibrate carries a [read group](../../GLOSSARY.md#read-group), the `@RG` header line naming the sample, since GATK groups reads by it.

Three commands cover all four. The first lists the companion files, the second prints the known-sites header's contig line, and the third prints the BAM's read group.

```bash
ls -l GRCh38.chr20.10.0-10.5Mb.fasta.fai GRCh38.chr20.10.0-10.5Mb.dict known-sites.vcf.gz.tbi
~/.lungfish/conda/envs/bcftools/bin/bcftools view -h known-sites.vcf.gz | grep '##contig'
~/.lungfish/conda/envs/samtools/bin/samtools view -H HG002.sorted.bam | grep '@RG'
```

The last of those prints one line reading `@RG	ID:HG002	SM:HG002	LB:HG002	PL:ILLUMINA	PU:HG002` on the fixture, and the part that matters is `SM:HG002`, the sample name GATK will write into the VCF. If it prints nothing at all, the BAM has no read group and GATK will refuse it. Remap the reads in LGE, whose mapper writes one automatically, rather than trying to add it by hand.

A successful BQSR run prints two lines and nothing else, an exit code line and a path to the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) recording what ran.

```text
GATK execution completed with exit code 0.
Provenance: /path/to/.lungfish-provenance.json
```

On the fixture that produced a 1,191,386 byte [recalibration table](../../GLOSSARY.md#recalibration-table) and a 16,929,652 byte recalibrated BAM with its index. Both figures come from one machine and are quoted so you can see the order of magnitude, not so you can match them. The provenance records the run as two steps, each a few seconds on this fixture, and the exact durations depend on the machine rather than on anything you can control.

The table is worth opening in a plain text editor even though it is a report rather than a result. Its first block, headed "Recalibration argument collection values used in this run", lists every argument the run used, and finding your known-sites file names on that list is the fastest way to confirm they were actually read.

When a step fails, LGE still writes provenance with a failed status, the nonzero exit code, and the whole of GATK's error output in the step's `stderr` field. That field is where the three error messages quoted in this chapter came from, and reading it is faster than rerunning the command to watch it fail again.

One last check applies the reference files to a different purpose, and it is shown here rather than run, because it needs a called VCF this chapter never produces. [Filtering, Selecting and Metrics](03-filtering-selecting-and-metrics.md) covers the command itself. `lungfish-cli gatk collect-metrics` takes a called VCF, a dbSNP file, and the sequence dictionary, and reports how much of your call set was already known. Run against the fixture's bcftools calls with the reheadered known sites standing in for dbSNP, it reported 873 SNVs by Picard's own typing, of which 805 were already catalogued, a 92.2 percent overlap.

The [transition to transversion ratio](../../GLOSSARY.md#transition-transversion-ratio) it prints alongside is the useful part. A transition swaps a base for the other one of the same chemical shape, meaning A for G or C for T, and a transversion swaps between the two shapes. Biology produces transitions more readily, so real human SNVs run near 2.0 to 2.1 genome-wide and closer to 3 inside protein-coding regions, which is why the previous chapter's expected range of 2 to 3 covers both. Random sequencing error has no such preference, and because each base has one transition partner and two transversion partners, error lands near 0.5. This run gave 2.25 among the catalogued calls and 1.34 among the 68 novel ones. A novel ratio around 1 or below, well beneath the known set's, says those novel calls are substantially noise.

## On the command line

The whole sequence, from a FASTA with no companions to a recalibrated BAM, using the HG002 chromosome 20 slice. Run every line from the folder holding the four downloaded files, with the BAM copied in beside the reference so the bare names below find it.

The first three lines are shell variables, which are shortcuts that let the rest of the block name a long path in one word. They last only as long as the Terminal window you type them in, so if you close it and come back, type those three lines again before the commands that use them.

```bash
GATK=~/.lungfish/conda/envs/gatk-core/bin/gatk
SAMTOOLS=~/.lungfish/conda/envs/samtools/bin/samtools
BCFTOOLS=~/.lungfish/conda/envs/bcftools/bin/bcftools

# Step 1, index the reference so tools can seek inside it.
"$SAMTOOLS" faidx GRCh38.chr20.10.0-10.5Mb.fasta

# Step 2, build the sequence dictionary GATK checks every other file against.
"$GATK" CreateSequenceDictionary -R GRCh38.chr20.10.0-10.5Mb.fasta

# Step 3, make the known-sites file agree with the reference, then index it.
"$BCFTOOLS" reheader --fai GRCh38.chr20.10.0-10.5Mb.fasta.fai \
  -o known-sites.vcf.gz HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
"$BCFTOOLS" index --tbi -f known-sites.vcf.gz

# Step 4, preview only. Prints two commands and changes nothing on disk.
lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites known-sites.vcf.gz \
  --recal-table HG002.recal.table \
  --output HG002.bqsr.bam

# Step 5, the same command plus --execute. This one actually runs GATK.
lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites known-sites.vcf.gz \
  --recal-table HG002.recal.table \
  --output HG002.bqsr.bam \
  --execute

# Step 6, confirm the two outputs and the index exist.
ls -l HG002.recal.table HG002.bqsr.bam HG002.bqsr.bai
```

Steps 4 and 5 are the same command apart from the last line. Step 4 prints the two GATK command lines it would run and stops there, writing nothing, so you can read them before committing. Step 5 adds `--execute` and runs them, writing the table, the recalibrated BAM, its index, and the provenance sidecar. You can skip Step 4 once you trust the command, and reading the preview first is the habit worth keeping.

Step 4 prints two command lines rather than one, because `bqsr` is two GATK tools run in order. `BaseRecalibrator` reads the BAM and the known sites and writes the table, then `ApplyBQSR` reads the BAM and that table and writes the corrected BAM. Both carry `-R` pointing at the reference.

LGE adds `--create-output-bam-index true` to the second command for you, which is why Step 6 finds an index without your asking. Write `--create-output-bam-index false` on your own command only when you mean to index the result yourself afterwards.

Two options reach both printed commands rather than only one. `--intervals` restricts the recalibration and the apply step alike, as the interval list section showed. `--extra-args` appends whatever you put inside one pair of quotes to the end of both, so `--extra-args "--verbosity DEBUG"` adds that one option to each. Other `lungfish-cli gatk` commands place that option differently, so read Step 4's preview to see where it landed rather than assuming it behaves the same everywhere. [Joint Genotyping](02-joint-genotyping.md) covers the one case that differs.

Most readers can stop here. The rest of this section applies only if you are setting up a second machine that has no display and so cannot open the Plugin Manager, and if that is not you, the chapter is finished. On a machine with a screen, install the pack from the Plugin Manager as Before you start described.

Two commands move an installed pack to such a machine. Run the first on the machine that already has GATK Core installed, replacing `~/gatk-core-pack` with wherever you want the exported copy written. It accepts the experimental pack id that `conda install --pack` rejects, and writes an offline pack with a manifest and its own provenance. The export measured 865 MB on the machine used here, so give it room. Copy that whole directory to the target machine, then run the second command there, naming the directory as a plain argument with no option in front of it.

```bash
lungfish-cli conda export-pack --pack gatk-core --output ~/gatk-core-pack
lungfish-cli conda offline-install ~/gatk-core-pack
```

That route exists because the installer's experimental filter is a defect, so treat it as a workaround rather than the normal path.

## Next

With the reference files in place, [HaplotypeCaller](01-haplotype-caller.md) calls variants from a BAM, and [Joint Genotyping](02-joint-genotyping.md) combines several samples into one cohort table. Both need the same `.fai` and `.dict` this chapter built, and neither will start without them.
