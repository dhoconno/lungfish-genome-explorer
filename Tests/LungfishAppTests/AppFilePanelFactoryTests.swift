// AppFilePanelFactoryTests.swift - App import/export panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class AppFilePanelFactoryTests: XCTestCase {
    func testNewProjectPanelUsesFolderSaveConfiguration() {
        let panel = AppFilePanelFactory.newProjectPanel()

        XCTAssertEqual(panel.title, "Create New Project")
        XCTAssertEqual(panel.message, "Choose a location for your new Lungfish project")
        XCTAssertEqual(panel.nameFieldLabel, "Project Name:")
        XCTAssertEqual(panel.nameFieldStringValue, "My Genome Project")
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.allowedContentTypes, [.folder])
        XCTAssertFalse(panel.isExtensionHidden)
    }

    func testDocumentOpenPanelAcceptsSupportedSequenceAndFastqInputs() throws {
        let panel = AppFilePanelFactory.documentOpenPanel()

        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canChooseDirectories)
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        for ext in ["fa", "fastq", "fq", "gz", "lungfishfastq", "gb", "gbk", "gff", "gff3"] {
            XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: ext))))
        }
    }

    func testProjectFolderOpenPanelSelectsSingleProjectDirectory() {
        let panel = AppFilePanelFactory.projectFolderOpenPanel()

        XCTAssertEqual(panel.title, "Open Project Folder")
        XCTAssertEqual(panel.message, "Select a Lungfish project folder to open in a new window")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
    }

    func testWelcomeProjectOpenPanelPreservesWelcomeCopy() {
        let panel = AppFilePanelFactory.welcomeProjectOpenPanel()

        XCTAssertEqual(panel.title, "Open Project")
        XCTAssertEqual(panel.message, "Select a Lungfish project folder")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
    }

    func testManagedStorageLocationPanelSelectsCreatableDirectory() {
        let panel = AppFilePanelFactory.managedStorageLocationPanel(title: "Choose Storage Location")

        XCTAssertEqual(panel.title, "Choose Storage Location")
        XCTAssertEqual(
            panel.message,
            "Select a storage location for managed tools and databases. The full resolved path cannot contain spaces."
        )
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.prompt, "Choose")
    }

    func testProjectFileImportPanelAllowsMultipleFilesAndOtherTypes() {
        let panel = AppFilePanelFactory.projectFileImportPanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.message, "Select files to import into the project")
        XCTAssertEqual(panel.prompt, "Import")
    }

    func testVCFImportPanelUsesCurrentBundleSpecificMessageAndVCFContentTypes() throws {
        let panel = AppFilePanelFactory.vcfImportPanel(targetsCurrentBundle: true)

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.message, "Select VCF file(s) to import into the current bundle")
        XCTAssertEqual(panel.prompt, "Import")
        XCTAssertTrue(try XCTUnwrap(panel.allowedContentTypes).contains(try XCTUnwrap(UTType(filenameExtension: "vcf"))))
        XCTAssertTrue(try XCTUnwrap(panel.allowedContentTypes).contains(try XCTUnwrap(UTType(filenameExtension: "gz"))))
    }

    func testVCFImportPanelUsesOpenMessageWithoutCurrentBundle() {
        let panel = AppFilePanelFactory.vcfImportPanel(targetsCurrentBundle: false)

        XCTAssertEqual(panel.message, "Select VCF file(s) to open")
    }

    func testBAMImportPanelRestrictsToSingleAlignmentFile() throws {
        let panel = AppFilePanelFactory.bamImportPanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.message, "Select a BAM, CRAM, or SAM file to import into the current bundle")
        XCTAssertEqual(panel.prompt, "Import")
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        for ext in ["bam", "cram", "sam"] {
            XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: ext))))
        }
    }

    func testSampleMetadataImportPanelUsesMetadataContentTypes() throws {
        let panel = AppFilePanelFactory.sampleMetadataImportPanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.message, "Select a TSV or CSV file with sample metadata")
        XCTAssertEqual(panel.prompt, "Import Metadata")
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        for ext in ["tsv", "csv", "txt"] {
            XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: ext))))
        }
    }

    func testONTRunImportPanelSelectsOneDirectory() {
        let panel = AppFilePanelFactory.ontRunImportPanel()

        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.message, "Select an ONT output directory (fastq_pass, a barcoded folder, or a folder with FASTQ chunks)")
        XCTAssertEqual(panel.prompt, "Import")
    }

    func testFASTQSingleExportPanelUsesSuggestedFilenameAndDataContentType() throws {
        let panel = AppFilePanelFactory.fastqSingleExportPanel(suggestedName: "reads.fastq.gz")

        XCTAssertEqual(panel.title, "Export FASTQ")
        XCTAssertEqual(panel.nameFieldStringValue, "reads.fastq.gz")
        XCTAssertEqual(panel.allowedContentTypes, [.data])
        XCTAssertTrue(panel.canCreateDirectories)
    }

    func testFASTQBatchExportFolderPanelSelectsOutputFolder() {
        let panel = AppFilePanelFactory.fastqBatchExportFolderPanel(itemCount: 3)

        XCTAssertEqual(panel.title, "Export 3 FASTQ Files — Choose Output Folder")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.prompt, "Export Here")
    }

    func testGFF3ExportPanelUsesSuggestedFilenameAndGFF3ContentType() throws {
        let panel = AppFilePanelFactory.gff3ExportPanel(suggestedName: "annotations.gff3")

        XCTAssertEqual(panel.title, "Export GFF3")
        XCTAssertEqual(panel.nameFieldStringValue, "annotations.gff3")
        XCTAssertEqual(panel.allowedContentTypes, [try XCTUnwrap(UTType(filenameExtension: "gff3"))])
    }

    func testProvenanceExportPanelSelectsDestinationDirectoryName() {
        let panel = AppFilePanelFactory.provenanceExportPanel(defaultDirectoryName: "reads-provenance-shell")

        XCTAssertEqual(panel.title, "Export Provenance")
        XCTAssertEqual(panel.message, "Choose a folder name for the exported reproducibility package.")
        XCTAssertEqual(panel.nameFieldStringValue, "reads-provenance-shell")
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.canSelectHiddenExtension)
    }

    func testSequenceExportPanelAllowsFilesAndOtherTypes() {
        let panel = AppFilePanelFactory.sequenceExportPanel()

        XCTAssertEqual(panel.title, "Export Sequences")
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.allowsOtherFileTypes)
    }

    func testBatchSequenceExportFolderPanelSelectsOutputFolder() {
        let panel = AppFilePanelFactory.batchSequenceExportFolderPanel(itemCount: 2)

        XCTAssertEqual(panel.title, "Export 2 Sequence Files - Choose Output Folder")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.prompt, "Export Here")
    }

    func testViewerGraphicsExportPanelUsesAllowedFormatsAndInitialName() {
        let panel = AppFilePanelFactory.viewerGraphicsExportPanel(
            formats: [.png, .pdf],
            initialFormat: .png
        )

        XCTAssertEqual(panel.title, "Export Viewer Graphics")
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.allowedContentTypes, [.png, .pdf])
        XCTAssertEqual(panel.nameFieldStringValue, "viewer-export.png")
    }
}
