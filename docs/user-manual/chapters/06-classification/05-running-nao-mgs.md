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
    caption: "The file hint on the NAO-MGS Results card reads virus_hits_final.tsv.gz or _virus_hits.tsv.gz."
  - id: nao-mgs-import-sheet
    caption: "After you choose a file with Browse…, Validation in the NAO-MGS Import sheet shows Valid NAO-MGS results and names the source file."
  - id: nao-mgs-result-viewport
    caption: "With All Samples selected, the Samples and Taxa cards summarize the imported result and the table lists each taxon once per sample where it appears."
  - id: nao-mgs-taxon-detail
    caption: "The selected taxon shows a Taxid line with unique and total read counts and an accession count, and each miniBAM panel shows a depth curve above the stacked reads."
illustrations: []
glossary_refs: [accession, bam, bit-score, blast, bundle, fastq, fragment, mate, metagenomics, minibam, nao-mgs, operations-panel, paired-end, pcr-duplicate, percent-identity, provenance, checksum, read, read-pair, taxon, taxonomy-id, unique-reads, viewport, library-prep, tsv, terminal, negative-control, contig, lowest-common-ancestor]
features_refs: [classify.nao-mgs]
fixtures_refs: [naomgs]
brand_reviewed: true
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) imports a finished NAO-MGS table so you can review the reads behind each match by sample. A [read](../../GLOSSARY.md#read) is a sequence recorded by the sequencer.

[NAO-MGS](../../GLOSSARY.md#nao-mgs) is a metagenomic surveillance pipeline built by SecureBio. A pipeline is a chain of programs that run in order. [Metagenomics](../../GLOSSARY.md#metagenomics) sequences genetic material from a mixed sample. Surveillance uses repeated sampling, here of wastewater, to track what circulates in a population and sometimes detect pathogens before cases are reported.

The pipeline aligns reads against a fixed collection of viral genomes, its reference. Aligning a read means finding where it matches a reference sequence. Each row in the NAO-MGS table records where a read or a [read pair](../../GLOSSARY.md#read-pair) matched the reference. A read pair contains two reads from one [fragment](../../GLOSSARY.md#fragment), a piece of DNA. [Paired-end](../../GLOSSARY.md#paired-end) sequencing reads that fragment from both ends. LGE counts each aligned read as one hit, so a pair adds two hits when both reads align. The NAO-MGS table holds only viral [taxa](../../GLOSSARY.md#taxon), named groups of organisms. LGE groups hits by taxon and sample, keeping the reads behind each row. The [viewport](../../GLOSSARY.md#viewport) is the main area of the window for one result.

The combined table is `virus_hits_final.tsv.gz`. A [TSV](../../GLOSSARY.md#tsv) is a text table with tabs between columns. Gzip compresses files so they take up less space. LGE opens it as supplied. Newer versions of the pipeline write one file per sequencing lane, each ending in `_virus_hits.tsv.gz`. A lane is a channel on a flow cell, the slide a sequencer loads DNA onto.

## Why you would do this

Before acting on a match, check how many reads support it and where they align. The practice table has 29 columns and covers several samples.

[Library preparation](../../GLOSSARY.md#library-prep) makes DNA ready for sequencing. When it includes PCR, a reaction that copies DNA in repeated cycles, reads from extra copies of the same fragment are called [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). Ten copies of one fragment can give the same hit count as ten independent fragments. Compare **Hits** with **Unique Reads**, the count after probable copies are set aside. A pileup stacks reads at their matching positions on the reference.

## Before you start

LGE needs an open project to save the result. If you see **No Project Open**, open a project and try again. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup. This import needs no plugin pack, a set of tools LGE installs on request.

The NAO-MGS wastewater fixture is a practice data set with five samples in one combined table. A demo project is a ready-made example project LGE downloads for you. Download Pathogen Detection through **Help > Demo Projects…**, as shown in the [demo projects guide](../01-foundations/06-the-lungfish-project.md#demo-projects). The file is `virus_hits_final.tsv.gz` in `~/Documents/LGE Demo Projects/Pathogen Detection.lungfish/Practice Data/naomgs` by default, where `~` is your home folder. You can also download it from the [Tests/Fixtures/naomgs](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/naomgs) folder.

The import needs an internet connection to fetch references from the US National Center for Biotechnology Information (NCBI). For each taxon in each sample, LGE downloads the reference sequences for the five records with the most unique reads. The first import on a Mac also downloads NCBI's taxonomy names.

## Procedure

### Open the NAO-MGS Results card

1. Choose **File > Import Center…** (Cmd-Shift-I).
2. Click the **Classification Results** tab.
3. Click **Import…** on the **NAO-MGS Results** card, or drag the file onto it.

The card's file hint reads `virus_hits_final.tsv.gz or _virus_hits.tsv.gz`.

<!-- SHOT: nao-mgs-import-card -->

### Choose the results and check the validation

**Import…** opens **NAO-MGS Import**, a sheet, or dialog attached to the top of the window. **Validation** checks the header, the first line of column names.

1. Click **Browse…**.
2. Select the combined table or, for a run with one file per lane, the folder that holds them. For the fixture, select `virus_hits_final.tsv.gz`.
3. Confirm the source file name under **Valid NAO-MGS results**. A green checkmark confirms the header format.

    <!-- SHOT: nao-mgs-import-sheet -->

4. If the folder holds more than one matching file, compare **Files found** with the lane file count you expect.

For a folder, LGE counts files whose names contain `virus_hits` and end in `.tsv` or `.tsv.gz`. If more than one file matches, **Files found** shows the count. LGE checks the header of the first matching file by name and shows that file as the source. LGE imports the lane files together. If you choose one file, LGE checks that file alone.

If the header fails the check, **Validation** shows a warning triangle and the reason. **Run** stays disabled. To correct your selection, use **Browse…**.

### Import and open the result

1. Click **Run**.
2. Wait for the `NAO-MGS Import` row to finish in the Operations Panel, which lists running and finished tasks. The downloads can take time.
3. Double-click the result under `Analyses` in the sidebar, the list of project files and results on the left.

`lungfish-cli` is LGE's command-line interface (CLI) for running tools in [Terminal](../../GLOSSARY.md#terminal), the macOS app for entering commands. LGE runs `lungfish-cli import nao-mgs` for you. On the `NAO-MGS Import` row in the Operations Panel, **Copy CLI Command** copies the command and **Cancel** stops the job. The project guide covers [the Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) and job status.

LGE combines the sample imports and looks up each [taxonomy identifier](../../GLOSSARY.md#taxonomy-id), the number NCBI assigns to a taxon. The names file on your Mac maps `28875` to Rotavirus A.

LGE saves a new folder under `Analyses/` named `naomgs-` plus the input name, giving `naomgs-virus_hits_final` for the fixture. The project guide shows [where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) in the project.

The result is a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item. It holds summaries by taxon, downloaded references and one [BAM](../../GLOSSARY.md#bam) file per sample. LGE builds the BAM file, which records where reads match the reference, from the table's read sequences and positions. Keep the table for reimport. The bundle holds no copy.

## Settings

The **NAO-MGS Import** sheet has no settings. The Import Center always downloads references from NCBI. The command-line import has three flags of its own. A flag is an option that starts with two dashes and changes how a command runs. `--sample-name` changes the name recorded in the result and used for its folder. `--no-fetch-references` skips reference downloads. `--output-dir` specifies the folder that receives the result. The command-line section below links to the full flag list.

## Reading the results

Use the table to compare samples and the detail pane to inspect reads.

### The summary bar and the sample filter

**Samples** counts the samples in view, including controls, samples run alongside the others to check the laboratory work. Four of the fixture's samples are named for wastewater sites. The fifth, ending in `Water_20260323`, is named like a water blank, a control that uses water in place of a sample. **Taxa** counts each distinct taxon once across the samples in view. The fixture shows 5 samples and 4 taxa, with more rows because the table lists a taxon once per sample where it appears.

To focus on particular samples, click **All Samples** or the current count, such as **2 of 5 Samples**, and choose which samples to show. The whole viewport follows the selection.

<!-- SHOT: nao-mgs-result-viewport -->

### The taxon table

**Hits** and **Unique Reads** count individual reads. A [mate](../../GLOSSARY.md#mate) is one of the two reads in a pair.

| Column | What it holds |
|---|---|
| **Sample** | The sample the row belongs to |
| **Taxon** | The organism name, or `Taxid N` when NCBI's taxonomy names file has no name for that number |
| **Hits** | Aligned reads assigned to the taxon in that sample |
| **Unique Reads** | Reads left after probable PCR copies are set aside |
| **Refs** | Number of distinct reference [accessions](../../GLOSSARY.md#accession), or permanent identifiers of database records, that reads matched. A value of 1 means every hit matched the same record. |

For **Unique Reads**, LGE sets aside probable copies within each sample and taxon. A pair is a probable copy when each read shares its reference, start position, strand and length with the read in the same position in another pair. A strand is one of DNA's two complementary chains. A read with no aligned mate is a probable copy if another read with no aligned mate shares those same features.

Independent fragments can occasionally share all these features, so a match signals a probable copy. The share of hits that are unique measures PCR copying within one sample and taxon. Use the unique count for read support. The unique share cannot tell you how much virus a sample holds.

In the fixture, IL_CHI_StickneyWS has 12 Rotavirus A hits from 8 unique reads, so 4 of the 12 are probable copies. The Rotavirus A row for CA_LosAngeles_County has 28 hits from 26 unique reads. The sample has more rotavirus reads on a separate row for Human rotavirus A, a taxon within Rotavirus A.

Sequencing depth here means the total number of reads from a sample. LGE lacks the original totals needed to adjust for depth. The action bar, the row of buttons along the bottom of the viewport, shows the selected row's share of all hits in view as a percentage of raw counts. More hits can reflect deeper sequencing. Wastewater dilution and differences in how much genetic material is recovered during sample preparation can also affect the counts.

To narrow the table, type in **Filter taxa…**. A column header's menu sorts or filters that column. Sample metadata, information you attach to describe a sample, appears in extra columns. See [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) for how to add it.

### The detail pane

With no taxon selected, **Total Hits** adds the hits for the samples in view, **Unique Taxa** counts distinct taxa, and a third card names or counts the samples. The **Top Taxa by Read Count** chart shows up to fifteen bars sized by **Hits**. Click a bar to select its taxon.

To inspect a match in one sample, select its row. The line below the name gives its taxonomy identifier, read counts and accession count. For Rotavirus A in CA_LosAngeles_County it reads `Taxid: 28875  •  26 unique / 28 total reads  •  7 accessions`.

An aligner is the program that matches reads to the reference. It can clip a read by leaving an unmatched end out of the alignment. LGE uses the first read's numbers for every aligned read in the NAO-MGS row, or the second read's numbers if the row has no first read. **Avg Edit Dist** averages the number of single-base differences from the reference, including gaps, places where a base is missing from one of the aligned sequences. Clipped ends are excluded from this count. Lower values mean fewer differences.

For **Avg Identity**, LGE divides the edit distance it uses by the full length of the same read, subtracts the result from one and averages the resulting percentages. Clipped bases count as matches, so even a read that aligns only in part can have high identity. For **Avg Bit Score**, LGE averages the aligner's scores using the same counting rule, with higher scores indicating stronger alignments. [BLAST](../../GLOSSARY.md#blast) is a search of NCBI's public sequence collection. Its scores use a different scale, so you cannot compare **Avg Bit Score** with a BLAST score.

See **miniBAM Panels** for read positions. Each [miniBAM](../../GLOSSARY.md#minibam) panel shows every aligned read for that taxon and accession. The depth curve counts reads at each position. The pileup below it uses color to mark bases that differ from the reference. The panels show up to five accessions ranked by total hits, as in `miniBAM Panels (Top 5: 5 of 7 accessions)`. The note under the heading says unique read count. See [NAO-MGS panel order](../appendices/troubleshooting.md#defect-naomgs-order) for details on this known defect.

Each accession links to its GenBank record in NCBI's sequence database. The line beside it gives unique and total reads, then covered bases out of the reference length. The percentage is coverage breadth, the share of reference positions with at least one aligned read.

<!-- SHOT: nao-mgs-taxon-detail -->

LGE needs the full reference length to report coverage as a percentage. If LGE has no downloaded copy, for example after an import with `--no-fetch-references`, the line reads `coverage unavailable (reference not fetched)`.

A reverse-strand note under **miniBAM Panels** warns of false mismatches when stored reads face the opposite way from the reference. **Extract Reads…** stops with an error for that sample. A missing alignment file leaves its panels empty. For either note, reimport the table through **NAO-MGS Results**. The new result appears beside the original with a suffix such as `-2`. Work from the new result.

### The action bar

A classifier assigns reads to taxa. The shared classifier action bar has **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**. See [The action bar](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) for details on the controls. The information button opens **NAO-MGS Pipeline Info** for import details.

To check whether the best matches support the name on a row, choose **Verify with BLAST…**. LGE sends reads to NCBI for [BLAST](../../GLOSSARY.md#blast). Choose how many reads to send, 20 by default. LGE sends the first reads that lack duplicate marks, up to that count, from the taxon's five accessions with the most unique reads. BLAST searches all of `core_nt`, a version of NCBI's general DNA sequence collection, without filtering by organism.

The **BLAST Results** drawer, a panel that opens along the bottom of the viewport, shows one row per read and a verdict, the call on how well the reads support the row's name. The verdict needs NCBI Taxonomy, NCBI's catalog of named groups of organisms, which the first import on a Mac downloads. If it is missing, install it in the **Databases** tab of **Tools > Plugin Manager…**, where LGE manages optional tools and data. Without it, the drawer reads **Not judged** when at least one read has a close match. With no close match, the drawer reads **Inconclusive** with or without NCBI Taxonomy. See [BLAST Verification](06-blast-verification.md) for how to read the verdict.

To save the table as shown, review your filters and sort order, then click **Export**. The Export NAO-MGS Summary save sheet, a dialog at the top of the window, suggests `<name>_naomgs_summary.tsv`. For a table with several samples, the name uses the first one in alphabetical order. Rename it to reflect the samples covered. LGE runs `lungfish-cli nao-mgs export table` to save a TSV with your filters, sort and metadata columns. Open it in a spreadsheet.

To keep the reads behind a match, select its row and click **Extract Reads…**. LGE saves reads from the selected rows in a new [FASTQ](../../GLOSSARY.md#fastq) bundle. FASTQ is a text format that stores each read's sequence and a quality score for each base. Each read comes out in the direction the sequencer wrote it. See [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) for its controls.

## What good looks like

Use [the evidence checklist](01-what-is-classification.md#the-evidence-checklist) before reporting a match. **Unique Reads** estimates read support after probable PCR copies are set aside, counting one read per independent fragment or two when both mates align.

| What you see | How to read it |
|---|---|
| **Unique Reads** well below **Hits** | PCR copies may account for many hits. Use the unique count to describe read support. |
| Reads across several separated parts of the reference | This pattern supports the reported match. |
| Reads stacked on one short stretch | The match may rest on PCR copies, or on a short stretch the virus shares with other sequences, such as related viruses, host or bacterial genomes, or laboratory vectors. A laboratory vector carries genetic material into cells. |

The fixture's two Rotavirus A rows have 67 and 93 percent unique reads. Check their pileups as well.

A match at several sites carries more weight only when those samples were extracted and sequenced separately. Contamination, unwanted material from another source, can recur across samples that share a reagent or run. A blank carried through the run is one kind of [negative control](../../GLOSSARY.md#negative-control), a comparison for checking contamination here. LGE shows it as another sample. Find it by sample name and check whether the same taxon appears there. In the fixture, `Cressdnaviricota sp.` appears at two sites and in the sample named Water.

In the NAO-MGS table, each read is named by the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) of the viruses it aligned to, the most specific taxon that contains all of them. That can put one virus on two rows in a sample, as in CA_LosAngeles_County. Report broad matches at the level the row names. For example, `Cressdnaviricota sp.` names an unplaced member of a viral phylum, a broad rank in the system for grouping organisms. NCBI lists it under `unclassified Cressdnaviricota`.

**Verify with BLAST…** runs a second search on a subset of the same reads and can support the reported name. NAO-MGS reports names from its viral collection, so a virus outside that collection or a bacterium cannot appear by name. Start with the pipeline's entry in the [Tool Bibliography](../appendices/bibliography.md#imported-classification-results) to see which viruses it covers. For a broader survey, the [Running Kraken 2](02-running-kraken2.md) chapter covers classification beyond viruses.

To document your input, record the source file name and its [checksum](../../GLOSSARY.md#checksum), a fingerprint of the file's exact contents. Both are in the import's [provenance](../../GLOSSARY.md#provenance) record, which documents how the result was made. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read the record.

## On the command line

In Terminal, the first command imports the table and the second extracts reads by sample and accession. The Import Center also adds `--format json`, which prints the import's progress as JSON, a structured text format other programs can read. See [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) for help. The CLI Reference describes the import in [`import nao-mgs`](../appendices/cli-reference.md#import-nao-mgs) and extraction in [`extract reads`](../appendices/cli-reference.md#extract-reads).

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

If you downloaded the table separately, change the path after `import nao-mgs`. Here `--output-dir` saves to the project's `Analyses` folder. The default is the working directory, the folder Terminal is using. Type `pwd` to see its path.

For extraction, copy the exact `--sample` value from the `sample` column of a table saved with **Export**. The `--result` flag points to the result folder. The file named by `--output` lands in the working directory.

On the fixture, extraction by `--accession` writes 4 reads for `KU048583.1`, a Rotavirus A record. **Extract Reads…** also filters by the selected taxon's identifier, so it may return fewer reads when an accession has reads assigned to several taxa.

`lungfish-cli nao-mgs summary <file>` prints the top 20 taxa without a project. It pools all samples and names only the first, a known defect documented under [nao-mgs summary names one sample](../appendices/troubleshooting.md#defect-naomgs-summary) in the manual. Use the project import for per-sample counts.

## Next

Continue to [Novel Virus Diagnostics](09-novel-virus-detection.md) to use assembled [contigs](../../GLOSSARY.md#contig), longer sequences joined from overlapping reads, when no database names the virus exactly. [BLAST Verification](06-blast-verification.md) explains the verdict from **Verify with BLAST…**.
