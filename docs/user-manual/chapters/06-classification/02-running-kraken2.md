---
title: Running Kraken 2
chapter_id: 06-classification/02-running-kraken2
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 25
task: Classify a FASTQ bundle with Kraken 2 against an installed database, read the taxonomy viewport, and pull the reads of one taxon out as a new bundle.
tags: [classification, kraken2, bracken, taxonomy, sunburst, extraction]
tools: [kraken2, bracken]
parameters_refs: [classify.kraken2, classify.taxonomy-browser, classify.extract-reads-by-taxon]
entry_points:
  - "Tools > Classification > Kraken2..."
  - "CLI: lungfish-cli conda classify"
shots:
  - id: kraken2-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > Kraken2..., with the dataset line naming Imports/SRR12486983.lungfishfastq, the Database picker on Viral with its description and recommended memory, and the Sensitivity control on Balanced."
  - id: kraken2-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the Confidence slider, the Min hit groups stepper, the Threads stepper, the Memory mapping checkbox, and the Extra arguments field."
  - id: kraken2-taxonomy-viewport
    caption: "The taxonomy viewport after classifying SRR12486983 against the Viral database, with the sunburst on the left and the per-taxon table on the right showing its Filter taxa... field and taxa count."
  - id: kraken2-drilldown-orthoherpesviridae
    caption: "The sunburst re-centred on Orthoherpesviridae after a double-click, with the breadcrumb bar showing the path back to the root."
  - id: kraken2-extract-reads
    caption: "The right-click menu on the Orthoherpesviridae row, listing Extract Reads... above the Expand and Collapse items, BLAST Matching Reads..., the Look Up on NCBI submenu, and Copy Taxon Name."
illustrations: []
glossary_refs: [accession, blast, bracken, bundle, capped-database, checksum, clade, clade-count, fastq, host-depletion, inspector, interleaved-fastq, k-mer, kraken2, kreport, lowest-common-ancestor, metagenomics, minimizer, operations-panel, paired-end, plugin-pack, provenance, read, read-classification, shotgun, sra, taxon, taxonomic-rank, taxonomy-id]
features_refs: []
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

[Kraken 2](../../GLOSSARY.md#kraken2) is a program that reads a [FASTQ](../../GLOSSARY.md#fastq) file one [read](../../GLOSSARY.md#read) at a time and writes down, for each read, which organism it most likely came from. The answer is a [taxon](../../GLOSSARY.md#taxon), any named group on the tree of life, so *Homo sapiens*, *Macaca mulatta*, and the herpesvirus family *Orthoherpesviridae* are each one taxon. Do that for every read in a file and you have a census of what was in the tube.

Kraken 2 matches short words rather than aligning whole sequences. Aligning means lining two sequences up base by base and scoring them, which is accurate and slow. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases taken from a longer sequence, so `ACGTA` holds three 3-mers, `ACG`, `CGT`, and `GTA`. A sliding window is a fixed-width stretch of the read, a few dozen bases across, that starts at the first base and moves along one base at a time. A [minimizer](../../GLOSSARY.md#minimizer) is the smallest k-mer inside one window, where smallest means first in a fixed sort order the program applies, and it stands in as a compact fingerprint of that whole window.

Kraken 2 slides the window along each read, takes the minimizer at each position, and looks it up in a prebuilt database that records which taxon every minimizer belongs to. The taxon with the most support wins the read, provided it clears the confidence threshold described under Settings. That threshold is written in terms of the read's k-mers, because each minimizer stands in for the k-mers of its window. A table lookup is far quicker than an alignment, which is why a run takes seconds. It is also why the answer is exactly as good as the database and no better, a point the rest of this chapter returns to.

When a read fits several relatives equally, Kraken 2 reports their [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) instead of guessing, as [What Is Read Classification](01-what-is-classification.md#what-it-is) explains. A Kraken 2 report therefore has counts sitting at every [rank](../../GLOSSARY.md#taxonomic-rank) at once, not only at species.

Lungfish Genome Explorer (LGE) labels the tool **Kraken2** in its menus. Every run LGE starts is two programs. Kraken 2 assigns the reads, and then [Bracken](../../GLOSSARY.md#bracken) re-estimates each species' abundance, meaning its share of the sample, by pushing reads that Kraken 2 left at a broad group down onto the species they most likely came from. The result opens in the taxonomy viewport, a sunburst chart beside a table of taxa.

## Why you would do this

Run Kraken 2 whenever you do not already know, or cannot yet prove, what is in a sequencing library. A clinical swab from a person or a macaque is the obvious case, where most reads are host and the pathogen sits somewhere in the rest. The less obvious cases come up more often. A library you believe is one organism may be a mislabelled tube or a cross-contaminated plate, and the two look identical until something counts the reads. A low-yield run may mean the target is scarce or that the sample is mostly host DNA. And before a week of genome assembly, it pays to know how much of the data even comes from the organism you meant to assemble.

This chapter works through run SRR12486983, the pathogen-identification example in the Kraken authors' protocol paper, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y), *Nature Protocols* 17, 2815. The reads come from the cornea, the clear front surface of the eye, of a person with herpes simplex keratitis, an eye infection caused by herpes simplex virus 1 (HSV-1). The tissue was preserved in formalin, a fixative that keeps tissue intact but damages its DNA, and sequenced on an Illumina NextSeq 550 as a [shotgun](../../GLOSSARY.md#shotgun) library, which reads whatever DNA the tissue held rather than copying one chosen target first. The study recorded HSV-1 as the organism, so you know the right answer before you start and can see plainly what each database finds, what it misses, and what else turns up.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Pathogen Detection demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR12486983` as the bundle described below, so the SRA download is done. To fetch the run yourself instead, follow the rest of this section.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for this chapter's practice data. Its only data is run `SRR12486983`, which you download from the [Sequence Read Archive](../../GLOSSARY.md#sra), following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). It imports as one [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, named `Imports/SRR12486983.lungfishfastq` and holding 4,819,760 read pairs. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/kraken-protocol-cornea, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries Kraken 2 and Bracken.

The counts in this chapter came from Kraken 2 version 2.17.1 and Bracken version 3.0.1 with the builds of the Viral and Standard-16 databases dated 26 June 2026, which LGE labels 20260626. A different tool or database build can move a few reads, so expect your counts to sit close to these rather than match them digit for digit.

## Procedure

The worked example classifies the same reads twice, once against a small viral database and once against a general one, because the difference between the two answers is the most useful thing this chapter teaches.

### 1. Download Viral and Standard-16

A Kraken 2 database decides which answers are possible at all. A database holding only viruses cannot report a bacterium, however much bacterial sequence the library holds, and reports those reads as unclassified instead.

Download the Viral database from the Databases tab of the Plugin Manager, which **Tools > Plugin Manager...** opens, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. Then download the Standard-16 database the same way. Viral needs about half a gigabyte of memory and fits any Mac LGE supports. Standard-16 is a [capped database](../../GLOSSARY.md#capped-database), the full Standard collection shrunk to fit a machine with 16 GB of memory by keeping only a sample of its minimizers. Kraken 2 loads the whole database into memory before it classifies a single read, so on a Mac with less than 16 GB take Standard-8 instead and expect it to recognise fewer reads still. To see how much memory your Mac has, choose **Apple menu > About This Mac**.

### 2. Open the dialog and choose a database

1. Click the FASTQ bundle SRR12486983 in the sidebar, the list down the left of the window, under `Imports`.

2. Choose **Tools > Classification > Kraken2...**. The FASTQ/FASTA Operations dialog opens with Kraken2 selected in its tool sidebar, and the dataset line at the top names the bundle going in. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, where each read is followed by its mate. Kraken 2 classifies the two mates of a pair together as one fragment, so the SRR12486983 bundle goes in as 4,819,760 read pairs, and every count in this chapter is a count of pairs.

3. Open the **Database** picker, which lists only databases that finished downloading, each with its size on disk. Choose **Viral**. If nothing is installed, the picker is replaced by "No databases installed." and a **Download Database...** button that opens the Plugin Manager on its Databases tab.

    <!-- SHOT: kraken2-dialog -->

4. Leave **Sensitivity** on **Balanced** and leave **Advanced Settings** collapsed. The three-way control fills in two numbers inside that section for you, Confidence and Min hit groups, and Settings below explains them. The picture shows the section opened only so you can see those numbers.

    <!-- SHOT: kraken2-advanced-settings -->

If you selected several bundles, the dialog also shows **Run Mode**, locked on "Run separately per bundle". The selection runs as one classification batch with a single Operations Panel row and one merged summary, and each sample is still classified on its own inside it.

### 3. Run it and find the result

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A single-sample row is titled "Profiling" plus the input file name, because the dialog always classifies and then profiles with Bracken. A multi-sample run is titled `Classification Batch (N samples)`. Expect the Standard-16 run to take longer than the Viral run, most of all the first time LGE reads the large database off disk.

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Its name starts with `kraken2-`, so a second run never overwrites the first. Click the new folder in the sidebar and the taxonomy viewport opens.

<!-- SHOT: kraken2-taxonomy-viewport -->

Now click the reads bundle again, reopen the dialog, choose **Standard-16** instead of Viral, and click **Run**, so you have both results for Reading the results. The newer `kraken2-` folder is the Standard-16 run. Right after each run, its Classification Provenance popover names the database it used, as [The action bar and the provenance popover](#the-action-bar-and-the-provenance-popover) describes.

### 4. Extract the reads of one taxon

Once you have found the taxon you care about, you usually want its reads rather than its count, to map them to a reference, assemble them, or check them with [BLAST](../../GLOSSARY.md#blast). On the worked example that taxon is HSV-1, which the table names by its species, *Simplexvirus humanalpha1*.

1. In the Viral result, type `humanalpha1` in the **Filter taxa…** field above the table, then click the *Simplexvirus humanalpha1* row. Selecting its wedge in the sunburst works too.

2. Click **Extract FASTQ** in the action bar, the strip of buttons along the bottom of the viewport. Right-clicking the row or wedge and choosing **Extract Reads...** opens the same dialog. The picture shows that menu on the Orthoherpesviridae row, and every taxon row carries the same menu.

    <!-- SHOT: kraken2-extract-reads -->

3. The Extract Reads dialog reads `Selected: 1 row` and gives an estimate of the reads the selection holds, `≈ 886,221 unique reads` on the worked example. It is the row's clade count, so it counts pairs, as the rest of this chapter does. Leave **Format** on FASTQ and **Destination** on Save as Bundle. The **Name** field arrives filled in as `kraken2_Simplexvirus_humanalpha1`.

4. Click **Create Bundle**, which is what the run button reads while Save as Bundle is the destination.

The new bundle appears in the project's top-level `Extractions` folder. It holds the reads assigned to the selected taxon and to every taxon beneath it, so extracting at a family row takes every genus and species in that family too. The bundle holds both mates of every pair, so on the worked example it held 1,772,442 reads, two for each of the 886,221 pairs. LGE adds a date, a time, and a short code to the name you left unchanged, so look for a bundle whose name starts with `kraken2_Simplexvirus_humanalpha1-`. Selecting several rows before clicking Extract FASTQ writes their reads into one bundle.

## Settings

Several bold labels below end in a colon followed by a period, because they keep the colon the app draws after each label on screen.

### The classification dialog

**Database.** Names the reference collection every read is compared against, and so fixes which answers are possible, since a read can only be given a name the database holds. The default is the first installed database that finished downloading, an arbitrary choice, so always look at it before you run. Pick a small collection such as Viral when you already know which family you are hunting, and a Standard or PlusPF collection for an unbiased survey, PlusPF being Standard plus protozoa and fungi. On the command line this is `--db`.

**Sensitivity.** Sets the Confidence and Min hit groups values together, trading how many reads get a name against how often that name is right. The default is Balanced, confidence 0.20 with 2 hit groups, against Sensitive at 0.00 with 1 and Precise at 0.50 with 3. Move to Precise when a false positive would be costly, such as reporting a pathogen, and to Sensitive when you are hunting something rare and will check every hit by hand. On the command line this is `--preset`.

**Run Mode.** Shows how several selected bundles are handled, and appears only when you selected more than one. It is locked on "Run separately per bundle (N results)", with "Combine all inputs, run once (1 result)" greyed out, because pooling reads across samples before classification would mix up the per-sample abundances. There is nothing to change, so read the lock reason and move on. This setting has no command-line flag.

**Confidence:.** Sets the fraction of a read's k-mers that must point at a taxon before Kraken 2 commits to that name, so 0.20 means at least a fifth. The default is 0.20, set by Balanced, and the slider and its typed number field run from 0.00 to 1.00 in steps of 0.05. Raise it when the report is full of implausible species, and lower it when too many reads come back unclassified, remembering that a read failing the test at one taxon is moved up to a broader group, and becomes unclassified only when no group, however broad, passes. On the command line this is `--confidence`.

**Min hit groups:.** Sets how many separate database hits a read must have before Kraken 2 names it at all, where a hit group is a run of overlapping k-mers that share one minimizer found in the database, on the reasoning that two independent chance matches are much rarer than one. The default is 2, and the stepper accepts 1 to 10. Raise it when short repeated sequence produces calls you do not believe, and lower it for very short reads that cannot hold two separate matches. On the command line this is `--min-hit-groups`.

**Threads:.** Sets how many processor cores Kraken 2 uses at once. The default is 4, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Memory mapping:.** Reads the database from disk in pieces instead of loading it whole into memory, so the database no longer has to fit in RAM and the run is much slower. It is off by default, which is right for every database that fits your memory. The dialog ticks it for you when you pick a database larger than your Mac's memory, with a banner naming the gigabytes required and the gigabytes you have. On the command line this is `--memory-mapping`.

**Extra arguments:.** Passes text straight to Kraken 2 without LGE checking it. The default is empty, which is right for almost every run. Use it only for a Kraken 2 option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

### The taxonomy viewport

These controls change what you are looking at, not what was computed.

**Filter taxa….** Shows only the rows whose sample, name, rank, read counts, or percentage contain what you type, together with each match's parent taxa and everything beneath it, and dims the sunburst wedges that no longer match. It is empty by default, showing everything. Use it whenever you are hunting one organism in a report of thousands of rows. This setting has no command-line flag.

**Bracken.** Is a column rather than a control, holding the species counts Bracken re-estimated. It appears on its own whenever the result carries Bracken numbers, which every dialog-started run does, and stays hidden on a result made without Bracken. There is nothing to set, so read it when it is there. This setting has no command-line flag.

**Select All.** Ticks or unticks every sample visible in the Sample Filter list, in the Inspector's Samples & Metadata section. It starts ticked, because every sample is shown at first. Use it to clear the list and then tick the few samples you want, rather than unticking twenty by hand. This setting has no command-line flag.

**Filter….** Narrows the sample picker's list to names containing what you type, changing which samples you can tick rather than which are ticked. It is empty by default. Use it on a many-sample run to reach one plate or one collection date. This setting has no command-line flag.

**Column header filter.** Restricts one column to rows matching a value or numeric range you set from the menu that opens when you click that column's header, and several column filters apply together. No column carries a filter at first. Use it to hold the table to species rank, or to rows above a read count you consider worth reading. This setting has no command-line flag.

### The Extract Reads dialog

**Format:.** Chooses whether the extracted reads keep their per-base quality scores, as FASTQ, or come out as sequence only, as FASTA. The default is FASTQ, which loses nothing. Choose FASTA when the next tool wants sequence alone, such as a BLAST submission. On the command line this is `--read-format`.

**Include unmapped mates of mapped pairs.** Also pulls out the partner of any pair where only one read landed on the selected reference, with the dialog showing how many reads that adds. It is off by default, and it is hidden on a Kraken 2 result, because Kraken 2 produces no alignment for it to work from. Turn it on for the classifiers that align reads, EsViritu, TaxTriage, NAO-MGS, and NVD, when you plan to assemble or map the extracted reads. On the command line this is `--include-unmapped-mates`.

**Destination:.** Chooses where the reads go, offering Save as Bundle, Save to File..., Copy to Clipboard, and Share.... The default is Save as Bundle, which puts them in your project as a new bundle you can run other tools on. Choose Save to File when the reads are going to another program, and Copy to Clipboard only for a handful of reads, since it is disabled above 10,000 reads and its tooltip then asks you to pick another destination. On the command line this is `--output`.

**Name:.** Names the bundle or file that gets written, and appears only for Save as Bundle and Save to File. It arrives filled in as `kraken2_` plus the taxon name, LGE adds a timestamp to the bundle name if you leave it unchanged, and it cannot be left blank. Change it when the suggested name will not tell you what the reads are six months from now. On the command line this is `--bundle-name`.

## Reading the results

The taxonomy viewport stacks five parts. Along the top, a row of summary cards reports Total Reads, Classified, Unclassified, Species, Shannon H′, and Dominant when the run has just finished. When you reopen the result from the sidebar, the cards read Batch, Samples, Taxa, and Database instead. Shannon H′ is the Shannon diversity index, one number for how evenly reads spread across species, which is 0 when a single species holds them all and grows as the mix evens out. Dominant names the species with the most reads. For the worked example's Viral run, Dominant names *Simplexvirus humanalpha1* and Shannon H′ reads 0.011, close to the single-species floor. Below the cards runs the breadcrumb bar, naming the part of the tree the sunburst is centred on. The middle holds the sunburst on the left and the table on the right. The action bar runs along the bottom.

The sunburst draws the root at the centre and one ring per level of the tree outward, so a rank Kraken 2 reports between the standard ones, such as a realm between the root and a kingdom, like Duplodnaviria, or a subfamily between a family and a genus, like Alphaherpesvirinae, takes a ring of its own. Each wedge is sized by its share of the classified reads, and the centre states which denominator its percentage uses, all reads for the whole tree and classified reads once you zoom in. Taxa too small to draw are pooled into a paler wedge in their parent's colour, and hovering it names how many taxa and reads it holds. The table lists the same taxa as rows under the columns Sample, Taxon Name, Rank, Reads, Direct, Bracken, and **%**. Sample names which input a row came from, SRR12486983 here, and matters only on a multi-sample run. Rank is the taxon's level, such as family, genus, or species. A count beside the **Filter taxa…** field reports how many taxa the table holds while the field is empty.

Two columns are easy to confuse, and everything else depends on telling them apart. **Reads** is the [clade count](../../GLOSSARY.md#clade-count), every read assigned to that taxon or to anything below it, a [clade](../../GLOSSARY.md#clade) being a taxon with all its descendants. **Direct** counts only the reads assigned to that exact taxon and no lower. A family row with a large Reads figure and a Direct figure near zero means the classifier carried almost every read further down, which is healthy. A family row whose Direct figure is a large share of its Reads means the classifier stopped there, either because the reads cannot be resolved further or because the database holds nothing more specific. The **%** column is the Reads figure as a share of every read in the sample, unclassified reads included.

The first figures to read are the totals. Of the 4,819,760 pairs, the Viral database classified 893,706 (18.54%), every one of them under Viruses, and left 3,926,054 (81.46%) unclassified. Unclassified means a read found no match that the database and the confidence threshold would both accept. A database of viruses can only name viruses, so every human or bacterial read in the tissue lands there too, and a large unclassified share is expected from this database.

Here are five of the rows on the path from Viruses to HSV-1 in the Viral result, running from the family through the subfamily, genus, and species to the named virus, with the ranks between Viruses and the family left out. The **%** figures are shares of all 4,819,760 pairs.

| Taxon | Reads | % |
|---|---|---|
| Orthoherpesviridae | 893,154 | 18.53 |
| Alphaherpesvirinae | 893,152 | 18.53 |
| Simplexvirus | 893,039 | 18.53 |
| *Simplexvirus humanalpha1* | 886,221 | 18.39 |
| Human alphaherpesvirus 1 | 886,221 | 18.39 |

*Simplexvirus humanalpha1* is the formal species name the virus taxonomy now gives HSV-1, and the familiar name, Human alphaherpesvirus 1, sits one level below it with [taxonomy ID](../../GLOSSARY.md#taxonomy-id) 10298. Viral taxonomy routinely names a species that holds familiar viruses as members, so a familiar name below an unfamiliar one is the convention, not a mistake.

Read the table downward. Nearly every classified read in the sample sits inside the herpesvirus family, and the clade count barely drops from the family to the species, which is what one dominant virus looks like. The Direct column shows where the reads stopped. At the genus row *Simplexvirus*, Direct is 6,789. Those pairs matched several simplexviruses equally, such as HSV-1 and its close relatives, so their lowest common ancestor was the genus. The genus total of 893,039 is those 6,789, the 886,221 HSV-1 pairs, and 29 pairs on two relatives described below. At the species row Direct is 0, and at Human alphaherpesvirus 1 it is 886,221. The database files HSV-1 genomes under that name, one level below the species, so any read specific to HSV-1 lands there rather than on the species itself. Kraken 2's report files that level as a subspecies. A small Direct figure at a broad rank is ordinary, and only its size relative to the clade count matters.

The Bracken column fills in on species rows. Bracken works at the species rank, so it hands the 6,789 genus-level pairs down to the species they most likely came from. The Bracken figure for *Simplexvirus humanalpha1* is 893,009, higher than its Reads figure of 886,221 by almost exactly those 6,789 pairs, and 99.98% of all the reads Bracken assigned to a species. Bracken's figures appear on species rows only, so the Human alphaherpesvirus 1 row has none. On a sample of several species the Bracken figure is the better estimate of each species' share.

### Small hits beside a big one

Kraken 2's report lists a few small rows beside HSV-1, which you see in the table once you clear the **Filter taxa…** field and choose **Expand All** from a row's right-click menu. *Simplexvirus paninealpha3*, the chimpanzee herpesvirus, holds 28 pairs. *Macacine alphaherpesvirus 1*, the B virus of macaques, holds 1 pair. Outside the herpesviruses, 402 pairs fall under Uroviricota, a group of phages, the viruses that infect bacteria, 66 of them in Pahexavirus, a genus of phages that infect the skin bacterium *Cutibacterium acnes*.

The two herpesvirus rows are the usual shadow of a large signal. Reads from stretches that HSV-1 and its relatives share exactly go to the genus, as the 6,789 did. The chimpanzee virus is HSV-1's closest known relative, and with 886,221 HSV-1 pairs in the sample, a few dozen reads from places where this patient's virus differs from the HSV-1 reference are expected to match the relative slightly better. One pair against B virus falls under the ten-read rule of thumb in [What good looks like](#what-good-looks-like), so treat it as noise unless BLAST says otherwise. The phage reads may be real, since the bacterium they infect is a common skin bacterium that [the Standard-16 run](#the-same-reads-a-different-database) finds in this sample, but the report cannot prove it. Check any small hit that matters with [BLAST Verification](06-blast-verification.md).

### Moving around the tree

A single click on a wedge selects it and selects the same row in the table, and the reverse works too. A double-click re-centres the sunburst on that wedge, so double-clicking **Orthoherpesviridae** redraws the chart with Orthoherpesviridae in the middle, its label naming Orthoherpesviridae with about 893 thousand reads, and its children as the first ring out. The breadcrumb bar then shows the path back to the root, Root > Viruses > Duplodnaviria > Heunggongvirae > Peploviricota > Herviviricetes > Herpesvirales > Orthoherpesviridae. The names between Viruses and the family are the upper ranks of virus taxonomy, from realm down to order. Clicking an earlier segment returns you there. Clicking the centre circle, or pressing Escape, zooms out one level, and Cmd-0 jumps back to the root. The shortcuts go to the chart, so click it once before you use them.

<!-- SHOT: kraken2-drilldown-orthoherpesviridae -->

Right-clicking a wedge offers Extract Reads..., Copy Taxon Name, Copy Taxonomy Path, Zoom to that taxon, Zoom Out to Root, a **Look Up on NCBI** submenu with NCBI Taxonomy, GenBank Sequences, PubMed Literature, and Genome Assemblies, and **BLAST Matching Reads...**. Right-clicking a table row offers Extract Reads..., Expand, Expand All Below, Collapse, Expand All, Collapse All, BLAST Matching Reads..., a **Look Up on NCBI** submenu, and Copy Taxon Name. Right-clicking empty chart space offers **Copy Chart as PNG**, which puts an image of the current sunburst on the clipboard.

### The action bar and the provenance popover

The action bar along the bottom carries, from the left, these controls:

- **BLAST Verify** sends a sample of the selected taxon's reads to NCBI, and needs exactly one row selected.
- **Export** offers Export as CSV..., Export as TSV..., Copy Summary, and Show Provenance.... A file export holds the columns Name, Rank, Reads (Clade), Reads (Direct), Clade %, and Direct %, one row per taxon in tree order, followed by one row for the unclassified reads.
- **Extract FASTQ** opens the Extract Reads dialog for the selection, as step 4 showed.
- **Collections** and **BLAST Results** toggle side drawers. A collection is a named set of taxa extracted together, each to its own file, such as the built-in Respiratory Viruses set. [BLAST Verification](06-blast-verification.md) covers both drawers.

A line of text after the buttons names the selected taxon with its read count and percentage. Right after a run, the information button at the right end opens the Classification Provenance popover, which lists the Kraken 2 version, the database and its folder on disk, the Confidence and Hit Groups values, the thread count, whether memory mapping was on, the runtime, the input files, a Bracken row when Bracken ran, and a short run ID. That popover is what you copy into a methods section. On a result reopened from the sidebar the button does nothing, so read the same values in the Inspector instead. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

### The same reads, a different database

Now open the Standard-16 result and read the same rows. This is the comparison the chapter exists for.

| Measure | Viral | Standard-16 |
|---|---|---|
| Reads classified | 893,706 (18.54%) | 343,324 (7.12%) |
| Unclassified | 3,926,054 (81.46%) | 4,476,436 (92.88%) |
| All viruses | 893,706 (18.54%) | 104,172 (2.16%) |
| Human alphaherpesvirus 1 | 886,221 (18.39%) | 89,294 (1.85%) |
| Bacteria | none possible | 219,636 (4.56%) |
| *Homo sapiens* | none possible | 13,252 (0.27%) |

The same reads went in. The Viral database named 886,221 pairs as HSV-1, and Standard-16 named 89,294, about a tenth as many. Nothing about the sample changed, and neither database is broken. Standard-16 is a [capped database](../../GLOSSARY.md#capped-database), squeezed from the full Standard collection of about 67 GB by keeping only a sample of its minimizers, and what survives is spread thinly across archaea, bacteria, viruses, plasmids, the human genome, and cloning-vector sequence. The Viral collection spends all its space on viruses, so it keeps far more HSV-1 detail. Standard-16 still found the right virus, but it recognised only a small share of that virus's reads. The classified pairs the table leaves out stopped at the root of the tree or at cellular organisms, or fell in small groups such as Archaea.

Neither 18.39% nor 1.85% is the true share of HSV-1 in the tissue. Each counts only the reads a database could recognise, measured against all 4,819,760 pairs, so each is a floor. The Viral figure is the closer one, because the Viral database holds far more HSV-1 sequence. The Viral database can only answer a virus or unclassified, but the confidence threshold stops it naming a read on a weak match, so a human or bacterial read stays unclassified rather than being called HSV-1.

Standard-16 also answered questions the Viral database cannot ask. It placed 219,636 pairs under Bacteria. The table below lists the largest bacterial species.

| Species | Reads |
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

Read the unclassified share first, on the Unclassified card right after the run, before you look at any organism. A reopened result does not show that card, so note the figure when the run finishes, or read the first line of the `classification.kreport` file in the result folder, which counts the unclassified reads. It tells you how much of the sample the report speaks for, and you read it against what the database holds. On a broad database such as Standard-16, under about 20% means the database recognised your sample and the taxa are worth reading. Between 20% and half, read the taxa with care, since a large part of the sample is unaccounted for. Over about half means the database did not recognise most of the sample, and every percentage you read describes only the small fraction it happened to match. On a specialist database such as Viral, a large unclassified share is expected, because every read from outside that group lands there, so read the classified reads instead. The two runs in this chapter both leave most pairs unclassified. The Viral result still answers its narrow question plainly. The Standard-16 result, at 92.88% unclassified, speaks for only a small part of the sample, so treat its percentages as a partial view rather than a census.

The extreme case is a database that matches nothing at all. The run then stops with the error `Empty Kraken2 report` instead of showing a result that is 100% unclassified. Treat it as the database being wrong for the sample and rerun with one that covers what you are looking for.

Then check whether the dominant signal is the organism you expected. Click the Reads column header and choose **Sort Descending** from the menu that opens, and look at family or genus rather than species, since that is the level a classifier reaches reliably. One taxon dwarfing everything else, as Orthoherpesviridae does in the Viral result, means the sample probably contains it. Several taxa of comparable size mean a mixed sample, and no clear peak usually means the wrong database.

Then read the long tail against a rule you set before you looked, such as "check any taxon above ten reads with BLAST". Writing the rule first stops you raising the bar to dismiss an inconvenient hit or lowering it to keep an exciting one. A low-abundance hit is a real minor component, a mis-assignment from k-mers that related or unrelated organisms share, or contamination from the laboratory or from stray sequence inside the reference database, and the report cannot tell you which. Under about ten reads is usually noise, whether the taxon is a relative of the main organism, like the single B virus pair here, or unrelated to it. Between that and a few thousand, extract the taxon's reads and search them against NCBI, as [BLAST Verification](06-blast-verification.md) explains. Above a few thousand the taxon is plainly present in the reads, and BLAST is still worth running to confirm which organism it is.

Finally, remember what the confidence score measures. It asks what fraction of a read's k-mers agree with the assigned taxon, so it measures fit to one database entry and nothing more. It says nothing about whether that entry was the right one, or how many other sequences would have fitted as well. A read that agrees perfectly with a short, divergent, or mislabelled entry is still a poor match to anything real. Kraken 2 is a screening step, so verify any hit that matters.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
# Work from inside the project, a folder whose name ends in .lungfish.
cd ~/Documents/MyProject.lungfish

# Classify against Viral, then Standard-16, running Bracken as the dialog does.
lungfish-cli conda classify Imports/SRR12486983.lungfishfastq \
  --db Viral --profile --output-dir ./kraken2-viral
lungfish-cli conda classify Imports/SRR12486983.lungfishfastq \
  --db Standard-16 --profile --output-dir ./kraken2-standard16

# Extract the HSV-1 reads (NCBI taxonomy ID 10298) and everything below it.
lungfish-cli extract reads --by-classifier --tool kraken2 \
  --result ./kraken2-viral --taxon 10298 \
  --output hsv-1.fastq --bundle-name "HSV-1 reads"
```

Run these lines in the Terminal application. `cd` moves Terminal into a folder, and `~` stands for your home folder. The last command writes a bundle, because `--bundle-name` implies one. The dialog always runs Bracken and the command line does not, so a command without `--profile` gives a classification with no Bracken column. Given a bundle, the default `--read-format auto` finds the alternating mates in its interleaved file and classifies them as pairs, as the dialog does. Given the two downloaded files instead, such as `SRR12486983_1.fastq.gz` and `SRR12486983_2.fastq.gz`, add `--paired`. The `extract reads` command has its own `--read-format` flag, which there chooses FASTQ or FASTA. `--taxon` takes the numeric taxonomy ID rather than a name, and right-clicking a row and choosing **Look Up on NCBI > NCBI Taxonomy** opens the taxon's NCBI page, which shows it. Taxonomy ID 10298 is the Human alphaherpesvirus 1 row, which holds every read of its species in this result.

## Next

Continue to [Running EsViritu](03-running-esviritu.md) for a viral-specialist classifier that also reports how much of each virus's genome your reads covered, or go to [BLAST Verification](06-blast-verification.md) to check a Kraken 2 hit against NCBI before you believe it.
