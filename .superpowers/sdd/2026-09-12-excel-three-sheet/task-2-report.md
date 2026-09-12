# Task 2 report — baseline-controlled v2 direct-edit importer

## Result

Implemented the non-activated three-sheet importer behind trusted schema-v2 attestation. The v1 baseline, reader, import behavior, public inspection/change/publication contracts, and outstanding v1 workbook support remain intact. Production workbook generation is intentionally not activated.

## TDD evidence

- RED: `swift test --jobs 6 --filter GenotypeThreeSheetEditableWorkbookTests` failed to compile at `trustedManifest:` with `extra argument 'trustedManifest' in call`. This was the earliest observable unsupported-v2 failure: no v2 attestation entry point existed yet. The first renderer-backed behavior test generated a real XLSX and JSON manifest using `GenotypeWorkbookPresentation.pythonScript`.
- Initial GREEN: the same focused command passed 1 test / 0 failures for direct H1 editing, explicit H2 pipeline reset, and an FP Note proposal.
- Expanded GREEN: the focused suite passed 8 tests / 0 failures before final blank-baseline and clear-operation coverage.
- During hardening, the genuine-empty-pipeline test exposed an openpyxl representation mismatch (`""` in the manifest reloads as an absent physical cell). The focused test failed with `Read-only scientific cell changed: Haplotype Calls!H2`; the validator was narrowed to treat only a manifest-attested empty immutable literal with no hyperlink as the equivalent absent cell.
- Final focused verification: `swift test --jobs 6 --filter GenotypeThreeSheetEditableWorkbookTests` passed 10 tests / 0 failures.
- Final affected integration: `swift test --jobs 6 --filter 'Genotype(ThreeSheet)?EditableWorkbookTests'` passed 20 tests / 0 failures (10 v1 + 10 v2) in 20.307 seconds.
- `git diff --check` passed.

## Interface changes for Task 3

- Existing attestation signatures remain source/binary compatible.
- New overload:

  ```swift
  attestGeneratedWorkbook(
      workbookURL: URL,
      bundleURL: URL,
      scientificInputURLs: [URL] = [],
      callEditingSupported: Bool = true,
      trustedManifest: Data?
  )
  ```

- Task 3 should pass the exact JSON bytes returned by `render_three_sheet_workbook` as `trustedManifest`. A non-nil manifest selects schema v2; nil preserves schema v1.
- The baseline stores the exact trusted manifest plus an attested physical reader snapshot. No workbook marker selects the schema or grants edit authority.
- Manifest `callTargets.*.{h1,h2}.valueCell/actionCell` and `noteTargets.*.sheet/cell` are the only editable mappings. Task 3 may change physical columns through the renderer without importer changes as long as the manifest mappings remain accurate.
- Manifest `sampleID` is normalized to the sidecar's exact scientific `sample`; display labels never become annotation identities. `stableClusterID` is preserved for row/cell targets.
- Existing `inspect`, `Inspection`, `Change`, revalidation, evidence preservation, and publication APIs are unchanged. V2 evidence receipts record schema 2 and retain exact workbook, baseline (including manifest), reader, parsed inspection, sources, runtime, hashes/sizes, status, and wall time.

## Implemented validation and edit semantics

- V2 reader records ordered sheets, every physical typed cell/value/Note/formula/hyperlink, defined names, external links, merged ranges, and runtime identity.
- Validator requires the trusted sheet order, identities at exact physical positions, exact immutable scientific values/types/links, exact generated formulas, unchanged defined names, no external links, and no values or Notes outside manifest-authorized targets. Formatting-only changes are ignored. Physically reordered targets reject with an actionable layout error.
- Direct changed nonempty H1/H2 values propose overrides; unchanged values are no-ops; `Use pipeline call` proposes explicit clear; blanking a nonempty call rejects; attested genuine blanks remain no-ops; unavailable baselines reject even after protection bypass.
- Notes accept exactly one whole-line-delimited LGE Edit v2 block. Generated text is immutable; missing/deleted Notes or complete blocks are no proposals. JSON string values support multiline text and literal delimiter substrings. Keep/set/clear rules are explicit, including clear-only deletion semantics.
- FP requires trusted positive raw support. FN requires trusted exact zero. Unknown support, ineligible cells, and row/sample reviews reject. Row/sample comments remain eligible.
- Existing input witness, sidecar/source staleness, byte-level inspection race, revalidation, atomic publication, retry, and evidence preservation guards apply unchanged.

## Coverage

Renderer-generated tests cover direct call edit/reset, FP proposal, scientific raw-value/formula/metadata/link tampering, missing/duplicate/unknown/reordered identities, stale sources, blank calls, unavailable baselines, genuine blanks, deleted Notes, multiline comments, explicit comment clear, generated Note tampering, delimiter literals, unknown-support FN, row/sample review rejection, harmless formatting, evidence receipts, and retry/no-op behavior. The preserved v1 suite covers outstanding legacy imports and v1 publication behavior.

## Files

- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService+Script.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService+ThreeSheet.swift`
- `Tests/LungfishWorkflowTests/GenotypeThreeSheetEditableWorkbookTests.swift`
- `.superpowers/sdd/2026-09-12-excel-three-sheet/task-2-report.md`

## Self-review and concerns

- Reviewed the importer for workbook-derived authority: every writable address and scientific identity comes from the retained manifest; workbook stable-ID or metadata edits cannot expand permissions.
- Reviewed Task 4 compatibility: no call-sheet column offsets are hardcoded; all H1/H2 addresses come from the manifest.
- Merged ranges are captured for evidence replay but not used as scientific authority, so harmless presentation-only merge changes do not invent or retarget edits. Exact identity locations still make structural target moves reject.
- The production writer remains on v1 until Task 3 explicitly supplies the renderer manifest. Native Excel Notes behavior and visual layout remain later integration/release responsibilities.
- Swift builds emit pre-existing unrelated warnings; the affected tests have no failures.
