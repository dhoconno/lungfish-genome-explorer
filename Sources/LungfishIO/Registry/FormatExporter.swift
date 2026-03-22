// FormatExporter.swift - Protocol for format exporters
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Part of the Format Registry system (DESIGN-003)

import Foundation
import LungfishCore

/// Protocol for types that can export documents to files.
///
/// Implement this protocol to add support for writing a new file format.
/// Exporters should be:
/// - Thread-safe (Sendable)
/// - Async-friendly (use async/await)
/// - Memory-efficient (stream large documents when possible)
///
/// ## Example Implementation
/// ```swift
/// public final class FASTAExporter: FormatExporter {
///     public let descriptor: FormatDescriptor = FormatDescriptor(
///         identifier: .fasta,
///         displayName: "FASTA",
///         description: "Simple sequence format",
///         extensions: ["fa", "fasta"],
///         capabilities: .nucleotideSequence
///     )
///
///     public var requiredCapabilities: DocumentCapability { .nucleotideSequence }
///
///     public func canExport(document: ImportResult) -> Bool {
///         !document.sequences.isEmpty
///     }
///
///     public func export(document: ImportResult, to url: URL) async throws {
///         let writer = FASTAWriter(url: url)
///         try writer.write(document.sequences)
///     }
/// }
/// ```
public protocol FormatExporter: Sendable {

    /// The format descriptor for this exporter
    var descriptor: FormatDescriptor { get }

    /// Capabilities required for export (document must have all of these)
    var requiredCapabilities: DocumentCapability { get }

    /// Check if this exporter can handle the document.
    ///
    /// - Parameter document: The document to check
    /// - Returns: true if this exporter can export the document
    func canExport(document: ImportResult) -> Bool

    /// Export the document to the URL.
    ///
    /// - Parameters:
    ///   - document: The document to export
    ///   - url: The destination file URL
    /// - Throws: ExportError or format-specific errors if export fails
    func export(document: ImportResult, to url: URL) async throws

    /// Export the document with progress reporting.
    ///
    /// - Parameters:
    ///   - document: The document to export
    ///   - url: The destination file URL
    ///   - progress: Callback for progress updates (0.0 to 1.0)
    /// - Throws: ExportError or format-specific errors if export fails
    func export(
        document: ImportResult,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Get warnings about data that will be lost when exporting to this format.
    ///
    /// - Parameter document: The document to check
    /// - Returns: Array of warnings about data loss
    func dataLossWarnings(for document: ImportResult) -> [DataLossWarning]
}

// MARK: - Default Implementations

extension FormatExporter {

    /// Default implementation without progress reporting
    public func export(
        document: ImportResult,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Default: no progress reporting
        try await export(document: document, to: url)
    }

    /// Default implementation returns no warnings
    public func dataLossWarnings(for document: ImportResult) -> [DataLossWarning] {
        []
    }

    /// Default canExport checks if document has required capabilities
    public func canExport(document: ImportResult) -> Bool {
        // Check that document has sequences if nucleotide/protein sequences are required
        if requiredCapabilities.contains(.nucleotideSequence) ||
           requiredCapabilities.contains(.aminoAcidSequence) {
            return !document.sequences.isEmpty
        }

        // Check that document has annotations if annotations are required
        if requiredCapabilities.contains(.annotations) {
            return document.annotationCount > 0
        }

        return true
    }
}

// MARK: - DataLossWarning

/// Warning about data that will be lost during export
public struct DataLossWarning: Sendable, Equatable {

    /// Severity level of the warning
    public let severity: Severity

    /// Human-readable warning message
    public let message: String

    /// The capability that will be lost
    public let affectedCapability: DocumentCapability

    /// Severity levels for data loss warnings
    public enum Severity: String, Sendable, CaseIterable {
        /// Informational - minor data loss
        case info

        /// Warning - significant data may be lost
        case warning

        /// Critical - important data will be lost
        case critical
    }

    public init(severity: Severity, message: String, affectedCapability: DocumentCapability) {
        self.severity = severity
        self.message = message
        self.affectedCapability = affectedCapability
    }
}


// MARK: - ExportError

/// Errors that can occur during file export
public enum ExportError: Error, LocalizedError, Sendable {

    /// Cannot write to the specified URL
    case cannotWriteToURL(URL)

    /// No exporter available for this format
    case noExporterAvailable(FormatIdentifier)

    /// Document is incompatible with the format
    case incompatibleDocument(format: FormatIdentifier, reason: String)

    /// Document lacks required capabilities
    case missingCapabilities(required: DocumentCapability, provided: DocumentCapability)

    /// Export was cancelled
    case cancelled

    /// Generic export error
    case exportFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .cannotWriteToURL(let url):
            return "Cannot write to: \(url.path)"
        case .noExporterAvailable(let format):
            return "No exporter available for format: \(format.id)"
        case .incompatibleDocument(let format, let reason):
            return "Document is incompatible with \(format.id): \(reason)"
        case .missingCapabilities(let required, _):
            return "Document is missing required capabilities: \(required)"
        case .cancelled:
            return "Export was cancelled"
        case .exportFailed(let underlying):
            return "Export failed: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Standard Data Loss Warnings

extension DataLossWarning {

    /// Warning for losing quality scores (FASTQ -> FASTA)
    public static let qualityScoresLost = DataLossWarning(
        severity: .warning,
        message: "Quality scores will be lost",
        affectedCapability: .qualityScores
    )

    /// Warning for losing annotations (GenBank -> FASTA)
    public static let annotationsLost = DataLossWarning(
        severity: .warning,
        message: "Annotations will be lost",
        affectedCapability: .annotations
    )

    /// Warning for losing rich metadata
    public static let metadataLost = DataLossWarning(
        severity: .info,
        message: "Some metadata will be lost",
        affectedCapability: .richMetadata
    )

    /// Warning for losing paired-end information
    public static let pairedReadsLost = DataLossWarning(
        severity: .critical,
        message: "Paired-end read information will be lost",
        affectedCapability: .pairedReads
    )

    /// Warning for losing alignment information
    public static let alignmentLost = DataLossWarning(
        severity: .critical,
        message: "Alignment information will be lost",
        affectedCapability: .alignment
    )

    /// Warning for losing circular topology
    public static let circularTopologyLost = DataLossWarning(
        severity: .info,
        message: "Circular topology information will be lost",
        affectedCapability: .circularTopology
    )
}
