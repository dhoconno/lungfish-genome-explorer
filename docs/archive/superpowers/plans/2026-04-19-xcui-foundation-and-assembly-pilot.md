# XCUI Foundation And Assembly Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first executable slice of the exhaustive XCUI program: shared UI-test runtime and fixtures, welcome/project lifecycle coverage, app-shell smoke coverage, and the assembly batch pilot.

**Architecture:** Extend the existing app-wide UI-test configuration into a reusable runtime contract, keep real open/save panel coverage in dedicated XCUI tests, and add stable accessibility identifiers to the first major surfaces. Use deterministic external-boundary adapters only where the real assembly tool path is too slow or unavailable, while preserving the actual Lungfish dialog, operation, sidebar, and viewer flow.

**Tech Stack:** AppKit, SwiftUI, XCTest/XCUI, xcodebuild, Lungfish workflow and FASTQ execution services, fixture-backed file I/O under `Tests/Fixtures`

---

**Scope note:** The approved design spec covers multiple independent subsystems. This first plan intentionally covers only phases 1-4 of that design:

- shared XCUI runtime and fixture catalog
- welcome/project lifecycle coverage
- main-window shell smoke coverage
- assembly tool batch pilot

Database search already has its own XCUI foothold. Import center, viewer deep coverage, metagenomics, workflow builder, and settings/help/about should get separate follow-on plans after this tranche is stable.

### Task 1: Expand The Shared UI-Test Runtime And Fixture Catalog

**Files:**
- Modify: `Sources/LungfishApp/App/AppUITestConfiguration.swift`
- Modify: `Tests/LungfishAppTests/AppUITestConfigurationTests.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/LungfishUITestLaunchOptions.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/LungfishFixtureCatalog.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift`
- Modify: `Tests/Fixtures/README.md`

- [ ] **Step 1: Write the failing unit tests for the expanded runtime contract**

```swift
func testLaunchEnvironmentParsesProjectPathFixtureRootAndBackendMode() {
    let config = AppUITestConfiguration(
        arguments: ["Lungfish", "--ui-test-mode"],
        environment: [
            "LUNGFISH_UI_TEST_SCENARIO": "welcome-project-open",
            "LUNGFISH_UI_TEST_PROJECT_PATH": "/tmp/Fixture.lungfish",
            "LUNGFISH_UI_TEST_FIXTURE_ROOT": "/tmp/Fixtures",
            "LUNGFISH_UI_TEST_BACKEND_MODE": "deterministic"
        ]
    )

    XCTAssertTrue(config.isEnabled)
    XCTAssertEqual(config.scenarioName, "welcome-project-open")
    XCTAssertEqual(config.projectPath, URL(fileURLWithPath: "/tmp/Fixture.lungfish"))
    XCTAssertEqual(config.fixtureRootPath, URL(fileURLWithPath: "/tmp/Fixtures"))
    XCTAssertEqual(config.backendMode, .deterministic)
}

func testUnknownBackendModeFallsBackToDeterministic() {
    let config = AppUITestConfiguration(
        arguments: ["Lungfish", "--ui-test-mode"],
        environment: ["LUNGFISH_UI_TEST_BACKEND_MODE": "mystery-mode"]
    )

    XCTAssertEqual(config.backendMode, .deterministic)
}
```

- [ ] **Step 2: Run the unit tests to verify the new contract is missing**

Run:

```bash
xcodebuild test -project Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishAppTests/AppUITestConfigurationTests
```

Expected: FAIL with compile errors because `projectPath`, `fixtureRootPath`, and `backendMode` do not exist yet.

- [ ] **Step 3: Implement the runtime fields in `AppUITestConfiguration`**

```swift
enum AppUITestBackendMode: String, Equatable, Sendable {
    case deterministic
    case liveSmoke = "live-smoke"
}

struct AppUITestConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let scenarioName: String?
    let projectPath: URL?
    let fixtureRootPath: URL?
    let backendMode: AppUITestBackendMode

    init(arguments: [String], environment: [String: String]) {
        let explicitFlag = arguments.contains("--ui-test-mode")
        let environmentFlag = environment["LUNGFISH_UI_TEST_MODE"] == "1"

        isEnabled = explicitFlag || environmentFlag
        scenarioName = environment["LUNGFISH_UI_TEST_SCENARIO"]
        projectPath = environment["LUNGFISH_UI_TEST_PROJECT_PATH"].map(URL.init(fileURLWithPath:))
        fixtureRootPath = environment["LUNGFISH_UI_TEST_FIXTURE_ROOT"].map(URL.init(fileURLWithPath:))
        backendMode = AppUITestBackendMode(
            rawValue: environment["LUNGFISH_UI_TEST_BACKEND_MODE"] ?? ""
        ) ?? .deterministic
    }
}
```

- [ ] **Step 4: Add test-side launch and fixture helpers**

```swift
struct LungfishUITestLaunchOptions {
    var scenario: String?
    var projectPath: URL?
    var fixtureRootPath: URL?
    var backendMode: String = "deterministic"
    var skipWelcome = false

    func apply(to app: XCUIApplication) {
        app.launchArguments = ["--ui-test-mode"] + (skipWelcome ? ["--skip-welcome"] : [])
        if let scenario { app.launchEnvironment["LUNGFISH_UI_TEST_SCENARIO"] = scenario }
        if let projectPath { app.launchEnvironment["LUNGFISH_UI_TEST_PROJECT_PATH"] = projectPath.path }
        if let fixtureRootPath { app.launchEnvironment["LUNGFISH_UI_TEST_FIXTURE_ROOT"] = fixtureRootPath.path }
        app.launchEnvironment["LUNGFISH_UI_TEST_BACKEND_MODE"] = backendMode
    }
}
```

```swift
enum LungfishFixtureCatalog {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fixturesRoot = repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    static let sarscov2 = fixturesRoot.appendingPathComponent("sarscov2", isDirectory: true)
    static let analyses = fixturesRoot.appendingPathComponent("analyses", isDirectory: true)
    static let assemblyUI = fixturesRoot.appendingPathComponent("assembly-ui", isDirectory: true)
}
```

```swift
enum LungfishProjectFixtureBuilder {
    static func makeAnalysesProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-xcui-project-\(UUID().uuidString)", isDirectory: true)
        let analysesDir = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analysesDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: LungfishFixtureCatalog.analyses.appendingPathComponent("spades-2026-01-15T13-00-00", isDirectory: true),
            to: analysesDir.appendingPathComponent("spades-2026-01-15T13-00-00", isDirectory: true)
        )
        return root
    }
}
```

- [ ] **Step 5: Re-run the runtime tests**

Run:

```bash
xcodebuild test -project Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishAppTests/AppUITestConfigurationTests
```

Expected: PASS with `AppUITestConfigurationTests` green.

- [ ] **Step 6: Commit the runtime tranche**

```bash
git add Sources/LungfishApp/App/AppUITestConfiguration.swift Tests/LungfishAppTests/AppUITestConfigurationTests.swift Tests/LungfishXCUITests/TestSupport/LungfishUITestLaunchOptions.swift Tests/LungfishXCUITests/TestSupport/LungfishFixtureCatalog.swift Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift Tests/Fixtures/README.md
git commit -m "test: expand ui test runtime and fixture catalog"
```

### Task 2: Add Welcome And Project Lifecycle XCUI Coverage With Real Panels

**Files:**
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/SystemPanelRobot.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/ProjectLifecycleRobot.swift`
- Create: `Tests/LungfishXCUITests/ProjectLifecycleXCUITests.swift`

- [ ] **Step 1: Write the failing XCUI tests for welcome create/open and deterministic startup**

```swift
@MainActor
final class ProjectLifecycleXCUITests: XCTestCase {
    func testWelcomeOpenProjectUsesRealOpenPanel() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeAnalysesProject()
        let robot = ProjectLifecycleRobot()

        robot.launchToWelcome()
        robot.openProjectThroughPanel(projectURL)

        XCTAssertTrue(robot.mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.sidebarGroup("Analyses").waitForExistence(timeout: 5))
    }

    func testWelcomeCreateProjectUsesRealSavePanel() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreatedFromXCUI-\(UUID().uuidString).lungfish", isDirectory: true)
        let robot = ProjectLifecycleRobot()

        robot.launchToWelcome()
        robot.createProjectThroughPanel(projectURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertTrue(robot.mainWindow.waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 2: Run the XCUI tests to capture the missing accessibility surface**

Run:

```bash
scripts/testing/run-macos-xcui.sh \
  LungfishXCUITests/ProjectLifecycleXCUITests/testWelcomeOpenProjectUsesRealOpenPanel \
  LungfishXCUITests/ProjectLifecycleXCUITests/testWelcomeCreateProjectUsesRealSavePanel
```

Expected: FAIL because welcome actions and real panel flow do not yet have stable XCUI hooks.

- [ ] **Step 3: Add stable identifiers to the welcome surface and deterministic startup project support**

```swift
PrimaryWelcomeActionCard(
    title: "Create Project",
    ...
)
.accessibilityIdentifier("welcome-create-project")

PrimaryWelcomeActionCard(
    title: "Open Project",
    ...
)
.accessibilityIdentifier("welcome-open-project")
```

```swift
public func applicationDidFinishLaunching(_ notification: Notification) {
    ...
    let uiTestConfig = AppUITestConfiguration.current
    if uiTestConfig.isEnabled, let projectPath = uiTestConfig.projectPath {
        showMainWindowWithProject(projectPath)
        return
    }
    ...
}
```

- [ ] **Step 4: Add a reusable system-panel robot**

```swift
struct SystemPanelRobot {
    let app: XCUIApplication

    func chooseFile(_ url: URL) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let pathField = sheet.textFields["Filename:"]
        if pathField.waitForExistence(timeout: 2) {
            pathField.click()
            pathField.typeText(url.path)
        } else {
            app.typeText("g")
            app.typeKey("G", modifierFlags: [.command, .shift])
            let goToFolderSheet = app.sheets.firstMatch
            let input = goToFolderSheet.textFields.firstMatch
            input.click()
            input.typeText(url.path)
            goToFolderSheet.buttons["Go"].click()
        }
        sheet.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Choose", "Create"])).firstMatch.click()
    }
}
```

- [ ] **Step 5: Re-run the project lifecycle XCUI tests**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/ProjectLifecycleXCUITests
```

Expected: PASS with both real-panel project lifecycle tests green.

- [ ] **Step 6: Commit the project lifecycle tranche**

```bash
git add Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishXCUITests/TestSupport/SystemPanelRobot.swift Tests/LungfishXCUITests/TestSupport/ProjectLifecycleRobot.swift Tests/LungfishXCUITests/ProjectLifecycleXCUITests.swift
git commit -m "test: add welcome project lifecycle xcui coverage"
```

### Task 3: Add Main Window Shell Smoke Coverage And Accessibility IDs

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/MainWindowRobot.swift`
- Create: `Tests/LungfishXCUITests/MainWindowNavigationXCUITests.swift`

- [ ] **Step 1: Write the failing shell smoke test**

```swift
@MainActor
final class MainWindowNavigationXCUITests: XCTestCase {
    func testToolbarAndAnalysesGroupAreReachableByPointerAndKeyboard() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeAnalysesProject()
        let robot = MainWindowRobot()

        robot.launch(opening: projectURL)
        XCTAssertTrue(robot.toolbarButton("main-window-toggle-sidebar").waitForExistence(timeout: 5))
        XCTAssertTrue(robot.toolbarButton("main-window-toggle-inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(robot.sidebarGroup("sidebar-group-analyses").waitForExistence(timeout: 5))

        robot.focusSidebar()
        robot.moveSelectionDown()
        XCTAssertTrue(robot.selectedSidebarRow.exists)
    }
}
```

- [ ] **Step 2: Run the shell smoke test to verify the identifiers are missing**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/MainWindowNavigationXCUITests/testToolbarAndAnalysesGroupAreReachableByPointerAndKeyboard
```

Expected: FAIL because the toolbar items and sidebar groups do not yet expose stable identifiers.

- [ ] **Step 3: Add main-window and sidebar identifiers**

```swift
private func makeToolbarButton(symbolName: String, fallbacks: [String], accessibilityLabel: String, identifier: String) -> NSButton {
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 24))
    ...
    button.setAccessibilityIdentifier(identifier)
    return button
}
```

```swift
let analysesItem = SidebarItem(
    title: "Analyses",
    type: .group,
    icon: "folder",
    children: analysesChildren,
    url: projectURL.appendingPathComponent(AnalysesFolder.directoryName)
)
analysesItem.userInfo["accessibilityIdentifier"] = "sidebar-group-analyses"
```

- [ ] **Step 4: Re-run the shell smoke test**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/MainWindowNavigationXCUITests
```

Expected: PASS with toolbar and sidebar smoke coverage green.

- [ ] **Step 5: Commit the shell smoke tranche**

```bash
git add Sources/LungfishApp/Views/MainWindow/MainWindowController.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Tests/LungfishXCUITests/TestSupport/MainWindowRobot.swift Tests/LungfishXCUITests/MainWindowNavigationXCUITests.swift
git commit -m "test: add main window shell xcui smoke coverage"
```

### Task 4: Add A Deterministic Assembly Pilot Execution Boundary

**Files:**
- Create: `Sources/LungfishApp/App/AppUITestAssemblyBackend.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`
- Create: `Tests/LungfishAppTests/AppUITestAssemblyBackendTests.swift`
- Create: `Tests/Fixtures/assembly-ui/illumina`
- Create: `Tests/Fixtures/assembly-ui/ont`
- Create: `Tests/Fixtures/assembly-ui/pacbio-hifi`
- Modify: `Tests/Fixtures/README.md`

- [ ] **Step 1: Write the failing deterministic assembly backend tests**

```swift
func testBackendSynthesizesMegahitAnalysisArtifacts() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("assembly-ui-backend-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = AssemblyRunRequest(
        tool: .megahit,
        readType: .illuminaShortReads,
        inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq.gz"), URL(fileURLWithPath: "/tmp/R2.fastq.gz")],
        projectName: "demo",
        outputDirectory: tempDir,
        pairedEnd: true,
        threads: 8
    )

    try AppUITestAssemblyBackend.writeResult(for: request)

    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("assembly-result.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("contigs.fasta").path))
    XCTAssertEqual(try AssemblyResult.load(from: tempDir).tool, .megahit)
}
```

- [ ] **Step 2: Run the new backend tests**

Run:

```bash
xcodebuild test -project Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishAppTests/AppUITestAssemblyBackendTests
```

Expected: FAIL because `AppUITestAssemblyBackend` does not exist yet.

- [ ] **Step 3: Implement the deterministic assembly result writer**

```swift
enum AppUITestAssemblyBackend {
    static func writeResult(for request: AssemblyRunRequest) throws {
        let contigsURL = request.outputDirectory.appendingPathComponent("contigs.fasta")
        try """
        >\(request.tool.rawValue)_contig_1
        ACGTACGTACGTACGT
        >\(request.tool.rawValue)_contig_2
        TTTTCCCCAAAAGGGG
        """.write(to: contigsURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: request.tool,
            readType: request.readType,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "ui-test",
            commandLine: "ui-test \(request.tool.rawValue)",
            outputDirectory: request.outputDirectory,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 0.5
        )
        try result.save(to: request.outputDirectory)
    }
}
```

- [ ] **Step 4: Route FASTQ assembly requests through the deterministic backend only in UI-test mode**

```swift
if AppUITestConfiguration.current.isEnabled,
   AppUITestConfiguration.current.backendMode == .deterministic,
   case .assemble(let request, _) = request {
    try AppUITestAssemblyBackend.writeResult(for: request)
    self.refreshSidebarAndSelectDerivedURL(workingDirectory)
    return
}
```

Use the real `FASTQOperationDialog`, `FASTQOperationDialogState`, `FASTQOperationExecutionService`, sidebar reload, and viewer routing. Only replace the external tool execution boundary.

- [ ] **Step 5: Add small explicit read-class fixtures**

```text
Tests/Fixtures/assembly-ui/illumina/reads_R1.fastq
Tests/Fixtures/assembly-ui/illumina/reads_R2.fastq
Tests/Fixtures/assembly-ui/ont/reads.fastq
Tests/Fixtures/assembly-ui/pacbio-hifi/reads.fastq
```

Use headers that `AssemblyReadType.detect(fromFASTQ:)` already understands:

```text
@A00488:56:H7WY3DSX5:1:1101:1000:1000 1:N:0:ATCACG
@9b50942a-4ec6-48d2-8f3b-4ff4f63cb17a runid=2de0f6d4 sampleid=sample1 read=1 ch=12 start_time=2024-01-01T00:00:00Z flow_cell_id=FLO-MIN114
@m64001_190101_000000/123/ccs
```

- [ ] **Step 6: Re-run the backend tests**

Run:

```bash
xcodebuild test -project Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishAppTests/AppUITestAssemblyBackendTests -only-testing:LungfishAppTests/FASTQOperationExecutionServiceTests
```

Expected: PASS with the deterministic backend tests green and no regression in the FASTQ execution service tests.

- [ ] **Step 7: Commit the deterministic assembly boundary**

```bash
git add Sources/LungfishApp/App/AppUITestAssemblyBackend.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift Tests/LungfishAppTests/AppUITestAssemblyBackendTests.swift Tests/Fixtures/assembly-ui Tests/Fixtures/README.md
git commit -m "test: add deterministic assembly ui-test backend"
```

### Task 5: Add The Assembly Wizard Accessibility Contract And Inventory Entries

**Files:**
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Create: `docs/testing/xcui-action-inventory.md`

- [ ] **Step 1: Write the failing XCUI tests for assembly UI state and result discoverability**

```swift
func testAssemblyWizardShowsOnlyValidToolsForIlluminaInputs() {
    let robot = AssemblyRobot()
    robot.launchOpeningFASTQFixture(.illuminaPaired)
    robot.openAssemblyDialog()

    XCTAssertTrue(robot.toolRow("assembly-tool-spades").exists)
    XCTAssertTrue(robot.toolRow("assembly-tool-megahit").exists)
    XCTAssertTrue(robot.toolRow("assembly-tool-skesa").exists)
    XCTAssertFalse(robot.toolRow("assembly-tool-flye").isEnabled)
    XCTAssertFalse(robot.toolRow("assembly-tool-hifiasm").isEnabled)
}
```

```swift
func testAssemblyResultAppearsUnderAnalysesAfterRun() {
    let robot = AssemblyRobot()
    robot.launchOpeningFASTQFixture(.illuminaPaired)
    robot.runAssembly(tool: .megahit, projectName: "megahit-demo")

    XCTAssertTrue(robot.sidebarGroup("sidebar-group-analyses").waitForExistence(timeout: 5))
    XCTAssertTrue(robot.analysisRow("analysis-result-megahit").waitForExistence(timeout: 5))
}
```

- [ ] **Step 2: Run the assembly XCUI tests to verify the missing IDs and labels**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/AssemblyWorkflowXCUITests/testAssemblyWizardShowsOnlyValidToolsForIlluminaInputs
```

Expected: FAIL because the assembly dialog, rows, readiness text, and analysis rows do not yet have stable accessibility identifiers.

- [ ] **Step 3: Add identifiers and labels to the assembly dialog and result viewer**

```swift
Picker("Assembler", selection: $selectedTool) {
    ...
}
.accessibilityIdentifier("assembly-tool-picker")

Text(validationMessage ?? "Ready to run.")
    .accessibilityIdentifier("assembly-readiness-text")

Button("Run") {
    performRun()
}
.accessibilityIdentifier("assembly-run-button")
```

```swift
Text(result.tool.displayName)
    .accessibilityIdentifier("assembly-result-summary-tool")

tableView.setAccessibilityIdentifier("assembly-result-table")
```

Also add stable identifiers for:

- assembly tool rows
- read-type picker
- project-name field
- advanced disclosure toggle
- sidebar analysis rows by tool

- [ ] **Step 4: Seed the action inventory with the first subsystem entries**

```markdown
| Subsystem | Action | Invocation | Coverage | Fixture | Boundary | Automation Readiness | Owner Test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Welcome | Open Project | system panel | both | analyses project | real system dialog | candidate for future automation | `ProjectLifecycleXCUITests.testWelcomeOpenProjectUsesRealOpenPanel` |
| Main Window | Toggle Sidebar | toolbar | both | analyses project | deterministic offline | not appropriate for automation | `MainWindowNavigationXCUITests.testToolbarAndAnalysesGroupAreReachableByPointerAndKeyboard` |
| Assembly | Run MEGAHIT | dialog button | both | illumina paired FASTQ | deterministic offline | candidate for future automation | `AssemblyWorkflowXCUITests.testMegahitRunCreatesAnalysisResult` |
```

- [ ] **Step 5: Re-run the assembly state XCUI tests**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/AssemblyWorkflowXCUITests/testAssemblyWizardShowsOnlyValidToolsForIlluminaInputs
```

Expected: PASS with stable assembly dialog discovery.

- [ ] **Step 6: Commit the assembly accessibility tranche**

```bash
git add Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift docs/testing/xcui-action-inventory.md
git commit -m "test: add assembly accessibility contract and action inventory"
```

### Task 6: Execute The Assembly Batch XCUI Pilot End To End

**Files:**
- Create: `Tests/LungfishXCUITests/TestSupport/AssemblyRobot.swift`
- Create: `Tests/LungfishXCUITests/AssemblyWorkflowXCUITests.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift`

- [ ] **Step 1: Write the failing end-to-end assembly pilot tests**

```swift
@MainActor
final class AssemblyWorkflowXCUITests: XCTestCase {
    func testMegahitRunCreatesAnalysisResult() {
        let robot = AssemblyRobot()
        robot.launchOpeningFASTQFixture(.illuminaPaired)
        robot.runAssembly(toolIdentifier: "assembly-tool-megahit", projectName: "megahit-demo")

        XCTAssertTrue(robot.analysisRow("analysis-result-megahit").waitForExistence(timeout: 5))
        robot.openAnalysisRow("analysis-result-megahit")
        XCTAssertTrue(robot.assemblyResultTable.waitForExistence(timeout: 5))
    }

    func testFlyeIsBlockedForIlluminaInputs() {
        let robot = AssemblyRobot()
        robot.launchOpeningFASTQFixture(.illuminaPaired)
        robot.openAssemblyDialog()
        robot.selectTool("assembly-tool-flye")

        XCTAssertEqual(robot.readinessText.label, "Flye is not available for Illumina short reads in v1.")
        XCTAssertFalse(robot.runButton.isEnabled)
    }

    func testHifiasmRunWorksWithKeyboardOnlyNavigation() {
        let robot = AssemblyRobot()
        robot.launchOpeningFASTQFixture(.pacBioHiFi)
        robot.runAssemblyByKeyboard(toolIdentifier: "assembly-tool-hifiasm", projectName: "hifi-demo")

        XCTAssertTrue(robot.analysisRow("analysis-result-hifiasm").waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 2: Run the full assembly pilot suite and capture the first failures**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/AssemblyWorkflowXCUITests
```

Expected: FAIL on missing robot support, missing waits, or any remaining identifiers and timing hooks.

- [ ] **Step 3: Fill in the assembly robot and remaining synchronization helpers**

```swift
struct AssemblyRobot {
    let app = XCUIApplication()
    let systemPanels: SystemPanelRobot

    var runButton: XCUIElement { app.descendants(matching: .any)["assembly-run-button"] }
    var readinessText: XCUIElement { app.descendants(matching: .any)["assembly-readiness-text"] }
    var assemblyResultTable: XCUIElement { app.tables["assembly-result-table"] }

    func openAssemblyDialog() {
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Assembly…"].click()
    }
}
```

- [ ] **Step 4: Re-run the full first-tranche XCUI suite**

Run:

```bash
scripts/testing/run-macos-xcui.sh \
  LungfishXCUITests/ProjectLifecycleXCUITests \
  LungfishXCUITests/MainWindowNavigationXCUITests \
  LungfishXCUITests/DatabaseSearchXCUITests \
  LungfishXCUITests/AssemblyWorkflowXCUITests
```

Expected: PASS with the first tranche of deterministic XCUI coverage green.

- [ ] **Step 5: Run the supporting non-XCUI tests**

Run:

```bash
xcodebuild test -project Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' \
  -only-testing:LungfishAppTests/AppUITestConfigurationTests \
  -only-testing:LungfishAppTests/AppUITestAssemblyBackendTests \
  -only-testing:LungfishAppTests/FASTQOperationExecutionServiceTests \
  -only-testing:LungfishAppTests/FASTQOperationDialogRoutingTests \
  -only-testing:LungfishIntegrationTests/AnalysesSidebarTests \
  -only-testing:LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests \
  -only-testing:LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests
```

Expected: PASS with no regressions in the shared runtime or assembly lower layers.

- [ ] **Step 6: Commit the assembly pilot tranche**

```bash
git add Tests/LungfishXCUITests/TestSupport/AssemblyRobot.swift Tests/LungfishXCUITests/AssemblyWorkflowXCUITests.swift Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift
git commit -m "test: add assembly workflow xcui pilot"
```

## Self-Review

- Spec coverage:
  - shared UI-test runtime: Task 1
  - real open/save panel coverage: Task 2
  - app-shell smoke: Task 3
  - deterministic external-boundary adapters: Task 4
  - accessibility contract and action inventory: Task 5
  - assembly batch pilot: Task 6
- Placeholder scan:
  - no `TBD`, `TODO`, or deferred implementation placeholders remain in the plan steps
  - later subsystems are intentionally scoped out rather than hand-waved
- Type consistency:
  - runtime uses `AppUITestConfiguration`
  - assembly execution boundary uses `AssemblyRunRequest` and `AssemblyResult`
  - XCUI runner remains `scripts/testing/run-macos-xcui.sh`

## Follow-On Plans

After this tranche is complete, write separate plans for:

- import center and export/save coverage
- viewer and inspector deep coverage
- metagenomics and classifier exhaustive coverage
- settings/help/about and auxiliary window coverage
- live-service smoke coverage

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-19-xcui-foundation-and-assembly-pilot.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
