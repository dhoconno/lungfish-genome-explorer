# Overnight Remediation Orchestration

Date: 2026-05-15
Base commit: `5797eb09`

This document tracks the overnight implementation program spawned from
`docs/reviews/2026-05-15-codex-triage.md`.

## Active Wave 1 Worktrees

| Branch | Worktree | Owner | Scope |
|---|---|---|---|
| `codex/wave1-provenance-materialization` | `.worktrees/wave1-provenance-materialization` | Worker A | Managed assembly virtual FASTQ materialization, `lungfish assemble` provenance, CLI derived-bundle audit |
| `codex/wave1-io-correctness` | `.worktrees/wave1-io-correctness` | Worker B | Gzip line preservation, GZI unaligned reads, transparent gzip text readers |
| `codex/wave1-runtime-plugins` | `.worktrees/wave1-runtime-plugins` | Worker C | Plugin pack install atomicity, orphan env handling, database RAM recommendation, conda root validation |
| `codex/wave1-appkit-polish` | `.worktrees/wave1-appkit-polish` | Worker D | Destructive alert flags, textured style replacement, dead MapReads sheet deletion, submenu ellipsis |
| `codex/wave1-boundary-deadcode` | `.worktrees/wave1-boundary-deadcode` | Worker E | OperationCenter file split, unused typealiases, boundary/dead-code implementation specs |

## Review Gates

Each worker must provide:

- A short plan/spec file in `docs/reviews/`.
- The red test command and failure for behavior changes.
- The green test/build command and result after implementation.
- Changed file list.
- Remaining concerns or follow-up issues.

Before integrating any branch:

- Inspect the diff.
- Run the targeted tests reported by the worker.
- Run `git diff --check`.
- Convene an independent review worker when the change is broad or touches
  scientific provenance, IO parsing, or AppKit behavior.

## Next Wave Queue

The next wave should be selected from findings not fully covered by Wave 1:

- GUI Orient and legacy Minimap2 provenance.
- CLI markdup provenance and pipeline parity.
- Missing OperationCenter cancel callbacks.
- CLI exit-code contract adoption.
- VCF structural variant classification and search LIKE escaping.
- Wizard/import sheet shell consolidation.
- Core/App boundary cleanup and dead module deletion after Wave 1 branch review.
