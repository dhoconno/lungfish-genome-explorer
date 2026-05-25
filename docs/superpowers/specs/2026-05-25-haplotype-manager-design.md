# Haplotype Manager - Design Spec

**Date:** 2026-05-25
**Branch:** `main`
**Status:** Ready for user review

## Problem Statement

ONT genotyping can use deterministic haplotype definitions, but the definitions are difficult to discover before a run. The app already has a project-level `HaplotypeDefinitionStore`, built-in definition sets, and a low-level editor that is reachable from post-run genotype review surfaces. That is not enough for workflow setup. Users need to inspect, import, export, create, and edit haplotype definitions before launching ONT genotyping.

The manager also needs to handle two different lifecycle scopes:

- Global definitions that can be reused across projects.
- Project definitions that travel with the project and support project-specific auditability.

Definitions are not universally applicable. A haplotype set is valid only for a species, PCR amplicon or assay, and reference allele library context. The workflow UI must make that compatibility obvious and must not offer definitions as if they were generic labels.

## Goals

1. Expose a first-class Haplotype Manager before ONT genotyping runs.
2. Support built-in, global user, and project user definition scopes.
3. Make import, export, create, edit, duplicate, and delete actions available through both app UI and CLI.
4. Keep all mutating behavior CLI-backed so CLI tests can be written first and lab automation can use the same operations.
5. Track species, assay/amplicon, reference library, and loci compatibility metadata.
6. Preserve provenance and audit records for scientific-data definition changes.
7. Snapshot the selected definition into each ONT genotyping output bundle.

## Non-Goals

- Replacing the post-run haplotype review inspector.
- Building a new haplotype-calling algorithm in this feature.
- Making incompatible definitions silently usable through override switches.
- Editing built-in definitions in place.

## Approach Options

### Recommended: Global + Project Manager, CLI-Backed

Add a dedicated Haplotype Manager window/sheet with global and project scopes. The manager is reachable from the Tools menu only when an enabled workflow uses haplotype definitions, and from the ONT Genotyping workflow dialog through a `Manage...` button. All actions call shared command models used by `lungfish-cli haplotypes ...`.

This gives users an obvious pre-run management surface, keeps definitions reusable, keeps project-specific definitions portable, and creates a durable CLI contract.

### Minimal: Project-Only Import/Export Button

Add `Import...` and `Manage...` to the ONT workflow dialog, writing only to `<project>/Haplotype Definitions/`.

This is faster but fails the reusable-library requirement and makes cross-project lab definitions tedious.

### Full Package Registry

Treat haplotype definitions as plugin/workflow-library package assets, with versioned installed packs and dependency resolution.

This is useful for package distribution, but it is too large for the immediate need. The recommended design leaves room for package-backed definitions by keeping built-ins/global/project definitions behind one registry API.

## Architecture

### Storage Scopes

Definitions come from three ordered scopes:

1. **Built-in:** bundled with Lungfish, read-only, shipped with optional workflow support.
2. **Global user:** stored in Application Support, reusable across projects.
3. **Project user:** stored under `<project>/Haplotype Definitions/`, portable with the project.

Resolution order should prefer project definitions over global definitions, and global definitions over built-ins when IDs collide. Collisions must be visible in the manager so users can see which definition is active.

The existing project store remains the project-scope implementation. A parallel global store should use the same JSON schema, validation, and provenance model.

### Compatibility Metadata

Each definition set must carry explicit compatibility metadata:

- `speciesCode` and user-visible species name when available.
- `assayID` and assay display name.
- Amplicon or PCR scheme ID/name.
- Reference library ID/name/version when known.
- Covered loci.
- Schema version and last-modified metadata.

The ONT workflow dialog filters definitions by selected assay first. When reference library identity is available, the dialog should flag or hide incompatible definitions rather than letting users accidentally run the wrong set.

MCM and rhesus macaque definitions remain separate where biology requires it. For MCM, DQ and DP can be combined haplotypes. For rhesus macaques, DPA, DPB, DQA, and DQB remain separate definitions because the reporting and biology are more complex.

### CLI-Backed Command Surface

Every manager action must have a public CLI equivalent before the UI depends on it. The app must not directly mutate definition JSON from SwiftUI or AppKit views.

Initial command family:

```bash
lungfish-cli haplotypes list --scope all --project <project>
lungfish-cli haplotypes validate <definition.json>
lungfish-cli haplotypes import <definition.json> --scope global|project --project <project>
lungfish-cli haplotypes export <definition-id> --scope built-in|global|project --project <project> --output <path>
lungfish-cli haplotypes duplicate <definition-id> --from-scope built-in|global|project --to-scope global|project --project <project>
lungfish-cli haplotypes create --scope global|project --project <project> --assay <assay-id> --species <species-code>
lungfish-cli haplotypes update <definition-id> --scope global|project --project <project> --input <definition.json>
lungfish-cli haplotypes delete <definition-id> --scope global|project --project <project>
```

The CLI and UI should share a command service that:

- Validates the input definition before writing.
- Computes file checksums and sizes.
- Writes or updates provenance.
- Returns structured results for tests and UI refresh.
- Produces a reproducible argv string for every GUI-initiated mutation.

This makes the CLI the first testing surface and avoids a separate UI-only mutation path.

### Provenance and Audit

All create, import, export, duplicate, update, and delete actions are scientific-data management operations and must write provenance. Records must include:

- Workflow/tool name and version.
- Exact argv or reproducible shell command.
- User-visible options and resolved defaults.
- Input/output paths.
- File checksums and sizes.
- Runtime identity where available.
- Exit status, wall time, and stderr when useful.

Project-scope mutations write provenance alongside the project definition. Global-scope mutations write provenance in the global definition library. Export writes a sidecar provenance record next to the exported file when the destination is user-selected.

## User Experience

### Entry Points

The Haplotype Manager is exposed in two places:

1. `Tools > Haplotype Definitions...`
2. `Manage...` beside the ONT Genotyping haplotype assay/definition selectors.

The Tools menu item appears only when at least one enabled workflow declares that it uses haplotype definitions. Initially that means ONT Genotyping must be enabled in Workflow Library. If ONT Genotyping is disabled, the manager is not shown as a standalone tool.

The workflow dialog entry is visible in the ONT Genotyping panel and is available before running the workflow.

### Manager Layout

The manager should be a compact operational UI, not a wizard.

Left pane:

- Search field.
- Scope filter: All, Built-in, Global, Project.
- Grouped list by assay, species, and reference library.
- Badges for built-in, global, project, incompatible, and shadowed definitions.

Right pane:

- Definition summary.
- Compatibility metadata.
- Loci and haplotype table.
- Validation messages.
- Provenance summary for user definitions.

Actions:

- `New`
- `Import...`
- `Export...`
- `Duplicate to Global`
- `Duplicate to Project`
- `Edit`
- `Delete`
- `Reveal in Finder`

Built-ins are read-only. The primary path for changing a built-in is `Duplicate to Project` or `Duplicate to Global`, then edit the copy.

### Workflow Dialog Integration

The ONT Genotyping workflow dialog keeps the existing assay and definition pickers, but adds:

- `Manage...` beside the pickers.
- A compatibility note under the selected definition.
- Refresh after manager close so newly imported definitions are immediately selectable.

The workflow setup must expose the options needed to choose the correct haplotype definition before launch:

- Species or host taxon when the assay supports multiple species.
- PCR amplicon or assay scheme, such as MHC exon 2 MiSeq.
- Reference allele library, including display name and version when known.
- Haplotyping mode: `No haplotyping` or `Deterministic haplotyping`.
- Definition scope/source when more than one compatible definition exists: built-in, global, or project.

The definition picker is driven by these options. The app should not make users infer MCM versus rhesus or combined DP/DQ versus split DPA/DPB/DQA/DQB behavior from definition names alone. If a selected reference library does not provide enough identity metadata to prove compatibility, the dialog shows the definition as "reference not specified" rather than "compatible."

If no definition is selected, the workflow runs genotyping only. If a compatible definition is selected, deterministic haplotyping runs and the definition is snapshotted into the output bundle.

## Error Handling

Validation failures should be explicit and actionable:

- Invalid JSON or unsupported schema version.
- Missing assay/species metadata.
- Duplicate ID conflict.
- Incompatible assay/reference library.
- Empty loci or haplotypes.
- Haplotype with no diagnostic alleles.
- Project scope requested with no open project.

The CLI returns structured errors and non-zero exits. The UI presents the same errors in the manager without swallowing details needed for debugging.

## Testing Plan

CLI tests come first:

- `haplotypes validate` accepts known good built-in/project JSON and rejects malformed definitions.
- `haplotypes import` writes global and project definitions with provenance.
- `haplotypes export` writes portable JSON plus export provenance.
- `haplotypes duplicate` creates editable copies of built-ins without mutating built-ins.
- `haplotypes update/delete` mutate only user scopes and reject built-in scope.

Store and registry tests:

- Built-in, global, and project definitions merge in the expected precedence order.
- Shadowed definitions are reported.
- Compatibility filtering respects assay, species, and reference metadata.

App state tests:

- Workflow Operations shows manager access only when ONT Genotyping is enabled.
- Imported global and project definitions are selectable before running ONT genotyping.
- Closing the manager refreshes the workflow dialog registry.

UI tests should focus on discoverability and basic flows:

- Open Haplotype Manager from Tools when ONT Genotyping is enabled.
- Open manager from ONT Genotyping setup.
- Import a definition, select it, and produce a launch request containing the selected assay and definition IDs.

## Rollout

1. Add the CLI-backed haplotype command service and tests.
2. Add global definition storage and merged registry precedence.
3. Add import/export/duplicate/update/delete provenance.
4. Add Haplotype Manager view model and UI.
5. Add Tools menu gating and workflow dialog `Manage...` integration.
6. Verify ONT genotyping snapshots the selected definition into output provenance as it does today.

## Compatibility Decision

The initial implementation uses assay/species/reference metadata from definition JSON when available. It does not infer compatibility by parsing reference bundle contents. The UI shows unknown reference compatibility as "Not specified" rather than pretending it is verified.
