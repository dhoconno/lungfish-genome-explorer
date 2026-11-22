---
title: Running Kraken 2
chapter_id: 06-classification/02-running-kraken2
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 26
task: Classify a FASTQ bundle with Kraken 2 against an installed database, read the taxonomy viewport, and pull the reads of one taxon out as a new bundle.
tags: [classification, kraken2, bracken, taxonomy, sunburst, extraction]
tools: [kraken2, bracken]
parameters_refs: [classify.kraken2, classify.taxonomy-browser, classify.extract-reads-by-taxon]
entry_points:
  - "Tools > Classification > Kraken2…"
  - "Selection > Table Row > Extract Reads…"
  - "CLI: lungfish-cli kraken2 classify"
shots:
  - id: kraken2-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > Kraken2…, with the dataset line naming Imports/SRR12486983.lungfishfastq, the Database picker on Viral with its description and recommended memory, and the Sensitivity control on Balanced."
  - id: kraken2-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the Confidence slider, the Min hit groups stepper, the Threads stepper, the Memory mapping checkbox, and the Extra arguments field."
  - id: kraken2-taxonomy-viewport
    caption: "The taxonomy viewport after classifying SRR12486983 against the Viral database, with the summary cards along the top, the sunburst on the left, the per-taxon table on the right with its Filter taxa… field and taxa count, and the action bar along the bottom with Verify with BLAST…, Export, Extract Reads…, BLAST Results, and Collections."
  - id: kraken2-drilldown-orthoherpesviridae
    caption: "The sunburst re-centred on Orthoherpesviridae after a double-click, with the breadcrumb bar showing the path back to the root."
  - id: kraken2-extract-reads
    caption: "The right-click menu on the Orthoherpesviridae row, listing Extract Reads… above the Expand and Collapse items, then Verify with BLAST…, Open Taxonomy on NCBI, Open GenBank Record, Search PubMed, and Copy Name."
illustrations:
  - id: clade-vs-direct-counts
    brief: "A small vertical tree for the cornea sample's Viral result, one node per rank from the family Orthoherpesviridae through the subfamily Alphaherpesvirinae, the genus Simplexvirus, and the species Simplexvirus humanalpha1, down to Human alphaherpesvirus 1, with a short side branch from the genus to Simplexvirus paninealpha3. Beside each node print two numbers, Reads (the clade count) and Direct (the reads assigned to that node only). Use the chapter's figures, Orthoherpesviridae 893,154, Alphaherpesvirinae 893,152, Simplexvirus 893,039 with Direct 6,789, Simplexvirus humanalpha1 886,221 with Direct 0, Human alphaherpesvirus 1 886,221 with Direct 886,221, and Simplexvirus paninealpha3 28. Show the clade count as a bar that shrinks only slightly down the tree and the Direct count as a small filled segment, so the reader sees that Reads sums everything below and Direct counts only the reads that stopped at that node. Deep Ink text, Creamsicle bars, Cream background."
glossary_refs: [accession, abundance, blast, bracken, confidence-kraken-2, false-positive, contamination, fragment, mate, relative-abundance, unclassified-reads, bundle, capped-database, checksum, clade, clade-count, fastq, host-depletion, inspector, interleaved-fastq, k-mer, kraken2, kreport, lowest-common-ancestor, metagenomics, minimizer, negative-control, operations-panel, paired-end, plugin-pack, provenance, read, read-classification, shannon-diversity, shotgun, sra, taxon, taxonomic-rank, taxonomy-id, library, read-pair]
features_refs: [classify.kraken2, viewport.taxonomy-browser, classify.extract-reads, results.table-row-commands, classify.blast-verify]
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

[Kraken 2](../../GLOSSARY.md#kraken2) is a program that names the organism each sequencing read most likely came from. A [read](../../GLOSSARY.md#read) is one short stretch of DNA sequence from the sequencer, and a [FASTQ](../../GLOSSARY.md#fastq) file is a text file that holds reads, often millions of them, each with a quality score for every base. The answer for each read is a [taxon](../../GLOSSARY.md#taxon), any named group on the tree of life, so *Homo sapiens*, *Macaca mulatta*, and the herpesvirus family *Orthoherpesviridae* are each one taxon. Do that for every read in a file and you have a census of what was in the tube.

Kraken 2 matches short words rather than aligning whole sequences. Aligning means lining two sequences up base by base and scoring them, which is accurate and slow. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases taken from a longer sequence, so `ACGTA` holds three 3-mers, `ACG`, `CGT`, and `GTA`. Kraken 2's default k is 35, so a 76-base read, the longest in this chapter's example, holds 42 k-mers. The database does not store every k-mer of every genome. It stores a [minimizer](../../GLOSSARY.md#minimizer) for each, by default the smallest 31-base stretch inside it, where smallest means first in a fixed sort order the program applies. Neighbouring k-mers often share a minimizer, so the database needs far fewer entries than it would for every k-mer and stays small.

Kraken 2 slides along each read one base at a time, takes the minimizer of each k-mer, and looks it up in a prebuilt database. The database files each minimizer under one taxon, and a minimizer that relatives share goes under their [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor), the smallest group in the tree that contains all of them. In simplified terms, each minimizer found is a hit for the taxon it is filed under, and the taxon whose branch of the tree collects the most hits wins the read, provided it clears the confidence threshold described under Settings. A table lookup is far quicker than an alignment, and it also means the answer is exactly as good as the database and no better, a point the rest of this chapter returns to.

When a read fits several relatives equally, Kraken 2 reports their lowest common ancestor instead of guessing, as [What Is Read Classification](01-what-is-classification.md#what-it-is) explains. If the database holds both genomes, a read that fits human and macaque equally well is reported as Catarrhini, the smallest group in the tree that holds both. A Kraken 2 report therefore has counts sitting at every [rank](../../GLOSSARY.md#taxonomic-rank) at once, not only at species.

Lungfish Genome Explorer (LGE) labels the tool **Kraken2** in its menus. Every run LGE starts is two programs. Kraken 2 assigns the reads, and then [Bracken](../../GLOSSARY.md#bracken) estimates each species' read count by sharing the reads that Kraken 2 left at a broad group out among the species beneath it. Roughly, it shares them in proportion to the reads each species received on its own, so Bracken's figure is an estimate across many reads and not a verdict on any one read. The result opens in the taxonomy viewport, a sunburst chart beside a table of taxa. Treat it as a first survey from one database, and verify any hit that matters.

## Why you would do this

Run Kraken 2 whenever you do not already know, or cannot yet prove, what is in a [sequencing library](../../GLOSSARY.md#library), the prepared mix of DNA pieces loaded onto the sequencer. A clinical swab from a person or a macaque is the obvious case, where most reads are host and the pathogen sits somewhere in the rest. The less obvious cases come up more often. A library you believe is one organism may be a mislabelled tube or a cross-contaminated plate, and the two look identical until something counts the reads. A low-yield run may mean the target is scarce or that the sample is mostly host DNA. And before a week of genome assembly, it pays to know how much of the data even comes from the organism you meant to assemble.

Choose Kraken 2 first when you have no hypothesis, because it is the fastest and broadest classifier in LGE. Move to EsViritu or TaxTriage when a call needs coverage evidence behind it, and to 12S matching when the question is which vertebrate species are present. [Choosing a tool](01-what-is-classification.md#choosing-a-tool) compares every classification route in LGE. Kraken 2 is Wood and colleagues 2019 and Bracken is Lu and colleagues 2017, both listed in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack).

This chapter works through the sequencing run with [accession](../../GLOSSARY.md#accession) SRR12486983, a public ID in the NCBI [Sequence Read Archive](../../GLOSSARY.md#sra) (SRA). It is the pathogen-identification example in the Kraken authors' protocol paper, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y), *Nature Protocols* 17, 2815. The reads come from the cornea, the clear front surface of the eye, of a person with herpes simplex keratitis, an eye infection caused by herpes simplex virus 1 (HSV-1). The tissue was preserved in formalin, a fixative that keeps tissue intact but damages its DNA, and sequenced on an Illumina NextSeq 550 as a [shotgun](../../GLOSSARY.md#shotgun) library, which reads whatever DNA the tissue held rather than copying one chosen target first. The study recorded HSV-1 as the organism, so you know the right answer before you start and can see plainly what each database finds, what it misses, and what else turns up.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. LGE saves every result inside the project, so with no project open **Tools > Classification > Kraken2…** shows an alert titled No Project Open and starts nothing.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries Kraken 2 and Bracken, and you need it whichever way you get the reads.

Open the Pathogen Detection demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the sequencing run `SRR12486983` as the bundle described below, so the SRA download is done. To fetch the run yourself instead, read on.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for this chapter's practice data. The fixture lists two public runs, and this chapter uses one of them, the sequencing run `SRR12486983`, which you download from the Sequence Read Archive, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The run imports as one [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, named `Imports/SRR12486983.lungfishfastq` and holding 4,819,760 [read pairs](../../GLOSSARY.md#read-pair). The run is [paired-end](../../GLOSSARY.md#paired-end), so the sequencer read each DNA [fragment](../../GLOSSARY.md#fragment) from both ends and wrote two reads for it, called [mates](../../GLOSSARY.md#mate). Kraken 2 names the two mates of a pair together, so wherever the app's labels say reads for this result, they count pairs, and this chapter writes pairs wherever it can. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The counts in this chapter came from Kraken 2 version 2.17.1, Bracken 3.1, and the Viral and Standard-16 database builds that LGE labels 20260626, which is 26 June 2026. LGE builds Bracken from the source of its release 3.1, which prints its version as 3.0.1 when asked. LGE does not ask, so its provenance record shows 3.1, and both numbers name the same program. A different version or database build can move some counts, so compare the pattern before the digits. In the example the Viral database assigns about ten times as many pairs to HSV-1 as Standard-16 does.

You can do every step of the Procedure section by clicking in the app. Sentences that start "On the command line" and the final section of that name are for terminal users, and you can skip them.

## Procedure

The example classifies the same reads twice, once against a small viral database and once against a general one.

### Download the Viral and Standard-16 databases

A Kraken 2 database decides which answers are possible at all. A database holding only viruses cannot report a bacterium, however much bacterial sequence the library holds, and reports those reads as unclassified instead.

Download the Viral database from the Databases tab of the Plugin Manager, which **Tools > Plugin Manager…** opens, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. Then download the Standard-16 database the same way. By the app's own estimate Viral is about 0.5 GB to download and to hold in memory, and Standard-16 is about 16 GB for each, so check your free disk space as well as your memory. Standard-16 is a [capped database](../../GLOSSARY.md#capped-database), the full Standard collection shrunk to fit a machine with 16 GB of memory by keeping only a sample of its minimizers. Kraken 2 loads the whole database into memory before it classifies a single read. On a Mac with less than 16 GB, use Standard-8 wherever the steps say Standard-16 and expect fewer pairs to be classified than the tables show. If you pick Standard-16 anyway, the dialog turns on **Memory mapping** for you, as Settings describes. To see how much memory your Mac has, choose **Apple menu > About This Mac**.

### Open the dialog and choose a database

1. Click the FASTQ bundle SRR12486983 in the sidebar, the list down the left of the window, under `Imports`.

2. Choose **Tools > Classification > Kraken2…**. The FASTQ/FASTA Operations dialog opens with Kraken2 selected in its tool sidebar, and the dataset line at the top names the bundle going in. Just below it, a short line names the read layout LGE found in the bundle. The bundle keeps the two mates of each pair in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, each read followed by its mate.

3. Open the **Database** picker, which lists only databases that finished downloading, each with its size on disk. Choose **Viral**. If nothing is installed, the picker is replaced by "No databases installed." and a **Download Database…** button that opens the Plugin Manager on its Databases tab.

    <!-- SHOT: kraken2-dialog -->

4. Leave **Sensitivity** on **Balanced** and leave **Advanced Settings** collapsed. The three-way control fills in two numbers inside that section for you, Confidence and Min hit groups, and Settings below explains them. The picture shows the section opened only so you can see those numbers.

    <!-- SHOT: kraken2-advanced-settings -->

If you selected several bundles, the dialog lists them under **Batch Samples**, each name followed by a short tag for its read layout, such as PE for paired-end reads or SE for single reads. LGE classifies each sample on its own and never pools reads across samples, because pooled reads would blur which organism came from which sample. The results are saved together as one batch result with a single Operations Panel row. Before **Run** turns on, LGE reads the start of each sample's files to tell pairs from single reads, several samples at a time, and the bottom of the dialog counts its progress, as in "Checking read layouts (12 of 57)…".

### Run Kraken 2 and find the result

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A single-sample row is titled "Profiling" plus the input file name, because the dialog always classifies and then profiles with Bracken. A multi-sample run is titled `Classification Batch (N samples)`. The row's time reads Elapsed while the run goes. Once it ends, the row reads Completed and its time reads Took. Expect Standard-16 to take longer than Viral.

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. For a single-sample run, its name is `kraken2-` followed by a timestamp, so a second run never overwrites the first, and the later timestamp marks the newer run. When such a run ends, LGE opens the taxonomy viewport itself and selects the new folder in the sidebar. That first view shows the Unclassified card and a working information button for the provenance popover, and a reopened result has neither, as Reading the results describes. Click the folder in the sidebar later and the viewport opens again in its reopened form. A multi-sample run goes in a folder named `kraken2-batch-` followed by a timestamp, shows its first sample in the viewport, and only refreshes the sidebar, so the new folder is not selected there.

<!-- SHOT: kraken2-taxonomy-viewport -->

Now click the reads bundle again, reopen the dialog, choose **Standard-16** instead of Viral, and click **Run**, so you have both results for Reading the results. The newer `kraken2-` folder is the Standard-16 run.

### Extract the reads of one taxon

Once you have found the taxon you care about, you usually want its reads rather than its count, to map them to a reference, assemble them, or check them with [BLAST](../../GLOSSARY.md#blast). In the cornea sample that taxon is HSV-1, which the table names by its species, *Simplexvirus humanalpha1*.

1. In the Viral result, type `humanalpha1` in the **Filter taxa…** field above the table, then click the *Simplexvirus humanalpha1* row. Selecting its wedge in the sunburst works too.

2. Click **Extract Reads…** in the action bar, the strip of buttons along the bottom of the viewport. Right-clicking the row or wedge and choosing **Extract Reads…** opens the same dialog, and so does **Selection > Table Row > Extract Reads…** once you have clicked the table. The picture shows the right-click menu on the Orthoherpesviridae row.

    <!-- SHOT: kraken2-extract-reads -->

3. The Extract Reads dialog reads `Selected: 1 row` and estimates the reads the selection holds, 886,221 for the cornea sample, on a line that ends "unique reads". Its reads are pairs, the same figure as the row's Reads column, which counts every pair assigned to that taxon or anything below it. Leave **Format** on FASTQ and **Destination** on Save as Bundle. The **Name** field arrives filled in as `kraken2_Simplexvirus_humanalpha1`.

4. Click **Create Bundle**. The button's word follows the destination, so it reads **Save**, **Copy**, or **Share** for the other three.

The new bundle appears in the project's top-level `Extractions` folder. It holds the reads assigned to the selected taxon and to every taxon beneath it, so extracting at a family row takes every genus and species in that family too. The bundle holds both mates of every pair, so for the cornea sample it held 1,772,442 reads, two for each of the 886,221 pairs. LGE adds a date, a time, and a short code to the name you left unchanged, so look for a bundle whose name starts with `kraken2_Simplexvirus_humanalpha1-`. Selecting several rows before clicking **Extract Reads…** writes their reads into one bundle.

Extract always works from the result's own folder, so a result you renamed, moved, or copied extracts where you expect, and a copied result that lacks its reads makes LGE say which ones are missing. Before it writes a read, LGE checks the read's name and length against what Kraken 2 recorded. If the bundle's reads were replaced after the run, for example by importing other reads under the same name, the extraction stops with a message rather than writing reads that do not belong to this result.

The cornea bundle is one interleaved file, so this paragraph does not apply to it. A bundle that keeps its mates in separate R1 and R2 files, or holds merged reads (overlapping mates joined into one read) and orphans (reads whose mate was removed) beside its pairs, extracts the same way. LGE reads R1 and R2 side by side, as Kraken 2 did, takes a pair when either mate was assigned to the selected taxa, and writes each pair as a read followed by its mate, with the merged reads and orphans after the pairs. Later tools recognise those pairs only when the read names show the pairing, as names ending in `/1` and `/2` do and as the dotted form `SRR123.1.1` and `SRR123.1.2` does. Mates that differ only by `_1` and `_2` are not recognised, so the new bundle holds them as single reads. If a record of R1 is not the mate of the record beside it in R2, the extraction stops with an error rather than writing mismatched pairs.

### Importing a Kraken 2 result made elsewhere

A colleague who ran Kraken 2 on another computer can send you its report, the [kreport](../../GLOSSARY.md#kreport) file, and LGE opens it in the same taxonomy viewport. Choose **File > Import Center…** (Cmd-Shift-I), click the **Classification Results** tab, and click **Import…** on the **Kraken2 Results** card, whose file hint reads ".kreport, .kreport2, .bracken". Pick one or more report files and click **Open**. No further dialog opens. The import starts at once in the background, with a row in the Operations Panel, and LGE runs the command `lungfish-cli import kraken2` for you.

Each report lands in the project as `Analyses/classification-<name>`, beside the results you ran yourself, where `<name>` is the file's name without its ending, tidied to letters, digits, hyphens, and single underscores, so `report (1).kreport` becomes `classification-report_1`. A second import of the same name adds `-2`. The Import Center copies the report alone. The imported result shows its counts and sunburst, but its per-read file is empty, so **Extract Reads…** and **Verify with BLAST…**, which read that file, have no reads to work from. The command-line import can bring the per-read file along with its `--output` flag, as [On the command line](#on-the-command-line) shows.

## Settings

### The classification dialog

**Database.** Names the reference collection every read is compared against, and so fixes which answers are possible, since a read can only be given a name the database holds. The default is the first installed database that finished downloading, an arbitrary choice, so always look at it before you run. Pick a small collection such as Viral when you already know which family you are hunting, and a Standard or PlusPF collection for an unbiased survey, PlusPF being Standard plus protozoa and fungi. On the command line this is `--db`.

**Sensitivity.** Sets the Confidence and Min hit groups values together, trading how many reads get a name against how often that name is right. The default is Balanced, confidence 0.20 with 2 hit groups, against Sensitive at 0.00 with 1 and Precise at 0.50 with 3. Move to Precise when a false positive would be costly, such as reporting a pathogen, and to Sensitive when you are hunting something rare and will check every hit by hand. On the command line this is `--preset`.

**Confidence.** Sets the fraction of a read's k-mers that must point at a taxon, meaning that taxon or anything beneath it, before Kraken 2 commits to that name, so 0.20 means at least a fifth. The default is 0.20, set by Balanced, and the slider and its typed number field run from 0.00 to 1.00 in steps of 0.05. Raise it when the report is full of implausible species, and lower it when too many reads come back unclassified, remembering that a read failing at one taxon moves up to the group above it, which counts the k-mers of everything beneath it and so may pass, and becomes unclassified only when no group up to the root passes. On the command line this is `--confidence`.

**Min hit groups.** Sets how many hit groups a read must have before Kraken 2 names it at all, where a hit group is a run of overlapping k-mers that share one minimizer found in the database, so two hit groups mean two separate places on the read matched. The default is 2, on the reasoning that two independent chance matches are much rarer than one, and the stepper accepts 1 to 10. Raise it when short repeated sequence produces calls you do not believe, and lower it for very short reads that cannot hold two separate matches. On the command line this is `--min-hit-groups`.

**Threads.** Sets how many processor cores Kraken 2 uses at once. The default is 4, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Memory mapping.** Reads the database from disk in pieces instead of loading it whole into memory, so the database no longer has to fit in RAM and the run is much slower. It is off by default, which is right for every database that fits your memory. The dialog ticks it for you when you pick a database larger than your Mac's memory, with a banner naming the gigabytes required and the gigabytes you have. On the command line this is `--memory-mapping`.

**Extra arguments.** Passes text straight to Kraken 2 without LGE checking what it means, though an unclosed quote turns **Run** off, and the footer of the dialog then reads "Complete the classifier settings to continue." The default is empty, with the grey placeholder Kraken2 arguments, which is right for almost every run. Use it only for a Kraken 2 option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

### The taxonomy viewport

These controls change what you are looking at, not what was computed.

**Filter taxa….** Shows only the rows whose sample, name, rank, read counts, or percentage contain what you type, together with each match's parent taxa and everything beneath it, and dims the sunburst wedges that no longer match. It is empty by default, showing everything. Use it whenever you are hunting one organism in a report of thousands of rows. This setting has no command-line flag.

**Bracken.** Is a column rather than a control, holding the species counts Bracken re-estimated. It appears on its own whenever the result carries Bracken numbers, which a dialog-started run does unless its Bracken profile could not be made, and stays hidden on a result made without Bracken. There is nothing to set, so read it when it is there. This setting has no command-line flag.

**Select All.** Ticks or unticks every sample visible in the Sample Filter list, in the Samples & Metadata section of the [Inspector](../../GLOSSARY.md#inspector), the right-hand pane that shows details of whatever is selected. It starts ticked, because every sample is shown at first. Use it to clear the list and then tick the few samples you want, rather than unticking twenty by hand. This setting has no command-line flag.

**Filter….** Narrows the sample picker's list to names containing what you type, changing which samples you can tick rather than which are ticked. It is empty by default. Use it on a many-sample run to reach one plate or one collection date. This setting has no command-line flag.

**Column header filter.** Restricts one column to rows matching a value or numeric range you set from the menu that opens when you click that column's header, and several column filters apply together. No column carries a filter at first. Use it to hold the table to species rank, or to rows above a read count you consider worth reading. This setting has no command-line flag.

### The Extract Reads dialog

**Format.** Chooses whether the extracted reads keep their per-base quality scores, as FASTQ, or come out as sequence only, as FASTA. The default is FASTQ, which loses nothing. Choose FASTA when the next tool wants sequence alone, such as a BLAST submission. On the command line this is `--read-format`.

**Include unmapped mates of mapped pairs.** Also pulls out the partner of any pair where only one mate aligned to the selected reference, with the dialog showing how many reads that adds. It is off by default and hidden on a Kraken 2 result, because Kraken 2 produces no alignment for it to work from, so you can skip this entry here. Turn it on for the classifiers that align reads, EsViritu, TaxTriage, NAO-MGS, and NVD, when you plan to assemble or map the extracted reads. On the command line this is `--include-unmapped-mates`.

**Destination.** Chooses where the reads go, offering Save as Bundle, Save to File…, Copy to Clipboard, and Share…. The default is Save as Bundle, which puts them in your project as a new bundle you can run other tools on. Choose Save to File when the reads are going to another program, and Copy to Clipboard only for a handful of reads, since it is disabled when the dialog's estimate is above 10,000 pairs and its tooltip then asks you to pick another destination. On the command line this is `--output`.

**Name.** Names the bundle or file that gets written, and appears only for Save as Bundle and Save to File. It arrives filled in as `kraken2_` plus the taxon name, LGE adds a timestamp to the bundle name if you leave it unchanged, and it cannot be left blank. Change it when the suggested name will not tell you what the reads are six months from now. On the command line this is `--bundle-name`.

## Reading the results

The taxonomy viewport stacks five parts. Along the top, a row of summary cards reports Total Reads, Classified, Unclassified, Species, Shannon H′, and Dominant when the run has just finished. When you reopen the result from the sidebar, the cards read Batch, Samples, Taxa, and Database instead. A run on a bundle whose mates sit in separate R1 and R2 files, or whose pairs share the bundle with merged or single reads, counts [fragments](../../GLOSSARY.md#fragment), with a pair counting once. Its first card then reads Fragments, and a Read Pairing card gives a line such as "100 fragments, 23 from read pairs and 77 from merged or single reads". An older result made from such a bundle before LGE classified pairs as pairs counted each mate as its own read, and a Counting card says so. [Shannon H′](../../GLOSSARY.md#shannon-diversity) is the Shannon diversity index, one number for how evenly reads spread across species, which is 0 when a single species holds them all and grows as the mix evens out. Dominant names the species with the most reads. For the cornea sample's Viral run, Dominant names *Simplexvirus humanalpha1* and Shannon H′ reads 0.011, close to 0, the value for a single species. Below the cards runs the breadcrumb bar, naming the part of the tree the sunburst is centred on. The middle holds the sunburst on the left and the table on the right. The action bar runs along the bottom.

The sunburst draws the root at the centre and one ring per level of the tree outward, so a group that sits between the usual ranks, such as the realm Duplodnaviria between the root and the kingdoms, takes a ring of its own. Each wedge is sized by its share of the classified pairs. The centre shows a separate percentage and says what it is a percentage of. With nothing zoomed it reads "of all reads" and gives the classified share of the sample, and once you zoom in it reads "of classified" and gives that taxon's share of the classified pairs. Taxa too small to draw are pooled into a paler wedge in their parent's colour, and hovering it names how many taxa and reads it holds. Hovering any other wedge opens a small card with the taxon's name and rank, a Reads line, a Clade reads line, its share of all reads and of classified reads, and how many child taxa it has.

The table lists the same taxa as rows under the columns Sample, Taxon Name, Rank, Reads, Direct, Bracken, and **%**. Sample names which input a row came from, SRR12486983 here, and matters only on a multi-sample run. Rank is the taxon's level, such as family, genus, or species. A count beside the **Filter taxa…** field reports how many taxa the table holds while the field is empty.

Two columns are easy to confuse, and everything else depends on telling them apart. **Reads** is the [clade count](../../GLOSSARY.md#clade-count), every read assigned to that taxon or to anything below it, a [clade](../../GLOSSARY.md#clade) being a taxon with all its descendants. **Direct** counts only the reads assigned to that exact taxon and no lower. A family row with a large Reads figure and a Direct figure near zero means the classifier carried almost every read further down, which is healthy. A family row whose Direct figure is a large share of its Reads means the classifier stopped there, either because the reads cannot be resolved further or because the database holds nothing more specific. Hover cards name these two counts differently, since a card's Reads line is the table's Direct figure and its Clade reads line is the table's Reads figure.

<!-- ILLUSTRATION: clade-vs-direct-counts -->

The **%** column is a [relative abundance](../../GLOSSARY.md#relative-abundance) whose denominator is every read pair in the sample, unclassified pairs included, so it gives the Reads figure as a share of the whole run. Other result views divide by other totals, as [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) lists.

In a result of several samples, each row's **%** divides by the reads of that row's own sample, unclassified included, so a row reads the same as it would in that sample's result alone. The sunburst and the line in the action bar use the same denominator, and the line names the sample. A sample with no saved total of its own, which happens only in a result made by hand or rebuilt part way, shows its reads with no percentage in the action bar line, and its hover card leaves out the share lines rather than show a share of an unknown total. The percent columns of an exported table, and the table's **%** column when you select several samples together, still read 0 for such a sample.

The first figures to read are the totals. Of the 4,819,760 pairs, the Viral database classified 893,706 (18.54%), every one of them under Viruses, and left 3,926,054 (81.46%) [unclassified](../../GLOSSARY.md#unclassified-reads). Unclassified means a read found no match that the database and the confidence threshold would both accept. A database of viruses can only name viruses, so every human or bacterial read in the tissue lands there too, and a large unclassified share is expected from this database.

Here are five of the rows on the path from Viruses to HSV-1 in the Viral result, running from the family through the subfamily, genus, and species to the named virus, with the ranks between Viruses and the family left out. The Reads figures count pairs, and the **%** figures are shares of all 4,819,760 pairs.

| Taxon | Reads | % |
|---|---|---|
| Orthoherpesviridae | 893,154 | 18.53 |
| Alphaherpesvirinae | 893,152 | 18.53 |
| Simplexvirus | 893,039 | 18.53 |
| *Simplexvirus humanalpha1* | 886,221 | 18.39 |
| Human alphaherpesvirus 1 | 886,221 | 18.39 |

*Simplexvirus humanalpha1* is the formal species name the virus taxonomy now gives HSV-1, and the familiar name, Human alphaherpesvirus 1, sits one level below it with [taxonomy ID](../../GLOSSARY.md#taxonomy-id) 10298. Viral taxonomy routinely names a species that holds familiar viruses as members, so a familiar name below an unfamiliar one is the convention, not a mistake.

Read the table downward. Nearly every classified read in the sample sits inside the herpesvirus family, and the clade count barely drops from the family to the species, which is what one dominant virus looks like. The Direct column shows where the reads stopped. At the genus row *Simplexvirus*, Direct is 6,789. Those pairs matched several simplexviruses equally, such as HSV-1 and its close relatives, so their lowest common ancestor was the genus. The genus total of 893,039 is those 6,789, the 886,221 HSV-1 pairs, and 29 pairs on two relatives described below. At the species row Direct is 0, and at Human alphaherpesvirus 1 it is 886,221. The database files HSV-1 genomes under that name, one level below the species, so any read specific to HSV-1 lands there rather than on the species itself. The report lists that level as a subspecies, but both rows are the same virus. A small Direct figure at a broad rank is ordinary, and only its size relative to the clade count matters.

The Bracken column fills in on species rows. Bracken works at the species rank, so it hands the 6,789 genus-level pairs down to the species they most likely came from. The Bracken figure for *Simplexvirus humanalpha1* is 893,009, higher than its Reads figure of 886,221 by almost exactly those 6,789 pairs, and 99.98% of all the pairs Bracken assigned to a species. Bracken's figures appear on species rows only, so the Human alphaherpesvirus 1 row has none. On a sample of several species the Bracken figure is the better estimate of each species' share, so quote it as Bracken's estimate, and quote Reads for what Kraken 2 itself placed there.

Bracken estimates only species whose clade count reaches its threshold of 10, counted in the same units as the Reads column. When no species reaches it, as in a sample where almost nothing was classified, LGE does not run Bracken at all. The run's Operations Panel row then reads Completed with Warnings, the warning says in plain words that no species reached the threshold and how many reads the largest one had, and the result opens as usual with no Bracken column.

### Small hits beside a big one

Kraken 2's report lists a few small rows beside HSV-1, which you see in the table once you clear the **Filter taxa…** field and choose **Expand All** from a row's right-click menu. *Simplexvirus paninealpha3*, the chimpanzee herpesvirus, holds 28 pairs. *Macacine alphaherpesvirus 1*, the B virus of macaques, holds 1 pair. Outside the herpesviruses, 402 pairs fall under Uroviricota, a group of phages, the viruses that infect bacteria, 66 of them in Pahexavirus, a genus of phages that infect the skin bacterium *Cutibacterium acnes*.

The two herpesvirus rows are the kind of small side effect a large signal produces, and they do not by themselves point to a second infection. Pairs from stretches that HSV-1 and its relatives share exactly go to the genus, as the 6,789 did. The chimpanzee virus is a close relative of HSV-1, and with 886,221 HSV-1 pairs in the sample, a few dozen pairs from places where this patient's virus differs from the HSV-1 reference are expected to match the relative slightly better. One pair against B virus falls under the ten-pair rule of thumb in [What good looks like](#what-good-looks-like), so treat it as noise unless BLAST says otherwise. The phage reads may be real, since the bacterium they infect is a common skin bacterium that [the Standard-16 run](#the-same-reads-a-different-database) finds in this sample, but the report cannot prove it. Check any small hit that matters with [BLAST Verification](06-blast-verification.md).

### Moving around the tree

A single click on a wedge selects it and selects the same row in the table, and the reverse works too. A double-click re-centres the sunburst on that wedge, so double-clicking **Orthoherpesviridae** redraws the chart with Orthoherpesviridae in the middle, its label naming Orthoherpesviridae with about 893 thousand reads, and its children as the first ring out. The breadcrumb bar then shows the path back to the root, Root > Viruses > Duplodnaviria > Heunggongvirae > Peploviricota > Herviviricetes > Herpesvirales > Orthoherpesviridae. The names between Viruses and the family are the upper ranks of virus taxonomy, from realm down to order. Clicking an earlier segment returns you there. Clicking the centre circle, or pressing Escape, zooms out one level, and Cmd-0 jumps back to the root. The shortcuts go to the chart, so click it once before you use them.

<!-- SHOT: kraken2-drilldown-orthoherpesviridae -->

Right-clicking a wedge or a table row offers **Extract Reads…**, **Verify with BLAST…**, **Open Taxonomy on NCBI**, **Open GenBank Record**, **Search PubMed**, and **Copy Name**. A wedge adds **Copy Taxonomy Path**, a **Zoom to** item named for that taxon, such as **Zoom to Orthoherpesviridae**, **Zoom Out to Root**, and **Open Genome Assemblies on NCBI**. A row adds **Expand**, **Expand All Below**, **Collapse**, **Expand All**, and **Collapse All**. **Open Taxonomy on NCBI**, **Open GenBank Record**, and **Search PubMed** open, in your web browser, the taxon's NCBI Taxonomy page, a GenBank search for its sequences, and a PubMed search for its name. Right-clicking empty chart space offers **Copy Chart as PNG**, which puts an image of the current sunburst on the clipboard.

### The action bar and the provenance popover

The viewers of Kraken 2, EsViritu, TaxTriage, NAO-MGS, and NVD results share one action bar with the same words, so what you learn here carries over to each of them, and the other classification chapters point back to this section. A viewer may add buttons of its own after the shared ones. On a Kraken 2 result the bar carries, from the left, these controls:

- **Verify with BLAST…** sends a sample of the selected taxon's reads to NCBI BLAST to check the call, as [BLAST Verification](06-blast-verification.md) explains. It needs exactly one row selected.
- **Export** offers **Export as CSV…**, **Export as TSV…**, **Copy Summary**, and **Show Provenance…**.
- **Extract Reads…** opens the Extract Reads dialog for the selection, as step 2 of the extraction showed.
- **BLAST Results** shows or hides the results of BLAST searches below the table.
- **Collections** shows or hides the taxa collections that [Collections](#collections) below covers.

The last two open one drawer that slides up from the bottom of the viewport, on its Collections tab or its BLAST Results tab. A greyed button says why in its tooltip. With no row selected, for example, the tooltip of **Extract Reads…** begins "Select one or more rows to extract their reads." and the tooltip of **Verify with BLAST…** begins "Select a row to verify it with BLAST."

A file export runs `lungfish-cli kraken2 export table` behind an Operations Panel row and writes the columns Name, Rank, Reads (Clade), Reads (Direct), Clade %, and Direct %, plus any sample metadata columns the table shows, one row per taxon in tree order and then one row for the unclassified reads. Clade % and Direct % divide by all the reads of the row's sample, unclassified included. With several samples shown, each sample's block opens with a row of its own and ends with its own unclassified row, so each block reads as that sample's table.

A line of text after the buttons describes the selection. With nothing selected it reads "Select a taxon to view details". With one taxon selected it gives the taxon's name, its clade count, and its share of all reads, and in a result of several samples it also names the sample. Right after a run, the information button at the right end opens the Classification Provenance popover, which lists the Kraken 2 version, the database and its folder on disk, the Confidence and Hit Groups values, the thread count, whether memory mapping was on, the runtime, the input files, a Bracken row when Bracken ran, and a short run ID. That popover is what you copy into a methods section. On a result reopened from the sidebar the button does nothing, so read the Operation Details in the Summary tab of the Inspector instead, which list the database with its build, the Kraken 2 and Bracken versions, the Confidence and Min Hit Groups values, the thread count, and the runtime.

The row commands are on the menu bar too, for working from the keyboard. Click the table once so it has keyboard focus, then open **Selection > Table Row**. On a Kraken 2 table six of its items act on the selected row, **Extract Reads…**, **Verify with BLAST…**, **Copy Name**, **Open Taxonomy on NCBI**, **Open GenBank Record**, and **Search PubMed**, and the others stay greyed here. [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) describes the Selection menu as a whole.

### Collections

A collection is a named set of taxa that LGE extracts together, each taxon to its own FASTQ file, so a panel of organisms you check in every sample takes one click rather than one extraction per taxon. Click **Collections** in the action bar to open the drawer on its Collections tab. A **Filter collections...** field and an **All**, **Built-in**, **App**, and **Project** switch sit at the top, and each collection row gives its name and how many taxa it holds. LGE offers no way to make a collection of your own, so only built-in collections exist and the **App** and **Project** choices stay empty.

LGE ships eight built-in collections, among them Respiratory Viruses, AMR Organisms (ESKAPE), and Fungal Pathogens. Open one to see its taxa. A taxon the result detected carries a green dot whose tooltip gives its read count, and a taxon with no reads is dimmed and struck through. Most taxa in a built-in collection are marked "+children", meaning reads assigned below them are included. Each taxon has a tick box, and every box starts ticked.

Click **Extract** on a collection row to write one FASTQ file for each ticked taxon that has reads, compressed with gzip to save space and named for the taxon and its taxonomy ID, into a folder named `extracted-` plus the collection's identifier, inside the result folder. To find that folder, right-click the result in the sidebar and choose **Show in Finder**, which selects the result's folder in a Finder window, and then open the result's folder to find the `extracted-` folder inside it. Each file takes the taxon's reads from every read file the classification read, with each pair kept together. Untick a taxon to leave it out. **Extract** stays greyed until at least one taxon is ticked, and when none of the ticked taxa has reads in the sample, an alert titled No reads to extract says so and nothing is written.

Extract works the same on a result you reopen from the sidebar, and it takes the reads of the sample the table shows. In a result of several samples, tick one sample in the Inspector's Sample Filter list first, because one folder that mixed samples would lose track of which reads came from where. With several samples shown, an alert titled Could not extract reads asks you to choose one. The extraction runs as `lungfish-cli extract taxa-collection` behind an Operations Panel row named Extract plus the collection's name.

### The same reads, a different database

Now open the Standard-16 result and read the same rows. This is the comparison the chapter exists for.

| Measure | Viral | Standard-16 |
|---|---|---|
| Pairs classified | 893,706 (18.54%) | 343,324 (7.12%) |
| Unclassified | 3,926,054 (81.46%) | 4,476,436 (92.88%) |
| All viruses | 893,706 (18.54%) | 104,172 (2.16%) |
| Human alphaherpesvirus 1 | 886,221 (18.39%) | 89,294 (1.85%) |
| Bacteria | none possible | 219,636 (4.56%) |
| *Homo sapiens* | none possible | 13,252 (0.27%) |

The same reads went in. The Viral database named 886,221 pairs as HSV-1, and Standard-16 named 89,294, about a tenth as many. Nothing about the sample changed, and neither database is broken. Standard-16 is a capped database, squeezed from the full Standard collection of about 67 GB, and what survives is spread thinly across archaea, bacteria, viruses, plasmids, the human genome, and cloning-vector sequence. The Viral collection spends all its space on viruses, so it keeps far more HSV-1 detail. Standard-16 still found the right virus, but it recognised only a small share of that virus's reads. The classified pairs the table leaves out stopped at the root of the tree or at cellular organisms, or fell in small groups such as Archaea.

Neither 18.39% nor 1.85% is the true share of HSV-1 in the tissue. Each counts only the pairs a database could recognise, measured against all 4,819,760 pairs, so each is a lower limit and the true share is at least that high. The Viral figure is the closer one, because the Viral database holds far more HSV-1 sequence.

Standard-16 also answered questions the Viral database cannot ask. It placed 219,636 pairs under Bacteria. The table below lists the largest bacterial species.

| Species | Pairs |
|---|---|
| *Kocuria rhizophila* | 7,761 |
| *Cutibacterium acnes* | 2,282 |
| *Kocuria varians* | 1,571 |
| *Bradyrhizobium* sp. WCU1 | 1,416 |
| *Cellulosimicrobium cellulans* | 331 |

Across all 549 bacterial species in the report, the species rows hold only 16,365 pairs, so most bacterial reads stopped at ranks above species, where the minimizers left after capping were not specific enough to go further. *Cutibacterium acnes* fits the Cutibacterium phages the Viral result found. Whether these bacteria lived on the eye, came from the skin around it, or came from the laboratory, the report cannot say, and [What good looks like](#what-good-looks-like) explains how to treat such hits.

Note also what barely appeared. Standard-16 contains the human genome and the tissue came from a person, yet only 13,252 pairs, 0.27%, were called *Homo sapiens*. One possible explanation is that most human reads were removed before the run was uploaded to the archive, the step called [host depletion](../../GLOSSARY.md#host-depletion), but this chapter cannot confirm it.

The lesson reaches past this sample. Capping thins out minimizers across the whole collection, so a capped database recognises fewer reads of every organism, including the one that supplied most of the tube. When screening an unknown sample, run a broad database to learn roughly what kinds of organism you face, then a specialist database for the group you care about to get the detail. Running only the broad one would have reported HSV-1 at under 2% of the sample, and running only the viral one would have missed the bacteria.

## What good looks like

The taxonomy viewport answers only the first question of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist), how many reads support each name. It shows nothing about where on a genome the reads fell, how many are copies of one fragment, or what a control held, which is why a Kraken 2 result is a survey and the chapters after this one add that evidence.

Read the unclassified share first, on the Unclassified card right after the run, before you look at any organism. A reopened result does not show that card, so note the figure when the run finishes, or take it from the sunburst, whose centre reads the classified share "of all reads" with nothing zoomed, and subtract that from 100 percent. It tells you how much of the sample the report speaks for, and you read it against what the database holds. As a rule of thumb, on a broad database such as Standard-16, under about 20% means the database recognised your sample and the taxa are worth reading. Between 20% and half, read the taxa with care, since a large part of the sample is unaccounted for. Over about half means the database did not recognise most of the sample, and every percentage you read describes only the small fraction it happened to match. On a specialist database such as Viral, a large unclassified share is expected, because every read from outside that group lands there, so read the classified reads instead. The two runs in this chapter both leave most pairs unclassified. The Viral result still answers its narrow question plainly. The Standard-16 result, at 92.88% unclassified, speaks for only a small part of the sample, so treat its percentages as a partial view rather than a census.

The extreme case is a database that matches nothing at all. That is what you hope to see for a [negative control](../../GLOSSARY.md#negative-control), a blank carried through the laboratory beside the real samples to show what the reagents add. The run still completes and opens with every read unclassified. Bracken has nothing to estimate, so the Operations Panel row reads Completed with Warnings and the result has no Bracken column. The sunburst reads "No classification data", the Unclassified card reads 100.0%, and the table lists no taxa. An exported table still ends with one row for the unclassified reads. On a real sample, treat such a result as the database being wrong for the sample and rerun with one that covers what you are looking for.

Then check whether the dominant signal is the organism you expected. Click the Reads column header and choose **Sort Descending** from the menu that opens, and look at family or genus rather than species, since that is the level a classifier reaches reliably. One taxon dwarfing everything else, as Orthoherpesviridae does in the Viral result, means the sample probably contains it. Several taxa of comparable size mean a mixed sample, and no clear peak usually means the wrong database.

Then read the long tail, the many rows with small counts far down the table once you sort by Reads, against a rule you set before you looked, such as "check any taxon above ten pairs with BLAST". Writing the rule first stops you raising the bar to dismiss an inconvenient hit or lowering it to keep an exciting one. A low-abundance hit is a real minor component, a [false positive](../../GLOSSARY.md#false-positive) from k-mers that related or unrelated organisms share, or [contamination](../../GLOSSARY.md#contamination) from the laboratory or from stray sequence inside the reference database, and the report cannot tell you which. [Why a classifier reports things that are not there](01-what-is-classification.md#why-a-classifier-reports-things-that-are-not-there) sets out the three sources. Under about ten pairs is usually noise, whether the taxon is a relative of the main organism, like the single B virus pair here, or unrelated to it. Between that and a few thousand pairs, extract the taxon's reads and search them against NCBI, as [BLAST Verification](06-blast-verification.md) explains. Above a few thousand pairs the taxon is plainly present in the reads, and BLAST is still worth running to confirm which organism it is. These cut-offs are untested rules of thumb, and a run many times larger than this one's 4,819,760 pairs will show more chance hits at any fixed count, so raise them as your run grows.

Finally, remember what the [Confidence](../../GLOSSARY.md#confidence-kraken-2) threshold measures. It asks what fraction of a read's k-mers agree with the assigned taxon, so it measures fit to one database entry and nothing more. It says nothing about whether that entry was the right one, or how many other sequences would have fitted as well. A read that agrees perfectly with a short, atypical, or mislabelled entry is still a poor match to anything real. Kraken 2 is a screening step, so verify any hit that matters. For a methods section, the run's provenance record carries the same facts as the popover, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read the record.

## On the command line

This section is optional, so skip it if you work in the app. The commands repeat the procedure for people who run LGE in Terminal, the macOS app where you paste a command and press Return, and [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains the `PROJECT=` line and the backslashes at the ends of lines. Every flag of `kraken2 classify` is listed in [Classification](../appendices/cli-reference.md#classification) in the CLI Reference, and the import in [`import kraken2`](../appendices/cli-reference.md#import-kraken2). A command copied from the Operations panel uses `kraken2 classify` with `--project`, so running it makes a new result folder under `Analyses`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"

# Classify against Viral, then Standard-16, running Bracken as the dialog does.
lungfish-cli kraken2 classify "$PROJECT/Imports/SRR12486983.lungfishfastq" \
  --db Viral --profile --output-dir "$PROJECT/Analyses/kraken2-viral"
lungfish-cli kraken2 classify "$PROJECT/Imports/SRR12486983.lungfishfastq" \
  --db Standard-16 --profile --output-dir "$PROJECT/Analyses/kraken2-standard16"

# Extract the HSV-1 reads (NCBI taxonomy ID 10298) and everything below it.
lungfish-cli extract reads --by-classifier --tool kraken2 \
  --result "$PROJECT/Analyses/kraken2-viral" --taxon 10298 \
  --output hsv-1.fastq --bundle-name "HSV-1 reads"

# Write the Viral result's taxonomy table, as Export > Export as TSV… does.
lungfish-cli kraken2 export table "$PROJECT/Analyses/kraken2-viral" \
  --output-format tsv --output viral-taxa.tsv

# Import a colleague's report together with its per-read output file.
lungfish-cli import kraken2 "/path/to/sample.kreport" \
  --output "/path/to/sample.kraken" --output-dir "$PROJECT/Analyses"
```

The extraction command writes a bundle, because `--bundle-name` implies one. `--taxon` takes the numeric taxonomy ID rather than a name, and **Open Taxonomy on NCBI** on a row's right-click menu opens the taxon's NCBI page, which shows it. Taxonomy ID 10298 is the Human alphaherpesvirus 1 row, which holds every read of its species in this result. By default `--taxon` takes the taxon and everything below it, as the dialog does, and `--taxon-scope exact` takes only the reads classified to the taxon itself. The `extract reads` command has its own `--read-format` flag, which there chooses FASTQ or FASTA. **Copy CLI Command** on the Operations Panel row of any extraction copies its command. The export command refuses to replace an existing file unless you add `--force`. In the import command, the two `/path/to/` paths stand for wherever the colleague's report and per-read file sit on your Mac.

The dialog always runs Bracken and the command line does not, so a command without `--profile` gives a classification with no Bracken column. With `--profile`, a Bracken profile that cannot be made leaves the classification complete, with a warning, and the command still finishes without an error. Given a bundle, the default `--read-format auto` classifies its mates as pairs, as the dialog does, and runs any merged or single reads beside them in the same run. Given the two downloaded files instead, such as `SRR12486983_1.fastq.gz` and `SRR12486983_2.fastq.gz`, add `--paired`, and add `--unpaired` once for each file of merged or single reads that belongs with them. Each command above writes to a folder of its own, as the dialog does with every run, because a rerun into a used folder removes the earlier report, per-read output and Bracken profile before Kraken 2 starts. The files may mix gzip-compressed (`.gz`) and plain text. Kraken 2 opens every file the way it opens the first, so LGE gives it a copy of each file in the other form, written in the first file's form for the run and kept in the hidden `.lungfish-classify-inputs` folder of the result, and the provenance records that copy as the step `Lungfish Classification Input Compression Staging`.

## Next

Continue to [Running EsViritu](03-running-esviritu.md), which surveys a SARS-CoV-2 run with Kraken 2 and then asks the question Kraken 2 cannot, how much of the virus's genome the reads covered. To check a Kraken 2 hit against NCBI before you believe it, go to [BLAST Verification](06-blast-verification.md), which verifies this chapter's HSV-1 call.
