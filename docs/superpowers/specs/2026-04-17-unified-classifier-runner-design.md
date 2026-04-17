# Unified Classifier Runner Design

Date: 2026-04-17
Status: Proposed

## Summary

Replace the current split metagenomics run sheets with one unified classifier runner window for Kraken2, EsViritu, and TaxTriage. The new window should use the same in-window sidebar pattern already used by the welcome screen and Import Center, while keeping each tool's execution logic and configuration model intact.

This change also standardizes user-facing language:

- The optional pack description becomes `Taxonomic classification and pathogen detection from metagenomic samples`.
- FASTQ dataset actions become:
  - `Classify & Profile (Kraken2)`
  - `Detect Viruses (EsViritu)`
  - `Detect Pathogens (TaxTriage)`
- The TaxTriage runner title becomes simply `TaxTriage`.

## Goals

- Provide one consistent interface for running all in-app classifiers.
- Keep the internal configuration and pipeline execution for Kraken2, EsViritu, and TaxTriage stable in the first pass.
- Use shared layout, section names, and validation/footer behavior so the three tools feel like one family.
- Reuse existing Lungfish macOS design patterns instead of adding another separate wizard style.
- Reduce terminology that overemphasizes `clinical triage` when the actual user goal is pathogen detection from metagenomic samples.

## Non-Goals

- Do not merge external result importers such as NVD or NAO-MGS into this runner in this pass.
- Do not redesign the underlying pipeline engines or configuration object models.
- Do not collapse all tool-specific controls into one generic schema-driven form.
- Do not change classifier result viewing or import flows as part of this refactor.

## Current State

The app already groups Kraken2, EsViritu, and TaxTriage conceptually in FASTQ dataset operations, but running them still opens separate tool-specific sheets with different titles, layouts, spacing, and validation patterns.

There is also an existing `UnifiedMetagenomicsWizard`, but it currently acts as a two-step chooser that then hands off to the three legacy sheets. That preserves inconsistency instead of solving it.

## User-Facing Design

### Plugin Pack Copy

Keep the pack name `Metagenomics` for now, but change its description to:

`Taxonomic classification and pathogen detection from metagenomic samples`

This keeps the category recognizable while making the scope clearer and less awkward than the current phrasing.

### FASTQ Dataset Action Labels

Use these labels everywhere the run actions appear:

- `Classify & Profile (Kraken2)`
- `Detect Viruses (EsViritu)`
- `Detect Pathogens (TaxTriage)`

The action labels should describe what the user is doing, while still surfacing the underlying tool name.

### Unified Runner Window

All three run entry points should open the same classifier runner window.

The window should have:

- a left sidebar listing:
  - `Kraken2`
  - `EsViritu`
  - `TaxTriage`
- a right content pane for the selected tool
- a shared footer with inline validation on the left and `Cancel` / `Run` actions on the right

The selected tool should be preselected based on the launch source, so users still get directly to the tool they asked for.

### TaxTriage Title

When TaxTriage is selected, the title should be `TaxTriage`. Avoid composite titles such as `TaxTriage Metagenomic Triage`.

## Shared Right-Panel Structure

The right pane should use the same section rhythm for all three tools whenever the concept applies:

1. `Overview`
2. `Prerequisites`
3. `Samples`
4. `Database`
5. `Tool Settings`
6. `Advanced Settings`

Not every tool needs every section, but the order and naming should stay consistent.

### Shared Elements

These elements should be standardized across all three tool panels:

- Header block
  - tool name
  - one-line plain-language description
  - dataset name or sample count
- `Samples` section
  - same general table/list treatment
  - same single-sample vs batch framing
- `Database` section
  - same heading, spacing, and readiness styling
- `Prerequisites` section
  - same indicator language and badge style when shown
- `Advanced Settings`
  - same disclosure treatment
- Footer
  - same validation text placement
  - same action button placement

### Tool-Specific Elements

Tool-specific controls remain, but they are confined to the shared section shells:

- Kraken2
  - classification preset
  - confidence
  - abundance/profile behavior
  - memory mapping or similar advanced knobs
- EsViritu
  - quality filtering
  - minimum read length
  - thread control
- TaxTriage
  - sequencing platform
  - assembly toggle
  - workflow-specific scoring/runtime controls

This keeps the tools coherent without pretending they have identical requirements.

## Implementation Plan Shape

### Primary Refactor Target

Refactor `UnifiedMetagenomicsWizard` into the real shared runner surface instead of keeping it as a chooser.

The resulting structure should be:

- `UnifiedMetagenomicsWizard`
  - shared shell
  - shared sidebar
  - shared footer
  - selected tool state
- tool-specific content panels:
  - `Kraken2RunnerPanel`
  - `EsVirituRunnerPanel`
  - `TaxTriageRunnerPanel`
- shared view components for repeated sections:
  - header
  - prerequisites row
  - samples section container
  - database section container
  - advanced disclosure shell
  - validation/footer row

### Launch Routing

These existing app entry points should all open the unified runner window:

- `AppDelegate.launchKraken2Classification`
- `AppDelegate.launchEsVirituDetection`
- `AppDelegate.launchTaxTriage`

They should differ only in which tool is preselected and which callback is wired for the final run action.

Existing menu and context-menu entry points should remain intact from the user perspective, but they should all route to the same runner shell.

### Existing Tool Views

The current `ClassificationWizardSheet`, `EsVirituWizardSheet`, and `TaxTriageWizardSheet` should stop acting as standalone framed sheet windows.

In the first implementation pass, they can be:

- converted into panel-content views inside the shared shell, or
- partially decomposed so their reusable inner sections survive while their old outer framing is removed

The important constraint is that there must be one visible runner shell, not a nested “sheet inside a sheet” effect.

## Import/Run Boundary

Keep the boundary between running analyses and importing external results clear.

- Running classifiers belongs in the unified classifier runner.
- Importing external result bundles such as NVD or NAO-MGS remains separate.

Those imports may later share visual language, but they should not be merged into the classifier runner in this pass because they are a different task model.

## Naming And Copy Rules

- Prefer plain-language action names over workflow jargon.
- Keep the tool name visible in parentheses for orientation.
- Use `Detect Pathogens (TaxTriage)` instead of `Clinical Triage (TaxTriage)`.
- Avoid descriptive headers that repeat the same concept with extra words.
- Avoid using `metagenomic triage` as the primary run label.

## Apple HIG And Window Behavior

The unified runner should follow the same macOS-aligned principles already adopted elsewhere in Lungfish:

- one clear window purpose
- persistent in-window navigation for mode/category changes
- native spacing and hierarchy
- predictable footer actions
- no overloaded titlebar control maze

This is one reason the sidebar model is preferred over segmented toolbar tabs or a two-step chooser.

## Migration Sequence

1. Update visible copy:
   - metagenomics pack description
   - FASTQ dataset action labels
   - TaxTriage title text
2. Rework `UnifiedMetagenomicsWizard` into the real shared shell.
3. Route all three run launch paths to the unified shell.
4. Remove old standalone framing from the three tool-specific sheets.
5. Keep callback and pipeline execution behavior unchanged in this pass.

## Testing

### Label And Copy Tests

- Metagenomics pack description matches the new wording.
- FASTQ dataset action labels match the new wording.
- TaxTriage runner title is `TaxTriage`.

### Launch Routing Tests

- Kraken2 launch opens the unified runner with `Kraken2` selected.
- EsViritu launch opens the unified runner with `EsViritu` selected.
- TaxTriage launch opens the unified runner with `TaxTriage` selected.

### Shared Layout Tests

- Sidebar lists exactly the three runnable in-app classifiers.
- Shared sections appear in the expected order where applicable.
- Footer shows validation text plus `Cancel` / `Run`.

### Behavior Preservation Tests

- Existing run callbacks still receive the same configuration types:
  - `[ClassificationConfig]`
  - `[EsVirituConfig]`
  - `TaxTriageConfig`
- Existing prerequisite/database validation still blocks invalid runs.

## Risks

- The current sheet views may carry too much outer-window logic, so extracting shared content cleanly may require a slightly larger refactor than the UI suggests.
- TaxTriage has more prerequisite and sample-role complexity than the other two tools, so the shared shell must not flatten away important behavior.
- If the shared layout is too rigid, it could make one tool feel awkward. Shared section shells, not identical forms, are the correct balance.

## Recommendation

Proceed with a shared classifier runner shell built from the existing `UnifiedMetagenomicsWizard`, and keep imports separate from runs. This gives Lungfish one coherent interface for running classifiers without destabilizing the underlying tool execution code.
