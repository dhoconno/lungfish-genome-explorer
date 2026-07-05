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
  - "Inspector > Analysis > Mark Duplicates in Bundle Tracks"
  - "CLI: lungfish markdup, lungfish bam filter"
shots: []
planned_shots:
  - id: inspector-alignment-stats
    caption: "Inspector pane showing mean coverage, mapped reads, and flagstat-style counts for an alignment track."
  - id: coverage-histogram-uniform
    caption: "BAM viewport coverage histogram for a well-tiled amplicon BAM, showing roughly even depth across the genome."
  - id: coverage-histogram-dropout
    caption: "BAM viewport coverage histogram with two amplicon-edge dropouts visible as gaps in the histogram."
  - id: markdup-dialog
    caption: "The Inspector's Analysis section showing the Mark Duplicates in Bundle Tracks and Create Deduplicated Bundle buttons."
illustrations: []
glossary_refs: [BAM, coverage, pileup, soft-clip, amplicon, mapq, percent-identity, supplementary-alignment]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A BAM with the right number of reads is not automatically a BAM that supports good variant calls. Three checks stand between raw reads and a call set you can trust: coverage above a workflow-appropriate minimum, coverage spread evenly across the genome, and duplicate handling. Each asks a different question. The first: do you have enough reads at all? The second: are they spread evenly? The third: are the reads you hold independent observations, or copies of the same starting molecule?

How much coverage you need depends on what the BAM is for. For SARS-CoV-2 amplicon variant calling, a healthy run lands near 200x mean depth with at least 50x at every position you mean to call. Clinical labs often set a 100x floor at every callable position, because below that the binomial confidence interval on allele frequency grows too wide to tell a real minor variant from sampling noise. Metagenomic classification plays by different rules: 5x is enough to say an organism is present, even though it is far too thin to call variants.

Uniformity matters more for amplicon data than for shotgun. An amplicon protocol tiles the genome with discrete primer pairs, and any pair that drops out, whether from a binding-site mutation, a degraded template, or a pipetting slip, leaves a gap. Inside that gap there is no evidence at all, so any variant that falls in it is invisible. Shotgun data fragments the template at random and tends to blanket the genome evenly enough that a single locally low region is a surprise rather than the norm.

Duplicate handling is the mirror image. A duplicate is a read whose start position and orientation match another so closely that the two are probably PCR copies of one original molecule. In shotgun data, two reads at the exact same position are suspect and should be collapsed, or marked, so a single starting molecule does not vote twice in a pileup. In amplicon data, every read from a given amplicon starts at the same primer position by design, so most reads look like duplicates of each other, and marking them throws away most of your data. The rule of thumb: mark duplicates for shotgun, skip them for amplicon.

The practical takeaway: before you call variants, open the alignment in the Inspector, check coverage and uniformity, and mark duplicates only if the data is shotgun.

## What you will learn

Work through this chapter and you will read mean and minimum coverage from the Inspector, spot under-covered regions in the BAM viewport, decide whether to mark duplicates for your workflow, run `lungfish markdup` (in place) and `lungfish bam filter` (to a new track) when they are called for, and recognise when an alignment is too poor for reliable variant calling and the reads need re-trimming or re-mapping.

## Procedure

### Read the Inspector stats

1. Click the alignment track in the sidebar. The BAM viewport opens and the Inspector fills with track-level stats. <!-- planned: inspector-alignment-stats -->
2. Read the **Mean coverage** field. This is the average depth across the entire reference, including any zero-coverage stretches.
3. Read the **Mapped reads** and **Properly paired** counts. Lungfish computes these straight from the BAM, and they match the equivalent rows of `samtools flagstat`. A healthy paired-end run shows >95% mapped and, for shotgun, >90% properly paired; amplicon data often runs lower on properly paired, because primer trimming reshapes the insert geometry.
4. Note the **Primary alignments** count. Supplementary and secondary alignments do not count toward coverage in the variant caller.

### Scan the coverage histogram

1. Look at the histogram strip above the read pile in the BAM viewport. Each bar is one position, or one bin at low zoom, and its height is the number of reads covering that position. <!-- planned: coverage-histogram-uniform -->
2. Drag horizontally across the genome. A uniform amplicon BAM shows a slightly bumpy plateau. A shotgun BAM shows a noisier but flatter trace.
3. Look for sharp dips to zero or near-zero. Each is either an amplicon dropout, in amplicon data, or a structural problem with the reference: a low-mappability region, a repeat, an N-stretch. <!-- planned: coverage-histogram-dropout -->
4. Note the genome coordinates of any dropouts. Variants inside them cannot be called from this BAM, however good the rest of the alignment is.

### Decide on duplicate marking

Use the table in [Thresholds](#thresholds-by-workflow) below to decide. If the answer is "skip", do nothing. If it is "mark", run `lungfish markdup` from the CLI or click **Mark Duplicates in Bundle Tracks** in the Inspector's Analysis section. <!-- planned: markdup-dialog -->

The CLI command takes a single positional path, either a BAM file or a directory of BAMs to mark in bulk:

```
lungfish markdup path/to/alignment.bam
```

The command wraps a `samtools markdup` pipeline (name-sort, fixmate, coordinate-sort, mark, index; fixmate is what lets `markdup` reason about read pairs) and marks duplicates **in place**: it replaces the input BAM with the marked version and writes no separate output. There is no `--in` or `--out` flag. This bites in scripting. Wrap `markdup` in a loop over a cohort and it overwrites every source BAM, so copy the originals first if you need to keep them.

Mark and remove are two different verbs, and the plain command only marks. In-place `markdup` keeps every read and sets the duplicate flag on the copies; nothing is deleted, and a downstream tool can still see, or ignore, the flagged reads. To instead *drop* the flagged reads into a fresh bundle and leave the source untouched, use the escape hatch:

```
lungfish markdup path/to/alignment.bam --deduplicated-bundle path/to/dedup.lungfishref
```

`--deduplicated-bundle` writes a sibling `.lungfishref` with the flagged duplicate reads removed, leaving the input untouched. The GUI equivalent is **Create Deduplicated Bundle** in the same Analysis section. One caution: the Inspector's **Mark Duplicates in Bundle Tracks** button marks every alignment track in the bundle, not just the one you selected.

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

For mixed-population samples such as wastewater or co-infections, raise the minimum-coverage floor: catching a minor variant at 1% allele frequency takes roughly 300x to clear the binomial sampling noise.

## Filtering a BAM before variant calling

Sometimes the right answer to a QC problem is not to re-map but to subset the alignment: keep only the reads you trust and call variants on those. `lungfish bam filter` derives a new, filtered alignment track from a bundle track or a mapping-result directory, leaving the source in place. It is the command form of the QC checks this chapter describes. The GUI equivalent is **Create Filtered Alignment** in the Inspector's Analysis section.

Because it produces a bundle track, `bam filter` needs to know which bundle, which source track, and what to name the result, alongside the filter flags:

```
lungfish bam filter \
  --bundle "Reference Sequences/MN908947.3.lungfishref" \
  --alignment-track <source-track-id> \
  --output-track-name "filtered (MAPQ 20, primary)" \
  --min-mapq 20 --primary-only --mapped-only
```

The filter flags map onto the QC concepts above:

| Flag | Keeps |
|---|---|
| `--mapped-only` | Drops unmapped reads. |
| `--primary-only` | Keeps only primary alignments (no secondary or supplementary). |
| `--min-mapq <n>` | Drops reads below the MAPQ floor. |
| `--exclude-marked-duplicates` | Drops reads already flagged as duplicates. |
| `--remove-duplicates` | Marks duplicates first, then drops them. |
| `--exact-match` | Keeps only perfect matches (edit distance `NM == 0`). |
| `--min-percent-identity <p>` | Keeps reads at or above a percent-identity threshold. |

`--exclude-marked-duplicates` and `--remove-duplicates` are mutually exclusive, and so are `--exact-match` and `--min-percent-identity`. A common pre-variant-calling filter for shotgun data is `--mapped-only --primary-only --min-mapq 20 --exclude-marked-duplicates`, which keeps confidently placed, non-duplicate primary reads and nothing else.

## Interpretation

### A passing BAM

Mean coverage at or above the workflow target, no zero-coverage gaps in regions of interest, and duplicate handling matched to the protocol. When all three hold, proceed to variant calling.

### Low mean coverage

If mean coverage sits below target but uniformity looks fine, the cause lies upstream of mapping: too few reads reached the reference. Check, in this order, whether the input FASTQ still held enough reads after host depletion or quality filtering, whether the sample titre was high enough to amplify, and whether the mapper preset matched the read type (map ONT reads with a short-read preset and most of them silently vanish). Re-running with a corrected preset is cheap; resequencing is not.

### Uneven coverage with amplicon-shaped dips

Sharp dropouts at amplicon edges are usually one of three things: a binding-site mutation in this lineage that the scheme was never designed for, a primer pair diluted or left out of the panel, or low template input that left some amplicons unamplified. Line the dropout coordinates up against the primer-scheme BED. If the gap straddles one primer pair across several samples in the same run, suspect the panel; if it shows up in a single sample, suspect titre or a binding-site mutation specific to that sample.

### Uneven coverage with broad slopes

Gentle, broad swings in coverage across kilobases, as opposed to sharp amplicon-shaped dips, usually point to GC bias from the library prep or, in shotgun viral data, a multi-segment genome where some segments outnumber others. Neither necessarily invalidates the BAM, but variant-calling thresholds should be set per segment or per region rather than globally.

### Surprisingly high duplicate rate on amplicon data

Expected. Amplicon reads share start coordinates by design, so a `samtools markdup` run on amplicon data flags 80–95% of reads as duplicates. It is not a problem to fix; it is the whole reason you skip duplicate marking for amplicon protocols.

### Surprisingly high duplicate rate on shotgun data

If shotgun marking flags much more than ~20% of reads, the library was over-amplified. The data is still usable once marked, but the effective coverage is lower than the raw mean coverage suggests. Re-read the **Mean coverage** field after marking; it falls by the duplicate fraction.

## Worked example: SRR36291587 primer-trimmed BAM

The fixture run `SRR36291587` is a SARS-CoV-2 amplicon library, primer-trimmed against the built-in QIAseq Direct SARS-CoV-2 scheme as described in [Primer Trimming](03-primer-trimming.md). The Inspector for the trimmed BAM reports mean coverage near 800x and >99% mapped. The coverage histogram shows the tell-tale amplicon sawtooth, every amplicon a small bump and the bumps overlapping at their junctions, with no zero-coverage gaps in the spike gene or anywhere else in the called region. Because the protocol is amplicon, duplicate marking is skipped. The BAM clears all three checks and is ready for iVar variant calling in the next chapter.

Had the same fixture shown a 1.5 kb dropout straddling one amplicon, the right response would be to note the gap in the methods record, restrict variant calling to the rest of the genome, and flag any reported lineage assignment that leans on a position inside the gap as inconclusive.

## Next

This is the last chapter in [Alignments](.). Continue to [Variants](../05-variants/) to call variants from your alignment.
