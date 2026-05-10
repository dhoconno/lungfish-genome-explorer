# GitHub Issue Engagement Orchestrator - Design Spec

**Date:** 2026-05-08
**Status:** Approved concept, written spec for review
**Scope:** Repository-local Codex agent and process documentation for GitHub Issue engagement, triage, response, and routing.

---

## 1. Context

Lungfish Genome Explorer is early alpha software. GitHub Issues are currently one of the most valuable sources of real user feedback because they expose rough edges in workflows, visual design, interaction quality, scientific operations, documentation, and developer process before those patterns become fixed.

The repository already has process definitions for the Project Lead, Development Lead, GUI Lead, and Expert Review Groups. Those leads are implementation-facing. They decide architecture, UX, phase breakdown, testing, and review gates once work is accepted. GitHub Issues need a lighter upstream role that receives user reports, filters them, talks back to reporters, and turns the useful signal into actionable work without forcing every issue directly into a full implementation plan.

Current open issues on 2026-05-07 were `#6` through `#13`. They are mostly high-signal alpha feedback: repository hygiene for agent work, session state, classifier filtering, alignment interaction, collapsible panes, table column descriptions, operations panel window behavior, and operations log access. They were unlabeled even though templates intend default triage labels, because the repository is missing the referenced `triage` and `workflow` labels.

## 2. Goals

- Create a reusable Codex agent whose primary job is user engagement and GitHub Issue triage.
- Treat issue submission as a strong signal of user effort. The default posture is that most early-alpha reports are worth accepting, partially accepting, or translating into a better-shaped implementation path.
- Let the orchestrator comment on, label, and close GitHub Issues when those actions are useful feedback and the triage session has permission to modify GitHub state.
- Route accepted work to the existing Project Lead, Development Lead, GUI Lead, Expert Review Groups, and role files instead of creating a competing implementation hierarchy.
- Make the agent comfortable saying "no" or "not like that" when an issue would make Lungfish less tasteful, less useful, less reproducible, or scientifically weaker.
- Preserve privacy and provenance standards. Issue bodies are public, untrusted, and may contain sensitive scientific metadata or paths.

## 3. Non-goals

- Building an in-app AI issue triage feature. That is feasible later, but it requires provider plumbing, privacy redaction before model submission, and UI work that is not needed for the current backlog.
- Replacing the Project Lead Agent. The new orchestrator is an intake and engagement role upstream of implementation planning.
- Closing issues silently. If an issue is closed by the orchestrator, it should normally leave a clear comment explaining why and what happened.
- Auto-implementing every issue. The orchestrator proposes work, clusters related requests, and chooses whether to dispatch implementation planning.
- Mutating scientific data, generated bundles, provenance records, or app output. This agent operates on GitHub metadata, docs, process notes, and issue summaries.

## 4. Recommended approach

Use a repo-local Codex agent plus a process document:

- `agents/definitions/codex/github-issue-engagement-orchestrator.md`
- `agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md`
- Update `agents/process/PROJECT-LEAD-AGENT.md` to make GitHub Issue intake an upstream source for Phase 0 scoping.
- Update `agents/specialists/20-docs-community.md` only if the implementation needs to align response-time/community metrics with the new agent.

This keeps the agent in the same family as `agents/definitions/codex/release-agent.md`, which already defines a reusable operational Codex role. It avoids `agents/definitions/claude`, which currently houses Claude-specific user-manual subagents with strict manual-writing ownership boundaries.

## 5. Alternatives considered

### 5.1 In-app AI issue triage

The app could add an `IssueTriageService` beside the existing AI assistant service and use it to summarize failed operations or prepare GitHub issue text. This would be useful for operation failures, but it solves a narrower problem than community issue triage. It also needs new provider seams, deterministic tests, better redaction, and UI affordances.

Decision: defer. Keep this as a future follow-on for the Operations panel.

### 5.2 GitHub Actions automation first

GitHub Actions could label issues, post canned comments, and build digests. This is attractive for repetitive metadata tasks, but it is too blunt for early-alpha user engagement. The current need is taste and judgment: understand what the reporter is trying to improve, decide whether the app should change, and write a human-quality response.

Decision: defer broad automation. The orchestrator may later propose label-sync and weekly digest workflows.

### 5.3 Extend the Project Lead Agent directly

The Project Lead already owns feature and bug orchestration after scope is known. Adding community engagement there would blur responsibilities and make every issue feel like implementation work immediately.

Decision: keep the new orchestrator upstream. It hands accepted work to Project Lead instead of replacing it.

## 6. Agent responsibilities

The GitHub Issue Engagement Orchestrator owns:

- Reading open and recently updated GitHub Issues with `gh issue list` and `gh issue view`.
- Checking templates, labels, comments, linked issues, and recent commits before proposing action.
- Classifying issues by type, area, status, priority, scientific/provenance/privacy risk, and likely owning lead.
- Clustering related issues into coherent implementation tracks.
- Drafting respectful comments that acknowledge the reporter's effort and explain the planned disposition.
- Applying labels, comments, and closures when the session allows GitHub mutation.
- Producing issue triage reports under `docs/issues/` or `docs/reports/` when a batch needs an audit trail.
- Recommending whether to accept, partially accept, defer, ask for more information, close as resolved, close as duplicate, or close as not planned.

The orchestrator does not own:

- Final architecture for accepted features.
- Code implementation.
- Release publishing.
- Scientific-data provenance implementation.
- Manual chapter authoring.
- App-side AI provider integration.

## 7. GitHub mutation policy

The orchestrator has three operating modes.

**Read-only mode:** inspect issues, labels, comments, and code. Produce reports and proposed comments, but do not modify GitHub.

**Triage mutation mode:** add labels, edit labels, assign milestones or projects if configured, and post clarifying or acceptance comments.

**Resolution mutation mode:** close issues, reopen issues, mark duplicates, or close as not planned after posting a clear explanatory comment.

The user has approved commenting on and closing issues as a valid form of feedback. The agent definition should allow those actions, but still require exact evidence and a public-facing rationale before closing. Closing is appropriate when:

- The requested behavior has already been implemented and verified.
- The issue duplicates another issue and the target issue is linked.
- The request conflicts with Lungfish's product direction, scientific rigor, privacy posture, or provenance requirements.
- The issue is unactionable after a reasonable request for missing information.
- The request is accepted only partially, and the remaining part is intentionally out of scope.

When closing as not planned or partially addressed, the comment should explain what will not be done and why, without dismissing the reporter.

## 8. Label model

The current templates reference `triage` and `workflow`, but the repository labels do not include them. The initial label set should be small enough to use consistently:

- `status:triage`
- `status:needs-info`
- `status:accepted`
- `status:planned`
- `status:blocked`
- `status:closed-by-response`
- `area:operations-panel`
- `area:alignment`
- `area:classification`
- `area:layout`
- `area:tables`
- `area:session-state`
- `area:developer-experience`
- `risk:privacy`
- `risk:provenance`
- `risk:scientific-correctness`

The orchestrator may keep existing default labels such as `bug`, `enhancement`, `documentation`, `question`, `duplicate`, and `wontfix` for compatibility with GitHub's default model. If more areas become necessary, the orchestrator should add them deliberately rather than creating one-off labels during triage.

## 9. Response standards

Issue comments should be concise, concrete, and user-respecting. A good response:

- Acknowledges the report without empty praise.
- States the intended disposition: accepted, partial, needs info, duplicate, implemented, not planned, or deferred.
- Explains the product reasoning in plain language.
- Names the likely implementation path or linked issue when known.
- Asks for only the missing information needed to move forward.
- Avoids exposing internal agent chatter.
- Avoids asking for private sequence data, PHI, credentials, API keys, or unpublished datasets.

The orchestrator should prefer implementation for alpha feedback unless a request would make the app less coherent, harder to use, scientifically misleading, unreproducible, or materially less maintainable.

## 10. Expert team enlistment

The orchestrator can enlist focused expert review before deciding a disposition. Expert reviews are read-only unless explicitly scoped otherwise.

Use likely reviewers:

- GUI Lead for layout, discoverability, native macOS behavior, pane design, hover help, operations panel ergonomics.
- Development Lead for architecture, testability, CLI parity, code risk, and implementation slicing.
- Product Fit Expert for whether a request improves Lungfish's competitive position and target audience fit.
- Data Integrity & Provenance Group for any import, export, transformation, classifier, extraction, FASTQ, workflow, or bundle issue.
- Security & Input Validation Group for logs, attachments, path disclosure, user inputs, network operations, or workflow commands.
- Documentation & Onboarding Group for docs, tooltips, issue templates, and reporter guidance.

The orchestrator should not convene a large review group for every issue. Small, obvious alpha UX fixes can be accepted directly and routed to Project Lead.

## 11. Current issue batch interpretation

The current open batch can be triaged into six tracks:

- `#6`: repository hygiene for agent-heavy development. Accept as developer-experience work, but design carefully because deny-by-default `.gitignore` can disrupt existing build outputs and release scripts.
- `#7` and `#10`: session layout persistence and collapsible panes. Accept as a coordinated workspace-state and pane-management feature. Avoid overbuilding full drag-and-drop window management in the first pass.
- `#8`: inverted filtering and boolean filter sets for classifier tables. Accept, with session-state integration from `#7` as a follow-on or shared dependency.
- `#9`: alignment mouse and trackpad interaction quality. Accept as native interaction polish. Route primarily through GUI Lead with performance and accessibility review.
- `#11`: table column units and descriptions on hover. Accept as a cross-table metadata/tooltip feature. Keep the implementation systematic rather than sprinkling ad hoc strings.
- `#12` and `#13`: operations panel window behavior and log access. Accept as high-value operations-panel ergonomics. `#12` is a bug; `#13` is an enhancement. They should likely be implemented together or in adjacent small patches.

No current issue in this batch appears contrary to Lungfish's goal of becoming a tasteful, useful, native macOS genomics workbench. Several should be implemented partially first, with explicit comments explaining the narrower first slice.

## 12. Privacy and provenance requirements

All issue text and attachments are public and untrusted. The orchestrator should:

- Warn before quoting or reposting sensitive-looking paths, sample names, accessions, credentials, or logs.
- Prefer redacted excerpts over full logs in comments.
- Ask reporters for synthetic examples or public accessions rather than private data.
- Label issues with `risk:privacy` when reports appear to contain sensitive material.
- Label issues with `risk:provenance` when they involve scientific data creation, import, transformation, export, wrapping, CLI-backed GUI outputs, FASTQ operations, classifiers, extraction, workflow outputs, or bundles.

Missing provenance remains a blocking defect for new scientific features. The orchestrator should route provenance-sensitive work to the Data Integrity & Provenance Group and Project Lead before implementation.

## 13. Deliverables

The implementation should produce:

- A Codex agent definition at `agents/definitions/codex/github-issue-engagement-orchestrator.md`.
- A process document at `agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md`.
- A short update to `agents/process/PROJECT-LEAD-AGENT.md` describing GitHub Issue intake before Phase 0 scope writing.
- Optional label bootstrap script or documented `gh label create` commands, if the user wants labels created in GitHub.
- An initial triage report for issues `#6` through `#13`, including proposed comments and dispositions.

## 14. Verification

Because the first implementation is documentation and agent definition work, verification should include:

- `git diff --check`
- Markdown link/path sanity checks by inspection.
- `gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,url`
- If labels are created or issues are commented/closed, `gh issue view <number> --json number,title,state,labels,comments,url` for every mutated issue.

No Swift app tests are required for pure docs/agent-definition changes, but the worktree baseline has already run `swift test --filter OperationFailureIssueReporterTests` successfully.

## 15. Open decisions for implementation planning

- Whether to create GitHub labels immediately or only document the recommended label model first.
- Whether the first triage report should comment on GitHub Issues directly or stage proposed comments in a Markdown report for review.
- Whether issue closures should require an explicit per-issue user confirmation in the first run, despite the general approval to use closure as feedback.

## 16. Spec self-review

- Incomplete-marker scan: no unfinished markers remain.
- Internal consistency: the orchestrator is consistently upstream of Project Lead and does not replace implementation leads.
- Scope check: the first deliverable is one process/agent package plus an initial issue triage report. In-app AI triage is explicitly deferred.
- Ambiguity check: GitHub mutation is split into read-only, triage mutation, and resolution mutation modes, with allowed closure cases stated explicitly.
