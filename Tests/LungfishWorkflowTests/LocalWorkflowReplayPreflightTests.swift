import Foundation
import XCTest
@testable import LungfishWorkflow

/// Harmless local text fixtures only; executable files are never launched.
final class LocalWorkflowReplayPreflightTests: XCTestCase {
    func testRelocatedIdenticalPackageCannotContainTheFreshDestination() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relocated = fixture.root.appendingPathComponent("Relocated.lungfishflowpkg")
        try FileManager.default.copyItem(at: fixture.configuration.identity.packageURL, to: relocated)
        let request = fixture.request(output: relocated.appendingPathComponent("new-results"),
                                      workflow: relocated.appendingPathComponent("main.nf"))
        try fixture.configuration.identity.validateCurrentInputs(for: request)
        assertRepair("destination") { try validate(fixture, request: request) }
    }

    func testAnExistingDanglingDestinationLinkIsNotAFreshDestination() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let link = fixture.root.appendingPathComponent("destination-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.request().outputDirectory)
        assertRepair("destination") { try validate(fixture, request: fixture.request(output: link)) }
    }

    func testBoundManifestLoadsWithoutRequiringLiveInputsAndRejectsChangedHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.original.inputURLs[0])
        let loaded = try LocalWorkflowReplayPreflight.load(from: fixture.bundle)
        XCTAssertEqual(loaded, fixture.configuration, "Missing inputs must remain repairable in configuration")
        let manifest = fixture.bundle.appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifest)
        bytes.append(contentsOf: [0x20, 0x0A])
        try bytes.write(to: manifest)
        assertRepair("history") { _ = try LocalWorkflowReplayPreflight.load(from: fixture.bundle) }
    }

    func testMissingCanonicalBindingCannotAuthorizeTypedHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        assertRepair("provenance") { _ = try LocalWorkflowReplayPreflight.load(from: fixture.bundle) }
    }

    func testValidFreshAttemptLeavesOldOutputAndHistoryUntouched() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try Data(contentsOf: fixture.bundle.appendingPathComponent("manifest.json"))
        try validate(fixture, request: fixture.request())
        XCTAssertEqual(try Data(contentsOf: fixture.bundle.appendingPathComponent("manifest.json")), before)
        XCTAssertEqual(try String(contentsOf: fixture.original.outputDirectory.appendingPathComponent("sentinel.txt"), encoding: .utf8), "original output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.request().outputDirectory.path))
    }

    func testMissingRuntimeAndChangedInputRequireRepairBeforeLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        assertRepair("runtime") {
            try LocalWorkflowReplayPreflight.validate(request: fixture.request(), configuration: fixture.configuration,
                sourceBundleURL: fixture.bundle, runtimeURL: nil)
        }
        try "different input".write(to: fixture.original.inputURLs[0], atomically: true, encoding: .utf8)
        assertRepair("input") { try validate(fixture, request: fixture.request()) }
    }

    func testOccupiedOverlappingAndEscapingDestinationsAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for output in [fixture.original.outputDirectory,
                       fixture.original.outputDirectory.appendingPathComponent("nested"),
                       fixture.bundle.appendingPathComponent("nested"),
                       fixture.configuration.identity.packageURL.appendingPathComponent("nested")] {
            assertRepair("destination") { try validate(fixture, request: fixture.request(output: output)) }
        }
        let occupied = fixture.request().outputDirectory
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        assertRepair("destination") { try validate(fixture, request: fixture.request()) }
        try FileManager.default.removeItem(at: occupied)
        assertRepair("output") {
            try validate(fixture, request: fixture.request(expected: [fixture.root.appendingPathComponent("escape.txt")]))
        }
    }

    func testChangedSettingsAndUnrelatedSourceBindingCannotStartRepeat() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        assertRepair("settings") { try validate(fixture, request: fixture.request(cpus: 9)) }
        let other = try makeFixture()
        defer { try? FileManager.default.removeItem(at: other.root) }
        assertRepair("source") {
            try LocalWorkflowReplayPreflight.validate(request: fixture.request(), configuration: fixture.configuration,
                sourceBundleURL: other.bundle, runtimeURL: fixture.runtime)
        }
    }

    private func validate(_ fixture: Fixture, request: LocalWorkflowRunRequest) throws {
        try LocalWorkflowReplayPreflight.validate(request: request, configuration: fixture.configuration,
            sourceBundleURL: fixture.bundle, runtimeURL: fixture.runtime)
    }

    private func assertRepair(_ term: String, file: StaticString = #filePath, line: UInt = #line,
                              operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(term),
                "Expected a specific \(term) repair, received: \(error)", file: file, line: line)
        }
    }

    private struct Fixture {
        let root: URL
        let bundle: URL
        let runtime: URL
        let original: LocalWorkflowRunRequest
        let configuration: LocalWorkflowReplayConfiguration

        func request(output: URL? = nil, expected: [URL]? = nil, cpus: Int = 3, workflow: URL? = nil) -> LocalWorkflowRunRequest {
            let output = output ?? root.appendingPathComponent("new-results")
            return LocalWorkflowRunRequest(workflowURL: workflow ?? original.workflowURL, engine: original.engine,
                inputURLs: original.inputURLs, outputDirectory: output,
                expectedOutputURLs: expected ?? [output.appendingPathComponent("result.txt")],
                params: ["label": "retained literal", "outdir": output.path], cpus: cpus)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-preflight-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let workflow = package.appendingPathComponent("main.nf")
        try "// never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(id: "invented-preflight", name: "Fixture", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "source", name: "Source", bundleTypes: [.lungfishref])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "result.txt")])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let input = root.appendingPathComponent("input.txt")
        try "original input".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("original-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "original output".write(to: output.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
        let request = LocalWorkflowRunRequest(workflowURL: workflow, engine: .nextflow, inputURLs: [input],
            outputDirectory: output, expectedOutputURLs: [output.appendingPathComponent("result.txt")],
            params: ["label": "retained literal", "outdir": output.path], cpus: 3)
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        let history = request.manifest(replayIdentity: identity, executionStatus: .completed, exitCode: 0)
        let bundle = root.appendingPathComponent("original.lungfishrun")
        try LocalWorkflowRunBundleStore.write(history, to: bundle)
        let step = StepExecution(toolName: "lungfish-cli workflow run", toolVersion: "test",
            command: ["lungfish-cli"] + request.cliArguments(bundlePath: bundle), inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: bundle.appendingPathComponent("manifest.json"), role: .output)],
            exitCode: 0, wallTime: 1, endTime: Date())
        let run = WorkflowRun(name: "Invented local attempt", endTime: Date(), status: .completed, steps: [step])
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: bundle)
        let runtime = root.appendingPathComponent("fake-runtime")
        try "local fixture; never launched".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        return Fixture(root: root, bundle: bundle, runtime: runtime, original: request,
                       configuration: try LocalWorkflowReplayConfiguration.restored(from: history))
    }
}
