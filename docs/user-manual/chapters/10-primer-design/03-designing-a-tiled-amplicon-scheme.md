---
title: Designing a Tiled Amplicon Scheme
chapter_id: 10-primer-design/03-designing-a-tiled-amplicon-scheme
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 10-primer-design/02-designing-a-pcr-assay, 02-sequences/04-aligning-sequences]
estimated_reading_min: 22
task: Design overlapping two-pool amplicons across a whole gene with PrimalScheme, Olivar and varVAMP, compare how each handles variation, and save one design as a primer scheme.
tags: [primer-design, tiling, amplicon, primer-scheme, primalscheme, olivar, varvamp, mhc]
tools: [primalscheme3, olivar, varvamp]
parameters_refs: [primer-design.primalscheme3, primer-design.olivar, primer-design.varvamp]
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
glossary_refs: [amplicon, primer, primer-pool, primer-scheme, primer-trim, tiling, msa, alignment-column, consensus-sequence, degenerate-base, design-reference, iupac-ambiguity-code, bed, mhc, allele, exon, intron, bundle, reference-bundle, inspector, operations-panel, plugin-pack, read-length, mapping, blast, oligo, paralog, linkage, library-prep, paired-end, primer-dimer, gap, read, coverage, accession, checksum, manifest, provenance, fragment, heterozygous, lineage, preprint, fasta, sidebar]
features_refs: [bam.primer-trim, primer-design.primalscheme3, primer-design.olivar, primer-design.varvamp, primer-analysis.scheme-from-analysis]
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A tiled amplicon scheme is a set of primer pairs whose products overlap end to end, so that together they cover a stretch of DNA longer than any single product. [Tiling](../../GLOSSARY.md#tiling) lays [amplicons](../../GLOSSARY.md#amplicon), the stretches of DNA that one primer pair copies, along the target, the stretch of DNA you want covered, like roof tiles, as [Multiplexing, pools and tiling](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains. Neighboring amplicons cannot share one reaction tube, because the reverse primer of one and the forward primer of the next face each other across their overlap and would copy that short stretch on its own, using up primers the full products need. So a scheme splits its primers into two [primer pools](../../GLOSSARY.md#primer-pool), separate reaction mixes, and each sample is amplified twice, with the products combined before [library preparation](../../GLOSSARY.md#library-prep), the bench steps that turn DNA into a sequencer-ready sample.

Lungfish Genome Explorer (LGE) designs tiled schemes with three design programs, which this manual calls engines, all under **Tools > PCR Primer Design**. They are PrimalScheme, Olivar and varVAMP. Each reads a [multiple sequence alignment](../../GLOSSARY.md#msa) (MSA) of the target, the sequences lined up so that matching bases share a column, with a dash called a [gap](../../GLOSSARY.md#gap) where one sequence lacks bases the others carry. It then finds primer sites, the stretches where one primer binds, and places amplicons one after another along the alignment. The engines differ in how they treat variable columns, the columns where the aligned sequences disagree. LGE saves each design as a primer analysis [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, in the project's `Analyses` folder. A tiled design can then be saved as a [primer scheme](../../GLOSSARY.md#primer-scheme), the `.lungfishprimers` bundle that [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) uses to clip primer bases, which copy the synthetic primer and not the sample's own DNA, out of [mapped](../../GLOSSARY.md#mapping) [reads](../../GLOSSARY.md#read), the instrument's sequences placed on a reference sequence.

## Why you would do this

Tiling is the usual way to read a whole viral genome straight from patient samples, a design the PrimalScheme method made standard ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). A short-read instrument cannot read a 3,000-base product end to end, since an Illumina [paired-end](../../GLOSSARY.md#paired-end) run reads at most a few hundred bases from each end of a [fragment](../../GLOSSARY.md#fragment), as [Read length](../../GLOSSARY.md#read-length) describes. With amplicons of about 400 bases each product is short enough for the two 250-base reads of a pair to span it, overlapping across its middle, and long products also amplify poorly from degraded or low-quantity DNA.

This chapter tiles *Mamu-A1*, a rhesus macaque [MHC](../../GLOSSARY.md#mhc) class I gene about 3,000 bases long, as a teaching case, because it is the hardest kind of target the three engines will meet. The gene has many [alleles](../../GLOSSARY.md#allele), the versions of it found across animals. It is GC-rich, with about 60 percent of the twelve alleles' bases being G or C, which makes primers bind too tightly and makes the DNA fold on itself. It also belongs to a duplicated family, and a primer can bind that family's [paralogs](../../GLOSSARY.md#paralog), the related gene copies elsewhere in the genome, as [What Is Primer Design](01-what-is-primer-design.md#why-you-would-do-this) explains. Separate 400-base amplicons also break [linkage](../../GLOSSARY.md#linkage), also called phase, the record of which variants sit together on one chromosome, so full-length allele sequences cannot be assembled for a [heterozygous](../../GLOSSARY.md#heterozygous) animal. A laboratory that needs them uses one long amplicon on a long-read instrument, as [Running genotyping](../09-genotyping/02-running-genotyping.md#6-what-changes-on-the-full-length-ont-route) describes, or sequences [exon](../../GLOSSARY.md#exon) 2 alone, which with exon 3 encodes the groove of a class I molecule that holds a short protein fragment, as an amplicon panel.

The demo project's panel is twelve genomic *Mamu-A1* alleles from eleven [lineages](../../GLOSSARY.md#lineage), 2,920 to 2,943 bases long, which align into 2,953 columns, slightly more than the longest allele because the aligner adds gaps. Row 1 is `LR699574.1`, 2,933 bases, whose record places exon 1 at bases 2 to 74, exon 2 at 205 to 474 and exon 3 at 718 to 993. The goal here is a scheme of about 400-base amplicons in two pools that covers as much of the gene as possible in all twelve alleles.

## Choosing a tool

All three engines tile an alignment into two pools. What separates them is how each handles a variable column, where the alleles differ, and that is the property of your data that settles the choice. [When the target varies](01-what-is-primer-design.md#when-the-target-varies) introduces the problem.

**PrimalScheme** adds an [oligo](../../GLOSSARY.md#oligo), a short synthetic DNA strand, for every variant. It was built for tiled sequencing of whole viral genomes from clinical samples ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)), and LGE runs its own modified copy of PrimalScheme 3, whose method the [preprint](../../GLOSSARY.md#preprint) describes ([Method papers](../appendices/bibliography.md#method-papers)) without LGE's changes. At each primer site it makes one exact-match oligo for every distinct sequence the aligned alleles carry there, and all of them go into the same pool. It walks along the alignment choosing overlapping amplicons, alternating pools, and refuses any oligo that would pair with one already in its pool. With the default **Minimum base frequency** of 0, every sequence in the alignment then gets an exact match at every primer site. The cost is oligo count, and a site with several oligos can leave each one at a smaller share of the primer mix, which may lower that amplicon's yield.

**Olivar** steers primers away from variable columns. It was built for tiled sequencing of pathogen genomes ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It scores every base of the target for risk, the chance that a primer placed there would fail, adding up how variable the base is, whether its surroundings are extremely GC-rich or GC-poor, whether it sits in low-complexity sequence, such as a run of one base or a short repeated unit, and, when you give it sequences to screen against, whether the region matches those too. It samples many possible layouts of primer sites and keeps the one with the lowest total risk. It then chooses the primers inside those sites with SADDLE, a search that lowers the chance of [primer dimers](../../GLOSSARY.md#primer-dimer), primers that pair with each other instead of the target, across each whole pool ([Method papers](../appendices/bibliography.md#method-papers)). It places one plain oligo per primer site, so where no primer site is free of variation some alleles carry a mismatch, a base that fails to pair with the primer, and the **Binding inspection** tab is where you find out which. You choose the screening sequences under **Advanced settings**, in "Off-target screening", with **Add Sequences to Screen Against…**. Olivar then counts a region that matches them as riskier and places primers away from it, which lowers the chance of mispriming, where a primer binds and copies a stretch other than its own. With none chosen, the dialog says candidates are not checked for off-targets.

**varVAMP** writes the variation into the primer. It was built for pan-specific primers, primers that work on many variants of the target, on very diverse viruses ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It first builds a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of the alignment, one sequence that summarizes every column, using a consensus threshold, the share of the sequences, from 0 to 1, that must carry a base before the column is written as that base alone. Take a column where 9 of 12 sequences carry A and 3 carry G, at a threshold of 0.8. A alone reaches only 0.75, so G is added, together they reach 1.0, and the column is written R, the [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) for A or G. A primer taken from that consensus is degenerate, meaning it is synthesized as a mixture, as [Degenerate bases and what they cost](01-what-is-primer-design.md#degenerate-bases-and-what-they-cost) explains. By default varVAMP allows at most two ambiguous bases per primer and none in the last three bases at the 3′ end, where the polymerase, the enzyme that copies DNA, starts. It then links candidate amplicons into the longest chain of overlapping amplicons it can find, split into two pools. The strength is few oligos that still match most alleles. The limit is that one unbroken chain is all it keeps, so a stretch with no usable primer site ends the scheme rather than starting a second chain, which [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) is about.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| PrimalScheme | Tiled viral genomes, variation absorbed by extra exact-match oligos | Every allele must match every primer exactly and a larger oligo order is acceptable | Diversity is so high that primer sites need many oligos each |
| Olivar | Tiled pathogen genomes, low-risk sites and pool-wide dimer checks | Off-target binding or dimers are the main worry and you want one plain oligo per primer site | Some alleles must not carry any primer mismatch |
| varVAMP | Tiled or single amplicons on diverse genomes, degenerate consensus primers | You want few oligos that tolerate variation through ambiguity codes | The scheme stops short of the gene's end and the single-chain limit cannot be tuned away |

All three were run on the twelve-allele alignment with 400-base amplicons, bounds of 360 to 440 bases, and two pools. In the next table, a span is a stretch of a reference given as its first and last base, counted from 1 with both included, and it describes an amplicon or a whole scheme. The [design reference](../../GLOSSARY.md#design-reference) is the one sequence an engine counts its positions on. For PrimalScheme it is row 1 of the alignment without its gaps, for Olivar a reference Olivar generates from the alignment, and for varVAMP its ambiguous consensus, the consensus with ambiguity codes in it. Coverage is a design percentage, the share of the design reference inside at least one amplicon, and not the read depth that the Glossary entry [Coverage](../../GLOSSARY.md#coverage) names.

| Engine | Amplicons | Oligos | Span on its design reference | Coverage |
|---|---|---|---|---|
| PrimalScheme | 8 | 49, over 16 primer sites | 208 to 2,876 of 2,933 (row 1, LR699574.1) | 91.0% |
| Olivar | 10 | 20, one per site | 75 to 2,705 of 2,934 (Olivar's generated reference) | 89.7% |
| varVAMP, automatic threshold | 9 | 18 | 23 to 2,793 of 2,916 (its ambiguous consensus) | 95.0% |
| varVAMP, threshold 0.8 | 10 | 20 | 22 to 2,931 of 2,931 (its ambiguous consensus) | 99.3% |

The reference lengths differ because each engine builds its own design reference, and varVAMP builds a different consensus for different thresholds, so none equals the alignment's 2,953 columns. Read the table as a trade. PrimalScheme matched every allele exactly and paid for it in oligos. Olivar kept one oligo per primer site and paid for it wherever no primer site was free of variation. varVAMP covered the most sequence, 99.3 percent at threshold 0.8, and used the fewest oligos, 18 at its automatic threshold. At 0.8 it used 20, level with Olivar, and it paid by letting two of the twelve alleles mismatch at some primer positions, since that run's advisory says 10 of 12 sequences must agree.

The procedure below runs all three, because the comparison is the lesson. For your own target, the first table's last two columns settle the choice. To design one primer pair rather than a scheme, use Primer3, as [Designing a PCR Assay](02-designing-a-pcr-assay.md) shows.

## Before you start

You need the Primer Design demo project open, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. This chapter uses `mamu-a1-panel` under `Reference Sequences`, and the same sequences are in the [mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-primer-design).

Install two [plugin packs](../../GLOSSARY.md#plugin-pack) from **Tools > Plugin Manager…**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The Multiple Sequence Alignment pack runs MAFFT, an alignment program, and the PCR Primer Design pack, about 2.8 GB, carries all four design engines, the three here and Primer3. Each engine's first run prepares its own programs, and the [Operations Panel](../../GLOSSARY.md#operations-panel) shows "Checking *Tool* runtime…" on every run, with a "Preparing *Tool* *version*…" step on the first.

Each engine accepts an alignment bundle, an uncompressed aligned nucleotide [FASTA](../../GLOSSARY.md#fasta) file, or a [reference bundle](../../GLOSSARY.md#reference-bundle) that holds a single sequence, which it reads as a one-row alignment, the way to tile one genome. The `mamu-a1-panel` reference bundle holds twelve sequences, so the dialog lists it but the run stops with a message to import the sequences as an alignment first, which the procedure's first step does. PrimalScheme reads each U as T, so RNA sequence works, and it treats an N, a base the sequencer could not call, as a gap, meaning missing data, unless a combined-panel option keeps it. It designs on renamed rows and records which input row became which, so results trace back to your allele names. Expect each design to take from about half a minute to a little over two minutes.

## Procedure

### Align the twelve alleles

If you already made the alignment in [Designing a PCR Assay](02-designing-a-pcr-assay.md), skip to Run PrimalScheme.

1. Click `mamu-a1-panel` under `Reference Sequences`, choose **Tools > Alignment & Phylogenetics > MAFFT…**, and run it at its default settings.
2. Click the new alignment under `Analyses/Multiple Sequence Alignments/`, which is also named `mamu-a1-panel`, and check that the [Inspector](../../GLOSSARY.md#inspector), the right-hand pane that describes whatever is selected, shows 12 for **Sequences** and 2953 for **Aligned Columns**.

### Run PrimalScheme

1. Click the `mamu-a1-panel` alignment in the [sidebar](../../GLOSSARY.md#sidebar), then choose **Tools > PCR Primer Design > PrimalScheme…**. The dialog takes its inputs from the sidebar selection and has no button to add one later.
2. Under **Selected project inputs**, check that the alignment is listed with the line "12 alignment rows included". If the section instead asks you to select bundles in the sidebar, cancel, select the alignment, and reopen the dialog.
3. Under **Scheme settings**, leave **Output grouping** at "One scheme per MSA", the amplicon sizes at 360, 400 and 440, and **Primer pools** at 2. Leave **Advanced settings** collapsed.

    <!-- SHOT: tiled-primalscheme-dialog -->

4. Under **Save analysis**, replace the **Analysis name** with `Mamu-A1 tiled PrimalScheme`, check that the status line reads "Ready. Progress will appear in Operations.", and click **Run**. The Operations Panel shows a row titled "PrimalScheme · Mamu-A1 tiled PrimalScheme", and when it reports "Primer analysis saved." LGE opens the new analysis.

### Run Olivar

1. Select the alignment again and choose **Tools > PCR Primer Design > Olivar…**.
2. Read the mode line, which names tiled amplicons as Olivar's only mode, and the pool line, which says Olivar's own behavior is two tiled pools.
3. Leave the amplicon sizes at 360, 400 and 440, name the analysis `Mamu-A1 tiled Olivar`, and click **Run**.

### Run varVAMP twice

1. Select the alignment and choose **Tools > PCR Primer Design > varVAMP…**.
2. Check that **Design mode** is "Tiled amplicons", whose caption reads "Design a tiled two-pool amplicon scheme." Leave the threshold field, labeled "Cumulative consensus threshold (blank = native automatic)", empty so varVAMP picks the threshold itself.
3. Leave the amplicon sizes as they are, name the analysis `Mamu-A1 tiled varVAMP`, and click **Run**.
4. Select the alignment again, because LGE opens each new analysis, and reopen the dialog on varVAMP. Type `0.8` in the threshold field, which asks that at least 80 percent of the sequences, 10 of the 12, carry a base before it is written plainly, name the analysis `Mamu-A1 tiled varVAMP threshold 0.8`, and click **Run**. [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) explains why this second run reaches further.

<!-- SHOT: tiled-varvamp-threshold -->

### Save a design as a primer scheme

This example saves the varVAMP threshold 0.8 design, which has the highest coverage and whose consensus reference shows what the save sheet warns about.

1. Click the analysis you want to use, here `Mamu-A1 tiled varVAMP threshold 0.8`, open its **Results** tab, and click **Save as Primer Scheme…**. The same button sits on the View tab of the Inspector, and when it is dimmed the caption beneath gives the reason.
2. Read the sheet before saving. Its summary line gives the engine and the counts of primers, amplicons and pools, and under **Coordinate reference** it names the sequence the scheme's coordinates belong to and states which reads can be trimmed with it.
3. **Scheme name** defaults to the analysis name, then the result's label, then the word scheme, so here it reads "Mamu-A1 tiled varVAMP threshold 0.8 varvamp tiled scheme". A result is one saved design inside an analysis. Shorten the name if you like, click **Save**, and an operation titled "Save as Primer Scheme" writes the scheme under `Primer Schemes` in the sidebar. [Saving a designed scheme](../appendices/primer-schemes.md#saving-a-designed-scheme) documents what the bundle holds.

<!-- SHOT: tiled-save-scheme-sheet -->

## Settings

The controls **Minimum base frequency**, **Backtrack when extending the scheme**, **Use high-GC design settings**, **Search effort**, **Random seed**, **Maximum primer ambiguities** and **Tiled overlap (bp)** sit under **Advanced settings**, and the others in **Scheme settings** or **Save analysis**. Skip the command-line flag that ends most entries if you work only in the app. [Primer Design Settings](../appendices/primer-design-settings.md#primalscheme) carries every other control, including the mispriming database check, which looks for other places in your input sequences where a primer could bind, and the combined-panel controls.

**Output grouping.** Chooses between "One scheme per MSA", which designs each selected alignment on its own, and "Combined scheme from selected MSAs", which designs one panel across several, and the caption beneath says what Combined means for the chosen engine. The default is one scheme per alignment, the right choice for a single gene. Choose Combined only for PrimalScheme or Olivar when several genes must share one pair of reactions, since varVAMP shows the picker dimmed, and read [Combined panels](../appendices/primer-design-settings.md#combined-panels) first. On the command line this is `--grouping`.

**Minimum amplicon size (bp).** Sets the shortest amplicon the design aims for, measured on the design reference from the outer end of the forward primer to the outer end of the reverse primer, and PrimalScheme keeps to it while Olivar and varVAMP can keep an amplicon a few bases shorter and warn about it. The default is 360, 90 percent of the 400-base target amplicon size. Raise it with the target for long-read runs, and lower it for degraded DNA or short reads, keeping Olivar's floor of 120 in mind. On the command line this is `--amplicon-size-min`.

**Target amplicon size (bp).** Gives the nominal amplicon length, the number the default bounds start from, and its caption says selection does not favor the size closest to it, so the two bounds are what the engines work to. The default is 400, and editing it resets any bound you have not edited yourself to 90 and 110 percent of the new value. Change the bounds rather than the target when you mean to change what is designed. On the command line this is `--amplicon-size`.

**Maximum amplicon size (bp).** Sets the longest amplicon the design aims for, primers included, and PrimalScheme keeps to it while Olivar and varVAMP can keep an amplicon a few bases longer and warn about it. The default is 440. Raise it to let an amplicon reach over a variable stretch that holds no usable primer site, as long as your reads still span the longer product. On the command line this is `--amplicon-size-max`.

The line under the three size fields restates the size range that will be saved, which for these settings reads 360 to 440 bp, inclusive of both primer sites, and PrimalScheme accepts a nominal target only between 100 and 2,000 bases.

**Primer pools.** Sets how many reactions PrimalScheme splits its primers across. The default is 2, the smallest number that keeps overlapping neighbors apart. Keep 2 for a tiled scheme. On the command line this is `--pool-count`.

**Minimum base frequency.** Sets the share of the sequences that must carry a base at a primer site before PrimalScheme makes an oligo for it. The default is 0, so every variant gets its own oligo, which is why this design needed 49. Raise it, for example to 0.1, which asks for at least 10 percent of the sequences, to drop oligos for variants carried by few, accepting that those sequences will carry a mismatch. On the command line this is `--minimum-base-frequency`.

**Backtrack when extending the scheme.** Lets PrimalScheme revisit earlier amplicon choices when it cannot place the next one. It is off by default, which is faster. Turn it on when a design stops short of the end of the alignment. On the command line this is `--backtrack`.

**Use high-GC design settings.** Switches PrimalScheme to its own settings for GC-rich targets. It is off by default. Try it when a GC-rich target such as MHC leaves gaps with the standard settings. On the command line this is `--high-gc`.

**Search effort.** Multiplies how many candidate layouts Olivar tries. The default is 1. Raise it when coverage falls short, at the cost of a longer run. On the command line this is `--effort`.

**Random seed.** Sets the starting point of Olivar's random search, so the same inputs give the same design. The default is 10. Change it to try a different layout when coverage falls short, and record the seed you used. On the command line this is `--seed`.

**Design mode.** Chooses between varVAMP's "Single amplicon", "Tiled amplicons" and "qPCR / dPCR primers + probe". The default is Tiled amplicons. Choose Single for one product that amplifies every allele and qPCR for a detection assay, which [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers. On the command line this is `--mode`.

**Cumulative consensus threshold.** Sets the share of the sequences that must carry a base before varVAMP's consensus writes it plainly rather than as an ambiguity code, and the caption beneath warns that with few sequences it works in whole-sequence steps, which for twelve sequences means steps of about 8.3 percentage points. It is blank by default in tiled mode, which lets varVAMP choose and report the value it used. Lower it when coverage falls short. On the command line this is `--consensus-threshold`.

**Maximum primer ambiguities.** Limits how many ambiguity codes one primer may contain. The default is 2, varVAMP's own value, because each code multiplies the number of sequences in the synthesized mixture. Raise it to 3 to let primers sit in more variable stretches of the alignment, and lower it to 0 or 1 when you want plain primers. On the command line this is `--maximum-primer-ambiguities`.

**Tiled overlap (bp).** Sets how many bases neighboring amplicons must share, so that reads from both cover them and link the two into one continuous sequence. The default is 25, varVAMP's own value. Raise it so that a failed amplicon leaves fewer bases unread, because its neighbors reach further into it, at the cost of more amplicons. On the command line this is `--tiled-overlap`.

**Analysis name.** Names the primer analysis bundle in the project's `Analyses` folder. The default is "Primer analysis", with a number added when that name is taken, and a name you type that is already in use blocks Run. Give every run its own name, as the procedure does, so the sidebar tells the runs apart. On the command line this is `--name`.

## Reading the results

Click the analysis under `Analyses` and read its **Overview** tab. There is one card per design reference. The large number is coverage, the design percentage defined above, with a label beneath naming what was measured, which reads "Reference spanned by amplicons" for PrimalScheme and "Generated reference spanned by tiled assays" for Olivar and varVAMP. The first of the card's notes is always visible, and "What this coverage figure does and does not mean" opens the rest. They say that overlapping amplicon spans count once, that primer sequences sit inside the spans, and, for PrimalScheme, that covering a position does not show that every allele is covered or that its amplicon amplifies. A line beneath gives the same thing in bases, both covered and outside every saved amplicon span.

<!-- SHOT: tiled-primalscheme-overview -->

The amplicon track below pictures the scheme. It has one lane per pool, labeled "Pool 1" and "Pool 2", ruled from 1 to the length of the reference. Each amplicon is a bar whose tooltip gives its span, length and pool. Forward primers are drawn in blue and reverse primers in orange.

The card can also carry advisories, each marked as information or as a warning. varVAMP adds an information note naming the consensus threshold it used, and below 95 percent coverage in tiled mode the longest-chain warning that [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) quotes. varVAMP and Olivar each treat the size bounds as a search target rather than a rule, so either can keep an amplicon outside them, and the card then warns and names each such amplicon with its length. A combined PrimalScheme panel adds a warning to each reference under 90 percent coverage, because PrimalScheme skips any amplicon whose primers would form a dimer with primers already in the pool.

<!-- SHOT: tiled-varvamp-advisory -->

Read the covered span against the exon positions given earlier, which come from the public record of `LR699574.1`, because coverage counts the primer sites themselves and primer trimming removes those bases from the reads. For your own gene, use your reference's annotation. PrimalScheme's span starts at base 208 of row 1, three bases into exon 2, which runs from 205 to 474. So exon 1, at 2 to 74, lies in no amplicon, and neither do bases 205 to 207. Trimming then removes the first primer's bases, so the first exon 2 base you can read lies a primer length past base 208. If you need exon 1, that is a hole rather than coverage, and a laboratory would add a separate amplicon for it or accept the loss.

The **Results** tab lists every oligo, grouped by pool, with its length, GC content, role, sequence and position. An oligo built from degenerate bases shows "GC varies" instead of a percentage and carries an orange line counting its ambiguous bases, a reminder that it is ordered as a mixture, so ask your supplier whether it accepts that many codes in one oligo. A varVAMP primer such as `TGTSTYCCGGTCCCAATACT` holds two, S standing for C or G and Y for C or T. PrimalScheme's oligos are the opposite case. One primer site can carry several, named `_LEFT_1`, `_LEFT_2` and so on, and the viewer groups them as "Selected primer set" with the reminder that all of them are components you order together, not ranked alternatives. The numbers are labels, and they do not pair one forward oligo with one reverse oligo.

The **Binding inspection** tab is where you check what a primer does to each allele, as [Inspect binding against the alignment](05-reviewing-and-ordering-primers.md#inspect-binding-against-the-alignment) shows. The Inspector holds the rest of the record, and its Files tab lists every file with a [checksum](../../GLOSSARY.md#checksum), a fingerprint of the file's contents.

### What the saved scheme holds

A scheme written by **Save as Primer Scheme…** is a `.lungfishprimers` bundle in the project's `Primer Schemes` folder. Besides `primers.bed` and `primers.fasta` it holds a [manifest](../../GLOSSARY.md#manifest), the list of its contents, [provenance](../../GLOSSARY.md#provenance), the record of how it was made, and `attachments/design-reference.fasta`, which [Saving a designed scheme](../appendices/primer-schemes.md#saving-a-designed-scheme) documents with the rest. That attachment is the point to understand, because the coordinates in `primers.bed`, a [BED](../../GLOSSARY.md#bed) table of primer positions, belong to the engine's design reference, not to whatever [accession](../../GLOSSARY.md#accession), a database's identifier for a sequence, you might map reads to out of habit.

Reads must be mapped to `attachments/design-reference.fasta`, or to an identical sequence, before the scheme can trim them. PrimalScheme's design reference is a real sequence, here `LR699574.1`, while varVAMP's is a consensus whose ambiguity codes a mapper scores as mismatches, so a varVAMP scheme is harder to use downstream. Mapping to another row of the alignment does not work, because primer trimming looks for the scheme's own reference name in the alignment file and stops with an error when it is missing.

To trim, import `attachments/design-reference.fasta` from inside the scheme's bundle in `Primer Schemes` as a reference bundle, using the **Reference Sequences** card of **File > Import Center…**, as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md#import-the-record) shows. Then map your reads to it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, and trim as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md#trimming-with-a-designed-scheme) shows, choosing the scheme under "In This Project" in the Primer Scheme menu.

## What good looks like

Treat 90 percent coverage as the bar for a tiled design on a variable gene, the line under which LGE warns on a combined PrimalScheme panel, or 95 percent for varVAMP, the line under which its warning appears, and below the bar follow the tuning section at the end of this part. The amplicon track should show the bases outside every amplicon at the two ends rather than in the middle, because a gap in the middle means a region with no usable primer site, and the covered-bases line gives only how many such bases there are. Read the span against your gene's exons, as above, and confirm that nothing you must read sits under a primer.

Check the oligo count against the amplicon count. Two oligos per amplicon is the plain case, as Olivar's 20 over 10 amplicons shows, and PrimalScheme's 49 over 8 reflects its extra oligos for variant primer sites and tells you what the order will cost. An amplicon named in a size-range warning is kept in the scheme, so check its length against your protocol, since two 250-base paired reads span at most 500 bases.

Open **Binding inspection** and step through a few primers, especially any sitting in exon 2 or exon 3, which encode the class I groove. A primer with a mismatch within the last three to five bases of its 3′ end may fail to copy an allele you must detect, and an animal carrying that allele could lose its reads, as [When the target varies](01-what-is-primer-design.md#when-the-target-varies) explains. The varVAMP scheme saved at threshold 0.8 is the case in point, since two of the twelve alleles mismatch at some primer positions by design. That is acceptable when those mismatches sit at a primer's 5′ end and not when they sit at its 3′ end.

Last, read the reference statement on the save sheet and write it into your protocol, so that a colleague maps reads to the design reference, because a sequence the scheme does not declare stops the trim with an error.

### Tuning a scheme that covers too little

Read the coverage percentage on the **Overview** tab first. When it is lower than you want, the response depends on the engine.

With varVAMP, coverage below 95 percent in tiled mode adds a warning to the Overview card, and its wording says what to do.

```text
varVAMP keeps only the longest unbroken chain of overlapping amplicons.
Regions it cannot link are left uncovered instead of starting a second
chain. Wider amplicon size bounds, a lower consensus threshold or more
allowed ambiguous bases usually close these gaps.
```

The automatic run on this alignment reached 95.03 percent, just above the line where LGE adds that warning, so only the threshold advisory quoted below appears on its card, plus any size-range warning. Lowering the threshold is usually the strongest lever on a variable target, so it comes first.

```text
Consensus threshold 0.99, chosen automatically by varVAMP. A base counts
as conserved only when 12 of 12 sequences agree. Any threshold from 0.92
to 1.00 gives the same consensus for this alignment.
```

The run at 0.8 reported instead that a base counts as conserved only when 10 of 12 sequences agree, and that any threshold from 0.76 to 0.83 gives the same consensus for this alignment. Single-allele differences then produce no codes, and coverage reached 99.3 percent. The price is that the alleles in the minority at those columns carry a mismatch, which you check in **Binding inspection**.

Widening the amplicon bounds is the next lever, as long as your reads can span the longer product, and raising **Maximum primer ambiguities** from 2 to 3 is the third, at the cost of a more complex oligo mixture. More sequences make the threshold finer rather than looser. With twelve sequences each step is one twelfth, so 0.8 asks for 10 to agree. With sixty alleles the same 0.8 asks for 48 to agree, so up to twelve alleles can differ at a column without forcing an ambiguity code, where twelve sequences allow only two.

With PrimalScheme, low coverage probably means it could not place amplicons across a region, not that it avoided variation, since it makes an oligo per variant. Turn on **Backtrack when extending the scheme**, then try **Use high-GC design settings** on a GC-rich target, and widen the bounds. Raising **Minimum base frequency** cuts the oligo count and can also raise coverage, because at 0 one sequence with a gap, an unreadable base or a stretch that cannot make a usable primer makes PrimalScheme reject the site, while a higher value ignores sequences that make up less than that share, which then carry a mismatch. With Olivar, raise **Search effort**, try another **Random seed**, and widen the bounds, since its layout comes from a random search over risk scores.

## On the command line

This section is optional. Type each block into Terminal as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, including `lungfish-cli`, the `PROJECT=` line and the backslashes that continue a long command, and find the flags under [Primer schemes and primer design](../appendices/cli-reference.md#primer-schemes-and-primer-design). These commands reproduce the three tiled designs and save one as a scheme.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Primer Design.lungfish"
ALIGN="$PROJECT/Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa"

lungfish-cli primers design primalscheme3 \
  --msa "$ALIGN" \
  --amplicon-size 400 --amplicon-size-min 360 --amplicon-size-max 440 \
  --pool-count 2 \
  --project "$PROJECT" --name "Mamu-A1 tiled PrimalScheme"

lungfish-cli primers design olivar \
  --msa "$ALIGN" \
  --amplicon-size 400 --amplicon-size-min 360 --amplicon-size-max 440 \
  --project "$PROJECT" --name "Mamu-A1 tiled Olivar"

lungfish-cli primers design varvamp \
  --msa "$ALIGN" --mode tiled --consensus-threshold 0.8 \
  --amplicon-size 400 --amplicon-size-min 360 --amplicon-size-max 440 \
  --project "$PROJECT" --name "Mamu-A1 tiled varVAMP threshold 0.8"

lungfish-cli primers scheme-from-analysis \
  "$PROJECT/Analyses/Mamu-A1 tiled varVAMP threshold 0.8.lungfishprimeranalysis" \
  --project "$PROJECT" \
  --output "Mamu-A1 tiled varVAMP threshold 0.8"
```

`--project` and `--name` write each bundle into the project's `Analyses` folder as the dialog does. When the name is already in use the command takes the next free one, such as `Mamu-A1 tiled varVAMP threshold 0.8 2`, and reports the path it wrote, so give `scheme-from-analysis` the path printed for the varVAMP run. Leave out `--consensus-threshold` for varVAMP's automatic choice, which is what the blank field in the dialog does. The varVAMP and Olivar commands print the card's advisories, including any size-range warning, as `[info]` and `[warning]` lines. Run `primers scheme-from-analysis` with `--list` first to see which results can be saved and why any cannot, and pass `--result-id` when an analysis holds more than one saved result.

## Next

Continue to [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md), which designs a detection assay with a probe and then makes it specific. [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) turns any of these designs into an order, and [Primer Scheme Bundles](../appendices/primer-schemes.md) documents the bundle a saved scheme writes.
