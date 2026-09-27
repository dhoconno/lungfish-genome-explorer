---
title: Long-Read Assembly (Flye, hifiasm)
chapter_id: 07-assembly/03-running-flye-or-hifiasm
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble, 07-assembly/02-running-spades]
estimated_reading_min: 15
task: Assemble Oxford Nanopore reads with Flye or PacBio HiFi reads with hifiasm, and read the resulting contig table.
tags: [assembly, flye, hifiasm, nanopore, pacbio, long-read]
tools: [flye, hifiasm]
parameters_refs: [assemble.flye, assemble.hifiasm]
entry_points:
  - "Tools > Assembly > Flye..."
  - "Tools > Assembly > Hifiasm..."
  - "CLI: lungfish-cli assemble"
shots:
  - id: assembly-sheet-flye
    caption: "The assembly sheet opened from Tools > Assembly > Flye..., with the ONT bundle selected in the sidebar beforehand, showing the Inputs section reporting ONT reads under Detected, the Assembler picker offering Flye beside Hifiasm and nothing else, the locked Read Type row, and the Profile picker on Nano Raw with the caption beneath it reporting that Nano Raw was preselected from a read quality of Q8 in the bundle's statistics."
  - id: assembly-sheet-hifiasm
    caption: "The same sheet opened from Tools > Assembly > Hifiasm... with the HiFi bundle selected, where the Assembler picker shows Hifiasm alone because it is the only assembler that accepts PacBio HiFi reads, and the Profile picker sits on Diploid."
  - id: assembly-sheet-curated-arguments
    caption: "The Advanced Settings section with the Curated extra arguments disclosure expanded for Flye, showing the Metagenome mode toggle above the four read-only option descriptions and the Extra arguments text field."
  - id: flye-contig-table
    caption: "The result of a window run with the preselected Nano Raw profile, with one contig of 32,690 bp in the table and the Inspector showing the HG002.chrM.ont.fastq.gz source, Flye 2.9.6, the Profile nano-raw, and the Profile Basis line recording the Q8 read-quality preselection."
illustrations: []
glossary_refs: [accession, assembly-bundle, assembly-graph, basecaller, bundle, circular-consensus-sequencing, contig, coverage, de-novo-assembly, fastq, gc-content, gfa, haplotype, l50, n50, nanopore-sequencing, operations-panel, ploidy, plugin-pack, read, read-length, reference-bundle, unitig, hg002]
features_refs: []
fixtures_refs: [hg002-long-reads]
brand_reviewed: false
lead_approved: false
---

## What it is

Flye and hifiasm are the two long-read assemblers in Lungfish Genome Explorer (LGE). A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads, and [When to Assemble](01-when-to-assemble.md) explains assembly and how to choose an assembler. Long-read assemblers work with reads whose [read length](../../GLOSSARY.md#read-length) runs to tens of thousands of bases, against the few hundred bases of an Illumina read.

Length is the whole point. Every assembler builds an [assembly graph](../../GLOSSARY.md#assembly-graph) and follows each stretch until it reaches a fork, a place where two ways forward are equally well supported. A repeat, a sequence that occurs more than once in the genome, creates such a fork because a short read cannot say which copy it came from. A read long enough to span the whole repeat resolves the fork by itself. That is why long reads usually give a handful of long contigs where short reads give hundreds of short ones.

The two tools suit different reads. Flye is built for [Oxford Nanopore](../../GLOSSARY.md#nanopore-sequencing) reads, which are long but individually noisy. It builds rough draft sequences that tolerate mismatches, builds a repeat graph from the drafts, and then polishes, revisiting the draft with the reads to correct bases. Hifiasm is built for PacBio HiFi reads, made by [circular consensus sequencing](../../GLOSSARY.md#circular-consensus-sequencing), which reads each molecule many times so that almost every base is correct. Because the reads are so accurate, hifiasm can keep the two parental copies of each chromosome apart. Those copies are what [ploidy](../../GLOSSARY.md#ploidy) counts, and humans carry two. Recent hifiasm versions, including the 0.25.0 LGE installs, also accept Nanopore reads, and LGE adds the option that tells it so.

The reads decide the assembler. Nanopore reads give you a choice of Flye or hifiasm, HiFi reads give you hifiasm alone, and Illumina reads give you neither.

## Why you would do this

Assemble long reads when you want a genome's structure rather than its individual bases. A short-read assembly can tell you which genes are present, but usually not their order, how many copies of a repeated element there are, or where a plasmid ends and the chromosome begins. A plasmid is a small circular DNA molecule that many bacteria carry beside their chromosome.

This chapter assembles the HG002 long reads. [HG002](../../GLOSSARY.md#hg002) is a benchmark human sample sequenced many times by many methods, so there is a published answer to check against. The fixture keeps only reads from the mitochondrion, whose genome is NCBI [accession](../../GLOSSARY.md#accession) `NC_012920.1`, 16,569 bases and circular. It holds 950 Nanopore reads totalling 4,348,051 bases and 363 HiFi reads totalling 4,991,345 bases. Dividing each total by 16,569 gives about 262-fold and 301-fold [coverage](../../GLOSSARY.md#coverage), far more than either assembler needs.

The small circular target is also a good teaching case for a real failure. Both assemblers report this circle at twice its true length, which [Circular genomes, trimmed, overlapped, or walked twice](01-when-to-assemble.md#circular-genomes-trimmed-overlapped-or-walked-twice) explains, and [From a doubled contig to a reference](#from-a-doubled-contig-to-a-reference) shows how to recover one copy.

On Nanopore reads, choose Flye for older or noisier reads, for a haploid genome such as a bacterium or a virus, and, with Metagenome mode, for a community. Choose hifiasm for HiFi reads, and for reads from a current Nanopore flow cell, the consumable chip the reads come from, when the two parental copies of a region must stay apart. [Choosing a tool](01-when-to-assemble.md#choosing-a-tool) compares all five assemblers in LGE and explains how long-read assembly differs from short-read assembly.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM.ont` and `HG002.chrM.hifi` bundles this section imports, each with its platform set. To import the files yourself instead, follow the rest of this section.

This chapter uses the hg002-long-reads fixture. Download `HG002.chrM.ont.fastq.gz` and `HG002.chrM.hifi.fastq.gz` from [the hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Import each file as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows. Each becomes its own [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, so look for two sidebar rows, `HG002.chrM.ont` and `HG002.chrM.hifi`. Nanopore reads of your own that arrive as a sequencing run folder, one subfolder per barcode, are imported as [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) shows. HiFi reads need no such step.

Install the `assembly` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries Flye 2.9.6 and hifiasm 0.25.0, the versions that produced this chapter's numbers. Each run on the fixture finishes in under a minute on a recent Mac.

## Procedure

### Assemble the Nanopore reads with Flye

1. Click the `HG002.chrM.ont` bundle in the sidebar to select it. The sheet assembles whatever is selected when you open it.

2. Choose **Tools > Assembly > Flye...**. The assembly sheet opens with Flye chosen. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Inputs** section. The **Detected** row should read ONT reads, meaning Oxford Nanopore Technologies, and the Read Layout row reads Single-input long-read assembly, since long reads are never paired. LGE detects the class from the first [FASTQ](../../GLOSSARY.md#fastq) header, falling back to the instrument recorded at import. The **Assembler** picker offers Flye and Hifiasm only, and the **Read Type** row is locked with "Locked from FASTQ header detection." beneath it.

4. The **Profile** picker opens on **Nano Raw**, and a caption beneath it says why, reporting that Nano Raw was preselected from a read quality of Q8 in the bundle's statistics. LGE reads the bundle's mean read quality when the sheet opens and preselects Nano Raw below Q10 and Nano HQ at Q10 or above. Nano HQ suits reads from a recent high-accuracy [basecaller](../../GLOSSARY.md#basecaller), the program that turns the sequencer's electrical signal into bases. The fixture's reads are older and noisier, at Q8, and Flye itself measures about 19% disagreement between them, so Nano Raw is the profile built for them. You can still pick another profile from the picker. Leave everything as it is.

    <!-- SHOT: assembly-sheet-flye -->

5. Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Flye names its own stages as it reaches them, from configure through contigger and polishing to finalize. A stage that stays on screen a while is working, not stuck.

### Assemble the HiFi reads with hifiasm

1. Click the `HG002.chrM.hifi` bundle in the sidebar. Opening a result changes the selection, so click the reads again before opening the menu.

2. Choose **Tools > Assembly > Hifiasm...**. The **Detected** row reads PacBio HiFi/CCS, and the **Assembler** picker shows Hifiasm alone, because it is the only assembler that accepts HiFi reads.

3. Leave **Profile** on **Diploid**, its default. A mitochondrion has one copy, so **Haploid/Viral** sounds like the better fit, but on these reads it gives the messier answer, as [Diploid or Haploid/Viral on a small circle](#diploid-or-haploidviral-on-a-small-circle) shows.

    <!-- SHOT: assembly-sheet-hifiasm -->

4. Click **Run**.

Hifiasm writes its answer as a [GFA](../../GLOSSARY.md#gfa) file, a text format for assembly graphs, rather than as plain FASTA sequence. LGE converts the primary contigs, hifiasm's main answer, into a `contigs.fasta` for the viewport without you asking.

### Open the results

Each run lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE opens each result when its run finishes. Later, click either row to open it again.

<!-- SHOT: flye-contig-table -->

## Settings

Both assemblers share one sheet, so an entry names its assembler only where the two differ. Memory Limit and Min Contig do not appear for either tool, because neither accepts them. Every slider has a number field beside it, so you can drag or type.

**Assembler.** Picks which assembler runs, listing only those that accept the detected read class, so Nanopore reads offer Flye and Hifiasm and HiFi reads offer Hifiasm alone. It defaults to the tool you chose from the menu. Switch it to try the other assembler on the same Nanopore reads, the one case with a real choice. On the command line this is `--assembler`.

**Read Type.** States which sequencing chemistry produced the reads, which narrows the Assembler picker. It defaults to the class read from the FASTQ headers and is locked when detection succeeds. It unlocks into a picker of Illumina short reads, ONT reads, and PacBio HiFi/CCS only when detection is inconclusive, as with older PacBio CLR data, a noisier mode with no class of its own here. On the command line this is `--read-type`.

**Profile.** Tells the assembler what input to expect. Flye offers **Nano HQ** for recent high-accuracy basecalls, **Nano Raw** for older or fast-mode basecalls, and **Nano Corrected** for reads another tool already corrected. LGE preselects Nano Raw when the reads' mean quality, read from the bundle's statistics or sampled from the first 500 reads, is below Q10, and Nano HQ otherwise, and the caption beneath the picker says which measurement it used. Hifiasm offers **Diploid** (the default), which keeps the two parental copies apart and purges duplicated copies of one stretch, and **Haploid/Viral**, which expects a single [haplotype](../../GLOSSARY.md#haplotype), one copy of each chromosome. It passes hifiasm `--n-hap 1`, and it skips duplicate purging (`-l0`) and a memory-saving filter (`-f0`) that a small genome does not need. Flye's own documentation describes Nano HQ as for reads under 5 percent error, about Q13, so reads with a mean quality between Q10 and Q13 may assemble better on Nano Raw than on the preselected Nano HQ. Override the preselection only when you know the basecaller better than the quality scores do. Keep hifiasm on Diploid for a first run, and try Haploid/Viral on a haploid genome, checking any extra low-depth contig it keeps against the main one. On the command line this is `--profile`, and leaving it off applies the same read-quality rule.

**Threads.** Sets how many processor cores the assembler uses at once. The default is the smaller of your Mac's core count and 8, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Metagenome mode.** Turns on Flye's metagenome setting, for a mixed community of organisms at very different abundances rather than one organism at even depth. It is off by default, belongs to Flye alone, and sits under **Advanced Settings > Curated extra arguments**. Turn it on for a community sample such as stool or seawater, and leave it off for a single isolate. This setting has no command-line flag, so pass `--extra-args "--meta"` instead.

**Primary contigs only.** Passes hifiasm's `--primary` option, which, despite the control's name, makes hifiasm write a primary and an alternate assembly instead of one set per parental copy. It is off by default, belongs to hifiasm alone, and sits in the same disclosure. It is offered for readers who want hifiasm's primary and alternate files on disk. Leave it off here, since LGE reads the primary contigs from hifiasm's default output files. This setting has no command-line flag, so pass `--extra-args "--primary"` instead.

**Extra arguments.** Passes text straight to the assembler without LGE checking it. The default is empty, which is right for almost every run. Use it only for an assembler option the dialog does not show, such as a Flye genome-size hint written `--genome-size 16k`, after reading that assembler's own documentation. On the command line this is `--extra-args`. Where your text and the Haploid/Viral profile set the same option, your value wins.

**Project Name.** Names the assembly the run produces. It defaults to the input file's name with `_assembly` added, for example `HG002.chrM.ont_assembly`. Rename it when you assemble the same reads more than once. For hifiasm it also becomes the prefix of every file hifiasm writes. On the command line this is `--project-name`.

Above the Extra arguments field, Advanced Settings prints four read-only notes for the selected assembler, each naming a family of options you could type in that field. They are reference, not controls.

<!-- SHOT: assembly-sheet-curated-arguments -->

## Reading the results

The contig table, the detail pane, and the Assembly Context block are read as [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md#reading-the-results) explains. [N50](../../GLOSSARY.md#n50) is the contig length at which contigs that long or longer hold half of all assembled bases, worked through in [When to Assemble](01-when-to-assemble.md#what-the-numbers-mean). This section covers what is particular to long-read results, above all what happens to a small circular genome.

### The files the viewport does not list

The contig table has no column for coverage, for whether a contig is circular, or for how often the assembler thinks a sequence repeats. Flye records all three in `assembly_info.txt` in the run folder, which **Show in Finder** on the result's right-click menu reveals. Flye also keeps its graph there as `assembly_graph.gfa`. Hifiasm writes its primary graph as `<project name>.bp.p_ctg.gfa`, plus one graph per parental copy, `hap1` and `hap2`, and unitig graphs ending `p_utg` and `r_utg`. A [unitig](../../GLOSSARY.md#unitig) is an unambiguous stretch from before any joins. Only the primary contigs reach the viewport.

### What the fixture gives

Run as the procedure describes, each assembler returns one contig about twice the length of the 16,569-base genome.

| Assembler and profile | Contigs | Length | GC | What it means |
|---|---|---|---|---|
| Flye, Nano Raw, imported bundle | 1, circular | 32,690 bp | 42.9% | The circle walked twice |
| Hifiasm, Diploid | 1, circular | 33,140 bp | 44.4% | The circle walked twice |

Both are the third outcome in [Circular genomes, trimmed, overlapped, or walked twice](01-when-to-assemble.md#circular-genomes-trimmed-overlapped-or-walked-twice). Neither assembler found an end in its graph at which to stop, so each went round twice and reported both passes as one contig. Hifiasm's contig is exactly two copies, since 33,140 divided by 16,569 is 2.0001. Flye's is a little under, 1.97 times, because Flye polished the two passes separately. Flye's `assembly_info.txt` marks its contig `circ. Y` with a mean coverage of 125, about half the reads' 262-fold, because every read now has two places to sit. Hifiasm names its contig `ptg000001c`, where the closing `c` marks it circular. A HiFi assembly of a whole nuclear genome does not behave this way, because the mitochondrion is then one small loop among long linear chromosomes.

Flye's contig is 42.9% GC where the reference and the hifiasm contig are 44.4%. [When to Assemble](01-when-to-assemble.md#what-good-looks-like) treats a GC several points away from the expected value as a warning, and a point and a half sits near that line. Here it is not contamination. The Nanopore reads average about Q8, and Flye's polishing cannot correct every systematic error such reads carry, the miscounted runs of one repeated base above all, so an unpolished Nanopore assembly can sit a point or two off in GC. The HiFi reads are accurate enough that hifiasm's contig matches the reference.

Nothing in the viewport flags a doubled contig. Its N50 and L50 look perfect. The check is knowing roughly how big the genome should be.

### What else Flye has given on these reads

Small, noisy data sets sit close to the point where Flye's choices tip one way or the other, so the profile, the read order, or the thread count can change the graph. Importing reads into a project reorders them for storage, which is why a run on the imported bundle and a run on the raw file need not agree. Flye has given four different answers on these reads.

| Input | Profile | Contigs | Total length | What it means |
|---|---|---|---|---|
| Imported bundle, 8 threads | Nano Raw | 1, circular | 32,690 bp | The circle walked twice, the procedure's result |
| Raw file | Nano HQ | 1, circular | 32,652 bp | The circle walked twice |
| Raw file | Nano HQ | 1, circular | 16,359 bp | The whole genome, with the join trimmed |
| Imported bundle | Nano HQ | 4, none circular | 22,137 bp | The circle broken into overlapping pieces |

The procedure as written, with the preselected Nano Raw on the imported bundle, gave the first row on both runs made for this manual. The four-contig run is worth reading too. Its contigs ran from 1,294 to 9,841 bases, its N50 was 5,800 and its L50 was 2, and Flye's `assembly_info.txt` gave several of them a multiplicity above 1, its estimate that a piece repeats. Four pieces that add up to more than the 16,569-base genome, some of them marked as repeats, are one circle cut into overlapping fragments, not four molecules. Nano HQ expects more accurate reads than these Q8 reads, which is why the sheet preselects Nano Raw for them.

### Diploid or Haploid/Viral on a small circle

The mitochondrion has one copy, so hifiasm's Haploid/Viral profile sounds right for it. Run on the same HiFi reads it returned two contigs, 60,111 bases in all. One is the same doubled circle of 33,140 bases, at a read depth of 170 in hifiasm's graph. The other is a linear contig of 26,971 bases at a depth of 16, and it lines up along its whole length, 99.9 percent identical, with part of the first. It is a partial duplicate copy of the same sequence, built from a minority of the reads. Diploid's duplicate purging removes exactly this kind of redundant copy, and Haploid/Viral turns the purging off. The procedure therefore keeps Diploid, and the lesson is to read a second, low-depth contig that repeats the first as a leftover copy, not a second molecule.

### From a doubled contig to a reference

A doubled contig holds the genome twice, so reads mapped to it split between two identical copies, which halves the depth and doubles every position. Cut one copy out before you map to it. Hifiasm's contig is exactly two copies, so one copy is its first half, positions 1 to 16,570, half of 33,140. The halves differ at one position in 16,570, so either half will do. HG002's own mitochondrion is one base longer than the 16,569-base reference, which is why the half is 16,570 rather than 16,569.

1. Turn the contig into a reference bundle as [Extracting Contigs](04-extracting-contigs.md) shows. Select its one row, `ptg000001c`, and click **Create Bundle**. The bundle lands under `Reference Sequences/`.
2. Open the new bundle, type `1-16570` into the location field at the left end of the ruler, and press Return.
3. Mark that range as a feature with **Sequence > Add Annotation...**, then right-click the feature, choose **Extract Sequence...**, and save it as a new bundle, as [Extract one annotated feature](../02-sequences/03-extracting-and-comparing.md#extract-one-annotated-feature) shows. The feature route cuts exactly the range you marked, where **Extract Visible Region...** cuts whatever the viewport frames.

The new bundle lands under `Extractions/` and holds one sequence of 16,570 bases, which aligns to the whole of `NC_012920.1`. It starts at a different place from the published reference and reads on the opposite strand, because the assembler chose its own cut point and direction. Map reads to it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, and expect positions that do not match the published numbering. For that numbering, map to `NC_012920.1` itself. [On the command line](#on-the-command-line) gives the same route as two commands.

Flye's doubled contig is not an exact double, so its halves are not a clean cut. For a single-copy mitochondrial reference from these reads, use the hifiasm contig, or the short-read contig from [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md), whose overshoot is only the closing overlap.

## What good looks like

Apply the four checks in [What good looks like](01-when-to-assemble.md#what-good-looks-like) of When to Assemble, above all the total length against the expected size. For a small circle, read the length as that chapter's circular-genome section explains.

- **About 16,569 in one contig.** The genome came back whole. Carry it forward.
- **About 33,000 in one contig.** The circle was walked twice. Cut one copy out as [From a doubled contig to a reference](#from-a-doubled-contig-to-a-reference) shows.
- **One doubled contig plus a shorter, low-depth one.** The shorter one is a leftover partial copy. Rerun hifiasm on Diploid, or ignore the extra contig.
- **Several contigs adding up to more than 16,569.** The circle broke into overlapping pieces. Check that **Profile** matches the reads, which for this fixture means the preselected Nano Raw, and run Flye again.
- **Well under 16,569.** Part of the genome had too little coverage to assemble, and more reads are the fix.

To run again, select the reads and open **Tools > Assembly > Flye...** again. Each run keeps its own folder, so you can compare results side by side. For hifiasm the lasting fix for a doubled mitochondrion is to assemble it together with the nuclear reads it came from. This fixture holds no nuclear reads, so for hifiasm the length check is the whole test.

Remember that a contig is a hypothesis. The doubled results in this chapter looked healthy by every summary number. When the answer matters, map the reads back and check that depth runs level along the contig, without a sharp drop or a halving.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every flag of `assemble` and `extract contigs` is listed under [Assembly](../appendices/cli-reference.md#assembly) in the CLI Reference, and `extract sequence` under [Sequence utilities](../appendices/cli-reference.md#sequence-utilities).

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

With `--profile` left off, as in the Flye command, the command applies the window's rule, choosing `nano-raw` for these reads and printing the choice with its basis in the Profile and Profile basis rows before Flye starts. The provenance file beside the output records both. `--output` writes exactly where you point it and makes no timestamped folder, so a second run into the same folder overwrites the first. Given the imported bundle, the command assembles the reads in the order the window does. The last command writes a plain FASTA file whose header reads `>ptg000001c:1-16570 [ptg000001c:1-16570, 1-based] [16570 bp]`, which you can import as a reference as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) shows. Both assemblers take one input, so combine several files from one sample first, for example with `cat a.fastq.gz b.fastq.gz > combined.fastq.gz`, then import the combined file.

## Next

Continue to [Extracting Contigs](04-extracting-contigs.md) to turn a contig into a [reference bundle](../../GLOSSARY.md#reference-bundle) you can map reads to or call variants against. Carry forward only a result whose length matches the genome you expect, or one copy cut from a doubled contig.
