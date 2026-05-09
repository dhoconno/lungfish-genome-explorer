---
title: Running Flye or Hifiasm
chapter_id: 07-assembly/03-running-flye-or-hifiasm
audience: analyst
prereqs: [07-assembly/01-when-to-assemble, 03-reads/07-ont-runs]
estimated_reading_min: 10
task: Assemble Oxford Nanopore reads with Flye or PacBio HiFi reads with Hifiasm.
tags: [assembly, flye, hifiasm, nanopore, pacbio, long-read]
tools: [flye, hifiasm]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Assembly > Flye"
  - "Tools > FASTQ/FASTA Operations > Assembly > Hifiasm"
shots: []
planned_shots:
  - id: assembly-wizard-flye
    caption: Assembly wizard with Flye selected and an ONT FASTQ chosen as input.
  - id: assembly-wizard-hifiasm
    caption: Assembly wizard with Hifiasm selected and a PacBio HiFi FASTQ chosen as input.
  - id: flye-single-contig-result
    caption: Project sidebar showing a Flye assembly bundle that contains a single full-length contig.
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Flye is the standard long-read assembler for Oxford Nanopore (ONT) data.
Hifiasm is the high-accuracy long-read assembler for PacBio HiFi data.
Lungfish runs both through the same Assembly wizard you used for SPAdes in
the previous chapter, and both produce the same kind of output: an assembly
bundle that lives under `Assemblies/` in your project folder, containing a
contigs FASTA and per-contig metadata.

Long-read assembly produces fewer and longer contigs than short-read
assembly. The reason is mechanical, not magical: a single ONT read can be
tens of thousands of bases long, and a HiFi read tens of thousands of bases
at high accuracy. Reads of that length span repetitive regions and operon
boundaries that short reads cannot bridge, so the assembly graph collapses
into a small number of long, unambiguous paths instead of a forest of short
contigs broken at every repeat. For an ONT amplicon SARS-CoV-2 run, Flye
typically returns a single contig that covers the full ~30 kb genome.

This is a simplification: long-read assemblers still struggle with very long
exact repeats, low-coverage regions, and chimeric reads. The point is that
the contig count for a viral or small bacterial genome is usually one or a
handful, not hundreds.

So what should you do with this? If your reads came off a MinION, GridION,
PromethION, or a Sequel II in HiFi mode, run Flye or Hifiasm instead of
SPAdes. The wizard pages are nearly identical; the assembler-specific
options are few.

## What you will learn

By the end of this chapter you will be able to choose between Flye
(Nanopore) and Hifiasm (PacBio HiFi), run either through the Assembly
wizard, recognize that long-read assemblies produce fewer contigs than
short-read assemblies for the same organism, and inspect the resulting
bundle.

## Procedure

### Choosing the assembler

Pick the assembler that matches your read chemistry. The two regimes do
different jobs and assume different error profiles.

| Aspect | Flye | Hifiasm |
| --- | --- | --- |
| Input platform | Oxford Nanopore (R9, R10) or PacBio CLR | PacBio HiFi (CCS) only |
| Read accuracy assumption | Noisy (5 to 15 percent error, R9 to R10) | High accuracy (Q20+, ~0.1 percent error) |
| Typical use case | Viral, bacterial, fungal, small eukaryote | Vertebrate-scale diploid and polyploid genomes |
| Output style | Single primary assembly | Primary plus haplotype-resolved contigs |
| Memory footprint (small genome) | Higher than SPAdes for the same genome size | Higher still; designed for large genomes |
| Runtime on a SARS-CoV-2 amplicon run | Minutes on a laptop | Overkill; rarely the right tool |

Hifiasm is overkill for viral genomes. It was designed and tuned for
vertebrate-scale HiFi assembly with heterozygosity-aware haplotype
resolution, and applying it to a 30 kb virus uses a sledgehammer where Flye
already does the job. If your HiFi reads are from a microbe, Flye in HiFi
mode (or a different microbial-focused tool) is often a better fit, but
Hifiasm will still produce a usable assembly.

Other long-read assemblers exist (Canu, NextDenovo, Raven, Shasta, wtdbg2,
miniasm) and each has its own niche. Lungfish currently ships only Flye and
Hifiasm; if you need one of the others, run it externally and import the
contigs FASTA through the standard FASTA import path.

### Running Flye on Oxford Nanopore reads

1. Open your project and select the FASTQ bundle that holds your ONT reads.
2. Choose **Tools > FASTQ/FASTA Operations > Assembly > Flye**.
3. In the Assembly wizard, confirm the input FASTQ is the ONT bundle. If
   your reads have been basecalled with a recent (Q20+) model, you can set
   the read-type option accordingly; otherwise leave it on the standard ONT
   raw setting.
4. Set the expected genome size if you know it. For SARS-CoV-2 use `30k`;
   for a small bacterial genome use something like `5m`. Flye uses this
   only as a hint for coverage estimation; an order-of-magnitude guess is
   fine.
5. Leave the metagenome and polishing toggles at their defaults unless you
   have a specific reason to change them. The default polishing pass is
   one round, which is sufficient for amplicon data.
6. Click **Run**.

<!-- planned: assembly-wizard-flye -->

### Running Hifiasm on PacBio HiFi reads

1. Open your project and select the FASTQ bundle that holds your HiFi
   reads. HiFi FASTQ files are usually named with `.hifi_reads.fastq.gz`
   or similar; do not feed CLR reads to Hifiasm.
2. Choose **Tools > FASTQ/FASTA Operations > Assembly > Hifiasm**.
3. In the Assembly wizard, confirm the input FASTQ. Hifiasm has no
   genome-size parameter; it infers structure from the reads themselves.
4. If you have parental short reads for trio binning, add them on the
   options page; otherwise leave the trio fields empty for a standard
   primary-plus-alternate assembly.
5. Click **Run**.

<!-- planned: assembly-wizard-hifiasm -->

The wizard hands the run to the OperationCenter, exactly as SPAdes did in
the previous chapter. You can close the wizard and watch progress in the
Operations panel.

## Worked example: ONT amplicon SARS-CoV-2 with Flye

The walkthrough below uses a hypothetical ONT amplicon SARS-CoV-2 dataset.
The shipped Lungfish fixtures cover the short-read SARS-CoV-2 case (see
`Tests/Fixtures/sarscov2/`); a matched ONT fixture is not yet packaged, so
treat the run numbers below as representative rather than reproducible
byte-for-byte. The qualitative result (a single full-length contig) is
what you should expect from any reasonably covered ONT amplicon run.

Setup. A FASTQ bundle of roughly 50,000 ONT reads from a tiled-amplicon
SARS-CoV-2 protocol, basecalled with a recent ONT model, sits in the
project's `Imports/` folder. Mean read length is ~400 bp because the
amplicons are short; a whole-genome ligation library would have a longer
mean.

Run. Open the Assembly wizard, choose Flye, set the genome size to `30k`,
and click Run. On a recent Apple silicon laptop the assembly finishes in
a few minutes. The Operations panel logs each Flye stage: read overlap,
graph construction, contig extraction, and polishing.

Result. The new bundle in `Assemblies/` contains a single contig of about
29.8 kb. That contig is the assembly's reconstruction of the SARS-CoV-2
genome from your reads. Coverage across the contig will be uneven because
amplicon coverage is uneven by design, with dropouts at amplicons that
amplified poorly.

<!-- planned: flye-single-contig-result -->

If you instead see two or three contigs, the most likely cause is an
amplicon dropout that broke the genome into pieces; this is interpretation
information, not a failure of the assembler. If you see dozens of short
contigs, something is wrong upstream: check that the reads were basecalled
with a recent model, that adapters were trimmed, and that the input is
actually long-read data and not short reads mislabeled as ONT.

## Interpretation

A long-read assembly bundle looks the same in the project sidebar as a
short-read one. What differs is what you see when you open it.

Contig count. For a viral genome assembled from ONT amplicon reads, expect
one contig. For a small bacterial isolate from whole-genome ONT reads,
expect a handful (one chromosome plus any plasmids). For HiFi data on a
microbe, expect similarly low counts. If the count is dramatically higher,
treat that as a signal that input quality, coverage, or read type is
mismatched to the assembler.

Contig length. The longest contig should approach the expected genome
size. For SARS-CoV-2 that is ~29.9 kb; a Flye contig in the 29.5 to 30 kb
range is normal. Substantially shorter contigs mean the assembler could
not bridge a gap, usually due to coverage dropout.

What to do next. Treat the assembly bundle exactly like any other
reference-shaped input. The next chapter, [Extracting
Contigs](04-extracting-contigs.md), shows how to promote a contig to a
reference sequence so you can map reads back to it, call variants against
it, or use it as the scaffold for a downstream workflow.

A note on resource use. Flye is more demanding than SPAdes for the same
small-genome input. The trade is paid in memory and wall time, and the
return is the long contigs that make downstream work easier. For a viral
amplicon run the absolute cost is still small (minutes, a few GB of RAM);
for a bacterial isolate plan for tens of GB of RAM and tens of minutes;
for anything larger consult the Flye documentation directly. Hifiasm's
memory footprint scales with genome size and heterozygosity and can run
into the hundreds of GB on vertebrate genomes; this is why it is rarely
the right tool for microbial work.

## Next

Continue to [Extracting Contigs](04-extracting-contigs.md) to use a contig
as a reference for a downstream workflow.
