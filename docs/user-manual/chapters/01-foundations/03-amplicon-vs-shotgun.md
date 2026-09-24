---
title: Amplicons and Shotgun Sequencing
chapter_id: 01-foundations/03-amplicon-vs-shotgun
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/02-sequencing-reads]
estimated_reading_min: 10
task: Understand the difference between amplicon and shotgun sequencing and why amplicon data needs primer trimming.
tags: [foundations, amplicon, shotgun, primers, primer-scheme, target-enrichment]
tools: []
parameters_refs: []
entry_points: []
shots: []
illustrations:
  - id: amplicon-vs-shotgun
    brief: "Top row: shotgun sequencing schematic showing a genome with reads scattered randomly across it, each read starting and ending at arbitrary positions. Bottom row: amplicon sequencing showing the same genome with reads starting and ending at fixed primer positions, with about 8-10 overlapping amplicons covering the genome. Use Lungfish Creamsicle for read positions, Peach for primer positions."
  - id: primer-scheme-diagram
    brief: "A 2000-base region of a genome backbone in Deep Ink, with three primer pairs marked above the backbone (forward primers as right-pointing Creamsicle arrows, reverse primers as left-pointing arrows), creating three overlapping amplicons. Below the backbone, a small table showing the BED-style start/end coordinates of each primer."
  - id: primer-trim-soft-clip
    brief: "A single read shown twice. Top: untrimmed read, with the leftmost ~20 bases highlighted in Peach (primer-derived) and the body of the read in Lungfish Creamsicle (sample-derived). Bottom: same read after primer trim, with primer-derived bases shown lightened/struck-through to indicate soft-clipping, body unchanged. Annotate 'Primer bases ignored by the variant caller'."
glossary_refs: [library-prep, shotgun, amplicon, pcr, primer, primer-scheme, primer-trim, fastq, variant-caller, paired-end, depth, coverage-breadth, mhc, allele, shearing, adapter, tiling, locus, bed, chimera, mapping, soft-clip, sra, ena, target-enrichment, coverage, inspector]
features_refs: []
fixtures_refs: [hg002-chr20, demo-assets, mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

Before any sequencing, somebody turned a tube of extracted DNA or RNA into a form the instrument can read. That bench procedure is the [library prep](../../GLOSSARY.md#library-prep), and it decides where on the genome your reads land, which changes how the rest of the analysis has to work.

Two preparations cover most of what you will meet. In [shotgun](../../GLOSSARY.md#shotgun) sequencing the DNA is broken into short pieces at random places, so every read starts wherever a break happened to fall. In [amplicon](../../GLOSSARY.md#amplicon) sequencing a chosen stretch of the genome is first copied many times by [PCR](../../GLOSSARY.md#pcr), the laboratory reaction that makes millions of copies of one stretch of DNA. Short laboratory-made pieces of DNA called [primers](../../GLOSSARY.md#primer) bind at two known positions and mark out what gets copied, so every read from an amplicon library starts and ends at those same designed positions.

[FASTQ](../../GLOSSARY.md#fastq) stores each read as four lines, a name, the bases, a separator, and one quality character per base. Every preparation writes those same four lines, and nothing inside the file says which preparation made it. You have to know or find out, because amplicon data needs a cleanup step that shotgun data does not.

That step is primer trimming. The first and last stretch of every amplicon read is primer, not sample. A [variant caller](../../GLOSSARY.md#variant-caller), the program that reports where your sample differs from the reference, will report that primer sequence as a mutation unless the primer bases are set aside first. Lungfish Genome Explorer (LGE) can trim primers at two stages of a workflow, and this chapter explains why the step exists and which stage to prefer.

Before you call a single variant, find out which library prep made your sample, and if it was amplicon, find its primer scheme too.

## Why you would do this

Two datasets used in this manual sit on opposite sides of this line.

The HG002 chromosome 20 slice is shotgun. HG002 is the human reference sample that [Sequencing Reads](02-sequencing-reads.md#why-you-would-do-this) introduces. The slice holds 45,574 Illumina read pairs over a 500,001-base stretch of chromosome 20, each pair one fragment read from both ends, as [Paired-end reads](02-sequencing-reads.md#paired-end-reads) explains.

Mapped back to the reference, the HG002 reads reach a mean [depth](../../GLOSSARY.md#depth), the number of reads over one position, of about 45. They cover 99.99% of the slice, a share called [coverage breadth](../../GLOSSARY.md#coverage-breadth). [Coverage and the coverage track](04-alignment-files.md#coverage-and-the-coverage-track) explains both numbers and how much depth is enough. Shotgun depth rises and falls gently along the slice rather than jumping at fixed points, because nobody chose where the fragments would break.

The Williams MiSeq genotyping project is amplicon. It holds 30 macaque samples, each prepared by PCR against the [MHC](../../GLOSSARY.md#mhc), the immune-system gene region, and sequenced on an Illumina MiSeq instrument. Its reads pile onto the handful of MHC genes the primers were designed to reach, and the rest of the macaque genome is absent. This dataset is not one of the manual's practice fixtures, so its numbers here are an illustration only. To try amplicon data yourself, use the `mhc-simulated` fixture of simulated MHC amplicon reads, listed in [Practice data for this manual](06-the-lungfish-project.md#practice-data-for-this-manual) and stored in the [mhc-simulated folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/mhc-simulated).

Each preparation answers its own question well. The HG002 slice asks what is anywhere in a stretch of genome. The Williams panel asks which [alleles](../../GLOSSARY.md#allele), the alternative versions of a gene, each animal carries at a few chosen genes.

## Shotgun sequencing

In a shotgun prep the DNA in the tube is broken into short pieces, by an enzyme or by physical [shearing](../../GLOSSARY.md#shearing). Short synthetic sequences called [adapters](../../GLOSSARY.md#adapter), which the instrument needs in order to read a fragment at all, are then attached to both ends of every piece. Where a read lands depends on where the break happened, and for every purpose in this manual that placement is random.

![Shotgun reads scattered randomly compared with tiled overlapping amplicons at fixed positions](../../assets/illustrations-imagegen/01-foundations/03-amplicon-vs-shotgun/amplicon-vs-shotgun.png)

The gain is that shotgun sees whatever was in the tube. It assumes nothing about what sequence you expect, so an unexpected organism or a rearranged chromosome still produces reads. The cost is that shotgun spends reads in proportion to what is present. If your target is one part in ten thousand of the DNA, roughly one read in ten thousand lands on it, so you have to sequence very deeply.

Shotgun data needs no primer trimming, because no primers were used. Adapters sometimes need removing, but that is a different step with different tools, covered in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md), and the sequencer's own software often does it before you see the file.

## Amplicon sequencing

An amplicon prep uses PCR instead of breaking the DNA. Two primers, each usually 18 to 30 bases long, bind at two known positions on the target, and an enzyme called a polymerase copies everything between them. The copied piece is the amplicon. Its two ends are the two primer sites, exactly, in every copy.

One primer pair covers one stretch. To cover a longer region, a protocol runs many pairs at once so that their amplicons overlap end to end, a design called [tiling](../../GLOSSARY.md#tiling). SARS-CoV-2 surveillance protocols tile the whole virus genome this way. Human and macaque panels more often aim at chosen genes, as the Williams panel does. Each of its amplicons sits on one MHC gene at its own [locus](../../GLOSSARY.md#locus), the place on a chromosome where one gene sits, and the amplicons do not join up into a continuous stretch.

A [primer scheme](../../GLOSSARY.md#primer-scheme) is the list of where every primer in a protocol binds on its reference, stored as a [BED](../../GLOSSARY.md#bed) file, a plain-text table with one region per line. GFF3, the other common table of genome positions, numbers bases differently. BED counts from 0 and GFF3 counts from 1, as [Standard annotation formats](../appendices/file-formats.md#standard-annotation-formats) explains. LGE ships eight SARS-CoV-2 schemes, listed in [Shipped schemes](../appendices/primer-schemes.md#shipped-schemes).

![ARTIC-style primer scheme showing forward primers, reverse primers, and overlapping amplicon bands](../../assets/illustrations-imagegen/01-foundations/03-amplicon-vs-shotgun/primer-scheme-diagram.png)

The gain is sensitivity. PCR multiplies the target many thousandfold before sequencing, so a sample with very little starting DNA can still give a usable result, and nearly every read is on target. Coverage is predictable too, so a missing amplicon is a specific event you can look into rather than bad luck.

The cost is that you see only what the primers were designed to reach. A target that has mutated under a primer site copies poorly or not at all. PCR also adds errors of its own. The polymerase occasionally miscopies a base, and it can join two template molecules into one [chimera](../../GLOSSARY.md#chimera), an artificial hybrid sequence that never existed in the sample. Most of these errors appear in only a small share of the reads at a position, so a variant caller's minimum-frequency filter usually removes them, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) explains.

## What an amplicon looks like, end to end

Take one amplicon in the abstract, with round numbers chosen for clarity rather than copied from a real scheme. Every position range in this manual counts both of its ends, so positions 1000 to 1021 is 22 bases and not 21. A 22-base forward primer binds at reference positions 1000 to 1021. A 22-base reverse primer binds at positions 1378 to 1399. The amplicon is everything between and including them, 400 bases from position 1000 to position 1399.

Sequence that amplicon on a run that reads 150 bases from each end, and the two reads of a pair read inward from opposite ends. Read 1 covers positions 1000 to 1149. Read 2 covers positions 1250 to 1399, from the other strand. The 100 bases in the middle get no reads from this amplicon, which is expected, because in a tiling scheme the neighbouring amplicons cover them.

Here is the part that decides everything downstream. The first 22 bases of read 1 are not your sample. They are the primer, which became the physical end of the amplicon during PCR and was copied into every later molecule. Whatever your sample truly carries at positions 1000 to 1021, the read shows the primer sequence there instead. The last 22 bases of read 2 do the same at the other end.

Now suppose your sample carries a real difference from the reference at position 1015, inside the forward primer site. The primer overwrote it, and every read says primer. Worse, suppose the primer itself carries a base that differs from your reference at that position. Then nearly every read reports the primer's base, with hundreds of reads behind it. A variant caller cannot tell that apart from a real mutation, so it reports one. What it found was the primer.

## Primer trimming

[Primer trimming](../../GLOSSARY.md#primer-trim) sets the primer bases aside so nothing downstream counts them as evidence. LGE can trim before or after [mapping](../../GLOSSARY.md#mapping), the step that places each read where it fits on the reference.

Trimming before mapping uses sequence matching. It looks for the primer's letters in each read and cuts them off, so it needs no reference. A sample that differs from the primer under its binding site no longer matches, though, and those bases slip through. Trimming after mapping uses position matching. It takes the primer scheme's coordinates and marks whatever bases sit there, whatever their letters, so they stay in the file but are left out of variant calling. In short, primers are matched by their letters before mapping and by their positions after mapping. A mutation under a primer cannot fool position matching, so prefer trimming after mapping whenever you have a scheme and a reference. [Primer trimming at the read level](../03-reads/04-trimming-and-filtering.md#primer-trimming-at-the-read-level) and [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) cover each stage.

![Before and after primer trimming, with the primer bases set aside](../../assets/illustrations-imagegen/01-foundations/03-amplicon-vs-shotgun/primer-trim-soft-clip.png)

## How to tell which prep your sample had

Three places usually hold the answer, in order of how far to trust them. The person who prepared the library is the authoritative record, so ask first. Next comes the submission record for a public dataset. The [SRA](../../GLOSSARY.md#sra) and the [ENA](../../GLOSSARY.md#ena) are the two public archives where raw sequencing reads are deposited, and each run there has a page whose library strategy field reads, for example, AMPLICON or WGS, short for whole-genome sequencing. Last, the protocol or paper the sample came from usually names the kit and its version.

Failing all three, the data itself gives hints. Amplicon depth steps up and down at fixed coordinates and repeats that shape in every sample prepared the same way. Many amplicon reads also begin at exactly the same position, the primer's, so their ends line up in an alignment view. Shotgun depth is smoother and does not repeat its bumps from sample to sample. Read length alone does not tell you, because an untrimmed Illumina run writes every read at the run's full length whichever prep made it.

A hint is not proof. Trimming against a guessed scheme is worse than not trimming, because it clips real sample bases at the wrong places and leaves the true primer bases in.

## Target enrichment, the third route

A third preparation sits between the two. This manual calls it [target enrichment](../../GLOSSARY.md#target-enrichment), and you will also meet it as capture or hybridisation capture. It starts like shotgun, with DNA broken at random. It then adds probes, pieces of DNA or RNA that pair with the regions you want and carry a tag that can be pulled out of the tube. The targeted fragments come out with the probes and the rest is washed away. A human exome kit, which pulls out the protein-coding parts of every gene, is the commonest example.

The method borrows from both sides. Like amplicon, it needs its targets chosen in advance and concentrates reads onto them. Like shotgun, its reads start at random places and carry no primer sequence. A probe can also still grab a target that differs from it in a few places, where a primer would fail to bind.

For every workflow in this manual, treat target-enrichment data as shotgun data and do not trim primers, since there are none. Expect its depth to dip at probe edges and in regions that differ from the probe sequence, rather than at amplicon junctions.

## Side by side

The table sets the three preparations against each other.

| Property | Shotgun | Amplicon | Target enrichment |
|---|---|---|---|
| Where reads start | Wherever the fragment broke | At the primer positions, every time | Wherever the fragment broke |
| Starting DNA needed | More | Less | More than amplicon |
| Reads that land on target | In proportion to what is present | Nearly all of them | A large share, fewer than amplicon |
| Primer trimming | Not needed | Required before variant calling | Not needed |
| Sees the unexpected | Yes | Only what the primers reach | Only what the probes reach |

Reach for shotgun when you do not yet know what is in the sample, when the target is abundant, or when you need an unbiased view. Reach for amplicon when the target is known, the starting material is scarce, and you want the same regions covered the same way across many samples so their results can be compared.

## What good looks like

Four checks are worth running before you trust an amplicon result. First, confirm the scheme name and version from a record rather than from memory. Second, confirm the scheme's reference accession, the database identifier of the genome its coordinates were written against, matches the reference the reads were mapped to, since the coordinates mean nothing otherwise. Third, confirm the trim actually ran. Select the primer-trimmed alignment, which [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows how to make, and look in the [Inspector](../../GLOSSARY.md#inspector) for a Primer-trim Derivation group naming the scheme. [The Inspector](06-the-lungfish-project.md#the-inspector) shows how to open it if it is hidden. Fourth, scan the variant list for a cluster of calls at close to 100% sitting at primer positions, which is what an untrimmed or wrongly trimmed run produces.

For a shotgun or target-enrichment result the checks are shorter. Confirm that no primer trim was applied, since there is nothing to trim, and expect a coverage curve without the repeating steps of an amplicon run, as [The coverage curve](../04-alignments/02-reading-an-alignment.md#the-coverage-curve) shows.

## Next

Continue to [Alignment Files](04-alignment-files.md) to see what a read looks like once it is mapped to a reference, and how trimmed primer bases are recorded there.
