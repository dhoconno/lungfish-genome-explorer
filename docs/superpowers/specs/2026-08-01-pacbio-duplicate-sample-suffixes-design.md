# PacBio Demultiplex Duplicate Sample Suffixes

## Problem

The ONT PacBio barcode demultiplexer accepts more than one barcode-pair row
with the same `sample_id`, but its output materializer later assumes sample
names are unique. A sheet with repeated sample names therefore completes the
expensive read scan and then terminates while constructing the output lookup.

Duplicate rows are legitimate independent samples for this workflow. Lungfish
must preserve every row and give each one a unique, deterministic output name.

## Naming behavior

Lungfish will resolve output names immediately after parsing the barcode sheet
and before inspecting or processing FASTQ reads.

- A sample name that occurs once keeps its filesystem-safe name without a
  suffix.
- Every member of a duplicate group is numbered in source-row order, beginning
  with `_1`. For example, two `LN94_Mamu-E` rows become
  `LN94_Mamu-E_1` and `LN94_Mamu-E_2`.
- Grouping occurs after the existing filesystem-safe normalization and is
  case-insensitive, matching the behavior required by common macOS volumes.
- Numbering is based on all barcode-sheet rows, including a row that ultimately
  receives no reads. This keeps names stable across reruns and input datasets.
- The resolved names must be globally unique. If a generated name conflicts
  with another explicit normalized name—for example, duplicate `Sample` rows
  alongside an explicit `Sample_1` row—the command stops during preflight with
  a clear error listing the conflicting rows. Lungfish will not invent nested
  or order-dependent suffixes for this ambiguous case.

## Data flow

The materializer will create an ordered resolved-assignment model containing:

- source row number;
- original `sample_id`;
- resolved output sample ID;
- forward barcode ID; and
- reverse barcode ID.

The resolved output ID is passed into the exact demultiplexer as its sample
name. As a result, the matching engine, its result collection, bundle builders,
FASTQ filenames, derived-bundle manifests, and aggregate manifest all use the
same unique identifier. This removes the late duplicate-key failure rather than
working around it during publication.

The original and resolved names, source row, and barcode pair will be written
to the aggregate demultiplex manifest. Per-bundle provenance notes will state
the original sample ID and the barcode pair that produced the bundle. Existing
CLI provenance continues to record the exact command, resolved options, input
and output paths, file checksums and sizes, runtime identity, status, and wall
time.

## Error handling

Malformed barcode IDs, missing columns, empty sample names, and ambiguous
resolved-name collisions remain preflight errors. They must be reported before
the output directory is created or any FASTQ record is processed. Errors must
name the barcode-sheet rows and sample IDs involved.

No raw Swift duplicate-key trap may remain reachable from repeated sample rows.
The manifest construction will consume already-unique resolved names and retain
defensive validation with a normal, user-readable error.

## Testing

Tests will establish the following behavior before production code changes:

1. A unique sample retains its unsuffixed normalized name.
2. Two and three identical names receive `_1`, `_2`, and `_3` in sheet order.
3. Names that collide only after normalization or case folding are numbered.
4. Numbering is derived from all input rows, not only rows receiving reads.
5. A generated suffix that collides with an explicit sample name fails during
   preflight and does not create the output directory.
6. A small end-to-end run with two barcode pairs sharing one original name
   creates two bundles containing the correct reads.
7. The aggregate manifest records original-to-resolved mappings and barcode
   row details, and each bundle preserves its source identity in provenance.
8. Existing single-occurrence sample sheets retain their current names and
   outputs.

Focused materializer, exact-demultiplex, CLI, and provenance tests will be run,
followed by the relevant workflow regression suite.

## Out of scope

- Merging reads from repeated sample names into one bundle.
- Changing exact barcode matching, minimum insert length, or first-match rules.
- Renaming already-created bundles.
- Adding a user-configurable suffix format.
