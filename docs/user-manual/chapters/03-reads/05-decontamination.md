---
title: Decontaminating Reads
chapter_id: 03-reads/05-decontamination
audience: analyst
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 8
task: Remove human, rRNA, contaminant, and duplicate reads from a FASTQ bundle.
tags: [reads, decontamination, human, rrna, deacon, bbduk]
tools: [deacon, bbduk]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Decontamination… (then pick the operation)"
  - "CLI: lungfish fastq scrub-human, deacon-ribo, contaminant-filter, deduplicate"
shots: []
planned_shots:
  - id: human-scrub-dialog
    caption: "The Remove Human Reads dialog with the managed deacon-panhuman database selected."
illustrations: []
glossary_refs: [FASTQ]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about clearing unwanted reads (host, rRNA, contaminants, duplicates) out of a bundle before analysis. For quality and adapter cleanup, see [Trimming and Filtering](04-trimming-and-filtering.md).

Nearly every clinical or environmental sample arrives salted with reads that never came from the organism you care about. A nasopharyngeal swab is mostly human. A wastewater concentrate is a jumble of bacterial rRNA, plant chloroplast, and laboratory vector sequence. An RNA-seq library aimed at messenger RNA still comes back dominated by ribosomal RNA whenever depletion fell short. Decontamination is the step that strains those reads out of a FASTQ bundle before anything downstream runs.

Lungfish offers four operations for the job. Choose `Tools > FASTQ/FASTA Operations > Decontamination…` and pick one from the list inside the dialog. Each writes a fresh FASTQ bundle with the targeted reads gone and leaves the original untouched. The tool behind each operation differs, and so do the controls you will meet, so read the table before you open the dialog.

**Remove Human Reads** runs Deacon, a minimizer-based host-depletion tool, against the managed `deacon-panhuman` index. It is the right default for clinical viral samples. **Remove Ribosomal RNA** runs Deacon with BBMap ribokmers against the managed `deacon-ribokmers` index. **Remove Contaminants** runs bbduk, a k-mer matcher, against either the bundled PhiX spike-in or a reference FASTA you supply. **Remove Duplicates** runs clumpify to collapse PCR and optical duplicate reads.

| Operation | When to use | Tool | Database or reference |
|---|---|---|---|
| Remove Human Reads | Clinical or human-derived samples | Deacon | Managed `deacon-panhuman` index |
| Remove Ribosomal RNA | Total-RNA libraries with carryover rRNA | Deacon + BBMap ribokmers | Managed `deacon-ribokmers` index |
| Remove Contaminants | PhiX spike-in, or a custom host or vector | bbduk | Bundled PhiX, or a FASTA you supply |
| Remove Duplicates | Library prep left PCR or optical duplicates | clumpify | None (sequence-based) |

The output is a regular FASTQ bundle, ready as input to every downstream operation: mapping, classification, assembly. The Operations Panel logs the removal rate and read counts, so you always have a number on how aggressive the scrub was.

Decontaminate when the host or contaminant is a known nuisance for the tool you are about to run. Skip the step, or keep the removed reads with a retain option, when those contaminants are part of the biology you came to study.

## Should I decontaminate?

The decision turns on three questions, in order.

First, **what is the sample?** A nasal or oropharyngeal swab from a human patient is mostly human reads, often 80 to 99 percent depending on viral titre. A pure cultured isolate is essentially all target organism. A wastewater concentrate is a metagenomic soup. An RNA-seq library holds whatever the wet-lab depletion left behind. Naming the sample gives you a prior on what fraction of reads are likely contaminants.

Second, **what is the downstream goal?** Mapping to a known reference and calling variants? Host reads are wasted compute and can throw spurious off-target alignments at low mapping quality, so removing them helps. Running de novo assembly on a clinical sample? Host removal usually helps the assembler converge faster on the viral contigs. Running a metagenomic classifier where the host is part of the question, say hunting novel human-tropic pathogens in a clinical sample? You may want host reads kept and tagged rather than removed. Running a wastewater surveillance classifier where the entire metagenome is the signal? Leave the bundle alone.

Third, **how do you weigh sensitivity against specificity?** These tools match short exact subsequences (Deacon uses minimizers, bbduk uses k-mers), so they lean conservative: a read comes out when it shares enough short exact matches with the host or contaminant database. A read that genuinely came from a virus but happens to share a short exact match with the human genome goes too. For a clinical sample with high viral titre, that loss is negligible. For a low-titre sample where every read counts, an aggressive human scrub can erase real signal. When in doubt, run the operation and hold the kept-read count up against the input. A 5 to 30 percent removal rate on a clinical SARS-CoV-2 swab is normal. A 95 percent rate on the same sample warns that the sample is mostly host and the residual viral signal is fragile. A 2 percent rate on a sample you expected to be mostly host points to the wrong database or a mis-identified sample.

To decide in one line: for clinical viral surveillance against a chosen reference, run Remove Human Reads before mapping; for RNA-seq with visible rRNA carryover, run Remove Ribosomal RNA; for everything else, decide explicitly and record the decision in your project notes.

## Procedure

### Install the database

Remove Human Reads and Remove Ribosomal RNA each need a managed database before they will run. These are not one Plugin Manager "pack" but two separate managed databases: `deacon-panhuman`, the human host-depletion index, and `deacon-ribokmers`, the rRNA index, both installed through Lungfish's tool-and-database management. Install the one your operation needs, and expect a sizable download the first time. The mechanics live in `F07 Managing tools and databases` and apply here without change. The other two operations need no managed database: Remove Contaminants screens the bundled PhiX or a FASTA you point it at, and Remove Duplicates works from the read sequences alone.

### Run the operation

1. In the sidebar, select the FASTQ bundle you want to clean.
2. Choose `Tools > FASTQ/FASTA Operations > Decontamination…`. In the dialog, select `Remove Human Reads` from the operations list.
3. <!-- planned: human-scrub-dialog --> Confirm the input bundle. The managed `deacon-panhuman` database is selected for you. The pane has no extra controls for this operation.
4. Click **Run**.

The other three operations follow the same open-the-dialog, pick-the-operation rhythm but expose different controls. Read whichever line below matches the operation you need.

**Remove Ribosomal RNA** shows one segmented `Retain Reads` control (keep non-rRNA, keep rRNA, or keep both; the default keeps non-rRNA), and no RiboDetector toggle.

**Remove Contaminants** shows a `Contaminant Mode` picker (PhiX or Custom Reference), a `K-mer` field, and a `Hamming Distance` field. In Custom Reference mode you also select the contaminant FASTA in the Inputs section.

**Remove Duplicates** shows a `Preset` picker, with substitution and optical-duplicate fields exposed under the custom preset.

### Read the operation log

When the operation finishes, expand its row in the Operations Panel. The log reports:

- The input read count.
- The number of reads matched against the database (the removal count).
- The number of reads kept (written to the output bundle).
- The wall-clock runtime.
- The exact command line for the tool that ran (Deacon, bbduk, or clumpify, depending on the operation).

The provenance sidecar on the output bundle carries the same fields plus input and output FASTQ checksums, so a co-author can confirm later exactly which tool, database, and parameters produced the cleaned reads.

Every operation has a command-line equivalent: Remove Human Reads is `lungfish fastq scrub-human <reads> -o <out> --database-id deacon-panhuman`; Remove Ribosomal RNA is `lungfish fastq deacon-ribo <reads> -o <outdir>` (with `--retain norrna|rrna|both`); Remove Contaminants is `lungfish fastq contaminant-filter <reads> -o <out> --mode phix|custom`; Remove Duplicates is `lungfish fastq deduplicate <reads> -o <out>`.

Two of those commands take extra flags worth knowing. `lungfish fastq deacon-ribo` decides what counts as an rRNA match by two thresholds on Deacon's minimizer hits. `--absolute-threshold` sets the minimum number of minimizer hits a read needs, defaulting to `1`, and `--relative-threshold` sets the minimum proportion of a read's minimizers that must hit, defaulting to `0` (no proportional floor) and accepting any value from 0 to 1. Raise either one to make the filter stricter and remove fewer reads. On the human side, `lungfish fastq scrub-human` writes a plain FASTQ by default; add `--compress` to gzip the cleaned output, which Lungfish also does on its own whenever the output path you give already ends in `.gz`.

## Worked example: human-scrubbing a clinical SARS-CoV-2 sample

Say you imported a paired-end nasopharyngeal-swab FASTQ bundle from a SARS-CoV-2 surveillance run, and you plan to map against the Wuhan-Hu-1 reference and call variants. Before mapping, you run Remove Human Reads against the managed `deacon-panhuman` database.

For a moderate-titre swab (Ct around 22 to 25, where Ct is the qPCR cycle threshold, and a lower Ct means more viral template and so a higher viral fraction in the reads), the Operations Panel will typically report something like this:

```
Input reads:    2,451,308
Matched (host): 612,827
Kept:           1,838,481
Removal rate:   25.0%
Runtime:        1m 47s
```

For a low-titre swab (Ct around 30 or higher), the removal rate often climbs much higher, sometimes 80 to 95 percent, and the kept-read count falls with it. For a high-titre swab from a culture supernatant, removal can drop to 1 to 5 percent. A removal rate of 5 to 30 percent sits in the typical middle of the distribution and is what to expect for routine clinical specimens.

Pass the kept-read bundle to `Tools > Map Reads` against the SARS-CoV-2 reference. The resulting BAM is smaller, the mapping step is faster, and any low-quality alignments to host-derived sequence are gone before they get a chance to confuse the variant caller.

## Troubleshooting

**The operation fails immediately with "database not found."** The managed database the operation needs (`deacon-panhuman` for Remove Human Reads, `deacon-ribokmers` for Remove Ribosomal RNA) is not installed, or its download was interrupted. Open the tool-and-database manager, find that database, and reinstall it. Database and tool files live under `~/.lungfish/conda`.

**The custom reference for Remove Contaminants produces a removal rate near zero.** Remove Contaminants runs bbduk, which matches 31-mers by default, so the reference has to overlap the contaminant at that scale. Check the FASTA contents and confirm the sequences are full chromosomes or contigs, not a short snippet: a reference of only a few hundred bases will not catch much. If your contaminant is a vector or plasmid, include flanking host sequence too.

**The removal rate is far higher than expected and downstream coverage is gone.** You may be scrubbing real signal. Two causes are common: the wrong database (an rRNA index applied to a DNA-seq library, say), or a target organism that genuinely shares k-mers with the host, as some endogenous retroviruses, integrated viral sequences, or a contaminated host reference will. Compare the kept-read count to a quick classification of the original bundle. If the numbers disagree by more than a factor of two, rerun without decontamination and decide whether the loss is acceptable.

**The output bundle is empty or holds only a handful of reads.** The input was probably almost entirely host. That is a real result for very low-titre clinical samples, not a software fault. Record it and move on, or repeat the wet-lab step with more input material.

## Next

Continue to [Subsetting and Extraction](06-subsetting-and-extraction.md) to learn how to take subsets of reads for testing, or skip to [Mapping](../04-alignments/01-mapping-reads-to-a-reference.md) when your reads are clean.
