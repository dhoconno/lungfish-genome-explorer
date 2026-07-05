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
    caption: "The Viral Recon wizard with the Consensus caller picker set, the only reads-to-consensus-FASTA path in Lungfish."
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

A consensus FASTA is the reference sequence with your sample's high-confidence variants written in place. Where the reads call a confident base, the consensus carries it; where they do not (low coverage, mixed signal, or no read at all), it carries an `N` mask. The result is a single sequence, the same length as the reference, that shows what your sample looks like as a genome rather than as a list of differences.

Consensus is the format downstream lineage and clade tools expect. Pangolin assigns SARS-CoV-2 Pango lineages from a consensus FASTA. Nextclade assigns Nextstrain clades and flags amino-acid changes from one. GISAID and NCBI both take a consensus FASTA as the surveillance deposit format. None of these tools accept a VCF directly, which is exactly why the consensus step sits between variant calling and lineage reporting.

Be exact about where consensus comes from in Lungfish, because it is tempting to assume the variant caller produces it. It does not. The iVar Variant Calling step from [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md) writes a VCF, a tabix index, and a SQLite store, but no consensus FASTA, and the dialog's consensus allele-frequency field governs how iVar merges adjacent codon SNPs into one VCF row, not where a base is masked as `N`. Lungfish builds a consensus FASTA on three other surfaces: the Viral Recon wizard (end to end from reads), `lungfish msa consensus` (from an alignment of sequences), and the Inspector's consensus mode (a quick region preview over a BAM). So what should you do with this? Pick the surface that matches your inputs, produce the consensus FASTA there, then hand that file to Pangolin or Nextclade, because Lungfish does not assign lineages itself.

## What you will learn

Finish this chapter and you will know which of the three consensus surfaces fits your inputs, how to set a consensus threshold and read what it means biologically, how to produce a consensus FASTA from reads with the Viral Recon wizard or from an alignment with `lungfish msa consensus`, how to run that consensus through Pangolin or Nextclade, and, for mixed wastewater samples, when to reach for `lungfish freyja demix` instead of a single-consensus call.

## Before you start

Each consensus surface starts from a different artefact, so the input you need depends on the path you take. A VCF is not one of them: a consensus is built from reads or aligned bases, not from a variant list, so arriving here from [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md) with only a VCF will not get you there.

- Viral Recon wizard: raw reads (FASTQ) plus the reference and primer scheme for the run.
- `lungfish msa consensus`: an aligned `.lungfishmsa` bundle.
- Inspector consensus mode: a BAM alignment track in a reference bundle.

## The three consensus surfaces

Which surface you use depends on what you are starting from. The table names each one, its scope, and where its threshold lives.

| Surface | Start from | Threshold control | When to use |
|---|---|---|---|
| Viral Recon wizard | Raw reads (FASTQ) | The wizard's `Consensus` caller picker (iVar or bcftools) | The amplicon-to-consensus surveillance workflow; the only reads-to-consensus-FASTA path |
| `lungfish msa consensus` | An aligned `.lungfishmsa` bundle | `--threshold` (minimum non-gap residue fraction) and `--gap-policy` | A reproducible CLI consensus a technician can run identically each time |
| Inspector consensus mode | A BAM alignment region | Consensus minimum depth, minimum MAPQ, and minimum base quality sliders | A quick look at the consensus over one region, not a deposit-grade whole-genome FASTA |

The Viral Recon wizard is the natural first choice for the surveillance workflow this chapter targets, because it runs the whole pipeline from reads and emits a consensus FASTA at the end. For a reproducible scripted path, reach for the `lungfish msa consensus` command. The Inspector consensus mode is for inspection, not submission.

## Consensus threshold choices

Whichever surface you use, the threshold is the same biological decision: the minimum fraction of reads (or aligned rows) that must agree before the consensus carries the alternate base. Below it, the position is masked. The right value depends on the biological situation your sample represents.

| Threshold | What gets called as consensus | Use this when |
|---|---|---|
| `0.5` | Any base supported by more than half the reads. Mixtures pull the consensus toward the majority allele. | The sample is genuinely a mixed population (wastewater, co-infection) and you want a majority-rule view. Expect more masking and a noisier sequence. |
| `0.75` (common default) | The alternate base is called only when about three-quarters of reads agree. Borderline positions are masked. | Most clinical isolates and surveillance samples. This is the iVar paper's default and what Pangolin and Nextclade have been benchmarked against. |
| `0.9` | The alternate base is called only when at least 90 percent of reads agree. Anything near a 50/50 split is masked. | High-confidence reference deposits for GISAID or NCBI, where you would rather mask a position than risk encoding a sequencing artefact. |

If you are unsure, `0.75` is the safe default for a clinical isolate. Note that `lungfish msa consensus` defaults to `0.6` and measures the non-gap residue fraction across aligned rows rather than read allele frequency; set `--threshold` explicitly when you need a specific value.

## Procedure: reads to consensus with Viral Recon

The Viral Recon wizard runs the nf-core/viralrecon pipeline end to end, and it is the only path that carries reads all the way to a consensus FASTA inside Lungfish.

1. Choose `Tools > FASTQ/FASTA Operations`, then select `Viral Recon` in the tool sidebar. The wizard appears in the dialog.
2. Set the platform, the reference, and the primer scheme to match your run, exactly as you would for mapping.
3. In the wizard's caller row, set `Variants` to your variant caller and `Consensus` to `iVar` or `bcftools`. The `Consensus` picker is what produces the consensus FASTA, and the threshold biology from the table above applies here. <!-- planned: viralrecon-consensus-picker -->
4. Choose the executor and click to run. The pipeline maps, calls variants, and builds a per-sample consensus FASTA as one of its outputs.

The consensus FASTA the pipeline writes is the file you hand to Pangolin or Nextclade.

## Procedure: alignment to consensus with the CLI

When you already have an alignment of sequences as a `.lungfishmsa` bundle, `lungfish msa consensus` builds a consensus FASTA from the aligned rows. This is the reproducible path: the same command on the same inputs produces the same file every time, which is exactly what a printed SOP needs.

```bash
lungfish msa consensus my-alignment.lungfishmsa \
    --output consensus.fa \
    --name "sample01 consensus" \
    --threshold 0.75 \
    --gap-policy omit
```

The `--threshold` flag is the minimum non-gap residue fraction required to call a consensus base; `--gap-policy omit` drops gap-only columns rather than emitting them. The command writes a plain FASTA with one record. The same consensus action lives in the app too, in the multiple-sequence-alignment viewport as `Create Consensus Sequence`. <!-- planned: msa-consensus-cli -->

For a quick consensus over one region of a BAM without leaving the alignment view, select an alignment track and turn on the Inspector's consensus mode. The controls there (`Consensus Mode`, `Use IUPAC ambiguity codes`, `Hide high-gap sites`, and sliders for consensus minimum depth, minimum MAPQ, and minimum base quality) drive a `samtools consensus` preview over the visible region. <!-- planned: inspector-consensus-mode --> This is for inspection only. For a whole-genome deposit, use Viral Recon or `lungfish msa consensus`.

## Wastewater: lineage abundances with Freyja

A consensus FASTA assumes one dominant sequence, so the single-consensus-to-Pangolin path is the wrong tool for a genuinely mixed sample. Wastewater is the canonical case: one sample holds many lineages at once, and the question is not "which lineage is this" but "how abundant is each lineage in the mixture."

For that, Lungfish provides `lungfish freyja demix`, which builds and runs a Freyja demixing plan from a variant table and a depth table:

```bash
lungfish freyja demix \
    --variants sample.variants.tsv \
    --depths sample.depths.tsv \
    --output-dir freyja_out \
    --sample "WW-2026-06-01" \
    --execute
```

Freyja untangles the lineage abundances from the mixed sample's variant profile; it is the mixed-population analogue of single-consensus Pangolin assignment. Use `--dry-run` in place of `--execute` to write and print the command plan without running Freyja. Running Freyja requires the `wastewater-surveillance` tool pack.

## Interpretation

Open the consensus FASTA you produced (in the viewport, or any FASTA viewer) and spot-check it. A clean SARS-CoV-2 consensus from amplicon data usually shows a small handful of base differences from the Wuhan-Hu-1 reference and a few short `N` runs at amplicon dropouts. Long stretches of `N`, more than a few hundred bases at a time, usually mean an amplicon failed and the sample needs re-sequencing or re-pooling before it is fit for lineage assignment. Pangolin will accept a sequence with substantial `N` content, but call quality drops sharply once masking climbs past roughly 10 percent.

To assign a lineage, hand the consensus to an external tool. In a web browser, open the Pangolin web interface at `https://pangolin.cog-uk.io`, drop in the FASTA, and read off the lineage, the confidence, and the pangolin-data version it used. The same FASTA goes unchanged to Nextclade at `https://clades.nextstrain.org`: choose the SARS-CoV-2 dataset, drop in the file, and read the Nextstrain clade and any flagged QC issues. Record the lineage call and the designation-set version in your sample sheet; that one piece of metadata is the part Lungfish cannot produce on its own.

## What Lungfish does not do

Lungfish produces a consensus FASTA and stops there. Lineage assignment is deliberately left to external software:

- **Pangolin** assigns SARS-CoV-2 Pango lineages. It updates its designation database often (sometimes weekly during a wave) and runs online at `pangolin.cog-uk.io` or locally as a separate conda package. Bundling it inside Lungfish would mean shipping a stale database.
- **Nextclade** assigns Nextstrain clades and reports amino-acid substitutions. It runs in the browser at `clades.nextstrain.org` or as a CLI, and likewise pins to a dataset version that updates outside Lungfish's release cycle.
- **GISAID and NCBI submission** require an account, metadata forms, and (for GISAID) a per-submitter agreement. Both portals accept the consensus FASTA without modification, but the credentials and forms belong to the depositor, not the analysis tool.

The boundary is intentional. A consensus FASTA is a stable file format; lineage nomenclature is a moving target. Keep the two on separate update cycles and you can re-run a lineage call with a fresher database six months from now without touching the consensus.

## Next

Continue to [Importing Existing VCFs](06-importing-existing-vcfs.md) if you have a VCF from an external pipeline you want to view in Lungfish.
