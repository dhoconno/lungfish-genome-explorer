# Plan: Fix Demux Parameters + Trim Position Storage

## Problem 1: PacBio barcodes on ONT reads get wrong parameters

When a user selects a PacBio barcode kit (e.g. Sequel 384) to demultiplex ONT reads,
the kit's `.pacbio` platform yields error rate 0.10 and overlap 14. These are too strict
for ONT reads (which have higher error at adapter junctions). Result: 7.6% assignment
instead of ~56%.

### Fix: Detect sequencing platform from read headers

ONT reads have distinctive headers with `basecall_model_version_id=`, `flow_cell_id=`,
`protocol_group_id=`. The DemultiplexConfig should carry the **detected sequencing platform**
(from the source FASTQ) separately from the barcode kit's platform. When they differ,
use the sequencing platform's error rate and overlap settings.

**Implementation:**
1. In `DemultiplexConfig`, add `sequencingPlatform: SequencingPlatform?`
2. In `FASTQDerivativeService`, detect the platform from the first FASTQ header before
   creating the config (we already parse headers for metadata)
3. In `DemultiplexingPipeline.runScoutCutadapt()` and `run()`, use
   `config.sequencingPlatform?.recommendedErrorRate ?? config.barcodeKit.platform.recommendedErrorRate`
4. Also add `--no-indels` for long-read platforms with short barcode sequences (16bp PacBio
   barcodes benefit from Hamming-only matching)

**Files:**
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift` — use sequencingPlatform params
- `Sources/LungfishIO/Formats/FASTQ/SequencingPlatform.swift` — add platform detection from header
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift` — pass detected platform to config

## Problem 2: Virtual bundles need trim positions

Currently virtual bundles store `read-ids.txt` + `preview.fastq.gz`. When materialized
(for export or downstream cutadapt), the full reads are extracted from the root FASTQ
with barcodes/adapters still present. The derived FASTQ should have adapters trimmed.

### Fix: Store trim info from cutadapt, apply during materialization

cutadapt's `--info-file` outputs per-read adapter match details including match positions.
We can use this to store trim coordinates per read.

**Implementation:**
1. During demux, pass `--info-file` to cutadapt to capture per-read trim positions
2. Parse the info file: columns include read name, match start, match end, adapter name
3. Store a `trim-positions.tsv` in each virtual barcode bundle (read_id \t trim_5prime \t trim_3prime)
4. Update `FASTQDerivativePayload.demuxedVirtual` to include `trimPositionsFilename: String?`
5. During materialization, use `seqkit subseq` or native Swift to extract reads AND apply trims
6. Preview files should also be trimmed

**Files:**
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift` — add --info-file, parse trims
- `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift` — add trimPositionsFilename
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift` — apply trims during materialization

## Phased Implementation

### Phase 1: Fix cutadapt parameters for cross-platform demux
- Add platform detection from FASTQ headers
- Thread sequencing platform through DemultiplexConfig
- Use detected platform's error rate and overlap in scout + full demux
- Add `--no-indels` for long-read + short-barcode combos
- **Commit after**: build + tests pass

### Phase 2: Add trim position capture during demux
- Add `--info-file` to cutadapt invocation
- Parse info file into per-read trim coordinates
- Store `trim-positions.tsv` in each virtual bundle
- Update `demuxedVirtual` payload to carry trim filename
- **Commit after**: build + tests pass

### Phase 3: Apply trims during materialization and export
- When materializing a virtual bundle, extract reads AND apply stored trims
- Preview files trimmed at creation time
- Export path also applies trims
- **Commit after**: build + tests pass, end-to-end verification
