---
title: Running SPAdes
chapter_id: 07-assembly/02-running-spades
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble]
estimated_reading_min: 10
task: Assemble Illumina viral or bacterial reads with SPAdes and review the resulting contigs.
tags: [assembly, spades, illumina, viral, bacterial]
tools: [spades]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Assembly > SPAdes"
  - "CLI: lungfish assemble"
shots: []
planned_shots:
  - id: assembly-wizard-spades
    caption: "The Assembly wizard with SPAdes selected and viral mode chosen."
  - id: assembly-viewport
    caption: "The assembly viewport showing contigs ranked by length with N50 highlighted."
  - id: contig-inspector
    caption: "Inspector pane for the longest contig showing length, coverage, and GC content."
illustrations: []
glossary_refs: [N50, contig, assembly bundle]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

SPAdes is the dominant short-read assembler for viral and bacterial isolates. It builds contigs from Illumina reads by constructing a de Bruijn graph (a network of overlapping k-mer fragments), simplifying that graph to remove sequencing-error branches, and then walking the surviving paths to produce contiguous sequences. For most short-read viral and bacterial data, SPAdes is the assembler people reach for first.

SPAdes ships several specialised modes. Viral mode (`--viral`) is tuned for the genome sizes (a few thousand to a few hundred thousand bases) and the deep, sometimes uneven coverage profiles that viral sequencing produces. Plasmid, metagenomic, and isolate modes target other organism profiles with different coverage assumptions. Picking the right mode matters more than tuning k-mer sizes by hand: the wrong mode can fragment a clean genome into dozens of short contigs, or fuse a metagenome into chimeric ones.

Lungfish runs SPAdes through the Assembly wizard. You point it at a paired or single FASTQ bundle, choose the mode, and Lungfish writes a `.lungfishref` assembly bundle into the project's `Assemblies/` folder. Each contig becomes a sequence inside the assembly bundle, and the assembly viewport shows the contig list ranked by length with per-contig length, coverage, and GC content.

So what should you do with this? Pick viral mode for any single-virus isolate, pick the default isolate mode for bacterial WGS, and for everything else read the mode table below before clicking Run.

## What you will learn

By the end of this chapter you will be able to run SPAdes against a FASTQ bundle, select the right SPAdes mode for your sample, navigate the assembly viewport, read the contig list and identify the longest contig as the target genome, and inspect a contig as a sequence in its own viewport.

## SPAdes modes

SPAdes exposes its specialised pipelines as flags. Lungfish surfaces the most common ones in the wizard's mode picker. The flag column is what the underlying SPAdes command line receives.

| Mode | Flag | Use when |
|---|---|---|
| Isolate (default) | `--isolate` | Single bacterial isolate, Illumina paired-end, even coverage |
| Viral | `--viral` | Single virus or viral isolate, including amplicon Illumina data |
| Plasmid | `--plasmid` | Plasmid-only sequencing, or extracting plasmids from an isolate |
| Metagenomic | `--meta` | Shotgun metagenome, multiple organisms at varying abundance |
| RNA | `--rna` | Eukaryotic RNA-seq for transcript assembly, not viral |

Two notes on choosing. Viral mode is the right pick for every single-virus dataset in this manual, including SARS-CoV-2 amplicon Illumina, even though "amplicon" is technically not what the original SPAdes paper validated. The viral mode is permissive about coverage non-uniformity, which is what amplicon protocols produce. Metagenomic mode is the right pick for wastewater shotgun data, but it is the wrong pick for wastewater amplicon data: amplicon data should still go through viral mode because the target organism count is one.

## Procedure

1. Open the FASTQ bundle you want to assemble. Foundation chapter [Importing FASTQ](../03-reads/01-importing-fastq.md) covers how to get reads into a project. Confirm in the Inspector that the bundle shows two paired files (or one file for single-end) and a non-zero read count.

2. Choose `Tools > FASTQ/FASTA Operations > Assembly > SPAdes`. The Assembly wizard opens.

   <!-- planned: assembly-wizard-spades -->

3. In the wizard, the input FASTQ bundle is pre-filled from the active selection. Confirm it is the bundle you intended. If not, use the input picker to choose the correct one.

4. Choose the SPAdes mode. For the worked example below, choose `Viral`. For bacterial WGS, leave it on `Isolate`. Refer to the mode table above if you are unsure.

5. Set the output name. Lungfish suggests `<input-name>-spades` by default. The output goes into the project's `Assemblies/` folder.

6. Click `Run`. Lungfish materialises the FASTQ files (reconstructing full reads if the bundle is virtual), launches SPAdes in its conda environment, and streams progress into the Operations panel. A SARS-CoV-2 amplicon run on a laptop typically finishes in two to five minutes; a bacterial isolate at 100x coverage takes ten to thirty minutes.

7. When the run completes, the new assembly bundle appears in `Assemblies/` and opens automatically in the assembly viewport.

   <!-- planned: assembly-viewport -->

## Worked example: SRR36291587

The fixture for this walkthrough is the SARS-CoV-2 Illumina amplicon run `SRR36291587`. Citation for the fixture lives in its `README.md`. Download the run via `File > Import > From SRA` and run the Assembly wizard against the resulting FASTQ bundle with viral mode selected.

When SPAdes finishes, the assembly viewport opens with one striking row at the top of the contig list: a single contig roughly 29,900 bases long. The exact number varies a little run to run because the assembly graph traversal is not strictly deterministic when coverage is borderline at the genome ends, but you should expect something between 29.7 and 29.9 kb. Coverage on that contig will be in the hundreds of x for a typical amplicon library.

Click the row. The Inspector shows length, coverage (the mean depth SPAdes estimates from the de Bruijn graph), and GC content. SARS-CoV-2 has a GC content near 38 percent; if your top contig reads close to that, you have the target genome. A GC content of 50 percent or higher on a "viral" contig usually means you assembled a host or contaminant fragment instead, and you should look further down the list for the genuine viral contig.

Double-click the contig. It opens in a sequence viewport, and from there you can use it as a reference for downstream mapping. Chapter [Extracting Contigs](04-extracting-contigs.md) covers promoting a contig into a reference bundle.

   <!-- planned: contig-inspector -->

Below the top contig you may see a handful of short contigs, often a few hundred bases each. These are typically primer-derived fragments, host carry-over, or fragments split off at coverage dropouts in the amplicon scheme. They are normal for amplicon data and you can ignore them for consensus work, though they are worth a glance if you are tracking contamination.

## Interpretation

A good SARS-CoV-2 assembly has three properties: one dominant contig of roughly 29.9 kb, even coverage along that contig (no zero-depth gaps when you flip to the alignment view), and a GC content near 38 percent. If all three hold, the assembly is publishable as a genome and usable as a per-sample reference for mapping and variant calling.

The headline assembly metrics live in the assembly bundle's Inspector. N50 is the most common one. N50 is defined so that half the assembly's total length is contained in contigs of at least N50 bases. For a SARS-CoV-2 amplicon assembly that resolves to a single ~30 kb contig, N50 equals the length of that single contig and tells you very little. For a bacterial assembly that resolves to dozens or hundreds of contigs, a higher N50 means a less fragmented assembly. Total length and contig count fill in the picture: a 5 Mb total in 50 contigs with N50 of 200 kb is a tidy bacterial isolate; a 5 Mb total in 5,000 contigs with N50 of 1 kb is a stressed assembly worth re-running with different parameters or more reads.

What does "good" look like by organism? Below are practical thresholds. They are simplifications, not rules.

| Organism | Single contig of | Total length near | N50 above |
|---|---|---|---|
| SARS-CoV-2 | ~29.9 kb | 29.9 kb | 29.9 kb |
| Influenza A (one segment) | ~1 to 2.4 kb | 13.5 kb across 8 segments | 1.5 kb |
| E. coli isolate | many contigs | 5.0 to 5.5 Mb | 100 kb |
| Mycobacterium tuberculosis | many contigs | 4.4 Mb | 50 kb |

If your numbers are well below these targets, the troubleshooting section is the next stop.

## Troubleshooting

Two failure modes account for almost every problem run.

**Many small contigs, no dominant one.** This is the symptom of low or uneven coverage. Open the FASTQ bundle and check the read count and the per-base quality summary from the Inspector. If the read count is in the low thousands for a 30 kb virus, you simply do not have enough data to assemble; map the reads against a known reference instead and see chapter [When to Assemble](01-when-to-assemble.md). If the read count is fine but coverage is uneven (common with degraded clinical samples on amplicon protocols), some amplicons may be missing entirely. Run the assembly anyway, but expect a multi-contig result and use the longest contigs as scaffolds rather than as a finished genome.

**No assembly produced, or SPAdes errored out.** Look at the Operations panel log. The most common cause is corrupted or truncated FASTQ files: an interrupted SRA download, a partially written export, or a paired-end mismatch where R1 and R2 have different read counts. Re-download the reads and try again. The next most common cause is choosing metagenomic mode on a single-isolate sample (or vice versa), which can collapse the graph to nothing or explode it past the available memory. Switch modes per the table above and re-run. If the log mentions "out of memory" specifically, close other apps and try again, or move to MEGAHIT for the run since it uses substantially less memory.

A third, rarer mode is the "single contig at half the expected length" result. This usually means a structural rearrangement is hiding in the data, or a large deletion broke the assembly into two halves and only the larger half met the minimum-length filter. Open the contig in a sequence viewport, BLAST it against the expected reference, and look for the missing region.

## Next

Continue to [Running Flye or Hifiasm](03-running-flye-or-hifiasm.md) for long-read assembly, or [Extracting Contigs](04-extracting-contigs.md) to use a contig as a reference downstream.
