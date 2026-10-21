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
    /// Column 9 is the record's stored attributes without the import's internal
    /// `lungfish_gff_phase` key (see `columnNine(for:)`). When a record has no
    /// attributes we fall back to `ID=<name>` so downstream tools (iVar's `-g`)
    /// still see a parseable identifier.
    ///
    /// A CDS record that spans multiple BED12 blocks (a spliced CDS, or a
    /// ribosomal-frameshift CDS such as SARS-CoV-2 ORF1ab) is expanded into
    /// one GFF3 line per block, all sharing the record's `ID`, with each
    /// block's phase computed from the cumulative CDS length in
    /// transcription order via `CDSSegmentPhases`. Collapsing those blocks
    /// into a single start..end span (the prior behaviour) silently changes
    /// the reading frame iVar uses for every downstream SNP.
    ///
    /// Records are written parent-first, in the order `parentFirst(_:)` describes, so no line names a
    /// `Parent` that a later line defines. The database returns its rows in name order, which put a
    /// child before its parent whenever the child's name sorted first (SARS-CoV-2's S CDS is named
    /// `QHD43416.1`, gene `S`), and SnpEff 5.0e then built the gene from the CDS.
    public static func export(database: AnnotationDatabase, to url: URL) throws {
        var buffer = "##gff-version 3\n"
        for record in parentFirst(database.query(limit: Int.max)) {
            let attributes = columnNine(for: record)
            for (gffStart, gffEnd, phase) in segmentLines(for: record) {
                buffer += "\(record.chromosome)\t.\t\(record.type)\t\(gffStart)\t\(gffEnd)\t.\t\(record.strand)\t\(phase)\t\(attributes)\n"
            }
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Column 9

    /// The attribute the import stores on a CDS record to remember the phase of its column 8
    /// (`AnnotationDatabase+Building.swift`). It is the database's own bookkeeping, `gffPhase(for:)` reads it for
    /// column 8, and it never belongs in a file that other tools read.
    private static let internalPhaseKey = "lungfish_gff_phase"

    /// Column 9 of every line `record` writes. It is the stored attribute string without the `lungfish_gff_phase`
    /// pair, every other pair byte for byte and in its stored order, so a record without the pair writes its stored
    /// string unchanged. A record with no attributes, or whose only attribute was the internal key, writes
    /// `ID=<name>`, so downstream tools (iVar's `-g`) still see a parseable identifier.
    static func columnNine(for record: AnnotationDatabaseRecord) -> String {
        guard let stored = record.attributes else { return "ID=\(record.name)" }
        let pairs = stored.split(separator: ";", omittingEmptySubsequences: false)
        let kept = pairs.filter { attributeKey(of: $0) != internalPhaseKey }
        guard kept.count < pairs.count else { return stored }
        guard kept.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "ID=\(record.name)"
        }
        return kept.joined(separator: ";")
    }

    /// The key of one attribute pair, found as `AnnotationDatabase.parseAttributes` finds it: the text before the
    /// first `=`, or for a GTF-style pair the text before the first space. Nil when the pair has neither.
    private static func attributeKey(of pair: Substring) -> String? {
        let entry = pair.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = entry.firstIndex(of: "=") ?? entry.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        return entry[..<separator].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Parent-first order

    /// The `ID` an exported line defines, qualified by its chromosome, since a `Parent` names a feature of
    /// its own sequence.
    private struct IdentifierKey: Hashable {
        let chromosome: String
        let id: String
    }

    /// Returns `records` in the order a GFF3 reader can follow, every record after the records it names
    /// as `Parent`.
    ///
    /// The order is chromosome, start ascending, end descending, then Parent depth. A record's Parent depth
    /// is 0 when the file defines none of its Parents and otherwise one more than its deepest Parent, so a
    /// gene, its transcript and their exon or CDS, which can share one span, keep that order. Records that
    /// tie on all four keys keep their database row order, which for a GFF3 import is the order of the
    /// source file. Each record is placed once, so the lines of a multi-block CDS stay together.
    ///
    /// A child that starts before its Parent, or starts with it but ends after it, would still precede it under that
    /// key, so a last pass writes every Parent the file defines ahead of the first record that names it.
    /// A Parent cycle, or a record that names itself, has no valid order, and the edge that closes it is
    /// ignored.
    static func parentFirst(_ records: [AnnotationDatabaseRecord]) -> [AnnotationDatabaseRecord] {
        let parents = parentIndices(of: records)

        // Parent depth. The records are visited in row order so a cycle always breaks at the same edge.
        let rowOrder = records.indices.sorted {
            (records[$0].rowID ?? Int64.max, $0) < (records[$1].rowID ?? Int64.max, $1)
        }
        var depths = [Int](repeating: 0, count: records.count)
        var counted = [Bool](repeating: false, count: records.count)
        visitParentsFirst(rowOrder, parents: parents) { index in
            depths[index] = parents[index].filter { counted[$0] }.map { depths[$0] + 1 }.max() ?? 0
            counted[index] = true
        }

        let sorted = records.indices.sorted { lhs, rhs in
            let (left, right) = (records[lhs], records[rhs])
            if left.chromosome != right.chromosome { return left.chromosome < right.chromosome }
            if left.start != right.start { return left.start < right.start }
            if left.end != right.end { return left.end > right.end }
            if depths[lhs] != depths[rhs] { return depths[lhs] < depths[rhs] }
            return (left.rowID ?? Int64.max, lhs) < (right.rowID ?? Int64.max, rhs)
        }

        var ordered: [AnnotationDatabaseRecord] = []
        ordered.reserveCapacity(records.count)
        visitParentsFirst(sorted, parents: parents) { ordered.append(records[$0]) }
        return ordered
    }

    /// For each record, the indices of the other records on its chromosome that define the `Parent` IDs it
    /// names. A `Parent` can list several IDs, and an `ID` can belong to several records (a discontinuous
    /// feature), so a record can have any number. Both come from the attributes the exported line carries.
    private static func parentIndices(of records: [AnnotationDatabaseRecord]) -> [[Int]] {
        var definitions: [IdentifierKey: [Int]] = [:]
        var parentIDs: [[String]] = []
        parentIDs.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            let attributes = AnnotationDatabase.parseAttributes(columnNine(for: record))
            if let id = attributes["ID"] {
                definitions[IdentifierKey(chromosome: record.chromosome, id: id), default: []].append(index)
            }
            parentIDs.append(attributes["Parent"]?.split(separator: ",").map(String.init) ?? [])
        }
        return records.indices.map { index in
            parentIDs[index]
                .flatMap { definitions[IdentifierKey(chromosome: records[index].chromosome, id: $0)] ?? [] }
                .filter { $0 != index }
        }
    }

    /// Calls `visit` once for every index in `order`, after the call for each index `parents` lists for it.
    /// A parent that is still being visited closes a cycle and is skipped. The walk keeps its own stack, so
    /// a long Parent chain in a hostile file cannot overflow the call stack.
    private static func visitParentsFirst(_ order: [Int], parents: [[Int]], visit: (Int) -> Void) {
        var done = [Bool](repeating: false, count: parents.count)
        var onPath = [Bool](repeating: false, count: parents.count)
        for root in order where !done[root] {
            var path: [(index: Int, next: Int)] = [(index: root, next: 0)]
            onPath[root] = true
            while let top = path.last {
                if top.next < parents[top.index].count {
                    path[path.count - 1].next += 1
                    let parent = parents[top.index][top.next]
                    if !done[parent], !onPath[parent] {
                        onPath[parent] = true
                        path.append((index: parent, next: 0))
                    }
                } else {
                    path.removeLast()
                    onPath[top.index] = false
                    done[top.index] = true
                    visit(top.index)
                }
            }
        }
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
