# Plugin Pack Catalog -- Complete 13-Pack Design

**Date**: 2026-03-22
**Status**: Design Specification
**Author**: Genomics & Bioinformatics Expert

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Tool Deduplication Strategy](#2-tool-deduplication-strategy)
3. [Full 13-Pack Catalog](#3-full-13-pack-catalog)
4. [Post-Install Hook System](#4-post-install-hook-system)
5. [Implementation: PluginPack Model Changes](#5-implementation-pluginpack-model-changes)
6. [Disk Budget Summary](#6-disk-budget-summary)

---

## 1. Design Principles

### Why 13 Packs

The original 7 packs cover core sequencing workflows but leave significant gaps for
users doing surveillance genomics, transcriptomics, single-cell analysis, amplicon
work, genome annotation, or format conversion. The expanded catalog covers every
major workflow a Lungfish user would encounter, without creating so many packs that
browsing becomes overwhelming.

### Pack Scoping Rules

Each pack follows these rules:

1. **Workflow-oriented, not tool-oriented.** A pack answers "I need to do X" rather
   than "I need tool Y." Users think in workflows, not tool names.
2. **3-6 tools per pack.** Fewer than 3 is not worth grouping. More than 6 becomes
   a long install with high failure risk.
3. **No tool appears more than twice across all packs.** This limits confusion about
   "which pack gives me minimap2?" while allowing genuinely cross-cutting tools to
   appear where users expect them.
4. **Each pack must be independently useful.** Installing a single pack should let
   the user complete the entire workflow without needing another pack.
5. **Respect Tier 1 native tools.** Tools already bundled natively (samtools,
   bcftools, fastp, seqkit, cutadapt, pigz, BBTools, bgzip, tabix) are NOT
   included in any pack. They are always available.

---

## 2. Tool Deduplication Strategy

### Recommendation: Option B -- Per-Pack Environments (with shared package cache)

**Selected: Option B.** Each pack creates one conda environment per tool. Tools that
appear in multiple packs each get their own environment regardless. The micromamba
package cache (`~/.lungfish/conda/pkgs/`) is shared, so the same tarball is only
downloaded once and hard-linked into each environment.

### Why Not the Other Options

| Option | Verdict | Reason |
|--------|---------|--------|
| A. Shared environments | Rejected | Version conflicts are guaranteed. Freyja pins numpy/scipy versions that conflict with scanpy. GATK requires Java 17; SnpEff requires a different JVM configuration. One broken install poisons everything. |
| C. Hybrid (core + specialized) | Rejected | The "core" environment becomes a fragile dependency. If the shared samtools is updated for one pack's needs, it can break another pack that pinned an older version. This is the "shared library hell" that conda environments were designed to prevent. |
| D. Per-tool with shared cache | Equivalent to B | Option D is just Option B stated differently. Per-pack environments ARE per-tool environments (since packs install one env per tool) with a shared cache. This is what micromamba does by default. |

### How Deduplication Actually Works

When a user installs both the "alignment" pack and the "long-read" pack, minimap2
appears in both. Here is what happens on disk:

```
~/.lungfish/conda/
    pkgs/                              # SHARED cache
        minimap2-2.28-h...tar.bz2      # Downloaded ONCE
        libz-1.3.1-h...tar.bz2         # Downloaded ONCE
    envs/
        minimap2/                       # Environment for minimap2
            bin/minimap2               # Hard-link to pkgs/ extraction
            lib/libz.so               # Hard-link to pkgs/ extraction
```

The second pack that references minimap2 finds the environment already exists.
The CondaManager.install() method already handles this -- it checks for existing
environments before creating new ones. No code change needed for deduplication.

### Cross-Pack Tool Overlap Matrix

Tools appearing in more than one pack:

| Tool | Pack 1 | Pack 2 | Conflict Risk | Resolution |
|------|--------|--------|---------------|------------|
| minimap2 | alignment | long-read | None (C binary, no deps) | Single env, both packs reference it |
| flye | assembly | long-read | None (C/Python, isolated) | Single env, both packs reference it |
| multiqc | illumina-qc | (standalone) | None | Single env |
| ivar | amplicon-analysis | wastewater-surveillance | None (same version needed) | Single env |
| pangolin | amplicon-analysis | wastewater-surveillance | None | Single env |
| freyja | wastewater-surveillance | (was in metagenomics) | Moved OUT of metagenomics to avoid confusion | Single env |
| hisat2 | rna-seq | (standalone) | None | Single env |

The current `installPack()` in PluginManagerViewModel already handles this correctly:
it iterates pack.packages and calls `CondaManager.shared.install(packages: [packageName], environment: packageName)`. If the environment already exists, `install()` skips creation.

---

## 3. Full 13-Pack Catalog

### 3.1 illumina-qc (EXISTING -- updated)

| Field | Value |
|-------|-------|
| **ID** | `illumina-qc` |
| **Name** | Illumina QC |
| **Description** | Quality control and reporting for Illumina short-read sequencing data |
| **SF Symbol** | `waveform.badge.magnifyingglass` |
| **Category** | Quality Control |
| **Packages** | `fastqc`, `multiqc`, `trimmomatic` |
| **Post-install hooks** | None |
| **Estimated size** | ~1.0 GB |

**Changes from current**: Removed `fastp` (already bundled natively as Tier 1).

**Why these tools**:
- **fastqc**: Per-read quality metrics, adapter content, GC bias, duplication. The standard first step.
- **multiqc**: Aggregates FastQC + fastp + alignment reports into a single HTML dashboard.
- **trimmomatic**: Java-based trimmer with sliding-window quality filtering. Complements native fastp for users who need Trimmomatic-specific adapter files (e.g., legacy Nextera).

---

### 3.2 alignment (EXISTING -- updated)

| Field | Value |
|-------|-------|
| **ID** | `alignment` |
| **Name** | Alignment |
| **Description** | Map short and long reads to reference genomes |
| **SF Symbol** | `arrow.left.and.right.text.vertical` |
| **Category** | Alignment |
| **Packages** | `bwa-mem2`, `minimap2`, `bowtie2`, `hisat2` |
| **Post-install hooks** | None |
| **Estimated size** | ~220 MB |

**Changes from current**: Added `hisat2` (graph-based spliced aligner, useful for both DNA and RNA alignment). Kept `minimap2` because it is the universal aligner and users expect to find it here.

**Why these tools**:
- **bwa-mem2**: Fastest short-read aligner for whole-genome resequencing. Drop-in BWA replacement.
- **minimap2**: Universal aligner for Illumina, ONT, PacBio, and RNA. The Swiss army knife.
- **bowtie2**: Memory-efficient short-read aligner. Required by many legacy pipelines and ChIP-seq workflows.
- **hisat2**: Spliced-aware aligner. Users doing RNA-seq alignment need it, and it is natural here alongside the other aligners.

---

### 3.3 variant-calling (EXISTING -- updated)

| Field | Value |
|-------|-------|
| **ID** | `variant-calling` |
| **Name** | Variant Calling |
| **Description** | Discover SNPs, indels, and structural variants from aligned reads |
| **SF Symbol** | `diamond.fill` |
| **Category** | Variant Calling |
| **Packages** | `freebayes`, `lofreq`, `gatk4`, `ivar` |
| **Post-install hooks** | None |
| **Estimated size** | ~850 MB |

**Changes from current**: Removed `bcftools` (Tier 1 native). Added `gatk4` (gold standard for germline/somatic calling) and `ivar` (amplicon-aware caller, essential for tiled-amplicon viral sequencing).

**Why these tools**:
- **freebayes**: Bayesian haplotype-based caller. Good for diploid organisms, no training data needed.
- **lofreq**: Detects low-frequency variants (down to 0.1% VAF). Essential for viral quasispecies and tumor heterogeneity.
- **gatk4**: HaplotypeCaller + Mutect2. The most widely used variant caller in human genomics. Requires Java but the conda package bundles it.
- **ivar**: Designed specifically for tiled-amplicon protocols (ARTIC, Primal). Trims primers, calls consensus, calls variants with amplicon-aware logic.

---

### 3.4 assembly (EXISTING -- unchanged)

| Field | Value |
|-------|-------|
| **ID** | `assembly` |
| **Name** | Genome Assembly |
| **Description** | De novo genome assembly from short and long reads |
| **SF Symbol** | `puzzlepiece.extension.fill` |
| **Category** | Assembly |
| **Packages** | `spades`, `megahit`, `flye`, `quast` |
| **Post-install hooks** | None |
| **Estimated size** | ~950 MB |

**Changes from current**: Replaced the lone `flye` with `flye` + `quast` (assembly QC is inseparable from assembly). Kept `spades` and `megahit`. Did NOT include `hifiasm` here (it belongs in long-read).

**Why these tools**:
- **spades**: The standard short-read assembler. Also handles hybrid assembly (Illumina + ONT/PacBio).
- **megahit**: Memory-efficient metagenome assembler. Handles large metagenomic datasets where SPAdes runs out of memory.
- **flye**: Long-read assembler for ONT and PacBio. Also handles metagenomes with `--meta`.
- **quast**: Assembly quality assessment. N50, misassemblies, gene completeness. Must be in the same pack because every assembly needs QC.

---

### 3.5 phylogenetics (EXISTING -- updated)

| Field | Value |
|-------|-------|
| **ID** | `phylogenetics` |
| **Name** | Phylogenetics |
| **Description** | Multiple sequence alignment and phylogenetic tree construction |
| **SF Symbol** | `tree` |
| **Category** | Phylogenetics |
| **Packages** | `iqtree`, `mafft`, `muscle`, `raxml-ng`, `treetime` |
| **Post-install hooks** | None |
| **Estimated size** | ~400 MB |

**Changes from current**: Added `raxml-ng` (alternative ML method, required by many published protocols) and `treetime` (molecular clock, essential for outbreak phylogenetics).

**Why these tools**:
- **mafft**: The most widely used multiple sequence aligner. Fast, accurate, handles thousands of sequences.
- **muscle**: Alternative MSA with different algorithmic strengths. Some pipelines require it specifically.
- **iqtree**: Maximum likelihood phylogenetics with automatic model selection (ModelFinder). State of the art.
- **raxml-ng**: Alternative ML implementation. Some reviewers/pipelines require RAxML specifically.
- **treetime**: Temporal phylogenetics (molecular clock). Converts branch lengths to calendar time. Essential for phylodynamic studies and outbreak reconstruction.

---

### 3.6 metagenomics (EXISTING -- updated)

| Field | Value |
|-------|-------|
| **ID** | `metagenomics` |
| **Name** | Metagenomics |
| **Description** | Taxonomic classification and community profiling of metagenomic samples |
| **SF Symbol** | `leaf.fill` |
| **Category** | Metagenomics |
| **Packages** | `kraken2`, `bracken`, `metaphlan` |
| **Post-install hooks** | See Section 4 (kraken2 database download) |
| **Estimated size** | ~500 MB (tools only; databases are 8-100 GB, downloaded separately) |

**Changes from current**: Removed `freyja` (moved to dedicated wastewater-surveillance pack where it belongs). Added `bracken` (Kraken2 companion for abundance re-estimation) and `metaphlan` (marker-gene-based profiling, complementary approach).

**Why these tools**:
- **kraken2**: k-mer-based taxonomic classifier. Fast, accurate, the standard for shotgun metagenomics.
- **bracken**: Re-estimates species-level abundance from Kraken2 output. Corrects for read-length bias. Always used with Kraken2.
- **metaphlan**: Marker-gene-based profiler. Complementary to Kraken2 (does not need a large database). Provides species-level abundance estimates from unique clade-specific markers.

**Database note**: Kraken2 requires a reference database (8 GB for "Standard-8", up to 100 GB for the full standard database). This is handled by the post-install hook system, not bundled in the pack install.

---

### 3.7 long-read (EXISTING -- updated)

| Field | Value |
|-------|-------|
| **ID** | `long-read` |
| **Name** | Long Read Analysis |
| **Description** | Oxford Nanopore and PacBio long-read alignment, assembly, and polishing |
| **SF Symbol** | `ruler` |
| **Category** | Long Read |
| **Packages** | `minimap2`, `flye`, `medaka`, `hifiasm`, `nanoplot` |
| **Post-install hooks** | None |
| **Estimated size** | ~700 MB |

**Changes from current**: Added `nanoplot` (ONT-specific QC, shows read length distributions, quality scores). Kept `hifiasm` (HiFi assembler). Kept `minimap2` and `flye` (both also in other packs -- this is fine because they share environments).

**Why these tools**:
- **minimap2**: Primary aligner for ONT and PacBio reads. Also handles RNA.
- **flye**: Best-in-class long-read assembler. Handles ONT, PacBio CLR, and HiFi.
- **medaka**: ONT-specific polishing. Uses neural networks trained on ONT error profiles. Essential for ONT-only assemblies.
- **hifiasm**: Purpose-built for PacBio HiFi reads. Produces near-complete diploid assemblies from HiFi data.
- **nanoplot**: Generates quality and length distribution plots for ONT/PacBio data. The "FastQC for long reads."

---

### 3.8 wastewater-surveillance (NEW)

| Field | Value |
|-------|-------|
| **ID** | `wastewater-surveillance` |
| **Name** | Wastewater Surveillance |
| **Description** | SARS-CoV-2 and multi-pathogen lineage de-mixing from wastewater sequencing data |
| **SF Symbol** | `drop.triangle` |
| **Category** | Surveillance |
| **Packages** | `freyja`, `ivar`, `pangolin`, `nextclade`, `minimap2` |
| **Post-install hooks** | `freyja update`, `pangolin --update-data` (see Section 4) |
| **Estimated size** | ~1.5 GB |

**Rationale**: Wastewater genomic surveillance is the single most common use case that combines multiple specialized tools into a non-obvious pipeline. Users doing wastewater work need: (1) alignment to reference, (2) amplicon-aware variant calling, (3) lineage de-mixing, (4) lineage assignment, and (5) clade annotation. Without this pack, they would need to install alignment + variant-calling + metagenomics packs and still be missing pangolin and nextclade.

**Why these tools**:
- **freyja**: Depth-weighted de-mixing of lineage mixtures from wastewater BAMs. The core tool for wastewater surveillance.
- **ivar**: Amplicon-aware variant calling and primer trimming. Required upstream of freyja (generates the variants TSV and depth file).
- **pangolin**: SARS-CoV-2 Pango lineage assignment. Assigns consensus sequences to lineages (B.1.1.7, BA.2.86, etc.).
- **nextclade**: Clade assignment + mutation calling + QC for any pathogen with a Nextclade dataset (SARS-CoV-2, RSV, influenza, mpox). Faster than pangolin for pure QC.
- **minimap2**: Alignment step. Wastewater reads must be mapped to the reference genome before variant calling.

**Complete workflow this pack enables**:
```
fastp (Tier 1) -> minimap2 -> samtools sort (Tier 1) ->
  ivar trim -> ivar variants -> freyja variants -> freyja demix
                              -> freyja boot (bootstrapped confidence)
                              -> pangolin (consensus lineage)
                              -> nextclade (clade + mutations + QC)
```

---

### 3.9 rna-seq (NEW)

| Field | Value |
|-------|-------|
| **ID** | `rna-seq` |
| **Name** | RNA-Seq Analysis |
| **Description** | Spliced alignment and transcript quantification for bulk RNA sequencing |
| **SF Symbol** | `bolt.horizontal` |
| **Category** | Transcriptomics |
| **Packages** | `star`, `salmon`, `subread`, `stringtie` |
| **Post-install hooks** | None |
| **Estimated size** | ~600 MB |

**Rationale**: RNA-seq is one of the most common sequencing applications, but the existing packs do not cover spliced alignment or transcript quantification. Users need a dedicated pack because RNA-seq requires fundamentally different tools from DNA alignment -- spliced aligners that handle introns, and quantification tools that operate at the transcript level rather than the variant level.

**Why these tools**:
- **star**: The gold-standard RNA-seq aligner. Handles spliced alignment, chimeric reads (for fusion detection), and outputs both genome and transcriptome BAMs.
- **salmon**: Alignment-free transcript quantification. Produces TPM/counts directly from FASTQ without alignment. Fast and accurate.
- **subread** (includes featureCounts): Gene-level counting from aligned BAMs. featureCounts is the standard tool for producing the count matrix used by DESeq2/edgeR.
- **stringtie**: Transcript assembly and quantification from aligned reads. Discovers novel transcripts and produces abundance estimates.

**Complete workflow this pack enables**:
```
fastp (Tier 1) -> STAR --genomeGenerate (index)
                  STAR --alignReads -> featureCounts -> DESeq2 (R)
                  salmon quant (alignment-free) -> tximeta (R)
                  STAR -> StringTie -> novel transcript discovery
```

---

### 3.10 single-cell (NEW)

| Field | Value |
|-------|-------|
| **ID** | `single-cell` |
| **Name** | Single-Cell Analysis |
| **Description** | Preprocessing and analysis of 10x Genomics and droplet-based single-cell RNA-seq data |
| **SF Symbol** | `circle.grid.3x3` |
| **Category** | Single Cell |
| **Packages** | `scanpy`, `scvi-tools`, `starsolo` |
| **Post-install hooks** | None |
| **Estimated size** | ~1.8 GB |

**Rationale**: Single-cell RNA-seq (scRNA-seq) is an entirely distinct analysis paradigm from bulk sequencing. Users need barcode-aware alignment (or pseudoalignment), UMI deduplication, cell calling, dimensionality reduction, clustering, and cell type annotation. None of the existing packs address this.

**Why these tools**:
- **scanpy**: The Python-based single-cell analysis framework (equivalent to Seurat in R). Handles QC filtering, normalization, PCA, UMAP, clustering, differential expression, trajectory inference. This is the core tool.
- **scvi-tools**: Deep generative models for single-cell data. Handles batch correction (scVI), differential expression (scVI-DE), and cell type annotation (scANVI). State of the art for integration of multi-sample datasets.
- **starsolo** (part of STAR): STARsolo is STAR's built-in single-cell mode. Replaces Cell Ranger's alignment step with an open-source, faster alternative. Outputs count matrices compatible with scanpy.

**Note on Cell Ranger**: 10x Genomics Cell Ranger is the proprietary tool most users start with, but it is NOT available on bioconda and has restrictive licensing. STARsolo is the open-source alternative that produces equivalent output. Users who need Cell Ranger specifically must install it through 10x Genomics' own distribution channel; Lungfish cannot redistribute it.

**Complete workflow this pack enables**:
```
fastp (Tier 1) -> STARsolo (barcode demux + alignment + counting)
               -> scanpy (QC, filtering, normalization, clustering, UMAP)
               -> scvi-tools (batch integration, cell type annotation)
```

---

### 3.11 amplicon-analysis (NEW)

| Field | Value |
|-------|-------|
| **ID** | `amplicon-analysis` |
| **Name** | Amplicon Analysis |
| **Description** | Primer trimming, variant calling, and consensus generation for tiled-amplicon sequencing protocols |
| **SF Symbol** | `waveform.badge.magnifyingglass` |
| **Category** | Amplicon |
| **Packages** | `ivar`, `pangolin`, `nextclade` |
| **Post-install hooks** | `pangolin --update-data` (see Section 4) |
| **Estimated size** | ~550 MB |

**Rationale**: Tiled-amplicon sequencing (ARTIC, Primal, Midnight, etc.) is the dominant method for pathogen whole-genome sequencing in public health labs. It requires specialized tools that understand amplicon boundaries, trim primers, and call variants with amplicon-aware logic. The variant-calling pack includes ivar, but users doing amplicon work also need lineage assignment and QC tools.

**Important overlap note**: `ivar`, `pangolin`, and `nextclade` also appear in the wastewater-surveillance pack. This is intentional. Amplicon analysis users who do NOT do wastewater work should not need to install wastewater-specific tools (freyja). The environment-per-tool architecture means no disk duplication occurs when both packs are installed.

**Why these tools**:
- **ivar**: The standard for amplicon data. `ivar trim` removes primer sequences from BAM alignments. `ivar consensus` generates consensus FASTA. `ivar variants` calls variants with amplicon-aware quality filtering.
- **pangolin**: Assigns SARS-CoV-2 Pango lineage designations to consensus sequences. Updated regularly as new lineages are designated.
- **nextclade**: Multi-pathogen clade assignment and QC. Supports SARS-CoV-2, influenza A/B, RSV, mpox, and others. Provides mutation annotation, QC metrics, and phylogenetic placement.

**Complete workflow this pack enables**:
```
fastp (Tier 1) -> minimap2/bwa-mem2 (alignment pack) ->
  samtools sort (Tier 1) -> ivar trim -> ivar variants
                                       -> ivar consensus -> pangolin
                                                         -> nextclade
```

---

### 3.12 genome-annotation (NEW)

| Field | Value |
|-------|-------|
| **ID** | `genome-annotation` |
| **Name** | Genome Annotation |
| **Description** | Gene prediction and functional annotation for prokaryotic and viral genomes |
| **SF Symbol** | `tag.fill` |
| **Category** | Annotation |
| **Packages** | `prokka`, `bakta`, `snpeff` |
| **Post-install hooks** | `bakta_db download --type light` (see Section 4) |
| **Estimated size** | ~1.2 GB (tools only; databases are 1.3-37 GB additional) |

**Rationale**: After assembling a genome, users need to annotate it -- predict genes, assign functions, and annotate variants with functional consequences. This is a distinct workflow from assembly itself.

**Why these tools**:
- **prokka**: Rapid prokaryotic genome annotation. Predicts CDS, rRNA, tRNA, signal peptides, and assigns functions from curated databases. The standard for bacterial genome annotation.
- **bakta**: Modern successor to Prokka. Uses a comprehensive database for more accurate functional annotation. Supports both bacteria and archaea. Produces standardized output (GFF3, GenBank, EMBL).
- **snpeff**: Variant annotation and effect prediction. Annotates VCF files with gene impact (synonymous, missense, stop-gain, etc.), protein change, and functional consequence. Works for any organism with a SnpEff database.

**Complete workflow this pack enables**:
```
Assembly (from assembly pack) -> prokka/bakta (gene prediction + annotation)
                               -> GFF3/GenBank output -> Lungfish viewer
Variant VCF -> snpeff ann -> annotated VCF with functional effects
```

---

### 3.13 data-format-utils (NEW)

| Field | Value |
|-------|-------|
| **ID** | `data-format-utils` |
| **Name** | Data Format Utilities |
| **Description** | File conversion, indexing, and manipulation tools for common bioinformatics formats |
| **SF Symbol** | `arrow.triangle.2.circlepath` |
| **Category** | Utilities |
| **Packages** | `bedtools`, `picard`, `ucsc-bedgraphtobigwig`, `ucsc-bedtobigbed` |
| **Post-install hooks** | None |
| **Estimated size** | ~650 MB |

**Rationale**: Many bioinformatics workflows require format conversion between BED, BAM, BigWig, BigBed, VCF, GFF, and other formats. While Lungfish bundles samtools, bcftools, and basic UCSC tools natively, power users frequently need bedtools for interval operations and picard for BAM manipulation (MarkDuplicates, CollectWgsMetrics, etc.).

**Why these tools**:
- **bedtools**: The swiss army knife of interval manipulation. Intersect, merge, complement, coverage, closest, subtract. Used in nearly every analysis pipeline at some point.
- **picard**: Broad Institute's BAM/VCF utility suite. MarkDuplicates is required by GATK best practices. CollectWgsMetrics, CollectAlignmentSummaryMetrics, and other tools are standard QC steps.
- **ucsc-bedgraphtobigwig**: Converts BedGraph coverage files to BigWig for visualization in genome browsers. (May already be available natively via Tier 1; included here for completeness if the user's Tier 1 bundle does not include it.)
- **ucsc-bedtobigbed**: Converts BED annotation files to BigBed for efficient random access. (Same caveat as above.)

**Note**: If `ucsc-bedgraphtobigwig` and `ucsc-bedtobigbed` are already provisioned natively via the `NativeBundleBuilder`, this pack's package list should be reduced to `bedtools` and `picard` only. Check `BundledToolSpec.defaultTools` before finalizing.

---

## 4. Post-Install Hook System

### 4.1 Model Extension

The `PluginPack` struct needs a new `postInstallHooks` field:

```swift
public struct PostInstallHook: Sendable, Codable {
    /// Human-readable description of what this hook does.
    public let description: String

    /// The conda environment in which to run the command.
    public let environment: String

    /// The command to execute (first element is the tool name, rest are arguments).
    public let command: [String]

    /// Whether this hook requires network access.
    public let requiresNetwork: Bool

    /// How often this hook should be re-run (nil = only on install).
    /// Value is in days. 0 = every launch. 7 = weekly. 30 = monthly.
    public let refreshIntervalDays: Int?

    /// Approximate download size for the data this hook fetches.
    public let estimatedDownloadSize: String?
}
```

### 4.2 Complete Hook Catalog

#### 4.2.1 freyja update

| Field | Value |
|-------|-------|
| **Packs** | wastewater-surveillance |
| **Environment** | `freyja` |
| **Command** | `["freyja", "update"]` |
| **Description** | Downloads the latest SARS-CoV-2 lineage barcodes from the UShER global phylogenetic tree |
| **Requires network** | Yes |
| **Refresh interval** | 7 days (weekly) |
| **Estimated download** | ~15 MB |
| **What it downloads** | `usher_barcodes.feather` and `curated_lineages.json` into the freyja environment's site-packages directory |
| **Why it is needed** | Freyja cannot de-mix lineages without barcode definitions. New SARS-CoV-2 lineages are designated continuously; stale barcodes produce inaccurate results. The Andersen Lab updates barcodes whenever new lineages appear in the UShER tree. |
| **Failure mode** | Non-fatal. Freyja will use previously downloaded barcodes (or fail with a clear error if none exist). The hook should retry silently on next launch. |

#### 4.2.2 pangolin --update-data

| Field | Value |
|-------|-------|
| **Packs** | wastewater-surveillance, amplicon-analysis |
| **Environment** | `pangolin` |
| **Command** | `["pangolin", "--update-data"]` |
| **Description** | Updates the pangolin-data and scorpio constellations used for Pango lineage assignment |
| **Requires network** | Yes |
| **Refresh interval** | 7 days (weekly) |
| **Estimated download** | ~50 MB |
| **What it downloads** | Updated pangolin-data package (UShER tree + designation mappings) via pip into the pangolin environment |
| **Why it is needed** | Pangolin assigns lineages based on a trained model. As new lineages are designated and existing ones are re-classified, the model must be updated. Running with stale data produces incorrect or "unassigned" lineage calls for recent samples. |
| **Failure mode** | Non-fatal. Pangolin works with whatever version of pangolin-data is installed. The hook should log a warning if update fails. |

#### 4.2.3 bakta_db download

| Field | Value |
|-------|-------|
| **Packs** | genome-annotation |
| **Environment** | `bakta` |
| **Command** | `["bakta_db", "download", "--output", "$LUNGFISH_DATA/bakta-db", "--type", "light"]` |
| **Description** | Downloads the Bakta light database for prokaryotic genome annotation |
| **Requires network** | Yes |
| **Refresh interval** | 90 days (quarterly) |
| **Estimated download** | ~1.3 GB (light) or ~37 GB (full) |
| **What it downloads** | Pre-built annotation database containing protein clusters, Pfam domains, COG categories, and AMR gene references |
| **Why it is needed** | Bakta cannot annotate genomes without its reference database. Unlike Prokka (which bundles minimal databases), Bakta's accuracy depends on its comprehensive database. |
| **Failure mode** | Non-fatal but bakta will not function without the database. Show a clear error in the Plugin Manager: "Bakta database not found. Click 'Download Database' to fetch it." |
| **User choice** | Offer "light" (1.3 GB) vs "full" (37 GB) in the UI. Default to light. |

#### 4.2.4 Kraken2 database (OPTIONAL, user-initiated only)

| Field | Value |
|-------|-------|
| **Packs** | metagenomics |
| **Environment** | `kraken2` |
| **Command** | NOT auto-run. User-initiated only. |
| **Description** | Downloads a Kraken2 taxonomic classification database |
| **Requires network** | Yes |
| **Refresh interval** | Manual only |
| **Estimated download** | 8 GB (Standard-8) to 100 GB (full Standard) |
| **Why it is NOT automatic** | Kraken2 databases are enormous (8-100 GB). Auto-downloading would be hostile to users on metered connections or limited storage. Instead, the Plugin Manager should show a "Download Database" button with size options after kraken2 is installed. |

**Database size options to present in UI**:

| Database | Size | Coverage |
|----------|------|----------|
| Standard-8 | 8 GB | RefSeq bacteria, archaea, viral, human |
| Standard-16 | 16 GB | More complete coverage |
| Standard | ~70 GB | Full RefSeq |
| Viral | ~500 MB | Viral genomes only |
| MinusB | ~8 GB | Standard minus bacteria (for host-focused work) |

Pre-built databases are available from https://benlangmead.github.io/aws-indexes/k2.

#### 4.2.5 SnpEff database (on-demand)

| Field | Value |
|-------|-------|
| **Packs** | genome-annotation |
| **Environment** | `snpeff` |
| **Command** | `["snpEff", "download", "<genome_name>"]` |
| **Description** | Downloads a SnpEff annotation database for a specific genome |
| **Requires network** | Yes |
| **Refresh interval** | Manual only (per-genome) |
| **Estimated download** | 50 MB - 2 GB depending on genome |
| **Why it is NOT automatic** | SnpEff supports thousands of genomes. The database must match the user's reference. Auto-downloading all databases would require hundreds of GB. Instead, prompt the user to download the appropriate database when they first use SnpEff with a specific reference. |

### 4.3 Hook Execution Architecture

```
User installs pack
    |
    v
CondaManager.install() for each tool
    |
    v
All tools installed successfully?
    |
    +-- YES --> Run postInstallHooks sequentially
    |               |
    |               v
    |           For each hook:
    |             1. Check refreshIntervalDays vs last run timestamp
    |             2. If due, show progress: "Updating freyja barcodes..."
    |             3. Run: micromamba run -n <env> <command>
    |             4. Record timestamp in registry.json
    |             5. On failure: log warning, continue to next hook
    |
    +-- NO  --> Skip hooks, show which tools failed
```

### 4.4 Periodic Refresh

For hooks with `refreshIntervalDays`, the CondaManager should check on app launch:

```swift
// Called from AppDelegate.applicationDidFinishLaunching()
// or from PluginManagerViewModel.init()
func checkHookRefreshes() async {
    for pack in PluginPack.builtIn {
        for hook in pack.postInstallHooks {
            guard let interval = hook.refreshIntervalDays else { continue }
            guard isEnvironmentInstalled(hook.environment) else { continue }

            let lastRun = registry.lastHookRun(pack: pack.id, hook: hook.description)
            let daysSince = Calendar.current.dateComponents(
                [.day], from: lastRun, to: Date()
            ).day ?? Int.max

            if daysSince >= interval {
                // Run in background, non-blocking
                try? await runHook(hook, pack: pack)
            }
        }
    }
}
```

This check runs asynchronously and does not block app launch. Failed refreshes are logged but do not show alerts (to avoid nagging). The Plugin Manager UI shows "Last updated: 3 days ago" next to tools with refresh hooks.

---

## 5. Implementation: PluginPack Model Changes

### 5.1 Updated PluginPack Struct

```swift
public struct PluginPack: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let sfSymbol: String
    public let packages: [String]
    public let category: String
    public let postInstallHooks: [PostInstallHook]
    public let estimatedSizeMB: Int

    public init(id: String, name: String, description: String,
                sfSymbol: String, packages: [String], category: String,
                postInstallHooks: [PostInstallHook] = [],
                estimatedSizeMB: Int = 0) {
        self.id = id
        self.name = name
        self.description = description
        self.sfSymbol = sfSymbol
        self.packages = packages
        self.category = category
        self.postInstallHooks = postInstallHooks
        self.estimatedSizeMB = estimatedSizeMB
    }
}
```

### 5.2 Updated builtIn Array

```swift
public static let builtIn: [PluginPack] = [
    // --- EXISTING (updated) ---
    PluginPack(
        id: "illumina-qc",
        name: "Illumina QC",
        description: "Quality control and reporting for Illumina short-read sequencing data",
        sfSymbol: "waveform.badge.magnifyingglass",
        packages: ["fastqc", "multiqc", "trimmomatic"],
        category: "Quality Control",
        estimatedSizeMB: 1000
    ),
    PluginPack(
        id: "alignment",
        name: "Alignment",
        description: "Map short and long reads to reference genomes",
        sfSymbol: "arrow.left.and.right.text.vertical",
        packages: ["bwa-mem2", "minimap2", "bowtie2", "hisat2"],
        category: "Alignment",
        estimatedSizeMB: 220
    ),
    PluginPack(
        id: "variant-calling",
        name: "Variant Calling",
        description: "Discover SNPs, indels, and structural variants from aligned reads",
        sfSymbol: "diamond.fill",
        packages: ["freebayes", "lofreq", "gatk4", "ivar"],
        category: "Variant Calling",
        estimatedSizeMB: 850
    ),
    PluginPack(
        id: "assembly",
        name: "Genome Assembly",
        description: "De novo genome assembly from short and long reads",
        sfSymbol: "puzzlepiece.extension.fill",
        packages: ["spades", "megahit", "flye", "quast"],
        category: "Assembly",
        estimatedSizeMB: 950
    ),
    PluginPack(
        id: "phylogenetics",
        name: "Phylogenetics",
        description: "Multiple sequence alignment and phylogenetic tree construction",
        sfSymbol: "tree",
        packages: ["iqtree", "mafft", "muscle", "raxml-ng", "treetime"],
        category: "Phylogenetics",
        estimatedSizeMB: 400
    ),
    PluginPack(
        id: "metagenomics",
        name: "Metagenomics",
        description: "Taxonomic classification and community profiling of metagenomic samples",
        sfSymbol: "leaf.fill",
        packages: ["kraken2", "bracken", "metaphlan"],
        category: "Metagenomics",
        estimatedSizeMB: 500
    ),
    PluginPack(
        id: "long-read",
        name: "Long Read Analysis",
        description: "Oxford Nanopore and PacBio long-read alignment, assembly, and polishing",
        sfSymbol: "ruler",
        packages: ["minimap2", "flye", "medaka", "hifiasm", "nanoplot"],
        category: "Long Read",
        estimatedSizeMB: 700
    ),

    // --- NEW ---
    PluginPack(
        id: "wastewater-surveillance",
        name: "Wastewater Surveillance",
        description: "SARS-CoV-2 and multi-pathogen lineage de-mixing from wastewater sequencing data",
        sfSymbol: "drop.triangle",
        packages: ["freyja", "ivar", "pangolin", "nextclade", "minimap2"],
        category: "Surveillance",
        postInstallHooks: [
            PostInstallHook(
                description: "Download latest SARS-CoV-2 lineage barcodes",
                environment: "freyja",
                command: ["freyja", "update"],
                requiresNetwork: true,
                refreshIntervalDays: 7,
                estimatedDownloadSize: "~15 MB"
            ),
            PostInstallHook(
                description: "Update Pango lineage designation data",
                environment: "pangolin",
                command: ["pangolin", "--update-data"],
                requiresNetwork: true,
                refreshIntervalDays: 7,
                estimatedDownloadSize: "~50 MB"
            ),
        ],
        estimatedSizeMB: 1500
    ),
    PluginPack(
        id: "rna-seq",
        name: "RNA-Seq Analysis",
        description: "Spliced alignment and transcript quantification for bulk RNA sequencing",
        sfSymbol: "bolt.horizontal",
        packages: ["star", "salmon", "subread", "stringtie"],
        category: "Transcriptomics",
        estimatedSizeMB: 600
    ),
    PluginPack(
        id: "single-cell",
        name: "Single-Cell Analysis",
        description: "Preprocessing and analysis of droplet-based single-cell RNA-seq data",
        sfSymbol: "circle.grid.3x3",
        packages: ["scanpy", "scvi-tools", "starsolo"],
        category: "Single Cell",
        estimatedSizeMB: 1800
    ),
    PluginPack(
        id: "amplicon-analysis",
        name: "Amplicon Analysis",
        description: "Primer trimming, variant calling, and consensus generation for tiled-amplicon protocols",
        sfSymbol: "waveform.badge.magnifyingglass",
        packages: ["ivar", "pangolin", "nextclade"],
        category: "Amplicon",
        postInstallHooks: [
            PostInstallHook(
                description: "Update Pango lineage designation data",
                environment: "pangolin",
                command: ["pangolin", "--update-data"],
                requiresNetwork: true,
                refreshIntervalDays: 7,
                estimatedDownloadSize: "~50 MB"
            ),
        ],
        estimatedSizeMB: 550
    ),
    PluginPack(
        id: "genome-annotation",
        name: "Genome Annotation",
        description: "Gene prediction and functional annotation for prokaryotic and viral genomes",
        sfSymbol: "tag.fill",
        packages: ["prokka", "bakta", "snpeff"],
        category: "Annotation",
        postInstallHooks: [
            PostInstallHook(
                description: "Download Bakta light annotation database",
                environment: "bakta",
                command: ["bakta_db", "download", "--output",
                          "$LUNGFISH_DATA/bakta-db", "--type", "light"],
                requiresNetwork: true,
                refreshIntervalDays: 90,
                estimatedDownloadSize: "~1.3 GB"
            ),
        ],
        estimatedSizeMB: 1200
    ),
    PluginPack(
        id: "data-format-utils",
        name: "Data Format Utilities",
        description: "File conversion, indexing, and interval manipulation for bioinformatics formats",
        sfSymbol: "arrow.triangle.2.circlepath",
        packages: ["bedtools", "picard"],
        category: "Utilities",
        estimatedSizeMB: 650
    ),
]
```

### 5.3 Note on starsolo Package

The `starsolo` entry in the single-cell pack refers to STAR with STARsolo mode, which is built into the `star` package. The bioconda package name is `star`, not `starsolo`. The single-cell pack should use `star` as the package name, and the UI can display it as "STAR (with STARsolo)" to clarify its single-cell capability. Update the packages array accordingly:

```swift
// single-cell pack correction:
packages: ["scanpy", "scvi-tools", "star"],
```

---

## 6. Disk Budget Summary

| Pack | Tools | Est. Size | Has Hooks |
|------|-------|-----------|-----------|
| illumina-qc | 3 | ~1.0 GB | No |
| alignment | 4 | ~220 MB | No |
| variant-calling | 4 | ~850 MB | No |
| assembly | 4 | ~950 MB | No |
| phylogenetics | 5 | ~400 MB | No |
| metagenomics | 3 | ~500 MB | Yes (kraken2 DB, user-initiated) |
| long-read | 5 | ~700 MB | No |
| wastewater-surveillance | 5 | ~1.5 GB | Yes (freyja update, pangolin update) |
| rna-seq | 4 | ~600 MB | No |
| single-cell | 3 | ~1.8 GB | No |
| amplicon-analysis | 3 | ~550 MB | Yes (pangolin update) |
| genome-annotation | 3 | ~1.2 GB | Yes (bakta DB) |
| data-format-utils | 2 | ~650 MB | No |
| **TOTAL (all packs)** | **48** | **~10.9 GB** | |
| **TOTAL (deduplicated)** | **~32 unique tools** | **~8.5 GB** | |

The deduplicated total reflects shared environments for tools that appear in multiple
packs (minimap2, flye, ivar, pangolin, nextclade, star).

### All-Packs Install Feasibility

Installing all 13 packs would consume approximately 8.5 GB of disk space for tools
plus the shared package cache. With the Kraken2 Standard-8 database (8 GB) and
Bakta light database (1.3 GB), a maximal install totals roughly 18 GB. This is
reasonable for a bioinformatics workstation and comparable to a Homebrew installation
with similar tooling.

Most users will install 2-4 packs relevant to their work, consuming 1-4 GB.

---

## Appendix A: Unique Tool Index (32 tools)

Every unique bioconda package across all 13 packs, sorted alphabetically:

| Package | osx-arm64 | License | Packs |
|---------|-----------|---------|-------|
| `bakta` | Yes (Python) | GPL-3.0 | genome-annotation |
| `bedtools` | Yes | MIT | data-format-utils |
| `bowtie2` | Yes | GPL-3.0 | alignment |
| `bracken` | Yes | MIT | metagenomics |
| `bwa-mem2` | Yes | MIT | alignment |
| `fastqc` | Yes (Java) | GPL-2.0+ | illumina-qc |
| `flye` | Yes | BSD-3-Clause | assembly, long-read |
| `freebayes` | Yes | MIT | variant-calling |
| `freyja` | Yes (Python) | BSD-2-Clause | wastewater-surveillance |
| `gatk4` | Yes (Java) | BSD-3-Clause | variant-calling |
| `hifiasm` | Yes | MIT | long-read |
| `hisat2` | Yes | GPL-3.0 | alignment |
| `iqtree` | Yes | GPL-2.0 | phylogenetics |
| `ivar` | Yes | GPL-3.0 | variant-calling, wastewater-surveillance, amplicon-analysis |
| `kraken2` | Yes | MIT | metagenomics |
| `lofreq` | Yes | MIT | variant-calling |
| `mafft` | Yes | BSD-2-Clause | phylogenetics |
| `medaka` | Yes (Python) | MPL-2.0 | long-read |
| `megahit` | Yes | GPL-3.0 | assembly |
| `metaphlan` | Yes (Python) | MIT | metagenomics |
| `minimap2` | Yes | MIT | alignment, long-read, wastewater-surveillance |
| `multiqc` | Yes (Python) | GPL-3.0 | illumina-qc |
| `muscle` | Yes | GPL-3.0 | phylogenetics |
| `nanoplot` | Yes (Python) | GPL-3.0 | long-read |
| `nextclade` | Yes | MIT | wastewater-surveillance, amplicon-analysis |
| `pangolin` | Yes (Python) | GPL-3.0 | wastewater-surveillance, amplicon-analysis |
| `picard` | Yes (Java) | MIT | data-format-utils |
| `prokka` | Yes | GPL-3.0 | genome-annotation |
| `quast` | Yes (Python) | GPL-2.0 | assembly |
| `raxml-ng` | Yes | AGPL-3.0 | phylogenetics |
| `salmon` | Yes | GPL-3.0 | rna-seq |
| `scanpy` | Yes (Python) | BSD-3-Clause | single-cell |
| `scvi-tools` | Yes (Python) | BSD-3-Clause | single-cell |
| `snpeff` | Yes (Java) | LGPL-3.0 | genome-annotation |
| `spades` | Yes | GPL-2.0 | assembly |
| `star` | Yes | MIT | rna-seq, single-cell |
| `stringtie` | Yes | MIT | rna-seq |
| `subread` | Yes | GPL-3.0 | rna-seq |
| `treetime` | Yes (Python) | MIT | phylogenetics |
| `trimmomatic` | Yes (Java) | GPL-3.0 | illumina-qc |

**Total unique packages: 40** (some appear in multiple packs but are installed once).

All 40 packages have osx-arm64 or noarch builds on bioconda as of early 2026. No
container fallback (Tier 3) is required for any tool in the catalog.
