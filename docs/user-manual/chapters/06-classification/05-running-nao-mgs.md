---
title: Importing NAO-MGS Results
chapter_id: 06-classification/05-running-nao-mgs
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 14
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
glossary_refs: [accession, bam, bit-score, blast, bundle, fastq, fragment, mate, metagenomics, minibam, nao-mgs, operations-panel, paired-end, pcr-duplicate, percent-identity, provenance, checksum, read, read-pair, taxon, taxonomy-id, unique-reads, viewport, library-prep, tsv, terminal, negative-control, contig]
features_refs: [classify.nao-mgs]
fixtures_refs: [naomgs]
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about reading a file somebody else made. Lungfish Genome Explorer (LGE) does not produce it.

[NAO-MGS](../../GLOSSARY.md#nao-mgs) is a [metagenomic](../../GLOSSARY.md#metagenomics) surveillance pipeline built by SecureBio. Metagenomics means sequencing all the nucleic acid in a mixed sample at once. Surveillance means repeating that on samples from a population, here wastewater, so that a new pathogen shows up before anyone reports a case. A pipeline is a fixed chain of programs run one after another.

The pipeline aligns every [read](../../GLOSSARY.md#read), the record a sequencer writes for one DNA [fragment](../../GLOSSARY.md#fragment), against a fixed collection of viral genomes, its reference. Aligning a read means finding where along a genome it matches. Its main output is a table with one row per matching read, each called a hit, not one row per virus. In a [paired-end](../../GLOSSARY.md#paired-end) run, where the sequencer reads each fragment from both ends, one row stands for a [read pair](../../GLOSSARY.md#read-pair), the two reads of one fragment. The pipeline reports only viral [taxa](../../GLOSSARY.md#taxon), meaning named groups of organisms, so a wastewater sample's bacteria never appear, however abundant.

LGE imports that finished table, totals it into one row per taxon in each sample, keeps the read evidence behind each taxon, and opens it in a [viewport](../../GLOSSARY.md#viewport), the main area of the window that shows one result.

The file LGE reads is `virus_hits_final.tsv.gz`, the pipeline's combined table of hits. It is a [TSV](../../GLOSSARY.md#tsv), a text table with a tab between columns, compressed with gzip, so leave it compressed and LGE opens it as it is. Newer versions of the pipeline write one file per sequencing lane instead, each ending in `_virus_hits.tsv.gz`, and the importer accepts those too. A lane is one channel of a flow cell, the slide a sequencer loads DNA onto.

## Why you would do this

The raw table runs 29 columns wide in the practice file, with one row per matching read or read pair, split across every sample in the run. The import totals it by taxon and by sample for you and keeps the reads.

A surveillance signal is only worth acting on if the reads under it are real. [Library preparation](../../GLOSSARY.md#library-prep), the bench steps that make DNA readable by a sequencer, copies fragments many times by PCR, a reaction that copies DNA in repeated cycles, and those copies are called [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). Ten copies of one fragment and ten independent fragments give the same count but mean very different things. The viewport therefore reports [unique reads](../../GLOSSARY.md#unique-reads), the reads left after copies are set aside, beside total hits, and lets you open the pileups under a taxon, the reads stacked over the reference where they match.

## Before you start

Open a project so LGE has somewhere to save the result, since with none open the import shows the alert No Project Open and imports nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

This chapter uses the NAO-MGS wastewater fixture, a small practice data set of five samples in one combined table. The Pathogen Detection demo project holds it as `virus_hits_final.tsv.gz`, so choose **Help > Demo Projects…** and download that project, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. By default the file sits in `~/Documents/LGE Demo Projects/Pathogen Detection.lungfish/Practice Data/naomgs`, the folder **Browse…** needs to open. You can also download it from [Tests/Fixtures/naomgs](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/naomgs), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Nothing needs installing, but the import needs an internet connection. It downloads from NCBI, the US National Center for Biotechnology Information, the reference sequences of the five records with the most unique reads for each taxon in each sample. The first import on a Mac also downloads NCBI's taxonomy names.

## Procedure

### Open the NAO-MGS Results card

Choose **File > Import Center…** (Cmd-Shift-I) and click the **Classification Results** tab. The **NAO-MGS Results** card's file hint reads `virus_hits_final.tsv.gz or _virus_hits.tsv.gz`. Click the card, or drag the file onto it.

<!-- SHOT: nao-mgs-import-card -->

### Choose the results and check the validation

A sheet titled **NAO-MGS Import** opens. Click **Browse…** and select the pipeline's output folder, which lets the importer find the right file, or select the table itself. For the fixture, pick `virus_hits_final.tsv.gz`.

The **Validation** section checks the file's header, its first line of column names. When the header matches an NAO-MGS virus-hits table, it shows a green checkmark beside **Valid NAO-MGS results** and names the source file. When the run wrote one file per lane, a **Files found** row reports how many, and the importer handles them together. When the header does not match, a warning triangle and the reason appear instead, and **Run** stays off.

<!-- SHOT: nao-mgs-import-sheet -->

### Import and open the result

Click **Run**. LGE runs `lungfish-cli import nao-mgs` for you. `lungfish-cli` is LGE's command-line interface (CLI), the same tools driven by typed commands in [Terminal](../../GLOSSARY.md#terminal), the macOS app for typing commands. The job appears as a row titled `NAO-MGS Import` in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which lists running and finished tasks. **Copy CLI Command** on the row copies the command, and **Cancel** stops the import.

The import splits the table by sample, imports each sample, merges them, and looks up each numeric [taxonomy identifier](../../GLOSSARY.md#taxonomy-id), the number NCBI assigns to one taxon, in NCBI's taxonomy names file, which LGE keeps on your Mac, to get an organism name, so `28875` becomes Rotavirus A.

Wait for the row to finish, since the reference downloads from NCBI can be slow. The result then lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. It is named `naomgs-` followed by the input file's name, so the fixture gives `naomgs-virus_hits_final`. Double-click the result in the sidebar, under `Analyses`, to open the NAO-MGS viewport.

The result is a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. It holds per-taxon summaries, one [BAM](../../GLOSSARY.md#bam) file per sample, and the downloaded references. A BAM file records where each read matches along a reference, and LGE writes it from the sequences and positions the table already holds. The result keeps no copy of the table and does not read the original again.

## Settings

The NAO-MGS Import sheet has no settings, and the Import Center always downloads the references from NCBI. The command-line import has three options of its own. `--sample-name` replaces the name the result records, which also names its folder. `--no-fetch-references` skips the reference downloads. `--output-dir` names the folder that receives the result.

## Reading the results

The viewport has a summary bar along the top, the taxon table on the right, the detail pane on the left, and an action bar along the bottom.

<!-- SHOT: nao-mgs-result-viewport -->

### The summary bar and the sample filter

The summary bar holds two cards. **Samples** reports how many samples are in view. Here a sample is one wastewater collection, and the fixture's five come from five sites. **Taxa** counts each taxon once, however many samples hold it, and counts only the samples in view. On the fixture the bar reads 5 samples and 4 taxa, but the table has more rows, one per taxon in each sample that holds it.

The button above the taxon table reads **All Samples** or a count such as **2 of 5 Samples**. Click it to choose the samples, and everything in the viewport follows.

### The taxon table

Both count columns count reads, and each [mate](../../GLOSSARY.md#mate) of a read pair, one of its two reads, counts as one read.

| Column | What it holds |
|---|---|
| Sample | The sample the row belongs to |
| Taxon | The organism name, or `Taxid N` when NCBI's taxonomy names file has no name for that number |
| Hits | Aligned reads assigned to that taxon in that sample |
| Unique Reads | Reads left after probable PCR copies are set aside, as the paragraph below explains |
| Refs | How many different reference [accessions](../../GLOSSARY.md#accession), the permanent identifiers of database records, the hits matched, so 1 means every hit landed on one record |

Reads that start at the same place on the same reference, on the same strand (one of DNA's two complementary chains), and at the same length count once in **Unique Reads**. PCR copies of one fragment share all three features and independent fragments seldom do, so a match marks a probable copy. This is an approximation, since two real fragments can coincide.

On the fixture, the sample from the IL_CHI_StickneyWS site has 12 Rotavirus A hits from 8 unique reads, so 4 of the 12 are probably duplicate copies, while the CA_LosAngeles_County sample has 28 hits from 26 unique reads for the same virus.

The share of hits that are unique measures PCR copying under a row, not how much virus a sample holds. The viewport shows no figure normalized for sequencing depth, meaning adjusted for how many reads each sample received, and LGE keeps no total read count per sample to divide by. The action bar shows a selected row's percent share of all hits in view, which is not adjusted either, so a larger raw count at one sample may reflect deeper sequencing rather than more virus.

Type in the **Filter taxa…** field to narrow the rows. A column header's menu sorts by that column or filters it. Sample metadata you attach becomes extra columns, as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

### The detail pane

With no taxon selected, the detail pane shows an overview. Its **Total Hits** card adds the hits of the samples in view, its **Unique Taxa** card counts distinct taxa, unrelated to Unique Reads, and a third card names or counts the samples in view. A **Top Taxa by Read Count** bar chart of up to fifteen taxa sizes each bar by the taxon's Hits, and a click on a bar selects that taxon.

Select a taxon row and the pane shows its evidence. Under the organism name, a line gives the taxonomy identifier, then the unique-of-total read counts, then the accession count. For the CA_LosAngeles_County Rotavirus A row it reads `Taxid: 28875  •  26 unique / 28 total reads  •  7 accessions`.

A row of metrics follows. **Avg Identity**, the share of aligned bases that match the reference, and **Avg Bit Score**, alignment strength, are better when higher. **Avg Edit Dist**, the number of single-base differences from the reference, counting gaps, is better when lower.

Below the metrics is a **miniBAM Panels** section. A [miniBAM](../../GLOSSARY.md#minibam) panel draws a depth curve, the number of reads covering each position, over the reference, stacks the reads underneath where they matched, and colors bases that disagree with the reference. A panel draws every read of the selected taxon that aligned to its accession. Panels are shown for at most five accessions, those with the most hits, and the heading says how many, for example `miniBAM Panels (Top 5: 5 of 7 accessions)`. The note under the heading says the panels are ordered by unique read count. That wording is wrong, because the panels follow total hits, as the known defect [NAO-MGS panel order](../appendices/troubleshooting.md#defect-naomgs-order) records.

<!-- SHOT: nao-mgs-taxon-detail -->

Each accession above its panel links to that record at GenBank, NCBI's sequence database. Beside it, a line gives the accession's unique and total reads, then how many bases of the reference the reads cover out of its length, with that share as a percent. The line reads `coverage unavailable (reference not fetched)` in place of the percent when LGE has no downloaded copy of that reference, such as after a command-line import with `--no-fetch-references`, because the reference's true length is then unknown.

A note under the **miniBAM Panels** heading can say the panels come from an earlier import that stored reads matching the reverse strand without flipping them to the reference's direction, so many reads show false mismatches, and **Extract Reads…** then refuses that sample. Only a result imported by an earlier version of LGE shows it. Another note can say an alignment file is missing from the result, so the panels are empty, which any result can show. Import the same results file again under **NAO-MGS Results** in the Import Center, and the new result sits beside the old one with a number such as `-2` added to its name, so work from the new one.

### The action bar

The action bar is the one every classifier viewport shares, with **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**. [The action bar](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each control and why a button is grayed. The information button at the right end opens **NAO-MGS Pipeline Info**, a small panel of import details.

**Verify with BLAST…** sends a subset of the selected taxon's reads to NCBI, which runs [BLAST](../../GLOSSARY.md#blast), a search of its public sequence collection, and reports whether their best matches belong to the taxon on the row. A small panel asks how many reads to send, 20 by default. From this viewport LGE sends the first reads of the taxon's top accessions that are not marked as duplicates, up to that number. It searches all of `core_nt`, a version of NCBI's general DNA sequence collection, with no filter on organism. The verdict and one row per read appear in the **BLAST Results** drawer at the bottom of the viewport. [BLAST Verification](06-blast-verification.md) explains the wait, the verdict, and the percent identity, e-value, and query coverage it reports.

**Export** opens a save sheet at once, with no menu, unlike Kraken 2. The sheet is titled Export NAO-MGS Summary and suggests `<name>_naomgs_summary.tsv`, where the name is that of the first sample in sorted order when the table holds several, so rename the file as you save. It writes the taxon table as it currently stands, with your filters, sort, and metadata columns, as a TSV that a spreadsheet program opens, and runs `lungfish-cli nao-mgs export table`.

**Extract Reads…** pulls the reads behind the selected rows into a new [FASTQ](../../GLOSSARY.md#fastq) bundle, so select a row first. Its dialog is the one [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) describes. Each read comes out in the direction the sequencer wrote it, even when it matched the opposite strand of the reference and LGE stored it flipped.

## What good looks like

The NAO-MGS viewport speaks to the five questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) in the order the checklist asks them. **Hits** counts the reads that support a name, the miniBAM panels show how they spread along the reference, and **Unique Reads** counts the reads left after probable PCR copies are set aside, so each independent fragment adds one read, or two when both mates of a pair align. The viewport has no control role, so a [negative control](../../GLOSSARY.md#negative-control), a blank carried through the run, is just one more sample. **Verify with BLAST…** gives the independent check.

Read Unique Reads before Hits. When Unique Reads falls well below Hits, the taxon rests on a few fragments that PCR copied, and the honest count is the unique one. As a rule of thumb, a row whose unique count is under half its hit count deserves its pileups opened before you quote the number. The fixture's two Rotavirus A rows sit at 67 and 93 percent unique, both above that line.

Check whether the taxon appears in more than one sample. One organism found at several independent sites is a stronger observation than the same number of reads at one site, though weaker than a negative control, because a contaminant from a shared reagent or run can recur too.

Open the miniBAM panels and look at where the reads sat. Reads touching several separated parts of the reference are what a genuine presence looks like. Reads stacked on one short stretch suggest a conserved region, a stretch shared with related viruses, or a PCR artifact, and in any of these cases the name on the row is a weaker claim than the count suggests.

Be careful about what the name proves. NAO-MGS reports the nearest match in its reference collection. A row naming a broad group, such as the fixture's `Cressdnaviricota sp.`, an unplaced member of a large viral phylum that NCBI lists under `unclassified Cressdnaviricota`, means the pipeline could not narrow it further.

Verify anything you intend to act on with **Verify with BLAST…**, and remember the boundary. A virus absent from the pipeline's collection cannot appear, and a bacterium cannot appear at all. To see which viruses the collection holds, start from the pipeline's page in the [Tool Bibliography](../appendices/bibliography.md#imported-classification-results). To see what else the sample held, pair the result with a broad survey such as [Running Kraken 2](02-running-kraken2.md). The import's [provenance](../../GLOSSARY.md#provenance) record, which documents how the result was made, names the source file and its [checksum](../../GLOSSARY.md#checksum), a fingerprint of the file's exact contents. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Type them into Terminal. Every flag of the import, a word starting with two dashes that changes how the command runs, is listed in [`import nao-mgs`](../appendices/cli-reference.md#import-nao-mgs) in the CLI Reference. The first command matches what the Import Center runs, apart from an extra flag that lets LGE follow its progress.

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

If you downloaded the file instead, change the path after `import nao-mgs` to match. The command-line import writes into the working directory, the folder your Terminal window is sitting in, which the command `pwd` prints, unless `--output-dir` names a folder, so the first command points it at the project's `Analyses` folder to match the Import Center. In the second command, `--by-classifier` and `--tool naomgs` take reads from an NAO-MGS result, `--result` names its folder, `--sample` and `--accession` pick one sample and one reference record, and `--output` names the file, which lands in the working directory too. Copy the exact sample name from the `sample` column of a table saved with **Export**.

Extraction for NAO-MGS selects by accession, not by taxon, and on the fixture the command writes 4 reads. The **Extract Reads…** button also keeps only the reads assigned to the selected taxon, so it can return fewer reads than the command when one accession holds reads of several taxa, because each read in the table carries its own taxonomy identifier. `KU048583.1` is a Rotavirus A record.

`lungfish-cli nao-mgs summary <file>` prints the top 20 taxa of a results file without a project, but it pools every sample into one total and names only the first, a known defect recorded as [nao-mgs summary names one sample](../appendices/troubleshooting.md#defect-naomgs-summary). Use the project import for per-sample counts.

## Next

Continue to [Novel Virus Diagnostics](09-novel-virus-detection.md), the last import in this part, which works from assembled [contigs](../../GLOSSARY.md#contig), longer sequences stitched together from overlapping reads, rather than single reads and suits the hunt for a virus no database names exactly. [BLAST Verification](06-blast-verification.md) explains the verdict that **Verify with BLAST…** returns.
