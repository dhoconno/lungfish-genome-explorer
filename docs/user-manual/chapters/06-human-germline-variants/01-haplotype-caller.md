---
title: HaplotypeCaller
chapter_id: 06-human-germline-variants/01-haplotype-caller
audience: power-user
prereqs: [01-foundations/05-variants-and-vcf, 01-foundations/07-plugin-packs]
estimated_reading_min: 6
task: Call germline SNPs and indels with GATK HaplotypeCaller from the CLI or the GUI.
tags: [gatk, haplotypecaller, germline, preview, cli, gui]
tools: [gatk]
entry_points:
  - "CLI: lungfish gatk haplotype-caller"
  - "GUI: BAM variant-calling dialog -> GATK HaplotypeCaller"
shots: []
illustrations: []
glossary_refs: [VCF, gvcf, bqsr, plugin-pack, reference-bundle, provenance, variant-caller]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

!!! note "Preview feature (experimental)"
    Human germline variant support is a power-user preview. By default each
    `lungfish gatk` command prints the GATK command it would run, so you can
    review and log it. Add `--execute` to actually run GATK4 in the managed
    `gatk-core` environment; Lungfish writes full provenance for the run. The
    `gatk-core` pack is flagged experimental, so validate results before you
    rely on them.

## What it is

This chapter is the first Lungfish bridge into human germline variant
workflows. GATK4 HaplotypeCaller is the Broad Institute's
local-reassembly caller for germline single-nucleotide variants and short
indels. Lungfish wraps it with sensible defaults and runs it for you.

By default the command below prints a GATK4 HaplotypeCaller invocation with
Lungfish defaults and does not run GATK. Add `--execute` to run it: Lungfish
launches GATK in the managed `gatk-core` environment, writes the GVCF
(genomic VCF: per-position reference confidence, the form HaplotypeCaller
emits for later joint genotyping), and records provenance. Add `--dry-run`
to force a preview even when `--execute` is present.

```bash
lungfish gatk haplotype-caller \
  --reference GRCh38.fa \
  --bam sample.markdup.bqsr.bam \
  --output sample.g.vcf.gz
# add --execute to run; omit it to preview the command only
```

The constructed command uses `HaplotypeCaller`, emits a GVCF by default
(`--emit-ref-confidence GVCF`), and sets sample ploidy to `2`. Use
`--extra-args` when you need a GATK option Lungfish has not promoted yet. The
text inside the quotes is passed to GATK verbatim:

```bash
lungfish gatk haplotype-caller \
  --reference GRCh38.fa \
  --bam sample.bam \
  --output sample.g.vcf.gz \
  --intervals exome.interval_list \
  --extra-args "--annotation Coverage"
```

In practice, preview first to confirm the command, then re-run with
`--execute` to produce a real GVCF with provenance attached.

## Preview versus execute

Three flag combinations control whether GATK runs. The rule in code is
`isDryRun = !execute || dryRun`: you must pass `--execute`, and `--dry-run`
always wins if both are present.

| Flags passed | Behaviour |
|---|---|
| (none) | Preview. Prints the GATK command. Writes nothing. |
| `--execute` | Runs GATK4 in `gatk-core`. Writes the output and provenance. |
| `--execute --dry-run` | Preview. `--dry-run` overrides `--execute`. |

On `--execute`, Lungfish runs GATK through the managed environment and prints
two lines: the GATK exit code and `Provenance: <path>`. The provenance record
captures the exact GATK command, the environment identity, inputs, outputs,
checksums, sizes, exit status, wall time, and stderr. This is the same
provenance bar the rest of Lungfish meets, and it is written today, not
"on the way".

If GATK exits nonzero, the `lungfish` process also exits nonzero: the failure
surfaces as an error and a failure provenance record is still written, so a
CI step can branch on the wrapper's own exit status rather than scraping the
printed exit-code line.

## Promoted defaults

Lungfish promotes the HaplotypeCaller flags below to first-class options, so
you reach for `--extra-args` only for flags this table does not cover. Each
shows its default; override any of them on the command line.

| Flag | Default | What it sets |
|---|---|---|
| `--emit-ref-confidence` | `GVCF` | GVCF output, or `NONE` for a final genotyped VCF |
| `--ploidy` | `2` | Sample ploidy |
| `--pcr-indel-model` | `CONSERVATIVE` | PCR-error model for indels |
| `--stand-call-conf` | `30.0` | Calling-confidence threshold (used in `NONE` mode) |
| `--max-alternate-alleles` | `6` | Maximum alternate alleles per site |
| `--pair-hmm-threads` | `4` | Native PairHMM threads |

The `--stand-call-conf` threshold only takes effect when
`--emit-ref-confidence NONE` produces a genotyped VCF; in GVCF mode GATK
defers calling to the joint-genotyping step (see
[joint genotyping](02-joint-genotyping.md)).

## From the GUI

HaplotypeCaller also runs from the project window, not only the CLI. Open a
bundle that has a BAM track, open the BAM variant-calling dialog, and choose
**GATK HaplotypeCaller** ("Germline SNP and indel calling with standard VCF
genotypes"). Lungfish runs HaplotypeCaller on the selected alignment track,
writes `variants/gatk/<id>.vcf.gz` inside the bundle, and attaches the result
as a variant track you can browse in the viewport. The run is logged in the
Operations Panel with its provenance, exactly like the CLI `--execute` path.

A second GUI tool, **GATK + WhatsHap Phased** ("Phase-aware HaplotypeCaller
plus WhatsHap command plan"), pairs HaplotypeCaller with read-backed phasing;
it requires both the `gatk-core` pack and the `phasing` pack.

One behavioural difference is worth pinning down before you compare outputs:
the GUI tool emits a final genotyped VCF (`--emit-ref-confidence NONE`),
whereas the CLI defaults to a GVCF. If a GUI VCF and a CLI GVCF look
different at the same site, that default is usually why; pass
`--emit-ref-confidence NONE` to the CLI to match the GUI, or feed the CLI
GVCF through joint genotyping to reach a comparable genotyped VCF.

The practical takeaway: use the GUI tool for a quick single-sample
genotyped VCF attached to a bundle, and the CLI GVCF path when you plan to
joint-genotype a cohort.
