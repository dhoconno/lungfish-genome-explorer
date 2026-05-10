# Storage Location For Managed Tools And Databases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared managed storage-root system so Lungfish can install third-party tools and databases on a validated alternate location, surface that option on first launch and in preferences, and keep app and CLI path resolution consistent.

**Architecture:** Introduce a shared bootstrap config and storage-root resolver in `LungfishCore`, then route managed tool lookup, database lookup, and migration orchestration through that shared model. Build the feature in layers: core storage model first, runtime refactor second, migration coordinator third, then UI and CLI surfaces on top.

**Tech Stack:** Swift, AppKit, SwiftUI, XCTest, UserDefaults, JSON config files, micromamba-managed environments

---

## File Structure

### New Files

- `Sources/LungfishCore/Storage/ManagedStorageLocation.swift`
  - Canonical storage-root model, derived subpaths, validation helpers, and storage status enums.
- `Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift`
  - Reads/writes the bootstrap config at `~/.config/lungfish/storage-location.json`.
- `Sources/LungfishWorkflow/Storage/ManagedStorageCoordinator.swift`
  - Orchestrates validation, database copy, tool reinstall, verification, root switching, and cleanup.
- `Tests/LungfishCoreTests/ManagedStorageLocationTests.swift`
  - Unit coverage for path derivation and destination validation.
- `Tests/LungfishCoreTests/ManagedStorageConfigStoreTests.swift`
  - Unit coverage for bootstrap config persistence and legacy fallback.
- `Tests/LungfishWorkflowTests/ManagedStorageCoordinatorTests.swift`
  - Migration and cleanup behavior coverage.
- `Tests/LungfishAppTests/StorageSettingsTabTests.swift`
  - Preferences storage UI and validation gating coverage.
- `Tests/LungfishAppTests/WelcomeStorageFlowTests.swift`
  - Welcome-screen alternate storage entry-point coverage.
- `Tests/LungfishCLITests/StorageLocationCommandTests.swift`
  - CLI reporting and storage-unavailable behavior coverage.

### Existing Files To Modify

- `Sources/LungfishCore/Models/AppSettings.swift`
  - Replace database-only storage preference with shared managed storage presentation state.
- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift`
  - Derive database root from shared managed storage instead of `DatabaseStorageLocation`.
- `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift`
  - Resolve managed database installs and checks from shared storage root.
- `Sources/LungfishWorkflow/Conda/CondaManager.swift`
  - Replace hard-coded `~/.lungfish/conda` root with shared storage-root resolution.
- `Sources/LungfishWorkflow/Conda/CoreToolLocator.swift`
  - Resolve env paths from shared storage root.
- `Sources/LungfishWorkflow/ProcessManager.swift`
  - Scan managed envs from the configured root.
- `Sources/LungfishCore/Services/NCBI/SRAService.swift`
  - Resolve `prefetch` and `fasterq-dump` from configured root.
- `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`
  - Add storage-unavailable distinction and route smoke checks through active root.
- `Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift`
  - Replace database-only UI with shared storage management and cleanup actions.
- `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
  - Replace database-only storage footer behavior with shared location display and deep-link/open-settings behavior.
- `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`
  - Adjust the Databases tab footer copy to reflect shared storage.
- `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
  - Add advanced alternate storage action and setup sheet.
- `Sources/LungfishCLI/Commands/CondaCommand.swift`
  - Stop advertising the wrong storage path and report configured location where relevant.
- `Sources/LungfishCLI/Commands/ProvisionToolsCommand.swift`
  - Report the configured bootstrap output directory.
- `Tests/LungfishCoreTests/AppSettingsTests.swift`
  - Update for shared storage settings behavior.
- `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
  - Add configured-root coverage.
- `Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift`
  - Add configured-root coverage.
- `Tests/LungfishWorkflowTests/DatabaseRegistryTests.swift`
  - Add configured database-root coverage.
- `Tests/LungfishCoreTests/SRAServicePathTests.swift`
  - Update SRA toolkit path resolution expectations.
- `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
  - Add storage-unavailable pack-status coverage.
- `Tests/LungfishAppTests/DatabasesTabTests.swift`
  - Update database storage footer behavior to use shared location state.

## Task 1: Build The Shared Storage Model In LungfishCore

**Files:**
- Create: `Sources/LungfishCore/Storage/ManagedStorageLocation.swift`
- Create: `Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift`
- Modify: `Sources/LungfishCore/Models/AppSettings.swift`
- Test: `Tests/LungfishCoreTests/ManagedStorageLocationTests.swift`
- Test: `Tests/LungfishCoreTests/ManagedStorageConfigStoreTests.swift`
- Test: `Tests/LungfishCoreTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing storage-location derivation and validation tests**

```swift
import XCTest
@testable import LungfishCore

final class ManagedStorageLocationTests: XCTestCase {
    func testDefaultLocationUsesDotLungfishRoot() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let location = ManagedStorageLocation.defaultLocation(homeDirectory: home)

        XCTAssertEqual(location.rootURL.path, "/Users/tester/.lungfish")
        XCTAssertEqual(location.condaRootURL.path, "/Users/tester/.lungfish/conda")
        XCTAssertEqual(location.databaseRootURL.path, "/Users/tester/.lungfish/databases")
    }

    func testValidationRejectsResolvedPathsContainingSpaces() throws {
        let base = URL(fileURLWithPath: "/Volumes/My SSD/Lungfish", isDirectory: true)
        let result = ManagedStorageLocation.validateSelection(base)

        XCTAssertEqual(result, .invalid(.containsSpaces))
    }

    func testValidationRejectsProjectNestedPath() throws {
        let base = URL(fileURLWithPath: "/Users/tester/Project.lungfish/Support", isDirectory: true)
        let result = ManagedStorageLocation.validateSelection(base)

        XCTAssertEqual(result, .invalid(.nestedInsideProject))
    }
}
```

- [ ] **Step 2: Run the core storage tests and verify they fail**

Run: `swift test --filter 'ManagedStorageLocationTests|ManagedStorageConfigStoreTests|AppSettingsTests'`

Expected: FAIL with missing `ManagedStorageLocation`, missing `ManagedStorageConfigStore`, and old database-only settings assumptions.

- [ ] **Step 3: Implement the shared storage model and bootstrap config store**

```swift
public struct ManagedStorageLocation: Sendable, Codable, Equatable {
    public enum ValidationError: String, Sendable, Codable, Equatable {
        case containsSpaces
        case notWritable
        case unsupportedFilesystem
        case nestedInsideProject
        case nestedInsideAppBundle
        case unreachable
    }

    public let rootURL: URL

    public var condaRootURL: URL {
        rootURL.appendingPathComponent("conda", isDirectory: true)
    }

    public var databaseRootURL: URL {
        rootURL.appendingPathComponent("databases", isDirectory: true)
    }

    public static func defaultLocation(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ManagedStorageLocation {
        ManagedStorageLocation(rootURL: homeDirectory.appendingPathComponent(".lungfish", isDirectory: true))
    }

    public static func validateSelection(_ url: URL) -> ValidationResult {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path.contains(" ") { return .invalid(.containsSpaces) }
        if resolved.path.contains(".lungfish/") { return .valid }
        if resolved.pathExtension == "lungfish" { return .invalid(.nestedInsideProject) }
        return .valid
    }
}

public struct ManagedStorageBootstrapConfig: Codable, Equatable, Sendable {
    public var activeRootPath: String
    public var previousRootPath: String?
    public var migrationState: MigrationState?
}

public final class ManagedStorageConfigStore: @unchecked Sendable {
    public static let shared = ManagedStorageConfigStore()
    public let configURL: URL

    public init(fileManager: FileManager = .default, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.configURL = homeDirectory
            .appendingPathComponent(".config/lungfish", isDirectory: true)
            .appendingPathComponent("storage-location.json")
    }
}
```

- [ ] **Step 4: Update `AppSettings` to expose shared managed storage display state**

```swift
public static let managedStorageLocationKey = "ManagedStorageLocation"

public var managedStorageRootURL: URL {
    get { ManagedStorageConfigStore.shared.currentLocation().rootURL }
    set { try? ManagedStorageConfigStore.shared.setActiveRoot(newValue) }
}

public var isManagedStorageDefault: Bool {
    managedStorageRootURL.standardizedFileURL == ManagedStorageLocation.defaultLocation().rootURL.standardizedFileURL
}
```

- [ ] **Step 5: Re-run the core storage tests and verify they pass**

Run: `swift test --filter 'ManagedStorageLocationTests|ManagedStorageConfigStoreTests|AppSettingsTests'`

Expected: PASS with new storage model and updated settings expectations.

- [ ] **Step 6: Commit the core storage model**

```bash
git add Sources/LungfishCore/Storage/ManagedStorageLocation.swift \
        Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift \
        Sources/LungfishCore/Models/AppSettings.swift \
        Tests/LungfishCoreTests/ManagedStorageLocationTests.swift \
        Tests/LungfishCoreTests/ManagedStorageConfigStoreTests.swift \
        Tests/LungfishCoreTests/AppSettingsTests.swift
git commit -m "feat: add shared managed storage model"
```

## Task 2: Refactor Managed Tool And Database Resolution To Use The Shared Root

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
- Modify: `Sources/LungfishWorkflow/Conda/CoreToolLocator.swift`
- Modify: `Sources/LungfishWorkflow/ProcessManager.swift`
- Modify: `Sources/LungfishCore/Services/NCBI/SRAService.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift`
- Modify: `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift`
- Test: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- Test: `Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift`
- Test: `Tests/LungfishWorkflowTests/DatabaseRegistryTests.swift`
- Test: `Tests/LungfishCoreTests/SRAServicePathTests.swift`

- [ ] **Step 1: Write failing configured-root tests for the runtime path seam**

```swift
func testEnvironmentURLUsesConfiguredManagedStorageRoot() async throws {
    let root = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
    let manager = CondaManager(
        rootPrefix: root.appendingPathComponent("conda"),
        bundledMicromambaProvider: { nil },
        bundledMicromambaVersionProvider: { nil }
    )

    let envURL = await manager.environmentURL(named: "samtools")
    XCTAssertEqual(envURL.path, "/tmp/custom-lungfish/conda/envs/samtools")
}

func testManagedToolkitExecutableURLUsesConfiguredStorageRoot() {
    let root = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
    let url = SRAService.managedExecutableURL(
        executableName: "prefetch",
        storageRoot: ManagedStorageLocation(rootURL: root)
    )

    XCTAssertEqual(url.path, "/tmp/custom-lungfish/conda/envs/sra-tools/bin/prefetch")
}
```

- [ ] **Step 2: Run the path-resolution tests and verify they fail**

Run: `swift test --filter 'CondaManagerTests|CoreToolLocatorTests|DatabaseRegistryTests|SRAServicePathTests'`

Expected: FAIL because several call sites still assume `~/.lungfish`.

- [ ] **Step 3: Thread the shared storage root into tool and database locators**

```swift
public actor CondaManager {
    public static let shared = CondaManager(storageConfigStore: .shared)

    private let storageConfigStore: ManagedStorageConfigStore

    public var rootPrefix: URL {
        storageConfigStore.currentLocation().condaRootURL
    }

    public init(
        storageConfigStore: ManagedStorageConfigStore,
        bundledMicromambaProvider: @escaping BundledMicromambaProvider = Self.defaultBundledMicromambaURL,
        bundledMicromambaVersionProvider: @escaping BundledMicromambaVersionProvider = Self.defaultBundledMicromambaVersion
    ) {
        self.storageConfigStore = storageConfigStore
        self.bundledMicromambaProvider = bundledMicromambaProvider
        self.bundledMicromambaVersionProvider = bundledMicromambaVersionProvider
    }
}

public enum CoreToolLocator {
    public static func environmentRoot(storage: ManagedStorageLocation = ManagedStorageConfigStore.shared.currentLocation()) -> URL {
        storage.condaRootURL.appendingPathComponent("envs", isDirectory: true)
    }
}
```

- [ ] **Step 4: Update registries and services to use the shared storage model**

```swift
public init(storageConfigStore: ManagedStorageConfigStore = .shared) {
    let base = storageConfigStore.currentLocation().databaseRootURL
    self.databasesBaseURL = base
    self.manifestURL = base.appendingPathComponent("metagenomics-db-registry.json")
}

public static func managedExecutableURL(
    executableName: String,
    storageRoot: ManagedStorageLocation = ManagedStorageConfigStore.shared.currentLocation()
) -> URL {
    storageRoot.condaRootURL
        .appendingPathComponent("envs/sra-tools/bin/\(executableName)")
}
```

- [ ] **Step 5: Re-run the path-resolution test set and verify it passes**

Run: `swift test --filter 'CondaManagerTests|CoreToolLocatorTests|DatabaseRegistryTests|SRAServicePathTests'`

Expected: PASS with all managed paths resolving from the configured storage root.

- [ ] **Step 6: Commit the runtime refactor**

```bash
git add Sources/LungfishWorkflow/Conda/CondaManager.swift \
        Sources/LungfishWorkflow/Conda/CoreToolLocator.swift \
        Sources/LungfishWorkflow/ProcessManager.swift \
        Sources/LungfishCore/Services/NCBI/SRAService.swift \
        Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift \
        Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift \
        Tests/LungfishWorkflowTests/CondaManagerTests.swift \
        Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift \
        Tests/LungfishWorkflowTests/DatabaseRegistryTests.swift \
        Tests/LungfishCoreTests/SRAServicePathTests.swift
git commit -m "refactor: route managed paths through shared storage root"
```

## Task 3: Add Migration, Verification, And Cleanup Orchestration

**Files:**
- Create: `Sources/LungfishWorkflow/Storage/ManagedStorageCoordinator.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`
- Modify: `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift`
- Test: `Tests/LungfishWorkflowTests/ManagedStorageCoordinatorTests.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`

- [ ] **Step 1: Write failing migration and storage-unavailable tests**

```swift
func testMigrationCopiesDatabasesReinstallsToolsAndSwitchesRootAfterVerification() async throws {
    let oldRoot = URL(fileURLWithPath: "/tmp/lungfish-old", isDirectory: true)
    let newRoot = URL(fileURLWithPath: "/tmp/lungfish-new", isDirectory: true)
    let coordinator = ManagedStorageCoordinator(
        configStore: configStore,
        validator: validator,
        databaseMigrator: databaseMigrator,
        toolInstaller: toolInstaller,
        verifier: verifier
    )

    try await coordinator.changeLocation(to: newRoot)

    XCTAssertEqual(configStore.currentLocation().rootURL, newRoot)
    XCTAssertEqual(databaseMigrator.copiedFromTo, [(oldRoot, newRoot)])
    XCTAssertEqual(toolInstaller.installedRoot, newRoot)
}

func testVisibleStatusesReturnStorageUnavailableWhenConfiguredRootIsMissing() async {
    let service = PluginPackStatusService(
        condaManager: manager,
        storageAvailability: { .unavailable("/Volumes/LungfishSSD") }
    )

    let statuses = await service.visibleStatuses()
    XCTAssertEqual(statuses.first?.state, .failed)
    XCTAssertEqual(statuses.first?.failureMessage, "Storage location unavailable")
}
```

- [ ] **Step 2: Run the migration/status tests and verify they fail**

Run: `swift test --filter 'ManagedStorageCoordinatorTests|PluginPackStatusServiceTests'`

Expected: FAIL with missing coordinator and no storage-unavailable distinction.

- [ ] **Step 3: Implement a coordinator that validates, migrates, verifies, then switches**

```swift
public actor ManagedStorageCoordinator {
    public func changeLocation(to newRoot: URL) async throws {
        let validated = try validator.validate(newRoot)
        let current = configStore.currentLocation()

        try await configStore.markMigrationPending(from: current.rootURL, to: validated.rootURL)
        try await databaseMigrator.copyDatabases(from: current.databaseRootURL, to: validated.databaseRootURL)
        try await toolInstaller.reinstallPinnedTools(at: validated.condaRootURL)
        try await verifier.verifyRequiredToolsAndData(at: validated)
        try await configStore.activate(validated, previousRoot: current.rootURL)
    }

    public func removeOldLocalCopies() async throws {
        guard let previousRoot = configStore.previousRootURL else { return }
        try fileManager.removeItem(at: previousRoot)
        try await configStore.clearPreviousRoot()
    }
}
```

- [ ] **Step 4: Extend pack status evaluation to distinguish storage-unavailable from missing installs**

```swift
public enum ManagedStorageAvailability: Sendable, Equatable {
    case available(ManagedStorageLocation)
    case unavailable(URL)
}

private func makePackStatus(
    pack: PluginPack,
    toolStatuses: [PackToolStatus],
    bootstrapReady: Bool,
    storageAvailability: ManagedStorageAvailability
) -> PluginPackStatus {
    if case .unavailable = storageAvailability {
        return PluginPackStatus(
            pack: pack,
            state: .failed,
            toolStatuses: toolStatuses,
            failureMessage: "Storage location unavailable"
        )
    }

    let state: PluginPackState = toolStatuses.allSatisfy(\.isReady) && bootstrapReady ? .ready : .needsInstall
    return PluginPackStatus(pack: pack, state: state, toolStatuses: toolStatuses, failureMessage: nil)
}
```

- [ ] **Step 5: Re-run the migration/status tests and verify they pass**

Run: `swift test --filter 'ManagedStorageCoordinatorTests|PluginPackStatusServiceTests'`

Expected: PASS with copy-plus-reinstall behavior and storage-unavailable pack status.

- [ ] **Step 6: Commit the migration layer**

```bash
git add Sources/LungfishWorkflow/Storage/ManagedStorageCoordinator.swift \
        Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift \
        Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift \
        Tests/LungfishWorkflowTests/ManagedStorageCoordinatorTests.swift \
        Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift
git commit -m "feat: add managed storage migration coordinator"
```

## Task 4: Update CLI Reporting And Error Surfaces

**Files:**
- Modify: `Sources/LungfishCLI/Commands/CondaCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/ProvisionToolsCommand.swift`
- Test: `Tests/LungfishCLITests/StorageLocationCommandTests.swift`
- Test: `Tests/LungfishCLITests/CLIRegressionTests.swift`

- [ ] **Step 1: Write failing CLI tests for configured storage reporting**

```swift
func testProvisionToolsStatusReportsConfiguredStorageRoot() async throws {
    let output = try await runCLI(
        "provision-tools",
        "--status",
        storageRoot: "/Volumes/LungfishSSD/lungfish-home"
    )

    XCTAssertTrue(output.contains("/Volumes/LungfishSSD/lungfish-home"))
}

func testCondaHelpDoesNotMentionApplicationSupportCondaPath() async throws {
    let output = try await runCLI("conda", "--help")
    XCTAssertFalse(output.contains("Application Support/Lungfish/conda"))
}
```

- [ ] **Step 2: Run the CLI storage tests and verify they fail**

Run: `swift test --filter 'StorageLocationCommandTests|CLITopLevelRegressionTests|ProvisionToolsCommandRegressionTests'`

Expected: FAIL because CLI copy and status still assume the wrong path.

- [ ] **Step 3: Route CLI output and help text through the shared storage root**

```swift
let storage = ManagedStorageConfigStore.shared.currentLocation()
print("Output directory: \(storage.condaRootURL.path)")

static let configuration = CommandConfiguration(
    commandName: "conda",
    abstract: "Manage bioconda tool plugins via micromamba",
    discussion: """
    Install bioinformatics tools from bioconda and conda-forge using micromamba.
    Managed tools are stored under the configured Lungfish storage root.
    """
)
```

- [ ] **Step 4: Make storage-unavailable errors explicit in CLI commands**

```swift
guard ManagedStorageConfigStore.shared.isActiveLocationReachable() else {
    throw ValidationError("Storage location unavailable: \(ManagedStorageConfigStore.shared.currentLocation().rootURL.path)")
}
```

- [ ] **Step 5: Re-run the CLI storage tests and verify they pass**

Run: `swift test --filter 'StorageLocationCommandTests|CLITopLevelRegressionTests|ProvisionToolsCommandRegressionTests'`

Expected: PASS with configured-root reporting and correct error language.

- [ ] **Step 6: Commit the CLI updates**

```bash
git add Sources/LungfishCLI/Commands/CondaCommand.swift \
        Sources/LungfishCLI/Commands/ProvisionToolsCommand.swift \
        Tests/LungfishCLITests/StorageLocationCommandTests.swift \
        Tests/LungfishCLITests/CLIRegressionTests.swift
git commit -m "feat: report shared storage root in CLI"
```

## Task 5: Replace The Database-Only Preferences And Plugin Manager Storage UI

**Files:**
- Modify: `Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`
- Test: `Tests/LungfishAppTests/StorageSettingsTabTests.swift`
- Test: `Tests/LungfishAppTests/DatabasesTabTests.swift`

- [ ] **Step 1: Write failing app-side storage UI tests**

```swift
func testStorageSettingsTabShowsSharedStorageLocationNotDatabaseOnlyCopy() {
    let view = StorageSettingsTab()
    let text = renderText(from: view)

    XCTAssertTrue(text.contains("Third-Party Tools and Databases"))
    XCTAssertFalse(text.contains("Database Storage"))
}

func testDatabasesFooterUsesSharedStorageLocation() {
    let viewModel = PluginManagerViewModel()
    XCTAssertTrue(viewModel.databaseStoragePath.contains(".lungfish") || viewModel.databaseStoragePath.contains("/Volumes/"))
}
```

- [ ] **Step 2: Run the app storage UI tests and verify they fail**

Run: `swift test --filter 'StorageSettingsTabTests|DatabasesTabTests'`

Expected: FAIL because the UI is still database-only.

- [ ] **Step 3: Replace the storage tab with shared managed-storage controls**

```swift
Section("Storage Location") {
    Text("Third-Party Tools and Databases are stored at this location.")

    HStack {
        Text(displayPath)
            .font(.system(.body, design: .monospaced))
        Spacer()
        if isDefault {
            Text("Recommended")
                .foregroundStyle(.secondary)
        }
    }

    HStack {
        Button("Change Location…") { chooseDirectory() }
        Button("Reveal in Finder") { revealCurrentLocation() }
        Spacer()
        if canRemoveOldCopies {
            Button("Remove old local copies…", role: .destructive) { removeOldCopies() }
        }
    }
}
```

- [ ] **Step 4: Make the Plugin Manager footer reflect shared location state**

```swift
var storageLocationPath: String {
    AppSettings.shared.managedStorageRootURL.path
}

Button("Storage Settings…") {
    SettingsWindowController.shared.showTab(.storage)
}
```

- [ ] **Step 5: Re-run the app storage UI tests and verify they pass**

Run: `swift test --filter 'StorageSettingsTabTests|DatabasesTabTests'`

Expected: PASS with shared-storage copy and actions.

- [ ] **Step 6: Commit the preferences and plugin-manager UI changes**

```bash
git add Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift \
        Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift \
        Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift \
        Tests/LungfishAppTests/StorageSettingsTabTests.swift \
        Tests/LungfishAppTests/DatabasesTabTests.swift
git commit -m "feat: add shared storage settings UI"
```

## Task 6: Add The Welcome-Screen Alternate Storage Flow

**Files:**
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/WelcomeStorageFlowTests.swift`
- Test: `Tests/LungfishAppTests/WelcomeSetupTests.swift`

- [ ] **Step 1: Write failing welcome-flow tests**

```swift
func testRequiredSetupCardShowsAlternateStorageAction() {
    let view = WelcomeView(viewModel: WelcomeViewModel())
    let text = renderText(from: view)

    XCTAssertTrue(text.contains("Need more space? Choose another storage location…"))
}

func testCannotConfirmSelectionWhenResolvedPathContainsSpaces() {
    let viewModel = WelcomeViewModel(statusProvider: fakeStatusProvider)
    let result = viewModel.validateStorageSelection(URL(fileURLWithPath: "/Volumes/My SSD/Lungfish"))

    XCTAssertEqual(result, .invalid(.containsSpaces))
}
```

- [ ] **Step 2: Run the welcome tests and verify they fail**

Run: `swift test --filter 'WelcomeStorageFlowTests|WelcomeSetupTests'`

Expected: FAIL because the alternate storage action and picker validation do not exist yet.

- [ ] **Step 3: Add a storage sheet and secondary action to the required-setup card**

```swift
@Published var showingStorageChooser = false
@Published var pendingStorageSelection: URL?
@Published var storageValidationResult: ManagedStorageLocation.ValidationResult = .valid

func chooseAlternateStorageLocation() {
    showingStorageChooser = true
}

func confirmAlternateStorageLocation() async throws {
    guard case .valid = storageValidationResult, let selection = pendingStorageSelection else { return }
    try await storageCoordinator.changeLocation(to: selection)
    await refreshSetup()
}
```

- [ ] **Step 4: Keep the default install path primary and gate invalid selections**

```swift
Button("Need more space? Choose another storage location…") {
    viewModel.chooseAlternateStorageLocation()
}
.buttonStyle(.link)

Button("Use This Location") {
    Task { try? await viewModel.confirmAlternateStorageLocation() }
}
.disabled(!viewModel.canConfirmStorageSelection)
```

- [ ] **Step 5: Re-run the welcome-flow tests and verify they pass**

Run: `swift test --filter 'WelcomeStorageFlowTests|WelcomeSetupTests'`

Expected: PASS with the advanced entry point, disabled invalid confirmation, and shared storage migration path.

- [ ] **Step 6: Commit the welcome-screen storage flow**

```bash
git add Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift \
        Sources/LungfishApp/App/AppDelegate.swift \
        Tests/LungfishAppTests/WelcomeStorageFlowTests.swift \
        Tests/LungfishAppTests/WelcomeSetupTests.swift
git commit -m "feat: add alternate storage flow to setup"
```

## Task 7: Run The Full Focused Verification Sweep

**Files:**
- Modify if needed: any files touched by fixes discovered during verification
- Test: `Tests/LungfishCoreTests/ManagedStorageLocationTests.swift`
- Test: `Tests/LungfishCoreTests/ManagedStorageConfigStoreTests.swift`
- Test: `Tests/LungfishWorkflowTests/ManagedStorageCoordinatorTests.swift`
- Test: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- Test: `Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift`
- Test: `Tests/LungfishWorkflowTests/DatabaseRegistryTests.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
- Test: `Tests/LungfishCoreTests/SRAServicePathTests.swift`
- Test: `Tests/LungfishAppTests/StorageSettingsTabTests.swift`
- Test: `Tests/LungfishAppTests/WelcomeStorageFlowTests.swift`
- Test: `Tests/LungfishAppTests/WelcomeSetupTests.swift`
- Test: `Tests/LungfishAppTests/DatabasesTabTests.swift`
- Test: `Tests/LungfishCLITests/StorageLocationCommandTests.swift`

- [ ] **Step 1: Run the focused verification suite**

Run:

```bash
swift test --filter 'ManagedStorageLocationTests|ManagedStorageConfigStoreTests|AppSettingsTests|ManagedStorageCoordinatorTests|CondaManagerTests|CoreToolLocatorTests|DatabaseRegistryTests|PluginPackStatusServiceTests|SRAServicePathTests|StorageSettingsTabTests|WelcomeStorageFlowTests|WelcomeSetupTests|DatabasesTabTests|StorageLocationCommandTests'
```

Expected: PASS with the new shared storage model, migration coordinator, UI entry points, and CLI reporting.

- [ ] **Step 2: Build a Debug app to sanity-check the welcome and preferences flows**

Run:

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/debug-derived-data build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Smoke-check the two user-facing entry points manually**

Run:

```bash
open .build/debug-derived-data/Build/Products/Debug/Lungfish.app
```

Expected:

- Welcome screen shows the advanced storage action in the required-setup card
- Invalid path selections cannot be confirmed
- Settings → Storage shows shared storage location and cleanup controls

- [ ] **Step 4: Commit any final verification-driven fixes**

```bash
git add Sources Tests
git commit -m "test: verify managed storage relocation flow"
```

## Spec Coverage Check

- Shared storage-root abstraction: covered by Task 1.
- Bootstrap config readable by app and CLI: covered by Task 1.
- Runtime refactor away from hard-coded `~/.lungfish`: covered by Task 2.
- Tool reinstall plus database copy behavior: covered by Task 3.
- Storage-unavailable status instead of missing-tool status: covered by Task 3 and Task 4.
- CLI parity with app-managed storage root: covered by Task 4.
- Preferences storage management UI: covered by Task 5.
- Welcome-screen advanced alternate-location entry point: covered by Task 6.
- Destination picker blocking invalid space-containing paths: covered by Task 1 validation rules and Task 6 UI gating.
- Cleanup of old local copies after successful cutover: covered by Task 3 and Task 5.

## Placeholder Scan

The plan intentionally names concrete files, concrete test targets, concrete commands, and concrete type names. There are no `TODO`, `TBD`, or “handle later” placeholders.

## Type Consistency Check

This plan uses the same names throughout:

- `ManagedStorageLocation`
- `ManagedStorageConfigStore`
- `ManagedStorageCoordinator`
- `managedStorageRootURL`
- `storage location unavailable`

Do not rename these midway through implementation without updating all later tasks and tests together.
