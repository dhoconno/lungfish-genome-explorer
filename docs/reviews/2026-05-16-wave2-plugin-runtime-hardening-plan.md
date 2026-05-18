# Wave 2 Plugin Runtime Hardening Plan

Date: 2026-05-16
Branch: `codex/wave2-plugin-runtime-hardening`

## Goal

Close the re-review gaps left after the plugin-pack rollback work:

- Treat live-observed `env-<32 hex>` conda environments as orphan runtime/plugin
  leftovers in the Plugin Manager Installed tab.
- Do not return a stale plugin-pack status when the persisted status snapshot's
  filesystem fingerprint no longer matches current disk state, even if the
  snapshot is still inside the TTL.

## Scope

- `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
- `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`
- `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`

## Test-First Steps

1. Add a Plugin Manager test that supplies `env-<32 hex>` and verifies it is
   moved to `orphanedEnvironments`.
2. Add a plugin-pack status test that:
   - creates a ready pack and persists a ready status snapshot,
   - removes the executable to change the fingerprint while keeping TTL fresh,
   - creates a new service instance and asks for status,
   - expects `.needsInstall` immediately, not stale `.ready`.
3. Run the focused tests and verify they fail on the current implementation.
4. Implement the smallest production changes:
   - normalize the orphan environment matcher to accept bare hex and `env-hex`;
   - wait for a refresh task when a cached snapshot has no matching
     fingerprint instead of returning it inside `cacheLifetime`.
5. Re-run focused tests and build affected targets.

## Verification

- `swift test --filter PluginPackVisibilityTests/testInstalledTabSeparatesEnvPrefixedHashNamedOrphanEnvironments`
- `swift test --filter PluginPackStatusServiceTests/testStatusForPackRefreshesFreshPersistedSnapshotWhenFingerprintChanges`
- `swift test --filter 'PluginPackVisibilityTests|PluginPackStatusServiceTests'`
- `swift build --target LungfishApp`
