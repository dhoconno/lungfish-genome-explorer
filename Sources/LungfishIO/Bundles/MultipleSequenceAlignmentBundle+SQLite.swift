import CryptoKit
import Foundation
import LungfishCore
import SQLite3

extension MultipleSequenceAlignmentBundle {
    static func writeAnnotationSQLiteStore(_ store: AnnotationStore, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw ImportError.sqliteError("open annotations.sqlite failed")
        }
        defer { sqlite3_close_v2(db) }

        try exec("""
        PRAGMA user_version = 1;
        CREATE TABLE annotation_records (
            id TEXT PRIMARY KEY,
            record_order INTEGER NOT NULL,
            origin TEXT NOT NULL,
            row_id TEXT NOT NULL,
            row_name TEXT NOT NULL,
            source_sequence_name TEXT NOT NULL,
            source_file_path TEXT NOT NULL,
            source_track_id TEXT NOT NULL,
            source_track_name TEXT NOT NULL,
            source_annotation_id TEXT NOT NULL,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            strand TEXT NOT NULL,
            source_intervals_json TEXT NOT NULL,
            aligned_intervals_json TEXT NOT NULL,
            qualifiers_json TEXT NOT NULL,
            note TEXT,
            projection_json TEXT,
            warnings_json TEXT NOT NULL
        );
        CREATE TABLE annotation_intervals (
            record_id TEXT NOT NULL,
            coordinate_system TEXT NOT NULL,
            interval_order INTEGER NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            FOREIGN KEY(record_id) REFERENCES annotation_records(id) ON DELETE CASCADE
        );
        CREATE INDEX annotation_records_row_idx ON annotation_records(row_id);
        CREATE INDEX annotation_records_track_idx ON annotation_records(source_track_id);
        CREATE INDEX annotation_records_type_idx ON annotation_records(type);
        CREATE INDEX annotation_intervals_lookup_idx ON annotation_intervals(coordinate_system, start, end);
        """, db: db)

        try exec("BEGIN TRANSACTION", db: db)
        do {
            for (order, record) in store.allAnnotations.enumerated() {
                try execute(
                    """
                    INSERT INTO annotation_records VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        record.id,
                        order,
                        record.origin.rawValue,
                        record.rowID,
                        record.rowName,
                        record.sourceSequenceName,
                        record.sourceFilePath,
                        record.sourceTrackID,
                        record.sourceTrackName,
                        record.sourceAnnotationID,
                        record.name,
                        record.type,
                        record.strand,
                        try jsonString(record.sourceIntervals),
                        try jsonString(record.alignedIntervals),
                        try jsonString(record.qualifiers),
                        record.note ?? NSNull(),
                        try optionalJSONString(record.projection),
                        try jsonString(record.warnings),
                    ],
                    db: db
                )
                try writeAnnotationIntervals(record.sourceIntervals, recordID: record.id, coordinateSystem: "source", db: db)
                try writeAnnotationIntervals(record.alignedIntervals, recordID: record.id, coordinateSystem: "aligned", db: db)
            }
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private static func writeAnnotationIntervals(
        _ intervals: [AnnotationInterval],
        recordID: String,
        coordinateSystem: String,
        db: OpaquePointer
    ) throws {
        for (order, interval) in intervals.enumerated() {
            try execute(
                "INSERT INTO annotation_intervals VALUES (?, ?, ?, ?, ?)",
                values: [
                    recordID,
                    coordinateSystem,
                    order,
                    interval.start,
                    interval.end,
                ],
                db: db
            )
        }
    }

    static func readAnnotationSQLiteStore(from url: URL) throws -> AnnotationStore {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw ImportError.sqliteError("open annotations.sqlite failed")
        }
        defer { sqlite3_close_v2(db) }

        let sql = """
        SELECT origin, row_id, row_name, source_sequence_name, source_file_path,
               source_track_id, source_track_name, source_annotation_id, name, type,
               strand, source_intervals_json, aligned_intervals_json, qualifiers_json,
               note, projection_json, warnings_json, id
        FROM annotation_records
        ORDER BY record_order, row_name, name
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sourceAnnotations: [AlignmentAnnotationRecord] = []
        var projectedAnnotations: [AlignmentAnnotationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let origin = AnnotationOrigin(rawValue: columnText(statement, 0)) ?? .source
            let record = AlignmentAnnotationRecord(
                id: columnText(statement, 17),
                origin: origin,
                rowID: columnText(statement, 1),
                rowName: columnText(statement, 2),
                sourceSequenceName: columnText(statement, 3),
                sourceFilePath: columnText(statement, 4),
                sourceTrackID: columnText(statement, 5),
                sourceTrackName: columnText(statement, 6),
                sourceAnnotationID: columnText(statement, 7),
                name: columnText(statement, 8),
                type: columnText(statement, 9),
                strand: columnText(statement, 10),
                sourceIntervals: try valueFromJSONString([AnnotationInterval].self, columnText(statement, 11)),
                alignedIntervals: try valueFromJSONString([AnnotationInterval].self, columnText(statement, 12)),
                qualifiers: try valueFromJSONString([String: [String]].self, columnText(statement, 13)),
                note: columnOptionalText(statement, 14),
                projection: try optionalValueFromJSONString(ProjectionMetadata.self, columnOptionalText(statement, 15)),
                warnings: try valueFromJSONString([String].self, columnText(statement, 16))
            )
            switch origin {
            case .projected:
                projectedAnnotations.append(record)
            case .source, .manual:
                sourceAnnotations.append(record)
            }
        }
        return AnnotationStore(sourceAnnotations: sourceAnnotations, projectedAnnotations: projectedAnnotations)
    }

    static func writeSQLiteIndex(at url: URL, rows: [Row], columns: [ColumnStat]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw ImportError.sqliteError("open failed")
        }
        defer { sqlite3_close_v2(db) }

        try exec("""
        CREATE TABLE alignment_rows (
            id TEXT PRIMARY KEY,
            source_name TEXT NOT NULL,
            display_name TEXT NOT NULL,
            row_order INTEGER NOT NULL,
            aligned_length INTEGER NOT NULL,
            ungapped_length INTEGER NOT NULL,
            gap_count INTEGER NOT NULL,
            ambiguous_count INTEGER NOT NULL,
            checksum_sha256 TEXT NOT NULL
        );
        CREATE TABLE column_stats (
            column_index INTEGER PRIMARY KEY,
            consensus_residue TEXT NOT NULL,
            residue_counts_json TEXT NOT NULL,
            gap_fraction REAL NOT NULL,
            conservation REAL NOT NULL,
            entropy REAL NOT NULL,
            variable_site INTEGER NOT NULL,
            parsimony_informative INTEGER NOT NULL
        );
        """, db: db)

        try exec("BEGIN TRANSACTION", db: db)
        do {
            try rows.forEach { row in
                try execute(
                    "INSERT INTO alignment_rows VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    values: [
                        row.id,
                        row.sourceName,
                        row.displayName,
                        row.order,
                        row.alignedLength,
                        row.ungappedLength,
                        row.gapCount,
                        row.ambiguousCount,
                        row.checksumSHA256,
                    ],
                    db: db
                )
            }
            try columns.forEach { column in
                let countsData = try JSONSerialization.data(withJSONObject: column.residueCounts, options: [.sortedKeys])
                let countsJSON = String(data: countsData, encoding: .utf8) ?? "{}"
                try execute(
                    "INSERT INTO column_stats VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    values: [
                        column.index,
                        column.consensusResidue,
                        countsJSON,
                        column.gapFraction,
                        column.conservation,
                        column.entropy,
                        column.variableSite ? 1 : 0,
                        column.parsimonyInformative ? 1 : 0,
                    ],
                    db: db
                )
            }
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw ImportError.sqliteError(message)
        }
    }

    private static func execute(_ sql: String, values: [Any], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case let int as Int:
                sqlite3_bind_int64(statement, position, Int64(int))
            case let double as Double:
                sqlite3_bind_double(statement, position, double)
            default:
                sqlite3_bind_null(statement, position)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ImportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static func columnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.malformedInput("Could not encode annotation metadata as UTF-8 JSON.")
        }
        return text
    }

    private static func optionalJSONString<T: Encodable>(_ value: T?) throws -> Any {
        guard let value else { return NSNull() }
        return try jsonString(value)
    }

    private static func valueFromJSONString<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw ImportError.malformedInput("Could not decode annotation metadata JSON.")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func optionalValueFromJSONString<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T? {
        guard let text, !text.isEmpty else { return nil }
        return try valueFromJSONString(type, text)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
