import XCTest
@testable import LungfishWorkflow

final class GUIImportedProvenanceRehydratorTests: XCTestCase {
    func testImportedPayloadPreservesCLIStepAndAddsGUIImportStepWithFinalOutputPath() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("Project/Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let stagedFASTQ = stagingDirectory.appendingPathComponent("download.fastq")
        let finalFASTQ = bundleURL.appendingPathComponent("download.fastq")
        let contents = Data("@r\nACGT\n+\n!!!!\n".utf8)
        try contents.write(to: stagedFASTQ, options: .atomic)
        try contents.write(to: finalFASTQ, options: .atomic)

        let sourceSidecarURL = ProvenanceRecorder.fileSidecarURL(for: stagedFASTQ)
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Download",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", stagedFASTQ.path])
        .output(stagedFASTQ, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", stagedFASTQ.path],
                inputs: [],
                outputs: [try ProvenanceFileDescriptor.file(url: stagedFASTQ, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1.5
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11.5)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, toSidecar: sourceSidecarURL)

        let rehydrated = try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(
            from: stagedFASTQ,
            to: finalFASTQ
        )

        XCTAssertEqual(rehydrated.workflowName, "CLI FASTQ Download")
        XCTAssertEqual(rehydrated.output?.path, finalFASTQ.path)
        XCTAssertEqual(rehydrated.outputs.map(\.path), [finalFASTQ.path])
        XCTAssertEqual(rehydrated.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertEqual(rehydrated.steps[0].outputs.map(\.path), [finalFASTQ.path])
        XCTAssertEqual(rehydrated.steps[0].outputs.first?.originPath, stagedFASTQ.path)
        XCTAssertEqual(rehydrated.steps[0].outputs.first?.sourceProvenancePath, sourceSidecarURL.path)
        XCTAssertEqual(rehydrated.steps[0].argv.last, stagedFASTQ.path)
        XCTAssertEqual(rehydrated.steps[0].durableReplayArgv?.last, finalFASTQ.path)
        XCTAssertTrue(rehydrated.steps[1].argv.contains("gui-import"))
        XCTAssertEqual(rehydrated.steps[1].outputs.map(\.path), [finalFASTQ.path])
        XCTAssertFalse(rehydrated.files.contains { $0.role == .output && $0.path == stagedFASTQ.path })

        let stored = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(stored.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertEqual(stored.output?.path, finalFASTQ.path)
    }

    func testImportedBundleRehydratesNestedCLIOutputsIntoCopiedBundle() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = tempDir.appendingPathComponent("staging/Source.lungfishfastq", isDirectory: true)
        let destinationBundle = tempDir.appendingPathComponent("Project/Source.lungfishfastq", isDirectory: true)
        let sourcePayload = sourceBundle.appendingPathComponent("reads/source.fastq")
        let destinationPayload = destinationBundle.appendingPathComponent("reads/source.fastq")
        try FileManager.default.createDirectory(at: sourcePayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationPayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("@r\nTGCA\n+\n!!!!\n".utf8).write(to: sourcePayload, options: .atomic)
        try Data("@r\nTGCA\n+\n!!!!\n".utf8).write(to: destinationPayload, options: .atomic)

        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Bundle Import",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "import", "fastq", "--bundle", sourceBundle.path])
        .output(sourcePayload, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "import", "fastq", "--bundle", sourceBundle.path],
                outputs: [try ProvenanceFileDescriptor.file(url: sourcePayload, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 2
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 22)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, to: sourceBundle)

        let rehydrated = try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(
            from: sourceBundle,
            to: destinationBundle
        )

        XCTAssertEqual(rehydrated.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertEqual(rehydrated.output?.path, destinationPayload.path)
        XCTAssertEqual(rehydrated.outputs.map(\.path), [destinationPayload.path])
        XCTAssertEqual(rehydrated.steps[0].outputs.map(\.path), [destinationPayload.path])
        XCTAssertEqual(rehydrated.steps[0].outputs.first?.originPath, sourcePayload.path)
        XCTAssertEqual(rehydrated.steps[0].durableReplayArgv?.last, destinationBundle.path)
        XCTAssertFalse(rehydrated.outputs.contains { $0.path.hasPrefix(sourceBundle.path) })

        let stored = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: destinationBundle))
        XCTAssertEqual(stored.output?.path, destinationPayload.path)
        XCTAssertEqual(stored.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
    }

    func testImportedSinglePayloadFromMultiOutputSidecarDoesNotRequireSiblingOutputsToBeCopied() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("Project/Multi.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let copiedSource = stagingDirectory.appendingPathComponent("copied.fastq")
        let siblingSource = stagingDirectory.appendingPathComponent("sibling.fastq")
        let copiedDestination = bundleURL.appendingPathComponent("copied.fastq")
        try Data("@copied\nACGT\n+\n!!!!\n".utf8).write(to: copiedSource, options: .atomic)
        try Data("@sibling\nTGCA\n+\n!!!!\n".utf8).write(to: siblingSource, options: .atomic)
        try Data("@copied\nACGT\n+\n!!!!\n".utf8).write(to: copiedDestination, options: .atomic)

        let sourceSidecarURL = ProvenanceRecorder.fileSidecarURL(for: copiedSource)
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI Multi FASTQ Export",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "multi", "--output", copiedSource.path])
        .output(copiedSource, format: .fastq, role: .output)
        .output(siblingSource, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "multi", "--output", copiedSource.path],
                outputs: [
                    try ProvenanceFileDescriptor.file(url: copiedSource, format: .fastq, role: .output),
                    try ProvenanceFileDescriptor.file(url: siblingSource, format: .fastq, role: .output)
                ],
                exitStatus: 0,
                wallTimeSeconds: 2
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 30),
            endedAt: Date(timeIntervalSince1970: 32)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, toSidecar: sourceSidecarURL)

        let rehydrated = try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(
            from: copiedSource,
            to: copiedDestination
        )

        XCTAssertEqual(rehydrated.output?.path, copiedDestination.path)
        XCTAssertEqual(rehydrated.outputs.map(\.path), [copiedDestination.path])
        XCTAssertEqual(rehydrated.steps[0].outputs.map(\.path), [copiedDestination.path])
        XCTAssertFalse(rehydrated.files.contains { $0.role == .output && $0.path.hasSuffix("sibling.fastq") })

        let stored = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(stored.outputs.map(\.path), [copiedDestination.path])
        XCTAssertEqual(stored.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
    }

    func testImportedFileSidecarPreservesCLIProvenanceWithoutOverwritingBundleRoot() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("Project/Sample.lungfishfastq", isDirectory: true)
        let attachmentsDirectory = bundleURL.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

        let sourceFASTQ = stagingDirectory.appendingPathComponent("reads.fastq")
        let siblingFASTQ = stagingDirectory.appendingPathComponent("sibling.fastq")
        let attachedFASTQ = attachmentsDirectory.appendingPathComponent("reads-2.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceFASTQ, options: .atomic)
        try Data("@s\nTGCA\n+\n!!!!\n".utf8).write(to: siblingFASTQ, options: .atomic)
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: attachedFASTQ, options: .atomic)

        let rootProvenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("{\"root\":true}\n".utf8).write(to: rootProvenanceURL, options: .atomic)

        let sourceSidecarURL = ProvenanceRecorder.fileSidecarURL(for: sourceFASTQ)
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Attachment Source",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceFASTQ.path])
        .output(sourceFASTQ, format: .fastq, role: .output)
        .output(siblingFASTQ, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceFASTQ.path],
                outputs: [
                    try ProvenanceFileDescriptor.file(url: sourceFASTQ, format: .fastq, role: .output),
                    try ProvenanceFileDescriptor.file(url: siblingFASTQ, format: .fastq, role: .output),
                ],
                exitStatus: 0,
                wallTimeSeconds: 1.5
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11.5)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, toSidecar: sourceSidecarURL)

        let rehydrated = try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(
            from: sourceFASTQ,
            to: attachedFASTQ
        )

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: attachedFASTQ)
        let stored = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(rehydrated.output?.path, attachedFASTQ.path)
        XCTAssertEqual(stored.output?.path, attachedFASTQ.path)
        XCTAssertEqual(stored.output?.originPath, sourceFASTQ.path)
        XCTAssertEqual(stored.output?.sourceProvenancePath, sourceSidecarURL.path)
        XCTAssertEqual(stored.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: attachedFASTQ))
        XCTAssertEqual(stored.outputs.map(\.path), [attachedFASTQ.path])
        XCTAssertEqual(stored.steps[0].outputs.map(\.path), [attachedFASTQ.path])
        XCTAssertEqual(stored.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertEqual(stored.steps[0].durableReplayArgv?.last, attachedFASTQ.path)
        XCTAssertFalse(stored.files.contains { $0.role == .output && $0.path == siblingFASTQ.path })
        XCTAssertEqual(try Data(contentsOf: rootProvenanceURL), Data("{\"root\":true}\n".utf8))
    }

    func testImportedFileSidecarRejectsUnrelatedCLIOutputProvenance() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let attachmentsDirectory = tempDir.appendingPathComponent("Project/Sample.lungfishfastq/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

        let sourceFASTQ = stagingDirectory.appendingPathComponent("reads.fastq")
        let unrelatedFASTQ = stagingDirectory.appendingPathComponent("other.fastq")
        let attachedFASTQ = attachmentsDirectory.appendingPathComponent("reads.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceFASTQ, options: .atomic)
        try Data("@o\nTGCA\n+\n!!!!\n".utf8).write(to: unrelatedFASTQ, options: .atomic)
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: attachedFASTQ, options: .atomic)

        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Other Output",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR999", "--output", unrelatedFASTQ.path])
        .output(unrelatedFASTQ, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR999", "--output", unrelatedFASTQ.path],
                outputs: [try ProvenanceFileDescriptor.file(url: unrelatedFASTQ, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1.5
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11.5)
        )
        try ProvenanceWriter(signingProvider: nil).write(
            cliEnvelope,
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: sourceFASTQ)
        )

        XCTAssertThrowsError(
            try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(
                from: sourceFASTQ,
                to: attachedFASTQ
            )
        ) { error in
            XCTAssertEqual(error as? ProvenanceRehydrationError, .outputPathNotMapped(sourceFASTQ.path))
        }
    }

    func testImportedFileSidecarRejectsStaleSamePathCLIOutputProvenance() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let attachmentsDirectory = tempDir.appendingPathComponent("Project/Sample.lungfishfastq/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

        let sourceFASTQ = stagingDirectory.appendingPathComponent("reads.fastq")
        let attachedFASTQ = attachmentsDirectory.appendingPathComponent("reads.fastq")
        try Data("@old\nAAAA\n+\n!!!!\n".utf8).write(to: sourceFASTQ, options: .atomic)
        let staleOutputDescriptor = try ProvenanceFileDescriptor.file(url: sourceFASTQ, format: .fastq, role: .output)
        try Data("@new\nCCCC\n+\n!!!!\n".utf8).write(to: sourceFASTQ, options: .atomic)
        try Data("@new\nCCCC\n+\n!!!!\n".utf8).write(to: attachedFASTQ, options: .atomic)

        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Stale Output",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceFASTQ.path])
        .output(sourceFASTQ, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceFASTQ.path],
                outputs: [staleOutputDescriptor],
                exitStatus: 0,
                wallTimeSeconds: 1.5
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11.5)
        )
        try ProvenanceWriter(signingProvider: nil).write(
            cliEnvelope,
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: sourceFASTQ)
        )

        XCTAssertThrowsError(
            try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(
                from: sourceFASTQ,
                to: attachedFASTQ
            )
        ) { error in
            XCTAssertEqual(
                error as? GUIImportedProvenanceRehydratorError,
                .sourceOutputIntegrityMismatch(sourceFASTQ.path)
            )
        }
    }

    func testImportedCopyRejectsStaleSamePathCLIOutputProvenance() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDirectory = tempDir.appendingPathComponent("staging", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("Project/Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sourceFASTQ = stagingDirectory.appendingPathComponent("reads.fastq")
        let finalFASTQ = bundleURL.appendingPathComponent("reads.fastq")
        try Data("@old\nAAAA\n+\n!!!!\n".utf8).write(to: sourceFASTQ, options: .atomic)
        let staleOutputDescriptor = try ProvenanceFileDescriptor.file(url: sourceFASTQ, format: .fastq, role: .output)
        try Data("@new\nCCCC\n+\n!!!!\n".utf8).write(to: sourceFASTQ, options: .atomic)
        try Data("@new\nCCCC\n+\n!!!!\n".utf8).write(to: finalFASTQ, options: .atomic)

        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Stale Copy",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceFASTQ.path])
        .output(sourceFASTQ, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceFASTQ.path],
                outputs: [staleOutputDescriptor],
                exitStatus: 0,
                wallTimeSeconds: 1.5
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11.5)
        )
        try ProvenanceWriter(signingProvider: nil).write(
            cliEnvelope,
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: sourceFASTQ)
        )

        XCTAssertThrowsError(
            try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(
                from: sourceFASTQ,
                to: finalFASTQ
            )
        ) { error in
            XCTAssertEqual(
                error as? GUIImportedProvenanceRehydratorError,
                .sourceOutputIntegrityMismatch(sourceFASTQ.path)
            )
        }
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gui-imported-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
