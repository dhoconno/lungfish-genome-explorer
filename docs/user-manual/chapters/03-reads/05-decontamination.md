---
title: Decontaminating Reads
chapter_id: 03-reads/05-decontamination
audience: analyst
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 8
task: Remove human and rRNA reads from a FASTQ bundle.
tags: [reads, decontamination, human, rrna, deacon, ribodetector]
tools: [deacon, ribodetector]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Decontamination > Remove Human Reads"
  - "Tools > FASTQ/FASTA Operations > Decontamination > Remove Ribosomal RNA"
  - "Tools > FASTQ/FASTA Operations > Decontamination > Remove Contaminants"
shots: []
planned_shots:
  - id: human-scrub-dialog
    caption: "The Remove Human Reads dialog with the Deacon database selected."
illustrations: []
glossary_refs: [FASTQ]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Clinical and environmental samples almost always carry reads that did not come from the organism you care about. A nasopharyngeal swab is mostly human. A wastewater concentrate carries bacterial rRNA, plant chloroplast, and laboratory vector sequence. An RNA-seq library targeted at messenger RNA still ends up dominated by ribosomal RNA if depletion was incomplete. Decontamination is the step that filters these reads out of a FASTQ bundle before downstream analysis runs.

Lungfish exposes three operations, all under `Tools > FASTQ/FASTA Operations > Decontamination`. **Remove Human Reads** runs Deacon against a prebuilt human-genome k-mer database and is the right default for clinical viral samples. **Remove Ribosomal RNA** runs either Deacon against an rRNA database or RiboDetector, a deep-learning classifier specifically trained for rRNA. **Remove Contaminants** runs Deacon against a custom reference you supply, which is what you reach for when the contaminant is a non-human host, a cloning vector, or a known lab strain. All three operations write a new FASTQ bundle with the matched reads stripped out and leave the original bundle untouched.

| Operation | When to use | Tool | Database |
|---|---|---|---|
| Remove Human Reads | Clinical or human-derived samples | Deacon | Prebuilt human-genome index, installed via Plugin Manager |
| Remove Ribosomal RNA | Total-RNA libraries with carryover rRNA | Deacon or RiboDetector | Prebuilt rRNA index (Deacon) or bundled model weights (RiboDetector) |
| Remove Contaminants | Custom host or vector | Deacon | A FASTA you supply, indexed on first use |

The output bundle is a regular FASTQ bundle. It works as input to every downstream operation, including mapping, classification, and assembly. The Operations Panel records the removal rate and read counts in its log, so you have a numerical handle on how aggressive the scrub was.

So what should you do with this? Decontaminate when the host or contaminant is a known nuisance for your downstream tool. Skip the step when the contaminants are part of the biology you are studying.

## Should I decontaminate?

The decision turns on three questions, in order.

First, **what is the sample?** A nasal or oropharyngeal swab from a human patient is mostly human reads, often 80 to 99 percent depending on viral titre. A pure cultured isolate is essentially all target organism. A wastewater concentrate is a metagenomic soup. An RNA-seq library is whatever the wet-lab depletion left behind. The answer to "what is the sample" gives you a prior on what fraction of reads are likely contaminants.

Second, **what is the downstream goal?** If you are mapping to a known reference and calling variants, host reads are wasted compute and can produce spurious off-target alignments at low mapping quality, so removing them helps. If you are running de novo assembly on a clinical sample, host removal usually helps the assembler converge faster on the viral contigs. If you are running a metagenomic classifier and the host is part of the question (for example, looking for novel human-tropic pathogens in a clinical sample), you may want host reads kept and tagged rather than removed. If you are running a wastewater surveillance classifier where the entire metagenome is the signal, leave the bundle alone.

Third, **how do you weigh sensitivity against specificity?** Decontamination is k-mer based and therefore conservative: it removes reads that share short exact matches with the host or contaminant database. A read that genuinely came from a virus but happens to share a 31-mer with the human genome will be removed too. For a clinical sample with high viral titre this loss is negligible. For a low-titre sample where every read counts, an aggressive human scrub can erase real signal. When in doubt, run the operation and compare the kept-read count to the input. A 5 to 30 percent removal rate on a clinical SARS-CoV-2 swab is normal. A 95 percent rate on the same sample suggests the sample is mostly host and the residual viral signal is fragile. A 2 percent rate on a sample you expected to be mostly host suggests the wrong database or a mis-identified sample.

So what should you do with this? For clinical viral surveillance against a chosen reference, run Remove Human Reads before mapping. For RNA-seq with visible rRNA carryover in a Bioanalyzer trace or a high rRNA percentage from a quick classification, run Remove Ribosomal RNA. For everything else, decide explicitly and record the decision in your project notes.

## Procedure

### Install the database

Decontamination operations need their database before they will run. Open the Plugin Manager from `Lungfish > Plugin Manager`, find the **Decontamination** plugin pack, and click Install. The pack pulls the Deacon binary plus the human-genome and rRNA k-mer indexes; expect a several-gigabyte download on first install. Plugin Manager mechanics are covered in `F07 Managing tools and databases` and apply identically here.

If you only want RiboDetector for rRNA removal, install the **RiboDetector** plugin pack instead. It carries the model weights and is much smaller than the Deacon rRNA index.

### Run the operation

1. In the sidebar, select the FASTQ bundle you want to clean.
2. Choose `Tools > FASTQ/FASTA Operations > Decontamination > Remove Human Reads`.
3. <!-- planned: human-scrub-dialog --> In the dialog, confirm the input bundle and the database (the human Deacon index appears preselected after install). Leave the threading at the default unless you have a reason to change it.
4. Choose an output name. The default appends `.decontam` to the input bundle name.
5. Click **Run**.

The same flow applies to Remove Ribosomal RNA (with the rRNA database or a tool toggle for RiboDetector) and to Remove Contaminants (with a file picker for the custom FASTA).

### Read the operation log

When the operation finishes, expand its row in the Operations Panel. The log reports:

- The input read count.
- The number of reads matched against the database (the removal count).
- The number of reads kept (written to the output bundle).
- The wall-clock runtime.
- The exact Deacon or RiboDetector command line, with database checksum.

The provenance sidecar on the output bundle carries the same fields plus input and output FASTQ checksums, so a re-run on the same input with the same database produces a checksum-identical output.

## Worked example: human-scrubbing a clinical SARS-CoV-2 sample

Suppose you imported a paired-end nasopharyngeal-swab FASTQ bundle from a SARS-CoV-2 surveillance run, and you plan to map against the Wuhan-Hu-1 reference and call variants. Before mapping, you run Remove Human Reads with the Deacon human database.

For a moderate-titre swab (Ct around 22 to 25), the Operations Panel will typically report something like:

```
Input reads:    2,451,308
Matched (host): 612,827
Kept:           1,838,481
Removal rate:   25.0%
Runtime:        1m 47s
```

For a low-titre swab (Ct around 30 or higher), the removal rate is often much higher, sometimes 80 to 95 percent, and the kept-read count drops accordingly. For a high-titre swab from a culture supernatant, removal can be as low as 1 to 5 percent. A removal rate of 5 to 30 percent is the typical middle of the distribution and is what you should expect for routine clinical specimens.

Pass the kept-read bundle to `Tools > Map Reads` against the SARS-CoV-2 reference. The resulting BAM is smaller, the mapping step is faster, and any low-quality alignments to host-derived sequence are gone before they have a chance to confuse the variant caller.

## Troubleshooting

**The operation fails immediately with "database not found."** The Decontamination plugin pack is not installed, or the database download was interrupted. Open Plugin Manager, find the pack, and reinstall. Database files live under `~/.lungfish/conda` alongside the tool environment.

**The custom reference for Remove Contaminants produces a removal rate near zero.** The reference probably does not match the contaminant. Check the FASTA contents and confirm the sequences are full chromosomes or contigs at the same scale as your reads. A reference of just a few hundred bases will not catch much, because Deacon needs enough k-mers to build a discriminating index. If your contaminant is a vector or plasmid, include flanking host sequence too.

**The removal rate is far higher than expected and downstream coverage is gone.** You may be scrubbing real signal. Two common causes: the wrong database (rRNA index applied to a DNA-seq library, for example), or a target organism that genuinely shares k-mers with the host (some endogenous retroviruses, integrated viral sequences, or contamination of the host reference itself). Compare the kept-read count to a quick classification of the original bundle, and if the numbers disagree by more than a factor of two, rerun without decontamination and decide whether the loss is acceptable.

**The output bundle is empty or has only a handful of reads.** The input was probably almost entirely host. This is a real result for very low-titre clinical samples and is not a software fault. Record it and move on, or repeat the wet-lab step with more input material.

## Next

Continue to [Subsetting and Extraction](06-subsetting-and-extraction.md) to learn how to take subsets of reads for testing, or skip to [Mapping](../04-alignments/01-mapping-reads-to-a-reference.md) when your reads are clean.
