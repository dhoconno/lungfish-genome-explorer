import Foundation
import XCTest
import LungfishKit
@testable import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class LocalWorkflowReplayServiceTests: XCTestCase {
    func testCancellationKeepsBothLeasesUntilTheCLIWorkerDrains() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let center = OperationCenter()
        let started = expectation(description: "CLI worker entered")
        let cancelSignalled = expectation(description: "CLI cancel signalled")
        let runner = SuspendedReplayCLI(onLaunch: { started.fulfill() }, onCancel: { cancelSignalled.fulfill() })
        let runtime = fixture.runtime
        let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner,
            runtimeResolver: { _ in runtime })
        let task = Task { try await service.run(fixture.request, bundleRoot: fixture.historyRoot) }
        await fulfillment(of: [started], timeout: 5)
        let item = try XCTUnwrap(center.activeLockHolder(for: fixture.request.outputDirectory))
        let target = try XCTUnwrap(item.targetBundleURL)
        center.cancel(id: item.id)
        await fulfillment(of: [cancelSignalled], timeout: 5)
        XCTAssertEqual(runner.cancelCount, 1)
        XCTAssertEqual(center.items.first(where: { $0.id == item.id })?.state, .cancelling)
        XCTAssertFalse(center.canStartOperation(on: fixture.request.outputDirectory))
        XCTAssertFalse(center.canStartOperation(on: target))
        runner.finish()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(center.items.first(where: { $0.id == item.id })?.state, .cancelled)
        XCTAssertTrue(center.canStartOperation(on: fixture.request.outputDirectory))
        XCTAssertTrue(center.canStartOperation(on: target))
    }

    func testAcceptedCancellationSuppressesLateSuccessAndNonzeroResults() async throws {
        for exitCode in [Int32(0), Int32(143)] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let center = OperationCenter()
            let started = expectation(description: "CLI entered")
            let signalled = expectation(description: "Cancel delivered")
            let runner = SuspendedReplayCLI(onLaunch: { started.fulfill() }, onCancel: { signalled.fulfill() })
            let runtime = fixture.runtime
            let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner,
                runtimeResolver: { _ in runtime })
            var ready = false
            center.onBundleReadyWithContext = { _, _ in ready = true }
            let task = Task { try await service.run(fixture.request, bundleRoot: fixture.historyRoot) }
            await fulfillment(of: [started], timeout: 5)
            let item = try XCTUnwrap(center.activeLockHolder(for: fixture.request.outputDirectory))
            let bundle = try XCTUnwrap(item.targetBundleURL)
            center.cancel(id: item.id)
            await fulfillment(of: [signalled], timeout: 5)
            if exitCode == 0 { try writeBoundHistory(fixture.request, identity: fixture.identity, at: bundle) }
            runner.finish(result: LocalWorkflowCLIProcessResult(exitCode: exitCode, standardOutput: "", standardError: "fixture termination"))
            do { _ = try await task.value; XCTFail("Cancelled worker must not return output URLs") }
            catch { XCTAssertTrue(error is CancellationError, String(reflecting: error)) }
            XCTAssertEqual(center.items.first(where: { $0.id == item.id })?.state, .cancelled)
            XCTAssertFalse(ready)
            XCTAssertTrue(center.canStartOperation(on: fixture.request.outputDirectory))
        }
    }

    func testFreshRepeatKeepsCapturedRouteAndHoldsOutputLeaseThroughExecution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let center = OperationCenter()
        let route = OperationRouteContext(projectURL: fixture.root, windowStateScopeID: UUID())
        let originalBytes = try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json"))
        let runner = FakeReplayCLI(request: fixture.request, identity: fixture.identity) { bundle, workingDirectory in
            XCTAssertFalse(center.canStartOperation(on: fixture.request.outputDirectory))
            let item = try XCTUnwrap(center.activeLockHolder(for: fixture.request.outputDirectory))
            XCTAssertEqual(item.targetBundleURL?.path, bundle.path)
            XCTAssertEqual(item.routeContext, route)
            XCTAssertNotEqual(workingDirectory.path, bundle.path, "CLI launch must not pre-create its reserved run bundle")
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        }
        let runtime = fixture.runtime
        let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner,
            runtimeResolver: { _ in runtime })
        let result = try await service.run(fixture.request, bundleRoot: fixture.historyRoot, routeContext: route)
        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertEqual(result.operationItem?.routeContext, route)
        XCTAssertEqual(result.operationItem?.state, .completed)
        XCTAssertEqual(result.operationItem?.targetBundleURL?.path, result.bundleURL.path)
        XCTAssertTrue(center.canStartOperation(on: fixture.request.outputDirectory))
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json")), originalBytes)
        XCTAssertEqual(try String(contentsOf: fixture.originalOutput, encoding: .utf8), "original output")
    }

    func testAnExistingOutputLeaseRejectsRegistrationWithoutWritesOrLaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let center = OperationCenter()
        let owner = center.start(title: "Existing writer", detail: "Local fixture",
            targetBundleURL: fixture.root.appendingPathComponent("other.lungfishrun"),
            additionalLockedBundleURLs: [fixture.request.outputDirectory])
        let runner = FakeReplayCLI(request: fixture.request, identity: fixture.identity)
        let runtime = fixture.runtime
        let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner,
            runtimeResolver: { _ in runtime })
        do { _ = try await service.run(fixture.request, bundleRoot: fixture.historyRoot); XCTFail("Expected output lease refusal") }
        catch {}
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyRoot.path))
        XCTAssertEqual(center.activeLockHolder(for: fixture.request.outputDirectory)?.id, owner)
    }

    func testClosedOriginIsCheckedAfterValidationAndBeforeRegistrationOrWrites() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let center = OperationCenter()
        let runner = FakeReplayCLI(request: fixture.request, identity: fixture.identity)
        let runtime = fixture.runtime
        let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner,
            runtimeResolver: { _ in runtime })
        var checked = false
        do {
            _ = try await service.run(fixture.request, bundleRoot: fixture.historyRoot, beforeRegister: {
                checked = true
                throw LocalWorkflowReplayError.repairRequired("The originating configuration was closed or replaced.")
            })
            XCTFail("Expected stale origin refusal")
        } catch {}
        XCTAssertTrue(checked)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertTrue(center.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyRoot.path))
    }

    func testMissingRuntimeChangedInputAndExistingPrivateHistoryDirectoryRequireRepairWithoutLaunch() async throws {
        for issue in ["runtime", "input", "history"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let center = OperationCenter()
            var runtime: URL? = fixture.runtime
            if issue == "runtime" { runtime = nil }
            if issue == "input" {
                try "changed".write(to: fixture.request.inputURLs[0], atomically: true, encoding: .utf8)
            }
            let sentinel = fixture.historyRoot.appendingPathComponent("foreign.txt")
            if issue == "history" {
                try FileManager.default.createDirectory(at: fixture.historyRoot, withIntermediateDirectories: true)
                try "foreign bytes".write(to: sentinel, atomically: true, encoding: .utf8)
            }
            let selectedRuntime = runtime
            let runner = FakeReplayCLI(request: fixture.request, identity: fixture.identity)
            let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner,
                runtimeResolver: { _ in selectedRuntime })
            do { _ = try await service.run(fixture.request, bundleRoot: fixture.historyRoot); XCTFail("Expected \(issue) repair") }
            catch {}
            XCTAssertEqual(runner.launchCount, 0, issue)
            if issue == "history" {
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "foreign bytes")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyRoot.path), issue)
                XCTAssertTrue(center.items.isEmpty, issue)
            }
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let historyRoot: URL
        let runtime: URL
        let originalOutput: URL
        let request: LocalWorkflowRunRequest
        let identity: LocalWorkflowReplayIdentity
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-service-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let workflow = package.appendingPathComponent("main.nf")
        try "// local fixture; never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(id: "invented-service", name: "Fixture", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "source", name: "Source", bundleTypes: [.lungfishref])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "result.txt")])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let input = root.appendingPathComponent("input.txt")
        try "original input".write(to: input, atomically: true, encoding: .utf8)
        let originalDirectory = root.appendingPathComponent("original-results")
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        let originalOutput = originalDirectory.appendingPathComponent("result.txt")
        try "original output".write(to: originalOutput, atomically: true, encoding: .utf8)
        let original = LocalWorkflowRunRequest(workflowURL: workflow, engine: .nextflow, inputURLs: [input],
            outputDirectory: originalDirectory, expectedOutputURLs: [originalOutput], params: ["label": "retained"], cpus: 3)
        let identity = try LocalWorkflowReplayIdentity.capture(for: original)
        let source = root.appendingPathComponent("original.lungfishrun")
        try writeBoundHistory(original, identity: identity, at: source)
        let output = root.appendingPathComponent("new-results")
        let request = LocalWorkflowRunRequest(workflowURL: workflow, engine: .nextflow, inputURLs: [input],
            outputDirectory: output, expectedOutputURLs: [output.appendingPathComponent("result.txt")], params: original.params,
            cpus: 3, replaySourceBundleURL: source)
        let runtime = root.appendingPathComponent("fake-runtime")
        try "never launched".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        return Fixture(root: root, source: source, historyRoot: root.appendingPathComponent("private-attempt"),
            runtime: runtime, originalOutput: originalOutput, request: request, identity: identity)
    }
}

@MainActor
private final class FakeReplayCLI: LocalWorkflowCLIProcessRunning {
    let request: LocalWorkflowRunRequest
    let identity: LocalWorkflowReplayIdentity
    let onLaunch: (URL, URL) throws -> Void
    private(set) var launchCount = 0

    init(request: LocalWorkflowRunRequest, identity: LocalWorkflowReplayIdentity,
         onLaunch: @escaping (URL, URL) throws -> Void = { _, _ in }) {
        self.request = request
        self.identity = identity
        self.onLaunch = onLaunch
    }

    func runLungfishCLI(arguments: [String], workingDirectory: URL,
                       outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) async throws -> LocalWorkflowCLIProcessResult {
        launchCount += 1
        let index = try XCTUnwrap(arguments.firstIndex(of: "--bundle-path"))
        let bundle = URL(fileURLWithPath: arguments[index + 1])
        XCTAssertEqual(arguments, request.cliArguments(bundlePath: bundle))
        try onLaunch(bundle, workingDirectory)
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        try "new local output".write(to: request.expectedOutputURLs[0], atomically: true, encoding: .utf8)
        try writeBoundHistory(request, identity: identity, at: bundle)
        return LocalWorkflowCLIProcessResult(exitCode: 0, standardOutput: "fake local result", standardError: "")
    }
}

private func writeBoundHistory(_ request: LocalWorkflowRunRequest, identity: LocalWorkflowReplayIdentity, at bundle: URL) throws {
    try LocalWorkflowRunBundleStore.write(request.manifest(replayIdentity: identity, executionStatus: .completed,
        startedAt: Date(), completedAt: Date(), exitCode: 0), to: bundle)
    let step = StepExecution(toolName: "lungfish-cli workflow run", toolVersion: "test",
        command: ["lungfish-cli"] + request.cliArguments(bundlePath: bundle), inputs: [],
        outputs: [FileRecord(path: bundle.path, role: .output),
                  ProvenanceRecorder.fileRecord(url: bundle.appendingPathComponent("manifest.json"), role: .output)],
        exitCode: 0, wallTime: 1, endTime: Date())
    let run = WorkflowRun(name: "Invented local attempt", endTime: Date(), status: .completed, steps: [step])
    try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: bundle)
}

@MainActor
private final class SuspendedReplayCLI: LocalWorkflowCLIProcessRunning {
    let onLaunch: () -> Void
    let onCancel: () -> Void
    private var continuation: CheckedContinuation<LocalWorkflowCLIProcessResult, Error>?
    private(set) var cancelCount = 0
    init(onLaunch: @escaping () -> Void, onCancel: @escaping () -> Void) { self.onLaunch = onLaunch; self.onCancel = onCancel }
    func runLungfishCLI(arguments: [String], workingDirectory: URL,
                       outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) async throws -> LocalWorkflowCLIProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onLaunch()
        }
    }
    func cancel() { cancelCount += 1; onCancel() }
    func finish(result: LocalWorkflowCLIProcessResult? = nil) {
        if let result { continuation?.resume(returning: result) }
        else { continuation?.resume(throwing: CancellationError()) }
        continuation = nil
    }
}
