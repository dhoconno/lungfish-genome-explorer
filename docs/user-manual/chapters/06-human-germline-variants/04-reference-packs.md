---
title: Reference Files for GATK
chapter_id: 06-human-germline-variants/04-reference-packs
audience: power-user
prereqs: [01-foundations/07-plugin-packs]
estimated_reading_min: 5
task: Assemble the reference files GATK germline commands expect, and install the gatk-core pack.
tags: [gatk, reference, grch38, known-sites, bqsr]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk bqsr"
  - "CLI: lungfish conda install --pack gatk-core"
  - "CLI: lungfish conda install --pack phasing"
shots: []
illustrations: []
glossary_refs: [reference-bundle, plugin-pack, bqsr]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

!!! note "Preview feature (experimental)"
    GATK germline support is a power-user preview. The `gatk` commands preview
    by default and run on `--execute`; see
    [HaplotypeCaller](01-haplotype-caller.md) for that model. The `gatk-core`
    pack is flagged experimental, so validate results before you rely on them.

## What it is

"Reference pack" is a convenience name this manual uses for the set of files
GATK germline workflows expect on disk. It is not a Lungfish object. No
`lungfish` command installs, downloads, validates, or enforces a "reference
pack", and no such symbol lives in the app. Picture a recommended folder
layout you assemble yourself, not something you pull from a server.

GATK human germline workflows lean on more than a FASTA. A practical reference
layout usually holds:

| File | Why GATK needs it |
|---|---|
| `GRCh38.fa` | Reference sequence passed with `-R` |
| `GRCh38.fa.fai` | FASTA index used for random access |
| `GRCh38.dict` | Sequence dictionary used by Picard and metrics tools |
| `dbsnp.vcf.gz` | Known variation for BQSR and metrics |
| `known_indels.vcf.gz` | Known indels for BQSR |
| interval list or BED | Optional targeted-capture or panel regions |

Lungfish does not ship a human reference layout. Keep these files under
explicit project or lab storage, note where each one came from, and pass
absolute paths when you build commands. The example below previews a BQSR
(base quality score recalibration: GATK's correction of systematic sequencer
quality errors using known sites) command. Add `--execute` to run it:

```bash
lungfish gatk bqsr \
  --reference /refs/grch38/GRCh38.fa \
  --bam sample.markdup.bam \
  --known-sites /refs/grch38/dbsnp.vcf.gz \
  --known-sites /refs/grch38/known_indels.vcf.gz \
  --recal-table sample.recal.table \
  --output sample.bqsr.bam
```

`--known-sites` is repeatable, so pass dbSNP, Mills, and any cohort resources
as separate flags. Two more `bqsr` options are worth knowing. `--intervals`
restricts recalibration to a region list, and `--create-output-bam-index`
(default `true`) decides whether ApplyBQSR writes a BAM index.

Build this folder once per reference genome, note each file's source in your
own records, and point the absolute paths at it from every `gatk` command.

## Plugin pack

Install the `gatk-core` pack before running these commands on a machine where
GATK is not already available through Lungfish:

```bash
lungfish conda install --pack gatk-core
```

The pack pins `bioconda::gatk4=4.6.2.0` and verifies it with `gatk --version`.
Two facts are worth weighing before you install. The pack is flagged
experimental, which keeps it out of validated or clinical use until you have
qualified it yourself. And the download runs roughly 600 MB, which stings when
students pull it over shared lab wifi.

The phased GUI tool (**GATK + WhatsHap Phased**, see
[HaplotypeCaller](01-haplotype-caller.md)) needs a second pack alongside
`gatk-core`. Install it the same way:

```bash
lungfish conda install --pack phasing
```

The `phasing` pack provides WhatsHap (`bioconda::whatshap=2.3`) and is also
flagged experimental.

Installing the pack provisions GATK. It does not run a workflow. Running a
workflow is a separate step: a `gatk` command with `--execute`, which runs
GATK in this environment and records final-output provenance in the bundle
(see [HaplotypeCaller](01-haplotype-caller.md)).
