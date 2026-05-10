# Generalized Temp Scope & Escaped-Temp Guard Design

**Date**: 2026-04-05  
**Status**: Proposed  
**Scope**: `ProjectTempDirectory`, temp callsites, DEBUG escaped-temp scanner

## Problem

The current DEBUG escaped-temp scanner infers errors only from:

1. directory prefix (`lungfish-*`, `esviritu-*`, etc.)
2. creation time in current session

This catches real regressions, but it cannot distinguish:

- project-required operations that accidentally fell back to system temp (true bug)
- operations where fallback is allowed (no-project contexts, some CLI flows)
- stale or external artifacts with matching prefixes

Recent evidence:

- `lungfish-demux-C51D...` triggered assertion in `AppDelegate`.
- `lungfish-demux-*` is created in `DemultiplexingPipeline.run()` via `ProjectTempDirectory.createFromContext(prefix: "lungfish-demux-", contextURL: config.outputDirectory)`.
- `createFromContext` falls back to system temp when no `.lungfish` root is found.

## Root Cause Class

There is no explicit temp-allocation policy attached to each callsite. The scanner has no provenance metadata to know whether a system-temp allocation was allowed.

## Goals

1. Enforce project `.tmp/` for project-required workflows.
2. Allow explicit system-temp fallback where valid.
3. Make DEBUG guard authoritative and low-noise.
4. Keep behavior deterministic and testable.

## Non-Goals

- Rewriting all temp-using workflows in one change.
- Changing release behavior beyond safer temp policy enforcement.

## Proposed Architecture

### 1) Introduce Explicit Temp Scope Policy

Add a policy enum in `ProjectTempDirectory`:

```swift
public enum TempScopePolicy: Sendable {
    case requireProjectContext
    case preferProjectContext(allowSystemFallback: Bool = true)
    case systemOnly
}
```

Add a new API:

```swift
public static func create(
    prefix: String,
    contextURL: URL?,
    policy: TempScopePolicy,
    caller: StaticString = #fileID,
    line: UInt = #line
) throws -> URL
```

Behavior:

- `requireProjectContext`: must resolve `.lungfish` root; otherwise throw `ProjectTempError.projectContextRequired`.
- `preferProjectContext`: use project `.tmp/` if found, else system temp.
- `systemOnly`: always system temp.

Keep existing `createFromContext` as compatibility shim, routed to `preferProjectContext`, then migrate callsites incrementally.

### 2) Add Temp Provenance Marker

When creating a temp dir, write a small marker file inside it, e.g. `.lungfish-temp-origin.json`:

- `version`
- `prefix`
- `createdAt`
- `pid`
- `policy`
- `contextPath`
- `resolvedProjectPath` (nullable)
- `caller` (`file:line`)

This gives the scanner ground truth.

### 3) Make DEBUG Scanner Policy-Aware

Update `debugScanForEscapedTempDirs()` to:

1. load marker metadata where present
2. assert only when:
   - marker indicates `requireProjectContext`
   - directory is in system temp
   - created by current app session
3. warn (not assert) when prefix matches but marker is absent (migration safety)

This removes prefix-only ambiguity.

### 4) Classify Callsites by Policy

Initial high-priority policy mapping:

- **requireProjectContext**:
  - app-driven derivative/pipeline work when a project/bundle context is expected (`demux`, `orient`, `spades`, classifier runs from project workflows)
- **preferProjectContext**:
  - CLI commands where output may be outside `.lungfish`
  - app flows that can run without open project
- **systemOnly**:
  - known no-project services (download staging, framework-driven temp copies)

### 5) Harden Project Root Discovery

`findProjectRoot` should not silently fail due path-depth assumptions. Replace fixed depth walk with filesystem-root walk, or increase depth with tests for deep derivative nesting.

## Acceptance Criteria

1. DEBUG assertions occur only for real policy violations (`requireProjectContext` escaped to system temp).
2. Valid fallback flows no longer crash DEBUG app.
3. Each escaped-temp assertion includes prefix, caller, context, and policy metadata.
4. Demux path (`lungfish-demux-*`) is correctly classified and behaves accordingly.

## Validation

1. Unit tests for `TempScopePolicy` behavior in `ProjectTempDirectory`.
2. Unit tests for marker creation and parsing.
3. App DEBUG scanner tests:
   - `requireProjectContext` + system temp => assert
   - `preferProjectContext` + system temp => no assert
   - prefix match without marker => warning-only during migration
4. Integration test for demux path in project and non-project contexts.

## Migration Strategy

1. Land policy API + marker + scanner changes behind compatibility shim.
2. Migrate highest-risk callsites first (`demux`, `esviritu`, `taxtriage`, `orient`, `spades`).
3. Expand to remaining prefixes in batches.
4. Once migration completes, tighten scanner treatment for unmarked prefixes from warning to assert.
