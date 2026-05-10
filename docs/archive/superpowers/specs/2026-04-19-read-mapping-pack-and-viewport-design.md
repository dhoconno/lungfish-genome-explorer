# Read Mapping Pack And Viewport Design

Date: 2026-04-19
Status: Proposed

## Summary

Introduce a dedicated `read-mapping` micromamba plugin pack for reference-guided read mapping workflows, with a first release focused on three optional managed mappers:

- `minimap2`
- `bwa-mem2`
- `bowtie2`

`BBMap` should also appear as a first-class mapper in the read-mapping dialog, but it should not be duplicated in the optional pack. Instead, it should be surfaced from the required BBTools setup that Lungfish already installs. The required setup metadata should be expanded to register:

- `bbmap.sh`
- `mapPacBio.sh`

The product surface should stop treating this BAM-oriented workflow as a generic "alignment results" class and instead formalize it as a `Mapping` result family. The mapping result viewer should be a split experience:

- a sortable list of mapped reference contigs with per-contig summary metrics
- a detail pane that goes straight into BAM/reference inspection with annotations

This keeps reference-guided read mapping separate from future pairwise or multiple-sequence alignment viewports, which will need a different interaction model.

## Goals

- Ship a dedicated optional read-mapping plugin pack backed by micromamba-managed environments.
- Keep the optional pack focused on the approved v1 tools:
  - `minimap2`
  - `bwa-mem2`
  - `bowtie2`
- Surface `BBMap` as a first-class mapper in the dialog by exposing additional BBTools executables from required setup, not by duplicating the package in the optional pack.
- Replace the current minimap2-specific mapping surface with a shared mapping configuration experience that follows the same launcher style as the assembly and database-search dialogs.
- Rename the current BAM-oriented result family from `Alignment` to `Mapping`.
- Normalize mapper outputs into a shared `MappingResult` model rather than keeping the viewport coupled to `Minimap2Result`.
- Show a per-contig mapping summary list with the agreed v1 columns:
  - `Contig`
  - `Length`
  - `Mapped Reads`
  - `% Mapped`
  - `Mean Depth`
  - `Coverage Breadth`
  - `Median MAPQ`
  - `Mean Identity`
- Make the detail pane go straight into the BAM/reference viewer with annotation tracks for the selected reference sequence.
- Enforce mapper compatibility rules before launch, including BBMap length-based constraints.
- Establish a clean foundation for later mapper additions without pretending that pairwise or MSA outputs belong in the same viewport.

## Non-Goals

- Do not create a broad generic `alignment` pack in this rollout.
- Do not add `BBMap` to the optional read-mapping micromamba pack.
- Do not add RNA-first or splice-aware aligners such as `HISAT2` or `STAR` in v1.
- Do not add specialized long-read mappers such as `Winnowmap`, `NGMLR`, or `pbmm2` in v1.
- Do not collapse reference-guided mapping and future pairwise or multiple-sequence alignment outputs into a single viewport family.
- Do not introduce a separate top-level `mapPacBio` tool in the dialog.
- Do not add a summary header above the detail viewer once a contig is selected.

## Current State

The repository already contains the early pieces of this workflow, but they are still minimap2-shaped and naming-wise too broad:

- The optional `alignment` pack currently groups `bwa-mem2`, `minimap2`, `bowtie2`, and `hisat2`.
- The FASTQ operations dialog exposes only `minimap2` under the `MAPPING` category.
- `MapReadsWizardSheet` is a minimap2-specific mapping UI.
- `Minimap2Pipeline` and `Minimap2Result` already exist for BAM-oriented mapping runs.
- `AlignmentResultViewController` is explicitly BAM-oriented but still named as a generic alignment result surface and still uses `Minimap2Result` directly.
- Required setup already installs BBTools from the `bbmap` package, but it does not currently register `bbmap.sh` or `mapPacBio.sh` as exposed executables.

This means the work is not greenfield. The main change is to convert read mapping from a one-tool path with minimap2-specific naming into a shared mapping surface with a clean result abstraction.

## Tool Selection

### Optional Read-Mapping Pack

The new v1 optional read-mapping pack should contain:

- `minimap2`
- `bwa-mem2`
- `bowtie2`

### Included Through Required Setup

The dialog should also expose:

- `BBMap`

`BBMap` should come from the existing required BBTools setup, not the optional pack.

### BBTools Exposure Changes

The required setup metadata for the BBTools environment should be expanded to register:

- `bbmap.sh`
- `mapPacBio.sh`

These executables should resolve through the same managed `bbtools` environment already used for the other BBTools scripts.

### Selection Rationale

- `minimap2` remains the broadest general-purpose mapper and should stay the most capable long-read-aware option in v1.
- `bwa-mem2` is the clearest short-read DNA/amplicon mapper for users who expect a BWA-family workflow.
- `bowtie2` remains useful for short-read and legacy DNA workflows with a familiar index-and-map model.
- `BBMap` belongs in the visible tool set because users expect it in reference-guided mapping workflows and it is already present through required setup.
- Keeping `BBMap` out of the optional pack avoids duplicate packaging of the same BBTools bundle.

### Explicit Deferrals

- `HISAT2` is deferred because it pushes the dialog toward RNA- and splice-aware controls that do not fit the intended v1 surface.
- `STAR` is deferred for the same reason.
- `Winnowmap`, `NGMLR`, and `pbmm2` are deferred because they are more specialized than the current v1 scope requires.

## Naming Boundary

### Result Family Naming

The current BAM-oriented result family should be renamed from `Alignment` to `Mapping`.

Recommended naming direction:

- `MappingResult`
- `MappingResultViewController`
- `MappingRunRequest`

### Why Not Keep "Alignment"

The current viewport is specifically about reference-guided read mappings that end in sorted/indexed BAM files and are inspected through a reference-coordinate viewer. That is a different product concept than future sequence-to-sequence or multiple-sequence alignments.

### Future Boundary

Future tools such as MAFFT or other pairwise/MSA-oriented aligners should use a separate result family, for example:

- `PairwiseAlignmentResult`
- `SequenceAlignmentResult`

Those tools should not be routed through the mapping viewport, even if some rendering components are eventually reused.

## User-Facing Model

### Dialog Shell

The mapping dialog should reuse the same `DatasetOperationsDialog` shell used by the assembly and database-search flows:

- tool list in the left sidebar
- mapper-specific configuration in the right pane
- readiness and action footer across the bottom

### Sidebar Tools

The v1 sidebar should expose four first-class mapper entries:

- `Minimap2`
- `BWA-MEM2`
- `Bowtie2`
- `BBMap`

### BBMap Tool Model

`BBMap` should be the top-level tool. `mapPacBio.sh` should not appear as its own sidebar entry.

Instead, the `BBMap` pane should expose a mode or profile control with at least:

- `Standard`
- `PacBio`

Selecting `PacBio` should route execution through `mapPacBio.sh`.

### Shared Pane Shape

The mapping dialog should follow the same general section rhythm already established elsewhere:

1. `Inputs`
2. `Primary Settings`
3. `Advanced Settings`
4. `Output`
5. `Readiness`

### Primary Controls

The primary mapping controls should include:

- `Mapper`
- `Reference`
- `Mapper Mode` or `Preset`
- `Threads`
- `Sample Name` or output label
- `Output Location`

Where concepts overlap, labels should be harmonized across tools. Tool-specific controls should appear only when relevant.

## Execution Model

### Shared Request Contract

The dialog should normalize mapper-specific settings into a shared `MappingRunRequest` before launch.

That request should carry:

- mapper identity
- mapper mode or preset
- input FASTQ paths
- reference identity and path
- common output configuration
- tool-specific advanced arguments where needed

### Pipeline Output Contract

Every mapper should normalize into a shared `MappingResult`.

That result should include:

- mapper id
- mapper mode or preset
- reference identity
- BAM path
- BAI path
- analysis output directory
- run-level summary metrics
- per-contig summary rows

### Canonical Storage And Display Format

Regardless of what a mapper emits initially, Lungfish should post-process the output into a canonical storage and display format:

- coordinate-sorted BAM
- BAM index (`.bai`)

This should be true whether the mapper's first output is:

- SAM
- unsorted BAM
- already-sorted BAM

The viewport and persisted analysis bundle should treat sorted, indexed BAM as the standard representation for mapping results.

### Standard Run Flow

The run flow should be:

1. user selects a mapper
2. user selects a reference and mapper settings
3. pipeline runs the mapper
4. pipeline converts mapper output into sorted, indexed BAM
5. pipeline computes contig-level summary metrics
6. pipeline writes a standardized mapping sidecar or bundle
7. opening the result routes into the `Mapping` viewport

Sorting and indexing should not be optional in the product flow. Indexed BAM is required because the viewport needs efficient random access for navigating between contigs and rendering different regions of the selected mapping without re-reading the entire alignment file.

## Compatibility Model

### Compatibility Is Blocking, Not Advisory

Known-invalid mapper and input combinations should be blocked before launch. The dialog should show explicit readiness text and should not allow "run anyway" for combinations the product has already decided are unsupported.

### Shared Compatibility Layer

Compatibility rules should live in a shared `MappingCompatibility` model rather than being scattered through each mapper pane.

This layer should evaluate:

- detected read class
- observed or sampled read length
- selected mapper
- selected mapper mode or preset

The dialog should use the shared evaluation to determine:

- whether the selected mapper can run
- whether the current mapper mode is valid
- what blocking or warning text to show

### Read-Class Rules

- `Minimap2`
  - allow `Illumina short reads`
  - allow `ONT reads`
  - allow `PacBio HiFi`
  - allow `PacBio CLR`
- `BWA-MEM2`
  - allow short-read DNA-style inputs only
  - block long-read classes
- `Bowtie2`
  - allow short-read DNA-style inputs only
  - block long-read classes
- `BBMap`
  - behavior depends on selected mode and read length constraints

### BBMap Length Rules

The BBMap rules should be exact and should be enforced against the selected mode.

#### Standard BBMap Mode

- route through `bbmap.sh`
- use FASTQ-oriented `maxlen` semantics for FASTQ input
- maximum supported read length is `500`

If sampled or detected reads exceed `500`, standard BBMap mode is blocked.

#### BBMap PacBio Mode

- route through `mapPacBio.sh`
- maximum supported read length is `6000`

If sampled or detected reads exceed `6000`, PacBio mode is also blocked.

### Expected UI Behavior

- if reads are `<= 500`, standard `BBMap` mode can run
- if reads are `> 500` and `<= 6000`, standard `BBMap` mode is blocked and the user must switch to `PacBio`
- if reads are `> 6000`, both BBMap modes are blocked and the user must choose a different mapper

### Status Messaging

The compatibility layer should provide clear blocking messages, for example:

- `BWA-MEM2 is only available for short-read mapping in v1.`
- `Bowtie2 is only available for short-read mapping in v1.`
- `Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.`
- `BBMap PacBio mode supports reads up to 6000 bases. Choose another mapper for longer reads.`

## Result Model

### Shared Mapping Result

`MappingResult` should replace mapper-specific viewport coupling.

At minimum it should capture:

- mapper id
- mapper mode or preset
- reference path or bundle identity
- BAM path
- BAI path
- total reads
- mapped reads
- unmapped reads
- wall-clock runtime
- per-contig summary rows

The BAM and BAI recorded in `MappingResult` should always point to the post-processed canonical sorted/indexed BAM artifacts, not raw mapper output.

### Per-Contig Summary Rows

Each contig row should include:

- `contigName`
- `contigLength`
- `mappedReads`
- `percentMapped`
- `meanDepth`
- `coverageBreadth`
- `medianMAPQ`
- `meanIdentity`

### Mean Identity Definition

The `Mean Identity` column should be a weighted aligned identity metric against the selected reference contig rather than a naive per-read average. This keeps the number comparable across mapper families and reduces distortion from very short reads or clipped alignments.

## Mapping Viewport

### High-Level Structure

The mapping result viewer should become a true list/detail split view:

- list pane for per-contig mapping summaries
- detail pane for direct BAM/reference inspection

### List Pane

The list pane should be sortable and display the approved v1 columns:

- `Contig`
- `Length`
- `Mapped Reads`
- `% Mapped`
- `Mean Depth`
- `Coverage Breadth`
- `Median MAPQ`
- `Mean Identity`

### Detail Pane

Selecting a contig should drive the detail pane directly into the existing BAM/reference viewer:

- focused on the selected contig
- using the canonical sorted, indexed BAM from the mapping result
- showing annotation tracks from the reference sequence

There should be no extra summary header above the detail viewer. The list already carries the summary metrics, and the detail pane should prioritize direct inspection.

### Controller Direction

The current `AlignmentResultViewController` should be renamed and evolved into a `MappingResultViewController` that owns:

- the contig summary list
- the embedded BAM/reference viewer
- selection synchronization between the two

## Architecture Notes

### Required Setup Integration

The BBTools environment already exists as a required managed dependency. This rollout should extend its exposed executable set rather than creating a new environment or duplicate package entry.

### Optional Pack Boundary

The new read-mapping pack should be narrowly scoped to tools that truly need optional installation and fit the shared reference-guided mapping surface:

- `minimap2`
- `bwa-mem2`
- `bowtie2`

### Viewport Boundary

The mapping viewport should remain specialized for BAM/reference mapping work. Future pairwise or multiple-sequence alignment tools should receive their own result families and UI surfaces.

## Open Questions

There are no unresolved product-scope questions remaining from the current design discussion. The next step after spec review is to write the implementation plan and then execute the work in the isolated worktree.
