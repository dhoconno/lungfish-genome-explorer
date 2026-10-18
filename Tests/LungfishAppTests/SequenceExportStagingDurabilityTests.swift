// SequenceExportStagingDurabilityTests.swift - What SequenceExportStaging writes for a sequence export, with no lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.13 M2 (A49-GAP). A captured document snapshot and a file `convert` does not read are staged
// under `<project>/.tmp/` before the row begins, and every export runs `lungfish-cli convert`. These cases check
// the staged files. `SequenceExportPinConformanceTests` runs them through the built command against the app
// writer's texts frozen in 12.13 M1. The staging publishes through `DurableReplace`, so the name holds
// Durability and `scripts/testing/exfat-tests.sh --simulate` runs it with the ExFAT rename fallback.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class SequenceExportStagingDurabilityTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sequence-export-staging")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testASelectionOfFilesConvertReadsStagesNothing() throws {
        let first = project.appendingPathComponent("first.fa")
        let bundle = project.appendingPathComponent("Alpha.lungfishref", isDirectory: true)

        let staged = try SequenceExportStaging.stage(
            [Self.fileSource(first), Self.fileSource(bundle)], format: .genbank, outputURL: root.appendingPathComponent("out.gb")
        )

        XCTAssertEqual(staged.inputs, [first, bundle])
        XCTAssertNil(staged.folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectTempDirectory.tempRoot(for: project).path))
    }

    func testAFileConvertDoesNotReadIsCopiedAsFASTAUnderTheProjectTemporaryFolder() throws {
        let seq = project.appendingPathComponent("reads.seq")
        let first = project.appendingPathComponent("first.fa")
        let packed = project.appendingPathComponent("reads.txt.gz")
        try ">one\nACGT\n>two described\nTTGGCC\n".write(to: seq, atomically: true, encoding: .utf8)
        try Data([0x1f, 0x8b, 0x08, 0x00, 0x01, 0x02]).write(to: packed)
        let sources = [Self.fileSource(seq), Self.fileSource(first), Self.fileSource(packed)]
        let output = root.appendingPathComponent("out.fa.gz")

        let staged = try SequenceExportStaging.stage(sources, format: .fasta, outputURL: output)

        let folder = try XCTUnwrap(staged.folder)
        XCTAssertEqual(
            folder.deletingLastPathComponent().standardizedFileURL.path,
            ProjectTempDirectory.tempRoot(for: project).standardizedFileURL.path
        )
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("sequence-export-"), folder.lastPathComponent)
        XCTAssertEqual(staged.inputs.map(\.lastPathComponent), ["1-reads.seq.fa", "first.fa", "3-reads.txt.fa.gz"])
        XCTAssertEqual(staged.inputs[1], first, "a file convert reads is used where it is")
        XCTAssertTrue(staged.inputs.allSatisfy(SequenceExportRoute.convertReads))
        XCTAssertEqual(try Data(contentsOf: staged.inputs[0]), try Data(contentsOf: seq))
        XCTAssertEqual(try Data(contentsOf: staged.inputs[2]), try Data(contentsOf: packed))
        let marker = try OwnedWorkDirectoryMarkerStore.load(from: folder, expectedProjectURL: project)
        XCTAssertTrue(marker.keepIntermediates, "no sweep removes the files the record names")
        let selection = try JSONDecoder().decode(
            [SequenceExportSourceResolver.Metadata].self,
            from: Data(contentsOf: folder.appendingPathComponent(SequenceExportStaging.selectionFileName))
        )
        XCTAssertEqual(selection.map(\.url), sources.map(\.metadata.url))
        let command = try XCTUnwrap(AppDelegate.sequenceExportCLICommand(
            inputURLs: staged.inputs, outputURL: output, format: .fasta, compression: .gzip
        ), "the row records the command that runs")
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: command),
            SequenceExportRoute.arguments(inputs: staged.inputs, outputURL: output, format: .fasta, compression: .gzip)
        )

        staged.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a failed export discards the staging")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seq.path), "and keeps its sources")
    }

    func testACapturedDocumentIsStagedAsTheAppWritersGenBankRecords() throws {
        let segA = try LungfishCore.Sequence(name: "segA", description: "segment A", alphabet: .dna, bases: "ACGTACGTAAAC")
        let segB = try LungfishCore.Sequence(name: "segB", alphabet: .dna, bases: "TTTTGGGGCCCC")
        let shared = SequenceAnnotation(type: .gene, name: "shared", start: 0, end: 6, qualifiers: [
            "gene": AnnotationQualifier("shared"),
        ])
        let onlyB = SequenceAnnotation(
            type: .gene, name: "onlyB", chromosome: "segB", intervals: [AnnotationInterval(start: 1, end: 5)],
            strand: .forward, qualifiers: ["gene": AnnotationQualifier("onlyB")]
        )
        let source = capturedSource("first native", sequences: [segA, segB], annotations: [shared, onlyB])

        let staged = try SequenceExportStaging.stage(
            [source], format: .genbank, outputURL: root.appendingPathComponent("out.gb"), date: "01-JAN-2026"
        )

        XCTAssertEqual(staged.inputs.map(\.lastPathComponent), ["1-first-native.gb"])
        let records = try GenBankReader(url: staged.inputs[0]).readAllSync()
        XCTAssertEqual(records.map(\.locus.name), ["segA", "segB"])
        XCTAssertEqual(records.map(\.definition), ["segment A", nil])
        XCTAssertEqual(records.map(\.locus.date), ["01-JAN-2026", "01-JAN-2026"])
        // A feature that names no sequence goes with every sequence of its document, as the app's writer put it.
        XCTAssertEqual(records.map { $0.annotations.map(\.name) }, [["shared"], ["shared", "onlyB"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.metadata.url.path), "the display path is not written")
    }

    func testACapturedDocumentIsStagedAsFASTAInLinesOfSixty() throws {
        let long = String(repeating: "ACGTACGTAC", count: 13)
        let native = try LungfishCore.Sequence(name: "native", description: "held in memory", alphabet: .dna, bases: long)
        let disk = project.appendingPathComponent("disk.fa")
        try ">disk\nTTTT\n".write(to: disk, atomically: true, encoding: .utf8)

        let staged = try SequenceExportStaging.stage(
            [capturedSource("native", sequences: [native], annotations: []), Self.fileSource(disk)],
            format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        )

        XCTAssertEqual(staged.inputs.map(\.lastPathComponent), ["1-native.fa", "disk.fa"])
        let lines = try String(contentsOf: staged.inputs[0], encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, ">native held in memory")
        XCTAssertEqual(lines.dropFirst().map(\.count), [60, 60, 10])
        XCTAssertEqual(lines.dropFirst().joined(), long)
    }

    func testAStagingFailureLeavesNoFolder() throws {
        let missing = project.appendingPathComponent("missing.seq")

        XCTAssertThrowsError(try SequenceExportStaging.stage(
            [Self.fileSource(missing)], format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        ))

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: ProjectTempDirectory.tempRoot(for: project).path)) ?? []
        XCTAssertEqual(entries.filter { $0.hasPrefix("sequence-export-") }, [])
    }

    func testAnEmptySnapshotKeepsTheNoSequencesMessage() throws {
        let empty = capturedSource("empty native", sequences: [], annotations: [])

        XCTAssertThrowsError(try SequenceExportStaging.stage(
            [empty], format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        )) { error in
            XCTAssertEqual(error.localizedDescription, "No sequences found in selected files.")
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: ProjectTempDirectory.tempRoot(for: project).path)) ?? []
        XCTAssertEqual(entries.filter { $0.hasPrefix("sequence-export-") }, [], "a refused selection leaves no staging folder")
    }

    func testAnEmptySnapshotBesideAFileStillStages() throws {
        let empty = capturedSource("empty native", sequences: [], annotations: [])
        let disk = project.appendingPathComponent("disk.fa")
        try ">disk\nTTTT\n".write(to: disk, atomically: true, encoding: .utf8)

        let staged = try SequenceExportStaging.stage(
            [empty, Self.fileSource(disk)], format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        )

        XCTAssertEqual(staged.inputs.map(\.lastPathComponent), ["1-empty-native.fa", "disk.fa"], "one empty document beside a file still exports")
    }

    func testRunDiscardsTheStagingWhenTheBodyThrows() async throws {
        let seq = try writeSeqFile()
        let staged = try SequenceExportStaging.stage(
            [Self.fileSource(seq)], format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        )
        let folder = try XCTUnwrap(staged.folder)
        struct BodyFailure: Error {}

        do {
            _ = try await staged.run { (inputs: [URL]) -> Int in
                XCTAssertEqual(inputs, staged.inputs, "the body runs on the staged inputs")
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "and the staging exists while it runs")
                throw BodyFailure()
            }
            XCTFail("the error of the body comes back")
        } catch is BodyFailure {
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a failed or cancelled export discards its staging")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seq.path), "and keeps its source")
    }

    func testRunKeepsTheStagingWhenTheBodyReturns() async throws {
        let seq = try writeSeqFile()
        let staged = try SequenceExportStaging.stage(
            [Self.fileSource(seq)], format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        )
        let folder = try XCTUnwrap(staged.folder)

        let count = try await staged.run { (inputs: [URL]) -> Int in inputs.count }

        XCTAssertEqual(count, 1, "the result of the body comes back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the record of a finished export names the staged files")
        let marker = try OwnedWorkDirectoryMarkerStore.load(from: folder, expectedProjectURL: project)
        XCTAssertTrue(marker.keepIntermediates, "and no sweep removes them")
    }

    func testTheProjectStorageScanKeepsTheStagedFolder() throws {
        let seq = try writeSeqFile()
        let staged = try SequenceExportStaging.stage(
            [Self.fileSource(seq)], format: .fasta, outputURL: root.appendingPathComponent("out.fa")
        )
        let folder = try XCTUnwrap(staged.folder)

        let entries = Dictionary(
            uniqueKeysWithValues: try ProjectStorageScanner().scan(projectURL: project).entries
                .map { ($0.relativePath, $0.classification) }
        )

        let kept = try XCTUnwrap(entries[".tmp/\(folder.lastPathComponent)"], "the scan lists the staged folder")
        XCTAssertFalse(kept.isRemovable, "no cleanup removes the files the record of the export names")
        XCTAssertEqual(kept.code, .explicitlyRetained)
    }

    // MARK: - Helpers

    /// A `.seq` file, which `convert` does not read, so staging copies it into a folder.
    private func writeSeqFile() throws -> URL {
        let seq = project.appendingPathComponent("reads.seq")
        try ">one\nACGT\n".write(to: seq, atomically: true, encoding: .utf8)
        return seq
    }

    private static func fileSource(_ url: URL) -> SequenceExportSourceResolver.Source {
        .init(
            metadata: .init(kind: .filesystem, url: url, documentID: nil, nativeSequenceID: nil, projectURL: nil),
            document: nil
        )
    }

    private func capturedSource(
        _ name: String,
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation]
    ) -> SequenceExportSourceResolver.Source {
        let url = project.appendingPathComponent(name)
        return .init(
            metadata: .init(kind: .nativeProjectSequence, url: url, documentID: UUID(), nativeSequenceID: UUID(), projectURL: project),
            document: .init(name: name, url: url, sequences: sequences, annotations: annotations)
        )
    }
}
