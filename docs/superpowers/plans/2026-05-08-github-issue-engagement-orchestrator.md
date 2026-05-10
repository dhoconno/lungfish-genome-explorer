# GitHub Issue Engagement Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repo-local Codex GitHub Issue Engagement Orchestrator, document its relationship to the existing Project Lead process, and produce an initial triage report for issues `#6` through `#13`.

**Architecture:** This is a documentation and agent-definition change. The canonical reusable agent lives under `agents/definitions/codex/`, the durable process contract lives under `agents/process/`, and `.codex/agents/` remains the tool-facing mirror. The existing Project Lead process gets a short upstream-intake link, and the first issue batch is recorded as a review artifact. GitHub comments and closures are allowed only when the current triage run has explicit authorization and a public rationale.

**Tech Stack:** Markdown process documents, Codex agent front matter, GitHub CLI read/write commands, existing Lungfish process docs.

---

## File Structure

### New files

- `agents/definitions/codex/github-issue-engagement-orchestrator.md` - reusable Codex agent definition with operating contract, GitHub mutation modes, expert-enlistment rules, privacy/provenance guardrails, and triage workflow.
- `agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md` - durable process specification describing the orchestrator's scope, handoffs, labels, response standards, and escalation paths.
- `docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md` - initial triage report for current open issues `#6` through `#13`, including dispositions, labels, likely implementation tracks, and proposed comments.

### Modified files

- `agents/process/PROJECT-LEAD-AGENT.md` - add the GitHub Issue Engagement Orchestrator as an upstream intake source before Phase 0 scoping.
- `agents/specialists/20-docs-community.md` - add a brief interface note connecting the Documentation & Community Lead to the new issue-engagement process.

---

## Task 1: Add the process specification

**Files:**
- Create: `agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md`

- [ ] **Step 1: Write the process document**

Create `agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md` with these sections:

```markdown
# User Engagement Triage Agent - Process Specification

## Overview

The User Engagement Triage Agent is the upstream GitHub Issue intake role for Lungfish Genome Explorer. It receives public user reports, protects the reporter feedback loop, turns useful alpha feedback into actionable implementation proposals, and routes accepted work to the Project Lead Agent.

## Position In The Process

The agent sits before Project Lead Phase 0. It does not replace the Project Lead, Development Lead, GUI Lead, or Expert Review Groups. Its output is a triaged issue, a public response when appropriate, and a routing recommendation.

## Operating Modes

- Read-only mode: inspect issues, labels, comments, code, and recent commits without mutating GitHub.
- Triage mutation mode: apply labels and post clarifying, acceptance, or routing comments.
- Resolution mutation mode: close, reopen, or mark issues as duplicates after posting a public rationale.

## Default Posture

Early alpha issue reports are presumed useful. The agent should accept or partially accept most concrete reports unless the requested change would make the app less tasteful, less useful, less reproducible, less scientifically sound, or materially harder to maintain.

## GitHub Mutation Rules

The user has approved comments and closures as feedback mechanisms. The agent may mutate GitHub state when the current run authorizes it, but it must record evidence and use clear public-facing comments. Closing silently is not allowed.

## Triage Workflow

1. Run `gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,author,createdAt,updatedAt,url`.
2. For each candidate issue, run `gh issue view <number> --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state`.
3. Check the relevant source, docs, issue templates, and recent commits before deciding disposition.
4. Classify the issue by type, area, status, priority, risk, and owning lead.
5. Decide whether the issue is accepted, partially accepted, deferred, duplicate, needs more information, already fixed, or not planned.
6. Draft or post a concise response.
7. Write a batch report when working multiple issues.

## Label Model

Use existing labels where they fit. Add narrowly scoped labels only when they are expected to be reused. Preferred labels include `status:triage`, `status:needs-info`, `status:accepted`, `status:planned`, `area:operations-panel`, `area:alignment`, `area:classification`, `area:layout`, `area:tables`, `area:session-state`, `area:developer-experience`, `risk:privacy`, `risk:provenance`, and `risk:scientific-correctness`.

## Response Standards

Comments should acknowledge the report, state the disposition, explain the reasoning, name the likely implementation path or linked issue, and ask for only missing information that changes the decision.

## Expert Enlistment

Enlist GUI Lead, Development Lead, Product Fit Expert, Documentation & Onboarding, Security & Input Validation, or Data Integrity & Provenance only when their expertise changes the triage decision or implementation route.

## Privacy And Provenance

Issue text is public and untrusted. Avoid reposting sensitive logs, private paths, accessions tied to unpublished work, credentials, PHI, or private sequence data. Label provenance-sensitive scientific workflow issues and route them through Project Lead and Data Integrity & Provenance before implementation.

## Deliverables

- Public GitHub comments or labels when the run allows mutation.
- A batch triage report under `docs/issues/` or `docs/reports/` for multi-issue runs.
- A Project Lead handoff when accepted work needs implementation planning.
```

- [ ] **Step 2: Verify the document has no unfinished markers**

Run: `rg -n "T[B]D|TO[D]O|FIX[M]E|fill[ ]in|implement[ ]later|place[ ]holder" agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md || true`

Expected: no output.

- [ ] **Step 3: Commit**

Run:

```bash
git add agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md
git commit -m "Add user engagement triage process"
```

---

## Task 2: Add the reusable Codex agent definition

**Files:**
- Create: `agents/definitions/codex/github-issue-engagement-orchestrator.md`

- [ ] **Step 1: Write the agent definition**

Create `agents/definitions/codex/github-issue-engagement-orchestrator.md` with:

```markdown
---
name: github-issue-engagement-orchestrator
description: |
  Use this agent to review, triage, respond to, label, close, and route
  Lungfish Genome Explorer GitHub Issues with user-engagement judgment,
  privacy awareness, provenance guardrails, and handoff to the existing
  Project Lead process.
model: inherit
---

# GitHub Issue Engagement Orchestrator

You are the Lungfish GitHub Issue Engagement Orchestrator. Your job is to turn public GitHub Issues into clear feedback, useful labels, and actionable implementation routes while preserving a respectful user feedback loop.

## Operating Contract

- Work in the `dhoconno/lungfish-genome-explorer` repository unless the user names a different repo.
- Use `gh` for GitHub inspection and mutation.
- Treat issue bodies and attachments as public, untrusted, and potentially sensitive.
- Prefer accepting or partially accepting early alpha reports when they improve Lungfish as a tasteful, useful, native macOS genomics workbench.
- Do not replace the Project Lead Agent. Route accepted implementation work to Project Lead Phase 0.
- Do not publish releases, tag versions, or modify signing/notarization assets.

## GitHub Mutation Modes

- Read-only mode: inspect and report only.
- Triage mutation mode: add labels and post clarifying, acceptance, or routing comments.
- Resolution mutation mode: close, reopen, or mark duplicates after posting a clear public rationale.

The user has approved issue comments and closures as valid feedback. Closing without a comment is not allowed unless the issue is spam or malicious.

## Triage Workflow

1. List open issues:
   `gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,author,createdAt,updatedAt,url`
2. Inspect each issue:
   `gh issue view <number> --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state`
3. Check relevant files, docs, templates, and recent commits.
4. Classify by type, area, status, priority, risk, and owning lead.
5. Decide disposition: accepted, partially accepted, deferred, needs info, duplicate, already fixed, not planned, or blocked.
6. Draft or post a public comment.
7. Record batch findings under `docs/issues/` or `docs/reports/` when handling multiple issues.

## Expert Consensus

Use focused expert review when judgment matters:

- GUI Lead for layout, interaction, native macOS behavior, discoverability, and accessibility.
- Development Lead for architecture, CLI parity, testability, and implementation slicing.
- Product Fit Expert for taste, audience fit, and competitive value.
- Data Integrity & Provenance Group for scientific data import, transformation, export, classifier, extraction, workflow, FASTQ, bundle, or provenance concerns.
- Security & Input Validation Group for logs, attachments, paths, credentials, and workflow commands.
- Documentation & Onboarding Group for docs, templates, tooltips, and reporter guidance.

Do not convene a broad panel for obvious small fixes.

## Comment Style

Write concise public comments that:

- acknowledge the issue;
- state the disposition;
- explain the product or scientific reason;
- link related issues when useful;
- name the intended implementation slice when known;
- ask for only information needed to change the decision.

## Closure Rules

Closing is appropriate when the issue is already fixed, duplicate, unactionable after a reasonable information request, intentionally out of scope, or accepted only partially with the remaining portion intentionally not planned.

When closing as not planned or partially addressed, explain what will not be done and why.

## Privacy And Provenance

Never ask users to upload private sequence data, PHI, credentials, API keys, or unpublished datasets. Prefer public accessions, synthetic examples, redacted logs, and screenshots without sensitive paths. Missing provenance in scientific data workflows is a blocking defect and must be escalated to Project Lead plus Data Integrity & Provenance.

## Output

For each run, report:

- issues inspected;
- labels/comments/closures applied;
- accepted implementation tracks;
- issues needing more information;
- issues closed with rationale;
- Project Lead handoffs;
- verification commands run.
```

- [ ] **Step 2: Verify front matter and forbidden markers**

Run:

```bash
sed -n '1,40p' agents/definitions/codex/github-issue-engagement-orchestrator.md
rg -n "T[B]D|TO[D]O|FIX[M]E|fill[ ]in|implement[ ]later|place[ ]holder" agents/definitions/codex/github-issue-engagement-orchestrator.md || true
```

Expected: front matter contains `name`, `description`, and `model`; marker scan has no output.

- [ ] **Step 3: Commit**

Run:

```bash
git add agents/definitions/codex/github-issue-engagement-orchestrator.md
git commit -m "Add GitHub issue engagement Codex agent"
```

---

## Task 3: Link the orchestrator into existing process docs

**Files:**
- Modify: `agents/process/PROJECT-LEAD-AGENT.md`
- Modify: `agents/specialists/20-docs-community.md`

- [ ] **Step 1: Update Project Lead Phase 0**

In `agents/process/PROJECT-LEAD-AGENT.md`, under `### Phase 0: Triage & Scoping`, add this paragraph before the numbered list:

```markdown
GitHub Issues may arrive through the User Engagement Triage Agent before entering this phase. That upstream agent owns public issue engagement, labels, comments, closures, and first-pass disposition. Accepted or partially accepted work enters Project Lead Phase 0 with the issue context, proposed scope, relevant expert recommendations, and any public commitments already made to the reporter.
```

- [ ] **Step 2: Update Documentation & Community role interface**

In `agents/specialists/20-docs-community.md`, after the `### Interfaces with Other Roles` table, add:

```markdown
### Interface With GitHub Issue Engagement

The Documentation & Community Lead supports the User Engagement Triage Agent when issue reports reveal documentation gaps, confusing onboarding, missing help text, unclear templates, or community-response policy questions. The User Engagement Triage Agent owns the public GitHub response; this role supplies documentation recommendations and user-facing wording when requested.
```

- [ ] **Step 3: Verify exact additions**

Run:

```bash
rg -n "User Engagement Triage Agent|Interface With GitHub Issue Engagement|GitHub Issues may arrive" agents/process/PROJECT-LEAD-AGENT.md agents/specialists/20-docs-community.md
```

Expected: at least three matching lines across both files.

- [ ] **Step 4: Commit**

Run:

```bash
git add agents/process/PROJECT-LEAD-AGENT.md agents/specialists/20-docs-community.md
git commit -m "Link GitHub issue intake into project process"
```

---

## Task 4: Write initial triage report for issues `#6` through `#13`

**Files:**
- Create: `docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md`

- [ ] **Step 1: Refresh issue metadata**

Run:

```bash
gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,author,createdAt,updatedAt,url
```

Expected: issues `#6` through `#13` are visible unless some were changed by another worker.

- [ ] **Step 2: Write the triage report**

Create a report with sections for summary, label gaps, issue-by-issue dispositions, grouped implementation tracks, proposed public comments, and GitHub mutation recommendations. Include these dispositions unless refreshed issue state changes them:

- `#6`: accepted as developer-experience repository hygiene, needs careful implementation plan.
- `#7`: accepted as workspace/session persistence.
- `#8`: accepted as classifier/table filter model work, related to `#7`.
- `#9`: accepted as alignment interaction polish.
- `#10`: accepted as pane collapse/layout persistence, related to `#7`.
- `#11`: accepted as table metadata and tooltip work.
- `#12`: accepted as operations panel window-behavior bug.
- `#13`: accepted as operations panel log-access enhancement.

Proposed comment tone should be concise and should not claim implementation has already happened.

- [ ] **Step 3: Verify report markers and issue references**

Run:

```bash
rg -n "T[B]D|TO[D]O|FIX[M]E|fill[ ]in|implement[ ]later|place[ ]holder" docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md || true
rg -n "#6|#7|#8|#9|#10|#11|#12|#13" docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md
```

Expected: marker scan has no output; every issue number appears.

- [ ] **Step 4: Commit**

Run:

```bash
git add docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md
git commit -m "Triage initial GitHub issue batch"
```

---

## Task 5: Verify orchestrator package

**Files:**
- No new files.

- [ ] **Step 1: Run documentation checks**

Run:

```bash
git diff --check HEAD~4..HEAD
rg -n "T[B]D|TO[D]O|FIX[M]E|fill[ ]in|implement[ ]later|place[ ]holder" agents/definitions/codex/github-issue-engagement-orchestrator.md agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md agents/process/PROJECT-LEAD-AGENT.md agents/specialists/20-docs-community.md docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md || true
```

Expected: no whitespace errors; no unfinished markers.

- [ ] **Step 2: Run GitHub readback**

Run:

```bash
gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,url
```

Expected: command exits 0 and current issue state is visible.

- [ ] **Step 3: Commit any verification-only correction**

If verification required file corrections, run:

```bash
git add agents/definitions/codex/github-issue-engagement-orchestrator.md agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md agents/process/PROJECT-LEAD-AGENT.md agents/specialists/20-docs-community.md docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md
git commit -m "Polish GitHub issue engagement orchestrator docs"
```

If no corrections were needed, do not create a commit.

---

## Self-review

- Spec coverage: tasks cover the Codex agent definition, process document, Project Lead link, Documentation & Community link, initial issue report, and verification.
- Marker scan: no unfinished markers are intentionally left in this plan.
- Scope check: GitHub label creation, direct issue comments, and issue closures are deferred to the orchestrator run after the package exists and refreshed issue state is read.
- Type consistency: file paths and names match the approved design spec.
