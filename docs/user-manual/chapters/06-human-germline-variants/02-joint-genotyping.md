---
title: Joint Genotyping
chapter_id: 06-human-germline-variants/02-joint-genotyping
audience: power-user
prereqs: [06-human-germline-variants/04-reference-packs, 06-human-germline-variants/01-haplotype-caller]
estimated_reading_min: 10
task: Call a family trio as GVCFs and combine them into one cohort VCF with GATK joint genotyping from the command line.
tags: [gatk, genotypegvcfs, combinegvcfs, genomicsdb, joint-genotyping, trio, cli]
tools: [gatk, bcftools]
parameters_refs: [variants.gatk-plans]
entry_points:
  - "CLI: lungfish-cli gatk joint-genotype --reference <fasta> --gvcf <gvcf> --intermediate <path> --output <vcf>"
shots: []
illustrations: []
glossary_refs: [allele-frequency, allele-specific-annotation, checksum, cohort, combinegvcfs, genomicsdb, genotype, genotype-quality, genotypegvcfs, gvcf, heterozygous, homozygous, indel, interval-list, joint-genotyping, phred-score, provenance, provenance-sidecar, reference-genome, sequence-dictionary, tabix, vcf, germline, filter]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20, giab-trio-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

[HaplotypeCaller](01-haplotype-caller.md) ends with one file per sample. This chapter turns several of those files into one table covering every sample at once. Joint genotyping has no window in Lungfish Genome Explorer (LGE), so everything here runs from the command line.

Each sample arrives as a [GVCF](../../GLOSSARY.md#gvcf), a variant file that records the sample's state at every position of the [reference genome](../../GLOSSARY.md#reference-genome), the agreed sequence everything is described against, rather than only where it differs. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference, so a missing row is ambiguous. It could mean the sample matched the reference or that no reads were there. A GVCF removes the ambiguity by carrying the caller's confidence at every position.

[Joint genotyping](../../GLOSSARY.md#joint-genotyping) reads the per-sample GVCFs together and decides the [genotype](../../GLOSSARY.md#genotype) of every sample at every variant position in one pass. The result is one [cohort](../../GLOSSARY.md#cohort) VCF, a cohort being the set of samples you compare, with one column per sample and an explicit call in every cell. LGE builds it as two GATK commands. The first gathers the GVCFs into one combined store, and the second genotypes that store and writes the cohort VCF.

## Why you would do this

Most questions asked of a set of human samples are comparisons. Which relatives carry a patient's variant, which unaffected controls do not, whether a change seen in a child was inherited from a parent. Each needs the same position evaluated in every sample, including samples where nothing was found. Per-sample VCFs cannot tell you whether a variant absent from one person means that person matched the reference or had no reads there. Joint genotyping answers that, because each GVCF carries that person's confidence at the position either way.

All of these compare inherited, [germline](../../GLOSSARY.md#germline) variants. Comparing a tumour with normal tissue from the same patient is a different problem, because a tumour's own mutations are present in only some of its cells. It needs a somatic caller built for that, such as GATK's Mutect2, which LGE does not offer.

The example in this chapter is a family. The Human Mapping and Variants demo project holds the same 500 kilobases of chromosome 20 from three people of the Genome in a Bottle Ashkenazi trio, the son HG002 and his parents, HG003 and HG004. A child inherits one copy of each chromosome from each parent, so every genotype the son carries should be explainable from his parents' genotypes. Where it is not, either a call is wrong or the change is new in the child, and only a table that holds all three people at every position can tell you which positions to look at.

## Before you start

Work through [Reference Files for GATK](04-reference-packs.md) first. It maps the three samples, sets up the `LGE GATK` working folder with the reference, its `.fai` index and `.dict` [sequence dictionary](../../GLOSSARY.md#sequence-dictionary), and the three BAMs, and sets the shell variables the commands below use. [HaplotypeCaller](01-haplotype-caller.md) explains what the caller does. Run every command in this chapter from `LGE GATK`.

This chapter uses the `gatk-core` pack that chapter installed, and `bcftools` from the Required Setup pack to read the results. The whole chapter took a few minutes on the recorded Mac, almost all of it the three HaplotypeCaller runs.

## Procedure

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. A backslash at the end of a line continues one command onto the next.

### Call each sample as a GVCF

`lungfish-cli gatk haplotype-caller` writes a GVCF unless told otherwise, which is what this step needs. The Call Variants dialog cannot make one, because it always writes a plain VCF, and a plain VCF cannot be joint-genotyped.

```bash
for SAMPLE in HG002 HG003 HG004; do
  lungfish-cli gatk haplotype-caller \
      --reference GRCh38.chr20.10.0-10.5Mb.fasta \
      --bam "$SAMPLE.sorted.bam" \
      --output "$SAMPLE.g.vcf.gz" --execute
done
```

Each run ends by printing "GATK execution completed with exit code 0." and took between 20 seconds and two minutes on the recorded Mac. The three GVCFs hold 48,057, 69,694, and 50,185 rows, because each has a row for every variant position or block of matching positions.

### Preview the joint genotyping commands

Leaving off `--execute` prints the plan and stops. Give one `--gvcf` per sample.

```bash
lungfish-cli gatk joint-genotype \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --gvcf HG002.g.vcf.gz --gvcf HG003.g.vcf.gz --gvcf HG004.g.vcf.gz \
    --intermediate cohort.combined.g.vcf.gz \
    --output cohort.vcf.gz
```

The command prints the two GATK commands it composed, shown here with folder paths shortened to three dots.

```text
gatk CombineGVCFs -R .../GRCh38.chr20.10.0-10.5Mb.fasta -O .../cohort.combined.g.vcf.gz --variant .../HG002.g.vcf.gz --variant .../HG003.g.vcf.gz --variant .../HG004.g.vcf.gz
gatk GenotypeGVCFs -R .../GRCh38.chr20.10.0-10.5Mb.fasta -V .../cohort.combined.g.vcf.gz -O .../cohort.vcf.gz --standard-min-confidence-threshold-for-calling 30.0 -G AS_StandardAnnotation
```

Read the first word after `gatk` on the first line. It names the combining tool LGE picked for your cohort size, `CombineGVCFs` or [`GenomicsDBImport`](../../GLOSSARY.md#genomicsdb). Count the `--variant` entries against your samples. The two options at the end of the second line are ones LGE always adds, which the Settings section explains.

### Run joint genotyping

Run the same command with `--execute` added as its last line. A successful run ends by printing "GATK execution completed with exit code 0." and the path of the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file LGE writes beside the results recording exactly what ran. The code printed is that of the last GATK step, so when a run fails, read the sidecar to see which step went wrong. The recorded run took about seven seconds.

### Read the cohort

List the samples and the first rows with `bcftools`.

```bash
"$BCFTOOLS" query -l cohort.vcf.gz
"$BCFTOOLS" view -H cohort.vcf.gz | head -5
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

`bcftools query -l` lists `HG002`, `HG003`, and `HG004`, one column per person. The cohort VCF holds 1,433 rows, one per position where anyone in the family differs from the reference, where HG002's own VCF from [HaplotypeCaller](01-haplotype-caller.md#reading-the-results) held 1,026. The extra rows are positions where only a parent carries a variant, now written with the son's genotype too.

### Reading one row

Here is the first row, wrapped to fit, with INFO keys this chapter does not need replaced by three dots. Its columns are CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT, and one column per sample.

```text
chr20_10.0-10.5Mb	2078	.	G	A	5432.73	.
AC=6;AF=1;AN=6;AS_QD=34.61;DP=160;...;QD=34.6;SOR=0.785	GT:AD:DP:GQ:PL
1/1:0,60:60:99:2189,180,0	1/1:0,48:48:99:1484,143,0	1/1:0,49:49:99:1773,147,0
```

The last three columns are what joint genotyping produced, one per person, read against the `GT:AD:DP:GQ:PL` labels before them. A genotype of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do, and here all three people are `1/1`. `AD`, the read counts for the reference and the alternate, is `0,60` for the son. `DP`, the reads covering the position, is 60. `GQ`, the [genotype quality](../../GLOSSARY.md#genotype-quality), GATK's confidence in this one person's genotype, is 99, the highest GATK writes, while a `GQ` under 20 is weak. `PL` restates the genotype confidences and is not needed here. The FORMAT fields are defined in [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md#the-eight-standard-columns-and-what-may-follow-them).

`QUAL`, 5432.73 here, is GATK's confidence that the position varies in anyone at all, and `GQ` is its confidence in one person's genotype. The INFO `DP` of 160 is larger than the 157 the three sample `DP` values add up to, because INFO `DP` counts reads before GATK sets aside the ones it does not trust for each sample. `AF=1` in the INFO column is not the share of reads that [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) reports. Here it is the fraction of the family's six chromosome copies that carry the change, all six of them, as [What AF means](../01-foundations/05-variants-and-vcf.md#what-af-means) explains.

The lowest `QUAL` in the file is 30.94, just above the fixed threshold of 30. The mean INFO depth across the 1,433 rows is 110.2, three people's worth of reads.

### What the family adds

Position 2,162 is the row that shows why the step exists.

```text
chr20_10.0-10.5Mb	2162	A	T	2328.95	0/1:23,26:49:99	1/1:0,41:41:99	0/0:38,0:38:99
```

The son is heterozygous, `0/1`, his father homozygous for the change, `1/1`, and his mother `0/0`, homozygous for the reference base. That last call is the point. Her own VCF would simply have had no row here. The cohort VCF says she matches the reference and backs it with 38 reads and a `GQ` of 99, so her absence of the variant is a measured result rather than a gap. The son's genotype fits, one copy from each parent. 814 rows carry an explicit `0/0` like this for at least one person, and `"$BCFTOOLS" view -H -i 'GT[*]="RR"' cohort.vcf.gz | wc -l` counts them.

Each person's genotypes split as the table shows.

| Genotype | HG002 (son) | HG003 (father) | HG004 (mother) |
|---|---|---|---|
| `0/0`, matches the reference | 386 | 223 | 406 |
| `0/1`, one copy carries it | 593 | 839 | 728 |
| `1/1`, both copies carry it | 414 | 331 | 260 |
| `./.`, no call | 12 | 10 | 8 |

A few rows in each column carry a second alternate allele, such as `1/2`, which is why each column adds up to a little less than the 1,433 rows.

`bcftools` includes a plugin, `+mendelian2`, that checks every row against the rules of inheritance, given the son, the father, and the mother in that order.

```bash
"$BCFTOOLS" +mendelian2 cohort.vcf.gz -p HG002,HG003,HG004
```

It reports 1,385 rows consistent with inheritance, 25 inconsistent, and 27 with a missing genotype in at least one person. Most of the 25 inconsistent rows are insertions or deletions inside repeats, called from a handful of reads with a `GQ` in single or low double figures, such as position 14,155, where the son is `1/1` from a single read. Adding `-i 'MIN(FMT/GQ)>=20'` to the command checks only the rows where every person's `GQ` is at least 20, and leaves 4 inconsistencies. Two are deletions in a run of repeated `TA` near position 117,590, and one is a deletion at 392,438, the first of four changes within 20 bases where the son reads as the reference and both parents as homozygous for the change. Repeats and tight clusters of changes like these are where short reads most often map or genotype wrongly, and finding them is how a trio catches genotyping errors.

The fourth is different. At position 429,138, 10,429,137 on the whole of chromosome 20, the son is `0/1` with 13 of 29 reads carrying a T, and both parents are `0/0` with 34 and 29 reads and a `GQ` of 99 and 81. A variant in a child that neither parent carries breaks the rules of inheritance by definition, and when the calls are this confident it is a candidate de novo variant, one that arose new in the child. HG002's own benchmark also lists this position as heterozygous, and neither parent's benchmark lists it, so the call is supported, though the benchmark does not itself say the change is new. Confirming one takes a second method, such as sequencing the three samples again.

Every row's FILTER column reads a bare `.`, meaning no filter was applied, not that the row passed. Joint genotyping applies no quality filters, and [Filtering, Selecting, and Metrics](03-filtering-selecting-and-metrics.md) covers the step that does, as [Three kinds of filter](../01-foundations/05-variants-and-vcf.md#three-kinds-of-filter) sets out.

### The run record

The sidecar holds one entry per GATK step, each with its full command, exit code, wall time, and GATK version, plus a [checksum](../../GLOSSARY.md#checksum), a fingerprint computed from a file's contents, for each file. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Cite the sidecar in a methods section rather than retyping the command from memory. A failed run removes the result files it created and leaves only the sidecar, marked `failed` with the failing step's exit code.

The GenomicsDB route writes a folder instead of a combined GVCF, holding GATK's own bookkeeping files. Delete it once the cohort VCF exists, unless you plan to add samples to the same store.

## What good looks like

Every sample you passed should appear as a column. `bcftools query -l cohort.vcf.gz` lists the names, `HG002`, `HG003`, and `HG004` here. A missing sample usually means a `--gvcf` flag was left out.

The row count should sit well above any one person's and far below the GVCFs'. `"$BCFTOOLS" view -H cohort.vcf.gz | wc -l` counts the rows, 1,433 here against HG002's 1,026 alone and 48,057 to 69,694 in each GVCF. A cohort VCF within a few fold of its input GVCFs suggests an ordinary VCF was passed where a GVCF was expected.

The combining tool in the preview should be the one you meant, since a mistyped strategy falls back to `auto` without a warning.

The lowest `QUAL` should sit at or above 30. `"$BCFTOOLS" query -f '%QUAL\n' cohort.vcf.gz | sort -g | head -1` prints it. A lower value means the file did not come from this command.

For a family, most rows should be consistent with inheritance, 1,385 of 1,433 here, and nearly all the inconsistent ones should be low-quality calls, 21 of the 25 here. Many confident inconsistencies usually mean the samples were labelled wrongly, a parent swapped with an unrelated person.

Do not read a bare `.` in the FILTER column as a pass.

## On the command line

The whole chapter is one block, run from `LGE GATK` with the variables from [Reference Files for GATK](04-reference-packs.md#before-you-start) set. A larger cohort adds one `--gvcf` per sample and nothing else. Every flag is listed under [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference.

```bash
for SAMPLE in HG002 HG003 HG004; do
  lungfish-cli gatk haplotype-caller --reference GRCh38.chr20.10.0-10.5Mb.fasta \
      --bam "$SAMPLE.sorted.bam" --output "$SAMPLE.g.vcf.gz" --execute
done

lungfish-cli gatk joint-genotype \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --gvcf HG002.g.vcf.gz --gvcf HG003.g.vcf.gz --gvcf HG004.g.vcf.gz \
    --intermediate cohort.combined.g.vcf.gz \
    --output cohort.vcf.gz \
    --execute

"$BCFTOOLS" +mendelian2 cohort.vcf.gz -p HG002,HG003,HG004
```

## Next

The cohort VCF is unfiltered. Continue to [Filtering, Selecting, and Metrics](03-filtering-selecting-and-metrics.md), which marks calls not worth trusting, pulls out one person or one variant type, and summarises the finished call set.
