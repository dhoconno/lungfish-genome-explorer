---
title: Running SPAdes (and MEGAHIT, SKESA)
chapter_id: 07-assembly/02-running-spades
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble]
estimated_reading_min: 12
task: Assemble Illumina viral or bacterial reads with SPAdes, MEGAHIT, or SKESA and review the resulting contigs.
tags: [assembly, spades, megahit, skesa, illumina, viral, bacterial]
tools: [spades, megahit, skesa]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Assembly…"
  - "CLI: lungfish assemble"
shots: []
planned_shots:
  - id: assembly-wizard-spades
    caption: "The Assembly wizard with SPAdes selected and the Isolate profile chosen."
  - id: assembly-viewport
    caption: "The assembly result viewport showing contigs ranked by length with N50 in the summary strip."
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

SPAdes is the dominant short-read assembler for viral and bacterial isolates. It builds contigs from Illumina reads by constructing a de Bruijn graph (a network of overlapping k-mer fragments), simplifying that graph to remove sequencing-error branches, and then walking the surviving paths to produce contiguous sequences. For most short-read viral and bacterial data, SPAdes is the assembler people reach for first. This chapter also covers MEGAHIT and SKESA, the other two short-read assemblers, because all three share one wizard and one procedure; only the profile choices differ.

SPAdes ships several specialised pipelines, and Lungfish surfaces three of them as profiles in the wizard: Isolate (the default), Meta, and Plasmid. Isolate suits a single virus or a single bacterial isolate; Meta suits a shotgun mixture of organisms at varying abundance; Plasmid targets plasmid-only sequencing. Picking the right profile matters more than tuning k-mer sizes by hand: the wrong profile can fragment a clean genome into dozens of short contigs, or fuse a metagenome into chimeric ones. There is no viral profile. For a single-virus dataset, including SARS-CoV-2 amplicon Illumina, the default Isolate profile is the right choice because the target organism count is one.

Lungfish runs SPAdes through the Assembly wizard. You point it at a paired or single FASTQ bundle, choose the profile, and Lungfish writes a `.lungfishref` assembly bundle into the project's `Assemblies/` folder. Each contig becomes a sequence inside the assembly bundle, and the assembly result viewport shows the contig list ranked by length with per-contig length, coverage, and GC content.

So what should you do with this? Leave SPAdes on the default Isolate profile for any single-virus isolate and for bacterial whole-genome sequencing, switch to Meta only when the sample is a known mixture, and read the profile table below before clicking Run.

## What you will learn

Here you will learn to run SPAdes (or MEGAHIT or SKESA) against a FASTQ bundle, select the right profile for your sample, navigate the assembly result viewport, read the contig list and identify the longest contig as the target genome, and script the same run from the CLI.

## SPAdes profiles

The wizard's Profile picker offers the three SPAdes pipelines Lungfish exposes. The flag column is what the underlying SPAdes command line receives.

| Profile | Flag | Use when |
|---|---|---|
| Isolate (default) | `--isolate` | Single virus or single bacterial isolate, Illumina paired-end, including amplicon data |
| Meta | `--meta` | Shotgun metagenome, multiple organisms at varying abundance |
| Plasmid | `--plasmid` | Plasmid-only sequencing, or extracting plasmids from an isolate |

Two notes on choosing. The default Isolate profile is the right pick for every single-virus dataset in this manual, including SARS-CoV-2 amplicon Illumina, because the target organism count is one. SPAdes does not ship a viral profile in Lungfish, and Isolate handles the genome sizes and the deep, sometimes uneven amplicon coverage that viral libraries produce. Meta is the right pick for wastewater shotgun data, but it is the wrong pick for wastewater amplicon data: amplicon data should still go through Isolate because the target organism count is one.

If you genuinely need SPAdes' own upstream `--viral` pipeline, it is not a selectable profile. The only way to reach it is to type it into the wizard's advanced options text field, or to pass `--extra-args "--viral"` on the CLI. Most readers will never need it; Isolate is the documented default for viral work.

## Procedure

1. Open the FASTQ bundle you want to assemble. Foundation chapter [Importing FASTQ](../03-reads/01-importing-fastq.md) covers how to get reads into a project. Confirm in the Inspector that the bundle shows two paired files (or one file for single-end) and a non-zero read count.

2. Choose `Tools > FASTQ/FASTA Operations > Assembly…`. The Assembly wizard opens. Set the Assembler picker at the top to `SPAdes`. The input FASTQ bundle is pre-filled from your selection; confirm it, or use the input picker to change it.

   <!-- planned: assembly-wizard-spades -->

3. Choose the SPAdes profile in the Profile picker. For a single virus or a bacterial isolate, leave it on `Isolate`. Refer to the profile table above if you are unsure. If you want SPAdes' slower, more accurate run, expand Advanced Settings and turn on `Careful mode`. The `Min Contig` stepper there sets a length below which Lungfish drops contigs after SPAdes finishes; it is a Lungfish post-filter, not a SPAdes flag.

4. Set the Project Name. Lungfish pre-fills the field from your input bundle name (for example `SRR36291587_assembly`), or `assembly` if it cannot derive one; type a more specific name if you want one. The output goes into the project's `Assemblies/` folder.

5. Click `Run`. Lungfish materialises the FASTQ files (reconstructing full reads if the bundle is virtual), launches SPAdes in its conda environment, and streams progress into the Operations Panel. A SARS-CoV-2 amplicon run on a laptop typically finishes in two to five minutes; a bacterial isolate at 100x coverage takes ten to thirty minutes. When the run completes, the new assembly bundle appears in `Assemblies/` and opens in the assembly result viewport.

   <!-- planned: assembly-viewport -->

## Worked example: SRR36291587

The fixture for this walkthrough is the SARS-CoV-2 Illumina amplicon run `SRR36291587`. Citation for the fixture lives in its `README.md`. Download the run via `File > Import > From SRA` and run the Assembly wizard against the resulting FASTQ bundle with SPAdes and its default Isolate profile.

When SPAdes finishes, the result viewport opens with one striking row at the top of the contig list: a single contig roughly 29,900 bases long. The exact number varies a little run to run because the assembly graph traversal is not strictly deterministic when coverage is borderline at the genome ends, but you should expect something between 29.7 and 29.9 kb. Coverage on that contig will be in the hundreds of x for a typical amplicon library.

Click the row. The Inspector shows length, coverage (parsed from the SPAdes contig header, for example the `cov_412.7` field in `NODE_1_length_29812_cov_412.7`), and GC content. SARS-CoV-2 has a GC content near 38 percent; if your top contig reads close to that, you have the target genome. A GC content of 50 percent or higher on a contig you expected to be viral usually means you assembled a host or contaminant fragment instead, and you should look further down the list for the genuine viral contig.

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

**No assembly produced, or SPAdes errored out.** Look at the Operations Panel log. The most common cause is corrupted or truncated FASTQ files: an interrupted SRA download, a partially written export, or a paired-end mismatch where R1 and R2 have different read counts. Re-download the reads and try again. The next most common cause is choosing the Meta profile on a single-isolate sample (or Isolate on a true mixture), which can collapse the graph to nothing or explode it past the available memory. Switch profiles per the table above and re-run. If the log mentions "out of memory" specifically, close other apps and try again, or move to MEGAHIT for the run since it uses substantially less memory.

A third, rarer mode is the "single contig at half the expected length" result. This usually means a structural rearrangement is hiding in the data, or a large deletion broke the assembly into two halves and only the larger half met the minimum-length filter. Open the contig in a sequence viewport, BLAST it against the expected reference, and look for the missing region.

## MEGAHIT and SKESA in the same wizard

MEGAHIT and SKESA are the other two short-read assemblers, and the procedure above is the same for both: pick the tool in the Assembler picker, confirm the input, choose a profile if one is offered, and click `Run`. They differ only in their profiles and a couple of defaults.

MEGAHIT offers three profiles in the Profile picker: `Default`, `Meta Sensitive`, and `Meta Large`. Use `Default` for a balanced run, `Meta Sensitive` for a higher-sensitivity metagenome, and `Meta Large` for a larger or more complex metagenome. On the CLI, `Default` is not a literal profile value: it corresponds to omitting `--profile` entirely, and only `meta-sensitive` and `meta-large` are named values you pass. The decision walkthrough in [When to Assemble](01-when-to-assemble.md) sends shotgun-metagenome samples here rather than to SPAdes, because MEGAHIT assembles many organisms in one pass at lower memory.

SKESA has no Profile picker, so the wizard shows only the shared controls. Lungfish pins SKESA's `--min_count 2` setting by default, which keeps small assemblies (such as low-coverage isolates or subsets) from being zeroed out by SKESA's high-coverage auto-escalation. SKESA is the conservative choice for a bacterial isolate that must meet strict isolate-quality requirements: it makes fewer mis-joins than SPAdes at the cost of slightly more contigs. The same N50 and total-length thresholds in the table above apply to MEGAHIT and SKESA output.

## Scripting the run with the CLI

The CLI command is `lungfish assemble`, and it uses the same tool and read-type compatibility model as the wizard. The first argument is the input FASTQ; pass two files with `--paired` for paired-end Illumina.

| Flag | Purpose |
|---|---|
| `--assembler <name>` | `spades` (default), `megahit`, `skesa`, `flye`, or `hifiasm` |
| `--read-type <class>` | `illumina-short-reads`, `ont-reads`, or `pacbio-hifi`; auto-detected if omitted |
| `--paired` | Treat the two input files as paired-end mates |
| `--profile <id>` | The profile, such as `isolate`, `meta-sensitive`, or `nano-hq`. There is no `viral` value. |
| `--memory-gb <n>` | Memory budget for assemblers that accept one |
| `--min-contig-length <bp>` | Minimum contig length post-filter |
| `--extra-args "..."` | Pass-through options written exactly as the underlying tool expects them |

A SARS-CoV-2 amplicon assembly is `lungfish assemble reads_R1.fastq.gz reads_R2.fastq.gz --paired --assembler spades --profile isolate`. There is no `--viral` profile; if you need SPAdes' own viral pipeline, append `--extra-args "--viral"`.

## Next

Continue to [Running Flye or Hifiasm](03-running-flye-or-hifiasm.md) for long-read assembly, or [Extracting Contigs](04-extracting-contigs.md) to use a contig as a reference downstream.
