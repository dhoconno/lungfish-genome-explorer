// AnnotationDatabaseGFFExporter.swift - Stream rows from a Lungfish AnnotationDatabase
// out as GFF3 so they can be consumed by `ivar variants -g <gff>`.
//
// iVar's codon-aware variant calling expects a GFF3 file describing the
// reference's CDS features. Lungfish bundles store annotations in a SQLite
// database (`AnnotationDatabase`), so before invoking iVar we materialize a
// transient GFF3 from that database.

import Foundation
import LungfishCore
import LungfishIO

public enum AnnotationDatabaseGFFExporter {
    /// Writes every record in `database` to `url` as a GFF3 file.
    ///
    /// The output starts with `##gff-version 3` and emits one tab-separated
    /// line per annotation in the canonical GFF3 column order: seqid, source,
    /// type, start, end, score, strand, phase, attributes. `source` and
    /// `score` are emitted as `.` since the database does not preserve them.
    /// When a record's attributes are nil we fall back to `ID=<name>` so
    /// downstream tools (iVar's `-g`) still see a parseable identifier.
    ///
    /// A CDS record that spans multiple BED12 blocks (a spliced CDS, or a
    /// ribosomal-frameshift CDS such as SARS-CoV-2 ORF1ab) is expanded into
    /// one GFF3 line per block, all sharing the record's `ID`, with each
    /// block's phase computed from the cumulative CDS length in
    /// transcription order via `CDSSegmentPhases`. Collapsing those blocks
    /// into a single start..end span (the prior behaviour) silently changes
    /// the reading frame iVar uses for every downstream SNP.
    public static func export(database: AnnotationDatabase, to url: URL) throws {
        var buffer = "##gff-version 3\n"
        for record in database.query(limit: Int.max) {
            let attributes = record.attributes ?? "ID=\(record.name)"
            for (gffStart, gffEnd, phase) in segmentLines(for: record) {
                buffer += "\(record.chromosome)\t.\t\(record.type)\t\(gffStart)\t\(gffEnd)\t.\t\(record.strand)\t\(phase)\t\(attributes)\n"
            }
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns the one-or-more `(start, end, phase)` GFF3 lines a record
    /// expands to, in 1-based inclusive GFF3 coordinates.
    static func segmentLines(for record: AnnotationDatabaseRecord) -> [(start: Int, end: Int, phase: String)] {
        guard record.type == "CDS" else {
            let gffStart = record.start + 1
            return [(gffStart, record.end, ".")]
        }

        guard
            let blockCount = record.blockCount, blockCount > 1,
            let blockSizes = record.blockSizes, let blockStarts = record.blockStarts
        else {
            let gffStart = record.start + 1
            return [(gffStart, record.end, gffPhase(for: record))]
        }

        let sizes = blockSizes.split(separator: ",").compactMap { Int($0) }
        let starts = blockStarts.split(separator: ",").compactMap { Int($0) }
        guard sizes.count >= blockCount, starts.count >= blockCount else {
            let gffStart = record.start + 1
            return [(gffStart, record.end, gffPhase(for: record))]
        }

        let intervals = (0..<blockCount).map { index in
            CDSSegmentPhases.Interval(
                start: record.start + starts[index],
                end: record.start + starts[index] + sizes[index]
            )
        }
        let phased = CDSSegmentPhases.compute(intervals: intervals, strand: record.strand)
        return phased.map { (interval, phase) in
            (interval.start + 1, interval.end, String(phase))
        }
    }

    private static func gffPhase(for record: AnnotationDatabaseRecord) -> String {
        guard record.type == "CDS" else {
            return "."
        }
        if let attributes = record.attributes {
            let parsed = AnnotationDatabase.parseAttributes(attributes)
            if let phase = parsed["lungfish_gff_phase"], ["0", "1", "2"].contains(phase) {
                return phase
            }
        }
        return "0"
    }
}
