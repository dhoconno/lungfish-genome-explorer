# Wave 1 Runtime Plugins Plan

## Scope

- Keep changes inside the runtime/plugin, managed storage, metagenomics database recommendation, and small welcome/plugin-manager surfaces identified for Worker C.
- Follow red/green TDD for each behavior before production edits.
- Do not change scientific data provenance behavior.

## Implementation Plan

1. Add regression tests for `PluginPackStatusService.install()` failure handling: a failed multi-tool install must invalidate status caches and should remove newly-created conda environments when the failed operation did not request reinstall.
2. Add Plugin Manager Installed-tab tests and view-model state so hash-like orphan conda env directories are excluded from the normal installed list and exposed separately with diagnostic removal.
3. Add metagenomics RAM recommendation tests proving 48 GB RAM does not select the 67 GB Standard database, while 67 GB RAM can.
4. Add managed storage tests proving `LUNGFISH_CONDA_ROOT` overrides with spaces are rejected by the same path validation used for managed storage selection.
5. Add a welcome setup source/UI regression test so Ready required setup shows status/details controls without a primary Install action, then make the smallest view adjustment.

## Verification Targets

- `swift test --filter PluginPackStatusServiceTests`
- `swift test --filter PluginPackVisibilityTests`
- `swift test --filter MetagenomicsDatabaseRegistryTests`
- `swift test --filter ManagedStorageConfigStoreTests`
- `swift test --filter WelcomeSetupTests`
