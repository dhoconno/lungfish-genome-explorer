---
title: Tool Versions
chapter_id: appendices/tool-versions
audience: power-user
prereqs: []
estimated_reading_min: 15
task: Look up the exact version of every tool, pipeline, and database this Lungfish Genome Explorer release pins.
tags: [reference, tools, versions, provenance]
tools: []
entry_points:
  - "CLI: lungfish-cli version --tools"
shots: []
illustrations: []
glossary_refs: [assembler, commit, conda, dependency-set, executable, exit-status, home-folder, micromamba, nextflow, pinned, plugin-pack, provenance-sidecar, repository, tool-lock-manifest]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-tool-versions"></a>

## What it is

Lungfish Genome Explorer (LGE) runs outside programs to do the computing, such as minimap2 for mapping and Kraken 2 for classification. This appendix covers the pinned version of every tool, pipeline, and database one release of LGE installs, and nothing else. Four tables follow, for the tools every copy of LGE has, the tools that arrive with a plugin pack, two whole pipelines, and the reference databases.

The tables say what release 2026.9.40 pins. Your own machine can hold an older installed version, because a pack downloaded months ago does not update itself. A methods section should be written from the run's own record. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Two windows show what your own machine has. The About window, at **Lungfish Genome Explorer > About Lungfish Genome Explorer**, prints the app version, the dependency set, and the tool versions. The Plugin Manager's Installed tab, at **Tools > Plugin Manager...** (Cmd-Shift-B), lists the exact packages inside each tool's environment, the private folder that holds it.

Every number on this page is read out of one file, LGE's [tool lock manifest](../../GLOSSARY.md#tool-lock-manifest), which names one exact version of every outside program LGE depends on, so two people installing the same release get the same programs. It lives inside the app at `Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/ManagedTools/third-party-tools-lock.json`, and in a source checkout at `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. You do not need to open it, since the tables here are its contents.

A version fixed this way is [pinned](../../GLOSSARY.md#pinned), locked to one exact number. The whole pinned collection is called the [dependency set](../../GLOSSARY.md#dependency-set). This appendix reflects dependency set `2026.2`, frozen on 2026-08-18, as shipped by app release 2026.9.40. Name the dependency set beside the app version in a methods section, as in this sentence.

```
Analyses were run in Lungfish Genome Explorer 2026.9.40 (dependency set 2026.2),
using minimap2 2.31 and Kraken 2 2.17.1.
```

Copy each version string exactly as the table prints it.

## Reading the tables

Four columns need a note each.

The Environment column names the [managed environment](../../GLOSSARY.md#managed-environment), the private folder that holds one tool and the libraries it needs. Ignore it unless a provenance record names an environment and you want to know which tool it belongs to. [Manage installed environments](../01-foundations/07-plugin-packs.md#manage-installed-environments) covers these folders.

The Pack column in the second table names the pack a tool arrives with.

The License column copies the lock's own `license` field without interpreting it. Using a tool for your own analysis and citing it is not redistribution, so read a tool's license text only if you plan to ship the program itself to other people.

The Executables column names the program files, or [executables](../../GLOSSARY.md#executable), that show up in a provenance record, which often differ from the tool's display name, as IQ-TREE's `iqtree3` does. Two rows list `python`, because they are code libraries that run inside the Python interpreter.

## Tools installed with every copy of LGE

These eighteen come with every copy of LGE. Seventeen arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. The eighteenth is **[micromamba](../../GLOSSARY.md#micromamba)**, the small package manager that installs all the others. It ships inside the app itself rather than in an environment of its own. The lock stores it separately from the rest, in a labelled entry of its own that records no license.

| Tool | Version | Environment | License | Executables |
|---|---|---|---|---|
| micromamba | 2.9.0-0 | (bundled in the app) | (not recorded in the lock) | `micromamba` |
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
| sra-tools | 3.4.1 | `sra-tools` | Public Domain | `prefetch`, `fasterq-dump` |
| ucsc-bedgraphtobigwig | 482 | `ucsc-bedgraphtobigwig` | `Varies; see https://genome.ucsc.edu/license` | `bedGraphToBigWig` |
| pysam | 0.24.0 | `pysam` | MIT | `python` |
| openpyxl | 3.1.5 | `openpyxl` | MIT | `python` |

Two version numbers are written in an unusual form and are correct as printed. bedGraphToBigWig counts by build number rather than by a dotted release, so a bare `482` is the whole version. The micromamba version carries a trailing `-0`, which is the packaging revision of that build. Copy either one whole, exactly as it appears, and it will be right in a citation.

The lock records some licenses loosely, which is why the bcftools cell reads a bare `GPL` where its neighbours carry a precise code. That is copied as found rather than tightened here.

The table prints the lock's own identifiers, so `bbtools` here is `BBTools` elsewhere. Either spelling identifies the tool, and a methods section reads better with the tool's own published capitalisation, `BBTools`, beside the version from this table.

Three rows do work you may not associate with a named tool. pysam is the Python library that reads the BAM files, the files of aligned reads, behind a viewport's coverage and depth readouts, openpyxl writes the genotyping workbooks, and micromamba installed every other tool on this page.

## Tools installed by a plugin pack

None of these tools is on a machine that has not installed its pack. The lock pins twenty-five tools across eleven packs. Install the `<pack-id>` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. Here `<pack-id>` is the value in the Pack column. Three packs, `gatk-core`, `phasing`, and `wastewater-surveillance`, are experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. A version you find in a provenance sidecar is what ran, whatever this machine holds today.

| Pack | Tool | Version | Environment | License | Executables |
|---|---|---|---|---|---|
| `read-mapping` | minimap2 | 2.31 | `minimap2` | MIT | `minimap2` |
| `read-mapping` | bwa-mem2 | 2.3 | `bwa-mem2` | MIT | `bwa-mem2` |
| `read-mapping` | bowtie2 | 2.5.5 | `bowtie2` | GPL-3.0 | `bowtie2`, `bowtie2-build` |
| `full-length-mhc-genotyping` | savont | 0.6.3 | `savont` | MIT | `savont` |
| `full-length-mhc-genotyping` | blast | 2.16.0 | `blast` | Public Domain | `blastn` |
| `pcr-primer-design` | primer3 | 2.6.1 | `primer3` | GPL-2.0-or-later | `primer3_core` |
| `pcr-primer-design` | primalscheme3 | 3.3.0+lge.5 | `primalscheme3` | GPL-3.0 | `primalscheme3` |
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
| `metagenomics` | bracken | 1.0.0 | `bracken` | GPL-3.0 | `bracken`, `bracken-build` |
| `metagenomics` | esviritu | 1.3.3 | `esviritu` | MIT | `EsViritu` |
| `metagenomics` | ribodetector | 0.3.3 | `ribodetector` | GPL-3.0-or-later | `ribodetector_cpu` |
| `wastewater-surveillance` | freyja | 2.0.3 | `freyja` | BSD-2-Clause | `freyja` |

LoFreq 2.1.5 rejects `--version`, so a LoFreq provenance record can carry the text `Unrecognized command '--version'` where a version belongs. Take LoFreq's version from this table. Bracken at 1.0.0 beside Kraken 2 at 2.17.1 is not an error. Each project numbers its own releases, so a low number simply means that project has cut fewer of them.

Two entries name the pack rather than the tool in their Environment column. GATK4 installs into an environment called `gatk-core` and WhatsHap into one called `phasing`, so a provenance record naming either environment is naming the pack. The GATK Core pack holds GATK4 4.6.2.0 alone, and the Plugin Manager estimates its download at about 600 MB. The primalscheme3 version carries the suffix `+lge.5`, which marks a build LGE maintains on top of PrimalScheme 3.3.0, so copy it whole.

## Pinned external pipelines

A pipeline is a program that runs many separate tools in a fixed order. LGE does not install these two into conda environments. It fetches each from its public **[repository](../../GLOSSARY.md#repository)**, the folder of files a project publishes together with the history of every change to it, at one exact revision. It then runs the pipeline through **[Nextflow](../../GLOSSARY.md#nextflow)**, the program that executes multi-step pipelines and the same tool the first table lists.

A revision is named one of two ways, and the table's last column shows both. A **[commit](../../GLOSSARY.md#commit)** identifier is the forty-character string a version-control system gives one saved snapshot of a repository, which is an ordinary identifier rather than anything alarming. A release tag is a short name a maintainer attached to a snapshot.

| Pipeline | Repository | Release | Revision the lock pins |
|---|---|---|---|
| TaxTriage | `jhuapl-bio/taxtriage` | v3.3.8 | `e10bfebda32a62711f38a4e23ab03b61725a9675` |
| Viral Recon | `nf-core/viralrecon` | 3.0.0 | `3.0.0` |

The difference between the two matters if you need to reproduce a run exactly. A commit names one unchangeable snapshot. A maintainer is able to move a tag to a different snapshot, though this is rare. Write the commit for TaxTriage and the tag for Viral Recon into your methods section, since those are what the lock records.

Most readers should leave both pinned. To run a different TaxTriage revision, add `--revision` and the revision you want to `lungfish-cli taxtriage run`, for example `--revision v3.3.7`. There is no window route for this, so the TaxTriage revision can only be changed from the command line.

## Reference databases

A classification result depends on its database as much as on its classifier, so a Kraken 2 report is not reproducible without the database version. The lock pins sixteen databases.

The Source policy column is the lock's own word for where each database comes from, and it changes how much the version string can be trusted. Read the four values this way. `unpinnedArchive` means LGE downloads a named archive, one compressed download file, from a public server, where the version string in the table is the only identifier and nothing checks that the archive's contents have not changed since. `liveSnapshot` means the data is fetched fresh on every run and is not fixed at all, which the warning under the table explains. `localBuild` means LGE builds the database on your machine from upstream data rather than downloading a finished one. `bundledPayload` is the lock's label for the two Deacon rows, whose data is still downloaded into LGE's managed storage the first time it is needed, or with `lungfish-cli conda db install-managed`.

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
| `deacon-ribokmers` | deacon | Ribosomal RNA Removal Data | bbmap-ribokmers-k31w15 | bundledPayload |

**Warning about the NCBI Taxonomy row.** Its version is the word `live`, meaning it is not pinned at all, so the same read can be assigned a different species name in a run made a month later, and a methods section must therefore record the date you ran the classification rather than a taxonomy version.

Your provenance sidecar records that date for you, which is one more reason to write a methods section from the sidecar rather than from this page.

Three of these version strings are dates written as year, month, and day, so `20260626` is 26 June 2026 and `20230407` is 7 April 2023. `20260706v2` is such a date with a revision marker after it. The rest are release names. Copy whichever kind you have exactly as it appears here.

The last two rows are reference data rather than searchable databases in the usual sense. Deacon uses them to recognise and discard host reads, meaning reads from the person or animal the sample came from rather than from the organism you are studying, and to discard ribosomal reads the same way.

## Two checks before you cite a number

Two checks are worth running before you quote a number from this page in a paper.

First, confirm your own copy reports this dependency set. Open **Lungfish Genome Explorer > About Lungfish Genome Explorer** and read the line beginning "Dependency set". This check needs no terminal. If your installed release is not 2026.9.40, the numbers here are not the numbers you ran, so take the versions from your run's provenance record instead.

Second, confirm the machine has the pinned versions installed. The window route is the Plugin Manager's **Check for Tool Updates...** button, which reports anything that has drifted from what your copy expects. The command-line form is `lungfish-cli tools update --plan`, which prints the outstanding work without doing any of it and exits with [exit status](../../GLOSSARY.md#exit-status) 10 when work is pending and 0 when the machine matches the lock.

The lock also carries a list of retired environments, removed from the pinned set so an upgrade can clean them up. That matters only when you are upgrading, and in dependency set 2026.2 the list is empty, so this release retires nothing.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it. The command line keeps its own copy of the managed tools, separate from the app's, so the versions it reports describe the tools the command line uses.

```bash
"/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli" version --tools
```

It prints the app version, the dependency set with the date it was frozen, and then the first table of this appendix, in five columns headed Tool, Version, Source, Environment, and Executables. Its first lines on release 2026.9.40 are these. The BBTools executables line is cut short here to fit the page, and the real output continues past the third row with the remaining fifteen tools.

```
Lungfish 2026.9.40
Dependency set: 2026.2 (2026-08-18)

Bundled and Managed Tools
Tool                   Version  Source   Environment            Executables
---------------------  -------  -------  ---------------------  -----------
micromamba             2.9.0-0  bundled  -                      micromamba
BBTools                40.02    managed  bbtools                clumpify.sh, bbduk.sh, ...
BCFtools               1.24     managed  bcftools               bcftools
...
```

Its eighteen rows agree with the first table on every version, environment, and executable. The command sorts rows by source, bundled before managed, and then alphabetically by display name, writes display names such as `Samtools` where the lock stores `samtools`, and prints a Source column of `bundled` or `managed` in place of the License column.

The command stops at those eighteen. It prints nothing about plugin pack tools, pipelines, or databases, so the other three tables here have no command-line equivalent, and the lock file is the only place all four live together.

## Which one governs

Use this appendix for release notes, for planning, and for a methods section written before you have run anything. Use your run's provenance sidecar for a methods section describing a finished analysis, for a rerun, and for a review, because it records the version that actually ran rather than the one the release pinned.

When the sidecar and this page disagree, the sidecar is right about your analysis, and the disagreement is telling you the machine was not up to date. The Plugin Manager's **Check for Tool Updates...** button, or `lungfish-cli tools update --plan`, tells you by how much.

For the reference list of a paper, cite the [Tool Bibliography](bibliography.md) rather than this appendix. It carries the published reference for each tool, which is what a reference list needs, and this page carries the version number that goes beside it.

## Next

The [Tool Bibliography](bibliography.md) gives the citation for every tool named here, and shows the three routes to the list of tools one run actually used. It is built from the same lock file, so the two agree on every version.
