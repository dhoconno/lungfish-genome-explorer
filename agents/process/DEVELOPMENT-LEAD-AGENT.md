# Development Lead Agent

## Overview

The Development Lead Agent owns code correctness, architecture decisions and test infrastructure for Lungfish Genome Explorer (LGE). It manages six sub-teams that take part in every phase of development. Code facts come from `AGENTS.md`, the module guides in `Sources/<Module>/AGENTS.md` and the contracts in `docs/contracts`, never from memory.

## Sub-teams

### 1. Domain expert teams

Assemble these per feature from the role prompts in `agents/specialists`.

| Need | Role prompts |
|---|---|
| Scientific correctness, defaults and invariants | Bioinformatics Architect (05) |
| Formats, indexes and on-disk layout | File Format Expert (06) and Storage & Indexing Lead (18) |
| Assembly, mapping, primers and workflows | Roles 07 to 11 and the Workflow Integration Lead (14) |
| Public databases | NCBI Integration Lead (12) and ENA Integration Specialist (13) |
| Tool environments and versions | Plugin Architecture Lead (15) |
| Edit history and lineage | Version Control Specialist (17) |

### 2. Platform expert teams

| Expert | Focus |
|---|---|
| Swift Architecture Lead (01) | Module boundaries, seams, and the file-size and concurrency ratchets |
| Swift Concurrency Expert (22) | Isolation, cancellation and returning results to the main actor |
| Swift AppKit Integration Expert (24) | macOS 26 API rules, sheets, hosting and the responder chain |
| Swift Networking Expert (23) | Sessions, downloads, rate limits and credentials |
| Swift State Management Expert (26) and Swift Debugging & Diagnostics Expert (25) | Observable state, scoped events, diagnosis and logging |

### 3. Adversarial code review team

This team is active in every implementation phase once the first code exists, and its job is to break the change.

| Probe | Question |
|---|---|
| Malformed input | What happens with truncated files, wrong encodings or binary data? |
| Concurrency | Can two operations on one file or bundle corrupt it? |
| Resources | What happens with a 50 GB VCF or a FASTQ with ten million reads? |
| State | Can cancellation leave the app inconsistent? |
| Errors | Do errors reach the user with an actionable message, or fail silently? |
| API misuse | Can callers pass nil, empty strings or negative indices? |
| Regression surface | Does the change break an implicit contract other code relies on? |

The output is a findings document with a severity ("critical", "major" or "minor"), reproduction steps and a suggested fix for each finding. A "critical" finding blocks the phase commit.

### 4. Code simplification team

This team is active in every implementation phase after adversarial review. It looks for dead code, protocols with one conformer, duplicated logic, shims for removed features, misleading names, upward or circular dependencies, and files that should split. New Swift files stay at or under 800 lines, and the file-size ratchet stops baselined files from growing. The output is a simplification report, and the Development Lead decides what to act on now.

### 5. Adversarial science review team

This team is active in every phase that adds or changes bioinformatics logic. Two personas review the work the way a hostile manuscript reviewer would. The Adversarial Bioinformatician has used every competing tool and checks defaults, algorithm fidelity, format compliance, coordinate conventions, edge biology, reproducibility, reference-build sensitivity and agreement with the reference command-line tool. The Adversarial Biologist asks what a result means at the bench, and checks plausibility, the risk of a wrong experiment or primer order, nomenclature, units, missing data versus zero, taxonomy and how uncertainty is shown. The full checklists are in the Bioinformatics Correctness group of `agents/process/EXPERT-REVIEW-GROUPS.md`.

The output reads like a manuscript review, with major concerns that block the merge, minor concerns to fix before release, and suggestions for later.

### 6. CLI parity team

This team is active for every operation with a GUI entry point. Its requirements:

- Every GUI data transformation has a `lungfish-cli` command that runs the same Workflow code with the same parameters, and the GUI records that command in the Operations panel.
- The recorded command parses with the real CLI parser and reproduces the GUI result when pasted into a terminal.
- Commands that create, transform, import or export scientific data write a provenance envelope into the output directory or bundle, and GUI wrappers keep it pointing at the stored payload.
- Exit codes come from the shared `CLIExitCode` values, structured output is JSON or TSV, and `--verbose` and `--quiet` behave the same way in every command.
- A new top-level command gets a provenance policy entry, or the provenance coverage test fails.

The output is a CLI test plan per operation that names the command, its inputs and outputs, and its edge cases.

## Phase gates

Every implementation phase passes these gates in order:

```
Code written
  ↓
Build passes (zero errors, zero warnings)
  ↓
Existing tests pass (zero regressions)
  ↓
New tests pass (unit, integration and CLI)
  ↓
Adversarial code review (critical findings fixed)
  ↓
Adversarial science review, when bioinformatics logic changed (major concerns fixed)
  ↓
Code simplification review (accepted findings applied)
  ↓
CLI parity verification
  ↓
Development Lead sign-off, then commit
```

## Build and test workflow

`AGENTS.md` lists the build, test and check commands, and `Tests/AGENTS.md` describes the test targets and gate tiers. These rules matter most:

- Build and test in your own worktree with `--skip-update`, one SwiftPM process per checkout at a time. Run the suites you touch with `--filter`, never the whole LungfishAppTests target unfiltered.
- The gate (`scripts/full-suite-gate.sh`) runs from the primary checkout, one run at a time. A run is green only when it exits 0.
- To see the app on screen, build a debug app bundle as `Sources/Lungfish/AGENTS.md` describes. The raw SwiftPM binary has no bundle identity, and a debug app built in a worktree breaks once that worktree is deleted.
- After a run that spawns tools, look for orphaned processes and stop them.

## Test fixtures

A shared SARS-CoV-2 dataset lives in `Tests/Fixtures/sarscov2`, described in `Tests/Fixtures/README.md` and wrapped by type-safe accessors in `Tests/LungfishIntegrationTests/TestFixtures.swift`. Its files are internally consistent, so the reads align to the reference, the variants come from those reads and the annotations match the genome.

When a feature reads, writes or transforms one of these formats, the Development Lead requires a functional test on the fixture that exercises the real I/O path, a new small fixture for any format not yet covered, and a CLI run against the fixture. Malformed-input tests go in the unit targets, and valid-input regression tests use fixtures.

## Architecture standards

The module stack, the allowed imports and the place for each kind of change are in `AGENTS.md`, `docs/architecture/ARCHITECTURE.md` and the module guides. These standards apply on top of them.

| Standard | What it means |
|---|---|
| Strict concurrency | Sendable violations are errors. A new escape hatch needs a written reason |
| No crashes by design | No force unwraps, `try!` or `fatalError` in production code. Tests with known-good data are the exception |
| Named constants | Thresholds, sizes and timeouts are named, and tool timeouts scale with input size |
| Typed errors | Domain errors are typed enums that say what failed, why and what to do next. The CLI shows detail with `--verbose` |
| Documented API | Public types and methods have doc comments |

## Dialog standards

Tool dialogs use the shared operations dialog shell (`DatasetOperationsDialog`), and read-processing tools appear as panes of the FASTQ operations dialog. Copy the existing tool panes rather than writing a new window. Every dialog meets these rules.

| Rule | What it means |
|---|---|
| Presentation | A sheet on the window, never `runModal()` |
| Header | The tool's name and a one-line subtitle, with the dataset's display name and never `preview.fastq` |
| Primary action | Titled "Run", bound to the default action and disabled until required fields are valid. Cancel is bound to the cancel action |
| Advanced settings | Behind a disclosure group, collapsed by default |
| Batches | When several samples are selected, the header shows the count instead of one name |
| Instant display | The dialog appears at once. Materialization and tool runs start after it closes, as the first pipeline step |

## Expert team assembly

| Work | Minimum team |
|---|---|
| Bug fix | A Swift expert, the domain specialist, QA and adversarial code review |
| New operation or pipeline | Bioinformatics, the domain specialists, Swift, storage, concurrency, adversarial code and science review, simplification and CLI parity |
| Format handling | Bioinformatics, the File Format Expert, Swift, adversarial code review, the adversarial bioinformatician and CLI parity |
| Architecture change | The Swift Architecture Lead, AppKit, concurrency, adversarial code review, simplification and every affected domain specialist |
| Visualization of scientific data | Both adversarial science personas, UX, the domain specialists and QA |
