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
  - "Tools > FASTQ/FASTA Operations > Mapping…, then a mapper tool row"
  - "CLI: lungfish map, lungfish bam adopt-mapping"
shots: []
planned_shots:
  - id: mapping-tool-picker
    caption: "The FASTQ/FASTA Operations dialog, Mapping category, with the minimap2 tool row selected."
  - id: mapping-wizard-overview
    caption: "The mapping wizard with Reference and Preset filled in and the Input Compatibility readout reporting a compatible match."
illustrations: []
glossary_refs: [BAM, mapping, alignment, mapper, soft-clip, supplementary-alignment, mapq]
features_refs: [map]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Mapping takes FASTQ reads and a reference genome and produces a BAM file
that records, for each read, where on the reference it best matched. The
output BAM is sorted by position and indexed, so a viewer can jump to any
coordinate without rereading the whole file. Lungfish ships four mappers:
minimap2 (the default), BWA-MEM2, Bowtie2, and BBMap.

Mapping in the GUI is a two-step selection that often trips up first-time
users. You do not pick the reads or the mapper inside the mapping wizard.
Instead you select the FASTQ bundle in the sidebar first, then open
`Tools > FASTQ/FASTA Operations > Mapping…` and click the row for the mapper
you want (minimap2, BWA-MEM2, Bowtie2, or BBMap). The wizard that opens
already knows the reads (your sidebar selection) and the mapper (the row you
clicked); it asks you only for the reference and the preset.

The preset is the part bench scientists most often get wrong, because it is
named for the *data type* (Illumina short reads, Oxford Nanopore long reads,
PacBio HiFi) rather than for any biological choice. The right preset is
determined entirely by which sequencer produced the FASTQ, not by the
organism. Before you run, the wizard inspects your reads and shows an Input
Compatibility readout; if the preset does not match the detected read type it
can block Run until you fix it.

This chapter is a procedure. Select the reads, choose the mapper, set the
reference and preset, and run. For minimap2 the pipeline that runs underneath
is `minimap2 -ax <preset> | samtools sort | samtools index`, the same
three-step recipe a bioinformatician would type by hand; the other three
mappers build an equivalent per-tool command with the same sort-and-index
finish.

In practice, when you have FASTQ reads and a reference, select the reads,
open the Mapping dialog, pick the mapper and the preset that matches your
sequencer, and run.

## What you will learn

This chapter walks you through choosing the right mapper and preset for your
data type, then selecting reads and running the Mapping dialog with paired or
single FASTQs, reading the Input Compatibility check, watching the operation
progress in the Operations Panel, finding the resulting alignment track in the
sidebar, and reading the per-track stats in the Inspector.

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

For short-read viral data, minimap2 with the Short-read preset is the right
default and there is no practical reason to switch. For human germline shotgun
data, BWA-MEM2 is often preferred and is what production human-genomics
pipelines call.

## Choosing a preset

A preset tells the mapper what the reads look like (length distribution,
expected error profile, whether they are paired). Pick the preset that
matches the sequencer that produced the FASTQ, not the organism.

The label you click in the GUI and the token you type on the command line
are not the same string. In the wizard you see readable names like "Short-read"
and "Oxford Nanopore" (drawn from the mapper's mode list); the CLI `--preset`
flag takes short tokens like `sr` and `map-ont`. The table below pairs them
so you can find either one.

| Data type                       | GUI preset label     | CLI `--preset` token |
|---------------------------------|----------------------|----------------------|
| Illumina short reads (paired or single) | Short-read   | `sr`                 |
| Oxford Nanopore long reads      | Oxford Nanopore      | `map-ont`            |
| PacBio HiFi (CCS) long reads    | PacBio HiFi          | `map-hifi`           |
| PacBio CLR (older long reads)   | PacBio CLR           | `map-pb`             |
| Assembly or assembled contigs   | Assembly-to-assembly | `asm5`               |
| Spliced transcripts (cDNA)      | Spliced CDS/cDNA     | `splice`             |

The GUI label list depends on the mapper: the assembly, splice, and PacBio
CLR presets above are minimap2 modes. BBMap presents its own modes ("Standard"
and "PacBio") rather than these tokens. For ordinary viral and bacterial work
you will use "Short-read", "Oxford Nanopore", or "PacBio HiFi" and never touch
the rest.

Pairing happens automatically from the reads you selected. If the sidebar
selection is a single FASTQ bundle, the run is single-end. If it is a bundle
that already carries an R1 and an R2 file (or both halves selected together),
the run is paired-end and the BAM records FLAG bits (per-read markers in the
BAM record) that mark each read as first-of-pair or second-of-pair. There is no pairing control in the wizard.

## Read groups

If you are not feeding the BAM to GATK or a joint-genotyping workflow, you can
skip this section: Lungfish fills in a sensible read group for you, and the
defaults are fine for mapping, viewing, and single-sample variant calling. Read
on only when a downstream tool requires specific read-group fields.

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

## Advanced filters

The wizard's **Advanced Settings** disclosure (collapsed by default) controls
which alignments survive into the BAM and lets you pass raw mapper flags. The
defaults are correct for almost everyone; open it only when you have a
specific reason. The same controls exist on the CLI.

| Wizard control       | CLI flag             | Effect                                                   |
|----------------------|----------------------|----------------------------------------------------------|
| Threads              | (uses host cores)    | How many CPU threads the mapper uses.                    |
| Secondary alignments | `--secondary`        | Keep secondary (alternate-placement) alignment records.  |
| Supplementary        | `--no-supplementary` | Exclude supplementary (split-read) alignment records.    |
| Min mapping quality  | `--min-mapq`         | Drop reads whose MAPQ falls below this floor.            |
| Extra arguments      | `--extra-args`       | Inject raw flags into the mapper command (for example `--eqx`). |

MAPQ is the mapper's confidence that a read sits where it was placed: 0 means
the read fits several positions equally well, 60 is the practical maximum.
Raising the minimum-MAPQ floor discards ambiguously-placed reads before they
reach the pileup.

## Procedure

The wizard you reach has five sections, top to bottom: **Reference**,
**Preset** (titled "Mode" for non-minimap2 mappers), **Read Group**, **Input
Compatibility**, and **Advanced Settings**. There is no Reads picker and no
mapper picker inside the wizard. The reads come from your sidebar selection
and the mapper comes from the tool row you clicked to open the wizard.

<!-- planned: mapping-tool-picker -->

1. In the sidebar, click the FASTQ bundle you want to map so it is the
   selected item. If the bundle holds an R1 and an R2, the run will be
   paired-end automatically.
2. Choose `Tools > FASTQ/FASTA Operations > Mapping…` from the menu bar, then
   click the tool row for the mapper you want: **minimap2** (the default),
   **BWA-MEM2**, **Bowtie2**, or **BBMap**. The mapping wizard opens, titled
   "Map Reads (<mapper>)".
   <!-- planned: mapping-wizard-overview -->
3. Under **Reference**, click the picker and choose the reference bundle you
   want to map against. The picker lists every `.lungfishref` already imported
   into the project (see chapter 02-01).
4. Under **Preset**, choose the label matching your data type from the table
   above. Check the **Input Compatibility** readout below it: it reports the
   detected format, read class, and longest observed read, and warns (or
   blocks Run) if the preset does not fit the reads.
5. Click **Run**. The wizard closes and the operation appears in the
   Operations Panel at the bottom of the project window.

While the operation runs, the Operations Panel shows a status row labelled
`map`. Expanding the row reveals the underlying pipeline (for minimap2:
minimap2, samtools sort, samtools index) and the resolved command line for
each step. When every step turns green the alignment track has been adopted
onto the reference bundle.

## Worked example: SRR36291587 against MN908947.3

This walkthrough uses the SRR36291587 paired Illumina FASTQ pair and the
MN908947.3 SARS-CoV-2 reference, both already in the project from earlier
chapters.

1. In the sidebar, click the `SRR36291587` FASTQ bundle. The bundle already
   pairs R1 and R2, so the run will be paired-end.
2. Open `Tools > FASTQ/FASTA Operations > Mapping…` and click the **minimap2**
   tool row. The mapping wizard opens.
3. Under **Reference**, choose `MN908947.3`.
4. Under **Preset**, leave it at **Short-read**. The data is paired Illumina,
   which is exactly what the Short-read preset is tuned for, and the Input
   Compatibility readout should agree.
5. Click **Run**.

The operation takes well under a minute on a typical Apple Silicon laptop
for a viral-scale dataset of this size. When it finishes, expand the
reference bundle's alignment tracks in the sidebar. A managed run adopts the
track under the default display name "minimap2 Mapping" (the mapper name plus
"Mapping"); you can rename it, and a CLI run uses whatever you pass to
`--name`. Selecting the track opens the alignment viewport and populates the
Inspector with mapping statistics: total reads, mapped reads, mapping rate,
mean coverage, and primary-alignment count. For SARS-CoV-2 amplicon data of
this depth, expect a mapping rate above 95% and mean coverage in the hundreds
or thousands.

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
  --mapping-result mapping/ \
  --name "minimap2 Mapping"
```

`lungfish map --reference` resolves the primary FASTA from whatever you point
it at. A plain `.fasta` always works; pointing it at a `.lungfishref` bundle
works only when Lungfish can extract the bundle's primary FASTA, so if a
bundle path is rejected, pass the FASTA inside it instead.

Both forms write the same provenance sidecar, so a GUI run and a CLI run
of identical inputs produce identical recorded methods.

## Interpretation

Once the alignment track is attached, the Inspector reports four numbers
worth checking before you call variants on it. The mapping rate is the
fraction of input reads the mapper placed on the reference at all. For a
viral isolate against the correct reference this is usually above 95%. Much
lower numbers signal that something is off. Mean coverage is
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

For a one-shot SARS-CoV-2 amplicon consensus workflow that runs mapping,
primer trim, variant calling, and consensus generation in sequence, Lungfish
also exposes a Viral Recon wizard wrapping the nf-core/viralrecon pipeline. It
lives alongside the mappers, as another tool row in the same
`Tools > FASTQ/FASTA Operations > Mapping…` dialog. That wizard is a separate
procedure covered in [Viral Recon Wizard](05-viral-recon-wizard.md) and is not
the right tool for one-off mapping experiments where you want to inspect the
alignment before deciding what to do next.

## Next

Continue to [Reading an Alignment](02-reading-an-alignment.md) to learn
how to view the BAM in Lungfish.
