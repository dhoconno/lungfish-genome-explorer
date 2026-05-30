# Amplicon Genotyping + 12S Review and Improvement Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify and baseline-commit the `12s-amplicon-matching` worktree, run a two-team expert
review producing an exhaustive operation-intent matrix and findings, then implement the
triaged improvements (CLI-backed, TDD) and verify them end-to-end with real and synthetic data.

**Architecture:** Two planning passes. Pass A (this document, Phases 1-2) is fully specified
and executable now: baseline, then parallel read-only review writing reports to
`docs/superpowers/reviews/`. Pass B (Phases 3-5) is authored *after* the review, from the real
synthesis, because task code must be grounded in actual findings (no placeholder tasks). The
orchestrator triages and sets the cut line autonomously (user is out of the loop) per the
agreed priorities: P0 correctness/concurrency/provenance, P1 UX consistency incl. cross-workflow
convergence, P2 reuse refactors (opted in).

**Tech Stack:** Swift 6.2, SPM, AppKit/SwiftUI, ArgumentParser, existing Lungfish provenance
APIs. Spec: `docs/superpowers/specs/2026-05-30-amplicon-12s-review-and-improvement-design.md`.

**Execution note:** the Bash tool defaults to the main checkout. Every `git`/`swift` command in
this plan must run with `-C <WT>` or from inside the worktree, where
`WT = /Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching`.

---

## Phase 1: Baseline Verification + Commit

### Task 1: Verify the build and baseline tests

**Files:**
- No source changes. Verification only.

- [ ] **Step 1: Build both products**

Run (from `WT`):
```bash
swift build --product Lungfish 2>&1 | tail -20
swift build --product lungfish-cli 2>&1 | tail -20
```
Expected: both succeed ("Compiling"/"Build complete"). If either fails, STOP and report the
compile errors. Do not commit a non-building baseline.

- [ ] **Step 2: Run the in-scope test filters**

Run (from `WT`):
```bash
swift test --skip-update --filter TwelveS 2>&1 | tail -30
swift test --skip-update --filter SampleMetadata 2>&1 | tail -30
swift test --skip-update --filter Provenance 2>&1 | tail -30
swift test --skip-update --filter Genotyp 2>&1 | tail -30
swift test --skip-update --filter Haplotype 2>&1 | tail -30
swift test --skip-update --filter ONTBarcodeDemux 2>&1 | tail -30
```
Expected: all green. Record pass/fail counts.

- [ ] **Step 3: Decide baseline-commit readiness**

If all green: proceed to Task 2.
If any red: STOP. Report which tests fail and the failure output. Do not commit a knowingly
broken baseline without explicit direction. (A pre-existing flake noted in memory —
`testSRASearch`, `GenBankReaderTests.testReadKF015279` — is not in these filters; if some
unrelated flake appears, note it but it does not block the baseline.)

### Task 2: Commit the worktree baseline

**Files:**
- All currently-uncommitted worktree files (the ~12k-line feature surface).

- [ ] **Step 1: Stage the feature surface (not the review artifacts)**

The spec commits already added the design doc and this plan. Stage the rest of the feature
work explicitly (avoid blind `git add -A`):
```bash
git -C "$WT" add Sources/ Tests/ docs/superpowers/plans/2026-05-27-12s-amplicon-matching.md docs/superpowers/plans/2026-05-28-canonical-sample-metadata.md docs/superpowers/plans/2026-05-30-12s-reference-bundle.md
git -C "$WT" status --short
```
Expected: all Sources/Tests changes plus the three feature plan docs staged. Verify no
secrets/large binaries are staged.

- [ ] **Step 2: Commit the baseline**

```bash
git -C "$WT" commit -m "$(cat <<'EOF'
Baseline: 12S amplicon matching + MHC genotyping worktree state

Snapshot the full feature surface (12S matching workflow, canonical sample
metadata, 12S/MHC reference bundles, haplotype manager, multi-bundle
genotyping) prior to expert review and improvement.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git -C "$WT" log --oneline -1
```
Expected: clean commit; `git status` shows only review artifacts (if any) untracked.

---

## Phase 2: Parallel Expert Review (read-only, two teams)

### Task 3: Prepare the review output directory and shared brief

**Files:**
- Create: `docs/superpowers/reviews/` (directory)
- Create: `docs/superpowers/reviews/2026-05-30-context-brief.md`

- [ ] **Step 1: Create the reviews directory**

```bash
mkdir -p "$WT/docs/superpowers/reviews"
```

- [ ] **Step 2: Write the shared context brief**

Write `docs/superpowers/reviews/2026-05-30-context-brief.md` containing the exact briefing every
review agent receives (so all five share identical context):
- Worktree absolute path (`WT`) and branch `codex/12s-amplicon-matching`.
- The spec path and a one-paragraph summary of the two workflows + the cross-workflow
  consistency requirement (the abundance filter is ONE example, not the scope; exhaustive
  operation-intent matrix required).
- The enumerated review surface (copy the "Specific features/fixes", "Cross-cutting changes",
  "12S surface", "Amplicon Genotyping surface" lists from the spec's Current State).
- Binding memory rules to apply: background->MainActor dispatch discipline
  (`DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }`; never
  `Task { @MainActor in }` from GCD; never `await` `@MainActor` from `Task.detached`); never
  `%s`/`String(format:)` with Swift Strings (use `%@`/interpolation); `@Observable` +
  `@MainActor` + strict concurrency + `Sendable`; GUI idioms (classifier-style IA,
  `ClassifierActionBar`, `BlastResultsDrawerTab`, `ReferenceSequencePickerView`,
  `SampleMetadataSection`); accent `#D47B3A`/dark `#E8A06A`; viewport interface classes;
  bundle/registry conventions; every scientific GUI action must shell out to `lungfish-cli`.
- The instruction that each agent reviews BOTH surfaces in their entirety and compares against
  existing LGE surfaces, and writes its report to a specified path.

- [ ] **Step 3: Commit the brief**

```bash
git -C "$WT" add docs/superpowers/reviews/2026-05-30-context-brief.md
git -C "$WT" commit -m "Add shared context brief for amplicon/12S expert review

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 4: Dispatch both review teams in parallel (5 agents, one message)

**Files:**
- Created by agents (read-only review; they only write their own report files):
  - `docs/superpowers/reviews/2026-05-30-code-reviewer-findings.md`
  - `docs/superpowers/reviews/2026-05-30-architect-reviewer-findings.md`
  - `docs/superpowers/reviews/2026-05-30-swift-expert-findings.md`
  - `docs/superpowers/reviews/2026-05-30-frontend-developer-findings.md`
  - `docs/superpowers/reviews/2026-05-30-ux-researcher-findings.md`

- [ ] **Step 1: Launch all five agents concurrently**

Send ONE message with five `Agent` tool calls (Team A: `code-reviewer`, `architect-reviewer`,
`swift-expert`; Team B: `frontend-developer`, `ux-researcher`). Each prompt: (a) points to the
context brief and spec, (b) states the agent's specific lens per the spec's Phase 2 briefs,
(c) requires read-only analysis (no edits), (d) names the exact output report path, (e) for
Team B, assigns matrix ownership (`ux-researcher` owns the operation-intent matrix;
`frontend-developer` contributes the widget-level column). Each report must use a consistent
finding schema: `ID | Severity (P0/P1/P2) | Surface | Location (file:line) | Problem | Evidence
| Suggested fix | Effort`.

- [ ] **Step 2: Wait for all five reports, then verify they exist and are non-trivial**

```bash
ls -la "$WT/docs/superpowers/reviews/"
wc -l "$WT"/docs/superpowers/reviews/2026-05-30-*-findings.md
```
Expected: five findings files, each substantive. If an agent failed or produced a stub, re-run
that agent.

### Task 5: Synthesize findings + consolidate the operation-intent matrix

**Files:**
- Create: `docs/superpowers/reviews/2026-05-30-synthesis.md`
- Create: `docs/superpowers/reviews/2026-05-30-operation-intent-matrix.md`

- [ ] **Step 1: Check matrix completeness (gate)**

Read the `ux-researcher` and `frontend-developer` reports. Confirm the operation-intent matrix
enumerates every surface and, for every intent, either flags divergence or explicitly confirms
consistency. If it is spot-check-only or missing surfaces, re-dispatch that agent with specific
gaps named. Do not proceed until the matrix is complete.

- [ ] **Step 2: Write the consolidated matrix**

Write `2026-05-30-operation-intent-matrix.md`: a table keyed by operation intent (rows) x
surface (columns: 12S, MHC genotype, existing-LGE idiom), each cell recording widget/flag and
behavior, with a divergent/consistent verdict and the target shared idiom per divergent row.

- [ ] **Step 3: Write the synthesis**

Write `2026-05-30-synthesis.md`: deduplicate findings across the five reports, assign final
P0/P1/P2, and produce one ordered, triaged list. Each entry keeps file:line evidence and a
suggested fix. Include a dedicated section listing every divergent matrix intent as P1
convergence items.

- [ ] **Step 4: Commit the synthesis and matrix**

```bash
git -C "$WT" add docs/superpowers/reviews/2026-05-30-synthesis.md docs/superpowers/reviews/2026-05-30-operation-intent-matrix.md docs/superpowers/reviews/2026-05-30-*-findings.md
git -C "$WT" commit -m "Add expert review findings, synthesis, and operation-intent matrix

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Guiding directives (apply throughout, per user)

- **The comprehensive review of these two workflows is the central goal**, not a gate to rush
  past on the way to coding. Depth and completeness of the review (and the operation-intent
  matrix) take precedence over speed. Build/commit mechanics serve the review, not the reverse.
- **Expert involvement is continuous, not one-shot.** The agent teams may review and iterate
  *throughout the entire process*: the initial surface review (Phase 2), the improvement plan
  itself (Pass B authoring), and a re-review after implementation lands (Phase 4 -> final
  review). Iterate with experts wherever it improves quality; do not treat Phase 2 as the only
  review.

## Phase 3-5: Authored after review (second planning pass)

These phases are intentionally not expanded into task code here, because their content depends
on the review synthesis. Writing concrete task code now would require inventing findings, which
violates the no-placeholder rule.

**Handoff into Pass B (performed by the orchestrator immediately after Task 5, no user gate):**

1. Re-invoke the writing-plans skill to author
   `docs/superpowers/plans/2026-05-30-amplicon-12s-improvements.md` from the synthesis. That
   plan contains the concrete, TDD, bite-sized tasks for:
   - **Phase 3 (triage):** already captured as the synthesis ordering + cut line. The
     orchestrator sets the cut line autonomously: all P0 and P1 in scope; P2 reuse refactors in
     scope where effort is justified (user opted these in). Anything deferred is listed with a
     reason.
   - **Phase 4 (improvement):** one task per finding/convergence item, TDD (failing test ->
     minimal impl -> green), every scientific action shelling out to `lungfish-cli`, frequent
     commits. Known anchors the improvement plan will almost certainly include:
     - 12S opt-in default fix (remove `twelveSAmpliconMatchingID` from
       `defaultEnabledWorkflowIDs`; update `WorkflowLibraryTests`).
     - `.lungfishmhcref` consume-side wiring: `FastqGenotypingSubcommand` accepts a
       `.lungfishmhcref` and resolves FASTA + paired haplotype definitions from it; GUI launch
       path resolves likewise; provenance records the bundle path.
     - Cross-workflow filter convergence: a shared minimum-read/abundance Inspector control idiom
       bound to both `TwelveSResultDisplayState` and `GenotypeResultDisplayState`, plus any other
       divergent intents from the matrix.
   - **Phase 5 (verification):** the exact commands from the spec's Phase 5 (12S synthetic +
     real `32308`/Hilo run; MHC `32271.lungfish` run incl. multi-bundle and `.lungfishmhcref`
     gates; SampleMetadata/Provenance filters; cross-workflow filter equivalence).
2. **Expert review of the improvement plan (per user's continuous-iteration directive).** Before
   executing Pass B, dispatch `architect-reviewer` (and `swift-expert` if the plan touches
   concurrency/API design heavily) to review the improvement plan against the synthesis: does it
   address every in-scope finding, is the sequencing sound, are the convergence refactors
   coherent? Iterate the plan on their feedback before implementing.
3. Execute Pass B with subagent-driven-development (per-task: implementer -> spec reviewer ->
   code-quality reviewer).
4. **Final post-implementation re-review (per user's continuous-iteration directive).** After
   all Pass B tasks land, dispatch a final review (re-run the relevant Team A/Team B agents over
   the *changed* surface) to confirm the findings are actually resolved and no consistency
   regressions were introduced. Capture in
   `docs/superpowers/reviews/2026-05-30-final-review.md`. Iterate on any new P0/P1.
5. Conclude with superpowers:finishing-a-development-branch.

**Verification assets (confirmed present):** see spec "Verification Assets".

---

## Self-Review (Pass A)

- **Spec coverage (Phases 1-2):** baseline build+tests (Task 1), baseline commit (Task 2),
  reviews dir + shared brief (Task 3), five-agent parallel dispatch with matrix ownership
  (Task 4), synthesis + matrix-completeness gate + consolidated matrix (Task 5). Covered.
- **Phases 3-5:** deferred to Pass B by design, with the handoff and known anchors documented
  so nothing is lost. Covered as a process.
- **Placeholders:** none of the forbidden kind. Pass B deferral is an explicit, justified
  process step, not a "TODO: fill in later" inside an executable task.
- **Type/name consistency:** symbol names used (`twelveSAmpliconMatchingID`,
  `defaultEnabledWorkflowIDs`, `FastqGenotypingSubcommand`, `TwelveSResultDisplayState`,
  `GenotypeResultDisplayState`, `.lungfishmhcref`) match the spec and verified source.
