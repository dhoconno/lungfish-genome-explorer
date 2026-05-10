# Bioinformatics Tool Format Matrix

**Research Date:** 2026-02-03
**Purpose:** Comprehensive matrix of input/output formats for bioinformatics tools that Lungfish will support

---

## Table of Contents

1. [Assemblers](#1-assemblers)
   - [SPAdes](#spades)
   - [MEGAHIT](#megahit)
   - [Trinity](#trinity)
   - [Flye](#flye)
2. [Aligners/Mappers](#2-alignersmappers)
   - [BWA](#bwa)
   - [minimap2](#minimap2)
   - [Bowtie2](#bowtie2)
   - [STAR](#star)
3. [Variant Callers](#3-variant-callers)
   - [bcftools](#bcftools)
   - [GATK](#gatk)
   - [FreeBayes](#freebayes)
4. [Utilities](#4-utilities)
   - [samtools](#samtools)
   - [bedtools](#bedtools)
5. [Format Conversion Paths](#5-format-conversion-paths)
6. [Index File Requirements](#6-index-file-requirements)
7. [Format Summary Table](#7-format-summary-table)

---

## 1. Assemblers

### SPAdes

**Description:** De novo genome assembler for Illumina and IonTorrent reads

#### Input Formats

| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTQ (.fq, .fastq) | Required (for error correction) | Paired-end, mate-pairs, or single reads |
| FASTQ.gz | Required (for error correction) | Gzip-compressed FASTQ |
| FASTA (.fa, .fasta) | Optional | For reads without quality scores |
| BAM | Optional | Aligned or unaligned reads |
| SRA | Optional | NCBI SRA format (read directly) |

#### Output Formats

| File | Format | Description |
|------|--------|-------------|
| `contigs.fasta` | FASTA | Assembled contigs |
| `scaffolds.fasta` | FASTA | Scaffolded sequences (recommended output) |
| `assembly_graph_with_scaffolds.gfa` | GFA 1.2 | Assembly graph with scaffold paths |
| `assembly_graph.fastg` | FASTG | Assembly graph (legacy format) |
| `corrected/*.fastq.gz` | FASTQ.gz | Error-corrected reads from BayesHammer |

#### Indexing Requirements
- None for input files
- Output files can be indexed with `samtools faidx` for downstream use

#### Key Constraints
- Illumina and IonTorrent libraries cannot be mixed
- For error correction, reads must be in FASTQ or BAM format
- Paired reads must be in matching order in R1/R2 files
- Memory intensive: ~500GB-1TB RAM for mammalian genomes

**Sources:**
- [SPAdes Input Documentation](https://ablab.github.io/spades/input.html)
- [SPAdes Output Documentation](https://ablab.github.io/spades/output.html)

---

### MEGAHIT

**Description:** Ultra-fast and memory-efficient metagenome assembler

#### Input Formats

| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTQ (.fq, .fastq) | Required | Paired-end or single-end reads |
| FASTA (.fa, .fasta) | Required | Alternative to FASTQ |
| .gz compressed | Supported | Gzip-compressed files |
| .bz2 compressed | Supported | Bzip2-compressed files |

#### Input Options
```bash
-1 <pe1>        # Paired-end #1 files (comma-separated)
-2 <pe2>        # Paired-end #2 files (comma-separated)
--12 <pe12>     # Interleaved paired-end files
-r/--read <se>  # Single-end files
```

#### Output Formats

| File | Format | Description |
|------|--------|-------------|
| `final.contigs.fa` | FASTA | Assembled contigs |
| `k*.contig.fa` | FASTA | Intermediate contigs per k-mer |
| `*.fastg` | FASTG | Assembly graph (generated separately) |

#### Indexing Requirements
- None for input
- FASTG can be generated from intermediate contigs:
  ```bash
  megahit_core contig2fastg 119 out/intermediate_contigs/k119.contig.fa > k119.fastg
  ```

#### Key Constraints
- Does NOT produce scaffolds (only contigs)
- k-mer values must be odd numbers
- k-mer step size must be even numbers
- Default k-list: [21,29,39,59,79,99,119,141]

**Sources:**
- [MEGAHIT GitHub](https://github.com/voutcn/megahit)
- [MEGAHIT Documentation](https://www.metagenomics.wiki/tools/assembly/megahit)

---

### Trinity

**Description:** RNA-seq de novo transcriptome assembler

#### Input Formats

| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTQ (.fq, .fastq) | Required | Specify with `--seqType fq` |
| FASTA (.fa, .fasta) | Required | Specify with `--seqType fa` |
| FASTQ.gz | Supported | Gzip-compressed with .gz extension |
| PacBio CCS (long reads) | Optional | Via `--long_reads` parameter (FASTA) |

#### Input Options
```bash
--seqType <fa|fq>     # Specify FASTA or FASTQ
--left <reads_1>      # Left reads for paired-end
--right <reads_2>     # Right reads for paired-end
--single <reads>      # Single-end reads
--SS_lib_type <type>  # Strand-specific: RF, FR, F, or R
--long_reads <file>   # Error-corrected long reads (FASTA)
```

#### Output Formats

| File | Format | Description |
|------|--------|-------------|
| `Trinity.fasta` | FASTA | Assembled transcripts |
| `SuperTranscripts.fasta` | FASTA | Super transcripts (optional) |
| `*.gff` | GFF | Transcript structure annotation (optional) |

#### Indexing Requirements
- None for input
- Output can be indexed for alignment with `salmon index` or `kallisto index`

#### Key Constraints
- Memory: ~1GB RAM per 1M 76bp paired reads
- In silico normalization enabled by default (since Nov 2016)
- Includes built-in Trimmomatic quality trimming option
- SRA files must be converted to FASTQ first

**Sources:**
- [Trinity GitHub Wiki](https://github.com/trinityrnaseq/trinityrnaseq/wiki/Running-Trinity)
- [Trinity FAQ](https://github.com/trinityrnaseq/trinityrnaseq/wiki/Trinity-FAQ)

---

### Flye

**Description:** De novo assembler for long reads (PacBio, ONT)

#### Input Formats

| Format | Required/Optional | Read Type Flag |
|--------|-------------------|----------------|
| FASTA (.fa, .fasta) | Required | Various (see below) |
| FASTQ (.fq, .fastq) | Required | Various (see below) |
| .gz compressed | Supported | Auto-detected |
| BAM | Supported | For polishing step only |

#### Read Type Flags
```bash
--pacbio-raw      # PacBio CLR reads (<20% error)
--pacbio-corr     # Corrected PacBio reads (<3% error)
--pacbio-hifi     # PacBio HiFi reads (<1% error)
--nano-raw        # ONT regular reads (<20% error)
--nano-corr       # Corrected ONT reads (<3% error)
--nano-hq         # ONT Guppy5+ SUP/Q20 reads (3-5% error)
```

#### Output Formats

| File | Format | Description |
|------|--------|-------------|
| `assembly.fasta` | FASTA | Final assembly contigs/scaffolds |
| `assembly_graph.gfa` | GFA | Repeat graph |
| `assembly_info.txt` | TSV | Contig statistics |

#### Indexing Requirements
- None for input
- Output assembly can be indexed with `samtools faidx`

#### Key Constraints
- Mixing different read types NOT supported
- Designed for uncorrected reads (handles correction internally)
- PacBio input assumes subreads (adaptors removed)
- Automatic chimeric read filtering
- Use `--asm-coverage` for high coverage subsampling

**Sources:**
- [Flye GitHub](https://github.com/mikolmogorov/Flye)
- [Flye Usage Documentation](https://github.com/fenderglass/Flye/blob/flye/docs/USAGE.md)

---

## 2. Aligners/Mappers

### BWA

**Description:** Burrows-Wheeler Aligner for short read alignment

#### Input Formats

**Reference:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTA (.fa, .fasta) | Required | Reference genome |

**Reads:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTQ (.fq, .fastq) | Required | Single or paired-end |
| FASTA (.fa, .fasta) | Supported | Without quality scores |
| FASTQ.gz | Supported | Gzip-compressed |
| BAM | Supported | Unaligned reads |

#### Output Formats

| Command | Output Format | Description |
|---------|---------------|-------------|
| `bwa mem` | SAM | Alignment output |
| `bwa aln` | Binary (.sai) | Intermediate (BWA internal only) |
| `bwa samse/sampe` | SAM | Convert .sai to SAM |

#### Indexing Requirements

**Reference Index (Required before alignment):**
```bash
bwa index [-a bwtsw|is] reference.fa
```

Creates 5-6 index files:
- `.amb` - Ambiguous bases
- `.ann` - Annotation
- `.bwt` - BWT index
- `.pac` - Packed sequence
- `.sa` - Suffix array
- `.alt` - ALT contigs (optional)

| Algorithm | Use Case | Memory |
|-----------|----------|--------|
| `bwtsw` | Long genomes (human) | ~5GB |
| `is` | Short genomes (<2GB) | Less memory |

#### Key Constraints
- Index files must be in same directory as reference
- Index must have same basename as reference FASTA
- BWA 0.5.x indexes incompatible with 0.6.x+
- BWA-backtrack: reads up to 100bp
- BWA-MEM: reads 70bp to 1Mbp (recommended)

**Sources:**
- [BWA Manual](https://bio-bwa.sourceforge.net/bwa.shtml)
- [BWA Illumina Documentation](https://www.illumina.com/products/by-type/informatics-products/basespace-sequence-hub/apps/bwa-aligner.html)

---

### minimap2

**Description:** Versatile aligner for long and short reads

#### Input Formats

**Reference:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTA (.fa, .fasta) | Required | Reference sequences |
| FASTA.gz | Supported | Gzip-compressed |
| .mmi | Supported | Pre-built index (faster) |

**Query:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTQ (.fq, .fastq) | Required | Reads with quality |
| FASTA (.fa, .fasta) | Supported | Sequences without quality |
| .gz compressed | Supported | Auto-detected |

#### Output Formats

| Option | Format | Description |
|--------|--------|-------------|
| (default) | PAF | Pairwise mApping Format (lightweight) |
| `-a` | SAM | Standard alignment format |
| `-c` | PAF + CIGAR | PAF with CIGAR in `cg` tag |

#### PAF Format
Tab-delimited with 12+ columns:
1. Query name
2. Query length
3. Query start
4. Query end
5. Strand (+/-)
6. Target name
7. Target length
8. Target start
9. Target end
10. Matches
11. Alignment block length
12. Mapping quality (0-60)

#### Indexing Requirements

**Optional Pre-indexing (speeds up repeated alignments):**
```bash
minimap2 -d reference.mmi reference.fa
```

Creates `.mmi` index file. Recommended for:
- Multiple alignments to same reference
- Human genome (saves minutes per run)

#### Preset Modes
```bash
-x map-pb      # PacBio CLR
-x map-ont     # ONT reads
-x map-hifi    # PacBio HiFi
-x sr          # Short reads
-x splice      # RNA-seq (long reads)
-x asm5        # Assembly-to-reference (~0.1% divergence)
-x asm20       # Assembly-to-reference (~5% divergence)
```

**Sources:**
- [minimap2 Manual](https://lh3.github.io/minimap2/minimap2.html)
- [minimap2 GitHub](https://github.com/lh3/minimap2)

---

### Bowtie2

**Description:** Fast and sensitive short read aligner

#### Input Formats

**Reference:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTA (.fa, .fasta) | Required | For index building |
| Bowtie2 Index | Required | Pre-built index for alignment |

**Reads:**
| Format | Flag | Notes |
|--------|------|-------|
| FASTQ | `-q` (default) | Standard format |
| FASTA | `-f` | No quality scores |
| Raw | `-r` | One sequence per line |
| Interleaved FASTQ | `--interleaved` | Paired reads in single file |
| Unaligned BAM | `-b` | Sorted by read name |
| QSEQ | `--qseq` | Illumina QSEQ format |
| Command-line | `-c` | Sequences as arguments |
| .gz/.bz2 | Supported | Compressed files |

#### Quality Score Encodings
```bash
--phred33      # Phred+33 (default, Illumina 1.8+)
--phred64      # Phred+64 (older Illumina)
```

#### Output Formats

| Output | Format | Notes |
|--------|--------|-------|
| Default | SAM | Unsorted alignment |
| Metrics | Text | Alignment statistics to stderr |

#### Indexing Requirements

**Build Index (Required):**
```bash
bowtie2-build reference.fa index_prefix
```

Creates 6 index files:
- `.1.bt2`, `.2.bt2`, `.3.bt2`, `.4.bt2`
- `.rev.1.bt2`, `.rev.2.bt2`

For large genomes (>4GB):
```bash
bowtie2-build --large-index reference.fa index_prefix
```
Creates `.bt2l` files instead.

#### Key Constraints
- SAM output is unsorted (pipe to samtools for BAM)
- Index must be built before alignment
- Quality encoding must match input files

**Sources:**
- [Bowtie2 Manual](https://bowtie-bio.sourceforge.net/bowtie2/manual.shtml)
- [Bowtie2 HCC Documentation](https://hcc.unl.edu/docs/applications/app_specific/bioinformatics_tools/alignment_tools/bowtie2/)

---

### STAR

**Description:** Spliced Transcripts Alignment to a Reference (RNA-seq)

#### Input Formats

**Reference:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTA (.fa, .fasta) | Required | Genome sequence |
| GTF | Recommended | Gene annotations (preferred) |
| GFF3 | Supported | Requires `--sjdbGTFtagExonParentTranscript Parent` |

**Reads:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTQ (.fq, .fastq) | Required | Uncompressed |
| FASTQ.gz | Supported | Use `--readFilesCommand zcat` |
| FASTA | Supported | Without quality scores |

#### Output Formats

| File | Format | Description |
|------|--------|-------------|
| `Aligned.out.sam` | SAM | Default alignment output |
| `Aligned.out.bam` | BAM | With `--outSAMtype BAM Unsorted` |
| `Aligned.sortedByCoord.out.bam` | BAM | With `--outSAMtype BAM SortedByCoordinate` |
| `SJ.out.tab` | TSV | Splice junctions |
| `ReadsPerGene.out.tab` | TSV | Gene counts (with `--quantMode GeneCounts`) |
| `Log.final.out` | Text | Alignment statistics |

#### Indexing Requirements

**Build Genome Index (Required):**
```bash
STAR --runMode genomeGenerate \
     --genomeDir /path/to/index \
     --genomeFastaFiles reference.fa \
     --sjdbGTFfile annotations.gtf \
     --sjdbOverhang <readLength-1>
```

Index files created:
- `Genome` - Genome sequence
- `SA` - Suffix array
- `SAindex` - Index of suffix array
- `chrName.txt`, `chrLength.txt` - Chromosome info
- `sjdbList.out.tab` - Splice junction database
- Multiple other supporting files

#### Key Constraints
- RAM: ~10x genome size (~30GB for human)
- Disk: >100GB recommended
- `sjdbOverhang`: typically read length - 1
- Paired-end reads must be in identical order
- Gene counts require GTF annotations

**Sources:**
- [STAR Manual](https://physiology.med.cornell.edu/faculty/skrabanek/lab/angsd/lecture_notes/STARmanual.pdf)
- [STAR GitHub](https://github.com/alexdobin/STAR)

---

## 3. Variant Callers

### bcftools

**Description:** Utilities for variant calling and VCF/BCF manipulation

#### Input Formats

| Format | Operations | Notes |
|--------|------------|-------|
| VCF (.vcf) | All operations | Text format |
| VCF.gz | All operations | BGZF-compressed VCF |
| BCF (.bcf) | All operations | Binary VCF (recommended) |
| BCF (uncompressed) | All operations | Uncompressed binary |
| BAM | `mpileup` only | For variant calling |
| CRAM | `mpileup` only | For variant calling |

#### Output Format Options
```bash
-Ov    # Uncompressed VCF
-Oz    # Compressed VCF (bgzip)
-Ob    # Compressed BCF
-Ou    # Uncompressed BCF (fastest for piping)
```

#### Key Operations and I/O

| Command | Input | Output | Description |
|---------|-------|--------|-------------|
| `mpileup` | BAM/CRAM + Reference FASTA | VCF/BCF | Generate genotype likelihoods |
| `call` | VCF/BCF | VCF/BCF | SNP/indel calling |
| `view` | VCF/BCF | VCF/BCF | View and convert |
| `filter` | VCF/BCF | VCF/BCF | Apply filters |
| `merge` | Multiple VCF/BCF | VCF/BCF | Merge samples |
| `concat` | Multiple VCF/BCF | VCF/BCF | Concatenate regions |
| `annotate` | VCF/BCF + annotations | VCF/BCF | Add/edit annotations |
| `consensus` | VCF/BCF + Reference FASTA | FASTA | Create consensus sequence |
| `query` | VCF/BCF | Text/TSV | Extract fields |
| `stats` | VCF/BCF | Text | Statistics |

#### Indexing Requirements

**VCF/BCF Indexing:**
```bash
bcftools index file.vcf.gz      # Creates .csi index
bcftools index -t file.vcf.gz   # Creates .tbi (tabix) index
```

- Indexed files required for: merge, isec, random access
- Unindexed files work for most streaming operations

**Reference FASTA Indexing (for mpileup):**
```bash
samtools faidx reference.fa     # Creates .fai index
```

#### Key Constraints
- BCF1 format (samtools <= 0.1.19) not compatible
- Use `-Ou` for piping between bcftools commands (fastest)
- Multiple simultaneous VCFs must be indexed and compressed
- VCF <-> BCF conversion has overhead; prefer BCF throughout

**Sources:**
- [bcftools Documentation](https://samtools.github.io/bcftools/bcftools.html)
- [BCFtools HowTo](https://samtools.github.io/bcftools/howtos/index.html)

---

### GATK

**Description:** Genome Analysis Toolkit for variant discovery

#### Input Formats

**Alignment Files:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| BAM | Required | Coordinate-sorted, indexed |
| CRAM | Supported | With reference |

**Reference:**
| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| FASTA | Required | With .fai and .dict indexes |

**Annotations/Known Sites:**
| Format | Use Case | Notes |
|--------|----------|-------|
| VCF | Base recalibration | Known SNPs/indels |
| VCF | VQSR | Training resources |
| BED | Intervals | Target regions |

#### Output Formats

| Tool | Output Format | Description |
|------|---------------|-------------|
| HaplotypeCaller | VCF | Standard variants |
| HaplotypeCaller | GVCF | Genomic VCF (all sites) |
| GenotypeGVCFs | VCF | Joint-called variants |
| BaseRecalibrator | Table | Recalibration data |
| VariantFiltration | VCF | Filtered variants |

#### GVCF vs VCF

| Feature | VCF | GVCF |
|---------|-----|------|
| Variant sites | Yes | Yes |
| Reference sites | No | Yes |
| Cohort analysis | Limited | Designed for |
| File size | Smaller | Larger |
| Generation | Default | `-ERC GVCF` mode |

#### Indexing Requirements

**Reference FASTA:**
```bash
samtools faidx reference.fa           # Creates .fai
gatk CreateSequenceDictionary -R reference.fa  # Creates .dict
```

**BAM Files:**
```bash
samtools index aligned.bam            # Creates .bai
```

**VCF Files:**
```bash
gatk IndexFeatureFile -I variants.vcf.gz  # Creates .tbi
```

#### Multi-Sample Workflow

```
Per-Sample:     BAM -> HaplotypeCaller (-ERC GVCF) -> GVCF
                                                        |
Consolidation:  Multiple GVCFs -> GenomicsDBImport -> GenomicsDB
                       or      -> CombineGVCFs -> Combined GVCF
                                                        |
Joint Calling:                    -> GenotypeGVCFs -> VCF
```

#### Key Constraints
- All input files must use same chromosome naming
- BAM must be coordinate-sorted and indexed
- GVCF required for cohort analysis
- BP_RESOLUTION mode creates per-position records

**Sources:**
- [GATK VCF Documentation](https://gatk.broadinstitute.org/hc/en-us/articles/360035531692-VCF-Variant-Call-Format)
- [GATK GVCF Documentation](https://gatk.broadinstitute.org/hc/en-us/articles/360035531812-GVCF-Genomic-Variant-Call-Format)
- [HaplotypeCaller Documentation](https://gatk.broadinstitute.org/hc/en-us/articles/360037225632-HaplotypeCaller)

---

### FreeBayes

**Description:** Bayesian haplotype-based variant detector

#### Input Formats

| Format | Required/Optional | Notes |
|--------|-------------------|-------|
| BAM | Required | Aligned reads (indexed) |
| Reference FASTA | Required | With `-f` flag |
| VCF | Optional | Prior variant information (`-@`) |
| BED | Optional | CNV map for ploidy variation |

#### BAM Requirements
- Must be indexed (.bai)
- Read groups and sample names required
- Duplicates should be marked
- Sorted by coordinate

#### Output Format

| Output | Format | Description |
|--------|--------|-------------|
| Variants | VCF 4.1 | Standard output to stdout |
| gVCF | GVCF | With `--gvcf` flag |

#### Variant Types Detected
- SNPs (single-nucleotide polymorphisms)
- Indels (insertions and deletions)
- MNPs (multi-nucleotide polymorphisms)
- Complex events (composite insertion/substitution)

#### Indexing Requirements

**Reference FASTA:**
```bash
samtools faidx reference.fa     # Creates .fai
```

**BAM Files:**
```bash
samtools index aligned.bam      # Creates .bai
```

#### Basic Usage
```bash
freebayes -f reference.fa input.bam > variants.vcf
```

#### Key Parameters
- `--ploidy` - Ploidy of samples (default: 2)
- `--min-alternate-fraction` - Minimum allele frequency
- `--min-mapping-quality` - Minimum mapping quality filter
- `--min-base-quality` - Minimum base quality filter

#### Key Constraints
- Low-quality alignments and bases filtered by default
- Multiple BAM files supported (one VCF column per sample)
- Designed for small variants (< read length)

**Sources:**
- [FreeBayes GitHub](https://github.com/freebayes/freebayes)
- [FreeBayes Tutorial](https://bioinformaticsworkbook.org/dataAnalysis/VariantCalling/freebayes-dnaseq-workflow.html)

---

## 4. Utilities

### samtools

**Description:** Suite for manipulating SAM/BAM/CRAM alignments

#### Supported Formats

| Format | Extension | Description |
|--------|-----------|-------------|
| SAM | .sam | Text alignment format |
| BAM | .bam | Binary compressed SAM |
| CRAM | .cram | Reference-based compression |
| FASTA | .fa, .fasta | Sequence format |
| FASTQ | .fq, .fastq | Sequence with quality |

#### Key Operations and I/O

| Command | Input | Output | Description |
|---------|-------|--------|-------------|
| `view` | SAM/BAM/CRAM | SAM/BAM/CRAM | Convert/filter alignments |
| `sort` | SAM/BAM/CRAM | BAM/CRAM | Sort by coordinate/name |
| `index` | BAM/CRAM | .bai/.csi/.crai | Create index |
| `merge` | Multiple BAM/CRAM | BAM/CRAM | Merge sorted files |
| `fasta` | SAM/BAM/CRAM | FASTA | Extract sequences |
| `fastq` | SAM/BAM/CRAM | FASTQ | Extract reads with quality |
| `import` | FASTQ | SAM/BAM/CRAM | Convert reads to alignment format |
| `faidx` | FASTA | .fai | Index FASTA |
| `depth` | BAM/CRAM | TSV | Coverage depth |
| `flagstat` | BAM/CRAM | Text | Flag statistics |
| `stats` | BAM/CRAM | Text | Comprehensive statistics |
| `consensus` | SAM/BAM/CRAM | FASTA/FASTQ | Generate consensus |
| `mpileup` | BAM/CRAM | Pileup/VCF | Pileup format |

#### Format Conversion Examples

```bash
# SAM to BAM
samtools view -b input.sam > output.bam

# BAM to CRAM
samtools view -C -T reference.fa input.bam > output.cram

# BAM to FASTQ
samtools fastq input.bam > output.fastq

# FASTQ to BAM (unaligned)
samtools import input.fastq > output.bam

# BAM to FASTA
samtools fasta input.bam > output.fasta
```

#### Indexing Operations

| Target | Command | Index File | Notes |
|--------|---------|------------|-------|
| FASTA | `samtools faidx ref.fa` | ref.fa.fai | Required for CRAM, mpileup |
| BAM | `samtools index aln.bam` | aln.bam.bai | Default BAI format |
| BAM | `samtools index -c aln.bam` | aln.bam.csi | CSI format (large chromosomes) |
| CRAM | `samtools index aln.cram` | aln.cram.crai | CRAM index |

#### view Options

```bash
-b          # Output BAM
-C          # Output CRAM
-h          # Include header in SAM output
-H          # Print header only
-c          # Count matching records
-o FILE     # Output file name
-q INT      # Minimum mapping quality
-f FLAG     # Required flags
-F FLAG     # Excluded flags
-T ref.fa   # Reference (required for CRAM)
```

#### Key Constraints
- CRAM requires reference FASTA for decode/encode
- Indexing requires coordinate-sorted files
- BAI index limited to 512Mbp chromosomes (use CSI for larger)
- Store only sorted BAM/CRAM (smaller, faster)

**Sources:**
- [samtools Manual](http://www.htslib.org/doc/samtools.html)
- [SAMtools Wikipedia](https://en.wikipedia.org/wiki/SAMtools)

---

### bedtools

**Description:** Swiss-army knife for genome arithmetic

#### Supported Input Formats

| Format | Extension | Notes |
|--------|-----------|-------|
| BED | .bed | BED3 through BED12 |
| BED.gz | .bed.gz | Gzip-compressed BED |
| GFF/GTF | .gff, .gtf | Gene annotation formats |
| VCF | .vcf | Variant format |
| BAM | .bam | Alignment format |
| CRAM | .cram | Compressed alignment (v2.28.0+) |
| BEDPE | .bedpe | Paired-end BED |

#### Coordinate Systems

| Format | Start | End | Example |
|--------|-------|-----|---------|
| BED | 0-based | 1-based (exclusive) | chr1:0-100 = bases 1-100 |
| GFF/GTF | 1-based | 1-based (inclusive) | chr1:1-100 = bases 1-100 |
| VCF | 1-based | 1-based | Position 1 = first base |

#### Key Operations and I/O

| Command | Input A | Input B | Output | Description |
|---------|---------|---------|--------|-------------|
| `intersect` | BED/GFF/VCF/BAM | BED/GFF/VCF/BAM | BED or BAM | Find overlaps |
| `merge` | BED/GFF/VCF | - | BED | Merge overlapping intervals |
| `subtract` | BED/GFF/VCF | BED/GFF/VCF | BED | Remove overlaps |
| `coverage` | BAM or BED | BED/GFF/VCF | BED + coverage | Coverage statistics |
| `genomecov` | BAM or BED | Genome file | BedGraph | Genome-wide coverage |
| `bamtobed` | BAM | - | BED | Convert BAM to BED |
| `bedtobam` | BED | Genome file | BAM | Convert BED to BAM |
| `getfasta` | BED | FASTA | FASTA | Extract sequences |
| `maskfasta` | BED | FASTA | FASTA | Mask regions |
| `complement` | BED | Genome file | BED | Find non-covered regions |
| `slop` | BED | Genome file | BED | Expand intervals |
| `flank` | BED | Genome file | BED | Get flanking regions |
| `closest` | BED/GFF/VCF | BED/GFF/VCF | BED | Find closest features |
| `window` | BED/GFF/VCF | BED/GFF/VCF | BED | Find features in window |

#### Genome File Requirement

Many operations require a genome file (chromosome sizes):
```
chr1    248956422
chr2    242193529
chr3    198295559
...
```

Generate from FASTA:
```bash
samtools faidx reference.fa
cut -f1,2 reference.fa.fai > genome.txt
```

Or from BAM:
```bash
samtools view -H file.bam | grep @SQ | cut -f2,3 | sed 's/SN://;s/LN://' > genome.txt
```

#### intersect Options

```bash
-a <file>       # First input file
-b <file(s)>    # Second input file(s)
-wa             # Write original A entry
-wb             # Write original B entry
-wo             # Write overlap amount
-wao            # Write A and B entries + overlap (0 if none)
-u              # Write A if any overlap in B
-v              # Write A if no overlap in B
-f <float>      # Minimum overlap fraction for A
-r              # Require reciprocal overlap
-split          # Handle split/spliced alignments
-sorted         # Use memory-efficient sorted algorithm
-bed            # Output in BED format (when using BAM)
```

#### Coverage/BedGraph Output

```bash
# BedGraph output (coverage)
bedtools genomecov -bg -ibam input.bam > coverage.bedgraph

# BedGraph with zero-coverage regions
bedtools genomecov -bga -ibam input.bam > coverage.bedgraph

# Scaled coverage (e.g., RPM normalization)
bedtools genomecov -bg -scale 0.5 -ibam input.bam > scaled.bedgraph
```

#### Key Constraints
- Large file intersections: use `-sorted` with pre-sorted input
- BAM output preserves alignment info
- BED output from BAM: use `-bed` flag
- Split alignments (RNA-seq): use `-split` flag
- Gzipped files auto-detected

**Sources:**
- [bedtools Documentation](https://bedtools.readthedocs.io/)
- [bedtools intersect](https://bedtools.readthedocs.io/en/latest/content/tools/intersect.html)
- [bedtools genomecov](https://bedtools.readthedocs.io/en/latest/content/tools/genomecov.html)

---

## 5. Format Conversion Paths

### Common Workflow Conversions

```
Raw Reads (FASTQ)
    |
    v
Alignment (BWA/minimap2/Bowtie2/STAR)
    |
    v
SAM (unsorted)
    |
    v [samtools view -b]
BAM (unsorted)
    |
    v [samtools sort]
BAM (coordinate-sorted)
    |
    v [samtools index]
BAM + BAI index
    |
    +---> [samtools view -C] ---> CRAM + CRAI
    |
    +---> [bcftools mpileup | bcftools call] ---> VCF/BCF
    |
    +---> [bedtools genomecov] ---> BedGraph
    |
    +---> [bedtools bamtobed] ---> BED
```

### Recommended Conversion Commands

| From | To | Command |
|------|-----|---------|
| SAM | BAM | `samtools view -b in.sam > out.bam` |
| BAM | SAM | `samtools view -h in.bam > out.sam` |
| BAM | CRAM | `samtools view -C -T ref.fa in.bam > out.cram` |
| CRAM | BAM | `samtools view -b -T ref.fa in.cram > out.bam` |
| BAM | FASTQ | `samtools fastq in.bam > out.fastq` |
| FASTQ | BAM | `samtools import in.fastq > out.bam` |
| BAM | BED | `bedtools bamtobed -i in.bam > out.bed` |
| VCF | BCF | `bcftools view -Ob in.vcf > out.bcf` |
| BCF | VCF | `bcftools view -Ov in.bcf > out.vcf` |

### Pipeline Best Practices

```bash
# Full alignment pipeline with proper indexing
bwa mem -t 8 reference.fa reads_1.fq reads_2.fq | \
    samtools view -b | \
    samtools sort -o aligned.sorted.bam
samtools index aligned.sorted.bam

# Variant calling pipeline
bcftools mpileup -Ou -f reference.fa aligned.sorted.bam | \
    bcftools call -mv -Oz -o variants.vcf.gz
bcftools index variants.vcf.gz
```

---

## 6. Index File Requirements

### Summary Table

| Primary File | Index File | Generator | Purpose |
|--------------|------------|-----------|---------|
| reference.fa | reference.fa.fai | `samtools faidx` | Random access, CRAM support |
| reference.fa | reference.dict | `gatk CreateSequenceDictionary` | GATK operations |
| aligned.bam | aligned.bam.bai | `samtools index` | Random access (<512Mb chr) |
| aligned.bam | aligned.bam.csi | `samtools index -c` | Random access (large chr) |
| aligned.cram | aligned.cram.crai | `samtools index` | Random access |
| variants.vcf.gz | variants.vcf.gz.tbi | `tabix` or `bcftools index -t` | Random access (tabix) |
| variants.vcf.gz | variants.vcf.gz.csi | `bcftools index` | Random access (CSI) |
| variants.bcf | variants.bcf.csi | `bcftools index` | Random access |
| reference.fa | reference.*.bt2 | `bowtie2-build` | Bowtie2 alignment |
| reference.fa | reference.*.bwt etc. | `bwa index` | BWA alignment |
| reference.fa | reference.mmi | `minimap2 -d` | minimap2 alignment |
| reference.fa | Genome, SA, etc. | `STAR --runMode genomeGenerate` | STAR alignment |

### Index Co-location Requirements

| Tool | Index Location Rule |
|------|---------------------|
| samtools | Same directory, same basename as primary file |
| BWA | Same directory as reference FASTA |
| Bowtie2 | Specified by index prefix |
| STAR | Dedicated genome directory |
| minimap2 | Any location (specified on command line) |
| bcftools | Same directory, same basename as VCF/BCF |
| GATK | Same directory as primary file |

---

## 7. Format Summary Table

### Quick Reference: File Formats by Tool

| Tool | Primary Input | Secondary Input | Primary Output | Index Required |
|------|---------------|-----------------|----------------|----------------|
| **Assemblers** |
| SPAdes | FASTQ/FASTA/BAM | - | FASTA, GFA, FASTG | None |
| MEGAHIT | FASTQ/FASTA | - | FASTA | None |
| Trinity | FASTQ/FASTA | Long reads (FASTA) | FASTA, GFF | None |
| Flye | FASTA/FASTQ | - | FASTA, GFA | None |
| **Aligners** |
| BWA | FASTQ/FASTA/BAM | Reference FASTA | SAM | BWA index |
| minimap2 | FASTQ/FASTA | Reference FASTA/MMI | PAF/SAM | Optional MMI |
| Bowtie2 | FASTQ/FASTA/BAM | Reference index | SAM | Bowtie2 index |
| STAR | FASTQ/FASTA | Reference + GTF | SAM/BAM, TSV | STAR index |
| **Variant Callers** |
| bcftools | VCF/BCF or BAM | Reference FASTA | VCF/BCF | FAI for mpileup |
| GATK | BAM | Reference FASTA + VCF | VCF/GVCF | FAI, DICT, BAI |
| FreeBayes | BAM | Reference FASTA | VCF | FAI, BAI |
| **Utilities** |
| samtools | SAM/BAM/CRAM/FASTQ | Reference FASTA | SAM/BAM/CRAM/FASTA/FASTQ | Various |
| bedtools | BED/GFF/VCF/BAM | BED/GFF/VCF/BAM | BED/BAM/BedGraph | Genome file |

### Format Extensions Reference

| Format | Extensions | Binary | Compressed | Description |
|--------|------------|--------|------------|-------------|
| FASTA | .fa, .fasta, .fna | No | .gz | Sequences |
| FASTQ | .fq, .fastq | No | .gz | Sequences + quality |
| SAM | .sam | No | No | Text alignments |
| BAM | .bam | Yes | Yes (built-in) | Binary alignments |
| CRAM | .cram | Yes | Yes (ref-based) | Compact alignments |
| VCF | .vcf | No | .gz (bgzip) | Variants |
| BCF | .bcf | Yes | Optional | Binary variants |
| BED | .bed | No | .gz | Genomic intervals |
| GFF/GTF | .gff, .gff3, .gtf | No | .gz | Gene annotations |
| GFA | .gfa | No | No | Assembly graphs |
| PAF | .paf | No | No | Pairwise alignments |
| BedGraph | .bedgraph, .bg | No | .gz | Coverage data |

---

## Lungfish Implementation Considerations

### Format Detection Priority

1. **File extension** - Primary indicator
2. **Magic bytes** - For binary formats (BAM: `BAM\1`, BCF: `BCF\2`)
3. **Header inspection** - For text formats (SAM: `@HD`, VCF: `##fileformat`)
4. **Gzip detection** - Magic bytes `1f 8b`

### Recommended Import Support

**High Priority (Core Formats):**
- FASTA/FASTQ (sequences)
- SAM/BAM/CRAM (alignments)
- VCF/BCF (variants)
- BED (intervals)
- GFF/GTF (annotations)

**Medium Priority (Specialized):**
- GFA (assembly graphs)
- PAF (long-read alignments)
- BedGraph (coverage)

**Index File Handling:**
- Auto-detect index files in same directory
- Prompt to create missing indexes when needed
- Support both BAI and CSI index formats

### Export Considerations

- Default to compressed formats (BAM, BCF, gzipped text)
- Include index generation option
- Validate format compatibility before export
