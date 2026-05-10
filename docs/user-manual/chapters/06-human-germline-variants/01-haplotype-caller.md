---
title: HaplotypeCaller Dry Runs
chapter_id: 06-human-germline-variants/01-haplotype-caller
audience: power-user
prereqs: [01-foundations/05-variants-and-vcf, 01-foundations/07-plugin-packs]
estimated_reading_min: 5
task: Construct a GATK HaplotypeCaller command without executing it.
tags: [gatk, haplotypecaller, germline, dry-run, cli]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk haplotype-caller"
shots: []
illustrations: []
glossary_refs: [VCF, plugin-pack, reference-bundle]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is the first Lungfish bridge into human germline variant
workflows. The command below constructs a GATK4 HaplotypeCaller invocation
with Lungfish defaults, but it does not run GATK and does not create a VCF:

```bash
lungfish gatk haplotype-caller \
  --reference GRCh38.fa \
  --bam sample.markdup.bqsr.bam \
  --output sample.g.vcf.gz
```

The printed command uses `HaplotypeCaller`, emits GVCF by default, sets
sample ploidy to `2`, and includes explicit defaults for the main tuning
flags Lungfish exposes. Use `--extra-args` when you need a GATK option that
Lungfish has not promoted yet:

```bash
lungfish gatk haplotype-caller \
  --reference GRCh38.fa \
  --bam sample.bam \
  --output sample.g.vcf.gz \
  --intervals exome.interval_list \
  --extra-args "--annotation Coverage"
```

## Scope

This is command construction only. Because no scientific output is written,
there is no output bundle provenance to record yet. The future execution
workflow must record the exact GATK command, environment identity, inputs,
outputs, checksums, sizes, exit status, wall time, and useful stderr in the
final `.lungfish*` bundle.
