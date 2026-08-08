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
  - **D1 Multi-bundle inventory:** for each tool invocation surface (classification wizards, assembly, alignment/mapping, orient, genotype, phylogenetics, NVD, 12S, EsViritu, TaxTriage, NAO-MGS, BLAST, primer trim), record what happens today when N>1 bundles are selected: disabled? first-only? silent iterate? error? Include file:line of the invocation path and the wizard used. **D1b:** for the same tools, inventory CLI multi-input support (which commands accept multiple inputs, and whether any pooled mode exists) — CLI parity is a binding process rule.
  - **D2 Responsiveness:** main-thread sync I/O, missing async/debounce, O(N²) loops on hot paths, redundant re-computation, missed generation counters, blocking dialogs. Named Swift-6 smells finders must explicitly hunt: actor/MainActor hops inside loops (serial `await` per iteration where a task group belongs), `@MainActor` over-isolation of pure logic (parsers/transforms isolated only because their enclosing type is), unbounded `NSOutlineView`/`NSTableView` `reloadData()` on high-frequency or >100-row paths (classify every call site targeted-vs-blanket), and unmanaged/uncancelled stored `Task` handles (stale work keeps burning CPU even when generation counters discard its result).
  - **D3 Correctness/rough edges:** race conditions, banned patterns from memory (Task{@MainActor} from GCD, `%s` in String(format:), SAM-not-BAM saves, missing OperationCenter log/update pairs), error handling gaps, stale-result overwrites. Also: `@unchecked Sendable` audit (justify each or propose a narrower fix), continuation double-resume/non-resume on error paths, and cross-reference `runModal`/deprecated-API hits against `docs/…/macos26-api-rules` (memory) before treating as novel findings.
  - **D4 Best practices/organization:** module-boundary violations (leaf/kernel referencing LungfishApp), duplicated helpers that belong in LungfishKit, dead code, deprecated macOS 26 API use, oversized files with tangled responsibilities. **Seeded candidate finding:** duplicated materialization logic across `MaterializationPipeline` (actor, bounded concurrency), `AssemblyConfigurationViewModel`'s sequential loop, `FASTQDerivativeService+Materialization`, and CLI's `FASTQCLIMaterializer`/`CLISequenceInputMaterialization` — consolidation candidate.
- **Findings schema (structured output):** `{dimension, file, line, title, description, userVisible: bool, severity: high|med|low, suggestedFix, estimatedEffort: S|M|L}`.
- **Dedup** by file+line+title in script code.
- **Adversarial verify (Sonnet, ~top 50–60 D2/D3/D4 findings by severity/user-visibility):** 2 refuters per finding; a finding survives if ≤1 refutes. D1/D1b inventory rows are facts, not claims — they bypass both verification and the top-N selection entirely and flow straight to the ranking panel as Phase 2 scoping inputs, never competing with D2–D4 findings for verify slots.
- **Expert ranking panel (Opus/Fable-tier, 3 judges):** rank surviving findings into an ordered fix list under the priority principle, estimate cost, and draw the budget cutline. Output: `docs/reports/2026-08-08-repo-audit-findings.md` + machine-readable JSON.

## Phase 2 — Multi-Bundle Consistency Feature

- **Shared UI:** `MultiBundleRunModePicker` in `LungfishKit` — a standard wizard section shown only when N>1 inputs arrive: radio "Run separately per bundle (N results)" / "Combine all inputs, run once (1 result)". Default: per-bundle. Tools where combining is scientifically wrong may pass a flag to hide the combine option (expert panel decides per tool; deviation documented in the findings report).
- **Shared execution helper** in `LungfishKit` (next to `OperationCenter`, its natural neighbor — `LungfishWorkflow` sits below the kernel and cannot reference OperationCenter types): given a config with mutable `inputFiles`, either fan out N sequential pipeline runs (each with its own OperationCenter operation, named per bundle) or pool inputs into one run. Only pure, framework-free parts (config-splitting, input-pooling logic) may be placed in `LungfishWorkflow`. Materialization stays owned by `LungfishApp` and the helper receives it as an injected `async` closure (the established `on...Requested` inversion pattern), never a direct call. **The injected closure must compose over the existing `MaterializationPipeline` actor (bounded concurrency) — not a new hand-rolled sequential loop** (the codebase already has ≥4 materialization paths; do not add a fifth). Pooling happens **after** materialization resolves, so virtual bundles contribute full reads, never `preview.fastq`. Pooled FASTQ concatenation routes through the existing `FASTQBundleMergeService`, never new concatenation code, and must respect paired-end structure (pool N `fastq1`s and N `fastq2`s separately; note read-ID collisions across samples). Per-tool config shapes vary — `inputFiles` is not universal (Assembly uses `forwardReads`/`reverseReads`/`unpairedReads`) — so the helper's protocol must abstract the input fields, not assume one flat array. Temp cleanup is scoped per materialization child (each child cleans its own temps on throw/cancel), not one outer `defer`.
- **Adoption rule (closed-form):** adopted = every D1 surface where selecting N>1 bundles is currently possible in the GUI, minus combine-hidden exceptions the expert panel documents. The ranking panel's output must list the adoption set explicitly.
- **CLI parity:** the CLI accepts multiple inputs where the GUI does; a `--combine` flag selects pooled mode. Per the Project Lead process, every op goes through OperationCenter with both `update()` and `log()`.
- **Tests:** one behavioral test per adopted wizard (mode plumbed to config), plus helper unit tests for fan-out vs pooling incl. the materialization interplay. Additional requirements: `MultiBundleRunModePicker` gets a unit test in `LungfishKit`'s test target; one test verifies the Operations panel performs targeted (not reload-all) updates when N fan-out operations land concurrently; the CLI `--combine` flag gets a `CLIRegressionTests` entry (beware the version-string brittleness noted in memory if help text changes). Any commit touching actor/Sendable boundaries must build with **zero new strict-concurrency warnings** — silencing a warning with `@unchecked Sendable` instead of fixing isolation is a regression even with green tests. Race-condition fixes require a deterministic regression test (injected delay, controlled Task ordering, or generation-counter assertion), not a timing-dependent flake.

## Phase 3 — Ranked Fix Execution

- Fixes executed in the panel's order by implementation subagents: Sonnet for contained multi-file work, Haiku for mechanical single-file edits. TDD per the process rules (failing test first where a bug is being fixed).
- **Build serialization:** exactly one `swift build`/`swift test` at a time in this worktree. Implementers run tests scoped to affected targets (`--filter`); Fable runs the integrating checks.
- **Review gate:** Fable reviews every diff before it is committed; each fix is an atomic commit referencing its finding ID.
- **Budget checkpoints:** after Phase 1 and after each third of the fix list **by cumulative estimated effort** (S=1, M=3, L=8 points — not finding count, so a few L items can't silently blow the budget), the Fable orchestrator re-estimates remaining credit and drops below-cutline work rather than risk an unfinished tree.

## Phase 4 — Verification & Handoff

- Full suite run; green bar must match **the Phase 0 recorded baseline** (the specific failure set recorded then, including the worktree-specific KF015279 failure — no new failures relative to that record).
- Findings report updated with fixed/deferred status per finding.
- Branch left merge-ready with a summary report at `docs/reports/2026-08-08-repo-review-results.md`; final message to the user covers outcomes, deferred items, and budget spent.

## Error Handling

- A finder/verifier that dies is dropped (results filtered), never retried more than once.
- An implementer whose diff fails review or breaks the build gets one revision cycle; after that the finding is deferred, the working tree reset to the last good commit.
- If the baseline itself is red beyond known-environmental failures, fixing the baseline becomes the first ranked item.

## Risks

- **SwiftPM lock contention** — mitigated by strictly sequential phases (no overlap: the "hard checkpoints" in the header and build serialization are the same guarantee), the no-build rule for finders, and serialized implementer builds within Phase 3.
- **Audit overruns budget** — finder fleet is fixed-size (no loop-until-dry); ranking panel enforces a cutline.
- **Refactor churn conflicts with fix commits** — Phase 3 orders work module-by-module where possible; D4 refactors land last.
