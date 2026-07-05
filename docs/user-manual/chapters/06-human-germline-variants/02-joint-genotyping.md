---
title: Joint Genotyping
chapter_id: 06-human-germline-variants/02-joint-genotyping
audience: power-user
prereqs: [06-human-germline-variants/01-haplotype-caller]
estimated_reading_min: 5
task: Combine per-sample GVCFs into a cohort VCF with GATK joint genotyping.
tags: [gatk, genotypegvcfs, combinegvcfs, genomicsdb, joint-genotyping, cli]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk joint-genotype"
shots: []
illustrations: []
glossary_refs: [VCF, gvcf, genomicsdb, joint-genotyping, plugin-pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

!!! note "Preview feature (experimental)"
    By default `lungfish gatk joint-genotype` prints the GATK commands it
    would run; add `--execute` to run GATK4 and write provenance. See
    [HaplotypeCaller](01-haplotype-caller.md) for the full preview-versus-`--execute`
    model and the `isDryRun = !execute || dryRun` rule.

## What it is

Joint genotyping turns the per-sample GVCFs from
[HaplotypeCaller](01-haplotype-caller.md) into one cohort VCF, so genotypes
are called across the whole cohort at once rather than sample by sample. By
default Lungfish prints the command sequence; add `--execute` to run each
GATK step in order through the managed `gatk-core` environment and write
provenance for the multi-step run.

```bash
lungfish gatk joint-genotype \
  --reference GRCh38.fa \
  --gvcf sample1.g.vcf.gz \
  --gvcf sample2.g.vcf.gz \
  --intermediate cohort.combined.g.vcf.gz \
  --output cohort.vcf.gz
# add --execute to run the combine + genotype sequence
```

With `--combine-strategy auto` (the default), Lungfish chooses `CombineGVCFs`
for cohorts of 50 samples or fewer and `GenomicsDBImport` above that
threshold, followed by `GenotypeGVCFs`. GenomicsDB is GATK's on-disk
multi-sample store, which scales to large cohorts better than a single
combined GVCF. The 50-sample boundary is where `auto` switches strategies.

You can force any of the three strategy values: `auto`, `combine-gvcfs`, or
`genomicsdb`. Pin `combine-gvcfs` or `genomicsdb` when you want deterministic
behaviour regardless of sample count, for example in a reproducible pipeline
that must not flip strategies at the 50-sample boundary:

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

When you force `genomicsdb`, pass a workspace directory path to
`--intermediate`; when you force `combine-gvcfs`, pass a combined GVCF path.
`--extra-args` is appended to the final `GenotypeGVCFs` command; use it for
advanced annotations or confidence settings that are not first-class Lungfish
options.

The practical takeaway: preview to confirm which strategy `auto` picks for
your cohort size, then re-run with `--execute` (or pin the strategy
explicitly) to write the cohort VCF.

## Provenance

On `--execute`, `GATKPipelineExecutor` runs every command in the combine plus
genotype sequence in order and writes one provenance record for the run,
capturing each GATK command, the environment identity, inputs, outputs,
checksums, sizes, exit status, and wall time. The CLI prints the GATK exit
code and `Provenance: <path>` when it finishes. There is no "future"
provenance step to wait for: execution records the cohort VCF's lineage
today.
