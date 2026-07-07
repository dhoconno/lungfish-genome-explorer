// ExtractionDestination.swift — Destination, outcome, options, and copy-format types
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - CopyFormat

/// Output format for extracted reads.
public enum CopyFormat: String, Sendable, CaseIterable, Hashable, Codable {
    /// Plain FASTQ with 4 lines per record.
    case fastq
    /// FASTA with 2 lines per record (quality dropped).
    case fasta
}

extension CopyFormat {
    var fileFormat: FileFormat {
        switch self {
        case .fastq: return .fastq
        case .fasta: return .fasta
        }
    }
}

// MARK: - ExtractionFileProvenance

/// Reproducibility context for standalone FASTQ/FASTA file exports.
///
/// Bundle destinations carry their provenance through ``ExtractionMetadata``.
/// Direct file/share destinations need the same context explicitly because
/// they do not have a bundle metadata file to hydrate from.
public struct ExtractionFileProvenance: Sendable, Hashable {

    public let workflowName: String
    public let toolName: String
    public let argv: [String]
    public let explicitOptions: [String: ParameterValue]
    public let defaults: [String: ParameterValue]
    public let resolved: [String: ParameterValue]

    public init(
        workflowName: String,
        toolName: String = "Lungfish.app",
        argv: [String],
        explicitOptions: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolved: [String: ParameterValue] = [:]
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.argv = argv
        self.explicitOptions = explicitOptions
        self.defaults = defaults
        self.resolved = resolved
    }

    public func mergingResolved(_ additionalValues: [String: ParameterValue]) -> ExtractionFileProvenance {
        var merged = resolved
        for (key, value) in additionalValues {
            merged[key] = value
        }
        return ExtractionFileProvenance(
            workflowName: workflowName,
            toolName: toolName,
            argv: argv,
            explicitOptions: explicitOptions,
            defaults: defaults,
            resolved: merged
        )
    }
}

// MARK: - ExtractionDestination

/// Where the extracted reads should go.
///
/// The resolver materializes a FASTQ to a temporary location first, then
/// transitions it to the destination-appropriate final location.
public enum ExtractionDestination: Sendable {

    /// Write the extracted FASTQ/FASTA to a user-chosen file URL.
    case file(URL)

    /// Package the extracted FASTQ into a `.lungfishfastq` bundle under the
    /// enclosing project root. The bundle is visible in the sidebar.
    ///
    /// - Parameters:
    ///   - projectRoot: The resolved `.lungfish/` project root directory.
    ///   - displayName: Human-readable bundle display name.
    ///   - metadata: Provenance metadata written into the bundle.
    case bundle(projectRoot: URL, displayName: String, metadata: ExtractionMetadata)

    /// Return the extracted FASTQ/FASTA string so the caller (GUI) can write
    /// it to `NSPasteboard`. Capped at `cap` records.
    case clipboard(format: CopyFormat, cap: Int)

    /// Write the extracted FASTQ into a stable location under `tempDirectory`
    /// so the GUI can hand the URL to `NSSharingServicePicker`.
    case share(tempDirectory: URL)
}

// MARK: - ExtractionOutcome

/// The successful result of a resolver extraction, one per destination case.
public enum ExtractionOutcome: Sendable {
    /// File destination completed; URL points to the finished FASTQ/FASTA.
    case file(URL, readCount: Int)

    /// Bundle destination completed; URL is the `.lungfishfastq` directory.
    case bundle(URL, readCount: Int)

    /// Clipboard destination completed. `payload` is the serialized
    /// FASTQ/FASTA text that the caller (the GUI) writes to `NSPasteboard`.
    /// `byteCount` is the payload length in bytes for quick display.
    case clipboard(payload: String, byteCount: Int, readCount: Int)

    /// Share destination completed; URL is the stable file ready for
    /// `NSSharingServicePicker`.
    case share(URL, readCount: Int)

    /// The number of reads the extraction produced.
    ///
    /// Matches the `MarkdupService.countReads` "Unique Reads" figure whenever
    /// the resolver was called with `includeUnmappedMates: false`.
    public var readCount: Int {
        switch self {
        case .file(_, let n),
             .bundle(_, let n),
             .share(_, let n):
            return n
        case .clipboard(_, _, let n):
            return n
        }
    }
}

// MARK: - ExtractionOptions

/// Per-invocation knobs that are independent of the destination.
public struct ExtractionOptions: Sendable, Hashable {

    /// Output format — FASTQ (default) or FASTA.
    public let format: CopyFormat

    /// When `true`, unmapped mates of mapped read pairs are kept in the output.
    ///
    /// Defaults to `false`. Ignored for Kraken2 (FASTQ-based; no concept of
    /// unmapped mates at this layer).
    public let includeUnmappedMates: Bool

    /// Optional provenance context for standalone file/share destinations.
    ///
    /// CLI extraction records provenance at the command layer, so this is nil
    /// by default. GUI file/share exports set it to request a focused sidecar
    /// next to the materialized FASTQ/FASTA.
    public let fileProvenance: ExtractionFileProvenance?

    /// Creates extraction options.
    ///
    /// - Parameters:
    ///   - format: Output format (default: `.fastq`).
    ///   - includeUnmappedMates: Keep unmapped mates of mapped pairs (default: `false`).
    ///   - fileProvenance: Optional standalone file/share export provenance context.
    public init(
        format: CopyFormat = .fastq,
        includeUnmappedMates: Bool = false,
        fileProvenance: ExtractionFileProvenance? = nil
    ) {
        self.format = format
        self.includeUnmappedMates = includeUnmappedMates
        self.fileProvenance = fileProvenance
    }

    /// Returns a copy that requests standalone file/share provenance sidecars.
    public func recordingFileProvenance(_ provenance: ExtractionFileProvenance) -> ExtractionOptions {
        ExtractionOptions(
            format: format,
            includeUnmappedMates: includeUnmappedMates,
            fileProvenance: provenance
        )
    }

    /// The samtools `-F` exclude-flag mask.
    ///
    /// - `0x404` (default, `includeUnmappedMates == false`): excludes
    ///   PCR/optical duplicates (`0x400`) AND unmapped reads (`0x004`).
    ///   Matches the `MarkdupService.countReads` filter used to populate the
    ///   "Unique Reads" column in classifier tables. This is the semantic the
    ///   user expects: extracted count == displayed count.
    /// - `0x400` (when `includeUnmappedMates == true`): excludes duplicates
    ///   only, keeping unmapped mates of mapped pairs. Useful when the user
    ///   wants both reads from a pair even if one didn't align.
    public var samtoolsExcludeFlags: Int {
        includeUnmappedMates ? 0x400 : 0x404
    }
}
