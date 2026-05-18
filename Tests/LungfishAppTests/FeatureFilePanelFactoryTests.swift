// FeatureFilePanelFactoryTests.swift - shared feature panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class FeatureFilePanelFactoryTests: XCTestCase {
    func testInspectorTextMetadataImportPanelAcceptsDelimitedText() throws {
        let panel = FeatureFilePanelFactory.inspectorTextMetadataImportPanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.message, "Select a CSV or TSV file with sample metadata")
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        XCTAssertTrue(contentTypes.contains(.commaSeparatedText))
        XCTAssertTrue(contentTypes.contains(.tabSeparatedText))
        XCTAssertTrue(contentTypes.contains(.plainText))
    }

    func testVariantSampleMetadataImportPanelKeepsImportPrompt() throws {
        let panel = FeatureFilePanelFactory.variantSampleMetadataImportPanel()

        XCTAssertEqual(panel.message, "Select a TSV or CSV file with sample metadata")
        XCTAssertEqual(panel.prompt, "Import")
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        for fileExtension in ["tsv", "csv", "txt"] {
            XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: fileExtension))))
        }
    }

    func testAttachmentImportPanelAllowsMultipleFilesOnly() {
        let panel = FeatureFilePanelFactory.attachmentImportPanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
    }

    func testPrimerSchemeFolderPanelSelectsSingleDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/Primer Schemes", isDirectory: true)
        let panel = FeatureFilePanelFactory.primerSchemeFolderPanel(directoryURL: directory)

        XCTAssertEqual(panel.title, "Choose Primer Scheme")
        XCTAssertEqual(panel.prompt, "Choose")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.allowedContentTypes, [])
        XCTAssertEqual(panel.directoryURL, directory)
    }

    func testMetadataCSVImportPanelUsesCallerMessage() {
        let panel = FeatureFilePanelFactory.metadataCSVImportPanel(message: "Choose a CSV file with sample metadata")

        XCTAssertEqual(panel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertEqual(panel.message, "Choose a CSV file with sample metadata")
    }

    func testMetadataCSVExportPanelUsesSuggestedName() {
        let panel = FeatureFilePanelFactory.metadataCSVExportPanel(suggestedName: "samples.csv")

        XCTAssertEqual(panel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertEqual(panel.nameFieldStringValue, "samples.csv")
    }

    func testInspectorProvenanceExportReusesFolderPackageConfiguration() {
        let panel = FeatureFilePanelFactory.inspectorProvenanceExportPanel(defaultDirectoryName: "reads-provenance-shell")

        XCTAssertEqual(panel.title, "Export Provenance")
        XCTAssertEqual(panel.message, "Choose a folder name for the exported reproducibility package.")
        XCTAssertEqual(panel.nameFieldStringValue, "reads-provenance-shell")
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.canSelectHiddenExtension)
    }
}
