# Wave 3 Dialog Test Hygiene Plan

Date: 2026-05-16
Worker: F
Worktree: `.worktrees/wave3-dialog-test-hygiene`
Branch: `codex/wave3-dialog-test-hygiene`
Base design: `docs/reviews/2026-05-16-wave3-next-phase-design.md`

## Inventory

- `Sources/LungfishApp/Views/Shared/DialogSheets.swift` already provides `WizardSheet` and `ImportSheet` with shared header, scrolling body, footer, default/cancel keyboard shortcuts, configurable status text, accessory text, primary button title, primary enablement, and fixed sizes.
- `Sources/LungfishApp/Views/Metagenomics/CzIdImportSheet.swift` still hand-rolls its header, scroll frame, destination section, footer buttons, fixed size, status/progress text, browse path, scan state, and primary enablement.
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift` uses a hand-rolled standalone sheet shell while the embedded operations-dialog mode is already footerless. It should migrate only the standalone shell to `WizardSheet` and leave the embedded mode stable.
- `Tests/LungfishAppTests/DialogShellTests.swift` covers only shared shell sizes, so CZ-ID-specific shell requirements are not yet behavior-covered.
- `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift` has behavior-level state tests, but still contains source-string assertions for embedded special-tool routing, embedded run-trigger wiring, viral recon run completion, operation routing project context, and derivative tool-pane controls.
- `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift` is almost entirely source-string based even though `DatabaseSearchDialogState`, `DatabaseSearchDestination`, `DatasetOperationsDialog`, and `DatabaseBrowserViewModel` expose enough behavior for several replacements.
- `Tests/LungfishAppTests/AssemblyWizardSheetTests.swift` source-reads `AssemblyWizardSheet.swift` for read-type confirmation, run gating, extra-arguments wording, and hifiasm profile behavior. Most of that can move to explicit presentation/helper values on `AssemblyWizardSheet` without broad UI refactoring.
- AppKit presenter files are out of scope for this worker and will not be modified.

## Slice Spec

- Migrate `CzIdImportSheet` to `ImportSheet` first. Preserve title, subtitle, dataset accessory text, size, help/accessibility identifier, body sections, browse behavior, scan behavior, cancellation behavior, and import callback semantics.
- Add a lightweight CZ-ID import presentation/state adapter that exposes primary enablement, selected path text, status/progress text, destination text, and cancellation/import behavior without reading Swift source.
- Migrate standalone `TaxTriageWizardSheet` to `WizardSheet` second. Preserve the embedded operations-dialog view, standalone size, title, subtitle, accessory text, validation/status message, primary enablement, cancellation, run callback, colors, and configuration content.
- Add minimal behavior-level hooks for touched source-string tests. Prefer state objects, presentation structs, existing command builders, or small internal static helpers over view introspection.
- Replace a constrained batch of touched source-string assertions in `FASTQOperationDialogRoutingTests.swift`, `DatabaseSearchDialogSourceTests.swift`, and `AssemblyWizardSheetTests.swift`. Keep genuine anti-pattern source tests only where behavior cannot practically be asserted in this slice.
- Do not change scientific data creation/import/export behavior. The provenance requirement remains unchanged; this slice only affects dialog shell presentation and tests.

## TDD / Red-Test Plan

1. Add `DialogShellTests` coverage for `ImportSheet` status/primary fields needed by CZ-ID. Expected red: missing helper/presentation snapshot on the shared shell.
2. Add CZ-ID import tests that instantiate a presentation/state adapter and verify:
   - no selected path disables the primary action,
   - scanning shows CZ-ID progress text and disables import,
   - a valid preview plus selected path enables import,
   - cancel requests cancel scan validation and call the cancellation callback,
   - import calls the import callback with the selected path.
   Expected red: no testable CZ-ID state/presentation adapter.
3. Add TaxTriage presentation tests for standalone title/subtitle/accessory/status/primary enablement independent of the SwiftUI body. Expected red: no testable standalone presentation adapter.
4. Replace selected FASTQ source-string tests with behavior-level assertions against `FASTQOperationDialogState`, `FASTQOperationToolID`, existing request builders, and a small `FASTQOperationEmbeddedToolPresentation` hook if needed. Expected red: missing presentation hook for special embedded sheet routing/run trigger semantics.
5. Replace selected database-search source-string tests with `DatabaseSearchDialogState` and `DatasetOperationsDialog` construction behavior. Expected red: missing dialog presentation snapshot for accessibility namespace and selected destination content.
6. Replace `AssemblyWizardSheetTests` with behavior tests against explicit `AssemblyWizardPresentation`, profile option, extra-arguments label, and readiness helpers. Expected red: missing exposed helpers or internal access levels.
7. Capture red output from the narrow filters before production edits.

## Implementation Plan

1. Add test-only production-facing hooks in the smallest internal form:
   - shared dialog snapshot values on `ImportSheet`/`WizardSheet`,
   - `CzIdImportPresentation` or equivalent internal struct,
   - `TaxTriageStandalonePresentation` or equivalent internal struct,
   - small assembly presentation/static helpers where existing private computed values are source-tested,
   - small FASTQ/database presentation hooks only if existing state objects do not already cover the behavior.
2. Migrate `CzIdImportSheet.body` from manual `VStack`/footer to `ImportSheet`. Reuse existing content sections and callbacks.
3. Migrate `TaxTriageWizardSheet.standaloneBody` from manual shell to `WizardSheet`. Keep `embeddedBody` unchanged.
4. Replace source-string assertions in the three touched test files with behavior-level assertions. Remove local repository source loaders from files where no remaining source reads need them.
5. Run narrow green tests after each migration/replacement batch, then the full verification target.
6. Review `git diff --check`, inspect changed files, and commit only this slice.

## Verification Commands

- `swift test --filter DialogShellTests`
- `swift test --filter 'CzIdImportWorkflowTests|CzIdDataConverterTests'`
- `swift test --filter FASTQOperationDialogRoutingTests`
- `swift test --filter DatabaseSearchDialogSourceTests`
- `swift test --filter AssemblyWizardSheetTests`
- `swift build --product Lungfish`
- `git diff --check`

## Residual Risks

- SwiftUI view behavior remains best covered by presentation/state hooks rather than full rendered UI tests in this slice.
- Some source-string tests in unrelated files may remain by design; this slice only replaces the constrained touched batch.
- TaxTriage prerequisite checking depends on installed external tools and database registry state. Tests will avoid launching that asynchronous environment check unless explicitly covered by injectable state.
- FASTQ AppKit presenter routing is owned by Worker E and will not be changed; any remaining source-level presenter checks outside this slice may need a later worker.
