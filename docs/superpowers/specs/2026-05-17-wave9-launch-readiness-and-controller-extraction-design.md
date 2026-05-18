# Wave 9 Launch Readiness And Controller Extraction Design

Date: 2026-05-17
Branch: `codex/wave9-appdelegate-setup`
Base: Wave 8 commit `d4976014`

## Problem Statement

Wave 9 should continue the cleanup work that was deferred after Wave 8:

- decompose `AppDelegate` and large viewer/controller files in narrow slices
- keep only useful static guard tests and replace brittle source-string checks when behavior seams exist
- clean up concurrency callback paths where real UI behavior can be tested
- address the welcome screen appearing stuck on "Checking Required Setup"

The setup screen eventually passed during manual review, so this is not currently proven to be a hard deadlock. It is still a product defect because the launch screen disables project actions while showing a generic spinner without enough progress detail.

## Evidence

The welcome model calls `statusProvider.visibleStatuses()` during launch refresh:

- `WelcomeWindowController.setupContent()` starts `Task { await viewModel.refreshSetup() }`
- `WelcomeViewModel.refreshSetup()` clears the required and optional statuses, then awaits `visibleStatuses()`
- `PluginPackStatusService.visibleStatuses()` computes `PluginPack.visibleForCLI`
- `PluginPack.visibleForCLI` is `[requiredSetupPack] + activeOptionalPacks`
- the current built-in registry contains the required setup pack plus 16 optional packs

That means the UI says "Checking Required Setup" while the cold path can also scan optional environments, fingerprints, conda metadata, managed databases, launchers, and smoke tests. The required setup card cannot appear until all visible statuses return.

There is also a redundant refresh shape after installation:

- `installRequiredSetup()` awaits `refreshSetup()`
- it then posts `.managedResourcesDidChange`
- the welcome model observes that notification and starts another `refreshSetup()`

The live sample taken after setup passed showed the app spending time in AppKit/OpenPanel/Services/IconServices activity, not a clear Lungfish setup deadlock. That should be treated as a separate UI/runtime observation unless a fresh repro shows setup code on the hot path.

## Approaches Considered

### Approach A: Required-First Launch Readiness

Add a required-first refresh path for the welcome screen. The welcome model should fetch `status(for: PluginPack.requiredSetupPack)` first, update project launch readiness as soon as that returns, then refresh optional pack statuses in a background phase.

Tradeoffs:

- Best user impact: create/open project can enable as soon as core setup is ready.
- Keeps optional pack checks available without blocking launch.
- Requires a small protocol/API extension or a view-model split between required and optional refreshes.

Recommendation: use this approach.

### Approach B: Keep One Status Call, Add Progress Text

Keep `visibleStatuses()` as the only launch call, but add staged progress messages and timing instrumentation.

Tradeoffs:

- Lowest implementation risk.
- Does not fix the core problem that optional pack checks block required setup readiness.
- Still leaves launch disabled longer than necessary.

This is acceptable only as a temporary diagnostic patch.

### Approach C: Broad AppDelegate/Launch Rewrite

Fold welcome setup, project opening, state restoration, and plugin status into a large new launch coordinator.

Tradeoffs:

- Could improve architecture long-term.
- Too much surface for this wave and mixes a user-visible bug with broad launch refactoring.
- Higher risk around provenance-sensitive project/import flows.

Do not use this approach for Wave 9.

## Recommended Design

### 1. Launch Readiness Refresh

Introduce a narrow welcome setup state model:

- `requiredSetupStatus`
- `optionalPackStatuses`
- `isRefreshingRequiredSetup`
- `isRefreshingOptionalPacks`
- optional `lastSetupRefreshDuration` or debug-only timing values

The launch flow should be:

1. Start required refresh on welcome creation.
2. Fetch `status(for: PluginPack.requiredSetupPack)`.
3. Set `requiredSetupStatus` and enable project actions if the status is ready or debug bypass is active.
4. Start optional pack refresh separately.
5. Populate optional status cards when optional checks complete.

The UI copy should distinguish these phases:

- required pending: "Checking core setup"
- required ready, optional pending: "Core tools installed. Checking optional tools..."
- optional failed or slow: show optional tool status in the optional section without blocking project creation/opening

If required setup is still pending after a short threshold, show a more specific message:

- "Checking required tool launchers and managed data..."
- "This can take longer after installation or after changing storage locations."

No workflow that creates/imports/transforms scientific data is added here, so the provenance rule does not add new output requirements for this slice.

### 2. Refresh Coalescing

Prevent duplicate welcome refreshes:

- Keep the notification observer, but make it call a coalescing method such as `scheduleSetupRefresh(reason:)`.
- Track the active refresh task and avoid starting another equivalent refresh while one is in flight.
- After `installRequiredSetup()` succeeds, either update state from the verified install status and post the notification, or refresh locally without re-observing the same post. It should not do both.

This should make setup state deterministic and easier to test.

### 3. AppDelegate Extraction Slice

Do not rewrite `AppDelegate`. Extract one small coordinator after launch readiness is fixed:

- `ProjectOpenCoordinator` or equivalent, owned by LungfishApp
- inputs: project URL, target `MainWindowController`, recent-project recorder, state saver callback
- responsibilities: open existing projects, create projects, record recents, route fallback working-directory openings
- non-goals: menu construction, app lifecycle, import pipelines, provenance behavior

The AppDelegate should remain the AppKit delegate and conductor. The extracted coordinator should be testable without opening full UI windows.

### 4. Viewer Controller Extraction Slice

Pick one viewer responsibility after the AppDelegate slice, not during the setup fix:

- preferred first target: result/bundle display routing, because it is a dispatch boundary with many existing extensions
- extract a small router or factory that maps loaded document/result types to viewport controllers
- leave drawing, sequence rendering, and metagenomics detail controllers untouched

This keeps the blast radius small and avoids a cosmetic file split that does not improve behavior.

### 5. Static Test Hygiene

Keep static source-string tests only when they enforce architectural policy that has no better runtime seam, such as "production code must not call `runModal()`."

Replace brittle source assertions when a behavior seam exists:

- welcome setup readiness
- classifier routing
- mapping/FASTQ dialog request construction
- window/layout presentation state

New tests should prefer:

- presentation structs
- injected providers
- command/request builders
- notification/coalescing state

### 6. Targeted Concurrency Cleanup

Do not ban every `Task { @MainActor }` or `await MainActor.run`. Clean only paths where a concrete callback or stale-update hazard exists.

Wave 9 targets:

- welcome setup refresh ordering and coalescing
- install progress callback state updates
- one operation progress coordinator if time remains, likely ONT import because prior dirty work and tests already point there

## Test Plan

Required tests for the setup slice:

- `WelcomeSetupTests` proves required setup can become ready while optional status refresh is still pending.
- `WelcomeSetupTests` proves launch remains disabled when required setup is missing, regardless of optional status state.
- `WelcomeSetupTests` proves duplicate `.managedResourcesDidChange` notifications coalesce into one in-flight refresh.
- `PluginPackStatusServiceTests` proves `status(for: .requiredSetupPack)` does not evaluate active optional packs.
- Optional: debug timing/logging test if timing is exposed through a small injectable clock.

Required tests for extraction slices:

- coordinator unit tests for project open/create success and fallback error paths
- existing AppDelegate/menu tests unchanged except for wiring updates
- focused viewer router tests before moving display-routing code

Verification before implementation completion:

- focused filters for changed tests
- `swift build --build-path /Users/dho/Documents/lungfish-genome-explorer/.build --disable-index-store -Xswiftc -gnone --target LungfishApp --target LungfishWorkflow`
- full `swift test --build-path /Users/dho/Documents/lungfish-genome-explorer/.build --disable-index-store -Xswiftc -gnone`
- debug app build and local welcome-screen review

## Implementation Order

1. Add the required-first setup API/state seam and failing welcome tests.
2. Implement required-first refresh and optional background refresh.
3. Add refresh coalescing and install-completion cleanup.
4. Verify welcome setup behavior in tests and the debug app.
5. Extract the AppDelegate project-open coordinator.
6. Replace source-string tests touched by those changes.
7. Consider one viewer display-router extraction if the setup and AppDelegate slices are stable.

## Non-Goals

- no broad AppDelegate rewrite
- no broad viewer rewrite
- no changes to scientific data output formats
- no optional-tool installation changes beyond status checking and UI readiness
- no new provenance writers unless a later implementation step introduces a new data-writing workflow
