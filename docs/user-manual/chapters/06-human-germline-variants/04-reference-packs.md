---
title: Reference Packs for GATK
chapter_id: 06-human-germline-variants/04-reference-packs
audience: power-user
prereqs: [01-foundations/07-plugin-packs]
estimated_reading_min: 5
task: Understand the reference files expected by Lungfish GATK dry-run commands.
tags: [gatk, reference, grch38, known-sites, dry-run]
tools: [gatk]
entry_points: []
shots: []
illustrations: []
glossary_refs: [reference-bundle, plugin-pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

GATK human germline workflows depend on more than a FASTA. A practical
reference pack usually contains:

| File | Why GATK needs it |
|---|---|
| `GRCh38.fa` | Reference sequence passed with `-R` |
| `GRCh38.fa.fai` | FASTA index used for random access |
| `GRCh38.dict` | Sequence dictionary used by Picard and metrics tools |
| `dbsnp.vcf.gz` | Known variation for BQSR and metrics |
| `known_indels.vcf.gz` | Known indels for BQSR |
| interval list or BED | Optional targeted-capture or panel regions |

Lungfish does not ship a human reference pack in this dry-run slice. Keep
the files under explicit project or lab storage, record their source, and
pass absolute paths when constructing commands:

```bash
lungfish gatk bqsr \
  --reference /refs/grch38/GRCh38.fa \
  --bam sample.markdup.bam \
  --known-sites /refs/grch38/dbsnp.vcf.gz \
  --known-sites /refs/grch38/known_indels.vcf.gz \
  --recal-table sample.recal.table \
  --output sample.bqsr.bam
```

## Plugin Pack

Install `gatk-core` before using these commands on a machine where GATK is
not already available through Lungfish:

```bash
lungfish conda install --pack gatk-core
```

The pack pins `bioconda::gatk4=4.6.2.0` and verifies it with
`gatk --version`. Installing the pack is not the same as executing a
workflow. The current CLI only prints commands; future execution must
record final-output provenance in the bundle.
