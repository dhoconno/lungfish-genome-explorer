# Three-sheet Excel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give current.xlsx and filtered Excel the same three-sheet presentation, full colored linked haplotype headers, and reviewed direct editing in current.xlsx.

**Architecture:** LungfishIO owns one shared embedded Python presentation writer and Codable payload. Existing scientific projection, publication, provenance, and annotation services remain the authority; a baseline-controlled schema-v2 reader handles direct cell/Note edits alongside the existing v1 reader.

**Tech Stack:** Swift 6.2, existing managed Python/openpyxl runtime, XLSX ZIP/XML, XCTest; Artifact Tool for independent read-only rendering/QA.

**Spec:** `docs/superpowers/specs/2026-09-12-excel-three-sheet-design.md` (user approved).

## Global Constraints

- Both filtered Excel and current.xlsx contain exactly three worksheets, in order: Genotype Matrix, Haplotype Calls, Export Metadata. There are no hidden extra worksheets.
- current.xlsx includes all evidence and remains two-way editable, with changes reviewed in LGE. Filtered Excel remains a one-way snapshot of the settled LGE filters.
- Audit/history and original data remain in the LGE bundle; removing worksheets does not delete their source data.
- Visual filters never rerun haplotype inference.
- Removing a Note or its edit block never clears a stored annotation. Require an explicit clear operation.
- FP requires attested positive raw support. FN requires attested exact zero; absent or ambiguous evidence is not zero.
- Every scientific export/import records workflow/version, exact argv or reproducible command, options and resolved defaults, runtime, input/output paths, checksums/sizes, exit status, wall time, and useful stderr. Retain exact reviewed workbook bytes and baseline; receipts reference final stored payloads.
- Preserve all unrelated worktrees. Never modify the supplied original project during QA.
- Test one Swift process at a time, using `swift test --jobs 6 --filter ...`. Run focused RED/GREEN, then one affected integration suite; no repeated whole-repository runs.

## Shared contract

Create `GenotypeWorkbookPresentation` in LungfishIO, with public `pythonScript: String` and nested Codable/Sendable payload models. Python entry point:

```python
# Invocation; returns the JSON-serializable trusted layout manifest.
layout_manifest = render_three_sheet_workbook(payload, output_path)
```

The function body is implemented in Task 1; the stable wire fields are:

```json
{
  "schemaVersion": 2,
  "role": "editable-current",
  "sourceRevision": {},
  "samples": [{"id":"S1", "name":"S1", "comment":null}],
  "loci": ["MHC-A"],
  "rows": [{"id":"row-identity", "target":{"kind":"row","locus":"MHC-A","genotype":"G1"}, "displayName":"G1", "comment":null, "fillHex":null,
    "cells":[{"sampleID":"S1","displayValue":5,"rawSupport":5,"reviewEligible":true,"fillHex":null,"comment":null,"review":null}]}],
  "calls": [{"id":"call-identity","sampleID":"S1","locus":"MHC-A",
    "h1":{"effective":"M1A","pipeline":"M1A","baselineAvailable":true,"status":"ok","source":"pipeline"},
    "h2":{"effective":"M1A","pipeline":"","baselineAvailable":true,"status":"ok","source":"pipeline"},"comment":null}],
  "colors": [{"locus":"MHC-A","call":"M1A","fillHex":"#000000","fontHex":"#FFFFFF"}],
  "metadata": [["Scope","All evidence"]],
  "callEditingSupported": true
}
```

Use deterministic row/call identity hashes derived from exact scientific target JSON in real callers, not the illustrative row/call IDs above. Sample.id is the exact scientific sample identifier used by annotation targets; Sample.name is its display label. `displayValue` is an integer or null; raw support is independently integer or null, never inferred from display. `pipeline:null` means unavailable; `pipeline:""` is a real empty baseline. Row target may include stableClusterID. Colors resolve from active LGE definitions, not a Python M-number map.

`loci` orders the haplotype band, not the universe of evidence-row loci: real matrices include MHC-F/G evidence without corresponding haplotype calls. `calls` may be sparse across samples and loci. Preserve absent sample/locus slots as blank band cells, without synthesizing call-sheet rows. Require complete sample cells for each evidence row, not a complete sample-by-locus call product.

The returned manifest contains schemaVersion, role, sheetOrder, callTargets, noteTargets, immutableCells, expectedFormulas, identityCells, allowedNoteGrammarVersion. callTargets map IDs to sample/locus and per-slot valueCell/actionCell/baselineAvailable/pipeline/effective. noteTargets map target IDs to sheet/cell/target/rawSupport/reviewEligible/currentComment/currentReview/generatedText. Immutable cells include types, values, hyperlinks; expectedFormulas map sheet and address to exact allowed formula. The caller stores this trusted manifest with the attested baseline. Workbook metadata never grants authority.

## Task 1: Shared renderer and deterministic workbook schema

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeWorkbookPresentation.swift`
- Create: `Sources/LungfishIO/Bundles/GenotypeWorkbookPresentation+Script.swift`
- Create: `Tests/LungfishIOTests/GenotypeWorkbookPresentationTests.swift`

**Interfaces:** Consumes the shared contract above. Produces the public payload models, `pythonScript`, and `render_three_sheet_workbook(payload, output_path)` for Tasks 2/3. No production activation in this task.

- [ ] Write a production-script fixture runner using the managed Python path convention in `GenotypeEditableWorkbookTests`. It executes the embedded script, renders a synthetic payload, opens saved XLSX with formulas and data-only modes, and returns compact JSON for XCTest assertions. Start with a literal two-sample/five-locus case; include homozygous DR, swapped DQ, unresolved H2, customized colors, one below-threshold null next to support 5, comments and explicit zero.
- [ ] Run `swift test --jobs 6 --filter GenotypeWorkbookPresentationTests` and record the missing-renderer failure. Representative assertions:

```swift
XCTAssertEqual(result.sheetNames, ["Genotype Matrix", "Haplotype Calls", "Export Metadata"])
XCTAssertEqual(result.cachedDRSlots, ["M4DR", "M4DR"])
XCTAssertEqual(result.matrixEvidence, [nil, 5])
XCTAssertEqual(result.zeroRawSupport, 0)
XCTAssertNil(result.unknownRawSupport)
```

- [ ] Implement payload validation (unique scientific IDs and sample/locus targets; known sample references; exact cell roster; nonnegative integer raw support; consistent baseline availability). Build exactly three sheets from a new workbook. Matrix: protected hidden row-ID column, allele/locus identity, sample columns, sample heading, two rows per locus, genotype-table-only autofilter and frozen band. Calls: protected hidden stable ID, common effective/status/source/pipeline/comment columns, H1/H2 import action dropdowns, lock calls without baselines. Snapshot fields are all locked; current call/action fields are unlocked. Notes remain editable without allowing raw-count edits in the importer.
- [ ] Use this exact editable Note block grammar, with values encoded as JSON strings to preserve multiline/literal text without delimiter ambiguities:

```text
[LGE Edit v2]
Review operation: keep
Review value: ""
Comment operation: keep
Comment value: ""
[/LGE Edit v2]
```

Keep generated evidence/current comments outside the block. Populate blocks on annotated eligible cells; provide the template/instructions in Metadata for adding to other eligible cells. Row/sample targets allow comments only. No redundant editing table.
- [ ] Link matrix band to the Haplotype Calls values with blank-preserving internal formulas. Generate bounded conditional formatting from supplied exact-locus color definitions; include initial fills. Set automatic/full calculation. After the final openpyxl save, inject exact initial string formula caches into the worksheet XML through ZIP/XML libraries; never save through openpyxl again after cache injection. Verify cached values, formula text, and cache escaping for literal special characters.
- [ ] Return the complete trusted manifest (including immutable generated Note text and identity locations) without creating a fourth sheet. Metadata explains role, source revision, scope, Notes vs threaded Comments, editable fields, explicit reset action, no deletion from blank cells, and LGE review.
- [ ] Add role-parity, text-injection, invalid-roster/duplicate-target, all-loci, Note block, formula cache, blank/zero, baseline-unavailable, custom-color/conditional-rule, and freeze/filter-range tests. Run the focused suite, self-review and commit only these files.

## Task 2: Baseline-controlled v2 direct-edit importer

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService+Script.swift`
- Create: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService+ThreeSheet.swift`
- Create: `Tests/LungfishWorkflowTests/GenotypeThreeSheetEditableWorkbookTests.swift`
- Preserve: `Tests/LungfishWorkflowTests/GenotypeEditableWorkbookTests.swift` as v1 coverage.

**Interfaces:** Consumes Task 1 renderer and manifest. Extend existing attestation with an optional trusted v2 manifest parameter, default nil preserving v1 callers. Baseline adds optional manifest with backward-compatible decoding. Public `inspect`, `Inspection`, `Change`, publication/revalidation/evidence APIs retain their existing consumer contracts.

- [ ] Generate a real Task 1 workbook and attest using the v2 entry point. Directly edit a H1 value, queue H2 pipeline reset, and add a structured FP Note; assert the existing `Change` objects. Run `swift test --jobs 6 --filter GenotypeThreeSheetEditableWorkbookTests` and record expected unsupported-schema failure.

```swift
XCTAssertEqual(inspection.changes.first(where: { $0.kind == .call && $0.slot == .h1 })?.value, "M2A")
XCTAssertNil(inspection.changes.first(where: { $0.kind == .call && $0.slot == .h2 })?.value)
XCTAssertEqual(inspection.changes.first(where: { $0.kind == .review })?.value, "false-positive")
```

- [ ] Dispatch reader/validator by trusted baseline version; preserve the v1 path. V2 reader returns all physical typed cells/Notes/formulas, order, defined names, links, merged ranges. Validator derives writable targets only from trusted manifest, compares every other scientific cell/formula and generated Note text, rejects extra/missing/reordered target layouts with an actionable error, and ignores harmless presentation-only changes. Never trust workbook-provided IDs or marker edits to expand edit permissions.
- [ ] H1/H2 changed nonempty literal creates an override; unchanged value no-op. Dropdown `Use pipeline call` creates explicit clear; default `Use entered call` with a newly blanked nonempty value rejects. Unavailable baseline rejects even after bypassing protection. Unchanged genuine blank slots remain no-op. Reject new user formulas, links, duplicate IDs, stale sources, and simultaneous edit/inspect races using existing guards.
- [ ] Parse exactly one valid Note block per allowed target. Keep/clear/set semantics match v1; changed values with keep reject. Missing block/Note means no proposal, not deletion. Editing generated text rejects; removing the whole Note is safe no-op. Validate FP positive/FN exact zero and prohibit reviews on row/sample or ineligible/unknown-support targets. Preserve unmodified comments and literal JSON text.
- [ ] Keep exact input workbook/baseline/reader/runtime evidence receipts and atomic annotation publication. Add RED/GREEN cases for rejected raw count/formula/metadata changes, stale/duplicate/missing targets, false-negative unknown support, row/sample comments, multiline comments, deleted Notes, blank calls, v1 pending import, and retry/no-op behavior. Run v1 and v2 suites once together, self-review and commit.

## Task 3: Wire both production exports and full current refresh

**Files:**
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportPivotXlsxSubcommand.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookInputFingerprint.swift`
- Modify: `Sources/LungfishIO/Bundles/GenotypeViewProjection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeViewportExportService.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift`
- Create as needed: a dedicated current presentation adapter/script alongside `GenotypeWorkbookRevisionService.swift`.
- Test: `Tests/LungfishCLITests/GenotypePivotFilteredCopyTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeProjectionTests.swift`

**Interfaces:** Consume Task 1 rendering and Task 2 attestation. Add backward-compatible optional projection color definitions and explicit per-slot baseline availability; existing initializers keep defaults. Current generation passes the trusted manifest from its staging writer to attestation. Existing external command flags and UI action signatures remain stable.

- [ ] Add production-writer tests showing current has exactly three sheets and filtered matrix header caches equal exact call sheet values. Include annotation-only refresh of a new-schema workbook, an old edited workbook awaiting review, and the one-read/5-read filter boundary. Run focused tests and record old-layout/no-band failures.
- [ ] Capture resolved active-definition colors for every relevant exact locus/call, including callable alternative values for Excel conditional formatting. Thread through snapshot serialization and current generation as witnessed input. Carry real baseline availability separately from display-normalized H2. Reuse LGE effective call authority and existing source resolver; no new biological inference.
- [ ] Include the canonical resolved palette and presentation schema version in current-workbook synchronization fingerprint inputs. Existing schema 3 fingerprints hash calls/loci/annotations/candidate/catalog state but not haplotype colors. Add backward-compatible input defaults and tests that changing a resolved color or presentation schema forces regeneration while reordering an equivalent color mapping does not. Preserve raw genotype-review enum meanings when adapting sidecar falsePositive/falseNegative into the renderer/importer's documented review values.
- [ ] Adapt filtered captured rows/cell masks and annotations to the shared payload, replacing only its clean-presentation section. Preserve no-projection CLI threshold semantics through the same three-sheet presentation adapter, with compatibility tests. Do not reconstruct visible cells from row membership alone or retain unfiltered companion worksheets.
- [ ] Adapt current full catalog/configuration roster and effective calls to the shared payload. Use raw catalog values for full evidence, preserve display labels/annotation styling, and retain explicit zero vs unknown distinctions. Remove legacy worksheet seeding from the final emitted presentation. Preserve old source payloads and audit history in bundle. Replace Edit Calls fallback with baseline-attested/new-schema call extraction or authoritative scientific sources during annotation-only refresh; never drop calls because the old editing sheet is absent.
- [ ] Finish current generation with the renderer as the last XLSX writer; no subsequent save erases caches. Keep no-clobber, stage/commit, provenance and atomic baseline/workbook publication. Block migration while unreviewed v1 edits exist; accepted v1 edits can regenerate v2 through existing review/retry guard.
- [ ] Run targeted writer/projection suites, adapt legacy-layout assertions only where user intentionally changed the contract, and retain old-input migration tests. Verify receipts bind final cached workbook bytes and resolved palette input. Self-review and commit.

## Task 4: Integrated workflow, user guidance, and acceptance

**Files:**
- Modify: `Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeReviewedHaplotypeInferenceTests.swift`
- Modify as needed: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift` and existing Excel review presenter guidance referring to Edit Calls/Edit Matrix.
- Modify: `Sources/LungfishGenotypeUI/GenotypeAuditTimelineSection.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeAuditTimelineExpansionTests.swift`
- Modify for visual acceptance: `Sources/LungfishIO/Bundles/GenotypeWorkbookPresentation+Script.swift` and `Tests/LungfishIOTests/GenotypeWorkbookPresentationTests.swift`.
- Create: `docs/reviews/2026-09-12-three-sheet-excel-qa.md`

**Interfaces:** Exercise existing Inspector export/review paths; no new permanent buttons. Consume completed Tasks 1–3.

- [ ] Extend real-controller tests to edit direct calls/Notes in generated current.xlsx, accept through the existing annotation store, and assert immediate matrix/call refresh, regenerated three-sheet current, filtered export, and save/reopen parity. Include mixed call+FP+comment and explicit clears. Run focused RED/GREEN for any stale legacy UI routing.
- [ ] Replace obsolete sheet-navigation instructions with direct-cell/Note guidance. Verify audit/history and original payloads remain accessible from LGE; do not delete storage. Keep existing single Inspector Export to Excel dialog and role explanations.
- [ ] The read-only interface audit confirmed both existing timeline usages truncate history, with no full-list action. Add a contextual Show all / Show recent toggle to the existing timeline, without new Inspector panels. Add a behavioral ViewInspector test with 13 uniquely named entries: oldest entry initially absent, present after Show all, absent after Show recent; all entries remain unchanged. Update CLI current-workbook help that still promises Overrides/Audit Log worksheets. Run `swift test --jobs 6 --filter GenotypeAuditTimelineExpansionTests` RED/GREEN.
- [ ] Use an additional disposable copy of the whole reported project for actual-cohort acceptance. Hash original before/after without invoking recovery-capable loaders on it. Compare both roles' every call slot, matrix values/annotations, colors, cache/formula parity, and exactly-three-sheet schema before/after a reviewed edit. Keep private paths/identifiers out of committed fixtures/docs.
- [ ] Independently render each sheet and changed header region with Artifact Tool, inspecting cells/formulas and testing dependent formula recalculation on a disposable in-memory copy. Native Excel Notes/protection/recalculation checks, if available through an approved QA environment, are recorded separately; never imply native testing from a library render.
- [ ] Parent's Task 1 visual check found default-width clipping in matrix allele labels and Haplotype Calls headings/actions, and colors missing from the call-sheet values (band colors work). Fit/wrap widths and row heights; keep effective H1/H2 easy to compare side by side with action/detail fields to their right. Apply the same initial/dynamic color mapping to both call views. Preserve manifest-derived identities/addresses and revise fixture coordinates accordingly. Remove duplicate Scope metadata rows and keep role instructions concise. Confirm FP/FN remain visibly annotated, using existing scientific review semantics and numeric formatting rather than modifying raw numeric counts. These are required presentation acceptance fixes before final completion.
- [ ] Run one integrated affected suite with `swift test --jobs 6 --filter 'GenotypeWorkbookPresentationTests|GenotypeThreeSheetEditableWorkbookTests|GenotypeEditableWorkbookTests|GenotypePivotFilteredCopyTests|GenotypeWorkbookRevisionServiceTests|GenotypeViewportExcelExportTests|GenotypeReviewedHaplotypeInferenceTests|GenotypeEffectiveHaplotypeProjectionTests|GenotypeCurrentWorkbookSyncCoordinatorTests|GenotypeExcelDialogBehaviorTests'`. Record counts, skips, failures, exact commands and limitations in QA doc. No passing claim if a required invariant remains unverified.
- [ ] Commit, obtain Astra final whole-branch review and resolve findings through one bounded fix wave. Leave the tested branch available for authorized merge/release; do not touch unrelated worktrees or publish unverified changes.
