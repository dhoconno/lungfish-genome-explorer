---
title: Designing qPCR and dPCR Assays
chapter_id: 10-primer-design/04-designing-qpcr-and-dpcr-assays
audience: bench-scientist
prereqs: [10-primer-design/01-what-is-primer-design, 10-primer-design/02-designing-a-pcr-assay, 02-sequences/04-aligning-sequences]
estimated_reading_min: 30
task: Design a quantitative detection assay for the Mamu-A1*001 lineage with varVAMP and Primer3, find that it detects the whole gene family, then find the columns that separate the lineage and design an assay that uses one.
tags: [primer-design, qpcr, dpcr, probe, varvamp, primer3, mhc, macaque, specificity]
tools: [varvamp, primer3, mafft]
parameters_refs: [primer-design.varvamp-qpcr, primer-design.primer3-qpcr, msa.inspection.discriminating-sites]
entry_points:
  - "Tools > PCR Primer Design > varVAMP…"
  - "Tools > PCR Primer Design > Primer3…"
  - "CLI: lungfish-cli primers design varvamp"
  - "CLI: lungfish-cli primers design primer3"
  - "CLI: lungfish-cli msa discriminating-sites"
shots:
  - id: qpcr-varvamp-dialog
    caption: "The PCR Primer Design dialog on varVAMP with Design mode set to qPCR / dPCR primers + probe, the four-allele lineage alignment as its input, 0.99 in the threshold field, and amplicon sizes of 70, 135 and 200."
  - id: qpcr-varvamp-screening
    caption: "The Off-target screening group inside Advanced settings, listing the mamu-class-i-exclusion reference bundle as its one screening source above the Add Sequences to Screen Against… button."
  - id: qpcr-primer3-probe-dialog
    caption: "The PCR Primer Design dialog on Primer3 with Assay set to qPCR · internal hydrolysis probe, showing the probe melting temperature, length and GC fields and the probe Tm offset field beneath them."
  - id: qpcr-varvamp-overview
    caption: "The Overview of the Mamu-A1 001 qPCR varVAMP analysis, headed by the count of 5 reported qPCR assays and showing each assay in its unpooled lane with forward primers, reverse primers and purple probes."
  - id: qpcr-varvamp-offtarget-warning
    caption: "The Overview of the varVAMP qPCR analysis run against the exclusion set, showing an orange warning for each of the five assays, from varVAMP_0 to varVAMP_4, that it could produce off-targets."
  - id: qpcr-discriminating-sites
    caption: "The four-row lineage alignment with each row name prefixed Target and the orange discriminating-sites legend in the viewport's toolbar, beside the Inspector's Discriminating Sites section, whose summary lines give 4 targets, 18 exclusions and 11 discriminating columns above its site table."
  - id: qpcr-primer3-fixed-oligo
    caption: "The Keep these oligos group of the Primer3 dialog, with the anchored reverse primer typed into Reverse primer (as ordered) and GC clamp (nt) set to 0."
illustrations:
  - id: probe-geometry
    brief: "One amplicon drawn as a horizontal line with the forward primer arrow at the left pointing right and the reverse primer arrow at the right pointing left. A probe sits between them on the same strand the forward primer's polymerase reads, 4 to 15 bases from the primer, labeled with its reporter dye at the 5 prime end and quencher at the 3 prime end, and annotated that its Tm sits at least 5 C above both primers and that its 5 prime base is never a G. Add a second small panel showing the polymerase reaching the probe and cutting it, freeing the reporter. Brand palette, probe in the viewport's purple."
glossary_refs: [amplicon, primer, primer-pool, pcr, pcr-ssp, msa, alignment-column, consensus-sequence, degenerate-base, iupac-ambiguity-code, gc-content, gc-clamp, exon, intron, allele, mhc, class-i-mhc, ipd-mhc, blast, probe, hydrolysis-probe, intercalating-dye, qpcr, dpcr, cq, melting-temperature, plugin-pack, operations-panel, sidebar, inspector, specificity, oligo, lineage, paralog, primer-dimer, reference-bundle, mafft, reverse-complement, provenance, tsv, fasta, gap, terminal]
features_refs: [primer-design.varvamp, primer-design.primer3, msa.inspection.discriminating-sites]
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

A quantitative PCR assay does not only ask whether a target is present. [Quantitative PCR](../../GLOSSARY.md#qpcr), or qPCR, reads a fluorescent signal after every cycle, and the cycle at which the signal crosses a threshold, the [Cq](../../GLOSSARY.md#cq), tells you how much template the reaction started with. [Digital PCR](../../GLOSSARY.md#dpcr), or dPCR, splits the same reaction into thousands of partitions and counts the ones that lit up. [qPCR and dPCR](01-what-is-primer-design.md#qpcr-and-dpcr) explains both readouts and the two detection chemistries.

Designing such an assay means choosing two [primers](../../GLOSSARY.md#primer) and often a third [oligo](../../GLOSSARY.md#oligo), a short synthetic DNA strand called a [probe](../../GLOSSARY.md#probe), that binds between them and carries the fluorescent label. The rules differ from an ordinary [PCR](../../GLOSSARY.md#pcr) assay in three ways. Products are short, usually 70 to 200 bases, because quantification assumes every molecule is copied completely in every cycle. [Melting temperatures](../../GLOSSARY.md#melting-temperature), written Tm, the temperature at which half of an oligo's copies have come off their target, are held close together so one annealing temperature suits both primers. And a probe is designed to melt several degrees above the primers, so it is already bound when the polymerase, the enzyme that copies the DNA, reaches it.

<!-- ILLUSTRATION: probe-geometry -->

Lungfish Genome Explorer (LGE) designs these assays two ways. Primer3 has two qPCR presets, one for an [intercalating dye](../../GLOSSARY.md#intercalating-dye) and one for a [hydrolysis probe](../../GLOSSARY.md#hydrolysis-probe), and designs on a single template. varVAMP has a qPCR mode that designs primers and a probe together from a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of an [alignment](../../GLOSSARY.md#msa), related sequences lined up so that matching positions share a column, so one assay can cover several related sequences. Neither is a dPCR optimizer, because a dPCR assay uses the same primers and probe, and the varVAMP dialog says so.

This chapter designs a detection assay, tests it against the sequences it must not detect, and finds that it detects the whole gene family. Then it finds the columns that do separate the target, and designs an assay around one of them.

## Why you would do this

The assay in this chapter detects one lineage of a rhesus macaque [MHC](../../GLOSSARY.md#mhc) [class I](../../GLOSSARY.md#class-i-mhc) gene, the *Mamu-A1\*001* lineage. A [lineage](../../GLOSSARY.md#lineage) is the first field after the asterisk in the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) nomenclature, so `Mamu-A1*001:01:01:01` and `Mamu-A1*001:05:01:01` are two [alleles](../../GLOSSARY.md#allele) of the same *\*001* lineage.

That lineage matters for a specific reason. *Mamu-A1\*001*, published before 2012 as *Mamu-A\*01*, presents a number of SIV peptides to killer T cells, SIV being the simian immunodeficiency virus, the monkey relative of HIV. Two of those peptides are studied far more than the rest, the Gag epitope CM9 and the Tat epitope SL8. An epitope is the short protein fragment an MHC molecule holds up for inspection, and Gag and Tat are two SIV proteins. The responses to both are large and reproducible, so animals carrying this lineage have been used heavily in SIV and HIV vaccine studies, and the structures of the molecule holding both peptides have been solved ([Chu and colleagues 2007](../appendices/bibliography.md#primer-design-background)).

Lineage membership is a statement about the peptide-binding region, which is why sequencing [exon](../../GLOSSARY.md#exon) 2 resolves alleles to lineage level. It is not a statement that every allele in the lineage behaves identically. The structures, the tetramers (fluorescent stains for the T cells that recognize the molecule) and the antibodies for this lineage were made with `Mamu-A1*001:01`, so a study that needs a particular reagent to work should confirm the allele and not only the lineage.

### How a colony types this lineage

A colony that assigns animals to such a study needs to know which animals carry the lineage, quickly and cheaply, for many animals at once. In practice it types them one of two ways, and neither is the assay this chapter designs.

The long-established route is PCR with sequence-specific primers, or [PCR-SSP](../../GLOSSARY.md#pcr-ssp), a single primer pair whose 3′ end, the end the polymerase extends, sits on a position unique to the lineage. The result is scored as a band present or absent on a gel. A second primer pair in the same tube copies a gene every animal carries, and its [amplicon](../../GLOSSARY.md#amplicon), the stretch a primer pair copies, is a control band that must always appear. The current routine method at primate centers is amplicon sequencing of exon 2, which types the whole class I repertoire at lineage level in one assay rather than one lineage at a time, as [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) describes.

The assay designed here is the quantitative version of the first idea, and working through it shows why the discriminating position, and not the conserved one, is what makes such an assay work. [Designing a PCR Assay](02-designing-a-pcr-assay.md) needed primers that work on every *Mamu-A1* allele. This assay must detect all four *\*001* alleles and must not detect the eleven other *Mamu-A1* lineages, one sequence each, or the [paralogs](../../GLOSSARY.md#paralog), related copies of the gene elsewhere in the genome, *Mamu-A2*, *A3*, *A4*, *A6*, *A7* and *B*, which add seven sequences because the set holds two *A7* alleles. Those eighteen sequences, 11 plus 7, are the exclusion set, and the demo project ships them for this purpose. They are a teaching subset, because a real exclusion set would carry more of the *A5* and *A6* minor genes and several *Mamu-B* loci.

## Choosing a tool

Three routes design a quantitative assay in LGE. The property of your data that settles the choice is how much the sequences you must detect differ from each other, and whether you need a probe.

**Primer3 with the intercalating-dye preset** designs two primers and no probe, for a dye that fluoresces in any double-stranded DNA. It walks one template, scores every candidate against a rule set, and returns ranked pairs ([Untergasser and colleagues 2012](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). The preset tightens the ordinary PCR rules because a dye reports every product, including [primer dimers](../../GLOSSARY.md#primer-dimer), short products of two primers stuck to each other, so [specificity](../../GLOSSARY.md#specificity), leaving out what should not be detected, rests on the primers alone. It handles variation only by staying off the variable columns of an alignment when you give it one. It is the cheapest assay to order, and it wins when your target is one known sequence and a melt curve, which heats the finished product to check that it melts as one, can confirm it.

**Primer3 with the hydrolysis-probe preset** designs the same two primers plus an internal oligo carrying a reporter dye and a quencher. Signal rises only when the polymerase cuts that probe, so a product with no probe site, such as a primer dimer, gives no signal, though an off-target product that carries a matching probe site still does. This preset handles variation no better than the dye one, and it demands more of the sequence, because a probe site of the right length, melting temperature and [GC content](../../GLOSSARY.md#gc-content), the share of G and C bases, must exist between the primers. It wins when a dye's readout is not trustworthy enough, which is the usual case for a gene with close relatives, and it is the common choice for dPCR, especially when more than one target is read in one well.

**varVAMP in qPCR mode** designs primers and a probe from a consensus of an alignment that can carry [degenerate bases](../../GLOSSARY.md#degenerate-base), positions ordered as a mixture of two or more bases ([Fuchs and colleagues 2025](../appendices/bibliography.md#tools-installed-by-a-plugin-pack)). It collapses the aligned sequences into one consensus, writing an [ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) wherever they disagree by more than the consensus threshold allows, then searches that consensus for primer and probe sites. It tests its best candidate amplicons for folding and rejects the ones whose structure would compete with the oligos. It reports several independent assays rather than one, and it handles variation directly, since one degenerate oligo covers several versions of a site.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Primer3, dye preset | One assay on one known sequence, read with an intercalating dye | The target is a single sequence and a melt curve can confirm one product | Close relatives could amplify, or the target varies |
| Primer3, probe preset | One assay plus a hydrolysis probe on one known sequence | You need a probe's readout, you are designing for dPCR, or you want to fix an oligo yourself | Several sequences that differ must all be detected by one assay |
| varVAMP, qPCR mode | Primer and probe assays across a set of related sequences | The sequences to detect differ from one another, or you want several independent assays | You have one template only, or you want plain non-degenerate oligos |

None of the three produces a lineage-specific assay by itself, because all three optimize conservation within the set you give them. This chapter starts with varVAMP, because the four *\*001* alleles differ from each other, then runs both Primer3 presets on the same alignment to compare, and then uses Primer3's ability to keep an oligo you chose, which is what finally makes an assay discriminate. For a target that is genuinely one sequence, start with Primer3 and skip varVAMP. To cover a whole gene rather than detect it, a tiled scheme is the right shape, as [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) shows.

## Before you start

Open the Primer Design demo project, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. This chapter uses two of its three [reference bundles](../../GLOSSARY.md#reference-bundle), the folders in which LGE keeps sequences. `mamu-a1-001-lineage` holds the four *Mamu-A1\*001* alleles the assay must detect, and `mamu-class-i-exclusion` holds the eighteen sequences it must not detect. The same records are in the [mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-primer-design), whose notes file lists every accession, allele and length.

Install the Multiple Sequence Alignment and PCR Primer Design [plugin packs](../../GLOSSARY.md#plugin-pack) from **Tools > Plugin Manager…**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows.

The designs need an alignment, because the four alleles differ in length. Select `mamu-a1-001-lineage` in the [sidebar](../../GLOSSARY.md#sidebar) and align it with [MAFFT](../../GLOSSARY.md#mafft), an alignment program, from **Tools > Alignment & Phylogenetics > MAFFT…**, leaving **Strategy** on **Automatic** and clicking **Run**, as [Align the five genomes](../02-sequences/04-aligning-sequences.md#align-the-five-genomes) shows. The result takes the input's name, so it is a 2,960-column alignment of 4 rows called `mamu-a1-001-lineage` under `Analyses/Multiple Sequence Alignments/`, with `LR699574.1` as row 1. Coordinates in this chapter are counted from 1 along that row with both end bases included, and its exon 2 runs from 205 to 474, exon 3 from 718 to 993, exon 4 from 1,590 to 1,865 and exon 5 from 1,968 to 2,084. The one exception is the varVAMP assay table under Reading the results, which counts along varVAMP's consensus, so each number there sits 16 above the same base in row 1.

On the demo run the varVAMP design took about three minutes, nearly half of it for the screen against the exclusion set. Each Primer3 run finished in well under a minute.

## Procedure

The dialog reads its inputs from the sidebar selection when it opens, so select the alignment first.

### Design with varVAMP in qPCR mode

1. Click the `mamu-a1-001-lineage` alignment under `Analyses/Multiple Sequence Alignments`, then choose **Tools > PCR Primer Design > varVAMP…**. Check that **Selected project inputs** lists it with the line "4 alignment rows included".
2. Set **Design mode** to **qPCR / dPCR primers + probe**. Its caption reads "varVAMP uses its qPCR optimizer for primer-and-probe assays. There is no separate dPCR optimizer." The pool line changes to "Assays are unpooled." because each assay is its own reaction and not part of a [pool](../../GLOSSARY.md#primer-pool), the primers mixed in one tube, as [Multiplexing, pools and tiling](01-what-is-primer-design.md#multiplexing-pools-and-tiling) explains, and the amplicon sizes change to 70, 135 and 200, varVAMP's own qPCR bounds. [When a qPCR amplicon is too long](#when-a-qpcr-amplicon-is-too-long) explains why they are short.
3. Type `0.99` in **Cumulative consensus threshold (required)**. qPCR mode has no automatic threshold, so while the field is empty **Run** stays disabled and the status line asks for an explicit threshold. On four sequences 0.99 means all four must agree at a column for it to be written as a plain base, and so does any value above 0.75.
4. Open **Advanced settings**, find "Off-target screening", and click **Add Sequences to Screen Against…**. Choose `mamu-class-i-exclusion` in the project and click **Open**, so the group lists it as its one source. LGE builds the [BLAST](../../GLOSSARY.md#blast) database, the searchable index of those eighteen sequences, itself.
5. Under **Save analysis**, set **Analysis name** to `Mamu-A1 001 qPCR varVAMP`, check that the status line reads "Ready. Progress will appear in Operations.", and click **Run**. The dialog closes and the [Operations Panel](../../GLOSSARY.md#operations-panel) shows a row titled "varVAMP · Mamu-A1 001 qPCR varVAMP", which runs LGE's own command-line program, `lungfish-cli primers design varvamp`, with your settings, so you never type it, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. The row's **Cancel** command stops the run, and **Copy CLI Command** copies the command for anyone who wants to rerun it in [Terminal](../../GLOSSARY.md#terminal), the Mac's command-line app. When the row reports "Primer analysis saved.", LGE opens the new analysis.

    <!-- SHOT: qpcr-varvamp-dialog -->


<!-- SHOT: qpcr-varvamp-screening -->

The probe rules sit under "Advanced settings" in the "qPCR probe constraints" group, which appears only in qPCR mode. Leave them alone for this run, and [Primer Design Settings](../appendices/primer-design-settings.md#varvamp) documents each one.

### Design with the Primer3 probe and dye presets

1. Select the same alignment again, because LGE opened the new analysis, and choose **Tools > PCR Primer Design > Primer3…**. Open the **Template row** menu, which reads **Choose a row…**, and choose row 1, `LR699574.1`, the row Primer3 designs on. **Run** stays disabled until a row is chosen.
2. Set **Assay** to **qPCR · internal hydrolysis probe**. The product range changes to 70 and 150, and the probe fields appear under "Advanced settings" in the "Hydrolysis probe (internal oligo)" group.
3. Under **Design settings**, below the product size fields, leave **Amplify a specific region** off, so Primer3 may place the assay anywhere on the template, and check that **Require binding sites conserved across all alignment rows** is on. [Designing a PCR Assay](02-designing-a-pcr-assay.md#settings) describes both. Set **Analysis name** to `Mamu-A1 001 qPCR Primer3 probe` and click **Run**. The run goes to the Operations Panel as `lungfish-cli primers design primer3`, as the varVAMP one did.

    <!-- SHOT: qpcr-primer3-probe-dialog -->

4. Repeat steps 1 to 3 with **Assay** set to **qPCR · intercalating dye** and the name `Mamu-A1 001 qPCR Primer3 dye`. This preset asks for no probe, so its results have forward and reverse primers only.
5. Run one instructive failure. Repeat steps 1 to 3 with the dye preset and the name `Mamu-A1 001 qPCR Primer3 dye exon 2`, but turn on **Amplify a specific region** and set **Target start** to 300 and **Target end** to 340, inside exon 2. On this alignment that request returns no pairs at all, for the reason [When a preset finds nothing](#when-a-preset-finds-nothing) gives.

## Settings

varVAMP's mode, threshold and sizes sit in "Scheme settings", its folding test, probe and screening settings in "Advanced settings", and Primer3's assay picker in "Design settings". Only the settings a quantitative assay turns on are covered here, followed by the [Discriminating Sites](#discriminating-sites) settings of the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window that describes what is selected. [Designing a PCR Assay](02-designing-a-pcr-assay.md#settings) covers Primer3's shared fields, [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md#settings) covers varVAMP's shared ones, and [Primer Design Settings](../appendices/primer-design-settings.md) covers every field in both.

**Design mode.** Chooses between "Single amplicon", "Tiled amplicons" and "qPCR / dPCR primers + probe". The default is Tiled amplicons, so you must change it for a quantitative assay. Choose the qPCR option for both qPCR and dPCR, since the same primers and probe serve both. On the command line this is `--mode qpcr`.

**Cumulative consensus threshold (required).** Sets how much agreement a base needs before varVAMP's consensus writes it plainly rather than as an ambiguity code. There is no default in qPCR mode and **Run** stays disabled until you type one, unlike the other two modes. Read it as how many of your sequences must agree, so 0.99 on four sequences means all four. On the command line this is `--consensus-threshold`.

**Minimum amplicon size (bp).** Sets the shortest amplicon, counted from the first base of the forward primer to the last base of the reverse primer. In qPCR mode the default is 70, varVAMP's own qPCR minimum rather than the 360 the other modes use. Leave it at the default in most designs. On the command line this is `--amplicon-size-min`.

**Target amplicon size (bp).** Gives the nominal amplicon length, which is kept for display and provenance and does not steer the design. In qPCR mode the default is 135, where the other modes use 400. Leave it at the default in most designs. On the command line this is `--amplicon-size`.

**Maximum amplicon size (bp).** Sets the longest amplicon, counted the same way. In qPCR mode the default is 200, varVAMP's own qPCR maximum rather than the 440 the other modes use. Raise it only with a reason, because a longer amplicon folds more and quantifies less evenly. On the command line this is `--amplicon-size-max`.

**qPCR test count.** Sets how many of the best-scoring candidate amplicons varVAMP folds and tests for secondary structure. The default is 50, and raising it examines more candidates at the cost of the run's slowest step. On the command line this is `--qpcr-test-count`.

**qPCR ΔG setting.** Sets the cutoff for ΔG, the free energy of the folded amplicon in kilocalories per mole, where more negative means a more stable fold, and rejects any amplicon at or below it. The default is −3, varVAMP's own value, so an amplicon folding more stably than that at the lower of its two primer melting temperatures is discarded, because its structure would compete with the primers and probe, as [Secondary structure and free energy](01-what-is-primer-design.md#secondary-structure-and-free-energy) explains. A lower cutoff lets more tightly folded products through, so an amplicon at −4 is rejected by −3 and kept by −5, and lowering it is a last resort when nothing passes. On the command line this is `--qpcr-delta-g`.

**Maximum probe ambiguities (blank = native).** Limits how many ambiguity codes the probe may contain. It is blank by default, which the label calls native, so varVAMP uses its own limit, one fewer than **Maximum primer ambiguities**, the field beside it. Set it to 0 when your supplier will not place a mixed base in a labeled probe, which is worth asking before you design. On the command line this is `--maximum-probe-ambiguities`.

**Add Sequences to Screen Against….** Chooses one or more sets of sequences the primers must not amplify, as alignment bundles, reference bundles or nucleotide [FASTA](../../GLOSSARY.md#fasta) files, from which LGE builds the BLAST database and which it records in [provenance](../../GLOSSARY.md#provenance), the run's record of inputs and settings. Nothing is chosen by default, so the group reads "No screening sequences chosen. Candidates are not checked for off-targets." Add the near relatives the assay must not detect, and read [what a screen does in qPCR mode](#testing-the-lineage-assay-for-specificity), or open "Use an existing BLAST database instead" for a database you built outside LGE, since the two routes exclude each other. On the command line this is `--screen-against`.

**Assay.** Chooses Primer3's rule set and loads it into the fields below, which you can still edit. Choosing "qPCR · intercalating dye" or "qPCR · internal hydrolysis probe" replaces the product range, primer lengths, melting temperatures, GC limits and complementarity thresholds (caps on how strongly a primer may pair with itself or its partner, as [Runs, repeats, hairpins and dimers](01-what-is-primer-design.md#runs-repeats-hairpins-and-dimers) explains) with that preset's values, so pick the assay before you adjust anything. On the command line this is `--assay qpcr-dye` or `--assay qpcr-probe`.

Both presets take their primer rules from the qPCR literature, the MIQE reporting guidelines (minimum information for publication of quantitative real-time PCR experiments) and Thornton and Basu 2011, both in [Primer design background](../appendices/bibliography.md#primer-design-background). Products run 70 to 150 bases, primers 18 to 24 bases with melting temperatures of 58 minimum, 60 optimum and 62 °C maximum and at most 1 °C between the two primers, GC content 40 to 60 percent, and the last five bases at the 3′ end may hold at most 2 G or C bases, with a [GC clamp](../../GLOSSARY.md#gc-clamp) of 1, a G or C as the last base. The dimer thresholds are stricter than Primer3's own, since a dye reports every double-stranded product.

**Probe Tm at least this far above the primers (°C).** Raises the probe's minimum melting temperature to the highest primer melting temperature plus this figure. The default is 5, the standard minimum margin for a probe above its primers, and it matters because the probe window's 64 °C floor and the 62 °C primer ceiling would otherwise allow a gap of only 2 °C. With this preset the effective probe minimum becomes 67 °C, which the saved analysis records. Enter 0 to use the window exactly as typed. On the command line this is `--probe-min-tm-offset-over-primers`.

The rest of the probe window, 64 to 70 °C, 20 to 30 bases and 40 to 80 percent GC, is editable in the same group, and so are two more probe rules. **Probe poly-X max (nt)** caps runs of one base in a probe at 3, tighter than the primers' 4, because a GC-rich probe with a run of four G stacks into a structure that quenches the reporter. **Probe 5′ must-match pattern** holds `hnnnn`, where h means A, C or T and n means any base, which keeps a G off the probe's 5′ end, since a G next to the reporter quenches it. Clear the pattern to leave that rule out.

varVAMP's own probe rules sit in the "qPCR probe constraints" group, and LGE sends every one on every qPCR run. Two of them matter for reading its results. varVAMP requires the probe to melt 5 to 10 °C above the primers, unlike Primer3's window, and to sit 4 to 15 bases beyond a primer's 3′ end, on that primer's own strand, because the polymerase extending from the primer must reach it. varVAMP_0's probe, for example, leaves 12 bases between itself and its forward primer. [Primer Design Settings](../appendices/primer-design-settings.md#varvamp) carries the rest.

### Discriminating Sites

The Discriminating Sites section of an alignment's Inspector, which [Find the columns that discriminate](#find-the-columns-that-discriminate) uses, has eight settings.

**Exclusions.** Chooses where the sequences the assay must not detect come from, **Rows in this alignment** or **Sequences from a file**, whose sequences MAFFT aligns onto the alignment without changing the target coordinates. The default is Rows in this alignment, which suits an alignment that already holds both groups. Choose Sequences from a file when the relatives you must rule out are not in the alignment, as in this chapter. On the command line these are `--exclusions` and `--exclusion-sequences`.

**Exclusion sequences.** This menu, which has no visible label and sits beside **Choose File…**, names the file of exclusion sequences and appears only with Sequences from a file. It reads **Choose…** until you pick, and it lists the reference bundles in the project's `Reference Sequences` folder, while **Choose File…** picks a FASTA file or reference bundle from anywhere. Pick the set of near relatives your assay must miss. On the command line this is `--exclusion-sequences`.

**Rows.** Gives each row of the alignment a role, **Target** for a sequence the assay must detect or **Skip** to leave it out, plus **Exclusion** when the exclusions are rows, and the heading reads **Target rows** when they come from a file. Every row starts as Target, and **All Targets** sets every row back to it. Mark a poor or partial sequence Skip, and mark relatives Exclusion when they are rows of this alignment. On the command line these are `--targets` and `--exclusions`.

**Template.** Names the target row whose positions, counted from 1, the report uses. The default is **First target**, here row 1, `LR699574.1`, the row this chapter's coordinates follow. Choose another target when your lab numbers positions on a different allele. On the command line this is `--template`.

**Target mismatch tolerance.** Sets how many target rows may carry a different base at a column and still let it count. The default is 0, so every target must agree, which is what an assay for the whole lineage needs. Raise it to 1 only for a target you can afford to miss, which on the demo adds position 952 in exon 3, and keep it below the number of target rows. On the command line this is `--target-mismatch-tolerance`.

**Window length (bp).** Sets the length, in template bases, of the candidate windows that group nearby discriminating columns. The default is 25, about a probe's length. Set it to the length of what you plan to place, such as 150 to find a region for a whole qPCR amplicon. On the command line this is `--window-length`.

**Exclusions that must differ.** Sets how many exclusion sequences must carry another base at a column. It is blank by default, shown as All, so a column must separate the targets from every exclusion. Lower it only when no column qualifies, since each step leaves some relatives detectable, and on the demo 17 gives 18 columns and 15 gives 41. On the command line this is `--min-exclusion-differences`.

**Highlight in viewport.** Appears with the results, and tints the reported columns in the alignment, puts `Target ·` or `Exclusion ·` before each row name in the left margin, and shows a legend in the viewport's toolbar. It is on by default, so a finished run shows its columns at once. Turn it off to read the alignment without the marks. This setting has no command-line flag.

## Reading the results

LGE opens `Mamu-A1 001 qPCR varVAMP` when the run ends, and it also sits under `Analyses` in the sidebar, as [Open a saved analysis](05-reviewing-and-ordering-primers.md#open-a-saved-analysis) shows. A saved analysis has three views, **Overview**, **Results** and [**Binding inspection**](05-reviewing-and-ordering-primers.md#inspect-binding-against-the-alignment), chosen with the control at the top of the viewport. A varVAMP qPCR analysis reports several independent assays rather than one scheme, so read it assay by assay.

<!-- SHOT: qpcr-varvamp-overview -->

The **Overview** shows one card, and its headline is a count of assays, 5, labeled "reported qPCR assays, each an independent alternative", because the assays are alternatives you choose among rather than a set you run together. The line under it gives the consensus length and says the spans of individual assays overlap and are not additive. The lanes beneath are labeled "Unpooled · selected assay" and "Unpooled · alternative rank" with a number, which are display groupings and not pools. Each assay draws its forward primer in blue, its reverse primer in orange and its probe in purple.

The demo run returned five assays on the four-allele alignment, and LGE marks the lowest-penalty one as selected, in the lane labeled "Unpooled · selected assay". varVAMP_0 and varVAMP_1 both show 2.2, which may hide a difference in the next decimal, so read that lane to see which one LGE chose. The Region column converts the Amplicon spans to row 1 by the 16 noted under Before you start.

| Assay | Amplicon | Length | Region in row 1 | ΔG | Penalty |
|---|---|---|---|---|---|
| varVAMP_0 | 1070 to 1250 | 181 bp | intron 3 | −2.2 | 2.2 |
| varVAMP_1 | 2649 to 2731 | 83 bp | after exon 5 | −0.3 | 2.2 |
| varVAMP_2 | 2430 to 2604 | 175 bp | after exon 5 | −1.4 | 2.8 |
| varVAMP_3 | 1679 to 1847 | 169 bp | exon 4 | −1.7 | 3.3 |
| varVAMP_4 | 392 to 487 | 96 bp | exon 2 | −1.4 | 4.6 |

Read the two right-hand numbers the way varVAMP means them. No LGE view shows them, since they come from varVAMP's own design table, which the Inspector's **Files** tab lists and reveals in Finder. The penalty adds up how far the assay's oligos sit from the optimum length, melting temperature and GC content, plus a charge for ambiguity codes and for sequences that mismatch near a 3′ end, so it is a distance from your settings and not a prediction of performance. A penalty of 0 would mean every oligo sits at its optimum with nothing charged, so use the number to rank assays and not as a pass mark. The spread here, 2.2 to 4.6, is narrow enough that the choice between assays should rest on specificity instead. The ΔG is the folding free energy of the amplicon at the lower of its two primer melting temperatures, and every value here is above the −3 cutoff, meaning less negative and so less folded, with varVAMP_1 at −0.3 barely folding at all, which is what you want from an 83-base product.

The **Results** view lists the oligos of each assay with their lengths and GC content, and the melting temperatures below come from varVAMP's own table of oligos, which the **Files** tab lists too. Click varVAMP_0 to see the shape a hydrolysis-probe assay should have.

| Role | Sequence | Length | Tm |
|---|---|---|---|
| Forward primer | CAAAGAGGGGAGACAAATGGGA | 22 nt | 60.1 °C |
| Probe | TATCGCCCTCCCTCTGKTCCTGAGG | 25 nt | 67.3 °C |
| Reverse primer | TTCGAGGGATCGTCTTTCCTTC | 22 nt | 60.0 °C |

The two primers sit within 0.1 °C of each other, so one annealing temperature suits both, and the probe sits about 7 °C above them, so it is bound before the polymerase arrives. The `K` in the probe stands for G or T, so the probe is ordered as a mixture of two sequences, each at half the concentration, and the **Results** view marks it in orange as an ambiguous base whose synthesis you should check with your supplier.

The Primer3 probe analysis reads differently, because Primer3 returns ranked alternatives rather than independent assays. Its top three pairs on the demo run, of the five it returns, all sit in exon 5 and the first bases of the [intron](../../GLOSSARY.md#intron) after it.

| Forward | Probe | Reverse | Product |
|---|---|---|---|
| TCATTGCTGGCCTGGTTCTC, 2004 to 2023, Tm 60.3 | TGGAGCTGTGGTCACTGGAGCTGTGGTTGC, 2026 to 2055, Tm 67.0 | GCTCTTCCTCCTCCACATCAC, 2060 to 2080, Tm 60.1 | 77 bp |
| TCATTGCTGGCCTGGTTCTC, 2004 to 2023, Tm 60.3 | TGGAGCTGTGGTCACTGGAGCTGTGGTTGC, 2026 to 2055, Tm 67.0 | CCTTCCTCACCTGAGCTCTTC, 2074 to 2094, Tm 59.8 | 91 bp |
| TCATTGCTGGCCTGGTTCTC, 2004 to 2023, Tm 60.3 | TGGAGCTGTGGTCACTGGAGCTGTGGTTGC, 2026 to 2055, Tm 67.0 | GAGCTCTTCCTCCTCCACATC, 2062 to 2082, Tm 59.6 | 79 bp |

Every probe sits 6.7 to 7.7 °C above its primers across all five pairs the run returned, which is the offset rule working, and none begins with a G. A probe works on either strand, so a G-rich probe can often be ordered as its [reverse complement](../../GLOSSARY.md#reverse-complement), the other strand's sequence, written by reading the probe backward and swapping A with T and C with G, which is C-rich and usually the better choice, as long as the reverse complement does not start with G.

The **Primer3 explanation** disclosure, a triangle you click to open, sits at the foot of the **Results** view and holds Primer3's own tally, one line per oligo role and one for the pairs. A run that returned no pairs shows it too, under the line "No primer pairs met the requested constraints." For the probe run the pair line ends "no internal oligo 31, ok 7". Here "ok 7" counts the pairs that passed every test, of which LGE returns the best five because **Candidate pairs** defaults to 5, and "no internal oligo" counts pairs that were fine as primers but had no acceptable probe site between them, which is the extra demand a probe places on the sequence. The probe line shows what a GC-rich target does to a probe search, with 18,937 candidates considered, 8,839 falling below the raised 67 °C floor and 5,875 failing the no-G rule at the 5′ end, with other rules removing the rest and leaving 656.

### When a preset finds nothing

Targeted at exon 2, the dye preset returned nothing, and its explanation lines say why. An N here is a template base that LGE hid from Primer3 because the four alleles differ there or one has a gap, so "too many Ns" counts candidates that cover such a base.

```text
Left primer: considered 1547, too many Ns 72, GC content failed 1453, GC clamp failed 12, low tm 6, high tm 1, ok 2
Right primer: considered 9049, too many Ns 497, GC content failed 6408, GC clamp failed 653, low tm 486, high tm 137, long poly-x seq 13, ok 330
Pair: considered 660, unacceptable product size 660, ok 0
```

The pair line alone would mislead. It reports "unacceptable product size" for all 660, because Primer3 builds pairs only from primers that already passed every single-primer rule and reports the first pair test that fails, which is product size. The real limit is in the left-primer line. Of 1,547 candidate forward primers upstream of the target, 1,453 failed the 40 to 60 percent GC window, leaving 2, and every pair those two could form with an acceptable reverse primer is longer than 150 bases. Whenever a run reports "ok 0", read the single-oligo lines first.

Two responses are open. Move the target, which keeps the preset intact but may give up the variable sites you need, or relax the GC maximum to about 65 or 70 percent and the melting-temperature maximum by a degree or two, then confirm efficiency, how close each cycle comes to doubling the product, with a standard curve, a dilution series that measures it, as [Bench validation](05-reviewing-and-ordering-primers.md#bench-validation) shows. For a lineage assay the variable exons are the first place to look for discrimination, which the column search below partly overturns, so relaxing is often the right choice, and the rest of this chapter takes that route.

### When a qPCR amplicon is too long

The short amplicon bounds in qPCR mode are not a stylistic choice, as an optional test shows. Set **Minimum amplicon size (bp)**, **Target amplicon size (bp)** and **Maximum amplicon size (bp)** to 360, 400 and 440, since the target amplicon size must sit between the other two, and run the same varVAMP design again. After about fifteen minutes it fails with "no qPCR amplicon passed the deltaG threshold". Every candidate 400-base stretch of this GC-rich sequence folds more stably than the −3 cutoff, so the filter discards all of them, and folding candidates that long is the slowest step of the run. A longer strand, and a GC-rich one most of all, folds more stably, which is why every candidate passed only once the products were short.

## Testing the lineage assay for specificity

Everything so far worked. Five varVAMP assays passed every filter, every oligo matches all four *\*001* alleles perfectly, and both Primer3 presets returned clean pairs with well placed probes. Now test the assay against the requirement, which is that it must not detect the other eighteen sequences.

Comparing every varVAMP oligo against every exclusion sequence gives the result that matters, and LGE has no view that does it. **Binding inspection** compares an oligo only with the rows of the alignment the design was made on, and the eighteen exclusion sequences were never rows of it. So the counts here come from searching each of the eighteen sequences for an oligo's exact letters. The command `lungfish-cli search`, which the [CLI Reference](../appendices/cli-reference.md#search) describes, does that in Terminal on `mamu-class-i-exclusion.fasta` from the fixture folder, on both strands, so a reverse primer can be typed as ordered, and its `--iupac` option reads a `K` as G or T. Each hit is one output row that starts with the sequence's name, so the count is the number of different names. The mismatch positions below come from lining each oligo up against its best-matching stretch of each sequence. What LGE does show is the base each exclusion sequence carries at the columns its Discriminating Sites section reports, which [Find the columns that discriminate](#find-the-columns-that-discriminate) uses to check an oligo's 3′ end.

Not one of the five assays is shown to be specific to the lineage, and the table counts, for each oligo, how many of the eighteen non-target sequences it matches perfectly.

| Assay | Forward | Probe | Reverse |
|---|---|---|---|
| varVAMP_0 | 0 of 18 | 11 of 18 | 1 of 18 |
| varVAMP_1 | 0 of 18 | 12 of 18 | 16 of 18 |
| varVAMP_2 | 11 of 18 | 15 of 18 | 0 of 18 |
| varVAMP_3 | 17 of 18 | 4 of 18 | 15 of 18 |
| varVAMP_4 | 11 of 18 | 2 of 18 | 17 of 18 |

A perfect-match count is the strictest test and not the whole one, because a primer still starts a copy across a mismatch that sits away from its 3′ end. So a low count such as varVAMP_0's 0 and 1 of 18 for its primers does not clear an assay, and its probe matches 11. Where the mismatches fall matters more than how many. varVAMP_1's forward primer `TAACCCCACAGTTCCTCCTCT` is the most discriminating oligo in the set, and against most exclusion sequences its three or four mismatches sit 17, 19 and 20 bases from the 3′ end, at the 5′ end where they are usually tolerated. On eight of them, including both *A7* alleles, there is also a mismatch one base from the 3′ end, which does discriminate. Against *A1\*041* the only mismatch is the 5′-most base, so that lineage would amplify almost as well as *\*001*. So varVAMP_1 partly discriminates, and an assay whose two primers both bind a non-target sequence can amplify it.

varVAMP's own screen reaches the same verdict independently. The procedure's run screened against the eighteen exclusion sequences and returned the same five assays a run without the screen returns, each marked as producing off-target amplicons, products from a sequence you did not mean to amplify, and its **Overview** shows five warnings of this form.

```text
varVAMP warning: varVAMP_0 could produce off-targets. No better amplicon in this area was found.
```

<!-- SHOT: qpcr-varvamp-offtarget-warning -->

The second sentence is varVAMP's standard wording, and in qPCR mode it does not mean a cleaner assay was looked for. In a qPCR design the screen checks the assays and does not steer them. varVAMP picks the assays it would pick with no screen, warns on each one that could amplify a screening sequence, and numbers the unflagged ones first, while LGE still selects the lowest-penalty assay, so read the warnings before you accept it. The single-amplicon and tiled modes differ, because there varVAMP prefers amplicons the screen did not flag.

The Primer3 results tell the same story from the other direction. The probe pairs above sit in exon 5 and just past it, four of the five dye pairs lie in exon 4, exon 5 or the intron between them, and the first probe pair's two primers both match six of the eighteen exclusion sequences perfectly, as counted below. Exons 2 and 3 encode the groove that holds the peptide, where selection drives alleles apart. Exon 4 encodes the domain that docks on CD8, a protein on killer T cells, and every class I molecule must dock the same way, so it is conserved across the class I genes and even across species. An assay there detects *Mamu* class I broadly rather than the *\*001* lineage.

None of this is a malfunction. A design engine maximizes conservation within the set of sequences you give it, and in a duplicated gene family the sites four closely related alleles share are largely the sites the whole family shares. [Conserved is not the same as specific](01-what-is-primer-design.md#conserved-is-not-the-same-as-specific) states the principle, and these numbers are what it looks like on real sequence.

### Find the columns that discriminate

Specificity starts from a different question. Instead of asking where the targets agree, ask where the targets agree with each other and differ from everything else. LGE answers it with one command, which aligns the exclusion sequences onto the target alignment with MAFFT and then reports every column where all the targets carry one base and every exclusion sequence carries another. A reader who will not use Terminal can skip the command below, because the Inspector steps after it run the same command.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Primer Design.lungfish"

lungfish-cli msa discriminating-sites \
  "$PROJECT/Analyses/Multiple Sequence Alignments/mamu-a1-001-lineage.lungfishmsa" \
  --exclusion-sequences "$PROJECT/Reference Sequences/mamu-class-i-exclusion.lungfishref" \
  --window-length 25 \
  --output "$PROJECT/Analyses/mamu-a1-001-discriminating-sites.tsv"
```

1. Click `mamu-a1-001-lineage` under `Analyses/Multiple Sequence Alignments` in the sidebar, and open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.
2. On the Inspector's **Bundle** tab, click the triangle of the **Discriminating Sites** section to expand it.
3. Under **Exclusions**, choose **Sequences from a file**. Open the menu beside **Choose File…**, which reads **Choose…** until you pick, and choose the `mamu-class-i-exclusion` reference bundle.
4. Leave every row under **Target rows** set to **Target**, and leave the other settings at their defaults, which [Discriminating Sites](#discriminating-sites) describes.
5. Click **Find Discriminating Sites**. The Operations Panel shows a row titled "Find Discriminating Sites", which runs `lungfish-cli msa discriminating-sites` and leaves the same provenance record the command does, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes.

<!-- SHOT: qpcr-discriminating-sites -->

The section then shows summary lines, here 4 targets with `LR699574.1` as the template, 18 exclusions and 11 discriminating columns. The site table below has the columns **Column**, the alignment column, **Template**, the position on the template row, **Target**, the target base, **Differing**, how many exclusion sequences carry another base, and **Exclusions**, which names each one with its base. Under it the **Candidate windows** table gives each window's **Template span**, its number of **Sites** and their **Positions**. **Copy TSV** copies the site table as [TSV](../../GLOSSARY.md#tsv), tab-separated text, and **Export TSV…** and **Export JSON…** run the command again into a file you name. Clicking a row of the site table moves the viewport to that column.

To read the base under an oligo's 3′ end, use the site table this way.

1. Find the oligo's 3′-terminal position on row 1, which is the higher of a forward primer's two end positions and the lower of a reverse primer's. A varVAMP position counts along its consensus, so subtract 16 first.
2. Find the table row whose **Template** equals that position. With the default settings, no row means that the column is not one where all the targets carry one base and every exclusion sequence carries another. For an oligo that matches all four targets with a plain base at its 3′ end, the cause is an exclusion sequence that carries the target's base, a gap or an ambiguity code there, so the oligo has no clear mismatch at its last base against that sequence.
3. Read **Differing**, which is 18 for every row under the default **Exclusions that must differ**, and the **Exclusions** cell, which lists each exclusion sequence as its name, a colon and the base it carries there.

The exclusion sequences came from a file, so the viewport still draws only the alignment's four rows, each prefixed `Target ·`. The legend in the toolbar above them names the exclusions instead, reading `Discriminating sites: 11 columns · Target rows 4 · Exclusion sequences 18 from mamu-class-i-exclusion`.

On the demo's four targets and eighteen exclusions it finds eleven discriminating columns, and only three of them fall in exons 2 and 3, where the alleles differ most.

| Template position | Target base | Exclusion bases | Region |
|---|---|---|---|
| 220 | A | G | exon 2 |
| 679 | A | C or G | intron 2 |
| 911 | C | G | exon 3 |
| 990 | A | G | exon 3 |
| 1008 | A | G | intron 3 |
| 1057 | A | G | intron 3 |
| 1851, 1860 | A, A | T, G | exon 4 |
| 1907 | T | A or C | intron 4 |
| 2633, 2876 | T, G | C, C or T | intron |

That is the first surprise. A reader told to look in exons 2 and 3 finds very little there. Those exons vary a lot, but probably among the eighteen too, so at most variable columns some exclusion sequence carries the targets' base, and a column is reported only when all eighteen differ. Most of what separates this lineage from its relatives sits outside them, much of it in introns. The report also groups clustered columns into candidate windows of the length you ask for, and at 25 bases, a probe's length, two windows hold two sites each, 990 to 1008 and 1851 to 1860. At 150 bases, a qPCR amplicon's length, the strongest region is 911 to 1057, with four sites.

[Gaps](../../GLOSSARY.md#gap), the places where the aligner left a row empty, and ambiguity codes count as no call rather than as a difference, so a column is reported only on real evidence. **Target mismatch tolerance** and **Exclusions that must differ** widen the report, and [Discriminating Sites](#discriminating-sites) gives what each adds on the demo.

### Why the exon cluster cannot carry a primer 3′ end

The cluster at 911 to 1057 looks like the obvious place to design, and it is not. To see why, repeat steps 1 to 3 of [Design with the Primer3 probe and dye presets](#design-with-the-primer3-probe-and-dye-presets) with the probe preset and the name `Mamu-A1 001 qPCR forward 990`, but before you click **Run** in step 3, anchor a forward primer's 3′ end on the cluster by typing 990 into **Forward 3′ end** in the "Keep these oligos (design the rest around them)" group under **Advanced settings**. Primer3 then reports this.

```text
Left primer: considered 7, too many Ns 2, GC content failed 5, ok 0
```

Only seven candidates exist, since the anchor fixes one end and only the length varies, and every one fails the GC window. Forced primers ending on these columns run 63 to 77 percent GC, because MHC class I exons are GC-rich. Widen the GC maximum to 75 percent and the next rule appears, a failed GC clamp, because position 990 carries an A and the qPCR preset requires a G or C at the 3′ end. A primer 3′ end anchored on a discriminating A or T can never satisfy a GC clamp, so those two settings exclude each other, and the clamp has to go to 0. With the clamp at 0 the remaining candidates still fail the preset's limit of 2 G or C bases among the last five, then its 62 °C melting-temperature ceiling, and once both are lifted they fail the self-complementarity limit, which caps how strongly a primer pairs with itself, so a site this GC-rich asks more of a primer than the preset allows. A probe covering both 990 and 1008 is no better, since every window spanning them runs 70 to 80 percent GC and contains `GGGG`, the run the probe's poly-X cap of 3 exists to prevent.

So the usable cluster is the one from 1851 to 1907, at the end of exon 4 and the start of intron 4, and the per-oligo explanation lines are what identified most of the blocking rules. Without them the pair line reads "considered 0, ok 0" and says nothing.

### Anchor a primer's 3′ end on a discriminating column

Column 1907 sits inside the usable cluster, at its right-hand end, and its target base is T. A reverse primer's 3′ end is its left end, so a reverse primer ending on 1907 keeps 1851 and 1860 inside the amplicon. Its sequence is the reverse complement of the template at 1,907 to 1,926.

```text
Row 1, 1,907 to 1,926        5′ TGGAGCCTTTCTAGAGACCT 3′
Reverse primer, as ordered   5′ AGGTCTCTAGAAAGGCTCCA 3′
```

To write the primer, read the template from 1,926 back to 1,907 and swap each base for its partner, A for T and C for G, so the last base written, at the primer's 3′ end, is the A that pairs with the T at 1,907. Typing the sequence fixes all twenty bases. A position box such as **Reverse 3′ end** fixes only the last base's place and leaves the length to Primer3, as for the forward 990 anchor, so it could return a different oligo from the one tested below.

Two preset rules had to be widened for this primer. Its melting temperature is 57.1 °C, below the preset's 58 °C floor, so **Minimum** under "Primer melting temperature (°C)" goes to 56. Its 3′ end carries three G or C bases among the last five against the preset's limit of 2, so **3′-end G/C max (last 5 nt)**, under "Assay rules (blank keeps Primer3's default)", goes to 4, one above its three. Two more fields change. **GC clamp (nt)**, in that row, goes to 0 because the primer ends in A, the reason given above, and **Maximum GC (%)**, below the melting temperatures, goes to 70 so that GC-rich forward primers stay in play, though the best pair's primers, at 55.0 and 50.0 percent, would pass without it.

Type that sequence into **Reverse primer (as ordered)** in the "Keep these oligos (design the rest around them)" group, set those four fields, name the run `Mamu-A1 001 qPCR anchored`, and run the probe preset again with row 1 as the template and the conserved-sites switch on, as before. Primer3 honors the fixed oligo and designs the rest around it, and its explanation lines confirm it.

```text
Right primer: considered 1, ok 1
Pair: considered 2151, unacceptable product size 2036, tm diff too large 110, ok 5
```

<!-- SHOT: qpcr-primer3-fixed-oligo -->

The best of the five pairs is a 136 bp assay.

| Oligo | Sequence | Template | Tm | GC |
|---|---|---|---|---|
| Forward | CTTCTGGAGAGGAGCAGAGA | 1791 to 1810 | 57.9 °C | 55.0% |
| Probe | TGTGCAGCATGAGGGTCTGCCCAAGCCC | 1822 to 1849 | 67.8 °C | 64.3% |
| Reverse, as ordered | AGGTCTCTAGAAAGGCTCCA | 1907 to 1926 | 57.1 °C | 50.0% |

Now test it in two parts. In **Binding inspection**, choosing each of the three oligos of Candidate 1 in **Compare primer** shows 0 mismatches on all four target rows. Against the eighteen exclusion sequences, the exact-match counts come from `lungfish-cli search`, as [Testing the lineage assay for specificity](#testing-the-lineage-assay-for-specificity) explains. The forward primer matches 3 of the 18 perfectly and the probe matches 4, but the anchored reverse primer matches none of them, against 10 of 18 for the reverse primer of the free design, the first probe run, where Primer3 chose both primers itself. Better still, the site table row for position 1907 reads 18 under **Differing**, so the mismatch sits at the 3′-terminal base in all eighteen, seventeen of which carry a C and one an A where the targets carry T, which is where a mismatch most strongly blocks extension. Six exclusion sequences had matched both primers of the free design's first pair perfectly and would have amplified, and each now carries two or three mismatches in the reverse primer.

The probe's Tm is 9.98 °C above the higher primer, well clear of the 5 °C floor, and its longest run of one base is 3, so the poly-X cap kept `GGGG` out of a 64 percent GC probe. What this assay does not have is a discriminating probe. No probe can cover position 1851 or 1860, because every 20 to 30 base window over either holds a run of four C or four G, which the probe's poly-X cap of 3 forbids, so the reverse primer carries the discrimination alone. That is honest rather than ideal, and it is why the bench test matters. Of the designs in this chapter, this anchored assay is the one to order. Export its 136 bp pair from `Mamu-A1 001 qPCR anchored` as [Export an order](05-reviewing-and-ordering-primers.md#export-an-order) shows, and enter the synthesis options as [Placing the order](05-reviewing-and-ordering-primers.md#placing-the-order) lists.

### What to do next

Anchoring one 3′ end is one of three tools, with a deliberate second mismatch in the primer and a discriminating base under the probe, and a real design uses more than one. Kwok and colleagues 1990 found that a primer's 3′-terminal T mismatched against G, C or T on the template has minimal effect even with a second mismatch nearby, so one discriminating base is not always enough. The anchored reverse primer ends in A, so the finding does not describe it, but the lesson holds. Allele-specific primers therefore often add a deliberate second mismatch two or three bases in, to destabilize the non-target further, and they need a polymerase without 3′ to 5′ proofreading, because a high-fidelity enzyme removes the mismatched 3′ base and amplifies the non-target anyway. LGE cannot place that second mismatch, because its "Keep these oligos (design the rest around them)" boxes accept only a sequence found in the template.

The probe is the other place to put a difference. A standard 25-base probe designed for a high melting temperature usually still binds across a single mismatch, so it discriminates poorly, and the way to use a probe for discrimination is a short minor-groove-binder probe, which carries a molecule that stabilizes its binding so a short probe still melts high, of about 13 to 18 bases centered on the discriminating base, often as two competing probes labeled with different dyes. A supplier's design service can advise, and that is outside what these engines design.

Then test it properly. Run the assay on DNA from animals typed as carrying *Mamu-A1\*001* and on animals typed as lacking it, since a specificity claim rests on the negatives, and [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) is one way to establish those types. Use the same template the assay will meet in service, genomic DNA from blood. [Bench validation](05-reviewing-and-ordering-primers.md#bench-validation) lists the tests in order.

## What good looks like

A quantitative assay worth ordering passes the checks below before it costs you anything.

- Both primers sit within about 1 °C of each other, and a probe sits at least 5 °C above the higher of them. varVAMP_0's 60.1, 60.0 and 67.3 °C is the pattern.
- The product is short, inside 70 to 200 bases, and its ΔG sits clear of the −3 cutoff, as every varVAMP assay here does.
- Every sequence the assay must detect shows zero mismatches in **Binding inspection**, as all four lineage alleles do for every design in this chapter.
- The design has been compared against the sequences it must not detect, and at least one oligo carries a mismatch at its 3′-terminal base against every one of them, which the site table shows as [Find the columns that discriminate](#find-the-columns-that-discriminate) describes.
- A probe carrying an ambiguity code has been checked with your supplier, and the assay has a no-template control and a control assay every sample should pass.

The fourth check is the one the first designs fail and the anchored design passes, and failing it in LGE is much cheaper than failing it after the oligos arrive.

### When the design fails

**Run** stays disabled while **Cumulative consensus threshold (required)** is empty, because qPCR mode requires an explicit value. A long run that ends with "no qPCR amplicon passed the deltaG threshold" means the size bounds are too wide for GC-rich sequence, so return them to 70, 135 and 200 before touching the ΔG setting. A target longer than the product maximum is refused up front with "The target region is 270 bp but the maximum product size is 150 bp. Every product must span the whole target, so widen the product size range or choose a shorter target." A probe run whose explanation line shows "no internal oligo" found acceptable primers with no valid probe site between them, so widen the product range a little or use the dye preset. The dialog accepts only A, C, G and T in a fixed oligo and says so in red under the fields. An oligo that does not occur in the template stops the run before Primer3 starts, with a message that names it and asks you to check its sequence and orientation, since a reverse primer is typed 5′ to 3′ as you would order it rather than as the top-strand bases it binds.

## On the command line

This section is optional. Every block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and the flags are listed under [Primer schemes and primer design](../appendices/cli-reference.md#primer-schemes-and-primer-design). These commands reproduce the three first designs and the anchored one.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Primer Design.lungfish"
ALIGN="$PROJECT/Analyses/Multiple Sequence Alignments/mamu-a1-001-lineage.lungfishmsa"

lungfish-cli primers design varvamp \
  --msa "$ALIGN" --mode qpcr --consensus-threshold 0.99 \
  --screen-against "$PROJECT/Reference Sequences/mamu-class-i-exclusion.lungfishref" \
  --project "$PROJECT" --name "Mamu-A1 001 qPCR varVAMP"

lungfish-cli primers design primer3 \
  --msa-template "$ALIGN@0" --assay qpcr-probe \
  --project "$PROJECT" --name "Mamu-A1 001 qPCR Primer3 probe"

lungfish-cli primers design primer3 \
  --msa-template "$ALIGN@0" --assay qpcr-dye \
  --project "$PROJECT" --name "Mamu-A1 001 qPCR Primer3 dye"

lungfish-cli primers design primer3 \
  --msa-template "$ALIGN@0" --assay qpcr-probe \
  --right-primer AGGTCTCTAGAAAGGCTCCA \
  --primer-min-tm 56 --primer-max-gc 70 \
  --primer-gc-clamp 0 --primer-max-end-gc 4 \
  --project "$PROJECT" --name "Mamu-A1 001 qPCR anchored"
```

`--project` and `--name` write each bundle into the project's `Analyses` folder as the dialog does, and when a name is in use the command takes the next free one and reports the path it wrote. `@0` picks the first row, because `--msa-template` counts rows from 0. Every flag left out takes the preset's own default, so these short commands match the dialog runs, while the command the Operations row copies spells out every value. `--assay qpcr-probe` implies `--pick-internal-oligo`. `--force-left-end` and `--force-right-end` take a template position instead of a sequence, and `--probe` fixes a probe the same way `--right-primer` fixes a primer. The varVAMP command prints the card's advisories and warnings as `[info]` and `[warning]` lines, and every Primer3 run prints its per-oligo explanation lines. `lungfish-cli primers analysis inspect` on a finished bundle verifies it and lists what it holds.

## Next

Continue to [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) to check these assays oligo by oligo, export an order, and work through the bench validation sequence. To design a primer pair without a probe, see [Designing a PCR Assay](02-designing-a-pcr-assay.md), and to cover a whole gene rather than detect it, see [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md).
