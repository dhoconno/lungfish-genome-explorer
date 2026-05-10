---
title: Joint Genotyping Dry Runs
chapter_id: 06-human-germline-variants/02-joint-genotyping
audience: power-user
prereqs: [06-human-germline-variants/01-haplotype-caller]
estimated_reading_min: 5
task: Construct GATK joint-genotyping commands for a cohort of GVCFs.
tags: [gatk, genotypegvcfs, combinegvcfs, genomicsdb, dry-run, cli]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk joint-genotype"
shots: []
illustrations: []
glossary_refs: [VCF, plugin-pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

!!! note "Coming soon"
    Human germline variant support is in active development. The pages in this section document the dry-run CLI commands available today. Full execution workflows, GUI integration, and expanded documentation are on the way.

## What it is

Joint genotyping turns per-sample GVCFs into a cohort VCF. Lungfish can
construct the command sequence without running it:

```bash
lungfish gatk joint-genotype \
  --reference GRCh38.fa \
  --gvcf sample1.g.vcf.gz \
  --gvcf sample2.g.vcf.gz \
  --intermediate cohort.combined.g.vcf.gz \
  --output cohort.vcf.gz
```

With `--combine-strategy auto`, Lungfish chooses `CombineGVCFs` for cohorts
up to 50 samples and `GenomicsDBImport` above that threshold, followed by
`GenotypeGVCFs`. You can force either path:

```bash
lungfish gatk joint-genotype \
  --reference GRCh38.fa \
  --gvcf sample1.g.vcf.gz \
  --gvcf sample2.g.vcf.gz \
  --intermediate genomicsdb-workspace \
  --output cohort.vcf.gz \
  --combine-strategy genomicsdb \
  --intervals exome.interval_list
```

`--extra-args` is appended to the final `GenotypeGVCFs` command. Use it for
advanced annotations or confidence settings that are not first-class
Lungfish options yet.

## Scope

These dry runs do not import GenomicsDB workspaces, write VCFs, or attach
variant tracks. Any future execution workflow must preserve provenance for
each emitted GATK command and for the final stored cohort VCF.
