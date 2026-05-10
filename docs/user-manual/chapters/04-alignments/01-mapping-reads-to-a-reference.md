---
title: Mapping Reads to a Reference
chapter_id: 04-alignments/01-mapping-reads-to-a-reference
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 01-foundations/04-alignment-files, 03-reads/01-importing-fastq]
estimated_reading_min: 10
task: Map FASTQ reads to a reference genome and attach the resulting BAM as a track.
tags: [alignments, mapping, minimap2, bwa, bowtie2, bbmap, illumina, nanopore]
tools: [minimap2, bwa-mem2, bowtie2, bbmap, samtools]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Mapping"
  - "CLI: lungfish map, lungfish bam adopt-mapping"
shots: []
planned_shots:
  - id: mapping-dialog-overview
    caption: "The Mapping dialog with mapper, preset, and reference selected."
illustrations: []
glossary_refs: [BAM, mapping, alignment, soft-clip]
features_refs: [map]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Mapping takes FASTQ reads and a reference genome and produces a BAM file
that records, for each read, where on the reference it best matched. The
output BAM is sorted by position and indexed, so a viewer can jump to any
coordinate without rereading the whole file. Lungfish runs the mapper
through `Tools > FASTQ/FASTA Operations > Mapping` and ships four mappers:
minimap2 (the default), BWA-MEM2, Bowtie2, and BBMap.

The dialog asks for three things: which reads to map (a FASTQ bundle, or
both halves of a paired pair), which reference to map them against (a
reference bundle already imported into the project), and which tool plus
preset to use. The preset is the part bench scientists most often get wrong,
because it is named for the *data type* (Illumina short reads, ONT long
reads, PacBio HiFi) rather than for any biological choice. The right preset
is determined entirely by which sequencer produced the FASTQ.

This chapter is a procedure. Pick the mapper, pick the preset, point at
your FASTQ and your reference, and run. The pipeline that runs underneath
is `minimap2 -ax <preset> | samtools sort | samtools index`, the same
three-step recipe a bioinformatician would type by hand.

So what should you do with this? When you have FASTQ reads and a reference,
open the Mapping dialog, pick the preset matching your sequencer, and run.

## What you will learn

By the end of this chapter you will be able to choose the right mapper and
preset for your data type, run the Mapping dialog with paired or single
FASTQs, watch the operation progress in the Operations Panel, find the
resulting alignment track in the sidebar, and read the per-track stats in
the Inspector.

## Choosing a mapper

Four mappers ship with Lungfish. For most viral and bacterial work the
default (minimap2) is correct and the choice is uninteresting. The table
below records the regimes where each tool wins, so you can defend a
non-default choice when a reviewer asks.

| Mapper    | Best for                                       | Notes                                                                 |
|-----------|------------------------------------------------|-----------------------------------------------------------------------|
| minimap2  | Default for everything: viral, bacterial, ONT, HiFi | Fast, well-supported, equivalent to BWA-MEM in published benchmarks for short-read viral data. |
| BWA-MEM2  | Human germline shotgun, large repetitive genomes | Slightly different multi-mapper handling; preferred at production scale for human resequencing. |
| Bowtie2   | Legacy short-read pipelines that hard-code Bowtie2 | Pick this only when reproducing a published pipeline that names Bowtie2 explicitly. |
| BBMap     | Recovering reads with high error rates or adapter contamination | More forgiving alignment scoring; useful when minimap2 reports a suspiciously low mapping rate. |

For short-read viral data, `minimap2 -ax sr` is the right default and there
is no practical reason to switch. For human germline shotgun data, BWA-MEM2
is often preferred and is what production human-genomics pipelines call.

## Choosing a preset

A preset tells the mapper what the reads look like (length distribution,
expected error profile, whether they are paired). Pick the preset that
matches the sequencer that produced the FASTQ, not the organism.

| Data type                          | Preset            | Mapper flag        |
|------------------------------------|-------------------|--------------------|
| Illumina paired-end short reads    | Short read (sr)   | `minimap2 -ax sr`  |
| Illumina single-end short reads    | Short read (sr)   | `minimap2 -ax sr`  |
| Oxford Nanopore long reads         | Map ONT (map-ont) | `minimap2 -ax map-ont` |
| PacBio HiFi (CCS) long reads       | Map HiFi (map-hifi) | `minimap2 -ax map-hifi` |
| Sanger or assembled contigs        | (use a different tool) | n/a            |

Pairing happens automatically. If you point the dialog at a single FASTQ
bundle, the run is single-end. If you point it at two FASTQ bundles (or one
bundle that already carries an R1 and an R2 file), the run is paired-end
and the BAM records FLAG bits that mark each read as first-of-pair or
second-of-pair.

## Read groups

Every BAM that will feed variant calling should carry a read group. A read
group is the `@RG` header line that tells downstream tools which sample,
library, sequencing platform, and platform unit produced the reads. GATK
and many joint-genotyping workflows treat this metadata as required rather
than decorative: without a stable sample name (`SM`) and read-group ID
(`ID`), later steps cannot reliably connect the alignment to the biological
sample it represents.

Lungfish writes a read group for managed mapping runs. The sample name is
still controlled by `--sample-name`; that value becomes `SM` and is also
used for output naming. The CLI now exposes the other read-group fields:

```text
lungfish map reads_R1.fastq.gz reads_R2.fastq.gz \
  --reference reference.fa \
  --paired \
  --sample-name HG00096 \
  --rg-id HG00096.flowcellA.lane1 \
  --rg-sm HG00096 \
  --rg-lb exome-capture-2026-05 \
  --rg-pl ILLUMINA \
  --rg-pu flowcellA.lane1
```

If you omit any read-group field, Lungfish resolves a reproducible default
and records it in the mapping provenance and analysis summary. `ID`, `SM`,
`LB`, and `PU` default to the sample name. `PL` defaults from the selected preset:
`ILLUMINA` for short-read and BBMap standard modes, `ONT` for minimap2
`map-ont`, `PACBIO` for PacBio/HiFi modes, `CDNA` for splice mode, and
`ASSEMBLY` for assembly alignment mode.

## Procedure

The wizard has three sections (Reads, Reference, Tool), all visible at
once. Filling them top to bottom is the fastest path.

<!-- planned: mapping-dialog-overview -->

1. Choose `Tools > FASTQ/FASTA Operations > Mapping` from the menu bar.
2. Under **Reads**, click the picker and choose your FASTQ bundle. If your
   bundle holds an R1 and an R2 the wizard treats the run as paired
   automatically. To map two separately-imported bundles as a pair, choose
   the R1 bundle in the first slot and the R2 bundle in the second.
3. Under **Reference**, click the picker and choose the reference bundle
   you want to map against. The picker lists every `.lungfishref` already
   imported into the project (see chapter 02-01).
4. Under **Tool**, leave the mapper at minimap2 unless the table above
   gives you a reason to switch. Choose the preset matching your data type
   from the table above.
5. Click **Run**. The wizard closes and the operation appears in the
   Operations Panel at the bottom of the project window.

While the operation runs, the Operations Panel shows a status row labelled
`map`. Expanding the row reveals the three-step pipeline (minimap2,
samtools sort, samtools index) and the resolved command line for each
step. When all three steps turn green the alignment track has been adopted
onto the reference bundle.

## Worked example: SRR36291587 against MN908947.3

This walkthrough uses the SRR36291587 paired Illumina FASTQ pair and the
MN908947.3 SARS-CoV-2 reference, both already in the project from earlier
chapters.

1. Open `Tools > FASTQ/FASTA Operations > Mapping`.
2. In **Reads**, choose `SRR36291587` from the FASTQ bundle picker. The
   bundle already pairs R1 and R2, so the wizard sets the run to paired-end.
3. In **Reference**, choose `MN908947.3`.
4. In **Tool**, leave the mapper at minimap2 and the preset at
   `Short read (sr)`. The data is paired Illumina, which is exactly what
   the `sr` preset is tuned for.
5. Click **Run**.

The operation takes well under a minute on a typical Apple Silicon laptop
for a viral-scale dataset of this size. When it finishes, expand
`Reference Sequences > MN908947.3 > Alignments` in the sidebar. A new
track named `SRR36291587 (minimap2 sr)` will be present. Selecting the
track opens the alignment viewport and populates the Inspector with
mapping statistics: total reads, mapped reads, mapping rate, mean
coverage, and primary-alignment count. For SARS-CoV-2 amplicon data of
this depth, expect a mapping rate above 95% and mean coverage in the
hundreds or thousands.

## Equivalent CLI

The same operation runs from the command line as two commands. The first
runs the mapper into a results directory. The second adopts that result
into the reference bundle so it appears as a track in the GUI.

```text
lungfish map Imports/SRR36291587_1.fastq.gz Imports/SRR36291587_2.fastq.gz \
  --reference "Reference Sequences/MN908947.3.lungfishref" \
  --paired --preset sr \
  --sample-name SRR36291587 \
  -o mapping/

lungfish bam adopt-mapping \
  --bundle "Reference Sequences/MN908947.3.lungfishref" \
  --mapping-result mapping/
```

Both forms write the same provenance sidecar, so a GUI run and a CLI run
of identical inputs produce identical recorded methods.

## Interpretation

Once the alignment track is attached, the Inspector reports four numbers
worth checking before you call variants on it. The mapping rate is the
fraction of input reads the mapper placed on the reference at all; for a
viral isolate against the correct reference this is usually above 95%, and
much lower numbers are a signal that something is off. Mean coverage is
the average depth across the reference; for variant calling on a viral
genome you want at least 30x and ideally over 100x. The primary alignment
count discounts secondary and supplementary rows so it is the cleanest
estimate of how many reads contributed evidence. The "properly paired"
fraction (paired runs only) measures how often R1 and R2 mapped at the
expected distance and orientation; near-100% is healthy.

If the alignment track looks healthy, the next step is usually variant
calling (chapter 05-01) or, for amplicon data, primer trimming first
(chapter 04-03).

## Troubleshooting

A few failure modes are common enough to call out.

**Very low mapping rate.** If under 50% of reads map, the most likely
cause is the wrong reference. Confirm the reference bundle is the genome
you actually sequenced, not a related organism. The second most likely
cause is host contamination in a viral sample (host reads will not map to
a viral reference); this is expected for shotgun viral data and usually
resolved by running classification first to confirm the target organism is
present at all. The third cause is a preset mismatch: ONT reads against
the `sr` preset will mostly fail to map because the error profile is
wrong.

**Mapper version drift.** Lungfish records the resolved tool version in
the provenance sidecar of every mapping run. If you re-run the same
operation after a plugin pack update and get slightly different alignments,
check the `tool_versions` block of the sidecar. Minor version changes in
minimap2 occasionally shift soft-clip boundaries by a base or two, which
is harmless for variant calling but can produce non-bit-identical BAMs.

**Paired-end pairing failures.** If the Operations Panel reports a pairing
error, the most common cause is that R1 and R2 carry mismatched read names
or different read counts (a corrupted download, or one half truncated by a
disk-space failure). Re-import the FASTQ pair from the original source. A
less common cause is mixing single-end and paired-end bundles in the
wrong slots; the dialog will only set paired mode when both slots hold
matching FASTQs.

## A note on viral recon

For a one-shot viral consensus workflow that runs mapping, primer trim,
variant calling, and consensus generation in sequence, Lungfish also
exposes a viral recon wizard wrapping the nf-core viralrecon pipeline.
That wizard is a separate procedure covered in [Viral Recon
Wizard](05-viral-recon-wizard.md) and is
not the right tool for one-off mapping experiments where you want to
inspect the alignment before deciding what to do next.

## Next

Continue to [Reading an Alignment](02-reading-an-alignment.md) to learn
how to view the BAM in Lungfish.
