---
title: Tool Versions
chapter_id: appendices/tool-versions
audience: power-user
prereqs: []
estimated_reading_min: 6
task: Look up the bundled and managed tool versions shipped with this Lungfish release.
tags: [reference, tools, versions, provenance]
tools: []
entry_points:
  - "CLI: lungfish version --tools"
shots: []
illustrations: []
glossary_refs: [provenance]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-tool-versions"></a>

## What it is

This appendix is the release-level reference for tools that Lungfish ships or manages directly. User-facing chapters link here instead of hard-coding tool versions. For a specific analysis, the provenance sidecar remains the authority because it records the executable actually used, the argv, input and output checksums, exit status, and runtime details.

The bundled and managed tool set is also printed from the command line:

```bash
lungfish version --tools
```

The live `version --tools` table has five columns: Tool, Version, Source, Environment, and Executables. The License and Source URL values shown in this appendix come from the managed-tool lock file's per-tool metadata, which the command reads but does not print. When the two ever disagree, the lock file is the authority for what shipped.

## Bundled Tools

Bundled tools are distributed with Lungfish resources and are available before any plugin pack is installed.

| Tool | Version | Source | License | Executables |
|---|---:|---|---|---|
| micromamba | 2.0.5-0 | bundled | BSD-3-Clause | `micromamba` |

## Managed Tools

Managed tools are installed from the Lungfish managed-tool lock through the conda/micromamba provisioning path. The lock file records package specs, environments, source URLs, and licenses.

| Tool | Version | Source | Environment | License | Executables |
|---|---:|---|---|---|---|
| Nextflow | 25.10.4 | managed | `nextflow` | Apache-2.0 | `nextflow` |
| Snakemake | 9.19.0 | managed | `snakemake` | MIT | `snakemake` |
| BBTools | 39.80 | managed | `bbtools` | BSD-3-Clause-LBNL | `clumpify.sh`, `bbduk.sh`, `bbmerge.sh`, `repair.sh`, `tadpole.sh`, `reformat.sh`, `bbmap.sh`, `mapPacBio.sh`, `java` |
| Fastp | 1.3.2 | managed | `fastp` | MIT | `fastp` |
| Deacon | 0.15.0 | managed | `deacon` | MIT | `deacon` |
| Samtools | 1.23.1 | managed | `samtools` | MIT | `samtools` |
| BCFtools | 1.23.1 | managed | `bcftools` | GPL | `bcftools` |
| HTSlib | 1.23.1 | managed | `htslib` | MIT | `bgzip`, `tabix` |
| SeqKit | 2.13.0 | managed | `seqkit` | MIT | `seqkit` |
| Cutadapt | 5.2 | managed | `cutadapt` | MIT | `cutadapt` |
| VSEARCH | 2.30.5 | managed | `vsearch` | GPL-3.0-or-later OR BSD-2-Clause | `vsearch` |
| pigz | 2.8 | managed | `pigz` | Zlib | `pigz` |
| SRA Tools | 3.4.1 | managed | `sra-tools` | Public Domain | `prefetch`, `fasterq-dump` |
| UCSC bedGraphToBigWig | 482 | managed | `ucsc-bedgraphtobigwig` | UCSC (see genome.ucsc.edu/license) | `bedGraphToBigWig` |
| pysam | 0.24.0 | managed | `pysam` | MIT | `python` |
| openpyxl | 3.1.5 | managed | `openpyxl` | MIT | `python` |

Tools such as Clair3, WhatsHap, and Freyja are not in the bundled managed-tool lock and do not appear in `lungfish version --tools`. They are provided by separate plugin packs (for example the GATK, phasing, and wastewater-surveillance packs) and are installed on demand with `lungfish conda install`. Check a specific analysis's provenance sidecar for the exact version of any plugin-pack tool it used.

## Supported Workflow Pins

These are workflow releases selected by Lungfish workflow adapters. They are not bundled executables; Lungfish launches them through Nextflow or the configured executor and records the final resolved workflow tag in the run bundle.

| Workflow | Default release | How to override |
|---|---:|---|
| nf-core/viralrecon | 3.0.0 | `lungfish workflow run nf-core/viralrecon --version <tag>` or the Viral Recon wizard version field |

## Provenance Rule

Use this appendix for release notes and manual procedures. Use the provenance sidecar for methods sections, reruns, and reviews. If the two disagree, cite the sidecar for the analysis and treat the appendix as a clue that the run used a different installation or override.
