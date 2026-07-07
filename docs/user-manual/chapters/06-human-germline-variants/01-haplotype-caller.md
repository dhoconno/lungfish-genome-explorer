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

This chapter is where Lungfish first reaches into human germline work. GATK4
HaplotypeCaller is the Broad Institute's local-reassembly caller for germline
single-nucleotide variants and short indels. Lungfish wraps it in sensible
defaults and drives it for you.

Run the command below as written and nothing touches your data. Lungfish
prints the GATK4 HaplotypeCaller invocation it would issue, defaults and all,
then stops. Add `--execute` and it acts: Lungfish launches GATK in the managed
`gatk-core` environment, writes the GVCF (genomic VCF: per-position reference
confidence, the form HaplotypeCaller emits for later joint genotyping), and
records provenance. Add `--dry-run` to force a preview even when `--execute`
is present.

```bash
lungfish gatk haplotype-caller \
  --reference GRCh38.fa \
  --bam sample.markdup.bqsr.bam \
  --output sample.g.vcf.gz
# add --execute to run; omit it to preview the command only
```

The command Lungfish builds calls `HaplotypeCaller`, emits a GVCF by default
(`--emit-ref-confidence GVCF`), and sets sample ploidy to `2`. Reach for
`--extra-args` when you need a GATK option Lungfish has not promoted yet.
Whatever sits inside the quotes passes to GATK verbatim:

```bash
lungfish gatk haplotype-caller \
  --reference GRCh38.fa \
  --bam sample.bam \
  --output sample.g.vcf.gz \
  --intervals exome.interval_list \
  --extra-args "--annotation Coverage"
```

The habit is simple. Preview first to read the command back, then re-run with
`--execute` to produce a real GVCF with provenance attached.

## Preview versus execute

Three flag combinations decide whether GATK runs. The rule in the code is
`isDryRun = !execute || dryRun`: you must pass `--execute`, and `--dry-run`
wins whenever both are present.

| Flags passed | Behaviour |
|---|---|
| (none) | Preview. Prints the GATK command. Writes nothing. |
| `--execute` | Runs GATK4 in `gatk-core`. Writes the output and provenance. |
| `--execute --dry-run` | Preview. `--dry-run` overrides `--execute`. |

On `--execute`, Lungfish runs GATK through the managed environment and prints
two lines: the GATK exit code and `Provenance: <path>`. That provenance record
holds the exact GATK command, the environment identity, inputs, outputs,
checksums, sizes, exit status, wall time, and stderr. It clears the same
provenance bar as the rest of Lungfish, and it lands on disk now, not
"on the way".

When GATK exits nonzero, the `lungfish` process exits nonzero too. The failure
surfaces as an error, a failure provenance record is still written, and a CI
step can branch on the wrapper's own exit status instead of scraping the
printed exit-code line.

## Promoted defaults

Lungfish lifts the HaplotypeCaller flags below to first-class options, so
`--extra-args` is only for flags this table leaves out. Each row shows its
default. Override any of them on the command line.

| Flag | Default | What it sets |
|---|---|---|
| `--emit-ref-confidence` | `GVCF` | GVCF output, or `NONE` for a final genotyped VCF |
| `--ploidy` | `2` | Sample ploidy |
| `--pcr-indel-model` | `CONSERVATIVE` | PCR-error model for indels |
| `--stand-call-conf` | `30.0` | Calling-confidence threshold (used in `NONE` mode) |
| `--max-alternate-alleles` | `6` | Maximum alternate alleles per site |
| `--pair-hmm-threads` | `4` | Native PairHMM threads |

The `--stand-call-conf` threshold bites only when `--emit-ref-confidence NONE`
produces a genotyped VCF. In GVCF mode GATK holds off and defers the call to
the joint-genotyping step (see [joint genotyping](02-joint-genotyping.md)).

## From the GUI

HaplotypeCaller is not CLI-only; it runs straight from the project window.
Open a bundle that carries a BAM track, open the BAM variant-calling dialog,
and choose **GATK HaplotypeCaller** ("Germline SNP and indel calling with
standard VCF genotypes"). Lungfish runs HaplotypeCaller on the selected
alignment track, writes `variants/gatk/<id>.vcf.gz` inside the bundle, and
attaches the result as a variant track you can browse in the viewport. The
Operations Panel logs the run with its provenance, exactly like the CLI
`--execute` path.

A second GUI tool, **GATK + WhatsHap Phased** ("Phase-aware HaplotypeCaller
plus WhatsHap command plan"), pairs HaplotypeCaller with read-backed phasing.
It needs both the `gatk-core` pack and the `phasing` pack.

One behavioural difference is worth pinning down before you compare outputs.
The GUI tool emits a final genotyped VCF (`--emit-ref-confidence NONE`); the
CLI defaults to a GVCF. When a GUI VCF and a CLI GVCF disagree at the same
site, that default is usually the reason. Pass `--emit-ref-confidence NONE` to
the CLI to match the GUI, or feed the CLI GVCF through joint genotyping to
reach a comparable genotyped VCF.

The practical takeaway: reach for the GUI tool when you want a quick
single-sample genotyped VCF attached to a bundle, and the CLI GVCF path when
you plan to joint-genotype a cohort.
