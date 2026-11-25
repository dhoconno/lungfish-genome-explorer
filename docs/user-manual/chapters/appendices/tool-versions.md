---
title: Tool Versions
chapter_id: appendices/tool-versions
audience: power-user
prereqs: []
estimated_reading_min: 17
task: Look up the exact version of every tool, pipeline, and database this Lungfish Genome Explorer release pins.
tags: [reference, tools, versions, provenance, linux]
tools: []
entry_points:
  - "CLI: lungfish-cli version --tools"
  - "CLI: lungfish-cli tools update --plan"
shots: []
illustrations: []
glossary_refs: [assembler, commit, conda, container, dependency-set, executable, exit-status, home-folder, micromamba, nextflow, pinned, plugin-pack, provenance-sidecar, repository, tool-lock-manifest]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-tool-versions"></a>

## What it is

Lungfish Genome Explorer (LGE) runs outside programs to do the computing, such as minimap2, which places reads on a reference, and Kraken 2, which assigns each read to the organism it probably came from. This appendix covers every tool, [pipeline](../../GLOSSARY.md#pipeline), and database that one release of LGE pins, or fixes, to an exact version, and nothing else. Five tables follow, for the tools every copy of LGE has, the tools that arrive with a [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, the tools of a run on a Linux machine, two whole pipelines, and the reference databases. A [reference genome](../../GLOSSARY.md#reference-genome) you choose yourself is not listed.

The tables say what the newest release this manual describes pins, read from that release's tool lock. Your own machine can hold an older installed version, because a pack downloaded months ago does not update itself. A methods section should be written from the run's own record. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file. To read it, select the result and open the **Provenance** tab of the [Inspector](../../GLOSSARY.md#inspector), where **Run Summary** names the tool, and a **Step Tools** row, when one shows, lists each other program the run used with its version, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows. **File > Export > Provenance > Methods Section…** writes a [draft methods section](../../GLOSSARY.md#methods-export) that lists each tool and its version.

Two windows show versions. The About window, opened with **About Lungfish Genome Explorer** in the application menu at the left of the menu bar (**About Lungfish Genome Explorer Preview** in a Preview build), prints the app version, the dependency set, and the tool versions this release pins. The Plugin Manager's Installed tab, at **Tools > Plugin Manager…** (Cmd-Shift-B), lists the exact packages inside each tool's environment on your Mac, the private folder that holds it.

Almost every number on this page is read out of one file, LGE's [tool lock manifest](../../GLOSSARY.md#tool-lock-manifest), which names one exact version of every outside program LGE depends on, so two people installing the same release get the same programs. It lives inside the app, in the `ManagedTools` folder of its `LungfishGenomeBrowser_LungfishWorkflow.bundle` resource folder, and in a source checkout, the copy of LGE's source code, at `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. Two files beside it supply the rest. `third-party-tools-lock.linux-64.json` pins the tools of a Linux run, and `bundled-payloads.json` lists the programs that ship inside the app itself. You do not need to open any of them, since the tables here are their contents.

A version fixed this way is [pinned](../../GLOSSARY.md#pinned), locked to one exact number. The whole pinned collection is called the [dependency set](../../GLOSSARY.md#dependency-set). This appendix reflects dependency set `2026.2`, dated 2026-08-18. Later releases added tools to this set without renaming it, so an older copy that reports 2026.2 can lack a tool listed here. Name the dependency set beside the app version in a methods section, as in the sentence below. For a finished analysis, open the **Runtime** block of that run's own record and copy the release for `<version>` and the dependency set from it, since the About window shows the copy you have now.

```
Analyses were run in Lungfish Genome Explorer <version> (dependency set 2026.2),
using minimap2 2.31 and Kraken 2 2.17.1 with the Standard-8 database, version
20260626, installed on <date>.
```

Copy each version string exactly as the table prints it. A record may show the whole package build instead, such as `bioconda::bcftools=1.24=h6bd33b9_2`, where `1.24` is the version this page prints.

## Reading the tables

The Environment column names the [managed environment](../../GLOSSARY.md#managed-environment), the private folder that holds one tool and the code libraries it needs. Ignore it unless a provenance record names an environment and you want to know which tool it belongs to. [Manage installed environments](../01-foundations/07-plugin-packs.md#manage-installed-environments) covers these folders.

The Pack column in the second table gives the id of the pack a tool arrives with, which [The packs, and what is in them](../01-foundations/07-plugin-packs.md#the-packs-and-what-is-in-them) pairs with the title the Plugin Manager shows.

The License column copies the lock's own `license` field without interpreting it. The one exception is micromamba, whose license comes from `bundled-payloads.json` because the lock records none for it. Citing a tool is not redistributing it, so read a license text only if you plan to ship the program itself.

The Executables column names the program files, or [executables](../../GLOSSARY.md#executable), that show up in a provenance record, which often differ from the tool's display name, as IQ-TREE's `iqtree3` does. Six rows list `python`, because they are code libraries that run inside the Python interpreter, and the Python version is one of the packages the Installed tab lists for their environment.

## Tools installed with every copy of LGE

These twenty tools are the ones every copy of LGE needs. Nineteen arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE, as [First launch and the Welcome window](../01-foundations/06-the-lungfish-project.md#first-launch-and-the-welcome-window) shows. The twentieth is **[micromamba](../../GLOSSARY.md#micromamba)**, the small package manager, the program that downloads and installs all the others. It ships inside the app, and the lock keeps its version and checksum in a separate entry.

| Tool | Version | Environment | License | Executables |
|---|---|---|---|---|
| micromamba | 2.9.0-0 | (bundled in the app) | BSD-3-Clause | `micromamba` |
| nextflow | 26.04.6 | `nextflow` | Apache-2.0 | `nextflow` |
| snakemake | 9.25.2 | `snakemake` | MIT | `snakemake` |
| bbtools | 40.02 | `bbtools` | BSD-3-Clause-LBNL | `clumpify.sh`, `bbduk.sh`, `bbmerge.sh`, `repair.sh`, `tadpole.sh`, `reformat.sh`, `bbmap.sh`, `mapPacBio.sh`, `java` |
| fastp | 1.3.6 | `fastp` | MIT | `fastp` |
| deacon | 0.16.0 | `deacon` | MIT | `deacon` |
| samtools | 1.24 | `samtools` | MIT | `samtools` |
| bcftools | 1.24 | `bcftools` | GPL | `bcftools` |
| htslib | 1.24 | `htslib` | MIT | `bgzip`, `tabix` |
| seqkit | 2.13.0 | `seqkit` | MIT | `seqkit` |
| cutadapt | 5.2 | `cutadapt` | MIT | `cutadapt` |
| trim_galore | 2.3.0 | `trim_galore` | GPL-3.0-only | `trim_galore` |
| vsearch | 2.31.0 | `vsearch` | GPL-3.0-or-later OR BSD-2-Clause | `vsearch` |
| pigz | 2.8 | `pigz` | Zlib | `pigz` |
| zstd | 1.5.7 | `zstd` | BSD-3-Clause OR GPL-2.0-only | `zstd` |
| xz | 5.8.3 | `xz` | 0BSD AND LGPL-2.1-or-later AND GPL-2.0-or-later | `xz` |
| sra-tools | 3.4.1 | `sra-tools` | Public Domain | `prefetch`, `fasterq-dump` |
| ucsc-bedgraphtobigwig | 482 | `ucsc-bedgraphtobigwig` | `Varies; see https://genome.ucsc.edu/license` | `bedGraphToBigWig` |
| pysam | 0.24.0 | `pysam` | MIT | `python` |
| openpyxl | 3.1.5 | `openpyxl` | MIT | `python` |

Two version numbers are written in an unusual form and are correct as printed. bedGraphToBigWig counts by build number rather than by a dotted release, so a bare `482` is the whole version. The micromamba version carries a trailing `-0`, the packaging revision of that build. Copy either one whole.

The bcftools cell reads a bare `GPL` because the lock records that license loosely, and it is copied as found.

The table prints the lock's own identifiers, so `bbtools` here is `BBTools` elsewhere. Either spelling identifies the tool, but a methods section reads better with its published name, which the [Tool Bibliography](bibliography.md) prints for each tool it lists.

Five rows do work you may not associate with a named tool. pysam is a Python library that reads BAM files, the files of aligned reads, and a small script in the amplicon genotyping pipeline uses it to filter those reads. openpyxl writes the genotyping workbooks, which are Excel files. zstd unpacks and writes `.zst` compressed files and xz unpacks `.xz` files, so importing either kind, or exporting a `.zst` file, needs no other software on the Mac. micromamba installed every other tool on this page. A methods section names only the programs your run's record names.

The app also carries a Linux kernel boot image, version 6.12.28, and a matching start-up file system for Apple's own container system, Apple Containerization, which `bundled-payloads.json` lists. LGE's container diagnostics report Apple Containerization as not used by pipelines, so you never cite either file.

## Tools installed by a plugin pack

None of these tools is on a machine that has not installed its pack. The lock pins thirty-three tools across thirteen packs. [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows how to install a pack by the id in the Pack column. Three packs, `gatk-core`, `phasing`, and `wastewater-surveillance`, are experimental, which means still being tested, so a result from one deserves a second check before it goes into a report, and their cards appear only after you turn on **Show Experimental Features** on the **Advanced** tab of **Settings…**, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. The `wastewater-surveillance` pack also installs Pangolin and Nextclade, which the lock does not pin, so they have no row here. A version you find in a provenance sidecar is what ran, whatever this machine holds today.

| Pack | Tool | Version | Environment | License | Executables |
|---|---|---|---|---|---|
| `read-mapping` | minimap2 | 2.31 | `minimap2` | MIT | `minimap2` |
| `read-mapping` | bwa-mem2 | 2.3 | `bwa-mem2` | MIT | `bwa-mem2` |
| `read-mapping` | bowtie2 | 2.5.5 | `bowtie2` | GPL-3.0 | `bowtie2`, `bowtie2-build` |
| `full-length-mhc-genotyping` | savont | 0.6.3 | `savont` | MIT | `savont` |
| `full-length-mhc-genotyping` | blast | 2.16.0 | `blast` | Public Domain | `blastn` |
| `pcr-primer-design` | primer3 | 2.6.1 | `primer3` | GPL-2.0-or-later | `primer3_core` |
| `pcr-primer-design` | primalscheme3 | 3.3.0+lge.5 | `primalscheme3` | GPL-3.0 | `primalscheme3` |
| `pcr-primer-design` | olivar | 1.3.3 | `olivar` | GPL-3.0-or-later | `olivar` |
| `pcr-primer-design` | varvamp | 1.3.2 | `varvamp` | GPL-3.0-or-later | `varvamp` |
| `variant-calling` | lofreq | 2.1.5 | `lofreq` | MIT | `lofreq` |
| `variant-calling` | ivar | 1.4.4 | `ivar` | GPL-3.0-or-later | `ivar` |
| `variant-calling` | medaka | 2.2.2 | `medaka` | MPL-2.0 | `medaka` |
| `variant-calling` | clair3 | 2.0.2 | `clair3` | BSD-3-Clause | `run_clair3.sh` |
| `gatk-core` | gatk4 | 4.6.2.0 | `gatk-core` | BSD-3-Clause | `gatk` |
| `phasing` | whatshap | 2.3 | `phasing` | MIT | `whatshap` |
| `assembly` | spades | 4.3.0 | `spades` | GPL-2.0-only | `spades.py` |
| `assembly` | megahit | 1.2.9 | `megahit` | GPL-3.0 | `megahit` |
| `assembly` | skesa | 2.5.1 | `skesa` | Public Domain | `skesa` |
| `assembly` | flye | 2.9.6 | `flye` | BSD | `flye` |
| `assembly` | hifiasm | 0.25.0 | `hifiasm` | MIT | `hifiasm` |
| `multiple-sequence-alignment` | mafft | 7.526 | `mafft` | BSD-3-Clause | `mafft` |
| `phylogenetics` | iqtree | 3.1.3 | `iqtree` | GPL-2.0-or-later | `iqtree3` |
| `metagenomics` | kraken2 | 2.17.1 | `kraken2` | GPL-3.0-or-later | `kraken2`, `kraken2-build` |
| `metagenomics` | bracken | 3.1, reports 3.0.1 | `bracken` | GPL-3.0 | `bracken`, `bracken-build` |
| `metagenomics` | esviritu | 1.3.3 | `esviritu` | MIT | `EsViritu` |
| `metagenomics` | ribodetector | 0.3.3 | `ribodetector` | GPL-3.0-or-later | `ribodetector_cpu` |
| `wastewater-surveillance` | freyja | 2.0.3 | `freyja` | BSD-2-Clause | `freyja` |
| `rna-seq` | salmon | 2.11.0 | `salmon` | BSD-3-Clause | `salmon` |
| `rna-seq` | gffread | 0.12.9 | `gffread` | MIT | `gffread` |
| `single-cell` | scanpy | 1.11.5 | `sc-embed` | BSD-3-Clause | `python` |
| `single-cell` | python-igraph | 1.0.0 | `sc-embed` | GPL-2.0-or-later | `python` |
| `single-cell` | leidenalg | 0.12.0 | `sc-embed` | GPL-3.0-or-later | `python` |
| `single-cell` | umap-learn | 0.6.0 | `sc-embed` | BSD-3-Clause | `python` |

LoFreq rejects the usual `--version` flag, the option most programs print their version with, so LGE asks it with the `version` subcommand, and a LoFreq provenance record names the version rather than an error message. Where a record reads `unknown` for a tool's version, it holds no readable version, so cite the Installed tab or this table and say which you used.

The Bracken row needs care. The only [conda](../../GLOSSARY.md#conda) build of Bracken for Apple Silicon Macs lacks Bracken's main program, so LGE builds Bracken from the source code of release 3.1, which Bracken's authors publish, instead of installing it from conda. The lock file also carries a version field of 1.0.0 for Bracken, but that is only a fallback pin, and a fresh install never uses it. The `bracken` script in release 3.1 still reports its own version as 3.0.1, but LGE never asks the program. It records the 3.1 source build it installed, so the provenance record of a Bracken run says 3.1. Write Bracken 3.1 in a methods section and add that its version flag prints 3.0.1, so a reader who runs it can see why.

Five environments install from an exact list of packages kept inside LGE, so every Mac receives the same builds. They are PrimalScheme3, Olivar, varVAMP, EsViritu, and the one `sc-embed` environment that the four Single-Cell Analysis tools share. The other environments pin the tool's own version and build and leave conda to pick the libraries beneath it when it installs, so those libraries can differ between installs made months apart, and the Installed tab lists the ones your Mac holds.

Two entries name the pack rather than the tool in their Environment column. GATK4 installs into an environment called `gatk-core` and WhatsHap into one called `phasing`, so a provenance record naming either environment is naming the pack. The primalscheme3 version carries the suffix `+lge.5`, which marks [PrimalScheme3-LGE](https://github.com/dhoconno/primalscheme3-lge), a build LGE maintains on top of PrimalScheme 3.3.0, so copy it whole and name PrimalScheme3-LGE in a methods section, since its results can differ from the published PrimalScheme's.

The umap-learn license is the one in the umap-learn repository's own license file. conda-forge labels the package BSD-2-Clause, and LGE records the repository's BSD-3-Clause.

## Tools of a run on a Linux machine

A step can run on a Linux machine or an HTCondor pool, a system that shares jobs across many computers, instead of your Mac, as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) shows. A record of such a step shows a **Version and build** row, as [A run on a Linux machine](../01-foundations/08-provenance-and-reproducibility.md#a-run-on-a-linux-machine) shows. That step uses the programs inside a tool image, a single file that holds the programs and everything they need, run as a [container](../../GLOSSARY.md#container). The image is built from the second lock, `third-party-tools-lock.linux-64.json`, under the same dependency set, 2026.2.

| Tool | Version | Environment | License | Executables |
|---|---|---|---|---|
| bbtools | 40.02 | `lge-tools` | BSD-3-Clause-LBNL | `clumpify.sh`, `bbduk.sh`, `bbmerge.sh`, `repair.sh`, `tadpole.sh`, `reformat.sh`, `bbmap.sh`, `mapPacBio.sh`, `java` |
| fastp | 1.3.6 | `lge-tools` | MIT | `fastp` |
| deacon | 0.16.0 | `lge-tools` | MIT | `deacon` |
| htslib | 1.24 | `lge-tools` | MIT | `bgzip`, `tabix` |
| seqkit | 2.13.0 | `lge-tools` | MIT | `seqkit` |
| trim_galore | 2.3.0 | `trim_galore` | GPL-3.0-only | `trim_galore` |
| pigz | 2.8 | `lge-tools` | Zlib | `pigz` |
| star | 2.7.11b | `rnaseq` | GPL-3.0-or-later | `STAR` |
| salmon | 2.11.0 | `rnaseq` | BSD-3-Clause | `salmon` |
| subread | 2.1.1 | `rnaseq` | GPL-3.0-only | `featureCounts` |
| umi_tools | 1.1.6 | `rnaseq` | MIT | `umi_tools` |
| star273a | 2.7.3a | `star273a` | GPL-3.0-or-later | `STAR` |

Two versions of STAR, the program that places RNA-seq reads on a genome, are pinned. STAR 2.7.11b is the default, and the older 2.7.3a is chosen with `--star 2.7.3a` on `lungfish-cli rnaseq index-plan`, a step with no window route that runs from [Terminal](../../GLOSSARY.md#terminal), as [Before you type anything](cli-reference.md#before-you-type-anything) and [Finding the program](cli-reference.md#finding-the-program) show. The two sit in separate environments, so a record that names the `star273a` environment ran 2.7.3a. Every tool here that also appears in the Mac tables carries the same version in both.

## Pinned external pipelines

A pipeline is a program that runs many separate tools in a fixed order. LGE does not install these two into conda environments. It fetches each from its public **[repository](../../GLOSSARY.md#repository)**, the folder of files a project publishes on GitHub together with the history of every change to it, at one exact revision. It then runs the pipeline through **[Nextflow](../../GLOSSARY.md#nextflow)**, the program that executes multi-step pipelines and the same tool the first table lists.

A revision is named one of two ways, and the table shows both. A **[commit](../../GLOSSARY.md#commit)** identifier is the forty-character string a version-control system gives one saved snapshot of a repository. A release tag is a short name a maintainer attached to a snapshot.

| Pipeline | Repository | Release | Revision the lock pins |
|---|---|---|---|
| TaxTriage | `jhuapl-bio/taxtriage` | v3.3.8 | `e10bfebda32a62711f38a4e23ab03b61725a9675` |
| Viral Recon | `nf-core/viralrecon` | 3.0.0 | `395079f1d24dce731ac22e03d7a5e71f110103fc` |

The difference between the two matters if you need to reproduce a run exactly. A commit names one unchangeable snapshot. A maintainer is able to move a tag to a different snapshot, though this is rare. The lock pins both pipelines by commit, so write the full commit into your methods section beside the release name, because **Step Tools** shows only its first seven characters.

Most readers should leave both pinned. To run a different TaxTriage revision, add `--revision` and the revision you want to `lungfish-cli taxtriage run`, for example `--revision v3.3.7`. There is no window route for this, so the TaxTriage revision can only be changed from the command line.

## Reference databases

A classification result depends on its database as much as on its classifier, so a Kraken 2 report is not reproducible without the database version. The lock lists sixteen databases, and only the last two rows are checked against a recorded checksum.

The Source policy column is the lock's own word for where each database comes from, and it changes how much the version string can be trusted. `unpinnedArchive` means LGE downloads a named archive, one compressed download file, from a public server, where the version string in the table is the only identifier and nothing checks that the archive's contents have not changed since, so record the install date the Plugin Manager's Databases tab shows beside the name and version, and for an EsViritu or TaxTriage run the `databaseDigest` in **Invocation & Options**. `pinnedArchive` means LGE downloads one named file and checks it against the SHA-256 checksum and size the lock records before it installs the file, so the version is backed by the file's contents. `liveSnapshot` means the data is fetched fresh and is not fixed at all, which the warning under the table explains. `localBuild` means LGE builds the database on your machine from a public reference collection rather than downloading a finished one, so its version names how it was built and not which release went in. `bundledPayload` is the lock's label for the Human Read Removal Data, which LGE also checks against a recorded checksum and size. Despite the label, the file is not inside the app. It is downloaded into LGE's storage folder, the folder that holds its tools and databases, the first time it is needed, or with `lungfish-cli conda db install-managed`.

The Kraken 2 names carry a number suffix, as in Standard-8 and PlusPF-16, and that number is roughly the RAM, or working memory, in gigabytes the database needs while it runs, not its size on disk. Standard and PlusPF with no suffix are the full-size builds. A capped build is trimmed to fit its RAM budget, so it can classify the same read differently from the full one, and a methods section must name the database exactly, as Standard-8 and never as Standard. PlusPF adds protozoa and fungi to Standard, MinusB is Standard without bacteria, and EuPathDB46 holds eukaryotic pathogens. Your own run's provenance sidecar names which one it used, and the Plugin Manager's Databases tab shows which ones this machine holds.

| Database | Tool | Name | Version | Source policy |
|---|---|---|---|---|
| `kraken2-standard` | kraken2 | Standard | 20260626 | unpinnedArchive |
| `kraken2-standard-8` | kraken2 | Standard-8 | 20260626 | unpinnedArchive |
| `kraken2-standard-16` | kraken2 | Standard-16 | 20260626 | unpinnedArchive |
| `kraken2-pluspf` | kraken2 | PlusPF | 20260626 | unpinnedArchive |
| `kraken2-pluspf-8` | kraken2 | PlusPF-8 | 20260626 | unpinnedArchive |
| `kraken2-pluspf-16` | kraken2 | PlusPF-16 | 20260626 | unpinnedArchive |
| `kraken2-viral` | kraken2 | Viral | 20260626 | unpinnedArchive |
| `kraken2-minus-b` | kraken2 | MinusB | 20260626 | unpinnedArchive |
| `kraken2-eupathdb46` | kraken2 | EuPathDB46 | 20230407 | unpinnedArchive |
| `esviritu-viral-v3` | esviritu | EsViritu Viral DB | v3.2.4 | unpinnedArchive |
| `ncbi-taxonomy` | ncbi-taxonomy | NCBI Taxonomy | live | liveSnapshot |
| `kraken2-special-silva` | kraken2 | SILVA | kraken2-special-v1 | localBuild |
| `kraken2-special-greengenes` | kraken2 | Greengenes | kraken2-special-v1 | localBuild |
| `human-scrubber` | sra-human-scrubber | Human Read Scrubber Database | 20260706v2 | unpinnedArchive |
| `deacon-panhuman` | deacon | Human Read Removal Data | panhuman-1 | bundledPayload |
| `deacon-ribokmers` | deacon | Ribosomal RNA Removal Data | bbmap-ribokmers-k31w15 | pinnedArchive |

**Warning about the NCBI Taxonomy row.** Its version is the word `live`, meaning it is not pinned at all. LGE reads it, if it is installed, to turn a taxon number into a name when you check a hit with BLAST, so the same read can be assigned a different species name in a run made a month later, and a methods section must therefore record the date you ran the classification rather than a taxonomy version.

Your provenance sidecar records that date for you, which is one more reason to write a methods section from the sidecar rather than from this page.

Three of these version strings are dates written as year, month, and day, so `20260626` is 26 June 2026 and `20230407` is 7 April 2023. For the Kraken 2 rows the date comes from the archive's file name, so it dates the published index and not your download. `20260706v2` is such a date followed by `v2`, which is part of NCBI's own file name. The rest are names. Copy whichever kind you have exactly as it appears here.

The last two rows are reference data rather than searchable databases in the usual sense, and they are not on the Databases tab. Deacon uses them to recognize and discard host reads, meaning reads from the person or animal the sample came from rather than from the organism you are studying, and to discard ribosomal reads the same way. Remove Human Reads uses the Human Read Removal Data, as [Decontamination](../03-reads/05-decontamination.md#remove-human-reads) explains, and not the Human Read Scrubber Database, which belongs to NCBI's `sra-human-scrubber` program, one the lock does not pin as a tool. The Ribosomal RNA Removal Data is about 10 MB and downloads the first time an operation needs it.

## Two checks before you cite a number

First, confirm your own copy reports this dependency set. Open the About window, as above, and read the line beginning "Dependency set". This check needs no terminal. If your copy reports a different dependency set, or is older than the newest release this manual describes, the numbers here may not be the numbers you ran, so take the versions from your run's provenance record instead.

Second, confirm the machine has the pinned versions installed. The window route is the **Check for Tool Updates…** button at the top of the Plugin Manager's Installed tab, which either reports that the tools are up to date or opens the Update Tools sheet, a list of the tools and databases that differ from what your copy expects. The command-line form is `lungfish-cli tools update --plan`, which prints the outstanding work without doing any of it and exits with [exit status](../../GLOSSARY.md#exit-status) 10 when work is pending and 0 when the machine matches the lock.

Updating changes what later runs use and nothing else. The sheet's **Update** button rebuilds each tool environment you leave ticked at the pinned version, so the older copy is gone from your Mac, and it updates the required databases and any others you tick. It never opens a project, so a finished result keeps its provenance record, which still names the version that ran. A rerun after an update uses the new version, and a new version can change a result, as a different database does for a classifier.

The lock also carries a list of retired environments, removed from the pinned set so an upgrade can clean them up. That matters only when you are upgrading, and in dependency set 2026.2 the list is empty, so this release retires nothing. When a set does retire one, the sheet's **Remove retired tools** box starts ticked, and updating with it ticked deletes that tool from your Mac, while a result that used it keeps its record.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it. It uses the same storage folder as the app it ships inside, and it reads the tool lock inside that app, so the versions it prints are the ones that release pins, not a list of what your Mac holds.

```bash
lungfish-cli version --tools
```

It prints the app version, the dependency set with its date, and then the first table of this appendix, in five columns headed Tool, Version, Source, Environment, and Executables. Its first lines are these, with the release number in place of `<version>`. The BBTools executables line is cut short here to fit the page, and the real output continues past the third row with the remaining seventeen tools.

```
Lungfish <version>
Dependency set: 2026.2 (2026-08-18)

Bundled and Managed Tools
Tool                   Version  Source   Environment            Executables
---------------------  -------  -------  ---------------------  -----------
micromamba             2.9.0-0  bundled  -                      micromamba
BBTools                40.02    managed  bbtools                clumpify.sh, bbduk.sh, ...
BCFtools               1.24     managed  bcftools               bcftools
...
```

Its twenty rows agree with the first table on every version, environment, and executable. The command sorts rows by source, bundled before managed, and then alphabetically by display name, writes display names such as `Samtools` where the lock stores `samtools`, and prints a Source column of `bundled` or `managed` in place of the License column.

The command stops at those twenty. It prints nothing about plugin pack tools, Linux tools, pipelines, or databases, so the other four tables here have no command-line equivalent, and the lock files are the only place they all live.

## Which one governs

Use this appendix for release notes, for planning, and for a methods section written before you have run anything. Use your run's provenance sidecar for a methods section describing a finished analysis, for a rerun, and for a review, because it records the version that actually ran rather than the one the release pinned. [Which tools you actually need to cite](bibliography.md#which-tools-you-actually-need-to-cite) shows three routes to the list of tools one run used.

When the sidecar and this page disagree, the sidecar is right about your analysis, and the disagreement is telling you the machine was not up to date.

For the reference list of a paper, cite the [Tool Bibliography](bibliography.md) rather than this appendix, since it carries the published reference for the tools it lists and this page carries the version number that goes beside it.

## Next

The next appendix is [Running in CI](06-running-in-ci.md), which installs these pinned versions on the fresh test machine of [continuous integration](../../GLOSSARY.md#continuous-integration). The [Tool Bibliography](bibliography.md) carries no version numbers of its own, so this page is where a version is looked up.
