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
glossary_refs: [nvd, contig, blast, e-value, percent-identity, bit-score, accession, taxon, read, fastq, bam, bundle, provenance, checksum, reads-per-billion, inspector, operations-panel, pileup, unique-reads, primary-alignment, mate, viewport, tsv, relative-abundance]
features_refs: [import.nvd]
fixtures_refs: [nvd-demo]
brand_reviewed: false
lead_approved: false
---

## What it is

A read classifier and [Novel Virus Diagnostics](../../GLOSSARY.md#nvd), abbreviated NVD, both ask what organisms a sample contains, but they go about it differently. A [read](../../GLOSSARY.md#read) is the record a sequencer writes for one DNA fragment, and Illumina reads are usually 75 to 300 bases. A read classifier asks which organism each read came from, one read at a time. NVD first stitches the reads into [contigs](../../GLOSSARY.md#contig), long continuous stretches of sequence assembled from many overlapping reads. It then searches each contig against NCBI's nucleotide collection with [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search program.

That extra length makes the evidence stronger. A chance resemblance between two sequences gets rapidly less likely as the matching stretch grows, so a match across thousands of bases of contig is far harder to explain away than a match on one 150-base read.

This is what makes NVD a discovery tool. When a read classifier meets a virus nobody has deposited in a database yet, it either names the nearest relative with more confidence than the evidence supports, or reports nothing. A long contig that matches a known virus across only part of its length, or at low [percent identity](../../GLOSSARY.md#percent-identity), is a visible signal, and that signal is what a search for new viruses looks for.

Lungfish Genome Explorer (LGE) does not run NVD. NVD is an external pipeline, usually run on a computing cluster, and its finished results reach you as a folder of files. It was built for wastewater viral surveillance, the practice of sequencing sewage to watch which viruses circulate in a community, so this chapter's examples are viral throughout. LGE imports the pipeline's output and opens it in a [viewport](../../GLOSSARY.md#viewport), the main area of the window, where each contig is a row with its ranked BLAST matches underneath.

The importer reads one file, named `*_blast_concatenated.csv` (or `.csv.gz` when shrunk with the gzip compression format), where the asterisk stands for the run's own prefix. It sits in the run's final stage folder, `05_labkey_bundling/`. The earlier stage folders do not need to be present.

## Why you would do this

A finished NVD run is one large CSV table, a plain-text table with commas between the fields. Several rows describe the same contig. Each row is one ranked match for that contig, and only the first is the pipeline's best guess. Judging a match usually means comparing the best match against the second-best, which an ungrouped spreadsheet hides.

Importing groups the rows back into contigs and keeps the ranked alternatives one click away. It also records where the file came from.

This chapter works through the NVD demo results, a small synthetic run holding 10 BLAST hit rows across 3 samples and 4 contigs. It is small enough to check every number by hand.

## Before you start

Open a project so LGE has somewhere to save the result. With no project open, the NVD import shows the alert No Project Open and imports nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds the demo results under `Practice Data/nvd-demo/results`. Importing that folder is this chapter's procedure, so point the importer at it, or download it as described next.

This chapter uses the NVD demo results fixture. Download the `nvd-demo` folder from [docs/user-manual/fixtures/nvd-demo](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/nvd-demo), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The folder you point the importer at is `nvd-demo/results`.

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

The result folder is named after the experiment identifier, so the demo results import as `nvd-100`. The Import Center writes it into the project's `Analyses` folder, beside the results of classifiers you run inside LGE, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Double-click `nvd-100` in the sidebar to open the NVD viewport.

<!-- SHOT: nvd-result-viewport -->

### Walk the viewport

Four summary cards run across the top, labeled **Experiment**, **Samples**, **Contigs**, and **Hits**. For the demo results they read `100`, `3 samples`, `4 contigs`, and `10 hits`, the same numbers the preview showed.

Below the cards sit a detail pane and an outline of contigs, an outline being a table whose rows open to show further rows nested underneath. A filter bar above the outline holds the grouping control, the sample filter, and the search field, which Settings describes.

Each top-level row is one contig showing its best BLAST match. Click the disclosure triangle on a row to open all of that contig's ranked matches, best e-value first (a lower e-value means a match less likely to be chance), starting again with the best match as Hit #1. In the demo results, contig `NODE_2_length_300_cov_5.0` in SampleA opens to five HIV-1 matches, and `NODE_1_length_500_cov_10.0` opens to three SARS-CoV-2 matches. A contig name carries the labels of the assembler, the program that joined reads into contigs. `NODE_2` numbers the contig, `length_300` gives its length in bases, and `cov_5.0` gives the average read depth, meaning how many reads cover each base.

Click a contig row to fill the detail pane. It shows the contig name, the sample, the organism with its rank, and six small badges labeled Identity, E-value, Bit Score, Mapped Reads, RPB, and Length. Below them a **Contig Alignment** section names the best hit and shows the reads that built the contig, stacked at the positions where they matched. Without an alignment file the section shows the heading and the best hit above an empty read view, as it does for the demo results.

### Verify a contig with BLAST

This step uses the sample's contig FASTA file, which a full NVD run writes. The demo results include simulated contig FASTAs, cut from the SARS-CoV-2 reference, so the step works on them too.

Select exactly one contig row, or one lower-ranked match under a contig, and click **Verify with BLAST…** in the action bar at the bottom of the window. The button stays grayed otherwise, and its tooltip gives the reason, as [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes. A taxon heading in the By Taxon arrangement is not a hit, so it leaves the button grayed too. The row's right-click menu offers the same **Verify with BLAST…**.

LGE submits the contig's own sequence to NCBI after a sheet titled Run BLAST at NCBI? asks you to confirm, and judges the contig against the taxon NVD named for it, as [Verify from another classifier viewport](06-blast-verification.md#verify-from-another-classifier-viewport) describes. Results arrive in the **BLAST Results** drawer across the bottom of the window, whose top edge you can drag to resize it. [Reading the results](06-blast-verification.md#reading-the-results) in the BLAST chapter explains percent identity, e-value, and query coverage in what comes back.

<!-- SHOT: nvd-blast-drawer -->

## Settings

The import sheet has no settings. It holds a **Browse…** button, a read-only path readout, the Preview panel, and **Cancel** and **Run**, and none of them changes the import. The command-line import has two options of its own, `--name` and `--output-dir`, which [`import nvd`](../appendices/cli-reference.md#import-nvd) in the CLI Reference lists.

The result window has three display controls. They change what the window shows, not what the import produced.

**By Sample / By Taxon.** Switches the outline between two arrangements of the same contigs. The default is By Sample, which gives one row per contig without grouping by organism and suits walking one run in order. Switch to By Taxon to collect every contig whose best match names the same organism under one heading. This setting has no command-line flag.

**All Samples.** Opens a popover for narrowing the outline to a chosen subset of the run's samples. The default is every sample, and the button relabels itself to report the state, for example "2 of 3 Samples". Narrow it when a run holds many samples and you want to read one at a time. This setting has no command-line flag.

**Search contigs….** Filters the outline to contigs whose organism name, subject title, accession, or contig name contains what you type. The default is empty, which lists every contig in the selected samples. It searches best matches only, so a term that appears only in a lower-ranked match will not bring its contig into view. This setting has no command-line flag.

## Reading the results

The outline carries fourteen columns. Six of them also appear as badges in the detail pane, marked below. Mapped Reads and Unique Reads count reads, and each mate of a read pair counts as one read. The two [mates](../../GLOSSARY.md#mate) are the two reads of one fragment.

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
| Mapped Reads | Reads that mapped back to this contig, as the pipeline counted them (badge) |
| Unique Reads | Reads in the sample's alignment file whose primary alignment is on this contig, after duplicates are set aside, or a dash when LGE could not count them |
| RPB | Reads per billion, an abundance figure (badge) |
| Aln Length | Length of the region BLAST aligned |

Contigs are listed longest first, and clicking a header does not re-sort them. You can drag headers to reorder columns and drag the dividers to resize them. Right-click any header for a menu with a **Standard Columns** checklist, **Reset Column Widths**, and, when sample metadata is attached, a **Sample Metadata** section for showing metadata columns.

<!-- SHOT: nvd-column-menu -->

<!-- ILLUSTRATION: contig-alignment-length -->

**Length and Aln Length.** Read these two together, because the gap between them is the part of the contig that matched nothing. In the demo results `NODE_1_length_500_cov_10.0` is 500 bases long and aligns over 498 of them. A 5,000-base contig aligning over only 400 would say that most of the contig is sequence the database does not know. As a working line, a match covering less than half of a long contig is worth chasing.

**Identity %, E-value, and Bit Score.** These are BLAST's standard measures of a match, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read each one. For NVD, a best hit near 100 percent identity is a known virus, and a best hit below about 90 percent is the case the pipeline exists to find. The demo best matches run 99.5, 96.0, 99.0, and 97.5 percent, all known-virus territory. An e-value shown as `0` means a number too small for BLAST to print, not zero. Bit scores compare one contig's own matches, which is the check [What good looks like](#what-good-looks-like) uses.

**Mapped Reads and Unique Reads.** Mapped Reads is how many reads mapped back to this contig, as the NVD pipeline reported it, the sequencing evidence behind the contig. [Unique Reads](../../GLOSSARY.md#unique-reads) is LGE's own count from the run's alignment files. At import LGE marks duplicates, reads that start and end at the same place on the same strand, and then counts the reads on this contig, leaving out duplicates and any extra placement of a read the mapper also reported. So each read counts once, at its [primary alignment](../../GLOSSARY.md#primary-alignment), the one placement the mapper marks as the read's real position. That is the meaning the column has in every classification view. Without alignment files LGE cannot count, and the column shows a dash, as it does on every row of the demo results.

**RPB.** [Reads per billion](../../GLOSSARY.md#reads-per-billion) is the mapped-read count divided by the sample's total read count and multiplied by a billion, a normalized figure whose denominator is every read in the sample. It puts contigs from libraries of different sizes on one scale. The sample's total read count comes from the pipeline's table and is not shown in the window. SampleA's SARS-CoV-2 contig has 50 mapped reads out of 1,000,000, an RPB of 50,000. SampleB's herpesvirus contig has 100 out of 2,000,000, also an RPB of 50,000, so the two are equally abundant in their own samples although one has twice the reads. RPB has no fixed good value, so compare contigs within one run.

**Classification and Rank.** These are the organism the pipeline settled on and the [taxonomic](../../GLOSSARY.md#taxon) level of its name. A broad rank, such as a genus or family where you might expect a species, means the pipeline would not be more specific than the evidence allowed, so report the identification at that rank.

**Accession and Subject.** These identify the matched record by its [accession](../../GLOSSARY.md#accession) and its full title. Right-click a row and choose **Open on NCBI** to open the record, or **Search PubMed** to search the literature for the organism.

### The action bar and the row menu

The action bar is the one every classifier viewport shares, with **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**, and [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each control. In the NVD viewport:

- **Export** opens a save sheet titled Export NVD Contigs, with `<experiment>_nvd_contigs.tsv` as the default file name, and runs `lungfish-cli nvd export contigs` on an Operations Panel row. It writes the best match of each contig in the selected samples as a [tab-separated](../../GLOSSARY.md#tsv) file with all fourteen columns, with Aln Length after the identity and Unique Reads right after Mapped Reads, and leaves the cell empty where the table shows a dash.
- **Export** stays grayed until the result has opened and a sample is selected, and its tooltip says which, such as "Pick a sample to export."
- **Extract Reads…** writes the reads behind the selected rows as a new FASTQ bundle, each read once, using the dialog that [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) describes. It needs the run's BAM files.

The information button at the right of the bar opens a popover headed **NVD Pipeline Info**, listing the experiment, import date, format version, sample, contig, and hit counts, the BLAST database version when the run recorded one, and the source directory. Sample metadata is attached through the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window, in the way [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

Right-click a contig row for **Extract Reads…**, then **Extract Sequence…**, **Verify with BLAST…**, **Copy FASTA**, **Export FASTA…**, **Extract to New Bundle…**, and **Run Operation…**, which work on the contig's own sequence. The menu ends with **Copy Name**, **Copy Accession**, **Open on NCBI**, and **Search PubMed**.

## What good looks like

The NVD viewport answers the questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) at the level of contigs. Mapped Reads says how many reads built each contig, the Contig Alignment section shows how they spread along it, Unique Reads says how many are independent on a full run, and the ranked BLAST hits are the independent check the pipeline already ran. Controls are yours to add.

First, check the summary cards. Samples should match the number of libraries that went into the run. Hits can never be lower than Contigs, since every contig carries at least one match.

Second, read the long contigs first. Compare Length with Aln Length and look at Identity %. A long contig matching near 100 percent across nearly its whole length is routine and says the sample holds a known virus. A long contig matched over only part of its length, or below about 90 percent identity, is the candidate to expand next.

Third, expand the row and compare bit scores, but only among matches that name different organisms. Close scores matter only when they point at different organisms. If the top match stands far above every match naming another organism, the call is clean. If matches naming different organisms score within a few percent of each other, the call is ambiguous and should not be reported as one identification. SampleA's HIV-1 contig shows close scores, stepping from 750 down to 660, but all five matches name HIV-1, so the call is safe.

Fourth, check Mapped Reads before you believe a contig at all. A contig built from very few reads may be an assembly artifact, and no BLAST number can tell you so. On a full run, compare Unique Reads with Mapped Reads too, since a contig whose reads are mostly duplicates rests on few original fragments. These checks need a full run, since the demo results carry no reads. Open the Contig Alignment section and look at the [pileup](../../GLOSSARY.md#pileup), the stack of reads over each position. Reads running the full length at a steady depth support the contig. Reads covering only a short stretch point to an artifact.

The import's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, holds a [checksum](../../GLOSSARY.md#checksum), a short fingerprint, of the table it read, so a later reader can confirm which run the result came from.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of the import is listed in [`import nvd`](../appendices/cli-reference.md#import-nvd) in the CLI Reference.

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

The second line stores the run folder in a variable named `RUN`, in the same way as `PROJECT`. `nvd summary` prints the experiment, the three counts, and each contig's best hit without importing anything. `import nvd` writes into the current folder unless `--output-dir` names one, so point it at the project's `Analyses` folder to match the Import Center. For NVD, the extraction's `--accession` takes the contig name. The extraction command reads the run's BAM files, so on the demo results it stops with an error and writes nothing.

## Next

This is the last chapter of the Classification part. Continue to [When to Assemble](../07-assembly/01-when-to-assemble.md), which opens the Assembly part and shows how to build contigs like NVD's from your own reads, the step that turns a read classifier's hint about an unknown virus into a sequence you can study. [BLAST Verification](06-blast-verification.md) explains what a contig verification returns, and [What Is Read Classification](01-what-is-classification.md) sets NVD beside the other routes in this part.
