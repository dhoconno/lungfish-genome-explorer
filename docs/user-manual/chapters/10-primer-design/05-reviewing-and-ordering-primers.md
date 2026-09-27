---
title: Reviewing and Ordering Primers
chapter_id: 10-primer-design/05-reviewing-and-ordering-primers
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 22
task: Review a saved primer analysis in LGE, export its oligos as an order or a primer scheme, and validate the assay at the bench.
tags: [primer-design, primer-analysis, primer-order, primer-scheme, qpcr, validation, mhc]
tools: [primer3, primalscheme3, olivar, varvamp]
entry_points:
  - "Sidebar > Analyses > a .lungfishprimeranalysis bundle"
  - "Inspector > View > Export candidate pairs… / Export displayed primer order… / Export selected assays…"
  - "Viewer > Results > Save as Primer Scheme…"
  - "Viewer > Results > Create Annotated Reference…"
  - "CLI: lungfish-cli primers analysis inspect"
  - "CLI: lungfish-cli primers scheme-from-analysis"
  - "CLI: lungfish-cli primers analysis annotated-reference"
shots:
  - id: primer-review-overview-varvamp
    caption: "The Overview of the Mamu-A1 tiled varVAMP analysis, showing the coverage card, the consensus threshold advisory, and the amplicon track with its two pools."
  - id: primer-review-primer3-results
    caption: "The Results tab of the Mamu-A1 exon 2-3 PCR Primer3 conserved analysis, with Pair 1 selected and its forward and reverse primer properties listed."
  - id: primer-review-binding-inspection
    caption: "Binding inspection for a forward primer of the Mamu-A1 tiled PrimalScheme analysis, with the alignment canvas above and the mismatch table below."
  - id: primer-review-inspector-view
    caption: "The Inspector's View tab for the Mamu-A1 tiled PrimalScheme analysis, showing the order export button, the strand and pool checkboxes, and the MSA matches filter."
  - id: primer-review-save-scheme
    caption: "The Save as Primer Scheme sheet for the Mamu-A1 tiled PrimalScheme analysis, stating its 49 primers, 8 amplicons, 2 pools, and the coordinate reference."
  - id: primer-review-order-sheet
    caption: "The Export Candidate Pairs sheet for the Mamu-A1 001 qPCR Primer3 dye analysis, with the order name field, the optional order details, and the oligo preview."
illustrations: []
glossary_refs: [amplicon, primer, primer-scheme, primer-trim, primer-pool, bed, fasta, csv, msa, iupac-ambiguity-code, consensus-sequence, provenance, checksum, inspector, operations-panel, sidebar, reference-bundle, annotation-track, bundle, manifest, pcr]
features_refs: []
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

Every primer design in Lungfish Genome Explorer (LGE) ends as a primer analysis, a `.lungfishprimeranalysis` [bundle](../../GLOSSARY.md#bundle) saved in the project's `Analyses/` folder. A bundle is a folder that the Finder shows as one file. This one holds the inputs the engine saw, the engine's own output files, LGE's tidied copy of the results, and a [provenance](../../GLOSSARY.md#provenance) record of the exact settings and tool versions. Primer3, PrimalScheme, Olivar and varVAMP all save the same kind of bundle, so one viewer reviews all four.

This chapter covers what happens after the design finishes. First you review the result, checking where each primer binds, how well it matches every sequence you designed against, and which candidates are worth buying. Then you take the chosen oligos out of LGE, as an order file for an oligo supplier, as a [primer scheme](../../GLOSSARY.md#primer-scheme) for trimming reads later, or as an annotated reference. An oligo is a short, chemically made single strand of DNA, and every primer and probe you order is one. Finally, you prove at the bench that the assay makes the product it was designed to make.

That last step matters as much as the others. Everything LGE shows is an in-silico result, a prediction made by comparing sequences on a computer. It says a primer's letters match a template. It does not say the primer will anneal, extend, or amplify only the target in a real tube. [What Is Primer Design](01-what-is-primer-design.md#checking-a-design-in-silico-and-at-the-bench) explains the difference, and the [What good looks like](#what-good-looks-like) section below lists the bench tests that close the gap.

## Why you would do this

The worked example throughout this part of the manual is rhesus macaque MHC class I, the Mamu-A1 gene, introduced in [What Is Primer Design](01-what-is-primer-design.md). MHC genes are hard targets. They are highly polymorphic, meaning each lineage of alleles differs from the next at many positions, and they share much of their sequence with the paralogs Mamu-A2, A3, A4 and B, related genes that arose by duplication. A primer that looks perfect on one allele can fail on a second allele or bind a paralog you never meant to amplify.

The review step is where those problems show. Chapters 02 to 04 produced eight analyses from the same twelve-allele panel and four-allele lineage set. Two of them tell the central story of this chapter. The Primer3 design on a single allele placed its forward primer on a site that varies across the panel, and the design on the alignment moved both primers to conserved sites. The varVAMP qPCR design gave five assays that match all four Mamu-A1*001 lineage sequences perfectly, yet none of them is specific to that lineage, because the engines optimise conservation within the target set and never looked at the sequences to exclude. [Conserved is not the same as specific](01-what-is-primer-design.md#conserved-is-not-the-same-as-specific) explains the distinction, and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) walks through the result. Reviewing before you order, and testing on animals known to carry and to lack the target after the oligos arrive, is how you catch it.

## Before you start

You need the Primer Design demo project open, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, with at least one saved primer analysis in it. The demo project ships with inputs only, so run the designs in [Designing a PCR Assay](02-designing-a-pcr-assay.md), [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md), and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) first. This chapter refers to the analyses by the names those chapters suggest, listed below. The sequences come from the mhc-primer-design fixture, whose source and citation are in [the mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design).

| Analysis in `Analyses/` | Engine and job |
|---|---|
| `Mamu-A1 exon 2-3 PCR Primer3` | Primer3 PCR pair on allele LR699574.1 alone |
| `Mamu-A1 exon 2-3 PCR Primer3 conserved` | Primer3 PCR pair on the twelve-allele alignment, conserved sites only |
| `Mamu-A1 tiled PrimalScheme` | PrimalScheme tiled scheme, 8 amplicons, 49 oligos |
| `Mamu-A1 tiled Olivar` | Olivar tiled scheme, 10 amplicons, 20 oligos |
| `Mamu-A1 tiled varVAMP` and `... threshold 0.8` | varVAMP tiled schemes at the automatic and the 0.8 threshold |
| `Mamu-A1 001 qPCR varVAMP` | varVAMP qPCR, five primer and probe assays |
| `Mamu-A1 001 qPCR Primer3 dye` | Primer3 intercalating-dye qPCR pairs |

Reviewing and exporting run no external tool, so no [plugin pack](../../GLOSSARY.md#plugin-pack) is needed and every step finishes in seconds. Only the design itself needed the PCR Primer Design pack.

## Procedure

### Open a saved analysis

1. In the [sidebar](../../GLOSSARY.md#sidebar), open the `Analyses` folder. Primer analyses appear with a yellow list icon and without their `.lungfishprimeranalysis` extension.
2. Click `Mamu-A1 tiled varVAMP`. The viewer shows "Loading saved primer analysis…" while it reads the bundle and checks the [checksum](../../GLOSSARY.md#checksum) of every stored file against the one recorded at design time.
3. Read the segmented control at the top of the viewer. It switches between **Overview**, **Results**, and **Binding inspection**.
4. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** if it is hidden. For a primer analysis it has the tabs **Bundle**, **View**, **Files**, and **Provenance**.

If any stored file has changed since the design ran, the viewer shows "Couldn't Load Primer Analysis" with the reason and a **Retry** button instead, as [Troubleshooting](#troubleshooting) explains.

### Read the Overview

<!-- SHOT: primer-review-overview-varvamp -->

The Overview holds one card per target. For a scheme, a target is one reference sequence. For Primer3, each candidate pair gets its own card, because the pairs are alternatives rather than parts of one scheme.

1. Read the large percentage at the top of the card. It is positional coverage, the share of the reference's bases that fall inside at least one saved amplicon, counting overlaps once and including the primer sites. For `Mamu-A1 tiled varVAMP` it reads 95.03 %.
2. Hover over the small label under the percentage. Its tooltip holds the notes that say what the percentage does and does not mean. For PrimalScheme it warns that positional coverage of the reference does not establish coverage of every alignment row or successful amplification. The notes appear only in this tooltip, so read them once for each engine.
3. Read the line under the label, which gives covered bases, reference length, and bases outside any amplicon.
4. Read any advisories below it. They appear for varVAMP only, as an information icon or an orange warning triangle. For the automatic run the advisory reads "Consensus threshold 0.99, chosen automatically by varVAMP. A base counts as conserved only when 12 of 12 sequences agree. Any threshold from 0.92 to 1.00 gives the same consensus for this alignment." In tiled mode, a warning also appears whenever coverage falls below 95 %, explaining that varVAMP keeps only the longest unbroken chain of overlapping amplicons.
5. Look at the amplicon track. Each lane is one pool, amplicons are bars, forward primers are blue, reverse primers orange, and probes purple. Hover over a bar for its span and pool, and click one to open its detail box.

A [primer pool](../../GLOSSARY.md#primer-pool) is the set of primers mixed into one tube. Tiled schemes split neighbouring amplicons between two pools so overlapping primers never meet in the same reaction, as [What Is Primer Design](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains. varVAMP single and qPCR assays are unpooled, and their lanes read "Unpooled · selected assay" and "Unpooled · alternative rank" followed by a number. Those lanes are for display only and do not create a pool.

The button at the end of the Overview, **Inspect primers and pools** for a scheme or **Inspect candidate details** for Primer3, opens the Results tab.

## Reviewing results and binding sites

### Read the Results

For a scheme, the Results tab lists every oligo, grouped by pool. The title is "Selected scheme oligos" for PrimalScheme and "Reported assay oligos" for Olivar and varVAMP. Each row gives the oligo's name, its length and GC content, its role and candidate status, its sequence written 5′ to 3′, its position on the design reference, and its MSA match line. GC content is the share of G and C bases, which raises a primer's melting temperature, as [What Is Primer Design](01-what-is-primer-design.md#gc-content-and-the-gc-clamp) explains.

An oligo with degenerate bases shows "GC varies" and, in orange, a line reading how many ambiguous bases it has, followed by "review synthesis representation". A degenerate base is one of the [IUPAC ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code), such as K for G or T, standing for a position where the target sequences differ, as [Degenerate bases and what they cost](01-what-is-primer-design.md#degenerate-bases-and-what-they-cost) explains. varVAMP designs such bases on purpose. How to order them is covered in [Placing the order](#placing-the-order).

PrimalScheme handles variation differently. It keeps several exact oligos at one binding site, named for example `a5686d1c_1_LEFT_1` through `a5686d1c_1_LEFT_6` in the demo run. The detail box calls them the "Selected primer set" and says they are all selected components, not backup candidates. Order every one of them and mix them together. The suffix numbers are not ranks and do not pair a LEFT with a RIGHT.

Every position the viewer shows is 1-based inclusive, counting the first base of the reference as 1 and including both ends of a range. **Copy Coordinates**, the saved order sheet, and the order CSV use the same form. A [BED](../../GLOSSARY.md#bed) file does not. A BED, such as the engine's `primer.bed` in the Files tab or the `primers.bed` inside a saved primer scheme, is 0-based and half-open by definition, so its start counts the first base as 0 and its end is the base just past the feature. The demo's `a5686d1c_1_LEFT_1` appears as 211–233 in the viewer and in `ordering-v1.csv`, and as 210 and 233 in `primer.bed`. Both describe the same 23 bases. To turn a BED range into the viewer's form, add 1 to the start and leave the end unchanged.

<!-- SHOT: primer-review-primer3-results -->

For Primer3 the Results tab is titled "Primer3 results". Open `Mamu-A1 exon 2-3 PCR Primer3 conserved` to see it.

1. Choose the template from the **Template** menu if the design used more than one.
2. Read the summary line, which gives the template length, the number of candidate pairs, and a reminder that coordinates are 1-based inclusive, meaning the first base is 1 and both ends of a range are counted.
3. Click a pair in the **Candidates** list. Pairs are listed in the order Primer3 returned them, best-scoring first, so Pair 1 is Primer3's first choice under the constraints you set. Each shows its product size.
4. Read **Primer properties**, one row each for the forward primer, the reverse primer and, for a probe design, the internal probe. Each row gives length, melting temperature (Tm), and GC. The best conserved pair in the demo is `CGGGTCTCAGCCTCTCCT` and `GAGGATTCCTCTCCCTCAGGA`, Tm 60.0 and 59.8 °C, product 948 bp.
5. Open **Template sequence with selected binding sites** to see the template with the primers coloured, and **Primer3 explanation** to see Primer3's own count of the pairs it considered and why it rejected the rest.

When a Primer3 design came from an alignment with a chosen template row, each primer row also shows its MSA match line.

### Inspect binding against the alignment

<!-- SHOT: primer-review-binding-inspection -->

Binding inspection lines up one primer against every row of the alignment it was designed on. It appears for PrimalScheme, Olivar and varVAMP results, and for Primer3 results designed from an alignment. A Primer3 design on a single sequence also shows the tab, but it only explains that there is no alignment to compare against and suggests designing from an alignment bundle with a template row.

1. Select a primer in the Overview or Results tab and click **Inspect in alignment**, or Control-click the primer and choose **Inspect in Alignment**.
2. Check the **Target alignment** and **Compare primer** menus at the top of "Alignment & primer sites". Compare primer starts at "Choose a visible primer" if nothing was selected.
3. Look at the alignment canvas. The primer's footprint is underlined. With dots turned on, a base that matches the primer inside the footprint is drawn as a dot, and only mismatched or unknown bases show as letters. Purple ruler marks flag variable columns, and orange marks in the overview flag columns with gaps.
4. Read the header of the table below, "MSA matches" with a percentage and a count in parentheses. It counts the rows with no incompatible base under the primer, out of the rows that could be compared.
5. Read the table row by row. The **Alignment row** column names each sequence, and **Reference-oriented site** shows its bases under the primer, with mismatched bases orange, bold and underlined.

Each row carries a status. "0 mismatches (IUPAC-compatible)" means every base matches, counting a degenerate primer base as matching any base it stands for. A count followed by "positional mismatches" is the number of bases where that sequence differs from the primer. Statuses that begin "Unknown" or "Unavailable" mean the row could not be compared. The commonest are `Unknown: uncovered alignment end`, where the sequence stops before the primer site, `Unavailable: internal alignment gap`, where the sequence has a gap inside the site, and `Unknown: ambiguous sequence bases`, where the sequence itself carries an ambiguity code such as N. Those rows are left out of the percentage rather than counted as matches.

An alignment row stored as RNA, with U in place of T, is shown and compared as T, so a U never counts as a mismatch against a DNA primer.

The position of a mismatch matters as much as the count. A mismatch within the last few bases of the primer's 3′ end, where the polymerase starts copying, can stop extension altogether, while one near the 5′ end is usually tolerated, as [What Is Primer Design](01-what-is-primer-design.md#when-the-target-varies) explains. For the reverse primer the table is reference-oriented, so its 3′ end is at the left of the site.

For the demo's varVAMP qPCR assays, every oligo matches all four lineage sequences. That is exactly what the engine was asked to do, and it says nothing about the fifteen exclusion sequences, which were never in the alignment.

### Check integrity and provenance

The Inspector's **Bundle** tab names the grouping, the inputs, the results, and the engine with its version, with a **Reveal Bundle in Finder** button. The **Files** tab lists every stored file with its role, format, size, and SHA-256 checksum, under a line counting the verified payloads. Each file is a link that reveals it in Finder, which is the way to reach the engine's native outputs, such as a BED of primer positions or varVAMP's `qpcr_design.tsv`. The **Provenance** tab holds the full record, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read.

Two more command-line tools, `primers analysis history` and `primers analysis audit`, replay how a PrimalScheme run chose its panel. They are for people developing the design method, and the [command-line reference](../appendices/cli-reference.md#primers-analysis-history) documents them.

## Exporting primers

### Choose what to export

LGE offers these ways to take primers out of an analysis. Pick by what happens next.

| Export | Where | What you get | Use it for |
|---|---|---|---|
| Order export | Inspector > View | An order folder with a workbook, a CSV, and a JSON record | Buying oligos |
| Saved order sheet | Results > **Show saved order sheet…** (PrimalScheme only) | `ordering-v1.csv`, written at design time | The complete PrimalScheme scheme, hidden oligos included |
| **Save as Primer Scheme…** | Results tab or Inspector > View | A `.lungfishprimers` bundle in `Primer Schemes/` | Primer trimming of reads from a tiled scheme |
| **Create Annotated Reference…** | Primer3 Results tab | A `.lungfishref` with the primers as annotations | Seeing Primer3 candidates on the template |
| Copy and Save actions | Control-click a primer or amplicon | FASTA text, a primer FASTA bundle, or the amplicon's reference sequence | Quick sharing, or a sequence to check elsewhere |

The Copy menu offers the name, the coordinates, the sequence 5′ to 3′, the oligo as [FASTA](../../GLOSSARY.md#fasta), the oligos of the same assay as FASTA, and all oligos of the pool as FASTA. **Save Primer FASTA Bundle in Project** and **Extract Reference Amplicon Bundle in Project** each run as an operation and write a new [reference bundle](../../GLOSSARY.md#reference-bundle) into `Analyses/`, named after the analysis with "primers" or "reference amplicon" and a short code added. Native files such as the engine's own [BED](../../GLOSSARY.md#bed) stay reachable through the Files tab.

### Save a tiled scheme as a primer scheme

<!-- SHOT: primer-review-save-scheme -->

A tiled scheme becomes useful a second time after sequencing, when its primer positions are needed to trim primer bases off reads. [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) covers this step in full. In short:

1. Open `Mamu-A1 tiled PrimalScheme`, go to **Results**, and click **Save as Primer Scheme…**. The same button sits in the Inspector's View tab.
2. Read the sheet. It states the engine and counts, "PrimalScheme3 · 49 primers · 8 amplicons · 2 pools" for the demo, then the **Coordinate reference** the primer positions belong to and a sentence explaining it.
3. Edit **Scheme name**, which defaults to the analysis name followed by the result label and "scheme", and click **Save**.

The operation "Save as Primer Scheme" writes the bundle into `Primer Schemes/`, and the [Primer Trim](../04-alignments/03-primer-trimming.md) dialog lists it under In This Project. Read the coordinate reference carefully. It is the sequence the engine designed on, the first alignment row for PrimalScheme, Olivar's generated reference, or varVAMP's ambiguous consensus. Reads must be mapped to that sequence, which the bundle carries as `attachments/design-reference.fasta`, before the scheme can trim them. [Primer Schemes](../appendices/primer-schemes.md#matching-the-scheme-to-your-alignment) explains why.

The button is disabled for results that are not tiled schemes, and the reason shows beside it. For Primer3 it reads "Primer3 candidate pairs are alternatives, not a tiled scheme, so they cannot become a primer-trimming scheme." A varVAMP qPCR result is refused the same way.

### Create an annotated reference from a Primer3 result

1. Open a Primer3 analysis, such as `Mamu-A1 exon 2-3 PCR Primer3`, and go to **Results**.
2. Click **Create Annotated Reference…**. A folder chooser titled "Choose a folder for the annotated reference" opens in the project's `Analyses` folder.
3. Keep that folder, or choose another folder inside the project, and click **Open**. The line under the button reads "Creating annotated reference…" and then names the saved bundle.
4. Click **Open Annotated Reference** to view the template with every candidate primer and probe as an [annotation track](../../GLOSSARY.md#annotation-track).

The bundle is named after the template with "primers" added, and its track is named `Primer analysis:` followed by the template name. The chooser accepts any folder on the Mac, so check that it points inside the project before you click Open, or the sidebar will not show the result.

## Placing the order

<!-- SHOT: primer-review-order-sheet -->

Order export lives in the Inspector's **View** tab and captures a fixed set of oligos when you click it. The button and what it captures depend on the engine.

| Engine | Button | What is ordered |
|---|---|---|
| Primer3 | **Export candidate pairs…** | Forward, reverse and probe of every included candidate pair |
| PrimalScheme | **Export displayed primer order…** | The oligos currently displayed after the View tab's filters |
| Olivar and varVAMP | **Export selected assays…** | The assays the engine marked as selected, with their probes |
| Olivar and varVAMP, when alternatives exist | **Export all reported assays…** | Selected and alternative assays together |

1. Open `Mamu-A1 001 qPCR Primer3 dye` and click the Inspector's **View** tab. For Primer3 it lists the candidate pairs with a checkbox each and a count of pairs included.
2. Untick the pairs you do not want. Order two or three pairs for a new assay, since the first pair does not always work best at the bench.
3. Click **Export candidate pairs…**. The Export Candidate Pairs sheet opens with a summary of oligos and order groups, and a note that each pair is its own order group, not a pool.
4. Fill **Order name**, which is required. Open **Order details (optional)** to add Requested by, Project label, Order reference, and Notes.
5. Check the **Oligo preview**, which shows the first eight oligos 5′ to 3′, and click **Export**.

The operation writes a folder named after the order into `Analyses/`, and selecting it opens the Primer Order viewer, described in [Reading the results](#reading-the-results).

For a scheme, the View tab also holds display filters. **Forward oligos (+)** and **Reverse oligos (−)** hide a strand, the pool checkboxes hide a pool, and the `Advanced: individual oligos` disclosure hides single oligos. Under **MSA matches**, **Filter by MSA matches** and the **Minimum MSA matches** slider hide oligos that match fewer alignment rows than the threshold. These filters change what PrimalScheme's **Export displayed primer order…** captures, which makes them a way to order one pool or drop a rarely needed variant. They never change the saved design, and Olivar and varVAMP orders ignore them.

<!-- SHOT: primer-review-inspector-view -->

LGE's export does not choose synthesis options, because those depend on your supplier and your chemistry. Add the following on the supplier's form or in the workbook before you send it.

| Item | What to enter |
|---|---|
| Name | One unique name per oligo, without spaces. Keep the LGE name in a notes column so the order traces back to the analysis. |
| Sequence | Exactly as exported, 5′ to 3′. Never reverse-complement a reverse primer by hand, because LGE already stores it in the orientation you order. |
| Scale | The amount synthesised. The smallest scale a supplier offers is usually ample for PCR primers. |
| Purification | Standard desalting is usual for PCR primers. Dye-labelled probes are normally purified by HPLC, a chromatography step, and many suppliers require it. |
| Degenerate bases | Enter the IUPAC letter, such as K, and choose a mixed base, where the synthesiser adds an equal mixture of the bases at that position. |
| Probe labels | A 5′ reporter dye and a 3′ quencher, chosen to match your qPCR instrument's detection channels. |

A degenerate oligo is a mixture. varVAMP_0's probe, `TATCGCCCTCCCTCTGKTCCTGAGG`, is really two probes, one with G and one with T at the K, each at half the concentration. If a supplier cannot place a mixed base in a labelled probe, order the two versions separately and mix them. Probes and dyes are introduced in [What Is Primer Design](01-what-is-primer-design.md#intercalating-dye-and-hydrolysis-probe).

Name oligos so a stranger can read them. A workable pattern is target, assay, and role, such as `MamuA1_ex2-3_F` and `MamuA1_ex2-3_R` for the PCR pair, or `MamuA1-001_q0_F`, `MamuA1-001_q0_P` and `MamuA1-001_q0_R` for varVAMP_0. Keep LEFT and RIGHT, or F and R, in every name, since the engines use them to mark strand.

## Settings

The order sheet and the scheme sheet are the only places in this chapter where you type a value. Everything else is a view.

**Order name.** Names the order folder LGE writes and fills the order name column of every file in it. The default is the analysis name followed by "candidate pairs order", "order", or "all reported assays order", depending on the button. Change it to something your supplier and your lab notebook will both recognise, such as a date and target. This setting has no command-line flag.

**Order details.** Adds Requested by, Project label, Order reference, and Notes to the Order metadata worksheet and to the CSV and JSON records. The default is blank, since LGE cannot know your purchasing details. Fill them when the order goes through a core facility or a grant account that needs a reference. This setting has no command-line flag.

**Scheme name.** Names the `.lungfishprimers` bundle that **Save as Primer Scheme…** writes. The default joins the analysis name, the result label, and "scheme", which is exact but long. Shorten it, because the Primer Trim dialog shows it in a menu, and note that a name already used in `Primer Schemes/` is refused rather than overwritten. On the command line this is `--output`.

## Reading the results

An order folder holds a detailed order workbook, `primer-order.xlsx`, a CSV of the same rows, `ordering.csv`, and a JSON record that preserves the exact assay, oligo, role, candidate and pool behind every row. The workbook's first sheet, Assay review, lists order group, oligo name, sequence, role, candidate status, and pool. The CSV adds the length, the 1-based start and end on the design reference, the strand, and the MSA match counts. When every oligo belongs to a native pool, as in a PrimalScheme or Olivar scheme, the folder also holds an upload-only workbook in one supplier's pooled-oligo format, which the app labels the IDT oPools workbook. Primer3 pairs have no pools, so their orders never include it.

The Primer Order viewer shows the counts, the order groups, and every exported oligo with its reference and position. Its buttons **Open order workbook**, **Open IDT upload copy**, and **Open CSV** open the files in their default applications. The Inspector repeats the metadata and notes that the order is a subset of the original design, not a new or validated scheme.

Primer3 oligos have no names of their own, so LGE names them from the template name, shortened to 24 characters, the pair number, and the role, giving names of the form `<template>_P1_LEFT`, `<template>_P1_RIGHT`, and `<template>_P1_PROBE`. Each pair becomes an order group named `Template_1_Candidate_1` and so on. Rename them to your convention on the supplier's form. PrimalScheme names come from the engine and begin with a short run code, as in `a5686d1c_1_LEFT_1`, which is unique but not readable.

## What good looks like

Before ordering, the in-silico checks should all pass. Every oligo you order should show 0 mismatches against every assessable row it is meant to detect, or mismatches only near its 5′ end. The numbers should agree with what the design chapter reported, such as a 948 bp product for the conserved Primer3 pair, about 91 % coverage for PrimalScheme, and 99.28 % for varVAMP at threshold 0.8. For an assay that must tell one lineage or gene from another, you also need evidence that it does not match the sequences to exclude, which the design engines do not provide unless you give them an exclusion set, as [Conserved is not the same as specific](01-what-is-primer-design.md#conserved-is-not-the-same-as-specific) explains and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) shows on the demo.

After the oligos arrive, validate the assay at the bench. The usual sequence is as follows.

1. Run a gradient PCR, one reaction per well across a range of annealing temperatures, starting a few degrees below the primers' Tm. Pick the highest temperature that still gives strong product, since higher annealing favours specific binding.
2. Check for a single product of the expected size. For endpoint PCR, run an agarose gel and look for one band at the designed length, such as 948 bp for the conserved exon 2 to 3 pair. For a dye qPCR assay, run a melt curve after cycling and look for one peak, since a second peak means a second product or primer dimers.
3. For qPCR, build a standard curve from a tenfold dilution series of template run in replicate. Amplification efficiency should fall between 90 and 110 %, the range commonly applied under the MIQE guidelines for reporting qPCR, which corresponds to a slope of about −3.6 to −3.1 in a plot of quantification cycle against log input. Include no-template controls, which should stay negative.
4. Sequence the product, by Sanger sequencing of the PCR product, and confirm it is the intended gene and region rather than a paralog.
5. Test on samples of known type. For a Mamu-A1*001 lineage assay, run animals already typed as Mamu-A1*001 positive and animals typed as negative, for example by [amplicon MHC genotyping](../09-genotyping/02-running-genotyping.md). Positives must amplify and negatives must not.

The fifth test is the one that exposes the demo's varVAMP qPCR assays. Their oligos match most of the fifteen exclusion sequences perfectly, so Mamu-A1*001 negative animals would amplify too. The review in LGE predicts that failure, and the negative animals prove it. The MIQE guidelines ([Bustin and colleagues 2009](../appendices/bibliography.md#primer-design-background)) list what a qPCR publication should report about all of these steps.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Run these from inside the project folder.

```bash
# Verify every stored file and print the analysis summary
lungfish-cli primers analysis inspect \
  "Analyses/Mamu-A1 exon 2-3 PCR Primer3 conserved.lungfishprimeranalysis"

# List the results that can become a primer scheme, then save one
lungfish-cli primers scheme-from-analysis \
  "Analyses/Mamu-A1 tiled PrimalScheme.lungfishprimeranalysis" --list
lungfish-cli primers scheme-from-analysis \
  "Analyses/Mamu-A1 tiled PrimalScheme.lungfishprimeranalysis" \
  --output "Mamu-A1 tiled PrimalScheme" --project .

# Create an annotated reference from one Primer3 result
lungfish-cli primers analysis annotated-reference \
  "Analyses/Mamu-A1 exon 2-3 PCR Primer3.lungfishprimeranalysis" \
  --result-id <result-id> --output-directory Analyses
```

On the demo, `inspect` ends with "Integrity verified" after counting the inputs, results, and stored files. Add `--json` to print the full manifest, which is where the result UUID for `--result-id` comes from. `--list` prints each result's engine, coordinate reference, and counts, or the reason it cannot be saved. For `Mamu-A1 001 qPCR varVAMP` it explains that primer trimming needs a tiled amplicon scheme. Order export has no command-line equivalent in this release.

## Troubleshooting

**"Couldn't Load Primer Analysis".** The viewer found a file whose checksum no longer matches the record, usually because something inside the bundle was edited, moved, or partly copied. The message names the file, as in "Primer analysis artifact integrity mismatch" followed by its path. Run `lungfish-cli primers analysis inspect` on the bundle for the same check. Restore the bundle from a backup or rerun the design, since LGE will not display results it cannot verify.

**Binding inspection only explains that there is no alignment.** The Primer3 design ran on a single sequence. Rerun it from an alignment bundle with a template row chosen, as [Designing a PCR Assay](02-designing-a-pcr-assay.md) shows.

**A row reads `Unknown: uncovered alignment end`.** That allele's record stops before the primer site, so there is nothing to compare. It is not a mismatch, but it is not evidence of a match either. Find a longer record for that allele, or treat the primer as untested on it.

**"Save as Primer Scheme…" is disabled.** The reason appears beside the button. Only tiled PrimalScheme, Olivar, and varVAMP results can be saved. For a Primer3 pair or a qPCR assay, use the order export instead.

**The export button is disabled.** Its tooltip gives the reason. "Include at least one candidate pair to export an order." means every Primer3 pair is unticked. "Show at least one oligo to export an order." means the PrimalScheme display filters hide everything, which **Show all** fixes. "Complete the MSA comparison before exporting the filtered order." means the MSA match calculation is still running or was cancelled, and **Calculate MSA matches** restarts it. "Open this analysis in its project to export an order." means the analysis was opened outside its project.

**No IDT oPools workbook in the order folder.** The oligos have no native pool. That is expected for Primer3 pairs and for unpooled varVAMP assays.

**The annotated reference does not appear in the sidebar.** It was saved to a folder outside the project. Find it with the path in the message under the button, or create it again inside `Analyses`.

**A saved scheme trims almost nothing.** The reads were mapped to a different sequence than the scheme's coordinate reference. Map them to the scheme's design reference, as [Primer Schemes](../appendices/primer-schemes.md#matching-the-scheme-to-your-alignment) explains, and check the trim rate in [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md#what-good-looks-like).

**At the bench, no product, several bands, or poor efficiency.** No product at any gradient temperature points to a primer that does not bind the samples, so check the binding table for 3′ mismatches against the alleles your animals carry. Several bands or melt peaks point to a second target, often a paralog, so sequence the extra product. Efficiency outside 90 to 110 % often comes from inhibitors or a poorly mixed dilution series, so rebuild the series before redesigning. For problems with the app that are not listed here, see [Troubleshooting](../appendices/troubleshooting.md).

## Next

Once an assay works, record which analysis and which candidate it came from alongside the order in your lab notebook. For a tiled scheme, sequence the amplicons and continue with [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) using the scheme you saved here. To revisit the concepts behind any check in this chapter, return to [What Is Primer Design](01-what-is-primer-design.md).
