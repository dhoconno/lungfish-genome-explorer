# Genotyping Inspector and MiSeq matrix polish

Approved by the user on 2026-09-13 for autonomous implementation and expert review. This file records the approved product scope; implementation does not require another user design checkpoint.

## Outcome

1. Hide the bottom detail pane in the paired haplotyped MiSeq MHC Haplotype Calls / Genotype Matrix presentation when Genotype Matrix is active, regardless of selection. Keep Haplotype Calls detail/editor fully intact. Other genotype-only MiSeq/ONT/manual-workbench workflows retain their existing behavior.
2. Simplify all five genotyping Inspector tabs: Bundle, Selected Item, Annotations, View, Provenance. Use consistent adaptive typography, alignment, wrapping, and concise control-first groups. Replace routine static explanation with concise hover and explicit accessibility help.
3. Preserve scientific context and operations: selected sample/allele identity, support/status/errors, sample-specific Edit calls sheet, H1/H2 operations, FP/FN, comments/authorship, annotations, filters, colors, and provenance. Dynamic failures, disabled reasons, read-only state, and consequences remain visible where needed for a decision.
4. Remove bespoke last-export history/presentation and static NSSavePanel Excel explanatory accessory. Export retains one action, disabled/in-flight progress, and actionable failures. No persistent success history.
5. Every exported workbook worksheet is editable. Preserve literal values, calls, colors, filters, comments, stable IDs, formatting, annotations, and provenance. Export remains one-way; no Excel reimport or scientific authority change.
6. Verify hidden-pane transitions, all-five-tab narrow-width/scaled-text/accessibility behavior, and workbook fidelity across MiSeq, ONT, and no-haplotype results.

## Boundaries

- Local Debug only. No merge, push, tag, release, cleanup, or other worktree changes.
- Work only in `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/genotype-inspector-polish`, branch `codex/genotype-inspector-polish`, base `3fc2179b8361069d103c40d85aa944c2ba44c7fd`.
- Preserve all scientific QA reports, task ledger, review packages, test logs, and existing caches.
- No inference algorithm, scientific data semantics, or provenance schema changes.
- Every scientific output workflow retains reproducibility provenance: tool/workflow version, exact invocation, resolved options/defaults, runtime, input and final output paths/checksums/sizes, exit status, wall time, useful stderr. Existing export snapshot capture and provenance writing remain authoritative.
- Scope the change to `appliesToHaplotypedMiSeq` plus active Summary / Matrix. The user's clarification expressly preserves the Haplotype Calls editor and excludes the other genotype-only/manual-workbench presentations from this cleanup. No new editor sheet or relocated manual editing UI.
- Do not hide evidence in ONT/general genotype-only or non-matrix views. Do not stop publishing selection to the Inspector when its bottom pane is hidden.

## UI acceptance

- All five existing tabs remain available and use a coherent hierarchy.
- Key/value metadata aligns in a native adaptive layout; it stacks at narrow widths instead of imposing fixed 118/96/62-point label columns.
- Data text remains selectable, wraps without clipping, and follows the existing genotyping text scale where applicable.
- Concise help has explicit accessibility meaning; controls retain names, state/value, keyboard operation, and visible focus. Bold/Italic and color targets must be understandable without their glyph/color alone.
- Provenance remains accessible/copyable; compact presentation must not delete scientific records.
- Mounted Inspector visual QA covers all tabs at 300 and 420 points, plus enlarged text. Use synthetic fixture windows; no real project mutation.

## Review and delivery

Serial implementations receive independent spec and quality review. Astra supervises judgments and conducts an independent final whole-branch review through a fresh agent. Root owns baseline verification and final local Debug packaging. A report must distinguish automated assertions, mounted screenshot inspection, and checks not performed.

## Scope clarification

The user clarified during implementation: “The haplotype editing doesn't happen in the Genotyping Matrix, which is what we should edit here. It IS necessary for the Haplotype Calls pane.” This supersedes the earlier PM/root interpretation that included typed genotype-only MiSeq. No editor-relocation code had been written when the worker received the correction.
