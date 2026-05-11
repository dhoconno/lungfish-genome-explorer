---
title: Plugin Packs
chapter_id: 01-foundations/07-plugin-packs
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 8
task: Install and verify Lungfish Genome Explorer plugin packs from the Plugin Manager.
tags: [foundations, plugin-pack, installation]
tools: []
entry_points:
  - "Tools > Plugin Manager (Cmd-Shift-B)"
shots: []
planned_shots:
  - id: plugin-manager-window
    caption: "The Plugin Manager window listing available and installed packs."
  - id: plugin-manager-installed
    caption: "Plugin Manager after read-mapping and variant-calling install, showing both packs marked installed."
illustrations: []
glossary_refs: [plugin-pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

Lungfish Genome Explorer (LGE) does not bundle every bioinformatics tool. The viral genomics
ecosystem moves quickly, individual tools update on their own schedules,
and a single user almost never needs all of them at once. Bundling
everything would mean a multi-gigabyte download, a slower release cadence,
and a guarantee that something would be out of date the day you installed
it. So LGE ships small and pulls in tools on demand.

A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of related command-line tools,
installed together because chapters tend to use them together. The
`read-mapping` pack gives you the read mappers (`minimap2`, `BWA-MEM2`,
`Bowtie2`, `BBMap`) and `samtools`, the workhorse utility for sorting,
indexing, and querying BAM alignment files. The `variant-calling` pack
gives you the variant callers (iVar, LoFreq, Medaka, Clair3), `bcftools`
for working with VCF files, and the indexing utilities that go with them.

You can install and update packs from the GUI (`Tools > Plugin Manager`,
described below) without needing to know anything about how packs are
laid out on disk. The packs themselves live in a hidden directory in your
home folder and are shared across every LGE project on the machine, so you
install a pack once and every project sees it.

So what should you do with this? When a workflow chapter says "install the
`read-mapping` pack first," open the Plugin Manager, click **Install** next
to that pack, and move on. The packs are quick to install and quick to
verify, and you only do it once per machine.

## What you will learn

By the end of this chapter you will be able to install one or more plugin
packs from the Plugin Manager window, list which packs are installed,
recognise a "missing tool" error from a workflow operation as a
missing-pack error, and re-run the install to confirm a pack is current.
You will not need to type any commands; the Plugin Manager handles the
download, the channel configuration, and the per-tool environment layout
for you.

## System requirements

Plugin packs are supported on macOS 26 Tahoe or later on Apple Silicon
Macs. A 16 GB Mac can run the default viral, mapping, variant-calling, and
assembly examples in this manual. Broad metagenomics databases need more
memory because tools such as Kraken2 load the active database into RAM.
Keep at least 50 GB of free disk before installing packs; use a larger
external or shared volume if you plan to install Standard or PlusPF
classification databases.
The About window repeats the hardware floor used by the app: macOS 26
Tahoe or later, Apple Silicon, 16 GB RAM minimum, 32 GB RAM recommended
for metagenomics and assembly, and 100 GB free disk recommended for a
working set of tool packs, databases, and projects.

If your internal SSD is full or you want to keep large databases off the
boot drive, you can stage LGE projects and the database storage location to
an external SSD. Use an external SSD (Thunderbolt, USB-C, or USB 3); a
spinning external hard drive is too slow for the working set of reads,
alignments, and database indices that LGE produces and will make
operations that the docs describe as fast feel slow or unresponsive. The
storage-location settings live in the Plugin Manager's Databases tab.

## The packs you will meet in this manual

The table below lists the packs referenced by later chapters, the tools each
pack installs, and the chapters that need them. You do not need to install
everything upfront. Install a pack the first time a chapter asks for it.

| Pack | Tools | Used by |
|---|---|---|
| `read-mapping` | minimap2, BWA-MEM2, Bowtie2, BBMap, samtools | Map Reads chapter, Primer Trim chapter |
| `variant-calling` | iVar, LoFreq, Medaka, Clair3, bcftools, tabix, bgzip | Variants chapters |
| `gatk-core` | GATK4 | Human germline variants dry-run chapters |
| `phasing` | WhatsHap | Phased variant command plans |
| `classification-kraken2` | Kraken2, KrakenTools | Kraken2 classification chapter |
| `classification-esviritu` | EsViritu and its references | EsViritu classification chapter |
| `classification-taxtriage` | TaxTriage workflow tools | TaxTriage classification chapter |
| `classification-naomgs` | NAO-MGS pipeline tools | NAO-MGS classification chapter |
| `wastewater-surveillance` | Freyja | Freyja lineage demixing chapter |
| `assembly` | SPAdes, MEGAHIT, SKESA, Flye, Hifiasm | Assembly chapters |
| `read-qc` | fastp | Read QC chapter |
| `decontamination` | Deacon, RiboDetector | Host decontamination chapter |

A typical pack install moves between 100 MB and 300 MB across the wire and
takes 30 seconds to 3 minutes depending on your network. The first install
on a fresh machine is slower because LGE has to download and set up its
managed tool runner the first time. Subsequent installs are faster.

`gatk-core` is larger than the viral caller packs because GATK4 ships as a
Java toolkit with its own runtime; budget roughly 600 MB of installed
space for it. The [Human Germline Variants](../06-human-germline-variants/01-haplotype-caller.md)
chapter walks through how LGE invokes GATK and what is and is not yet
wired into the GUI for that workflow.

## Procedure

### Install a pack from the Plugin Manager

The Plugin Manager is the recommended way to install and update packs.
Open it from the menu bar at **Tools > Plugin Manager**, or with
`Cmd-Shift-B`. The window lists every available pack with a status badge:
**not installed**, **installed**, or **update available**.

<!-- planned: plugin-manager-window -->

Click **Install** next to a pack to start. Progress streams into the
window as LGE downloads the tools and sets them up. When the badge flips
to **installed**, you are done. You do not need to restart LGE; the next
workflow operation that asks for one of the pack's tools will find it.

To install several packs, click **Install** for each one. The packs are
independent, so they can install in parallel without interfering with
each other.

### Worked example: install read-mapping and variant-calling

Most variant-calling workflows in this manual need two packs together. In
the Plugin Manager, click **Install** next to `read-mapping`, then
**Install** next to `variant-calling`. The first install on a fresh
machine takes 1 to 3 minutes depending on your network because LGE also
sets up its managed tool runner the first time. The second install is
faster because the runner is already in place.

To verify, look at the Plugin Manager and confirm both packs show the
**installed** badge. Re-clicking **Install** on a pack that is already
installed performs an integrity check: LGE re-verifies the installed pack
and reports it is current. This is the recommended way to confirm an
install is intact after an interruption (closing the lid mid-install, a
network drop, an unexpected reboot).

<!-- planned: plugin-manager-installed -->

### Check database versions and update state

Reference databases are tracked separately from the tool packs. The
**Databases** tab in the Plugin Manager lists each installed database's
install date, current version, and whether LGE knows of a newer version.
An **Update Available** badge means the catalog version is newer than the
installed version. **Up to Date** means your local copy matches the
current catalog. From the same tab you can install a database, update it,
or remove it; LGE handles the storage location, the download, and the
integrity check.

## Interpretation

### What "already installed" means

When you re-click **Install** on a pack and LGE reports it as already
installed, the tools are present on disk and their integrity matches what
this version of LGE expects. A mismatch would trigger a re-install rather
than a silent skip, so an "already installed" message means the pack is
genuinely current.

### What a "missing tool" error looks like

When a workflow operation needs a tool from a pack you have not installed,
the operation fails fast with a message that names the missing tool and
the pack that provides it. For example, running Map Reads without the
`read-mapping` pack will surface an error like "missing tool: minimap2.
Install the `read-mapping` plugin pack." The fix is to install the named
pack and re-run the operation. The original input files and project state
are untouched; nothing was partially written.

If you see this error on a machine where you believe the pack is
installed, open the Plugin Manager and confirm the pack shows the
**installed** badge. If it does not, click **Install** and let LGE repair
the state in place. For deeper failures (network blocks, locked package
caches, an interrupted earlier install), see the
[Plugin packs and conda environments](../appendices/troubleshooting.md#plugin-packs-and-conda-environments)
section of the **Troubleshooting** appendix.

### Disk usage

A full set of the packs listed in the table above lands in the 1 to 3 GB
range, with classification tool packs the largest of the bunch.
Classification *databases* are the heavier items and are tracked
separately from the tool packs in the Plugin Manager's Databases tab;
those can run to tens of gigabytes for Standard or PlusPF. Project folders
never contain pack binaries, so a project archive stays small and
portable.

## Notes for shared workstations and lab administrators

This section is for IT staff and lab administrators setting up LGE on a
shared workstation. Routine LGE users do not need to read it.

On a shared workstation, an administrator can place LGE's tool packs and
reference databases on a larger shared volume so that all lab users share
one installation. LGE supports this by reading the `LUNGFISH_CONDA_ROOT`
environment variable; when it is set, every LGE process (GUI and CLI) uses
that location as the install root for packs and databases.

The recommended setup pattern:

1. The admin sets `LUNGFISH_CONDA_ROOT` in a shell startup file that lab
   users inherit, then opens LGE and installs the packs and databases
   from the Plugin Manager.
2. The admin leaves the install root readable and executable for lab
   users, but writable only by the admin account.
3. Routine users open LGE, see the packs and databases as
   **installed**, and run workflows; the Plugin Manager will not let them
   mutate a read-only root.

LGE's pack and database operations take an exclusive lock on the install
root, so a second install waits rather than corrupting the shared
environment. If a routine user tries to install into a read-only admin
root, LGE stops with `install root is read-only; reinstall as the admin
user`.

## Next

Continue to [Provenance and Reproducibility](08-provenance-and-reproducibility.md)
to learn how LGE records every operation, including which pack
versions ran, and how to export a workflow for sharing or publication.
