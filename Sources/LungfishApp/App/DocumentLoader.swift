// DocumentLoader.swift - Background document loading without MainActor blocking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

/// Logger for document loading operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "DocumentLoader")

// MARK: - Scan Result

/// Result of scanning a folder for supported files (lightweight, no parsing).
/// This is Sendable and can be safely passed between actors.
public struct FileScanResult: Sendable {
    public let url: URL
    public let type: DocumentType

    public init(url: URL, type: DocumentType) {
        self.url = url
        self.type = type
    }
}

// MARK: - Load Result

/// Result of loading a file's contents (full parsing).
/// This is Sendable and can be safely passed to MainActor.
public struct FileLoadResult: Sendable {
    public let url: URL
    public let type: DocumentType
    public let sequences: [Sequence]
    public let annotations: [SequenceAnnotation]
    public let error: String?

    public init(url: URL, type: DocumentType, sequences: [Sequence] = [], annotations: [SequenceAnnotation] = [], error: String? = nil) {
        self.url = url
        self.type = type
        self.sequences = sequences
        self.annotations = annotations
        self.error = error
    }
}

// MARK: - DocumentLoader

/// Background file loading actor that avoids MainActor blocking.
///
/// DocumentLoader performs all file I/O and parsing on background actors,
/// returning Sendable results that can be safely transferred to MainActor.
///
/// Usage:
/// ```swift
/// // Phase 1: Fast folder scan (synchronous, just reads directory entries)
/// let files = try DocumentLoader.scanFolder(at: folderURL)
///
/// // Phase 2: Background loading for each file
/// for scan in files {
///     Task.detached(priority: .userInitiated) {
///         let result = try await DocumentLoader.loadFile(at: scan.url, type: scan.type)
///         await MainActor.run {
///             // Update UI with result
///         }
///     }
/// }
/// ```
public enum DocumentLoader {

    /// Scans folder for supported files without parsing content.
    /// This is fast - only reads directory entries and checks file extensions.
    ///
    /// - Parameter folderURL: The folder URL to scan
    /// - Returns: Array of file scan results (URL + type)
    /// - Throws: DocumentLoadError if folder cannot be accessed
    public static func scanFolder(at folderURL: URL) throws -> [FileScanResult] {
        logger.info("scanFolder: Scanning \(folderURL.path, privacy: .public)")

        let fileManager = FileManager.default

        // Verify folder exists and is a directory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            logger.error("scanFolder: Not a valid directory: \(folderURL.path, privacy: .public)")
            throw DocumentLoadError.fileNotFound(folderURL)
        }

        var results: [FileScanResult] = []

        // Enumerate all files recursively
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            logger.error("scanFolder: Failed to create enumerator")
            throw DocumentLoadError.accessDenied(folderURL)
        }

        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

            // Treat custom package directories as leaf documents and skip descendants.
            if isDirectory.boolValue,
               (fileURL.pathExtension.lowercased() == "lungfishref" ||
                fileURL.pathExtension.lowercased() == MultipleSequenceAlignmentBundle.directoryExtension ||
                fileURL.pathExtension.lowercased() == "lungfishtree" ||
                fileURL.pathExtension.lowercased() == FASTQBundle.directoryExtension) {
                if let type = DocumentType.detect(from: fileURL) {
                    results.append(FileScanResult(url: fileURL, type: type))
                    logger.debug("scanFolder: Found package \(fileURL.lastPathComponent, privacy: .public) (\(type.rawValue, privacy: .public))")
                }
                enumerator.skipDescendants()
                continue
            }

            // Check if it's a supported file type
            if let type = DocumentType.detect(from: fileURL) {
                results.append(FileScanResult(url: fileURL, type: type))
                logger.debug("scanFolder: Found \(fileURL.lastPathComponent, privacy: .public) (\(type.rawValue, privacy: .public))")
            }
        }

        logger.info("scanFolder: Found \(results.count) supported files")
        return results
    }

    /// Loads file content on a background executor.
    /// This performs full parsing and may be slow for large files.
    ///
    /// - Parameters:
    ///   - url: The file URL to load
    ///   - type: The document type
    /// - Returns: FileLoadResult with parsed content
    /// - Throws: Error if file cannot be read or parsed
    public static func loadFile(at url: URL, type: DocumentType) async throws -> FileLoadResult {
        logger.info("loadFile: Loading \(url.lastPathComponent, privacy: .public) as \(type.rawValue, privacy: .public)")

        var sequences: [Sequence] = []
        var annotations: [SequenceAnnotation] = []

        switch type {
        case .fasta:
            let reader = try FASTAReader(url: url)
            sequences = try await reader.readAll()
            logger.info("loadFile: FASTA loaded \(sequences.count) sequences")

        case .fastq:
            // FASTQ files are handled by the streaming statistics dashboard
            // (MainSplitViewController.loadFASTQDatasetInBackground).
            // Return a lightweight marker document so the sidebar shows the file.
            logger.info("loadFile: FASTQ file detected — streaming dashboard will handle display")

        case .genbank:
            let reader = try GenBankReader(url: url)
            let records = try await reader.readAll()
            for record in records {
                sequences.append(record.sequence)
                annotations.append(contentsOf: record.annotations)
            }
            logger.info("loadFile: GenBank loaded \(sequences.count) sequences, \(annotations.count) annotations")

        case .gff3:
            let reader = GFF3Reader()
            annotations = try await reader.readAsAnnotations(from: url)
            logger.info("loadFile: GFF3 loaded \(annotations.count) annotations")

        case .bed:
            let reader = BEDReader()
            annotations = try await reader.readAsAnnotations(from: url)
            logger.info("loadFile: BED loaded \(annotations.count) annotations")

        case .vcf:
            // VCF files are handled by the streaming dashboard
            // (MainSplitViewController.loadVCFDatasetInBackground).
            // Return a lightweight marker document so the sidebar shows the file.
            logger.info("loadFile: VCF file detected — dashboard will handle display")

        case .bam:
            throw DocumentLoadError.unsupportedFormat("BAM/CRAM files are imported as alignment tracks. Use File \u{203A} Import Center\u{2026} with a bundle open.")

        case .lungfishProject:
            throw DocumentLoadError.unsupportedFormat("Use openProject for .lungfish files")

        case .lungfishReferenceBundle:
            throw DocumentLoadError.unsupportedFormat("Use displayBundle for .lungfishref bundles")

        case .lungfishMultipleSequenceAlignmentBundle:
            throw DocumentLoadError.unsupportedFormat("Use the MSA bundle viewer for .lungfishmsa bundles")

        case .lungfishPhylogeneticTreeBundle:
            throw DocumentLoadError.unsupportedFormat("Use the tree bundle viewer for .lungfishtree bundles")
        }

        return FileLoadResult(
            url: url,
            type: type,
            sequences: sequences,
            annotations: annotations,
            error: nil
        )
    }
}
