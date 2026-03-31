// ReferenceSequenceScanner.swift - Scans project tree for reference sequence candidates
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Scans a project directory tree for reference sequence candidates.
///
/// Discovers references from three sources:
/// 1. Explicit `.lungfishref` bundles in the "Reference Sequences" folder
/// 2. Genome bundle FASTAs found in the project tree
/// 3. Standalone FASTA files found in the project tree
///
/// Results are yielded incrementally via `AsyncStream` so the caller can
/// populate UI dropdowns as candidates are discovered.
public enum ReferenceSequenceScanner {

    /// Known FASTA file extensions (case-insensitive), excluding .gz suffix.
    private static let fastaExtensions: Set<String> = ["fasta", "fa", "fna", "fas"]

    /// Resolves the FASTA URL within a `.lungfishref` bundle.
    ///
    /// Handles both simple reference bundles (with `ReferenceSequenceManifest`)
    /// and full genome bundles (with `BundleManifest` and FASTA in `genome/`).
    private static func resolveFASTAInBundle(_ bundleURL: URL) -> (fastaURL: URL, displayName: String)? {
        // Strategy 1: Simple reference manifest
        if let fastaURL = ReferenceSequenceFolder.fastaURL(in: bundleURL) {
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            let name: String
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? {
                   let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
                   return try d.decode(ReferenceSequenceManifest.self, from: data)
               }() {
                name = manifest.name
            } else {
                name = bundleURL.deletingPathExtension().lastPathComponent
            }
            return (fastaURL, name)
        }

        // Strategy 2: Genome bundle — FASTA in genome/ subdirectory
        let fm = FileManager.default
        let genomeDir = bundleURL.appendingPathComponent("genome")
        if let genomeContents = try? fm.contentsOfDirectory(at: genomeDir, includingPropertiesForKeys: nil) {
            let fastaFile = genomeContents.first { file in
                let name = file.lastPathComponent.lowercased()
                return name.hasSuffix(".fa") || name.hasSuffix(".fasta") || name.hasSuffix(".fna")
                    || name.hasSuffix(".fa.gz") || name.hasSuffix(".fasta.gz") || name.hasSuffix(".fna.gz")
            }
            if let fastaFile {
                let displayName = bundleURL.deletingPathExtension().lastPathComponent
                return (fastaFile, displayName)
            }
        }

        // Strategy 3: FASTA at bundle root
        if let rootContents = try? fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
            let fastaFile = rootContents.first { isFASTAFile($0) }
            if let fastaFile {
                return (fastaFile, bundleURL.deletingPathExtension().lastPathComponent)
            }
        }

        return nil
    }

    /// Scans a project directory for all reference candidates.
    ///
    /// Results are returned sorted by source category and display name.
    /// This is a synchronous method suitable for small projects.
    public static func scanAll(in projectURL: URL) -> [ReferenceCandidate] {
        var candidates: [ReferenceCandidate] = []

        // Source 1: Explicit references from Reference Sequences folder
        let projectRefs = ReferenceSequenceFolder.listReferences(in: projectURL)
        for ref in projectRefs {
            candidates.append(.projectReference(url: ref.url, manifest: ref.manifest))
        }

        // Source 2 & 3: Scan project tree for genome bundles and standalone FASTAs
        scanDirectory(projectURL, projectURL: projectURL, candidates: &candidates)

        // Sort by category priority, then display name
        return candidates.sorted { a, b in
            if a.sourceCategory != b.sourceCategory {
                return categoryPriority(a.sourceCategory) < categoryPriority(b.sourceCategory)
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Provides an `AsyncStream` of candidates for incremental discovery.
    ///
    /// Yields candidates as they are found during directory traversal.
    /// Callers can update UI progressively.
    public static func scan(in projectURL: URL) -> AsyncStream<ReferenceCandidate> {
        AsyncStream { continuation in
            Task.detached {
                // Source 1: Project references (fast)
                let projectRefs = ReferenceSequenceFolder.listReferences(in: projectURL)
                for ref in projectRefs {
                    continuation.yield(.projectReference(url: ref.url, manifest: ref.manifest))
                }

                // Source 2 & 3: Scan tree
                scanDirectoryAsync(projectURL, projectURL: projectURL, continuation: continuation)

                continuation.finish()
            }
        }
    }

    /// Infers the likely usage role of a FASTA file based on its filename.
    ///
    /// Returns a hint string for operation pre-selection:
    /// - `"primer"` for files matching `*primer*` or `*oligo*`
    /// - `"contaminant"` for files matching `*contam*`, `*host*`, `*phix*`
    /// - `"reference"` for files matching `*genome*`, `*reference*`, or being the largest FASTA
    /// - `nil` for unknown
    public static func inferRole(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("primer") || name.contains("oligo") {
            return "primer"
        }
        if name.contains("contam") || name.contains("host") || name.contains("phix") {
            return "contaminant"
        }
        if name.contains("genome") || name.contains("reference") || name.contains("ref") {
            return "reference"
        }
        return nil
    }

    // MARK: - Private

    private static func categoryPriority(_ category: ReferenceCandidate.SourceCategory) -> Int {
        switch category {
        case .projectReferences: return 0
        case .genomeBundles: return 1
        case .standaloneFASTAFiles: return 2
        }
    }

    /// Recursively scans a directory for genome bundles and standalone FASTAs.
    private static func scanDirectory(
        _ directoryURL: URL,
        projectURL: URL,
        candidates: inout [ReferenceCandidate],
        depth: Int = 0
    ) {
        guard depth < 5 else { return } // Limit recursion depth

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Skip the Reference Sequences folder (already scanned separately)
        let refFolderName = ReferenceSequenceFolder.folderName

        for url in contents {
            if url.lastPathComponent == refFolderName { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // Check for genome bundle (.lungfishref)
                if url.pathExtension == "lungfishref" {
                    if let resolved = resolveFASTAInBundle(url) {
                        let alreadyAdded = candidates.contains { $0.fastaURL == resolved.fastaURL }
                        if !alreadyAdded {
                            candidates.append(.genomeBundleFASTA(url: resolved.fastaURL, displayName: resolved.displayName))
                        }
                    }
                }
                // Skip .lungfishfastq directories (not references)
                else if url.pathExtension != "lungfishfastq" {
                    scanDirectory(url, projectURL: projectURL, candidates: &candidates, depth: depth + 1)
                }
            } else {
                // Standalone FASTA file
                if isFASTAFile(url) {
                    let alreadyAdded = candidates.contains { $0.fastaURL == url }
                    if !alreadyAdded {
                        candidates.append(.standaloneFASTA(url: url))
                    }
                }
            }
        }
    }

    /// Async version of scanDirectory for AsyncStream.
    private static func scanDirectoryAsync(
        _ directoryURL: URL,
        projectURL: URL,
        continuation: AsyncStream<ReferenceCandidate>.Continuation,
        depth: Int = 0
    ) {
        guard depth < 5 else { return }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let refFolderName = ReferenceSequenceFolder.folderName

        for url in contents {
            if url.lastPathComponent == refFolderName { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if url.pathExtension == "lungfishref" {
                    if let resolved = resolveFASTAInBundle(url) {
                        continuation.yield(.genomeBundleFASTA(url: resolved.fastaURL, displayName: resolved.displayName))
                    }
                } else if url.pathExtension != "lungfishfastq" {
                    scanDirectoryAsync(url, projectURL: projectURL, continuation: continuation, depth: depth + 1)
                }
            } else {
                if isFASTAFile(url) {
                    continuation.yield(.standaloneFASTA(url: url))
                }
            }
        }
    }

    /// Checks if a URL points to a FASTA file based on extension.
    private static func isFASTAFile(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        return fastaExtensions.contains(checkURL.pathExtension.lowercased())
    }
}
