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
            return manifest.resolvedFastaURL(in: url) ?? manifest.safeFallbackFastaURL(in: url)
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

    /// Returns a displayable FASTA path, relative to the project when possible.
    public func displayPath(relativeTo projectURL: URL?) -> String {
        Self.displayPath(for: fastaURL, relativeTo: projectURL)
    }

    /// Returns picker labels keyed by candidate id.
    ///
    /// A unique candidate uses only its bundle or FASTA name. Candidates with
    /// the same name include their containing folder so they remain distinct.
    public static func pickerDisplayNames(
        for candidates: [ReferenceCandidate],
        relativeTo projectURL: URL?
    ) -> [String: String] {
        let candidatesByName = Dictionary(grouping: candidates) {
            $0.displayName.lowercased()
        }
        let displayNameKeys = Set(candidatesByName.keys)

        var labels: [String: String] = [:]
        for sameNamedCandidates in candidatesByName.values {
            guard sameNamedCandidates.count > 1 else {
                if let candidate = sameNamedCandidates.first {
                    labels[candidate.id] = candidate.displayName
                }
                continue
            }

            let candidatesByFolder = Dictionary(grouping: sameNamedCandidates) { candidate in
                displayFolder(
                    for: candidate.pickerContainerURL,
                    relativeTo: projectURL
                ).lowercased()
            }

            for candidate in sameNamedCandidates {
                let folder = displayFolder(
                    for: candidate.pickerContainerURL,
                    relativeTo: projectURL
                )
                let folderQualifiedLabel = "\(candidate.displayName) (\(folder))"
                let detail: String
                if candidatesByFolder[folder.lowercased(), default: []].count > 1
                    || displayNameKeys.contains(folderQualifiedLabel.lowercased()) {
                    detail = displayPath(for: candidate.pickerSourceURL, relativeTo: projectURL)
                } else {
                    detail = folder
                }
                labels[candidate.id] = "\(candidate.displayName) (\(detail))"
            }
        }
        return labels
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

    private static func displayPath(for url: URL, relativeTo projectURL: URL?) -> String {
        let standardizedTarget = url.standardizedFileURL.path
        guard let projectURL else { return standardizedTarget }

        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard standardizedTarget.hasPrefix(normalizedProjectPath) else {
            return standardizedTarget
        }

        return String(standardizedTarget.dropFirst(normalizedProjectPath.count))
    }

    private var pickerContainerURL: URL {
        pickerSourceURL.deletingLastPathComponent()
    }

    private var pickerSourceURL: URL {
        sourceBundleURL ?? fastaURL
    }

    private static func displayFolder(for url: URL, relativeTo projectURL: URL?) -> String {
        let standardizedTarget = url.standardizedFileURL.path
        guard let projectURL else { return standardizedTarget }

        let projectPath = projectURL.standardizedFileURL.path
        if standardizedTarget == projectPath {
            return "."
        }

        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard standardizedTarget.hasPrefix(normalizedProjectPath) else {
            return standardizedTarget
        }

        return String(standardizedTarget.dropFirst(normalizedProjectPath.count))
    }
}
