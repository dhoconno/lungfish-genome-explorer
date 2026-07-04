import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

@MainActor
final class BundleCreateProvenanceTests: XCTestCase {
    func testBundlePayloadURLsExcludeProvenanceSidecars() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-payload-filter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Payload.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let provenanceURL = bundleURL.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: provenanceURL, withIntermediateDirectories: true)

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let fastaURL = genomeURL.appendingPathComponent("sequence.fa")
        try "{}".write(to: manifestURL, atomically: true, encoding: .utf8)
        try ">chr1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try "{}".write(
            to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: provenanceURL.appendingPathComponent(ProvenanceWriter.bundleRollupFilename),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: genomeURL.appendingPathComponent("sequence.fa.lungfish-provenance.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: bundleURL.appendingPathComponent("\(ProvenanceRecorder.provenanceFilename).signature.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: bundleURL.appendingPathComponent("\(ProvenanceRecorder.provenanceFilename).pub"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: genomeURL.appendingPathComponent("sequence.fa.lungfish-provenance.json.signature.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: genomeURL.appendingPathComponent("sequence.fa.lungfish-provenance.json.pub"),
            atomically: true,
            encoding: .utf8
        )

        let payloadPaths = Set(CLIProvenanceSupport.bundlePayloadURLs(in: bundleURL).map(\.path))
        XCTAssertEqual(payloadPaths, [manifestURL.standardizedFileURL.path, fastaURL.standardizedFileURL.path])
    }

    func testBundleCreateWritesWorkflowProvenanceSidecar() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-create-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fastaURL = tempDir.appendingPathComponent("genome.fa")
        try """
        >chr1
        ACGTACGTACGT
        """.write(to: fastaURL, atomically: true, encoding: .utf8)

        let command = try BundleCreateSubcommand.parse([
            "--fasta", fastaURL.path,
            "--name", "Test Bundle",
            "--identifier", "org.lungfish.test.bundle",
            "--organism", "Test organism",
            "--assembly", "Test assembly",
            "--output-dir", tempDir.path,
        ])

        try await command.run()

        let bundleURL = tempDir.appendingPathComponent("Test_Bundle.lungfishref", isDirectory: true)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))

        XCTAssertEqual(run.name, "lungfish bundle create")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.steps.count, 1)
        XCTAssertEqual(run.steps[0].toolName, "lungfish bundle create")
        XCTAssertEqual(run.steps[0].exitCode, 0)
        XCTAssertEqual(run.parameters["identifier"]?.stringValue, "org.lungfish.test.bundle")
        XCTAssertEqual(run.parameters["compressFASTA"]?.booleanValue, false)
        XCTAssertTrue(run.primaryInputFiles.contains {
            $0.path == fastaURL.path && $0.sha256 != nil && $0.sizeBytes != nil
        })
        let manifestPath = bundleURL
            .appendingPathComponent("manifest.json")
            .standardizedFileURL
            .path
        XCTAssertTrue(run.allOutputFiles.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == manifestPath
                && $0.sha256 != nil
                && $0.sizeBytes != nil
        })
        XCTAssertFalse(run.allOutputFiles.contains {
            $0.path.contains("/provenance/") || $0.path.hasSuffix(".lungfish-provenance.json")
        })
        XCTAssertTrue(run.steps[0].command.contains("--identifier"))
    }
}
