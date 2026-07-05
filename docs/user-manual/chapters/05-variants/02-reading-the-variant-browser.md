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
    caption: "The variant browser with the genome track on top and the ID, Chrom, Position, Ref, Alt, Quality, Filter, and Source columns in the table below."
  - id: variant-browser-filter
    caption: "The variant table filter bar with the PASS smart-filter chip selected."
  - id: variant-browser-inspector
    caption: "The Inspector showing the INFO and FORMAT payload for a selected variant row."
  - id: variant-browser-source-column
    caption: "A bundle with two variant tracks aggregated into one table, with the Source column distinguishing the iVar and LoFreq rows."
illustrations: []
glossary_refs: [VCF, allele-frequency, FILTER, INFO, FORMAT, depth]
features_refs: [viewport.variant-browser]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

The variant browser is the main surface in Lungfish for reading, sorting, and exporting variants. Click a variant track in the sidebar and it opens, filling the full viewport area of the project window. It marries a coordinate-aware view of the genome to a tabular view of every row in the underlying VCF, so you can swing between "where on the genome is this variant" and "what does this variant say" without leaving the page.

Three regions stack vertically. At the top, a genome track draws each variant as a tick at its reference position. Below it, a reference panel shows the bases under the cursor and updates as you navigate. At the bottom sits a sortable variant table, one row per variant, carrying the standard VCF columns plus a `Source` column that records which source file each row came from. When a reference bundle holds more than one variant track, the browser loads them all into this single table at once, and the `Source` column is how you tell them apart. A filter bar above the table takes both chip-style presets and free-text smart-filter queries.

<!-- planned: variant-browser-overview -->

The browser never touches the underlying VCF. Sorts, filters, and selections are display state and nothing more. To write a filtered subset back to disk, use the CLI command `lungfish variants query` with a `--filter` expression and an `--output` path; the in-app table stays read-only. Treat the browser as a read-only lens onto the VCF: filter hard to surface the rows you care about, then run `variants query` when you are ready to hand a subset to a downstream tool.

## What you will learn

This chapter leaves you able to jump to any position in the variant browser, sort the table by any column, filter down to PASS-only rows, read the INFO and FORMAT payloads in the Inspector for a selected row, and read two variant tracks side by side when a bundle carries more than one.

## The variant table columns

The table has eight fixed columns: seven from the VCF specification and one, `Source`, that is Lungfish-specific. Every column sorts on click, once for ascending, twice for descending. Drag a header to reorder columns, and right-click the header bar to hide or show them.

| Column | What it holds | Typical use |
|---|---|---|
| `ID` | The VCF `ID` field (often `.` when the caller assigns none) | Look up a named or catalogued variant |
| `Chrom` | Reference sequence name (`MN908947.3` for SARS-CoV-2) | Filter to one contig in multi-contig VCFs |
| `Position` | 1-based reference coordinate of the variant | Sort to walk the genome 5' to 3' |
| `Ref` | Reference allele at that position | Confirm the base the caller compared against |
| `Alt` | Alternate allele the reads support | Read the variant itself |
| `Quality` | Phred-scaled caller confidence | Sort to triage low-confidence rows |
| `Filter` | Caller-assigned status (`PASS`, `ft`, `sb_fdr`, etc.) | Filter to confident calls only |
| `Source` | The source file each row came from | Tell two callers' rows apart in one table |

Beyond those eight, the table promotes whatever `INFO` keys the loaded VCF actually defines into columns of their own. There is no fixed list and no dotted `INFO.AF` naming: a key named `AF` becomes a column titled `AF`, a key named `DP` becomes `DP`, and so on. Which columns appear therefore depends on the caller. A LoFreq VCF defines `DP`, `AF`, `SB`, and `DP4` in `INFO`, so those four show up. A Lungfish iVar VCF defines only `TYPE` in `INFO` and keeps depth and allele frequency in the per-sample `FORMAT` payload (`DP`, `ALT_FREQ`, and `MERGED_AF`/`MERGED_DP` on merged rows), so an iVar table promotes fewer `INFO` columns and you read its depth and frequency from the Inspector or the genotype view instead.

Per-sample genotype data stays out of the main table's columns. Instead, a `GT` sub-tab above the table flips the view from one-row-per-variant to one-row-per-sample genotype, so you can read zygosity and allelic depth for a multi-sample VCF without crowding the variant rows. For multi-sample VCFs, the left-pane sample selector governs which samples that genotype view and the per-sample filters apply to; hide the samples you are not comparing before you filter.

## Procedure

Five steps follow. The first three open the browser and orient you in the table. The last two cover filtering and multi-track loading.

### Step 1. Open a variant track

Open the project from [Calling Variants from Amplicons](01-calling-variants-from-amplicons.md), or any project with at least one variant track. In the sidebar, expand `Reference Sequences > MN908947.3 > Variants` and click the `iVar variants` track. The viewport switches to the variant browser. The genome track at the top now shows a row of ticks across the 29,903-base SARS-CoV-2 reference, one tick per VCF row, and the table at the bottom fills with every row in the VCF, unfiltered.

If the track is missing from the sidebar, the variant calling step from the previous chapter has not finished. Wait for the Operations Panel row to turn green, then try again.

### Step 2. Sort the table

Click the `Position` column header. The table reorders so the lowest-coordinate variant sits at the top. Click again to reverse it. Click the `Quality` header to sort by caller confidence, and the highest-quality calls float to the top.

Sorting is a display operation. It leaves the VCF on disk untouched and does not change which rows pass the filter. A small chevron in the column header marks the active sort.

The variant table is a standard macOS table, so it inherits the system keyboard and VoiceOver behaviour. Once the table has keyboard focus (tab to it, or click any row), VoiceOver announces the focused cell and its column, and the column headers are reachable as buttons you can activate to sort. If you work without a mouse, give the table focus first, then drive sorting from the header buttons.

### Step 3. Read a row in the Inspector

Click any row in the table and three things happen at once. The genome track centres on that variant's position, the reference panel scrolls until the cursor sits on the variant's reference base, and the Inspector on the right fills with the per-row detail: every `INFO` field from the VCF, every `FORMAT` field for every sample, and any annotation context Lungfish can attach (gene name, codon, amino-acid consequence) when a GFF sits on the reference bundle.

<!-- planned: variant-browser-inspector -->

The Inspector is the canonical place to read a single variant. The table is dense and built for scanning; the Inspector is sparse and built for reading. Once the table has keyboard focus, the up and down arrow keys move the selection row to row, and the genome track, reference panel, and Inspector all follow the focused row exactly as they do on a click.

### Step 4. Filter the table

The filter bar sits above the table. Click the `Presets` toggle on the left to reveal a row of curated chips. Click a chip to apply it, click again to remove it, and stack chips to narrow further. The curated set includes `PASS`, `SNV`, `Indel`, `High Impact`, `Qual >= 30`, `DP >= 10`, and three chips built for reading viral minority variants: `Minor (<=20%)`, `Mixed (20-80%)`, and `Dominant (>=80%)`. Those last three are the fastest way to triage within-host frequency in a viral sample. Alongside the curated chips, Presets also generates value chips from the `INFO` keys the loaded VCF actually carries, so the exact list depends on the file.

Type into the free-text field on the right of the filter bar to write a smart-filter query directly. A clause is a key, an operator, and a value; the operators are `=`, `!=`, `<`, `<=`, `>`, `>=`, and `~` (contains). Quote a string value only when it contains a space. The filter bar shows a count of matched rows directly under the input. These examples filter the whole table:

- `Filter=PASS` keeps only rows whose `Filter` column reads `PASS`.
- `AF>=0.5` keeps only rows where the allele frequency reaches half of reads or more.
- `DP>=50` keeps only rows with depth at or above 50 reads.
- `Position>=21000` keeps rows at or beyond coordinate 21000.
- `AF>=0.05 AF<0.5` keeps rows in the minority-variant band.

Clauses are joined by AND only: writing two clauses separated by a space keeps the rows that satisfy both. There is no `OR` operator between clauses, no colon syntax such as `Pos:1193`, and no `Source=` key. To pull one track's rows out of an aggregated table, filter on a column that differs between the tracks rather than on `Source`.

<!-- planned: variant-browser-filter -->

For a multi-sample VCF, the same field can be addressed inside one named sample, and a `count(...)` predicate can range over every sample. These per-sample clauses match the CLI `variants query` grammar exactly:

- `Sample[NA12878].GT=1/1` keeps variants where sample `NA12878` is homozygous alternate.
- `Sample[NA12878].AF>=0.5` keeps variants where that sample's alternate allele fraction is at least 0.5.
- `Sample[NA12878].DP>=30` keeps variants where that sample's genotype depth is at least 30.
- `count(Sample[*].GT=1/1) >= 5` keeps variants with at least five homozygous-alternate samples.
- `Sample[NA12878].GT != Sample[NA12879].GT` keeps variants where two samples have different genotype calls.

For multi-sample VCFs, open the sample selector and leave visible only the samples you want to compare. The genotype view and the per-sample filters draw on that same visible-sample set, so hiding a sample drops it from the browser without changing the imported VCF.

### Step 5. Read two callers in one aggregated table

When a reference bundle carries more than one variant track, the browser shows them all in one table automatically. You never load a second track by hand: open the variant browser on a bundle that holds both an `iVar variants` track and a `LoFreq variants` track, and one table fills with the rows from both, each row's `Source` column recording the file it came from.

This aggregated table is the substrate for reading two callers side by side. Sort by `Position` and read top to bottom: rows both callers reported appear at the same coordinate with different `Source` values, and rows only one caller produced appear alone. Tell the callers apart by the text in the `Source` column, not the tick color on the genome track. The ticks are color-coded, but the `Source` column is the readable discriminator, and the only one that survives print, small sizes, or a colorblind reader. The next chapter, [Reading Two Callers in One Table](03-cross-caller-comparison.md), works through the disagreements in detail.

<!-- planned: variant-browser-source-column -->

## Worked walkthrough on SRR36291587

This walkthrough uses the project from the previous chapter. {{ fixtures_refs.sarscov2-srr36291587 | cite }} The reference bundle is `MN908947.3` with the NCBI GFF3 attached. The variant track is `iVar variants`, called from the primer-trimmed `SRR36291587` alignment with iVar defaults.

Open the project and click the `iVar variants` track in the sidebar. The browser fills. Sort by `Position` ascending, click the `Presets` toggle, and select the `PASS` chip. The row count under the filter bar drops as the below-threshold calls fall away, each carrying the `ft` flag in the `Filter` column. The chip applies the smart-filter expression `Filter=PASS` behind the scenes; watch the free-text field as you click the chip and you can see it appear.

Scroll to position `21618` and click the row. The genome track centres on coordinate 21618, the reference panel shows the surrounding bases with the variant base highlighted, and the Inspector on the right fills with the per-row detail. You should see `Ref C`, `Alt T`, `Quality` near the caller maximum, `Filter PASS`, and the per-sample `FORMAT` values: a genotype of `1`, a high depth, and an `ALT_FREQ` near `1.0`. The Inspector also shows the annotation block `Gene S, Codon 19, AA T19I`, which it derives from the bundle's GFF3 rather than reading from the VCF. This is the canonical Omicron spike T19I mutation. High allele frequency (every read supports the alternate) and high depth (every read at this position has been counted) together make this call essentially certain.

Now type `AF>=0.05 AF<0.5` into the free-text field. The chip selection clears, and the table narrows to minority variants: rows where the alternate allele is present in at least 5% of reads but in fewer than half. Expect a small handful. These are the candidate within-host variants in this isolate, and their interpretation is biological, not technical. A true minority variant may signal a heterogeneous viral population, a contaminant, or an early sublineage shift, and the call alone cannot tell those apart. What the browser tells you is that the rows exist and that the depth and quality behind them are high enough to take seriously.

Clear the filter by clicking the `x` at the right of the free-text field. The table returns to its full unfiltered state.

## A practical reading guide

A reliable triage habit for any variant table is to weigh three things in order: the `Filter` column first, then allele frequency, then depth. The order matters because each one rejects a different failure mode. Where allele frequency and depth live depends on the caller: a LoFreq VCF promotes them as `AF` and `DP` columns, while an iVar VCF keeps them in the per-sample `FORMAT` payload (`ALT_FREQ` and `DP`), which you read in the Inspector or the genotype view.

The `Filter` column carries the caller's own verdict. A row tagged `PASS` met every internal threshold the caller checked. A row tagged anything else (`ft`, `sb_fdr`, `min_dp_10`, depending on the caller) failed at least one. Start by filtering to `Filter=PASS`. That single step clears most of the noise.

Allele frequency sets your biological expectation. In a clonal viral sample, real variants cluster near `1.0`, where every read supports the alternate. In a mixed or heterogeneous sample, real minority variants cluster between `0.05` and `0.5`. A row near `0.01` is almost always sequencing error, and a row near `0.5` in a haploid organism is suspicious unless you expect mixed populations. Set an explicit floor (`AF>=0.05` for amplicon Illumina, higher for noisier protocols) and read what remains.

Depth gates your confidence in that frequency estimate. A frequency of `0.5` at a depth of 4 rests on two reads; the same `0.5` at a depth of 400 rests on two hundred. Identical frequency, wildly different weight. As a working rule, treat depth below 20 as untrustworthy for amplicon Illumina viral calls, and below 10 as untrustworthy for any caller. Fold it into the frequency floor: `Filter=PASS AF>=0.05 DP>=20` makes a reasonable opening filter for a caller that promotes those keys.

Two more signals help when those three fall short. `Quality` flags rows the caller stayed internally uncertain about even after they passed the filter; sort descending and check the bottom. Strand bias (LoFreq's `SB` column, when present) flags rows where the alternate allele turned up almost entirely on one read strand, which usually points to a mapping or trimming artefact rather than a real variant. Neither is strictly necessary on a clean amplicon dataset, but both repay attention on shotgun or noisy data.

## Interpretation

A well-behaved variant browser session looks like this. The genome track spreads ticks across the reference rather than bunching them at one end. The PASS-row count lands in the expected range for your sample (roughly 80 for the SRR36291587 fixture, an illustrative figure rather than a guaranteed output, and species-specific for other organisms). High-confidence rows you spot-check carry an allele frequency near `1.0` and a depth in line with your expected sequencing depth. And the Inspector fills with a populated annotation block, not an empty one.

A pathological session usually shows one of three tells. Zero PASS rows almost always means the reference is wrong or the alignment failed; reopen the alignment track and check coverage before re-calling. A flood of low-frequency rows (hundreds, mostly below `0.1`) means the minimum allele frequency sits too low for the noise level; raise it in the variant calling dialog and re-run. An empty annotation block means the GFF never reached the reference bundle; rebuild the bundle with the GFF and the codon-level fields will appear.

When a bundle carries two callers' tracks, add a fourth check. If the two callers on the same alignment disagree heavily, more than a quarter of rows present under only one `Source`, then one caller is mis-tuned for this data type. The next chapter walks through that case.

## Next

Continue to [Reading Two Callers in One Table](03-cross-caller-comparison.md) to learn what to do when a bundle carries variants from two different callers, or [Consensus and Lineage](05-consensus-and-lineage.md) to take a VCF downstream.
