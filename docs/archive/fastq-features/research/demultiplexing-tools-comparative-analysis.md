# Demultiplexing Tools: Comparative Analysis

## Research Objective

Understand how professional bioinformatics tools handle FASTQ demultiplexing, barcode removal, adapter trimming, and primer removal across ONT, PacBio, and Illumina platforms. Inform the Lungfish FASTQ operations design.

---

## 1. ONT Dorado (Oxford Nanopore's Official Basecaller/Demuxer)

### Algorithm

Dorado uses **edlib** (edit-distance-based alignment) for barcode classification. The algorithm:

1. Uses flanking sequences (adapters) to locate a **window** in the read where the barcode should be
2. Each barcode candidate is aligned to the subsequence within that window
3. Edit distance is computed and converted to a penalty score: `score = 1.0 - (edit_distance / length(target_seq))`
4. The barcode with the lowest penalty (best match) is selected, subject to separation thresholds

### Barcode Orientation Handling

For **double-ended native barcoding** (e.g., SQK-NBD114.24), the read structure is:

```
5' --- ADAPTER ... LEADING_FLANK_1 --- BARCODE_1 --- TRAILING_FLANK_1 ...
      READ ...
      RC(TRAILING_FLANK_2) --- RC(BARCODE_2) --- RC(LEADING_FLANK_2) ... 3'
```

Key points:
- The **rear barcode** appears as the **reverse complement** of the reference barcode sequence
- The default heuristic looks for barcodes on **either** end of the read (increases classification rate but may increase false positives)
- `--barcode-both-ends` forces detection on **both** ends (reduces false positives, lowers overall classification rate)
- For symmetric kits (same barcode both ends), the front and rear flank/barcode sequences are identical

### Scoring Parameters (TOML configuration)

| Parameter | Description |
|-----------|-------------|
| `max_barcode_penalty` | Maximum acceptable edit distance for a classified barcode |
| `min_barcode_penalty_dist` | Required penalty difference between top-2 candidates |
| `min_separation_only_dist` | Required penalty difference when penalty exceeds threshold |
| `barcode_end_proximity` | How close the barcode construct must be to read ends |
| `front_barcode_window` / `rear_barcode_window` | Search region size (typically 175 bp) at read extremities |
| `min_flank_score` | Alignment quality threshold for flanking sequences (0-1) |
| `flank_left_pad` / `flank_right_pad` | Padding bases (5-10) for alignment |

### Custom Barcode TOML Format

```toml
[arrangement]
name = "custom_kit"
mask1_front = "ADAPTER_FRONT_FLANK"
mask1_rear = "ADAPTER_REAR_FLANK"
barcode1_pattern = "BC%02i"
mask2_front = "REAR_ADAPTER_FRONT_FLANK"   # double-ended only
mask2_rear = "REAR_ADAPTER_REAR_FLANK"     # double-ended only
barcode2_pattern = "BC%02i"                 # double-ended only
first_index = 1
last_index = 24
```

### Output Format

- Generates separate BAM/FASTQ files per barcode plus one for "unclassified"
- Barcode classification stored in BAM tags
- Barcodes trimmed by default (`--no-trim` to preserve)

### Known Limitations (per Barbell paper, Oct 2025)

- Approximately **7% of reads** left partially trimmed with adapter fragment contamination
- Complex barcode attachment patterns not fully handled
- Rapid barcoding: ~17% of reads contain multiple barcodes or artifacts

---

## 2. PacBio Lima

### Algorithm

Lima uses **Smith-Waterman glocal alignment** (global in barcode reference, local in query sequence). This approach:

1. Computes SW scores for each barcode region, examining both leading and trailing positions
2. Tests each barcode in both **forward and reverse-complement** orientation, choosing the higher-scoring orientation
3. For the best barcode, evaluates all possible pair combinations
4. Normalizes score: `(100 * sw_score) / (sw_match_score * barcode_length)` producing a 0-100 range

### Three Barcode Design Types

| Design | Description | Flag | Minimum Requirement |
|--------|-------------|------|---------------------|
| **Symmetric** | Same barcode on both ends, same orientation | `--same` / `--hifi-preset SYMMETRIC` | Single barcode region sufficient |
| **Tailed** | Same barcode on both ends, different orientation (trailing is RC) | `--same` | Single barcode region sufficient |
| **Asymmetric** | Different barcode pair on each end | `--different` / `--hifi-preset ASYMMETRIC` | Both leading AND trailing barcode regions required |

### Asymmetric Barcode Handling

- Both flanking barcodes must be observed (ZMWs with only one adapter are removed)
- Output naming uses `bc1002--bc1054` format (lowest index first)
- `--min-signal-increase` prevents spurious asymmetric assignments when symmetric barcodes dominate
- `--min-score-lead` (default 10) requires sufficient gap between best and second-best barcode

### Precision (PPV) by Design

| Design | Plex | PPV (CLR) |
|--------|------|-----------|
| Symmetric | 8-plex | 99.7% |
| Symmetric | 384-plex | 99.1% |
| Asymmetric | 28-plex | 98.8% |
| Asymmetric | 384-plex | 97.0% |
| Mixed (NOT supported) | 36-plex | 90.6% |

**HiFi data** with `--min-score 80`: **99.992% PPV** (recommended setting)

| Score Threshold | PPV | Yield Loss |
|-----------------|-----|------------|
| 25 | 99.96% | 0.53% |
| 80 (recommended) | 99.99% | 2.79% |
| 100 | 99.99% | 15.59% |

### Key Design Decision

**Mixing symmetric and asymmetric barcode pairs in one library is explicitly NOT supported** and yields ~90% PPV. Lima enforces this separation.

### Output

- Orientation-agnostic (forward or reverse-complement, but not reversed)
- Supports BAM, FASTQ, FASTA output
- Separate files per barcode pair

---

## 3. Geneious Prime

### Demultiplexing Workflow

**Menu path:** Sequence > Separate Reads by Barcode

**UI Configuration:**
- Preset barcode sets: 454 MID (standard, Titanium), Rapid MID
- Custom barcode sets: user-defined via Edit Barcode Sets dialog
- "Specific barcode" mode for single-barcode extraction (e.g., a primer)
- Auto-detect mode: specify barcode length only, Geneious identifies barcode sequences automatically

**Barcode Location:**
- Sorts by barcodes at the **5' end only**
- 3' barcodes/adapters/primers trimmed via "Trim End Adaptor/Primer/Barcode" checkbox
- Special token `[END_BARCODE]` for matching the reverse complement of the 5' barcode at the 3' end
- Adapter and linker sequences can be specified as fixed flanking regions

**Error Tolerance:**
- Allows mismatches (configurable, specific threshold not documented in public sources)

### Adapter/Primer Trimming (BBDuk Plugin)

**Recommended order of operations:**
1. Set paired reads (if applicable)
2. **Demultiplex** (Separate by Barcodes) -- ALWAYS before trimming
3. Quality check
4. **Trim** with BBDuk (adapter + quality trimming combined)

BBDuk handles adapter trimming and primer removal **in a single step**:
- Presets for Illumina TruSeq adapters
- Custom adapter/primer sequences can be imported
- Simultaneous quality trimming + length filtering

### Output Organization

- Creates **separate sequence list documents** named by barcode
- Documents appear as siblings in the current folder (flat, not hierarchical)
- No automatic subfolder creation; user organizes manually
- Unmatched reads collected in a separate document

### Platform Support

- **Illumina**: Barcodes detected from FASTQ header (classical and HiSeq X formats auto-detected)
- **ONT/PacBio**: Barcodes are in-read at unknown positions; requires basecalled FASTQ (no native fast5/pod5)
- No specialized ONT native barcoding kit support (no built-in knowledge of flanking adapters)

---

## 4. CLC Genomics Workbench (Qiagen)

### Demultiplexing Workflow

**Wizard-based UI** (multi-step dialog):
1. Select input sequences (single-end or paired-end)
2. Define **element structure** as ordered chain: Linker > Barcode > Sequence (or other arrangements)
3. For paired reads: configure parameters separately for R1 and R2 (two wizard pages)
4. Specify barcodes manually or import from CSV/Excel
5. Configure output options

### Barcode Matching

- **Exact match only** -- no mismatch tolerance
- "Sequences are associated with a particular sample when they contain an exact match to a particular barcode"
- This is a significant limitation for noisy long-read data

### Element Types

Users define read structure as a sequence of typed elements:
- **Linker** (adapter): sequence to be ignored/removed
- **Barcode**: sample identifier (length specified)
- **Sequence**: target region retained in output

### Barcode Orientation

- Configurable element order (barcode before or after sequence)
- Historical bug: tool always demultiplexed as "barcode, sequence" regardless of configured order (fixed in later versions)
- For paired-end: each read configured independently

### Output Organization

- Individual sequence lists per barcode
- "Not grouped" file for unmatched reads
- Summary report with read counts per barcode
- Optional subfolder creation for batch processing

### Key Limitation

CLC handles **in-line barcodes only** (barcodes embedded in reads). It assumes Illumina index demultiplexing is performed upstream by instrument software (bcl2fastq/BCL Convert).

---

## 5. Porechop / Porechop_ABI

### Porechop (now deprecated)

**Algorithm:**
- Aligns first and last **150 bases** of each read against all known adapter sequences
- Match criteria: minimum **4 bases** aligned, minimum **75% identity**
- Trims adapter plus **2 extra bases** beyond the match
- Identity measured over the **aligned portion** of the adapter (not full length) -- enables trimming of partially present adapters/barcodes

**Demultiplexing:**
- Supports Native Barcoding Kit, PCR Barcoding Kit, Rapid Barcoding Kit
- Default: single barcode match sufficient to bin a read
- `--require_two_barcodes`: both start and end must match the same barcode (more stringent)
- Not appropriate for rapid barcoding kits (barcodes only at start)

**Chimera Detection:**
- When adapter found in the **middle** of a read, treats it as chimeric
- Splits into separate reads at the adapter junction

### Porechop_ABI (Active Fork)

- Discovers adapter sequences **de novo** without prior knowledge
- Uses **approximate k-mers** to identify adapter sequences by frequency
- Works across different flowcells, kits, and basecallers
- Extends Porechop's functionality to unknown/novel adapters

---

## 6. qcat (ONT's Python Demultiplexer)

- Implements the **EPI2ME/Guppy demultiplexing algorithm** in standalone Python
- Accepts basecalled FASTQ files
- Kit-aware (specifying correct kit improves sensitivity/specificity)
- Reported adapter detection rate: ~99% in tested datasets
- Now largely superseded by Dorado's built-in demultiplexing

---

## 7. Deepbinner (Signal-Level Demultiplexing)

- Uses **deep convolutional neural networks** on **raw electrical signal** (not basecalled sequence)
- Trained on 9.1 GB of signal data
- Significantly better recall than base-space tools:
  - ~10% recall improvement over Albacore/Porechop
  - 1-2% precision improvement
  - Particularly strong on low-quality reads (where base-space tools drop below 50% recall)
- Can be used alone (maximize classified reads) or combined with Albacore/Guppy (maximize precision)

---

## Comparative Analysis

### Key Question 1: Do any tools use cutadapt for demux?

**No major tool uses cutadapt as its primary demux engine.** Each platform has specialized demultiplexers:
- ONT: Dorado (edlib), qcat (EPI2ME algorithm), Porechop (custom alignment)
- PacBio: Lima (Smith-Waterman glocal alignment)
- Illumina: bcl2fastq/BCL Convert (exact matching with configurable mismatches)
- Geneious: Built-in barcode splitter
- CLC: Built-in exact-match demultiplexer

Cutadapt **can** do demultiplexing and is used in some metabarcoding pipelines, but it was historically single-threaded for demux and lacks the platform-specific heuristics (flanking sequence awareness, adapter structure knowledge) that specialized tools provide. Cutadapt is primarily used for **adapter/primer trimming after demultiplexing**.

### Key Question 2: How do tools handle the 4 ONT barcode orientations?

For ONT native barcoding, a read can present the barcode in **4 configurations** depending on which strand was sequenced and which end is read first:

| Config | Front | Rear |
|--------|-------|------|
| 1 | BC_forward | RC(BC_forward) |
| 2 | RC(BC_forward) | BC_forward |
| 3 (asymmetric) | BC_forward | RC(BC_reverse) |
| 4 (asymmetric) | RC(BC_reverse) | BC_forward |

**Dorado**: Searches a window at each end, tests barcode in both forward and RC orientation, takes best score. For symmetric kits, front and rear barcodes are the same sequence. The rear barcode appears as RC because of read structure (the molecule is read 5' to 3', so the barcode ligated to the 3' end appears as RC).

**Porechop**: Aligns known barcodes against read start/end; the alignment naturally handles orientation since it checks all known barcode sequences (which implicitly include the expected orientations).

**Lima**: Tests each barcode "as given and as reverse-complement" at each position, choosing the higher-scoring orientation. Explicitly orientation-agnostic.

### Key Question 3: Error rates and matching algorithms

| Tool | Algorithm | Error Tolerance |
|------|-----------|-----------------|
| **Dorado** | edlib (edit distance) | Configurable via `max_barcode_penalty` (typically allows ~15-25% edit distance) |
| **Lima** | Smith-Waterman (glocal) | Score 0-100; recommended `--min-score 80` for HiFi |
| **Porechop** | Local alignment | 75% identity threshold over aligned region |
| **CLC** | Exact match | 0 mismatches |
| **Geneious** | Alignment-based | Configurable (details not public) |
| **Deepbinner** | CNN on raw signal | N/A (learned decision boundary) |
| **qcat** | EPI2ME algorithm | Kit-dependent |

### Key Question 4: Separation of demultiplexing vs. trimming

| Tool | Demux + Trim Combined? | Details |
|------|------------------------|---------|
| **Dorado** | Combined by default | Barcodes trimmed during classification; `--no-trim` to separate |
| **Lima** | Combined | Barcodes and adapters clipped in one pass |
| **Porechop** | Combined | Adapter trimming and barcode demux in single tool |
| **Geneious** | Separate steps | Demux (Separate by Barcodes) THEN trim (BBDuk); recommended order |
| **CLC** | Combined | Linker/barcode removal is part of demux element structure |
| **cutadapt** | Can do either | Primarily trimming; demux is secondary feature |

**Industry consensus**: Platform-native tools (Dorado, Lima) combine demux and trimming. GUI workbenches (Geneious, CLC) tend to separate them into distinct workflow steps for user clarity.

### Key Question 5: How demuxed results are presented to users

| Tool | Output Organization |
|------|---------------------|
| **Dorado** | Separate files per barcode (barcode01.bam, barcode02.bam, unclassified.bam) |
| **Lima** | Separate files per barcode pair (bc1002--bc1054.bam), flat directory |
| **Geneious** | Separate sequence list documents per barcode in current folder (flat, not hierarchical) |
| **CLC** | Sequence lists per barcode + "Not grouped" + summary report; optional subfolders |
| **Porechop** | Separate FASTQ per barcode in output directory |

**No tool uses a virtual parent-child hierarchy**. All produce flat file collections. The closest to hierarchy is CLC's optional subfolder creation and summary reports.

### Key Question 6: Typical accuracy for ONT barcode detection

| Tool | Metric | Value |
|------|--------|-------|
| **Dorado** | Classification rate | ~93% (7% left partially trimmed per Barbell study) |
| **Lima** (PacBio) | PPV | 99.99% (HiFi, --min-score 80) |
| **Deepbinner** | Recall improvement | +10% over Albacore/Porechop |
| **qcat** | Adapter detection | ~99% |
| **Porechop** | General | Lower than Deepbinner; adequate for high-quality reads |
| **Guppy** (legacy) | vs Dorado | Generally similar; some users report more unclassified reads with Dorado |

---

## Design Implications for Lungfish

### 1. Demux Engine Choice

The current Lungfish approach of using **cutadapt** for demux is unconventional. Every major platform has a specialized demux tool. Consider:
- **For ONT**: Wrapping Dorado's `demux` subcommand or implementing edlib-based matching
- **For PacBio**: Wrapping Lima
- **For Illumina**: Assuming pre-demuxed data (industry standard)
- **For custom/simple demux**: cutadapt is adequate

If staying with cutadapt, ensure the linked adapter approach correctly handles all 4 barcode orientations for ONT native barcoding (the current two-phase scout approach in the codebase addresses this).

### 2. Separation of Concerns

Geneious's approach of separating demux from trimming is the most user-friendly for a GUI application:
- **Step 1**: Demultiplex (identify and split by barcode)
- **Step 2**: Trim adapters/primers (BBDuk or cutadapt)
- **Step 3**: Quality filter

This matches the existing Lungfish DemultiplexPlan multi-step architecture.

### 3. Output Presentation

No tool uses virtual parent-child relationships. All produce flat file collections. For Lungfish:
- Create a results folder per demux run
- Individual FASTQ files per barcode within the folder
- Summary statistics document
- The sidebar could show these as expandable groups (virtual hierarchy over flat files)

### 4. Error Tolerance Defaults

Recommended defaults based on industry practice:
- ONT: ~15-20% error rate for barcode matching (Dorado's default)
- PacBio HiFi: Score threshold 80/100 (~20% tolerance)
- Illumina: 1 mismatch (bcl2fastq default)
- The current Lungfish default of ~10% error rate for cutadapt is reasonable

### 5. Barcode-Both-Ends Strategy

For ONT native barcoding:
- Default: require barcode on ONE end (maximizes yield)
- Strict mode: require barcode on BOTH ends (maximizes accuracy)
- This is exactly what Dorado's `--barcode-both-ends` flag does
- Porechop's `--require_two_barcodes` is the equivalent

---

## Sources

- [Dorado Barcode Classification Documentation](https://software-docs.nanoporetech.com/dorado/latest/barcoding/barcoding/)
- [Dorado Custom Barcodes Documentation](https://software-docs.nanoporetech.com/dorado/latest/barcoding/custom_barcodes/)
- [Lima Documentation](https://lima.how/)
- [Lima Precision FAQ](https://lima.how/faq/precision.html)
- [Lima Barcode Score FAQ](https://lima.how/faq/barcode-score.html)
- [Lima Barcode Design](https://lima.how/barcode-design.html)
- [PacBio Barcoding GitHub](https://github.com/PacificBiosciences/barcoding)
- [Geneious Prime Preprocessing Best Practices](https://help.geneious.com/hc/en-us/articles/360044626852)
- [Geneious Barcode Splitting Manual](https://assets.geneious.com/manual/2019.2/static/GeneiousManualsu93.html)
- [CLC Genomics Workbench Demultiplex Reads (v9.0)](https://resources.qiagenbioinformatics.com/manuals/clcgenomicsworkbench/900/index.php?manual=Demultiplex_reads.html)
- [Porechop GitHub](https://github.com/rrwick/Porechop)
- [Porechop_ABI Paper (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9869717/)
- [qcat GitHub](https://github.com/nanoporetech/qcat)
- [Deepbinner Paper (PLOS Comp Bio)](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1006583)
- [Barbell Preprint (bioRxiv Oct 2025)](https://www.biorxiv.org/content/10.1101/2025.10.22.683865v1.full)
- [Cutadapt User Guide](https://cutadapt.readthedocs.io/en/stable/guide.html)
- [Ultraplex Paper (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8287537/)
