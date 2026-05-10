# EsViritu Escaped Temp Guard False-Positive Design

**Date**: 2026-04-05  
**Status**: Proposed  
**Scope**: Debug escaped-temp guard (`AppDelegate`) and EsViritu test fixture temp handling

## Problem Statement

A debug-only assertion is firing:

- `DEBUG: Found escaped temp dir in system temp: esviritu-test-88B2C27B-4FED-4BE1-9C6A-4C1DFB149F8E`
- `Fatal error: Escaped temp dir found in system temp: esviritu-test-...`

The crash blocks app usage even though the directory is not an app runtime EsViritu result directory.

## Root Cause

### Direct Trigger

`debugScanForEscapedTempDirs()` in `Sources/LungfishApp/App/AppDelegate.swift` matches any system-temp directory with prefix `esviritu-` and asserts.

### Why This Specific Path Matches

`Tests/LungfishWorkflowTests/Metagenomics/EsVirituPipelineTests.swift` creates fixture directories in system temp with names:

- `esviritu-test-<UUID>`
- `esviritu-test-db-<UUID>`

These names begin with `esviritu-`, so they match the escaped-temp guard prefix list.

### Why It Persists

The `EsVirituConfigTests` class has no teardown cleanup for these fixture directories, so they remain in system temp long enough to be scanned by the app debug timer.

### Evidence Collected

- The exact failing directory exists at `$TMPDIR/esviritu-test-88B2C27B-...`.
- It contains `test.fastq`, matching the `makeFakeFastqFile()` helper in the test file.
- The guard assertion originates at `AppDelegate.swift:805` in the debug temp scanner.

## Desired Behavior

1. Keep the invariant that project-scoped runtime temp directories are created under `<project>.lungfish/.tmp/`.
2. Keep a strong debug regression detector for real escaped app temp dirs.
3. Do not crash on stale or test-owned system-temp directories unrelated to the current app runtime session.

## Non-Goals

- No behavior change to production/release builds.
- No broad rewrite of all temp handling in the codebase.

## Proposed Design

### 1) Session-Bounded Debug Scan

Track app launch time and only assert on escaped temp directories created during the current app session (not arbitrary recent entries in system temp).

### 2) Explicit Test-Prefix Exclusions

Exclude known test fixture prefixes from assertion checks:

- `esviritu-test-`
- `esviritu-test-db-`
- other `*-test-*` prefixes used only by tests if needed

This keeps the guard focused on production operation prefixes.

### 3) Test Fixture Hygiene

Update EsViritu tests to always remove created temp fixtures via teardown blocks or a managed test temp root removed in `tearDown`.

### 4) Optional Prefix Disambiguation in Tests

Rename test fixture prefixes to avoid colliding with runtime prefixes (for example `test-esviritu-...` instead of `esviritu-test-...`).

## Acceptance Criteria

1. Running EsViritu workflow tests no longer leaves `esviritu-test-*` artifacts in system temp after test completion.
2. Launching debug app after tests does not hit `Escaped temp dir found in system temp: esviritu-test-*`.
3. If a real runtime path creates `esviritu-*` in system temp during the same app session, the debug assertion still fires.

## Risks

- Over-broad exclusions could hide real regressions.
- Session-bound filtering must still catch leaks generated early in long-running sessions.

## Validation Plan

1. Run targeted EsViritu tests and verify fixture cleanup.
2. Launch app in DEBUG and allow scanner interval to run; verify no false positive.
3. Inject a controlled escaped temp dir with a production prefix during app runtime and verify assertion triggers.
