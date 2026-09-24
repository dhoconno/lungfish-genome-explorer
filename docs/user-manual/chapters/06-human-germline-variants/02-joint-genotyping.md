---
title: Joint Genotyping
chapter_id: 06-human-germline-variants/02-joint-genotyping
audience: power-user
prereqs: [06-human-germline-variants/01-haplotype-caller, 01-foundations/07-plugin-packs]
estimated_reading_min: 14
task: Combine per-sample GVCFs into one cohort VCF with GATK joint genotyping from the command line.
tags: [gatk, genotypegvcfs, combinegvcfs, genomicsdb, joint-genotyping, cli]
tools: [gatk]
parameters_refs: [variants.gatk-plans]
entry_points:
  - "CLI: lungfish-cli gatk joint-genotype --reference <fasta> --gvcf <gvcf> --intermediate <path> --output <vcf>"
shots: []
illustrations: []
glossary_refs: [allele-specific-annotation, checksum, cohort, combinegvcfs, genomicsdb, genotype, genotypegvcfs, gvcf, indel, interval-list, joint-genotyping, phred-score, plugin-pack, provenance, provenance-sidecar, reference-genome, sequence-dictionary, tabix, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

[HaplotypeCaller](01-haplotype-caller.md) ends with one file per sample. This chapter turns several of those files into one table covering every sample at once. Joint genotyping has no window in Lungfish Genome Explorer (LGE), so everything here runs from the command line.

Each sample arrives as a [GVCF](../../GLOSSARY.md#gvcf), a variant file that records the sample's state at every position of the [reference genome](../../GLOSSARY.md#reference-genome), the agreed sequence everything is described against, rather than only where it differs. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference, so a missing row is ambiguous. It could mean the sample matched the reference or that no reads were there. A GVCF removes the ambiguity by carrying the caller's confidence at every position.

[Joint genotyping](../../GLOSSARY.md#joint-genotyping) reads the per-sample GVCFs together and decides the [genotype](../../GLOSSARY.md#genotype) of every sample at every variant position in one pass. The result is one [cohort](../../GLOSSARY.md#cohort) VCF, a cohort being the set of samples you compare, with one column per sample and an explicit call in every cell. LGE builds it as two GATK commands. The first gathers the GVCFs into one combined store, and the second genotypes that store and writes the cohort VCF.

## Why you would do this

Most questions asked of a set of human samples are comparisons. Which relatives carry the patient's variant, which controls do not, which position differs between a tumour and a matched normal sample from the same patient. Each needs the same position evaluated in every sample, including samples where nothing was found. Per-sample VCFs cannot tell you whether a variant absent from sample B means B matched the reference or had no reads there. Joint genotyping answers that, because the GVCFs carry B's confidence at that position either way.

The worked example uses the HG002 chromosome 20 slice, a 500 kilobase stretch of one human genome. It holds one sample, so it cannot show the comparison the step exists for. It does show every mechanical part of the run, and the command is identical for two samples or two hundred. Repeat `--gvcf` once per sample and nothing else changes.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta` and its `.fai` index from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Put every file this chapter names in one folder and run every command from that folder, which [Before you type anything](../appendices/cli-reference.md#before-you-type-anything) shows how to reach.

You need at least one GVCF. Make it by typing the command below, which writes a GVCF by default. Its input is the BAM of aligned reads that [HaplotypeCaller](01-haplotype-caller.md#on-the-command-line) has you copy out of the bundle as `hg002-minimap2.bam`. The dialog cannot make one, because it always writes a plain VCF, and a plain VCF cannot be joint-genotyped.

```bash
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output HG002.g.vcf.gz --execute
```

This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Install the `gatk-core` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The command line keeps its own copy of the tools, which HaplotypeCaller's command block installs.

GATK needs a FASTA index and a [sequence dictionary](../../GLOSSARY.md#sequence-dictionary) beside the reference, which [Reference Files for GATK](04-reference-packs.md#the-sequence-dictionary) builds.

## Procedure

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. A backslash at the end of a line continues one command onto the next.

**Step 1.** Preview the commands without running anything. Leaving off `--execute` prints the plan and stops.

```bash
lungfish-cli gatk joint-genotype \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --gvcf HG002.g.vcf.gz \
    --intermediate cohort.combined.g.vcf.gz \
    --output cohort.vcf.gz
```

The command prints the two GATK commands it composed, shown here with folder paths shortened to three dots.

```
gatk CombineGVCFs -R .../GRCh38.chr20.10.0-10.5Mb.fasta -O .../cohort.combined.g.vcf.gz --variant .../HG002.g.vcf.gz
gatk GenotypeGVCFs -R .../GRCh38.chr20.10.0-10.5Mb.fasta -V .../cohort.combined.g.vcf.gz -O .../cohort.vcf.gz --standard-min-confidence-threshold-for-calling 30.0 -G AS_StandardAnnotation
```

Read the first word after `gatk` on the first line. It names the combining tool LGE picked for your cohort size, `CombineGVCFs` or [`GenomicsDBImport`](../../GLOSSARY.md#genomicsdb). The two options at the end of the second line are ones LGE always adds, which the Settings section explains.

**Step 2.** Run it by adding `--execute`.

```bash
lungfish-cli gatk joint-genotype \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --gvcf HG002.g.vcf.gz \
    --intermediate cohort.combined.g.vcf.gz \
    --output cohort.vcf.gz \
    --execute
```

A successful run ends by printing "GATK execution completed with exit code 0." and the path of the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file LGE writes beside the results recording exactly what ran. An exit code of `0` means success. The code printed is that of the last GATK step, so when a run fails, read the sidecar to see which step went wrong. The recorded run took about three seconds.

**Step 3.** Read the cohort VCF's first lines. `bcftools` arrives with the Required Setup pack at `~/.lungfish/conda/envs/bcftools/bin/bcftools`, and `| head -40` keeps the first 40 lines, the `##` header lines first.

```bash
bcftools view cohort.vcf.gz | head -40
```

## Settings

Joint genotyping has no window, so every setting is a command-line flag. `--reference`, `--output`, and `--intermediate` are required.

**Reference.** Names the reference FASTA both GATK steps run against, which must be the one the GVCFs were called against. There is no default, because GATK cannot read a GVCF's coordinates without their sequence. Change it for each reference, and keep its `.fai` index and `.dict` dictionary beside it. On the command line this is `--reference`.

**GVCF.** Names one input GVCF, repeated once per sample. There is no default, and LGE does not insist on at least one. Give one for every sample in the cohort, and count your `--gvcf` flags against your samples before you run, since a command with none still prints a plan. On the command line this is `--gvcf`.

**Output.** Names the cohort VCF the run writes. There is no default. Give each cohort its own path, and expect a [tabix](../../GLOSSARY.md#tabix) index, the companion file that lets a program jump to a position, to appear beside it. On the command line this is `--output`.

**Intermediate.** Names the combined store the first step writes and the second reads. There is no default. Give a path ending `.g.vcf.gz` when CombineGVCFs runs and a folder name when GenomicsDBImport runs. On the command line this is `--intermediate`.

**Combine strategy.** Chooses the combining tool, [CombineGVCFs](../../GLOSSARY.md#combinegvcfs), which merges the GVCFs into one file and grows slow as samples mount, or [GenomicsDB](../../GLOSSARY.md#genomicsdb), an on-disk store built for many samples whose setup cost is wasted on a handful. The default is `auto`, which picks CombineGVCFs for 50 samples or fewer and GenomicsDB above that. Set `combine-gvcfs` or `genomicsdb` when an automated pipeline must not change behaviour as a cohort grows, and check the preview, because an unrecognised value quietly falls back to `auto`. On the command line this is `--combine-strategy`.

**Intervals.** Restricts both GATK steps to regions named in an [interval list](../../GLOSSARY.md#interval-list), or a BED file. The default is empty, so the whole reference is genotyped. Set it for a gene panel or other defined region, which saves the time the combine step would spend on the rest of the genome. On the command line this is `--intervals`.

**Extra args.** Passes text straight to the final `GenotypeGVCFs` command without LGE checking it, never to the combine step. The default is empty, which is right for almost every run. Use it for a GATK option LGE does not offer, in one pair of straight double quotes, such as `--extra-args "--max-alternate-alleles 3"`. On the command line this is `--extra-args`.

**Execute.** Runs both GATK steps instead of only printing them. The default is off, so a command without it prints the plan and writes nothing. Add it once you have read the preview. On the command line this is `--execute`.

**Dry run.** Stops a run at the preview even when `--execute` is present. The default is off, and on its own it changes nothing. Use it in a script where `--execute` is fixed and you want one run to stop short. On the command line this is `--dry-run`.

LGE always adds two GATK options to the genotyping step. `--standard-min-confidence-threshold-for-calling 30.0` drops any candidate scoring below 30. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand, and GATK's call confidence uses the same scale. `-G AS_StandardAnnotation` asks for [allele-specific annotations](../../GLOSSARY.md#allele-specific-annotation), extra measurements recorded separately for each alternate allele, with keys beginning `AS_`. Neither can be changed. No flag sets them, and passing a second copy through `--extra-args` makes GATK stop with an error that the option was given more than once.

## Reading the results

A finished run leaves five files.

| File | What it holds |
|---|---|
| `cohort.vcf.gz` | The cohort VCF, one row per variant position and one column per sample |
| `cohort.vcf.gz.tbi` | Its tabix index |
| `cohort.combined.g.vcf.gz` | The combined GVCF the first step wrote |
| `cohort.combined.g.vcf.gz.tbi` | Its tabix index |
| `.lungfish-provenance.json` | The provenance sidecar for the whole run |

The sidecar's name begins with a dot, which Finder hides until you press Cmd-Shift-Period.

The input GVCF held 48,057 rows across the slice, because a GVCF has a row for every position or block of positions. The cohort VCF held 1,026 rows, one per position where something differed, about a forty-seven-fold reduction. Of those, 844 are single-base substitutions and 182 are [indels](../../GLOSSARY.md#indel), insertions or deletions, counting each row by its first alternate allele.

Here is the first row of the cohort VCF, wrapped to fit, with INFO keys this chapter does not need replaced by three dots. Its columns are CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT, and one column per sample.

```
chr20_10.0-10.5Mb	2078	.	G	A	2175.06	.
AC=2;AF=1;AN=2;AS_QD=25.36;DP=62;...;QD=28.73;SOR=0.76	GT:AD:DP:GQ:PL	1/1:0,60:60:99:2189,180,0
```

The last column is what joint genotyping produced, read against the `GT:AD:DP:GQ:PL` labels before it. A [genotype](../../GLOSSARY.md#genotype) of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do, and here `GT` is `1/1`. `AD`, the read counts for the reference and the alternate, is `0,60`. `DP`, the reads covering the position, is 60. `GQ`, the confidence in this sample's genotype, is 99, the highest GATK writes, while a `GQ` under 20 is weak. `PL` restates the genotype confidences and is not needed here. The FORMAT fields are defined in [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md#the-eight-standard-columns-and-what-may-follow-them).

`QUAL`, 2175.06 here, is GATK's confidence that the position varies at all, and `GQ` is its confidence in one sample's genotype. The INFO `DP` of 62 sums depth across all samples, while the sample's own `DP` is 60. On a real cohort the INFO figure is far larger.

The lowest `QUAL` in the file is 31.6, just above the fixed threshold of 30. The mean INFO depth across the 1,026 rows is 39.4. Judge depth against the alignment's own depth over the region, 44.7 for this slice, and expect called positions to sit a little below it.

Every row's FILTER column reads a bare `.`, meaning no filter was applied, not that the row passed. Joint genotyping applies no quality filters, and [Filtering, Selecting, and Metrics](03-filtering-selecting-and-metrics.md) covers the step that does.

The sidecar holds one entry per GATK step, each with its full command, exit code, wall time, and tool version, plus a [checksum](../../GLOSSARY.md#checksum), a fingerprint computed from a file's contents, for each file. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Cite the sidecar in a methods section rather than retyping the command from memory.

A failed run removes the result files it created and leaves only the sidecar, marked `failed` with the failing step's exit code. A run pointed at a missing GVCF stopped with GATK exit code 2 and printed the sidecar path.

The GenomicsDB route writes a folder instead of a combined GVCF, holding GATK's own bookkeeping files. Delete it once the cohort VCF exists, unless you plan to add samples to the same store. A run forcing GenomicsDB with `--intervals` covering the first 100 kilobases wrote 258 rows, the last at position 99,174, which shows the restriction reached both steps.

## What good looks like

Every sample you passed should appear as a column. `bcftools query -l cohort.vcf.gz` lists the sample names, and the recorded run listed one, `HG002`. A missing sample usually means a `--gvcf` flag was left out.

The row count should collapse sharply from the input. `bcftools view -H cohort.vcf.gz | wc -l` counts the rows. A cohort VCF within a few fold of its input GVCF suggests an ordinary VCF was passed where a GVCF was expected.

The combining tool in the preview should be the one you meant, since a mistyped strategy falls back to `auto` without a warning.

The lowest `QUAL` should sit at or above 30. `bcftools query -f '%QUAL\n' cohort.vcf.gz | sort -g | head -1` prints it. A lower value means the file did not come from this command.

Do not read a bare `.` in the FILTER column as a pass.

## On the command line

The whole procedure for a real cohort is one command with one `--gvcf` per sample.

```bash
lungfish-cli gatk joint-genotype \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --gvcf sample1.g.vcf.gz \
    --gvcf sample2.g.vcf.gz \
    --gvcf sample3.g.vcf.gz \
    --intermediate cohort.combined.g.vcf.gz \
    --output cohort.vcf.gz \
    --execute
```

## Next

The cohort VCF is unfiltered. [Filtering, Selecting, and Metrics](03-filtering-selecting-and-metrics.md) covers marking calls not worth trusting, pulling out one sample or variant type, and summarising a finished call set.
