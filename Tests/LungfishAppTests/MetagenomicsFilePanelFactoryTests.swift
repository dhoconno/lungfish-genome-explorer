// MetagenomicsFilePanelFactoryTests.swift - metagenomics panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class MetagenomicsFilePanelFactoryTests: XCTestCase {
    func testNaoMgsResultsImportPanelAcceptsFileOrDirectory() {
        let panel = MetagenomicsFilePanelFactory.naoMgsResultsImportPanel()

        XCTAssertEqual(panel.title, "Select NAO-MGS Results")
        XCTAssertEqual(panel.message, "Select a virus_hits_final.tsv.gz file or results directory")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.allowedContentTypes, [.data, .folder])
    }

    func testNvdResultsImportPanelSelectsDirectory() {
        let panel = MetagenomicsFilePanelFactory.nvdResultsImportPanel()

        XCTAssertEqual(panel.title, "Select NVD Results Directory")
        XCTAssertEqual(panel.message, "Select the top-level NVD run directory")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
    }

    func testCzIdExportImportPanelAcceptsKnownExportsAndOtherFiles() throws {
        let panel = MetagenomicsFilePanelFactory.czIdExportImportPanel()

        XCTAssertEqual(panel.title, "Select CZ-ID Export")
        XCTAssertEqual(panel.message, "Select a CZ-ID taxon report TSV, ZIP archive, or extracted folder")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        for fileExtension in ["zip", "tsv", "txt", "csv"] {
            XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: fileExtension))))
        }
    }

    func testTSVSummaryExportPanelUsesCallerTitleAndName() {
        let panel = MetagenomicsFilePanelFactory.tsvSummaryExportPanel(
            title: "Export NVD Contigs",
            suggestedName: "experiment_nvd_contigs.tsv"
        )

        XCTAssertEqual(panel.title, "Export NVD Contigs")
        XCTAssertEqual(panel.allowedContentTypes, [.tabSeparatedText])
        XCTAssertEqual(panel.nameFieldStringValue, "experiment_nvd_contigs.tsv")
    }

    func testDelimitedExportPanelUsesPlainTextAndCreatesDirectories() {
        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export Taxonomy as CSV",
            suggestedName: "classification.csv",
            contentTypes: [.plainText]
        )

        XCTAssertEqual(panel.title, "Export Taxonomy as CSV")
        XCTAssertEqual(panel.nameFieldStringValue, "classification.csv")
        XCTAssertEqual(panel.allowedContentTypes, [.plainText])
        XCTAssertTrue(panel.canCreateDirectories)
    }

    func testBlastDelimitedExportPanelUsesFormatSpecificContentTypes() {
        let csvPanel = MetagenomicsFilePanelFactory.blastDelimitedExportPanel(fileExtension: "csv")
        let tsvPanel = MetagenomicsFilePanelFactory.blastDelimitedExportPanel(fileExtension: "tsv")

        XCTAssertEqual(csvPanel.nameFieldStringValue, "blast_results.csv")
        XCTAssertEqual(csvPanel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertEqual(tsvPanel.nameFieldStringValue, "blast_results.tsv")
        XCTAssertEqual(tsvPanel.allowedContentTypes, [.tabSeparatedText])
    }

    func testReadExtractionSavePanelUsesSuggestedNameWithoutAddingExportPolicy() {
        let panel = MetagenomicsFilePanelFactory.readExtractionSavePanel(suggestedName: "extract.fastq.gz")

        XCTAssertEqual(panel.nameFieldStringValue, "extract.fastq.gz")
        XCTAssertEqual(panel.allowedContentTypes, [])
        XCTAssertTrue(panel.canCreateDirectories)
    }
}
