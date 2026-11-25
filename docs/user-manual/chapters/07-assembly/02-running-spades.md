---
title: Short-Read Assembly (SPAdes, MEGAHIT, SKESA)
chapter_id: 07-assembly/02-running-spades
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 07-assembly/01-when-to-assemble]
estimated_reading_min: 18
task: Assemble Illumina paired-end reads with SPAdes, MEGAHIT, or SKESA and read the contigs the run produces.
tags: [assembly, spades, megahit, skesa, illumina, de-novo, contigs, n50]
tools: [spades, megahit, skesa]
parameters_refs: [assemble.spades, assemble.megahit, assemble.skesa]
entry_points:
  - "Tools > Assembly > SPAdes…"
  - "Tools > Assembly > MEGAHIT…"
  - "Tools > Assembly > SKESA…"
  - "Sidebar context menu on an assembly reference bundle: Reassemble…"
  - "CLI: lungfish-cli assemble"
shots:
  - id: assembly-wizard-spades
    caption: "The assembly dialog opened from Tools > Assembly > SPAdes…, showing the read-only Dataset, Read Layout, and Detected rows, with Read Layout reading Interleaved paired-end Illumina reads (pairs verified against the records at run time), and under Primary settings the Assembler picker, the locked Read Type row, the Isolate profile, and the Threads slider with its number field."
  - id: assembly-advanced-settings
    caption: "The Advanced settings section with the Curated extra arguments disclosure open, showing the Careful mode toggle disabled for the Isolate profile with its caption and the Skip error correction toggle above the Extra arguments field."
  - id: assembly-viewport
    caption: "The assembly viewport after the HG002 mitochondrial run, with the summary strip above the contig table and the Inspector's Bundle tab showing the Assembly Context block with 1 contig, 16697 total assembled bp, and an N50 of 16697 bp."
  - id: assembly-bundle-in-analyses
    caption: "The HG002-chrM assembly result selected as one row under Analyses in the sidebar, with its contig table open and the whole-assembly metrics in the Inspector's Assembly Context block."
  - id: contig-detail-pane
    caption: "The detail pane for the longest contig, showing its header, length, GC percent, rank, share of the assembly, and sequence."
illustrations: []
glossary_refs: [hg002, amplicon, assembly-bundle, assembly-graph, bundle, checksum, conda, contig, coverage, de-bruijn-graph, de-novo-assembly, error-correction, fastq, gc-content, interleaved-fastq, k-mer, l50, mitochondrial-genome, n50, operations-panel, paired-end, plugin-pack, read, reference-bundle, scaffold, blast, inspector, thread]
features_refs: [assemble, viewport.assembly]
fixtures_refs: [human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

SPAdes, short for St. Petersburg genome assembler, takes short sequencing [reads](../../GLOSSARY.md#read) and rebuilds the longer stretches of DNA they came from, using only the reads. A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads. Building contigs with no reference genome is [de novo assembly](../../GLOSSARY.md#de-novo-assembly), and [When to Assemble](01-when-to-assemble.md) covers when you want it.

SPAdes cuts every read into [k-mers](../../GLOSSARY.md#k-mer), overlapping words of exactly k bases, and joins k-mers that overlap by all but one base into a [de Bruijn graph](../../GLOSSARY.md#de-bruijn-graph), a network in which each unbranched path becomes a contig. [Two ways to put reads together](01-when-to-assemble.md#two-ways-to-put-reads-together) walks through a small example. Sequencing errors and repeats make the paths branch, and SPAdes prunes the weakly supported branches. It repeats this at several k values and merges the answers, and you never choose k yourself. On the fixture it used 21, 33, 55, 77, 99, and 127.

Lungfish Genome Explorer (LGE) runs SPAdes from an assembly sheet under **Tools > Assembly > SPAdes…**. The same sheet runs MEGAHIT and SKESA, the other two short-read assemblers, so this chapter covers all three. They differ in presets and a few starting values, not in how you drive them. This chapter also explains how to read any assembly result, whichever of the five assemblers produced it.

## Why you would do this

You assemble when you want the sequence itself rather than a list of differences from something already known. The clearest case is a genome with no good reference, such as a new bacterial isolate or a plasmid, a small circular DNA molecule that lives beside a bacterium's main chromosome. A second case is a genome you suspect has been rearranged, since a large insertion shows up plainly as an unexpected contig. A third is confirmation. If you believe a sample holds one organism and one contig comes back at the expected length, you have independent evidence.

This chapter assembles reads from the [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome) of [HG002](../../GLOSSARY.md#hg002), a benchmark human sample sequenced many times by many methods. Mitochondria carry a small circular chromosome of their own, 16,569 bases long in humans. That is small enough to assemble in seconds and large enough to be a real genome. The fixture is a [paired-end](../../GLOSSARY.md#paired-end) Illumina library, meaning each DNA fragment was read from both ends, holding 9,958 read pairs. The right answer is published, so you can see what each assembler gets right.

Choose SPAdes for Illumina reads from one organism, and its Meta profile for a community. Choose SKESA when you prefer more contigs with fewer wrong joins, and MEGAHIT for a large community only if it completes on your Mac. [Choosing a tool](01-when-to-assemble.md#choosing-a-tool) compares all five assemblers in LGE.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM` bundle this section imports, so only the plugin pack remains. To import the pair yourself instead, follow the rest of this section.

This chapter uses the human-mito fixture. Download `HG002.chrM_R1.fastq.gz` and `HG002.chrM_R2.fastq.gz` from [the human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Import both files together as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows. LGE pairs them into one bundle named `HG002.chrM`.

Install the `assembly` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries SPAdes 4.3.0, MEGAHIT 1.2.9, and SKESA 2.5.1, the versions that produced the numbers below. The SPAdes run on the fixture takes well under a minute on a recent Mac.

## Procedure

Every number below came from real runs on the fixture reads. Yours should match to within a few bases. A different contig count is not ordinary, and [What good looks like](#what-good-looks-like) says what to make of one.

### Open the assembly sheet

1. Click the `HG002.chrM` bundle in the sidebar to select it. The sheet takes whatever is selected and has no file picker of its own.

2. Choose **Tools > Assembly > SPAdes…**. The assembly sheet opens with SPAdes chosen in the Assembler picker. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the **Inputs** section at the top. Its three read-only rows are **Dataset**, the bundle's name, **Read Layout**, how its reads pair, and **Detected**, the read class LGE found. For the fixture, Read Layout reads "Interleaved paired-end Illumina reads (pairs verified against the records at run time)", because the bundle keeps both mates of each pair in one file. To assemble a different bundle, close the sheet, select that bundle, and reopen it.

    <!-- SHOT: assembly-wizard-spades -->

4. Check the **Read Type** row. For the fixture it is a fixed label reading Illumina short reads, with "Locked from FASTQ header detection." beneath it.

5. Leave **Profile** on **Isolate**, the preset for a sample believed to hold one organism, and change nothing else for a first run.

Read the line beside **Run** at the foot of the dialog before you click anything. It reads "Checking the Genome Assembly pack…" while LGE checks the pack, and Run stays disabled until the pack is installed and its quick launch test has passed, which takes a few seconds. When Run is disabled for another reason, the line says which, such as "Project name is required." The same line also carries a warning that leaves Run on, such as one for an assembler that does not suit the reads.

### Run SPAdes

1. Click **Run**. The sheet closes. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The tool's output streams into the row, and the full text is also saved as `assembly.log` in the run folder.

2. When the row finishes, LGE opens the result in the assembly viewport. Later, click the result under `Analyses` in the sidebar to open it again. A summary strip above the contig table reads SPAdes, Illumina Short Reads, 1 contig, 16697 total bp, an N50 of 16697 bp, and 44.4% global GC.

<!-- SHOT: assembly-viewport -->

## Settings

The sheet shows these controls with a short-read assembler selected. Entries say when a control belongs to one assembler only. Every slider has a number field beside it, so you can drag or type.

**Assembler.** Picks which assembler runs, as a row of buttons of which one is selected. It arrives set to the tool you chose from the menu and always lists all five assemblers, and one that does not suit the detected read class shows a warning while Run stays available. Switch it to compare two assemblers on the same reads without closing the sheet. On the command line this is `--assembler`.

**Read Type.** States which sequencing chemistry produced the reads, which sets the assembler's defaults and decides which assemblers suit the run. It arrives locked to the class LGE read from the FASTQ headers, one of Illumina short reads, ONT reads (Oxford Nanopore), or PacBio HiFi/CCS, and becomes a picker only when the headers give no clear answer, starting then on the class the read lengths suggest, or on the assembler's own class when the lengths say neither. Check it whenever it is a picker, because an assembler that does not suit the chosen class runs with its own read-type settings. On the command line this is `--read-type`.

The sheet takes one read class per run. Bundles from more than one class do not stop the run. The sheet warns that hybrid assembly, which combines short and long reads, is not supported in v1, shows the Read Type picker, and assembles every input as one read class. "v1" is the app's name for this first version of the assembly feature, not a release number. Mixing bundles the sheet could classify with bundles it could not gives a warning that the inputs with no known read type are assembled as the class of the others.

**Profile.** Chooses the SPAdes mode, offering Isolate, Meta, and Plasmid. The default is Isolate, which assumes one organism at reasonably even coverage. Pick Meta for a metagenome, a mixture of organisms sequenced together, and Plasmid when the plasmids rather than the chromosome are what you want. On the command line this is `--profile`.

**Profile (MEGAHIT).** Chooses a MEGAHIT preset, offering Default, Meta Sensitive, and Meta Large. The default is Default, the balanced setting. Pick Meta Sensitive to recover rarer organisms in a mixture at the cost of time, and Meta Large for a large, complex community such as soil. On the command line this is `--profile`. SKESA has no presets, so the row is hidden for it.

**Threads.** Sets how many [threads](../../GLOSSARY.md#thread), parallel workers on separate processor cores, the assembler runs at once. The default is the smaller of your Mac's core count and 8, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run, and leave it alone for MEGAHIT on Apple silicon, which LGE runs on one thread whatever it says, as the note "On Apple silicon MEGAHIT runs on at most 1 thread, because more threads can crash it." under the control states and [its known-limit row](../appendices/troubleshooting.md#defect-megahit) explains. On the command line this is `--threads`.

**Memory Limit.** Caps how much memory the assembler may claim, in whole gigabytes from 1 to your Mac's installed memory. The default is three quarters of installed memory, up to 32 GB, which leaves room for the rest of the system. Raise it for a large or deep library that stops partway, and lower it when you need memory for other applications. On the command line this is `--memory-gb`. It is a ceiling rather than a reservation, and SPAdes stops with a clear error when it reaches it.

**Min Contig.** Drops contigs shorter than this from a MEGAHIT or SKESA result, set with a stepper from 0 to 1,000,000 bases in steps of 100, while with SPAdes the value is recorded but never applied, as [its defect row](../appendices/troubleshooting.md#defect-assembly-min-contig) records. The default is 0, which keeps everything so you can see what the assembler produced. Raise it on a metagenome to keep thousands of unplaceable fragments out of the contig table, and screen short SPAdes contigs by sorting the table's Length (bp) column instead. On the command line this is `--min-contig-length`.

**Careful mode.** Turns on SPAdes' `--careful` pass, which corrects single-base mismatches and short insertions or deletions after assembly. It sits under **Advanced settings > Curated extra arguments**, for SPAdes only, and is off by default because it adds noticeable run time and most runs do not need it. SPAdes refuses careful mode in its isolate and meta modes, so the sheet disables the toggle with the Isolate and Meta profiles, and a caption under it says careful mode is unavailable with that profile because SPAdes rejects `--careful` in that mode. Turn it on only with the Plasmid profile, when per-base accuracy matters. This setting has no command-line flag, so pass `--extra-args "--careful"` instead. The command refuses that combination too, stopping before SPAdes starts with a message that SPAdes rejects `--careful` with the Isolate or Meta profile.

**Skip error correction.** Passes SPAdes' `--only-assembler` flag, which skips the read [error-correction](../../GLOSSARY.md#error-correction) stage. It sits beside Careful mode, for SPAdes only, and is off by default, because correcting errors first keeps false branches out of the graph. Turn it on when an earlier step already corrected the reads, or when the correction stage runs out of memory. This setting has no command-line flag, so pass `--extra-args "--only-assembler"` instead.

<!-- SHOT: assembly-advanced-settings -->

**Extra arguments.** Passes text straight to the assembler without LGE checking it. The default is empty, which is right for almost every run. Use it only for an assembler option the dialog does not show, after reading that assembler's own documentation. On the command line this is `--extra-args`. Quotation marks must come in pairs, and an unclosed one blocks Run with the reason shown at the foot of the sheet. For SKESA, LGE always adds `--min_count 2`, which keeps SKESA from discarding every real k-mer on a small library, and typing your own `--min_count` here replaces it.

**Project Name.** Names the assembly the run produces. It arrives filled from the first input's name with the mate suffix removed and `_assembly` added, so the fixture gives `HG002.chrM_assembly`. Rename it when you assemble the same reads more than once, and note that an empty name blocks Run. On the command line this is `--project-name`.

**Output Folder.** Shows, read only, where the run will land, which is the project's `Analyses` folder. It is there so you can confirm the path, and there is nothing to change in the window. On the command line this is `--output`.

**Run Mode.** Appears only when you select several bundles, and says how they are handled. The only choice is **Run separately per bundle**, with the number of results after it, and **Combine all inputs, run once (1 result)** is locked because pooling is not supported yet. There is nothing to change. This setting has no command-line flag, so run `assemble` once per sample instead.

## Reading the results

This section applies to a result from any of the five assemblers.

### Where the result sits

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes, named for the tool and the moment the run started, for example `spades-2026-09-07T14-23-10`. That run folder is the [assembly bundle](../../GLOSSARY.md#assembly-bundle), and the sidebar shows it as one row that opens the assembly viewport. It is a plain folder rather than a `.lungfishref` reference bundle, and the contigs sit inside it as `contigs.fasta`. A reference bundle exists only after you extract contigs, as [Extracting Contigs](04-extracting-contigs.md) shows. Every run gets its own folder, so several assemblies of the same reads sit side by side.

<!-- SHOT: assembly-bundle-in-analyses -->

Right-click the result row and choose **Show in Finder** to reveal the run folder, which also holds `assembly.log`, the assembler's raw output, a scaffold file for the tools that write one, and `assembly-result.json` with the tool version, the exact command, the wall time, and the statistics. Scaffolds are contigs the assembler has ordered using paired reads, with runs of `N` standing in for unknown gaps. LGE shows the contigs, not the scaffolds. The result reads its files from its own folder, so you can move, rename, or copy it. If its contigs file has gone, opening the result shows the file's name followed by "is no longer in this assembly's folder."

### Assembling the same reads again

To run again with a different setting, select the reads and open the same item under **Tools > Assembly**. **Reassemble…**, on a sidebar row's right-click menu, repeats a run on exactly the reads it used, but only a reference bundle that carries its assembly record offers it, such as the bundle `--reference-bundle` publishes in [On the command line](#on-the-command-line). A result under `Analyses/` made from the window does not offer it, as [its defect row](../appendices/troubleshooting.md#defect-reassemble) records.

Reassemble… looks for each read file of the original run inside the open project first, so it still works after you copy or rename the project. It checks each file's size and [checksum](../../GLOSSARY.md#checksum), a fingerprint of the file's exact bytes, against the record, and it stops with an alert headed **Cannot Reassemble** that names the file when one is gone, cannot be read, or has changed since. An older record with no checksum makes it ask "Reassemble on reads that cannot be checked?" first. The sheet then opens on those reads alone, and a name already taken gets the next free one, such as `HG002.chrM_assembly-2`. The run is a `lungfish-cli assemble` command, so its row offers **Copy CLI Command**, and a failed run shows an alert that sends you to **View Log** on that row.

### The Assembly Context block

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. An assembly result gives it three tabs, **Bundle**, **View**, and **Provenance**. The **Bundle** tab carries an **Assembly Context** block, a two-column list of labels and values, between a **Source Data** list of the reads the run used and a **Source Artifacts** list of the files it wrote. The block starts with Assembler, Read Type, and Version, then the recorded run details such as run date, host, and exit status, then Wall Time, Contigs, Total Assembled bp, N50, L50, Longest Contig, Global GC, the command, and Output Directory, the folder the result sits in now. Wall time is the real elapsed time the run took. For the fixture's SPAdes run it reports SPAdes 4.3.0, 1 contig, 16697 total bp, an N50 of 16697 bp, an L50 of 1 contig, and 44.4% global GC.

The **View** tab's **Assembly Layout** choice arranges the contig list and the detail pane as **Detail left, list right**, **List left, detail right**, or **List above detail**. LGE keeps the choice and uses it for every assembly you open after. The **Provenance** tab holds the run's full record, read as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) explains.

[N50](../../GLOSSARY.md#n50) is the contig length at which contigs that long or longer hold half of all assembled bases, worked through in [When to Assemble](01-when-to-assemble.md#what-the-numbers-mean). A single-contig assembly always has an N50 equal to its one contig and an L50 of 1. [GC content](../../GLOSSARY.md#gc-content) is the share of bases that are G or C.

### The contig table and the detail pane

The viewport's table lists one contig per row, with the columns `#`, `Contig`, `Length (bp)`, `GC %`, `Share of Assembly (%)`, and `Sequence Preview`. The `#` column ranks by length, so row 1 is always the longest, whatever order the assembler wrote its file in. Share is the contig's fraction of all assembled bases. The preview shows the first 80 bases. A filter field above the table narrows rows by name or by the contig's full FASTA name line. There is no coverage column, though most assemblers write their own coverage estimate into each contig's name.

Click a row to open the detail pane beside the table, showing the contig's header, length, GC percent, rank, share, and full sequence. The fixture's contig is named `NODE_1_length_16697_cov_121.957333`, where `cov_121.957333` is SPAdes' average k-mer coverage, how often the contig's k-mers occur in the reads. It runs lower than the number of reads over each base, so compare such figures only between contigs of one run, never across tools, since each assembler counts coverage its own way.

<!-- SHOT: contig-detail-pane -->

The action bar under the table offers **BLAST Contigs**, **Copy FASTA**, **Export FASTA**, and **Create Bundle**, all disabled until you select a contig, with a count of how many are selected. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and the button sends the selected contigs to NCBI over the internet. It reads **BLAST Contig** when exactly one is selected. **Create Bundle** turns the selected contigs into a reference bundle, which [Extracting Contigs](04-extracting-contigs.md) covers. Making a bundle is how you open a contig in a sequence viewport, since opening a row does nothing more than show its detail pane. Right-clicking a row offers the same actions, with **Extract to New Bundle…** in place of Create Bundle, plus **Extract Sequence…** and **Run Operation…**.

Each of these actions first checks that the contigs file is still the one the viewport opened. If a command or a sync rewrote it meanwhile, the action stops with an alert saying "The contigs file of this assembly changed on disk after it opened, so the contigs on screen are not the ones in the result. Nothing was sent to NCBI, copied or written." Select another item in the sidebar, select the assembly again, and repeat the action.

### An empty result

An assembler can finish cleanly and produce nothing. LGE records that as its own outcome, and the viewport reads "Assembly completed, but no contigs were generated." in place of the table. That is the expected result from too few reads or coverage too thin to find overlaps, and the fix is more sequencing.

### What the three assemblers gave on the same reads

| Assembler | Version | Contigs | Total bp | Longest | N50 | Global GC |
|---|---|---|---|---|---|---|
| SPAdes | 4.3.0 | 1 | 16697 | 16697 | 16697 | 44.4% |
| MEGAHIT | 1.2.9 | 3 | 17405 | 16711 | 16711 | 44.6% |
| SKESA | 2.5.1 | 1 | 16570 | 16570 | 16570 | 44.4% |

All three recovered the 16,569-base mitochondrial genome. SKESA landed one base over and named its contig `Contig_1_257.173_Circ [topology=circular]`, marking that it recognized the circle. SPAdes and MEGAHIT each ran a little over a hundred bases long, the overlap written twice where the assembler cut the circle open, as [Circular genomes, trimmed, overlapped, or walked twice](01-when-to-assemble.md#circular-genomes-trimmed-overlapped-or-walked-twice) explains. MEGAHIT also wrote two short contigs of 332 and 362 bases, fragments it could not place. The assemblers disagreed about the exact ends and agreed about the content, which is why the contig count matters more than the last hundred bases.

## What good looks like

Apply the four checks in [What good looks like](01-when-to-assemble.md#what-good-looks-like) of When to Assemble, which covers the contig count, the total length, the GC content, and the coverage arithmetic for this fixture. Three points are particular to short-read results.

A small overshoot is the closing overlap. For a single-molecule target like the mitochondrion, one contig a hundred or so bases over the expected length is right, and SPAdes' 16,697 and SKESA's 16,570 are both the whole genome.

A few short extra contigs beside one complete contig still count as a good result. MEGAHIT's three contigs hold the whole genome in one, with fragments of 332 and 362 bases beside it, and [Extracting Contigs](04-extracting-contigs.md) shows how to keep only the long one. Many short contigs with none near the expected length is the sign of thin or uneven coverage.

GC agrees closely across the three short-read assemblers, 44.4 to 44.6 percent, because Illumina reads carry few base errors. A few tenths of a percent is nothing.

When a run produces nothing at all, read its row in the Operations Panel, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it. The usual causes are a truncated FASTQ or mate files with different read counts.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every flag of `assemble` is listed under [Assembly](../appendices/cli-reference.md#assembly) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"
lungfish-cli assemble "$PROJECT/Imports/HG002.chrM.lungfishfastq" \
  --assembler spades \
  --profile isolate \
  --project-name HG002.chrM_assembly \
  --output "$PROJECT/Analyses/spades-cli"
```

Every assembly run from the window is this same command. After the run finishes, **Copy CLI Command** on its row in the Operations Panel copies it with every value the window chose spelled out, such as `--read-type` and `--threads`, and the copy ends in `--format json`, which makes the command print its progress as lines of JSON for LGE to read. Leave that flag off to get the readable summary.

For the other two runs, swap in `--assembler megahit` or `--assembler skesa` and delete the `--profile` line. SKESA has no presets, and MEGAHIT runs its Default preset only when given no `--profile`, since the command hands `--profile default` to MEGAHIT as a preset name it does not know, as [its defect row](../appendices/troubleshooting.md#defect-megahit-profile) records. `--output` writes exactly where you point it, so give each run its own folder. Add `--reference-bundle` to also publish a `.lungfishref` bundle of the contigs beside that folder, named after the project, which is the kind of bundle that offers **Reassemble…** in the sidebar.

Given the imported bundle, the command reads the bundle's record that its one file is [interleaved](../../GLOSSARY.md#interleaved-fastq), with the two mates of each pair side by side, and hands the pairs to SPAdes and MEGAHIT with `--12` and to SKESA with `--use_paired_ends`, as the window does. Its summary reads Paired-end yes (interleaved pairs). On the fixture SPAdes gives one contig of 16,697 bases with 44.4 percent GC, the same as a run on the two loose FASTQ files with `--paired`, which binds them as mates of one library. `--read-layout` overrides the detection with `single-end`, `interleaved`, or `mixed`, the spellings `map` uses. A file that mixes merged reads with pairs is split by fragment name, so its pairs reach the assembler as pairs and its merged reads go in beside them in the same run, as the files of a merge bundle do. The summary then reads Paired-end yes (R1/R2 files and single reads).

## Next

Continue to [Long-Read Assembly (Flye, hifiasm)](03-running-flye-or-hifiasm.md), which assembles long reads from the same mitochondrion. If your reads are Illumina only, go on to [Extracting Contigs](04-extracting-contigs.md), which turns contigs into a reference bundle for mapping and variant calling.
