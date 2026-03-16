# Cutadapt Demultiplexing Pipeline Specification

## Overview

This document specifies the cutadapt-based pipeline for demultiplexing ONT reads containing dual asymmetric PacBio barcodes. It is based on empirical benchmarking on 100 ONT reads and expert analysis.

The pipeline detects and trims ONT native barcodes (with their flanking sequences), then identifies PacBio barcodes exposed at the read ends.

---

## Read Structure

```
5'-[Y-adapter]-[outer flank: ATTGCTAAGGTTAA]-[ONT BC 24bp]-[rear flank: CAGCACCT]-
   [PacBio BC fwd 16bp]-[M13? ~25%]-[amplicon]-
   [M13?]-[PacBio BC rc 16bp]-[rear flank RC: AGGTGCTG]-[ONT BC RC 24bp]-
   [outer flank RC: TTAACCTTAGCAAT]-[Y-adapter RC]-3'
```

## Key Design Decision: Concatenated ONT Barcode + Rear Flank

The ONT rear flank (`CAGCACCT`, 8bp) is a constant sequence engineered into all ONT native barcoding adapter oligos. It sits between the ONT barcode and the insert DNA. **The rear flank must be included in the ONT barcode adapter definition** so cutadapt trims both in a single pass.

### Why concatenate (not separate trim steps)?

1. **Robustness to indels**: cutadapt aligns the full 32bp as a single unit. An indel at the barcode-flank boundary is absorbed naturally by the alignment. A separate 8bp flank trim is fragile — CAGCACCT is too short to reliably anchor against amplicon false positives.
2. **Simpler pipeline**: One trim step instead of two (or three, if you count both ends separately).
3. **Better alignment accuracy**: The 8bp constant flank provides additional context that helps cutadapt place the adapter boundary correctly.
4. **No offset calculation**: After trimming, the PacBio barcode is at position 0 — no need to skip a fixed number of bases (which breaks with indels).

### Empirical validation (100 ONT reads)

| Pipeline | Both-end reads | Asymmetric pairs | Symmetric pairs | Agreement |
|----------|---------------|-----------------|-----------------|-----------|
| Separate ONT trim + flank trim + 20bp window | 59 | 35 | 18 | reference |
| **Concatenated ONT+flank trim + 20bp window** | **58** | **35** | **18** | **100% on shared reads** |

The concatenated approach produces identical barcode assignments. The 1-read difference is a marginal case at the error-rate boundary.

### Rear flank asymmetry

The top strand flank is `CAGCACCT` (8bp) and the bottom strand is `CAGCACC` (7bp). Use the 8bp version in adapter definitions — the 1bp difference is well within cutadapt's error tolerance and does not require special handling.

---

## Rear Flank Reference by ONT Kit Family

The rear flank is determined by the ONT library prep kit, defined in Dorado's `barcode_kits.cpp`. Source: https://github.com/nanoporetech/dorado/blob/master/dorado/utils/barcode_kits.cpp

| Kit family | Product codes | Rear flank (barcode→insert) | Length | Handling |
|-----------|--------------|---------------------------|--------|----------|
| **Native barcoding** | SQK-NBD114-24/96, NBD111, EXP-NBD103/104 | `CAGCACCT` | 8bp | Concatenate |
| **Rapid barcoding** | SQK-RBK114-24/96, RBK110 | *(none)* | 0bp | No flank needed |
| **PCR barcoding** | EXP-PBC001/096 | PCR primer (28-29bp) | 28-29bp | Concatenate |
| **16S barcoding** | SQK-16S024/114-24 | 16S primer 27F/1492R (20bp) | 20bp | Concatenate |
| **PCR+ligation** | SQK-PCB109/110/111/114 | VNP/SSP primer (22bp) | 22bp | Concatenate |

**All native barcoding kits across all generations use the same CAGCACCT flank.**

---

## Pipeline Steps

### Step 1: Trim ONT barcode + rear flank (5' end)

```bash
cutadapt \
  -g "ont5=[ONT_BARCODE_24bp][REAR_FLANK]" \
  -e 0.15 \
  --overlap 24 \
  --discard-untrimmed \
  -o trimmed_5.fasta \
  input.fasta
```

**Adapter definition**: Concatenate the ONT barcode sequence with the rear flank.
- Example for barcode 13, native kit: `AGAACGACTTCCATACTCGTGTGACAGCACCT` (32bp)
- Example for barcode 13, rapid kit: `AGAACGACTTCCATACTCGTGTGA` (24bp, no flank)

### Step 2: Trim ONT barcode + rear flank (3' end)

```bash
cutadapt \
  -a "ont3=[REAR_FLANK_RC][ONT_BARCODE_RC]" \
  -e 0.15 \
  --overlap 24 \
  --discard-untrimmed \
  -o trimmed_both.fasta \
  trimmed_5.fasta
```

**Adapter definition**: Prepend the rear flank RC to the ONT barcode RC.
- Example for barcode 13, native kit: `AGGTGCTGTCACACGAGTATGGAAGTCGTTCT` (32bp)
- Example for barcode 13, rapid kit: `TCACACGAGTATGGAAGTCGTTCT` (24bp, no flank)

### Step 3: Extract barcode windows

After ONT+flank trimming, the PacBio barcode is at position 0 (5' end) and position -0 (3' end). Extract short windows to prevent amplicon false positives:

- 5' window: first 20bp of each read
- 3' window: last 20bp of each read

The 5' window can be extracted with `cutadapt --length 20`. The 3' window requires extracting the last 20bp (e.g., with seqkit or a simple script).

### Step 4: Classify PacBio barcodes (5' end)

```bash
cutadapt \
  -g file:pacbio_barcodes_fwd.fasta \
  -e 0.20 \
  --overlap 12 \
  --action=none \
  --info-file=pb5_info.tsv \
  -o /dev/null \
  first_20bp.fasta
```

### Step 5: Classify PacBio barcodes (3' end)

```bash
cutadapt \
  -g file:pacbio_barcodes_rc.fasta \
  -e 0.20 \
  --overlap 12 \
  --action=none \
  --info-file=pb3_info.tsv \
  -o /dev/null \
  last_20bp.fasta
```

### Step 6: Pair barcodes

Parse the info files from steps 4 and 5. For each read, combine the 5' and 3' barcode assignments:
- **Asymmetric pair**: 5' barcode ≠ 3' barcode (expected for PacBio dual-indexed libraries)
- **Symmetric pair**: 5' barcode = 3' barcode
- **Single barcode**: Only one end matched
- **Unclassified**: Neither end matched

---

## Parameter Reference

### ONT barcode trimming (steps 1-2)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `-e` | 0.15 | 4 errors in 32bp; covers ONT error rate without crossing inter-barcode distance |
| `--overlap` | 24 | Requires 75% of 32bp adapter to be present; handles truncated reads |
| `--no-indels` | **NOT used** | ONT reads have significant indel rates; allowing indels improved detection by 18% |
| `--discard-untrimmed` | flag | Drop reads without the ONT barcode (not from this experiment) |

### PacBio barcode classification (steps 4-5)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `-e` | 0.20 | 3 mismatches in 16bp; needed for ONT error rate on short barcodes |
| `--overlap` | 12 | Requires 75% of 16bp barcode; handles partial matches |
| `--no-indels` | **NOT used** | Indels improved PacBio barcode detection from 36/50 to 47/50 |
| `--action=none` | flag | Don't trim — we just need the barcode identity |

### Window extraction (step 3)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Window size | 20bp | 16bp barcode + 4bp slack for indel-shifted barcodes |
| `--length 20` | cutadapt flag | Truncates to first 20bp for 5' window |

---

## App Implementation Changes

### 1. Modify ONT barcode adapter definitions

**Current** (in `ONTBarcodeData.swift` or equivalent): Barcode sequences are 24bp, matching only the barcode.

**New**: Append the rear flank to each barcode sequence based on kit type.

```swift
struct ONTBarcodeKit {
    let name: String                    // e.g., "SQK-NBD114.96"
    let barcodes: [(id: String, sequence: String)]  // 24bp barcode sequences
    let rearFlank: String?              // "CAGCACCT" for native, nil for rapid
    let frontFlank: String              // "ATTGCTAAGGTTAA" for native

    /// Build the 5' adapter sequence for cutadapt: [barcode][rearFlank]
    func fivePrimeAdapter(barcodeID: String) -> String {
        guard let seq = barcodes.first(where: { $0.id == barcodeID })?.sequence else { return "" }
        return seq + (rearFlank ?? "")
    }

    /// Build the 3' adapter sequence for cutadapt: [rearFlankRC][barcodeRC]
    func threePrimeAdapter(barcodeID: String) -> String {
        guard let seq = barcodes.first(where: { $0.id == barcodeID })?.sequence else { return "" }
        let rc = reverseComplement(seq)
        let flankRC = rearFlank.map { reverseComplement($0) } ?? ""
        return flankRC + rc
    }
}
```

### 2. Expose parameters in the UI

The following parameters should be user-configurable in the FASTQ operations panel:

| Parameter | Default | UI control | Notes |
|-----------|---------|------------|-------|
| ONT barcode error rate | 0.15 | Slider (0.05-0.25) | Higher = more permissive |
| ONT barcode min overlap | 24 | Stepper (16-32) | Lower = allows more partial matches |
| Allow indels (ONT) | true | Toggle | Should almost always be on for ONT |
| PacBio barcode error rate | 0.20 | Slider (0.10-0.30) | Higher = more permissive |
| PacBio barcode min overlap | 12 | Stepper (8-16) | Lower = allows more partial matches |
| Allow indels (PacBio) | true | Toggle | Should almost always be on for ONT |
| Barcode window size | 20 | Stepper (16-30) | Larger = more tolerance for shifted barcodes |

### 3. Modify DemultiplexingPipeline.swift

The pipeline currently runs cutadapt with barcode-only adapter definitions. Changes needed:

1. When building the cutadapt adapter FASTA file, concatenate the rear flank to each barcode sequence.
2. After ONT barcode trimming, extract 5'/3' windows (not full reads) for PacBio barcode classification.
3. Parse both 5' and 3' info files to build barcode pair assignments.
4. Create derivative bundles named by pair (e.g., `bc1002--bc1049`) instead of single barcode.

---

## Expected Performance

On the 100-read test dataset:
- **ONT barcode detection**: 98% (5'), 59% (3') — 58 reads with both ends
- **PacBio barcode pairing**: 35 asymmetric + 18 symmetric = 53 paired (91% of both-end reads)
- **Biological ceiling**: Only ~59% of reads have the 3' ONT construct (ONT sequencing truncation)
- **Pipeline speed**: cutadapt processes 21k reads in ~10 seconds per step

---

## Test Data

- 100-read FASTA: `/Users/dho/Downloads/100_reads_FBC38282_pass_barcode13_a1c761b1_8146054e_106 extraction.fasta`
- Full dataset: `/Users/dho/Downloads/fastq_pass_barcode13/FBC38282_pass_barcode13_a1c761b1_8146054e_104.fastq.gz` (21,748 reads)
- PacBio 384 barcode FASTA: stored in `PacBioBarcodeData.swift` as `sequel384V1FASTA`
