---
title: Filtering, Selecting, and Metrics
chapter_id: 06-human-germline-variants/03-filtering-selecting-and-metrics
audience: power-user
prereqs: [06-human-germline-variants/02-joint-genotyping]
estimated_reading_min: 7
task: Filter, subset, normalize, tabulate, and report on a cohort VCF with GATK.
tags: [gatk, variantfiltration, selectvariants, variantstotable, metrics, cli]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk filter"
  - "CLI: lungfish gatk select"
  - "CLI: lungfish gatk variants-to-table"
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

!!! note "Preview feature (experimental)"
    By default each command below prints the GATK command it would run; add
    `--execute` to run GATK4 and write provenance. See
    [HaplotypeCaller](01-haplotype-caller.md) for the full
    preview-versus-`--execute` model and the `isDryRun = !execute || dryRun`
    rule.

## What it is

After joint genotyping you usually clean up the cohort VCF: flag low-quality
records, pull out one sample or one variant class, normalize indel
representation, export a flat table, and collect summary metrics. Lungfish
wraps the standard GATK and Picard tools for each of these. By default a
command is printed for review; add `--execute` to run it and attach
provenance.

`filter` builds `VariantFiltration`, and `select` builds `SelectVariants`:

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

The `filter` preset is one of `best-practices-snp`, `best-practices-indel`,
or `best-practices-both` (the default), each applying GATK's recommended
hard-filter expressions for that variant class. The `select --type` value is
`SNP`, `INDEL`, or `MIXED`; both `--sample` and `--type` are optional.

In practice, preview each command to confirm its flags, then re-run with
`--execute` so every cleanup step lands a provenance record alongside its
output.

## Normalizing and tabulating

`leftalign` builds `LeftAlignAndTrimVariants` for normalization, which
left-shifts and trims indels to a canonical representation so the same indel
is written the same way across callers:

```bash
lungfish gatk leftalign \
  --reference GRCh38.fa \
  --vcf cohort.filtered.vcf.gz \
  --output cohort.leftaligned.vcf.gz \
  --split-multi-allelics
```

`--split-multi-allelics` splits multi-allelic records into one row per
allele. Two numeric defaults govern which indels are normalized, and they are
load-bearing for clinical work: an indel longer than `--max-indel-length`
(default `200`) or one needing more than `--max-leading-bases` (default
`1000`) of left shift falls outside the default window. If you call long
indels, raise these before you rely on the output.

`variants-to-table` builds `VariantsToTable`, exporting selected fields to a
TSV for downstream analysis or review. The default field set is
`CHROM,POS,REF,ALT,QUAL,AF,DP`; override it with `--fields`:

```bash
lungfish gatk variants-to-table \
  --vcf cohort.filtered.vcf.gz \
  --fields "CHROM,POS,REF,ALT,QUAL,AF,DP,AC,AN" \
  --output cohort.table.tsv
```

## Collecting metrics

`collect-metrics` builds Picard `CollectVariantCallingMetrics` through GATK,
producing summary and detail metrics files against a dbSNP reference (dbSNP is
NCBI's database of known human variation, used here to separate novel from
known sites):

```bash
lungfish gatk collect-metrics \
  --vcf cohort.vcf.gz \
  --dbsnp dbsnp.vcf.gz \
  --sequence-dictionary GRCh38.dict \
  --output-prefix metrics/cohort
```

Pass `--gvcf-input` when the input is a GVCF rather than a genotyped VCF.
Every command in this chapter accepts `--extra-args` for advanced GATK or
Picard options written verbatim.

Where this matters: normalize before you compare or merge VCFs, export a
table when you need the calls outside Lungfish, and run `collect-metrics` to
get the cohort's titration of known versus novel sites.
On `--execute`, each command writes its output plus a provenance record
capturing the GATK command, environment identity, checksums, exit status, and
wall time.
