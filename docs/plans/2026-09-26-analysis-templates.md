# Analysis templates: save a finished analysis as a reusable workflow (v1)

Status: approved for autonomous implementation (owner away, 2026-09-26).
Inputs: architect review and UX review (2026-09-26, summarized here).

## Goal

From a finished Kraken2 analysis in a project, create a **workflow template** that
captures the chain from FASTQ import (including the import recipe) through Kraken2
(and Bracken), with every setting pinned. Later, run the template on new FASTQ files
of the same kind and get the same steps with the same settings, with explicit checks
and warnings where the environment differs (recipe content, database version, tool
versions).

Wording rule (UX): promise "the same steps with the same settings", never "the same
results".

## Verdicts

- Architect: practical and advisable as a narrow v1 (~6-8 h). A general "any output"
  version is 2-4 weeks. The prototype Workflow Builder is not a usable base (only 5
  FASTQ-recipe node types, its per-step command `workflow builder-step run` does not
  exist, no import or Kraken2 nodes).
- UX: advisable. "Template from a result I trust" fits bench scientists better than a
  node graph. v1 must be narrow and honest about reproducibility.

## Decisions

1. **New typed template format**, not the builder graph, not `.lungfishflowpkg`, not
   `LocalWorkflowReplay*`. File: `<name>.lungfishtemplate` (JSON, `schemaVersion: 1`).
2. **Storage**: an app-wide template library in the app identity's Application Support
   directory, next to user recipes (`RecipeRegistry.userRecipesDirectoryURL` pattern),
   folder `Workflow Templates`. CLI `create` also accepts `--output <file>`; `run`
   accepts a path or a library template name.
3. **Source of truth for Kraken2 settings**: `classification-result.json`
   (`PersistedClassificationResult` / `ClassificationConfig`, ClassificationResult.swift
   ~181-204 and ~434), NOT the provenance `argv` (GUI runs record the raw kraken2 step,
   CLI runs record `lungfish-cli`; different shapes).
4. **Source of truth for import settings**: the root `.lungfishfastq` bundle's
   `.lungfish-provenance.json` written by `FASTQBatchImporter.writeImportProvenance`
   (FASTQBatchImporter.swift ~1420, options ~2100-2160; `workflowName "lungfish import
   fastq"`), `options.explicit` + `resolvedDefaults["pairing"]`, plus bundle metadata
   `recipeApplied` (~1157-1170). Note the recorded argv omits `--pairing` and `--name`.
5. **Recipes are snapshotted** (full `Recipe` content + SHA-256 of a canonical
   encoding). At run time the installed recipe with that id must hash-match, otherwise
   refuse unless `--allow-drift` (then warn). Built-in recipes resolve the same way.
6. **Every setting is pinned** from recorded values, even ones equal to today's
   defaults (compression, clumping, quality binning, storage optimization, platform,
   pairing; all `ClassificationConfig` fields). Per-run values only: input files,
   project, sample/bundle name, threads, output directory.
7. **Execution runs the bundled `lungfish-cli` as a subprocess per step** (`import
   fastq`, then `conda classify` built by `ClassificationCLIInvocationBuilder`), so each
   step writes its own normal provenance with its real argv (ClassifyCommand records
   CommandLine.arguments, so in-process calls would record the wrong argv). A run-level
   provenance record (`workflowName "lungfish.workflow.template.run"`) links the step
   outputs and stores the template SHA-256 and any drift warnings.
8. **The prototype Workflow Builder stays as it is in v1** (hidden behind the
   experimental toggle). Removing it is a separate follow-up change.
9. Database identity: pin name + version + catalog id + digest when present. Missing
   digest is a creation warning. At run time a missing database refuses; a
   version/digest mismatch refuses unless `--allow-drift`.

## Scope of v1

Supported chain: one sample. Root FASTQ import (platforms and pairings the import
command already supports, as recorded) with optional recipe → Kraken2 classify or
profile (optionally with Bracken). Created from a Kraken2 analysis folder under
`<project>/Analyses/kraken2-*`.

Refused with a clear typed error (never a guess):
- the Kraken2 input is a derived FASTQ bundle, a merged/batch input, or more than one
  input
- the import record is missing, is not `lungfish import fastq`, or lacks needed fields
- `classification-result.json` lacks `originalInputFiles`
- the `extract` goal (no CLI flag); classify/profile only

Skipped with a warning: the non-replayable `lungfish-app gui-import` copy step
(GUIImportedProvenanceRehydrator.swift ~732-736).

Deferred: derived-bundle steps, batch/sample sheets, other analyses, `.lungfishflowpkg`
sharing, editing a template's settings, builder removal and its doc updates, pre-run
tool-version checks (v1 records versions after the run and warns on difference),
`--recipe-file` for `import fastq`.

## Components

LungfishWorkflow (`Sources/LungfishWorkflow/Templates/`):
- `AnalysisTemplate.swift`: model (`schemaVersion`, `id`, `name`, `createdAt`,
  `origin` {app version, source analysis relative path, source provenance ids and
  SHA-256}, `input` {kind fastq, platform, pairing, fileCount}, `steps` enum
  `.importFASTQ(ImportFASTQStepSpec)` / `.kraken2(Kraken2StepSpec)`,
  `creationWarnings`). Stable JSON (sorted keys, ISO dates). load/save. No absolute
  source paths stored.
- `AnalysisTemplateExtractor.swift`: analysis folder → template with typed errors and
  project-relative re-resolution when the recorded absolute input path moved.
- `FASTQImportCLIInvocationBuilder.swift`: typed import args → `import fastq` argv
  (with `--pairing`, `--name`, `--threads`); mirrors
  `CLIImportRunner.buildCLIArguments` (LungfishApp/Services/CLIImportRunner.swift
  ~195-240). Do not switch the GUI importer to it in v1.
- `AnalysisTemplateRenderer.swift`: pure (template + inputs + project + name + threads)
  → ordered rendered steps (argv, expected output) plus a placeholder form for display
  and shell export.
- `AnalysisTemplateRunner.swift`: preflight (input count vs pairing, recipe hash,
  database presence/version), run via injected `AnalysisTemplateStepExecuting`, locate
  each step's output, write the run-level provenance record, collect drift warnings.
- `AnalysisTemplateLibrary.swift`: list/save/delete in the app-wide folder
  (injectable directory for tests).

CLI (`Sources/LungfishCLI/Commands/WorkflowCommand.swift`, new `template` group):
- `workflow template create --from <analysisDir> [--name N] [--output F] [--format json|text]`
- `workflow template list [--format json|text]`
- `workflow template show <template> [--format json|text|shell]`
- `workflow template run <template> --project P <r1> [r2] [--name S] [--threads N] [--dry-run] [--allow-drift]`

GUI (every run through OperationCenter; GUI launches the bundled CLI, same pattern as
`WorkflowBuilderRunService.swift` ~308-383):
- "Save as Workflow Template…" in the sidebar context menu for Kraken2 analysis items
  (SidebarViewController+MenuDelegate.swift), and Tools > Workflows > "Save Selection
  as Workflow Template…". Sheet: name field, read-only numbered step list with key
  settings, creation warnings, Cancel/Save.
- Tools > Workflows > "Run Workflow Template…": sheet listing library templates,
  FASTQ chooser (sheet-presented open panel, never runModal), sample name, read-only
  steps, fixed resources (database and installed status), warnings, Cancel/Run.
  Missing database or recipe mismatch disables Run with an explanation.
- Accessibility identifiers for new controls.

## Tests (no real tools, no network)

- Extractor with a synthetic temp project (import provenance via ProvenanceRunBuilder +
  ProvenanceWriter, bundle metadata `recipeApplied`, `classification-result.json`
  modelled on `Tests/Fixtures/kraken2-bracken-reopen/`): happy path, missing
  originalInputFiles, derived input, missing import record, unknown recipe (warning),
  copy step skipped, moved project.
- Renderer golden argv: paired, single, interleaved, profile+Bracken, extra args;
  `--pairing`/`--name` present; no absolute source paths in template JSON.
- Runner with a fake executor: order, bindings, run record links; refusals on recipe
  hash mismatch, database version mismatch, missing database; `--allow-drift`.
- Model JSON round trip and schema-version rejection.
- CLI parsing, `run --dry-run`, `show --format shell`.

## Verification before merge

- New tests and affected existing suites pass.
- End-to-end CLI run on a throwaway project in the scratchpad with the Debug app's
  bundled CLI if a Kraken2 database is installed locally; otherwise dry-run end to end.
- One full unit tier (`scripts/full-suite-gate.sh --tier unit`) green on the
  integrated branch.
- Next Preview release notes describe the feature.

## Execution model

Fable implements in one isolated worktree (one building agent at a time). The session
orchestrator (Opus 5.5) wrote this plan from the two reviews, reviews the full diff,
runs the gate and integrates. The implementer never pushes or merges. Delete this plan
once v1 ships (docs retention rule).
