---
title: Plugin Packs
chapter_id: 01-foundations/07-plugin-packs
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 8
task: Install and verify Lungfish plugin packs from the command line.
tags: [foundations, plugin-pack, conda, micromamba, installation]
tools: []
entry_points:
  - "Tools > Plugin Manager (Cmd-Shift-B)"
  - "CLI: lungfish conda install"
shots: []
planned_shots:
  - id: plugin-manager-window
    caption: "The Plugin Manager window listing available and installed packs."
  - id: plugin-manager-installed
    caption: "Plugin Manager after read-mapping and variant-calling install, showing both packs marked installed."
illustrations: []
glossary_refs: [plugin-pack, conda, micromamba]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish does not bundle every bioinformatics tool. The viral genomics
ecosystem moves quickly, individual tools update on their own schedules,
and a single user almost never needs all of them at once. Bundling
everything would mean a multi-gigabyte download, a slower release cadence,
and a guarantee that something would be out of date the day you installed
it. So Lungfish ships small and pulls in tools on demand.

A **plugin pack** is a themed group of related command-line tools, installed
together because chapters tend to use them together. The `read-mapping` pack
gives you the mappers and `samtools`. The `variant-calling` pack gives you
the callers, `bcftools`, and the indexing utilities. Each pack lives in its
own per-tool conda environment under `~/.lungfish/conda` in your home
directory. Note the leading dot, and note that this is the home directory,
not the project folder. Tools are shared across every Lungfish project on
the machine; you install a pack once and every project sees it.

A short note on why conda and not pip. Bioinformatics tools accumulated
years of C, C++, Java, and R dependencies long before Python packaging
existed in its current form. `samtools` links against `htslib`, `htslib`
links against `libdeflate` and `libcurl`, and so on down a long chain of
compiled libraries. `pip` cannot manage non-Python compiled dependencies in
a portable way; conda can, and the bioconda channel hosts almost every
tool a viral genomicist would ever reach for. Lungfish uses
**micromamba**, a small standalone bootstrap that speaks the conda protocol
without needing a full Anaconda installation. The first pack you install
also installs the micromamba bootstrap into `~/.lungfish/conda`, which
takes an extra few seconds.

So what should you do with this? When a workflow chapter says "install the
`read-mapping` pack first," run the install command and move on. The packs
are quick to install and quick to verify, and you only do it once per
machine.

## What you will learn

By the end of this chapter you will be able to install one or more plugin
packs from the command line, list installed packs from the Plugin Manager
window, recognise a "missing tool" error from a workflow operation as a
missing-pack error, and re-run the install command to confirm a pack is
current. You will not need to type a single `conda` command. The
`lungfish conda` subcommand wraps the bootstrap, the channel configuration,
and the per-tool environment layout for you.

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

## The packs you will meet in this manual

The table below lists the packs referenced by later chapters, the tools each
pack installs, and the chapters that need them. You do not need to install
everything upfront. Install a pack the first time a chapter asks for it.

| Pack | Tools | Used by |
|---|---|---|
| `read-mapping` | minimap2, BWA-MEM2, Bowtie2, BBMap, samtools | Map Reads chapter, Primer Trim chapter |
| `variant-calling` | iVar, LoFreq, Medaka, bcftools, tabix, bgzip | Variants chapters |
| `gatk-core` | GATK4 | Human germline variants dry-run chapters |
| `classification-kraken2` | Kraken2, KrakenTools | Kraken2 classification chapter |
| `classification-esviritu` | EsViritu and its references | EsViritu classification chapter |
| `classification-taxtriage` | TaxTriage workflow tools | TaxTriage classification chapter |
| `classification-naomgs` | NAO-MGS pipeline tools | NAO-MGS classification chapter |
| `assembly` | SPAdes, MEGAHIT, SKESA, Flye, Hifiasm | Assembly chapters |
| `read-qc` | fastp | Read QC chapter |
| `decontamination` | Deacon, RiboDetector | Host decontamination chapter |

A typical pack install moves between 100 MB and 300 MB across the wire and
takes 30 seconds to 3 minutes depending on your network. The first install
on a fresh machine is slower because it also writes the micromamba
bootstrap and resolves the channel index for the first time. Subsequent
installs reuse the cached index.

`gatk-core` is larger than the viral caller packs because GATK4 is a Java
toolkit with its runtime dependencies. Lungfish pins it as
`bioconda::gatk4=4.6.2.0`, runs `gatk --version` as the smoke test, and
budgets roughly 600 MB of installed space for the environment. The current
`lungfish gatk` commands construct dry-run command lines only: they do not
execute GATK, create scientific outputs, or attach bundles. When execution
is added, the output bundle must record full Lungfish provenance for the
final stored payload, not just the staging command.

## Procedure

### Install a pack from the command line

The CLI is the fastest path and the one we recommend for the worked
examples below. From any terminal:

```bash
lungfish conda install --pack read-mapping
```

The command prints progress as micromamba resolves the environment,
downloads packages, and links them into place. When the command exits with
status `0`, the pack is ready. You do not need to restart Lungfish; the
next workflow operation that asks for `minimap2` or `samtools` will find
them.

To install several packs, run the command once per pack. The packs are
independent of each other, and parallel installs are safe.

### Install a pack from the Plugin Manager

The GUI equivalent lives in the menu bar at **Tools > Plugin Manager**, or
Cmd-Shift-B. The Plugin Manager window lists every available pack with a
status badge: not installed, installed, or update available. Click the
**Install** button next to a pack to start the same operation the CLI
runs. Progress streams into the window. When the badge flips to
**installed**, you are done.

<!-- planned: plugin-manager-window -->

The two paths are equivalent. Both write to `~/.lungfish/conda`. Both run
the same hash check on re-install. The Plugin Manager is convenient when
you are already in the app; the CLI is convenient when you are setting up
a machine.

### Worked example: install read-mapping and variant-calling

Most variant-calling workflows in this manual need two packs together.
Run the installs back to back:

```bash
lungfish conda install --pack read-mapping
lungfish conda install --pack variant-calling
```

The first run will probably take 1 to 3 minutes depending on your
connection, because it downloads the micromamba bootstrap on top of the
read-mapping tools. The second run is faster because the bootstrap is
already there and the channel index is cached.

To verify, re-run either command:

```bash
lungfish conda install --pack read-mapping
```

You should see output that mentions the pack is already installed and that
the hash matches; the command exits without re-downloading. This
**idempotent** behaviour is the recommended verification path. If you
prefer a list view, run:

```bash
lungfish conda list
```

which prints every installed pack and its on-disk version, or open
**Tools > Plugin Manager** and confirm both packs show the **installed**
badge.

<!-- planned: plugin-manager-installed -->

### Check database versions and update state

Reference databases are tracked separately from conda environments. The
Databases tab in Plugin Manager shows each installed database's install
date, current version, and whether the built-in catalog knows about a
newer version. The same information is available from the CLI:

```bash
lungfish conda db list
lungfish conda db info Standard-8
```

`db info` prints the database tool, local version, install date, last
updated date, available update, disk path, disk size, and RAM requirement.
An "available update" value means the catalog version is newer than the
installed version; "none" means the local copy matches the current catalog
or no newer version can be determined.

## Interpretation

### What "already installed" means

When a re-run reports a pack as already installed, two things have been
checked. First, the per-tool environments under `~/.lungfish/conda` exist
and contain the expected binaries. Second, the recorded hash for the pack
matches the hash Lungfish expects for this app version. A mismatch would
trigger a re-install rather than a silent skip, so an "already installed"
message means the pack is genuinely current.

### What a "missing tool" error looks like

When a workflow operation needs a tool from a pack you have not installed,
the operation fails fast with a message that names the missing tool and the
pack that provides it. For example, running Map Reads without the
`read-mapping` pack will surface an error such as "missing tool: minimap2.
Install the `read-mapping` plugin pack." The fix is to install the named
pack and re-run the operation. The original input files and project state
are untouched; nothing was partially written.

If you see this error on a machine where you believe the pack is installed,
check three things. The directory `~/.lungfish/conda` should exist. It
should be writable by your user. And `lungfish conda list` should name the
pack. If any of those is wrong, re-running the install will repair the
state in place. For deeper failures (network blocks, locked package
caches, channel resolution errors), see the **Troubleshooting** appendix
chapter on plugin pack install failures, planned at the back of the
manual.

### Disk usage and where it goes

Plugin packs accumulate at `~/.lungfish/conda` by default. A full set of
the packs listed in the table above lands in the 1 to 3 GB range, with
classification packs (which carry reference databases) responsible for most
of it. The directory is safe to delete when you want to start over; the
next install will recreate it. Project folders never contain pack binaries,
so a project archive stays small and portable.

On shared workstations, an administrator can place the conda root on a
larger shared volume and launch Lungfish with `LUNGFISH_CONDA_ROOT` set to
that directory:

```bash
export LUNGFISH_CONDA_ROOT=/shared/lungfish/conda
lungfish conda install --pack read-mapping
```

All managed tool lookup paths use the override while it is set. For a
shared lab machine, the recommended pattern is:

1. The admin user sets `LUNGFISH_CONDA_ROOT` and installs or updates packs.
2. The admin leaves the installed root readable and executable by lab users.
3. Routine users run workflows with the same `LUNGFISH_CONDA_ROOT`, but do
   not mutate the root.

Conda mutations take an exclusive `.install.lock` in the conda root. A
second install waits rather than corrupting the shared environment. If a
routine user tries to install into a read-only admin root, Lungfish stops
with `conda root is read-only; reinstall as the admin user`.

## Next

Continue to [Provenance and Reproducibility](08-provenance-and-reproducibility.md)
to learn how Lungfish records every operation, including which pack
versions ran, and how to export a workflow for sharing or publication.
