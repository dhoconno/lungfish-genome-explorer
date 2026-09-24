---
title: Running Flye or hifiasm
chapter_id: 07-assembly/03-running-flye-or-hifiasm
audience: analyst
prereqs: [07-assembly/01-when-to-assemble, 03-reads/07-ont-runs]
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
    caption: "The assembly sheet opened from Tools > Assembly > Flye..., with the ONT bundle selected in the sidebar beforehand, showing the Inputs section reporting ONT reads under Detected, the Assembler picker offering Flye beside Hifiasm and nothing else, the locked Read Type row, and the Profile picker on Nano HQ."
  - id: assembly-sheet-hifiasm
    caption: "The same sheet opened from Tools > Assembly > Hifiasm... with the HiFi bundle selected, where the Assembler picker shows Hifiasm alone because it is the only assembler that accepts PacBio HiFi reads, and the Profile picker sits on Diploid."
  - id: assembly-sheet-curated-arguments
    caption: "The Advanced Settings section with the Curated extra arguments disclosure expanded for Flye, showing the Metagenome mode toggle above the four read-only option descriptions and the Extra arguments text field."
  - id: flye-contig-table
    caption: "The HG002-chrM-flye result with one 32,652 bp contig at 43.0% GC in the table, and the Inspector showing the HG002.chrM.ont.fastq.gz source, Flye 2.9.6, and a wall time of 46.6 seconds."
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

The two tools suit different reads. Flye is built for [Oxford Nanopore](../../GLOSSARY.md#nanopore-sequencing) reads, which are long but individually noisy. It builds rough draft sequences that tolerate mismatches, builds a repeat graph from the drafts, and then polishes, revisiting the draft with the reads to correct bases. Hifiasm is built for PacBio HiFi reads, made by [circular consensus sequencing](../../GLOSSARY.md#circular-consensus-sequencing), which reads each molecule many times so that almost every base is correct. Because the reads are so accurate, hifiasm can keep the two parental copies of each chromosome apart. Those copies are what [ploidy](../../GLOSSARY.md#ploidy) counts, and humans carry two. Hifiasm also accepts Nanopore reads, and LGE adds the option that tells it so.

The reads decide the assembler. Nanopore reads give you a choice of Flye or hifiasm, HiFi reads give you hifiasm alone, and Illumina reads give you neither.

## Why you would do this

Assemble long reads when you want a genome's structure rather than its individual bases. A short-read assembly can tell you which genes are present, but usually not their order, how many copies of a repeated element there are, or where a plasmid ends and the chromosome begins. A plasmid is a small circular DNA molecule that many bacteria carry beside their chromosome.

This chapter assembles the HG002 long reads. [HG002](../../GLOSSARY.md#hg002) is a benchmark human sample sequenced many times by many methods, so there is a published answer to check against. The fixture keeps only reads from the mitochondrion, whose genome is NCBI [accession](../../GLOSSARY.md#accession) `NC_012920.1`, 16,569 bases and circular. It holds 950 Nanopore reads totalling 4,348,051 bases and 363 HiFi reads totalling 4,991,345 bases. Dividing each total by 16,569 gives about 262-fold and 301-fold [coverage](../../GLOSSARY.md#coverage), far more than either assembler needs.

The small circular target is also a good teaching case for a real failure. Both assemblers can report a small circle at twice its true length, and [Reading the results](#reading-the-results) works through it.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the hg002-long-reads fixture. Download `HG002.chrM.ont.fastq.gz` and `HG002.chrM.hifi.fastq.gz` from [the hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Import each file as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows. Each becomes its own [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, so look for two sidebar rows, `HG002.chrM.ont` and `HG002.chrM.hifi`.

Install the `assembly` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries Flye 2.9.6 and hifiasm 0.25.0, the versions that produced this chapter's numbers. Each run on the fixture finishes in under a minute on a recent Mac.

## Procedure

### 1. Assemble the Nanopore reads with Flye

1. Click the `HG002.chrM.ont` bundle in the sidebar to select it. The sheet assembles whatever is selected when you open it.

2. Choose **Tools > Assembly > Flye...**. The assembly sheet opens with Flye chosen. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Inputs** section. The **Detected** row should read ONT reads, meaning Oxford Nanopore Technologies, and the Read Layout row reads Single-input long-read assembly, since long reads are never paired. LGE detects the class from the first [FASTQ](../../GLOSSARY.md#fastq) header, falling back to the instrument recorded at import. The **Assembler** picker offers Flye and Hifiasm only, and the **Read Type** row is locked with "Locked from FASTQ header detection." beneath it.

4. Leave **Profile** on **Nano HQ**, its default, which suits reads from a recent high-accuracy [basecaller](../../GLOSSARY.md#basecaller), the program that turns the sequencer's electrical signal into bases. The fixture's reads were made that way. Leave everything else as it is.

    <!-- SHOT: assembly-sheet-flye -->

5. Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Flye names its own stages as it reaches them, from configure through contigger and polishing to finalize. A stage that stays on screen a while is working, not stuck.

### 2. Assemble the HiFi reads with hifiasm

1. Click the `HG002.chrM.hifi` bundle in the sidebar. Opening a result changes the selection, so click the reads again before opening the menu.

2. Choose **Tools > Assembly > Hifiasm...**. The **Detected** row reads PacBio HiFi/CCS, and the **Assembler** picker shows Hifiasm alone, because it is the only assembler that accepts HiFi reads.

3. Leave **Profile** on **Diploid**, its default, which keeps the two chromosome copies apart. A mitochondrion has one copy, so **Haploid/Viral** fits it better in principle, but Diploid is the setting that produced this chapter's result, and the doubling described below comes from the circle rather than the profile.

    <!-- SHOT: assembly-sheet-hifiasm -->

4. Click **Run**.

Hifiasm writes its answer as a [GFA](../../GLOSSARY.md#gfa) file, a text format for assembly graphs, rather than as plain FASTA sequence. LGE converts the primary contigs, hifiasm's main answer, into a `contigs.fasta` for the viewport without you asking.

### 3. Open the results

Each run lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. LGE opens each result when its run finishes. Later, click either row to open it again.

<!-- SHOT: flye-contig-table -->

## Settings

Both assemblers share one sheet, so an entry names its assembler only where the two differ. Memory Limit and Min Contig do not appear for either tool, because neither accepts them. Every slider has a number field beside it, so you can drag or type.

**Assembler.** Picks which assembler runs, listing only those that accept the detected read class, so Nanopore reads offer Flye and Hifiasm and HiFi reads offer Hifiasm alone. It defaults to the tool you chose from the menu. Switch it to try the other assembler on the same Nanopore reads, the one case with a real choice. On the command line this is `--assembler`.

**Read Type.** States which sequencing chemistry produced the reads, which narrows the Assembler picker. It defaults to the class read from the FASTQ headers and is locked when detection succeeds. It unlocks into a picker of Illumina short reads, ONT reads, and PacBio HiFi/CCS only when detection is inconclusive, as with older PacBio CLR data, a noisier mode with no class of its own here. On the command line this is `--read-type`.

**Profile.** Tells the assembler what input to expect. Flye offers **Nano HQ** (the default) for recent high-accuracy basecalls, **Nano Raw** for older or fast-mode basecalls, and **Nano Corrected** for reads another tool already corrected. Hifiasm offers **Diploid** (the default), which keeps the two parental copies apart, and **Haploid/Viral**, which expects a single [haplotype](../../GLOSSARY.md#haplotype), one copy of each chromosome, and skips duplicate purging and a memory-saving filter that a small one-copy genome does not need. Choose Nano Raw for older reads, and Haploid/Viral for a virus, a haploid genome, or any small target. On the command line this is `--profile`.

**Threads.** Sets how many processor cores the assembler uses at once. The default is the smaller of your Mac's core count and 8, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Metagenome mode.** Turns on Flye's metagenome setting, for a mixed community of organisms at very different abundances rather than one organism at even depth. It is off by default, belongs to Flye alone, and sits under **Advanced Settings > Curated extra arguments**. Turn it on for a community sample such as stool or seawater, and leave it off for a single isolate. This setting has no command-line flag, so pass `--extra-args "--meta"` instead.

**Primary contigs only.** Passes hifiasm's `--primary` option, which, despite the control's name, makes hifiasm write a primary and an alternate assembly instead of one set per parental copy. It is off by default, belongs to hifiasm alone, and sits in the same disclosure. It is offered for readers who want hifiasm's primary and alternate files on disk. Leave it off here, since LGE reads the primary contigs from hifiasm's default output files. This setting has no command-line flag, so pass `--extra-args "--primary"` instead.

**Extra arguments.** Passes text straight to the assembler without LGE checking it. The default is empty, which is right for almost every run. Use it only for an assembler option the dialog does not show, such as a Flye genome-size hint written `--genome-size 16k`, after reading that assembler's own documentation. On the command line this is `--extra-args`. Where your text and the Haploid/Viral profile set the same option, your value wins.

**Project Name.** Names the assembly the run produces. It defaults to the input file's name with `_assembly` added, for example `HG002.chrM.ont_assembly`. Rename it when you assemble the same reads more than once. For hifiasm it also becomes the prefix of every file hifiasm writes. On the command line this is `--project-name`.

Above the Extra arguments field, Advanced Settings prints four read-only notes for the selected assembler, each naming a family of options you could type in that field. They are reference, not controls.

<!-- SHOT: assembly-sheet-curated-arguments -->

## Reading the results

The contig table, the detail pane, and the Assembly Context block are read as [Running SPAdes](02-running-spades.md#reading-the-results) explains. [N50](../../GLOSSARY.md#n50) is the contig length at which contigs that long or longer hold half of all assembled bases, worked through in [When to Assemble](01-when-to-assemble.md#what-the-numbers-mean). This section covers what is particular to long-read results, above all what happens to a small circular genome.

### The files the viewport does not list

The contig table has no column for coverage, for whether a contig is circular, or for how often the assembler thinks a sequence repeats. Flye records all three in `assembly_info.txt` in the run folder, which **Show in Finder** on the result's right-click menu reveals. Flye also keeps its graph there as `assembly_graph.gfa`. Hifiasm writes its primary graph as `<project name>.bp.p_ctg.gfa`, plus one graph per parental copy, `hap1` and `hap2`, and unitig graphs ending `p_utg` and `r_utg`. A [unitig](../../GLOSSARY.md#unitig) is an unambiguous stretch from before any joins. Only the primary contigs reach the viewport.

### A circle cut open, once or twice

A linear contig has two ends, and a circular genome has none, so an assembler must cut the circle somewhere to write it out. Where it cuts, it either trims the join slightly, writes the overlap twice, or walks the whole circle more than once. These are the three outcomes to recognise.

A slightly short contig is a trimmed join. Most Flye runs on this fixture give one contig of 16,359 bases at 43.9% GC, with an L50 of 1. That is 210 bases, or 1.3%, under the 16,569-base reference, and Flye's `assembly_info.txt` marks it `circ. Y`, meaning circular. A percent or two under a known size reads as a trimmed junction.

A contig slightly long is the overlap written twice. That is what the short-read assemblers did in [Running SPAdes](02-running-spades.md#reading-the-results), where SPAdes ran 128 bases over.

A contig about twice the expected length is the circle walked twice. Hifiasm's result for the fixture is one contig of 33,140 bases at 44.4% GC, and 33,140 divided by 16,569 is 2.0001. Hifiasm looks for an end in its graph at which to stop, and a small circle assembled on its own offers none, so it goes round twice and reports both passes as one contig. A HiFi assembly of a whole nuclear genome does not behave this way, because the mitochondrion is then one small loop among long linear chromosomes. On this fixture the doubling is routine for hifiasm and rerunning does not clear it.

Flye can double too. In repeated Flye runs on these identical reads, most gave the 16,359-base contig, but one gave 32,652 bases at 43.0% GC, marked circular with a multiplicity of 4. Multiplicity is Flye's estimate of how many times a sequence repeats, and any value above 1 on a genome with no such repeat is Flye flagging the doubling in a file the window does not show. The screenshot above shows that doubled run. Either result can happen to you.

Nothing in the viewport flags a doubled contig. Its N50 and L50 look perfect. The check is knowing roughly how big the genome should be.

To confirm a doubling rather than assume it, turn the contig into a reference bundle as [Extracting Contigs](04-extracting-contigs.md) describes, then map the same reads back as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes. Every read then fits two places, so the two halves carry the same sequence and the depth reads about half what it should. For the Nanopore fixture, at about 262-fold, a doubled contig shows roughly 130x along its length. LGE does not collapse a doubled contig. For Flye, select the reads, open **Tools > Assembly > Flye...** again, and compare the new run beside the old one, since each run keeps its own folder. For hifiasm, the lasting fix is to assemble the mitochondrion together with the nuclear reads it came from. This fixture holds no nuclear reads, so here the length check is the whole test.

## What good looks like

Check the total length against the expected size first. The committed Flye result sits 1.3% under 16,569 bases, a trimmed junction. The doubled Flye run at 32,652 bases and hifiasm's 33,140 are about twice the size, the circle walked twice, and need the check above before you carry them forward. A length far under what you expected means the assembler could not bridge something, most often a stretch where coverage dropped away.

Then check the contig count against the number of separate DNA molecules you expect. That is one for a mitochondrion, one for a bacterial chromosome plus one per plasmid, and roughly one per chromosome for a deeply covered HiFi assembly of a small genome such as yeast. A count far higher usually means reads too short to span the repeats, coverage too thin, or a read set that is not long-read data at all. The Detected row from step 1 is the check on that last cause.

Then read the N50 beside the contig count. Together they say whether a fragmented assembly is evenly fragmented or one good contig among small scraps, and only the second is usually usable.

Finally, remember that a contig is a hypothesis. Both doublings in this chapter looked healthy by every summary number. When the answer matters, map the reads back and check that depth runs level along the contig, without a sharp drop or a halving.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli assemble HG002.chrM.ont.fastq.gz \
  --assembler flye --read-type ont-reads \
  --profile nano-hq \
  --project-name HG002-chrM-flye \
  --output ./flye-out

lungfish-cli assemble HG002.chrM.hifi.fastq.gz \
  --assembler hifiasm --read-type pacbio-hifi \
  --profile diploid \
  --project-name HG002-chrM-hifiasm \
  --output ./hifiasm-out
```

One difference changes results. `--output` writes exactly where you point it and makes no timestamped folder, so a second run into the same folder overwrites the first, while the window always makes a new folder under `Analyses/`. Both assemblers take one input file, so combine several files from one sample first, for example with `cat a.fastq.gz b.fastq.gz > combined.fastq.gz`.

## Next

Continue to [Extracting Contigs](04-extracting-contigs.md) to turn a contig into a [reference bundle](../../GLOSSARY.md#reference-bundle) you can map reads to or call variants against. The 16,359-base Flye contig is close to the expected mitochondrial length. The doubled results need review before either is carried forward.
