---
title: Filtering, Selecting, and Metrics
chapter_id: 06-human-germline-variants/03-filtering-selecting-and-metrics
audience: power-user
prereqs: [06-human-germline-variants/02-joint-genotyping]
estimated_reading_min: 35
task: Flag the untrustworthy calls in a cohort VCF, pull out one sample or one variant class, normalize indels, export a table, and summarise the call set against a known-variant file.
tags: [gatk, variantfiltration, selectvariants, variantstotable, metrics, cli]
tools: [gatk]
parameters_refs: [variants.gatk-plans]
entry_points:
  - "CLI: lungfish-cli gatk filter --vcf <vcf> --output <vcf>"
  - "CLI: lungfish-cli gatk select --vcf <vcf> --output <vcf>"
  - "CLI: lungfish-cli gatk variants-to-table --vcf <vcf> --output <tsv>"
  - "CLI: lungfish-cli gatk leftalign --reference <fasta> --vcf <vcf> --output <vcf>"
  - "CLI: lungfish-cli gatk collect-metrics --vcf <vcf> --dbsnp <vcf> --output-prefix <path>"
shots: []
illustrations: []
glossary_refs: [bam, checksum, dbsnp, filter, hard-filter, indel, interval-list, left-alignment, multi-allelic, novel-variant, picard, provenance-sidecar, quality-by-depth, reference-genome, snv, strand-odds-ratio, transition-transversion-ratio, tsv, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Every operation in this chapter runs from the command line in a terminal. Lungfish Genome Explorer (LGE) has no dialog and no menu item for any of the five, so there is no window to open and nothing to click. If you have never used a terminal, read [CLI Reference](../appendices/cli-reference.md) first, which covers where the command line tool lives, how to open the Terminal application, and how to run a command. Everything below assumes it.

The previous chapter, [Joint Genotyping](02-joint-genotyping.md), ends with a cohort [VCF](../../GLOSSARY.md#vcf), a tab-separated table listing the positions where the samples differ from the [reference genome](../../GLOSSARY.md#reference-genome). A cohort VCF is simply the VCF that joint genotyping produced, named `cohort.vcf.gz` in the commands below. Most of what a VCF holds sits packed inside single columns rather than spread across many, which is why a later step exists to unpack it.

That file contains calls nobody has yet judged for quality. It holds every position the caller was willing to write down, including the rows whose supporting evidence is too weak to believe, and it says nothing about which rows are which. Here are the first two lines of the fixture's own file with the columns labelled.

```
CHROM              POS    ID  REF  ALT  QUAL     FILTER  INFO                              FORMAT        HG002
chr20_10.0-10.5Mb  2078   .   G    A    2175.06  .       AC=2;AF=1.00;AN=2;DP=62;QD=28.73  GT:AD:DP:GQ   1/1:0,60:60:99
```

The seventh column, [FILTER](../../GLOSSARY.md#filter), holds a single dot character (`.`) on every row of an unfiltered file, and a dot means no filter was applied rather than that the row passed one. The eighth column, INFO, is where the caller wrote the per-variant statistics that the filtering step reads. `DP=62` and `QD=28.73` in the row above are two of them.

This chapter covers the five steps that turn that raw table into something you can hand to a colleague. All five come from GATK, the Genome Analysis Toolkit, the standard software package for human variant work, and all five are subcommand names you type after `lungfish-cli gatk`. `filter` marks the suspect rows without deleting them. `select` pulls out one sample, one class of variant, or one region. `leftalign` rewrites [indels](../../GLOSSARY.md#indel), meaning insertions and deletions, at the leftmost position they can occupy, so two files can be compared. `variants-to-table` unpacks the VCF into a spreadsheet, splitting those packed columns into one column per statistic. And `collect-metrics` counts the finished set against a file of variants already known to science, which is how you find out whether the call set as a whole looks like a human genome or like an artefact, meaning a false signal produced by the laboratory or the machine rather than by the sample.

Four of the five do not change the number of rows, or shrink it in a way you asked for. The one that adds rows is `leftalign` when you ask it to split [multi-allelic](../../GLOSSARY.md#multi-allelic) sites, meaning positions where more than one alternative to the reference was seen. So the rule for the chapter is short. Run `filter` on every cohort VCF before you trust any row in it, and reach for the other four as the question in front of you requires.

## Why you would do this

The reason filtering comes first is that a variant caller, the program that reads an alignment and writes down every position where the sample looks different from the reference, reports every position with any supporting evidence at all. It leaves the judgement of whether that evidence is good enough to a later step in the analysis. If you skip that judgement, a few positions with unbalanced strand support or low read depth sit in your results looking exactly like the thousand positions without either problem.

A [hard filter](../../GLOSSARY.md#hard-filter) is the simplest way to make that judgement. It is a fixed list of arithmetic tests applied to the INFO-field statistics the caller already wrote into each row, with no training step and no model. GATK publishes a recommended list for human germline work, and LGE ships that list as its default. The tests are blunt, and GATK recommends Variant Quality Score Recalibration, usually written VQSR, for large projects, which learns a model from the data instead of applying fixed thresholds. On a single sample or a small cohort a hard filter catches the obvious problems and is easy to explain in a methods section.

The worked example below runs on the cohort VCF from the previous chapter, built from the HG002 chromosome 20 slice. A slice here is a 500 kb region cut out of chromosome 20 rather than the whole chromosome, small enough that every command below finishes in about a second. HG002 is a human reference sample from the Genome in a Bottle consortium, sequenced many times over by many groups, so the variation it carries is known independently. That gives this chapter a human example with an answer key, which is what makes the metrics step meaningful. On that file the filter marked 13 rows out of 1,026 as suspect, or 1.3 percent. Thirteen rows is not many, and finding out that it is only thirteen is itself the result. A run that flagged three hundred would tell you something had gone wrong earlier in the analysis, and you would not know either way without running the step.

## Before you start

The five operations in this chapter have no dialog, no menu item, and no entry anywhere in the LGE window, so none of them happens inside the app. Open the Terminal application, which lives in **Applications > Utilities > Terminal**, and keep it open for the whole chapter. Every command below assumes you are standing in the folder that holds the files, so put all the downloaded files and the cohort VCF in one folder and move the terminal there before you start. [CLI Reference](../appendices/cli-reference.md) covers how to do that.

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. The project is where you install the GATK Core pack from, and that is all this chapter uses it for. None of the five commands reads it or writes into it, and the files used below do not need to sit inside the project folder, because the CLI writes wherever you point it.

This chapter uses the HG002 chromosome 20 slice. Download the file `GRCh38.chr20.10.0-10.5Mb.fasta` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

On that GitHub page, click the file name to open it, then use the Download raw file button at the top right of the file view, and save it into your working folder. Step 4 below uses this file. Download `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` and its `.tbi` file from the same folder the same way. The `.tbi` is an index, a small companion file that lets a tool jump straight to a position instead of reading the whole compressed file from the start, and a tool that needs one and cannot find it stops with an error. The benchmark VCF is this chapter's known-variants file, standing in for a public catalogue, and the chapter calls it the known-variants file throughout.

You also need the cohort VCF that [Joint Genotyping](02-joint-genotyping.md) produces, named `cohort.vcf.gz` in the commands below, together with the `.tbi` index that appears beside it. Everything in this chapter starts from that file.

GATK comes from the GATK Core plugin pack and is not installed by default. This feature is experimental. Turn on **Show Experimental Features** in **Settings > Advanced** before you look for it. Settings is under the application menu, the one named **Lungfish Genome Explorer** at the left of the Mac menu bar. Experimental here means the pack has had less testing inside LGE than the ones earlier chapters use, not that GATK itself is unfinished, so results are fine to report as long as you record the tool version alongside them. With that toggle on, open **Tools > Plugin Manager...** (Cmd-Shift-B), go to the Packs tab, and install the GATK Core card.

The Plugin Manager is the only route that works. `lungfish-cli conda install --pack gatk-core` answers `Unknown tool pack: gatk-core` and installs nothing, which is a known bug in the command-line installer alone. It does not affect any of the runs below.

Two companion files have to sit beside the reference before Step 4 will work, and LGE builds neither of them for you. The first is the `.fai` index, which the fixture ships. The second is the `.dict` sequence dictionary, a small text file listing each named sequence in the reference with its length. Build it once with GATK's own `CreateSequenceDictionary`.

```bash
~/.lungfish/conda/envs/gatk-core/bin/gatk CreateSequenceDictionary \
  -R GRCh38.chr20.10.0-10.5Mb.fasta
```

Step 4 also needs a known-variants file whose header describes exactly the contigs your calls use, at exactly the lengths the reference gives. A contig is one named sequence in a reference, such as a chromosome. The downloaded benchmark VCF was written against whole chromosome 20 and its header still declares that chromosome's full length, so rewrite the header from the reference index and rebuild the index afterwards.

```bash
~/.lungfish/conda/envs/bcftools/bin/bcftools reheader \
  --fai GRCh38.chr20.10.0-10.5Mb.fasta.fai \
  -o known-sites.vcf.gz HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
~/.lungfish/conda/envs/bcftools/bin/bcftools index --tbi -f known-sites.vcf.gz
```

Both commands and the reasoning behind them are explained in [Reference Files for GATK](04-reference-packs.md), which covers the companion files GATK expects and how to build each one.

The six recorded runs below, meaning the filter, the two `select` runs, `leftalign`, `variants-to-table`, and `collect-metrics`, each finished in about 1.2 seconds on the 500 kb slice. A whole human genome takes minutes rather than seconds for these steps, a figure inherited from GATK's own published guidance rather than measured here. Either way they are far cheaper than the calling that preceded them.

## Procedure

The command line tool is `lungfish-cli`. A flag is a word beginning with two dashes that you add to a command to change what it does, and every setting in this chapter is a flag. In the commands below, a backslash at the end of a line continues one command onto the next line, so select a whole block and paste it into the terminal as a single piece. You never need to type the line breaks or the indentation by hand.

Every subcommand composes its GATK command, prints it, and exits without running anything or writing any file. That is a safe preview rather than a failure. Adding `--execute` is what makes it run.

**Step 1.** Preview the filter without running anything.

```bash
lungfish-cli gatk filter \
    --vcf cohort.vcf.gz \
    --preset best-practices-both \
    --output cohort.filtered.vcf.gz
```

`best-practices-both` is already the default and is written out here only so you can see it. Be careful typing it, because an unrecognised `--preset` value falls back to `best-practices-both` rather than failing. A recorded run with `--preset bestpractices-snp`, missing one hyphen, quietly applied both filter lists instead of the SNP list alone, with no warning anywhere in the output. Reading the preview is the only way to catch that.

The recorded run printed the command below. The directory part of each path is shortened to three dots, which is this manual's own shorthand for your folder rather than something that will appear in your output.

```
gatk VariantFiltration -V .../cohort.vcf.gz -O .../cohort.filtered.vcf.gz \
  --filter-expression 'QD < 2.0'               --filter-name QD2 \
  --filter-expression 'FS > 60.0'              --filter-name FS60 \
  --filter-expression 'MQ < 40.0'              --filter-name MQ40 \
  --filter-expression 'MQRankSum < -12.5'      --filter-name MQRankSum-12.5 \
  --filter-expression 'ReadPosRankSum < -8.0'  --filter-name ReadPosRankSum-8 \
  --filter-expression 'SOR > 3.0'              --filter-name SOR3 \
  --filter-expression 'QD < 2.0'               --filter-name QD2 \
  --filter-expression 'FS > 200.0'             --filter-name FS200 \
  --filter-expression 'ReadPosRankSum < -20.0' --filter-name ReadPosRankSum-20 \
  --filter-expression 'SOR > 10.0'             --filter-name SOR10
```

The first six tests apply to substitutions and the last four to indels. Each reads one INFO-field statistic from the row and marks the row when the arithmetic is true.

| Test | Reads | Marks a row when | Meaning |
|---|---|---|---|
| `QD2` | `QD` | `QD < 2.0` | Quality divided by read depth is low, so the call is weak per read |
| `FS60`, `FS200` | `FS` | `FS > 60.0` (SNP), `FS > 200.0` (indel) | Reads supporting the variant came from one strand far more than the other |
| `MQ40` | `MQ` | `MQ < 40.0` | The reads at this position mapped poorly, so their placement is uncertain |
| `MQRankSum-12.5` | `MQRankSum` | `MQRankSum < -12.5` | Reads carrying the variant mapped worse than reads carrying the reference |
| `SOR3`, `SOR10` | `SOR` | `SOR > 3.0` (SNP), `SOR > 10.0` (indel) | A second measure of strand imbalance, less sensitive than `FS` to high depth |

The tenth test, `ReadPosRankSum-8` for substitutions and `ReadPosRankSum-20` for indels, reads `ReadPosRankSum` and marks a row when the variant sits nearer the ends of its supporting reads than the reference allele does, since read ends are where errors gather.

Notice that `QD2` appears twice. The default preset is the SNP list followed by the indel list, and both lists open with the same quality-by-depth test, so the duplicate is expected rather than a mistake. It has no effect on the answer, because a row failing that test is labelled `QD2` once whichever copy caught it.

**Step 2.** Run the filter for real by adding `--execute`.

```bash
lungfish-cli gatk filter \
    --vcf cohort.vcf.gz \
    --preset best-practices-both \
    --output cohort.filtered.vcf.gz \
    --execute
```

It prints two lines when it finishes. Exit code 0 means the run succeeded, and any other number means it did not.

```
GATK execution completed with exit code 0.
Provenance: .../.lungfish-provenance.json
```

Provenance is a record of exactly what was run, and [The provenance record](#the-provenance-record) below covers what it holds. One thing about it matters before the next step. LGE always writes that record into the folder holding the command's output, always under that same name, so a second `--execute` into the same folder overwrites the first one's record with no warning. Steps 2 and 3 both write into your working folder, so the filter's record is gone once Step 3 runs. Copy the file after each run if you need to keep every step's provenance.

**Step 3.** Split the filtered cohort by variant class, one command per class. Each writes its own file and leaves the input alone. `--sample HG002` names the sample whose column you want, and a sample name is a column heading in the VCF, the tenth column onward. Run `~/.lungfish/conda/envs/bcftools/bin/bcftools query -l cohort.filtered.vcf.gz` to list the names in your own file. This fixture holds one sample, so `--sample HG002` here selects the only column there is and drops nothing. On a real multi-sample cohort it drops every other sample from the output.

```bash
lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz \
    --sample HG002 \
    --type SNP \
    --output HG002.snps.vcf.gz \
    --execute

lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz \
    --sample HG002 \
    --type INDEL \
    --output HG002.indels.vcf.gz \
    --execute
```

Be as careful with `--type` as with `--preset`, and for the same reason. An unrecognised value is dropped rather than rejected, so a recorded run with `--type SUBSTITUTION` printed a `SelectVariants` command carrying no `-select-type` at all, which would have selected every row in the file. The preview is where you catch it, by checking that `-select-type SNP` is actually present.

**Step 4.** Rewrite the indels at their leftmost position and split the multi-allelic rows. This is the step that uses the reference FASTA you downloaded.

```bash
lungfish-cli gatk leftalign \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.leftaligned.vcf.gz \
    --split-multi-allelics \
    --execute
```

**Step 5.** Export the calls as a table any spreadsheet can open.

```bash
lungfish-cli gatk variants-to-table \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.table.tsv \
    --execute
```

**Step 6.** Summarise the filtered set against the known-variants file. The `--output-prefix` value is a path stem, meaning the start of a file name that the tool completes for you, rather than a whole file name. [Picard](../../GLOSSARY.md#picard), the toolkit GATK bundles for this kind of counting, appends its own suffixes to it. `mkdir -p` is a terminal command rather than an LGE one, typed in the same terminal, and it creates the folder because `collect-metrics` will not.

```bash
mkdir -p metrics

lungfish-cli gatk collect-metrics \
    --vcf cohort.filtered.vcf.gz \
    --dbsnp known-sites.vcf.gz \
    --sequence-dictionary GRCh38.chr20.10.0-10.5Mb.dict \
    --output-prefix metrics/cohort \
    --execute
```

The `known-sites.vcf.gz` named here is the reheadered file you built in Before you start, not the file you downloaded. Passing the downloaded benchmark directly fails, and [When the metrics step fails](#when-the-metrics-step-fails) shows the two error messages and why.

**Step 7.** Read the two metrics files and the filtered VCF. All of them are plain text, so they open in any text editor, and the two metrics files and the exported table also open in a spreadsheet. The next section explains what is in them.

## Settings

None of these five operations has a dialog, so none of them has a dialog setting. Every setting is a command-line flag, so each entry below ends by naming the flag rather than pointing at a control. Three flags are shared by every GATK subcommand and are described at the end. Nothing from another chapter is needed to finish this one. The flags belonging to `joint-genotype` are documented in [Joint Genotyping](02-joint-genotyping.md) and the ones belonging to `bqsr` in [Reference Files for GATK](04-reference-packs.md), and both are separate operations rather than parts of this procedure.

**Filter.** Builds a `VariantFiltration` command that adds a label to the FILTER column of every row failing one of its tests, leaving the row itself in place. There is no default, since naming the subcommand is how you ask for it. Run it once on every cohort VCF, before you read a single row as a result. On the command line this is `lungfish-cli gatk filter`.

**Preset.** Chooses which published list of [hard filter](../../GLOSSARY.md#hard-filter) tests the filter applies. The allowed values are `best-practices-snp`, `best-practices-indel`, and `best-practices-both`, which is the default and applies both lists one after the other. Set it to one of the single-class values when you have already split the cohort with `select` and are filtering substitutions ([SNVs](../../GLOSSARY.md#snv)) and length changes ([indels](../../GLOSSARY.md#indel)) apart, which is the more careful way to work because a test tuned for substitutions is not the right test for a length change. On the command line this is `--preset`.

This chapter filters first and splits afterwards, which is the opposite order, and that is fine here because `best-practices-both` applies the SNP tests and the indel tests separately and GATK matches each test to the rows it belongs to. Splitting first only matters when you want to depart from the published thresholds for one class.

A fourth value, `custom`, is an unfinished feature rather than a working option. It applies no filter expressions at all, so the command copies the file and marks nothing. A recorded run with `--preset custom` printed `gatk VariantFiltration -V cohort.vcf.gz -O x.vcf.gz` and nothing more. Avoid it from the command line, since there is no companion flag for supplying your own tests.

**Select.** Builds a `SelectVariants` command that writes out the subset of rows you describe, discarding the rest. There is no default. Run it when a later step wants one sample, one class of variant, or one region rather than the whole cohort. On the command line this is `lungfish-cli gatk select`.

**Sample.** Restricts the output to the named sample's column, dropping every other sample from the file. The default is empty, so all samples are kept, which is the right behaviour for a cohort file whose whole purpose is holding several samples. Set it when you are handing one person's calls to a tool or a collaborator who should not receive the rest. On the command line this is `--sample`.

**Type.** Restricts the output to one class of variant. The allowed values are `SNP` for single-base substitutions, `INDEL` for insertions and deletions, and `MIXED` for a position where the alternative alleles include both at once, and the default is empty so every class is kept. Position 29,224 of the fixture is a worked example. Its reference base is `A` and its two alternatives are `G`, a substitution, and `AGG`, a two-base insertion, so GATK files the whole row as `MIXED`. Set the flag when a later step handles the two classes differently, which most do, since the evidence that a substitution is real is not the evidence that a length change is real. On the command line this is `--type`.

**Intervals.** Restricts the output to the stretches of the reference named in an [interval list](../../GLOSSARY.md#interval-list), which can be a BED file, a Picard-style interval list, or a bare contig name. A BED file is a plain text file with one region per line, holding the contig name, the start position, and the end position separated by tabs, and the start is counted from zero. The default is empty, so the whole file is considered. Set it when you only care about a defined region, such as a gene panel. On the command line this is `--intervals`, and `leftalign` accepts the same flag with the same meaning.

**Variants to table.** Builds a `VariantsToTable` command that writes the chosen VCF columns into a plain [TSV](../../GLOSSARY.md#tsv), a tab-separated text file that opens in any spreadsheet. There is no default. Run it when the calls need to leave the genomics tools and be read, sorted, or plotted by something else. On the command line this is `lungfish-cli gatk variants-to-table`.

**Fields.** Lists which VCF fields become columns of the table, written as one comma-separated string. The default is `CHROM,POS,REF,ALT,QUAL,AF,DP`, giving you the contig, the position, the reference and alternate alleles, the quality score, the allele frequency, and the depth. Allele frequency is the fraction of the sample's own chromosome copies that carry the variant, so `AF=1.00` in the example row means both copies carry it and `AF=0.500` means one of two does, and depth is how many reads cover the position. Change it when you want a statistic the default leaves out, and note that spaces after commas are ignored. On the command line this is `--fields`.

**Reference.** Names the reference FASTA that `leftalign` compares each indel against, since shifting an indel leftward means checking the reference bases it would move across. There is no default and the flag is required for `leftalign`, which is the only subcommand in this chapter that takes it. Point it at the same FASTA the calls were made against, with its `.fai` index beside it. On the command line this is `--reference`.

**Left align.** Builds a `LeftAlignAndTrimVariants` command. The same biological insertion inside a repeated stretch of sequence can be written at several different positions, all of them equally correct, so two callers can describe one event two ways and a comparison finds a difference that is not there. This command rewrites each indel at the leftmost position it can occupy and trims any bases shared between the reference and alternate alleles, which makes the [left-aligned](../../GLOSSARY.md#left-alignment) form the same in both files. There is no default. Run it before comparing or merging two VCFs from different callers. On the command line this is `lungfish-cli gatk leftalign`.

**Split multi-allelics.** Splits a row carrying more than one alternate allele into one row per allele. The default is off, which keeps the file compact and keeps GATK's own per-allele statistics attached to a single row. Splitting loses that pairing, because each new row carries a copy of the site's statistics with no record that the two rows came from one position. Turn it on when a later tool reads only the first alternate allele of each row, which many older tools do, and be ready for the row count to rise. On the command line this is `--split-multi-allelics`, and LGE writes this argument into the GATK command with an explicit `true` or `false` every time, so you will see it in the preview even when you leave the flag off.

**Max indel length.** Sets the longest indel the tool will attempt to realign, in bases. The default is 200. Most human indels are under 10 bases and the overwhelming majority are under 50, so 200 covers almost everything ordinary sequencing produces. Raise it if you call long insertions or deletions and want them normalized too, because an indel above the limit is passed through in whatever position the caller wrote it. On the command line this is `--max-indel-length`.

**Max leading bases.** Sets how far to the left the tool will shift an indel while looking for its canonical position, in bases. The default is 1000, which is far enough to walk out of most repeats. Raise it when your indels sit inside long repeated stretches. Both this number and the one above matter for clinical work, because an indel that falls outside either window is left exactly as the caller wrote it and nothing in the output says so, which makes it look normalized when it is not. On the command line this is `--max-leading-bases`.

**Collect metrics.** Builds a Picard `CollectVariantCallingMetrics` command that counts the finished call set and compares it against a file of already-known variants. There is no default. Run it as the last step on any call set you are about to report, because its numbers are the fastest check that the set as a whole looks like real human variation. On the command line this is `lungfish-cli gatk collect-metrics`.

**Output prefix.** Names the path stem the two metrics files are built from. There is no default and the flag is required. Point it at a folder you have already created, and expect two files rather than one, since Picard appends `.variant_calling_summary_metrics` and `.variant_calling_detail_metrics` to whatever stem you give. On the command line this is `--output-prefix`.

**dbSNP.** Names the VCF of already-known variants that every call is checked against. There is no default and the flag is required, because the split between known and [novel](../../GLOSSARY.md#novel-variant) is the whole point of the step. The flag accepts any known-variants VCF, and this chapter passes the HG002 benchmark because the fixture ships one, but real work uses a release of [dbSNP](../../GLOSSARY.md#dbsnp), the public catalogue of human variation. Whichever file you use has to describe the same contigs as your calls or the step fails. On the command line this is `--dbsnp`.

**Sequence dictionary.** Names the `.dict` file describing the reference's contigs and their lengths. The default is empty and the flag is optional, so Picard falls back on the dictionary embedded in the VCF headers. Pass it when your VCF header does not list the contigs, or when you want the check made against the reference itself. On the command line this is `--sequence-dictionary`.

**GVCF input.** Tells Picard the input is a GVCF, a VCF that also records the positions where the sample matches the reference rather than only the positions where it differs. The default is off, which is right for the cohort VCF this chapter starts from. Turn it on only when you are pointing the step at a GVCF, since the counting logic differs. On the command line this is `--gvcf-input`.

**Execute.** Runs the composed GATK command through the GATK Core pack instead of only printing it. The default is false, so a command with neither this flag nor `--dry-run` prints one command line and stops without running anything or writing any file. Add it once you have read the preview. On the command line this is `--execute`, and every subcommand in this chapter accepts it.

**Dry run.** Cancels `--execute` when both are given, printing the composed command and running nothing. That override is its only use, since not executing is already the default and the flag on its own changes nothing. A recorded run with both flags printed the command and wrote no file. On the command line this is `--dry-run`, and every subcommand in this chapter accepts it.

**Extra args.** Appends further arguments to the end of the composed GATK command. The default is empty. Use it for GATK options LGE does not expose as flags of its own, and put the whole set inside one pair of quotes, which means several GATK options fit in a single `--extra-args` value. On the command line this is `--extra-args`, and every subcommand in this chapter accepts it.

## Reading the results

The filter changes no row count at all. The recorded run went in with 1,026 rows and came out with 1,026, because `VariantFiltration` marks rather than removes. What changed is the FILTER column.

One row failed two tests at once and so appears in two rows of the table below. It is position 496,668, which carries `QD2;SOR3`, because a VCF records more than one failure as a semicolon-separated list.

| FILTER value | Rows |
|---|---|
| `PASS` | 1,013 |
| `SOR3` | 12, one of them also `QD2` |
| `QD2` | 2, one of them also `SOR3` |

So 12 plus 2 is 14 labels, minus the 1 row counted twice, leaving 13 distinct rows marked out of 1,026, or 1.3 percent. The other eight tests marked no rows at all on this file.

Reading a label tells you which test caught the row. [QD](../../GLOSSARY.md#quality-by-depth), quality by depth, is the row's quality score divided by the depth of reads supporting the variant, so it measures confidence per read rather than in total. A deep position accumulates a high total quality even when each individual read is unconvincing, and dividing by depth removes that advantage. The two `QD2` rows had QUAL values of 32.64 and 32.60, which is the caller's own confidence in the whole call rather than a QD figure, and both sit just above HaplotypeCaller's emission threshold of 30 on the Phred scale, described in [HaplotypeCaller](01-haplotype-caller.md). [SOR](../../GLOSSARY.md#strand-odds-ratio), the strand odds ratio, measures whether the reads supporting the variant came disproportionately from one strand of the DNA. A real variant should be seen about equally from both, so a lopsided count points at an artefact of library preparation or of the sequencing chemistry rather than a real difference in the sample.

The output also carries a `##FILTER` header line for each distinct test name, nine in all, because the duplicated `QD2` is declared once. A tenth line, `LowQual`, came from the caller rather than from this step. Each line writes its arithmetic out in its description, which is what makes a filtered VCF self-documenting. A reader who receives the file six months later can find out that `SOR3` meant `SOR > 3.0` without asking you.

`select` splits the file by class. The recorded runs pulled 842 SNP rows and 182 indel rows out of the 1,026, and a third run with `--type MIXED` pulled the remaining 2. The three add up exactly, because GATK puts every row in exactly one class.

Those are GATK's own class names, and they differ by two from the counts the earlier chapters in this part give for the same file. The manual counts a row's type from its first alternate allele, under which this file holds 844 substitutions and 182 length changes. GATK instead files a row whose alternatives include both a substitution and an insertion as `MIXED`, and there are exactly two such rows. So GATK's 842 plus 2 and the manual's 844 describe the same file counted two ways, and both totals reach 1,026.

Both selections kept the FILTER labels the earlier step wrote, so the SNP file holds 836 `PASS` rows and the indel file 175. Those two add to 1,011 rather than 1,013 because the two `MIXED` rows are the remaining `PASS` rows, and they are in neither file.

`leftalign` with `--split-multi-allelics` was the one step that changed the row count, from 1,026 to 1,045. The input held 19 multi-allelic rows, each carrying two alternate alleles, and each became two rows, so the split added exactly 19 rows and 1,026 plus 19 is 1,045. None remained multi-allelic afterwards. Position 29,224 shows the effect plainly. Before splitting it read `A` to `G,AGG` on one row, and after it read `A` to `G` on one row and `A` to `AGG` on the next.

`variants-to-table` drops filtered rows by default, so it produced 1,013 data rows from a 1,026-row input, which is exactly the `PASS` set with none of the 13 marked rows. If you want them, add `--extra-args "--show-filtered"`, which a recorded run confirmed by producing all 1,026. The table is also the easiest way to look up one position, since it opens in a spreadsheet you can search. The default seven columns look like this, with the first data row from the recorded run. The contig name is `chr20_10.0-10.5Mb` rather than `chr20` because the fixture renamed it when the slice was cut, which is expected.

```
CHROM	POS	REF	ALT	QUAL	AF	DP
chr20_10.0-10.5Mb	2078	G	A	2175.06	1.00	62
```

### The metrics files

`collect-metrics` writes two files, both plain text with a few comment lines at the top and then a header row and a data row. `cohort.variant_calling_summary_metrics` holds one row for the whole call set, and `cohort.variant_calling_detail_metrics` holds one row per sample. On a single-sample cohort the two carry the same numbers, and the detail file adds two per-sample fields the summary leaves out, `SAMPLE_ALIAS` and `HET_HOMVAR_RATIO`.

Here are the headline figures from the recorded run against the known-variants file.

| Metric | Value | What it means |
|---|---|---|
| `TOTAL_SNPS` | 835 | Substitutions counted, `PASS` rows only |
| `NUM_IN_DB_SNP` | 799 | Of those, already in the known-variants file |
| `NOVEL_SNPS` | 36 | Of those, not in it |
| `PCT_DBSNP` | 0.9569, or 95.7 percent | The known fraction. High is good |
| `DBSNP_TITV` | 2.248 | Transition to transversion ratio among the known ones. Expect 2 to 3 |
| `NOVEL_TITV` | 1.769 | The same ratio among the novel ones. Usually lower |
| `TOTAL_INDELS` | 159 | Insertions and deletions counted, `PASS` rows only |
| `FILTERED_SNPS` | 6 | Substitutions the filter marked |
| `FILTERED_INDELS` | 7 | Length changes the filter marked |
| `HET_HOMVAR_RATIO` | 1.459 | Heterozygous calls divided by homozygous-variant calls, detail file only |

Three of these deserve unpacking. The known fraction is the share of your calls that somebody has seen before. High is good, because a well-studied human sample should mostly carry variation already catalogued, and a set where most calls are novel is usually a set full of errors rather than a set full of discoveries. The [transition to transversion ratio](../../GLOSSARY.md#transition-transversion-ratio) compares the two chemical kinds of substitution. A transition swaps a base for the other one of the same chemical family, meaning purine for purine (A for G) or pyrimidine for pyrimidine (C for T), and a transversion swaps between families. Transitions happen more readily in real biology, so genuine human variation runs at roughly 2 to 3, while random sequencing error has no such preference and runs near 0.5. The recorded run's 2.248 among the known variants is squarely in the expected range, and the 1.769 among the novel ones is lower, which is what a small novel set carrying a higher share of error looks like. `HET_HOMVAR_RATIO` counts how many calls have one variant copy against how many have two, and as general guidance rather than a measured figure it runs near 1.5 to 2 for a human sample, so 1.459 is unremarkable. It is worth watching mainly as a change between runs of similar samples rather than judged against a fixed target.

The counts in this table are not the counts from `select`, and the difference is real rather than an error. `select` reported 842 substitutions and 182 length changes across every row in the file. The metrics table counts only `PASS` rows, and it counts them by Picard's own typing rather than GATK's, which is why 835 and 159 are both smaller. Three numbers for substitutions appear in this chapter, and each counts something different. 842 is every SNP row, 836 is the `PASS` SNP rows, and 835 is what Picard counted as a substitution among the `PASS` rows.

`FILTERED_SNPS` plus `FILTERED_INDELS` is 13, matching the 13 rows the filter marked. This is the same 13 rows the FILTER table broke down earlier, split by variant class here and by which test caught them there. That two independently computed numbers agree is a useful internal check.

### When the metrics step fails

Picard insists that the known-variants file and the input describe exactly the same contigs, in the same order, at the same lengths. Nothing else in this chapter is that strict. Two recorded runs failed on it before one succeeded, and both failures are worth recognising because the message names the cause plainly.

The first failure printed `Error: GATK command failed with exit code 3.` on the terminal, and the provenance record held Picard's own explanation, `Sequence dictionary for (DBSNP) does not match sequence dictionary for (INPUT)`, with the underlying reason `Sequence dictionaries are not the same size (195, 1)`. The first number is the known-variants file's contig count and the second is the cohort VCF's. The benchmark VCF was written against the whole human genome and lists all 195 contigs in its header, while the cohort VCF describes only the one 500 kb slice.

The second failure got past that and reported `Sequences at index 0 don't match`, because the rebuilt header claimed a length of 500,000 where the reference is 500,001 bases long. The file name says 10.0 to 10.5 Mb, which reads like exactly 500,000, but the slice was cut inclusive of both end positions, so it holds one more base than the difference between them. The reference index is the authority. Its second column gives the true length, and `cat GRCh38.chr20.10.0-10.5Mb.fasta.fai` on the fixture prints `500001`.

The fix in both cases belongs to the known-variants file rather than to LGE, and it is the `bcftools reheader` command given in Before you start, which rewrites the header directly from that index and so cannot get the length wrong. In real work against a whole reference genome the question does not come up, because a dbSNP release and a whole-genome call set already agree.

### The provenance record

Every `--execute` run writes a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) named `.lungfish-provenance.json`, a record in JSON, a plain text format that stores labelled values and opens in any text editor. Its name begins with a dot, which macOS treats as hidden, so it will not appear in a Finder window until you press Cmd-Shift-Period to show hidden files.

The record holds the full command, the exit code, the wall time, the pinned tool version `4.6.2.0`, the path of the conda environment GATK ran from, every resolved option including the preset that was chosen, and a SHA-256 [checksum](../../GLOSSARY.md#checksum) and byte size for each input and output file. A conda environment is a self-contained folder holding one program and everything it needs, which is how LGE keeps each tool at a pinned version. A checksum is a short string computed from a file's contents, so it acts as a fingerprint that proves later which file a run actually used, and SHA-256 is the recipe used to compute it. Cite the sidecar when you write up a method rather than retyping the command from memory.

The overwrite behaviour introduced at Step 2 is worth restating, because it is a real loss of information rather than an inconvenience. After the recorded `select` runs, the file in that folder described `GATK SelectVariants` and the earlier `VariantFiltration` record was gone. If you need to keep the provenance of each step, either copy the file after each run or send each step's output to its own folder, which is what the metrics step does here by writing into `metrics/`.

A failed run leaves a usable record and no partial output. A recorded run pointed at a VCF that did not exist printed `Error: GATK command failed with exit code 2.` followed by the path of the provenance file, and left nothing else in the folder, because LGE removes the files it created before it gives up. The record it wrote carries the status `failed` and the failing step's exit code.

## What good looks like

Check these before you trust a filtered call set.

The row count should not change across the filter. The recorded run went from 1,026 to 1,026. A shorter output means something removed rows, which `VariantFiltration` does not do, so look at what else ran.

The marked share should be small. On the recorded run 13 rows out of 1,026 were marked, or 1.3 percent. A double-digit percentage points at a problem in the mapping or the calling that ran earlier rather than at a filter working as intended.

The known fraction should be high. The recorded run reported 95.7 percent of substitutions already present in the known-variants file. A set where most calls are novel is usually a set full of errors.

The transition to transversion ratio should sit between 2 and 3 for a human sample. The recorded run reported 2.248 among the known variants. A value near 0.5 means the calls are indistinguishable from random error.

Read the preview before every filter and select run. A mistyped `--preset` value falls back to `best-practices-both` without saying so, a mistyped `--type` value is dropped entirely, and the composed command is the only place either mistake shows.

## On the command line

This is a recap of the whole chapter as one block, from the cohort VCF to a filtered set, two class-specific files, a normalized file, a table, and a pair of metrics files. Every command below already appears in the Procedure.

```bash
# Mark the rows that fail GATK's recommended tests. Nothing is deleted.
lungfish-cli gatk filter \
    --vcf cohort.vcf.gz \
    --preset best-practices-both \
    --output cohort.filtered.vcf.gz \
    --execute

# Split the filtered cohort by variant class, one sample at a time.
lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz \
    --sample HG002 \
    --type SNP \
    --output HG002.snps.vcf.gz \
    --execute

lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz \
    --sample HG002 \
    --type INDEL \
    --output HG002.indels.vcf.gz \
    --execute

# Rewrite indels in their canonical position and split multi-allelic rows.
lungfish-cli gatk leftalign \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.leftaligned.vcf.gz \
    --split-multi-allelics \
    --execute

# Export the PASS rows as a spreadsheet-friendly table.
lungfish-cli gatk variants-to-table \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.table.tsv \
    --execute

# Count the finished set against the reheadered known-variants file.
mkdir -p metrics

lungfish-cli gatk collect-metrics \
    --vcf cohort.filtered.vcf.gz \
    --dbsnp known-sites.vcf.gz \
    --sequence-dictionary GRCh38.chr20.10.0-10.5Mb.dict \
    --output-prefix metrics/cohort \
    --execute
```

To keep the marked rows in the exported table rather than only the `PASS` ones, pass GATK's own option through.

```bash
lungfish-cli gatk variants-to-table \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.all.tsv \
    --extra-args "--show-filtered" \
    --execute
```

To restrict any of these steps to one region, point `--intervals` at a BED file. The one used in the recorded run holds a single tab-separated line naming the contig, the start counted from zero, and the end.

```
chr20_10.0-10.5Mb	0	100000
```

That run restricted `select` to the first 100 kb of the slice and returned 258 rows ending at position 99,174.

```bash
lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz \
    --output first100kb.vcf.gz \
    --intervals first100kb.bed \
    --execute
```

### Two more GATK subcommands for BAM files

Two further GATK subcommands prepare [BAM](../../GLOSSARY.md#bam) files, the compressed binary form of an alignment, rather than VCFs. Neither has a chapter of its own and neither is part of this chapter's pipeline.

`lungfish-cli gatk markdup` builds a Picard `MarkDuplicates` command, which labels reads that are copies of one original fragment so a later step does not count the same evidence twice. Its flags are `--bam`, given once per lane, plus `--output`, `--metrics`, `--create-index` (default true), `--remove-duplicates`, and `--validation-stringency`.

Two different subcommands share the name `markdup`. This one wraps Picard. The top-level `lungfish-cli markdup`, with no `gatk` in front of it, wraps `samtools` instead and is covered in [Alignment Quality](../04-alignments/04-alignment-quality.md). Check which one a command names before you run it, because they take different flags.

`lungfish-cli gatk validate-sam` builds a Picard `ValidateSamFile` command that checks a BAM for format problems. Its flags are `--bam`, `--output`, `--reference`, `--mode` (`SUMMARY` or `VERBOSE`, default `SUMMARY`), `--validate-index` (default true), and `--ignore-warnings` (default false).

## Next

The GATK toolchain in this part depends on one experimental plugin pack and on a small set of companion files that LGE never builds for you. [Reference Files for GATK](04-reference-packs.md) covers installing the pack, what it pins, and base quality score recalibration, a step that corrects the per-base quality scores in an alignment before calling rather than filtering the calls afterwards.
