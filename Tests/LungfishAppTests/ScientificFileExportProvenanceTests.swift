// ScientificFileExportProvenanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishApp
@testable import LungfishOperations
@testable import LungfishWorkflow
import LungfishTestSupport

final class ScientificFileExportProvenanceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScientificFileExportProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAtomicExportRejectsSidecarDirectoryAndPreservesPreviousExport() throws {
        let output = tempDir.appendingPathComponent("existing.tsv")
        let original = Data("old export".utf8)
        try original.write(to: output)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let marker = sidecar.appendingPathComponent("keep")
        try Data("old artifact".utf8).write(to: marker)
        XCTAssertThrowsError(try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "fixture", sourceURLs: [], outputURL: output, outputFormat: .text,
            argv: ["fixture"], runClock: ProvenanceRunClock()
        )) { staged in try Data("replacement".utf8).write(to: staged) })
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try Data(contentsOf: marker), Data("old artifact".utf8))
    }

    func testPublicationRollbackPreservesReplacementAndReportsRecoverableOldBytes() throws {
        let output = tempDir.appendingPathComponent("owned.txt")
        let staged = tempDir.appendingPathComponent("staged.txt")
        try Data("previous".utf8).write(to: output)
        try Data("attempted".utf8).write(to: staged)
        let publication = try ScientificFilePublicationTransaction(protectedURLs: [output], fileDestinations: [output])
        try publication.publish(stagedURL: staged, to: output)
        try Data("newer owner".utf8).write(to: output, options: .atomic)
        do {
            try publication.rollback(after: CocoaError(.fileWriteUnknown))
        } catch let error as ScientificPublicationRecoveryRequired {
            defer { for url in error.recoveryURLs { try? FileManager.default.removeItem(at: url) } }
            XCTAssertEqual(try Data(contentsOf: output), Data("newer owner".utf8))
            let backup = publication.recoveryDirectoryURL.appendingPathComponent("artifact-0")
            XCTAssertEqual(try Data(contentsOf: backup), Data("previous".utf8))
            XCTAssertFalse(error.originalErrorDescription.isEmpty)
            XCTAssertFalse(error.restorationErrorDescription.isEmpty)
        }
    }

    func testWriteCreatesFocusedSidecarWithChecksummedInputAndOutput() throws {
        let sourceURL = tempDir.appendingPathComponent("source.fa")
        let outputURL = tempDir.appendingPathComponent("export.fa")
        try ">seq\nACGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try ">seq\nACGT\n".write(to: outputURL, atomically: true, encoding: .utf8)

        let sidecarURL = try ScientificFileExportProvenance.write(.init(
            workflowName: "lungfish app fasta export",
            sourceURLs: [sourceURL],
            outputURL: outputURL,
            outputFormat: .fasta,
            argv: ["Lungfish.app", "export-fasta", sourceURL.path, "--output", outputURL.path],
            explicitOptions: [
                "sourcePath": .file(sourceURL),
                "outputPath": .file(outputURL),
            ],
            resolved: [
                "recordCount": .integer(1),
            ],
            runClock: ProvenanceRunClock()
        ))

        XCTAssertEqual(sidecarURL, ProvenanceRecorder.fileSidecarURL(for: outputURL))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app fasta export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.format, .fasta)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertNotNil(envelope.output?.fileSize)

        let input = try XCTUnwrap(envelope.files.first { $0.path == sourceURL.path && $0.role == .input })
        XCTAssertNotNil(input.checksumSHA256)
        XCTAssertNotNil(input.fileSize)
        XCTAssertEqual(envelope.options.resolvedDefaults["recordCount"]?.integerValue, 1)
    }

    func testWriteCreatesAggregateDescriptorForDirectoryInputs() throws {
        let sourceDirectory = tempDir.appendingPathComponent("source-bundle", isDirectory: true)
        let nestedDirectory = sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        let outputURL = tempDir.appendingPathComponent("export.tsv")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "alpha\n".write(to: sourceDirectory.appendingPathComponent("a.tsv"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: nestedDirectory.appendingPathComponent("b.tsv"), atomically: true, encoding: .utf8)
        try "alpha\tbeta\n".write(to: outputURL, atomically: true, encoding: .utf8)

        let sidecarURL = try ScientificFileExportProvenance.write(.init(
            workflowName: "lungfish app directory export",
            sourceURLs: [sourceDirectory],
            outputURL: outputURL,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-directory", "--output", outputURL.path],
            runClock: ProvenanceRunClock()
        ))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let input = try XCTUnwrap(envelope.files.first { $0.path == sourceDirectory.path && $0.role == .input })
        XCTAssertNotNil(input.checksumSHA256)
        XCTAssertEqual(input.checksumSHA256?.count, 64)
        XCTAssertEqual(input.fileSize, 11)
    }

    func testWriteAtomicallyPublishesFinalOutputAndSidecarDescriptors() throws {
        let sourceURL = tempDir.appendingPathComponent("source.tsv")
        let outputURL = tempDir.appendingPathComponent("export.tsv")
        try "name\tcount\nalpha\t1\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "old\n".write(to: outputURL, atomically: true, encoding: .utf8)
        try "old provenance\n".write(
            to: ProvenanceRecorder.fileSidecarURL(for: outputURL),
            atomically: true,
            encoding: .utf8
        )

        let sidecarURL = try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app atomic export",
            sourceURLs: [sourceURL],
            outputURL: outputURL,
            outputFormat: .text,
            argv: ["Lungfish.app", "atomic-export", "--output", outputURL.path],
            runClock: ProvenanceRunClock()
        )) { tempURL in
            try "name\tcount\nalpha\t1\n".write(to: tempURL, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(sidecarURL, ProvenanceRecorder.fileSidecarURL(for: outputURL))
        XCTAssertEqual(try readRepositorySource(outputURL), "name\tcount\nalpha\t1\n")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.format, .text)
        XCTAssertEqual(envelope.output?.fileSize, UInt64(Data("name\tcount\nalpha\t1\n".utf8).count))
        XCTAssertFalse(envelope.output?.path.contains(".export.tmp") ?? true)
        XCTAssertTrue(envelope.files.contains { $0.path == sourceURL.path && $0.role == .input })
    }

    func testWriteAtomicallySnapshotsDirectoryInputsBeforePayloadWrite() throws {
        let sourceDirectory = tempDir.appendingPathComponent("source-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("source.tsv")
        let outputURL = sourceDirectory.appendingPathComponent("export.tsv")
        let auxiliaryWriteURL = sourceDirectory.appendingPathComponent("auxiliary-write.tmp")
        try "source\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let sidecarURL = try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app atomic directory export",
            sourceURLs: [sourceDirectory],
            outputURL: outputURL,
            outputFormat: .text,
            argv: ["Lungfish.app", "atomic-directory-export", "--output", outputURL.path],
            runClock: ProvenanceRunClock()
        )) { tempURL in
            try "auxiliary\n".write(to: auxiliaryWriteURL, atomically: true, encoding: .utf8)
            try "export\n".write(to: tempURL, atomically: true, encoding: .utf8)
        }

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let input = try XCTUnwrap(envelope.files.first { $0.path == sourceDirectory.path && $0.role == .input })
        XCTAssertEqual(input.fileSize, try ProvenanceFileHasher.fileSize(of: sourceURL))
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
    }

    func testWriteAtomicallyExcludesExistingOutputAndSidecarFromDirectoryInputs() throws {
        let sourceDirectory = tempDir.appendingPathComponent("source-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("source.tsv")
        let outputURL = sourceDirectory.appendingPathComponent("export.tsv")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        try "source\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "old export\n".write(to: outputURL, atomically: true, encoding: .utf8)
        try "old sidecar\n".write(to: sidecarURL, atomically: true, encoding: .utf8)

        let writtenSidecarURL = try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app atomic directory export",
            sourceURLs: [sourceDirectory],
            outputURL: outputURL,
            outputFormat: .text,
            argv: ["Lungfish.app", "atomic-directory-export", "--output", outputURL.path],
            runClock: ProvenanceRunClock()
        )) { tempURL in
            try "new export\n".write(to: tempURL, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(writtenSidecarURL, sidecarURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let input = try XCTUnwrap(envelope.files.first { $0.path == sourceDirectory.path && $0.role == .input })
        XCTAssertEqual(input.fileSize, try ProvenanceFileHasher.fileSize(of: sourceURL))
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
    }

    func testWriteAtomicallyCompletedAtIncludesPayloadWrite() throws {
        let sourceURL = tempDir.appendingPathComponent("source.tsv")
        let outputURL = tempDir.appendingPathComponent("export.tsv")
        try "source\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let sidecarURL = try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app atomic export",
            sourceURLs: [sourceURL],
            outputURL: outputURL,
            outputFormat: .text,
            argv: ["Lungfish.app", "atomic-export", "--output", outputURL.path],
            runClock: ProvenanceRunClock()
        )) { tempURL in
            try "export\n".write(to: tempURL, atomically: true, encoding: .utf8)
            Thread.sleep(forTimeInterval: 0.02)
        }

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? 0, 0.02)
        XCTAssertGreaterThanOrEqual(envelope.steps.first?.wallTimeSeconds ?? 0, 0.02)
    }

    func testWriteAtomicallyKeepsExistingOutputWhenPayloadWriteFails() throws {
        let sourceURL = tempDir.appendingPathComponent("source.tsv")
        let outputURL = tempDir.appendingPathComponent("export.tsv")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        try "source\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "old\n".write(to: outputURL, atomically: true, encoding: .utf8)
        try "old provenance\n".write(to: sidecarURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ScientificFileExportProvenance.writeAtomically(.init(
                workflowName: "lungfish app atomic export",
                sourceURLs: [sourceURL],
                outputURL: outputURL,
                outputFormat: .text,
                argv: ["Lungfish.app", "atomic-export", "--output", outputURL.path],
                runClock: ProvenanceRunClock()
            )) { tempURL in
                try "new\n".write(to: tempURL, atomically: true, encoding: .utf8)
                throw CocoaError(.fileWriteUnknown)
            }
        )

        XCTAssertEqual(try readRepositorySource(outputURL), "old\n")
        XCTAssertEqual(try readRepositorySource(sidecarURL), "old provenance\n")
    }

    func testWriteAtomicallyRefusesToReplaceExistingDirectory() throws {
        let sourceURL = tempDir.appendingPathComponent("source.tsv")
        let outputURL = tempDir.appendingPathComponent("Existing.lungfishref", isDirectory: true)
        try "source\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try "manifest\n".write(
            to: outputURL.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try ScientificFileExportProvenance.writeAtomically(.init(
                workflowName: "lungfish app atomic export",
                sourceURLs: [sourceURL],
                outputURL: outputURL,
                outputFormat: .text,
                argv: ["Lungfish.app", "atomic-export", "--output", outputURL.path],
                runClock: ProvenanceRunClock()
            )) { tempURL in
                try "new\n".write(to: tempURL, atomically: true, encoding: .utf8)
            }
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            try readRepositorySource(outputURL.appendingPathComponent("manifest.json")),
            "manifest\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: outputURL).path))
    }

    func testStandaloneScientificExportersWriteScientificProvenanceSidecars() throws {
        let root = repositoryRoot()
        let files = [
            ("Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift", "lungfish app taxtriage results export"),
        ]

        for (path, workflowName) in files {
            let source = try readRepositorySource(root.appendingPathComponent(path))
            XCTAssertTrue(
                source.contains("ScientificFileExportProvenance.write(.init(")
                    || source.contains("ScientificFileExportProvenance.writeAtomically(.init("),
                path
            )
            XCTAssertTrue(source.contains(#"workflowName: "\#(workflowName)""#), path)
        }

        let taxTriageSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(taxTriageSource.contains("try? csv.write(to:"))
        XCTAssertFalse(taxTriageSource.contains("try? report.write(to:"))


        let annotationExportCapture = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+ExportCapture.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(annotationExportCapture.contains("scientificTableExportSources(columns: columns)"))
        XCTAssertTrue(annotationExportCapture.contains("variantFormatOverlaySnapshot.sourceIdentities"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
