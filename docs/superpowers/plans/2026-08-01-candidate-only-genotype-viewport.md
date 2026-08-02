# Candidate-Only Genotype Viewport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox notation for traceable execution.

**Goal:** Open genotype-only bundles with reviewable reference or candidate rows in the native genotype matrix even when the conventional call summary is empty.

**Architecture:** Define one read-only capability on `ONTGenotypeResultBundleData` that represents whether the bundle has rows the native matrix can review. Use that shared capability in both the app-level workbook fallback and the genotype controller's initial Matrix/Outline selection so the two routing decisions cannot disagree.

**Tech Stack:** Swift, AppKit, XCTest, Swift Package Manager.

---

### Task 1: Specify the shared matrix-content capability with tests

- [x] Add focused `LungfishIOTests` coverage proving the capability is true for conventional calls and for a nonempty reviewable-row catalog, and false when both are empty.
- [x] Run the focused tests and confirm they fail because the capability is not implemented.
- [x] Add `hasNativeGenotypeMatrixContent` to `ONTGenotypeResultBundleData`.
- [x] Re-run the focused tests and confirm they pass.

### Task 2: Route candidate-only bundles to the native viewport

- [x] Extend the app routing fixture so a genotype bundle can include an attested reviewable-row catalog.
- [x] Add an app regression test proving an empty-call, catalog-backed bundle opens the native Matrix view rather than workbook Quick Look.
- [x] Preserve the existing regression test proving a truly empty legacy bundle still opens the workbook.
- [x] Update `MainSplitViewController.shouldPreviewPrimaryWorkbook` to use the shared capability.
- [x] Run the focused app routing tests.

### Task 3: Keep the genotype controller's default view consistent

- [x] Add a genotype UI regression test for an empty-call result with a nonempty reviewable-row catalog.
- [x] Confirm the test initially selects Outline.
- [x] Update `GenotypeResultViewController.defaultSummaryViewMode` to use the shared capability for genotype-only results.
- [x] Run the focused genotype viewport tests and confirm the candidate-only result starts in Matrix while haplotyped behavior is unchanged.

### Task 4: Verify and package the change as a reviewable branch

- [x] Run the focused IO, app-routing, and genotype-viewport tests.
- [x] Run `swift build` and `git diff --check`.
- [x] Record any unrelated pre-existing test failures separately rather than changing their behavior.
- [x] Review the final diff for scope, then commit the implementation on `codex/candidate-only-genotype-viewport`.

Verification note: the candidate-routing suite passes 15/15 tests and the package builds. The broad suite retains the same three pre-existing `GenotypeResultDisplaySectionTests` failures reproduced on unchanged `main`; they concern the expected Summary versus Audit inspector lens and are outside this routing fix.
