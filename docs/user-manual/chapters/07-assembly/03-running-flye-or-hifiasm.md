---
title: Long-Read Assembly (Flye, hifiasm)
chapter_id: 07-assembly/03-running-flye-or-hifiasm
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble, 07-assembly/02-running-spades]
estimated_reading_min: 18
task: Assemble Oxford Nanopore reads with Flye or PacBio HiFi reads with hifiasm, and read the resulting contig table.
tags: [assembly, flye, hifiasm, nanopore, pacbio, long-read]
tools: [flye, hifiasm]
parameters_refs: [assemble.flye, assemble.hifiasm]
entry_points:
  - "Tools > Assembly > Flye…"
  - "Tools > Assembly > Hifiasm…"
  - "CLI: lungfish-cli assemble"
shots:
  - id: assembly-sheet-flye
    caption: "The assembly sheet opened from Tools > Assembly > Flye…, with the ONT bundle selected in the sidebar beforehand, showing the Inputs section reporting ONT reads under Detected, the Assembler picker listing all five assemblers with Flye chosen, the locked Read Type row, and the Profile picker on Nano Raw with the caption beneath it reporting that Nano Raw was preselected from a read quality of Q8 in the bundle's statistics."
  - id: assembly-sheet-hifiasm
    caption: "The same sheet opened from Tools > Assembly > Hifiasm… with the HiFi bundle selected, where the Assembler picker has Hifiasm chosen and the Profile picker sits on Diploid."
  - id: assembly-sheet-curated-arguments
    caption: "The Advanced settings section with the Curated extra arguments disclosure open for Flye, showing the Metagenome mode toggle above the Extra arguments field and its caption naming Flye."
  - id: flye-contig-table
    caption: "The result of a window run with the preselected Nano Raw profile, with one contig of 32,690 bp in the table and the Inspector showing the HG002.chrM.ont.fastq.gz source, Flye 2.9.6, the Profile nano-raw, and the Profile Basis line recording the Q8 read-quality preselection."
illustrations: []
glossary_refs: [accession, assembly-bundle, assembly-graph, basecaller, bundle, circular-consensus-sequencing, contig, coverage, de-novo-assembly, fastq, gc-content, gfa, haplotype, l50, n50, nanopore-sequencing, operations-panel, phred-score, ploidy, plugin-pack, polishing, read, read-length, reference-bundle, unitig, hg002]
features_refs: [assemble, viewport.assembly]
fixtures_refs: [hg002-long-reads]
brand_reviewed: false
lead_approved: false
---

## What it is

Flye and hifiasm are the two long-read assemblers in Lungfish Genome Explorer (LGE). A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads, and [When to Assemble](01-when-to-assemble.md) explains assembly and how to choose an assembler. Long-read assemblers work with reads whose [read length](../../GLOSSARY.md#read-length) runs to tens of thousands of bases, against the few hundred bases of an Illumina read.

Length is the whole point. Every assembler builds an [assembly graph](../../GLOSSARY.md#assembly-graph) and follows each stretch until it reaches a fork, a place where two ways forward are equally well supported. A repeat, a sequence that occurs more than once in the genome, creates such a fork because a short read cannot say which copy it came from. A read long enough to span the repeat resolves the fork, which is why long reads usually give a handful of long contigs where short reads give hundreds of short ones.

The two tools suit different reads. Flye was built for long reads that are individually noisy, such as [Oxford Nanopore](../../GLOSSARY.md#nanopore-sequencing) reads and older PacBio CLR reads, the noisier long reads PacBio made before HiFi, and it has a mode for PacBio HiFi reads as well. It first builds draft contigs, early and rough versions that tolerate mismatches between reads, then builds a repeat graph from them, and finally runs [polishing](../../GLOSSARY.md#polishing), which lines the reads up against the contigs again and corrects each base where the reads favor a different one. Hifiasm is built for PacBio HiFi reads, made by [circular consensus sequencing](../../GLOSSARY.md#circular-consensus-sequencing), which reads each molecule many times so that almost every base is correct. Because the reads are so accurate, hifiasm can keep the two parental copies of each chromosome apart. Those copies are what [ploidy](../../GLOSSARY.md#ploidy) counts, and humans carry two. A bacterium carries one, so it is haploid, and for an organism whose ploidy you do not know, ask whoever supplied the sample. Recent hifiasm versions, including the 0.25.0 LGE installs, also accept Nanopore reads, and LGE passes hifiasm its `--ont` option whenever the **Read Type** row says ONT reads.

The reads decide which assembler suits them. Nanopore reads suit Flye or hifiasm, HiFi reads suit hifiasm or Flye in its PacBio HiFi mode, and Illumina reads suit neither. LGE starts Flye in the mode that matches the reads, PacBio HiFi or PacBio CLR for PacBio reads and a nanopore mode chosen by read quality for Nanopore reads, as [Settings](#settings) explains. The sheet lists every assembler, and one that does not suit the reads shows a warning and runs with its own read-type settings. Apply the same checks to such a run as to any other.

## Why you would do this

Assemble long reads when you want a genome's structure rather than its individual bases. A short-read assembly can tell you which genes are present, but usually not their order, how many copies of a repeated element there are, or where a plasmid ends and the chromosome begins. A plasmid is a small circular DNA molecule that many bacteria carry beside their chromosome.

This chapter assembles the HG002 long reads. [HG002](../../GLOSSARY.md#hg002) is a benchmark human sample sequenced many times by many methods, so there is a published answer to check against. The fixture keeps only reads from the mitochondrion, whose genome is NCBI [accession](../../GLOSSARY.md#accession) `NC_012920.1`, 16,569 bases and circular. It holds 950 Nanopore reads totaling 4,348,051 bases and 363 HiFi reads totaling 4,991,345 bases. Dividing each total by 16,569 gives about 262-fold and 301-fold [coverage](../../GLOSSARY.md#coverage), far more than the documentation of either assembler asks for. [Flye's usage notes](https://github.com/mikolmogorov/Flye/blob/flye/docs/USAGE.md) say 40-fold of the longest reads typically gives good draft contigs, and [the hifiasm FAQ](https://hifiasm.readthedocs.io/en/latest/faq.html) says usually at least 13-fold of HiFi reads per haplotype. Neither is a hard minimum, and [When to Assemble](01-when-to-assemble.md#what-good-looks-like) shows how to estimate yours.

On Nanopore reads, choose Flye for older or noisier reads, for a haploid genome such as a bacterium or a virus, and, with Metagenome mode, for a community. Choose hifiasm for HiFi reads, and for reads from a recent Nanopore flow cell, the consumable chip the reads come from, when the two parental copies of a region must stay apart. [Hifiasm's README](https://github.com/chhylp123/hifiasm/blob/master/README.md) names simplex R10 reads, single-pass reads from the R10 flow cell, as the Nanopore kind it supports. Your provider's run report names your flow cell, and the reads' **Mean Q (error rate)** card gives their quality, as [Quality Control](../03-reads/03-quality-control.md#mean-q-error-rate) explains. [Choosing a tool](01-when-to-assemble.md#choosing-a-tool) compares all five assemblers in LGE.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM.ont` and `HG002.chrM.hifi` bundles this section imports, each with its platform set.

This chapter uses the hg002-long-reads fixture. Download `HG002.chrM.ont.fastq.gz` and `HG002.chrM.hifi.fastq.gz` from [the hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Import each file as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows. Each becomes its own [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, so look for two sidebar rows, `HG002.chrM.ont` and `HG002.chrM.hifi`. Nanopore reads of your own that arrive as a sequencing run folder, one subfolder per barcode, are imported as [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) shows. HiFi reads need no such step.

Both assemblers take one input, so several FASTQ files from one sample must become one bundle first. Import each file, Cmd-click the bundles in the sidebar, right-click one, choose **Merge Into New Bundle…**, name it, and click **Merge**. Then check the merged bundle's **Detected** row.

Install the `assembly` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries Flye 2.9.6 and hifiasm 0.25.0, the versions that produced this chapter's numbers. On the fixture, the Flye run on record took 85 seconds and the hifiasm runs took 6 to 27 seconds, so allow a couple of minutes for each. A bacterial genome is far larger, so expect a far longer run. [Flye's benchmark table](https://github.com/mikolmogorov/Flye/blob/flye/docs/USAGE.md) lists about 2 hours of processor time and 2 Gb of memory for the 4.6-megabase E. coli genome at 50-fold on PacBio reads, a figure from Flye's test machines, not LGE on your Mac. Hifiasm's README gives no run time for a small genome and says its start-up filter takes 16 GB of memory unless `-f0` switches it off, as Haploid/Viral does.

## Procedure

### Assemble the Nanopore reads with Flye

1. Click the `HG002.chrM.ont` bundle in the sidebar to select it.

2. Choose **Tools > Assembly > Flye…**. The assembly sheet opens with Flye chosen.
3. Read the **Inputs** section at the top of the sheet. The **Detected** row should read ONT reads, meaning Oxford Nanopore Technologies, and the Read Layout row reads Single-input long-read assembly, since long reads are never paired. LGE uses the read class recorded with the bundle when there is one, then reads the class from the headers of the first reads in the [FASTQ](../../GLOSSARY.md#fastq) file, then falls back to the instrument recorded at import. Below it, **Primary settings** holds the **Assembler** picker, which lists all five assemblers with Flye chosen, and the **Read Type** row, which is locked with "Locked from FASTQ header detection." beneath it.

4. The **Profile** picker opens on **Nano Raw**, and a caption beneath it says why, reporting that Nano Raw was preselected from a read quality of Q8 in the bundle's statistics. Q is the [Phred score](../../GLOSSARY.md#phred-score), a per-base error scale on which Q10 means 1 wrong base in 10, Q20 means 1 in 100, and Q30 means 1 in 1,000, so Q8 is roughly 1 in 6. The reads' **Mean Q (error rate)** card shows this quality, as [Quality Control](../03-reads/03-quality-control.md#mean-q-error-rate) explains. LGE preselects Nano Raw below Q10 and Nano HQ at Q10 or above. Nano HQ suits reads from a recent high-accuracy [basecaller](../../GLOSSARY.md#basecaller), the program that turns the sequencer's electrical signal into bases. The fixture's reads are older and noisier, at Q8, so Nano Raw is the profile built for them. Leave everything as it is.

    <!-- SHOT: assembly-sheet-flye -->

5. Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A stage that stays on screen a while is usually working, not stuck.

### Assemble the HiFi reads with hifiasm

1. Click the `HG002.chrM.hifi` bundle in the sidebar. Opening a result changes the selection, so click the reads again before opening the menu.

2. Choose **Tools > Assembly > Hifiasm…**. The **Detected** row reads PacBio HiFi/CCS, and the **Assembler** picker has Hifiasm chosen.

3. Leave **Profile** on **Diploid**, its default. A mitochondrion has one copy, so **Haploid/Viral** sounds like the better fit, but on these reads it gives the messier answer, as [Diploid or Haploid/Viral on a small circle](#diploid-or-haploidviral-on-a-small-circle) shows. For a haploid bacterium the advice differs, and the same section gives the rule.

    <!-- SHOT: assembly-sheet-hifiasm -->

4. Click **Run**.

Hifiasm writes a [GFA](../../GLOSSARY.md#gfa) file, a text format for assembly graphs, and LGE converts its primary contigs, the main answer, into a `contigs.fasta` for the viewport. Hifiasm can exit cleanly without assembling anything, so a run that writes no primary contig graph ends as a failed row whose message says hifiasm "exited successfully but wrote no primary contig graph".

### Open the results

Each run lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE opens each result when its run finishes. Later, click the result's row under `Analyses` in the sidebar to open it again.

<!-- SHOT: flye-contig-table -->

## Settings

Both assemblers share one sheet, so an entry names its assembler only where the two differ. Memory Limit and Min Contig do not appear for either tool, because neither accepts them.

**Assembler.** Picks which assembler runs. It lists all five assemblers and defaults to the tool you chose from the menu. An assembler that does not suit the detected read class shows a warning and still runs. Switch it to try the other long-read assembler on the same reads. On the command line this is `--assembler`, whose default follows the read type.

**Read Type.** States which sequencing chemistry produced the reads, which sets the assembler's defaults, and makes LGE pass `--ont` to hifiasm when the reads are ONT reads. It defaults to the class read from the FASTQ headers and is locked when detection succeeds. It unlocks into a picker of Illumina short reads, ONT reads, and PacBio HiFi/CCS only when detection is inconclusive, as with older PacBio CLR data, a noisier mode with no class of its own here. On the command line this is `--read-type`.

**Profile.** Tells the assembler what input to expect. Flye offers **Nano HQ** for recent high-accuracy basecalls, **Nano Raw** for older or fast-mode basecalls, **Nano Corrected** for reads another tool already corrected, **PacBio HiFi** for HiFi reads, and **PacBio CLR** for older PacBio subreads. LGE preselects PacBio HiFi for HiFi reads and PacBio CLR for PacBio subreads. For Nanopore reads it preselects Nano Raw when the reads' mean quality in the bundle's statistics is below Q10, or the median read quality of the first 500 reads when the bundle has no statistics, and Nano HQ otherwise. Hifiasm offers **Diploid** (the default), which keeps the two parental copies apart and purges duplicated copies of one stretch, and **Haploid/Viral**, which expects a single [haplotype](../../GLOSSARY.md#haplotype), one copy of each chromosome. It passes hifiasm `--n-hap 1`, and it skips duplicate purging (`-l0`) and a memory-saving filter (`-f0`) that a small genome does not need. Override the preselection only when you know the basecaller better than the quality scores do. For hifiasm on a small haploid genome such as a bacterium, choose Haploid/Viral first, since it is the profile written for one haplotype and hifiasm's FAQ points inbred or homozygous genomes to `-l0`. Keep Diploid for a genome with two or more copies or an unknown ploidy. The mitochondrion in this chapter differs because on its reads Haploid/Viral kept a leftover partial copy that Diploid removed. That is one measured case, so check any shallower contig a Haploid/Viral run keeps against the main one, and rerun on Diploid if it repeats it. On the command line this is `--profile`, and leaving it off applies the same read-quality rule.

**Threads.** Sets how many processor cores the assembler uses at once. The default is the smaller of your Mac's core count and 8, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Metagenome mode.** Turns on Flye's metagenome setting, for a mixed community of organisms at very different abundances rather than one organism at even depth. It is off by default, belongs to Flye alone, and sits under **Advanced settings > Curated extra arguments**. Turn it on for a community sample such as stool or seawater, and leave it off for a single isolate. This setting has no command-line flag, so pass `--extra-args "--meta"` instead.

**Primary contigs only.** Passes hifiasm's `--primary` option, which, despite the control's name, makes hifiasm write a primary and an alternate assembly instead of one set per parental copy. The alternate assembly is the contigs hifiasm set aside from the primary one, as [its output notes](https://hifiasm.readthedocs.io/en/latest/interpreting-output.html) describe. It belongs to hifiasm alone, sits in the same disclosure, and is off by default, because the primary contigs LGE shows come out either way, as `<project name>.p_ctg.gfa` when it is on. Turn it on only to keep those alternate contigs on disk. This setting has no command-line flag, so pass `--extra-args "--primary"` instead.

**Extra arguments.** Passes text straight to the assembler without LGE checking it. The default is empty, which is right for almost every run. Use it only for an assembler option the dialog does not show, after reading that assembler's own documentation. A genome-size hint is not needed. Flye's usage notes call `--genome-size` optional since version 2.8 and say to pair it with `--asm-coverage`, and a 5-megabase bacterium needs neither. On the command line this is `--extra-args`. Where your text and the Haploid/Viral profile set the same option, your value wins.

**Project Name.** Names the assembly the run produces. It defaults to the input file's name with `_assembly` added, for example `HG002.chrM.ont_assembly`. Rename it when you assemble the same reads more than once. For hifiasm it also becomes the prefix of every file hifiasm writes. On the command line this is `--project-name`.

<!-- SHOT: assembly-sheet-curated-arguments -->

## Reading the results

The contig table, the detail pane, and the Assembly Context block are read as [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md#reading-the-results) explains. Of the table's columns, **Contig**, **Length (bp)**, and **GC %** matter most here, and the **Assembly Context** block in the Inspector gives the contig count, total length, N50, and L50. [N50](../../GLOSSARY.md#n50) is the contig length at which contigs that long or longer hold half of all assembled bases, and [L50](../../GLOSSARY.md#l50) is how many contigs, longest first, it takes to reach that half, both worked through in [When to Assemble](01-when-to-assemble.md#what-the-numbers-mean). An N50 near the chromosome's length with an L50 of 1 is what one chromosome plus small plasmids gives, and a low N50 with a high L50 means many short pieces. What follows is particular to long-read results.

### The files the viewport does not list

The contig table has no column for coverage, for whether a contig is circular, or for how often the assembler thinks a sequence repeats. Flye records all three in `assembly_info.txt` in the run folder. To open it, right-click the result's row in the sidebar, choose **Show in Finder**, and double-click the file, or open it in a spreadsheet program, since it is tab-separated. It has one row per contig, and [Flye's usage notes](https://github.com/mikolmogorov/Flye/blob/flye/docs/USAGE.md) list its columns in this order. They are the contig id, length, coverage, circular (Y or N), repetitive (Y or N), multiplicity (an estimate from coverage of how often the sequence occurs), alternative group, and graph path. Flye also keeps its graph there as `assembly_graph.gfa`. Hifiasm writes its primary graph as `<project name>.bp.p_ctg.gfa`, plus one graph per parental copy and [unitig](../../GLOSSARY.md#unitig) graphs, whose unitigs are unambiguous stretches from before any joins. Only the primary contigs reach the viewport.

### What the fixture gives

Run as the procedure describes, each assembler returns one contig about twice the length of the 16,569-base genome.

| Assembler and profile | Contigs | Length | GC | What it means |
|---|---|---|---|---|
| Flye, Nano Raw, imported bundle | 1, circular | 32,690 bp | 42.9% | The circle walked twice |
| Hifiasm, Diploid | 1, circular | 33,140 bp | 44.4% | The circle walked twice |

Both are the third outcome in [Circular genomes, trimmed, overlapped, or walked twice](01-when-to-assemble.md#circular-genomes-trimmed-overlapped-or-walked-twice). Hifiasm's contig is exactly two copies, since 33,140 divided by 16,569 is 2.0001. Flye's is a little under, 1.97 times, because Flye polished the two passes separately. Flye's `assembly_info.txt` marks its contig `circ. Y` with a mean coverage of 125, about half the reads' 262-fold, because every read now has two places to sit. Hifiasm names its contig `ptg000001c`, where the closing `c` marks it circular. Hifiasm's own manual does not describe that letter, so confirm it against the contig's length.

Flye's contig is 42.9% GC where the reference and the hifiasm contig are 44.4%. Here it is probably not contamination, since every read comes from one mitochondrion. The likely cause is that Nanopore reads at about Q8 carry systematic errors, the miscounted runs of one repeated base above all, which polishing cannot fully fix. That is an interpretation, not a measured cause.

Nothing in the viewport flags a doubled contig. Its N50 equals its own length and its L50 is 1, which look perfect. The check is knowing roughly how big the genome should be. Neither this fixture, which holds only the mitochondrion, nor the Flye or hifiasm manuals says whether a megabase bacterial circle also comes back doubled, so check every circular contig of your own against the expected size.

### What else Flye has given on these reads

On small, noisy data the profile, the read order, or the thread count can change Flye's graph. Importing reads into a project reorders them for storage, so a run on the imported bundle and a run on the raw file need not agree. Flye has given four different answers on these reads.

| Input | Profile | Contigs | Total length | What it means |
|---|---|---|---|---|
| Imported bundle, 8 threads | Nano Raw | 1, circular | 32,690 bp | The circle walked twice, the procedure's result |
| Raw file | Nano HQ | 1, circular | 32,652 bp | The circle walked twice |
| Raw file | Nano HQ | 1, circular | 16,359 bp | The whole genome, with the join trimmed |
| Imported bundle | Nano HQ | 4, none circular | 22,137 bp | The circle broken into overlapping pieces |

The procedure as written, with the preselected Nano Raw on the imported bundle, gave the first row on both runs made for this manual. Four pieces that add up to more than the 16,569-base genome, as in the last row, are one circle cut into overlapping fragments, not four molecules.

### Diploid or Haploid/Viral on a small circle

The mitochondrion has one copy, so hifiasm's Haploid/Viral profile sounds right for it. Run on the same HiFi reads it returned two contigs, 60,111 bases in all. One is the same doubled circle of 33,140 bases, at a read depth of 170 in hifiasm's graph. The other is a linear contig of 26,971 bases at a depth of 16, and it lines up along its whole length, 99.9 percent identical, with part of the first. It is a partial duplicate copy of the same sequence, built from a minority of the reads. Diploid's duplicate purging removes exactly this kind of redundant copy, and Haploid/Viral turns the purging off. The procedure therefore keeps Diploid, and the lesson is to read a second, low-depth contig that repeats the first as a leftover copy, not a second molecule. The depth figures come from the graph file, which the viewport does not show. On your own data, judge a shallow extra contig by its length and depth first. A real plasmid can also sit at a different depth from the chromosome, so select the contig and click **BLAST Contig**, which sends it to NCBI, to see what it is.

For a small haploid genome such as a bacterium, the rule in the **Profile** setting applies. Choose Haploid/Viral first and check every shallower contig as this one was checked.

### From a doubled contig to a reference

A doubled contig holds the genome twice, so reads mapped to it split between two identical copies, which halves the depth and doubles every position. Cut one copy out before you map to it. Hifiasm's contig is exactly two copies, so one copy is its first half, positions 1 to 16,570, half of 33,140. The halves differ at one position in 16,570, so either half will do. HG002's own mitochondrion is one base longer than the 16,569-base reference, which is why the half is 16,570 rather than 16,569.

1. Turn the contig into a reference bundle as [Extracting Contigs](04-extracting-contigs.md) shows. Select its one row, `ptg000001c`, and click **Create Bundle**. The bundle lands under `Reference Sequences/`.
2. Open the new bundle, choose **Sequence > Go to Location…** (Cmd-L), type `ptg000001c:1-16570`, and click **Go**, as [Go to a position](../02-sequences/01-importing-and-viewing.md#go-to-a-position) shows.
3. Mark that range as a feature with **Sequence > Add Annotation…**, then right-click the feature, choose **Extract Sequence…**, and save it as a new bundle, as [Extract one annotated feature](../02-sequences/03-extracting-and-comparing.md#extract-one-annotated-feature) shows. The feature route cuts exactly the range you marked, where **Extract Visible Region…** cuts whatever the viewport frames.

The new bundle lands under `Extractions/` and holds one sequence of 16,570 bases, which aligns to the whole of `NC_012920.1`. It starts at a different place from the published reference and reads on the opposite strand, because the assembler chose its own cut point and direction. Map reads to it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, and expect positions that do not match the published numbering. For that numbering, map to `NC_012920.1` itself.

Flye's doubled contig is not an exact double, so its halves are not a clean cut. For a single-copy mitochondrial reference from these reads, use the hifiasm contig, or the short-read contig from [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md), whose overshoot is only the closing overlap.

## What good looks like

Apply the four checks in [What good looks like](01-when-to-assemble.md#what-good-looks-like) of When to Assemble, above all the total length against the expected size. For a bacterium, look the size up in NCBI's genome records, as [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md#what-good-looks-like) says.

- **About 16,569 in one contig.** The genome came back whole. Carry it forward.
- **About 33,000 in one contig.** The circle was walked twice. Cut one copy out as [From a doubled contig to a reference](#from-a-doubled-contig-to-a-reference) shows.
- **One doubled contig plus a shorter, low-depth one.** The shorter one is a leftover partial copy. Rerun hifiasm on Diploid, or ignore the extra contig.
- **Several contigs adding up to more than 16,569, or a total well under it.** More means the circle broke into overlapping pieces, so check that **Profile** matches the reads, which for this fixture means the preselected Nano Raw, and run Flye again. Well under means part of the genome had too little coverage, and more reads are the fix.
- **For a bacterium, one large circular contig plus small circular ones.** The large one should sit near your species' size, and each small one is a possible plasmid. Twice the size reads as the doubled circle above, and several overlapping pieces as the broken circle.

The contig table does not show circularity. For hifiasm, read the name in the **Contig** column, where a closing `c` marks a circular contig. For Flye, open `assembly_info.txt` as [The files the viewport does not list](#the-files-the-viewport-does-not-list) describes, and read its circular column, which holds Y for a closed circle and N otherwise. A small circular contig is a possible plasmid, not a proven one, so select it and click **BLAST Contig** to ask NCBI what it matches.

For hifiasm the lasting fix for a doubled mitochondrion is to assemble it together with the nuclear reads it came from. This fixture holds no nuclear reads, so for hifiasm the length check is the whole test.

Remember that a contig is a hypothesis. When the answer matters, map the reads back to the contig as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, then read the [coverage curve](../04-alignments/02-reading-an-alignment.md#the-coverage-curve) to check that depth runs level along the contig, without a sharp drop or a halving.

## On the command line

This section is optional, because the window route above needs no terminal. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every flag of `assemble` and `extract contigs` is listed under [Assembly](../appendices/cli-reference.md#assembly) in the CLI Reference, and `extract sequence` under [Sequence utilities](../appendices/cli-reference.md#sequence-utilities).

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"

lungfish-cli assemble "$PROJECT/Imports/HG002.chrM.ont.lungfishfastq" \
  --assembler flye --read-type ont-reads \
  --project-name HG002.chrM.ont_assembly \
  --output "$PROJECT/Analyses/flye-cli"

lungfish-cli assemble "$PROJECT/Imports/HG002.chrM.hifi.lungfishfastq" \
  --assembler hifiasm --read-type pacbio-hifi \
  --profile diploid \
  --project-name HG002.chrM.hifi_assembly \
  --output "$PROJECT/Analyses/hifiasm-cli"

# One copy of the doubled hifiasm contig
lungfish-cli extract contigs --assembly "$PROJECT/Analyses/hifiasm-cli" \
  --contig ptg000001c --bundle --project-root "$PROJECT"
lungfish-cli extract sequence \
  "$PROJECT/Reference Sequences/hifiasm-cli-subset.lungfishref/genome/sequence.fa" \
  ptg000001c:1-16570 -o chrM-single-copy.fa
```

With `--profile` left off, as in the Flye command, the command applies the window's rule, choosing `nano-raw` for these reads and printing the choice with its basis in the Profile and Profile basis rows before Flye starts. A window run passes the same choice with `--profile` and `--profile-basis`, as **Copy CLI Command** on its row shows. The last command writes a plain FASTA file whose header reads `>ptg000001c:1-16570 [ptg000001c:1-16570, 1-based] [16570 bp]`. To merge several files from one sample first, use the window route in [Before you start](#before-you-start), or from a terminal run `cat a.fastq.gz b.fastq.gz > combined.fastq.gz` and import the combined file.

## Next

Continue to [Extracting Contigs](04-extracting-contigs.md) to turn a contig into a [reference bundle](../../GLOSSARY.md#reference-bundle) you can map reads to or call variants against. Carry forward only a result whose length matches the genome you expect, or one copy cut from a doubled contig.
