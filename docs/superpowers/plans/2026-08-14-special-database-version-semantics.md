# Special Database Version Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a newly built SILVA or Greengenes catalog database from immediately reporting a false update while preserving safe migration and scientific provenance.

**Architecture:** Keep `MetagenomicsDatabaseInfo.version` as the catalog recipe version for catalog-managed installations, and retain local build identity in `payloadDigest`, timestamps, and canonical provenance. During manifest load, normalize affected `built-*` special-database records only when their successful final provenance proves they were built from the current catalog recipe and matches the registered path and payload digest.

**Tech Stack:** Swift 6, XCTest, LungfishWorkflow provenance envelopes, JSON registry persistence.

## Global Constraints

- Every scientific database installation must retain exact tool, argv, runtime, input/output checksum, size, exit status, wall-time, and useful stderr provenance.
- Pre-built and non-catalog database version behavior must remain unchanged.
- A migration must not mark an older special recipe current merely because its version starts with `built-`.
- Manifest writes remain atomic through the existing `saveManifest()` implementation.

---

### Task 1: Persist catalog recipe versions after managed installation

**Files:**
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift:886-906`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift:929-936`

**Interfaces:**
- Consumes: `MetagenomicsDatabaseRegistry.catalogEntry(matching:) -> MetagenomicsDatabaseInfo?`
- Produces: managed catalog rows whose `version` equals the current catalog recipe version; `PreparedMetagenomicsDatabaseInstallation.result.version` remains the fallback for non-catalog rows.

- [ ] **Step 1: Change the injected-install regression test to express the desired behavior**

In `testRecipeDownloadUsesInjectedInstallerAndPersistsBeforeFinalize`, replace the generated-version expectation with:

```swift
XCTAssertEqual(stored.version, "kraken2-special-v1")
XCTAssertFalse(stored.isUpdateAvailable)
XCTAssertEqual(stored.payloadDigest, installer.digest)
```

- [ ] **Step 2: Run the focused test and verify the RED failure**

Run:

```bash
swift test --skip-update --filter MetagenomicsDatabaseRegistryTests/testRecipeDownloadUsesInjectedInstallerAndPersistsBeforeFinalize
```

Expected: FAIL because the stored value is `built-20260812-aaaaaaaaaaaa`.

- [ ] **Step 3: Make the minimal registry assignment change**

After installation preparation succeeds, resolve the current catalog entry before falling back to the generated version:

```swift
db.version = Self.catalogEntry(matching: db)?.version
    ?? prepared.result.version
```

Do not alter `payloadDigest`, timestamps, final-path publication, rollback, or provenance generation.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same filtered command. Expected: PASS with no failures.

- [ ] **Step 5: Commit the isolated behavior change**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift
git commit -m "fix: retain special database recipe versions"
```

### Task 2: Safely migrate affected successful records

**Files:**
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift:288-350,1015-1090`

**Interfaces:**
- Consumes: `ProvenanceEnvelopeReader.loadCanonical(fromSidecar:)`, `ProvenanceWriter.provenanceFilename`, `catalogEntry(matching:)`.
- Produces: `currentCatalogVersionProvenByReceipt(for:) -> String?`, a private pure decision helper except for reading the final sidecar.

- [ ] **Step 1: Add a failing successful-migration test**

Create a mock special Kraken2 payload, generate its snapshot, and write final success provenance with the current SILVA catalog row. Persist an otherwise-ready row whose version is `built-20260815-<digest-prefix>`, then load a fresh registry and assert:

```swift
XCTAssertEqual(migrated.version, "kraken2-special-v1")
XCTAssertFalse(migrated.isUpdateAvailable)
```

Decode `metagenomics-db-registry.json` afterward and assert the normalized version was durably saved.

- [ ] **Step 2: Add a failing mismatched-provenance test**

Write the same ready manifest, but create success provenance from a SILVA row whose version is `kraken2-special-v0`. Assert after load:

```swift
XCTAssertTrue(persisted.version?.hasPrefix("built-") == true)
XCTAssertTrue(persisted.isUpdateAvailable)
```

This test may already pass before implementation; retain it as the safety boundary paired with the RED migration test.

- [ ] **Step 3: Run both migration tests and verify the intended RED result**

Run:

```bash
swift test --skip-update --filter MetagenomicsDatabaseRegistryTests/testLegacyBuiltSpecialDatabase
```

Expected: the current-recipe migration test FAILS because `loadIfNeeded()` leaves `built-*` unchanged; the mismatched-recipe test passes.

- [ ] **Step 4: Implement provenance-gated normalization during manifest load**

Add a private helper that returns the current catalog version only when all of these are true:

```swift
database.status == .ready
database.version?.hasPrefix("built-") == true
database.installationRecipe is .kraken2Special
database.catalogID resolves to a current catalog entry with a nonempty version
database.path and database.payloadDigest are present
the final .lungfish-provenance.json decodes canonically
envelope.workflowName == "metagenomics.database.install"
envelope.workflowVersion == catalog.version
envelope.exitStatus == 0
envelope.options.resolvedDefaults["payloadAggregateSHA256"] == database.payloadDigest
envelope.options.resolvedDefaults["intendedFinalPath"] == database.path.standardizedFileURL.path
```

During the existing manifest decode loop, apply the returned version and track a `didMigrateVersion` flag. Save the manifest after catalog merging when either `addedCount > 0` or `didMigrateVersion` is true. Do not recompute the multi-gigabyte payload digest during startup.

- [ ] **Step 5: Run the migration tests and verify GREEN**

Run the same filtered command. Expected: both tests PASS.

- [ ] **Step 6: Run the complete database regression groups**

Run:

```bash
swift test --skip-update --filter MetagenomicsDatabaseInfoTests
swift test --skip-update --filter MetagenomicsDatabaseRegistryTests
swift test --skip-update --filter MetagenomicsDatabaseInstallerTests
swift test --skip-update --filter MetagenomicsDatabaseInstallProvenanceTests
swift test --skip-update --filter DatabasesTabTests
git diff --check
```

Expected: all tests pass and the diff check is clean.

- [ ] **Step 7: Commit the migration**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift
git commit -m "fix: migrate special database build versions"
```

### Task 3: Repair the live record and publish a verified debug bundle

**Files:**
- Build: `build/Debug/Lungfish.app`
- Verify: `/Users/dho/.lungfish/databases/metagenomics-db-registry.json`

**Interfaces:**
- Consumes: the provenance-gated migration in `MetagenomicsDatabaseRegistry.loadIfNeeded()`.
- Produces: a debug app whose Plugin Manager shows SILVA installed without an update badge.

- [ ] **Step 1: Build the debug app**

Run:

```bash
./scripts/build-app.sh --configuration debug --log-dir build/logs
```

Expected: exit 0 and `build/Debug/Lungfish.app` exists.

- [ ] **Step 2: Verify bundle identity and signature**

Run:

```bash
codesign --verify --deep --strict --verbose=2 build/Debug/Lungfish.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/Debug/Lungfish.app/Contents/Info.plist
```

Expected: signature validation succeeds and identifier is `com.lungfish.browser.debug`.

- [ ] **Step 3: Exercise migration using the bundled CLI code path**

Run the new bundle's database-list command, which initializes the same shared
database registry without interrupting the user's running app:

```bash
build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli conda db list --format json
```

Then read the persisted SILVA row and assert:

```text
status = ready
version = kraken2-special-v1
payloadDigest = 8e9a80931c7070a39de23f18d60d08f7a37afda0b8b9f9803fdf179d9f6137c4
```

The final provenance sidecar must remain unchanged and successful.

- [ ] **Step 4: Obtain independent review**

Ask a reviewer to inspect the final diff for update semantics, migration safety, provenance preservation, and test coverage. Resolve any Critical or Important finding before handoff.
