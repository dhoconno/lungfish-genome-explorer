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

    func testSelectedOutputProjectionKeepsIntermediateProducerSteps() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let finalDirectory = tempDir.appendingPathComponent("bundle.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        let intermediateURL = sourceDirectory.appendingPathComponent("intermediate.fastq")
        let selectedURL = sourceDirectory.appendingPathComponent("selected.fastq")
        let siblingURL = sourceDirectory.appendingPathComponent("sibling.fastq")
        let finalOutputURL = finalDirectory.appendingPathComponent("payload.fastq.gz")
        try Data("@in\nACGT\n+\n!!!!\n".utf8).write(to: inputURL, options: .atomic)
        try Data("@mid\nACG\n+\n!!!\n".utf8).write(to: intermediateURL, options: .atomic)
        try Data("@sel\nAC\n+\n!!\n".utf8).write(to: selectedURL, options: .atomic)
        try Data("@sib\nGT\n+\n!!\n".utf8).write(to: siblingURL, options: .atomic)
        try Data("@sel\nAC\n+\n!!\n".utf8).write(to: finalOutputURL, options: .atomic)

        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let intermediateOutput = try ProvenanceFileDescriptor.file(url: intermediateURL, format: .fastq, role: .output)
        let intermediateInput = ProvenanceFileDescriptor(
            path: intermediateOutput.path,
            checksumSHA256: intermediateOutput.checksumSHA256,
            fileSize: intermediateOutput.fileSize,
            format: intermediateOutput.format,
            role: .input
        )
        let selectedOutput = try ProvenanceFileDescriptor.file(url: selectedURL, format: .fastq, role: .output)
        let siblingOutput = try ProvenanceFileDescriptor.file(url: siblingURL, format: .fastq, role: .output)
        let producerStepID = UUID()
        let selectedStepID = UUID()
        let producerStep = ProvenanceStep(
            id: producerStepID,
            toolName: "fastq-prep",
            toolVersion: "1.0",
            argv: ["fastq-prep", inputURL.path, "-o", intermediateURL.path],
            inputs: [input],
            outputs: [intermediateOutput],
            exitStatus: 0
        )
        let selectedStep = ProvenanceStep(
            id: selectedStepID,
            toolName: "fastq-split",
            toolVersion: "1.0",
            argv: ["fastq-split", intermediateURL.path, "--selected", selectedURL.path, "--sibling", siblingURL.path],
            inputs: [intermediateInput],
            outputs: [selectedOutput, siblingOutput],
            exitStatus: 0,
            dependsOn: [producerStepID]
        )
        let envelope = try ProvenanceRunBuilder(
            workflowName: "split selected FASTQ",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fastq", "split"])
        .input(inputURL, format: .fastq, role: .input)
        .output(selectedURL, format: .fastq, role: .output)
        .output(siblingURL, format: .fastq, role: .output)
        .step(producerStep)
        .step(selectedStep)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 23)
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: sourceDirectory)

        let rehydrated = try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: sourceDirectory,
            finalDirectory: finalDirectory,
            pathMap: [selectedURL.path: finalOutputURL.path]
        )

        XCTAssertEqual(rehydrated.output?.path, finalOutputURL.path)
        XCTAssertEqual(rehydrated.outputs.map(\.path), [finalOutputURL.path])
        XCTAssertEqual(rehydrated.steps.map(\.id), [producerStepID, selectedStepID])
        XCTAssertEqual(rehydrated.steps[0].outputs.map(\.path), [intermediateURL.path])
        XCTAssertEqual(rehydrated.steps[1].inputs.map(\.path), [intermediateURL.path])
        XCTAssertEqual(rehydrated.steps[1].outputs.map(\.path), [finalOutputURL.path])
        XCTAssertFalse(rehydrated.files.contains { $0.path == siblingURL.path })
        XCTAssertTrue(rehydrated.files.contains { $0.path == intermediateURL.path && $0.role == .output })
        XCTAssertTrue(rehydrated.files.contains { $0.path == finalOutputURL.path && $0.role == .output })
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
