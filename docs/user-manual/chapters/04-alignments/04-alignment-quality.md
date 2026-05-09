---
title: Alignment Quality
chapter_id: 04-alignments/04-alignment-quality
audience: analyst
prereqs: [04-alignments/01-mapping-reads-to-a-reference, 04-alignments/02-reading-an-alignment]
estimated_reading_min: 8
task: Check coverage uniformity, mark duplicates, and validate alignment quality before variant calling.
tags: [alignments, qc, coverage, duplicates, samtools]
tools: [samtools]
entry_points:
  - "Inspector > alignment track stats"
  - "CLI: lungfish markdup"
shots: []
planned_shots:
  - id: inspector-alignment-stats
    caption: "Inspector pane showing mean coverage, mapped reads, and flagstat-style counts for an alignment track."
  - id: coverage-histogram-uniform
    caption: "BAM viewport coverage histogram for a well-tiled amplicon BAM, showing roughly even depth across the genome."
  - id: coverage-histogram-dropout
    caption: "BAM viewport coverage histogram with two amplicon-edge dropouts visible as gaps in the histogram."
  - id: markdup-dialog
    caption: "The Mark Duplicates dialog launched from the Inspector's Analysis section."
illustrations: []
glossary_refs: [BAM, coverage, pileup, soft-clip, amplicon]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A BAM with the right number of reads is not necessarily a BAM that supports good variant calls. Three quality checks matter before you trust a downstream call set: coverage above a workflow-appropriate minimum, coverage uniformity across the genome, and duplicate handling. Each check answers a different question. The first asks whether you have enough reads in total. The second asks whether those reads are spread evenly. The third asks whether the reads you have are independent observations or copies of the same starting molecule.

Coverage minimum depends on what you plan to do with the BAM. For SARS-CoV-2 amplicon variant calling, a healthy run lands around 200x mean depth and at least 50x at every position you intend to call. Clinical labs frequently set a 100x floor at every callable position because below that the binomial confidence interval on allele frequency is too wide to distinguish a real minor variant from sampling noise. Metagenomic classification is a different regime entirely: 5x is enough to tell that an organism is present, even if it is far too thin for variant calling.

Coverage uniformity matters more for amplicon data than for shotgun. An amplicon protocol tiles the genome with discrete primer pairs, and any pair that drops out (because of a primer-binding-site mutation, a degraded template, or a pipetting error) leaves a gap. Inside that gap there is no evidence at all, so any variant that falls in it is invisible. Shotgun data fragments the template randomly and tends to cover the genome evenly enough that a single locally-low region is unusual rather than expected.

Duplicate handling is the inverse story. A duplicate is a read whose start position and orientation match another read so closely that they are probably PCR copies of the same original molecule. For shotgun data, two reads at the exact same position are suspicious and should be collapsed (marked) so that a single starting molecule does not vote twice in a pileup. For amplicon data, every read from a given amplicon starts at the same primer position by design, so most reads look like duplicates of each other and marking them throws away most of your data. The rule of thumb: mark duplicates for shotgun, skip for amplicon.

So what should you do with this? Before calling variants, open the alignment in the Inspector, check coverage and uniformity, and mark duplicates only if your data is shotgun.

## What you will learn

By the end of this chapter you will be able to read mean and minimum coverage from the Inspector, identify under-covered regions in the BAM viewport, decide whether to mark duplicates for your workflow, run `lungfish markdup` when needed, and recognize when an alignment is too poor for reliable variant calling and the reads need re-trimming or re-mapping.

## Procedure

### Read the Inspector stats

1. Click the alignment track in the sidebar. The BAM viewport opens and the Inspector populates with track-level stats. <!-- planned: inspector-alignment-stats -->
2. Read the **Mean coverage** field. This is the average depth across the entire reference, including any zero-coverage stretches.
3. Read the **Mapped reads** and **Properly paired** counts. These match the equivalent rows of `samtools flagstat`. A healthy paired-end run shows >95% mapped and (for shotgun) >90% properly paired; amplicon data often shows lower properly-paired numbers because primer trimming alters insert geometry.
4. Note the **Primary alignments** count. Supplementary and secondary alignments do not count toward coverage in the variant caller.

### Scan the coverage histogram

1. Look at the histogram strip above the read pile in the BAM viewport. Each bar is one position (or one bin at low zoom) and its height is the number of reads covering that position. <!-- planned: coverage-histogram-uniform -->
2. Drag horizontally across the genome. A uniform amplicon BAM shows a slightly bumpy plateau. A shotgun BAM shows a noisier but flatter trace.
3. Look for sharp dips to zero or near-zero. Each dip is either an amplicon dropout (in amplicon data) or a structural problem with the reference (a low-mappability region, a repeat, an N-stretch). <!-- planned: coverage-histogram-dropout -->
4. Note the genome coordinates of any dropouts. Variants in those regions cannot be called from this BAM regardless of how good the rest of the alignment is.

### Decide on duplicate marking

Use the table in [Thresholds](#thresholds-by-workflow) below to decide. If the answer is "skip", do nothing. If the answer is "mark", run `lungfish markdup` from the CLI or launch Mark Duplicates from the Inspector's Analysis section. <!-- planned: markdup-dialog -->

```
lungfish markdup --in path/to/alignment.bam --out path/to/alignment.markdup.bam
```

The command wraps `samtools markdup` with sensible defaults (the input is name-sorted, fixmate'd, position-sorted, then marked, then indexed). The output is a new BAM track adopted onto the same reference; the original is preserved.

## Thresholds by workflow

The numbers below are working defaults, not regulatory minima. Tighten them for clinical reporting; loosen them for exploratory work.

| Workflow | Mean coverage | Min coverage at any callable position | Mark duplicates? | Uniformity matters? |
|---|---|---|---|---|
| Viral amplicon (research) | 200x | 50x | Skip | Yes, critical |
| Viral amplicon (clinical) | 500x | 100x | Skip | Yes, critical |
| Viral shotgun | 30x | 10x | Mark | Less critical |
| Bacterial isolate shotgun | 50x | 20x | Mark | Less critical |
| Metagenomic classification | 5x | n/a | Mark | n/a |
| Metagenomic variant calling | 30x at organism of interest | 10x | Mark | Yes |

For mixed-population samples (wastewater, co-infections), raise the minimum-coverage floor: minor-variant detection at 1% allele frequency requires roughly 300x to clear the binomial sampling noise.

## Interpretation

### A passing BAM

Mean coverage at or above the workflow target, no zero-coverage gaps in regions of interest, and duplicate handling appropriate to the protocol. If all three are true, proceed to variant calling.

### Low mean coverage

If mean coverage is below target but uniformity looks fine, the cause is upstream of mapping: not enough reads reached the reference. Check, in this order, whether the input FASTQ had enough reads after host depletion or quality filtering, whether the sample titre was high enough to amplify, and whether the mapper preset matched the read type (mapping ONT reads with a short-read preset silently discards most of them). Re-running with a corrected preset is cheap; resequencing is not.

### Uneven coverage with amplicon-shaped dips

Sharp dropouts at amplicon edges are usually one of three things: a primer-binding-site mutation in this lineage that the scheme was not designed against, a primer pair that was diluted or omitted from the panel, or low template input that left some amplicons unamplified. Compare the dropout coordinates against the primer-scheme BED. If the gap straddles a single primer pair across multiple samples in the same run, suspect the panel; if it appears in one sample only, suspect titre or a binding-site mutation specific to that sample.

### Uneven coverage with broad slopes

Gentle, broad coverage variation across kilobases (rather than sharp amplicon-shaped dips) usually points to GC bias from the library prep or, in shotgun viral data, a multi-segment genome where some segments are more abundant than others. Neither necessarily invalidates the BAM, but variant calling thresholds should be set per-segment or per-region rather than globally.

### Surprisingly high duplicate rate on amplicon data

Expected. Amplicon reads share start coordinates by design, so a `samtools markdup` run on amplicon data flags 80–95% of reads as duplicates. This is not a problem to fix; it is the reason you skip duplicate marking for amplicon protocols.

### Surprisingly high duplicate rate on shotgun data

If shotgun marking flags much more than ~20% of reads, the library was over-amplified. The data is still usable post-marking, but the effective coverage is lower than the raw mean coverage suggests. Re-read the **Mean coverage** field after marking; it drops by the duplicate fraction.

## Worked example: SRR36291587 primer-trimmed BAM

The fixture run `SRR36291587` is a SARS-CoV-2 ARTIC v3 amplicon library, primer-trimmed against the matching scheme as described in [Primer Trimming](03-primer-trimming.md). The Inspector for the trimmed BAM reports mean coverage near 800x and >99% mapped. The coverage histogram shows the characteristic ARTIC sawtooth (every amplicon is a small bump and the bumps overlap at amplicon junctions) with no zero-coverage gaps in the spike gene or the rest of the called region. Because the protocol is amplicon, duplicate marking is skipped. The BAM passes all three checks and is ready for iVar variant calling in the next chapter.

If the same fixture had shown a 1.5 kb dropout straddling amplicon 76, the correct response would be to note the gap in the methods record, restrict variant calling to the rest of the genome, and flag any reported lineage assignment that depends on a position inside the gap as inconclusive.

## Next

This is the last chapter in [Alignments](.). Continue to [Variants](../05-variants/) to call variants from your alignment.
