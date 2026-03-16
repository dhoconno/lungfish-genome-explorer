# Bioinformatics Tools Analysis for Lungfish FASTQ Operations

Expert analysis of the Lungfish virtual FASTQ derivative system, covering
operation feasibility, tool chain constraints, reference requirements,
default parameters, batch processing strategy, output formats, validation,
and performance characteristics.

Date: 2026-03-14

---

## 1. Virtual (Pointer-Based) vs Materialized Operations

The existing codebase defines three virtual payload types (`subset`,
`trim`, `orientMap`) and three materialized types (`full`, `fullPaired`,
`fullMixed`). This is a sound classification. Below is a detailed
breakdown of every current and planned operation.

### 1.1 Operations That Can Be Virtual

These operations produce metadata that references the original reads
without copying sequence data. Materialization is deferred until the user
explicitly requests it or a downstream tool requires an actual FASTQ.

| Operation | Virtual Payload Type | What Gets Stored | Notes |
|---|---|---|---|
| Subsampling (proportion/count) | `subset` | Read ID list | Reservoir sampling on IDs only |
| Length filtering | `subset` | Read ID list | Single-pass length scan, store passing IDs |
| Text search (header) | `subset` | Read ID list | Grep-like on header lines |
| Motif search (sequence) | `subset` | Read ID list | Pattern match on sequence lines |
| Deduplication | `subset` | Read ID list | Hash sequences or IDs, store unique set |
| Quality trimming | `trim` | Per-read trim coordinates TSV | `read_id\t5prime_trim\t3prime_trim` |
| Adapter trimming | `trim` | Per-read trim coordinates TSV | Same format; fastp/bbduk report trim positions |
| Fixed trimming | `trim` | Per-read trim coordinates TSV | Trivial: same offset for all reads |
| Primer removal | `trim` | Per-read trim coordinates TSV | cutadapt `--info-file` provides exact positions |
| Orientation | `orientMap` | Read ID to strand TSV + preview | vsearch `--orient` output parsed to +/- map |
| Demultiplexing | `demuxedVirtual` | Read ID list per barcode + preview | cutadapt demux assigns reads to barcodes |

**Key constraint for virtual trim operations**: When trim and subset
operations are chained, the trim coordinates must be composable. The
current system handles this correctly -- a trim derivative references its
parent, and materialization walks the chain. However, there is a
correctness subtlety: if a quality trim is followed by a length filter,
the length filter must evaluate against the *trimmed* length (original
length minus trim offsets), not the raw length. This means the length
filter step must read both the parent trim TSV and the original FASTQ to
compute effective lengths. This is still virtual (no FASTQ copy) but
requires joining two data sources during the subset computation.

### 1.2 Operations That MUST Produce Materialized Files

These operations transform read content in ways that cannot be
represented as pointers or coordinates back to the original file.

| Operation | Why It Cannot Be Virtual | Output Type |
|---|---|---|
| Paired-end merging | Creates new composite reads from overlapping pairs; the merged sequence does not exist in the original file | `full` or `fullMixed` (merged + unmerged) |
| Paired-end repair | Reorders and re-pairs reads; output ordering differs from input | `fullPaired` |
| Error correction | Modifies base calls using k-mer frequency or overlap evidence; every base potentially changes | `full` |
| Interleave/deinterleave | Restructures file layout (1 file to 2 or vice versa) | `full` or `fullPaired` |
| Contaminant filtering | Technically could be virtual (subset of non-matching reads), BUT bbduk's k-mer matching is fast enough that the overhead of a two-pass approach (first identify, then subset) exceeds just writing the filtered output directly. Recommend materialized for simplicity. | `full` |
| Read mapping (future) | Produces BAM/SAM, a fundamentally different format | BAM |
| Assembly (future) | Produces contigs, a fundamentally different data type | FASTA |
| Variant calling (future) | Produces VCF from BAM input | VCF |

**Contaminant filtering special case**: While conceptually a subset
operation (keep reads that do NOT match the reference), the performance
argument for materialization is strong. bbduk streams input and writes
output in a single pass. A virtual approach would require: (1) run bbduk
to identify contaminant read IDs, (2) store the ID list, (3) later
re-read the original FASTQ to extract non-matching reads. Since bbduk
already writes the clean output as part of step 1, storing just the IDs
adds latency with no benefit. However, if disk space is the primary
concern and the source FASTQ is very large (>50 GB), a virtual subset
approach becomes attractive. Recommend offering both modes: default
materialized, with a "virtual mode" toggle for large datasets.

### 1.3 Composability of Virtual Operations

Virtual operations can be chained without materializing intermediate
files, but the chain must be evaluated carefully:

```
Subset + Subset = intersection of read ID sets (fast set operation)
Trim + Trim = sum of trim offsets per read (coordinate arithmetic)
Subset + Trim = apply trim only to reads in subset (join on read ID)
Trim + Subset = filter trimmed reads by criterion (must evaluate against trimmed coordinates)
Orient + Trim = trim coordinates must be relative to oriented strand (the current codebase handles this)
Orient + Subset = subset evaluated against oriented sequences
```

**Materialization trigger**: Any operation that transforms content (merge,
repair, error correction) forces materialization of all upstream virtual
operations first. The recipe executor should detect this and insert an
implicit materialization step.

---

## 2. Tool Chain Ordering Constraints

### 2.1 Mandatory Ordering Rules

These constraints are biologically and technically non-negotiable:

1. **Primer removal BEFORE quality trimming**. Primers are synthetic
   sequences with known positions. Quality trimming first may partially
   remove primer bases, leaving fragments that the primer removal tool
   cannot recognize. This leads to primer remnants in the final data.

2. **Primer removal BEFORE adapter trimming**. Same rationale. Primer
   sequences are internal to the read (between the adapter and the insert).
   Adapter trimming first is acceptable only if primers are immediately
   adjacent to adapters and the adapter trimmer is configured to trim
   through them, which is fragile.

3. **Adapter trimming BEFORE paired-end merging**. Residual adapter
   sequence at read 3' ends will prevent correct overlap detection.
   bbmerge can handle some adapter contamination, but explicit adapter
   removal first is more reliable.

4. **Quality trimming BEFORE paired-end merging**. Low-quality tails
   reduce merge accuracy. Trimming them first improves overlap alignment.

5. **Paired-end repair BEFORE any paired-end operation**. If reads are
   out of order or have missing mates, merge/interleave will produce
   incorrect pairs. Repair must come first.

6. **Demultiplexing BEFORE per-barcode processing**. By definition,
   demux splits a pool into subsets. All downstream per-sample operations
   depend on this split.

7. **Orientation BEFORE assembly or mapping**. Reads in mixed
   orientations will confuse assemblers (especially overlap-based ones
   like megahit) and reduce mapping rates for strand-specific protocols.

8. **All preprocessing BEFORE mapping**. Mapping should receive the
   cleanest possible reads. The only exception is if you intentionally
   want to map raw reads for QC purposes (e.g., to estimate contamination
   before filtering).

9. **Mapping BEFORE variant calling**. Variant callers require aligned
   reads in BAM format. There is no shortcut.

10. **Contaminant filtering BEFORE assembly**. Contaminant reads will
    produce chimeric or off-target contigs.

### 2.2 Recommended Canonical Order

```
1. Paired-end repair (if needed)
2. Demultiplexing
3. Primer removal
4. Quality trimming
5. Adapter trimming
6. Fixed trimming (if needed)
7. Contaminant filtering
8. Length filtering
9. Deduplication
10. Orientation
11. Error correction
12. Paired-end merging
13. Subsampling (if needed for downstream resource constraints)
--- content-transforming boundary ---
14. Mapping
15. Assembly
16. Variant calling
```

### 2.3 Flexible Ordering (User Discretion)

Some orderings are context-dependent:

- **Deduplication timing**: Before merging (removes duplicate read pairs)
  vs. after merging (removes duplicate merged reads). Before is more
  conservative; after catches duplicates that differ only in overlap
  quality.

- **Error correction timing**: Before merging improves overlap detection.
  After merging is pointless (merged reads already have consensus quality).
  Before adapter trimming can help the trimmer identify adapters in
  low-quality reads, but this is marginal.

- **Length filtering timing**: After trimming (to remove reads shortened
  below a useful threshold) is standard. Before trimming is unusual but
  valid for removing known-bad very short or very long reads from ONT data.

- **Orientation timing**: Before primer removal if primers are defined
  relative to a canonical strand. After demux if barcodes are
  orientation-independent. The current codebase correctly handles orient
  + demux interaction with the orientMap propagation.

### 2.4 Ordering Validation Rules for the UI

The recipe builder should enforce these rules and warn on violations:

```
ERROR conditions (block recipe save):
- pairedEndMerge before adapterTrim
- variantCalling without mapping upstream
- mapping without any preprocessing

WARNING conditions (allow but flag):
- qualityTrim before primerRemoval
- adapterTrim before primerRemoval
- deduplication after pairedEndMerge (valid but unusual)
- contaminantFilter after mapping (wasteful)
- no qualityTrim in pipeline (almost always a mistake)
- no adapterTrim in pipeline with Illumina data
```

---

## 3. Reference Sequence Requirements

### 3.1 Per-Operation Reference Needs

| Operation | Reference Required | Reference Type | Discovery Strategy |
|---|---|---|---|
| Primer removal | Yes (unless literal sequences provided) | FASTA of primer sequences | Project References folder, or literal entry in UI |
| Contaminant filter (PhiX) | Yes, bundled | PhiX genome (ships with bbtools) | Automatic; bbduk knows the path |
| Contaminant filter (custom) | Yes, user-supplied | FASTA of contaminant genome(s) | Project References folder |
| Orientation | Yes | Reference FASTA of target organism | Project References folder |
| Mapping (future) | Yes | Reference genome FASTA + index | Project References folder; auto-index if missing |
| Assembly (future) | No (de novo) or Yes (reference-guided) | Reference genome for scaffolding | Optional; Project References folder |
| Variant calling (future) | Yes | Same reference used for mapping | Inherited from mapping step |
| Quality trimming | No | -- | -- |
| Adapter trimming | No (auto-detect) or Yes (FASTA of adapters) | Adapter FASTA | Bundled adapter sets (TruSeq, Nextera, etc.) |
| Demultiplexing | No (barcode kit definitions are metadata) | -- | Kit definitions bundled in app |
| All other operations | No | -- | -- |

### 3.2 Reference Discovery from Project "References" Folder

Recommended structure:

```
MyProject/
  References/
    genome.fasta            # Primary reference genome
    genome.fasta.fai        # samtools faidx index
    genome.fasta.bwt        # BWA index files
    genome.fasta.mmi        # minimap2 index
    primers.fasta           # Primer sequences
    adapters.fasta          # Custom adapter sequences
    contaminants/
      phix.fasta            # PhiX (could also use bbtools bundled)
      human_host.fasta      # Host depletion reference
      rrna.fasta            # rRNA for depletion
```

**Auto-discovery logic**: When an operation requires a reference, the UI
should scan the References folder and present matching files filtered by
likely purpose:

- Files named `*primer*` or `*oligo*` for primer removal
- Files named `*adapt*` for adapter trimming
- Files named `*contam*`, `*host*`, `*phix*`, `*rrna*` for contaminant filtering
- The largest FASTA file (or one named `*genome*`, `*reference*`) for
  mapping and orientation

**Index management**: For mapping operations, the app should check for
the presence of required index files and offer to build them:
- minimap2: `.mmi` index (fast to build, ~3 min for human genome)
- BWA: `.bwt`, `.pac`, `.ann`, `.amb`, `.sa` files (~1 hour for human)
- samtools: `.fai` index (seconds)

Store a `references.json` manifest in the References folder to cache
file roles and avoid re-scanning.

### 3.3 Reference Validation

Before starting an operation that requires a reference:

1. Verify the file exists and is readable
2. Verify it parses as valid FASTA (check first record)
3. For primer FASTA: verify sequences are short (<200 bp) and contain
   only IUPAC nucleotide characters
4. For genome references: verify sequence names match expected chromosome
   naming conventions if relevant
5. For contaminant references: warn if the file is very large (>1 GB),
   as k-mer indexing will be memory-intensive

---

## 4. Recommended Default Parameters

### 4.1 Illumina Amplicon Sequencing

Target: 16S/ITS, viral amplicons, targeted panels.
Typical read length: 2x150 or 2x250.

```
Pipeline: Primer Removal -> Quality Trim -> Adapter Trim -> Length Filter -> PE Merge

Primer Removal (cutadapt):
  mode: paired (linked for 16S with conserved primer sites)
  errorRate: 0.12 (allows ~3 mismatches in a 25-mer)
  minimumOverlap: 17 (for typical 20-25 bp primers)
  anchored5Prime: true (primers at read starts)
  anchored3Prime: true (for linked mode)
  keepUntrimmed: false (discard reads without primers = off-target)
  allowIndels: true
  pairFilter: any (keep pair if either read has primer)

Quality Trim (fastp):
  threshold: 20 (Q20, 1% error rate)
  windowSize: 4
  mode: cutRight (3' end trimming, where quality degrades)

Adapter Trim (fastp):
  mode: autoDetect (fastp overlap-based detection works well for PE)

Length Filter:
  minLength: 100 (after trimming, shorter reads are likely artifacts)
  maxLength: null (no upper bound for short amplicons)
  NOTE: For ITS, set maxLength to expected amplicon + 20%

PE Merge (bbmerge):
  strictness: strict (amplicons should merge cleanly)
  minOverlap: 20 (conservative; most amplicons have >50 bp overlap with 2x250)
```

### 4.2 Illumina Whole Genome Sequencing (WGS)

Target: Bacterial, viral, or eukaryotic whole genomes.
Typical read length: 2x150.

```
Pipeline: Quality Trim -> Adapter Trim -> Contaminant Filter -> Dedup -> PE Merge (optional)

Quality Trim (fastp):
  threshold: 20
  windowSize: 4
  mode: cutRight

Adapter Trim (fastp):
  mode: autoDetect

Contaminant Filter (bbduk):
  mode: phix (standard Illumina spike-in)
  kmerSize: 31
  hammingDistance: 1

Deduplication:
  mode: sequence (optical/PCR duplicates have identical sequences)
  pairedAware: true

PE Merge (bbmerge):
  strictness: normal
  minOverlap: 12
  NOTE: Only merge if downstream analysis benefits (e.g., variant calling
  with merged reads for short inserts). For standard WGS with insert
  sizes > 300 bp, merging is counterproductive -- most reads will not
  overlap.
```

### 4.3 Nanopore/PacBio Long-Read Sequencing

Target: Bacterial genomes, structural variants, full-length transcripts.

```
Pipeline: Quality Filter -> Length Filter -> Orientation (if needed) -> Dedup

Quality Trim (ONT/PacBio-aware):
  threshold: 10 (ONT Q10 = 10% error; Q20 for HiFi)
  windowSize: 10 (wider window for noisy long reads)
  mode: cutBoth (ONT reads degrade at both ends)

Length Filter:
  For amplicons:
    minLength: expected_amplicon * 0.8
    maxLength: expected_amplicon * 1.2
  For WGS:
    minLength: 1000 (short fragments are often chimeric)
    maxLength: null
  For HiFi:
    minLength: 500
    maxLength: null

Deduplication:
  mode: sequence
  NOTE: ONT has lower duplicate rates than Illumina. For HiFi, dedup
  by sequence hash is appropriate. For ONT, dedup is rarely needed
  unless PCR amplification was used.

Orientation (vsearch):
  wordLength: 12 (default; shorter for divergent references)
  dbMask: dust
  NOTE: Critical for amplicon sequencing where reads may be in either
  orientation. Less important for WGS.
```

### 4.4 Metagenomic Sequencing

Target: Environmental or clinical microbiome samples.

```
Pipeline: Quality Trim -> Adapter Trim -> Host Depletion -> Length Filter -> Dedup

Quality Trim (fastp):
  threshold: 20
  windowSize: 4
  mode: cutRight

Adapter Trim (fastp):
  mode: autoDetect

Host Depletion (bbduk contaminant filter):
  mode: custom
  referenceFasta: human_host.fasta (or relevant host genome)
  kmerSize: 31
  hammingDistance: 1
  NOTE: For human microbiome, use the masked human reference (hs38DH)
  to avoid removing microbial reads that align to low-complexity human
  regions. Consider minimap2 mapping + unmapped read extraction for
  higher sensitivity host removal.

Length Filter:
  minLength: 50 (short reads after aggressive trimming are uninformative)
  maxLength: null

Deduplication:
  mode: sequence
  pairedAware: true
  NOTE: Metagenomic samples often have genuine biological duplicates
  (abundant organisms). Consider skipping dedup or using UMI-aware
  dedup if available.

Additional considerations:
  - rRNA depletion reference if doing metatranscriptomics
  - PhiX filtering is always appropriate (Illumina spike-in)
  - Consider running two contaminant filters in sequence: PhiX then host
```

---

## 5. Batch Processing vs Sequential Execution

### 5.1 Operations That Benefit from Batch Processing

Batch processing means applying the same operation to multiple files
(typically demultiplexed barcodes) with bounded concurrency. The current
`BatchProcessingEngine` handles this correctly with configurable
`maxConcurrency`.

**High batch benefit** (independent per-file, CPU-bound):
- Quality trimming: Each file processes independently. 4-8 concurrent
  fastp instances saturate a modern CPU.
- Adapter trimming: Same as quality trimming.
- Length filtering: Trivial per-read check. I/O-bound; batch helps by
  overlapping reads with writes.
- Deduplication: Independent per file. Memory-bound for sequence hashing.
- Fixed trimming: Trivial computation.
- Subsampling: Independent, fast.

**Moderate batch benefit** (independent but resource-constrained):
- Contaminant filtering: bbduk loads the reference k-mer index into
  memory once per instance. Running N concurrent bbduk instances
  multiplies memory usage by N. For a human host reference (~3 GB index),
  limit concurrency to 2-3 on a 32 GB machine.
- Primer removal: cutadapt is single-threaded by default. Running
  multiple instances in parallel is the correct way to utilize multiple
  cores.
- Error correction: Memory-intensive k-mer counting. Limit concurrency.
- PE merge: bbmerge is moderately memory-hungry. 4 concurrent is safe.

**Low batch benefit** (must be sequential or has shared resources):
- Demultiplexing: Operates on the multiplexed pool; there is nothing to
  parallelize at the file level. Internal parallelism is tool-dependent.
- Mapping (future): Each BAM is independent, but minimap2/bwa already
  use multiple threads internally. Running 2-3 concurrent mapping jobs
  with 4 threads each is better than 8 single-threaded jobs.
- Assembly (future): Extremely memory-intensive. Run ONE assembly at a
  time. megahit uses ~1 GB per million reads; SPAdes uses ~10x more.

### 5.2 Concurrency Recommendations

| Operation | Max Concurrency | Bottleneck | Memory per Instance |
|---|---|---|---|
| Quality trim (fastp) | 8 | CPU | ~200 MB |
| Adapter trim (fastp) | 8 | CPU | ~200 MB |
| Primer removal (cutadapt) | 8 | CPU (single-threaded) | ~100 MB |
| Length filter | 8 | I/O | ~50 MB |
| Deduplication | 4 | Memory | ~500 MB - 2 GB (depends on read count) |
| Contaminant filter | 2-3 | Memory | ~1-4 GB (depends on reference size) |
| PE merge (bbmerge) | 4 | CPU + Memory | ~500 MB |
| Error correction | 2 | Memory | ~2-8 GB |
| Orientation (vsearch) | 4 | CPU | ~200 MB |
| Mapping (minimap2) | 2-3 | CPU + I/O | ~4-8 GB (genome-dependent) |
| Assembly | 1 | Memory | 4-64 GB |
| Variant calling | 2-3 | CPU | ~2 GB |

### 5.3 Batch Processing Architecture Recommendations

The current `BatchProcessingEngine` processes barcodes with bounded
concurrency, executing recipe steps sequentially per barcode. This is
correct. Two enhancements to consider:

1. **Step-level concurrency control**: Different steps in a recipe may
   have different safe concurrency levels. The engine should allow
   per-step concurrency overrides rather than a single global
   `maxConcurrency`. For example, quality trimming at 8x concurrency
   followed by contaminant filtering at 2x.

2. **Shared resource deduplication**: When multiple barcodes need the
   same contaminant reference, bbduk loads it independently in each
   instance. There is no practical way to share this across processes, but
   the engine should at least stagger launches to avoid simultaneous
   index-building spikes.

---

## 6. Output Format Expectations

### 6.1 Current Operations (FASTQ Domain)

All current operations produce FASTQ output (or virtual references to
FASTQ). The bundle system (`.lungfishfastq`) wraps the FASTQ with
metadata, statistics, and provenance.

### 6.2 Future Operations

| Operation | Primary Output | Secondary Outputs | Format Details |
|---|---|---|---|
| Read mapping | BAM | BAM index (.bai), mapping stats | Sorted by coordinate; `samtools sort` + `samtools index` |
| Assembly | FASTA (contigs) | Assembly graph (GFA), stats | Headers contain contig names, coverage, length |
| Variant calling | VCF | VCF index (.tbi), stats | bgzipped VCF + tabix index is the standard |
| Consensus calling | FASTA | Quality mask BED | Single sequence per reference contig |

### 6.3 Bundle Extensions for Future Formats

The `.lungfishfastq` bundle concept should extend to:

- `.lungfishbam` -- BAM + BAI + mapping QC metrics JSON
- `.lungfishasm` -- Contigs FASTA + assembly metrics JSON (N50, L50, total length, contig count)
- `.lungfishvcf` -- VCF.gz + TBI + variant summary JSON

Each bundle should contain:
- The primary data file
- Index files
- A `metadata.json` with provenance (which FASTQ input, which reference, which tool + version, parameters)
- A `statistics.json` with format-appropriate QC metrics

### 6.4 Mapping Output Details

minimap2 output requires post-processing:

```
minimap2 -a -x sr reference.mmi reads.fastq | samtools sort -o output.bam
samtools index output.bam
samtools flagstat output.bam > stats.txt
samtools idxstats output.bam > idxstats.txt
```

For paired-end:
```
minimap2 -a -x sr reference.mmi reads_R1.fastq reads_R2.fastq | samtools sort -o output.bam
```

BWA requires a pre-built index:
```
bwa index reference.fasta  # one-time
bwa mem -t 4 reference.fasta reads_R1.fastq reads_R2.fastq | samtools sort -o output.bam
```

### 6.5 Assembly Output Details

```
megahit -1 reads_R1.fastq -2 reads_R2.fastq -o assembly_output --min-contig-len 500
# Output: assembly_output/final.contigs.fa

spades.py -1 reads_R1.fastq -2 reads_R2.fastq -o assembly_output
# Output: assembly_output/contigs.fasta, assembly_output/scaffolds.fasta

flye --nano-raw reads.fastq --out-dir assembly_output --genome-size 5m
# Output: assembly_output/assembly.fasta
```

### 6.6 Variant Calling Output Details

```
# From BAM:
bcftools mpileup -f reference.fasta input.bam | bcftools call -mv -Oz -o variants.vcf.gz
tabix -p vcf variants.vcf.gz

# For amplicon/viral:
lofreq call -f reference.fasta -o variants.vcf input.bam  # sensitive to low-frequency variants
```

---

## 7. Output Validation

### 7.1 Read Count Validation

Every operation should track input and output read counts. The ratio
provides a sanity check:

| Operation | Expected Retention | Alarm Threshold |
|---|---|---|
| Quality trimming | 85-99% | <70% suggests quality issues or overly aggressive threshold |
| Adapter trimming | 95-100% (reads shortened, rarely removed) | <90% suggests contamination or wrong adapter set |
| Primer removal | 70-99% (depends on keepUntrimmed) | <50% suggests wrong primers or primer degradation |
| Contaminant filter (PhiX) | 99%+ | <95% suggests heavy PhiX spike or wrong reference |
| Contaminant filter (host) | Varies widely | <10% for heavily host-contaminated samples is normal |
| Length filter | 90-99% | <80% suggests upstream trimming was too aggressive |
| Deduplication | 70-95% | <50% suggests low library complexity (over-amplification) |
| PE merge | 60-95% for amplicons, 10-50% for WGS | <30% for amplicons suggests wrong insert size |
| Demultiplexing | 70-95% assigned | <50% assigned suggests wrong barcode kit |
| Orientation | 95-100% oriented | <80% suggests divergent reference |
| Error correction | 100% (same read count) | Any loss indicates a tool error |

### 7.2 Quality Metrics to Track Per Step

```json
{
  "readCount": 1250000,
  "baseCount": 312500000,
  "meanReadLength": 250.0,
  "medianReadLength": 251,
  "n50ReadLength": 251,
  "meanQuality": 32.5,
  "q20Percentage": 95.2,
  "q30Percentage": 88.7,
  "gcContent": 0.48,
  "adapterContent": 0.02,
  "duplicateRate": 0.15,
  "retentionFromPrevious": 0.92,
  "retentionFromRaw": 0.85
}
```

The current `StepMetrics` and `FASTQDatasetStatistics` types cover most
of these. Add `adapterContent` and `duplicateRate` if not already present.

### 7.3 Mapping-Specific Validation

| Metric | Good | Concerning | Bad |
|---|---|---|---|
| Mapped reads % | >90% (WGS), >95% (amplicon) | 70-90% | <70% |
| Properly paired % | >85% | 70-85% | <70% |
| Mean coverage | Depends on design | -- | <10x for variant calling |
| Coverage uniformity (CoV) | <0.3 | 0.3-0.5 | >0.5 |
| Duplicate rate (post-mapping) | <20% (WGS) | 20-40% | >40% |
| Insert size (mean) | Near expected | >20% deviation | >50% deviation |

### 7.4 Assembly-Specific Validation

| Metric | Description | How to Compute |
|---|---|---|
| Total assembly length | Sum of all contig lengths | `awk '/^>/{next}{total+=length}END{print total}'` |
| Number of contigs | Count of sequences | `grep -c '^>'` |
| N50 | Contig length where 50% of assembly is in contigs >= this length | Sort contigs by length, cumulative sum |
| L50 | Number of contigs comprising N50 | Count of contigs in N50 set |
| Largest contig | Maximum contig length | Parse FASTA |
| GC content | Should match expected for organism | Calculate from sequence |
| Expected genome coverage | Total bases in reads / assembly length | Sanity check |

### 7.5 Variant Calling Validation

| Metric | What to Check |
|---|---|
| Total variants | Order of magnitude appropriate for organism (e.g., ~4M SNPs for human WGS) |
| Ti/Tv ratio | ~2.0-2.1 for human WGS; deviation suggests artifacts |
| Het/Hom ratio | ~1.5 for human; varies by organism |
| Variants per Mb | Consistent across chromosomes (excluding known hypervariable regions) |
| QUAL distribution | Most variants should have QUAL > 20 |

---

## 8. Performance Considerations

### 8.1 I/O-Bound Operations

These operations spend most of their time reading and writing FASTQ data.
CPU utilization is low. Performance scales with disk speed (SSD vs HDD)
and file size.

- **Subsampling**: Read headers, decide inclusion, optionally write.
  Pure I/O.
- **Length filtering**: Read each record, check length, write or skip.
  Pure I/O.
- **Text/motif search**: Read headers or sequences, pattern match
  (fast), write matches. I/O-dominant.
- **Fixed trimming**: Trivial per-read computation. I/O-dominant.
- **Interleave/deinterleave**: File restructuring. Pure I/O.

**Optimization**: For I/O-bound operations, the virtual approach
(storing only read IDs or trim coordinates) provides massive speedup
because it avoids writing the output FASTQ entirely. A 10 GB FASTQ
produces a ~50 MB read ID list -- 200x smaller I/O.

### 8.2 CPU-Bound Operations

These operations perform significant computation per read.

- **Quality trimming**: Sliding window quality calculation. Moderate CPU.
  fastp is highly optimized with SIMD; bbduk is Java-based and slower
  per thread but multi-threaded.
- **Adapter trimming**: Smith-Waterman or overlap-based alignment per
  read. fastp's overlap detection is fast; bbduk's k-mer approach is
  also fast. CPU-moderate.
- **Deduplication**: Hashing sequences. CPU + memory. For large datasets,
  the hash table becomes the bottleneck (memory).
- **Error correction**: K-mer counting across the entire dataset, then
  per-read correction. CPU + memory intensive. bbmerge ecco uses overlap
  information and is faster than k-mer-based methods like BayesHammer.
- **Primer removal**: cutadapt performs semi-global alignment per read.
  Single-threaded by default. CPU-bound. Running multiple cutadapt
  instances is the correct parallelization strategy.
- **PE merge**: Overlap alignment per read pair. CPU-moderate.

### 8.3 Memory-Bound Operations

- **Contaminant filtering**: bbduk loads the reference into a k-mer hash
  table. Human genome reference: ~4 GB RAM. PhiX: negligible.
- **Deduplication**: Hash table of all unique sequences. For 100M reads
  of 150 bp: ~15 GB if storing full sequences, ~2 GB if using 64-bit
  hashes.
- **Assembly**: SPAdes: ~1 GB per million reads (practical minimum 16 GB).
  megahit: ~0.5 GB per million reads. Flye (long-read): ~10-30 GB for
  bacterial genomes, >100 GB for eukaryotic.
- **Mapping**: minimap2: ~6 GB for human genome index. BWA: ~5 GB.
  Per-read memory is minimal.

### 8.4 Performance Summary Table

| Operation | CPU | Memory | I/O | Typical Speed (1M PE150 reads) |
|---|---|---|---|---|
| Quality trim (fastp) | Medium | Low | Medium | ~30 seconds |
| Adapter trim (fastp) | Medium | Low | Medium | ~30 seconds |
| Primer removal (cutadapt) | Medium | Low | Low | ~60 seconds (single-threaded) |
| Contaminant filter (bbduk, PhiX) | Low | Low | Medium | ~20 seconds |
| Contaminant filter (bbduk, human) | Medium | High | Medium | ~90 seconds |
| Length filter | Low | Low | High | ~10 seconds |
| Deduplication | Medium | High | Medium | ~45 seconds |
| PE merge (bbmerge) | Medium | Medium | Medium | ~30 seconds |
| Error correction (ecco) | High | Medium | Medium | ~60 seconds |
| Orientation (vsearch) | Medium | Medium | Medium | ~30 seconds |
| Mapping (minimap2, bacterial) | High | Medium | High | ~60 seconds |
| Mapping (minimap2, human) | High | High | High | ~5 minutes |
| Assembly (megahit, bacterial) | High | High | Medium | ~5-15 minutes |
| Variant calling (bcftools) | Medium | Low | Medium | ~2 minutes |

### 8.5 Virtual Operation Performance Advantages

For a 10 GB FASTQ file with 30 million reads:

| Approach | Disk I/O | Time | Disk Space |
|---|---|---|---|
| Materialized quality trim | Read 10 GB + Write ~9.5 GB | ~3 min | +9.5 GB |
| Virtual quality trim (trim TSV) | Read 10 GB + Write ~300 MB | ~2 min | +300 MB |
| Materialized subset (length filter) | Read 10 GB + Write ~9 GB | ~2.5 min | +9 GB |
| Virtual subset (read ID list) | Read 10 GB + Write ~50 MB | ~1.5 min | +50 MB |
| Chain of 3 virtual operations | Read 10 GB once + Write ~400 MB total | ~3 min | +400 MB |
| Chain of 3 materialized operations | Read + Write 3 times (~57 GB I/O) | ~10 min | +28 GB |

The virtual approach is approximately 3x faster and uses 70x less disk
space for a typical 3-step preprocessing pipeline. The cost is paid at
materialization time, but materialization only happens once (when the
user exports or when a content-transforming operation is reached).

### 8.6 Streaming and Piping Considerations

For materialized operations, Unix pipes can eliminate intermediate files:

```
fastp -i input.fq -o /dev/stdout | bbduk.sh in=stdin.fq out=output.fq ref=phix
```

However, this has drawbacks:
1. No intermediate QC metrics (cannot count reads between steps)
2. If any step in the pipe fails, the entire chain fails
3. Harder to resume from failure
4. Not compatible with the virtual derivative model

Recommendation: Do NOT use piping. The virtual derivative model with
deferred materialization is superior because it preserves per-step
metrics and allows the user to inspect intermediate results.

---

## 9. Implementation Priorities for Future Operations

### 9.1 Phase 1: Mapping (Highest Value)

Mapping is the gateway to all downstream genomic analyses. Without it,
variant calling and many QC workflows are impossible.

**Tool recommendation**: minimap2 as the primary mapper.
- Handles both short (Illumina) and long (ONT/PacBio) reads
- Fast index building
- Single binary, no complex dependencies
- Preset system (`-x sr` for short reads, `-x map-ont` for ONT, `-x map-hifi` for HiFi)

**Integration points**:
- Input: Materialized FASTQ from the derivative chain (or raw FASTQ)
- Reference: From project References folder (auto-build `.mmi` index)
- Output: `.lungfishbam` bundle with sorted BAM + BAI + flagstat metrics
- The BAM bundle should link back to its source FASTQ derivative for provenance

### 9.2 Phase 2: Variant Calling (High Value)

Once BAM files exist, variant calling is straightforward.

**Tool recommendation**: bcftools for SNP/indel calling (universal),
lofreq for low-frequency variant detection (viral/amplicon).

**Integration points**:
- Input: BAM from mapping step
- Reference: Same FASTA used for mapping (enforce consistency)
- Output: `.lungfishvcf` bundle
- The existing `VariantDatabase` and VCF viewer infrastructure can
  directly consume the output

### 9.3 Phase 3: Assembly (Medium Value)

Assembly is computationally expensive and the output is less standardized
than mapping/variant calling.

**Tool recommendations**:
- megahit for metagenomics (memory-efficient, fast)
- SPAdes for isolate bacterial genomes (higher quality, slower)
- Flye for long-read assembly

**Integration points**:
- Input: Materialized FASTQ
- Output: `.lungfishasm` bundle with contigs FASTA + metrics
- The existing FASTA viewer can display contigs
- Assembly metrics (N50, contig count) displayed in metadata panel

### 9.4 Phase 4: Consensus Calling (Niche but Valuable for Viral)

For viral sequencing workflows, consensus calling from a BAM produces
the final genome sequence.

**Tool recommendations**:
- samtools consensus or bcftools consensus
- ivar consensus (amplicon-aware, handles primer masking)

---

## 10. Summary of Recommendations

1. **The virtual derivative model is sound.** Subset and trim operations
   should remain virtual. Contaminant filtering should default to
   materialized but offer a virtual mode for very large datasets.

2. **Enforce operation ordering in the recipe builder.** Hard-block
   biologically invalid orderings (merge before adapter trim). Warn on
   suboptimal but valid orderings (quality trim before primer removal).

3. **Add per-step concurrency limits to BatchProcessingEngine.** The
   current global `maxConcurrency` is insufficient for recipes mixing
   lightweight (fastp) and heavyweight (bbduk with large reference)
   operations.

4. **Build the References folder discovery system before adding mapping.**
   Mapping, variant calling, and reference-guided assembly all need it.
   Implement it once and reuse across all reference-dependent operations.

5. **Prioritize minimap2 mapping as the next operation.** It unlocks
   variant calling, coverage analysis, and consensus generation with a
   single tool addition.

6. **Track retention ratios per step and alert on anomalies.** The
   thresholds in section 7.1 should be configurable but ship with
   sensible defaults.

7. **Do not use Unix pipes between operations.** The virtual derivative
   model with deferred materialization is superior for user experience,
   debugging, and provenance tracking.
