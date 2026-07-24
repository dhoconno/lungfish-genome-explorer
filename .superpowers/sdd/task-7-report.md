# Task 7 Report: Current workbook semantic formatting and native notes

## Status

Implemented, independently reviewed, and verified.

## Delivered behavior

- Coordinates annotation writes and workbook publication through the same adjacent bundle lock. The workbook workflow reads one no-follow immutable sidecar byte snapshot, decodes only those bytes, stages those same bytes, and witness-checks the live sidecar before publication. A bypass writer causes a fail-closed update while preserving its exact annotation/provenance pair and the prior workbook.
- Publishes the immutable snapshot as the final stored `annotations.json` and records the final sidecar and final `current.xlsx` paths, checksums, sizes, and replay argv in provenance.
- Matches matrix rows by the workbook identity fields that are available: locus, genotype, sample, and stable cluster ID. Ambiguous or insufficient identities fail closed rather than formatting colliding rows.
- Validates imported reviews against raw workbook evidence:
  - false positive requires positive read support and writes bracketed text such as `[42]`, italic, with `#767676` font color;
  - false negative requires explicit zero or absent support and applies a thick border on all four sides without changing `0` or an empty value;
  - invalid or superseded reviews remain in `Matrix Annotations` and receive a semantic `validateMatrixReview` Audit Log row, but never format a cell.
- Stores reversible review-owned presentation metadata in a very-hidden managed worksheet. Every update restores prior FP/FN value, font, and border properties before validating current reviews; cleared or newly invalid reviews therefore cannot retain stale formatting. Cleanup restores managed properties independently, preserving unrelated manual font/border edits, and removes stale managed sheets and comments.
- Resolves the current matrix style/comment/review per exact target. Native notes preserve unrelated text and author, attach row comments to allele labels, column comments to sample headers, and compose intersection notes in `Allele Row` → `Sample Column` → `Cell` order with body, author, and timestamp.
- Adds stable identity, disposition, validation status, and validation reason columns to `Matrix Annotations`; extends Audit Log rows with semantic identity and validation fields.
- Preserves unrelated native cell comments and formatting by semantic identity across full-length MHC two-sheet rebuilds. Regenerated authoritative candidate fills win over stale prior fills, while unrelated font/comment styling survives; current sidecar styles are applied last.
- Normalizes timezone-naive and timezone-aware imported timestamps to UTC before deterministic duplicate resolution.
- Retains the existing atomic bundle publication, rollback, manual-edit conflict, and recovery mechanisms.

## TDD evidence

RED was observed before implementation:

- the focused workflow suite executed 70 tests with 18 expected assertion failures covering missing review formatting, exact identity, note resolution/composition, invalid reporting, and final-path provenance;
- the new two-sheet review regression failed with unformatted `7` and missing semantic sheets;
- the final replay-path assertion failed while durable argv still named the retained generated workbook instead of final `current.xlsx`.
- the review-fix regressions failed with a lost concurrent sidecar/provenance edit, stale `[42]`/font/border state after clear or invalidation, and lost native two-sheet comments/styles;
- the mixed timestamp test raised Python `TypeError`, per-property cleanup stranded managed properties, and the repeat-update tint test retained stale `#ABCDEF` instead of the authoritative candidate tint.

GREEN was then observed for each focused case before the complete workflow suite.

## Verification

```text
swift test --skip-update --filter GenotypeWorkbookRevisionServiceTests
Executed 77 tests, with 0 failures

swift test --skip-update --filter \
  'GenotypeAnnotationStoreTests/(testHeldCandidatePublicationLockCannotPartiallyMutateBundle|testUnsafeCandidatePublicationLockCannotPartiallyMutateBundle)'
Executed 2 tests, with 0 failures

git diff --check
exit 0
```

The focused suite includes the existing final-provenance failure rollback, post-exchange rollback, pre-manifest rollback, cancellation, manual-edit conflict, and hard-stop recovery tests, so prior workbook/bundle preservation remains covered.

Independent re-review reported no remaining Critical or Important issues. Its timestamp and repeat-tint minor notes were subsequently addressed and verified.

## Files

- `Sources/LungfishGenotypeUI/GenotypeAnnotationPublicationCoordinator.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift`
- `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- `.superpowers/sdd/task-7-report.md`

## Self-review

- Confirmed invalid review results never enter the formatting path.
- Confirmed exact stable IDs do not leak to same-label rows at another locus or cluster.
- Confirmed explicit zero remains numeric and an absent value remains empty.
- Confirmed repeated updates reverse only prior managed review properties and preserve unrelated fill/font/border/note formatting.
- Confirmed stale Lungfish-managed note sections are replaced while unrelated native note text remains.
- Confirmed the shared lock prevents coordinated annotation/workbook races and the sidecar witness fails closed for an injected bypass edit without losing either JSON or its provenance companion.
- Confirmed full-length MHC rebuilds preserve semantic native content while current candidate tint and sidecar styling remain authoritative.
- Confirmed the durable command consumes the final stored sidecar and writes final `current.xlsx`.

## Concerns

None blocking. Workbooks that do not expose enough identity to disambiguate duplicate rows are deliberately reported invalid and left unformatted.
