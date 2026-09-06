import AppKit
import CryptoKit
import XCTest
@testable import LungfishApp

@MainActor
final class MSAClipboardExportArtifactTests: XCTestCase {
    func testClipboardPublicationRetainsPayloadAndMatchingProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try MSAClipboardExportArtifact.createOutputURL(applicationSupportDirectory: root)
        let payload = Data(">reference\nAC--GT\n>query\nACTTGT\n".utf8)
        try payload.write(to: output)
        let provenance = try writeProvenance(for: output, payload: payload)
        let publication = try MSAClipboardExportArtifact.load(from: output)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        publication.write(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), ">reference\nAC--GT\n>query\nACTTGT\n")
        XCTAssertEqual(pasteboard.data(forType: MSAClipboardExportArtifact.provenanceType), provenance)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), output.absoluteString)
        XCTAssertEqual(try Data(contentsOf: output), payload)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathExtension("lungfish-provenance.json")), provenance)
    }

    func testMissingOrMismatchedEvidenceCannotBeCopied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try MSAClipboardExportArtifact.createOutputURL(applicationSupportDirectory: root)
        let payload = Data(">row\nA-C\n".utf8)
        try payload.write(to: output)
        XCTAssertThrowsError(try MSAClipboardExportArtifact.load(from: output))
        _ = try writeProvenance(for: output, payload: payload, recordedPath: "/deleted/staging.fasta")
        XCTAssertThrowsError(try MSAClipboardExportArtifact.load(from: output))
        _ = try writeProvenance(for: output, payload: payload)
        try Data(">row\nACT\n".utf8).write(to: output)
        XCTAssertThrowsError(try MSAClipboardExportArtifact.load(from: output))
    }

    func testEachCopyHasItsOwnDurableOutputDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try MSAClipboardExportArtifact.createOutputURL(applicationSupportDirectory: root)
        let second = try MSAClipboardExportArtifact.createOutputURL(applicationSupportDirectory: root)
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertTrue(first.path.hasPrefix(root.path + "/"))
    }

    @discardableResult
    private func writeProvenance(for output: URL, payload: Data, recordedPath: String? = nil) throws -> Data {
        let provenance = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "workflowName": "multiple-sequence-alignment-export",
            "actionID": "msa.export.aligned-fasta",
            "toolName": "lungfish msa export", "toolVersion": "test",
            "argv": ["lungfish", "msa", "export", "--output-format", "aligned-fasta"],
            "reproducibleCommand": "lungfish msa export --output-format aligned-fasta",
            "options": ["outputFormat": "aligned-fasta", "sequenceLayout": "aligned", "selectedRowCount": 2, "selectedColumnCount": 6],
            "runtimeIdentity": ["executablePath": "/test/lungfish", "operatingSystemVersion": "test", "processIdentifier": 1],
            "inputBundle": ["path": "/test/source.lungfishmsa", "checksumSHA256": String(repeating: "0", count: 64), "fileSize": 100],
            "inputAlignmentFile": ["path": "/test/source.lungfishmsa/alignment/primary.aligned.fasta", "checksumSHA256": String(repeating: "1", count: 64), "fileSize": 50],
            "outputFile": [
                "path": recordedPath ?? output.path,
                "checksumSHA256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                "fileSize": payload.count,
            ],
            "exitStatus": 0,
            "wallTimeSeconds": 0.1, "warnings": [], "createdAt": "2026-09-06T12:00:00Z",
        ])
        try provenance.write(to: output.appendingPathExtension("lungfish-provenance.json"))
        return provenance
    }
}
