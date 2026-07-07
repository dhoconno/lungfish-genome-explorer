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

Mapping takes two things, a pile of FASTQ reads and a reference genome, and
returns a BAM file that pins each read to the spot on the reference it matched
best. The BAM comes out sorted by position and indexed, so a viewer can leap
to any coordinate without scanning the whole file. Lungfish ships four
mappers: minimap2 (the default), BWA-MEM2, Bowtie2, and BBMap.

Mapping in the GUI is a two-step selection, and it trips up nearly every
first-time user. The wizard is not where you choose the reads or the mapper.
You pick the FASTQ bundle in the sidebar first, then open
`Tools > FASTQ/FASTA Operations > Mapping…` and click the row for the mapper
you want: minimap2, BWA-MEM2, Bowtie2, or BBMap. By the time the wizard opens
it already knows the reads, from your sidebar selection, and the mapper, from
the row you clicked. All it asks you for is the reference and the preset.

The preset is the field bench scientists most often get wrong. It is named for
the *data type*, not the biology: Illumina short reads, Oxford Nanopore long
reads, PacBio HiFi. What sets it is the sequencer that produced the FASTQ,
never the organism. Before you run, the wizard reads your data and posts an
Input Compatibility readout, and if the preset does not fit the detected read
type it can block Run until you fix it.

This chapter is a procedure: select the reads, choose the mapper, set the
reference and preset, and run. Underneath minimap2 the pipeline is
`minimap2 -ax <preset> | samtools sort | samtools index`, the same three-step
recipe a bioinformatician would type by hand. The other three mappers build
their own command and finish with the same sort and index.

In practice: with FASTQ reads and a reference in hand, select the reads, open
the Mapping dialog, pick the mapper and the preset that matches your sequencer,
and run.

## What you will learn

This chapter walks you from data type to finished track. You will choose the
right mapper and preset, run the Mapping dialog on paired or single FASTQs,
read the Input Compatibility check, watch the operation move through the
Operations Panel, find the alignment track it leaves in the sidebar, and read
the per-track stats in the Inspector.

## Choosing a mapper

Four mappers ship with Lungfish. For most viral and bacterial work the
default, minimap2, is the right call and the choice is dull. The table below
records where each tool actually wins, so you can defend a non-default pick
when a reviewer asks.

| Mapper    | Best for                                       | Notes                                                                 |
|-----------|------------------------------------------------|-----------------------------------------------------------------------|
| minimap2  | Default for everything: viral, bacterial, ONT, HiFi | Fast, well-supported, equivalent to BWA-MEM in published benchmarks for short-read viral data. |
| BWA-MEM2  | Human germline shotgun, large repetitive genomes | Slightly different multi-mapper handling; preferred at production scale for human resequencing. |
| Bowtie2   | Legacy short-read pipelines that hard-code Bowtie2 | Pick this only when reproducing a published pipeline that names Bowtie2 explicitly. |
| BBMap     | Recovering reads with high error rates or adapter contamination | More forgiving alignment scoring; useful when minimap2 reports a suspiciously low mapping rate. |

For short-read viral data, minimap2 with the Short-read preset is right, and
nothing practical is gained by switching. For human germline shotgun data,
BWA-MEM2 is often the preferred choice, and it is what production
human-genomics pipelines call.

## Choosing a preset

A preset tells the mapper what the reads look like: their length distribution,
their expected error profile, whether they arrive paired. Pick the one that
matches the sequencer that produced the FASTQ, not the organism.

The label you click in the GUI and the token you type on the command line are
not the same string. The wizard shows readable names like "Short-read" and
"Oxford Nanopore", drawn from the mapper's mode list. The CLI `--preset` flag
wants short tokens like `sr` and `map-ont`. The table below pairs them so you
can find either one.

| Data type                       | GUI preset label     | CLI `--preset` token |
|---------------------------------|----------------------|----------------------|
| Illumina short reads (paired or single) | Short-read   | `sr`                 |
| Oxford Nanopore long reads      | Oxford Nanopore      | `map-ont`            |
| PacBio HiFi (CCS) long reads    | PacBio HiFi          | `map-hifi`           |
| PacBio CLR (older long reads)   | PacBio CLR           | `map-pb`             |
| Assembly or assembled contigs   | Assembly-to-assembly | `asm5`               |
| Spliced transcripts (cDNA)      | Spliced CDS/cDNA     | `splice`             |

Which labels appear depends on the mapper. The assembly, splice, and PacBio
CLR presets above are minimap2 modes; BBMap offers its own two instead of these
tokens. In the BBMap wizard they read "Standard" and "PacBio"; on the command
line the `--preset` flag takes `bbmap-standard`, the mode BBMap falls back to
when you omit the flag, and `bbmap-pacbio` for BBMap's long-read mode. For
ordinary viral and bacterial work you will reach for "Short-read", "Oxford
Nanopore", or "PacBio HiFi" and never touch the rest.

Pairing follows from the reads you selected, with no control in the wizard.
Select a single FASTQ bundle and the run is single-end. Select a bundle that
already carries an R1 and an R2 file, or both halves together, and the run is
paired-end: the BAM then records FLAG bits, the per-read markers that tag each
read as first-of-pair or second-of-pair.

## Read groups

If the BAM is not headed for GATK or a joint-genotyping workflow, skip this
section. Lungfish fills in a sensible read group on its own, and the defaults
are fine for mapping, viewing, and single-sample variant calling. Read on only
when a downstream tool demands specific read-group fields.

Every BAM bound for variant calling should carry a read group. That is the
`@RG` header line, and it tells downstream tools which sample, library,
sequencing platform, and platform unit produced the reads. GATK and many
joint-genotyping workflows treat the metadata as required, not decorative.
Strip out a stable sample name (`SM`) and read-group ID (`ID`) and later steps
can no longer tie the alignment back to the biological sample it came from.

Lungfish writes a read group for managed mapping runs. The sample name still
comes from `--sample-name`; that value becomes `SM` and also drives output
naming. The CLI now exposes the other read-group fields:

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

Omit any field and Lungfish fills a reproducible default, then records it in
the mapping provenance and the analysis summary. `ID`, `SM`, `LB`, and `PU`
fall back to the sample name. `PL` follows the preset: `ILLUMINA` for
short-read and BBMap standard modes, `ONT` for minimap2 `map-ont`, `PACBIO`
for PacBio/HiFi modes, `CDNA` for splice mode, and `ASSEMBLY` for assembly
alignment mode.

## Advanced filters

The wizard's **Advanced Settings** disclosure, collapsed by default, decides
which alignments survive into the BAM and lets you hand raw flags to the
mapper. The defaults are right for almost everyone, so open it only when you
have a specific reason. The same controls live on the CLI.

| Wizard control       | CLI flag             | Effect                                                   |
|----------------------|----------------------|----------------------------------------------------------|
| Threads              | (uses host cores)    | How many CPU threads the mapper uses.                    |
| Secondary alignments | `--secondary`        | Keep secondary (alternate-placement) alignment records.  |
| Supplementary        | `--no-supplementary` | Exclude supplementary (split-read) alignment records.    |
| Min mapping quality  | `--min-mapq`         | Drop reads whose MAPQ falls below this floor.            |
| Extra arguments      | `--extra-args`       | Inject raw flags into the mapper command (for example `--eqx`). |

MAPQ is the mapper's confidence that a read sits where it was placed. A 0
means the read fits several spots equally well; 60 is the practical ceiling.
Raise the minimum-MAPQ floor and ambiguously placed reads are thrown out
before they ever reach the pileup.

## Procedure

The wizard has five sections, top to bottom: **Reference**, **Preset** (titled
"Mode" for the non-minimap2 mappers), **Read Group**, **Input Compatibility**,
and **Advanced Settings**. There is no Reads picker and no mapper picker inside
it. The reads come from your sidebar selection; the mapper comes from the tool
row you clicked to open the wizard.

<!-- planned: mapping-tool-picker -->

1. In the sidebar, click the FASTQ bundle you want to map so it becomes the
   selected item. If the bundle holds an R1 and an R2, the run goes paired-end
   on its own.
2. Choose `Tools > FASTQ/FASTA Operations > Mapping…` from the menu bar, then
   click the tool row for the mapper you want: **minimap2** (the default),
   **BWA-MEM2**, **Bowtie2**, or **BBMap**. The mapping wizard opens, titled
   "Map Reads (<mapper>)".
   <!-- planned: mapping-wizard-overview -->
3. Under **Reference**, click the picker and choose the reference bundle you
   want to map against. The picker lists every `.lungfishref` already imported
   into the project (see chapter 02-01). To map against a FASTA that is not in
   the project, click **Browse...** below the picker and select the reference
   file; the wizard adds it to the picker and selects it for this run.
4. Under **Preset**, pick the label that matches your data type from the table
   above. Then check the **Input Compatibility** readout below it: it reports
   the detected format, the read class, and the longest observed read, and it
   warns you, or blocks Run outright, when the preset does not fit.
5. Click **Run**. The wizard closes and the operation appears in the
   Operations Panel at the bottom of the project window.

While it runs, the Operations Panel shows a status row labelled `map`. Expand
the row and you see the underlying pipeline, for minimap2 the trio of
minimap2, samtools sort, and samtools index, with the resolved command line
for each step. When every step turns green, the alignment track has been
adopted onto the reference bundle.

## Worked example: SRR36291587 against MN908947.3

This walkthrough uses the SRR36291587 paired Illumina FASTQ pair and the
MN908947.3 SARS-CoV-2 reference, both already sitting in the project from
earlier chapters.

1. In the sidebar, click the `SRR36291587` FASTQ bundle. The bundle already
   pairs R1 and R2, so the run goes paired-end.
2. Open `Tools > FASTQ/FASTA Operations > Mapping…` and click the **minimap2**
   tool row. The mapping wizard opens.
3. Under **Reference**, choose `MN908947.3`.
4. Under **Preset**, leave it at **Short-read**. The data is paired Illumina,
   exactly what the Short-read preset is tuned for, and the Input
   Compatibility readout should agree.
5. Click **Run**.

On a typical Apple Silicon laptop, a viral-scale dataset this size finishes in
well under a minute. When it does, expand the reference bundle's alignment
tracks in the sidebar. A managed run adopts the track under the default name
"minimap2 Mapping", the mapper name plus "Mapping"; you can rename it, and a
CLI run uses whatever you pass to `--name`. Click the track and the alignment
viewport opens, while the Inspector fills with mapping statistics: total reads,
mapped reads, mapping rate, mean coverage, and primary-alignment count. For
SARS-CoV-2 amplicon data at this depth, expect a mapping rate above 95% and
mean coverage in the hundreds or thousands.

## Equivalent CLI

The same operation runs from the command line as two commands. The first sends
the mapper's output into a results directory. The second adopts that result
into the reference bundle, where it shows up as a track in the GUI.

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
it at. A plain `.fasta` always works. A `.lungfishref` bundle works only when
Lungfish can extract the bundle's primary FASTA, so if a bundle path is
rejected, pass the FASTA inside it instead.

`lungfish bam adopt-mapping` mints a fresh alignment-track identifier of the
form `aln_<hex>` for each adoption. Add `--track-id` to set that identifier
yourself when a script needs a stable, predictable handle for the track it just
attached; omit it and Lungfish generates one and records in the adoption
provenance that the identifier was defaulted.

Both forms write the same provenance sidecar, so a GUI run and a CLI run
of identical inputs produce identical recorded methods.

## Interpretation

Once the track is attached, the Inspector reports four numbers worth a look
before you call variants. The mapping rate is the fraction of input reads the
mapper placed on the reference at all; for a viral isolate against the correct
reference it usually clears 95%, and a much lower figure means something is
off. Mean coverage is the average depth across the reference, and for variant
calling on a viral genome you want at least 30x, ideally over 100x. The primary
alignment count sets aside secondary and supplementary rows, so it is the
cleanest count of reads that actually contributed evidence. The "properly
paired" fraction, on paired runs only, tracks how often R1 and R2 landed at the
expected distance and orientation; near 100% is healthy.

If the track looks healthy, the next step is usually variant calling
(chapter 05-01) or, for amplicon data, primer trimming first (chapter 04-03).

## Troubleshooting

A few failure modes are common enough to call out.

**Very low mapping rate.** When under 50% of reads map, the usual culprit is
the wrong reference. Confirm the bundle is the genome you actually sequenced
and not a related organism. Next most likely is host contamination in a viral
sample, since host reads will not map to a viral reference; that is expected
for shotgun viral data and usually cleared by running classification first to
confirm the target organism is even present. Third is a preset mismatch: ONT
reads against the `sr` preset mostly fail to map, because the error profile is
wrong.

**Mapper version drift.** Lungfish records the resolved tool version in the
provenance sidecar of every mapping run. If you re-run the same operation after
a plugin pack update and the alignments come back slightly different, check the
sidecar's `tool_versions` block. A minor minimap2 release now and then nudges
soft-clip boundaries by a base or two. That is harmless for variant calling,
but it can leave two BAMs that are not bit-identical.

**Paired-end pairing failures.** When the Operations Panel reports a pairing
error, the common cause is that R1 and R2 carry mismatched read names or
different read counts, the mark of a corrupted download or a half truncated by
a full disk. Re-import the FASTQ pair from the original source. Less often,
single-end and paired-end bundles have been dropped into the wrong slots; the
dialog sets paired mode only when both slots hold matching FASTQs.

## A note on viral recon

For a one-shot SARS-CoV-2 amplicon consensus workflow, one that runs mapping,
primer trim, variant calling, and consensus generation back to back, Lungfish
also exposes a Viral Recon wizard wrapping the nf-core/viralrecon pipeline. It
sits alongside the mappers, as another tool row in the same
`Tools > FASTQ/FASTA Operations > Mapping…` dialog. That wizard is a separate
procedure, covered in [Viral Recon Wizard](05-viral-recon-wizard.md), and it is
the wrong tool for one-off mapping experiments where you want to inspect the
alignment before deciding what comes next.

## Next

Continue to [Reading an Alignment](02-reading-an-alignment.md) to learn
how to view the BAM in Lungfish.
