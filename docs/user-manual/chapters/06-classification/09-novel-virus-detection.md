---
title: Novel Virus Diagnostics
chapter_id: 06-classification/09-novel-virus-detection
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 17
task: Import Novel Virus Diagnostics (NVD) pipeline results and read the contig-keyed BLAST viewport.
tags: [classification, nvd, novel-virus, blast, import, wastewater]
tools: [nvd]
parameters_refs: [import.nvd]
entry_points:
  - "File > Import Center… > Classification Results > NVD Results"
  - "CLI: lungfish-cli import nvd <input-path>"
  - "CLI: lungfish-cli nvd summary <input-path>"
shots:
  - id: nvd-import-card
    caption: "The Classification Results tab in the Import Center shows the NVD Results card and its file hint."
  - id: nvd-import-preview
    caption: "The Preview panel in the NVD Import sheet lists Experiment, Samples, Contigs, and BLAST hits after scanning the demo folder."
  - id: nvd-result-viewport
    caption: "The NVD viewport shows an expanded contig with its ranked matches and a dash in the Unique Reads column."
  - id: nvd-column-menu
    caption: "The contig outline's header menu shows the Standard Columns checklist and Reset Column Widths."
  - id: nvd-blast-drawer
    caption: "The BLAST Results drawer opens below the outline and above the action bar."
illustrations:
  - id: contig-alignment-length
    brief: "Draw two stacked bars of equal width on a Cream background to compare the share of each contig in one BLAST alignment. Outline each bar in Warm Grey and fill the approximate aligned share in Creamsicle, with no specific position implied. Use Deep Ink for the labels. Label the upper bar NODE_1_length_500_cov_10.0 with Length of 500 bases and Aln Length of 498 bases. Label the lower bar Hypothetical contig with Length of 5,000 bases and Aln Length of 400 bases."
glossary_refs: [nvd, contig, blast, e-value, percent-identity, bit-score, accession, taxon, read, fastq, bam, bundle, provenance, checksum, reads-per-billion, inspector, operations-panel, pileup, unique-reads, primary-alignment, mate, viewport, tsv, relative-abundance, fasta, csv, secondary-alignment, working-directory, sample-metadata, pipeline, mapper, command-line-flag, reference-bundle]
features_refs: [import.nvd]
fixtures_refs: [nvd-demo]
brand_reviewed: false
lead_approved: false
---

## What it is

[Novel Virus Diagnostics](../../GLOSSARY.md#nvd) (NVD) is a [pipeline](../../GLOSSARY.md#pipeline), a series of programs that pass results from one to the next. It was built for wastewater viral surveillance, which uses sequences from sewage to track viruses in a community. Lungfish Genome Explorer (LGE) imports the files from a finished NVD run.

A [read](../../GLOSSARY.md#read) is a sequence reported by a sequencing instrument. Illumina makes sequencing instruments. A read classifier looks for the organism that each read came from. NVD assembles overlapping reads into [contigs](../../GLOSSARY.md#contig), longer stretches of sequence. It searches each contig for similar sequences using [BLAST](../../GLOSSARY.md#blast), a program from the National Center for Biotechnology Information (NCBI).

| Read type | Typical length |
|---|---|
| Illumina read | 75 to 300 bases |

LGE needs only the `*_blast_concatenated.csv` table in `05_labkey_bundling/`. A [CSV](../../GLOSSARY.md#csv) is a plain-text table with commas between fields. The asterisk stands for the run's prefix, and LGE also accepts `.csv.gz`, the form compressed with gzip. You can import without the earlier stage folders. LGE opens a [viewport](../../GLOSSARY.md#viewport), the main area of the window. If a contig has more than one match, expand its row to see all its reported BLAST matches.

## Why you would do this

A match across thousands of bases is less likely to occur by chance than a match on a single 150-base read. In a search for new viruses, look more closely at a long contig if only part of it matches a known virus or if its [percent identity](../../GLOSSARY.md#percent-identity), the share of aligned positions that agree, is low. The imported table holds only contigs that BLAST matched, so a contig that matched nothing never reaches this viewport. This view alone cannot tell you a run held no unknown sequence.

The synthetic NVD demo results illustrate the known-virus case. All their best matches have at least 96 percent identity.

LGE groups the spreadsheet rows by contig so you can see whether other strong matches name the same organism. NVD keeps at most five matches per contig, so a match naming another organism can sit just outside the list. LGE sorts matches by [e-value](../../GLOSSARY.md#e-value), the expected number of matches this strong or stronger by chance, lowest first. When e-values tie, LGE puts the higher [bit score](../../GLOSSARY.md#bit-score) first. A bit score measures alignment strength. The first row is the contig's best match.

## Before you start

Open a project so LGE has somewhere to save the result. An alert is a message that needs your attention. LGE shows the alert **No Project Open** if you start without a project open. For setup, follow the procedure in [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) before importing.

A demo project is a project supplied with practice data. Choose **Help > Demo Projects…** to download Pathogen Detection, then locate its `Practice Data/nvd-demo/results` folder. The NVD demo results are also available as a fixture, a set of files prepared for practice. The [`docs/user-manual/fixtures/nvd-demo` folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.70/docs/user-manual/fixtures/nvd-demo) is on GitHub, a website for sharing code and files. The manual's [practice data guide](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to download it. Either way, select `nvd-demo/results` when you import.

LGE looks in two locations for optional files and copies the files it finds into the result. A [FASTA](../../GLOSSARY.md#fasta) file lists named sequences in plain text. A [BAM](../../GLOSSARY.md#bam) file records alignments, which show where reads match a sequence.

| Optional file | Where LGE looks | What the file enables |
|---|---|---|
| Contig FASTA file for each sample, named `<sample>.human_virus.fasta` | `02_human_viruses/03_human_virus_results/` | **Verify with BLAST…** and the other commands that use the contig's sequence |
| BAM file for each sample, with the sample name in its file name | `02_human_viruses/03_human_virus_results/mapped_reads/` | LGE's own read count, [Unique Reads](../../GLOSSARY.md#unique-reads), the reads in **Contig Alignment**, and **Extract Reads…** |

The demo has the table and simulated contig FASTA files, so you can verify a match. To count Unique Reads, view mapped reads, or extract reads, use a run with the sample's BAM file. A plugin pack is an add-on that supplies tools. This import needs no plugin pack and the demo import can take well under a second.

NCBI Taxonomy is NCBI's catalog of named groups of organisms. It is an optional download in the **Databases** tab of the **Plugin Manager**, the window where you install plugin packs and databases. Choose **Tools > Plugin Manager…** (Cmd-Shift-B) to open it. Without NCBI Taxonomy, LGE cannot judge the BLAST result in the last verification step.

## Procedure

### Open the NVD importer

1. Choose **File > Import Center…** (Cmd-Shift-I).

2. Click **Classification Results**. The **NVD Results** card has the hint "NVD run folder containing *_blast_concatenated.csv(.gz)".

   <!-- SHOT: nvd-import-card -->

3. Click **Import…** on the **NVD Results** card. **NVD Import** opens as a sheet, a dialog attached to the window.

### Choose the NVD run folder and check the preview

1. Click **Browse…**.

2. Select the folder that contains `05_labkey_bundling/`. For the demo, choose `nvd-demo/results`. The hint reads "Select the top-level NVD run directory (containing 05_labkey_bundling/)."

3. Check **Preview** before importing. It shows **Experiment**, **Samples**, **Contigs**, and **BLAST hits**, with **Total BAM size** when alignment files are present. For the demo, expect experiment `100`, 3 samples, 4 contigs, and 10 BLAST hits.

   <!-- SHOT: nvd-import-preview -->

   **Experiment** identifies the run. **Samples** counts the distinct sample names in the table. If the preview warns that it cannot find the table, check the selected folder and look for the table in `05_labkey_bundling/`.

### Import and open the NVD result

1. Click **Run** once it becomes available after a successful scan. The `lungfish-cli` program runs LGE commands typed in a terminal, a window for entering commands. LGE uses it to run `lungfish-cli import nvd` in the background. The [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which lists running and finished tasks, shows the job as "NVD Import". The panel is under **Operations > Show Operations Panel** (Cmd-Shift-P). The row offers **Copy CLI Command** and **Cancel**.

2. To open the NVD viewport, click the result row once. LGE saves the result as `nvd-<experiment>` in the project's `Analyses` folder. The sidebar is the list along the side of the window. When the import finishes, the **Analyses** group at the top of the sidebar shows the result, `nvd-100` for the demo, with its date underneath.

### Walk the NVD viewport

Four summary cards repeat the preview counts under **Experiment**, **Samples**, **Contigs**, and **Hits**. The outline is a table whose rows expand to show more rows. Each contig row shows its best BLAST match. The detail pane shows information about the selected row.

1. Expand a contig with the triangle beside its name to compare matches. The first expanded row, Hit #1, repeats the best match. In SampleA, `NODE_2_length_300_cov_5.0` has five HIV-1 matches and `NODE_1_length_500_cov_10.0` has three SARS-CoV-2 matches.

   <!-- SHOT: nvd-result-viewport -->

   The assembler, the program that joined the reads, supplies the full name. In this example, `NODE_2` is the contig number and `length_300` is its length in bases. `cov_5.0` is the assembler's coverage figure for the contig. A k-mer is a short stretch of sequence of a fixed length. In names of this form, the coverage figure usually counts how often those stretches occur in the reads, averaged across the contig. This average k-mer coverage runs lower than the number of reads over each base, so use it to compare contigs from the same run. The outline and detail pane shorten the name to `NODE_2 (300 bp)`, and search also uses the full name.

2. Select a contig row to see its details. It shows the contig name, sample, organism and rank, the level of the organism's name, such as species or genus. The six badges, small labeled values, are **Identity**, **E-value**, **Bit Score**, **Mapped Reads**, **RPB**, and **Length**. Mapped reads are reads placed back on the contig. Reads per billion (RPB) rescales the mapped count by how deeply the sample was sequenced.

   **Contig Alignment** names the best match and stacks the reads mapped back to the contig from the sample's BAM file at their aligned positions. Expect the heading and best match above an empty read view in the demo.

### Verify a contig with BLAST

To check a match with a fresh BLAST search, LGE uses the contig's sequence from the sample's FASTA file. All four simulated contigs in the demo use sequence from the SARS-CoV-2 reference, a sequence used for comparison. SampleA's `NODE_1_length_500_cov_10.0` tests a row whose reported match and sequence refer to the same virus. The other three demo contigs hold SARS-CoV-2 sequence under rows that name HIV-1, a herpesvirus, or a norovirus.

With NCBI Taxonomy installed, verifying one of those three gives **Unsupported** when NCBI's best match is SARS-CoV-2 and not the organism the row names. It gives **Inconclusive** if NCBI returns no strong match. The simulated files produce those results.

1. Select one contig row or one of its expanded matches. For the demo, use SampleA's `NODE_1_length_500_cov_10.0`. A [taxon](../../GLOSSARY.md#taxon) is a named group of organisms. The **By Taxon** headings label those groups, so selecting one leaves verification grayed.

2. Click **Verify with BLAST…** in the action bar at the bottom of the window. If the button is grayed, point to it to see the reason in its tooltip, the note shown beside the pointer.

3. Confirm in the **Run BLAST at NCBI?** sheet. LGE submits the contig sequence to NCBI and looks for a copy of NCBI Taxonomy that you have already installed. If it finds one, LGE judges the result against the species of the organism in the selected row's **Classification** cell, or against the organism itself when the row names a group above species. The same rule applies if you select a lower-ranked hit.

4. Read the verdict for the contig's single search in the **BLAST Results** drawer at the bottom of the window. If the badge reads **Not judged**, install NCBI Taxonomy in the **Databases** tab of the **Plugin Manager** and run **Verify with BLAST…** again. For what the verdict means, see the [BLAST Verification](06-blast-verification.md#the-summary-bar-and-the-verdict) chapter.

   <!-- SHOT: nvd-blast-drawer -->

## Settings

The import sheet has no settings. The command-line import accepts `--name` and `--output-dir`. A [flag](../../GLOSSARY.md#command-line-flag) is an option you type after a command, such as the two shown here. The [`import nvd`](../appendices/cli-reference.md#import-nvd) entry in the CLI Reference lists both flags.

Three controls above the outline change what you see. For `lungfish-cli nvd export contigs`, you can repeat `--sample`. A subject title is the title of the matched database record. An [accession](../../GLOSSARY.md#accession) is the identifier for that record.

**By Sample / By Taxon.** Switches the outline between two arrangements of the same contigs. The default is **By Sample**, which shows one row per contig without grouping by organism so you can review the run in order. Switch to **By Taxon** to group contigs whose best matches name the same organism. This setting has no command-line flag.

**All Samples.** Opens a popover, a small panel beside the button, where you can select samples. The default includes every sample so you can see the whole run, and the button updates to show a narrower selection, such as "2 of 3 Samples". Narrow the selection to review one sample at a time. On the command line this is `--sample`.

**Search contigs….** Shows contigs whose name or best match's organism name, subject title, or accession contains what you type. The default is empty so you can see every contig in the selected samples. Use it to find a named contig or narrow the outline by its best match. On the command line this is `--search`.

## Reading the results

The outline has fourteen columns, six of which also appear as detail badges. NVD's taxonomy adjustment is the pipeline's own step that sets the organism name shown in **Classification**.

| Column | What it holds |
|---|---|
| Sample | Sample the contig was assembled from, as the pipeline named it |
| Contig | Short name such as `NODE_2 (300 bp)`. **Copy Name** and the export give the full name |
| Length | Contig length in bases (badge) |
| Classification | Organism the pipeline assigned to this contig, after its own taxonomy adjustment |
| Rank | Level of the organism name the pipeline assigned to the contig |
| Accession | ID of the matched database record |
| Subject | Full title of the matched record |
| Identity % | Share of aligned positions that agree (badge) |
| E-value | Expected number of equally strong or stronger matches by chance (badge) |
| Bit Score | Alignment strength on a scale independent of database size (badge) |
| Mapped Reads | Reads mapped back to this contig, as counted by NVD (badge) |
| Unique Reads | LGE's filtered count from the sample's BAM file, or a dash when unavailable |
| RPB | Reads per billion, the mapped count scaled to the sample's total reads (badge) |
| Aln Length | Number of columns in the BLAST alignment |

The outline lists contigs longest first, and clicking a header keeps that order. Drag headers to move columns, or drag dividers to resize them. Right-click a header for **Standard Columns** and **Reset Column Widths**. Once you attach [sample metadata](../../GLOSSARY.md#sample-metadata), details such as collection dates, **Sample Metadata** lets you show those columns.

<!-- SHOT: nvd-column-menu -->

**Length and Aln Length.** Compare these to estimate how much of the contig a match covers. Aln Length counts alignment columns, which can include gaps. A gap is a position where one sequence has no base opposite the other. The difference between the two lengths only approximates how much sequence lies outside that match. A local alignment finds a matching stretch within a sequence. Other stretches may align to the same record in a second local alignment, align to another record, or have matches too weak to report.

| Contig | Length in bases | Aln Length |
|---|---|---|
| Demo `NODE_1_length_500_cov_10.0` | 500 | 498 |
| Hypothetical contig | 5,000 | 400 |

<!-- ILLUSTRATION: contig-alignment-length -->

Identity describes the aligned stretch. In the demo it is high for all four best matches. An isolate is a virus sample obtained from a particular source. Look at how much of the contig aligns and whether the identity sits well below the identity that isolates of the named virus show with one another.

| What you see | How to read it |
|---|---|
| Near 100% identity across nearly all of a long contig | Supports a match to a known viral sequence |
| A match that covers only part of a long contig, or whose identity sits well below the identity that isolates of the named virus show with one another | Expand the row if it has multiple matches. Compare **Length** with **Aln Length** for each match to estimate how much of the contig lies outside it |
| Demo best matches at 99.5%, 96.0%, 99.0%, and 97.5% identity | Inspect alignment length to see how much of each contig agrees |

A fresh search from **Verify with BLAST…** runs megablast, a BLAST mode tuned for nearly identical sequences. It can confirm a near-identical contig but can miss a distant relative. For a possible new virus, use a protein-level search outside LGE. It compares sequences of amino acids, the building blocks of proteins, and can find relatives whose base sequences are too different for a nucleotide search, which compares bases directly.

An e-value shown as `0` is too small for BLAST to print at its displayed precision. See how the scores fit together in [BLAST Verification](06-blast-verification.md#reading-the-results). Report the match at the rank shown, such as genus or family if the row gives a broad name. The name comes from the pipeline's own adjustment, so check the row's **Subject** and **Accession** before you report it.

**Mapped Reads and Unique Reads.** Mapped Reads comes from NVD's table. [Mates](../../GLOSSARY.md#mate) are the two reads from one fragment, and NVD may count them separately. LGE marks duplicates, reads that appear to be copies from the same original fragment, at import, then counts BAM records on the contig for Unique Reads. It skips records marked as unmapped, secondary (an alternative placement), supplementary (another part of a split placement), or duplicate. Each mate has its own record and counts once if retained. The demo shows dashes in Unique Reads because it has no BAM files.

**RPB.** To calculate [reads per billion](../../GLOSSARY.md#reads-per-billion), divide Mapped Reads by the sample's total read count and multiply by a billion. Find the denominator, `total_reads`, in `demo_blast_concatenated.csv`. The viewport does not display it.

| Demo contig | Mapped Reads | Total reads | RPB |
|---|---|---|---|
| SampleA SARS-CoV-2 | 50 | 1,000,000 | 50,000 |
| SampleB herpesvirus | 100 | 2,000,000 | 50,000 |

The same share of each sample's reads mapped to its contig, even though the SampleB contig had twice the mapped reads. RPB has no fixed good value. It corrects only for sequencing depth, the total reads from a sample. Contig length and how much virus survived collection and extraction can still affect RPB. Compare RPB between contigs of similar length, such as contigs for the same virus in different samples. Use the alignment and read support to judge each match.

### The NVD action bar and row menu

The NVD action bar has **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**. The [Running Kraken 2](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) chapter describes the shared controls.

**Export** saves the best match of each contig shown in the outline. It uses the checked samples and any text in **Search contigs…**, includes any visible sample metadata columns, and writes rows independently of the outline's sort or grouping. The save sheet may be titled **Export NVD Contigs**, with `<experiment>_nvd_contigs.tsv` as the default name. LGE runs `lungfish-cli nvd export contigs` in the Operations Panel. The [tab-separated file](../../GLOSSARY.md#tsv) puts a tab between fields and has all fourteen standard columns, with Aln Length after Identity % and empty cells where the outline shows dashes.

**Export** becomes available once the result opens and at least one sample is checked. If you clear every sample, its tooltip reads "Pick a sample to export." **Extract Reads…** needs BAM files and saves each read behind the selected rows once in a new [FASTQ](../../GLOSSARY.md#fastq) [bundle](../../GLOSSARY.md#bundle). FASTQ stores reads with their quality scores, and a bundle groups related files. Follow the steps for [the Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) to use it.

The information button opens **NVD Pipeline Info**, which lists the experiment, import date, format version, counts, source directory, and BLAST database version if recorded. To attach metadata, use the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window. Under **Samples & Metadata**, click **Import Metadata…** while the result has no metadata.

Right-click a contig row for **Extract Reads…** and the sequence commands below. The sequence commands require the sample's contig FASTA file.

| Sequence command | Use it to |
|---|---|
| **Extract Sequence…** | Send the sequence to a new [reference bundle](../../GLOSSARY.md#reference-bundle), a package for reference sequences, or to a FASTA file, the clipboard, or the Mac's sharing menu |
| **Verify with BLAST…** | Check the match with a fresh search |
| **Copy FASTA** | Copy the sequence in FASTA format |
| **Export FASTA…** | Save the sequence as a FASTA file |
| **Extract to New Bundle…** | Make a reference bundle from the sequence |
| **Run Operation…** | Run an operation that accepts FASTA |

The menu ends with **Copy Name**, **Copy Accession**, **Open on NCBI** for the matched record, and **Search PubMed** for published research about the organism.

## What good looks like

Apply the [read classification evidence checklist](01-what-is-classification.md#the-evidence-checklist) to each contig before reporting a match.

1. Check **Samples** against the number of samples you submitted for the run. If an expected sample is missing, check whether the table has any rows for it. **Hits** should equal or exceed **Contigs** because each reported contig has at least one hit.

2. Start with the longest contigs. Compare **Length** with **Aln Length** to see how much of the contig a match covers. Look more closely if the match covers only part of the contig or its percent identity sits well below the identity that isolates of the named virus show with one another.

3. If the contig has multiple matches, expand it and compare bit scores across organism names. A clear score gap favors the higher match among the records searched. If matches for different organisms score within a few percent of each other, compare how much of the contig each match covers and report uncertainty if the evidence leaves the names unresolved. SampleA's HIV-1 contig has scores of 750, 720, 700, 680, and 660, all naming HIV-1. Databases often hold many isolates of a common virus, so seeing one name throughout the list is common and a nearly equal match to another organism can still fall outside it.

4. Check Mapped Reads. A contig with little read support may be an assembly artifact, a sequence created by an error when joining reads. If you have the sample's BAM file, compare Unique Reads with Mapped Reads. The counts can differ because they use different rules. Check the [pileup](../../GLOSSARY.md#pileup), the stack of reads at each position, in **Contig Alignment**. Reads spread across the contig can support the assembly. If reads cover only a short stretch, inspect the rest of the contig more closely.

If your lab ran controls, samples used for comparison, check them before reporting a match. A negative control omits the material you want to detect. A similar signal in a negative control can suggest contamination.

The import's [provenance](../../GLOSSARY.md#provenance) record documents where the result came from. It includes a [checksum](../../GLOSSARY.md#checksum), a short fingerprint of the imported table's contents. Use the steps in [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) to check which table was imported.

## On the command line

A variable is a name that holds a value. The first two lines store the paths to the project and run folders in `PROJECT` and `RUN`. See [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) for how to enter the commands. The CLI Reference lists the flags for [`nvd summary`](../appendices/cli-reference.md#nvd-summary), [`import nvd`](../appendices/cli-reference.md#import-nvd), and [`extract reads`](../appendices/cli-reference.md#extract-reads). For the demo, stop after `lungfish-cli import nvd`. The extraction command needs the sample's BAM file and returns an error on the demo.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"
RUN="$PROJECT/Practice Data/nvd-demo/results"

lungfish-cli nvd summary "$RUN" --top 20

lungfish-cli import nvd "$RUN" --output-dir "$PROJECT/Analyses"

lungfish-cli extract reads --by-classifier --tool nvd \
  --result "$PROJECT/Analyses/nvd-100" \
  --sample SampleA --accession NODE_1_length_500_cov_10.0 \
  --output sampleA-contig1.fastq
```

`nvd summary` previews the experiment, the three counts, and the best matches. `--top` sets how many contigs to list, so 20 shows all four demo contigs. `import nvd` saves to the [working directory](../../GLOSSARY.md#working-directory), the folder the terminal is using, unless you set `--output-dir`. Use the project's `Analyses` folder to match the Import Center. With `extract reads`, `--by-classifier` uses a classifier's result, and for NVD, `--accession` takes the contig name.

## Next

Continue to [When to Assemble](../07-assembly/01-when-to-assemble.md) to learn when to build contigs from your own reads.
