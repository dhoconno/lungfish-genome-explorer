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
}
