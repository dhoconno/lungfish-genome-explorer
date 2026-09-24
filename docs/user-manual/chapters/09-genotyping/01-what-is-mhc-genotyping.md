---
title: What Is MHC Genotyping
chapter_id: 09-genotyping/01-what-is-mhc-genotyping
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 12
task: Understand the question an MHC genotyping run answers, tell an allele apart from a haplotype, and pick between the two genotyping workflows LGE offers.
tags: [genotyping, mhc, immunogenetics, amplicon, macaque, rhesus]
tools: []
parameters_refs: []
entry_points:
  - "Tools > Genotyping > miSeq amplicon MHC genotyping..."
  - "Tools > Genotyping > Full-length ONT MHC genotyping..."
shots:
  - id: genotyping-submenu
    caption: "The Tools menu open on its Genotyping submenu, showing the three specialized workflows it holds, miSeq amplicon MHC genotyping..., 12S Amplicon Matching..., and Full-length ONT MHC genotyping..., with any workflow that is not yet enabled shown in grey followed by (not enabled)."
illustrations: []
glossary_refs: [alignment, allele, allele-target, amplicon, bbmerge, class-i-mhc, class-ii-mhc, clustering, fasta, fastq, genotype-matrix, haplotype, homozygous, immunogenetics, ipd-mhc, locus, mcm, mhc, minimap2, pcr, plugin-pack, primer, provenance, read, reference-bundle, required-setup-pack, retained-read, variant-caller, workflow-library]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

MHC genotyping asks which versions of a set of immune-system genes an individual animal carries. The [MHC](../../GLOSSARY.md#mhc), short for major histocompatibility complex, is a dense cluster of genes whose proteins sit on the cell surface and display fragments of what the cell is making, so the immune system can inspect them. It is the most variable region of a vertebrate genome. Reads from one animal's alleles often will not align cleanly, meaning line up base for base, to another animal's sequence, so the region gets its own assay, meaning its own laboratory panel and its own analysis. A [locus](../../GLOSSARY.md#locus) is the place on a chromosome where one gene sits, and an [allele](../../GLOSSARY.md#allele) is one of the alternative sequences a locus can carry. At most MHC loci the known alleles run into the hundreds.

The assay works by [amplicon](../../GLOSSARY.md#amplicon) sequencing. An amplicon is a short stretch of DNA copied many times from one defined region by [PCR](../../GLOSSARY.md#pcr), the reaction that makes millions of copies of a chosen piece of DNA. A pair of [primers](../../GLOSSARY.md#primer), short synthetic DNA pieces that mark where copying starts, sits in sequence shared by every allele at a locus and flanks the variable stretch between them, so whatever alleles the animal carries come back as amplicons. The [reads](../../GLOSSARY.md#read), each one stretch of sequence from one DNA fragment, arrive as a [FASTQ](../../GLOSSARY.md#fastq) file.

Lungfish Genome Explorer (LGE) then compares each read against a library of known allele sequences held as a [FASTA](../../GLOSSARY.md#fasta) file, a plain-text file listing each sequence under a name. The library comes from the [immunogenetics](../../GLOSSARY.md#immunogenetics) community, the researchers who study immune-system genes, through a database such as [IPD-MHC](../../GLOSSARY.md#ipd-mhc). You supply it yourself as a [reference bundle](../../GLOSSARY.md#reference-bundle). Every sequence in it is an [allele target](../../GLOSSARY.md#allele-target), one reference sequence a read either matches or does not. For each allele target the run asks whether any reads in a sample match it exactly, and how many. The answer is a [genotype matrix](../../GLOSSARY.md#genotype-matrix) with allele targets as rows and samples as columns, where a filled cell holds a read count.

That is a different question from variant calling. A [variant caller](../../GLOSSARY.md#variant-caller) lines reads up against one reference genome and lists every position where the sample differs from it. Genotyping never reports a position. It names which catalogued sequences are present, and a read that differs from every allele target by one base is not counted. A named allele is the unit immunologists work with, because it is the unit that is inherited, published, and matched between animals.

Before you run anything, decide whether your reads are short amplicons or full-length sequences. Read length is the test, and the summary cards LGE shows for an imported read bundle give it. Reads of a few hundred bases or less are short amplicons. Reads long enough to cover a whole allele, typically well over a thousand bases from an Oxford Nanopore instrument, are full length. LGE's two genotyping workflows divide on that question.

## Why you would do this

You genotype the MHC when the alleles an animal carries change how you interpret everything else you measure about it.

The first case is study design in nonhuman primate research. Macaques are the standard model for vaccine and infectious-disease studies, and MHC genotype strongly shapes how an animal's immune system responds. Assigning animals to groups without knowing their genotypes risks filling one treatment group with animals that keep virus levels low on their own, so the study measures their genetics rather than the treatment. The same workflow applies to human HLA work, HLA being the human name for the MHC, provided you supply a human allele library.

The second is interpreting an immune response after the fact. A T cell is an immune cell that inspects the fragments an MHC protein displays. When a T cell recognizes a fragment of a pathogen, one particular MHC protein displayed it, so you need each animal's alleles to say which animals could make that response.

The third is colony management. A breeding colony tracks genotypes across generations, and confirming which animals are the parents of which needs the same assay run consistently on every animal.

The worked example throughout this part of the manual is the Williams MiSeq genotyping project, a rhesus macaque study of 30 animals sequenced on an Illumina MiSeq, a benchtop sequencing instrument. It does not ship with LGE, so its figures are for orientation. Rhesus macaque MHC genes carry the prefix `Mamu`, from *Macaca mulatta*. The run matched its reads against the IPD-MHC Mamu allele library dated 2021-07-09, which holds 970 allele targets, 362 of them group records, single entries standing for several alleles each, as [How allele names are built](#how-allele-names-are-built) explains. A 2021 library is still usable in 2026 provided every run in a study uses the same one, because calls made against different releases are not comparable.

## Alleles, loci, and haplotypes

Three words get used interchangeably in conversation and mean different things in a result.

An allele is a single sequence at a single locus, and it is the unit the assay measures. An animal has two copies of each chromosome, so it carries at most two alleles at one locus, and they can be the same.

A locus is the gene, and the MHC holds many. [Class I](../../GLOSSARY.md#class-i-mhc) genes are carried on nearly every cell and show fragments of what that cell makes, which is how an infected cell is recognized. [Class II](../../GLOSSARY.md#class-ii-mhc) genes sit on a smaller set of immune cells and show fragments taken in from outside. The Williams result reports 13 loci. Its class I loci are MHC-A, MHC-AG, MHC-B, MHC-E, MHC-F, MHC-G, MHC-I, and MHC-J, and its class II loci are MHC-DPA1, MHC-DPB1, MHC-DQA1, MHC-DQB1, and MHC-DRB. These names drop the species prefix, so `MHC-A` here is the locus written `Mamu-A1` inside an allele name. Which loci appear depends on the allele library, and the run's [provenance](../../GLOSSARY.md#provenance) record names the library it read.

A [haplotype](../../GLOSSARY.md#haplotype) is the level above both, a set of alleles across several linked loci inherited together as one block. They travel together because recombination, the shuffling of chromosome copies when eggs and sperm are made, rarely cuts between loci this close together. A haplotype lets immunologists name a whole MHC region with one label. A run never observes a haplotype directly. It observes alleles, and a haplotype is an interpretation built on them.

LGE can make that interpretation when you choose Deterministic haplotyping in the run dialog and give it haplotype definitions, lists of the diagnostic alleles that mark each haplotype. A diagnostic allele is one found on some haplotypes and not others, so seeing it narrows down which haplotype an animal carries. [MCM](../../GLOSSARY.md#mcm), the Mauritian cynomolgus macaque, is the usual teaching set, because its small founding population left it only a handful of haplotypes, named M1 to M7. Each sample then gets two haplotype calls per locus, one per chromosome copy. An animal carrying the same haplotype on both copies is [homozygous](../../GLOSSARY.md#homozygous), and LGE reports it as one haplotype. When two definitions share every observed diagnostic allele, LGE cannot tell them apart and reports both joined by a vertical bar, as in `M4|M7`. [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#haplotype-calls) shows how to read these calls.

## How allele names are built

An allele name in a result is not something LGE composes. It is the record name from the FASTA library, copied through unchanged, so reading one means reading that library's convention.

The IPD-MHC library the Williams project used builds each name in three parts. Take `01_Mamu-A1_001_05_01_01` and read it left to right. The leading `01` groups records by locus, so every record beginning `01_` belongs to the same locus family. Next comes the species and locus prefix, `Mamu-A1` here. Last comes the allele designation, `001_05_01_01`, numbers separated by underscores that run from broad to specific.

Each added number narrows the call. Two alleles agreeing on the first number are close relatives, and each further number they share makes them closer. In the naming systems this convention follows, the earlier numbers track differences that change the protein and the later ones track differences that do not. The library records no meaning for each position, so treat the ladder as a measure of relatedness rather than a promise about protein sequence.

Many records carry a `g` and a list after a vertical bar, as in `01_Mamu-A1_001g1|A1_001_01_01_01,A1_001_01_01_02,A1_001_02`. That marks a group record. The `g` says the record stands for several alleles, and the digit after it numbers the groups within that allele family. The amplicon this panel sequences is only about 156 bases long, one variable exon of a gene that runs to several thousand bases. Several published alleles are identical across that short stretch while differing elsewhere, so the library folds them into one record and lists every member after the bar.

A call on a group record says the animal carries one of the listed alleles and the assay cannot say which. It is one call, not several, and the length of the name says nothing about the length of the sequence.

A library can still hold two records whose sequences are identical, either directly or as reverse complements (the same sequence read from the opposite DNA strand), when the curators did not group them. A read would then match both equally. LGE finds such records when it loads the library, keeps the first one, and credits it with all their reads, so the group appears as one row. The run's report file names the others, as [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results) describes.

## What LGE offers, and where it lives

Every genotyping workflow opens from **Tools > Genotyping**. The submenu holds two MHC workflows, **miSeq amplicon MHC genotyping...** and **Full-length ONT MHC genotyping...**. A third item, **12S Amplicon Matching...**, identifies vertebrate species from a short mitochondrial marker and is covered by [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md). It sits here because it uses the same exact-matching method.

<!-- SHOT: genotyping-submenu -->

Oxford Nanopore, abbreviated ONT, makes the long-read instruments the second workflow expects.

| Workflow | Reads it expects | The question it answers best |
|---|---|---|
| miSeq amplicon MHC genotyping | Illumina paired reads, or Oxford Nanopore reads, from a short-amplicon panel | Which catalogued alleles does each animal carry, as finely as a short amplicon can tell them apart? |
| Full-length ONT MHC genotyping | Oxford Nanopore reads long enough to span a whole allele | What is the full-length sequence of each allele, including ones no library names yet? |

The first name misleads slightly. **miSeq amplicon MHC genotyping** handles both Illumina paired reads and Oxford Nanopore reads from a short-amplicon panel. It works out which your reads are and says so in a caption in its dialog. There is no separate short-read ONT item.

Running either workflow on the wrong reads raises no error. It produces a poor result instead. Full-length reads pushed through the short-amplicon workflow rarely span an allele target end to end and mostly go uncounted, and short reads pushed through the full-length workflow cluster into nothing usable.

All three items are specialized workflows, shown in grey with `(not enabled)` until you turn them on. The packs each workflow needs and how to turn it on are in [Before you start](02-running-genotyping.md#before-you-start) of Running Amplicon MHC Genotyping.

## What counts as a supporting read

A genotyping run is strict about what it counts, and the rule explains most of the numbers in a finished result.

The unit being judged is the [alignment](../../GLOSSARY.md#alignment), one record of where a single read was placed against one allele target. An alignment is retained only when it covers the allele target from its first base to its last, and the read agrees with the reference at every one of those bases. One substituted base disqualifies it.

The indel case needs stating carefully. LGE counts substitutions, positions where the read carries a different base from the reference. An insertion or a deletion inside the span does not by itself disqualify a read. In practice this rarely widens what passes, because a read must still cover every reference base and agree at each one. Treat the rule as exact matching over the full length, with the narrow exception that a gap is not counted as a mismatch.

Reads that fail are discarded, not counted weakly. A read matching an allele target over 90 percent of its length with two differences is evidence for some allele, but not for that one, and counting it would create a call the data does not support.

The [retained read](../../GLOSSARY.md#retained-read) count in a result cell is the number of reads that passed for that allele target in that sample. Because the rule is strict, the retained fraction is much smaller than a mapping workflow would report, and a low fraction is not by itself a problem. In the Williams run 2,854,092 reads went in and 682,927 were retained, 23.9 percent. LGE defines no threshold for that percentage, so compare your own runs against each other.

A run where nearly everything passes is worth a second look. The usual cause is an allele library built from these very reads, which guarantees a good-looking result and proves nothing. The run's own count of why reads were dropped is read in [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results).

The full-span rule matters for Illumina paired reads, where each DNA fragment is read from both ends and each of the two reads, called a mate, can be shorter than the longest amplicons. LGE merges overlapping pairs first so the 244-base DRB amplicons can be spanned, as [step 3 of Running Amplicon MHC Genotyping](02-running-genotyping.md#3-read-the-mode-caption-and-leave-the-merge-alone) explains.

## What a finished run looks like

Both workflows write a `.lungfishgenotype` bundle under the project's `Analyses/` folder, and clicking it opens the genotype matrix, which [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) covers. The run also writes plain CSV report files you can read without LGE, which [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results) lists.

## What good looks like

The checks that make a result worth interpreting are about depth, whether each sample carried enough reads for a blank cell to mean the allele is absent, and [step 2 of Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#step-2-judge-the-depth-of-the-whole-run) applies them. Check also that the run used the allele library you meant, because a run against the wrong species or release produces a full result that is entirely wrong, and only the provenance record names the library.

## Next

Continue to [Running Amplicon MHC Genotyping](02-running-genotyping.md), which walks a run from selecting reads to a finished bundle. [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) covers the matrix once you have a result open, and [Exporting Genotypes](04-haplotype-definitions-and-export.md) covers taking a result out of LGE.
