# Managed Bracken Source Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a checksum-pinned modern Bracken source overlay in Lungfish's managed conda environment so `bracken-build` is real, verified, offline-exportable, and correctly identified in provenance.

**Architecture:** Extend a tool requirement with an optional typed source overlay, implement the Bracken overlay as a transactional download/extract/compile/publish service, and integrate it into the existing pack-install rollback boundary. Readiness and database provenance consult the overlay installation record; final non-ready status is an installation error.

**Tech Stack:** Swift 6, Foundation/URLSession, CryptoKit, Swift Package Manager tests, micromamba, managed clang/OpenMP runtime, Lungfish provenance models

---

### Task 1: Managed Bracken overlay and authoritative pack verification

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Create: `Sources/LungfishWorkflow/Conda/ManagedToolSourceInstaller.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`
- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
- Create: `Tests/LungfishWorkflowTests/ManagedToolSourceInstallerTests.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift`

- [ ] **Step 1: Write the failing pack-contract and verification tests**

Assert the Bracken requirement no longer installs `bioconda::bracken=1.0.0`,
declares the v3.1 overlay URL/checksum, and still requires both executables.
Add a service test whose install action creates an incomplete environment and
assert `install(pack:reinstall:progress:)` throws instead of returning success.

Run:

```bash
swift test --skip-update --filter 'MetagenomicsPluginPackTests|PluginPackRegistryTests|PluginPackStatusServiceTests'
```

Expected: RED because the overlay model and verification error do not exist.

- [ ] **Step 2: Add the typed overlay descriptor and installed-record contract**

Add a Codable/Hashable descriptor shaped as:

```swift
public struct PackToolSourceOverlay: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable { case bracken }
    public let kind: Kind
    public let version: String
    public let sourceURL: URL
    public let sha256: String
}
```

Add `sourceOverlay: PackToolSourceOverlay?` to `PackToolRequirement` with a
default of `nil`. Configure Bracken v3.1 and pinned dependencies, retaining the
existing environment/executable/license/source metadata.

Define a stable JSON installed record at
`share/lungfish/managed-tools/bracken.json` containing source identity,
install commands, runtime, installed file descriptors, timestamps, status,
stderr, and wall time. Expose a read-only `CondaManager` method returning a
validated overlay version for consumers.

- [ ] **Step 3: Write source-installer tests and verify RED**

Use a synthetic tarball and injected downloader/process runner. Cover:

- correct SHA and expected archive structure publish both scripts plus payload;
- a checksum mismatch publishes nothing;
- absolute/parent-traversal archive members are rejected;
- compile failure preserves the prior installed overlay;
- cancellation publishes nothing;
- the installation record has exact URL/SHA/version/argv, checksums/sizes,
  runtime identity, exit status, bounded stderr, and wall time.

Run:

```bash
swift test --skip-update --filter ManagedToolSourceInstallerTests
```

Expected: RED because `ManagedToolSourceInstaller` does not exist.

- [ ] **Step 4: Implement the minimal transactional source installer**

Download the small pinned archive, verify SHA-256, inspect archive member paths,
extract in a temporary sibling directory, validate required regular files, and
compile the four upstream C++ translation units with a compiler from the
managed environment. Link against the environment's `libomp` with an
environment-relative rpath. Stage `bracken`, `bracken-build`, and `bin/src`
without editing upstream scientific algorithms; smoke-probe all three entry
points before atomic replacement and installed-record publication.

Use dependency injection for download/process/filesystem/time/UUID so tests are
network-free. All subprocess calls use argument arrays, never shell command
interpolation.

- [ ] **Step 5: Integrate the overlay into the install transaction**

Add a source-install action dependency to `PluginPackStatusService`. For an
overlay requirement, reserve part of the item's progress for the source step.
Include the source step and final `computeStatus` in the existing rollback
`do/catch`. Add an Equatable localized verification error containing the first
missing executable or smoke/metadata failure. Do not emit a ready/success final
event on this path.

Status evaluation validates the installed overlay record against the descriptor
before smoke tests, and fingerprint calculation includes that record.

- [ ] **Step 6: Use overlay identity in database provenance**

Update `ManagedMetagenomicsDatabaseToolRunner.resolveManagedToolVersion` so
`bracken-build` first reads the validated managed overlay record, then falls
back to conda metadata for legacy/non-overlay tools. Add a focused test proving
the new source version is used and the old `bracken=1.0.0` identity cannot leak
into a new database-install step.

- [ ] **Step 7: Verify GREEN and broader compatibility**

Run:

```bash
swift test --skip-update --filter 'ManagedToolSourceInstallerTests|MetagenomicsPluginPackTests|PluginPackRegistryTests|PluginPackStatusServiceTests|MetagenomicsDatabaseInstallerTests|MetagenomicsDatabaseInstallProvenanceTests|CondaOfflinePackServiceTests'
git diff --check
```

Expected: all selected tests pass with zero failures and no warnings introduced
by changed files.

- [ ] **Step 8: Perform a real temporary-environment proof**

Using a temporary micromamba root (never the user's active environment), install
the exact declared dependencies and run the production overlay installer.
Verify:

```text
<temp>/envs/bracken/bin/bracken --help
<temp>/envs/bracken/bin/bracken-build -v
<temp>/envs/bracken/bin/src/kmer2read_distr --help
```

Then export/import the Metagenomics offline pack fixture and repeat the probes
against the imported environment. Record exact exit codes and reported versions.

- [ ] **Step 9: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift \
  Sources/LungfishWorkflow/Conda/ManagedToolSourceInstaller.swift \
  Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift \
  Sources/LungfishWorkflow/Conda/CondaManager.swift \
  Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift \
  Tests/LungfishWorkflowTests/ManagedToolSourceInstallerTests.swift \
  Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift \
  Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift \
  Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift \
  docs/superpowers/specs/2026-08-14-bracken-managed-source-install-design.md \
  docs/superpowers/plans/2026-08-14-bracken-managed-source-install.md
git commit -m "fix: install managed Bracken build tools"
```
