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
  - "File > Import Center… > Classification Results > NAO-MGS Results"
  - "CLI: lungfish-cli import nao-mgs <input-path>"
  - "CLI: lungfish-cli nao-mgs summary <input-path>"
shots:
  - id: nao-mgs-import-card
    caption: "The NAO-MGS Results card, with the file hint reading virus_hits_final.tsv.gz or _virus_hits.tsv.gz."
  - id: nao-mgs-import-sheet
    caption: "The NAO-MGS Import sheet after a file is chosen, showing the read-only path readout beside the Browse… button and the Validation section reporting Valid NAO-MGS results with the source file name."
  - id: nao-mgs-result-viewport
    caption: "The NAO-MGS viewport on the imported wastewater fixture, showing the Samples and Taxa summary cards along the top, the sample-filter button reading All Samples above the taxon table, the table's Sample, Taxon, Hits, Unique Reads, and Refs columns, the overview bar chart filling the detail pane, and the action bar with Verify with BLAST…, Export, Extract Reads…, and BLAST Results."
  - id: nao-mgs-taxon-detail
    caption: "The detail pane after a taxon row is selected, showing the taxon name header, the Taxid line with its unique-of-total read counts and accession count, and the miniBAM Panels section with one read-pileup panel per top accession."
illustrations: []
glossary_refs: [accession, bam, bit-score, blast, bundle, fastq, fragment, mate, metagenomics, minibam, nao-mgs, operations-panel, paired-end, pcr-duplicate, percent-identity, provenance, checksum, read, read-pair, taxon, taxonomy-id, unique-reads, viewport]
features_refs: [classify.nao-mgs]
fixtures_refs: [naomgs]
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about reading a file somebody else made. Lungfish Genome Explorer (LGE) does not produce it.

[NAO-MGS](../../GLOSSARY.md#nao-mgs) is a [metagenomic](../../GLOSSARY.md#metagenomics) surveillance pipeline built by SecureBio, a nonprofit working on biosecurity. Metagenomics means sequencing all the nucleic acid in a mixed sample at once. Surveillance means doing that again and again on samples from a population, here wastewater, so that a new pathogen shows up before anyone reports a case. A pipeline is a fixed chain of programs run one after another. NAO-MGS runs on a computing cluster or in the cloud, operated by someone else.

The pipeline aligns every [read](../../GLOSSARY.md#read), the record a sequencer writes for one DNA [fragment](../../GLOSSARY.md#fragment), against a fixed collection of viral genomes. Its main output is a table with one row per matching read, not one row per virus. In a [paired-end](../../GLOSSARY.md#paired-end) run, where the sequencer reads each fragment from both ends, one row stands for a [read pair](../../GLOSSARY.md#read-pair), the two reads of one fragment. The pipeline reports viral [taxa](../../GLOSSARY.md#taxon) only, so a wastewater sample's bacteria never appear, however abundant.

LGE imports that finished table, totals it into a table with one row per taxon in each sample, keeps the read evidence behind each taxon, and opens it in a [viewport](../../GLOSSARY.md#viewport), the main area of the window that shows one result.

The file LGE reads is `virus_hits_final.tsv.gz`, the pipeline's combined virus-hit table, a tab-separated text table compressed with gzip. Newer versions of the pipeline write one file per sequencing lane instead, each ending in `_virus_hits.tsv.gz`, and the importer accepts those too. Point the importer at the results folder and it finds the table, or point it at the table itself.

## Why you would do this

The raw table runs thirty columns wide with one row per matching read or read pair, split across every sample in the run. To say anything, you would first have to total it by taxon and by sample. The import does that totaling for you and keeps the reads.

A surveillance signal is only worth acting on if the reads under it are real. Library preparation copies fragments many times by PCR, and those copies are called [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). Ten copies of one fragment and ten independent fragments give the same count but mean very different things. The viewport therefore reports [unique reads](../../GLOSSARY.md#unique-reads), the reads left after copies are set aside, beside total hits, and lets you open the read pileups under a taxon and look.

The import also puts the surveillance result in the same project as everything else, so the same [BLAST](../../GLOSSARY.md#blast) verification and read extraction you use for Kraken 2 results work here. BLAST searches a sequence against NCBI's public sequence collection.

## Before you start

Open a project so LGE has somewhere to save the result. With no project open, the NAO-MGS import shows the alert No Project Open and imports nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds `virus_hits_final.tsv.gz` under `Practice Data/naomgs`. Importing it is this chapter's procedure, so point the importer at that file, or download it as described next.

This chapter uses the NAO-MGS wastewater fixture, a small five-site run in one combined table. Download `virus_hits_final.tsv.gz` from [Tests/Fixtures/naomgs](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/naomgs), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. In normal work this file arrives from a collaborator or a computing core.

Nothing needs installing. The import downloads each matched reference sequence from NCBI, so it needs an internet connection.

## Procedure

### Open the NAO-MGS Results card

Choose **File > Import Center…** (Cmd-Shift-I) and click the **Classification Results** tab. The **NAO-MGS Results** card carries the tag NM, and its file hint reads `virus_hits_final.tsv.gz or _virus_hits.tsv.gz`. Click it, or drag the file onto it.

<!-- SHOT: nao-mgs-import-card -->

### Choose the results and check the validation

A sheet titled **NAO-MGS Import** opens. Click **Browse…** and select the pipeline's output folder or the table itself. Pick the folder when you have the pipeline's whole output, since the importer then finds the right file. For the fixture, pick the downloaded file.

The **Validation** section checks the file's header, its first line of column names. When the header matches an NAO-MGS virus-hits table, it shows a green checkmark beside **Valid NAO-MGS results** and names the source file. When the run wrote one file per sequencing lane, a **Files found** row reports how many it found, and the importer handles them together. When the header does not match, a warning triangle and the reason appear instead, and **Run** stays off.

<!-- SHOT: nao-mgs-import-sheet -->

### Import and open the result

Click **Run**. LGE runs `lungfish-cli import nao-mgs` in the background on an [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) row titled `NAO-MGS Import`. The Operations Panel lists running and finished tasks and opens with **Operations > Show Operations Panel** (Cmd-Shift-P). **Copy CLI Command** on the row copies the command, and **Cancel** stops the import.

The import splits the table by sample, imports each sample, merges them, and looks up each numeric [taxonomy identifier](../../GLOSSARY.md#taxonomy-id) at NCBI to get an organism name. A taxonomy identifier is the number NCBI assigns to one taxon, so `28875` is Rotavirus A.

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. It is named `naomgs-` followed by the input file's name, so the fixture gives `naomgs-virus_hits_final`. Double-click the result in the sidebar, under `Analyses`, to open the NAO-MGS viewport.

The result is a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. It holds per-taxon summaries, an alignment file per sample rebuilt from the reads in the table, and the downloaded references, not a copy of the table.

## Settings

The NAO-MGS Import sheet has no settings. Its **Browse…** button, path readout, Validation section, and **Cancel** and **Run** buttons are the whole surface. The Import Center always fetches the matched references from NCBI. The command-line import has three options of its own, `--sample-name`, `--no-fetch-references`, and `--output-dir`, which [`import nao-mgs`](../appendices/cli-reference.md#import-nao-mgs) in the CLI Reference lists.

## Reading the results

The viewport has a summary bar along the top, the taxon table on the right, the detail pane on the left, and an action bar along the bottom.

<!-- SHOT: nao-mgs-result-viewport -->

### The summary bar and the sample filter

The summary bar holds two cards. **Samples** reports how many samples are in view, for example `2 of 5 samples` after filtering. **Taxa** counts each taxon once, however many samples hold it, and counts only the samples in view. On the fixture the bar reads 5 samples and 4 taxa. The taxon table has more rows than that, because it gives each taxon one row in every sample that holds it.

The button above the taxon table reads **All Samples** when every sample is included and a count such as **2 of 5 Samples** when it is not. Click it to choose which sites to show. Everything in the viewport follows that choice.

### The taxon table

The table has five columns. Both count columns count reads, and each mate of a read pair counts as one read. The [mates](../../GLOSSARY.md#mate) are the two reads of one fragment.

| Column | What it holds |
|---|---|
| Sample | The sample the row belongs to, so one taxon found at three sites fills three rows |
| Taxon | The organism name, or `Taxid N` when NCBI returned no name for that number |
| Hits | Aligned reads assigned to that taxon in that sample |
| Unique Reads | The same reads after duplicates are set aside, so reads that start at the same place on the same reference, on the same strand and at the same length, count once, the meaning the column has in every classification view |
| Refs | How many reference [accessions](../../GLOSSARY.md#accession), each the permanent identifier of one database record, the hits spread across |

Type in the **Filter taxa…** field above the table to narrow the rows. Click a column header for a menu that sorts by that column or filters it, for example **Filter Taxon Contains…**, which asks for a value. Right-click a header for a list of columns with a checkmark beside each, and choose one to hide or show that column. Sample metadata you attach becomes extra columns, as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

Read Hits against Unique Reads. The viewport has no normalized figure, so compare sites by these counts and by the share of hits that are unique. On the fixture, the IL_CHI_StickneyWS site's Rotavirus A row has 12 hits from 8 unique reads, so 4 of the 12 are duplicate copies. The CA_LosAngeles_County row for the same virus has 28 hits from 26 unique reads. That is 93 percent independent against 67 percent at the other site. Compare these proportions, not the raw counts. When Unique Reads falls well below Hits, the taxon rests on a few fragments that PCR copied, and the honest count is the unique one.

### The detail pane

With no taxon selected, the detail pane shows an overview with **Total Hits** and **Unique Taxa** cards, a card naming or counting the samples in view, and a **Top Taxa by Read Count** bar chart of up to fifteen taxa. Click a bar to select that taxon in the table.

Select a taxon row and the pane shows its evidence. Under the organism name, a line gives the taxonomy identifier, then the unique-of-total read counts, then the accession count. For the CA_LosAngeles_County Rotavirus A row it reads `Taxid: 28875  •  26 unique / 28 total reads  •  7 accessions`.

A row of metrics follows, giving average identity (the share of aligned bases that match the reference), average bit score (alignment strength, higher is better), average edit distance (the number of bases that differ), unique reads, and accession count. Below it is a **miniBAM Panels** section. A [miniBAM](../../GLOSSARY.md#minibam) panel is a compact read-pileup view. It draws a depth curve, the number of reads covering each position, over the reference and stacks the reads underneath at the positions where they matched, coloring bases that disagree with the reference. Panels are shown for at most five accessions, ordered by total hits, and the heading says how many, for example `miniBAM Panels (Top 5: 5 of 7 accessions)`. The note under the heading says the panels are ordered by unique read count, which is a known defect listed under [NAO-MGS panel order](../appendices/troubleshooting.md#defect-naomgs-order). Drag a panel's bottom edge down to make it taller. When there are too many reads to draw, only a sample of them is drawn, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

<!-- SHOT: nao-mgs-taxon-detail -->

Each accession above its panel links to that record at GenBank, NCBI's sequence database. Right-click it to open the record or copy the accession. Beside the accession, the share of the reference the reads covered reads as a percent. It reads `coverage unavailable (reference not fetched)` when LGE has no downloaded copy of that reference, such as after a command-line import with `--no-fetch-references`, because the reference's true length is then unknown.

A note under the **miniBAM Panels** heading can name a problem with the result itself. One says the panels come from an earlier NAO-MGS import that stored reads mapping to the reverse strand the wrong way round, so many reads show false mismatches, and **Extract Reads…** then refuses that sample and writes nothing. Another names an alignment file that is missing from the result, so the panels are empty. In either case, import the same NAO-MGS results file again under **NAO-MGS Results** in the Import Center, which makes a second result beside the old one, and work from the new result.

### The action bar

The action bar is the one every classifier viewport shares, with **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**. [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each control and the reason a grayed button gives in its tooltip.

**Verify with BLAST…** sends a sample of the selected taxon's reads to NCBI and reports whether their best matches belong to the taxon on the row. From this viewport it searches all of NCBI's `core_nt` collection with no filter, as every viewport does, and draws its reads from the four quarters of the reference. [Verify from another classifier viewport](06-blast-verification.md#verify-from-another-classifier-viewport) describes the draw, and [Reading the results](06-blast-verification.md#reading-the-results) in the same chapter explains percent identity, e-value, and query coverage.

**Export** opens a save sheet titled Export NAO-MGS Summary, with `<sample>_naomgs_summary.tsv` as the default file name. It writes the taxon table as it currently stands, with your filters, sort, and metadata columns, as a tab-separated file, and runs `lungfish-cli nao-mgs export table` on an Operations Panel row. The button stays grayed, with the tooltip "Export is ready once this result finishes opening.", until the result has opened.

**Extract Reads…** pulls the reads behind the selected rows into a new [FASTQ](../../GLOSSARY.md#fastq) bundle, so select a row first. Its dialog is the one [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) describes. Reads come out on the strand they were sequenced.

The information button at the right end opens a popover headed **NAO-MGS Pipeline Info**, which lists the source file, import date, format version, hit and taxon counts, top taxon, workflow version, and number of fetched accessions.

Right-clicking a taxon row offers **Verify with BLAST…**, **Copy Taxon ID**, **Copy Accession**, **Open on NCBI**, **Open Taxonomy on NCBI**, **Search PubMed**, and **Extract Reads…**.

## What good looks like

The NAO-MGS viewport answers three questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) on screen. Hits says how many reads support each taxon, the miniBAM panels show how they spread along the reference, and Unique Reads says how many are independent. Recurrence across sites stands in for a control, and **Verify with BLAST…** answers the last question.

Read Unique Reads before Hits. As a rule of thumb, a row whose unique count is under half its hit count deserves its pileups opened before you quote the number. The fixture's two Rotavirus A rows sit at 67 and 93 percent unique, both above that line.

Check whether the taxon appears in more than one sample. One organism found at several independent sites is a stronger observation than the same number of reads at one site. Sort by Taxon so the rows for one organism sit together.

Open the miniBAM panels and look at where the reads sat. Reads touching several separated parts of the reference are what a genuine presence looks like. Reads stacked on one short stretch suggest a conserved region, a stretch shared with related viruses, or a PCR artifact, and in any of these cases the name on the row is a weaker claim than the count suggests.

Be careful about what the name proves. NAO-MGS reports the nearest match in its reference collection. A row naming a broad group, such as the fixture's `Cressdnaviricota sp.`, an unplaced member of a large viral phylum, means the pipeline could not narrow it further.

Verify anything you intend to act on with **Verify with BLAST…**, and remember the boundary. A virus absent from the pipeline's collection cannot appear, and a bacterium cannot appear at all. Pair the result with a broad survey such as [Running Kraken 2](02-running-kraken2.md) when you need to know what else the sample held. The import's provenance record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, names the source file and its checksum.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of the import is listed in [`import nao-mgs`](../appendices/cli-reference.md#import-nao-mgs) in the CLI Reference. The first command matches what the Import Center runs, apart from the `--format json` it adds so LGE can read the command's progress.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"

lungfish-cli import nao-mgs "$PROJECT/Practice Data/naomgs/virus_hits_final.tsv.gz" \
  --output-dir "$PROJECT/Analyses"

lungfish-cli extract reads --by-classifier --tool naomgs \
  --result "$PROJECT/Analyses/naomgs-virus_hits_final" \
  --sample MU-CASPER-2026-03-31-a-IL_CHI_StickneyWS_20260308 \
  --accession KU048583.1 \
  --output virus-reads.fastq
```

The command-line import writes into the current folder unless `--output-dir` names one, so point it at the project's `Analyses` folder to match the Import Center. Extraction for NAO-MGS selects by accession, not by taxon, and on the fixture the command above writes 4 reads. The **Extract Reads…** button selects by accession and also keeps only the reads assigned to the taxon, so the command can return more reads than the button when one accession holds reads from more than one taxon. `KU048583.1` is a Rotavirus A record, and the full sample name appears in the Sample column. For per-sample counts, use the project import rather than `nao-mgs summary`, which adds all the sites of a multi-sample table together and labels the total with one site's name.

## Next

Continue to [Novel Virus Diagnostics](09-novel-virus-detection.md), the last import in this part, which works from assembled contigs rather than single reads and suits the hunt for a virus no database names exactly. [BLAST Verification](06-blast-verification.md) explains the verdict that **Verify with BLAST…** returns.
