---
title: What Is Primer Design
chapter_id: 10-primer-design/01-what-is-primer-design
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 02-sequences/04-aligning-sequences]
estimated_reading_min: 24
task: Understand how PCR primers work, what makes a primer good or bad, why sequence variation and related genes complicate design, and which of LGE's four primer design engines fits which job.
tags: [primer-design, pcr, qpcr, dpcr, primer, amplicon, tiling, mhc, macaque]
tools: [primer3, primalscheme3, olivar, varvamp]
parameters_refs: []
entry_points:
  - "Tools > PCR Primer Design > Primer3…"
  - "Tools > PCR Primer Design > PrimalScheme…"
  - "Tools > PCR Primer Design > Olivar…"
  - "Tools > PCR Primer Design > varVAMP…"
shots:
  - id: primer-design-submenu
    caption: "The Tools menu open on its PCR Primer Design submenu, showing the four engines in order, Primer3…, PrimalScheme…, Olivar…, and varVAMP…"
illustrations: []
glossary_refs: [allele, alignment-column, amplicon, amplicon-dropout, blast, class-i-mhc, consensus-sequence, exon, gap, gc-content, intron, ipd-mhc, iupac-ambiguity-code, locus, mhc, msa, pcr, primer, primer-pool, primer-scheme, primer-trim, tiling, plugin-pack]
features_refs: []
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

Primer design is choosing the short pieces of DNA that decide what a [PCR](../../GLOSSARY.md#pcr) will copy. PCR, the polymerase chain reaction, makes millions of copies of one stretch of DNA. It copies only the stretch that lies between two [primers](../../GLOSSARY.md#primer), short synthetic DNA strands, usually 18 to 30 bases long, that stick to the template at chosen places and give the copying enzyme a starting point. Choose the primers and you have chosen the product, the samples it will work on, and the samples it will miss.

A primer that works well binds its own site firmly, binds nowhere else, and does not stick to itself or to its partner. Whether a sequence behaves that way depends on physical properties you can predict from the letters alone. Its length, its [GC content](../../GLOSSARY.md#gc-content) (the share of G and C bases), the last few bases at the end where copying starts, and any stretch that can fold back on itself all matter. Primer design software scores thousands of candidate sequences on these properties and keeps the best.

Real targets add two harder problems. The first is variation. If the target differs between the individuals, alleles, or strains you want to detect, a primer designed on one sequence can fail on another. The second is relatives. Many genes have [paralogs](#conserved-is-not-the-same-as-specific), related copies elsewhere in the genome that share much of their sequence, and a primer can bind those instead. A good design works on every sequence you want and on none you do not.

Lungfish Genome Explorer (LGE) offers four design engines, Primer3, PrimalScheme, Olivar, and varVAMP, under **Tools > PCR Primer Design**. This chapter explains the ideas all four share. It owns the terms the later chapters use, and [The four engines and where each is covered](#the-four-engines-and-where-each-is-covered) at the end says which chapter takes each job.

## Why you would do this

You design primers when no published assay fits your target, when a published assay has stopped working because the target changed, or when you need a new kind of assay such as a quantitative one. The worked example in this part of the manual is a hard, realistic case. It is the rhesus macaque MHC class I gene *Mamu-A1*.

The [MHC](../../GLOSSARY.md#mhc), the major histocompatibility complex, is a cluster of immune genes and the most variable region of a vertebrate genome, as [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#what-it-is) explains. *Mamu-A1* is one of its [class I](../../GLOSSARY.md#class-i-mhc) genes, and it is a difficult target for three reasons. It is highly polymorphic, meaning each [locus](../../GLOSSARY.md#locus) carries many [alleles](../../GLOSSARY.md#allele), alternative versions that differ at many positions. It is GC-rich, which makes primers bind too tightly and makes the DNA fold on itself. And it has paralogs, the genes *Mamu-A2*, *Mamu-A3*, *Mamu-A4*, and *Mamu-B*, which share long stretches of sequence with *Mamu-A1*, so a primer meant for one gene can copy another.

Allele names in the example follow the IPD-MHC nomenclature, the naming system of the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) database of non-human MHC sequences, cited in [Primer design background](../appendices/bibliography.md#primer-design-background). In `Mamu-A1*001:01:01:01`, `Mamu` is the species (*Macaca mulatta*) and `A1` the gene. The fields after the asterisk run from broad to fine. The first, `001`, is the lineage, a group of closely related alleles. The second marks a distinct protein, the third a coding difference that leaves the protein unchanged, and the fourth a difference outside the coding sequence, such as in an [intron](../../GLOSSARY.md#intron). [How allele names are built](../09-genotyping/01-what-is-mhc-genotyping.md#how-allele-names-are-built) covers the related record names a genotyping library uses.

The Primer Design demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds three sets of public genomic sequences. The panel is 12 *Mamu-A1* alleles from 12 lineages, each about 2,930 bases from exon 1 to exon 8. The lineage set is 4 alleles of the *Mamu-A1\*001* lineage. The exclusion set is 15 sequences a lineage test must not detect, 11 other *Mamu-A1* lineages plus one allele each of *Mamu-A2*, *A3*, *A4*, and *B*. The source of every record is in the [fixture README](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design). Coordinates in this chapter refer to the first panel allele, `LR699574.1`, whose [exons](../../GLOSSARY.md#exon) 2 and 3 lie at bases 205 to 474 and 718 to 993. Those two exons encode the groove that holds peptides for the immune system, and they carry most of the variation between alleles.

## How PCR copies DNA

PCR repeats three temperature steps, usually 25 to 40 times, in a tube holding the template DNA, two primers, a heat-stable DNA polymerase (the enzyme that builds new DNA), and the four DNA building blocks. The method in its modern form, with a polymerase from the hot-spring bacterium *Thermus aquaticus*, is described in Saiki and colleagues 1988, cited in [Primer design background](../appendices/bibliography.md#primer-design-background).

1. **Denature.** Heating to about 95 °C separates the two strands of every DNA molecule.
2. **Anneal.** Cooling, typically to somewhere between 50 and 65 °C, lets each primer find and pair with its complementary site on a single strand. The forward primer binds one strand and the reverse primer binds the other, facing each other across the target.
3. **Extend.** At about 72 °C the polymerase adds bases to the 3′ end of each bound primer, copying the template strand. A DNA strand has a direction, and the 3′ end is the end new bases are added to, so every copy starts at a primer and grows away from it.

After one cycle each target molecule has become two. After the next, four. Because every new copy can serve as a template in the next cycle, the number grows exponentially, doubling each cycle when the reaction runs perfectly. Thirty perfect cycles turn one molecule into about a billion (2 to the power 30). Real reactions copy less than every molecule each cycle, and the growth slows once primers or building blocks run low, but the principle holds. From the third cycle on, most products run exactly from the forward primer's 5′ end to the reverse primer's 5′ end, and that fixed-length product is the [amplicon](../../GLOSSARY.md#amplicon).

The primers themselves become part of every copy. That is why reads from an amplicon library begin and end in primer sequence that was never in the sample, and why the bases have to be [primer-trimmed](../../GLOSSARY.md#primer-trim) before variant calling, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) explains.

## What makes a good primer

Primer design software checks the same handful of properties whatever engine you use. The defaults quoted here are LGE's Primer3 defaults for an ordinary PCR assay, unless the text says otherwise. Each engine's full settings are in its own chapter.

### Length and melting temperature

A primer's **melting temperature**, or **Tm**, is the temperature at which half of the primer molecules are paired with their target and half have come apart. Above its Tm a primer mostly floats free. Well below it, a primer sticks firmly, and also sticks to near-matches it should ignore. The anneal step is set a few degrees below the primers' Tm, so the two primers of a pair need similar Tm values or one of them will be too loose or too sloppy at the chosen temperature.

Tm rises with length, because each extra base pair adds stability, and with GC content, because a G-C pair has three hydrogen bonds to an A-T pair's two and stacks more stably. Design programs estimate Tm with a nearest-neighbour model, which adds up measured stabilities for every adjacent pair of bases, corrected for salt and primer concentration. The standard parameter set is SantaLucia 1998, cited in [Primer design background](../appendices/bibliography.md#primer-design-background). Primer3 in LGE aims for primers of 18 to 27 bases, optimum 20, with a Tm between 57 and 63 °C, optimum 60 °C.

### GC content and the GC clamp

GC content affects more than Tm. A primer with very few G and C bases must be long to reach a useful Tm, and one with very many binds so tightly that a partial match can still hold. Primer3 in LGE accepts 20 to 80 percent GC for ordinary PCR. The stricter qPCR rules narrow that to 40 to 60 percent.

The last five or so bases at the 3′ end matter most, because the polymerase starts there. One or two G or C bases in those positions, called a **GC clamp**, hold the end firmly in place so extension can begin. More than about three G or C bases at the end go the other way, since such an end can stay bound at a wrong site long enough to be extended. LGE's qPCR rules ask for a clamp of at least one and allow at most two G or C bases among the last five.

The *Mamu-A1* example shows how GC content limits a design. Asked for a short qPCR product inside exon 2, Primer3 considered 816 candidate pairs and found none that passed. Exon 2 of *Mamu-A1* is too GC-rich for primers inside the 40 to 60 percent window, so the fix was to choose a different region, not to loosen the rules.

### Runs and repeats

A run is a stretch of one repeated base, such as `GGGGG`, and a dinucleotide repeat is a repeated pair, such as `ATATAT`. Either lets a primer bind one or two positions out of register, so it can slip along the template and start copying in the wrong place. Design rules cap them. varVAMP in LGE allows at most four of either, and Primer3's qPCR rules allow runs of at most four.

### Hairpins and primer dimers

A **hairpin** forms when part of a primer pairs with another part of the same primer, folding it into a loop so it cannot bind the template. A **self-dimer** forms when two copies of the same primer pair with each other, and a **cross-dimer** when the forward and reverse primers pair. A dimer whose 3′ ends overlap is the worst case, because the polymerase extends both primers across each other and makes a **primer dimer**, a tiny product that copies efficiently in every cycle and uses up primers meant for the target. Primer dimers show up as a short band at the bottom of a gel and as an extra low peak in a melt curve, both described in [Checking a design in silico and at the bench](#checking-a-design-in-silico-and-at-the-bench). Every engine scores these structures by their free energy, explained in [Secondary structure and free energy](#secondary-structure-and-free-energy), and rejects the ones that would form readily.

## Amplicon and product size

The **product size** is the length of the amplicon, counted from the 5′ end of the forward primer to the 5′ end of the reverse primer, primers included. You set a size range and the engine keeps only pairs that fall inside it. LGE's Primer3 default for ordinary PCR is 100 to 400 bases.

The right size depends on what happens to the product. A product for Sanger sequencing or cloning can be over a thousand bases. A product that will be sequenced as short reads should fit the read length, since two 150-base reads from each end of a 250-base fragment overlap in the middle, while a 400-base fragment leaves an unread gap. A qPCR product is kept short, for reasons given in [Why qPCR amplicons are short](#why-qpcr-amplicons-are-short). A target region, the stretch that must lie between the primers, can never be longer than the largest product allowed, and LGE's Primer3 refuses such a request with a message instead of running it.

For the *Mamu-A1* example, a PCR that spans exons 2 and 3 must cover bases 205 to 993, so the product range was set to 800 to 1,100 bases. The best pair Primer3 returned on `LR699574.1` gave a product of 945 bases.

## When the target varies

A primer does not need a perfect match to bind. What matters is where the mismatches are. A mismatch near the 5′ end, the end away from the polymerase, weakens binding a little and is usually tolerated, since the 3′ end still sits correctly and extension proceeds. A mismatch at the 3′ end, the last base, can stop extension altogether, because the polymerase needs a correctly paired final base to add the next one. Kwok and colleagues 1990, cited in [Primer design background](../appendices/bibliography.md#primer-design-background), measured this directly. Single mismatches inside a primer had no significant effect on yield. A mismatch at the final 3′ base cut yield about 100-fold for some base combinations and hardly at all for others, and two mismatches within the last four bases, one of them terminal, generally reduced yield sharply.

The practical rules follow. Keep the 3′ end, roughly the last three to five bases, on sequence every target shares. If some variation must fall inside a primer, put it toward the 5′ end. And never assume a primer designed on one allele will work on the next one.

The *Mamu-A1* example shows the problem in numbers. Designed on `LR699574.1` alone, Primer3's best pair for exons 2 and 3 put the forward primer at bases 89 to 107 in intron 1 and the reverse primer at bases 1,014 to 1,033 in intron 3. Those sites are not shared by all 12 panel alleles, so on some alleles the pair would carry mismatches and could fail. [Designing on an alignment](#designing-on-an-alignment) shows what changed when the same design ran on all 12.

## Designing on an alignment

To find sites every target shares, you need every target side by side. That is a multiple sequence alignment, or [MSA](../../GLOSSARY.md#msa), in which each sequence is a row and each [alignment column](../../GLOSSARY.md#alignment-column) holds the bases that descend from one ancestral position. [Aligning Sequences](../02-sequences/04-aligning-sequences.md) builds one with MAFFT. The 12 panel alleles align into 2,953 columns, and every primer design chapter in this part starts from that alignment.

### Conserved columns

A column is **conserved** when every row carries the same base there. A column is **variable** when rows disagree, and **gapped** when some rows carry a [gap](../../GLOSSARY.md#gap), a placeholder for an insertion in another sequence. A primer placed entirely on conserved columns matches every sequence in the alignment.

Primer3 in LGE can design on one row of an alignment while reading the others. With "Require binding sites conserved across all alignment rows" turned on, the default for alignment input, it treats every variable or gapped column as off limits for primers and probes. On the 12-allele panel that excluded 328 single columns. The best pair moved as a result. The forward primer now sits at bases 178 to 195, still in intron 1, and the reverse primer at 1,105 to 1,125, further into intron 3, giving a 948-base product. Both primers now match all 12 alleles exactly. The price is fewer choices, since Primer3 considered 177 candidate pairs on the alignment where it had considered 374 on the single sequence.

A conserved site in your alignment is only as good as the alignment. Twelve alleles are a teaching size. A working design includes every allele seen in your colony, and published alleles from the same population, because a site conserved across 12 may vary in the 13th.

### Degenerate bases and what they cost

When no fully conserved site exists where you need one, a primer can carry a **degenerate base**, a position written with an [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) that stands for two or more bases. `K`, for example, means G or T. A primer written as `TGTSTYCCGGTCCCAATACT`, with `S` (C or G) and `Y` (C or T), is ordered as a mixture of every sequence the codes allow, here four.

Degeneracy has a cost. Each distinct sequence in the mixture is present at only its share of the total, a quarter each in the four-sequence example, so the exact match for any one template is scarce. The other versions are mismatched primers competing for the same site, and each extra degenerate position doubles or triples the number of versions. That is why varVAMP in LGE allows at most two ambiguous bases per primer by default and requires the last three bases at the 3′ end to be unambiguous.

A related idea is the **consensus threshold** varVAMP uses to decide which columns count as conserved. With a threshold of 0.99 on the 12-allele panel, a base counts as conserved only when 12 of 12 sequences agree, and any disagreement becomes an ambiguity code. At 0.8, a base counts as conserved when 10 of 12 agree, so fewer ambiguity codes appear and more windows qualify for primers, at the price of possible mismatches in the other 2 sequences. With few sequences the threshold moves in whole-sequence steps, so on 12 sequences every threshold from 0.76 to 0.83 gives the same result. [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) works through this choice.

## Multiplexing, pools, and tiling

**Multiplex PCR** runs several primer pairs in one tube, so one reaction copies several targets. The primers in a tube must all work at the same anneal temperature and must not form dimers with any other primer in the tube, which is harder to arrange the more primers there are. The set of primers that share a tube is a **pool**, recorded as the [primer pool](../../GLOSSARY.md#primer-pool) number in a scheme.

**Tiling** covers a region too long for one amplicon with many overlapping amplicons laid end to end, as described under [tiling](../../GLOSSARY.md#tiling) and in [Amplicon sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing). The overlaps matter, because a variant that falls on a primer site is hidden in that amplicon's reads and must be read from the neighbour instead.

Overlapping amplicons cannot share a tube. Where amplicon 1 and amplicon 2 overlap, the forward primer of amplicon 2 sits upstream of the reverse primer of amplicon 1, and the two face each other across the overlap. In one tube they copy that short overlap as its own product, which is small and copies faster than either real amplicon. A tiled scheme therefore alternates amplicons between two pools, odd-numbered amplicons in pool 1 and even-numbered in pool 2, so neighbours never meet. The two pools are run as separate reactions and combined afterwards. This design comes from the PrimalScheme method, cited in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack).

The finished design, with each primer's sequence, position, and pool, is a [primer scheme](../../GLOSSARY.md#primer-scheme). LGE stores one as a `.lungfishprimers` bundle, described in [Primer Scheme Bundles](../appendices/primer-schemes.md). On the 12-allele panel with 400-base amplicons, the three tiling engines covered roughly 90 to 99 percent of the alignment in 8 to 10 amplicons, and [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) compares them.

## qPCR and dPCR

Ordinary PCR tells you what was copied once the reaction ends. **Quantitative PCR**, qPCR or real-time PCR, measures the product after every cycle with a fluorescent signal. The more starting template a sample holds, the sooner its signal crosses a set threshold, and the cycle at which it crosses is the **Cq**, the quantification cycle. At perfect efficiency each tenfold increase in starting template moves Cq about 3.3 cycles earlier, since 2 to the power 3.3 is about 10. **Digital PCR**, dPCR, splits one reaction into thousands of tiny partitions, droplets or wells, so each holds either no template molecule or a few. After cycling, the instrument counts the partitions that lit up and calculates the number of starting molecules directly, without a standard curve. The MIQE and digital MIQE guidelines, cited in [Primer design background](../appendices/bibliography.md#primer-design-background), set out what a qPCR or dPCR assay report must include.

Both methods use the same primer and probe designs, so LGE designs one assay for either. varVAMP's qPCR mode states this on screen, since it has no separate dPCR optimizer.

### Intercalating dye and hydrolysis probe

qPCR detects product in one of two ways, and the choice changes the design.

An **intercalating dye**, SYBR Green being the common one, fluoresces when it slips between the bases of any double-stranded DNA. It needs only two primers, which makes it cheap. It also lights up on primer dimers and wrong products, so the assay relies entirely on the primers being specific, and each run ends with a melt curve to check that only one product formed. Primer3's "qPCR · intercalating dye" assay in LGE applies stricter primer rules for this reason, drawn from MIQE and from Thornton and Basu 2011. Among other limits, the two primers of a pair must lie within 1 °C of each other in Tm, with an optimum of 60 °C.

A **hydrolysis probe**, often called a TaqMan probe after one commercial brand, adds a third oligo that binds inside the amplicon between the primers. The probe carries a fluorescent reporter at one end and a quencher, a molecule that absorbs the reporter's light, at the other. While the probe is intact the quencher keeps it dark. When the polymerase extends a primer and reaches the bound probe, the polymerase's 5′ to 3′ nuclease activity chews the probe apart, freeing the reporter from the quencher, so the signal rises only when the intended product is copied. Holland and colleagues 1991, cited in [Primer design background](../appendices/bibliography.md#primer-design-background), first described this detection.

The probe's Tm is set higher than the primers', usually by about 5 to 10 °C, so the probe is already bound when the primers anneal and extend, and stays bound until the polymerase reaches it. A probe that melts off first is never cut and gives no signal. The first varVAMP assay in the *Mamu-A1\*001* example shows the pattern, with primers at 60.1 and 60.0 °C and a 25-base probe at 67.3 °C. Both Primer3's "qPCR · internal hydrolysis probe" assay and varVAMP's qPCR mode in LGE aim the probe above the primers, and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) gives their settings. Reporter and quencher chemistry is chosen when you order the probe, not during design.

### Why qPCR amplicons are short

qPCR works best when every cycle copies nearly every molecule, because quantification assumes a steady doubling. Short amplicons, commonly 70 to 200 bases, extend completely in every cycle, tolerate damaged template better, and are less likely to fold into structures that block the primers or the probe. LGE's Primer3 dye assay defaults to 70 to 150 bases, and varVAMP's qPCR mode to 70 to 200 bases.

The *Mamu-A1* example shows what happens otherwise. An earlier LGE build reused the tiling size range of 360 to 440 bases for varVAMP's qPCR mode. The run took 938 seconds and failed with "no qPCR amplicon passed the deltaG threshold". Every 400-base stretch of GC-rich MHC sequence folded too stably. With the corrected 70 to 200 base range the same design finished in 88 seconds with five assays, of 83 to 181 bases.

## Secondary structure and free energy

**Secondary structure** is any shape a single DNA strand makes by pairing with itself, such as a hairpin in a primer or a folded stretch in a single-stranded amplicon. Design programs judge these structures by their **free energy change**, written **ΔG** (delta G) and measured in kilocalories per mole. The sign carries the meaning. A negative ΔG means the structure forms on its own, and the more negative the number, the more stable the structure and the more of the DNA is tied up in it at any moment. A ΔG near zero, or positive, means the structure barely forms.

The same measure applies to dimers between primers and to folding of the product. varVAMP's qPCR mode folds each candidate amplicon at the lower of its two primers' Tm values and rejects any amplicon whose ΔG is at or below its cutoff of −3 kcal/mol, because a template that folds that stably competes with the primers and probe for their binding sites. The five *Mamu-A1\*001* assays that passed had ΔG values between −2.2 and −0.3. Olivar applies the same idea to primer dimers across a whole pool, with a dimer ΔG limit of −11.8 by default.

## Conserved is not the same as specific

A **conserved** primer matches every sequence you want to detect. A **specific** primer matches nothing else. These are different properties, checked against different sequence sets, and a design can have the first without the second.

The design engines optimise conservation. They look at the target sequences you give them and find sites shared by all of them. None of them learns what else might be in the sample unless you also give it something to avoid. That can be a set of sequences to compare against, or a [BLAST](../../GLOSSARY.md#blast) database, which Olivar and varVAMP in LGE can use to flag primers that match other sequences. The risk is highest for genes with paralogs, and for off-target products, copies of a sequence you never meant to amplify, from anywhere in the genome that happens to share the primer sites.

The *Mamu-A1\*001* qPCR example makes the point. varVAMP designed five assays on the 4 lineage alleles, and every oligo in all five matches all 4 perfectly. Compared against the 15 exclusion sequences, none of the five is specific to the lineage. The forward primer of one assay matches 14 of the 15 non-target sequences perfectly. The most discriminating forward primer carries 3 or 4 mismatches against most other lineages, but only 1 against *Mamu-A1\*041*, and its reverse partner matches 14 of the 15 perfectly. The intercalating-dye assays Primer3 found for the same lineage told the same story. They sat in exon 4, which is conserved across class I genes, so they would detect *Mamu* class I sequences broadly, not the *\*001* lineage.

A lineage-specific or gene-specific assay needs sites where the targets agree with each other and differ from everything else, ideally with the differences at the primers' 3′ ends, for the reason given in [When the target varies](#when-the-target-varies). Finding such sites is a separate step from conservation. [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) walks through checking a design against an exclusion set.

## Checking a design in silico and at the bench

Every check so far happens in silico, on the computer. In-silico checks predict binding from thermodynamic models that assume a salt concentration, a primer concentration, and a clean template. A real reaction differs in all three, and some problems, such as a template region that folds in the tube or an off-target product from a sequence missing from every database, cannot be predicted at all. A design is a hypothesis until it passes bench validation.

The usual bench checks, in the order most laboratories run them, are the following.

| Check | What you do | What it shows |
|---|---|---|
| Gradient PCR | Run the same reaction at a range of anneal temperatures in one run | The anneal temperature that gives a strong product and no extra bands |
| Gel electrophoresis | Run the product on an agarose gel beside a size ladder | One band of the expected size, and no primer dimer band near the bottom |
| Melt curve | After a dye qPCR run, heat the product slowly while reading fluorescence | One sharp peak means one product. A second, lower peak usually means primer dimers |
| Efficiency standard curve | Run a tenfold dilution series and plot Cq against the log of input | The slope gives the efficiency. About −3.3 is 100 percent, and many laboratories accept roughly 90 to 110 percent |
| Sequencing the product | Sanger-sequence the band, or sequence it with the rest of the run | That the product is the intended target and not a paralog |

For a variable target like *Mamu-A1*, run the assay on samples carrying as many known alleles as you can, not just one, and for a lineage assay also on samples you expect to be negative. A tiled scheme is validated by sequencing a few samples and checking that every amplicon has reads, since a missing amplicon, called [amplicon dropout](../../GLOSSARY.md#amplicon-dropout), leaves a gap in coverage.

## The four engines and where each is covered

LGE's four engines share the ideas above but answer different questions. All four live under **Tools > PCR Primer Design**, come from the PCR Primer Design [plugin pack](../../GLOSSARY.md#plugin-pack), and save each run as a `.lungfishprimeranalysis` bundle in the project's Analyses folder.

<!-- SHOT: primer-design-submenu -->

**Primer3** scores every candidate primer on one template by length, Tm, GC content, the 3′ end, runs, hairpins, and dimers, and returns a small number of ranked pairs, five by default. It can add a hydrolysis probe. In LGE it can also design on one row of an alignment while keeping primers off variable columns, as [Conserved columns](#conserved-columns) showed. It is the engine for a single assay.

**PrimalScheme** designs tiled two-pool schemes and handles variation by adding oligos. At each primer site it writes one exact-match oligo for every variant it sees, so a variable site gets several. On the 12-allele panel its scheme used 49 oligos for 8 amplicons, up to 7 at one site.

**Olivar** designs tiled two-pool schemes by scoring every base for risk, from variation, extreme GC, low complexity, and optional matches in a BLAST database, and placing primers where the risk is lowest. It then chooses primers inside those places so that dimers across each pool are as unlikely as possible. It writes one oligo per site, so its scheme on the panel used 20 oligos for 10 amplicons.

**varVAMP** builds a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of the alignment with ambiguity codes wherever sequences disagree, and designs degenerate primers on it. It has three modes, single amplicons, tiled schemes, and qPCR assays with a probe. Its tiled scheme on the panel used 20 oligos for 10 amplicons at a threshold of 0.8.

| Engine | Designs | Copes with variation by | Covered in |
|---|---|---|---|
| Primer3 | One primer pair, or one pair plus a probe, on one template | Avoiding variable columns of an alignment | [Designing a PCR Assay](02-designing-a-pcr-assay.md), and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) for its qPCR assays |
| PrimalScheme | Tiled two-pool schemes, from one or several alignments | Adding an exact-match oligo per variant | [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) |
| Olivar | Tiled two-pool schemes, from one or several alignments | Placing primers where variation and dimer risk are lowest | [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) |
| varVAMP | Single amplicons, tiled schemes, and qPCR assays with a probe | Degenerate bases in a consensus | [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) |

Whichever engine you use, [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) covers opening a saved analysis, checking each primer against the alignment, saving a tiled result as a primer scheme, and preparing an order. The papers for all four engines are in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), with PrimalScheme 3 and Olivar's dimer method, SADDLE, under [Method papers](../appendices/bibliography.md#method-papers).

## What good looks like

Before you order oligos from any engine, check the design against the ideas in this chapter.

- Every primer's 3′ end sits on columns conserved across all the sequences you want to detect.
- The primers of a pair are within a few degrees of each other in Tm, and a probe sits several degrees above them.
- The product size suits what happens next, short for qPCR and matched to read length for sequencing.
- The design was compared against the sequences you must not detect, including paralogs, and not only against the targets.
- You have a bench plan, at least a gradient PCR and a gel, and for qPCR a melt curve or a probe check plus a standard curve.

## Next

Start with [Designing a PCR Assay](02-designing-a-pcr-assay.md), which aligns the *Mamu-A1* panel and runs Primer3 across exons 2 and 3. [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) compares the three tiling engines on the same alignment, and [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) builds and tests the lineage assays.
