---
title: Filtering, Selecting, and Metrics
chapter_id: 06-human-germline-variants/03-filtering-selecting-and-metrics
audience: power-user
prereqs: [06-human-germline-variants/02-joint-genotyping]
estimated_reading_min: 18
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
glossary_refs: [checksum, dbsnp, filter, hard-filter, indel, interval-list, left-alignment, multi-allelic, novel-variant, phred-score, picard, provenance, provenance-sidecar, quality-by-depth, reference-genome, snv, strand-odds-ratio, transition-transversion-ratio, tsv, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

[Joint Genotyping](02-joint-genotyping.md) ends with a cohort [VCF](../../GLOSSARY.md#vcf), a tab-separated file with one row per position where the samples differ from the [reference genome](../../GLOSSARY.md#reference-genome). Nobody has yet judged its calls for quality. It holds every position the caller was willing to write down, including rows whose evidence is too weak to believe. The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains, and every row of the cohort VCF reads `.`.

This chapter covers five GATK steps that turn that raw table into something you can hand to a colleague. Each is a subcommand of `lungfish-cli gatk`, and none has a window in Lungfish Genome Explorer (LGE).

| Subcommand | What it does |
|---|---|
| `filter` | Marks suspect rows in the FILTER column without deleting them |
| `select` | Pulls out one sample, one class of variant, or one region |
| `leftalign` | Rewrites each [indel](../../GLOSSARY.md#indel), an insertion or deletion, at the leftmost position it can occupy, so two files compare cleanly |
| `variants-to-table` | Unpacks the VCF into a [TSV](../../GLOSSARY.md#tsv), a tab-separated table any spreadsheet opens |
| `collect-metrics` | Counts the finished set against a file of already known variants |

Run `filter` on every cohort VCF before you trust any row in it, and reach for the other four as your question requires.

## Why you would do this

A variant caller reports every position with any supporting evidence and leaves the judgement to a later step. Skip that step and a few positions with lopsided strand support or thin evidence sit in your results looking like the thousand without either problem.

A [hard filter](../../GLOSSARY.md#hard-filter) is the simplest judgement, a fixed list of arithmetic tests on the statistics the caller already wrote into each row's INFO column, with no model to train. GATK publishes a recommended list for human germline work, and LGE ships it as the default. For large projects GATK recommends Variant Quality Score Recalibration (VQSR), which learns thresholds from the data. On a single sample or a small cohort a hard filter catches the obvious problems and is easy to explain in a methods section.

The worked example runs on the cohort VCF from the HG002 chromosome 20 slice, a 500 kilobase stretch of a Genome in a Bottle reference sample whose variants are known independently. On that file the filter marked 13 rows out of 1,026, 1.3 percent. Learning that it is only thirteen is itself the result, and you would not know without running the step.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, its `.fai` index, `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz`, and its `.tbi` index from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Put them, and the `cohort.vcf.gz` and `.tbi` from [Joint Genotyping](02-joint-genotyping.md), in one folder and run every command from there.

This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Install the `gatk-core` pack. The command line keeps its own copy of the tools, which [HaplotypeCaller](01-haplotype-caller.md#on-the-command-line) installs.

Steps 4 and 6 need two more files you make yourself, `GRCh38.chr20.10.0-10.5Mb.dict` and `known-sites.vcf.gz`. GATK needs a FASTA index and a [sequence dictionary](../../GLOSSARY.md#sequence-dictionary) beside the reference, which [Reference Files for GATK](04-reference-packs.md#the-sequence-dictionary) builds. The metrics step also needs a known-variants file whose header matches the reference exactly. The benchmark's header describes the whole genome, so rebuild it as `known-sites.vcf.gz` as [The known-sites files](04-reference-packs.md#the-known-sites-files) shows. Each step below finished in about a second on this slice.

## Procedure

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every subcommand prints the GATK command it composed and stops. Adding `--execute` runs it.

**Step 1.** Preview the filter.

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

`QD2` appears twice in the preview because both published lists open with it. A row failing it is labelled once.

**Step 2.** Run the filter.

```bash
lungfish-cli gatk filter \
    --vcf cohort.vcf.gz \
    --output cohort.filtered.vcf.gz \
    --execute
```

It ends by printing "GATK execution completed with exit code 0." and the path of the provenance record. LGE writes that record as `.lungfish-provenance.json` in the output's folder, so the next `--execute` into the same folder overwrites it. Copy it after each run, or send each step's output to its own folder, if you need every step's record.

**Step 3.** Split the filtered cohort by variant class. `--sample HG002` names the sample column to keep, which on this one-sample fixture drops nothing.

```bash
lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz --sample HG002 \
    --type SNP --output HG002.snps.vcf.gz --execute

lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz --sample HG002 \
    --type INDEL --output HG002.indels.vcf.gz --execute
```

**Step 4.** Rewrite indels at their leftmost position and split rows carrying several alternate alleles.

```bash
lungfish-cli gatk leftalign \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.leftaligned.vcf.gz \
    --split-multi-allelics --execute
```

**Step 5.** Export the calls as a table.

```bash
lungfish-cli gatk variants-to-table \
    --vcf cohort.filtered.vcf.gz \
    --output cohort.table.tsv --execute
```

**Step 6.** Summarise the filtered set against the known-variants file. `--output-prefix` is the start of a file name, which [Picard](../../GLOSSARY.md#picard), the toolkit GATK bundles for counting, completes with its own endings. LGE creates the folder if it does not exist.

```bash
lungfish-cli gatk collect-metrics \
    --vcf cohort.filtered.vcf.gz \
    --dbsnp known-sites.vcf.gz \
    --sequence-dictionary GRCh38.chr20.10.0-10.5Mb.dict \
    --output-prefix metrics/cohort --execute
```

## Settings

None of these operations has a window, so every setting is a command-line flag.

**Filter.** Builds a `VariantFiltration` command that labels the FILTER column of every row failing a test, leaving the row in place. There is no default, since naming the subcommand is how you ask for it. Run it on every cohort VCF before reading any row as a result. On the command line this is `lungfish-cli gatk filter`.

**Preset.** Chooses which published list of hard-filter tests to apply, `best-practices-snp`, `best-practices-indel`, or the default `best-practices-both`, which applies both lists to every row. Choose a single-class value when you have split the cohort with `select` and want to tune one class apart. An unrecognised value does not fail but silently applies `best-practices-both`, and the value `custom`, which `--help` does not list, applies no tests at all, so read the preview. On the command line this is `--preset`.

**Select.** Builds a `SelectVariants` command that writes the subset of rows you describe. There is no default. Run it when a later step wants one sample, one variant class, or one region. On the command line this is `lungfish-cli gatk select`.

**Sample.** Keeps only the named sample's column. The default is empty, which keeps every sample. Set it when handing one person's calls to someone who should not receive the rest. On the command line this is `--sample`.

**Type.** Keeps one class of variant, `SNP` for single-base substitutions, `INDEL` for insertions and deletions, or `MIXED` for a position whose alternatives include both. The default is empty, which keeps every class. Set it when a later step treats the classes differently, which most do, and check the preview for `-select-type`, because an unrecognised value is dropped and the command then selects every row. On the command line this is `--type`.

**Intervals.** Restricts `select` or `leftalign` to regions named in an [interval list](../../GLOSSARY.md#interval-list), a BED file, or a contig name. A BED file holds one region per line, the contig, a start counted from zero, and an end, separated by tabs. The default is empty, so the whole file is used. Set it for a gene panel or other defined region. On the command line this is `--intervals`.

**Variants to table.** Builds a `VariantsToTable` command that writes chosen VCF fields to a TSV. There is no default. Run it when the calls need to be read, sorted, or plotted outside genomics tools. On the command line this is `lungfish-cli gatk variants-to-table`.

**Fields.** Lists the VCF fields that become table columns, as one comma-separated string. The default is `CHROM,POS,REF,ALT,QUAL,AF,DP`, where `AF` is the fraction of the sample's chromosome copies carrying the variant and `DP` the reads covering it. Change it when you want a statistic the default omits. On the command line this is `--fields`.

**Reference.** Names the FASTA that `leftalign` checks each indel against. There is no default, and `leftalign` requires it. Point it at the FASTA the calls were made against, with its `.fai` index and `.dict` dictionary beside it. On the command line this is `--reference`.

**Left align.** Builds a `LeftAlignAndTrimVariants` command. An insertion inside a repeated stretch can be written at several equally correct positions, so two callers can describe one event two ways. This command rewrites each indel at its leftmost position and trims shared bases, giving the [left-aligned](../../GLOSSARY.md#left-alignment) form both files agree on. There is no default. Run it before comparing or merging VCFs from different callers. On the command line this is `lungfish-cli gatk leftalign`.

**Split multi-allelics.** Splits a [multi-allelic](../../GLOSSARY.md#multi-allelic) row, one carrying more than one alternate allele, into one row per allele. The default is off, which keeps GATK's per-allele statistics on one row. Turn it on when a later tool reads only the first alternate allele, and expect the row count to rise. On the command line this is `--split-multi-allelics`.

**Max indel length.** Sets the longest indel, in bases, the tool will realign. The default is 200, which covers nearly all indels short-read sequencing produces. Raise it when you call long insertions or deletions, because a longer one passes through unchanged with no note in the output. On the command line this is `--max-indel-length`.

**Max leading bases.** Sets how far left, in bases, the tool will shift an indel looking for its leftmost position. The default is 1000, far enough to leave most repeats. Raise it for indels inside long repeats, since one outside the window stays where the caller wrote it and looks normalized when it is not. On the command line this is `--max-leading-bases`.

**Collect metrics.** Builds a Picard `CollectVariantCallingMetrics` command that counts the call set against known variants. There is no default. Run it last on any call set you are about to report. On the command line this is `lungfish-cli gatk collect-metrics`.

**Output prefix.** Names the path stem the two metrics files grow from. There is no default. Expect two files ending `.variant_calling_summary_metrics` and `.variant_calling_detail_metrics`. On the command line this is `--output-prefix`.

**dbSNP.** Names the VCF of known variants each call is checked against. There is no default, because the split between known and [novel](../../GLOSSARY.md#novel-variant) calls is the point of the step. Real work uses a release of [dbSNP](../../GLOSSARY.md#dbsnp), the public catalogue of human variation, and the file must describe the same contigs as your calls. On the command line this is `--dbsnp`.

**Sequence dictionary.** Names the `.dict` file for the reference. The default is empty, so Picard uses the contig list in the VCF headers. Pass it when a header lacks contigs or you want the check made against the reference itself. On the command line this is `--sequence-dictionary`.

**GVCF input.** Tells Picard the input is a GVCF rather than a VCF. The default is off, which suits this chapter's cohort VCF. Turn it on only for a GVCF. On the command line this is `--gvcf-input`.

**Execute.** Runs the composed command instead of printing it. The default is off. Add it once you have read the preview. On the command line this is `--execute`.

**Dry run.** Stops at the preview even when `--execute` is present. The default is off. Use it in a script where `--execute` is fixed. On the command line this is `--dry-run`.

**Extra args.** Passes text straight to the composed GATK command without LGE checking it. The default is empty, which is right for almost every run. Use it for a GATK option LGE does not offer, in one pair of quotes. On the command line this is `--extra-args`.

## Reading the results

The filter changes no row count. The run went in with 1,026 rows and came out with 1,026, because `VariantFiltration` marks rather than removes. What changed is the FILTER column.

| FILTER value | Rows |
|---|---|
| `PASS` | 1,013 |
| `SOR3` | 12, one of them also `QD2` |
| `QD2` | 2, one of them also `SOR3` |

Position 496,668 failed both tests and reads `QD2;SOR3`, a VCF's way of listing two failures. So 13 distinct rows were marked, 1.3 percent, and the other seven tests marked none.

[QD](../../GLOSSARY.md#quality-by-depth), quality by depth, divides a row's quality by the depth of reads supporting it, so a deep position with unconvincing reads cannot hide behind a large total. The two `QD2` rows had QUAL values of 32.64 and 32.60, just above the calling threshold of 30. [SOR](../../GLOSSARY.md#strand-odds-ratio), the strand odds ratio, measures whether supporting reads came mostly from one DNA strand. A real variant is seen about equally from both, so a lopsided count points at a library or chemistry artefact. The output also gains a `##FILTER` header line for each test, with its arithmetic written out, so a reader months later can see that `SOR3` meant `SOR > 3.0`.

`select` pulled 842 SNP rows and 182 indel rows, and `--type MIXED` pulled the remaining 2, which together make 1,026. GATK files a row whose alternatives include both a substitution and an insertion as `MIXED`, such as position 29,224, where `A` becomes `G` or `AGG`. That is why GATK's 842 differs from the 844 substitutions [HaplotypeCaller](01-haplotype-caller.md#reading-the-results) reports by first alternate allele. Both selections keep the FILTER labels, so the SNP file holds 836 `PASS` rows and the indel file 175.

`leftalign` with `--split-multi-allelics` was the one step that changed the row count, from 1,026 to 1,045. Each of the 19 multi-allelic rows became two. Position 29,224 went from `A` to `G,AGG` on one row to `A` to `G` and `A` to `AGG` on two.

`variants-to-table` writes only `PASS` rows by default, 1,013 of them. Add `--extra-args "--show-filtered"` to keep all 1,026. The first data row reads as follows.

```
CHROM	POS	REF	ALT	QUAL	AF	DP
chr20_10.0-10.5Mb	2078	G	A	2175.06	1.00	62
```

### The metrics files

`collect-metrics` writes two plain-text files. `cohort.variant_calling_summary_metrics` holds one row for the whole call set and `cohort.variant_calling_detail_metrics` one row per sample, adding `SAMPLE_ALIAS` and `HET_HOMVAR_RATIO`. On a one-sample cohort the numbers match.

| Metric | Value | What it means |
|---|---|---|
| `TOTAL_SNPS` | 835 | Substitutions counted, `PASS` rows only |
| `NUM_IN_DB_SNP` | 799 | Of those, already in the known-variants file |
| `NOVEL_SNPS` | 36 | Of those, not in it |
| `PCT_DBSNP` | 0.9569 | The known fraction, 95.7 percent. High is good |
| `DBSNP_TITV` | 2.248 | Transition to transversion ratio among known calls. Expect 2 to 3 |
| `NOVEL_TITV` | 1.769 | The same ratio among novel calls. Usually lower |
| `TOTAL_INDELS` | 159 | Insertions and deletions counted, `PASS` rows only |
| `FILTERED_SNPS` | 6 | Substitutions the filter marked |
| `FILTERED_INDELS` | 7 | Indels the filter marked |
| `HET_HOMVAR_RATIO` | 1.459 | Calls with one variant copy divided by calls with two, detail file only |

The known fraction is the share of your calls someone has seen before. A well-studied human sample mostly carries catalogued variation, so a set where most calls are novel is usually full of errors rather than discoveries.

The [transition to transversion ratio](../../GLOSSARY.md#transition-transversion-ratio), Ti/Tv, compares two chemical kinds of substitution. A transition swaps a base for the other of its chemical family, purine for purine (A and G) or pyrimidine for pyrimidine (C and T), and a transversion swaps across families. Transitions happen more readily in real biology, so genuine human variation runs at about 2 to 3, while random sequencing error runs near 0.5. The 2.248 among known calls is squarely in range, and the lower 1.769 among novel calls is what a small set carrying more error looks like.

`HET_HOMVAR_RATIO` runs near 1.5 to 2 for a human sample as general guidance, so 1.459 is unremarkable. Watch it mainly for change between runs of similar samples.

These counts differ from `select`'s because Picard counts only `PASS` rows and types them its own way, which is why 835 and 159 are smaller than 842 and 182. `FILTERED_SNPS` plus `FILTERED_INDELS` is 13, matching the 13 rows the filter marked, a useful internal check.

If the step fails with a message beginning "Sequence dictionary for (DBSNP" and ending "does not match sequence dictionary for (INPUT)", or with "Sequences at index 0 don't match", the known-variants header does not describe the same contigs at the same lengths as your calls. Rebuild it as [The known-sites files](04-reference-packs.md#the-known-sites-files) shows. Real work against a whole reference and a dbSNP release does not meet this.

### The provenance record

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Here it is the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) `.lungfish-provenance.json`, hidden in Finder until you press Cmd-Shift-Period, and it also records the filter expressions that were applied. A failed run leaves this record, marked `failed`, and removes the files it created, so no partial output is left behind.

## What good looks like

The row count should not change across the filter. A shorter output means something other than `VariantFiltration` removed rows.

The marked share should be small, 1.3 percent here. A double-digit percentage points at a problem in the mapping or calling that ran earlier.

The known fraction should be high, 95.7 percent here. A set where most calls are novel is usually full of errors.

Ti/Tv should sit between 2 and 3 for a human sample, 2.248 here. A value near 0.5 means the calls look like random error.

Read the preview before every `filter` and `select` run, since a mistyped `--preset` or `--type` shows only there.

## On the command line

The Procedure above is the whole command-line route. Two variations are worth knowing. To keep marked rows in the exported table, pass GATK's own option through, and to restrict a step to one region, point `--intervals` at a BED file. A `select` restricted to the first 100 kilobases returned 258 rows ending at position 99,174.

```bash
lungfish-cli gatk variants-to-table \
    --vcf cohort.filtered.vcf.gz --output cohort.all.tsv \
    --extra-args "--show-filtered" --execute

lungfish-cli gatk select \
    --vcf cohort.filtered.vcf.gz --output first100kb.vcf.gz \
    --intervals first100kb.bed --execute
```

## Next

[Reference Files for GATK](04-reference-packs.md) covers the companion files GATK expects beside a reference, and base quality score recalibration, which corrects per-base quality scores in an alignment before calling.
