# Hifiasm ONT Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Lungfish to run `Hifiasm` on ONT reads via `hifiasm --ont`, while keeping `Flye` available for ONT and preserving the existing HiFi/CCS `Hifiasm` path.

**Architecture:** Keep a single `Hifiasm` tool entry and make read type authoritative. Expand the compatibility matrix and user-facing assembly catalog copy so ONT datasets expose both `Flye` and `Hifiasm`, then branch only in the `Hifiasm` command builder so ONT runs add `--ont` while HiFi runs keep the existing command shape and output normalization.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit dialog state, LungfishWorkflow managed assembly pipeline, XCTest, XCUITest, `scripts/testing/run-macos-xcui.sh`

---

## File Structure

- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`
  - Expand ONT compatibility to include `Hifiasm` while preserving existing Illumina and HiFi behavior.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
  - Update ONT assembly availability/copy so the operations dialog reflects dual long-read `Hifiasm` support without changing the default ONT tool ordering.
- Modify: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
  - Add the `--ont` branch to `buildHifiasmCommand(for:)` and update the topology error text to cover both ONT and HiFi single-input runs.
- Modify: `Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift`
  - Lock the new ONT compatibility matrix in unit tests.
- Modify: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
  - Verify ONT datasets expose both `Flye` and `Hifiasm` and that `Hifiasm` copy no longer claims HiFi-only support.
- Modify: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`
  - Verify `Hifiasm` emits `--ont` for ONT input, omits it for HiFi input, and reports the correct single-input topology error.
- Modify: `Tests/LungfishXCUITests/AssemblyXCUITests.swift`
  - Add a deterministic UI regression that proves the ONT assembly dialog exposes `Hifiasm` and leaves the primary Run action enabled when it is selected.

### Task 1: Expose Hifiasm for ONT in Compatibility and Assembly UI

**Files:**
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Test: `Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Test: `Tests/LungfishXCUITests/AssemblyXCUITests.swift`

- [ ] **Step 1: Write the failing tests**

Update `Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift`:

```swift
func testONTReadsEnableFlyeAndHifiasm() {
    XCTAssertEqual(
        Set(AssemblyCompatibility.supportedTools(for: .ontReads)),
        [.flye, .hifiasm]
    )
    XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .flye, for: .ontReads))
    XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .ontReads))
    XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .spades, for: .ontReads))
    XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .megahit, for: .ontReads))
    XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .skesa, for: .ontReads))
}
```

Update `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`:

```swift
func testAssemblySidebarFiltersToCompatibleToolsForPersistedONTReadType() throws {
    let bundleURL = try makeFASTQBundle(
        fastqName: "reads.fastq",
        fastqContents: """
        @unknown-read
        ACGT
        +
        !!!!
        """
    )
    defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

    let primaryFASTQURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
    FASTQMetadataStore.save(
        PersistedFASTQMetadata(assemblyReadType: .ontReads),
        for: primaryFASTQURL
    )

    let state = FASTQOperationDialogState(
        initialCategory: .assembly,
        selectedInputURLs: [bundleURL]
    )

    XCTAssertEqual(state.sidebarItems.map(\.id), [
        FASTQOperationToolID.flye.rawValue,
        FASTQOperationToolID.hifiasm.rawValue,
    ])
    XCTAssertTrue(state.sidebarItems.allSatisfy { $0.availability == .available })
}

func testHifiasmAssemblySubtitleMentionsOntAndHiFi() {
    XCTAssertEqual(
        FASTQOperationToolID.hifiasm.subtitle,
        "Assemble ONT or PacBio HiFi/CCS long reads into phased contigs."
    )
}
```

Update `Tests/LungfishXCUITests/AssemblyXCUITests.swift`:

```swift
@MainActor
func testOntDialogShowsHifiasmAndKeepsRunEnabled() throws {
    let projectURL = try LungfishProjectFixtureBuilder.makeOntAssemblyProject(named: "OntHifiasmAssemblyFixture")
    let robot = AssemblyRobot()
    defer {
        robot.app.terminate()
        try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
    }

    robot.launch(opening: projectURL, backendMode: "deterministic")
    robot.selectSidebarItem(named: "reads.fastq")
    robot.openAssemblyDialog()

    XCTAssertTrue(
        robot.app.descendants(matching: .any)["fastq-operations-assembly-tool-flye"].firstMatch.exists
    )
    XCTAssertTrue(
        robot.app.descendants(matching: .any)["fastq-operations-assembly-tool-hifiasm"].firstMatch.exists
    )

    robot.chooseAssembler("Hifiasm")
    robot.expandAdvancedOptionsIfNeeded()
    robot.reveal(robot.hifiasmPrimaryOnlyToggle)

    let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "enabled == true"),
        object: robot.primaryActionButton
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyCompatibilityTests|FASTQOperationDialogRoutingTests'
scripts/testing/run-macos-xcui.sh LungfishXCUITests/AssemblyXCUITests/testOntDialogShowsHifiasmAndKeepsRunEnabled
```

Expected:
- The unit test run fails because `AssemblyCompatibility.supportedTools(for: .ontReads)` still returns only `flye`, the persisted ONT sidebar still shows only `flye`, and `FASTQOperationToolID.hifiasm.subtitle` is still HiFi-only.
- The XCUI run fails because the ONT assembly dialog does not expose `fastq-operations-assembly-tool-hifiasm`.

- [ ] **Step 3: Write the minimal implementation**

Update `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`:

```swift
public static func supportedTools(for readType: AssemblyReadType) -> [AssemblyTool] {
    switch readType {
    case .illuminaShortReads:
        return [.spades, .megahit, .skesa]
    case .ontReads:
        return [.flye, .hifiasm]
    case .pacBioHiFi:
        return [.hifiasm]
    }
}
```

Update `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`:

```swift
private static func requiredReadTypeBadge(for tool: AssemblyTool) -> String {
    switch tool {
    case .spades, .megahit, .skesa:
        return "Requires Illumina"
    case .flye:
        return "Requires ONT"
    case .hifiasm:
        return "Requires ONT or HiFi/CCS"
    }
}
```

```swift
case .hifiasm:
    return "Assemble ONT or PacBio HiFi/CCS long reads into phased contigs."
```

Keep the ONT tool order as `[.flye, .hifiasm]` so existing default-tool behavior still prefers `Flye` for ONT datasets.

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyCompatibilityTests|FASTQOperationDialogRoutingTests'
scripts/testing/run-macos-xcui.sh LungfishXCUITests/AssemblyXCUITests/testOntDialogShowsHifiasmAndKeepsRunEnabled
```

Expected:
- `swift test` exits `0` with the compatibility and routing tests green.
- The deterministic XCUI test exits `0`, proving the ONT dialog now shows both `Flye` and `Hifiasm` and selecting `Hifiasm` leaves the primary action enabled.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift Tests/LungfishXCUITests/AssemblyXCUITests.swift
git commit -m "feat: expose hifiasm for ont assembly"
```

### Task 2: Add ONT Mode to the Hifiasm Command Builder

**Files:**
- Modify: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Update `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`:

```swift
func testBuildsHifiasmCommandForOntReadsAddsOntFlag() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-assembly-hifiasm-ont-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = AssemblyRunRequest(
        tool: .hifiasm,
        readType: .ontReads,
        inputURLs: [URL(fileURLWithPath: "/tmp/ont.fastq.gz")],
        projectName: "ont-demo",
        outputDirectory: tempDir,
        threads: 8
    )

    let command = try ManagedAssemblyPipeline.buildCommand(for: request)

    XCTAssertEqual(command.executable, "hifiasm")
    XCTAssertTrue(command.arguments.contains("--ont"))
    XCTAssertEqual(command.arguments.last, "/tmp/ont.fastq.gz")
}

func testBuildsHifiasmCommandForHiFiDoesNotAddOntFlag() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-assembly-hifiasm-hifi-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = AssemblyRunRequest(
        tool: .hifiasm,
        readType: .pacBioHiFi,
        inputURLs: [URL(fileURLWithPath: "/tmp/hifi.fastq.gz")],
        projectName: "hifi-demo",
        outputDirectory: tempDir,
        threads: 8
    )

    let command = try ManagedAssemblyPipeline.buildCommand(for: request)

    XCTAssertFalse(command.arguments.contains("--ont"))
    XCTAssertEqual(command.arguments.last, "/tmp/hifi.fastq.gz")
}

func testHifiasmTopologyErrorUsesDualLongReadLabel() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-assembly-hifiasm-invalid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = AssemblyRunRequest(
        tool: .hifiasm,
        readType: .ontReads,
        inputURLs: [
            URL(fileURLWithPath: "/tmp/sample-1.fastq.gz"),
            URL(fileURLWithPath: "/tmp/sample-2.fastq.gz"),
        ],
        projectName: "bad-hifiasm-demo",
        outputDirectory: tempDir,
        threads: 8
    )

    XCTAssertThrowsError(try ManagedAssemblyPipeline.buildCommand(for: request)) { error in
        XCTAssertEqual(
            error.localizedDescription,
            "Hifiasm expects a single ONT or PacBio HiFi/CCS FASTQ input in v1."
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'ManagedAssemblyPipelineTests'
```

Expected:
- The new ONT command test fails because `buildHifiasmCommand(for:)` does not emit `--ont`.
- The topology test fails because the current error text still says `single PacBio HiFi/CCS FASTQ input in v1.`

- [ ] **Step 3: Write the minimal implementation**

Update `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`:

```swift
private static func buildHifiasmCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
    guard request.inputURLs.count == 1, let inputURL = request.inputURLs.first else {
        throw ManagedAssemblyPipelineError.unsupportedInputTopology(
            "Hifiasm expects a single ONT or PacBio HiFi/CCS FASTQ input in v1."
        )
    }
    try FileManager.default.createDirectory(
        at: request.outputDirectory,
        withIntermediateDirectories: true
    )
    let outputPrefix = request.outputDirectory.appendingPathComponent(request.projectName).path
    var arguments = ["-o", outputPrefix, "-t", "\(request.threads)"]
    if request.readType == .ontReads {
        arguments.append("--ont")
    }
    arguments.append(inputURL.path)
    arguments += request.extraArguments
    return ManagedAssemblyCommand(
        executable: "hifiasm",
        arguments: arguments,
        environment: request.tool.environmentName,
        workingDirectory: request.outputDirectory
    )
}
```

Do not change the output normalization path or create a second tool variant. The only runtime branch is the ONT-specific `--ont` flag.

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'ManagedAssemblyPipelineTests'
```

Expected:
- `ManagedAssemblyPipelineTests` exits `0`.
- The ONT builder test shows `--ont` is present only for ONT input, and the updated topology message is green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift
git commit -m "feat: add ont mode for hifiasm"
```

### Task 3: Run the Focused Regression Sweep and Produce a Fresh Debug Build

**Files:**
- Modify only if verification exposes a real regression in one of the files above.

- [ ] **Step 1: Run the focused unit regression suite**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyCompatibilityTests|FASTQOperationDialogRoutingTests|ManagedAssemblyPipelineTests'
```

Expected:
- All three test groups pass with exit code `0`.

- [ ] **Step 2: Run the deterministic ONT assembly XCUI regression**

Run:

```bash
scripts/testing/run-macos-xcui.sh LungfishXCUITests/AssemblyXCUITests/testOntDialogShowsHifiasmAndKeepsRunEnabled
```

Expected:
- The ONT assembly dialog test passes and proves the interactive dialog now exposes `Hifiasm` for ONT input without disabling Run.

- [ ] **Step 3: Build a fresh debug app**

Run:

```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer --product Lungfish
```

Expected:
- `Build of product 'Lungfish' complete!`

- [ ] **Step 4: Check the tree for unexpected fallout**

Run:

```bash
git status --short
```

Expected:
- Only the intended `Hifiasm` ONT support files remain modified. If unrelated files changed, inspect them before proceeding.

- [ ] **Step 5: Commit any verification-driven touch-ups**

If verification required no follow-up edits, skip the commit. If it did, use:

```bash
git add Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift Tests/LungfishXCUITests/AssemblyXCUITests.swift
git commit -m "test: verify hifiasm ont support"
```
