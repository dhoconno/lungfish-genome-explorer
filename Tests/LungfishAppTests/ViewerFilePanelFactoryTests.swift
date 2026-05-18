// ViewerFilePanelFactoryTests.swift - viewer drawer file panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class ViewerFilePanelFactoryTests: XCTestCase {
    func testTableExportPanelUsesFormatSpecificContentType() {
        let panel = ViewerFilePanelFactory.tableExportPanel(
            title: "Export Table",
            suggestedName: "variants.csv",
            contentType: .commaSeparatedText
        )

        XCTAssertEqual(panel.title, "Export Table")
        XCTAssertEqual(panel.nameFieldStringValue, "variants.csv")
        XCTAssertEqual(panel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertTrue(panel.canCreateDirectories)
    }

    func testBookmarkedVariantsPanelExportsTSV() {
        let panel = ViewerFilePanelFactory.bookmarkedVariantsExportPanel()

        XCTAssertEqual(panel.title, "Export Bookmarked Variants")
        XCTAssertEqual(panel.nameFieldStringValue, "bookmarked_variants.tsv")
        XCTAssertEqual(panel.allowedContentTypes, [.tabSeparatedText])
        XCTAssertTrue(panel.canCreateDirectories)
    }

    func testSequenceFastaExportPanelPreservesTextType() {
        let panel = ViewerFilePanelFactory.sequenceFastaExportPanel(suggestedName: "segment.fasta")

        XCTAssertEqual(panel.title, "Export Sequence")
        XCTAssertEqual(panel.nameFieldStringValue, "segment.fasta")
        XCTAssertEqual(panel.allowedContentTypes, [.text])
    }

    func testFASTQMetadataImportAndExportPanelsUseExistingPrompts() {
        let importPanel = ViewerFilePanelFactory.fastqMetadataImportPanel(prompt: "Import")
        let exportPanel = ViewerFilePanelFactory.fastqMetadataExportPanel(suggestedName: "fastq-sample-metadata.csv")

        XCTAssertEqual(importPanel.allowedContentTypes, [.commaSeparatedText, .tabSeparatedText, .plainText])
        XCTAssertFalse(importPanel.allowsMultipleSelection)
        XCTAssertEqual(importPanel.prompt, "Import")
        XCTAssertEqual(exportPanel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertEqual(exportPanel.prompt, "Export")
        XCTAssertEqual(exportPanel.nameFieldStringValue, "fastq-sample-metadata.csv")
    }

    func testSampleMetadataTemplatePanelAllowsTSVOrCSV() throws {
        let panel = ViewerFilePanelFactory.sampleMetadataTemplatePanel(suggestedName: "sample-metadata-template.tsv")

        XCTAssertEqual(panel.title, "Save Sample Metadata Template")
        XCTAssertEqual(panel.prompt, "Save Template")
        XCTAssertEqual(panel.nameFieldStringValue, "sample-metadata-template.tsv")
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: "tsv"))))
        XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: "csv"))))
    }

    func testPhylogeneticSubtreeExportPanelUsesNewickName() {
        let panel = ViewerFilePanelFactory.phylogeneticSubtreeExportPanel(suggestedName: "clade.nwk")

        XCTAssertEqual(panel.nameFieldStringValue, "clade.nwk")
        XCTAssertEqual(panel.allowedContentTypes, [.plainText])
    }
}
