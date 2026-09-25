---
title: Novel Virus Diagnostics
chapter_id: 06-classification/09-novel-virus-detection
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 15
task: Import Novel Virus Diagnostics (NVD) pipeline results and read the contig-keyed BLAST viewport.
tags: [classification, nvd, novel-virus, blast, import, wastewater]
tools: [nvd]
parameters_refs: [import.nvd]
entry_points:
  - "File > Import Center... > Classification Results > NVD Results"
  - "CLI: lungfish-cli import nvd <input-path>"
  - "CLI: lungfish-cli nvd summary <input-path>"
shots:
  - id: nvd-import-card
    caption: "The Import Center on its Classification Results tab with the NVD Results card, whose file hint reads NVD run folder containing *_blast_concatenated.csv(.gz)."
  - id: nvd-import-preview
    caption: "The NVD Import sheet after a successful scan of the NVD demo results, showing the Browse... button, the path readout, and the Preview panel's Experiment, Samples, Contigs, and BLAST hits rows."
  - id: nvd-result-viewport
    caption: "The NVD viewport on the demo results, showing the four summary cards, the By Sample and By Taxon grouping control, the Search contigs... field, a contig row expanded to its secondary hits, and the detail pane alongside."
  - id: nvd-column-menu
    caption: "The right-click menu on the contig outline's column header, showing the Standard Columns checklist and Reset Column Widths."
  - id: nvd-blast-drawer
    caption: "The BLAST results drawer open across the bottom of the NVD viewport below the outline and above the action bar, with the BLAST Verify button in the action bar at lower left."
illustrations: []
glossary_refs: [nvd, contig, blast, e-value, percent-identity, bit-score, accession, taxon, read, fastq, bam, bundle, provenance, checksum, reads-per-billion, inspector, operations-panel, pileup]
features_refs: []
fixtures_refs: [nvd-demo]
brand_reviewed: false
lead_approved: false
---

## What it is

A read classifier and [Novel Virus Diagnostics](../../GLOSSARY.md#nvd), abbreviated NVD, both ask what organisms a sample contains, but they go about it differently. A [read](../../GLOSSARY.md#read) is one stretch of sequence the instrument produced, typically about 150 bases on an Illumina machine. A read classifier asks which organism each read came from, one read at a time. NVD first stitches the reads into [contigs](../../GLOSSARY.md#contig), long continuous stretches of sequence assembled from many overlapping reads. It then searches each contig against NCBI's nucleotide collection with [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search program.

That extra length makes the evidence stronger. A chance resemblance between two sequences gets rapidly less likely as the matching stretch grows, so a match across thousands of bases of contig is far harder to explain away than a match on one 150-base read.

This is what makes NVD a discovery tool. When a read classifier meets a virus nobody has deposited in a database yet, it either names the nearest relative with more confidence than the evidence supports, or reports nothing. A long contig that matches a known virus across only part of its length, or at low [percent identity](../../GLOSSARY.md#percent-identity), is a visible signal, and that signal is what a search for new viruses looks for.

Lungfish Genome Explorer (LGE) does not run NVD. NVD is an external pipeline, usually run on a computing cluster, and its finished results reach you as a folder of files. It was built for wastewater viral surveillance, the practice of sequencing sewage to watch which viruses circulate in a community, so this chapter's examples are viral throughout. LGE imports the pipeline's output and opens it as a window where each contig is a row with its ranked BLAST matches underneath.

The importer reads one file, named `*_blast_concatenated.csv` (or `.csv.gz` when shrunk with the gzip compression format), where the asterisk stands for the run's own prefix. It sits in the run's final stage folder, `05_labkey_bundling/`. The earlier stage folders do not need to be present.

## Why you would do this

A finished NVD run is one large CSV table, a plain-text table with commas between the fields. Several rows describe the same contig. Each row is one ranked match for that contig, and only the first is the pipeline's best guess. Judging a match usually means comparing the best match against the second-best, which an ungrouped spreadsheet hides.

Importing groups the rows back into contigs and keeps the ranked alternatives one click away. It also records where the file came from. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

This chapter works through the NVD demo results, a small synthetic run holding 10 BLAST hit rows across 3 samples and 4 contigs. It is small enough to check every number by hand.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds the demo results under `Practice Data/nvd-demo/results`. Importing that folder is this chapter's procedure, so point the importer at it, or download it as described next.

This chapter uses the NVD demo results fixture. Download the `nvd-demo` folder from [docs/user-manual/fixtures/nvd-demo](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/nvd-demo), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The folder you point the importer at is `nvd-demo/results`.

```text
nvd-demo/
  README.md
  results/
    05_labkey_bundling/
      demo_blast_concatenated.csv
```

Two steps cannot be performed on the demo results, because the fixture ships the BLAST table alone. Verifying a contig with BLAST needs the contig's own sequence, which a full run supplies as a FASTA file per sample. Extracting the reads behind a contig needs the [BAM](../../GLOSSARY.md#bam) files a full run produces, where each BAM records which reads built which contig. Both steps are described here for use on a full run.

No plugin pack is needed, and the demo import takes well under a second.

## Procedure

### 1. Open the importer

Choose **File > Import Center...** (Cmd-Shift-I), click the **Classification Results** tab, and find the **NVD Results** card. Its file hint reads "NVD run folder containing *_blast_concatenated.csv(.gz)".

<!-- SHOT: nvd-import-card -->

Click the card. A sheet titled **NVD Import** opens. It scans the run and reports what it found before anything is written.

### 2. Point it at the run and read the preview

Click **Browse...** and select the run directory, `nvd-demo/results` for the fixture. The hint under the path readout says "Select the top-level NVD run directory (containing 05_labkey_bundling/)", so pick the folder above `05_labkey_bundling/`, not that folder or the CSV inside it.

The **Preview** panel then lists **Experiment**, **Samples**, **Contigs**, and **BLAST hits**, plus a **Total BAM size** row when the run ships alignment files. For the demo results it reads experiment `100`, 3 samples, 4 contigs, and 10 BLAST hits. The experiment identifier is a label the pipeline operator gave the run, not a count. If the scan cannot find the table, the panel shows a warning instead, which usually means you picked a subfolder.

<!-- SHOT: nvd-import-preview -->

### 3. Import and open the result

Click **Run**. The button stays disabled until a folder is selected and the scan has finished without error. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled "NVD Import".

The result folder is named after the experiment identifier, so the demo results import as `nvd-100`. The Import Center writes it into the project's `Imports` folder. Classifiers you run inside LGE write under `Analyses` instead, so an imported NVD result and a Kraken 2 run sit in different folders. Double-click `nvd-100` in the sidebar to open the NVD viewport.

<!-- SHOT: nvd-result-viewport -->

### 4. Walk the viewport

Four summary cards run across the top, labelled **Experiment**, **Samples**, **Contigs**, and **Hits**. For the demo results they read `100`, `3 samples`, `4 contigs`, and `10 hits`, the same numbers the preview showed.

Below the cards sit a detail pane and an outline of contigs, an outline being a table whose rows open to show further rows nested underneath. A filter bar above the outline holds the grouping control, the sample filter, and the search field, which Settings describes.

Each top-level row is one contig showing its best BLAST match. Click the disclosure triangle on a row to open all of that contig's ranked matches, best e-value first (a lower e-value means a match less likely to be chance), starting again with the best match as Hit #1. In the demo results, contig `NODE_2_length_300_cov_5.0` in SampleA opens to five HIV-1 matches, and `NODE_1_length_500_cov_10.0` opens to three SARS-CoV-2 matches. A contig name carries the labels of the assembler, the program that joined reads into contigs. `NODE_2` numbers the contig, `length_300` gives its length in bases, and `cov_5.0` gives the average read depth, meaning how many reads cover each base.

Click a contig row to fill the detail pane. It shows the contig name, the sample, the organism with its rank, and six small badges labelled Identity, E-value, Bit Score, Mapped Reads, RPB, and Length. Below them a **Contig Alignment** section names the best hit and shows the reads that built the contig, stacked at the positions where they matched. Without an alignment file the section shows the heading and the best hit above an empty read view, as it does for the demo results.

### 5. Verify a contig with BLAST

This step needs a full NVD run, because it uses the sample's contig FASTA file.

Select exactly one contig row, or one lower-ranked match under a contig, and click **BLAST Verify** in the action bar at the bottom of the window. The button stays disabled otherwise, and its tooltip reads "Select a row to use BLAST Verify" when nothing is selected and "Select a single row to use BLAST Verify" when several rows are. A taxon group heading in the By Taxon arrangement is not a hit, so it leaves the button disabled too. The right-click menu names the same action **Verify with BLAST…**.

LGE submits the contig's own sequence to NCBI. Results arrive in a drawer across the bottom of the window, whose top edge you can drag to resize it. [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage in what comes back.

<!-- SHOT: nvd-blast-drawer -->

## Settings

The import sheet has no settings. It holds a **Browse...** button, a read-only path readout, the Preview panel, and **Cancel** and **Run**, and none of them changes the import. The command-line import has two options of its own, `--name` and `--output-dir`, which the [CLI Reference](../appendices/cli-reference.md) lists.

The result window has three display controls. They change what the window shows, not what the import produced.

**By Sample / By Taxon.** Switches the outline between two arrangements of the same contigs. The default is By Sample, which gives one row per contig without grouping by organism and suits walking one run in order. Switch to By Taxon to collect every contig whose best match names the same organism under one heading. This setting has no command-line flag.

**All Samples.** Opens a popover for narrowing the outline to a chosen subset of the run's samples. The default is every sample, and the button relabels itself to report the state, for example "2 of 3 Samples". Narrow it when a run holds many samples and you want to read one at a time. This setting has no command-line flag.

**Search contigs….** Filters the outline to contigs whose organism name, subject title, accession, or contig name contains what you type. The default is empty, which lists every contig in the selected samples. It searches best matches only, so a term that appears only in a lower-ranked match will not bring its contig into view. This setting has no command-line flag.

## Reading the results

The outline carries fourteen columns. Six of them also appear as badges in the detail pane, marked below.

| Column | What it holds |
|---|---|
| Sample | The library the contig was assembled from |
| Contig | The assembler's name for the contig |
| Length | The contig's length in bases (badge) |
| Classification | The organism the pipeline settled on |
| Rank | The taxonomic level of that name |
| Accession | The database record the contig matched |
| Subject | The full title of that record |
| Identity % | Share of aligned bases that agree (badge) |
| E-value | How many matches this good chance alone would produce (badge) |
| Bit Score | Strength of the alignment, independent of database size (badge) |
| Mapped Reads | Reads that mapped back to this contig (badge) |
| Unique Reads | Of those, the reads that mapped nowhere else |
| RPB | Reads per billion, an abundance figure (badge) |
| Aln Length | Length of the region BLAST aligned |

Contigs are listed longest first, and clicking a header does not re-sort them. You can drag headers to reorder columns and drag the dividers to resize them. Right-click any header for a menu with a **Standard Columns** checklist, **Reset Column Widths**, and, when sample metadata is attached, a **Sample Metadata** section for showing metadata columns.

<!-- SHOT: nvd-column-menu -->

**Length and Aln Length.** Read these two together, because the gap between them is the part of the contig that matched nothing. In the demo results `NODE_1_length_500_cov_10.0` is 500 bases long and aligns over 498 of them. A 5,000-base contig aligning over only 400 would say that most of the contig is sequence the database does not know. As a working line, a match covering less than half of a long contig is worth chasing.

**Identity %, E-value, and Bit Score.** These are BLAST's standard measures of a match, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read each one. For NVD, a best hit near 100 percent identity is a known virus, and a best hit below about 90 percent is the case the pipeline exists to find. The demo best matches run 99.5, 96.0, 99.0, and 97.5 percent, all known-virus territory. An e-value shown as `0` means a number too small for BLAST to print, not zero. Bit scores compare one contig's own matches, which is the check [What good looks like](#what-good-looks-like) uses.

**Mapped Reads and Unique Reads.** Mapped Reads is how many reads mapped back to this contig, the sequencing evidence behind it. Unique Reads is the subset that mapped to this contig and nowhere else. When the pipeline reports no separate figure, Unique Reads shows 1 as a placeholder rather than a count, as it does on every row of the demo results, so ignore the column there.

**RPB.** [Reads per billion](../../GLOSSARY.md#reads-per-billion) is the mapped-read count divided by the sample's total read count and multiplied by a billion. It puts contigs from libraries of different sizes on one scale. The sample's total read count comes from the pipeline's table and is not shown in the window. SampleA's SARS-CoV-2 contig has 50 mapped reads out of 1,000,000, an RPB of 50,000. SampleB's herpesvirus contig has 100 out of 2,000,000, also an RPB of 50,000, so the two are equally abundant in their own samples although one has twice the reads. RPB has no fixed good value, so compare contigs within one run.

**Classification and Rank.** These are the organism the pipeline settled on and the [taxonomic](../../GLOSSARY.md#taxon) level of its name. A broad rank, such as a genus or family where you might expect a species, means the pipeline would not be more specific than the evidence allowed, so report the identification at that rank.

**Accession and Subject.** These identify the matched record by its [accession](../../GLOSSARY.md#accession) and its full title. Right-click a row and choose **View Accession on NCBI** to open the record, or **Search PubMed** to search the literature for the organism.

The same right-click menu extracts the contig's reads or sequence, copies its name, accession, or FASTA text, or hands the sequence to another operation. The action bar holds **BLAST Verify**, **Extract FASTQ**, **Export**, and an information button. **Export** writes the displayed rows as a tab-separated file with twelve of the fourteen columns, leaving out Unique Reads and Aln Length. The information button opens a popover headed **NVD Pipeline Info**, listing the experiment, import date, format version, sample, contig, and hit counts, the BLAST database version when the run recorded one, and the source directory. Sample metadata is attached through the [Inspector](../../GLOSSARY.md#inspector), in the way [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

## What good looks like

First, check the summary cards. Samples should match the number of libraries that went into the run. Hits can never be lower than Contigs, since every contig carries at least one match.

Second, read the long contigs first. Compare Length with Aln Length and look at Identity %. A long contig matching near 100 percent across nearly its whole length is routine and says the sample holds a known virus. A long contig matched over only part of its length, or below about 90 percent identity, is the candidate to expand next.

Third, expand the row and compare bit scores, but only among matches that name different organisms. Close scores matter only when they point at different organisms. If the top match stands far above every match naming another organism, the call is clean. If matches naming different organisms score within a few percent of each other, the call is ambiguous and should not be reported as one identification. SampleA's HIV-1 contig shows close scores, stepping from 750 down to 660, but all five matches name HIV-1, so the call is safe.

Fourth, check Mapped Reads before you believe a contig at all. A contig built from very few reads may be an assembly artifact, and no BLAST number can tell you so. This check needs a full run, since the demo results carry no reads. Open the Contig Alignment section and look at the [pileup](../../GLOSSARY.md#pileup), the stack of reads over each position. Reads running the full length at a steady depth support the contig. Reads covering only a short stretch point to an artifact.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli nvd summary /path/to/nvd-demo/results --top 20

lungfish-cli import nvd /path/to/nvd-demo/results \
  --output-dir "/path/to/My Project.lungfish/Imports"

lungfish-cli extract reads --by-classifier --tool nvd \
  --result "/path/to/My Project.lungfish/Imports/nvd-100" \
  --sample SampleA --accession NODE_1_length_500_cov_10.0 \
  --output sampleA-contig1.fastq
```

Replace each `/path/to/` with the location of the file on your Mac. For NVD, `--accession` takes the contig name. `nvd summary` prints the experiment, the three counts, and each contig's best hit without importing anything. `import nvd` writes into the current folder unless `--output-dir` names one, so point it at the project's `Imports` folder to match the window. The extraction command reads the run's BAM files, so on the demo results it stops with an error and writes nothing.

## Next

Continue to [BLAST Verification](06-blast-verification.md) to read what a verification returns. For the other import-only classification paths, see [Importing CZ ID Results](08-importing-cz-id-results.md) and [Importing NAO-MGS Results](05-running-nao-mgs.md), or return to [What Is Read Classification](01-what-is-classification.md).
