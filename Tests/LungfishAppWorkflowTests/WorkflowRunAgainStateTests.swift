import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowRunAgainStateTests: XCTestCase {
    func testExplicitValidationEnablesOnlyTheRetainedConfigurationAndUsesASiblingRunRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        XCTAssertTrue(fixture.state.isRunEnabled)
        guard case .workflowPackage(let request, let bundleRoot) = try fixture.state.makeLaunchRequest() else {
            return XCTFail("Expected the typed local package request")
        }
        XCTAssertEqual(request.replaySourceBundleURL?.path, fixture.runBundle.path)
        XCTAssertEqual(request.cpus, 3)
        XCTAssertFalse(bundleRoot.pathComponents.starts(with: request.outputDirectory.pathComponents))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
        fixture.state.threads = 9
        XCTAssertFalse(fixture.state.isRunEnabled, "A previous check cannot authorize edited settings")
    }

    func testValidationFailureKeepsConfigurationVisibleAndBlockedForRepair() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        XCTAssertTrue(fixture.state.isRunEnabled)
        try "changed local input".write(to: fixture.configuration.request.inputURLs[1].appendingPathComponent("manifest.json"),
                                       atomically: true, encoding: .utf8)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        XCTAssertFalse(fixture.state.isRunEnabled)
        XCTAssertTrue(fixture.state.readinessText.localizedCaseInsensitiveContains("input"))
        XCTAssertEqual(fixture.state.replaySourceBundleURL?.path, fixture.runBundle.path)
        XCTAssertEqual(fixture.state.outputName, "retained-name")
    }

    func testInvalidReplacementCheckClearsBusyStateAndRejectsLateCompletion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        let entered = expectation(description: "Identity worker entered")
        let release = DispatchSemaphore(value: 0)
        let oldCheck = Task {
            await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in
                entered.fulfill()
                release.wait()
                return runtime
            })
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(fixture.state.isCheckingReplay)
        fixture.state.setReads([])
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        XCTAssertFalse(fixture.state.isCheckingReplay)
        XCTAssertFalse(fixture.state.isRunEnabled)
        release.signal()
        await oldCheck.value
        XCTAssertFalse(fixture.state.isCheckingReplay)
        XCTAssertFalse(fixture.state.isRunEnabled)
    }

    func testBothOutputNameTemplateSpellingsRenderAndRoundTripWithoutExtraBraces() throws {
        for template in ["{outputName}.lungfishref", "{{outputName}}.lungfishref"] {
            XCTAssertEqual(WorkflowRunAgainPresentation.render(template, outputName: "retained-name"), "retained-name.lungfishref")
            let fixture = try makeFixture(template: template)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            XCTAssertEqual(try WorkflowRunAgainPresentation.outputName(for: fixture.configuration), "retained-name")
            try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
            XCTAssertEqual(fixture.state.outputName, "retained-name")
        }
    }

    func testLibraryLocateOfAlreadyEnabledPackageIsRefreshedByExplicitCheck() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        let relocated = fixture.root.appendingPathComponent("Relocated.lungfishflowpkg")
        try FileManager.default.moveItem(at: fixture.configuration.identity.packageURL, to: relocated)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        XCTAssertFalse(fixture.state.isRunEnabled)
        let registration = try XCTUnwrap(fixture.packages.registrationSnapshot.first)
        let library = WorkflowLibraryViewModel(items: [], store: fixture.enablement, packageStore: fixture.packages,
            automaticallyRefreshUserWorkflowPackages: false)
        try await library.locateRegistration(registration, at: relocated)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        XCTAssertTrue(fixture.state.isRunEnabled, fixture.state.readinessText)
        XCTAssertEqual(fixture.state.selectedToolID, "package.invented-repeat")
        XCTAssertEqual(fixture.state.threads, 3)
        XCTAssertEqual(fixture.state.outputName, "retained-name")
        if fixture.state.isRunEnabled, case .workflowPackage(let request, _) = try fixture.state.makeLaunchRequest() {
            XCTAssertEqual(request.workflowURL.deletingLastPathComponent().path, relocated.path)
        }
    }

    func testRetainedOutputDirectoryExistenceDoesNotChangeItsStoredPathMeaning() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = try XCTUnwrap(fixture.configuration.request.expectedOutputURLs.first)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertEqual(try WorkflowRunAgainPresentation.outputName(for: fixture.configuration), "retained-name")
        try FileManager.default.removeItem(at: output)
        XCTAssertEqual(try WorkflowRunAgainPresentation.outputName(for: fixture.configuration), "retained-name")
    }

    private func makeRuntime(in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("fake-local-engine")
        try "never executed".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testSelectingTheSameRetainedPackageDoesNotResetItsConfiguration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        let output = fixture.state.outputDirectoryURL
        fixture.state.selectTool("package.invented-repeat")
        XCTAssertEqual(fixture.state.outputName, "retained-name")
        XCTAssertEqual(fixture.state.outputDirectoryURL, output)
        XCTAssertEqual(fixture.state.threads, 3)
        XCTAssertEqual(fixture.state.replayConfiguration, fixture.configuration)
    }

    func testReopeningRestoresExactPackageInputsResourcesAndFreshDestinationWithoutExecution() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        XCTAssertEqual(fixture.state.selectedToolID, "package.invented-repeat")
        XCTAssertEqual(fixture.state.selectedReferenceURL, fixture.configuration.request.inputURLs[0])
        XCTAssertEqual(fixture.state.selectedReadURLs, [fixture.configuration.request.inputURLs[1]])
        XCTAssertEqual(fixture.state.threads, 3)
        XCTAssertEqual(fixture.state.outputName, "retained-name")
        XCTAssertEqual(fixture.state.replaySourceBundleURL?.path, fixture.runBundle.path)
        let output = try XCTUnwrap(fixture.state.outputDirectoryURL)
        XCTAssertNotEqual(output, fixture.configuration.request.outputDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try String(contentsOf: fixture.runBundle.appendingPathComponent("sentinel.txt"), encoding: .utf8), "original attempt")
        XCTAssertFalse(fixture.state.isRunEnabled, "Identity/runtime/destination checks must precede a repeat")
    }

    func testMissingPackageStaysSelectedAfterAsynchronousDiscoveryAndRequiresRepair() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.configuration.identity.packageURL)
        try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)
        fixture.state.refreshWorkflowAvailability()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.state.selectedToolID, "package.invented-repeat")
        XCTAssertEqual(fixture.state.replaySourceBundleURL?.path, fixture.runBundle.path)
        XCTAssertFalse(fixture.state.isRunEnabled)
        XCTAssertTrue(fixture.state.readinessText.localizedCaseInsensitiveContains("package"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.request.outputDirectory.path))
    }

    func testUnrepresentableRetainedSettingsAreExplicitlyRejectedInsteadOfResetToDefaults() throws {
        let fixture = try makeFixture(memory: "7 GB")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try fixture.state.restoreReplayConfiguration(fixture.configuration, sourceBundleURL: fixture.runBundle)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("settings"))
        }
        XCTAssertNil(fixture.state.replaySourceBundleURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.request.outputDirectory.path))
    }

    private struct Fixture {
        let root: URL
        let runBundle: URL
        let state: WorkflowOperationDialogState
        let configuration: LocalWorkflowReplayConfiguration
        let packages: WorkflowLibraryImportedPackageStore
        let enablement: WorkflowLibraryEnablementStore
    }

    private func makeFixture(memory: String? = nil, template: String = "{outputName}.lungfishref") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-repeat-state-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "// invented fixture; never executed".write(to: package.appendingPathComponent("main.nf"), atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(
            id: "invented-repeat", name: "Invented Repeat", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "reference", name: "Reference", bundleTypes: [.lungfishref]),
                     WorkflowPackageInput(id: "reads", name: "Reads", bundleTypes: [.lungfishfastq])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref,
                                           pathTemplate: template)]
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let inputs = [root.appendingPathComponent("reference.lungfishref"), root.appendingPathComponent("reads.lungfishfastq")]
        for input in inputs {
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            try "invented local payload".write(to: input.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        let output = root.appendingPathComponent("original-results")
        let request = LocalWorkflowRunRequest(
            workflowURL: package.appendingPathComponent("main.nf"), engine: .nextflow, inputURLs: inputs,
            outputDirectory: output, expectedOutputURLs: [output.appendingPathComponent("retained-name.lungfishref")],
            params: ["reference": inputs[0].path, "reference_bundle": inputs[0].path,
                     "reads": inputs[1].path, "reads_bundle": inputs[1].path, "outdir": output.path],
            cpus: 3, memory: memory
        )
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        let runBundle = root.appendingPathComponent("original.lungfishrun")
        try FileManager.default.createDirectory(at: runBundle, withIntermediateDirectories: true)
        try "original attempt".write(to: runBundle.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
        let history = request.manifest(replayIdentity: identity, executionStatus: .completed, exitCode: 0)
        try LocalWorkflowRunBundleStore.write(history, to: runBundle)
        let step = StepExecution(toolName: "lungfish-cli workflow run", toolVersion: "test",
            command: ["lungfish-cli"] + request.cliArguments(bundlePath: runBundle), inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: runBundle.appendingPathComponent("manifest.json"), role: .output)],
            exitCode: 0, wallTime: 1, endTime: Date())
        let run = WorkflowRun(name: "Invented local run", endTime: Date(), status: .completed, steps: [step])
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: runBundle)
        let configuration = try LocalWorkflowReplayConfiguration.restored(from: history)
        let suite = "WorkflowRunAgainStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let enablement = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packages = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let validated = try WorkflowPackageValidator.validatePackage(at: package)
        packages.addPackage(at: package)
        _ = packages.validatedPackages()
        enablement.setUserWorkflow(validated, enabled: true)
        let state = WorkflowOperationDialogState(projectURL: root, enablementStore: enablement, packageStore: packages)
        return Fixture(root: root, runBundle: runBundle, state: state, configuration: configuration, packages: packages, enablement: enablement)
    }
}
