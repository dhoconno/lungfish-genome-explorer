# Codebase-Quality Refactor — Results

Date: 2026-07-03
Branch: `worktree-fable-codebase-quality` (off `main` @ 810502e6)
Spec: [design](../superpowers/specs/2026-07-03-codebase-quality-refactor-design.md)
Plan: [plan](../superpowers/plans/2026-07-03-codebase-quality-refactor.md)

## Status: IN PROGRESS

## Green-bar baseline

The first baseline run on untouched `main` HEAD surfaced TWO pre-existing
non-environmental failures (a concurrency-lint failure in ViewerViewController and
an MHC reference-bundle external-open routing regression). Per user decision both
were fixed first (see [defer 00-baseline-fixes](2026-07-03-codebase-quality-defer/00-baseline-fixes.md)).

Post-fix clean baseline (this is the gate every phase is measured against):

- XCTest: 9558 executed, **0 failures**, 24 skipped (the environmental external-path
  tests skip gracefully when volumes/paths are absent).
- swift-testing: 487 tests in 67 suites, **0 failures**.

Green from here = 0 non-environmental XCTest failures AND swift-testing = 0.

## Batching strategy (tiered, adopted after the first 3 Core files)

To cover ~1100 files tractably while keeping every confidence gate, batches are
tiered by file size:

- **Big / tangled files (>~800 lines): full solo treatment** — one audit agent,
  one implementer, build + scoped tests, one independent adversarial reviewer,
  revert-on-uncertainty, its own commit.
- **Mid / small files (<~800 lines): clustered** — grouped by directory/concern
  into one audit + implement + build + scoped-test + independent-review + commit
  cycle per cluster. Same gates, fewer round-trips.
- **File splits** of large files are batched into a dedicated mechanical
  `git mv`/extension pass per module (pure relocation, no logic change), reviewed
  as one diff.

Each module still ends with a FULL green-bar gate before the next module begins.

## Per-module summary

| Module | Batches applied | LOC delta | Deferrals | Green-bar |
|---|---|---|---|---|
| LungfishCore | IN PROGRESS: 21 files across 5 committed batches | net ~ -190 lines | rich (see 01-core.md) | scoped LungfishCoreTests 1158/0 after every batch; module-boundary FULL green-bar NOT yet run |
| LungfishIO | - | - | - | - |
| LungfishWorkflow | - | - | - | - |
| LungfishKit | - | - | - | - |
| Leaf UI modules (9) | - | - | - | - |
| LungfishApp | - | - | - | - |
| LungfishCLI | - | - | - | - |

## How to review (for the downstream LLM)

1. Whole diff: `git diff main...worktree-fable-codebase-quality`.
2. Per-module rationale + everything deferred: `docs/reports/2026-07-03-codebase-quality-defer/*.md`.
3. Each batch is its own commit (`refactor(<module>): <file> — <summary>`), so the
   history reads as a reviewable sequence.
4. Green-bar was enforced at every module boundary; the final full-suite result is
   recorded above.
