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
        try Data("changed".utf8).write(to: bundle.url.appendingPathComponent("native/result.txt"))
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
    }

    func testInspectionPolicyDoesNotRequireWritingProvenance() throws {
        let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand(path: ["primers", "analysis", "inspect"]))
        XCTAssertFalse(policy.createsOrModifiesScientificData)
        XCTAssertFalse(policy.requiresProvenance)
    }

    func testDesignAndAnnotatedReferenceCommandsRequireFinalOutputProvenance() throws {
        for path in [["primers", "design", "primer3"], ["primers", "design", "primalscheme3"],
                     ["primers", "analysis", "annotated-reference"]] {
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
    }

    private func fixture(in root: URL) throws -> PrimerAnalysisBundle {
        let source = root.appendingPathComponent("source.txt")
        let output = root.appendingPathComponent("result.txt")
        try Data("opaque source\n".utf8).write(to: source)
        try Data("opaque result\n".utf8).write(to: output)
        let inputID = UUID()
        return try PrimerAnalysisBundleWriter().write(.init(
            analysisID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            runID: UUID(), grouping: .combined,
            inputs: [.init(id: inputID, label: "example input", artifactPaths: ["inputs/source.txt"])],
            results: [.init(id: UUID(), label: "example result", inputIDs: [inputID], artifactPaths: ["native/result.txt"])],
            artifacts: [
                .init(sourceURL: source, relativePath: "inputs/source.txt", role: "input", format: "text"),
                .init(sourceURL: output, relativePath: "native/result.txt", role: "nativeOutput", format: "text"),
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
