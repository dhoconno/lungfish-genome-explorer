// ReferenceBundleImportService.swift - Import standalone sequence files as .lungfishref bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let referenceImportLogger = Logger(subsystem: LogSubsystem.app, category: "ReferenceBundleImport")

/// Classification of an input file for sidebar/import-center routing.
public enum ReferenceImportClassification: Sendable, Equatable {
    /// Standalone sequence source that should become a new `.lungfishref` bundle.
    case standaloneReferenceSequence
    /// Annotation track source that should attach to an existing reference bundle.
    case annotationTrack
    /// Variant source that should attach to an existing reference bundle or use existing VCF flow.
    case variantTrack
    /// Alignment source that should attach to an existing reference bundle.
    case alignmentTrack
    /// Not a supported import source for bundle creation.
    case unsupported
}

/// Result of creating a `.lungfishref` bundle from an imported sequence file.
public struct ReferenceBundleImportResult: Sendable {
    /// URL to the created bundle.
    public let bundleURL: URL
    /// Effective bundle display name used during creation.
    public let bundleName: String

    public init(bundleURL: URL, bundleName: String) {
        self.bundleURL = bundleURL
        self.bundleName = bundleName
    }
}

/// Errors thrown by `ReferenceBundleImportService`.
public enum ReferenceBundleImportError: Error, LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(URL)
    case noSequencesFound(URL)
    case decompressionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let url):
            return "Unsupported reference import format: \(url.lastPathComponent)"
        case .noSequencesFound(let url):
            return "No sequences were found in \(url.lastPathComponent)"
        case .decompressionFailed(let message):
            return "Failed to decompress input: \(message)"
        }
    }
}

/// Imports sequence files as standalone `.lungfishref` bundles.
///
/// This service is used by both sidebar drag/drop import and Import Center
/// to ensure identical bundle output structure.
public final class ReferenceBundleImportService: @unchecked Sendable {
    public static let shared = ReferenceBundleImportService()

    private init() {}

    /// Compression wrappers accepted for standalone reference inputs.
    public static let compressionExtensions: Set<String> = ["gz", "gzip", "bgz", "bz2", "xz", "zst", "zstd"]

    /// Sequence formats that should become standalone `.lungfishref` bundles.
    ///
    /// FASTQ is intentionally excluded because it uses `.lungfishfastq` bundles.
    public static let standaloneReferenceExtensions: Set<String> = [
        "fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn",
        "gb", "gbk", "genbank", "gbff", "embl",
    ]

    /// Annotation-like file formats that should be attached to existing references.
    public static let annotationExtensions: Set<String> = ["gff", "gff3", "gtf", "bed"]

    /// Variant-like file formats that should be attached to existing references.
    public static let variantExtensions: Set<String> = ["vcf", "bcf"]

    /// Alignment-like file formats that should be attached to existing references.
    public static let alignmentExtensions: Set<String> = ["bam", "sam", "cram"]

    /// All standalone reference extensions in sorted order for UI registration.
    public static var sortedStandaloneReferenceExtensions: [String] {
        standaloneReferenceExtensions.sorted()
    }

    /// Returns the normalized extension (peeking through compression wrappers).
    public static func normalizedExtension(for url: URL) -> String {
        var ext = url.pathExtension.lowercased()
        if compressionExtensions.contains(ext) {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        return ext
    }

    /// Classifies an input URL for import routing.
    public static func classify(_ url: URL) -> ReferenceImportClassification {
        let ext = normalizedExtension(for: url)

        if standaloneReferenceExtensions.contains(ext) {
            return .standaloneReferenceSequence
        }
        if annotationExtensions.contains(ext) {
            return .annotationTrack
        }
        if variantExtensions.contains(ext) {
            return .variantTrack
        }
        if alignmentExtensions.contains(ext) {
            return .alignmentTrack
        }
        return .unsupported
    }

    /// Returns `true` if the source should be imported as a standalone `.lungfishref` bundle.
    public static func isStandaloneReferenceSource(_ url: URL) -> Bool {
        classify(url) == .standaloneReferenceSequence
    }

    /// Imports a supported standalone sequence source into `outputDirectory` as a `.lungfishref` bundle.
    public func importAsReferenceBundle(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String? = nil,
        provenanceWorkflowName: String? = "lungfish reference import",
        provenanceCommand: [String]? = nil,
        provenanceInputFiles: [URL]? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ReferenceBundleImportResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ReferenceBundleImportError.fileNotFound(sourceURL)
        }

        guard Self.isStandaloneReferenceSource(sourceURL) else {
            throw ReferenceBundleImportError.unsupportedFormat(sourceURL)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        OperationMarker.markInProgress(outputDirectory, detail: "Importing reference bundle\u{2026}")
        defer { OperationMarker.clearInProgress(outputDirectory) }

        let baseName = sanitizedBaseName(preferredBundleName ?? defaultBundleName(for: sourceURL))
        let bundleName = makeUniqueBundleName(base: baseName, in: outputDirectory)

        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "ref-import-", contextURL: outputDirectory)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        progressHandler?(0.02, "Preparing reference input...")

        let prepared = try await ReferenceSourcePreparer().prepare(
            sourceURL: sourceURL,
            bundleName: bundleName,
            tempDirectory: tempDirectory
        )

        let configuration = BuildConfiguration(
            name: bundleName,
            identifier: "org.lungfish.import.\(UUID().uuidString.lowercased())",
            fastaURL: prepared.fastaURL,
            annotationFiles: prepared.annotationInputs,
            outputDirectory: outputDirectory,
            source: prepared.sourceInfo,
            compressFASTA: true,
            provenanceWorkflowName: provenanceWorkflowName,
            provenanceCommand: provenanceCommand ?? defaultProvenanceCommand(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                bundleName: bundleName,
                isEnabled: provenanceWorkflowName != nil
            ),
            provenanceInputFiles: provenanceInputFiles ?? (provenanceWorkflowName == nil ? nil : [sourceURL]),
            warnings: prepared.warnings.map(\.bundleWarning),
            referenceRecordStoreURL: prepared.recordStoreURL
        )

        let builder = await NativeBundleBuilder()

        let bundleURL = try await builder.build(configuration: configuration) { _, progress, message in
            progressHandler?(progress, message)
        }

        referenceImportLogger.info(
            "Created reference bundle \(bundleURL.lastPathComponent, privacy: .public) from \(sourceURL.lastPathComponent, privacy: .public)"
        )

        return ReferenceBundleImportResult(bundleURL: bundleURL, bundleName: bundleName)
    }

    // MARK: - Internal Helpers

    private func makeUniqueBundleName(base: String, in directory: URL) -> String {
        var candidate = base
        var counter = 2

        while FileManager.default.fileExists(atPath: bundleURL(forBundleName: candidate, in: directory).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }

        return candidate
    }

    private func bundleURL(forBundleName bundleName: String, in directory: URL) -> URL {
        let safeName = bundleName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safeName).lungfishref", isDirectory: true)
    }

    private func defaultBundleName(for sourceURL: URL) -> String {
        var stripped = sourceURL
        while !stripped.pathExtension.isEmpty {
            stripped = stripped.deletingPathExtension()
        }
        let base = stripped.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Imported Reference" : base
    }

    private func sanitizedBaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Imported Reference" }
        return trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func defaultProvenanceCommand(
        sourceURL: URL,
        outputDirectory: URL,
        bundleName: String,
        isEnabled: Bool
    ) -> [String]? {
        guard isEnabled else { return nil }
        return [
            "lungfish-app",
            "reference-bundle-import",
            sourceURL.standardizedFileURL.path,
            "--output-directory",
            outputDirectory.standardizedFileURL.path,
            "--name",
            bundleName,
        ]
    }

}
