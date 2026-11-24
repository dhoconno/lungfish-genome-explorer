---
title: BLAST Verification
chapter_id: 06-classification/06-blast-verification
audience: bench-scientist
prereqs: [06-classification/02-running-kraken2]
estimated_reading_min: 27
task: Send a sample of a classifier's reads to NCBI BLAST and read the verdict it comes back with.
tags: [classification, blast, verification]
tools: [blast]
parameters_refs: [classify.blast-verify]
entry_points:
  - "Taxonomy viewport action bar > Verify with BLAST…"
  - "Right-click a taxon in the taxonomy viewport > Verify with BLAST…"
  - "Selection > Table Row > Verify with BLAST…"
  - "CLI: lungfish-cli blast verify --kreport <kreport> --source <fastq-or-bundle> ... --kraken-output <kraken> --taxid <taxid>"
shots:
  - id: blast-verify-popover
    caption: "The Verify \"Simplexvirus humanalpha1\" via NCBI BLAST popover open over the sunburst of the SRR12486983 Viral result, showing the Reads to submit slider at 20 with its typed number field, the line saying the reads go to NCBI BLASTN core_nt and leave this Mac, and the Run BLAST button."
  - id: blast-results-drawer
    caption: "The BLAST Results drawer from an earlier run, under the sunburst of the SRR12486983 Viral result, with the summary bar reading 20 supporting, 0 contradicting, ten filled circles, and the verdict Supported, above per-read rows whose best record is Human alphaherpesvirus 1 at 100.0 percent identity."
illustrations: []
glossary_refs: [accession, bit-score, blast, bundle, clade, contig, e-value, esviritu, fastq, fragment, k-mer, kraken2, kreport, mate, nao-mgs, not-specific, nt-database, nvd, operations-panel, paired-end, percent-identity, provenance, query-coverage, read, read-classification, rid, taxon, taxonomic-rank, taxonomy-id, taxtriage, viewport]
features_refs: [classify.blast-verify, results.table-row-commands]
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: true
lead_approved: true
---

## What it is

A [read](../../GLOSSARY.md#read) is a short stretch of DNA sequence from a sequencer. A [classifier](../../GLOSSARY.md#read-classification) assigns reads to named groups of organisms. [Kraken 2](../../GLOSSARY.md#kraken2) looks up [k-mers](../../GLOSSARY.md#k-mer), stretches exactly k bases long, in a table. The lookup is fast, but it can name the wrong organism when the source is missing from its database and a relative shares the same pieces. [Running Kraken 2](02-running-kraken2.md#what-it-is) shows how the lookup works.

[BLAST](../../GLOSSARY.md#blast) is a sequence search method available online from NCBI, the United States National Center for Biotechnology Information. Use BLAST verification to check whether those reads match sequences from the group the classifier named. BLAST lines up matching stretches of a read with sequences in NCBI's public collection, base by base. It ranks the matching records by score. A record is an entry in the collection, such as a genome or gene. Each record returned is a hit.

Lungfish Genome Explorer (LGE) draws a small sample of reads the classifier assigned to a [taxon](../../GLOSSARY.md#taxon), a named group of organisms. LGE sends the reads to NCBI, checks whether their best matches belong to the selected group, and summarizes the evidence in one verdict when it can look up the selected group's species, as [Before you start](#before-you-start) explains. Use the verdict as a second check. The source organism may be missing from NCBI's collection, and a draw of twenty reads can miss a small group with different matches.

## Why you would do this

Verify a taxon when the answer could change your next step. An unexpected organism in a familiar sample may share sequence with a source missing from the classifier's database. BLAST can find a closer match if NCBI's collection includes sequences from the source. Shared sequences can still match several organisms equally well.

Check a taxon with few reads before acting on it. A few dozen reads out of millions give you little evidence to work with. When classifiers disagree, check which assignments the sampled reads support. Verification also gives you a second check before you report a result.

The example uses reads from a single sequencing run, listed in the Sequence Read Archive, NCBI's public archive of sequencing reads. Its [accession](../../GLOSSARY.md#accession), or catalog number, is SRR12486983. This check starts with its Kraken 2 result from [Running Kraken 2](02-running-kraken2.md), made with Viral, Kraken 2's database of viral sequences. The sample is corneal tissue from a person with herpes simplex keratitis, an infection of the cornea caused by herpes simplex virus. The species with the most reads in the result is *Simplexvirus humanalpha1*, the formal species name of herpes simplex virus 1 (HSV-1).

## Before you start

Open a project so LGE has a place to save the search. With no project open, **Verify with BLAST…** shows the alert **No Project Open** and sends nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for help opening a project.

For this example, open Pathogen Detection with **Help > Demo Projects…**. It holds run `SRR12486983`, so classify the reads against the Viral database. If you need the reads separately, see how to fetch `SRR12486983` in [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The [kraken-protocol-cornea fixture](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea) is the set of example data used in the Kraken 2, TaxTriage, and BLAST chapters. Its README gives the study source and terms of use. Follow the [Running Kraken 2 procedure](02-running-kraken2.md#procedure) to classify the reads.

Open the finished classification in its [viewport](../../GLOSSARY.md#viewport), the panel that shows one result. If you only have a [FASTQ](../../GLOSSARY.md#fastq) file, a text file of reads, classify those reads first. CZ ID is a web service for metagenomics, the study of genetic material from a mixture of organisms. Imported CZ ID results lack the read identifiers LGE needs to send a search.

You can start without a plugin pack, an optional set of tools LGE installs. A verdict needs one optional database download, NCBI Taxonomy, NCBI's catalog of named groups. LGE uses it to find the species of the row you verify, so that a record of another species whose name holds the row's name does not count for the row. Install it in the **Databases** tab of **Tools > Plugin Manager…**, the window that installs tools and databases. Without it, or when your copy does not list the row's taxon, LGE gives no verdict. The result reads **Not judged** and lists each read's best match with no counts for or against.

The search runs at NCBI. LGE sends each sampled read's sequence and identifier, its own tool name, and a contact address. LGE uses the identifier as stored in the reads file, dropping a trailing `/1` or `/2`. The identifier can include the run accession or the names of the sequencer and its flow cell, where sequencing takes place. LGE sends no separate sample or project details or other parts of the file.

Treat submission as a disclosure. LGE cannot call the reads back, and **Verify with BLAST…** has no local mode. A [request ID](../../GLOSSARY.md#rid) is the tracking number NCBI assigns each search. NCBI says it keeps a search for 36 hours and makes it available to anyone with its request ID. Before you click **Run BLAST**, check whether the data-use agreement, the contract that came with the data, allows you to send sequences and identifiers. Always check before sending reads from human samples, since reads assigned to a virus can still carry human sequence. The human cornea reads are already public in the Sequence Read Archive.

NCBI asks BLAST tools for a contact address in case it needs to reach you about a search. LGE uses its shared no-reply address by default. To use yours, choose **Settings…** (Cmd-,) from the menu named after the app and enter it in **Contact email (optional)** in the **NCBI BLAST** section of the **General** tab. LGE sends the address only to NCBI and keeps it out of project files, records, logs, and copied commands.

NCBI controls how long the search takes. Most searches in LGE's tests came back within about two and a half minutes, and a few took hours. The steps in [Follow a search that NCBI holds](#follow-a-search-that-ncbi-holds) explain how to check progress.

## Procedure

### Verify a Kraken 2 taxon

1. Click the Viral result under `Analyses` in the sidebar, the list at the side of the window. Its folder name starts with `kraken2-`. In the taxonomy viewport, type `humanalpha1` in **Filter taxa…** and click the *Simplexvirus humanalpha1* row. Verification checks one row at a time.

2. To open the verification settings, click **Verify with BLAST…** in the action bar, the row of controls under the table. You can also choose **Verify with BLAST…** from the row's right-click menu or **Selection > Table Row**. If the button is grayed out, check its tooltip, the message that appears when you point to the button.

3. Before sending reads, review the database and data-sharing notice in the popover, a small panel over the sunburst, the ring chart beside the table. The title reads `Verify "Simplexvirus humanalpha1" via NCBI BLAST`. The notice names `core_nt`, a version of NCBI's general DNA sequence collection, and says the reads leave this Mac. LGE may send them again if NCBI is slow, at most three sends in all.

    <!-- SHOT: blast-verify-popover -->

4. Leave **Reads to submit** at 20 and click **Run BLAST** or press Return.

5. Follow the search in the **BLAST Results** drawer, the panel that slides up from the bottom of the viewport. It first shows `Submitting reads to NCBI BLAST...` with **Cancel**, then may show **Sending reads to NCBI** with **Stop**. Once NCBI confirms the search, the drawer shows **Waiting for NCBI** and the request ID.

You can also follow the search on the `BLAST Simplexvirus humanalpha1` row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the list of tasks LGE is running or has run. Open it with **Operations > Show Operations Panel** (Cmd-Shift-P).

When NCBI answers, LGE saves the result and the drawer shows the verdict and one row per read. Start with the supporting and contradicting counts beside the verdict. If the verdict reads **Not judged**, the drawer shows no counts for or against and a line under the summary says why. See an earlier run's counts in [What good looks like](#what-good-looks-like) for an example. Click **BLAST Results** in the action bar to show or hide the drawer.

### Follow a search that NCBI holds

You can keep working in LGE or quit while NCBI queues or runs the search. LGE checks once a minute for the first ten minutes, then less often, until it checks every thirty minutes after six hours. A search can wait for hours even if a fresh copy would come back in a minute or two. LGE usually sends the same reads again after about three minutes and makes a third send after about six minutes. LGE uses the first answer and stops checking the other copies. If two searches in a row stay stuck after all copies go out, LGE pauses automatic repeat sends for an hour.

The drawer lists the request IDs. Once LGE has sent all automatic copies, the heading changes from **Waiting for NCBI** to **Still waiting at NCBI**.

While a search is pending, use these controls:

| Control | When to use it |
|---|---|
| **Check Now** | Ask NCBI for an update. A result that finishes after a long wait can take up to half an hour to appear on its own. The button is gray while LGE is sending and for a minute after a check, because NCBI asks for at most one check a minute. |
| **Send Again** | Send the same reads as another search. The button is gray while automatic copies are still due. |
| **Stop** | Pause LGE's checks. NCBI may still finish the search. Click **Resume** to check again while NCBI holds it. |

If you quit, LGE checks again when you reopen it. When the answer comes back, click **Results** on the Operations Panel row to open the Kraken 2 result, then select the original taxon. If the drawer says NCBI no longer holds the search or could not finish it, use **Send Again**. If NCBI is refusing new searches, the drawer and Operations Panel show when LGE will try again.

### Verify from another classifier viewport

From every classifier viewport, LGE searches all of `core_nt` with no filter and judges reads by the same rules. **Verify with BLAST…** is in the action bar and the row's right-click menu in EsViritu, TaxTriage, NAO-MGS, and NVD, which are other tools for classification or virus detection.

What LGE sends depends on the viewport. A [fragment](../../GLOSSARY.md#fragment) is one piece of the sample's DNA. In [paired-end](../../GLOSSARY.md#paired-end) sequencing, both ends are read, giving two reads called [mates](../../GLOSSARY.md#mate). A [contig](../../GLOSSARY.md#contig) is a longer sequence assembled from overlapping reads. A [taxonomy ID](../../GLOSSARY.md#taxonomy-id), or tax ID, is the number NCBI assigns to a taxon. A reference sequence is the known sequence that reads are compared with. A duplicate is a read from an extra copy of the same fragment made while preparing the sample for sequencing. A unique read is a read left after duplicates are set aside.

| Viewport | What LGE sends | Before it sends |
|---|---|---|
| [Taxonomy](02-running-kraken2.md), where Kraken 2 results open | Random fragments, one read per fragment | The popover |
| [EsViritu](03-running-esviritu.md) and [TaxTriage](04-running-taxtriage.md) | The longest reads, five or a quarter of the request, whichever is smaller, then a random fill. EsViritu uses the row's sample. Both mates are judged and the pair counts once. | The popover |
| [NAO-MGS](05-running-nao-mgs.md) | LGE sends the first reads from the taxon's top accessions, up to five reference sequences with the most unique reads. It skips reads marked as duplicates and sends up to the number you choose in the popover. | The popover |
| [Novel Virus Diagnostics](09-novel-virus-detection.md) | The selected contig, judged against the taxon named by NVD's adjusted tax ID | A sheet titled **Run BLAST at NCBI?** |
| [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md) | Unresolved sequences from the Unresolved view | A sheet titled **Run BLAST at NCBI?** |

The 12S drawer displays `BLAST results for <name>` and gives no verdict. EsViritu, TaxTriage, NAO-MGS, and NVD find a row's species in NCBI Taxonomy, the download that [Before you start](#before-you-start) describes, as Kraken 2 does. Without it, or when its copy does not hold the row's species, LGE gives no verdict. The summary bar shows **Not judged**, and the line under the summary says why.

## Settings

**Reads to submit.** Sets how many reads LGE sends to NCBI, one per sampled fragment in the taxonomy viewport, with both mates possible in EsViritu and TaxTriage. The default is 20 because, when every read counts, switching one read between supporting and contradicting shifts the supporting share by 5 percentage points versus 10 for ten reads, though even that can change the verdict by crossing 40 or 80 percent. Lower it to leave room for other searches, since LGE submits at most 50 reads in new searches in any 60 minutes, or raise it when a Mixed verdict, between those cutoffs, rests on few counted reads. On the command line this is `--reads`.

| Control | Range and limits |
|---|---|
| Slider and number field | 1 to 50 reads. LGE brings typed values back into range. If the taxon has fewer than 50 reads, its count is the maximum. Below 20, that count is also the default. |
| Command line | Accepts up to 100, subject to the limit of 50 reads in new searches in any 60 minutes. |

In the taxonomy viewport, when the selected taxon is a species or a group above species, LGE draws randomly from fragments assigned to that taxon or any group below it. For a taxon below species, the draw covers its whole species because LGE judges at species level. Each eligible fragment has the same chance of being drawn. The same count on the same result draws the same reads. A larger draw includes the smaller draw, so 40 reads include the first 20.

For each fragment, LGE uses the mate with more k-mers matching the taxon in Kraken 2's per-read file, `classification.kraken.gz`. On a tie, it uses the mate with more k-mers matched to anything, then mate 1 if they still tie. This favors the mate with more Kraken 2 evidence for the taxon when that evidence differs. The rule also applies to a read [bundle](../../GLOSSARY.md#bundle), LGE's folder for one set of reads, with separate files R1 and R2 for the first and second mates, respectively. A merged read combines overlapping mates. An orphan is a read whose mate was removed. Either can be drawn like any fragment.

LGE uses `blastn`, which compares DNA with DNA, in NCBI's megablast mode, a fast setting for close matches that can miss distant relatives. The database `core_nt` is a version of NCBI's general nucleotide collection, [`nt`](../../GLOSSARY.md#nt-database). To speed searches, it leaves out some large chromosome assemblies of eukaryotes such as animals and plants. Virus records are outside those exclusions.

LGE keeps the best five records for the drawer. When LGE judges by taxonomy ID, as it does for every Kraken 2 result, it requests up to 500 records per read to check for ties. When LGE can judge an EsViritu or TaxTriage result only by organism names, it requests five records per read. NCBI drops matches with an [e-value](../../GLOSSARY.md#e-value) above `1e-10`, or 0.0000000001. The e-value estimates how many matches this good or better you would expect by chance.

LGE limits new submissions to 50 reads per rolling hour, the last 60 minutes. The app and `lungfish-cli`, LGE's command-line program, share that allowance even if you quit. **Re-run BLAST** counts as a new search. Repeat sends for slow searches have a separate allowance. LGE spaces contacts with NCBI at least 11 seconds apart. If you see `LGE's own limit stopped this search, and NCBI was not contacted.`, wait until the time shown or lower **Reads to submit** to fit the remaining allowance.

## Reading the results

Start with the rows under the summary bar. Check the label for each read's match. Verified means the best match is close enough across enough of the read to count for or against the selected taxon. Check which way each Verified read counts. Use those counts to interpret the batch verdict. The example figures below come from an earlier run on the cornea sample, before LGE asked NCBI for 500 records per read, so a run today can differ.

<!-- SHOT: blast-results-drawer -->

### The per-read table

The main row for each read shows its best record. To compare other matches, click the small arrow on the left. It reveals up to four more records in score order, for at most five per read. Six columns show by default.

| Default column | What it shows |
|---|---|
| Status | Verified is a filled circle with a checkmark. Unverified is a filled circle with a cross. Ambiguous is a triangle with an exclamation mark. Error is an octagon with an exclamation mark. |
| **Read / Accession** | The read identifier on the main row and the NCBI accession on an expanded row. |
| **Organism** | The source of the matched record. |
| **Identity**, **E-value**, and **Bit Score** | The match statistics explained below. |

### Percent identity

An alignment lines up two sequences base by base, with gaps where one has extra bases. [Percent identity](../../GLOSSARY.md#percent-identity), the share of aligned positions with the same base, appears under **Identity**.

| Identity | How to read it |
|---|---|
| In the 80s | Below the identity requirement for Verified. |
| 90% to 95.9% | Meets the identity requirement. The read may come from a fast-changing virus or from a variant absent from NCBI's records for the species. A few sequencing errors can also lower identity. Check how much of the read aligned and compare organism names among the top records. |
| 96% to 100% | Meets the identity requirement. A close relative can match this well over one short read, so compare organism names and scores among the top records here too. |

In the example run, cornea reads were at most 76 bases long, and trimming removed poor-quality ends from some. One mismatch across 76 aligned positions gives 75 divided by 76, or 98.7 percent identity. Identity covers only aligned positions. A read with a perfect match over its first 50 bases and no match over the other 26 still shows 100 percent identity.

### Query coverage

The read you ask about is the query. [Query coverage](../../GLOSSARY.md#query-coverage) is the aligned length on the read divided by the read's length, using one alignment at a time. A 76-base read aligned from base 1 to base 57 has 75 percent coverage.

Read identity and coverage together. Ninety-nine percent identity across a third of the read leaves two thirds of the sequence unexplained. A match at 95 percent identity across the whole read accounts for more of it. To see coverage and the per-read label, right-click any column header and show **Coverage** and **Verdict**.

### E-value

A smaller e-value means fewer matches this good or better are expected by chance, given the read length and database size. At 0.1 you would expect one such chance match across ten comparable searches, on average. At `1e-30`, or 10 to the power of minus 30, the expected count is tiny. Each step in the exponent changes it tenfold. The expected count at `1e-30` is a billion billion times smaller than at `1e-12`.

Longer matches can give smaller e-values. In the example run, reads that matched HSV-1 perfectly came back at `1e-29` over 76 bases and `4e-29` over 75 bases, well below the `1e-10` cutoff. A sequence shared by several species can give a very small e-value for each of them.

### Bit score

The [bit score](../../GLOSSARY.md#bit-score) grades one alignment. It rises with matches and falls with mismatches and gaps. Unlike the e-value, it is independent of database size. Compare scores for the same read to see whether several records share the top score. If one record scores 141 and another scores 100, check the higher-scoring record's organism, identity, and coverage. In the example run, perfect matches scored 141 over 76 bases and 140 over 75 bases.

### The per-read label

The Status icon and **Verdict** column show the per-read label. It grades the quality of the best match, with the placement exceptions in the next section. LGE checks the first alignment of the best record against the Verified thresholds. LGE normally uses the first record NCBI returns. If LGE judges by taxonomy ID and records inside and outside the group tie for best, LGE uses the first tied record inside the group when NCBI lists an outside record first. If LGE judges by organism names alone, it uses the first record NCBI returns.

| Label | Rule |
|---|---|
| **Verified** | At least 90% identity, at least 80% query coverage, and an e-value of `1e-10` or smaller. Every returned record already meets the e-value requirement. |
| **Ambiguous** | A record came back but missed a Verified threshold, or LGE could not place the read. |
| **Unverified** | NCBI returned no record under these search settings. **Organism** says "No significant hit". |
| **Error** | NCBI's answer had no usable entry for the read. **Organism** says "No BLAST result". LGE still judges the rest of the batch. |

A Verified read can count as supporting or contradicting. Verified describes the strength of the match. The taxon check asks where the match belongs.

### Supporting, contradicting, and ties

LGE checks for ties only when it judges by taxonomy ID, as it does for every Kraken 2 result. When it judges by organism names alone, LGE uses the first record NCBI returns.

A Verified read is **supporting** if a best match belongs to the selected taxon's [clade](../../GLOSSARY.md#clade), the group and everything below it in the [Kraken 2 report](../../GLOSSARY.md#kreport), a table of counts per taxon, and in NCBI Taxonomy. LGE checks all records tied for best among those NCBI returned. A record ties if its bit score matches the first record's exactly as printed in NCBI's reply. A stretch of 76 bases shared across HSV-1 genomes can tie across many HSV-1 records. A Verified read is **contradicting** if the best match, or all tied best matches, are outside the clade and the result meets none of the placement exceptions below.

LGE judges a species or any group below it at species level. In the EsViritu, TaxTriage, NAO-MGS, and NVD viewports, the exception is a species whose scientific name, its formal name in NCBI Taxonomy, ends in `sp.`, NCBI's catch-all for records whose species nobody named. A row below it is judged at its own taxon and the groups below that, and a row on the `sp.` species itself is judged at that taxon alone.

A strain is a variant within a species, so a match to another strain of the same species supports the selection. For a group above species, such as a genus, which groups related species, a match to any species in that group can support the selection. With HSV-1 selected, matches to Human alphaherpesvirus 2 or Human gammaherpesvirus 4 are outside the clade.

LGE checks taxonomy IDs first. If neither the report nor NCBI Taxonomy lists a record's ID, LGE checks whether the organism name contains the full name of any taxon in the clade. As a rule, a name that the scientific name of a taxon outside the clade also contains does not count, so a record of Woolly monkey hepatitis B virus does not join a Hepatitis B virus row by name. The report lists Human alphaherpesvirus 1 (taxonomy ID 10298) below *Simplexvirus humanalpha1*, so a record containing that full name can also join the species clade by name.

When a tie includes records inside and outside the clade, the read supports and shows an outline triangle. Point to it to see `Tied with <n> other records at the best score: <n> more in this taxon, <n> outside. NCBI returned <n>.`

LGE labels a read or fragment Ambiguous in any of these placement cases:

- NCBI returned all 500 requested records, every one ties for best, and none is in the clade. Otherwise, a read with no clade record among its tied best matches counts as contradicting if it is Verified.
- LGE judges by organism names alone because the best record or the row lacks a taxonomy ID, and the best record's organism name shares only its first word with the taxon's name. That word alone cannot distinguish Human alphaherpesvirus 1 from Human gammaherpesvirus 4.
- Both mates of a pair sent from EsViritu or TaxTriage are Verified, with one mate's best match inside the clade and the other's outside. The fragment counts as neither supporting nor contradicting.

Ambiguous, Unverified, and Error reads count as neither supporting nor contradicting.

### The summary bar and the verdict

When LGE gives a verdict, the bar reads `BLAST for <taxon>: <n> supporting, <n> contradicting (<n> reads)`, or `(<n> fragments, <m> reads)` when both mates went out. It also shows ten symbols and the verdict. If reads came back Error, it adds a count such as `2 with no BLAST result`.

A result that is **Not judged** has no counts for or against and no symbols. Its bar reads `BLAST for <taxon>: not judged, <k> of <n> reads with a significant hit. NCBI Taxonomy is needed to judge them.` where `<k>` is the number of Verified reads. The Operations Panel row for the search shows the words after the colon.

Divide the supporting count by the sum of the supporting and contradicting counts. LGE uses this share and the ties outside the clade to set the verdict. One supporting read and 19 Ambiguous reads give a 100 percent share. Compare the sum of the two counts with the number submitted to see how many reads the verdict rests on.

| Supporting share | Verdict |
|---|---|
| 80% and above, with at least one supporting read free of ties outside the clade | **Supported** |
| 80% and above, with every supporting read tied outside the clade | **Not specific** |
| 40% up to but not including 80% | **Mixed** |
| Below 40% | **Unsupported** |
| No read supporting or contradicting | **Inconclusive** |
| Reads count, but LGE cannot look up the row's species, so it gives no share | **Not judged** |

[Not specific](../../GLOSSARY.md#not-specific) means every supporting read fits at least one record outside the clade equally well. The bar adds a sentence such as `Every supporting read also matches other records equally, such as <name> and <name>. These reads cannot tell <taxon> apart from them.`

The ten symbols split submitted reads into rounded tenths. With 20 reads, each symbol represents two. A filled circle means supporting, a diamond means contradicting, and a hollow circle means neither.

Beside the verdict, `<n> also match other records equally` counts supporting reads tied outside the clade. LGE judges a read by organism names alone if its best record has no taxonomy ID. If LGE cannot look up the row's species in NCBI Taxonomy, or the row has no tax ID, it gives no verdict and the summary bar shows **Not judged**. When LGE judges a read by names alone, the bar adds a read to `<n> with conflicting organisms` if the five records have more than one first word across their organism names.

If the drawer says `NCBI searched <database>, not the <database> this search asked for.`, record the database NCBI actually used when you compare or report results. A line starting with `Collected` gives the time since the first send, the number of sends, and the request ID that answered.

### Columns, copying, and exporting

Five columns are hidden at first, **Accession**, **Coverage**, **Align Length**, **Tax ID**, and **Verdict**. Right-click any column header for a menu with a checkmark beside each one showing. Choose a column to show or hide it. LGE remembers the choice across drawers and after you quit.

FASTA is a text format with a name line followed by a sequence. To copy a sequence in this format, right-click its row and choose **Copy FASTA**. The menu also offers **Copy Name** for the read ID, **Copy Accession**, **Expand All**, and **Collapse All**.

**Open in NCBI BLAST** opens the result on NCBI's site. **Re-run BLAST** sends the same reads as a new search. To send more, reopen **Verify with BLAST…** and raise **Reads to submit**.

**Export** offers **Export as CSV...** for comma-separated text and **Export as TSV...** for tab-separated text. LGE runs `lungfish-cli blast export table` and shows it in the Operations Panel. The export writes one line for each record of each read, so count each read once when checking a Kraken 2 verdict.

The export's **Verdict** column holds the per-read label, which grades the quality of the best match with the placement exceptions. A read can show `verified` there and `contradicting` under Taxon Check. Taxon Check also uses `supporting` or `inconclusive`, and `not judged` for a Verified read in a result that is **Not judged**. The tied, tied_in_taxon, and tied_outside columns count ties, and Judged At says how LGE judged the result, `species` when it could look up the row's species and `rowTaxId` or `names` when it could not.

### Saved verifications

In the Kraken 2 result folder, LGE stores each finished verification under `blast-verifications`, with the reads sent, the result, and its [provenance](../../GLOSSARY.md#provenance), a record of how the result was produced. To reopen the latest verification, even after quitting LGE, select the taxon's row and click **BLAST Results**. In the other viewports, return to the row you verified. If you report a verification, keep the provenance, the counts, the number of reads sent, and the request ID.

## What good looks like

For a Supported verdict, check how many submitted reads counted and how many supporting reads tied outside the clade. Look for best matches in the clade with high identity across nearly the whole read and e-values far below `1e-10`. For a virus with a DNA genome and many genomes in NCBI's collection, such as HSV-1, expect a mismatch or two per read at most. A fast-changing virus with an RNA genome can give lower identity for the right species when no NCBI record matches your strain closely. Supported tells you that enough of the counted reads support the selected taxon under LGE's rules. Read counts, abundance estimates, and the presence of relatives are separate questions.

The example run on the cornea sample gave 20 supporting, 0 contradicting, ten filled circles, and a Supported verdict. Every best record was Human alphaherpesvirus 1 with 100 percent query coverage. Of those reads, 19 had 100.0 percent identity and one had 98.7 percent, a single mismatch in 76 bases. A flagged read tied with a laboratory construct, an engineered DNA molecule carrying a piece of HSV-1, and still supported the taxon. The 100 percent supporting share covered all submitted reads.

For Not specific, check the records named in the bar. A tie to a laboratory construct carrying the same sequence leaves the source unresolved. If another species ties, check whether the reads are spread across the genome or pile up in one shared stretch. Several reads overlapping the same stretch may repeat the same evidence. The coverage sparkline, a small chart drawn without axes or labels, shows how the reads spread along the genome in [EsViritu's results](03-running-esviritu.md#reading-the-results).

For Unsupported, look for a consistent alternative. If rows repeatedly name one other organism, compare identity, coverage, and ties before treating it as a candidate. If rows name many unrelated organisms, look at the read sequences. Reads with low complexity, meaning limited sequence variety or simple repeats such as a run of one base, can match the same repeat in many unrelated genomes at high identity, often with many ties, or find no match.

Reads that still carry adapter, a short synthetic sequence added during library preparation, when DNA is prepared for sequencing, may align to the organism over only part of the read. The adapter can match a laboratory construct or a vector, a DNA molecule used to carry a sequence into cells in the laboratory. Trimming adapter and removing low-complexity reads before classification helps prevent misleading matches.

For Inconclusive, check the per-read labels first. No read was Verified, so every read was Ambiguous, Unverified, or Error. An Ambiguous read may have a strong match LGE could not place. Short or poor-quality reads can give weak matches. In this search, even a perfect match shorter than about 40 bases falls short of the `1e-10` cutoff and comes back Unverified. A source organism can be too distant from every record in `core_nt` for megablast to find a match. If read length or quality is the problem, more reads help only if some are longer or cleaner. A longer sequence, such as a contig assembled from the reads, can give stronger evidence.

For Mixed, see how many reads counted before acting on the share. Two supporting reads out of three give a 67 percent share. To add evidence, reopen **Verify with BLAST…**, raise **Reads to submit**, and run again. After a 20-read search, up to 30 reads remain in the rolling hour, depending on what else you sent. The larger draw includes the original reads.

For **Not judged**, install NCBI Taxonomy in the **Databases** tab of **Tools > Plugin Manager…**, or update it if your copy does not list the row's tax ID, then run **Verify with BLAST…** again. The drawer still lists each read's best match, so you can read the organism names yourself.

## On the command line

You can skip this section if you work only in the window. These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, and every flag of `blast verify` is listed in [`blast verify`](../appendices/cli-reference.md#blast-verify) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"
RESULT="$PROJECT/Analyses/kraken2-<timestamp>"

# Verify HSV-1 (NCBI taxonomy ID 10298) in the Kraken 2 Viral result,
# including reads assigned below it, as the window does.
lungfish-cli blast verify \
  --kreport "$RESULT/classification.kreport" \
  --kraken-output "$RESULT/classification.kraken.gz" \
  --source "$PROJECT/Imports/SRR12486983.lungfishfastq" \
  --taxid 10298 --include-children \
  --reads 20 --format json \
  --result-dir "$RESULT"
```

Replace `<timestamp>` with the rest of the Viral result's folder name. The first two lines give the folder paths short names, `$PROJECT` and `$RESULT`.

`--kreport` names the Kraken 2 report. Taxonomy ID 10298 is the Human alphaherpesvirus 1 row, one level below *Simplexvirus humanalpha1*. Both rows hold 886,221 pairs, as [Running Kraken 2](02-running-kraken2.md#reading-the-results) explains. `--result-dir` saves the verification under `blast-verifications` in the result folder. LGE finds saved verifications by taxonomy ID. For this command, select Human alphaherpesvirus 1 to see the result.

`--kraken-output` names the per-read file used to choose mates by k-mer count. `--source` names the reads and can repeat. It accepts a `.lungfishfastq` bundle, whose files have assigned roles, or loose files in this order, R1, R2, then merged or single reads. `--format json` prints JSON, a structured text format other programs can read. Omit it for a readable summary that counts how many reads went as mate 2 and gives the BLAST verdict on a line labeled Confidence.

The command reads the NCBI Taxonomy you have installed and never downloads it. Without it, or when it does not list the taxon, the Confidence line reads `Not judged`, the summary gives a line that starts `Verification: NOT JUDGED`, and the JSON has `"confidence" : "notJudged"` and sets `supporting` and `contradicting` to `null`, JSON's word for no value.

The command draws reads assigned to the named taxon. Add `--include-children` to include taxa below it. Here all 886,221 pairs were assigned to 10298 itself. `--seed` takes a whole number that sets the random draw. The default is 0, the same seed LGE uses in the window.

The command waits for NCBI. With `--result-dir`, pending searches stay in the result folder. Use `lungfish-cli blast resume --output <folder>` to collect a pending result. `lungfish-cli blast in-flight` lists pending searches, and `lungfish-cli blast stop` stops LGE checking one. **Copy CLI Command** on the Operations Panel row copies the `lungfish-cli blast submit` command that sends the saved reads again.

## Next

Continue to [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md), which names the vertebrate species in a mixed sample by exact matching and sends its unmatched sequences to BLAST in the same drawer. To review the classification that raised the question, use [Running Kraken 2](02-running-kraken2.md) or [Running EsViritu](03-running-esviritu.md) as a guide.
