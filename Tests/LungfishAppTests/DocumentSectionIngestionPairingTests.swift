// DocumentSectionIngestionPairingTests.swift - The Inspector's Pairing row names pairs and single reads by their count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ViewInspector
import LungfishIO
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
