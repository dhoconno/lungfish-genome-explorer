---
title: Novel Virus Diagnostics
chapter_id: 06-classification/09-novel-virus-detection
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 16
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
    caption: "The Import Center on its Classification Results tab with the NVD Results card, whose file hint reads NVD run folder containing *_blast_concatenated.csv(.gz)."
  - id: nvd-import-preview
    caption: "The NVD Import sheet after a successful scan of the NVD demo results, showing the Browse… button, the path readout, and the Preview panel's Experiment, Samples, Contigs, and BLAST hits rows."
  - id: nvd-result-viewport
    caption: "The NVD viewport on the demo results, showing the four summary cards, the By Sample and By Taxon grouping control, the Search contigs… field, a contig row expanded to its lower-ranked hits with a dash in its Unique Reads column, the detail pane alongside, and the action bar with Verify with BLAST…, Export, Extract Reads…, and BLAST Results."
  - id: nvd-column-menu
    caption: "The right-click menu on the contig outline's column header, showing the Standard Columns checklist and Reset Column Widths."
  - id: nvd-blast-drawer
    caption: "The BLAST Results drawer open across the bottom of the NVD viewport below the outline and above the action bar, with the Verify with BLAST… button in the action bar at lower left."
illustrations:
  - id: contig-alignment-length
    brief: "One horizontal bar standing for a contig, labeled with its length, with the stretch BLAST aligned shaded in Creamsicle and the unaligned remainder left in Warm Grey outline. Draw two versions stacked. The upper is the demo's NODE_1_length_500_cov_10.0, 500 bases long with 498 aligned, almost entirely shaded and labeled 'known virus'. The lower is a 5,000-base contig with only 400 bases shaded near one end, labeled 'most of the contig matches nothing the database knows'. Under each bar print Length and Aln Length as the NVD table names them. Deep Ink labels, Cream background."
glossary_refs: [nvd, contig, blast, e-value, percent-identity, bit-score, accession, taxon, read, fastq, bam, bundle, provenance, checksum, reads-per-billion, inspector, operations-panel, pileup, unique-reads, primary-alignment, mate, viewport, tsv, relative-abundance, fasta, csv, secondary-alignment, working-directory, sample-metadata, pipeline, mapper, command-line-flag]
features_refs: [import.nvd]
fixtures_refs: [nvd-demo]
brand_reviewed: false
lead_approved: false
---

## What it is

A read classifier and [Novel Virus Diagnostics](../../GLOSSARY.md#nvd), abbreviated NVD, both ask what organisms a sample contains, but they go about it differently. A [read](../../GLOSSARY.md#read) is the record a sequencer writes for one DNA fragment, and Illumina reads are usually 75 to 300 bases. A read classifier asks which organism each read came from, one read at a time. NVD first stitches the reads into [contigs](../../GLOSSARY.md#contig), long continuous stretches of sequence assembled from many overlapping reads. It then searches each contig against the nucleotide collection of the National Center for Biotechnology Information (NCBI) with [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search program.

That extra length makes the evidence stronger. A chance resemblance between two sequences gets rapidly less likely as the matching stretch grows, so a match across thousands of bases of contig is far harder to explain away than a match on one 150-base read.

This is what makes NVD a discovery tool. When a read classifier meets a virus nobody has deposited in a database yet, it either names the nearest relative with more confidence than the evidence supports, or reports nothing. A long contig that matches a known virus across only part of its length, or at low [percent identity](../../GLOSSARY.md#percent-identity), is a visible signal, and that signal is what a search for new viruses looks for.

Lungfish Genome Explorer (LGE) does not run NVD. NVD is an external [pipeline](../../GLOSSARY.md#pipeline), a chain of programs that hand their output to each other, usually run on a computing cluster, and its finished results reach you as a folder of files. It was built for wastewater viral surveillance, the practice of sequencing sewage to watch which viruses circulate in a community. LGE imports the pipeline's output and opens it in a [viewport](../../GLOSSARY.md#viewport), the main area of the window, where each contig is a row with its ranked BLAST matches underneath.

The importer needs one file, named `*_blast_concatenated.csv` (or `.csv.gz` when shrunk with the gzip compression format), where the asterisk stands for the run's own prefix. It sits in the run's final stage folder, `05_labkey_bundling/`. The earlier stage folders do not need to be present. When `02_human_viruses/03_human_virus_results/` exists, the importer also copies each sample's [BAM](../../GLOSSARY.md#bam) files, the alignment files that record which reads map to which contig, and its contig [FASTA](../../GLOSSARY.md#fasta) files, plain-text files of named sequences, into the result.

## Why you would do this

A finished NVD run is one large [CSV](../../GLOSSARY.md#csv) table, a plain-text table with commas between the fields. Several rows describe the same contig, and each row is one BLAST match for it. LGE ranks a contig's rows by [e-value](../../GLOSSARY.md#e-value), how many matches this good or better would turn up by chance alone, so lower is better. It breaks a tie with the higher [bit score](../../GLOSSARY.md#bit-score), a strength-of-alignment number, and calls the first row the contig's best match. Judging a match usually means comparing the best match against the second-best, which an ungrouped spreadsheet hides.

This chapter works through the NVD demo results, a small synthetic run holding 10 BLAST hit rows across 3 samples and 4 contigs. It is small enough to check every number by hand.

## Before you start

Open a project so LGE has somewhere to save the result. With no project open, the NVD import shows the alert No Project Open and imports nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

The simplest way to get the demo results is the Pathogen Detection demo project. Choose **Help > Demo Projects…** and download Pathogen Detection, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Its `Practice Data/nvd-demo/results` folder holds the demo results, and importing that folder is this chapter's procedure.

This chapter uses the NVD demo results fixture, which holds the same results files and is also on GitHub at [docs/user-manual/fixtures/nvd-demo](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.70/docs/user-manual/fixtures/nvd-demo). [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to download it from there. Either way, the folder you point the importer at is `nvd-demo/results`.

```text
nvd-demo/
  README.md
  results/
    02_human_viruses/
      03_human_virus_results/
        SampleA.human_virus.fasta
        SampleB.human_virus.fasta
        SampleC.human_virus.fasta
    05_labkey_bundling/
      demo_blast_concatenated.csv
  scripts/
    make-contig-fastas.py
```

A full run holds more than the table, and each extra file switches on a feature.

| What LGE looks for | Where it sits in the run folder | What it switches on |
|---|---|---|
| One contig FASTA file per sample, named `<sample>.human_virus.fasta` | `02_human_viruses/03_human_virus_results/` | **Verify with BLAST…** and the other commands that use a contig's own sequence |
| One BAM file per sample, with the sample name in its file name | `02_human_viruses/03_human_virus_results/mapped_reads/` | Unique Reads, the reads in **Contig Alignment**, and **Extract Reads…** |

The demo results hold the table and simulated contig FASTA files, so verification works on them. They hold no BAM files, so extracting the reads behind a contig cannot be performed on them, and that step is described here for use on a full run.

No plugin pack is needed, and the demo import takes well under a second.

## Procedure

### Open the importer

Choose **File > Import Center…** (Cmd-Shift-I), click the **Classification Results** tab, and find the **NVD Results** card. Its file hint reads "NVD run folder containing *_blast_concatenated.csv(.gz)".

<!-- SHOT: nvd-import-card -->

Click the card. A sheet titled **NVD Import** opens. It scans the run and reports what it found before anything is written.

### Point it at the run and read the preview

Click **Browse…** and select the run folder, `nvd-demo/results` for the fixture. The hint under the path readout says "Select the top-level NVD run directory (containing 05_labkey_bundling/).", so pick the folder above `05_labkey_bundling/`, not that folder or the CSV inside it.

The **Preview** panel then lists **Experiment**, **Samples**, **Contigs**, and **BLAST hits**, plus a **Total BAM size** row when the run ships alignment files. For the demo results it reads experiment `100`, 3 samples, 4 contigs, and 10 BLAST hits. The experiment identifier is a label the pipeline operator gave the run, not a count. If the scan cannot find the table, the panel shows a warning instead, which usually means you picked a subfolder.

<!-- SHOT: nvd-import-preview -->

### Import and open the result

Click **Run**. The button stays off until a folder is selected and the scan has finished without error. LGE runs `lungfish-cli import nvd` in the background on an [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) row titled "NVD Import". The Operations Panel lists running and finished tasks and opens with **Operations > Show Operations Panel** (Cmd-Shift-P). **Copy CLI Command** on the row copies the command, and **Cancel** stops the import.

The result folder is named after the experiment identifier, so the demo results import as `nvd-100`. The Import Center writes it into the project's `Analyses` folder. When the Operations Panel row finishes, the **Analyses** group at the top of the sidebar lists `nvd-100` with its date underneath. Click it to open the NVD viewport.

<!-- SHOT: nvd-result-viewport -->

### Walk the viewport

Four summary cards run across the top, labeled **Experiment**, **Samples**, **Contigs**, and **Hits**. For the demo results they repeat the preview's numbers.

Below the cards sit a detail pane and an outline of contigs, an outline being a table whose rows open to show further rows nested underneath.

Each top-level row is one contig showing its best BLAST match. Click the small triangle beside a contig's name to open all of that contig's ranked matches, best e-value first, starting again with the best match as Hit #1. In the demo results, contig `NODE_2_length_300_cov_5.0` in SampleA opens to five HIV-1 matches, and `NODE_1_length_500_cov_10.0` opens to three SARS-CoV-2 matches. A contig name carries the labels of the assembler, the program that joined reads into contigs. `NODE_2` numbers the contig, `length_300` gives its length in bases, and `cov_5.0` gives the average read depth, meaning how many reads cover each base. The outline and detail pane show a contig as `NODE_2 (300 bp)`, and search still matches the full name.

Click a contig row to fill the detail pane. It shows the contig name, the sample, the organism with its rank, and six small badges labeled Identity, E-value, Bit Score, Mapped Reads, RPB, and Length. Below them a **Contig Alignment** section names the best hit and shows the reads that built the contig, stacked at the positions where they matched. Without an alignment file the section shows the heading and the best hit above an empty read view, as it does for the demo results.

### Verify a contig with BLAST

This step uses the sample's contig FASTA file, which a full NVD run writes. The demo results include simulated contig FASTA files, so the step works on them too. All of them are cut from the SARS-CoV-2 reference, so SampleA's SARS-CoV-2 contig `NODE_1_length_500_cov_10.0` is the fair test.

Select exactly one contig row, or one lower-ranked match under a contig, and click **Verify with BLAST…** in the action bar at the bottom of the window. The button stays grayed otherwise, and its tooltip, the note shown when you point at it, gives the reason, as [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes. In the By Taxon arrangement a heading names a [taxon](../../GLOSSARY.md#taxon), a named group of organisms, and is not a hit, so it leaves the button grayed too.

LGE submits the contig's own sequence to NCBI after a sheet titled Run BLAST at NCBI? asks you to confirm. NVD already ran BLAST on every contig, so this is a second look, made fresh at NCBI and judged against the taxon in the **Classification** cell of the row you selected, as [Verify from another classifier viewport](06-blast-verification.md#verify-from-another-classifier-viewport) describes. A lower-ranked match that names a different organism from Hit #1 therefore tests that name instead. Results arrive in the **BLAST Results** drawer across the bottom of the window, and because a contig is one sequence, the verdict rests on that single search, as [The summary bar and the verdict](06-blast-verification.md#the-summary-bar-and-the-verdict) explains.

<!-- SHOT: nvd-blast-drawer -->

## Settings

The import sheet has no settings. It holds a **Browse…** button, a read-only path readout, the Preview panel, and **Cancel** and **Run**, and none of them changes how the import runs. The command-line import has two [flags](../../GLOSSARY.md#command-line-flag) of its own, options typed after the command with two leading hyphens, `--name` and `--output-dir`, which [`import nvd`](../appendices/cli-reference.md#import-nvd) in the CLI Reference lists.

The result window has three display controls in the filter bar above the outline. They change what the window shows, not what the import produced. Two of them have a matching flag on `lungfish-cli nvd export contigs`.

**By Sample / By Taxon.** Switches the outline between two arrangements of the same contigs. The default is By Sample, which gives one row per contig without grouping by organism and suits walking one run in order. Switch to By Taxon to collect every contig whose best match names the same organism under one heading. This setting has no command-line flag.

**All Samples.** Opens a popover, a small panel beside the button, for narrowing the outline to a chosen subset of the run's samples. The default is every sample, and the button relabels itself to report the state, for example "2 of 3 Samples". Narrow it when a run holds many samples and you want to read one at a time. On the command line this is `--sample`, which you repeat to keep several samples.

**Search contigs….** Filters the outline to contigs whose organism name, subject title, accession, or contig name contains what you type. The default is empty, which lists every contig in the selected samples. It searches best matches only, so a term that appears only in a lower-ranked match will not bring its contig into view. On the command line this is `--search`.

## Reading the results

The outline carries fourteen columns. Six of them also appear as badges in the detail pane, marked below. Mapped Reads and Unique Reads count reads, and each mate of a read pair counts as one read. The two [mates](../../GLOSSARY.md#mate) are the two reads of one fragment.

| Column | What it holds |
|---|---|
| Sample | The library the contig was assembled from |
| Contig | The contig's number and length, shortened to a form such as `NODE_2 (300 bp)`. **Copy Name** and the export give the assembler's full name |
| Length | The contig's length in bases (badge) |
| Classification | The organism the pipeline settled on |
| Rank | The taxonomic level of that name |
| Accession | The database record the contig matched |
| Subject | The full title of that record |
| Identity % | Share of aligned bases that agree (badge) |
| E-value | How many matches this good or better would turn up by chance alone (badge) |
| Bit Score | Strength of the alignment, independent of database size (badge) |
| Mapped Reads | Reads that mapped back to this contig, as the pipeline counted them (badge) |
| Unique Reads | Reads in the sample's alignment file whose primary alignment is on this contig, after duplicates are set aside, or a dash when LGE could not count them |
| RPB | Reads per billion, an abundance figure (badge) |
| Aln Length | Length of the region BLAST aligned |

Contigs are listed longest first, and clicking a header does not re-sort them. You can drag headers to reorder columns and drag the dividers to resize them. Right-click any header for a menu with a **Standard Columns** checklist, **Reset Column Widths**, and, once you attach [sample metadata](../../GLOSSARY.md#sample-metadata) such as collection dates, a **Sample Metadata** section for showing those columns.

<!-- SHOT: nvd-column-menu -->

<!-- ILLUSTRATION: contig-alignment-length -->

**Length and Aln Length.** Read these two together, because the gap between them is the part of the contig that matched nothing. In the demo results `NODE_1_length_500_cov_10.0` is 500 bases long and aligns over 498 of them. A 5,000-base contig aligning over only 400 would say that most of the contig is sequence the database does not know. As a working line, a match covering less than half of a long contig is worth expanding and sending to **Verify with BLAST…**.

**Identity %, E-value, and Bit Score.** These are BLAST's standard measures of a match, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read each one. For NVD, a best hit near 100 percent identity is a known virus, and a best hit below about 90 percent is the case the pipeline exists to find. The demo best matches run 99.5, 96.0, 99.0, and 97.5 percent, none of them below that 90 percent line. An e-value shown as `0` means a number too small for BLAST to print, not zero.

**Mapped Reads and Unique Reads.** Mapped Reads is how many reads mapped back to this contig, as the NVD pipeline reported it, the sequencing evidence behind the contig. [Unique Reads](../../GLOSSARY.md#unique-reads) is LGE's own count from the run's alignment files. At import, LGE first marks duplicates, which are reads that start and end at the same place on the same strand. It then counts the reads on this contig and leaves out the duplicates and any extra placement of a read that the [mapper](../../GLOSSARY.md#mapper), the program that places reads on contigs, also reported, such as a [secondary alignment](../../GLOSSARY.md#secondary-alignment). So each read counts once, at its [primary alignment](../../GLOSSARY.md#primary-alignment), the one placement the mapper marks as the read's real position. Without alignment files LGE cannot count, and the column shows a dash, as it does on every row of the demo results.

**RPB.** [Reads per billion](../../GLOSSARY.md#reads-per-billion) is the mapped-read count divided by the sample's total read count and multiplied by a billion. It puts contigs from libraries of different sizes on one scale. The sample's total read count comes from the `total_reads` column of the pipeline's table, which the window does not show, so open `demo_blast_concatenated.csv` in a spreadsheet to check the sums. SampleA's SARS-CoV-2 contig has 50 mapped reads out of 1,000,000, an RPB of 50,000. SampleB's herpesvirus contig has 100 out of 2,000,000, also an RPB of 50,000, so the two are equally abundant in their own samples although one has twice the reads. RPB has no fixed good value, so compare contigs within one run.

**Classification and Rank.** These are the organism the pipeline settled on and the [taxonomic](../../GLOSSARY.md#taxon) level of its name. A broad rank, such as a genus or family where you might expect a species, means the pipeline would not be more specific than the evidence allowed, so report the identification at that rank.

**Accession and Subject.** These identify the matched record by its [accession](../../GLOSSARY.md#accession) and its full title.

### The action bar and the row menu

The action bar is the one every classifier viewport shares, with **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**, and [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each control. In the NVD viewport:

- **Export** opens a save sheet titled Export NVD Contigs, with `<experiment>_nvd_contigs.tsv` as the default file name, and runs `lungfish-cli nvd export contigs` on an Operations Panel row. It writes the best match of each contig in the selected samples as a [tab-separated](../../GLOSSARY.md#tsv) file with all fourteen columns in the table's default order, except that Aln Length comes right after Identity % instead of last, and leaves the cell empty where the table shows a dash.
- **Export** stays grayed until the result has opened and at least one sample is checked in the **All Samples** popover. Every sample starts checked, so its tooltip, "Pick a sample to export.", appears only after you clear them all.
- **Extract Reads…** writes the reads behind the selected rows as a new [FASTQ](../../GLOSSARY.md#fastq) [bundle](../../GLOSSARY.md#bundle), each read once, using the dialog that [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) describes. It needs the run's BAM files.

The information button at the right of the bar opens a popover headed **NVD Pipeline Info**, listing the experiment, import date, format version, sample, contig, and hit counts, the BLAST database version when the run recorded one, and the source directory. Sample metadata is attached in the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window. Open **Samples & Metadata** and click **Import Metadata…**, which shows while the result has no metadata.

Right-click a contig row for **Extract Reads…**, then six commands on the contig's own sequence, which stay grayed when LGE cannot read it from the sample's FASTA file. **Extract Sequence…** opens a dialog that sends it to a new reference bundle, a FASTA file, the clipboard, or the Mac's sharing menu. **Verify with BLAST…** is the search described above. **Copy FASTA** copies it at once, **Export FASTA…** saves it as a file, **Extract to New Bundle…** makes a reference bundle from it, and **Run Operation…** runs an operation that accepts a FASTA file on it. The menu ends with **Copy Name**, **Copy Accession**, **Open on NCBI**, which opens the record, and **Search PubMed**, which searches the literature for the organism.

## What good looks like

The NVD viewport answers the questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) at the level of contigs. Controls are yours to add.

First, check the summary cards. Samples should match the number of libraries that went into the run. Hits can never be lower than Contigs, since every contig carries at least one match.

Second, read the long contigs first. Compare Length with Aln Length and look at Identity %. A long contig matching near 100 percent across nearly its whole length is routine and says the sample holds a known virus. A long contig matched over only part of its length, or below about 90 percent identity, is the candidate to expand next.

Third, expand the row and compare bit scores, but only among matches that name different organisms. If the top match stands far above every match naming another organism, the call is clean. If matches naming different organisms score within a few percent of each other, the call is ambiguous and should not be reported as one identification. SampleA's HIV-1 contig has five matches scoring 750, 720, 700, 680, and 660, but all five name HIV-1, so the spread among them does not matter.

Fourth, check Mapped Reads before you believe a contig at all. A contig built from very few reads may be an assembly artifact, and no BLAST number can tell you so. On a full run, compare Unique Reads with Mapped Reads too, since a contig whose reads are mostly duplicates rests on few original fragments. These checks need a full run. Open the Contig Alignment section and look at the [pileup](../../GLOSSARY.md#pileup), the stack of reads over each position. Reads spread evenly along the whole contig at a steady depth support it. Reads covering only a short stretch point to an artifact.

The import's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, holds a [checksum](../../GLOSSARY.md#checksum), a short fingerprint, of the table it read, so a later reader can confirm which run the result came from.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of the import is listed in [`import nvd`](../appendices/cli-reference.md#import-nvd) in the CLI Reference. The third command needs the run's BAM files, so it works only on a full run and stops with an error on the demo results.

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

The second line stores the run folder in a variable named `RUN`, in the same way as `PROJECT`. [`nvd summary`](../appendices/cli-reference.md#nvd-summary) prints the experiment, the three counts, and each contig's best hit without importing anything, and `--top` sets how many contigs it lists, so 20 lists all four demo contigs. `import nvd` writes into the [working directory](../../GLOSSARY.md#working-directory), the folder you typed the command from, unless `--output-dir` names one, so point it at the project's `Analyses` folder to match the Import Center. In [`extract reads`](../appendices/cli-reference.md#extract-reads), `--by-classifier` takes the reads from a classifier's result, and for NVD the `--accession` takes the contig name.

## Next

This is the last chapter of the Classification part. Continue to [When to Assemble](../07-assembly/01-when-to-assemble.md), which opens the Assembly part and shows how to build contigs like NVD's from your own reads, the step that turns a read classifier's hint about an unknown virus into a sequence you can study.
