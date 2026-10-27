// MetagenomicsFilePanelFactory.swift - metagenomics import/export panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import UniformTypeIdentifiers

@MainActor
public enum MetagenomicsFilePanelFactory {
    public static var naoMgsImportContentTypes: [UTType] {
        [UTType(filenameExtension: "tsv") ?? .tabSeparatedText,
         UTType(filenameExtension: "gz") ?? .gzip, .folder]
    }

    public static var czIdImportContentTypes: [UTType] {
        [UTType(filenameExtension: "zip") ?? .zip,
         UTType(filenameExtension: "tsv") ?? .tabSeparatedText,
         UTType(filenameExtension: "txt") ?? .plainText,
         UTType(filenameExtension: "csv") ?? .commaSeparatedText]
    }

    public static func naoMgsResultsImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Select NAO-MGS Results"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = naoMgsImportContentTypes
        panel.message = "Select a virus_hits_final.tsv.gz file or results directory"
        return panel
    }

    public static func nvdResultsImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Select NVD Results Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the top-level NVD run directory"
        return panel
    }

    public static func czIdExportImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Select CZ-ID Export"
        panel.message = "Select a CZ-ID taxon report TSV, ZIP archive, or extracted folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = czIdImportContentTypes
        panel.allowsOtherFileTypes = false
        return panel
    }

    /// The folder a save panel for the result at `resultURL` opens in (Phase 3.0 lane CONSENSUS-DEST, walk WO-3).
    /// It is the project that holds the result, else the result's own folder, and a result file stands for its
    /// folder. A panel given it never opens in the last folder used, which can be another project's. Nil when
    /// the caller has no result.
    public static func startFolder(forResultAt resultURL: URL?) -> URL? {
        guard let resultURL else { return nil }
        if let project = ProjectTempDirectory.findProjectRoot(resultURL) { return project }
        let isFolder = (try? resultURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return (isFolder ? resultURL : resultURL.deletingLastPathComponent()).standardizedFileURL
    }

    /// Opens `panel` in `folder`, and leaves the system's choice alone when the caller names none.
    private static func start(_ panel: NSSavePanel, in folder: URL?) {
        if let folder { panel.directoryURL = folder }
    }

    public static func tsvSummaryExportPanel(
        title: String,
        suggestedName: String,
        startingIn folder: URL? = nil
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.title = title
        start(panel, in: folder)
        return panel
    }

    public static func delimitedExportPanel(
        title: String? = nil,
        suggestedName: String,
        contentTypes: [UTType] = [.plainText],
        startingIn folder: URL? = nil
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        if let title {
            panel.title = title
        }
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        start(panel, in: folder)
        return panel
    }

    public static func blastDelimitedExportPanel(fileExtension: String, startingIn folder: URL? = nil) -> NSSavePanel {
        let contentTypes: [UTType] = fileExtension == "csv"
            ? [.commaSeparatedText]
            : [.tabSeparatedText]
        return delimitedExportPanel(
            suggestedName: "blast_results.\(fileExtension)",
            contentTypes: contentTypes,
            startingIn: folder
        )
    }

    public static func readExtractionSavePanel(suggestedName: String, startingIn folder: URL? = nil) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        start(panel, in: folder)
        return panel
    }
}
