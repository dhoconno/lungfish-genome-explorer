---
title: Running Kraken 2
chapter_id: 06-classification/02-running-kraken2
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 35
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
    caption: "The dialog's Advanced Settings section expanded, showing the Confidence slider, the Min hit groups stepper, the Threads stepper, the Memory mapping checkbox, and the Extra arguments field."
  - id: kraken2-taxonomy-viewport
    caption: "The taxonomy viewport after classifying SRR12486983 against the Viral database, with the summary cards along the top, the sunburst on the left, the per-taxon table on the right with its Filter taxa… field and taxa count, and the action bar along the bottom with Verify with BLAST…, Export, Extract Reads…, BLAST Results, and Collections."
  - id: kraken2-drilldown-orthoherpesviridae
    caption: "The sunburst re-centered on Orthoherpesviridae after a double-click, with the breadcrumb bar showing the path back to the root."
  - id: kraken2-extract-reads
    caption: "The right-click menu on the Orthoherpesviridae row, listing Extract Reads… above the Expand and Collapse items, then Verify with BLAST…, Open Taxonomy on NCBI, Open GenBank Record, Search PubMed, and Copy Name."
illustrations:
  - id: clade-vs-direct-counts
    brief: "A small vertical tree for the cornea sample's Viral result, one node per rank from the family Orthoherpesviridae through the subfamily Alphaherpesvirinae, the genus Simplexvirus, and the species Simplexvirus humanalpha1, down to Human alphaherpesvirus 1, with a short side branch from the genus to Simplexvirus paninealpha3. Beside each node print two numbers, Reads (the clade count) and Direct (the reads assigned to that node only). Use the chapter's figures, Orthoherpesviridae 893,154, Alphaherpesvirinae 893,152, Simplexvirus 893,039 with Direct 6,789, Simplexvirus humanalpha1 886,221 with Direct 0, Human alphaherpesvirus 1 886,221 with Direct 886,221, and Simplexvirus paninealpha3 28. Show the clade count as a bar that shrinks only slightly down the tree and the Direct count as a small filled segment, so the reader sees that Reads sums everything below and Direct counts only the reads that stopped at that node. Deep Ink text, Creamsicle bars, Cream background."
glossary_refs: [accession, abundance, blast, bracken, confidence-kraken-2, false-positive, contamination, fragment, mate, relative-abundance, unclassified-reads, bundle, capped-database, checksum, clade, clade-count, fastq, host-depletion, inspector, interleaved-fastq, k-mer, kraken2, kreport, lowest-common-ancestor, metagenomics, minimizer, negative-control, operations-panel, paired-end, plugin-pack, provenance, read, read-classification, shannon-diversity, shotgun, sra, taxon, taxonomic-rank, taxonomy-id, library, read-pair]
features_refs: [classify.kraken2, viewport.taxonomy-browser, classify.extract-reads, results.table-row-commands, classify.blast-verify]
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: true
lead_approved: true
---

## What it is

[Kraken 2](../../GLOSSARY.md#kraken2) compares sequencing reads with a database of known sequences. A [read](../../GLOSSARY.md#read) is a short DNA sequence recorded by a sequencer. A [FASTQ](../../GLOSSARY.md#fastq) file stores reads and a quality score for each base. The score estimates how reliably the sequencer called that base. When matches support an assignment, Kraken 2 reports a [taxon](../../GLOSSARY.md#taxon), a named group such as *Homo sapiens*, *Macaca mulatta*, or the herpesvirus family *Orthoherpesviridae*. These groups sit at different [ranks](../../GLOSSARY.md#taxonomic-rank), or levels in the tree, such as family, genus, and species.

Kraken 2 looks up short stretches of sequence. An alignment lines up sequences and scores them base by base. Looking up a short sequence takes less time than aligning a whole read. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases, so `ACGTA` holds three 3-mers, `ACG`, `CGT`, and `GTA`. Kraken 2's default k is 35, so a 76-base read, the longest in this example, holds 42 k-mers. A [minimizer](../../GLOSSARY.md#minimizer) is the shorter stretch Kraken 2 uses to look up a k-mer. By default it chooses the 31-base stretch that comes first in a fixed sort order. Neighboring k-mers often share a minimizer, so one database entry can serve several lookups.

A minimizer shared by relatives is filed under their [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor), the smallest group containing them all. For example, a minimizer shared by human and macaque goes under Catarrhini, the group of Old World monkeys and apes, if it has no matches outside that group. A hit is a k-mer whose minimizer is in the database. Kraken 2 tallies hits along paths from the root, the tree's top, to each taxon. When the highest-scoring paths tie, Kraken 2 reports their lowest common ancestor. The **Confidence** threshold, the fraction of a read's k-mers that must support a taxon, can move an assignment farther up the tree. The report can therefore show counts at several ranks. See [What Is Read Classification](01-what-is-classification.md#what-it-is) for more on how classifiers handle shared sequence.

Lungfish Genome Explorer (LGE) labels the tool **Kraken2** in its menus. LGE runs Kraken 2 first and adds species estimates from [Bracken](../../GLOSSARY.md#bracken) when the classification supports them. Bracken uses a table built from the database for one read length that records where Kraken 2 places reads from each genome. It uses that table and each species' own count to share out reads that Kraken 2 left above species. Bracken estimates counts across many reads, while Kraken 2 makes the individual assignments. The result opens in the taxonomy viewport, with a table of taxa beside a sunburst chart that draws the tree as wedges in rings.

## Why you would do this

Use Kraken 2 for a first look at what a [sequencing library](../../GLOSSARY.md#library) contains. A library is the prepared mix of DNA pieces loaded onto the sequencer. In a clinical swab, for example, most reads may come from the host, the person or animal sampled. A first survey can help you look for a pathogen among the rest. If a run yields few reads from your target, check how much of the library the classifier assigns to the host. A survey can also flag a possibly mislabeled tube or cross-contaminated plate. Before starting a genome assembly, use the counts to see how much sequence matches the target organism. Genome assembly joins reads into longer sequences.

The database you choose shapes what the report can tell you. See [Choosing a tool](01-what-is-classification.md#choosing-a-tool) for the other classification options in LGE. The [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack) lists the papers for Kraken 2 by Wood and colleagues 2019 and Bracken by Lu and colleagues 2017.

This chapter uses accession SRR12486983 from the Sequence Read Archive (SRA) at the National Center for Biotechnology Information (NCBI), the American public repository for sequence data. An [accession](../../GLOSSARY.md#accession) is a public record ID. The [SRA](../../GLOSSARY.md#sra) is an archive of sequencing data. The reads come from the cornea, the clear front surface of the eye, of a person with herpes simplex keratitis, an eye infection caused by herpes simplex virus 1 (HSV-1). The tissue was preserved in formalin, a fixative that can damage DNA, and sequenced on an Illumina NextSeq 550. In [shotgun sequencing](../../GLOSSARY.md#shotgun), the sequencer reads DNA from across the sample without first copying a chosen target.

The study reported HSV-1, so use that finding to check whether each database reports the expected virus. The sample is the pathogen-identification example in Lu et al. 2022, *Nature Protocols* 17, 2815. See [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y) for the study.

## Before you start

Open a project so LGE has somewhere to save the result. With no project open, **Tools > Classification > Kraken2…** shows the alert No Project Open. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a group of tools LGE installs on request. This pack supplies Kraken 2 and Bracken. Use the steps in [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) to install it before opening the classifier.

Open the Pathogen Detection demo project with **Help > Demo Projects…** to use its copy of `SRR12486983`. See [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) for help opening it. If you are preparing your own project, fetch `SRR12486983` using [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) as your guide. The [kraken-protocol-cornea fixture](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea), the manual's practice data for this chapter, lists two public runs and gives the source and terms of use in its README. See [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) for how fixtures are used.

The run comes as `Imports/SRR12486983.lungfishfastq`, a [bundle](../../GLOSSARY.md#bundle) that LGE treats as one item. It holds 4,819,760 [read pairs](../../GLOSSARY.md#read-pair), with two reads from each sequenced DNA fragment. In [paired-end](../../GLOSSARY.md#paired-end) sequencing, the sequencer reads a piece of DNA called a [fragment](../../GLOSSARY.md#fragment) from both ends. The two reads in the pair are [mates](../../GLOSSARY.md#mate). Kraken 2 names both mates together, so the app's "reads" labels for this result count pairs.

To reproduce the counts, compare tool versions and database builds. This example used Kraken 2 version 2.17.1, Bracken 3.1, and Viral and Standard-16 builds labeled 20260626, which is 26 June 2026. Bracken's 3.1 release prints 3.0.1 when asked for its version, while the LGE run record shows 3.1. A different version or database build can change the exact counts. Compare the pattern first. In this example Viral assigns about ten times as many pairs to HSV-1 as Standard-16 does, while Standard-16 can report bacteria and human sequence as well.

You can complete the procedure in LGE. A flag is an option you type after a command. The flag sentences under Settings and the command-line section cover the same work in Terminal, the macOS app for typed commands.

## Procedure

Classify the same sample against a viral database and a broader one to see which assignments change.

### Download the Viral and Standard-16 databases

A database can report only the taxa it contains. Reads from organisms outside the database can stay unclassified or receive a label based on a sequence match to a reference in the database.

Before downloading, check free disk space and use **Apple menu > About This Mac** to check memory.

The table gives LGE's estimates.

| Database | Download | Memory |
|---|---|---|
| Viral | About 0.5 GB | About 0.5 GB |
| Standard-16 | About 16 GB | About 16 GB |

Standard-16 is a [capped database](../../GLOSSARY.md#capped-database). It keeps about 1 in 7 of the full Standard collection's minimizers to fit in 16 GB of memory. A read can match only k-mers whose minimizers were kept, so capping can make more reads fall below the **Confidence** threshold. If your Mac has less than 16 GB, use Standard-8 wherever the steps say Standard-16. Standard-8 keeps fewer minimizers still, so expect far fewer classified pairs than shown.

With **Memory mapping** off, Kraken 2 loads the whole database into memory before classifying reads. If you choose a database larger than your Mac's memory, the dialog turns **Memory mapping** on so Kraken 2 can read it from disk. This can take much longer than keeping the database in memory, so use the smaller collection if it suits your question.

Open **Tools > Plugin Manager…** and download Viral from the **Databases** tab. Download Standard-16 or Standard-8 from the same tab. See [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) for download help.

### Open the dialog and choose a database

1. Click the FASTQ bundle SRR12486983 under `Imports` in the sidebar, the list on the left of the window.
2. Choose **Tools > Classification > Kraken2…**. In the FASTQ/FASTA Operations dialog, check that **Kraken2** is selected and the dataset line names `SRR12486983`. FASTA is a text format for sequences without quality scores. The line below describes the bundle's read layout. In an [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq), both mates are in one file, with each read followed by its mate.
3. Choose **Viral** in the **Database** picker. The picker lists finished downloads and their sizes. If it says "No databases installed.", click **Download Database…** to open the Plugin Manager on its **Databases** tab.

    <!-- SHOT: kraken2-dialog -->

4. Leave **Sensitivity** on **Balanced** and **Advanced Settings** collapsed. **Balanced** sets how much matching sequence a read needs before Kraken 2 assigns it. Settings explains the two controls, **Confidence** and **Min hit groups**. The screenshot shows the section open so you can see those values. A stepper is a pair of small up and down arrows beside a number.

    <!-- SHOT: kraken2-advanced-settings -->

If you select several bundles, **Batch Samples** lists each input with a layout tag such as PE for paired-end or SE for single reads. LGE samples the start of each file to distinguish pairs from single reads before enabling **Run**. It checks several samples at a time and shows progress such as "Checking read layouts (12 of 57)…". It classifies samples separately so you can tell which sample each assignment came from, then saves them as one batch result with one row in the Operations Panel, which lists running and finished operations.

### Run Kraken 2 and find the result

1. Click **Run**. To follow the analysis, open the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) with **Operations > Show Operations Panel** (Cmd-Shift-P). A single-sample row shows "Profiling" followed by the input file name. A batch is titled `Classification Batch (N samples)`. The row shows Elapsed during the run and Took when it reads Completed.
2. Find the Viral result under `Analyses/` in a new folder whose name starts with `kraken2-` and ends with a timestamp. Each run gets its own folder, so you can compare it with later runs. LGE opens a single-sample result in the taxonomy viewport, with its folder selected and the Unclassified card visible among the summaries at the top. A batch goes into a timestamped `kraken2-batch-` folder and opens on the first sample without selecting the new folder. See [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) for the project layout.

    <!-- SHOT: kraken2-taxonomy-viewport -->

3. Select the original reads bundle again and reopen **Tools > Classification > Kraken2…**. To make the database the only change, choose **Standard-16** in **Database**, leave **Sensitivity** on **Balanced**, and click **Run**. Expect Standard-16 to take longer than Viral.
4. Open the earlier `kraken2-` folder for the Viral extraction below. The newer folder holds the Standard-16 run.

### Extract the reads of one taxon

Extract a taxon's reads when you need the sequences behind the count. You can map them to a reference sequence to see where they align, assemble them, or check the assignment with [BLAST](../../GLOSSARY.md#blast). BLAST searches a sequence database for regions similar to a sequence you give it. In the cornea sample, use the species row *Simplexvirus humanalpha1* for HSV-1.

1. In the Viral result, type `humanalpha1` in **Filter taxa…**, then select the *Simplexvirus humanalpha1* row. Its wedge lies beyond the eight rings drawn from the root. Re-center on Orthoherpesviridae to see the wedge, as Moving around the tree describes.
2. Click **Extract Reads…** in the action bar at the bottom of the viewport. You can also choose it from the row or wedge's right-click menu, or use **Selection > Table Row > Extract Reads…** after clicking the table. The screenshot shows the menu on the Orthoherpesviridae family row. Keep *Simplexvirus humanalpha1* selected to extract the HSV-1 pairs without taking the entire family.

    <!-- SHOT: kraken2-extract-reads -->

3. Check for `Selected: 1 row` and an estimate of 886,221 pairs on the line ending in "unique reads". This matches the row's Reads count, which includes assignments to the species and all groups below it. Leave **Format** on **FASTQ** and **Destination** on **Save as Bundle**. **Name** starts as `kraken2_Simplexvirus_humanalpha1`.
4. Click **Create Bundle**. For the other destinations the button reads **Save**, **Copy**, or **Share**.

In the top-level `Extractions` folder, look for a bundle starting with `kraken2_Simplexvirus_humanalpha1-`. LGE adds a date, time, and short code to the unchanged name. Check that the bundle holds 1,772,442 reads, two for each of the 886,221 pairs. Selecting a family brings in the reads of its genera and species too. Selecting several rows writes their reads into one bundle.

Extraction uses the result's own folder, even after you rename, move, or copy it. If a copied result lacks its reads, LGE identifies what is missing. Before writing any read, LGE checks its name and length against the Kraken 2 record. If you replaced the bundle's reads after classification, such as by importing different reads under the same name, extraction stops when the checks fail.

An R1 file holds the first mate of each pair, and an R2 file holds the second. For bundles with separate R1 and R2 files, LGE reads the files side by side and takes a pair when Kraken 2 assigned it to the selected taxa. LGE matches the pair's assignment by either mate's read name. LGE checks mate names only for pairs it is about to write and stops with an error if the names identify different pairs. LGE writes each read followed by its mate, then writes any merged reads and orphans after the pairs. Merged reads join overlapping mates into one read. Orphans have lost their mate.

Later tools recognize pairs with matching names ending in `/1` and `/2`, or names such as `SRR123.1.1` and `SRR123.1.2`. Mates that differ only by `_1` and `_2` appear as single reads in the new bundle.

### Importing a Kraken 2 result made elsewhere

To review a colleague's taxon counts in the taxonomy viewport, import their [kreport](../../GLOSSARY.md#kreport), a file that summarizes assignments by taxon.

1. Choose **File > Import Center…** (Cmd-Shift-I).
2. Open **Classification Results** and click **Import…** on the **Kraken2 Results** card. Its file hint reads ".kreport, .kreport2, .bracken".
3. Pick one or more reports and click **Open**. LGE runs `lungfish-cli import kraken2` in the background and shows progress in the Operations Panel.

Each report lands in `Analyses/classification-<name>`. LGE drops the file ending and tidies `<name>` to letters, digits, hyphens, and single underscores. For example, `report (1).kreport` becomes `classification-report_1`. A second import of the same name adds `-2`.

The Import Center copies the report alone. The command-line import can also copy the per-read assignment file with `--output`, as shown in [On the command line](#on-the-command-line). Neither import brings in the classified sequences, so **Extract Reads…** and **Verify with BLAST…** have no reads to work from in either imported result. The counts and sunburst are still available for review in the taxonomy viewport.

## Settings

### The classification dialog

Start with **Balanced** for the two runs in this chapter, so you can compare the databases at the same settings.

The **Sensitivity** presets set two thresholds together.

| Preset | Confidence | Min hit groups |
|---|---|---|
| **Sensitive** | 0.00 | 1 |
| **Balanced** | 0.20 | 2 |
| **Precise** | 0.50 | 3 |

| Control | Range | Step |
|---|---|---|
| **Confidence** slider and typed field | 0.00 to 1.00 | 0.05 |
| **Min hit groups** stepper | 1 to 10 | |

Use the slider, typed field, or stepper to adjust a threshold on its own. An ambiguous base is a symbol that does not specify a single base. If an assignment fails **Confidence**, Kraken 2 tries the parent group, where k-mers supporting any descendant count toward the threshold. If no group up to the root passes, the read stays unclassified.

**Database.** Sets the reference collection and therefore which names Kraken 2 can report. The default is the first ready database in the picker's list, which is sorted by name, so with Viral and Standard-16 installed it is Standard-16. Choose Viral for viruses or Standard or PlusPF for a broader survey, with PlusPF adding protozoa and fungi to Standard. On the command line this is `--db`.

**Sensitivity.** Sets **Confidence** and **Min hit groups** together. The default is **Balanced**, the middle setting in the table. Choose **Precise** when a wrong assignment would be costly, or **Sensitive** to look for a rare target when you can check every hit. On the command line this is `--preset`.

**Confidence.** Sets the fraction of a read's k-mers without ambiguous bases that must support the taxon or its descendants, counting even k-mers with no database match in the denominator. The default is 0.20, so **Balanced** requires at least a fifth of those k-mers to support the assignment. Raise it when the report has many implausible calls, or lower it when you want to examine weaker matches among unclassified reads. On the command line this is `--confidence`.

**Min hit groups.** Sets the minimum number of hit groups for an assignment, where a hit group is a run of overlapping k-mers that share a minimizer found in the database. The default is 2, so one hit group alone cannot give an assignment. Raise it when short repeats produce implausible calls, or lower it for reads too short to hold separate hits. On the command line this is `--min-hit-groups`.

**Threads.** Sets how many processor cores Kraken 2 uses at once. The default is 4 to share the work across cores, and the control is capped at your Mac's core count. Lower it to keep the Mac responsive during a run. On the command line this is `--threads`.

**Memory mapping.** Reads the database from disk in pieces so it can exceed the Mac's memory. It is off by default so databases that fit in memory run faster. Use it for a database too large for your Mac's memory, in which case LGE checks it and shows a banner with the gigabytes required and available. On the command line this is `--memory-mapping`.

**Extra arguments.** Passes text to Kraken 2 without checking which options you entered, with an unclosed quote disabling **Run** and showing "Complete the classifier settings to continue." The default is empty, with the gray placeholder "Kraken2 arguments", because most runs use the visible controls. Use it for an option the dialog lacks after checking the Kraken 2 documentation. On the command line this is `--extra-args`.

### The taxonomy viewport

The [Inspector](../../GLOSSARY.md#inspector) is the right-hand pane that shows details of the selection. The controls here change which samples and taxa you see. Use the sample filters to focus on an input and the table filters to focus on assignments within it.

**Filter taxa….** Shows rows whose sample, name, rank, count, or percentage contains what you type, plus their parents and descendants, and dims wedges that no longer match. It starts empty to show all taxa. Use it to find an organism in a long report. This setting has no command-line flag.

**Bracken.** Shows Bracken's estimated species counts. The column appears automatically when an estimate is available so you can read it beside the Kraken 2 counts. Use it when you need an estimated species total. This setting has no command-line flag.

**Select All.** Selects or clears every visible sample in Sample Filter, under Samples & Metadata in the Inspector. It starts checked so every sample is shown. Clear it before selecting only the samples you want. This setting has no command-line flag.

**Filter….** Narrows the sample picker by name while keeping the current selections. It starts empty so you can see all samples in the picker. Use it to find the samples from one plate or date. This setting has no command-line flag.

**Column header filter.** Limits rows to a value or range set in a column header's menu, with all active filters applied together. It starts clear so no rows are hidden by column values. Use it to focus on species rows or on counts above a threshold you set. This setting has no command-line flag.

### The Extract Reads dialog

**Format.** Chooses **FASTQ** for reads with per-base quality scores or **FASTA** for sequences alone. The default is **FASTQ** to keep the scores. Choose **FASTA** when the next tool needs only sequences, such as for a BLAST submission. On the command line this is `--read-format`.

**Include unmapped mates of mapped pairs.** Includes the mate when only one read in a pair aligned to the selected reference and shows how many reads this adds. It is off by default and hidden for Kraken 2 because Kraken 2 produces no alignment. Turn it on for EsViritu, TaxTriage, NAO-MGS, or NVD if you plan to assemble or map the extracted reads. On the command line this is `--include-unmapped-mates`.

**Destination.** Sends the reads to **Save as Bundle**, **Save to File…**, **Copy to Clipboard**, or **Share…**. The default is **Save as Bundle** so you can run other tools on the reads in your project. Choose **Save to File…** when sending reads to another program, or **Copy to Clipboard** for a small selection, since above 10,000 pairs the option is disabled and its tooltip, the message that opens when you hover, asks you to choose another destination. On the command line this is `--output`.

**Name.** Sets a required bundle or file name for **Save as Bundle** or **Save to File…**. It starts with `kraken2_` plus the taxon name so you can identify the selection, and LGE timestamps the bundle if you keep the default. Change it if you need a more descriptive name. On the command line this is `--bundle-name`.

## Reading the results

Start with the summary cards. A just-finished run shows Total Reads, Classified, Unclassified, Species, Shannon H′, and Dominant. A result reopened from the sidebar shows Batch, Samples, Taxa, and Database. Dominant names the species with the highest count. [Shannon H′](../../GLOSSARY.md#shannon-diversity) measures diversity by reflecting both how many species contribute and how evenly their counts are spread. In the Viral result, Dominant names *Simplexvirus humanalpha1* and Shannon H′ is 0.011, close to 0, the value for a single species.

When mates are in separate R1 and R2 files or paired reads are mixed with merged or single reads, look for Fragments and Read Pairing. A pair counts as one fragment, as in "100 fragments, 23 from read pairs and 77 from merged or single reads". Older results that counted the two mates separately indicate this on a Counting card.

The sunburst puts the root in the center and draws one ring per level. An extra rank such as the realm Duplodnaviria gets its own ring. Wedges are sized by their share of classified pairs. At the root the center shows the classified share of the whole sample, "of all reads". After zooming to a taxon, "of classified" gives its share of classified pairs.

Taxa too small to draw share a paler wedge in their parent's color. Hover over it to see how many taxa and pairs it holds, or hover over another wedge to see the taxon's name, rank, counts, shares of all and classified pairs, and number of child taxa. A child taxon sits directly below another group in the tree.

The table lists Sample, Taxon Name, Rank, Reads, Direct, Bracken, and **%**. Sample identifies the input, SRR12486983 here. The count beside **Filter taxa…** gives the number of taxa when the field is empty. A [clade](../../GLOSSARY.md#clade) is a taxon and all its descendants.

Use these two counts to see where assignments stopped.

| Column | What it counts | Matching hover label |
|---|---|---|
| **Reads** | The [clade count](../../GLOSSARY.md#clade-count), including pairs assigned to this taxon and all descendants | Clade reads |
| **Direct** | Pairs assigned to this taxon itself | Reads |

A family with many Reads and nearly zero Direct has most of its pairs assigned to groups within that family. Check the child rows to see which groups account for them. If Direct makes up much of Reads, many assignments stopped at the family. The available references or the sequence shared among relatives can limit how far the classifier goes. Compare taxa at the same rank on separate branches to avoid counting the same pairs again at a parent row.

<!-- ILLUSTRATION: clade-vs-direct-counts -->

The **%** column divides Reads by all pairs in that row's sample, including unclassified pairs. Kraken 2 calls this the percentage of fragments in the clade. It measures [relative abundance](../../GLOSSARY.md#relative-abundance) as a share of sequence. Genome size and the amount of host DNA can change that share even when organism counts stay the same. The action bar's selection line and the hover card's share of all pairs also use that sample total. See [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) for the denominators in other views.

If you show several samples, compare the rows by sample. Each row uses the same denominator it would in a view of that sample alone. A result made by hand or partly rebuilt can lack a sample total. Its action bar line omits the percentage and its hover card omits the shares. Exported percentage columns still show 0 for that sample, as does the table's **%** column when several samples are selected.

In the Viral run, Kraken 2 classified 893,706 of 4,819,760 pairs (18.54 percent), all under Viruses, and left 3,926,054 (81.46 percent) [unclassified](../../GLOSSARY.md#unclassified-reads). Of these, 1,565,604 pairs, or 32.48 percent of the run, contain only N, the letter for an unknown base, in both mates. They have no sequence for any database to classify. In the remaining unclassified pairs, any viral matches fell short of the assignment thresholds.

An unclassified pair received no assignment that passed the matching and threshold checks. For example, just one hit group falls below the minimum set by **Balanced**. A database restricted to viruses can leave a large share of tissue reads unclassified. Use Standard-16 to look for other groups as well.

Follow the Viral result down from family through subfamily, genus, and species to HSV-1. The **%** column uses all 4,819,760 pairs.

| Taxon | Reads | % |
|---|---|---|
| Orthoherpesviridae | 893,154 | 18.5 |
| Alphaherpesvirinae | 893,152 | 18.5 |
| Simplexvirus | 893,039 | 18.5 |
| *Simplexvirus humanalpha1* | 886,221 | 18.4 |
| Human alphaherpesvirus 1 | 886,221 | 18.4 |

*Simplexvirus humanalpha1* is the species name for HSV-1. The row below it, Human alphaherpesvirus 1, carries the species name used before 2023. Its [taxonomy ID](../../GLOSSARY.md#taxonomy-id), the numeric identifier for that group, is 10298. NCBI kept the old name for the virus when it adopted two-part species names. The Rank column shows Subspecies, LGE's label for Kraken 2's code S1, which marks an entry one step below species. Virus taxonomy has no subspecies rank, so read this row as the virus filed under its species. The small drop in Reads from family to species shows how much of the herpesvirus branch is accounted for by this species.

At the *Simplexvirus* genus row, Direct is 6,789 pairs. An assignment can stop at genus if the minimizers are filed there or if a species assignment fails **Confidence** and moves up. The genus total of 893,039 pairs includes those, the 886,221 HSV-1 pairs, and 29 pairs on two relatives. At the species row Direct is 0, while at Human alphaherpesvirus 1 it is 886,221 pairs. The database holds one HSV-1 genome, reference strain 17 (NC_001806.2 in RefSeq, NCBI's reference sequence collection). It is filed under the lower name, so that row supplies the Reads count at species rank. Where the patient's virus differs from that reference, a pair can lose HSV-1 matches and stop at the genus.

For *Simplexvirus humanalpha1*, Bracken estimates 893,009 pairs, nearly 6,789 more than Reads gives and 99.98 percent of the total Bracken estimated across species. The Bracken column appears only at species rank, so Human alphaherpesvirus 1 has no estimate of its own. Report Bracken as a species estimate and Reads as the Kraken 2 count for that species and its descendants. For extraction, use Reads to see the size of the selection, since extraction uses the original assignments.

If no species reaches 10 in Reads, LGE skips Bracken. The Operations Panel shows Completed with Warnings, and the warning gives the threshold and the largest species count. You can still read the Kraken 2 result, which opens without a Bracken column.

### Small hits beside a big one

To see small hits beside HSV-1, clear **Filter taxa…** and choose **Expand All** from a row's right-click menu. *Simplexvirus paninealpha3*, the chimpanzee herpesvirus, has 28 pairs. Macacine alphaherpesvirus 1, the B virus of macaques, in the species *Simplexvirus macacinealpha1*, has 1 pair. Outside herpesviruses, 402 pairs fall under Uroviricota, a group of phages, or viruses that infect bacteria. Of these, 66 pairs fall in Pahexavirus, a genus of phages that infect the skin bacterium *Cutibacterium acnes*.

The chimpanzee virus is a close relative of HSV-1 in the same genus. K-mers shared by both viruses support the genus *Simplexvirus*. Under **Balanced**, at least a fifth of the pair's k-mers without ambiguous bases must support the chimpanzee-virus branch for the pair to land there. Those matches support the chimpanzee virus without matching the HSV-1 reference. The few chimpanzee-virus assignments beside 886,221 HSV-1 pairs could reflect differences from the single HSV-1 reference, read errors, or formalin damage. Treat both small herpesvirus hits as candidates to check before reporting a second infection.

The phage assignments are consistent with the *Cutibacterium acnes* assignments in [the Standard-16 run](#the-same-reads-a-different-database). Follow [BLAST Verification](06-blast-verification.md) to check a small hit that matters. The two classifier results give you leads to check before drawing a conclusion about which organisms were present.

### Moving around the tree

Click a wedge or row to select it in both views. Double-click **Orthoherpesviridae** to re-center the chart on the family, which has about 893 thousand pairs. Its child taxa fill the first ring. The breadcrumb bar shows the path back to the root. For this family it reads Root > Viruses > Duplodnaviria > Heunggongvirae > Peploviricota > Herviviricetes > Herpesvirales > Orthoherpesviridae.

Click any breadcrumb to return there. Click the center circle or press Escape to zoom out one level, or press Cmd-0 to return to the root. Click the chart before using its shortcuts.

LGE remembers each result's view on this Mac. When you come back, the **Filter taxa…** text, the sort, the selected rows, the sunburst zoom and the **Collections** drawer are as you left them. The Inspector's sample choice comes back only until you quit LGE. A changed result or a new sample list clears what no longer applies, with a line that begins "The data changed since your last visit".

<!-- SHOT: kraken2-drilldown-orthoherpesviridae -->

| Right-click target | Commands |
|---|---|
| Wedge or row | **Extract Reads…**, **Verify with BLAST…**, **Copy Name**, **Open Taxonomy on NCBI**, **Open GenBank Record**, **Search PubMed** |
| Wedge only | **Copy Taxonomy Path**, **Zoom to** followed by the name, such as **Zoom to Orthoherpesviridae**, **Zoom Out to Root**, **Open Genome Assemblies on NCBI** |
| Row only | **Expand**, **Expand All Below**, **Collapse**, **Expand All**, **Collapse All** |
| Empty chart space | **Copy Chart as PNG** |

Use **Open Taxonomy on NCBI** to view the taxon's taxonomy page, **Open GenBank Record** to look up sequences, or **Search PubMed** to look up the name in the literature.

### The action bar and the provenance popover

Use the action bar to check a taxon, extract its reads, or save results. Kraken 2, EsViritu, TaxTriage, NAO-MGS, and NVD share these controls. Some viewers add buttons after the shared ones.

| Control | What it does |
|---|---|
| **Verify with BLAST…** | Sends a sample of the selected taxon's reads to NCBI BLAST. Select exactly one row. See [BLAST Verification](06-blast-verification.md) for the steps. |
| **Export** | Offers **Export as CSV…**, **Export as TSV…**, **Copy Summary**, and **Show Provenance…**. |
| **Extract Reads…** | Opens the Extract Reads dialog for the selected taxa. |
| **BLAST Results** | Shows or hides the **BLAST Results** tab in the drawer below the table. |
| **Collections** | Shows or hides the **Collections** tab in the same drawer. See [Collections](#collections) for extraction by group. |

A grayed button gives the reason in its tooltip. With no selection, the tooltip for **Extract Reads…** begins "Select one or more rows to extract their reads." The tooltip for **Verify with BLAST…** begins "Select a row to verify it with BLAST."

To save the table for use outside LGE, choose a file export. The Operations Panel tracks `lungfish-cli kraken2 export table`. The file contains Name, Rank, Reads (Clade), Reads (Direct), "Clade %", and "Direct %", plus any sample metadata columns shown in the table. Metadata are details associated with a sample. Taxon rows follow tree order, with an unclassified row at the end. A multi-sample export groups each sample's rows between its own sample row and its unclassified row. "Clade %" and "Direct %" divide by the total for that row's sample, including the unclassified count. For the cornea result, that total counts pairs.

The line beside the buttons reads "Select a taxon to view details" until you select a taxon. With one taxon selected, it gives the name, clade count, and share of all pairs. In a multi-sample result it also names the sample.

Use the run's provenance, the record of how it was made, to document what produced the counts in your methods. Keep the database and settings with the reported result so another reader can tell how you obtained it. Right after a run, the information button at the right opens the Classification Provenance popover. It lists the Kraken 2 version, database and folder, Confidence and Hit Groups values, thread count, memory mapping status, runtime, input files, a Bracken row when Bracken ran, and a short run ID.

On a Kraken 2 result reopened from the sidebar, the information button and **Export > Show Provenance…** do nothing, as recorded under [Kraken 2 provenance buttons](../appendices/troubleshooting.md#defect-kraken-provenance) in the troubleshooting appendix. Open **Operation Details** in the **Summary** tab of the Inspector to see the database and its build, Kraken 2 and Bracken versions, Confidence and Min Hit Groups values, thread count, and runtime.

For the keyboard route to the row commands, click the table to give it focus, then open **Selection > Table Row**. On a Kraken 2 table, **Extract Reads…**, **Verify with BLAST…**, **Copy Name**, **Open Taxonomy on NCBI**, **Open GenBank Record**, and **Search PubMed** act on the selected row. The remaining items are grayed. [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) describes the rest of the Selection menu.

### Collections

Use a collection to check the same group of organisms across samples. A collection is a named set of taxa. LGE can extract the set at once, with a separate FASTQ file for each selected taxon with reads.

Click **Collections** to open the drawer on its **Collections** tab. It has a **Filter collections...** field. Each collection row shows its name and how many taxa it holds. Only built-in collections are available.

LGE has eight built-in collections, including Respiratory Viruses, AMR Organisms (ESKAPE), and Fungal Pathogens. Open a collection to see its taxa. A green dot marks a detected taxon, and its tooltip gives the count. A taxon with no reads is dimmed and struck through. Most taxa are marked "+children", meaning reads assigned below them are included. All taxa start selected. Clear the checkbox for any you want to leave out.

For a batch result, first leave only the sample you want selected in the Inspector's Sample Filter. Extraction uses the sample shown in the table, including in a result reopened from the sidebar. If several samples are shown, an alert titled Could not extract reads asks you to choose one.

Click **Extract** on the collection row. LGE runs `lungfish-cli extract taxa-collection` behind an Operations Panel row named Extract followed by the collection name. The button stays grayed until you select a taxon. If none of the selected taxa has reads, LGE shows the alert No reads to extract and writes nothing.

LGE writes one FASTQ for each selected taxon with reads and keeps both mates of a pair together. Each file uses reads from every file that went into the classification for that sample. The files are compressed with gzip, a file format that saves space, and named for the taxon and its taxonomy ID. To find them, right-click the result in the sidebar and choose **Show in Finder**. Open the result folder and look for `extracted-` followed by the collection identifier.

### The same reads, a different database

Open the Standard-16 result to compare HSV-1 counts and look for groups that Viral cannot report. Both runs used the same input pairs.

| Measure | Viral | Standard-16 |
|---|---|---|
| Pairs classified | 893,706 (18.54%) | 343,324 (7.12%) |
| Unclassified | 3,926,054 (81.46%) | 4,476,436 (92.88%) |
| All viruses | 893,706 (18.54%) | 104,172 (2.16%) |
| Human alphaherpesvirus 1 | 886,221 (18.39%) | 89,294 (1.85%) |
| Bacteria | none possible | 219,636 (4.56%) |
| *Homo sapiens* | none possible | 13,252 (0.27%) |

Viral assigned 886,221 pairs to HSV-1, while Standard-16 assigned 89,294, about a tenth as many. Standard-16 keeps about 1 in 7 of the minimizers in the full Standard collection. It covers archaea, bacteria, viruses, plasmids, the human genome, and cloning-vector sequences. Plasmids are DNA molecules that can replicate independently of the chromosome. Cloning vectors are DNA molecules used to carry other DNA into cells.

Both databases hold the same HSV-1 reference genome, and Viral keeps every one of its minimizers. In Standard-16, an HSV-1 pair can match about 1 in 7 of its k-mers on average, below the fifth **Balanced** requires. This likely left most HSV-1 pairs unclassified and explains much of the drop to about a tenth as many. Some classified Standard-16 pairs stopped at the root or at cellular organisms, or fell in small groups such as Archaea.

The 18.39 percent and 1.85 percent figures divide the HSV-1 count for each database by all 4,819,760 pairs. Report each as the share assigned to HSV-1 by the named database. Missed HSV-1 pairs can lower the reported share, and pairs assigned to HSV-1 in error can raise it.

Standard-16 also placed 219,636 pairs under Bacteria, a group that Viral cannot report.

The table lists the largest bacterial species.

| Species | Pairs |
|---|---|
| *Kocuria rhizophila* | 7,761 |
| *Cutibacterium acnes* | 2,282 |
| *Kocuria varians* | 1,571 |
| *Bradyrhizobium* sp. WCU1 | 1,416 |
| *Cellulosimicrobium cellulans* | 331 |

The species rows for all 549 bacterial species hold 16,365 pairs. Most pairs counted under Bacteria stopped above species. The report leaves open whether bacterial DNA came from the eye, the surrounding skin, or the lab. See [What good looks like](#what-good-looks-like) for checks before reporting such hits.

Only 13,252 pairs, or 0.27 percent, were assigned to *Homo sapiens*, even though Standard-16 includes the human genome. [Host depletion](../../GLOSSARY.md#host-depletion) removes or masks host material, such as its DNA or reads. The 1,565,604 pairs with only N in both mates, 32.48 percent of the run, are consistent with masking and count as unclassified, since they contain no sequence to assign to *Homo sapiens*. The report cannot tell how many came from the host. Standard-16's cap likely leaves many remaining human pairs below the **Confidence** threshold set by **Balanced**, as it can for HSV-1.

Use a broad database to look across groups, then try a specialist database for a group you want to examine in more detail. Here Standard-16 reported HSV-1 at under 2 percent of all pairs, while Viral reported a larger HSV-1 share and could give no bacterial assignments. For HSV-1, the databases share one reference genome, so the cap and **Confidence** likely explain most of the gap. Viral has no bacterial or human reference. To see how the capped database performs with looser thresholds, rerun Standard-16 on **Sensitive**, which sets **Confidence** to 0.00, and compare the HSV-1 counts.

## What good looks like

Start with the unclassified share to see how much of your sample received no label. Read the Unclassified card after the run. On a reopened result, return the chart to the root and subtract the classified share "of all reads" from 100 percent. If more than half the sample is unclassified, named groups account for a minority of the pairs. The table's **%** column still uses all pairs.

A large unclassified share is expected in tissue screened against Viral. Standard-16 left 92.88 percent unclassified in this example. About a third of all pairs contain only N, consistent with masking before upload. The cap can also leave reads below the **Confidence** threshold set by **Balanced**, and reads from organisms missing from the database may stay unclassified.

Samples with lots of host DNA and environmental samples usually leave more pairs unclassified than samples from a single organism grown in culture. Compare the share with a similar sample or a negative control, a blank processed alongside the samples, using the same database and settings. A result can still answer a narrow question, as the Viral run did by reporting HSV-1.

A [negative control](../../GLOSSARY.md#negative-control) is a blank you process beside your samples to check for contamination. Comparing the blank with your samples can flag assignments that may come from contamination. When Kraken 2 assigns no pairs, the run opens with "No classification data", the Unclassified card shows "100.0%", and the table has no taxa. The Operations Panel reads Completed with Warnings because Bracken has nothing to estimate, and the Bracken column is absent. An exported table still has an unclassified row. If a sample gives no assignments, check read quality, your thresholds, and whether the database includes the groups you expected before rerunning.

To find the dominant assignments, click the **Reads** column header and choose **Sort Descending**. Compare separate branches at the same rank, then follow the dominant branch down to see how narrow the assignments are. Orthoherpesviridae dominates the Viral result and most of its pairs reach the HSV-1 branch. If several groups have similar counts, check the evidence for each before interpreting the pattern as a mixture.

Plan how you will check small hits before opening the result, then apply the same checks to expected and unexpected organisms. After reviewing the largest groups, scroll down to the small counts.

Consider the single pair assigned to B virus here alongside the much larger HSV-1 signal. A small hit could be a real component, a [false positive](../../GLOSSARY.md#false-positive) such as an HSV-1 pair that matches B virus better than the single HSV-1 reference, or [contamination](../../GLOSSARY.md#contamination) from stray DNA in the sample or reference. A false positive is an assignment to a group the read did not come from. Contamination is unwanted sequence from another source. The same count can arise in any of these cases. Use [BLAST Verification](06-blast-verification.md) to check assignments that matter. See [Why a classifier reports things that are not there](01-what-is-classification.md#why-a-classifier-reports-things-that-are-not-there) for more examples.

Read the [Confidence](../../GLOSSARY.md#confidence-kraken-2) threshold as a measure of k-mer support for a taxon and its descendants. Even a strong match can come from a mislabeled reference or a sequence that several organisms share. The viewport shows the count supporting each label. To check an important finding, look for evidence such as the parts of the genome the reads cover, whether many reads came from copies of one fragment, and what your controls showed. See [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) for how to use each kind of evidence. To document the run, use the details described in [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) when you write your methods.

## On the command line

This section is optional, so skip it if you work in the app. The commands repeat the procedure for people who run LGE in Terminal, the macOS app where you paste a command and press Return, and [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains the `PROJECT=` line and the backslashes at the ends of lines. A command copied from the Operations Panel uses `kraken2 classify` with `--project` and makes a new result folder under `Analyses`.

Before running either `kraken2 classify` command below, check that its `--output-dir` is new. Reusing a classification folder removes its earlier report, per-read output, and Bracken profile before Kraken 2 starts.

The CLI Reference lists the `kraken2 classify` flags under [Classification](../appendices/cli-reference.md#classification) and the import flags under [`import kraken2`](../appendices/cli-reference.md#import-kraken2) for quick reference.

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

The extraction command writes a bundle, because `--bundle-name` implies one. `--taxon` takes the numeric taxonomy ID rather than a name, and **Open Taxonomy on NCBI** on a row's right-click menu opens the taxon's NCBI page, which shows it. Taxonomy ID 10298 is the Human alphaherpesvirus 1 row, which holds every read of its species in this result. By default `--taxon` takes the taxon and everything below it, as the dialog does, and `--taxon-scope exact` takes only the reads classified to the taxon itself.

The `extract reads` command has its own `--read-format` flag, which there chooses FASTQ or FASTA. **Copy CLI Command** on the Operations Panel row of any extraction copies its command.

The export command refuses to replace an existing file unless you add `--force`. In the import command, the two `/path/to/` paths stand for the report and per-read file on your Mac. The import lets you review the counts while keeping the assignment file with the result.

The dialog requests Bracken profiling. On the command line, add `--profile` to request it. Without it, the result has no Bracken column. With `--profile`, a Bracken profile that cannot be made leaves the classification complete, with a warning, and the command still finishes without an error.

Given a bundle, the default `--read-format auto` classifies its mates as pairs, as the dialog does, and runs any merged or single reads beside them in the same run. Given the two downloaded files instead, such as `SRR12486983_1.fastq.gz` and `SRR12486983_2.fastq.gz`, add `--paired`, and add `--unpaired` once for each file of merged or single reads that belongs with them.

Your inputs can mix gzip-compressed (`.gz`) files and plain text. Kraken 2 opens all files in the same format as the first, so LGE makes copies of inputs that differ from it and converts the copies to match. The copies stay in the hidden `.lungfish-classify-inputs` folder in the result. Provenance lists this step as `Lungfish Classification Input Compression Staging`.

## Next

Continue to [Running EsViritu](03-running-esviritu.md), which surveys a SARS-CoV-2 run with Kraken 2 and then checks how much of the virus's genome the reads covered. To check a Kraken 2 hit against NCBI before you believe it, go to [BLAST Verification](06-blast-verification.md), which verifies this chapter's HSV-1 call.
