import XCTest
@testable import LungfishWorkflow

final class ProvenanceRehydrationTests: XCTestCase {
    func testRehydrateCopiesCanonicalProvenanceAndRewritesMappedOutputs() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let finalDirectory = tempDir.appendingPathComponent("bundle.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        let stagedOutputURL = sourceDirectory.appendingPathComponent("staged.fastq")
        let finalOutputURL = finalDirectory.appendingPathComponent("payload.fastq.gz")
        try Data("@in\nACGT\n+\n!!!!\n".utf8).write(to: inputURL, options: .atomic)
        try Data("@out\nACG\n+\n!!!\n".utf8).write(to: stagedOutputURL, options: .atomic)
        try Data("@out\nACG\n+\n!!!\n".utf8).write(to: finalOutputURL, options: .atomic)
        let inputDescriptor = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: stagedOutputURL, format: .fastq, role: .output)

        let envelope = try ProvenanceRunBuilder(
            workflowName: "Deacon rRNA FASTQ filter",
            workflowVersion: "2026.05",
            toolName: "deacon",
            toolVersion: "0.15.0"
        )
        .argv(["deacon", "filter", inputURL.path, "-o", stagedOutputURL.path])
        .input(inputURL, format: .fastq, role: .input)
        .output(stagedOutputURL, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "deacon",
                toolVersion: "0.15.0",
                argv: ["deacon", "filter", inputURL.path, "-o", stagedOutputURL.path],
                inputs: [inputDescriptor],
                outputs: [outputDescriptor],
                exitStatus: 0,
                wallTimeSeconds: 2
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 12)
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: sourceDirectory)

        let rehydrated = try ProvenanceRehydrator.rehydrate(
            sourceDirectory: sourceDirectory,
            finalDirectory: finalDirectory,
            pathMap: [stagedOutputURL.path: finalOutputURL.path]
        )

        let sourceProvenancePath = sourceDirectory
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            .path
        XCTAssertEqual(rehydrated.workflowName, "Deacon rRNA FASTQ filter")
        XCTAssertEqual(rehydrated.output?.path, finalOutputURL.path)
        XCTAssertEqual(rehydrated.outputs.map(\.path), [finalOutputURL.path])
        XCTAssertEqual(rehydrated.steps.first?.outputs.map(\.path), [finalOutputURL.path])
        XCTAssertEqual(rehydrated.steps.first?.inputs.map(\.path), [inputURL.path])
        XCTAssertEqual(rehydrated.output?.originPath, stagedOutputURL.path)
        XCTAssertEqual(rehydrated.output?.sourceProvenancePath, sourceProvenancePath)
        XCTAssertEqual(rehydrated.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: finalOutputURL))
        XCTAssertEqual(rehydrated.output?.fileSize, try ProvenanceFileHasher.fileSize(of: finalOutputURL))
        XCTAssertTrue(rehydrated.signatures.isEmpty)

        let decoded = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: finalDirectory))
        XCTAssertEqual(decoded.output?.path, finalOutputURL.path)
        XCTAssertEqual(decoded.output?.originPath, stagedOutputURL.path)
        XCTAssertEqual(decoded.output?.sourceProvenancePath, sourceProvenancePath)

        let legacy = try XCTUnwrap(ProvenanceRecorder.load(from: finalDirectory))
        XCTAssertEqual(legacy.steps.first?.outputs.first?.path, finalOutputURL.path)
    }

    func testRehydrateThrowsWhenOutputDescriptorHasNoPathMap() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let finalDirectory = tempDir.appendingPathComponent("bundle.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let stagedOutputURL = sourceDirectory.appendingPathComponent("staged.fastq")
        try Data("@out\nACG\n+\n!!!\n".utf8).write(to: stagedOutputURL, options: .atomic)
        let envelope = ProvenanceEnvelope.fixture(outputPath: stagedOutputURL.path)
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: sourceDirectory)

        XCTAssertThrowsError(
            try ProvenanceRehydrator.rehydrate(
                sourceDirectory: sourceDirectory,
                finalDirectory: finalDirectory,
                pathMap: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ProvenanceRehydrationError, .outputPathNotMapped(stagedOutputURL.path))
        }
    }

    func testRehydrateThrowsWhenSourceSidecarIsMissing() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let finalDirectory = tempDir.appendingPathComponent("bundle.lungfishfastq", isDirectory: true)

        XCTAssertThrowsError(
            try ProvenanceRehydrator.rehydrate(
                sourceDirectory: sourceDirectory,
                finalDirectory: finalDirectory,
                pathMap: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ProvenanceRehydrationError, .missingSourceProvenance(sourceDirectory.path))
        }
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-rehydration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
