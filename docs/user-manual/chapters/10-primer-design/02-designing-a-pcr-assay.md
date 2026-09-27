---
title: Designing a PCR Assay
chapter_id: 10-primer-design/02-designing-a-pcr-assay
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 02-sequences/04-aligning-sequences, 10-primer-design/01-what-is-primer-design]
estimated_reading_min: 20
task: Design one PCR primer pair with Primer3 across Mamu-A1 exons 2 and 3, first on a single allele and then on a twelve-allele alignment with conserved binding sites, and read the candidate pairs.
tags: [primer-design, primer3, pcr, mhc, macaque, alignment]
tools: [primer3]
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
    caption: "The Binding inspection view of the conserved analysis, showing the twelve alignment rows under the forward primer of Pair 1 and the mismatch table beneath."
glossary_refs: [primer, pcr, amplicon, exon, intron, allele, mhc, ipd-mhc, msa, alignment-column, gc-content, fasta, reference-bundle, plugin-pack, operations-panel, sidebar, inspector, provenance]
features_refs: []
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A [PCR](../../GLOSSARY.md#pcr) assay copies one stretch of DNA, the [amplicon](../../GLOSSARY.md#amplicon), many millions of times. Two [primers](../../GLOSSARY.md#primer), short pieces of laboratory-made DNA, decide where that stretch starts and ends. The forward primer matches the top strand at the left end. The reverse primer matches the bottom strand at the right end. Designing the assay means choosing those two sequences so they bind where you want, at the same temperature, and nowhere else.

Lungfish Genome Explorer (LGE) designs single primer pairs with Primer3, a widely used program for this job ([Untergasser and colleagues 2012](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). Primer3 walks along a template sequence, scores every possible primer against a set of rules, and returns the pairs that break the fewest rules by the smallest margins. The rules cover primer length, [melting temperature](01-what-is-primer-design.md#length-and-melting-temperature), the temperature at which half the primer lets go of its target, [GC content](../../GLOSSARY.md#gc-content), the share of G and C bases, and the risk that a primer folds on itself or sticks to its partner. [What Is Primer Design](01-what-is-primer-design.md) explains each of these ideas. This chapter shows how to set them in LGE and read what comes back.

Primer3 designs on one sequence at a time. LGE adds a second route. You give it a [multiple sequence alignment](../../GLOSSARY.md#msa), a table that lines up related sequences so shared positions sit in the same column, and pick one row as the template. LGE then forbids primers from sitting on any column where the rows disagree or where a row has a gap, as [Designing on an alignment](01-what-is-primer-design.md#designing-on-an-alignment) explains. The pair that comes back binds a stretch every aligned sequence shares.

## Why you would do this

The worked example is a gene from the rhesus macaque [MHC](../../GLOSSARY.md#mhc), the major histocompatibility complex, a cluster of immune genes that varies more between individuals than any other part of the genome. MHC class I molecules sit on the cell surface and display short protein fragments, called peptides, to T cells. The groove that holds the peptide is built from the parts of the protein that exons 2 and 3 encode. An [exon](../../GLOSSARY.md#exon) is a stretch of a gene kept in the mature message, and an [intron](../../GLOSSARY.md#intron) is a stretch cut out between exons. Exons 2 and 3 are where most of the differences between [alleles](../../GLOSSARY.md#allele), the versions of a gene, are found.

A laboratory that studies macaques in vaccine or transplant research often needs to know which MHC alleles each animal carries. One practical route is to amplify exons 2 and 3 from genomic DNA as a single product and sequence it. A product of about 1,000 bases can be read by Sanger sequencing from both primers, or sequenced as an amplicon on a short-read or long-read instrument. The sequence of both exons is usually enough to name the allele. Placing both primers in the introns on either side means the whole of both exons is copied, with no primer sequence written over the bases you want to read.

MHC genes are a hard, realistic case for primer design, for three reasons. They are highly polymorphic, which means many alleles differ at many positions, so a primer that matches one allele may mismatch another. They are rich in G and C, which pushes melting temperatures up and makes primers more likely to fold. And the rhesus genome carries several related genes, called paralogs, such as Mamu-A2, A3, A4, and Mamu-B, that share much of their sequence with Mamu-A1, so a primer can bind the wrong gene.

Allele names in this chapter follow the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) nomenclature ([Maccari and colleagues 2017](../appendices/bibliography.md#primer-design-background)). In `Mamu-A1*001:01:01:01`, `Mamu-A1` names the gene. The four numbered fields then name the lineage (001), the protein sequence within that lineage, differences that do not change the protein, and differences outside the coding sequence, in that order.

The chapter works the same design twice. First you design on one allele, `Mamu-A1*001:01:01:01`, accession LR699574.1. Then you design on an alignment of twelve alleles from twelve lineages and let LGE keep the primers off every variable column. Comparing the two shows why a primer designed on one allele can fail on another.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the Primer Design demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Its `Reference Sequences` folder holds `mamu-a1-panel`, a [reference bundle](../../GLOSSARY.md#reference-bundle) of twelve full-length genomic Mamu-A1 alleles from twelve lineages, 2,920 to 2,943 bases each. Record 1 is LR699574.1, 2,933 bases long.

This chapter uses the mhc-primer-design fixture. To build the project yourself, download `mamu-a1-panel.fasta` from [the mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design) and import it as a reference. The folder's README lists every accession and its source.

Install the `pcr-primer-design` [plugin pack](../../GLOSSARY.md#plugin-pack) from **Tools > Plugin Manager…**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It is about 2.8 GB and carries Primer3 2.6.1 with the other three design tools. The second procedure also needs the `multiple-sequence-alignment` pack for MAFFT. The first time you run Primer3, LGE prepares its environment before the design starts, and the Operations Panel shows that step.

The second procedure needs an alignment of the panel. Select `mamu-a1-panel` in the [sidebar](../../GLOSSARY.md#sidebar) and align it with **Tools > Multiple Sequence Alignment > MAFFT…** at the default settings, as [Aligning Sequences](../02-sequences/04-aligning-sequences.md#procedure) shows. The result is `Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa`, 2,953 columns wide, with LR699574.1 as row 1.

The coordinates you need come from the ENA record for LR699574.1. On that sequence exon 2 runs from base 205 to 474 and exon 3 from 718 to 993. Each design took about 25 to 35 seconds on the reference run.

## Procedure

The dialog reads its inputs from whatever is selected in the sidebar when you open it. It has no button to add inputs, so select first and then open it.

### Design on a single allele

1. Click `mamu-a1-panel` under `Reference Sequences` in the sidebar, then choose **Tools > PCR Primer Design > Primer3…**. The PCR Primer Design dialog opens with Primer3 selected in its left-hand list and `mamu-a1-panel` under "Selected project inputs".
2. Open the **Records** disclosure under the input, which counts 12 of 12 records selected. Untick every record except the first, LR699574.1. Primer3 designs each ticked record separately, so leaving all twelve ticked would give twelve independent designs.
3. Leave **Assay** at **PCR primers**. Set **Product minimum (bp)** to 800 and **Product maximum (bp)** to 1100, and leave **Candidate pairs** at 5.
4. Turn on **Amplify a specific region**. Set **Target start** to 205 and **Target end** to 993, the first base of exon 2 and the last base of exon 3. Leave **Advanced settings** collapsed, and under "Save analysis" set **Analysis name** to `Mamu-A1 exon 2-3 PCR Primer3`.

    <!-- SHOT: primer3-dialog-single-record -->

5. Check the status line at the foot of the dialog. It reads "Ready. Progress will appear in Operations." when every value is valid, and otherwise names the first problem. Click **Run**.

The dialog closes and the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) opens with a row titled `Primer3 · Mamu-A1 exon 2-3 PCR Primer3`. When it finishes, the sidebar reloads. The result does not open by itself, so click `Mamu-A1 exon 2-3 PCR Primer3` under `Analyses` to open it.

### Design on the alignment with conserved binding sites

1. Click `mamu-a1-panel` under `Analyses/Multiple Sequence Alignments` in the sidebar, then choose **Tools > PCR Primer Design > Primer3…**. This input is the `.lungfishmsa` alignment bundle, not the reference bundle of the same name.
2. Open the **Template row** menu under the input and choose row 1, LR699574.1. Until you choose a row, the status line reads "Choose a template row for mamu-a1-panel.lungfishmsa." and Run stays disabled.
3. Set the design settings exactly as before. **Assay** is **PCR primers**, the product range is 800 to 1100, **Candidate pairs** is 5, and the target is 205 to 993. The target is counted on the template row's own bases with gaps skipped, so the numbers are the same as in the single-allele design.
4. Check that **Require binding sites conserved across all alignment rows** is on. It is on by default whenever an alignment is among the inputs. Set **Analysis name** to `Mamu-A1 exon 2-3 PCR Primer3 conserved`.

    <!-- SHOT: primer3-dialog-msa-template -->

5. Click **Run**, and open the new analysis under `Analyses` when the Operations Panel row finishes.

## Settings

The Primer3 settings sit in three places. The input section holds the template choice, "Design settings" holds the assay and the product, and "Advanced settings" holds the rules for each primer. The values below are the defaults for the PCR primers assay. Choosing a different assay loads that assay's own values into the same fields, and you can still edit any of them.

**Records.** Chooses which records of a FASTA file or reference bundle become templates. The default ticks every record, because LGE cannot guess which one you want. Untick the rest when you want a design on one sequence. On the command line this is `--fasta-record`, repeated once per record.

**Template row.** Chooses which row of an alignment Primer3 designs on. There is no default, and Run stays disabled until you pick a row. Pick the allele whose coordinates you know, since target positions and results are counted on that row. On the command line this is `--msa-template`.

**Assay.** Chooses the kind of assay and loads its rules into the fields below. The default is "PCR primers", the right choice for an end-point PCR whose product you will sequence or run on a gel. Choose one of the two qPCR assays only for quantitative PCR, which [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers. On the command line this is `--assay`.

**Product minimum (bp).** Sets the shortest product, counted from the first base of the forward primer to the last base of the reverse primer, that Primer3 may return. The default is 100 bases. Raise it with the maximum whenever the product must span a long target. On the command line this is `--product-size-min`.

**Product maximum (bp).** Sets the longest product Primer3 may return. The default is 400 bases, a common size for a gel or a short-read amplicon. Raise it to at least the target length plus room for both primers, which is why this chapter uses 1,100. On the command line this is `--product-size-max`.

**Candidate pairs.** Sets how many primer pairs Primer3 returns for each template. The default is 5, enough to have a choice without a long list to read. Raise it when you expect to discard several pairs after checking them. On the command line this is `--pair-count`.

**Amplify a specific region.** Turns on a target that every product must contain, with the forward primer before it and the reverse primer after it. The default is off, which lets Primer3 place the product anywhere on the template. Turn it on whenever you need particular bases copied, such as the two exons here. This switch has no command-line flag, because giving the two target flags turns it on.

**Target start.** Sets the first base of the target, counted from 1 on the template's own bases. There is no default. Set it a few bases outside the region you need read if you want margin at that end. On the command line this is `--target-start`.

**Target end.** Sets the last base of the target, counted the same way, and it must not be smaller than the start. There is no default. The target must fit inside the product maximum, and LGE refuses to run when it does not. On the command line this is `--target-end`.

**Require binding sites conserved across all alignment rows.** Stops Primer3 from placing a primer over any alignment column where the rows disagree, where any row has a gap, or where a row carries an ambiguous base. It is on by default, because a primer that sits on a variable column will mismatch some of the aligned sequences. Turn it off only to see the best pair for the template row alone, for example to compare it with the conserved design. On the command line this is `--binding-site-policy`, with `exclude-variable-and-gapped-columns` for on and `template-only` for off.

**Primer length (nt).** Sets the minimum, optimum, and maximum primer length in nucleotides. The defaults are 18, 20, and 27, the range most PCR primers fall in. Allow longer primers when a stretch is AT-rich and a short primer cannot reach the melting temperature. On the command line these are `--primer-min-size`, `--primer-opt-size`, and `--primer-max-size`.

**Primer melting temperature (°C).** Sets the minimum, optimum, and maximum melting temperature for each primer. The defaults are 57, 60, and 63 °C, so both primers of a pair work at one annealing temperature near 60 °C. Change the range only when your polymerase or cycling protocol needs a different annealing temperature. On the command line these are `--primer-min-tm`, `--primer-opt-tm`, and `--primer-max-tm`.

**Minimum GC (%).** Sets the lowest share of G and C bases a primer may have. The default is 20%, a loose floor that leaves the melting temperature rules to do most of the work. Raise it toward 40% for a stricter design. On the command line this is `--primer-min-gc`.

**Maximum GC (%).** Sets the highest share of G and C bases a primer may have. The default is 80%, loose enough for a GC-rich gene such as this one. Lower it toward 60% when primers from a design fold or bind too readily. On the command line this is `--primer-max-gc`.

The next four fields sit under "Assay rules (blank keeps Primer3's default)". For PCR primers they start blank, so Primer3 uses its own built-in value. The intercalating-dye qPCR assay fills them in.

**Pair Tm difference max (°C).** Sets the largest melting temperature gap allowed between the forward and reverse primer. The default is blank, Primer3's own value. Fill it in, for example with 1 or 2, when you want the two primers matched tightly. On the command line this is `--pair-max-tm-difference`.

**3′-end G/C max (last 5 nt).** Sets how many of the last five bases at a primer's 3′ end, the end the polymerase extends, may be G or C. The default is blank, Primer3's own value. Set it to 2 or 3 to keep the 3′ end from binding too firmly to partial matches. On the command line this is `--primer-max-end-gc`.

**GC clamp (nt).** Sets how many G or C bases must sit at the very 3′ end. The default is blank, Primer3's own value. Set it to 1 when you want every primer to end on a G or C for a firm start to extension. On the command line this is `--primer-gc-clamp`.

**Poly-X max (nt).** Sets the longest run of one repeated base a primer may contain, such as `GGGGG`. The default is blank, Primer3's own value. Lower it to 4 when runs of G are common, as they are in MHC exons. On the command line this is `--primer-max-poly-x`.

The last four fields sit under "Complementarity thresholds (duplex Tm, °C)". Each is the highest predicted melting temperature allowed for a duplex that a primer could form with itself or its partner, as [primer dimers and hairpins](01-what-is-primer-design.md#hairpins-and-primer-dimers) explains. All four start blank for PCR primers.

**Self, any.** Limits how stably one primer can pair with a copy of itself anywhere along its length. The default is blank, Primer3's own value. Lower it when your pairs form primer dimers on a gel. On the command line this is `--primer-max-self-any-th`.

**Self, 3′ end.** Limits how stably one primer's 3′ end can pair with a copy of itself, the form of self-pairing most likely to be extended. The default is blank, Primer3's own value. Lower it with the one above. On the command line this is `--primer-max-self-end-th`.

**Pair, any.** Limits how stably the forward and reverse primers can pair with each other. The default is blank, Primer3's own value. Lower it when the two primers of a pair form a dimer. On the command line this is `--pair-max-compl-any-th`.

**Pair, 3′ end.** Limits how stably the 3′ end of one primer can pair with the other primer. The default is blank, Primer3's own value. Lower it with the one above. On the command line this is `--pair-max-compl-end-th`.

**Analysis name.** Names the analysis bundle LGE saves in the project's `Analyses` folder. The default is "Primer analysis", with a number added when that name is taken, such as "Primer analysis 2". Give each run a name that says what it designed, because a name already in use blocks Run. On the command line the name is the last part of the `--output` path.

An internal oligo is a third oligo that binds between the two primers, used as a hydrolysis probe in qPCR. The dialog has no separate switch for it. Choosing "qPCR · internal hydrolysis probe" under **Assay** asks Primer3 for one with each pair, and on the command line `--pick-internal-oligo` does the same for any assay. A PCR assay whose product you will sequence does not need one, and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) covers probes.

## Reading the results

A Primer3 analysis opens with three views, **Overview**, **Results**, and **Binding inspection**, chosen with the segmented control at the top.

### The candidate pairs

Click **Results**. The **Template** menu lists each template the analysis designed on. Beneath it a summary line gives the template length, the number of candidate pairs, and a reminder that coordinates are 1-based and inclusive, meaning the first base is base 1 and both end bases count. The **Candidates** list shows "Pair 1" to "Pair 5", each with its product size.

The list keeps Primer3's order. Primer3 gives every pair a penalty, a score that grows as the pair's length, melting temperature, and GC content move away from the optimum values you set. Pair 1 has the lowest penalty, so it sits closest to your optimum settings. A higher-numbered pair is not worse at binding. It is only further from the targets you chose, and it may still be the better pick once you check it against other sequences.

<!-- SHOT: primer3-results-single-record -->

Click a pair to see its primers under "Primer properties". Each primer row gives its position on the template, then its length in nucleotides, its predicted melting temperature, and its GC content on one line. The **Template sequence with selected binding sites** disclosure prints the template 60 bases to a line, with the forward primer in blue and the reverse primer in orange.

The table gives Pair 1 from each design on the reference run.


| Design | Forward primer | Reverse primer | Positions | Product | Tm |
|---|---|---|---|---|---|
| Single allele | GGGAGGGAAATGGCCTCTG | TCCACAGGAGATCAGGGAGG | 89–107 and 1014–1033 | 945 bp | 59.8 and 60.0 °C |
| Alignment, conserved sites | CGGGTCTCAGCCTCTCCT | GAGGATTCCTCTCCCTCAGGA | 178–195 and 1105–1125 | 948 bp | 60.0 and 59.8 °C |

Read a pair against the gene map. Exon 1 ends at base 74 and exon 2 begins at 205, so in both designs the forward primer sits in intron 1. Exon 3 ends at base 993 and exon 4 begins at 1590, so both reverse primers sit in intron 3. Each product therefore holds all of exon 2, intron 2, and all of exon 3. Both primers of each pair sit within 0.2 °C of 60 °C, so one annealing temperature suits both. The reverse primer is written 5′ to 3′ as you would order it, which is the reverse complement of the top-strand bases it binds.

### Why the primers moved

Both designs use the same template, the same target, and the same rules. The only difference is that the second design could not put a primer on any column where the twelve alleles disagree. On this alignment LGE marked 328 excluded regions on the template, stretches where at least one allele differs or has a gap. The first design's primer sites overlap such columns, so the second design moved the forward primer 89 bases downstream, from 89 to 178, and the reverse primer 91 bases downstream, from 1014 to 1105.

The first pair matches LR699574.1 perfectly. On an animal carrying a different Mamu-A1 allele, one or both primers would carry mismatches, and a mismatch near a primer's 3′ end can stop that allele from amplifying at all. That failure is silent. The PCR still gives a band from the alleles that do match, and the genotype you read from the product is missing an allele. Designing on the alignment with conserved binding sites is how LGE keeps primers on bases every aligned allele shares.

### The Primer3 explanation line

Open the **Primer3 explanation** disclosure at the bottom of the Results view. It holds Primer3's own count of the pairs it tried. On the single-allele run it reads "considered 374, unacceptable product size 369, ok 5". Primer3 considered 374 pairs of candidate primers, rejected 369 whose product fell outside the rules for size and target, and kept 5. On the conserved run it reads "considered 177, unacceptable product size 170, ok 7". Fewer pairs were considered, because the excluded columns removed many primer sites. Seven passed and five were returned, because **Candidate pairs** asked for five.

A line with "ok 0" means no pair met every rule. The reason Primer3 names is the last rule each pair failed, which is not always the one that matters. When every primer on a stretch breaks the GC rules, for example, Primer3 can still report all its pairs under "unacceptable product size". The [Troubleshooting](#troubleshooting) table covers what to try.

### The Overview

**Overview** shows one card per candidate pair, labelled with the template name and "Candidate *n*". Each card draws the whole template as a line from base 1 to its last base, 2,933 for LR699574.1. Beneath it sit a row for the product, labelled with its length, and one row for each primer, the forward primer in blue with an arrow pointing right and the reverse primer in orange with an arrow pointing left. The picture shows at a glance where on the gene the product falls. It says nothing about whether the pair will amplify.

### Binding inspection

**Binding inspection** compares each primer with every row of the alignment it was designed on. Open it on the conserved analysis. Choose the alignment under **Target alignment** and a primer under **Compare primer**. A read-only alignment view shows the primer's footprint, and a table below lists every row with what it carries under the primer. The header line reads "MSA matches" with a percentage and a count of rows. A row that matches shows "0 mismatches (IUPAC-compatible)". A row that differs shows the number of positional mismatches, with the mismatched bases in orange, bold, and underlined.

<!-- SHOT: primer3-binding-inspection -->

Because the conserved design excluded every variable and gapped column, every row should match every primer of the conserved design. Check that it does before you order.

The single-allele analysis has no alignment to compare against. Its Binding inspection view says so and suggests designing from an alignment bundle with a template row. To see the first pair's mismatches across the twelve alleles, run the alignment design again with **Require binding sites conserved across all alignment rows** turned off. That design uses LR699574.1 alone, as the first one did, and its Binding inspection shows every row's bases under each primer.

## What good looks like

Check that each pair's product holds the whole target. The forward primer should end before the target start and the reverse primer should start after the target end. Both hold for every pair here.

Check that the two primers of the pair you choose have melting temperatures within about 2 °C of each other, so one annealing temperature serves both. Both Pair 1 results above are within 0.2 °C.

Check the pair against every sequence it must amplify. For a design on the alignment, Binding inspection should show no mismatches in any row. Twelve alleles is a teaching size, and a working laboratory assay would include every allele seen in its colony.

Remember what the design did not check. Conserved across Mamu-A1 alleles is not the same as specific to Mamu-A1, as [Conserved is not the same as specific](01-what-is-primer-design.md#conserved-is-not-the-same-as-specific) explains. The paralogs share much of their sequence, and neither Primer3 nor the conservation filter compares the primers with Mamu-A2, A3, A4, or Mamu-B. [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) shows how to compare primers against a set of sequences an assay must not detect. A computer check of binding is only a prediction, as [in-silico and bench validation](01-what-is-primer-design.md#checking-a-design-in-silico-and-at-the-bench) explains. Test the pair at the bench on DNA from animals with known genotypes before relying on it.

[Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) shows how to copy, export, and order the pair you choose.

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| The dialog lists no inputs and says to select bundles in the sidebar | Nothing supported was selected when the dialog opened | Close it, select a FASTA file, reference bundle, or alignment bundle in the sidebar, and reopen it |
| "Choose a template row for *file*." and Run is disabled | An alignment is an input but no template row is chosen | Pick a row from **Template row** |
| "The target region is 789 bp but the maximum product size is 400 bp." | The product range was left at its defaults while the target spans both exons | Raise **Product maximum (bp)** above the target length, or shorten the target |
| "An analysis with this name already exists in the project." | Another analysis in `Analyses` has that name | Type a different **Analysis name** |
| "No primer pairs met the requested constraints." on a GC-rich stretch | No primer on either side of the target meets the GC and melting temperature rules | Widen the GC range, allow longer primers, or move the target edges a little into the introns |
| Zero pairs on an alignment with conserved sites on | Too few conserved columns remain on one side of the target to hold a primer | Remove rows that are not meant to share the assay, widen the product range so primers can reach further out, or use a design tool with degenerate primers as [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) describes |
| Binding inspection says there is no alignment to compare against | The analysis was designed on a single sequence | Design on an alignment bundle with a template row |

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Run these from inside the project folder. The first command reproduces the single-allele design, with `@0` choosing record 1 of the bundle, since the CLI counts records from 0. The second reproduces the conserved design on alignment row 1.

```bash
cd ~/Documents/"Primer Design.lungfish"

lungfish-cli primers design primer3 \
  --fasta-record "Reference Sequences/mamu-a1-panel.lungfishref@0" \
  --assay pcr \
  --target-start 205 --target-end 993 \
  --product-size-min 800 --product-size-max 1100 \
  --pair-count 5 \
  --output "Analyses/Mamu-A1 exon 2-3 PCR Primer3.lungfishprimeranalysis"

lungfish-cli primers design primer3 \
  --msa-template "Analyses/Multiple Sequence Alignments/mamu-a1-panel.lungfishmsa@0" \
  --binding-site-policy exclude-variable-and-gapped-columns \
  --assay pcr \
  --target-start 205 --target-end 993 \
  --product-size-min 800 --product-size-max 1100 \
  --pair-count 5 \
  --output "Analyses/Mamu-A1 exon 2-3 PCR Primer3 conserved.lungfishprimeranalysis"
```

Every flag left out takes the same default as the dialog. `lungfish-cli primers analysis inspect` followed by the bundle path checks a saved analysis and lists what it holds. [Command-Line Reference](../appendices/cli-reference.md) lists every flag.

## Next

Continue to [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) to cover the whole Mamu-A1 gene with overlapping amplicons, or to [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) to take this pair to an order.
