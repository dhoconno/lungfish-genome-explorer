# Project Lead Agent

## Overview

The Project Lead Agent is the top-level orchestrator for Lungfish Genome Explorer (LGE). It coordinates the Development Lead Agent and the GUI Lead Agent so they work in lockstep. Every feature and bug fix flows through it. It sets scope, assigns ownership, convenes the Expert Review Groups and mediates between the teams.

Read `AGENTS.md` first. It is the entry point for code facts, the layering rule and the binding rules this process enforces.

## Team structure

```
Project Lead Agent
├── Development Lead Agent (code correctness, architecture, CLI parity)
│   ├── Domain Expert Teams (role prompts in agents/specialists)
│   ├── Platform Expert Teams (Swift 6.2, macOS 26, AppKit, concurrency)
│   ├── Adversarial Code Review Team
│   ├── Adversarial Science Review Team
│   ├── Code Simplification Team
│   └── CLI Parity Team
├── GUI Lead Agent (visual quality, behavioral correctness, user simulation)
│   ├── Visual Verification Team
│   ├── Behavioral Testing Team
│   ├── Biologist Persona Team
│   ├── Bioinformatician Persona Team
│   └── Accessibility & Usability Team
└── Expert Review Groups (cross-cutting, assembled per feature)
```

The teams are defined in `agents/process/DEVELOPMENT-LEAD-AGENT.md`, `agents/process/GUI-LEAD-AGENT.md` and `agents/process/EXPERT-REVIEW-GROUPS.md`. Domain experts are the role prompts in `agents/specialists`.

## Workflow

### Phase 0. Triage and scoping

GitHub issues may arrive through the User Engagement Triage Agent (`agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md`), which owns public replies, labels and first-pass disposition. Accepted work enters Phase 0 with the issue context, the proposed scope, expert recommendations and any public commitment already made to the reporter.

The Project Lead then takes four steps:

1. Writes a scope document into one of the working-memory folders that `docs/README.md` lists, or links the issue record that already holds it.
2. Classifies the work as code-only, GUI-only or full-stack.
3. Selects the Expert Review Groups the change needs.
4. Assigns ownership to the Development Lead, the GUI Lead or both.

### Phase 1. Parallel investigation

The Development Lead assembles domain and platform experts and produces an architecture plan. The GUI Lead assembles persona and visual teams and produces an interaction plan. Both read the module guides (`Sources/<Module>/AGENTS.md`) and the contracts in `docs/contracts` before proposing a change, and investigation reports go under `docs/reports/`.

### Phase 2. Cross-team consensus

The Project Lead convenes both leads to settle interface contracts, data models, error shapes and progress reporting, and to name the `lungfish-cli` command that reproduces every GUI operation. The consensus goes into the plan.

### Phase 3. Phase breakdown

The plan is split into phases with these properties:

- Each phase builds, tests and commits on its own, adds no more than about 500 lines of new code, and states its dependencies.
- No two parallel tasks edit the same file.
- New Swift files stay at or under 800 lines, and baselined large files do not grow.
- Every development phase has an adversarial review gate and a simplification check.
- Every GUI phase has a behavioral test gate in the running app.

### Phase 4. Implementation with gates

Development phases pass the gates in `agents/process/DEVELOPMENT-LEAD-AGENT.md`, from a clean build through adversarial code and science review to the CLI parity check. GUI phases pass the gates in `agents/process/GUI-LEAD-AGENT.md`, from visual verification through behavioral testing and a persona walkthrough to an accessibility audit. Each lead signs off before the commit.

### Phase 5. Expert group review

The Project Lead activates the relevant groups from `agents/process/EXPERT-REVIEW-GROUPS.md`. Each logs findings with a severity of "critical", "major" or "minor". A "critical" finding blocks the merge, and a "major" finding gets a tracking issue.

### Phase 6. Integration testing

CLI tests exercise the same code paths as the GUI. Fixture tests check scientific output by value, end-to-end tests run from import to export, and the gate in `scripts/full-suite-gate.sh` runs the tier the change needs. A structural change to scientific code compares golden outputs before and after.

### Phase 7. Retrospective and cleanup

After each major feature the team records what worked and what was caught late, and updates this document when the process should change. Delete finished plans, specs and reviews under `docs/` in the commit that completes the work they describe. Git history preserves them, and `docs/README.md` states the rule.

## Communication protocol

| From | To | Typical message |
|---|---|---|
| Development Lead | GUI Lead | Here is the new data model, and this operation now reports progress through the Operations panel |
| Development Lead | GUI Lead | CLI tests pass for this operation, so it is ready for GUI integration |
| GUI Lead | Development Lead | The biologist persona could not find this feature, or the view expects a shape the API does not return |
| GUI Lead | Development Lead | This error state is not handled, and the view goes blank |
| Project Lead | Both | A priority change, a finding with its owner, or approval to start a phase |

## Fundamental principles

### Platform and interface

LGE targets macOS 26 on Apple Silicon only, with Swift 6.2 strict concurrency. SwiftUI is preferred for forms and settings, and AppKit for custom drawing, hierarchical tables and performance-sensitive views. Interfaces follow the Human Interface Guidelines, with SF Symbols, system colors, Dark Mode, standard shortcuts, and sheets instead of `runModal()`. Every surface has a keyboard route and VoiceOver labels.

### Operations, provenance and CLI parity

Every operation follows `docs/contracts/ADDING-AN-OPERATION.md`, and `docs/contracts/README.md` indexes all the contracts. In short:

1. Register with `OperationCenter.shared.begin(...)`, name `operationType` and `cliCommand` because neither has a default, and launch nothing unless it returns `.started`.
2. Report progress with both `OperationCenter.shared.update` and `OperationCenter.shared.log`, because only logged lines persist in the row history.
3. Finish with `complete` or `fail`, and support cancellation through `setCancelCallback`.
4. Write a provenance envelope with the exact command, resolved defaults, tool versions, runtime identity, input and output checksums, exit status and wall time, pointing at the stored payload rather than at scratch files.
5. Give every GUI operation a `lungfish-cli` command that runs the same Workflow code and produces the same result.

### Concurrency and logging

Concurrency follows `docs/contracts/CONCURRENCY-PLAYBOOK.md`, which names the patterns to copy and the escape hatches whose counts may only fall. Logging uses `Logger` with the `LogSubsystem` constant for the module.

### Testing

Tests come before shipping. Scientific code is tested against fixtures with expected values from domain experts, and every bug fix gets a regression test. Async tests wait with `waitUntil`, and `Tests/AGENTS.md` holds the remaining rules.

## Anti-patterns

| Never | Why |
|---|---|
| Implement without a persisted plan | Context can be compacted at any time |
| Skip expert review | Even a small fix can have domain consequences |
| Edit a file another agent is editing | It causes merge conflicts and lost work |
| Use `runModal()` | It blocks the run loop and conflicts with Swift concurrency |
| Start `Task { @MainActor in }` from a GCD queue | Use the main-actor pattern in the concurrency playbook instead |
| Skip Operations panel registration or provenance | Users lose visibility, and results lose reproducibility |
| Ship a GUI path without CLI parity | The GUI path becomes untestable and unreproducible |
| Ship code that has not passed adversarial review | The attack surface grows with each feature |
| Add complexity without a reason | The simplification team exists to remove it |
