---
title: Primer Trimming a BAM
chapter_id: 04-alignments/03-primer-trimming
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/02-reading-an-alignment]
estimated_reading_min: 8
task: Soft-clip amplicon primers from a BAM using a primer scheme.
tags: [alignments, primer-trim, amplicon, ivar, primer-scheme, qiaseq, artic]
tools: [ivar, samtools]
entry_points:
  - "Inspector > Analysis > Primer-trim BAM…"
  - "CLI: lungfish bam primer-trim"
shots: []
planned_shots:
  - id: primer-trim-dialog-overview
    caption: "The Primer Trim dialog with a primer scheme selected."
  - id: primer-trim-track-result
    caption: "The primer-trimmed alignment track in the sidebar, with the (Primer-trimmed) suffix and soft-clip ticks visible at amplicon ends."
illustrations: []
glossary_refs: [primer-trim, primer-scheme, soft-clip, amplicon]
features_refs: [bam.primer-trim]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Primer trim is the BAM-level operation that soft-clips amplicon primer
sequences off the ends of every aligned read in a BAM, so the variant
caller does not mistake primer bases for sample bases. Lungfish runs
`ivar trim` against a primer scheme bundle (a `.lungfishprimers` file that
lists where each forward and reverse primer binds on the reference) and
writes a new, separately-named alignment track, leaving the source track in
place.

The trim does not delete bases from the BAM. It changes their CIGAR
flag from `M` (aligned, analysable) to `S` (soft-clipped, present but
excluded from pileups). The reads keep their original length. The
primer footprints stay visible in the viewport as short, lighter ticks
at amplicon edges. Pileup, coverage, and variant calling all skip those
bases. This is the same convention iVar, samtools, and bcftools use, and
it is reversible: the unclipped BAM is preserved as a parent track if
you ever want to compare.

This chapter covers the BAM-level primer trim. There is also a
FASTQ-level primer trim (covered in [Read QC and
Trimming](../03-reads/04-trimming-and-filtering.md)) that runs
before mapping. The two are not interchangeable. BAM-level primer trim
is the default for the variant-calling pipeline because iVar was
designed around it: iVar trims and iVar calls share the same coordinate
model. Use BAM-level trim when you intend to call variants with iVar.
Use FASTQ-level trim only when a downstream tool refuses soft-clipped
input.

The practical takeaway: if you mapped amplicon reads in the last chapter
and you plan to call variants, run primer trim now, before the variant call.

## Why this matters

Untrimmed amplicon BAMs produce phantom variants. Every primer in the
scheme binds the reference at a fixed position, and the bases the
sequencer reads at that position come from the synthetic primer, not
from the patient sample. If the primer sequence carries a mismatch
relative to the reference (which is common: schemes are often designed
against an older reference, and primers are intentionally degenerate to
tolerate strain variation), every read overlapping that footprint
reports the primer base, not the sample base. The variant caller sees a
column where 100% of reads carry the same alternate allele at perfect
quality and emits a confident SNP call.

These calls are wrong. They are reproducible (same primer, same
mismatch, same call), they are well-supported by depth, and they look
clean in any standard QC plot. They are also concentrated at amplicon
ends, which is the giveaway. A SARS-CoV-2 ARTIC v3 BAM that has not
been primer-trimmed routinely shows a dozen or more such phantoms,
clustered at the 30-base footprints of primers with known
reference-mismatches. Strand bias is often the only column in the VCF
that reveals them, because the artefact comes from one direction only.

Primer trimming removes the artefact at the source. The trimmed BAM
holds exactly the same reads, mapped to exactly the same positions, but
the variant caller no longer sees primer bases when it builds pileups.
A clean primer trim against the right scheme is the difference between
a credible amplicon variant call and one that needs a footnote.

## Primer schemes

The Primer Trim dialog lists every scheme it can find, bundled or
project-local, in the picker. The current release ships one built-in scheme.
In the picker it appears as **QIAseq Direct SARS-CoV-2 with Booster A
(Built-in)**; its internal manifest name is `QIASeqDIRECT-SARS2`, so the bundle
folder and the CLI `--scheme` path use the short name, but the picker label you
click is the long one. ARTIC, midnight, and other lab or vendor schemes should
be imported into the project's `Primer Schemes/` folder as `.lungfishprimers`
bundles.

| Picker label | Target | Amplicons | Primers | When to choose |
|---|---|---|---|---|
| QIAseq Direct SARS-CoV-2 with Booster A (Built-in) | SARS-CoV-2 | 223 | 563 | QIAGEN QIAseq Direct SARS-CoV-2 Kit with Booster A; default for the Lungfish Wastewater Kit |

The reference each scheme is built against is recorded inside the
`.lungfishprimers` bundle and shown in the dialog when you select it.
Confirm that the reference matches the one you mapped against before
you trim. A scheme built against one coordinate system applied to a BAM
mapped against another can silently miss primers, because the BED
coordinates will not line up.

### Bringing your own scheme

Use `File > Import Center > Primer Scheme` to build a project-local
scheme from a BED file, optional primer FASTA, and optional
attachments. Lungfish writes `manifest.json`, `primers.bed`, optional
`primers.fasta`, and `PROVENANCE.md` under
`Primer Schemes/<name>.lungfishprimers`. CLI workflows can build the
same bundle with `lungfish primers import --bed <bed> --fasta <ref>
--output <name>.lungfishprimers`, then consume the bundle with
`--scheme`.

See [Primer Scheme Bundles](../appendices/primer-schemes.md#appendix-primer-schemes)
for the layout and import procedure.

## Procedure

The worked example trims the SRR36291587 minimap2 alignment from the
[Mapping Reads](01-mapping-reads-to-a-reference.md) chapter using the built-in
QIAseq Direct SARS-CoV-2 scheme.

1. In the sidebar, select the alignment track produced by minimap2 in the
   previous chapter ("minimap2 Mapping" by default). The Inspector on the
   right populates with the alignment's metadata.
2. In the Inspector, expand the **Analysis** section and click
   **Primer-trim BAM…**. The Primer Trim dialog opens.
   <!-- planned: primer-trim-dialog-overview -->
3. In the **Primer Scheme** picker at the top of the dialog, choose
   **QIAseq Direct SARS-CoV-2 with Booster A (Built-in)**. The dialog shows the
   scheme's reference (MN908947.3) and amplicon count (223) below the picker.
   Confirm the reference matches the alignment's reference.
4. Leave **Advanced Options** collapsed. The defaults match the iVar
   recommendations for amplicon variant calling: minimum read length
   30 bases, minimum quality 20, sliding window 4, primer offset 0.
   Open the disclosure only if your kit's documentation calls for a
   different value.
5. Click **Run**. The dialog closes and a new entry appears in the
   Operations Panel labelled `bam primer-trim`. When it completes
   (typically under a minute for a SARS-CoV-2 BAM), a new alignment
   track appears in the sidebar. It carries a name marking it as
   primer-trimmed (the GUI pre-fills one for you and you can edit it; a CLI
   run uses whatever you pass to `--name`), and it lands in the bundle's
   `alignments/primer-trimmed` directory, leaving the source track untouched.
   <!-- planned: primer-trim-track-result -->

## Equivalent CLI

The same trim runs from the command line against a bundle alignment track.
`bam primer-trim` works on a track inside a `.lungfishref` bundle, so you pass
the bundle, the source track identifier, the scheme, and a name for the new
track:

```text
lungfish bam primer-trim \
  --bundle "Reference Sequences/MN908947.3.lungfishref" \
  --alignment-track <source-track-id> \
  --scheme "Primer Schemes/QIASeqDIRECT-SARS2.lungfishprimers" \
  --name "SRR36291587 primer-trimmed"
```

The iVar defaults are exposed as `--ivar-min-length` (30), `--ivar-min-quality`
(20), `--ivar-sliding-window` (4), and `--ivar-primer-offset` (0). One extra
flag has no dialog equivalent and is worth knowing: `--target-reference`
overrides the contig name (`@SQ SN`) used to resolve the scheme against the
BAM. By default the scheme resolves against its own canonical accession
(here `MN908947.3`); if you mapped to a reference whose contig is named
differently from the scheme accession, pass the BAM's contig name to
`--target-reference` so the primer coordinates line up.

## Interpretation

Select the new primer-trimmed track and open it in the alignment
viewport. The reads map at the same positions as before. What
changed is the appearance of the read ends: where the previous track
showed solid `M`-bases running flush to the read edge, the trimmed
track shows short stretches of lighter, half-tone bases at every
amplicon boundary. Those are the soft-clipped primer footprints. They
remain in the BAM, addressable and inspectable, but pileup and
coverage tracks now ignore them. Coverage at amplicon ends drops
slightly; the inner body of each amplicon is unchanged.

The Inspector's **Provenance** section for the new track lists the
primer-trim step with the exact `ivar trim` command, the scheme's BED
checksum, and the input BAM's checksum. A primer-trim provenance
sidecar travels with the BAM inside its bundle. The variant-calling
dialog reads that sidecar: when you run iVar variant calling against
this trimmed track in the next chapter, the dialog shows the
"this BAM has been primer-trimmed" acknowledgement as already
confirmed. You do not need to assert it manually.

Two things to check before moving on. First, the operation log should
report a non-trivial trim rate (typically 15% to 30% of bases
soft-clipped for a tight amplicon scheme). A rate near zero usually
means the scheme's reference does not match the alignment's reference,
and the trim found no primers to clip. Second, the trimmed track is
the right input for iVar variant calling and the wrong input for
LoFreq. LoFreq does not respect soft-clipping in the same way and will
re-introduce some primer bases into its pileups. If you plan to call
with LoFreq instead, use FASTQ-level primer trimming before mapping,
not BAM-level trimming after.

## What you will learn

This chapter covers choosing the right primer scheme for your protocol,
running the Primer Trim dialog from the Inspector, reading the resulting
alignment track and confirming the soft-clipping rendered correctly in the
viewport, and knowing that a primer-trimmed track is the right input for iVar
variant calling and the wrong input for LoFreq.

## Next

Continue to [Alignment Quality](04-alignment-quality.md) for QC checks,
or skip to [Calling Variants from Amplicon
Reads](../05-variants/01-calling-variants-from-amplicons.md) to start
variant calling on your trimmed BAM.
