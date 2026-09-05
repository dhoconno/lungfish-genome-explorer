import XCTest
@testable import LungfishWorkflow

/// Synthetic file-publication tests; no classifier, biological fixture or external tool.
final class ClassifierFilePublicationTests: XCTestCase {
    func testFailedSidecarPreservesPreviousDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("classifier-publication-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("scratch.txt")
        let output = root.appendingPathComponent("previous.txt")
        try Data("new synthetic bytes".utf8).write(to: source)
        try Data("old synthetic bytes".utf8).write(to: output)
        try FileManager.default.createDirectory(at: ProvenanceRecorder.fileSidecarURL(for: output), withIntermediateDirectories: true)
        let request = ScientificFileExportProvenance.Request(workflowName: "copy fixture", sourceURLs: [source],
            outputURL: output, outputFormat: .text, argv: ["fixture"], startedAt: Date())
        XCTAssertThrowsError(try ClassifierReadResolver.publishStandaloneFile(from: source, to: output, provenance: request))
        XCTAssertEqual(try Data(contentsOf: output), Data("old synthetic bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new synthetic bytes".utf8))
    }

    func testReplacementPublishesMatchingPayloadAndFinalSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("classifier-publication-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("scratch.txt")
        let output = root.appendingPathComponent("previous.txt")
        try Data("new synthetic bytes".utf8).write(to: source)
        try Data("old synthetic bytes".utf8).write(to: output)
        let request = ScientificFileExportProvenance.Request(workflowName: "copy fixture", sourceURLs: [source],
            outputURL: output, outputFormat: .text, argv: ["fixture"], startedAt: Date())
        try ClassifierReadResolver.publishStandaloneFile(from: source, to: output, provenance: request)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.output?.path, output.path)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: output))
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
    }
}
