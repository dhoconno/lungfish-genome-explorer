// BundleSequenceSummarySynthesizer.swift - Builds lightweight bundle browser summaries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

enum BundleSequenceSummarySynthesizerError: Error, LocalizedError {
    case variantDatabasePathMissing(trackID: String)
    case variantDatabaseUnreadable(path: String, underlyingError: Error?)
    case noVariantDatabasesAvailable

    var errorDescription: String? {
        switch self {
        case .variantDatabasePathMissing(let trackID):
            return "Variant-only summary synthesis requires database_path for track '\(trackID)'"
        case .variantDatabaseUnreadable(let path, let underlyingError):
            if let underlyingError {
                return "Failed to read variant database at \(path): \(underlyingError.localizedDescription)"
            }
            return "Failed to read variant database at \(path)"
        case .noVariantDatabasesAvailable:
            return "Variant-only summary synthesis requires at least one readable variant database"
        }
    }
}

enum BundleSequenceSummarySynthesizer {

    static func summarize(bundleURL: URL, manifest: BundleManifest) throws -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: makeAggregate(from: manifest),
            sequences: try makeSequences(bundleURL: bundleURL, manifest: manifest)
        )
    }

    private static func makeAggregate(from manifest: BundleManifest) -> BundleBrowserSummary.Aggregate {
        let mappedReadCounts = manifest.alignments.compactMap(\.mappedReadCount)
        let totalMappedReads = mappedReadCounts.isEmpty ? nil : mappedReadCounts.reduce(0, +)
        return .init(
            annotationTrackCount: manifest.annotations.count,
            variantTrackCount: manifest.variants.count,
            alignmentTrackCount: manifest.alignments.count,
            totalMappedReads: totalMappedReads
        )
    }

    private static func makeSequences(bundleURL: URL, manifest: BundleManifest) throws -> [BundleBrowserSequenceSummary] {
        if let genome = manifest.genome {
            return genome.chromosomes.map { chromosome in
                BundleBrowserSequenceSummary(
                    name: chromosome.name,
                    displayDescription: chromosome.fastaDescription,
                    length: chromosome.length,
                    aliases: chromosome.aliases,
                    isPrimary: chromosome.isPrimary,
                    isMitochondrial: chromosome.isMitochondrial,
                    metrics: nil
                )
            }
        }

        return try summarizeVariantOnlySequences(bundleURL: bundleURL, manifest: manifest)
    }

    private static func summarizeVariantOnlySequences(bundleURL: URL, manifest: BundleManifest) throws -> [BundleBrowserSequenceSummary] {
        var maxPositionsByChromosome: [String: Int] = [:]
        var sawReadableDatabase = false

        for track in manifest.variants {
            guard let databasePath = track.databasePath else {
                throw BundleSequenceSummarySynthesizerError.variantDatabasePathMissing(trackID: track.id)
            }
            let databaseURL = bundleURL.appendingPathComponent(databasePath)
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw BundleSequenceSummarySynthesizerError.variantDatabaseUnreadable(path: databaseURL.path, underlyingError: nil)
            }

            let database: VariantDatabase
            do {
                database = try VariantDatabase(url: databaseURL)
            } catch {
                throw BundleSequenceSummarySynthesizerError.variantDatabaseUnreadable(path: databaseURL.path, underlyingError: error)
            }
            sawReadableDatabase = true

            for (chromosome, maxPosition) in database.chromosomeMaxPositions() {
                maxPositionsByChromosome[chromosome] = max(maxPositionsByChromosome[chromosome] ?? 0, maxPosition)
            }
        }

        guard sawReadableDatabase, !maxPositionsByChromosome.isEmpty else {
            throw BundleSequenceSummarySynthesizerError.noVariantDatabasesAvailable
        }

        return maxPositionsByChromosome.keys.sorted().map { chromosome in
            let maxPosition = maxPositionsByChromosome[chromosome] ?? 0
            let estimatedLength = max(Int64(Double(maxPosition) * 1.1), 1000)
            return BundleBrowserSequenceSummary(
                name: chromosome,
                displayDescription: nil,
                length: estimatedLength,
                aliases: [],
                isPrimary: true,
                isMitochondrial: false,
                metrics: nil
            )
        }
    }
}
