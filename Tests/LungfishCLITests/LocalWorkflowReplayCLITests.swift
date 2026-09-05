import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishCLI

final class LocalWorkflowReplayCLITests: XCTestCase {
    func testRacedForeignRunBundleIsNotMergedAndPreventsEngineLaunch() async throws {
        try await assertReservationRace(atRunBundle: true)
    }

    func testRacedForeignOutputKeepsFailedHistoryWithoutClaimingForeignOutputs() async throws {
        try await assertReservationRace(atRunBundle: false)
    }

    private func assertReservationRace(atRunBundle: Bool) async throws {
        let fixture = try await makeReplayFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = fixture.repeatRequest()
        let bundle = fixture.root.appendingPathComponent("raced.lungfishrun")
        let raced = atRunBundle ? bundle : request.outputDirectory
        let sentinel = raced.appendingPathComponent("foreign.txt")
        let originalReserver = RunSubcommand.localWorkflowDirectoryReserver
        RunSubcommand.localWorkflowDirectoryReserver = { url in
            if url.path == raced.path {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try "foreign writer bytes".write(to: sentinel, atomically: true, encoding: .utf8)
            }
            try LocalWorkflowReplayReservation.reserveDirectory(at: url)
        }
        defer { RunSubcommand.localWorkflowDirectoryReserver = originalReserver }
        let runner = CaptureRunner(exitCode: 0, runtimeURL: fixture.runtime) {
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            try "must not launch".write(to: request.expectedOutputURLs[0], atomically: true, encoding: .utf8)
        }
        do { try await run(request, bundle: bundle, runner: runner); XCTFail("Expected exclusive reservation refusal") } catch {}
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "foreign writer bytes")
        if atRunBundle {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.path), ["foreign.txt"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
        } else {
            let history = try LocalWorkflowRunBundleStore.read(from: bundle)
            XCTAssertEqual(history.executionStatus, .failed)
            let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle))
            XCTAssertFalse(provenance.outputs.contains { URL(fileURLWithPath: $0.path).pathComponents.starts(with: raced.pathComponents) })
            XCTAssertEqual(try LocalWorkflowReplayPreflight.load(from: bundle).request, request)
        }
    }

    func testReturnedRuntimeEvidenceIsRetainedInCanonicalExecutionProvenance() async throws {
        let fixture = try await makeReplayFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = fixture.repeatRequest()
        let bundle = fixture.root.appendingPathComponent("runtime.lungfishrun")
        let evidence = LocalWorkflowRuntimeEvidence(executable: ProvenanceRecorder.fileRecord(url: fixture.runtime, role: .input),
            environment: ["PATH": fixture.root.path, "HOME": fixture.root.path])
        let runner = CaptureRunner(exitCode: 0, runtimeURL: fixture.runtime, runtimeEvidence: evidence) {
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            try "local output".write(to: request.expectedOutputURLs[0], atomically: true, encoding: .utf8)
        }
        try await run(request, bundle: bundle, runner: runner)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle))
        XCTAssertEqual(provenance.options.resolvedDefaults["runtimeExecutablePath"], .file(fixture.runtime))
        XCTAssertEqual(provenance.options.resolvedDefaults["runtimeExecutableSHA256"], .string(try XCTUnwrap(evidence.executable.sha256)))
        XCTAssertEqual(provenance.options.resolvedDefaults["runtimeEnvironment"], .dictionary(evidence.environment.mapValues(ParameterValue.string)))
    }

    func testTypedRepeatLaunchCreatesFreshHistoryAndPreservesOriginalBytes() async throws {
        let fixture = try await makeReplayFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalManifest = try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json"))
        let request = fixture.repeatRequest()
        let bundle = fixture.root.appendingPathComponent("second.lungfishrun")
        let runner = CaptureRunner(exitCode: 0, runtimeURL: fixture.runtime) {
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            try "second output".write(to: request.expectedOutputURLs[0], atomically: true, encoding: .utf8)
        }
        try await run(request, bundle: bundle, runner: runner)
        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json")), originalManifest)
        XCTAssertEqual(try String(contentsOf: fixture.original.expectedOutputURLs[0], encoding: .utf8), "original output")
        let history = try LocalWorkflowRunBundleStore.read(from: bundle)
        XCTAssertEqual(history.executionStatus, .completed)
        XCTAssertEqual(history.request?.replaySourceBundleURL?.path, fixture.source.path)
        XCTAssertEqual(history.replayIdentity, try LocalWorkflowRunBundleStore.read(from: fixture.source).replayIdentity)
        XCTAssertEqual(try LocalWorkflowReplayPreflight.load(from: bundle).request, request)
    }

    func testTypedRepeatRejectsChangedMissingOrUnsafeResourcesBeforeFakeLaunch() async throws {
        for issue in ["input missing", "input changed", "runtime", "destination occupied", "destination overlap", "settings", "history", "run bundle"] {
            let fixture = try await makeReplayFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var request = fixture.repeatRequest()
            var bundle = fixture.root.appendingPathComponent("second.lungfishrun")
            var runtime: URL? = fixture.runtime
            switch issue {
            case "input missing": try FileManager.default.removeItem(at: fixture.original.inputURLs[0])
            case "input changed": try "changed input".write(to: fixture.original.inputURLs[0], atomically: true, encoding: .utf8)
            case "runtime": runtime = nil
            case "destination occupied": try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            case "destination overlap": request = fixture.repeatRequest(output: fixture.original.outputDirectory.appendingPathComponent("nested"))
            case "settings": request = fixture.repeatRequest(cpus: 8)
            case "history":
                let manifest = fixture.source.appendingPathComponent("manifest.json")
                var bytes = try Data(contentsOf: manifest); bytes.append(0x20); try bytes.write(to: manifest)
            case "run bundle": bundle = fixture.source
            default: XCTFail("Unknown fixture case")
            }
            let runner = CaptureRunner(exitCode: 0, runtimeURL: runtime) {}
            do {
                try await run(request, bundle: bundle, runner: runner)
                XCTFail("Expected repair for \(issue)")
            } catch {
                let term = issue.components(separatedBy: " ").first!
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(term), "\(issue): \(error)")
            }
            XCTAssertEqual(runner.launchCount, 0, issue)
            if bundle != fixture.source { XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), issue) }
            XCTAssertEqual(try String(contentsOf: fixture.original.expectedOutputURLs[0], encoding: .utf8), "original output")
        }
    }

    func testThrownRunnerRetainsFailedHistoryWithOriginalIdentityAndErrorProvenance() async throws {
        try await assertThrownHistory(cancelled: false)
    }

    func testCancelledRunnerRetainsCancelledHistoryWithOriginalIdentityAndErrorProvenance() async throws {
        try await assertThrownHistory(cancelled: true)
    }

    private func assertThrownHistory(cancelled: Bool) async throws {
        let fixture = try await makeReplayFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Ordinary local execution also needs a terminal durable record on a thrown launch.
        let request = LocalWorkflowRunRequest(workflowURL: fixture.original.workflowURL, engine: .nextflow,
            inputURLs: fixture.original.inputURLs, outputDirectory: fixture.root.appendingPathComponent("thrown-results"),
            expectedOutputURLs: [fixture.root.appendingPathComponent("thrown-results/result.txt")], cpus: 3)
        let bundle = fixture.root.appendingPathComponent("thrown.lungfishrun")
        let originalIdentity = try LocalWorkflowReplayIdentity.capture(for: request)
        let runner = CaptureRunner(exitCode: 0, runtimeURL: fixture.runtime) {
            try "changed during launch".write(to: request.inputURLs[0], atomically: true, encoding: .utf8)
            if cancelled { throw CancellationError() }
            throw NSError(domain: "invented-launch", code: 17, userInfo: [NSLocalizedDescriptionKey: "invented launch failure"])
        }
        do { try await run(request, bundle: bundle, runner: runner); XCTFail("Expected a thrown runner") } catch {}
        XCTAssertEqual(runner.launchCount, 1)
        let history = try LocalWorkflowRunBundleStore.read(from: bundle)
        XCTAssertEqual(history.executionStatus, cancelled ? .cancelled : .failed)
        XCTAssertNotNil(history.completedAt)
        XCTAssertEqual(history.replayIdentity, originalIdentity)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle))
        XCTAssertNotNil(provenance.steps.first?.completedAt)
        XCTAssertFalse(provenance.steps.compactMap(\.stderr).joined().isEmpty)
        XCTAssertEqual(try LocalWorkflowReplayPreflight.load(from: bundle).identity, originalIdentity)
    }

    func testCompletedPackageRunRetainsIdentityCapturedBeforeFakeExecution() async throws {
        try await assertCapturedIdentity(exitCode: 0)
    }

    func testFailedPackageRunRetainsIdentityCapturedBeforeFakeExecution() async throws {
        try await assertCapturedIdentity(exitCode: 9)
    }

    func testTypedSourceRunIsPassedAsOneCLIArgumentWithoutParsingCommandText() throws {
        let request = LocalWorkflowRunRequest(workflowURL: URL(fileURLWithPath: "/fixture/main.nf"),
            engine: .nextflow, outputDirectory: URL(fileURLWithPath: "/fixture/new results"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let source = URL(fileURLWithPath: "/fixture/old 'literal' attempt.lungfishrun")
        object["replaySourceBundleURL"] = source.absoluteString
        let decoded = try JSONDecoder().decode(LocalWorkflowRunRequest.self, from: JSONSerialization.data(withJSONObject: object))
        let arguments = decoded.cliArguments(bundlePath: URL(fileURLWithPath: "/fixture/new.lungfishrun"))
        let index = try XCTUnwrap(arguments.firstIndex(of: "--repeat-from"))
        XCTAssertEqual(arguments[index + 1], source.path)
        XCTAssertEqual(arguments.filter { $0 == source.path }.count, 1)
    }

    private func assertCapturedIdentity(exitCode: Int32) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-cli-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let workflow = package.appendingPathComponent("main.nf")
        try "// invented fixture; never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let packageManifest = WorkflowPackageManifest(id: "invented-cli-repeat", name: "Fixture", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "source", name: "Source", bundleTypes: [.lungfishref])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "result.txt")])
        try JSONEncoder().encode(packageManifest).write(to: package.appendingPathComponent("manifest.json"))
        let input = root.appendingPathComponent("input.txt")
        try "original local input".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("results")
        let expectedOutput = output.appendingPathComponent("result.txt")
        let request = LocalWorkflowRunRequest(workflowURL: workflow, engine: .nextflow, inputURLs: [input],
            outputDirectory: output, expectedOutputURLs: [expectedOutput], params: ["label": "retained"], cpus: 3)
        let originalIdentity = try LocalWorkflowReplayIdentity.capture(for: request)
        let originalInput = ProvenanceRecorder.fileRecord(url: input, role: .input)
        let runner = CaptureRunner(exitCode: exitCode) {
            try "changed during fake execution".write(to: input, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try "invented output".write(to: expectedOutput, atomically: true, encoding: .utf8)
        }
        let originalRunner = RunSubcommand.localWorkflowProcessRunner
        RunSubcommand.localWorkflowProcessRunner = runner
        defer { RunSubcommand.localWorkflowProcessRunner = originalRunner }
        let bundle = root.appendingPathComponent("attempt.lungfishrun")
        let command = try RunSubcommand.parse(Array(request.cliArguments(bundlePath: bundle).dropFirst(2)) + ["--quiet"])
        do {
            try await command.run()
            XCTAssertEqual(exitCode, 0)
        } catch {
            guard exitCode != 0 else { throw error }
        }
        XCTAssertEqual(runner.launchCount, 1)
        let manifest = try LocalWorkflowRunBundleStore.read(from: bundle)
        XCTAssertEqual(manifest.executionStatus, exitCode == 0 ? .completed : .failed)
        XCTAssertEqual(try XCTUnwrap(manifest.replayIdentity), originalIdentity,
                       "Completion/failure must retain the original source snapshot, not recapture changed bytes")
        XCTAssertEqual(manifest.inputBindings.first?.sha256, originalInput.sha256)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle))
        XCTAssertTrue(provenance.steps.flatMap(\.inputs).contains { $0.path == input.path && $0.checksumSHA256 == originalInput.sha256 })
    }

    private func run(_ request: LocalWorkflowRunRequest, bundle: URL, runner: CaptureRunner) async throws {
        let originalRunner = RunSubcommand.localWorkflowProcessRunner
        RunSubcommand.localWorkflowProcessRunner = runner
        defer { RunSubcommand.localWorkflowProcessRunner = originalRunner }
        let command = try RunSubcommand.parse(Array(request.cliArguments(bundlePath: bundle).dropFirst(2)) + ["--quiet"])
        try await command.run()
    }

    private struct ReplayFixture {
        let root: URL
        let source: URL
        let runtime: URL
        let original: LocalWorkflowRunRequest

        func repeatRequest(output: URL? = nil, cpus: Int = 3) -> LocalWorkflowRunRequest {
            let output = output ?? root.appendingPathComponent("second-results")
            return LocalWorkflowRunRequest(workflowURL: original.workflowURL, engine: .nextflow, inputURLs: original.inputURLs,
                outputDirectory: output, expectedOutputURLs: [output.appendingPathComponent("result.txt")],
                params: original.params, cpus: cpus, replaySourceBundleURL: source)
        }
    }

    private func makeReplayFixture() async throws -> ReplayFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-cli-launch-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let workflow = package.appendingPathComponent("main.nf")
        try "// invented fixture; never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(id: "invented-repeat-launch", name: "Fixture", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "source", name: "Source", bundleTypes: [.lungfishref])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "result.txt")])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let input = root.appendingPathComponent("input.txt")
        try "original local input".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("original-results")
        let request = LocalWorkflowRunRequest(workflowURL: workflow, engine: .nextflow, inputURLs: [input],
            outputDirectory: output, expectedOutputURLs: [output.appendingPathComponent("result.txt")], params: ["label": "retained"], cpus: 3)
        let runtime = root.appendingPathComponent("fake-runtime")
        try "never launched".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let runner = CaptureRunner(exitCode: 0, runtimeURL: runtime) {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try "original output".write(to: request.expectedOutputURLs[0], atomically: true, encoding: .utf8)
        }
        let source = root.appendingPathComponent("original.lungfishrun")
        try await run(request, bundle: source, runner: runner)
        return ReplayFixture(root: root, source: source, runtime: runtime, original: request)
    }
}

private final class CaptureRunner: LocalWorkflowProcessRunning, @unchecked Sendable {
    let exitCode: Int32
    let operation: () throws -> Void
    let runtimeURL: URL?
    let runtimeEvidence: LocalWorkflowRuntimeEvidence?
    private(set) var launchCount = 0

    init(exitCode: Int32, runtimeURL: URL? = nil, runtimeEvidence: LocalWorkflowRuntimeEvidence? = nil,
         operation: @escaping () throws -> Void) {
        self.exitCode = exitCode
        self.operation = operation
        self.runtimeURL = runtimeURL
        self.runtimeEvidence = runtimeEvidence
    }

    func runtimeExecutableURL(named executableName: String) -> URL? { runtimeURL }

    func runWorkflow(executableName: String, arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowProcessResult {
        launchCount += 1
        try operation()
        return LocalWorkflowProcessResult(exitCode: exitCode, standardOutput: "fake local run", standardError: "", runtimeEvidence: runtimeEvidence)
    }
}
