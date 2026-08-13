# Kraken2 SILVA and Greengenes Database Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SILVA and Greengenes as ordinary downloadable Kraken2 databases that are built transactionally with Kraken2/Bracken managed tools and published only with complete reproducibility provenance.

**Architecture:** Preserve `MetagenomicsDatabaseRegistry.downloadDatabase(name:progress:)` as the only public installation entry point, but dispatch by a backward-compatible catalog recipe into a focused transactional installer. The installer stages and validates payloads, atomically replaces the final directory, writes canonical final-path provenance, and rolls back on every failure; Plugin Manager, CLI, and classifier consumers continue to use the existing catalog/status interface without seeing archive-versus-build differences.

**Tech Stack:** Swift 6, Foundation/URLSession, Swift concurrency, CryptoKit, XCTest, Swift Package Manager, micromamba-managed Kraken2 2.17.1 and Bracken, Lungfish canonical provenance envelopes

---

## Global constraints and file structure

- Scope is exactly SILVA and Greengenes. Never add RDP or an arbitrary `--special` option.
- Keep `DatabaseCollection` limited to AWS prebuilt indexes.
- Preserve existing decoded manifests and installed custom databases. Legacy ready entries without new digest metadata remain usable; every installation performed by the new workflow requires final-path provenance before becoming ready.
- Keep the public `downloadDatabase` name and Plugin Manager controls. User-visible progress strings are only `Downloading…`, `Preparing…`, and `Verifying…`; do not show “local build,” `kraken2-build`, or recipe names in the UI.
- Special installs run `kraken2-build --db <staging> --special <type>` in `kraken2`, then `bracken-build -d <staging> -t <threads> -k 35 -l 150 -x <kraken2-bin> -y kraken2` in `bracken`.
- A successful database requires non-empty `hash.k2d`, `opts.k2d`, `taxo.k2d`, `database150mers.kmer_distrib`, `taxonomy/nodes.dmp`, `taxonomy/names.dmp`, and at least one regular library file. Reject symbolic links and filesystem entries escaping the staging root.
- Successful and attempted scientific work must record workflow/tool versions, exact argv and durable replay argv, explicit/default/resolved options, conda/plugin/runtime identity, paths, checksums, sizes, exit status, wall time, and bounded stderr. Provenance failure blocks publication.
- Do not add `.build-special-rrna/` or any other local build directory to commits.

New focused files:

- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift`: injected transfer/tool/filesystem dependencies, recipe execution, validation, digesting, staging, atomic promotion, rollback, and failure-receipt orchestration.
- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstallProvenance.swift`: immutable attempt/step/snapshot models and canonical success/failure provenance writing.
- `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift`: fake-only transaction, command, validation, cancellation, and rollback tests.
- `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallProvenanceTests.swift`: canonical provenance contract tests.

Dependencies flow in one direction: catalog model → provenance value types → installer → registry → plugin/app/CLI/classifier. Tasks follow that order.

### Task 1: Backward-compatible recipes, catalog identity, and rRNA rows

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsModels.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInfo.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift`
- Test: `Tests/LungfishWorkflowTests/WorkflowRegressionTests.swift`

- [ ] **Step 1: Add failing model, compatibility, and catalog tests**

Add tests that round-trip both recipe cases, decode legacy JSON containing only `downloadURL`, and assert stable identities survive encode/decode:

```swift
XCTAssertEqual(legacy.installationRecipe, .archive(url: try XCTUnwrap(legacy.downloadURL.flatMap(URL.init))))
XCTAssertEqual(silva.installationRecipe, .kraken2Special(type: .silva))
XCTAssertEqual(greengenes.installationRecipe, .kraken2Special(type: .greengenes))
XCTAssertEqual(Set([silva.catalogID, greengenes.catalogID]), ["kraken2-special-silva", "kraken2-special-greengenes"])
XCTAssertFalse(MetagenomicsDatabaseInfo.builtInCatalog.contains { $0.name.localizedCaseInsensitiveContains("rdp") })
```

Update exact `DatabaseCollection.allCases.count` assertions only to remain `9`; SILVA and Greengenes must not enter that enum.

- [ ] **Step 2: Run model tests and verify RED**

Run:

```bash
swift test --filter 'MetagenomicsDatabaseInfoTests|DatabaseCollectionRegressionTests'
```

Expected: compilation failures for the missing recipe/special/catalog identity APIs.

- [ ] **Step 3: Implement the additive model and catalog entries**

Add these public types to `MetagenomicsModels.swift`:

```swift
public enum Kraken2SpecialDatabase: String, Codable, Sendable, CaseIterable {
    case silva
    case greengenes
}

public enum MetagenomicsDatabaseInstallationRecipe: Codable, Sendable, Equatable {
    case archive(url: URL)
    case kraken2Special(type: Kraken2SpecialDatabase)
}
```

Add these stored fields to `MetagenomicsDatabaseInfo`:

```swift
public let catalogID: String?
public let installationRecipe: MetagenomicsDatabaseInstallationRecipe?
public var payloadDigest: String?
```

Extend the initializer with defaulted parameters in that order. Add explicit `CodingKeys`, decoder, and encoder so a missing `installationRecipe` infers `.archive(url:)` from a valid legacy `downloadURL`, and missing `catalogID`/`payloadDigest` remain `nil`. Include all three fields in equality.

Give each existing built-in entry a stable catalog ID (`kraken2-<collection.rawValue>`, `esviritu-viral-v3`, `ncbi-taxonomy`) and its archive recipe. Append SILVA and Greengenes entries with tool `kraken2`, IDs above, recipe version `kraken2-special-v1`, positive conservative display estimates, no `downloadURL`, descriptions naming the upstream rRNA source, and recipes `.kraken2Special(type: ...)`.

Add:

```swift
public static func catalogEntry(catalogID: String) -> MetagenomicsDatabaseInfo? {
    builtInCatalog.first { $0.catalogID == catalogID }
}
```

- [ ] **Step 4: Verify GREEN and commit**

Run:

```bash
swift test --filter 'MetagenomicsDatabaseInfoTests|MetagenomicsDatabaseRegistryTests|DatabaseCollectionRegressionTests'
git diff --check
```

Expected: all selected tests pass and `DatabaseCollection` still has nine cases.

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsModels.swift Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInfo.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift Tests/LungfishWorkflowTests/WorkflowRegressionTests.swift
git commit -m "feat: describe Kraken2 special database recipes"
```

### Task 2: Installation evidence and canonical provenance

**Files:**
- Create: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstallProvenance.swift`
- Create: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallProvenanceTests.swift`

- [ ] **Step 1: Add failing deterministic snapshot tests**

Create fixture files in deliberately unsorted order and assert this API rejects symlinks, excludes `.lungfish-provenance.json` and `.install-*`, returns sorted per-file descriptors, aggregate byte size, and a stable SHA-256 over `relativePath<TAB>sha256<TAB>size` lines:

```swift
public struct MetagenomicsDatabasePayloadSnapshot: Sendable, Equatable {
    public let rootURL: URL
    public let files: [ProvenanceFileDescriptor]
    public let aggregateSHA256: String
    public let totalSizeBytes: UInt64
}

public enum MetagenomicsDatabasePayloadDigester {
    public static func snapshot(at rootURL: URL) throws -> MetagenomicsDatabasePayloadSnapshot
}
```

- [ ] **Step 2: Add failing success/failure envelope tests**

Define fixture evidence with fixed dates and assert `makeSuccessEnvelope` includes final paths only, exact executed and durable argv, all three option maps, runtime identity, checksums/sizes, aggregate digest, statuses/timing/stderr, and tool versions. Assert `makeFailureEnvelope` has equivalent attempted-operation context, nonzero/cancelled status, and no claimed outputs.

Required interfaces:

```swift
public struct MetagenomicsDatabaseInstallStepEvidence: Sendable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let durableReplayArgv: [String]
    public let resolvedOptions: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let inputs: [ProvenanceFileDescriptor]
    public let outputs: [ProvenanceFileDescriptor]
    public let exitStatus: Int32
    public let startedAt: Date
    public let completedAt: Date
    public let stderr: String
}

public struct MetagenomicsDatabaseInstallAttempt: Sendable {
    public let database: MetagenomicsDatabaseInfo
    public let finalURL: URL
    public let recipeSource: String
    public let explicitOptions: [String: ParameterValue]
    public let defaultOptions: [String: ParameterValue]
    public let resolvedOptions: [String: ParameterValue]
    public let steps: [MetagenomicsDatabaseInstallStepEvidence]
    public let startedAt: Date
    public let completedAt: Date
}

public enum MetagenomicsDatabaseInstallFailure: Error, Sendable, Equatable {
    case failed(exitStatus: Int32, message: String, stderr: String)
    case cancelled(message: String, stderr: String)

    public var provenanceExitStatus: Int32 {
        switch self {
        case .failed(let status, _, _): return status == 0 ? 1 : status
        case .cancelled: return 130
        }
    }
}

public protocol MetagenomicsDatabaseInstallProvenanceWriting: Sendable {
    func writeSuccess(_ attempt: MetagenomicsDatabaseInstallAttempt, snapshot: MetagenomicsDatabasePayloadSnapshot) throws
    func writeFailure(_ attempt: MetagenomicsDatabaseInstallAttempt, error: MetagenomicsDatabaseInstallFailure, historyDirectory: URL) throws
}
```

- [ ] **Step 3: Run provenance tests and verify RED**

Run: `swift test --filter MetagenomicsDatabaseInstallProvenanceTests`

Expected: compilation failure because the snapshot/evidence/writer types do not exist.

- [ ] **Step 4: Implement canonical final-path provenance**

Implement `CanonicalMetagenomicsDatabaseInstallProvenanceWriter` with `ProvenanceEnvelope`, `ProvenanceOptions`, `ProvenanceStep`, `ProvenanceRuntimeIdentity`, `ProvenanceWriter`, and `ProvenanceStderr.normalized`. Rehydrate every staging-root argument and descriptor to `finalURL` before constructing success steps. Write success to `<finalURL>/.lungfish-provenance.json`; write failures atomically to `<historyDirectory>/<catalogID-or-slug>/<ISO8601>-<UUID>.lungfish-provenance.json`. A failure envelope has `outputs: []` and records the intended final path only as a resolved option.

Use `CryptoKit.SHA256` for the aggregate digest. Inspect entries without following symlinks and throw `unsafePayload(path:)` for any symbolic link, non-regular file, or standardized path outside the root.

- [ ] **Step 5: Verify GREEN and commit**

Run:

```bash
swift test --filter MetagenomicsDatabaseInstallProvenanceTests
git diff --check
```

Expected: all selected tests pass.

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstallProvenance.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallProvenanceTests.swift
git commit -m "feat: record database installation provenance"
```

### Task 3: Injectable special/archive recipe execution and validation

**Files:**
- Create: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift`
- Create: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift`

- [ ] **Step 1: Add failing recipe-command and generic-progress tests**

Use fake dependencies that create tiny required files and capture calls. Assert SILVA and Greengenes each run exactly one matching special command followed by Bracken:

```swift
XCTAssertEqual(tool.calls[0].name, "kraken2-build")
XCTAssertEqual(tool.calls[0].arguments, ["--db", staging.path, "--special", "silva"])
XCTAssertEqual(tool.calls[0].environment, "kraken2")
XCTAssertEqual(tool.calls[1].name, "bracken-build")
XCTAssertEqual(tool.calls[1].arguments, [
    "-d", staging.path, "-t", "4", "-k", "35", "-l", "150",
    "-x", krakenBin.path, "-y", "kraken2",
])
XCTAssertEqual(tool.calls[1].environment, "bracken")
XCTAssertFalse(messages.contains { $0.localizedCaseInsensitiveContains("build") || $0.contains("kraken2-build") })
```

Assert archive recipes call the injected downloader and extractor, never either build executable, and capture archive SHA-256/size before extraction.

- [ ] **Step 2: Define the injected runner contracts and verify RED**

Run: `swift test --filter MetagenomicsDatabaseInstallerTests`

Expected: compilation failure for these missing interfaces:

```swift
public struct MetagenomicsDatabaseToolResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitStatus: Int32
    public let argv: [String]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let toolVersion: String
    public let startedAt: Date
    public let completedAt: Date
}

public protocol MetagenomicsDatabaseToolRunning: Sendable {
    func run(name: String, arguments: [String], environment: String, workingDirectory: URL, timeout: TimeInterval) async throws -> MetagenomicsDatabaseToolResult
    func executableDirectory(environment: String) async throws -> URL
}

public protocol MetagenomicsDatabaseArchiveTransferring: Sendable {
    func download(from source: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    func extract(archive: URL, destination: URL) async throws -> MetagenomicsDatabaseToolResult
}

public protocol MetagenomicsDatabaseFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItemIfPresent(at url: URL) throws
}

public struct MetagenomicsDatabaseInstallResult: Sendable {
    public let finalURL: URL
    public let version: String
    public let payloadDigest: String
    public let sizeOnDisk: Int64
}

public struct PreparedMetagenomicsDatabaseInstallation: Sendable {
    public let result: MetagenomicsDatabaseInstallResult
    fileprivate let stagingURL: URL
    fileprivate let backupURL: URL?
}
```

- [ ] **Step 3: Implement minimal recipe execution and strict payload validation**

Implement `ManagedMetagenomicsDatabaseToolRunner` over `CondaManager.runTool`, recording the real micromamba argv, environment URL/prefix, and versions. Implement `URLSessionTarDatabaseArchiveTransfer` using the existing cancellation-safe delegate logic and `/usr/bin/tar` without shell interpolation.

Implement:

```swift
public struct MetagenomicsDatabaseInstaller: Sendable {
    public init(
        toolRunner: any MetagenomicsDatabaseToolRunning,
        archiveTransfer: any MetagenomicsDatabaseArchiveTransferring,
        provenanceWriter: any MetagenomicsDatabaseInstallProvenanceWriting,
        fileSystem: any MetagenomicsDatabaseFileSystem = FoundationMetagenomicsDatabaseFileSystem(),
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    )

    public func prepareInstallation(
        database: MetagenomicsDatabaseInfo,
        databasesBaseURL: URL,
        threads: Int,
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> PreparedMetagenomicsDatabaseInstallation

    public func finalize(_ prepared: PreparedMetagenomicsDatabaseInstallation) throws
    public func rollback(_ prepared: PreparedMetagenomicsDatabaseInstallation) throws
}
```

Use phase mappings `Downloading…` (archive transfer or special-source acquisition), `Preparing…` (extract/build/Bracken), and `Verifying…` (validation/digest/provenance). Special validation requires every file listed in the global constraints. Archive Kraken2 validation requires non-empty Kraken2 core files and `database150mers.kmer_distrib`; only the special recipes additionally require retained taxonomy/library evidence. Return a nonzero process as `.toolFailed(tool:exitStatus:stderr:)` after retaining its evidence.

- [ ] **Step 4: Add failing malformed payload, executable, and cancellation tests**

Cover empty/missing required files, absent `kraken2-build`, absent `bracken-build`, missing distribution, absent taxonomy/library evidence, symlinked content, escaping content, command exit 42 with bounded stderr, cancellation before/between commands, and cancellation while the fake runner is suspended. Assert the runner receives cancellation and no `.ready` result is returned.

- [ ] **Step 5: Implement the failure paths and verify GREEN**

Call `Task.checkCancellation()` before and after every phase. Map missing tools to an actionable error naming the Metagenomics pack. Always call `writeFailure` after an attempt has resolved commands/runtime; if failure-receipt writing also fails, preserve the original error and append the receipt error to its diagnostic.

Run:

```bash
swift test --filter MetagenomicsDatabaseInstallerTests
swift test --filter MetagenomicsDatabaseInstallProvenanceTests
```

Expected: all selected tests pass without network access.

- [ ] **Step 6: Commit**

```bash
git diff --check
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift
git commit -m "feat: execute Kraken2 database recipes"
```

### Task 4: Transactional publication, replacement rollback, and registry lifecycle

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift`

- [ ] **Step 1: Add failing transaction boundary tests**

Inject failures after recipe execution, validation, digesting, staging-to-final move, success-provenance writing, registry manifest saving, and backup cleanup. For a pre-existing ready directory, assert every pre-commit failure restores byte-identical old payload/provenance. Assert every retry uses a new sibling `.install-<UUID>` directory and no staging/backup becomes a registry path.

- [ ] **Step 2: Add failing catalog reset and reconciliation tests**

Assert removal/reset finds SILVA and Greengenes by `catalogID`, restores fresh missing catalog rows, and never deletes a similarly named imported custom database. Assert new managed entries with `payloadDigest != nil` become corrupt unless required payload, recomputed digest, and final sidecar all validate. Assert legacy ready entries with `payloadDigest == nil` retain the current three-file compatibility behavior.

- [ ] **Step 3: Run registry/installer tests and verify RED**

Run:

```bash
swift test --filter 'MetagenomicsDatabaseInstallerTests|MetagenomicsDatabaseRegistryTests'
```

Expected: failures because publication is not transactional and the registry still resets only by `DatabaseCollection`.

- [ ] **Step 4: Implement atomic publication and rollback**

Create staging beside the final destination. If replacing, rename final to `.backup-<UUID>`, rename staging to final, write success provenance against final paths, and return `PreparedMetagenomicsDatabaseInstallation` while retaining the backup. `finalize` deletes the backup only after registry persistence; `rollback` removes the candidate final and restores the backup. If backup cleanup fails after a scientifically valid commit, return a cleanup diagnostic without reverting the ready payload; keep the backup path out of the registry.

Have `prepareInstallation` return only after the provenance sidecar can be decoded and its output digest matches the in-memory snapshot. Because Kraken2's special workflow does not expose a stable upstream release in machine-readable output, set the installed version deterministically to `built-<yyyyMMdd>-<first-12-digest-characters>`; retain `kraken2-special-v1` only on the missing catalog row.

- [ ] **Step 5: Route the stable registry API through the installer**

Add an injected installer closure to registry test initializers and a production default backed by `MetagenomicsDatabaseInstaller`. Keep this public signature unchanged:

```swift
public func downloadDatabase(
    name: String,
    progress: @Sendable @escaping (Double, String) -> Void
) async throws -> URL
```

Set `.downloading` before installation for every recipe and pass the fixed resolved build default `threads = 4`. After `prepareInstallation`, set final path, installed version, payload digest, size, dates, and `.ready`, then persist the manifest and call `finalize`. If manifest persistence fails, call `rollback`, restore the prior registry row, and re-save it. Generalize catalog reconciliation/reset to `catalogID`, with the old collection/name fallback only for legacy rows.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
swift test --filter 'MetagenomicsDatabaseInstallerTests|MetagenomicsDatabaseRegistryTests|MetagenomicsDatabaseInfoTests'
git diff --check
```

Expected: all selected tests pass, including cancellation/replacement/provenance failure boundaries.

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift
git commit -m "feat: publish metagenomics databases transactionally"
```

### Task 5: Managed build executables and pack diagnostics

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/EsVirituPipelineTests.swift`
- Test: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`

- [ ] **Step 1: Add failing pack requirement tests**

Assert the pinned Kraken2 requirement declares `kraken2` and `kraken2-build`, the Bracken requirement declares `bracken` and `bracken-build`, both remain in their current separate environments, and pack health is not ready when either build executable is missing.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'MetagenomicsPluginPackTests|PluginPackVisibilityTests'`

Expected: assertions fail because only runtime executables are declared.

- [ ] **Step 3: Extend requirements and verify GREEN**

Change only these arrays:

```swift
executables: ["kraken2", "kraken2-build"]
executables: ["bracken", "bracken-build"]
```

Keep pinned packages, versions, licenses, source URLs, and environment names unchanged.

Run:

```bash
swift test --filter 'MetagenomicsPluginPackTests|PluginPackVisibilityTests'
git diff --check
```

Expected: all selected tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift Tests/LungfishWorkflowTests/Metagenomics/EsVirituPipelineTests.swift Tests/LungfishAppTests/PluginPackVisibilityTests.swift
git commit -m "feat: require Kraken2 database build tools"
```

### Task 6: Invisible Plugin Manager and CLI integration

**Files:**
- Modify: `Sources/LungfishCLI/Commands/DbCommand.swift`
- Test: `Tests/LungfishAppTests/DatabasesTabTests.swift`
- Test: `Tests/LungfishCLITests/DbExtractCommandTests.swift`
- Test: `Tests/LungfishCLITests/CLIRegressionTests.swift`
- Create: `Tests/LungfishCLITests/DbCommandDatabaseRoutingTests.swift`

- [ ] **Step 1: Add failing catalog/UI/CLI behavior tests**

Assert SILVA and Greengenes appear under the existing Kraken2 section, use the same accessibility download/cancel/remove identifiers and `Download` label as archive rows, and carry no recommended badge. Assert progress messages visible through the view model are limited to the three generic phases. Add a source guard rejecting user-visible `kraken2-build`, `bracken-build`, “local build,” or recipe type copy in Plugin Manager files.

Parse `lungfish conda db download SILVA` and assert the argument is preserved exactly. In `DbCommandDatabaseRoutingTests`, read `DbCommand.swift` and assert `DbDownloadSubcommand.run()` contains one call to `registry.downloadDatabase(name: name)` and contains no recipe dispatch, `kraken2-build`, or direct URLSession use; the fake registry tests from Task 4 prove that same method dispatches both SILVA and Viral. Update help/discussion to say databases may be downloaded or prepared from managed upstream sources, without adding a new subcommand or flag.

- [ ] **Step 2: Run app/CLI tests and verify RED**

Run:

```bash
swift test --filter 'DatabasesTabTests|DbCommandParsingTests|DbCommandRegressionTests'
```

Expected: catalog count/copy assertions or injection seam tests fail.

- [ ] **Step 3: Preserve the existing UI path and update CLI copy**

Do not modify `PluginManagerViewModel` or `PluginManagerView`: their existing generic row and `downloadDatabase(name:)` path must render the new catalog rows. Update only `DbCommand` help/discussion. Exclude specialist rRNA rows from `recommendedCollections` by leaving that existing explicit list unchanged.

- [ ] **Step 4: Verify GREEN and commit**

Run:

```bash
swift test --filter 'DatabasesTabTests|DbCommandParsingTests|DbCommandRegressionTests'
git diff --check
```

Expected: all selected tests pass and source guards confirm implementation differences are invisible.

```bash
git add Sources/LungfishCLI/Commands/DbCommand.swift Tests/LungfishAppTests/DatabasesTabTests.swift Tests/LungfishCLITests/DbExtractCommandTests.swift Tests/LungfishCLITests/CLIRegressionTests.swift Tests/LungfishCLITests/DbCommandDatabaseRoutingTests.swift
git commit -m "feat: expose rRNA databases through existing selectors"
```

### Task 7: Classifier selection and digest-backed database identity

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
- Test: `Tests/LungfishAppTests/ClassificationWizardTests.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineProvenanceSourceTests.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift`

- [ ] **Step 1: Add failing ready-selection and identity tests**

Assert ready SILVA and Greengenes rows are selected by the unchanged ready-Kraken2 filter and produce profile configs using their final paths. Add an optional additive `databaseDigest` fixture and assert legacy `ClassificationConfig` JSON without it decodes as `nil`.

Assert classification provenance parameters contain database name, installed version, final database path, and digest, while Kraken2 and Bracken argv remain otherwise unchanged.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter 'ClassificationWizardTests|ClassificationPipelineProvenanceSourceTests|ClassificationPipelineTests'
```

Expected: failures because digest identity is not carried into config/provenance.

- [ ] **Step 3: Carry additive database identity through the existing workflow**

Add to `ClassificationConfig` initializer, `CodingKeys`, decoder, and preset factory:

```swift
public let databaseDigest: String?
```

In `ClassificationWizardSheet`, pass `db.payloadDigest` while retaining `.profile`, database path, thresholds, Bracken defaults, and UI layout. Add these top-level classification provenance parameters:

```swift
"databaseVersion": .string(effectiveConfig.databaseVersion),
"databasePath": .file(effectiveConfig.databasePath.standardizedFileURL),
"databaseDigest": effectiveConfig.databaseDigest.map(ParameterValue.string) ?? .null,
```

Do not read or hash the multi-gigabyte database during classification; installation provenance is the authority for the digest.

- [ ] **Step 4: Verify GREEN and commit**

Run:

```bash
swift test --filter 'ClassificationWizardTests|ClassificationPipelineProvenanceSourceTests|ClassificationPipelineTests'
git diff --check
```

Expected: all selected tests pass, including Kraken2-plus-Bracken profiling for fake special entries.

```bash
git add Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift Tests/LungfishAppTests/ClassificationWizardTests.swift Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineProvenanceSourceTests.swift Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift
git commit -m "feat: retain classifier database build identity"
```

### Task 8: Cross-cutting provenance policy and final verification

**Files:**
- Modify: `Tests/LungfishWorkflowTests/ScientificProvenancePolicyTests.swift`
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallProvenanceTests.swift`
- Modify: `Tests/LungfishAppTests/DatabasesTabTests.swift`
- Modify: `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift`

- [ ] **Step 1: Add final blocking-policy tests**

Add a policy case identifying metagenomics database installation as a scientific output workflow and requiring a concrete writer. Add end-to-end fake installs for archive, SILVA, and Greengenes; load each final `.lungfish-provenance.json` and assert complete checksums/sizes for every retained payload file, aggregate digest equality, exact argv/durable replay, resolved defaults `threads`, `kmerLength = 35`, `readLength = 150`, runtime conda prefixes/environments, success statuses/times/stderr, and no staging paths.

Add failure/cancellation receipt assertions for equivalent attempted context and zero outputs. Add a CLI coverage assertion that the database download command delegates to the provenance-enforcing registry API rather than a second installer.

- [ ] **Step 2: Run policy tests and verify RED, then close only identified gaps**

Run:

```bash
swift test --filter 'ScientificProvenancePolicyTests|MetagenomicsDatabaseInstallProvenanceTests|ScientificCLIProvenanceCoverageTests'
```

Expected: new assertions expose any missing contract fields; update only the provenance/adapter code responsible for each failing field.

- [ ] **Step 3: Run focused feature verification**

Run:

```bash
swift test --filter 'MetagenomicsDatabaseInfoTests|MetagenomicsDatabaseRegistryTests|MetagenomicsDatabaseInstallerTests|MetagenomicsDatabaseInstallProvenanceTests|DatabasesTabTests|ClassificationWizardTests|ClassificationPipelineProvenanceSourceTests|DbCommandParsingTests|DbCommandRegressionTests|PluginPackVisibilityTests|ScientificProvenancePolicyTests'
```

Expected: zero failures and no live network or full Kraken2 build.

- [ ] **Step 4: Run module and repository verification**

Run:

```bash
swift test --filter LungfishWorkflowTests
swift test --filter LungfishAppTests
swift test --filter LungfishCLITests
swift test
git diff --check
git status --short
```

Expected: every command exits 0; status contains only intended source/test changes and never `.build-special-rrna/` in the index.

- [ ] **Step 5: Audit acceptance criteria explicitly**

Run:

```bash
rg -n 'RDP|rdp' Sources/LungfishWorkflow/Metagenomics Sources/LungfishApp/Views/PluginManager Sources/LungfishCLI/Commands/DbCommand.swift
rg -n 'kraken2-build|bracken-build|local build' Sources/LungfishApp/Views/PluginManager
git diff --cached --name-only
```

Expected: the first command finds no catalog/UI addition, the second finds no user-facing implementation copy, and the index contains no generated build directory. Inspect final fixtures to confirm archive and both special recipes use the same registry API, special profiles run Bracken 150, failures publish no ready row, and all successful output directories contain valid final-path provenance.

- [ ] **Step 6: Request two-stage final review and commit**

Request a spec-compliance review against `docs/superpowers/specs/2026-08-12-kraken2-special-rrna-databases-design.md`, then a code-quality/provenance review. Fix every Critical or Important finding, rerun affected focused tests plus `swift test`, and commit:

```bash
git add Sources Tests
git commit -m "test: verify Kraken2 rRNA database installation"
```

Do not merge, push, or remove the worktree until the user chooses the finishing action.
