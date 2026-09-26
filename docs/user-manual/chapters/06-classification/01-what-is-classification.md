---
title: What Is Read Classification
chapter_id: 06-classification/01-what-is-classification
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/07-plugin-packs, 03-reads/01-importing-fastq]
estimated_reading_min: 18
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
glossary_refs: [fastq, read, taxon, taxonomic-rank, lowest-common-ancestor, read-classification, metagenomics, mapping, kraken2, esviritu, taxtriage, cz-id, nao-mgs, nvd, freyja, lineage, plugin-pack, k-mer, blast, container, nextflow, host-depletion, import-center, operations-panel, amplicon, accession, shotgun, paired-end, coverage, contig, rpkmf, reads-per-billion, reads-per-million, workflow-library, bracken, minimap2, coverage-breadth, demixing, allele-frequency, sensitivity, specificity, consensus-sequence, tass-score, negative-control]
features_refs: []
fixtures_refs: [kraken-protocol-cornea, sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[Read classification](../../GLOSSARY.md#read-classification) answers one practical question about a sequencing run, which is what organisms the sample contained. A [read](../../GLOSSARY.md#read) is one stretch of sequence the instrument produced, stored as one record in a [FASTQ](../../GLOSSARY.md#fastq) file. A classifier is a program that compares each read against a reference database of known genomes and writes down which organism it best matches. The database is a folder of files installed on your own Mac, not a website the app queries. Classify every read in the file and you have a count of which organisms are present and in what proportion.

The answer for a single read is a [taxon](../../GLOSSARY.md#taxon), which is any named group on the tree of life. *Homo sapiens* is a taxon, and so are the primate family Hominidae and the virus family *Coronaviridae*. Every taxon sits at a [taxonomic rank](../../GLOSSARY.md#taxonomic-rank), the level of the naming hierarchy it belongs to. The ranks these tools report run from broadest to narrowest as domain, kingdom, phylum, class, order, family, genus, and species, so for a person the ladder reads Eukaryota, Metazoa, Chordata, Mammalia, Primates, Hominidae, *Homo*, *Homo sapiens*.

A classifier does not always reach species, and a call that stops at genus is still a usable answer. When a read's sequence is shared by several close relatives, the classifier steps back up the hierarchy and reports the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor), the most specific taxon that all the matching organisms belong to. A read that fits the rhesus macaque and the cynomolgus macaque equally well is reported as the genus *Macaca* rather than guessed at species. The tool picks that level from what the database contains, and you do not set it yourself.

This is a different question from [mapping](../../GLOSSARY.md#mapping). Mapping starts from an organism you already named and asks where on its genome each read fits. Classification starts from nothing and asks which organism each read came from. A common working pattern is to classify first to find out what is present, then map against whichever genome the classification named.

![A FASTQ bundle feeding a classifier box that carries a reference database, producing a taxonomy sunburst split into host, bacterial, viral, and unclassified shares](../../assets/illustrations-imagegen/06-classification/01-what-is-classification/classification-question.png)

The whole-sample answer is a distribution rather than a yes or no. It reports what share of the reads went to each taxon, plus a separate share the classifier could not place at all. This is [metagenomics](../../GLOSSARY.md#metagenomics), the study of all the nucleic acid in a mixed sample at once. Lungfish Genome Explorer (LGE) offers several classifiers, and they answer different questions, so the one decision to make before you run anything is which question you are asking.

A result can report a taxon in two ways, as a count or as a normalised abundance. A count is the number of reads assigned to the taxon, such as the Reads column of the Kraken2 table. A count grows with sequencing depth, so 2,000 reads means something different in a run of one million reads than in a run of fifty million, and a long genome collects more reads than a short one at the same concentration. A normalised abundance divides the count by the size of the library, and sometimes by the length of the genome as well, so figures from different samples can be set side by side. Each tool reports its own normalised figure, and each is defined in the chapter for that tool. EsViritu reports [RPKMF](03-running-esviritu.md#reading-the-results) (reads per kilobase of genome per million filtered reads), NVD reports [RPB](09-novel-virus-detection.md#reading-the-results) (reads per billion), a CZ ID summary reports [RPM](08-importing-cz-id-results.md#on-the-command-line) (reads per million), and 12S matching reports [% of Sample](10-twelve-s-metabarcoding.md#reading-the-results). Compare samples on the normalised figure, and use the count to judge how much evidence sits behind it.

## Why you would do this

You classify when you cannot fully predict what is in the tube. A clinical swab from a person or a macaque is the clearest case. Most of what a nasal or throat swab yields is the host's own genome, because sampling collects far more host cells than microbes, and whatever pathogen you are chasing sits somewhere in the remainder. Classification answers three questions at once:

1. How much of the run went to host background?
2. Does one bacterium dominate the rest?
3. Is the virus you suspected present at all?

A targeted assay, meaning a test that looks only for organisms chosen in advance, answers only the third.

The same reasoning covers wastewater, a culture you suspect is contaminated, and any run where you need to check that the library holds what you think it holds. [Host depletion](../../GLOSSARY.md#host-depletion), the removal of the sampled organism's own reads, is often run first because the host fraction is so large, and [Decontamination](../03-reads/05-decontamination.md) covers that step.

The worked examples in the chapters that follow use public runs from the NCBI Sequence Read Archive. Each run has an [accession](../../GLOSSARY.md#accession), the permanent identifier the archive gives one public sequencing run. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle.

The Kraken 2, TaxTriage, and BLAST chapters use human corneal tissue from BioProject PRJNA381365, a study that diagnosed eye infections from preserved clinical specimens. The main run, SRR12486983, comes from a person with herpes simplex keratitis, an infection of the cornea by herpes simplex virus 1 (HSV-1). It is the pathogen-identification example in the Kraken authors' own protocol paper, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y), *Nature Protocols* 17, 2815. It is a [shotgun](../../GLOSSARY.md#shotgun) library of 4,819,760 read pairs of up to 76 bases, so the reads sample whatever DNA the tissue held rather than one chosen target. The TaxTriage chapter adds a second case, SRR12486989, recorded as a *Streptococcus agalactiae* infection, to make a two-sample batch. The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds both runs ready to classify.

EsViritu and Freyja keep SRR36291587, a SARS-CoV-2 [amplicon](../../GLOSSARY.md#amplicon) run of 85,199 read pairs. An amplicon is a stretch of genome copied many times by PCR before sequencing, so that run reads one viral genome deeply. EsViritu discards any read that aligns along fewer than 100 bases, so the 76-base corneal reads give it nothing to report, and Freyja names SARS-CoV-2 lineages, so it needs SARS-CoV-2 reads.

A macaque specimen works the same way with one difference. The Standard database holds the human genome and no macaque genome, so macaque reads land on human or primate rows or stay unclassified. Do not read those rows as contamination. Expect a larger unclassified share than a human sample of the same kind would give.

## Choosing a tool

Two properties of your data settle the choice, what kind of organism you expect to find and how the library was made. A shotgun sample with no hypothesis, a suspected virus, a pathogen report that someone must sign off, a mix of SARS-CoV-2 lineages, and a list of vertebrate species each have their own route in LGE.

### Three ways to match a read

Every classifier here answers by one of three methods, and the method decides what the answer can mean.

The first is exact word lookup. Kraken 2 cuts each read into [k-mers](../../GLOSSARY.md#k-mer), stretches of exactly k bases, and looks each one up in a prebuilt table that records which taxon owns it. Strictly it looks up a compact sample of those words called minimizers, as [Running Kraken 2](02-running-kraken2.md#what-it-is) explains. Nothing is aligned, so millions of reads classify in seconds to minutes. The price is that a word counts only when it matches exactly. A virus that differs from every genome in the database every few bases shares few whole words with any of them, so many of its reads go unclassified.

The second is read mapping. EsViritu, and TaxTriage in its second round, line each read up against whole reference genomes with [minimap2](../../GLOSSARY.md#minimap2), allowing some mismatches, and record where on the genome it fits. Mapping is slower, but it tells you where the reads landed. That gives [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of a genome the reads reached, which is the evidence that separates a real infection from reads piled onto one shared stretch.

The third is lineage [demixing](../../GLOSSARY.md#demixing), which is what Freyja does. It names no organisms. Given reads already mapped to one virus, it reads the [allele frequency](../../GLOSSARY.md#allele-frequency), the fraction of reads carrying a change, at the positions that define each lineage, and estimates the blend of lineages that best explains those frequencies.

A few routes sit outside these three. 12S matching is stricter than any of them, and it accepts a read only when a whole known reference sequence sits inside it. Two of the imported tools work differently again. NVD joins overlapping reads into contigs and searches each contig with BLAST, and CZ-ID also compares reads against a protein database, where distant relatives still look alike after their DNA has drifted apart.

### Sensitivity, specificity, and the database

Two measures describe how well any classifier does. [Sensitivity](../../GLOSSARY.md#sensitivity) is the share of the organisms truly present that the tool finds. [Specificity](../../GLOSSARY.md#specificity) is the share of absent organisms it correctly leaves out, so a tool with poor specificity names things that are not there. A setting that raises one usually lowers the other. Kraken 2's Sensitivity control shows the trade in LGE. Precise names a read only when at least half its k-mers agree and three separate matches support it, which gives fewer false names and more unclassified reads. Sensitive names a read on a single match, which finds rare organisms and also more false ones. [Running Kraken 2](02-running-kraken2.md#settings) gives the exact values.

The database matters more than any setting. A classifier can only name what its database holds, so an organism missing from the database comes back as a relative or as unclassified, never under its own name. Size matters too. Kraken 2 loads its whole database into memory, so the capped builds Standard-8 and Standard-16 keep only a sample of the full Standard collection, which is about 67 GB, and they recognise fewer reads of every organism. On the corneal sample, Standard-16 recognised about a tenth as many HSV-1 reads as the half-gigabyte Viral database did, as [The same reads, a different database](02-running-kraken2.md#the-same-reads-a-different-database) shows. A small focused database is the more sensitive choice for the group it covers and blind to everything else.

Coverage evidence adds specificity. A hundred reads spread along a whole viral genome and a hundred reads stacked on one conserved gene, meaning a gene nearly identical across many organisms, give the same count, and only the first supports saying the virus is present. Kraken 2 cannot tell the two apart. EsViritu and TaxTriage can.

### The tools

**Kraken 2 with Bracken** is the broad survey, published by Wood and colleagues in 2019. LGE's menus write the name as Kraken2, and the tool's own documentation writes Kraken 2, and both mean the same program. Its Standard database covers archaea, bacteria, viruses, plasmids, the human genome, and UniVec, a collection of laboratory cloning vector sequence that sometimes contaminates a library and should not be read as a biological finding. Fungi and protozoa come only with the PlusPF builds, whose name stands for Plus Protozoa and Fungi, where a build is one prepared version of a database rather than a different program. Every run LGE starts also runs [Bracken](../../GLOSSARY.md#bracken) (Lu and colleagues, 2017). Bracken takes the reads Kraken 2 could place only at genus or family and shares them out among the species below, using a profile of which species the database confuses, to estimate how much of each species the sample holds. Kraken 2 is the fastest and broadest tool here, and the right first move for routine quality control. It is weakest on divergent viruses, and its report carries no coverage evidence.

**EsViritu** is the viral specialist, described by Tisza and colleagues in 2023 in a study of viruses in wastewater. It maps every read against 19,925 curated viral assemblies from 63 families and reports, for each virus, the reads, the breadth and depth of coverage, and a [consensus sequence](../../GLOSSARY.md#consensus-sequence), the single sequence the mapped reads agree on. It tells close viral relatives apart and gives a consensus you can take to BLAST or to a tree. It finds nothing but viruses, and it keeps an alignment only when at least 100 bases of the read align, so a run of 75-base or 76-base reads reports nothing. Expect minutes rather than seconds. The worked example of 85,199 read pairs took about six minutes on a fourteen-core Mac, and its database wants about 8 GB of memory.

**TaxTriage** is the scored report, a pipeline from the Johns Hopkins University Applied Physics Laboratory published by Merritt and colleagues in 2026. It runs Kraken 2 first, downloads a reference genome for each of the top hits, maps the reads back to those genomes, and folds breadth and depth of coverage into one [TASS score](../../GLOSSARY.md#tass-score) per organism, which LGE shows from 0 to 1 with a High, Medium, or Low label. It was built for clinical metagenomics, where a [negative control](../../GLOSSARY.md#negative-control), a blank tube carried through the whole protocol, sits in the same batch as the specimens. It runs as a [Nextflow](../../GLOSSARY.md#nextflow) pipeline, a published multi-step workflow driven by a workflow engine, and each step runs in a [container](../../GLOSSARY.md#container), a packaged copy of a program with everything it needs. Nextflow comes with LGE's Required Setup pack, but the containers need Docker Desktop, a separate free app, as [Running TaxTriage](04-running-taxtriage.md#before-you-start) explains. The first run also downloads the containers and needs the internet for reference genomes, so it is the slowest and heaviest route. It classifies against an installed Kraken 2 database, so it shares that database's gaps.

**Freyja** estimates which SARS-CoV-2 [lineages](../../GLOSSARY.md#lineage), the named subgroups inside one virus species, are mixed together in a sample, and was published by Karthikeyan and colleagues in 2022 for wastewater surveillance. It runs after mapping and primer trimming, and takes seconds. In LGE it has no menu item. It runs from `lungfish-cli` and comes in an experimental plugin pack. Its lineage barcode file, the table of which mutations define which lineage, is downloaded once at install, so a lineage named after that day cannot be reported. For a single patient's SARS-CoV-2 genome you do not need it, and [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md) is the route. [Running Freyja](07-running-freyja.md) covers it.

**12S Amplicon Matching** names the vertebrate species in a mixed sample, such as gut contents, a water sample, or a pooled field collection, from a short PCR-copied stretch of the mitochondrial 12S gene. In its Illumina mode a read counts only when it contains a known reference sequence with no changed bases, so it never reports a partial match. A species missing from the reference file cannot be reported. Kraken 2 is the wrong tool for this question, because the only vertebrate in its Standard database is human.

**CZ-ID**, published as IDseq by Kalantar and colleagues in 2020, is a hosted service from the Chan Zuckerberg Initiative. It removes host reads, then compares reads and assembled contigs against NCBI's nucleotide and protein collections and reports reads per million for each taxon. Its protein search can catch divergent viruses that exact word lookup misses. **NAO-MGS** is SecureBio's pipeline for very large wastewater studies, and it writes one row per read from a virus that infects humans. **NVD** is the O'Connor laboratory's novel-virus pipeline, and a long contig that matches a known virus only in part flags something new. LGE runs none of these three, so import their results rather than looking for a menu item.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Kraken 2 with Bracken | Broad surveys of shotgun data | You have no hypothesis, or you are checking a library | You need coverage evidence for a virus call |
| EsViritu | Viruses in clinical and wastewater shotgun data | You suspect a virus and want to show how much of its genome you recovered | Reads are under 100 bases, or the target is not a virus |
| TaxTriage | Clinical pathogen reports with controls | Each call must carry a score a reviewer can check | Docker Desktop is not an option, or a quick look will do |
| Freyja | SARS-CoV-2 lineage mixes in wastewater | The sample is known SARS-CoV-2 and may hold several lineages | You do not yet know what the sample holds |
| 12S Amplicon Matching | Vertebrate species from a 12S amplicon | You need a species list from an amplicon run | The library is shotgun, or the species are not in the reference |
| CZ-ID (import) | Hosted pathogen detection | A collaborator already ran it | You want the analysis on your own Mac |
| NAO-MGS (import) | Wastewater viral surveillance at scale | Your group already runs it on a cluster | You have a handful of clinical samples |
| NVD (import) | Finding viruses no database names exactly | Known-virus tools find little in a sick animal or patient | Any known virus explains the sample |

### When to confirm a hit with BLAST

Every method above can name the wrong organism, and BLAST is the tie-breaker. [BLAST](../../GLOSSARY.md#blast) aligns a sample of one taxon's reads against NCBI's full public collection and reports the closest matches with their identity. Run it when a call is unexpected for the sample type, when it rests on between about ten and a few thousand reads, or when a decision or a publication depends on it. [BLAST Verification](06-blast-verification.md) shows how.

### What this part's examples use

The corneal sample is a human shotgun library with no single target, so [Running Kraken 2](02-running-kraken2.md) surveys it twice, first against Viral and then against Standard-16, and [Running TaxTriage](04-running-taxtriage.md) scores the same sample beside a second case. Its reads are 76 bases long, which EsViritu cannot use, so [Running EsViritu](03-running-esviritu.md) and [Running Freyja](07-running-freyja.md) use the SARS-CoV-2 amplicon run instead. With your own data, run Kraken 2 first to see the shape of the sample, then a more specific tool on the same reads. Import instead of rerunning when your lab already produced a result elsewhere, since a rerun costs hours and gives a second answer to reconcile with the first.

Citations for each tool are in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), under [Pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines) for TaxTriage, and under [Imported classification results](../appendices/bibliography.md#imported-classification-results) for CZ-ID, NAO-MGS, and NVD.

## What LGE runs and what it only imports

LGE draws a firm line between classifiers it launches for you and results it accepts from elsewhere. Knowing the side a tool sits on saves a search for a menu item that does not exist. The operation sheet describes the three runnable classifiers as "Classify reads taxonomically.", "Detect viruses and report coverage.", and "Run the TaxTriage pathogen workflow."

| Tool | How you get a result in LGE |
|---|---|
| [Kraken2](../../GLOSSARY.md#kraken2) | Run it from **Tools > Classification > Kraken2...** |
| [EsViritu](../../GLOSSARY.md#esviritu) | Run it from **Tools > Classification > EsViritu...** |
| [TaxTriage](../../GLOSSARY.md#taxtriage) | Run it from **Tools > Classification > TaxTriage...** |
| [Freyja](../../GLOSSARY.md#freyja) | Run it with `lungfish-cli freyja`, with no menu item |
| 12S Amplicon Matching | Run it from **Tools > Genotyping** once enabled |
| [CZ-ID](../../GLOSSARY.md#cz-id), [NAO-MGS](../../GLOSSARY.md#nao-mgs), [NVD](../../GLOSSARY.md#nvd) | Import only |

For the three imports, you run the analysis elsewhere and bring its output into LGE, which turns it into a result you can browse and export. Each import chapter names the file its tool produces. A colleague may also have run Kraken2, EsViritu, or TaxTriage for you on another machine, so those results import too. That is why the Import Center's Classification Results tab carries six cards rather than three. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Then click the Classification Results tab.

<!-- SHOT: import-center-classification-tab -->

## Where the classifiers live

Every runnable classifier opens from **Tools > Classification**, a submenu with three items, **Kraken2...**, **EsViritu...**, and **TaxTriage...**. You choose the tool in the menu rather than in a later dialog.

<!-- SHOT: classification-submenu -->

A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. Select a reads bundle in the project sidebar before you open the menu, because the classifier works on whatever is selected. [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows how the bundle gets there. Picking a menu item opens the FASTQ/FASTA Operations sheet with your classifier already selected. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. Its tool sidebar lists all three classifiers, so switching from Kraken2 to EsViritu takes one click rather than a trip back to the menu.

<!-- SHOT: classification-dialog-tool-sidebar -->

Install a database first, as the Databases section below explains, then click **Run** to start. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Imported results land elsewhere, and the sidebar shows each one where it lands. Kraken2, EsViritu, TaxTriage, and NVD imports go to the project's `Imports` folder, NAO-MGS imports go under `Analyses/`, and a CZ-ID import writes a `.lungfishtax` bundle into a `Classifications` folder, as [Importing CZ-ID Results](08-importing-cz-id-results.md) explains.

## What you will see in the results

A Kraken2 result opens in the taxonomy viewport, a sunburst beside a table of taxa, which [Running Kraken 2](02-running-kraken2.md#reading-the-results) teaches you to read. A sunburst is a ring chart with one ring per rank, where each wedge is one taxon sized by its reads. Imported CZ-ID results open in the same viewport. EsViritu, TaxTriage, NAO-MGS, and NVD each open a table built around what that tool reports, and their own chapters describe them.

## Databases, and why you install one first

Download the Kraken2 or EsViritu database from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. Kraken2 holds its whole database in memory while it runs, so choose a build that fits your Mac's memory, which is why the capped builds Standard-8 and Standard-16, sized to fit in 8 GB and 16 GB of memory, exist beside the full 72 GB PlusPF. To see how much memory your Mac has, choose **Apple menu > About This Mac**.

Every row a classifier reports is tied to the database it used, as [Sensitivity, specificity, and the database](#sensitivity-specificity-and-the-database) explains. [Running Kraken 2](02-running-kraken2.md#what-good-looks-like) shows how to judge the unclassified share against the database you chose.

## Next

Continue to [Running Kraken 2](02-running-kraken2.md) for a full walkthrough of a broad survey, which is the run most readers want first. From there, [Running EsViritu](03-running-esviritu.md) covers viral identification with coverage, and [Running TaxTriage](04-running-taxtriage.md) covers confidence-scored pathogen detection. [BLAST Verification](06-blast-verification.md) shows how to check a single surprising hit against NCBI. The import chapters, [Importing NAO-MGS Results](05-running-nao-mgs.md), [Importing CZ-ID Results](08-importing-cz-id-results.md), and [Novel Virus Diagnostics](09-novel-virus-detection.md), cover results produced elsewhere.

One chapter in this part answers a classification question through a different menu. [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md) identifies vertebrate species from a short mitochondrial marker, and the app files it under **Tools > Genotyping** rather than Classification. It shows there as "12S Amplicon Matching (not enabled)" in grey until you turn it on. Turn the workflow on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Running External Workflows](../08-workflows/03-running-external-workflows.md#procedure) shows.
