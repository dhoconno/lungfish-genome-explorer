# Final Fix Report: Special Database Version Semantics / Bracken Lifecycle

## Commits

- `e3731b63 fix: prepare databases from current catalog recipe`
- `b9320093 fix: harden Bracken managed source lifecycle`

## RED → GREEN evidence

### 1. Current catalog entry is used before special-database preparation

- RED: added `testSpecialRecipeDownloadUsesCurrentCatalogVersionForPreparationManifestAndReceipt` and ran:

  ```sh
  swift test --filter MetagenomicsDatabaseRegistryTests/testSpecialRecipeDownloadUsesCurrentCatalogVersionForPreparationManifestAndReceipt --quiet
  ```

  It failed at compile time with the expected missing catalog-injection interface (`extra argument 'catalog' in call`).
- GREEN: injected the catalog into `MetagenomicsDatabaseRegistry`, resolved the current catalog record before preparation, and persisted the resolved record. The same command passed: 1 test, 0 failures.

### 2. Live Bracken runtime and all executable probes

- RED: `swift test --filter ManagedToolSourceInstallerTests --quiet` produced the three expected new assertion failures: a live conda-record drift, missing compiler, and missing `libomp.dylib` were each accepted incorrectly.
- RED: `swift test --filter PluginPackStatusServiceTests/testManagedBrackenReadinessRunsAllInstalledRuntimeProbes --quiet` failed because `bracken-build -v` and `src/kmer2read_distr --help` were not run.
- RED: `swift test --filter CondaOfflinePackServiceTests/testOfflinePackPreservesManagedBrackenOverlayRecordAndPayload --quiet` failed because no automatic post-import probes were recorded.
- GREEN: receipt validation now binds to current conda package records, compiler, and OpenMP runtime (with portable path rebasing). Final status probes all three commands through micromamba; offline import probes installed paths and stores the probe argv/exit status/stderr in provenance.

### 3. Failed explicit reinstall restores a known-good environment

- RED: `swift test --filter PluginPackStatusServiceTests/testFailedExplicitReinstallRestoresKnownGoodEnvironmentAndRefreshesStatus --quiet` failed four assertions: the original environment was absent, its known-good executable was gone, and status became `needsInstall`.
- GREEN: explicit reinstalls now move the existing environment to a same-filesystem backup, discard it only after source overlay and final readiness succeed, and restore it after any failed replacement. The same command passed: 1 test, 0 failures.

### 4. Mutation transaction is process-safe across overlay and final readiness

- RED: `swift test --filter PluginPackStatusServiceTests/testConcurrentBrackenMutationsSerializeOverlayAndFinalReadiness --quiet` failed its expected assertion: a second transaction entered source-overlay publication while the first was still protected.
- GREEN: added `CondaEnvironmentMutationLock`, backed by the existing process-safe `flock` implementation. `PluginPackStatusService` acquires sorted per-environment locks before backup/conda mutation, holds them across source-overlay publication and final status, and releases them with `defer` on success, error, or cancellation. Blocking lock acquisition runs in a detached utility task so it cannot starve the transaction which must release the lock. The final readiness-gated regression passed and observed the expected wait diagnostic.

## Focused verification

```sh
swift test --filter ManagedToolSourceInstallerTests --quiet
# 14 executed; 1 opt-in live proof skipped; 0 failures

swift test --filter CondaOfflinePackServiceTests --quiet
# 6 executed; 0 failures

swift test --filter PluginPackStatusServiceTests/testManagedBrackenReadinessRunsAllInstalledRuntimeProbes --quiet
# 1 executed; 0 failures

swift test --filter PluginPackStatusServiceTests/testFailedExplicitReinstallRestoresKnownGoodEnvironmentAndRefreshesStatus --quiet
# 1 executed; 0 failures

swift test --filter PluginPackStatusServiceTests/testConcurrentBrackenMutationsSerializeOverlayAndFinalReadiness --quiet
# 1 executed; 0 failures; observed "waiting for conda lock held by pid …"

git diff --check
# clean
```

## Self-review

- The scientific data path preserves the resolved current catalog identity in both preparation inputs and receipt/manifest persistence; no live registry payload was changed.
- Offline readiness probes are recorded in the generated provenance parameters, including exact argv, status, and stderr, so the added scientific runtime validation remains reproducible.
- Backup restoration uses same-filesystem moves and rollback removes only the replacement before moving the original back. Backups remain until final readiness succeeds.
- Per-environment locking is deterministic for multi-environment packs (sorted acquisition), releases partial acquisitions on error, and defers release for the complete transaction.
- No archive-validation, source-overlay publication rollback, or offline portability checks were weakened.

## Remaining verification ownership / concern

The opt-in live Bracken proof remains skipped unless `LUNGFISH_LIVE_BRACKEN_ENV` and `LUNGFISH_LIVE_BRACKEN_PROOF` are set. The parent/controller is running the broader five database regression groups; this focused worker did not duplicate those groups after the final Bracken commit.
