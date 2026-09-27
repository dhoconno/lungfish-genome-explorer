---
title: Designing qPCR and dPCR Assays
chapter_id: 10-primer-design/04-designing-qpcr-and-dpcr-assays
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 10-primer-design/02-designing-a-pcr-assay, 02-sequences/04-aligning-sequences]
estimated_reading_min: 26
task: Design a quantitative detection assay for the Mamu-A1*001 lineage with varVAMP's qPCR mode and with Primer3's two qPCR presets, then test whether the result detects only the lineage it was meant to detect.
tags: [primer-design, qpcr, dpcr, probe, varvamp, primer3, mhc, macaque, specificity]
tools: [varvamp, primer3]
entry_points:
  - "Tools > PCR Primer Design > varVAMP…"
  - "Tools > PCR Primer Design > Primer3…"
  - "CLI: lungfish-cli primers design varvamp"
  - "CLI: lungfish-cli primers design primer3"
shots:
  - id: qpcr-varvamp-dialog
    caption: "The PCR Primer Design dialog on varVAMP with Design mode set to qPCR / dPCR primers + probe, the four-allele lineage alignment as its input, 0.99 in the threshold field, and amplicon sizes of 70, 135 and 200."
  - id: qpcr-varvamp-probe-fields
    caption: "The varVAMP qPCR probe constraints group inside Advanced settings, showing the probe length, probe Tm, probe GC and probe distance fields at their defaults."
  - id: qpcr-primer3-probe-dialog
    caption: "The PCR Primer Design dialog on Primer3 with Assay set to qPCR · internal hydrolysis probe and its caption describing the probe window beneath the picker."
  - id: qpcr-varvamp-overview
    caption: "The Overview tab of the Mamu-A1 001 qPCR varVAMP analysis, showing the five reported assays in their unpooled lanes with forward primers, reverse primers and purple probes."
  - id: qpcr-varvamp-offtarget-warning
    caption: "The Overview card of the varVAMP qPCR analysis run with a BLAST database, showing the orange warning that varVAMP_0 could produce off-targets."
  - id: qpcr-primer3-probe-results
    caption: "The Results tab of the Mamu-A1 001 qPCR Primer3 probe analysis, with Pair 1 selected and the forward primer, internal probe and reverse primer rows showing their melting temperatures."
illustrations: []
glossary_refs: [amplicon, primer, primer-pool, pcr, msa, alignment-column, consensus-sequence, iupac-ambiguity-code, gc-content, exon, intron, allele, mhc, class-i-mhc, ipd-mhc, blast, plugin-pack, operations-panel, sidebar, inspector]
features_refs: []
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A quantitative PCR assay does not only ask whether a target is present. It measures how much of it was there to begin with. Quantitative PCR, or qPCR, reads a fluorescent signal after every cycle, and the cycle at which the signal crosses a threshold tells you how much template the reaction started with. Digital PCR, or dPCR, splits the same reaction into thousands of tiny partitions and counts the ones that lit up. [qPCR and dPCR](01-what-is-primer-design.md#qpcr-and-dpcr) explains both readouts.

Designing such an assay means choosing two [primers](../../GLOSSARY.md#primer), short synthetic pieces of DNA that mark where copying starts, and often a third oligo called a probe that binds between them and carries the fluorescent label. The design rules differ from an ordinary [PCR](../../GLOSSARY.md#pcr) assay in three ways. Products are short, usually 70 to 200 bases, because quantification assumes every molecule is copied completely in every cycle. Melting temperatures are held close together so one annealing temperature suits both primers. And a probe, when there is one, is designed to melt several degrees above the primers so it is already bound when the polymerase reaches it.

Lungfish Genome Explorer (LGE) designs these assays two ways. Primer3 has two qPCR presets, one for an intercalating dye and one for a hydrolysis probe, and designs on a single template. varVAMP has a qPCR mode that designs primers and a probe together from a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of an alignment, so one assay can cover several related sequences. Neither is a dPCR optimizer, because there is no separate design for dPCR. The dialog says so itself, since a dPCR assay uses the same primers and probe as the qPCR assay.

This chapter designs a detection assay three times on the same sequences, and then tests it. The test is the part worth reading twice. All three designs succeed at what the software was asked to do and still fail at what the laboratory actually needs, for a reason [Conserved is not the same as specific](#conserved-is-not-the-same-as-specific) works through in numbers.

## Why you would do this

The example assay in this chapter detects one lineage of a rhesus macaque [MHC](../../GLOSSARY.md#mhc) class I gene, the *Mamu-A1\*001* lineage. A lineage is a group of closely related [alleles](../../GLOSSARY.md#allele), named by the first field after the asterisk in the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) nomenclature ([Maccari and colleagues 2017](../appendices/bibliography.md#primer-design-background)), so `Mamu-A1*001:01:01:01` and `Mamu-A1*001:05:01:01` are two alleles of the same *\*001* lineage. [What Is Primer Design](01-what-is-primer-design.md#why-you-would-do-this) introduces the full name.

That lineage matters to a laboratory for a specific reason. *Mamu-A1\*001*, published for many years as *Mamu-A\*01*, presents two well studied SIV peptides to killer T cells, the Gag epitope CM9 and the Tat epitope SL8. An epitope is the short protein fragment an MHC molecule holds up for inspection. Because the immune response against these two epitopes is measurable and reproducible, animals carrying this lineage have been used heavily in SIV and HIV vaccine studies, and the structures of the molecule holding both peptides have been solved ([Chu and colleagues 2007](../appendices/bibliography.md#primer-design-background)). A colony that assigns animals to such a study needs to know which animals carry the lineage, and it needs to know quickly and cheaply for many animals at once. A qPCR or dPCR assay that gives a yes or no answer per animal in a few hours is a real use, and it is the assay this chapter designs.

The requirement is therefore sharper than in the earlier chapters. [Designing a PCR Assay](02-designing-a-pcr-assay.md) needed primers that work on every *Mamu-A1* allele. This assay needs the opposite as well. It must detect all four *\*001* alleles and must not detect the eleven other *Mamu-A1* lineages or the paralogs *Mamu-A2*, *A3*, *A4* and *B*, related genes that share long stretches of sequence. Those fifteen sequences are the exclusion set, and the demo project ships them for this purpose.

## Choosing a tool

Three routes design a quantitative assay in LGE. The property of your data that settles the choice is how much the sequences you must detect differ from each other, and whether you need a probe.

**Primer3 with the intercalating-dye preset** designs two primers and no probe, for a dye such as SYBR Green that fluoresces in any double-stranded DNA. It walks one template, scores every candidate primer against a rule set, and returns ranked pairs, as [Designing a PCR Assay](02-designing-a-pcr-assay.md#what-it-is) describes ([Untergasser and colleagues 2012](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). The preset tightens the ordinary PCR rules because a dye reports every product, including primer dimers, so specificity rests on the primers alone. It handles variation only in the way any Primer3 design does, by staying off the variable columns of an alignment when you give it one. It is the cheapest assay to order and the fastest to set up, and it wins when your target is one known sequence and a melt curve can confirm the product.

**Primer3 with the hydrolysis-probe preset** designs the same two primers plus an internal oligo, a third oligo binding between them that carries a reporter dye and a quencher. The signal rises only when the polymerase cuts that probe, so a wrong product gives no signal, as [Intercalating dye and hydrolysis probe](01-what-is-primer-design.md#intercalating-dye-and-hydrolysis-probe) explains. This preset handles variation no better than the dye one, and it demands more of the sequence, because a probe site with the right length, melting temperature and GC content must exist between the primers. It wins when a dye's readout is not trustworthy enough, which is the usual case for a gene with close relatives, and it is the standard choice for dPCR.

**varVAMP in qPCR mode** designs primers and a probe from a degenerate consensus of an alignment ([Fuchs and colleagues 2025](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It collapses the aligned sequences into one consensus, writing an [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) wherever the sequences disagree by more than the consensus threshold allows, then searches that consensus for primer and probe sites, as [Degenerate bases and what they cost](01-what-is-primer-design.md#degenerate-bases-and-what-they-cost) describes. It tests its best candidate amplicons for folding and rejects the ones whose structure would compete with the oligos. It handles variation directly, since one degenerate oligo covers several versions of a site, and it reports several independent assays rather than one. It wins when the sequences you must detect differ from each other, which is exactly the lineage case here, and it is the only one of the three that can screen candidates against a BLAST database.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Primer3, dye preset | One assay on one known sequence, read with an intercalating dye | The target is a single sequence and a melt curve can confirm one product | Close relatives could amplify, or the target varies |
| Primer3, probe preset | One assay plus a hydrolysis probe on one known sequence | You need a probe's readout, or you are designing for dPCR | Several sequences that differ must all be detected by one assay |
| varVAMP, qPCR mode | Primer and probe assays across a set of related sequences | The sequences to detect differ from one another, or you want an off-target screen | You have one template only, or you want plain non-degenerate oligos |

This chapter starts with varVAMP, because the four *\*001* alleles differ from each other and a single-template design would sit on one of them and hope. It then runs both Primer3 presets on the same alignment to compare. For a target that is genuinely one sequence, such as a cloned insert or a single human exon, start with Primer3 and skip varVAMP. For an assay that must cover a whole gene rather than detect it, a tiled scheme is the right shape instead, as [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) shows.

## Before you start

You need a project open. Open the Primer Design demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. This chapter uses two of its three reference bundles. `mamu-a1-001-lineage` holds the four *Mamu-A1\*001* alleles the assay must detect. `mamu-class-i-exclusion` holds the fifteen sequences it must not detect. The same records are in [the mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design), whose README lists every accession, allele and length.

Install two [plugin packs](../../GLOSSARY.md#plugin-pack) from **Tools > Plugin Manager…**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The Multiple Sequence Alignment pack runs MAFFT. The PCR Primer Design pack, about 2.8 GB, carries Primer3 2.6.1 and varVAMP 1.3.2 with the other two engines. The first run of each engine prepares that engine's own environment before the design starts, and the [Operations Panel](../../GLOSSARY.md#operations-panel) reports that step.

The designs need an alignment, not loose sequences, because the four alleles differ in length. Select `mamu-a1-001-lineage` in the [sidebar](../../GLOSSARY.md#sidebar) and align it with **Tools > Multiple Sequence Alignment > MAFFT…** at its default settings, as [Aligning Sequences](../02-sequences/04-aligning-sequences.md#procedure) shows. The result is a 2,960-column alignment of 4 rows under `Analyses/Multiple Sequence Alignments/`, with `LR699574.1` as row 1.

The varVAMP run took 88 seconds on the reference machine, and 101 seconds with the off-target screen added. Each Primer3 run finishes in well under a minute. Coordinates in this chapter are 1-based and inclusive on the design reference, counting the first base as 1 and including both ends of a range.

## Procedure

The dialog reads its inputs from the sidebar selection when it opens and has no button to add one afterwards, so select the alignment first.

### Design with varVAMP in qPCR mode

1. Click the `mamu-a1-001-lineage` alignment under `Analyses/Multiple Sequence Alignments`, then choose **Tools > PCR Primer Design > varVAMP…**. Check that the input is listed with the line "4 alignment rows included".
2. Set **Design mode** to **qPCR / dPCR primers + probe**. Its caption reads "varVAMP uses its qPCR optimizer for primer-and-probe assays. There is no separate dPCR optimizer." The pool line changes to "Assays are unpooled." because each assay is its own reaction.
3. Type `0.99` in **Cumulative consensus threshold (required)**. qPCR mode has no automatic threshold, so Run stays disabled while the field is empty. On four sequences 0.99 means all four must agree at a column for it to be written as a plain base.
4. Check that the amplicon sizes read 70, 135 and 200. Those are varVAMP's own qPCR bounds and the defaults for this mode, and [Why the old default failed](#why-the-old-default-failed) explains why they are short.

    <!-- SHOT: qpcr-varvamp-dialog -->

5. Under "Save analysis" set **Analysis name** to `Mamu-A1 001 qPCR varVAMP`, check that the status line reads "Ready. Progress will appear in Operations.", and click **Run**. When the Operations row reports "Primer analysis saved.", click the new analysis under `Analyses`, since the result does not open by itself.

The probe rules sit under "Advanced settings" in the "qPCR probe constraints" group, which appears only in qPCR mode. Leave them alone for this run and read [Settings](#settings) for what each one does.

<!-- SHOT: qpcr-varvamp-probe-fields -->

### Screen the same design against the exclusion set

varVAMP can check its candidates against a local BLAST nucleotide database and mark any assay that could make an unwanted product. At the time of writing LGE has no command that builds such a database, so you build it once outside LGE with `makeblastdb` from the BLAST package, pointing it at the exclusion FASTA, and then give LGE the database prefix. Repeat the varVAMP run above with two changes. Open **Advanced settings** and type the database prefix into **Local nucleotide BLAST database prefix (optional)**, then name the analysis something like `Mamu-A1 001 qPCR varVAMP BLAST`. [Conserved is not the same as specific](#conserved-is-not-the-same-as-specific) reads what comes back.

### Design with the Primer3 hydrolysis-probe preset

1. Select the same alignment and choose **Tools > PCR Primer Design > Primer3…**.
2. Open the **Template row** menu and choose row 1, `LR699574.1`. Run stays disabled until a row is chosen.
3. Set **Assay** to **qPCR · internal hydrolysis probe**. The product range changes to 70 and 150, and the caption under the picker describes the probe window the preset asks for.
4. Leave **Amplify a specific region** off, so Primer3 may place the assay anywhere on the template, and check that **Require binding sites conserved across all alignment rows** is on.

    <!-- SHOT: qpcr-primer3-probe-dialog -->

5. Set **Analysis name** to `Mamu-A1 001 qPCR Primer3 probe` and click **Run**.

### Design with the Primer3 dye preset

Repeat the previous procedure with **Assay** set to **qPCR · intercalating dye** and the name `Mamu-A1 001 qPCR Primer3 dye`. Everything else stays the same. This preset asks for no probe, so its results have forward and reverse primers only.

One instructive failure is worth running. Turn on **Amplify a specific region** and set the target inside exon 2, for example 300 to 340, then run the dye preset again. On this alignment that request returns no pairs at all, for the reason [When a preset finds nothing](#when-a-preset-finds-nothing) gives.

## Settings

The qPCR controls sit in three places. varVAMP's mode and threshold are in "Scheme settings", its probe rules are in "Advanced settings", and Primer3's assay picker is in "Design settings". Only the settings specific to a quantitative assay are covered here. [Designing a PCR Assay](02-designing-a-pcr-assay.md#settings) covers Primer3's shared fields and [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md#varvamp-settings) covers varVAMP's shared primer constraints.

### varVAMP qPCR settings

**Design mode.** Chooses between "Single amplicon", "Tiled amplicons" and "qPCR / dPCR primers + probe". The default is Tiled amplicons, so you must change it for a quantitative assay. Choose the qPCR option for both qPCR and dPCR, since the same primers and probe serve both. On the command line this is `--mode`, with the value `qpcr`.

**Cumulative consensus threshold (required).** Sets how much agreement a base needs before the consensus writes it plainly rather than as an ambiguity code. There is no default in qPCR mode and Run stays disabled until you type one, unlike the other two modes where a blank field lets varVAMP choose. Read it as how many of your sequences must agree, so 0.99 on four sequences means all four. On the command line this is `--consensus-threshold`.

**Minimum, Target and Maximum amplicon size (bp).** Set the shortest, nominal and longest amplicon span, both primer sites included. In qPCR mode the defaults are 70, 135 and 200, which are varVAMP's own qPCR bounds rather than the 360, 400 and 440 the other modes use. Raise the maximum only if you have a reason, because a longer amplicon folds more and quantifies less evenly. On the command line these are `--amplicon-size-min`, `--amplicon-size` and `--amplicon-size-max`.

**qPCR test count.** Sets how many of the best-scoring candidate amplicons varVAMP folds and tests for secondary structure. The default is 50, varVAMP's own value, which keeps the slowest step of the run bounded. Raise it when few assays come back and you want more candidates examined, at the cost of run time. On the command line this is `--qpcr-test-count`.

**qPCR ΔG setting.** Sets the free-energy cutoff, in kilocalories per mole, below which a folded amplicon is rejected. The default is −3, varVAMP's own value, so an amplicon that folds more stably than −3 at the lower of its two primer melting temperatures is discarded because its structure would compete with the primers and probe, as [Secondary structure and free energy](01-what-is-primer-design.md#secondary-structure-and-free-energy) explains. Make it more negative to accept more structured amplicons, which is a last resort when nothing passes. On the command line this is `--qpcr-delta-g`.

**Maximum probe ambiguities (blank = native).** Limits how many ambiguity codes the probe may contain. It is blank by default, which lets varVAMP derive the limit from the primer ambiguity setting. Set it to 0 when a supplier cannot place a mixed base in a labelled probe, as [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md#placing-the-order) discusses. On the command line this is `--maximum-probe-ambiguities`.

**Local nucleotide BLAST database prefix (optional).** Names a local BLAST nucleotide database that varVAMP searches for other places its candidate primers could bind and make a product. It is blank by default, so no off-target check runs. At the time of writing LGE does not build this database, so create one outside LGE with `makeblastdb` and give the prefix here. On the command line this is `--blast-database`.

The "qPCR probe constraints" group repeats varVAMP's own probe rules, and LGE sends every one of them on every qPCR run. Probe length is 20, 25 and 30 bases as minimum, optimum and maximum, and probe melting temperature is 64, 67 and 70 °C, which sits the probe above the primers on purpose. Probe GC content is 40, 60 and 80%, with 0 to 4 G or C bases at the probe end. The probe must melt 5 to 10 °C above the primers and sit 4 to 15 bases from the primer on its own strand. The amplicon itself must be 40 to 60% GC, the two primers must be within 2 °C of each other, and an alignment region is considered for folding only when its deletions are shorter than 4 bases. Each field has a command-line flag of the same shape, such as `--probe-tm-min` and `--probe-distance-max`, listed in the [Command-Line Reference](../appendices/cli-reference.md). None of these fields shows a unit on screen.

### Primer3 qPCR settings

**Assay.** Chooses the rule set and loads it into the fields below, which you can still edit. The default is "PCR primers". Choosing "qPCR · intercalating dye" or "qPCR · internal hydrolysis probe" replaces the product range, primer lengths, melting temperatures, GC limits and dimer thresholds with that preset's values, so pick the assay before you adjust anything. On the command line this is `--assay`, with `qpcr-dye` or `qpcr-probe`.

Both presets take their primer rules from the qPCR literature, the MIQE guidelines and Thornton and Basu 2011, both in [Primer design background](../appendices/bibliography.md#primer-design-background). Products run 70 to 150 bases. Primers are 18 to 24 bases, optimum 20, with melting temperatures of 58, 60 and 62 °C and no more than 1 °C between the two primers of a pair, so both anneal at a single 60 °C step. GC content is held to 40 to 60%, runs of one base to 4, and the last five bases at the 3′ end may hold at most 2 G or C bases with at least 1 as a clamp. The dimer thresholds are stricter than Primer3's own, since a dye reports every double-stranded product and a dimer wastes reagent in either chemistry.

The hydrolysis-probe preset adds the probe rules, which the dialog states in its caption but does not expose as editable fields. The probe melts at 64, 67 and 70 °C, which is 5 to 10 °C above the primers, runs 20 to 30 bases with an optimum of 25, holds 40 to 80% GC, allows runs of at most 4, and may not begin with a G at its 5′ end, because a G next to the reporter dye quenches it. The command line can override each of these with flags such as `--probe-min-tm`, `--probe-max-size` and `--probe-must-match-five-prime`.

**Product minimum and maximum (bp).** Set the shortest and longest product. Both presets default to 70 and 150, against 100 and 400 for ordinary PCR. Leave them alone unless your instrument or chemistry asks for something else, and never raise the maximum above what the [reason for short amplicons](01-what-is-primer-design.md#why-qpcr-amplicons-are-short) allows. On the command line these are `--product-size-min` and `--product-size-max`.

**Amplify a specific region, Target start and Target end.** Restrict the assay to a chosen stretch, which every product must contain. The switch is off by default, which lets Primer3 place the assay wherever the rules are best satisfied. Use it when a particular region must be measured, and keep in mind that a target longer than the product maximum is refused, as the [Troubleshooting](#troubleshooting) table shows. On the command line these are `--target-start` and `--target-end`.

## Reading the results

Open `Mamu-A1 001 qPCR varVAMP` under `Analyses`. A varVAMP qPCR analysis reports several independent assays rather than one scheme, so read it assay by assay.

<!-- SHOT: qpcr-varvamp-overview -->

The Overview card gives a coverage percentage whose label reads "Descriptive union of reported assay spans". For a qPCR result that number is not a quality score. It only says how much of the consensus the reported assays happen to touch between them, and the assays are alternatives you choose among rather than a set you run together. The lanes beneath are labelled "Unpooled · selected assay" and "Unpooled · alternative rank" with a number, which are display groupings and not pools. Each assay draws its forward primer in blue, its reverse primer in orange and its probe in purple.

The reference run returned five assays on the four-allele alignment.

| Assay | Amplicon | Length | ΔG | Penalty |
|---|---|---|---|---|
| varVAMP_0 | 1070 to 1250 | 181 bp | −2.2 | 2.2 |
| varVAMP_1 | 2649 to 2731 | 83 bp | −0.3 | 2.2 |
| varVAMP_2 | 2430 to 2604 | 175 bp | −1.4 | 2.8 |
| varVAMP_3 | 1679 to 1847 | 169 bp | −1.7 | 3.3 |
| varVAMP_4 | 392 to 487 | 96 bp | −1.4 | 4.6 |

Read the two numbers on the right the way varVAMP means them. The penalty adds up how far the assay's oligos sit from the optimum length, melting temperature and GC content, so a lower penalty is closer to the rules you set. The ΔG is the folding free energy of the amplicon at the lower of its two primer melting temperatures, and every value here is above the −3 cutoff. varVAMP_1 at −0.3 barely folds at all, which is what you want from an 83-base product.

The Results tab lists the oligos of each assay. The first assay reads as follows on the reference run.

| Role | Sequence | Length | Tm |
|---|---|---|---|
| Forward primer | CAAAGAGGGGAGACAAATGGGA | 22 nt | 60.1 °C |
| Probe | TATCGCCCTCCCTCTGKTCCTGAGG | 25 nt | 67.3 °C |
| Reverse primer | TTCGAGGGATCGTCTTTCCTTC | 22 nt | 60.0 °C |

That is the shape a hydrolysis-probe assay should have. The two primers sit within 0.1 °C of each other, so one annealing temperature suits both, and the probe sits about 7 °C above them, so it is bound before the polymerase arrives. The `K` in the probe is an ambiguity code standing for G or T, which means the probe is ordered as a mixture of two sequences, each at half the concentration. The Results tab flags this in orange as a count of ambiguous bases with a reminder to check how your supplier will synthesise it.

The Primer3 probe analysis reads differently, because Primer3 returns ranked alternatives rather than independent assays. Its top three pairs on the reference run all lie in or near exon 4.

<!-- SHOT: qpcr-primer3-probe-results -->

| Forward | Probe | Reverse | Product |
|---|---|---|---|
| GCTTCTACCCTGCGGAGATC, 1662 to 1681, Tm 60.0 | TGACCTGGCAGCGGGATGGGGAGGA, 1686 to 1710, Tm 66.7 | AGCTCCGTGTCCTGAGTTTG, 1712 to 1731, Tm 60.0 | 70 bp |
| AGGGAAAGCTGGAGCCTTTC, 1898 to 1917, Tm 60.0 | CCCATGGTGGGCATCATTGCTGGCC, 1991 to 2015, Tm 64.3 | ACCACAGCTCCAAGGAGAAC, 2018 to 2037, Tm 59.6 | 140 bp |
| AGGGAAAGCTGGAGCCTTTC, 1898 to 1917, Tm 60.0 | CCCTCACCTTCCCCTCTTTTCCCAGAGCCG, 1943 to 1972, Tm 66.4 | GAACCAGGCCAGCAATGATG, 2002 to 2021, Tm 59.5 | 124 bp |

Every probe sits 4 to 7 °C above its primers, which is the preset working as intended. Before this release the same assay picked a probe at Primer3's own 60 °C internal default, level with the primers, and such a probe can melt off before it is ever cut.

The **Primer3 explanation** disclosure at the foot of the Results tab holds Primer3's own tally. For the probe run it reads "considered 1757, unacceptable product size 1736, tm diff too large 8, no internal oligo 4, ok 9". That last clause is the one to watch on a probe design. "No internal oligo 4" counts pairs that were fine as primers but had no acceptable probe site between them, which is the extra demand a probe places on the sequence.

The dye preset returned five pairs when left untargeted, among them `GCTTCTACCCTGCGGAGATC` with `AGCTCCGTGTCCTGAGTTTG` at 1662 to 1681 and 1712 to 1731, a 70-base product in exon 4 with both primers at 60.0 °C, and `AGGGAAAGCTGGAGCCTTTC` at 1898 to 1917 paired with reverse primers giving 124 or 140 bases.

### When a preset finds nothing

Targeted at exon 2, the dye preset returned nothing. Its explanation line reads "considered 816, unacceptable product size 816, ok 0", and that wording misleads. The real limit is not product size. Exon 2 of *Mamu-A1* is too GC-rich for the preset's 40 to 60% window, so no primer in that stretch qualifies, and Primer3 reports pairs whose primers never met the rules under its product-size count. When you see "ok 0" with every pair blamed on product size, check the GC rules against your target before you widen the size range.

The fix is to move, not to loosen. Exon 2 is where the allelic variation lives, which makes it tempting, but a preset that exists to keep quantification honest is the wrong thing to relax. Either accept a site outside exon 2 or use varVAMP, whose consensus and degenerate oligos search the same sequence under different rules.

### Why the old default failed

The short amplicon bounds in qPCR mode are not a stylistic choice, and there is a concrete failure behind them. An earlier LGE build reused the tiled default of 360 to 440 bases for varVAMP's qPCR mode. The same design on this alignment then ran for 938 seconds and failed with "no qPCR amplicon passed the deltaG threshold". Every candidate 400-base stretch of this GC-rich sequence folded more stably than the −3 cutoff, so the deltaG filter discarded all of them. Folding candidates that long is also the slowest step of the run, which is where the 938 seconds went.

That was a bug in LGE's defaults rather than in varVAMP, and it is fixed. qPCR mode now defaults to 70, 135 and 200 as varVAMP itself does, and the same design finishes in 88 seconds with five assays. The lesson outlasts the bug. A qPCR amplicon is short because a long single-stranded product folds, and a folded product competes with the primers and the probe for the very sites they need. If you ever raise the maximum here and the run stops finding anything, this is the first thing to suspect.

## Conserved is not the same as specific

Everything so far worked. Five varVAMP assays passed every filter, every oligo matches all four *\*001* alleles perfectly, and both Primer3 presets returned clean pairs with well placed probes. Now test the assay against the requirement, which is that it must not detect the other fifteen sequences.

Comparing every varVAMP oligo against all nineteen sequences gives the result that matters. Against the four *Mamu-A1\*001* alleles, all five assays show zero mismatches, exactly as designed. Against the fifteen exclusion sequences, not one of the five assays is specific to the lineage. The forward primer of varVAMP_3 matches 14 of the 15 non-target sequences perfectly. varVAMP_1 is the most discriminating of the five, carrying 3 or 4 mismatches against most other lineages, yet even it has only 1 mismatch against *Mamu-A1\*041*, and its reverse primer matches 14 of the 15 perfectly. An assay whose primers both bind a non-target sequence will amplify that sequence.

varVAMP's own off-target screen reaches the same verdict independently. The run with the BLAST database of the exclusion set returned the same five assays, each now marked as producing off-target amplicons, and LGE printed five warnings of this form.

```text
varVAMP warning: varVAMP_0 could produce off-targets. No better amplicon in this area was found.
```

<!-- SHOT: qpcr-varvamp-offtarget-warning -->

Read the second sentence carefully. The screen reports the problem and says it could not do better, because there was no alternative amplicon in that region that avoided the off-targets. The screen is a check, not a steering mechanism. The Primer3 results tell the same story from the other direction, since their assays sit in exon 4, a region conserved across the class I genes, so they would detect *Mamu* class I broadly rather than the *\*001* lineage.

None of this is a malfunction. A design engine maximises conservation within the set of sequences you give it. It has no idea what else is in the sample. Give varVAMP four *\*001* alleles and it will find the sites those four share, and the sites four closely related MHC alleles share are largely the sites the whole gene family shares. [Conserved is not the same as specific](01-what-is-primer-design.md#conserved-is-not-the-same-as-specific) states the principle, and these numbers are what it looks like on real sequence.

### What to do next

Specificity has to be designed for deliberately, and it starts from a different question. Instead of asking where the targets agree, ask where the targets agree with each other and differ from everything else. Align the four *\*001* alleles together with the fifteen exclusion sequences, then read the alignment for columns where all four targets carry one base and the non-targets carry another. Those columns are the only places a discriminating assay can be built.

Where you put such a column decides whether it works. A mismatch at a primer's 3′ end can stop extension outright, while the same mismatch near the 5′ end is usually tolerated, as [When the target varies](01-what-is-primer-design.md#when-the-target-varies) sets out with the measured effects. So place the discriminating position at or within a few bases of a primer's 3′ end, which is the principle behind allele-specific PCR, or put several discriminating positions under the probe, where a hydrolysis probe's shorter binding and higher melting temperature make it less forgiving of mismatches than a primer. Designing one primer by hand around a chosen position, then asking Primer3 for a partner, is a normal way to work once you know which position matters.

Then test it properly. Run the assay on DNA from animals typed as carrying *Mamu-A1\*001* and on animals typed as lacking it, since a specificity claim rests on the negatives. [Amplicon MHC genotyping](../09-genotyping/02-running-genotyping.md) is one way to establish those types. No in-silico result substitutes for the negative controls, as [Checking a design in silico and at the bench](01-what-is-primer-design.md#checking-a-design-in-silico-and-at-the-bench) explains, and [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md#what-good-looks-like) lists the bench sequence in order.

## What good looks like

A quantitative assay worth ordering passes the checks below before it costs you anything.

- Both primers sit within about 1 °C of each other, and a probe sits 5 to 10 °C above them. The varVAMP_0 assay's 60.1, 60.0 and 67.3 °C is the pattern.
- The product is short, inside 70 to 200 bases, and its ΔG is above the −3 cutoff rather than at it.
- Every sequence the assay must detect shows zero mismatches in Binding inspection, as all four lineage alleles do here.
- The design has been compared against the sequences it must not detect, and the discriminating positions sit at a primer's 3′ end or under the probe.
- A probe carrying an ambiguity code has been checked with your supplier, and a design for dPCR uses a probe rather than a dye.

The fourth check is the one this chapter's designs fail, and failing it in LGE is much cheaper than failing it after the oligos arrive.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. These commands reproduce the three designs.

```bash
ALIGN="$HOME/Documents/Primer Design.lungfish/Analyses/Multiple Sequence Alignments/mamu-a1-001-lineage.lungfishmsa"
PROJECT="$HOME/Documents/Primer Design.lungfish"

lungfish-cli primers design varvamp \
  --msa "$ALIGN" --mode qpcr --consensus-threshold 0.99 \
  --amplicon-size 135 --amplicon-size-min 70 --amplicon-size-max 200 \
  --qpcr-test-count 50 --qpcr-delta-g -3 \
  --output "$PROJECT/Analyses/Mamu-A1 001 qPCR varVAMP.lungfishprimeranalysis"

lungfish-cli primers design primer3 \
  --msa-template "$ALIGN@0" \
  --binding-site-policy exclude-variable-and-gapped-columns \
  --assay qpcr-probe --pair-count 5 \
  --output "$PROJECT/Analyses/Mamu-A1 001 qPCR Primer3 probe.lungfishprimeranalysis"

lungfish-cli primers design primer3 \
  --msa-template "$ALIGN@0" \
  --binding-site-policy exclude-variable-and-gapped-columns \
  --assay qpcr-dye --pair-count 5 \
  --output "$PROJECT/Analyses/Mamu-A1 001 qPCR Primer3 dye.lungfishprimeranalysis"
```

Every flag left out takes the preset's own default, so the sizes and probe rules above are the values the dialog would have sent anyway. Add `--blast-database` with your database prefix to the varVAMP command for the off-target screen, and the design command prints the advisories and warnings the Overview card shows as `[info]` and `[warning]` lines. `--assay qpcr-probe` implies `--pick-internal-oligo`, so there is no need to pass both. `lungfish-cli primers analysis inspect` on a finished bundle verifies it and lists what it holds. The [Command-Line Reference](../appendices/cli-reference.md) lists every flag.

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| Run is disabled and the status line asks for a consensus threshold | qPCR mode requires an explicit threshold, unlike single and tiled mode | Type a value such as 0.99 in **Cumulative consensus threshold** |
| "no qPCR amplicon passed the deltaG threshold" after a long run | Every candidate amplicon folds more stably than the cutoff, usually because the size bounds are too wide for GC-rich sequence | Return the sizes to 70, 135 and 200, then raise **qPCR test count** before touching **qPCR ΔG setting** |
| `The target region is 270 bp but the maximum product size is 150 bp; widen the product size range or choose a shorter target` | The target is longer than a qPCR preset's product maximum, so no product could ever contain it | Shorten the target, or raise **Product maximum (bp)** and accept a longer amplicon |
| "considered 816, unacceptable product size 816, ok 0" from the dye preset | Usually the GC rules rather than the size, since Primer3 reports pairs whose primers never qualified under its size count | Move the target out of the GC-rich stretch, or use varVAMP on the alignment |
| "no internal oligo" in a probe run's explanation line | Pairs were acceptable as primers but had no valid probe site between them | Widen the product range a little so more probe sites fall inside, or use the dye preset |
| Five assays come back and all are marked as producing off-targets | The BLAST screen found other sequences both primers could bind, and no better amplicon existed in that region | Treat the design as non-specific and follow [What to do next](#what-to-do-next) |
| The probe carries an ambiguity code your supplier will not label | Degenerate probes are ordered as mixtures, which some suppliers refuse on labelled oligos | Set **Maximum probe ambiguities** to 0 and rerun, or order the versions separately and mix them |

## Next

Continue to [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) to check these assays oligo by oligo, export an order, and work through the bench validation sequence. To design a primer pair without a probe, see [Designing a PCR Assay](02-designing-a-pcr-assay.md), and to cover a whole gene rather than detect it, see [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md).
