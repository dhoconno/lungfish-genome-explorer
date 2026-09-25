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
glossary_refs: [amplicon, blast, bracken, bundle, capped-database, clade, clade-count, fastq, host-depletion, k-mer, kraken2, kreport, lowest-common-ancestor, metagenomics, minimizer, operations-panel, paired-end, plugin-pack, provenance, read, read-classification, spike-in-control, taxon, taxonomic-rank]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[Kraken 2](../../GLOSSARY.md#kraken2) is a program that reads a [FASTQ](../../GLOSSARY.md#fastq) file one [read](../../GLOSSARY.md#read) at a time and writes down, for each read, which organism it most likely came from. The answer is a [taxon](../../GLOSSARY.md#taxon), any named group on the tree of life, so *Homo sapiens*, *Macaca mulatta*, and the virus family *Coronaviridae* are each one taxon. Do that for every read in a file and you have a census of what was in the tube.

Kraken 2 matches short words rather than aligning whole sequences. Aligning means lining two sequences up base by base and scoring them, which is accurate and slow. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases taken from a longer sequence, so `ACGTA` holds three 3-mers, `ACG`, `CGT`, and `GTA`. A sliding window is a fixed-width stretch of the read, a few dozen bases across, that starts at the first base and moves along one base at a time. A [minimizer](../../GLOSSARY.md#minimizer) is the smallest k-mer inside one window, where smallest means first in a fixed sort order the program applies, and it stands in as a compact fingerprint of that whole window.

Kraken 2 slides the window along each read, takes the minimizer at each position, and looks it up in a prebuilt database that records which taxon every minimizer belongs to. The taxon with the most support wins the read, provided it clears the confidence threshold described under Settings. That threshold is written in terms of the read's k-mers, because each minimizer stands in for the k-mers of its window. A table lookup is far quicker than an alignment, which is why a run takes seconds. It is also why the answer is exactly as good as the database and no better, a point the rest of this chapter returns to.

When a read fits several relatives equally, Kraken 2 reports their [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) instead of guessing, as [What Is Read Classification](01-what-is-classification.md#what-it-is) explains. A Kraken 2 report therefore has counts sitting at every [rank](../../GLOSSARY.md#taxonomic-rank) at once, not only at species.

Lungfish Genome Explorer (LGE) labels the tool **Kraken2** in its menus. Every run LGE starts is two programs. Kraken 2 assigns the reads, and then [Bracken](../../GLOSSARY.md#bracken) re-estimates each species' abundance, meaning its share of the sample, by pushing reads that Kraken 2 left at a broad group down onto the species they most likely came from. The result opens in the taxonomy viewport, a sunburst chart beside a table of taxa.

## Why you would do this

Run Kraken 2 whenever you do not already know, or cannot yet prove, what is in a sequencing library. A clinical swab from a person or a macaque is the obvious case, where most reads are host and the pathogen sits somewhere in the rest. The less obvious cases come up more often. A library you believe is one organism may be a mislabelled tube or a cross-contaminated plate, and the two look identical until something counts the reads. A low-yield run may mean the target is scarce or that the sample is mostly host DNA. And before a week of genome assembly, it pays to know how much of the data even comes from the organism you meant to assemble.

This chapter works through the SRR36291587 SARS-CoV-2 reads, a QIAseq Direct [amplicon](../../GLOSSARY.md#amplicon) library from a public NCBI Sequence Read Archive run. An amplicon library is one where PCR copied a fixed set of target regions before sequencing, so it is deliberately enriched for one organism. That makes it a clear teaching case, because you know the right answer before you start and can see plainly what the classifier gets right, what it misses, and what it invents. The example is viral because Kraken 2's downloadable databases are built to name microbes and viruses, and the same reasoning applies unchanged to a human or macaque specimen.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the sarscov2-srr36291587 fixture. Download the reads from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md), and find the fixture's README with its source and licence at https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries Kraken 2 and Bracken.

The counts in this chapter came from Kraken 2 version 2.17.1 and Bracken version 3.0.1 with the 20260626 builds of the Viral and Standard-16 databases. A different tool or database build can move a few reads, so expect your counts to sit close to these rather than match them digit for digit.

## Procedure

The worked example classifies the same reads twice, once against a small viral database and once against a general one, because the difference between the two answers is the most useful thing this chapter teaches.

### 1. Download Viral and Standard-16

A Kraken 2 database decides which answers are possible at all. A database holding only viruses cannot report a bacterium, however much bacterial sequence the library holds, and reports those reads as unclassified instead.

Download the Viral database from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. Then download the Standard-16 database the same way. Viral is about half a gigabyte and fits any Mac LGE supports. Standard-16 is a [capped database](../../GLOSSARY.md#capped-database), the full Standard collection shrunk to fit a machine with 16 GB of memory by discarding reference fragments. Kraken 2 loads the whole database into memory before it classifies a single read, so on a Mac with less than 16 GB take Standard-8 instead and expect it to recognise fewer reads still. To see how much memory your Mac has, choose **Apple menu > About This Mac**.

### 2. Open the dialog and choose a database

1. Click the FASTQ [bundle](../../GLOSSARY.md#bundle) holding the SRR36291587 reads in the sidebar. A bundle is a folder LGE treats as one item, here holding the reads and the record of where they came from.

2. Choose **Tools > Classification > Kraken2...**. The FASTQ/FASTA Operations dialog opens with Kraken2 selected in its tool sidebar, and the dataset line at the top names the bundle going in. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. Kraken 2 classifies the two mates of a pair together as one fragment, so the SRR36291587 bundle goes in as 85,199 read pairs, and every count in this chapter is a count of pairs.

3. Open the **Database** picker, which lists only databases that finished downloading, each with its size on disk. Choose **Viral**. If nothing is installed, the picker is replaced by "No databases installed." and a **Download Database...** button that opens the Plugin Manager on its Databases tab.

    <!-- SHOT: kraken2-dialog -->

4. Leave **Sensitivity** on **Balanced** and leave **Advanced Settings** collapsed. The three-way control fills in the two numbers inside that section for you, and Settings below explains them.

    <!-- SHOT: kraken2-advanced-settings -->

If you selected several bundles, the dialog also shows **Run Mode**, locked on "Run separately per bundle". The selection runs as one classification batch with a single Operations Panel row and one merged summary, and each sample is still classified on its own inside it.

### 3. Run it and find the result

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A single-sample row is titled "Profiling" plus the input file name, because the dialog always classifies and then profiles with Bracken. A multi-sample run is titled `Classification Batch (N samples)`. On a recent Mac the Viral run on these reads takes a few seconds and the Standard-16 run about ten, plus extra time the first time a large database is read off disk.

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Its name starts with `kraken2-`, so a second run never overwrites the first. Click it and the taxonomy viewport opens.

<!-- SHOT: kraken2-taxonomy-viewport -->

Now click the reads bundle again, reopen the dialog, choose **Standard-16** instead of Viral, and click **Run**, so you have both results for Reading the results. The newer `kraken2-` folder is the Standard-16 run, and the Database line in the Inspector names the database of whichever result is open. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

### 4. Extract the reads of one taxon

Once you have found the taxon you care about, you usually want its reads rather than its count, to map them to a reference, assemble them, or check them with [BLAST](../../GLOSSARY.md#blast). On the worked example that taxon is *Severe acute respiratory syndrome coronavirus 2*, the bottom row of the Viral result.

1. In the Viral result, select the taxon's row in the table or its wedge in the sunburst.

2. Click **Extract FASTQ** in the action bar, the strip of buttons along the bottom of the viewport. Right-clicking the row or wedge and choosing **Extract Reads...** opens the same dialog.

    <!-- SHOT: kraken2-extract-reads -->

3. The Extract Reads dialog reports an estimate of how many reads the selection holds, counting each read once. Leave **Format** on FASTQ and **Destination** on Save as Bundle, and check the **Name** field, which arrives filled in as `kraken2_` plus the taxon name.

4. Click **Create Bundle**, which is what the run button reads while Save as Bundle is the destination.

The new bundle appears in the project's top-level `Extractions` folder. It holds the reads assigned to the selected taxon and to every taxon beneath it, so extracting at a family row takes every genus and species in that family too. On the reference run, extracting *Severe acute respiratory syndrome coronavirus 2* from the Viral result wrote 83,591 read pairs. Selecting several rows before clicking Extract FASTQ writes their reads into one bundle.

## Settings

### The classification dialog

**Database.** Names the reference collection every read is compared against, and so fixes which answers are possible, since a read can only be given a name the database holds. The default is the first installed database that finished downloading, an arbitrary choice, so always look at it before you run. Pick a small collection such as Viral when you already know which family you are hunting, and a Standard or PlusPF collection for an unbiased survey, PlusPF being Standard plus protozoa and fungi. On the command line this is `--db`.

**Sensitivity.** Sets the Confidence and Min hit groups values together, trading how many reads get a name against how often that name is right. The default is Balanced, confidence 0.20 with 2 hit groups, against Sensitive at 0.00 with 1 and Precise at 0.50 with 3. Move to Precise when a false positive would be costly, such as reporting a pathogen, and to Sensitive when you are hunting something rare and will check every hit by hand. On the command line this is `--preset`.

**Run Mode.** Shows how several selected bundles are handled, and appears only when you selected more than one. It is locked on "Run separately per bundle (N results)", with "Combine all inputs, run once (1 result)" greyed out, because pooling reads across samples before classification would mix up the per-sample abundances. There is nothing to change, so read the lock reason and move on. This setting has no command-line flag.

**Confidence:.** Sets the fraction of a read's k-mers that must point at a taxon before Kraken 2 commits to that name, so 0.20 means at least a fifth. The default is 0.20, set by Balanced, and the slider and its typed number field run from 0.00 to 1.00 in steps of 0.05. Raise it when the report is full of implausible species, and lower it when too many reads come back unclassified, remembering that a read failing the test at one taxon is moved up to a broader group, and becomes unclassified only when no group, however broad, passes. On the command line this is `--confidence`.

**Min hit groups:.** Sets how many separate stretches of a read must match the same taxon before it can be assigned, where a hit group is one unbroken run of neighbouring matches, on the reasoning that two independent chance matches are much rarer than one. The default is 2, and the stepper accepts 1 to 10. Raise it when short repeated sequence produces calls you do not believe, and lower it for very short reads that cannot hold two separate matches. On the command line this is `--min-hit-groups`.

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

The taxonomy viewport stacks five parts. Along the top, a row of summary cards reports Total Reads, Classified, Unclassified, Species, Shannon H′, and Dominant when the run has just finished. When you reopen the result from the sidebar, the cards read Batch, Samples, Taxa, and Database instead. Shannon H′ is the Shannon diversity index, one number for how evenly reads spread across species, which is 0 when a single species holds them all and grows as the mix evens out. Dominant names the species with the most reads. Below the cards runs the breadcrumb bar, naming the part of the tree the sunburst is centred on. The middle holds the sunburst on the left and the table on the right. The action bar runs along the bottom.

The sunburst draws the root at the centre and one ring per level of the tree outward, so a rank Kraken 2 reports between the standard ones, such as a kingdom under a domain or an unclassified group under a genus, takes a ring of its own. Each wedge is sized by its share of the classified reads, and the centre states which denominator its percentage uses, all reads for the whole tree and classified reads once you zoom in. Taxa too small to draw are pooled into a paler wedge in their parent's colour, and hovering it names how many taxa and reads it holds. The table lists the same taxa as rows under the columns Sample, Taxon Name, Rank, Reads, Direct, Bracken, and **%**. Sample names which input a row came from, which matters only on a multi-sample run. Rank is the taxon's level, such as family, genus, or species.

Two columns are easy to confuse, and everything else depends on telling them apart. **Reads** is the [clade count](../../GLOSSARY.md#clade-count), every read assigned to that taxon or to anything below it, a [clade](../../GLOSSARY.md#clade) being a taxon with all its descendants. **Direct** counts only the reads assigned to that exact taxon and no lower. A family row with a large Reads figure and a Direct figure near zero means the classifier carried almost every read further down, which is healthy. A family row whose Direct figure is a large share of its Reads means the classifier stopped there, either because the reads cannot be resolved further or because the database holds nothing more specific. The **%** column is the Reads figure as a share of every read in the sample, unclassified reads included.

Here are five of the rows on the path from the top of the tree to SARS-CoV-2 in the Viral result, with the intermediate ranks, such as the order *Nidovirales*, left out. The Rank column reads Sub-root for Viruses because this database's copy of the taxonomy files viruses one level below the root, the single starting point of the whole tree.

| Taxon | Rank | Reads | Direct | % |
|---|---|---|---|---|
| Viruses | Sub-root | 83,728 | 65 | 98.27 |
| Coronaviridae | Family | 83,663 | 0 | 98.20 |
| Betacoronavirus | Genus | 83,662 | 0 | 98.20 |
| *Betacoronavirus pandemicum* | Species | 83,645 | 54 | 98.18 |
| Severe acute respiratory syndrome coronavirus 2 | Subspecies | 83,591 | 83,591 | 98.11 |

*Betacoronavirus pandemicum* is the formal species name the taxonomy now gives the group SARS-CoV-2 belongs to, and SARS-CoV-2 sits below it as a named subspecies. Viral taxonomy routinely names a species that holds familiar viruses as members, so a familiar name below an unfamiliar one is the convention, not a mistake.

Read the table downward. Every rank carries almost the same clade count, which is what a single-organism sample looks like, and Direct stays near zero until the bottom row, where the classifier committed its reads to SARS-CoV-2 itself. A few reads sitting Direct at the Viruses row are reads whose k-mers matched several unrelated viruses equally, so their lowest common ancestor was Viruses as a whole. A small Direct figure at a broad rank is ordinary, and only its size relative to the clade count matters.

The row missing from that table is the one to read next. Right after the run, the Unclassified card reads 1.7%, and the report behind it counts 1,471 unclassified pairs. Unclassified means a read found no match that the database and the confidence threshold would both accept. It is the classifier telling you where its knowledge ran out.

The Bracken column fills in on species rows. Bracken works at the species rank, so reads already sitting at the subspecies below are counted inside the species total rather than moved. When one species dominates this completely there is nothing left to redistribute, and the Bracken figure matches the Reads figure, 83,645 for *Betacoronavirus pandemicum*. On a mixed sample they differ, and the Bracken figure is the better estimate of each species' share.

### Moving around the tree

A single click on a wedge selects it and selects the same row in the table, and the reverse works too. A double-click re-centres the sunburst on that wedge, so double-clicking **Coronaviridae** redraws the chart with Coronaviridae in the middle and its children as the first ring out. The breadcrumb bar then shows the path back to the root, and clicking an earlier segment returns you there. Clicking the centre circle, or pressing Escape, zooms out one level, and Cmd-0 jumps back to the root. The shortcuts go to the chart, so click it once before you use them.

<!-- SHOT: kraken2-drilldown-coronaviridae -->

Right-clicking a wedge offers Extract Reads..., Copy Taxon Name, Copy Taxonomy Path, Zoom to that taxon, Zoom Out to Root, a **Look Up on NCBI** submenu with NCBI Taxonomy, GenBank Sequences, PubMed Literature, and Genome Assemblies, and **BLAST Matching Reads...**. Right-clicking a table row offers Extract Reads..., the Expand and Collapse items for the tree, BLAST Matching Reads..., Look Up on NCBI without Genome Assemblies, and Copy Taxon Name. Right-clicking empty chart space offers **Copy Chart as PNG**, which puts an image of the current sunburst on the clipboard.

### The action bar and the provenance popover

The action bar along the bottom carries, from the left, these controls:

- **BLAST Verify** sends a sample of the selected taxon's reads to NCBI, and needs exactly one row selected.
- **Export** offers Export as CSV..., Export as TSV..., Copy Summary, and Show Provenance.... A file export holds the columns Name, Rank, Reads (Clade), Reads (Direct), Clade %, and Direct %, one row per taxon in tree order.
- **Extract FASTQ** opens the Extract Reads dialog for the selection, as step 4 showed.
- **Collections** and **BLAST Results** toggle side drawers. A collection is a named set of taxa extracted together, each to its own file, such as the built-in Respiratory Viruses set. [BLAST Verification](06-blast-verification.md) covers both drawers.

A line of text after the buttons names the selected taxon with its read count and percentage. Right after a run, the information button at the right end opens the Classification Provenance popover, which lists the Kraken 2 version, the database and its folder on disk, the Confidence and Hit Groups values, the thread count, whether memory mapping was on, the runtime, the input files, a Bracken row when Bracken ran, and a short run ID. That popover is what you copy into a methods section. On a result reopened from the sidebar the button does nothing, so read the same values in the Inspector instead. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

### The same reads, a different database

Now open the Standard-16 result and read the same rows. This is the comparison the chapter exists for.

| Measure | Viral | Standard-16 |
|---|---|---|
| Reads classified | 83,728 (98.27%) | 3,320 (3.90%) |
| Unclassified | 1,471 (1.73%) | 81,879 (96.10%) |
| SARS-CoV-2 reads | 83,591 | 2,602 |
| Species reported | 1 | 1 |

The same reads went in. The Viral database named 98% of them and Standard-16 named 4%, about twenty-five times fewer. Nothing about the sample changed, and neither database is broken. Standard-16 is squeezed from the full Standard collection of about 67 GB by discarding most of its reference fragments, and what survives is spread thinly across archaea, bacteria, viruses, plasmids, the human genome, and cloning-vector sequence. The Viral collection spends its whole half-gigabyte on viruses, so it keeps far more SARS-CoV-2 detail.

Standard-16 still found the right virus, but it recognised only a small share of that virus's reads. The 718 reads it classified beyond the SARS-CoV-2 row stopped at ranks above species, because their surviving k-mers were not specific enough to go further.

The lesson reaches past this fixture. Capping discards fragments evenly across the reference set, so the organism that supplied almost every read in the tube is the one that loses the most reads. When screening an unknown sample, run a broad database to learn roughly what family you face, then a specialist database for that family to get the detail. Running only the broad one and concluding the sample was mostly nothing is the mistake this comparison exists to prevent.

Note also what did not appear. Standard-16 contains the human genome and the swab came from a person, yet no human reads were reported. That is the amplicon protocol at work. PCR amplified the viral targets so heavily that the human background fell below detection. A shotgun library from the same swab, made without PCR enrichment, would usually be dominated by human reads, which is what [host depletion](../../GLOSSARY.md#host-depletion) exists to remove.

### What the Sensitivity preset changes

Running the same reads against the Viral database at all three presets shows what the control does.

| Preset | Classified | Unclassified | Species reported |
|---|---|---|---|
| Sensitive | 85,181 (99.98%) | 18 (0.02%) | 5 |
| Balanced | 83,728 (98.27%) | 1,471 (1.73%) | 1 |
| Precise | 78,731 (92.41%) | 6,468 (7.59%) | 1 |

Precise gave up about 5,000 pairs that Balanced was willing to name and named nothing new for them. Sensitive named nearly everything and reported four species beyond *Betacoronavirus pandemicum*, so look at what they were. One is *Sinsheimervirus phiX174*, with 5 pairs. PhiX is a small virus of bacteria that Illumina adds to runs as a [spike-in control](../../GLOSSARY.md#spike-in-control), so a few of its reads are expected. The other three rest on one or two pairs each, a Vibrio phage, a frog adenovirus, and a picorna-like virus, none with a route into a respiratory swab prepared with a SARS-CoV-2 amplicon kit, so they are chance k-mer matches rather than organisms in the tube.

That is the trade the preset names. Sensitive found a real minor component that Balanced missed and paid for it with findings that are not real. On a hit of one or two reads the report alone cannot say which you have, and the judgement above leaned on knowing what the sample was. For an unknown sample, settle it with the BLAST check that What good looks like describes.

## What good looks like

Read the unclassified share first, on the Unclassified card right after the run, before you look at any organism. A reopened result does not show that card, so note the figure when the run finishes, or read the first line of the `classification.kreport` file in the result folder, which counts the unclassified reads. It tells you whether to trust the rest of the report. Under about 20% means the database recognised your sample and the taxa are worth reading. Between 20% and half, read the taxa with care, since a large part of the sample is unaccounted for. Over about half means the database did not recognise it, and every percentage you read describes only the small fraction it happened to match. On the reference runs the Viral result is a report you can read straight, and the Standard-16 result is a report telling you to change the database rather than a report about the sample.

The extreme case is a database that matches nothing at all. The run then stops with the error `Empty Kraken2 report` instead of showing a result that is 100% unclassified. Treat it as the database being wrong for the sample and rerun with one that covers what you are looking for.

Then check whether the dominant signal is the organism you expected. Click the Reads column header to sort by it, and look at family or genus rather than species, since that is the level a classifier reaches reliably. One taxon dwarfing everything else, as Coronaviridae does here, means the sample probably contains it. Several taxa of comparable size mean a mixed sample, and no clear peak usually means the wrong database.

Then read the long tail against a rule you set before you looked, such as "follow up any taxon above 100 reads". Writing the rule first stops you raising the bar to dismiss an inconvenient hit or lowering it to keep an exciting one. A low-abundance hit is a real minor component like phiX, a mis-assignment from k-mers unrelated organisms share, or contamination from the laboratory or from stray sequence inside the reference database, and the report cannot tell you which. Under about ten reads against an unrelated taxon is usually noise. Between that and a few thousand, extract the taxon's reads and search them against NCBI, as [BLAST Verification](06-blast-verification.md) explains.

Finally, remember what the confidence score measures. It asks what fraction of a read's k-mers agree with the assigned taxon, so it measures fit to one database entry and nothing more. It says nothing about whether that entry was the right one, or how many other sequences would have fitted as well. A read that agrees perfectly with a short, divergent, or mislabelled entry is still a poor match to anything real. Kraken 2 is a screening step, so verify any hit that matters.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
# Classify against Viral, then Standard-16, running Bracken as the dialog does.
lungfish-cli conda classify SRR36291587_1.fastq SRR36291587_2.fastq \
  --paired --db Viral --profile --output-dir ./kraken2-viral
lungfish-cli conda classify SRR36291587_1.fastq SRR36291587_2.fastq \
  --paired --db Standard-16 --profile --output-dir ./kraken2-standard16

# Extract the SARS-CoV-2 reads (NCBI taxonomy ID 2697049) and everything below it.
lungfish-cli extract reads --by-classifier --tool kraken2 \
  --result ./kraken2-viral --taxon 2697049 \
  --output sars-cov-2.fastq --bundle-name "SARS-CoV-2 reads"
```

The dialog always runs Bracken and the command line does not, so a command without `--profile` gives a classification with no Bracken column. Given the single FASTQ file inside a paired bundle instead of the two downloaded files, leave out `--paired`. The default `--read-format auto` finds the alternating mates and classifies them as pairs, as the dialog does. `--taxon` takes the numeric taxonomy ID rather than a name, and right-clicking a row and choosing **Look Up on NCBI > NCBI Taxonomy** opens the taxon's NCBI page, which shows it.

## Next

Continue to [Running EsViritu](03-running-esviritu.md) for a viral-specialist classifier that also reports how much of each virus's genome your reads covered, or go to [BLAST Verification](06-blast-verification.md) to check a Kraken 2 hit against NCBI before you believe it.
