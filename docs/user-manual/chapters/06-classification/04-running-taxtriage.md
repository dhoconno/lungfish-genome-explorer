---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification, 06-classification/02-running-kraken2]
estimated_reading_min: 30
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
    caption: "The TaxTriage viewport after a single-sample run of SRR36291587, with the summary cards along the top, the organism table on the right showing its TASS Score and Confidence columns, and the alignment pane on the left."
  - id: taxtriage-batch-overview
    caption: "The batch overview shown when the sample filter is set to All Samples on a two-sample run, with the menu that chooses the cell values above the cross-sample table and one column per sample."
illustrations: []
glossary_refs: [accession, blast, container, coverage-breadth, docker, fastq, kraken2, negative-control, nextflow, operations-panel, paired-end, plugin-pack, provenance, read, read-classification, samplesheet, tass-score, taxonomic-rank, taxtriage]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

[TaxTriage](../../GLOSSARY.md#taxtriage) is a pathogen-detection workflow, meaning a chain of separate programs run one after another by a program that manages them, rather than a single application you open. It takes a [FASTQ](../../GLOSSARY.md#fastq) file, which is the sequencing instrument's own output file holding every read it produced along with a quality score for each base. It then classifies every [read](../../GLOSSARY.md#read) in that file, a task called [read classification](../../GLOSSARY.md#read-classification). A read is one stretch of sequence the instrument produced.

TaxTriage then goes back over the organisms it named and gathers more evidence for each one, specifically how much of that organism's genome the reads reached and how thickly they stacked on it. The point of that second round is that a name alone is a weak claim, and TaxTriage was built for situations where somebody has to decide whether a named organism is worth acting on.

The classification step is [Kraken 2](../../GLOSSARY.md#kraken2), the same program [Running Kraken 2](02-running-kraken2.md) covers, run against the same installed databases. A Kraken 2 database is a prebuilt collection of reference genomes the program compares every read against. TaxTriage adds the steps around it. It maps the reads that Kraken 2 assigned to each candidate organism back against that organism's reference genome, and to map a read means to find the position in a reference genome that the read best matches, which is a different job from mapping a gene onto a chromosome in a genetics course. TaxTriage measures how much of the reference the reads reached and how deeply, then folds those measurements into a single number per organism.

That number is the [TASS score](../../GLOSSARY.md#tass-score). Lungfish Genome Explorer (LGE) is the app you are reading about, and its own parser expands the acronym as the Taxonomic Assignment Scoring System. Nothing the app can cite records what the upstream project itself calls the acronym, so treat the expansion as LGE's name for it rather than the official one. The score itself is not in doubt on that account, though a defect described later does keep it out of one column.

TaxTriage is not a program LGE installs. It is a published [Nextflow](../../GLOSSARY.md#nextflow) pipeline, meaning a multi-step workflow described in a workflow language and executed by a workflow engine, and each of its steps runs inside a [container](../../GLOSSARY.md#container), which is a packaged copy of a program with everything it needs to run. The other classifiers in this part ship as single programs LGE installs directly, and this one does not, which is why its setup section is longer and why TaxTriage appears in no [plugin pack](../../GLOSSARY.md#plugin-pack). Containers are handled for you by the container software, and you never build or open one by hand.

LGE pins one specific commit of the pipeline, a commit being one saved version of the pipeline's code, so that a re-run reproduces the same result. It records that commit in the result folder described in step 4 below, alongside the exact command it issued.

So what should you do with this chapter? Confirm the two runtime prerequisites first, because a missing one stops the run before it starts, then run the worked example, and read the Reading the results section carefully, because this pinned revision has a reporting gap that the section explains and that you must know about before you trust a TASS column.

## Why you would do this

You would run TaxTriage when the question is not only what is present but how well supported each answer is, and when several samples have to be compared under the same rule.

That is the shape of a pathogen-detection question. A survey classifier, meaning a tool like Kraken 2 used on its own without the extra mapping round, hands you a list of taxa with read counts. Read counts alone cannot separate the good case from the bad one. In the good case an organism's reads tile its whole genome, spread across the reference from one end to the other. In the bad case every read piles onto one repetitive stretch, a region whose sequence looks much like other regions, so reads from anywhere in the sample can land there by mistake. Both cases look identical in a count column. TaxTriage measures the difference, because its extra mapping round reports [coverage breadth](../../GLOSSARY.md#coverage-breadth), the fraction of the reference the reads actually reached, alongside mean depth, the average number of reads covering each position of the reference.

The second reason is the sample-role feature. TaxTriage lets you label each sample in a run as a clinical sample or as one of four kinds of control, and it then uses the [negative controls](../../GLOSSARY.md#negative-control) when it reports across the batch. A negative control is a sample deliberately containing no template, run alongside the real ones so that anything appearing in it must have come from the reagents, the laboratory, or the sequencing run rather than from the specimen. An organism that shows up in both a patient sample and the blank is flagged as a contamination risk, which is a judgement a per-sample count table cannot make on its own.

This chapter works through the SRR36291587 reads, an amplicon library of paired-end Illumina reads taken from a human clinical specimen. An amplicon library is one where a chosen region was copied many times over by PCR before sequencing, so the reads pile onto the targeted region rather than spreading across everything in the tube. These are the same reads [Running Kraken 2](02-running-kraken2.md) used, and the reference run behind this chapter classified 85,199 read pairs of them. Viral data is the right example here because pathogen detection from a clinical specimen is the setting the workflow was designed for, and because knowing the right answer in advance is what lets you see plainly what the tool reports well and what it reports badly.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. A name written as Cmd-N is a keyboard shortcut, meaning hold the Command key and press N.

This chapter uses the SRR36291587 reads. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive, NCBI's public store of raw sequencing reads, as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The rest of the fixture's files, and the source and licence notes for the data, are on GitHub at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

TaxTriage needs two things on the machine that no plugin pack supplies. The first is Nextflow, which LGE installs for you on first launch as one of the tools it needs before you can create or open a project at all. You do not have to install or check it yourself, and the dialog shows you its status in step 1 below.

The second is a container runtime. This pipeline runs inside [Docker](../../GLOSSARY.md#docker) containers, so Docker Desktop must be installed and running. Docker Desktop is a free download from docker.com, and once it is running its whale icon sits in the menu bar at the top of your screen, which is how you tell at a glance that it is up. On macOS 26 and later on an Apple Silicon Mac, LGE prefers Apple's own container support and uses it in place of Docker without your having to choose or install anything, and it falls back to Docker when Apple's is unavailable.

You also need a Kraken 2 database, because TaxTriage classifies against one rather than carrying a database of its own. If you followed [Running Kraken 2](02-running-kraken2.md) you already have one. If not, open **Tools > Plugin Manager...** (Cmd-Shift-B), click the **Databases** tab, and download one. The size depends entirely on which one you choose, from 0.5 GB for Viral, which holds viral genomes alone, up to 72 GB for PlusPF, which stands for Plus Protozoa and Fungi and adds those two groups to a broad collection of bacteria, archaea, viruses, the human genome, and vector sequence. A Standard collection sits between them and covers bacteria, archaea, and viruses. This chapter's run used Viral, the smallest.

## Procedure

The worked example runs TaxTriage once on the SRR36291587 reads against the Viral database. Every number quoted in this chapter came from real runs made on 2026-09-07 under Nextflow 26.04.6 and Docker, with the pipeline revision LGE pins by default, `e10bfebda32a62711f38a4e23ab03b61725a9675`, which is TaxTriage release v3.3.8. That forty-character string is a version identifier LGE fills in and records for you. You never type it and you never check it against anything.

### 1. Check the prerequisites

Both prerequisites are visible inside the dialog, so you do not need to look them up beforehand, but it is worth knowing what a failure looks like before you meet one.

1. Click the FASTQ bundle holding the SRR36291587 reads in the project sidebar to select it. A bundle is how LGE groups the files of one sample together, so a paired-end sample's two files appear in the sidebar as one item rather than two.

2. Open **Tools > Classification > TaxTriage...**. The window that opens is titled FASTQ/FASTA Operations rather than TaxTriage, which is expected and not a sign you picked the wrong item. Classification is a submenu holding one item per classifier, so picking TaxTriage opens that window with TaxTriage already selected, and the tool sidebar lists Kraken2 and EsViritu beside it if you want to switch without going back to the menu.

3. Read the **Prerequisites** row at the top of the TaxTriage pane. It carries two indicators, one labelled **Nextflow** and one labelled with the name of whichever container runtime was detected, which reads **Docker** unless you are on macOS 26 or later with Apple's own container support, where it names that instead. A filled green dot means the item was found and a filled orange dot means it was not, and the text label beside each dot names the item either way, so the colour is a second cue rather than the only one. A spinner in place of a dot means the check is still running, and the message under the Run button reads "Checking prerequisites..." while that is true. It normally settles within a few seconds.

    <!-- SHOT: taxtriage-dialog -->

4. If either indicator is orange, the **Run** button stays disabled and the message under it names the missing piece, either "Nextflow is not installed" or "No container runtime available". The fix for the second message is to install Docker Desktop and start it. Install the missing piece and reopen the dialog, because the check runs when the pane appears.

If you use the Terminal, the same check runs from the command line with `lungfish-cli taxtriage check-prerequisites`. That line is optional and readers working in the LGE window can skip it. On this chapter's machine it reported Nextflow v26.04.6, a container runtime of Docker, and the closing line "All prerequisites met. Ready to run TaxTriage."

### 2. Name the samples and give each one a role

The **Samples** section holds one editable row per sample, built from whatever bundles were selected when you opened the dialog.

1. Read the **Sample ID** field on the row. It carries the sample name LGE derived from the bundle, and whatever you type here is the label the pipeline reports the sample under, so make it match the identifier your records already use. The file names sit beside the field, one line for a single-end sample, meaning one read per fragment, and two for a [paired-end](../../GLOSSARY.md#paired-end) one, meaning the instrument read each fragment from both ends, so counting the file names on the row tells you which kind you have.

2. Set the role picker at the right of the row. A Clinical Sample is the specimen you are testing. A Negative Control is a blank run through the whole protocol to catch contamination, and an Extraction Blank is the narrower case of a blank that went through nucleic acid extraction only. A Positive Control is material known to contain the target, and an Environmental Control samples the room or bench. The contamination check reads the Negative Control and Extraction Blank rows, so label those two honestly above all, because a blank left labelled as a clinical sample removes the only signal TaxTriage has for telling contamination from a finding. The picker starts on Clinical Sample, and the worked example is a single clinical specimen, so leave it there.

3. Use **Add Sample** below the list to add a row for a sample you did not select in the sidebar, such as a control living elsewhere in the project, and **Remove** at the right of a row to drop one. Rows you add by hand are named `Sample_1`, `Sample_2`, and so on until you rename them. This lets you correct the selection inside the dialog rather than closing it and reselecting in the sidebar.

### 3. Choose the database and the platform

Open the **Kraken2 Database** picker and choose **Viral**. The picker lists exactly the Kraken 2 databases the Plugin Manager finished downloading, which are the same collections the separate Kraken2 tool in this same menu offers, and it starts on the first one installed. When no Kraken 2 database is installed at all, the section shows the words "No Kraken2 databases installed" in place of the picker, and the fix is to install one from the Plugin Manager's Databases tab.

Leave **Sequencing Platform** on **Illumina**, which is what produced these reads. The control offers three choices, the other two being Oxford Nanopore and PacBio, and the setting tells the pipeline what error profile to expect, meaning the typical pattern of mistakes that machine tends to make. For your own data, the platform is recorded with the reads when you import them and is also on the sequencing run sheet.

Leave **Skip assembly (faster)** ticked, which it is by default. Assembly means stitching overlapping reads together into long continuous sequences without using a reference, which is slow and which the detection question does not need. With the box ticked the pipeline classifies and scores without attempting it, and the explanatory line under the box reads "Classification and confidence scoring only. Significantly faster."

Leave **Advanced Settings** collapsed for a first run. Every number inside it already carries a sensible default, and the Settings section below explains all six.

<!-- SHOT: taxtriage-advanced-settings -->

### 4. Run it and find the result

Click **Run**. The dialog closes and a row appears in the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P).

The first run on a machine is much slower than later ones, because Nextflow has to pull the pipeline's container images before any step can execute. That first run takes as long as the download takes, so do not read a long first run as a failure. Once those images are cached the pipeline itself is quick. The reference run of these 85,199 read pairs against the Viral database reported a runtime of 73.4 seconds with images already cached, and produced 106 output files. Only a few of those matter to a reader. The organism detection report under the `report` folder carries the pipeline's own findings, the Kraken 2 report under `kraken2` carries the raw classification counts, and the Krona chart is the interactive picture of the community.

When the row completes, find the result in the sidebar. It is a folder named `taxtriage-batch-<timestamp>` under the project's `Analyses` folder, so a second run never overwrites the first. The angle brackets are not part of the name, which on a real run reads something like `taxtriage-batch-2026-09-07T14-23-10`. LGE names every TaxTriage run a batch, whether it holds one sample or several. Double-click the folder and the TaxTriage viewport opens.

<!-- SHOT: taxtriage-result-table -->

## Settings

Every setting the TaxTriage dialog offers is documented below. Five controls sit in plain view and six live inside the **Advanced Settings** disclosure. Some of the bold labels below end with both a colon and a period. The colon is part of the label as the app draws it on screen, and the period closes the bold opening of the paragraph, so neither is a typing slip. Skip Krona visualization is the one advanced label the app draws without a colon, so it is written without one here. Each entry ends with a short sentence naming the command-line flag that does the same job. Those closing sentences belong to the optional command-line section at the end of this chapter, so skip them if you are staying in the window.

**Sample ID.** Names one row of the sample list, and every report the pipeline writes uses this label to refer to that sample. The default is the name LGE derived from the selected bundle, or `Sample_1` and then `Sample_2` and so on for rows you add by hand, which are placeholders rather than considered choices. Change it to the identifier your lab already uses so the report matches your records. On the command line this is `--sample`.

**Sample role.** Tells TaxTriage what kind of material a row is, so that control samples can be set against the test samples when the batch is scored. The default is Clinical Sample, and the other four values are Negative Control, Positive Control, Environmental Control, and Extraction Blank. Set it on every control you ran alongside the samples, since a blank labelled as a clinical sample tells the pipeline nothing and silently costs you the contamination flagging. This setting has no command-line flag, and a command-line run declares roles through a [samplesheet](../../GLOSSARY.md#samplesheet) instead, which is a CSV file listing one sample per line.

**Kraken2 Database.** Names the reference collection the classification step compares every read against, and therefore fixes which organisms can be reported at all. The default is the first installed Kraken 2 database, which is an arbitrary choice rather than a considered one, so look at it before you run. Match it to the breadth of organism you expect, the same way you would for a plain Kraken 2 run, choosing Viral when you are hunting a virus and a Standard or PlusPF collection when you want a broad survey. On the command line this is `--db`.

**Sequencing Platform.** Tells the pipeline what kind of reads it is handling so that its steps can use error tolerances and alignment settings that suit them. The default is Illumina, and the other two choices are Oxford Nanopore and PacBio. Match it to the machine that produced the reads, since long noisy reads and short accurate reads need different handling and a mismatch degrades every step downstream. On the command line this is `--platform`.

**Skip assembly (faster).** Leaves out the assembly stage so the pipeline classifies and scores only, and turning it off adds de novo assembly, which is much slower but produces genome sequences for the organisms found. The default is on, because classification and scoring answer the detection question and assembly does not. Turn it off when you want assembled genomes and can spare the extra hours. On the command line the default is already `--skip-assembly`, and `--no-skip-assembly` turns assembly back on.

**K2 Confidence:.** Sets what share of a read's k-mers, the short overlapping pieces Kraken 2 cuts every read into, must agree on a taxon before the Kraken 2 step commits to that name. A read that falls short is not discarded. It is moved up to the lowest common ancestor of the taxa its k-mers pointed at, so a read torn between two species in one genus is reported at that genus instead. The default is 0.20, meaning one k-mer in five, and the slider runs from 0.00 to 1.00 in steps of 0.05. Raise it when the organism list fills with species that could not plausibly be in your sample, which on this chapter's SARS-CoV-2 run would mean unrelated viruses appearing beside the coronavirus, and lower it when too much of the library comes back unclassified. On the command line this is `--confidence`.

**Top hits:.** Sets how many organisms the pipeline carries forward into its evidence-gathering steps and reports, ranked by how much support each one has. The default is 10 and the stepper accepts 1 to 100. Raise it when you expect a complex community and the top ten would cut off organisms you care about, and remember that every extra organism costs another mapping round. On the command line this is `--top-hits`.

**Max memory:.** Caps how much memory the pipeline is allowed to use, and setting it above what your Mac actually has makes steps fail rather than run. To see how much your Mac has, open the Apple menu, choose About This Mac, and read the Memory line. The default is 16 GB and the stepper accepts 2 to 256 GB in steps of 2. Raise it for a large database on a machine with plenty of memory, and lower it to leave room for other work. On the command line this is `--max-memory`.

**Max CPUs:.** Caps how many processor cores the pipeline may use at once, so a higher cap finishes sooner and leaves less of the machine free for anything else. The default is the number of cores currently available on your Mac, and the stepper will not let you exceed your machine's core count. Lower it when you need the machine responsive while a long run proceeds. On the command line this is `--max-cpus`.

**Skip Krona visualization.** Leaves out the interactive Krona chart the pipeline otherwise renders of the community it found, which is an HTML file written into the result folder. The default is off, so the chart is produced, and the tables in the viewport are unaffected either way. Turn it on to shorten the run when you only want the tables. On the command line this is `--skip-krona`.

**Extra arguments:.** Passes text straight through to TaxTriage or Nextflow without LGE checking it, which is how you reach a pipeline option the dialog does not expose. Leave it empty, which is the default and which is right for every run in this chapter and for almost every run you will make. An unclosed quote blocks the run with the dialog saying so under the Run button. Use it only when you know the exact option you need, since anything LGE does not recognise is handed on verbatim. On the command line this is `--extra-args`.

## Reading the results

The viewport opens as a summary card bar across the top, an alignment pane on the left, an organism table on the right, and an action bar along the bottom. The alignment pane draws the reads stacked up against the reference genome they were mapped to, one row per read, so you can see where along the genome the evidence actually sat. [Reading an Alignment](../04-alignments/02-reading-an-alignment.md) documents that viewer and its controls in full.

Read the summary cards first. A single-sample result shows four, labelled Organisms, Runtime, High Confidence, and Samples. High Confidence counts the organisms whose TASS score reached 0.80. On this version of LGE that card always reads zero, because of the defect described immediately below, so ignore it until the defect is fixed.

### A reporting gap you must know about

Meet this before you read the table. On this pinned revision the viewport's **TASS Score** column reads 0.000 for every row, and so does the Confidence column beside it and the High Confidence summary card above it. The pipeline itself scored this chapter's organism at 99.

The two numbers disagree because they come from different files and different scales. The pipeline writes its own score on a 0 to 100 scale into an organism detection report, while the viewport's parser and its TASS Score column expect a 0 to 1 scale and read a separate per-organism confidence file. This pinned pipeline revision never writes that confidence file. Lacking it, LGE falls back to a top-hits report that carries no score column at all, and every row therefore arrives with a score of zero.

Trust the pipeline's own figure of 99 out of 100 and disregard the column. The report file holding it is `report/<sample>.odr.txt` inside the result folder, where the sample part of the name is the Sample ID you set in step 2, so this chapter's run wrote `report/SRR36291587.odr.txt`. Reach it by right-clicking the result folder in the sidebar, choosing Show in Finder, and opening that file in any text editor. The action bar's **Open Report** button opens a report from the folder but does not reliably pick that particular file, so go through the Finder when you want the score.

Everything else in the table is sound. The counts, the unique-read counts, the coverage figures, and the accession are all correct, and the contamination flagging described later is unaffected, since it does not read the score. The practical consequence is only that you cannot rank calls by the TASS column inside the app, because every value in it is identical. Rank by coverage and by unique reads instead, and read the score from the report file when you need it. This has been reported.

### The organism table

The organism table holds one row per organism call, with six columns. **Organism** names the call and **TASS Score** gives its numeric score to three decimals. **Reads** counts the reads that mapped to that organism's reference and **Unique Reads** counts those that mapped there and nowhere else, so a large gap between the two means the evidence is shared with relatives rather than specific to this genome. **Coverage** reports how much of the reference the reads reached, and **Confidence** restates the TASS score as a labelled bar. A multi-sample run adds Sample, Coverage Depth, and Abundance columns to a wider table, where Abundance is the share of that sample's classified reads which went to that organism, written as a proportion between 0 and 1 rather than as a percentage. The table sorts by TASS score descending by default, which on this version leaves the order unchanged because every score is zero.

### What the TASS score means

The TASS score is a composite. It folds read support, how those reads distribute across the organism's reference, and agreement between the pipeline's steps into one value that can be sorted on. Two steps disagree when, for example, the classification step assigns many reads to a species while the mapping step finds those same reads covering only a narrow slice of that species' genome. A call backed by many reads that spread across the whole reference and that the pipeline's steps agree on scores high, and one backed by a few reads piled on one window scores low.

LGE reads the score in three bands, and hovering a TASS cell shows a tooltip naming the band and saying what to do about it. The bands are what the column would show if the defect above were fixed.

| Score | Band | What the tooltip advises |
|---|---|---|
| 0.80 and above | High | A strong taxonomic signal |
| 0.40 to below 0.80 | Medium | Likely a true positive, and worth verifying with BLAST |
| Below 0.40 | Low | A weak signal that may be noise or contamination |

[BLAST](../../GLOSSARY.md#blast) compares one sequence against NCBI's own reference database and reports what it most closely matches, which is an independent check on a call the pipeline made from its own database.

The Confidence column shows the same three bands as a filled bar, so you can read the band without reading the number.

The score is not a calibrated probability that the organism is present. It is a repeatable sort order, so that two reviewers looking at the same batch work through it in the same sequence. Treat a high score as a reason to look first, not as a verdict.

### The reference run

The reference run returned one organism call worth acting on. The pipeline's own report named a single species, and the viewport's table shows that species alongside the lineage rows above it, from `root` down through `Sarbecovirus`, plus an `unclassified` row. That is fifteen rows in all, and the Organisms summary card reads 15 for the same reason. Read the species row and treat the lineage rows as the path down to it rather than as fourteen further findings.

The species row is *Severe acute respiratory syndrome coronavirus 2*, taxonomy identifier 2697049. The pipeline's own organism detection report gives it 96.9542% of reads, a coverage breadth of 100.0%, a mean depth of 1258.7 reads per position, and 165,208 reads aligned to the reference. Each read pair contributes two reads to that aligned count, which is why an aligned count near 165,000 is consistent with a library of 85,199 pairs. The Kraken 2 step inside the pipeline assigned 82,983 read pairs to that species and left 770 read pairs unclassified.

Those 770 unclassified pairs are the ordinary residue of a real library. They are reads the Viral database could not match to anything it holds, which for an amplicon library from a human specimen means primer sequence, host DNA the database does not contain, and reads too poor in quality to place. Their number is small here because PCR enriched the viral target so heavily that almost nothing else survived into the library.

Coverage breadth of 100.0% means the reads reached every position of the 29,903-base reference, which for a tiled amplicon library is exactly the expected result and is the observation that supports the call. A mean depth near 1,250 reads per position is ordinary for an amplicon run, where hundreds to a few thousand reads per position is the usual range, because the protocol deliberately concentrates every read onto one small genome.

### Working with a single row

Selecting a row loads its supporting reads into the alignment pane on the left, drawn against the reference genome the pipeline mapped them to, so you can see where the evidence actually sat.

The action bar along the bottom carries **BLAST Verify**, which sends the selected row's reads to NCBI for an independent second opinion, described in [BLAST Verification](06-blast-verification.md). It stays disabled until exactly one row is selected, and the tooltip explains why. Beside it sit **Export**, which opens the export menu described below, **Extract FASTQ**, which pulls the selected organism's reads out into a new bundle, **Open Report**, which opens one of the pipeline's own report files outside the app, and a [provenance](../../GLOSSARY.md#provenance) button that shows what was run. A **Related** button joins them once the project holds other analyses built from the same reads, so a first run shows no such button.

Right-clicking a row offers the same BLAST action under the name **Verify with BLAST...**, along with items to copy the organism name, the [accession](../../GLOSSARY.md#accession) number, the taxonomy identifier, or the whole row as TSV. TSV means tab-separated values, the same idea as CSV with tab characters between the fields instead of commas.

You can attach a sample sheet of your own metadata with **Import Metadata...** in the Inspector, and the fields it carries then become available as extra columns from the table's column chooser.

### Comparing several samples

When a result holds more than one sample, a segmented control appears above the table. Its first segment is **All Samples** and the rest are the individual sample identifiers.

Selecting **All Samples** replaces the per-sample organism table with the batch overview, which is a different view rather than a tab you switch to. The overview lays out the organisms as rows and the samples as columns, and a menu above it chooses what the cells contain, either TASS Score, Total Reads, Unique Reads, or Coverage, where Coverage means breadth rather than depth. The grid's leading columns carry each organism's name, how many samples detected it, its mean score, and the range of read counts across the batch, and the per-sample columns follow them in the same row. A Risk column joins those leading columns when the batch holds a negative control. Selecting an individual sample brings the per-sample organism table back and reloads the alignment pane with that sample's reads.

<!-- SHOT: taxtriage-batch-overview -->

The overview is where you compare specimens against controls. An organism carrying a real score in a negative control column is a candidate contaminant for the whole batch. TaxTriage flags such a row and never removes the row or its reads, so nothing is taken away from your counts and the decision stays yours. The flag appears on two surfaces. In the overview the organism gets a warning triangle in the **Risk** column, with the tooltip "Detected in negative control sample". In the per-sample table the same organism's name carries a warning triangle and turns orange. Neither view names which control the organism turned up in, so read the control's own column in the overview to find that out.

The **Export** button's menu writes what you have. **Export as CSV...** and **Export as TSV...** write the visible table, and **Copy Summary** puts the pipeline's summary text on the clipboard. On a multi-sample result the menu grows two more items. **Export Organism Matrix (CSV)...** writes one row per organism with columns for the mean TASS score, how many samples detected it as a fraction, a contamination-risk column reading Yes or No, and then one column per sample holding that sample's score. **Export Batch Report...** writes a plain-text summary with sections for cross-sample organisms, contamination-risk organisms, and high-confidence organisms. There is no PDF and there are no report templates, so the matrix CSV is the file to keep if you are loading results into something downstream.

## What good looks like

Read coverage breadth before you read anything else. It is the fraction of the organism's reference genome that the reads reached, and it is the single number that separates a real detection from a pile of reads on a repetitive stretch. On the reference run it was 100.0%, meaning the reads covered every position of the SARS-CoV-2 genome, which is what a working amplicon library looks like. A breadth in the low single digits with a large read count is the classic shape of a spurious call, because it says the reads all landed in one place. A middle value such as 40% is neither, and it usually means either that the organism is genuinely present at low abundance, so the reads have not yet reached the whole genome, or that a relative of the true organism is what your database actually holds. Look at depth alongside it, because a middling breadth with a very high depth points at the second case.

Then compare Reads against Unique Reads, keeping in mind which kind of library you have. In a shotgun library, where fragments start at random positions across everything in the tube, the two counts should be close, and a Unique Reads count that is a small fraction of Reads means most of the evidence is shared with relatives, so the honest statement is that something in that group is present rather than that this particular genome is.

An amplicon library is the exception to that rule. Every fragment in one starts at a primer position rather than at a random point, so many reads are literal copies of the same original molecule and the tool counts only one of them as unique. A low unique fraction is therefore expected and is not a warning sign. The reference run's row reported 6,865 unique reads against 168,265 aligned in the LGE database, which is the shape an amplicon library should have. Apply the unique-read rule to shotgun libraries and set it aside for amplicon ones.

One number needs care here. The reads-aligned figure the pipeline wrote into its own report is 165,208, while the database LGE builds from the same run reports 168,265, and the app's Reads column shows the second. The two are different measurements rather than a contradiction. The pipeline counted its own alignments as it wrote them, and LGE recounted from the alignment file after marking duplicates. Quote whichever you are reading and say which it came from.

Then check the database against the question. TaxTriage can only report organisms its Kraken 2 database contains, exactly as a plain Kraken 2 run can. The reference run used the Viral database, so its silence about bacteria is not evidence that none were present. It is evidence that nothing was asked. Rerun against a broader collection when you need a survey rather than a targeted check.

Then look at your controls. If you labelled a negative control and it carries an organism at any real score, that organism is suspect across every sample in the batch, whatever its score in the specimens. This is the reason the role picker exists and the reason it is worth setting properly at run time rather than reasoning about afterwards.

Finally, remember what the score does and does not tell you while the reporting gap above persists. Rank by coverage breadth inside the app, and by unique reads when your library is shotgun, read the pipeline's own scores from the report file when you need them, and send anything that matters to BLAST before you act on it.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the dialog cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application. A single sample goes in behind `--input`, with `--input2` for the second mate of a pair, and `--sample` naming it.

The database path this example passes is the one the Plugin Manager wrote when it downloaded the collection. The Plugin Manager's Databases tab shows the folder holding all of them along the foot of the tab, and each collection sits in a folder named after it beneath that.

```bash
lungfish-cli taxtriage run \
  --input SRR36291587_1.fastq.gz \
  --input2 SRR36291587_2.fastq.gz \
  --sample SRR36291587 \
  --platform illumina \
  --db ~/.lungfish/databases/kraken2/viral \
  --output ./taxtriage-viral
```

The command prints the whole configuration before it starts, then progress lines, then a results block. The reference run's results block read as follows, and the path of every report, metrics, and Krona file it wrote was listed underneath.

```
TaxTriage pipeline completed successfully
Runtime: 73.4s
Samples: 1
Reports: 5
Metrics: 8
Krona visualizations: 1
Total output files: 106
```

Check the runtime prerequisites on their own with `lungfish-cli taxtriage check-prerequisites`, which reports Nextflow and the container runtime and exits non-zero when either is missing.

The dialog's controls all reach the command line. `--db`, `--platform`, `--confidence`, `--top-hits`, `--max-memory`, `--max-cpus`, `--skip-krona`, and `--extra-args` set the settings of the same name, and `--skip-assembly` is already the default with `--no-skip-assembly` turning assembly back on. Five further options have no counterpart in the dialog. `--samplesheet` reads the whole sample list from a CSV instead of naming samples one at a time, which is how a headless run declares more than one sample and their roles. `--recursive` picks up eligible FASTQ files inside subfolders when the input is a folder. `--rank` sets the [taxonomic rank](../../GLOSSARY.md#taxonomic-rank) the report is built at, one of D, P, C, O, F, G, or S, which are the initials of Domain, Phylum, Class, Order, Family, Genus, and Species, defaulting to S. `--nf-profile` chooses the Nextflow execution profile and defaults to docker. And `--revision` pins which commit of the pipeline runs, defaulting to `e10bfebda32a62711f38a4e23ab03b61725a9675`, which you should leave alone unless you are reproducing an older run.

A samplesheet is a CSV with one header line and one line per sample. LGE writes one into every result folder, and the reference run's file reads as follows.

```
sample,fastq_1,fastq_2,platform
SRR36291587,/path/to/SRR36291587_1.fastq.gz,/path/to/SRR36291587_2.fastq.gz,ILLUMINA
```

A two-sample run behaves the same way. The reference batch run took 86.2 seconds for two samples and its database build reported 30 taxonomy rows parsed, fifteen per sample, since each sample carries its own copy of the lineage. Its second sample was a 10,000-pair subsample of the same library, which the pipeline scored at a breadth of 100.0%, a mean depth of 147.7, and 9,748 reads assigned by Kraken 2.

The result folder records exactly what ran. A file named `taxtriage-launch-command.txt` holds the pipeline repository `jhuapl-bio/taxtriage`, the pinned revision, the matching release tag, the effective execution profile, the working directories, and the full Nextflow command in both the form LGE issued and a reproducible form that fetches the pipeline from its repository. Keep that file with the result, because it is what lets somebody else reproduce the run.

Two neighbouring commands finish the headless path. `lungfish-cli import taxtriage <results-dir>` brings a TaxTriage result produced on another machine into a project so the viewport can read it, taking `--output-dir` for the project and `--name` for the imported result's name. `lungfish-cli build-db taxtriage <result-dir>` builds the SQLite index the viewport queries, taking `--force` to rebuild over an existing one and `--no-cleanup` to keep the intermediate files it otherwise deletes. On the reference run it reported "Parsed 15 taxonomy rows, 2 accession entries from top report fallback". The phrase "top report fallback" is the visible sign of the reporting gap described above, because it names the file LGE fell back to when the confidence report was missing, and the fifteen rows are the one organism plus the lineage ranks above it rather than fifteen separate organisms.

Pulling one organism's reads out is its own command, which takes the result directory rather than a single file.

```bash
lungfish-cli extract reads --by-classifier --tool taxtriage \
  --result ./taxtriage-viral --accession NC_045512.2 \
  --source SRR36291587_1.fastq.gz \
  --output sars-reads.fastq
```

`--accession` takes the reference accession, which the viewport's Copy Accession Number puts on your clipboard and which the organism table's row carries. Kraken 2 results are selected by `--taxon` and its numeric taxonomy identifier instead, because they carry no accession.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md) for wastewater surveillance results produced by an outside pipeline, or go to [BLAST Verification](06-blast-verification.md) to check a TaxTriage call against NCBI before you rely on it.
