---
title: 12S Amplicon Metabarcoding
chapter_id: 06-classification/09-twelve-s-metabarcoding
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification, 03-reads/01-importing-fastq]
estimated_reading_min: 9
task: Match merged 12S amplicon reads to a deduplicated reference FASTA, resolve cross-species ambiguity, review unresolved clusters, and export species rows.
tags: [classification, metabarcoding, twelve-s, amplicon, blast, export]
tools: [blast]
entry_points:
  - "Workflow Library > 12S Amplicon Matching"
  - "CLI: lungfish fastq 12s-match"
shots: []
planned_shots:
  - id: twelve-s-workflow-library
    caption: "The Workflow Library with the 12S Amplicon Matching workflow selected and the merged FASTQ and reference FASTA inputs listed."
  - id: twelve-s-result-species-table
    caption: "The 12S result viewport showing the species table with per-species read counts after exact matching."
  - id: twelve-s-unresolved-clusters
    caption: "The unresolved-cluster review pane grouping reads that matched more than one species or none."
  - id: twelve-s-blast-review
    caption: "An unresolved sequence cluster sent to NCBI BLAST from the review pane, with the returned hits."
  - id: twelve-s-export
    caption: "The export control writing species and unresolved rows to CSV, TSV, Excel, or FASTA."
illustrations: []
glossary_refs: [amplicon, metabarcoding, twelve-s, fastq, blast]
features_refs: [classify.twelve-s]
fixtures_refs: []
brand_reviewed: true
lead_approved: false
---

## What it is

12S metabarcoding identifies which vertebrate species are present in a
mixed sample. The 12S rRNA gene sits in the mitochondrial genome. A short
slice of it (roughly 100 to 200 bases) can be copied by PCR using primers
that bind conserved sites shared across vertebrates. The copied slice is an
amplicon, meaning a defined stretch of DNA amplified from a known pair of
primer sites. Because the interior of that slice differs
from species to species while the primer sites stay constant, reading the
amplicon tells you which animal the DNA came from. Metabarcoding is the
practice of amplifying and sequencing one marker gene across a whole mixed
sample at once, so you get an inventory of the taxa present rather than a
single answer. This is common in diet studies (what did the animal eat?),
environmental DNA or eDNA work (which species passed through this water or
soil?), and any mixed-sample setting where you need a species roster.

Lungfish resolves a 12S run by exact matching, not by a taxonomic
database. Your paired reads are first merged into one sequence per amplicon
(the forward and reverse reads overlap and are stitched together). Each
merged read is then compared base for base against a deduplicated reference
FASTA: a curated file where every record is one known 12S sequence labelled
with the species it belongs to, and identical sequences have been collapsed
so each unique sequence appears once. A read that matches a reference
exactly is assigned to that reference's species. This differs from a
classifier like Kraken2, which breaks reads into short k-mers (short
overlapping chunks of each read) and looks them up in a large
tree-of-life database. Exact matching is the right tool
here because a 12S amplicon is short, the reference is small and curated,
and a base-perfect match to a curated record is a confident species call.

No 12S fixture ships with this manual, so the reference records below are an
illustrative example, not a downloadable fixture. The sequences are
shortened and simplified to show the shape of a deduplicated reference
FASTA, and are labelled as such.

```text
>Salmo_trutta|taxid=8032|group=Fish
ACCCGCCGTCGTAAGCACGCCCTGACAAGCTTAGCTATAAGCGCAGGGCTA
>Rangifer_tarandus|taxid=9870|group=Mammal
ACCCGCCACCGCAAGCACGCCTTGATAGGCCTTAGCTATAAACACAGGGCTC
# Each header names one species and its taxid (its NCBI taxonomy ID
# number); the line below is the
# deduplicated 12S sequence a merged read must match exactly.
```

Two sequences that are identical across species produce a cross-species
match: one read that could belong to more than one animal. Lungfish handles
these explicitly rather than guessing silently, and it flags reads that
match nothing so you can review them. The practical takeaway: run the
workflow, read the species table to see what resolved, then check the
unresolved and cross-species rows before you trust the roster.

<!-- planned: twelve-s-workflow-library -->

## What you will learn

This chapter walks you through launching the 12S Amplicon Matching workflow
on merged reads and a reference FASTA, reading the resulting species table,
seeing how cross-species identical sequences get resolved, reviewing
unresolved sequence clusters, checking an unresolved cluster against NCBI
BLAST, exporting species and unresolved rows, and running the same match
from the command line.

## Exact matching against a deduplicated reference

Every merged read falls into one of three outcomes, and knowing the three
is the key to reading the result.

An exact match means the read's sequence matches exactly one species in the
reference. These reads count toward that species in the table and are the
confident core of your roster. The default matching mode is `illumina-exact`,
which accepts only exact embedded reference matches (no substitutions). A
second mode, `ont-indel`, tolerates insertion or deletion differences for
Oxford Nanopore reads, which carry more indel noise.

A cross-species match means the read's sequence is identical in more than
one species, so the read alone cannot separate them. Lungfish resolves
these by abundance: it looks at how many reads unambiguously support each
candidate species elsewhere in the sample and reassigns the shared read to
the most abundant candidate. The default policy (`strict`) lets any nonzero
lead win. A `conservative` policy requires the winner to have at least twice
the runner-up and at least ten reads, otherwise the read stays unresolved.
Reassigned reads are tracked in their own channel and never quietly folded
into the exact-match counts, so the reassignment is always auditable.

An unresolved read matches no reference at all, or was a cross-species read
that abundance could not break. These collect into unresolved sequence
clusters: groups of identical reads that share one sequence. A cluster can
mean a species missing from your reference, a sequencing artifact, or a
chimera (a hybrid sequence formed when two real amplicons join during PCR).
Lungfish runs a chimera review over the unresolved clusters and marks
likely chimeras so you do not chase them as if they were new species.

## Procedure

### Step 1. Launch 12S Amplicon Matching from the Workflow Library

Open the Workflow Library and choose **12S Amplicon Matching**. In the two
input fields, set the merged FASTQ file (or a FASTQ bundle) as the reads and
the deduplicated 12S reference FASTA as the reference. If you have a prepared
reference bundle, you can select it in place of a plain FASTA. Leave the
matching mode on the default for Illumina reads, or switch it to the
Nanopore mode if your reads came from an Oxford Nanopore run. Click **Run**.
The workflow merges any remaining paired reads, matches them, resolves
cross-species reads, reviews unresolved clusters for chimeras, and writes a
result bundle into your project.

### Step 2. Read the species table

Double-click the new result to open the 12S viewport. It opens on the
**Targets** view, which is the species table. Each row is one species, with
its scientific name, common name, taxon group (for example Fish or Mammal),
taxid, and the number of reads that matched it exactly. The summary line at
the top reports the sample count, the total exact reads, the percent of
reads left unresolved, and the number of chimera candidates. Sort by read
count to put the dominant species at the top, and use the filter field to
narrow by species or taxon group.

Some rows carry an alternate-match note. That note lists other species whose
reference sequence was identical, which is Lungfish showing its work on a
cross-species call rather than hiding it. Treat a species with only
alternate-match support more cautiously than one with unambiguous reads.

<!-- planned: twelve-s-result-species-table -->

### Step 3. Review unresolved sequence clusters

Switch the view to **Unresolved**. This table lists the unresolved sequence
clusters, each with its sequence, its read count, and a chimera status. Sort
by read count. A cluster with many identical reads and a clean (not chimera)
status is the most interesting case: it is a sequence your sample produced
in quantity that matched nothing in your reference, which often means a
species the reference does not yet cover. Clusters flagged as chimera
candidates are usually artifacts and can be set aside.

<!-- planned: twelve-s-unresolved-clusters -->

### Step 4. Verify an unresolved cluster with BLAST

Select one or more unresolved clusters and click **BLAST Verify** in the
action bar. Lungfish sends the cluster sequence to NCBI BLAST, which
compares it against GenBank and returns the closest published sequences.
The hits appear in a drawer below the table with their species, percent
identity, and accession (the GenBank record ID). A high-identity hit to a plausible species is
strong evidence that the cluster is a real animal missing from your
reference. A weak or scattered set of hits points back toward an artifact
or chimera. BLAST runs against the public NCBI service, so it needs a
network connection and takes longer than the local match.

<!-- planned: twelve-s-blast-review -->

### Step 5. Export species and unresolved rows

Click **Export** to write the current table out. The species table exports
to CSV, TSV, or Excel (`.xlsx`); the Excel export adds the unresolved rows
as a second sheet, so one file carries both. The export honors the filters
you have applied, so filtering to a taxon group and then exporting gives you
just those rows. To export the unresolved cluster sequences themselves as a
FASTA (for example to BLAST them in bulk elsewhere), use the command-line
`12s-export-unresolved` shown below; the workflow also writes an
`unresolved-sequences.fasta` into the result bundle automatically.

<!-- planned: twelve-s-export -->

## What good looks like

A healthy 12S run resolves most of its reads to a small number of species.
For a diet or eDNA sample you typically expect a handful of vertebrates to
dominate, a high exact-match percentage, and a short unresolved tail rather
than a long one.

A few things tell you the run went well. The exact-match percentage in the
summary should be high, often well above 80 percent for a clean sample
against a matching reference. A low value means your reference is missing
species or your reads are noisy. You also want the species table dominated
by a few rows with large read counts, rather than spread thinly across
dozens of near-zero rows. The unresolved tail should stay small and mostly
chimera-flagged or low-count. A large clean unresolved cluster is normal to
see once or twice and is your cue to BLAST it, but a table full of them
means the reference does not fit your sample.

A small unresolved tail is expected and is not a failure. Real samples
contain PCR artifacts, off-target amplification, and the occasional species
your reference has not catalogued. The workflow surfaces that tail on
purpose so you can judge it, rather than forcing every read into a call.

## Interpretation

The species table is a roster of the vertebrates whose 12S sequence appears,
base-perfect, in your reads. Because the match is exact against a curated
reference, a species with a solid read count is a confident call. Read the
table together with the unresolved view: the species table tells you what is
present and catalogued, and the unresolved clusters tell you what is present
but not yet explained.

Cross-species reassignment deserves a second look when two closely related
species share a 12S sequence. Lungfish reports both the winning species and,
through the alternate-match note, the species that donated reads to it. If
your question depends on separating two such species, the 12S amplicon alone
may not resolve them, and you should say so in your report rather than
treating the abundance-based winner as certain.

Your next move depends on what the unresolved view shows. If a large clean
cluster BLASTs to a plausible species, add that species to your reference
and rerun so future samples resolve it directly. If the clusters are mostly
chimeras and low-count noise, the roster in the species table is your
answer. Either way, the exported tables and the bundled provenance record
carry the exact reference, command line, and thresholds you used, so the
result is reproducible.

## Running from the command line

The same match, export, and unresolved-FASTA export are available headless
for scripting and pipelines. The commands mirror the workflow above.

```bash
# Match merged 12S amplicon reads against a deduplicated reference FASTA
lungfish fastq 12s-match merged.fastq.gz \
  --reference vertebrate-12s.fasta \
  --output-dir results \
  --output-name diet-run

# Use the conservative cross-species policy instead of the default
lungfish fastq 12s-match merged.fastq.gz \
  --reference vertebrate-12s.fasta \
  --output-dir results --output-name diet-run \
  --ambiguity-resolution conservative

# Export the species table to CSV, TSV, or Excel (xlsx)
lungfish fastq 12s-export --bundle results/diet-run.lungfish12s \
  --export-format csv --output species.csv

# Export unresolved clusters above a read threshold to FASTA for BLAST
lungfish fastq 12s-export-unresolved --bundle results/diet-run.lungfish12s \
  --min-reads 5 --output unresolved.fasta
```

## Next

Return to [What Is Read Classification](01-what-is-classification.md) for
how 12S matching sits beside the taxonomic classifiers, or see [BLAST
Verification](06-blast-verification.md) for more on confirming an
unresolved cluster against NCBI.
