// MetagenomicsFilePanelFactoryTests.swift - metagenomics panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
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
        XCTAssertEqual(panel.allowedContentTypes, MetagenomicsFilePanelFactory.naoMgsImportContentTypes)
    }

    func testNvdResultsImportPanelSelectsDirectory() {
        let panel = MetagenomicsFilePanelFactory.nvdResultsImportPanel()

        XCTAssertEqual(panel.title, "Select NVD Results Directory")
        XCTAssertEqual(panel.message, "Select the top-level NVD run directory")
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
    }

    func testCzIdExportImportPanelAcceptsKnownExports() throws {
        let panel = MetagenomicsFilePanelFactory.czIdExportImportPanel()

        XCTAssertEqual(panel.title, "Select CZ-ID Export")
        XCTAssertEqual(panel.message, "Select a CZ-ID taxon report TSV, ZIP archive, or extracted folder")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.allowsOtherFileTypes)
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

    // MARK: - Where a save panel opens (Phase 3.0 lane CONSENSUS-DEST, walk WO-3)

    /// A project with a classifier result in it, in a temp folder that the case removes.
    private func makeProject() throws -> (project: URL, result: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-start-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (project, result)
    }

    private func assertStarts(
        inside project: URL, _ panel: NSSavePanel, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let start = panel.directoryURL?.resolvingSymlinksInPath().path
        let root = project.resolvingSymlinksInPath().path
        XCTAssertTrue(
            start == root || start?.hasPrefix(root + "/") == true,
            "\(what) starts in \(start ?? "the last folder used"), not in the project",
            file: file, line: line
        )
    }

    /// The walk met an Export as CSV whose panel opened in another project, the last folder used.
    func testEveryExportPanelMadeForAResultInAProjectStartsInsideTheProject() throws {
        let (project, result) = try makeProject()
        let folder = MetagenomicsFilePanelFactory.startFolder(forResultAt: result)
        assertStarts(inside: project, MetagenomicsFilePanelFactory.tsvSummaryExportPanel(
            title: "Export", suggestedName: "a.tsv", startingIn: folder), "the TSV summary panel")
        assertStarts(inside: project, MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export", suggestedName: "a.csv", startingIn: folder), "the delimited export panel")
        assertStarts(inside: project, MetagenomicsFilePanelFactory.blastDelimitedExportPanel(
            fileExtension: "csv", startingIn: folder), "the BLAST export panel")
        assertStarts(inside: project, MetagenomicsFilePanelFactory.readExtractionSavePanel(
            suggestedName: "a.fastq", startingIn: folder), "the read extraction panel")
    }

    func testAResultOutsideAProjectStartsItsPanelInItsOwnFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-start-\(UUID().uuidString)", isDirectory: true)
        let result = root.appendingPathComponent("kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let record = result.appendingPathComponent("results.json")
        try Data("{}".utf8).write(to: record)

        XCTAssertEqual(
            MetagenomicsFilePanelFactory.startFolder(forResultAt: result)?.resolvingSymlinksInPath().path,
            result.resolvingSymlinksInPath().path, "a result folder is its own start folder"
        )
        XCTAssertEqual(
            MetagenomicsFilePanelFactory.startFolder(forResultAt: record)?.resolvingSymlinksInPath().path,
            result.resolvingSymlinksInPath().path, "a result file starts in its folder"
        )
        XCTAssertNil(MetagenomicsFilePanelFactory.startFolder(forResultAt: nil), "no result names no folder")
    }
}
