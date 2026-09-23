---
title: Reading the Variants Table
chapter_id: 05-variants/02-reading-the-variant-browser
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 30
task: Read, sort, and filter the Variants tab of the table drawer, compare two callers in one table, and write a filtered subset to a VCF from the command line.
tags: [variants, table-drawer, filter, presets, search-builder, source-column, inspector]
tools: [bcftools]
parameters_refs: [variants.filter-table, variants.query]
entry_points:
  - "Open a reference bundle, then the table drawer's Variants tab"
  - "CLI: lungfish-cli variants query"
shots:
  - id: variants-tab-twelve-columns
    caption: "The Variants tab of the table drawer inside the reference bundle viewport, with the twelve fixed columns from ID through AA Change and both caller tracks loaded."
  - id: variants-preset-chips
    caption: "The Presets chip strip open above the Variants table, showing the first three groups, Biological Effect, Quality / QC, and Population / Frequency."
  - id: variants-search-builder
    caption: "The Variant Query Builder sheet with two rules, one on Call Quality and one on an INFO field, combined with Match All."
  - id: variants-inspector-row
    caption: "The Inspector filled with one selected variant row, showing its identity, quality, genotype summary, and every INFO key on its own line."
  - id: variants-source-column
    caption: "The Source column separating the bcftools rows from the LoFreq rows at one shared coordinate in the aggregated table."
illustrations: []
glossary_refs: [allele-depth, allele-frequency, bcftools, consequence, depth, filter, format, genotype, heterozygous, homozygous, indel, info, ivar, lofreq, mapping, operations-panel, phred-score, plugin-pack, provenance, ref-alt, reference-bundle, smart-filter-token, table-drawer, variant-caller, variant-track, vcf]
features_refs: [viewport.variant-browser]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

A [variant caller](../../GLOSSARY.md#variant-caller) is a program that compares aligned reads against the reference and lists every place they disagree. It writes its answer to a [VCF](../../GLOSSARY.md#vcf) file, a long text file whose fields are separated by tab characters rather than commas, with one row per position where the reads disagreed. Lungfish Genome Explorer (LGE) stores that file inside the [reference bundle](../../GLOSSARY.md#reference-bundle) as a named [variant track](../../GLOSSARY.md#variant-track), and it shows you the rows in a table. This chapter is about that table. You never open the VCF file by hand in LGE, and nothing in this chapter asks you to.

The table is not a window of its own. It lives in the [table drawer](../../GLOSSARY.md#table-drawer), a panel that slides out from the bottom edge of the reference bundle viewport, on a tab labelled **Variants**. The drawer opens by itself the moment you load a bundle that carries at least one variant track, so there is nothing to click to summon it and no per-track node in the project sidebar to hunt for. It opens tall enough to show something like eight rows at once, which is under a third of a full-height window, you can drag its top edge to resize it, and LGE remembers the height you chose the next time you open a bundle. Two other tabs sit in the same drawer. **Annotations** lists gene features such as exons and coding regions, and **Samples** lists the sample columns the loaded VCF files declare.

Above the table sits a row of controls that decide what the table shows. A two-segment control labelled **Calls** and **Genotypes** switches between one row per variant and one row per sample. A second two-segment control labelled **Region** and **Genome** decides whether the table lists only the stretch of genome the viewport is currently showing or queries the whole reference. A **Presets** button opens a strip of one-click filter chips. A **Search Builder...** button opens a sheet that composes a structured query rule by rule. A **Clear** button drops every filter at once. There is no free-text box to type a query into, and looking for one is the single most common way to get stuck here. The Search Builder in step 5 is what replaces it.

Everything the table does is display. Sorting, filtering, hiding a column, and hiding a sample all change what you see and never touch the VCF on disk. Writing a filtered subset back out as a new file is a separate operation, and on this surface it belongs to the command line. Treat the table as a lens for finding the handful of rows that matter out of the hundreds the caller produced, and reach for `lungfish-cli variants query`, a command you type in the Terminal application and which the last section of this chapter covers in full, only when a downstream tool needs those rows as a file of their own.

## Why you would do this

The worked example is human. HG002 is a consenting research participant whose DNA is distributed as a cell line, so laboratories everywhere sequence the same genome and an independent truth set already lists the variants that genome really carries. The HG002 chromosome 20 slice holds Illumina reads from that cell line, Illumina being the sequencing instrument brand that produced them, [mapped](../../GLOSSARY.md#mapping) to a 500 kilobase stretch of chromosome 20, which means each read was placed at the position on the reference it matches best. The previous chapter called variants on that alignment twice, once with [bcftools](../../GLOSSARY.md#bcftools) and once with [LoFreq](../../GLOSSARY.md#lofreq). The two callers differ in what they set out to do. bcftools works out a diploid genotype for each position and reports it, while LoFreq estimates what fraction of the reads carry the change and reports that instead, which is step 6's whole subject. Those two runs produced 1,056 rows and 862 rows respectively, and in the default Calls view one row is one variant in one track. Nobody reads sixteen hundred rows one at a time.

Filtering is how a call set becomes an answer. A geneticist asking which changes in this half-megabase might affect a protein does not want every row, only the ones with a predicted protein [consequence](../../GLOSSARY.md#consequence). Someone checking whether the sequencing run was deep enough wants the rows with the thinnest coverage, which are the ones the table's own quality columns will surface. Someone comparing two callers wants to see, at a shared coordinate, what each one said. Each of those is a different filter over the same table, and the point of learning the controls is that you stop scrolling and start asking.

There is a second reason, less obvious and more useful in the long run. Two callers reading the same alignment disagree, and the way they disagree tells you something about your data that neither file tells you alone. On this fixture the two call sets share 852 positions, bcftools reports 201 that LoFreq does not, and LoFreq reports 9 that bcftools does not. Those figures count distinct coordinates rather than rows, and each track keeps its own row even where both callers reported the same coordinate, which is why the shared 852 does not subtract from either row total. Reading the two tracks together in one table is the cheapest calibration you will ever run.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. Any folder you can write to works, and the project's name and location make no difference to anything in this chapter.

This chapter uses a practice data set, which this manual calls a fixture, named the HG002 chromosome 20 slice. Download the files `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. On that page, click a filename and then the Download raw file button, since the page itself only previews the file. No GitHub account is needed to download them.

What this chapter needs in the project is not those raw files but the two variant tracks they lead to. Work through the whole of [Calling Variants](01-calling-variants-from-amplicons.md) first, since none of the six steps below can be done without it. It imports the reference, maps the reads, and calls variants twice on the resulting alignment, which leaves a reference bundle carrying a bcftools track and a LoFreq track. Both are needed here, because half of what this chapter teaches is only visible when two tracks sit in one table.

Nothing needs installing for this chapter. The table reads files that already exist inside the bundle, so it needs no [plugin pack](../../GLOSSARY.md#plugin-pack), which is LGE's name for a downloadable set of third-party analysis programs. The one third-party program the optional command-line section uses is bcftools, which LGE installs with its Required Setup pack the first time you run it, so there is nothing to fetch by hand.

## Procedure

The procedure has six steps. The first two open the table and orient you in its columns. The next three cover selecting a row, filtering with chips, and filtering with the Search Builder. The last reads the two callers against each other.

### Step 1. Open the Variants tab

Click the reference bundle in the project sidebar. The viewport fills with the bundle, and the table drawer opens along the bottom by itself, because this bundle carries variant tracks. Click the drawer's **Variants** tab.

Both tracks load into the one table at once. You do not open a second track by hand, and there is no way to open only one. Every row from both files is there from the start, and the **Source** column names the file each row came from. If the drawer does not open at all, or its Variants tab is empty, the variant calling from the previous chapter has not finished. Check the [Operations panel](../../GLOSSARY.md#operations-panel), the running log of every job LGE has started, with **Operations > Show Operations Panel** (Cmd-Shift-P). A job still running holds a moving progress bar and a status line naming the step it is on, while a finished one holds a completion message and no bar. Wait for the run to report "Variant calling complete".

Drag the top edge of the drawer upward if the table feels cramped. LGE stores the height you set and reuses it.

<!-- SHOT: variants-tab-twelve-columns -->

### Step 2. Read the columns

Twelve fixed columns run across the table, always in this order. Seven of them are the VCF's own standard columns, listed below as "from the VCF". `Type` and `Samples` are worked out from each record rather than read from it. `Source`, `Consequence`, and `AA Change` are added by LGE and appear in no VCF file.

| Column | Where it comes from | What it holds |
|---|---|---|
| `ID` | From the VCF | The `ID` field, a bare `.` when the caller assigned no name |
| `Type` | Worked out | Whether the row is a substitution or an insertion or deletion |
| `Chrom` | From the VCF | The reference sequence name, `chr20_10.0-10.5Mb` on this fixture |
| `Position` | From the VCF | The 1-based coordinate of the change on that sequence |
| `Ref` | From the VCF | The [reference allele](../../GLOSSARY.md#ref-alt), the base or bases already in the reference |
| `Alt` | From the VCF | The alternate allele, the base or bases the reads carried instead |
| `Quality` | From the VCF | The caller's confidence as a [Phred score](../../GLOSSARY.md#phred-score) |
| `Filter` | From the VCF | The caller's own pass or fail label for the row |
| `Samples` | Worked out | How many sample columns hold a call at that position |
| `Source` | Added by LGE | Which variant track the row came from |
| `Consequence` | Added by LGE | A predicted protein effect such as `missense_variant`, where an annotation supplies one |
| `AA Change` | Added by LGE | The amino-acid substitution, in the same case |

`Type` is worked out by a rule worth stating once, because the same file can be counted more than one way. LGE reads only the first alternate allele on a row and gives the whole row that one type, so a row offering two alternates is counted once rather than twice. Every substitution and indel count in this chapter follows that rule.

Two columns behave differently than their names suggest, and both catch people out. `Quality` is a real number for both callers on this fixture. It is blank on a track called with [iVar](../../GLOSSARY.md#ivar), a variant caller built for amplicon data that this fixture does not use, because LGE's iVar output writes a bare `.` in that field for every row, so sorting by it on such a track tells you nothing. `Filter` is where the fixture teaches its sharpest lesson, covered in step 4.

Beyond the twelve, the table adds a column for each `INFO` key the loaded track carries. `INFO` keys are the extra per-variant measurements a caller records alongside the call, such as depth. Three come to the front when a file carries them, allele frequency first, then gene, then impact, and every other key follows in the order it was found. Only two `INFO` keys matter in this chapter. `DP` is depth, the number of reads covering the position, and `AF` is allele frequency, the fraction of those reads carrying the change. The other names you will see on this fixture stand for mapping quality (`MQ`), alternate allele count (`AC`), the four-way split of reads by allele and strand (`DP4`), and a strand-bias score (`SB`), and none of them is needed here. The two tracks do not contribute the same columns, because each caller records its own set. The bcftools track carries sixteen `INFO` keys and the LoFreq track carries seven, and only some of the names overlap.

Every column sorts. Click a header once and the table sorts ascending, click again for descending. Drag a header sideways to reorder the columns, and right-click the header bar to hide the ones you are not using. LGE stores your column widths, ordering, and visibility per tab and restores them the next time you open the drawer.

### Step 3. Select a row and read the Inspector

Click any row in the table. The Inspector on the right fills with that one variant, one field to a line, which is far easier to read than the packed `INFO` string a VCF stores. That string arrives as one run of key-and-value pairs joined by semicolons, in the shape `DP=63;VDB=0.62;MQ=60`, and the Inspector breaks it apart for you. It shows the identifier and type, the position, the alleles, the quality, a genotype summary where the file carries [genotypes](../../GLOSSARY.md#genotype), and every [`INFO`](../../GLOSSARY.md#info) key on its own line. It does not repeat the `Consequence` or `AA Change` values, which live in the table's own columns, and it does not print the per-sample [`FORMAT`](../../GLOSSARY.md#format) payload.

Once the table has keyboard focus, the up and down arrow keys move the selection from row to row and the Inspector follows. The table is a standard macOS table, so VoiceOver, the screen reader built into macOS, announces the focused cell and its column, and the column headers are reachable as buttons you can activate to sort without a mouse.

<!-- SHOT: variants-inspector-row -->

### Step 4. Filter with the preset chips

Click **Presets** in the toolbar above the table. A strip of fourteen chips unfolds, each one a [smart-filter token](../../GLOSSARY.md#smart-filter-token), grouped into four named sections. **Biological Effect** holds `SNV`, `Indel`, `High Impact`, `Moderate+`, and `ClinVar Path.`. **Quality / QC** holds `PASS`, `Qual ≥ 30`, and `DP ≥ 10`. **Population / Frequency** holds `Rare (<1%)`, `Minor (≤20%)`, `Mixed (20-80%)`, and `Dominant (≥80%)`. **Sample / Genotype** holds `Het Only` and `Bookmarked`. `Moderate+` and `High Impact` refer to an impact level, an annotation program's own ranking of how severely a change is likely to affect the protein, and `ClinVar Path.` refers to ClinVar, a public database of variants that clinical laboratories have judged to cause disease or not.

You will not see all fourteen. A chip appears only when the loaded track carries the field it reads, and its tooltip says which field is missing when it does not. The impact chips need an `IMPACT` field written by an annotation program such as SnpEff or VEP. This fixture needs neither program, and neither caller here writes that field, so both chips stay hidden. `ClinVar Path.` needs a `CLNSIG` field. The three frequency chips appear only when LGE takes the organism to be haploid and the track carries genotypes, because allele fraction is a clean filter only when there is one genome copy. In an organism with one copy, a fraction near one half means a mixture of two populations, which is worth filtering on. In a diploid organism it means a routine [heterozygous](../../GLOSSARY.md#heterozygous) call instead, so the same threshold would say nothing. The Auto / Haploid / Diploid pull-down in the same toolbar is what settles that question, and its Settings entry below explains why a small slice of a human chromosome is not the case its automatic guess handles well. Set that control to Diploid on this fixture, which is the truthful answer for a human sample and which takes the three frequency chips out of the strip, since they would tell you nothing about a diploid genome anyway. `Het Only` is unavailable on every track today, which is a known gap rather than a fault in your data, and its tooltip says as much. `Bookmarked` keeps the rows you flagged by hand, which is a feature covered elsewhere in this manual rather than in this chapter.

Click a chip to apply it and click it again to remove it. Chips from different sections combine, so `PASS` and `DP ≥ 10` together keep only the rows satisfying both. Three sets behave differently, since picking one chip inside such a set clears the others in that same set. `SNV` and `Indel` are one such set, `High Impact` and `Moderate+` are another, and the three frequency chips are the third.

Now the lesson this fixture exists to teach. Read a bare `.` in the [`FILTER`](../../GLOSSARY.md#filter) column as unjudged rather than as failed, and look at the column before you filter on it. Click `PASS` while the bcftools rows are on screen and the table empties. Not one of the 1,056 bcftools rows says `PASS`, because a default bcftools run applies no filter of its own and writes a bare `.` in that column instead. The chip is doing exactly what it says. It hides every row whose filter value is anything but `PASS`, and on this track that is all of them. The 862 LoFreq rows all say `PASS`, so the same chip changes nothing on those. Use **Clear** to bring the rows back.

<!-- SHOT: variants-preset-chips -->

A **Profiles** pull-down beside the chips saves you assembling the same chips repeatedly. It offers four built-in combinations, `Clinical`, `Research`, `QC`, and `High Confidence`, each hidden when the track lacks a field its chips need, and a `Save Current as Profile...` item that stores your own on this Mac, keyed to the bundle you saved it from. A profile therefore does not travel with a bundle you copy or share. `No Profile` at the top clears the selection.

### Step 5. Filter with the Search Builder

For anything the chips cannot express, click **Search Builder...**. The Variant Query Builder sheet opens with one blank rule. Each rule picks a category, then a field inside that category, then an operator, then a value, and the sheet writes the query text for you. Add as many rules as you need. They combine with **Match All**, meaning a row must satisfy every rule, and Match All is the only choice the sheet offers, so there is no way to ask for either-or.

Seven categories organise the fields.

| Category | Fields it offers |
|---|---|
| Location | Region, Chromosome, and Gene List |
| Variant Identity | ID/Name and Type |
| Biological Effect | IMPACT, GENE, and CLNSIG |
| Population/Frequency | `AF`, plus the three population-database keys `gnomAD_AF`, `ExAC_AF`, and `1000G_AF`, plus any frequency-like `INFO` key the loaded track carries |
| Call Quality | Quality, Filter, DP, MQ, and Sample Count |
| Sample/Genotype | A genotype, allele-frequency, and depth field for each sample the tracks declare |
| INFO Field | Every `INFO` key the loaded track carries |

Two of those rows need a word. The three population-database keys name public catalogues of how common a variant is across many people, and neither caller on this fixture writes any of them, so those fields find nothing here. The Sample/Genotype fields are named after your own samples, so on this fixture the sheet offers `HG002.GT`, `HG002.AF`, and `HG002.DP` rather than a generic label. The dot in those names marks a field belonging to one named sample rather than to the variant as a whole, and the sample name is the one the **Samples** tab of the same drawer lists.

Which operators a rule offers depends on its field. A Location rule takes only `=`, which here means "inside this range" rather than "exactly equal to", because a coordinate rule takes a range rather than a comparison. A Filter rule takes only `=`. Numeric fields take `<`, `<=`, `>`, `>=`, and `=`. A genotype rule takes `=` and `!=`, and the other per-sample fields add the numeric comparisons.

A Region value has to name the reference sequence as well as the range, in the form `chrom:start-end`. A bare range with no sequence name is silently ignored, so the rule applies no restriction at all and the table you get back is the unfiltered one. Coordinates are counted from the start of the 500 kilobase slice rather than from the start of the real chromosome 20, so the slice runs from 1 to 500000 even though its name carries the figure 10.0 Mb.

A worked pair of rules for this fixture. First set the scope control above the table to **Genome**, since the counts below are for the whole slice rather than for whatever the viewport happens to be showing. Set the first rule to Location, then Region, then `=`, then `chr20_10.0-10.5Mb:1-250000`, which keeps the first half of the slice. Set the second to INFO Field, then `DP`, then `>=`, then `30`. Click Apply. On the bcftools track that leaves 512 rows out of the 574 in that window, so most calls in the first half of the slice rest on at least thirty reads.

The sheet ships built-in query presets you can load instead of building rules, including `High-Confidence Coding`, `Rare Pathogenic`, `Quality Review`, `PASS + High Quality`, `Rare Variants`, and `Indels Only`. A preset whose rules name a field the track does not carry is hidden rather than offered and failing. `Save Preset...` stores a query of your own under the same list.

One limit is worth knowing before you meet it. On a very large variant database the Search Builder button is disabled, because the query would take too long to be useful, and its tooltip names the database size and tells you to zoom the viewport in below 10 Mb to enable it again. [Reading an Alignment](../04-alignments/02-reading-an-alignment.md) covers the zoom commands. The chips keep working in that case. The fixture is nowhere near that size, so you will not hit it here.

<!-- SHOT: variants-search-builder -->

### Step 6. Read the two callers against each other

LGE has no side-by-side caller comparison view, no intersection button, and no union export. What it gives you is one table holding both call sets with a `Source` column naming which file each row came from, and that is enough to do the comparison by eye.

Sort by `Position` ascending. Rows that both callers reported land at the same coordinate on adjacent lines with different `Source` values. Rows that only one caller reported sit alone. Read the `Source` text and nothing else. Above the drawer, the viewport draws a variant track, a thin horizontal band carrying one tick mark for every call at its coordinate along the reference. Those tick colors encode the genotype call and the variant type, never the source file, so they cannot separate two callers and trying to read them that way will mislead you.

Coordinate 250527 shows the shape of a shared call. To reach it, sort by `Position` and scroll, or use **Sequence > Go to Location...** (Cmd-L) to move the viewport there with the scope control set to **Region**, which trims the table to what is on screen. Both callers report a reference `C` read as a `T` at a [depth](../../GLOSSARY.md#depth) of 63. The bcftools row carries the [genotype](../../GLOSSARY.md#genotype) `0/1`, meaning one of this person's two copies of chromosome 20 carries the change, with [allele depths](../../GLOSSARY.md#allele-depth) of 20 reference reads and 33 alternate reads. Those two counts come to 53 rather than 63, and the gap is not an error. The `DP` depth counts every read covering the position, while the allele depths count only the reads the caller judged good enough to assign to one allele or the other, so the ten it set aside are in the first figure and not the second. The LoFreq row carries no genotype at all and reports `AF=0.571429` in its own `AF` column instead, which is the fraction of the reads LoFreq counted that carried the `T`. Those two rows say the same thing in different languages, that a little over half the reads carry the change, which is what a [heterozygous](../../GLOSSARY.md#heterozygous) position in a human sample looks like. Neither shape is wrong, and a downstream tool expecting genotypes will find nothing in the LoFreq rows.

<!-- SHOT: variants-source-column -->

When the two callers disagree, the disagreement usually has a mundane cause. On this fixture bcftools reports 201 positions LoFreq does not, and 182 of the 1,056 bcftools rows are [indels](../../GLOSSARY.md#indel) while LoFreq called none at all, because LoFreq skips indels unless you ask for them. Asking is possible inside LGE. The Call Variants dialog carries an Extra arguments field whose own placeholder text is `--call-indels`, which is the flag LoFreq wants. That one default accounts for most of the gap. Before concluding that one caller is wrong, check whether a difference in what each caller was even looking for explains it.

## Settings

Six controls sit in the drawer toolbar on the Variants tab. None of them reaches the command line. The Search Builder comes closest, but the query text it writes is not in general accepted by the `--filter` flag, which takes per-sample clauses only, and the command-line section at the end of this chapter sets out what that flag does take.

**Calls / Genotypes.** Switches the table between one row per variant and one row per sample genotype at each variant, so the second view shows what each sample was called rather than folding every sample into one row. The default is Calls, which is the right view whenever the track holds a single sample as both fixture tracks do. Switch to Genotypes when a VCF holds several samples and you want to compare their calls side by side, and note that at narrow window widths the second segment shortens its label to GT, which is the standard abbreviation for genotype. This setting has no command-line flag.

**Region / Genome.** Decides whether the table lists only the variants inside the stretch of reference the viewport is currently showing or queries the whole reference regardless of where you have scrolled. The default is Region, which keeps the table in step with what you are looking at and keeps each query small. Switch to Genome when you are counting or filtering across the whole reference rather than reading one locus, which is what you want for every row count quoted in this chapter. This setting has no command-line flag.

**Presets.** Opens a strip of one-click filter chips grouped into four sections, `Biological Effect` holding SNV, Indel, High Impact, Moderate+, and ClinVar Path., `Quality / QC` holding PASS, Qual ≥ 30, and DP ≥ 10, `Population / Frequency` holding Rare (<1%), Minor (≤20%), Mixed (20-80%), and Dominant (≥80%), and `Sample / Genotype` holding Het Only and Bookmarked. The default is no chip applied and the strip collapsed, so the table starts showing every row in every loaded track. Use it whenever a common filter is all you need, and remember that the button hides itself when the window is too narrow to hold it or the loaded track declares no `INFO` keys for the chips to read. This setting has no command-line flag.

**Search Builder....** Opens the Variant Query Builder sheet, which is the only way to compose a filter by hand, since the free-text filter field is permanently hidden on this tab. The sheet opens with one blank rule and Match All logic, which is the only logic it offers because the query engine has no OR. Use it when a chip is not specific enough, for example to keep a coordinate window or to test one sample's genotype, and expect the button to be disabled with an explanatory tooltip on a very large variant database. The query text it writes is not in general accepted by the command line's `--filter` flag, which takes per-sample clauses only, so treat the sheet and the flag as two separate grammars.

**Auto / Haploid / Diploid.** Tells the three within-sample frequency chips how to read allele fractions, since the same fraction means something different in an organism carrying one genome copy than in one carrying two. The default is Auto, which reads a ploidy note from the bundle's own metadata when one is there and otherwise guesses from the total length of the reference, treating anything under 10 megabases as haploid on the reasoning that viral and bacterial genomes are small and eukaryotic ones are not. That guess is right for a whole viral or bacterial genome and wrong for a short slice of a human chromosome, this fixture's 500 kilobases included, so force Diploid whenever you are reading part of a large genome rather than all of a small one, and force Haploid in the opposite case. This setting has no command-line flag.

**Clear.** Drops every active variant filter at once, both the chips you clicked and anything the Search Builder wrote, and returns the table to every row in every loaded track. It is hidden until a filter is active, so its presence in the toolbar is itself the signal that something is filtered. Use it whenever you want the full table back, and reach for it first whenever a table looks emptier than it should. This setting has no command-line flag.

## Reading the results

Set the scope control to **Genome** so the counts below match, then read the table with no filter applied. It holds 1,918 rows, which is the 1,056 bcftools rows plus the 862 LoFreq rows, and the `Source` column is what separates them. The two tracks are stacked rather than merged, so a coordinate both callers reported contributes two rows to that total, one from each track.

Take the `Filter` column first, because it decides whether every later filter behaves the way you expect. Sort by it and the table splits cleanly in two. Every bcftools row reads `.` and every LoFreq row reads `PASS`. That is not a quality difference between the callers. It is a difference in what each one writes. bcftools applies no filter of its own by default and leaves the judgement to you, and LoFreq applies its filters while calling and emits only the survivors. A track of all `PASS` and a track of all `.` need different handling, and only one of them has been judged by anything.

Take `Quality` next. It is a [Phred score](../../GLOSSARY.md#phred-score), which measures the caller's confidence on a logarithmic scale. A score of 10 means the caller expects to be wrong about one time in ten, 20 means one time in a hundred, and 30 means one time in a thousand, so every ten points divides the expected error rate by ten again. The two callers put their scores on scales that cannot be compared, so read each track's distribution on its own rather than holding one number against both. The `Qual ≥ 30` chip does apply the same threshold to both tracks, which is useful for spotting a track's own weakest rows and misleading if you use it to rank one caller against the other. The bcftools rows run from 4.5 to 228.4 and only 24 of the 1,056 fall below 30. The LoFreq rows run from 73 to 2,478 and none fall below 30. In both cases most rows are far above the threshold with a short tail near the bottom, which is what a healthy call set looks like. Twenty-four low rows out of a thousand is a normal tail rather than something to act on, so read them alongside their depth before you decide whether any of them matters. A distribution that is mostly low scores says the alignment or the depth is the real problem, not the caller.

Take depth third, using the `DP` column both callers contribute. Depth is the number of reads covering a position, and it gates how much you should trust everything else about the row. The alignment viewport's coverage strip reports a mean of 44.7 reads across the visible window on this fixture, and 1,049 of the 1,056 bcftools rows sit at a depth of 10 reads or more. That is comfortable for human work, where a whole-genome run is normally aimed at about 30 reads deep. The reason depth matters so much is that a given allele fraction means wildly different things at different depths. Half the reads at a depth of 4 is two reads of evidence. Half the reads at a depth of 63, which is what coordinate 250527 shows, is thirty-three reads of evidence and a genotype you can act on.

Take [allele frequency](../../GLOSSARY.md#allele-frequency) last, which is where the two tracks differ most in shape. The LoFreq rows carry an `AF` key directly, so its values sit in the table's own `AF` column and you can read these three groups by sorting that column rather than by clicking any chip. Reading it splits the 862 rows into 339 at or above 0.8, 517 between 0.2 and 0.8, and 6 below 0.2. That two-humped shape is exactly what a diploid human sample should produce, with the middle group being [heterozygous](../../GLOSSARY.md#heterozygous) positions near one half and the upper group being [homozygous](../../GLOSSARY.md#homozygous) alternate positions near one. The bcftools rows carry no `AF` key at all and answer the same question with a genotype instead, 623 rows reading `0/1`, 415 reading `1/1`, and 18 reading `1/2`, where the two copies carry two different alternates at that one position, which brings the three counts to 1,056. Both descriptions of this person's chromosome 20 agree. They are written in different notations.

The `Type` column adds the last piece, counted by the first-alternate rule from step 2. Of the 1,056 bcftools rows, 874 are substitutions and 182 are insertions or deletions. All 862 LoFreq rows are substitutions. The `Indel` chip therefore empties the LoFreq rows entirely and keeps 182 bcftools rows, which is another case where a filter returning nothing is telling you about the file rather than about the filter.

## What good looks like

Five checks are worth making on any variants table before you build on what it says, and this fixture lets you make all five.

First, read the row count against the size of the region. The bcftools track called 1,056 rows across 500 kilobases, and 500,000 divided by 1,056 is roughly 473, so that is one difference every 470 bases or so. Human samples differ from the reference at about one base in a thousand, so this slice is about twice as dense as that figure. A factor of two either way is expected, since variants are not spread evenly along a chromosome. A count in the single digits would mean the alignment failed or the wrong reference was used. A count in the tens of thousands would mean the caller is reporting sequencing error as signal.

Second, look at the `Filter` column itself before you filter on it, rather than clicking the `PASS` chip and drawing a conclusion from whatever appears. An empty table after a chip click is ambiguous. It means either that no row passed or that no row was ever judged, and only the column tells you which.

Third, check that the quality and depth distributions have the shape described above, most rows well clear of the thresholds with a short tail near the bottom. Sort by `Quality` ascending and read the first twenty rows. If the whole table looks like that tail, stop and go back to the alignment.

Fourth, when two tracks are loaded, check the size of their disagreement and look for a mundane explanation before an interesting one. Here 852 positions are shared, 201 are bcftools-only, and 9 are LoFreq-only, and the indel default explains most of the 201. A disagreement you cannot explain by a difference in caller defaults is worth investigating. One you can explain that way is not.

Fifth, know where each row came from. The `Source` column names the track, and every track LGE writes carries a [provenance](../../GLOSSARY.md#provenance) record filed beside it recording how it was made. The column itself is not a link. To read the record, select the track in the project sidebar rather than clicking a cell in this table. A filtered table you cannot trace back to a caller run is a list of numbers with no way to check them.

## On the command line

This section is optional. Everything above happens in the window, every row count quoted earlier in this chapter can be read off the table itself, and nothing later in this manual needs you to have run a command. Commands go in Terminal, the macOS application that gives you a text prompt, which you open from the Applications folder under Utilities.

The table cannot write a VCF. When a downstream tool needs your filtered rows as a file of their own, `lungfish-cli variants query` is the route. It reads the same variant database the table reads, applies the filter expression you hand it, and writes the matching rows to a new VCF with a [provenance](../../GLOSSARY.md#provenance) record beside it. The command stages the output first, writes that record, and publishes the VCF only once the record is safely saved, restoring the previous record if anything fails, so a half-written export cannot masquerade as a finished one.

The command line's filter grammar is not the Search Builder's, and assuming otherwise is the fastest way to an error message. Start from the one shape that works. The `--filter` flag accepts per-sample clauses only, of the form `Sample[<name>].<field>`, plus a `count(...)` over all samples and a comparison between two named samples. The sample name inside the brackets is the one the drawer's **Samples** tab lists, which is `HG002` here. The plain clause keys the Search Builder writes, such as `filter=PASS` or `pos:1-250000`, and comparisons against `INFO` keys such as `DP>=10`, are rejected with the message "Unsupported smart-filter clause". Only `GT`, `AF`, and `DP` are valid per-sample fields, and `AF` is worked out from the allele depths rather than read from an `AF` tag, so it works on a caller that writes `AD` and returns nothing on one that does not.

The first line of the block below sets a shortcut name for the bundle's location on disk, so the later lines can say `"$BUNDLE"` rather than repeating the path. The path shown is an example. Replace it with the path to your own project folder, keeping the double quotes, which are what stop the space in `Reference Sequences` from splitting the path in two.

```bash
BUNDLE="MyProject.lungfish/Reference Sequences/chr20_10.0-10.5Mb.lungfishref"

# Homozygous-alternate calls for the HG002 sample, 415 rows on this fixture
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002].GT=1/1' \
    --output hom-alt.vcf

# Heterozygous calls, 623 rows
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002].GT=0/1' \
    --output het.vcf

# Calls where over half the reads carry the alternate, 770 rows
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002].AF>=0.5' \
    --output majority.vcf

# Cap the export, which writes the first 20 matching rows only
lungfish-cli variants query "$BUNDLE" \
    --filter 'Sample[HG002].GT=1/1' \
    --output first20.vcf --limit 20

# Count what came out. bcftools prints the rows without the
# header, and wc -l counts the lines it printed.
bcftools view -H hom-alt.vcf | wc -l
```

The third of those counts is worth a moment, because 770 is not the 1,038 you get by adding the heterozygous and homozygous-alternate rows. The two counts answer different questions. A genotype clause reads the label the caller wrote, while an `AF` clause recomputes the fraction from the allele depths on each row, so a heterozygous row whose alternate reads fall just under half the total is counted by the first and not by the second.

Four flags shape the run beyond the bundle path. `--filter` holds the filter expression and is required. `-o` or `--output` names the VCF and is required too. `--limit` caps how many rows the export writes and defaults to 5000, which stops a broad filter on a large database from running away. `--format` prints the run summary as `text`, `json`, or `tsv` and defaults to `text`. A `-t` or `--threads` flag sets the thread count and defaults to automatic.

A narrower cousin sits beside it. `lungfish-cli variants extract-sample` pulls one named sample's calls out of a multi-sample track rather than filtering rows, which is what you want when a collaborator needs their own sample and nothing else.

## Next

Continue to [Nanopore Variant Calling](04-nanopore-variant-calling.md) for the callers built for long reads, or to [Extracting a Consensus Sequence](05-consensus-and-lineage.md) to turn an alignment into a sequence.
