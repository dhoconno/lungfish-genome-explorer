// AttachmentImportProvenanceTests.swift - Generic attachment provenance guardrail coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class AttachmentImportProvenanceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentImportProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOrdinaryDocumentAttachmentDoesNotRequireProvenance() throws {
        let bundleURL = tempDir.appendingPathComponent("ResultBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let reportURL = tempDir.appendingPathComponent("report.pdf")
        try Data("%PDF placeholder\n".utf8).write(to: reportURL, options: .atomic)

        let store = BundleAttachmentStore(bundleURL: bundleURL)
        let filename = try ProvenanceAwareAttachmentImporter.attach(fileAt: reportURL, to: store)

        let attachedURL = store.urlForAttachment(filename)
        XCTAssertEqual(filename, "report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: attachedURL).path))
    }

    func testScientificAttachmentWithoutCLIProvenanceIsRejectedAndExistingAttachmentRestored() throws {
        let bundleURL = tempDir.appendingPathComponent("ResultBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let store = BundleAttachmentStore(bundleURL: bundleURL)
        try FileManager.default.createDirectory(at: store.attachmentsDirectory, withIntermediateDirectories: true)

        let existingURL = store.urlForAttachment("reads.fastq")
        let existingSidecarURL = ProvenanceRecorder.fileSidecarURL(for: existingURL)
        try Data("old reads\n".utf8).write(to: existingURL, options: .atomic)
        try Data("old sidecar\n".utf8).write(to: existingSidecarURL, options: .atomic)

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)

        XCTAssertThrowsError(
            try ProvenanceAwareAttachmentImporter.attach(fileAt: sourceURL, to: store)
        ) { error in
            XCTAssertTrue(error is GenericAttachmentValidationError)
        }

        XCTAssertEqual(try Data(contentsOf: existingURL), Data("old reads\n".utf8))
        XCTAssertEqual(try Data(contentsOf: existingSidecarURL), Data("old sidecar\n".utf8))
    }

    func testScientificAttachmentWithCLISidecarGetsAdjacentRehydratedSidecar() throws {
        let bundleURL = tempDir.appendingPathComponent("ResultBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let rootProvenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("{\"root\":true}\n".utf8).write(to: rootProvenanceURL, options: .atomic)

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)
        let sourceSidecarURL = try writeCLISidecar(for: sourceURL)

        let store = BundleAttachmentStore(bundleURL: bundleURL)
        let filename = try ProvenanceAwareAttachmentImporter.attach(fileAt: sourceURL, to: store)

        let attachedURL = store.urlForAttachment(filename)
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: attachedURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.output?.path, attachedURL.path)
        XCTAssertEqual(envelope.output?.originPath, sourceURL.path)
        XCTAssertEqual(envelope.output?.sourceProvenancePath, sourceSidecarURL.path)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: attachedURL))
        XCTAssertEqual(envelope.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertEqual(try Data(contentsOf: rootProvenanceURL), Data("{\"root\":true}\n".utf8))
        XCTAssertEqual(store.attachments.map(\.filename), ["reads.fastq"])
    }

    func testScientificAttachmentRejectsSidecarThatDoesNotDescribeSourceOutput() throws {
        let bundleURL = tempDir.appendingPathComponent("ResultBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        let unrelatedURL = tempDir.appendingPathComponent("other.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)
        try Data("@o\nTGCA\n+\n!!!!\n".utf8).write(to: unrelatedURL, options: .atomic)
        try writeCLISidecar(for: unrelatedURL, sidecarTargetURL: sourceURL)

        let store = BundleAttachmentStore(bundleURL: bundleURL)

        XCTAssertThrowsError(
            try ProvenanceAwareAttachmentImporter.attach(fileAt: sourceURL, to: store)
        ) { error in
            XCTAssertTrue(error is GenericAttachmentValidationError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.urlForAttachment("reads.fastq").path))
        XCTAssertTrue(store.attachments.isEmpty)
    }

    func testScientificAttachmentRejectsStaleSidecarForSameSourcePath() throws {
        let bundleURL = tempDir.appendingPathComponent("ResultBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try Data("@old\nAAAA\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)
        try writeCLISidecar(for: sourceURL)
        try Data("@new\nCCCC\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)

        let store = BundleAttachmentStore(bundleURL: bundleURL)

        XCTAssertThrowsError(
            try ProvenanceAwareAttachmentImporter.attach(fileAt: sourceURL, to: store)
        ) { error in
            XCTAssertTrue(error is GenericAttachmentValidationError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.urlForAttachment("reads.fastq").path))
        XCTAssertTrue(store.attachments.isEmpty)
    }

    @MainActor
    func testFASTQMetadataAttachmentRejectsScientificFileWithoutMutatingMetadata() throws {
        let bundleURL = tempDir.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)

        let viewModel = FASTQMetadataSectionViewModel()
        viewModel.load(from: bundleURL)
        viewModel.addAttachment(from: sourceURL)

        XCTAssertTrue(viewModel.attachmentFilenames.isEmpty)
        XCTAssertNil(viewModel.metadata?.attachments)
        XCTAssertNotNil(viewModel.attachmentErrorMessage)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent(BundleAttachmentManager.attachmentsDirectoryName, isDirectory: true)
                    .appendingPathComponent("reads.fastq")
                    .path
            )
        )
    }

    func testFASTQAttachmentManagerPreservesProvenanceWhenDuplicateNameIsRenamed() throws {
        let bundleURL = tempDir.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        let attachmentsDirectory = bundleURL.appendingPathComponent(
            BundleAttachmentManager.attachmentsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        try Data("existing\n".utf8).write(
            to: attachmentsDirectory.appendingPathComponent("reads.fastq"),
            options: .atomic
        )

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: sourceURL, options: .atomic)
        let sourceSidecarURL = try writeCLISidecar(for: sourceURL)

        let manager = BundleAttachmentManager(bundleURL: bundleURL)
        let filename = try ProvenanceAwareAttachmentImporter.addAttachment(from: sourceURL, using: manager)

        XCTAssertEqual(filename, "reads-2.fastq")
        let attachedURL = manager.urlForAttachment(filename)
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: attachedURL))
        )
        XCTAssertEqual(envelope.output?.path, attachedURL.path)
        XCTAssertEqual(envelope.output?.originPath, sourceURL.path)
        XCTAssertEqual(envelope.output?.sourceProvenancePath, sourceSidecarURL.path)
        XCTAssertEqual(Set(manager.listAttachments()), ["reads.fastq", "reads-2.fastq"])
    }

    func testScientificAttachmentSidecarObstructionPreservesOldPayloadAndArtifact() throws {
        let bundle = tempDir.appendingPathComponent("ResultBundle", isDirectory: true)
        let store = BundleAttachmentStore(bundleURL: bundle)
        try FileManager.default.createDirectory(at: store.attachmentsDirectory, withIntermediateDirectories: true)
        let destination = store.urlForAttachment("reads.fastq")
        try Data("old attachment".utf8).write(to: destination)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: destination)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let marker = sidecar.appendingPathComponent("retained.txt")
        try Data("old artifact".utf8).write(to: marker)
        let source = tempDir.appendingPathComponent("reads.fastq")
        try Data("synthetic replacement".utf8).write(to: source)
        try writeCLISidecar(for: source)

        XCTAssertThrowsError(try ProvenanceAwareAttachmentImporter.attach(fileAt: source, to: store))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old attachment".utf8))
        XCTAssertEqual(try Data(contentsOf: marker), Data("old artifact".utf8))
    }

    @discardableResult
    private func writeCLISidecar(for outputURL: URL, sidecarTargetURL: URL? = nil) throws -> URL {
        let envelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Attachment Source",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", outputURL.path])
        .output(outputURL, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", outputURL.path],
                outputs: [try ProvenanceFileDescriptor.file(url: outputURL, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: sidecarTargetURL ?? outputURL)
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
        return sidecarURL
    }
}
