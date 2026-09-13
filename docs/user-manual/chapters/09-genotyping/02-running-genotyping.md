---
title: Running Amplicon MHC Genotyping
chapter_id: 09-genotyping/02-running-genotyping
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 03-reads/01-importing-fastq, 01-foundations/07-plugin-packs]
estimated_reading_min: 34
task: Genotype a plate of macaque MHC amplicon samples against an allele library and produce a genotype result bundle.
tags: [genotyping, mhc, amplicon, miseq, ont, macaque, savont]
tools: [minimap2, samtools, bbmerge, savont]
parameters_refs: [genotype.miseq-amplicon, genotype.full-length-ont]
entry_points:
  - "Tools > Genotyping > miSeq amplicon MHC genotyping..."
  - "Tools > Genotyping > Full-length ONT MHC genotyping..."
  - "CLI: lungfish-cli fastq genotype-cohort"
  - "CLI: lungfish-cli fastq genotype"
  - "CLI: lungfish-cli fastq full-length-ont-mhc-genotype"
shots:
  - id: genotyping-run-dialog
    caption: "The Workflow Operations dialog on miSeq amplicon MHC genotyping, showing the Reference group with its Project Reference menu, the FASTQ Bundles group, the Report group with Report Name, and the Run Parameters group with Threads and Min Reads above the read-only mode caption."
  - id: genotyping-analysis-mode
    caption: "The dialog's Haplotyping group with the Analysis Mode segmented picker on Genotype only, and the AI preset segment greyed out under the caption about configured API access."
  - id: genotyping-advanced-options
    caption: "The dialog's Advanced Options disclosure expanded on the miSeq workflow, showing the minimap2 arguments field and the Keep Intermediates checkbox above the Directory group."
  - id: genotyping-operations-row
    caption: "The Operations panel after the simulated two-sample MHC teaching batch completes, with its command, output files, log, and Completed status visible."
  - id: genotyping-full-length-dialog
    caption: "The Workflow Operations dialog on Full-length ONT MHC genotyping, showing the Length Filter group with Min Length and Max Length, the Call Thresholds group with its Locus % field, and the Advanced Options disclosure holding Orient Reference, Forward Primers, and Reverse Primers."
illustrations: []
glossary_refs: [adapter, allele, allele-target, amplicon, api-access, bam, bbmerge, bundle, cdna, clustering, cohort, consensus-sequence, fasta, fastq, genotype-result-bundle, haplotype, insert-size, ipd-mhc, locus, mhc, minimap2, miseq, nanopore-sequencing, operations-panel, paired-end, pbaa, plugin-pack, primer, provenance, read, read-merging, reference-bundle, retained-read, savont, wall-time]
features_refs: []
fixtures_refs: []
brand_reviewed: true
lead_approved: true
---

## What it is

A genotyping run takes the sequencing reads from one or more animals, one read bundle per animal, and reports which catalogued [MHC](../../GLOSSARY.md#mhc) [alleles](../../GLOSSARY.md#allele) each animal carries. The MHC is a dense cluster of immune-system genes, and an allele is one of the alternative sequences a gene can have. Lungfish Genome Explorer (LGE) does this by comparing every [read](../../GLOSSARY.md#read), meaning one fragment of DNA the sequencing instrument reported, against an allele library and counting which library entries the reads match. The allele library is a file of known allele sequences, usually handed to you by your laboratory or downloaded from a public catalogue, and it is not the sequencing library your bench protocol prepared. The output is a folder called a [genotype result bundle](../../GLOSSARY.md#genotype-result-bundle). A [bundle](../../GLOSSARY.md#bundle) is a folder LGE shows as one item, and this one holds the counts as a table, as an Excel workbook, and as the [BAM](../../GLOSSARY.md#bam) alignment file behind them.

LGE offers two genotyping operations, and which one you use is decided by your sequencing platform rather than by preference. The miSeq amplicon operation handles short [paired-end](../../GLOSSARY.md#paired-end) reads, meaning reads produced by sequencing each DNA fragment from both ends, which is what an Illumina [MiSeq](../../GLOSSARY.md#miseq) instrument produces. The full-length Oxford Nanopore Technologies operation, ONT for short, handles long reads from an Oxford [Nanopore](../../GLOSSARY.md#nanopore-sequencing) instrument that span an entire allele in one piece. It groups near-identical reads into [consensus sequences](../../GLOSSARY.md#consensus-sequence), meaning one cleaned-up sequence standing for a whole group, before it compares anything to the library. Both sit under **Tools > Genotyping**, and both write the same shape of result.

The most important word in the paragraph above is *matches*. A read is counted for an allele only when its alignment covers that library sequence from its first base to its last with no substitutions anywhere along it. A substitution is one position where the read carries a different base from the library sequence. The manual calls a read that passes this test a [retained read](../../GLOSSARY.md#retained-read). Reads that align partly, or align fully but differ by one base, are discarded rather than counted weakly, so the fraction of a run's reads that survive is small by design. On the Williams plate this chapter uses, 23.9 percent of the reads survived, and that is a healthy number rather than a poor one. LGE defines no threshold for that percentage, so read the section on what good looks like before you judge your own.

The work itself has three steps. Pick the operation that matches your instrument, point it at your reads and at an allele library, and run it. Everything else in this chapter is about reading the numbers the run gives back and knowing when they are telling you the sample failed.

## Why you would do this

Macaques are the standard animal model for vaccine and infectious-disease work, and which MHC alleles an animal carries changes how it responds. Two monkeys given the same vaccine can mount visibly different immune responses. The reason is that their MHC proteins present different fragments of the same antigen, meaning they display those fragments on the cell surface for immune cells to inspect. An experiment that does not know its animals' MHC genotypes cannot separate that source of variation from the effect it is trying to measure. Genotyping the colony, meaning the breeding group of animals a facility keeps, is therefore routine before a study starts rather than optional.

The assay itself is an [amplicon](../../GLOSSARY.md#amplicon) panel, meaning a set of PCR [primers](../../GLOSSARY.md#primer) that copy one short defined stretch of each gene many times over. A primer is a short piece of DNA that marks where copying starts, and copying the same stretch many times means the sequencer reads it at high depth, meaning many reads cover each base. Each [locus](../../GLOSSARY.md#locus), meaning the place on a chromosome where one gene sits, gets its own amplicon, and the reads arrive as a [FASTQ](../../GLOSSARY.md#fastq) file, the standard text format holding sequencing reads beside their quality scores. What the run reports back is one row per [allele target](../../GLOSSARY.md#allele-target), meaning one sequence in the allele library that reads matched. A run reports alleles rather than [haplotypes](../../GLOSSARY.md#haplotype). A haplotype is a set of alleles across several linked loci that are inherited together as one block. It is an interpretation layered on top of the calls rather than something the calls contain. [What Is MHC Genotyping](01-what-is-mhc-genotyping.md) covers both terms in full.

The example running through this chapter is a plate of 30 rhesus macaque samples sequenced on a MiSeq and genotyped against the rhesus [IPD-MHC](../../GLOSSARY.md#ipd-mhc) allele catalogue. That is the ordinary scale of the work. One plate, one library, one table at the end naming which alleles each animal carries.

## Before you start

You need a project open. A project is the folder LGE keeps a study's reads, references, and results in. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. A name written as Cmd-N is a keyboard shortcut, meaning hold the Command key and press N. A three-key name such as Cmd-Shift-B means hold Command and Shift together and press B. LGE runs on macOS, which is where these shortcuts and menu paths apply.

This chapter reports its numbers from the Williams MiSeq genotyping project, a real rhesus macaque plate belonging to this manual's author. That project does not ship with the manual, because the animal data behind it is not ours to publish, and there is no substitute dataset. Follow along with your own MiSeq amplicon run instead. The run needs two kinds of thing in the project. The first is one `.lungfishfastq` read bundle per animal. The second is a reference holding your allele library. One route is a `.lungfishref` bundle made when you import a FASTA, which [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) covers. The other is the dialog's own **Choose...** button, which reads a file from anywhere on disk.

Take the reads first. One read bundle holds one animal's reads, and that one-to-one rule is what lets the run keep the samples apart. Import them by following [Importing FASTQ Files](../03-reads/01-importing-fastq.md), and finish that import before you open the genotyping dialog. A bundle is a folder LGE treats as a single object, so it appears in the sidebar as one row rather than as a folder you open. The Williams project holds 30 such bundles under `Imports/`, one per sample, totalling 180 MB, with names of the form `WD1_S148_L001`. LGE treats that name as a label rather than parsing an animal identifier out of it.

Now the allele library, which the dialog calls the reference. It is a [FASTA](../../GLOSSARY.md#fasta) file, meaning a plain-text file listing each sequence under a name, holding one entry per known allele sequence. LGE also accepts it packaged as a `.lungfishref` [reference bundle](../../GLOSSARY.md#reference-bundle) or as a `.lungfishmhcref` bundle. A `.lungfishmhcref` differs from the other two in that it carries haplotype definitions alongside the sequences.

The Williams project uses `26128_ipd-mhc-mamu-2021-07-09.lungfishref`, a bundle of 970 rhesus allele sequences drawn from the IPD-MHC catalogue. That 970 is one release of that catalogue rather than every rhesus allele ever named, and a newer release holds more. Most of its sequences are 156 bases long, which is the length of the class I amplicon. Class I and class II are the two families of MHC genes, and DRB is one class II gene. A further 198 sequences are 244 bases long, which is the length of the DRB class II amplicon. That 244 matters because a single MiSeq read is too short to cover a 244-base amplicon end to end, which step 3 explains and handles. To see these figures for a library of your own, open its bundle the way [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) describes. In most laboratories the library already exists and is handed to you, so your first move is often to ask a colleague which file to use.

The miSeq operation needs the `read-mapping` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE downloads on demand into its own private storage. Mapping means working out where a read sits against a reference sequence. The full-length ONT operation needs that pack and the `full-length-mhc-genotyping` pack as well. Check both in **Tools > Plugin Manager...** (Cmd-Shift-B) before you start, because a missing pack stops the run rather than slowing it. Each pack in that window carries a status beside its name reading either Installed or an **Install** button, and clicking the button fetches it. Installing one needs a network connection, and LGE gives no size or duration estimate before you start.

One last difference between the two operations is worth knowing before you go looking in the menu. The miSeq operation is switched on out of the box. The full-length ONT operation is a specialized workflow that stays off until you enable it, and until then the Tools menu shows it greyed out with the words "(not enabled)" after its name. There are two routes to the switch that turns it on. Choosing the greyed item raises a message window whose **Open Workflow Library** button takes you to the card. Or go straight there with **Tools > Workflow Library...**, find the **Full-length ONT MHC genotyping** card in the **Genotyping** group, and turn its **Enabled** switch on.

## Procedure

Steps 1 through 5 cover the miSeq amplicon workflow on the Williams plate. Step 6 covers what changes for the full-length ONT workflow, and step 7 is shared by both.

### 1. Select the samples you want to genotype

Click the read bundles you want in the project sidebar. Cmd-click adds one more row to the selection, and Shift-click extends the selection to cover a range of rows. Selecting several at once is the usual case, because a genotyping plate is normally read as one cohort. A [cohort](../../GLOSSARY.md#cohort) is a set of samples genotyped and compared together, which is what produces a single table with one column per animal instead of 30 separate reports.

Selecting more than one bundle locks the dialog's run picker to a single combined batch, and the picker says so in a caption reading "Selections run as one genotyping batch producing a merged report. Run bundles individually for separate per-sample reports." That caption means one report file rather than pooled reads. Pooling would mean tipping every sample's reads into one heap and losing track of which animal each came from, and that never happens. Every sample keeps its own read counts and its own column throughout.

### 2. Open the dialog and set the reference

Choose **Tools > Genotyping > miSeq amplicon MHC genotyping...**. The Workflow Operations dialog opens with that workflow already selected. This is LGE's standard window for setting up and starting an operation, and it holds a workflow selector at the top that you should leave as you found it.

Set the reference first, in the group headed **Reference** at the top of the dialog. That group and its **Project Reference** menu are the same on both genotyping routes. If LGE found any reference bundles inside your project it lists them in that menu, and picking your allele library from the menu is all this step needs. The Williams run picked `26128_ipd-mhc-mamu-2021-07-09.lungfishref`. The menu lists only what is inside the project, so a FASTA sitting elsewhere on your disk never appears in it, and an empty menu means the project holds no reference yet. Use the **Choose...** button beside the menu in either case, which accepts a plain allele FASTA, a `.lungfishref` bundle, or a `.lungfishmhcref` bundle from anywhere.

Check that the **FASTQ Bundles** group lists the samples you selected in step 1. Below it sits **Report Name**, which arrives filled in as `amplicon-genotyping` and names both the result bundle and the Excel workbook inside it.

<!-- SHOT: genotyping-run-dialog -->

### 3. Read the mode caption and leave the merge alone

Under **Threads** and **Min Reads** in the **Run Parameters** group sits a line of small grey text. On this plate it reads **Illumina sample bundles**, and on a Nanopore plate it reads **ONT sample bundles** instead. That caption only reports what LGE decided and cannot be changed from this window, and there is no mode picker anywhere in the dialog. LGE works the mode out by inspecting the reads themselves, choosing the Illumina path when the bundles carry Illumina metadata and the Nanopore path otherwise. Read the caption to confirm LGE reached the same conclusion you would have. If it names the wrong platform, the metadata inside the bundles is wrong, so reimport those reads following [Importing FASTQ Files](../03-reads/01-importing-fastq.md), since only the command line can force the choice.

One step happens automatically here and is worth understanding, because without it a whole class of results goes quietly wrong. Before mapping anything, LGE joins the two halves of each read pair into one longer fragment wherever they overlap, using [bbmerge](../../GLOSSARY.md#bbmerge). This is [read merging](../../GLOSSARY.md#read-merging), and the word merging here means joining two reads, not the merged report of step 1.

The reason merging is necessary is arithmetic, and it is worth following slowly. An Illumina run reads each DNA fragment from both ends, and each of those two reads is called a mate. The stretch of DNA between them, the fragment the pair came from, is the [insert](../../GLOSSARY.md#insert-size). Chemistry is the kit that decides how many bases the instrument reads per mate, and a 2x251 kit reads up to 251 bases from each end. Once the primer and adapter sequence at the ends is removed, one mate typically covers only about 198 bases of the insert. That is comfortably more than a 156-base class I amplicon, so one mate spans it alone. It is less than a 244-base DRB amplicon, so no single mate can span one of those from its first base to its last.

Without merging, then, every DRB allele in the library would receive exactly zero reads while every shorter locus genotyped normally. The failure would be silent, because a locus with no reads simply has no rows, and the way you catch it is the DRB check in the What good looks like section below. LGE reports the merge in the Operations panel as it happens. On the three-sample reproduction described later in this chapter the message read "3 of 3 Illumina inputs contain unmerged read pairs. Merging overlapping pairs before mapping so full-length amplicons (including the 244 bp DRB loci) can be genotyped. Import with the Illumina Amplicon Merge recipe to do this at import time instead."

### 4. Leave Analysis Mode on Genotype only

Below the Run Parameters group sits a group headed **Haplotyping** holding an **Analysis Mode** picker with three segments, **AI preset**, **Deterministic**, and **Genotype only**. Leave it on **Genotype only**, which maps the reads, reports which alleles each sample carries, and stops there. That is the whole of genotyping and the whole of this chapter. The other two segments add a haplotype interpretation on top of the allele calls. The **AI preset** segment is greyed out unless [API access](../../GLOSSARY.md#api-access) has been configured for your copy of LGE, meaning a stored key for an outside AI provider, with a caption underneath saying so. Nothing in this chapter needs it, so a greyed segment is not a problem to solve.

<!-- SHOT: genotyping-analysis-mode -->

Everything else in the dialog already holds the value the worked example used, so the defaults are ready and you can continue to step 5. **Threads** arrives pre-filled with your machine's processor count, which is the right number and needs no lookup. **Min Reads** starts at 1. The **Advanced Options** disclosure holds a minimap2 arguments field and a Keep Intermediates checkbox, neither of which you have reason to change on a first run. The **Directory** group at the bottom already points inside your project. Read the Settings section afterwards rather than before.

<!-- SHOT: genotyping-advanced-options -->

### 5. Run it and watch the Operations panel

Click **Run**. A row appears in the [Operations panel](../../GLOSSARY.md#operations-panel), which does not open on its own, so open it with **Operations > Show Operations Panel** (Cmd-Shift-P). The row's message changes as the run moves through its stages. Those stages are validating the inputs, resolving the reference and the managed tools, merging the read pairs, and mapping with [minimap2](../../GLOSSARY.md#minimap2). Then it filters the alignments down to the retained reads, writes the summaries, and writes the Excel workbook.

<!-- SHOT: genotyping-operations-row -->

Runtime depends on the plate and the machine, and both figures below are from the author's Apple Silicon Mac. The Williams project's own 30-sample run took 329 seconds of [wall time](../../GLOSSARY.md#wall-time), meaning real elapsed time, which is about five and a half minutes. A three-sample reproduction of it took 55 seconds, or a little under a minute. Mapping and merging take nearly all of that.

### 6. What changes on the full-length ONT route

Choose **Tools > Genotyping > Full-length ONT MHC genotyping...** instead when your reads are long Nanopore reads that each span a whole allele. The reference, FASTQ Bundles, Report Name, Threads, and Directory groups work exactly as described above. Three things differ.

The first is that reads are clustered before anything is compared to the library. [Clustering](../../GLOSSARY.md#clustering) groups near-identical reads and derives one cleaned-up consensus sequence from each group, and those consensus sequences rather than the raw reads are what get genotyped. The reason is that Nanopore reads carry a much higher per-base error rate than Illumina reads, so a single true allele matched read by read would scatter into many near-misses and match nothing exactly. LGE always clusters with [savONT](../../GLOSSARY.md#savont) on this route, which the `full-length-mhc-genotyping` pack supplies at version 0.6.3. That version number is informational, and a copy at a different version needs no action from you. There is no clustering choice in the dialog. [pbAA](../../GLOSSARY.md#pbaa), a different read-clustering program that builds consensus sequences the same way, is a separate operation whose saved output this workflow can reuse rather than a second option inside this one.

The second is a **Length Filter** group holding **Min Length** and **Max Length**. Together they decide which reads are long enough and short enough to be a whole amplicon rather than a fragment or two amplicons joined end to end. They start at 2000 and 4000 bases, which suits a typical full-length MHC amplicon of roughly 3,000 bases. Your own amplicon's length comes from the protocol that designed its primers.

<!-- SHOT: genotyping-full-length-dialog -->

The third is that the **Advanced Options** disclosure on this route holds three file pickers instead of the miSeq route's minimap2 field, for an orientation reference and for forward and reverse primer sequences. All three are optional. LGE fills each one automatically when it finds a file in your project whose name and contents suit that role, so an empty field means it found no match rather than that anything is wrong.

### 7. Find the result

When the Operations panel row turns green, the run succeeded and the result appears in the sidebar. A failed run turns the row red instead and leaves no bundle behind. A miSeq run writes its bundle to a fixed folder at `Analyses/Amplicon genotyping results/`, and a full-length ONT run writes to `Analyses/Full-length ONT MHC genotyping results/`. These are named category folders rather than the timestamped per-run folders most other tools use. A second run with the same report name therefore lands beside the first as `amplicon-genotyping_1` rather than overwriting it, and the higher the suffix the later the run. The Williams project holds several such runs side by side.

Double-click the `.lungfishgenotype` bundle to open the genotype viewport, which [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) covers in full.

## Settings

Both dialogs share several controls, and each control below is documented once with a note saying which of the two workflows shows it. Each entry names the control, says what it does, gives its default, says when to change it, and ends with the command-line flag that does the same job. Those closing sentences are for readers who script their runs, and a reader staying in the window can pass over them. A separate subheading at the end of this section holds the options the window does not show at all.

**Project Reference.** Names the allele library every read is compared against, as a pop-up menu listing the reference bundles LGE found inside the project, on both workflows. It is the most important choice in the run, because an allele missing from this file can never be reported for any sample. It arrives set to the first MHC reference found in the project, or to nothing when the project holds none. The **Choose...** button beside it takes an allele FASTA, a `.lungfishref` bundle, or a `.lungfishmhcref` bundle from anywhere on disk. Choose the library built for your species and amplicon panel, because a macaque panel will not name human alleles. On the ONT route choose a full-length library, since a short-amplicon panel will not match reads that span a whole gene. On the command line this is `--reference`.

**Reference.** Is the same control under the same group heading on the full-length ONT workflow, where it names the library of full-length allele sequences the clustered consensus sequences are compared against. It arrives set to the first MHC reference found in the project, or to nothing when the project holds none, and it accepts the same three kinds of file. Choose a full-length allele library here rather than a short-amplicon panel. On the command line this is `--reference`.

**FASTQ Bundles.** Chooses which sequenced samples the run genotypes, and it appears on both workflows. It arrives holding whatever you selected in the sidebar before opening the dialog, and it accepts prepared per-sample `.lungfishfastq` bundles, loose FASTQ files, or a folder of either. Select the whole plate when you want one comparison table, and run bundles one at a time when you want separate per-sample reports. On the miSeq route every selected bundle runs as one batch and lands in a single merged report. On the full-length route LGE schedules the samples itself, largest first with several running at once, which needs no action from you. This setting has no command-line flag, because the command line takes the inputs as bare arguments after the subcommand name.

**Include subfolders.** Adds bundles nested inside further folders to the batch when the thing you selected was a folder, and it sits in the **FASTQ Bundles** group on both workflows. It is off by default, so a selected folder contributes only the bundles sitting directly inside it. Turn it on when a sequencing run wrote each sample into its own subfolder. This setting has no command-line flag.

**Report Name.** Names the result bundle and the Excel workbook the run writes, and it appears on both workflows. On the miSeq route it is always `amplicon-genotyping` and does not change with the read files you picked. On the full-length route a single input gives it a name built from that file's own name, while several inputs give it the fixed name `full-length-ont-mhc-genotyping`. Change it when the suggested name will not tell you later which plate or cohort the run covered, since successive runs with the same name land beside each other as `amplicon-genotyping_1` and so on rather than overwriting. On the command line this is `--output-name`.

**Threads.** Sets how many worker threads the run may use, and it appears on both workflows. It arrives pre-filled with your machine's active processor count, which is the right answer whenever nothing else needs the machine, and it needs no change on either route. Lower it when you need to keep cores free for other work while a long run proceeds. On the miSeq route it governs the mapping step, and on the full-length route it is shared across the clustering and mapping steps. On the command line this is `--threads`.

**Min Reads.** Sets the fewest reads that must support an allele before that allele is treated as a call, on the miSeq workflow. In Preview 2026.9.13 it has no effect on a Genotype only run, which is the mode this chapter uses. It removes no rows from the report, and the What good looks like section explains what to do instead. It starts at 1. A read counts towards an allele only when it matched that allele across its whole length with no mismatches. That test is strict enough that a single supporting read is meaningful rather than noise. Raise it on deeply sequenced libraries once the defect above is fixed, to cut the tail of one-read and two-read hits. On the command line this is `--min-support`.

**Analysis Mode.** Decides how far the run goes, as a segmented picker with three settings, **AI preset**, **Deterministic**, and **Genotype only**, on the miSeq workflow. It starts on Genotype only, or on AI preset when AI provider access has been configured. Genotype only maps the reads and reports which alleles each sample carries. The other two add a haplotype interpretation on top of that. Leave it on Genotype only for genotyping work, which is what this chapter covers. This setting has no command-line flag.

**minimap2 arguments.** Passes extra arguments to minimap2, the program that lines each read up against the allele library, after LGE's own fixed mapping preset, on the miSeq workflow. It starts empty, which is what the worked example used, and it lives inside the **Advanced Options** disclosure. This field is for expert use and can be left empty, so change it only when you have a specific argument from [the minimap2 documentation](https://lh3.github.io/minimap2/minimap2.html) to try. On the command line this is `--extra-args`.

**Min Length.** Sets the shortest read, in bases, kept for clustering after primers are trimmed, on the full-length ONT workflow. It starts at 2000, and reads shorter than the threshold are usually fragments rather than whole amplicons. Set it just below your amplicon's true length so truncated reads do not form clusters of their own. On the command line this is `--min-length`.

**Max Length.** Sets the longest read, in bases, kept for clustering after primers are trimmed, on the full-length ONT workflow. It starts at 4000, and reads longer than the threshold are usually two amplicons joined end to end. Raise it when your amplicon is longer than 4000 bases, and lower it when joined reads are producing spurious clusters. On the command line this is `--max-length`.

**Keep Intermediates.** Keeps the large working files a run produces on its way to the report, instead of deleting them at the end, and it appears inside the **Advanced Options** disclosure on both workflows. It is off by default, which is what the dialog's own caption recommends for normal runs, because the merged FASTQ files and unfiltered alignments are large and can be regenerated by rerunning. Turn it on only when a run gave an unexpected result and you want to inspect the files behind it. On the command line this is `--keep-intermediates`.

**Orient Reference.** Supplies a sequence used to turn every read the same way round before clustering, on the full-length ONT workflow. Nanopore reads arrive on either strand of the DNA, so without this step clusters would split by strand rather than by allele. It arrives filled in with an orientation FASTA if LGE found one in your project, and empty otherwise, and it lives inside **Advanced Options**. Supply one when your reads were not oriented before import and clusters are splitting by strand. On the command line this is `--orient-reference`.

**Forward Primers.** Names the primer sequences trimmed from the start of each read, on the full-length ONT workflow, so that primer bases are not mistaken for sequence differences between alleles. It arrives filled in with a forward-primer FASTA if LGE found one in your project, and empty otherwise, and it lives inside **Advanced Options**. Supply it when your reads still carry the PCR primers used to make the amplicon. On the command line this is `--forward-primer`.

**Reverse Primers.** Names the primer sequences trimmed from the end of each read, on the full-length ONT workflow, and is the partner of the setting above. It arrives filled in with a reverse-primer FASTA if LGE found one in your project, and empty otherwise, and it lives inside **Advanced Options**. Supply it when your reads still carry the PCR primers used to make the amplicon. On the command line this is `--reverse-primer`.

**Directory.** Chooses where the `.lungfishgenotype` result bundle is written, and it appears on both workflows. It points at the project's own results folder for that workflow, which is `Amplicon genotyping results` for the miSeq route and `Full-length ONT MHC genotyping results` for the full-length route, both inside `Analyses/`. Change it only when the result belongs outside the project folder. On the command line this is `--output-dir`.

### Options that exist only on the command line

Everything below is for readers who script their runs, so skip to Reading the results if you work in the LGE window. Nothing above depends on any of these, and no result in this chapter needs one.

**`--mode`.** Forces the input layout instead of letting the run work it out from the reads, on the miSeq operation, accepting `auto`, `ont-sample-bundles`, `illumina-paired`, or the deprecated `ont-barcode-demux`. It defaults to `auto` for `fastq genotype` and to `illumina-paired` for `fastq genotype-cohort`. Set it when automatic detection reaches the wrong answer, which is the only way to override the caption described in step 3.

**`--read-type`.** Forces the sequencing platform to `ont` or `illumina` instead of reading it from the input bundles, on the miSeq operation. It defaults to `auto` for `fastq genotype` and to `illumina` for `fastq genotype-cohort`. Set it alongside `--mode` when you are overriding detection.

**`--preset`.** Locks the run to a bundled panel, on the miSeq operation, and the only supported value is `mcm-mhc-miseq`, where MCM stands for Mauritian cynomolgus macaque. There is no default, so a run without it uses whatever `--reference` names. Use it for the established Mauritian cynomolgus macaque panel, whose reference and haplotype definitions travel inside the preset, which is why passing `--reference` alongside it stops the run with an error telling you to leave that flag out.

**`--analysis-name`.** Labels this analysis inside the Excel workbook separately from the output file name, on the miSeq operation. It defaults to the value of `--output-name`, which is also what the dialog does, since the dialog's Report Name fills both. Set it when the workbook needs a human label that differs from the file name.



**`--sort-threads`.** Sets how many threads samtools uses to sort the alignments before filtering, on the miSeq operation. It defaults to 4, which the Williams run used. Raise it only on a machine with cores to spare and a very large plate.

**`--barcodes`.** Supplies sample identifiers and barcode sequences for the deprecated ONT barcode-demux mode, on the miSeq operation. There is no default. Use it only with legacy barcode-split inputs, since preparing one bundle per sample first is the supported route.

**`--demux-manifest`.** Supplies recorded input and per-sample read counts for the deprecated ONT barcode-demux mode, on the miSeq operation. There is no default. It has the same legacy scope as `--barcodes`.

**`--project`.** Names a project directory into which an outside reference FASTA is imported before mapping, on the miSeq operation, and names a project root recorded in the run's provenance on the full-length operation. There is no default. Pass it when you want a headless run recorded against a project the way an in-window run would be.

**`--sample-jobs`.** Caps how many samples are worked on at the same time, on the full-length ONT operation. It defaults to an automatic sample-level strategy that LGE picks from the machine and the batch. Lower it when concurrent samples are exhausting memory.

**`--savont-threads-per-sample`.** Sets how many threads savONT gets for each sample being processed concurrently, on the full-length ONT operation. It defaults to an automatic batch-aware value. Set it alongside `--sample-jobs` when you are tuning a large cohort by hand.

**`--savont-quality-value-cutoff`.** Sets the lowest estimated read accuracy, as a percent, kept for clustering, on the full-length ONT operation. It defaults to 90, which is roughly the Q10 mark on the quality scale your sequencer's own run summary reports. Lower it to keep more of a poor run's reads at the cost of noisier consensus sequences.

**`--savont-min-cluster-size`.** Sets the fewest reads a cluster must hold before its consensus sequence is kept, on the full-length ONT operation. It defaults to 3. Raise it on deeply sequenced samples where small clusters are producing spurious calls.

**`--min-unmatched-reads`.** Sets the fewest reads a cluster must hold before it is written to the unmatched FASTA for later inspection, on the full-length ONT operation. It defaults to 5. Lower it to 1 when you want to see every cluster that matched nothing in the library.

**`--cdna-threshold`.** Sets the length below which an allele in the reference is treated as a [cDNA](../../GLOSSARY.md#cdna) sequence rather than a whole genomic one, on the full-length ONT operation. A cDNA is a DNA copy of a gene's messenger RNA, and so is shorter than the genomic version of the same allele. It defaults to 2000 bases. Change it when your library mixes genomic and cDNA records at unusual lengths.

**`--reuse-compatible-checkpoints`.** Picks up compatible per-sample checkpoints from an earlier run instead of redoing that work, on the full-length ONT operation. It is off by default, so every run starts clean. Turn it on when you are rerunning a large cohort after a failure partway through.

## Reading the results

The genotype viewport is the subject of the next chapter. What this section covers is the numbers the run itself reports, which tell you whether the run worked before you look at a single allele call. They live in the result bundle's statistics file and in the workbook's Run Stats sheet, and you reach both by opening the bundle in the Finder, since the window offers no separate viewer for them.

Two runs are quoted throughout this section, and they are different runs rather than a disagreement. One is the whole Williams plate of 30 samples. The other is the author's three-bundle reproduction of it, run against the same library from three of the same samples.

The number to read first is the retained fraction. It is the share of the input reads that survived the end-to-end, zero-mismatch test. On the whole plate it was 23.9 percent of 2,854,092 input reads, or 682,927 retained reads. The three-bundle reproduction gave 23.6 percent of 505,528 reads, or 119,146 retained. Those two figures agreeing within a third of a percent on different subsets of the same plate is what a stable assay looks like. A gap of several percent between runs of the same assay is the point at which to go looking for a cause.

The run also reports why the other reads were dropped, as four counts, and these count alignments rather than reads. An alignment is one record of a read placed against one allele target, so a read that landed on several targets contributes several alignments. That is why the whole-plate figure below reads 682,928 alignments passed against 682,927 retained reads. On the whole plate 224,134 alignments were unmapped, meaning minimap2 found no position for them anywhere in the library. Another 311,914 mapped but did not span their allele target from end to end. Another 296,843 spanned it but carried at least one mismatch. Reading those four together tells you which part of the assay is losing reads. A large unmapped count points at off-target amplification, meaning PCR copied something other than the intended gene, or at the wrong library. A large not-spanned count points at reads that are too short, which on a MiSeq plate usually means merging did not happen.

Per-sample counts are where a plate's real story sits, because the whole-plate figure hides everything. LGE labels each sample from its own read counts, showing OK for a sample that retained 1,000 reads or more and Low Support for one below that line. On the whole Williams plate 23 samples were labelled OK and 7 Low Support. Retained reads ranged from 2 to 58,370 across all 30, and the retained percentage from 0.6 percent to 26.8 percent. The OK samples ran from 1,976 to 58,370 retained reads and the Low Support samples from 2 to 713. Those two populations are visible at a glance in the samples summary, which is the reason to look at the per-sample table before the allele table.

The number of allele rows per sample follows the read count and is the quickest sanity check on a working sample. A sample yields dozens of rows rather than one or two because the library holds many closely related alleles, and one animal's reads match every catalogued sequence they cover exactly. On the whole plate individual samples produced between 2 and 117 allele rows each, with a median of 80 across the 30, and the thin end of that range belongs to the Low Support samples. The plate as a whole produced 2,109 rows. The three-bundle reproduction produced 104 rows for the sample `WD1_S148_L001`, which is exactly the number the whole-plate run produced for the same sample against the same library. Rerunning the same input and getting the same output every time is what determinism means here.

Two further facts about the output are worth knowing before the next chapter. The Excel workbook holds four sheets, the main genotype table, a Long Summary with one row per sample and allele, a Sample Summary with one row per sample, and a Run Stats sheet carrying the figures described above. And the run keeps the alignment evidence, writing a sorted and indexed [BAM](../../GLOSSARY.md#bam) of just the retained reads into the bundle. A BAM is the compressed file format holding one row per aligned read, sorted by position and indexed so any region can be reached quickly. The next chapter reads it to trace any call in the table back to the reads that produced it.

## What good looks like

Read the retained fraction first, and read it against your own assay rather than against a fixed number. Roughly a quarter of reads surviving is normal for this panel, because the filter is deliberately strict and because a MiSeq plate carries adapter dimers and off-target product that were never going to match an allele. An [adapter](../../GLOSSARY.md#adapter) dimer is two adapter sequences stuck together with no sample DNA between them, and off-target product is amplified DNA from somewhere other than the intended gene. On a first run you have nothing of your own to compare against, so take the Williams plate's 23.9 percent as orientation and compare your later runs against your own first one. What matters over time is that the figure is stable between runs of the same assay. A plate that suddenly retains 5 percent where the last one retained 24 has a laboratory problem or a library mismatch, and the four drop counts described above will say which.

Then read the per-sample table and use the app's own labels. A sample marked OK has retained enough reads for its empty cells to carry meaning. A sample marked Low Support retained fewer than 1,000 and the honest response is to rerun it in the laboratory rather than to interpret the handful of rows it produced. The Williams plate had 7 Low Support samples out of 30, the weakest carrying 2 retained reads and the strongest 713. LGE defines no scale finer than that one label, and this manual invents none, so the Williams ranges above are the only orientation on offer. Judge each sample against the rest of your own plate as well.

Then check that class II loci are present. Open the workbook's Long Summary sheet, which lists one row per sample and allele, and scan the allele names for DRB rows. Allele names follow the library's own scheme, so a class I row reads like `01_Mamu-A1_001_05_01_01` and a class II row like `07_Mamu-DRB1_03_03_01_01`. If a plate has produced class I calls in quantity with no DRB rows at all, the merge described in step 3 did not happen. That is the specific failure the merge exists to prevent, and its signature is a complete absence rather than a low count. If you find it, reimport the reads with the Illumina Amplicon Merge recipe the Operations message names and run the genotyping again. The reproduction run for this chapter reported 3,598 retained reads on a single DRB allele, and one solid DRB row is enough to show the merge worked, since the absence the check looks for is total.

One caution about **Min Reads** belongs here as well as in Settings, because it changes what the checks above are worth. In Preview 2026.9.13, which the **Lungfish Genome Explorer > About Lungfish Genome Explorer** window names for your own copy, raising Min Reads on a Genotype only run does not remove low-support rows from the report. It affects that mode alone, because the value reaches a real filter only when a haplotype definition is in play. Setting it to 50 on the reproduction run left all 293 rows in the CSV and all 293 in the workbook, including rows supported by a single read. The value was recorded in the run statistics without being applied. Until that is fixed, read the Long Summary sheet's own read-count column and set aside the rows you consider too thin, since LGE offers no number to compare against.

Finally, open the bundle's [provenance](../../GLOSSARY.md#provenance) record, which is the file named `.lungfish-provenance.json` that LGE writes beside every result describing exactly how it was made. It is plain text, so any text editor opens it. The Williams run's record names the app version, the host operating system, the complete command with all 30 inputs, and the checksum of every input and output file. It also lists each of its 67 tool invocations with a note of whether that step succeeded and how long it took. That record is what lets a genotype be defended or reproduced a year later, and it is written whether you ran from the window or from the command line.

## Haplotype analysis

The run dialog's haplotype definition choice is not documented in this release.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the dialog cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application. If you have never opened a terminal, the [CLI Reference](../appendices/cli-reference.md) explains how to start one and how to run `lungfish-cli` from it. The reason to work this way is to repeat a run unattended, or to run one on a shared server that has no screen.

Three subcommands cover the two operations. `fastq genotype-cohort` genotypes several prepared per-sample bundles together and is the command the miSeq dialog runs for a multi-sample selection. `fastq genotype` is the same operation with looser input rules, taking files, folders, or bundles, and defaulting `--mode` and `--read-type` to `auto` instead of to the Illumina values. `fastq full-length-ont-mhc-genotype` is the full-length ONT operation.

The command below is the Williams plate's own run, shortened to three of its 30 inputs. Pass `--output-dir` a path ending in `.lungfishgenotype`, because that directory is the result bundle itself rather than a folder to put one in. The backslash at the end of each line tells the terminal that one command continues onto the next line, so type them as written.

```bash
# Genotype three prepared per-sample bundles against a rhesus MHC allele library
lungfish-cli fastq genotype-cohort \
  Imports/WD1_S148_L001.lungfishfastq \
  Imports/WD2_S149_L001.lungfishfastq \
  Imports/WD5_S152_L001.lungfishfastq \
  --mode illumina-paired --read-type illumina \
  --reference 26128_ipd-mhc-mamu-2021-07-09.lungfishref \
  --output-dir results/three-sample.lungfishgenotype \
  --output-name three-sample \
  --threads 8 --min-support 1
```

That is the three-bundle reproduction quoted throughout this chapter. It took 55 seconds on the author's machine and wrote a bundle holding the same files the dialog produces, plus a provenance record for the run and for each file in it. The stem of every name below is the value of `--output-name`.

| File | What it holds |
|---|---|
| `three-sample.retained-demux-genotypes.csv` | One row per sample and allele, with the read count supporting it |
| `three-sample.retained-demux-samples.csv` | One row per sample, with its retained read count and percentage |
| `three-sample.retained-demux-stats.json` | The four drop counts and the retained totals for the whole run |
| `three-sample.xlsx` | The four-sheet workbook |
| `three-sample.retained.demuxed.bam` | The retained reads, sorted, with a `.bai` index beside it |

The bundle also holds copies of the three CSV files whose names use underscores in place of the hyphens above, so a file such as `three-sample.retained_demux_genotypes.csv` is the same table under a second name rather than a different result.

One difference between the two miSeq subcommands is worth stating plainly, because it decides which you should reach for. `fastq genotype-cohort` needs at least two `.lungfishfastq` bundles, each holding one prepared per-sample FASTQ. A single bundle stops it with the message "At least two input FASTQ bundles are required for genotype-cohort." `fastq genotype` sets no minimum and accepts loose FASTQ files and folders as well. Use the cohort form when your samples are already imported as bundles, which is the usual case inside a project, and the plain form for a single sample or for files that are not yet bundles.

The full-length ONT route runs the same way with its own flag set.

```bash
# Cluster long ONT reads with savONT and genotype the cluster consensus sequences
lungfish-cli fastq full-length-ont-mhc-genotype \
  Imports/sample.lungfishfastq \
  --reference mhc-full-length.lungfishref \
  --output-dir results/sample.lungfishgenotype \
  --output-name sample \
  --min-length 2000 --max-length 4000 \
  --threads 8
```

Two things about running these commands from a script are worth knowing. The first is where to put the output. Write the output bundle somewhere inside your project or your home folder. A path spelled `/private/tmp/...` fails near the end of the run, after all the work is done, with a message about the reviewable-row catalog being outside the result bundle. The cause is that LGE compares the two paths in different spellings and concludes wrongly that they do not match. The same folder reached as `/tmp/...` works, so the spelling rather than the location is what trips it. The second is that `--min-support` behaves on the command line exactly as **Min Reads** does in the window, which is to say it is recorded but does not filter a Genotype only run's report.

## Next

Continue to [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) to open the bundle you just produced, or go back to [What Is MHC Genotyping](01-what-is-mhc-genotyping.md) for the biology behind the allele calls.
