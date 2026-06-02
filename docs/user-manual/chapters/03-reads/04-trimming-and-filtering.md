---
title: Trimming and Filtering Reads
chapter_id: 03-reads/04-trimming-and-filtering
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 03-reads/03-quality-control]
estimated_reading_min: 10
task: Apply quality trimming, adapter removal, primer trimming, fixed-base trimming, and length filtering to FASTQ reads.
tags: [reads, trim, adapter, primer, length, filter]
tools: [fastp, bbduk]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Trimming & Filtering… (then pick the operation)"
  - "CLI: lungfish fastq trim, quality-trim, adapter-trim, primer-remove, fixed-trim, length-filter"
shots: []
planned_shots:
  - id: trimming-dialog
    caption: "The combined fastp Adapter + Quality Trim dialog with default parameters."
illustrations: []
glossary_refs: [primer-trim, soft-clip, pileup, FASTQ]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter covers cleaning reads before mapping. For removing host or rRNA reads see [Decontamination](05-decontamination.md); for taking a subset of reads see [Subsetting and Extraction](06-subsetting-and-extraction.md).

Trimming and filtering happen before mapping. The reads that come off a sequencer carry artefacts that have nothing to do with the biology you care about: low-Phred bases at the read ends, sequencer adapters that the demultiplexer did not finish stripping, amplicon primers that need to come off before counting reference matches, and very short reads that survived earlier steps but are too short to map confidently. Lungfish exposes separate operations for each artefact, plus a combined fastp operation for the common adapter-plus-quality cleanup.

All of these operations live in one dialog. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…` and pick the operation you want from the list inside the dialog. The category holds six operations. The table below lists each with its tool and defaults. The tool matters, and three are involved: most operations run fastp, primer trimming runs bbduk (a k-mer matcher), and the length filter runs seqkit, so the tuning knobs differ from operation to operation. Each operation produces a new FASTQ bundle in the project's `Imports/` folder; the input bundle is never modified.

| Operation | When to use | Tool | Default parameters |
|---|---|---|---|
| fastp Adapter + Quality Trim | QC shows adapters and low-quality read ends, or you want the standard Illumina cleanup pass | fastp | Auto-detect adapters plus sliding window Q20, window 4 bp, cut-right |
| Quality Trim | Per-base quality drops below Q20 at the read ends | fastp | Sliding window Q20, window 4 bp, cut-right |
| Adapter Removal | QC flagged adapter contamination | fastp | Auto-detect adapters |
| Primer Trimming (FASTQ-level) | Amplicon reads, shotgun-style downstream analysis | bbduk (default) or cutadapt-linked | K-mer 23, min k-mer 11, Hamming distance 1 |
| Trim Fixed Bases | Hard-trim a known number of bases off each end (fixed-length UMIs, adapter stubs) | fastp | 5' trim 0, 3' trim 0 (you set them) |
| Filter by Read Length | After any trim that shortens reads | seqkit | Min Length and Max Length both blank (you set them) |

The combined fastp Adapter + Quality Trim operation does adapter detection, adapter removal, and quality trimming in one pass; it is the default trim/filter choice in the dialog for FASTQ inputs. Order only matters when you chain separate operations. Run primer trimming before or after the combined fastp pass based on the downstream protocol, and run the length filter last because every preceding step can shorten reads. Trim only what QC told you needs trimming, prefer the combined fastp pass when both adapter and quality cleanup are needed, then re-run QC on the output to confirm the trim helped, not hurt.

## What you will learn

By the end of this chapter you will be able to choose the right trim operation for the QC pattern you saw in the previous chapter, run the combined fastp adapter plus quality cleanup with sensible defaults, run FASTQ-level primer trimming when appropriate, hard-trim a fixed number of bases with Trim Fixed Bases, run a length filter to drop reads that became too short, and chain separate trims only when the protocol calls for it.

## Procedure

The worked example below runs the combined fastp cleanup on the public SRR36291587 bundle that you imported in [Importing FASTQ](01-importing-fastq.md), then runs a length filter on the trimmed output. Each step takes about a minute on this 1.4 million read pair bundle.

### Combined adapter and quality trim

1. In the sidebar, click `Imports/SRR36291587` to select the source FASTQ bundle.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…`. In the dialog that opens, select `fastp Adapter + Quality Trim` from the operations list (it is the default selection for FASTQ input).
   <!-- planned: trimming-dialog -->
3. Leave adapter trimming enabled with auto-detection, the Phred threshold at Q20, and the window size at 4 bp. Q20 means a 1-in-100 base error rate, which is a conservative floor for Illumina data.
4. Click `Run`.

The Operations Panel shows a combined fastp trim row, and a trimmed bundle appears under `Imports/`. Open the new bundle and check the FASTQ viewport's QC tab to confirm the per-base quality plot now sits above Q20 across the full read length and the adapter contamination indicator drops to near zero. The operation provenance records the `lungfish fastq trim` command, the resolved fastp adapter and quality defaults, checksums, file sizes, and runtime status. The combined command also accepts a manual adapter with `--adapter <seq>`, quality-only mode with `--no-adapter-trimming`, and extra fastp flags passed verbatim with `--extra-args`.

### Length filter

1. In the sidebar, click the trimmed bundle from the previous step.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…` and select `Filter by Read Length` in the dialog.
3. Set `Min Length` and/or `Max Length`. Both fields are blank by default, so the filter does nothing until you supply at least one bound. Set the minimum to the shortest read you are willing to map (for SARS-CoV-2 Illumina, something in the 30 to 50 bp range is reasonable); leave the maximum blank unless you need to cap read length.
4. Click `Run`.

The output is a new bundle under `Imports/`. This is the bundle you would pass to the mapper. The length filter applies per read; it does not have a "drop the whole pair if one mate fails" option.

### Trim a fixed number of bases

When you know exactly how many bases to remove (a fixed-length UMI, an in-line index, or a known adapter stub at a constant position), use `Trim Fixed Bases` rather than quality or adapter trimming. It cuts a set number of bases off each end regardless of quality. Select the bundle, choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…`, and select `Trim Fixed Bases` in the dialog. Set `5' Trim` and `3' Trim` to the number of bases to remove from each end (both default to 0, so set at least one) and click `Run`. The command-line form is `lungfish fastq fixed-trim --front N --tail N`, where `--front` is the 5' end and `--tail` is the 3' end the pane labels.

### Primer trimming, when relevant

Skip this section unless your data is amplicon (ARTIC, QIASeqDIRECT, midnight, or a similar protocol). For amplicon data you have a choice between FASTQ-level and BAM-level primer trimming, covered in the next section.

To run FASTQ-level primer trimming: select the bundle, choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…`, select `Primer Trimming` in the dialog, supply the primer sequences (a literal sequence or a primer-scheme FASTA), and click `Run`. This operation runs bbduk by default, which matches primers as k-mers (default k-mer 23, minimum k-mer 11, Hamming distance 1). A second engine, `cutadapt-linked`, is available on the command line (`lungfish fastq primer-remove --engine cutadapt-linked`, with `--minimum-overlap 12` and `--error-rate 0.12`) when you need anchored linked-adapter matching instead.

## Interpretation

### FASTQ-level versus BAM-level primer trim

Amplicon data needs primers removed before variant calling, but you can do this at two points in the pipeline. FASTQ-level primer trimming (this chapter) cuts primer bases off the reads before mapping. BAM-level primer trimming (covered in [Primer Trimming](../04-alignments/03-primer-trimming.md)) leaves the reads alone, runs the mapper, and then soft-clips primer-derived bases in the alignment. Soft-clipping means the bases stay in the read record but are marked as not aligned, so tools downstream ignore them.

The variant-calling pipeline that this manual teaches uses BAM-level primer trim by default. The reason is that `ivar trim` consults the alignment position of each read to decide which primer pair it belongs to, which is more reliable than matching primer sequences in raw reads, especially when reads contain SNPs near a primer site. Soft-clipped bases stay in the BAM record (so you can audit them) but are excluded from the pileup (the stack of bases observed at each reference position, which is what a variant caller actually counts) and from variant calls.

FASTQ-level primer trimming makes sense in a narrower set of cases: when you want to feed amplicon reads into a tool that expects shotgun-style FASTQ (some assemblers, some classifiers), when you want to count primer-removed reads as a QC step in their own right, or when downstream you are not running `ivar` and have no aligner-aware trim available. Pick FASTQ-level when the downstream tool reads FASTQ; pick BAM-level when the downstream tool reads BAM.

### Re-running QC after trimming

Trimming is not free: every step removes data, and a poorly chosen threshold can remove too much. After every trim, re-run `Refresh QC Summary` (from `Tools > FASTQ/FASTA Operations > QC & Reporting…`) on the new bundle and compare the QC tab against the input. The signs of a good trim are a per-base quality plot that no longer dips below Q20, an adapter contamination indicator near zero, and a length distribution that has tightened around the expected fragment size with most reads still surviving. The Operations Panel records the read counts before and after, so a quick sanity check is to confirm that survival rate is in the 90 to 99 percent range for typical Illumina data.

### Troubleshooting

**Over-trimming, too few reads survive.** If the survival rate after quality trimming drops below about 70 percent, the Q20 floor is probably too aggressive for the data. Re-run with Q15 (1-in-32 error rate) and compare. Long-read data, especially Nanopore, routinely sits at Q10 to Q15 and should never be quality-trimmed against an Illumina threshold. If survival drops after the length filter, the minimum length is probably set too high for a run that produced short reads on purpose (for example, miRNA libraries or aggressively fragmented inputs). Lower the minimum to 20 bp or skip the filter.

**Under-trimming, low quality persists.** If the QC tab still shows per-base quality below Q20 at the read ends after a Q20 trim, fastp's sliding window probably skipped over isolated bad bases inside an otherwise high-quality window. Reduce the window from 4 bp to 1 bp to trim base by base, accepting that this is slower and slightly more aggressive. If adapter contamination is still flagged after adapter removal, the auto-detect step probably picked the wrong adapter family. Check the QC tab for the adapter sequence the auto-detect chose, and if it does not match your library prep kit, re-run with a custom adapter FASTA.

**Primer bases visible after FASTQ-level primer trim.** bbduk matches primer k-mers against the reads with a small mismatch tolerance (Hamming distance 1 by default). Reads that carry SNPs inside a primer footprint can fall outside that tolerance and slip through. This is the structural reason BAM-level primer trim exists: an alignment-position match does not care about base identity. If you see primer-derived signal in variant calls, switch to the BAM-level path.

## Next

Continue to [Decontamination](05-decontamination.md) to remove host and rRNA reads, or skip to [Subsetting and Extraction](06-subsetting-and-extraction.md) if your reads are already clean.
