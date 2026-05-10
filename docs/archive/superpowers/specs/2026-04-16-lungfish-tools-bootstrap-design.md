# Lungfish Tools Bootstrap Design

Date: 2026-04-16
Status: Approved

## Scope

This design replaces bundled BBTools and the bundled JRE with micromamba-managed installs under `~/.lungfish`, adds a shared dependency registry for required and optional tool packs, updates the welcome screen to show plain-language setup status, hides inactive packs everywhere they appear, and makes the new welcome/setup UI explicitly follow current Apple Human Interface Guidelines for macOS.

It also removes bundled BBTools/JRE from release packaging after runtime callers have switched to the new managed locations, then measures the release build impact of that cleanup.

## Problem

Bundling BBTools and the JRE inside the app has created two practical problems:

- bundled BBTools/JRE complicate worktree behavior and release packaging
- BBTools shell wrappers and the bundled JRE path assumptions are a major source of failures when project paths contain spaces

The current app also has no single source of truth for tool availability:

- `CondaManager` already manages user-installed environments under `~/.lungfish/conda`, but required-before-launch tools are not modeled as one user-facing setup unit
- `WelcomeWindowController` is a static launcher and does not surface setup status
- `PluginPack.builtIn` currently exposes every pack, including packs that are not active yet
- BBTools and Java are still resolved from bundled resources in `NativeToolRunner` and downstream FASTQ/recipe services

This leaves GUI, CLI, plugin browsing, and runtime execution with overlapping but inconsistent ideas of what is installed, what is required, and what users should see.

## Goals

- Present required setup as one plain-language pack called `Lungfish Tools`.
- Keep the actual app logo, branding, and recent projects on the welcome screen.
- Restrict welcome-screen launch actions to `Create Project` and `Open Project`.
- Disable launch and recent-project reopening until `Lungfish Tools` is healthy.
- Keep the welcome/setup experience aligned with the current Apple Human Interface Guidelines for macOS windows, layout, onboarding, and accessibility.
- Use explicit user action to install or reinstall required tools. Do not auto-install on launch.
- Keep one conda environment per required tool under `~/.lungfish/conda/envs/<tool>`.
- Allow optional packs to remain non-blocking and installable separately.
- Hide inactive packs everywhere, including the welcome screen, Plugin Manager, and CLI pack flows.
- Move BBTools execution to the conda-managed install and let that environment provide Java.
- Keep Nextflow and Snakemake in small dedicated launcher environments while still allowing separate task-specific environments when needed.
- Remove bundled BBTools and JRE from the shipped app once no runtime code depends on them.
- Measure bundle size and release build time before and after the cleanup.

## Non-Goals

- Auto-installing missing required tools on app launch.
- Merging all required tools into one shared conda environment.
- Rewriting the entire plugin or package-management system.
- Surfacing low-level tool names as the primary welcome-screen experience.
- Showing inactive packs in a disabled or coming-soon state.
- Introducing a custom splash or launcher experience that departs from native macOS window behavior without a product need.
- Changing unrelated welcome-screen branding, recent-project behavior, or Apple HIG-aligned layout conventions.

## Current State

The existing seams for this refactor are:

- `Sources/LungfishWorkflow/Conda/CondaManager.swift`
  - owns `~/.lungfish/conda`
  - defines `PluginPack.builtIn`
  - already installs one conda environment per package/environment name
- `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
  - shows the app logo, version, recent projects, and three actions: `Create Project`, `Open Project`, and `Open Files`
- `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
  - reads `PluginPack.builtIn` directly and shows all packs
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
  - still models BBTools wrappers and `java` as bundled native tools under `Resources/Tools/bbtools` and `Resources/Tools/jre/bin/java`
- FASTQ and recipe services still set `JAVA_HOME` and `BBMAP_JAVA` from bundled resources
- `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`, `scripts/release/build-notarized-dmg.sh`, and `scripts/smoke-test-release-tools.sh`
  - still treat BBTools and OpenJDK as bundled release assets

## Design

### 1. Shared Dependency Registry

Add one shared registry that defines every installable pack and every required tool that backs those packs.

The registry must model two user-facing categories:

- `Lungfish Tools`
  - required before creating or opening a project
  - shown as a single setup unit in the welcome screen
  - internally expands to `nextflow`, `snakemake`, and `bbtools`
- `Optional Tools`
  - user-installable packs shown only when active
  - currently only `metagenomics` is active

Each registry entry should include:

- stable internal ID
- plain-language display name and description
- whether the pack is required before launch
- whether the pack is active and should be visible
- the environments or tools it owns
- install recipes and health-check rules
- a user-facing status summary and a diagnostics-friendly per-tool breakdown

Internally, `Lungfish Tools` remains a pack of individual tools. The UI does not lead with those tool names, but diagnostics and reinstall logic still operate at per-tool granularity.

### 2. Managed Core Tool Bootstrap

Add a bootstrap/status service that reads the registry and reports whether each visible pack is ready, missing, broken, installing, or failed.

For the required tool pack:

- `micromamba` remains the bootstrap binary at `~/.lungfish/conda/bin/micromamba`
- `nextflow` lives at `~/.lungfish/conda/envs/nextflow`
- `snakemake` lives at `~/.lungfish/conda/envs/snakemake`
- `bbtools` lives at `~/.lungfish/conda/envs/bbtools`

Launch-time behavior:

1. On every app start, run a fast local health check for the visible packs.
2. If all required tool environments are present and executable where expected, mark `Lungfish Tools` ready.
3. If any required tool is missing, corrupted, or not executable where expected, mark `Lungfish Tools` as needing install or reinstall.
4. Do not start installation automatically.
5. When the user clicks `Install` or `Reinstall`, install or repair the missing tools through micromamba, then rerun the health check immediately.

The health check should be conservative. Partial or stale installs in `~/.lungfish` should be treated as not ready rather than guessed into a usable state.

### 3. Welcome-Screen Behavior

Extend the existing welcome screen instead of replacing it.

The welcome window should be treated as the app's first real macOS window, not as a decorative launch-only experience. The setup UI should therefore follow the current Apple Human Interface Guidelines for macOS. Based on Apple's current guidance for launching, onboarding, windows, layout, and accessibility, that means the setup state should be integrated into the first usable window, preserve a clear visual hierarchy, keep controls and content easy to scan, and avoid turning the opening experience into a separate branded splash flow.

Keep:

- the actual app logo
- the existing branding treatment
- the recent-projects list

Change the launch surface to:

- show only `Create Project` and `Open Project`
- remove `Open Files` from the welcome screen
- add a plain-language `Required Setup` card for `Lungfish Tools`
- add a smaller section for active optional packs below it

Required setup UX:

- If `Lungfish Tools` is ready, show a green status and enable launch actions.
- If `Lungfish Tools` is not ready, show a red status and an `Install` or `Reinstall` action.
- While setup is not ready, disable `Create Project`, `Open Project`, and recent-project reopen actions.
- Keep recent projects visible even when they cannot yet be opened.
- Hide the per-tool details behind a disclosure such as `Show setup details`.
- Keep the layout feeling like a standard macOS window: native control patterns, clear alignment, restrained visual treatment, and no oversized branded takeover screen.
- Make status, disabled states, and install progress accessible and easy to distinguish without relying on color alone.
- Validate the layout at the supported welcome-window sizes so the setup card, actions, and recent-projects list remain readable and usable.

Optional packs UX:

- Show only active optional packs.
- Optional packs do not block launch.
- Each optional pack shows a simple ready/not installed state with a small green or red indicator.
- Selecting an optional pack from the welcome screen should open the Plugin Manager to that pack or its details so the user can install it.

Language should remain non-technical. Terms like `workflow`, `runtime`, or `wired up` should not appear in user-facing welcome-screen copy.

### 4. Plugin Manager And CLI Visibility

All pack lists must come from the same registry.

This means:

- `PluginManagerViewModel` must stop reading `PluginPack.builtIn` directly as the source of truth for visible packs
- the Plugin Manager should show only active packs
- the required base pack should be represented consistently as `Lungfish Tools`, even if detailed per-tool state is exposed in diagnostics or management views
- CLI pack listing and pack-install flows must also hide inactive packs

This keeps the GUI and CLI from drifting apart again as more packs are added.

### 5. Runtime Tool Resolution

BBTools must stop depending on bundled resources.

Runtime behavior changes:

- treat BBTools as a conda-managed core tool instead of a bundled native tool
- resolve BBTools entrypoints from the `bbtools` environment under `~/.lungfish`
- use the `bbtools` environment’s Java rather than a bundled `jre/bin/java`
- remove direct assumptions that `Resources/Tools/jre` exists

Affected callers include `NativeToolRunner` and the FASTQ/recipe services that currently build bundled `JAVA_HOME` and `BBMAP_JAVA` environments.

Nextflow and Snakemake should also resolve from their dedicated environments under `~/.lungfish`, but those environments should remain small launcher environments. Extra task-specific dependencies should continue to live in separate environments created for those operations rather than being stuffed into the `nextflow` or `snakemake` launcher environments.

### 6. Active-Pack Policy

`isActive` must be an explicit registry property, not a UI-only filter.

That property controls visibility everywhere:

- welcome screen
- Plugin Manager
- CLI pack listing and pack install entry points

Current policy for this branch:

- `metagenomics` is active
- all other optional packs are hidden

### 7. Migration And Release Cleanup

Implement the refactor in this order:

1. Add the shared registry and bootstrap/status service.
2. Switch runtime BBTools, Nextflow, and Snakemake resolution to the managed `~/.lungfish` installs.
3. Update the welcome screen and Plugin Manager to use the new required-pack and active-pack model.
4. Remove bundled BBTools and bundled JRE from resources, manifests, notices, signing steps, and smoke tests.
5. Measure the impact on release packaging.

Once runtime callers no longer depend on bundled BBTools or Java:

- remove `bbtools` and `openjdk` from bundled tool manifests where appropriate
- stop signing JRE launchers in release scripts
- update smoke tests to validate the new managed-tool expectations
- update notices and version summaries so they match the shipped app contents

## Error Handling

### Required Setup

- If `micromamba` is missing or invalid, surface `Install` or `Reinstall` for `Lungfish Tools`.
- If any required tool environment is missing, incomplete, or not executable, mark the pack as not ready.
- If installation fails, keep launch disabled and show a clear user-facing error with a retry path.

### Optional Packs

- If an optional pack is missing, show it as not installed without blocking launch.
- If optional-pack installation fails, keep the app usable and surface a retry path in the Plugin Manager and any welcome-screen affordance.

### Old Or Partial State

- If old bundled paths are still referenced by stale code, treat that as a migration bug and remove the dependency rather than adding fallback behavior.
- If `~/.lungfish` contains partial installs from interrupted work, require reinstall rather than attempting silent repair without user consent.

## Testing

Add coverage for four areas.

### 1. Registry And Status Detection

- `Lungfish Tools` is ready only when all required tools pass their health checks.
- missing or broken required-tool environments mark the pack as not ready.
- inactive packs do not appear in visible pack lists.
- active packs do appear in visible pack lists.

### 2. Welcome-Screen Behavior

- the app logo and recent projects still render
- `Open Files` is no longer offered on the welcome screen
- `Create Project`, `Open Project`, and recent-project reopen actions are disabled when `Lungfish Tools` is not ready
- those actions become enabled after successful install and recheck
- only active optional packs are shown

### 3. Runtime Behavior

- BBTools invocations resolve from the managed `bbtools` environment, not from bundled `Resources/Tools/bbtools`
- Java for BBTools comes from the managed environment, not bundled `Resources/Tools/jre`
- Nextflow and Snakemake resolve from their dedicated managed environments
- task-specific extra environments remain possible without polluting the core launcher environments

### 4. Release And Packaging

- bundled BBTools and bundled JRE are absent from the final app
- release scripts no longer sign JRE launchers
- smoke tests and version/notices outputs match the new shipped artifact

## Release Measurement

Capture before-and-after numbers for:

- app bundle size
- bundled-tools staging time during release preparation
- notarized release build duration

The goal is not just to remove BBTools/JRE from the app bundle, but to quantify whether that materially improves release packaging time and output size.

## Risks

The main risks are:

- runtime callers that still assume bundled `jre/bin/java`
- inconsistent pack visibility if any GUI or CLI path bypasses the shared registry
- partial user installs under `~/.lungfish` causing confusing state unless the health check is strict
- overexposing low-level tool details in the welcome screen and making setup feel technical

This design reduces those risks by centralizing registry data, making health checks conservative, and separating user-facing pack status from internal per-tool diagnostics.

## Open Decisions Resolved

- Required setup is shown as one user-facing pack, `Lungfish Tools`.
- Installation is explicit user action, not automatic.
- One environment per required tool remains the internal model.
- Inactive packs are hidden everywhere.
- Only active optional packs appear on the welcome screen.
- The welcome screen keeps the existing app logo, branding, and recent-project affordances.
