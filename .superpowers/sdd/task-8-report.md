# Task 8 Report: Native Matrix Review Export

## Scope

Implemented exact viewport projection identity and raw OOXML export semantics for
matrix reviews and scoped comments.

## TDD Evidence

- Initial focused build failed because `GenotypeViewProjectionRow` and
  `GenotypeViewportExportRow` did not expose `stableClusterID`.
- After the first implementation pass, the OOXML acceptance test failed because
  comment-order assertions inspected separate note objects instead of the
  combined target note; the assertion was corrected to inspect `D2`.
- A later RED case proved legacy `"-"` absence values were being emitted for a
  false-negative cell. The writer now treats `"-"` as absent for Excel only and
  emits an empty bordered cell. CSV/TSV values remain unchanged.
- Provenance RED coverage showed the replay argv omitted `--force`; the recorded
  command now includes it when resolved true.
- The failed-overwrite RED regression showed all three prior generation files
  were deleted after provenance verification failed; rollback snapshots now
  restore them byte-for-byte.
- The invalid-import audit RED regression showed only pre-existing mutation
  audit entries were exported; review validation rows are now synthesized for
  every review record.
- The order-independent duplicate-review RED regression showed last-write-wins
  target validation could format a cell while misreporting one of its records;
  duplicate exact targets now conflict and fail closed.

## Implementation

- Added optional stable cluster identity to projection and viewport-export rows,
  including legacy JSON decoding, filtering, GUI snapshot serialization, and a
  visible XLSX identity column.
- Added exact locus/genotype/sample/stable-ID matching. Ambiguous or incomplete
  identities fail closed.
- Applied valid false positives as bracketed read counts with italic `#767676`
  text while preserving the viewport fill.
- Applied valid false negatives with a four-sided thick border; explicit zero is
  retained and absent/`"-"` values become empty emitted cells.
- Added collision-safe invalid-review reporting in Matrix Annotations.
- Conflicting duplicate imported reviews for one exact target now fail closed
  in either record order: no semantic cell formatting is applied and every
  conflicting record is marked invalid in both semantic sheets.
- Added native comment XML, deterministic author lists, VML note shapes with
  zero-based anchors, worksheet relationships, `legacyDrawing`, and content
  types.
- Composed native data-cell notes in Allele Row, Sample Column, Cell order while
  also attaching row notes to labels and column notes to headers.
- Added projection Audit Log export for semantic sidecar audit entries.
- Added an explicit export-validation audit row for every matrix review, with
  exact target, disposition, validation status/reason, author, and timestamp;
  malformed imports therefore remain traceable even when their source sidecar
  lacks a matching mutation audit entry.
- Made raw XLSX publication atomic by zipping to a sibling temporary file before
  replacing the destination.
- Added GUI generation rollback snapshots so runner or provenance-verification
  failures restore any prior output, provenance, and durable projection trio
  byte-for-byte.
- Recorded `--force` in exact durable export provenance; output and stable input
  descriptors retain checksums and sizes.

## Full-Export Topology Decision

The full raw Matrix worksheet is sample-by-haplotype, not
genotype-by-sample. It does not carry an exact genotype observation row, so
genotype-cell reviews are not heuristically applied. They remain visible in
Matrix Annotations with status `unapplied` and an explicit topology reason.
Projection exports carry exact genotype observation identity and receive native
formatting and notes.

## Verification

- `swift test --skip-update --filter GenotypeExportSubcommandTests`
  - 13 tests passed, 0 failures.
- `swift test --skip-update --filter GenotypeViewportExcelExportTests`
  - 8 tests passed, 0 failures.
- `git diff --check`
  - passed with no output.

## Independent Review

The first review found two Important issues: failed GUI overwrites deleted the
prior export generation, and invalid imported reviews were not guaranteed to
appear in Audit Log. The follow-up found target-keyed validation could misreport
conflicting duplicate imports. All three received RED regressions, root-cause
fixes, and focused GREEN verification. Final follow-up review found no remaining
Critical or Important issues.
