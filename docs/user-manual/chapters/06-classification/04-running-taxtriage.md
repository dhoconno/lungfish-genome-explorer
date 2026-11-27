---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification, 06-classification/02-running-kraken2]
estimated_reading_min: 32
task: Run the TaxTriage pathogen workflow on two clinical FASTQ bundles against an installed Kraken 2 database, keep the human genome out of its top hits, and read the organism table and the evidence behind each call.
tags: [classification, taxtriage, nextflow, container, confidence, pathogen-detection]
tools: [taxtriage]
parameters_refs: [classify.taxtriage]
entry_points:
  - "Tools > Classification > TaxTriage…"
  - "CLI: lungfish-cli taxtriage run"
shots:
  - id: taxtriage-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > TaxTriage… with SRR12486983 and SRR12486989 selected, showing both samples as Clinical Sample rows, the Prerequisites row with its Nextflow and Docker Desktop indicators, the Kraken2 Database picker on Standard-16, Sequencing Platform on Illumina, Skip assembly (faster) checked, the Exclude host taxa field holding 9606, and Advanced Settings collapsed."
  - id: taxtriage-advanced-settings
    caption: "The dialog's Advanced Settings section expanded, showing the K2 Confidence slider at 0.20, the Top hits stepper at 10, the Max memory stepper at 16 GB, the Max CPUs stepper at 14, the Skip Krona visualization checkbox, and an empty Extra arguments field, below the Exclude host taxa field holding 9606."
  - id: taxtriage-running-row
    caption: "The Operations Panel during the two-sample run, with the row titled TaxTriage (2 samples) and its detail line naming the sample at work, its place in the batch as Sample 1/2 or Sample 2/2, and the pipeline step that is running."
  - id: taxtriage-batch-overview
    caption: "With both samples selected and Kocuria in Filter organisms…, the Organisms card reads 15 and the table shows SRR12486983's rows from Kocuria sp. BT304 at 0.920 High to Kocuria sp. MNB10 at 0.380 Low, followed by SRR12486989's rows starting with Kocuria sp. BT304 at 0.980 High, while the pane below shows the selected first row's coverage track."
  - id: taxtriage-result-table
    caption: "In List Over Detail, both samples are selected in the Inspector's Sample Filter, the cards read Batch TaxTriage, Samples 2, and Organisms 193, and the selected Human alphaherpesvirus 1 row for SRR12486983 shows TASS Score 0.930, Reads 1.5M, and High above a coverage track spanning all 152,222 bases of the HSV-1 reference NC_001806.2."
illustrations: []
glossary_refs: [minimap2, accession, amplicon, bam, blast, bundle, checksum, container, docker, coverage-breadth, depth, fastq, fragment, inspector, kraken2, k-mer, library-prep, lowest-common-ancestor, mapping-quality, mark-duplicates, multiqc, negative-control, nextflow, operations-panel, paired-end, pinned, plugin-pack, primary-alignment, provenance, read, read-classification, reference-genome, required-setup-pack, samplesheet, shotgun, sra, taxon, taxonomy-id, tass-score, taxtriage, tsv, viewport, mate, unique-reads, confidence-kraken-2, contamination, relative-abundance, false-positive, read-merging, single-end, virtual-bundle]
features_refs: [classify.taxtriage, classify.blast-verify, classify.extract-reads, provenance.result-popovers, results.table-row-commands, containers.run, operations.panel]
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: true
lead_approved: true
---

## What it is

[TaxTriage](../../GLOSSARY.md#taxtriage) checks sequencing [reads](../../GLOSSARY.md#read), stretches of sequence reported by the instrument, for evidence of pathogens. A pathogen is an organism or virus that can cause disease. A [FASTQ](../../GLOSSARY.md#fastq) file stores each read and a quality score for each base. A workflow is a series of programs that [Nextflow](../../GLOSSARY.md#nextflow) runs in order.

[Kraken 2](../../GLOSSARY.md#kraken2) looks up short pieces of each read in an installed database to assign the read to an organism or group. This is [read classification](../../GLOSSARY.md#read-classification), covered in [Running Kraken 2](02-running-kraken2.md). TaxTriage starts with the organisms Kraken 2 names most often, adds any organism on its own list of known and possible pathogens that Kraken 2 names at all, and downloads [reference genomes](../../GLOSSARY.md#reference-genome), published sequences for comparison. It maps the sample's reads to those references with [minimap2](../../GLOSSARY.md#minimap2), a program that finds where each read fits best.

TaxTriage combines evidence from mapping into a [TASS score](../../GLOSSARY.md#tass-score) for each organism it reports. This is a confidence score, with higher values indicating stronger evidence that the organism is present. Lungfish Genome Explorer (LGE) divides the reported score by 100 and labels each organism **High**, **Medium**, or **Low**, as [The Confidence column](#the-confidence-column) explains. This chapter uses *call* for an organism assignment you can assess from the evidence.

LGE uses TaxTriage release v3.3.8. A [pinned](../../GLOSSARY.md#pinned) release is a fixed version of the workflow code. TaxTriage fetches references from NCBI, the United States National Center for Biotechnology Information, on each run and records which it used. Each step runs in a [container](../../GLOSSARY.md#container), a package with the program and what it needs to run. [Docker Desktop](../../GLOSSARY.md#docker) runs those containers on your Mac. Nextflow comes in the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the set of tools the Welcome window offers to install the first time you open LGE. TaxTriage needs no additional [plugin pack](../../GLOSSARY.md#plugin-pack), a group of tools LGE installs on request.

## Why you would do this

Use TaxTriage to compare evidence for organism calls across samples. Two rows can have the same read count even when one has reads spread across the genome and the other has reads piled on a short stretch. A stretch that resembles the DNA of other organisms, such as a gene many species share, can collect their reads by mistake. [Coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of the reference reached by reads. Mean [depth](../../GLOSSARY.md#depth) is the average number of reads per position, including positions with no reads. Compare both measures to see whether the count comes from reads that reach much of the reference or from repeated coverage of a small part.

A [negative control](../../GLOSSARY.md#negative-control) is a tube of water or buffer carried through the protocol in place of patient material. Reads assigned to an organism in that control can point to [contamination](../../GLOSSARY.md#contamination), material introduced from another source such as reagents or the bench. Include the control in the batch so LGE can flag the same organisms in the specimens.

To compare classifiers, see [Choosing a tool](01-what-is-classification.md#choosing-a-tool) for the differences among LGE's options. The TaxTriage paper by Merritt and colleagues 2026 appears in [Pinned external pipelines](../appendices/bibliography.md#pinned-external-pipelines) in the bibliography.

The example uses two samples from the human cornea, the clear front surface of the eye. They come from BioProject PRJNA381365, NCBI's record of a study of corneal specimens preserved in formalin, a formaldehyde solution that stops tissue from breaking down. The study's records name the infection for each case.

The [Sequence Read Archive](../../GLOSSARY.md#sra) (SRA), NCBI's public store of sequencing data, calls each dataset a sequencing run. SRR12486983 is the herpes simplex keratitis case from [Running Kraken 2](02-running-kraken2.md), an eye infection by herpes simplex virus 1 (HSV-1). SRR12486989 is a case recorded as an infection by *Streptococcus agalactiae*. In the Kraken 2 protocol [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y), Lu et al. 2022 use SRR12486983 as the example run.

A [sequencing library](../../GLOSSARY.md#library-prep) is DNA prepared for sequencing. Both cases use [shotgun](../../GLOSSARY.md#shotgun) libraries made by breaking the tissue DNA into random fragments, or pieces. Compare the recorded pathogens with the other organisms in each table to see what the score and coverage can tell you.

## Before you start

Open a project so LGE has an `Analyses` folder for the result, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) describes. Without a project, LGE shows the **No Project Open** alert. From **Help > Demo Projects…**, open Pathogen Detection, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds both sequencing runs as [bundles](../../GLOSSARY.md#bundle), folders LGE treats as individual items.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for this example dataset. The [kraken-protocol-cornea fixture README](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea) lists the source and terms of use. [BLAST](../../GLOSSARY.md#blast) is NCBI's search that compares a sequence with its full public collection. The Kraken 2 and BLAST chapters use the same fixture.

To get the reads yourself, download `SRR12486983` and `SRR12486989` as shown in [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). These are [paired-end](../../GLOSSARY.md#paired-end) runs. The sequencer reads each DNA [fragment](../../GLOSSARY.md#fragment) from both ends, producing a read pair. The bundles are `Imports/SRR12486983.lungfishfastq` with 4,819,760 read pairs and `Imports/SRR12486989.lungfishfastq` with 5,440,369.

TaxTriage needs Nextflow, Docker Desktop, and a Kraken 2 database. Install Nextflow through the **Required Setup** section of **Plugin Manager**, where it is part of the **Third-Party Tools** pack. Download Docker Desktop from the Docker website. Install and open it before the run so the check sees it as **Running**. For help setting it up, see [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) in Plugin Packs.

Choose **Apple menu > About This Mac** to check your Mac's memory. This example uses Standard-16, which covers bacteria, archaea, viruses, and the human genome and is sized for a Mac with 16 GB of memory. Use Standard-8 if your Mac has less than 16 GB. To download a database, open the **Databases** tab in **Tools > Plugin Manager…**, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) explains. Standard-16 takes about 16 GB to download, so check your free disk space against the [System requirements](../01-foundations/06-the-lungfish-project.md#system-requirements) before downloading.

On the test Mac, which has 14 processor cores, the two-sample run took about 21 minutes. A processor core is a unit in a chip that carries out calculations. The first run also downloads container images, the stored copies each container starts from. Later runs reuse them, but every run still needs internet access.

## Procedure

### Select both samples and check the prerequisites

1. Click the SRR12486983 bundle in the project sidebar, then Cmd-click the SRR12486989 bundle so that both are selected.

2. Choose **Tools > Classification > TaxTriage…**. **TaxTriage** is selected in the **FASTQ/FASTA Operations** dialog, which follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Prerequisites** row at the top of the TaxTriage settings. Check the **Nextflow** indicator and whether **Docker Desktop** says **Running**, **Not running**, or **Not installed**. Green means ready, orange means the check failed, and a spinner means the check is still running. The check asks Docker itself, so Apple's own container system never turns this dot green, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains.

    <!-- SHOT: taxtriage-dialog -->

4. If either dot is orange, **Run** stays disabled and the footer reads "Complete the classifier settings to continue." An orange dot beside **Nextflow** means the Required Setup pack is missing or broken, so open **Tools > Plugin Manager…** and install it from the **Required Setup** section, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. An orange **Docker Desktop** dot means Docker Desktop is not installed or not running, so install it or start it. Reopen the dialog to run the check again.

<!-- WAIT ux-text TV-SHELL -->

### Check the samples

Check that **Samples** lists SRR12486983 and SRR12486989. There is one row per bundle, and each bundle runs as its own sample. Paired read files often end in `_1` and `_2`, or `_R1` and `_R2`. With bundles named `Swab_1` and `Swab_2`, the dialog shows two rows and the message "Swab_1 and Swab_2 run as two samples because each FASTQ bundle is one sample. To run them as two reads of one sample, import both read files together as a pair."

The message leaves **Run** available. If both files belong to one sample, click **Cancel** and import the files together as one paired bundle, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md#procedure) shows. Then reopen TaxTriage on that bundle.

1. Read each **Sample ID** field. It starts with the bundle's full name, with an ending such as `_1` or `_R1` kept, and the pipeline reports the sample under it. When you run several samples, leave each Sample ID as LGE filled it in. In a run of several samples, typing an ID or using a bundle name with a dot, such as `Pt.7`, triggers **TaxTriage Cannot Run These Samples**. LGE uses bundle names to match samples to results in a batch. A typed ID would break that match, and LGE drops everything after the last dot when it names samples. Rename such a bundle in the sidebar before you open the dialog.

2. Leave the role picker at the right of each row on **Clinical Sample**, because both samples are patient specimens. Sample metadata is information stored about a sample. LGE sets the picker from the bundle's sample metadata and uses **Clinical Sample** when there is no recorded role. See [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) for how to record a role.

    For your own samples, choose **Negative Control** for a tube without sample DNA or **Extraction Blank** for one carried through extraction without specimen material. Either role marks the sample as a negative control. Whatever the picker shows, either role recorded in the bundle's metadata also marks it as a negative control. The other control roles are **Positive Control** and **Environmental Control**.

3. Use **Remove** to drop a row. Select all bundles you need in the sidebar before opening the dialog. **Add Sample** creates an empty row that cannot hold reads. The run skips that row, so use the project sidebar to add bundles to your selection.

4. Check that sample names stay distinct after the pipeline replaces spaces and drops symbols. The pipeline turns a space into an underscore and drops symbols such as brackets, so `A (1)` and `A_1` both become `A_1`. When two names meet like that, an orange line under the list says so and **Run** stays disabled until you rename one. Rename a bundle in the sidebar and open the dialog again, or run the samples one at a time.

### Choose the database and the platform

Choose **Standard-16** in the **Kraken2 Database** picker, or **Standard-8** if your Mac has less than 16 GB of memory. If you see "No Kraken2 databases installed", download a database from the **Databases** tab in **Tools > Plugin Manager…** and reopen the dialog.

The sequencing runs' SRA records name an Illumina NextSeq 550, an instrument that reads short pieces of DNA. Leave **Sequencing Platform** on **Illumina** for the example. A bundle that already records its platform runs on that platform whatever **Sequencing Platform** shows, so the setting matters only when a bundle records no platform TaxTriage can use, as [How LGE decides the platform](../03-reads/01-importing-fastq.md#how-lge-decides-the-platform) explains.

Assembly joins overlapping reads into longer sequences without a reference. TaxTriage can classify and score organisms without it, so leave **Skip assembly (faster)** checked. The line under it reads "Classification and confidence scoring only. Significantly faster."

### Keep the human genome out of the top hits

The top hits are the organisms with the most Kraken 2 reads, up to the **Top hits** number at each rank of the Kraken 2 report, which lists how many reads went to each organism or group. A rank is a level of grouping, such as species or genus. TaxTriage adds every organism on its pathogen list that Kraken 2 found, however few its reads, and downloads references for the species in the combined list.

To keep the human genome out of the top hits, leave **Exclude host taxa** at 9606 below **Skip assembly (faster)**. LGE fills it in because both rows are Clinical Sample. A [taxon](../../GLOSSARY.md#taxon) is a named group of organisms. A [taxonomy ID](../../GLOSSARY.md#taxonomy-id), or taxid, is the number NCBI assigns to each taxon. The help line reads "NCBI taxids removed before TaxTriage picks references, separated by spaces. 9606 is human. Leave empty to keep every taxon."

Open **Advanced Settings** and keep the defaults. On the test Mac these were **K2 Confidence** 0.20, where K2 stands for Kraken 2, **Top hits** 10, **Max memory** 16 GB, and **Max CPUs** 14, based on the number of processor cores. Leave **Extra arguments** empty. A stepper is a pair of small up and down arrows beside a number.

<!-- SHOT: taxtriage-advanced-settings -->

<!-- WAIT ux-text TV-SHELL -->

If you type `--remove_taxids` in **Extra arguments**, it overrides **Exclude host taxa** and the help line says the field is unused. The Kraken 2 report summarizes how many reads went to each taxon. **Exclude host taxa** removes listed taxa from that report before TaxTriage selects its top hits. With 9606 in place for these samples, human reads stay in the input but the human genome stays out of the top hits. For an animal sample, see **Exclude host taxa** under Settings for how to enter the host's ID.

Standard-16 includes the human genome, and human tissue samples contain mostly human DNA. Clearing the field for these samples puts *Homo sapiens* among the top hits. TaxTriage then downloads GRCh38, the standard human reference genome of about 3.1 billion bases. With the 16 GB limit in this example, Nextflow stops the mapping step for lack of memory. TaxTriage continues, but every **TASS Score** in the affected result reads 0.000.

To see which step failed, open the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists current and past jobs, with **Operations > Show Operations Panel** (Cmd-Shift-P). In this case the row reads **Completed with Warnings**. Its detail says "Some TaxTriage tasks failed", names the step, and adds "killed, usually for running out of memory" when applicable. The log identifies missing results and suggests **Max memory** or **Exclude host taxa**. The [Inspector](../../GLOSSARY.md#inspector), the panel on the right, shows a **Warnings** line under **Operation Details**, such as "1 ignored failure across 1 sample".

Use the failed step to decide whether you need to rerun a sample. If only plotting failed, the log says that only plots in the [MultiQC](../../GLOSSARY.md#multiqc) quality-control report are missing and that classifications, alignments, and TASS scores are complete.

### Run TaxTriage and open the result

1. Click **Run**. LGE runs `lungfish-cli taxtriage run`. CLI stands for command-line interface, which lets you run LGE commands by typing them in Terminal, the Mac app for typed commands. To save the command for your records, right-click the job in the Operations Panel and choose **Copy CLI Command**.

2. To follow progress, choose **Operations > Show Operations Panel** (Cmd-Shift-P) and find **TaxTriage (2 samples)**. Each sample runs separately in Nextflow. The detail line identifies the sample and step, for example `Sample 1/2 (SRR12486983): Running KRAKEN2_KRAKEN2 (SRR12486983)`. If Docker Desktop stopped after the dialog checked it, the detail reads "Docker daemon unavailable. Launching Docker Desktop..." while LGE starts it. **Cancel** stops Nextflow and then stops and removes the Docker containers the run started, so nothing keeps working in the background.

    <!-- SHOT: taxtriage-running-row -->

3. The result appears in the sidebar when the job finishes. Click its folder under `Analyses/` to open the TaxTriage [viewport](../../GLOSSARY.md#viewport), the panel that shows the result. See [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) for how the project organizes analyses. The folder is named `taxtriage-batch-` followed by the date and time, such as `taxtriage-batch-2026-09-25T03-40-19`, and holds one subfolder per sample.

LGE splits each paired bundle into its [mates](../../GLOSSARY.md#mate), the two reads of each pair, so TaxTriage can map them together. The R1 and R2 files hold the first and second read of every pair, respectively. Bundles that store these files separately also run as pairs. A bundle that mixes pairs with unpaired reads, such as reads [merged](../../GLOSSARY.md#read-merging) by joining overlapping mates, runs [single-end](../../GLOSSARY.md#single-end), with all reads in one file and no pairs. The same applies to bundles imported as several files of single reads. Check the job log for the reason. If one sample fails while the other completes, the row reads **Completed with Warnings** and its detail counts the failed sample.

For a methods section, record TaxTriage release v3.3.8 and copy the settings from the Inspector's **Operation Details**, such as **Platform**, **Confidence**, **Top Hits**, **Max Memory**, **Database Path**, and **Runtime**. A [provenance](../../GLOSSARY.md#provenance) record describes how a result was made. For a database LGE installed, look there for its release and [checksum](../../GLOSSARY.md#checksum). A checksum is a short fingerprint used to detect changes to a file.

### Importing a TaxTriage result made elsewhere

To review a colleague's TaxTriage result in the viewport, ask for the output folder. Choose **File > Import Center…** (Cmd-Shift-I), click the **Classification Results** tab, and click **Import…** on the **TaxTriage Results** card, whose file hint reads "TaxTriage output directory". Pick the folder and click **Open** to start the import.

LGE looks inside for each sample's organism report, `<sample>.odr.txt` or `<sample>.organisms.report.txt`, and also picks up the run's `nextflow.log`, `trace.txt`, and Krona chart when present. A Krona chart is an interactive web page showing the organisms.

Find the import at `Imports/taxtriage-<name>`. For `<name>`, LGE takes the folder name up to its last dot, if any. It keeps letters, digits, hyphens, and underscores and replaces other characters with underscores. It joins consecutive underscores and removes leading and trailing ones. It keeps an existing `taxtriage-` prefix and adds `-2` for a second import of the same name.

If the folder includes `taxtriage-result.json` from an LGE run, the import keeps the negative controls, settings, and database. Before sharing an import, check above the table for a note beginning "Not recorded by this import". The note means the import could not identify the controls. The settings and the export's **Contamination Risk** column read **Not recorded**.

## Settings

The numeric controls in **Advanced Settings** accept these values:

| Control | Values | Step |
|---|---|---|
| **K2 Confidence** | 0.00 to 1.00 | 0.05 |
| **Top hits** | **All organisms**, or 1 to 1,000 | |
| **Max memory** | 2 to 256 GB | 2 GB |
| **Max CPUs** | Up to your Mac's core count | |

**Sample ID.** Names the sample in the pipeline's reports. The default is the bundle's full name, including an ending such as `_R1` or `_1`, so reports match their bundles. Change it to your lab's identifier for a single sample, and leave it as filled in for several, as [Check the samples](#check-the-samples) explains. On the command line this is `--sample`.

**Sample role.** Identifies the material as a **Clinical Sample** or one of four control roles. The default is **Clinical Sample**, or the role the bundle's sample metadata records, so recorded roles carry into the run. Choose **Negative Control** or **Extraction Blank** for blanks, since only those roles flag organisms as a contamination risk, and see [Check the samples](#check-the-samples) if the stored role differs. On the command line this is `--negative-control`.

**Kraken2 Database.** Sets the collection Kraken 2 compares reads against. The default is the first installed Kraken 2 database, so check that it covers the organisms you want to find. Choose **Viral** for viruses only, **Standard-8** or **Standard-16** for a broad survey on an 8 GB or 16 GB Mac, or **PlusPF** for fungi and protozoa, as [Sensitivity, precision, and the database](01-what-is-classification.md#sensitivity-precision-and-the-database) explains. On the command line this is `--db`.

**Sequencing Platform.** Tells the pipeline what read lengths and errors to expect from **Illumina**, **Oxford Nanopore**, or **PacBio**. The default is **Illumina** for short reads, while **Oxford Nanopore** and **PacBio** are long-read platforms. If the bundle records no platform TaxTriage can use, choose the instrument on your sequencing run sheet, as [How LGE decides the platform](../03-reads/01-importing-fastq.md#how-lge-decides-the-platform) describes. On the command line this is `--platform`.

**Skip assembly (faster).** Skips de novo assembly, which joins overlapping reads without using a reference. The default is on because classification and scoring can run without assembly. Turn it off if you need assembled sequences and can allow hours more. On the command line this is `--no-skip-assembly`.

**Exclude host taxa.** Removes the listed NCBI taxonomy IDs from the Kraken 2 report before TaxTriage chooses its top hits, with spaces or commas separating the IDs. The default is 9606 for human when any row is a **Clinical Sample**, and empty otherwise, because most human specimens, such as tissue, swabs and blood, contain mostly human DNA. For animal samples, use [NCBI Taxonomy](https://www.ncbi.nlm.nih.gov/taxonomy) to find the host's ID, such as 9544 for rhesus macaque, or clear the field if you want to find the host. On the command line this is `--remove-taxids`.

**K2 Confidence.** Sets the minimum share of a read's [k-mers](../../GLOSSARY.md#k-mer), short pieces Kraken 2 looks up, that must support a taxon or the groups within it, counting only k-mers with unambiguous bases. The default is 0.20, one k-mer in five, so a read can qualify with partial support. Raise it with the slider or by typing a value if unexpected species fill the table, or lower it if an expected organism is missing, since reads below the threshold go to the nearest broader group that passes or stay unclassified. On the command line this is `--confidence`.

**Top hits.** Caps how many organisms TaxTriage adds from each rank of the Kraken 2 report when choosing references, most reads first, on top of every organism on its pathogen list that Kraken 2 found. TaxTriage aligns reads only to the organisms it chooses, so an organism outside the cap has no BAM and no Unique Reads. **All organisms** is on by default and chooses every species Kraken 2 found, so every organism gets a BAM. It means more reference downloads and a longer run. Turn it off and set a number with the stepper for a quicker run. On the command line this is `--top-hits`, where 1000000 chooses every species.

**Max memory.** Sets the pipeline's memory limit. The default is 16 GB, which is enough for this example with Standard-16 and the host excluded. On a Mac with less than 16 GB, set it a few gigabytes below what **Apple menu > About This Mac** shows, or raise it for a large database if you have memory to spare. On the command line this is `--max-memory`.

**Max CPUs.** Sets how many processor cores the pipeline can use at once. The default uses all available cores, 14 on the test Mac, so the pipeline can use the Mac's full processing capacity. Lower it to keep the Mac responsive during a long run. On the command line this is `--max-cpus`.

**Skip Krona visualization.** Skips the interactive Krona chart in the result folder. The default is off so you get the chart alongside the tables. Turn it on to save time if you only need the tables. On the command line this is `--skip-krona`.

**Extra arguments.** Passes text to TaxTriage and Nextflow without checking it, and a `--remove_taxids` here overrides **Exclude host taxa**. The default is empty because the dialog supplies the usual settings. Use it for options documented in the [TaxTriage repository](https://github.com/jhuapl-bio/taxtriage) that the dialog lacks, and close quotes around values with spaces to keep **Run** available. On the command line this is `--extra-args`.

## Reading the results

Use the summary cards to see what is in view and the organism table and alignment pane to assess each call. The default **Detail | List** layout puts the pane beside the table. The Inspector's **Panel Layout** also offers **List | Detail** and **List Over Detail**, with the pane below the table in the latter. See [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) for both layouts.

In this example the cards show **Batch** TaxTriage, **Samples** 2, and **Organisms** 193. **Organisms** counts rows, including one per sample for organisms found in both. A note above the table can tell you when a control did not run, as [Recognizing the pathogen](#recognizing-the-pathogen) explains. The figures here come from one run. A rerun can give slightly different numbers, such as 1,480,825 aligned reads for HSV-1 where this run gave 1,481,003.

LGE uses a small database behind the viewport to display the results. To rebuild it from the command line, run `lungfish-cli build-db taxtriage` with the result folder and `--force`.

### Choosing which samples to show

The table starts with every row of both samples, SRR12486983 first. The table is wider than the pane, so **Coverage Breadth**, **Coverage Depth**, and **Abundance** sit to the right of **Confidence**, and you scroll sideways to reach them.

Above the table, **All Samples** comes first, then one button per sample. For batches of more than six samples, use the pop-up menu. Click SRR12486983 to read that sample alone, which leaves 130 rows. SRR12486989 alone has 63. **View > Next Sample** (Cmd-right bracket) and **View > Previous Sample** (Cmd-left bracket) step from one sample to the next.

**Top hits** caps each rank of the starting list, and organisms Kraken 2 found on TaxTriage's pathogen list join it, so the result can have many more rows than the **Top hits** number. For SRR12486983 the pipeline downloaded 983 reference sequences, and the sample has 130 rows. One genome can span several sequences, such as chromosomes and plasmids.

Use the **Sample Filter** checkboxes in the Inspector's **Samples & Metadata** section to choose samples. See [The taxonomy viewport](02-running-kraken2.md#the-taxonomy-viewport) for **Select All** and **Filter…** in the Inspector.

The **Filter organisms…** field at the right end of the row of sample buttons keeps only the rows whose organism name contains what you type. With both samples selected, typing a name such as Kocuria leaves only the rows with Kocuria in their names, all of SRR12486983's first and then all of SRR12486989's, with the **Sample** column telling them apart. The **Organisms** card then counts only those rows, 15 for Kocuria, and the first row is selected.

<!-- SHOT: taxtriage-batch-overview -->

To compare an organism across samples, click **All Samples** or choose **View > All Samples**. The overview grid puts each organism on one row across the batch. Its first columns give the number of samples the organism appears in, its mean TASS score, and the range of its read counts, and one column per sample follows. A control above the grid switches the sample columns between **TASS Score**, **Total Reads**, **Unique Reads**, and **Coverage**, and a double-click on a value opens that sample's list with the organism selected. Click **All Samples** again to return to the list.

### The organism table

The list has one row per organism per sample, with nine columns.

| Column | What it shows |
|---|---|
| **Sample** | The Sample ID the row belongs to |
| **Organism** | The organism's name |
| **TASS Score** | The TASS score from 0 to 1, to three decimals |
| **Reads** | [Primary alignments](../../GLOSSARY.md#primary-alignment), one placement per read, across the organism's references after filtering. [Mapping quality](../../GLOSSARY.md#mapping-quality) estimates confidence in a placement, and the mapping-quality and conflict filters drop poor or ambiguous placements. TaxTriage reports `# Reads Aligned`, including duplicates and counting mates separately |
| **Unique Reads** | Primary alignments LGE left unmarked when it [flagged likely duplicate reads](../../GLOSSARY.md#mark-duplicates), counted in the BAM before TaxTriage's filters. A [BAM](../../GLOSSARY.md#bam) file stores where each read aligned. A dash means this count exceeds what TaxTriage kept, so the count does not apply to that row |
| **Confidence** | **High**, **Medium**, or **Low**, as the next section explains |
| **Coverage Breadth** | The share of the reference the reads reached, as a percentage |
| **Coverage Depth** | The mean depth, written with × for times |
| **Abundance** | The **Reads** figure as a share of every read in the sample |

Rows arrive in TaxTriage's own order, highest TASS score first within each sample. To sort by another column, click its header and choose **Sort Descending** or **Sort Ascending** from the menu that opens.

Depth is an average over every position of the genome, so it can fall below one. A depth of 0.1× means the reads, laid end to end, would cover only a tenth of the genome, so most positions have no read at all. The table rounds depth to one decimal, so 0.0× can still mean some reads, fewer than 0.05 per position on average.

**Abundance** is a [relative abundance](../../GLOSSARY.md#relative-abundance), the reads TaxTriage aligned to the organism divided by every read in the sample. For HSV-1 in SRR12486983, TaxTriage's report gives 1,481,003 aligned reads. **Reads** shows that count. Divide it by the total reads in the sample to get 15.36 percent, shown in **Abundance**. [Running Kraken 2](02-running-kraken2.md) counts a pair once, as one fragment, so when you report a count, name the tool and the column.

### The Confidence column

The **Confidence** column labels each organism after mapping. The **High** label comes from TaxTriage's presence call. The [K2 Confidence setting](../../GLOSSARY.md#confidence-kraken-2) applies earlier, when Kraken 2 classifies individual reads.

| Label | Rule |
|---|---|
| **High** | TaxTriage called the organism present after its score passed the run's threshold of 75 on the 0 to 100 scale, equivalent to a threshold of 0.75 in **TASS Score** |
| **Medium** | No TaxTriage presence call, with a TASS score of 0.40 or more, a line that LGE sets |
| **Low** | A TASS score below 0.40 |

In the example run *Streptococcus agalactiae* reads **High** at 0.780. Hold the pointer over a **Confidence** or **TASS Score** cell to see a tooltip that states the rule behind that row's label.

### What the TASS score means

TASS weighs how far and how evenly reads spread across the reference, how well their matches distinguish the organism from its relatives, and how cleanly they map. Read count plays little part. For a bacterial genome, breadth and evenness can earn close to full credit when reads are scattered over a few percent of the reference. Reads on a few percent can score as high as reads on the entire reference, as *Micrococcus luteus* and *Kocuria* sp. BT304 show below. A few thousand reads can score as high as millions.

Read **Coverage Breadth** and **Coverage Depth** alongside **TASS Score**. To compare the read fractions for two organisms, use **Abundance**. A row can score near 1 even with limited coverage, and a skin commensal, an organism that normally lives on the body and is usually harmless in healthy people, can outscore the recorded pathogen. The example shows both why a score alone can mislead and why the same score can go with very different breadth and depth. Use the score to assess evidence for presence, then use clinical findings and controls to assess a possible role in disease.

### The example run

Here are the top rows for SRR12486983, the HSV-1 case, as the table shows them.

| Organism | TASS Score | Coverage Breadth | Coverage Depth |
|---|---|---|---|
| *Bradyrhizobium* sp. WCU1 | 1.000 | 31.8% | 0.5× |
| Human alphaherpesvirus 1 | 0.930 | 100.0% | 733.3× |
| *Actinomyces oris* | 0.930 | 2.0% | 0.1× |
| *Kocuria* sp. BT304 | 0.920 | 100.0% | 39.5× |
| *Micrococcus luteus* | 0.920 | 4.8% | 0.1× |

In the second row, Human alphaherpesvirus 1 (HSV-1) ties *Actinomyces oris* on **TASS Score**. Reads assigned to HSV-1 cover the entire 152,222-base reference at a mean depth of 733.3 and account for about 15 percent of the sample's reads. Compare that with 2 percent breadth at 0.1 for *Actinomyces oris* and under a third at 0.5 for *Bradyrhizobium*. Reads assigned to *Kocuria* sp. BT304, a bacterium found on skin and in the environment, cover its full reference. Assess its role using the clinical findings. *Streptococcus agalactiae* does not appear in this sample.

Clear SRR12486983 and select SRR12486989, the *Streptococcus agalactiae* case.

| Organism | TASS Score | Coverage Breadth | Coverage Depth |
|---|---|---|---|
| *Kocuria* sp. BT304 | 0.980 | 91.9% | 4.0× |
| *Cutibacterium acnes* | 0.960 | 6.6% | 0.1× |
| *Bradyrhizobium* sp. WCU1 | 0.890 | 3.5% | 0.0× |
| *Cellulosimicrobium cellulans* | 0.890 | 7.0% | 0.1× |
| *Streptococcus agalactiae* | 0.780 | 27.8% | 0.4× |

The recorded pathogen, *Streptococcus agalactiae*, ranks fifth and passes TaxTriage's threshold. HSV-1 does not appear in this sample. The *Streptococcus agalactiae* matches cover 27.8 percent of its reference at a mean depth of 0.4, close to *Bradyrhizobium* in the first sample at about 30 percent breadth and a depth under one. Use the report and any controls alongside the coverage figures, as [Recognizing the pathogen](#recognizing-the-pathogen) explains.

Standard-16 found *Kocuria*, *Cutibacterium acnes*, *Bradyrhizobium*, and *Cellulosimicrobium* in the HSV-1 sample, as [Running Kraken 2](02-running-kraken2.md#the-same-reads-a-different-database) shows. TaxTriage reports the same four in the second patient's corneal sample, from a case with a different infection. That recurrence gives you a reason to check for contamination. The report lists *C. acnes* as **Commensal**, an organism that normally lives harmlessly on the body. It lists *Kocuria* sp. BT304 and *Bradyrhizobium* sp. WCU1 as **Unknown**. In the second sample, reads for *C. acnes*, *Bradyrhizobium*, and *Cellulosimicrobium* cover under 10 percent of their references.

### Recognizing the pathogen

To assess whether an organism could explain the infection, review the TASS score and **Confidence** label alongside breadth and depth. Then check how the report describes the organism and whether a negative control also has a row for it.

To see the organism categories for a sample, select one of its rows and click **Open Report**. LGE opens the organism discovery report, `<sample>.odr.pdf`, or the HTML version when there is no PDF. To find the files, right-click the result in the sidebar and choose **Show in Finder**. Each sample has its own `report` folder, such as `<result folder>/SRR12486983/report/`. Its `all.odr.pdf` covers that sample. The file `<sample>.odr.txt` holds the same table as tab-separated text, which Numbers or Excel opens with one column per field.

The **Microbial Category** column uses these labels, as [TaxTriage's documentation](https://jhuapl-bio.github.io/taxtriage/stable/microbial-categories/) defines them:

| Category | Meaning |
|---|---|
| **Primary** | Recognized pathogen |
| **Opportunistic** | Causes disease mainly in a weakened host |
| **Potential** | Has case reports but no established role as a routine cause |
| **Commensal** | Normally lives harmlessly on the body |
| **Unknown** | TaxTriage has no annotation |

Human alphaherpesvirus 1 and *Streptococcus agalactiae* are both **Primary** in this run. The **High Consequence** column flags organisms of special public health concern and reads **False** for both. Deciding what caused a patient's infection is a clinical judgment. Confirm pathogens for patient care using your laboratory's validated tests.

The example has no negative control, so its contamination risk remains untested. For your own batch, include a control and set **Negative Control** or **Extraction Blank** in the dialog, as [Check the samples](#check-the-samples) describes. LGE flags an organism across the batch if it has any row in a negative control, regardless of read count or specimen score. Compare **Abundance**, the read share, in the control and specimen, since the two libraries rarely hold the same number of reads. A few reads of a specimen's main organism can reach the control from the specimen itself, so use more than the flag to assess whether a strong specimen call reflects contamination.

The table shows orange text and a warning sign. Hold the pointer over the sign to see that the control triggered the warning. The overview grid adds a **Risk** column. **Export Organism Matrix (CSV)…** preserves that risk even when you leave the control out of the export. CSV means comma-separated values.

If a control failed, is missing, or had a step stop with an error, the note above the table says "Contamination risk is not checked." or "Contamination risk is only partly checked." It names the control, gives instructions, and ends "Where no warning sign shows, the risk is not checked." A name collision in the reports also triggers the note because LGE cannot tell the samples apart.

[TSV](../../GLOSSARY.md#tsv) means tab-separated text. Copying a single row or taking a screenshot of the table alone leaves out the note above the table. Include the note if you share a screenshot or use **Copy Row as TSV**. With **Export**, the **Contamination Risk** column shows **Not checked** for affected rows that would otherwise read **No**.

### The alignment pane

To see where reads land along a reference, select an organism row. The alignment pane shows mapped reads from that row's sample against its reference. If a row has no mapped reads to draw, the pane stays closed. Zoomed out to the whole genome, the pane draws a coverage track, the depth of reads along the reference, and asks you to zoom in to view individual mapped reads. To zoom in, click into the pane and press Cmd-plus, or pinch on a trackpad, as [Keyboard Shortcuts](../appendices/keyboard-shortcuts.md#inside-the-bam-alignment-viewport) lists. For HSV-1 the track spans the 152,222-base reference NC_001806.2.

<!-- SHOT: taxtriage-result-table -->

The pane works out its own covered share and mean depth from the alignment file, so its figures can differ a little from the table's. The HSV-1 pile, 733.3 deep on average, runs deeper than 500, the most reads the pane draws over one position by default, so the pane draws a subset of its reads, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains, while the table's figures come from TaxTriage's report.

LGE reads each sample's reads from that sample's own alignment file in the result's `minimap2` folder, named `<sample>.bam` or `<sample>.<sample>.dwnld.references.bam`. If neither file is present, LGE loads the file whose name fits. If the action bar and the Inspector's `BAM note:` warn it may belong to another sample, confirm its identity before using the alignment.

### Working with rows

The action bar includes **Open Report** alongside the shared controls described in [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) in Running Kraken 2.

**Verify with BLAST…** sends reads of the selected row to NCBI for a second opinion, as [BLAST Verification](06-blast-verification.md) explains, and needs exactly one row selected in the list. In the overview grid it stays dimmed, and its tooltip asks you to choose one sample. Use **BLAST Results** to see the matches below the table.

**Extract Reads…** saves the reads that mapped to the selected organisms as a new bundle by default. It takes any number of rows, from one sample or several, and opens the dialog [Running Kraken 2](02-running-kraken2.md#extract-the-reads-of-one-taxon) documents. A reference [accession](../../GLOSSARY.md#accession) is the identifier a public database gives a sequence. The dialog skips and names selected rows that lack a reference accession in their own sample. When no selected row has one, an alert titled **Nothing to extract** says so and nothing is written.

Right-clicking a row offers **Verify with BLAST…**, **Copy Name**, **Copy Taxon ID**, **Copy Row as TSV**, **Open Taxonomy on NCBI**, and **Extract Reads…**. Paste the copied TSV into a spreadsheet. With several rows selected, only **Extract Reads…** applies.

**Export** offers **Export as CSV…** and **Export as TSV…**, which write the rows the table shows at that moment, with columns for the sample, the scores and counts, the taxonomy ID, and a **Contamination Risk** flag. **Copy Summary** copies a short text summary of the run and of what the view shows. A batch adds **Export Organism Matrix (CSV)…** and **Export Batch Report…**.

The info button opens a popover with the run's samples, platform, runtime, and main settings. In the full provenance record, a database LGE installed has the release and checksum recorded at installation. A database without an install record appears as unpinned. See [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) to review the record.

## What good looks like

Start with the job log in the Operations Panel. If every **TASS Score** reads 0.000 or the job shows **Completed with Warnings**, check which samples and steps the log names. When mapping fails, treat the affected TASS scores as unusable. If mapping ran out of memory on a human sample, check **Exclude host taxa** as described in [Keep the human genome out of the top hits](#keep-the-human-genome-out-of-the-top-hits). Then check the note above the table to see whether the controls ran.

Read breadth and depth beside the score. HSV-1's breadth of 100 percent at 733.3 shows deep coverage across the reference. Below one, mean depth caps breadth because each covered position holds at least one read. At 0.4×, reads can reach at most 40 percent of the reference. The recorded pathogen in SRR12486989 sits at 0.4×. A low depth alone cannot tell you whether the organism is absent or present in a trace amount, since at the same total read count depth falls as the genome gets longer or the share of human reads rises.

Look at **Coverage Breadth** to see how much of the reference the reads reached. If many reads cover only a few percent, inspect the coverage track for reads concentrated in small regions.

Compare **Reads** with **Unique Reads** where both show a number. When **Unique Reads** shows a number, it is at most **Reads**. A much smaller **Unique Reads** count means many reads were marked as duplicates. Use the gap as a clue to duplication since the counts come from different stages. At high depth, reads can start at the same position by chance. In an [amplicon](../../GLOSSARY.md#amplicon) library, PCR, a method for making copies of DNA, copies chosen targets from short starter sequences called primers. Reads starting at those primers can look like copies.

Check the database against your question. Standard-16 contains bacteria, archaea, viruses, and the human genome. It leaves out fungi and protozoa. Choose a database that includes those groups if you need them among the candidates in the first classification step.

Review the report category and controls, then use **Verify with BLAST…** to check a call against NCBI's collection. See [BLAST Verification](06-blast-verification.md) for how to interpret the matches and [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) for the full set of checks.

## On the command line

To repeat the procedure in Terminal, follow [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) for how to set the project path. Most flags of `taxtriage run` are listed in [Classification](../appendices/cli-reference.md#classification) in the CLI Reference, and `lungfish-cli taxtriage run --help` shows every one.

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

Each `--input` names one sample, named after its bundle, and `--batch` runs each sample alone, as the dialog does. `--project` puts the result in the project's `Analyses` folder as `taxtriage-batch-` with the date and time. The command line fills in no default for `--remove-taxids`, so pass it yourself for every human sample. The command that **Copy CLI Command** copies from the Operations Panel row also names every other setting at its value.

Give `--input` the bundle path to read the whole bundle, as the dialog does. Give it a file path inside the bundle to read just that file. A [virtual bundle](../../GLOSSARY.md#virtual-bundle) keeps only a preview of its reads. If you pass its preview file, the command reads the whole bundle.

A bundle whose sample role is **Negative Control** or **Extraction Blank** marks its sample as a negative control, and `--negative-control` with a sample's name marks any other. With `--output` in place of `--project` and no `--batch`, one Nextflow run takes every sample, and an output folder whose name begins with `taxtriage-` inside the project's `Analyses` folder opens in the TaxTriage viewport too.

## Next

Continue to [BLAST Verification](06-blast-verification.md), which checks a classifier's call against NCBI's full collection, the independent method the last question of the evidence checklist asks for. It uses the HSV-1 call from [Running Kraken 2](02-running-kraken2.md), and the same popover verifies a TaxTriage row.
