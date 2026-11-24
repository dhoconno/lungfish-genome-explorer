---
title: Reading the Variants Table
chapter_id: 05-variants/02-reading-the-variant-browser
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 22
task: Read, sort, filter, and export the Variants tab of the table drawer, compare two callers in one table, and write a filtered subset to a VCF from the command line.
tags: [variants, table-drawer, filter, presets, search-builder, source-column, inspector, export, hover-card]
tools: [bcftools]
parameters_refs: [variants.filter-table, variants.query, viewport.variant-browser]
entry_points:
  - "Click a mapping result or reference bundle that holds variant tracks, then the table drawer's Variants tab"
  - "Table drawer > Export button > All Matching Rows… or Selected Rows (n)…"
  - "CLI: lungfish-cli variants query"
  - "CLI: lungfish-cli variants export bookmarked"
shots:
  - id: variants-tab-twelve-columns
    caption: "The Variants tab of the table drawer inside the reference bundle viewport, with the columns cut down to Variant Track, the call itself, and three INFO columns, DP, AC, and AN."
  - id: variants-preset-chips
    caption: "The smart-filter chip strip above the Variants table, showing the first three groups, Biological Effect, Quality / QC, and Population / Frequency."
  - id: variants-search-builder
    caption: "The Variant Query Builder sheet with two rules, one on Location and one on an INFO field."
  - id: table-drawer-export-menu
    caption: "The Export menu of the table drawer open on the Variants tab, showing All Matching Rows… with its format submenu of Excel Workbook (.xlsx), CSV, TSV, and JSON, and Selected Rows (0)… dimmed below it."
  - id: variants-inspector-row
    caption: "The Inspector filled with one selected variant row, showing its identity, quality, track and caller settings, and every INFO key on its own line."
  - id: variants-source-column
    caption: "The Variant Track column separating the bcftools rows from the LoFreq rows in the aggregated table, sorted by position."
  - id: variant-track-glyphs
    caption: "The HG002 bcftools variant track in the genome viewport at position 250,527, a heterozygous 0/1 call drawn as a blue genotype cell, with the summary bar of variant types above the genotype row."
illustrations:
  - id: lofreq-af-histogram
    brief: "Two histograms side by side on a Cream background, x axis allele frequency from 0 to 1, y axis number of calls. Left, the HG002 LoFreq track's 862 calls, with one peak near 0.5 (heterozygous sites, one changed copy of two) and one near 1.0 (homozygous sites), labeled 'diploid person: two peaks'. Right, a sketch of a viral population's calls spread continuously across the range with most near 1.0 and a long low tail of minority changes, labeled 'virus population: a continuum'. Lungfish Creamsicle bars, Deep Ink axes, IBM Plex Mono labels."
glossary_refs: [allele-depth, allele-frequency, annotation-track, bcftools, benchmark-vcf, cds, command-line-flag, consequence, csv, depth, filter, filter-profile, fixture, genetic-code, genotype, genotype-quality, hard-filter, heterozygous, hg002, homozygous, indel, info, inspector, json, lofreq, mapping-quality, multi-allelic, operations-panel, phred-score, ploidy, provenance, qual, reading-frame, ref-alt, reference-bundle, sidebar, smart-filter-token, snv, strand-bias, table-drawer, tsv, variant-caller, variant-track, vcf, viewport]
features_refs: [viewport.variant-browser]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A [variant caller](../../GLOSSARY.md#variant-caller) compares aligned reads against the reference and lists every place they disagree. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. Lungfish Genome Explorer (LGE) stores each VCF inside the [reference bundle](../../GLOSSARY.md#reference-bundle) as a named [variant track](../../GLOSSARY.md#variant-track) and shows its rows in a table. This chapter is about that table. [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md) covers a VCF's own columns, and this chapter does not repeat it.

The table lives in the [table drawer](../../GLOSSARY.md#table-drawer), a panel that slides out from the bottom edge of the [viewport](../../GLOSSARY.md#viewport), the main display area of the LGE window. The drawer opens by itself when a bundle has a variant track. **View > Show Drawer** (Control-Command-B) opens and closes it, and you can drag its top edge to resize it. Its **Variants** tab holds the table, **Annotations** lists a bundle's features such as genes, and **Samples** lists its sample columns, the VCF columns that hold each sample's [genotypes](../../GLOSSARY.md#genotype), the alleles it carries at a position.

Above the table sit a row of controls and a strip of filter chips, one-click buttons that each keep only the rows passing one test. **Calls** and **Genotypes** switch between one row per variant and one row per sample, **Region** and **Genome** between the stretch the viewport shows and the whole reference, and a pull-down reading **Auto**, **Haploid**, or **Diploid** tells the frequency chips how many copies of each chromosome the organism carries. **Presets** adds chips for the values of `INFO` keys to the right end of the strip, and **Profiles** saves combinations of chips. **Query Builder...** opens a sheet, a dialog attached to the top of the window, where you build a query, a set of filter rules, one rule at a time. **Clear** drops the chip and Query Builder filters, an Export button writes the rows to a file, and a gear button chooses which columns show.

Sorting, filtering, and hiding columns change only what you see and never touch the VCF on disk, the third of the [three kinds of filter](../01-foundations/05-variants-and-vcf.md#three-kinds-of-filter), after a caller's `FILTER` flag and the thresholds LGE applies when it calls. A filtered subset written as a new VCF comes from the command line, covered at the end of this chapter. Writing `FILTER` flags into a call set takes a [hard filter](../../GLOSSARY.md#hard-filter), a fixed set of arithmetic tests such as the list that GATK, the toolkit behind LGE's human germline calls, publishes, which [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md) covers.

## Why you would do this

The practice data for this chapter, its [fixture](../../GLOSSARY.md#fixture), is human. [HG002](../../GLOSSARY.md#hg002) is a DNA sample from the Genome in a Bottle project, distributed openly and known to high confidence, so a result can be checked against a published answer. The fixture holds Illumina reads mapped to a 500 kilobase stretch of chromosome 20. [Calling Variants](01-calling-variants-from-amplicons.md) called variants on that alignment twice, once with [bcftools](../../GLOSSARY.md#bcftools) and once with [LoFreq](../../GLOSSARY.md#lofreq), and produced 1,040 rows and 862 rows. Filtering is how nineteen hundred rows become an answer to a question, such as which calls rest on too few reads. A question about protein effect needs an [annotation track](../../GLOSSARY.md#annotation-track), a layer that marks where genes sit on the reference, and this fixture's bundle has none, so its `Gene / Protein`, `Consequence`, and `AA Change` columns stay empty.

Two callers reading the same alignment also disagree, and the way they disagree tells you something neither file shows alone. On this fixture the two call sets share 851 positions, bcftools reports 187 that LoFreq does not, and LoFreq reports 10 that bcftools does not. These count distinct coordinates, so the 1,040 bcftools rows cover 1,038 coordinates and the 862 LoFreq rows cover 861, because a position can carry more than one row. Reading the two tracks in one table shows where they disagree, which is where to look before you trust either.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The chapter needs the `HG002 bcftools` and `HG002 LoFreq` tracks in one bundle, because it compares two callers in one table. Either work through [Calling Variants](01-calling-variants-from-amplicons.md) in the Human Mapping and Variants demo project, which leaves both tracks in the reference bundle inside the mapping result, or open the Human Mapping and Variants (with results) demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. That project holds both tracks, made with the same defaults, and a third, the [benchmark](../../GLOSSARY.md#benchmark-vcf), a call set of the true HG002 variants that [Importing Existing VCFs](06-importing-existing-vcfs.md) adds and that serves as an answer key. Its mapping result is the row `minimap2-2026-09-25T00-00-00` under **Analyses**. The [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20) holds the files behind both projects, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Nothing needs installing.

## Procedure

### Open the Variants tab

Click the `minimap2-` mapping result under **Analyses** in the [sidebar](../../GLOSSARY.md#sidebar), the list of folders and results at the left of the window. The viewport opens with the reference bundle inside the mapping result, and the table drawer opens along the bottom of the pane that holds it. Click the drawer's **Variants** tab. Every track in the bundle loads into the one table at once, and the **Variant Track** column names the track each row came from. The drawer reports its row count at the right end of the tab row.

The with-results project's benchmark track adds 961 rows, and most counts in this chapter are for the two callers alone. To hide the benchmark, open the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window, click its **View** tab, click **Annotations** under **View Settings**, and clear the checkbox of `HG002.chr20.10.0-10.5Mb.benchmark.vcf` under **Variant Tracks**.

If the drawer does not open, or its Variants tab is empty, the variant calling has not finished. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists running jobs, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), and wait for its row to end with "Created variant track" and the track's name.

The screenshot below shows the table with its columns cut down.

<!-- SHOT: variants-tab-twelve-columns -->

### Read the columns

Fifteen fixed columns run across the table, after an unlabeled column holding a star. Click a row's star to bookmark it, and the star fills yellow. The `Bookmarked` chip joins the strip the next time LGE redraws it, such as after you switch to another tab and back. Seven of the fifteen are the VCF's own standard columns, `Type` and `Samples` are worked out from each record, and the rest are added by LGE.

| Column | Where it comes from | What it holds |
|---|---|---|
| `Variant Track` | Added by LGE | The track the row came from |
| `Caller Settings` | Added by LGE | The settings recorded for that track's caller run, or "Not recorded" |
| `ID` | From the VCF | The `ID` field, or `<chrom>_<position>` such as `chr20_10.0-10.5Mb_2078` when the caller gave no name |
| `Type` | Worked out | The kind of change, `SNP` for a single-base substitution, an [SNV](../../GLOSSARY.md#snv), `INS` for an insertion, or `DEL` for a deletion, the two kinds of [indel](../../GLOSSARY.md#indel). Other files can also give `MNP` for several neighboring bases changed at once, `COMPLEX` for an allele written as a symbol such as `<DEL>` instead of bases, and `REF` for a record with no alternate allele |
| `Chrom` | From the VCF | The reference sequence name, `chr20_10.0-10.5Mb` here |
| `Position` | From the VCF | The coordinate of the change, counting the first base as 1 |
| `Ref` | From the VCF | The [reference allele](../../GLOSSARY.md#ref-alt), the base or bases already in the reference |
| `Alt` | From the VCF | The alternate allele, the base or bases the reads carried instead |
| `Quality` | From the VCF | The caller's [`QUAL`](../../GLOSSARY.md#qual) score, its [Phred-scaled](../../GLOSSARY.md#phred-score) confidence that a variant exists here |
| `Filter` | From the VCF | The caller's own [pass or fail label](../../GLOSSARY.md#filter) for the row |
| `Samples` | Worked out | How many sample columns hold a call at that position |
| `Source` | Added by LGE | The track name again |
| `Gene / Protein` | Added by LGE | The gene or protein the change falls in, where an annotation supplies one |
| `Consequence` | Added by LGE | A predicted [protein effect](../../GLOSSARY.md#consequence) such as `missense_variant`, where an annotation supplies one |
| `AA Change` | Added by LGE | The amino-acid substitution, where an annotation supplies one |

Where the VCF carries no annotation of its own, LGE fills `Gene / Protein`, `Consequence`, and `AA Change` itself for a variant inside a [CDS](../../GLOSSARY.md#cds), the coding stretch of a gene in the bundle's annotation. It finds the codons from the annotation, in the [reading frame](../../GLOSSARY.md#reading-frame) it records for that CDS, and translates them with the [genetic code](../../GLOSSARY.md#genetic-code) the feature names, the standard code when it names none. On screen the cells fill for the stretch of genome the viewport has loaded, and an export fills every exported row inside a CDS.

LGE reads only the first alternate allele of a [multi-allelic](../../GLOSSARY.md#multi-allelic) row and gives the whole row that one type, so every substitution and indel count here follows that rule.

Beyond the fifteen, the table adds a column for each [`INFO`](../../GLOSSARY.md#info) key the loaded tracks carry, an extra per-variant measurement a caller records beside the call, and hovering a column header shows the description the VCF's own header gives it. `DP` is the read [depth](../../GLOSSARY.md#depth) at the position and `AF` the [allele frequency](../../GLOSSARY.md#allele-frequency), the share of those reads carrying the change. `AD` holds the [allele depths](../../GLOSSARY.md#allele-depth), the reads supporting the reference and the alternate, `DP4` the reference and alternate bases counted on each strand, `SB` a [strand bias](../../GLOSSARY.md#strand-bias) score, and `MQ` the average [mapping quality](../../GLOSSARY.md#mapping-quality), as [Walking through one row](../01-foundations/05-variants-and-vcf.md#walking-through-one-row) explains. The bcftools track fills seventeen `INFO` columns and the LoFreq track four, `AF`, `DP`, `DP4`, and `SB`, so each track leaves some columns empty.

Click a header once to sort ascending and again for descending. Right-click a header for sizing and sorting commands and for **Filter** commands such as **Filter Quality ≥…**, which asks for a value. Header filters are separate from the chips, so **Clear** leaves them in place and **Clear Variant Column Filters** in the same menu removes them. To hide or reorder columns, click the gear button, whose tooltip reads "Column visibility and order".

### Select a row and read the Inspector

Click any row. The Inspector's **Selected Item** tab fills with a **Variant Detail** section for that variant. It lists the identifier, type, position, and alleles, then the quality and filter, the track and caller settings, and any gene, consequence, and amino-acid change. A **Genotype Summary** appears where the file carries genotypes, and a **Variant Fields** block shows every `INFO` key on its own line, which for a bcftools row includes `AD`. **Zoom to Variant** and **Copy Info** buttons sit at the bottom, and the up and down arrow keys move the selection once the table has focus. The screenshot below shows the Inspector for one row.

<!-- SHOT: variants-inspector-row -->

Shift-click or Command-click to select several rows, such as both callers' rows at one position. The Inspector then shows a **Variant Selection** section with counts of **Selected Rows** and **Unique Variants**, which counts a call once even when several of its sample lines are selected. It breaks the rows down by track, chromosome, and type and lists one collapsible entry per row. Past 100 rows it lists the first 100 under a line such as "Showing 100 of 250 selected variants", and **Copy Selection** still copies every selected row.

Right-click a row for a menu that copies its ID, coordinates, alleles, or the whole row as a VCF line, zooms to it, and bookmarks it. **Delete Selected Variant…** and **Delete All Variants…** in the same menu permanently remove rows from the bundle's variant database, the file LGE builds from each track so the table can filter quickly, so unlike a filter they change the bundle, and each asks you to confirm. To remove whole tracks, right-click a reference bundle in the sidebar and choose **Delete Variant Tracks…**, which deletes every variant track of that bundle, with its database, after an alert that names them.

### Filter with the preset chips

Above the table, a strip of chips is open whenever the Variants tab is. Each chip is a saved filter rule this manual calls a [smart-filter token](../../GLOSSARY.md#smart-filter-token), grouped into four sections, and most carry a compact count of the variants they match. The counts add up every loaded track, the ones you have hidden included, so a chip can count more rows than the table shows. **Presets** adds chips for the values of `INFO` keys that take few distinct values to the right end of the same strip, which scrolls sideways when it is wider than the window. The screenshot below shows the strip with the unusable chips dimmed.

<!-- SHOT: variants-preset-chips -->

| Section | Chips |
|---|---|
| Biological Effect | `SNV`, `Indel`, `High Impact`, `Moderate+` (moderate or high impact), `ClinVar Path.` (pathogenic in ClinVar, a public database of clinical judgments about variants) |
| Quality / QC (quality control) | `PASS`, `Qual ≥ 30`, `DP ≥ 10` |
| Population / Frequency | `Rare (<1%)`, `Minor (≤20%)`, `Mixed (20-80%)`, `Dominant (≥80%)` |
| Sample / Genotype | `Bookmarked` |

A chip whose field the loaded tracks lack is dimmed, and its tooltip names what is missing. `High Impact` and `Moderate+` read an impact field, an annotation program's own ranking of how severely a change may affect the protein. SnpEff and VEP write it inside `ANN` and `CSQ` annotations, which LGE splits into one `INFO` column per field at import, so the chips and the Query Builder find keys such as `ANN_IMPACT`. `ClinVar Path.` reads a `CLNSIG` field. Neither caller here writes those fields, so those three chips stay dimmed. `Rare (<1%)` needs an `AF` key, which LoFreq supplies, and there `AF` is the share of reads carrying the change, so the chip keeps changes seen in under 1 percent of reads and not changes that are rare in people.

The `Minor`, `Mixed`, and `Dominant` chips read a within-sample share, the allele frequency of reads at one position carrying the change, and not how common a variant is in a population, as [What AF means](../01-foundations/05-variants-and-vcf.md#what-af-means) sets out. They can be clicked only when a track carries genotypes and LGE takes the organism to be haploid, meaning it carries one copy of each chromosome, so Haploid allows them, Diploid dims them with the tooltip "Only available for haploid organisms", and Auto guesses from the reference size. In a virus a read share near one half means a mixture of two populations, but in a diploid human it means a routine [heterozygous](../../GLOSSARY.md#heterozygous) call, one copy changed and one not, so set Diploid here.

Click a chip to apply it and click it again to remove it. Chips combine, so `PASS` and `DP ≥ 10` together keep only rows satisfying both. Picking one chip clears the others in three sets, `SNV` and `Indel`, `High Impact` and `Moderate+`, and the three frequency chips.

The `FILTER` column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains. With the **Region / Genome** switch on **Genome**, click `PASS` while the bcftools rows are on screen and those rows vanish. Not one of the 1,040 bcftools rows says `PASS`, because bcftools as LGE runs it applies no filter of its own and writes `.` there. The 862 LoFreq rows all say `PASS`, so with the two caller tracks loaded the table drops from 1,902 rows to 862, or from 2,863 to 1,823 with the benchmark shown, whose 961 rows are all `PASS`. Read a bare `.` as unjudged rather than failed, and look at the column before you filter on it. Click **Clear** to bring the rows back.

A **Profiles** pull-down, shown when the window is wide enough, saves assembling the same chips again. It offers four built-in combinations, `Clinical` (`PASS` and `ClinVar Path.`), `Research` (`Rare (<1%)`), `QC` (`Qual ≥ 30` and `DP ≥ 10`), and `High Confidence` (`PASS`, `Qual ≥ 30`, and `High Impact`), each hidden when the tracks lack a field its chips need. `Save Current as Profile…` stores your own on this Mac, keyed to the bundle, and `No Profile` clears the selection.

### Filter with the Query Builder

For anything the chips cannot express, click **Query Builder...**, which reads **Edit Query...** once a filter is active. The Variant Query Builder sheet opens with one blank rule under a line that names the scope it will query, the region on screen or the whole genome. Each rule picks a category, a field inside it, an operator, and a value. **Add Rule** adds another, **Apply** filters the table, and **Edit Query...** reopens the sheet with those rules. A row must satisfy every rule, and the sheet has no way to ask for either-or.

| Category | Fields it offers |
|---|---|
| Location | Region, Chromosome, and Gene List |
| Variant Identity | ID/Name and Type |
| Biological Effect | IMPACT, GENE, and CLNSIG |
| Population/Frequency | `AF`, the population-database keys `gnomAD_AF`, `ExAC_AF`, and `1000G_AF`, and any frequency-like `INFO` key the tracks carry |
| Call Quality | Quality, Filter, DP, MQ, and Sample Count |
| Sample/Genotype | A genotype, allele-frequency, and depth field for each sample the tracks declare |
| INFO Field | Every `INFO` key the tracks carry |

The population-database keys name public catalogs of how common a variant is across many people, and neither caller here writes them, so they find nothing on this fixture. A Sample/Genotype field takes its sample's name followed by `GT`, `AF`, or `DP`, and its `AF` is worked out from that sample's allele depths.

The operators depend on the field. A Location rule takes only `=`, meaning "inside this range", and a Gene List rule takes gene names separated by commas, as the gray hint `BRCA1, TP53, EGFR` in its field shows. An INFO Field rule takes `=`, `~` (contains), `<`, `<=`, `>`, and `>=`. A genotype rule takes `=` and `!=` (is not equal to), and the per-sample `AF` and `DP` fields add the numeric comparisons.

A Region value must name the reference sequence as well as the range, in the form `chrom:start-end`, because a bare range applies no restriction and the table comes back unfiltered. Coordinates count from the start of the slice, which is 500,001 bases long because the region from 10,000,000 to 10,500,000 includes both ends, so positions run from 1 to 500,001.

Try a pair of rules. Set the **Region / Genome** switch to **Genome** first, and hide the benchmark and the `HG002 LoFreq` track as the first step shows, so only the bcftools rows remain. Set the first rule to Location, Region, `=`, `chr20_10.0-10.5Mb:1-250000`, which keeps the first half of the slice, and click Apply. The table holds 558 rows. Add a second rule, INFO Field, `DP`, `>=`, `30`, and click Apply again. That keeps 514 of the 558 rows, so most calls in the first half rest on at least thirty reads. The screenshot below shows the sheet with both rules.

<!-- SHOT: variants-search-builder -->

A row of buttons headed **Presets** under the scope line loads ready-made rule sets such as `High-Confidence Coding` and `Indels Only`, and hides one whose rules name a missing annotation or `INFO` field. **Save Preset...** stores a query of your own in the same row, under the name you type in the **Preset Name** field of the small sheet it opens.

A very large variant database limits the Query Builder. From 1 GB it is disabled until you zoom the viewport in below 10 Mb, and from 25 GB it stays disabled and the **Presets** button is hidden. This fixture is far below either size.

### Export the rows you kept

A filtered table is often the thing you want to send a colleague or open in a spreadsheet. Click the Export button at the right of the drawer's tab row, a square with an arrow whose tooltip reads "Export table data". Its menu offers two sets of rows.

- **All Matching Rows…** writes every row the current filters keep, including rows past the table's display limit, which is 5,000 rows until you change **Max table items** under Display Limits on the **Rendering** tab of LGE's Settings.
- **Selected Rows (n)…** writes only the rows you selected, where n is their count, and stays dimmed until you select one.

The screenshot below shows the open menu with **Selected Rows (0)…** dimmed.

<!-- SHOT: table-drawer-export-menu -->

Each opens a submenu of formats. **Excel Workbook (.xlsx)** opens in Excel, Numbers, or any spreadsheet program. [**CSV**](../../GLOSSARY.md#csv) and [**TSV**](../../GLOSSARY.md#tsv) are plain-text tables with commas or tabs between the columns, which any spreadsheet or script reads. [**JSON**](../../GLOSSARY.md#json) is a plain-text format that programs read directly. Choose one, then a name and a place in the save sheet, which suggests a name such as `variants-all-matching.csv`. The file holds the columns the table shows, in their order.

LGE first collects the rows under a sheet with a **Cancel** button. A row titled "Export Variants Table" then appears in the [Operations Panel](../../GLOSSARY.md#operations-panel), runs `lungfish-cli bundle export-annotation-table`, and writes the file with a [provenance](../../GLOSSARY.md#provenance) record beside it. When it ends, the drawer reads "Exported", the row count, and the file name. The same menu exports the Annotations and Samples tabs, and the Genotypes view of this tab. Bookmarked rows have their own route, **Export Bookmarked Variants…** in a row's right-click menu, which writes them as TSV.

### Read the two callers against each other

LGE has no side-by-side comparison view and no intersection button. It gives you one table holding both call sets with a `Variant Track` column, which is enough to compare them by eye.

Sort by `Position` ascending. Where both callers reported a coordinate, their two rows land on adjacent lines with different `Variant Track` values, and with the benchmark shown its row joins them where it lists that coordinate. Rows only one caller reported sit alone. Read the `Variant Track` text rather than the viewport, because the marks the viewport draws encode the genotype and the variant type, never the source file, as [The variant track in the viewport](#the-variant-track-in-the-viewport) shows. The screenshot below shows the callers' rows interleaved by position.

<!-- SHOT: variants-source-column -->

Coordinate 2078 shows a shared call. Use **Sequence > Go to Location…** (Cmd-L), type `chr20_10.0-10.5Mb:2078`, and click Go, with the **Region / Genome** switch on **Region** so the table trims to what is on screen. Both callers report a reference `G` read as `A`. The bcftools row carries the genotype `1/1`, meaning both copies carry the change, with allele depths of 0 reference reads and 52 alternate reads, which the Inspector lists as `AD=0,52`. The LoFreq row carries no genotype and reports `AF` 1 instead. Every read carries the `A`, so this person has the change on both copies, a [homozygous](../../GLOSSARY.md#homozygous) position, and the two callers agree in different notations.

Coordinate 250527 shows the other common kind of call. LoFreq reports a reference `C` read as `T` with `AF` 0.571 at a depth of 63, so a little over half the reads carry the change, which is what a heterozygous position in a human sample looks like. The bcftools row there carries the genotype `0/1`, one copy changed and one not, with allele depths of 20 reference reads and 33 alternate reads. The two callers count different reads, as [The pileup at position 250,527](../04-alignments/02-reading-an-alignment.md#the-pileup-at-position-250527) in Reading an Alignment shows.

Where the callers disagree, the cause is mundane. Of the 1,040 bcftools rows, 181 are indels, and LoFreq called none, because LoFreq skips indels unless asked. That accounts for 180 of the 187 positions only bcftools reported, and the other 7 are substitutions bcftools called and LoFreq did not, the ordinary spread between two statistical models. None of the 10 positions only LoFreq reported appears in the benchmark, so those 10 are probably the calls most worth a second look. To make LoFreq call indels, type `--call-indels` into the **Extra arguments** field of the Call Variants dialog and run the call again, as [Calling Variants](01-calling-variants-from-amplicons.md) explains.

### Calls and genotypes

The **Calls** and **Genotypes** switch at the left of the toolbar changes what one row means. In Calls, the default, a row is one variant, one line of the VCF. In Genotypes, which reads **GT** in a narrow window, a row is one sample's genotype at one variant, with the columns `Sample`, `Track`, `Variant`, `Chrom`, `Position`, `GT`, `Zygosity` (shown only when LGE takes the organism to be diploid), `AD`, `DP`, `GQ`, and `Allele Bal.`. `Zygosity` spells the genotype out as Het, Hom Alt, or Missing, [`GQ`](../../GLOSSARY.md#genotype-quality) is the caller's confidence in the genotype, and `Allele Bal.` is the share of reads carrying an alternate allele, worked out from `AD`. A sample reading `0/0`, the reference on both copies, gets no row of its own.

The bcftools track has one sample and the LoFreq track has none, because LoFreq writes no genotype columns, so a LoFreq row reads 0 under `Samples` and has no line in the Genotypes view. The switch matters for a VCF with several sample columns, such as a family called together, where each sample gets its own line at each position. The **Samples** tab lists the sample columns the loaded tracks declare, and the name there is the one the command line expects after its `--filter` [flag](../../GLOSSARY.md#command-line-flag), an option typed after a command.

A call set of many samples is easier to read in groups. On the **Samples** tab, **Groups** opens the Sample Groups sheet. Type a name such as Cases in **New group**, click the plus button beside it, select the samples that belong to the group, and click **Apply**. The pop-up beside **Groups** then shows only the samples of one saved group. Neither caller track in the demo project has several samples to group, but [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md) builds a three-person call set that does.

### The variant track in the viewport

The viewport draws the variant tracks of the bundle together under the sequence, so a call can be found by eye before it is found in the table. Go to `chr20_10.0-10.5Mb:250527` with **Sequence > Go to Location…** (Cmd-L) and zoom in until single calls separate. The screenshot below shows the heterozygous call at that position.

<!-- SHOT: variant-track-glyphs -->

The drawing has two layers. A thin summary bar at the top stacks the variants under each screen pixel by type, green for single-base substitutions, violet for insertions, and red for deletions, and its label at the left reads a count such as `2,863 variants`, taken over all the shown tracks and the stretch the viewport has loaded. Below it, each sample gets a row, and each call is a small block as wide as its reference allele, colored by genotype. In the default color theme a heterozygous call such as the `0/1` at 250,527 is blue, a homozygous call such as the `1/1` at 2,078 is deep indigo, a reference call is light gray, and a missing call is near white.

Hover a block for a card that lists the variant, its track, depth, allele frequency, quality, filter, and predicted effect, then the sample's genotype, spelled out as `HET` or `HOM_ALT`, which confirms the color you are looking at. Hover the summary bar instead and the card lists every call under the pointer. The card closes when the pointer leaves it, unless you click inside it or click its **Pin** button. **Copy** puts its whole text on the clipboard, and **Close** dismisses it. Click a block itself to select the variant, which fills the Inspector's **Selected Item** tab. When more than 5,000 calls are in view, the genotype rows give way to the message "Zoom in to display genotypes" with the count, and only the summary bar is drawn.

Position 2,078 is too far from 250,527 to share a view, so go to `chr20_10.0-10.5Mb:2078` with Cmd-L. At 2,078 every read carried the change, and the block is indigo. At 250,527 about half did, and it is blue. A human track with no blue at all says the ploidy was set wrongly when the calls were made. A blue call in a sample that carries one copy of its genome says the same.

## Settings

Seven controls sit in the drawer toolbar on the Variants tab, beside the **All** and **None** buttons that switch every variant-type chip on or off. The Query Builder sheet adds three fields, and the Sample Groups sheet one. Only the Query Builder has a command-line counterpart, the `--filter` flag of `variants query`, and that flag follows its own typing rules, which accept only tests on samples, such as a sample's genotype, depth, or allele frequency, as the last section sets out.

**Calls / Genotypes.** Switches the table between one row per variant and one row per sample genotype at each variant. The default is Calls, the right view for a track with one sample or none, as the two fixture callers have. Switch to Genotypes when a VCF holds several samples and you want their calls side by side. This setting has no command-line flag.

**Region / Genome.** Decides whether the table lists only variants inside the stretch the viewport shows or queries the whole reference. The default is Region, which keeps the table in step with what you are looking at and each query small. Switch to Genome when counting or filtering across the whole reference, which every count in this chapter assumes. This setting has no command-line flag.

**Presets.** Shows or hides extra chips at the right end of the strip, one for each value of an `INFO` key that takes few distinct values, beside the smart-filter chips that are always on screen. The default is hidden with no chip applied, so the table starts with every row of every loaded track. Open it to filter on one such value, and expect the button to hide when the window is too narrow or the tracks declare no `INFO` keys. This setting has no command-line flag.

**Profiles.** Applies a saved combination of chips, either one of the built-in `Clinical`, `Research`, `QC`, and `High Confidence` profiles or one you saved with `Save Current as Profile…`. The default is `No Profile`, so no combination is applied. Use it when you apply the same chips often, and remember that a saved [filter profile](../../GLOSSARY.md#filter-profile) stays on this Mac. This setting has no command-line flag.

**Query Builder....** Opens the Variant Query Builder sheet, the fullest way to compose a filter by hand on this tab, where every rule you add must hold. It opens with one blank rule for you to fill in, or with the active filter's rules when its button reads **Edit Query...**. Use it when a chip is not specific enough, such as for a coordinate window or an `INFO` threshold, and expect it to be disabled on a very large variant database. On the command line the nearest counterpart is the `--filter` flag of `variants query`, which accepts only tests on samples.

**Gene List.** Keeps the variants in the genes you name, separated by commas, as a Location rule of the Query Builder. The field starts empty under the gray hint `BRCA1, TP53, EGFR`. Use it when a short list of genes matters more than a coordinate window. This setting has no command-line flag.

**Value.** Holds what a Query Builder rule compares its field against, such as `30` for a depth or `chr20_10.0-10.5Mb:1-250000` for a region. It starts empty under the gray hint Value. Fill it on every rule you add, since the field, the operator, and this value together make the rule. This setting has no command-line flag.

**Preset Name.** Names a query you save with **Save Preset...**, so it joins the sheet's list of presets. It starts empty, and the sheet's **Save** button stays dimmed until you type a name. LGE does not write the saved query to disk, so it lasts at most until you quit, and you should pick a name that says what the query keeps, such as its gene or its threshold. This setting has no command-line flag.

**Auto / Haploid / Diploid.** Tells the three within-sample frequency chips how to read an allele frequency, since the same share of reads means something different with one genome copy than with two. The default is Auto, which reads a [ploidy](../../GLOSSARY.md#ploidy) note from the bundle's metadata when there is one and otherwise treats any reference under 10 megabases as haploid, because viral and bacterial genomes are small. That guess suits a whole viral genome and is wrong for a slice of a human chromosome, this fixture's 500 kilobases included, so choose Diploid when reading part of a large genome and Haploid in the opposite case. This setting has no command-line flag.

**Clear.** Drops every active filter at once, the chips and anything the Query Builder wrote, and returns the full table. It is hidden until a filter is active, so its presence is itself the sign that something is filtered. Reach for it first whenever a table looks emptier than it should, and remember that a filter set from a column header stays until **Clear Variant Column Filters** removes it. This setting has no command-line flag.

**New group.** Names a new group of samples on the Sample Groups sheet, which the plus button beside it adds. It starts empty, and the plus button stays dimmed until you type. Add one group for each condition you want to compare, such as cases and controls. This setting has no command-line flag.

## Reading the results

Set the **Region / Genome** switch to **Genome** and read the table with no filter applied. It holds 1,902 rows for the two caller tracks, the 1,040 bcftools rows plus the 862 LoFreq rows, and 2,863 rows with the benchmark shown. The tracks are stacked rather than merged, so a coordinate both callers reported contributes two rows.

Take the `Filter` column first. Every bcftools row reads `.` and every LoFreq row reads `PASS`. That reflects what each caller writes and says nothing about quality, since bcftools leaves the judgment to you and LoFreq writes only the rows that survive its filters.

Take `Quality` next. A Phred score is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand, and a caller's `Quality` uses the same scale for the whole call. Each caller stretches that scale in its own way, so read each track on its own and never rank one caller against the other. The bcftools rows run from 3.2 to 228.4, and 12 of the 1,040, about 1 percent, fall below 30. The LoFreq rows run from 73 to 2,478 and none fall below 30. The `Qual ≥ 30` chip applies one threshold to both tracks, so it finds a track's weakest rows and says nothing about which caller is better.

Take depth third. Depth, also called coverage, is the number of reads covering one position. Every bcftools row sits at a depth of 10 or more, because the Call Variants dialog's Minimum Depth of 10 removed shallower rows before the track was written, and the rows average about 43 reads, well above that floor. Depth matters because an allele frequency means different things at different depths. Half the reads at a depth of 4 is two reads of evidence. Half the reads at a depth of 63 is more than thirty.

Take allele frequency last, which is where the tracks differ most in shape. The picture below sets the LoFreq track's frequencies on the left beside a sketch of a viral population's on the right.

<!-- ILLUSTRATION: lofreq-af-histogram -->

Of the LoFreq rows, 339 sit at or above 0.8, 517 between 0.2 and 0.8, and 6 below 0.2. To check the first count, add an INFO Field rule on `AF` with `>=` and `0.8` in the Query Builder, and for the last use `<` and `0.2`. Of the two callers only LoFreq writes `AF`, so only its rows can match. That two-humped shape is what a diploid human sample should produce, a heterozygous group near one half and a homozygous group near one. The bcftools track has no `AF` key, but its genotypes show the same two groups, 617 heterozygous `0/1` rows and 405 homozygous `1/1` rows, plus 18 `1/2` rows where the two copies carry different changes.

The `Type` column adds the last piece. Of the 1,040 bcftools rows, 859 are substitutions and 181 are insertions or deletions, and all 862 LoFreq rows are substitutions. The `Indel` chip therefore hides every LoFreq row, because LoFreq called no indels, and keeps the 181 bcftools rows, and the benchmark's 152 as well, 333 in all, when the benchmark is shown.

## What good looks like

Five checks are worth making on any variants table before you build on it.

First, read the row count against the region and the caller. This slice's benchmark holds 961 variants, so a caller that returns about that many rows is probably in the right range. LoFreq's 862 rows cover 861 positions, and 808 of those, about 94 percent, match a benchmark position. The bcftools track holds more rows, mostly because it also calls indels. A count in the single digits would probably mean the alignment failed or the reference is wrong, and tens of thousands would probably mean sequencing error is being reported as signal.

Second, look at the `Filter` column itself before you filter on it, because an empty table after a chip click means either that no row passed or that no row was ever judged.

Third, check that quality and depth have a healthy shape, most rows well clear of the thresholds and a short tail near the bottom. Sort by `Quality` ascending and count the rows before the values reach 30, which is 12 of the bcftools rows here, about 1 percent of the track. If most of a track sat below a threshold, the alignment or the depth is the problem, so go back to the alignment.

Fourth, when two tracks are loaded, look for a mundane explanation of their disagreement before an interesting one. Here LoFreq's indel default explains nearly all of bcftools' extra positions, and a disagreement that no difference in caller behavior explains is worth investigating.

Fifth, know where each row came from. Each track's provenance record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads, names the caller, its version, and the thresholds applied.

## On the command line

The Export button writes tables and JSON, never a VCF. When another program needs your filtered rows as a VCF, `lungfish-cli variants query` reads the bundle's variant database, applies a filter written as text, and writes the matching rows to a new VCF with a provenance record beside it. It reads only the first variant track in the bundle that has a database, first meaning the earliest one added, and has no option to pick another. On the bundle Calling Variants builds, that is the bcftools track. Every flag of `variants query` is listed in [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference.

Its filter grammar, the typing rules for the filter text, is not the Query Builder's. The `--filter` flag accepts tests on one sample's genotype, written `Sample[<name>].<field>`, where the name is the one the **Samples** tab lists, `HG002.chr20.10.0-10.5Mb` here, and the field is `GT`, `AF`, or `DP`. Query Builder clauses such as `filter=PASS`, and comparisons against `INFO` keys such as `DP>=10`, are rejected with "Unsupported smart-filter clause", meaning the command does not recognize the filter. A sample name that does not match exactly, such as `HG002` alone, is not an error and writes a VCF with no rows.

The block uses the Human Mapping and Variants (with results) demo project, whose mapping result has a fixed name. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains Terminal, the `PROJECT` line, the backslashes, and the quotes, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make the name `lungfish-cli` work in Terminal. For your own run, find your `minimap2-` folder inside the `Analyses` folder of your project in Finder, and put its name in the `BUNDLE` line.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
BUNDLE="$PROJECT/Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref"

# Heterozygous calls in the first track. 617 rows here.
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002.chr20.10.0-10.5Mb].GT=0/1' \
    --output heterozygous.vcf

# Calls where at least half the reads carry the alternate. 755 rows here.
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002.chr20.10.0-10.5Mb].AF>=0.5' \
    --output majority.vcf

# Count the rows of the first file, which are the lines that do not start with #.
grep -vc '^#' heterozygous.vcf
```

The counts in the comments come from this demo project, and the new files land in the folder Terminal is working in, your home folder in a new window. `--limit` caps the export and defaults to 5000 rows, so raise it for a larger track. Two drawer exports have commands of their own. `lungfish-cli variants export bookmarked` writes bookmarked rows as TSV, and the Export button's row records `lungfish-cli bundle export-annotation-table`, which reads a small file the app writes beside the output, listing the rows to write. Copy that command from the row with **Copy CLI Command** in its right-click menu, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) explains, rather than typing it.

## Next

Continue to [Nanopore Variant Calling](04-nanopore-variant-calling.md), which calls long reads with the callers built for them and reads their rows in this same table. [Extracting a Consensus Sequence](05-consensus-and-lineage.md) turns an alignment into a sequence, and [Importing Existing VCFs](06-importing-existing-vcfs.md) adds the benchmark as a third track to read against these two.
