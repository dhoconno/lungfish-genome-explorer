// ClampedSequenceProvider.swift - The one reader of reference bases for CDS translation and extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Reads the reference bases that a CDS translation or extraction needs, clamped to the sequence that exists.
///
/// A reference bundle refuses a read that runs past the end of a chromosome, and every caller turned the
/// refusal into nil with `try?`, so a CDS that ended beyond the chromosome lost the whole segment. The viewer's
/// single-sequence mode clamped the range and kept the bases that exist. This provider gives every bundle caller
/// the clamp of single-sequence mode. A request comes back as the bases inside the extent, with the coordinate
/// they start at, and nil when no base of it exists. `TranslationEngine` reads the missing bases off the
/// segment, so a CDS that a sequence end clips keeps its frame (Phase 2.8 lane B6, decision G1).
package struct ClampedSequenceProvider {
    /// The coordinates the named sequence can be read over, or nil when they are not known.
    private let extent: (String) -> Range<Int>?

    /// Reads bases inside the extent. It is never asked for a range outside an extent that is known.
    private let fetch: (String, Int, Int) -> String?

    package init(
        extent: @escaping (String) -> Range<Int>?,
        fetch: @escaping (String, Int, Int) -> String?
    ) {
        self.extent = extent
        self.fetch = fetch
    }

    /// A reference bundle, read over the length of each chromosome.
    package init(bundle: ReferenceBundle) {
        self.init(
            extent: { name in
                bundle.chromosome(named: name).map { 0..<Int($0.length) }
            },
            fetch: { name, start, end in
                try? bundle.fetchSequenceSync(region: GenomicRegion(chromosome: name, start: start, end: end))
            }
        )
    }

    /// A window onto one chromosome that the viewer holds in memory, from `region.start` to `region.end`.
    /// Unlike a bundle, a window can cut the start of a range as well as its end.
    package init(window bases: String, region: GenomicRegion) {
        self.init(
            extent: { _ in region.start..<max(region.start, region.end) },
            fetch: { _, start, end in
                let offsetStart = start - region.start
                let offsetEnd = end - region.start
                guard offsetStart >= 0, offsetEnd <= bases.count else { return nil }
                let startIndex = bases.index(bases.startIndex, offsetBy: offsetStart)
                let endIndex = bases.index(bases.startIndex, offsetBy: offsetEnd)
                return String(bases[startIndex..<endIndex])
            }
        )
    }

    // MARK: - Reading

    /// The bases of `start..<end` that lie inside the sequence, with the coordinate of the first one.
    /// Returns nil when no base of the range exists.
    package func segment(chromosome: String, start: Int, end: Int) -> TranslationEngine.SegmentRead? {
        guard let extent = extent(chromosome) else {
            // The length is not known, as for a bundle with no genome or a name it does not map. Ask as before.
            return fetch(chromosome, start, end).map { TranslationEngine.SegmentRead(start: start, sequence: $0) }
        }
        let clampedStart = max(start, extent.lowerBound)
        let clampedEnd = min(end, extent.upperBound)
        guard clampedStart < clampedEnd, let bases = fetch(chromosome, clampedStart, clampedEnd) else {
            return nil
        }
        return TranslationEngine.SegmentRead(start: clampedStart, sequence: bases)
    }

    /// Only the bases of `segment(chromosome:start:end:)`, for callers that need no coordinate.
    package func bases(chromosome: String, start: Int, end: Int) -> String? {
        segment(chromosome: chromosome, start: start, end: end)?.sequence
    }

    /// The reader for one chromosome as a closure over a range, the shape `translateCDS` takes.
    package func basesProvider(chromosome: String) -> (Int, Int) -> String? {
        { start, end in bases(chromosome: chromosome, start: start, end: end) }
    }

    /// The same reader, reporting where each read starts.
    package func segmentProvider(chromosome: String) -> (Int, Int) -> TranslationEngine.SegmentRead? {
        { start, end in segment(chromosome: chromosome, start: start, end: end) }
    }

    /// The provider `SequenceExtractor` takes, which names the chromosome in each call.
    package var extractionProvider: SequenceExtractor.SequenceProvider {
        { chromosome, start, end in bases(chromosome: chromosome, start: start, end: end) }
    }
}
