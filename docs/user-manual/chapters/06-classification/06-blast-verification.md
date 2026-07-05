---
title: BLAST Verification
chapter_id: 06-classification/06-blast-verification
audience: bench-scientist
prereqs: [06-classification/02-running-kraken2]
estimated_reading_min: 7
task: Verify a classification hit against NCBI BLAST and read the verdict.
tags: [classification, blast, verification]
tools: [blast]
entry_points:
  - "Classifier viewport > BLAST Verify"
  - "CLI: lungfish blast verify"
shots: []
planned_shots:
  - id: blast-verify-popover
    caption: "The Verify-via-NCBI-BLAST popover with the Reads to submit slider and the Run BLAST button."
  - id: blast-results-drawer
    caption: "The BLAST results drawer showing the verdict, the verification rate, and the per-read hit rows."
illustrations: []
glossary_refs: [BLAST, e-value, percent identity, query coverage]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A classifier like Kraken2 sorts each read into a taxon by matching its
k-mers against a reference database. The verdict is only as trustworthy as
that database. Leave the true source organism out of it, and the classifier
does the one thing it can: it names the closest match it has ever seen, and
names it with confidence. BLAST verification is the second opinion. Lungfish
pulls a sample of the reads a classifier assigned to a taxon, ships them to
NCBI's nucleotide BLAST service, and reports how many of them the broader
public sequence collection independently backs.

The point is a verdict, not a wall of hits. For the reads it submits, Lungfish
asks a single question: does each read's best NCBI match name the same taxon
the classifier did? It folds the answers into one of four verdicts.
**Supported** means the submitted reads mostly matched the classifier's taxon.
**Unsupported** means they mostly matched something else. **Mixed** means the
reads split. **Inconclusive** means too few reads returned a significant hit to
call it either way. Beside the verdict sits a verification rate: the percentage
of submitted reads that checked out.

This is approximate verification, not ground truth. NCBI's nucleotide
database reaches wider than any classifier database, yet it is still not
exhaustive, and a sample of reads is still only a sample. Treat a verdict as a
strong second signal, not a final word.

In practice, when a classifier surprises you, hold off on the call until you
have run a BLAST verification against it and read the verdict.

## What you will learn

By the time you finish, you can launch BLAST Verify from a classifier
viewport, choose how many reads to submit, read the verdict and verification
rate in the results drawer, and fire the same verification from the command
line.

## When BLAST verification earns its keep

BLAST is a network round trip to NCBI, and each submission runs one at a time.
Verifying every taxon would be a waste. Verify the calls where a second
opinion changes what you do next.

| Situation | Why BLAST helps | Typical outcome |
|---|---|---|
| Unexpected organism in a known sample type | The classifier database may not contain the actual source, forcing it to pick a near neighbour | The verdict comes back Mixed or Unsupported, with hits naming a related organism |
| Low-abundance hit driving a clinical or surveillance decision | Few reads means fragile evidence; one false-positive read can dominate | The verdict either Supports the taxon or shows the reads are host or contaminant |
| Novel detection (first time you have seen this taxon in this matrix) | The classifier may be assigning by k-mer overlap to a relative; you need to know which | The verification rate resolves how much of the signal holds up |
| Disagreement between two classifiers on the same sample | Two databases disagree; a third opinion breaks the tie | BLAST agrees with one of the two, or with neither |
| Sanity check before reporting | Catch obvious database artifacts before they reach a report | A Supported verdict lets the report go out with one fewer asterisk |

If your sample is well characterised and the hit matches what you expected,
BLAST verification is overhead you can skip. Save it for the calls where the
answer matters.

## Procedure

The worked example follows the SARS-CoV-2 Kraken2 run from
[Running Kraken2](02-running-kraken2.md). Its top hit is *Severe acute
respiratory syndrome coronavirus 2*. The goal is to confirm that hit
against NCBI before treating the sample as a confirmed positive. The same
flow opens from the Kraken2, EsViritu, TaxTriage, and NAO-MGS viewports, and
from the [Novel Virus Diagnostics](08-novel-virus-detection.md) viewport,
where **BLAST Verify** submits the selected contig sequence instead of a
sample of reads.

1. Open the classifier's result viewport and select the taxon row you want to
   check. You never pick individual reads. Lungfish chooses them for you.

2. Click **BLAST Verify** in the viewport's action bar. The same action lives
   on a taxon's right-click menu, labelled "BLAST Verify…" or
   "BLAST Matching Reads…". A popover opens, titled
   `Verify "<taxon>" via NCBI BLAST`.
   <!-- planned: blast-verify-popover -->

3. Set the **Reads to submit** slider. It defaults to 20 and ranges from 1 to
   50, capped at the number of reads available for the taxon. Lungfish picks
   that many reads for you, spread across the taxon's coverage so the sample is
   representative rather than clustered in one spot. Nothing else to choose: no
   read list to scroll, no database or program to pick. The database is NCBI
   `nt` and the program is `blastn`, both fixed.

4. Click **Run BLAST**. NCBI hands back a request ID, and Lungfish polls until
   the job is done. Typical wait is 30 seconds to a few minutes. During NCBI
   peak hours the queue can stretch past ten minutes. The Operations Panel logs
   the wait, so you can leave the viewport and come back.

When the job finishes, the results appear in a drawer at the bottom of the
viewport.

## Reading the result

The drawer leads with the verdict and the verification rate. Read those
first. They are the answer. A **Supported** verdict with a high verification
rate means most submitted reads matched the taxon on their own and the call
holds up. An **Unsupported** or **Mixed** verdict means the reads disagree
with the classifier, and the call needs a closer look.

<!-- planned: blast-results-drawer -->

Below the verdict, the drawer breaks results down by submitted read. Each read
is a parent row that expands to its NCBI hits, up to about five per read, the
fixed hit-list size. The columns run Status, Read ID, Organism, Identity,
E-value, Bit score, Accession, Coverage, Align Length, Tax ID, and the
per-read Verdict. Three of them carry most of the weight.

**Percent identity** is the fraction of aligned positions where the query
read and the database subject agree, counted only over the aligned region. A
99.8% identity across a 250-base alignment means two of those 250 positions
disagreed.

**Coverage** is the fraction of the read that took part in the alignment. A
high identity over just 30% of the read is far weaker evidence than a
moderate identity over 95% of it. Read the two numbers together.

**E-value** is how many alignments of equal or better score you would expect
by chance, given the query length and the database size. Smaller is better.
For a viral read of a few hundred bases matching the right organism, an
e-value at or below `1e-30` is effectively unmistakable. An e-value near `0.1`
could just as easily come from random sequence.

Two buttons sit on the drawer. **Open in NCBI BLAST** loads the full NCBI
result for the submission in your web browser, where every hit NCBI returned
is on view. **Re-run BLAST** submits the same taxon again, the move when a
queue timed out or you want a fresh sample of reads.

When the verdict is Supported and the per-read hits name the classifier's
organism with high identity, high coverage, and vanishingly small e-values,
the classification stands corroborated. When the verdict is Unsupported, read
the per-read organisms. If they keep naming a different organism, treat the
original call with suspicion and consider pulling it from the report.

## Running verification from the command line

The same verification runs headless. The subcommand is `blast verify`, and it
needs three inputs the GUI assembles for you: the Kraken2 report, the per-read
Kraken2 output, and the source FASTQ.

```bash
lungfish blast verify \
    --kreport class.kreport \
    --kraken-output class.kraken \
    --source reads.fastq \
    --taxid 2697049
```

`--taxid` selects the taxon to verify. `--reads` sets how many to submit
(default 20, and it must fall between 1 and 100, wider than the GUI slider's
1-to-50 range). `--include-children` also pulls reads classified to descendant
taxa. `--max-concurrent` caps in-flight submissions (default 1), and
`--extra-args KEY=VALUE` passes extra NCBI URL-API parameters straight
through. The command prints the same verdict the drawer shows: SUPPORTED,
MIXED, UNSUPPORTED, or INCONCLUSIVE, with the supporting and contradicting
counts and a link to the full NCBI result.

The **Verification Results** block prints as a key-and-value table. It lists the
Taxon, the Supporting and Contradicting counts (each out of the total reads
submitted), Inconclusive (reads with no significant hit), Ambiguous, Unverified,
Errors, the Confidence verdict, the BLAST RID, the Program, and the Database.
The Program and Database are the fixed `blastn` and `nt`, printed so a captured
log records exactly what ran.

Add `-v` (`--verbose`) to expand a **Per-Read Results** block beneath the
summary. It prints one line per submitted read: a `PASS`, `AMBG`, `FAIL`, or
`ERR` verdict, the read ID, the read's top-hit organism, and the percent
identity. Without `-v` those per-read lines stay hidden and only the summary
table and the final verdict print.

## A note on rate limits

NCBI BLAST is shared infrastructure. Every Lungfish user, every web
submission from anywhere else, and every automated pipeline queues
against the same servers. Two practical consequences follow.

First, runs may queue. A submission that came back in 20 seconds last week may
take five minutes today. The queue is not a Lungfish bug. The Operations
Panel timestamp shows you the wait.

Second, etiquette matters. NCBI publishes usage limits and asks heavy users
to throttle. Lungfish spaces its submissions apart to keep you under the
threshold, but a long run of verifications can still creep toward the per-hour
ceiling. If you have many taxa to verify, space them out and step away rather
than hammering resubmit in a tight loop. There is no local-BLAST escape
hatch: the database and program are fixed at NCBI `nt` and `blastn`, with no
local path to switch to.

## Next

This is the last verification chapter in [Classification](.). Continue to
[Novel Virus Diagnostics](08-novel-virus-detection.md) for the contig-level
BLAST import, to [Assembly](../07-assembly/) for de novo assembly workflows,
or back to
[Reading the Variant Browser](../05-variants/02-reading-the-variant-browser.md)
for variant workflows.
