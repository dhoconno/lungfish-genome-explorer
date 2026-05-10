---
title: Reading the Variant Browser
chapter_id: 05-variants/02-reading-the-variant-browser
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 8
task: Navigate the variant browser, sort and filter the variant table, and read per-row details.
tags: [variants, viewport, table, filter, source-column, inspector]
tools: []
entry_points:
  - "Click a variant track in the sidebar"
shots: []
planned_shots:
  - id: variant-browser-overview
    caption: "The variant browser with the genome track on top and the variant table on the bottom."
  - id: variant-browser-filter
    caption: "The variant table filter bar with the PASS chip selected."
  - id: variant-browser-inspector
    caption: "The Inspector showing INFO and FORMAT fields for a selected variant row."
  - id: variant-browser-multi-track
    caption: "Two variant tracks loaded together, with the Source column distinguishing iVar and LoFreq rows."
illustrations: []
glossary_refs: [VCF, allele-frequency, FILTER, INFO, FORMAT, depth]
features_refs: [viewport.variant-browser]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

The variant browser is the main surface in Lungfish for reading, sorting, and exporting variants. It opens when you click a variant track in the sidebar, and it occupies the full viewport area of the project window. The browser combines a coordinate-aware view of the genome with a tabular view of every row in the underlying VCF, so you can jump between "where on the genome is this variant" and "what does this variant say" without leaving the chapter.

The browser has three regions stacked vertically. The top region is a genome track that draws each variant as a tick at its reference position. The middle region is a reference panel that shows the bases under the cursor and updates as you navigate. The bottom region is a sortable variant table that lists every VCF row, one row per variant, with the standard VCF columns plus a `Source` column that records which caller produced the row. A filter bar above the table accepts both chip-style presets and free-text smart-filter queries.

<!-- planned: variant-browser-overview -->

The browser does not modify the underlying VCF. Sorts, filters, and selections are display state. If you want to write a filtered subset back to disk, use `File > Export Filtered VCF` once the filter is in place. So what should you do with this? Treat the browser as a read-only lens onto the VCF: filter aggressively to find the rows you care about, and export only when you are ready to hand a subset to a downstream tool.

## What you will learn

By the end of this chapter you will be able to navigate to a specific position in the variant browser, sort the table by any column, filter to PASS-only rows, read the INFO and FORMAT payloads in the Inspector for any selected row, and load multiple variant tracks at once for side-by-side reading.

## The variant table columns

The table draws columns directly from the VCF specification, with one Lungfish-specific addition (`Source`). Every column is sortable; click the header once for ascending, twice for descending. Reorder columns by dragging the header. Right-click the header bar to hide or show columns.

| Column | What it holds | Typical use |
|---|---|---|
| `Chrom` | Reference sequence name (`MN908947.3` for SARS-CoV-2) | Filter to one contig in multi-contig VCFs |
| `Pos` | 1-based reference coordinate of the variant | Sort to walk the genome 5' to 3' |
| `Ref` | Reference allele at that position | Confirm the base the caller compared against |
| `Alt` | Alternate allele the reads support | Read the variant itself |
| `Qual` | Phred-scaled caller confidence | Sort to triage low-confidence rows |
| `Filter` | Caller-assigned status (`PASS`, `LowQual`, `ft`, etc.) | Filter to confident calls only |
| `Source` | Which variant track the row came from | Distinguish iVar rows from LoFreq rows |
| `INFO.AF` | Allele frequency, fraction of reads supporting Alt | Triage minority vs. consensus variants |
| `INFO.DP` | Total read depth at the position | Reject calls from under-covered positions |
| `INFO.SB` | Strand-bias indicator (caller-specific) | Spot artefacts that appear on one strand only |
| `FORMAT.GT` | Per-sample genotype call | Read zygosity in diploid or pooled samples |
| `FORMAT.AD` | Per-sample allelic depth | Read raw counts behind the AF estimate |

The exact `INFO` and `FORMAT` columns depend on the caller. iVar emits `AF`, `DP`, `REF_DP`, `ALT_DP`, `ALT_QUAL`, and a `GFF_FEATURE`/`AA_REF`/`AA_ALT` triple when annotations are attached. LoFreq emits `AF`, `DP`, `SB`, and `DP4`. The browser shows whichever fields the loaded VCF defines; columns it has no data for stay empty.

## Procedure

The procedure has five steps. The first three open the browser and orient you in the table. The last two cover filtering and multi-track loading.

### Step 1. Open a variant track

Open the project from chapter [Calling Variants from Amplicons](01-calling-variants-from-amplicons.md), or any project with at least one variant track. In the sidebar, expand `Reference Sequences > MN908947.3 > Variants` and click the `iVar variants` track. The viewport switches to the variant browser. The genome track at the top now shows a row of ticks across the 29,903-base SARS-CoV-2 reference, one tick per VCF row. The table at the bottom fills with every row in the VCF, unfiltered.

If the track does not appear in the sidebar, the variant calling step from the previous chapter has not finished yet. Wait for the Operations Panel row to turn green, then try again.

### Step 2. Sort the table

Click the `Pos` column header. The table reorders so that the lowest-coordinate variant appears at the top. Click again to reverse the sort. Click the `Qual` header to sort by caller confidence; the highest-quality calls float to the top.

Sort is a display operation. It does not change the VCF on disk and it does not change which rows pass the filter. The sort indicator in the column header (a small chevron) shows the active sort.

### Step 3. Read a row in the Inspector

Click any row in the table. Three things happen at once. The genome track centres on that variant's position. The reference panel scrolls so that the cursor sits on the variant's reference base. The Inspector on the right fills with the per-row detail: every `INFO` field from the VCF, every `FORMAT` field for every sample, and any annotation context Lungfish can attach (gene name, codon, amino-acid consequence) when a GFF is present on the reference bundle.

<!-- planned: variant-browser-inspector -->

The Inspector is the canonical place to read a single variant. The table is dense and optimised for scanning; the Inspector is sparse and optimised for reading.

### Step 4. Filter the table

The filter bar sits above the table. Click the `Presets` toggle on the left. A row of chips appears: `PASS only`, `AF >= 0.5`, `DP >= 50`, `Coding`, `High confidence`. Click a chip to apply it; click again to remove it. Multiple chips combine with AND.

Type into the free-text field on the right of the filter bar to write a smart-filter query directly. The grammar is column-name, operator, value, separated by spaces or commas. Examples:

- `Filter=PASS` keeps only rows whose `Filter` column reads `PASS`.
- `AF>=0.5` keeps only rows where the allele frequency reaches half of reads or more.
- `DP>=50` keeps only rows with depth at or above 50 reads.
- `Sample[NA12878].GT=1/1` keeps rows where sample `NA12878` is homozygous alternate.
- `Sample[NA12878].AF>=0.5` keeps rows where sample `NA12878` has alternate allele balance of at least 0.5.
- `Sample[NA12878].DP>=30` keeps rows where sample `NA12878` has at least 30 reads at the site.
- `count(Sample[*].GT=1/1) >= 5` keeps cohort sites with at least five homozygous alternate sample calls.
- `Sample[NA12878].GT != Sample[NA12879].GT` keeps sites where those two samples have different stored genotype calls.
- `Pos>=21000 Pos<=25500` restricts to the spike gene window.
- `Source=iVar` keeps only rows from the `iVar variants` track when multiple tracks are open.

Comparison operators are `=`, `!=`, `<`, `<=`, `>`, `>=`. String values may be unquoted when they have no spaces; quote them when they do (`Gene="ORF1ab"`). Combine clauses with spaces (AND) or with the literal token `OR`. The filter bar shows a count of matched rows directly under the input.

For multi-sample VCFs, open the Samples view or sample selector and leave visible only the samples you want to compare. The variant table and genotype rows use that same visible-sample set, so hiding a sample removes its genotype column from the browser without changing the imported VCF.

<!-- planned: variant-browser-filter -->

### Step 5. Load multiple variant tracks together

The browser can show rows from more than one variant track at once. In the sidebar, Cmd-click a second variant track (for example, a `LoFreq variants` track on the same reference) while the first track is already open. The browser keeps the first track loaded and merges the second track's rows into the same table. Each row's `Source` column records which track it came from.

Multi-track mode is the natural setting for cross-caller comparison. With both `iVar variants` and `LoFreq variants` loaded, sort by `Pos` and read the table top to bottom: rows that agree across callers appear back-to-back at the same position with different `Source` labels; rows that only one caller produced appear alone. The next chapter, [Cross-Caller Comparison](03-cross-caller-comparison.md), works through this in detail.

<!-- planned: variant-browser-multi-track -->

## Worked walkthrough on SRR36291587

This walkthrough uses the project from the previous chapter. {{ fixtures_refs.sarscov2-srr36291587 | cite }} The reference bundle is `MN908947.3` with the NCBI GFF3 attached. The variant track is `iVar variants`, called from the primer-trimmed `SRR36291587` alignment with iVar defaults.

Open the project and click the `iVar variants` track in the sidebar. The browser fills. Sort the table by `Pos` ascending. Click the `Presets` toggle and select the `PASS only` chip. The row count under the filter bar drops from roughly 90 to roughly 80. The hidden rows are iVar calls below the consensus allele-frequency threshold; they carry the `ft` (failed threshold) flag in the `Filter` column. The chip applies the smart-filter expression `Filter=PASS` behind the scenes; you can verify this by clicking the chip while watching the free-text field.

Scroll to position `21618`. Click the row. The genome track centres on coordinate 21618. The reference panel shows the surrounding bases: `...CCTTGTC[T]TTGTTAA...` with the variant base highlighted. The Inspector on the right fills with the per-row detail. You should see `Ref C`, `Alt T`, `Qual` near the caller maximum, `Filter PASS`, `Source iVar variants`, and an `INFO` block that includes `AF` near `1.0`, `DP` in the high hundreds, and an annotation block reading `Gene S, Codon 19, AA T19I`. This is the canonical Omicron spike T19I mutation. The high allele frequency (every read supports the alternate) and the high depth (every read at this position has been counted) together mean this call is essentially certain.

Now switch the filter to `AF>=0.05 AF<0.5` by typing into the free-text field. The chip selection clears. The table now shows only minority variants: rows where the alternate allele is present in at least 5% of reads but in less than half. Expect a small handful of rows. These are the candidate within-host variants in this isolate. Their interpretation is biological, not technical: a true minority variant suggests a heterogeneous viral population, a contaminant, or an early sublineage shift, and the call alone cannot distinguish those. What the browser tells you is that the rows exist and that the `DP` and `Qual` columns are high enough to take them seriously.

Clear the filter by clicking the `x` on the right of the free-text field. The table returns to its full 90-row state.

## A practical reading guide

A useful triage habit when reading any variant table is to combine three columns in this order: `Filter`, then `INFO.AF`, then `INFO.DP`. The order matters because each column rejects a different failure mode.

The `Filter` column carries the caller's own opinion. A row tagged `PASS` met every internal threshold the caller checked. A row tagged anything else (`LowQual`, `ft`, `min_dp_10`, depending on the caller) failed at least one. Start by filtering to `Filter=PASS`. This step alone removes most noise.

The `INFO.AF` column sets your biological expectation. For a clonal viral sample, real variants cluster near `1.0` (every read supports the alternate). For a mixed or heterogeneous sample, real minority variants cluster between `0.05` and `0.5`. A row with `AF` near `0.01` is almost always sequencing error; a row with `AF` near `0.5` in a haploid organism is suspicious unless you expect mixed populations. Set an explicit floor (`AF>=0.05` for amplicon Illumina, higher for noisier protocols) and read what remains.

The `INFO.DP` column gates your confidence in the AF estimate. An `AF` of `0.5` from `DP=4` means two reads of evidence; an `AF` of `0.5` from `DP=400` means two hundred reads of evidence. The same allele frequency means very different things. As a working rule, treat `DP<20` as untrustworthy for amplicon Illumina viral calls and `DP<10` as untrustworthy for any caller. Combine with the AF floor: `Filter=PASS AF>=0.05 DP>=20` is a reasonable opening filter for amplicon Illumina viral data.

Two columns help when those three are not enough. `Qual` flags rows the caller was internally uncertain about even when they passed the filter; sort descending and check the bottom. `INFO.SB` (strand bias, when present) flags rows where the alternate allele was observed almost entirely on one read strand, which often indicates a mapping or trimming artefact rather than a real variant. Neither column is strictly necessary on a clean amplicon dataset, but both repay attention on shotgun or noisy data.

## Interpretation

A well-behaved variant browser session looks like this. The genome track shows ticks distributed across the reference rather than clustered at one end. The PASS-row count is in the expected range for your sample (about 80 for the SRR36291587 fixture; species-specific for other organisms). The high-confidence rows you spot-check carry `AF` near `1.0` and `DP` consistent with your expected sequencing depth. The Inspector fills with a populated annotation block, not an empty one.

A pathological session usually shows one of three things. Zero PASS rows almost always means the reference is wrong or the alignment failed; reopen the alignment track and check coverage before re-calling. A flood of low-AF rows (hundreds, mostly with `AF<0.1`) means the minimum allele frequency is too low for the noise level; raise it in the variant calling dialog and re-run. An empty annotation block means the GFF was not attached to the reference bundle; rebuild the bundle with the GFF and the codon-level fields will appear.

Multi-track sessions add a fourth check. If two callers on the same alignment disagree heavily (more than a quarter of rows present in only one track), one caller is mis-tuned for this data type. The next chapter walks through this case.

## Next

Continue to [Cross-Caller Comparison](03-cross-caller-comparison.md) to learn what to do when you have variants from two different callers, or [Consensus and Lineage](05-consensus-and-lineage.md) to take a VCF downstream.
