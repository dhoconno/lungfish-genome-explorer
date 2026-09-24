---
title: What Is Read Classification
chapter_id: 06-classification/01-what-is-classification
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/07-plugin-packs, 03-reads/01-importing-fastq]
estimated_reading_min: 11
task: Understand the question read classifiers answer, tell the three classifiers LGE runs apart from the results it only imports, and pick the one that fits your sample.
tags: [classification, taxonomy, kraken2, esviritu, taxtriage, nao-mgs, nvd, cz-id]
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
glossary_refs: [fastq, read, taxon, taxonomic-rank, lowest-common-ancestor, read-classification, metagenomics, mapping, kraken2, esviritu, taxtriage, cz-id, nao-mgs, nvd, freyja, lineage, plugin-pack, k-mer, blast, container, nextflow, host-depletion, import-center, operations-panel, amplicon, accession, coverage, contig, rpkmf, reads-per-billion, reads-per-million, workflow-library]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
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

The worked examples in the chapters that follow use the SRR36291587 SARS-CoV-2 reads, a clinical [amplicon](../../GLOSSARY.md#amplicon) run of 170,398 reads, which is 85,199 read pairs. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. An amplicon is a stretch of genome copied many times by PCR before sequencing, so the run reads one viral genome deeply rather than the whole sample evenly. SRR36291587 is an [accession](../../GLOSSARY.md#accession), the permanent identifier the NCBI Sequence Read Archive gives one public sequencing run. The example is viral because the databases these classifiers use are built to name microbes and viruses, so a viral sample exercises them end to end. Even on a run aimed at one virus, classification confirms that the library holds that virus and little else. The concepts apply unchanged to a human specimen, where the result would show the host as the dominant taxon and the pathogen as a small slice beside it. A macaque specimen behaves the same way with one difference, since the Standard database holds the human genome and no macaque genome, so macaque reads land on human or primate rows or stay unclassified.

## What LGE runs and what it only imports

LGE draws a firm line between classifiers it launches for you and results it accepts from elsewhere. Knowing the side a tool sits on saves a search for a menu item that does not exist.

Three classifiers run inside the app. [Kraken2](../../GLOSSARY.md#kraken2) surveys a sample broadly. [EsViritu](../../GLOSSARY.md#esviritu) identifies viruses and reports [coverage](../../GLOSSARY.md#coverage) for each one, meaning how much of that virus's genome the reads reached. [TaxTriage](../../GLOSSARY.md#taxtriage) runs a pathogen-detection workflow that attaches a confidence score to each call, where a call is the decision that a given organism is present. The operation sheet describes them as "Classify reads taxonomically.", "Detect viruses and report coverage.", and "Run the TaxTriage pathogen workflow."

Three more tools produce results LGE reads but never runs. [CZ-ID](../../GLOSSARY.md#cz-id) is a hosted metagenomics service used through a web browser. [NAO-MGS](../../GLOSSARY.md#nao-mgs) is a wastewater surveillance pipeline from SecureBio. [NVD](../../GLOSSARY.md#nvd) is a novel-virus pipeline that stitches overlapping reads into longer sequences called [contigs](../../GLOSSARY.md#contig) and searches each one against a public collection with [BLAST](../../GLOSSARY.md#blast). For all three, you run the analysis elsewhere and bring its output into LGE, which turns it into a result you can browse and export. Each import chapter names the file its tool produces.

| Tool | Does LGE run it? | The question it answers best |
|---|---|---|
| Kraken2 | Yes, from **Tools > Classification > Kraken2...** | What is in this sample, across bacteria, archaea, viruses, and host? |
| EsViritu | Yes, from **Tools > Classification > EsViritu...** | Which viruses are here, and how much of each genome did the reads cover? |
| TaxTriage | Yes, from **Tools > Classification > TaxTriage...** | Is a reportable pathogen present, and how confident is the call? |
| CZ-ID | No, import only | What is in this sample, according to a run made on a hosted service? |
| NAO-MGS | No, import only | Which viral taxa are circulating in the community whose sewage this sample came from? |
| NVD | No, import only | Is there a virus here that no database names exactly? |

A colleague may have run Kraken2, EsViritu, or TaxTriage for you on another machine, so those results import too. That is why the Import Center's Classification Results tab carries six cards rather than three. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Then click the Classification Results tab.

<!-- SHOT: import-center-classification-tab -->

One tool in this part is not a classifier. [Freyja](../../GLOSSARY.md#freyja) estimates which SARS-CoV-2 [lineages](../../GLOSSARY.md#lineage), the named subgroups inside one virus species, are mixed together in a wastewater sample. It reads the variants and depths from a mapping run rather than classifying reads, so it belongs after mapping rather than in place of a classifier. [Running Freyja](07-running-freyja.md) covers it.

## Picking a classifier for your sample

Two questions settle the choice most of the time. How much do you already know about the sample, and what will you do with the answer?

Start with **Kraken2** when you have no specific hypothesis. LGE's menus write the name as Kraken2, and the tool's own documentation writes Kraken 2, and both mean the same program. Its Standard database covers archaea, bacteria, viruses, plasmids, the human genome, and UniVec, a collection of laboratory cloning vector sequence that sometimes contaminates a library and should not be read as a biological finding. Fungi and protozoa are not in Standard. They come with the PlusPF builds, whose name stands for Plus Protozoa and Fungi, where a build is one prepared version of a database rather than a different program. Kraken2 is also the right first move for routine quality control, where the question is whether the host fraction looks as expected and whether anything unexpected rides along. Kraken2 is fast because it looks up short exact words of sequence rather than aligning each read base by base. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases, and [Running Kraken 2](02-running-kraken2.md#what-it-is) shows how tools match on them.

Move to **EsViritu** once you know you are looking at a virus and want a more careful viral answer. Its database is a curated set of viral genomes, and rather than only counting reads it reports how much of each viral genome the reads covered. A hundred reads spread across a whole genome is a very different observation from a hundred reads stacked on one conserved gene, meaning a gene nearly identical across many organisms, and only the first supports saying the virus is present. Run EsViritu as a second pass after a broad survey, or first when the sample type makes a viral target near certain.

Reach for **TaxTriage** in a pathogen-detection setting where a reviewer needs to see how well supported each call is. It runs as a [Nextflow](../../GLOSSARY.md#nextflow) pipeline, a published multi-step workflow driven by a workflow engine, and each step runs in a [container](../../GLOSSARY.md#container), a packaged copy of a program with everything it needs. It is heavier to set up than the other two because it needs Nextflow and a container runtime, the program that starts and runs containers, on the Mac, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains. The TaxTriage pane carries a **Prerequisites** row with one indicator for each, so opening it tells you whether both are present. TaxTriage classifies against an installed Kraken2 database rather than carrying one of its own.

Import instead of rerunning when your lab already produced a result elsewhere, since a rerun costs hours and gives a second answer to reconcile with the first.

When the choice still feels open, run Kraken2 first to see the shape of the sample, then run a more specific tool on the same reads to sharpen whatever it turned up.

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

Every row a classifier reports is tied to the database it used. Change the database and the same reads give a different answer, and a taxon missing from a result was often never in the database to begin with. [Running Kraken 2](02-running-kraken2.md#what-good-looks-like) shows how to judge the unclassified share against the database you chose.

## Next

Continue to [Running Kraken 2](02-running-kraken2.md) for a full walkthrough of a broad survey, which is the run most readers want first. From there, [Running EsViritu](03-running-esviritu.md) covers viral identification with coverage, and [Running TaxTriage](04-running-taxtriage.md) covers confidence-scored pathogen detection. [BLAST Verification](06-blast-verification.md) shows how to check a single surprising hit against NCBI. The import chapters, [Importing NAO-MGS Results](05-running-nao-mgs.md), [Importing CZ-ID Results](08-importing-cz-id-results.md), and [Novel Virus Diagnostics](09-novel-virus-detection.md), cover results produced elsewhere.

One chapter in this part answers a classification question through a different menu. [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md) identifies vertebrate species from a short mitochondrial marker, and the app files it under **Tools > Genotyping** rather than Classification. It shows there as "12S Amplicon Matching (not enabled)" in grey until you turn it on. Turn the workflow on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Running External Workflows](../08-workflows/03-running-external-workflows.md#procedure) shows.
