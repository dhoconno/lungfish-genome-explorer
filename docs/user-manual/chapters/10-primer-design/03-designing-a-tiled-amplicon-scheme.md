---
title: Designing a Tiled Amplicon Scheme
chapter_id: 10-primer-design/03-designing-a-tiled-amplicon-scheme
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 10-primer-design/02-designing-a-pcr-assay, 02-sequences/04-aligning-sequences]
estimated_reading_min: 22
task: Design overlapping two-pool amplicons across a whole gene with PrimalScheme, Olivar and varVAMP, compare how each handles variation, and save one design as a primer scheme.
tags: [primer-design, tiling, amplicon, primer-scheme, primalscheme, olivar, varvamp, mhc]
tools: [primalscheme3, olivar, varvamp]
entry_points:
  - "Tools > PCR Primer Design > PrimalScheme…"
  - "Tools > PCR Primer Design > Olivar…"
  - "Tools > PCR Primer Design > varVAMP…"
  - "Inspector > View > Save as Primer Scheme…"
  - "CLI: lungfish-cli primers design primalscheme3"
  - "CLI: lungfish-cli primers design olivar"
  - "CLI: lungfish-cli primers design varvamp"
  - "CLI: lungfish-cli primers scheme-from-analysis"
shots:
  - id: tiled-primalscheme-dialog
    caption: "The PCR Primer Design dialog on PrimalScheme with the twelve-allele Mamu-A1 alignment as its input, showing the Scheme settings section with the three amplicon size fields and Primer pools."
  - id: tiled-varvamp-threshold
    caption: "The PCR Primer Design dialog on varVAMP in Tiled amplicons mode, with 0.8 typed in the cumulative consensus threshold field and its caption beneath."
  - id: tiled-primalscheme-overview
    caption: "The Overview tab of the Mamu-A1 tiled PrimalScheme analysis, showing the coverage percentage, the covered-bases line, the visible coverage note, and the amplicon track with Pool 1 and Pool 2 lanes."
  - id: tiled-varvamp-advisory
    caption: "The Overview tab of the Mamu-A1 tiled varVAMP threshold 0.8 analysis, showing the information advisory that reads 10 of 12 sequences must agree."
  - id: tiled-save-scheme-sheet
    caption: "The Save as Primer Scheme sheet for the varVAMP threshold 0.8 analysis, showing the summary line, the Coordinate reference name and statement, and the Scheme name field."
illustrations: []
glossary_refs: [amplicon, primer, primer-pool, primer-scheme, primer-trim, tiling, msa, alignment-column, consensus-sequence, degenerate-base, design-reference, iupac-ambiguity-code, bed, mhc, allele, exon, intron, bundle, reference-bundle, inspector, operations-panel, plugin-pack, read-length, mapping, blast, oligo]
features_refs: [bam.primer-trim]
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A tiled amplicon scheme is a set of primer pairs whose products overlap end to end, so that together they cover a stretch of DNA longer than any single product. [Tiling](../../GLOSSARY.md#tiling) lays [amplicons](../../GLOSSARY.md#amplicon) along the target like roof tiles, each overlapping its neighbours, as [Multiplexing, pools and tiling](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains. Neighbouring amplicons cannot share one reaction tube, so a scheme splits its primers into two [primer pools](../../GLOSSARY.md#primer-pool) and each sample is amplified twice, with the products combined before library preparation, the bench steps that turn DNA into a sequencer-ready sample.

Lungfish Genome Explorer (LGE) designs tiled schemes with three engines, PrimalScheme, Olivar and varVAMP, all under **Tools > PCR Primer Design**. Each reads a [multiple sequence alignment](../../GLOSSARY.md#msa) of the target, finds primer sites, and chains amplicons along it. They differ in how they deal with sites where the aligned sequences disagree, which is the subject of this chapter. LGE saves each design as a primer analysis bundle in the project's `Analyses` folder, and a tiled design can then be saved as a [primer scheme](../../GLOSSARY.md#primer-scheme), the `.lungfishprimers` bundle that [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) uses to clip primer bases out of mapped reads.

## Why you would do this

Tiling is the standard design for a viral genome, where each sample carries essentially one sequence, and it is the design the ARTIC network, a collaboration that publishes schemes for outbreak sequencing, made standard for reading whole viral genomes straight from patient samples. A short-read instrument cannot read a 3,000-base product end to end, since an Illumina paired-end run reads at most a few hundred bases from each end of a fragment, as [Read length](../../GLOSSARY.md#read-length) describes. With amplicons of about 400 bases each product is short enough for paired 250-base reads to overlap across its middle, and long products also amplify poorly from degraded or low-quantity DNA.

This chapter tiles *Mamu-A1*, a rhesus macaque [MHC](../../GLOSSARY.md#mhc) class I gene about 3,000 bases long, because it is the hardest kind of target the three engines will meet and the comparison teaches how each one works. Be clear about what such a scheme can and cannot deliver for a diploid gene. A macaque carries two *Mamu-A1* alleles, and more sequence from the paralogs, so separate 400-base amplicons break phase. Once the amplicons are sequenced apart, nothing says which variant in amplicon 3 belongs on the same allele as which variant in amplicon 5, so full-length allele sequences cannot be assembled for a heterozygous animal, and where a primer site is shared an amplicon may carry paralog sequence too. A laboratory that needs full-length alleles uses one long amplicon read on a long-read instrument, as [Running genotyping](../09-genotyping/02-running-genotyping.md#6-what-changes-on-the-full-length-ont-route) describes, or sequences exon 2 alone as an amplicon panel. *Mamu-A1* is also polymorphic, GC-rich and one of a duplicated gene family, for the reasons [Why you would do this](01-what-is-primer-design.md#why-you-would-do-this) sets out.

The demo project's panel is twelve genomic *Mamu-A1* alleles from eleven lineages, 2,920 to 2,943 bases long, which align into 2,953 columns. Row 1 is `LR699574.1`, 2,933 bases, whose record places [exon](../../GLOSSARY.md#exon) 1 at bases 2 to 74, exon 2 at 205 to 474 and exon 3 at 718 to 993. The goal here is a scheme of about 400-base amplicons in two pools that covers as much of the gene as possible in all twelve alleles.

## Choosing a tool

All three engines tile an alignment into two pools. What separates them is how each handles a site where the alleles differ, and that is the property of your data that settles the choice. [When the target varies](01-what-is-primer-design.md#when-the-target-varies) introduces the problem.

**PrimalScheme** adds an [oligo](../../GLOSSARY.md#oligo) for every variant. It was built for tiled sequencing of whole viral genomes from clinical samples ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)), and LGE runs an LGE build of PrimalScheme 3, whose method is described in its preprint ([Method papers](../appendices/bibliography.md#method-papers)). At each candidate site it collects every distinct sequence the aligned alleles carry there and makes one exact-match oligo for each, so the site is covered by a small cloud of primers that all go into the same pool. It walks along the alignment choosing overlapping amplicons, alternating pools, and refuses any oligo that would pair with one already in its pool. Every sequence in the alignment then gets a perfect match at every site. The cost is oligo count, and a seven-oligo site leaves each of those oligos at roughly a seventh of the usual concentration, which can lower that amplicon's yield.

**Olivar** avoids variable sites. It was built for tiled sequencing of pathogen genomes ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It scores every base of the target for risk, adding up how variable the base is, whether its surroundings are extremely GC-rich or GC-poor, whether it sits in low-complexity sequence such as a repeat, and, when you give it sequences to screen against, whether the region matches those too. It samples many possible layouts of primer sites and keeps the one with the lowest total risk, choosing the primers inside those sites with SADDLE, a search that lowers the chance of [primer dimers](01-what-is-primer-design.md#runs-repeats-hairpins-and-dimers) across each whole pool ([Method papers](../appendices/bibliography.md#method-papers)). It places one plain oligo per site, so where no site is free of variation some alleles carry a mismatch under a primer, and Binding inspection is where you find out which.

**varVAMP** writes the variation into the primer. It was built for pan-specific primers on very diverse viruses ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It first builds a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of the alignment with a consensus threshold. At each column, a base carried by enough sequences to reach the threshold is written plainly, and otherwise the commonest bases are added together until they reach it and written as one [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code), a letter such as S for C or G. A primer taken from that consensus is degenerate, meaning it is synthesised as a mixture, as [Degenerate bases and what they cost](01-what-is-primer-design.md#degenerate-bases-and-what-they-cost) explains, and varVAMP allows at most two ambiguous bases per primer by default and none in the last three bases at the 3′ end. It then links candidate amplicons into the longest chain of overlapping amplicons it can find, split into two pools. The strength is few oligos that still match most alleles. The limit is that one unbroken chain is all it keeps, so a stretch with no usable primer site ends the scheme rather than starting a second chain, which [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) is about.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| PrimalScheme | Tiled viral genomes, variation absorbed by extra exact-match oligos | Every allele must match every primer exactly and a larger oligo order is acceptable | Diversity is so high that sites need many oligos each |
| Olivar | Tiled pathogen genomes, low-risk sites and pool-wide dimer checks | Off-target binding or dimers are the main worry and you want one plain oligo per site | Some alleles must not carry any primer mismatch |
| varVAMP | Tiled or single amplicons on diverse genomes, degenerate consensus primers | You want few oligos that tolerate variation through ambiguity codes | Coverage stops short and the single-chain limit cannot be tuned away |

All three were run on the twelve-allele alignment with 400-base amplicons, bounds of 360 to 440 bases, and two pools. Spans are 1-based and inclusive, as the viewer shows them.

| Engine | Amplicons | Oligos | Span on its design reference | Coverage | Run time |
|---|---|---|---|---|---|
| PrimalScheme | 8 | 49, over 16 primer sites, up to 7 at one site | 208 to 2,876 of 2,933 (row 1, LR699574.1) | 91.0% | 136 s |
| Olivar | 10 | 20, one per site | 75 to 2,705 of 2,934 (Olivar's own reference) | 89.7% | 82 s |
| varVAMP, automatic threshold | 9 | 18 | 23 to 2,793 of 2,916 (its ambiguous consensus) | 95.0% | 25 s |
| varVAMP, threshold 0.8 | 10 | 20 | 22 to 2,931 of 2,931 (its ambiguous consensus) | 99.3% | 24 s |

Coverage is the share of the engine's own [design reference](../../GLOSSARY.md#design-reference) that lies inside at least one amplicon, and each engine measures it on a different reference, as [Reading the results](#reading-the-results) explains. The Overview shows it to one decimal place, and varVAMP's own figures for the two runs above are 95.03 and 99.28 percent. Read the table as a trade. PrimalScheme matched every allele exactly and paid for it in oligos. Olivar kept one oligo per site and paid for it wherever no site was free of variation. varVAMP covered the most sequence with the fewest oligos, and at threshold 0.8 it paid by letting two of the twelve alleles mismatch at some primer positions.

The procedure below runs all three, because the comparison is the lesson. For your own target, start with PrimalScheme when every sample's sequence must amplify evenly and the order size is acceptable, with varVAMP when you want a small order and will check each primer's mismatches afterwards, and with Olivar when off-target products are the bigger risk, as they are with MHC paralogs, and you can give it the sequences to avoid. To design one primer pair rather than a scheme, use Primer3, as [Designing a PCR Assay](02-designing-a-pcr-assay.md) shows.

## Before you start

You need the Primer Design demo project open, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. This chapter uses `mamu-a1-panel` under `Reference Sequences`, and the same sequences are in the [mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design).

Install two [plugin packs](../../GLOSSARY.md#plugin-pack) from **Tools > Plugin Manager…**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The Multiple Sequence Alignment pack runs MAFFT, and the PCR Primer Design pack, about 2.8 GB, carries all four design engines. Each engine's first run prepares its own programs, and the [Operations Panel](../../GLOSSARY.md#operations-panel) shows "Checking *Tool* runtime…" on every run, with a "Preparing *Tool* *version*…" step on the first.

The engines need an alignment of equal-length rows. The dialog does list the reference bundle, but a run on it fails, because its twelve sequences differ in length, so align them first as the procedure's first step does. If you worked through [Designing a PCR Assay](02-designing-a-pcr-assay.md) you already have the alignment. Each design takes between about half a minute and a little over two minutes.

## Procedure

### Align the twelve alleles

Click `mamu-a1-panel` under `Reference Sequences`, choose **Tools > Multiple Sequence Alignment > MAFFT...** and run it at its default settings. Then click the result under `Analyses/Multiple Sequence Alignments/` and check that the main panel shows 12 rows and 2,953 columns.

### Run PrimalScheme

1. Click the `mamu-a1-panel` alignment in the sidebar, then choose **Tools > PCR Primer Design > PrimalScheme…**. The dialog takes its inputs from the sidebar selection and has no button to add one later.
2. Under "Selected project inputs", check that the alignment is listed with the line "12 alignment rows included". If the section instead asks you to select bundles in the sidebar, cancel, select the alignment, and reopen the dialog.
3. Under "Scheme settings", leave **Output grouping** at "One scheme per MSA", the amplicon sizes at 360, 400 and 440, and **Primer pools** at 2. Leave "Advanced settings" collapsed.

    <!-- SHOT: tiled-primalscheme-dialog -->

4. Under "Save analysis", replace the **Analysis name** with `Mamu-A1 tiled PrimalScheme`, check that the status line reads "Ready. Progress will appear in Operations.", and click **Run**. The Operations Panel shows a row titled "PrimalScheme · Mamu-A1 tiled PrimalScheme", and when it reports "Primer analysis saved." LGE opens the new analysis.

### Run Olivar

Select the alignment again and choose **Tools > PCR Primer Design > Olivar…**. Read the mode line, which says the mode is tiled amplicons and cannot be changed, and the pool line, which says Olivar's own behaviour is two tiled pools. Leave the amplicon sizes at 360, 400 and 440, name the analysis `Mamu-A1 tiled Olivar`, and click **Run**.

### Run varVAMP twice

Select the alignment and choose **Tools > PCR Primer Design > varVAMP…**. Check that **Design mode** is "Tiled amplicons", whose caption reads "Design a tiled two-pool amplicon scheme." Leave the threshold field, labelled "Cumulative consensus threshold (blank = native automatic)", empty so varVAMP picks the threshold itself. Leave the amplicon sizes as they are, name the analysis `Mamu-A1 tiled varVAMP`, and click **Run**.

Then open the dialog on varVAMP once more, type `0.8` in the threshold field, name the analysis `Mamu-A1 tiled varVAMP threshold 0.8`, and click **Run**. [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) explains why this second run reaches further.

<!-- SHOT: tiled-varvamp-threshold -->

### Save a design as a primer scheme

Click the analysis you want to use, here `Mamu-A1 tiled varVAMP threshold 0.8`, open its **Results** tab, and click **Save as Primer Scheme…**. The same button sits in the [Inspector](../../GLOSSARY.md#inspector) on its View tab, and when it is dimmed the caption beneath gives the reason.

Read the sheet before saving. Its summary line gives the engine and the counts of primers, amplicons and pools, and under "Coordinate reference" it names the sequence the scheme's coordinates belong to and states which reads can be trimmed with it. **Scheme name** defaults to the analysis name, the result's label and the word scheme, which is exact but long, so shorten it if you like. Click **Save**, and an operation titled "Save as Primer Scheme" writes the scheme under `Primer Schemes` in the sidebar. [Saving a designed scheme](../appendices/primer-schemes.md#saving-a-designed-scheme) documents what the bundle holds.

<!-- SHOT: tiled-save-scheme-sheet -->

## Settings

The three engines share the first group of settings, and the rest belong to one engine each. This section carries the ones the procedure sets and the tuning section below uses. [Primer Design Settings](../appendices/primer-design-settings.md#primalscheme) carries every other control, including the pool and overlap rules, the mispriming database, the developer executable, and the six controls that appear only for a combined multi-gene panel.

**Output grouping.** Chooses between "One scheme per MSA", which designs each selected alignment on its own, and "Combined scheme from selected MSAs", which designs one panel across several. The default is one scheme per alignment, the right choice for a single gene. Choose Combined only for PrimalScheme or Olivar when several genes must share one pair of reactions, and note that varVAMP shows the picker dimmed. On the command line this is `--grouping`.

**Minimum amplicon size (bp).** Sets the shortest amplicon the design may keep, measured on the design reference from the outer end of the forward primer to the outer end of the reverse primer. The default is 360, 90 percent of the target. Raise it with the target for long-read runs, and lower it for degraded DNA or short reads, keeping Olivar's floor of 120 in mind. On the command line this is `--amplicon-size-min`.

**Target amplicon size (bp).** Gives the nominal amplicon length. The default is 400, and editing it resets any bound you have not edited yourself to 90 and 110 percent of the new value. Its caption calls the target nominal and says selection does not favour the closest size, so the two bounds are what the engines enforce. Change the bounds when you mean to change what is designed. On the command line this is `--amplicon-size`.

**Maximum amplicon size (bp).** Sets the longest amplicon the design may keep, primers included. The default is 440. Raise it to let an amplicon reach over a variable stretch that holds no usable primer site, as long as your reads still span the longer product. On the command line this is `--amplicon-size-max`.

The line under the three size fields restates the span that will be saved, which for these settings reads 360 to 440 bp, inclusive of both primer sites. LGE remembers the sizes separately for each engine, and PrimalScheme accepts a nominal target only between 100 and 2,000 bases.

**Primer pools.** Sets how many reactions PrimalScheme splits its primers across. The default is 2, the smallest number that keeps overlapping neighbours apart. Keep 2 for a tiled scheme. On the command line this is `--pool-count`.

**Minimum base frequency.** Sets how common a base must be at a site before PrimalScheme makes an oligo for it. The default is 0, so every variant gets its own oligo, which is why this design needed 49. Raise it, for example to 0.1, to drop oligos for variants carried by few sequences, accepting that those sequences will carry a mismatch. On the command line this is `--minimum-base-frequency`.

**Backtrack when extending the scheme.** Lets PrimalScheme revisit earlier amplicon choices when it cannot place the next one. It is off by default, which is faster. Turn it on when a design stops short of the end of the alignment. On the command line this is `--backtrack`.

**Use high-GC design settings.** Switches PrimalScheme to its own settings for GC-rich targets. It is off by default. Try it when a GC-rich target such as MHC leaves gaps with the standard settings. On the command line this is `--high-gc`.

**Search effort** and **Random seed** are Olivar's two tuning levers. Search effort multiplies how many candidate layouts Olivar tries, and defaults to 1. Random seed fixes the starting point of its random search so the same inputs give the same design, and defaults to 10. Raise the effort or change the seed when coverage falls short, and record the seed you used. On the command line these are `--effort` and `--seed`.

**Design mode.** Chooses between varVAMP's "Single amplicon", "Tiled amplicons" and "qPCR / dPCR primers + probe". The default is Tiled amplicons. Choose Single for one pan-allele product and qPCR for a detection assay, which [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers. On the command line this is `--mode`.

**Cumulative consensus threshold.** Sets how much agreement a base needs before varVAMP's consensus writes it plainly rather than as an ambiguity code. Read it as "k of N sequences must agree". It is blank by default in tiled mode, which lets varVAMP choose, and the saved analysis then reports the value used. Lower it when coverage falls short. On the command line this is `--consensus-threshold`. The dialog's caption warns that with few sequences the threshold moves in whole-sequence steps, because one sequence out of twelve is more than eight percentage points.

**Maximum primer ambiguities.** Limits how many ambiguity codes one primer may contain. The default is 2, varVAMP's own value, because each code multiplies the number of sequences in the synthesised mixture. Raise it to 3 to let primers sit in more variable windows, and lower it to 0 or 1 when you want plain primers. On the command line this is `--maximum-primer-ambiguities`.

**Tiled overlap (bp).** Sets how many bases neighbouring amplicons must share. The default is 25, varVAMP's own value, wide enough to join reads across the overlap. Raise it for extra safety against one amplicon failing, at the cost of more amplicons. On the command line this is `--tiled-overlap`.

**Analysis name.** Names the primer analysis bundle in the project's `Analyses` folder. The default is "Primer analysis", and a name already used in the project blocks Run, so give every run its own name as the procedure does. This setting has no command-line flag, because `--output` takes the whole bundle path.

## Tuning a scheme that covers too little

Read the coverage percentage on the Overview tab first. When it is lower than you want, the response depends on the engine.

With varVAMP, coverage below 95 percent in tiled mode adds a warning to the Overview card, and its wording says what to do.

```text
varVAMP keeps only the longest unbroken chain of overlapping amplicons.
Regions it cannot link are left uncovered instead of starting a second
chain. Wider amplicon size bounds, a lower consensus threshold or more
allowed ambiguous bases usually close these gaps.
```

The automatic run on this alignment reached 95.03 percent, just above the line where LGE adds that warning, so its card shows only the threshold advisory quoted below. The warning's advice still applies when you want the last few percent, and the three levers come in this order, because lowering the threshold is the strongest one on a variable target.

```text
Consensus threshold 0.99, chosen automatically by varVAMP. A base counts
as conserved only when 12 of 12 sequences agree. Any threshold from 0.92
to 1.00 gives the same consensus for this alignment.
```

At 0.99 every column where one allele differs becomes an ambiguity code, few windows hold two or fewer of them, and the chain stops at 95.0 percent coverage. The run at 0.8 reported instead that a base counts as conserved only when 10 of 12 sequences agree, and that any threshold from 0.76 to 0.83 gives the same consensus for this alignment. Single-allele differences stopped producing codes, and coverage reached 99.3 percent. The price is that the alleles in the minority at those columns carry a mismatch, which you check in Binding inspection.

Widening the amplicon bounds is the next lever, because a longer amplicon can reach over a variable stretch that holds no usable primer site. Only widen as far as your reads can span. Raising **Maximum primer ambiguities** from 2 to 3 is the third, and it costs a more complex oligo mixture. Adding sequences helps in a way that is easy to misread. With twelve sequences each threshold step is one twelfth, so the threshold is coarse. With sixty alleles the same 0.8 asks for 48 to agree, and one rare allele no longer forces an ambiguity code.

With PrimalScheme, low coverage means it could not chain amplicons through a region rather than that it avoided variation, since it makes an oligo per variant. Turn on **Backtrack when extending the scheme**, then try **Use high-GC design settings** on a GC-rich target, and widen the bounds. Raising **Minimum base frequency** cuts the oligo count rather than raising coverage. With Olivar, raise **Search effort**, try another **Random seed**, and widen the bounds, since its layout comes from a random search over risk scores.

Coverage never reaches 100 percent in a tiled design. The first forward primer and the last reverse primer sit inside the target, so the bases outside them are never inside an amplicon. On this alignment that accounts for the first 207 and the last 57 bases of PrimalScheme's span.

## Reading the results

Click the analysis under `Analyses` and read the Overview tab. There is one card per design reference. The large number is coverage, with a label beneath naming what was measured, which reads "Reference spanned by amplicons" for PrimalScheme and "Generated reference spanned by tiled assays" for Olivar and varVAMP. The first of the card's notes is always visible, and "What this coverage figure does and does not mean" opens the rest. They say that overlapping amplicon spans count once, that primer sequences sit inside the spans, and, for PrimalScheme, that positional coverage of the reference does not establish coverage of every alignment row or successful amplification. A line beneath gives the same thing in bases, both covered and outside every amplicon span.

<!-- SHOT: tiled-primalscheme-overview -->

The amplicon track below is the picture of the scheme. It has one lane per pool, labelled "Pool 1" and "Pool 2", ruled from 1 to the length of the reference. Each amplicon is a bar whose tooltip gives its span, length and pool. Forward primers are drawn in blue, reverse primers in orange, and probes, which a tiled design has none of, in purple. A gap in both lanes is a stretch the scheme does not cover.

varVAMP results also show advisories on the card, an information note for the threshold used and, below 95 percent coverage in tiled mode, the longest-chain warning quoted above.

<!-- SHOT: tiled-varvamp-advisory -->

Read the covered span against the gene map, because coverage counts the primer sites themselves and primer trimming removes those bases from the reads. PrimalScheme's span starts at base 208 and its first primer cloud sits at 211 to 233, inside exon 2, which runs from 205 to 474. So exon 1, at 2 to 74, is in no amplicon at all, and the opening bases of exon 2 are read only by whatever amplicon overlaps them from the left. For a scheme meant to read exon 2 that is a hole rather than coverage. A laboratory would add a separate exon 1 amplicon, or decide it does not need those bases. Check, for any scheme, that no primer sits inside a region whose sequence you need.

The Results tab lists every oligo, grouped by pool, with its length, GC content, role, sequence and position. An oligo built from degenerate bases shows "GC varies" instead of a percentage and carries an orange line counting its ambiguous bases, a reminder to check how your supplier will synthesise it. A varVAMP primer such as `TGTSTYCCGGTCCCAATACT` holds two, S standing for C or G and Y for C or T. PrimalScheme's oligos are the opposite case. One site can carry several, named `_LEFT_1`, `_LEFT_2` and so on, and the viewer groups them as "Selected primer set" with the reminder that all of them are components you order together, not ranked alternatives. The numbers are labels, and they do not pair one forward oligo with one reverse oligo.

The Binding inspection tab is where you check what a primer does to each allele, and [Inspect binding against the alignment](05-reviewing-and-ordering-primers.md#inspect-binding-against-the-alignment) works through it. The Inspector holds the rest of the record, naming the grouping, inputs, results and tool version on its Bundle tab, listing every file with a checksum on its Files tab, including the engine's own outputs, and holding the display filters and the export buttons on its View tab.

### What the saved scheme holds

A scheme written by **Save as Primer Scheme…** is a `.lungfishprimers` bundle in the project's `Primer Schemes` folder, holding `primers.bed` with one line per oligo, `primers.fasta` with the sequences, a manifest, provenance, and one attachment, `attachments/design-reference.fasta`. [Saving a designed scheme](../appendices/primer-schemes.md#saving-a-designed-scheme) documents the bundle.

That attachment is the point to understand. The [BED](../../GLOSSARY.md#bed) coordinates belong to the engine's own design reference, not to whatever accession you might map reads to out of habit. For PrimalScheme it is the first row of the alignment without its gaps, here `LR699574.1`. For Olivar it is the reference Olivar generated from the alignment, which is no single input allele. For varVAMP it is the ambiguous consensus, which contains IUPAC codes and matches no real sequence at all. The save sheet states this before you save, and the saved scheme repeats it. Reads must be [mapped](../../GLOSSARY.md#mapping) to `attachments/design-reference.fasta`, or to a sequence identical to it, before the scheme can trim them, and mapping to a consensus means a mapper scores its ambiguity codes as mismatches at those positions. For that reason a varVAMP scheme is easier to use downstream if you save the PrimalScheme or Olivar design instead, or map to an alignment row and accept that the primer positions shift.

With that in hand, trimming is the ordinary route. Import the design reference as a reference bundle, map your reads to it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, then trim with the scheme as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows, where it appears in the Primer Scheme menu under "In This Project".

## What good looks like

Coverage in the nineties on a variable gene is a good tiled design, and the covered-bases line should show the bases outside every amplicon sitting at the two ends rather than in the middle. A gap in the middle of the track means a region with no usable primer site, and the tuning section above is the response. Read the span against your gene's feature map, as above, and confirm that nothing you must read sits under a primer.

Check the oligo count against the amplicon count. Two oligos per amplicon is the plain case, as Olivar's 20 over 10 amplicons shows. PrimalScheme's 49 over 8 amplicons reflects its extra oligos for variant sites, and the number tells you what the order will cost. A varVAMP oligo carrying more than two ambiguous bases should not appear under the default limit, so if one does, check the limit you set.

Open Binding inspection and step through a few primers, especially any sitting in exon 2 or exon 3. A primer with a mismatch near its 3′ end against an allele you must detect may fail to copy that allele, and an animal carrying it could lose that allele's reads, so check where each mismatch falls before accepting it. The varVAMP scheme saved at threshold 0.8 is the case in point. Two of the twelve alleles mismatch at some primer positions by design, which is acceptable when those mismatches sit at a primer's 5′ end and not when they sit at its 3′ end.

Last, read the reference statement on the save sheet and write it into your protocol. A scheme whose coordinates belong to a consensus sequence is easy to hand to a colleague who will map reads to a database accession and then see almost nothing trimmed. When that happens, the trim rate in the run's log is the first place it shows.

## On the command line

This section is optional. Every block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and the flags are listed under [Primer schemes and primer design](../appendices/cli-reference.md#primer-schemes-and-primer-design). These commands reproduce the three tiled designs and save one as a scheme.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Primer Design.lungfish"
ALIGN="$PROJECT/Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa"

lungfish-cli primers design primalscheme3 \
  --msa "$ALIGN" \
  --amplicon-size 400 --amplicon-size-min 360 --amplicon-size-max 440 \
  --pool-count 2 \
  --output "$PROJECT/Analyses/Mamu-A1 tiled PrimalScheme.lungfishprimeranalysis"

lungfish-cli primers design olivar \
  --msa "$ALIGN" \
  --amplicon-size 400 --amplicon-size-min 360 --amplicon-size-max 440 \
  --output "$PROJECT/Analyses/Mamu-A1 tiled Olivar.lungfishprimeranalysis"

lungfish-cli primers design varvamp \
  --msa "$ALIGN" --mode tiled --consensus-threshold 0.8 \
  --amplicon-size 400 --amplicon-size-min 360 --amplicon-size-max 440 \
  --output "$PROJECT/Analyses/Mamu-A1 tiled varVAMP threshold 0.8.lungfishprimeranalysis"

lungfish-cli primers scheme-from-analysis \
  "$PROJECT/Analyses/Mamu-A1 tiled varVAMP threshold 0.8.lungfishprimeranalysis" \
  --project "$PROJECT" \
  --output "Mamu-A1 tiled varVAMP threshold 0.8"
```

Leave out `--consensus-threshold` for varVAMP's automatic choice, which is what the blank field in the dialog does. Leaving the two amplicon bounds off gives the same 90 and 110 percent of the nominal size that the dialog sends. The design commands print the advisories the Overview card shows, as `[info]` and `[warning]` lines after the written-to line. Run `primers scheme-from-analysis` with `--list` first to see which results can be saved and why any cannot, and pass `--result-id` when an analysis holds more than one saved result. The window runs the same service and records the equivalent command on its Operations row.

## Next

Continue to [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md), which designs a detection assay with a probe and then makes it specific. [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) turns any of these designs into an order, and [Primer Scheme Bundles](../appendices/primer-schemes.md) documents the bundle a saved scheme writes.
