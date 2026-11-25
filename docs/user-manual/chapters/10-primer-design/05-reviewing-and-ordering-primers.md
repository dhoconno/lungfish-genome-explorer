---
title: Reviewing and Ordering Primers
chapter_id: 10-primer-design/05-reviewing-and-ordering-primers
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 10-primer-design/02-designing-a-pcr-assay, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 20
task: Review a saved primer analysis in LGE, check each oligo against the alignment, save a tiled design as a primer scheme, export an order for a supplier, and validate the assay at the bench.
tags: [primer-design, primer-analysis, primer-order, primer-scheme, qpcr, validation, mhc]
tools: [primer3, primalscheme3, olivar, varvamp]
parameters_refs: [primer-analysis.order-export, primer-analysis.scheme-from-analysis]
entry_points:
  - "Sidebar > Analyses > a .lungfishprimeranalysis bundle"
  - "Inspector > View > Export candidate pairs… / Export displayed primer order… / Export selected assays…"
  - "Viewer > Results > Save as Primer Scheme…"
  - "Viewer > Results > Create Annotated Reference…"
  - "CLI: lungfish-cli primers analysis inspect"
  - "CLI: lungfish-cli primers analysis export-order"
  - "CLI: lungfish-cli primers analysis export-selection"
  - "CLI: lungfish-cli primers analysis annotated-reference"
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
glossary_refs: [amplicon, paralog, primer, primer-scheme, primer-trim, primer-pool, primer-analysis-bundle, bed, fasta, csv, msa, iupac-ambiguity-code, degenerate-base, design-reference, consensus-sequence, provenance, checksum, inspector, operations-panel, sidebar, reference-bundle, annotation-track, bundle, manifest, oligo, probe, pcr, qpcr, cq, melting-temperature, accession, terminal, reverse-complement, gap, xlsx]
features_refs: [primer-analysis.review, primer-analysis.order-export, primer-analysis.export-selection, primer-analysis.scheme-from-analysis]
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

Every primer design in Lungfish Genome Explorer (LGE) ends as a [primer analysis bundle](../../GLOSSARY.md#primer-analysis-bundle), a `.lungfishprimeranalysis` folder saved in the project's `Analyses` folder, which the Finder shows as one file. It holds the inputs the engine saw, the engine's own output files, LGE's tidied copy of the results, and a [provenance](../../GLOSSARY.md#provenance) record of the settings and tool versions. Primer3, PrimalScheme, Olivar and varVAMP all save the same kind of bundle, so one viewer reviews all four.

This chapter owns what happens after a design finishes. It reads the viewer's three views, checks each [oligo](../../GLOSSARY.md#oligo) against every sequence the design was made from, saves a tiled design as a [primer scheme](../../GLOSSARY.md#primer-scheme) for trimming reads later, exports an order for a supplier, and lists the bench tests that prove the assay works.

That last step matters as much as the others. Everything LGE shows is an in-silico result, a prediction made by comparing sequences on a computer. It says a primer's letters match a template. It does not say the primer will anneal, extend, or amplify only the target in a real tube, as [Checking a design in silico and at the bench](01-what-is-primer-design.md#checking-a-design-in-silico-and-at-the-bench) explains.

## Why you would do this

The review step is where a design's problems show while they are still free to fix. A primer that looks perfect on one allele can fail on a second or bind a [paralog](../../GLOSSARY.md#paralog), a related gene copy you never meant to amplify, and *Mamu-A1*, a rhesus macaque immune gene and this part's example, has both problems, for the reasons [Why you would do this](01-what-is-primer-design.md#why-you-would-do-this) sets out. Reviewing before you order, and testing on samples known to carry and to lack the target after the oligos arrive, is how you catch them.

## Before you start

You need the Primer Design demo project open, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It ships with inputs only, so run the designs in the three chapters before this one first.

| Analysis in `Analyses/` | Engine and job |
|---|---|
| `Mamu-A1 exon 2-3 PCR Primer3` and `... conserved` | Primer3 PCR pairs on one allele and on the twelve-allele alignment |
| `Mamu-A1 tiled PrimalScheme` | PrimalScheme tiled scheme, 8 [amplicons](../../GLOSSARY.md#amplicon), 49 oligos, since each primer site gets one oligo per version of its sequence |
| `Mamu-A1 tiled Olivar` | Olivar tiled scheme, 10 amplicons, 20 oligos |
| `Mamu-A1 tiled varVAMP` and `... threshold 0.8` | varVAMP tiled schemes at the automatic and the 0.8 threshold, the share of sequences that must agree on a base |
| `Mamu-A1 001 qPCR varVAMP` | varVAMP [qPCR](../../GLOSSARY.md#qpcr), five primer and probe assays, screened against the exclusion set, the eighteen sequences they must not detect |
| `Mamu-A1 001 qPCR Primer3 probe` and `... dye` | Primer3 qPCR pairs with and without a [probe](../../GLOSSARY.md#probe) |
| `Mamu-A1 001 qPCR anchored` | Primer3 probe assay built around a fixed reverse primer |

Nothing here needs a tool installed first, so every step finishes in seconds, and order export uses two small programs that macOS already has.

## Procedure

### Open a saved analysis

In the [sidebar](../../GLOSSARY.md#sidebar), open the `Analyses` folder, where primer analyses appear with a yellow list icon and without their extension, and click `Mamu-A1 tiled varVAMP`. The viewer shows "Loading saved primer analysis…" while it reads the bundle and checks the [checksum](../../GLOSSARY.md#checksum) of every stored file against the one recorded at design time.

The switch at the top of the viewer moves between **Overview**, **Results** and **Binding inspection**. The [Inspector](../../GLOSSARY.md#inspector) is the pane at the right of the window, and **View > Show Inspector** brings it back if it is hidden. For a primer analysis its tabs are **Bundle**, **View**, **Files** and **Provenance**. The Bundle tab gives the grouping, which says whether the run designed each input on its own or combined them, the number of inputs, the number of results and the engine with its version. The Files tab lists every stored file with its role, format, size and checksum, and each file is a link that reveals it in Finder, which is the way to reach the engine's own outputs such as a [BED](../../GLOSSARY.md#bed) file of primer positions or varVAMP's own design table. The Provenance tab holds the full record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read.

### Read the Overview

<!-- SHOT: primer-review-overview-varvamp -->

The Overview holds one card per target. For a scheme a target is one reference sequence, and for Primer3 each candidate pair gets its own card, because the pairs are alternatives rather than parts of one scheme.

The large percentage at the top of the card is positional coverage, the share of the reference's bases inside at least one saved amplicon, counting overlaps once and including the primer sites. For `Mamu-A1 tiled varVAMP` it reads 95.0%. LGE sets no pass mark, so check that the stretches outside every amplicon avoid the region you need, since no reads come from them. Read the note under it, and open "What this coverage figure does and does not mean" for the caveats, which for PrimalScheme include that positional coverage does not establish coverage of every alignment row, meaning every input sequence, or successful amplification.

Advisories sit below that, each with an information icon or an orange warning triangle. For the automatic varVAMP run the first reads "Consensus threshold 0.99, chosen automatically by varVAMP. A base counts as conserved only when 12 of 12 sequences agree. Any threshold from 0.92 to 1.00 gives the same consensus for this alignment." The threshold is the share of sequences that must carry a base before it is written alone, so 0.99 means all 12, since 11 of 12 is only 0.917, which is why the range starts at 0.92. The advisory is information, and [Tuning a scheme that covers too little](03-designing-a-tiled-amplicon-scheme.md#tuning-a-scheme-that-covers-too-little) shows how to ask for a more tolerant consensus. Olivar and varVAMP cards repeat each warning the engine's own run wrote, and a combined PrimalScheme panel, one designed from several alignments at once, warns on each reference whose amplicons span less than 90 percent of it. Last comes the amplicon track, one lane per pool, with amplicons as bars, forward primers in blue, reverse primers in orange and probes in purple. Hover over a bar for its span and pool, click one to open its detail box, and Control-click it for a menu of copy, alignment and export commands.

A [primer pool](../../GLOSSARY.md#primer-pool) is the set of primers mixed into one tube, and a tiled scheme splits neighboring amplicons between two pools so overlapping primers never meet, as [Multiplexing, pools and tiling](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains. varVAMP single and qPCR assays are unpooled, so their lanes, which read "Unpooled · selected assay" and "Unpooled · alternative rank" followed by a number, are display groupings rather than pools. The button at the end of the Overview, **Inspect primers and pools** for a scheme or **Inspect candidate details** for Primer3, opens the Results tab.

### Read the Results

For a scheme, the Results tab lists every oligo, grouped by pool, titled "Selected scheme oligos" for PrimalScheme and "Reported assay oligos" for Olivar and varVAMP. Each row gives the oligo's name, its length and GC content, its role, its candidate status, which says whether the engine selected this oligo or offers it as an alternative, its sequence written 5′ to 3′, its position on the [design reference](../../GLOSSARY.md#design-reference), and its MSA match line. That line gives the share of the rows of the design's [multiple sequence alignment](../../GLOSSARY.md#msa) (MSA), one sequence each, with no incompatible base under the oligo, so `MSA matches: 91.7% (11/12)` means 11 of 12 comparable rows match. Binding inspection shows the rows behind it.

An oligo with [degenerate bases](../../GLOSSARY.md#degenerate-base) shows "GC varies" and, in orange, a count of its ambiguous bases followed by "review synthesis representation", which means the supplier must make a mixed base at each of those positions, as [Placing the order](#placing-the-order) explains. PrimalScheme handles variation the other way, keeping several exact oligos at one binding site, named for example `a5686d1c_1_LEFT_1` through `a5686d1c_1_LEFT_7` in the demo run. The detail box calls them the "Selected primer set" and says they are all selected components rather than backup candidates, so order every one. They share one pool, which a pooled-oligo form such as the one from IDT (Integrated DNA Technologies) mixes for you, whereas with single-oligo tubes you mix it yourself. The suffix numbers are not ranks and do not pair a LEFT with a RIGHT.

<!-- SHOT: primer-review-primer3-results -->

For Primer3 the tab is titled "Primer3 results". Open `Mamu-A1 exon 2-3 PCR Primer3 conserved` to see it. Read the summary line, which gives the template length, the number of candidate pairs, and a reminder that coordinates are 1-based inclusive, meaning the first base is 1 and both end bases count. Click a pair in the **Candidates** list, which keeps Primer3's own order, so Pair 1 sits closest to the optimum values you set, which is not the same as binding best. **Primer properties** then gives one row each for the forward primer, the reverse primer and, for a probe design, the internal probe, with length, melting temperature and GC content. Pair 1 of the conserved analysis is `CGGGTCTCAGCCTCTCCT` and `GAGGATTCCTCTCCCTCAGGA`, melting temperatures 60.0 and 59.8 °C, product 948 bp. Two collapsible sections sit below, **Template sequence with selected binding sites**, which prints the template with the primers colored, and **Primer3 explanation**, which holds counts of the oligos and pairs Primer3 tried and why it dropped some, as [The Primer3 explanation line](02-designing-a-pcr-assay.md#the-primer3-explanation-line) explains.

Every position the viewer shows is 1-based inclusive, and so are **Copy Coordinates** and the order [CSV](../../GLOSSARY.md#csv) file. A BED file is 0-based and half-open, as in the engine's own `primer.bed` in the Files tab and the `primers.bed` inside a saved scheme, so its start counts the first base as 0 and its end is the base just past the feature. To turn a BED range into the viewer's form, add 1 to the start and leave the end alone.

Control-click a primer or an amplicon for its menu. The **Copy** submenu copies the name, the coordinates, the sequence or a [FASTA](../../GLOSSARY.md#fasta) record. **Save Primer FASTA Bundle in Project** writes a primer as a [reference bundle](../../GLOSSARY.md#reference-bundle) in `Analyses/`, and **Extract Reference Amplicon Bundle in Project** writes the amplicon's stretch of the design reference with its primer sites as an [annotation track](../../GLOSSARY.md#annotation-track). Each runs `lungfish-cli primers analysis export-selection`, LGE's own command-line program, in a row of the [Operations Panel](../../GLOSSARY.md#operations-panel), a separate window that lists running and finished jobs, opens by itself when a job starts, and returns with **Operations > Show Operations Panel**. You never type the command, **Cancel** stops the job, and **Copy CLI Command** copies it for the [Terminal](../../GLOSSARY.md#terminal). The analysis itself is never changed.

### Inspect binding against the alignment

<!-- SHOT: primer-review-binding-inspection -->

Binding inspection lines up one primer against every row of the alignment it was designed on, one sequence per row, and only those rows, so it cannot test sequences that were never in the alignment, such as the demo's eighteen exclusion sequences, which [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) covers. It appears for PrimalScheme, Olivar and varVAMP results, and for Primer3 results designed from an alignment. A Primer3 design on a single sequence shows the tab but only explains that there is no alignment to compare against.

1. Select a primer by clicking its row in the Results tab, its name in an amplicon's detail box on the Overview (click the bar to open it), or, for Primer3, its row under **Primer properties**. A line reading "Selected primer" then appears under the switch at the top of the viewer, with the **Inspect in alignment** button beside it. Control-clicking the primer and choosing **Inspect in Alignment** does the same.
2. Check that **Target alignment** at the top of "Alignment & primer sites" names the alignment you designed on, and that **Compare primer** names the oligo you meant. Compare primer starts on the first primer in its list if nothing was selected, and reads "Choose a visible primer" only when the primer you chose is no longer shown, for example because a filter in the Inspector's View tab hides it.
3. Look at the alignment canvas. The primer's footprint is underlined, and a base matching the primer inside the footprint is drawn as a dot, so only mismatched or unknown bases show as letters. For a scheme, the **Matching observed bases as dots** checkbox in the Inspector's View tab turns the dots off. Purple marks on the ruler flag variable columns, and orange marks on the thin overview strip under the ruler flag columns with gaps. Hover over the canvas for a key.
4. Read the header of the table below, "MSA matches" with a percentage and a count in parentheses. It counts the rows with no incompatible base under the primer, out of the rows that could be compared, so the second number is how many rows the percentage rests on.
5. Read the table row by row. **Alignment row** names each sequence and **Reference-oriented site** shows its bases under the primer as they read on the reference strand, so for a reverse primer they read as its [reverse complement](../../GLOSSARY.md#reverse-complement), with mismatched bases orange, bold and underlined.

Each row carries a status. "0 mismatches (IUPAC-compatible)" means every base matches, counting a degenerate primer base as matching any base it stands for. Statuses beginning "Unknown" or "Unavailable" mean the row could not be compared. `Unknown: uncovered alignment end` means the sequence stops before the primer site. `Unavailable: internal alignment gap` means a [gap](../../GLOSSARY.md#gap), a dash, sits inside the footprint, so that sequence has a deletion or the others an insertion there. `Unknown: ambiguous sequence bases` means the sequence holds a letter such as N that stands for more than one base. Those rows are left out of the percentage rather than counted as matches, so a row that reads Unknown is not evidence of a match. Open them when the header's second number is well below the row total.

LGE sets no pass mark for MSA matches, so these are rules of thumb. Primer3 oligos designed with **Require binding sites conserved across all alignment rows** on, and Olivar oligos, which avoid variable columns where they can, should read 100 percent. A varVAMP oligo comes from a consensus, so rows in the minority at a variable column can mismatch, as the consensus threshold allows. PrimalScheme keeps one exact oligo per version of a site, so one oligo far below 100 percent is normal and the test is per row. Choose a site's first oligo in **Compare primer** and note each row that does not read "0 mismatches (IUPAC-compatible)". Then check that each of those rows reads that way for another oligo of the site, which shares its name apart from the last number. LGE does not add them up for you, and with the default **Minimum base frequency** of 0 every comparable row should end up covered.

The position of a mismatch matters as much as the count. A mismatch within the last few bases of the primer's 3′ end, roughly the last three to five, can stop extension altogether, while one near the 5′ end is usually tolerated, as [When the target varies](01-what-is-primer-design.md#when-the-target-varies) explains. The table is reference-oriented, so for a forward primer the 3′ end is the rightmost base of the site and for a reverse primer it is the leftmost. Read a reverse primer's row from left to right and the first base you see is the one that decides whether the allele amplifies.

### Save a tiled scheme as a primer scheme

<!-- SHOT: primer-review-save-scheme -->

A tiled scheme becomes useful a second time after sequencing, when its primer positions are needed to [trim](../../GLOSSARY.md#primer-trim) primer bases off reads. Those bases come from the oligos, not the sample, so left in place they would be called as variants. Open `Mamu-A1 tiled PrimalScheme`, go to **Results**, and click **Save as Primer Scheme…**, which also sits in the Inspector's View tab. Read the dialog before saving. It states the engine and counts, "PrimalScheme3 · 49 primers · 8 amplicons · 2 pools" for the demo, then the **Coordinate reference** the primer positions belong to and a sentence explaining it. Edit **Scheme name**, which defaults to the analysis name followed by the result's label and the word scheme, and click **Save**.

The Operations Panel opens by itself with a row titled "Save as Primer Scheme", whose **Copy CLI Command** gives the matching `lungfish-cli primers scheme-from-analysis` command. The row ends with "Saved in the project's Primer Schemes folder." and the sidebar then shows a `Primer Schemes` folder, hidden until it holds a scheme. The Primer Trim dialog lists the scheme under In This Project, and the [Viral Recon wizard](../04-alignments/05-viral-recon-wizard.md), which calls variants from amplicon reads, shows it with "(Project)" after its display name. Read the coordinate reference carefully, because it is the sequence the engine designed on, the first alignment row for PrimalScheme, a reference Olivar builds from the alignment, or varVAMP's ambiguous consensus, which has an IUPAC letter wherever the rows disagree. Reads must be mapped to that sequence, which the bundle carries as `attachments/design-reference.fasta` for you to import as a reference bundle, before the scheme can trim them, as [Matching the scheme to your alignment](../appendices/primer-schemes.md#matching-the-scheme-to-your-alignment) explains, and [Saving a designed scheme](../appendices/primer-schemes.md#saving-a-designed-scheme) documents the bundle.

The button is disabled for results that are not tiled schemes, and the reason appears beside it. For Primer3 it reads that candidate pairs are alternatives rather than a tiled scheme, and a varVAMP qPCR result is refused the same way. A result whose primers sit on more than one reference is refused, so choose a single-reference result in the dialog's **Result** menu or design again with **Output grouping** set to "One scheme per MSA". A design with no selected primers, or one whose oligo names repeat, is refused too, and only a new design fixes either.

### Export an order

<!-- SHOT: primer-review-order-sheet -->

Order export lives in the Inspector's **View** tab and captures a fixed set of oligos when you click it. The tab opens with a heading, "Primer3 candidates" or "Primer display", with the button **Include all** or **Show all** at its right edge to restore the full set, and a count line such as `N of M oligos displayed` below. What the export button captures depends on the engine.

| Engine | Button | What is ordered |
|---|---|---|
| Primer3 | **Export candidate pairs…** | Forward, reverse and probe of every included candidate pair |
| PrimalScheme | **Export displayed primer order…** | The oligos currently displayed after the View tab's filters |
| Olivar and varVAMP | **Export selected assays…** | The assays the engine's ranking marked as selected, with their probes |
| Olivar and varVAMP, when alternatives exist | **Export all reported assays…** | Selected and alternative assays together |

1. Open `Mamu-A1 exon 2-3 PCR Primer3 conserved` and click the Inspector's **View** tab, which lists the candidate pairs with a checkbox each and a count of pairs included.
2. Untick the pairs you do not want. Order two or three pairs for a new assay, since the first pair does not always work best at the bench.
3. Click **Export candidate pairs…**. The dialog opens with a summary of oligos and order groups, which are sets of oligos ordered together, and a note that each pair is its own order group rather than a pool.
4. Fill **Order name**, which is required, and open **Order details (optional)** to add **Requested by**, **Project label**, **Order reference** and **Notes**.
5. Check the **Oligo preview**, which shows the first eight oligos 5′ to 3′, against the pairs you meant to order, and click **Export**, which writes every oligo and not only the eight shown.

The dialog closes and the Operations Panel shows a row titled "Export Candidate Pairs", which runs `lungfish-cli primers analysis export-order` for the oligos you chose. When the row reads "Saved in the project's Analyses folder.", the order folder sits in `Analyses/`, named from the first 50 characters of the order name plus a short code, so a new order never replaces an earlier one. Selecting it opens the Primer Order viewer. For a varVAMP qPCR analysis the route is the same with a different button. Open `Mamu-A1 001 qPCR varVAMP`, and **Export selected assays…** orders the one assay LGE marks as selected, the lowest-penalty one, where the penalty is varVAMP's own score for how far an assay sits from its ideal values and is listed in varVAMP's design table in the Files tab. To order a different assay, such as one whose oligos match fewer exclusion sequences, as [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) counts, use **Export all reported assays…**, copy `primer-order.xlsx` out of the order folder, and delete the rows of the assays you do not want from its Assay review worksheet. Send the copy, because LGE refuses to reopen an order whose files were edited.

For the tiled `Mamu-A1 tiled PrimalScheme` analysis the walk is shorter, because there are no pairs to untick.

1. In the Inspector's **View** tab, set any filters you want, because the order captures exactly the oligos counted in `N of M oligos displayed`.
2. Click **Export displayed primer order…**. The dialog is titled "Export Displayed Primer Order" and lists each order group, here a pool named like `Scheme_1_Pool_1`, with its oligo count.
3. Fill **Order name**, which defaults to `Mamu-A1 tiled PrimalScheme order`, add any order details, and click **Export**.
4. Follow the Operations Panel row titled "Export Displayed Primer Order". The saved folder also holds `IDT-oPools.xlsx`, because every PrimalScheme oligo has a native pool.

For a scheme, the View tab also holds display filters. **Forward oligos (+)** and **Reverse oligos (−)** hide a strand, the pool checkboxes hide a pool, and the last collapsible section, for individual oligos, hides single oligos. Under **MSA matches**, **Filter by MSA matches** and the **Minimum MSA matches** slider, a percentage from 0 to 100, hide oligos that match a smaller percentage of the alignment rows that could be compared than the one you set. These filters change what PrimalScheme's **Export displayed primer order…** captures, which makes them a way to order one pool or drop a variant that few rows need, though only when Binding inspection shows that an oligo you keep matches every row that variant matches. They never change the saved design, and Olivar and varVAMP orders ignore them.

<!-- SHOT: primer-review-inspector-view -->

### Create an annotated reference from a Primer3 result

Open a Primer3 analysis, go to **Results**, and click **Create Annotated Reference…**. LGE writes the reference into the project's own `Analyses` folder, and the line under the button then names the saved bundle. Click **Open Annotated Reference** to view the template with every candidate primer and probe as an annotation track.

## Settings

**Order name.** Names the order folder LGE writes and fills the order name in the CSV, in the Order metadata worksheet and in the JSON record. The default is the analysis name followed by "candidate pairs order", "order" or "all reported assays order", depending on the button. Change it to something your supplier and your lab notebook will both recognize, such as a date and a target. On the command line this is `--name`.

**Order details.** Opens the optional fields **Requested by**, **Project label** and **Order reference**, which LGE copies to the Order metadata worksheet and to the CSV and JSON records. The default is blank, since LGE cannot know your purchasing details. Fill them when the order goes through a core facility or a grant account that needs a reference. On the command line these are `--requested-by`, `--project` and `--order-reference`.

**Notes.** Adds free text under the other order details, in a field that reads "Optional order notes" until you type, and LGE copies it to the same worksheet and records. The default is blank, because only you know what the order needs said. Use it for anything the supplier or your lab should read with the order, such as a delivery address or the experiment the oligos are for. On the command line this is `--notes`.

**Scheme name.** Names the `.lungfishprimers` bundle that **Save as Primer Scheme…** writes. The default joins the analysis name, the result label and the word scheme, which is exact but long. Shorten it for a tidier folder name in `Primer Schemes/`, since the Primer Trim dialog lists the scheme by its display name, which is the analysis name and the result label, and note that a name already used in `Primer Schemes/` is refused rather than overwritten. On the command line this is `--output`.

## Reading the results

An order folder holds four files. `primer-order.xlsx` is the order workbook, an [XLSX](../../GLOSSARY.md#xlsx) spreadsheet file, and `ordering.csv` lists the same rows as plain text. `order.json` records the exact assay, oligo, role, candidate and pool behind every row. `template.xlsx` is an unchanged copy of IDT's order-entry template, with its sample rows, kept as a record of what the workbook was filled from and never the file to send.

The workbook's first worksheet depends on the order. For Primer3 pairs and unpooled varVAMP assays it is Assay review, which lists order group, oligo name, sequence, role, candidate status, assay IDs, native pool and source oligo ID. For a pooled scheme it is IDT's template worksheet, filled in. Order metadata follows either one and holds your order details and a table of every exported oligo. A native pool is a pool number the design engine itself assigned, such as PrimalScheme's pools 1 and 2. When every oligo has one, as in a PrimalScheme or Olivar scheme, the folder also holds `IDT-oPools.xlsx`, which LGE labels the IDT oPools workbook. It is the filled template worksheet alone, with the pool name and sequence that IDT's oPools form takes for each oligo, for upload pages that cannot pick one worksheet from a workbook. Primer3 pairs have no pools, so their orders never include it. The CSV adds each oligo's length, its 1-based start and end on the design reference, its strand and its MSA match counts, and ends with three empty columns, `Synthesis scale`, `Purification` and `Modifications`, which the oligo table of the Order metadata worksheet repeats.

Which file goes to the supplier depends on the supplier, and LGE sends nothing itself. If yours is IDT and the folder holds `IDT-oPools.xlsx`, upload that file and read the instructions kept on its worksheet. For any other supplier, and for an order with no IDT file, LGE writes nothing in the supplier's own format, so copy the oligo names and sequences from `ordering.csv` into the supplier's form. Scale and purification are in none of LGE's files, because LGE cannot know your chemistry, so choose them on that form and use the three empty columns only to record the choices.

The Primer Order viewer lists the counts, the order groups and every exported oligo, and its buttons **Open order workbook**, **Open IDT upload copy** and **Open CSV** open the files in their default applications. The Inspector notes that the order is a subset of the original design, not a new or validated scheme.

Primer3 oligos have no names of their own, so LGE builds one from the record's own identifier, the pair number and the role, giving names such as `LR699574.1_P1_LEFT`, `LR699574.1_P1_PROBE` and `LR699574.1_P1_RIGHT`. Each pair becomes an order group named without the role, such as `LR699574.1_P1`. PrimalScheme names come from the engine and begin with a short run code, as in `a5686d1c_1_LEFT_1`, so rename them on a form that names each oligo. `ordering.csv` keeps every LGE name beside its sequence, so the order still traces back to the analysis, and an IDT oPools upload names only pools, such as `Scheme_1_Pool_1`.

## Placing the order

LGE's export does not choose synthesis options, because those depend on your supplier and your chemistry, and none of its files holds a value for them. Enter the following on the supplier's own order form.

| Item | What to enter |
|---|---|
| Name | One unique name per oligo, without spaces, unless the form names only pools, as IDT's oPools form does. |
| Sequence | Exactly as exported, 5′ to 3′. Never reverse-complement a reverse primer by hand, because LGE already stores it in the orientation you order. |
| Scale | The amount synthesized. The smallest a supplier offers, often 25 nmol, is ample for PCR primers, and a labeled probe is usually sold at a fixed small scale of its own. |
| Purification | Standard desalting, which removes synthesis salts and nothing else, is usual for PCR primers. Dye-labeled probes are normally purified by HPLC, a chromatography step many suppliers require. |
| Degenerate bases | Enter the [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code), such as K, and choose a mixed base, where the synthesizer adds an equal mixture of the bases at that position. |
| Probe labels | A 5′ reporter dye, which gives off the light the instrument reads, and a 3′ quencher, which absorbs it until the probe is cut, both matched to your instrument's detection channels, the wavelengths it reads. FAM, a green dye, with a BHQ-1 or TAMRA quencher is a common first choice, and the supplier's dye list shows which pairs suit which channels. |

A degenerate oligo is a mixture. varVAMP_0's probe, `TATCGCCCTCCCTCTGKTCCTGAGG`, is really two probes, one with G and one with T at the K, each at half the concentration. If a supplier will not place a mixed base in a labeled probe, order the two versions separately and mix them, or set **Maximum probe ambiguities** to 0 in the [varVAMP qPCR design settings](04-designing-qpcr-and-dpcr-assays.md#settings) and design again.

Name oligos so a stranger can read them, by target, assay and role, as in `MamuA1_ex2-3_F` and `MamuA1_ex2-3_R` for the PCR pair, or `MamuA1-001_q0_F`, `MamuA1-001_q0_P` and `MamuA1-001_q0_R` for varVAMP_0. Keep LEFT and RIGHT, or F and R, in every name, so anyone at the bench can tell the strand from the tube. LGE reads these tags only in its own saved names, so renaming for the supplier breaks nothing in the project.

## What good looks like

Before ordering, the in-silico checks should all pass. Every row you want the assay to detect, as long as LGE could compare it, should match at least one oligo of each primer site with 0 mismatches, or with mismatches only near the 5′ end, by the rule for your engine under [Inspect binding against the alignment](#inspect-binding-against-the-alignment). An assay that must tell one lineage or gene from another also needs evidence that it does not match the sequences to exclude, which only Olivar and varVAMP can check, and only when you give them an exclusion set, as [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) shows on the demo.

### Bench validation

After the oligos arrive, validate the assay at the bench as follows.

1. Run a gradient PCR, one reaction per well across annealing temperatures that start a few degrees below the primers' melting temperature and rise in steps of about 2 °C, such as 55 to 65 °C for primers that melt near 60 °C. Pick the highest temperature that still gives strong product, since higher annealing favors specific binding.
2. Check for a single product of the expected size. For end-point PCR, run an agarose gel beside a size ladder and look for one band at the designed length, such as 948 bp for the conserved exon 2 to 3 pair. For a dye qPCR assay, add a melt curve after the last cycle, a slow heating step that reads fluorescence as the products come apart, and look for one peak, since a second peak means a second product or primer dimers.
3. For a quantitative assay, build a standard curve from a tenfold dilution series run in replicate, meaning several wells per dilution so a single pipetting error shows up. Plot the [Cq](../../GLOSSARY.md#cq) of each dilution against the base-10 logarithm of its amount, fit a line, and report the slope, the y-intercept, the R² and the efficiency, as the MIQE guidelines ([Bustin and colleagues 2009](../appendices/bibliography.md#primer-design-background)), the minimum information for publication of quantitative real-time PCR experiments, ask. Efficiency should fall between 90 and 110 percent, which is a slope of about −3.6 to −3.1, since efficiency = 10^(−1/slope) − 1. For a presence or absence assay, also establish the limit of detection, the lowest amount of DNA that still gives a signal in at least 95 percent of replicates, which matters more than efficiency does.
4. Sequence the product and confirm it is the intended gene and region rather than a paralog.
5. Test on samples of known type. For a *Mamu-A1\*001* lineage assay, run animals already typed as positive and animals typed as negative, for example by [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md). Positives must amplify and negatives must not, and every sample should also pass a control assay for a gene every animal carries, so a failed reaction is never read as a negative animal. Include no-template controls, which must stay negative.

The fifth test would expose the demo's five varVAMP qPCR assays. At least one oligo of each matches more than half of the eighteen exclusion sequences perfectly, and for varVAMP_0 only the probe does, matching 11 of the 18, so animals lacking the lineage might amplify, which typed negatives would confirm. The anchored assay in [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) is the one to take to the bench instead.

### When a check fails

No product at any gradient temperature points to a primer that does not bind the samples, so check the binding table for 3′ mismatches against the alleles your animals carry. Several bands or melt peaks point to a second target, often a paralog, so sequence the extra product. Efficiency outside 90 to 110 percent usually comes from a pipetting error in the dilution series, and after that from inhibitors, substances in the sample that slow the polymerase, so rebuild the series before redesigning.

Inside LGE, three messages each point to a likely cause. "Couldn't Load Primer Analysis" appears with a **Retry** button and means LGE could not read or verify the bundle. The line under the title says why, most often because a stored file's checksum no longer matches the record after something inside the bundle was edited, moved or partly copied, and the fix is to restore the bundle or rerun the design. A disabled export button gives its reason in a tooltip, such as "Include at least one candidate pair to export an order.", which **Include all** fixes, or "Show at least one oligo to export an order.", which **Show all** fixes. And a saved scheme whose trim stops with an error naming the [accessions](../../GLOSSARY.md#accession) it expects, or trims almost nothing, means the reads went to a different sequence from the scheme's coordinate reference. Other app problems are listed in [Troubleshooting](../appendices/troubleshooting.md).

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

# Create the annotated reference. RESULT_ID is the "id" line under "results"
# in inspect --json, a code of 36 letters, digits and hyphens
RESULT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
lungfish-cli primers analysis annotated-reference \
  "$PROJECT/Analyses/Mamu-A1 exon 2-3 PCR Primer3 conserved.lungfishprimeranalysis" \
  --result-id "$RESULT_ID" --output-directory "$PROJECT/Analyses"
```

`inspect` prints the analysis and run identifiers, the grouping, and counts of inputs, results and stored files, then "Integrity verified". Add `--json` to print the full [manifest](../../GLOSSARY.md#manifest), the bundle's record of its contents, which is where a result's identifier comes from for `--result-id`. `export-order` writes the same files the window writes, and its `--scope` takes `candidate-pairs`, `selected-assays`, `all-reported-assays` or `displayed`, defaulting to whichever suits the analysis. `annotated-reference` makes the same bundle as **Create Annotated Reference…**, into a folder that must already exist. `primers analysis history` and `primers analysis audit` recheck how a combined PrimalScheme panel chose its amplicons, for people developing the design method, and `history` also needs at least one of `--entity`, `--target`, `--region` or `--stage`.

## Next

This is the last chapter of the Primer Design part. For a tiled scheme, sequence the amplicons and continue with [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) using the scheme you saved here, then call variants as [Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md) shows. For an MHC panel, [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) is the downstream instead, and [Primer Scheme Bundles](../appendices/primer-schemes.md) documents the bundle a saved scheme writes. Record which analysis and which candidate an assay came from alongside the order in your lab notebook, because the analysis bundle holds the provenance that explains it.
