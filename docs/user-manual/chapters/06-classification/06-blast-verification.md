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

A classifier such as Kraken2 assigns each read to a taxon by matching its
k-mers against a reference database. The result is only as good as that
database. If the database does not contain the true source organism, the
classifier will pick the closest thing it has seen and confidently report
it. BLAST verification is the second opinion. Lungfish takes a sample of the
reads a classifier assigned to a taxon, sends them to NCBI's nucleotide BLAST
service, and reports what fraction of them the broader public sequence
collection independently agrees with.

The point is a verdict, not a wall of hits. For the reads it submits, Lungfish
asks: does each read's best NCBI match name the same taxon the classifier did?
It rolls the answers up into one of four verdicts. **Supported** means the
submitted reads mostly matched the classifier's taxon. **Unsupported** means
they mostly matched something else. **Mixed** means the reads split. And
**Inconclusive** means too few reads returned a significant hit to decide.
Alongside the verdict you get a verification rate: the percentage of submitted
reads that were independently verified.

This is approximate verification, not ground truth. NCBI's nucleotide
database is broader than any classifier database but still not exhaustive, and
a sample of reads is still a sample. Treat a verdict as a strong second
signal, not a final answer.

In practice, when a classifier reports something surprising, do not act on
the call until you have run a BLAST verification against it and read the
verdict.

## What you will learn

By the end of this chapter you will be able to launch BLAST Verify from a
classifier viewport, choose how many reads to submit, read the verdict and
verification rate in the results drawer, and run the same verification from
the command line.

## When BLAST verification earns its keep

BLAST is a network round trip to NCBI and runs serially per submission. You
do not want to verify every taxon. You want to verify the calls where a
second opinion changes what you would do next.

| Situation | Why BLAST helps | Typical outcome |
|---|---|---|
| Unexpected organism in a known sample type | The classifier database may not contain the actual source, forcing it to pick a near neighbour | The verdict comes back Mixed or Unsupported, with hits naming a related organism |
| Low-abundance hit driving a clinical or surveillance decision | Few reads means fragile evidence; one false-positive read can dominate | The verdict either Supports the taxon or shows the reads are host or contaminant |
| Novel detection (first time you have seen this taxon in this matrix) | The classifier may be assigning by k-mer overlap to a relative; you need to know which | The verification rate resolves how much of the signal holds up |
| Disagreement between two classifiers on the same sample | Two databases disagree; a third opinion breaks the tie | BLAST agrees with one of the two, or with neither |
| Sanity check before reporting | Catch obvious database artifacts before they reach a report | A Supported verdict lets the report go out with one fewer asterisk |

If your sample is well-characterised and the classifier hit matches what
you expected, BLAST verification is overhead you can skip. Reserve it for
calls where the answer matters.

## Procedure

The worked example follows the SARS-CoV-2 Kraken2 run from
[Running Kraken2](02-running-kraken2.md). The top hit is *Severe acute
respiratory syndrome coronavirus 2*. The goal is to confirm that hit
against NCBI before treating the sample as a confirmed positive. The same
flow is available from the Kraken2, EsViritu, TaxTriage, and NAO-MGS
viewports, and from the
[Novel Virus Diagnostics](09-novel-virus-detection.md) viewport, where
**BLAST Verify** submits the selected contig sequence rather than a sample
of reads.

1. Open the result viewport for the classifier and select the taxon row you
   want to check. You do not pick individual reads; Lungfish chooses them for
   you.

2. Click **BLAST Verify** in the viewport's action bar. (A taxon's
   right-click menu offers the same action, labelled "BLAST Verify…" or
   "BLAST Matching Reads…".) A popover opens, titled
   `Verify "<taxon>" via NCBI BLAST`.
   <!-- planned: blast-verify-popover -->

3. Set the **Reads to submit** slider. It defaults to 20 and ranges from 1 to
   50, capped to the number of reads available for the taxon. Lungfish selects
   that many reads automatically, stratified across the taxon's coverage so
   the sample is representative rather than clustered. There is no
   representative-read list to scroll and no database or program to choose:
   the database is NCBI `nt` and the program is `blastn`, both fixed.

4. Click **Run BLAST**. NCBI returns a request ID and Lungfish polls for
   completion. Typical wait is 30 seconds to a few minutes; during NCBI peak
   hours the queue can stretch to ten minutes or more. The Operations Panel
   logs the wait, so you can leave the viewport and come back.

When the job completes, the results appear in a drawer at the bottom of the
viewport.

## Reading the result

The drawer leads with the verdict and the verification rate. Read those
first: they are the answer. A **Supported** verdict with a high verification
rate means most submitted reads independently matched the taxon and the call
holds up. An **Unsupported** or **Mixed** verdict means the reads disagree
with the classifier and the call needs investigation.

<!-- planned: blast-results-drawer -->

Below the verdict, the drawer lists results per submitted read. Each read is
a parent row that expands to its NCBI hits (up to about five per read, the
fixed hit-list size). The columns available are Status, Read ID, Organism,
Identity, E-value, Bit score, Accession, Coverage, Align Length, Tax ID, and
the per-read Verdict. Three of those columns carry most of the weight.

**Percent identity** is the fraction of aligned positions where the query
read and the database subject agree, measured only over the aligned region. A
99.8% identity over a 250-base alignment means two of those 250 positions
disagreed.

**Coverage** is the fraction of the read that participated in the alignment.
A high identity over only 30% of the read is much weaker evidence than a
moderate identity over 95% of the read. Read both numbers together.

**E-value** is the number of alignments of equal or better score you would
expect by chance, given the query length and database size. Smaller is
better. An e-value at or below `1e-30` is effectively unmistakable for a
viral read of a few hundred bases matching the right organism; an e-value
near `0.1` could plausibly arise from random sequence.

Two buttons sit on the drawer. **Open in NCBI BLAST** loads the full NCBI
result for the submission in your web browser, where you can see every hit
NCBI returned. **Re-run BLAST** submits the same taxon again, which is the
move when a queue timed out or you want a fresh sample of reads.

When the verdict is Supported and the per-read hits name the classifier's
organism with high identity and coverage and vanishingly small e-values, the
classification is corroborated. When the verdict is Unsupported, read the
per-read organisms: if they consistently name a different organism, treat the
original call with suspicion and consider retracting it from the report.

## Running verification from the command line

The same verification is available headless. The subcommand is `blast
verify`, and it needs three inputs the GUI assembles for you: the Kraken2
report, the per-read Kraken2 output, and the source FASTQ.

```bash
lungfish blast verify \
    --kreport class.kreport \
    --kraken-output class.kraken \
    --source reads.fastq \
    --taxid 2697049
```

The `--taxid` selects the taxon to verify. `--reads` sets how many to submit
(default 20). `--include-children` also pulls reads classified to descendant
taxa. `--max-concurrent` caps in-flight submissions (default 1), and
`--extra-args KEY=VALUE` passes additional NCBI URL-API parameters straight
through. The command prints the same verdict the drawer shows: SUPPORTED,
MIXED, UNSUPPORTED, or INCONCLUSIVE, with the supporting and contradicting
counts and a link to the full NCBI result.

## A note on rate limits

NCBI BLAST is shared infrastructure. Every Lungfish user, every web
submission from anywhere else, and every automated pipeline queues
against the same servers. Two practical consequences follow.

First, runs may queue. A submission that returned in 20 seconds last week may
take five minutes today. The queue is not a Lungfish bug; the Operations
Panel timestamp shows you the wait.

Second, etiquette matters. NCBI publishes usage limits and asks heavy users
to throttle. Lungfish enforces a minimum spacing between submissions to keep
you below the threshold, but a long run of verifications can still approach
the per-hour ceiling. If you need to verify many taxa, space them out and
step away rather than resubmitting in a tight loop. Lungfish does not offer a
local-BLAST escape hatch: the database and program are fixed at NCBI `nt` and
`blastn`, so there is no local path to switch to.

## Next

This is the last verification chapter in [Classification](.). Continue to
[Novel Virus Diagnostics](09-novel-virus-detection.md) for the contig-level
BLAST import, to [Assembly](../07-assembly/) for de novo assembly workflows,
or back to
[Reading the Variant Browser](../05-variants/02-reading-the-variant-browser.md)
for variant workflows.
