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

Joint genotyping gathers the per-sample GVCFs from
[HaplotypeCaller](01-haplotype-caller.md) into one cohort VCF, so genotypes
are called across the whole cohort at once instead of sample by sample. By
default Lungfish prints the command sequence. Add `--execute` and it runs each
GATK step in order through the managed `gatk-core` environment and writes
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

With `--combine-strategy auto` (the default), Lungfish picks `CombineGVCFs`
for cohorts of 50 samples or fewer and `GenomicsDBImport` above that
threshold, then runs `GenotypeGVCFs`. GenomicsDB is GATK's on-disk
multi-sample store, and it scales to large cohorts far better than a single
combined GVCF. The 50-sample line is where `auto` flips between the two.

You can force any of the three strategy values: `auto`, `combine-gvcfs`, or
`genomicsdb`. Pin `combine-gvcfs` or `genomicsdb` when you want the same
behaviour no matter the sample count, say in a reproducible pipeline that must
never flip strategies at the 50-sample boundary:

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

Force `genomicsdb` and you pass a workspace directory path to
`--intermediate`; force `combine-gvcfs` and you pass a combined GVCF path.
`--extra-args` is appended to the final `GenotypeGVCFs` command, so reach for
it when you want advanced annotations or confidence settings that are not
first-class Lungfish options.

The practical takeaway: preview to see which strategy `auto` picks for your
cohort size, then re-run with `--execute` (or pin the strategy yourself) to
write the cohort VCF.

## Provenance

On `--execute`, `GATKPipelineExecutor` runs every command in the combine plus
genotype sequence in order and writes one provenance record for the whole run,
capturing each GATK command, the environment identity, inputs, outputs,
checksums, sizes, exit status, and wall time. When it finishes, the CLI prints
the GATK exit code and `Provenance: <path>`. No "future" provenance step waits
in the wings: execution records the cohort VCF's lineage today.
