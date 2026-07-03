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

## Per-module summary

| Module | Batches applied | LOC delta | Deferrals | Green-bar |
|---|---|---|---|---|
| LungfishCore | - | - | - | - |
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
