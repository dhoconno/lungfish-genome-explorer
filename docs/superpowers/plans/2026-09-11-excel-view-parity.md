# Excel View Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export exact LGE haplotype and filtered matrix views, safely exchange supported Excel edits, and publish a verified Preview.

**Architecture:** Shared effective-call authority supplies displayed homozygous calls and exact locus identities. A revision-bound projection supplies visible matrix cells and complete calls to a one-way workbook. A separately attested full-evidence workbook carries explicit editing tables and baseline identities; a single dialog selects the role.

**Tech Stack:** Swift, AppKit/SwiftUI, XCTest, managed Python/openpyxl, existing CLI provenance and workbook transactions.

**Spec:** `docs/superpowers/specs/2026-09-11-excel-view-parity-design.md` (user approved 2026-09-11).

## Global Constraints

- One Inspector button: **Export to Excel…**. Two roles: **Filtered view** and **Editable workbook — current.xlsx**.
- Both workbooks must show all effective H1/H2 calls displayed in LGE, including homozygous calls at every locus.
- Visual filters must not rerun biological inference or change calls.
- Supported edits are manual H1/H2 overrides, matrix false-positive/false-negative review dispositions, and comments.
- Raw observations are not an editable scientific input.
- Missing provenance blocks publication. Retain workflow/version, reproducible argv, defaults/options, runtime, paths/checksums/sizes, status/time/stderr and final stored payloads.
- Use only `.worktrees/excel-view-parity`, preserve source cohort and every unrelated worktree. No private cohort fixtures in git.
- Never overwrite unreviewed external edits. Preserve imported workbook evidence; publish accepted sidecar changes atomically and save immediately.

## Task 1: Exact effective calls and filtered workbook parity

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeEffectiveCallAuthority.swift`, `GenotypeViewProjection.swift`.
- Modify: `Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift`, `GenotypeViewportExportService.swift`, `GenotypeResultViewController.swift`.
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`, `GenotypeWorkbookRevisionService+OverrideScript.swift`.
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportPivotXlsxSubcommand.swift`.
- Tests: existing effective authority/projection, viewport pivot, CLI filtered-copy, and workbook revision suites.

**Interfaces:** Consume `GenotypeEffectiveCallAuthority.resolve(analysis:sidecar:)`. Extend `GenotypeViewProjection` and viewport snapshot with optional ordered exact-locus haplotype payload and source revision/filter context, decoding legacy projections unchanged. The implementer records exact new signatures in its report for Tasks 2–3.

- [ ] Run existing focused baseline tests, then add failing real-behavior cases with hand-derived assertions:
  ```swift
  // Synthetic single-haplotype called locus, no override:
  XCTAssertEqual(resolvedH1, "M4DR")
  XCTAssertEqual(resolvedH2, "M4DR")
  // Explicit analyst absent H2 remains absent; baseline stays raw "-".
  XCTAssertEqual(explicitAbsentH2, "-")
  XCTAssertEqual(pipelineBaselineH2, "-")
  // XLSX fixture: sample A supports row at 1, B at 10; Min Reads = 5.
  XCTAssertEqual(exportedA, "")
  XCTAssertEqual(exportedB, "10")
  ```
  Include counts 1/4/5/6, DR/DRB and simultaneous DQA/DQB/DQ, unresolved/error slots, all homozygous loci, comments/FP/FN, and stale overrides. Remove old expectations deliberately requiring DRB blank.
- [ ] Run relevant `swift test --jobs 6 --filter 'GenotypeEffective|GenotypeViewportPivotExportTests|GenotypePivotFilteredCopyTests|GenotypeWorkbookRevisionServiceTests'`; retain expected RED failures before implementation.
- [ ] Move existing UI single-haplotype H2 display normalization into shared effective authority after overrides and before locus snapshots, using H2 status. Preserve raw baseline/source and explicit absence; remove duplicate UI normalization. Do not change biological input thresholds.
- [ ] Remove exact-locus exclusions/collapse from effective workbook payloads. Generate a complete Haplotype Calls worksheet from that payload and remove writer-only homozygous inference. Preserve existing legacy overview compatibility as clearly derived presentation, not editing authority.
- [ ] Capture live effective calls in current export snapshot and serialize them. For new typed filtered snapshots, write only visible Genotype Matrix, complete scoped Haplotype Calls, and filtered metadata/provenance; do not retain unfiltered template companion data. Legacy CLI no-projection behavior remains compatible.
- [ ] Use current row projection as cell authority; verify low-support blanks rather than applying another inconsistent threshold. Reproduce original cohort on a disposable copy and identify any additional selected-pivot leak before patching it. Record original hashes unchanged.
- [ ] Run focused suites GREEN, `git diff --check`, self-review, and commit only this task. Report exact commands/counts and shared APIs.

## Task 2: Attested editable workbook and atomic supported-edit service

**Files:**
- Create focused editable workbook parser/baseline/change-set service files under `Sources/LungfishWorkflow/ONTGenotyping/`.
- Modify workbook revision service/script to seed explicit editing sheets and trusted baseline.
- Modify `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift` for a single accepted-change transaction.
- Modify `Sources/LungfishApp/Services/GenotypeCurrentWorkbookSyncCoordinator.swift` and shared sync-state types to detect external edits before regeneration/open.
- Tests: new workflow edit service tests, annotation store transaction tests, current workbook sync coordinator tests.

**Interfaces:** Consume exact effective calls from Task 1, `GenotypeAnnotationSidecar.MatrixTarget`, and current revision/hash. Produce read-only inspect/diff, preserved input evidence, and one validated change-set apply interface for Task 3. Record concrete signatures in report. Use baseline stored in bundle, not an Excel-editable trust anchor alone.

- [ ] Add failing XLSX fixture tests for no-op roundtrip; explicit H1/H2 override/clear; review FP/FN/clear; comment set/clear; reordered rows/columns; duplicate/unknown IDs; raw evidence tampering; stale source/sidecar; all-or-nothing failure.
  ```swift
  XCTAssertTrue(unchangedDiff.changes.isEmpty)
  XCTAssertEqual(importedSidecar.callOverrides.count, 1)
  XCTAssertEqual(rawReadsAfterImport, rawReadsBeforeImport)
  XCTAssertEqual(sidecarBytesAfterRejectedImport, sidecarBytesBeforeImport)
  ```
- [ ] Run new focused tests RED. Implement explicit editable tables using stable IDs and operation columns; protect/label scientific read-only sheets. Do not silently interpret omitted rows or blank cells as deletion. Whitelist mutable fields; reject changed evidence and schema/identity ambiguity.
- [ ] Record immutable baseline, source/sidecar identity, full workbook evidence, and checksums in bundle-controlled state. Compare actual current.xlsx checksum before regeneration; external modifications enter a review-required state rather than being overwritten. Preserve reordered cells by identity, not worksheet position.
- [ ] Implement read-only inspection and validated change-set, revalidate under publication lock at apply time, preserve edited workbook snapshot, and apply all supported changes through one annotation publication transaction with audit/replay/provenance. Reuse GUI annotation semantics; never sequentially partially commit mixed edits.
- [ ] Expose editable opening of attested canonical current.xlsx, retaining immutable snapshot behavior for any separate legacy read-only intent. After successful import mark current dirty and refresh through existing sync. On generation failure retain saved annotations, imported input, and retryable dirty state.
- [ ] Run focused tests GREEN, including in-flight external edit race/no-clobber, rollback and final-path provenance. Self-review and commit; report APIs Task 3 must wire.

## Task 3: Single Excel dialog, status, and review integration

**Files:**
- Create focused export-choice/review UI under `Sources/LungfishGenotypeUI/`.
- Modify `GenotypeResultDocumentSection.swift`, `GenotypeResultDisplaySection.swift`, `GenotypeResultViewController.swift`, Inspector callback/state seams and App content-display wiring as needed.
- Tests: viewport workbook publication, Inspector interaction, numeric filter draft, and App workbook coordinator suites.

**Interfaces:** Consume Task 1 captured export and Task 2 external-edit inspection/apply/open APIs. Reuse existing filtered exporter and current sync intent routing, not a second workbook engine.

- [ ] Add failing behavior tests for one button reaching both actions, default filtered role, cancel no side effects, valid/invalid filter drafts, review-required external file, and import refresh/error presentation.
  ```swift
  XCTAssertEqual(exportedSnapshot.filters["matrixMinimumReads"], "5")
  XCTAssertEqual(exportCallsAfterCancel, 0)
  XCTAssertEqual(regenerationsWhileExternalEditsPending, 0)
  ```
- [ ] Run focused UI tests RED. Replace competing buttons with **Export to Excel…** in one Excel Inspector section. Dialog defaults to **Filtered view**, shows the spec's brief role explanations and committed filter summary, and chooses **Export…** or **Open in Excel** primary action.
- [ ] Commit valid numeric drafts and settle view state before capturing immutable export. Abort invalid input; reuse captured state through save dialog so reported scope and exported bytes agree.
- [ ] Add current synchronization status, latest filtered-file link, progress and actionable errors in that section. Show contextual **Review Excel Changes…** when external edits exist; present supported changes before atomic import. No extra permanent export control.
- [ ] Wire accepted imported edits to immediate save, recompute, viewer refresh, and current-workbook regeneration. Avoid auto-overwriting a workbook still being edited; checksum revalidation is authoritative.
- [ ] Run focused tests GREEN and accessibility/keyboard interaction checks. Inspect generated workbook structure/content programmatically and visually where tooling permits. Self-review and commit.

## Task 4: Integration, specialist review, and Preview publication

**Files:** release identity declarations and next `docs/release-notes/<version>.md`; verification report in `docs/reviews/` with no private cohort data.

- [ ] Run affected regression suites together and real-cohort checks on a disposable copy; compare all effective slots, visible cells, FP/FN/comments and unfiltered current. Retain workbook checksums/provenance and no-mutation evidence.
- [ ] Have Astra review whole branch, plus bioinformatics and UI/UX acceptance findings. Fix important findings and run covering tests; do not release unmet editing safety or scientific parity requirements.
- [ ] Read current release authority/help/tests, validate skill, run Doctor. Determine collision-free next version from remote tags and releases. Update only required identity files and release notes.
- [ ] Verify clean main and unchanged unrelated worktrees; merge tested branch to main. Run supported `python3 scripts/release/release.py package preview` then `publish preview`; retry identical publish for recoverable interruptions, never replace candidate bytes.
- [ ] Verify signed/notarized DMG, receipt, GitHub prerelease, primary feed and legacy bridge. Report actual verified evidence and limitations.
- [ ] Remove only this completed worktree after successful release, preserving release artifacts and unrelated worktrees. Record final inventory.
