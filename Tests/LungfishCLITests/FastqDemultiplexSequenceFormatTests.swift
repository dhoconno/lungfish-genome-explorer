import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class FastqDemultiplexSequenceFormatTests: XCTestCase {
    func testExactDemultiplexFASTAProducesFASTAWithCompleteTransformationProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demux-fasta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.fasta")
        let kit = directory.appendingPathComponent("barcodes.csv")
        let output = directory.appendingPathComponent("demux")
        try ">read1\nACGTTGCAAGTCGATGCTAGCTACGATCGTAC\n".write(to: input, atomically: true, encoding: .utf8)
        try "id,sequence\nBC01,ACGTTGCAAGTC\n".write(to: kit, atomically: true, encoding: .utf8)
        let command = try FastqDemultiplexSubcommand.parse([
            input.path, "--kit", kit.path, "--output", output.path,
            "--engine", "exact-bare", "--location", "5prime", "--discard-unassigned"
        ])
        try await command.run()
        let bundles = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { FASTQBundle.isBundleURL($0) }
        let bundle = try XCTUnwrap(bundles.first)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        XCTAssertEqual(manifest.sequenceFormat, .fasta)
        guard case .fullFASTA = manifest.payload else { return XCTFail("Expected physical FASTA payload") }
        XCTAssertEqual(manifest.cachedStatistics.readCount, 1)
        XCTAssertTrue(manifest.cachedStatistics.qualityScoreHistogram.isEmpty)
        XCTAssertNil(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimarySequenceURL(for: bundle))
        XCTAssertEqual(SequenceFormat.from(url: payload), .fasta)
        XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), ">read1\nACGTTGCAAGTCGATGCTAGCTACGATCGTAC\n")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: payload)))
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "SyntheticFASTQBridge.convertFASTAToFASTQ" })
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "exact-bare-barcode-demux" })
        XCTAssertTrue(envelope.steps.contains { $0.toolName == SequenceProcessingOutputNormalizer.normalizationToolName })
        XCTAssertTrue(envelope.files.contains { $0.path == input.path && $0.format == .fasta && $0.checksumSHA256 != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == payload.path && $0.format == .fasta && $0.checksumSHA256 != nil })
        let bundleEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        XCTAssertEqual(bundleEnvelope.output?.path, payload.path)
        XCTAssertEqual(bundleEnvelope.output?.format, .fasta)
        let directoryEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertTrue(directoryEnvelope.outputs.contains { $0.path == payload.path && $0.format == .fasta })
        XCTAssertTrue(directoryEnvelope.steps.contains { $0.toolName == SequenceProcessingOutputNormalizer.normalizationToolName })
        for step in envelope.steps {
            for file in step.inputs + step.outputs where file.format == .fastq || file.format == .fasta {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Missing recorded sequence artifact: \(file.path)")
            }
        }
    }

    func testRetainedPayloadIsCompleteDatasetRatherThanPreview() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("zz-\(UUID().uuidString).lungfishfastq")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data("preview".utf8).write(to: bundle.appendingPathComponent("preview.fastq"))
        try Data("complete".utf8).write(to: bundle.appendingPathComponent("zz.fastq"))
        let retained = try FastqDemultiplexSequenceFormat.retainToolPayload(in: bundle)
        XCTAssertEqual(retained.lastPathComponent, "zz.fastq")
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "complete")
        XCTAssertNil(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
    }
}
