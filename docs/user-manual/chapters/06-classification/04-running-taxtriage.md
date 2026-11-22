---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification, 06-classification/02-running-kraken2]
estimated_reading_min: 24
task: Run the TaxTriage pathogen workflow on two clinical FASTQ bundles against an installed Kraken 2 database, keep the human genome out of its top hits, and read the organism table and the evidence behind each call.
tags: [classification, taxtriage, nextflow, container, confidence, pathogen-detection]
tools: [taxtriage]
parameters_refs: [classify.taxtriage]
entry_points:
  - "Tools > Classification > TaxTriage…"
  - "CLI: lungfish-cli taxtriage run"
shots:
  - id: taxtriage-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > TaxTriage… with SRR12486983 and SRR12486989 selected, showing both samples as Clinical Sample rows, the Prerequisites row with its Nextflow and Docker Desktop indicators, the Kraken2 Database picker on Standard-16, Sequencing Platform on Illumina, Skip assembly (faster) ticked, the Exclude host taxa field holding 9606, and Advanced Settings collapsed."
  - id: taxtriage-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the K2 Confidence slider at 0.20, the Top hits stepper at 10, the Max memory stepper at 16 GB, the Max CPUs stepper at 14, the Skip Krona visualization checkbox, and an empty Extra arguments field, below the Exclude host taxa field holding 9606."
  - id: taxtriage-running-row
    caption: "The Operations Panel during the two-sample run, with the row titled TaxTriage (2 samples) and its detail line naming the sample at work, its place in the batch as Sample 1/2 or Sample 2/2, and the pipeline step that is running."
  - id: taxtriage-batch-overview
    caption: "The TaxTriage viewport with both samples ticked and Kocuria typed in the Filter organisms… field beside the sample buttons, the Organisms card reading 15, and SRR12486983's Kocuria rows first, from Kocuria sp. BT304 at 0.920 High down to Kocuria sp. MNB10 at 0.380 Low, then SRR12486989's, starting with Kocuria sp. BT304 at 0.980 High. The first row is selected, and the alignment pane below shows its coverage track."
  - id: taxtriage-result-table
    caption: "The TaxTriage viewport for the two-sample corneal run in the List Over Detail layout, with both samples ticked in the Inspector's Sample Filter and the cards reading Batch TaxTriage, Samples 2, and Organisms 193. The Human alphaherpesvirus 1 row of SRR12486983 is selected in the table on top, showing TASS Score 0.930, Reads 1.5M, and High, and the alignment pane below shows the coverage track across the 152,222-base HSV-1 reference NC_001806.2, zoomed out, with its prompt to zoom in to view individual mapped reads. The Inspector shows its Panel Layout control and the run's Operation Details."
illustrations: []
glossary_refs: [minimap2, accession, amplicon, bam, blast, bundle, checksum, container, docker, coverage-breadth, depth, fastq, fragment, inspector, kraken2, k-mer, library-prep, lowest-common-ancestor, mapping-quality, mark-duplicates, multiqc, negative-control, nextflow, operations-panel, paired-end, pinned, plugin-pack, primary-alignment, provenance, read, read-classification, reference-genome, required-setup-pack, samplesheet, shotgun, sra, taxon, taxonomy-id, tass-score, taxtriage, tsv, viewport, mate, unique-reads, confidence-kraken-2, contamination, relative-abundance, false-positive, read-merging, single-end, virtual-bundle]
features_refs: [classify.taxtriage, classify.blast-verify, classify.extract-reads, provenance.result-popovers, results.table-row-commands, containers.run, operations.panel]
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

[TaxTriage](../../GLOSSARY.md#taxtriage) is a pathogen-detection workflow, a chain of separate programs run one after another by a managing program called [Nextflow](../../GLOSSARY.md#nextflow). It takes a [FASTQ](../../GLOSSARY.md#fastq) file of sequencing [reads](../../GLOSSARY.md#read), the short stretches of sequence the instrument produced, and names the organisms the reads came from, a task called [read classification](../../GLOSSARY.md#read-classification). Each name it reports is a call, TaxTriage's statement that one organism is present in your sample.

The naming step is [Kraken 2](../../GLOSSARY.md#kraken2), the same program [Running Kraken 2](02-running-kraken2.md) covers, run against the same installed databases. In simplified terms, Kraken 2 cuts each read into short pieces and looks each one up in a database of known genomes to name the organism the read came from. On its own it stops at a list of names and read counts. TaxTriage then tests those names. It takes the organisms Kraken 2 named most often and downloads a [reference genome](../../GLOSSARY.md#reference-genome) for each, a published full genome sequence of that organism. It maps the sample's reads onto those genomes, meaning it finds where on a genome each read fits best, with a mapper called [minimap2](../../GLOSSARY.md#minimap2). Finally it measures how much of each genome the reads reached and how deeply they stacked, and folds those measurements into one number per organism.

That number is the [TASS score](../../GLOSSARY.md#tass-score), TaxTriage's confidence that an organism's DNA is really in your sample. TaxTriage writes it on a scale of 0 to 100, and Lungfish Genome Explorer (LGE) shows it divided by 100, so 0 means not confident at all and 1 means as confident as the score gets. The score weighs how well the reads support the organism, not how many there are. LGE also labels every organism High, Medium, or Low, as Reading the results explains.

TaxTriage is published as a Nextflow pipeline, a recipe file that lists the steps in order and that Nextflow reads and runs. Each step runs inside a [container](../../GLOSSARY.md#container), a packaged copy of a program with everything it needs, which Nextflow downloads from the internet the first time. LGE runs the containers through [Docker](../../GLOSSARY.md#docker) Desktop, an application from Docker, Inc. that you install yourself. Each container carries its own copy of its programs, so beyond Nextflow, which comes in the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), TaxTriage needs no [plugin pack](../../GLOSSARY.md#plugin-pack), one of the themed groups of tools LGE installs on request. LGE runs one [pinned](../../GLOSSARY.md#pinned) version of the pipeline's code, TaxTriage release v3.3.8, so a rerun takes exactly the same steps. The reference genomes are the exception. TaxTriage fetches them from NCBI during each run, and the run's record notes them as a snapshot of that day.

In short, reach for TaxTriage when you want every organism call checked against a real genome, and plan for a run that takes longer than Kraken 2 alone.

## Why you would do this

You run TaxTriage when the question is not only what is present but how well each answer is supported, and when several samples have to be judged by the same yardstick, the TASS score and its High, Medium, and Low labels.

A read count alone cannot tell a good call from a bad one. In the good case an organism's reads spread along its whole genome. In the bad case every read piles onto one repetitive stretch, a region that looks like many others, so reads from anywhere in the sample can land there by mistake. Both give the same count. TaxTriage separates them because its mapping round reports [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of the reference the reads reached, beside mean [depth](../../GLOSSARY.md#depth), the average number of reads over each position.

The second reason is controls. A [negative control](../../GLOSSARY.md#negative-control) is a tube of water or buffer instead of patient material, carried through the whole protocol, so anything found in it came from reagents, the bench, or the sequencing run. Run it in the same batch and LGE flags every organism it holds in the specimens' rows too, so an organism found in both is easy to spot.

Choose TaxTriage over Kraken 2 alone when each call must carry evidence a reviewer can check, and over [EsViritu](03-running-esviritu.md), LGE's tool that looks for viruses only, when the answer may be a bacterium rather than a virus. Choose something lighter when Docker Desktop is not an option or a quick look at the sample will do. [Choosing a tool](01-what-is-classification.md#choosing-a-tool) compares every classification route in LGE, and the TaxTriage paper is Merritt and colleagues 2026, listed in [Pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines).

This chapter works through two human corneal samples, the cornea being the clear front surface of the eye. They come from the study behind the protocol paper by the team that wrote Kraken 2, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y). The [Sequence Read Archive](../../GLOSSARY.md#sra) (SRA), NCBI's public store of sequencing data, calls each dataset a run, so SRR12486983 and SRR12486989 are sequencing runs. A TaxTriage run is one execution of the pipeline, and plain "run" in this chapter means that. Sequencing run SRR12486983 is the herpes simplex keratitis case that [Running Kraken 2](02-running-kraken2.md) uses, an eye infection by herpes simplex virus 1 (HSV-1). Sequencing run SRR12486989 is a second case from the same study, recorded as an infection by the bacterium *Streptococcus agalactiae*. Both are [shotgun](../../GLOSSARY.md#shotgun) [libraries](../../GLOSSARY.md#library-prep) of human tissue, meaning the tissue's DNA was broken into random fragments and prepared for the sequencer. Knowing each answer in advance shows what the tool reports well and what it does not.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Without one, the run cannot start and LGE shows an alert titled No Project Open, because it saves every TaxTriage result in the project's `Analyses` folder.

Open the Pathogen Detection demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds both sequencing runs as the two bundles described below, so the SRA downloads are done. To fetch them yourself instead, follow the next paragraph.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for the example data of the Kraken 2, TaxTriage, and BLAST chapters. Download both sequencing runs from the SRA as `SRR12486983` and `SRR12486989`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). Each is [paired-end](../../GLOSSARY.md#paired-end), so every DNA [fragment](../../GLOSSARY.md#fragment) was read from both ends, and the two reads of one fragment are a read pair. Each imports as one [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, `Imports/SRR12486983.lungfishfastq` with 4,819,760 read pairs and `Imports/SRR12486989.lungfishfastq` with 5,440,369. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea. Reading it is optional, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Whichever way you get the sequencing runs, you also need Nextflow, Docker Desktop, and a Kraken 2 database. Nextflow comes with the Required Setup pack, which the Welcome window offers to install the first time you open LGE and the Plugin Manager lists in its Required Setup section as the Third-Party Tools pack.

TaxTriage runs its containers through Docker Desktop. Download it from the Docker website, install it like any other Mac application, and open it before you run TaxTriage, because the dialog's check passes only while Docker Desktop reports Running. [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains what to check when a run cannot reach it.

TaxTriage classifies against an installed Kraken 2 database rather than carrying its own. This chapter uses Standard-16, a broad database of bacteria, archaea, viruses, and the human genome, sized for a Mac with 16 GB of memory. Choose **Apple menu > About This Mac** to see your Mac's memory, and on a Mac with less than 16 GB take Standard-8 instead. Open **Tools > Plugin Manager…** and download Standard-16 from its Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. The download is about 16 GB, so check your free disk space first, as [System requirements](../01-foundations/06-the-lungfish-project.md#system-requirements) describes. If you worked through [Running Kraken 2](02-running-kraken2.md) you already have it.

Allow time. On the test Mac, which has 14 processor cores, the TaxTriage run on the two samples together took about 21 minutes. The first TaxTriage run also waits while Nextflow downloads the pipeline's container images, the stored copies each container starts from, and later runs reuse them. Every run needs the internet and is the slowest classification route in LGE.

## Procedure

The example in this chapter runs TaxTriage once on both corneal samples against Standard-16.

### Select both samples and check the prerequisites

1. Click the SRR12486983 bundle in the project sidebar, then Cmd-click the SRR12486989 bundle so that both are selected.

2. Choose **Tools > Classification > TaxTriage…**. The window that opens is titled FASTQ/FASTA Operations, with TaxTriage already chosen in its tool sidebar and its settings beside it. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Prerequisites** row at the top of the TaxTriage settings. It carries one indicator labelled **Nextflow** and a second that names Docker Desktop followed by Running, Not running, or Not installed. A green dot means the item is ready and an orange dot means it is missing, and a spinner means the check is still running. The check asks Docker itself, so Apple's own container system never turns this dot green, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains.

    <!-- SHOT: taxtriage-dialog -->

4. If either dot is orange, **Run** stays disabled and the status line at the left end of the footer, beside **Cancel** and **Run**, reads "Complete the classifier settings to continue." An orange dot beside **Nextflow** means the Required Setup pack is missing or broken, so open **Tools > Plugin Manager…** and install it from the Required Setup section, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. An orange Docker Desktop dot means Docker Desktop is not installed or not running, so install it or start it. In either case reopen the dialog afterwards, because the check runs when the settings appear.

<!-- WAIT ux-text TV-SHELL -->

### Check the samples

The **Samples** section holds one row per bundle you selected, so it lists SRR12486983 and SRR12486989.

1. Read each **Sample ID** field. It starts with the bundle's name, and the pipeline reports the sample under it. When you run several samples, leave each Sample ID as LGE filled it in. LGE then names each sample after its bundle, so a Sample ID you type would not match the name in the results. LGE refuses such a run with an alert titled TaxTriage Cannot Run These Samples, which says what to change.

2. Leave the role picker at the right of each row on **Clinical Sample**, because both samples are patient specimens. For your own samples there are four control roles. A Negative Control is a no-template tube, and an Extraction Blank is a tube with nothing in it carried through DNA extraction. A Positive Control holds a known organism, and an Environmental Control samples the room or bench. Whatever the picker shows, the run marks a sample as a negative control when its bundle's sample metadata records the role Negative Control or Extraction Blank, as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

3. **Remove** at the right of a row drops it. Do not use **Add Sample**. It adds an empty row that cannot hold reads, and the run leaves it out. Select every bundle you want in the sidebar before you open the dialog instead.

4. Give every sample a name that stays different once spaces and symbols are removed. The pipeline turns a space into an underscore and drops symbols such as brackets, so `A (1)` and `A_1` both become `A_1`. When two names meet like that, an orange line under the list says so and **Run** stays disabled until you rename one. Rename a bundle in the sidebar and open the dialog again, or run the samples one at a time.

### Choose the database and the platform

Open the **Kraken2 Database** picker and choose **Standard-16**. If none is installed, the section reads "No Kraken2 databases installed" instead.

Leave **Sequencing Platform** on **Illumina**, whose instruments read short pieces of DNA. The sequencing runs' SRA records name the instrument, an Illumina NextSeq 550. A bundle that already records its platform runs on that platform whatever the picker says, so the picker matters only when a bundle records no platform TaxTriage can use, as [How LGE decides the platform](../03-reads/01-importing-fastq.md#how-lge-decides-the-platform) explains.

Leave **Skip assembly (faster)** ticked, because TaxTriage can name organisms without assembly, the stitching of overlapping reads into new long sequences. The line under it reads "Classification and confidence scoring only. Significantly faster."

### Keep the human genome out of the top hits

Find the **Exclude host taxa** field below **Skip assembly (faster)**. Because both rows are Clinical Sample rows, LGE has already filled it with 9606. Leave it as it is. The line under the field reads "NCBI taxids removed before TaxTriage picks references, separated by spaces. 9606 is human. Leave empty to keep every taxon."

Click **Advanced Settings** to open it. Leave every value at its default and leave **Extra arguments** empty. On the test Mac the defaults were K2 Confidence 0.20, where K2 stands for Kraken 2, Top hits 10, Max memory 16 GB, and Max CPUs 14, a number that follows how many processor cores your Mac has. If you type `--remove_taxids` into Extra arguments yourself, it takes the place of the Exclude host taxa field, and the line under the field then says the field is not used.

<!-- SHOT: taxtriage-advanced-settings -->

<!-- WAIT ux-text TV-SHELL -->

This one setting matters most. TaxTriage downloads a reference genome for each organism at the top of the Kraken 2 report, the summary table of how many reads went to each [taxon](../../GLOSSARY.md#taxon), meaning each named group of organisms. Standard-16 contains the human genome, and a human tissue sample is mostly human DNA, so without the setting *Homo sapiens* enters the top hits. TaxTriage then downloads GRCh38, the complete human reference genome, and its mapping step needs more memory than the 16 GB limit allows, so Nextflow stops it.

If you clear the field on these samples, the mapping step is stopped for lack of memory and TaxTriage carries on without it. LGE reports the failure in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists the jobs LGE is running or has finished, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The job's row there reads Completed with Warnings, and its detail says "Some TaxTriage tasks failed", names the failed step, and adds "killed, usually for running out of memory" when that is what happened. The row's log says which results are missing and suggests Max memory or Exclude host taxa, and the Inspector's **Operation Details** shows a Warnings line such as "1 ignored failure across 1 sample". In the result itself, every TASS Score reads 0.000, because the scores depend on the step that failed. A failed step that only draws quality-control plots is harmless, and the log then says that only the quality-control plots in the [MultiQC](../../GLOSSARY.md#multiqc) report are missing and that the classifications, alignments, and TASS scores are complete.

Exclude host taxa drops the listed taxa from the Kraken 2 report before the top hits are chosen. The human reads stay in the sample, but no human genome is downloaded and nothing is ranked as human. The number 9606 is the [taxonomy ID](../../GLOSSARY.md#taxonomy-id) that NCBI, the United States National Center for Biotechnology Information, gives *Homo sapiens*. LGE fills it in only for Clinical Sample rows and only for human, so **Exclude host taxa** in Settings explains what to type for an animal sample.

### Run TaxTriage and open the result

1. Click **Run**. Behind the dialog LGE runs the `lungfish-cli taxtriage run` command, the same command a user of the Terminal, the Mac's window for typed commands, could type, so the app and the command line give the same result. You never need the Terminal to follow this chapter, and its command-line parts are optional. The Operations Panel records the command in the job's row, and **Copy CLI Command** on the row's right-click menu copies it.

2. Watch the row titled TaxTriage (2 samples) in the Operations Panel. Each sample runs alone, one after the other, in its own Nextflow run. The detail line names the sample, its place in the batch, and the pipeline step at work, such as `Sample 1/2 (SRR12486983): Running KRAKEN2_KRAKEN2 (SRR12486983)`. If Docker Desktop stopped after the dialog checked it, the detail reads "Docker daemon unavailable. Launching Docker Desktop..." while LGE starts it. **Cancel** stops Nextflow and then stops and removes the Docker containers the run started, so nothing keeps working in the background.

    <!-- SHOT: taxtriage-running-row -->

3. When the row finishes, find the result in the sidebar. It appears only then, because LGE keeps a running analysis out of the sidebar. It lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE names it `taxtriage-batch-` followed by the date and time, such as `taxtriage-batch-2026-09-25T03-40-19`, with one subfolder per sample inside it. Click the folder and the TaxTriage [viewport](../../GLOSSARY.md#viewport) opens, the panel that fills the window and shows one result.

LGE splits each paired bundle into its two [mates](../../GLOSSARY.md#mate) before the run, so TaxTriage maps true pairs. A bundle that keeps its mates in separate R1 and R2 files, the files that hold the first and the second read of every pair, runs as pairs too. A bundle that mixes pairs with unpaired reads, such as reads [merged](../../GLOSSARY.md#read-merging) from overlapping mates, or one imported as several files of single reads, runs [single-end](../../GLOSSARY.md#single-end), which means every read goes into one file and none is paired, and the row's log gives the reason. If one sample fails while the other completes, the row reads Completed with Warnings and its detail counts the failed sample.

Once the result is open, the Inspector's **Operation Details** section lists the settings the run used, such as Platform, Confidence, Top Hits, Max Memory, Database Path, and Runtime. Copy them from there into a methods section.

### Importing a TaxTriage result made elsewhere

A colleague who ran TaxTriage on another computer can send you its output folder, and LGE opens it in the same viewport. Choose **File > Import Center…** (Cmd-Shift-I), click the **Classification Results** tab, and click **Import…** on the **TaxTriage Results** card, whose file hint reads "TaxTriage output directory". Pick the output folder and click **Open**. No sheet follows, and the import starts at once.

LGE looks inside for each sample's organism report, `<sample>.odr.txt` or `<sample>.organisms.report.txt`, and also picks up the run's Krona chart, `nextflow.log`, and `trace.txt` when they are there. The folder lands in the project as `Imports/taxtriage-<name>`, where `<name>` is the folder's name, less anything after its last dot, with every character other than a letter, a digit, a hyphen, or an underscore turned into an underscore, with runs of underscores merged into one and any at either end dropped. A name that already begins with `taxtriage-`, as LGE's own result folders do, gets no second prefix, and a second import of the same name adds `-2`.

A folder that LGE's own run wrote holds a record of that run, `taxtriage-result.json`, and the import keeps its negative controls, settings, and database. A folder without that record cannot say which samples were controls. Its viewport then shows a note above the table that begins "Not recorded by this import", its settings read Not recorded, and an export's Contamination Risk column reads Not recorded rather than a misleading No.

## Settings

Six controls sit in plain view and six more inside **Advanced Settings**.

**Sample ID.** Names one row of the sample list, and every report the pipeline writes refers to the sample by this label. The default is the bundle's name without any mate marker at its end, such as `_R1` or `_1`, so each report stays matched to the bundle it came from. Change it to your lab's identifier in a run of one sample, and leave it as filled in for a run of several, as [Check the samples](#check-the-samples) explains. On the command line this is `--sample`.

**Sample role.** Records what kind of material a row holds, Clinical Sample for the specimen under test or one of four control roles. The default is Clinical Sample, because most rows are specimens. Set Negative Control or Extraction Blank on every blank you carried through the protocol, because only those two roles mark the organisms found in them as a contamination risk, and a Clinical Sample row also fills **Exclude host taxa** with 9606. On the command line this is `--negative-control`.

**Kraken2 Database.** Names the reference collection the classification step compares every read against, and so fixes which organisms can be reported at all. The default is the first installed Kraken 2 database, which is an accident of install order rather than a choice. Match it to the organisms you expect, such as Viral for viruses only, Standard-8 or Standard-16 for a broad survey on an 8 GB or 16 GB Mac, and PlusPF when fungi and protozoa matter, as [Sensitivity, precision, and the database](01-what-is-classification.md#sensitivity-precision-and-the-database) describes. On the command line this is `--db`.

**Sequencing Platform.** Tells the pipeline which instrument made the reads, offering Illumina, Oxford Nanopore, and PacBio, the last two being long-read platforms, so its steps expect that instrument's read length and errors. The default is Illumina, the short-read platform. Change it only for reads whose bundle records no platform, choosing the instrument named on your sequencing run sheet, as [How LGE decides the platform](../03-reads/01-importing-fastq.md#how-lge-decides-the-platform) describes. On the command line this is `--platform`.

**Skip assembly (faster).** Leaves out de novo assembly, the slow stitching of overlapping reads into long sequences without a reference. The default is on, because classification and scoring answer the detection question and assembly does not. Turn it off only when you want assembled genomes and can spare hours more. On the command line this is `--no-skip-assembly`.

**Exclude host taxa.** Lists NCBI taxonomy IDs, separated by spaces or commas, that are removed from the Kraken 2 report before TaxTriage picks its top hits, so their genomes are never downloaded as references. The default is 9606, human, whenever any row is a Clinical Sample, and empty otherwise, because a human specimen is mostly human DNA. Type the host's ID for an animal sample, such as 9544 for the rhesus macaque, which you can find by searching the animal's name in [NCBI Taxonomy](https://www.ncbi.nlm.nih.gov/taxonomy), and clear the field only when the host itself is what you want to find. On the command line this is `--remove-taxids`.

**K2 Confidence.** Sets the share of a read's [k-mers](../../GLOSSARY.md#k-mer), the short pieces of sequence Kraken 2 looks up in its database, that must point to one taxon before the read is given that taxon's name. The default is 0.20, one k-mer in five, set with a slider or a typed number from 0.00 to 1.00 in steps of 0.05. Raise it when the table fills with species that make no sense for the sample, such as ocean bacteria in an eye, and lower it when an organism you expect never appears, because a read that falls short is named for the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) of the taxa it matched, a broader group such as the genus shared by two species. On the command line this is `--confidence`.

**Top hits.** Sets how many of the organisms with the most Kraken 2 reads the pipeline starts from when it chooses reference genomes to download, and it does not cap the rows in the result, since the pipeline downloads more reference sequences than the top hits alone give. The default is 10, and the stepper accepts 1 to 100. Raise it for a complex community where the top ten would leave out organisms you care about, knowing each extra organism adds downloads and mapping time. On the command line this is `--top-hits`.

**Max memory.** Caps how much memory the pipeline may use, and a cap above what your Mac has makes steps fail. The default is 16 GB, and the stepper accepts 2 to 256 GB in steps of 2. On a Mac with less than 16 GB set it a few gigabytes below the memory **Apple menu > About This Mac** shows, and raise it for a large database on a Mac with memory to spare. On the command line this is `--max-memory`.

**Max CPUs.** Caps how many processor cores, the separate calculating units inside the Mac's chip, the pipeline uses at once. The default is every core currently available, 14 on the test Mac, and the stepper stops at your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--max-cpus`.

**Skip Krona visualization.** Leaves out the interactive Krona chart, a clickable picture of the community written into the result folder as a web page. The default is off, so the chart is made, and the viewport's tables do not depend on it. Turn it on to shorten a run when you only want the tables. On the command line this is `--skip-krona`.

**Extra arguments.** Passes text straight to TaxTriage and Nextflow without LGE checking it, and a `--remove_taxids` typed here takes the place of **Exclude host taxa**. The default is empty. Use it only for an option the dialog lacks, after reading the TaxTriage documentation at https://github.com/jhuapl-bio/taxtriage, and put a value that contains spaces in quotes, because an unclosed quote keeps **Run** disabled. On the command line this is `--extra-args`.

## Reading the results

The viewport has a row of summary cards across the top, an organism table with an alignment pane, and an action bar along the bottom. The pane sits beside the table in the default Detail | List layout. The Inspector's **Panel Layout** control also offers List | Detail and List Over Detail, which puts the pane below the table, the layout the shots here use, as [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) describes. The cards read Batch, Samples, and Organisms. A note can appear between the cards and the table when something limits what the result can say, such as a negative control that did not run, as Recognising the pathogen explains.

For the example TaxTriage run, Batch reads TaxTriage and Samples reads 2. Organisms counts the rows in the table, 193 while both samples are showing, and one organism found in both samples takes two rows. The figures in this chapter come from one run, and a rerun gives slightly different numbers, such as 1,480,825 aligned reads for HSV-1 where this run gave 1,481,003.

When you open a result that an older version of LGE made, LGE first rebuilds the small database behind the viewport, a different thing from the Kraken 2 database, once while the project is open for editing, so the counts follow the rules this section describes. On the command line, `lungfish-cli build-db taxtriage` with the result folder and `--force` does the same.

### Choosing which samples to show

The table starts with every row of both samples, SRR12486983 first. The table is wider than the pane, so Coverage Breadth, Coverage Depth, and Abundance sit to the right of Confidence, and you scroll sideways to reach them.

A row of buttons above the table picks samples quickly. **All Samples** comes first, then one button per sample, and a batch of more than six samples gets a pop-up menu instead. Click SRR12486983 to read that sample alone, which leaves 130 rows. SRR12486989 alone has 63. **View > Next Sample** (Cmd-right bracket) and **View > Previous Sample** (Cmd-left bracket) step from one sample to the next.

That is far more than the ten of Top hits, which only sets where the pipeline starts. For SRR12486983 the pipeline downloaded 983 reference sequences, covering many more organisms than its ten top hits, and mapped every read against all of them at once.

The buttons are shortcuts into the [Inspector](../../GLOSSARY.md#inspector), the panel on the right of the window. Its **Samples & Metadata** section holds the **Sample Filter** list, with a tick box for each sample, and its Select All and Filter… controls work as [The taxonomy viewport](02-running-kraken2.md#the-taxonomy-viewport) describes.

The **Filter organisms…** field at the right end of the row of sample buttons keeps only the rows whose organism name contains what you type. With both samples ticked, typing a name such as Kocuria leaves only that genus's rows, all of SRR12486983's first and then all of SRR12486989's, with the Sample column telling them apart. The Organisms card then counts only those rows, 15 for Kocuria, and the first row is selected.

<!-- SHOT: taxtriage-batch-overview -->

Click **All Samples**, or choose **View > All Samples**, and the list gives way to an overview grid with one row per organism across the batch. Its first columns give the number of samples the organism appears in, its mean TASS score, and the range of its read counts, and one column per sample follows. A control above the grid switches the sample columns between TASS Score, Total Reads, Unique Reads, and Coverage, and a double-click on a value opens that sample's list with the organism selected. Click **All Samples** again to return to the list.

### The organism table

The table holds one row per organism per sample, under nine columns.

| Column | What it shows |
|---|---|
| Sample | The Sample ID the row belongs to |
| Organism | The organism's name |
| TASS Score | The TASS score from 0 to 1, to three decimals |
| Reads | How many reads TaxTriage placed on this organism's genomes, after its [mapping-quality](../../GLOSSARY.md#mapping-quality) and conflict filters dropped poor or ambiguous placements. TaxTriage reports it as `# Reads Aligned`. It counts [primary alignments](../../GLOSSARY.md#primary-alignment), one per read, summed over every reference genome of the organism, so the two mates of a pair count separately |
| Unique Reads | The reads that are not copies of one another, so a high value means many independent reads back the organism. It counts the organism's primary alignments in the result's [BAM](../../GLOSSARY.md#bam) file that LGE did not [mark as duplicates](../../GLOSSARY.md#mark-duplicates), before TaxTriage's filters. The EsViritu, NAO-MGS, and NVD views have a [Unique Reads](../../GLOSSARY.md#unique-reads) column of the same kind. A dash means the BAM holds more such reads than TaxTriage kept, so the count does not apply to that row |
| Confidence | High, Medium, or Low, as the next section explains |
| Coverage Breadth | The share of the reference the reads reached, as a percentage |
| Coverage Depth | The mean depth, written with × for times |
| Abundance | The Reads figure as a share of every read in the sample |

Rows arrive in TaxTriage's own order, highest TASS score first within each sample. To sort by another column, click its header and choose **Sort Descending** or **Sort Ascending** from the menu that opens.

Depth is an average over every position of the genome, so it can fall below one. A depth of 0.1× means the reads, laid end to end, would cover only a tenth of the genome, so most positions have no read at all. The table rounds depth to one decimal, so 0.0× can still mean some reads, fewer than 0.05 per position on average.

Abundance is a [relative abundance](../../GLOSSARY.md#relative-abundance), the reads TaxTriage aligned to the organism divided by every read in the sample. For HSV-1 in SRR12486983, TaxTriage's report gives 1,481,003 aligned reads. That count is the Reads cell, and dividing it by every read in the sample gives the 15.36% in the Abundance cell. [Running Kraken 2](02-running-kraken2.md) counts a pair once, as one fragment, so when you report a count, name the tool and the column.

### The Confidence column

LGE gives every row one of three labels derived from its TASS score. They are unrelated to the K2 Confidence setting, which is the [Kraken 2 threshold](../../GLOSSARY.md#confidence-kraken-2) of the same name.

| Label | Rule |
|---|---|
| High | TaxTriage itself called the organism present, because its score passed the pipeline's threshold of 75 on the 0 to 100 scale, which is 0.75 in the TASS Score column |
| Medium | Below the pipeline's threshold, with a TASS score of 0.40 or more, a line that LGE sets itself |
| Low | A TASS score below 0.40 |

In the example run *Streptococcus agalactiae* reads High at 0.780. Hold the pointer over a Confidence or TASS Score cell to see a tooltip that states the rule behind that row's label.

### What the TASS score means

The TASS score folds several measures into one value. They include how cleanly the reads map, whether they map to this organism rather than equally well to others, and how evenly they spread along the reference. It weighs how well the evidence hangs together, not how many reads there are, so a few thousand reads that map cleanly and only to one organism can score as high as millions.

The score does not measure how much of the organism there is, and it is not a probability that the organism caused a disease. A harmless skin bacterium with clean, evenly spread reads can outscore a pathogen, and the example run shows exactly that. A thin organism can also score near 1, so read Coverage Breadth and Coverage Depth beside it.

### The example run

Here are the top rows for SRR12486983, the HSV-1 case, as the table shows them.

| Organism | TASS Score | Coverage Breadth | Coverage Depth |
|---|---|---|---|
| *Bradyrhizobium* sp. WCU1 | 1.000 | 31.8% | 0.5× |
| Human alphaherpesvirus 1 | 0.930 | 100.0% | 733.3× |
| *Actinomyces oris* | 0.930 | 2.0% | 0.1× |
| *Kocuria* sp. BT304 | 0.920 | 100.0% | 39.5× |
| *Micrococcus luteus* | 0.920 | 4.8% | 0.1× |

HSV-1 is second by score, level with *Actinomyces oris*, and it is plainly the finding. Its reads cover the whole 152,222-base reference, 733.3 deep on average, and about 15 percent of all the sample's reads came from the virus. The row above it scores higher with far less behind it. *Bradyrhizobium* reaches under a third of its genome at a depth of 0.5, and *Actinomyces oris* reaches 2 percent at 0.1, so their reads are real but thinly spread. *Kocuria* sp. BT304, a bacterium of skin and the environment, covers its whole genome, which says its DNA is really in the tube and says nothing about whether it did any harm. *Streptococcus agalactiae* does not appear in this sample.

Now untick SRR12486983 and tick SRR12486989, the *Streptococcus agalactiae* case.

| Organism | TASS Score | Coverage Breadth | Coverage Depth |
|---|---|---|---|
| *Kocuria* sp. BT304 | 0.980 | 91.9% | 4.0× |
| *Cutibacterium acnes* | 0.960 | 6.6% | 0.1× |
| *Bradyrhizobium* sp. WCU1 | 0.890 | 3.5% | 0.0× |
| *Cellulosimicrobium cellulans* | 0.890 | 7.0% | 0.1× |
| *Streptococcus agalactiae* | 0.780 | 27.8% | 0.4× |

The recorded pathogen sits fifth, just past TaxTriage's threshold, covering 27.8 percent of its genome at a depth of 0.4. HSV-1 does not appear in this sample at all. Four organisms outscore the pathogen, among them *Cutibacterium acnes*, a common skin bacterium, and the same *Kocuria* and *Bradyrhizobium* as in the first sample.

That answers a question [Running Kraken 2](02-running-kraken2.md#the-same-reads-a-different-database) left open. Standard-16 found *Kocuria*, *Cutibacterium acnes*, *Bradyrhizobium*, and *Cellulosimicrobium* in the HSV-1 sample and could not say where they came from. TaxTriage finds the same four in a second patient's cornea with a different infection. Organisms that turn up in sample after sample, whatever the diagnosis, are the usual sign of skin, reagent, or bench [contamination](../../GLOSSARY.md#contamination) rather than infection. The report files *C. acnes* as a commensal of skin and *Kocuria* sp. BT304 and *Bradyrhizobium* sp. WCU1 as Unknown, which says only that TaxTriage has no annotation for them. In the second sample *C. acnes*, *Bradyrhizobium*, and *Cellulosimicrobium* also reach under 10 percent of their genomes, and thin coverage fits traces better than an infection. That is the pattern [Why a classifier reports things that are not there](01-what-is-classification.md#why-a-classifier-reports-things-that-are-not-there) describes.

Compare *Streptococcus agalactiae* from the second sample with *Bradyrhizobium* from the first. The numbers are much alike, about 30 percent breadth at a depth under one. Nothing in these columns alone says which is the pathogen and which came from a reagent. TaxTriage's own annotations and a negative control make that call, as the next section explains.

### Recognising the pathogen

No single column picks out the pathogen. Read four things together.

1. The TASS score and Confidence label, which say the organism's DNA is really in the tube.
2. Coverage breadth and depth, which say how much of the genome the reads support.
3. TaxTriage's own annotations in its report, described below.
4. A negative control, which says what the lab and reagents put in every tube.

The viewport does not show TaxTriage's annotations, so open the pipeline's report, which TaxTriage calls its organism discovery report. Select a row and click **Open Report** in the action bar to open the report for that row's sample, `<sample>.odr.pdf`, or the HTML version when there is no PDF. The report files sit in each sample's own `report` folder, such as `<result folder>/SRR12486983/report/`, which **Show in Finder** on the result's right-click menu in the sidebar reaches. `all.odr.pdf` there holds that one sample, since each sample ran alone. The file `<sample>.odr.txt` there holds the same table as tab-separated text, which Numbers or Excel opens with one column per field.

The report's **Microbial Category** column sorts organisms into Primary, Opportunistic, Potential, Commensal, and Unknown, as [TaxTriage's documentation](https://jhuapl-bio.github.io/taxtriage/stable/microbial-categories/) defines them. Primary marks a recognised pathogen. Opportunistic marks an organism that causes disease mainly in a weakened host, and Potential one with case reports but no established role as a routine cause. Commensal marks one that normally lives harmlessly on the body, and Unknown means TaxTriage has no annotation for it. In the example run, Human alphaherpesvirus 1 and *Streptococcus agalactiae* are both Primary, and the high-scoring *Kocuria* and *Bradyrhizobium* rows are Unknown. The **High Consequence** column flags organisms of special public-health concern and reads False for both pathogens.

This batch has no negative control, so it cannot show which organisms came from the laboratory, and a table with no warning signs here means untested, not clean. When you run your own samples, include a control and give it the Negative Control or Extraction Blank role in the dialog. An organism that has any row in a negative control is suspect in every sample of the batch, whatever its score in the specimens, and LGE sets no minimum read count, so compare the control's amounts with the specimen's yourself. LGE marks every such organism in the table with a warning sign and orange text, and its tooltip says it was detected in a negative control sample. The overview grid adds a Risk column for the same organisms, and **Export Organism Matrix (CSV)…** counts them as a risk even when the samples you export leave the control out.

A control helps only if it ran. When a negative control failed, cannot be found in the results, or ran with a step that stopped with an error, a note above the table says "Contamination risk is not checked." or "Contamination risk is only partly checked.", names the control, says what to do, and ends "Where no warning sign shows, the risk is not checked." The exports agree, and their Contamination Risk column reads Not checked where it would otherwise read No. The same note warns when two sample names meet in the pipeline's reports, because the results then cannot tell those samples apart.

The note belongs to the whole view, not to any row. A row copied with **Copy Row as TSV**, or a screenshot of the table alone, leaves it out and then reads as if the control were clean. Keep the note with anything you copy, or use **Export**, which writes Not checked into every affected row.

TaxTriage reports what DNA is in the tube. Deciding that an organism caused a patient's infection is a clinical judgement, and confirming a pathogen for patient care needs your laboratory's own validated tests.

### The alignment pane

Selecting a row loads its reads into the alignment pane, drawn against the reference that row's own sample mapped them to, so you can see where along the genome the evidence sits. If a row has no mapped reads to draw, the pane stays closed. Zoomed out to the whole genome, the pane draws a coverage track, the depth of reads along the reference, and asks you to zoom in to view individual mapped reads. To zoom in, click into the pane and press Cmd-plus, or pinch on a trackpad, as [Keyboard Shortcuts](../appendices/keyboard-shortcuts.md#inside-the-bam-alignment-viewport) lists. For HSV-1 the track spans the 152,222-base reference NC_001806.2.

The pane works out its own covered share and mean depth from the alignment file, so its figures can differ a little from the table's. The HSV-1 pile, 733.3 deep on average, runs deeper than 500, the most reads the pane draws over one position by default, so the pane draws a subset of its reads, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains, while the table's figures come from TaxTriage's report.

LGE reads each sample's reads from that sample's own alignment file in the result's `minimap2` folder, named `<sample>.bam` or `<sample>.<sample>.dwnld.references.bam`. When neither file is there, it reads the one file whose name fits the sample, and the action bar and a `BAM note:` line in the Inspector say that the file may belong to another sample.

<!-- SHOT: taxtriage-result-table -->

### Working with rows

The action bar along the bottom is the one every classifier viewport shares, as [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes. It holds **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**, with TaxTriage's own **Open Report** beside them.

**Verify with BLAST…** sends reads of the selected row to NCBI for a second opinion, as [BLAST Verification](06-blast-verification.md) explains, and needs exactly one row selected in the list. In the overview grid it stays dimmed, and its tooltip asks you to choose one sample. **BLAST Results** shows or hides the search results below the table.

**Extract Reads…** saves the reads that mapped to the selected organisms as a new bundle by default. It takes any number of rows, from one sample or several, and opens the dialog [Running Kraken 2](02-running-kraken2.md#extract-the-reads-of-one-taxon) documents. A selected row with no reference [accession](../../GLOSSARY.md#accession) in its own sample is left out, and the dialog names it. When no selected row has one, an alert titled Nothing to extract says so and nothing is written.

Right-clicking a row offers **Verify with BLAST…**, **Copy Name**, **Copy Taxon ID**, **Copy Row as [TSV](../../GLOSSARY.md#tsv)**, **Open Taxonomy on NCBI**, and **Extract Reads…**. Copy Row as TSV copies the row as tab-separated text you can paste into a spreadsheet. With several rows selected, only Extract Reads… applies.

**Export** offers **Export as CSV…** and **Export as TSV…**, which write the rows the table shows at that moment, with columns for the sample, the scores and counts, the taxonomy ID, and a Contamination Risk flag. **Copy Summary** copies a short text summary of the run and of what the view shows. A batch adds **Export Organism Matrix (CSV)…** and **Export Batch Report…**.

The info button at the right end of the action bar opens a popover of the run's facts, such as its samples, platform, runtime, and main settings. The run's full [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, goes further. For a Kraken 2 database that LGE installed, it names the database's release and the [checksum](../../GLOSSARY.md#checksum) recorded at install, and it marks a database without that install record as unpinned.

## What good looks like

The TaxTriage viewport answers four of the five questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist). Reads says how many reads support each organism, Coverage Breadth and Depth say how they spread along the genome, Unique Reads says how many are independent, and a negative control in the batch shows what the laboratory added. **Verify with BLAST…** answers the fifth, whether an independent method agrees.

Check the run first. A result where every TASS Score reads 0.000, or whose Operations Panel row reads Completed with Warnings with a step killed for lack of memory, is a failed run, and for a human sample the usual cause is an empty **Exclude host taxa** field, as [Keep the human genome out of the top hits](#keep-the-human-genome-out-of-the-top-hits) explains. Then look above the table. A note saying contamination risk is not checked means a control's evidence is missing, so no organism is cleared yet.

Then read coverage breadth and depth beside the score. A breadth near 100 percent with a depth of several reads or more, like HSV-1's 100 percent at 733.3, is what an abundant organism looks like. A depth below one means most of the genome has no read, so the organism is present at most in trace amounts, whatever its score. A breadth of a few percent with a large read count is the classic shape of a false call, because every read landed in one place.

Then compare Reads with Unique Reads. Where Unique Reads shows a number, it is at most the Reads figure, and a much smaller one means much of the evidence is copies of a few original fragments. A very deep genome loses some reads this way by chance, because many reads start at the same position. An [amplicon](../../GLOSSARY.md#amplicon) library, where PCR copied chosen targets from short starter sequences called primers before sequencing, is an exception. There every fragment starts at a primer, so many reads look like copies.

Then check the database against the question. TaxTriage reports only organisms its Kraken 2 database contains. Standard-16 holds bacteria, archaea, viruses, and the human genome but no fungi or protozoa, so its silence about them says nothing about them.

Then read your controls and TaxTriage's Microbial Category, as Recognising the pathogen explains. Send any call that matters to [BLAST](../../GLOSSARY.md#blast) with **Verify with BLAST…** before you act on it. A result whose reads match the organism at high identity backs the call, as [BLAST Verification](06-blast-verification.md) explains.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. You can skip this section if you work in the app, because the dialog covers the prerequisite check and the run, and the Import Center covers the import. Most flags of `taxtriage run` are listed in [Classification](../appendices/cli-reference.md#classification) in the CLI Reference, and `lungfish-cli taxtriage run --help` shows every one.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"

lungfish-cli taxtriage check-prerequisites
lungfish-cli taxtriage run \
  --input "$PROJECT/Imports/SRR12486983.lungfishfastq" \
  --input "$PROJECT/Imports/SRR12486989.lungfishfastq" \
  --project "$PROJECT" \
  --batch \
  --db "$HOME/.lungfish/databases/kraken2/kraken2-standard-16" \
  --remove-taxids 9606

# Import a TaxTriage output folder made elsewhere.
lungfish-cli import taxtriage "/path/to/taxtriage-output" \
  --output-dir "$PROJECT/Imports"
```

A passing check reports `Container runtime: Docker Desktop (running)` and ends with the line `All prerequisites met. Ready to run TaxTriage.` Like the dialog, it asks Docker alone, and when Docker cannot be reached it prints `Container runtime: not available` followed by the reason in parentheses, then says prerequisites are missing and exits with status 126. By default, `$HOME/.lungfish/databases/kraken2` is where the Plugin Manager installs Kraken 2 databases for the Preview build, and the Stable build uses `$HOME/.lungfish-stable` instead.

Each `--input` names one sample, named after its bundle, and `--batch` runs each sample alone, as the dialog does. `--project` puts the result in the project's `Analyses` folder as `taxtriage-batch-` with the date and time. The command line fills in no default for `--remove-taxids`, so pass it yourself for every human sample. The command that Copy CLI Command copies from the Operations Panel row also names every other setting at its value.

A bundle given to `--input` is read whole, as the dialog reads it. A file inside a bundle is read as named, so naming one file of a bundle that holds several reads only that file, except the preview file of a [virtual bundle](../../GLOSSARY.md#virtual-bundle), a bundle that keeps only a preview of its reads, which reads its whole bundle. A bundle whose sample role is Negative Control or Extraction Blank marks its sample as a negative control, and `--negative-control` with a sample's name marks any other. With `--output` in place of `--project` and no `--batch`, one Nextflow run takes every sample, and an output folder whose name begins with `taxtriage-` inside the project's `Analyses` folder opens in the TaxTriage viewport too.

## Next

Continue to [BLAST Verification](06-blast-verification.md), which checks a classifier's call against NCBI's full collection, the independent method the last question of the evidence checklist asks for. It uses the HSV-1 call from [Running Kraken 2](02-running-kraken2.md), and the same popover verifies a TaxTriage row.
