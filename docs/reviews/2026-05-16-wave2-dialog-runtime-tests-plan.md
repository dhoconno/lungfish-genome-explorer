# Wave 2 Dialog Runtime Tests Plan

Worker E scope: shared dialog shells, runtime status polish, and focused test hygiene for FASTA, live database gates, ENA/SRA batch behavior, and source-string test replacement.

## Issues

- W2-E-001: Wizard/import sheets duplicate header, scroll, footer, and fixed-size structure. First migration should preserve embedded EsViritu mode and avoid modal API churn owned elsewhere.
- W2-E-002: Plugin Manager required setup pack can show a primary Install action even when the pack is already ready.
- W2-E-003: Welcome required setup ready-state behavior is covered by a brittle source-string assertion instead of a behavioral model assertion.
- W2-E-004: `FASTARealFileTests` depend on `/Users/dho/Desktop/test2/My Genome Project.lungfish` and silently skip when absent.
- W2-E-005: Live database integration tests run by default and only some transient network failures skip consistently.
- W2-E-006: `SRABatchLookupTests` is compile-only because it passes an empty accession list.
- W2-E-007: Dialog shell primitives need focused tests so later migrations have a stable contract.

## Red Tests And Source Checks

- `rg -n '/Users/dho/Desktop|testProjectPath|XCTSkipUnless|skipIfTestDirectoryMissing' Tests/LungfishIOTests/FASTAReaderTests.swift`
  - Found hard-coded Desktop fixture path at line 794, skip helper at lines 802-804, and 10 tests calling the skip helper.
- `swift test --filter FASTARealFileTests`
  - Passed only by skipping all selected tests: executed 10 tests, 10 skipped, 0 failures.
  - Skip reason: `Test data directory not found at /Users/dho/Desktop/test2/My Genome Project.lungfish`.
- `rg -n 'XCTSkip|transientLiveNCBISkipReason|NCBIService\\(|ENAService\\(|SRAService\\(' Tests/LungfishCoreTests/Services/DatabaseServiceIntegrationTests.swift`
  - Found live service construction in tests without an explicit opt-in gate.
- `rg -n 'accessions: \\[\\]|testBatchLookupMethodExists|searchReadsBatch' Tests/LungfishCoreTests/SRABatchLookupTests.swift`
  - Found compile-only empty batch lookup coverage.
- `rg -n 'status\\.shouldReinstall \\? "Reinstall"|pack\\.isRequiredBeforeLaunch|Button\\(actionTitle\\)|if !isReady|Color\\.accentColor|\\? \\.green|\\? \\.red' Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift Tests/LungfishAppTests/WelcomeSetupTests.swift`
  - Found Plugin Manager required-pack action branch before ready-state handling.
  - Found Welcome ready-state coverage as source-string assertion.
- `swift test --filter DialogShellTests` after adding tests and before production code
  - Failed to compile because `WizardSheetSize`, `ImportSheetSize`, `PackCardPresentation`, and `RequiredSetupCardPresentation` were not in scope.

## Implementation

- Add shared `WizardSheet` and `ImportSheet` primitives under `Sources/LungfishApp/Views/Shared`.
- Migrate `OrientWizardSheet` and standalone `EsVirituWizardSheet` to `WizardSheet`; keep EsViritu embedded mode unchanged.
- Migrate `NaoMgsImportSheet` and `NvdImportSheet` to `ImportSheet`; leave `CzIdImportSheet` modal browsing untouched to avoid Worker C call-site churn.
- Add `PackCardPresentation` so Plugin Manager decides primary action from ready/reinstall/required status before rendering.
- Add `RequiredSetupCardPresentation` and replace the high-value Welcome ready-state source-string test with behavioral assertions.
- Replace Desktop FASTA fixtures with package resources already copied under `Tests/LungfishIOTests/Resources`.
- Gate `DatabaseServiceIntegrationTests` behind `LUNGFISH_RUN_LIVE_DATABASE_TESTS=1` and keep transient skips for opted-in live runs.
- Replace empty SRA batch coverage with mocked ENA batch behavior that verifies URL construction, progress callbacks, result order, and per-accession failure tolerance.

## Verification

- `swift test --filter DialogShellTests`: passed, 3 tests.
- `swift test --filter PluginPackVisibilityTests`: passed, 10 tests.
- `swift test --filter WelcomeSetupTests/testRequiredSetupPresentation`: passed, 2 tests.
- `swift test --filter FASTAReaderTests`: passed, 34 tests.
- `swift test --filter FASTARealFileTests`: passed, 10 tests, 0 skips.
- `swift test --filter DatabaseServiceIntegrationTests`: passed, 10 tests skipped by explicit `LUNGFISH_RUN_LIVE_DATABASE_TESTS=1` gate.
- `swift test --filter ENAServiceTests`: passed, 11 tests.
- `swift test --filter SRABatchLookupTests`: passed, 2 tests.
- `swift build --target LungfishApp`: passed.
- `rg -n '/Users/dho/Desktop|testProjectPath|XCTSkipUnless|skipIfTestDirectoryMissing' Tests/LungfishIOTests/FASTAReaderTests.swift`: no matches.
- `rg -n 'accessions: \\[\\]|testBatchLookupMethodExists' Tests/LungfishCoreTests/SRABatchLookupTests.swift`: no matches.
- `git diff --check`: passed.

## Residual Risks

- Only the first wizard and import sheet migrations are in scope. Remaining sheets may still duplicate shell structure after this lane.
- Live database tests remain skipped by default; they require an explicit environment opt-in for real network verification.
- CZ-ID import shell migration is intentionally deferred because its open-panel modal flow is part of another worker's coordination surface.
