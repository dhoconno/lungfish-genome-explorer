---
title: Consensus and Lineage
chapter_id: 05-variants/05-consensus-and-lineage
audience: bench-scientist
prereqs: [05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 9
task: Produce a consensus FASTA from reads or an alignment and hand it to external tools for lineage assignment.
tags: [variants, consensus, lineage, pangolin, nextclade, freyja, viralrecon]
tools: [ivar, bcftools, samtools, freyja]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Viral Recon (consensus caller)"
  - "CLI: lungfish msa consensus"
  - "Inspector consensus mode on an alignment track"
shots: []
planned_shots:
  - id: viralrecon-consensus-picker
    caption: "The Viral Recon wizard with the Consensus caller picker set for the end-to-end surveillance consensus path."
  - id: inspector-consensus-mode
    caption: "The Inspector consensus controls on an alignment track: consensus mode, IUPAC ambiguity, gap masking, and the depth and quality minimums."
  - id: msa-consensus-cli
    caption: "A lungfish msa consensus run writing a consensus FASTA from an aligned bundle with an explicit threshold."
illustrations: []
glossary_refs: [VCF, allele-frequency, consensus-fasta, lineage, freyja]
# This chapter documents consensus and lineage, not the variant caller, so it
# carries no variants.call ref. features.yaml has no consensus/viralrecon/msa/
# freyja entry yet; once the cartographer adds one, point features_refs here.
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A consensus FASTA is the reference sequence with your sample's high-confidence variants applied in place. Where the reads call a confident base, the consensus carries it; where the reads do not give a confident call (low coverage, mixed signal, or no read at all), the consensus carries an `N` mask. The result is a single sequence, the same length as the reference, that represents what your sample looks like as a genome rather than as a list of differences.

Consensus is the format that downstream lineage and clade tools expect. Pangolin assigns SARS-CoV-2 Pango lineages from a consensus FASTA. Nextclade assigns Nextstrain clades and flags amino-acid changes from a consensus FASTA. GISAID and NCBI both accept a consensus FASTA as the surveillance deposit format. None of these tools accept a VCF directly, which is why the consensus step exists between variant calling and lineage reporting.

It is worth being precise about where consensus comes from in Lungfish, because it is easy to assume the variant caller produces it. It does not. The iVar Variant Calling step from [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md) writes a VCF, a tabix index, and a SQLite store; it does not write a consensus FASTA, and the dialog's consensus allele-frequency field controls how iVar merges adjacent codon SNPs into one VCF row, not where a base is masked as `N`. Lungfish produces a consensus FASTA on three other surfaces: the Viral Recon wizard (end to end from reads), `lungfish msa consensus` (from an alignment of sequences), and the Inspector's consensus mode (a quick region preview over a BAM). In practice, pick the surface that matches your inputs, produce the consensus FASTA there, then hand that file to Pangolin or Nextclade for lineage, because Lungfish does not assign lineages itself.

## What you will learn

By the end of this chapter you will know which of the three consensus surfaces fits your inputs, be able to set a consensus threshold with an understanding of what it means biologically, produce a consensus FASTA from reads with the Viral Recon wizard or from an alignment with `lungfish msa consensus`, run that consensus through Pangolin or Nextclade, and (for mixed wastewater samples) reach for `lungfish freyja demix` instead of a single-consensus call.

## Before you start

Each consensus surface starts from a different artefact, so the input you need depends on the path you take. Note that a VCF is not one of them: a consensus is built from reads or aligned bases, not from a variant list, so arriving here from [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md) with only a VCF is not enough on its own.

- Viral Recon wizard: raw reads (FASTQ) plus the reference and primer scheme for the run.
- `lungfish msa consensus`: an aligned `.lungfishmsa` bundle.
- Inspector consensus mode: a BAM alignment track in a reference bundle.

## The three consensus surfaces

The surface you use depends on what you are starting from. The table names each one, its scope, and where its threshold lives.

| Surface | Start from | Threshold control | When to use |
|---|---|---|---|
| Viral Recon wizard | Raw reads (FASTQ) | The wizard's `Consensus` caller picker (iVar or bcftools) | The end-to-end amplicon surveillance workflow that maps reads and emits consensus FASTA outputs |
| `lungfish msa consensus` | An aligned `.lungfishmsa` bundle | `--threshold` (minimum non-gap residue fraction) and `--gap-policy` | A reproducible CLI consensus a technician can run identically each time |
| Inspector consensus mode | A BAM alignment region | Consensus minimum depth, minimum MAPQ, and minimum base quality sliders | A quick look at the consensus over one region, not a deposit-grade whole-genome FASTA |

The Viral Recon wizard is the natural primary choice for the surveillance workflow this chapter targets, because it runs the whole pipeline from reads and emits a consensus FASTA at the end. The `lungfish msa consensus` command is the reproducible scripted path. The Inspector consensus mode is for inspection, not submission.

## Consensus threshold choices

Whichever surface you use, the threshold is the same biological decision: the minimum fraction of reads (or aligned rows) that must agree before the consensus carries the alternate base. Below the threshold, the position is masked. The right value depends on what biological situation your sample represents.

| Threshold | What gets called as consensus | Use this when |
|---|---|---|
| `0.5` | Any base supported by more than half the reads. Mixtures pull the consensus toward the majority allele. | The sample is genuinely a mixed population (wastewater, co-infection) and you want a majority-rule view. Expect more masking and a noisier sequence. |
| `0.75` (common default) | The alternate base is called only when about three-quarters of reads agree. Borderline positions are masked. | Most clinical isolates and surveillance samples. This is the iVar paper's default and what Pangolin and Nextclade have been benchmarked against. |
| `0.9` | The alternate base is called only when at least 90 percent of reads agree. Anything near a 50/50 split is masked. | High-confidence reference deposits for GISAID or NCBI, where you would rather mask a position than risk encoding a sequencing artefact. |

If you do not know which to pick, `0.75` is the safe default for a clinical isolate. Note that the `lungfish msa consensus` default is `0.6` and measures the non-gap residue fraction across aligned rows rather than read allele frequency; set `--threshold` explicitly when you need a specific value.

## Procedure: reads to consensus with Viral Recon

The Viral Recon wizard runs the nf-core/viralrecon pipeline end to end and is the only path that takes reads all the way to a consensus FASTA inside Lungfish.

1. Choose `Tools > FASTQ/FASTA Operations`, then select `Viral Recon` in the tool sidebar. The wizard appears in the dialog.
2. Set the platform, the reference, and the primer scheme to match your run, exactly as you would for mapping.
3. In the wizard's caller row, set `Variants` to your variant caller and set `Consensus` to `iVar` or `bcftools`. The `Consensus` picker is what produces the consensus FASTA; the threshold biology in the table above applies here. <!-- planned: viralrecon-consensus-picker -->
4. Choose the executor and click to run. The pipeline maps, calls variants, and builds a per-sample consensus FASTA as one of its outputs.

The consensus FASTA the pipeline writes is the file you hand to Pangolin or Nextclade.

## Procedure: alignment to consensus with the CLI

When you already have an alignment of sequences as a `.lungfishmsa` bundle, `lungfish msa consensus` builds a consensus FASTA from the aligned rows. This is the reproducible path: the same command and the same inputs produce the same file every time, which is what a printed SOP needs.

```bash
lungfish msa consensus my-alignment.lungfishmsa \
    --output consensus.fa \
    --name "sample01 consensus" \
    --threshold 0.75 \
    --gap-policy omit
```

The `--threshold` flag is the minimum non-gap residue fraction required to call a consensus base; `--gap-policy omit` drops gap-only columns rather than emitting them. The command writes a plain FASTA with one record. The same consensus action is available in the app from the multiple-sequence-alignment viewport as `Create Consensus Sequence`. <!-- planned: msa-consensus-cli -->

For a quick consensus over one region of a BAM without leaving the alignment view, select an alignment track and turn on the Inspector's consensus mode. The controls there (`Consensus Mode`, `Use IUPAC ambiguity codes`, `Hide high-gap sites`, and sliders for consensus minimum depth, minimum MAPQ, and minimum base quality) drive the preview. `Extract Consensus…` exports the selected bases when there is an active base selection; otherwise it exports the visible viewport. <!-- planned: inspector-consensus-mode --> This is for inspection. For a whole-genome deposit, use Viral Recon or `lungfish msa consensus`.

## Wastewater: lineage abundances with Freyja

A consensus FASTA assumes one dominant sequence, so the single-consensus-to-Pangolin path is the wrong tool for a genuinely mixed sample. Wastewater is the canonical case: one sample contains many lineages at once, and the question is not "which lineage is this" but "what is the abundance of each lineage in the mixture."

For that, Lungfish provides `lungfish freyja demix`, which constructs and runs a Freyja demixing plan from a variant table and a depth table:

```bash
lungfish freyja demix \
    --variants sample.variants.tsv \
    --depths sample.depths.tsv \
    --output-dir freyja_out \
    --sample "WW-2026-06-01" \
    --execute
```

Freyja demixes the lineage abundances from the mixed sample's variant profile; it is the mixed-population analogue of single-consensus Pangolin assignment. Use `--dry-run` instead of `--execute` to write and print the command plan without running Freyja. Running Freyja requires the `wastewater-surveillance` tool pack.

## Interpretation

Open the consensus FASTA you produced (in the viewport, or any FASTA viewer) and spot-check it. A clean SARS-CoV-2 consensus from amplicon data typically shows a small handful of base differences from the Wuhan-Hu-1 reference and a few short `N` runs at amplicon dropouts. Long stretches of `N` (more than a few hundred bases at a time) usually mean an amplicon failed and the sample needs re-sequencing or re-pooling before it is fit for lineage assignment. Pangolin will accept a sequence with substantial `N` content, but call quality drops sharply as masking rises past roughly 10 percent.

To assign a lineage, hand the consensus to an external tool. In a web browser, open the Pangolin web interface at `https://pangolin.cog-uk.io`, drop in the FASTA, and read off the lineage, the confidence, and the pangolin-data version it used. The same FASTA goes to Nextclade unchanged at `https://clades.nextstrain.org`: choose the SARS-CoV-2 dataset, drop in the file, and read the Nextstrain clade and any flagged QC issues. Record the lineage call and the designation-set version in your sample sheet; that one piece of metadata is the part Lungfish cannot produce on its own.

## What Lungfish does not do

Lungfish produces a consensus FASTA and stops. Lineage assignment is deliberately left to external software:

- **Pangolin** assigns SARS-CoV-2 Pango lineages. It updates its designation database often (sometimes weekly during a wave) and runs online at `pangolin.cog-uk.io` or locally as a separate conda package. Bundling it inside Lungfish would mean shipping a stale database.
- **Nextclade** assigns Nextstrain clades and reports amino-acid substitutions. It runs in the browser at `clades.nextstrain.org` or as a CLI, and likewise pins to a dataset version that updates outside Lungfish's release cycle.
- **GISAID and NCBI submission** require an account, metadata forms, and (for GISAID) a per-submitter agreement. Both portals accept the consensus FASTA without modification, but the credentials and forms belong to the depositor, not the analysis tool.

The boundary is intentional. A consensus FASTA is a stable file format; lineage nomenclature is a moving target. Keeping the two on separate update cycles means you can re-run a lineage call with a fresher database six months from now without re-running the consensus.

## Next

Continue to [Importing Existing VCFs](06-importing-existing-vcfs.md) if you have a VCF from an external pipeline you want to view in Lungfish.
