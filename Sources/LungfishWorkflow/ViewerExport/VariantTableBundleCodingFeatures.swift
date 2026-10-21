// VariantTableBundleCodingFeatures.swift - The bundle's CDS over a variant table export's rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The one read of the coding features behind the variant table's derived columns in an export (Phase 2.13 lane
/// 13.38, BIO ruling on M854 items 6 and 7, V1-1).
///
/// It reads the CDS of the named annotation tracks, in `bundle.annotationTrackIds` order as the viewer reads them,
/// over the exported rows rather than over the part of the genome the viewer cached. The leaf calls it for a selection
/// that names `bundleCodingFeatureTrackIDs`, and the drawer calls it for both scopes and for All Matching's derived
/// filter and sort, so a row is written, kept, dropped and placed by one list. The viewer's cache, the hover text and
/// the table on screen do not call it.
package enum VariantTableBundleCodingFeatures {
    /// The most annotations one read takes from one track, the default of
    /// `ReferenceBundle.getAnnotationsFromDatabase(trackId:region:limit:)` (BIO ruling on M854, F6).
    package static let annotationLimit = 50_000

    /// The rows of one chromosome merged where they overlap or touch, 0-based and half-open.
    package struct Span: Sendable, Equatable {
        /// The reference's name, which the read queries.
        package let chromosome: String
        /// The name the variant table shows, which the limit failure names.
        package let shownChromosome: String
        package let start: Int
        package let end: Int
    }

    /// A read returned as many annotations as its limit, so a cut list could drop a label with no sign (BIO 4). The
    /// export fails with exit 64 and writes nothing, in R-QB2 item 1's words.
    package struct LimitReached: Error, LocalizedError, Equatable {
        package let trackName: String
        package let span: Span
        package let limit: Int

        package var errorDescription: String? {
            "The annotation track \(trackName) holds at least \(VariantTableBundleCodingFeatures.grouped(limit)) "
                + "annotations in \(span.shownChromosome):\(span.start + 1)-\(span.end), the most the export reads from "
                + "one track at a time, so the Gene / Protein, Consequence and AA Change cells of the variants there "
                + "could miss a coding feature. No file was written. Export fewer of the variants in that span at a time."
        }
    }

    /// The selection names an annotation track this bundle does not hold with a database (V1-1 item 4), a failure.
    package struct UnknownTrack: Error, LocalizedError, Equatable {
        package let trackID: String

        package var errorDescription: String? {
            "The selection names the annotation track \(trackID), which this bundle does not hold. "
                + "Export the table again from the app."
        }
    }

    /// The id of every annotation track of the bundle whose database file exists, sorted, which a new selection names.
    package static func trackIDs(bundle: ReferenceBundle) -> [String] {
        bundle.manifest.annotations.filter { track in
            guard let path = track.databasePath,
                  let url = try? bundle.memberURL(for: path, field: "annotations[\(track.id)].databasePath") else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }.map(\.id).sorted()
    }

    /// `limit` with a comma between each group of three digits, whatever the locale (R-QB2 item 1).
    package static func grouped(_ limit: Int) -> String {
        var digits = Array(String(limit))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(",", at: index)
            index -= 3
        }
        return String(digits)
    }

    /// The spans of `rows`, `[start, start + max(1, ref count))` as the resolver matches a row
    /// (`VariantTableExportResolverSnapshot.overlappingFeatures`), grouped by the reference's name for each row's
    /// chromosome, merged where they overlap or touch, and in chromosome and then start order.
    package static func spans(
        rows: [AnnotationSearchResult], referenceChromosome: (String) -> String
    ) -> [Span] {
        var ranges: [String: [(start: Int, end: Int)]] = [:]
        var shown: [String: String] = [:]
        for row in rows {
            let chromosome = referenceChromosome(row.chromosome)
            ranges[chromosome, default: []].append((row.start, row.start + max(1, row.ref?.count ?? 1)))
            shown[chromosome] = min(shown[chromosome] ?? row.chromosome, row.chromosome)
        }
        var spans: [Span] = []
        for chromosome in ranges.keys.sorted() {
            var merged: [(start: Int, end: Int)] = []
            for range in (ranges[chromosome] ?? []).sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
                if let last = merged.last, range.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, range.end)
                } else {
                    merged.append(range)
                }
            }
            spans += merged.map {
                Span(chromosome: chromosome, shownChromosome: shown[chromosome] ?? chromosome, start: $0.start, end: $0.end)
            }
        }
        return spans
    }

    /// The CDS of `trackIDs` that overlap the spans of `rows`, as resolver features with no coding bases.
    ///
    /// Each named track is read over each span with the viewer's call, in `bundle.annotationTrackIds` order and then
    /// span order. A CDS is kept once, by track and row id, when one of its intervals overlaps a span of its
    /// chromosome, and a track's CDS keep the database's order, start, end and name (F11). A named track the bundle
    /// does not hold throws `UnknownTrack`, and a read that returns `limit` annotations throws `LimitReached` for the
    /// first such read.
    package static func features(
        bundle: ReferenceBundle,
        trackIDs: [String],
        rows: [AnnotationSearchResult],
        referenceChromosome: (String) -> String,
        limit: Int = annotationLimit,
        shouldCancel: () -> Bool = { false }
    ) throws -> [VariantTableExportResolverSnapshot.CodingFeature] {
        let available = Set(Self.trackIDs(bundle: bundle))
        if let unknown = trackIDs.sorted().first(where: { !available.contains($0) }) {
            throw UnknownTrack(trackID: unknown)
        }
        let named = Set(trackIDs)
        let spans = Self.spans(rows: rows, referenceChromosome: referenceChromosome)
        let spansByChromosome = Dictionary(grouping: spans, by: \.chromosome)
        var annotations: [SequenceAnnotation] = []
        for trackID in bundle.annotationTrackIds where named.contains(trackID) {
            let trackName = bundle.annotationTrack(id: trackID).map { $0.name.isEmpty ? trackID : $0.name } ?? trackID
            var seen = Set<String>()
            var kept: [(chromosomeRank: Int, annotation: SequenceAnnotation)] = []
            for span in spans {
                if shouldCancel() { throw CancellationError() }
                let read = try bundle.getAnnotationsFromDatabase(
                    trackId: trackID,
                    region: GenomicRegion(chromosome: span.chromosome, start: span.start, end: span.end),
                    limit: limit
                )
                if read.count >= limit { throw LimitReached(trackName: trackName, span: span, limit: limit) }
                let chromosomeSpans = spansByChromosome[span.chromosome] ?? []
                let rank = spans.firstIndex { $0.chromosome == span.chromosome } ?? 0
                for annotation in read where annotation.type == .cds {
                    let key = annotation.qualifier("annotation_db_row_id") ?? annotation.id.uuidString
                    guard seen.insert(key).inserted else { continue }
                    let overlaps = annotation.intervals.contains { interval in
                        chromosomeSpans.contains { interval.start < $0.end && interval.end > $0.start }
                    }
                    if overlaps { kept.append((rank, annotation)) }
                }
            }
            annotations += kept.enumerated().sorted { left, right in
                let l = left.element, r = right.element
                if l.chromosomeRank != r.chromosomeRank { return l.chromosomeRank < r.chromosomeRank }
                if l.annotation.start != r.annotation.start { return l.annotation.start < r.annotation.start }
                if l.annotation.end != r.annotation.end { return l.annotation.end < r.annotation.end }
                if l.annotation.name != r.annotation.name { return l.annotation.name < r.annotation.name }
                return left.offset < right.offset
            }.map(\.element.annotation)
        }
        return VariantTableCodingFeatures.features(
            annotations: annotations,
            fallbackChromosome: "",
            chromosomeName: { bundle.chromosome(named: $0)?.name ?? $0 },
            context: { _ in nil }
        )
    }

    /// The resolver the export's derived columns read: the CDS of `features(...)` over `rows`, each with its coding
    /// bases read from the bundle off the main actor (`preparingForBackgroundExport`), and the chromosome names
    /// matched as the resolver matches them, through the bundle's aliases and `variantChromosomeAliasMap`.
    package static func resolver(
        bundle: ReferenceBundle,
        trackIDs: [String],
        rows: [AnnotationSearchResult],
        variantChromosomeAliasMap: [String: String],
        limit: Int = annotationLimit,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> VariantTableExportResolverSnapshot {
        let aliases = VariantTableCodingFeatures.referenceAliases(chromosomes: bundle.manifest.genome?.chromosomes ?? [])
        let names = VariantTableExportResolverSnapshot(
            features: [], variantChromosomeAliasMap: variantChromosomeAliasMap, referenceChromosomeAliases: aliases
        )
        let features = try features(
            bundle: bundle, trackIDs: trackIDs, rows: rows, referenceChromosome: names.resolvedReferenceChromosome,
            limit: limit, shouldCancel: shouldCancel
        )
        return try VariantTableExportResolverSnapshot(
            features: features, variantChromosomeAliasMap: variantChromosomeAliasMap,
            referenceChromosomeAliases: aliases, referenceBundle: bundle
        ).preparingForBackgroundExport(shouldCancel: shouldCancel)
    }
}
