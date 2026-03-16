# Workflow Integration Research: arm64-Compatible Nextflow and Snakemake Workflows

**Date:** 2026-03-09
**Objective:** Identify one Nextflow and one Snakemake workflow that are simple, arm64-compatible, and use standard genomic formats.

---

## Recommendation: Nextflow -- nf-core/demo

### Overview

nf-core/demo is a minimal, officially maintained nf-core pipeline designed for workshops and demonstrations. It performs FASTQ quality control and trimming in 3 steps: FASTQC, SEQTK_TRIM, and MULTIQC.

### Repository

- **URL:** https://github.com/nf-core/demo
- **Latest release:** v1.1.0 (January 30, 2026)
- **License:** MIT
- **DOI:** 10.5281/zenodo.12192442

### Input / Output

- **Input:** CSV samplesheet with columns: `sample`, `fastq_1`, `fastq_2`
- **Output:** Trimmed FASTQ files, FastQC reports, MultiQC aggregate report

### arm64 Container Support

nf-core pipelines (including nf-core/demo) support arm64 natively via **Seqera Containers** (community.wave.seqera.io). As of nf-core tools 3.4.0+, dedicated arm64 profiles are available:

- `docker_arm` -- Docker with arm64 container images
- `singularity_arm` -- Singularity with arm64 images
- `conda_arm` -- Conda with arm64 packages

Container images are automatically built for both `linux/amd64` and `linux/arm64` from the Seqera Containers registry at `community.wave.seqera.io/library/`.

Tools used and their containers:
- **FastQC** -- `community.wave.seqera.io/library/fastqc:0.12.1--<hash>` (arm64 available)
- **seqtk** -- `community.wave.seqera.io/library/seqtk:1.4--<hash>` (arm64 available)
- **MultiQC** -- `community.wave.seqera.io/library/multiqc:1.x--<hash>` (arm64 available)

### How to Run

```bash
# Install Nextflow (requires Java 11+)
curl -s https://get.nextflow.io | bash

# Run with test data on arm64 (Apple Silicon)
nextflow run nf-core/demo -r 1.1.0 -profile test,docker_arm

# Run with your own data
nextflow run nf-core/demo -r 1.1.0 \
    --input samplesheet.csv \
    --outdir results \
    -profile docker_arm
```

### Example Samplesheet (samplesheet.csv)

```csv
sample,fastq_1,fastq_2
sample1,/path/to/reads_R1.fastq.gz,/path/to/reads_R2.fastq.gz
sample2,/path/to/single_end.fastq.gz,
```

### Pipeline Steps

1. **FASTQC** -- Read quality metrics (HTML report per sample)
2. **SEQTK_TRIM** -- Quality/adapter trimming (trimmed FASTQ output)
3. **MULTIQC** -- Aggregate QC report across all samples

### Required Parameters

| Parameter    | Description                          | Required |
|-------------|--------------------------------------|----------|
| `--input`   | Path to CSV samplesheet              | Yes      |
| `--outdir`  | Output directory                     | Yes      |
| `-profile`  | Execution profile (docker_arm, etc.) | Yes      |

---

## Recommendation: Snakemake -- snakemake-wrappers bio/fastp

### Overview

The Snakemake fastp wrapper provides a declarative rule for FASTQ quality control and adapter trimming using fastp. It is part of the official snakemake-wrappers repository, the canonical source of curated Snakemake wrappers.

### Repository

- **URL:** https://github.com/snakemake/snakemake-wrappers
- **Wrapper path:** `v9.3.0/bio/fastp` (latest release: March 3, 2026)
- **Documentation:** https://snakemake-wrappers.readthedocs.io/en/stable/wrappers/bio/fastp.html
- **License:** MIT
- **Software version:** fastp 1.1.0

### Input / Output

- **Input:** FASTQ file(s) -- single-end or paired-end
- **Output:** Trimmed FASTQ file(s), HTML report, JSON statistics, optionally: unpaired reads, merged reads, failed reads

### arm64 Container Support

The wrapper uses **Conda** dependency resolution (`--use-conda`). fastp is available in Bioconda for both `linux-aarch64` and `osx-arm64` architectures. When running on Apple Silicon:

- **Conda/Mamba route (recommended for arm64):** fastp 1.1.0 is natively available for `osx-arm64` and `linux-aarch64` via Bioconda
- **Docker route:** Use Seqera Containers to get an arm64 image:
  ```bash
  # Generate arm64 container via Wave CLI
  wave --conda-package "bioconda::fastp=1.1.0" --platform linux/arm64
  ```
- **BioContainers route:** `quay.io/biocontainers/fastp:1.0.1--heae3180_0` (check manifest for arm64 support; BioContainers has been adding arm64 builds)

### How to Run

```bash
# Install Snakemake (requires Python 3.8+)
pip install snakemake

# Create a minimal Snakefile (see below)
# Then run:
snakemake --use-conda --cores 4
```

### Example Snakefile

```python
# Snakefile for FASTQ QC with fastp

SAMPLES = ["sample1", "sample2"]

rule all:
    input:
        expand("trimmed/{sample}.fastq", sample=SAMPLES),
        expand("report/{sample}.html", sample=SAMPLES),
        expand("report/{sample}.json", sample=SAMPLES)

# Single-end fastp rule
rule fastp_se:
    input:
        sample=["reads/{sample}.fastq"]
    output:
        trimmed="trimmed/{sample}.fastq",
        failed="trimmed/{sample}.failed.fastq",
        html="report/{sample}.html",
        json="report/{sample}.json"
    log:
        "logs/fastp/{sample}.log"
    params:
        adapters="",
        extra=""
    threads: 2
    wrapper:
        "v9.3.0/bio/fastp"

# Paired-end fastp rule (alternative)
rule fastp_pe:
    input:
        sample=["reads/{sample}.R1.fastq", "reads/{sample}.R2.fastq"]
    output:
        trimmed=["trimmed/{sample}.R1.fastq", "trimmed/{sample}.R2.fastq"],
        unpaired1="trimmed/{sample}.u1.fastq",
        unpaired2="trimmed/{sample}.u2.fastq",
        html="report/{sample}.html",
        json="report/{sample}.json"
    log:
        "logs/fastp/{sample}.log"
    params:
        adapters="",
        extra=""
    threads: 2
    wrapper:
        "v9.3.0/bio/fastp"
```

### Required Parameters

| Parameter       | Description                           | Required |
|----------------|---------------------------------------|----------|
| `input.sample` | FASTQ file path(s)                    | Yes      |
| `output.html`  | HTML report path                      | Yes      |
| `output.json`  | JSON statistics path                  | Yes      |
| `params.extra` | Additional fastp flags (can be empty) | No       |
| `params.adapters` | Adapter sequences                  | No       |

---

## Comparison Summary

| Criterion              | nf-core/demo (Nextflow)                    | bio/fastp wrapper (Snakemake)           |
|------------------------|--------------------------------------------|-----------------------------------------|
| **Repository**         | github.com/nf-core/demo                    | github.com/snakemake/snakemake-wrappers |
| **Steps**              | 3 (FASTQC + SEQTK_TRIM + MULTIQC)         | 1 (fastp only)                          |
| **Input**              | FASTQ (via samplesheet CSV)                | FASTQ (direct file paths)              |
| **Output**             | Trimmed FASTQ + QC reports                 | Trimmed FASTQ + QC reports             |
| **arm64 support**      | Native via docker_arm profile              | Native via Conda (Bioconda aarch64)    |
| **Container registry** | community.wave.seqera.io (Seqera)          | Bioconda/Conda or Wave on-demand       |
| **License**            | MIT                                        | MIT                                    |
| **Latest release**     | v1.1.0 (Jan 2026)                          | v9.3.0 (Mar 2026)                      |
| **Maintenance**        | nf-core community                          | Snakemake community                    |
| **Complexity**         | Low (but has samplesheet overhead)         | Minimal (single rule)                  |

---

## arm64 Verification Notes

### Bioconda fastp arm64 availability

fastp is listed in Bioconda with explicit support for:
- `linux-aarch64` (Linux ARM64, e.g., Docker on Apple Silicon)
- `osx-arm64` (native macOS Apple Silicon)

This means both the Snakemake Conda route and the Nextflow Conda route will install native arm64 binaries.

### Seqera Containers (nf-core approach)

Since nf-core tools 3.4.0, all module containers are automatically built for both `linux/amd64` and `linux/arm64` via the Seqera Containers service. The `docker_arm` profile selects arm64 images automatically.

### BioContainers (legacy)

BioContainers on quay.io historically only provided amd64 images. As of 2024-2025, multi-arch support has been improving but is not guaranteed for all tools. The Seqera Containers approach is more reliable for arm64.

---

## Sources

- nf-core/demo: https://github.com/nf-core/demo
- nf-core/demo docs: https://nf-co.re/demo/1.0.0/
- Snakemake fastp wrapper: https://snakemake-wrappers.readthedocs.io/en/stable/wrappers/bio/fastp.html
- Snakemake wrappers releases: https://github.com/snakemake/snakemake-wrappers/releases
- Seqera Containers migration: https://nf-co.re/blog/2024/seqera-containers-part-2
- Seqera Containers service: https://seqera.io/containers/
- Bioconda fastp recipe: https://bioconda.github.io/recipes/fastp/README.html
- BioContainers fastp (quay.io): https://quay.io/repository/biocontainers/fastp
- BioContainers arm64 issue: https://github.com/BioContainers/containers/issues/425
