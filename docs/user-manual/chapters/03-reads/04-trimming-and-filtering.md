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

This chapter is about cleaning reads before mapping. To remove host or rRNA reads, see [Decontamination](05-decontamination.md); to take a subset of reads, see [Subsetting and Extraction](06-subsetting-and-extraction.md).

Trimming and filtering come before mapping. Reads fresh off a sequencer carry baggage that has nothing to do with the biology you care about: low-Phred bases at the read ends, sequencer adapters the demultiplexer did not finish stripping, amplicon primers that must come off before you count reference matches, and reads too short to map with confidence that slipped through earlier steps. Lungfish gives each artefact its own operation, plus a combined fastp operation for the everyday adapter-plus-quality cleanup.

All of these operations live in one dialog. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…` and pick the one you want from the list inside. The category holds six operations, and the table below pairs each with its tool and defaults. The tool matters, and four are in play: most operations run fastp, primer trimming runs bbduk or cutadapt depending on the primer source, and the length filter runs seqkit, so the tuning knobs shift from operation to operation. Each one writes a new FASTQ bundle into the project's `Imports/` folder and leaves the input bundle untouched.

| Operation | When to use | Tool | Default parameters |
|---|---|---|---|
| fastp Adapter + Quality Trim | QC shows adapters and low-quality read ends, or you want the standard Illumina cleanup pass | fastp | Auto-detect adapters plus sliding window Q20, window 4 bp, cut-right |
| Quality Trim | Per-base quality drops below Q20 at the read ends | fastp | Sliding window Q20, window 4 bp, cut-right |
| Adapter Removal | QC flagged adapter contamination | fastp | Auto-detect adapters |
| Primer Trimming (FASTQ-level) | Amplicon reads, shotgun-style downstream analysis | bbduk (literal sequence) or cutadapt-linked (reference FASTA) | Literal path: k-mer 15, min k-mer 11, Hamming distance 1 |
| Trim Fixed Bases | Hard-trim a known number of bases off each end (fixed-length UMIs, adapter stubs) | fastp | 5' trim 0, 3' trim 0 (you set them) |
| Filter by Read Length | After any trim that shortens reads | seqkit | Min Length and Max Length both blank (you set them) |

The combined fastp Adapter + Quality Trim operation folds adapter detection, adapter removal, and quality trimming into one pass, and it is the dialog's default trim/filter choice for FASTQ inputs. Order only matters once you chain separate operations. Run primer trimming before or after the combined fastp pass, whichever the downstream protocol wants, and run the length filter last, since every step before it can shorten reads. Trim only what QC flagged, reach for the combined fastp pass when you need both adapter and quality cleanup, then re-run QC on the output to confirm the trim helped rather than hurt.

## What you will learn

You will come away able to match the right trim operation to the QC pattern you saw in the previous chapter, run the combined fastp adapter-plus-quality cleanup with sensible defaults, run FASTQ-level primer trimming when it fits, hard-trim a fixed number of bases with Trim Fixed Bases, run a length filter to drop reads that fell too short, and chain separate trims only when the protocol calls for it.

## Procedure

The worked example below runs the combined fastp cleanup on the public SRR36291587 bundle you imported in [Importing FASTQ](01-importing-fastq.md), then runs a length filter on the trimmed output. Each step takes about a minute on this 1.4 million read pair bundle.

### Combined adapter and quality trim

1. In the sidebar, click `Imports/SRR36291587` to select the source FASTQ bundle.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…`. In the dialog that opens, select `fastp Adapter + Quality Trim` from the operations list (it is the default selection for FASTQ input).
   <!-- planned: trimming-dialog -->
3. Leave adapter trimming enabled with auto-detection, the Phred threshold at Q20, and the window size at 4 bp. Q20 marks a 1-in-100 base error rate, a conservative floor for Illumina data. The Mode segmented picker sets the sliding-window direction: leave it on Cut Right, its default, which scans from the 3' end inward. Cut Front scans from the 5' end, Cut Tail trims low-quality tails only, and Cut Both trims from both ends. On the command line the same control is `--mode` (cut-right, cut-front, cut-tail, cut-both), default cut-right.
4. Click `Run`.

The Operations Panel shows a combined fastp trim row, and a trimmed bundle appears under `Imports/`. Open it and check the FASTQ viewport's QC tab: the per-base quality plot should now sit above Q20 across the full read length, and the adapter contamination indicator should drop to near zero. The operation provenance records the `lungfish fastq trim` command, the resolved fastp adapter and quality defaults, checksums, file sizes, and runtime status. The combined command also takes a manual adapter with `--adapter <seq>`, quality-only mode with `--no-adapter-trimming`, and extra fastp flags passed verbatim with `--extra-args`.

### Length filter

1. In the sidebar, click the trimmed bundle from the previous step.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…` and select `Filter by Read Length` in the dialog.
3. Set `Min Length` and/or `Max Length`. Both start blank, so the filter does nothing until you give it at least one bound. Set the minimum to the shortest read you are willing to map, somewhere in the 30 to 50 bp range for SARS-CoV-2 Illumina, and leave the maximum blank unless you need to cap read length.
4. Click `Run`.

The output is a new bundle under `Imports/`, and this is the one you hand to the mapper. The length filter works per read; it has no "drop the whole pair if one mate fails" option.

### Trim a fixed number of bases

When you know exactly how many bases to cut, whether a fixed-length UMI, an in-line index, or a known adapter stub at a constant position, use `Trim Fixed Bases` rather than quality or adapter trimming. It removes a set number of bases from each end regardless of quality. Select the bundle, choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…`, and select `Trim Fixed Bases` in the dialog. Set `5' Trim` and `3' Trim` to the count you want off each end, both default to 0, so set at least one, and click `Run`. The command-line form is `lungfish fastq fixed-trim --front N --tail N`, where `--front` is the 5' end and `--tail` the 3' end the pane labels.

### Primer trimming, when relevant

Skip this section unless your data is amplicon, from ARTIC, QIASeqDIRECT, midnight, or a similar protocol. For amplicon data you choose between FASTQ-level and BAM-level primer trimming, weighed in the next section.

To run FASTQ-level primer trimming, select the bundle, choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering…`, select `Primer Trimming` in the dialog, supply the primer sequences as a literal sequence or a primer-scheme FASTA, and click `Run`. The primer source picks the engine. A Literal Sequence runs bbduk, matching primers as k-mers, and the k-mer, minimum k-mer, and Hamming distance fields govern this path alone, defaulting in the dialog to 15, 11, and 1. A Reference FASTA instead runs cutadapt in linked mode for anchored linked-adapter matching, and the k-mer fields do not apply. On the command line, `lungfish fastq primer-remove` exposes both engines through `--engine bbduk` or `--engine cutadapt-linked`, with `--minimum-overlap 12` and `--error-rate 0.12` tuning the cutadapt path and a default `--kmer 23` on the bbduk path.

## Interpretation

### FASTQ-level versus BAM-level primer trim

Amplicon data needs its primers gone before variant calling, and you can do that at two points in the pipeline. FASTQ-level primer trimming, this chapter, cuts primer bases off the reads before mapping. BAM-level primer trimming, covered in [Primer Trimming](../04-alignments/03-primer-trimming.md), leaves the reads alone, runs the mapper, then soft-clips primer-derived bases in the alignment. Soft-clipping means the bases stay in the read record but are marked as unaligned, so downstream tools ignore them.

The variant-calling pipeline this manual teaches uses BAM-level primer trim by default. The reason is that `ivar trim` reads each read's alignment position to decide which primer pair it belongs to, which beats matching primer sequences in raw reads, above all when reads carry SNPs near a primer site. Soft-clipped bases stay in the BAM record, so you can audit them, but drop out of the pileup, the stack of bases observed at each reference position that a variant caller actually counts, and out of the variant calls.

FASTQ-level primer trimming fits a narrower set of cases: when you feed amplicon reads into a tool that expects shotgun-style FASTQ, such as some assemblers and classifiers, when you want to count primer-removed reads as a QC step in its own right, or when nothing downstream runs `ivar` and no aligner-aware trim is on hand. Pick FASTQ-level when the downstream tool reads FASTQ; pick BAM-level when it reads BAM.

### Re-running QC after trimming

Trimming is never free: every step removes data, and a badly chosen threshold removes too much. After every trim, re-run `Refresh QC Summary` from `Tools > FASTQ/FASTA Operations > QC & Reporting…` on the new bundle and set the QC tab beside the input. A good trim shows three signs: a per-base quality plot that no longer dips below Q20, an adapter contamination indicator near zero, and a length distribution tightened around the expected fragment size with most reads still standing. The Operations Panel records the read counts before and after, so a quick sanity check is that the survival rate lands in the 90 to 99 percent range for typical Illumina data.

### Troubleshooting

**Over-trimming, too few reads survive.** When the survival rate after quality trimming falls below about 70 percent, the Q20 floor is probably too harsh for the data. Re-run with Q15, a 1-in-32 error rate, and compare. Long-read data, Nanopore above all, routinely sits at Q10 to Q15 and should never be quality-trimmed against an Illumina threshold. When survival drops after the length filter, the minimum length is probably too high for a run that made short reads on purpose, such as miRNA libraries or aggressively fragmented inputs. Lower the minimum to 20 bp, or skip the filter.

**Under-trimming, low quality persists.** When the QC tab still shows per-base quality below Q20 at the read ends after a Q20 trim, fastp's sliding window probably stepped over isolated bad bases inside an otherwise clean window. Drop the window from 4 bp to 1 bp to trim base by base, at the cost of speed and a touch more aggression. When adapter contamination is still flagged after adapter removal, the auto-detect step probably chose the wrong adapter family. Check the QC tab for the adapter sequence it settled on, and if it does not match your library prep kit, re-run with a custom adapter FASTA.

**Primer bases visible after FASTQ-level primer trim.** bbduk matches primer k-mers against the reads with a small mismatch tolerance, Hamming distance 1 by default. Reads carrying SNPs inside a primer footprint can fall outside that tolerance and slip through. This is the structural reason BAM-level primer trim exists: an alignment-position match does not care about base identity. If primer-derived signal shows up in variant calls, switch to the BAM-level path.

## Next

Continue to [Decontamination](05-decontamination.md) to remove host and rRNA reads, or skip to [Subsetting and Extraction](06-subsetting-and-extraction.md) if your reads are already clean.
