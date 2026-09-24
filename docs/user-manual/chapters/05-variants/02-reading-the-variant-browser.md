---
title: Reading the Variants Table
chapter_id: 05-variants/02-reading-the-variant-browser
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 20
task: Read, sort, and filter the Variants tab of the table drawer, compare two callers in one table, and write a filtered subset to a VCF from the command line.
tags: [variants, table-drawer, filter, presets, search-builder, source-column, inspector]
tools: [bcftools]
parameters_refs: [variants.filter-table, variants.query]
entry_points:
  - "Open a reference bundle, then the table drawer's Variants tab"
  - "CLI: lungfish-cli variants query"
shots:
  - id: variants-tab-twelve-columns
    caption: "The Variants tab of the table drawer inside the reference bundle viewport, with the fixed columns from Variant Track through AA Change and both caller tracks loaded."
  - id: variants-preset-chips
    caption: "The Presets chip strip open above the Variants table, showing the first three groups, Biological Effect, Quality / QC, and Population / Frequency."
  - id: variants-search-builder
    caption: "The Variant Query Builder sheet with two rules, one on Location and one on an INFO field."
  - id: variants-inspector-row
    caption: "The Inspector filled with one selected variant row, showing its identity, quality, track and caller settings, and every INFO key on its own line."
  - id: variants-source-column
    caption: "The Variant Track column separating the bcftools rows from the LoFreq rows in the aggregated table, sorted by position."
illustrations: []
glossary_refs: [allele-depth, allele-frequency, bcftools, consequence, depth, coverage-breadth, filter, genotype, heterozygous, homozygous, indel, info, ivar, lofreq, phred-score, ploidy, provenance, ref-alt, reference-bundle, smart-filter-token, table-drawer, variant-caller, variant-track, vcf]
features_refs: [viewport.variant-browser]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A [variant caller](../../GLOSSARY.md#variant-caller) compares aligned reads against the reference and lists every place they disagree. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. Lungfish Genome Explorer (LGE) stores each VCF inside the [reference bundle](../../GLOSSARY.md#reference-bundle) as a named [variant track](../../GLOSSARY.md#variant-track) and shows its rows in a table. This chapter is about that table. How to read a VCF's own columns is covered in [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md), and this chapter does not repeat it.

The table lives in the [table drawer](../../GLOSSARY.md#table-drawer), a panel that slides out from the bottom edge of the reference bundle viewport, on a tab labelled **Variants**. The drawer opens by itself when you load a bundle that carries at least one variant track. You can drag its top edge to resize it, and LGE remembers the height. Two other tabs share the drawer. **Annotations** lists gene features, and **Samples** lists the sample columns the loaded VCF files declare.

A row of controls above the table decides what it shows. **Calls** and **Genotypes** switch between one row per variant and one row per sample. **Region** and **Genome** decide whether the table lists only the stretch the viewport shows or the whole reference. **Presets** opens a strip of one-click filter chips, and **Profiles** saves combinations of them. A pull-down reading **Auto**, **Haploid**, or **Diploid** tells the frequency chips how many copies of each chromosome the organism carries. **Query Builder...** opens a sheet that builds a query rule by rule, and **Clear** drops every filter. A gear button at the end chooses which columns show. There is no free-text query box, and the Query Builder is what replaces it.

Everything the table does is display. Sorting, filtering, and hiding columns change what you see and never touch the VCF on disk. Writing a filtered subset out as a new file belongs to the command line, covered at the end of this chapter.

## Why you would do this

The worked example is human. HG002 is a consenting research participant whose DNA is distributed as a cell line, so laboratories everywhere sequence the same genome. The HG002 chromosome 20 slice holds Illumina reads mapped to a 500 kilobase stretch of chromosome 20. [Calling Variants](01-calling-variants-from-amplicons.md) called variants on that alignment twice, once with [bcftools](../../GLOSSARY.md#bcftools) and once with [LoFreq](../../GLOSSARY.md#lofreq), and produced 1,040 rows and 862 rows. Nobody reads nineteen hundred rows one at a time. Filtering is how a call set becomes an answer to a question, such as which changes might alter a protein, or which calls rest on too few reads.

There is a second reason. Two callers reading the same alignment disagree, and the way they disagree tells you something neither file tells you alone. On this fixture the two call sets share 851 positions, bcftools reports 187 that LoFreq does not, and LoFreq reports 10 that bcftools does not. Those figures count distinct coordinates, and each track keeps its own row where both callers reported one. Reading the two tracks in one table is the cheapest calibration you will run.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the HG002 chromosome 20 slice fixture, whose files are in the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. What the chapter needs in the project is the two variant tracks those files lead to. Work through [Calling Variants](01-calling-variants-from-amplicons.md) first, which leaves a reference bundle carrying a bcftools track and a LoFreq track. Both are needed, because half of what this chapter teaches shows only when two tracks sit in one table.

Nothing needs installing. The table reads files already inside the bundle.

## Procedure

The first two steps open the table and orient you in its columns. The next three cover selecting a row, filtering with chips, and filtering with the Query Builder. The last reads the two callers against each other.

### Step 1. Open the Variants tab

Click the reference bundle in the project sidebar. The viewport fills with the bundle, and the table drawer opens along the bottom. Click the drawer's **Variants** tab.

Both tracks load into the one table at once, and the **Variant Track** column names the track each row came from. If the drawer does not open, or its Variants tab is empty, the variant calling has not finished. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), and wait for its row to end with "Created variant track" and the track's name.

<!-- SHOT: variants-tab-twelve-columns -->

### Step 2. Read the columns

Fifteen fixed columns run across the table, after an unlabelled column for bookmarking a row. Seven are the VCF's own standard columns. `Type` and `Samples` are worked out from each record. The rest are added by LGE.

| Column | Where it comes from | What it holds |
|---|---|---|
| `Variant Track` | Added by LGE | The name of the variant track the row came from |
| `Caller Settings` | Added by LGE | The settings recorded for that track's caller run, such as the thresholds applied, or "Not recorded" |
| `ID` | From the VCF | The `ID` field, or `<chrom>_<position>` such as `chr20_10.0-10.5Mb_2078` when the caller assigned no name |
| `Type` | Worked out | Whether the row is a substitution or an insertion or deletion |
| `Chrom` | From the VCF | The reference sequence name, `chr20_10.0-10.5Mb` on this fixture |
| `Position` | From the VCF | The coordinate of the change, counting the first base of the sequence as 1 |
| `Ref` | From the VCF | The [reference allele](../../GLOSSARY.md#ref-alt), the base or bases already in the reference |
| `Alt` | From the VCF | The alternate allele, the base or bases the reads carried instead |
| `Quality` | From the VCF | The caller's confidence in the call, on the Phred scale described under Reading the results |
| `Filter` | From the VCF | The caller's own pass or fail label for the row |
| `Samples` | Worked out | How many sample columns hold a call at that position |
| `Source` | Added by LGE | The track name again |
| `Gene / Protein` | Added by LGE | The gene or protein the change falls in, where an annotation supplies one |
| `Consequence` | Added by LGE | A predicted protein effect such as `missense_variant`, where an annotation supplies one |
| `AA Change` | Added by LGE | The amino-acid substitution, where an annotation supplies one |

LGE reads only the first alternate allele on a row and gives the whole row that one type, so a row offering two alternates is counted once. Every substitution and indel count in this chapter follows that rule. `Quality` reads `.` on a track called with [iVar](../../GLOSSARY.md#ivar), an amplicon caller this fixture does not use, because iVar writes no quality there.

Beyond the twelve, the table adds a column for each [`INFO`](../../GLOSSARY.md#info) key the loaded tracks carry, which are the extra per-variant measurements a caller records beside the call. Allele frequency, gene, and impact come first when present, and the rest follow in alphabetical order. Two keys matter here. `DP` is the read depth at the position, and `AF` is the [allele frequency](../../GLOSSARY.md#allele-frequency), the fraction of those reads carrying the change. The bcftools track fills seventeen `INFO` columns and the LoFreq track four, `AF`, `DP`, `DP4`, and `SB`. Only some names overlap, so each track leaves some columns empty.

Click a header once to sort ascending and again for descending. Right-click a header for Size to Fit, sorting, and filter commands such as keeping rows equal to or above a value. To hide or reorder columns, click the gear button, whose tooltip reads "Column visibility and order". LGE remembers the visibility and order set there, but not column widths.

### Step 3. Select a row and read the Inspector

Click any row. The Inspector on the right fills with that one variant, one field to a line. A VCF packs its `INFO` values into one string of `key=value` pairs joined by semicolons, and the Inspector breaks it apart. It shows the identifier and type, the position, the alleles, the quality, the track and caller settings, any gene, consequence, and amino-acid change, a genotype summary where the file carries [genotypes](../../GLOSSARY.md#genotype), and every `INFO` key on its own line. For a bcftools row the `INFO` lines include `AD`, the reads supporting the reference and the alternate. **Zoom to Variant** and **Copy Info** buttons sit at the bottom.

Once the table has keyboard focus, the up and down arrow keys move the selection and the Inspector follows. VoiceOver, the screen reader built into macOS, announces the focused cell and its column, and the column headers work as buttons for sorting without a mouse.

<!-- SHOT: variants-inspector-row -->

### Step 4. Filter with the preset chips

Click **Presets** in the toolbar above the table. A strip of chips unfolds, each one a saved filter rule this manual calls a [smart-filter token](../../GLOSSARY.md#smart-filter-token), grouped into four sections.

| Section | Chips |
|---|---|
| Biological Effect | `SNV`, `Indel`, `High Impact`, `Moderate+`, `ClinVar Path.` |
| Quality / QC | `PASS`, `Qual ≥ 30`, `DP ≥ 10` |
| Population / Frequency | `Rare (<1%)`, `Minor (≤20%)`, `Mixed (20-80%)`, `Dominant (≥80%)` |
| Sample / Genotype | `Bookmarked` |

A chip whose field the loaded tracks lack is shown dimmed and cannot be clicked, and its tooltip names what is missing. A section is left out only when none of its chips can be used. `High Impact` and `Moderate+` read an `IMPACT` field, an annotation program's own ranking of how severely a change is likely to affect the protein, written by programs such as SnpEff or VEP. `ClinVar Path.` reads a `CLNSIG` field from ClinVar, a public database of clinical judgements about variants. Neither caller here writes those fields, so those three chips stay dimmed. `Rare (<1%)` needs an `AF` key, which the LoFreq track supplies. `Bookmarked` keeps rows you flagged by hand and appears once you have bookmarked one.

The three within-sample frequency chips, `Minor`, `Mixed`, and `Dominant`, appear only when the tracks carry genotypes and LGE takes the organism to be haploid, meaning it carries one copy of each chromosome. Allele fraction is a clean filter only then. In a haploid virus, a fraction near one half means a mixture of two populations. In a diploid human it means a routine [heterozygous](../../GLOSSARY.md#heterozygous) call, one copy changed and one not, so the same threshold says nothing. The **Auto / Haploid / Diploid** control in the same toolbar settles the question, and its Settings entry explains why Auto guesses wrong on this fixture. Set it to Diploid here, which is the truthful answer for a human sample. The three chips then dim, with the tooltip "Only available for haploid organisms".

Click a chip to apply it and click it again to remove it. Chips from different sections combine, so `PASS` and `DP ≥ 10` together keep only rows satisfying both. Inside three sets, picking one chip clears the others in that set. `SNV` and `Indel` form one set, `High Impact` and `Moderate+` another, and the three frequency chips the third.

Now the lesson this fixture exists to teach. The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains. Click `PASS` while the bcftools rows are on screen and those rows vanish. Not one of the 1,040 bcftools rows says `PASS`, because bcftools as LGE runs it applies no filter of its own and writes `.` in that column. The chip is doing what it says, hiding every row whose filter value is anything but `PASS`, and on this track that is every row. The 862 LoFreq rows all say `PASS`, so the chip keeps all of them, and with both tracks loaded the table drops from 1,902 rows to 862. Read a bare `.` as unjudged rather than failed, and look at the column before you filter on it. Click **Clear** to bring the rows back.

<!-- SHOT: variants-preset-chips -->

A **Profiles** pull-down in the toolbar, shown when the window is wide enough, saves assembling the same chips again. It offers four built-in combinations, `Clinical`, `Research`, `QC`, and `High Confidence`, each hidden when the tracks lack a field its chips need. `Save Current as Profile...` stores your own on this Mac, keyed to the bundle, so a profile does not travel with a bundle you copy. `No Profile` clears the selection.

### Step 5. Filter with the Query Builder

For anything the chips cannot express, click **Query Builder...**, which reads **Edit Query...** once a filter is active, and **Query** or **Edit** in a narrow window. The Variant Query Builder sheet opens with one blank rule. Each rule picks a category, a field inside it, an operator, and a value, and the sheet writes the query text for you. Rules combine with **Match All**, meaning a row must satisfy every rule. Match All is the only logic the sheet offers, so there is no way to ask for either-or.

| Category | Fields it offers |
|---|---|
| Location | Region, Chromosome, and Gene List |
| Variant Identity | ID/Name and Type |
| Biological Effect | IMPACT, GENE, and CLNSIG |
| Population/Frequency | `AF`, the population-database keys `gnomAD_AF`, `ExAC_AF`, and `1000G_AF`, and any frequency-like `INFO` key the tracks carry |
| Call Quality | Quality, Filter, DP, MQ, and Sample Count |
| Sample/Genotype | A genotype, allele-frequency, and depth field for each sample the tracks declare |
| INFO Field | Every `INFO` key the tracks carry |

The population-database keys name public catalogues of how common a variant is across many people, and neither caller here writes them, so they find nothing on this fixture. The Sample/Genotype fields are named after your samples, so the sheet offers `HG002.GT`, `HG002.AF`, and `HG002.DP`. The dot marks a field belonging to one sample rather than to the whole variant.

The operators depend on the field. A Location rule takes only `=`, meaning "inside this range". A Filter rule takes only `=`. An INFO Field rule takes `=`, `~` (contains), `<`, `<=`, `>`, and `>=`. A genotype rule takes `=` and `!=`, and the per-sample `AF` and `DP` fields add the numeric comparisons.

A Region value must name the reference sequence as well as the range, in the form `chrom:start-end`. A bare range with no sequence name applies no restriction, and the table comes back unfiltered. Coordinates count from the start of the 500 kilobase slice, so the slice runs from 1 to 500001 even though its name carries 10.0 Mb.

Try a pair of rules. Set the scope control to **Genome** first, since the counts are for the whole slice. Set the first rule to Location, Region, `=`, `chr20_10.0-10.5Mb:1-250000`, which keeps the first half of the slice. Set the second to INFO Field, `DP`, `>=`, `30`. Click Apply. On the bcftools track that keeps 514 of the 558 rows in that window, so most calls in the first half rest on at least thirty reads.

The sheet also offers built-in query presets, including `High-Confidence Coding`, `Rare Pathogenic`, `Quality Review`, `PASS + High Quality`, `Rare Variants`, and `Indels Only`. A preset whose rules name a missing annotation or `INFO` field is hidden. `Save Preset...` stores a query of your own in the same list.

A very large variant database, the file LGE builds from each track so the table can filter quickly, limits the Query Builder. From 1 GB it is disabled until you zoom the viewport in below 10 Mb, as its tooltip says. From 25 GB it stays disabled and the Presets button is hidden. This fixture is far below either size.

<!-- SHOT: variants-search-builder -->

### Step 6. Read the two callers against each other

LGE has no side-by-side comparison view and no intersection button. It gives you one table holding both call sets with a `Variant Track` column, which is enough to compare them by eye.

Sort by `Position` ascending. Where both callers reported a coordinate, two rows land on adjacent lines with different `Variant Track` values. Rows only one caller reported sit alone. Read the `Variant Track` text rather than the viewport. The ticks the viewport draws on a variant track encode the genotype and the variant type, never the source file, so they cannot separate two callers.

<!-- SHOT: variants-source-column -->

Coordinate 2078 shows a shared call. Use **Sequence > Go to Location...** (Cmd-L), type `chr20_10.0-10.5Mb:2078`, and click Go, with the scope control on **Region** so the table trims to what is on screen. Both callers report a reference `G` read as `A`. The bcftools row carries the genotype `1/1`, meaning both copies carry the change, with [allele depths](../../GLOSSARY.md#allele-depth) of 0 reference reads and 52 alternate reads, which the Inspector lists as `AD=0,52`. The LoFreq row carries no genotype and reports `AF` 1 instead. Every read carries the `A`, so this person has the change on both copies of chromosome 20, a [homozygous](../../GLOSSARY.md#homozygous) position, and the two callers agree in different notations.

Coordinate 250527 shows the other common kind of call. LoFreq reports a reference `C` read as `T` with `AF` 0.571 at a depth of 63, so a little over half the reads carry the change. That is what a heterozygous position in a human sample looks like. The bcftools row there carries the genotype `0/1`, one copy changed and one not, with allele depths of 20 reference reads and 33 alternate reads. Again the two callers agree, one as a fraction and one as a genotype.

Where the callers disagree, the cause is mundane. Of the 1,040 bcftools rows, 181 are [indels](../../GLOSSARY.md#indel), and LoFreq called none, because LoFreq skips indels unless asked. That accounts for 180 of the 187 positions only bcftools reported. None of the 10 positions only LoFreq reported appears in the benchmark. The Call Variants dialog's Extra arguments field shows `--call-indels` as its placeholder, which is the flag LoFreq wants. Before concluding that one caller is wrong, check whether a difference in what each caller was looking for explains the gap.

## Settings

Seven controls sit in the drawer toolbar on the Variants tab, and the column-header menu adds quick filters of its own. None of them passes through to the command line unchanged. The Query Builder comes closest, but the command line's `--filter` flag takes per-sample clauses only, as the last section sets out.

**Calls / Genotypes.** Switches the table between one row per variant and one row per sample genotype at each variant. The default is Calls, which suits a track holding a single sample, as both fixture tracks do. Switch to Genotypes when a VCF holds several samples and you want their calls side by side, and note that at narrow widths the second label shortens to GT. This setting has no command-line flag.

**Region / Genome.** Decides whether the table lists only variants inside the stretch the viewport shows or queries the whole reference. The default is Region, which keeps the table in step with what you are looking at and each query small. Switch to Genome when counting or filtering across the whole reference, which every count in this chapter assumes. This setting has no command-line flag.

**Presets.** Opens the strip of one-click filter chips described in step 4. The default is no chip applied and the strip collapsed, so the table starts with every row of every loaded track. Use it whenever a common filter is all you need, and expect the button to hide when the window is too narrow or the tracks declare no `INFO` keys. This setting has no command-line flag.

**Profiles.** Applies a saved combination of chips, either one of the built-in `Clinical`, `Research`, `QC`, and `High Confidence` profiles or one you saved with `Save Current as Profile...`. The default is `No Profile`, so no combination is applied. Use it when you apply the same chips often, and remember that a saved profile stays on this Mac. This setting has no command-line flag.

**Query Builder....** Opens the Variant Query Builder sheet, the fullest way to compose a filter by hand on this tab. It opens with one blank rule, and every rule must hold, the only logic the query engine supports. Use it when a chip is not specific enough, such as a coordinate window or one sample's genotype, and expect it to be disabled on a very large variant database. Its query text is not in general accepted by the command line's `--filter` flag, so treat the two as separate grammars.

**Auto / Haploid / Diploid.** Tells the three within-sample frequency chips how to read allele fractions, since a fraction means something different with one genome copy than with two. The default is Auto, which reads a [ploidy](../../GLOSSARY.md#ploidy) note from the bundle's metadata when there is one and otherwise treats any reference under 10 megabases as haploid, because viral and bacterial genomes are small. That guess suits a whole viral genome and is wrong for a slice of a human chromosome, this fixture's 500 kilobases included, so choose Diploid when reading part of a large genome and Haploid in the opposite case. This setting has no command-line flag.

**Clear.** Drops every active filter at once, the chips and anything the Query Builder wrote, and returns the full table. It is hidden until a filter is active, so its presence is itself the sign that something is filtered. Reach for it first whenever a table looks emptier than it should. This setting has no command-line flag.

## Reading the results

Set the scope control to **Genome** and read the table with no filter applied. It holds 1,902 rows, the 1,040 bcftools rows plus the 862 LoFreq rows. The tracks are stacked rather than merged, so a coordinate both callers reported contributes two rows.

Take the `Filter` column first, because it decides whether later filters behave as you expect. Sort by it and the table splits in two. Every bcftools row reads `.` and every LoFreq row reads `PASS`. That is a difference in what each caller writes, not in quality. bcftools leaves the judgement to you, and LoFreq applies its filters while calling and writes only the survivors.

Take `Quality` next. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand, and a caller's `Quality` uses the same scale for the whole call. The two callers put their scores on scales that cannot be compared with each other, so read each track on its own. The bcftools rows run from 3.2 to 228.4, the commonest score is 225.4, and 12 of the 1,040 fall below 30. The LoFreq rows run from 73 to 2,478 and none fall below 30. The `Qual ≥ 30` chip applies the same threshold to both tracks, which is useful for finding a track's weakest rows and misleading for ranking one caller against the other. A healthy call set has most rows far above the threshold and a short tail near the bottom. A table that is mostly low scores says the alignment or the depth is the problem.

Take depth third. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Every bcftools row sits at a depth of 10 or more, because the Call Variants dialog's Minimum Depth of 10 removed shallower rows before the track was written. The bcftools rows average about 43 reads. Depth matters because an allele fraction means different things at different depths. Half the reads at a depth of 4 is two reads of evidence. Half the reads at a depth of 63 is more than thirty.

Take [allele frequency](../../GLOSSARY.md#allele-frequency) last, which is where the tracks differ most in shape. Sort the LoFreq rows by the `AF` column and they split into 339 at or above 0.8, 517 between 0.2 and 0.8, and 6 below 0.2. That two-humped shape is what a diploid human sample should produce, with a heterozygous group near one half and a homozygous group near one. The bcftools track has no `AF` key, but its genotypes show the same two groups, 617 heterozygous `0/1` rows and 405 homozygous `1/1` rows, plus 18 `1/2` rows where the two copies carry different changes.

The `Type` column adds the last piece. Of the 1,040 bcftools rows, 859 are substitutions and 181 are insertions or deletions. All 862 LoFreq rows are substitutions. The `Indel` chip therefore hides every LoFreq row and keeps 181 bcftools rows, another case where an empty result describes the file rather than the filter.

## What good looks like

Five checks are worth making on any variants table before you build on it.

First, read the row count against the region and the caller. LoFreq's 862 rows across 500 kilobases is about one difference every 580 bases, close to the one in a thousand that separates any two people, and 808 of its 861 positions, 862 rows because one position has two alternates, match the fixture's benchmark, the curated answer key of true HG002 variants [Importing Existing VCFs](06-importing-existing-vcfs.md) loads. The bcftools track holds more rows, mostly because it also calls indels. A count in single digits would mean the alignment failed or the reference is wrong. Tens of thousands would mean sequencing error is being reported as signal.

Second, look at the `Filter` column itself before you filter on it. An empty table after a chip click means either that no row passed or that no row was ever judged, and only the column tells you which.

Third, check that quality and depth have the shape described above, most rows well clear of the thresholds and a short tail near the bottom. Sort by `Quality` ascending and read the first twenty rows. If the whole table looks like that tail, go back to the alignment.

Fourth, when two tracks are loaded, look for a mundane explanation of their disagreement before an interesting one. Here LoFreq's indel default explains nearly all of bcftools' extra positions. A disagreement no difference in caller behaviour explains is worth investigating.

Fifth, know where each row came from. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. The `Variant Track` column is not a link, so select the track in the project sidebar to read its record.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The table cannot write a VCF. When a downstream tool needs your filtered rows as a file, `lungfish-cli variants query` reads the bundle's variant database, applies a filter expression, and writes the matching rows to a new VCF with a provenance record beside it. It reads only the first variant track in the bundle that has a database, first meaning the earliest one added, and there is no flag to pick another track. On the bundle Calling Variants builds, that is the bcftools track.

Its filter grammar is not the Query Builder's. The `--filter` flag accepts per-sample clauses of the form `Sample[<name>].<field>`, where the name is the one the **Samples** tab lists, `HG002` here, and the field is `GT`, `AF`, or `DP`. `AF` is worked out from the allele depths rather than read from an `AF` tag. Query Builder clauses such as `filter=PASS`, and comparisons against `INFO` keys such as `DP>=10`, are rejected with "Unsupported smart-filter clause".

The first line below stores the bundle's path in a shortcut name. Replace the path with your own, keeping the double quotes, which stop the space in `Reference Sequences` from splitting it.

```bash
BUNDLE="MyProject.lungfish/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref"

# Heterozygous calls in the first track. 617 rows here.
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002].GT=0/1' \
    --output heterozygous.vcf

# Calls where at least half the reads carry the alternate. 755 rows here.
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002].AF>=0.5' \
    --output majority.vcf

# Count what came out
bcftools view -H majority.vcf | wc -l
```

A haploid clause such as `Sample[HG002].GT=1` returns no rows on this bundle, because the track it reads holds diploid genotypes. `--limit` caps the export and defaults to 5000 rows, so raise it for a larger track.

## Next

Continue to [Nanopore Variant Calling](04-nanopore-variant-calling.md) for the callers built for long reads, or to [Extracting a Consensus Sequence](05-consensus-and-lineage.md) to turn an alignment into a sequence.
