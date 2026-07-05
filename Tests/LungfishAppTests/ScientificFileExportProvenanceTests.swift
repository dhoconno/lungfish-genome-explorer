// ScientificFileExportProvenanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
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
            startedAt: Date()
        ))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let input = try XCTUnwrap(envelope.files.first { $0.path == sourceDirectory.path && $0.role == .input })
        XCTAssertNotNil(input.checksumSHA256)
        XCTAssertEqual(input.checksumSHA256?.count, 64)
        XCTAssertEqual(input.fileSize, 11)
    }

    @MainActor
    func testSequenceContextMenuFASTAExportWritesScientificProvenanceSidecar() throws {
        let sourceURL = tempDir.appendingPathComponent("source.lungfishref", isDirectory: true)
        let outputURL = tempDir.appendingPathComponent("selected-sequence.fasta")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try ">source\nACGT\n".write(
            to: sourceURL.appendingPathComponent("reference.fasta"),
            atomically: true,
            encoding: .utf8
        )
        let sequence = try Sequence(
            name: "chr1",
            description: "visible track",
            alphabet: .dna,
            bases: String(repeating: "ACGT", count: 25)
        )

        let sidecarURL = try SequenceViewerView.writeSequenceFASTAExport(
            sequence,
            sourceURLs: [sourceURL],
            to: outputURL,
            startedAt: Date()
        )

        XCTAssertEqual(sidecarURL, ProvenanceRecorder.fileSidecarURL(for: outputURL))
        let fasta = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(fasta.hasPrefix(">chr1 visible track\n"))
        XCTAssertTrue(fasta.contains(String(repeating: "ACGT", count: 20)))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app sequence fasta export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.format, .fasta)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.explicit["sequenceName"]?.stringValue, "chr1")
        XCTAssertEqual(envelope.options.defaults["lineWidth"]?.integerValue, 80)
        XCTAssertEqual(envelope.options.resolvedDefaults["sequenceLength"]?.integerValue, sequence.length)
        XCTAssertEqual(envelope.options.resolvedDefaults["sourceCount"]?.integerValue, 1)
        XCTAssertTrue(envelope.argv.contains("--sequence"))
        XCTAssertTrue(envelope.files.contains { $0.path == sourceURL.path && $0.role == .input })
    }

    @MainActor
    func testSequenceContextMenuFASTAExportRemovesPayloadWhenProvenanceSidecarFails() throws {
        let outputURL = tempDir.appendingPathComponent("blocked-sidecar.fasta")
        try FileManager.default.createDirectory(
            at: ProvenanceRecorder.fileSidecarURL(for: outputURL),
            withIntermediateDirectories: true
        )
        let sequence = try Sequence(name: "chr1", alphabet: .dna, bases: "ACGT")

        XCTAssertThrowsError(
            try SequenceViewerView.writeSequenceFASTAExport(
                sequence,
                sourceURLs: [],
                to: outputURL,
                startedAt: Date()
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @MainActor
    func testSequenceContextMenuSourceURLsUseSingleDocumentOnlyWhenUnambiguous() throws {
        let sourceURL = tempDir.appendingPathComponent("single.fasta")
        try ">seq1\nACGT\n>seq2\nACGA\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let seq1 = try Sequence(name: "seq1", alphabet: .dna, bases: "ACGT")
        let seq2 = try Sequence(name: "seq2", alphabet: .dna, bases: "ACGA")
        let document = LoadedDocument(url: sourceURL, type: .fasta)
        document.sequences = [seq1, seq2]

        let viewController = ViewerViewController()
        _ = viewController.view
        viewController.displayDocuments([document])

        let state = try XCTUnwrap(viewController.viewerView.multiSequenceState)
        let secondInfo = try XCTUnwrap(state.stackedSequences.last)
        XCTAssertEqual(
            viewController.viewerView.sequenceFASTAExportSourceURLs(for: secondInfo),
            [sourceURL.standardizedFileURL]
        )
    }

    @MainActor
    func testSequenceContextMenuSourceURLsUseSelectedDocumentInMultiDocumentStack() throws {
        let firstURL = tempDir.appendingPathComponent("first.fasta")
        let secondURL = tempDir.appendingPathComponent("second.fasta")
        try ">first\nACGT\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try ">second\nTTTT\n".write(to: secondURL, atomically: true, encoding: .utf8)
        let firstSequence = try Sequence(name: "first", alphabet: .dna, bases: "ACGT")
        let secondSequence = try Sequence(name: "second", alphabet: .dna, bases: "TTTT")
        let firstDocument = LoadedDocument(url: firstURL, type: .fasta)
        firstDocument.sequences = [firstSequence]
        let secondDocument = LoadedDocument(url: secondURL, type: .fasta)
        secondDocument.sequences = [secondSequence]

        let viewController = ViewerViewController()
        _ = viewController.view
        viewController.displayDocuments([firstDocument, secondDocument])

        let state = try XCTUnwrap(viewController.viewerView.multiSequenceState)
        let secondInfo = try XCTUnwrap(state.stackedSequences.last)
        XCTAssertEqual(
            viewController.viewerView.sequenceFASTAExportSourceURLs(for: secondInfo),
            [secondURL.standardizedFileURL]
        )
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

    func testStandaloneScientificExportersWriteScientificProvenanceSidecars() throws {
        let root = repositoryRoot()
        let files = [
            ("Sources/LungfishApp/Views/Viewer/SequenceViewerView+Drawing.swift", "lungfish app sequence fasta export"),
            ("Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift", "lungfish app mapping result export"),
            ("Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift", "lungfish app phylogenetic subtree export"),
            ("Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift", "lungfish app naomgs summary export"),
            ("Sources/LungfishNvdUI/NvdResultViewController.swift", "lungfish app nvd contigs export"),
            ("Sources/LungfishEsVirituUI/EsVirituResultViewController.swift", "lungfish app esviritu detections export"),
            ("Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift", "lungfish app taxtriage results export"),
            ("Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift", "lungfish app taxtriage organism matrix export"),
            ("Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift", "lungfish app taxtriage batch report export"),
        ]

        for (path, workflowName) in files {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("ScientificFileExportProvenance.write(.init("), path)
            XCTAssertTrue(source.contains(#"workflowName: "\#(workflowName)""#), path)
        }

        let taxTriageSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(taxTriageSource.contains("try? csv.write(to:"))
        XCTAssertFalse(taxTriageSource.contains("try? report.write(to:"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
