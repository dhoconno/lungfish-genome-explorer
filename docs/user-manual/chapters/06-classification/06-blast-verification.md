---
title: BLAST Verification
chapter_id: 06-classification/06-blast-verification
audience: bench-scientist
prereqs: [06-classification/02-running-kraken2]
estimated_reading_min: 24
task: Send a sample of a classifier's reads to NCBI BLAST and read the verdict it comes back with.
tags: [classification, blast, verification]
tools: [blast]
parameters_refs: [classify.blast-verify]
entry_points:
  - "Taxonomy viewport action bar > BLAST Verify"
  - "Right-click a taxon in the taxonomy viewport > BLAST Matching Reads..."
  - "CLI: lungfish-cli blast verify --kreport <kreport> --source <fastq> --kraken-output <kraken> --taxid <taxid>"
shots:
  - id: blast-verify-popover
    caption: "The Verify via NCBI BLAST popover open over a taxonomy row, showing the Reads to submit slider, the warning that reads leave the app for NCBI, and the Run BLAST button."
  - id: blast-results-drawer
    caption: "The BLAST Results drawer after a verification, showing the summary bar with its supporting and contradicting counts and confidence word, above the per-read rows in their six default columns."
illustrations: []
glossary_refs: [accession, bit-score, blast, coverage, e-value, kraken2, kreport, nt-database, percent-identity, query-coverage, read, read-classification, rid, taxon, taxonomic-rank]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

A [classifier](../../GLOSSARY.md#read-classification) such as [Kraken 2](../../GLOSSARY.md#kraken2) names the organism each [read](../../GLOSSARY.md#read) came from by matching short stretches of its sequence, called k-mers, against a reference database installed on your own machine. A k-mer is a fixed-length window of sequence, usually around 31 bases in a classifier database. That database, which you downloaded and installed in [Running Kraken 2](02-running-kraken2.md), is the whole of what the classifier knows, and it is built from pathogen sequence rather than from everything. If it does not hold the organism your sample actually contained, the classifier cannot report that organism. It reports the nearest relative it does hold, and it gives you no warning that it did so.

BLAST verification is the second opinion on that call. [BLAST](../../GLOSSARY.md#blast) is a search service NCBI runs over the public sequence collection, which is far larger than any database a classifier ships with. Given one sequence, BLAST normally returns a ranked list of every database record that resembles it, and leaves the interpretation to you. Lungfish Genome Explorer (LGE) asks a smaller question. It takes a sample of the reads one classifier assigned to one [taxon](../../GLOSSARY.md#taxon), which is a named group at any rank from species up to kingdom, and for each read it asks only whether the best public match names the same organism the classifier did.

Those reads travel over the internet to NCBI. Only the reads for that one taxon are sent, so verification checks a small sample rather than repeating the whole analysis, and the Before you start section below says exactly what leaves your Mac.

The answers roll up into one word. LGE counts each read that came back with a good match as supporting the classifier, when the match names the same organism, or contradicting it, when the match names something else. A good match here means a read that passed the per-read Verified rule, whose three numbers the Reading the results section gives. A read with no good match counts as neither, so the share is supporting divided by supporting plus contradicting.

| Share of supporting reads | Word |
|---|---|
| 80 percent and above | **Supported** |
| 40 percent up to but not including 80 | **Mixed** |
| Below 40 percent | **Unsupported** |
| No read produced a good match | **Inconclusive** |

Inconclusive is not a failure of the sample. It usually means the reads were too short or too poor for the search to settle anything.

Treat the word as a strong second signal rather than a final answer. NCBI's collection is broad but it is not complete, twenty reads is a small sample and can be unlucky, and a read from one organism can match a close relative well enough to count as supporting. What this asks of you in practice is a habit. When a classification surprises you, verify it before you act on it, and read the per-read rows rather than the summary word alone.

## Why you would do this

Verification costs you a wait while the reads travel to NCBI and the answer comes back, and you can only run it on one taxon at a time, so the point is to spend it where a second opinion changes what you would do next. Four situations reliably qualify.

An unexpected organism in a familiar sample type is the clearest one. A classifier that lacks the true source assigns the reads to a related organism it does hold, and that wrong name often belongs to the same genus or family, two levels of [taxonomic rank](../../GLOSSARY.md#taxonomic-rank) just above species. Reads landing on a close relative's record rather than the true source is the shape of the error. BLAST usually catches this, because the public collection holds the relative and the true source both, so the reads land on whichever one they really came from.

A low-abundance hit that is about to drive a decision is the second. Abundance here means the number of reads assigned to a taxon, not a concentration you measured at the bench, and a few dozen reads out of the millions in a sequencing run is fragile evidence. The [Running Kraken 2](02-running-kraken2.md) chapter's advice to hold the long tail, meaning the many taxa that each carry only a handful of reads, to a read-count threshold you set in advance leaves you with exactly the hits BLAST is worth spending on.

The third is a disagreement between two classifiers run on the same sample. BLAST settles it by agreeing with one of them, or with neither. The fourth is a check before you report a result to someone else. That one is the cheapest of the four and the one people skip.

The worked example in this chapter runs against the reads from SRR36291587, which is a public sequencing run identifier at NCBI, holding SARS-CoV-2 data. It picks up after the Kraken 2 run in [Running Kraken 2](02-running-kraken2.md), where the taxon carrying the most reads is *Severe acute respiratory syndrome coronavirus 2* (SARS-CoV-2). That is a case where you already expect the answer, which makes it a good first verification to read, because you can tell a working check from a broken one. A viral example is used here rather than the human one this manual usually reaches for because the classifier databases are pathogen databases, so a viral sample is the only kind that uses every step of this feature.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. LGE creates the project's folders inside the one you picked and opens an empty project window, and the project takes the folder's own name.

This chapter uses the SRR36291587 SARS-CoV-2 reads. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The download is 21.7 MB compressed, and how long it takes depends on your connection. The rest of the fixture's files, along with background notes on where the data came from and how it is licensed, are on GitHub at the address below. Reading them is optional and nothing in this chapter depends on it.

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

You also need a finished classification open in its viewport, since verification starts from a result rather than from a FASTQ. A viewport is the panel that fills the LGE window and displays one result, and a classification opens in its own viewport when the run finishes. Run the Kraken 2 walkthrough in [Running Kraken 2](02-running-kraken2.md) first if you have not.

Two things make this chapter different from the rest of the classification chapters. There is no plugin pack to install and no database to download, because the search runs on NCBI's machines rather than yours. In exchange, the reads you verify leave your Mac. What LGE sends is the sequence of each selected read and the read's own identifier, and nothing else. No sample name, no project, no file, and no part of the sample you did not select. NCBI holds a submitted search on its servers for a day or so and returns results to anyone holding the job's tracking number, so treat a submission as a disclosure. A sample under a data-use agreement, or one that carries human reads, should not be sent without first checking what that agreement allows. LGE offers no local BLAST, meaning a copy of the same search running on your own machine, so a sample you cannot send out is a sample you cannot verify this way.

The wait is not something LGE controls, because your job queues at NCBI behind everyone else's and how long that takes varies with how busy the service is. What LGE does control is how long it waits. It checks repeatedly for the result, first every 10 seconds, then every 15, and every 30 once the job has been running a while, and it gives up after ten minutes. A timeout reports the job's request ID, which is the tracking number NCBI assigns each search, so the result stays collectable from NCBI's own site afterwards. Both outcomes happened while this chapter was written, on the same reads an hour apart. One run finished and one timed out, which is normal rather than a sign that anything is broken.

## Procedure

The steps below describe the taxonomy viewport, which is where a Kraken 2 result opens. The same verification runs from the viewports of the other classifiers in this part of the manual, which are EsViritu, TaxTriage, NAO-MGS, and Novel Virus Diagnostics, and the section after the settings explains what each of those calls it.

1. Open the Kraken 2 result and select the taxon row you want to check. The result opens as a table of taxa, one organism per row, with the read counts beside each name. In the worked example the row to select is *Severe acute respiratory syndrome coronavirus 2*. Verification runs on one taxon at a time by design, so select a single row. You do not choose individual reads, since LGE picks them for you.

2. Click **BLAST Verify** in the action bar, the strip of buttons under the results table. Right-clicking the row and choosing **BLAST Matching Reads...** does the same thing. If the button is greyed out, hover the pointer over it and a tooltip names the reason, which is that no row or more than one row is selected.

3. Read the popover that opens, which is a small panel anchored to the button rather than a dialog that blocks the window, so clicking anywhere outside it cancels. For the worked example its title reads `Verify "Severe acute respiratory syndrome coronavirus 2" via NCBI BLAST`, and under the slider it warns that the reads leave the app for NCBI.
   <!-- SHOT: blast-verify-popover -->

4. Set the slider labelled **Reads to submit**, described in the next section, and click **Run BLAST**. If the taxon has only one read, LGE shows a line stating the fixed count instead of the slider, because there is nothing left to choose.

5. Watch the drawer at the bottom of the viewport, which is a panel that slides up from the lower edge. It opens on its **BLAST Results** tab and shows the three phases of the job in turn. Those are submitting the reads, waiting for NCBI, and parsing what came back. The waiting phase has no expected length, since it depends on NCBI's queue, and LGE ends it either with a result or with a timeout at ten minutes. The run also appears in the Operations panel, which you open from the toolbar's Operations button, titled `BLAST <taxon>`, so you can leave the viewport and come back to it.

The drawer is one of two tabs in the taxonomy viewport, sharing the space with Collections, which is a way of grouping taxa and has nothing to do with verification. The **BLAST Results** and **Collections** buttons in the action bar switch between them, and clicking the button for the tab already showing closes the drawer.

## Settings

The popover exposes exactly one setting. The bold label below ends with both a colon and a period. The colon is part of the label as the app draws it on screen, and the period closes the bold opening of the paragraph, so neither is a typing slip. Everything else about the search is fixed, and the last paragraphs of this section say what those fixed values are so you can record them in a methods section.

**Reads to submit:.** Sets how many of the taxon's reads are sent to NCBI to be checked against `nt`, NCBI's general nucleotide collection, so more reads give a firmer answer and take longer. The default is 20, which is enough for the supporting share to mean something, whereas a sample below about ten reads swings so far on a single read that the band it lands in tells you little. The slider runs from 1 to 50, and when the taxon holds fewer than 50 reads the taxon's own count becomes the slider's maximum, since LGE cannot send reads that do not exist. Lower it for a quick check on an abundant taxon, and raise it when the first answer comes back Mixed and you want the split resolved. On the command line this is `--reads`, which accepts 1 to 100 there rather than stopping at 50, because a scripted run can be left to wait while a window cannot. Either limit gives the same kind of answer, so the difference does not change how you read a result.

Which reads you get is not a setting, but it is worth knowing. LGE takes the longest reads first, up to five of them or a quarter of the sample, whichever is smaller, and fills the rest at random. A long read carries more sequence for the search to work with, while random picks keep the sample from being one unrepresentative corner of the data. The NAO-MGS viewport is the exception, because that pipeline maps reads to a reference genome. It spreads its picks across quarters of that genome instead, so its sample covers the whole genome rather than only its best-covered stretch.

The rest of the search is set for you and neither the popover nor the command line exposes it. The program is `blastn`, which compares nucleotide sequence against nucleotide sequence and is the right program for sequencing reads. LGE selects it and runs it for you, and there is nothing to type. The database is [`nt`](../../GLOSSARY.md#nt-database), the same general nucleotide collection named above. Each read gets at most five hits back, a hit being one database record that matched, which is why an expanded read row never shows more than five.

One further parameter can be pushed through to NCBI, but only from the command line, using the `--extra-args` flag described in the last section of this chapter. It is a pass-through rather than a supported setting, and nothing in the window offers it.

## Reading the results

The drawer leads with a summary bar, which gives the overall result. It reads `BLAST for <taxon>: <n> supporting, <n> contradicting (<n> reads)`, followed by a ten-dot bar and the confidence word. The bar always holds ten dots however many reads you sent, so each dot stands for a tenth of the sample rather than a fixed number of reads. A filled circle is a supporting read, a diamond is a contradicting one, and a hollow circle is a read that settled nothing. The bar is also tinted to match the word, but the word itself carries the whole meaning, so you never need the colour to read the result.

<!-- SHOT: blast-results-drawer -->

One extra phrase can appear beside the word, reading `<n> with conflicting organisms`. Each read comes back with its own short list of matches, and this counts the reads whose list disagrees at the genus level, meaning the read matched several unrelated organisms at similar quality rather than landing cleanly on one. Genus is the level tested because matches within a genus are expected and matches across genera are not. As a rule of thumb, a quarter of your submitted reads or more is a high count. It tells you the reads themselves are ambiguous, which is a different problem from the classifier being wrong. It usually indicates a conserved region, meaning a stretch of sequence that has changed so little over evolutionary time that many species still share it, so a read from that stretch cannot distinguish them.

Below the summary sits one row per submitted read. The table nests each read's matches underneath it, and clicking the disclosure triangle at the left of a read's row expands it to show the hits ranked below its best one. Six columns are shown by default. Status is the icon at the left, which mirrors the Verdict value described below, Read / Accession holds the read's identifier on a parent row and the matched record's [accession](../../GLOSSARY.md#accession) on a child row, and Organism names what the hit was. The three numbers are Identity, E-value, and Bit Score.

[Percent identity](../../GLOSSARY.md#percent-identity) is the share of aligned positions where the read and the database record agree, counted only over the stretch that actually aligned. A read reported at 99.6 percent over 250 aligned bases disagreed at one of those 250 positions. On its own it is easy to misread, because it says nothing about how much of the read took part.

[E-value](../../GLOSSARY.md#e-value) is how many matches this good you would expect to see by chance, given how long the read is and how large the database is. Smaller is better. The scale is logarithmic, which means each step in the exponent is a tenfold change, so the gap between two e-values is far larger than the printed digits suggest. A value of `1e-30`, which is ten to the power of minus thirty, means chance alone would essentially never produce this match, while a value near `0.1` means chance alone plausibly would. The per-read Verified rule described below draws its line at `1e-10`.

[Bit score](../../GLOSSARY.md#bit-score) measures the same alignment's strength on a scale that does not shift with database size. That makes it the number to compare across two searches run months apart. It rises with both the length and the quality of the match, so a longer and cleaner alignment scores higher, and reading it means comparing it against the other hits for the same read rather than against a fixed number.

Five more columns are hidden until you ask for them, which are Accession, Coverage, Align Length, Tax ID, and Verdict. Right-click the column header, which on a trackpad means clicking it with two fingers, and a menu of the column names appears with a tick beside each one already showing. Choose a name to show or hide that column. There is no menu-bar equivalent. LGE remembers your choice for every BLAST drawer from then on, including after you quit. The hidden Accession column repeats the accession the Read / Accession column already shows on child rows, and its use is that it also fills in on parent rows, so you can read every accession without expanding anything.

Two of the hidden columns are worth turning on the first time you read a drawer. Verdict shows LGE's own per-read call, which is Verified when the top hit clears all three thresholds, meaning at least 90 percent identity, at least 80 percent query coverage, and an e-value of `1e-10` or smaller. It reads Ambiguous when a hit came back but fell short of any of those three, Unverified when nothing significant came back at all, and Error when the search failed for that read. Those are the numbers behind the good match that decides the summary word.

The other is [query coverage](../../GLOSSARY.md#query-coverage), the share of the read that took part in the alignment.

Coverage is the number that stops a high identity from misleading you. Ninety-nine percent identity across a third of the read is much weaker evidence than 95 percent across all of it.

Right-clicking a row offers Copy Sequence as FASTA, Copy Read ID, and Copy Accession, plus Expand All and Collapse All. Two buttons sit along the bottom of the drawer. **Open in NCBI BLAST** opens the full result on NCBI's own site in your browser, where every hit is available rather than the five LGE kept, and **Re-run BLAST** reopens the popover so you can set the read count again before it submits a fresh sample. Re-running is the move after a timeout, and it is also how you get a second sample when the first one came back Mixed. **Export** in the summary bar writes the table as CSV or TSV through a Save dialog, covering every read and every hit whether or not the rows are expanded. Both formats are plain text tables, CSV separating the columns with commas and TSV with tabs, and CSV is the one that opens cleanly by double-clicking it in a spreadsheet.

## What good looks like

Read the summary bar and the per-read organisms together, because either one alone can mislead you.

A verification you can rely on has a Supported word, and per-read rows that name the classifier's organism and clear the Verified rule's three thresholds comfortably, with identity and coverage in the high nineties and e-values far smaller than `1e-10`. The worked example below returned exactly that, with both submitted reads matching *Severe acute respiratory syndrome coronavirus 2* at 100 percent identity.

An Unsupported word is not automatically bad news about your sample, and what you do next depends on what the rows say. If they consistently name one other organism, the classifier probably assigned the reads to a relative it had in its database, and that other organism is your better answer. If they name a scatter of unrelated organisms with mediocre identities, the reads are probably uninformative rather than wrong. That happens when a read is low-complexity, meaning it repeats one or two bases over most of its length, or adapter-contaminated, meaning it still carries the short synthetic sequence the library preparation attached rather than sequence from the organism. The honest conclusion for such a taxon is that it is unresolved.

Two results deserve a second run rather than an interpretation. Inconclusive means no read produced a significant hit, which on short or poor-quality reads says more about the reads than about the taxon, so send more reads or verify a taxon with longer ones. Mixed on a small sample can be nothing more than sampling noise, since two supporting reads out of three is a 67 percent share and lands in the Mixed band on evidence far too thin to act on. Raise the slider and run it again before you read anything into it.

That warning applies to this chapter's own example. The reference run submitted 2 reads, not the default 20, because an earlier attempt at 5 reads timed out at LGE's ten-minute ceiling and the page needed a completed job to show. Two reads demonstrate the mechanics and nothing more. A two-read Supported verdict is not evidence about the sample, for exactly the reason the paragraph above gives. Leave the slider at its default of 20 for any verification whose answer you intend to use.

Finally, be honest about what a Supported verdict covers. It says the reads LGE sent match the organism the classifier named. It does not say the classifier's read counts are right, that the abundance estimate holds, or that a related organism is absent. Verification checks what the reads are, not how many of them there are.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the popover cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole verification runs headless, meaning with no window at all, by typing commands into the Terminal application.

One thing does live only here. Recovering a timed-out job by its request ID is a command-line and browser route, so a reader working in the window has no way to collect a timed-out result from inside LGE and should simply run the verification again from the popover.

The command needs three inputs the viewport assembles for you. Those are the [kreport](../../GLOSSARY.md#kreport) for the taxonomy tree, the per-read Kraken 2 output for the read identifiers, and the source FASTQ for the sequences themselves. The source FASTQ must be uncompressed. A compressed one has a name ending in `.fastq.gz`, and `gunzip reads.fastq.gz` writes the uncompressed `reads.fastq` beside it. Pointing `--source` at a `.gz` file does not report a clear error. It reports that no matching reads were found, which names the wrong cause, so check the extension first. The Kraken 2 output may be gzipped.

In the command below, the backslash at the end of each line tells the shell that the command continues on the next line. You can equally type it all on one line without the backslashes.

```bash
lungfish-cli blast verify \
  --kreport classification.kreport \
  --kraken-output classification.kraken \
  --source sars-reads.fastq \
  --taxid 2697049 \
  --reads 2 -v
```

`--taxid` picks the taxon, and its number comes from the kreport's seventh tab-separated column, or from the Tax ID column of the taxonomy table, which you turn on the same way you turn on a drawer column. In the fixture's kreport the fields run percentage, clade reads, direct reads, minimizers, distinct minimizers, rank code, taxid, name, so `S1` is the sixth field and `2697049` is the seventh.

`--reads` is the slider. `--include-children` also pulls in reads assigned to taxa below the one you named, such as the species inside a genus. `--max-concurrent` caps how many searches this process has running at the same time, defaulting to 1 to stay inside NCBI's usage limits. `--extra-args` forwards further NCBI parameters as `KEY=VALUE` tokens, for example `WORD_SIZE=11`, which is an advanced option covered by NCBI's own BLAST documentation rather than this manual. Adding `--format json` prints the summary as JSON, and `-v` adds the per-read table shown below.

The run above printed its inputs, then its progress, then this.

```
Verification Results

Taxon        : Severe acute respiratory syndrome coronavirus 2 (txid2697049)
Supporting   : 2/2 (top hit matches taxon)
Contradicting: 0/2 (top hit differs)
Inconclusive : 0 (no significant hit)
Ambiguous    : 0
Unverified   : 0
Errors       : 0
Confidence   : Supported
BLAST RID    : 9WZYE9M0014
Program      : blastn
Database     : nt
```

Two of those lines can look like the same thing. `Inconclusive` counts reads whose search returned nothing significant, and it is also the summary word when that is true of every read. `Unverified` is the per-read verdict for one such read. The first is a count and a summary, the second is a label on a single row.

The per-read table follows.

```
Per-Read Results

  PASS SRR36291587.1  Severe acute respiratory syndrome coronavirus 2  100.0%
  PASS SRR36291587.2  Severe acute respiratory syndrome coronavirus 2  100.0%
```

The `BLAST RID` is the [request ID](../../GLOSSARY.md#rid) NCBI gave the job, and the command prints a link built from it so you can open the full result in a browser. That identifier is what makes a timeout recoverable. An earlier run of the same command with `--reads 5` was still queued when LGE gave up at ten minutes, and it printed `BLAST job timed out after 10 minutes (RID: 9WZADAY9016)` with the same link, so the result was still collectable from NCBI afterwards.

LGE paces its own submissions whichever way you run it. It waits at least ten seconds between submissions and treats fifty sequences an hour as its ceiling, and on reaching that ceiling it waits rather than failing, until enough of the hour has passed for the next submission to fit. That hourly limit is a separate thing from the slider's maximum of 50, which applies to one search, so two full 50-read searches inside an hour will make the second one wait.

One habit belongs to the terminal alone. Verify the taxa that matter rather than looping over every row, and leave `--max-concurrent` alone unless you know why you are raising it.

## Where else verification starts

Every classifier viewport carries the same **BLAST Verify** button in its action bar and opens the same drawer, and the behaviour is identical everywhere. Only the wording of the right-click item changes.

| Viewport | Right-click item |
|---|---|
| Taxonomy, where Kraken 2 results open | **BLAST Matching Reads...** |
| EsViritu | **BLAST Verify...** |
| TaxTriage | **Verify with BLAST...** |
| Novel Virus Diagnostics | **Verify with BLAST...** |

NAO-MGS is the one that behaves differently. Rather than opening the popover, its right-click menu offers the read count directly. An abundant taxon shows **BLAST 20 Reads** and **BLAST 50 Reads**, a taxon of fifty reads or fewer shows an item naming its own count, such as **BLAST All 34 Reads**, and a taxon between 21 and 50 reads shows both the 20-read item and the all-reads one.

Novel Virus Diagnostics differs in what it sends. That pipeline has already assembled the reads into contigs, a contig being one longer sequence stitched together from many overlapping reads, so verification submits the selected contig's own sequence rather than a sample of reads. Its drawer still carries a confidence word, since it runs the same verification summary.

The 12S metabarcoding viewport is the one that drops the word. That viewport identifies animal species from a short stretch of the mitochondrial 12S gene, and it BLASTs the sequences it could not match against its local reference set. Its drawer shows a plain `BLAST results for <name>` heading instead of a confidence word, because a single unmatched sequence has no supporting share to compute.

## Next

Continue to [Running Freyja](07-running-freyja.md), which estimates how much of each viral lineage a mixed sample holds, or to [Novel Virus Diagnostics](09-novel-virus-detection.md) for the contig-level BLAST path this chapter has referred to. To go back to the classification that raised the question, return to [Running Kraken 2](02-running-kraken2.md) or [Running EsViritu](03-running-esviritu.md).
