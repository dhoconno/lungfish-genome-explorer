// ReferenceCandidate.swift - Reference sequence discovery for operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A reference sequence available for selection in operations requiring one
/// (contaminant filtering, orientation, primer removal, mapping).
///
/// Discovered by scanning the project's Reference Sequences folder, genome
/// bundles, and standalone FASTA files. Presented in operation configuration
/// panel dropdowns grouped by source.
public enum ReferenceCandidate: Sendable, Identifiable, Equatable {
    /// A `.lungfishref` bundle from the project's "Reference Sequences" folder.
    case projectReference(url: URL, manifest: ReferenceSequenceManifest)

    /// A FASTA file from a `.lungfishref` genome bundle (e.g., from Downloads).
    case genomeBundleFASTA(fastaURL: URL, bundleURL: URL, displayName: String)

    /// A standalone FASTA file found in the project tree.
    case standaloneFASTA(url: URL)

    /// Stable identifier based on the FASTA file path.
    public var id: String { fastaURL.absoluteString }

    /// Human-readable name for display in dropdowns.
    public var displayName: String {
        switch self {
        case .projectReference(_, let manifest):
            return manifest.name
        case .genomeBundleFASTA(_, _, let name):
            return name
        case .standaloneFASTA(let url):
            return url.deletingPathExtension().lastPathComponent
        }
    }

    /// The URL to the actual FASTA file.
    public var fastaURL: URL {
        switch self {
        case .projectReference(let url, let manifest):
            return url.appendingPathComponent(manifest.fastaFilename)
        case .genomeBundleFASTA(let fastaURL, _, _):
            return fastaURL
        case .standaloneFASTA(let url):
            return url
        }
    }

    /// The originating bundle when the selection comes from a `.lungfishref`.
    public var sourceBundleURL: URL? {
        switch self {
        case .projectReference(let url, _):
            return url
        case .genomeBundleFASTA(_, let bundleURL, _):
            return bundleURL
        case .standaloneFASTA:
            return nil
        }
    }

    /// The source category for grouping in UI dropdowns.
    public var sourceCategory: SourceCategory {
        switch self {
        case .projectReference: return .projectReferences
        case .genomeBundleFASTA: return .genomeBundles
        case .standaloneFASTA: return .standaloneFASTAFiles
        }
    }

    /// Source categories for grouping in dropdowns.
    public enum SourceCategory: String, Sendable, CaseIterable {
        case projectReferences = "Project References"
        case genomeBundles = "Genome Bundles"
        case standaloneFASTAFiles = "FASTA Files"
    }

    // MARK: - Equatable

    public static func == (lhs: ReferenceCandidate, rhs: ReferenceCandidate) -> Bool {
        lhs.id == rhs.id
    }
}
