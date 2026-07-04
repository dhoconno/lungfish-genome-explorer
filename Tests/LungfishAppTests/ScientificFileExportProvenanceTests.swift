// ScientificFileExportProvenanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

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
            startedAt: Date()
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

    func testFASTAExporterWritesScientificProvenanceSidecar() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController.swift"),
            encoding: .utf8
        )

        let body = try XCTUnwrap(source.range(of: "func exportFASTARecords"))
        let exportBody = source[body.lowerBound...]
        XCTAssertTrue(exportBody.contains("ScientificFileExportProvenance.write(.init("))
        XCTAssertTrue(exportBody.contains(#"workflowName: "lungfish app fasta export""#))
        XCTAssertTrue(exportBody.contains("try normalized.write(to: destination"))
        XCTAssertFalse(exportBody.contains("try? normalized.write(to: destination"))
    }

    func testBookmarkedVariantExporterWritesScientificProvenanceSidecar() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Bookmarks.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ScientificFileExportProvenance.write(.init("))
        XCTAssertTrue(source.contains(#"workflowName: "lungfish app bookmarked variant export""#))
        XCTAssertTrue(source.contains("bookmarkedVariantExportSourceURLs"))
        XCTAssertTrue(source.contains("try? FileManager.default.removeItem(at: url)"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
