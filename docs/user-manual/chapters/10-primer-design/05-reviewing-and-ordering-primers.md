---
title: Reviewing and Ordering Primers
chapter_id: 10-primer-design/05-reviewing-and-ordering-primers
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 10-primer-design/02-designing-a-pcr-assay, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 20
task: Review a saved primer analysis in LGE, check each oligo against the alignment, save a tiled design as a primer scheme, export an order for a supplier, and validate the assay at the bench.
tags: [primer-design, primer-analysis, primer-order, primer-scheme, qpcr, validation, mhc]
tools: [primer3, primalscheme3, olivar, varvamp]
entry_points:
  - "Sidebar > Analyses > a .lungfishprimeranalysis bundle"
  - "Inspector > View > Export candidate pairs… / Export displayed primer order… / Export selected assays…"
  - "Viewer > Results > Save as Primer Scheme…"
  - "Viewer > Results > Create Annotated Reference…"
  - "CLI: lungfish-cli primers analysis inspect"
  - "CLI: lungfish-cli primers analysis export-order"
  - "CLI: lungfish-cli primers scheme-from-analysis"
shots:
  - id: primer-review-overview-varvamp
    caption: "The Overview of the Mamu-A1 tiled varVAMP analysis, showing the coverage card, the visible coverage note, the consensus threshold advisory, and the amplicon track with its two pools."
  - id: primer-review-primer3-results
    caption: "The Results tab of the Mamu-A1 exon 2-3 PCR Primer3 conserved analysis, with Pair 1 selected and its forward and reverse primer properties listed."
  - id: primer-review-binding-inspection
    caption: "Binding inspection for a forward primer of the Mamu-A1 tiled PrimalScheme analysis, with the alignment canvas above and the mismatch table below."
  - id: primer-review-inspector-view
    caption: "The Inspector's View tab for the Mamu-A1 tiled PrimalScheme analysis, showing the order export button, the strand and pool checkboxes, and the MSA matches filter."
  - id: primer-review-save-scheme
    caption: "The Save as Primer Scheme sheet for the Mamu-A1 tiled PrimalScheme analysis, stating its 49 primers, 8 amplicons, 2 pools, and the coordinate reference."
  - id: primer-review-order-sheet
    caption: "The Export Candidate Pairs sheet for the Mamu-A1 exon 2-3 PCR Primer3 conserved analysis, with the order name field, the optional order details, and the oligo preview."
illustrations: []
glossary_refs: [amplicon, primer, primer-scheme, primer-trim, primer-pool, primer-analysis-bundle, bed, fasta, csv, msa, iupac-ambiguity-code, degenerate-base, design-reference, consensus-sequence, provenance, checksum, inspector, operations-panel, sidebar, reference-bundle, annotation-track, bundle, manifest, oligo, probe, pcr, qpcr, cq, melting-temperature, xlsx]
features_refs: []
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

Every primer design in Lungfish Genome Explorer (LGE) ends as a [primer analysis bundle](../../GLOSSARY.md#primer-analysis-bundle), a `.lungfishprimeranalysis` folder saved in the project's `Analyses` folder, which the Finder shows as one file. It holds the inputs the engine saw, the engine's own output files, LGE's tidied copy of the results, and a [provenance](../../GLOSSARY.md#provenance) record of the settings and tool versions. Primer3, PrimalScheme, Olivar and varVAMP all save the same kind of bundle, so one viewer reviews all four.

This chapter owns what happens after a design finishes. It reads the viewer's three views, checks each [oligo](../../GLOSSARY.md#oligo) against every sequence the design was made from, saves a tiled design as a [primer scheme](../../GLOSSARY.md#primer-scheme) for trimming reads later, exports an order for a supplier, and lists the bench tests that prove the assay works.

That last step matters as much as the others. Everything LGE shows is an in-silico result, a prediction made by comparing sequences on a computer. It says a primer's letters match a template. It does not say the primer will anneal, extend, or amplify only the target in a real tube, as [Checking a design in silico and at the bench](01-what-is-primer-design.md#checking-a-design-in-silico-and-at-the-bench) explains.

## Why you would do this

The review step is where a design's problems show while they are still free to fix. A primer that looks perfect on one allele can fail on a second or bind a paralog you never meant to amplify, and *Mamu-A1*, this part's example, has both problems, for the reasons [Why you would do this](01-what-is-primer-design.md#why-you-would-do-this) sets out. Reviewing before you order, and testing on samples known to carry and to lack the target after the oligos arrive, is how you catch them.

## Before you start

You need the Primer Design demo project open, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, with at least one saved primer analysis in it. The demo project ships with inputs only, so run the designs in the three chapters before this one first. This chapter refers to the analyses by the names those chapters give them.

| Analysis in `Analyses/` | Engine and job |
|---|---|
| `Mamu-A1 exon 2-3 PCR Primer3` and `... conserved` | Primer3 PCR pairs on one allele and on the twelve-allele alignment |
| `Mamu-A1 tiled PrimalScheme` | PrimalScheme tiled scheme, 8 amplicons, 49 oligos |
| `Mamu-A1 tiled Olivar` | Olivar tiled scheme, 10 amplicons, 20 oligos |
| `Mamu-A1 tiled varVAMP` and `... threshold 0.8` | varVAMP tiled schemes at the automatic and the 0.8 threshold |
| `Mamu-A1 001 qPCR varVAMP` | varVAMP qPCR, five primer and probe assays, screened against the exclusion set |
| `Mamu-A1 001 qPCR Primer3 probe` and `... dye` | Primer3 qPCR pairs with and without a probe |
| `Mamu-A1 001 qPCR anchored` | Primer3 probe assay built around a fixed reverse primer |

Reviewing and saving a scheme run no plugin-pack tool, so every step here finishes in seconds. Order export runs the `zip` and `unzip` programs macOS already has, to fill in the supplier's workbook.

## Procedure

### Open a saved analysis

In the [sidebar](../../GLOSSARY.md#sidebar), open the `Analyses` folder, where primer analyses appear with a yellow list icon and without their extension, and click `Mamu-A1 tiled varVAMP`. The viewer shows "Loading saved primer analysis…" while it reads the bundle and checks the [checksum](../../GLOSSARY.md#checksum) of every stored file against the one recorded at design time. If a file has changed since, the viewer shows "Couldn't Load Primer Analysis" with the reason and a **Retry** button instead.

The segmented control at the top switches between **Overview**, **Results** and **Binding inspection**. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** if it is hidden, which for a primer analysis has the tabs **Bundle**, **View**, **Files** and **Provenance**. The Bundle tab names the grouping, the inputs, the results and the engine with its version, with a **Reveal Bundle in Finder** button. The Files tab lists every stored file with its role, format, size and checksum, under a line counting the verified payloads, and each file is a link that reveals it in Finder, which is the way to reach the engine's own outputs such as a BED of primer positions or varVAMP's own design table. The Provenance tab holds the full record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read.

### Read the Overview

<!-- SHOT: primer-review-overview-varvamp -->

The Overview holds one card per target. For a scheme a target is one reference sequence, and for Primer3 each candidate pair gets its own card, because the pairs are alternatives rather than parts of one scheme.

The large percentage at the top of the card is positional coverage, the share of the reference's bases inside at least one saved amplicon, counting overlaps once and including the primer sites. For `Mamu-A1 tiled varVAMP` it reads 95.0%. Read the note under it, and open "What this coverage figure does and does not mean" for the rest, which for PrimalScheme include the warning that positional coverage of the reference does not establish coverage of every alignment row or successful amplification. The line under the label gives covered bases, reference length, and bases outside any amplicon.

Advisories sit below that, for varVAMP only, as an information icon or an orange warning triangle. For the automatic run the advisory reads "Consensus threshold 0.99, chosen automatically by varVAMP. A base counts as conserved only when 12 of 12 sequences agree. Any threshold from 0.92 to 1.00 gives the same consensus for this alignment." In tiled mode a warning also appears whenever coverage falls below 95 percent, explaining that varVAMP keeps only the longest unbroken chain of overlapping amplicons. Last comes the amplicon track, one lane per pool, with amplicons as bars, forward primers in blue, reverse primers in orange and probes in purple. Hover over a bar for its span and pool, and click one to open its detail box.

A [primer pool](../../GLOSSARY.md#primer-pool) is the set of primers mixed into one tube, and a tiled scheme splits neighbouring amplicons between two pools so overlapping primers never meet, as [Multiplexing, pools and tiling](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains. varVAMP single and qPCR assays are unpooled, and their lanes read "Unpooled · selected assay" and "Unpooled · alternative rank" followed by a number, which are display groupings rather than pools. The button at the end of the Overview, **Inspect primers and pools** for a scheme or **Inspect candidate details** for Primer3, opens the Results tab.

### Read the Results

For a scheme, the Results tab lists every oligo, grouped by pool, titled "Selected scheme oligos" for PrimalScheme and "Reported assay oligos" for Olivar and varVAMP. Each row gives the oligo's name, its length and GC content, its role, its candidate status, which says whether the engine selected this oligo or offers it as an alternative, its sequence written 5′ to 3′, its position on the [design reference](../../GLOSSARY.md#design-reference), and its MSA match line.

An oligo with [degenerate bases](../../GLOSSARY.md#degenerate-base) shows "GC varies" and, in orange, a count of its ambiguous bases followed by "review synthesis representation". PrimalScheme handles variation the other way, keeping several exact oligos at one binding site, named for example `a5686d1c_1_LEFT_1` through `a5686d1c_1_LEFT_7` in the demo run. The detail box calls them the "Selected primer set" and says they are all selected components rather than backup candidates, so order every one and mix them together. The suffix numbers are not ranks and do not pair a LEFT with a RIGHT.

<!-- SHOT: primer-review-primer3-results -->

For Primer3 the tab is titled "Primer3 results". Open `Mamu-A1 exon 2-3 PCR Primer3 conserved` to see it. Choose the template from the **Template** menu if the design used more than one, then read the summary line, which gives the template length, the number of candidate pairs, and a reminder that coordinates are 1-based inclusive. Click a pair in the **Candidates** list, which keeps Primer3's own order, so Pair 1 sits closest to the optimum values you set, which is not the same as binding best. **Primer properties** then gives one row each for the forward primer, the reverse primer and, for a probe design, the internal probe, with length, melting temperature and GC content. The best conserved pair in the demo is `CGGGTCTCAGCCTCTCCT` and `GAGGATTCCTCTCCCTCAGGA`, melting temperatures 60.0 and 59.8 °C, product 948 bp. Two disclosures sit below, **Template sequence with selected binding sites**, which prints the template with the primers coloured, and **Primer3 explanation**, which holds the per-oligo and pair tallies that [The Primer3 explanation line](02-designing-a-pcr-assay.md#the-primer3-explanation-line) explains.

Every position the viewer shows is 1-based inclusive. **Copy Coordinates**, the saved order sheet and the order CSV use the same form, and a [BED](../../GLOSSARY.md#bed) file does not. A BED, such as the engine's own `primer.bed` in the Files tab or the `primers.bed` inside a saved scheme, is 0-based and half-open, so its start counts the first base as 0 and its end is the base just past the feature. The demo's `a5686d1c_1_LEFT_1` appears as 211 to 233 in the viewer and as 210 and 233 in `primer.bed`, and both describe the same 23 bases. To turn a BED range into the viewer's form, add 1 to the start and leave the end alone.

### Inspect binding against the alignment

<!-- SHOT: primer-review-binding-inspection -->

Binding inspection lines up one primer against every row of the alignment it was designed on. It appears for PrimalScheme, Olivar and varVAMP results, and for Primer3 results designed from an alignment. A Primer3 design on a single sequence shows the tab but only explains that there is no alignment to compare against.

1. Select a primer in the Overview or Results tab and click **Inspect in alignment**, or Control-click the primer and choose **Inspect in Alignment**.
2. Check the **Target alignment** and **Compare primer** menus at the top of "Alignment & primer sites". Compare primer starts at "Choose a visible primer" if nothing was selected.
3. Look at the alignment canvas. The primer's footprint is underlined, and the toggle above the canvas turns dots on, so that a base matching the primer inside the footprint is drawn as a dot and only mismatched or unknown bases show as letters. Purple marks on the ruler flag variable columns, and orange marks on the strip above the canvas flag columns with gaps.
4. Read the header of the table below, "MSA matches" with a percentage and a count in parentheses. It counts the rows with no incompatible base under the primer, out of the rows that could be compared.
5. Read the table row by row. **Alignment row** names each sequence and **Reference-oriented site** shows its bases under the primer, with mismatched bases orange, bold and underlined.

Each row carries a status. "0 mismatches (IUPAC-compatible)" means every base matches, counting a degenerate primer base as matching any base it stands for. A count followed by "positional mismatches" is the number of bases where that sequence differs. Statuses beginning "Unknown" or "Unavailable" mean the row could not be compared, the commonest being `Unknown: uncovered alignment end`, where the sequence stops before the primer site, `Unavailable: internal alignment gap`, and `Unknown: ambiguous sequence bases`. Those rows are left out of the percentage rather than counted as matches, so a row that reads Unknown is not evidence of a match. An alignment row stored as RNA, with U in place of T, is compared as T.

The position of a mismatch matters as much as the count. A mismatch within the last few bases of the primer's 3′ end can stop extension altogether, while one near the 5′ end is usually tolerated, as [When the target varies](01-what-is-primer-design.md#when-the-target-varies) explains. The table is reference-oriented, so for a forward primer the 3′ end is the rightmost base of the site and for a reverse primer it is the leftmost. Read a reverse primer's row from left to right and the first base you see is the one that decides whether the allele amplifies.

For the demo's varVAMP qPCR assays, every oligo matches all four lineage sequences. That is what the engine was asked for, and it says nothing about the eighteen exclusion sequences, which were never in that alignment. [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) is where that check happens.

### Save a tiled scheme as a primer scheme

<!-- SHOT: primer-review-save-scheme -->

A tiled scheme becomes useful a second time after sequencing, when its primer positions are needed to trim primer bases off reads. Open `Mamu-A1 tiled PrimalScheme`, go to **Results**, and click **Save as Primer Scheme…**, which also sits in the Inspector's View tab. Read the sheet before saving. It states the engine and counts, "PrimalScheme3 · 49 primers · 8 amplicons · 2 pools" for the demo, then the **Coordinate reference** the primer positions belong to and a sentence explaining it. Edit **Scheme name**, which defaults to the analysis name followed by the result's label and the word scheme, and click **Save**.

The operation writes the bundle into `Primer Schemes/`, and the Primer Trim dialog lists it under In This Project. Read the coordinate reference carefully, because it is the sequence the engine designed on, the first alignment row for PrimalScheme, Olivar's generated reference, or varVAMP's ambiguous consensus. Reads must be mapped to that sequence, which the bundle carries as `attachments/design-reference.fasta`, before the scheme can trim them, as [Matching the scheme to your alignment](../appendices/primer-schemes.md#matching-the-scheme-to-your-alignment) explains, and [Saving a designed scheme](../appendices/primer-schemes.md#saving-a-designed-scheme) documents the bundle.

The button is disabled for results that are not tiled schemes, and the reason appears beside it. For Primer3 it reads that candidate pairs are alternatives rather than a tiled scheme, and a varVAMP qPCR result is refused the same way. A result whose primers sit on more than one reference is refused, so save each single-reference result instead, and a design with no selected primers, or one whose oligo names repeat, is refused too.

### Export an order

<!-- SHOT: primer-review-order-sheet -->

Order export lives in the Inspector's **View** tab and captures a fixed set of oligos when you click it. The button and what it captures depend on the engine.

| Engine | Button | What is ordered |
|---|---|---|
| Primer3 | **Export candidate pairs…** | Forward, reverse and probe of every included candidate pair |
| PrimalScheme | **Export displayed primer order…** | The oligos currently displayed after the View tab's filters |
| Olivar and varVAMP | **Export selected assays…** | The assays the engine's ranking marked as selected, with their probes |
| Olivar and varVAMP, when alternatives exist | **Export all reported assays…** | Selected and alternative assays together |

1. Open `Mamu-A1 exon 2-3 PCR Primer3 conserved` and click the Inspector's **View** tab, which lists the candidate pairs with a checkbox each and a count of pairs included.
2. Untick the pairs you do not want. Order two or three pairs for a new assay, since the first pair does not always work best at the bench.
3. Click **Export candidate pairs…**. The sheet opens with a summary of oligos and order groups, and a note that each pair is its own order group rather than a pool.
4. Fill **Order name**, which is required, and open **Order details (optional)** to add Requested by, Project label, Order reference and Notes.
5. Check the **Oligo preview**, which shows the first eight oligos 5′ to 3′, and click **Export**.

The operation writes a folder named after the order into `Analyses/`, and selecting it opens the Primer Order viewer. For a varVAMP qPCR analysis the route is the same with a different button. Open `Mamu-A1 001 qPCR varVAMP`, and **Export selected assays…** orders the one assay LGE marks as selected, the lowest-penalty one. To order a different assay, such as the most discriminating rather than the lowest-penalty one, use **Export all reported assays…** and delete the rows you do not want from the workbook before sending it.

For a scheme, the View tab also holds display filters. **Forward oligos (+)** and **Reverse oligos (−)** hide a strand, the pool checkboxes hide a pool, and the disclosure named "Advanced, individual oligos" hides single oligos. Under **MSA matches**, **Filter by MSA matches** and the **Minimum MSA matches** slider hide oligos that match fewer alignment rows than the threshold. These filters change what PrimalScheme's **Export displayed primer order…** captures, which makes them a way to order one pool or drop a rarely needed variant. They never change the saved design, and Olivar and varVAMP orders ignore them.

<!-- SHOT: primer-review-inspector-view -->

### Create an annotated reference from a Primer3 result

Open a Primer3 analysis, go to **Results**, and click **Create Annotated Reference…**. LGE writes the reference into the project's own `Analyses` folder and the line under the button reads "Creating annotated reference…" and then names the saved bundle. Click **Open Annotated Reference** to view the template with every candidate primer and probe as an [annotation track](../../GLOSSARY.md#annotation-track). The bundle is named after the template with "primers" added, and its track is named `Primer analysis:` followed by the template name.

## Settings

The order sheet and the scheme sheet are the only places in this chapter where you type a value.

**Order name.** Names the order folder LGE writes and fills the order name column of every file in it. The default is the analysis name followed by "candidate pairs order", "order" or "all reported assays order", depending on the button. Change it to something your supplier and your lab notebook will both recognise, such as a date and a target. On the command line this is `--name`.

**Order details.** Adds Requested by, Project label, Order reference and Notes to the order metadata worksheet and to the CSV and JSON records. The default is blank, since LGE cannot know your purchasing details. Fill them when the order goes through a core facility or a grant account that needs a reference. On the command line these are `--requested-by`, `--project`, `--order-reference` and `--notes`.

**Scheme name.** Names the `.lungfishprimers` bundle that **Save as Primer Scheme…** writes. The default joins the analysis name, the result label and the word scheme, which is exact but long. Shorten it, because the Primer Trim dialog shows it in a menu, and note that a name already used in `Primer Schemes/` is refused rather than overwritten. On the command line this is `--output`.

## Reading the results

An order folder holds the order workbook `primer-order.xlsx`, a CSV of the same rows named `ordering.csv`, a JSON record named `order.json` that preserves the exact assay, oligo, role, candidate and pool behind every row, and `template.xlsx`, the blank supplier template the workbook was filled from.

The workbook's first sheet depends on the order. For Primer3 pairs and unpooled varVAMP assays it is Assay review, which lists order group, oligo name, sequence, role, candidate status and pool. For a pooled scheme it is the supplier's own template sheet, filled in, with the order metadata beside it. When every oligo belongs to a native pool, as in a PrimalScheme or Olivar scheme, the folder also holds an upload-only workbook in one supplier's pooled-oligo format, which LGE labels the IDT oPools workbook after the company whose format it is. Primer3 pairs have no pools, so their orders never include it. The CSV adds each oligo's length, its 1-based start and end on the design reference, its strand and its MSA match counts.

The Primer Order viewer shows the counts, the order groups, and every exported oligo with its reference and position, and its buttons **Open order workbook**, **Open IDT upload copy** and **Open CSV** open the files in their default applications. The Inspector repeats the metadata and notes that the order is a subset of the original design rather than a new or validated scheme.

Primer3 oligos have no names of their own, so LGE builds one from the record's own identifier, the pair number and the role, giving names such as `LR699574.1_P1_LEFT`, `LR699574.1_P1_PROBE` and `LR699574.1_P1_RIGHT`. A long name is shortened by dropping whole fields from the end rather than cutting mid-field, so a shortened name is still a readable prefix. Each pair becomes an order group named `Template_1_Candidate_1` and so on. PrimalScheme names come from the engine and begin with a short run code, as in `a5686d1c_1_LEFT_1`, which is unique but not readable, so rename oligos to your own convention on the supplier's form and keep the LGE name in a notes column so the order traces back to the analysis.

## Placing the order

LGE's export does not choose synthesis options, because those depend on your supplier and your chemistry. Add the following on the supplier's form or in the workbook before you send it.

| Item | What to enter |
|---|---|
| Name | One unique name per oligo, without spaces. Keep the LGE name in a notes column. |
| Sequence | Exactly as exported, 5′ to 3′. Never reverse-complement a reverse primer by hand, because LGE already stores it in the orientation you order. |
| Scale | The amount synthesised. The smallest a supplier offers, often 25 nmol, is ample for PCR primers, and a labelled probe is usually sold at a fixed small scale of its own. |
| Purification | Standard desalting, which removes synthesis salts and nothing else, is usual for PCR primers. Dye-labelled probes are normally purified by HPLC, a chromatography step many suppliers require. |
| Degenerate bases | Enter the IUPAC letter, such as K, and choose a mixed base, where the synthesiser adds an equal mixture of the bases at that position. |
| Probe labels | A 5′ reporter dye and a 3′ quencher that match your instrument's detection channels, the wavelengths it can read. FAM with a BHQ-1 or TAMRA quencher is a common first choice on almost every instrument, and your core facility will know which channels yours reads. |

A degenerate oligo is a mixture. varVAMP_0's probe, `TATCGCCCTCCCTCTGKTCCTGAGG`, is really two probes, one with G and one with T at the K, each at half the concentration. If a supplier will not place a mixed base in a labelled probe, order the two versions separately and mix them, or set **Maximum probe ambiguities** to 0 and design again.

Name oligos so a stranger can read them. A workable pattern is target, assay and role, such as `MamuA1_ex2-3_F` and `MamuA1_ex2-3_R` for the PCR pair, or `MamuA1-001_q0_F`, `MamuA1-001_q0_P` and `MamuA1-001_q0_R` for varVAMP_0. Keep LEFT and RIGHT, or F and R, in every name, since the engines use them to mark strand.

## What good looks like

Before ordering, the in-silico checks should all pass. Every oligo you order should show 0 mismatches against every assessable row it is meant to detect, or mismatches only near its 5′ end. The numbers should agree with what the design chapter reported, such as a 948 bp product for the conserved Primer3 pair, 91.0 percent coverage for PrimalScheme and 99.3 percent for varVAMP at threshold 0.8. For an assay that must tell one lineage or gene from another you also need evidence that it does not match the sequences to exclude, which the design engines do not provide unless you give them an exclusion set, as [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) shows on the demo.

### Bench validation

After the oligos arrive, validate the assay at the bench. The usual sequence is as follows.

1. Run a gradient PCR, one reaction per well across a range of annealing temperatures starting a few degrees below the primers' melting temperature. Pick the highest temperature that still gives strong product, since higher annealing favours specific binding.
2. Check for a single product of the expected size. For end-point PCR, run an agarose gel beside a size ladder and look for one band at the designed length, such as 948 bp for the conserved exon 2 to 3 pair. For a dye qPCR assay, run a melt curve after cycling and look for one peak, since a second peak means a second product or primer dimers.
3. For a quantitative assay, build a standard curve from a tenfold dilution series run in replicate, meaning several wells per dilution so a single pipetting error shows up. Report the slope, the y-intercept, the R² and the efficiency, as MIQE asks. Efficiency should fall between 90 and 110 percent, which is a slope of about −3.6 to −3.1, since efficiency = 10^(−1/slope) − 1. For a presence or absence assay, also establish the lowest amount of DNA that still gives a signal in most replicates, which matters more than efficiency does.
4. Sequence the product and confirm it is the intended gene and region rather than a paralog.
5. Test on samples of known type. For a *Mamu-A1\*001* lineage assay, run animals already typed as positive and animals typed as negative, for example by [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md). Positives must amplify and negatives must not, and every sample should also pass a control assay for a gene every animal carries, so a failed reaction is never read as a negative animal. Include no-template controls, which must stay negative.

The fifth test is the one that would expose the demo's first varVAMP qPCR assays. At least one primer of every one of them matches most of the eighteen exclusion sequences perfectly, so animals lacking the lineage would be expected to amplify, and testing typed negatives is how you would confirm that before relying on any lineage call. The anchored assay in [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) is the one to take to the bench instead. The MIQE guidelines ([Bustin and colleagues 2009](../appendices/bibliography.md#primer-design-background)) list what a qPCR publication should report about all of these steps.

### When a check fails

No product at any gradient temperature points to a primer that does not bind the samples, so check the binding table for 3′ mismatches against the alleles your animals carry. Several bands or melt peaks point to a second target, often a paralog, so sequence the extra product. Efficiency outside 90 to 110 percent usually comes from a pipetting error in the dilution series, and after that from inhibitors, substances in the sample that slow the polymerase, so rebuild the series before redesigning.

Inside LGE, three messages have one cause each. "Couldn't Load Primer Analysis" means a stored file's checksum no longer matches the record, usually because something inside the bundle was edited, moved or partly copied, and the fix is to restore the bundle or rerun the design. A disabled export button gives its reason in a tooltip, such as "Include at least one candidate pair to export an order." or "Show at least one oligo to export an order.", which **Show all** fixes. And a saved scheme that trims almost nothing means the reads went to a different sequence from the scheme's coordinate reference. Other app problems are listed in [Troubleshooting](../appendices/troubleshooting.md).

## On the command line

This section is optional. Every block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and the flags are listed under [Primer schemes and primer design](../appendices/cli-reference.md#primer-schemes-and-primer-design).

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Primer Design.lungfish"

# Verify every stored file and print the analysis summary
lungfish-cli primers analysis inspect \
  "$PROJECT/Analyses/Mamu-A1 exon 2-3 PCR Primer3 conserved.lungfishprimeranalysis"

# List the results that can become a primer scheme, then save one
lungfish-cli primers scheme-from-analysis \
  "$PROJECT/Analyses/Mamu-A1 tiled PrimalScheme.lungfishprimeranalysis" --list
lungfish-cli primers scheme-from-analysis \
  "$PROJECT/Analyses/Mamu-A1 tiled PrimalScheme.lungfishprimeranalysis" \
  --project "$PROJECT" --output "Mamu-A1 tiled PrimalScheme"

# Export the same order the Inspector writes
lungfish-cli primers analysis export-order \
  "$PROJECT/Analyses/Mamu-A1 exon 2-3 PCR Primer3 conserved.lungfishprimeranalysis" \
  --scope candidate-pairs --name "Mamu-A1 exon 2-3 order" \
  --output "$PROJECT/Analyses/Mamu-A1 exon 2-3 order"
```

On the demo, `inspect` prints "Integrity verified" after counting the inputs, results and stored files, followed by a summary of the results. Add `--json` to print the full manifest, which is where a result's identifier comes from for `--result-id`. `--list` prints each result's engine, coordinate reference and counts, or the reason it cannot be saved, and for `Mamu-A1 001 qPCR varVAMP` it explains that primer trimming needs a tiled amplicon scheme. `export-order` writes the same files the window writes, and its `--scope` takes `candidate-pairs`, `selected-assays`, `all-reported-assays` or `displayed`, defaulting to whichever suits the analysis. `primers analysis annotated-reference` writes the annotated reference, and `primers analysis history` and `audit` replay how a PrimalScheme run chose its panel, for people developing the design method.

## Next

This is the last chapter of the Primer Design part. For a tiled scheme, sequence the amplicons and continue with [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) using the scheme you saved here, then call variants as [Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md) shows. For an MHC panel, [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) is the downstream instead, and [Primer Scheme Bundles](../appendices/primer-schemes.md) documents the bundle a saved scheme writes. Record which analysis and which candidate an assay came from alongside the order in your lab notebook, because the analysis bundle holds the provenance that explains it.
