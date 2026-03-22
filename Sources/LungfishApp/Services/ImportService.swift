// ImportService.swift - Unified file import with auto-detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishIO
import UniformTypeIdentifiers
import os.log

/// Logger for import operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "ImportService")

/// Type alias for backward compatibility - use UICategory from LungfishIO
public typealias FileCategory = UICategory

/// Detected file format information
public struct DetectedFormat: Sendable {
    public let category: UICategory
    public let formatId: String
    public let formatName: String
    public let fileExtension: String
    public let isGenomicsFormat: Bool
    public let supportsQuickLook: Bool

    public init(
        category: UICategory,
        formatId: String,
        formatName: String,
        fileExtension: String,
        isGenomicsFormat: Bool = false,
        supportsQuickLook: Bool = true
    ) {
        self.category = category
        self.formatId = formatId
        self.formatName = formatName
        self.fileExtension = fileExtension
        self.isGenomicsFormat = isGenomicsFormat
        self.supportsQuickLook = supportsQuickLook
    }
}

/// Service for importing files into Lungfish projects
@MainActor
public final class ImportService {

    // MARK: - Singleton

    public static let shared = ImportService()

    // MARK: - Format Name Mapping

    /// Maps format IDs to human-readable names for display
    private static let formatNames: [String: String] = [
        // Sequence
        "fasta": "FASTA", "fa": "FASTA", "fna": "FASTA", "faa": "FASTA",
        "ffn": "FASTA", "frn": "FASTA", "fas": "FASTA",
        "fastq": "FASTQ", "fq": "FASTQ",
        "gb": "GenBank", "gbk": "GenBank", "genbank": "GenBank", "gbff": "GenBank",
        "embl": "EMBL",
        // Annotation
        "gff": "GFF3", "gff3": "GFF3", "gtf": "GTF", "bed": "BED",
        // Variant
        "vcf": "VCF", "bcf": "BCF",
        // Alignment
        "bam": "BAM", "sam": "SAM", "cram": "CRAM",
        // Coverage
        "bw": "BigWig", "bigwig": "BigWig",
        "bb": "BigBed", "bigbed": "BigBed",
        "bedgraph": "bedGraph", "bg": "bedGraph",
        // Index
        "fai": "FASTA Index", "bai": "BAM Index", "tbi": "Tabix Index",
        // Document
        "pdf": "PDF", "txt": "Plain Text", "text": "Plain Text",
        "md": "Markdown", "markdown": "Markdown",
        "rtf": "Rich Text", "csv": "CSV", "tsv": "TSV",
        // Image
        "png": "PNG", "jpg": "JPEG", "jpeg": "JPEG",
        "tiff": "TIFF", "tif": "TIFF", "svg": "SVG",
        // Compressed
        "gz": "Gzip", "zip": "ZIP Archive"
    ]

    // MARK: - Initialization

    private init() {}

    // MARK: - Format Detection

    /// Detects file format information from a URL.
    ///
    /// Uses the unified FileTypeUtility from LungfishIO for consistent
    /// format detection across the application.
    public func detectFormat(url: URL) -> DetectedFormat {
        let fileInfo = FileTypeUtility.detect(url: url)
        let ext = url.pathExtension.lowercased()

        // Determine format name - check for compressed inner extension
        let formatName: String
        let formatId: String
        let finalExtension: String

        if ext == "gz" || ext == "gzip" {
            let innerExt = url.deletingPathExtension().pathExtension.lowercased()
            if !innerExt.isEmpty {
                formatName = (Self.formatNames[innerExt] ?? innerExt.uppercased()) + " (compressed)"
                formatId = innerExt
                finalExtension = "\(innerExt).gz"
            } else {
                formatName = "Gzip Compressed"
                formatId = "gz"
                finalExtension = ext
            }
        } else {
            formatName = Self.formatNames[ext] ?? (ext.isEmpty ? "Unknown" : ext.uppercased())
            formatId = ext.isEmpty ? "unknown" : ext
            finalExtension = ext
        }

        return DetectedFormat(
            category: fileInfo.category,
            formatId: formatId,
            formatName: formatName,
            fileExtension: finalExtension,
            isGenomicsFormat: fileInfo.isGenomicsFormat,
            supportsQuickLook: fileInfo.supportsQuickLook
        )
    }
    
    // MARK: - Import Dialog
    
    /// Shows a file open panel and imports selected files to the project.
    /// This is the main entry point for file import.
    ///
    /// - Parameters:
    ///   - window: The parent window for the panel
    ///   - projectURL: The destination project folder
    /// - Returns: Array of successfully imported file URLs
    public func showImportDialogAndImport(
        for window: NSWindow,
        projectURL: URL
    ) async -> [URL] {
        logger.info("showImportDialogAndImport: Starting for project at '\(projectURL.path, privacy: .public)'")

        // Create and configure the open panel
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.message = "Select files to import into the project"
        panel.prompt = "Import"

        // Show the panel as a sheet and wait for response
        let response = await panel.beginSheetModal(for: window)

        guard response == .OK else {
            logger.debug("showImportDialogAndImport: User cancelled")
            return []
        }

        let selectedURLs = panel.urls
        guard !selectedURLs.isEmpty else {
            logger.debug("showImportDialogAndImport: No files selected")
            return []
        }

        logger.info("showImportDialogAndImport: Selected \(selectedURLs.count) file(s)")

        // Import the files
        return await importFiles(selectedURLs, to: projectURL, window: window)
    }
    
    // MARK: - File Import
    
    /// Imports files to a project folder with progress indication for large files.
    public func importFiles(
        _ urls: [URL],
        to projectURL: URL,
        window: NSWindow?
    ) async -> [URL] {
        logger.info("importFiles: Starting import of \(urls.count) file(s)")

        let fileManager = FileManager.default
        var importedURLs: [URL] = []

        // Verify project directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("importFiles: Project directory does not exist: '\(projectURL.path, privacy: .public)'")
            return []
        }
        
        // Calculate total size to determine if we need progress UI
        var totalSize: Int64 = 0
        for url in urls {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        
        // Show progress for imports over 10MB
        let showProgress = totalSize > 10_000_000
        var progressWindow: NSWindow?
        var progressIndicator: NSProgressIndicator?
        var statusLabel: NSTextField?
        
        if showProgress, let parentWindow = window {
            let (pw, pi, sl) = createProgressWindow()
            progressWindow = pw
            progressIndicator = pi
            statusLabel = sl
            progressIndicator?.maxValue = Double(urls.count)
            parentWindow.beginSheet(pw) { _ in }
        }
        
        // Import each file
        for (index, sourceURL) in urls.enumerated() {
            if showProgress {
                statusLabel?.stringValue = "Importing \(sourceURL.lastPathComponent)..."
                progressIndicator?.doubleValue = Double(index)
            }
            
            logger.debug("importFiles: Processing [\(index + 1)/\(urls.count)]: '\(sourceURL.lastPathComponent, privacy: .public)'")

            // Verify source exists and is readable
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                logger.warning("importFiles: Source file does not exist")
                continue
            }
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                logger.warning("importFiles: Source file is not readable")
                continue
            }

            let format = detectFormat(url: sourceURL)
            logger.debug("importFiles: Format: \(format.formatName, privacy: .public)")
            
            let destinationURL = projectURL.appendingPathComponent(sourceURL.lastPathComponent)
            
            // Handle duplicates
            if fileManager.fileExists(atPath: destinationURL.path) {
                logger.debug("importFiles: Duplicate detected")
                
                // Hide progress temporarily for dialog
                if let pw = progressWindow, let parentWindow = window {
                    parentWindow.endSheet(pw)
                }
                
                let resolution = await showDuplicateAlert(for: sourceURL, window: window)
                
                // Re-show progress
                if let pw = progressWindow, let parentWindow = window {
                    parentWindow.beginSheet(pw) { _ in }
                }
                
                switch resolution {
                case .replace:
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        try fileManager.copyItem(at: sourceURL, to: destinationURL)
                        importedURLs.append(destinationURL)
                        logger.debug("importFiles: Replaced existing file")
                    } catch {
                        logger.error("importFiles: Error replacing file - \(error.localizedDescription, privacy: .public)")
                    }
                case .keepBoth:
                    let uniqueURL = generateUniqueURL(for: sourceURL, in: projectURL)
                    do {
                        try fileManager.copyItem(at: sourceURL, to: uniqueURL)
                        importedURLs.append(uniqueURL)
                        logger.debug("importFiles: Created copy '\(uniqueURL.lastPathComponent, privacy: .public)'")
                    } catch {
                        logger.error("importFiles: Error copying file - \(error.localizedDescription, privacy: .public)")
                    }
                case .skip:
                    logger.debug("importFiles: Skipped duplicate")
                }
            } else {
                // No duplicate - copy directly
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    importedURLs.append(destinationURL)
                    logger.debug("importFiles: Copied successfully")
                } catch {
                    logger.error("importFiles: Error copying file - \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Dismiss progress window
        if let pw = progressWindow, let parentWindow = window {
            progressIndicator?.doubleValue = Double(urls.count)
            statusLabel?.stringValue = "Import complete"
            try? await Task.sleep(for: .milliseconds(300))
            parentWindow.endSheet(pw)
        }

        logger.info("importFiles: Import completed - \(importedURLs.count) file(s) imported")
        return importedURLs
    }
    
    // MARK: - Duplicate Handling
    
    private func showDuplicateAlert(for sourceURL: URL, window: NSWindow?) async -> DuplicateResolution {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "A file named \"\(sourceURL.lastPathComponent)\" already exists in the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        
        let response: NSApplication.ModalResponse
        if let window = window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default: return .skip
        }
    }
    
    private func generateUniqueURL(for sourceURL: URL, in directory: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let fileManager = FileManager.default
        
        var counter = 2
        var newURL = directory.appendingPathComponent(ext.isEmpty ? "\(baseName) 2" : "\(baseName) 2.\(ext)")
        
        while fileManager.fileExists(atPath: newURL.path) {
            counter += 1
            newURL = directory.appendingPathComponent(ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)")
        }
        
        return newURL
    }
    
    // MARK: - Progress Window
    
    private func createProgressWindow() -> (NSWindow, NSProgressIndicator, NSTextField) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: true
        )
        window.title = "Importing Files"
        
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        
        let label = NSTextField(labelWithString: "Preparing to import...")
        label.frame = NSRect(x: 20, y: 60, width: 360, height: 20)
        label.font = .systemFont(ofSize: 13)
        contentView.addSubview(label)
        
        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 360, height: 20))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.doubleValue = 0
        contentView.addSubview(progress)
        
        window.contentView = contentView
        
        return (window, progress, label)
    }
}
