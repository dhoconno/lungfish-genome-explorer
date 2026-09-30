---
title: Designing a PCR Assay
chapter_id: 10-primer-design/02-designing-a-pcr-assay
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 02-sequences/04-aligning-sequences, 10-primer-design/01-what-is-primer-design]
estimated_reading_min: 14
task: Design one PCR primer pair with Primer3 across Mamu-A1 exons 2 and 3, first on a single allele and then on a twelve-allele alignment with conserved binding sites, and read the candidate pairs.
tags: [primer-design, primer3, pcr, mhc, macaque, alignment]
tools: [primer3]
parameters_refs: [primer-design.primer3]
entry_points:
  - "Tools > PCR Primer Design > Primer3…"
  - "CLI: lungfish-cli primers design primer3"
shots:
  - id: primer3-dialog-single-record
    caption: "The PCR Primer Design dialog with Primer3 chosen, the Records list open with only record 1, LR699574.1, ticked, and a target of 205 to 993 with products of 800 to 1,100 bp."
  - id: primer3-results-single-record
    caption: "The Results view of the single-allele analysis, with Pair 1 selected in the Candidates list and its forward and reverse primer properties beside it."
  - id: primer3-dialog-msa-template
    caption: "The PCR Primer Design dialog on the twelve-allele alignment, with the Template row picker set to row 1 and the conserved binding sites switch turned on."
  - id: primer3-binding-inspection
    caption: "The Binding inspection view of the conserved analysis, with the forward primer of Candidate 1 compared against all twelve rows of the alignment and every row showing zero mismatches."
illustrations: []
glossary_refs: [primer, pcr, amplicon, exon, intron, allele, mhc, ipd-mhc, msa, alignment-column, gc-content, melting-temperature, oligo, paralog, fasta, reference-bundle, plugin-pack, operations-panel, sidebar, inspector, provenance]
features_refs: [primer-design.primer3]
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A [PCR](../../GLOSSARY.md#pcr) assay copies one stretch of DNA, the [amplicon](../../GLOSSARY.md#amplicon), many millions of times. Two [primers](../../GLOSSARY.md#primer) decide where that stretch starts and ends. The forward primer matches the top strand, the strand a database writes out, at the left end of the product, and the reverse primer matches the bottom strand at the right end. Designing the assay means choosing those two sequences so they bind where you want, at the same temperature, and nowhere else.

Lungfish Genome Explorer (LGE) designs single primer pairs with Primer3 ([Untergasser and colleagues 2012](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). Primer3 walks along a template sequence, scores every possible primer against a set of rules, and returns the pairs that break the fewest rules by the smallest margins. The rules cover primer length, [melting temperature](01-what-is-primer-design.md#length-and-melting-temperature), [GC content](../../GLOSSARY.md#gc-content), and the risk that a primer folds on itself or sticks to its partner, all explained in [What Is Primer Design](01-what-is-primer-design.md).

Primer3 designs on one sequence at a time. LGE adds a second route. You give it a [multiple sequence alignment](../../GLOSSARY.md#msa), pick one row as the template, and LGE then forbids primers from sitting on any column where the rows disagree or where a row has a gap, as [Designing on an alignment](01-what-is-primer-design.md#designing-on-an-alignment) explains. The pair that comes back binds a stretch every aligned sequence shares. This chapter runs the same design both ways, because the difference between them is the lesson.

## Why you would do this

A laboratory that studies macaques in vaccine or transplant research needs to know which MHC alleles each animal carries. One route is to amplify [exons](../../GLOSSARY.md#exon) 2 and 3 from genomic DNA as a single product and sequence it, because those two exons encode the peptide-binding groove and carry most of the differences between [alleles](../../GLOSSARY.md#allele). Placing both primers in the [introns](../../GLOSSARY.md#intron) on either side means the whole of both exons is copied, with no primer sequence written over the bases you want to read.

A product of about 1,000 bases is readable by Sanger sequencing from both primers, or as an amplicon on a short-read or long-read instrument. One caution belongs here. On genomic DNA from an outbred animal the product is a mixture of the alleles that animal carries, and possibly of a [paralog](../../GLOSSARY.md#paralog) too, so a direct Sanger read through the exons is unreadable. That is why such products are cloned, or sequenced on an instrument that reads molecules one at a time, which is the route [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) follows.

*Mamu-A1* is a hard target for three reasons, set out in [Why you would do this](01-what-is-primer-design.md#why-you-would-do-this). It is highly polymorphic, it is GC-rich, and it sits in a duplicated gene family whose copy number differs between animals. Allele names follow the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) nomenclature, whose fields [How allele names are built](../09-genotyping/01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the Primer Design demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Its `Reference Sequences` folder holds `mamu-a1-panel`, a [reference bundle](../../GLOSSARY.md#reference-bundle) of twelve full-length genomic *Mamu-A1* alleles from eleven lineages, 2,920 to 2,943 bases each. Record 1 is `LR699574.1`, 2,933 bases long.

To build the project yourself instead, download `mamu-a1-panel.fasta` from the [mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-primer-design), whose notes file lists every accession, and import it with the Reference Sequences card of the Import Center, as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md#procedure) shows.

Install the PCR Primer Design [plugin pack](../../GLOSSARY.md#plugin-pack) from **Tools > Plugin Manager…**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It is about 2.8 GB and carries Primer3 2.6.1 with the other three design tools. The second procedure also needs the Multiple Sequence Alignment pack for MAFFT. The first time you run an engine, LGE prepares that engine's own set of programs before the design starts, which takes a minute or two, and the [Operations Panel](../../GLOSSARY.md#operations-panel) shows "Checking Primer3 runtime…", then "Preparing Primer3 2.6.1…" on that first run, then "Primer3 runtime ready".

The coordinates this chapter uses come from the ENA record for `LR699574.1`. ENA, the European Nucleotide Archive, is one of the public sequence databases, and a record's feature table lists each exon's start and end. On this sequence exon 2 runs from base 205 to 474 and exon 3 from 718 to 993. Each design takes about 25 to 35 seconds.

## Procedure

The dialog reads its inputs from whatever is selected in the sidebar when it opens, and it has no button to add inputs, so select first and then open it.

### Align the twelve alleles

Click `mamu-a1-panel` under `Reference Sequences` in the [sidebar](../../GLOSSARY.md#sidebar), then choose **Tools > Multiple Sequence Alignment > MAFFT…** and run it at its default settings, as [Aligning Sequences](../02-sequences/04-aligning-sequences.md#procedure) shows. The result appears at `Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa`, which means the `Multiple Sequence Alignments` folder inside `Analyses`. Click it and check that the main panel shows 12 rows and 2,953 columns, with `LR699574.1` as row 1.

### Design on a single allele

1. Click `mamu-a1-panel` under `Reference Sequences`, then choose **Tools > PCR Primer Design > Primer3…**. The PCR Primer Design dialog opens with Primer3 selected in its left-hand list and `mamu-a1-panel` under "Selected project inputs".
2. Open the **Records** disclosure, the small triangle under the input, which counts 12 of 12 records selected. Untick every record except the first, `LR699574.1`. Primer3 designs each ticked record separately, so leaving all twelve ticked would give twelve independent designs.
3. Leave **Assay** at **PCR primers**. Set **Product minimum (bp)** to 800 and **Product maximum (bp)** to 1100, and leave **Candidate pairs** at 5. The target spans 789 bases, and 800 to 1,100 leaves room for both primers to sit in the flanking introns rather than on the exons.
4. Turn on **Amplify a specific region**. Set **Target start** to 205 and **Target end** to 993, the first base of exon 2 and the last base of exon 3. Leave **Advanced settings** collapsed, and under "Save analysis" set **Analysis name** to `Mamu-A1 exon 2-3 PCR Primer3`.

    <!-- SHOT: primer3-dialog-single-record -->

5. Check the status line at the foot of the dialog. It reads "Ready. Progress will appear in Operations." when every value is valid, and otherwise names the first problem. Click **Run**.

The dialog closes and the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) opens with a row titled `Primer3 · Mamu-A1 exon 2-3 PCR Primer3`. When the row reports "Primer analysis saved.", LGE selects the new analysis in the sidebar and the viewer opens it.

### Design on the alignment with conserved binding sites

1. Click `mamu-a1-panel` under `Analyses/Multiple Sequence Alignments`, then choose **Tools > PCR Primer Design > Primer3…**. This input is the alignment bundle, which carries a stack-of-layers icon, not the reference bundle of the same name.
2. Open the **Template row** menu under the input and choose row 1, `LR699574.1`. Until you choose a row, the status line reads "Choose a template row for mamu-a1-panel.lungfishmsa." and Run stays disabled.
3. Set the design settings exactly as before, a PCR assay with products of 800 to 1100, five candidate pairs, and a target of 205 to 993. The target is counted on the template row's own bases with the alignment's gaps skipped, so the numbers are the same as in the single-allele design.
4. Check that **Require binding sites conserved across all alignment rows** is on, which it is by default whenever an alignment is among the inputs. Set **Analysis name** to `Mamu-A1 exon 2-3 PCR Primer3 conserved`.

    <!-- SHOT: primer3-dialog-msa-template -->

5. Click **Run**.

## Settings

The Primer3 settings sit in three places. The input section holds the template choice, "Design settings" holds the assay and the product, and "Advanced settings" holds the rules for each primer. The values below are the defaults for the PCR primers assay, and choosing a different assay loads that assay's own values into the same fields. [Primer Design Settings](../appendices/primer-design-settings.md#primer3) documents every field, including the primer length, melting temperature, GC, assay-rule and complementarity groups this chapter leaves alone.

**Records.** Chooses which records of a FASTA file or reference bundle become templates. The default ticks every record, because LGE cannot guess which one you want. Untick the rest when you want a design on one sequence. On the command line this is `--fasta-record`, repeated once per record.

**Template row.** Chooses which row of an alignment Primer3 designs on. There is no default, and Run stays disabled until you pick a row. Pick the allele whose coordinates you know, since target positions and results are counted on that row. On the command line this is `--msa-template`.

**Assay.** Chooses the kind of assay and loads its rules into the fields below. The default is "PCR primers", the right choice for an end-point PCR whose product you will sequence or run on a gel. Choose one of the two qPCR assays only for quantitative PCR, which [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers. On the command line this is `--assay`.

**Product minimum (bp).** Sets the shortest product Primer3 may return, counted from the first base of the forward primer to the last base of the reverse primer. The default is 100 bases. Lower it only when the region you need is shorter than that. On the command line this is `--product-size-min`.

**Product maximum (bp).** Sets the longest product Primer3 may return, counted the same way. The default is 400 bases. Raise it to at least the target length plus room for both primers, which is why this chapter uses 1,100. On the command line this is `--product-size-max`.

**Candidate pairs.** Sets how many primer pairs Primer3 returns for each template. The default is 5, enough to have a choice without a long list to read. Raise it when you expect to discard several pairs after checking them. On the command line this is `--pair-count`.

**Amplify a specific region.** Turns on a target that every product must contain, with the forward primer before it and the reverse primer after it. The default is off, which lets Primer3 place the product anywhere on the template. Turn it on whenever particular bases must be copied, as the two exons must be here. This switch has no command-line flag, because giving the two target flags turns it on.

**Target start.** Sets the first base of the target, counted from 1 on the template's own bases. There is no default. Set it a few bases before the region you need read when you want margin, because the bases immediately next to a sequencing primer are the least reliable ones in a Sanger read. On the command line this is `--target-start`.

**Target end.** Sets the last base of the target, counted the same way, and it may not be smaller than the start. There is no default. Set it a few bases past the region you need read, for the same reason. On the command line this is `--target-end`.

**Require binding sites conserved across all alignment rows.** Stops Primer3 from placing a primer over any alignment column where the rows disagree, where any row has a gap, or where a row carries an ambiguous base. It is on by default, because a primer on a variable column will mismatch some of the aligned sequences. Turn it off to see the best pair for the template row alone. On the command line this is `--binding-site-policy`, with `exclude-variable-and-gapped-columns` for on and `template-only` for off.

**Analysis name.** Names the analysis bundle LGE saves in the project's `Analyses` folder. The default is "Primer analysis", with a number added when that name is taken. Give each run a name that says what it designed, because a name already in use blocks Run. On the command line the name is the last part of the `--output` path.

## Reading the results

A Primer3 analysis opens with three views, **Overview**, **Results** and **Binding inspection**, chosen with the segmented control at the top. [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) owns all three in full. This section reads the one thing this chapter is about, the pair and why it moved.

Click **Results**. A summary line gives the template length, the number of candidate pairs, and a reminder that coordinates are 1-based and inclusive, meaning the first base is base 1 and both end bases count. The **Candidates** list shows "Pair 1" to "Pair 5" with each product size, in Primer3's own order. Primer3 gives every pair a penalty that grows as each primer's melting temperature and length move away from the optimum values you set, so Pair 1 sits closest to those optimums. The penalty does not measure binding, so a higher-numbered pair may still be the better choice once you have checked it against other sequences. Click a pair to see its primers under "Primer properties", each row giving position, length, melting temperature and GC content.

<!-- SHOT: primer3-results-single-record -->

Pair 1 of each design, on the demo project, is as follows.

| Design | Forward primer | Reverse primer | Positions | Product | Tm |
|---|---|---|---|---|---|
| Single allele | GGGAGGGAAATGGCCTCTG | TCCACAGGAGATCAGGGAGG | 89 to 107 and 1014 to 1033 | 945 bp | 59.8 and 60.0 °C |
| Alignment, conserved sites | CGGGTCTCAGCCTCTCCT | GAGGATTCCTCTCCCTCAGGA | 178 to 195 and 1105 to 1125 | 948 bp | 60.0 and 59.8 °C |

Read a pair against the gene map. Exon 1 ends at base 74 and exon 2 begins at 205, so in both designs the forward primer sits in intron 1. Exon 3 ends at base 993 and exon 4 begins at 1590, so both reverse primers sit in intron 3. Each product therefore holds all of exon 2, intron 2 and all of exon 3. Both primers of each pair sit within 0.2 °C of 60 °C, so one annealing temperature suits both. The reverse primer is written 5′ to 3′ as you would order it, which is the [reverse complement](../../GLOSSARY.md#reverse-complement) of the top-strand bases it binds. For `GAGGATTCCTCTCCCTCAGGA`, the top strand at 1,105 to 1,125 reads `TCCTGAGGGAGAGGAATCCTC`, and the two are the same oligo written two ways.

### Why the primers moved

Both designs use the same template, the same target and the same rules. The only difference is that the second could not put a primer on any column where the twelve alleles disagree. On this alignment LGE marked 328 stretches of the template, 473 bases in all, as off limits, most of them single bases and the longest 14. The first design's primer sites overlap such columns, so the second design moved the forward primer 89 bases along, from 89 to 178, and the reverse primer 91 bases along, from 1,014 to 1,105.

The move matters because the first pair is perfect only on `LR699574.1`. Compared against all twelve panel alleles, its forward primer matches five of them perfectly and carries one mismatch 8 bases from its 3′ end on five more and two mismatches on the remaining two. Its reverse primer matches only the two *\*001* alleles perfectly, carries two mismatches on eight alleles, and on *\*008* and *\*012* carries three, one of them only 3 bases from the 3′ end. That last one is the dangerous case, because a mismatch near the 3′ end can stop an allele amplifying at all, as [When the target varies](01-what-is-primer-design.md#when-the-target-varies) explains. The failure is silent. The PCR still gives a band from the alleles that do match, and the genotype you read is missing an allele. The conserved-site pair matches all twelve alleles perfectly at both primers.

### The Primer3 explanation line

Open the **Primer3 explanation** disclosure at the foot of the Results view. It holds Primer3's own count of what it tried, one line for the left primer, one for the right, one for a probe when the assay has one, and one for the pairs. The single-allele run's pair line reads "considered 374, unacceptable product size 369, ok 5", and the conserved run's reads "considered 177, unacceptable product size 170, ok 7". Fewer pairs were considered on the alignment because the excluded columns removed many primer sites. Seven passed and five were returned, because **Candidate pairs** asked for five.

Read the pair line carefully, because it is easy to misread. Primer3 builds pairs only from primers that already passed every single-primer rule, and it reports the first pair test that fails, which is product size. So "ok 0" with every pair under "unacceptable product size" does not mean the primers were bad. It means Primer3 found acceptable primers but none close enough on both sides of the target to fit the size range. The single-primer lines are where a zero-pair run is explained, and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md#when-a-preset-finds-nothing) reads a real one.

## What good looks like

Check that each pair's product holds the whole target, with the forward primer ending before the target start and the reverse primer starting after the target end. Check that the two primers are within about 2 °C of each other, so one annealing temperature serves both. Both pairs above are within 0.2 °C.

Check the pair against every sequence it must amplify. Binding inspection compares one primer with every row of the alignment and reports the rows that mismatch, and [Inspect binding against the alignment](05-reviewing-and-ordering-primers.md#inspect-binding-against-the-alignment) works through it. For the conserved design every row should show zero mismatches. The single-allele analysis has no alignment behind it, so its Binding inspection only explains that there is nothing to compare. Twelve alleles are a teaching size, and a working assay includes every allele the colony carries.

<!-- SHOT: primer3-binding-inspection -->

Remember what the design did not check. Conserved across *Mamu-A1* alleles is not the same as specific to *Mamu-A1*, as [Conserved is not the same as specific](01-what-is-primer-design.md#conserved-is-not-the-same-as-specific) explains, and neither Primer3 nor the conservation filter compared these primers with *Mamu-A2*, *A3*, *A4*, *A7* or *B*. A computer check is a prediction, so test the pair at the bench on DNA from animals with known genotypes before relying on it.

### When the design fails

When the dialog refuses to run, the status line at its foot names the first problem. A target longer than the product maximum gives "The target region is 789 bp but the maximum product size is 400 bp. Every product must span the whole target, so widen the product size range or choose a shorter target.", which the defaults produce if you set the target before the product range. A name already used in `Analyses` gives "An analysis with this name already exists in the project.". An alignment input with no template row chosen keeps Run disabled until you pick one.

When a run finishes with "No primer pairs met the requested constraints.", read the single-primer explanation lines first. On a GC-rich stretch they usually show "GC content failed" on most candidates, and the fix is to widen the GC range, allow shorter primers or a higher maximum melting temperature, or move the target edges a little into the introns. When a conserved-site design returns nothing, too few conserved columns remain on one side of the target to hold a primer. Widen the product range so primers can reach further out, remove rows that are not meant to share the assay, or design with degenerate primers as [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) describes.

## On the command line

This section is optional. Every block in this manual follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and the flags are listed under [Primer schemes and primer design](../appendices/cli-reference.md#primer-schemes-and-primer-design) in the CLI Reference. The first command reproduces the single-allele design, with `@0` choosing record 1, since the CLI counts records from 0. The second reproduces the conserved design on alignment row 1.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Primer Design.lungfish"

lungfish-cli primers design primer3 \
  --fasta-record "$PROJECT/Reference Sequences/mamu-a1-panel.lungfishref@0" \
  --assay pcr \
  --target-start 205 --target-end 993 \
  --product-size-min 800 --product-size-max 1100 \
  --pair-count 5 \
  --output "$PROJECT/Analyses/Mamu-A1 exon 2-3 PCR Primer3.lungfishprimeranalysis"

lungfish-cli primers design primer3 \
  --msa-template "$PROJECT/Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa@0" \
  --binding-site-policy exclude-variable-and-gapped-columns \
  --assay pcr \
  --target-start 205 --target-end 993 \
  --product-size-min 800 --product-size-max 1100 \
  --pair-count 5 \
  --output "$PROJECT/Analyses/Mamu-A1 exon 2-3 PCR Primer3 conserved.lungfishprimeranalysis"
```

Every flag left out takes the same default as the dialog, and the command prints each explanation line when it finishes. `lungfish-cli primers analysis inspect` followed by a bundle path checks a saved analysis and lists what it holds.

## Next

Continue to [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md), which covers the whole *Mamu-A1* gene with overlapping amplicons on the same alignment. [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) takes either pair from this chapter to an order.
