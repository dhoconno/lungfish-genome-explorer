import Foundation
import XCTest
@testable import LungfishWorkflow

final class LocalWorkflowRuntimeEvidenceTests: XCTestCase {
    func testEvidenceRecordsCurrentExecutableBytesAfterARepairAndOnlyRelevantEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".lungfish/conda/envs/nextflow/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("nextflow")
        try "old local fixture".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let launch = WorkflowEngineLaunch.resolve(executableName: "nextflow", homeDirectory: root,
            baseEnvironment: ["PATH": "/fixture/bin", "PRIVATE_API_TOKEN": "must never be retained", "OTHER_SETTING": "unrelated"])
        let oldHash = ProvenanceRecorder.sha256(of: executable)
        try "repaired local fixture".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let evidence = try XCTUnwrap(LocalWorkflowRuntimeEvidence.capture(afterRepair: launch))
        XCTAssertEqual(evidence.executable.path, executable.path)
        XCTAssertEqual(evidence.executable.sha256, ProvenanceRecorder.sha256(of: executable))
        XCTAssertNotEqual(evidence.executable.sha256, oldHash)
        XCTAssertEqual(evidence.executable.sizeBytes, UInt64("repaired local fixture".utf8.count))
        XCTAssertEqual(evidence.environment["HOME"], root.path)
        XCTAssertEqual(evidence.environment["PATH"], launch.environment["PATH"])
        XCTAssertEqual(evidence.environment["NXF_HOME"], launch.environment["NXF_HOME"])
        XCTAssertNil(evidence.environment["PRIVATE_API_TOKEN"])
        XCTAssertNil(evidence.environment["OTHER_SETTING"])
    }

    func testMissingRuntimeProducesNoClaimedExecutableIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-runtime-\(UUID().uuidString)")
        let launch = WorkflowEngineLaunch.resolve(executableName: "invented-unavailable-local-engine", homeDirectory: root,
            baseEnvironment: ["PATH": "/invented/missing"])
        XCTAssertNil(LocalWorkflowRuntimeEvidence.capture(afterRepair: launch))
    }
}
