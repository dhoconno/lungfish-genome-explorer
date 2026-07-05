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
  - "Tools > FASTQ/FASTA Operations > Assembly…"
  - "CLI: lungfish assemble"
shots: []
planned_shots:
  - id: assembly-wizard-flye
    caption: Assembly wizard with Flye selected, an ONT FASTQ chosen as input, and the Nano HQ profile in the Profile picker.
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

The practical takeaway: if your reads came off a MinION, GridION,
PromethION, or a Sequel II in HiFi mode, run Flye or Hifiasm instead of
SPAdes. The wizard pages are nearly identical; the assembler-specific
options are few.

## What you will learn

This chapter covers how to choose between Flye (Nanopore) and Hifiasm
(PacBio HiFi), run either through the Assembly wizard, recognize that
long-read assemblies produce fewer contigs than short-read assemblies for
the same organism, and inspect the resulting bundle.

## Procedure

### Choosing the assembler

Pick the assembler that matches your read chemistry. The two regimes do
different jobs and assume different error profiles.

| Aspect | Flye | Hifiasm |
| --- | --- | --- |
| Input platform | Oxford Nanopore (R9, R10) | PacBio HiFi (CCS), and also ONT |
| Read accuracy assumption | Noisy (5 to 15 percent error, R9 to R10) | High accuracy (Q20+, ~0.1 percent error) |
| Typical use case | Viral, bacterial, fungal, small eukaryote | Vertebrate-scale diploid and polyploid genomes |
| Output style | Single primary assembly | Primary plus haplotype-resolved contigs |
| Memory footprint (small genome) | Higher than SPAdes for the same genome size | Higher still; designed for large genomes |
| Runtime on a SARS-CoV-2 amplicon run | Minutes on a laptop | Overkill; rarely the right tool |

Hifiasm is overkill for viral genomes. It was designed and tuned for
vertebrate-scale HiFi assembly with heterozygosity-aware haplotype
resolution, and applying it to a 30 kb virus uses a sledgehammer where Flye
already does the job. Hifiasm will still produce a usable assembly, and in
this version it also accepts ONT reads (it adds the `--ont` flag when the
detected read type is Nanopore), so it is not strictly HiFi-only. For a
microbe in HiFi, though, Flye is usually the lighter choice.

Two read-type limits matter here. In this version Flye accepts ONT reads
only: PacBio CLR is not an accepted Flye input, and the wizard will not
offer Flye for a CLR bundle. Other long-read assemblers exist (Canu,
NextDenovo, Raven, Shasta, wtdbg2, miniasm) and each has its own niche.
Lungfish currently ships only Flye and Hifiasm; if you have CLR data or need
one of the others, run it externally and import the contigs FASTA through
the standard FASTA import path.

### Running Flye on Oxford Nanopore reads

1. Open your project and select the FASTQ bundle that holds your ONT reads.
2. Choose **Tools > FASTQ/FASTA Operations > Assembly…**. The Assembly
   wizard opens. Set the Assembler picker to **Flye** and confirm the input
   FASTQ is your ONT bundle.
3. Choose the Flye read-quality profile in the Profile picker. The default
   is **Nano HQ**, for reads basecalled with a recent (Q20+) model. Use
   **Nano Raw** for older or noisier ONT chemistries, or **Nano Corrected**
   if your reads were error-corrected upstream.
4. Leave the **Metagenome mode** toggle (under Advanced Settings) off unless
   your sample is a mixed community. There is no genome-size field and no
   polishing control in the wizard: Flye estimates coverage and polishes
   internally. If you must pass a genome-size hint, type it into the
   advanced options text field as `--genome-size 30k`.
5. Click **Run**.

<!-- planned: assembly-wizard-flye -->

### Running Hifiasm on PacBio HiFi reads

1. Open your project and select the FASTQ bundle that holds your HiFi
   reads. HiFi FASTQ files are usually named with `.hifi_reads.fastq.gz`
   or similar; do not feed CLR reads to Hifiasm.
2. Choose **Tools > FASTQ/FASTA Operations > Assembly…**. The Assembly
   wizard opens. Set the Assembler picker to **Hifiasm** and confirm the
   input FASTQ.
3. Choose the Hifiasm profile in the Profile picker: **Diploid** (the
   default) for a heterozygous genome where you want haplotype-resolved
   output, or **Haploid/Viral** for a haploid or viral target. Hifiasm has
   no genome-size parameter; it infers structure from the reads themselves.
4. To get just the primary assembly without the alternate haplotigs, turn on
   **Primary contigs only** under Advanced Settings. There are no trio-binning
   fields in the wizard.
5. Click **Run**.

<!-- planned: assembly-wizard-hifiasm -->

The wizard hands the run to the Operations Panel, exactly as SPAdes did in
the previous chapter. You can close the wizard and watch progress in the
Operations Panel.

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

Run. Open the Assembly wizard, set the Assembler picker to Flye, leave the
Profile picker on Nano HQ (the reads are recent-model ONT), and click Run.
On a recent Apple silicon laptop the assembly finishes in a few minutes. The
Operations Panel logs each Flye stage: read overlap, graph construction,
contig extraction, and polishing.

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
