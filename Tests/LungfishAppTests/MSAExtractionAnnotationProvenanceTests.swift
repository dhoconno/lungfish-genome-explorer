import Foundation
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class MSAExtractionAnnotationProvenanceTests: XCTestCase {
    func testWriteStoresCanonicalEnvelopeAtLegacySidecarPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa-extraction-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceAlignmentBundleURL = root.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAlignmentBundleURL, withIntermediateDirectories: true)
        let sourceFASTAURL = root.appendingPathComponent("selection.fasta")
        let sourceAnnotationURL = root.appendingPathComponent("selection.bed")
        try ">seq1\nACGT\n".write(to: sourceFASTAURL, atomically: true, encoding: .utf8)
        try "seq1\t0\t4\tgene1\n".write(to: sourceAnnotationURL, atomically: true, encoding: .utf8)

        let bundleURL = root.appendingPathComponent("Extracted.lungfishref", isDirectory: true)
        let annotationsURL = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsURL, withIntermediateDirectories: true)
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        try #"{"schemaVersion":1}"#.write(to: manifestURL, atomically: true, encoding: .utf8)
        let databaseURL = annotationsURL.appendingPathComponent("msa_selection.db")
        try Data([0x53, 0x51, 0x4c, 0x69]).write(to: databaseURL)

        let track = AnnotationTrackInfo(
            id: "msa_selection",
            name: "MSA Selection",
            path: "annotations/msa_selection.db",
            databasePath: "annotations/msa_selection.db",
            annotationType: .custom,
            featureCount: 2
        )
        let result = ReferenceBundleAnnotationImportResult(bundleURL: bundleURL, track: track, featureCount: 2)

        let sidecarURL = try MSAExtractionAnnotationProvenance.write(
            bundleURL: bundleURL,
            sourceAlignmentBundleURL: sourceAlignmentBundleURL,
            sourceFASTAURL: sourceFASTAURL,
            sourceAnnotationURL: sourceAnnotationURL,
            annotationResult: result,
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 101)
        )

        XCTAssertTrue(sidecarURL.path.hasSuffix("annotations/msa-extraction-annotations-provenance.json"))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "msa-selection-reference-bundle-extraction")
        XCTAssertEqual(envelope.toolName, "lungfish-gui msa extract annotated bundle")
        XCTAssertEqual(envelope.output?.path, bundleURL.path)
        XCTAssertEqual(envelope.options.explicit["feature_count"], ParameterValue.integer(2))
        let files = envelope.files
        let outputs = envelope.outputs
        XCTAssertTrue(files.contains { descriptor in
            descriptor.path == sourceFASTAURL.path && descriptor.checksumSHA256 != nil && descriptor.fileSize != nil
        })
        XCTAssertTrue(files.contains { descriptor in
            descriptor.path == sourceAnnotationURL.path && descriptor.checksumSHA256 != nil && descriptor.fileSize != nil
        })
        XCTAssertTrue(files.contains { descriptor in
            descriptor.path == sourceAlignmentBundleURL.path && descriptor.role == FileRole.input
        })
        XCTAssertTrue(outputs.contains { descriptor in
            descriptor.path == manifestURL.path && descriptor.checksumSHA256 != nil && descriptor.fileSize != nil
        })
        XCTAssertTrue(outputs.contains { descriptor in
            descriptor.path == databaseURL.path && descriptor.checksumSHA256 != nil && descriptor.fileSize != nil
        })
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.wallTimeSeconds, 1)
        XCTAssertFalse(envelope.runtimeIdentity.appVersion.isEmpty)
    }

    func testWriteUsesDurableSelectionSourcesRatherThanTemporaryFASTAOrBED() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa-extraction-durable-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let durableSourceURL = root.appendingPathComponent("source.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: durableSourceURL, withIntermediateDirectories: true)
        let temporarySourceURL = root.appendingPathComponent("selection.fasta")
        let temporaryAnnotationURL = root.appendingPathComponent("selection.bed")
        try ">seq1\nACGT\n".write(to: temporarySourceURL, atomically: true, encoding: .utf8)
        try "seq1\t0\t4\tgene1\n".write(to: temporaryAnnotationURL, atomically: true, encoding: .utf8)

        let bundleURL = root.appendingPathComponent("Extracted.lungfishref", isDirectory: true)
        let annotationsURL = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsURL, withIntermediateDirectories: true)
        try #"{"schemaVersion":1}"#.write(
            to: bundleURL.appendingPathComponent(BundleManifest.filename),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x53, 0x51, 0x4c, 0x69]).write(to: annotationsURL.appendingPathComponent("msa_selection.db"))
        let track = AnnotationTrackInfo(
            id: "msa_selection", name: "MSA Selection", path: "annotations/msa_selection.db",
            databasePath: "annotations/msa_selection.db", annotationType: .custom, featureCount: 1
        )

        let sidecarURL = try MSAExtractionAnnotationProvenance.write(
            bundleURL: bundleURL,
            sourceAlignmentBundleURL: durableSourceURL,
            sourceFASTAURL: temporarySourceURL,
            sourceAnnotationURL: temporaryAnnotationURL,
            durableSourceURLs: [durableSourceURL],
            selectedSequenceIDs: ["seq1"],
            selectedAnnotationsByRecord: [
                "seq1": [SequenceAnnotation(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    type: .gene,
                    name: "gene1",
                    chromosome: "seq1",
                    start: 0,
                    end: 4,
                    strand: .forward
                )],
            ],
            annotationResult: ReferenceBundleAnnotationImportResult(bundleURL: bundleURL, track: track, featureCount: 1),
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 101)
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let inputPaths = envelope.files.filter { $0.role == .input }.map(\.path)
        XCTAssertTrue(inputPaths.contains(durableSourceURL.path))
        XCTAssertFalse(envelope.files.contains { $0.path == temporarySourceURL.path })
        XCTAssertFalse(envelope.files.contains { $0.path == temporaryAnnotationURL.path })
        XCTAssertEqual(
            envelope.options.explicit["selected_sequence_ids"],
            ParameterValue.array([.string("seq1")])
        )
        XCTAssertTrue(envelope.durableReplayArgv?.contains(temporarySourceURL.path) == false)
        XCTAssertTrue(envelope.durableReplayArgv?.contains("--sequence-id") == true)
        XCTAssertEqual(
            envelope.options.explicit["selected_annotation_bed_sha256"],
            ProvenanceRecorder.sha256(of: temporaryAnnotationURL).map(ParameterValue.string)
        )
        XCTAssertEqual(envelope.options.explicit["selected_annotation_bed_size"], .integer(15))
        guard case .dictionary(let selectedByRecord)? = envelope.options.explicit["selected_annotations_by_record"],
              case .array(let annotations)? = selectedByRecord["seq1"],
              case .dictionary(let gene)? = annotations.first else {
            return XCTFail("Expected exact selected annotation definitions in final provenance")
        }
        XCTAssertEqual(gene["name"], .string("gene1"))
        XCTAssertEqual(gene["intervals"], .array([.dictionary(["start": .integer(0), "end": .integer(4)])]))
    }
}
