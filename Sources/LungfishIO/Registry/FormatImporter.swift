// FormatImporter.swift - Protocol for format importers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Part of the Format Registry system (DESIGN-003)

import Foundation
import LungfishCore

/// Protocol for types that can import files into GenomicDocument.
///
/// Implement this protocol to add support for reading a new file format.
/// Importers should be:
/// - Thread-safe (Sendable)
/// - Async-friendly (use async/await)
/// - Memory-efficient (stream large files when possible)
///
/// ## Example Implementation
/// ```swift
/// public final class FASTAImporter: FormatImporter {
///     public let descriptor: FormatDescriptor = FormatDescriptor(
///         identifier: .fasta,
///         displayName: "FASTA",
///         description: "Simple sequence format",
///         extensions: ["fa", "fasta"],
///         capabilities: .nucleotideSequence
///     )
///
///     public func canImport(url: URL) async -> Bool {
///         descriptor.matchesExtension(url)
///     }
///
///     public func importDocument(from url: URL) async throws -> ImportResult {
///         let reader = try FASTAReader(url: url)
///         let sequences = try await reader.readAll()
///         // ... create document from sequences
///     }
/// }
/// ```
public protocol FormatImporter: Sendable {

    /// The format descriptor for this importer
    var descriptor: FormatDescriptor { get }

    /// Check if this importer can handle the given URL.
    ///
    /// This should be a quick check based on file extension or magic bytes,
    /// not a full file parse.
    ///
    /// - Parameter url: The file URL to check
    /// - Returns: true if this importer can likely handle the file
    func canImport(url: URL) async -> Bool

    /// Import a document from the URL.
    ///
    /// - Parameter url: The file URL to import
    /// - Returns: The loaded document with sequences and annotations
    /// - Throws: ImportError or format-specific errors if import fails
    func importDocument(from url: URL) async throws -> ImportResult

    /// Import a document with progress reporting.
    ///
    /// - Parameters:
    ///   - url: The file URL to import
    ///   - progress: Callback for progress updates (0.0 to 1.0)
    /// - Returns: The loaded document
    /// - Throws: ImportError or format-specific errors if import fails
    func importDocument(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportResult

    /// Quickly scan the file for metadata without full parsing.
    ///
    /// This is useful for displaying file information before import.
    ///
    /// - Parameter url: The file URL to scan
    /// - Returns: Metadata about the file contents
    /// - Throws: If the file cannot be read
    func scanMetadata(from url: URL) async throws -> ImportMetadata
}

// MARK: - Default Implementations

extension FormatImporter {

    /// Default implementation without progress reporting
    public func importDocument(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportResult {
        // Default: no progress reporting
        try await importDocument(from: url)
    }

    /// Default implementation returns minimal metadata
    public func scanMetadata(from url: URL) async throws -> ImportMetadata {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes?[.size] as? Int64

        return ImportMetadata(
            formatIdentifier: descriptor.identifier,
            estimatedRecordCount: nil,
            estimatedSize: fileSize,
            sequenceNames: nil,
            organism: nil,
            accession: nil
        )
    }

    /// Default canImport checks file extension
    public func canImport(url: URL) async -> Bool {
        descriptor.matchesExtension(url)
    }
}

// MARK: - ImportResult

/// Result of importing a file, containing sequences and metadata.
///
/// ImportResult is a lightweight container for import results before
/// creating a full GenomicDocument.
public struct ImportResult: Sendable {

    /// Sequences loaded from the file
    public let sequences: [Sequence]

    /// Annotations grouped by sequence name
    public let annotationsBySequence: [String: [SequenceAnnotation]]

    /// Document metadata
    public let metadata: LoadedMetadata

    /// Source file URL
    public let sourceURL: URL

    /// Format that was imported
    public let sourceFormat: FormatIdentifier

    /// Creates a loaded document with sequences only
    public init(
        sequences: [Sequence],
        sourceURL: URL,
        sourceFormat: FormatIdentifier,
        metadata: LoadedMetadata = LoadedMetadata()
    ) {
        self.sequences = sequences
        self.annotationsBySequence = [:]
        self.sourceURL = sourceURL
        self.sourceFormat = sourceFormat
        self.metadata = metadata
    }

    /// Creates a loaded document with sequences and annotations
    public init(
        sequences: [Sequence],
        annotationsBySequence: [String: [SequenceAnnotation]],
        sourceURL: URL,
        sourceFormat: FormatIdentifier,
        metadata: LoadedMetadata = LoadedMetadata()
    ) {
        self.sequences = sequences
        self.annotationsBySequence = annotationsBySequence
        self.sourceURL = sourceURL
        self.sourceFormat = sourceFormat
        self.metadata = metadata
    }

    /// Creates a loaded document with annotations only (no sequences)
    public init(
        annotationsBySequence: [String: [SequenceAnnotation]],
        sourceURL: URL,
        sourceFormat: FormatIdentifier,
        metadata: LoadedMetadata = LoadedMetadata()
    ) {
        self.sequences = []
        self.annotationsBySequence = annotationsBySequence
        self.sourceURL = sourceURL
        self.sourceFormat = sourceFormat
        self.metadata = metadata
    }

    /// Total number of sequences
    public var sequenceCount: Int { sequences.count }

    /// Total number of annotations
    public var annotationCount: Int {
        annotationsBySequence.values.reduce(0) { $0 + $1.count }
    }

    /// Total length of all sequences
    public var totalLength: Int {
        sequences.reduce(0) { $0 + $1.length }
    }
}

// MARK: - LoadedMetadata

/// Metadata extracted during import
public struct LoadedMetadata: Sendable {

    /// Source organism
    public var organism: String?

    /// Taxonomy ID
    public var taxonomyID: Int?

    /// Assembly name
    public var assemblyName: String?

    /// Accession number
    public var accession: String?

    /// Data source (e.g., "NCBI", "ENA")
    public var source: String?

    /// Additional custom metadata
    public var custom: [String: String]

    public init(
        organism: String? = nil,
        taxonomyID: Int? = nil,
        assemblyName: String? = nil,
        accession: String? = nil,
        source: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.organism = organism
        self.taxonomyID = taxonomyID
        self.assemblyName = assemblyName
        self.accession = accession
        self.source = source
        self.custom = custom
    }
}

// MARK: - ImportMetadata

/// Metadata about a file's contents from quick scan
public struct ImportMetadata: Sendable {

    /// Format of the file
    public let formatIdentifier: FormatIdentifier

    /// Estimated number of records (sequences, features, etc.)
    public let estimatedRecordCount: Int?

    /// File size in bytes
    public let estimatedSize: Int64?

    /// Names of sequences in the file
    public var sequenceNames: [String]?

    /// Organism from metadata
    public var organism: String?

    /// Accession number
    public var accession: String?

    /// Additional custom metadata
    public var customMetadata: [String: String]

    public init(
        formatIdentifier: FormatIdentifier,
        estimatedRecordCount: Int? = nil,
        estimatedSize: Int64? = nil,
        sequenceNames: [String]? = nil,
        organism: String? = nil,
        accession: String? = nil,
        customMetadata: [String: String] = [:]
    ) {
        self.formatIdentifier = formatIdentifier
        self.estimatedRecordCount = estimatedRecordCount
        self.estimatedSize = estimatedSize
        self.sequenceNames = sequenceNames
        self.organism = organism
        self.accession = accession
        self.customMetadata = customMetadata
    }
}

// MARK: - ImportError

/// Errors that can occur during file import
public enum ImportError: Error, LocalizedError, Sendable {

    /// File not found at the specified URL
    case fileNotFound(URL)

    /// File format not recognized
    case unknownFormat(URL)

    /// No importer available for this format
    case noImporterAvailable(FormatIdentifier)

    /// File encoding is invalid
    case invalidEncoding(URL)

    /// File is corrupted or malformed
    case corruptedFile(URL, details: String)

    /// Import was cancelled
    case cancelled

    /// Generic import error
    case importFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unknownFormat(let url):
            return "Unknown file format: \(url.lastPathComponent)"
        case .noImporterAvailable(let format):
            return "No importer available for format: \(format.id)"
        case .invalidEncoding(let url):
            return "Invalid file encoding: \(url.lastPathComponent)"
        case .corruptedFile(let url, let details):
            return "Corrupted file \(url.lastPathComponent): \(details)"
        case .cancelled:
            return "Import was cancelled"
        case .importFailed(let underlying):
            return "Import failed: \(underlying.localizedDescription)"
        }
    }
}
