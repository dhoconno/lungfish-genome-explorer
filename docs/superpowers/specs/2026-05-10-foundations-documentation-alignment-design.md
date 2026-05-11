# Foundations Documentation Alignment - Design Spec

**Date:** 2026-05-10
**Status:** Draft for user review
**Scope:** Align the Foundations user-manual section with current scientific consensus, `v0.4.0-alpha.12` app behavior, and active product limitations before broader documentation review continues.

---

## 1. Context

The Foundations section teaches the conceptual base for the rest of the Lungfish manual. It covers genomes, reads, amplicon versus shotgun sequencing, alignments, VCFs, project structure, plugin packs, provenance, and shared projects. Because readers encounter these chapters before specific workflows, incorrect or overconfident statements here can mis-train users before they run real analyses.

The `v0.4.0-alpha.12` release completed the repository hygiene cleanup, created a clean `main`, and published a new notarized DMG. The next work should not disturb release artifacts. This review therefore runs on `codex/foundations-doc-review` and creates plans only. User-manual and app changes should wait for review approval.

## 2. Goals

- Correct blocking scientific errors in the Foundations section.
- Make alpha product limitations explicit without making the manual feel apologetic.
- Ensure every app/CLI claim is traceable to code, tests, release behavior, or an active implementation ticket.
- Preserve the repository provenance rule: missing provenance is a blocking defect for new scientific features.
- Keep active expert-review issues salient while avoiding resurrection of archived plans/specs.
- Reconcile active issue records that are contradicted by current source before turning this review into implementation work.
- Produce a repeatable pattern for reviewing later documentation sections one at a time.

## 3. Non-goals

- Implementing the Foundations fixes before user review.
- Rewriting the entire manual voice or structure.
- Building major missing app features solely to avoid editing a doc claim.
- Treating external "current" biology statements as stable without dated sources.
- Reopening archived historical specs unless they are directly needed for traceability.

## 4. Design Principles

### 4.1 Docs as product contract

Foundations prose should state only what the current app does, what the current scientific model supports, or what is explicitly framed as future/advanced. When a claim has product implications, the doc patch should include a reference to the implementing code, test, or follow-up issue.

### 4.2 Scientific claims need stable examples

Use examples that are:

- correct relative to a named reference accession
- unlikely to change
- simple enough for non-expert users
- not misleading to expert bioinformaticians

For SARS-CoV-2 variant examples, prefer `MN908947.3:23403 A>G` for D614G, because it is widely recognizable and reference-anchored. Do not use a random spike coordinate and label it D614G.

### 4.3 Alpha features need precise verbs

Use "stores", "writes", "shows", and "runs" only for behavior verified in the current release. Use "planned", "not yet", or "use the CLI" for future workflows. Avoid "always", "every", and "anywhere" unless a test or shared utility enforces the statement.

### 4.4 Provenance language is strict but honest

The docs should match the repo-level rule: new scientific workflows that create, import, transform, export, or wrap scientific data must write provenance. If older or UI-adjacent paths are not fully audited, the manual should say which workflow families are covered and which are under active review.

### 4.5 Generated or source-checked inventories

Hand-maintained tables for plugin packs, managed tool versions, and caller inventories should be generated from source or checked against source during every docs edit. Tables that drift from `PluginPack.builtIn`, `third-party-tools-lock.json`, or current CLI tests are planning hazards.

## 5. Proposed Outputs

### 5.1 Foundations review manifest

File: `docs/issues/2026-05-10-foundations-documentation-review.md`

Purpose: Active issue-style inventory with severity, locations, assessment, and proposed disposition. This is the user-review entry point.

### 5.2 Foundations implementation plan

File: `docs/superpowers/plans/2026-05-10-foundations-documentation-alignment.md`

Purpose: A task-by-task plan that can later be executed subagent-driven. It separates documentation-only corrections from app-feature decisions.

### 5.3 Follow-up issues

Only create additional issue files after user review if a manifest item becomes a durable product gap. Likely candidates:

- provenance export packaging and citation blocks
- Operations Panel persistence and resumed background jobs
- GUI shared-project warning/read-only mode
- universal coordinate parser, if later chapters need it
- plugin-pack documentation sync
- active issue reconciliation for documentation-derived technical gaps

## 6. Workstream Design

### Workstream A: Scientific correctness

Patch only prose and examples. Expected edits are in:

- `01-what-is-a-genome.md`
- `02-sequencing-reads.md`
- `03-amplicon-vs-shotgun.md`
- `04-alignment-files.md`
- `05-variants-and-vcf.md`

Acceptance criteria:

- No chapter claims `21618 C>T` is D614G.
- Shotgun-depth arithmetic is transparent and dimensionally correct.
- SARS-CoV-2 is called an RNA genome, not a chromosome.
- FASTQ and Q-score claims are framed by platform and calibration.
- Amplicon primer trimming is described as BAM-level post-alignment trimming in Lungfish.
- Primer-scheme BED rows are described as coordinates, not as primer sequences unless extra sequence files/columns are explicitly present.
- Strand-bias guidance tells users to inspect context rather than ignore filters categorically.
- BAM and VCF semantics are precise enough for expert readers: BAM rows are alignment records; VCF `QUAL`, `GT`, `AF`, and `FILTER` are caller/header-defined.

### Workstream B: App and CLI capability alignment

Verify claims against source and tests before changing prose. Expected audit areas:

- project folder layout and `Analyses/`
- `lungfish` command naming and packaging
- mapper/caller/plugin pack tables
- Clair3, bcftools, and GATK status by surface: installed pack, CLI support, GUI lane, first-class workflow, or tracked product gap
- BAM/VCF output storage, compression, and indexes
- Operations Panel lifecycle
- Help menu and provenance export menu behavior
- coordinate parsing surfaces
- shared-project CLI lock/migrate semantics

Acceptance criteria:

- Every product claim in Foundations is either verified, narrowed, or linked to a follow-up issue.
- The project chapter names current project areas accurately.
- The plugin chapter matches `PluginPack.builtIn` and release requirements.
- Existing issue files that contradict current source are flagged before sprint planning.

### Workstream C: Provenance contract refresh

Use current sidecars and code to update the provenance chapter.

Acceptance criteria:

- The example schema is copied from a current representative sidecar or clearly labeled illustrative.
- The chapter distinguishes guaranteed new-workflow provenance from legacy audit gaps.
- GUI-imported CLI-output provenance points to final stored payloads where supported.
- Any missing provenance found during audit becomes a blocking issue before new scientific features are added.
- Helper/converter tools, migrations, and GUI-imported CLI outputs include tool/workflow version, argv/defaults, runtime identity, paths, checksums, sizes, exit status, wall time, and useful stderr where applicable.

### Workstream D: Review process for later documentation sections

Capture the review pattern so later sections can be evaluated consistently.

Acceptance criteria:

- The manifest format is reusable.
- Subagents can be assigned separate roles: science reviewer, app capability auditor, and implementation planner.
- Review artifacts live in active docs while current; old review outputs move to `docs/archive/` only after the associated work is completed or superseded.

### Workstream E: Active issue reconciliation

Review active documentation-derived issue files before implementation starts. If an issue says a feature is missing but source/tests now expose it, update the issue status or split the remaining gap.

Acceptance criteria:

- Workflow Builder, GATK, plugin-pack, and provenance issues reflect current `v0.4.0-alpha.12` behavior.
- Active issues remain salient; obsolete claims are corrected instead of archived silently.
- New implementation work references reconciled issue/spec IDs only.

## 7. Test Strategy

Use lightweight docs tests first:

- `rg` checks for known bad strings such as `21618 C>T` near `D614G`.
- MkDocs build smoke for broken links and anchors.
- Existing Python docs lint if available.

Use code tests only when a plan item touches app behavior:

- SwiftPM targeted tests for provenance, plugin packs, and CLI commands.
- Xcode UI smoke only for Help menu, Operations Panel, or plugin manager claims that cannot be verified statically.

Do not run the full release suite for a documentation-only patch unless the final approved implementation changes app code.

## 8. Open Questions for User Review

- Should the first implementation pass be documentation-only, with product gaps filed separately, or should any missing small app behavior be fixed immediately?
- Should Foundations explicitly label alpha-only limitations in callouts, or should the limitations be integrated into regular prose?
- Should ARTIC primer scheme wording use a fixed example bundled with Lungfish, or teach the user to verify current schemes externally each time?
- Should plugin-pack and managed-tool tables be generated automatically as part of the docs build, or should a lightweight audit script fail when the manual drifts from source?
- Should active issue reconciliation be part of this Foundations implementation pass, or handled as a short prerequisite pass before any docs edits?
