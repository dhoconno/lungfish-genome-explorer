---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification, 06-classification/02-running-kraken2]
estimated_reading_min: 18
task: Run the TaxTriage pathogen workflow on a FASTQ bundle against an installed Kraken 2 database, label each sample with its role, and read the organism table it produces.
tags: [classification, taxtriage, nextflow, container, confidence, pathogen-detection]
tools: [taxtriage]
parameters_refs: [classify.taxtriage]
entry_points:
  - "Tools > Classification > TaxTriage..."
  - "CLI: lungfish-cli taxtriage run"
shots:
  - id: taxtriage-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > TaxTriage..., showing the Prerequisites row with its Nextflow indicator and Apple Containerization reported as Available, the Samples section with a sample-ID field and a role picker on each row, and the Kraken2 Database picker below."
  - id: taxtriage-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the K2 Confidence slider, the Top hits stepper, the Max memory stepper, the Max CPUs stepper, the Skip Krona visualization checkbox, and the Extra arguments field."
  - id: taxtriage-result-table
    caption: "The TaxTriage viewport after a single-sample run of SRR36291587 against the Viral database, with the Organisms summary card, the organism table on the right with its TASS Score, Reads, Unique Reads, Coverage, and Confidence columns, and the alignment pane on the left drawing the selected Severe acute respiratory syndrome coronavirus 2 row's reads, sampled where the pile runs deeper than the default Maximum displayed depth of 500."
  - id: taxtriage-batch-overview
    caption: "The batch overview shown when the sample filter is set to All Samples on a two-sample run holding SRR36291587 and a second sample, with the value buttons above the grid, the Organism, # Samples, Mean TASS, and Reads (min-max) columns, and one column per sample."
illustrations: []
glossary_refs: [accession, amplicon, blast, container, coverage-breadth, depth, fastq, kraken2, k-mer, lowest-common-ancestor, mark-duplicates, negative-control, nextflow, read, read-classification, required-setup-pack, samplesheet, shotgun, tass-score, taxtriage, tsv]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[TaxTriage](../../GLOSSARY.md#taxtriage) is a pathogen-detection workflow, a chain of separate programs run one after another by a program that manages them. It takes a [FASTQ](../../GLOSSARY.md#fastq) file of sequencing [reads](../../GLOSSARY.md#read), the short stretches of sequence the instrument produced, and names the organism each read came from, a task called [read classification](../../GLOSSARY.md#read-classification).

The naming step is [Kraken 2](../../GLOSSARY.md#kraken2), the same program [Running Kraken 2](02-running-kraken2.md) covers, run against the same installed databases. TaxTriage adds a second round of evidence around it. For each organism Kraken 2 named, it maps the assigned reads back to that organism's reference genome, meaning it finds where on the genome each read fits best. It then measures how much of the genome the reads reached and how deeply they stacked, and folds those measurements into one number per organism.

That number is the [TASS score](../../GLOSSARY.md#tass-score), a value between 0 and 1 that ranks how well supported each call is. Lungfish Genome Explorer (LGE) sorts the organism table by it and reads it in three bands, described under Reading the results.

TaxTriage is a published [Nextflow](../../GLOSSARY.md#nextflow) pipeline, a multi-step workflow written in a workflow language and run by a workflow engine. Each step runs inside a [container](../../GLOSSARY.md#container), a packaged copy of a program with everything it needs, so TaxTriage needs no plugin pack of its own. Its programs arrive inside the containers. LGE pins one saved version of the pipeline's code, TaxTriage release v3.3.8, so that a rerun reproduces the same result.

## Why you would do this

You run TaxTriage when the question is not only what is present but how well each answer is supported, and when several samples have to be judged by the same rule.

A read count alone cannot tell a good call from a bad one. In the good case an organism's reads spread along its whole genome. In the bad case every read piles onto one repetitive stretch, a region that looks like many others, so reads from anywhere in the sample can land there by mistake. Both give the same count. TaxTriage separates them because its mapping round reports [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of the reference the reads reached, beside mean [depth](../../GLOSSARY.md#depth), the average number of reads over each position.

The second reason is sample roles. You label each sample as a clinical sample or as one of four kinds of control. A [negative control](../../GLOSSARY.md#negative-control) is a sample with no template, carried through the whole protocol so that anything found in it came from reagents, the bench, or the sequencing run. LGE flags any organism that also appears in a negative control as a contamination risk across the batch, a judgement a per-sample count table cannot make.

This chapter works through the SRR36291587 reads, an [amplicon](../../GLOSSARY.md#amplicon) library of Illumina reads from a human clinical specimen, meaning PCR copied a chosen target many times before sequencing. They are the same reads [Running Kraken 2](02-running-kraken2.md) used. A viral example is right here because pathogen detection in clinical specimens is the setting TaxTriage was built for, and knowing the answer in advance shows plainly what the tool reports well and what it does not.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the sarscov2-srr36291587 fixture. Fetch its reads from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md), and find the fixture's README, with the data's source and licence, at https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Nextflow arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

This pipeline runs in containers, so Docker Desktop must be running first, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains. The pipeline always runs its containers in Docker, and LGE starts Docker Desktop if it is not running. On macOS 26 the dialog's second indicator may name Apple Containerization, but the run still uses Docker.

TaxTriage classifies against an installed Kraken 2 database rather than carrying its own. Download the Viral database from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. If you worked through [Running Kraken 2](02-running-kraken2.md) you already have it.

The first run on a Mac takes as long as Nextflow needs to download the pipeline's container images. Later runs reuse them.

## Procedure

The worked example runs TaxTriage once on the SRR36291587 reads against the Viral database.

### 1. Check the prerequisites

1. Click the FASTQ bundle holding the SRR36291587 reads in the project sidebar to select it.

2. Choose **Tools > Classification > TaxTriage...**. The window that opens is titled FASTQ/FASTA Operations, with TaxTriage already chosen in its tool sidebar. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Prerequisites** row at the top of the pane. It carries one indicator labelled **Nextflow** and a second that names the container runtime it found, such as Apple Containerization or Docker, followed by the word Available. When no runtime is found, the second indicator reads Container, followed by the words Not found. A green dot means the item is ready and an orange dot means it is missing. A spinner means the check is still running, and the line under the **Run** button reads "Complete the classifier settings to continue." until every check passes.

    <!-- SHOT: taxtriage-dialog -->

4. If either indicator is orange, **Run** stays disabled and the line under it reads "Complete the classifier settings to continue." Docker Desktop is an app from Docker, Inc., so install it if your Mac does not have it, open it, then reopen the dialog, because the check runs when the pane appears.

### 2. Name the samples and give each one a role

The **Samples** section holds one row per bundle you selected before opening the dialog.

1. Read the **Sample ID** field. It starts with the name LGE took from the bundle, and the pipeline reports the sample under whatever you type here. The bundle's name sits beside the field.

2. Set the role picker at the right of the row. Leave it on **Clinical Sample** for the worked example, which is a single clinical specimen. For your own batches, set every control to its role, as the Sample role entry under Settings explains.

3. To include a control, Cmd-click its bundle and the specimen's bundles in the sidebar to select them together before opening the dialog. **Remove** at the right of a row drops it. **Add Sample** adds an empty row that cannot hold reads, and the run leaves it out, so you can ignore that button.

### 3. Choose the database and the platform

Open the **Kraken2 Database** picker and choose **Viral**. The picker lists every Kraken 2 database the Plugin Manager has downloaded and starts on the first one, which may not be the one you want. If none is installed, the section reads "No Kraken2 databases installed" instead.

Leave **Sequencing Platform** on **Illumina**, the instrument that produced these reads. Leave **Skip assembly (faster)** ticked, and the line under it reads "Classification and confidence scoring only. Significantly faster." Leave **Advanced Settings** collapsed for a first run, since every value inside it has a working default.

<!-- SHOT: taxtriage-advanced-settings -->

### 4. Run it and open the result

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

When the row completes, find the result in the sidebar. The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE names it `taxtriage-batch-<timestamp>` whether it holds one sample or several. Click the folder and the TaxTriage viewport opens.

<!-- SHOT: taxtriage-result-table -->

## Settings

Five controls sit in plain view and six more inside **Advanced Settings**. Several labels end in a colon because the app draws them that way.

**Sample ID.** Names one row of the sample list, and every report the pipeline writes refers to the sample by this label. The default is the name LGE takes from the selected bundle. Change it to the identifier your lab already uses so the reports match your records. On the command line this is `--sample`.

**Sample role.** Tells LGE what kind of material a row holds, choosing from Clinical Sample, Negative Control, Positive Control, Environmental Control, and Extraction Blank. The default is Clinical Sample, the specimen under test. Set every control you ran, and above all the blanks, because LGE flags contamination only from rows labelled Negative Control or Extraction Blank, and a blank left as a clinical sample removes that signal. Positive Control and Environmental Control are recorded with the run but change nothing else. This setting has no command-line flag.

**Kraken2 Database.** Names the reference collection the classification step compares every read against, and so fixes which organisms can be reported at all. The default is the first installed Kraken 2 database, which is an accident of install order rather than a choice. Match it to the breadth of organisms you expect, Viral for a virus hunt and a Standard collection for a broad survey. On the command line this is `--db`.

**Sequencing Platform.** Tells the pipeline which instrument made the reads, offering Illumina, Oxford Nanopore, and PacBio, so its steps can expect that instrument's typical errors. The default is Illumina, the most common source of short reads. Match it to the instrument named on your run sheet, since long noisy reads and short accurate reads need different handling. On the command line this is `--platform`.

**Skip assembly (faster).** Leaves out de novo assembly, the slow stitching of overlapping reads into long sequences without a reference. The default is on, because classification and scoring answer the detection question and assembly does not. Turn it off only when you want assembled genomes and can spare hours more. On the command line assembly is skipped by default and `--no-skip-assembly` turns it back on.

**K2 Confidence:.** Sets what share of a read's [k-mers](../../GLOSSARY.md#k-mer), the short fixed-length pieces Kraken 2 matches, must agree on one taxon before Kraken 2 names it. A read short of the threshold moves up to the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) of the taxa it matched, such as the genus shared by two species. The default is 0.20, one k-mer in five, and the control runs from 0.00 to 1.00 in steps of 0.05, with a slider and a typed number field. Raise it when implausible species crowd the table, and lower it when too much of the library stays unclassified. On the command line this is `--confidence`.

**Top hits:.** Sets how many organisms the pipeline carries into its mapping round and reports, ranked by support. The default is 10, and the stepper accepts 1 to 100. Raise it for a complex community where the top ten would cut off organisms you care about, knowing each extra organism costs another mapping round. On the command line this is `--top-hits`.

**Max memory:.** Caps how much memory the pipeline may use, and a cap above what your Mac has makes steps fail, so on a Mac with less than 16 GB lower it below your Mac's memory. The default is 16 GB, and the stepper accepts 2 to 256 GB in steps of 2. Raise it for a large database on a Mac with memory to spare, as shown under About This Mac in the Apple menu, and lower it to leave room for other work. On the command line this is `--max-memory`.

**Max CPUs:.** Caps how many processor cores the pipeline uses at once. The default is every core currently available, and the stepper stops at your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--max-cpus`.

**Skip Krona visualization.** Leaves out the interactive Krona chart, a clickable picture of the community written into the result folder as a web page. The default is off, so the chart is made, and the viewport's tables do not depend on it. Turn it on to shorten a run when you only want the tables. On the command line this is `--skip-krona`.

**Extra arguments:.** Passes text straight to TaxTriage and Nextflow without LGE checking it. The default is empty, which is right for almost every run, and an unclosed quote keeps **Run** disabled, with the line under it reading "Complete the classifier settings to continue." Use it only for a pipeline option the dialog does not show, after reading TaxTriage's own documentation. On the command line this is `--extra-args`.

## Reading the results

The viewport has a row of summary cards across the top, an alignment pane on the left, an organism table on the right, and an action bar along the bottom.

A single-sample result shows four cards, labelled Organisms, Runtime, High Confidence, and Samples. High Confidence counts the organisms whose TASS score reached 0.80.

### The organism table

The table holds one row per organism with six columns. It also lists the higher ranks above each organism, from `root` down, and an `unclassified` row.

| Column | What it shows |
|---|---|
| Organism | The organism's name |
| TASS Score | The score to three decimals, with a tooltip naming its band |
| Reads | Every read record in the result's alignment file that mapped to this organism's reference |
| Unique Reads | The mapped reads left after LGE [marks duplicates](../../GLOSSARY.md#mark-duplicates), the reads copied from one original fragment |
| Coverage | Coverage breadth, the share of the reference the reads reached |
| Confidence | The TASS band drawn as a filled bar |

The table sorts by TASS Score, highest first. LGE counts Reads and Unique Reads itself from the result's [BAM](../../GLOSSARY.md#bam) file, which holds one row per aligned read, so they can differ from the aligned-read total in the pipeline's own report. Quote the figure you read and say where it came from.

A multi-sample result shows a wider table with a Sample column, Coverage Breadth in place of Coverage, and two more columns. Coverage Depth is the mean depth, and Abundance is the share of that sample's classified reads that went to the organism, written as a percentage.

### The TASS score in this release

The pinned pipeline revision does not write the confidence report LGE reads scores from, so every row shows a TASS Score of 0.000, an empty Confidence bar, and a dash under Coverage, and the High Confidence card reads 0. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

The pipeline still scores each organism in its organism detection report, on a scale of 0 to 100, so divide the file's score by 100 before comparing it with the bands below. That file ends in `.odr.txt` and sits in the result folder's `report` folder under the Sample ID you set. Right-click the result folder in the sidebar, choose **Show in Finder**, and open the file in any text editor to read the score, the coverage breadth, and the mean depth for each organism.

### What the TASS score means

The TASS score folds three things into one value. They are how many reads support the organism, how evenly those reads spread along its reference, and whether the pipeline's steps agree. Steps disagree when Kraken 2 assigns many reads to a species but mapping finds them on a narrow slice of its genome. A call backed by many evenly spread reads that every step agrees on scores high, and a few reads piled in one window score low.

LGE reads the score in three bands, and hovering a TASS Score cell shows a tooltip with the advice for its band.

| Score | Band | Tooltip advice |
|---|---|---|
| 0.80 and above | High | A strong taxonomic signal |
| 0.40 to below 0.80 | Medium | Likely a true positive, verify with BLAST |
| Below 0.40 | Low | A weak signal that may be noise or contamination |

The score is not a probability that the organism is present. It is a repeatable sort order, so two reviewers work through a batch in the same sequence. Treat a high score as a reason to look first, not as a verdict.

### The worked example

The Viral run names one species, *Severe acute respiratory syndrome coronavirus 2*, taxonomy identifier 2697049, whose reference genome is 29,903 bases long. The table also lists the rows of its lineage above it, from `root` down to *Sarbecovirus*, plus an `unclassified` row. Read the species row as the finding and the lineage rows as the path down to it.

In an example run, the pipeline's organism detection report gave the species a coverage breadth of 100 percent. A tiled amplicon library, whose overlapping PCR pieces are designed to span the genome, should reach close to the whole reference.

### The alignment pane

Selecting a row loads its reads into the alignment pane, drawn against the reference the pipeline mapped them to, so you can see where along the genome the evidence sits. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains. An amplicon pile runs far deeper than the Inspector's default Maximum displayed depth of 500, so the pane draws a sample of the reads while the table's counts include every read.

### Working with a single row

Extract reads with the action bar's **Extract FASTQ** button, whose dialog [Running Kraken 2](02-running-kraken2.md#4-extract-the-reads-of-one-taxon) documents. **BLAST Verify** and the **Export** menu sit beside it, and the rest of the bar holds two TaxTriage-specific items.

- **Open Report** opens one of the pipeline's own report files in another app, a PDF when the run wrote one.
- **Recompute Unique Reads** appears on a multi-sample result and recounts the Unique Reads column from the alignment files.

In a single-sample table, right-clicking a row adds **Copy Accession Number**, which copies the reference sequence's [accession](../../GLOSSARY.md#accession), its catalogue number at NCBI, and **Look Up in NCBI Taxonomy**. **Copy Row as TSV** copies the row as [TSV](../../GLOSSARY.md#tsv). The multi-sample table's menu offers **Copy Taxon ID** in place of Copy Accession Number.

### Comparing several samples

A result with more than one sample adds a sample filter above the table. Its first choice is **All Samples** and the rest are the sample IDs.

**All Samples** replaces the organism table with the batch overview, a grid with organisms as rows and samples as columns. A row of four buttons above the grid chooses what each cell holds, TASS Score, Total Reads, Unique Reads, or Coverage, where Coverage means breadth. The leading columns give each organism's name, the number of samples that detected it, its mean TASS score, and the range of its read counts across samples. A **Risk** column joins them when the batch holds a negative control. Choosing one sample brings back its organism table and loads its reads into the alignment pane.

<!-- SHOT: taxtriage-batch-overview -->

The overview is where specimens meet controls. LGE flags an organism found in any sample labelled Negative Control or Extraction Blank, and never removes the row or its reads, so the decision stays yours. In the overview the flagged organism gets a warning triangle in the **Risk** column, with the tooltip "Detected in negative control sample". In each sample's table its name carries the same triangle and turns orange. Neither view names the control, so read the control's own column in the overview.

The **Export** menu offers **Export as CSV...**, **Export as TSV...**, and **Copy Summary** on every result. A multi-sample result adds **Export Organism Matrix (CSV)...**, one row per organism with its mean score, detection fraction, contamination risk, and one score column per sample, and **Export Batch Report...**, a plain-text summary of shared, contamination-risk, and high-confidence organisms.

## What good looks like

Read coverage breadth first, from the report file while the Coverage column is blank. It separates a real detection from a pile of reads on a repetitive stretch. A breadth near 100% with good depth is what a working amplicon library looks like. A breadth of a few percent with a large read count is the classic shape of a false call, because every read landed in one place. A middle value such as 40% means either a real organism at low abundance or a relative of what your database holds, and a high depth beside a middling breadth points to the relative.

Then compare Reads with Unique Reads, keeping your library type in mind. In a [shotgun](../../GLOSSARY.md#shotgun) library, made from DNA broken at random, the two should be close, and a small unique share means much of the evidence is copies of a few original fragments. An amplicon library is the exception. Every fragment starts at a primer, so many reads look like copies of one molecule and few count as unique. A low unique share there is expected.

Then check the database against the question. TaxTriage reports only organisms its Kraken 2 database contains. The worked example used Viral, so its silence about bacteria says nothing about bacteria.

Then read your controls. An organism present in a negative control is suspect in every sample of the batch, whatever its score in the specimens.

Finally, send any call that matters to [BLAST](../../GLOSSARY.md#blast) with **BLAST Verify**, as [BLAST Verification](06-blast-verification.md#reading-the-results) explains, before you act on it.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli taxtriage check-prerequisites
lungfish-cli taxtriage run \
  --input SRR36291587_1.fastq.gz \
  --sample SRR36291587 \
  --platform illumina \
  --db ~/.lungfish/databases/kraken2/viral \
  --output ./taxtriage-viral
```

Add `--input2` with the second file when a sample is paired-end. Several samples go in through a [samplesheet](../../GLOSSARY.md#samplesheet), a CSV listing one sample per line, passed with `--samplesheet`. The samplesheet has no role column, so sample roles, and with them the contamination flags, have no command-line equivalent.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md) for wastewater surveillance results produced by an outside pipeline, or go to [BLAST Verification](06-blast-verification.md) to check a TaxTriage call against NCBI before you rely on it.
