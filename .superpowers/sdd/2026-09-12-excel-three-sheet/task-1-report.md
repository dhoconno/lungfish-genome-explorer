# Task 1 report — shared three-sheet renderer

## Result

Implemented the shared, non-activated workbook presentation in LungfishIO. Production writers are intentionally unchanged.

## TDD evidence

- RED: `swift test --jobs 6 --filter GenotypeWorkbookPresentationTests` failed at compile time because `GenotypeWorkbookPresentation` and its renderer did not exist.
- GREEN: the same focused command passed 5 tests / 0 failures after implementation.
- Affected integration: `swift test --jobs 6 --filter GenotypeEditableWorkbookTests` passed 10 tests / 0 failures.
- `git diff --check` passed for all three owned source/test files.

The production-script fixture uses `LUNGFISH_TEST_PYTHON`, falling back to `~/.lungfish/conda/envs/openpyxl/bin/python3`, executes the actual embedded script, opens the result in formula and data-only modes, and returns compact JSON to XCTest.

## Files

Implementation commit: `12736b8c2` (`Add shared three-sheet genotype workbook renderer`). This report's final metadata update is committed separately so the implementation hash remains exact.

- `Sources/LungfishIO/Bundles/GenotypeWorkbookPresentation.swift`
- `Sources/LungfishIO/Bundles/GenotypeWorkbookPresentation+Script.swift`
- `Tests/LungfishIOTests/GenotypeWorkbookPresentationTests.swift`

## Public payload interface

`GenotypeWorkbookPresentation` exposes `public static let pythonScript: String` and public nested `Codable & Sendable` models:

- `Payload(schemaVersion, role, sourceRevision, samples, loci, rows, calls, colors, metadata, callEditingSupported)`
- `Sample(id, name, comment)`
- `Target(kind, locus, genotype, stableClusterID)`
- `Cell(sampleID, displayValue, rawSupport, reviewEligible, fillHex, comment, review)`
- `Row(id, target, displayName, comment, fillHex, cells)`
- `Slot(effective, pipeline, baselineAvailable, status, source)`
- `Call(id, sampleID, locus, h1, h2, comment)`
- `Color(locus, call, fillHex, fontHex)`

Python entry point: `layout_manifest = render_three_sheet_workbook(payload, output_path)`.

Validation rejects unsupported schema/role, duplicate sample/locus/row/call IDs, duplicate call targets, unknown call sample/locus references, incomplete/duplicate per-row sample cell rosters, negative/non-integer raw support, and disagreement between `baselineAvailable` and pipeline presence. Calls are intentionally sparse, and evidence-only loci such as MHC-F are intentionally permitted.

## Returned trusted manifest

The JSON-serializable dictionary contains:

- `schemaVersion`, `role`, `sourceRevision`, `callEditingSupported`, `sheetOrder`, `allowedNoteGrammarVersion`
- `callTargets`: keyed by supplied stable call ID; each value has `sampleID`, `locus`, and nested `h1`/`h2`, each containing `valueCell`, `actionCell`, `baselineAvailable`, `pipeline` (including null vs empty), and `effective`
- `noteTargets`: keyed by deterministic composite identity (`sample:<id>`, `row:<id>`, or `cell:<row-id>:<sample-id>`); each includes `sheet`, `cell`, exact scientific `target`, independent `rawSupport`, `reviewEligible`, `currentComment`, `currentReview`, and immutable `generatedText`
- `immutableCells`: keyed by `Sheet!Address`, with cell `type`, exact `value`, and `hyperlink`
- `expectedFormulas`: sheet/address to exact allowed blank-preserving internal formula
- `identityCells`: call/sample/row stable identity to sheet/cell/value

Workbook metadata is explanatory only and grants no authority. The returned manifest is designed to be retained with an attested baseline by the production caller.

## Workbook behavior covered

- Exactly the ordered sheets `Genotype Matrix`, `Haplotype Calls`, `Export Metadata`, with no hidden companion sheet.
- All supplied loci get two call-band rows; sparse missing calls remain blank. Evidence tables may contain additional loci.
- Matrix formulas link to effective call cells, preserve blanks, retain initial cached string values, and request automatic/full recalculation.
- Cache injection happens through ZIP/XML after the final openpyxl save; the workbook is never saved through openpyxl afterward.
- Stable IDs are protected and hidden. Raw matrix cells and snapshot call fields are locked. Editable-current effective/action cells unlock only when a baseline exists; filtered role locks them all.
- Traditional Notes contain immutable generated evidence/current annotation text plus the exact JSON-string-valued LGE Edit v2 block where an eligible annotated target exists. Metadata supplies the exact template for adding a block elsewhere. Row/sample targets permit comments only.
- Explicit action dropdowns, custom initial fills, bounded formula conditional formatting, genotype-table-only autofilter, and frozen identity/call band are present.
- Literal formula-like annotation text remains a string.

## Concerns / deferred scope

- Task 1 does not activate either production writer and therefore does not itself publish provenance or an attested baseline. The activating production tasks must retain exact workbook bytes plus this trusted manifest and record the required scientific export provenance against final stored paths.
- Validation intentionally rejects duplicate/missing physical identities via future importer attestation rather than attempting to relocate edits; importer behavior is outside Task 1.
- Verification used openpyxl/ZIP inspection, not native Microsoft Excel visual QA; native Excel checks remain a release/integration responsibility.

## Review fix round 1

Implementation commit: `1b7509c33` (`Complete workbook renderer trust contract`).

TDD command: `swift test --jobs 6 --filter GenotypeWorkbookPresentationTests`.

- RED: 6 tests executed with 5 failures. The run reproduced missing `stableClusterID`, missing unannotated row/sample targets, incomplete conditional-format rules, and the exact `re.error: invalid group reference 1` from a cached value containing `\\1`.
- GREEN: 6 tests executed with 0 failures in 2.019 seconds after the fixes; build completed successfully in 10.19 seconds.
- `git diff --check` passed for the renderer, tests, and report.

Covering behavior added or strengthened:

- Every cell Note target carries an available `stableClusterID`; every sample and row has a trusted `noteTargets` entry even before its first Note/comment.
- Every matrix call cell receives rules for all supplied exact-locus definitions plus a bounded neutral fallback for undefined values, including initially blank/uncolored cells.
- Cache XML replacement uses callbacks, preserving literal backslashes, `<`, `&`, quotes, and empty caches. The test checks special text through data-only openpyxl and checks the exact explicit empty cache in worksheet XML (openpyxl correctly exposes that blank as nil).
- Payload sample labels, evidence headers, row identities/loci/display labels, and caller metadata use literal-string assignment; formula-like payload text remains non-executable.
- Invalid-input coverage now includes duplicate row IDs, duplicate call IDs, and duplicate sample/locus call targets. DQ special/unresolved caches, sparse missing-call cache behavior, and the MHC-F cluster identity are asserted directly.

Manifest clarification after fixes: `noteTargets` always includes `sample:<sample-id>` and `row:<row-id>` entries with null current comment and empty generated text when initially unannotated. Cell target dictionaries include `stableClusterID` when supplied by the row target. No authority moved into workbook metadata.
