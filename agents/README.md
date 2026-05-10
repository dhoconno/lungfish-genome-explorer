# Lungfish Agent Roster

This directory is the canonical home for Lungfish Genome Explorer agent definitions, process roles, and expert specialists.

Tool-specific folders such as `.codex/agents/` and `.claude/agents/` may contain mirror copies for tool discovery. When a definition changes, update the canonical file here first, then update the tool-facing mirror and the tests that validate the relationship.

## Layout

| Path | Purpose |
| --- | --- |
| `definitions/codex/` | Codex agent definitions used for release, issue engagement, and other Codex-native workflows. |
| `definitions/claude/` | Claude manual-writing and documentation agent definitions. |
| `process/` | Lead-agent workflows, review protocols, and operating contracts. |
| `specialists/` | Expert role definitions used for focused review and architecture consultation. |
| `archive/` | Inactive agent experiments or retired prompts retained for context. |

## Dispatch Rules

- Use the smallest agent set that can answer the question or review the work.
- Keep scientific-data provenance salient for imports, exports, transformations, classifiers, extraction, workflow outputs, and bundle generation.
- Record durable review outputs in active issue/product-spec locations when they drive current work; use `docs/archive/` only for historical records.
