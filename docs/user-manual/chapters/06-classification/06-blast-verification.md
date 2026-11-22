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
  - "Taxonomy viewport action bar > Verify with BLAST…"
  - "Right-click a taxon in the taxonomy viewport > Verify with BLAST…"
  - "Selection > Table Row > Verify with BLAST…"
  - "CLI: lungfish-cli blast verify --kreport <kreport> --source <fastq-or-bundle> ... --kraken-output <kraken> --taxid <taxid>"
shots:
  - id: blast-verify-popover
    caption: "The Verify \"Simplexvirus humanalpha1\" via NCBI BLAST popover open over the sunburst of the SRR12486983 Viral result, showing the Reads to submit slider at 20 with its typed number field, the line saying the reads go to NCBI BLASTN core_nt and leave this Mac, and the Run BLAST button."
  - id: blast-results-drawer
    caption: "The BLAST Results drawer under the sunburst of the SRR12486983 Viral result, with the summary bar reading 20 supporting, 0 contradicting, ten filled circles, and the verdict Supported, above per-read rows whose best record is Human alphaherpesvirus 1 at 100.0% identity."
illustrations: []
glossary_refs: [accession, bit-score, blast, bundle, clade, contig, e-value, esviritu, fastq, fragment, k-mer, kraken2, kreport, mate, nao-mgs, not-specific, nt-database, nvd, operations-panel, paired-end, percent-identity, provenance, query-coverage, read, read-classification, rid, taxon, taxonomic-rank, taxonomy-id, taxtriage, viewport]
features_refs: [classify.blast-verify, results.table-row-commands]
fixtures_refs: [kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

A [classifier](../../GLOSSARY.md#read-classification) such as [Kraken 2](../../GLOSSARY.md#kraken2) names each [read](../../GLOSSARY.md#read), one short stretch of DNA from the sequencer, by looking up short pieces of it in a table. Those pieces are [k-mers](../../GLOSSARY.md#k-mer), stretches exactly k bases long, and [Running Kraken 2](02-running-kraken2.md#what-it-is) shows how the lookup works. A table lookup is fast, but it can name the wrong organism when the right one is missing from the table or when a relative shares the same pieces.

BLAST verification gets a second opinion from a different method. [BLAST](../../GLOSSARY.md#blast) is a search service run by NCBI, the United States National Center for Biotechnology Information. Given one sequence, it lines it up base by base against NCBI's public sequence collection and returns the records that match best, ranked from best to worst. A record is one entry in that collection, such as a genome or a gene, and each record returned is a hit. The collection is far larger than any database a classifier installs on your Mac, so it can name organisms the classifier never had a chance to report.

Lungfish Genome Explorer (LGE) uses BLAST to ask one narrow question. It draws a small random sample of the reads a classifier assigned to one [taxon](../../GLOSSARY.md#taxon), a named group of organisms at any level from species up to kingdom. It sends them to NCBI, and for each read it asks whether the best match belongs to the taxon the classifier named. The answers roll up into one verdict for the whole batch, which is Supported, Not specific, Mixed, Unsupported, or Inconclusive. [Reading the results](#reading-the-results) defines each one and every number behind it.

Treat the verdict as a strong second signal rather than a final answer. NCBI's collection is broad but not complete, and twenty reads show what most of a taxon's reads are but can miss a small minority. So verify any call that would change what you do next.

## Why you would do this

A verification waits on NCBI and covers one taxon at a time, so spend it where a second opinion would change your next step. Four situations qualify.

The first is an unexpected organism in a familiar sample type. A classifier that lacks the true source puts its reads on the nearest relative it does hold, usually in the same genus or family, the [taxonomic ranks](../../GLOSSARY.md#taxonomic-rank) just above species. NCBI's collection usually holds both the relative and the true source, so each read lands on the one it really came from.

The second is a taxon with few reads about to drive a decision, since a few dozen reads out of millions is fragile evidence. The third is two classifiers that disagree about the same sample, which BLAST settles by agreeing with one of them or with neither. The fourth is a check before you report a result to someone else.

This chapter verifies the Kraken 2 Viral result from [Running Kraken 2](02-running-kraken2.md), made from run SRR12486983, corneal tissue from a person with herpes simplex keratitis. The species with the most reads there is *Simplexvirus humanalpha1*, the formal species name of herpes simplex virus 1 (HSV-1). Because you already expect that answer, you can tell a working check from a broken one.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. LGE saves every search inside the project, so with no project open **Verify with BLAST…** shows an alert titled No Project Open and sends nothing.

Open the Pathogen Detection demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR12486983`, but no classification, so first classify the run against the Viral database, Kraken 2's collection of viral sequences, as the [Running Kraken 2 procedure](02-running-kraken2.md#procedure) shows.

This chapter uses the kraken-protocol-cornea fixture, the manual's name for the example data of the Kraken 2, TaxTriage, and BLAST chapters. To fetch the run yourself, download `SRR12486983` from the Sequence Read Archive as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows, then classify it. The fixture's README, with the study's source and terms of use, is at https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Verification starts from that finished classification open in its [viewport](../../GLOSSARY.md#viewport), the panel that fills the window and shows one result, rather than from a [FASTQ](../../GLOSSARY.md#fastq) file, the text file of reads that a sequencer writes. A result imported from CZ ID, a web-based metagenomics service, cannot be verified, because it carries no per-read identifiers to send.

There is no plugin pack to install and no database to download, because the search runs on NCBI's computers. In exchange, the reads you verify leave your Mac, and LGE cannot call them back. LGE sends the sequence and identifier of each sampled read, its own tool name, and a contact address, and nothing about the sample, the project, or the rest of the file. NCBI says it keeps a search for 36 hours and returns it to anyone who holds its [request ID](../../GLOSSARY.md#rid), the tracking number NCBI gives each search, so treat sending as a disclosure. Check what a data-use agreement, the contract that came with the data, allows before you send reads from a sample it covers. Never send reads from a human sample without that check, because a read Kraken 2 assigned to a virus can still carry human sequence. The cornea reads come from a human sample but are already public in the Sequence Read Archive, so sending them discloses nothing new. **Verify with BLAST…** has no local mode, so a sample you cannot send out cannot be verified this way.

The contact address is LGE's shared no-reply address unless you give your own. NCBI asks BLAST tools for an address so that it can reach you if your searches cause a problem. To give yours, choose **Settings…** (Cmd-,) from the menu named after the app and type it in **Contact email (optional)** in the NCBI BLAST section of the **General** tab. LGE sends it only to NCBI and keeps it out of project files, records, logs, and copied commands. It is not known to make a search faster.

NCBI decides how long a search takes, and LGE does not control its queue. In LGE's own tests, most searches came back within about two and a half minutes, and a few stuck for hours. [Follow a search that NCBI holds](#follow-a-search-that-ncbi-holds) explains what you see meanwhile.

## Procedure

### Verify a Kraken 2 taxon

1. Click the Viral result in the sidebar, a folder under `Analyses` whose name starts with `kraken2-`, so that the taxonomy viewport opens. Type `humanalpha1` in the **Filter taxa…** field above the table and click the *Simplexvirus humanalpha1* row. Verification runs on one row at a time.

2. Click **Verify with BLAST…** in the action bar under the table, which [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes. Choosing **Verify with BLAST…** from the row's right-click menu or from **Selection > Table Row** does the same. A greyed button names the reason in its tooltip.

3. Read the popover that opens over the middle of the sunburst chart, the ring chart beside the table. A popover is a small panel that closes when you click anywhere outside it. Its title reads `Verify "Simplexvirus humanalpha1" via NCBI BLAST`. The line under the slider names the database, `core_nt`, and says that the reads leave this Mac and that LGE may send them again if NCBI is slow, at most three sends in all.
   <!-- SHOT: blast-verify-popover -->

4. Leave **Reads to submit**, which the Settings section describes, at 20, and click **Run BLAST** or press Return.

5. Watch the drawer that slides up from the bottom of the viewport on its **BLAST Results** tab. It first reads `Submitting reads to NCBI BLAST...`, with a **Cancel** button, while LGE draws the reads and sends them, and may then read **Sending reads to NCBI** with a **Stop** button until NCBI confirms the search. After that it reads **Waiting for NCBI** and gives the request ID until NCBI answers, however long that takes. The search also appears in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), on a row titled `BLAST Simplexvirus humanalpha1`. When NCBI answers, the drawer shows the verdict and one row per read, and LGE saves the result, as [Saved verifications](#saved-verifications) explains. [What good looks like](#what-good-looks-like) shows an earlier run's counts and verdict for this row.

The drawer shares its space with the taxa collections that [Collections](02-running-kraken2.md#collections) describes, and **BLAST Results** in the action bar shows or hides it.

### Follow a search that NCBI holds

NCBI runs every search in a queue that it alone manages. LGE never treats a waiting search as failed. It checks once a minute for the first ten minutes, then less and less often, until it checks every thirty minutes after six hours, for as long as NCBI says the search is waiting. A search that sticks at NCBI can stay stuck for hours while a fresh copy usually comes back in a minute or two, so after about three minutes without an answer LGE usually sends the same reads again as a second search, and after about six minutes a third. The first answer to come back counts, and LGE stops checking the others. After two searches in a row stayed stuck even with every copy sent, LGE sends no new copies for an hour, since more would only add load to a stuck service.

While the search waits, the drawer lists every request ID so far, and once LGE has sent every copy it makes by itself, its heading reads **Still waiting at NCBI**. Three buttons sit under the text:

- **Check Now** asks NCBI about the search at once. It stays grey while LGE is still sending, and for a minute after each check, because NCBI asks for no more than one check a minute. Its tooltip says why.
- **Send Again** sends the same reads to NCBI as one more search, besides the copies LGE makes by itself. It stays grey while those are still due.
- **Stop** stops LGE checking the search. NCBI may still finish it, and **Resume** takes it up again while NCBI holds it.

You can select other taxa, open other results, or quit LGE meanwhile. The search stays at NCBI, LGE checks it again the next time you open LGE, and the result comes back on the row it was sent from. The search's Operations Panel row shows where it stands. When the search has come back, the row's **Results** button selects the Kraken 2 result that holds it in the sidebar, and selecting the taxon shows it. Because the checks space out over time, a search that NCBI finishes after a long wait can take up to half an hour to appear, so click **Check Now** when you want it sooner.

A few searches end without a result. When NCBI no longer holds a search, or says it could not finish one, the drawer says so and offers **Send Again**. When NCBI is not taking new searches at all, the drawer and the Operations Panel row say so and give the time LGE sends the search again.

### Verify from another classifier viewport

If you only use Kraken 2, skip this section. The [EsViritu](../../GLOSSARY.md#esviritu), [TaxTriage](../../GLOSSARY.md#taxtriage), [NAO-MGS](../../GLOSSARY.md#nao-mgs), and [NVD](../../GLOSSARY.md#nvd) viewers share Kraken 2's action bar, so **Verify with BLAST…** sits in the same place there and in each row's right-click menu. Every viewer searches all of `core_nt` with no filter and judges each read by the same rules. They differ in what they send. In the table, a [fragment](../../GLOSSARY.md#fragment) is one piece of the sample's DNA. In [paired-end](../../GLOSSARY.md#paired-end) data it is read from both ends, giving two reads called [mates](../../GLOSSARY.md#mate), and Kraken 2 counts the pair once.

| Viewer | What LGE sends | Before it sends |
|---|---|---|
| Taxonomy, where Kraken 2 results open | Fragments drawn at random, one mate each | The popover |
| [EsViritu](03-running-esviritu.md) and [TaxTriage](04-running-taxtriage.md) | The longest reads, five or a quarter of the request, whichever is smaller, then a random fill. EsViritu draws them from the row's own sample. Both mates of a pair are judged and the pair counts once | The popover |
| [NAO-MGS](05-running-nao-mgs.md) | Reads spread across the four quarters of the reference genome, each quarter giving half its share from its reads with the fewest differences from the reference and half from those with the most | The popover |
| [Novel Virus Diagnostics](09-novel-virus-detection.md) | The selected [contig](../../GLOSSARY.md#contig)'s own sequence, judged against the taxon NVD's adjusted tax ID names | A sheet titled Run BLAST at NCBI? |
| [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md) | The unresolved sequences, from the Unresolved view | A sheet titled Run BLAST at NCBI? |

The 12S drawer gives a `BLAST results for <name>` heading and no verdict. The EsViritu, TaxTriage, NAO-MGS, and NVD viewers find a row's species in the NCBI Taxonomy, an optional download in the Databases tab of the Plugin Manager. Without it, they judge by the row's own tax ID or by organism names alone, and a line under the drawer's summary says which.

## Settings

The popover has one setting. Every other search setting is fixed, and the paragraphs after the entry list them so you can record them in a methods section.

**Reads to submit.** Sets how many of the taxon's [fragments](../../GLOSSARY.md#fragment) LGE sends to NCBI, one read from each, where more reads give a firmer answer. The default is 20, so when every read is judged each moves the supporting share by 5 percentage points (with ten reads, 10), and a share within 5 points of the 40 or 80 percent cutoffs that Reading the results defines can change the verdict on one read. Lower it to spend fewer of the hour's 50 reads, and raise it when the first answer comes back Mixed. On the command line this is `--reads`.

The slider runs from 1 to 50 fragments, and the number field beside it takes a typed value, which LGE pulls back inside that range. When the taxon holds fewer than 50 fragments, that count becomes the maximum, and when it holds fewer than 20 the default drops to that count. The command line accepts up to 100, but any search over 50 reads is refused, as the limit below explains.

Which reads LGE sends from the taxonomy viewport is fixed. It draws fragments at random from every fragment Kraken 2 assigned to the taxon or to a taxon below it, so each has the same chance of being picked and the sample stands for the whole taxon. The draw is repeatable, so the same count on the same result sends the same reads, and a larger count keeps the smaller draw and adds to it, so 40 reads include the first 20. For each fragment LGE sends one mate, the one with more k-mers matching the taxon in Kraken 2's per-read output file, `classification.kraken.gz` in the result folder. On a tie it sends the mate with more k-mers matched to anything, and otherwise mate 1. That keeps a mate with no evidence for the taxon out of the search. The same rule holds for a read [bundle](../../GLOSSARY.md#bundle), LGE's folder for one set of reads, whose two mates sit in separate files, R1 and R2. A merged read, two overlapping mates joined into one, or an orphan whose mate was removed, has no second mate and can be drawn like any fragment.

The search itself is fixed too. The program is `blastn`, which compares DNA against DNA, in NCBI's megablast mode, a fast setting built for sequences that match closely. It suits reads from a known organism but can miss a distant relative that a slower search would find. The database is `core_nt`, a version of NCBI's general nucleotide collection, [`nt`](../../GLOSSARY.md#nt-database), that leaves out some large chromosome assemblies of eukaryotes such as animals and plants, to speed searches. Virus records are not among them. LGE asks NCBI for up to 500 matching records per read, so that it can judge the records tied for best, and it keeps the best five per read for the drawer. NCBI drops any match with an [e-value](../../GLOSSARY.md#e-value) above `1e-10`, which is 0.0000000001, where a smaller e-value means a match less likely to be chance.

LGE also paces itself to follow NCBI's usage rules. New searches carry at most 50 reads in any rolling hour, meaning the last 60 minutes, so after a 20-read search 30 reads remain. LGE keeps that count in a file in its storage folder, so quitting does not reset it, and the app and `lungfish-cli` share one count. A search that would pass the limit stops before anything is sent, with a message that begins `LGE's own limit stopped this search, and NCBI was not contacted.` and gives the time when the search fits. Every new search counts toward the 50, including **Re-run BLAST**. The extra sends of a slow search draw on a separate allowance, so they never stop you starting a new one. LGE also spaces its contacts with NCBI at least 11 seconds apart.

## Reading the results

The drawer shows a summary bar above one row per submitted read. Each read gets a label, each Verified read counts as supporting or contradicting, and those counts give the batch one verdict, so this section starts with the per-read numbers. The example figures below come from an earlier run on the cornea sample, before LGE asked NCBI for 500 records per read, so a run today can differ.

<!-- SHOT: blast-results-drawer -->

### The per-read table

Each read gets a parent row showing its best record. Click the small arrow at the left of the row to show up to four more records under it, ranked from best to worst, so a read never shows more than five. Six columns show by default. Status is an icon at the left that mirrors the read's label, a filled tick for Verified, a triangle with an exclamation mark for Ambiguous, a cross for Unverified, and an octagon with an exclamation mark for Error. Read / Accession holds the read's identifier on a parent row and the matched record's [accession](../../GLOSSARY.md#accession), its catalogue number at NCBI, on a child row. Organism names the source of the matched record. Identity, E-value, and Bit Score are the three numbers below.

### Percent identity

[Percent identity](../../GLOSSARY.md#percent-identity), the Identity column, is the share of aligned positions where the read and the record carry the same base. An alignment is the two sequences lined up base against base, with gaps allowed where one has extra bases. The cornea sample's reads are at most 76 bases long, and shorter where trimming removed poor-quality ends, so a read aligned over 76 positions with one mismatch scores 75 divided by 76, or 98.7 percent.

Identity counts only the stretch that aligned, so it says nothing about how much of the read took part. A read that matched perfectly over its first 30 bases and not at all over its other 46 still reports 100 percent. Query coverage closes that gap.

As a rule of thumb, identity in the high nineties is what a match to the right organism usually looks like, and identity in the 80s often means a relative rather than the organism itself. Between 90 and 95 percent the read passes the Verified threshold below, but it could come from your organism or from a close relative missing from NCBI's collection, so check the Organism column and the next records.

### Query coverage

[Query coverage](../../GLOSSARY.md#query-coverage), in the Coverage column, is the share of the read that took part in the alignment. The read is the query, the sequence you asked about. A 76-base read whose alignment runs from base 1 to base 57 has 75 percent query coverage.

Judge identity and coverage together. Ninety-nine percent identity over a third of the read is much weaker evidence than 95 percent over all of it, because the unaligned two thirds may belong to something else entirely. The Coverage column is hidden until you show it, as [Columns, copying, and exporting](#columns-copying-and-exporting) describes. Show **Coverage** and **Verdict** before you read the rows, because together they explain why a read counts or not.

### E-value

The [e-value](../../GLOSSARY.md#e-value) is the number of matches at least this good you would expect by chance alone, given the length of the read and the size of the database. Smaller is better. An e-value of 0.1 means one chance match in every ten searches like this one, which is weak evidence. An e-value of `1e-30`, meaning 10 to the power of minus 30, means chance essentially never produces a match this good.

The scale is logarithmic, so each step in the exponent is a tenfold change, and `1e-30` is a billion billion times stronger than `1e-12`. An e-value also shrinks as a match gets longer, so a short read can never reach the tiny e-values a long one can, however well it matches. In the example run, reads that matched HSV-1 perfectly over 76 bases came back at `1e-29` and `4e-29`, well inside the `1e-10` cutoff.

### Bit score

The [bit score](../../GLOSSARY.md#bit-score) measures how strong one alignment is. It rises with every matching base and falls with every mismatch and gap, so a longer, cleaner alignment scores higher. Unlike the e-value, it does not depend on the size of the database.

A bit score has no fixed good or bad value, because it grows with the length of the read. Its use is comparing the records for one read against each other. In the example run, 76-base reads that matched perfectly scored 140 and 141. If a read's best record scores 141 and the next 100, the best record is a clear winner. If several records share the same top score, they are tied, and the next sections explain how LGE treats them.

### The per-read label

LGE gives every read one of four labels, shown by the Status icon and, once you turn it on, the **Verdict** column. A label grades the quality of the best match, with two exceptions the next section explains.

| Label | Rule |
|---|---|
| **Verified** | The best record has at least 90% identity, at least 80% query coverage, and an e-value of `1e-10` or smaller, which every returned record already meets |
| **Ambiguous** | A record came back but misses at least one of the three Verified thresholds, or LGE cannot place the read, as the next section explains |
| **Unverified** | No record came back, and the Organism column says "No significant hit" |
| **Error** | NCBI's answer held no usable entry for the read, and the Organism column says "No BLAST result" |

Ambiguous is the catch-all label, and Unverified means NCBI found nothing at all. An Error read is a failed search for that read, not evidence against the taxon. The rest of the batch is still judged.

Verified says the read found a strong match, not that the match names the classifier's organism. Supporting, in the summary bar, is the second test, about the name. A read helps the verdict only when it passes both.

### Supporting, contradicting, and ties

A Verified read is **supporting** when its best match belongs to the selected taxon's [clade](../../GLOSSARY.md#clade), the taxon with everything below it in the Kraken 2 report, and **contradicting** when it does not. For a species or anything below it, LGE judges at species level, so the clade of a strain is its whole species and a match to a sister strain still supports. For a taxon above species, such as a genus, the clade is that taxon with everything below it, so a match to any species inside it supports.

LGE judges by [taxonomy ID](../../GLOSSARY.md#taxonomy-id), the number NCBI gives every taxon. NCBI often files a record under a strain's own taxonomy ID, which the report never lists. LGE then compares names, and the record joins the clade when its organism name contains the full name of any taxon in the clade. That is how a record NCBI names Human alphaherpesvirus 1 supports *Simplexvirus humanalpha1*, the species name Kraken 2 uses for the same virus. With a species selected, any other species contradicts, even one in the same genus, so a match to Human alphaherpesvirus 2 contradicts HSV-1, and so does one to Human gammaherpesvirus 4, a different herpesvirus.

Many records can match a read equally well. A stretch of 76 bases that every HSV-1 genome carries can match many HSV-1 records at the same top bit score, and NCBI lists such ties in an order that means nothing. So LGE looks at every record tied for best, not only the first, and a read supports when any tied record belongs to the clade. When the tie also holds records outside the clade, the read still supports but carries a flag, and its Status icon becomes an outline triangle. Hold the pointer over that icon for a line of the form `Tied with <n> other records at the best score: <n> more in this taxon, <n> outside. NCBI returned <n>.`

LGE cannot place two kinds of read, and both count as Ambiguous. One is a read where more than 500 records tie for best and none of the 500 NCBI returned is in the clade, so LGE cannot tell whether an unreturned record is. The other is a read whose best record carries no taxonomy ID, so that only its organism name can judge it, and whose name shares only its first word with the taxon's name. A first word cannot tell Human alphaherpesvirus 1 from Human gammaherpesvirus 4. Ambiguous, Unverified, and Error reads count as neither supporting nor contradicting.

### The summary bar and the verdict

The summary bar reads `BLAST for <taxon>: <n> supporting, <n> contradicting (<n> reads)`, or `(<n> fragments, <m> reads)` when both mates of a pair went out, followed by a row of ten symbols and the overall verdict. When some reads came back Error, the bar adds their count, as in `2 with no BLAST result`.

The supporting share is supporting reads divided by supporting plus contradicting reads, and it sets the verdict using LGE's own cutoffs. Reads that counted as neither are left out, so the verdict can rest on far fewer reads than you sent. One supporting read and 19 Ambiguous ones give a 100 percent share, so always read the two counts beside the verdict.

| Supporting share | Verdict |
|---|---|
| 80% and above, unless every supporting read is also tied with records outside the clade | **Supported** |
| 80% and above, with every supporting read also tied with records outside the clade | **Not specific** |
| 40% up to but not including 80% | **Mixed** |
| Below 40% | **Unsupported** |
| No read supporting or contradicting | **Inconclusive** |

[Not specific](../../GLOSSARY.md#not-specific) means the reads fit the classifier's taxon, but they fit something else just as well. The bar then adds a sentence such as `Every supporting read also matches other records equally, such as <name> and <name>. These reads cannot tell <taxon> apart from them.`

The ten symbols split the submitted reads into tenths, rounded. With 20 reads each symbol stands for two reads. A filled circle stands for supporting reads, a diamond for contradicting reads, and a hollow circle for reads that counted as neither. The bar is tinted to match the verdict, but you never need the color.

Beside the verdict, `<n> also match other records equally` counts the flagged supporting reads whose tie held records outside the clade. A read judged by organism names, which happens when its best record has no taxonomy ID or LGE could not look up the row's species, is flagged when its five records start with more than one first word, and the bar counts such reads as `<n> with conflicting organisms`. Many flagged reads usually mean the reads come from a conserved region, a stretch of sequence so little changed over evolutionary time that several organisms still share it, which is a different problem from the classifier being wrong.

Two more sentences can follow the counts. `NCBI searched <database>, not the <database> this search asked for.` appears when NCBI reports searching a different database than the one LGE asked for. A sentence that begins `Collected` says how long after the first send the result came back, how many sends went out, and which request ID answered.

### Columns, copying, and exporting

Five more columns are hidden at first, Accession, Coverage, Align Length, Tax ID, and Verdict. Right-click any column header for a menu of column names, with a tick beside each one showing, and choose a name to show or hide it. LGE remembers the choice for every BLAST drawer, even after you quit.

Right-clicking a row offers **Copy FASTA**, **Copy Name**, which copies the read ID, **Copy Accession**, **Expand All**, and **Collapse All**. Two buttons run along the bottom of the drawer. **Open in NCBI BLAST** opens the full result on NCBI's site, where every record NCBI returned is listed rather than the five LGE shows. **Re-run BLAST** sends the same number of reads again as a new search, and because the draw is repeatable they are the same reads. To send more, click **Verify with BLAST…** again and raise the slider.

**Export** in the summary bar offers **Export as CSV...** and **Export as TSV...**, comma-separated or tab-separated text. The export runs `lungfish-cli blast export table` behind its own Operations Panel row and writes one line for each record of each read. Its **Verdict** column holds the per-read label, which grades match quality alone, so a contradicting read can read `verified` there. The Taxon Check column says what the read means for the taxon, `supporting`, `contradicting`, or `inconclusive`. Columns named tied, tied_in_taxon, and tied_outside count each read's tie, and Judged At says how the verdicts were judged.

### Saved verifications

LGE saves every finished verification from the taxonomy viewport inside the Kraken 2 result folder, in a folder of its own under `blast-verifications`. That folder holds a copy of the reads sent, the result, and its [provenance](../../GLOSSARY.md#provenance) record. When you select the taxon again, even after quitting LGE, its newest verification waits in the drawer's BLAST Results tab, and clicking **BLAST Results** shows it. The other viewers save their searches too, and a saved result comes back when you return to its row.

## What good looks like

Read the verdict and the per-read rows together, because either alone can mislead you.

A verification you can rely on has a Supported verdict, and per-read rows that name the classifier's organism with identity and coverage in the high nineties and e-values far below `1e-10`. The example run on the cornea sample came back that way. Its summary bar reads 20 supporting, 0 contradicting, with all ten circles filled and the verdict Supported. Every read's best record is Human alphaherpesvirus 1 with 100 percent query coverage, 19 at 100.0 percent identity and one at 98.7 percent, a single mismatch in 76 bases. A read flagged for tying with a laboratory construct, an engineered DNA molecule that carries a piece of HSV-1, still supports the taxon. With every read supporting, none was set aside as Ambiguous, so the 100 percent covers all the reads you sent. Leave the slider at 20 for any verification whose answer you intend to use.

A Not specific verdict names its look-alike records in the bar's sentence. If they are laboratory constructs that carry a piece of the same organism, the reads still fit it, but BLAST cannot confirm it. If they are another species, the reads come from sequence the two share, so check whether the reads cover the whole genome or pile up in one shared stretch, for example in the coverage sparkline of [EsViritu's results](03-running-esviritu.md#reading-the-results).

An Unsupported verdict is not automatically bad news about your sample. If the rows consistently name one other organism with high identity, the classifier probably assigned the reads to a relative it held, and that other organism is the better answer. If they name a scatter of unrelated organisms at middling identity, the reads are probably uninformative. That happens when a read is low-complexity, meaning it repeats one or two bases over most of its length, or when it still carries adapter, the short synthetic sequence attached during library preparation. The conclusion for such a taxon is that it is unresolved.

Two results call for another run rather than an interpretation. Inconclusive means no read found a strong match, which on short or poor-quality reads says more about the reads than the taxon, so send more reads or verify a taxon with longer ones. Mixed on a small sample can be sampling noise, since two supporting reads out of three make a 67 percent share on evidence far too thin to act on. Raise the slider, up to the 30 reads that remain in the hour after a 20-read search, and run it again.

Expect small differences between two runs of the same reads. NCBI returns a sample of the records tied for best, and a run can miss the best record itself, so a 76-base read can show 100 percent on one run and 98.7 percent, one mismatch, on the next. A read tied with many records outside the clade can count against the taxon on a run whose sample holds no clade record.

Finally, Supported says only that the reads LGE sent match the organism the classifier named. It does not say the classifier's read counts are right, that the abundance estimate holds, or that a related organism is absent.

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

Replace `<timestamp>` with the rest of the Viral result's folder name. The first two lines each store a folder path under a short name, so `$PROJECT` and `$RESULT` stand for those paths in the lines below. `--kreport` names the [Kraken 2 report](../../GLOSSARY.md#kreport), the table of counts per taxon. Taxonomy ID 10298 is the Human alphaherpesvirus 1 row, which sits one level below the *Simplexvirus humanalpha1* row you clicked and holds the same 886,221 pairs, as [Running Kraken 2](02-running-kraken2.md#reading-the-results) explains. `--kraken-output` names the per-read output file whose k-mer counts choose the mate. `--source` names the reads and can repeat. It takes a `.lungfishfastq` bundle, read by the roles of its files, or loose files in the order R1, R2, and then the files of merged or single reads. `--format json` prints the result as JSON, a structured text format other programs can read. Leave it out for a readable summary, which also says how many reads went as mate 2 and gives the verdict on a line labelled Confidence, a name unrelated to Kraken 2's Confidence setting. `--result-dir` saves the verification in the result's `blast-verifications` folder, where the window finds it the next time you select the taxon.

The command judges as the window does, but it draws reads only from the taxon you name, and from the taxa below it only with `--include-children`. Kraken 2 assigned every one of the 886,221 pairs to 10298 itself, so the flag changes nothing here. `--seed` with a whole number picks a random draw different from the window's.

The command waits until NCBI answers. With `--result-dir`, a search still waiting when the command stops stays under that folder, and `lungfish-cli blast resume --output <folder>` collects it later. `lungfish-cli blast in-flight` lists the searches that have not ended, and `lungfish-cli blast stop` stops LGE checking one. **Copy CLI Command** on a verification's Operations Panel row copies the `lungfish-cli blast submit` command the row ran, which sends a saved copy of the same reads rather than drawing them again.

## Next

Continue to [12S Amplicon Metabarcoding](10-twelve-s-metabarcoding.md), which names the vertebrate species in a mixed sample by exact matching and sends its unmatched sequences to BLAST in the same drawer. To go back to the classification that raised the question, return to [Running Kraken 2](02-running-kraken2.md) or [Running EsViritu](03-running-esviritu.md).
