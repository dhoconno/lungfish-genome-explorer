# Legacy Dimer Salvage Implementation Plan

> **For agentic workers:** Use subagent-driven development: Luna implementation and CLI evaluation, Astra contract review.

**Goal:** Add bounded sequential dimer salvage to the preserved legacy candidate pool.

**Architecture:** A small opt-in helper runs after the unmodified legacy strict selector and before publication, using original PrimerPair/Panel objects. Legacy-only options and compact audit records stay separate from allele search.

**Tech Stack:** Existing Python/Typer CLI, native dimer kernel, legacy Panel/MatchDB and provenance utilities.

**Spec:** ../specs/2026-09-16-legacy-dimer-salvage.md

## Global constraints

Original strict panel is immutable during salvage. No new chemistry/candidate generation, no allele catalog, no GUI or runtime installation. Preserve all scientific provenance. Tests/runs use isolated mutable native worktree; saved legacy worktree and benchmark outputs are read-only.

## Task 1 — Native legacy salvage (Luna)

Likely files: new `primalscheme3/panel/legacy_salvage.py`; focused options module if useful; integration in `panel_main.py`, CLI/config handling, and optional backward-compatible cutoff override in `core/multiplex.py`. Agent must map precise interfaces before editing and avoid broad refactoring.

- [ ] Inspect pairing, strict selection, pool admission and publication seams; confirm retained pool and exact dimer kernel semantics.
- [ ] Write failing focused tests for monotone rescue, untouched baseline, cumulative budgets, threshold boundary/floor, unchanged nondimer checks, sequence deduplication and reference interval gain.
- [ ] Implement legacy-only options with fail-closed validation and no change to existing off-mode or allele behavior.
- [ ] Implement finite sequential additions using retained PrimerPair objects and bounded numerical conflict recording; stable candidate/stage records.
- [ ] Integrate distinct raw-input copies and existing success/failure provenance, plus fresh final stage validation and primary/secondary coverage reports.
- [ ] Add CLI help/docs, focused integration tests and strict-equivalence test; commit owned changes after focused tests pass.

## Task 2 — Review and real-data CLI gate (Luna under Astra review)

- [ ] Astra reviews scientific invariants, counter boundaries, native dimer parity and output/provenance truthfulness.
- [ ] Freeze a clean candidate commit; run one appropriate suite, fix only demonstrated defects.
- [ ] Run ordinary legacy control and new opt-in salvage on original A1+A2, two pools, normal chemistry, original gap/MatchDB settings; verify exact saved CLI settings before interpreting results. Bound total run time/memory/disk and preserve interrupted receipts.
- [ ] Verify strict-stage scientific equivalence and all final stage invariants; compare saved reference BED unions using the established geometry evaluator.
- [ ] Save compact stage/candidate status reports, baseline comparison, provenance and limitations. Stop without a broad sweep or full11 launch.
