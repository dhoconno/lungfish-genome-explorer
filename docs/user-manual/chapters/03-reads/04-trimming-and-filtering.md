---
title: Trimming and Filtering Reads
chapter_id: 03-reads/04-trimming-and-filtering
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 03-reads/03-quality-control]
estimated_reading_min: 10
task: Apply quality trimming, adapter removal, primer trimming, and length filtering to FASTQ reads.
tags: [reads, trim, adapter, primer, length, filter, fastp]
tools: [fastp]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Trimming & Filtering > Quality Trim"
  - "Tools > FASTQ/FASTA Operations > Trimming & Filtering > Adapter Removal"
  - "Tools > FASTQ/FASTA Operations > Trimming & Filtering > Primer Trimming"
  - "Tools > FASTQ/FASTA Operations > Trimming & Filtering > Filter by Read Length"
  - "CLI: lungfish fastq"
shots: []
planned_shots:
  - id: trimming-dialog
    caption: "The Quality Trim dialog with default parameters."
illustrations: []
glossary_refs: [primer-trim, soft-clip, FASTQ]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Trimming and filtering happen before mapping. The reads that come off a sequencer carry artefacts that have nothing to do with the biology you care about: low-Phred bases at the read ends, sequencer adapters that the demultiplexer did not finish stripping, amplicon primers that need to come off before counting reference matches, and very short reads that survived earlier steps but are too short to map confidently. Each artefact has its own removal step, and Lungfish exposes one operation per step.

The four operations are quality trimming (drop low-Phred bases from read ends), adapter removal (drop sequencer adapters that did not get cleaned during demultiplexing), primer trimming (drop amplicon primers, distinct from adapter removal because primers can sit further into the read), and length filtering (drop reads that became too short after the earlier trims). Lungfish runs `fastp` for the first three operations and a built-in length filter for the fourth. Each operation produces a new FASTQ bundle in the project's `Imports/` folder; the input bundle is never modified.

| Operation | When to use | Tool | Default parameters |
|---|---|---|---|
| Quality Trim | Per-base quality drops below Q20 at the read ends | fastp | Sliding window Q20, window 4 bp |
| Adapter Removal | QC flagged adapter contamination | fastp | Auto-detect Illumina adapters |
| Primer Trimming (FASTQ-level) | Amplicon reads, shotgun-style downstream analysis | fastp | Primer FASTA from selected scheme |
| Filter by Read Length | After any trim that shortens reads | Lungfish length filter | Minimum 30 bp, drop pair if either fails |

Order matters. Run quality trimming first so adapter detection sees clean ends. Run adapter removal next so primer detection is not confused by adapter remnants. Run primer trimming third when the protocol is amplicon. Run the length filter last, because every preceding step can shorten reads. If you would rather do this in one pass, the Quality Trim dialog has an "also remove adapters" checkbox that asks fastp to handle quality and adapters in a single read of the file. So what should you do with this? Trim only what QC told you needs trimming, then re-run QC on the output to confirm the trim helped.

## What you will learn

By the end of this chapter you will be able to choose the right trim operation for the QC pattern you saw in the previous chapter, run quality trimming with sensible defaults, run adapter removal, run FASTQ-level primer trimming when appropriate, run a length filter to drop reads that became too short, and chain trims by running one operation after another on the resulting bundle.

## Procedure

The worked example below chains three trims on the public SRR36291587 bundle that you imported in [Importing FASTQ](01-importing-fastq.md). Run quality trim, then adapter removal on the quality-trimmed output, then a length filter on the adapter-removed output. Each step takes about a minute on this 1.4 million read pair bundle.

### Quality trim

1. In the sidebar, click `Imports/SRR36291587` to select the source FASTQ bundle.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering > Quality Trim`. The dialog opens.
   <!-- planned: trimming-dialog -->
3. Leave the default Phred threshold at Q20 and the window size at 4 bp. Q20 means a 1-in-100 base error rate, which is a conservative floor for Illumina data.
4. Click `Run`.

The Operations Panel shows a `fastp quality-trim` row that lands in `Imports/SRR36291587 (qtrim)`. Open the new bundle and check the FASTQ viewport's QC tab to confirm the per-base quality plot now sits above Q20 across the full read length.

### Adapter removal

1. In the sidebar, click the `SRR36291587 (qtrim)` bundle that the previous step produced.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering > Adapter Removal`.
3. Leave the adapter source set to "Auto-detect (Illumina)". Fastp inspects the first few thousand reads and infers the adapter sequence; you only need a custom adapter FASTA for non-Illumina chemistries.
4. Click `Run`.

The output is `SRR36291587 (qtrim, adapt)`. The QC tab on the new bundle should show the adapter contamination indicator drop to near zero.

### Length filter

1. In the sidebar, click the `SRR36291587 (qtrim, adapt)` bundle.
2. Choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering > Filter by Read Length`.
3. Leave the minimum length at 30 bp and the "drop pair if either mate fails" checkbox ticked. For paired-end data, dropping a singleton mate prevents downstream tools from getting confused by mismatched read counts.
4. Click `Run`.

The output is `SRR36291587 (qtrim, adapt, len30)`. This is the bundle you would pass to the mapper.

### Primer trimming, when relevant

Skip this section unless your data is amplicon (ARTIC, QIASeqDIRECT, midnight, or a similar protocol). For amplicon data you have a choice between FASTQ-level and BAM-level primer trimming, covered in the next section.

To run FASTQ-level primer trimming: select the bundle, choose `Tools > FASTQ/FASTA Operations > Trimming & Filtering > Primer Trimming`, choose a primer scheme from `Primer Schemes/`, and click `Run`. The output bundle is suffixed `(primtrim)`.

## Interpretation

### FASTQ-level versus BAM-level primer trim

Amplicon data needs primers removed before variant calling, but you can do this at two points in the pipeline. FASTQ-level primer trimming (this chapter) cuts primer bases off the reads before mapping. BAM-level primer trimming (covered in [Primer Trimming](../04-alignments/03-primer-trimming.md)) leaves the reads alone, runs the mapper, and then soft-clips primer-derived bases in the alignment.

The variant-calling pipeline that this manual teaches uses BAM-level primer trim by default. The reason is that `ivar trim` consults the alignment position of each read to decide which primer pair it belongs to, which is more reliable than matching primer sequences in raw reads, especially when reads contain SNPs near a primer site. Soft-clipped bases stay in the BAM record (so you can audit them) but are excluded from pileups and variant calls.

FASTQ-level primer trimming makes sense in a narrower set of cases: when you want to feed amplicon reads into a tool that expects shotgun-style FASTQ (some assemblers, some classifiers), when you want to count primer-removed reads as a QC step in their own right, or when downstream you are not running `ivar` and have no aligner-aware trim available. Pick FASTQ-level when the downstream tool reads FASTQ; pick BAM-level when the downstream tool reads BAM.

### Re-running QC after trimming

Trimming is not free: every step removes data, and a poorly chosen threshold can remove too much. After every trim, re-run `Tools > FASTQ/FASTA Operations > QC & Reporting > Refresh QC Summary` on the new bundle and compare the QC tab against the input. The signs of a good trim are a per-base quality plot that no longer dips below Q20, an adapter contamination indicator near zero, and a length distribution that has tightened around the expected fragment size with most reads still surviving. The Operations Panel records the read counts before and after, so a quick sanity check is to confirm that survival rate is in the 90 to 99 percent range for typical Illumina data.

### Troubleshooting

**Over-trimming, too few reads survive.** If the survival rate after quality trimming drops below about 70 percent, the Q20 floor is probably too aggressive for the data. Re-run with Q15 (1-in-32 error rate) and compare. Long-read data, especially Nanopore, routinely sits at Q10 to Q15 and should never be quality-trimmed against an Illumina threshold. If survival drops after the length filter, the minimum length is probably set too high for a run that produced short reads on purpose (for example, miRNA libraries or aggressively fragmented inputs). Lower the minimum to 20 bp or skip the filter.

**Under-trimming, low quality persists.** If the QC tab still shows per-base quality below Q20 at the read ends after a Q20 trim, fastp's sliding window probably skipped over isolated bad bases inside an otherwise high-quality window. Reduce the window from 4 bp to 1 bp to trim base by base, accepting that this is slower and slightly more aggressive. If adapter contamination is still flagged after adapter removal, the auto-detect step probably picked the wrong adapter family. Check the QC tab for the adapter sequence the auto-detect chose, and if it does not match your library prep kit, re-run with a custom adapter FASTA.

**Primer bases visible after FASTQ-level primer trim.** Fastp matches primer sequences against read ends with a small mismatch tolerance. Reads that carry SNPs inside a primer footprint can fall outside that tolerance and slip through. This is the structural reason BAM-level primer trim exists: an alignment-position match does not care about base identity. If you see primer-derived signal in variant calls, switch to the BAM-level path.

## Next

Continue to [Decontamination](05-decontamination.md) to remove host and rRNA reads, or skip to [Subsetting and Extraction](06-subsetting-and-extraction.md) if your reads are already clean.
