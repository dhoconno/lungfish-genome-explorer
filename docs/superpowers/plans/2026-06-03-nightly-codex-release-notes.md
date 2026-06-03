# Nightly Codex Release Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move nightly narrative release-note synthesis into the Codex automation layer and keep the local nightly release script deterministic and model-free.

**Architecture:** Revert the standalone script's OpenAI integration, make the script preserve a prewritten release note when one already exists, and update the Codex automation prompt so the automation writes the narrative summary before executing the release script. Verification stays focused on the script unit tests and prompt/config diffs.

**Tech Stack:** Python 3 stdlib, unittest, Codex automation TOML, markdown release notes.

---

### Task 1: Script Preservation Behavior

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/scripts/release/nightly_alpha_release.py`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/scripts/tests/test_nightly_alpha_release.py`

- [ ] Add a failing test that proves `write_release_notes(...)` leaves an existing release-note file untouched.
- [ ] Run `python3 -m unittest scripts.tests.test_nightly_alpha_release` and confirm the new test fails for the missing preservation behavior.
- [ ] Remove the OpenAI summary helpers and implement minimal preservation logic in `write_release_notes(...)`.
- [ ] Re-run `python3 -m unittest scripts.tests.test_nightly_alpha_release` and confirm all tests pass.

### Task 2: Automation Prompt Ownership

**Files:**
- Modify: `/Users/dho/.codex/automations/nightly-lungfish-alpha-release/automation.toml`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/docs/release/nightly-alpha-releases.md`

- [ ] Update the automation prompt so Codex writes the next release note summary from commits since the previous alpha tag before running `scripts/release/run-nightly-alpha-release.sh`.
- [ ] Update docs to describe that Codex authors nightly narrative summaries and the release script preserves prewritten notes.
- [ ] Review the resulting diff to confirm there is no remaining API-key requirement for release-note synthesis.

### Task 3: Final Verification

**Files:**
- Verify only.

- [ ] Run `python3 -m unittest scripts.tests.test_nightly_alpha_release`.
- [ ] Run `git diff -- scripts/release/nightly_alpha_release.py scripts/tests/test_nightly_alpha_release.py docs/release/nightly-alpha-releases.md /Users/dho/.codex/automations/nightly-lungfish-alpha-release/automation.toml`.
- [ ] Run `git status --short --branch` and confirm only intended files changed.
