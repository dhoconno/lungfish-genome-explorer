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

Lungfish Genome Explorer (LGE) runs outside programs to do the computing, such as minimap2 for mapping and Kraken 2 for classification. This appendix covers every tool, pipeline, and database that one release of LGE pins to an exact version, and nothing else. Five tables follow, for the tools every copy of LGE has, the tools that arrive with a plugin pack, the tools of a run on a Linux machine, two whole pipelines, and the reference databases.

The tables say what the newest release this manual describes pins, read from that release's tool lock. Your own machine can hold an older installed version, because a pack downloaded months ago does not update itself. A methods section should be written from the run's own record. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Two windows show what your own machine has. The About window, at **Lungfish Genome Explorer > About Lungfish Genome Explorer**, prints the app version, the dependency set, and the tool versions. The Plugin Manager's Installed tab, at **Tools > Plugin Manager…** (Cmd-Shift-B), lists the exact packages inside each tool's environment, the private folder that holds it.

Almost every number on this page is read out of one file, LGE's [tool lock manifest](../../GLOSSARY.md#tool-lock-manifest), which names one exact version of every outside program LGE depends on, so two people installing the same release get the same programs. It lives inside the app at `Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/ManagedTools/third-party-tools-lock.json`, and in a source checkout at `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. Two files beside it supply the rest. `third-party-tools-lock.linux-64.json` pins the tools of a Linux run, and `bundled-payloads.json` lists the programs that ship inside the app itself. You do not need to open any of them, since the tables here are their contents.

A version fixed this way is [pinned](../../GLOSSARY.md#pinned), locked to one exact number. The whole pinned collection is called the [dependency set](../../GLOSSARY.md#dependency-set). This appendix reflects dependency set `2026.2`, dated 2026-08-18. Later releases added tools to this set without renaming it, so an older copy that reports 2026.2 can lack a tool listed here. Name the dependency set beside the app version in a methods section, as in this sentence, with `<version>` replaced by the release your About window shows.

```
Analyses were run in Lungfish Genome Explorer <version> (dependency set 2026.2),
using minimap2 2.31 and Kraken 2 2.17.1.
```

Copy each version string exactly as the table prints it.

## Reading the tables

Four columns need a note each.

The Environment column names the [managed environment](../../GLOSSARY.md#managed-environment), the private folder that holds one tool and the libraries it needs. Ignore it unless a provenance record names an environment and you want to know which tool it belongs to. [Manage installed environments](../01-foundations/07-plugin-packs.md#manage-installed-environments) covers these folders.

The Pack column in the second table names the pack a tool arrives with.

The License column copies the lock's own `license` field without interpreting it. The one exception is micromamba, whose license comes from `bundled-payloads.json` because the lock records none for it. Using a tool for your own analysis and citing it is not redistribution, so read a tool's license text only if you plan to ship the program itself to other people.

The Executables column names the program files, or [executables](../../GLOSSARY.md#executable), that show up in a provenance record, which often differ from the tool's display name, as IQ-TREE's `iqtree3` does. Six rows list `python`, because they are code libraries that run inside the Python interpreter.

## Tools installed with every copy of LGE

These twenty tools come with every copy of LGE. Nineteen arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE, as [First launch and the Welcome window](../01-foundations/06-the-lungfish-project.md#first-launch-and-the-welcome-window) shows. The twentieth is **[micromamba](../../GLOSSARY.md#micromamba)**, the small package manager that installs all the others. It ships inside the app itself rather than in an environment of its own, and the lock stores it separately from the rest, in an entry of its own that records its version and checksum.

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

Two version numbers are written in an unusual form and are correct as printed. bedGraphToBigWig counts by build number rather than by a dotted release, so a bare `482` is the whole version. The micromamba version carries a trailing `-0`, which is the packaging revision of that build. Copy either one whole, exactly as it appears, and it will be right in a citation.

The lock records some licenses loosely, which is why the bcftools cell reads a bare `GPL` where its neighbors carry a precise code. That is copied as found rather than tightened here.

The table prints the lock's own identifiers, so `bbtools` here is `BBTools` elsewhere. Either spelling identifies the tool, and a methods section reads better with the tool's own published capitalization, `BBTools`, beside the version from this table.

Five rows do work you may not associate with a named tool. pysam is the Python library that reads the BAM files, the files of aligned reads, inside the amplicon genotyping pipeline, where a small script uses it to filter the aligned reads, and openpyxl writes the genotyping workbooks. zstd unpacks and writes `.zst` compressed files and xz unpacks `.xz` files, so importing either kind, or exporting a `.zst` file, needs no other software on the Mac. micromamba installed every other tool on this page.

The app also carries a Linux kernel boot image, version 6.12.28, and a matching start-up file system for Apple's own container system, Apple Containerization, which `bundled-payloads.json` lists. `lungfish-cli debug container` reports Apple Containerization as not used by pipelines, so no result in this manual depends on them.

## Tools installed by a plugin pack

None of these tools is on a machine that has not installed its pack. The lock pins thirty-three tools across thirteen packs. Install the `<pack-id>` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. Here `<pack-id>` is the value in the Pack column. Three packs, `gatk-core`, `phasing`, and `wastewater-surveillance`, are experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. A version you find in a provenance sidecar is what ran, whatever this machine holds today.

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

LoFreq rejects the usual `--version` flag, so LGE asks it with the `version` subcommand, and a LoFreq provenance record names the version rather than an error message.

The Bracken row needs care. The only conda build of Bracken for Apple Silicon Macs lacks Bracken's main program, so LGE builds Bracken from the upstream release 3.1 source code instead of installing it from conda. The lock file also carries a version field of 1.0.0 for Bracken, but that is only a fallback pin, and a fresh install never uses it. The `bracken` script in release 3.1 still reports its own version as 3.0.1, so Bracken's own version flag says 3.0.1. LGE never asks the program, because it records the 3.1 source build it installed, so your provenance record says 3.1. Write Bracken 3.1 in a methods section and add that its version flag prints 3.0.1, so a reader who runs it can see why.

Five environments install from an exact list of packages kept inside LGE, so every Mac receives the same builds. They are PrimalScheme3, Olivar, varVAMP, EsViritu, and the one `sc-embed` environment that the four Single-Cell Analysis tools share. That shared environment is why those four rows name `sc-embed` rather than the tool.

Two entries name the pack rather than the tool in their Environment column. GATK4 installs into an environment called `gatk-core` and WhatsHap into one called `phasing`, so a provenance record naming either environment is naming the pack. The GATK Core pack holds GATK4 4.6.2.0 alone. The Plugin Manager estimates it at about 600 MB, but the installed pack takes about 900 MB, so allow about 1 GB of disk for it. The primalscheme3 version carries the suffix `+lge.5`, which marks a build LGE maintains on top of PrimalScheme 3.3.0, so copy it whole.

The umap-learn license is the one in the umap-learn repository's own license file. conda-forge labels the package BSD-2-Clause, and LGE records the repository's BSD-3-Clause.

## Tools of a run on a Linux machine

A step can run on a Linux machine or an HTCondor pool instead of your Mac, as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) shows. That step uses the programs inside a tool image, a single file that holds the programs and everything they need, run as a [container](../../GLOSSARY.md#container). The image is built from the second lock, `third-party-tools-lock.linux-64.json`, under the same dependency set, 2026.2. `linux-64` is conda's name for Linux on 64-bit Intel and AMD processors.

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

Two versions of the STAR read aligner are pinned. STAR 2.7.11b is the default, and the older 2.7.3a is chosen with `--star 2.7.3a` on `lungfish-cli rnaseq index-plan`. The two sit in separate environments, so a record that names the `star273a` environment ran 2.7.3a. Every tool here that also appears in the Mac tables carries the same version in both.

## Pinned external pipelines

A pipeline is a program that runs many separate tools in a fixed order. LGE does not install these two into conda environments. It fetches each from its public **[repository](../../GLOSSARY.md#repository)**, the folder of files a project publishes together with the history of every change to it, at one exact revision. It then runs the pipeline through **[Nextflow](../../GLOSSARY.md#nextflow)**, the program that executes multi-step pipelines and the same tool the first table lists.

A revision is named one of two ways, and the table shows both. A **[commit](../../GLOSSARY.md#commit)** identifier is the forty-character string a version-control system gives one saved snapshot of a repository, which is an ordinary identifier rather than anything alarming. A release tag is a short name a maintainer attached to a snapshot.

| Pipeline | Repository | Release | Revision the lock pins |
|---|---|---|---|
| TaxTriage | `jhuapl-bio/taxtriage` | v3.3.8 | `e10bfebda32a62711f38a4e23ab03b61725a9675` |
| Viral Recon | `nf-core/viralrecon` | 3.0.0 | `395079f1d24dce731ac22e03d7a5e71f110103fc` |

The difference between the two matters if you need to reproduce a run exactly. A commit names one unchangeable snapshot. A maintainer is able to move a tag to a different snapshot, though this is rare. The lock pins both pipelines by commit, so write the commit into your methods section beside the release name.

Most readers should leave both pinned. To run a different TaxTriage revision, add `--revision` and the revision you want to `lungfish-cli taxtriage run`, for example `--revision v3.3.7`. There is no window route for this, so the TaxTriage revision can only be changed from the command line.

## Reference databases

A classification result depends on its database as much as on its classifier, so a Kraken 2 report is not reproducible without the database version. The lock pins sixteen databases.

The Source policy column is the lock's own word for where each database comes from, and it changes how much the version string can be trusted. Read the five values this way. `unpinnedArchive` means LGE downloads a named archive, one compressed download file, from a public server, where the version string in the table is the only identifier and nothing checks that the archive's contents have not changed since. `pinnedArchive` means LGE downloads one named file and checks it against the SHA-256 checksum and size the lock records before it installs the file, so the version is backed by the file's contents. `liveSnapshot` means the data is fetched fresh and is not fixed at all, which the warning under the table explains. `localBuild` means LGE builds the database on your machine from upstream data rather than downloading a finished one. `bundledPayload` is the lock's label for the Human Read Removal Data, which LGE also checks against a recorded checksum and size. It is downloaded into LGE's managed storage the first time it is needed, or with `lungfish-cli conda db install-managed`.

The Kraken 2 names carry a number suffix, as in Standard-8 and PlusPF-16, and that number is roughly the memory in gigabytes the database needs. Standard and PlusPF with no suffix are the full-size builds. PlusPF adds protozoa and fungi to Standard, MinusB is Standard without bacteria, and EuPathDB46 holds eukaryotic pathogens. Your own run's provenance sidecar names which one it used, and the Plugin Manager's Databases tab shows which ones this machine holds.

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

**Warning about the NCBI Taxonomy row.** Its version is the word `live`, meaning it is not pinned at all, so the same read can be assigned a different species name in a run made a month later, and a methods section must therefore record the date you ran the classification rather than a taxonomy version.

Your provenance sidecar records that date for you, which is one more reason to write a methods section from the sidecar rather than from this page.

Three of these version strings are dates written as year, month, and day, so `20260626` is 26 June 2026 and `20230407` is 7 April 2023. `20260706v2` is such a date with a revision marker after it. The rest are release names. Copy whichever kind you have exactly as it appears here.

The last two rows are reference data rather than searchable databases in the usual sense. Deacon uses them to recognize and discard host reads, meaning reads from the person or animal the sample came from rather than from the organism you are studying, and to discard ribosomal reads the same way. The Ribosomal RNA Removal Data is about 10 MB and downloads the first time an operation needs it.

## Two checks before you cite a number

Two checks are worth running before you quote a number from this page in a paper.

First, confirm your own copy reports this dependency set. Open **Lungfish Genome Explorer > About Lungfish Genome Explorer** and read the line beginning "Dependency set". This check needs no terminal. If your copy reports a different dependency set, or is older than the newest release this manual describes, the numbers here may not be the numbers you ran, so take the versions from your run's provenance record instead.

Second, confirm the machine has the pinned versions installed. The window route is the Plugin Manager's **Check for Tool Updates…** button, which either reports that the tools are up to date or opens the Update Tools sheet with what has drifted from what your copy expects. The command-line form is `lungfish-cli tools update --plan`, which prints the outstanding work without doing any of it and exits with [exit status](../../GLOSSARY.md#exit-status) 10 when work is pending and 0 when the machine matches the lock.

The lock also carries a list of retired environments, removed from the pinned set so an upgrade can clean them up. That matters only when you are upgrading, and in dependency set 2026.2 the list is empty, so this release retires nothing.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it. It uses the same storage folder as the app it ships inside, and it reads the tool lock inside that app, so the versions it prints are the ones that release pins, not a list of what your Mac holds.

```bash
lungfish-cli version --tools
```

It prints the app version, the dependency set with the date it was frozen, and then the first table of this appendix, in five columns headed Tool, Version, Source, Environment, and Executables. Its first lines are these, with the release number in place of `<version>`. The BBTools executables line is cut short here to fit the page, and the real output continues past the third row with the remaining seventeen tools.

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

Use this appendix for release notes, for planning, and for a methods section written before you have run anything. Use your run's provenance sidecar for a methods section describing a finished analysis, for a rerun, and for a review, because it records the version that actually ran rather than the one the release pinned.

When the sidecar and this page disagree, the sidecar is right about your analysis, and the disagreement is telling you the machine was not up to date. The Plugin Manager's **Check for Tool Updates…** button, or `lungfish-cli tools update --plan`, tells you by how much.

For the reference list of a paper, cite the [Tool Bibliography](bibliography.md) rather than this appendix. It carries the published reference for the tools it lists, which is what a reference list needs, and this page carries the version number that goes beside it.

## Next

The next appendix is [Running in CI](06-running-in-ci.md), which installs these pinned versions on a build machine. The [Tool Bibliography](bibliography.md) gives the citation for the tools it lists and shows the three routes to the list of tools one run actually used. It carries no version numbers of its own, so this page is where a version is looked up.
