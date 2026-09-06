import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowRunAgainControllerTests: XCTestCase {
    func testDurableRunChooserReopensExactConfigurationWithoutLaunchingOrRequiringOperationHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = makeController(fixture)
        defer { controller.close() }
        let before = try Data(contentsOf: fixture.runBundle.appendingPathComponent("manifest.json"))
        try await controller.choosePreviousRun { fixture.runBundle }
        XCTAssertEqual(fixture.state.replaySourceBundleURL?.path, fixture.runBundle.path)
        XCTAssertEqual(fixture.state.selectedReadURLs, [fixture.configuration.request.inputURLs[1]])
        XCTAssertEqual(fixture.state.threads, 3)
        XCTAssertEqual(fixture.state.outputName, "retained-name")
        XCTAssertFalse(fixture.state.isRunEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.state.outputDirectoryURL).path))
        XCTAssertEqual(try Data(contentsOf: fixture.runBundle.appendingPathComponent("manifest.json")), before)
        XCTAssertEqual(controller.window?.frameAutosaveName, "")
    }

    func testReopeningMissingPackageKeepsItVisibleForRepair() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.configuration.identity.packageURL)
        let controller = makeController(fixture)
        defer { controller.close() }
        try await controller.reopenPreviousRun(at: fixture.runBundle)
        XCTAssertEqual(fixture.state.selectedToolID, "package.invented-repeat")
        XCTAssertTrue(fixture.state.readinessText.localizedCaseInsensitiveContains("package"))
        XCTAssertFalse(fixture.state.isRunEnabled)
    }

    func testChooserCannotApplyAnOldSelectionAfterWindowReconfiguration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = makeController(fixture)
        defer { controller.close() }
        var chose = false
        do {
            try await controller.choosePreviousRun {
                chose = true
                controller.configure(projectURL: nil, routeContext: nil, selectedReadURLs: [],
                    sidebarInputSelection: nil, initialToolID: nil)
                return fixture.runBundle
            }
            XCTFail("Expected replaced configuration refusal")
        } catch {}
        XCTAssertTrue(chose)
        XCTAssertNil(fixture.state.replaySourceBundleURL)
    }

    func testCapturedOriginRejectsReplacedProjectGenerationAndNeverUsesAnotherWindow() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let first = delegate.createAndShowMainWindow()
        let second = delegate.createAndShowMainWindow()
        first.window?.setFrameAutosaveName("")
        second.window?.setFrameAutosaveName("")
        defer { first.close(); second.close() }
        let route = try XCTUnwrap(delegate.currentOperationRouteContext(for: first))
        let validate = WorkflowOperationsWindowController.captureReplayOrigin(routeContext: route, appDelegate: delegate)
        XCTAssertNoThrow(try validate())
        _ = first.projectSession.beginProjectOpen()
        XCTAssertThrowsError(try validate())
        let missing = WorkflowOperationsWindowController.captureReplayOrigin(
            routeContext: OperationRouteContext(projectURL: nil, windowStateScopeID: UUID()), appDelegate: delegate)
        XCTAssertThrowsError(try missing())
    }

    func testConfiguredRepeatUsesTypedExecutionAndRetainsOutputRoute() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        let center = OperationCenter()
        let delegate = makeAppDelegateWithTemporaryState()
        let owner = delegate.createAndShowMainWindow()
        owner.window?.setFrameAutosaveName("")
        defer { owner.close() }
        let route = try XCTUnwrap(delegate.currentOperationRouteContext(for: owner))
        let runner = ControllerReplayCLI(identity: fixture.configuration.identity)
        let controller = WorkflowOperationsWindowController(projectURL: nil, routeContext: route, selectedReadURLs: [],
            sidebarInputSelection: nil, initialToolID: nil,
            serviceFactory: { WorkflowOperationExecutionService(operationCenter: center, processRunner: runner,
                localWorkflowRuntimeResolver: { _ in runtime }) }, providedState: fixture.state,
            persistWindowFrame: false, appDelegate: delegate)
        defer { controller.close() }
        try await controller.choosePreviousRun { fixture.runBundle }
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        guard fixture.state.isRunEnabled else { return XCTFail("Not ready after explicit check: " + fixture.state.readinessText) }
        let request = try fixture.state.makeLaunchRequest()
        guard case .workflowPackage(let local, _) = request else { return XCTFail("Expected typed request") }
        runner.request = local
        var deliveredRoute: OperationRouteContext?
        center.onBundleReadyWithContext = { _, route in deliveredRoute = route }
        let outputs: [URL]
        do { outputs = try await controller.executeReplay(request) }
        catch { return XCTFail("Controller execute: " + String(reflecting: error)) }
        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertNotNil(fixture.state.replayConfiguration,
            "Accepted launch hides the configuration without invalidating the owning replay session")
        XCTAssertEqual(deliveredRoute, route)
        XCTAssertEqual(center.items.first?.routeContext, route)
        XCTAssertEqual(center.items.first?.state, .completed)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertNotEqual(outputs.first?.path, fixture.runBundle.path)
        let output = try XCTUnwrap(outputs.first)
        let recorded = try LocalWorkflowReplayPreflight.load(from: output).request
        XCTAssertEqual(recorded.cliArguments(bundlePath: output), local.cliArguments(bundlePath: output))
        XCTAssertEqual(recorded.params, local.params)
        XCTAssertEqual(recorded.engine, local.engine)
        XCTAssertEqual(try String(contentsOf: fixture.runBundle.appendingPathComponent("sentinel.txt"), encoding: .utf8), "original attempt")
    }

    func testTwoRunsFromReusedControllerOwnSeparateCancellationTargets() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        let center = OperationCenter()
        let delegate = makeAppDelegateWithTemporaryState()
        let owner = delegate.createAndShowMainWindow()
        owner.window?.setFrameAutosaveName("")
        defer { owner.close() }
        let route = try XCTUnwrap(delegate.currentOperationRouteContext(for: owner))
        let firstStarted = XCTestExpectation(description: "First attempt entered")
        let secondStarted = XCTestExpectation(description: "Second attempt entered")
        let firstCancelled = XCTestExpectation(description: "First worker cancel signal")
        let first = ControllerReplayCLI(identity: fixture.configuration.identity, suspended: true,
            onLaunch: { firstStarted.fulfill() }, onCancel: { firstCancelled.fulfill() })
        let second = ControllerReplayCLI(identity: fixture.configuration.identity, suspended: true,
            onLaunch: { secondStarted.fulfill() })
        var created = 0
        let controller = WorkflowOperationsWindowController(projectURL: fixture.root, routeContext: route, selectedReadURLs: [],
            sidebarInputSelection: nil, initialToolID: nil, serviceFactory: {
                let runner = created == 0 ? first : second
                created += 1
                return WorkflowOperationExecutionService(operationCenter: center, processRunner: runner,
                    localWorkflowRuntimeResolver: { _ in runtime })
            }, providedState: fixture.state, persistWindowFrame: false, appDelegate: delegate)
        defer { controller.close() }
        try await controller.reopenPreviousRun(at: fixture.runBundle)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        guard fixture.state.isRunEnabled else { return XCTFail("First check: " + fixture.state.readinessText) }
        let firstRequest = try fixture.state.makeLaunchRequest()
        guard case .workflowPackage(let firstLocal, _) = firstRequest else { return XCTFail("Expected local request") }
        first.request = firstLocal
        let firstTask = Task { try await controller.executeReplay(firstRequest) }
        await fulfillment(of: [firstStarted], timeout: 5)
        let firstID = try XCTUnwrap(center.activeLockHolder(for: firstLocal.outputDirectory)?.id)
        try await controller.reopenPreviousRun(at: fixture.runBundle)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        guard fixture.state.isRunEnabled else { first.finish(); _ = try? await firstTask.value; return XCTFail("Second check: " + fixture.state.readinessText) }
        let secondRequest = try fixture.state.makeLaunchRequest()
        guard case .workflowPackage(let secondLocal, _) = secondRequest else { return XCTFail("Expected local request") }
        second.request = secondLocal
        let secondTask = Task { try await controller.executeReplay(secondRequest) }
        await fulfillment(of: [secondStarted], timeout: 5)
        let secondID = try XCTUnwrap(center.activeLockHolder(for: secondLocal.outputDirectory)?.id)
        XCTAssertEqual(created, 2)
        XCTAssertNotEqual(firstID, secondID)
        center.cancel(id: firstID)
        await fulfillment(of: [firstCancelled], timeout: 5)
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.cancelCount, 0)
        XCTAssertEqual(center.items.first(where: { $0.id == secondID })?.state, .running)
        first.finish()
        do { _ = try await firstTask.value; XCTFail("Expected cancelled first attempt") } catch {}
        XCTAssertEqual(center.items.first(where: { $0.id == firstID })?.state, .cancelled)
        XCTAssertFalse(center.canStartOperation(on: secondLocal.outputDirectory))
        second.finish()
        do { _ = try await secondTask.value; XCTFail("Expected fake drain error") } catch {}
        XCTAssertTrue(center.canStartOperation(on: secondLocal.outputDirectory))
    }

    func testOriginChangedDuringFinalWorkerValidationPreventsRegistration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        let center = OperationCenter()
        let delegate = makeAppDelegateWithTemporaryState()
        let owner = delegate.createAndShowMainWindow()
        owner.window?.setFrameAutosaveName("")
        defer { owner.close() }
        let route = try XCTUnwrap(delegate.currentOperationRouteContext(for: owner))
        let runner = ControllerReplayCLI(identity: fixture.configuration.identity)
        let entered = XCTestExpectation(description: "Final preflight worker entered")
        let release = DispatchSemaphore(value: 0)
        let controller = WorkflowOperationsWindowController(projectURL: nil, routeContext: route, selectedReadURLs: [],
            sidebarInputSelection: nil, initialToolID: nil, serviceFactory: {
                WorkflowOperationExecutionService(operationCenter: center, processRunner: runner,
                    localWorkflowRuntimeResolver: { _ in entered.fulfill(); release.wait(); return runtime })
            }, providedState: fixture.state, persistWindowFrame: false, appDelegate: delegate)
        defer { controller.close() }
        try await controller.reopenPreviousRun(at: fixture.runBundle)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        guard fixture.state.isRunEnabled else { return XCTFail("Not ready after explicit check: " + fixture.state.readinessText) }
        let request = try fixture.state.makeLaunchRequest()
        let task = Task { try await controller.executeReplay(request) }
        await fulfillment(of: [entered], timeout: 5)
        _ = owner.projectSession.beginProjectOpen()
        release.signal()
        do { _ = try await task.value; XCTFail("Expected captured origin refusal") } catch {}
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertTrue(center.items.isEmpty)
    }

    func testNativeConfigurationWindowCloseDuringValidationPreventsRegistration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try makeRuntime(in: fixture.root)
        let center = OperationCenter()
        let delegate = makeAppDelegateWithTemporaryState()
        let owner = delegate.createAndShowMainWindow()
        owner.window?.setFrameAutosaveName("")
        defer { owner.close() }
        let route = try XCTUnwrap(delegate.currentOperationRouteContext(for: owner))
        let runner = ControllerReplayCLI(identity: fixture.configuration.identity)
        let entered = XCTestExpectation(description: "Final preflight worker entered")
        let release = DispatchSemaphore(value: 0)
        let controller = WorkflowOperationsWindowController(projectURL: nil, routeContext: route, selectedReadURLs: [],
            sidebarInputSelection: nil, initialToolID: nil, serviceFactory: {
                WorkflowOperationExecutionService(operationCenter: center, processRunner: runner,
                    localWorkflowRuntimeResolver: { _ in entered.fulfill(); release.wait(); return runtime })
            }, providedState: fixture.state, persistWindowFrame: false, appDelegate: delegate)
        defer { controller.close() }
        try await controller.reopenPreviousRun(at: fixture.runBundle)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        guard fixture.state.isRunEnabled else { return XCTFail("Not ready after explicit check: " + fixture.state.readinessText) }
        let request = try fixture.state.makeLaunchRequest()
        let task = Task { try await controller.executeReplay(request) }
        await fulfillment(of: [entered], timeout: 5)
        controller.window?.close()
        release.signal()
        do { _ = try await task.value; XCTFail("Expected captured origin refusal") } catch {}
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertTrue(center.items.isEmpty)
    }

    func testReadOnlyOriginAllowsInspectionButRefusesRegistration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectURL = fixture.root.appendingPathComponent("ReadOnly.lungfish")
        _ = try ProjectFile.create(at: projectURL, name: "Local fixture")
        let session = ProjectSession()
        _ = try session.openProject(at: projectURL, access: .readOnly)
        let delegate = makeAppDelegateWithTemporaryState()
        let owner = delegate.createAndShowMainWindow(projectSession: session)
        owner.window?.setFrameAutosaveName("")
        defer { owner.close() }
        let route = try XCTUnwrap(delegate.currentOperationRouteContext(for: owner))
        let runtime = try makeRuntime(in: fixture.root)
        let center = OperationCenter()
        let runner = ControllerReplayCLI(identity: fixture.configuration.identity)
        let controller = WorkflowOperationsWindowController(projectURL: projectURL, routeContext: route, selectedReadURLs: [],
            sidebarInputSelection: nil, initialToolID: nil, serviceFactory: {
                WorkflowOperationExecutionService(operationCenter: center, processRunner: runner,
                    localWorkflowRuntimeResolver: { _ in runtime })
            }, providedState: fixture.state, persistWindowFrame: false, appDelegate: delegate)
        defer { controller.close() }
        try await controller.reopenPreviousRun(at: fixture.runBundle)
        XCTAssertEqual(fixture.state.replaySourceBundleURL?.path, fixture.runBundle.path)
        await fixture.state.checkReplayConfiguration(runtimeResolver: { _ in runtime })
        guard fixture.state.isRunEnabled else { return XCTFail("Read-only inspection check: " + fixture.state.readinessText) }
        let request = try fixture.state.makeLaunchRequest()
        if case .workflowPackage(let local, _) = request { runner.request = local }
        do { _ = try await controller.executeReplay(request); XCTFail("Expected read-only origin refusal") }
        catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("read-only"), String(reflecting: error)) }
        XCTAssertTrue(center.items.isEmpty)
        XCTAssertEqual(runner.launchCount, 0)
    }

    func testOperationsReplayCandidateUsesTerminalRunTargetWithoutParsingCapturedShell() {
        let center = OperationCenter()
        let source = URL(fileURLWithPath: "/tmp/invented-history.lungfishrun")
        let id = center.start(title: "Local run", detail: "Fixture", operationType: .workflow,
            targetBundleURL: source, cliCommand: "never parse this shell")
        XCTAssertNil(WorkflowOperationsWindowController.replaySourceBundleURL(for: center.items[0]))
        center.fail(id: id, detail: "Failed fixture", errorMessage: "Fixture", errorDetail: "Fixture")
        XCTAssertEqual(WorkflowOperationsWindowController.replaySourceBundleURL(for: center.items[0]), source)
    }

    func testUnscopedHistoryAllowsInspectionButCannotRegisterAgainstALaterWindow() throws {
        let inspect = WorkflowOperationsWindowController.captureReplayOrigin(routeContext: nil, appDelegate: nil)
        XCTAssertNoThrow(try inspect())
        let register = WorkflowOperationsWindowController.captureReplayOrigin(routeContext: nil, appDelegate: nil, requireWritable: true)
        XCTAssertThrowsError(try register()) { error in
            XCTAssertTrue(error.localizedDescription.contains("intended project window"))
        }
    }

    private func makeRuntime(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("fake-runtime")
        try "never executed".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func makeController(_ fixture: Fixture) -> WorkflowOperationsWindowController {
        _ = NSApplication.shared
        return WorkflowOperationsWindowController(projectURL: fixture.root, routeContext: nil, selectedReadURLs: [],
            sidebarInputSelection: nil, initialToolID: nil, providedState: fixture.state, persistWindowFrame: false)
    }

    private struct Fixture {
        let root: URL
        let runBundle: URL
        let state: WorkflowOperationDialogState
        let configuration: LocalWorkflowReplayConfiguration
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
        return Fixture(root: root, runBundle: runBundle, state: state, configuration: configuration)
    }
}

@MainActor
private final class ControllerReplayCLI: LocalWorkflowCLIProcessRunning {
    let identity: LocalWorkflowReplayIdentity
    let suspended: Bool
    let onLaunch: () -> Void
    let onCancel: () -> Void
    var request: LocalWorkflowRunRequest?
    private(set) var launchCount = 0
    private(set) var cancelCount = 0
    private var continuation: CheckedContinuation<LocalWorkflowCLIProcessResult, Error>?
    init(identity: LocalWorkflowReplayIdentity, suspended: Bool = false,
         onLaunch: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
        self.identity = identity; self.suspended = suspended; self.onLaunch = onLaunch; self.onCancel = onCancel
    }
    func runLungfishCLI(arguments: [String], workingDirectory: URL,
                       outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) async throws -> LocalWorkflowCLIProcessResult {
        launchCount += 1
        let request = try XCTUnwrap(request)
        let index = try XCTUnwrap(arguments.firstIndex(of: "--bundle-path"))
        let bundle = URL(fileURLWithPath: arguments[index + 1])
        XCTAssertEqual(arguments, request.cliArguments(bundlePath: bundle))
        if suspended {
            return try await withCheckedThrowingContinuation { continuation in self.continuation = continuation; onLaunch() }
        }
        onLaunch()
        // The real CLI reconstructs initially absent expected outputs from argv paths,
        // which have no Foundation directory hint even when the GUI URL does.
        let reconstructed = LocalWorkflowRunRequest(workflowURL: request.workflowURL, engine: request.engine,
            inputURLs: request.inputURLs, outputDirectory: request.outputDirectory,
            expectedOutputURLs: request.expectedOutputURLs.map { URL(fileURLWithPath: $0.path, isDirectory: false) },
            params: request.params, resume: request.resume, workDirectory: request.workDirectory,
            cpus: request.cpus, memory: request.memory, replaySourceBundleURL: request.replaySourceBundleURL)
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        for output in request.expectedOutputURLs {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try "harmless local fixture output".write(to: output.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        }
        try LocalWorkflowRunBundleStore.write(reconstructed.manifest(replayIdentity: identity, executionStatus: .completed, exitCode: 0), to: bundle)
        let step = StepExecution(toolName: "lungfish-cli workflow run", toolVersion: "fixture", command: ["lungfish-cli"] + arguments,
            inputs: [], outputs: [FileRecord(path: bundle.path, role: .output),
                ProvenanceRecorder.fileRecord(url: bundle.appendingPathComponent("manifest.json"), role: .output)],
            exitCode: 0, wallTime: 1, endTime: Date())
        let run = WorkflowRun(name: "Local repeat fixture", endTime: Date(), status: .completed, steps: [step])
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: bundle)
        return LocalWorkflowCLIProcessResult(exitCode: 0, standardOutput: "local fixture", standardError: "")
    }
    func cancel() { cancelCount += 1; onCancel() }
    func finish() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
