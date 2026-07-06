# Codebase-Quality Refactor — Design

Date: 2026-07-03
Author: Fable (Claude Code)
Status: Approved for planning

2026-07-04 review note: the original planning base was local `main`, but final downstream review
is against `origin/main` @ 56e3a21d. The green-bar definition below was superseded after the
baseline fixes by the clean gate recorded in `docs/reports/2026-07-03-codebase-quality-results.md`.

## Goal

Perform an aggressive but confidence-gated Swift-best-practices refactor of the
entire Lungfish codebase (~502K lines of Swift across 16 SwiftPM targets). The
objectives, in the user's words: follow Swift best practices, avoid redundancy,
and leave the most maintainable and clear codebase possible.

The work runs autonomously (user not in the loop during execution), in small
batches across many phases. Every phase is independently expert-reviewed and
green-bar-verified. Anything that cannot be done confidently is reverted and
recorded in a defer document.

The deliverable is a ready-to-use git worktree containing all applied changes,
per-module defer docs, and a summary report. A downstream LLM will review the
worktree; this project is considered complete once that worktree exists and is
ready to use.

## Non-goals

- New features, behavior changes, or API surface changes visible to users.
- Unrelated refactoring outside the maintainability/clarity/redundancy scope.
- Touching `main`. All work happens in an isolated worktree.
- Changing the known-environmental test baseline (see Green Bar below).

## Where it runs

A dedicated git worktree off `main`:
`../lungfish-worktrees/codebase-quality` on branch `worktree-fable-codebase-quality`.
Main stays untouched. Per project memory, worktrees can build and run the app
freely (the earlier dylib restriction is resolved).

## Ordering — bottom-up the dependency graph

One module per "super-phase", processed bottom-up so cleaned patterns propagate
upward and later diffs never force re-review of a lower layer:

1. `LungfishCore` (71 files, ~28K LOC)
2. `LungfishIO` (139 files, ~66K LOC)
3. `LungfishWorkflow` (272 files, ~124K LOC)
4. `LungfishKit` (47 files, ~11K LOC) — the shared UI/infra kernel
5. Leaf UI modules (9): TwelveSUI, AlignmentUI, AssemblyUI, NvdUI, NaoMgsUI,
   TaxTriageUI, EsVirituUI, GenotypeUI, PhylogeneticsUI
6. `LungfishApp` (409 files, ~188K LOC) — composition roots, largest module
7. `LungfishCLI` (90 files, ~45K LOC)

Rationale: foundations first means best-practice patterns established in Core/IO
propagate upward; and because a change in a leaf can never force a re-review of
Core, each phase diff stays self-contained.

Within each module, batches are ordered largest/most-tangled file first (e.g.
the 5,756-line `GenotypeResultViewController.swift`, the 5,749-line
`ONTBarcodeDemuxGenotypingPipeline.swift`), since those carry the most debt.

## Batch (sub-phase) protocol

A batch is one large/tangled file or a small cluster of tightly related files.
For each batch:

1. **Audit.** An independent expert (swift-expert + code-reviewer lens) produces
   findings against: Swift 6.2 idioms, `@Observable` / `@MainActor` / strict
   concurrency correctness, redundancy/duplication, clarity/naming, access-control
   tightening, file-size/responsibility boundaries, and the binding rules in
   project memory.
2. **Apply.** Make the changes the expert is confident in. Aggressive is allowed:
   split large files, extract types, dedupe helpers, tighten access control, fix
   concurrency anti-patterns, remove dead code. Preserve behavior exactly.
3. **Verify (scoped).** Build the package and run the affected target's tests.
   `swift build --package-path <wt> --skip-update` then scoped
   `swift test --package-path <wt> --skip-update --filter <Target>Tests`.
4. **Independent review.** A *separate* expert team (did not write the change)
   adversarially reviews the batch diff for correctness regressions, hidden
   behavior changes, and rule violations. Concerns → iterate → re-review.
5. **Unresolved handling.** If a flagged concern cannot be resolved confidently,
   **revert that specific change** to keep the batch green and low-risk, and log
   it to the module's defer doc with a concrete suggestion.

## Green bar (module-boundary gate)

Per user decision, test cadence is: scoped tests per batch, and the **full
green-bar suite at each module boundary**. A module is "done" only when:

- XCTest failures ⊆ the 9 known-environmental failures (6
  `GenotypeRealBundleSmokeTests`, 2 `ZhangArtifactCanaryTests`, 1
  `VCFRobustnessTests.testAllRealVCFsFromDownloads` — all macOS TCC
  `Operation not permitted` on external paths), AND
- swift-testing failures = 0.

Only then is the module's work committed and the next module begun. If the full
suite reveals a regression that batch-scoped tests missed, bisect to the batch,
revert or fix, and re-run.

Supersession: after two baseline fixes, the final gate used for the completed branch is a clean
baseline of 9558 XCTest / 487 swift-testing, 0 failures, with the known ONT deadlock suite run in
isolation where noted in the results report.

## Concurrency / build discipline

- `swift` has no `-C` flag; always use `--package-path <wt>`.
- Always `--skip-update` (offline; avoids the `testSRASearch` NCBI flake).
- SwiftPM holds a single `.build/.lock` per checkout. **Serialize all swift
  invocations.** Never run a build while a subagent may be building; dispatch
  implementer subagents one at a time. Check `ps` + `.build/.lock` before
  assuming a hang is a test failure.

## Binding constraints honored throughout

- **Module layering:** a leaf or the kernel may NEVER reference a type defined in
  `LungfishApp` (forbidden cycle). `LungfishApp` importing leaves is fine.
  `LungfishCLI` does NOT import `LungfishKit`.
- **macOS 26 API rules:** no `NSSplitViewController` delegate methods, `lockFocus`,
  `wantsLayer`, `runModal`, `synchronize`; use the approved substitutes.
- **Background→MainActor dispatch:** never `Task { @MainActor in }` from GCD
  background, never bare `DispatchQueue.main.async` to touch `@MainActor` state,
  never `await` `@MainActor` from `Task.detached`. Use the documented patterns.
- **Never save alignment as SAM:** always sorted+indexed BAM.
- **OperationCenter for every op:** call both `.update()` and `.log()`.
- **Docs prose rules** for any doc touched under `docs/user-manual/**` or
  `.claude/agents/*` (no em dashes; bullet cap 5/2).
- **Version-string sites** must not drift (they are not in refactor scope, but if
  touched, all ~8 sites + 2 test expectations bump together).

## Defer docs

`docs/reports/2026-07-03-codebase-quality-defer/` with one Markdown file per
module (`01-core.md`, `02-io.md`, ...). Each entry records: what was
reverted-or-not-attempted, why it couldn't be done confidently, the file/line,
and a concrete suggestion. This is the punch list for the downstream LLM / a
future Opus pass. Defer docs follow the prose rules (no em dashes).

## Final deliverable

- Worktree `worktree-fable-codebase-quality` reviewed against `origin/main`, all module work
  committed, tree clean.
- Per-module defer docs under the reports directory.
- A summary report `docs/reports/2026-07-03-codebase-quality-results.md`:
  modules processed, batches applied, LOC moved, deferrals, green-bar status.
- Complete when the worktree exists, is green-bar-verified, and is ready for the
  downstream LLM.

## Risks and mitigations

- **Regression risk from aggressive refactor.** Mitigated by small batches,
  scoped tests per batch, full green-bar per module, adversarial independent
  review, and revert-on-uncertainty.
- **Long serial test runs.** Mitigated by scoping tests per batch; full suite
  only at module boundaries. The 9 leaf UI modules may share a single full run
  at the end of phase 5 since they are independent siblings, so the full suite
  runs roughly 7 times total across the whole effort.
- **Build-lock contention.** Mitigated by strict serialization of swift
  invocations and one-at-a-time implementer dispatch.
- **Scope creep across the huge App module.** App is processed last and batched
  strictly largest-file-first; if time/tokens run short, remaining App/CLI files
  are recorded in the defer doc rather than rushed.
