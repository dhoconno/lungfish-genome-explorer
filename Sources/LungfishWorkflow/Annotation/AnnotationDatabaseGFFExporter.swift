// AnnotationDatabaseGFFExporter.swift - Stream rows from a Lungfish AnnotationDatabase
// out as GFF3 so they can be consumed by `ivar variants -g <gff>`.
//
// iVar's codon-aware variant calling expects a GFF3 file describing the
// reference's CDS features. Lungfish bundles store annotations in a SQLite
// database (`AnnotationDatabase`), so before invoking iVar we materialize a
// transient GFF3 from that database.

import Foundation
import LungfishIO

public enum AnnotationDatabaseGFFExporter {
    /// Writes every record in `database` to `url` as a GFF3 file.
    ///
    /// The output starts with `##gff-version 3` and emits one tab-separated
    /// line per annotation in the canonical GFF3 column order: seqid, source,
    /// type, start, end, score, strand, phase, attributes. `source`, `score`,
    /// and `phase` are emitted as `.` since the database does not preserve
    /// them. When a record's attributes are nil we fall back to `ID=<name>`
    /// so iVar still sees a parseable identifier.
    public static func export(database: AnnotationDatabase, to url: URL) throws {
        var buffer = "##gff-version 3\n"
        for record in database.query(limit: Int.max) {
            let attributes = record.attributes ?? "ID=\(record.name)"
            let gffStart = record.start + 1
            let phase = gffPhase(for: record)
            buffer += "\(record.chromosome)\t.\t\(record.type)\t\(gffStart)\t\(record.end)\t.\t\(record.strand)\t\(phase)\t\(attributes)\n"
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
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
