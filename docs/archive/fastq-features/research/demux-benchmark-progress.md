# Demultiplexing Benchmark Progress

## Dataset
- File: `FBC38282_pass_barcode13_a1c761b1_8146054e_104.fastq.gz`
- Reads: 21,748
- ONT R10.4.1, barcode13 pre-demuxed by MinKNOW
- Contains: PacBio Sequel 384 asymmetric barcodes (16bp) flanked by ONT native construct

## Read Structure (verified on first 20 reads)
```
5'-[variable]-[Y-adapter]-[AAGGTTAA]-[ONT BC13(24bp)]-[CAGCACCT(inner flank)]-
   [PacBio BC fwd(16bp)]-[M13?(25% of reads)]-[amplicon]-
   [M13?]-[PacBio BC rc(16bp)]-[AGGTGCTG(inner flank RC)]-
   [ONT BC13 RC]-[TTAACCTT]-[Y-adapter RC]-3'
```

## Completed Experiments

### Approach 1: cutadapt single-pass `-g --revcomp` (e=0.15)
- Single barcode: 20,778/21,748 (95.5%)
- No paired classification (assigns ONE best barcode per read)

### Approach 2: cutadapt single-pass `-g --revcomp` (e=0.20)
- Single barcode: 21,674/21,748 (99.7%)

### Approach 3: cutadapt two-step flank-trim → classify (e=0.15)
- Both barcodes: 7,888/21,748 (36.3%)
- Asymmetric: 4,392/21,748 (20.2%), Symmetric: 3,496/21,748 (16.1%)

### Approach 3b: cutadapt two-step (e=0.20)
- Both barcodes: 20,335/21,748 (93.5%)
- Asymmetric: 15,830/21,748 (72.8%), Symmetric: 4,505/21,748 (20.7%)
- **ISSUE**: 92% of symmetric pairs are false (unanchored re-finding)
- Position filter (≤5bp): only 8.0% asymmetric, 10.8% symmetric

### Approach 4: cutadapt anchored classification (e=0.20)
- 1.8% asymmetric — too strict (ONT indels shift barcode position)

### Approach 5: cutadapt two-pass (classify → trim → reclassify)
- Pass 1: 99.7% classified, Pass 2: 78.2% classified
- Asymmetric: 64.7%, Symmetric: 13.8%
- **ISSUE**: 57% of pass 2 matches at position 500+ (false positives in amplicon)
- Position filter (≤100bp): only 10.9% asymmetric

### Approach 6: seqkit locate
- Returns all barcode positions with ≤3 mismatches — no structural anchoring
- Multiple false positive matches per read throughout amplicon

### Approach 7: Custom positional Hamming scanner (v6)
- Uses ONT BC13 (24bp) as anchor, sliding window ±20bp for barcode
- K-mer pre-filtered for speed
- **1000-read results**: 30.0% asymmetric, 15.7% symmetric, 45.4% single, 8.9% unclassified
- **Full dataset**: running (rates consistent at ~30% asym, ~15% sym through 4500 reads)
- Cross-validation with cutadapt: ~90% agreement on first barcode
- **Speed**: 40s/1000 reads in Python. Est. 2-5s/1000 in Swift.

### Tool availability
- bbduk.sh: NOT bundled in app, not tested
- seqkit: bundled, tested (no positional filtering = unusable alone)
- cutadapt: bundled, extensively tested (single-barcode only)

## Key Findings

1. **cutadapt cannot natively find two barcodes per read** — fundamental ONE-adapter-per-read design
2. **16bp barcodes match in amplicon DNA** — ~5% false positive rate at ≤3 mismatches
3. **8bp inner flanks match 2-4× per read** — too short for reliable anchoring
4. **ONT BC13 (24bp) is the reliable anchor** — false positive rate ~0.0006% per read
5. **3' end quality limits dual detection** — ~90% for 5' barcode, ~50-65% for 3' barcode
6. **ONT indels shift barcodes 2-5bp** — sliding window required, anchored matching fails

## Recommendation

**Hybrid two-phase pipeline**:
1. cutadapt single-pass with `--info-file` → 99.7% first barcode (fast, proven)
2. Swift-native positional Hamming scanner → ~30-45% second barcode (accurate)

See: `demux-benchmark-report.md` for full report
See: `demux-implementation-plan.md` for implementation details
