---
title: BLAST Verification
chapter_id: 06-classification/06-blast-verification
audience: bench-scientist
prereqs: [06-classification/02-running-kraken2]
estimated_reading_min: 18
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
    caption: "The Verify \"Simplexvirus humanalpha1\" via NCBI BLAST popover open over the sunburst of the SRR12486983 Viral result, drilled down to Orthoherpesviridae, showing the Reads to submit slider at 20 with its typed number field, the warning that reads leave the app for NCBI, and the Run BLAST button."
  - id: blast-results-drawer
    caption: "The BLAST Results drawer under the sunburst, drilled down to Orthoherpesviridae, of the SRR12486983 Viral result in the Detail | List layout, with the summary bar reading 20 supporting, 0 contradicting, ten filled circles, the word Supported, and 1 with conflicting organisms, above per-read rows whose top hit is Human alphaherpesvirus 1 at 100.0% identity."
illustrations: []
glossary_refs: [accession, bit-score, blast, clade, contig, e-value, k-mer, kraken2, kreport, nt-database, paired-end, percent-identity, query-coverage, read, read-classification, rid, taxon, taxonomic-rank, taxonomy-id, viewport]
features_refs: []
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

Classifiers such as Kraken 2 name a read by looking up short exact stretches of it in a table, which is fast but can mislead. Those stretches are [k-mers](../../GLOSSARY.md#k-mer), each exactly k bases long, and [Running Kraken 2](02-running-kraken2.md#what-it-is) shows how Kraken 2 looks them up. Its per-read output records how many of each read's k-mers matched each taxon, which matters for which reads get sent.

BLAST verification is a second opinion on a [classifier](../../GLOSSARY.md#read-classification)'s call. [BLAST](../../GLOSSARY.md#blast) is a search service that NCBI, the United States National Center for Biotechnology Information, runs over its public sequence collection. That collection is far larger than any database a classifier installs on your Mac, so it can name organisms the classifier never had a chance to report. Given one sequence, BLAST returns the database records that resemble it most, ranked from best to worst.

Lungfish Genome Explorer (LGE) uses BLAST to ask one narrow question. It takes a small sample of the [reads](../../GLOSSARY.md#read) a classifier assigned to one [taxon](../../GLOSSARY.md#taxon), a named group of organisms at any level from species up to kingdom. For each read it asks whether the best public match agrees with the name the classifier gave. Every answer then rolls up into one word, Supported, Mixed, Unsupported, or Inconclusive, which [Reading the results](#reading-the-results) defines along with every number behind it.

Treat the word as a strong second signal rather than a final answer. NCBI's collection is broad but not complete, the default of twenty reads shows what most of a taxon's reads are but can miss a small minority, and a read can match a close relative well enough to count as agreement. When a classification surprises you, verify it before you act on it, and read the per-read rows rather than the summary word alone.

## Why you would do this

Verification costs a wait and runs on one taxon at a time, so spend it where a second opinion would change what you do next. Four situations qualify.

The first is an unexpected organism in a familiar sample type. A classifier that lacks the true source assigns its reads to the nearest relative it does hold, and that wrong name usually sits in the same genus or family, the [taxonomic ranks](../../GLOSSARY.md#taxonomic-rank) just above species. The public collection usually holds both the relative and the true source, so the reads land on whichever they really came from.

The second is a low-abundance hit about to drive a decision, since a few dozen reads out of millions is fragile evidence. The third is two classifiers disagreeing about the same sample, which BLAST settles by agreeing with one of them or with neither. The fourth is a check before you report a result to someone else.

The worked example verifies the Kraken 2 Viral result from [Running Kraken 2](02-running-kraken2.md), made from run SRR12486983, the corneal sample from a person with herpes simplex keratitis. There the species holding the most reads is *Simplexvirus humanalpha1*, the formal species name of herpes simplex virus 1 (HSV-1). Because you already expect that answer, you can tell a working check from a broken one.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for the example data of the Kraken 2, TaxTriage, and BLAST chapters. Download run `SRR12486983` from the Sequence Read Archive, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md), then classify it against the Viral database as [Running Kraken 2](02-running-kraken2.md#procedure) shows. The download alone is not enough. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/kraken-protocol-cornea, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Verification starts from that finished classification open in its [viewport](../../GLOSSARY.md#viewport), the panel that fills the window and shows one result, rather than from a FASTQ file. A result imported from CZ-ID, a web-based metagenomics service, cannot be verified, because it carries no per-read identifiers to send.

There is no plugin pack to install and no database to download, because the search runs on NCBI's computers. In exchange, the reads you verify leave your Mac. LGE sends the sequence of each sampled read and that read's identifier, plus LGE's own tool name and a fixed LGE contact address, and nothing about the sample, the project, or the rest of the file. NCBI keeps a submitted search for about 36 hours and returns it to anyone holding its tracking number, so treat a submission as a disclosure. Check what a data-use agreement allows before you send reads from a sample it covers, and never send reads that may be human without that check. Kraken 2 assigns a fragment to a virus on part of its sequence, so you cannot rule out that a read also carries human sequence, and the rule covers every read from a human sample. The worked example's reads are already public in the Sequence Read Archive, so sending them discloses nothing new, but your own clinical samples need that check. LGE has no local BLAST, so a sample you cannot send out cannot be verified this way.

The wait depends on NCBI's queue, which LGE does not control. A run usually takes a minute or two. LGE checks on the job by itself and gives up after ten minutes, and a timed-out job is not lost, as step 5 below explains.

## Procedure

These steps use the taxonomy viewport, where a Kraken 2 result opens. The other classifier viewports start verification in the ways the last section of this chapter lists.

1. Click the Viral result in the sidebar, a folder under `Analyses` whose name starts with `kraken2-`, so that the taxonomy viewport opens. Type `humanalpha1` in the **Filter taxa…** field above the table and click the *Simplexvirus humanalpha1* row. Verification runs on one taxon at a time, so select a single row. LGE picks the reads for you, as the Settings section explains.

2. Click **BLAST Verify** in the action bar, the strip of buttons under the table. Right-clicking the row and choosing **BLAST Matching Reads...** does the same. If the button is greyed out, hold the pointer over it and a tooltip names the reason, which is no row selected, more than one row selected, or a result that has no read-level data.

3. Read the popover that opens over the middle of the sunburst chart, the ring chart beside the table where each wedge is one taxon. A popover is a small panel that closes when you click anywhere outside it. Its title reads `Verify "Simplexvirus humanalpha1" via NCBI BLAST`, and the line under the slider warns that the reads leave the app for NCBI.
   <!-- SHOT: blast-verify-popover -->

4. Leave **Reads to submit**, described under Settings, at 20 and click **Run BLAST** or press Return. A taxon with only one read shows a line stating that count instead of the slider, because there is nothing to choose.

5. Watch the drawer at the bottom of the viewport, a panel that slides up from the lower edge. It opens on its **BLAST Results** tab and steps through three phases, submitting the reads, waiting for NCBI, and parsing the answer, with a line of text naming the current phase and a **Cancel** button that stops the job. The run also appears in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), titled `BLAST` followed by the taxon name, and when it finishes its row gives the same supporting and contradicting counts as the drawer. If the job times out, the drawer's failure message gives the job's [request ID](../../GLOSSARY.md#rid), the tracking number NCBI assigned it, and a web address that collects the finished result from NCBI later in a browser.

The action bar holds two BLAST buttons. **BLAST Verify** starts a new verification. **BLAST Results** only shows or hides the results drawer, which shares its space with **Collections**, a way of grouping taxa unrelated to verification. **BLAST Results** opens the drawer on its BLAST tab, switches to that tab if the drawer shows Collections, and closes the drawer if the BLAST tab is already showing. **Collections** only opens or closes the drawer, on whichever tab was last shown.

## Settings

The popover has one setting. Its bold label ends in a colon followed by a period, because it keeps the colon the app draws after the label on screen. Every other search setting is fixed, and the paragraphs after the entry list them so you can record them in a methods section.

**Reads to submit:.** Sets how many of the taxon's reads LGE sends to NCBI, where more reads give a firmer answer and take longer to come back. The default is 20, enough for the supporting share to mean something, whereas below about ten reads a single read can swing the share across the 40 and 80 percent cutoffs that Reading the results defines. Lower it for a quick check on an abundant taxon, and raise it when the first answer comes back Mixed. On the command line this is `--reads`.

The slider runs from 1 to 50, and a number field beside it takes a typed value, which LGE pulls back inside that range if you type past either end. A fragment is one piece of DNA from the library. In a [paired-end](../../GLOSSARY.md#paired-end) run each fragment was read from both ends, giving two reads called mate 1 and mate 2, and Kraken 2 counts the pair once. The slider counts fragments, and LGE sends one read per fragment. When the taxon holds fewer than 50 fragments, that count becomes the maximum, and when it holds fewer than 20 the default drops to that count. The count here includes fragments assigned to taxa below the one you selected, such as the strains inside a species, and those are eligible to be sent. The command line accepts 1 to 100, but a request that sends more than 50 reads fails at NCBI's hourly limit, so keep it at 50 or below.

Which reads LGE sends from the taxonomy viewport is fixed. It draws fragments at random from every fragment Kraken 2 assigned to the taxon or to a taxon below it, so each one has the same chance of being picked and the sample stands for the whole taxon. The draw is repeatable, so the same count on the same result sends the same reads, and a larger count keeps the smaller draw and adds to it, so 40 reads include the first 20. For each fragment LGE sends one mate, the one with more k-mers matching the taxon in Kraken 2's per-read output file, `classification.kraken.gz` in the result folder. On a tie it sends the mate with more k-mers matched to anything, and otherwise mate 1. That keeps a mate with no evidence for the taxon out of the search. The drawer does not say which mate went. Other viewports choose reads their own way, as the table at the end of this chapter lists.

The rest of the search is fixed too. The program is `blastn`, which compares DNA against DNA, run in NCBI's megablast mode, a fast setting built for sequences that match closely. It suits reads from a known organism but can miss a distant relative that a slower search would find. You need these details only to describe the search in a methods section. From the taxonomy viewport the database is [`nt`](../../GLOSSARY.md#nt-database), NCBI's general nucleotide collection, and the other viewports search `core_nt`, a smaller version of `nt` that leaves out most chromosome-scale sequences of plants and animals. NCBI returns at most five hits per read, a hit being one database record that matched, and drops any hit with an e-value above `1e-10`, a measure of how likely the match is by chance that Reading the results explains.

LGE also paces itself to follow NCBI's usage rules. It sends at most 50 sequences in any rolling hour. The count is kept by each running copy of LGE, and separately by each `lungfish-cli` command, so quitting the app resets it, but NCBI's own limit still applies. A verification that would pass that limit stops at once with the message `NCBI rate limit exceeded. Retry after <n> seconds.`, so run a second 50-read verification after the hour is up. Every submission counts toward the 50, including **Re-run BLAST**. LGE also spaces submissions at least 10 seconds apart and waits for that gap on its own.

## Reading the results

The drawer shows a summary bar above one row per submitted read. The summary is built from the per-read numbers, so this section explains those first.

<!-- SHOT: blast-results-drawer -->

### The per-read table

Each read gets a parent row showing its best hit. Click the small arrow at the left of the row to show the other hits under it, ranked from best to worst, never more than five. Six columns show by default. Status is an icon at the left that mirrors the read's verdict, a filled tick for Verified, a triangle with an exclamation mark for Ambiguous, and a cross for Unverified. Read / Accession holds the read's identifier on a parent row and the matched record's [accession](../../GLOSSARY.md#accession), its catalogue number at NCBI, on a child row. Organism names the source of the matched record. Identity, E-value, and Bit Score are the three numbers below.

### Percent identity

[Percent identity](../../GLOSSARY.md#percent-identity), the Identity column, is the share of aligned positions where the read and the database record carry the same base. An alignment is the two sequences lined up base against base, with gaps allowed where one has extra bases. The worked example's reads are at most 76 bases long, and shorter where trimming removed poor-quality ends, so a read aligned over 76 positions with one mismatch scores 75 divided by 76, or 98.7 percent.

Identity is counted only over the stretch that aligned, so it says nothing about how much of the read took part. A read that matched perfectly over its first 30 bases and not at all over its remaining 46 still reports 100 percent. Query coverage closes that gap.

Identity in the high nineties is what a match to the right organism usually looks like. Identity in the 80s often means a relative rather than the organism itself. Between 90 and 95 percent the read passes the Verified threshold below, but a strain or relative missing from NCBI's collection is as likely as the organism itself, so check the Organism column and the next hits.

### Query coverage

[Query coverage](../../GLOSSARY.md#query-coverage), in the Coverage column, is the share of the read that took part in the alignment. The read is the query, the sequence you asked about. A 76-base read whose alignment runs from base 1 to base 57 has 75 percent query coverage.

Read identity and coverage together. Ninety-nine percent identity over a third of the read is much weaker evidence than 95 percent over all of it, because the unaligned two thirds may belong to something else entirely. The Coverage column is hidden until you show it, as described below. Show Coverage and Verdict before you read the rows, because together they explain why a read counts or not.

### E-value

The [e-value](../../GLOSSARY.md#e-value) is the number of matches at least this good you would expect to find by chance alone, given the length of the read and the size of the database. Smaller is better. An e-value of 0.1 means one chance match in every ten searches like this one, which is weak evidence. An e-value of `1e-30`, meaning 10 to the power of minus 30, means chance essentially never produces a match this good.

The scale is logarithmic, so each step in the exponent is a tenfold change, and `1e-30` is a billion billion times stronger than `1e-12` even though the printed numbers look alike. An e-value also shrinks as a match gets longer, so a short read can never reach the tiny e-values a long one can, however well it matches. In the worked example, reads that matched HSV-1 perfectly over 76 bases came back at `1e-29` and `4e-29`, well inside the `1e-10` cutoff.

### Bit score

The [bit score](../../GLOSSARY.md#bit-score) measures how strong one alignment is. It rises with every matching base and falls with every mismatch and gap, so a longer, cleaner alignment scores higher. Unlike the e-value, it does not depend on the size of the database.

A bit score has no fixed good or bad value, because it grows with the length of the read. Its use is comparing the hits for one read against each other. Expand a read's row and compare its hits. In the worked example, 76-base reads that matched perfectly scored 140 and 141. If a read's top hit scores 141 and the second 139, the read fits both records almost equally well, and the organism named on the top row is barely preferred. If the top hit scores 141 and the second 100, the top hit is a clear winner. Do not compare bit scores between reads of different lengths.

### The per-read verdict

LGE labels every read with one of three verdicts, shown by the Status icon and, once you turn it on, the Verdict column.

| Verdict | Rule |
|---|---|
| **Verified** | The top hit has at least 90 percent identity, at least 80 percent query coverage, and an e-value of `1e-10` or smaller |
| **Ambiguous** | A hit came back but falls short of any of the three Verified thresholds |
| **Unverified** | No hit came back at all |

Verified is about the quality of the match only. It says the read found a strong match, not that the match names the classifier's organism. Supporting, in the summary bar, is the second test, about the name. A read helps the word only when it passes both.

### The summary bar and the confidence word

The summary bar reads `BLAST for <taxon>: <n> supporting, <n> contradicting (<n> reads)`, then a row of ten symbols and the confidence word. Only Verified reads count toward the summary.

A Verified read is **supporting** when its top hit agrees with the taxon you selected, and **contradicting** when it names something else. A hit agrees in any of three ways. Its [taxonomy ID](../../GLOSSARY.md#taxonomy-id) falls inside the selected taxon's [clade](../../GLOSSARY.md#clade), the taxon with everything below it. Its organism name contains the name of a member of that clade. Or the first words of the two names match, which for a species name is the genus. The first two are why a hit that NCBI names Human alphaherpesvirus 1 supports *Simplexvirus humanalpha1*, the species name Kraken 2 and Bracken use for the same virus. The third means a read whose top hit is a different species in the same genus also counts as supporting, so a Supported word can include close relatives. The first-word test does not know that many virus names start with a host, so if you verify a row named Human alphaherpesvirus 1, a hit to Human gammaherpesvirus 4, a different herpesvirus, would also count as supporting. Check the Organism column when the exact species matters. Ambiguous and Unverified reads count as neither.

The supporting share is supporting reads divided by supporting plus contradicting reads, and it sets the word. Reads that counted as neither are left out, so the word can rest on far fewer reads than you sent. One supporting read and 19 Ambiguous ones give a 100 percent share and the word Supported, so always read the two counts beside it.

| Supporting share | Word |
|---|---|
| 80 percent and above | **Supported** |
| 40 percent up to but not including 80 | **Mixed** |
| Below 40 percent | **Unsupported** |
| No read supporting or contradicting | **Inconclusive** |

The ten symbols split the submitted reads into tenths, rounded. With 20 reads each symbol stands for two reads. With three reads, two supporting and one contradicting, the bar shows seven filled circles and three diamonds. A filled circle stands for supporting reads, a diamond for contradicting reads, and a hollow circle for reads that counted as neither. The bar is tinted to match the word, but you never need the colour.

A phrase reading `<n> with conflicting organisms` can appear beside the word. It counts reads whose five hits span more than one genus, judged by the first word of each organism name, so viruses whose names start with the same host word, such as Human, count as one genus here. A handful is normal, but when it reaches about a quarter of the reads you sent, the reads themselves are ambiguous. That usually means they come from a conserved region, a stretch of sequence so little changed over evolutionary time that several genera still share it. Such reads cannot tell the organisms apart, which is a different problem from the classifier being wrong.

### Columns, copying, and exporting

Five more columns are hidden at first, Accession, Coverage, Align Length, Tax ID, and Verdict. Right-click any column header to get a menu of column names, with a tick beside each one showing, and choose a name to show or hide it. LGE remembers the choice for every BLAST drawer, even after you quit. The Accession column fills in on parent rows too, so you can read every accession without expanding anything.

Right-clicking a row offers Copy Sequence as FASTA, Copy Read ID, Copy Accession, Expand All, and Collapse All. **Open in NCBI BLAST** opens the full result on NCBI's site, where every hit is available rather than the five LGE keeps. **Re-run BLAST** submits the same number of reads again at once, and because the draw is repeatable they are the same reads, which is useful after a failure or timeout. To send more, click **BLAST Verify** again and raise the slider. **Export** in the summary bar saves the table as CSV (comma-separated) or TSV (tab-separated), covering every read and every hit whether the rows are expanded or not.

BLAST results are not saved with the analysis. They stay in the drawer only until the result view reloads, such as when you open another item in the sidebar and come back. The Operations Panel row keeps only the two counts. Click **Export** before you move on if you need the per-read rows.

## What good looks like

Read the summary word and the per-read rows together, because either alone can mislead you.

A verification you can rely on has a Supported word, and per-read rows that name the classifier's organism with identity and coverage in the high nineties and e-values far below `1e-10`. The worked example came back that way. Its summary bar read `BLAST for Simplexvirus humanalpha1: 20 supporting, 0 contradicting`, with all ten circles filled, the word Supported, and the phrase `1 with conflicting organisms`. The rows' top hits named Human alphaherpesvirus 1 at 100.0 percent identity, with e-values of `1e-29` and `4e-29` and bit scores of 140 and 141. The phrase means that for one read, the up to five hits BLAST returned included a name whose first word differs from the rest, so by LGE's first-word test they span more than one genus. Its top hit still agreed with HSV-1, so it still counts as supporting, and one read in 20 is the handful that is normal. With every one of 20 reads agreeing, the share rests on all the reads sent, so leave the slider at 20 for any verification whose answer you intend to use.

An Unsupported word is not automatically bad news about your sample. If the rows consistently name one other organism with high identity, the classifier probably assigned the reads to a relative it held, and that other organism is the better answer. If they name a scatter of unrelated organisms at middling identity, the reads are probably uninformative. That happens when a read is low-complexity, meaning it repeats one or two bases over most of its length, or when it still carries adapter, the short synthetic sequence attached during library preparation. The honest conclusion for such a taxon is that it is unresolved.

Two results call for another run rather than an interpretation. Inconclusive means no read found a strong match, which on short or poor-quality reads says more about the reads than the taxon, so send more reads or verify a taxon with longer ones. Mixed on a small sample can be sampling noise, since two supporting reads out of three is a 67 percent share on evidence far too thin to act on. Raise the slider and run it again.

A result from the NAO-MGS viewport leans toward Supported, because that viewport limits the search to the taxon's own records, as the table below notes. There, read the identities and the count of reads that settled nothing rather than trusting the word.

Finally, Supported says only that the reads LGE sent match the organism the classifier named. It does not say the classifier's read counts are right, that the abundance estimate holds, or that a related organism is absent. Verification checks what the reads are, not how many there are.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
# Work from inside the project, a folder whose name ends in .lungfish.
cd ~/Documents/MyProject.lungfish

# Verify HSV-1 (NCBI taxonomy ID 10298) in the Kraken 2 Viral result,
# including reads assigned below it, as the window does.
lungfish-cli blast verify \
  --kreport Analyses/kraken2-<timestamp>/classification.kreport \
  --kraken-output Analyses/kraken2-<timestamp>/classification.kraken.gz \
  --source Imports/SRR12486983.lungfishfastq/SRR12486983.fastq.gz \
  --taxid 10298 --include-children \
  --reads 20 --format json
```

Replace `<timestamp>` with the rest of the Viral result's folder name. Taxonomy ID 10298 is the Human alphaherpesvirus 1 row, which sits one level below the *Simplexvirus humanalpha1* row you clicked in the window and holds the same 886,221 pairs, as [Running Kraken 2](02-running-kraken2.md#reading-the-results) explains. Kraken 2 assigned every one of those pairs to 10298 itself, so `--include-children` changes nothing here, but it matches what the window does and matters for a taxon with strains below it. `--kraken-output` names the per-read output file whose k-mer counts choose the mate. `--format json` prints the result as JSON, a structured text format other programs can read, and leaving it out prints a readable summary. That summary also says how many of the reads went as mate 2, which on this sample was 6 of the 20.

Two differences matter. The window always includes reads assigned below the chosen taxon, and the command does so only with `--include-children`. The command accepts up to 100 reads but fails above 50 for the same hourly limit. The command draws its reads the same way the window does, and `--seed` with a whole number picks a different random draw. Leaving `--seed` out uses the same seed as the window. When a job times out, the command prints its request ID and the web address that collects the result.

## Where else verification starts

| Viewport | How to start it | What LGE sends and searches | Summary |
|---|---|---|---|
| Taxonomy, where Kraken 2 results open | **BLAST Verify** in the action bar, or right-click **BLAST Matching Reads...** | Fragments drawn at random, one mate each, searched against `nt` | Confidence word |
| EsViritu | **BLAST Verify** in the action bar, or right-click **BLAST Verify...** | The longest reads, five or a quarter of the request, whichever is smaller, then a random fill, searched against `core_nt` | Confidence word |
| TaxTriage | Right-click **Verify with BLAST...** to choose the count in the popover. **BLAST Verify** in the action bar opens no popover and sends 50 reads at once, or every read when the row has fewer | The longest reads, five or a quarter of the request, whichever is smaller, then a random fill, searched against `core_nt` | Confidence word |
| NAO-MGS | **BLAST Verify** in the action bar, or right-click **BLAST 20 Reads**, **BLAST 50 Reads**, or **BLAST All N Reads** (N being the taxon's unique read count, with at most 50 sent) | Reads spread across the four quarters of the reference genome, of which LGE takes the longest few and a random fill, searched against only that taxon's own records in `core_nt`, so the word leans toward Supported | Confidence word |
| [Novel Virus Diagnostics](09-novel-virus-detection.md) | **BLAST Verify** in the action bar, or right-click a contig and choose **Verify with BLAST...** | The selected [contig](../../GLOSSARY.md#contig)'s own sequence, searched against `core_nt` | Confidence word |
| [12S metabarcoding](10-twelve-s-metabarcoding.md) | **BLAST Verify** in the action bar while the Unresolved view shows | The unresolved sequences, searched against `core_nt` | `BLAST results for <name>` heading, no word |

## Next

Continue to [Running Freyja](07-running-freyja.md), which estimates how much of each viral lineage a mixed sample holds, or to [Novel Virus Diagnostics](09-novel-virus-detection.md) for contig-level verification. To go back to the classification that raised the question, return to [Running Kraken 2](02-running-kraken2.md) or [Running EsViritu](03-running-esviritu.md).
