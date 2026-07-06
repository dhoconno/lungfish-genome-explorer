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
            startedAt: Date()
        )) { tempURL in
            try "name\tcount\nalpha\t1\n".write(to: tempURL, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(sidecarURL, ProvenanceRecorder.fileSidecarURL(for: outputURL))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "name\tcount\nalpha\t1\n")
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
            startedAt: Date()
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
            startedAt: Date()
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
            startedAt: Date()
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
                startedAt: Date()
            )) { tempURL in
                try "new\n".write(to: tempURL, atomically: true, encoding: .utf8)
                throw CocoaError(.fileWriteUnknown)
            }
        )

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "old\n")
        XCTAssertEqual(try String(contentsOf: sidecarURL, encoding: .utf8), "old provenance\n")
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
                startedAt: Date()
            )) { tempURL in
                try "new\n".write(to: tempURL, atomically: true, encoding: .utf8)
            }
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            try String(contentsOf: outputURL.appendingPathComponent("manifest.json"), encoding: .utf8),
            "manifest\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: outputURL).path))
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
            ("Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift", "lungfish app taxonomy result export"),
            ("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Export.swift", "lungfish app annotation table export"),
            ("Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift", "lungfish app fastq metadata export"),
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

        let taxonomySource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(taxonomySource.contains("taxonomyExportSourceURLs"))
        XCTAssertTrue(taxonomySource.contains("taxonomyExportArgv"))

        let annotationExportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Export.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(annotationExportSource.contains("tableExportSourceURLs"))
        XCTAssertTrue(annotationExportSource.contains("sourceDatabasePaths"))

        let fastqMetadataSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fastqMetadataSource.contains("fastqMetadataExportSourceURLs"))
        XCTAssertTrue(fastqMetadataSource.contains("assignmentCount"))
    }

    func testImportCenterSequenceExportersWriteScientificProvenanceSidecars() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/LungfishApp/App/AppDelegate+ImportCenter.swift"),
            encoding: .utf8
        )
        let exportStart = try XCTUnwrap(source.range(of: "nonisolated private func performSequenceExport"))
        let batchTargetsStart = try XCTUnwrap(source.range(of: "nonisolated static func batchSequenceExportTargets"))
        let exportBody = source[exportStart.lowerBound..<batchTargetsStart.lowerBound]
        let referenceStart = try XCTUnwrap(source.range(of: "nonisolated private func performReferenceBundleSequenceExport"))
        let referenceEnd = try XCTUnwrap(source.range(of: "nonisolated private func sequenceForWholeChromosome"))
        let referenceBody = source[referenceStart.lowerBound..<referenceEnd.lowerBound]

        XCTAssertTrue(exportBody.contains("try Self.writeSequenceExportProvenance("))
        XCTAssertTrue(referenceBody.contains("try Self.writeSequenceExportProvenance("))
        XCTAssertTrue(source.contains(#"workflowName: "lungfish app sequence export""#))
        XCTAssertTrue(source.contains(#""compression": .string(compression.provenanceValue)"#))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
