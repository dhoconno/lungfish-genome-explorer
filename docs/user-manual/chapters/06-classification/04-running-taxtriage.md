---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification, 06-classification/02-running-kraken2]
estimated_reading_min: 26
task: Run the TaxTriage pathogen workflow on two clinical FASTQ bundles against an installed Kraken 2 database, keep the human genome out of its top hits, and read the organism table it produces.
tags: [classification, taxtriage, nextflow, container, confidence, pathogen-detection]
tools: [taxtriage]
parameters_refs: [classify.taxtriage]
entry_points:
  - "Tools > Classification > TaxTriage..."
  - "CLI: lungfish-cli taxtriage run"
shots:
  - id: taxtriage-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > TaxTriage... with SRR12486983 and SRR12486989 selected, showing both samples as Clinical Sample rows, the Kraken2 Database picker on Standard-16, Sequencing Platform on Illumina, Skip assembly (faster) ticked, and Advanced Settings collapsed."
  - id: taxtriage-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the K2 Confidence slider at 0.20, the Top hits stepper at 10, the Max memory stepper at 16 GB, the Max CPUs stepper, the Skip Krona visualization checkbox, and the Extra arguments field holding --remove_taxids 9606."
  - id: taxtriage-result-table
    caption: "The TaxTriage viewport for the two-sample corneal run in the List Over Detail layout, with both samples ticked in the Inspector's Sample Filter and the cards reading Batch TaxTriage, Samples 2, and Organisms 322. The Human alphaherpesvirus 1 row of SRR12486983 is selected in the table on top, showing TASS Score 0.930, Reads 2.0M, Unique Reads 1.6M, and High, and the alignment pane below shows the coverage track across the 152,222-base HSV-1 reference NC_001806.2, zoomed out, with its prompt to zoom in to view individual mapped reads. The Inspector shows its Panel Layout control and the run's Operation Details."
  - id: taxtriage-batch-overview
    caption: "The TaxTriage viewport with both samples ticked and Kocuria typed in the Filter organisms... field, showing SRR12486983's Kocuria rows first, from Kocuria sp. BT304 at 0.920 High down to Kocuria rosea at 0.080 Low, then SRR12486989's, starting with Kocuria sp. BT304 at 0.980 High, under the Sample, Organism, TASS Score, Reads, Unique Reads, and Confidence columns. No row is selected, so the alignment pane is empty."
illustrations: []
glossary_refs: [accession, amplicon, bam, blast, bundle, container, coverage-breadth, depth, fastq, inspector, kraken2, k-mer, library-prep, lowest-common-ancestor, mark-duplicates, negative-control, nextflow, paired-end, plugin-pack, read, read-classification, reference-genome, required-setup-pack, samplesheet, shotgun, sra, taxon, taxonomy-id, tass-score, taxtriage, tsv, viewport]
features_refs: []
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

[TaxTriage](../../GLOSSARY.md#taxtriage) is a pathogen-detection workflow, a chain of separate programs run one after another by a managing program called [Nextflow](../../GLOSSARY.md#nextflow). It takes a [FASTQ](../../GLOSSARY.md#fastq) file of sequencing [reads](../../GLOSSARY.md#read), the short stretches of sequence the instrument produced, and names the organism each read came from, a task called [read classification](../../GLOSSARY.md#read-classification).

The naming step is [Kraken 2](../../GLOSSARY.md#kraken2), the same program [Running Kraken 2](02-running-kraken2.md) covers, run against the same installed databases. TaxTriage adds a second round of evidence around it. It takes the organisms Kraken 2 named most often and downloads a [reference genome](../../GLOSSARY.md#reference-genome) for each, a published full genome sequence of that organism. It then maps the sample's reads onto those genomes, meaning it finds where on a genome each read fits best. Finally it measures how much of each genome the reads reached and how deeply they stacked, and folds those measurements into one number per organism.

That number is the [TASS score](../../GLOSSARY.md#tass-score), TaxTriage's own name for its score. TaxTriage writes it on a scale of 0 to 100, and Lungfish Genome Explorer (LGE) shows it divided by 100, as a value from 0 to 1. LGE also labels every organism High, Medium, or Low, as Reading the results explains.

TaxTriage is published as a Nextflow pipeline, a recipe file that lists the steps in order and that Nextflow reads and runs. Each step runs inside a [container](../../GLOSSARY.md#container), a packaged copy of a program with everything it needs, which Nextflow downloads from the internet the first time. So TaxTriage needs no [plugin pack](../../GLOSSARY.md#plugin-pack), the themed groups of tools LGE installs on request. LGE always uses one saved version of the pipeline's code, TaxTriage release v3.3.8, so that a rerun reproduces the same result.

## Why you would do this

You run TaxTriage when the question is not only what is present but how well each answer is supported, and when several samples have to be judged by the same yardstick, the TASS score and its High, Medium, and Low labels.

A read count alone cannot tell a good call from a bad one. In the good case an organism's reads spread along its whole genome. In the bad case every read piles onto one repetitive stretch, a region that looks like many others, so reads from anywhere in the sample can land there by mistake. Both give the same count. TaxTriage separates them because its mapping round reports [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of the reference the reads reached, beside mean [depth](../../GLOSSARY.md#depth), the average number of reads over each position.

The second reason is controls. A [negative control](../../GLOSSARY.md#negative-control) is a tube of water or buffer instead of patient material, carried through the whole protocol, so anything found in it came from reagents, the bench, or the sequencing run. Run it in the same batch and its organisms sit in the same result table as the specimens', so an organism found in both is easy to spot.

This chapter works through two human corneal samples, the cornea being the clear front surface of the eye. They come from the study behind the protocol paper by the team that wrote Kraken 2, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y). Run SRR12486983 is the herpes simplex keratitis case that [Running Kraken 2](02-running-kraken2.md) uses, an eye infection by herpes simplex virus 1 (HSV-1). Run SRR12486989 is a second case from the same study, recorded as an infection by the bacterium *Streptococcus agalactiae*. Both are [shotgun](../../GLOSSARY.md#shotgun) [libraries](../../GLOSSARY.md#library-prep) of human tissue, meaning the tissue's DNA was broken into random fragments and prepared for the sequencer. That is the setting TaxTriage was built for, and knowing each answer in advance shows plainly what the tool reports well and what it does not.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Pathogen Detection demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds both runs as the two bundles described below, so the SRA downloads are done. To fetch the runs yourself instead, follow the rest of this section.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for the example data of the Kraken 2, TaxTriage, and BLAST chapters. Download both runs from the [Sequence Read Archive](../../GLOSSARY.md#sra), NCBI's public store of sequencing runs, as `SRR12486983` and `SRR12486989`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). Each run is [paired-end](../../GLOSSARY.md#paired-end), so every DNA fragment was read from both ends, and the two reads of one fragment are a read pair. Each run imports as one [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, `Imports/SRR12486983.lungfishfastq` with 4,819,760 read pairs and `Imports/SRR12486989.lungfishfastq` with 5,440,369. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/kraken-protocol-cornea. Reading it is optional, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Nextflow arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack every LGE install needs.

TaxTriage needs Docker Desktop, a free app from Docker, Inc. that runs containers, available from https://www.docker.com/products/docker-desktop/. Install it before your first run. LGE always runs this pipeline's containers in Docker. The dialog may show a green Apple Containerization indicator on macOS 26, but that does not replace Docker Desktop, and without it the run stops. If Docker Desktop is installed but closed, LGE opens it for you when the run starts, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains.

TaxTriage classifies against an installed Kraken 2 database rather than carrying its own. This chapter uses Standard-16, a broad database of bacteria, archaea, viruses, and the human genome, sized for a Mac with 16 GB of memory. It holds no fungi or protozoa, both of which can also infect the eye. Choose **Apple menu > About This Mac** to see your Mac's memory, and on a Mac with less than 16 GB take Standard-8 instead. Open **Tools > Plugin Manager...** and download the database from its Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. If you worked through [Running Kraken 2](02-running-kraken2.md) you already have it.

On the first run Nextflow also downloads the pipeline's container images, the stored copies each container starts from. Allow extra time for that. Later runs reuse them.

## Procedure

The worked example runs TaxTriage once on both corneal samples against Standard-16.

### 1. Select both samples and check the prerequisites

1. Click the SRR12486983 bundle in the project sidebar, then Cmd-click the SRR12486989 bundle so that both are selected.

2. Choose **Tools > Classification > TaxTriage...**. The window that opens is titled FASTQ/FASTA Operations, with TaxTriage already chosen in its tool sidebar and its settings beside it. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Prerequisites** row at the top of the TaxTriage settings. It carries one indicator labelled **Nextflow** and a second that names the container runtime it found, such as Apple Containerization or Docker, followed by the word Available. When no runtime is found, the second indicator reads Container, followed by the words Not found. A green dot means the item is ready and an orange dot means it is missing. A spinner means the check is still running.

    <!-- SHOT: taxtriage-dialog -->

4. If either dot is orange, **Run** stays disabled and the line under the **Run** button reads "Complete the classifier settings to continue." An orange dot beside **Nextflow** means the Required Setup pack is missing or broken, so open **Tools > Plugin Manager...** and install it from the Required Setup section, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. An orange container dot means no runtime was found, so install Docker Desktop. In either case reopen the dialog afterwards, because the check runs when the settings appear.

### 2. Check the samples

The **Samples** section holds one row per bundle you selected, so it lists SRR12486983 and SRR12486989.

1. Read each **Sample ID** field. It starts with the reads file's name, less its `.fastq.gz` ending, which here matches the bundle's name, and the pipeline reports the sample under whatever you type here. The reads file's name sits beside the field.

2. Leave the role picker at the right of each row on **Clinical Sample**, because both runs are patient specimens.

3. **Remove** at the right of a row drops it. Do not use **Add Sample**. It adds an empty row that cannot hold reads, and the run leaves it out. Select every bundle you want in the sidebar before you open the dialog instead.

### 3. Choose the database and the platform

Open the **Kraken2 Database** picker and choose **Standard-16**. The picker lists every Kraken 2 database the Plugin Manager has downloaded and starts on the first one, which may not be the one you want. If none is installed, the section reads "No Kraken2 databases installed" instead.

Leave **Sequencing Platform** on **Illumina**. The runs' Sequence Read Archive records name the instrument, an Illumina NextSeq 550.

Leave **Skip assembly (faster)** ticked. The line under it reads "Classification and confidence scoring only. Significantly faster."

### 4. Keep the human genome out of the top hits

Click **Advanced Settings** to open it. Leave every value at its default. On the test Mac those were K2 Confidence 0.20, where K2 stands for Kraken 2, Top hits 10, Max memory 16 GB, and Max CPUs 14, a number that follows how many processor cores your Mac has. Then click the **Extra arguments** field and type `--remove_taxids 9606`, which is two hyphens, the word `remove_taxids` with an underscore, a space, and the number. Check that the field shows two separate hyphens rather than one long dash.

<!-- SHOT: taxtriage-advanced-settings -->

This one line is the most useful thing in the chapter. TaxTriage downloads a reference genome for each organism at the top of the Kraken 2 report, the summary table of how many reads went to each [taxon](../../GLOSSARY.md#taxon), meaning each named group of organisms. Standard-16 contains the human genome, and a human tissue sample is mostly human DNA, so without the line *Homo sapiens* enters the top hits. TaxTriage then downloads GRCh38, the complete human reference genome, and its mapping step needs more memory than the 16 GB limit allows, so Nextflow stops it.

The first run on these two samples failed exactly that way. The mapping step was stopped four times for each sample, and the run still finished as if it had worked, with no organism given a score. Do not rely on LGE to warn you about a run that ended like this. A result where every TASS Score reads 0.000 is the sign.

The pipeline's `remove_taxids` option drops the listed taxa from the Kraken 2 report before the top hits are chosen. The human reads are still in the sample, but no human genome is downloaded and nothing is ranked as human. The number 9606 is the [taxonomy ID](../../GLOSSARY.md#taxonomy-id) that NCBI, the United States National Center for Biotechnology Information, gives *Homo sapiens*. Add the same line for any human clinical sample classified against a database that includes the human genome.

### 5. Run it and open the result

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Its row shows progress while the samples run one after the other, and reports the run complete when both are done. On the test Mac the whole run took about 18 minutes, 11 for SRR12486983 and the rest for SRR12486989.

Then find the result in the sidebar. It lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE names it `taxtriage-batch-` followed by the date and time, such as `taxtriage-batch-2026-09-25T03-40-19`, with one subfolder per sample inside it. Click the folder and the TaxTriage [viewport](../../GLOSSARY.md#viewport) opens, the panel that fills the window and shows one result.

Once the result is open, the Inspector's **Operation Details** section lists the settings the run used, including the database path, Max CPUs, Max Memory, Platform, Top Hits, and the runtime, 17m 39s for the worked example. Copy them from there into a methods section.

## Settings

Several bold labels below end in a colon followed by a period, because they keep the colon the app draws after each label on screen. Five controls sit in plain view and six more inside **Advanced Settings**.

**Sample ID.** Names one row of the sample list, and every report the pipeline writes refers to the sample by this label. The default is the reads file's name without its ending and without any `_R1` or `_1` mate marker. Change it to the identifier your lab already uses so the reports match your records. On the command line this is `--sample`.

**Sample role.** Records what kind of material a row holds. The choices are Clinical Sample, the specimen under test, and four controls. A Negative Control is a no-template tube, and an Extraction Blank is a tube with nothing in it carried through DNA extraction. A Positive Control holds a known organism, and an Environmental Control samples the room or bench. The default is Clinical Sample. In this release LGE saves only one fact from the role, whether the row is a negative control, which Negative Control and Extraction Blank both set. Positive Control and Environmental Control are saved the same as Clinical Sample, and no role changes the result table, so name your controls' Sample IDs clearly as well, such as `NEG-blank-1`. This setting has no command-line flag.

**Kraken2 Database.** Names the reference collection the classification step compares every read against, and so fixes which organisms can be reported at all. The default is the first installed Kraken 2 database, which is an accident of install order rather than a choice. Match it to the organisms you expect, such as Viral for viruses only, Standard-8 or Standard-16 for a broad survey on an 8 GB or 16 GB Mac, and PlusPF when fungi and protozoa matter, as [Picking a classifier for your sample](01-what-is-classification.md#picking-a-classifier-for-your-sample) describes. On the command line this is `--db`.

**Sequencing Platform.** Tells the pipeline which instrument made the reads, offering Illumina, Oxford Nanopore, and PacBio, so its steps can expect that instrument's typical errors. The default is Illumina. Illumina gives short, accurate reads and the other two give long reads with more errors, so match it to the instrument named on your run sheet. On the command line this is `--platform`.

**Skip assembly (faster).** Leaves out de novo assembly, the slow stitching of overlapping reads into long sequences without a reference. The default is on, because classification and scoring answer the detection question and assembly does not. Turn it off only when you want assembled genomes and can spare hours more. On the command line assembly is skipped by default and `--no-skip-assembly` turns it back on.

**K2 Confidence:.** Sets what share of a read's [k-mers](../../GLOSSARY.md#k-mer), the short fixed-length pieces Kraken 2 matches, must agree on one taxon before Kraken 2 names it. A read short of the threshold moves up to the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) of the taxa it matched, such as the genus shared by two species. The default is 0.20, one k-mer in five, and the control runs from 0.00 to 1.00 in steps of 0.05, with a slider and a typed number field. Raise it when the table fills with species that make no sense for the sample, such as ocean bacteria in an eye, and lower it when an organism you expect never appears. On the command line this is `--confidence`.

**Top hits:.** Sets how many of the organisms with the most Kraken 2 reads the pipeline starts from when it chooses reference genomes to download. The default is 10, and the stepper accepts 1 to 100. It does not cap the rows in the result, because the pipeline downloads related genomes too, as Reading the results explains. Raise it for a complex community where the top ten would leave out organisms you care about, knowing each extra organism adds downloads and mapping time. On the command line this is `--top-hits`.

**Max memory:.** Caps how much memory the pipeline may use. The default is 16 GB, and the stepper accepts 2 to 256 GB in steps of 2. A cap above what your Mac has makes steps fail, so on a Mac with less than 16 GB set it a few gigabytes below your Mac's memory, as shown under **Apple menu > About This Mac**. Raise it for a large database on a Mac with memory to spare. On the command line this is `--max-memory`.

**Max CPUs:.** Caps how many processor cores, the separate calculating units inside the Mac's chip, the pipeline uses at once. The default is every core currently available, 14 on the test Mac, and the stepper stops at your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--max-cpus`.

**Skip Krona visualization.** Leaves out the interactive Krona chart, a clickable picture of the community written into the result folder as a web page. The default is off, so the chart is made, and the viewport's tables do not depend on it. Turn it on to shorten a run when you only want the tables. On the command line this is `--skip-krona`.

**Extra arguments:.** Passes text straight to TaxTriage and Nextflow without LGE checking it. The default is empty. Type `--remove_taxids 9606` here for any human sample classified against a database that holds the human genome, as step 4 explains. For any other option, read the TaxTriage documentation at https://github.com/jhuapl-bio/taxtriage first. A value that contains spaces goes in quotes, and an unclosed quote keeps **Run** disabled, with the line under it reading "Complete the classifier settings to continue." On the command line this is `--extra-args`.

## Reading the results

The viewport has a row of summary cards across the top, an organism table with an alignment pane below it, and an action bar along the bottom. That table-over-pane arrangement is the default, and the Inspector's **Panel Layout** control can put the two side by side instead. The cards read Batch, Samples, and Organisms. For the worked example, Batch reads TaxTriage and Samples reads 2. Organisms counts the rows in the table, 322 while both samples are showing, and one organism found in both samples takes two rows.

### Choosing which samples to show

The table starts with every row of both samples, SRR12486983 first. The table is wider than the pane, so Coverage Breadth, Coverage Depth, and Abundance sit to the right of Confidence, and you scroll sideways to reach them. Which samples show is set in the [Inspector](../../GLOSSARY.md#inspector), the panel on the right of the window, in its **Samples & Metadata** section. Its **Sample Filter** list has a tick box for each sample, and the Select All and Filter... controls work as [The taxonomy viewport](02-running-kraken2.md#the-taxonomy-viewport) describes. Untick SRR12486989 to read SRR12486983 alone, which leaves 209 rows. SRR12486989 alone has 113.

That is far more than the ten of Top hits. For SRR12486983 the pipeline downloaded 1,766 reference sequences, covering many more organisms than its ten top hits, and mapped every read against all of them at once. Its report lists every organism whose genome received reads, and every row in the table was mapped and scored the same way.

The **Filter organisms…** field above the table keeps only the rows whose organism name contains what you type. With both samples ticked, typing a name such as Kocuria leaves only that genus's rows, all of SRR12486983's first and then all of SRR12486989's, with the Sample column telling them apart.

<!-- SHOT: taxtriage-batch-overview -->

### The organism table

The table holds one row per organism per sample, under nine columns.

| Column | What it shows |
|---|---|
| Sample | The Sample ID the row belongs to |
| Organism | The organism's name |
| TASS Score | The TASS score from 0 to 1, to three decimals |
| Reads | LGE's count of aligned reads on this organism's reference genome, from the result's [BAM](../../GLOSSARY.md#bam) file of mapped reads |
| Unique Reads | The Reads figure left after LGE [marks duplicates](../../GLOSSARY.md#mark-duplicates), the reads copied from one original fragment |
| Confidence | High, Medium, or Low, as the next section explains |
| Coverage Breadth | The share of the reference the reads reached, as a percentage |
| Coverage Depth | The mean depth, written with × for times |
| Abundance | TaxTriage's own share of the sample's reads that aligned to this organism |

Rows arrive in TaxTriage's own order, highest TASS score first within each sample. To sort by another column, click its header and choose **Sort Descending** or **Sort Ascending** from the menu that opens.

Depth is an average over every position of the genome, so it can fall below one. A depth of 0.1× means the reads, laid end to end, would cover only a tenth of the genome, so most positions have no read at all.

LGE handed TaxTriage each bundle's reads as one file, so TaxTriage counted each read of a pair as its own read. The counts in this table are reads, so halve them before you compare them with the pairs [Running Kraken 2](02-running-kraken2.md) counts. SRR12486983's 4,819,760 pairs are 9,639,520 reads here.

Abundance and Reads come from different counts. Abundance is TaxTriage's figure, the reads it aligned to the organism divided by every read in the sample. The Reads cell is LGE's own count from the same file, which can count one read more than once when it aligns to several places. For HSV-1 in SRR12486983, TaxTriage's report gives 1,482,057 aligned reads, which is the 15.37% in the Abundance cell, and the Reads cell shows 1,972,047. Quote the figure you read and say where it came from.

### The Confidence column

LGE gives every row one of three labels. They are unrelated to the K2 Confidence setting, which is a Kraken 2 threshold.

| Label | Rule |
|---|---|
| High | TaxTriage itself called the organism present, because its score passed the pipeline's threshold of 75 on the 0 to 100 scale, which is 0.75 in the TASS Score column |
| Medium | Below the pipeline's threshold, with a TASS score of 0.40 or more |
| Low | A TASS score below 0.40 |

In the worked example *Streptococcus agalactiae* reads High at 0.780.

### What the TASS score means

The TASS score folds several measures into one value. They include how cleanly the reads map, whether they map to this organism rather than equally well to others, how evenly they spread along the reference, and whether Kraken 2 and the mapping step agree. It does not reward the number of reads as such. A few thousand reads that map cleanly and only to one organism, spread evenly along its genome, can score as high as millions.

So the TASS score measures how confident TaxTriage is that an organism's DNA is really in the tube. It does not measure how much of the organism there is, and it is not a probability that the organism caused a disease. A harmless skin bacterium with clean, evenly spread reads can outscore a pathogen, and the worked example shows exactly that.

### The worked example

Here are the top rows for SRR12486983, the HSV-1 case, as the table shows them.

| Organism | TASS Score | Reads | Coverage Breadth | Coverage Depth |
|---|---|---|---|---|
| *Bradyrhizobium* sp. WCU1 | 1.000 | 48,811 | 31.8% | 0.5× |
| *Actinomyces oris* | 0.980 | 2,127 | 2.9% | 0.1× |
| Human alphaherpesvirus 1 | 0.930 | 1,972,047 | 100.0% | 733.8× |
| *Kocuria* sp. BT304 | 0.920 | 1,482,482 | 100.0% | 39.1× |
| *Micrococcus luteus* | 0.920 | 3,291 | 4.8% | 0.1× |

HSV-1 is third by score, and it is plainly the finding. Its reads cover the whole 152,222-base reference, 733.8 deep on average, and about 15% of all the sample's reads came from the virus. The two rows above it score higher with far less behind them. *Bradyrhizobium* reaches under a third of its genome at a depth of 0.5, and *Actinomyces oris* under 3% at 0.1, so their reads are real but thinly spread. *Bradyrhizobium* is also a genus often found in laboratory reagents, whatever the specimen. *Kocuria* sp. BT304, a bacterium of skin and the environment, covers its whole genome, which says its DNA is really in the tube and says nothing about whether it did any harm. *Streptococcus agalactiae* is in this sample too, far down the table with 23 reads, a TASS score of 0.030, and a Low label.

Now untick SRR12486983 and tick SRR12486989, the *Streptococcus agalactiae* case.

| Organism | TASS Score | Reads | Coverage Breadth | Coverage Depth |
|---|---|---|---|---|
| *Kocuria* sp. BT304 | 0.980 | 150,917 | 91.8% | 4.0× |
| *Cutibacterium acnes* | 0.970 | 2,621 | 6.6% | 0.1× |
| *Bradyrhizobium* sp. WCU1 | 0.890 | 4,038 | 3.5% | 0.0× |
| *Cellulosimicrobium cellulans* | 0.890 | 4,829 | 7.0% | 0.1× |
| *Burkholderia arboris* | 0.830 | 13,247 | 15.7% | 0.2× |
| *Streptococcus agalactiae* | 0.780 | 10,698 | 28.1% | 0.4× |

The recorded pathogen sits sixth, just past TaxTriage's threshold, covering 28.1% of its genome at a depth of 0.4. HSV-1 does not appear in this sample at all. Five organisms outscore the pathogen, among them *Cutibacterium acnes*, a common skin bacterium, and the same *Kocuria* and *Bradyrhizobium* as in the first sample. Organisms that turn up in sample after sample, whatever the diagnosis, are the usual sign of skin, reagent, or bench contamination rather than infection.

Look at *Streptococcus agalactiae* beside *Bradyrhizobium* in the first sample. The numbers are much alike, about 30% breadth at a depth under one. Nothing in these columns alone says which is the pathogen and which came from a reagent. TaxTriage's own annotations and a negative control make that call, as the next section explains.

### Recognising the pathogen

No single column picks out the pathogen. Read four things together.

1. The TASS score and Confidence label, which say the organism's DNA is really in the tube.
2. Coverage breadth and depth, which say how much of the genome the reads support.
3. TaxTriage's own annotations in its report, described below.
4. A negative control, which says what the lab and reagents put in every tube.

The viewport does not show TaxTriage's annotations, so open the pipeline's report, which TaxTriage calls its organism discovery report. Right-click the result folder in the sidebar, choose **Show in Finder**, and open a sample's folder, then its `report` folder. The file `<sample>.odr.pdf` is TaxTriage's printable report. The file `<sample>.odr.txt` holds the same table as tab-separated text, which Numbers or Excel opens with one column per field.

Its **Microbial Category** column sorts organisms into Primary, Opportunistic, Potential, Commensal, and Unknown. Primary marks a recognised pathogen. Opportunistic marks an organism that causes disease mainly in a weakened host, and Commensal one that normally lives harmlessly on the body. Unknown means TaxTriage has no annotation for it. In the worked example, Human alphaherpesvirus 1 and *Streptococcus agalactiae* are both Primary, and the high-scoring *Kocuria* and *Bradyrhizobium* rows are Unknown. The **High Consequence** column flags organisms of special public-health concern and reads False for both pathogens.

This batch has no negative control, so it cannot show which organisms came from the laboratory. When you run your own samples, include one. An organism present in the negative control is suspect in every sample of the batch, whatever its score in the specimens.

TaxTriage reports what DNA is in the tube. Deciding that an organism caused a patient's infection is a clinical judgement, and confirming a pathogen for patient care needs your laboratory's own validated tests.

### The alignment pane

Selecting a row loads its reads into the alignment pane below the table, drawn against the reference the pipeline mapped them to, so you can see where along the genome the evidence sits. If a row has no mapped reads to draw, the pane stays closed. Zoomed out to the whole genome, the pane draws a coverage track, the depth of reads along the reference, and asks you to zoom in to view individual mapped reads. For HSV-1 the track spans the 152,222-base reference NC_001806.2. The pane works out its own covered share and mean depth from the alignment file, so its figures, 99% covered at about 794× for HSV-1, can differ a little from the table's. Very deep piles are drawn from a subset of their reads, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains. The HSV-1 pile, 733.8 deep on average, runs deeper than 500, the most reads the pane draws over one position by default, so the pane draws a subset while the table's counts include every read.

<!-- SHOT: taxtriage-result-table -->

### Working with a single row

**BLAST Verify** in the action bar sends reads of the selected row to NCBI for a second opinion, as [BLAST Verification](06-blast-verification.md) explains, and needs exactly one row selected. In this viewport it opens no popover and sends 50 reads at once, or every read when the row has fewer, which uses up LGE's hourly allowance of 50. To choose how many, right-click the row and choose **Verify with BLAST...** instead, which opens the popover with its slider. **Extract FASTQ** opens the dialog [Running Kraken 2](02-running-kraken2.md#4-extract-the-reads-of-one-taxon) documents.

Right-clicking a row offers **Verify with BLAST...**, **Copy Organism Name**, **Copy Taxon ID**, **Copy Row as TSV**, **Look Up in NCBI Taxonomy**, and **Extract Reads...**. Copy Row as [TSV](../../GLOSSARY.md#tsv) copies the row as tab-separated text you can paste into a spreadsheet.

## What good looks like

Check the run first. A result where every TASS Score reads 0.000 is a failed run, whatever the Operations Panel said. For a human sample, the usual cause is a missing `--remove_taxids 9606`, as step 4 explains.

Then read coverage breadth and depth beside the score. A breadth near 100% with a depth of several reads or more, like HSV-1's 100% at 733.8, is what an abundant organism looks like. A depth below one means most of the genome has no read, so the organism is present at most in trace amounts, whatever its score. A breadth of a few percent with a large read count is the classic shape of a false call, because every read landed in one place.

Then compare Reads with Unique Reads. In a shotgun library the two should be close, and a small unique share means much of the evidence is copies of a few original fragments. HSV-1 keeps 1,625,225 unique reads out of 1,972,047, about 82 percent. At a depth of 733, many reads start at the same position by chance, so some loss is expected for a very deep genome. An [amplicon](../../GLOSSARY.md#amplicon) library, where PCR copied chosen targets from short starter sequences called primers before sequencing, is an exception. There every fragment starts at a primer, so many reads look like copies.

Then check the database against the question. TaxTriage reports only organisms its Kraken 2 database contains. Standard-16 holds bacteria, archaea, viruses, and the human genome but no fungi or protozoa, so its silence about them says nothing about them.

Then read your controls and TaxTriage's Microbial Category, as Recognising the pathogen explains. Send any call that matters to [BLAST](../../GLOSSARY.md#blast) with **BLAST Verify** before you act on it. A Supported answer whose reads match the organism at high identity backs the call, as [BLAST Verification](06-blast-verification.md#what-good-looks-like) explains.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE. In the commands below `lungfish-cli` stands for the program's full location, which [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to find.

Several samples go in through a [samplesheet](../../GLOSSARY.md#samplesheet), a CSV file listing one sample per line. Make it in TextEdit, choose **Format > Make Plain Text**, and save these three lines as `cornea.csv`. Change the paths to your own project. To find the reads file, right-click the bundle in Finder and choose **Show Package Contents**.

```text
sample,fastq_1,fastq_2,platform
SRR12486983,/Users/you/Documents/MyProject.lungfish/Imports/SRR12486983.lungfishfastq/SRR12486983.fastq.gz,,ILLUMINA
SRR12486989,/Users/you/Documents/MyProject.lungfish/Imports/SRR12486989.lungfishfastq/SRR12486989.fastq.gz,,ILLUMINA
```

Then run the check and the pipeline in Terminal. A backslash at the end of a line continues the command on the next line.

```bash
lungfish-cli taxtriage check-prerequisites
lungfish-cli taxtriage run \
  --samplesheet cornea.csv \
  --db ~/.lungfish/databases/kraken2/standard-16 \
  --extra-args="--remove_taxids 9606" \
  --output ./taxtriage-cornea
```

A passing check ends with the line `All prerequisites met. Ready to run TaxTriage.` The `~` stands for your home folder, and `~/.lungfish/databases/kraken2` is where the Plugin Manager installs Kraken 2 databases. `./taxtriage-cornea` is a new folder inside whichever folder Terminal is working in, and LGE's sidebar does not show it unless that folder is inside your project.

Write `--extra-args=` with the equals sign. Without it, the program would read `--remove_taxids` as one of its own options and stop. The `fastq_2` column is empty because each bundle holds both reads of a pair in one file, which is how the dialog passes them too. For a single sample, `--input` with a FASTQ file and `--sample` with its name replace `--samplesheet`, and `--input2` adds the second file of a pair stored as two files. The samplesheet has no role column, so sample roles have no command-line equivalent.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md) for wastewater surveillance results produced by an outside pipeline, or go to [BLAST Verification](06-blast-verification.md) to check a TaxTriage call against NCBI before you rely on it.
