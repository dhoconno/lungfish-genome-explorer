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
/// transcript or mRNA, `CDS` for a CDS. A transcript or mRNA row of one part with sibling exon rows is what the old import
/// wrote, so its sequence is the span with its introns whether or not exons are to be joined. A GFF3 row never matches:
/// its mRNA holds blocks and its CDS is merged by `ID`, and its exons carry `Parent` and no `transcript_id` in the stored
/// text. A true one-exon transcript is quiet, because its one exon row has the transcript's own span and so is no other part.
enum GTFPartsNotJoined {
    /// Where the words show. The last words of each sentence name what the person did, so a copy of the nucleotides is
    /// not told to copy the translation again.
    enum Route {
        /// Copy translation, and Extract as protein.
        case translation
        /// Copy as FASTA, and Extract with the nucleotides copied.
        case copy
        /// Extract to a new bundle or a file, and the FASTQ/FASTA operation.
        case extraction
    }

    /// The route that an output mode of the Extract Sequence dialog takes.
    static func route(for outputMode: ExtractionOutputMode) -> Route {
        switch outputMode {
        case .clipboardNucleotide: return .copy
        case .clipboardProtein: return .translation
        case .newBundle: return .extraction
        }
    }

    /// The words for a transcript or mRNA row. The ruling's sentence ends "then extract it again.", and a copy of the
    /// nucleotides ends "then copy it again." A translation cannot reach a transcript, since only a CDS has a protein, so
    /// it takes the extraction ending.
    static func transcriptWords(for route: Route) -> String {
        switch route {
        case .copy:
            return "This transcript came from a GTF track that an older version stored as one part, so this sequence includes its introns. Attach the GTF file again to join its exons, then copy it again."
        case .translation, .extraction:
            return "This transcript came from a GTF track that an older version stored as one part, so this sequence includes its introns. Attach the GTF file again to join its exons, then extract it again."
        }
    }

    /// The words for a CDS row. A translation says protein and to copy the translation again, as the ruling gives it. A
    /// copy or an extraction of the nucleotides says sequence, and to copy it or extract it again.
    static func cdsWords(for route: Route) -> String {
        switch route {
        case .translation:
            return "This CDS is one of several parts in a GTF track that an older version stored separately, so this protein is only part of it. Attach the GTF file again to join the parts, then copy the translation again."
        case .copy:
            return "This CDS is one of several parts in a GTF track that an older version stored separately, so this sequence is only part of it. Attach the GTF file again to join the parts, then copy it again."
        case .extraction:
            return "This CDS is one of several parts in a GTF track that an older version stored separately, so this sequence is only part of it. Attach the GTF file again to join the parts, then extract it again."
        }
    }

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
    ///   - route: Where the words show, which sets their last words.
    ///   - siblingCount: The number of other rows of the part type with the row's `transcript_id` in its track, not
    ///     counting a row of the same span. It runs only when the row can get the words. A transcript or mRNA row of one
    ///     part with sibling exon rows is what the old import wrote, so its sequence is the span with its introns whether
    ///     or not exons are to be joined.
    static func words(
        type: AnnotationType,
        partCount: Int,
        attributes: [String: String],
        route: Route = .extraction,
        siblingCount: @autoclosure () -> Int
    ) -> String? {
        guard partCount == 1, partType(of: type) != nil, transcriptID(in: attributes) != nil else { return nil }
        guard siblingCount() >= 1 else { return nil }
        return type == .cds ? cdsWords(for: route) : transcriptWords(for: route)
    }

    /// The report that carries `words`: the first sentence says what is so, and the rest says what to do. The copy or the
    /// extraction itself worked, so the sheet's title names the join that did not happen and never says "Could not copy".
    static func report(words: String) -> FailureReport {
        let step = words.hasPrefix("This CDS") ? "Join the parts of this CDS" : "Join the exons of this transcript"
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
    /// The words for a selected annotation on `route`, or nil when it gets none or the viewer holds no reference bundle.
    func gtfPartsNotJoinedWords(for annotation: SequenceAnnotation, route: GTFPartsNotJoined.Route) -> String? {
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
            route: route,
            siblingCount: GTFPartsNotJoined.siblingCount(
                for: annotation,
                attributes: attributes,
                databaseURLs: GTFPartsNotJoined.databaseURLs(inBundleAt: bundle.url, tracks: tracks, trackID: trackID)
            )
        )
    }

    /// Says so after a copy or an extraction of `request` when its annotation is a GTF row an older version stored in
    /// parts. A region gets nothing.
    func presentGTFPartsNotJoinedWords(for request: ExtractionRequest, route: GTFPartsNotJoined.Route) {
        guard case .annotation(let annotation) = request.source else { return }
        presentGTFPartsNotJoinedWords(for: [annotation], route: route)
    }

    /// Says so for a selection of annotations that a route took: one sheet for each sentence the selection earns, in
    /// selection order, so a long selection of old CDS lines gets one. The track is asked once for each kind of
    /// sentence (`GTFPartsNotJoined.sentences(forTypes:wordsFor:)`). The words go through `ViewerRefusalSeam`, so a test
    /// binds a recording presenter and no alert opens.
    func presentGTFPartsNotJoinedWords(for annotations: [SequenceAnnotation], route: GTFPartsNotJoined.Route) {
        let sentences = GTFPartsNotJoined.sentences(forTypes: annotations.map(\.type)) {
            gtfPartsNotJoinedWords(for: annotations[$0], route: route)
        }
        for words in sentences {
            ViewerRefusalSeam.present(GTFPartsNotJoined.report(words: words), in: window)
        }
    }
}

extension GTFPartsNotJoined {
    /// The distinct sentences a selection earns, at most one for exons and one for CDS lines. `wordsFor` runs the track
    /// query for the annotation at an index, and a part type whose sentence is found is not asked again.
    static func sentences(forTypes types: [AnnotationType], wordsFor: (Int) -> String?) -> [String] {
        var shown: [String] = []
        var done: Set<String> = []
        for (index, type) in types.enumerated() {
            guard let part = partType(of: type), !done.contains(part), let words = wordsFor(index) else { continue }
            done.insert(part)
            shown.append(words)
            if done.count == 2 { break }
        }
        return shown
    }
}
