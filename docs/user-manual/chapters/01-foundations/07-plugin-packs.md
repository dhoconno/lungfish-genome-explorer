---
title: Plugin Packs
chapter_id: 01-foundations/07-plugin-packs
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 24
task: Install and verify Lungfish Genome Explorer plugin packs, experimental features, specialized workflows, container prerequisites, and reference databases.
tags: [foundations, plugin-pack, installation, databases, experimental, specialized-workflows, workflow-library, containers, docker, offline]
tools: []
parameters_refs: [classify.install-database]
entry_points:
  - Tools > Plugin Manager... (Cmd-Shift-B)
  - Tools > Workflows > Workflow Library...
  - Settings... (Cmd-,) > Advanced
  - "CLI: lungfish-cli conda packs"
  - "CLI: lungfish-cli conda db list"
  - "CLI: lungfish-cli debug container"
shots:
  - id: plugin-manager-window
    caption: "The Plugin Manager on the Packs tab, with the Required Setup section above the Optional Tools section and the Read Mapping card showing its three mappers."
  - id: settings-advanced-experimental
    caption: "The Advanced tab of Settings, showing the Show Experimental Features toggle and the warning printed beside it."
  - id: plugin-manager-wastewater-pack
    caption: "With Show Experimental Features turned on, the Plugin Manager Packs tab shows the experimental Wastewater Surveillance card, its Install All button, and the five tools it installs."
  - id: plugin-manager-offline-commands
    caption: "The offline strip at the foot of one pack card, showing the two greyed command lines and the Copy button beside them."
  - id: plugin-manager-installed-tab
    caption: "The Installed tab with one environment row expanded to list the packages and versions inside it, and the Check for Tool Updates button above the list."
  - id: plugin-manager-databases-tab
    caption: "The Databases tab, with installed databases beside ones offering a Download button, the recommended-database banner at the top, and the total storage readout at the foot."
illustrations: []
glossary_refs: [plugin-pack, conda, micromamba, required-setup-pack, managed-environment, post-install-hook, container, docker, workflow-library, offline-pack, experimental-features]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) does not carry every analysis tool inside the application. Tools update on their own schedules, no one person uses all of them, and bundling the lot would make the download enormous. So LGE installs tools on request.

A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of related tools installed together, because the chapters that need one tend to need the rest. Each tool is a command-line program, one with no window of its own, which LGE runs for you behind the scenes. Installing one never means you have to type anything. The `read-mapping` pack, for example, installs three read mappers, programs that place each sequencing read at the position on a reference genome it best matches. A fourth mapper, BBMap, comes with the required pack described next.

Names in this typeface, such as `read-mapping`, are the ids LGE uses for a pack. On screen the same pack shows a plain title, Read Mapping, and the table in [The packs, and what is in them](#the-packs-and-what-is-in-them) pairs every id with its title.

One pack is not optional. The Third-Party Tools pack sits in the Plugin Manager's Required Setup section, which is why other chapters call it the [Required Setup pack](../../GLOSSARY.md#required-setup-pack). It holds the seventeen everyday programs that most analyses in LGE rely on, and its card describes it as "Needed to run analyses. Projects open with the built-in viewers before it is installed." `samtools` and `bcftools`, which sort and query alignment and variant files, are in it. So are `fastp` and `Deacon`, which trim reads and remove human reads from a sample, BBMap, a general-purpose read mapper that sits inside the entry labelled `bbtools`, and Nextflow, the program that runs multi-step pipelines. The Welcome window offers to install it the first time you open LGE, with an **Install** button on its Required Setup card, and nothing is installed until you click it. You can also install it from the Plugin Manager. Every task chapter assumes it is there.

Installation is handled by [conda](../../GLOSSARY.md#conda), a package manager that installs scientific software along with the shared code it depends on. LGE drives conda through [micromamba](../../GLOSSARY.md#micromamba), a small, fast version of it, and you never touch either one. Every tool lands in a [managed environment](../../GLOSSARY.md#managed-environment) of its own, a private folder holding that tool and its shared code, so two tools that want different versions of the same code never collide. The whole collection sits in LGE's storage folder, a hidden folder in your home folder, with the tools in its `conda` folder and the databases in its `databases` folder. The `~` stands for your home folder. A Stable copy of LGE uses `~/.lungfish-stable` and a Preview copy uses `~/.lungfish`, as [Release channels](06-the-lungfish-project.md#release-channels) explains. The storage folder sits outside every project and every project shares it, so you install a pack once and every project sees it. When both copies of LGE live on one Mac, each keeps its own folder but the same tool or database is stored on disk only once. Tool packages are downloaded into a cache both copies share, `~/.lungfish-shared/conda/pkgs`, and a database the other copy already holds is copied as an APFS clone, which takes seconds and no extra space, instead of being downloaded again. The command line inside an app bundle uses that app's folder, so the Preview app's `lungfish-cli` sees what the Preview app installed.

Three other things in this chapter sit beside the packs. Reference databases, the large collections of known genomes that classification tools compare reads against, are downloaded separately on the Plugin Manager's Databases tab. A few pipelines run their tools inside containers through the separate Docker Desktop application, which LGE does not install for you. And a few specialized workflows, such as 12S amplicon matching, stay switched off until you turn them on in the Workflow Library.

## Why you would do this

Every task chapter in this manual names the pack it needs in `## Before you start`. That instruction is only useful once you know where the packs live and what "installed" looks like. Learning it once here means the rest of the manual can say "install the `assembly` pack" and move on.

A missing pack also does not look like a missing pack at first. It looks like an analysis that refuses to start, with a message about a tool you may never have heard of. This chapter turns that into a one-click fix.

The third reason is disk. Reference databases are large, some of them very large, and knowing which one your work needs before you download it is the difference between an 8 GB download and a 72 GB one.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](06-the-lungfish-project.md#procedure) shows. This chapter uses no practice data, and everything happens in the Plugin Manager window against your own Mac. You need an internet connection, and the two packs the procedure installs take a few minutes on a fast connection.

Check that your Mac meets the memory and disk figures in [System requirements](06-the-lungfish-project.md#system-requirements) before you download a large database. LGE recommends 100 GB of free disk for packs, databases, and projects. Nothing enforces that figure, but a download that runs out of room fails partway.

## Procedure

1. Open the Plugin Manager with **Tools > Plugin Manager...** (Cmd-Shift-B). Three tabs run across the top. **Installed** lists the managed environments LGE has built. **Packs** holds the packs you can install. **Databases** holds the reference databases that classification and read-removal tools read.

2. Look at the **Packs** tab. The **Required Setup** section holds the Third-Party Tools pack described above. The **Optional Tools** section below it holds one card per optional pack.

    <!-- SHOT: plugin-manager-window -->

3. Read the tools listed on a pack card. Every tool shows one of four status labels. **Ready** means installed and working. **Needs install** means not installed yet. **Needs reinstall** means installed but failing its integrity check, a test that the installed files are complete and undamaged, which running the install again repairs. **Storage unavailable** means the external drive the install lives on is unplugged. Two rows on the Third-Party Tools card are reference data rather than programs, and those read **Needs download** or **Needs refresh** instead. A pack is ready when every row inside it reads Ready.

4. Click **Install All** on the Read Mapping card. The Third-Party Tools card says **Install** instead, because it installs as one unit, and a card whose tools need repair says **Reinstall**. A card that is already fully installed shows no install button at all. Progress appears in the card as LGE downloads the tools and builds their environments. Keep the Mac awake until the card finishes, because a sleeping Mac pauses the download. There is no need to restart LGE afterwards.

5. Click **Install All** on the Variant Calling card. Packs are independent, so starting a second one is safe. LGE lets only one install write at a time, so the second waits for the first to finish. The first install on a new Mac is the slowest, usually a few minutes on a fast connection, because LGE sets up micromamba along the way.

Both packs should now read Ready on every tool. LGE runs the integrity check each time it reads a pack's status, so a pack that no longer passes after a closed lid, a dropped network, or a restart shows **Reinstall** again. An installed optional pack shows **Remove All** where Install was, and clicking it removes every environment the pack owns. The Third-Party Tools pack has no Remove All, since LGE needs it to run.

### Experimental packs and features

A few parts of LGE are marked experimental, which means they are still being tested and may change between releases. They stay hidden until you turn them on, so nobody meets one by accident. In practice, a result from an experimental pack deserves a second check before it goes into a report, and a command or setting it offers may be renamed in a later release.

To turn them on, choose **Settings...** (Cmd-,) from the application menu, the menu named after the app at the left of the menu bar, and click the **Advanced** tab. Turn on **Show Experimental Features**. The warning beside it says experimental features may be incomplete and are not intended for production scientific work.

<!-- SHOT: settings-advanced-experimental -->

Reopen the Plugin Manager. The three experimental packs, GATK Core, Variant Phasing, and Wastewater Surveillance, now appear as cards in the Optional Tools section, and they install with **Install All** like any other pack.

<!-- SHOT: plugin-manager-wastewater-pack -->

Turning the switch off again hides the experimental packs from the Plugin Manager, but it does not remove any you installed.

Install an experimental pack from the Plugin Manager. The command line's `lungfish-cli conda install --pack` accepts only the packs that show without the switch, and answers "Unknown tool pack" for the three experimental ids. The offline export in [Install a pack without internet access](#install-a-pack-without-internet-access) does accept them, so an experimental pack already installed on one Mac can be carried to another.

### Turning on a specialized workflow

A specialized workflow is a multi-step analysis built for one kind of study, such as MHC genotyping or 12S amplicon matching. LGE lists them in the Workflow Library, and all but one start switched off, because each needs outside programs from one or more packs. A switched-off workflow appears in its **Tools** submenu in pale grey with "(not enabled)" after its name, and choosing it offers to open the Workflow Library. Nothing is broken when you see that label.

1. Choose **Tools > Workflows > Workflow Library...**. The window lists Core Tools first and Specialized Workflows below them, grouped by kind of work.
2. Find the workflow's card under **Specialized Workflows**. Each card carries a Specialized badge, a one-line description, and one dependency row for each pack the workflow needs, reading **Ready** or **Needs install**.
3. If any row reads Needs install, click **Install Dependencies** on the card. LGE installs the missing packs and then switches the workflow on.
4. If every row reads Ready, turn on the card's **Enabled** switch instead.

The workflow's menu item now appears in ordinary type and opens its dialog. Three specialized workflows ship with LGE. miSeq amplicon MHC genotyping is on from the start. Full-length ONT MHC genotyping and 12S Amplicon Matching start switched off, and all three sit under **Tools > Genotyping**. Turning a switch off hides the workflow again without removing any pack. Workflow packages you link yourself appear under User Workflows in the same window, as [Running External Workflows](../08-workflows/03-running-external-workflows.md) shows.

### Tools that run in containers

A [container](../../GLOSSARY.md#container) is a packaged copy of a program together with everything it needs to run, so the program behaves the same on every machine. A few published pipelines run each of their steps inside containers, and LGE runs those containers through [Docker](../../GLOSSARY.md#docker) Desktop, a separate free application from Docker, Inc. The Plugin Manager does not install Docker Desktop. Download it from the Docker website and install it like any other Mac application.

Two pipelines in this manual need it, the Viral Recon SARS-CoV-2 pipeline and the TaxTriage classification pipeline. Their chapters say so in `## Before you start`. Workflows you add from the Workflow Library may need it too, and the Workflow Library shows which ones do. No other chapter needs Docker Desktop.

Start Docker Desktop before you click Run on one of these pipelines. It is running when its whale icon sits in the menu bar at the top right of the screen, and clicking the whale shows its status. TaxTriage tries to start Docker Desktop itself and waits up to 90 seconds for it. A run that still cannot reach Docker stops with a message saying Docker Desktop is not running, and [Containers and pipelines will not start](../appendices/troubleshooting.md#containers-and-pipelines-will-not-start) covers what to check next.

macOS 26 also has a container system of Apple's own, Apple Containerization. LGE's pipelines do not use it, and LGE never counts it when it checks whether a pipeline can run. The TaxTriage dialog's prerequisite row names Docker Desktop followed by Running, Not running, or Not installed, and only Running lets the run start.

To check from Terminal, `lungfish-cli debug container` reports whether the Docker program and the Docker background service it talks to are reachable, with their versions, and lists Apple Containerization separately as not used by pipelines. It exits with status 65 when Docker cannot be reached, the code the [CLI Reference](../appendices/cli-reference.md#exit-status) lists for a container problem.

```text
Docker (used by pipelines)
✓ Docker daemon reachable
```

### Install a pack without internet access

A Mac kept off the network, or one behind rules that block outside downloads as many hospital networks are, cannot reach the servers packs come from. LGE lets you carry a pack across by hand. Every pack card carries two greyed command lines and a **Copy** button that puts both on the clipboard.

<!-- SHOT: plugin-manager-offline-commands -->

Both commands are typed into the Terminal application, as [Reading an On the command line block](06-the-lungfish-project.md#reading-a-command-line-block) explains. Run the first on a Mac with internet access that already has the pack installed, to pack its tools into one archive file. Move the archive to the offline Mac and run the second there to install from it. The Copy button fills in the pack id of the card you took it from.

```bash
lungfish-cli conda export-pack --pack read-mapping --output ./read-mapping-conda-offline-pack.tgz
lungfish-cli conda install --offline --from-bundle ./read-mapping-conda-offline-pack.tgz
```

Each command has a second name that does the same job, and older notes and scripts may use either. `lungfish-cli conda offline-export` runs the same export as `conda export-pack`, and `lungfish-cli conda offline-install <folder>` runs the same install as `conda install --offline --from-bundle`. The export writes a folder, or a single archive when the output name ends in `.tar`, `.tgz`, or `.tar.gz`. Add `--overwrite` to the install to replace environments that already exist. Unlike `conda install --pack`, the export accepts the three experimental packs, so this is the one command-line route for them.

### Manage installed environments

The **Installed** tab lists every managed environment LGE has built, one per tool. Click a row to expand it and read the exact packages and versions inside. Each row has a **Remove** button that deletes that one environment.

<!-- SHOT: plugin-manager-installed-tab -->

**Check for Tool Updates…** sits above the list. It compares the tools installed on this Mac against the exact versions your copy of LGE expects, called the pinned dependency list, and reports anything that differs. The pinned list changes with each LGE release, so updating LGE and then checking for tool updates keeps the two in step.

An interrupted install sometimes leaves an environment behind named with a long string of letters and numbers rather than a tool name. LGE gathers these into an **Orphaned Environments** row that reports how many it found, and its **Remove** button clears them. Removing them is safe, since nothing depends on them.

## Settings

The Databases tab downloads, updates, and removes reference databases, and its five controls follow. Two of the databases, SILVA and Greengenes, are built on your own Mac from downloaded source sequences rather than fetched ready-made, which [The Databases tab](#the-databases-tab) explains. A word in angle brackets such as `<name>` marks a database name you type in its place.

**Download.** Fetches one database and unpacks it into LGE's storage folder, showing the download size, the memory the database needs, and a progress bar with a Cancel button. Nothing is downloaded until you ask, because the databases run from under half a gigabyte to seventy-two gigabytes. Download the one your work needs, and treat the banner's recommendation as the safe first choice, since it names the database that fits your Mac's memory. On the command line this is `lungfish-cli conda db download <name>`.

**Remove.** Deletes an installed database and frees its disk space, after a confirmation sheet that names it. Nothing is removed unless you ask, since a removed database has to be downloaded again from scratch. Remove one you no longer use, because the large collections take tens of gigabytes. On the command line this is `lungfish-cli conda db remove <name> --delete-files`.

**Update.** Replaces an installed database with the version named in LGE's pinned dependency list. Nothing is updated unless you ask, and SILVA and Greengenes, which are built locally, are reported as skipped. Update when the row says an update is available and you want your results to match the current pinned version. On the command line this is `lungfish-cli conda db update <name> --yes`.

**Refresh.** Reads the database list and the installed set again, so a database that arrived some other way shows up. The list loads once when you open the tab, which is why it can fall out of date while the window stays open. Use it when a download you started elsewhere has finished and the list still looks unchanged. On the command line this is `lungfish-cli conda db list`.

**Storage Settings....** Opens the setting that decides where LGE's storage folder lives, with the current folder and the total space in use shown along the foot of the tab. It points at `~/.lungfish-stable` for a Stable copy of LGE and `~/.lungfish` for a Preview copy by default, both of which LGE can always reach. Change it when the startup disk is too small for a large database and you want to keep databases on an external drive. There is no command-line equivalent for this setting.

## Reading the results

### The packs, and what is in them

Eleven optional packs can be installed from the Plugin Manager. Eight show all the time, and the three marked experimental appear only after you turn experimental features on, as [Experimental packs and features](#experimental-packs-and-features) shows.

| Pack id | Shown as | Approximate size | Tools |
|---|---|---|---|
| `read-mapping` | Read Mapping | 260 MB | minimap2, BWA-MEM2, Bowtie2 |
| `variant-calling` | Variant Calling | 260 MB | LoFreq, iVar, Medaka, Clair3 |
| `assembly` | Genome Assembly | 950 MB | SPAdes, MEGAHIT, SKESA, Flye, hifiasm |
| `metagenomics` | Metagenomics | 1.2 GB | Kraken 2, Bracken, EsViritu, RiboDetector |
| `full-length-mhc-genotyping` | Full-length MHC Genotyping | 650 MB | Savont, NCBI BLAST+ |
| `pcr-primer-design` | PCR Primer Design | 2.8 GB | Primer3, PrimalScheme, Olivar, varVAMP |
| `multiple-sequence-alignment` | Multiple Sequence Alignment | 120 MB | MAFFT |
| `phylogenetics` | Phylogenetics | 180 MB | IQ-TREE |
| `gatk-core` | GATK Core (experimental) | 600 MB | GATK4 |
| `phasing` | Variant Phasing (experimental) | 180 MB | WhatsHap |
| `wastewater-surveillance` | Wastewater Surveillance (experimental) | 1.5 GB | Freyja, iVar, Pangolin, Nextclade, minimap2 |

MHC in the genotyping pack's name stands for the major histocompatibility complex, the cluster of immune genes that varies more between individuals than any other part of the genome. The PCR Primer Design card spells one of its tools OliVar, while the tool's own authors and this manual write Olivar. PrimalScheme on that card is an LGE build of PrimalScheme 3, the third version of the program.

All eleven optional packs together come to about 8.7 GB, on top of the 2.7 GB Third-Party Tools pack. The PCR Primer Design pack alone is about 2.8 GB, because Olivar and varVAMP each install into a separate environment with its own supporting libraries, which measured about 1.1 GB and 0.8 GB when the two were added. Most people install two or three packs.

### What each pack is for

Most packs hold more than one tool for the same kind of job, because no single tool suits every kind of data. The table says what each pack's tools do and names the chapter that helps you pick among them, usually in a section called Choosing a tool.

| Pack | What its tools do | Where to choose among them |
|---|---|---|
| Read Mapping | Place each read where it best matches a reference genome, with three mappers here and BBMap from the Third-Party Tools pack, four in all | [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#choosing-a-tool) |
| Variant Calling | List the positions where a sample's reads differ from the reference, with LoFreq and iVar for Illumina reads and Medaka and Clair3 for Nanopore reads. bcftools, which calls genotypes in human samples, comes with the Third-Party Tools pack instead | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md#choosing-a-tool) and [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md#choosing-a-tool) |
| Genome Assembly | Rebuild a genome from reads alone, with SPAdes, MEGAHIT, and SKESA for short reads and Flye and hifiasm for long reads | [When to Assemble](../07-assembly/01-when-to-assemble.md#choosing-a-tool) |
| Metagenomics | Name the organisms in a mixed sample with Kraken 2 and Bracken or, for viruses, EsViritu. RiboDetector is also installed, but no operation in this release runs it | [What Is Read Classification](../06-classification/01-what-is-classification.md#choosing-a-tool) |
| Full-length MHC Genotyping | Cluster long MHC reads into consensus alleles with Savont and search unmatched ones against the allele library with BLAST+ | [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#choosing-a-tool) |
| PCR Primer Design | Design PCR primers, with Primer3 for a single assay and PrimalScheme, Olivar, and varVAMP for tiled schemes that cover a whole target, varVAMP also designing single and qPCR assays | [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md#choosing-a-tool) |
| Multiple Sequence Alignment | Line up related sequences column by column with MAFFT, which offers six strategies | [Aligning Sequences](../02-sequences/04-aligning-sequences.md#choosing-a-tool) |
| Phylogenetics | Build maximum-likelihood family trees from an alignment with IQ-TREE | [Building Trees](../02-sequences/05-building-trees.md#choosing-a-tool) |
| GATK Core | Call inherited variants in human samples with GATK4 | [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md#choosing-a-tool) |
| Variant Phasing | Work out which nearby variants sit on the same copy of a chromosome with WhatsHap | [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md#choosing-a-tool) |
| Wastewater Surveillance | Estimate the mix of SARS-CoV-2 lineages in a wastewater sample with Freyja, with iVar, Pangolin, Nextclade, and minimap2 alongside | [What Is Read Classification](../06-classification/01-what-is-classification.md#choosing-a-tool) |

A pack with a single tool, such as Phylogenetics, still leaves choices inside that tool, and its chapter covers them the same way. Ribosomal RNA removal, the job RiboDetector was built for, runs with Deacon from the Third-Party Tools pack, as [Decontamination](../03-reads/05-decontamination.md#choosing-a-tool) explains.

Most projects need only a few packs on top of the required one. A phylogeny of finished sequences, such as macaque mitochondrial genomes downloaded from NCBI, needs Multiple Sequence Alignment to line them up and Phylogenetics to build the tree. A bacterial genome assembled from its reads needs only Genome Assembly, since trimming and quality control run on the required pack's tools.

Some packs finish with extra work after the tools land. LGE calls these [post-install hooks](../../GLOSSARY.md#post-install-hook), small follow-up commands a pack declares for itself, such as fetching the list of named virus lineages Freyja compares a sample against. A pack that has hooks shows how many on its card, and resting the pointer on the count lists what they do.

### The Databases tab

<!-- SHOT: plugin-manager-databases-tab -->

The Databases tab groups its rows by the tool that reads them. Each row reports the database's size, the memory it needs while it runs, whether it is installed, the install date, the version, and whether an update is available. An installed row reads **Installed**, and one you have not downloaded shows a **Download** button in that place instead. A banner at the top reads "Recommended for your system" with your Mac's memory, and names the database that fits it. Any database that needs more memory than your Mac has reads "(exceeds system RAM)" beside its memory figure, so you do not choose one by mistake.

Thirteen databases are listed. Kraken 2, the classifier that reports which organism each read most likely came from, reads eleven of them.

| Database | Download size | Memory it needs | What it covers |
|---|---|---|---|
| Standard | 67 GB | 67 GB | Archaea, bacteria, viruses, plasmids, human, and vector sequence, the DNA used to carry inserts in the lab |
| Standard-8 and Standard-16 | 8 GB and 16 GB | 8 GB and 16 GB | The same collection as Standard, reduced to fit smaller Macs |
| PlusPF | 72 GB | 72 GB | Standard plus protozoa and fungi |
| PlusPF-8 and PlusPF-16 | 8 GB and 16 GB | 8 GB and 16 GB | PlusPF reduced the same way |
| Viral | 0.5 GB | under 1 GB | RefSeq viral genomes only, the smallest of the set |
| MinusB | 11 GB | 11 GB | Standard with the bacteria taken out, for a sample where bacteria would swamp what you want to find |
| EuPathDB46 | 34 GB | 34 GB | Eukaryotic pathogens such as *Plasmodium* and *Toxoplasma*, with 46 being the release number |
| SILVA | 12 GB | 24 GB | Ribosomal RNA genes from the SILVA collection, used to identify bacteria and archaea |
| Greengenes | 8 GB | 18 GB | Ribosomal RNA genes from the Greengenes collection |
| EsViritu Viral DB | 0.4 GB | 8 GB | A curated set of viral genomes read by EsViritu rather than Kraken 2 |
| NCBI Taxonomy | 0.1 GB | under 1 GB | The table that turns numeric taxon identifiers into names |

The reduced databases fit a smaller Mac at some cost in sensitivity. They keep fewer reference fragments, so a read the full Standard would have assigned to a species is more often left unassigned or reported only to its genus. On a 16 GB Mac that trade is the price of running the analysis at all.

SILVA and Greengenes are built on your Mac rather than downloaded ready-made, which the same **Download** button does after fetching their source sequences. Both come from collections of ribosomal RNA genes, the genes most often used to identify bacteria by sequence. Choose SILVA for the broader reference, and Greengenes when you are comparing results with earlier work that used it. Because they are built locally, Update skips them. Rebuild one by removing it and downloading it again.

Choose the EsViritu Viral DB when viruses are the whole question, and the Kraken 2 Viral database when you want viruses reported alongside everything else Kraken 2 covers.

Two more reference sets handle human and background sequence, and they do not appear on this tab. The Human Read Removal Data and Ribosomal RNA Removal Data entries are prebuilt indexes that Deacon uses to remove human reads and ribosomal RNA reads, and both arrive with the Third-Party Tools pack. Earlier releases also listed a Human Read Scrubber Database for NCBI's human read scrubber. LGE no longer uses it, and a request that names it runs Deacon with the Human Read Removal Data instead.

### What a missing tool looks like

Run an operation that needs a tool you have not installed and it stops before doing any work, naming the tool and the pack. Run a mapping without the `read-mapping` pack, for example, and you get "minimap2 is not installed. Install the read-mapping plugin pack first." Nothing was written, so your files and project are exactly as they were. Install the named pack and run the operation again. The command line stops the same way, with an error that says a required tool is missing and names it, and exits with status 126.

If that message appears when you believe the pack is installed, open the **Packs** tab and check the pack's tools. Anything reading **Needs install** or **Needs reinstall** is repaired by clicking Install All on that card. If a row on the **Installed** tab expands to an empty package list, the environment is present but empty, and Install All on the pack rebuilds it. For blocked networks or an install that died halfway, see [Tools and databases are missing](../appendices/troubleshooting.md#tools-and-databases-are-missing).

### Disk usage

The Third-Party Tools pack is about 2.7 GB, and all eleven optional packs add about 8.7 GB, for roughly 11 GB with everything installed. The databases are the real weight, and a single Standard or PlusPF collection at 67 GB or 72 GB outweighs every tool on the Mac put together. Projects never hold tools or databases, so a project stays small and portable however much you install.

## What good looks like

Four checks tell you the Mac is set up the way you think. Every tool in the packs you installed reads **Ready** on the Packs tab. The Installed tab lists an environment for each of those tools, and expanding one shows real package versions rather than an empty list. The Databases tab shows an install date and a version for each database you downloaded, with no "(exceeds system RAM)" beside the one you plan to use. And **Check for Tool Updates…** comes back with nothing to change.

When one of those disagrees, suspect the install before LGE. An interrupted download, an external drive unplugged mid-install, or a database added outside the window and never refreshed accounts for most of what looks like a broken feature.

## On the command line

The block below does what the procedure did, then downloads a database sized for this Mac. It works on your Mac rather than on a project, so it needs no `PROJECT` line. The commands and their flags are listed in [Tool packs, databases, and managed tools](../appendices/cli-reference.md#tool-packs-databases-and-managed-tools) in the CLI Reference, and [Reading an On the command line block](06-the-lungfish-project.md#reading-a-command-line-block) explains the notation.

```bash
lungfish-cli conda packs
lungfish-cli conda install --pack read-mapping
lungfish-cli conda install --pack variant-calling
lungfish-cli conda envs
lungfish-cli conda db recommend
lungfish-cli conda db download Viral
```

The command line lists and installs only the packs that show without the experimental switch, so install the three experimental packs from the Plugin Manager, or carry them from another Mac with the offline export.

## Next

Continue to [Provenance and Reproducibility](08-provenance-and-reproducibility.md) to learn how LGE records every operation it runs, including which tool versions were installed at the time.
