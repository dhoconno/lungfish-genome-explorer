// ImportService.swift - Unified file import with auto-detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import UniformTypeIdentifiers
import os.log

/// Logger for import operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "ImportService")

/// Represents a detected file type with its category
public enum FileCategory: String, CaseIterable, Sendable {
    case sequence, annotation, alignment, variant, coverage, index, document, image, compressed, unknown
    
    public var displayName: String {
        switch self {
        case .sequence: return "Sequence"
        case .annotation: return "Annotation"
        case .alignment: return "Alignment"
        case .variant: return "Variant"
        case .coverage: return "Coverage"
        case .index: return "Index"
        case .document: return "Document"
        case .image: return "Image"
        case .compressed: return "Compressed"
        case .unknown: return "Other"
        }
    }
    
    public var iconName: String {
        switch self {
        case .sequence: return "doc.text"
        case .annotation: return "list.bullet.rectangle"
        case .alignment: return "chart.bar"
        case .variant: return "chart.bar.xaxis"
        case .coverage: return "waveform.path.ecg"
        case .index: return "doc.badge.gearshape"
        case .document: return "doc.richtext"
        case .image: return "photo"
        case .compressed: return "archivebox"
        case .unknown: return "doc"
        }
    }
}

/// Detected file format information
public struct DetectedFormat: Sendable {
    public let category: FileCategory
    public let formatId: String
    public let formatName: String
    public let fileExtension: String
    public let isGenomicsFormat: Bool
    public let supportsQuickLook: Bool
    
    public init(
        category: FileCategory,
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
    
    // MARK: - Properties
    
    private let formatMap: [String: DetectedFormat]
    
    // MARK: - Initialization
    
    private init() {
        var map: [String: DetectedFormat] = [:]
        
        // Sequence formats
        for ext in ["fasta", "fa", "fna", "faa", "ffn", "frn", "fas"] {
            map[ext] = DetectedFormat(category: .sequence, formatId: "fasta", formatName: "FASTA", fileExtension: ext, isGenomicsFormat: true, supportsQuickLook: false)
        }
        for ext in ["fastq", "fq"] {
            map[ext] = DetectedFormat(category: .sequence, formatId: "fastq", formatName: "FASTQ", fileExtension: ext, isGenomicsFormat: true, supportsQuickLook: false)
        }
        for ext in ["gb", "gbk", "genbank", "gbff"] {
            map[ext] = DetectedFormat(category: .sequence, formatId: "genbank", formatName: "GenBank", fileExtension: ext, isGenomicsFormat: true, supportsQuickLook: false)
        }
        map["embl"] = DetectedFormat(category: .sequence, formatId: "embl", formatName: "EMBL", fileExtension: "embl", isGenomicsFormat: true, supportsQuickLook: false)
        
        // Annotation formats
        for ext in ["gff", "gff3"] {
            map[ext] = DetectedFormat(category: .annotation, formatId: "gff3", formatName: "GFF3", fileExtension: ext, isGenomicsFormat: true, supportsQuickLook: false)
        }
        map["gtf"] = DetectedFormat(category: .annotation, formatId: "gtf", formatName: "GTF", fileExtension: "gtf", isGenomicsFormat: true, supportsQuickLook: false)
        map["bed"] = DetectedFormat(category: .annotation, formatId: "bed", formatName: "BED", fileExtension: "bed", isGenomicsFormat: true, supportsQuickLook: false)
        
        // Variant formats
        map["vcf"] = DetectedFormat(category: .variant, formatId: "vcf", formatName: "VCF", fileExtension: "vcf", isGenomicsFormat: true, supportsQuickLook: false)
        map["bcf"] = DetectedFormat(category: .variant, formatId: "bcf", formatName: "BCF", fileExtension: "bcf", isGenomicsFormat: true, supportsQuickLook: false)
        
        // Alignment formats
        map["bam"] = DetectedFormat(category: .alignment, formatId: "bam", formatName: "BAM", fileExtension: "bam", isGenomicsFormat: true, supportsQuickLook: false)
        map["sam"] = DetectedFormat(category: .alignment, formatId: "sam", formatName: "SAM", fileExtension: "sam", isGenomicsFormat: true, supportsQuickLook: false)
        map["cram"] = DetectedFormat(category: .alignment, formatId: "cram", formatName: "CRAM", fileExtension: "cram", isGenomicsFormat: true, supportsQuickLook: false)
        
        // Coverage formats
        for ext in ["bw", "bigwig"] {
            map[ext] = DetectedFormat(category: .coverage, formatId: "bigwig", formatName: "BigWig", fileExtension: ext, isGenomicsFormat: true, supportsQuickLook: false)
        }
        for ext in ["bb", "bigbed"] {
            map[ext] = DetectedFormat(category: .coverage, formatId: "bigbed", formatName: "BigBed", fileExtension: ext, isGenomicsFormat: true, supportsQuickLook: false)
        }
        map["bedgraph"] = DetectedFormat(category: .coverage, formatId: "bedgraph", formatName: "bedGraph", fileExtension: "bedgraph", isGenomicsFormat: true, supportsQuickLook: false)
        
        // Index formats
        map["fai"] = DetectedFormat(category: .index, formatId: "fai", formatName: "FASTA Index", fileExtension: "fai", isGenomicsFormat: true, supportsQuickLook: false)
        map["bai"] = DetectedFormat(category: .index, formatId: "bai", formatName: "BAM Index", fileExtension: "bai", isGenomicsFormat: true, supportsQuickLook: false)
        
        // Document formats
        map["pdf"] = DetectedFormat(category: .document, formatId: "pdf", formatName: "PDF", fileExtension: "pdf", isGenomicsFormat: false, supportsQuickLook: true)
        for ext in ["txt", "text"] {
            map[ext] = DetectedFormat(category: .document, formatId: "text", formatName: "Plain Text", fileExtension: ext, isGenomicsFormat: false, supportsQuickLook: true)
        }
        map["md"] = DetectedFormat(category: .document, formatId: "markdown", formatName: "Markdown", fileExtension: "md", isGenomicsFormat: false, supportsQuickLook: true)
        map["rtf"] = DetectedFormat(category: .document, formatId: "rtf", formatName: "Rich Text", fileExtension: "rtf", isGenomicsFormat: false, supportsQuickLook: true)
        map["csv"] = DetectedFormat(category: .document, formatId: "csv", formatName: "CSV", fileExtension: "csv", isGenomicsFormat: false, supportsQuickLook: true)
        map["tsv"] = DetectedFormat(category: .document, formatId: "tsv", formatName: "TSV", fileExtension: "tsv", isGenomicsFormat: false, supportsQuickLook: true)
        
        // Image formats
        map["png"] = DetectedFormat(category: .image, formatId: "png", formatName: "PNG Image", fileExtension: "png", isGenomicsFormat: false, supportsQuickLook: true)
        for ext in ["jpg", "jpeg"] {
            map[ext] = DetectedFormat(category: .image, formatId: "jpeg", formatName: "JPEG Image", fileExtension: ext, isGenomicsFormat: false, supportsQuickLook: true)
        }
        map["tiff"] = DetectedFormat(category: .image, formatId: "tiff", formatName: "TIFF Image", fileExtension: "tiff", isGenomicsFormat: false, supportsQuickLook: true)
        map["svg"] = DetectedFormat(category: .image, formatId: "svg", formatName: "SVG Image", fileExtension: "svg", isGenomicsFormat: false, supportsQuickLook: true)
        
        // Compressed formats
        map["gz"] = DetectedFormat(category: .compressed, formatId: "gzip", formatName: "Gzip Compressed", fileExtension: "gz", isGenomicsFormat: false, supportsQuickLook: false)
        map["zip"] = DetectedFormat(category: .compressed, formatId: "zip", formatName: "ZIP Archive", fileExtension: "zip", isGenomicsFormat: false, supportsQuickLook: true)
        
        self.formatMap = map
    }
    
    // MARK: - Format Detection
    
    public func detectFormat(url: URL) -> DetectedFormat {
        let ext = url.pathExtension.lowercased()
        
        // Handle compound extensions like .fastq.gz
        if ext == "gz" {
            let innerExt = url.deletingPathExtension().pathExtension.lowercased()
            if !innerExt.isEmpty, let innerFormat = formatMap[innerExt] {
                return DetectedFormat(
                    category: innerFormat.category,
                    formatId: innerFormat.formatId,
                    formatName: innerFormat.formatName + " (compressed)",
                    fileExtension: "\(innerExt).gz",
                    isGenomicsFormat: innerFormat.isGenomicsFormat,
                    supportsQuickLook: false
                )
            }
        }
        
        if let format = formatMap[ext] {
            return format
        }
        
        return DetectedFormat(
            category: .unknown,
            formatId: ext.isEmpty ? "unknown" : ext,
            formatName: ext.isEmpty ? "Unknown" : ext.uppercased(),
            fileExtension: ext,
            isGenomicsFormat: false,
            supportsQuickLook: true
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
        print("[ImportService] showImportDialogAndImport: Starting for project at \(projectURL.path)")
        
        // Create and configure the open panel
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.message = "Select files to import into the project"
        panel.prompt = "Import"
        
        print("[ImportService] Showing open panel as sheet...")
        
        // Show the panel as a sheet and wait for response
        let response = await panel.beginSheetModal(for: window)
        
        print("[ImportService] Panel response: \(response.rawValue)")
        
        guard response == .OK else {
            print("[ImportService] User cancelled")
            return []
        }
        
        let selectedURLs = panel.urls
        guard !selectedURLs.isEmpty else {
            print("[ImportService] No files selected")
            return []
        }
        
        print("[ImportService] Selected \(selectedURLs.count) file(s)")
        for url in selectedURLs {
            print("[ImportService]   - \(url.lastPathComponent)")
        }
        
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
        print("[ImportService] importFiles: Starting import of \(urls.count) file(s)")
        
        let fileManager = FileManager.default
        var importedURLs: [URL] = []
        
        // Verify project directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("[ImportService] ERROR: Project directory does not exist: \(projectURL.path)")
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
            
            print("[ImportService] Processing [\(index + 1)/\(urls.count)]: \(sourceURL.lastPathComponent)")
            
            // Verify source exists and is readable
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                print("[ImportService] ERROR: Source file does not exist")
                continue
            }
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                print("[ImportService] ERROR: Source file is not readable")
                continue
            }
            
            let format = detectFormat(url: sourceURL)
            print("[ImportService] Format: \(format.formatName)")
            
            let destinationURL = projectURL.appendingPathComponent(sourceURL.lastPathComponent)
            
            // Handle duplicates
            if fileManager.fileExists(atPath: destinationURL.path) {
                print("[ImportService] Duplicate detected")
                
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
                        print("[ImportService] Replaced existing file")
                    } catch {
                        print("[ImportService] ERROR replacing: \(error)")
                    }
                case .keepBoth:
                    let uniqueURL = generateUniqueURL(for: sourceURL, in: projectURL)
                    do {
                        try fileManager.copyItem(at: sourceURL, to: uniqueURL)
                        importedURLs.append(uniqueURL)
                        print("[ImportService] Created copy: \(uniqueURL.lastPathComponent)")
                    } catch {
                        print("[ImportService] ERROR copying: \(error)")
                    }
                case .skip:
                    print("[ImportService] Skipped duplicate")
                }
            } else {
                // No duplicate - copy directly
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    importedURLs.append(destinationURL)
                    print("[ImportService] Copied successfully")
                } catch {
                    print("[ImportService] ERROR copying: \(error)")
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
        
        print("[ImportService] Import completed: \(importedURLs.count) file(s) imported")
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
