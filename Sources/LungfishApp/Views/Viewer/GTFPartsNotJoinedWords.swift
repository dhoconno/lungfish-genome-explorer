// GTFPartsNotJoinedWords.swift - The words for a GTF transcript or CDS that an older version stored in parts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import SQLite3

/// A bundle built before the GTF-SPLICE fix keeps blockless GTF rows: a `transcript` row has one interval and each GTF
/// `CDS` line is its own row. Asking such a row for exons joined keeps its introns, and a translation of such a CDS holds
/// one exon's piece. The stored rows are complete and keep their `transcript_id`, so the track takes no affected row
/// (`SCR/rulings/AFFECTED-WORDS-17.md`, item 3). The app says so at the point of use instead.
///
/// The words show only when the selected feature is a `transcript`, `mRNA` or `CDS` row of one part, its attributes hold
/// a `transcript_id`, and the same track holds another row of the part type with that `transcript_id`: `exon` for a
/// transcript or mRNA, `CDS` for a CDS. A transcript row shows its words only when exons are to be joined, since
/// without that the sequence is the span the person asked for. A GFF3 row never matches: its mRNA holds blocks and its
/// CDS is merged by `ID`, and its exons carry `Parent` and no `transcript_id` in the stored text. A true one-exon
/// transcript is quiet, because its one exon row has the transcript's own span and so is no other part.
enum GTFPartsNotJoined {
    /// A transcript or mRNA row, with exons to be joined.
    static let transcriptWords = "This transcript came from a GTF track that an older version stored as one part, so this sequence includes its introns. Attach the GTF file again to join its exons, then extract it again."
    /// A CDS row, on Copy translation or an extraction.
    static let cdsWords = "This CDS is one of several parts in a GTF track that an older version stored separately, so this protein is only part of it. Attach the GTF file again to join the parts, then copy the translation again."

    /// The `transcript_id` of a row, or nil when it holds none.
    static func transcriptID(in attributes: [String: String]) -> String? {
        guard let id = attributes["transcript_id"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        return id
    }

    /// The type of the rows that make up a feature of `type` in a GTF track, and nil for a type that gets no words.
    static func partType(of type: AnnotationType) -> String? {
        switch type {
        case .transcript, .mRNA: return "exon"
        case .cds: return "CDS"
        default: return nil
        }
    }

    /// The words for a feature, or nil when it gets none.
    ///
    /// - Parameters:
    ///   - type: The type of the selected row.
    ///   - partCount: The number of intervals the row holds. A row of several parts was joined and gets no words.
    ///   - attributes: The row's attributes by key.
    ///   - concatenateExons: Whether exons are to be joined. A transcript or mRNA row needs it, and a CDS row does not.
    ///   - siblingCount: The number of other rows of the part type with the row's `transcript_id` in its track, not
    ///     counting a row of the same span. It runs only when the row can get the words.
    static func words(
        type: AnnotationType,
        partCount: Int,
        attributes: [String: String],
        concatenateExons: Bool,
        siblingCount: @autoclosure () -> Int
    ) -> String? {
        guard partCount == 1, partType(of: type) != nil, transcriptID(in: attributes) != nil else { return nil }
        if type != .cds, !concatenateExons { return nil }
        guard siblingCount() >= 1 else { return nil }
        return type == .cds ? cdsWords : transcriptWords
    }

    /// The report that carries `words`: the first sentence says what is so, and the rest says what to do.
    static func report(words: String, step: String) -> FailureReport {
        let split = words.range(of: ". ")
        let whatHappened = split.map { String(words[..<$0.lowerBound]) + "." } ?? words
        let nextStep = split.map { String(words[$0.upperBound...]) } ?? ""
        return FailureReport(failedStep: step, whatHappened: whatHappened, nextStep: nextStep, underlying: nil)
    }

    // MARK: - The sibling rows

    /// The databases of the bundle's annotation tracks that a row can come from: the track the row names when it names
    /// one, and every track with a database otherwise. A path that leaves the bundle or names no file is left out.
    static func databaseURLs(
        inBundleAt bundleURL: URL,
        tracks: [(id: String, databasePath: String?)],
        trackID: String?
    ) -> [URL] {
        let root = bundleURL.standardizedFileURL
        var urls: [URL] = []
        for track in tracks where trackID == nil || track.id == trackID {
            guard let path = track.databasePath else { continue }
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// The number of sibling rows of `annotation` in the first of `databaseURLs` that holds any.
    static func siblingCount(for annotation: SequenceAnnotation, attributes: [String: String], databaseURLs: [URL]) -> Int {
        guard let part = partType(of: annotation.type), let id = transcriptID(in: attributes),
              let chromosome = annotation.chromosome else { return 0 }
        for url in databaseURLs {
            let count = siblingRowCount(
                in: url, partType: part, chromosome: chromosome, transcriptID: id,
                excludingStart: annotation.start, excludingEnd: annotation.end
            )
            if count > 0 { return count }
        }
        return 0
    }

    /// The one query: how many rows of `partType` on `chromosome` carry `transcriptID`, leaving out the row that has
    /// the span `excludingStart` to `excludingEnd`, which is the selected row or the one exon of a one-exon transcript.
    ///
    /// The database stores a row's attributes as `key=value` pairs joined by `;`, sorted by key, with `%`, `;`, `=`, `&`
    /// and `,` in a value written as `%25`, `%3B`, `%3D`, `%26` and `%2C` (`AnnotationDatabase` build). Matching the whole
    /// pair between two `;` finds `transcript_id` exactly, and not an id that only starts or ends the same or a key that
    /// only ends in `transcript_id`. The database opens read only, and a database that cannot be read counts nothing.
    static func siblingRowCount(
        in databaseURL: URL,
        partType: String,
        chromosome: String,
        transcriptID: String,
        excludingStart: Int,
        excludingEnd: Int
    ) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return 0
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT COUNT(*) FROM annotations \
        WHERE lower(type) = lower(?1) AND chromosome = ?2 AND instr(';' || attributes || ';', ?3) > 0 \
        AND NOT ("start" = ?4 AND "end" = ?5)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, partType, -1, transient)
        sqlite3_bind_text(statement, 2, chromosome, -1, transient)
        sqlite3_bind_text(statement, 3, ";transcript_id=\(storedForm(transcriptID));", -1, transient)
        sqlite3_bind_int64(statement, 4, Int64(excludingStart))
        sqlite3_bind_int64(statement, 5, Int64(excludingEnd))
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// A value as the annotation database writes it into a row's attribute text.
    private static func storedForm(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ";", with: "%3B")
            .replacingOccurrences(of: "=", with: "%3D")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: ",", with: "%2C")
    }
}

// MARK: - The viewer's routes

extension SequenceViewerView {
    /// The words for a selected annotation, or nil when it gets none or the viewer holds no reference bundle.
    func gtfPartsNotJoinedWords(for annotation: SequenceAnnotation, concatenateExons: Bool) -> String? {
        guard let bundle = currentReferenceBundle else { return nil }
        var attributes: [String: String] = [:]
        for (key, qualifier) in annotation.qualifiers {
            if let value = qualifier.values.first { attributes[key] = value }
        }
        let tracks = bundle.manifest.annotations.map { (id: $0.id, databasePath: $0.databasePath) }
        let trackID = annotation.qualifiers[GFF3ExportIdentifiers.trackIDKey]?.values.first
        return GTFPartsNotJoined.words(
            type: annotation.type,
            partCount: annotation.intervals.count,
            attributes: attributes,
            concatenateExons: concatenateExons,
            siblingCount: GTFPartsNotJoined.siblingCount(
                for: annotation,
                attributes: attributes,
                databaseURLs: GTFPartsNotJoined.databaseURLs(inBundleAt: bundle.url, tracks: tracks, trackID: trackID)
            )
        )
    }

    /// Says so after a copy or an extraction of `request` when its annotation is a GTF row an older version stored in
    /// parts. `step` names the route and starts with a verb, as `FailureReport.failedStep` asks. A region gets nothing.
    func presentGTFPartsNotJoinedWords(for request: ExtractionRequest, step: String) {
        guard case .annotation(let annotation) = request.source,
              let words = gtfPartsNotJoinedWords(for: annotation, concatenateExons: request.concatenateExons) else { return }
        FailurePresenter.present(GTFPartsNotJoined.report(words: words, step: step), in: window)
    }
}
