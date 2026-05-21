import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowOperationDialogStateTests: XCTestCase {
    func testStateShowsEnabledONTGenotypingAsRunnableWorkflow() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)

        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        let ont = try XCTUnwrap(state.tools.first { $0.title == "ONT Genotyping" })
        XCTAssertEqual(ont.availability, .available)
    }

    func testEnabledWorkflowPackageBuildsLocalWorkflowRunWithExpectedOutputs() async throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let packageURL = helloWorldNextflowPackageURL()
        packageStore.addPackage(at: packageURL)
        let package = try WorkflowPackageValidator.validatePackage(at: packageURL)
        enablementStore.setUserWorkflow(package, enabled: true)

        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let referenceURL = projectURL.appendingPathComponent("Reference Sequences/ref.lungfishref", isDirectory: true)
        let readsURL = projectURL.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectTool("package.org.lungfish.templates.hello-world-nextflow")
        state.setReference(referenceURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)

        let launchRequest = try state.makeLaunchRequest()
        guard case .workflowPackage(let request, let bundleRoot) = launchRequest else {
            return XCTFail("Expected workflow package launch request")
        }

        XCTAssertEqual(request.workflowURL, packageURL.appendingPathComponent("main.nf").standardizedFileURL)
        XCTAssertEqual(request.engine, .nextflow)
        XCTAssertEqual(request.inputURLs, [referenceURL.standardizedFileURL, readsURL.standardizedFileURL])
        XCTAssertEqual(
            request.expectedOutputURLs,
            [outputURL.appendingPathComponent("hello-world-nextflow.lungfishref", isDirectory: true).standardizedFileURL]
        )
        XCTAssertEqual(request.params["reference_bundle"], referenceURL.standardizedFileURL.path)
        XCTAssertEqual(request.params["reads_bundle"], readsURL.standardizedFileURL.path)
        XCTAssertEqual(request.params["outdir"], outputURL.standardizedFileURL.path)
        XCTAssertEqual(bundleRoot, outputURL.appendingPathComponent("Workflow Runs", isDirectory: true).standardizedFileURL)
        XCTAssertTrue(request.cliArguments(bundlePath: bundleRoot.appendingPathComponent("run.lungfishrun")).contains("--expected-output"))
    }

    func testONTGenotypingLaunchRequestUsesConfiguredSimpleOptions() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)
        state.outputName = "sample-ont"
        state.threads = 6
        state.minSupport = 3

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        XCTAssertEqual(request.inputFASTQURLs, [readsURL.standardizedFileURL])
        XCTAssertEqual(request.referenceSourceURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(request.outputDirectory, outputURL.standardizedFileURL)
        XCTAssertEqual(request.outputName, "sample-ont")
        XCTAssertEqual(request.threads, 6)
        XCTAssertEqual(request.minSupport, 3)
    }

    func testInitialSelectedReadBundlesAreUsedForONTGenotyping() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let firstReadsURL = temp.appendingPathComponent("reads-a.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("reads-b.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstReadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondReadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [firstReadsURL, secondReadsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setOutputDirectory(outputURL)

        XCTAssertEqual(state.selectedReadURLs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
        XCTAssertEqual(state.datasetLabel, "2 read bundles selected")

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
    }

    func testReconfiguringForNewProjectResetsReferenceAndOutputDirectory() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let firstProjectURL = temp.appendingPathComponent("first.lungfish", isDirectory: true)
        let secondProjectURL = temp.appendingPathComponent("second.lungfish", isDirectory: true)
        let firstReferenceURL = firstProjectURL.appendingPathComponent("Reference Sequences/ref-a.lungfishref", isDirectory: true)
        let secondReferenceURL = secondProjectURL.appendingPathComponent("Reference Sequences/ref-b.lungfishref", isDirectory: true)
        let secondReadsURL = secondProjectURL.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
        for url in [firstReferenceURL, secondReferenceURL, secondReadsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: firstProjectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        XCTAssertEqual(state.selectedReferenceURL, firstReferenceURL.standardizedFileURL)
        XCTAssertEqual(
            state.outputDirectoryURL,
            firstProjectURL
                .appendingPathComponent("Analyses/ONT genotyping results", isDirectory: true)
                .standardizedFileURL
        )

        state.configureProject(projectURL: secondProjectURL, selectedReadURLs: [secondReadsURL])

        XCTAssertEqual(state.projectURL, secondProjectURL.standardizedFileURL)
        XCTAssertEqual(state.selectedReferenceURL, secondReferenceURL.standardizedFileURL)
        XCTAssertEqual(state.selectedReadURLs, [secondReadsURL.standardizedFileURL])
        XCTAssertEqual(
            state.outputDirectoryURL,
            secondProjectURL
                .appendingPathComponent("Analyses/ONT genotyping results", isDirectory: true)
                .standardizedFileURL
        )
    }

    func testONTGenotypingDefaultsToDedicatedAnalysesResultsDirectory() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertEqual(
            state.outputDirectoryURL,
            temp.appendingPathComponent("Analyses/ONT genotyping results", isDirectory: true).standardizedFileURL
        )
    }

    func testWorkflowOperationsDialogTreatsFASTQBundlesAsSidebarOnlySelection() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let readPicker = try sourceBlock(
            startingAt: "    private var readPicker: some View",
            endingBefore: "    @ViewBuilder\n    private var primarySettings",
            in: source
        )
        let referencePicker = try sourceBlock(
            startingAt: "    private var referencePicker: some View",
            endingBefore: "    private var readPicker: some View",
            in: source
        )

        XCTAssertTrue(readPicker.contains("Text(state.selectedReadsDisplay)"))
        XCTAssertFalse(readPicker.contains("Button("), "FASTQ bundles must be fixed to the project sidebar selection for the dialog lifetime.")
        XCTAssertFalse(source.contains("browseForReads"))
        XCTAssertFalse(source.contains("Choose FASTQ Bundles"))
        XCTAssertFalse(source.contains("state.setReads([])"))

        XCTAssertTrue(referencePicker.contains("browseForReference()"))
        XCTAssertTrue(referencePicker.contains("Button("), "Reference selection should remain editable.")
    }

    func testWorkflowOperationsRunClosesWindowAsSoonAsLaunchIsAccepted() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsWindowController.swift"),
            encoding: .utf8
        )
        let runStart = try XCTUnwrap(
            source.range(of: "    private func run(_ request: WorkflowOperationLaunchRequest) {")
        )
        let runSuffix = source[runStart.lowerBound...]
        let closeRange = try XCTUnwrap(runSuffix.range(of: "window?.close()"))
        let taskRange = try XCTUnwrap(runSuffix.range(of: "Task { @MainActor [weak self] in"))

        XCTAssertLessThan(
            closeRange.lowerBound,
            taskRange.lowerBound,
            "The workflow operations window should dismiss immediately after accepting Run, before waiting on the async operation."
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WorkflowOperationDialogStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func helloWorldNextflowPackageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg", isDirectory: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowOperationDialogStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceBlock(
        startingAt startNeedle: String,
        endingBefore endNeedle: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startNeedle))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: endNeedle))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
