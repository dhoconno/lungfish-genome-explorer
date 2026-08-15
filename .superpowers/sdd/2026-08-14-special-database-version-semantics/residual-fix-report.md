# Residual Fix Report: Shared Conda Mutation Lease and Offline Import Recovery

## Scope

This residual pass closes the two remaining review findings:

1. all conda-environment mutation paths share one process-safe transaction;
2. offline imports roll back destination state and retain failure provenance.

No live registry payloads or `~/.lungfish/live` state are used.

## RED → GREEN evidence

### Shared environment transaction

- RED: `testPublicCondaReinstallCannotEnterWhilePackOverlayTransactionIsHeld`
  failed before production changes with:

  ```text
  A public CondaManager reinstall must not remove the pack environment before source-overlay publication finishes.
  ```

- RED: `testOfflineImportCannotOverwriteEnvironmentWhilePackOverlayTransactionIsHeld`
  failed before production changes because the offline overwrite entered while
  the pack source-overlay gate was still held.

- GREEN: `CondaEnvironmentMutationTransaction` acquires sorted per-environment
  `flock`s first and the conda-root lock second. `PluginPackStatusService`
  keeps that lease through backup, package mutation, overlay publication, and
  final readiness. Its production CondaManager calls reuse the lease rather
  than self-reacquiring it. Public CondaManager create/remove/install/reinstall/
  uninstall operations acquire the same transaction when no lease is supplied.
  Offline import parses and validates its manifest before acquiring the same
  transaction for all target environments.

### Offline failure recovery and provenance

- RED: `testFailedManagedBrackenProbeRestoresExistingEnvironmentAndWritesFailureProvenance`
  failed before production changes: the known-good payload was removed and no
  failure receipt existed.

- GREEN: offline imports copy into same-filesystem staging, move an existing
  destination to a backup only at publication, and restore all touched
  destinations in reverse order on error. New destinations and staging are
  removed. Probe failures retain exact final-payload argv, exit status, and
  stderr in `.lungfish-offline-pack-install-failure.provenance.json`.

- Additional coverage: `testManifestValidationFailurePreservesDestinationAndWritesFailureProvenance`
  proves checksum validation fails without replacing the destination and emits
  a failed receipt.

## Failure receipt self-review

- The failure writer runs after `rollbackOfflineImport` and rescans only the
  final/restored destination files for its output records.
- The probe-failure regression verifies the receipt fingerprints the restored
  known-good payload and does not list the rejected `kmer2read_distr`
  replacement as an output.
- It also verifies exact final-payload probe argv, exit status `17`, and
  stderr `kmer probe failed\n`.
- Receipts include redacted command argv, resolved overwrite/environment
  options, source and destination paths, manifest/input checksums and sizes,
  final output checksums and sizes, runtime identity, exit status, stderr, and
  wall time.

## Focused verification

```sh
swift test --skip-build --filter CondaOfflinePackServiceTests --quiet
# 8 executed; 0 failures; 1.702s

swift test --skip-build --filter CondaManagerTests --quiet
# 52 executed; 0 failures; 6.465s

swift test --skip-build --filter PluginPackStatusServiceTests/testConcurrentBrackenMutationsSerializeOverlayAndFinalReadiness --quiet
# 1 executed; 0 failures; 0.192s

swift test --skip-build --filter PluginPackStatusServiceTests/testFailedExplicitReinstallRestoresKnownGoodEnvironmentAndRefreshesStatus --quiet
# 1 executed; 0 failures; 0.409s

swift test --skip-build --filter PluginPackStatusServiceTests/testInstallRejectsNonReadyManagedSourceOverlayAndRollsBackEnvironment --quiet
# 1 executed; 0 failures; 0.508s

swift test --skip-build --filter PluginPackStatusServiceTests/testPublicCondaReinstallCannotEnterWhilePackOverlayTransactionIsHeld --quiet
# 1 executed; 0 failures; 2.115s; observed lock wait

swift test --skip-build --filter PluginPackStatusServiceTests/testOfflineImportCannotOverwriteEnvironmentWhilePackOverlayTransactionIsHeld --quiet
# 1 executed; 0 failures; 2.033s; observed lock wait

git diff --check
# clean
```

## Remaining concern

Controller review subsequently completed the full `PluginPackStatusServiceTests`
class: 37 tests passed with no failures in 41.292 seconds.

Controller review also caught and repaired three offline-transaction edge cases
with explicit RED → GREEN coverage:

- rejecting `overwrite: false` now distinguishes staged data from published
  data and cannot remove the untouched existing environment;
- failure to discard a hidden backup after verified publication and durable
  success provenance cannot roll back the committed replacement;
- failure to write mandatory failure provenance is surfaced as a blocking
  combined error instead of being silently discarded.

The expanded `CondaOfflinePackServiceTests` class passes 11/11. The combined
database/UI regression selection passes 117 XCTest tests plus 33 Swift Testing
tests. Its managed-Bracken provenance fixture now supplies the complete pinned
compiler/OpenMP runtime required by production receipt validation.
