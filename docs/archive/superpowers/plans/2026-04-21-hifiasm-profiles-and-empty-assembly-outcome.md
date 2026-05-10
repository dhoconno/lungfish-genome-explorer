# Hifiasm Profiles and Empty Assembly Outcome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Diploid` and `Haploid/Viral` curated `Hifiasm` profiles for both ONT and HiFi runs, and treat successful zero-contig assemblies as completed analyses with a `no contigs generated` outcome instead of failures.

**Architecture:** Keep `Hifiasm` as one tool entry and route both mode and curation through existing assembly request state: read type still decides whether `--ont` is present, while `selectedProfileID` decides whether curated haploid flags are added. Reclassify empty-contig runs by carrying an assembly-specific outcome through `AssemblyResult`, saving that metadata in the assembly sidecar, then updating CLI, operation detail, manifest summaries, and the assembly viewport to render the warning state without introducing a new global analysis status.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit assembly UI, LungfishWorkflow managed assembly pipeline, LungfishCLI, LungfishIO sidecars/manifests, XCTest, XCUITest, `swift test`, `swift build`, `scripts/testing/run-macos-xcui.sh`

---

## File Structure

- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`
  - Add curated `Hifiasm` profile options, set the default profile to `diploid`, and map `selectedProfileID` to curated `Hifiasm` arguments while keeping `--primary` independent.
- Modify: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
  - Make `buildHifiasmCommand(for:)` add `--ont` only for ONT input and add `--n-hap 1 -l0 -f0` only for the `haploid-viral` profile.
- Modify: `Tests/LungfishAppTests/AssemblyWizardSheetTests.swift`
  - Lock the new wizard source strings and default-profile behavior in the same source-text style the file already uses.
- Modify: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`
  - Verify the four `Hifiasm` command combinations: ONT/HiFi crossed with Diploid/Haploid-Viral, plus the independent `--primary` toggle.

- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift`
  - Add an assembly-specific persisted outcome field so managed assembly sidecars can represent `completed`, `completedWithNoContigs`, and legacy-loaded defaults without changing generic manifest status.
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyOutputNormalizer.swift`
  - Stop throwing on `contigCount == 0`; instead build an `AssemblyResult` with empty statistics, skip FASTA indexing for empty output, and set the new `completedWithNoContigs` outcome.
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
  - Change CLI reporting so empty-contig assemblies exit successfully with dedicated copy and without pretending normal contig metrics exist.
- Modify: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests.swift`
  - Verify the empty-output normalizer returns a persisted result instead of throwing, and that the outcome round-trips through `assembly-result.json`.

- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
  - Render an explicit empty-results state when `AssemblyResult.outcome == .completedWithNoContigs`, while keeping the existing summary strip and inspector integration available.
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift`
  - Update operation completion detail and user notifications so empty-contig runs are completed-with-warning instead of failures.
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
  - Keep BLAST and extraction hooks intact, but ensure the assembly viewport can open and present empty-contig results cleanly.
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
  - Record assembly manifest summaries as completed, with detail that no contigs were generated when applicable.
- Modify: `Tests/LungfishAppTests/AssemblyViewportTestSupport.swift`
  - Add a test fixture helper for empty-contig `AssemblyResult` instances so the viewer and viewport tests do not have to hand-roll sidecars.
- Modify: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`
  - Lock the empty-results state, identifiers, and copy.
- Modify: `Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift`
  - Verify empty-contig assembly results still open in the viewer instead of being surfaced as failures.
- Modify: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`
  - Verify assembly completion detail/notification handling uses the completed-with-warning path for empty outputs.

### Task 1: Add Curated Hifiasm Profiles to the Wizard and Command Builder

**Files:**
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
- Test: `Tests/LungfishAppTests/AssemblyWizardSheetTests.swift`
- Test: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Update `Tests/LungfishAppTests/AssemblyWizardSheetTests.swift`:

```swift
func testHifiasmProfilesDefaultToDiploidAndExposeHaploidViral() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains(#"return "diploid""#))
    XCTAssertTrue(source.contains(#".init(id: "diploid", title: "Diploid""#))
    XCTAssertTrue(source.contains(#".init(id: "haploid-viral", title: "Haploid/Viral""#))
    XCTAssertTrue(source.contains(#"arguments.append(contentsOf: ["--n-hap", "1", "-l0", "-f0"])"#))
    XCTAssertTrue(source.contains(#"if hifiasmPrimaryOnly {"#))
}
```

Update `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`:

```swift
func testBuildsHifiasmCommandForOntDiploidProfile() throws {
    let command = try makeHifiasmCommand(readType: .ontReads, profile: "diploid", extraArguments: [])
    XCTAssertTrue(command.arguments.contains("--ont"))
    XCTAssertFalse(command.arguments.contains("--n-hap"))
    XCTAssertFalse(command.arguments.contains("-l0"))
    XCTAssertFalse(command.arguments.contains("-f0"))
}

func testBuildsHifiasmCommandForOntHaploidProfile() throws {
    let command = try makeHifiasmCommand(readType: .ontReads, profile: "haploid-viral", extraArguments: [])
    XCTAssertTrue(command.arguments.contains("--ont"))
    XCTAssertTrue(command.arguments.contains("--n-hap"))
    XCTAssertTrue(command.arguments.contains("1"))
    XCTAssertTrue(command.arguments.contains("-l0"))
    XCTAssertTrue(command.arguments.contains("-f0"))
}

func testBuildsHifiasmCommandForHiFiHaploidProfileOmitsOntFlag() throws {
    let command = try makeHifiasmCommand(readType: .pacBioHiFi, profile: "haploid-viral", extraArguments: [])
    XCTAssertFalse(command.arguments.contains("--ont"))
    XCTAssertTrue(command.arguments.contains("--n-hap"))
}

func testBuildsHifiasmCommandKeepsPrimaryFlagIndependentOfProfile() throws {
    let command = try makeHifiasmCommand(
        readType: .ontReads,
        profile: "haploid-viral",
        extraArguments: ["--primary"]
    )
    XCTAssertTrue(command.arguments.contains("--ont"))
    XCTAssertTrue(command.arguments.contains("--primary"))
    XCTAssertTrue(command.arguments.contains("--n-hap"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyWizardSheetTests|ManagedAssemblyPipelineTests'
```

Expected:
- `AssemblyWizardSheetTests` fails because `Hifiasm` still has no curated profile options and no `diploid` default.
- `ManagedAssemblyPipelineTests` fails because `buildHifiasmCommand(for:)` only toggles `--ont` and does not react to `selectedProfileID`.

- [ ] **Step 3: Write the minimal implementation**

Update `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`:

```swift
case .hifiasm:
    return [
        .init(
            id: "diploid",
            title: "Diploid",
            detail: "Default long-read assembly behavior."
        ),
        .init(
            id: "haploid-viral",
            title: "Haploid/Viral",
            detail: "Favor single-haplotype or compact viral assemblies."
        ),
    ]
```

```swift
case .hifiasm:
    return "diploid"
```

```swift
case .hifiasm:
    if selectedProfileID == "haploid-viral" {
        arguments.append(contentsOf: ["--n-hap", "1", "-l0", "-f0"])
    }
    if hifiasmPrimaryOnly {
        arguments.append("--primary")
    }
```

Update `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`:

```swift
if request.readType == .ontReads {
    arguments.insert("--ont", at: 0)
}

if request.selectedProfileID == "haploid-viral" {
    arguments.insert(contentsOf: ["--n-hap", "1", "-l0", "-f0"], at: request.readType == .ontReads ? 1 : 0)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyWizardSheetTests|ManagedAssemblyPipelineTests'
```

Expected:
- `swift test` exits `0`.
- The `AssemblyWizardSheet` source-text test sees the `diploid` default and both profile strings.
- The command-builder tests confirm the four ONT/HiFi and Diploid/Haploid-Viral combinations.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift Tests/LungfishAppTests/AssemblyWizardSheetTests.swift Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift
git commit -m "feat: add curated hifiasm assembly profiles"
```

### Task 2: Persist Empty-Contig Assemblies as Completed Results

**Files:**
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyOutputNormalizer.swift`
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
- Test: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests.swift`

- [ ] **Step 1: Write the failing tests**

Update `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests.swift`:

```swift
func testNormalizeHifiasmOutputsMarksEmptyContigSetAsCompletedWithoutContigs() throws {
    let tempDir = try makeTempDirectory(prefix: "hifiasm-empty-normalizer")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = AssemblyRunRequest(
        tool: .hifiasm,
        readType: .ontReads,
        inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
        projectName: "ont-demo",
        outputDirectory: tempDir,
        threads: 8
    )

    let gfaURL = tempDir.appendingPathComponent("ont-demo.bp.p_ctg.gfa")
    try "".write(to: gfaURL, atomically: true, encoding: .utf8)

    let result = try AssemblyOutputNormalizer.normalize(
        request: request,
        primaryOutputDirectory: tempDir,
        commandLine: "hifiasm --ont -o ont-demo sample.fastq.gz",
        wallTimeSeconds: 20
    )

    XCTAssertEqual(result.outcome, .completedWithNoContigs)
    XCTAssertEqual(result.statistics.contigCount, 0)
    XCTAssertEqual(result.graphPath, gfaURL)
}

func testManagedAssemblyResultRoundTripsCompletedWithoutContigsOutcome() throws {
    let tempDir = try makeTempDirectory(prefix: "managed-assembly-empty-result")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
    let logURL = tempDir.appendingPathComponent("assembly.log")
    try "".write(to: contigsURL, atomically: true, encoding: .utf8)
    try "assembly completed without contigs\n".write(to: logURL, atomically: true, encoding: .utf8)

    let result = AssemblyResult(
        tool: .hifiasm,
        readType: .ontReads,
        contigsPath: contigsURL,
        graphPath: nil,
        logPath: logURL,
        assemblerVersion: "0.25.0-r726",
        commandLine: "hifiasm --ont -o ont-demo sample.fastq.gz",
        outputDirectory: tempDir,
        statistics: AssemblyStatistics(
            contigCount: 0,
            totalLengthBP: 0,
            largestContigBP: 0,
            smallestContigBP: 0,
            n50: 0,
            l50: 0,
            n90: 0,
            gcFraction: 0,
            meanLengthBP: 0
        ),
        wallTimeSeconds: 42,
        outcome: .completedWithNoContigs
    )

    try result.save(to: tempDir)
    let loaded = try AssemblyResult.load(from: tempDir)
    XCTAssertEqual(loaded.outcome, .completedWithNoContigs)
    XCTAssertEqual(loaded.statistics.contigCount, 0)
}
```

Add a CLI regression to `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests.swift` as a source assertion against `Sources/LungfishCLI/Commands/AssembleCommand.swift`:

```swift
func testAssembleCommandPrintsCompletedWithoutContigsMessage() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishCLI/Commands/AssembleCommand.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains("Assembly completed, but no contigs were generated."))
    XCTAssertTrue(source.contains("if result.outcome == .completedWithNoContigs"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter ManagedAssemblyArtifactTests
```

Expected:
- The normalizer test fails because empty outputs still throw.
- The round-trip test fails because `AssemblyResult` has no `outcome` field.
- The CLI source assertion fails because `AssembleCommand` still prints normal contig stats and success copy only.

- [ ] **Step 3: Write the minimal implementation**

Update `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift`:

```swift
public enum AssemblyOutcome: String, Codable, Sendable {
    case completed
    case completedWithNoContigs
}
```

```swift
public let outcome: AssemblyOutcome
```

```swift
outcome: AssemblyOutcome = .completed
```

and persist/load it in `PersistedManagedAssemblyResult`.

Update `Sources/LungfishWorkflow/Assembly/AssemblyOutputNormalizer.swift`:

```swift
let statistics = try AssemblyStatisticsCalculator.compute(from: contigsPath)
let outcome: AssemblyOutcome

if statistics.contigCount == 0 {
    outcome = .completedWithNoContigs
} else {
    try FASTAIndexBuilder.buildAndWrite(for: contigsPath)
    outcome = .completed
}
```

```swift
return AssemblyResult(
    tool: request.tool,
    readType: request.readType,
    contigsPath: contigsPath,
    graphPath: existingURL(graphPath),
    logPath: existingURL(logPath),
    assemblerVersion: assemblerVersion,
    commandLine: commandLine,
    outputDirectory: primaryOutputDirectory,
    statistics: statistics,
    wallTimeSeconds: wallTimeSeconds,
    scaffoldsPath: existingURL(scaffoldsPath),
    paramsPath: existingURL(paramsPath),
    outcome: outcome
)
```

Update `Sources/LungfishCLI/Commands/AssembleCommand.swift`:

```swift
if result.outcome == .completedWithNoContigs {
    print(formatter.header("Assembly Results"))
    print("")
    print("Log:     \(formatter.path(result.logPath?.path ?? outputDirectory.path))")
    print("")
    print(formatter.success("Assembly completed, but no contigs were generated."))
    return
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter ManagedAssemblyArtifactTests
```

Expected:
- `swift test` exits `0`.
- The normalizer returns a persisted empty-contig result instead of throwing.
- The sidecar round-trips `completedWithNoContigs`.
- The CLI source assertion sees the dedicated empty-contig branch.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Assembly/AssemblyResult.swift Sources/LungfishWorkflow/Assembly/AssemblyOutputNormalizer.swift Sources/LungfishCLI/Commands/AssembleCommand.swift Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests.swift
git commit -m "feat: preserve empty assembly results as completed"
```

### Task 3: Present Empty-Contig Assemblies as Completed-With-Warning in the App

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Tests/LungfishAppTests/AssemblyViewportTestSupport.swift`
- Test: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Update `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`:

```swift
func testCompletedWithoutContigsShowsAssemblyEmptyState() async throws {
    let vc = AssemblyResultViewController()
    _ = vc.view

    let result = try makeEmptyAssemblyResult(outcome: .completedWithNoContigs)

    try await vc.configureForTesting(result: result)

    XCTAssertTrue(vc.testEmptyStateLabel.isHidden == false)
    XCTAssertEqual(
        vc.testEmptyStateLabel.stringValue,
        "Assembly completed, but no contigs were generated."
    )
    XCTAssertTrue(vc.testContigTableView.isHidden)
}
```

Update `Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift`:

```swift
@MainActor
func testViewerDisplaysEmptyAssemblyOutcomeInsteadOfFailing() async throws {
    let viewer = ViewerViewController()
    _ = viewer.view

    let result = try makeEmptyAssemblyResult(outcome: .completedWithNoContigs)
    viewer.displayAssemblyResult(result)

    XCTAssertEqual(viewer.contentMode, .assembly)
    XCTAssertNotNil(viewer.assemblyResultController)
    XCTAssertEqual(
        viewer.assemblyResultController?.testEmptyStateLabel.stringValue,
        "Assembly completed, but no contigs were generated."
    )
}
```

Update `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`:

```swift
func testAssemblyCompletionDetailUsesNoContigsMessage() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift"),
        encoding: .utf8
    )
    XCTAssertTrue(source.contains("Assembly completed, but no contigs were generated."))
    XCTAssertTrue(source.contains("No Contigs Generated"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyResultViewControllerTests|AssemblyViewerIntegrationTests|FASTQOperationExecutionServiceTests'
```

Expected:
- The result-view tests fail because the controller assumes a browsable table and has no empty-results copy.
- The viewer integration test fails because the assembly controller exposes no dedicated empty state.
- The source assertion fails because assembly completion and notification copy still use the normal success or failure wording.

- [ ] **Step 3: Write the minimal implementation**

Update `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`:

```swift
private func applyEmptyAssemblyStateIfNeeded(for result: AssemblyResult) -> Bool {
    guard result.outcome == .completedWithNoContigs else { return false }
    emptyStateLabel.stringValue = "Assembly completed, but no contigs were generated."
    emptyStateLabel.isHidden = false
    contigTableView.isHidden = true
    detailContainer.isHidden = true
    actionBar.isHidden = true
    return true
}
```

Call that branch before loading the contig catalog, and expose `testEmptyStateLabel`.

Update `Tests/LungfishAppTests/AssemblyViewportTestSupport.swift`:

```swift
func makeEmptyAssemblyResult(
    outcome: AssemblyOutcome = .completedWithNoContigs
) throws -> AssemblyResult {
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("assembly-empty-viewport-test-\(UUID().uuidString).lungfish", isDirectory: true)
    let root = projectRoot
        .appendingPathComponent("Analyses", isDirectory: true)
        .appendingPathComponent("hifiasm-2026-04-21T20-00-00", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let contigsURL = root.appendingPathComponent("contigs.fasta")
    try "".write(to: contigsURL, atomically: true, encoding: .utf8)

    let result = AssemblyResult(
        tool: .hifiasm,
        readType: .ontReads,
        contigsPath: contigsURL,
        graphPath: root.appendingPathComponent("assembly_graph.gfa"),
        logPath: root.appendingPathComponent("assembly.log"),
        assemblerVersion: "0.25.0-r726",
        commandLine: "hifiasm --ont -o \(root.path)",
        outputDirectory: root,
        statistics: AssemblyStatistics(
            contigCount: 0,
            totalLengthBP: 0,
            largestContigBP: 0,
            smallestContigBP: 0,
            n50: 0,
            l50: 0,
            n90: 0,
            gcFraction: 0,
            meanLengthBP: 0
        ),
        wallTimeSeconds: 15,
        outcome: outcome
    )
    try result.save(to: root)
    return result
}
```

Update `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift`:

```swift
let completionDetail =
    result.outcome == .completedWithNoContigs
    ? "Assembly completed, but no contigs were generated."
    : "Assembly complete"

OperationCenter.shared.complete(id: opID, detail: completionDetail, bundleURLs: [bundleURL])
```

```swift
postNotification(
    title: result.outcome == .completedWithNoContigs ? "No Contigs Generated" : "Assembly Complete",
    body: result.outcome == .completedWithNoContigs
        ? "\(request.tool.displayName) finished for \(projectName), but no contigs were generated."
        : "\(request.tool.displayName) finished for \(projectName).",
    isSuccess: true
)
```

Update `Sources/LungfishApp/App/AppDelegate.swift` anywhere assembly analyses are recorded:

```swift
let summary = result.outcome == .completedWithNoContigs
    ? "No contigs generated"
    : "\(result.statistics.contigCount) contigs, N50 \(result.statistics.n50) bp"
```

Keep `status: .completed`.

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'AssemblyResultViewControllerTests|AssemblyViewerIntegrationTests|FASTQOperationExecutionServiceTests'
```

Expected:
- `swift test` exits `0`.
- The result viewport shows the explicit empty state.
- Empty-contig assemblies still open normally in the viewer.
- Operation and notification copy use completed-with-warning wording rather than failure wording.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/AssemblyViewportTestSupport.swift Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift
git commit -m "feat: show empty assembly runs as completed warnings"
```

## Self-Review

- Spec coverage:
  - `Hifiasm` `Diploid`/`Haploid/Viral` profiles: Task 1
  - `--ont` remains read-type driven and haploid flags remain profile-driven: Task 1
  - `Primary contigs only` remains independent: Task 1
  - empty-contig assemblies become completed-with-warning and persist that outcome: Task 2
  - CLI success semantics and copy for empty outputs: Task 2
  - app operation detail, manifest summary, inspector/viewport opening, and empty-results UI: Task 3
- Placeholder scan:
  - No `TODO`, `TBD`, or implicit “write tests later” steps remain.
- Type consistency:
  - The plan consistently uses `AssemblyOutcome.completedWithNoContigs`, `selectedProfileID == "haploid-viral"`, and the same empty-contig copy string across workflow, CLI, and app surfaces.
