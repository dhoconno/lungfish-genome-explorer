---
title: Provenance and Reproducibility
chapter_id: 01-foundations/08-provenance-and-reproducibility
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 11
task: Read the run record Lungfish Genome Explorer keeps for a result, check it before trusting the result, and verify a signed record.
tags: [foundations, provenance, reproducibility, inspector, signing]
tools: []
parameters_refs: []
entry_points:
  - Inspector > Provenance tab
  - Settings... (Cmd-,) > General > Provenance Signing
  - "CLI: lungfish-cli provenance verify"
shots:
  - id: inspector-provenance-section
    caption: "The chr20 reference bundle selected in the demo project, with the Inspector's Provenance tab open on the right showing Run Summary above the Warnings, Lineage, Files & Outputs, Invocation & Options, Runtime, and Raw JSON blocks."
  - id: provenance-lineage-step-expanded
    caption: "The Provenance section with HG002 bcftools chosen in the Source picker and one bcftools step expanded in Lineage, showing that step's own Command, Inputs, Outputs, Exit Status, and Wall Time."
  - id: provenance-signing-settings
    caption: "Settings > General > Provenance Signing, showing the Off, Local, and Cosign Plan provider choices above the local signing key field, the public key path field, and the Save Signing Key and Clear Signing Key buttons."
illustrations:
  - id: provenance-graph-cartoon
    brief: "Schematic of the demo project's chain: an imported chr20 reference FASTA and an imported pair of HG002 FASTQ files feed a minimap2 mapping that produces a BAM, which feeds a bcftools variant call that produces a VCF. Each stage is a node, arrows show which stage produced inputs for the next, and each arrow carries a small SHA-256 label. Use Lungfish Creamsicle for nodes, Deep Ink for arrows and labels, Peach to highlight the variant track at the end as the item you would select before exporting."
glossary_refs: [provenance, provenance-sidecar, reproducibility, checksum, inspector, methods-export, run-record, project, bundle, conda, pileup]
features_refs: []
fixtures_refs: [demo-project]
brand_reviewed: false
lead_approved: false
---

## What it is

Every time Lungfish Genome Explorer (LGE) makes a file, it writes down how that file came to be. That note is called [provenance](../../GLOSSARY.md#provenance), the record of where a file came from and what was done to it. LGE stores it as a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file that sits beside the result it describes, the way a sidecar rides beside a motorcycle. The sidecar is written in JSON, a plain-text format that both a program and a person can read.

A sidecar answers one question. Which tool, at which version, with which options, read which files and wrote which files? The chr20 reference [bundle](../../GLOSSARY.md#bundle) in the demo project has such a sidecar, and one of its fields, `reproducibleCommand`, is the command that made the bundle. It is a record of what already ran, not something to type.

```json
"reproducibleCommand": "lungfish-cli import fasta .../GRCh38.chr20.10.0-10.5Mb.fasta --output-dir '.../LGE Manual Demo.lungfish' --name 'chr20 10.0-10.5Mb'"
```

The three dots stand for a longer folder path shortened to fit the page.

Every file that command touched is listed with a [checksum](../../GLOSSARY.md#checksum), a short fingerprint computed from the file's exact bytes. LGE uses SHA-256, a standard fingerprinting method whose output is a 64-character string. Two people holding the same checksum hold the same bytes, and any change to the file at all, even one edited base, changes the whole string. LGE records the checksum when it writes a file, so you or a collaborator can compare it later with a copy you hold.

[Reproducibility](../../GLOSSARY.md#reproducibility) is what the record is for. It means running the same tool at the same version with the same options on the same inputs and getting the same answer. Provenance is what LGE writes down, and reproducibility is what you, a collaborator, or a reviewer does with it. This chapter shows how to read one record before you trust a result.

## Why you would do this

Six months after a run, nobody remembers which version of bcftools called those variants. bcftools is the program that reads aligned sequencing reads and writes out the positions where a sample differs from the reference. The demo project holds the answer. Its sidecar names bcftools as `bioconda::bcftools=1.24=h6bd33b9_2`. [Conda](../../GLOSSARY.md#conda) is the package manager LGE uses to install its tools, `bioconda` is the collection the package came from, `1.24` is the release, and `h6bd33b9_2` is the build, the particular compiled copy of that release. A reviewer asking how a figure was made needs exactly that level of detail.

The record helps in everyday moments too. A run fails and you want to see which step broke. A paper needs a methods paragraph naming every tool. LGE writes a record for every analysis it runs, with no way to turn it off, so the material is already on disk before you go looking for it.

This chapter uses three linked results in the demo project. They are the chr20 reference bundle, the HG002 minimap2 mapping built on it, and the HG002 bcftools variant track built on the mapping. HG002 is a widely shared human reference sample, and minimap2 is the program that places sequencing reads onto a reference genome. Because each result was made from the one before, each record reaches back through the one before it.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](06-the-lungfish-project.md#procedure) shows. This chapter uses the demo project fixture. Build it from https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/demo-project, as [Practice data for this manual](06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Nothing in this chapter needs a plugin pack, because it only reads records that earlier runs already wrote. Reading a record takes a minute.

## Procedure

1. Select the `chr20_10.0-10.5Mb` reference bundle under `Reference Sequences/` in the sidebar. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

2. Click the **Provenance** tab at the top of the Inspector. Its content, which this chapter calls the Provenance section, fills the Inspector.

    <!-- SHOT: inspector-provenance-section -->

3. Read **Run Summary** at the top. For this bundle it names the workflow `lungfish import fasta`, the tool and its version, when the run was created, an exit status of 0, the wall time, and counts of steps, inputs, and outputs. The last row gives the path of the sidecar file itself.

4. Choose `HG002 bcftools` from the **Source** picker at the top of the Provenance section, then open the **Lineage** block and expand one step. The picker offers **Bundle** and each named variant track attached to the reference bundle, and choosing a track loads that track's own record. That track's chain runs eleven steps, from staging the alignment and the reference, through `samtools faidx`, four `bcftools` calls, `bgzip`, `tabix`, and the import of the rows into the bundle's search database, to the `lungfish-cli variants call` command that ran them all. These are bookkeeping steps LGE ran for you, so read them as a list of what happened rather than as tools to learn.

    <!-- SHOT: provenance-lineage-step-expanded -->

To hand the run to someone else as a script or a workflow, see [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure).

## Reading the results

The Provenance section breaks into blocks you open and close one at a time. They are Run Summary, Warnings, Lineage, Files & Outputs, Invocation & Options, Runtime, and Raw JSON, and Warnings appears only when the run reported one. Once a record is long enough, a **Filter provenance** field appears above the blocks and narrows a long lineage to the steps whose text matches what you type. A **Copy** button in the section header puts the whole record on the clipboard.

**Run Summary** identifies the run. Steps is the number of tool runs the record holds, small for the chr20 import and eleven for the bcftools track. Inputs and Outputs are counts rather than lists, so a run reporting one input and ten outputs read one file and wrote ten. Signatures appears only when the record was signed, which [Signing a record](#signing-a-record) covers, and Sidecar gives the record's path on disk.

**Lineage** is the chain of steps in order, each one numbered and expandable. Open a step and it shows that step's own Command, its Inputs and Outputs as file lists, its exit status, its wall time, and whatever the tool wrote to standard error. Standard error is the channel a command-line tool uses for its own progress notes and complaints, so text there is normal rather than a sign of failure. In the bcftools chain, step 4 is the [pileup](../../GLOSSARY.md#pileup), which gathers the bases every read shows at each reference position, and step 5 is the call, which decides from that evidence where the sample differs.

```
bcftools mpileup -Ou -f .../reference.fa .../hg002-minimap2.bam
bcftools call -mv -Ov -o .../bcftools.raw.vcf
```

**Files & Outputs** lists every file the run read and wrote, with its role, its size, and its SHA-256 checksum. The chr20 import's record shows the FASTA it read at `sha256 3ee1418353a681cbd415a278ecc0bd9579121eac2bc483448ab78ca679840101` and the compressed sequence it wrote at `sha256 e8d07729ea4729764967e236a2450ff1e356ee7947020dab68dc73dc85589a1e`. Those strings let a collaborator confirm they hold your file rather than a lookalike. Glancing at the first few characters is enough to see that two records name the same file.

**Invocation & Options** lists the option values the run used, each marked as explicit, default, or resolved default. A thread count can appear here, which matters because some tools give slightly different answers with a different number of threads. The demo project's minimap2 mapping ran with `-t 14`, which describes the Mac it ran on rather than a recommended setting.

**Runtime** names the machine. The chr20 record carries the LGE version, the processor type `arm64`, a dependency set of `2026.2`, the operating system `macOS 26.6.2 (arm64)`, and the user who ran it. The dependency set is the versioned collection of tools LGE installed for itself, so `2026.2` names that whole collection rather than any one tool. **Raw JSON** shows the whole sidecar as text with a Copy button of its own, for any field the other blocks do not show. Each field in the sidecar is listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

## What good looks like

Four checks tell you a record is worth trusting. The exit status in Run Summary is 0, since any other number means the tool reported a failure whatever the output files look like. The tool version names a package build rather than a bare number, the way `bioconda::bcftools=1.24=h6bd33b9_2` does. The input checksums in Files & Outputs match the files you meant to use. And the step count matches the work you think ran, so a chain far shorter than you expect usually means a step was skipped.

An empty Provenance section usually has an ordinary explanation. A file you copied into the project folder by hand has no run record, and the section's status line says so, reading "Missing provenance" for an item that should have a record and "No provenance required" for one that should not. If a result LGE itself produced shows an empty Provenance section, that is a bug, and **Help > Report an Issue…** is the place to say so.

Three things a record cannot promise are worth keeping in mind. A public database can revise an entry after you fetched it, so an accession and a date may not return the same bytes next year. A run on a different Mac or macOS version can shift a tool's output slightly, usually a handful of borderline variant calls out of thousands, and the thread count is the first value to match when you chase such a difference. And the [methods export](../../GLOSSARY.md#methods-export) is a first draft, so add the accession numbers, access dates, and database citations it cannot know. LGE writes down what ran, not what you meant to run.

## Signing a record

Most readers leave signing off and can skip this section. For audit work that needs a tamper-evident record, one that shows whether anyone changed it after it was written, **Settings...** (Cmd-,), in the application menu at the left of the menu bar, has a Provenance Signing section on its **General** tab. Its Provider control offers Off, Local, and Cosign Plan, where Cosign is an outside signing service used in software supply-chain work. The default is Off, which is right for most research. Below the provider sit a local signing key field, a public key path field, and **Save Signing Key** and **Clear Signing Key** buttons, with a status line beneath them. A signature only matters if someone checks it later, which the command line below does.

<!-- SHOT: provenance-signing-settings -->

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The command below checks a signed record against its signature. It takes a sidecar file, a bundle, or a result folder. Pointed at the demo project's unsigned chr20 bundle, as here, it stops with "Signature artifact is missing", which is the expected answer for a record nobody signed. The project path holds spaces, so it sits inside quotation marks, where `$HOME` stands for your home folder.

```bash
lungfish-cli provenance verify \
  "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish/Reference Sequences/chr20_10.0-10.5Mb.lungfishref"
```

The command looks for the signature beside the sidecar, in a file named after it ending in `.signature.json`, and the public key in a file ending in `.pub`. It checks only records signed with the Local provider, so it pairs with the Provenance Signing setting above.

## Next

Foundations is complete. Continue to one of the task parts.

- [Sequences](../02-sequences/01-importing-and-viewing.md) for importing, viewing, and downloading reference sequences
- [Reads](../03-reads/01-importing-fastq.md) for importing, checking, trimming, and cleaning sequencing reads
- [Alignments](../04-alignments/01-mapping-reads-to-a-reference.md) for mapping reads and reviewing the alignment
- [Variants](../05-variants/01-calling-variants-from-amplicons.md) for calling and reading variants
- [Classification](../06-classification/01-what-is-classification.md) for identifying the organisms in a sample
