# Task 6 Report: Annotation Inspector Review Controls and Scoped Comment Cards

## Status

Implemented and verified.

## Delivered

- Reordered the matrix annotation inspector so **Review Annotation** is first,
  followed by scoped comments and then the existing generic controls inside a
  collapsed **Appearance** disclosure.
- Review presentation now shows exact target count/type, all-supported,
  all-unsupported, mixed, or unavailable evidence copy, and none, uniform, or
  mixed current review state.
- False Positive, False Negative, and Clear Review Mark use the Task 4 shared
  capability availability and exact disabled reasons. Their view-model methods
  emit the existing semantic `GenotypeMatrixReviewRequest` values only when the
  corresponding shared capability allows the command.
- Added distinct Cell, Allele Row, and Sample Column cards. A selected cell
  receives all three applicable scopes from the controller's cached current
  comment dictionary, with body, author, and timestamp kept separate.
- Empty cards use Add Comment. Populated single-target cards use Save Changes
  and Remove Comment. Bulk cards distinguish empty, uniform, and mixed values.
  Existing or mixed bulk values show the exact explicit action
  `Replace Comments on N Targets` and emit `.replace`; mixed state never
  initializes its editor from an arbitrary current value.
- Scoped drafts remain stable through capability refreshes while still
  rehydrating when the saved value changes. Draft storage is observable so
  Add/Save/Replace enablement updates while typing.
- The capability snapshot now carries resolved comments already present in the
  controller cache for the exact selection and applicable row/column scopes.
  This adds no sidecar scan, disk access, or independent eligibility path.
- Added literal stable accessibility identifiers for the review group and
  actions, each comment card/field/save/replace/remove action, and the
  Appearance disclosure. Existing Task 3 `Saving as` and Settings identifiers
  and app-layer routing remain unchanged.

## TDD Evidence

### RED

The new display-section and viewport tests initially failed to compile because
the inspector presentation properties, scoped card state/actions, and cached
`commentsByTarget` capability payload did not exist. This established the
missing feature boundary before production changes.

### GREEN

Focused tests now cover:

- supported, unsupported, mixed, and read-only review presentation;
- none, uniform, and mixed review state;
- exact shared capability availability and semantic review requests;
- distinct Cell, Allele Row, and Sample Column values and metadata;
- Add, Save, Remove, and explicit bulk Replace request intents;
- empty, uniform, and mixed bulk comments with no arbitrary mixed draft;
- inspector hierarchy and stable identifier readiness; and
- controller-to-inspector delivery of cached applicable scoped comments.

## Verification

Fresh final verification:

```text
swift test --skip-update --filter GenotypeResultDisplaySectionTests
Executed 33 tests, with 0 failures.

swift test --skip-update --filter GenotypeResultViewportTests
Executed 256 tests, with 0 failures.

git diff --check
Passed.
```

## Self-Review

- Review enablement and reasons are read directly from
  `GenotypeMatrixReviewCapabilityState`; the inspector does not recalculate
  evidence eligibility.
- Review and comment actions emit the exact Task 4 request targets and intents
  through the already-wired controller callbacks.
- Applicable comment metadata comes from `matrixCommentsByTarget`, which Task 4
  rebuilds on sidecar revision, and not from a new data source.
- Scope target expansion preserves full locus/genotype/sample/stable-cluster
  identity and de-duplicates exact targets before presenting bulk actions.
- Appearance controls retain their existing bindings and behavior; only their
  hierarchy moved under the disclosure.
- Task 3 identity text and Settings routing remain app-owned, avoiding a new
  LungfishApp dependency in LungfishGenotypeUI.

## Provenance

This task changes inspector presentation and routes mutations through the
existing provenance-aware semantic controller/store commands. It adds no new
scientific data writer, importer, transformer, exporter, or wrapper.

## Concerns

None identified.
