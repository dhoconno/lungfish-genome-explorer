# Structure-Aware Demultiplexing Spec

## Goal

Add a structure-aware demultiplexing workflow for long-read FASTQ datasets that lets users describe how a library is actually constructed, preview what is present in sampled reads, and compile that description into a cutadapt-based demultiplexing strategy. The workflow must live in the FASTQ bottom drawer and must coexist with the current kit-centric demultiplexing flow.

This is explicitly designed for mixed or incomplete read structures such as:

- ONT barcode present on one end or both
- PacBio asymmetric barcodes present with optional M13 context
- gene primers present, partially present, or missing on one side
- reads that begin or end inside the expected construct rather than spanning the whole molecule

## Non-Goals For The First Implementation

- Do not add an ML/foundation-model demultiplexer.
- Do not replace cutadapt with a learned classifier.
- Do not attempt full dynamic grammar inference from arbitrary reads.
- Do not require all structure elements to participate in actual cutadapt trimming in v1.

The first implementation is deterministic and explainable. It uses:

- a declarative structure model
- a preview/evidence scanner on sampled reads
- a planner that compiles the structure model into the existing multi-step cutadapt demultiplex pipeline

## Product Requirements

1. Users can configure a structure-aware demux model in the FASTQ bottom drawer.
2. Users can preview sampled read evidence before running demux.
3. Preview summarizes observed structure, not just theoretical library structure.
4. The configured model is persisted in FASTQ sidecar metadata.
5. Running `Demultiplex (Barcodes)` should use the structure-aware model when no explicit manual plan is present.
6. The initial planner must support ONT outer barcode plus PacBio inner asymmetric barcode workflows with optional M13 and primer evidence.
7. The system must remain reproducible and explainable from stored metadata.

## User Experience

### Drawer Placement

Add a new bottom-drawer tab:

- `Structure Demux`

This tab is separate from:

- `Samples`
- `Demux Setup`
- `Barcode Kits`
- `Primer Trim`

### Structure Demux Tab Layout

Top section:

- Structure name
- Outer kit popup
- Expected outer barcode IDs
- Outer barcode requirement popup
  - `At least one end`
  - `Both ends`
- Inner kit popup
- Expected inner barcode pairs table or multiline field
- Optional M13 support checkbox
- Forward primer list
- Reverse primer list
- Sample size field for preview
- `Preview Sample` button
- `Adopt Suggested Plan` button

Bottom section:

- Preview / evidence pane in the drawer
- Plain-text or attributed summary in v1
- Must include:
  - reads sampled
  - reads with outer barcode on at least one end
  - reads with outer barcode on both ends
  - reads matching expected inner pairs
  - top observed expected pairs
  - representative architecture examples
  - notes when observed structure differs from the declared structure

### Operation Flow

When the user selects `Demultiplex (Barcodes)` from FASTQ operations:

- if a manual `Demux Setup` plan exists, use it
- else if a structure-aware configuration exists, compile it into a `DemultiplexPlan` and use that
- else show the existing drawer configuration guidance

This preserves backward compatibility and allows progressive migration.

## Data Model

Add a new persisted model in `LungfishIO`.

### FASTQStructureDemuxConfiguration

Fields:

- `name: String`
- `outerBarcodeKitID: String?`
- `outerBarcodeIDs: [String]`
- `outerBarcodeRequirement: FASTQStructureOuterBarcodeRequirement`
- `innerBarcodeKitID: String?`
- `expectedInnerPairs: [FASTQSampleBarcodeAssignment]`
- `includeM13Evidence: Bool`
- `forwardPrimerSequences: [String]`
- `reversePrimerSequences: [String]`
- `previewReadLimit: Int`
- `endSearchWindow: Int`

### FASTQStructureOuterBarcodeRequirement

Cases:

- `oneEnd`
- `bothEnds`

### FASTQStructurePreviewResult

Fields:

- `readsSampled: Int`
- `outerBarcodeOneEndCount: Int`
- `outerBarcodeBothEndsCount: Int`
- `expectedInnerPairCount: Int`
- `ambiguousInnerPairCount: Int`
- `observedPairs: [FASTQStructureObservedPair]`
- `exampleStructures: [String]`
- `notes: [String]`

### FASTQStructureObservedPair

Fields:

- `pairID: String`
- `readCount: Int`
- `m13SupportedCount: Int`
- `primerSupportedCount: Int`

### Metadata Persistence

Extend `FASTQDemultiplexMetadata` with:

- `structureDemuxConfigJSON: String?`

This allows persistence without creating an app/workflow module cycle.

## Deterministic Evidence Scanner

The preview scanner operates on sampled reads and uses exact-or-near-exact motif finding rather than cutadapt execution.

The scanner must:

1. Resolve outer barcode sequences from the selected outer kit and barcode IDs.
2. Resolve inner forward/reverse barcode sequences from the selected inner kit and expected pair assignments.
3. Search sampled reads for:
   - outer barcode or reverse-complement outer barcode near read ends
   - forward inner barcode sequence
   - reverse inner barcode reverse complement
   - optional M13F and M13R_RC
   - optional forward primers
   - optional reverse primer reverse complements
4. Summarize evidence in biologically meaningful order.

The scanner is not the final demultiplexer. It is an evidence and planning aid.

## Planner

Create a planner in `LungfishWorkflow` that compiles `FASTQStructureDemuxConfiguration` into a normal `DemultiplexPlan`.

### Initial Supported Strategy

For ONT outer + PacBio inner libraries:

Step 0:

- outer ONT kit
- selected outer barcode IDs only
- `symmetryMode = .singleEnd` if outer requirement is `oneEnd`
- `symmetryMode = .symmetric` if outer requirement is `bothEnds`
- `barcodeLocation = .bothEnds`
- `trimBarcodes = true`
- `searchReverseComplement = true`

Step 1:

- inner PacBio kit
- `symmetryMode = .asymmetric`
- `barcodeLocation = .bothEnds`
- `sampleAssignments = expectedInnerPairs`
- `trimBarcodes = true`
- `searchReverseComplement = true`

### Planned Later Extensions

- optional partial-assignment bins
- confidence tiers: full / strong partial / weak partial / ambiguous
- optional M13-aware trimming/tracking
- motif-based rescue of inner barcode assignments

## Evidence Interpretation Rules

For v1, the preview scanner should classify evidence conservatively:

- `outer one end`: outer barcode found near either terminus
- `outer both ends`: outer barcode found near both termini
- `expected pair hit`: exactly one expected pair has both forward and reverse inner barcode evidence in the same read
- `M13-supported`: pair hit plus adjacent M13 evidence on at least one side
- `primer-supported`: pair hit plus one configured primer on at least one side
- `ambiguous`: more than one expected pair fits the read

## AI Integration

The app’s AI layer should not perform barcode assignment directly in v1.

Instead, the structure-aware feature provides a stable deterministic substrate that AI can use later for:

- converting user natural-language descriptions into a structure-aware configuration
- explaining why certain reads were assigned or rejected
- proposing relaxed or stricter demux strategies from preview evidence

Future AI workflows may generate `FASTQStructureDemuxConfiguration`, but the stored artifact remains the deterministic configuration JSON.

## Implementation Plan

### Phase 1

- Add structure-aware config model in `LungfishIO`
- Persist config in FASTQ metadata
- Add workflow planner and sampled preview scanner in `LungfishWorkflow`
- Add `Structure Demux` tab in the bottom drawer
- Add preview pane and buttons
- Allow `Demultiplex (Barcodes)` to compile and run the structure-aware plan automatically when no manual plan exists

### Phase 2

- Add confidence scoring and ambiguity summaries
- Add partial-assignment policy controls
- Add per-read evidence export
- Add richer preview rendering in the drawer

### Phase 3

- Add AI-assisted configuration generation from natural-language library descriptions
- Add optional ML rescue/anomaly analysis for ambiguous reads

## Test Plan

Add targeted tests for:

1. Config codable roundtrip
2. Planner compilation for:
   - outer one-end
   - outer both-ends
   - inner asymmetric pair assignments
3. Preview scanner on synthetic reads:
   - full structure
   - one-ended outer barcode
   - missing M13
   - ambiguous inner barcode pair
4. Drawer metadata persistence roundtrip
5. FASTQ operation request path uses compiled structure-aware plan when no explicit manual plan exists

## Risks

- The preview scanner is approximate and may undercount noisy barcode evidence compared with cutadapt.
- Users may expect the preview to exactly equal final demux counts. The UI must describe it as a sampled planning preview.
- Existing kit-centric demux must remain available and must take precedence when explicitly configured.

## Success Criteria

- Users can declare a real read architecture in the drawer.
- The drawer preview explains what is actually present in sampled reads.
- A compiled cutadapt plan can be run without manually recreating the structure as individual demux steps.
- Metadata persists cleanly and survives compaction, reopen, and re-run.
