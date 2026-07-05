---
title: Running Amplicon MHC Genotyping
chapter_id: 09-genotyping/02-running-genotyping
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 03-reads/01-importing-fastq, 03-reads/07-ont-runs]
estimated_reading_min: 12
task: Launch amplicon MHC genotyping from the Workflow Library for miSeq reads, ONT barcode-demux and sample bundles, and full-length ONT clustering.
tags: [genotyping, mhc, amplicon, miseq, ont, clustering, workflow-library]
tools: [minimap2, savont, pbaa]
entry_points:
  - "Workflow Library > miSeq amplicon MHC genotyping"
  - "Workflow Library > Full-length ONT MHC genotyping"
  - "CLI: lungfish fastq ont-genotype"
  - "CLI: lungfish fastq genotype"
  - "CLI: lungfish fastq full-length-ont-mhc-genotype"
shots: []
planned_shots:
  - id: genotyping-workflow-config
    caption: "The miSeq amplicon MHC genotyping configuration sheet with the MHC allele-library reference bundle and paired FASTQ inputs selected."
  - id: genotyping-ont-barcode-config
    caption: "The ONT genotyping configuration sheet with barcode-demux mode selected and one sample bundle per barcode listed."
  - id: genotyping-full-length-clustering
    caption: "The full-length ONT MHC genotyping sheet showing the Savont or pbAA clustering options ahead of the genotyping step."
  - id: genotyping-operations-panel
    caption: "The Operations Panel tracking a cohort genotyping run from clustering through to a genotype result bundle."
illustrations: []
glossary_refs: [amplicon, mhc, allele, barcode, fastq, reference-bundle, clustering, pbaa]
features_refs: [genotype.amplicon, genotype.full-length-ont-mhc]
fixtures_refs: []
brand_reviewed: true
lead_approved: false
---

!!! note "Newer workflow area"
    MHC genotyping is one of the newer corners of Lungfish. A real MCM MHC
    dataset has not been added to this manual yet, so the paths, sample counts,
    and read counts in the steps below stand in for a real run rather than
    describing one you can download. They show the shape of a run, not a fixture
    you can reproduce step for step.

## What it is

A genotyping run turns prepared reads into a genotype result bundle: a
self-contained folder holding the comparison matrix, the per-sample calls, the
run statistics, and full provenance (a record of exactly which inputs, tools,
and settings produced a result). You start every run from the Workflow Library,
the launcher that lists the workflows Lungfish can run against your project
data. The reads go in as FASTQ files (the standard text format holding
sequencing reads and their quality scores) or `.lungfishfastq` bundles. The
run compares them to an MHC allele-library reference bundle: a `.lungfishmhcref`
package that carries the allele FASTA (a plain-text file listing each sequence)
plus the haplotype definitions used to name families.

In most labs that reference bundle already exists and is handed to you, so your
first move is often just to ask a colleague which `.lungfishmhcref` file to use.
If you have to build one yourself, that is a separate task covered in
[Haplotype Definitions, AI-Assisted Haplotyping, and
Export](04-haplotype-definitions-and-export.md), or the `mhc-reference-bundle`
step in the command-line section below.

Three routes share this chapter because they solve the same problem for
different data. Paired Illumina reads from a MiSeq (an Illumina short-read
platform) use the miSeq amplicon route. Reads from an Oxford Nanopore (ONT) run
that already arrive split by sample or by barcode (a short sequence tag added
per sample) use the ONT genotyping route. Long ONT reads that span a whole
allele use the full-length route, which first clusters reads into consensus
sequences, each a single cleaned-up sequence built from many overlapping noisy
reads, before genotyping them.

In practice, your one real decision is which of the three
routes fits your data, so start at the table below and match it. After that the
run is mostly a matter of watching the Operations Panel until a genotype result
bundle lands in the sidebar.

## What you will learn

The goal here is a genotype result bundle you can open in the next chapter.
Reaching it means picking the right workflow for your data, running either a
single sample or a whole cohort (a batch of samples run together), knowing where
clustering fits into the full-length ONT route, following the run in the
Operations Panel, and, if you script, reproducing all of it from the command
line.

## Choosing a genotyping workflow

Which route you use depends on the sequencing platform and, for ONT, on how the
reads reach Lungfish. The biological reason to care is read length. Short reads
are matched directly to allele targets, allowing for the odd indel (a small
insertion or deletion). Long reads are first collapsed into per-cluster
consensus sequences, so that sequencing error does not fragment a single allele
into many near-duplicate matches.

| If your data is | Use | Why |
|---|---|---|
| Paired Illumina reads from the miSeq panel | miSeq amplicon MHC genotyping (Illumina sample bundles) | Short reads map directly to the allele library with exact and indel-aware matching. |
| ONT reads, one barcode or bundle per sample | ONT MHC genotyping (sample bundles or barcode demux) | Reads are mapped and filtered per sample without a clustering step. |
| Long ONT reads that span a full allele | Full-length ONT MHC genotyping | Reads are clustered into consensus sequences with Savont or pbAA before genotyping, so a full-length allele resolves as one sequence. |

## Procedure

The procedure below shows all three routes. Run only the step that matches your
data, then finish with Step 5, which is shared.

### Step 1. Open the Workflow Library and pick a genotyping workflow

Open your project, then open the Workflow Library from the toolbar. You will see
the miSeq amplicon, ONT, and full-length ONT MHC genotyping workflows grouped
together under genotyping. Click the one that matches your data from the table above.
A configuration sheet opens where you choose inputs and the reference bundle.

<!-- planned: genotyping-workflow-config -->

Every route needs the same two things: your reads and an MHC allele-library
reference bundle. Choose the reads first, then choose the `.lungfishmhcref`
bundle as the reference. A single-sample run takes one FASTQ input. A cohort run
takes several prepared per-sample bundles at once and genotypes each one
independently, so no sample can influence another.

### Step 2. Run miSeq amplicon genotyping on paired Illumina reads

The miSeq route exists because the established MCM panel is sequenced on
Illumina, and short reads are best matched straight to the allele library. In
the configuration sheet, choose your paired FASTQ inputs and the MHC
reference bundle, then leave the mode on Illumina sample bundles. Click Run.

Lungfish maps the reads, keeps only reads that span an allele target cleanly,
and counts the retained unique-read support per allele target. The
`--min-support` setting controls how many retained reads an allele target needs
before it appears as a genotype row. Raising it trims low-support noise;
lowering it keeps faint signals for review.

### Step 3. Run ONT genotyping on barcode-demux or sample bundles

The ONT route handles reads that arrive already separated by sample, either as
one bundle per sample or split by Fluidigm barcode. It maps and filters each
sample without a clustering step, which suits reads that are already close to
one allele target each.

Choose ONT sample bundles when you have one prepared `.lungfishfastq` bundle per
animal. Choose the barcode-demux mode (demux is short for demultiplex, sorting
mixed reads back into per-sample groups by their barcode) only for legacy
barcode-split inputs: it is deprecated in favour of preparing per-sample bundles
first. In both cases, select the MHC reference bundle and click Run.

<!-- planned: genotyping-ont-barcode-config -->

### Step 4. Run full-length ONT genotyping with Savont or pbAA clustering

Long ONT reads that span a whole allele need a different first move. If each
noisy long read were matched on its own, one true allele would scatter into many
near-miss matches. Clustering collapses reads into a small number of consensus
sequences first, and those consensus sequences are what get genotyped.

Open the full-length ONT sheet, then choose your per-sample ONT FASTQ inputs and
the MHC reference bundle. The workflow clusters each sample with Savont by default,
using a quality-value cutoff and a minimum cluster size to keep only
well-supported consensus sequences. As an alternative upstream path, you can
cluster PacBio HiFi or ONT reads with pbAA first and feed the passed consensus
FASTA in as the reads. Click Run.

<!-- planned: genotyping-full-length-clustering -->

Clustering is the slow part of this route. On a cohort, Lungfish processes
samples largest-first and runs several in parallel, so the Operations Panel
message names which sample started and how many reads it carried.

### Step 5. Track the run and open the genotype result bundle

All three routes report into the Operations Panel, the running log of background
work. A genotyping run shows its stages there: staging inputs, mapping or
clustering, genotyping, and writing the report. When the row turns green, the
genotype result bundle appears in the sidebar under your project.

<!-- planned: genotyping-operations-panel -->

Click the bundle to open the genotype comparison dashboard. If the row turns red
instead, open it to read the error. A missing reference FASTA and an empty
cluster set are the two most common causes, and both name the offending input in
the message.

## Command-line parity

Each of the three routes runs headless (from the command line, with no graphical
window) with the same inputs, which is the reliable way to put a genotyping run
in a script or a pipeline. Build the MHC reference bundle once, then call the route that matches
your data. The block below reproduces the procedure above.

```bash
# Build the MHC allele-library reference bundle once.
lungfish fastq mhc-reference-bundle \
  --reference-fasta mcm-mhc-alleles.fasta \
  --haplotype-definition mcm-mhc-miseq.json \
  --output mcm-mhc.lungfishmhcref

# Route A: platform-aware amplicon genotyping (Illumina or ONT).
lungfish fastq genotype sampleA_R1.fastq.gz sampleA_R2.fastq.gz \
  --mode illumina-paired \
  --reference mcm-mhc.lungfishmhcref \
  --output-dir results/sampleA

# Route B: ONT sample-bundle genotyping.
lungfish fastq ont-genotype sampleB.lungfishfastq \
  --reference mcm-mhc.lungfishmhcref \
  --output-dir results/sampleB

# Route C: full-length ONT MHC genotyping (Savont clustering built in).
lungfish fastq full-length-ont-mhc-genotype sampleC.lungfishfastq \
  --reference mcm-mhc.lungfishmhcref \
  --output-dir results/sampleC

# Optional upstream clustering with pbAA, feeding its consensus FASTA back in.
lungfish fastq pbaa-cluster sampleC.lungfishfastq \
  --guide mcm-mhc-alleles.fasta \
  --output-dir results/sampleC-pbaa
```

Route A takes the two files a MiSeq sample comes off the instrument as, R1 and
R2 (the forward and reverse reads). Pass both, as shown. See [Importing
FASTQ](../03-reads/01-importing-fastq.md) for how those files are named and
paired. Each command writes CSV summaries, a workbook, run statistics, and
provenance into its output directory, the same artifacts the Workflow Library
produces.

## What good looks like

A healthy run finishes with a genotype result bundle in the sidebar and a green
Operations Panel row. Each reportable sample carries six locus rows (MHC-A,
MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP), each with an H1 and an H2 slot filled
by an M-family call or by `?`. Read support behind the strong calls sits well
above your `--min-support` floor, and only a minority of loci are unresolved.

## Interpretation

A run that produces a bundle but leaves most loci as `?` is telling you
something about the input, not failing silently. Thin read support across the
board usually means the reads did not cover the panel, so check that the
reference bundle matches the wet-lab panel you actually ran. A sample where
nearly every M-family has substantial support across many loci is the pattern
the overcall guard is designed to catch. That points to a mixed or
cross-contaminated input rather than a rich genotype. The next chapter shows how
to read those signals in the dashboard.

## Next

Continue to
[Reading the Genotype Comparison Viewport](03-reading-the-genotype-comparison.md)
to open the bundle you just produced and read its matrix, haplotype tape, and
call evidence.
