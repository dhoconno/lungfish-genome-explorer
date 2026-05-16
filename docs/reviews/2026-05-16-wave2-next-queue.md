# Wave 2 Next Queue Design

Date: 2026-05-16
Base: `codex/wave2-integrated-fixes` at `cd79d8e1`
Source review: `.claude/worktrees/fervent-boyd-45e388/review/2026-05-15`

## Goal

Continue the Codex remediation wave after the first integrated lanes by fixing
the remaining high-value review findings that still show up in the current
source tree. Preserve scientific provenance as a blocking requirement for any
workflow that creates, imports, transforms, exports, or wraps data.

## Current Triage

The integration branch already contains fixes for several stop-the-bleeding
items:

- Managed assembly now materializes virtual FASTQ inputs before MEGAHIT/native
  execution and records materialization provenance.
- AppDelegate and ViralRecon pipeline operations have cancel callbacks wired to
  OperationCenter.
- Plugin pack install failure paths roll back attempted conda environments and
  invalidate the persisted status cache.

The next queue is therefore:

1. `P1-architecture-lungfishcore-imports-appkit`: remove AppKit from
   `LungfishCore` color/settings models.
2. `P1-architecture-cli-imports-lungfishapp`: move CLI-used, UI-free import
   services into `LungfishWorkflow` and drop the `LungfishCLI -> LungfishApp`
   dependency.
3. Remaining Desktop-only test fixtures: replace `GFF3RealFileTest` and
   `VCFRealFileTests` Desktop paths with package fixtures.
4. `P1-runtime-database-recommended-exceeds-system-ram`: centralize database
   recommendation so no exceeding-RAM database can be recommended.

## Worktree Slices

### Slice A: Core AppKit Boundary

Branch: `codex/wave2-core-appkit-boundary`

Files expected:

- Modify `Sources/LungfishCore/Models/SemanticColors.swift`
- Modify `Sources/LungfishCore/Models/SequenceAppearance.swift`
- Modify `Sources/LungfishCore/Models/AppSettings.swift`
- Add a Foundation-only color value type, likely
  `Sources/LungfishCore/Models/HexColor.swift`
- Add AppKit adapters in `Sources/LungfishApp/Support/` or another app-owned
  location, because `LungfishUI` was intentionally deleted in the prior
  boundary cleanup.
- Update `Tests/LungfishCoreTests/SequenceAppearanceTests.swift` and add
  explicit tests that `LungfishCore` exposes hex/color-value behavior without
  importing AppKit.

Design notes:

- Keep persistence stable: existing saved color hex strings must decode without
  migration.
- `SemanticColors` should expose stable Foundation values or hex strings.
  App-owned extensions may convert to `NSColor`.
- `AppSettings` should retain the existing `@MainActor` singleton unless a
  smaller safe move is obvious. The required fix is removing AppKit from the
  core module, not reworking observation semantics.
- Avoid introducing a replacement UI module.

Verification:

- `rg -n '^import (AppKit|SwiftUI)' Sources/LungfishCore Tests/LungfishCoreTests`
  must return no production Core matches and only acceptable test matches if
  the test target explicitly needs AppKit for adapter tests.
- `swift test --filter SequenceAppearanceTests`
- `swift test --filter AppSettingsTests`
- `swift build --product lungfish-cli`
- `swift build --target LungfishApp`

### Slice B: CLI/App Boundary

Branch: `codex/wave2-cli-app-boundary`

Files expected:

- Move UI-free files from `Sources/LungfishApp/Services/ApplicationExports/` to
  `Sources/LungfishWorkflow/ApplicationExports/`.
- Move UI-free files from `Sources/LungfishApp/Services/Geneious/` to
  `Sources/LungfishWorkflow/Geneious/`.
- Move `CzIdImportPreview.swift`, `CzIdDataConverter.swift`, and
  `CzIdProjectImportWorkflow.swift` from
  `Sources/LungfishApp/Views/Metagenomics/` to
  `Sources/LungfishWorkflow/Metagenomics/CzId/`.
- Move or split `ReferenceBundleImportService` so the CLI can import
  references through `LungfishWorkflow` without `LungfishApp`.
- Change CLI imports in `ApplicationExportImportSubcommands.swift`,
  `CzIdCommand.swift`, and `ImportCzIdSubcommand.swift` from `LungfishApp` to
  `LungfishWorkflow`.
- Remove `LungfishApp` from the `LungfishCLI` target dependency in
  `Package.swift`.
- Update `Tests/LungfishCLITests/ImportCzIdCommandTests.swift` and any moved
  test imports so CLI tests do not import `LungfishApp`.

Design notes:

- This slice is a file ownership move, not a behavior rewrite.
- Preserve all scientific import provenance fields when moving CZ-ID and
  application-export import code.
- Leave AppKit/SwiftUI presentation surfaces in `LungfishApp`; only pure
  conversion/import/workflow code moves.
- If a singleton is only app ergonomics, keep a thin app wrapper and move the
  implementation below it.

Verification:

- `rg -n '^import LungfishApp' Sources/LungfishCLI Tests/LungfishCLITests`
  returns nothing.
- `swift build --product lungfish-cli`
- `swift test --filter ImportCzIdCommandTests`
- `swift test --filter CzIdDataConverterTests`
- `swift test --filter CzIdImportWorkflowTests`
- Inspect `otool -L .build/debug/lungfish-cli` for no AppKit/SwiftUI linkage
  after Slice A is integrated too.

### Slice C: Desktop Fixture Removal

Branch: `codex/wave2-io-fixtures`

Files expected:

- Modify `Tests/LungfishIOTests/GFF3RealFileTest.swift`
- Modify `Tests/LungfishIOTests/VCFRealFileTests.swift`
- Add small package fixtures under `Tests/LungfishIOTests/Resources/` if the
  existing `sample.gff3` and `sarscov2_*.vcf` resources do not cover the test
  assertions.

Design notes:

- Remove all `/Users/dho/Desktop/...` paths.
- Prefer existing package resources over new large fixtures.
- Remove silent skips for committed resources.
- Keep the tests behavior-level; do not replace with compile-only assertions.

Verification:

- `rg -n '/Users/dho/Desktop|Desktop/test|testProjectPath|skipIfTestDirectoryMissing' Tests/LungfishIOTests`
  returns nothing.
- `swift test --filter 'GFF3RealFileTest|VCFRealFileTests'`
- `swift test --filter LungfishIOTests`

### Slice D: Database Recommendation

Branch: `codex/wave2-db-recommendation`

Files expected:

- Modify `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
  if recommendation state belongs in the view model.
- Prefer adding reusable recommendation logic below the UI if
  `Kraken2DatabaseRegistry` already owns database metadata.
- Modify or add `Tests/LungfishAppTests/DatabasesTabTests.swift`.

Design notes:

- Recommend the largest database whose RAM requirement is no more than 60% of
  physical RAM.
- If every database exceeds the limit, recommend the smallest viable option.
- Never put the `Recommended` badge on a row that reports
  `exceeds system RAM`.
- Header copy and row badge must use the same recommendation source.

Verification:

- Tests for 48 GB, 128 GB, and 8 GB scenarios.
- `swift test --filter DatabasesTabTests`
- `swift build --target LungfishApp`

## Review Gates

Each slice needs two independent reviews before integration:

1. Spec compliance review against this document and the original Claude issue.
2. Code-quality review for Swift/AppKit/module-boundary fit, composability, and
   provenance preservation where applicable.

If either review finds issues, the implementer must iterate in the same
worktree and the reviewer must re-check the fix.

## Integration Order

1. Slice C and Slice D can integrate first; they are small and low-conflict.
2. Slice A should integrate before the final CLI linkage check.
3. Slice B can be developed in parallel but final `otool` verification is most
   meaningful after Slice A is merged.

Final integration verification:

- `swift build --product lungfish-cli`
- `swift build --target LungfishApp`
- Focused tests from all slices
- `rg` checks for forbidden imports and Desktop paths
- `git diff --check`
- Produce a Debug build artifact path for user review
