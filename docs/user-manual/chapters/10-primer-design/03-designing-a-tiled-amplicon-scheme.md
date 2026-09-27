---
title: Designing a Tiled Amplicon Scheme
chapter_id: 10-primer-design/03-designing-a-tiled-amplicon-scheme
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 02-sequences/04-aligning-sequences, 01-foundations/03-amplicon-vs-shotgun]
estimated_reading_min: 35
task: Design overlapping two-pool amplicons that cover a whole gene across many alleles with PrimalScheme, Olivar or varVAMP, then save the design as a primer scheme for trimming.
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
    caption: "The Overview tab of the Mamu-A1 tiled PrimalScheme analysis, showing the coverage percentage, the covered-bases line, and the amplicon track with Pool 1 and Pool 2 lanes."
  - id: tiled-varvamp-advisory
    caption: "The Overview tab of the Mamu-A1 tiled varVAMP threshold 0.8 analysis, showing the information advisory that reads 10 of 12 sequences must agree."
  - id: tiled-save-scheme-sheet
    caption: "The Save as Primer Scheme sheet for the varVAMP threshold 0.8 analysis, showing the summary line, the Coordinate reference name and statement, and the Scheme name field."
illustrations: []
glossary_refs: [amplicon, primer, primer-pool, primer-scheme, primer-trim, tiling, msa, alignment-column, consensus-sequence, iupac-ambiguity-code, bed, mhc, allele, exon, intron, bundle, reference-bundle, inspector, operations-panel, plugin-pack, read-length, mapping]
features_refs: [bam.primer-trim]
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A tiled amplicon scheme is a set of primer pairs whose products overlap end to end, so that together they cover a long stretch of DNA that no single short product could. An [amplicon](../../GLOSSARY.md#amplicon) is the piece of DNA one primer pair copies by PCR. [Tiling](../../GLOSSARY.md#tiling) lays many amplicons along the target like roof tiles, each one overlapping its neighbours, as [Multiplexing, pools and tiling](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains.

Neighbouring amplicons cannot share one reaction tube. Where two amplicons overlap, the forward primer of the right-hand amplicon sits just inside the reverse primer of the left-hand one. In one tube those two primers would copy the short overlap between them, and that short product would win the race for reagents. A scheme therefore splits its primers into two [primer pools](../../GLOSSARY.md#primer-pool), the numbered reactions each primer belongs to, with odd-numbered amplicons in pool 1 and even-numbered ones in pool 2. Each sample is amplified in both tubes, and the products are combined before library preparation.

Lungfish Genome Explorer (LGE) designs tiled schemes with three engines, PrimalScheme, Olivar and varVAMP, all opened from **Tools > PCR Primer Design**. Each one reads a [multiple sequence alignment](../../GLOSSARY.md#msa) of the target, finds primer sites, and chains amplicons along it. They differ in how they deal with sites where the aligned sequences disagree, which is the main subject of this chapter. LGE saves each design as a primer analysis bundle in the project's `Analyses` folder. A tiled design can then be saved as a [primer scheme](../../GLOSSARY.md#primer-scheme), the `.lungfishprimers` bundle that [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) uses to clip primer bases out of mapped reads.

## Why you would do this

Suppose your laboratory wants the full genomic sequence of Mamu-A1, a rhesus macaque [MHC](../../GLOSSARY.md#mhc) class I gene about 3,000 bases long, from every animal in a colony. One primer pair around the whole gene is one option, and the full-length route in [Running genotyping](../09-genotyping/02-running-genotyping.md#6-what-changes-on-the-full-length-ont-route) sequences such products on Oxford Nanopore instruments, which read thousands of bases at a stretch. Short-read instruments cannot read a 3,000 base product end to end. An Illumina paired-end run reads at most a few hundred bases from each end of a fragment, as [Read length](../../GLOSSARY.md#read-length) describes. Long products also amplify poorly from degraded or low-quantity DNA. A tiled scheme answers both problems. With amplicons of about 400 bases, each product is short enough for paired 250-base reads to overlap across its middle, and a nanopore run reads each amplicon whole. This is the same design idea the ARTIC network made standard for sequencing whole viral genomes directly from patient samples.

MHC genes make this hard. They are among the most variable genes in any vertebrate genome, so a primer that matches one allele can carry mismatches against the next. They are rich in G and C bases, which makes primers bind strongly and fold on themselves. And Mamu-A1 has paralogs, related genes such as Mamu-A2, A3, A4 and Mamu-B that share much of its sequence, so a primer can bind a gene you did not intend to copy.

Allele names in this chapter follow the IPD-MHC nomenclature ([Tool Bibliography](../appendices/bibliography.md#primer-design-background)). In Mamu-A1\*001:01:01:01, "Mamu" names the species *Macaca mulatta* and "A1" the gene. The first field after the asterisk, 001, is the lineage, a group of closely related [alleles](../../GLOSSARY.md#allele). The second field marks alleles that encode different proteins, the third marks DNA differences that leave the protein unchanged, and the fourth marks differences outside the coding sequence.

The Primer Design demo project holds twelve genomic Mamu-A1 alleles, one from each of twelve lineages, from 2,920 to 2,943 bases long. Aligned, they span 2,953 columns. The first row is LR699574.1, the allele Mamu-A1\*001:01:01:01, 2,933 bases long, whose record places [exon](../../GLOSSARY.md#exon) 1 at bases 2 to 74, exon 2 at 205 to 474 and exon 3 at 718 to 993. Exons 2 and 3 encode the groove that holds peptides for the immune system and carry most of the allelic variation. The goal of this chapter is a scheme of about 400 base amplicons in two pools that covers as much of the gene as possible in all twelve alleles.

## Choosing a tool

All three engines tile an alignment into two pools. What separates them is how each handles a site where the alleles differ, and that is the property of your data that settles the choice. [When the target varies](01-what-is-primer-design.md#when-the-target-varies) introduces the problem.

**PrimalScheme** adds an oligo for every variant. It was built for tiled sequencing of whole viral genomes from clinical samples ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)), and LGE runs an LGE build of PrimalScheme 3, version 3.3.0+lge.5, whose method is described in the PrimalScheme 3 preprint ([Method papers](../appendices/bibliography.md#method-papers)). At each candidate site it collects every distinct sequence the aligned alleles carry there and makes one exact-match oligo, a short synthetic DNA strand, for each. A site is then covered by a small cloud of primers that are all ordered and mixed into the same pool. It walks along the alignment choosing overlapping amplicons, alternating pools, and refuses any oligo that would pair with an oligo already in its pool. The strength is that every sequence in the alignment gets a perfect match at every site. The cost is oligo count. On this chapter's alignment it used 49 oligos for 16 primer sites, with up to 7 at one site, and each variant oligo makes up a smaller share of its pool.

**Olivar** avoids variable sites. It was built for tiled sequencing of pathogen genomes ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It scores every base of the target for risk, adding up how variable the base is across the alignment, whether its surroundings are extremely GC-rich or GC-poor, whether it sits in low-complexity sequence such as a repeat, and, when you give it a BLAST database, whether the region also matches other sequences. It then samples many possible layouts of primer sites and keeps the one with the lowest total risk. Inside those sites it picks the primers with SADDLE, a search that lowers the chance of [primer dimers](01-what-is-primer-design.md#hairpins-and-primer-dimers) across each whole pool ([Method papers](../appendices/bibliography.md#method-papers)). It places one oligo per site and, as LGE runs it by default, no degenerate bases. The strength is a small, clean pool with dimers checked across all of it. The limit is that where no site is free of variation, some alleles carry a mismatch under a primer.

**varVAMP** writes the variation into the primer. It was built for pan-specific primers on very diverse viruses ([Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It first builds a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of the alignment with a consensus threshold. At each column, if one base is carried by enough sequences to reach the threshold it is written as that base. Otherwise the commonest bases are pooled until they reach the threshold and are written as one [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code), a letter such as S for C or G. A primer taken from that consensus is degenerate, meaning it is synthesised as a mixture of sequences, as [Degenerate bases and what they cost](01-what-is-primer-design.md#degenerate-bases-and-what-they-cost) explains. varVAMP allows at most two ambiguous bases per primer by default and none in the last three bases at the 3′ end. It then links candidate amplicons into the longest chain of overlapping amplicons it can find, split into two pools. The strength is few oligos, one per site, that still match most alleles. The limit is that it keeps only one unbroken chain, so a stretch with no usable primer site ends the scheme there rather than starting a second chain.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| PrimalScheme | Tiled viral genomes, variation absorbed by extra exact-match oligos | Every allele must match every primer exactly and a larger oligo order is acceptable | Diversity is so high that sites need many oligos each |
| Olivar | Tiled pathogen genomes, low-risk sites and pool-wide dimer checks | Dimers or off-target binding are the main worry and you want one plain oligo per site | Some alleles must not carry any primer mismatch |
| varVAMP | Tiled or single amplicons on diverse genomes, degenerate consensus primers | You want few oligos that tolerate variation through ambiguity codes | Coverage stops short and the single-chain limit cannot be tuned away |

All three were run on the twelve-allele Mamu-A1 alignment with 400 base amplicons, bounds of 360 to 440 bases, and two pools.

| Engine | Amplicons | Oligos | Span on its design reference | Coverage | Run time |
|---|---|---|---|---|---|
| PrimalScheme (3.3.0+lge.5) | 8 | 49, over 16 primer sites, up to 7 at one site | 207 to 2,876 of 2,933 (row 1, LR699574.1) | about 91% | 136 s |
| Olivar | 10 | 20, one per site | 75 to 2,705 of 2,934 (Olivar's own reference) | about 90% | 82 s |
| varVAMP, automatic threshold | 9 | 18 | BED 22 to 2,793 on its ambiguous consensus | 95.03% | 25 s |
| varVAMP, threshold 0.8 | 10 | 20 | BED 21 to 2,931 on its ambiguous consensus of 2,931 bases | 99.28% | 24 s |

Coverage is the share of the engine's design reference that lies inside at least one amplicon, and each engine measures it on a different reference, as [Reading the results](#reading-the-results) explains. BED coordinates count from 0, so BED 22 is base 23. Read the table as a trade. PrimalScheme matched every allele exactly and paid for it in oligos. Olivar kept one oligo per site and paid for it in mismatches wherever no site was free of variation. varVAMP covered the most sequence with the fewest oligos, and at threshold 0.8 it paid by letting two of the twelve alleles mismatch at some primer positions.

The procedure below runs all three, because the comparison is the lesson. For your own gene, start with PrimalScheme when every animal's allele must amplify evenly and the order size is acceptable. Start with varVAMP when you want a small order and can check each primer's mismatches afterwards. Start with Olivar when off-target products are the bigger risk, as with MHC paralogs, and you can supply a BLAST database of the sequences to avoid. To design one primer pair rather than a scheme, use Primer3, as [Designing a PCR Assay](02-designing-a-pcr-assay.md) shows.

## Before you start

You need a project open. Open the Primer Design demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds three reference bundles under `Reference Sequences`. This chapter uses `mamu-a1-panel`, the twelve Mamu-A1 alleles. The same sequences are in the [mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design), whose README gives each accession and allele.

Install two [plugin packs](../../GLOSSARY.md#plugin-pack), themed groups of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The Multiple Sequence Alignment pack runs MAFFT. The PCR Primer Design pack, about 2.8 GB, carries Primer3 2.6.1, PrimalScheme 3.3.0+lge.5, Olivar 1.3.3 and varVAMP 1.3.2. The first run of each engine prepares that engine's own environment, and the [Operations Panel](../../GLOSSARY.md#operations-panel) shows "Checking *Tool* runtime…" and then "*Tool* runtime ready" while it does.

The engines need an alignment, not loose sequences. The twelve alleles differ in length, so the reference bundle cannot go straight into the dialog. Align them first, as the first step of the Procedure does. Each design then takes between about half a minute and a little over two minutes on this alignment, as the comparison table shows.

## Procedure

### Align the twelve alleles

1. In the sidebar, click `mamu-a1-panel` under `Reference Sequences`.
2. Choose **Tools > Multiple Sequence Alignment > MAFFT...** and run it with its default settings, as [Aligning Sequences](../02-sequences/04-aligning-sequences.md#procedure) shows.
3. When the run finishes, find `mamu-a1-panel` under `Analyses/Multiple Sequence Alignments/`. Click it and check that the viewport shows 12 rows and 2,953 columns.

### Run PrimalScheme

1. Click the `mamu-a1-panel` alignment in the sidebar so it is selected, then choose **Tools > PCR Primer Design > PrimalScheme…**. The PCR Primer Design sheet opens with PrimalScheme chosen in the tool list on the left. The dialog takes its inputs from the sidebar selection and has no button to add one later.
2. Under "Selected project inputs", check that the alignment is listed with the line "12 alignment rows included". If the section instead asks you to select bundles in the sidebar, cancel, select the alignment, and reopen the dialog.
3. Under "Scheme settings", leave **Output grouping** at "One scheme per MSA", the amplicon sizes at 360, 400 and 440, and **Primer pools** at 2. Leave "Advanced settings" collapsed, since [Settings](#settings) explains what is inside.

    <!-- SHOT: tiled-primalscheme-dialog -->

4. Under "Save analysis", replace the **Analysis name** "Primer analysis" with `Mamu-A1 tiled PrimalScheme`, then check that the status line reads "Ready. Progress will appear in Operations." and click **Run**. The sheet closes and the Operations Panel shows a row titled "PrimalScheme · Mamu-A1 tiled PrimalScheme".
5. When the row reports "Primer analysis saved.", click `Mamu-A1 tiled PrimalScheme` under `Analyses` in the sidebar. The result does not open by itself.

### Run Olivar

Select the `mamu-a1-panel` alignment again and choose **Tools > PCR Primer Design > Olivar…**. Read the mode line, which says that the mode is tiled amplicons and cannot be changed, and the pool line, which says that Olivar's own behaviour is two tiled pools. Leave the amplicon sizes at 360, 400 and 440, name the analysis `Mamu-A1 tiled Olivar`, and click **Run**.

### Run varVAMP twice

Select the alignment and choose **Tools > PCR Primer Design > varVAMP…**. Check that **Design mode** is "Tiled amplicons", whose caption reads "Design a tiled two-pool amplicon scheme." Leave the threshold field, labelled "Cumulative consensus threshold (blank = native automatic)", empty so that varVAMP picks the threshold itself. Leave the amplicon sizes at 360, 400 and 440, name the analysis `Mamu-A1 tiled varVAMP`, and click **Run**.

Then open the dialog on varVAMP once more, type `0.8` in the threshold field, name the analysis `Mamu-A1 tiled varVAMP threshold 0.8`, and click **Run**. [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) explains why this second run reaches further.

<!-- SHOT: tiled-varvamp-threshold -->

### Save a design as a primer scheme

Click the analysis you want to use, here `Mamu-A1 tiled varVAMP threshold 0.8`, and open the Results tab at the top of the viewer. Click **Save as Primer Scheme…**. The same button sits in the [Inspector](../../GLOSSARY.md#inspector) on the View tab, and when it is dimmed the caption beneath it gives the reason, as [Troubleshooting](#troubleshooting) lists.

Read the sheet before saving. Its summary line gives the engine and the counts of primers, amplicons and pools. Under "Coordinate reference" it names the sequence the scheme's coordinates belong to and states which reads can be trimmed with it. Edit **Scheme name** if you like, since the default only joins the analysis name and the result's label. Click **Save**, and an operation titled "Save as Primer Scheme" writes the new scheme under `Primer Schemes` in the sidebar.

<!-- SHOT: tiled-save-scheme-sheet -->

## Settings

The three engines share the first group of settings. The rest belong to one engine each, and most sit under "Advanced settings", which is collapsed until you open it.

### Settings every engine shows

**Output grouping.** Chooses between "One scheme per MSA", which designs each selected alignment on its own, and "Combined scheme from selected MSAs", which designs one panel across several. The default is one scheme per alignment, the right choice for a single gene. Choose Combined only for PrimalScheme or Olivar when several genes must share one pair of reactions, and note that varVAMP shows the picker dimmed at the default. On the command line this is `--grouping`.

**Minimum amplicon size (bp).** Sets the shortest amplicon the design may keep, measured on the design reference from the outer end of the forward primer to the outer end of the reverse primer. The default is 360, 90% of the target. Raise it with the target for nanopore runs, and lower it for degraded DNA or short reads, keeping Olivar's floor of 120 in mind. On the command line this is `--amplicon-size-min`.

**Target amplicon size (bp).** Gives the nominal amplicon length. The default is 400, and editing it resets any size bound you have not edited yourself to 90% and 110% of the new value. Its caption calls the target nominal and says selection does not favour the closest size, which means the engines enforce only the two bounds, so change the bounds when you mean to change what is designed. On the command line this is `--amplicon-size`.

**Maximum amplicon size (bp).** Sets the longest amplicon the design may keep, primers included. The default is 440, 110% of the target. Raise it to let amplicons reach over a variable stretch that has no usable primer site, as long as your reads still span the longer product. On the command line this is `--amplicon-size-max`.

The line under the three size fields restates the span that will be saved, giving 360 to 440 bp for these settings and noting that both primer sites are inside it. LGE remembers the sizes separately for each engine. PrimalScheme accepts targets from 100 to 2,000 bases only.

**Analysis name.** Names the primer analysis bundle, saved in the project's `Analyses` folder with the extension `.lungfishprimeranalysis`. The default is "Primer analysis". A name already used in the project blocks Run with a message, so give every run its own name, as the Procedure does. This setting has no command-line flag, because `--output` takes the whole bundle path.

### PrimalScheme settings

**Primer pools.** Sets how many reactions the primers are split across. The default is 2, the smallest number that keeps overlapping neighbours apart. Keep 2 for a tiled scheme. On the command line this is `--pool-count`.

**Minimum overlap (bp).** Sets how many bases neighbouring amplicons must share. The default is 10, enough to join reads from neighbouring amplicons across the join. It appears only with one scheme per alignment, and a combined design always uses 10. On the command line this is `--min-overlap`.

**Backtrack when extending the scheme.** Lets PrimalScheme go back and change earlier amplicon choices when it cannot place the next one. It is off by default, which is faster. Turn it on when a design stops short of the end of the alignment. On the command line this is `--backtrack`.

**Ignore unknown bases (N).** Leaves `N` bases out of the site sequences PrimalScheme collects. It is off by default because the Mamu-A1 alleles contain no `N`. Turn it on when some of your sequences carry runs of `N` from low-quality sequencing. On the command line this is `--ignore-n`.

**Minimum base frequency.** Sets how common a base must be at a site before PrimalScheme makes an oligo for it. The default is 0, so every variant in the alignment gets its own oligo, which is why this design needed 49. Raise it, for example to 0.1, to drop oligos for variants carried by few sequences, accepting that those sequences will carry a mismatch. On the command line this is `--minimum-base-frequency`.

**CPU cores.** Sets how many processor cores PrimalScheme uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a large alignment to finish sooner. On the command line this is `--core-count`.

**Dimer score threshold.** Sets how strong an interaction between two oligos may be before PrimalScheme refuses to put them in one pool. The default is -26. A more negative value allows stronger interactions and so accepts more candidates, so change it only when a design fails because too many pairs are refused. On the command line this is `--dimer-score`.

**Check the primer mispriming database.** Checks each candidate against PrimalScheme's own database of sequences where a primer could also bind and make an unwanted product. It is on by default. Turn it off only to test whether it is the reason a design fails. On the command line, off is `--disable-matchdb`.

**Use high-GC design settings.** Switches PrimalScheme to its settings for GC-rich targets. It is off by default. Try it when a GC-rich target such as MHC leaves gaps with the standard settings. On the command line this is `--high-gc`.

**Treat alignment ends without data as missing observations.** Tells PrimalScheme that a sequence which stops before the end of the alignment has no data there, rather than a gap that counts against a primer. It is on by default, as its caption says, so shorter sequences do not block sites near the ends. Turn it off only to reproduce a design made with the older behaviour. On the command line this is `--terminal-gap-policy`, with `observed-only` for on and `legacy` for off.

**Choose verified executable….** Runs a PrimalScheme program you select instead of the one the pack installed. The default is the managed program, shown as "Managed runtime (legacy defaults)". Leave it alone unless a developer asks you to test a build. On the command line this is `--primalscheme3-path`.

A caption in the same section names the mapping reference, and it is a fact rather than a setting. PrimalScheme writes its coordinates on the first row of the alignment, here LR699574.1, so put the sequence you want coordinates on first when you build the alignment.

Six further controls appear only with "Combined scheme from selected MSAs", and a bench reader designing one gene never meets them. **Panel selection** either weights every position equally, the default, or favours amplicons that contain more variation. **Maximum panel amplicons** and **Maximum per MSA** cap the panel, and are blank by default. **Allow bounded dimer salvage** retries a failed panel with relaxed interaction limits, **Choose parent output…** starts a follow-up design that fills the gaps of an earlier combined panel, and a third control generates bounded candidates for the stretches the parent left out. The last three have no command-line flag.

### Olivar settings

Every Olivar control except the amplicon sizes lives under "Advanced settings" in a group named "Olivar native settings".

**CPU workers.** Sets how many processor cores Olivar uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a long alignment. On the command line this is `--workers`.

**Minimum variant frequency (--min-var).** Sets how common a difference between the aligned sequences must be before Olivar records it as a variant and treats that base as risky. The default is 0.01, so on twelve sequences even one differing allele counts. Raise it toward 0.1 to make Olivar ignore differences carried by a single sequence. On the command line this is `--minimum-variant-frequency`.

**Maximum primer length.** Sets the longest primer Olivar may build. The default is 36 bases, Olivar's own value, which is long because Olivar extends a primer until it reaches the required binding energy. Lower it when your synthesis supplier charges by length. On the command line this is `--maximum-primer-length`.

**Minimum complexity.** Rejects primers whose sequence is too repetitive, measured on a scale from 0 to 1. The default is 0.4, Olivar's own value, which excludes runs and simple repeats. Raise it when a design returns primers full of repeats. On the command line this is `--minimum-complexity`.

**Design degenerate oligos.** Lets Olivar build primers with ambiguity codes instead of one exact sequence per site. It is off by default, so Olivar's twenty oligos here are all plain sequences. Turn it on when too many alleles mismatch the plain primers, and expect the risk weights for sensitivity and combinations to start acting, since Olivar sets both to zero in plain mode. On the command line this is `--degenerate`.

**Avoid variants at binding sites.** Throws away any candidate primer with a variant in its last five bases at the 3′ end, the end that must match for DNA synthesis to start. It is off by default because, as Olivar's own documentation warns, turning it on when many variants are recorded leaves very few candidates. Turn it on for a target with only a few known differences. On the command line this is `--check-variants`.

**Minimum GC fraction and Maximum GC fraction.** Bound the share of G and C bases in a primer. The defaults are 0.2 and 0.75, Olivar's own values, written as fractions here while Primer3 and varVAMP use percentages. Narrow them toward 0.4 and 0.6 when primers bind unevenly, which matters in GC-rich MHC sequence. On the command line these are `--minimum-gc` and `--maximum-gc`.

**Temperature (°C).** Sets the annealing temperature Olivar assumes when it works out how strongly a primer binds. The default is 60, the temperature most PCR protocols use. Change it only to match a protocol that anneals somewhere else. On the command line this is `--temperature-c`.

**Salinity (M).** Sets the concentration of monovalent salt Olivar assumes, in moles per litre, because salt changes binding strength. The default is 0.18, Olivar's own value. Change it only for a reaction buffer you know differs. On the command line this is `--salinity-m`.

**Maximum dimer ΔG.** Sets the binding energy in kilocalories per mole a primer must reach, and so how far Olivar extends it. The default is -11.8, Olivar's own value, and a more negative number means stronger binding. Leave it alone unless Olivar's own documentation guides you otherwise. On the command line this is `--maximum-dimer-delta-g`.

**Random seed.** Fixes the starting point of Olivar's random search, so the same inputs give the same design. The default is 10, Olivar's own value. Change it to see whether a different search finds a better layout, and record the value you used. On the command line this is `--seed`.

**Search effort.** Multiplies how many candidate layouts Olivar tries. The default is 1. Raise it to 2 or more when coverage falls short, at the cost of a longer run. On the command line this is `--effort`.

**Native risk weights.** Six fields, Extreme GC, Low complexity, Non-specificity, Variation, Sensitivity and Combination, set how much each kind of risk counts when Olivar scores the target. All six default to 1. Raise Variation to push primers harder away from variable sites, or Non-specificity once you have supplied a BLAST database, and leave Sensitivity and Combination alone while degenerate design is off. On the command line these are `--risk-extreme-gc`, `--risk-low-complexity`, `--risk-non-specificity`, `--risk-variation`, `--risk-sensitivity` and `--risk-combination`.

**Local nucleotide BLAST database prefix (optional).** Names a local BLAST database whose sequences Olivar searches to find regions that also match somewhere else, which feeds the non-specificity risk. It is blank by default, so that risk contributes nothing. Set it to a database of the sequences you want to avoid, such as the Mamu class I paralogs, which is the main reason to choose Olivar for MHC work. On the command line this is `--blast-database`.

### varVAMP settings

**Design mode.** Chooses between "Single amplicon", "Tiled amplicons" and "qPCR / dPCR primers + probe". The default is Tiled amplicons, which is what this chapter uses. Choose Single for one pan-allele product, and qPCR for a detection assay, which [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers. On the command line this is `--mode`.

**Cumulative consensus threshold.** Sets how much agreement a base needs before the consensus writes it plainly rather than as an ambiguity code. Read it as "k of N sequences must agree", where N is the number of aligned sequences. It is blank by default in tiled mode, which lets varVAMP choose, and the saved analysis then reports the value it used. Lower it when coverage falls short, as [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) shows. On the command line this is `--consensus-threshold`.

The dialog's caption warns that with few sequences the threshold moves in whole-sequence steps, since one sequence out of twelve is more than eight percentage points. That is why the automatic run and a request of 0.95 give the same consensus here.

**CPU workers.** Sets how many processor cores varVAMP uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a long alignment. On the command line this is `--workers`.

**Maximum primer ambiguities.** Limits how many ambiguity codes one primer may contain. The default is 2, varVAMP's own value, because each code doubles or triples the number of sequences in the synthesised mixture. Raise it to 3 to let primers sit in more variable windows, and lower it to 0 or 1 when you want plain primers. On the command line this is `--maximum-primer-ambiguities`.

**Tiled overlap (bp).** Sets how many bases neighbouring amplicons must share. The default is 25, varVAMP's own value, wide enough to join reads across the overlap. Raise it for extra safety against one amplicon failing, at the cost of more amplicons. On the command line this is `--tiled-overlap`.

**Scheme name.** Names the scheme inside varVAMP's own output, which is where oligo names such as `varVAMP_0_LEFT` come from. The default is "varVAMP". Change it to tell two designs apart in an order sheet. On the command line this is `--scheme-name`.

**Compatible-primer input path (optional).** Points at a file of primers a new design must not interact with, so a second scheme can share a tube with an existing one. It is blank by default. Use it when you are extending a scheme you already ordered. On the command line this is `--compatible-primers`.

**Local nucleotide BLAST database prefix (optional).** Names a local BLAST database varVAMP searches for places its candidate primers could also bind and make an unwanted product. It is blank by default, so no off-target check runs. Set it when unwanted products are a risk, as with MHC paralogs. On the command line this is `--blast-database`.

The "Primer constraints" group repeats varVAMP's own primer rules, and LGE sends every one of them on every run. Length is 18, 21 and 24 bases as minimum, optimum and maximum, melting temperature 56, 60 and 63 °C, and GC content 35, 50 and 65%. Homopolymers, meaning runs of one base, and dinucleotide repeats are capped at 4, the hairpin melting temperature at 47 °C, the dimer melting temperature at 35 °C, and the last three bases at the 3′ end must be unambiguous, with 1 to 3 of the last five being G or C. Each has a command-line flag of the same name, listed in the [CLI Reference](../appendices/cli-reference.md). The fields under "Chemistry and masking defaults" match varVAMP's own values and show no units on screen. They are 100 and 2 millimolar for monovalent and divalent cations, 0.8 millimolar dNTP and 15 nanomolar primer. **Terminal masking threshold**, 0.5 by default, decides when a gap at the very start or end of the alignment is masked, so such a base is masked only when more than half the sequences are missing it.

The probe fields in "qPCR probe constraints" and the fields **Maximum probe ambiguities**, **Reported assays**, **qPCR test count** and **qPCR ΔG setting** belong to varVAMP's other modes, and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers them.

## Tuning a scheme that covers too little

Read the coverage percentage on the Overview tab first. When it is lower than you want, the response depends on the engine.

With varVAMP, coverage below 95% in tiled mode brings a warning onto the Overview card, and its wording says what to do.

```text
varVAMP keeps only the longest unbroken chain of overlapping amplicons.
Regions it cannot link are left uncovered instead of starting a second
chain. Wider amplicon size bounds, a lower consensus threshold or more
allowed ambiguous bases usually close these gaps.
```

Take those three in order, because lowering the threshold is the strongest lever on a variable target. The automatic run on this alignment chose 0.99, and the information advisory beside the warning read as follows.

```text
Consensus threshold 0.99, chosen automatically by varVAMP. A base counts
as conserved only when 12 of 12 sequences agree. Any threshold from 0.92
to 1.00 gives the same consensus
```

Every column where one allele differs then becomes an ambiguity code, few windows hold two or fewer of them, and the chain broke at 95.03% coverage. The run at 0.8 reported instead that a base counts as conserved only when 10 of 12 sequences agree, and that any threshold from 0.76 to 0.83 gives the same consensus for this alignment. Single-allele differences stopped producing codes, and coverage reached 99.28%. The price is that the alleles in the minority at those columns carry a mismatch, which you check in the binding inspection.

Widening the amplicon bounds is the next lever, because a longer amplicon can reach over a variable stretch that holds no usable primer site. On an earlier six-allele version of this alignment, the automatic threshold gave 66.6% coverage with bounds of 150 to 250 bases, a threshold of 0.8 gave 92%, and widening to 200 to 350 bases at the automatic threshold gave 98%. Only widen as far as your reads can span. Raising **Maximum primer ambiguities** from 2 to 3 is the third lever, and it costs you a more complex oligo mixture.

Adding sequences helps in a way that is easy to misread. With twelve sequences each threshold step is one twelfth, so the threshold is coarse. With sixty alleles the same 0.8 means 48 must agree, and one rare allele no longer forces an ambiguity code. More sequences also make the design honest, since twelve alleles do not represent a colony.

With PrimalScheme, low coverage means it could not chain amplicons through a region rather than that it avoided variation, since it makes an oligo per variant. Turn on **Backtrack when extending the scheme**, then try **Use high-GC design settings** on a GC-rich target, and widen the amplicon bounds. Raising **Minimum base frequency** cuts the oligo count rather than raising coverage. With Olivar, raise **Search effort**, try another **Random seed**, and widen the bounds, since its layout comes from a random search over risk scores.

Coverage never reaches 100% in a tiled design. The first forward primer and the last reverse primer sit inside the target, so the bases outside them are never inside an amplicon. On this alignment that accounts for the first 206 and the last 57 bases of PrimalScheme's span.

## Reading the results

Click the analysis under `Analyses` and read the Overview tab. There is one card per design reference. The large number is coverage, the share of that reference lying inside at least one amplicon, with a label beneath naming what was measured. For PrimalScheme it reads "Reference spanned by amplicons", and for Olivar and varVAMP "Generated reference spanned by tiled assays". Hovering the label shows the notes that keep the number honest, including that overlapping amplicon spans count once, that primer sequences sit inside the spans, and that positional coverage does not show that every allele will amplify. Beneath it a line gives the same thing in bases, both covered and outside every amplicon span.

<!-- SHOT: tiled-primalscheme-overview -->

The amplicon track below is the picture of the scheme. It has one lane per pool, labelled "Pool 1" and "Pool 2", ruled from 1 to the length of the reference. Each amplicon is a bar whose tooltip gives its span, length and pool. Forward primers are drawn in blue, reverse primers in orange, and probes, which a tiled design has none of, in purple. A gap in both lanes is a stretch the scheme does not cover.

varVAMP results also show advisories on the card, an information note for the threshold used and, below 95% coverage in tiled mode, the longest-chain warning quoted above.

<!-- SHOT: tiled-varvamp-advisory -->

The Results tab lists every oligo, grouped by pool, with its length, GC content, role, sequence and position. An oligo built from degenerate bases shows "GC varies" instead of a percentage and carries an orange line counting its ambiguous bases, a reminder to check how your supplier will synthesise it. A varVAMP primer such as `TGTSTYCCGGTCCCAATACT` holds two, S standing for C or G and Y for C or T. PrimalScheme's oligos are the opposite case. One site can carry several, named `_LEFT_1`, `_LEFT_2` and so on, and the viewer groups them as "Selected primer set" with the reminder that all of them are components you order together, not ranked alternatives. The numbers are labels, not quality ranks, and they do not pair one forward oligo with one reverse oligo.

The Binding inspection tab is where you check what a primer does to each allele. Choose a primer in "Compare primer" and read the mismatch table beneath the alignment. Its header gives the share of comparable rows that match, and each row reads either "0 mismatches (IUPAC-compatible)", a count of positional mismatches, or a reason the row cannot be assessed, such as an internal gap. This is a sequence comparison and not a prediction of amplification, as its tooltip says, but a primer with several mismatches against an allele you must detect is a primer to redesign.

The Inspector holds the rest of the record. Its Bundle tab names the grouping, the inputs, the results and the tool version. Its Files tab lists every file in the bundle with a checksum, including the engine's own outputs, which for Olivar include its risk plots. Its View tab hides and shows oligos in the viewport without changing the saved design, and holds the order export and the Save as Primer Scheme button.

### What the saved scheme holds

A scheme written by **Save as Primer Scheme…** or by `lungfish-cli primers scheme-from-analysis` is a `.lungfishprimers` bundle in the project's `Primer Schemes` folder, in the layout [Primer Schemes](../appendices/primer-schemes.md#bundle-layout) describes. It holds `primers.bed` with one line per oligo, `primers.fasta` with the sequences, `PROVENANCE.md` and the machine-readable provenance beside it, a `manifest.json`, and one attachment, `attachments/design-reference.fasta`.

That attachment is the point to understand. The BED coordinates belong to the engine's own design reference, not to whatever accession you might map reads to by habit. For PrimalScheme it is the first row of the alignment without its gaps, here LR699574.1. For Olivar it is the reference Olivar generated from the alignment, which is no single input allele. For varVAMP it is the ambiguous consensus, which contains IUPAC codes and matches no real sequence at all. The save sheet states this before you save, and the saved scheme repeats it. Reads must be mapped to `attachments/design-reference.fasta`, or to a sequence identical to it, before the scheme can trim them. Mapping to a consensus also means a mapper scores its ambiguity codes as mismatches at those positions.

With that in hand, trimming is the ordinary route. Import the design reference as a reference bundle, map your reads to it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, then trim with the scheme as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows. The scheme appears in that dialog's Primer Scheme menu under "In This Project". Check the trim rate in the run's log, which that chapter explains, because a low rate is the first sign the reads went to the wrong sequence.

## What good looks like

Coverage in the nineties on a variable gene is a good tiled design, and the covered-bases line should show the bases outside every amplicon sitting at the two ends rather than in the middle. A gap in the middle of the track means a region with no usable primer site, and the tuning section above is the response.

Check the oligo count against the amplicon count. Two oligos per amplicon is the plain case, as Olivar's 20 over 10 amplicons shows. PrimalScheme's 49 over 8 amplicons is not a fault, it is variant coverage, and the number tells you what the order will cost. A varVAMP oligo carrying more than two ambiguous bases should not appear at all under the default limit, so if one does, check the limit you set.

Open Binding inspection and step through a few primers, especially any sitting in exon 2 or exon 3. Every allele you must amplify should show zero mismatches, or mismatches only well away from the 3′ end. A primer that matches ten of twelve alleles is a primer that will lose two animals' sequences.

Last, read the reference statement on the save sheet and write it into your protocol. A scheme whose coordinates belong to a consensus sequence is easy to hand to a colleague who will map reads to a database accession and see almost nothing trimmed.

## On the command line

This section is optional. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. These commands reproduce the three tiled designs and save one as a scheme.

```bash
ALIGN="$HOME/Documents/Primer Design.lungfish/Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa"
PROJECT="$HOME/Documents/Primer Design.lungfish"

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

Leave out `--consensus-threshold` for varVAMP's automatic choice, which is what the blank field in the dialog does. The design commands print the advisories the Overview card shows, as `[info]` and `[warning]` lines after the written-to line. Run `primers scheme-from-analysis` with `--list` first to see which results can be saved and why any cannot, and pass `--result-id` when an analysis holds more than one saved result. The window runs this same command, and the Operations row records it.

One difference between the two routes is worth knowing. The dialog always sends both amplicon bounds, which puts PrimalScheme into its reference-span sizing. Leaving `--amplicon-size-min` and `--amplicon-size-max` off the command line uses a different, legacy sizing instead, so the same nominal 400 can give a different design. The commands above pass the bounds for that reason. `lungfish-cli primers analysis inspect` on a finished bundle checks its integrity and lists what it holds.

## Troubleshooting

**The dialog opens with no inputs.** The design dialog reads the sidebar selection when it opens and cannot add a file afterwards. Cancel, click the alignment in the sidebar, and choose the menu item again. Unsupported selections are dropped without a message, so a compressed FASTA, a GenBank record or a FASTQ file leaves the section empty too. Align loose sequences first, since these engines need equal-length rows.

**Run stays disabled.** Read the status line at the foot of the sheet, which shows the first problem. An analysis name already used in the project blocks Run, and so does a name holding a path separator. Amplicon sizes must be ordered minimum, target, maximum. Olivar refuses a minimum below 120 bases, and PrimalScheme refuses a target outside 100 to 2,000.

**The run finishes but nothing opens.** LGE saves the analysis and reloads the sidebar without opening the result. Click the new bundle under `Analyses` yourself.

**varVAMP reports coverage well under 95%.** This is the single-chain behaviour rather than a failure. Lower the consensus threshold, widen the amplicon bounds, or allow a third ambiguous base, in that order, as [Tuning a scheme that covers too little](#tuning-a-scheme-that-covers-too-little) explains.

**Save as Primer Scheme… is dimmed.** The Inspector prints the reason under the button. A Primer3 analysis can never be saved this way, because candidate pairs are alternatives rather than a tiled scheme, and neither can varVAMP's single or qPCR results for the same reason. A result whose primers sit on more than one reference has to be saved one reference at a time. A design with no selected primers, or one whose oligo names repeat, is refused as well.

**Trimming removes almost nothing.** The reads went to the wrong sequence. Map them to the scheme's own `attachments/design-reference.fasta` and trim again, then read the trim rate in the log as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md#what-good-looks-like) describes.

## Next

Continue to [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) for detection assays with a probe, or to [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) to turn a design into an order. [Primer Schemes](../appendices/primer-schemes.md) documents the bundle a saved scheme writes.
