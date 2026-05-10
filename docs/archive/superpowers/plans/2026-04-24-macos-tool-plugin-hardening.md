# macOS Tool and Plugin Hardening Plan

## Implementation Steps

1. Add regression tests for transient smoke retries, ONT sidecar persistence, metadata-aware mapping detection, preferred mapping presets, scoped embedded readiness, and assembly pack gating.
2. Persist workflow platform metadata in `FASTQBatchImporter` and reuse the same platform-to-read-type mapping in ENA/SRA metadata augmentation.
3. Update mapping read-class detection and inspection to consult FASTQ sidecars before falling back to headers.
4. Add preferred mapping mode selection and use it in `MappingWizardSheet`; guard embedded `performRun()` with `canRun`.
5. Scope FASTQ operation embedded readiness callbacks by `FASTQOperationToolID` and update panes to capture the originating tool.
6. Retry plugin pack smoke tests, refresh pack status synchronously after install, await Plugin Manager status refresh, and notify from Welcome installs.
7. Gate assembly Run on selected tool readiness.
8. Run targeted tests, then broader Swift/Xcode verification, then build Debug and Release apps.
9. Merge the worktree branch back to `main` and remove the worktree.

## Test Focus

- `PluginPackStatusServiceTests`
- `FASTQBatchImportTests`
- `MappingInputInspectionTests`
- `MappingCompatibilityTests`
- `FASTQOperationDialogRoutingTests`
- `FASTQMetadataSectionTests`
- `WelcomeSetupTests` / `PluginPackVisibilityTests`
