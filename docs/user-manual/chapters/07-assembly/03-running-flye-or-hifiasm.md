---
title: Running Flye or hifiasm
chapter_id: 07-assembly/03-running-flye-or-hifiasm
audience: analyst
prereqs: [07-assembly/01-when-to-assemble, 03-reads/07-ont-runs]
estimated_reading_min: 28
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
glossary_refs: [accession, assembly-bundle, assembly-graph, basecaller, bundle, circular-consensus-sequencing, contig, coverage, de-novo-assembly, fastq, gc-content, gfa, haplotype, l50, n50, nanopore-sequencing, operations-panel, ploidy, plugin-pack, read, read-length, reference-bundle, unitig]
features_refs: []
fixtures_refs: [hg002-long-reads]
brand_reviewed: true
lead_approved: true
---

## What it is

Flye and hifiasm are the two long-read assemblers that Lungfish Genome Explorer (LGE) includes. An assembler is a program that joins sequencing [reads](../../GLOSSARY.md#read) into longer sequences. [De novo assembly](../../GLOSSARY.md#de-novo-assembly) means reconstructing a genome from reads alone, with no reference sequence to guide the work, and a [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence the assembler managed to reconstruct. Long-read assembly does that job with reads whose [read length](../../GLOSSARY.md#read-length) runs to tens of thousands of bases, against the few hundred bases produced by an Illumina instrument, the short-read sequencer used in most laboratories.

The length is the whole point, and the reason is a property of the graph rather than a mystery. Every assembler builds an [assembly graph](../../GLOSSARY.md#assembly-graph) first. In that graph a node is a stretch of sequence that several reads read the same way, and an edge is an observed overlap joining two such stretches. Node and edge are the formal names, and this chapter uses them throughout. Emitting contigs then means following a stretch for as long as exactly one edge leads forward, and stopping at the first place where two or more edges lead forward. That stopping point is a fork. A repeat, meaning a sequence that occurs more than once in the genome, creates exactly such a fork, because the assembler cannot tell which copy a short read came from. A read long enough to span the whole repeat and reach unique sequence on both sides resolves the fork by itself. That is why the same organism assembled from long reads usually returns a handful of long contigs where short reads returned hundreds of short ones.

The two assemblers take different routes to that graph, and the difference follows from the accuracy of the reads each was built for. Flye works with [Oxford Nanopore](../../GLOSSARY.md#nanopore-sequencing) reads, which are long but individually noisy, so it first builds draft sequences that allow mismatches between the reads, then builds a repeat graph from those drafts, then polishes the result, meaning it revisits the draft with the reads a second time and corrects the bases they disagree with. Hifiasm works with PacBio HiFi reads, which are produced by [circular consensus sequencing](../../GLOSSARY.md#circular-consensus-sequencing) and are accurate enough that each individual base is almost always correct, so it can overlap the reads directly and keep the two parental copies of each chromosome apart rather than blending them. Those two copies are what [ploidy](../../GLOSSARY.md#ploidy) counts, since ploidy is how many copies of each chromosome an organism carries and a human carries two, one inherited from each parent. Hifiasm also accepts Nanopore reads, and LGE adds the option that tells it so, so you never type anything. An option passed to a program on the command line is called a flag, and this chapter names flags only where the command line is involved.

LGE runs both through the same assembly sheet, which is shared by all five of its assemblers, so nothing here assumes you read the SPAdes chapter first. Both write the same kind of output. Each run produces an assembly result in a per-run folder under the project's `Analyses` folder, holding its contig sequences and run records, and each opens in the same assembly viewport. The result appears as one sidebar row. Use **Create Bundle** to turn selected contigs into a `.lungfishref` reference bundle for later mapping.

The practical takeaway is that the reads decide the assembler, not your preference. Nanopore reads give you a choice between Flye and hifiasm, HiFi reads give you hifiasm alone, and Illumina reads give you neither.

## Why you would do this

You would assemble long reads whenever the thing you want to know about the genome is its structure rather than its individual bases. A short-read assembly can tell you which genes are present. It usually cannot tell you in what order they sit, how many copies of a repeated element there are, or where one plasmid ends and the chromosome begins. A plasmid is a small circular DNA molecule that sits alongside the main chromosome in many bacteria and copies itself separately. Those are precisely the questions the assembler leaves unanswered when a repeat makes the path through the graph ambiguous.

This chapter assembles the HG002 long reads, a fixture holding both Nanopore and HiFi reads from the same human sample. HG002 is a well characterised human DNA sample distributed by the Genome in a Bottle consortium as a reference material, meaning a sample sequenced many times by many methods so that everyone can check their own results against a published answer. It is the son in a mother, father, and child set that were all sequenced together, an arrangement geneticists call a trio, and it carries two catalogue names for the one sample (HG002 and NA24385). The fixture keeps only the reads that came from the mitochondrion, whose genome is catalogued at NCBI under the [accession](../../GLOSSARY.md#accession) `NC_012920.1`, a permanent identifier for one deposited sequence, and is 16,569 base pairs long and circular.

Mitochondria sit at high copy number in every cell, so a whole-genome long-read library over-covers the mitochondrion heavily, and the fixture thins each set down to roughly 300-fold [coverage](../../GLOSSARY.md#coverage), meaning each position is covered by about three hundred reads on average. You can check that arithmetic against the fixture itself. Its 950 Nanopore reads hold 4,348,051 bases in total, and 4,348,051 divided by the genome's 16,569 bases is 262, so each base sits under about 262 reads. The 363 HiFi reads hold 4,991,345 bases and work out at 301-fold the same way. Both figures are far more coverage than either assembler needs, which is part of why this fixture assembles cleanly, and the fixture is all you need to follow this chapter.

That target is deliberately small, which makes it a good teaching case and one that shows a real failure mode. Both assemblers finish quickly, both reconstruct the whole genome, and both can report a circular genome at twice its true length, which is the failure the Reading the results section works through. A real Nanopore assembly of a bacterial isolate or a HiFi assembly of a vertebrate genome behaves the same way and takes far longer.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. Pick an empty folder or make a new one, since LGE fills the folder with its own structure. A project you already made for an earlier chapter works just as well, since every run lands in its own folder and nothing overwrites anything.

This chapter uses the HG002 long reads. Download the fixture folder from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-long-reads

GitHub offers no download for a single folder, so open the repository's front page at https://github.com/dhoconno/lungfish-genome-explorer, click the green **Code** button, choose **Download ZIP**, double-click the downloaded file to unpack it, and find the folder inside it under `docs/user-manual/fixtures/`. That ZIP holds the whole manual repository rather than this one fixture, and it unpacks to a folder named `lungfish-genome-explorer-main`. Only two files inside it matter here, `HG002.chrM.ont.fastq.gz`, holding 950 Nanopore reads, and `HG002.chrM.hifi.fastq.gz`, holding 363 HiFi reads. Import both into your project as described in [Importing FASTQ Files](../03-reads/01-importing-fastq.md). Each file becomes its own [bundle](../../GLOSSARY.md#bundle), so the fixture gives you two sidebar rows rather than one. A bundle is a folder LGE treats as one object and draws as a single row, named for the file it came from, so look for rows reading `HG002.chrM.ont` and `HG002.chrM.hifi`. The import also records which sequencing instrument produced each file, which the next section relies on.

Flye and hifiasm both arrive in the Genome Assembly [plugin pack](../../GLOSSARY.md#plugin-pack), which the Plugin Manager lists under that name. A plugin pack is a themed group of tools LGE downloads on demand into its own private storage, so nothing is added to the rest of your Mac. The download needs an internet connection the first time and none afterwards. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and install Genome Assembly if it is not already there. The pack holds SPAdes, MEGAHIT, SKESA, Flye, and hifiasm together, so one install covers all five and an earlier chapter's install already covered these two. LGE always uses the exact tool versions it was tested against, which are Flye 2.9.6 and hifiasm 0.25.0, and the Plugin Manager shows you the version it installed.

## Procedure

The worked example assembles each read set with the assembler that suits it, Nanopore reads with Flye and HiFi reads with hifiasm. Every number quoted in this chapter came from real runs made on 2026-09-07 with Flye 2.9.6 and hifiasm 0.25.0. Those runs went through `lungfish-cli`, the command-line tool, only so that the exact commands could be recorded for anyone repeating them. The sheet described below runs the same tools with the same settings and produces the same kinds of output, so nothing in this chapter needs a terminal.

Two of the steps below use a right-click menu on a sidebar row, which is where LGE keeps **Reassemble...** and **Show in Finder**. Neither is reachable any other way.

### 1. Assemble the Nanopore reads with Flye

1. Click the `HG002.chrM.ont` bundle in the project sidebar to select it. The sheet has no input picker of its own, so whatever is selected when you open the menu is what gets assembled. You do get a check, since the sheet's Inputs section names the selected bundle and you can read it before pressing Run.

2. Choose **Tools > Assembly > Flye...**. Assembly is a submenu holding one item per assembler, so SPAdes, MEGAHIT, SKESA, Flye, and Hifiasm are five separate menu items that all open the same sheet. The sheet opens with Flye already chosen, because that is the item you clicked.

3. Read the **Inputs** section at the top. It names your bundle on the Dataset row, states whether the reads are single or paired on the Read Layout row, and reports the read class LGE detected on the **Detected** row, which should read ONT reads. ONT is short for Oxford Nanopore Technologies, the maker of the sequencer. Long reads are always single rather than paired, so the Read Layout row reads single here. Detection works by reading the first [FASTQ](../../GLOSSARY.md#fastq) header in the file and matching its text against the patterns each instrument writes. When the header matches nothing, LGE falls back to the instrument the bundle recorded when you imported it. If the Detected row names the wrong class, the Read Type control below unlocks so you can set it yourself.

4. Look at the **Assembler** picker under Primary Settings. It offers Flye and Hifiasm and nothing else, because those are the two assemblers that accept Nanopore reads. The **Read Type** row below it is a plain label reading ONT reads with the note "Locked from FASTQ header detection." underneath, since there is nothing to decide once detection has succeeded.

5. Leave the **Profile** picker on **Nano HQ**, its default. Basecalling is the step that translates a sequencer's raw electrical signal into letters, and a [basecaller](../../GLOSSARY.md#basecaller) is the program that does it. Nano HQ suits reads basecalled by one of the recent high-accuracy models, which is how the fixture's reads were produced.

    <!-- SHOT: assembly-sheet-flye -->

Everything else on the sheet can stay as it is for this run. The sheet's own **Advanced Settings** section is closed when the sheet opens, and you can leave it closed, since this chapter's Settings section explains everything inside it and none of it needs changing for a single organism whose reads cover the genome evenly, which the fixture's do. Glance at the **Project Name** under Output, which becomes the name of the bundle the run produces. For this file it fills in as `HG002.chrM.ont_assembly`, and the underscore is part of the name LGE writes rather than something you type. Glance also at the **Output Folder** line beneath it, which reports where the run will write. Then click **Run**.

The sheet closes and a row appears in the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P). The panel streams Flye's own output as it works, so what you read there is Flye's wording rather than anything LGE composed, and you can ignore all of it unless the run fails. Flye names its own internal stages as it reaches them, running through configure, assembly, consensus, repeat, contigger, polishing, and finalize. None of those names asks anything of you, and a stage that sits on screen for a while is working rather than stuck. The whole text is also saved as `assembly.log` in the run folder. The earlier CLI reference run finished in 35.2 seconds on an Apple silicon laptop, meaning a Mac with one of Apple's M-series chips. A slower or busier machine takes longer, and a run time is not a check on a result.

### 2. Assemble the HiFi reads with hifiasm

1. Click the `HG002.chrM.hifi` bundle in the sidebar. Clicking anything else in the sidebar changes what is selected, and opening a result counts, so click the reads again before you open the menu.

2. Choose **Tools > Assembly > Hifiasm...**. The sheet opens with Hifiasm chosen and the Detected row reading PacBio HiFi/CCS. CCS stands for circular consensus sequencing, the method named earlier that makes these reads accurate.

3. Look at the **Assembler** picker. It shows Hifiasm alone, with no other choice beside it. That is correct rather than broken. Hifiasm is the only assembler in LGE that accepts HiFi reads, so there is nothing else the picker could offer.

4. Leave the **Profile** picker on **Diploid**, its default. Diploid means two copies of each chromosome, which is the ploidy introduced above. The Diploid profile keeps those two copies apart rather than merging them into one blended sequence.

    <!-- SHOT: assembly-sheet-hifiasm -->

5. Click **Run**. The reference run finished in 5.9 seconds, and again a slower machine takes longer.

Hifiasm writes its assembly as a [GFA](../../GLOSSARY.md#gfa) file rather than a FASTA. GFA is a text format for assembly graphs in which each node carries its sequence and each edge records an overlap, and FASTA is the plain text format that holds sequences without any graph around them. LGE converts the primary contig graph in that GFA into a `contigs.fasta` of its own before the viewport can list anything. Primary here means the one contig set hifiasm designates as its main answer, as against the alternate copies it also writes. The conversion happens without you asking, and you never have to open either file yourself.

### 3. Open the results

Both runs land in the project's `Analyses` folder, each in its own folder that appears as a row in the sidebar under Analyses. LGE names that folder for the tool and the moment the run started. The name reads as the year, then the month, then the day, then the letter `T`, then the hour, minute, and second, so a Flye run started at ten past two in the afternoon on 7 September 2026 gives `flye-2026-09-07T14-23-10`. A second run of the same reads therefore never overwrites the first. Double-click either folder row and the assembly viewport opens.

<!-- SHOT: flye-contig-table -->

To rerun an assembly with different settings, right-click the bundle in the sidebar and choose **Reassemble...**, which reopens the sheet against the reads the bundle came from. That item appears only on a bundle LGE assembled itself, since only those carry a record of which reads and settings produced them. Every assembly you make in LGE has one. Reads you imported and reference sequences you downloaded do not, and show no Reassemble item.

The same right-click menu carries **Show in Finder**, which opens the run folder itself. That is the route to the files the viewport does not list, and two places later in this chapter need it.

## Settings

Every setting of both assemblers is documented below. The two share most of their controls, because both run through one sheet, so a paragraph names the assembler it belongs to only where the two differ.

The sheet carries seven controls for each assembler. Five sit in plain view under Primary Settings and Output, and two sit inside the sheet's Advanced Settings section. Eight bold entries follow rather than seven, because one of the advanced pair belongs to Flye alone and the other to hifiasm alone. Metagenome mode is Flye's, Primary contigs only is hifiasm's, and the other six are shared, so either assembler shows you seven.

Two controls that appear for the short-read assemblers are absent here. Memory Limit, which caps how much of your Mac's memory a run may use, does not appear, because neither Flye nor hifiasm accepts a memory budget. Min Contig, which discards contigs below a length you set, does not appear either, for the same reason. Nothing is hidden behind either absence.

**Assembler.** Picks which assembler runs the job, and lists only the assemblers that accept the read class LGE detected, so a Nanopore bundle offers Flye and Hifiasm while a HiFi bundle offers Hifiasm alone. It defaults to whichever assembler you chose from the Tools menu, since the menu item is what opened the sheet. Switch it when you want the other assembler on the same Nanopore reads, which is the one case where a genuine choice exists.

**Read Type.** States which sequencing chemistry produced the reads, and is what narrows the Assembler picker above it. It defaults to the class read off the FASTQ headers and is drawn as a locked label rather than a control whenever that detection succeeded, with the note "Locked from FASTQ header detection." beneath it. It unlocks into a three-way picker offering Illumina short reads, ONT reads, and PacBio HiFi/CCS only when detection came back inconclusive, which is what happens with a PacBio CLR library, since CLR, short for continuous long read, is an older and noisier PacBio mode that has no read class of its own in this version.

**Profile.** Tells the assembler what kind of input to expect, and offers different choices for each tool. Flye's three profiles are **Nano HQ**, the default, for reads basecalled by a recent high-accuracy model, **Nano Raw** for older or fast-mode basecalls, and **Nano Corrected** for reads another tool has already error-corrected. Hifiasm's two profiles are **Diploid**, the default, which keeps the two parental copies of each chromosome apart, and **Haploid/Viral**, which tells hifiasm to expect a single [haplotype](../../GLOSSARY.md#haplotype) and skips two steps it would otherwise run first. The first of those steps, duplicate purging, removes contigs that are second copies of a sequence already assembled, which a one-copy genome does not have. The second builds a filter that keeps hifiasm's memory use down on a large genome, which a small target does not need, and skipping both is what makes the profile fast. Move Flye down to Nano Raw when the reads predate the high-accuracy models, and pick Haploid/Viral in hifiasm for a virus, a haploid genome, or any small target where purging duplicates only wastes time.

**Threads.** Sets how many processor cores the assembler may use at once. A higher value finishes the run sooner. The cost is that it leaves less of the machine free, so everything else you do while it runs feels slower. It defaults to the smaller of your Mac's core count and 8, and the slider will not let you exceed the number of cores your Mac reports, so the sheet already shows you a sound number and you need not work one out. Should you want to know your own core count, the Apple menu's **About This Mac** reports it. Lower the value when you want the machine responsive for other work while a long assembly proceeds.

**Metagenome mode.** Turns on Flye's metagenome setting, which tells Flye to expect a metagenome, meaning a mixed community of many organisms present in very different amounts, rather than one organism at even depth. It is off by default and belongs to Flye alone, and it lives inside the **Curated extra arguments** disclosure under Advanced Settings rather than in plain view. Turn it on for a stool or seawater sample, which is a community, and leave it off for a single bacterial colony, which is one genome.

**Primary contigs only.** Restricts hifiasm to writing only the primary assembly, leaving out the alternate haplotype copies. The primary set is hifiasm's main answer, one contig per stretch of genome, and the alternate set holds the second parental copy of each stretch where the two differ. It is off by default, belongs to hifiasm alone, and sits in the same Curated extra arguments disclosure. Turn it on when you have no use for the alternate haplotype and want the run to finish sooner. The viewport lists the primary contigs either way, so this changes what lands on disk rather than what you see.

**Extra arguments.** Passes text straight through to the assembler exactly as you typed it, without LGE checking it, which is the way to reach any option the sheet does not offer. It is empty by default and should stay empty for almost every run, since a typo here makes the run fail rather than being caught. Use it for something with no control of its own, such as a genome-size hint to Flye written as `--genome-size 16k`, where `16k` means 16 kilobases, that is 16,000 bases, which is the rounded size of the 16,569 base mitochondrial genome this chapter assembles. One rule governs what happens when your text and a profile collide. The Haploid/Viral profile fills in only the arguments you did not supply yourself, so your own value is the one that reaches the assembler.

**Project Name.** Names the assembly bundle the run produces, and defaults to the input file's name with `_assembly` appended. Paired-end files carry a mate suffix, the `_R1` or `_R2` marker that says which half of a pair a file holds, and LGE strips that suffix before appending. Long reads are never paired, so nothing is stripped from the fixture's names. An empty name blocks Run, so the field always holds something. Rename it when you assemble the same reads more than once and want to tell the results apart. For hifiasm alone this name also becomes the prefix on every file hifiasm writes inside the run folder, which affects those file names and nothing else.

The Advanced Settings section also prints four read-only descriptions for whichever assembler is selected, above the Extra arguments field. They are reference notes rather than controls, so nothing about them is clickable, and you can skip them unless you are writing something into Extra arguments. Flye's four each name a family of options you could type there. ONT Read Mode covers the basecall-quality choice the Profile picker already makes for you. Genome Size covers the expected-size hint. Overlap / Assembly Coverage covers the minimum read overlap and the depth Flye assembles from. Haplotype Controls covers whether Flye keeps alternative versions of a region apart. Hifiasm's four work the same way. Small-Genome Memory Tuning covers the memory filter described under Profile. Purge Duplication covers the duplicate-purging step. Primary / Alternate Output covers which contig sets get written. Haplotype Assumption covers how many haplotypes hifiasm expects.

<!-- SHOT: assembly-sheet-curated-arguments -->

### The same settings on the command line

This subsection is for readers who intend to script a run. If you work in the LGE window you can skip to Reading the results, since every control above is complete without it.

Six of the eight settings reach the command line as a flag of their own. Assembler is `--assembler`, Read Type is `--read-type`, Profile is `--profile`, Threads is `--threads`, Extra arguments is `--extra-args`, and Project Name is `--project-name`. Every one of those flags defaults to the same value its control does.

The two toggles in the Curated extra arguments disclosure have no flag of their own, so each reaches the command line through `--extra-args` instead. Metagenome mode is `--extra-args "--meta"` for Flye, and Primary contigs only is `--extra-args "--primary"` for hifiasm. The Haploid/Viral profile likewise passes `--n-hap 1`, `-l0`, and `-f0` to hifiasm on your behalf, and supplying any of those three yourself in `--extra-args` overrides what the profile would have added.

Five further options exist on the command line with no counterpart in the sheet, and they apply to both assemblers. `--output` writes the run somewhere other than the project's `Analyses` folder, and accepts `-o` and `--output-dir` as aliases. `--extra-arg` adds one argument at a time and may be repeated, which is the safer sibling of `--extra-args` when an argument contains spaces. `--format` prints the run summary as `text`, `json`, or `tsv` instead of the default text. The last two are traps rather than tools. `--memory-gb` is accepted by the command and then silently ignored for both of these tools, since neither takes a memory budget, which is the same reason the sheet hides its Memory Limit slider, and `--min-contig-length` is accepted and ignored in exactly the same way. Neither prints a warning, so a script that passes either will run as though it had not.

## Reading the results

The assembly viewport lists the contigs in a table. The Inspector's **Bundle** tab provides **Source Data** and **Assembly Context** beside it.

The Assembly Context block reports the assembler, the read type, the contig count, the total assembled length in base pairs, [N50](../../GLOSSARY.md#n50), [L50](../../GLOSSARY.md#l50), the longest contig, and the whole-assembly [GC content](../../GLOSSARY.md#gc-content) as a percentage. GC content is the share of bases that are G or C rather than A or T, and its one everyday use here is as a fingerprint, since a contig whose GC differs sharply from the rest often came from a different organism. The earlier reference runs in this chapter land near 44%, which is what a human mitochondrion gives, and neither number needs judging on its own. The block adds the resolved tool version and the wall time, meaning the elapsed real time the run took from start to finish, whenever the run recorded them, which a run started inside LGE always does.

The contig table carries six columns, holding each contig's rank, its name, its length in base pairs, its GC percent, its share of the whole assembly as a percentage, and a preview of its opening sequence, which is the contig's first 80 bases. Two columns you might want are not there. The table shows no per-contig coverage, and it shows nothing at all about whether a contig is circular or how many times the assembler thinks a sequence repeats, which matters for the doubling described below. Flye records all three in a file called `assembly_info.txt` in the run folder, which you reach by right-clicking the assembly in the sidebar and choosing **Show in Finder**.

Contig count is the number of separate pieces the assembler could not join. One is the ideal for a single circular replicon, meaning one separate DNA molecule such as a mitochondrion or a bacterial chromosome. Both reference runs returned one contig. A handful for a bacterial isolate usually means one chromosome plus its plasmids, which is a correct answer rather than a poor one. Dozens or hundreds from a long-read run means the problem lies in the reads rather than in the assembler, most often because they are too short or too few to span the genome's repeats.

N50 is a length. It is the contig length at which contigs of that length or longer account for half of all the bases you assembled, and you judge it against the size of the genome you were trying to assemble rather than against any universal threshold. [When to Assemble](01-when-to-assemble.md) works the arithmetic through on a real three-contig example. L50 is the companion count, the number of contigs it took to reach that same halfway point. A one-contig assembly makes both numbers trivial, since N50 equals the contig's length and L50 is 1, which is exactly what both reference runs report. On a fragmented assembly the pair is the first thing to read, since an N50 near the expected genome size means the assembly is mostly a few long pieces while an N50 far below it means the assembly is mostly small fragments.

The earlier Flye CLI reference run returned one contig of 16,359 bp at 43.9% GC, with N50 16,359 bp, L50 1, and a wall time of 35.2 seconds. Against the 16,569 bp reference that contig is 210 bp, or 1.3%, short. That shortfall is expected. The mitochondrial genome is circular, so an assembler writing it out as a straight line has to cut the circle somewhere. Where the two ends of the read pile meet, the same sequence appears twice, and the assembler trims one copy, which costs a small stretch at the junction. Flye's own `assembly_info.txt` marks this contig `circ. Y`, meaning Flye recognised the contig as circular. This manual offers no threshold at which a shortfall becomes a real problem, because no honest one exists across genomes. What you have instead is the comparison itself. A percent or two under a genome you know the size of reads as a trimmed junction, and a result far under it reads as a genome the assembler could not finish, which the next section takes up.

The hifiasm reference run returned one contig of 33,140 bp at 44.4% GC, with N50 33,140 bp, L50 1, and a wall time of 5.9 seconds. That length is almost exactly twice the reference, and 33,140 divided by 16,569 is 2.0002. The number looks good and is in fact wrong. It is an artifact, meaning a false result produced by the method rather than a real biological feature, and it is worth understanding because nothing in the viewport flags it. Hifiasm looks through its graph for a point at which to stop, and a small circular genome assembled entirely on its own gives it no such point, since that graph is a loop with no ends. Hifiasm therefore goes round the mitochondrial circle twice, stops there, and reports both passes as one contig. Note that the overlap graph, the assembly graph, the repeat graph, and the unitig graph named across this chapter are all one graph seen at different stages of the same process. A HiFi assembly of a whole nuclear genome does not behave this way, because the mitochondrion is then a small circle in a graph full of ordinary linear chromosomes.

Flye can produce the same doubling, and this is where the check matters most. The earlier comparison recorded four Flye runs on these identical reads. Three of them, plus the fixture's own committed output, returned the 16,359 bp contig described above. The fourth returned a 32,652 bp contig, doubled in the same way hifiasm's was, at 43.0% GC and marked circular with a multiplicity of 4. Multiplicity is Flye's estimate of how many times a sequence repeats in the genome, and a value of 4 on a genome with no such repeat is Flye reporting the doubling to a file the window does not show you.

The screenshot shows a later run stored as `Analyses/HG002-chrM-flye`, which also returned one 32,652 bp contig at 43.0% GC. Its native provenance records Flye 2.9.6 with four threads, and the result records a wall time of 46.6 seconds. Its N50 and longest contig are both 32,652 bp and L50 is 1. These measurements belong to the displayed run, not the earlier 16,359 bp example. The Inspector now links its original `HG002.chrM.ont.fastq.gz` input under Source Data. Only wall time is visible in the top strip in this Preview, so read the other metrics in the table and Assembly Context.

A small circular replicon is exactly the case where the assembler's choice of where to cut the loop is least constrained. If your own Flye run comes back at roughly twice the length you expected, review it for duplicated sequence before carrying it forward.

A repeat run through **Reassemble...** can return a different result, but a unit-length contig is not guaranteed. Timestamped run folders keep both results side by side so you can compare them, and any result still needs review rather than acceptance based on length alone. If you want to confirm the doubling rather than assume it, extract the contig into a reference bundle as [Extracting Contigs](04-extracting-contigs.md) describes, then map the same reads back to it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes. A doubled contig shows every read mapping to two places, so coverage across it reads at about half what it should, and the two halves carry the same sequence. Collapsing a doubled contig into one copy is not something LGE does, and it needs tools this manual does not cover, so rerunning is the practical fix. On hifiasm the doubling is not rare and rerunning will not clear it, which is why this chapter's HiFi result stays doubled. Assembling the mitochondrion together with the nuclear genome it came from is what avoids it there.

Hifiasm writes more files than the viewport lists. The run folder holds the primary contig graph LGE converted, `<project name>.bp.p_ctg.gfa`, and beside it the two haplotype-resolved graphs, `<project name>.bp.hap1.p_ctg.gfa` and `<project name>.bp.hap2.p_ctg.gfa`, one per parental copy. In those names `<project name>` is whatever you typed in the Project Name field, `bp` marks hifiasm's own graph-building stage, `p_ctg` means primary contigs, and `hap1` and `hap2` mean the first and second haplotype. Two further files ending `p_utg` and `r_utg` hold the [unitig](../../GLOSSARY.md#unitig) graphs, which are the unambiguous stretches from before hifiasm joined any of them into contigs, and nothing in this chapter needs them. Only the primary contigs reach the viewport, so the alternate haplotype stays on disk unlisted. Flye similarly keeps its assembly graph as `assembly_graph.gfa` in its run folder, alongside the per-stage working directories it built along the way.

## What good looks like

Check the total assembled length against the size you expected before you look at anything else. For the mitochondrial genome that is 16,569 bp, and the earlier Flye result of 16,359 bp sits 1.3% under it, which is the trimmed junction of a circular assembly described above. A length near twice what you expected, as the displayed Flye result of 32,652 bp and hifiasm's 33,140 bp are here, means the assembler walked a circular genome more than once, and the previous section gives the check and the remedy. A length far under what you expected means the assembler could not bridge something, most often a stretch where coverage dropped away.

Then check the contig count against the number of separate DNA molecules you believe the organism has. One for a mitochondrion, one for a bacterial chromosome plus one per plasmid, and roughly one per chromosome for a HiFi assembly of an organism with a small nuclear genome, such as a yeast, when the reads cover it deeply. This chapter's own fixture is the concrete case, and it gives one contig for one molecule. A count far higher than that is the signal that something upstream is wrong, and the three usual causes are reads that are too short to span the repeats, coverage too thin to establish overlaps, or a read set that is not really long-read data at all. The Detected row from step 1 is the check on that last one, since it names the class LGE read off the file.

Then read N50 beside the contig count rather than on its own. The two together tell you whether a fragmented assembly is fragmented evenly or is one good contig surrounded by small fragments. Only the second of those is usually usable.

Then check that the run produced contigs at all. An assembler can finish without an error and still write nothing, and LGE records that as its own outcome rather than as either success or failure. The viewport says so in place of the contig table, reading "Assembly completed, but no contigs were generated." That outcome almost always means too few reads or too little coverage rather than a broken tool.

Finally, remember what an assembly is not. A contig is a hypothesis about what the genome looks like, assembled from reads that carry their own errors, and the assembler never compared its result to a known genome. Both of the surprises in this chapter, the doubled Flye result and hifiasm's doubling, produced assemblies that looked healthy by every summary number the viewport reports. The check that catches them is knowing roughly how big the genome should be. When the answer matters, map the reads back to the assembly and look at whether coverage is even along it, which [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) covers. Uneven coverage means a sharp drop or a doubling along the contig rather than a level line, and the check is optional for this fixture, whose expected size already tells you what you need.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the sheet cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application, which you will find in the Applications folder under Utilities. The section assumes you have used a terminal before.

Both commands below are the ones the earlier reference runs in this chapter used. The displayed Flye run was a separate four-thread run whose exact command remains in its provenance. A backslash at the end of a line continues one command onto the next line.

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

Both commands print a summary block naming the contig count, total length, N50, largest contig, and GC content, and then the paths to the contigs FASTA, the graph, and the log. They also write `assembly-result.json` into the output directory, which holds the same statistics as machine-readable fields together with the exact command line that ran, the resolved assembler version, and the wall time, and is the file the viewport reads.

One difference between the two routes matters. `--output` on the command line writes exactly where you point it and creates no timestamped folder, so a second run against the same output directory overwrites the first. The sheet always creates `Analyses/flye-<timestamp>/` or `Analyses/hifiasm-<timestamp>/` for you and therefore never overwrites anything.

Both assemblers take exactly one input file. Passing two or more is refused before the run starts, on either route, though the wording differs between them. The command prints a refusal naming the tool, such as "Flye expects a single ONT sequence input in v1.", and the sheet refuses the same selection with a message naming the read class instead, reading "ONT reads assembly expects a single FASTQ input in v1." for Nanopore and "PacBio HiFi/CCS assembly expects a single FASTQ input in v1." for HiFi. One defect goes with the command's refusal. It exits with a success status even though it ran nothing, so a script cannot tell the refusal from a completed run by the exit code alone and must read the output or check for the result files.

If you have several long-read files from one sample, combine them into one file before you assemble. For gzipped FASTQ that is `cat a.fastq.gz b.fastq.gz > combined.fastq.gz`. LGE's window offers no operation that does this, so combining files is a step that needs the terminal.

## Next

Continue to [Extracting Contigs](04-extracting-contigs.md) to turn one of these contigs into a [reference bundle](../../GLOSSARY.md#reference-bundle), so you can map reads back to it, call variants against it, or use it as the target of a downstream workflow. The earlier 16,359 bp Flye example is close to the expected mitochondrial length. The displayed 32,652 bp Flye result and the doubled hifiasm result need review before either is carried forward.
