import Foundation
import XCTest
@testable import LungfishOperations
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Lane 12.39 M1 pins of B5, the GFF3 export of one source's annotations, at the base with no Sources edit
/// (QA 1). The payload is `GFF3Writer.write` of the captured annotations, and the base's selection.json holds the
/// source and those annotations, which rebuild the payload with no other input (the trace of M1 (3)).
final class AnnotationGFF3ExportPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationGFF3ExportPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct BaseSelection: Decodable {
        let replayScope: String
        let source: AnnotationExportService.Source
        let annotations: [SequenceAnnotation]
    }

    func testBytesRecordAndSelectionOfOneSource() async throws {
        let bundle = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let annotations = [
            SequenceAnnotation(type: .gene, name: "geneA", chromosome: "chr1", start: 10, end: 100),
            SequenceAnnotation(type: .cds, name: "cdsA; partial", chromosome: "chr1", start: 20, end: 90),
            SequenceAnnotation(type: .gene, name: "geneB", chromosome: "chr2", start: 0, end: 5),
        ]
        let output = root.appendingPathComponent("reference.gff3")
        try await AnnotationExportService.export(.init(
            source: .init(kind: .sidebarBundle, urls: [bundle], name: "Reference"),
            annotations: annotations, outputURL: output
        ))

        let payload = try Data(contentsOf: output)
        let reference = root.appendingPathComponent("builder.gff3")
        try await GFF3Writer.write(annotations, to: reference, source: "Lungfish")
        XCTAssertEqual(payload, try Data(contentsOf: reference), "the payload is the builder's bytes")
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("##gff-version 3\n"), text)
        XCTAssertEqual(text.split(separator: "\n").filter { !$0.hasPrefix("#") }.count, 3, text)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)
        ))
        XCTAssertEqual(envelope.toolName, "Lungfish.app")
        XCTAssertEqual(envelope.tool.kind, "gui")
        XCTAssertEqual(envelope.argv, [
            "Lungfish.app", "export-gff3", "--source-kind", "sidebarBundle", "--source", bundle.path,
            "--output", output.path,
        ])
        XCTAssertEqual(envelope.workflowName, "lungfish app annotation export")
        XCTAssertEqual(envelope.durableReplayArgv?.first, "/bin/cp")
        // The base names its retained copy and selection.json, never the bundle the annotations came from.
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(), ["selected.gff3", "selection.json"])
        XCTAssertEqual(Set(envelope.options.resolvedDefaults.keys), ["annotationCount", "replayScope", "replaysUpstreamAnalysis"])
        XCTAssertEqual(envelope.options.resolvedDefaults["annotationCount"]?.integerValue, 3)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath", "sourceKind", "sourceName", "sourcePaths"])
        XCTAssertEqual(envelope.options.defaults.keys.sorted(), ["featureSource", "outputFormat"])

        // The trace. The selection holds the source and the annotations as values, and they alone rebuild the bytes.
        let selectionURL = try XCTUnwrap(inputs.first { $0.path.hasSuffix("/selection.json") }).path
        let selection = try JSONDecoder().decode(BaseSelection.self, from: Data(contentsOf: URL(fileURLWithPath: selectionURL)))
        XCTAssertEqual(selection.source.kind, .sidebarBundle)
        XCTAssertEqual(selection.annotations.map(\.id), annotations.map(\.id))
        let rebuilt = root.appendingPathComponent("rebuilt.gff3")
        try await GFF3Writer.write(selection.annotations, to: rebuilt, source: "Lungfish")
        XCTAssertEqual(try Data(contentsOf: rebuilt), payload)
    }
}
