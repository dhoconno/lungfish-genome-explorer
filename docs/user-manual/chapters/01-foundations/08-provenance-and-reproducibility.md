---
title: Provenance and Reproducibility
chapter_id: 01-foundations/08-provenance-and-reproducibility
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 16
task: Read the run record Lungfish Genome Explorer keeps for a result, check it before trusting the result, act on an affected-result warning, follow a lineage of steps, and verify a signed record.
tags: [foundations, provenance, reproducibility, inspector, lineage, signing, affected-results]
tools: []
parameters_refs: []
entry_points:
  - Inspector > Provenance tab
  - Settings… (Cmd-,) > General > Provenance Signing
  - "CLI: lungfish-cli provenance verify"
shots:
  - id: inspector-provenance-section
    caption: "The GRCh38.chr20.10.0-10.5Mb reference bundle selected in the Human Mapping and Variants (with results) demo project, with the Inspector's Provenance tab open on the right showing Run Summary at the top and the Lineage, Files & Outputs, Invocation & Options, Runtime, and Raw JSON blocks below it."
  - id: provenance-lineage-step-expanded
    caption: "The Provenance section with HG002 bcftools chosen in the Source picker and one bcftools step expanded in Lineage, showing that step's own Command, Inputs, Outputs, Exit Status, and Wall Time."
  - id: affected-result-band
    caption: "A result made by a release with a known fault, with the pale yellow band above the viewport that says what may be wrong with the result and what to do about it."
  - id: provenance-signing-settings
    caption: "Settings > General > Provenance Signing, showing the Off, Local, and Cosign Plan provider choices above the local signing key field, the public key path field, and the Save Signing Key and Clear Signing Key buttons."
illustrations:
  - id: provenance-graph-cartoon
    brief: "Schematic of the chain in the Human Mapping and Variants (with results) demo project: an imported GRCh38.chr20.10.0-10.5Mb reference FASTA and an imported pair of HG002 FASTQ files feed a minimap2 mapping that produces the HG002 minimap2 alignment track, which feeds a bcftools variant call that produces the HG002 bcftools variant track. Each stage is a node, arrows show which stage produced inputs for the next, and each arrow carries a small SHA-256 label. Use Lungfish Creamsicle for nodes, Deep Ink for arrows and labels, Peach to highlight the variant track at the end as the item you would select before exporting."
glossary_refs: [provenance, provenance-sidecar, reproducibility, checksum, inspector, methods-export, run-record, project, bundle, conda, pileup, exit-status, wall-time, variant-track, standard-error, viewport, affected-result, environment-variable, json, reference-genome, hg002, minimap2, terminal, sidebar, fai, fasta, bam, sam, thread, read-clumping, primer-analysis-bundle, allele-frequency, de-novo-assembly, read-classification, demultiplex, accession, nextflow, snakemake, demo-project, fastq, vcf]
features_refs: [provenance.inspector, provenance.export]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Every time Lungfish Genome Explorer (LGE) downloads a file or runs an operation, it writes down how the result came to be. That note is called [provenance](../../GLOSSARY.md#provenance), the record of where a file came from and what was done to it. LGE stores it as a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file that sits beside the result it describes, the way a sidecar rides beside a motorcycle. The sidecar is written in [JSON](../../GLOSSARY.md#json), a plain-text format that both a program and a person can read.

A sidecar answers one question. Which tool, at which version, with which options, read which files and wrote which files? The `GRCh38.chr20.10.0-10.5Mb` reference [bundle](../../GLOSSARY.md#bundle) in the Human Mapping and Variants (with results) [demo project](../../GLOSSARY.md#demo-project) has such a sidecar. Its name reads GRCh38, a numbered build of the human [reference genome](../../GLOSSARY.md#reference-genome), then chromosome 20 and a 10.0 to 10.5 million base slice. One field, `reproducibleCommand`, holds the command that made the bundle, and the **Command** row of step 1 under **Lineage** in the Provenance tab shows it too. It starts with `lungfish-cli`, LGE's own command-line program, and records what already ran, so reading it is enough.

```json
"reproducibleCommand": "lungfish-cli import fasta <workspace>/lge-demo-build/inputs/hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta --output-dir '@/' --name GRCh38.chr20.10.0-10.5Mb"
```

Here `@/` stands for the project folder and `<workspace>/` for a scratch folder, a temporary folder on the Mac that built the demo, as [Reading the results](#reading-the-results) explains. This page leaves out the backslash JSON puts before each slash.

Every file that command touched is listed with a [checksum](../../GLOSSARY.md#checksum), a short fingerprint computed from the file's exact bytes. LGE uses SHA-256, a standard fingerprinting method whose output is a 64-character string. Two files with the same checksum hold the same bytes, and any change at all, even one edited base, changes the whole string. LGE records each checksum when it writes the file, so anyone can compare it with a copy they hold. To print the SHA-256 of your copy, type `shasum -a 256` and the file's path in [Terminal](../../GLOSSARY.md#terminal), the macOS application where you type commands, as [Reading an On the command line block](06-the-lungfish-project.md#reading-a-command-line-block) explains.

[Reproducibility](../../GLOSSARY.md#reproducibility) is what the record is for. It means running the same tool at the same version with the same options on the same inputs and getting the same answer. This chapter shows how to read one record before you trust a result.

## Why you would do this

Six months after a run, nobody remembers which version of bcftools called those variants. bcftools is the program that finds the positions where a sample differs from the reference. The demo project's `HG002 bcftools` [variant track](../../GLOSSARY.md#variant-track), a named set of variant calls stored in a reference bundle, has a sidecar that names bcftools as `bioconda::bcftools=1.24=h6bd33b9_2`. [Conda](../../GLOSSARY.md#conda) is the package manager LGE uses to install its tools, `bioconda` is the collection the package came from, `1.24` is the release, and `h6bd33b9_2` is the build, the exact packaged copy of that release. A reviewer needs that level of detail.

The record helps in everyday moments too. A run fails and you want to see which step broke, which the **Warnings** block of the Provenance tab names. A paper needs a methods paragraph naming every tool. A release of LGE turns out to have had a fault that could change one kind of result, and you need to know which of your results it made. LGE writes a record for every analysis it runs, with no way to turn it off.

This chapter reads three linked records in the demo project. The first is the import of the `GRCh38.chr20.10.0-10.5Mb` reference, the second is the minimap2 mapping of the HG002 reads onto it, and the third, in [Reading a lineage](#reading-a-lineage), is the `HG002 bcftools` variant track called from that mapping. [HG002](../../GLOSSARY.md#hg002) is the human DNA sample the reads come from, which [Sequencing Reads](02-sequencing-reads.md#why-you-would-do-this) introduces, not the reference they are placed on, and [minimap2](../../GLOSSARY.md#minimap2) is the program that places reads onto a reference. Each record reaches back through the one before it.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](06-the-lungfish-project.md#procedure) shows. This chapter uses the Human Mapping and Variants (with results) demo project, whose name means it already holds the finished mapping and variant calls. If you have not downloaded it yet, choose **Help > Demo Projects…** and click **Download & Open** beside it, as [Demo projects](06-the-lungfish-project.md#demo-projects) explains. LGE saves it by default in the `LGE Demo Projects` folder inside your Documents folder, where the command-line section looks for it.

No plugin pack is needed, because this chapter only reads records that earlier runs wrote. Reading one takes a minute.

## Procedure

1. Select the `GRCh38.chr20.10.0-10.5Mb` reference bundle under `Reference Sequences/` in the [sidebar](../../GLOSSARY.md#sidebar). Open the [Inspector](../../GLOSSARY.md#inspector) if it is hidden, as [The Inspector](06-the-lungfish-project.md#the-inspector) shows.

2. Click the **Provenance** tab at the top of the Inspector. Its content, which this chapter calls the Provenance section, fills the Inspector.

    <!-- SHOT: inspector-provenance-section -->

3. Read **Run Summary** at the top. Click the small arrow beside a block's title to open or close the block, and Run Summary starts open. **Workflow** reads `lungfish import fasta`, the record's name for the import that `lungfish-cli import fasta` runs, and **Tool** repeats it with the LGE version that made the demo. **Run Status** says how the run ended, here Completed. The [exit status](../../GLOSSARY.md#exit-status) is the number a tool reports when it stops, where 0 means success and any other number means failure. The [wall time](../../GLOSSARY.md#wall-time) is how long the run took by an ordinary clock, under a second here, which the row shows as `<1s`. This import ran three steps, LGE's own import, `bgzip` to compress the sequence, and `samtools` to index it, writing a small lookup file, a [FAI file](../../GLOSSARY.md#fai), that lets a program jump to one position without reading the whole sequence.

4. Find **Files & Outputs**, which is open when the tab loads. It lists the [FASTA](../../GLOSSARY.md#fasta) file the import read, `GRCh38.chr20.10.0-10.5Mb.fasta`, a plain-text file of the sequence, and the compressed copy it wrote, whose path ends in `sequence.fa.gz`, each with its checksum. [Reading the results](#reading-the-results) shows the two values to expect.

5. Select the mapping result `minimap2-2026-09-25T00-00-00` under `Analyses/`, and read its Run Summary in the same Provenance tab. **Workflow** reads `lungfish map`, **Tool** reads minimap2 at version 2.31, and **Steps** reads 7. They are the mapping, four `samtools` steps that filter, sort, index, and count the reads, and two steps of LGE's own, one that rewrites the header of the [BAM](../../GLOSSARY.md#bam) alignment file so it names no private folders and one that builds the viewer bundle. In **Files & Outputs**, a **Reference** row names the compressed sequence from step 4 with the same start, `e8d07729`, so this record reaches back to the one before it.

To hand a run to someone else as a script, a text file of commands, or as a [Nextflow](../../GLOSSARY.md#nextflow) or [Snakemake](../../GLOSSARY.md#snakemake) pipeline, see [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure).

## Reading the results

The Provenance section breaks into the blocks **Run Summary**, **Warnings**, **Lineage**, **Files & Outputs**, **Invocation & Options**, **Runtime**, and **Raw JSON**, and the last three start closed. **Warnings** appears only when there is something to warn about, such as a fact missing from the record, a step that exited with a failure, or a known fault in the release that made the result, which [When a result is marked affected](#when-a-result-is-marked-affected) covers. Once a record holds more than six steps, more than eight files, or more than eight options, a **Filter provenance** field appears above the blocks and narrows a long lineage to the steps whose text matches what you type. A copy icon in the section header, with the tooltip **Copy provenance text**, puts the whole record on the clipboard as text.

The status line under the section title judges the record and not the run. It reads "Complete record" when the record holds every fact LGE expects and "Incomplete record" when one is missing, and **Warnings** says which. It can also read "Invalid record" for a [primer analysis bundle](../../GLOSSARY.md#primer-analysis-bundle) whose record could not be verified, and **Warnings** says what is wrong. A record in an older format can read "Older record format" beside a small clock icon, and it shows each fact that format never held as Not recorded.

**Run Summary** identifies the run. **Run Status** reads Completed, Failed, Cancelled, Not finished, or Not recorded. Not finished means the record was written while the run was still going and nothing updated it afterward, and Not recorded means an older record never said how its run ended. When the **Tool** row reads `lungfish-cli`, a **Step Tools** row follows it and names each program other than LGE that the run used, such as `kraken2 v2.17.1`. A pipeline step that recorded a release tag and a commit, the exact snapshot of its code, reads as its name, the tag, and the first seven characters of the commit in parentheses. **Steps** is the number of tool runs the record holds, three for the chr20 import, seven for the mapping, and twelve for the bcftools track. **Inputs** and **Outputs** count files rather than list them. **Signatures** appears only when the record was signed, which [Signing a record](#signing-a-record) covers, and **Sidecar** gives the record's path inside the project.

**Lineage** lists one row for each record behind this result, ending with the result's own record. Click a row to open its numbered steps and a step to open its own **Command**, its **Inputs** and **Outputs** as file lists, its **Exit Status**, its **Wall Time**, and whatever the tool wrote to [standard error](../../GLOSSARY.md#standard-error), the channel a command-line tool uses for its own progress notes and complaints, which this block labels **stderr**. Text there is normal rather than a sign of failure. The **Command** names each file inside the project by its path from the project folder. A file the run wrote to a scratch folder, a temporary folder for work files, and then discarded shows by its file name alone. Hover over the **Command** to see the command as it ran.

Right-click a step's title or its **Command** row for three choices. **Copy Step** copies every row of that step as text, **Copy Command** copies the command with every path in full, and **Copy All Steps** copies each step of that record in order. With a step's title selected, Cmd-C does what **Copy Step** does, and VoiceOver, the macOS screen reader, offers the same three as actions. Paste a copied command into Terminal only to run that one step again, because it can write over the files the step made. If a folder the command names is renamed or duplicated in the sidebar, such as the bundle that holds the record, a note under the **Command** row names the old and new folders, and **Copy Command** uses the new one. A step LGE ran inside the app has no command for Terminal, so a note says so and **Copy Command** is turned off.

Some steps add rows of their own, each shown only when the step's record holds it.

| Row | Shows when | What it says |
|---|---|---|
| **Environment** | LGE changed the [environment variables](../../GLOSSARY.md#environment-variable) a step ran with, the named values a program starts with | The names of the variables it set or removed, never their values |
| **Version and build** | The step ran on a [Linux machine](#a-run-on-a-linux-machine) | The tool's version and build, and where that version came from |
| **Compressed by**, **Compression level**, **Clumpify groups** | A read import recorded how it compressed the reads | The program that wrote the compressed file, the level it actually used, and how many groups, or pieces, `clumpify.sh`, the [read clumping](../../GLOSSARY.md#read-clumping) program, split the reads into to fit its memory |
| **Termination** | The step was stopped, ended by a signal, or never started | How it ended, such as Cancelled, at a time limit, or by a signal, the message the operating system sends a program to stop it |
| **Output** | An output was cut short, or a failed step recorded nothing about it | Incomplete or Not recorded |

**Files & Outputs** lists every file the run read and wrote, with its role, such as Input, Output, Reference, Index, Log, or Report, its size, its format, and its SHA-256 checksum. A file inside the project is named by its path from the project folder, such as `Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq`, and a file outside the project by its name alone, with a note that it lies outside the project. A file the run wrote and then discarded, such as the unsorted [SAM](../../GLOSSARY.md#sam) alignment file that minimap2 writes before samtools sorts it, carries the note "Intermediate file, not kept", because the project holds only the sorted result. The chr20 import's record shows the FASTA it read at `sha256 3ee1418353a681cbd415a278ecc0bd9579121eac2bc483448ab78ca679840101` and the compressed sequence it wrote at `sha256 e8d07729ea4729764967e236a2450ff1e356ee7947020dab68dc73dc85589a1e`. Compare the first eight characters of a checksum, such as `e8d07729`. If they match, the files are almost certainly the same, and any difference anywhere in the string means your copy is not the file the record describes.

**Invocation & Options** lists the option values the run used, each row ending in a kind. **Explicit** is a value the run was asked for, **Default** is a value left at its default, and **Resolved Default** is a value LGE filled in when the run started, such as a folder path. A thread count can appear here, and a [thread](../../GLOSSARY.md#thread), one parallel worker inside a program, matters because some tools give slightly different answers with a different number of threads. The demo project's minimap2 mapping ran with `-t 14`, which sets 14 threads and describes the Mac that made the demo rather than a recommended setting. The **Threads** setting of the mapping wizard sets yours, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#settings) explains. An EsViritu or TaxTriage record, which [What Is Read Classification](../06-classification/01-what-is-classification.md) introduces, also lists `databaseIdentityStatus`. It reads `pinned` when a SHA-256 checksum LGE computed over the database's files names it, held in `databaseDigest`, and `unpinned` when none does, as for a database put in place by hand. An imported classification result reads `namedBySource` or `notNamedBySource`, by whether the result states the database version that made its calls.

**Runtime** names the machine. The chr20 record carries the LGE version that ran it, the processor type `arm64`, the chip family of Apple-silicon Macs, a dependency set of `2026.2`, and the operating system `macOS 26.6.2 (arm64)`. It names no user, because LGE leaves the account name out of the records it writes into a project. The dependency set is the versioned collection of tools LGE installed for itself, so `2026.2` names that whole collection rather than any one tool.

**Raw JSON** shows the sidecar as text, with a **Copy** button of its own that copies the whole text, for any field the other blocks do not show. In the file, a path inside the project is written as `@/` followed by its path from the project folder, a file you chose from elsewhere on your Mac as `<external>/` followed by the file name alone, a scratch file as `<workspace>/` followed by its path, and a tool in LGE's own tool folder as `<tool-root>/` followed by its path, so a record names neither your account nor the folders of the Mac that wrote it. A long record shows only its first 80 lines and says how many it holds, and a record too large to show offers **Reveal in Finder** instead. Each field in the sidecar is listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

### Reading a lineage

The `HG002 bcftools` variant track in the demo project has a long lineage, the list of every step behind one result in the order they ran, and it is the record to read when you want to know exactly how a set of variant calls was made. Variant tracks live in the reference bundle inside the mapping result, as [Where results land](06-the-lungfish-project.md#where-results-land) explains, so you open that bundle first.

1. Click the `minimap2-2026-09-25T00-00-00` result under `Analyses/` in the sidebar. LGE opens it in the [viewport](../../GLOSSARY.md#viewport), the main area of the window where a result is drawn, and loads the reference bundle inside the mapping result, as [Open the mapping result](../04-alignments/01-mapping-reads-to-a-reference.md#open-the-mapping-result) shows.
2. In the Inspector's **Provenance** tab, choose `HG002 bcftools` from the **Source** picker at the top of the Provenance section. The picker lists the result's own record, **Mapping** here, and each named variant track in the bundle, and choosing a track loads that track's own record.
3. In **Lineage**, click the last row, the track's own record, and then click step 4.

<!-- SHOT: provenance-lineage-step-expanded -->

Each earlier row has its own numbered steps, so numbering restarts in every row, and the last row is the variant call. The variant call's own chain runs twelve steps. The first two are LGE's own, one that readies the alignment for bcftools and one that unpacks the compressed reference into a scratch folder. Step 3 indexes that reference with `samtools faidx`. Step 4 is the [pileup](../../GLOSSARY.md#pileup), which gathers the bases every read shows at each reference position. Step 5 is the call, which decides from that evidence where the sample differs. Step 6 is the threshold filter, which removes every row below the **Minimum Allele Frequency** of 0.05, in round terms fewer than 5 percent of the reads at that position carrying the changed base, or the **Minimum Depth** of 10, fewer than 10 reads covering it. Both are set in the Call Variants dialog, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md#read-the-dialog-before-you-change-anything) explains, and the [allele frequency](../../GLOSSARY.md#allele-frequency) here is a share of reads and not of a population. Steps 4 and 5 are these two commands, with three dots for long folder paths and `<id>` for the alignment track's internal id, which differs in every project:

```text
bcftools mpileup -Ou -A -d 0 -a FORMAT/AD,FORMAT/DP,INFO/AD -f .../reference.fa .../aln_<id>.bam
bcftools call --ploidy 2 -mv -Ov -o .../bcftools.raw.vcf
```

In step 5, `--ploidy 2` is the **Diploid** choice of the dialog's **Ploidy** setting, which lets the caller report positions where the two copies of a chromosome differ, as in a human sample. The remaining steps are bookkeeping. Two more `bcftools` steps attach the reference's sequence names and sort the rows, `bgzip` and `tabix` compress and index the file, and an LGE step loads the rows into the database the variants table searches. The last step is the `lungfish-cli variants call` command itself, whose inputs are the finished files in the scratch folder and whose outputs are the track's files in the bundle.

After [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), read the lineage of your own bcftools track. It should match these steps, apart from your Mac's thread count and your own file paths.

### When a result is marked affected

A release of LGE can turn out to have had a fault that could make one kind of result wrong, such as a [classification](../../GLOSSARY.md#read-classification) (which organism each read came from), an [assembly](../../GLOSSARY.md#de-novo-assembly) (reads joined into longer sequences), a set of variant calls, trimmed or [demultiplexed](../../GLOSSARY.md#demultiplex) reads (split by barcode into one set per sample), or a mapping made from two separate read files. LGE keeps a list of these faults, each with the releases that had it and the kinds of result it touches, and every record names the release that made it. So LGE checks each result you select against the list, and an [affected result](../../GLOSSARY.md#affected-result) is one whose record names a release the list holds for its kind.

LGE shows an affected result in two places, so you meet the warning before you read the result. The Provenance tab gains an **Affected result** row under **Warnings**, with one sentence on what may be wrong and one on what to do. A pale yellow band above the viewport carries the same words, and you can select them to copy. When more than one fault matches, the band gives the first in full and says how many more notes wait under **Warnings**.

<!-- SHOT: affected-result-band -->

The band stays until the result is made again by a release without the fault. If your copy of LGE is still on the release that made the result, update it first, as [Updating LGE](06-the-lungfish-project.md#updating-lge) shows, then run the same step on the same inputs again from the **Tools** menu. Read the whole note before you delete anything, because some notes ask you to check one thing first, such as whether two input files shared a name, and the result may be sound if that does not apply to your run.

### A run on a Linux machine

A step can run on a Linux machine, such as a lab server or an HTCondor pool, a system that shares jobs out across many computers, and come back into the project as a bundle, as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) shows. A launcher, the program that starts the run there, starts it. In **Run Summary**, **Wall Time (Linux run)** then takes the place of **Wall Time** and gives the time the run took there, because the Mac only wrote the record down. **Runtime** adds these rows after **Dependency Set**.

| Row | What it says |
|---|---|
| **Steps ran on** | The release of the Linux kernel, the core of the operating system, and the processor type |
| **Steps ran with** | `lungfish-executor`, the LGE program that ran each step there, with its build and its SHA-256 checksum |
| **Leftover processes** | What that program did about programs a tool left running. Either it found them only by following each program's parent, so one that cut itself loose may still be running after the step ended, or it took in every one and stopped it before the step ended |
| **Reported by the launcher** | Facts the launcher passed in, such as the machine's name, shown as given and not checked by LGE |

## What good looks like

Five checks tell you a record is worth trusting. **Run Status** reads Completed and the exit status is 0. A cancelled run can end on a step that exited 0, so only **Run Status** shows the cancel, and any other exit status means the tool reported a failure whatever the output files look like. An older record reads Not recorded for **Run Status**, and then the exit status is the check. The tool version in the sidecar names a package build rather than a bare number, the way `bioconda::bcftools=1.24=h6bd33b9_2` does, and the **Copy** button of **Raw JSON** puts the whole sidecar, which holds it, on the clipboard, while **Lineage** shows only the short form, such as `v1.24`. The input checksums in **Files & Outputs** match the files you meant to use. The step count matches the work you think ran, such as 3 for an import, 7 for a minimap2 mapping, and 12 for a bcftools call in the demo project, so a chain far shorter than you expect usually means a step was skipped. And **Warnings** holds no **Affected result** row.

If a check fails, do not rely on the result yet. Read the failed step's **stderr** in **Lineage**, correct the cause, and run it again. A checksum that differs means you hold a different file, so find the right one first.

An empty Provenance section usually has an ordinary explanation. LGE expects a record for every result and for scientific files such as a FASTA, [FASTQ](../../GLOSSARY.md#fastq), BAM, or [VCF](../../GLOSSARY.md#vcf), so a scientific file you copied into the project folder by hand has no run record, and the status line reads "Missing provenance". If a result LGE itself produced shows an empty Provenance section, that is a bug, and **Help > Report an Issue…** is the place to say so.

A record cannot promise three things. A public database can revise an entry after you fetched it, so an [accession](../../GLOSSARY.md#accession), the identifier a database gives a record, and a date may not return the same bytes next year. A run on a different Mac or macOS version can shift a tool's output slightly, and the thread count is the first value to match when you chase such a difference. And the [methods export](../../GLOSSARY.md#methods-export), the methods paragraph LGE writes when you choose **File > Export > Provenance > Methods Section…** as [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure) shows, is only a first draft. Add the accession numbers, access dates, and database citations it cannot know. LGE writes down what ran, not what you meant to run.

## Signing a record

Most readers leave signing off and skip this section. Signing serves audit work that needs a tamper-evident record, one that shows whether anyone changed it after it was written. It uses a key pair, two linked codes where the private signing key stamps a record and the matching public key lets anyone check the stamp without being able to make one. The key can be any secret text you choose, and LGE derives the pair from it. The stamp goes in a file beside the record ending in `.signature.json`, and the public key in a file ending in `.pub`.

LGE signs a record only when a signing key is set as the record is written, in one of two environment variables. `LUNGFISH_PROVENANCE_SIGNING_KEY` holds the key itself, and `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` holds the path of a file that holds it. Records written while one is set are signed, though a few, such as a database install receipt, never are. A record written with no key stays unsigned, and getting a signed one means running the analysis again with a key set.

A rename, move, or copy in the sidebar rewrites the paths inside the records it carries, which would break their signatures. With a key set, LGE signs again each record that verified before, so it still verifies. With none, LGE removes the signature and the public key, so the record reads as unsigned rather than as changed. [Shared Projects and Bundle Migration](../appendices/shared-projects.md#provenance-expectations) explains what a copy between projects checks.

**Settings…** (Cmd-,), in the application menu at the left of the menu bar, has a **Provenance Signing** section on its **General** tab. Its **Provider** control offers **Off**, **Local**, and **Cosign Plan**, and the default is Off. Below it sit the **Local signing key** and **Public key path** fields, the **Save Signing Key** and **Clear Signing Key** buttons, and a status line under them. A signature only matters if someone checks it later, which the command line below does.

<!-- SHOT: provenance-signing-settings -->

## On the command line

The command below checks a signed record against its signature, following the convention in [Reading an On the command line block](06-the-lungfish-project.md#reading-a-command-line-block). If Terminal cannot find `lungfish-cli`, see [Finding the program](../appendices/cli-reference.md#finding-the-program). The command is listed in [Projects, provenance, and run history](../appendices/cli-reference.md#projects-provenance-and-run-history) in the CLI Reference. It takes a sidecar file, a bundle, or a result folder, looks for the two files beside the sidecar that [Signing a record](#signing-a-record) names, and checks only records signed with the Local provider.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
lungfish-cli provenance verify "$PROJECT/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref"
```

Pointed at the demo project's unsigned chr20 bundle, as here, the command prints "This record carries no signature, so there is nothing to verify.", names the signature file it looked for, says how LGE signs a record, and ends with exit status 3, the command line's code for an input error, here a record with no signature to check. That is the expected answer for a record nobody signed, and typing `echo $?` straight afterward shows the number. A signed record that matches its signature prints "Signature valid" with the provider and the record's SHA-256, and a record changed after it was signed fails with a message that names the mismatch.

## Next

Foundations is complete. Continue to [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md), the first chapter of the Sequences part, where you bring a human gene record into a project and read it base by base. To go straight to the kind of data you have, the [reading paths](../../index.md#reading-paths) on the home page list a chapter order for each.
