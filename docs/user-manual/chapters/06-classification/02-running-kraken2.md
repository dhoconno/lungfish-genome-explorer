---
title: Running Kraken 2
chapter_id: 06-classification/02-running-kraken2
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 30
task: Classify a FASTQ bundle with Kraken 2 against an installed database, read the taxonomy viewport, and pull the reads of one taxon out as a new bundle.
tags: [classification, kraken2, bracken, taxonomy, sunburst, extraction]
tools: [kraken2, bracken]
parameters_refs: [classify.kraken2, classify.install-database, classify.taxonomy-browser, classify.extract-reads-by-taxon]
entry_points:
  - "Tools > Classification > Kraken2..."
  - "Tools > Plugin Manager... (Databases tab)"
  - "CLI: lungfish-cli conda classify"
shots:
  - id: kraken2-databases-tab
    caption: "The Plugin Manager on its Databases tab, with the recommended-database banner at the top and the eleven Kraken 2 rows showing which collections are installed and which still offer a Download button."
  - id: kraken2-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > Kraken2..., showing the dataset line, the Database picker with its size readout, and the Sensitivity segmented control."
  - id: kraken2-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the Confidence slider, the Min hit groups stepper, the Threads stepper, the Memory mapping checkbox, and the Extra arguments field."
  - id: kraken2-taxonomy-viewport
    caption: "The taxonomy viewport after classifying SRR36291587, with the breadcrumb bar running across the top of both panes, the sunburst on the left, and the per-taxon table on the right showing its Filter taxa... field."
  - id: kraken2-drilldown-coronaviridae
    caption: "The sunburst re-centred on Coronaviridae after a double-click, with the breadcrumb bar showing the path back to the root."
  - id: kraken2-extract-reads
    caption: "The right-click menu on a taxon row, with Extract Reads... highlighted above the expansion, BLAST, NCBI lookup, and Copy Taxon Name actions."
illustrations: []
glossary_refs: [amplicon, blast, bracken, bundle, capped-database, clade, clade-count, conda, fastq, host-depletion, k-mer, kraken2, kreport, lowest-common-ancestor, metagenomics, minimizer, operations-panel, paired-end, plugin-pack, provenance, read, read-classification, spike-in-control, taxon, taxonomic-rank]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

[Kraken 2](../../GLOSSARY.md#kraken2) is a program that reads a [FASTQ](../../GLOSSARY.md#fastq) file one [read](../../GLOSSARY.md#read) at a time and writes down, for each read, which organism it most likely came from. A read is one stretch of sequence the instrument produced, a few hundred bases long. The answer it writes down is a [taxon](../../GLOSSARY.md#taxon), which is any named group on the tree of life, so *Homo sapiens*, *Streptococcus*, and the virus family *Coronaviridae* are each one taxon. Do that for every read in a file and you have a census of what was in the tube.

Kraken 2 answers by matching short words rather than by aligning whole sequences. Aligning means lining two sequences up base by base and scoring how similar they are, which is accurate and slow. A [k-mer](../../GLOSSARY.md#k-mer) is a substring of exactly k bases taken from a longer sequence, so `ACGTA` holds three 3-mers, `ACG`, `CGT`, and `GTA`. A sliding window is a fixed-width stretch of the read, a few dozen bases across, that starts at the first base and moves along one base at a time. A [minimizer](../../GLOSSARY.md#minimizer) is the smallest k-mer inside one window, where smallest means first in a fixed sort order the program applies to the four letters, and it stands in as a compact fingerprint of that whole window.

Kraken 2 slides that window along each read, takes the minimizer from each position, and looks it up in a prebuilt database that records which taxon every minimizer belongs to. It then reads off the series of taxa the read's minimizers point at and counts them. The taxon holding the most matching minimizers wins the read, provided it clears the confidence threshold the Settings section explains. That lookup is a table lookup rather than an alignment, which is why the tool is quick. It is also why the tool is exactly as good as its database and no better, a point the rest of this chapter depends on.

When a read's minimizers point at several close relatives equally well, Kraken 2 does not guess. It steps up the hierarchy and reports the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor), the most specific taxon that all the matching organisms belong to. A read shared by every *Streptococcus* species comes back labelled *Streptococcus*, and that is honest reporting rather than a failure. It does mean that a Kraken 2 report has counts sitting at every level of the hierarchy at once, not only at species, which is what the Reading the results section below teaches you to read.

Lungfish Genome Explorer (LGE) labels this tool **Kraken2** in its menus and describes it as "Classify reads taxonomically". Every run LGE starts is really two programs. Kraken 2 assigns the reads, and then [Bracken](../../GLOSSARY.md#bracken) re-estimates how abundant each species actually was. Abundance here is the fraction of the sample each species made up, and Bracken's job is to push reads that Kraken 2 stopped at a broad group down onto the species they most likely came from. The result lands as a folder named with the tool and the date and time, such as `kraken2-2026-09-07T14-23-10`, under the project's `Analyses` folder, and it opens in the taxonomy viewport, which is a sunburst chart on the left, a sortable table on the right, and a breadcrumb bar naming whichever part of the tree you have moved into.

Treat a Kraken 2 run as a screen, meaning a first quick pass you follow up rather than trust. Read the dominant signal and the unclassified share together, and treat any single hit as a hypothesis you still have to check.

## Why you would do this

You would run Kraken 2 whenever you do not already know, or cannot already prove, what is in a sequencing library. That covers more situations than it sounds like it does.

The obvious one is a genuinely unknown sample. A patient specimen, a wastewater grab, a swab from a sick animal. You sequence everything present and ask the classifier what came back. The less obvious ones matter more often in practice. You have a library you believe is one organism and you want evidence rather than belief, because a mislabelled tube and a cross-contaminated plate look identical until something counts the reads. A plate here is the tray of small wells, usually ninety-six of them, that samples are prepared in side by side, which is how liquid from one sample reaches another. You have a low-yield run, meaning one that returned few reads of the thing you were after, and you want to know whether the target is scarce or the sample is mostly host DNA, the DNA of the animal or person the specimen came from. You are about to spend a week assembling a genome, which means stitching short reads back into long continuous sequence, and you would like to know first how much of the data is even from the organism you meant to assemble.

This chapter works through the SRR36291587 SARS-CoV-2 reads, a QIAseq Direct [amplicon](../../GLOSSARY.md#amplicon) library of 85,199 [paired-end](../../GLOSSARY.md#paired-end) Illumina read pairs from a public NCBI Sequence Read Archive run. Paired-end means the instrument read each DNA fragment from both ends, so one fragment yields two reads that travel together as a pair, and every count in this chapter is a count of pairs unless it says otherwise. An amplicon library is one where PCR amplified a fixed set of target regions before sequencing, so the library is deliberately enriched for one organism rather than sampling everything present. That makes it an unusually clear teaching case, because you know the right answer before you start and can therefore see plainly what the classifier gets right, what it misses, and what it invents. This chapter is one of the manual's viral examples because read classification of a viral specimen is the setting the tool was designed for, and because the same reads carry the human and laboratory background that makes the interpretation lesson real.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. A name written as Cmd-N is a keyboard shortcut, meaning hold the Command key and press N. Pick an empty folder or make a new one, since LGE fills the folder with its own structure.

This chapter uses the SRR36291587 SARS-CoV-2 reads. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The archive is public and no account or login is needed. The rest of the fixture's files, and the source and licence notes for the data, are on GitHub at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

Kraken 2 and Bracken both ship in the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), which the Plugin Manager lists as **Metagenomics**. A plugin pack is a themed group of tools LGE installs on demand into private [conda](../../GLOSSARY.md#conda) environments, described in [Plugin Packs and Databases](../01-foundations/07-plugin-packs.md). A conda environment is a self-contained folder of programs, and LGE downloads these and keeps them inside its own storage, so nothing is added to the rest of your Mac and nothing has to be undone later. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and install Metagenomics if it is not already there. The pack's card reports how many of its tools are ready, reading "4 of 4 ready" when the pack is complete, and it offers an **Install All** button until it is.

You also need a Kraken 2 database, which is a separate download from the tools and is the subject of step 1 below. No database ships with LGE, so a first run always starts by fetching one.

## Procedure

The worked example classifies the SRR36291587 reads twice, once against a small viral database and once against a general-purpose one, because the difference between the two answers is the most useful thing this chapter has to teach. Every count quoted in this chapter came from real runs made on 2026-09-07 with Kraken 2 version 2.17.1 and Bracken version 3.0.1. If your installed versions differ, expect your counts to sit close to these rather than match them digit for digit, since a different build of a tool or a newer build of a database can move a few reads.

### 1. Install a database

A Kraken 2 database is a prebuilt index of reference genomes, and it is the thing that decides what answers are even possible. A database holding only viruses cannot report a bacterium, no matter how much bacterial sequence your library contains. It will report those reads as unclassified instead.

1. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and click the **Databases** tab. Eleven Kraken 2 rows are listed. Nine are downloadable collections, running from the half-gigabyte Viral collection up to the seventy-two-gigabyte PlusPF, which stands for Plus Protozoa and Fungi. The other two are SILVA and Greengenes, ribosomal catalogs LGE builds on your own machine rather than downloading. A collection is simply one database, and this chapter uses the two words for the same thing. [Plugin Packs and Databases](../01-foundations/07-plugin-packs.md) has the full table of what each one covers. The short rule is that a collection is worth choosing when it covers the organisms you might plausibly find and still fits your memory.

2. Read the banner at the top, which reads "Recommended for your system" and names the largest general-purpose collection that fits comfortably in your Mac's memory, leaving headroom for everything else the machine is doing. Specialist collections such as Viral are never recommended this way. The banner has already checked your memory for you, so you do not have to look the figure up. Kraken 2 loads the entire database into RAM before it classifies a single read, so memory rather than disk is the limit that matters, and any collection asking for more memory than you have is labelled "(exceeds system RAM)" inline.

3. Click **Download** on **Viral**, which is the collection this chapter's first run uses. It is the smallest at about 0.5 GB and it runs comfortably on any Mac LGE supports.

4. Download a second, broader collection as well, either **Standard-8** or **Standard-16**. The number is the memory the collection needs, so Standard-8 wants about 8 GB free and Standard-16 about 16 GB. If you are unsure, take whichever one the banner recommends. Both are [capped databases](../../GLOSSARY.md#capped-database), meaning a full Standard collection shrunk to fit a smaller machine by discarding reference fragments. The reference run behind this chapter used Standard-16.

    <!-- SHOT: kraken2-databases-tab -->

The row turns to read **Installed** when the download and unpack finish, and it then reports the version, the install date, and whether a newer pinned build exists. Pinned means the exact version this release of LGE was tested against, so an available update moves you to a newer tested build. If you would rather read the same information outside the app, and this is optional, `lungfish-cli conda db list` prints it, and `lungfish-cli conda db recommend` prints the recommendation the banner shows.

### 2. Open the dialog and choose a database

1. Click the FASTQ bundle holding the SRR36291587 reads in the project sidebar to select it. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one object, holding the reads together with the notes recording where they came from, and it appears in the sidebar as a single row with a file-like icon rather than as a folder you open. Bundle, sample, and dataset all name the same thing from three angles here. The bundle is what you click, the sample is what the run reports on, and the dataset line in the dialog names which bundles are going in.

2. Open **Tools > Classification > Kraken2...**. Classification is a submenu holding one item per classifier, so Kraken2, EsViritu, and TaxTriage are three separate menu items rather than one shared wizard. The classifier is chosen by which menu item you clicked. The window that opens is titled FASTQ/FASTA Operations, which is the name of the window rather than of anything in the menu, and it opens with Kraken 2 already selected. Its tool sidebar lists EsViritu and TaxTriage beside Kraken2 if you want to switch without going back to the menu.

3. Read the dataset line at the top of the dialog, which names whatever bundle was selected when you opened it. Paired reads are handled for you. LGE groups the selected bundles into samples and detects for each sample whether it holds one read file or a mated pair, matching the mate markers in the filenames, so `SRR36291587_1` and `SRR36291587_2` are recognised as the two halves of one sample, as are the `_R1` and `_R2` forms. A paired bundle therefore feeds both mates into the same Kraken 2 run.

4. Open the **Database** picker. It lists only the collections that finished downloading, each with its size on disk beside the name. Choose **Viral**. If no database is installed the picker is replaced by the words "No databases installed." and a **Download Database...** button that opens the Plugin Manager straight to its Databases tab.

    <!-- SHOT: kraken2-dialog -->

5. Leave **Sensitivity** on **Balanced** and the **Advanced Settings** section collapsed. The three-way sensitivity control is the simple version of two numbers inside that section, the confidence threshold and the minimum hit groups. Picking a preset fills both of those in for you, so there is nothing to set by hand, and the Settings section below explains all of them. Balanced is the right first answer for almost every sample and is what this worked example uses throughout.

    <!-- SHOT: kraken2-advanced-settings -->

If you selected more than one bundle before opening the menu, the dialog shows a **Run Mode** control fixed on "Run separately per bundle" and explains why it is locked. The whole selection runs as one classification batch, which registers a single entry in the Operations Panel, writes one merged summary, and produces one result folder. Each sample is still classified separately inside that batch, because pooling reads across samples before classification would destroy the per-sample abundance numbers you ran the batch to get.

### 3. Run it and find the result

Click **Run**. The dialog closes, and a row appears in the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled `Profiling SRR36291587_1.fastq`, naming the file rather than the tool, because a run started from the dialog always classifies and then profiles with Bracken. A multi-sample run is titled `Classification Batch (N samples)` instead. Runtime depends on your machine, the database, and how many reads you have. On the reference run the Viral database finished in 2.6 seconds and Standard-16 in 11.3 seconds against these 85,199 read pairs. A few seconds is the normal shape of the thing, because classifying a read is a table lookup rather than an alignment. Both figures are also for a database the operating system had already read once and kept in memory, so a first run after a restart spends extra time reading the database off disk, and the larger the collection the more of that time you wait.

When the row completes, find the result in the sidebar. It is a folder named `kraken2-<timestamp>` under the project's `Analyses` folder, not a file beside your reads. Every classification run gets its own folder named with the date and time it started, so a second run never overwrites the first and you can keep a Viral result and a Standard-16 result side by side. Double-click the folder and the taxonomy viewport opens.

<!-- SHOT: kraken2-taxonomy-viewport -->

Now reselect the reads bundle in the sidebar, reopen the dialog, and choose **Standard-16** in the Database picker instead of Viral, so you have both results to compare in the Reading the results section. Opening a result folder moves the selection off the bundle, which is why the reselection matters.

### 4. Extract the reads of one taxon

Once you have found the taxon you care about, you usually want its reads rather than its count, so you can map them to a reference, assemble them, or send them to [BLAST](../../GLOSSARY.md#blast).

On the worked example the taxon to take is *Severe acute respiratory syndrome coronavirus 2*, the bottom row of the Viral result. If you would rather see why that is the row that matters before you extract anything, read the Reading the results section first and come back.

Right-click the taxon's row in the table, or its wedge in the sunburst, and choose **Extract Reads...**. The action bar, the strip of buttons running along the top of the viewport, carries an **Extract FASTQ** button that does the same thing for whatever is selected.

<!-- SHOT: kraken2-extract-reads -->

In the dialog that opens, leave the **Format** control on FASTQ, leave the **Destination** control on Save as Bundle, and check the **Name** field, which arrives pre-filled from the taxon and the run. Then click **Create Bundle**, which is what the run button says while Save as Bundle is the destination. The new bundle appears under the project's top-level `Extractions` folder, holding the reads assigned to that taxon and to everything beneath it in the hierarchy.

On the reference run, extracting under *Severe acute respiratory syndrome coronavirus 2* from the Viral result produced 83,591 read pairs. The extraction dialog for the alignment-backed classifiers carries an extra "Include unmapped mates of mapped pairs" checkbox, which is hidden here because Kraken 2 produces no alignment to draw a mate from.

## Settings

Every setting of all four operations this chapter covers is documented below, grouped by where you meet it. Each entry ends with a short sentence naming the command-line flag that does the same job. Those closing sentences belong to the optional command-line section at the end of this chapter, so skip them if you are staying in the window.

The classification dialog carries eight controls. Seven are always there, two in plain view and five inside the Advanced Settings section, and the eighth, Run Mode, appears only when you selected more than one bundle. Some of the bold labels below end with both a colon and a period. The colon is part of the label as the app draws it on screen, and the period closes the bold opening of the paragraph, so neither is a typing slip.

**Database.** Names the reference collection every read is compared against, and therefore fixes which answers are possible at all, since a read can only be given a name that exists in this database. The default is the first installed database that finished downloading, which is an arbitrary choice rather than a considered one, so always look at it before you run. Pick a small collection such as Viral when you already know which family you are hunting, and a Standard or PlusPF collection when you want an unbiased survey. On the command line this is `--db`.

**Sensitivity.** Sets two numbers together, the confidence, meaning the share of a read's k-mers that must agree with a name, and the minimum hit groups, meaning how many separate matching stretches the read must carry, which between them trade how many reads get a name against how often that name is right. The default is Balanced, which uses confidence 0.20 with 2 hit groups, against Sensitive at 0.00 with 1 and Precise at 0.50 with 3. Move to Precise when a false positive would be costly, such as reporting a pathogen in a clinical context, and to Sensitive when you are hunting something rare and are willing to check every hit by hand. On the command line this is `--preset`.

**Run Mode.** Shows how several selected samples are handled, and appears only when you selected more than one bundle. It is fixed on "Run separately per bundle" and cannot be changed, because pooling reads across samples before classification would mix up the per-sample abundance numbers. There is nothing to change, so read the lock reason and move on. This setting has no command-line flag.

**Confidence:.** Sets how much of a read must match a taxon before Kraken 2 will commit to that name, expressed as a fraction of the read's k-mers, so 0.20 means at least a fifth of the k-mers in that read have to point at the taxon being assigned. The default is 0.20, the value the Balanced preset chooses, with 0.00 accepting any single supporting k-mer and 0.50 demanding half the read, and the slider runs from 0.00 to 1.00 in steps of 0.05. Raise it when the report is full of implausible species, and lower it when too many reads come back unclassified, remembering that a read failing this test is usually pushed up to a broader group and is left unclassified only when no broader group clears the bar either. On the command line this is `--confidence`.

**Min hit groups:.** Sets how many separate stretches of a read must match the same taxon before that taxon can be assigned, where a hit group is one unbroken run of neighbouring k-mers all pointing at that taxon and two groups have to be separated by at least one k-mer that does not, on the reasoning that one long chance match is much easier to come by than two independent ones. The default is 2, and the stepper accepts 1 to 10. Raise it when short repeated sequence is producing calls you do not believe, and lower it for very short reads that cannot physically hold two separate matches. On the command line this is `--min-hit-groups`.

**Threads:.** Sets how many processor cores Kraken 2 uses at once, so more threads finish sooner and leave less of the machine free for anything else. The default is 4 and the stepper will not let you exceed your Mac's core count, so there is nothing to look up and nothing you can set that would harm the result, since the only cost of a high value is a less responsive machine while the run proceeds. Lower it when you want the machine responsive for other work while a large run proceeds. On the command line this is `--threads`.

**Memory mapping:.** Reads the database from disk in pieces instead of loading the whole thing into memory, so the run no longer needs the database to fit in RAM and is much slower in exchange. The checkbox is off by default and stays off for every database that fits your memory, which is the state almost every reader will see, so it is not a box you normally set yourself. It ticks itself when you pick a database larger than your Mac's memory, and the warning banner that appears alongside names both the gigabytes required and the gigabytes you have. On the command line this is `--memory-mapping`.

**Extra arguments:.** Passes text straight through to Kraken 2 without LGE checking it, which is the escape hatch for a Kraken 2 option the dialog does not expose. It is empty by default, and it should stay empty for almost every run. Use it only after reading the Kraken 2 documentation for the option you want, and note that an unclosed quote blocks the run with the dialog saying so. On the command line this is `--extra-args`.

The Plugin Manager's Databases tab carries five controls, which [Plugin Packs and Databases](../01-foundations/07-plugin-packs.md) covers in the context of the tab as a whole.

**Download.** Fetches one database and unpacks it into the app's managed storage, showing the download size, the memory the database needs, and a progress bar. Nothing is installed until you ask, because the nine downloadable Kraken 2 collections run from half a gigabyte to seventy-two and no machine needs all of them. Download the one your work needs, taking the banner's recommendation as a safe first choice. On the command line this is `conda db download <name>`.

**Remove.** Deletes an installed database and frees its disk space, after a confirmation sheet naming the database. Nothing is removed unless you ask, since a removed collection has to be fetched again from scratch. Remove one you no longer classify against, because the large collections take tens of gigabytes. On the command line this is `conda db remove <name> --delete-files`.

**Update.** Replaces an installed database with the version pinned in the app's dependency list. Nothing is updated unless you ask, and the two collections LGE builds on your own machine cannot be replaced in place, so they are reported as skipped. Update when the row says an update is available and you want your results to match the current pinned build. On the command line this is `conda db update <name> --yes`.

**Refresh.** Re-reads the catalog and the installed set, so a database that arrived some other way appears. The list loads once when you open the tab, which is why it can go stale while the window stays open. Use it when a download you started elsewhere has finished and the list still looks unchanged. On the command line this is `conda db list`.

**Storage Settings....** Opens the setting deciding where downloaded databases live, with the current folder and total space in use shown along the foot of the tab. It points at the app's own managed storage folder by default, which is the one place LGE can always reach. Change it when your startup disk is too small for a Standard collection and you would rather keep databases on an external drive. This setting has no command-line flag.

The taxonomy viewport carries five controls of its own, and none of them reaches the command line, since they change what you are looking at rather than what was computed.

**Filter taxa….** Hides every row whose taxon name, rank, or read count does not contain what you type, with a count beside the field reporting how many rows survive. It is empty by default, showing everything. Use it whenever you are hunting one organism in a report running to thousands of rows.

**Bracken.** Is a column rather than a control, holding read counts that Bracken re-estimated, which corrects Kraken 2's habit of stopping reads at a broad rank instead of carrying them down to the species below. The column is hidden by default and appears on its own whenever the result carries Bracken numbers, which it always does for a run started from the dialog. There is nothing here to set, so read the column when it is there and expect it on every dialog-started run.

**Select All.** Ticks or unticks every sample currently visible in the sample picker, which only appears at all for a result covering several samples. It starts unticked. Use it to begin from all samples and untick a few, rather than ticking twenty by hand.

**Filter….** Narrows the sample list in the sample picker to names containing what you type, changing which samples you can tick rather than which are already ticked. It is empty by default. Use it on a run with many samples when you want to reach only one plate or one collection date.

**Column header filter.** Restricts one column to rows matching a value or a numeric range you set from that column's own menu, which opens when you click the column's header, and several column filters apply together. No column carries a filter to begin with. Use it to hold a report to species rank only, or to rows above a read count you consider worth reading, where a hundred reads is a reasonable opening threshold on a library this size.

The extraction dialog carries four controls, one of which you will never see on a Kraken 2 result.

**Format:.** Chooses whether the extracted reads keep their per-base quality scores or come out as sequence only, so FASTQ keeps the scores and FASTA drops them. The default is FASTQ, which loses nothing. Choose FASTA when the next tool wants sequence alone, such as a BLAST submission or an alignment. This setting has no command-line flag.

**Include unmapped mates of mapped pairs.** Also pulls out the partner read of any pair where only one of the two was assigned to this taxon, with the dialog reporting how many extra reads that adds. It is off by default. Turn it on when you plan to assemble or map the extracted reads, since both halves of a pair carry more information than one, and note that this checkbox is hidden entirely for a Kraken 2 result because Kraken 2 produces no alignment to find a mate in. This setting has no command-line flag.

**Destination:.** Chooses where the extracted reads go, offering Save as Bundle, Save to File..., Copy to Clipboard, and Share.... The default is Save as Bundle, which puts them in your project as a new dataset you can run other tools on. Choose Save to File when the reads are going to another program, and Copy to Clipboard only for a handful of reads, since that option is disabled above 10,000 read records, counting each mate of a pair separately, and hovering the pointer over it brings up a message telling you to pick another destination. The dialog reports the count itself, reading "N unique reads" beside the selection, so you do not have to work it out first. On the command line this is `--output`.

**Name:.** Names the bundle or file that gets written, and appears only for the Save as Bundle and Save to File destinations. It arrives pre-filled with a name built from the taxon and the run, and it cannot be left blank. Change it when the suggested name will not tell you what the reads are six months from now. This setting has no command-line flag.

## Reading the results

The viewport shows the same tree twice. On the left the sunburst draws the root of life at the centre and one ring per [taxonomic rank](../../GLOSSARY.md#taxonomic-rank) outward, with each wedge sized by how many reads fall under it. On the right the table lists the same taxa as rows. The table's columns are Sample, Taxon Name, Rank, Reads, Direct, Bracken, and a percent column headed simply **%**. Sample names which input the row's counts came from, which matters only on a multi-sample run. Rank is the level of the hierarchy the taxon sits at, so domain, family, genus, species. The percent column is a clade percentage rather than a direct one, holding the row's Reads figure as a share of the classified reads, and the tables below head it Percent.

Two of those columns are easy to confuse and everything else depends on telling them apart. **Reads** is the [clade count](../../GLOSSARY.md#clade-count), meaning every read assigned to that taxon or to anything below it, a [clade](../../GLOSSARY.md#clade) being a taxon together with everything descended from it. **Direct** is only the reads assigned to that exact taxon and no lower. A family row with a large Reads figure and a Direct figure of zero, or a Direct under about one read in a thousand of its Reads figure, means the classifier resolved almost all of those reads to something more specific, which is a healthy result. A family row with a large Direct figure, meaning a substantial share of its own clade count, means the classifier stopped there, either because the reads genuinely cannot be resolved further or because the database holds nothing more specific to resolve them to.

Here is the Viral result on the SRR36291587 reads, one row per level from the top of the tree down to the species. Every count in this table, and in every table in this chapter, is a count of read pairs. The Rank column reads domain for Viruses because that is how this database's own copy of the taxonomy files viruses, whatever your genetics course said about the three domains of cellular life.

| Taxon | Rank | Reads | Direct | Percent |
|---|---|---|---|---|
| Viruses | domain | 83,728 | 65 | 98.27 |
| Coronaviridae | family | 83,663 | 0 | 98.20 |
| Betacoronavirus | genus | 83,662 | 0 | 98.20 |
| *Betacoronavirus pandemicum* | species | 83,645 | 54 | 98.18 |
| Severe acute respiratory syndrome coronavirus 2 | subspecies | 83,591 | 83,591 | 98.11 |

The name in the species row will be unfamiliar. *Betacoronavirus pandemicum* is the formal species name the taxonomy now gives to the group SARS-CoV-2 belongs to, and SARS-CoV-2 itself sits below it as a named subspecies. Viral taxonomy routinely names a species that holds one or more familiar viruses as members, so a virus you know by name appearing below the species rank is the convention rather than a mistake. Seeing an unfamiliar formal name above a familiar one is normal, since reference taxonomies are revised and Kraken 2 reports whatever its database's copy of the taxonomy said.

Read the table downward. Every level carries almost the same clade count, which is what a single-organism sample looks like, and Direct is near zero at every level until the bottom, where the classifier committed 83,591 reads to SARS-CoV-2 itself. The one exception is the 65 reads sitting Direct at the Viruses domain row. Those are reads whose k-mers matched several unrelated viruses equally, so the lowest common ancestor of the candidates was the whole domain. A small Direct figure at a broad rank is ordinary, and it is the size relative to the clade count that matters, 65 out of 83,728 being nothing at all.

The row that is not in that table is the one to read next. Kraken 2 reports 1,471 reads, or 1.73%, as unclassified. Unclassified means the read found no match that the database, and the confidence threshold, would both accept. It is not an error and it is not noise. It is the classifier telling you where its knowledge ran out.

The Bracken column carries a second number for the species rows, and on this run it reads 83,645 for *Betacoronavirus pandemicum*, identical to the Reads figure. Bracken redistributes reads that Kraken 2 stopped at a broad rank down onto the species those reads most likely came from, using how the database's genomes overlap. It works at the species rank, so the 83,591 reads already sitting at the subspecies below are counted inside this species total rather than moved anywhere. When one species dominates so completely there is nothing left to redistribute, so the two numbers agree. On a mixed sample they will not agree, and the Bracken figure is the better estimate of what fraction of the sample each species actually was.

### Moving around the tree

A single click on a wedge selects it and syncs the table to it. A double-click re-centres the sunburst on that wedge, so double-clicking **Coronaviridae** redraws the chart with Coronaviridae at the middle and its children as the first ring out. The breadcrumb bar above the chart then shows the path back to the root, and clicking any earlier segment returns you there. Escape zooms out one level and Cmd-0 jumps straight back to the root. Both shortcuts go to the chart, so click the chart once before you use them, and neither one closes the window or the result.

<!-- SHOT: kraken2-drilldown-coronaviridae -->

Right-clicking a taxon offers Extract Reads..., Copy Taxon Name, Copy Taxonomy Path, Zoom to that taxon, Zoom Out to Root, a **Look Up on NCBI** submenu carrying NCBI Taxonomy, GenBank Sequences, PubMed Literature, and Genome Assemblies, and **BLAST Matching Reads...**, which is the per-row route into verification. Right-clicking the chart background instead offers **Copy Chart as PNG**, which puts a rendered image of the current sunburst on the clipboard.

The action bar above the viewport carries **Export**, which writes the whole table as CSV or TSV in depth-first order with the columns Name, Rank, Reads (Clade), Reads (Direct), Clade %, and Direct %, and also offers **Copy Summary** for the plain-text summary. Beside Export sits an information button, which opens the run's [provenance](../../GLOSSARY.md#provenance), listing the tool version, the database and where it sits on disk, the confidence and hit-group values, the thread count, whether memory mapping was used, the runtime, and the input files. That popover is what you copy into the methods section of a paper or a report, since it records exactly what was run against what. Two further buttons toggle side drawers, Collections for taxa you have set aside and BLAST Results for hits returned by verification, and [BLAST Verification](06-blast-verification.md) covers both.

### The same reads, a different database

Now open the Standard-16 result and read the same rows. This is the comparison the chapter exists for.

| Measure | Viral | Standard-16 |
|---|---|---|
| Reads classified | 83,728 (98.27%) | 3,320 (3.90%) |
| Unclassified | 1,471 (1.73%) | 81,879 (96.10%) |
| SARS-CoV-2 reads | 83,591 | 2,602 |
| Species reported | 1 | 1 |

The same 85,199 read pairs went in. The Viral database named 98% of them and the Standard-16 database named 4%. Nothing about the sample changed, and neither database is broken. Standard-16 is a capped database, squeezed from the full sixty-seven-gigabyte Standard collection down to sixteen by throwing away most of its reference fragments, meaning the short pieces of reference genome the index is built from, and what survives is spread thinly across archaea, bacteria, viruses, plasmids, the human genome, and vector sequence. The Viral collection spends its entire half-gigabyte on viruses alone, so it holds far more SARS-CoV-2 detail than the capped general database kept.

Two of those rows repay a second look. Species reported stayed at 1 even though Standard-16 named twenty-five times fewer reads, which tells you the capping cost detail rather than breadth. The database still knew what the organism was, and simply recognised far less of it. And the 718 reads Standard-16 classified beyond its 2,602 SARS-CoV-2 reads went to no second organism, because only one species was reported at all. They stopped at ranks above species, reads whose surviving k-mers were not specific enough to carry them all the way down.

The lesson generalises past this fixture. A capped database trades sensitivity for the ability to run at all, and the loss falls hardest on whatever the sample is actually full of, because capping discards fragments across the whole reference set evenly, and the organism supplying almost every read in the tube therefore loses the most matches in absolute terms. The loss scales with the cap, so Standard-8 would keep fewer fragments still and would name fewer of these reads than Standard-16 did. If you are screening an unknown sample, run the broad database to find out roughly what family you are dealing with, then run the specialist database for that family to get the detail. Running only the broad one and concluding the sample was mostly nothing is the mistake this comparison is here to prevent.

Note also what did not appear in either result. No human reads were reported by Standard-16, even though it contains the human genome and the sample came from a person. That is the amplicon protocol doing its job. PCR amplified the viral targets so heavily before sequencing that the human background was diluted below the level anything here would pick up. A shotgun library from the same swab, where no PCR enriched anything, would look completely different and would usually be dominated by human reads, which is what [host depletion](../../GLOSSARY.md#host-depletion) exists to remove.

### What the Sensitivity preset actually changes

Running the same 85,199 read pairs against the Viral database at all three presets shows what the control is doing. Every percentage below is a share of that total.

| Preset | Classified | Unclassified | Species reported |
|---|---|---|---|
| Sensitive | 85,181 (99.98%) | 18 (0.02%) | 5 |
| Balanced | 83,728 (98.27%) | 1,471 (1.73%) | 1 |
| Precise | 78,731 (92.41%) | 6,468 (7.59%) | 1 |

Precise threw away about 5,000 reads that Balanced was willing to name, and named nothing new for it. Sensitive named nearly everything and reported five species in total, four more than Balanced found, so it is worth looking at what those four were. One is *Sinsheimervirus phiX174* with 5 reads, which is a real thing to find, because phiX is a small virus that infects bacteria and is the standard Illumina [spike-in control](../../GLOSSARY.md#spike-in-control) added to sequencing runs, so a handful of its reads in a library is expected rather than alarming. The other three are two reads of a Vibrio phage, one of a frog adenovirus, and one of a picorna-like virus. Those three were judged chance k-mer matches rather than organisms in the tube on two grounds, that each rests on one or two reads where phiX rests on five, and that none of them has any route into a respiratory swab prepared with a SARS-CoV-2 amplicon kit.

That is exactly the trade the preset names. Sensitive found a real minor component that Balanced missed, and paid for it with three findings that are not real. On a single-read hit the report alone cannot settle which of the two you have, and the judgement above leaned on knowing what the sample was, so a report about an unknown sample would need the BLAST check the next section describes.

## What good looks like

Read the unclassified share first, before you look at any organism at all. It is the single number that tells you whether to trust the rest of the report. A low share, meaning under about 20%, means the database recognised your sample and the taxa below are worth reading. A high share, meaning over about half, means the database did not recognise your sample, and every taxon it did report is drawn from the small fraction it happened to match, so the percentages you are reading are shares of only the reads that matched rather than of the sample. On the reference run the Viral database left 1.73% unclassified, which is a report you can read straight. The Standard-16 run left 96.10% unclassified, which is a report telling you to change the database rather than a report about the sample.

Then check whether the dominant signal is the organism you expected. Sort the table by Reads descending and look at the top of the family or genus rank rather than at species, since that is the level a classifier reaches reliably. One taxon dwarfing everything else, as Coronaviridae does here at 98.20%, means the sample probably does contain that organism. Several taxa at comparable size means a genuinely mixed sample, and no clear peak at all usually means the database was wrong for this sample.

Then scan the long tail, and hold it to a rule you set before you looked, such as "I will follow up any taxon above 100 reads and ignore everything below it." Writing the rule down first stops you from raising the bar to dismiss an inconvenient hit or lowering it to keep an exciting one. Low-abundance hits are one of three things, and the report cannot tell you which. They are real minor components, such as the phiX spike-in above. They are mis-assignments from k-mers that unrelated organisms happen to share. Or they are contamination, either from the laboratory or from stray sequence inside the reference database itself. Under about ten reads against an unrelated taxon is usually noise, and a hundred reads is a sensible place to put the line on a library this size, since a few thousand is clearly worth investigating. Between those, the honest answer is that you do not know yet, and the way to find out is to extract that taxon's reads and BLAST them, meaning search them against the whole of NCBI's sequence collection to see what they actually resemble, which [BLAST Verification](06-blast-verification.md) covers.

Finally, remember what Kraken 2 confidence measures. The confidence threshold asks what fraction of a read's k-mers agree with the assignment, so it is a measure of internal consistency against the database and nothing more. It says how well the read fits the entry it was matched to, and says nothing about whether that entry was the right one to match, or how many unrelated sequences would have fitted about as well. A read with perfect k-mer agreement to one database entry can still turn out to be a poor match to anything real, if that entry is itself short, divergent, or wrongly labelled. Kraken 2 is a screening step. When a hit matters, verify it.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the dialog cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application. The classification subcommand sits under `conda`, because it runs a conda-installed tool rather than an LGE-native one.

```bash
lungfish-cli conda classify \
  SRR36291587_1.fastq SRR36291587_2.fastq \
  --paired --db Viral --profile \
  --output-dir ./kraken2-viral
```

`--paired` treats the two files as the two mates of the same fragments, `--db` names the database, and `--profile` runs Bracken afterwards. That last flag matters, because the dialog always runs Bracken and the command line does not, so a command without `--profile` gives you a classification with no abundance re-estimation and no Bracken column in the viewport, the one described in the Settings section above. That is the only difference between the two routes, since every other control the dialog offers reaches the command line as a flag and defaults to the same value. The command writes `classification.kreport`, a compressed per-read `classification.kraken.gz`, and `classification.bracken` into the output directory, alongside a provenance sidecar. The `.kreport` is the [kreport](../../GLOSSARY.md#kreport) file, the per-taxon summary the viewport reads. Kraken 2 writes six columns by default, and LGE always asks for two extra k-mer columns, so a report LGE produced holds eight. The `.kraken` file is the per-read record of what each individual read was assigned to.

The dialog's controls all reach the command line. `--preset sensitive|balanced|precise` sets Sensitivity, `--confidence` and `--min-hit-groups` override the two numbers behind it, `--threads` sets the thread count, `--memory-mapping` runs the database from disk, and `--extra-args` forwards raw text to Kraken 2. Three further flags have no counterpart in the dialog. `--quick` stops examining a read as soon as one taxon matches, which is faster and less careful. `--recursive` picks up eligible FASTQ or FASTA files inside subfolders when an input is a folder. And `--bracken-read-length`, `--bracken-level`, and `--bracken-threshold` tune the Bracken step, defaulting to 150, automatic for the selected database, and 10 respectively, which are the values the dialog always uses.

One failure is worth knowing about in advance. When the database matches nothing at all in your reads, the run stops with an error reading `Empty Kraken2 report` rather than reporting a result that is 100% unclassified. Kraken 2 itself finishes and writes its report. What fails is LGE reading that report back, which finds no classified taxon in it and stops there, before the Bracken step ever runs. The command also exits with status 64, which is a numeric code meant for scripts that want to test whether a command worked, and you can ignore it if you are typing commands by hand. The reference run reproduced this by classifying these viral amplicon reads against the SILVA ribosomal database, which holds no viruses and therefore matched nothing. Treat that error as the strongest possible version of a high unclassified share, meaning the database was wrong for the sample, and rerun with a database that covers what you are looking for.

Databases have their own subcommands under `conda db`.

```bash
lungfish-cli conda db list
lungfish-cli conda db recommend
lungfish-cli conda db download Viral
lungfish-cli conda db info Viral
lungfish-cli conda db update --all --yes
```

`list` prints every catalogued database with size, memory, install state, and update status. `recommend` names the largest general-purpose collection that fits comfortably in this machine's memory, which is the same choice the Databases tab banner shows. `download` installs one and `info` reports the installed version of one. `update` replaces installed databases with their pinned versions and requires `--yes`, either for one name or with `--all`. `remove <name>` drops a database, and `--delete-files` erases the index from disk rather than only unregistering it. A separate `conda db install-managed` handles the helper datasets used for host and ribosomal read removal rather than for classification, and `conda db install-managed --list` prints their identifiers.

Extracting a taxon's reads is its own command, which takes the result directory rather than a single file.

```bash
lungfish-cli extract reads --by-classifier --tool kraken2 \
  --result ./kraken2-viral --taxon 2697049 \
  --source SRR36291587_1.fastq \
  --output sars-reads.fastq
```

`--taxon` takes the numeric taxonomy identifier, which the kreport's seventh column holds, one row per taxon. The viewport's Copy Taxonomy Path does not give you that number. It copies the chain of names down to the taxon, such as `Viruses > Coronaviridae > Betacoronavirus`, and Copy Taxon Name copies the name alone. Read the number out of the kreport's seventh column, or right-click the row and choose **Look Up on NCBI > NCBI Taxonomy**, which opens that taxon's NCBI page with the number in the address bar. `--read-format fastq|fasta` chooses the output format, matching the dialog's Format picker. The `--include-unmapped-mates` flag exists for the alignment-backed classifiers and is rejected with `--tool kraken2`, exactly as the dialog hides that checkbox. On the reference run this command extracted 83,591 read pairs, written as 167,182 read records, since each pair is two records in the file.

Two neighbouring commands finish the headless path. `lungfish-cli import kraken2 <kreport-file>` brings a Kraken 2 report generated elsewhere into a project so the viewport can read it. `lungfish-cli build-db kraken2 <result-dir>` builds a SQLite index over an existing Kraken 2 result directory so the viewport can query it quickly, taking `--force` to overwrite, `--no-cleanup` to keep intermediates, and `--sample-dir` to name one sample directory at a time. That second command builds an index of a result, not a Kraken 2 classification database, and LGE offers no route to build one of those at all. Building a custom Kraken 2 database is done with Kraken 2's own tools outside LGE, and LGE offers no supported way to register the finished index so that the Database picker will list it.

## Next

Continue to [Running EsViritu](03-running-esviritu.md) for a viral-specialist classifier that also reports how much of each virus's genome your reads covered. Reach for it after Kraken 2 rather than instead of it, once a screen has told you the sample is viral and you want to know how completely each virus is represented. Or go to [BLAST Verification](06-blast-verification.md) to check a Kraken 2 hit against NCBI before you believe it.
