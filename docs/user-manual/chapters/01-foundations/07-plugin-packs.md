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
shots:
  - id: plugin-manager-window
    file: ../../assets/screenshots/01-foundations/07-plugin-packs/plugin-manager-window.png
    caption: "The Plugin Manager window on the Packs tab, showing the Required Setup section with every Third-Party Tools entry ready, the Read Mapping pack with all three mappers ready, and the Variant Calling pack with three of four callers ready (Clair3 needs install)."
  - id: plugin-manager-databases-tab
    file: ../../assets/screenshots/01-foundations/07-plugin-packs/plugin-manager-databases-tab.png
    caption: "The Plugin Manager window on the Databases tab, showing Kraken2 databases (some installed, others available to download), the EsViritu Viral DB, and the NCBI Taxonomy. Each row reports size, RAM requirement, install date, version, and whether an update is available."
illustrations: []
glossary_refs: [plugin-pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

Lungfish Genome Explorer (LGE) does not bundle every bioinformatics
tool. The viral genomics field moves fast, each tool updates on its own
schedule, and no single user ever needs all of them at once. Bundling
everything would mean a multi-gigabyte download, a slower release
cadence, and a near-certainty that something would be stale the day you
installed it. So LGE ships small and pulls in tools on demand.

A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of
related command-line tools, installed together because the chapters that
use one tend to use the rest. The `read-mapping` pack hands you four read
mappers, `minimap2`, `BWA-MEM2`, `Bowtie2`, and `BBMap`, plus `samtools`,
the workhorse that sorts, indexes, and queries BAM alignment files. The
`variant-calling` pack hands you four variant callers, iVar, LoFreq,
Medaka, and Clair3, alongside `bcftools` for working with VCF files and
the indexing utilities they depend on.

You install and update packs from the GUI, through `Tools > Plugin
Manager`, described below, and never need to know how they are laid out
on disk. The packs live in a hidden directory in your home folder and
are shared across every LGE project on the machine. Install a pack once
and every project sees it.

In practice, when a workflow chapter says "install the `read-mapping`
pack first," you open the Plugin Manager, click **Install** next to that
pack, and move on. Packs install fast and verify fast, and you do it just
once per machine.

## What you will learn

Finish this chapter and you can install one or more plugin packs from the
Plugin Manager window, list which packs are installed, recognise a
"missing tool" error from a workflow operation as nothing more than a
missing pack, and re-run an install to confirm a pack is current. You
will type no commands. The Plugin Manager handles the download, the
channel configuration, and the per-tool environment layout for you.

## System requirements

Plugin packs run on macOS 26 Tahoe or later, on Apple Silicon Macs. A
16 GB Mac handles the default viral, mapping, variant-calling, and
assembly examples in this manual. Broad metagenomics databases ask for
more memory, because tools such as Kraken2 load the active database
straight into RAM. Keep at least 50 GB of free disk before installing
packs, and reach for a larger external or shared volume if you plan to
install Standard or PlusPF classification databases.
The About window states the same hardware floor: macOS 26 Tahoe or later,
Apple Silicon, 16 GB RAM minimum, 32 GB RAM recommended for metagenomics
and assembly, and 100 GB free disk recommended for a working set of tool
packs, databases, and projects.

If your internal SSD is full, or you simply want large databases off the
boot drive, you can stage LGE projects and the database storage location
onto an external SSD. Use a genuine SSD over Thunderbolt, USB-C, or
USB 3. A spinning external hard drive is too slow for the working set of
reads, alignments, and database indices that LGE produces, and it will
make operations the docs call fast feel sluggish or stalled. The
storage-location settings live in the Plugin Manager's Databases tab.

## The packs you will meet in this manual

The table below lists the packs later chapters reference, the tools each
one installs, and the chapters that need them. There is no need to install
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

A typical pack install pulls 100 MB to 300 MB across the wire and
finishes in 30 seconds to 3 minutes, depending on your network. The first
install on a fresh machine runs slower, because LGE has to download and
set up its managed tool runner once. Every install after that is faster.

`gatk-core` runs larger than the viral caller packs, because GATK4 ships
as a Java toolkit with its own runtime. Budget roughly 600 MB of
installed space for it. The [Human Germline Variants](../06-human-germline-variants/01-haplotype-caller.md)
chapter walks through how LGE invokes GATK, and what is and is not yet
wired into the GUI for that workflow.

## Procedure

### Install a pack from the Plugin Manager

The Plugin Manager is the recommended way to install and update packs.
Open it from the menu bar at **Tools > Plugin Manager**, or with
`Cmd-Shift-B`. Three tabs run across the top. **Installed** lists every
tool LGE currently knows about. **Packs** holds the themed groups of
tools available to install. **Databases** holds the reference databases
that classification and other workflows depend on.

<!-- SHOT: plugin-manager-window -->
![The Plugin Manager on the Packs tab. The Required Setup section at the top shows every Third-Party Tool with a green Ready badge. Below it, optional packs (Read Mapping, Variant Calling) list each tool inside the pack and its individual status. Most tools here are Ready; Clair3 inside Variant Calling shows Needs install.](../../assets/screenshots/01-foundations/07-plugin-packs/plugin-manager-window.png)

Each pack expands to show the tools inside it, and every tool wears one
of four status labels. **Ready** means installed and working. **Needs
install** means not installed yet. **Needs reinstall** means installed
but failing its integrity check, which re-running the install will
repair. **Storage unavailable** means the external SSD or shared root the
install lives on is not currently mounted. When every tool in a pack
reads Ready, the pack as a whole is ready to use.

Click **Install** next to a pack to start, or **Install All** when
several tools in it are missing. Progress streams into the window as LGE
downloads the tools and sets them up. When every tool flips to **Ready**,
you are done. There is no need to restart LGE. The next workflow
operation that reaches for one of the pack's tools will find it.

To install several packs, click **Install** on each. The packs are
independent, so they install in parallel without stepping on one another.

Installing is reversible. Each optional pack that is already installed
shows a **Remove All** button in place of Install. Click it and LGE tears
down every managed environment the pack owns, then flips the pack back to
**Needs install**, ready to reinstall whenever a later chapter calls for
it. The Required Setup pack has no Remove All, since LGE leans on it to
run.

### Worked example: install read-mapping and variant-calling

Most variant-calling workflows in this manual need two packs together. On
the **Packs** tab of the Plugin Manager, click **Install** next to
`Read Mapping`, then **Install All** next to `Variant Calling`. On a
fresh machine the first install takes 1 to 3 minutes, depending on your
network, because LGE sets up its managed tool runner along the way. The
second install is quicker, the runner already in place.

To verify, look at the Plugin Manager and confirm every tool in both
packs shows the green **Ready** badge. Click **Install** again on a pack
that is already installed and LGE runs an integrity check, re-verifying
the tools and reporting them current. That is the recommended way to
confirm an install survived an interruption, whether you closed the lid
mid-install, dropped the network, or hit an unexpected reboot.

### Manage installed environments from the Installed tab

The **Installed** tab lists every managed environment LGE has built, one
per tool. Click a row to expand it and read the exact packages and their
versions inside, the quickest way to confirm what a given tool actually
pulled in. Each row also carries a **Remove** button that deletes that
single environment and all of its packages, finer-grained than the
pack-level Remove All on the Packs tab.

LGE keeps its own housekeeping honest too. An interrupted install or an
old plugin sometimes leaves behind an environment with a bare hexadecimal
hash name rather than a tool name. LGE hides these from the tool list and
gathers them into an **Orphaned Environments** row that reports how many
it found. Its **Remove** button clears them in one pass to reclaim disk.
Removing them is safe: nothing in the packs table depends on a hash-named
environment.

### Install a pack without internet access

An air-gapped or firewalled Mac cannot reach the tool channels, so LGE
lets you carry a pack across by hand. Every pack card on the **Packs** tab
shows two greyed command lines and a **Copy** button that places both on
the clipboard. On a networked Mac, run the first command to bundle the
pack into a single archive. Move that archive to the offline Mac and run
the second command to install from it:

```bash
lungfish conda export-pack --pack read-mapping --output ./read-mapping-conda-offline-pack.tgz
lungfish conda install --offline --from-bundle ./read-mapping-conda-offline-pack.tgz
```

The Copy button fills in whichever pack you are looking at, so the archive
name always matches its pack id. This is the one place in this chapter
where you type a command. Every other install path runs from the buttons
above.

### Check database versions and update state

Reference databases are tracked apart from the tool packs. The
**Databases** tab in the Plugin Manager lists every available database,
grouped by the tool that consumes it, Kraken2, EsViritu, and the rest.
Each row shows the database's size, its RAM requirement, its install
state or a **Download** action when it is not installed, the install
date, the version, and whether the local copy is **Up to date**.

<!-- SHOT: plugin-manager-databases-tab -->
![The Plugin Manager on the Databases tab. Kraken2 databases are listed first; the EuPathDB46, MinusB, PlusPF, PlusPF-16, PlusPF-8, Standard, and Standard-8 databases show a Download button (not installed), while Standard-16 and Viral show the green Installed badge with a Remove action. A "Recommended for your system" banner at the top suggests the PlusPF-16 database for a 48 GB Mac. The EsViritu Viral DB and NCBI Taxonomy are installed at the bottom.](../../assets/screenshots/01-foundations/07-plugin-packs/plugin-manager-databases-tab.png)

A "Recommended for your system" banner at the top of the Databases tab
points to the database that best fits your Mac's RAM. Any database whose
RAM requirement outstrips your system reads "(exceeds system RAM)"
inline, so you avoid loading it by mistake. From the same tab you
download a new database, update an existing one, or remove one to reclaim
disk. LGE handles the storage location, the download, and the integrity
check. While a database is downloading, its row shows a progress bar with
a **Cancel** button. Cancel stops the transfer and leaves the database
uninstalled, ready to start again later.

## Interpretation

### What "already installed" means

When you click **Install** again on a pack and LGE reports it already
installed, the tools are present on disk and their integrity matches what
this version of LGE expects. A mismatch would trigger a reinstall rather
than a silent skip, so "already installed" means the pack is genuinely
current.

### What a "missing tool" error looks like

When a workflow operation needs a tool from a pack you have not
installed, it fails fast with a message naming the missing tool and the
pack that provides it. Run Map Reads without the `read-mapping` pack, for
instance, and you get an error like "missing tool: minimap2. Install the
`read-mapping` plugin pack." The fix is simple: install the named pack
and re-run the operation. Your original input files and project state are
untouched, because nothing was partially written.

If this error shows up on a machine where you believe the pack is
installed, open the Plugin Manager and confirm every tool in the pack
reads **Ready**. If any tool reads **Needs install** or **Needs
reinstall**, click **Install**, or **Install All**, and let LGE repair
the state in place. For deeper trouble, such as network blocks, locked
package caches, or an interrupted earlier install, see the
[Plugin packs and conda environments](../appendices/troubleshooting.md#plugin-packs-and-conda-environments)
section of the **Troubleshooting** appendix.

### Disk usage

A full set of the packs in the table above lands in the 1 to 3 GB range,
with the classification tool packs the largest of the bunch. The
classification *databases* are the real weight, tracked separately in the
Plugin Manager's Databases tab, and they can run to tens of gigabytes for
Standard or PlusPF. Project folders never hold pack binaries, so a
project archive stays small and portable.

## Notes for shared workstations and lab administrators

This section is for IT staff and lab administrators setting up LGE on a
shared workstation. Routine users can skip it.

On a shared workstation, an administrator can place LGE's tool packs and
reference databases on a larger shared volume, so every lab user draws on
one installation. LGE reads the `LUNGFISH_CONDA_ROOT` environment
variable to make this work. Set it, and every LGE process, GUI and CLI
alike, uses that location as the install root for packs and databases.

The recommended setup pattern:

1. The admin sets `LUNGFISH_CONDA_ROOT` in a shell startup file that lab
   users inherit, then opens LGE and installs the packs and databases
   from the Plugin Manager.
2. The admin leaves the install root readable and executable for lab
   users, but writable only by the admin account.
3. Routine users open LGE, see the packs and databases as
   **installed**, and run workflows. The Plugin Manager will not let them
   mutate a read-only root.

LGE's pack and database operations take an exclusive lock on the install
root, so a second install waits its turn rather than corrupting the
shared environment. If a routine user tries to install into a read-only
admin root, LGE stops with `install root is read-only; reinstall as the
admin user`.

## Next

Continue to [Provenance and Reproducibility](08-provenance-and-reproducibility.md)
to learn how LGE records every operation, including which pack
versions ran, and how to export a workflow for sharing or publication.
