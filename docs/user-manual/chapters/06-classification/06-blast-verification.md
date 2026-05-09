---
title: BLAST Verification
chapter_id: 06-classification/06-blast-verification
audience: bench-scientist
prereqs: [06-classification/02-running-kraken2]
estimated_reading_min: 6
task: Verify a classification hit against NCBI BLAST.
tags: [classification, blast, verification]
tools: [blast]
entry_points:
  - "Taxonomy viewport > BLAST tab"
  - "CLI: lungfish blast"
shots: []
planned_shots:
  - id: blast-tab-overview
    caption: "The BLAST tab in the taxonomy viewport with a Kraken2 hit selected and the Send to BLAST control highlighted."
  - id: blast-submission-dialog
    caption: "Submission dialog showing the representative read sequence, the chosen NCBI database, and the queued job indicator."
  - id: blast-results-table
    caption: "Returned hit table with percent identity, query coverage, e-value, and the top alignment expanded."
illustrations: []
glossary_refs: [BLAST, e-value, percent identity, query coverage, representative read]
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
it. BLAST verification is the second opinion: Lungfish takes a
representative read from a classification hit, sends it to NCBI's
nucleotide BLAST service, and shows you what the broader public sequence
collection thinks the read is.

The BLAST tab in the taxonomy viewport is wired for one decision. You
pick a hit (a row from the Kraken2, EsViritu, or TaxTriage table), choose
a representative read or contig, and submit. NCBI returns a ranked list
of database hits, each with an alignment, a percent-identity score, a
query-coverage percentage, and an e-value. If the top hit names the same
organism as the classifier, the call is corroborated. If a different
organism scores higher, you have a finding to investigate.

This is approximate verification, not ground truth. NCBI's nucleotide
database is broader than any classifier database but still not exhaustive,
and a single read is a small piece of evidence. Treat a BLAST result as a
strong second signal, not a verdict.

So what should you do with this? When a classifier reports something
surprising, do not act on the call until you have run at least one BLAST
query against it.

## What you will learn

By the end of this chapter you will be able to extract a representative
read from a classification hit, run BLAST against NCBI from inside
Lungfish, read the BLAST result table, and decide whether the BLAST
result confirms or refutes the original classifier.

## When BLAST verification earns its keep

BLAST is a network round trip to NCBI and runs serially per submission.
You do not want to BLAST every read. You want to BLAST the calls where a
second opinion changes what you would do next.

| Situation | Why BLAST helps | Typical outcome |
|---|---|---|
| Unexpected organism in a known sample type | The classifier database may not contain the actual source, forcing it to pick a near neighbour | Top BLAST hit names a different but related organism, often a closer match |
| Low-abundance hit driving a clinical or surveillance decision | Few reads means fragile evidence; one false-positive read can dominate | BLAST either confirms the species or shows the read is host or contaminant |
| Novel detection (first time you have seen this taxon in this matrix) | The classifier may be assigning by k-mer overlap to a relative; you need to know which | BLAST resolves species-level identity or flags a chimeric read |
| Disagreement between two classifiers on the same sample | Two databases disagree; a third opinion breaks the tie | BLAST agrees with one of the two, or with neither |
| Sanity check before reporting | Catch obvious database artifacts before they reach a report | BLAST confirms the call and the report goes out with one fewer asterisk |

If your sample is well-characterised and the classifier hit matches what
you expected, BLAST verification is overhead you can skip. Reserve it for
calls where the answer matters.

## Procedure

The walked example follows the SARS-CoV-2 Kraken2 run from
[Running Kraken2](02-running-kraken2.md). The top hit is *Severe acute
respiratory syndrome coronavirus 2*. The goal is to confirm that hit
against NCBI before treating the sample as a confirmed positive.

1. Open the taxonomy viewport for the Kraken2 result. Click the **BLAST**
   tab in the viewport's top toolbar.
   <!-- planned: blast-tab-overview -->
2. In the hit table, click the row for the SARS-CoV-2 hit. The right pane
   populates with a list of representative reads assigned to that taxon,
   sorted longest first. Longer reads carry more BLAST signal and queue
   faster on NCBI than dozens of short reads.
3. Select the longest read in the list. The sequence preview shows the
   read in IBM Plex Mono with its read ID and length. Verify the length
   is at least roughly 100 bases; reads shorter than that produce noisy
   BLAST results.
4. Click **Send to BLAST**. The submission dialog confirms the database
   (NCBI `nt` by default) and the program (`blastn` for nucleotide
   queries). Click **Submit**.
   <!-- planned: blast-submission-dialog -->
5. Watch the queued indicator. NCBI returns a request ID immediately and
   Lungfish polls for completion. Typical wait is 30 seconds to a few
   minutes; during NCBI peak hours the queue can stretch to ten minutes
   or more. The Operations Panel logs the wait so you can leave the
   viewport and come back.

When the job completes, the results table appears in the lower pane of
the BLAST tab.

## Reading the result

The result table lists up to 50 NCBI hits in descending order of bit
score, with five columns that matter for verification: subject accession,
subject description, percent identity, query coverage, and e-value.
<!-- planned: blast-results-table -->

**Percent identity** is the fraction of aligned positions where the query
read and the database subject agree, measured only over the aligned
region. A 99.8% identity over a 250-base alignment means two of those 250
positions disagreed.

**Query coverage** is the fraction of the query read that participated in
the alignment. A high percent identity over only 30% of the read is much
weaker evidence than a moderate identity over 95% of the read. Read both
numbers together: identity tells you how well the aligned part matches,
coverage tells you how much of the read aligned at all.

**E-value** is the number of alignments of equal or better score you
would expect by chance, given the query length and database size. Smaller
is better. An e-value of `1e-50` means the alignment is effectively
unmistakable; an e-value of `0.1` means a comparable hit could plausibly
arise from random sequence. For a viral read of a few hundred bases
matching the right organism, expect e-values at or below `1e-30`.

When the top hit's subject description names the same organism as the
classifier, with high identity (often above 98%), high coverage (often
above 90%), and a vanishingly small e-value, the classification is
corroborated. In the SARS-CoV-2 example, the top BLAST hit will name a
SARS-CoV-2 isolate accession with identity near 100% and coverage near
100%, which is the result you want.

When the top hit names a different organism, read further down the
table. If the second and third hits also disagree with the classifier,
treat the original call with suspicion. If only one or two reads from a
low-abundance hit BLAST cleanly to a different organism, the classifier
likely false-positived on a contaminating sequence and the original call
should be retracted from the report.

## A note on rate limits

NCBI BLAST is shared infrastructure. Every Lungfish user, every web
submission from elsewhere on the planet, and every automated pipeline
queues against the same servers. Two practical consequences follow.

First, runs may queue. A submission that returned in 20 seconds last week
may take five minutes today. The queue is not a Lungfish bug; the
Operations Panel timestamp shows you the wait.

First-class etiquette matters here. NCBI publishes usage limits (no more
than one submission every ten seconds, no more than 50 sequences per hour
from a single IP for sustained use) and asks heavy users to run BLAST
locally instead. Lungfish enforces a minimum spacing between submissions
to keep you below the threshold, but a long batch of verifications can
still hit the per-hour ceiling. If you need to BLAST more than a handful
of reads, batch them and step away rather than resubmitting in a tight
loop.

For routine, large-scale verification, install a local BLAST database via
the appropriate plugin pack and switch the BLAST tab's database selector
to the local path. Local BLAST has no network queue and no rate limit.
The trade-off is that the database is whatever you downloaded, frozen at
that moment, while NCBI's `nt` is updated continuously.

## Next

This is the last chapter in [Classification](.). Continue to
[Assembly](../07-assembly/) for de novo assembly workflows, or back to
[Reading the Variant Browser](../05-variants/02-reading-the-variant-browser.md)
for variant workflows.
