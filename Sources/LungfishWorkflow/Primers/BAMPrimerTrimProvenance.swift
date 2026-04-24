// BAMPrimerTrimProvenance.swift - JSON sidecar describing a BAM primer-trim run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Provenance record describing a single BAM primer-trim run.
///
/// Written as a JSON sidecar next to the trimmed BAM by
/// `BAMPrimerTrimPipeline`, using snake_case wire keys so the file is readable
/// from non-Swift tooling. Round-trips losslessly through `JSONEncoder` and
/// `JSONDecoder` when both use `.iso8601` date handling.
public struct BAMPrimerTrimProvenance: Codable, Sendable, Equatable {
    /// Short operation identifier, e.g. `"primer-trim"`.
    public let operation: String

    /// Reference to the primer scheme used for this run.
    public let primerScheme: PrimerSchemeRef

    /// Project-relative path to the source BAM that was trimmed.
    public let sourceBAMRelativePath: String

    /// Version string reported by the invoked `ivar` binary.
    public let ivarVersion: String

    /// Literal argument list passed to `ivar trim` (excluding the program name).
    public let ivarTrimArgs: [String]

    /// Wall-clock timestamp at which the pipeline wrote this record.
    public let timestamp: Date

    /// Minimal reference to the primer scheme whose BED drove the trim.
    public struct PrimerSchemeRef: Codable, Sendable, Equatable {
        /// Human-readable bundle name (manifest `name`).
        public let bundleName: String

        /// Origin of the bundle (e.g. `"built-in"`, `"imported"`).
        public let bundleSource: String

        /// Bundle version string if declared; `nil` when the manifest omits it.
        public let bundleVersion: String?

        /// Canonical reference accession the primer coordinates were authored against.
        public let canonicalAccession: String

        enum CodingKeys: String, CodingKey {
            case bundleName = "bundle_name"
            case bundleSource = "bundle_source"
            case bundleVersion = "bundle_version"
            case canonicalAccession = "canonical_accession"
        }
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case primerScheme = "primer_scheme"
        case sourceBAMRelativePath = "source_bam"
        case ivarVersion = "ivar_version"
        case ivarTrimArgs = "ivar_trim_args"
        case timestamp
    }

    /// Creates a provenance record from the pipeline's observed values.
    /// - Parameters:
    ///   - operation: Short operation identifier, e.g. `"primer-trim"`.
    ///   - primerScheme: Minimal reference to the primer scheme used.
    ///   - sourceBAMRelativePath: Project-relative path to the source BAM.
    ///   - ivarVersion: Version string reported by `ivar`.
    ///   - ivarTrimArgs: Literal argument list passed to `ivar trim`.
    ///   - timestamp: Wall-clock timestamp for the run.
    public init(
        operation: String,
        primerScheme: PrimerSchemeRef,
        sourceBAMRelativePath: String,
        ivarVersion: String,
        ivarTrimArgs: [String],
        timestamp: Date
    ) {
        self.operation = operation
        self.primerScheme = primerScheme
        self.sourceBAMRelativePath = sourceBAMRelativePath
        self.ivarVersion = ivarVersion
        self.ivarTrimArgs = ivarTrimArgs
        self.timestamp = timestamp
    }
}
