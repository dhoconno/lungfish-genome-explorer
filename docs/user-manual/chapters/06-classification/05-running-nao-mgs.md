---
title: Importing NAO-MGS Results
chapter_id: 06-classification/05-running-nao-mgs
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 15
task: Import externally produced NAO-MGS wastewater-surveillance results and read the taxon viewport.
tags: [classification, nao-mgs, wastewater, surveillance, import]
tools: [nao-mgs]
parameters_refs: [import.nao-mgs]
entry_points:
  - "File > Import Center... > Classification Results > NAO-MGS Results"
  - "CLI: lungfish-cli import nao-mgs <input-path>"
  - "CLI: lungfish-cli nao-mgs summary <input-path>"
shots:
  - id: nao-mgs-import-card
    caption: "The NAO-MGS Results card, with the file hint reading virus_hits_final.tsv.gz or _virus_hits.tsv.gz."
  - id: nao-mgs-import-sheet
    caption: "The NAO-MGS Import sheet after a file is chosen, showing the read-only path readout beside the Browse... button and the Validation section reporting Valid NAO-MGS results with the source file name."
  - id: nao-mgs-result-viewport
    caption: "The NAO-MGS viewport on the imported wastewater fixture, showing the Samples and Taxa summary cards along the top, the sample-filter button reading All Samples above the taxon table, the table's Sample, Taxon, Hits, Unique Reads, and Refs columns, and the overview bar chart filling the detail pane."
  - id: nao-mgs-taxon-detail
    caption: "The detail pane after a taxon row is selected, showing the taxon name header, the Taxid line with its unique-of-total read counts and accession count, and the miniBAM Panels section with one read-pileup panel per top accession."
illustrations: []
glossary_refs: [accession, bam, bit-score, blast, bundle, fastq, metagenomics, minibam, nao-mgs, operations-panel, pcr-duplicate, percent-identity, provenance, checksum, read, taxon, taxonomy-id]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about reading a file somebody else made. Lungfish Genome Explorer (LGE) does not produce it.

[NAO-MGS](../../GLOSSARY.md#nao-mgs) is a [metagenomic](../../GLOSSARY.md#metagenomics) surveillance pipeline built by SecureBio, a nonprofit working on biosecurity. Metagenomics means sequencing all the nucleic acid in a mixed sample at once, and surveillance means doing that repeatedly on samples from a population, here wastewater, so that a new pathogen shows up before anyone reports a case. A pipeline is a fixed chain of programs run one after another. NAO-MGS runs on a computing cluster or in the cloud, operated by someone else.

The pipeline aligns every [read](../../GLOSSARY.md#read), one fragment of sequence the instrument reported, against a fixed collection of viral genomes. Its main output is a table with one row per matching read, not one row per virus. It reports viral [taxa](../../GLOSSARY.md#taxon) only, so a wastewater sample's bacteria never appear, however abundant.

LGE imports that finished table, folds it into a per-taxon table you can sort, keeps the read evidence behind each taxon, and opens it in a viewport, the panel that displays one result.

The file LGE reads is `virus_hits_final.tsv.gz`, the pipeline's combined virus-hit table, a tab-separated text table compressed with gzip. Newer versions of the pipeline write one file per sequencing lane instead, each ending in `_virus_hits.tsv.gz`, and the importer accepts those too. Point the importer at the results folder and it finds the table, or point it at the table itself.

## Why you would do this

The raw table runs thirty columns wide with one row per read alignment, split across every sample in the run. To say anything, you would first have to total it by taxon and by sample. The import does that totalling for you and keeps the reads.

A surveillance signal is only worth acting on if the reads under it are real. Library preparation copies fragments many times by PCR, and those copies are called [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). Ten copies of one fragment and ten independent fragments give the same count but mean very different things. The viewport therefore reports unique reads beside total hits, and lets you open the read pileups under a taxon and look.

The import also puts the surveillance result in the same project as everything else, so the same [BLAST](../../GLOSSARY.md#blast) verification and read extraction you use for Kraken 2 results work here.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the NAO-MGS wastewater fixture, a small five-site run in one combined table. Download `virus_hits_final.tsv.gz` from [Tests/Fixtures/naomgs](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/naomgs), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. In normal work this file arrives from a collaborator or a computing core.

Nothing needs installing. The window's import downloads each matched reference sequence from NCBI, so it needs an internet connection.

## Procedure

### 1. Open the NAO-MGS Results card

Choose **File > Import Center...** (Cmd-Shift-I) and click the **Classification Results** tab. The **NAO-MGS Results** card carries the tag NM, and its file hint reads `virus_hits_final.tsv.gz or _virus_hits.tsv.gz`. Click it, or drag the file onto it.

<!-- SHOT: nao-mgs-import-card -->

### 2. Choose the results and check the validation

A sheet titled **NAO-MGS Import** opens. Click **Browse...** and select the pipeline's output folder or the table itself. Pick the folder when you have the pipeline's whole output, since the importer then finds the right file. For the fixture, pick the downloaded file.

The **Validation** section checks the file's header, its first line of column names. When the header matches an NAO-MGS virus-hits table, it shows a green tick beside **Valid NAO-MGS results** and names the source file. When the run wrote one file per sequencing lane, a **Files found** row reports how many it found, and the importer handles them together. When the header does not match, a warning triangle and the reason appear instead, and **Run** stays disabled.

<!-- SHOT: nao-mgs-import-sheet -->

### 3. Import and open the result

Click **Run**. LGE splits the table by sample, imports each sample, merges them, and looks up each numeric [taxonomy identifier](../../GLOSSARY.md#taxonomy-id) at NCBI to get an organism name. A taxonomy identifier is the number NCBI assigns to one taxon, so `28875` is Rotavirus A. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. It is named `naomgs-` followed by the input file's name, so the fixture gives `naomgs-virus_hits_final`. The fixture imports 35 hits across 4 distinct taxa. Double-click the result in the sidebar, under `Analyses`, to open the NAO-MGS viewport.

The result is a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. It holds per-taxon summaries, an alignment file per sample rebuilt from the reads in the table, and the downloaded references, not a copy of the table.

## Settings

The NAO-MGS Import sheet has no settings. Its **Browse...** button, path readout, Validation section, and **Cancel** and **Run** buttons are the whole surface. The window always fetches the matched references from NCBI. The command-line import has three options of its own, `--sample-name`, `--no-fetch-references`, and `--output-dir`, which the [CLI Reference](../appendices/cli-reference.md) lists.

## Reading the results

The viewport has a summary bar along the top, the taxon table on the right, the detail pane on the left, and an action bar along the bottom.

<!-- SHOT: nao-mgs-result-viewport -->

### The summary bar and the sample filter

The summary bar holds two cards. **Samples** reports how many samples are in view, for example `2 of 5 samples` after filtering. **Taxa** counts rows in the taxon table, which has one row per sample-and-taxon pair, not one per organism. On the fixture the bar reads 5 samples and 7 taxa, and those 7 rows cover 4 distinct organisms. The **Unique Taxa** card in the detail pane, described below, counts distinct organisms and reads 4, so the two cards measure different things.

The button above the taxon table reads **All Samples** when every sample is included and a count such as **2 of 5 Samples** when it is not. Click it to choose which sites to show. Everything in the viewport follows that choice.

### The taxon table

The table has five columns.

| Column | What it holds |
|---|---|
| Sample | The sample the row belongs to, so one taxon found at three sites fills three rows |
| Taxon | The organism name, or `Taxid N` when NCBI returned no name for that number |
| Hits | Read-to-reference alignments for that taxon in that sample |
| Unique Reads | Hits left after collapsing PCR duplicates, so hits that start at the same place on the same reference, on the same strand and at the same length, count once |
| Refs | How many reference [accessions](../../GLOSSARY.md#accession), each the permanent identifier of one database record, the hits spread across |

Click a column header for a menu that sorts by that column or filters it, for example **Filter Taxon Contains…**, which asks for a value. Right-click a header for a list of columns with a tick beside each, and untick one to hide that column. Sample metadata you attach becomes extra columns, as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

Read Hits against Unique Reads. On the fixture, the IL_CHI_StickneyWS site's Rotavirus A row has 12 hits from 8 unique reads, so 4 of the 12 are duplicate copies. The CA_LosAngeles_County row for the same virus has 28 hits from 26 unique reads. That is 93 percent independent against 67 percent at the other site. Compare these proportions, not the raw counts. When Unique Reads falls well below Hits, the taxon rests on a few fragments that PCR copied, and the honest count is the unique one.

### The detail pane

With no taxon selected, the detail pane shows an overview with **Total Hits** and **Unique Taxa** cards, a card naming or counting the samples in view, and a **Top Taxa by Read Count** bar chart of up to fifteen taxa. Click a bar to select that taxon in the table.

Select a taxon row and the pane shows its evidence. Under the organism name, a line reads `Taxid: N`, then the unique-of-total read counts, then the accession count. For the CA_LosAngeles_County Rotavirus A row it reads `Taxid: 28875  •  26 unique / 28 total reads  •  7 accessions`.

A row of metrics follows, giving average identity (the share of aligned bases that match the reference), average bit score (alignment strength, higher is better), average edit distance (the number of bases that differ), unique reads, and accession count. Below it is a **miniBAM Panels** section. A [miniBAM](../../GLOSSARY.md#minibam) panel is a compact read-pileup view. It draws a depth curve, the number of reads covering each position, over the reference and stacks the reads underneath at the positions where they matched, colouring bases that disagree with the reference. Panels are shown for at most five accessions, ordered by total hits, and the heading says which, for example `miniBAM Panels (Top 5: 5 of 7 accessions)`. Drag a panel's bottom edge down to make it taller. When there are too many reads to draw, only a sample of them is drawn, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

<!-- SHOT: nao-mgs-taxon-detail -->

Each accession above its panel links to that record at GenBank, NCBI's sequence database. Right-click it to open the record or copy the accession.

### The action bar

**BLAST Verify** sends a sample of the selected taxon's reads to NCBI and reports whether NCBI agrees with the name on the row. From this viewport the search is limited to NCBI records for the row's own taxon, so a Supported verdict here is weaker evidence than one from the taxonomy viewport. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage.

**Export** writes the taxon table as it currently stands, with your filters, sort, and metadata columns, to a `.tsv` file named `<sample>_naomgs_summary.tsv` by default.

**Extract FASTQ** pulls the reads behind the selected rows into a new [FASTQ](../../GLOSSARY.md#fastq) bundle, so select a row first. Its dialog is the one [Running Kraken 2](02-running-kraken2.md#4-extract-the-reads-of-one-taxon) documents.

The information button at the right end opens a popover headed **NAO-MGS Pipeline Info**, which lists the source file, import date, format version, hit and taxon counts, top taxon, workflow version, and number of fetched accessions. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Right-clicking a taxon row offers BLAST verification, **Extract Reads...**, **Copy Taxon ID**, **Copy Top Accessions**, **View on NCBI**, **View Taxonomy on NCBI**, and **Search PubMed**.

## What good looks like

Read Unique Reads before Hits. As a rule of thumb, a row whose unique count is under half its hit count deserves its pileups opened before you quote the number. The fixture's two Rotavirus A rows sit at 67 and 93 percent unique, both above that line.

Check whether the taxon appears in more than one sample. One organism found at several independent sites is a stronger observation than the same number of reads at one site. Sort by Taxon so the rows for one organism sit together.

Open the miniBAM panels and look at where the reads sat. Reads touching several separated parts of the reference are what a genuine presence looks like. Reads stacked on one short stretch suggest a conserved region, a stretch shared with related viruses, or a PCR artifact, and in any of these cases the name on the row is a weaker claim than the count suggests.

Be careful about what the name proves. NAO-MGS reports the nearest match in its reference collection. A row naming a broad group, such as the fixture's `Cressdnaviricota sp.`, an unplaced member of a large viral phylum, means the pipeline could not narrow it further.

Verify anything you intend to act on with BLAST Verify, and remember the boundary. A virus absent from the pipeline's collection cannot appear, and a bacterium cannot appear at all. Pair the result with a broad survey such as [Running Kraken 2](02-running-kraken2.md) when you need to know what else the sample held.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli import nao-mgs /path/to/virus_hits_final.tsv.gz \
  --output-dir "/path/to/My Project.lungfish/Analyses"

lungfish-cli extract reads --by-classifier --tool naomgs \
  --result "/path/to/My Project.lungfish/Analyses/naomgs-virus_hits_final" \
  --sample MU-CASPER-2026-03-31-a-IL_CHI_StickneyWS_20260308 \
  --accession KU048583.1 \
  --output virus-reads.fastq
```

The command-line import writes into the current folder unless `--output-dir` names one, so point it at the project's `Analyses` folder to match the window. Extraction for NAO-MGS selects by accession, not by taxon, and on the fixture the command above writes 4 reads. The Extract FASTQ button selects by accession and also keeps only the reads assigned to the taxon, so the command can return more reads than the button when one accession holds reads from more than one taxon. `KU048583.1` is a Rotavirus A record, and the full sample name appears in the Sample column. For per-sample counts, use the project import rather than `nao-mgs summary`, which adds all the sites of a multi-sample table together and labels the total with one site's name.

## Next

Continue to [BLAST Verification](06-blast-verification.md) to confirm a taxon against NCBI, or to [Novel Virus Diagnostics](09-novel-virus-detection.md) for the other surveillance import.
