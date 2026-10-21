import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class FASTQIngestionProvenanceTests: XCTestCase {
    func testSampleSheetMetadataWriteAppendsBundleProvenance() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQSampleSheetMetadataProvenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = temp.appendingPathComponent("SampleA.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("SampleA.fastq.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: fastqURL)
        let sampleSheetURL = temp.appendingPathComponent("samples.csv")
        try """
        sample,r1,collection_site
        SampleA,\(fastqURL.path),Site 12
        """.write(to: sampleSheetURL, atomically: true, encoding: .utf8)

        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "lungfish import fastq",
            workflowVersion: "2026.05",
            toolName: "lungfish import fastq",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "import", "fastq", fastqURL.path, "--project", temp.path])
        .output(fastqURL, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish import fastq",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "import", "fastq", fastqURL.path, "--project", temp.path],
                outputs: [try ProvenanceFileDescriptor.file(url: fastqURL, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 80),
            endedAt: Date(timeIntervalSince1970: 81)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, to: bundleURL)

        let pair = FASTQFilePair(
            r1: fastqURL,
            r2: nil,
            sampleNameOverride: "SampleA",
            metadata: ["collection_site": "Site 12"],
            sampleSheetURL: sampleSheetURL
        )

        try FASTQIngestionService.testingSaveSampleSheetMetadata(pair: pair, bundleURL: bundleURL)

        let metadataURL = FASTQBundleCSVMetadata.metadataURL(in: bundleURL)
        let saved = try XCTUnwrap(FASTQBundleCSVMetadata.load(from: bundleURL))
        XCTAssertEqual(saved.keyValuePairs["sample"], "SampleA")
        XCTAssertEqual(saved.keyValuePairs["collection_site"], "Site 12")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertTrue(envelope.outputs.contains { $0.path == fastqURL.path })
        XCTAssertTrue(envelope.outputs.contains { output in
            output.path == metadataURL.path
                && output.checksumSHA256?.count == 64
                && (output.fileSize ?? 0) > 0
        })
        let metadataStep = try XCTUnwrap(envelope.steps.last)
        XCTAssertEqual(metadataStep.toolName, LungfishAppIdentity.recordedToolName)
        XCTAssertTrue(metadataStep.argv.contains(sampleSheetURL.path))
        XCTAssertTrue(metadataStep.inputs.contains { $0.path == sampleSheetURL.path })
        XCTAssertTrue(metadataStep.outputs.contains { $0.path == metadataURL.path })

        let focusedSidecar = try XCTUnwrap(
            ProvenanceWriter.bundleOutputSidecarURL(for: metadataURL, inBundle: bundleURL)
        )
        let focusedEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: focusedSidecar))
        XCTAssertEqual(focusedEnvelope.output?.path, metadataURL.path)
        XCTAssertEqual(focusedEnvelope.steps.last?.toolName, LungfishAppIdentity.recordedToolName)
    }
}
