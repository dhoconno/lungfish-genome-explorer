# Bundle Alignment BAM Filtering Design

Date: 2026-04-22
Status: Draft for review

## Summary

Lungfish should support BAM filtering as a general bundle-alignment feature, not as a mapping-only special case. The right entry point is the Inspector sidebar for loaded alignment tracks. Users will choose a source alignment track, select BAM filters, and create a new sibling alignment track in the same `.lungfishref` bundle under `alignments/filtered/`.

This design uses one shared filtering engine for both imported BAM tracks and BAMs produced by managed mapping analyses, because managed mapping results already import their BAM into a reference bundle for integrated viewing. The source BAM remains unchanged. Each filtered output is a new derived BAM with explicit provenance describing the original source BAM, any duplicate preprocessing, the exact filters applied, and pre/post read counts.

## Goals

- Support BAM filtering for any alignment track associated with a loaded reference bundle.
- Use the Inspector sidebar as the primary user entry point.
- Create filtered BAMs as sibling alignment tracks in the same bundle.
- Reuse one shared execution engine for imported BAM tracks and managed mapping result BAMs.
- Support active duplicate removal when requested, not just passive filtering of already marked duplicate reads.
- Preserve clear provenance for every derived BAM.
- Validate required tags and surface clear errors when a requested filter cannot be computed safely.
- Leave the original BAM and original alignment track unchanged.

## Non-Goals

- Do not support loose external BAM files that are not attached to a bundle.
- Do not overwrite or mutate the source alignment track in place.
- Do not silently run duplicate marking for ordinary BAM filtering unless the user explicitly requested duplicate removal.
- Do not merge BAM filtering into viewer-only read display controls.
- Do not implement every possible `samtools view` expression in the first pass.
- Do not export filtered BAMs to new bundles or external files as part of the initial derivation workflow, beyond defining how later export should fit.

## Current State

### Alignment Tracks Are Bundle-Centric

Lungfish does not treat BAM files as a standalone document type. BAM/CRAM/SAM files are imported into existing `.lungfishref` bundles and represented as `AlignmentTrackInfo` entries in the bundle manifest. Imported alignments are normalized into bundle storage, indexed, and accompanied by an `AlignmentMetadataDatabase`.

This means the natural abstraction for BAM filtering is an alignment-track workflow, not a file-open workflow.

### Managed Mapping Already Produces Normalized BAMs

Managed mapping runs already perform a normalization sequence that is close to the desired filtering pipeline:

- raw mapper output
- `samtools view` for basic normalization filters
- `samtools sort`
- `samtools index`
- `samtools flagstat`

That path already records mapping provenance separately for analysis bundles.

### Duplicate Workflows Already Re-Import Derived BAMs

The existing duplicate workflows already establish the correct app-level pattern for BAM derivation:

- resolve source bundle alignment tracks
- run a BAM-rewriting workflow
- import the rewritten BAM back into the bundle as a new alignment track

The BAM filtering feature should follow the same pattern rather than introducing a separate storage model.

### Inspector Already Owns Alignment Actions

The Inspector’s alignment section already exposes BAM-oriented controls and actions such as duplicate workflows and variant calling. Adding BAM filtering there matches the current app structure and avoids a new operations surface.

## Product Decisions

### 1. Bundle Alignment Filtering Is a General Feature

The feature scope is:

- any alignment track in a loaded `.lungfishref` bundle
- including imported BAM tracks
- including BAMs imported into copied mapping viewer bundles for managed mapping analyses

The feature scope is not:

- arbitrary external BAM files with no bundle context

This keeps one coherent model across the app.

### 2. The Inspector Is the Primary Entry Point

Add a new Inspector subsection within the existing alignment/read area for bundle alignment filtering.

The UI should:

- show the selected source alignment track
- allow source-track selection when multiple alignment tracks exist
- expose filter controls
- allow the user to name the output track
- run the derivation workflow from the Inspector

This section must be clearly distinct from viewer-only display filters such as temporary MAPQ visibility toggles.

### 3. Filtered BAMs Become Sibling Alignment Tracks

Running BAM filtering creates a new derived alignment track in the same bundle.

Approved behavior:

- source BAM remains unchanged
- output BAM is stored in `alignments/filtered/`
- output track is added to the bundle manifest as a normal `AlignmentTrackInfo`
- output track gets its own metadata DB and provenance history

This makes filtered BAMs first-class bundle assets that work everywhere existing alignment tracks work.

### 4. Duplicate Removal Is an Explicit Preprocessing Mode

Duplicate behavior must be split into two user-facing options with different semantics:

- `Exclude duplicate-marked reads`
  - simple filter using existing duplicate flags
- `Remove duplicates`
  - active preprocessing step that runs duplicate marking before filtering

If the user requests `Remove duplicates`, Lungfish should run the duplicate-marking pipeline first, then exclude the reads marked as duplicate from the final derived BAM.

This is intentionally more expensive than a plain `samtools view -F 0x400` filter, but it gives the user a reproducible and self-contained result instead of depending on whatever the source BAM happened to contain.

### 5. One Shared Derivation Engine Should Power the Workflow

Create a shared alignment-filter service that accepts:

- source alignment track information
- bundle URL
- selected filter configuration
- output track name

Core execution flow:

1. Resolve source BAM and index.
2. Preflight requested filters.
3. Optionally run duplicate preprocessing.
4. Run `samtools view` with flags, MAPQ thresholds, optional region constraints, and optional expression filters.
5. Sort and index the resulting BAM.
6. Import the result back into the bundle as a new alignment track.
7. Record structured derivation provenance.

Managed mapping workflows should reuse this service when they need to generate derived BAMs post hoc.

### 6. The Source BAM Is Immutable

Filtering always produces a new output track.

Approved behavior:

- no in-place rewrite of bundle alignment tracks
- no mutation of source metadata DBs
- no mutation of source `AlignmentTrackInfo`
- derivation provenance always points back to the source track and source BAM

This preserves auditability and avoids breaking downstream tools that reference the original track.

## Filter Catalog

### V1 Filters

The first implementation should support:

- `Mapped reads only`
  - `samtools view -F 0x4`
- `Primary alignments only`
  - `samtools view -F 0x900`
- `Minimum MAPQ`
  - `samtools view -q <value>`
- `Proper pairs only`
  - `samtools view -f 0x2`
- `Both mates mapped`
  - `samtools view -f 0x1 -F 0xC`
- `Exclude duplicate-marked reads`
  - `samtools view -F 0x400`
- `Remove duplicates`
  - duplicate-marking preprocessing plus duplicate exclusion
- `Exact matches only`
  - expression filter requiring `NM == 0`
- `Minimum percent identity`
  - expression filter based on `NM` and aligned query length
- optional contig or region subset
  - positional arguments or interval input

These filters cover the immediate use cases discussed in design review while leaving room for expansion.

### Deferred Filters

The following are good follow-ups but not required for the first pass:

- read-name allowlist or blocklist
- read group or library subset
- arbitrary tag-value subset
- minimum aligned query length
- more advanced expression composition UI

## Identity and Exact-Match Semantics

### Exact Match

For the first implementation, `Exact matches only` means:

- the read has an `NM` tag
- `NM == 0`

This is an edit-distance-based exact-match definition over the aligned portion of the read. It is acceptable for v1 because it matches existing Lungfish assumptions around `NM`-based identity metrics and is easy to explain.

### Percent Identity

For the first implementation, percent identity should mirror the current mapping summary logic:

- aligned query bases minus edit distance
- divided by aligned query bases

This is an `NM`-based proxy rather than a fresh reference-aware recalculation. The UI and provenance should describe it as identity estimated from alignment tags, not as an independent realignment.

### Required Tag Validation

If the user requests `Exact matches only` or `Minimum percent identity`, Lungfish must verify that the BAM contains the required `NM` tags.

If required tags are missing:

- the workflow must fail preflight before generating output
- the error must state which filter could not be computed
- the error must explain that the source BAM lacks required alignment tags

The feature must not silently skip those filters or emit a misleading derived BAM.

## Provenance

Each derived BAM needs explicit derivation provenance beyond the generic import record.

### Track-Level Provenance Requirements

Each filtered BAM should record:

- source bundle path
- source alignment track ID
- source alignment track name
- source BAM path
- derived BAM path
- whether duplicate preprocessing ran
- exact filter settings
- command chain in execution order
- pre-filter read counts
- post-filter read counts
- warnings or validation notes
- derivation timestamp

### Storage

Use two complementary layers:

- a structured filtered-track derivation sidecar stored alongside the derived BAM or metadata DB
- mirrored provenance entries and summary fields in the `AlignmentMetadataDatabase`

The structured sidecar gives stable machine-readable derivation semantics. The metadata DB integration ensures provenance is visible through existing Inspector surfaces.

### Inspector Presentation

The Inspector should clearly identify a derived track as derived and show, at minimum:

- source track
- key filter summary
- whether duplicate removal preprocessing ran
- pre/post counts
- command history

The goal is that a biologist can answer:

- what BAM did this come from
- what did Lungfish do to it
- how many reads were retained

## UI Design

### Inspector Controls

The new Inspector subsection should include:

- source alignment track picker when multiple tracks exist
- output track name
- toggles or controls for the v1 filters
- action button to create the filtered BAM track

Plain-language labels should be preferred over SAM jargon in the primary controls.

Examples:

- `Mapped reads only`
- `Primary alignments only`
- `Both mates mapped`
- `Remove duplicates`
- `Exact matches only`
- `Minimum percent identity`

Technical details such as exact flags or expression syntax belong in provenance and help text, not the main control labels.

### Validation UX

Disable or block invalid filter combinations when possible.

Examples:

- pair-based filters should be unavailable for non-paired tracks
- identity-based filters should fail fast when required tags are absent
- duplicate removal should report clear preconditions if the input cannot support the required preprocessing path

### Naming

Default output names should be descriptive and plain.

Examples:

- `Sample 1 [filtered mapped-only]`
- `Sample 1 [filtered exact-match]`
- `Sample 1 [deduplicated filtered]`

The actual naming algorithm can be finalized during implementation planning, but the name must communicate that the track is derived.

## Export Model

The initial workflow creates sibling alignment tracks inside the same bundle.

Follow-on export actions should build on those derived tracks:

- `Export Filtered Track as Bundle`
- `Export Filtered BAM + Reference`

These export actions are intentionally separate from derivation. The derivation workflow should finish with a new track in the bundle; users can then export that filtered track if needed.

## Implementation Notes

### Relationship to Existing Duplicate Workflows

The existing duplicate workflows remain valid and should not be replaced by this feature.

They solve different problems:

- duplicate workflows operate at the bundle level across tracks
- BAM filtering derives a new track from one chosen source track

The BAM filtering engine may reuse internal duplicate-marking steps, but it should remain a separate user-facing workflow.

### Relationship to Mapping Analyses

Mapping-result BAMs should not keep a separate bespoke BAM filtering implementation.

Instead:

- if a mapping result has a viewer bundle with imported alignment tracks, BAM filtering should operate through the same bundle alignment workflow
- mapping-analysis provenance remains analysis-specific
- derived BAM provenance remains track-specific

This avoids parallel implementations for imported BAMs versus mapping BAMs.

## Testing

### Unit and Service Tests

Add service coverage for:

- command construction for each v1 filter
- duplicate preprocessing invocation when requested
- no duplicate preprocessing when not requested
- preflight failure when `NM` is required but missing
- successful import of derived BAM as a new track
- provenance sidecar generation

### Bundle Integration Tests

Add bundle-level tests for:

- one source alignment track producing one new sibling filtered track
- manifest update correctness
- metadata DB regeneration for the derived track
- provenance visibility through existing Inspector-facing data loaders

### UI Tests

Add UI coverage for:

- Inspector subsection visibility when alignment tracks exist
- source-track selection
- running a simple mapped-only derivation
- showing an error when an `NM`-dependent filter is requested on a BAM without `NM`

## Risks and Tradeoffs

- Active duplicate removal can be expensive on large BAMs. That is acceptable because it matches the requested semantics and will be clearly represented as preprocessing in provenance.
- `NM`-based identity is an approximation, not a full recomputation against the reference. The UI must avoid overstating what the identity filter means.
- If users confuse viewer display filters with BAM derivation filters, they may misinterpret whether a BAM was actually rewritten. The Inspector must keep those surfaces visually distinct.
- Adding too many filters in the first pass could make the Inspector harder to scan. V1 should stay focused on the agreed high-value set.

## Recommendation

Implement BAM filtering as a shared bundle alignment-track derivation workflow launched from the Inspector.

The first implementation should:

1. Create a shared alignment-filter service.
2. Add an Inspector subsection for alignment-track filtering.
3. Emit sibling derived alignment tracks inside the same bundle.
4. Support the agreed v1 filter catalog.
5. Treat `Remove duplicates` as active duplicate preprocessing.
6. Record explicit derivation provenance for every filtered BAM.

This gives Lungfish one coherent BAM filtering model for imported alignments and mapping-derived alignments while preserving provenance, auditability, and future export flexibility.
