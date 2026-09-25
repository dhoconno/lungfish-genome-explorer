---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification, 06-classification/02-running-kraken2]
estimated_reading_min: 22
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
    caption: "The TaxTriage viewport for the two-sample corneal run with only SRR12486983 ticked in the Inspector's Sample Filter, the Human alphaherpesvirus 1 row selected in the organism table on the right, and its reads drawn against the HSV-1 reference in the alignment pane on the left."
  - id: taxtriage-batch-overview
    caption: "The TaxTriage viewport with both samples ticked and Kocuria typed in the Filter organisms... field, showing the Kocuria rows of SRR12486983 and SRR12486989 in one table, told apart by the Sample column, with TASS Score, Reads, Confidence, Coverage Breadth, and Coverage Depth beside each."
illustrations: []
glossary_refs: [accession, amplicon, bam, blast, container, coverage-breadth, depth, fastq, inspector, kraken2, k-mer, lowest-common-ancestor, mark-duplicates, negative-control, nextflow, read, read-classification, required-setup-pack, samplesheet, shotgun, taxonomy-id, tass-score, taxtriage, tsv]
features_refs: []
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

[TaxTriage](../../GLOSSARY.md#taxtriage) is a pathogen-detection workflow, a chain of separate programs run one after another by a program that manages them. It takes a [FASTQ](../../GLOSSARY.md#fastq) file of sequencing [reads](../../GLOSSARY.md#read), the short stretches of sequence the instrument produced, and names the organism each read came from, a task called [read classification](../../GLOSSARY.md#read-classification).

The naming step is [Kraken 2](../../GLOSSARY.md#kraken2), the same program [Running Kraken 2](02-running-kraken2.md) covers, run against the same installed databases. TaxTriage adds a second round of evidence around it. For each of the organisms Kraken 2 named most often, it maps the assigned reads back to that organism's reference genome, meaning it finds where on the genome each read fits best. It then measures how much of the genome the reads reached and how deeply they stacked, and folds those measurements into one number per organism.

That number is the [TASS score](../../GLOSSARY.md#tass-score). TaxTriage writes it on a scale of 0 to 100, and Lungfish Genome Explorer (LGE) shows it divided by 100, as a value from 0 to 1. LGE also labels every organism High, Medium, or Low, as Reading the results explains.

TaxTriage is a published [Nextflow](../../GLOSSARY.md#nextflow) pipeline, a multi-step workflow written in a workflow language and run by a workflow engine. Each step runs inside a [container](../../GLOSSARY.md#container), a packaged copy of a program with everything it needs, so TaxTriage needs no plugin pack of its own. Its programs arrive inside the containers. LGE pins one saved version of the pipeline's code, TaxTriage release v3.3.8, so that a rerun reproduces the same result.

## Why you would do this

You run TaxTriage when the question is not only what is present but how well each answer is supported, and when several samples have to be judged by the same rule.

A read count alone cannot tell a good call from a bad one. In the good case an organism's reads spread along its whole genome. In the bad case every read piles onto one repetitive stretch, a region that looks like many others, so reads from anywhere in the sample can land there by mistake. Both give the same count. TaxTriage separates them because its mapping round reports [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of the reference the reads reached, beside mean [depth](../../GLOSSARY.md#depth), the average number of reads over each position.

The second reason is sample roles. You label each sample as a clinical sample or as one of four kinds of control. A [negative control](../../GLOSSARY.md#negative-control) is a sample with no template, carried through the whole protocol so that anything found in it came from reagents, the bench, or the sequencing run. LGE records each role with the run, and the result table holds the control's organisms beside the specimens', so an organism in both is easy to spot.

This chapter works through two human corneal samples from the study behind the Kraken authors' protocol paper, Lu et al. 2022, [Metagenome analysis using the Kraken software suite](https://doi.org/10.1038/s41596-022-00738-y). Run SRR12486983 is the herpes simplex keratitis case, an eye infection by herpes simplex virus 1 (HSV-1), that [Running Kraken 2](02-running-kraken2.md) uses. Run SRR12486989 is a second case from the same study, recorded as an infection by the bacterium *Streptococcus agalactiae*. Both are [shotgun](../../GLOSSARY.md#shotgun) libraries of human tissue, which is the setting TaxTriage was built for, and knowing each answer in advance shows plainly what the tool reports well and what it does not.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for this part's practice data. Download both runs from the Sequence Read Archive, `SRR12486983` and `SRR12486989`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). Each imports as one bundle, `Imports/SRR12486983.lungfishfastq` with 4,819,760 read pairs and `Imports/SRR12486989.lungfishfastq` with 5,440,369. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/kraken-protocol-cornea, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Nextflow arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

This pipeline runs in containers, so Docker Desktop must be running first, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains. The pipeline always runs its containers in Docker, and LGE starts Docker Desktop if it is not running. On macOS 26 the dialog's second indicator may name Apple Containerization, but the run still uses Docker.

TaxTriage classifies against an installed Kraken 2 database rather than carrying its own. This chapter uses Standard-16, a broad database sized for a Mac with 16 GB of memory, because a corneal infection can be a virus, a bacterium, or something else. Download it from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. If you worked through [Running Kraken 2](02-running-kraken2.md) you already have it. Standard-16 also holds the human genome, which matters in step 4 below.

The first run on a Mac takes as long as Nextflow needs to download the pipeline's container images. Later runs reuse them.

## Procedure

The worked example runs TaxTriage once on both corneal samples against Standard-16.

### 1. Select both samples and check the prerequisites

1. Click the SRR12486983 bundle in the project sidebar, then Cmd-click the SRR12486989 bundle so that both are selected.

2. Choose **Tools > Classification > TaxTriage...**. The window that opens is titled FASTQ/FASTA Operations, with TaxTriage already chosen in its tool sidebar. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Prerequisites** row at the top of the pane. It carries one indicator labelled **Nextflow** and a second that names the container runtime it found, such as Apple Containerization or Docker, followed by the word Available. When no runtime is found, the second indicator reads Container, followed by the words Not found. A green dot means the item is ready and an orange dot means it is missing. A spinner means the check is still running.

    <!-- SHOT: taxtriage-dialog -->

4. If either indicator is orange, **Run** stays disabled and the line under it reads "Complete the classifier settings to continue." Docker Desktop is an app from Docker, Inc., so install it if your Mac does not have it, open it, then reopen the dialog, because the check runs when the pane appears.

### 2. Check the samples and their roles

The **Samples** section holds one row per bundle you selected, so it lists SRR12486983 and SRR12486989.

1. Read each **Sample ID** field. It starts with the name LGE took from the bundle, and the pipeline reports the sample under whatever you type here. The reads file's name sits beside the field.

2. Leave the role picker at the right of each row on **Clinical Sample**, because both runs are patient specimens. For your own batches, set every control to its role, as the Sample role entry under Settings explains.

3. **Remove** at the right of a row drops it. **Add Sample** adds an empty row that cannot hold reads, and the run leaves it out, so select every bundle you want in the sidebar before you open the dialog.

### 3. Choose the database and the platform

Open the **Kraken2 Database** picker and choose **Standard-16**. The picker lists every Kraken 2 database the Plugin Manager has downloaded and starts on the first one, which may not be the one you want. If none is installed, the section reads "No Kraken2 databases installed" instead.

Leave **Sequencing Platform** on **Illumina**, the kind of instrument that produced these reads. Leave **Skip assembly (faster)** ticked, and the line under it reads "Classification and confidence scoring only. Significantly faster."

### 4. Keep the human genome out of the top hits

Click **Advanced Settings** to open it. Leave every value at its default and type `--remove_taxids 9606` in the **Extra arguments** field. On the test Mac the defaults were K2 Confidence 0.20, Top hits 10, Max memory 16 GB, and Max CPUs 14, the last one following your Mac's core count.

<!-- SHOT: taxtriage-advanced-settings -->

This one line is the most useful thing in the chapter. TaxTriage maps reads only for the organisms at the top of the Kraken 2 report, and it downloads a reference genome for each one. Standard-16 contains the human genome, and a human tissue sample is mostly human DNA, so without the line *Homo sapiens* enters the top hits. TaxTriage then downloads the whole human reference genome, GRCh38, and its mapping step runs out of memory inside the 16 GB limit and is stopped.

The first run on these two samples failed exactly that way. The mapping step was stopped four times for each sample, and the run still finished as if it had worked, with no organism given a score. Do not rely on LGE to warn you about a run that ended like this. A result where every TASS Score reads 0.000 is the sign.

The pipeline's `remove_taxids` option drops the listed taxa from the Kraken 2 report before the top hits are chosen. The number 9606 is the NCBI [taxonomy ID](../../GLOSSARY.md#taxonomy-id) of *Homo sapiens*. Add the same line for any human clinical sample classified against a database that includes the human genome.

### 5. Run it and open the result

Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The samples run one after the other. On the test Mac the whole run took about 18 minutes, 11 for SRR12486983 and the rest for SRR12486989.

When the row completes, find the result in the sidebar. The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE names it `taxtriage-batch-<timestamp>` whether it holds one sample or several, with one subfolder per sample inside it. Click the folder and the TaxTriage viewport opens.

## Settings

Five controls sit in plain view and six more inside **Advanced Settings**. Several labels end in a colon because the app draws them that way.

**Sample ID.** Names one row of the sample list, and every report the pipeline writes refers to the sample by this label. The default is the name LGE takes from the selected bundle. Change it to the identifier your lab already uses so the reports match your records. On the command line this is `--sample`.

**Sample role.** Tells LGE what kind of material a row holds, choosing from Clinical Sample, Negative Control, Positive Control, Environmental Control, and Extraction Blank. The default is Clinical Sample, the specimen under test. Set every control you ran, and above all the blanks, so that the run's record says which rows are controls when you compare them with the specimens. This setting has no command-line flag.

**Kraken2 Database.** Names the reference collection the classification step compares every read against, and so fixes which organisms can be reported at all. The default is the first installed Kraken 2 database, which is an accident of install order rather than a choice. Match it to the breadth of organisms you expect, Viral for a virus hunt and a Standard collection for a broad survey. On the command line this is `--db`.

**Sequencing Platform.** Tells the pipeline which instrument made the reads, offering Illumina, Oxford Nanopore, and PacBio, so its steps can expect that instrument's typical errors. The default is Illumina, the most common source of short reads. Match it to the instrument named on your run sheet, since long noisy reads and short accurate reads need different handling. On the command line this is `--platform`.

**Skip assembly (faster).** Leaves out de novo assembly, the slow stitching of overlapping reads into long sequences without a reference. The default is on, because classification and scoring answer the detection question and assembly does not. Turn it off only when you want assembled genomes and can spare hours more. On the command line assembly is skipped by default and `--no-skip-assembly` turns it back on.

**K2 Confidence:.** Sets what share of a read's [k-mers](../../GLOSSARY.md#k-mer), the short fixed-length pieces Kraken 2 matches, must agree on one taxon before Kraken 2 names it. A read short of the threshold moves up to the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) of the taxa it matched, such as the genus shared by two species. The default is 0.20, one k-mer in five, and the control runs from 0.00 to 1.00 in steps of 0.05, with a slider and a typed number field. Raise it when implausible species crowd the table, and lower it when too much of the library stays unclassified. On the command line this is `--confidence`.

**Top hits:.** Sets how many organisms the pipeline carries into its mapping round and reports, ranked by support. The default is 10, and the stepper accepts 1 to 100. Raise it for a complex community where the top ten would cut off organisms you care about, knowing each extra organism costs another reference download and mapping round. On the command line this is `--top-hits`.

**Max memory:.** Caps how much memory the pipeline may use, and a cap above what your Mac has makes steps fail, so on a Mac with less than 16 GB lower it below your Mac's memory. The default is 16 GB, and the stepper accepts 2 to 256 GB in steps of 2. Raise it for a large database on a Mac with memory to spare, as shown under About This Mac in the Apple menu, and lower it to leave room for other work. On the command line this is `--max-memory`.

**Max CPUs:.** Caps how many processor cores the pipeline uses at once. The default is every core currently available, and the stepper stops at your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--max-cpus`.

**Skip Krona visualization.** Leaves out the interactive Krona chart, a clickable picture of the community written into the result folder as a web page. The default is off, so the chart is made, and the viewport's tables do not depend on it. Turn it on to shorten a run when you only want the tables. On the command line this is `--skip-krona`.

**Extra arguments:.** Passes text straight to TaxTriage and Nextflow without LGE checking it. The default is empty, and an unclosed quote keeps **Run** disabled, with the line under it reading "Complete the classifier settings to continue." Type `--remove_taxids 9606` here for any human sample classified against a database that holds the human genome, as step 4 explains. Use it for any other pipeline option only after reading TaxTriage's own documentation. On the command line this is `--extra-args`.

## Reading the results

The viewport has a row of summary cards across the top, an alignment pane on the left, an organism table on the right, and an action bar along the bottom. The cards read Batch, Samples, and Organisms. For the worked example, Batch reads TaxTriage, Samples reads 2, and Organisms counts the rows in the table, 322 while both samples are showing.

### Choosing which samples to show

The table starts with every row of both samples, SRR12486983 first. Which samples show is set in the [Inspector](../../GLOSSARY.md#inspector), the panel on the right of the window, in its **Samples & Metadata** section. Its **Sample Filter** list has a tick box for each sample, and the Select All and Filter... controls work as [The taxonomy viewport](02-running-kraken2.md#the-taxonomy-viewport) describes. Untick SRR12486989 to read SRR12486983 alone, which leaves 209 rows. SRR12486989 alone has 113.

The **Filter organisms…** field above the table keeps only the rows whose organism name contains what you type. With both samples ticked, typing a name such as Kocuria puts that genus's rows from both samples together, one above the other.

<!-- SHOT: taxtriage-batch-overview -->

### The organism table

The table holds one row per organism per sample, under nine columns.

| Column | What it shows |
|---|---|
| Sample | The Sample ID the row belongs to |
| Organism | The organism's name |
| TASS Score | The TASS score from 0 to 1, to three decimals |
| Reads | The aligned-read count from the result's [BAM](../../GLOSSARY.md#bam) file, the file of mapped reads |
| Unique Reads | The mapped reads left after LGE [marks duplicates](../../GLOSSARY.md#mark-duplicates), the reads copied from one original fragment |
| Confidence | High, Medium, or Low, as the next section explains |
| Coverage Breadth | The share of the reference the reads reached, as a percentage |
| Coverage Depth | The mean depth, the average number of reads over each position of the reference |
| Abundance | The organism's aligned reads as a percentage of all the sample's reads |

Rows arrive in TaxTriage's own order, highest TASS score first within each sample. To sort by another column, click its header and choose **Sort Descending** or **Sort Ascending** from the menu that opens. The pipeline's own report gives a different aligned-read figure from the Reads column, because the two count in different ways, so quote the figure you read and say where it came from.

LGE handed TaxTriage each bundle's reads as one file, so TaxTriage counted each mate of a pair as its own read. The read counts in this table are reads, not the pairs [Running Kraken 2](02-running-kraken2.md) counts.

### The Confidence column

LGE gives every row one of three labels.

| Label | Rule |
|---|---|
| High | TaxTriage itself called the organism, because its score passed the pipeline's threshold of 75 on the 0 to 100 scale, which is 0.75 in the TASS Score column |
| Medium | Below the pipeline's threshold, with a TASS score of 0.40 or more |
| Low | A TASS score below 0.40 |

High therefore starts at 0.75, not at 0.80. TaxTriage's threshold is the one that counts, and in the worked example *Streptococcus agalactiae* reads High at 0.780.

### What the TASS score means

The TASS score folds several measures into one value. They include how many reads support the organism, how evenly those reads spread along its reference, how well they map, and whether the pipeline's steps agree. Steps disagree when Kraken 2 assigns many reads to a species but mapping finds them on a narrow slice of its genome. A call backed by many evenly spread reads that every step agrees on scores high, and a few reads piled in one window score low.

The TASS score measures how confident TaxTriage is that an organism's reads are really in the sample. It does not measure how much of the organism there is, and it is not a probability that the organism caused a disease. A harmless skin bacterium with clean, evenly spread reads can outscore a pathogen, and the worked example shows exactly that.

### The worked example

Here are the top rows for SRR12486983, the HSV-1 case, as the table shows them.

| Organism | TASS Score | Coverage Breadth | Coverage Depth |
|---|---|---|---|
| *Bradyrhizobium* sp. WCU1 | 1.000 | 31.8% | 0.5× |
| *Actinomyces oris* | 0.980 | 2.9% | 0.1× |
| Human alphaherpesvirus 1 | 0.930 | 100.0% | 733.8× |
| *Kocuria* sp. BT304 | 0.920 | 100.0% | 39.1× |
| *Micrococcus luteus* | 0.920 | 4.8% | 0.1× |

HSV-1 is third by score, and it is plainly the finding. Its reads cover the whole 152,222-base reference, 733.8 deep on average. Its Reads cell holds 1,972,047 and Unique Reads 1,625,225, and its Abundance of 15.37% means about one read in seven from this tissue came from the virus. The two rows above it have high scores and little else. *Bradyrhizobium* reaches under a third of its genome at a depth of 0.5, and *Actinomyces oris* under 3% at 0.1, so a small number of reads is spread thinly. *Bradyrhizobium* is also a genus often found in laboratory reagents, whatever the specimen. *Kocuria* sp. BT304, a bacterium of skin and the environment, covers its whole genome here, which says its DNA is really in the tube and says nothing about whether it did any harm.

Now untick SRR12486983 and tick SRR12486989, the *Streptococcus agalactiae* case.

| Organism | TASS Score | Coverage Breadth | Coverage Depth |
|---|---|---|---|
| *Kocuria* sp. BT304 | 0.980 | 91.8% | 4.0× |
| *Cutibacterium acnes* | 0.970 | 6.6% | 0.1× |
| *Cellulosimicrobium cellulans* | 0.890 | 7.0% | 0.1× |
| *Bradyrhizobium* sp. WCU1 | 0.890 | 3.5% | 0.0× |
| *Burkholderia arboris* | 0.830 | 15.7% | 0.2× |
| *Streptococcus agalactiae* | 0.780 | 28.1% | 0.4× |

The recorded pathogen sits sixth, just past TaxTriage's threshold, with 10,698 reads covering 28.1% of its genome at a depth of 0.4. Five organisms outscore it, among them *Cutibacterium acnes*, the common skin bacterium, and the same *Kocuria* and *Bradyrhizobium* as in the first sample. Organisms that turn up in every sample of a batch, whatever the diagnosis, are the usual sign of skin, reagent, or bench contamination rather than infection.

### Recognising the pathogen

No single column picks out the pathogen. Read four things together.

1. The TASS score and Confidence label, which say the reads are real.
2. Coverage breadth and depth, which say how much of the genome the reads support.
3. TaxTriage's own annotations in its report, described below.
4. A negative control, which says what the lab and reagents put in every tube.

The viewport does not show TaxTriage's annotations, so open the pipeline's report. Right-click the result folder in the sidebar, choose **Show in Finder**, and open a sample's folder, then its `report` folder. The file `<sample>.odr.pdf` is TaxTriage's printable report, and `<sample>.odr.txt` holds the same table as tab-separated text. Its **Microbial Category** column sorts organisms into groups such as Primary, Opportunistic, Commensal, and Potential, where Primary marks a recognised pathogen. In the worked example, Human alphaherpesvirus 1 and *Streptococcus agalactiae* are both Primary, and the high-scoring *Kocuria* and *Bradyrhizobium* rows are Unknown. The **High Consequence** column flags organisms of special public-health concern and reads False for both.

This batch has no negative control, so it cannot show which organisms came from the laboratory. When you run your own samples, include one. An organism present in the negative control is suspect in every sample of the batch, whatever its score in the specimens.

TaxTriage reports what sequence is in the tube. Deciding that an organism caused a patient's infection is a clinical judgement, and confirming a pathogen for patient care needs your laboratory's own validated tests.

### The alignment pane

Selecting a row loads its reads into the alignment pane on the left, drawn against the reference the pipeline mapped them to, so you can see where along the genome the evidence sits. The pane appears only for a row whose reads were mapped. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains. The HSV-1 pile, 733.8 deep on average, runs deeper than the Inspector's default Maximum displayed depth of 500, so the pane draws a sample of the reads while the table's counts include every read.

<!-- SHOT: taxtriage-result-table -->

### Working with a single row

**BLAST Verify** in the action bar sends a sample of the selected row's reads to NCBI, as [BLAST Verification](06-blast-verification.md) explains, and needs exactly one row selected. **Extract FASTQ** opens the dialog [Running Kraken 2](02-running-kraken2.md#4-extract-the-reads-of-one-taxon) documents.

Right-clicking a row offers **Verify with BLAST...**, **Copy Organism Name**, **Copy Taxon ID**, **Copy Row as TSV**, **Look Up in NCBI Taxonomy**, and **Extract Reads...**. Copy Row as [TSV](../../GLOSSARY.md#tsv) copies the row as tab-separated text you can paste into a spreadsheet.

## What good looks like

Check the run first. A result where every TASS Score reads 0.000 is a failed run, whatever the Operations Panel said. For a human sample, the usual cause is a missing `--remove_taxids 9606`, as step 4 explains.

Then read coverage breadth and depth beside the score. A breadth near 100% with good depth, like HSV-1's 100% at 733.8, is what a real, abundant organism looks like. A breadth of a few percent at a depth near zero means a small number of reads scattered over the genome, which a high score alone does not make important. A breadth of a few percent with a large read count is the classic shape of a false call, because every read landed in one place.

Then compare Reads with Unique Reads. In a [shotgun](../../GLOSSARY.md#shotgun) library, made from DNA broken at random, the two should be close, and a small unique share means much of the evidence is copies of a few original fragments. HSV-1's 1,625,225 unique reads out of 1,972,047 is a healthy share. An [amplicon](../../GLOSSARY.md#amplicon) library, where PCR copied chosen targets before sequencing, is the exception, because every fragment starts at a primer and many reads look like copies.

Then check the database against the question. TaxTriage reports only organisms its Kraken 2 database contains. Standard-16 holds bacteria, viruses, and archaea but no fungi or protozoa, and both are causes of eye infection, so its silence about them says nothing about them.

Then read your controls and TaxTriage's Microbial Category, as Recognising the pathogen explains, and send any call that matters to [BLAST](../../GLOSSARY.md#blast) with **BLAST Verify** before you act on it.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

Several samples go in through a [samplesheet](../../GLOSSARY.md#samplesheet), a CSV file listing one sample per line. Save these three lines as `cornea.csv`, with the paths changed to your own project.

```text
sample,fastq_1,fastq_2,platform
SRR12486983,/Users/you/Documents/MyProject.lungfish/Imports/SRR12486983.lungfishfastq/SRR12486983.fastq.gz,,ILLUMINA
SRR12486989,/Users/you/Documents/MyProject.lungfish/Imports/SRR12486989.lungfishfastq/SRR12486989.fastq.gz,,ILLUMINA
```

Then run the check and the pipeline.

```bash
lungfish-cli taxtriage check-prerequisites
lungfish-cli taxtriage run \
  --samplesheet cornea.csv \
  --db ~/.lungfish/databases/kraken2/standard-16 \
  --extra-args="--remove_taxids 9606" \
  --output ./taxtriage-cornea
```

Write `--extra-args=` with the equals sign, because the value itself starts with two dashes. The `fastq_2` column is empty because each bundle holds both mates in one file, which is how the dialog passes them too. For a single sample, `--input` with a FASTQ file and `--sample` with its name replace `--samplesheet`, and `--input2` adds the second file of a pair stored as two files. The samplesheet has no role column, so sample roles have no command-line equivalent.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md) for wastewater surveillance results produced by an outside pipeline, or go to [BLAST Verification](06-blast-verification.md) to check a TaxTriage call against NCBI before you rely on it.
