---
title: Running SPAdes
chapter_id: 07-assembly/02-running-spades
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 07-assembly/01-when-to-assemble]
estimated_reading_min: 15
task: Assemble Illumina paired-end reads with SPAdes, MEGAHIT, or SKESA and read the contigs the run produces.
tags: [assembly, spades, megahit, skesa, illumina, de-novo, contigs, n50]
tools: [spades, megahit, skesa]
parameters_refs: [assemble.spades, assemble.megahit, assemble.skesa]
entry_points:
  - "Tools > Assembly > SPAdes..."
  - "Tools > Assembly > MEGAHIT..."
  - "Tools > Assembly > SKESA..."
  - "CLI: lungfish-cli assemble"
shots:
  - id: assembly-wizard-spades
    caption: "The assembly sheet opened from Tools > Assembly > SPAdes..., showing the read-only Inputs rows, the Assembler and Read Type controls at the top of Primary Settings, the Isolate profile, and the Threads slider with its number field."
  - id: assembly-advanced-settings
    caption: "The sheet's Advanced Settings section with the Curated extra arguments disclosure expanded, showing the Careful mode and Skip error correction toggles above the Extra arguments field."
  - id: assembly-viewport
    caption: "The assembly result viewport after the HG002 mitochondrial run, with the contig table open and the Inspector's Assembly Context block reporting one contig, 16697 total bp, and an N50 of 16697 bp."
  - id: assembly-bundle-in-analyses
    caption: "The HG002-chrM assembly result selected as one row under Analyses in the sidebar, with its contig table open and the whole-assembly metrics in the Inspector's Assembly Context block."
  - id: contig-detail-pane
    caption: "The detail pane for the longest contig, showing its header, length, GC percent, rank, share of the assembly, and sequence."
illustrations: []
glossary_refs: [amplicon, assembly-bundle, assembly-graph, bundle, conda, contig, coverage, de-bruijn-graph, de-novo-assembly, error-correction, fastq, gc-content, k-mer, l50, mitochondrial-genome, n50, operations-panel, paired-end, plugin-pack, read, reference-bundle, scaffold, blast, inspector]
features_refs: []
fixtures_refs: [human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

SPAdes, short for St. Petersburg genome assembler, takes short sequencing [reads](../../GLOSSARY.md#read) and rebuilds the longer stretches of DNA they came from, using only the reads. A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads. Building contigs with no reference genome is [de novo assembly](../../GLOSSARY.md#de-novo-assembly), and [When to Assemble](01-when-to-assemble.md) covers when you want it.

A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases, and [Running Kraken 2](../06-classification/02-running-kraken2.md#what-it-is) shows how tools match on them. SPAdes cuts every read into k-mers and joins k-mers that overlap by all but one base into a [de Bruijn graph](../../GLOSSARY.md#de-bruijn-graph), a network in which each unbranched path becomes a contig. Sequencing errors and repeats make the paths branch, and SPAdes prunes the weakly supported branches. It repeats this at several k values and merges the answers, and you never choose k yourself. On the fixture it used 21, 33, 55, 77, 99, and 127.

Lungfish Genome Explorer (LGE) runs SPAdes from an assembly sheet under **Tools > Assembly > SPAdes...**. The same sheet runs MEGAHIT and SKESA, the other two short-read assemblers, so this chapter covers all three. They differ in presets and a few starting values, not in how you drive them. This chapter also explains how to read any assembly result, whichever of the five assemblers produced it.

## Why you would do this

You assemble when you want the sequence itself rather than a list of differences from something already known. The clearest case is a genome with no good reference, such as a new bacterial isolate or a plasmid, a small circular DNA molecule that lives beside a bacterium's main chromosome. A second case is a genome you suspect has been rearranged, since a large insertion shows up plainly as an unexpected contig. A third is confirmation. If you believe a sample holds one organism and one contig comes back at the expected length, you have independent evidence.

This chapter assembles reads from the [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome) of HG002, a widely studied human sample. Mitochondria carry a small circular chromosome of their own, 16,569 bases long in humans. That is small enough to assemble in seconds and large enough to be a real genome. The fixture is a [paired-end](../../GLOSSARY.md#paired-end) Illumina library, meaning each DNA fragment was read from both ends, holding 9,958 read pairs. The right answer is published, so you can see what each assembler gets right.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM` bundle this section imports, so only the plugin pack remains. To import the pair yourself instead, follow the rest of this section.

This chapter uses the human-mito fixture. Download `HG002.chrM_R1.fastq.gz` and `HG002.chrM_R2.fastq.gz` from [the human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Import both files together as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows. LGE pairs them into one bundle named `HG002.chrM`.

Install the `assembly` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries SPAdes 4.3.0, MEGAHIT 1.2.9, and SKESA 2.5.1, the versions that produced the numbers below. The SPAdes run on the fixture takes well under a minute on a recent Mac.

## Procedure

Every number below came from real runs on the fixture reads. Yours should match to within a few bases. A different contig count is not ordinary, and [What good looks like](#what-good-looks-like) says what to make of one.

### 1. Open the sheet

1. Click the `HG002.chrM` bundle in the sidebar to select it. The sheet takes whatever is selected and has no file picker of its own.

2. Choose **Tools > Assembly > SPAdes...**. The assembly sheet opens with SPAdes chosen in the Assembler picker. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Inputs** section at the top. Its three read-only rows show the dataset, its read layout, and the detected read class. To assemble a different bundle, close the sheet, select that bundle, and reopen it.

    <!-- SHOT: assembly-wizard-spades -->

4. Check the **Read Type** row. For the fixture it is a fixed label reading Illumina short reads, with "Locked from FASTQ header detection." beneath it.

5. Leave **Profile** on **Isolate**, the preset for a sample believed to hold one organism, and change nothing else for a first run.

Look at the **Readiness** line at the bottom before you click anything. Run stays disabled until the pack is installed and its quick launch test has passed, which takes a few seconds. When Run is disabled for another reason, a short line says which, such as "Select at least one FASTQ input." or "Project name is required."

### 2. Run it

6. Click **Run**. The sheet closes. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The tool's output streams into the row, and the full text is also saved as `assembly.log` in the run folder.

7. When the row finishes, LGE opens the result in the assembly viewport. Later, click the result under `Analyses` in the sidebar to open it again. A summary strip above the contig table reads SPAdes, Illumina Short Reads, 1 contig, 16697 total bp, an N50 of 16697, and 44.4% global GC.

<!-- SHOT: assembly-viewport -->

## Settings

The sheet shows these controls with a short-read assembler selected. Entries say when a control belongs to one assembler only. Every slider has a number field beside it, so you can drag or type.

**Assembler.** Picks which assembler runs, as a row of buttons of which one is selected. It arrives set to the tool you chose from the menu, and it lists only the assemblers that accept the detected read class, so an Illumina bundle offers SPAdes, MEGAHIT, and SKESA. Switch it to compare two assemblers on the same reads without closing the sheet. On the command line this is `--assembler`.

**Read Type.** States which sequencing chemistry produced the reads, which decides the assembler list. It arrives locked to the class LGE read from the FASTQ headers, one of Illumina short reads, ONT reads (Oxford Nanopore), or PacBio HiFi/CCS. It becomes a picker only when the headers give no clear answer. Then it starts on a best guess and the Assembler picker lists all five tools, so set the class yourself before you run. On the command line this is `--read-type`.

The sheet takes one read class per run. Bundles from more than one class stop the run with "Hybrid assembly is not supported in v1. Select one read class per run." Hybrid assembly combines short and long reads, and "v1" is the app's name for this first version of the assembly feature, not a release number. Mixing bundles the sheet could classify with bundles it could not gives "Selected FASTQ inputs mix detected and unclassified read classes. Select one read class per run."

**Profile.** Chooses the SPAdes mode, offering Isolate, Meta, and Plasmid. The default is Isolate, which assumes one organism at reasonably even coverage. Pick Meta for a metagenome, a mixture of organisms sequenced together, and Plasmid when the plasmids rather than the chromosome are what you want. On the command line this is `--profile`.

**Profile (MEGAHIT).** Chooses a MEGAHIT preset, offering Default, Meta Sensitive, and Meta Large. The default is Default, the balanced setting. Pick Meta Sensitive to recover rarer organisms in a mixture at the cost of time, and Meta Large for a large, complex community such as soil. On the command line this is `--profile`. SKESA has no presets, so the row is hidden for it.

**Threads.** Sets how many processor cores the assembler uses at once. The default is the smaller of your Mac's core count and 8, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`. For MEGAHIT on Apple Silicon, LGE lowers any value above 2 to 2 and turns off the tool's hardware acceleration, to reduce crashes.

**Memory Limit.** Caps how much memory the assembler may claim, in whole gigabytes from 1 to your Mac's installed memory. The default is three quarters of installed memory, up to 32 GB, which leaves room for the rest of the system. Raise it for a large or deep library that stops partway, and lower it when you need memory for other applications. On the command line this is `--memory-gb`. It is a ceiling rather than a reservation, and SPAdes stops with a clear error when it reaches it.

**Min Contig.** Drops contigs shorter than this from the result, set with a stepper from 0 to 1,000,000 bases in steps of 100. The default is 0, which keeps everything so you can see what the assembler produced. Raise it on a metagenome to keep thousands of unplaceable fragments out of the contig table. On the command line this is `--min-contig-length`. MEGAHIT and SKESA receive it, but with SPAdes selected the value never reaches the run, so screen short SPAdes contigs by sorting the table's Length (bp) column instead. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

**Careful mode.** Turns on SPAdes' `--careful` pass, which corrects single-base mismatches and short insertions or deletions after assembly. It sits under **Advanced Settings > Curated extra arguments**, for SPAdes only, and is off by default because it adds noticeable run time and most runs do not need it. SPAdes' own documentation says careful mode cannot be combined with its isolate or meta modes, so it is of no use with the Isolate profile this chapter runs. Turn it on only with the Plasmid profile, when per-base accuracy matters. This setting has no command-line flag, so pass `--extra-args "--careful"` instead.

**Skip error correction.** Passes SPAdes' `--only-assembler` flag, which skips the read [error-correction](../../GLOSSARY.md#error-correction) stage. It sits beside Careful mode, for SPAdes only, and is off by default, because correcting errors first keeps false branches out of the graph. Turn it on when an earlier step already corrected the reads, or when the correction stage runs out of memory. This setting has no command-line flag, so pass `--extra-args "--only-assembler"` instead.

<!-- SHOT: assembly-advanced-settings -->

**Extra arguments.** Passes text straight to the assembler without LGE checking it. The default is empty, which is right for almost every run. Use it only for an assembler option the dialog does not show, after reading that assembler's own documentation. On the command line this is `--extra-args`. Quotation marks must come in pairs, and an unclosed one blocks Run with the reason shown at the foot of the sheet. For SKESA, LGE always adds `--min_count 2`, which keeps SKESA from discarding every real k-mer on a small library, and typing your own `--min_count` here replaces it.

**Project Name.** Names the assembly the run produces. It arrives filled from the first input's name with the mate suffix removed and `_assembly` added, so the fixture gives `HG002.chrM_assembly`. Rename it when you assemble the same reads more than once, and note that an empty name blocks Run. On the command line this is `--project-name`.

**Output Folder.** Shows, read only, where the run will land, which is the project's `Analyses` folder. It is there so you can confirm the path, and there is nothing to change in the window. On the command line, `--output` sets it.

**Run Mode.** Appears only when you select several bundles, and says how they are handled. The only choice is **Run separately per bundle**, and **Combine all inputs, run once** is locked because pooling is not supported yet. There is nothing to change. This setting has no command-line flag, so run `assemble` once per sample instead.

## Reading the results

This section applies to a result from any of the five assemblers.

### Where the result sits

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes, named for the tool and the moment the run started, for example `spades-2026-09-07T14-23-10`. The sidebar shows it as one row. Every run gets its own folder, so several assemblies of the same reads sit side by side.

<!-- SHOT: assembly-bundle-in-analyses -->

To run again with a different setting, select the reads and open the same item under **Tools > Assembly**. Right-click the result row and choose **Show in Finder** to reveal the run folder, which also holds `assembly.log`, the assembler's raw output, a scaffold file for the tools that write one, and `assembly-result.json` with the tool version, the exact command, the wall time, and the statistics. Scaffolds are contigs the assembler has ordered using paired reads, with runs of `N` standing in for unknown gaps. LGE shows the contigs, not the scaffolds.

### The Assembly Context block

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Its **Bundle** tab carries an **Assembly Context** block, a two-column list of labels and values. It starts with Assembler, Read Type, and Version, then the recorded run details such as run date, host, and exit status, then Wall Time, Contigs, Total Assembled bp, N50, L50, Longest Contig, Global GC, the command, and the output folder. Wall time is the real elapsed time the run took. For the fixture's SPAdes run it reports SPAdes 4.3.0, 1 contig, 16697 total bp, an N50 of 16697, an L50 of 1, and 44.4% global GC.

[N50](../../GLOSSARY.md#n50) is the contig length at which contigs that long or longer hold half of all assembled bases, worked through in [When to Assemble](01-when-to-assemble.md#what-the-numbers-mean). A single-contig assembly always has an N50 equal to its one contig and an L50 of 1. [GC content](../../GLOSSARY.md#gc-content) is the share of bases that are G or C.

### The contig table and the detail pane

The viewport's table lists one contig per row, with the columns `#`, `Contig`, `Length (bp)`, `GC %`, `Share of Assembly (%)`, and `Sequence Preview`. The `#` column ranks by length, so row 1 is always the longest, whatever order the assembler wrote its file in. Share is the contig's fraction of all assembled bases. The preview shows the first 80 bases. A filter field above the table narrows rows by name or by the contig's full FASTA name line. There is no coverage column, though most assemblers write their own coverage estimate into each contig's name.

Click a row to open the detail pane beside the table, showing the contig's header, length, GC percent, rank, share, and full sequence. The fixture's contig is named `NODE_1_length_16697_cov_121.957333`, where `cov_121.957333` is SPAdes' estimate of about 122-fold coverage. Compare such figures only within one tool, since each assembler counts coverage its own way.

<!-- SHOT: contig-detail-pane -->

The action bar under the table offers **BLAST Contigs**, **Copy FASTA**, **Export FASTA**, and **Create Bundle**, all disabled until you select a contig, with a count of how many are selected. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and the button sends the selected contigs to NCBI over the internet. It reads **BLAST Contig** when exactly one is selected. **Create Bundle** turns the selected contigs into a reference bundle, which [Extracting Contigs](04-extracting-contigs.md) covers. Making a bundle is how you open a contig in a sequence viewport, since opening a row does nothing more than show its detail pane. Right-clicking a row offers the same actions, with **Extract to New Bundle...** in place of Create Bundle, plus **Extract Sequence...** and **Run Operation...**.

### An empty result

An assembler can finish cleanly and produce nothing. LGE records that as its own outcome, and the viewport reads "Assembly completed, but no contigs were generated." in place of the table. That is the expected result from too few reads or coverage too thin to find overlaps, and the fix is more sequencing.

### What the three assemblers gave on the same reads

| Assembler | Version | Contigs | Total bp | Longest | N50 | Global GC |
|---|---|---|---|---|---|---|
| SPAdes | 4.3.0 | 1 | 16697 | 16697 | 16697 | 44.4% |
| MEGAHIT | 1.2.9 | 3 | 17405 | 16711 | 16711 | 44.6% |
| SKESA | 2.5.1 | 1 | 16570 | 16570 | 16570 | 44.4% |

All three recovered the 16,569-base mitochondrial genome. SKESA landed one base over and named its contig `Contig_1_257.173_Circ [topology=circular]`, marking that it recognised the circle. SPAdes and MEGAHIT each ran a little over a hundred bases long, the overlap an assembler can write twice where it cuts a circle open, as [Running Flye or hifiasm](03-running-flye-or-hifiasm.md#reading-the-results) explains. MEGAHIT also wrote two short contigs of 332 and 362 bases, fragments it could not place. The assemblers disagreed about the exact ends and agreed about the content, which is why the contig count matters more than the last hundred bases.

MEGAHIT runs on Apple Silicon often stop partway with no contigs, and a run that does finish, like the one in the table, is correct. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## What good looks like

Check three things before you trust an assembly, in this order.

First, the contig count and the longest contig together. For a small single-molecule target like the mitochondrion, one contig near the expected length is right, and a small overshoot on a circular genome is the closing overlap. MEGAHIT's three contigs still count as a good result, since one holds the whole genome. Many short contigs with none near the expected length is the sign of thin or uneven coverage.

Second, the GC percent. It is nearly constant within a genome and differs between genomes, so it is a cheap identity check. The human mitochondrion sits near 44 percent, and all three runs gave 44.4 to 44.6. A few tenths is nothing, while several percentage points away from what you expected usually means a contaminant or host fragment.

Third, the total length against the expected genome size. Far above suggests duplicated or contaminating pieces. Far below means part of the genome had no reads.

When a run disappoints, work out the coverage before blaming the assembler. Multiply the read count by the read length and divide by the genome size. The same 9,958 pairs that cover this 16.6 kb genome hundreds of times over would cover a 5 Mb bacterial chromosome about once, which is hopeless, and the only fix is more sequencing. When a run produces nothing at all, read its row in the Operations Panel, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it. The usual causes are a truncated FASTQ or mate files with different read counts.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli assemble HG002.chrM_R1.fastq.gz HG002.chrM_R2.fastq.gz \
  --paired \
  --assembler spades \
  --profile isolate \
  --project-name HG002.chrM_assembly \
  --output ./out-spades
```

Swap in `--assembler megahit` or `--assembler skesa` for the other two runs. `--paired` binds the two files as mates of one library, which the window works out from the file names. For MEGAHIT's Default preset, leave `--profile` out, since the command passes any profile it is given straight to MEGAHIT and `default` is not a MEGAHIT preset.

## Next

Continue to [Running Flye or hifiasm](03-running-flye-or-hifiasm.md) for long reads. If your reads are Illumina, go on to [Extracting Contigs](04-extracting-contigs.md), which turns contigs into a reference bundle for mapping and variant calling.
