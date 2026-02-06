// AnnotationSearchIndex.swift - In-memory annotation name index for search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation search operations
private let searchLogger = Logger(subsystem: "com.lungfish.browser", category: "AnnotationSearch")

// MARK: - AnnotationSearchIndex

/// In-memory index of annotation names for fast text search.
///
/// Built by scanning all BigBed annotation tracks across all chromosomes. Once built,
/// `search(query:)` performs case-insensitive substring matching against annotation names.
///
/// ## Usage
/// ```swift
/// let index = AnnotationSearchIndex()
/// await index.buildIndex(bundle: bundle, chromosomes: manifest.genome.chromosomes)
/// let results = index.search(query: "GZMB")
/// ```
@MainActor
public final class AnnotationSearchIndex {

    // MARK: - Types

    /// A search result representing a single annotation feature.
    public struct SearchResult: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let chromosome: String
        public let start: Int
        public let end: Int
        public let trackId: String

        public init(id: UUID = UUID(), name: String, chromosome: String, start: Int, end: Int, trackId: String) {
            self.id = id
            self.name = name
            self.chromosome = chromosome
            self.start = start
            self.end = end
            self.trackId = trackId
        }
    }

    // MARK: - Properties

    private var entries: [SearchResult] = []

    /// Whether the index is currently being built.
    public private(set) var isBuilding: Bool = false

    /// Number of indexed entries.
    public var entryCount: Int { entries.count }

    // MARK: - Building

    /// Builds the index by scanning all annotation tracks across all chromosomes.
    ///
    /// This is an async operation that reads BigBed files for every chromosome.
    /// For a typical human genome with GENCODE annotations, this takes 2-5 seconds.
    ///
    /// - Parameters:
    ///   - bundle: The reference bundle containing annotation tracks
    ///   - chromosomes: The chromosome list to scan
    public func buildIndex(bundle: ReferenceBundle, chromosomes: [ChromosomeInfo]) async {
        isBuilding = true
        searchLogger.info("AnnotationSearchIndex: Building index for \(chromosomes.count) chromosomes, \(bundle.annotationTrackIds.count) tracks")

        var results: [SearchResult] = []
        var seenNames = Set<String>() // Deduplicate by name+chrom+start+end

        for trackId in bundle.annotationTrackIds {
            for chrom in chromosomes {
                let region = GenomicRegion(
                    chromosome: chrom.name,
                    start: 0,
                    end: Int(chrom.length)
                )
                do {
                    let annotations = try await bundle.getAnnotations(trackId: trackId, region: region)
                    for ann in annotations {
                        let name = ann.name
                        guard !name.isEmpty, name != "unknown" else { continue }

                        let interval = ann.intervals.first!
                        let lastInterval = ann.intervals.last!
                        let key = "\(name)|\(chrom.name)|\(interval.start)|\(lastInterval.end)"

                        if seenNames.insert(key).inserted {
                            results.append(SearchResult(
                                name: name,
                                chromosome: chrom.name,
                                start: interval.start,
                                end: lastInterval.end,
                                trackId: trackId
                            ))
                        }
                    }
                } catch {
                    searchLogger.debug("AnnotationSearchIndex: Skipping \(trackId)/\(chrom.name, privacy: .public): \(error.localizedDescription)")
                }
            }
        }

        // Sort results alphabetically for consistent display
        results.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        entries = results
        isBuilding = false
        searchLogger.info("AnnotationSearchIndex: Built index with \(results.count) entries")
    }

    /// Searches the index for annotations matching the query.
    ///
    /// Performs case-insensitive substring matching on annotation names.
    ///
    /// - Parameters:
    ///   - query: The search text
    ///   - limit: Maximum number of results to return (default 20)
    /// - Returns: Array of matching search results
    public func search(query: String, limit: Int = 20) -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        let lowered = query.lowercased()
        var results: [SearchResult] = []

        // Prioritize exact prefix matches, then contains matches
        for entry in entries {
            if entry.name.lowercased().hasPrefix(lowered) {
                results.append(entry)
                if results.count >= limit { return results }
            }
        }

        for entry in entries {
            if !entry.name.lowercased().hasPrefix(lowered),
               entry.name.lowercased().contains(lowered) {
                results.append(entry)
                if results.count >= limit { return results }
            }
        }

        return results
    }

    /// Clears the index.
    public func clear() {
        entries = []
        isBuilding = false
    }
}
