---
title: Filtering, Selecting, and Metrics Dry Runs
chapter_id: 06-human-germline-variants/03-filtering-selecting-and-metrics
audience: power-user
prereqs: [06-human-germline-variants/02-joint-genotyping]
estimated_reading_min: 6
task: Construct post-calling GATK commands for VCF cleanup and reporting.
tags: [gatk, variantfiltration, selectvariants, metrics, dry-run, cli]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk filter"
  - "CLI: lungfish gatk select"
  - "CLI: lungfish gatk leftalign"
  - "CLI: lungfish gatk collect-metrics"
shots: []
illustrations: []
glossary_refs: [VCF]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish exposes dry-run builders for the common post-calling commands:

```bash
lungfish gatk filter \
  --vcf cohort.vcf.gz \
  --preset best-practices-both \
  --output cohort.filtered.vcf.gz

lungfish gatk select \
  --vcf cohort.filtered.vcf.gz \
  --sample HG00096 \
  --type SNP \
  --output HG00096.snps.vcf.gz
```

`leftalign` constructs `LeftAlignAndTrimVariants` for normalization:

```bash
lungfish gatk leftalign \
  --reference GRCh38.fa \
  --vcf cohort.filtered.vcf.gz \
  --output cohort.leftaligned.vcf.gz \
  --split-multi-allelics
```

`collect-metrics` constructs Picard `CollectVariantCallingMetrics` through
GATK:

```bash
lungfish gatk collect-metrics \
  --vcf cohort.vcf.gz \
  --dbsnp dbsnp.vcf.gz \
  --sequence-dictionary GRCh38.dict \
  --output-prefix metrics/cohort
```

Each command accepts `--extra-args` for advanced GATK or Picard options.
The printed command is meant for review, logging, and workflow integration
tests before real execution support is added.

## Scope

These commands do not write normalized VCFs, filtered VCFs, tables, or
metrics files. Missing provenance would be a blocking defect once execution
is implemented.
