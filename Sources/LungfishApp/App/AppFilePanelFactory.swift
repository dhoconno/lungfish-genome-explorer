// AppFilePanelFactory.swift - shared import/export panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import UniformTypeIdentifiers

@MainActor
enum AppFilePanelFactory {
    static func newProjectPanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Create New Project"
        panel.message = "Choose a location for your new Lungfish project"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "My Genome Project"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.folder]
        panel.isExtensionHidden = false
        return panel
    }

    static func documentOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes + contentTypes(forFilenameExtensions: [
            "fq",
            "fastq",
            "gz",
            FASTQBundle.directoryExtension,
            "gb",
            "gbk",
            "gff",
            "gff3",
        ])
        return panel
    }

    static func projectFolderOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "Select a Lungfish project folder to open in a new window"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
    }

    static func welcomeProjectOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Select a Lungfish project folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
    }

    static func managedStorageLocationPanel(title: String? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        if let title {
            panel.title = title
        }
        panel.message = "Select a storage location for managed tools and databases. The full resolved path cannot contain spaces."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel
    }

    static func projectFileImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.message = "Select files to import into the project"
        panel.prompt = "Import"
        return panel
    }

    static func vcfImportPanel(targetsCurrentBundle: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = contentTypes(forFilenameExtensions: ["vcf", "gz"])
        panel.allowsOtherFileTypes = true
        panel.message = targetsCurrentBundle
            ? "Select VCF file(s) to import into the current bundle"
            : "Select VCF file(s) to open"
        panel.prompt = "Import"
        return panel
    }

    static func bamImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = contentTypes(forFilenameExtensions: ["bam", "cram", "sam"])
        panel.allowsOtherFileTypes = true
        panel.message = "Select a BAM, CRAM, or SAM file to import into the current bundle"
        panel.prompt = "Import"
        return panel
    }

    static func sampleMetadataImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = contentTypes(forFilenameExtensions: ["tsv", "csv", "txt"])
        panel.message = "Select a TSV or CSV file with sample metadata"
        panel.prompt = "Import Metadata"
        return panel
    }

    static func ontRunImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select an ONT output directory (fastq_pass, a barcoded folder, or a folder with FASTQ chunks)"
        panel.prompt = "Import"
        return panel
    }

    static func fastqSingleExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export FASTQ"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        return panel
    }

    static func fastqBatchExportFolderPanel(itemCount: Int) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Export \(itemCount) FASTQ Files — Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        return panel
    }

    static func gff3ExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export GFF3"
        panel.allowedContentTypes = contentTypes(forFilenameExtensions: ["gff3"])
        panel.nameFieldStringValue = suggestedName
        return panel
    }

    static func provenanceExportPanel(defaultDirectoryName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export Provenance"
        panel.message = "Choose a folder name for the exported reproducibility package."
        panel.nameFieldStringValue = defaultDirectoryName
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        return panel
    }

    static func sequenceExportPanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export Sequences"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        return panel
    }

    static func batchSequenceExportFolderPanel(itemCount: Int) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Export \(itemCount) Sequence Files - Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        return panel
    }

    static func viewerGraphicsExportPanel(
        formats: [ViewerGraphicFormat],
        initialFormat: ViewerGraphicFormat
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export Viewer Graphics"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = formats.map(\.contentType)
        panel.nameFieldStringValue = "viewer-export.\(initialFormat.fileExtension)"
        return panel
    }

    private static func contentTypes(forFilenameExtensions extensions: [String]) -> [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }
}
