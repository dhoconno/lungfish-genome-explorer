---
title: What Is Primer Design
chapter_id: 10-primer-design/01-what-is-primer-design
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 02-sequences/04-aligning-sequences, 09-genotyping/01-what-is-mhc-genotyping]
estimated_reading_min: 18
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
illustrations:
  - id: pcr-three-cycles
    brief: "Three PCR cycles on one template. Cycle 1 shows the two strands separated with the forward primer bound to the bottom strand and the reverse primer to the top strand, each labelled with its 5 prime and 3 prime ends and an arrow showing the direction the polymerase extends. Cycle 2 shows the long ragged products those extensions make, whose far ends are set by where the polymerase stopped rather than by a primer. Cycle 3 shows the first product whose two ends are both primer 5 prime ends, drawn as a fixed-length bar labelled amplicon, beside a note that from here on this length dominates. Keep every strand horizontal and use the brand palette, Deep Ink strands, Creamsicle primers."
  - id: strand-geometry
    brief: "One stretch of double-stranded DNA drawn as two horizontal lines, the top strand left to right with 5 prime at the left, the bottom strand right to left with 5 prime at the right. The forward primer sits on the bottom strand pointing right, the reverse primer on the top strand pointing left, both labelled with their 3 prime ends facing the product. Label upstream at the left and downstream at the right. Beneath, show the reverse primer twice, once as the bases it pairs with on the top strand and once as the sequence a supplier would synthesise, with an arrow between them labelled reverse complement, so a reader sees the two are the same oligo written two ways."
  - id: tiled-overlap-pools
    brief: "Two overlapping amplicons along one reference line. Amplicon 1 carries a forward and a reverse primer arrow, amplicon 2 the same, and the overlap region shows amplicon 2's forward primer sitting inside amplicon 1's span and facing amplicon 1's reverse primer. Draw the short product those two would make in one tube as a small bar marked with a cross. Then show the same four primers split into two lanes labelled Pool 1 and Pool 2, with a note that odd amplicons go in one tube and even amplicons in the other. Use the brand palette."
  - id: qpcr-standard-curve
    brief: "A standard curve with the log of input template on the x axis over four tenfold dilutions and the quantification cycle Cq on the y axis, points falling on a straight line of slope about minus 3.3, each tenfold step marked as 3.3 cycles. Annotate the slope and print the relation efficiency equals 10 to the power of minus one over slope, minus 1, with minus 3.3 giving 100 percent. Keep it a plain two-axis plot in the brand palette with no red, amber or green."
glossary_refs: [allele, alignment-column, amplicon, amplicon-dropout, blast, class-i-mhc, consensus-sequence, cq, degenerate-base, dpcr, exon, gap, gc-clamp, gc-content, hydrolysis-probe, intercalating-dye, intron, ipd-mhc, iupac-ambiguity-code, locus, melting-temperature, mhc, msa, oligo, paralog, pcr, pcr-ssp, primer, primer-dimer, primer-pool, primer-scheme, primer-trim, probe, qpcr, reverse-complement, tiling, plugin-pack]
features_refs: []
fixtures_refs: [mhc-primer-design]
brand_reviewed: false
lead_approved: false
---

## What it is

Primer design is choosing the short pieces of DNA that decide what a [PCR](../../GLOSSARY.md#pcr) will copy. PCR, the polymerase chain reaction, makes millions of copies of one stretch of DNA. It copies only the stretch that lies between two [primers](../../GLOSSARY.md#primer), short synthetic DNA strands, usually 18 to 30 bases long, that pair with the template at chosen places and give the copying enzyme a starting point. The template is the DNA from your sample, and a primer finds its place on it because A pairs with T and G with C. Choose the primers and you have chosen the product, the samples it will work on, and the samples it will miss.

Every primer and probe is an [oligo](../../GLOSSARY.md#oligo), a short single strand of DNA made to order by a synthesis company. A primer that works well pairs firmly with its own site, pairs nowhere else, and does not stick to itself or to its partner. Whether a sequence behaves that way follows from properties you can predict from the letters alone, its length, its [GC content](../../GLOSSARY.md#gc-content) or share of G and C bases, the last few bases at the end where copying starts, and any stretch that can fold back on itself. Design software scores thousands of candidates on these properties and keeps the best.

Real targets add two harder problems. If the target differs between the individuals, alleles or strains you want to detect, a primer designed on one sequence can fail on another. And many genes have [paralogs](../../GLOSSARY.md#paralog), related copies elsewhere in the genome that share much of their sequence, which a primer can bind instead. A good design works on every sequence you want and on none you do not.

Lungfish Genome Explorer (LGE) offers four design engines, Primer3, PrimalScheme, Olivar and varVAMP, under **Tools > PCR Primer Design**. Each is a separate program that LGE installs, runs for you, and saves the result of. This chapter explains the ideas all four share, and [Choosing a tool](#choosing-a-tool) says which chapter takes each job.

## Why you would do this

You design primers when no published assay fits your target, when a published assay has stopped working because the target changed, or when you need a different kind of readout, such as one that measures how much DNA was present. An assay is a tested laboratory procedure that detects or measures something. Look for a published assay for your target first, because a validated one saves months.

The example used through this part of the manual is a hard, realistic case. It is the rhesus macaque [MHC](../../GLOSSARY.md#mhc) class I gene *Mamu-A1*. The MHC, the major histocompatibility complex, is a cluster of immune genes and the most variable region of a vertebrate genome, as [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#what-it-is) explains. A [class I](../../GLOSSARY.md#class-i-mhc) molecule sits on the cell surface holding up a short protein fragment for inspection by T cells, and the groove that holds it is built from the parts of the protein that [exons](../../GLOSSARY.md#exon) 2 and 3 encode. An exon is a stretch of a gene kept in the mature message, and an [intron](../../GLOSSARY.md#intron) is a stretch cut out between exons.

*Mamu-A1* is difficult for three reasons. It is highly polymorphic, meaning each [locus](../../GLOSSARY.md#locus) carries many [alleles](../../GLOSSARY.md#allele), versions that differ at many positions. It is GC-rich, which makes primers bind too tightly and makes the DNA fold on itself, as [Secondary structure and free energy](#secondary-structure-and-free-energy) explains. And it sits in a duplicated gene family whose size differs between animals. A rhesus haplotype carries one major A-region gene, either *A1* or its close duplicate *A7*, alongside minor genes *A2* to *A6*, and the *Mamu-B* region carries several *B* genes whose number differs between haplotypes. A human carries one *HLA-B* per chromosome copy, a macaque several. A primer meant for *Mamu-A1* can bind any of these, and you cannot know from the animal alone how many copies are present. [Duplicated genes and many rows per locus](../09-genotyping/01-what-is-mhc-genotyping.md#duplicated-genes-and-many-rows-per-locus) shows what that does to a genotyping result.

Allele names follow the [IPD-MHC](../../GLOSSARY.md#ipd-mhc) nomenclature ([Maccari and colleagues 2017](../appendices/bibliography.md#primer-design-background)). In `Mamu-A1*001:01:01:01`, `Mamu` is the species and `A1` the gene. The first field after the asterisk, `001`, is the lineage, a group of alleles whose peptide-binding region is the same or nearly so, and the first two fields together name the protein. [How allele names are built](../09-genotyping/01-what-is-mhc-genotyping.md#how-allele-names-are-built) owns the four fields in full.

The Primer Design demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds three sets of public genomic sequences. The panel is 12 *Mamu-A1* alleles from 11 lineages, two of them from the *\*001* lineage, each about 2,930 bases from exon 1 to exon 8. The lineage set is 4 alleles of the *\*001* lineage. The exclusion set is 18 sequences a lineage test must not detect, the 11 other *Mamu-A1* lineages plus alleles of *A2*, *A3*, *A4*, *A6*, *A7* and *B*. Each record's source is listed in the notes file of the [mhc-primer-design fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/mhc-primer-design). Coordinates in this part refer to the first panel allele, accession `LR699574.1`, the identifier a public database gives one record. On that sequence exons 2 and 3 lie at bases 205 to 474 and 718 to 993.

## How PCR copies DNA

PCR repeats three temperature steps, usually 25 to 40 times, in a tube holding the template DNA, two primers, a heat-stable DNA polymerase, and the four DNA building blocks the polymerase adds, called dNTPs. The method in its modern form is described in Saiki and colleagues 1988, cited in [Primer design background](../appendices/bibliography.md#primer-design-background).

1. **Denature.** Heating to about 95 °C separates the two strands of every DNA molecule.
2. **Anneal.** Cooling, typically to between 50 and 65 °C, lets each primer find and pair with its matching site on a single strand. The forward primer binds one strand and the reverse primer the other, facing each other across the target.
3. **Extend.** At about 72 °C the polymerase adds bases to the 3′ end of each bound primer, copying the template strand.

A DNA strand has a direction. The 3′ end is the end new bases are added to, and the 5′ end is the other end, where a primer's first base sits, so every copy starts at a primer's 5′ end and grows away from it.

<!-- ILLUSTRATION: strand-geometry -->

After one cycle each target molecule has become two, after the next four, and because every new copy can serve as a template the number grows exponentially. Thirty perfect cycles turn one molecule into about a billion, 2 to the power 30. The first two cycles make long products whose far ends are wherever the polymerase happened to stop. Copies that run exactly from the forward primer's 5′ end to the reverse primer's 5′ end first appear in the third cycle and within a few more far outnumber everything else. That fixed-length product is the [amplicon](../../GLOSSARY.md#amplicon). Real reactions copy less than every molecule each cycle, and growth slows as reagents run low and products re-anneal to each other instead of to primers.

<!-- ILLUSTRATION: pcr-three-cycles -->

The primers become part of every copy. That is why reads from an amplicon library, the pool of DNA fragments prepared for a sequencer, begin and end in primer sequence that was never in the sample, and why those bases must be [primer-trimmed](../../GLOSSARY.md#primer-trim) before variants are called, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) explains.

## What makes a good primer

Design software checks the same handful of properties whatever engine you use. The values quoted here are LGE's Primer3 defaults for an ordinary PCR assay, and [Primer Design Settings](../appendices/primer-design-settings.md#primer3) lists every one.

### Length and melting temperature

A primer's **melting temperature**, or **Tm**, is the temperature at which half of the primer-template duplexes have come apart. Above its Tm a primer mostly floats free, and well below it a primer holds firmly to its own site and also to near-matches it should ignore. Because the value depends on the strand concentration the software assumes, a supplier's figure and LGE's can differ by a degree or two. The anneal step sits a few degrees below the primers' Tm, so the two primers of a pair need similar values. At one annealing temperature the primer with the higher Tm binds partial matches it should not, and the one with the lower Tm binds its own site too weakly to prime every molecule.

Tm rises with length, because each extra base pair adds stability, and with GC content, because a G-C pair has three hydrogen bonds to an A-T pair's two. Design programs estimate it with a nearest-neighbour model, which adds up measured stabilities for every adjacent pair of bases and corrects for salt and primer concentration, using the parameters of SantaLucia 1998, cited in [Primer design background](../appendices/bibliography.md#primer-design-background). Primer3 in LGE aims for primers of 18 to 27 bases, optimum 20, with a Tm between 57 and 63 °C, optimum 60 °C.

### GC content and the GC clamp

A primer with very few G and C bases must be long to reach a useful Tm, and one with very many binds so tightly that a partial match can still hold. Primer3 in LGE accepts 20 to 80 percent GC for ordinary PCR, and its qPCR rules narrow that to 40 to 60 percent. Those bounds are design guidance rather than a rule of validity, and a GC-rich gene often needs them relaxed, which [Designing qPCR and dPCR Assays](04-designing-qpcr-and-dpcr-assays.md) works through on real sequence.

The last five or so bases at the 3′ end matter most, because the polymerase starts there. One or two G or C bases in those positions, called a [GC clamp](../../GLOSSARY.md#gc-clamp), hold the end in place so extension can begin. Three or more go the other way, since such an end can stay bound at a wrong site long enough to be extended, and LGE's qPCR rules therefore ask for a clamp of at least one and allow at most two G or C bases among the last five.

### Runs, repeats, hairpins and dimers

A run is a stretch of one repeated base, such as `GGGGG`, and a dinucleotide repeat is a repeated pair, such as `ATATAT`. Either lets a primer pair with more than one place inside the repeat, and runs of G in particular stack and aggregate, so design rules cap them. varVAMP in LGE allows at most four of either, and Primer3's qPCR rules allow runs of at most four.

A **hairpin** forms when part of a primer pairs with another part of the same primer, folding it into a loop so it cannot bind the template. A **self-dimer** forms when two copies of one primer pair with each other, and a **cross-dimer** when the forward and reverse primers pair. A dimer whose 3′ ends overlap is the worst case, because the polymerase extends both primers across each other and makes a [primer dimer](../../GLOSSARY.md#primer-dimer), a tiny product that copies efficiently in every cycle and uses up primers meant for the target. Every engine scores these structures by their free energy, explained in [Secondary structure and free energy](#secondary-structure-and-free-energy), and rejects the ones that would form readily.

## Amplicon and product size

The **product size** is the length of the amplicon, counted from the 5′ end of the forward primer to the 5′ end of the reverse primer, primers included. You set a size range and the engine keeps only pairs inside it, and LGE's Primer3 default for ordinary PCR is 100 to 400 bases.

The right size depends on what happens to the product. A product for cloning, or for Sanger sequencing, which reads one molecule's sequence outward from a primer for several hundred bases, can be over a thousand bases. A product sequenced as short reads should fit the read length, since two 150-base reads from each end of a 250-base fragment overlap in the middle while a 400-base fragment leaves an unread gap. A qPCR product is kept short, for reasons given in [qPCR and dPCR](#qpcr-and-dpcr). A target region, the stretch that must lie between the primers, can never be longer than the largest product allowed, and LGE's Primer3 refuses such a request rather than running it.

## When the target varies

A primer does not need a perfect match to bind. What matters is where the mismatches are. A mismatch near the 5′ end weakens binding a little and is usually tolerated, since the 3′ end still sits correctly and extension proceeds. A mismatch at the last 3′ base can stop extension altogether, because the polymerase needs a correctly paired final base to add the next one. Kwok and colleagues 1990, cited in [Primer design background](../appendices/bibliography.md#primer-design-background), measured this directly. Single mismatches inside a primer had no significant effect on yield, the amount of product made. A mismatch at the final 3′ base cut yield about a hundredfold when an A faced a G, a G faced an A, or a C faced a C, while a T facing G, C or T had minimal effect, and two mismatches within the last four bases, one of them terminal, generally reduced yield sharply.

Three rules follow. Keep the 3′ end, roughly the last three to five bases, on sequence every target shares. If variation must fall inside a primer, put it toward the 5′ end. And never assume a primer designed on one allele will work on the next one. The same physics read backwards is how a primer is made to tell two sequences apart, which [Conserved is not the same as specific](#conserved-is-not-the-same-as-specific) returns to.

## Designing on an alignment

To find sites every target shares, you need every target side by side. That is a multiple sequence alignment, or [MSA](../../GLOSSARY.md#msa), in which each sequence is a row and each [alignment column](../../GLOSSARY.md#alignment-column) lines up the base at the same place in every sequence, the place they inherited from a shared ancestor. [Aligning Sequences](../02-sequences/04-aligning-sequences.md) builds one with MAFFT, an alignment program. The 12 panel alleles align into 2,953 columns.

A column is **conserved** when every row carries the same base there. It is **variable** when rows disagree, and **gapped** when some rows carry a [gap](../../GLOSSARY.md#gap), a dash where that sequence lacks bases the others have. A primer placed entirely on conserved columns matches every sequence in the alignment. Primer3 in LGE can design on one row of an alignment while reading the others, and with "Require binding sites conserved across all alignment rows" on, the default for alignment input, it treats every variable or gapped column as off limits. [Designing a PCR Assay](02-designing-a-pcr-assay.md) runs the same design with and without that switch and shows how far the primers move.

A conserved site in your alignment is only as good as the alignment. Twelve alleles are a teaching size, and one allele per lineage at that, chosen for breadth rather than to represent any colony. A working design includes every allele seen in your own colony and published alleles from the same population, because a site conserved across 12 may vary in the 13th.

### Degenerate bases and what they cost

When no fully conserved site exists where you need one, a primer can carry a [degenerate base](../../GLOSSARY.md#degenerate-base), a position written with an [IUPAC ambiguity code](../../GLOSSARY.md#iupac-ambiguity-code) that stands for two or more bases. `K` means G or T. A primer written as `TGTSTYCCGGTCCCAATACT`, with `S` for C or G and `Y` for C or T, is ordered as a mixture of every sequence the codes allow, here four.

Degeneracy has three costs. Each distinct sequence in the mixture is present at only its share of the total, a quarter each here, so the exact match for any one template is scarce. The other versions are mismatched primers competing for the same site. And each version has its own melting temperature, spread by a few degrees, so the mixture anneals over a range rather than at the single figure the software reports. That is why varVAMP in LGE allows at most two ambiguous bases per primer by default and requires the last three bases at the 3′ end to be unambiguous.

A related idea is the **consensus threshold** varVAMP uses to decide which columns count as conserved. Read it as "k of N sequences must agree". With 12 sequences, 9 of 12 is 0.75 and 10 of 12 is 0.83, so every threshold from 0.76 to 0.83 asks for the same 10 and gives the same consensus. Few sequences therefore mean coarse steps. [Designing a Tiled Amplicon Scheme](03-designing-a-tiled-amplicon-scheme.md) tunes this choice on the panel.

## Multiplexing, pools and tiling

**Multiplex PCR** runs several primer pairs in one tube, so one reaction copies several targets. The primers in a tube must all work at the same anneal temperature and must not form dimers with any other primer there, which is harder the more primers there are. The set that shares a tube is a [primer pool](../../GLOSSARY.md#primer-pool).

[Tiling](../../GLOSSARY.md#tiling) covers a region too long for one amplicon with many overlapping amplicons laid end to end, as [Amplicon sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) describes. The overlaps matter because a variant under a primer site is read from the primer's bases, not the sample's, so it is invisible in that amplicon and must be read from the neighbour.

Overlapping amplicons cannot share a tube. Where amplicon 1 and amplicon 2 overlap, the forward primer of amplicon 2 sits upstream of the reverse primer of amplicon 1, meaning nearer base 1, and the two face each other across the overlap. In one tube they copy that short overlap as its own product, which is small and copies faster than either real amplicon, so it wins the competition for reagents. A tiled scheme therefore alternates amplicons between two pools, odd-numbered amplicons in pool 1 and even-numbered in pool 2, run as separate reactions and combined afterwards. This is the design the PrimalScheme method made standard, cited in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack). Pools are the default even when the dimer check passes, because the overlap product needs no dimer to form.

<!-- ILLUSTRATION: tiled-overlap-pools -->

The finished design, with each primer's sequence, position and pool, is a [primer scheme](../../GLOSSARY.md#primer-scheme). LGE stores one as a `.lungfishprimers` bundle, described in [Primer Scheme Bundles](../appendices/primer-schemes.md).

## qPCR and dPCR

Ordinary PCR, also called end-point PCR because it is read once at the end, tells you what was copied. [Quantitative PCR](../../GLOSSARY.md#qpcr), qPCR or real-time PCR, measures the product after every cycle with a fluorescent signal. The more starting template a sample holds, the sooner its signal crosses a set threshold, and the cycle at which it crosses is the [Cq](../../GLOSSARY.md#cq). At perfect efficiency each tenfold increase in starting template moves Cq about 3.3 cycles earlier, since 2 to the power 3.3 is about 10.

[Digital PCR](../../GLOSSARY.md#dpcr), dPCR, splits one reaction into thousands of tiny partitions, droplets or wells, so each holds either no template molecule or a few. After cycling, the instrument counts the partitions that lit up and works out the number of starting molecules directly, with no standard curve. Counting rather than timing changes four things.

- Efficiency and Cq do not apply, but partition occupancy does, and too much template saturates the partitions so the count no longer corrects properly.
- Long genomic DNA distributes unevenly between partitions, so laboratories cut it with a restriction enzyme or shear it before loading.
- dPCR tolerates poor amplification efficiency better than qPCR, which is a real reason to choose it.
- A dPCR report names the partition volume, the number of partitions analysed and any merged wells, as digital MIQE asks.

The MIQE and digital MIQE guidelines, cited in [Primer design background](../appendices/bibliography.md#primer-design-background), set out what each kind of report must include. Both methods use the same primer and probe design, so LGE designs one assay for either, and varVAMP's qPCR mode says so on screen.

### Intercalating dye and hydrolysis probe

qPCR detects product in one of two ways, and the choice changes the design.

An [intercalating dye](../../GLOSSARY.md#intercalating-dye), SYBR Green being the common one, fluoresces when it slips between the bases of any double-stranded DNA. It needs only two primers, which makes it cheap, but it also lights up on primer dimers and wrong products, so the assay rests entirely on the primers being specific. Each run ends with a melt curve, a slow heating step that reads fluorescence as products come apart, and because each product melts at its own temperature one product gives one peak. Primer3's "qPCR · intercalating dye" assay in LGE applies stricter primer rules for this reason, drawn from MIQE and from Thornton and Basu 2011.

A [hydrolysis probe](../../GLOSSARY.md#hydrolysis-probe), often called a TaqMan probe after one commercial brand, adds a third oligo, the [probe](../../GLOSSARY.md#probe), that binds inside the amplicon between the primers. It carries a fluorescent reporter at one end and a quencher, a molecule that absorbs the reporter's light, at the other, so while the probe is intact the quencher keeps it dark. When the polymerase extends a primer and reaches the bound probe, its 5′ to 3′ nuclease activity, its ability to cut DNA it runs into, chews the probe apart and frees the reporter, so signal rises only when the intended product is copied, as Holland and colleagues 1991 first described. Because the polymerase cuts only what it runs into, a probe must lie on the strand the polymerase is reading, which is why probe strand choice matters.

A probe's Tm is set 5 to 10 °C above the primers', so the probe is already bound when the primers anneal and stays bound until the polymerase reaches it. A probe that melts off first is never cut and gives no signal. Reporter and quencher chemistry is chosen when you order, not during design, and [Placing the order](05-reviewing-and-ordering-primers.md#placing-the-order) covers the form.

qPCR works best when every cycle copies nearly every molecule, because quantification assumes a steady doubling. Short amplicons, commonly 70 to 200 bases, extend completely in every cycle, amplify more evenly from degraded or formalin-fixed DNA, and are less likely to fold into structures that block the primers or the probe. LGE's Primer3 qPCR assays default to 70 to 150 bases and varVAMP's qPCR mode to 70 to 200.

## Secondary structure and free energy

**Secondary structure** is any shape a single DNA strand makes by pairing with itself, such as a hairpin in a primer or a folded stretch in a product whose strands the denature step has just separated. Design programs judge these structures by their **free energy change**, written **ΔG** and measured in kilocalories per mole. A negative ΔG means the structure forms on its own, and the more negative the number the more stable it is and the more of the DNA is tied up in it. A ΔG near zero, or positive, means the structure barely forms.

varVAMP's qPCR mode folds each candidate amplicon at the lower of its two primers' Tm values, the temperature at which the weaker primer is trying to bind, and rejects any amplicon whose ΔG is at or below its cutoff of −3 kcal/mol, because a template that folds that stably competes with the primers and probe for their sites. Folding grows more stable with both length and GC content, so a long GC-rich product fails this test at almost any threshold. Olivar uses free energy differently. It extends each primer until the primer's own binding to its target reaches −11.8 kcal/mol by default, and handles dimers with a separate search that scores every possible pair of primers in a pool.

## Conserved is not the same as specific

A **conserved** primer matches every sequence you want to detect. A **specific** primer matches nothing else. These are different properties, checked against different sequence sets, and a design can have the first without the second.

The design engines optimise conservation. They find the sites shared by the target sequences you give them, and none of them learns what else might be in the sample unless you also give it something to avoid, either as sequences to screen against or as a [BLAST](../../GLOSSARY.md#blast) database, a searchable collection of sequences built from a FASTA file. Olivar and varVAMP in LGE can use one, and LGE builds it for you from sequences you pick.

For a duplicated gene family the two properties actively pull apart. The sites shared by all your targets tend to be the sites shared by the whole family, because class I paralogs arose by duplication and exchange sequence between each other, so the framework exons and introns are nearly identical across *A1*, *A2*, *A3*, *A4*, *A7* and *B* while the differences sit in exons 2 and 3. Any engine that maximises conservation lands in the shared framework.

A specific assay instead needs sites where the targets agree with each other and differ from everything else, with the difference at a primer's last 3′ base or under a short probe. Putting a discriminating base at a primer's 3′ end is the principle behind allele-specific PCR, called [PCR-SSP](../../GLOSSARY.md#pcr-ssp) in the MHC typing literature. Finding such sites is a separate step from conservation, and LGE has a tool for it. [Testing the lineage assay for specificity](04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) shows a conserved lineage assay failing this test, then builds one that passes.

## Checking a design in silico and at the bench

Every check so far happens in silico, on the computer. In-silico checks predict binding from models that assume a salt concentration, a primer concentration and a clean template. A real reaction differs in all three, and some problems, such as a template region that folds in the tube or an off-target product from a sequence missing from every database, cannot be predicted at all. A design is a hypothesis until it passes bench validation.

[Bench validation](05-reviewing-and-ordering-primers.md#bench-validation) owns the procedure. In short, you find an annealing temperature with a gradient PCR, check for one product of the expected size on a gel or in a melt curve, sequence the product to prove it is the intended gene and not a paralog, and, for a quantitative assay, build a standard curve from a tenfold dilution series. Efficiency comes from the slope of Cq against the log of input, as efficiency = 10^(−1/slope) − 1, so a slope of −3.3 is 100 percent and the 90 to 110 percent range most laboratories accept runs from about −3.6 to −3.1.

<!-- ILLUSTRATION: qpcr-standard-curve -->

Two controls belong on every plate. A no-template control, which MIQE requires, shows that neither reagents nor bench are contaminated. For a test that reads "no signal" as "this animal does not carry the target", a second assay for a gene every animal carries must run alongside, so a failed extraction is never scored as a negative animal. For a variable target, run the assay on samples carrying as many known alleles as you can, and for a lineage assay also on samples you expect to be negative. A tiled scheme is validated by sequencing a few samples and checking that every amplicon has reads, since a missing amplicon, called [amplicon dropout](../../GLOSSARY.md#amplicon-dropout), leaves a gap in coverage.

## Choosing a tool

All four engines score candidate primers on the properties above. What separates them is the shape of the answer you need, one assay or a scheme covering a whole region, and how each handles sites where your sequences disagree.

**Primer3** scores every candidate primer on one template and returns a small number of ranked pairs, five by default, optionally with a hydrolysis probe. In LGE it can design on one row of an alignment while keeping primers off the variable columns, and it can take an oligo you chose already and design the rest around it. It is the engine for a single assay, and the only one you can steer onto a position you name.

**PrimalScheme** designs tiled two-pool schemes and absorbs variation by adding oligos. At each primer site it writes one exact-match oligo for every variant it sees, so every sequence in the alignment gets a perfect match and a variable site gets a small cloud of primers. The cost is oligo count, and each variant oligo makes up a smaller share of its pool.

**Olivar** designs tiled two-pool schemes by scoring every base for risk, from variation, extreme GC content, low-complexity sequence such as a repeat, and optional matches in a BLAST database, then placing primers where the risk is lowest and choosing them so that dimers across each whole pool are as unlikely as possible. It writes one plain oligo per site, so where no site is free of variation some alleles carry a mismatch.

**varVAMP** builds a [consensus sequence](../../GLOSSARY.md#consensus-sequence) of the alignment with ambiguity codes wherever sequences disagree, and designs degenerate primers on it. It has three modes, single amplicons, tiled schemes, and qPCR assays with a probe, and it is the engine written for very diverse targets.

| Engine | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Primer3 | One pair, or a pair plus a probe, on one template | You need one assay, or you want to fix an oligo or a 3′ end position yourself | A region is longer than one product can cover |
| PrimalScheme | Tiled viral genomes, variation absorbed by extra exact-match oligos | Every sequence must match every primer exactly and a larger oligo order is acceptable | Diversity is so high that each site needs many oligos |
| Olivar | Tiled pathogen genomes, low-risk sites and pool-wide dimer checks | Off-target binding or dimers are the main worry and you want one plain oligo per site | No sequence may carry a primer mismatch |
| varVAMP | Diverse targets, degenerate consensus primers, and qPCR assays with a probe | You want few oligos that tolerate variation, or a quantitative assay across related sequences | You have one template only, or your supplier will not make mixed bases |

All four live under **Tools > PCR Primer Design**, come from the PCR Primer Design [plugin pack](../../GLOSSARY.md#plugin-pack), and save each run as a `.lungfishprimeranalysis` bundle in the project's `Analyses` folder. A bundle is a folder LGE treats as one item, as [What "bundle" means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains.

<!-- SHOT: primer-design-submenu -->

This part uses all four, in that order, and [Reviewing and Ordering Primers](05-reviewing-and-ordering-primers.md) reviews any saved design, saves a scheme and places an order. Every control of every engine is in [Primer Design Settings](../appendices/primer-design-settings.md), and the engines' papers are in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack) and [Method papers](../appendices/bibliography.md#method-papers).

## What good looks like

Before you order oligos from any engine, check the design against the ideas in this chapter.

- Every primer's 3′ end sits on columns conserved across all the sequences you want to detect.
- The primers of a pair are within about 2 °C of each other, or 1 °C for a qPCR assay, and a probe sits at least 5 °C above them.
- The product size suits what happens next, short for qPCR and matched to read length for sequencing.
- The design was compared against the sequences you must not detect, including paralogs, and not only against the targets.
- You have a bench plan, at least a gradient PCR and a gel, and for a quantitative assay a melt curve or probe check, a standard curve, a no-template control and a control assay every sample should pass.

## Next

Continue to [Designing a PCR Assay](02-designing-a-pcr-assay.md), which aligns the *Mamu-A1* panel and runs Primer3 across exons 2 and 3. For the concepts behind the alignment it uses, [Aligning Sequences](../02-sequences/04-aligning-sequences.md) builds one from scratch, and [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md) explains how a laboratory types the alleles this part designs primers against.
