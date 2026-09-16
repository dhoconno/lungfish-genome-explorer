import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class PrimerAnalysisInspectCommandTests: XCTestCase {
    func testRegisteredCommandInspectsManifestWithoutChangingBundleBytes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixture(in: root)
        let before = try snapshot(bundle.url)
        let command = try XCTUnwrap(try LungfishCLI.parseAsRoot([
            "primers", "analysis", "inspect", bundle.url.path, "--json"
        ]) as? PrimerAnalysisInspectCommand)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let inspected = try decoder.decode(PrimerAnalysisManifest.self, from: Data(command.inspectionOutput().utf8))
        XCTAssertEqual(inspected.analysisID, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(inspected.grouping, .combined)
        XCTAssertEqual(inspected.inputs.count, 1)
        XCTAssertEqual(inspected.results.count, 1)
        XCTAssertEqual(try snapshot(bundle.url), before)
    }

    func testCorruptedPayloadCannotProduceTextOrJSONSuccess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixture(in: root)
        let native = try XCTUnwrap(bundle.manifest.artifacts.first { $0.role == "nativeOutput" })
        try Data("changed".utf8).write(to: bundle.url.appendingPathComponent(native.relativePath))
        for flags in [[], ["--json"]] {
            let command = try PrimerAnalysisInspectCommand.parse([bundle.url.path] + flags)
            XCTAssertThrowsError(try command.inspectionOutput())
        }
    }

    func testSummaryReportsStoredGroupingAndInventory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixture(in: root)
        let command = try PrimerAnalysisInspectCommand.parse([bundle.url.path])
        let output = try command.inspectionOutput()
        XCTAssertTrue(output.contains("Grouping: combined"))
        XCTAssertTrue(output.contains("Inputs: 1"))
        XCTAssertTrue(output.contains("Results: 1"))
        XCTAssertTrue(output.contains("Integrity verified"))
        XCTAssertTrue(output.contains("Metric: observed-allele-primer-trimmed/v1"))
        XCTAssertTrue(output.contains("distinct classes 2"))
        XCTAssertTrue(output.contains("Class allele-a (aliases: row-a, row-a-duplicate): covered 90/100; fraction 0.9000; deficit 0.0500; dropout no"))
        XCTAssertTrue(output.contains("Class allele-b: covered 100/100; fraction 1.0000; deficit 0.0000; dropout no"))
        XCTAssertTrue(output.contains("target-1: mean 0.9500; assessable classes 2; unassessable classes 0; covered 190/200; deficit 0.0000; dropout no"))
    }

    func testSummaryKeepsUnassessableTierTargetAndClassVisible() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixture(in: root, unassessable: true)
        let output = try PrimerAnalysisInspectCommand.parse([bundle.url.path]).inspectionOutput()

        XCTAssertTrue(output.contains("Tier strict: mean unavailable; distinct classes 1; goal 0.9500"))
        XCTAssertTrue(output.contains("target-1: mean unavailable; assessable classes 0; unassessable classes 1; covered 0/0; deficit unavailable; dropout unavailable"))
        XCTAssertTrue(output.contains("Class allele-unavailable (aliases: row-unknown): covered 0/0; fraction unavailable; deficit unavailable; dropout unavailable"))
    }

    func testInspectionPolicyDoesNotRequireWritingProvenance() throws {
        let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand(path: ["primers", "analysis", "inspect"]))
        XCTAssertFalse(policy.createsOrModifiesScientificData)
        XCTAssertFalse(policy.requiresProvenance)
    }

    func testDesignAndAnnotatedReferenceCommandsRequireFinalOutputProvenance() throws {
        for path in [["primers", "design", "primer3"], ["primers", "design", "primalscheme3"],
                     ["primers", "analysis", "annotated-reference"],
                     ["primers", "analysis", "history"], ["primers", "analysis", "audit"]] {
            let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand(path: path))
            XCTAssertTrue(policy.requiresProvenance)
            XCTAssertEqual(policy.outputPathExpectation, .finalStoredPayload)
        }
        XCTAssertThrowsError(try PrimerAnalysisAnnotatedReferenceCommand.parse([
            "input.lungfishprimeranalysis", "--result-id", "invalid", "--output-directory", "/tmp"]))
        let command = try XCTUnwrap(LungfishCLI.parseAsRoot([
            "primers", "analysis", "annotated-reference", "input.lungfishprimeranalysis",
            "--result-id", UUID().uuidString, "--output-directory", "/tmp"])
            as? PrimerAnalysisAnnotatedReferenceCommand)
        XCTAssertEqual(command.outputDirectory, "/tmp")
        XCTAssertNoThrow(try PrimerAnalysisHistoryCommand.parse([
            "input.lungfishprimeranalysis", "--result-id", UUID().uuidString,
            "--primalscheme3-path", "/tmp/primalscheme3", "--output", "/tmp/history", "--stage", "strict"]))
        XCTAssertThrowsError(try PrimerAnalysisHistoryCommand.parse([
            "input.lungfishprimeranalysis", "--result-id", UUID().uuidString,
            "--primalscheme3-path", "/tmp/primalscheme3", "--output", "/tmp/history",
            "--stage", "strict", "--pool", "0"]))
        XCTAssertThrowsError(try PrimerAnalysisHistoryCommand.parse([
            "input.lungfishprimeranalysis", "--result-id", UUID().uuidString,
            "--primalscheme3-path", "/tmp/primalscheme3", "--output", "/tmp/history",
            "--stage", "strict", "--limit", "1001"]))
        XCTAssertNoThrow(try PrimerAnalysisAuditCommand.parse([
            "input.lungfishprimeranalysis", "--result-id", UUID().uuidString,
            "--primalscheme3-path", "/tmp/primalscheme3", "--output", "/tmp/audit"]))
    }

    private func fixture(in root: URL, unassessable: Bool = false) throws -> PrimerAnalysisBundle {
        let source = root.appendingPathComponent("source.txt")
        let output = root.appendingPathComponent("result.txt")
        try Data("opaque source\n".utf8).write(to: source)
        let resultID = UUID()
        let nativePath = "native/\(resultID.uuidString)/panel-optimizer.json"
        let coverage: [String: Any]
        if unassessable {
            coverage = ["mean_coverage": NSNull(), "goal": 0.95,
                "targets": [["target_id": "target-1", "fraction": NSNull(),
                    "assessable_classes": 0, "unassessable_classes": 1]],
                "classes": [["target_id": "target-1", "allele_id": "allele-unavailable",
                    "aliases": ["row-unknown"], "covered_count": 0, "observed_count": 0,
                    "fraction": NSNull()]]]
        } else {
            coverage = ["mean_coverage": 0.95, "goal": 0.95,
                "targets": [["target_id": "target-1", "fraction": 0.95,
                    "assessable_classes": 2, "unassessable_classes": 0]],
                "classes": [
                    ["target_id": "target-1", "allele_id": "allele-a",
                     "aliases": ["row-a", "row-a-duplicate"], "covered_count": 90,
                     "observed_count": 100, "fraction": 0.90],
                    ["target_id": "target-1", "allele_id": "allele-b", "covered_count": 100,
                     "observed_count": 100, "fraction": 1.0]
                ]]
        }
        let optimizer: [String: Any] = ["schemaVersion": "primalscheme3.panel-optimizer/v2",
          "metric": "observed-allele-primer-trimmed/v1", "primaryTier": "strict",
          "profile": ["name": "allele-panel-v1"], "stages": [["stage_id": "strict", "coverage": coverage]]]
        try JSONSerialization.data(withJSONObject: optimizer).write(to: output)
        let inputID = UUID()
        return try PrimerAnalysisBundleWriter().write(.init(
            analysisID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            runID: UUID(), grouping: .combined,
            inputs: [.init(id: inputID, label: "example input", artifactPaths: ["inputs/source.txt"])],
            results: [.init(id: resultID, label: "example result", inputIDs: [inputID], artifactPaths: [nativePath])],
            artifacts: [
                .init(sourceURL: source, relativePath: "inputs/source.txt", role: "input", format: "text"),
                .init(sourceURL: output, relativePath: nativePath, role: "nativeOutput", format: "json"),
            ],
            destinationURL: root.appendingPathComponent("example.lungfishprimeranalysis"),
            invocation: .init(argv: ["storage-test-host", "--case", "cli-inspection"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())
        ))
    }

    private func temporaryRoot() throws -> URL {
        let physicalPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physicalPath) }
        let root = URL(fileURLWithPath: String(cString: physicalPath)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in iterator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.path] = try Data(contentsOf: url)
            }
        }
        return files
    }
}
