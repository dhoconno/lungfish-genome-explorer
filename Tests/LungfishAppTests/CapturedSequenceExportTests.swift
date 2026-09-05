import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class CapturedSequenceExportTests: XCTestCase {
    func testGenBankAnnotationsStayWithTheirSelectedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedGenBank-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try ["first", "second"].map { name in
            let url = root.appendingPathComponent("project.lungfish/\(name)")
            return SequenceExportSourceResolver.Source(metadata: .init(kind: .nativeProjectSequence,
                url: url, documentID: UUID(), nativeSequenceID: UUID(), projectURL: url.deletingLastPathComponent()),
                document: .init(name: name, url: url,
                    sequences: [try LungfishCore.Sequence(name: name, alphabet: .dna, bases: "ACGT")],
                    annotations: [SequenceAnnotation(type: .gene, name: name + "-feature", start: 0, end: 2,
                        qualifiers: ["gene": AnnotationQualifier(name + "-feature")])]))
        }
        let output = root.appendingPathComponent("result.gb")
        _ = try await makeAppDelegateWithTemporaryState().performSequenceExport(
            sources: sources, outputURL: output, format: .genbank, compression: .none)
        let records = try GenBankReader(url: output).readAllRecoveringAnnotationsSync().records
        XCTAssertEqual(records.count, 2)
        for (record, name) in zip(records, ["first", "second"]) {
            XCTAssertEqual(record.annotations.count, 1)
            XCTAssertEqual(record.annotations.map(\.name), [name + "-feature"])
        }
    }

    func testMixedCapturedAndFilesystemExportPreservesOrderAndRetainedReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedExport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("disk.fa")
        try ">disk\nTTTT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let displayURL = root.appendingPathComponent("project.lungfish/native-display")
        let native = try LungfishCore.Sequence(name: "native", alphabet: .dna, bases: "ACGT")
        let sources: [SequenceExportSourceResolver.Source] = [
            .init(metadata: .init(kind: .nativeProjectSequence, url: displayURL, documentID: UUID(),
                nativeSequenceID: UUID(), projectURL: displayURL.deletingLastPathComponent()),
                document: .init(name: "native", url: displayURL, sequences: [native], annotations: [])),
            .init(metadata: .init(kind: .filesystem, url: sourceURL, documentID: nil,
                nativeSequenceID: nil, projectURL: nil), document: nil)
        ]
        let output = root.appendingPathComponent("result.fa")
        let count = try await makeAppDelegateWithTemporaryState().performSequenceExport(
            sources: sources, outputURL: output, format: .fasta, compression: .none)
        XCTAssertEqual(count, 2)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(">native\nACGT\n>disk\nTTTT"), text)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        let replay = try XCTUnwrap(receipt["durableReplayArgv"] as? [String])
        XCTAssertEqual(replay.first, "/bin/cp")
        if replay.first == "/bin/cp", replay.count == 3 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: replay[1]))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: replay[1])), try Data(contentsOf: output))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayURL.path))
    }
}
