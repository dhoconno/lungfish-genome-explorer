---
title: What Is Read Classification
chapter_id: 06-classification/01-what-is-classification
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/07-plugin-packs, 03-reads/01-importing-fastq]
estimated_reading_min: 15
task: Understand the question read classifiers answer, tell the three classifiers LGE runs apart from the results it only imports, and pick the one that fits your sample.
tags: [classification, taxonomy, kraken2, bracken, esviritu, taxtriage, nao-mgs, nvd, cz-id, freyja, 12s]
tools: []
parameters_refs: []
entry_points:
  - Tools > Classification > Kraken2...
  - Tools > Classification > EsViritu...
  - Tools > Classification > TaxTriage...
  - File > Import Center... (Classification Results tab)
shots:
  - id: classification-submenu
    caption: "The Tools menu open on its Classification submenu, showing the three runnable classifiers as separate items, Kraken2..., EsViritu..., and TaxTriage..."
  - id: classification-dialog-tool-sidebar
    caption: "The FASTQ/FASTA Operations sheet opened from Tools > Classification > Kraken2..., with Kraken2 already selected and the tool sidebar listing EsViritu and TaxTriage beside it."
  - id: import-center-classification-tab
    caption: "The Import Center on its Classification Results tab, showing all six cards, NAO-MGS Results, Kraken2 Results, EsViritu Results, TaxTriage Results, NVD Results, and CZ-ID Results."
illustrations:
  - id: classification-question
    brief: "Schematic showing a FASTQ bundle on the left, a classifier box in the middle labelled with a reference database, and a sunburst diagram on the right with reads assigned to taxonomic groups (host, bacteria, virus, unclassified). Use Lungfish Creamsicle for the classifier box and Deep Ink for the labels."
glossary_refs: [minimizer, fastq, read, taxon, taxonomic-rank, lowest-common-ancestor, read-classification, metagenomics, mapping, kraken2, esviritu, taxtriage, cz-id, nao-mgs, nvd, freyja, lineage, plugin-pack, k-mer, blast, container, nextflow, host-depletion, import-center, operations-panel, amplicon, accession, shotgun, paired-end, coverage, contig, rpkmf, reads-per-billion, reads-per-million, workflow-library, bracken, minimap2, coverage-breadth, demixing, allele-frequency, sensitivity, specificity, consensus-sequence, tass-score, negative-control]
features_refs: []
fixtures_refs: [kraken-protocol-cornea, sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[Read classification](../../GLOSSARY.md#read-classification) answers one practical question about a sequencing run, which is what organisms the sample contained. A [read](../../GLOSSARY.md#read) is one stretch of sequence the instrument produced, stored as one record in a [FASTQ](../../GLOSSARY.md#fastq) file. A classifier is a program that compares each read against a reference database of known genomes and writes down which organism it best matches. The database is a folder of files installed on your own Mac, not a website the app queries. Classify every read in the file and you have a count of which organisms are present and in what proportion.

The answer for a single read is a [taxon](../../GLOSSARY.md#taxon), which is any named group on the tree of life. *Homo sapiens* is a taxon, and so are the primate family Hominidae and the virus family *Coronaviridae*. Every taxon sits at a [taxonomic rank](../../GLOSSARY.md#taxonomic-rank), the level of the naming hierarchy it belongs to. The ranks these tools report run from broadest to narrowest as domain, kingdom, phylum, class, order, family, genus, and species, so for a person the ladder reads Eukaryota, Metazoa, Chordata, Mammalia, Primates, Hominidae, *Homo*, *Homo sapiens*.

A classifier does not always reach species, and a call that stops at genus is still a usable answer. When a read's sequence is shared by several close relatives, the classifier steps back up the hierarchy and reports the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor), the most specific taxon that all the matching organisms belong to. In a database that holds both genomes, a read that fits the rhesus macaque and the cynomolgus macaque equally well is reported as the genus *Macaca* rather than guessed at species. The tool picks that level from what the database contains, and you do not set it yourself.

This is a different question from [mapping](../../GLOSSARY.md#mapping). Mapping starts from an organism you already named and asks where on its genome each read fits. Classification starts from nothing and asks which organism each read came from. A common working pattern is to classify first to find out what is present, then map against whichever genome the classification named.

![A FASTQ bundle feeding a classifier box that carries a reference database, producing a taxonomy sunburst split into host, bacterial, viral, and unclassified shares](../../assets/illustrations-imagegen/06-classification/01-what-is-classification/classification-question.png)

The whole-sample answer is a distribution rather than a yes or no. It reports what share of the reads went to each taxon, plus a separate share the classifier could not place at all. This is [metagenomics](../../GLOSSARY.md#metagenomics), the study of all the nucleic acid in a mixed sample at once. Lungfish Genome Explorer (LGE) offers several classifiers, and they answer different questions, so the one decision to make before you run anything is which question you are asking.

A result can report a taxon in two ways, as a count or as a normalised abundance. A count is the number of reads assigned to the taxon, such as the Reads column of the Kraken2 table. A count grows with sequencing depth, so 2,000 reads means something different in a run of one million reads than in a run of fifty million, and a long genome collects more reads than a short one at the same concentration. A normalised abundance divides the count by the size of the library, and sometimes by the length of the genome as well, so figures from different samples can be set side by side. Each tool names its normalised figure differently, and each tool's chapter defines its own, as [EsViritu's](03-running-esviritu.md#reading-the-results) does. Compare samples on the normalised figure, and use the count to judge how much evidence sits behind it.

## Why you would do this

You classify when you cannot fully predict what is in the tube. A clinical swab from a person or a macaque is the clearest case. Most of what a nasal or throat swab yields is the host's own genome, because sampling collects far more host cells than microbes, and whatever pathogen you are chasing sits somewhere in the remainder. Classification answers three questions at once:

1. How much of the run went to host background?
2. Does one bacterium dominate the rest?
3. Is the virus you suspected present at all?

A targeted assay, meaning a test that looks only for organisms chosen in advance, answers only the third.

The same reasoning covers wastewater, a culture you suspect is contaminated, and any run where you need to check that the library holds what you think it holds. [Host depletion](../../GLOSSARY.md#host-depletion), the removal of the sampled organism's own reads, is often run first because the host fraction is so large, and [Decontamination](../03-reads/05-decontamination.md) covers that step.

The examples in the chapters that follow use public runs from the NCBI Sequence Read Archive. Each run has an [accession](../../GLOSSARY.md#accession), the permanent identifier the archive gives one public sequencing run. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle.

The Kraken 2, TaxTriage, and BLAST chapters use human corneal tissue from BioProject PRJNA381365, a study that diagnosed eye infections from preserved clinical specimens. The main run, SRR12486983, comes from a person with herpes simplex keratitis, an infection of the cornea by herpes simplex virus 1 (HSV-1). It is the pathogen-identification example in the Kraken authors' own protocol paper, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y), *Nature Protocols* 17, 2815. It is a [shotgun](../../GLOSSARY.md#shotgun) library of 4,819,760 read pairs of up to 76 bases, so the reads sample whatever DNA the tissue held rather than one chosen target. The TaxTriage chapter adds a second case, SRR12486989, recorded as a *Streptococcus agalactiae* infection, to make a two-sample batch. The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds both runs ready to classify.

EsViritu and Freyja keep SRR36291587, a SARS-CoV-2 [amplicon](../../GLOSSARY.md#amplicon) run of 85,199 read pairs. An amplicon is a stretch of genome copied many times by PCR before sequencing, so that run reads one viral genome deeply. EsViritu discards any read that aligns along fewer than 100 bases, so the 76-base corneal reads give it nothing to report, and Freyja names SARS-CoV-2 lineages, so it needs SARS-CoV-2 reads.

A macaque specimen works the same way with one difference. The Standard database holds the human genome and no macaque genome, so macaque reads land on human or primate rows or stay unclassified. Do not read those rows as contamination. Expect a larger unclassified share than a human sample of the same kind would give.

## Choosing a tool

First check the facts in [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool). Here the choice rests on what kind of organism you expect and how the library was made. If the sample came from one organism you already know, such as a person's whole-genome library, classification is only a contamination check, and one Kraken 2 run answers it.

### Three ways to match a read

Every classifier here matches reads in one of three ways. The first is exact word lookup. Kraken 2 cuts each read into [k-mers](../../GLOSSARY.md#k-mer), overlapping words of exactly k bases, and looks each word up in a prebuilt table that records which taxon owns it. Take the read `ACGTTGCA` and words of five bases. It gives four words, `ACGTT`, `CGTTG`, `GTTGC`, and `TTGCA`. If three of the four are listed under one bacterium, the read is named as that bacterium. Real words are about 35 bases long, and Kraken 2 looks up a compact sample of them called [minimizers](../../GLOSSARY.md#minimizer). It is fast because nothing is aligned, but a word counts only when it matches exactly, so a virus that differs from every database genome every few bases leaves many reads unclassified.

The second is read mapping. EsViritu, and TaxTriage in its second round, line each read up against whole reference genomes with [minimap2](../../GLOSSARY.md#minimap2), allowing mismatches, and TaxTriage in LGE uses minimap2's short-read mode for Illumina reads and its nanopore mode for Oxford Nanopore reads. Mapping is slower but gives [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of a genome the reads reached. A hundred reads spread along a whole viral genome show the virus is present, and a hundred stacked on one conserved gene do not, though Kraken 2 counts both the same.

The third is lineage [demixing](../../GLOSSARY.md#demixing), which is what Freyja does. From reads mapped to one virus, it reads the [allele frequency](../../GLOSSARY.md#allele-frequency), the fraction of reads carrying a change, at the positions that define each lineage, and estimates the blend of lineages that best explains them.

### Sensitivity, precision, and the database

[Sensitivity](../../GLOSSARY.md#sensitivity) is the share of the organisms truly present that a tool finds. Precision is the share of its reported names that are correct. [Specificity](../../GLOSSARY.md#specificity) is the share of absent organisms correctly left out. Raising sensitivity usually lowers precision, as Kraken 2's [Sensitivity control](02-running-kraken2.md#settings) shows.

The database matters more than any setting. A read from an organism the database lacks is not simply left out. It can be named as the nearest relative the database holds, and host reads are the usual case. The Kraken protocol paper therefore advises including the host genome, and Confidence should stay above zero. Kraken 2 also loads its whole database into memory. The capped builds Standard-8 and Standard-16 fit in 8 GB and 16 GB by keeping only a sample of the full Standard collection's words, so they recognise fewer reads of every organism. On the corneal sample, Standard-16 found about a tenth as many HSV-1 reads as the [Viral database did](02-running-kraken2.md#the-same-reads-a-different-database).

### The tools

**Kraken 2 with Bracken** is the broad survey. Its Standard database covers archaea, bacteria, viruses, plasmids, the human genome, and UniVec, a collection of cloning vector sequence that can contaminate a library. Fungi and protozoa need the PlusPF builds. Every run started from the Kraken2 dialog also runs [Bracken](../../GLOSSARY.md#bracken), which shares reads Kraken 2 could place only at genus or family among the species below. It is the fastest and broadest tool here, and the weakest on divergent viruses.

**EsViritu** is the viral specialist. It maps reads against 19,925 curated viral assemblies and reports reads, breadth and depth of coverage, and a [consensus sequence](../../GLOSSARY.md#consensus-sequence), the sequence the mapped reads agree on, for each virus. It was built for short-read Illumina data, finds only viruses, and ignores any alignment shorter than 100 bases.

**TaxTriage** is the scored report. It runs Kraken 2, downloads a reference genome for each top hit, maps the reads to them, and folds breadth and depth into one [TASS score](../../GLOSSARY.md#tass-score) from 0 to 1 per organism. It was built for clinical batches that include a [negative control](../../GLOSSARY.md#negative-control), a blank tube carried through the whole protocol. It is the slowest route, needs [Docker Desktop](04-running-taxtriage.md#before-you-start), and shares its Kraken 2 database's gaps.

**Freyja** estimates which SARS-CoV-2 [lineages](../../GLOSSARY.md#lineage), the named subgroups of one virus species, are mixed in a sample. LGE runs it from `lungfish-cli` only, with SARS-CoV-2 lineage barcodes downloaded when its experimental pack is installed, and reinstalling the pack fetches newer ones. For one patient's SARS-CoV-2 genome use the [Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) instead.

**12S Amplicon Matching** names the vertebrate species in a mixed sample from a short PCR-copied stretch of the mitochondrial 12S gene, counting a read only when it contains a whole known reference sequence. Kraken 2 cannot answer this, because the only vertebrate in its Standard database is human.

Three routes are imports only. **CZ ID** is a hosted service whose protein search can catch viruses too divergent for word lookup. **NAO-MGS** is SecureBio's pipeline for very large wastewater studies. **NVD** is the O'Connor laboratory's pipeline for finding viruses no database names exactly.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Kraken 2 with Bracken | Broad surveys of shotgun data | You have no hypothesis, or you are checking a library | You need coverage evidence for a virus call |
| EsViritu | Viruses in short-read shotgun data | You suspect a virus and want to show how much of its genome you recovered | Reads are under 100 bases, or the target is not a virus |
| TaxTriage | Clinical pathogen reports with controls | Each call must carry a score a reviewer can check | Docker Desktop is not an option, or a quick look will do |
| Freyja | SARS-CoV-2 lineage mixes | The sample is known SARS-CoV-2 and may hold several lineages | You have one patient's genome |
| 12S Amplicon Matching | Vertebrate species from a 12S amplicon | You need a species list from an amplicon run | The library is shotgun, or the species are not in the reference |
| CZ ID, NAO-MGS, NVD (import) | Analyses run elsewhere | Someone already ran one | You want to run it on your Mac |

### When to confirm a hit with BLAST

Any method can name the wrong organism. [BLAST](../../GLOSSARY.md#blast) aligns a sample of one taxon's reads against NCBI's full public collection and reports the closest matches with their identity. Run it when a call is unexpected for the sample type, rests on few reads, or will support a decision or a publication. [BLAST Verification](06-blast-verification.md) shows how.

### What this part's examples use

The corneal sample is a human shotgun library with no single target, so Kraken 2 surveys it and TaxTriage scores it. Its 76-base reads give EsViritu nothing, so EsViritu and Freyja use the SARS-CoV-2 amplicon run. With your own data, run Kraken 2 first to see the shape of the sample, then a more specific tool on the same reads. Citations are in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), with TaxTriage under [Pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines) and the imports under [Imported classification results](../appendices/bibliography.md#imported-classification-results).

## What LGE runs and what it only imports

LGE draws a firm line between classifiers it launches for you and results it accepts from elsewhere. Knowing the side a tool sits on saves a search for a menu item that does not exist. The operation sheet describes the three runnable classifiers as "Classify reads taxonomically.", "Detect viruses and report coverage.", and "Run the TaxTriage pathogen workflow."

| Tool | How you get a result in LGE |
|---|---|
| [Kraken2](../../GLOSSARY.md#kraken2), which its authors write Kraken 2 | Run it from **Tools > Classification > Kraken2...** |
| [EsViritu](../../GLOSSARY.md#esviritu) | Run it from **Tools > Classification > EsViritu...** |
| [TaxTriage](../../GLOSSARY.md#taxtriage) | Run it from **Tools > Classification > TaxTriage...** |
| [Freyja](../../GLOSSARY.md#freyja) | Run it with `lungfish-cli freyja`, with no menu item |
| 12S Amplicon Matching | Run it from **Tools > Genotyping** once enabled |
| [CZ ID](../../GLOSSARY.md#cz-id), [NAO-MGS](../../GLOSSARY.md#nao-mgs), [NVD](../../GLOSSARY.md#nvd) | Import only |

For the three imports, you run the analysis elsewhere and bring its output into LGE, which turns it into a result you can browse and export. Each import chapter names the file its tool produces. A colleague may also have run Kraken2, EsViritu, or TaxTriage for you on another machine, so those results import too. That is why the Import Center's Classification Results tab carries six cards rather than three. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Then click the Classification Results tab.

<!-- SHOT: import-center-classification-tab -->

## Where the classifiers live

Every runnable classifier opens from **Tools > Classification**, a submenu with three items, **Kraken2...**, **EsViritu...**, and **TaxTriage...**. You choose the tool in the menu rather than in a later dialog.

<!-- SHOT: classification-submenu -->

A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. Select a reads bundle in the project sidebar before you open the menu, because the classifier works on whatever is selected. [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows how the bundle gets there. Picking a menu item opens the FASTQ/FASTA Operations sheet with your classifier already selected. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. Its tool sidebar lists all three classifiers, so switching from Kraken2 to EsViritu takes one click rather than a trip back to the menu.

<!-- SHOT: classification-dialog-tool-sidebar -->

Install a database first, as the Databases section below explains, then click **Run** to start. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Imported results land elsewhere, and the sidebar shows each one where it lands. Kraken2, EsViritu, TaxTriage, and NVD imports go to the project's `Imports` folder, NAO-MGS imports go under `Analyses/`, and a CZ ID import writes a `.lungfishtax` bundle into a `Classifications` folder, as [Importing CZ-ID Results](08-importing-cz-id-results.md) explains.

## What you will see in the results

A Kraken2 result opens in the taxonomy viewport, a sunburst beside a table of taxa, which [Running Kraken 2](02-running-kraken2.md#reading-the-results) teaches you to read. A sunburst is a ring chart with one ring per rank, where each wedge is one taxon sized by its reads. Imported CZ ID results open in the same viewport. EsViritu, TaxTriage, NAO-MGS, and NVD each open a table built around what that tool reports, and their own chapters describe them.

## Databases, and why you install one first

Download the Kraken2 or EsViritu database from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. Kraken2 holds its whole database in memory, so choose a build that fits your Mac, such as Standard-8 or Standard-16 rather than the full 72 GB PlusPF, for the reasons [Sensitivity, precision, and the database](#sensitivity-precision-and-the-database) gives. EsViritu's database wants about 8 GB of memory. To see how much memory your Mac has, choose **Apple menu > About This Mac**. [Running Kraken 2](02-running-kraken2.md#what-good-looks-like) shows how to judge the unclassified share against the database you chose.

## Next

Continue to [Running Kraken 2](02-running-kraken2.md) for a full walkthrough of a broad survey, which is the run most readers want first. From there, [Running EsViritu](03-running-esviritu.md) covers viral identification with coverage, and [Running TaxTriage](04-running-taxtriage.md) covers confidence-scored pathogen detection. [BLAST Verification](06-blast-verification.md) shows how to check a single surprising hit against NCBI. The import chapters, [Importing NAO-MGS Results](05-running-nao-mgs.md), [Importing CZ-ID Results](08-importing-cz-id-results.md), and [Novel Virus Diagnostics](09-novel-virus-detection.md), cover results produced elsewhere.

One chapter in this part answers a classification question through a different menu. [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md) identifies vertebrate species from a short mitochondrial marker, and the app files it under **Tools > Genotyping** rather than Classification. It shows there as "12S Amplicon Matching (not enabled)" in grey until you turn it on. Turn the workflow on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Running External Workflows](../08-workflows/03-running-external-workflows.md#procedure) shows.
