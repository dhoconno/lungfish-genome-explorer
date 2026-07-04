import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class FASTQAutoBundleWorkflowTests: XCTestCase {
    func testWrapNakedFASTQWritesBundleAndPayloadProvenance() throws {
        let temp = try makeTemporaryDirectory(prefix: "fastq-auto-bundle-")
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceURL = temp.appendingPathComponent("sample.fastq")
        try fastqText.write(to: sourceURL, atomically: true, encoding: .utf8)
        let metadataURL = FASTQMetadataStore.metadataURL(for: sourceURL)
        try #"{"sample":"sample"}"#.write(to: metadataURL, atomically: true, encoding: .utf8)

        let bundleURL = temp.appendingPathComponent("sample.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let result = try FASTQAutoBundleWorkflow.wrapNakedFASTQ(
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            runtimeIdentity: .fixture()
        )

        XCTAssertEqual(result.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.payloadURL.path))

        let finalMetadataURL = bundleURL.appendingPathComponent(metadataURL.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalMetadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        let rollupURL = bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollupURL.path))
        let payloadSidecarURL = try XCTUnwrap(
            ProvenanceWriter.bundleOutputSidecarURL(for: result.payloadURL, inBundle: bundleURL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadSidecarURL.path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(envelope.workflowName, "FASTQ Auto-Bundle")
        XCTAssertEqual(envelope.toolName, "lungfish-app")
        XCTAssertEqual(envelope.output?.path, bundleURL.path)
        XCTAssertTrue(envelope.outputs.contains { $0.path == result.payloadURL.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == finalMetadataURL.path && $0.fileSize != nil })
        XCTAssertEqual(envelope.options.explicit["moveMode"]?.stringValue, "in-place-auto-bundle")
        XCTAssertTrue(envelope.steps.last?.argv.contains(sourceURL.path) == true)
        XCTAssertTrue(envelope.steps.last?.durableReplayArgv?.contains(result.payloadURL.path) == true)
    }

    func testWrapNakedFASTQPreservesExistingCLIProvenanceWithFinalPayloadPath() throws {
        let temp = try makeTemporaryDirectory(prefix: "fastq-auto-bundle-cli-")
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceURL = temp.appendingPathComponent("cli-output.fastq")
        try fastqText.write(to: sourceURL, atomically: true, encoding: .utf8)
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Materialize",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceURL.path])
        .output(sourceURL, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceURL.path],
                outputs: [try ProvenanceFileDescriptor.file(url: sourceURL, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        let sourceSidecarURL = ProvenanceRecorder.fileSidecarURL(for: sourceURL)
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, toSidecar: sourceSidecarURL)

        let bundleURL = temp.appendingPathComponent("cli-output.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let result = try FASTQAutoBundleWorkflow.wrapNakedFASTQ(
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            runtimeIdentity: .fixture()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceSidecarURL.path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(envelope.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertTrue(envelope.steps[0].outputs.contains { $0.path == result.payloadURL.path })
        XCTAssertTrue(envelope.steps[0].durableReplayArgv?.contains(result.payloadURL.path) == true)
        XCTAssertTrue(envelope.steps[1].outputs.contains { $0.path == bundleURL.path })
        XCTAssertFalse(envelope.outputs.contains { $0.path == sourceURL.path })
        XCTAssertFalse(envelope.steps.flatMap(\.outputs).contains { $0.path == sourceURL.path })
    }

    private var fastqText: String {
        """
        @read-1
        ACGT
        +
        IIII

        """
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
