---
title: What Is Read Classification
chapter_id: 06-classification/01-what-is-classification
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/07-plugin-packs, 03-reads/01-importing-fastq]
estimated_reading_min: 22
task: Understand the question read classifiers answer, tell the classifiers LGE runs apart from the results it only imports, compare what each result view counts, and pick the tool that fits your sample.
tags: [classification, taxonomy, kraken2, bracken, esviritu, taxtriage, nao-mgs, nvd, cz-id, freyja, 12s, contamination]
tools: []
parameters_refs: []
entry_points:
  - "Tools > Classification > Kraken2…"
  - "Tools > Classification > EsViritu…"
  - "Tools > Classification > TaxTriage…"
  - "File > Import Center… (Classification Results tab)"
shots:
  - id: classification-submenu
    caption: "In **Tools > Classification**, **Kraken2…**, **EsViritu…**, and **TaxTriage…** appear above the separator and **Enable 12S Amplicon Matching…** appears below it."
  - id: classification-dialog-tool-sidebar
    caption: "**Tools > Classification > Kraken2…** opens FASTQ/FASTA Operations with Kraken2 selected and EsViritu and TaxTriage visible in the tool sidebar."
  - id: import-center-classification-tab
    caption: "The **Classification Results** tab shows the **NAO-MGS Results**, **Kraken2 Results**, **EsViritu Results**, **TaxTriage Results**, **NVD Results**, and **CZ-ID Results** cards."
illustrations:
  - id: classification-question
    brief: "Schematic showing a FASTQ bundle on the left, a classifier box in the middle labeled with a reference database, and a sunburst diagram on the right with reads assigned to taxonomic groups (host, bacteria, virus, unclassified). Use Lungfish Creamsicle for the classifier box and Deep Ink for the labels."
  - id: classifier-decision-flowchart
    brief: "A left-to-right decision flowchart for choosing a classification route. First branch, sample type: a clinical swab or tissue from a person or macaque, wastewater, an environmental or diet sample, or a library you only want to check. Second branch, organism class you expect: anything (no hypothesis), a virus, a bacterium, a vertebrate species, or a SARS-CoV-2 lineage mix. Third branch, library prep: shotgun or amplicon, with short reads under 100 bases marked. Leaves name the tool and its chapter: Kraken 2 with Bracken (Running Kraken 2) for no hypothesis or a library check, EsViritu (Running EsViritu) for a virus in reads of 100 bases or more, Kraken 2 with the Viral database followed by TaxTriage for a virus in reads under 100 bases, TaxTriage (Running TaxTriage) for a clinical batch with controls where bacteria matter, 12S Amplicon Matching (12S Amplicon Metabarcoding) for a vertebrate roster from a 12S amplicon, Freyja (Running Freyja) for a SARS-CoV-2 lineage mix, and a side box of imports (CZ ID, NAO-MGS, NVD) for results someone ran elsewhere. Every path that ends at a call from Kraken 2, EsViritu, TaxTriage, NAO-MGS, or NVD carries a small arrow to BLAST Verification, the 12S leaf carries one marked unresolved clusters only, and Freyja and the CZ ID import carry none. Deep Ink labels, Creamsicle for the leaves, Cream background."
glossary_refs: [minimizer, fastq, read, fragment, mate, read-pair, alignment, taxon, taxonomic-rank, lowest-common-ancestor, read-classification, metagenomics, mapping, kraken2, esviritu, taxtriage, cz-id, nao-mgs, nvd, freyja, lineage, plugin-pack, k-mer, blast, container, docker, terminal, nextflow, host-depletion, import-center, operations-panel, amplicon, pcr, accession, shotgun, paired-end, coverage, contig, rpkmf, reads-per-billion, reads-per-million, workflow-library, bracken, minimap2, coverage-breadth, demixing, allele-frequency, sensitivity, specificity, precision, consensus-sequence, tass-score, negative-control, abundance, relative-abundance, false-positive, false-negative, contamination, unclassified-reads, unique-reads, confidence-kraken-2, twelve-s, bundle, project, ncbi, depth, library, kreport, taxon-report, inspector, barcode]
features_refs: [classify.kraken2, classify.esviritu, classify.taxtriage, classify.twelve-s, variants.freyja-demix, classify.nao-mgs, import.nvd, import.czid, viewport.taxonomy-browser, classify.blast-verify, classify.extract-reads]
fixtures_refs: [kraken-protocol-cornea, sarscov2-srr36291587, primate-12s]
brand_reviewed: false
lead_approved: false
---

## What it is

[Read classification](../../GLOSSARY.md#read-classification) uses sequencing reads to look for evidence of which organisms were in a sample. A DNA [fragment](../../GLOSSARY.md#fragment) is one piece of the sample's DNA as it went onto the sequencer. A [read](../../GLOSSARY.md#read) records the bases the sequencer reads from a fragment. [FASTQ](../../GLOSSARY.md#fastq) is a plain-text format that stores each read's bases and a quality score for each base. A classifier compares reads with a reference database, a collection of known sequences. A genome is an organism's full set of genetic material. [Kraken 2](../../GLOSSARY.md#kraken2) and [EsViritu](../../GLOSSARY.md#esviritu) are classifiers that use reference databases stored on your Mac.

A classifier assigns a read to a [taxon](../../GLOSSARY.md#taxon), a named group on the tree of life, when the sequence supports an assignment. A [taxonomic rank](../../GLOSSARY.md#taxonomic-rank) is a level in that hierarchy. The table shows the main ranks in order.

| Rank | Human example |
|---|---|
| Domain | Eukaryota |
| Kingdom | Metazoa |
| Phylum | Chordata |
| Class | Mammalia |
| Order | Primates |
| Family | Hominidae |
| Genus | *Homo* |
| Species | *Homo sapiens* |

A genus-level assignment can be useful when the read fits more than one species. A path through the tree runs from the root, the top of the tree, down to a taxon. When Kraken 2's best-scoring paths tie, it reports their [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor). This is the most specific taxon that includes all the tied matches. If the database holds both genomes, Kraken 2 can report the genus *Macaca* for a read that fits rhesus and cynomolgus macaques equally well. Once classification suggests a match, you can [map the reads](../04-alignments/01-mapping-reads-to-a-reference.md). [Mapping](../../GLOSSARY.md#mapping) finds where each read fits along one or more chosen reference sequences.

![A reads file feeding a classifier box, producing a sunburst that splits the reads among virus, bacteria, and host](../../assets/illustrations-imagegen/06-classification/01-what-is-classification/classification-question.png)

In [metagenomics](../../GLOSSARY.md#metagenomics), you study the nucleic acid from a mixed sample together. Lungfish Genome Explorer (LGE) offers a broad survey with Kraken 2 and more focused tools for specific groups. A Kraken 2 summary gives the share assigned to each taxon and the share of [unclassified reads](../../GLOSSARY.md#unclassified-reads), which received no assignment at any rank. Use those shares to decide which names to check.

### Counts, shares, and normalized figures

An [abundance](../../GLOSSARY.md#abundance) figure describes how much sequence supports a taxon. A raw count can tally reads, [read pairs](../../GLOSSARY.md#read-pair), or [alignments](../../GLOSSARY.md#alignment). A read pair holds the two reads from opposite ends of one fragment. An alignment records where a read fits a reference. A count of 2,000 reads means something different in a run of one million reads than in a run of fifty million.

A [relative abundance](../../GLOSSARY.md#relative-abundance) expresses a count as a share of a total. That total, called the denominator, might be all reads, only classified reads, or only reads from one virus. To compare shares, check that the tools count the same kind of item and use the same rule for what goes into the total.

A [library](../../GLOSSARY.md#library) is the DNA prepared for sequencing. Here, library size means the number of reads from that DNA. A normalized abundance adjusts the count for library size so you can compare runs with different totals. Reads per million ([RPM](../../GLOSSARY.md#reads-per-million)) and reads per billion ([RPB](../../GLOSSARY.md#reads-per-billion)) express counts on those respective scales. EsViritu's reads per kilobase of reference per million filtered reads ([RPKMF](../../GLOSSARY.md#rpkmf)) also adjusts for genome length. A kilobase is a thousand bases, and filtered reads are those that survived quality filtering.

Compare samples using the same tool's normalized figure, and check the raw count to see how many observations support it. The [result comparison tables](#comparing-the-result-views) show the units and denominators for each tool.

## Why you would do this

Classify reads when you are unsure what the sample holds. A nasal or throat swab often yields mostly DNA from the host, the person or animal sampled. The remaining reads may include the pathogen, an organism that causes disease. A broad survey helps you ask three questions.

1. How much of the run came from the host?
2. Does one bacterium dominate the remaining assignments?
3. Do any reads support the presence of the virus you suspect?

A targeted assay looks for targets chosen in advance. It can address the last question if the suspected virus is among them. A broad survey can also check wastewater or a culture for unexpected DNA. [Contamination](../../GLOSSARY.md#contamination) is DNA that entered the sample from outside it.

Classify the original library if you want to estimate the host share. [Host depletion](../../GLOSSARY.md#host-depletion) removes the sampled organism's reads from a copy, which you can use for mapping or sharing. A host index is a lookup built from the host genome that helps find those reads. LGE ships a host index for human only. See [Decontamination](../03-reads/05-decontamination.md) for the procedure.

## Choosing a tool

Choose a broad survey or a check for a particular group based on your question. Then check the read length and how the library was made. A [shotgun](../../GLOSSARY.md#shotgun) library samples whatever DNA the sample holds. An [amplicon](../../GLOSSARY.md#amplicon) is a chosen stretch of DNA copied by [PCR](../../GLOSSARY.md#pcr). PCR, short for polymerase chain reaction, makes many copies of a DNA stretch. An amplicon library restricts the analysis to the stretches copied. Check the sequencing platform, the type of instrument used, and whether the reads are single-end or [paired-end](../../GLOSSARY.md#paired-end). A single-end run reads one end of a fragment. A paired-end run reads both ends, producing two [mates](../../GLOSSARY.md#mate), or reads from the same fragment.

<!-- ILLUSTRATION: classifier-decision-flowchart -->

LGE shows these details on summary cards, boxes that show key facts about the reads, and in the [Inspector](../../GLOSSARY.md#inspector), the panel on the right. See [Quality Control for Reads](../03-reads/03-quality-control.md#where-lge-shows-the-facts-about-your-reads) to find them. For a library from one known organism, use Kraken 2 to check for contamination.

### Three ways to match a read

**Word lookup.** Kraken 2 breaks each read into overlapping [k-mers](../../GLOSSARY.md#k-mer), stretches of exactly k bases also called words. For example, the five-base words in `ACGTTGCA` are `ACGTT`, `CGTTG`, `GTTGC`, and `TTGCA`. Kraken 2 uses 35 bases per word and looks each k-mer up by its [minimizer](../../GLOSSARY.md#minimizer), a shorter, 31-base stretch. A k-mer is a hit when its minimizer is in the database. Kraken 2 tallies the hits to name a read along the best-supported path in the taxonomy, the hierarchy of named groups. The lookups are fast, but a virus with few matching stretches may leave many reads unclassified. [Running Kraken 2](02-running-kraken2.md#what-it-is) explains the lookup in more detail.

**Mapping.** EsViritu and TaxTriage line up reads against reference genomes with [minimap2](../../GLOSSARY.md#minimap2), a program that allows mismatched bases in an alignment. Mapping takes longer but gives [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of a genome the reads reach. A hundred reads across a viral genome can give stronger evidence than a hundred on a stretch shared by relatives.

**Estimating a mixture.** A [lineage](../../GLOSSARY.md#lineage) is a named subgroup of one virus species. [Freyja](../../GLOSSARY.md#freyja) estimates which lineages are mixed in a sample from reads already mapped to SARS-CoV-2, the virus that causes COVID-19. A mutation is a change in the sequence. At positions with mutations that help identify a lineage, Freyja uses the [allele frequency](../../GLOSSARY.md#allele-frequency), the share of reads at that position that carry the alternate base, a base that differs from the reference. [Demixing](../../GLOSSARY.md#demixing) estimates which mixture of lineages best explains those shares.

12S Amplicon Matching uses an exact match across a whole reference sequence from the mitochondrial [12S](../../GLOSSARY.md#twelve-s) gene. This lets you check for vertebrate species using the same short region in each.

### Sensitivity, precision, and the database

[Sensitivity](../../GLOSSARY.md#sensitivity) is the share of organisms present that the tool finds. [Precision](../../GLOSSARY.md#precision) is the share of reported names that are correct. Finding more of the organisms present can also mean reporting more names in error. The **Sensitive** and **Precise** presets for **Sensitivity** in the Kraken 2 [settings](02-running-kraken2.md#settings) illustrate that trade-off.

The reference sequences in the database limit what a classifier can identify. Reads from an organism the database lacks may match a relative, including when the reads come from the host. The Kraken authors' protocol paper recommends a database that holds at least the human genome. See [Lu et al. 2022, Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y), *Nature Protocols* 17, 2815.

Kraken 2's [Confidence](../../GLOSSARY.md#confidence-kraken-2) setting sets the minimum share of a read's k-mers that must support a taxon or taxa below it, 0.20 by default. It counts only k-mers without an ambiguous base, a position that lacks a definite base call.

Kraken 2 normally loads the whole database into memory (RAM). With **Memory mapping** checked, it reads the database from disk in pieces, which is much slower but avoids loading a database-sized copy into memory. To check your Mac's memory, choose **Apple menu > About This Mac**. The Standard database covers archaea, bacteria, viruses, plasmids, and the human genome. Plasmids are DNA molecules separate from a cell's main genome. The table shows LGE's memory estimates for five builds. Find the others and download databases in the **Databases** tab of **Tools > Plugin Manager…**, the window that installs tools and databases. See [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) for details.

| Database | Memory when loaded into RAM | Use it for |
|---|---|---|
| Viral | about 0.5 GB | A virus survey, even on a Mac with 16 GB |
| Standard-8, Standard-16 | 8 GB, 16 GB | A broad survey on a Mac with that much memory |
| Standard, PlusPF | more than 16 GB | A broad survey. PlusPF adds fungi and protozoa, a group of single-celled organisms. |

Standard-8 and Standard-16 keep a sample of the full Standard collection's lookup entries to fit in 8 GB and 16 GB. Fewer entries can mean fewer matches. On the corneal sample, from the clear front of the eye, Standard-16 found about a tenth as many herpes simplex virus 1 (HSV-1) reads as the Viral database did. Compare the [two database results](02-running-kraken2.md#the-same-reads-a-different-database) from that run.

### The tools

**Kraken 2 with Bracken** gives a broad survey. Every run from the **Kraken2…** dialog requests [Bracken](../../GLOSSARY.md#bracken), with no switch to turn it off. Bracken uses probabilities of how Kraken 2 classifies reads from each database genome. It estimates abundance at a chosen rank by dividing counts assigned above that rank among the taxa below. The estimates apply to groups of reads and appear beside Kraken 2's counts in a separate column. A virus that differs from every genome in the database may be missed.

**EsViritu** maps reads to see how much of a viral genome they cover. It was built for Illumina, a sequencing platform that produces short reads, each covering a short stretch of DNA. It maps against 19,925 curated viral genomes and reports read counts, breadth, [depth](../../GLOSSARY.md#depth), and a [consensus sequence](../../GLOSSARY.md#consensus-sequence) for each virus. Depth is the number of reads covering a base. A consensus sequence is the sequence the mapped reads agree on. EsViritu itself requires at least 100 aligned bases per read, so reads of 100 bases or more can count.

**[TaxTriage](../../GLOSSARY.md#taxtriage)** scores evidence for each of Kraken 2's top taxa. It downloads their genomes from [NCBI](../../GLOSSARY.md#ncbi), the US National Center for Biotechnology Information, and maps reads to them. This requires internet access. Its [TASS score](../../GLOSSARY.md#tass-score) weights breadth and evenness of coverage most by default. Read count has a small effect. TaxTriage needs a [negative control](../../GLOSSARY.md#negative-control), a blank carried through the same steps, to flag contamination from reagents, the materials used to process samples. It is the slowest route and requires [Docker Desktop](../../GLOSSARY.md#docker), a separate application you install yourself, to run [containers](../../GLOSSARY.md#container), packages that hold programs and their requirements. See [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) for setup.

| TASS score | What it represents |
|---|---|
| 0 | Least support from the mapping evidence |
| 1 | Most support from the mapping evidence |

**12S Amplicon Matching** names vertebrate species using a list of reference sequences you build. It counts each fragment once when it contains a whole reference sequence. A species absent from the list cannot appear in the result. Kraken 2's Standard database holds human as its only vertebrate, which limits its use for a mixed 12S sample.

**Freyja** estimates lineage shares in SARS-CoV-2 samples. Run it with `lungfish-cli`, LGE's command-line interface (CLI). You enter commands in [Terminal](../../GLOSSARY.md#terminal), the macOS app in the Utilities folder. Freyja's lineage barcodes, tables of changes that mark each lineage, download when you install its experimental [plugin pack](../../GLOSSARY.md#plugin-pack), a set of tools LGE adds on request. Check an experimental result a second time before reporting it. To reconstruct a SARS-CoV-2 genome, use [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) to build a consensus.

**[CZ ID](../../GLOSSARY.md#cz-id)** is a web service that searches NCBI's nucleotide and protein collections separately. A protein search can find evidence for a virus whose DNA differs too much for word lookup. Ask for the [taxon report](../../GLOSSARY.md#taxon-report), a table with one row per taxon and its read counts. The viewport, the panel that displays results, shows only the nucleotide counts, as [Importing CZ ID Results](08-importing-cz-id-results.md#what-the-conversion-keeps) explains.

**[NAO-MGS](../../GLOSSARY.md#nao-mgs)** is SecureBio's pipeline for wastewater surveillance. A pipeline is an analysis whose steps pass output from one to the next. It runs on a computing cluster, a group of computers that work together, or in the cloud, on remote computers. It reports reads that matched viral genomes. Ask the team that ran it for `virus_hits_final.tsv.gz`.

**[NVD](../../GLOSSARY.md#nvd)** is the O'Connor laboratory's pipeline for viruses that only partly match known sequences. It usually runs on a computing cluster. It assembles overlapping reads into longer sequences called [contigs](../../GLOSSARY.md#contig), then searches them with [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search. Ask for the `*_blast_concatenated.csv` file. For read-based checks, also ask for a full run, one whose output includes the contig sequences and alignment files.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Kraken 2 with Bracken | Broad surveys from your reads, via the menu | You need a first look, a library check, or bacterial assignments | You need coverage evidence. Add EsViritu or TaxTriage. |
| EsViritu | Short-read Illumina viral data, via the menu | You want viral coverage and reads can align across at least 100 bases | Reads are under 100 bases or bacteria matter. Use Kraken 2 or TaxTriage. |
| TaxTriage | Clinical batches with a negative control, via the menu | You need a score for each call, bacteria included | You cannot install Docker Desktop or need a quick survey. Use Kraken 2. |
| 12S Amplicon Matching | Vertebrate 12S reads, via the menu once enabled | You need a species list | Your library is shotgun. Use Kraken 2 for a broad survey. |
| Freyja | SARS-CoV-2 reads, via the command line | You need shares for a mixture of lineages | You need a consensus genome. Use the Viral Recon Wizard. |
| CZ ID | Results from the CZ ID web service, import only | A colleague already ran the sample there | You need per-read evidence, BLAST checks, or read extraction. |
| NAO-MGS | Wastewater virus hits, import only | A surveillance team supplies the virus-hit table | You need organisms other than viruses. |
| NVD | Searches of assembled viral sequences, import only | You have results for viruses that match known ones only partly | You need a broad survey of the whole sample. |

These situations narrow the choice further.

| Your situation | Run this |
|---|---|
| Wastewater reads of your own | [Running Freyja](07-running-freyja.md) for a SARS-CoV-2 lineage mix, or [Running EsViritu](03-running-esviritu.md) for other viruses when reads are 100 bases or more. |
| A suspected virus in reads under 100 bases | Kraken 2 with the Viral database, as the 76-base corneal reads show in [Running Kraken 2](02-running-kraken2.md). Follow with [Running TaxTriage](04-running-taxtriage.md) for coverage evidence, then [BLAST Verification](06-blast-verification.md) to check the name. |
| Oxford Nanopore reads, from a long-read sequencing platform | TaxTriage and 12S Amplicon Matching have a nanopore setting. Kraken 2 has no platform setting. LGE runs EsViritu only with its short-read setting. |

### What this part's examples use

The examples use public runs from the NCBI Sequence Read Archive. An [accession](../../GLOSSARY.md#accession) is the archive's permanent identifier for a run. A [project](../../GLOSSARY.md#project) is the folder LGE keeps your data and results in. A demo project is a ready-made example project LGE downloads for you. Open **Help > Demo Projects…** to find the examples, as the [demo project instructions](../01-foundations/06-the-lungfish-project.md#demo-projects) show.

The Pathogen Detection demo project holds the corneal runs from BioProject PRJNA381365, NCBI's record of a study that diagnosed eye infections from preserved specimens. Kraken 2, TaxTriage, and BLAST use those runs. SRR12486983 comes from a person with herpes simplex keratitis, here an infection of the cornea by HSV-1. Lu et al. 2022 use it to illustrate pathogen identification. It is a shotgun library of 4,819,760 read pairs of up to 76 bases, too short for EsViritu.

EsViritu and Freyja use SRR36291587, a SARS-CoV-2 amplicon run of 85,199 read pairs from a clinical specimen. Its amplicons are designed to cover the whole viral genome. The SARS-CoV-2 Amplicons demo project holds the run, so you can compare the Kraken 2 survey, EsViritu's coverage, and Freyja's lineage estimates on the same reads.

The 12S Metabarcoding demo project holds a simulated mixture of human, rhesus macaque, and cynomolgus macaque 12S reads with known proportions. 12S Amplicon Matching distinguishes the three species in that mixture. The Standard database holds the human genome and no macaque genome. A macaque read can be named *Homo sapiens*, be placed in a much broader group, or stay unclassified. No run in this manual measures which happens. Treat an unexpected human call in a macaque sample as a name to check before attributing it to contamination.

For your own shotgun reads, start with Kraken 2 when you need a broad survey. If you already have a specific question, use the tool table to choose a focused route. Find tool citations in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), including [pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines) for TaxTriage and [imported classification results](../appendices/bibliography.md#imported-classification-results) for CZ ID, NAO-MGS, and NVD.

## Why a classifier reports things that are not there

A [false positive](../../GLOSSARY.md#false-positive) is a reported name for something absent. A [false negative](../../GLOSSARY.md#false-negative) is something present that the tool missed. Three sources are the usual ones for false positives.

**A match to a relative.** Related organisms share stretches of DNA. Reads from a species missing from the database can match a relative that is present. A mapping tool such as EsViritu puts the read on whichever reference fits best. In the corneal run, 28 read pairs went to chimpanzee herpesvirus, a close relative of HSV-1, beside 886,221 pairs assigned to HSV-1. Those 28 pairs could be HSV-1 reads that fit the relative slightly better, or they could have another cause. See [Small hits beside a big one](02-running-kraken2.md#small-hits-beside-a-big-one) for the results.

**Laboratory and reagent contamination.** DNA can enter from extraction kits, water, the bench, or people handling the sample. In a low-biomass sample, one with little DNA of its own, even a trace of contaminating DNA is a larger share of a small total, as [Salter and colleagues 2014](https://pubmed.ncbi.nlm.nih.gov/25387460/) showed with a diluted culture. The corneal run includes *Cutibacterium acnes*, a skin bacterium, and *Bradyrhizobium*, a genus Salter and colleagues list among reported reagent contaminants. See the [corneal run comparison](02-running-kraken2.md#the-same-reads-a-different-database) for those rows.

**Carry-over between samples.** Material can pass between samples through a shared plate or pipette tip. A misread index, the short tag that identifies a sample, can also put a read in the wrong sample. A strong signal in one sample can then appear weakly in its neighbors.

If a name keeps appearing in unrelated samples, check whether the reads support it. A BLAST search can show whether the reads also fit close relatives. It sends a sample of the reads to NCBI, as [BLAST Verification](06-blast-verification.md#before-you-start) explains.

## The evidence checklist

Before reporting a name, ask five questions. Each tool chapter's What good looks like section shows which you can answer from its result view.

1. How many reads support the name? A small count can come from any of the sources above.
2. Does the spread of reads fit the library? For shotgun reads, matches spread across a genome usually give stronger support than matches to one shared stretch. For a single-marker amplicon such as 12S, check whether the targeted stretch distinguishes the species.
3. How many original fragments do the reads represent? Copies of one fragment count as one observation. A [unique-read count](../../GLOSSARY.md#unique-reads) counts reads left after duplicate marking, which groups alignments with the same start, end, and strand and counts each group once.
4. What do the controls show? Compare the blank with each sample to see whether the sample has support beyond the background.
5. Does an independent method agree? Agreement with a BLAST search, a second classifier, or a PCR test adds support. Weigh it alongside the count, coverage, and controls.

Write your review rule before looking at results so you apply the same standard to each call. Kraken 2's table answers the count question. EsViritu, TaxTriage, NAO-MGS, and NVD add coverage and a unique-read count, with a full run needed for NVD's unique reads. Sequence a blank in the same run and compare it using the same tool and database. In TaxTriage, the **Negative Control** role marks which sample is the blank and lets the tool compare it with the rest of the batch.

## What LGE runs and what it only imports

Start from your reads with Kraken 2, EsViritu, or TaxTriage in the app, or use 12S Amplicon Matching once you turn it on. Freyja runs only with `lungfish-cli freyja`. [Running Freyja](07-running-freyja.md) shows the command in use. CZ ID, NAO-MGS, and NVD run elsewhere. LGE can import their results so you can browse and export them.

You can also import Kraken 2, EsViritu, or TaxTriage results made elsewhere. To open the [Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center), the window that brings files into the open project, choose **File > Import Center…** (Cmd-Shift-I), then select **Classification Results**.

<!-- SHOT: import-center-classification-tab -->

Every import on this tab runs a `lungfish-cli import` command. To record how you imported a result, use **Copy CLI Command** in the right-click menu for its row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which lists running and finished tasks.

A workflow is a series of analysis steps. LGE lists optional workflows in the [Workflow Library](../../GLOSSARY.md#workflow-library). At the foot of **Tools > Classification**, **Enable 12S Amplicon Matching…** offers to open that window. See [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) to enable it.

## Where the classifiers live

Each classifier saves its result inside the open project. With no project open, the first three items in **Tools > Classification** show **No Project Open**. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) to open or create a project.

The classifier uses the reads you select in the project sidebar, the list on the left. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item and keeps both mates together for paired-end reads. See [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) to add a bundle. Select the bundle, or Cmd-click to select several. Open **Tools > Classification** and choose **Kraken2…**, **EsViritu…**, or **TaxTriage…**. Once enabled, 12S Amplicon Matching is available in the same menu.

<!-- SHOT: classification-submenu -->

Your menu choice opens the FASTQ/FASTA Operations dialog with that tool selected. Use the tool sidebar to switch among the three classifiers. See [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) for the layout.

<!-- SHOT: classification-dialog-tool-sidebar -->

Kraken 2 and TaxTriage use an installed Kraken 2 database. Choose one in the dialog using the [memory table](#sensitivity-precision-and-the-database). EsViritu shows its one database and offers **Download Database…** when it is missing. Its database needs about 8 GB of memory.

Click **Run** at the bottom of the dialog to start the selected classifier. To follow its progress, open **Operations > Show Operations Panel** (Cmd-Shift-P). Open the finished result from its new folder under `Analyses` in the sidebar.

## Comparing the result views

Use the first table to find your result and its view. CZ ID goes under `Classifications`. A viewport is the panel in the middle of the window that shows a result. A sunburst is a ring chart with one ring per rank. A [kreport](../../GLOSSARY.md#kreport) is the Kraken 2 summary report, with one row per taxon.

| Tool | Where it lands | Result view |
|---|---|---|
| Kraken 2 | `Analyses/kraken2-<timestamp>/`, or `Analyses/classification-<name>/` when imported from a kreport | Taxonomy viewport, a sunburst beside a table of taxa |
| EsViritu | `Analyses/esviritu-<timestamp>/`, or `Analyses/esviritu-<name>/` when imported | EsViritu viewport, a detection table |
| TaxTriage | `Analyses/taxtriage-batch-<timestamp>/`, or `Analyses/taxtriage-<name>/` when imported | TaxTriage viewport, an organism table |
| 12S Amplicon Matching | `Analyses/12S amplicon results/<name>.lungfish12s` | 12S viewport, with a species table. The **Unresolved** view holds reads with no reference match or matches to several species with no clear winner. See [Alternates and the abundance rule](10-twelve-s-metabarcoding.md#alternates-and-the-abundance-rule) for how 12S handles those reads. |
| Freyja | The folder you name with `--output-dir` | Text file of lineages and their shares |
| CZ ID | `Classifications/<sample>.lungfishtax` | Taxonomy viewport |
| NAO-MGS | `Analyses/naomgs-<name>/` | NAO-MGS viewport, a taxon table |
| NVD | `Analyses/nvd-<experiment>/` | NVD viewport, a contig outline |

Before comparing values, check what the tool counts and what total it uses to calculate a share. A pair represents two reads from one fragment. Filtering or merging can change the relationship between reported read and pair counts. Where offered, **Verify with BLAST…** and **Extract Reads…** appear in the action bar at the bottom of the viewport and in a row's right-click menu. Extraction saves the taxon's reads as a new bundle. The `core_nt` collection is a version of NCBI's general nucleotide collection. See [BLAST Verification](06-blast-verification.md#settings) for the search settings.

| Tool | Unit counted | Normalized figure and its denominator | What Unique Reads means | **Verify with BLAST…** | **Extract Reads…** |
|---|---|---|---|---|---|
| Kraken 2 | Fragments, so a read pair counts once | % of all fragments in the same sample, unclassified included | No such column | Yes, against `core_nt` | Yes |
| EsViritu | Reads, each mate counted once | RPKMF, per kilobase of reference per million filtered reads | Left after duplicate marking | Yes, against `core_nt` | Yes |
| TaxTriage | Alignment records, one placement of a read per line, each mate counted | Abundance, TaxTriage's % of the sample's reads aligned to the organism | Left after duplicate marking | Yes, against `core_nt` | Yes |
| 12S Amplicon Matching | Fragments containing a whole reference sequence, counting each merged read (two mates joined into one), single read, or pair whose mates agree once | % of Sample, a share of exact-matched fragments only | No such column | Unresolved clusters only | No |
| Freyja | Mutation frequencies at lineage-defining positions | Abundances, shares of the virus in the sample | No such column | No | No |
| CZ ID | CZ ID's nucleotide read count per taxon | % of the report's root row count, with RPM in the output of `lungfish-cli cz-id summary` | No such column | No | No |
| NAO-MGS | Aligned reads, called Hits, each mate counted as one read | None. Read raw Hits against each sample's read total. | Left after duplicate marking | Yes, against `core_nt` | Yes |
| NVD | Contigs, with the reads that mapped back to each | RPB, per billion of the sample's reads | Left after duplicate marking, on a full run with contig sequences and alignment files | Yes, the contig itself, on a full run | Yes, on a full run |

**Unique Reads** means the same thing in all four views that carry it. In a shotgun library, a small share is a reason to check whether many reads came from copies of the same fragments. A primer is a short piece of DNA that binds a chosen position and starts DNA synthesis there. In an amplicon library, copies of a region can share endpoints because the same primers set the ends. That design can yield a small share of unique reads. See [Running EsViritu](03-running-esviritu.md#reading-the-results) for how the library affects this count.

The Kraken 2, EsViritu, TaxTriage, NAO-MGS, and NVD views share **Panel Layout** on the Inspector's **Summary** tab. The choices are **Detail | List**, **List | Detail**, and **List Over Detail**. The default is **Detail | List**, with detail on the left and the table on the right. Changing the choice applies it to all five views.

| Where it appears | What it means |
|---|---|
| Kraken 2 **Confidence** | Threshold on the share of k-mers that support an assignment |
| TaxTriage **Confidence** | **High**, **Medium**, or **Low**, based on the TASS score |
| BLAST verification verdict | **Supported**, **Not specific**, **Mixed**, **Unsupported**, or **Inconclusive**. See [The summary bar and the verdict](06-blast-verification.md#the-summary-bar-and-the-verdict) for their meanings. |

In an Oxford Nanopore run, **Unclassified** labels reads assigned to no [barcode](../../GLOSSARY.md#barcode), the tag identifying a sample in a run that combines several samples.

## Next

For a broad survey, continue to [Running Kraken 2](02-running-kraken2.md) to classify the corneal reads. [Running EsViritu](03-running-esviritu.md) shows how to measure viral coverage, [Running TaxTriage](04-running-taxtriage.md) shows how to score calls, and [BLAST Verification](06-blast-verification.md) shows how to check a name. For vertebrate species or SARS-CoV-2 lineages, see [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md) or [Running Freyja](07-running-freyja.md) for the corresponding procedure.
