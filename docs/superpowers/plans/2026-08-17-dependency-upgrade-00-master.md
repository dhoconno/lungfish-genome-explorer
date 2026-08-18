# Dependency Upgrade Program: Master Plan Index

> **For agentic workers:** This program is executed under Fable supervision using superpowers:subagent-driven-development. Fable orchestrates, picks the model per task, reviews every subagent diff and test output, and runs the gate before a task is marked complete. Execute the three plans in order; each produces working, testable software on its own.

**Goal:** Give Lungfish Genome Explorer a durable, semiannual dependency-upgrade mechanism, a regression strategy that makes upgrades safe, and ship the first sweep (dependency set 2026.2).

**Spec:** `docs/superpowers/specs/2026-08-17-dependency-upgrade-mechanism-design.md`

## Plans

| # | Plan | Delivers |
|---|---|---|
| A | `2026-08-17-dependency-upgrade-01-mechanism.md` | Single dependency manifest, install receipt, reconciler (plan + apply), Update Tools sheet, CLI parity, provenance `dependencySet`, storage-root override |
| B | `2026-08-17-dependency-upgrade-02-regression.md` | `LUNGFISH_REQUIRE_TOOLS` conformance mode, live conformance tests for every tool, parser hardening, golden regeneration + diff tooling, CI `toolset-conformance` job, sweep checklist doc |
| C | `2026-08-17-dependency-upgrade-03-sweep.md` | `scripts/deps/check-upstream.py`, `bump.py`, `verify.sh`, and execution of the 2026.2 sweep with verification and release notes |

## Execution model (binding)

- **Orchestrator:** Fable. Reads each task, decides model, dispatches, reviews the diff and the test output, runs the relevant gate (`scripts/test-surface.sh` filters for inner loop, `scripts/full-suite-gate.sh` before merge), then marks the task complete.
- **Model routing:** Sonnet/Haiku for bounded mechanical tasks (moving literals into the manifest, deleting mirror tests, boilerplate tests, doc edits, script scaffolding). Opus for design-sensitive tasks (reconciler policy, receipt synthesis, parser hardening, sheet UX, provenance changes, golden updates, anything touching scientific outputs). Fable keeps integration tasks and all sweep-verification decisions.
- **Serialization:** one `swift build`/`swift test` at a time per checkout (single `.build/.lock`). Never run a build while a subagent may be building.
- **GUI verification:** Computer Use against the launched app; code audits do not count.
- **Docs prose:** `docs/user-manual/**` and `.claude/agents/*` obey the no-em-dash and bullet-cap rules; plans/specs are exempt.

## Global constraints (from the spec)

- Swift 6.2, macOS 26 only, `@Observable` + `@MainActor` + strict concurrency; SwiftPM build; `swift test --skip-update`.
- Storage root default `~/.lungfish/` (space-free path required); conda root `<root>/conda`; databases `<root>/databases`.
- Every operation goes through `OperationCenter` with both `.update()` and `.log()`; every data-writing or metadata operation writes a provenance envelope.
- CLI parity: GUI and CLI share the same reconciler and plan types.
- Dependency set identifier format `YYYY.N`; first new set is `2026.2`.
- Old-version analyses are not required: superseded envs and databases are removed after successful replacement.
- Never save alignments as SAM; not relevant here but binding project-wide.
