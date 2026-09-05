import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

final class AnnotationExportServiceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testOpenDocumentExportRetainsUnsavedSelectionForReplayAfterLiveSourceChanges() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        let output = root.appendingPathComponent("edited selection.gff3")
        try Data("original document revision".utf8).write(to: source)
        var annotations = [SequenceAnnotation(type: .gene, name: "unsaved-edited-feature", chromosome: "synthetic", start: 2, end: 7)]
        let request = AnnotationExportService.Request(source: .init(kind: .openDocument, urls: [source], name: "Edited document"),
            annotations: annotations, outputURL: output)
        annotations[0].name = "later-live-feature"
        try await AnnotationExportService.export(request)
        let expected = try Data(contentsOf: output)
        XCTAssertTrue(String(decoding: expected, as: UTF8.self).contains("unsaved-edited-feature"))
        XCTAssertFalse(String(decoding: expected, as: UTF8.self).contains("later-live-feature"))
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(receipt.argv.first, "Lungfish.app")
        XCTAssertEqual(receipt.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: output))
        let replay = try XCTUnwrap(receipt.durableReplayArgv)
        XCTAssertEqual(replay.first, "/bin/cp")
        let metadata = try XCTUnwrap(receipt.files.first { $0.role == .input && $0.path.hasSuffix("selection.json") })
        let selection = try String(contentsOfFile: metadata.path, encoding: .utf8)
        XCTAssertTrue(selection.contains("openDocument"))
        XCTAssertTrue(selection.contains("unsaved-edited-feature"))
        XCTAssertTrue(selection.contains("Edited document"))
        try Data("changed live document".utf8).write(to: source)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: output)
        try Self.runRetainedCopy(replay)
        XCTAssertEqual(try Data(contentsOf: output), expected)
    }

    func testSidebarBundleExportRecordsCapturedSourceAndSelection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfishref")
        let output = root.appendingPathComponent("sidebar.gff3")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let annotation = SequenceAnnotation(type: .gene, name: "sidebar-feature", chromosome: "synthetic", start: 10, end: 15)
        try await AnnotationExportService.export(.init(source: .init(kind: .sidebarBundle, urls: [source], name: "Selected reference"),
            annotations: [annotation], outputURL: output))
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        let metadata = try XCTUnwrap(receipt.files.first { $0.role == .input && $0.path.hasSuffix("selection.json") })
        let selection = try String(contentsOfFile: metadata.path, encoding: .utf8)
        XCTAssertTrue(selection.contains("sidebarBundle"))
        XCTAssertTrue(selection.contains("Selected reference"))
        XCTAssertTrue(selection.contains(annotation.id.uuidString))
        XCTAssertEqual(receipt.exitStatus, 0)
        XCTAssertNotNil(receipt.wallTimeSeconds)
    }

    func testGFF3SidecarFailurePreservesExistingUserExport() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("previous.gff3")
        try Data("previous user export".utf8).write(to: output)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let marker = sidecar.appendingPathComponent("retained")
        try Data("previous sidecar artifact".utf8).write(to: marker)
        do {
            try await AnnotationExportService.export(.init(source: .init(kind: .openDocument, urls: [], name: "Unsaved"),
                annotations: [SequenceAnnotation(type: .gene, name: "replacement", start: 0, end: 2)], outputURL: output))
            XCTFail("Expected publication obstruction to reject export")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: output), Data("previous user export".utf8))
        XCTAssertEqual(try Data(contentsOf: marker), Data("previous sidecar artifact".utf8))
    }

    func testMethodsAndJSONDescribeByteReplayWithoutClaimingUpstreamAnalysis() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("scope.gff3")
        try await AnnotationExportService.export(.init(source: .init(kind: .openDocument, urls: [], name: "Unsaved"),
            annotations: [SequenceAnnotation(type: .gene, name: "selected", start: 1, end: 4)], outputURL: output))
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        let methods = ProvenanceExporter().exportMethods(receipt.legacyWorkflowRun(preferCanonicalSteps: true))
        XCTAssertTrue(methods.contains("retained-selection snapshot byte replay"))
        XCTAssertTrue(methods.contains("does not rerun upstream analysis"))
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertTrue(json.contains("retained-selection snapshot byte replay"))
        XCTAssertTrue(json.contains("replaysUpstreamAnalysis"))
    }

    private static func runRetainedCopy(_ argv: [String]) throws {
        guard argv.count == 3, argv.first == "/bin/cp" else { throw CocoaError(.executableNotLoadable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = Array(argv.dropFirst())
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
