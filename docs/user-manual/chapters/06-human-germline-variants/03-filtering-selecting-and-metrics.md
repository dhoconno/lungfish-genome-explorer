---
title: Filtering, Selecting, and Metrics
chapter_id: 06-human-germline-variants/03-filtering-selecting-and-metrics
audience: power-user
prereqs: [06-human-germline-variants/02-joint-genotyping]
estimated_reading_min: 12
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
glossary_refs: [allele-frequency, benchmark-vcf, checksum, dbsnp, filter, hard-filter, indel, interval-list, known-sites, left-alignment, multi-allelic, novel-variant, phred-score, picard, provenance, provenance-sidecar, quality-by-depth, reference-genome, snv, strand-odds-ratio, transition-transversion-ratio, tsv, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20, giab-trio-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

[Joint Genotyping](02-joint-genotyping.md) ends with a cohort [VCF](../../GLOSSARY.md#vcf), a tab-separated file with one row per position where anyone in the cohort differs from the [reference genome](../../GLOSSARY.md#reference-genome). Nobody has yet judged its calls for quality. It holds every position the caller was willing to write down, including rows whose evidence is too weak to believe. The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains, and every row of the cohort VCF reads `.`.

This chapter covers five GATK steps that turn that raw table into something you can hand to a colleague. Each is a subcommand of `lungfish-cli gatk`, and none has a window in Lungfish Genome Explorer (LGE).

| Subcommand | GATK tool | What it does |
|---|---|---|
| `filter` | `VariantFiltration` | Marks suspect rows in the FILTER column without deleting them |
| `select` | `SelectVariants` | Pulls out one sample, one class of variant, or one region |
| `leftalign` | `LeftAlignAndTrimVariants` | Rewrites each [indel](../../GLOSSARY.md#indel), an insertion or deletion, at the leftmost position it can occupy, so two files compare cleanly |
| `variants-to-table` | `VariantsToTable` | Unpacks the VCF into a [TSV](../../GLOSSARY.md#tsv), a tab-separated table any spreadsheet opens |
| `collect-metrics` | Picard `CollectVariantCallingMetrics` | Counts the finished set against a file of already known variants |

Run `filter` on every cohort VCF before you trust any row in it, and reach for the other four as your question requires.

## Why you would do this

A variant caller reports every position with any supporting evidence and leaves the judgement to a later step. Skip that step and a few positions with lopsided strand support or thin evidence sit in your results looking like the thousand without either problem.

A [hard filter](../../GLOSSARY.md#hard-filter) is the simplest judgement, a fixed list of arithmetic tests on the statistics the caller already wrote into each row's INFO column, with no model to train. GATK publishes a recommended list for human germline work, and LGE ships it as the default. For large projects GATK recommends Variant Quality Score Recalibration (VQSR), which learns thresholds from the data. On a single sample or a small cohort a hard filter catches the obvious problems and is easy to explain in a methods section.

The word filter names three different things in this manual, and this chapter's is the first of them, a flag written into the FILTER column that keeps the row, as [Three kinds of filter](../01-foundations/05-variants-and-vcf.md#three-kinds-of-filter) sets out. The Call Variants dialog's Minimum Allele Frequency threshold, which removes rows, and the Variants table's chips, which hide them on screen, are the other two.

The example in this chapter runs on the trio's cohort VCF from Joint Genotyping. On that file the filter marked 13 rows out of 1,433, under 1 percent. Learning that it is only thirteen is itself the result, and you would not know without running the step.

## Before you start

Work through [Joint Genotyping](02-joint-genotyping.md) first, which leaves `cohort.vcf.gz` and its `.tbi` index in the `LGE GATK` working folder. Run every command in this chapter from that folder, with the shell variables from [Reference Files for GATK](04-reference-packs.md#before-you-start) set. The folder also holds the reference, its `.fai` index and `.dict` dictionary, and `known-sites.vcf.gz`, the rebuilt HG002 benchmark, all made in [Reference Files for GATK](04-reference-packs.md#known-sites). Each step below finished in a few seconds on this slice.

## Procedure

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every subcommand prints the GATK command it composed and stops. Adding `--execute` runs it.

### Filter the cohort with VariantFiltration

Preview the filter first.

```bash
lungfish-cli gatk filter \
    --vcf cohort.vcf.gz \
    --output cohort.filtered.vcf.gz
```

The preview shows the default preset's ten tests, GATK's six published tests for substitutions followed by its four for indels, each a `--filter-expression` paired with a `--filter-name`. All ten go into one command, so every row is tested against both lists, and an indel can be marked by a substitution threshold such as `SOR3`.

| Test | Reads | Marks a row when | Meaning |
|---|---|---|---|
| `QD2` | `QD` | `QD < 2.0` | Quality divided by depth is low, so the call is weak per read |
| `FS60`, `FS200` | `FS` | `FS > 60.0` (SNP list), `FS > 200.0` (indel list) | Supporting reads came from one strand far more than the other |
| `MQ40` | `MQ` | `MQ < 40.0` | The reads here mapped poorly |
| `MQRankSum-12.5` | `MQRankSum` | `MQRankSum < -12.5` | Reads carrying the variant mapped worse than reference reads |
| `ReadPosRankSum-8`, `ReadPosRankSum-20` | `ReadPosRankSum` | below -8.0 (SNP list), below -20.0 (indel list) | The variant sits near read ends, where errors gather |
| `SOR3`, `SOR10` | `SOR` | `SOR > 3.0` (SNP list), `SOR > 10.0` (indel list) | A second strand-imbalance measure, steadier at high depth |

`QD2` appears twice in the preview because both published lists open with it. A row failing it is labelled once. Run the same command with `--execute` added. It ends by printing "GATK execution completed with exit code 0." and the path of the provenance record, `.lungfish-provenance.json` in the output's folder. The next `--execute` into the same folder overwrites that record, so copy it after each run, or send each step's output to its own folder, if you need every step's record.

### Pull out one person and one variant class with SelectVariants

`--sample HG002` keeps only the son's column, and `--type` keeps one class of variant.

```bash
lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz --sample HG002 \
    --type SNP --output HG002.snps.vcf.gz --execute

lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz --sample HG002 \
    --type INDEL --output HG002.indels.vcf.gz --execute
```

### Normalise indels with LeftAlignAndTrimVariants

Rewrite indels at their leftmost position and split rows carrying several alternate alleles.

```bash
lungfish-cli gatk leftalign \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.leftaligned.vcf.gz \
    --split-multi-allelics --execute
```

### Export a table with VariantsToTable

```bash
lungfish-cli gatk variants-to-table \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.table.tsv --execute
```

### Summarise the call set with CollectVariantCallingMetrics

`--output-prefix` is the start of a file name, which [Picard](../../GLOSSARY.md#picard), the toolkit GATK bundles for counting, completes with its own endings. LGE creates the folder if it does not exist.

```bash
lungfish-cli gatk collect-metrics \
    --vcf cohort.filtered.vcf.gz \
    --dbsnp known-sites.vcf.gz \
    --sequence-dictionary GRCh38.chr20.10.0-10.5Mb.dict \
    --output-prefix metrics/cohort --execute
```

## Settings

None of these subcommands has a window, so every setting is a command-line flag. The table in [What it is](#what-it-is) names the subcommands, and the entries below are their flags. Every flag is listed under [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference.

**Preset.** Chooses which published list of hard-filter tests `filter` applies, `best-practices-snp`, `best-practices-indel`, or the default `best-practices-both`, which applies both lists to every row. Choose a single-class value when you have split the cohort with `select` and want to tune one class apart. An unrecognised value does not fail but silently applies `best-practices-both`, and the value `custom`, which `--help` does not list, applies no tests at all, so read the preview. On the command line this is `--preset`.

**Sample.** Keeps only the named sample's column in `select`. The default is empty, which keeps every sample. Set it when handing one person's calls to someone who should not receive the rest. On the command line this is `--sample`.

**Type.** Keeps one class of variant in `select`, `SNP` for single-base substitutions, `INDEL` for insertions and deletions, or `MIXED` for a position whose alternatives include both. The default is empty, which keeps every class. Set it when a later step treats the classes differently, which most do, and check the preview for `-select-type`, because an unrecognised value is dropped and the command then selects every row. On the command line this is `--type`.

**Intervals.** Restricts `select` or `leftalign` to regions named in an [interval list](../../GLOSSARY.md#interval-list), a BED file, or a contig name. A BED file holds one region per line, the contig, a start counted from zero, and an end, separated by tabs. The default is empty, so the whole file is used. Set it for a gene panel or other defined region. On the command line this is `--intervals`.

**Fields.** Lists the VCF fields `variants-to-table` turns into table columns, as one comma-separated string. The default is `CHROM,POS,REF,ALT,QUAL,AF,DP`, where `AF` is the fraction of the cohort's chromosome copies carrying the variant and `DP` the reads covering it. Change it when you want a statistic the default omits. On the command line this is `--fields`.

**Reference.** Names the FASTA that `leftalign` checks each indel against. There is no default, and `leftalign` requires it. Point it at the FASTA the calls were made against, with its `.fai` index and `.dict` dictionary beside it. On the command line this is `--reference`.

**Split multi-allelics.** Splits a [multi-allelic](../../GLOSSARY.md#multi-allelic) row, one carrying more than one alternate allele, into one row per allele. The default is off, which keeps GATK's per-allele statistics on one row. Turn it on when a later tool reads only the first alternate allele, and expect the row count to rise. On the command line this is `--split-multi-allelics`.

**Max indel length.** Sets the longest indel, in bases, `leftalign` will realign. The default is 200, which covers nearly all indels short-read sequencing produces. Raise it when you call long insertions or deletions, because a longer one passes through unchanged with no note in the output. On the command line this is `--max-indel-length`.

**Max leading bases.** Sets how far left, in bases, `leftalign` will shift an indel looking for its leftmost position. The default is 1000, far enough to leave most repeats. Raise it for indels inside long repeats, since one outside the window stays where the caller wrote it and looks normalized when it is not. On the command line this is `--max-leading-bases`.

**Output prefix.** Names the path stem the two metrics files grow from. There is no default. Expect two files ending `.variant_calling_summary_metrics` and `.variant_calling_detail_metrics`. On the command line this is `--output-prefix`.

**dbSNP.** Names the VCF of known variants each call is checked against. There is no default, because the split between known and [novel](../../GLOSSARY.md#novel-variant) calls is the point of the step. Real work uses a release of [dbSNP](../../GLOSSARY.md#dbsnp), the public catalogue of human variation, and the file must describe the same contigs as your calls. On the command line this is `--dbsnp`.

**Sequence dictionary.** Names the `.dict` file for the reference. The default is empty, so Picard uses the contig list in the VCF headers. Pass it when a header lacks contigs or you want the check made against the reference itself. On the command line this is `--sequence-dictionary`.

**GVCF input.** Tells Picard the input is a GVCF rather than a VCF. The default is off, which suits this chapter's cohort VCF. Turn it on only for a GVCF. On the command line this is `--gvcf-input`.

**Execute.** Runs the composed command instead of printing it. The default is off. Add it once you have read the preview. On the command line this is `--execute`.

**Dry run.** Stops at the preview even when `--execute` is present. The default is off. Use it in a script where `--execute` is fixed. On the command line this is `--dry-run`.

**Extra args.** Passes text straight to the composed GATK command without LGE checking it. The default is empty, which is right for almost every run. Use it for a GATK option LGE does not offer, in one pair of quotes. On the command line this is `--extra-args`.

## Reading the results

### What the filter marked

The filter changes no row count. The run went in with 1,433 rows and came out with 1,433, because `VariantFiltration` marks rather than removes. What changed is the FILTER column.

| FILTER value | Rows |
|---|---|
| `PASS` | 1,420 |
| `SOR3` | 12 |
| `QD2` | 1 |

So 13 rows were marked, 0.9 percent, and the other eight tests marked none. The output also gains a `##FILTER` header line for each test, with its arithmetic written out, so a reader months later can see that `SOR3` meant `SOR > 3.0`.

[SOR](../../GLOSSARY.md#strand-odds-ratio), the strand odds ratio, measures whether supporting reads came mostly from one DNA strand. A real variant is seen about equally from both, so a lopsided count points at a library or chemistry artefact. Most of the 12 `SOR3` rows are insertions or deletions in short repeats, such as position 21,811, where `G` becomes `GTTT` with an SOR of 3.29. [QD](../../GLOSSARY.md#quality-by-depth), quality by depth, divides a row's quality by the depth of reads supporting it, so a deep position with unconvincing reads cannot hide behind a large total. The one `QD2` row, position 87,517, is a deletion in an `AT` repeat with a QUAL of 47.03 and a QD of 1.34.

### What select kept

`select` pulled 1,167 SNP rows and 261 indel rows, and `--type MIXED` pulled the remaining 5, which together make 1,433. GATK files a row whose alternatives include both a substitution and an insertion as `MIXED`. That is why `bcftools view -v snps` counts 1,171 and `-v indels` 266 on the same file, since `bcftools` counts a mixed row under both. The selections keep the FILTER labels, so the SNP file holds 1,162 `PASS` rows and the indel file 253.

`--sample HG002` removed the parents' columns but kept every row, including the 386 where the son is `0/0` and the 12 where he has no call, because `SelectVariants` keeps a row whether or not the chosen sample carries the variant. To keep only the son's own variants, add GATK's option through `--extra-args "--exclude-non-variants"`. On the cohort that leaves 1,035 rows.

### What leftalign changed

`leftalign` with `--split-multi-allelics` was the one step that changed the row count, from 1,433 to 1,488. Each of the 46 multi-allelic rows became one row per alternate allele. Position 27,382, where `T` becomes `TAA` or `TA`, went from one row with `TAA,TA` to two rows.

### The table

`variants-to-table` writes only `PASS` rows by default, 1,420 of them. Add `--extra-args "--show-filtered"` to keep all 1,433. The first two data rows read as follows.

```text
CHROM	POS	REF	ALT	QUAL	AF	DP
chr20_10.0-10.5Mb	2078	G	A	5432.73	1.00	160
chr20_10.0-10.5Mb	2162	A	T	2328.95	0.500	129
```

`AF` here is GATK's fraction of the cohort's chromosome copies that carry the variant, 1.00 when all six copies do and 0.500 when three do, not the share of reads that a frequency-based caller writes under the same name. [What AF means](../01-foundations/05-variants-and-vcf.md#what-af-means) sets the three meanings side by side.

### The metrics files

`collect-metrics` writes two plain-text files. `cohort.variant_calling_summary_metrics` holds one row for the whole call set and `cohort.variant_calling_detail_metrics` one row per sample, adding `SAMPLE_ALIAS` and `HET_HOMVAR_RATIO`. Picard counts only `PASS` rows and types each row its own way, so its counts are smaller than `select`'s.

| Metric | HG002 | HG003 | HG004 | What it means |
|---|---|---|---|---|
| `TOTAL_SNPS` | 839 | 968 | 822 | Substitutions in `PASS` rows where this person carries the variant |
| `NUM_IN_DB_SNP` | 806 | 692 | 561 | Of those, found in the known-variants file |
| `NOVEL_SNPS` | 33 | 276 | 261 | Of those, not in it |
| `PCT_DBSNP` | 0.9607 | 0.7149 | 0.6825 | The known fraction |
| `DBSNP_TITV` | 2.237 | 2.204 | 2.066 | Transition to transversion ratio among known calls |
| `NOVEL_TITV` | 2.000 | 2.494 | 2.527 | The same ratio among novel calls |
| `TOTAL_INDELS` | 148 | 181 | 148 | Insertions and deletions in `PASS` rows |
| `HET_HOMVAR_RATIO` | 1.484 | 2.595 | 2.877 | Calls with one variant copy divided by calls with two |

The summary row for the whole cohort counts 1,159 substitutions, 806 of them known, a known fraction of 0.6954, and 219 indels. Its `FILTERED_SNPS`, 5, plus `FILTERED_INDELS`, 8, is 13, matching the 13 rows the filter marked, a useful internal check.

The known fraction is the share of a person's calls that the known-variants file already holds. Read it against what that file is. The `known-sites.vcf.gz` this part uses is HG002's own [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), so for HG002 the 96 percent measures agreement with his answer key, a recall-style concordance, and not how much of his variation is catalogued. The parents score about 70 percent, not because their calls are worse, but because the file holds only their son's variants, and each parent passed on only half of theirs. Their novel calls are genuine parental variants, which is why their novel Ti/Tv sits at 2.5 rather than falling towards error. Against a real dbSNP release the same metric does measure the catalogued share, and a set where most calls are novel is then usually full of errors rather than discoveries.

The [transition to transversion ratio](../../GLOSSARY.md#transition-transversion-ratio), Ti/Tv, compares two chemical kinds of substitution. A transition swaps a base for the other of its chemical family, purine for purine (A and G) or pyrimidine for pyrimidine (C and T), and a transversion swaps across families. Transitions happen more readily in real biology, so genuine human variation runs at about 2 to 3, while random sequencing error runs near 0.5. Every value in the table sits between 2.0 and 2.6, what real variation looks like.

`HET_HOMVAR_RATIO` differs between people for reasons of ancestry and chance as well as call quality, so watch it mainly for change between runs of the same kind of sample.

If the step fails with a message beginning "Sequence dictionary for (DBSNP" and ending "does not match sequence dictionary for (INPUT)", or with "Sequences at index 0 don't match", the known-variants header does not describe the same contigs at the same lengths as your calls. Rebuild it as [Prepare the known-sites file](04-reference-packs.md#known-sites) shows. Real work against a whole reference and a dbSNP release does not meet this.

LGE writes a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) beside each output, which also records the filter expressions that were applied, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. A failed run leaves this record, marked `failed`, and removes the files it created.

## What good looks like

The row count should not change across the filter. A shorter output means something other than `VariantFiltration` removed rows.

The marked share should be small, under 1 percent here. A double-digit percentage points at a problem in the mapping or calling that ran earlier.

The known fraction should be high for the sample the known-variants file describes, 96 percent for HG002 here. Against a real catalogue it should be high for everyone.

Ti/Tv should sit between 2 and 3 for a human sample, 2.0 to 2.6 here. A value near 0.5 means the calls look like random error.

Read the preview before every `filter` and `select` run, since a mistyped `--preset` or `--type` shows only there.

## On the command line

The Procedure above is the whole command-line route, gathered here as one block with two variations. `--extra-args "--show-filtered"` keeps marked rows in the exported table, and `--intervals` restricts a step to one region. A `select` restricted to the first 100 kilobases with the BED line from [Write an interval list, if you need one](04-reference-packs.md#write-an-interval-list-if-you-need-one) returned 315 rows ending at position 99,174.

```bash
lungfish-cli gatk filter --vcf cohort.vcf.gz --output cohort.filtered.vcf.gz --execute
lungfish-cli gatk select --vcf cohort.filtered.vcf.gz --sample HG002 \
    --type SNP --output HG002.snps.vcf.gz --execute
lungfish-cli gatk leftalign --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --vcf cohort.filtered.vcf.gz --output cohort.leftaligned.vcf.gz \
    --split-multi-allelics --execute
lungfish-cli gatk variants-to-table --vcf cohort.filtered.vcf.gz \
    --output cohort.all.tsv --extra-args "--show-filtered" --execute
lungfish-cli gatk collect-metrics --vcf cohort.filtered.vcf.gz \
    --dbsnp known-sites.vcf.gz --sequence-dictionary GRCh38.chr20.10.0-10.5Mb.dict \
    --output-prefix metrics/cohort --execute
lungfish-cli gatk select --vcf cohort.filtered.vcf.gz --output first100kb.vcf.gz \
    --intervals first100kb.bed --execute
```

## Next

This is the last chapter of Human Germline Variants. To read the filtered cohort in the window, attach `cohort.filtered.vcf.gz` to the reference bundle inside a trio mapping result as [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) shows, then switch the Variants table to per-sample genotypes as [Calls and genotypes](../05-variants/02-reading-the-variant-browser.md#calls-and-genotypes) describes. The manual continues with [What Is Read Classification](../06-classification/01-what-is-classification.md), which turns from what a person's genome carries to which organisms a sample holds.
