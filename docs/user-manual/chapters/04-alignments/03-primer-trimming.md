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
sequences off the ends of every aligned read, so the variant caller never
mistakes primer bases for sample bases. Lungfish runs `ivar trim` against a
primer scheme bundle, a `.lungfishprimers` file that lists where each forward
and reverse primer binds on the reference, and writes a new, separately named
alignment track while leaving the source track untouched.

The trim deletes nothing. It flips each primer base in the CIGAR string from
`M` (aligned, analysable) to `S` (soft-clipped, still present but kept out of
pileups). The reads hold their original length. The primer footprints stay in
view as short, lighter ticks at amplicon edges, and pileup, coverage, and
variant calling all step over them. This is the same convention iVar, samtools,
and bcftools follow, and it is reversible: the unclipped BAM survives as a
parent track whenever you want to compare.

This chapter is about the BAM-level primer trim. A FASTQ-level trim also exists
(covered in [Read QC and Trimming](../03-reads/04-trimming-and-filtering.md))
and runs before mapping. The two are not interchangeable. BAM-level trim is the
default for the variant-calling pipeline because iVar was built around it: iVar
trims and iVar calls share one coordinate model. Reach for BAM-level trim when
you plan to call variants with iVar. Reach for FASTQ-level trim only when a
downstream tool refuses soft-clipped input.

The practical takeaway: if you mapped amplicon reads in the last chapter and
variants are next, run primer trim now, before the call.

## Why this matters

Untrimmed amplicon BAMs breed phantom variants. Every primer in the scheme
binds the reference at a fixed spot, and the bases the sequencer reads there
come from the synthetic primer, not the patient sample. When the primer
sequence carries a mismatch against the reference, and it often does, since
schemes are frequently designed against an older reference and primers are
deliberately degenerate to tolerate strain variation, every read across that
footprint reports the primer base instead of the sample base. The variant
caller then sees a column where 100% of reads carry the same alternate allele
at perfect quality, and it emits a confident SNP call.

These calls are wrong, and they are the worst kind of wrong: reproducible
(same primer, same mismatch, same call), backed by deep coverage, and clean in
any standard QC plot. Their one tell is location. They cluster at amplicon
ends. A SARS-CoV-2 ARTIC v3 BAM left un-trimmed routinely throws a dozen or
more such phantoms, packed into the 30-base footprints of primers with known
reference-mismatches. Strand bias is often the only column in the VCF that
gives them away, because the artefact runs in one direction only.

Primer trimming pulls the artefact out at the source. The trimmed BAM holds the
very same reads at the very same positions, but the variant caller no longer
meets primer bases when it builds its pileups. A clean trim against the right
scheme is the difference between a credible amplicon variant call and one that
needs a footnote.

## Primer schemes

The Primer Trim dialog's picker lists every scheme it can find, bundled or
project-local. The current release ships one built-in scheme. It appears in the
picker as **QIAseq Direct SARS-CoV-2 with Booster A (Built-in)**. Its internal
manifest name is `QIASeqDIRECT-SARS2`, so the bundle folder and the CLI
`--scheme` path use the short name while the picker label you click is the long
one. ARTIC, midnight, and other lab or vendor schemes belong in the project's
`Primer Schemes/` folder, imported as `.lungfishprimers` bundles.

| Picker label | Target | Amplicons | Primers | When to choose |
|---|---|---|---|---|
| QIAseq Direct SARS-CoV-2 with Booster A (Built-in) | SARS-CoV-2 | 223 | 563 | QIAGEN QIAseq Direct SARS-CoV-2 Kit with Booster A; default for the Lungfish Wastewater Kit |

The reference each scheme is built against is stored inside its
`.lungfishprimers` bundle and shown in the dialog when you select it. Confirm
it matches the reference you mapped against before you trim. A scheme built on
one coordinate system, applied to a BAM mapped on another, can miss primers
without a word of warning, because the BED coordinates never line up.

### Bringing your own scheme

Use `File > Import Center > Primer Scheme` to build a project-local scheme from
a BED file, an optional primer FASTA, and optional attachments. Lungfish writes
`manifest.json`, `primers.bed`, an optional `primers.fasta`, and `PROVENANCE.md`
under `Primer Schemes/<name>.lungfishprimers`. On the CLI,
`lungfish primers import --bed <bed> --fasta <ref> --output <name>.lungfishprimers`
builds the same bundle, which you then consume with `--scheme`.

See [Primer Scheme Bundles](../appendices/primer-schemes.md#appendix-primer-schemes)
for the layout and import procedure.

## Procedure

Primer trim runs iVar and samtools from the Variant Calling pack, so that
pack must be installed and ready before you start. Until it is, the dialog's
Run button stays disabled and its Readiness line reads "Requires Variant
Calling Pack". Install the pack from the plugin manager, then come back.

The worked example trims the SRR36291587 minimap2 alignment from the
[Mapping Reads](01-mapping-reads-to-a-reference.md) chapter with the built-in
QIAseq Direct SARS-CoV-2 scheme.

1. In the sidebar, select the alignment track minimap2 produced in the
   previous chapter ("minimap2 Mapping" by default). The Inspector on the
   right fills with the alignment's metadata.
2. In the Inspector, expand the **Analysis** section and click
   **Primer-trim BAM…**. The Primer Trim dialog opens. Its **Target** section
   holds an **Alignment Track** picker, defaulted to the first eligible BAM in
   the bundle. Leave it as is here; switch it only when the bundle carries
   several alignments and you mean to trim a different one.
   <!-- planned: primer-trim-dialog-overview -->
3. In the **Primer Scheme** picker at the top of the dialog, choose
   **QIAseq Direct SARS-CoV-2 with Booster A (Built-in)**. The dialog reports
   the scheme's reference (MN908947.3) and amplicon count (223) below the
   picker. Confirm the reference matches the alignment's.
4. Leave **Advanced Options** collapsed. The defaults follow iVar's
   recommendations for amplicon variant calling: minimum read length 30 bases,
   minimum quality 20, sliding window 4, primer offset 0. Open the disclosure
   only when your kit's documentation calls for a different value.
5. Click **Run**. The dialog closes and a new entry, labelled
   `bam primer-trim`, appears in the Operations Panel. When it finishes
   (typically under a minute for a SARS-CoV-2 BAM), a new alignment track shows
   up in the sidebar. It carries a name marking it primer-trimmed (the GUI
   pre-fills one you can edit; a CLI run uses whatever you pass to `--name`),
   and it lands in the bundle's `alignments/primer-trimmed` directory, the
   source track left untouched.
   <!-- planned: primer-trim-track-result -->

## Equivalent CLI

The same trim runs from the command line against a bundle alignment track.
`bam primer-trim` operates on a track inside a `.lungfishref` bundle, so you
pass the bundle, the source track identifier, the scheme, and a name for the
new track:

```text
lungfish bam primer-trim \
  --bundle "Reference Sequences/MN908947.3.lungfishref" \
  --alignment-track <source-track-id> \
  --scheme "Primer Schemes/QIASeqDIRECT-SARS2.lungfishprimers" \
  --name "SRR36291587 primer-trimmed"
```

The iVar defaults surface as `--ivar-min-length` (30), `--ivar-min-quality`
(20), `--ivar-sliding-window` (4), and `--ivar-primer-offset` (0). One extra
flag has no dialog twin and is worth knowing: `--target-reference` overrides
the contig name (`@SQ SN`) used to resolve the scheme against the BAM. By
default the scheme resolves against its own canonical accession, here
`MN908947.3`. If you mapped to a reference whose contig is named differently
from the scheme accession, pass the BAM's contig name to `--target-reference`
so the primer coordinates line up.

## Interpretation

Select the new primer-trimmed track and open it in the alignment viewport. The
reads map exactly where they did before. What changed is the look of the read
ends: where the old track showed solid `M`-bases running flush to the edge, the
trimmed track shows short runs of lighter, half-tone bases at every amplicon
boundary. Those are the soft-clipped primer footprints. They stay in the BAM,
addressable and inspectable, but pileup and coverage now pass over them.
Coverage at amplicon ends dips a little; the inner body of each amplicon is
unchanged.

Reads that carry no matching primer are retained, not dropped. iVar soft-clips
only where it locates a primer, so an off-target or primer-free read passes
through at its full mapped length. That is expected behaviour, not a trim
failure. Weigh those reads in the downstream coverage and QC checks before you
call variants.

The Inspector's **Provenance** section for the new track lists the primer-trim
step with the exact `ivar trim` command, the scheme's BED checksum, and the
input BAM's checksum. That provenance sidecar travels with the BAM inside its
bundle, and the variant-calling dialog reads it. When you run iVar variant
calling against this trimmed track in the next chapter, the dialog shows the
"this BAM has been primer-trimmed" acknowledgement already confirmed. You never
have to assert it by hand.

Check two things before moving on. First, the operation log should report a
non-trivial trim rate, typically 15% to 30% of bases soft-clipped for a tight
amplicon scheme. A rate near zero usually means the scheme's reference does not
match the alignment's, so the trim found no primers to clip. Second, the
trimmed track is the right input for iVar variant calling and the wrong input
for LoFreq. LoFreq does not honour soft-clipping the same way and will pull
some primer bases back into its pileups. If you mean to call with LoFreq, do
FASTQ-level primer trimming before mapping, not BAM-level trimming after.

## What you will learn

This chapter leaves you able to choose the right primer scheme for your
protocol, run the Primer Trim dialog from the Inspector, read the resulting
alignment track and confirm the soft-clipping rendered correctly in the
viewport, and tell that a primer-trimmed track is the right input for iVar
variant calling and the wrong input for LoFreq.

## Next

Continue to [Alignment Quality](04-alignment-quality.md) for QC checks,
or skip to [Calling Variants from Amplicon
Reads](../05-variants/01-calling-variants-from-amplicons.md) to start
variant calling on your trimmed BAM.
