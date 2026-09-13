# Biomere2 MHC Preview Repair Implementation Plan

> **For agentic workers:** Execute the independent tasks below with delegated implementation and Astra review before integration.

**Goal:** Repair initial MHC slot ordering, propagate false-positive evidence review immediately, restore filtered Excel exports, and simplify the haplotype evidence pane.

**Architecture:** Keep raw scientific evidence immutable. Derive reviewed analyzer input and deterministic sample-wide slot presentation, then apply explicit user call overrides last. Export the visible matrix's semantic sample and row identities rather than assuming one worksheet layout.

**Tech stack:** Swift/AppKit/SwiftUI, LungfishIO analyzer, CLI Python/openpyxl workbook projection, XCTest.

**Spec:** User report of 11 September 2026 and read-only inspection of the supplied cohort project. Private fixture data is not committed.

## Constraints and evidence

- Work only in `codex/mhc-biomere-review`; leave all unrelated worktrees and the supplied project unchanged.
- Preserve immediate annotation saving, replay/audit records, export provenance, and authoritative manual H1/H2 assignments.
- Current ordering examines each label independently. An M2 family spanning all five loci can incorrectly alternate between H1 and H2 when the other chromosome has M1 and M3 regions.
- The reported minor DQB variant exceeds 1% of its locus-specific reads; this report does not authorize changing scientific threshold definitions. Review exclusions must use the full allele identifier.
- Matrix review publication reloads visual annotations but does not recompute the live analyzer, which still consumes raw calls.
- Confirm marks both locus slots confirmed, audits this, and advances the review queue. Skip only navigates. Neither commits haplotype editor changes.
- The supplied reference defines the reported minor DQ family using a separate DQA diagnostic. Excluding DQB alone correctly leaves that call supported. Tests must verify exact reviewed evidence exclusion and must not force a call change while an independent required marker remains.

## Task 1: Sample-wide intact-family ordering (Astra)

Files: `Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift`, `Tests/LungfishIOTests/GenotypeHaplotypeAnalyzerTests.swift`.

- [x] Add a synthetic five-locus regression: M1/M2 at A/B and M2/M3 at DR/DQ/DP must yield M2 in H1 throughout.
- [x] Include homozygous/single-call anchors, two intact families (numeric tie-break), and no coherent intact family (retain deterministic local ordering).
- [x] Run the focused analyzer tests against old implementation and confirm ordering failures.
- [x] Compute the intersection of unambiguous single-family labels across informative canonical MHC loci. A single reported haplotype with H2 `-` contributes that family; unknown/error calls do not establish a family. Choose the lowest numbered candidate when multiple remain. Place that family in H1 at each applicable heterozygous locus; preserve existing per-locus intact-vs-recombinant and numeric fallback otherwise.
- [x] Preserve matched-definition order and record the ordering rationale without changing called haplotypes or raw evidence.
- [x] Run focused tests. Manual override projection remains downstream and authoritative.

## Task 2: Reviewed evidence drives current calls (parent)

Files: shared IO evidence projection helper/analyzer, `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`, corresponding IO/UI regression tests and CLI/workbook analysis consumers.

- [x] Reproduce FP save/reopen behavior with a small synthetic analyzer fixture representing a minor contaminant.
- [x] Apply FP exclusion using exact sample, canonical source locus, and full genotype identity; do not modify retained read counts or synthesize reads for FN annotations.
- [x] Recompute after successful review mutations and on initial load. Refresh effective calls, haplotype matrix/band, selected evidence, and exports before asynchronous workbook publication.
- [x] Clear FP restores evidence; unrelated samples/loci remain unaffected. Manual overrides still win over recalculated defaults.
- [x] Ensure CLI/current workbook and GUI consume the same reviewed scientific input and persist reproducibility provenance for derived outputs.

## Task 3: Filtered Pivot workbook identity (delegated)

Files: `Sources/LungfishCLI/Commands/GenotypeExportPivotXlsxSubcommand.swift`, CLI filtered pivot tests.

- [x] Inspect original/current worksheet headers on the supplied project read-only and reproduce the projected-sample mismatch on a copy.
- [x] Resolve actual worksheet sample header locations with exact semantic identities, supporting both original and updated workbook layouts.
- [x] Verify visible row/sample ordering, FP/FN styles and native comments, zero/blank cells, candidates, and explicit missing-identity errors.
- [x] Exercise a real current-workbook update followed by filtered export and compare cells with the viewport projection. Preserve workbook provenance and stable annotation identities.

## Task 4: Evidence pane simplification (delegated)

Files: `Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift`, UI evidence tests.

- [x] Hide Confirm/Skip from normal Haplotype Calls browsing. Preserve them only where an explicit review queue is active and the actions apply.
- [x] Keep immediate H1/H2 swap/edit controls clear and available; inspect other visible elements for duplicate or misleading save/review actions.
- [x] Verify actual UI behavior and report what was removed and why.

## Integration and release (parent, Astra review)

- [x] Run focused analyzer, annotation, projection, and Excel regressions once changes stabilize; use the supplied cohort only on a temporary copy for smoke checks.
- [x] Astra reviews the complete diff and evidence, including manual override authority and reopen/export consistency.
- [ ] Merge the tested worktree to main, create the next version using the release skill, package/publish the GitHub Preview, and verify signature, notarization, artifacts, and update feeds.
- [ ] Remove only this completed worktree after successful release. Report final worktree inventory and release link.

## Review evidence

- Astra reproduced the intact-ordering defect with three synthetic tests (seven expected assertions failing against old ordering).
- The actual current-workbook transform retained all 26 exact sample identities and 169 allele rows, rendered the saved false-positive cell as bracketed italic text, and preserved values/comments on all seven other sheets. The original workbook checksum was unchanged.
- Synthetic export checks exercise FP/FN and native comments, updated haplotype values/colors, manual override authority, and rejection of ambiguous sheet/allele identities.
- Release contract/identity/note preflight tests: 27 passed. Release signing setup refreshed successfully.
- Cohort diagnostic harness is temporary and must be removed before commit; no private cohort fixture is committed.

- Expanded verification: 341 tests passed, zero failures, including the temporary read-only cohort check. Full 26-sample analyzer time was 2.40 seconds in Debug after scoped token preparation (previously about 20 seconds per pass).
- Matcher preparation equivalence, fallback, nested/throwing scope restoration, and concurrent contexts passed. The temporary cohort harness was removed after verification.
