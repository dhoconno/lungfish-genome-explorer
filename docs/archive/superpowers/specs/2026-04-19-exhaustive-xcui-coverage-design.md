# Exhaustive XCUI Coverage Design

Date: 2026-04-19
Status: Proposed

## Summary

Build an app-wide XCUI and accessibility program for Lungfish that aims at exhaustive UI action coverage without collapsing into a brittle, slow, machine-specific test suite.

The main suite should use deterministic offline inputs, real Lungfish workflows, real menu and window interactions, and broad keyboard-plus-pointer coverage. Real `NSOpenPanel` and `NSSavePanel` flows should remain part of the test strategy, but in dedicated system-dialog coverage layers rather than as the default setup path for every test. Live network behavior should be validated in a narrow separate smoke layer, not in the default exhaustive suite.

This rollout should also treat accessibility as part of the same contract as XCUI. Stable identifiers, meaningful labels and values, predictable focus order, and keyboard-only access should be built alongside the test harness, not after it.

The first exemplar feature-specific pilot should cover the new assembly tool batch added on 2026-04-19:

- `SPAdes`
- `MEGAHIT`
- `SKESA`
- `Flye`
- `Hifiasm`

That pilot should validate not just launch gating, but end-to-end behavior through result creation, sidebar surfacing, and viewer opening, while explicitly recording current product gaps such as unfinished viewport designs or layouts.

## Goals

- Build a reusable app-wide XCUI harness rather than feature-specific one-off test plumbing.
- Reach exhaustive action coverage through an explicit inventory of user-visible actions.
- Keep the main suite deterministic and CI-safe by default.
- Exercise real Lungfish workflows after data enters the app, rather than shortcutting directly into preloaded UI state.
- Cover both pointer-driven and keyboard-driven interaction paths for important workflows.
- Improve accessibility at the same time as automation by standardizing identifiers, labels, values, and focus behavior.
- Make the UI action model automation-ready for future AppleScript and Shortcuts work.
- Preserve real macOS open/save panel coverage for critical entry and export paths.
- Add a small separate live-service smoke layer for remote integrations.
- Use the assembly tool batch as the first feature-specific pilot on top of the shared harness.

## Non-Goals

- Do not make every test depend on live network services.
- Do not make every test drive real `NSOpenPanel` and `NSSavePanel` setup.
- Do not treat AppKit system dialogs as a substitute for broad in-app workflow coverage.
- Do not claim exhaustive coverage by counting generic smoke tests as subsystem completion.
- Do not hide unfinished product surfaces behind vague test exclusions.
- Do not create multiple incompatible harness patterns for different subsystems.
- Do not implement full AppleScript or Shortcuts support in this rollout.

## Current State

The repository already has an initial macOS XCUI foothold:

- `Tests/LungfishXCUITests/DatabaseSearchXCUITests.swift`
- `Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift`
- `Sources/LungfishApp/App/AppUITestConfiguration.swift`
- `scripts/testing/run-macos-xcui.sh`
- `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchAutomationBackend.swift`

This proves the basic direction:

- the real macOS menu bar can be driven through XCUI
- the app can boot into deterministic UI-test scenarios
- stable accessibility identifiers can be added to production UI
- a feature can swap live backend behavior for deterministic fixtures only at the external boundary

However, the existing XCUI layer is still feature-local. Most of the app does not yet expose a reusable accessibility contract or a shared deterministic runtime model. The larger UI surface also includes many areas that go beyond database search:

- welcome/setup and project lifecycle
- main window shell, panes, and menus
- import and export flows
- sidebar and navigation flows
- viewer and inspector actions
- FASTQ workflows
- database search and import workflows
- metagenomics and classifier workflows
- workflow builder and execution flows
- settings, help, about, and auxiliary windows

The assembly tool batch added on 2026-04-19 is especially important because it represents the kind of multi-tool feature family Lungfish is likely to keep adding in batches. It already has lower-layer coverage for compatibility and command building, but it does not yet have full app-level proof that the UI, execution, sidebar, and viewer all hold together end to end.

## Coverage Model

Use four suite layers.

### 1. System-Dialog Smoke

Keep real `NSOpenPanel` and `NSSavePanel` coverage for critical entry and exit paths, including:

- opening an existing project
- creating a new project
- opening key import flows that depend on file panels
- key export/save actions

These tests should be isolated in a dedicated layer because AppKit system dialogs are slower and more machine-sensitive than the in-app UI.

### 2. App-Wide Navigation Smoke

Add a stable shell-level smoke layer that verifies:

- app launch
- welcome/setup path availability
- project opening
- major windows, panes, and menus
- core keyboard navigation and focus movement

This layer proves that the app shell is operable and that the harness is wired correctly before subsystem suites go deeper.

### 3. Subsystem Exhaustive Suites

Treat each subsystem as complete only when every inventoried user-visible action has deterministic XCUI coverage with the required pointer and keyboard paths.

### 4. Live-Service Smoke

Add a separate, narrow suite for real integrations such as NCBI, ENA, and Pathoplexus. This layer should verify that service contracts still work, but it must not be required for the main exhaustive suite to pass.

## End-To-End Fidelity Rules

The simulation boundary for the main suite should be external systems, not Lungfish internals.

### Main-Suite Rules

- Use real menu actions, sheets, windows, focus changes, persistence, progress UI, and result rendering.
- Use offline fixtures or recorded artifacts for remote responses, downloads, and other external inputs.
- Prefer the real Lungfish import, processing, persistence, sidebar update, and display pipeline after those inputs enter the app.
- Replace internal execution only when the real path is too slow, nondeterministic, or depends on unavailable external tools.
- When replacement is required, keep it narrow and preserve progress, completion, and error behavior.

### Network Policy

- Default suite: offline and deterministic.
- Separate suite: live-service smoke.

### System-Dialog Policy

- Real panels are required for critical entry and export workflows.
- Most subsystem tests should use deterministic fixture-loading helpers after those panel paths have been proven.

## Shared Harness Architecture

### 1. App-Wide UI Test Runtime

Expand the current `AppUITestConfiguration` concept into a reusable runtime layer that carries:

- whether UI-test mode is active
- named scenario identifiers
- fixture root locations
- backend mode such as deterministic or live smoke
- narrowly-scoped debug assists for slow or unsafe dependencies

The runtime must be inert during normal launches and reusable by every future feature suite.

### 2. Fixture Project Catalog

Maintain a curated fixture catalog under `Tests/Fixtures` and related support code. Fixtures should be chosen to unlock real workflow coverage, not single assertions.

The baseline catalog should include:

- empty and newly-created project states
- a genomics viewer project
- a FASTQ project
- a metagenomics/classifier project
- an import-heavy and export-heavy project
- assembly-pilot fixture inputs for the supported read classes

### 3. System-Dialog Driver Layer

Add a reusable robot layer that drives open/save panels attached to Lungfish windows. It should handle:

- targeting the correct sheet
- entering absolute fixture paths
- confirming creates, opens, and exports
- recovering from common focus or timing issues

This keeps fragile Finder-sheet logic out of individual tests.

### 4. External-Boundary Adapters

Inject deterministic adapters only at the external boundary:

- remote search services
- downloads
- optional long-running or unavailable external tools
- other OS-integrated behaviors that cannot be made stable under XCUI

The app should still execute its real internal state transitions, persistence, progress reporting, and rendering.

### 5. Shared UI Robots And Utilities

The shared harness should own generic capabilities only:

- app launch and runtime setup
- fixture loading
- panel driving
- menu and toolbar interaction helpers
- keyboard navigation helpers
- common wait and assertion helpers
- shared accessibility lookup conventions

It should not own feature-specific knowledge such as assembly compatibility rules or metagenomics-specific controls.

## Feature-Specific Suite Layer

Build feature-specific suites on top of the shared harness rather than forcing everything through one giant generic robot.

Initial suite families should include:

- `WelcomeAndProjectXCUITests`
- `MainWindowNavigationXCUITests`
- `ImportCenterXCUITests`
- `ViewerXCUITests`
- `FASTQWorkflowXCUITests`
- `DatabaseSearchXCUITests`
- `MetagenomicsXCUITests`
- `SettingsHelpAboutXCUITests`

Each feature suite should own:

- a feature robot
- a small set of canonical fixture scenarios
- an action inventory mapping every user-visible action to at least one test

Feature suites may add small local helpers, but they must not introduce independent launch modes, scenario plumbing, or backend injection models. Those belong in the shared harness.

## Accessibility Contract

Accessibility is part of the XCUI contract, not a separate cleanup pass.

### App-Wide Conventions

Define one app-wide convention for:

- window identifiers
- pane identifiers
- dialog identifiers
- list and row identifiers
- toolbar items
- primary and destructive actions
- status and validation text

### Feature-Level Requirements

Each tested surface should expose:

- stable accessibility identifiers for interactive controls
- meaningful accessibility labels, values, and roles
- deterministic keyboard focus order
- keyboard equivalents for high-value actions where appropriate
- both keyboard and pointer paths for important workflows

The goal is not only to make XCUI find controls, but to make the UI operable and inspectable for assistive technology users.

## Automation Readiness

This rollout should prepare Lungfish for future AppleScript and Shortcuts support without attempting to ship those automation surfaces yet.

### Current Boundary

The current repository does not expose an established AppleScript or Shortcuts integration surface. The exhaustive XCUI and accessibility rollout should therefore treat automation-readiness as a design constraint, not as a first-pass deliverable.

### What This Rollout Should Do

Use the XCUI and accessibility effort to standardize the pieces that future automation will need anyway:

- explicit user-action inventory
- stable semantic action names
- clear feature ownership for actions and parameters
- predictable state and validation models
- narrow external-boundary adapters
- reusable launch and scenario plumbing for deterministic automation

### What This Rollout Should Not Do

Do not add:

- AppleScript dictionary and scriptability plumbing
- App Intents or Shortcuts actions
- new automation-only command surfaces that bypass the normal UI and workflow model

Those belong in a later dedicated automation phase once the app's action inventory and accessibility contract are stable.

### Action Inventory Extension

The UI action inventory should include an additional automation-readiness field for each action:

- `candidate for future automation`
- `not appropriate for automation`
- `blocked by unfinished product model`

Where useful, the inventory should also record likely future automation semantics, such as:

- action name
- required parameters
- required project or selection context
- expected result or side effect

This allows the XCUI/accessibility program to shape the app around stable actions now, without forcing immediate AppleScript or Shortcuts implementation.

### Design Principle

Future automation should reuse the same action model the app exposes to users and tests. The XCUI and accessibility program should therefore avoid ad hoc state or one-off UI wiring that would make eventual scriptable actions inconsistent with normal user behavior.

## UI Action Inventory

Exhaustive coverage requires an explicit action inventory document. This inventory should be treated as the source of truth for completeness.

For each action, record:

- subsystem
- action name
- invocation mode:
  - `menu`
  - `toolbar`
  - `button`
  - `context menu`
  - `drag/drop`
  - `keyboard shortcut`
  - `system panel`
  - `canvas or viewport interaction`
- required coverage path:
  - `pointer`
  - `keyboard`
  - `both`
- required fixture or scenario
- boundary mode:
  - `deterministic offline`
  - `real system dialog`
  - `live smoke`
- owning XCUI test
- current status:
  - `covered`
  - `blocked by missing accessibility contract`
  - `blocked by unfinished product surface`

### Definition Of Done For A Subsystem

A subsystem is complete only when:

- every inventoried action is mapped to tests
- interactive controls have stable accessibility identifiers and labels
- important actions are operable by keyboard and pointer where required
- critical entry and export paths have real panel coverage
- deterministic XCUI passes locally and in CI
- any exclusions are explicit and justified

## Assembly Batch Pilot

The assembly tool batch added on 2026-04-19 should be the first feature-specific pilot on top of the shared harness.

### Why Assembly Is The Right Pilot

- it is a fresh multi-tool feature family
- it uses a shared wizard with tool-specific and read-type-specific behavior
- it includes managed execution rather than simple local UI-only state
- it must prove result creation, sidebar discovery, and viewer dispatch
- it matches the likely future pattern of adding related tools in batches

### Pilot Coverage Questions

For each of:

- `SPAdes`
- `MEGAHIT`
- `SKESA`
- `Flye`
- `Hifiasm`

the pilot must answer:

- does the tool appear in the assembly UI when expected?
- do incompatible read classes block launch with the correct message?
- do compatible read classes expose the correct controls and advanced options?
- can the run be launched end to end from the real app UI with deterministic inputs?
- does the result land in `Analyses/`?
- does the sidebar show the resulting analysis?
- does selecting the analysis open the assembly result viewer?
- do both keyboard and pointer paths work for the important actions?

### Pilot Execution Boundary

The assembly pilot should prefer real internal app behavior:

- real FASTQ operations dialog launch
- real shared assembly wizard
- real compatibility gating
- real output directory creation
- real analysis discovery in `Analyses/`
- real sidebar refresh and result selection
- real assembly result viewer dispatch

Where full assembler execution is too slow or unavailable for CI, deterministic tool-boundary adapters may be used, but they must preserve the real app behavior after execution completes.

### Existing Evidence And Gaps

The current codebase already provides lower-layer assembly evidence:

- compatibility and command construction coverage in workflow tests
- assembly routing coverage in app tests
- assembly analysis discovery and sidebar plumbing in production code

However, there is not yet app-level end-to-end XCUI proof for all five tools, their visible option states, their result surfacing, or their keyboard-accessibility behavior.

### Current Product Gaps That Must Be Tracked

The assembly pilot must explicitly record missing product components instead of silently skipping them. Current examples include:

- incomplete assembly result viewport design maturity
- stubbed contig-row detail in `AssemblyResultViewController`
- unimplemented assembly export behavior
- incomplete per-contig sequence extraction behavior
- any missing layout or viewport work needed to make assembly results genuinely testable

These are not merely test gaps. They are product gaps that must be incorporated into the broader UI action and accessibility program so the eventual exhaustive suite can cover them honestly.

## Missing Component Tracking

The exhaustive XCUI program must include a mechanism for recording incomplete product surfaces that block meaningful coverage.

Examples:

- missing viewport designs
- unfinished result layouts
- stubbed or partial viewer implementations
- missing keyboard affordances
- controls without stable accessibility contracts

Each such gap should be recorded in the action inventory or a directly-linked companion document with:

- the affected subsystem
- the blocked user action
- the missing product component
- the impact on XCUI and accessibility coverage
- the implementation work required before coverage can be considered complete

This prevents the project from confusing "untested" with "not yet fully built."

## Rollout Strategy

### Phase 1. Shared Harness And Inventory

- expand the app-wide UI-test runtime
- create the fixture catalog
- add shared robots and panel drivers
- create the first action inventory document
- establish accessibility naming conventions

### Phase 2. Welcome And Project Lifecycle

This remains the first foundational subsystem because it unlocks the rest of the app:

- new project
- open project
- required setup handling
- storage chooser behavior
- recent project flows

This phase should include the critical real `NSOpenPanel` and `NSSavePanel` paths.

### Phase 3. App-Shell Navigation Smoke

- main window shell
- core pane toggles
- major menu paths
- basic keyboard navigation and focus behavior

### Phase 4. Assembly Batch Pilot

Use the shared harness to validate the full assembly feature family end to end and to prove the framework can handle batch-added tools with shared UI and divergent state rules.

### Phase 5. Remaining Subsystem Rollout

Proceed subsystem by subsystem:

- import and export flows
- database search and import
- viewer and inspector
- FASTQ workflows
- metagenomics and classifier workflows
- workflow builder and execution
- settings, help, about, and auxiliary windows

Each subsystem should be closed against its action inventory before moving on.

## Testing Expectations

The final program should produce:

- deterministic local and CI XCUI execution for the default suite
- a separate live-service smoke lane
- explicit subsystem completion criteria
- accessibility improvements that are enforced by the same suite structure

The intended end state is not "many UI tests." It is a maintained coverage system where Lungfish can add new feature batches, such as the new assembly tools, and immediately fit them into a reusable end-to-end XCUI and accessibility framework.
