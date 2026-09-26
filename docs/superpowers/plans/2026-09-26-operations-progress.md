# Operations Progress Implementation Plan

> **For agentic workers:** Use test-driven development and independent review for the following tasks.

**Goal:** Make operation status, live logs, and supported percentages truthful and visible.
**Architecture:** Separate progress evidence from lifecycle and log activity. Stream complete lines on both tool pipes, preserve diagnostic artifacts, and display a stable operation list with a persistent log inspector.
**Tech Stack:** Swift 6, AppKit, Combine, SwiftPM/XCTest.
**Spec:** `docs/reports/2026-09-26-operations-progress-exploration.md` (user approved implementation).

## Global constraints

- Work only in the issue-33 worktree; retain existing scientific provenance and final payload references.
- Never derive ETA from an arbitrary legacy fraction or stage weight.
- Keep measured percentages; unknown work displays activity and stage information.
- Log capture must not depend on UI retention or successful process exit.
- Preserve existing call sites through additive APIs where practical.

## Review focus

- Continuous logs must not postpone UI rendering or starve other operations.
- Partial UTF-8, CR/LF boundaries, and final unterminated lines must survive streaming.
- Warnings must survive preview truncation; terminal status must survive late events.
- Manual log selection and scroll positions must survive updates and operation switches.
- CLI and direct assembly routes must both report before process exit without damaging provenance.

### Task 1: Progress evidence and outcomes

- [x] Add tests for unspecified versus measured progress, independent rate-based ETA eligibility, phase/total resets, and retained warning outcome.
- [x] Implement additive evidence and presentation APIs on OperationCenter; keep legacy fractions compatible but exclude unspecified values from ETA. Measure byte progress explicitly.
- [x] Run focused OperationCenter tests.

### Task 2: Live subprocess output and durable assembly logs

- [x] Test incremental UTF-8/line framing, both streams arriving before exit, and EOF flush.
- [x] Add stdout callbacks to CondaManager with safe framing and preserve EOF drain ordering.
- [x] Stream managed assembly output to durable diagnostics, including interruption paths, and provide meaningful stage/activity callbacks without fixed 50%.
- [x] Run framing and managed assembly tests.

### Task 3: Operations list and persistent inspector

- [x] Test continuous refresh, latest-line visibility, follow/pause/jump and per-operation state.
- [x] Keep Progress as lifecycle/outcome, show scoped evidence when known, combine elapsed/eligible ETA in Time.
- [x] Add a persistent full-width selected-operation inspector and latest-line preview in every row. Preserve command/output/failure actions.
- [x] Run AppKit regression tests.

### Task 4: Assembly/CLI integration

- [x] Test that assembly CLI status and raw output reach GUI callbacks before termination.
- [x] Reuse shared CLI events on the established progress channel, forwarding log activity independently of fractions.
- [x] Connect direct assembly to scoped evidence and stage recognition; avoid unsupported percentages. Keep final bundle/provenance workflow intact.
- [x] Run focused assembly, CLI, provenance, and UI tests.

### Task 5: Verification and review

- [x] Build and run relevant suites, then the repository unit gate; record any environment or baseline limitations.
- [x] Independent code review and fixes with focused regressions.
- [x] Record final validation and leave reviewable branch changes.

## Execution notes

- User explicitly authorized implementation after reading the exploration. Continue within that scope without another design/plan approval round.
- Tasks 1–3 own separate files and may proceed concurrently; task 4 integrates their additive interfaces.

## Final validation

- Build with tests succeeded. Focused repository gate passed on unchanged source: 323 XCTest cases, zero failures; evidence `.build/gate-logs/gate-20260926-132556-a4e1c3583-40428/gate.result.json`.
- Additional direct runs passed: all 235 LungfishKit tests, 103 workflow tests, 230 selected app tests, 23 CLI/provenance tests, and 13 Operations UI tests. These selections overlap the focused gate.
- Minimum-size screenshot inspected with Details open: Follow latest stays enabled, final line remains visible, and controls fit; no Auto Layout warnings in the focused UI run.
- Broad unit run completed 14,499 XCTest cases and 605 Swift Testing cases, with two initial UI failures. Both affected suites passed after fixes (20 appearance tests and 4 inspector tests). That broad gate remains FAIL because source changed during the run; it is not a clean whole-repository certification. The final stable focused gate above covers the affected suites.
- Independent model, streaming, architecture, and UI reviews completed.
- Actual micromamba 2.9.0 smoke confirmed both streams deliver before process exit. Large real SPAdes/MEGAHIT assemblies were not run. No unsupported assembler percentage adapter was added.
- Worktree retained for review; no push or merge performed.
