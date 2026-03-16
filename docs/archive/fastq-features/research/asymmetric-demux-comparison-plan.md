# Asymmetric Demux Comparison: lima vs cutadapt

## Context
- Input: `/Users/dho/Desktop/barcode13.fastq.gz` (plain text FASTQ, 20,467 reads, 98 MB)
- Barcodes: PacBio Sequel 96 v2 (asymmetric/combinatorial pairs)
- Sample map: `/Users/dho/Downloads/32118_ONT05_MHC-I-E_Barcodes.xlsx` (192 samples across 3 plates)
- Problem: cutadapt finds only ~hundreds of reads out of 20,467. Expecting ~20K assigned.
- Platform: ONT reads (basecalled by MinKNOW) with PacBio M13 barcodes at both ends

## Barcode Layout
- Plate 1 (32055-01 to 32055-96): even-numbered bc (bc1002-bc1016) x (bc1050-bc1072)
- Plate 2 (32055-97 to 32055-192): odd-numbered bc (bc1003-bc1017) x (bc1050-bc1072)
- Plate 3 (32084-01 to 32084-80): bc1001-bc1016 x bc1017-bc1024
- All asymmetric pairs: barcode_fwd,barcode_rev per sample

## Plan

### Step 1: Prepare barcode FASTA for lima
- Extract PacBio Sequel 96 barcode sequences from `PacBioBarcodeData.sequel96V2FASTA`
- Write to `/tmp/demux-comparison/pacbio_sequel96.fasta` in lima's expected format
- Each barcode as `>bcXXXX\nSEQUENCE`

### Step 2: Run lima in Docker
- Image: `quay.io/biocontainers/lima:2.9.0--h9ee0642_1`
- lima requires BAM input, but can also accept FASTQ
- Command: `lima barcode13.fastq.gz barcodes.fasta output.fastq --split-named --peek-guess`
- `--peek-guess` auto-detects barcode orientation
- Capture: lima summary counts per barcode pair

### Step 3: Run cutadapt manually (replicating our pipeline logic)
- Generate the same adapter FASTA that DemultiplexingPipeline creates
- Use PacBioAdapterContext: bare barcode + RC(barcode) as linked adapters
- Both orientations: fwd--rev AND rev--fwd
- Run cutadapt with same parameters our pipeline uses
- Capture: per-barcode read counts

### Step 4: Compare results
- For each barcode pair in the Excel sample map:
  - lima read count
  - cutadapt read count
  - delta
- Total assigned reads for each tool
- Identify barcodes found by lima but missed by cutadapt

### Step 5: Diagnose cutadapt shortfall
- Check if the issue is:
  a. Error rate too strict (default 0.1 = 10%)
  b. Linked adapter syntax too strict (requires BOTH barcodes)
  c. Missing flanking context (PacBioAdapterContext uses bare sequences)
  d. Wrong barcode orientation handling
  e. Cutadapt can't handle the M13-primer-barcode structure
- Try relaxing parameters to see if more reads match

## Results

### Read Structure Discovery
The reads have PacBio M13 barcodes embedded within ONT native library adapter constructs:
```
5': [variable] + [Y-adapter: TTCGTTCAGTTACGTATTGCT] + [AAGGTTAA] + [inner flank: GAACGACTTCCATACTCGTGTGACAGCACCT] + [BARCODE_16bp] + [M13 primer] + [amplicon]
3': [amplicon] + [M13 primer RC] + [BARCODE_RC_16bp] + [RC(inner flank): AGGTGCTGTCACACGAGTATGGAAGTCGTTC] + [TTAACCTT] + [Y-adapter RC] + [variable]
```
- Barcode is at position ~77 from 5' end (not at read boundary)
- 30bp inner flank between ONT outer flank and barcode
- 5' orientation: 93% fwd, 7% rc (biased toward fwd)
- 3' orientation: 40% fwd, 60% rc (mixed)
- 3' barcode errors higher (mean 1.1) vs 5' (mean 0.3)

### Barcode Set Issue
- Sequel 96 v2 is MISSING bc1005 and bc1014 (used in sample sheet)
- Sequel 384 v1 has ALL 36 needed barcodes
- This alone causes some samples to be unassignable with Sequel 96

### Lima Results
- Lima (PacBio's native demultiplexer) could NOT run on ONT FASTQ data
- Requires PacBio-specific BAM metadata (read type, ZMW grouping)
- Not a viable comparison tool for ONT reads with PacBio barcodes

### Cutadapt Parameter Sweep (linked adapters, both orientations, 272 sample pairs)

| Parameters | Assigned | Rate | Notes |
|---|---|---|---|
| `-e 0.10 --overlap 14` | 1,557 | 7.6% | Scout exact params (PacBio defaults) |
| `-e 0.15 --overlap 14` | 2,937 | 14.3% | Relaxed error rate |
| `-e 0.20 --overlap 14` | 15,391 | 75.2% | Very permissive (likely false positives) |
| `-e 0.15 --overlap 10` | 3,559 | 17.4% | Reduced overlap |
| `-e 0.15 --no-indels` | 11,554 | 56.5% | No overlap requirement, Hamming only |
| `-e 0.15` (V2, ONT context) | 5,229 | 25.5% | Added ONT Y-adapter flanking |
| `-e 0.15` (V3, full context) | 5,543 | 27.1% | Added inner flank too |

### Python Ground Truth (Hamming matcher, max 3 errors, search 150bp each end)
- 5' barcode found: 18,519/20,467 (90.5%)
- 3' barcode found: 12,232/20,467 (59.8%)
- Both barcodes found: 11,114/20,467 (54.3%)
- Mapped to known samples: 7,647 (37.4%)
- Unexpected pairs: 3,467

### Diagnosis

**The core problem is parameter mismatch: PacBio barcode kits get PacBio platform defaults (error=0.10, overlap=14), but these are ONT reads.**

1. `--overlap 14` with 16bp barcodes is extremely strict — requires 14/16 bases to align. This kills the linked adapter matching for barcodes embedded 77bp into the read.

2. `-e 0.10` only allows 1 error in 16bp. ONT adapter junctions have higher error rates (avg 1.1 at 3' end) — need at least `-e 0.15` (2 errors).

3. The `--no-indels` flag (Hamming-only matching) performs surprisingly well because it avoids the overlap requirement. However, it may cause more false positives.

4. Adding ONT adapter flanking context (V2/V3) paradoxically reduces matching because the longer adapter spec makes the linked adapter stricter.

### Recommended Fix

For PacBio barcodes on ONT reads:
- Use `-e 0.15` (not 0.10) — ONT error rates at adapter junctions
- Use `--no-indels` — prevents indel-based false matches while removing overlap strictness
- Keep both orientations in linked adapters (already generated by M×M loop)
- OR: detect that the sequencing platform is ONT (from read headers) and apply ONT parameters even when using PacBio barcode kits

## Working directory
`/tmp/demux-comparison/`
