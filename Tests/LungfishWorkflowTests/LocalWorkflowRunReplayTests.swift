import Foundation
import XCTest
@testable import LungfishWorkflow

/// Durable configuration checks only; no workflow engine or shell is executed.
final class LocalWorkflowRunReplayTests: XCTestCase {
    func testCompletedManifestRetainsExactTypedRequestForConfigurationReopening() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-replay-typed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let request = LocalWorkflowRunRequest(
            workflowURL: root.appendingPathComponent("Fixture.lungfishflowpkg/main.nf"),
            engine: .nextflow,
            inputURLs: [root.appendingPathComponent("second input.txt"), root.appendingPathComponent("first input.txt")],
            outputDirectory: root.appendingPathComponent("original results"),
            expectedOutputURLs: [root.appendingPathComponent("original results/result.txt")],
            params: ["label": "literal 'quoted' value", "empty": ""],
            resume: false,
            workDirectory: root.appendingPathComponent("original work"),
            cpus: 3,
            memory: "7 GB"
        )
        let bundle = root.appendingPathComponent("original.lungfishrun")
        try LocalWorkflowRunBundleStore.write(
            request.manifest(executionStatus: .completed, exitCode: 0), to: bundle
        )
        let manifest = try LocalWorkflowRunBundleStore.read(from: bundle)
        let retained = try retainedRequest(in: manifest)
        XCTAssertEqual(retained, request)
        XCTAssertEqual(retained.inputURLs, request.inputURLs)
        XCTAssertEqual(retained.expectedOutputURLs, request.expectedOutputURLs)
        XCTAssertEqual(retained.params["empty"], "")
    }

    func testFailedManifestPreservesUnresolvedResourceDefaultsAndRawOptions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-replay-defaults-\(UUID().uuidString)")
        let request = LocalWorkflowRunRequest(
            workflowURL: root.appendingPathComponent("Fixture.lungfishflowpkg/Snakefile"),
            engine: .snakemake,
            inputURLs: [root.appendingPathComponent("input.txt")],
            outputDirectory: root.appendingPathComponent("results"),
            params: ["outdir": "literal original option", "empty": ""],
            cpus: nil,
            memory: nil
        )
        let retained = try retainedRequest(in: request.manifest(executionStatus: .failed, exitCode: 9))
        XCTAssertEqual(retained, request)
        XCTAssertNil(retained.cpus)
        XCTAssertNil(retained.memory)
        XCTAssertNil(retained.workDirectory)
        XCTAssertEqual(retained.params["outdir"], "literal original option")
        XCTAssertEqual(retained.effectiveParams["cores"], "all")
    }

    func testLegacyManifestWithoutTypedRequestStillDecodesAsHistory() throws {
        let request = LocalWorkflowRunRequest(
            workflowURL: URL(fileURLWithPath: "/invented/fixture.nf"),
            engine: .nextflow,
            outputDirectory: URL(fileURLWithPath: "/invented/results")
        )
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(request.manifest(executionStatus: .failed, exitCode: 1))
        ) as? [String: Any])
        object.removeValue(forKey: "request")
        object.removeValue(forKey: "replayIdentity")
        let decoded = try JSONDecoder().decode(
            LocalWorkflowRunBundleManifest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.executionStatus, .failed)
        XCTAssertEqual(decoded.workflowPath, request.workflowURL.path)
        XCTAssertEqual(decoded.commandPreview, request.commandPreview)
    }

    func testCompleteIdentityIncludesHiddenPackageBytesAndInputOrder() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        XCTAssertEqual(identity.schemaVersion, 1)
        XCTAssertEqual(identity.packageManifest.id, "invented-local-fixture")
        XCTAssertTrue(identity.package.entries.contains { $0.relativePath == ".settings/runtime.txt" && $0.sha256 != nil })
        XCTAssertTrue(identity.package.entries.contains { $0.relativePath == "main.nf" && $0.sha256 != nil })
        XCTAssertEqual(identity.inputs.map(\.rootURL), request.inputURLs.map { $0.resolvingSymlinksInPath() })
        try identity.validateCurrentInputs(for: request)
    }

    func testRetainedIdentityRejectsHiddenPackageChangesAndMissingInputWithoutRecapture() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        let settings = request.workflowURL.deletingLastPathComponent().appendingPathComponent(".settings/runtime.txt")
        try "changed runtime declaration".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try identity.validateCurrentInputs(for: request))
        try "retained runtime declaration".write(to: settings, atomically: true, encoding: .utf8)
        try identity.validateCurrentInputs(for: request)
        try FileManager.default.removeItem(at: request.inputURLs[0])
        XCTAssertThrowsError(try identity.validateCurrentInputs(for: request))
    }

    func testCompleteIdentityRejectsNewSymlinkPayloadInsteadOfSilentlyIgnoringIt() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LocalWorkflowReplayIdentity.capture(for: request)
        let link = request.workflowURL.deletingLastPathComponent().appendingPathComponent("linked-payload.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: request.inputURLs[0])
        XCTAssertThrowsError(try LocalWorkflowReplayIdentity.capture(for: request))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.inputURLs[0].path))
    }

    func testBoundIdentitySurvivesManifestDecodeWithoutRecapturingChangedSources() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        let manifest = try boundManifest(request: request, identity: identity, status: .completed)
        try "changed after execution".write(to: request.inputURLs[0], atomically: true, encoding: .utf8)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        let retained = try XCTUnwrap(encoded["replayIdentity"] as? [String: Any], "A status record must retain its captured identity")
        let decoded = try JSONDecoder().decode(LocalWorkflowReplayIdentity.self, from: JSONSerialization.data(withJSONObject: retained))
        XCTAssertEqual(decoded, identity)
        XCTAssertThrowsError(try decoded.validateCurrentInputs(for: request))
    }

    func testTerminalBoundHistoryReopensConfigurationEvenWhenInputNeedsRepair() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        try FileManager.default.removeItem(at: request.inputURLs[0])
        for status in [NFCoreRunExecutionStatus.completed, .failed, .cancelled] {
            let manifest = try boundManifest(request: request, identity: identity, status: status)
            let configuration = try LocalWorkflowReplayConfiguration.restored(from: manifest)
            XCTAssertEqual(configuration.request, request)
            XCTAssertEqual(configuration.identity, identity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path), "Reopening must not create or launch a new attempt")
        }
    }

    func testPreparedRunningUnboundAndUnknownHistoryCannotBecomeAReplayConfiguration() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        for status in [NFCoreRunExecutionStatus.prepared, .running] {
            let manifest = try boundManifest(request: request, identity: identity, status: status)
            XCTAssertThrowsError(try LocalWorkflowReplayConfiguration.restored(from: manifest))
        }
        XCTAssertThrowsError(try LocalWorkflowReplayConfiguration.restored(from: request.manifest(executionStatus: .completed)))
        let unknown = try boundManifest(request: request, identity: identity, status: .completed, schemaVersion: 999)
        XCTAssertThrowsError(try LocalWorkflowReplayConfiguration.restored(from: unknown))
    }

    func testReferencePresentationStateIsExcludedTransparentlyButOtherHiddenInputBytesStayBound() throws {
        let (root, request) = try identityFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = root.appendingPathComponent("Source.lungfishref")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try "invented bundle payload".write(to: reference.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let viewState = reference.appendingPathComponent(".viewstate.json")
        try "original presentation".write(to: viewState, atomically: true, encoding: .utf8)
        let changedRequest = LocalWorkflowRunRequest(workflowURL: request.workflowURL, engine: request.engine,
                                                    inputURLs: [reference], outputDirectory: request.outputDirectory)
        let identity = try LocalWorkflowReplayIdentity.capture(for: changedRequest)
        try "new presentation".write(to: viewState, atomically: true, encoding: .utf8)
        try identity.validateCurrentInputs(for: changedRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity.inputs[0])) as? [String: Any])
        XCTAssertEqual(object["excludedRelativePaths"] as? [String], [".viewstate.json"])
        try "scientific hidden payload".write(to: reference.appendingPathComponent(".payload.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try identity.validateCurrentInputs(for: changedRequest))
    }

    private func boundManifest(
        request: LocalWorkflowRunRequest, identity: LocalWorkflowReplayIdentity,
        status: NFCoreRunExecutionStatus, schemaVersion: Int = 1
    ) throws -> LocalWorkflowRunBundleManifest {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request.manifest(executionStatus: status))) as? [String: Any])
        object["schemaVersion"] = schemaVersion
        object["replayIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        return try JSONDecoder().decode(LocalWorkflowRunBundleManifest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func identityFixture() throws -> (URL, LocalWorkflowRunRequest) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-replay-identity-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package.appendingPathComponent(".settings"), withIntermediateDirectories: true)
        try "// invented fixture; never executed".write(to: package.appendingPathComponent("main.nf"), atomically: true, encoding: .utf8)
        try "retained runtime declaration".write(to: package.appendingPathComponent(".settings/runtime.txt"), atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(
            id: "invented-local-fixture", name: "Invented Local Fixture", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "source", name: "Source", bundleTypes: [.lungfishref])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "result.lungfishref")]
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let inputs = [root.appendingPathComponent("second.txt"), root.appendingPathComponent("first.txt")]
        for input in inputs { try input.lastPathComponent.write(to: input, atomically: true, encoding: .utf8) }
        return (root, LocalWorkflowRunRequest(
            workflowURL: package.appendingPathComponent("main.nf"), engine: .nextflow,
            inputURLs: inputs, outputDirectory: root.appendingPathComponent("results"), cpus: 2
        ))
    }

    private func retainedRequest(in manifest: LocalWorkflowRunBundleManifest) throws -> LocalWorkflowRunRequest {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(manifest)
        ) as? [String: Any])
        let retained = try XCTUnwrap(object["request"] as? [String: Any],
                                    "Run history must retain the exact typed request, not reconstruct it from commandPreview or effective params")
        return try JSONDecoder().decode(
            LocalWorkflowRunRequest.self,
            from: JSONSerialization.data(withJSONObject: retained)
        )
    }
}
