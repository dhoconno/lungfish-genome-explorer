// MappingAnnotationActionCoordinator.swift - Shared mapping annotation action helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

public enum MappingAnnotationActionCoordinator {
    public static func canonicalBlocks(for annotation: SequenceAnnotation) -> [AnnotationInterval] {
        ReadExtractionService.canonicalBlocks(for: annotation.intervals)
    }

    public static func samtoolsRegions(for annotation: SequenceAnnotation) -> [String] {
        ReadExtractionService.samtoolsRegions(for: annotation)
    }

    public static func zoomRegion(
        for annotation: SequenceAnnotation,
        chromosomeLength: Int
    ) -> GenomicRegion? {
        guard let chromosome = annotation.chromosome else { return nil }
        let blocks = canonicalBlocks(for: annotation)
        guard let first = blocks.first else { return nil }

        let boundingStart = blocks.map(\.start).min() ?? first.start
        let boundingEnd = blocks.map(\.end).max() ?? first.end
        let span = max(1, boundingEnd - boundingStart)
        let padding = max(50, Int(ceil(Double(span) * 0.02)))
        let clampedLength = max(1, chromosomeLength)

        var start = max(0, boundingStart - padding)
        start = min(start, clampedLength - 1)
        var end = min(clampedLength, boundingEnd + padding)
        end = max(start + 1, end)

        return GenomicRegion(chromosome: chromosome, start: start, end: end)
    }

    public static func extractionConfiguration(
        for annotation: SequenceAnnotation,
        mappingResult: MappingResult,
        outputDirectory: URL
    ) -> BAMRegionExtractionConfig? {
        let regions = samtoolsRegions(for: annotation)
        guard !regions.isEmpty else { return nil }

        let outputBaseName = sanitizedOutputBaseName(for: annotation.name)
        // The service refuses a region extraction without an explicit index.
        return BAMRegionExtractionConfig(
            bamURL: mappingResult.bamURL,
            indexURL: mappingResult.baiURL,
            regions: regions,
            fallbackToAll: false,
            outputDirectory: outputDirectory,
            outputBaseName: outputBaseName,
            deduplicateReads: true
        )
    }

    private static func sanitizedOutputBaseName(for value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let pieces = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(pieces)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "annotation_extract" : collapsed
    }
}
