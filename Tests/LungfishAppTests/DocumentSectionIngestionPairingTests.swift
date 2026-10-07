// DocumentSectionIngestionPairingTests.swift - The Inspector's Pairing row names pairs and single reads by their count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ViewInspector
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// A file whose read roles hold pairs and single reads is labelled
/// `single_end` by its count, the one convention every importer follows, so
/// no tool pairs it by position. The Ingestion group's Pairing row printed
/// that label as it is stored, so a paired SRA run imported with its reads
/// whose mate is missing, or a dialog output that kept merged reads beside
/// pairs, read "Single End" in the Inspector. The row now names what the
/// file holds, and the stored label stays as it is.
@MainActor
final class DocumentSectionIngestionPairingTests: XCTestCase {

    func testTheRowNamesPairsAndSingleReadsOfADerivedBundleByTheirCount() throws {
        let viewModel = DocumentSectionViewModel()
        viewModel.updateFASTQStatistics(.placeholder(readCount: 264, baseCount: 39_600))
        viewModel.updateIngestionMetadata(IngestionMetadata(pairingMode: .singleEnd))
        viewModel.updateFASTQDerivativeMetadata(Self.manifest(roles: ReadClassification(files: [
            .init(filename: "reads.fastq", role: .pairedR1, readCount: 129),
            .init(filename: "reads.fastq", role: .pairedR2, readCount: 129),
            .init(filename: "reads.fastq", role: .unpaired, readCount: 6),
        ])))

        let section = try DocumentSection(viewModel: viewModel).inspect()

        XCTAssertNoThrow(try section.find(text: "Pairs and single reads (129 pairs + 6 singles)"))
        XCTAssertThrowsError(try section.find(text: "Single End"), "the stored label is not what the row shows")
    }

    func testTheRowNamesPairsAndSingleReadsOfARootBundleFromItsSidecar() throws {
        // A paired SRA run imported with its third file, 129 pairs and 6
        // reads whose mate is missing, which the import labels single_end.
        let root = try TestTempDirectory.make(prefix: "inspector-pairing-row")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("SRR1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("SRR1.fastq.gz")
        try Data([0x1F, 0x8B]).write(to: fastq)
        var metadata = PersistedFASTQMetadata()
        metadata.ingestion = IngestionMetadata(pairingMode: .singleEnd)
        metadata.readClassification = ReadClassification(files: [
            .init(filename: "SRR1.fastq.gz", role: .pairedR1, readCount: 129),
            .init(filename: "SRR1.fastq.gz", role: .pairedR2, readCount: 129),
            .init(filename: "SRR1.fastq.gz", role: .unpaired, readCount: 6),
        ])
        FASTQMetadataStore.save(metadata, for: fastq)
        let viewModel = DocumentSectionViewModel()
        viewModel.updateFASTQStatistics(.placeholder(readCount: 264, baseCount: 39_600))
        viewModel.updateIngestionMetadata(metadata.ingestion)

        viewModel.updateIngestionReadRoles(fromBundle: bundle)

        let section = try DocumentSection(viewModel: viewModel).inspect()
        XCTAssertNoThrow(try section.find(text: "Pairs and single reads (129 pairs + 6 singles)"))
        XCTAssertEqual(metadata.ingestion?.pairingMode, .singleEnd, "the stored label stays as it is")
        // The next dataset's metadata takes the roles of this one away.
        viewModel.updateIngestionMetadata(IngestionMetadata(pairingMode: .singleEnd))
        XCTAssertNil(viewModel.ingestionReadRoles)
    }

    func testTheRowReadsABundlesRolesInTheOrderItsToolsReadThem() throws {
        // FASTQMixedLayoutHint.recordedRoles(of:) reads a derived manifest's
        // roles before the sidecar of the file the bundle holds, so the row
        // shows the roles the bundle's tools read.
        let root = try TestTempDirectory.make(prefix: "inspector-pairing-row")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = Self.manifest(roles: ReadClassification(files: [
            .init(filename: "reads.fastq", role: .pairedR1, readCount: 129),
            .init(filename: "reads.fastq", role: .pairedR2, readCount: 129),
            .init(filename: "reads.fastq", role: .unpaired, readCount: 6),
        ]))
        try FASTQBundle.saveDerivedManifest(manifest, in: bundle)
        let preview = bundle.appendingPathComponent("preview.fastq")
        try Data("@r/1\nACGT\n+\nIIII\n@r/2\nACGT\n+\nIIII\n".utf8).write(to: preview)
        FASTQMixedLayoutHint.write(ReadClassification(files: [
            .init(filename: "preview.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "preview.fastq", role: .pairedR2, readCount: 1),
        ]), beside: preview)
        let viewModel = DocumentSectionViewModel()
        viewModel.updateIngestionMetadata(IngestionMetadata(pairingMode: .singleEnd))
        viewModel.updateFASTQDerivativeMetadata(manifest)

        viewModel.updateIngestionReadRoles(fromBundle: bundle)

        XCTAssertEqual(viewModel.ingestionPairingRoles, manifest.readClassification)
        XCTAssertEqual(
            DocumentSectionViewModel.pairingRowText(.singleEnd, roles: viewModel.ingestionPairingRoles),
            "Pairs and single reads (129 pairs + 6 singles)"
        )
    }

    func testTheRowShowsTheStoredPairingForEveryOtherFile() {
        func roles(_ entries: [(ReadClassification.FileRole, Int)]) -> ReadClassification {
            ReadClassification(files: entries.map { .init(filename: "reads.fastq", role: $0.0, readCount: $0.1) })
        }
        let pairs = [(ReadClassification.FileRole.pairedR1, 5), (.pairedR2, 5)]
        XCTAssertEqual(
            DocumentSectionViewModel.pairingRowText(.singleEnd, roles: roles(pairs + [(.merged, 3)])),
            "Pairs and single reads (5 pairs + 3 merged)"
        )
        XCTAssertEqual(
            DocumentSectionViewModel.pairingRowText(.singleEnd, roles: roles(pairs + [(.merged, 3), (.unpaired, 2)])),
            "Pairs and single reads (5 pairs + 3 merged + 2 singles)"
        )
        XCTAssertEqual(DocumentSectionViewModel.pairingRowText(.interleaved, roles: roles(pairs)), "Interleaved")
        XCTAssertEqual(DocumentSectionViewModel.pairingRowText(.singleEnd, roles: roles([(.unpaired, 4)])), "Single End")
        XCTAssertEqual(DocumentSectionViewModel.pairingRowText(.singleEnd, roles: nil), "Single End")
        XCTAssertEqual(DocumentSectionViewModel.pairingRowText(.pairedEnd, roles: nil), "Paired End")
        XCTAssertEqual(DocumentSectionViewModel.pairingRowText(.interleaved, roles: nil), "Interleaved")
    }

    // MARK: - Helpers

    private static func manifest(roles: ReadClassification) -> FASTQDerivedBundleManifest {
        let operation = FASTQDerivativeOperation(kind: .orient)
        return FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "@/Imports/run.lungfishfastq",
            rootBundleRelativePath: "@/Imports/run.lungfishfastq",
            rootFASTQFilename: "run.fastq.gz",
            lineage: [operation],
            operation: operation,
            cachedStatistics: .placeholder(readCount: roles.totalReadCount, baseCount: 0),
            pairingMode: .singleEnd,
            readClassification: roles
        )
    }
}
