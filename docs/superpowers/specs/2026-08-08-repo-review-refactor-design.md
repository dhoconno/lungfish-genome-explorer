# Repo-Wide Performance & Best-Practices Review and Refactor — Design

**Date:** 2026-08-08
**Branch:** `worktree-fable-repo-review`
**Mode:** Fully autonomous (user waived in-loop review; expert agents staff all review gates)
**Budget:** ~85% of a weekly Fable credit, ~20 hours wall clock. Hard checkpoints between phases.

## Goals

1. A streamlined, internally consistent codebase that follows Swift 6.2 best practices and is organized for scalable growth.
2. Consistent multi-bundle tool invocation: every tool wizard that receives multiple selected bundles offers both "Run separately per bundle" and "Combine all inputs, run once."
3. Maximum user-facing responsiveness: eliminate avoidable main-thread stalls and slower-than-necessary steps.
4. Bugs and rough edges found during the audit get fixed, ranked user-visible-first.

## Non-Goals

- Style-only churn in stable code that no finding justifies.
- New features beyond the multi-bundle consistency work.
- Merging to `main` (branch is left merge-ready; the user merges).

## Priority Principle

User-visible first: (1) bugs and responsiveness issues users feel, (2) the multi-bundle consistency feature, (3) internal best-practices/organization refactors as budget allows.

## Phase 0 — Setup (this document)

- Isolated worktree `worktree-fable-repo-review` under `.claude/worktrees/`.
- Baseline green bar recorded before any change. Green bar = XCTest failures ⊆ the 9 known environmental failures (plus `GenBankReaderTests.testReadKF015279`, which fails in worktrees by design) AND 0 swift-testing failures.

## Phase 1 — Audit Workflow

One `Workflow` run, scaled up per user request (cheaper parallel agents, larger fleet):

- **Finder fleet (~24–32 agents, Sonnet, low/medium effort)**, each scoped to one dimension × one module slice. Finders are **read-only and must not build** (single SwiftPM lock per checkout; the baseline test run owns it).
  - **D1 Multi-bundle inventory:** for each tool invocation surface (classification wizards, assembly, alignment/mapping, orient, genotype, phylogenetics, NVD, 12S, EsViritu, TaxTriage, NAO-MGS, BLAST, primer trim), record what happens today when N>1 bundles are selected: disabled? first-only? silent iterate? error? Include file:line of the invocation path and the wizard used.
  - **D2 Responsiveness:** main-thread sync I/O, missing async/debounce, O(N²) loops on hot paths, redundant re-computation, missed generation counters, blocking dialogs.
  - **D3 Correctness/rough edges:** race conditions, banned patterns from memory (Task{@MainActor} from GCD, `%s` in String(format:), SAM-not-BAM saves, missing OperationCenter log/update pairs), error handling gaps, stale-result overwrites.
  - **D4 Best practices/organization:** module-boundary violations (leaf/kernel referencing LungfishApp), duplicated helpers that belong in LungfishKit, dead code, deprecated macOS 26 API use, oversized files with tangled responsibilities.
- **Findings schema (structured output):** `{dimension, file, line, title, description, userVisible: bool, severity: high|med|low, suggestedFix, estimatedEffort: S|M|L}`.
- **Dedup** by file+line+title in script code.
- **Adversarial verify (Sonnet, ~top 50 by severity/user-visibility):** 2 refuters per finding; a finding survives if ≤1 refutes. D1 inventory rows are facts, not claims — they skip verification.
- **Expert ranking panel (Opus/Fable-tier, 3 judges):** rank surviving findings into an ordered fix list under the priority principle, estimate cost, and draw the budget cutline. Output: `docs/reports/2026-08-08-repo-audit-findings.md` + machine-readable JSON.

## Phase 2 — Multi-Bundle Consistency Feature

- **Shared UI:** `MultiBundleRunModePicker` in `LungfishKit` — a standard wizard section shown only when N>1 inputs arrive: radio "Run separately per bundle (N results)" / "Combine all inputs, run once (1 result)". Default: per-bundle. Tools where combining is scientifically wrong may pass a flag to hide the combine option (expert panel decides per tool; deviation documented in the findings report).
- **Shared execution helper** in `LungfishWorkflow` (or kernel if UI-coupled): given a config with mutable `inputFiles`, either fan out N sequential pipeline runs (each with its own OperationCenter operation, named per bundle) or pool inputs into one run. Pooling happens **after** `materializeInputFilesIfNeeded()` so virtual bundles contribute full reads, never `preview.fastq`; materialized temps cleaned up via `defer`.
- **CLI parity:** the CLI accepts multiple inputs where the GUI does; a `--combine` flag selects pooled mode. Per the Project Lead process, every op goes through OperationCenter with both `update()` and `log()`.
- **Tests:** one behavioral test per adopted wizard (mode plumbed to config), plus helper unit tests for fan-out vs pooling incl. the materialization interplay.

## Phase 3 — Ranked Fix Execution

- Fixes executed in the panel's order by implementation subagents: Sonnet for contained multi-file work, Haiku for mechanical single-file edits. TDD per the process rules (failing test first where a bug is being fixed).
- **Build serialization:** exactly one `swift build`/`swift test` at a time in this worktree. Implementers run tests scoped to affected targets (`--filter`); Fable runs the integrating checks.
- **Review gate:** Fable reviews every diff before it is committed; each fix is an atomic commit referencing its finding ID.
- **Budget checkpoints:** after Phase 1 and after each third of the fix list, re-estimate remaining credit; drop below-cutline work rather than risk an unfinished tree.

## Phase 4 — Verification & Handoff

- Full suite run; green bar must match baseline (no new failures).
- Findings report updated with fixed/deferred status per finding.
- Branch left merge-ready with a summary report at `docs/reports/2026-08-08-repo-review-results.md`; final message to the user covers outcomes, deferred items, and budget spent.

## Error Handling

- A finder/verifier that dies is dropped (results filtered), never retried more than once.
- An implementer whose diff fails review or breaks the build gets one revision cycle; after that the finding is deferred, the working tree reset to the last good commit.
- If the baseline itself is red beyond known-environmental failures, fixing the baseline becomes the first ranked item.

## Risks

- **SwiftPM lock contention** — mitigated by the no-build rule for finders and serialized implementer builds.
- **Audit overruns budget** — finder fleet is fixed-size (no loop-until-dry); ranking panel enforces a cutline.
- **Refactor churn conflicts with fix commits** — Phase 3 orders work module-by-module where possible; D4 refactors land last.
