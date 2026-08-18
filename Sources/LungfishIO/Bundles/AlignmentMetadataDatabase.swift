// AlignmentMetadataDatabase.swift - SQLite-backed alignment metadata storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

/// Logger for alignment metadata operations
private let alignmentDBLogger = Logger(subsystem: LogSubsystem.io, category: "AlignmentMetadataDB")

// MARK: - AlignmentMetadataDatabase

/// SQLite database storing alignment file metadata, statistics, and provenance.
///
/// This database does NOT store individual read alignments (BAM files are too large
/// for that). Instead, it caches summary statistics, read group information, per-chromosome
/// coverage stats, and a provenance audit trail. This data is expensive to recompute
/// from the BAM header and index on every bundle open.
///
/// ## Tables
///
/// - `file_info`: Key-value metadata (source path, import date, total reads, etc.)
/// - `read_groups`: @RG header information (sample, library, platform)
/// - `chromosome_stats`: Per-chromosome mapped/unmapped read counts from samtools idxstats
/// - `flag_stats`: samtools flagstat output (QC pass/fail by category)
/// - `provenance`: Audit trail of tool executions
///
/// ## Usage
///
/// ```swift
/// let db = try AlignmentMetadataDatabase.create(at: dbURL)
/// db.setFileInfo("total_reads", value: "1234567")
/// db.addReadGroup(id: "RG1", sample: "Sample1", platform: "ILLUMINA")
/// ```
public final class AlignmentMetadataDatabase: @unchecked Sendable {

    // MARK: - Properties

    /// URL to the SQLite database file.
    public let databaseURL: URL

    /// SQLite connection handle.
    private let db: OpaquePointer

    // MARK: - Initialization

    /// Opens an existing alignment metadata database.
    ///
    /// - Parameter url: Path to the SQLite database file
    /// - Throws: If the database cannot be opened or is invalid
    public init(url: URL) throws {
        self.databaseURL = url
        var dbHandle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &dbHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle = dbHandle else {
            let msg = dbHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbHandle)
            throw AlignmentMetadataError.openFailed(url, msg)
        }
        self.db = handle
    }

    /// Opens a database for read-write access.
    private init(url: URL, readWrite: Bool) throws {
        self.databaseURL = url
        var dbHandle: OpaquePointer?
        let flags = readWrite
            ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(url.path, &dbHandle, flags, nil)
        guard rc == SQLITE_OK, let handle = dbHandle else {
            let msg = dbHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbHandle)
            throw AlignmentMetadataError.openFailed(url, msg)
        }
        self.db = handle
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Database Creation

    /// Creates a new alignment metadata database with the required schema.
    ///
    /// - Parameter url: Path where the database should be created
    /// - Returns: A writable database instance
    /// - Throws: If the database cannot be created
    @discardableResult
    public static func create(at url: URL) throws -> AlignmentMetadataDatabase {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let database = try AlignmentMetadataDatabase(url: url, readWrite: true)
        try database.createSchema()
        return database
    }

    /// Opens an existing alignment metadata database for read-write updates.
    public static func openForUpdate(at url: URL) throws -> AlignmentMetadataDatabase {
        try AlignmentMetadataDatabase(url: url, readWrite: true)
    }

    private func createSchema() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS file_info (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS read_groups (
            id            TEXT PRIMARY KEY,
            sample        TEXT,
            library       TEXT,
            platform      TEXT,
            platform_unit TEXT,
            center        TEXT,
            description   TEXT
        );

        CREATE TABLE IF NOT EXISTS chromosome_stats (
            chromosome     TEXT PRIMARY KEY,
            length         INTEGER NOT NULL,
            mapped_reads   INTEGER NOT NULL,
            unmapped_reads INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chromstats_mapped
            ON chromosome_stats(mapped_reads DESC);

        CREATE TABLE IF NOT EXISTS flag_stats (
            category TEXT PRIMARY KEY,
            qc_pass  INTEGER NOT NULL,
            qc_fail  INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS program_records (
            id            TEXT PRIMARY KEY,
            name          TEXT,
            version       TEXT,
            command_line  TEXT,
            prev_program  TEXT
        );

        CREATE TABLE IF NOT EXISTS provenance (
            step_order  INTEGER PRIMARY KEY,
            tool        TEXT NOT NULL,
            subcommand  TEXT,
            version     TEXT,
            command     TEXT NOT NULL,
            timestamp   TEXT,
            input_file  TEXT,
            output_file TEXT,
            exit_code   INTEGER,
            duration    REAL,
            parent_step INTEGER REFERENCES provenance(step_order)
        );
        """

        let rc = sqlite3_exec(db, schema, nil, nil, nil)
        if rc != SQLITE_OK {
            throw AlignmentMetadataError.schemaFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - File Info

    /// Sets a key-value pair in the file_info table.
    public func setFileInfo(_ key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO file_info (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        sqlite3_step(stmt)
    }

    /// Gets a value from the file_info table.
    public func getFileInfo(_ key: String) -> String? {
        let sql = "SELECT value FROM file_info WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Returns all file_info entries as a dictionary.
    public func allFileInfo() -> [String: String] {
        var result: [String: String] = [:]
        let sql = "SELECT key, value FROM file_info"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            result[key] = value
        }
        return result
    }

    // MARK: - Read Groups

    /// Adds a read group record.
    public func addReadGroup(
        id: String,
        sample: String? = nil,
        library: String? = nil,
        platform: String? = nil,
        platformUnit: String? = nil,
        center: String? = nil,
        description: String? = nil
    ) {
        let sql = """
        INSERT OR REPLACE INTO read_groups
            (id, sample, library, platform, platform_unit, center, description)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, id)
        bindOptionalText(stmt, 2, sample)
        bindOptionalText(stmt, 3, library)
        bindOptionalText(stmt, 4, platform)
        bindOptionalText(stmt, 5, platformUnit)
        bindOptionalText(stmt, 6, center)
        bindOptionalText(stmt, 7, description)
        sqlite3_step(stmt)
    }

    /// Read group record from the database.
    public struct ReadGroupRecord: Sendable {
        public let id: String
        public let sample: String?
        public let library: String?
        public let platform: String?
        public let platformUnit: String?
        public let center: String?
        public let description: String?
    }

    /// Returns all read groups.
    public func readGroups() -> [ReadGroupRecord] {
        var result: [ReadGroupRecord] = []
        let sql = "SELECT id, sample, library, platform, platform_unit, center, description FROM read_groups"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ReadGroupRecord(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                sample: optionalText(stmt, 1),
                library: optionalText(stmt, 2),
                platform: optionalText(stmt, 3),
                platformUnit: optionalText(stmt, 4),
                center: optionalText(stmt, 5),
                description: optionalText(stmt, 6)
            ))
        }
        return result
    }

    /// Returns unique sample names from read groups.
    public func sampleNames() -> [String] {
        var names: [String] = []
        let sql = "SELECT DISTINCT sample FROM read_groups WHERE sample IS NOT NULL ORDER BY sample"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return names }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return names
    }

    // MARK: - Chromosome Stats

    /// Chromosome-level alignment statistics.
    public struct ChromosomeStats: Sendable {
        public let chromosome: String
        public let length: Int64
        public let mappedReads: Int64
        public let unmappedReads: Int64
    }

    /// Adds chromosome statistics (from samtools idxstats).
    public func addChromosomeStats(chromosome: String, length: Int64, mapped: Int64, unmapped: Int64) {
        let sql = """
        INSERT OR REPLACE INTO chromosome_stats (chromosome, length, mapped_reads, unmapped_reads)
        VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, chromosome)
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(length))
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(mapped))
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(unmapped))
        sqlite3_step(stmt)
    }

    /// Returns all chromosome statistics.
    public func chromosomeStats() -> [ChromosomeStats] {
        var result: [ChromosomeStats] = []
        let sql = "SELECT chromosome, length, mapped_reads, unmapped_reads FROM chromosome_stats ORDER BY mapped_reads DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ChromosomeStats(
                chromosome: String(cString: sqlite3_column_text(stmt, 0)),
                length: sqlite3_column_int64(stmt, 1),
                mappedReads: sqlite3_column_int64(stmt, 2),
                unmappedReads: sqlite3_column_int64(stmt, 3)
            ))
        }
        return result
    }

    /// Returns total mapped read count.
    public func totalMappedReads() -> Int64 {
        let sql = "SELECT COALESCE(SUM(mapped_reads), 0) FROM chromosome_stats"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Returns total unmapped read count.
    public func totalUnmappedReads() -> Int64 {
        let sql = "SELECT COALESCE(SUM(unmapped_reads), 0) FROM chromosome_stats"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        let chromosomeTotal = sqlite3_column_int64(stmt, 0)

        guard let flagstatTotal = flagStatCount(category: "total"),
              let flagstatMapped = flagStatCount(category: "mapped"),
              flagstatTotal >= flagstatMapped else {
            return chromosomeTotal
        }
        let wholeFileUnmapped = flagstatTotal - flagstatMapped
        guard wholeFileUnmapped >= chromosomeTotal else { return chromosomeTotal }
        return wholeFileUnmapped
    }

    private func flagStatCount(category: String) -> Int64? {
        let sql = "SELECT qc_pass + qc_fail FROM flag_stats WHERE category = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, category)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - Flag Stats

    /// Adds a flagstat category (from samtools flagstat).
    public func addFlagStat(category: String, qcPass: Int64, qcFail: Int64) {
        let sql = "INSERT OR REPLACE INTO flag_stats (category, qc_pass, qc_fail) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, category)
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(qcPass))
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(qcFail))
        sqlite3_step(stmt)
    }

    /// Flag statistics record.
    public struct FlagStatRecord: Sendable {
        public let category: String
        public let qcPass: Int64
        public let qcFail: Int64
    }

    /// Returns all flag statistics in the order they were inserted.
    ///
    /// `populateFromFlagstat` inserts in samtools' own category order, so the
    /// explicit `ORDER BY rowid` is what makes the displayed order match the
    /// tool's output rather than whatever order the query planner returns.
    public func flagStats() -> [FlagStatRecord] {
        var result: [FlagStatRecord] = []
        let sql = "SELECT category, qc_pass, qc_fail FROM flag_stats ORDER BY rowid"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(FlagStatRecord(
                category: String(cString: sqlite3_column_text(stmt, 0)),
                qcPass: sqlite3_column_int64(stmt, 1),
                qcFail: sqlite3_column_int64(stmt, 2)
            ))
        }
        return result
    }

    // MARK: - Program Records

    /// Program record from the SAM @PG header.
    public struct ProgramRecord: Sendable {
        public let id: String
        public let name: String?
        public let version: String?
        public let commandLine: String?
        public let previousProgram: String?
    }

    /// Adds a program record from a @PG header line.
    public func addProgramRecord(
        id: String,
        name: String? = nil,
        version: String? = nil,
        commandLine: String? = nil,
        previousProgram: String? = nil
    ) {
        let sql = """
        INSERT OR REPLACE INTO program_records
            (id, name, version, command_line, prev_program)
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        bindOptionalText(stmt, 2, name)
        bindOptionalText(stmt, 3, version)
        bindOptionalText(stmt, 4, commandLine)
        bindOptionalText(stmt, 5, previousProgram)
        sqlite3_step(stmt)
    }

    /// Returns all program records.
    public func programRecords() -> [ProgramRecord] {
        var result: [ProgramRecord] = []
        let sql = "SELECT id, name, version, command_line, prev_program FROM program_records"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ProgramRecord(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: optionalText(stmt, 1),
                version: optionalText(stmt, 2),
                commandLine: optionalText(stmt, 3),
                previousProgram: optionalText(stmt, 4)
            ))
        }
        return result
    }

    /// Populates program records from parsed SAM header @PG records.
    public func populateFromProgramRecords(_ records: [SAMParser.ProgramRecord]) {
        for pg in records {
            addProgramRecord(
                id: pg.id,
                name: pg.name,
                version: pg.version,
                commandLine: pg.commandLine,
                previousProgram: pg.previousProgram
            )
        }
    }

    // MARK: - Provenance

    /// Records a tool execution in the provenance table.
    ///
    /// - Returns: The step_order of the new record
    @discardableResult
    public func addProvenanceRecord(
        tool: String,
        subcommand: String? = nil,
        version: String? = nil,
        command: String,
        timestamp: Date = Date(),
        inputFile: String? = nil,
        outputFile: String? = nil,
        exitCode: Int32? = nil,
        duration: TimeInterval? = nil,
        parentStep: Int? = nil
    ) -> Int {
        let sql = """
        INSERT INTO provenance
            (tool, subcommand, version, command, timestamp, input_file, output_file, exit_code, duration, parent_step)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, tool)
        bindOptionalText(stmt, 2, subcommand)
        bindOptionalText(stmt, 3, version)
        bindText(stmt, 4, command)

        let formatter = ISO8601DateFormatter()
        bindText(stmt, 5, formatter.string(from: timestamp))

        bindOptionalText(stmt, 6, inputFile)
        bindOptionalText(stmt, 7, outputFile)

        if let exitCode {
            sqlite3_bind_int(stmt, 8, exitCode)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        if let duration {
            sqlite3_bind_double(stmt, 9, duration)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        if let parentStep {
            sqlite3_bind_int(stmt, 10, Int32(parentStep))
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        sqlite3_step(stmt)
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// Provenance record.
    public struct ProvenanceRecord: Sendable {
        public let stepOrder: Int
        public let tool: String
        public let subcommand: String?
        public let version: String?
        public let command: String
        public let timestamp: String?
        public let inputFile: String?
        public let outputFile: String?
        public let exitCode: Int32?
        public let duration: TimeInterval?
        public let parentStep: Int?
    }

    /// Returns all provenance records in execution order.
    public func provenanceHistory() -> [ProvenanceRecord] {
        var result: [ProvenanceRecord] = []
        let sql = """
        SELECT step_order, tool, subcommand, version, command, timestamp,
               input_file, output_file, exit_code, duration, parent_step
        FROM provenance ORDER BY step_order
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ProvenanceRecord(
                stepOrder: Int(sqlite3_column_int(stmt, 0)),
                tool: String(cString: sqlite3_column_text(stmt, 1)),
                subcommand: optionalText(stmt, 2),
                version: optionalText(stmt, 3),
                command: String(cString: sqlite3_column_text(stmt, 4)),
                timestamp: optionalText(stmt, 5),
                inputFile: optionalText(stmt, 6),
                outputFile: optionalText(stmt, 7),
                exitCode: sqlite3_column_type(stmt, 8) != SQLITE_NULL ? sqlite3_column_int(stmt, 8) : nil,
                duration: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? sqlite3_column_double(stmt, 9) : nil,
                parentStep: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 10)) : nil
            ))
        }
        return result
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, sqliteTransientDestructor)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, sqliteTransientDestructor)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func optionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, index))
    }
}

// MARK: - Samtools Output Parsers

/// Errors raised by the static samtools output parsers.
public enum SamtoolsOutputParseError: Error, LocalizedError, Sendable, Equatable {

    /// The output contained no parseable rows.
    case emptyOutput(String)

    /// An `idxstats` row did not have the four expected fields.
    case malformedIdxstatsRow(line: Int, content: String)

    /// The text was not valid JSON, or was JSON of an unexpected shape.
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput(let tool):
            return "samtools \(tool) produced no parseable output"
        case .malformedIdxstatsRow(let line, let content):
            return "samtools idxstats line \(line) is malformed: '\(content)'"
        case .invalidJSON(let detail):
            return "samtools flagstat JSON could not be parsed: \(detail)"
        }
    }
}

/// One row of `samtools idxstats` output.
public struct IdxstatsRow: Sendable, Equatable {

    /// Reference sequence name. `*` is the unmapped-reads summary row.
    public let chromosome: String

    /// Reference sequence length in bases.
    public let length: Int64

    /// Reads mapped to this reference.
    public let mappedReads: Int64

    /// Reads placed on this reference but unmapped.
    public let unmappedReads: Int64

    public init(chromosome: String, length: Int64, mappedReads: Int64, unmappedReads: Int64) {
        self.chromosome = chromosome
        self.length = length
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
    }
}

/// A parsed `samtools flagstat` report.
///
/// Values are keyed by flagstat's own category names so that a samtools release
/// adding a category is carried through rather than dropped, while the counts
/// the app actually reads are exposed as named properties.
public struct FlagstatSummary: Sendable, Equatable {

    /// QC-passed and QC-failed counts for a single flagstat category.
    public struct Counts: Sendable, Equatable {
        public let qcPass: Int64
        public let qcFail: Int64

        public init(qcPass: Int64, qcFail: Int64) {
            self.qcPass = qcPass
            self.qcFail = qcFail
        }
    }

    /// Every category flagstat reported, keyed by category name (`total`,
    /// `mapped`, `duplicates`, ...).
    public let categories: [String: Counts]

    /// The same category names in the order samtools reported them: source
    /// line order for the text form, key order for the `-O json` form.
    ///
    /// A dictionary has no order, so anything that renders these counts (the
    /// inspector's flag-stat table, the `flag_stats` rows) would otherwise
    /// reshuffle between runs on byte-identical input. samtools orders its
    /// output meaningfully (the total first, then the breakdown), so that
    /// order is preserved rather than replaced with an alphabetical sort.
    ///
    /// Always exactly the keys of ``categories``, with no duplicates.
    public let orderedCategories: [String]

    /// Creates a summary, preserving the caller's category order.
    ///
    /// - Parameter ordered: Category/count pairs in the order samtools reported
    ///   them. A repeated category keeps its first position and takes the last
    ///   value, matching the dictionary-assignment behaviour of the parsers.
    public init(ordered: [(String, Counts)]) {
        var categories: [String: Counts] = [:]
        var order: [String] = []
        for (name, counts) in ordered {
            if categories.updateValue(counts, forKey: name) == nil {
                order.append(name)
            }
        }
        self.categories = categories
        self.orderedCategories = order
    }

    /// Creates a summary from an unordered dictionary.
    ///
    /// Category order falls back to a stable alphabetical sort, since a
    /// dictionary carries no source order to preserve. Prefer ``init(ordered:)``
    /// from a parser, which knows the order samtools used.
    public init(categories: [String: Counts]) {
        self.categories = categories
        self.orderedCategories = categories.keys.sorted()
    }

    /// QC-passed count for a category, or `nil` when flagstat did not report it.
    public func count(_ category: String) -> Int64? {
        categories[category]?.qcPass
    }

    /// QC-passed reads in total.
    public var totalReads: Int64 { count("total") ?? 0 }

    /// QC-passed mapped reads.
    public var mappedReads: Int64 { count("mapped") ?? 0 }

    /// QC-passed duplicate reads.
    public var duplicateReads: Int64 { count("duplicates") ?? 0 }

    /// QC-passed properly paired reads.
    public var properlyPaired: Int64 { count("properly paired") ?? 0 }
}

extension AlignmentMetadataDatabase {

    // MARK: - Static Parsers

    /// Parses `samtools idxstats` output.
    ///
    /// Each row has: `refName\tseqLength\tmappedReads\tunmappedReads`. The `*`
    /// summary row is returned like any other row; callers that populate
    /// per-chromosome tables filter it out.
    ///
    /// - Parameter text: Raw stdout from `samtools idxstats`.
    /// - Returns: One row per reference sequence, in output order.
    /// - Throws: ``SamtoolsOutputParseError`` when the output is empty or a row
    ///   does not have four fields.
    public static func parseIdxstats(_ text: String) throws -> [IdxstatsRow] {
        var rows: [IdxstatsRow] = []
        var lineNumber = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lineNumber += 1
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }

            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else {
                throw SamtoolsOutputParseError.malformedIdxstatsRow(line: lineNumber, content: raw)
            }

            // Strict: a non-numeric count is a format change, not a zero.
            guard let length = Int64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let mapped = Int64(fields[2].trimmingCharacters(in: .whitespaces)),
                  let unmapped = Int64(fields[3].trimmingCharacters(in: .whitespaces)) else {
                throw SamtoolsOutputParseError.malformedIdxstatsRow(line: lineNumber, content: raw)
            }

            rows.append(IdxstatsRow(
                chromosome: String(fields[0]),
                length: length,
                mappedReads: mapped,
                unmappedReads: unmapped
            ))
        }

        guard !rows.isEmpty else {
            throw SamtoolsOutputParseError.emptyOutput("idxstats")
        }
        return rows
    }

    /// Parses the default (human-readable) `samtools flagstat` output.
    ///
    /// Each line looks like `12345 + 0 mapped (99.50% : N/A)`.
    ///
    /// - Parameter text: Raw stdout from `samtools flagstat`.
    /// - Returns: The parsed summary.
    /// - Throws: ``SamtoolsOutputParseError/emptyOutput(_:)`` when no line parsed.
    public static func parseFlagstat(_ text: String) throws -> FlagstatSummary {
        // Accumulated in source line order: samtools prints the total first and
        // then the breakdown, and that order is what the UI displays.
        var ordered: [(String, FlagstatSummary.Counts)] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            // Expected pattern: "<pass> + <fail> <category text>"
            let components = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard components.count >= 4,
                  let qcPass = Int64(components[0]),
                  components[1] == "+",
                  let qcFail = Int64(components[2]) else {
                continue
            }

            let category = normalizeFlagstatCategory(String(components[3]))
            guard !category.isEmpty else { continue }

            ordered.append((category, FlagstatSummary.Counts(qcPass: qcPass, qcFail: qcFail)))
        }

        guard !ordered.isEmpty else {
            throw SamtoolsOutputParseError.emptyOutput("flagstat")
        }
        return FlagstatSummary(ordered: ordered)
    }

    /// Parses `samtools flagstat -O json` output.
    ///
    /// The JSON form is preferred where available because it is not sensitive to
    /// the wording of the human-readable lines.
    ///
    /// - Parameter json: Raw stdout from `samtools flagstat -O json`.
    /// - Returns: The parsed summary.
    /// - Throws: ``SamtoolsOutputParseError/invalidJSON(_:)`` when the text is
    ///   not JSON or lacks a `QC-passed reads` object.
    public static func parseFlagstat(json: String) throws -> FlagstatSummary {
        guard let data = json.data(using: .utf8) else {
            throw SamtoolsOutputParseError.invalidJSON("output is not UTF-8")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SamtoolsOutputParseError.invalidJSON(error.localizedDescription)
        }

        guard let root = object as? [String: Any] else {
            throw SamtoolsOutputParseError.invalidJSON("top level is not an object")
        }
        guard let passed = root["QC-passed reads"] as? [String: Any] else {
            throw SamtoolsOutputParseError.invalidJSON("missing 'QC-passed reads' object")
        }
        let failed = root["QC-failed reads"] as? [String: Any] ?? [:]

        /// Reads an integer count, ignoring the `... %` percentage entries.
        func intCount(_ container: [String: Any], _ key: String) -> Int64? {
            guard let value = container[key] else { return nil }
            if let number = value as? NSNumber { return number.int64Value }
            if let string = value as? String { return Int64(string) }
            return nil
        }

        // JSONSerialization returns an unordered dictionary, so the samtools key
        // order (which matches the text form's line order and is what the UI
        // displays) is recovered from the raw text instead.
        let names = orderedJSONKeys(in: json, union: Set(passed.keys).union(failed.keys))

        var ordered: [(String, FlagstatSummary.Counts)] = []
        for name in names where !name.hasSuffix(" %") {
            let pass = intCount(passed, name)
            let fail = intCount(failed, name)
            guard pass != nil || fail != nil else { continue }
            ordered.append((name, FlagstatSummary.Counts(qcPass: pass ?? 0, qcFail: fail ?? 0)))
        }

        guard !ordered.isEmpty else {
            throw SamtoolsOutputParseError.invalidJSON("no numeric categories present")
        }
        return FlagstatSummary(ordered: ordered)
    }

    /// Orders `keys` by where each first appears as an object key in `json`.
    ///
    /// This is a presentation concern only: the values always come from the
    /// real JSON parse above, and a key whose literal is not found (an escaped
    /// or unusually encoded name) sorts last alphabetically rather than being
    /// dropped, so no category is ever lost to this lookup.
    private static func orderedJSONKeys(in json: String, union keys: Set<String>) -> [String] {
        var positions: [String: String.Index] = [:]
        for key in keys {
            // Match the quoted key followed by its colon, so a key that also
            // occurs as a string *value* elsewhere does not win the position.
            if let range = json.range(of: "\"\(key)\"") {
                let afterKey = json[range.upperBound...]
                if afterKey.drop(while: { $0 == " " || $0 == "\t" }).first == ":" {
                    positions[key] = range.lowerBound
                }
            }
        }
        return keys.sorted { left, right in
            switch (positions[left], positions[right]) {
            case let (leftIndex?, rightIndex?):
                return leftIndex < rightIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }
    }

    /// Maps a raw flagstat category phrase to the stable key used in the
    /// `flag_stats` table and in ``FlagstatSummary``.
    static func normalizeFlagstatCategory(_ raw: String) -> String {
        var category = raw
        // Strip trailing percentages/notes in parentheses for stable category keys.
        if let parenIndex = category.firstIndex(of: "(") {
            let parenContent = category[parenIndex...]
            // Strip trailing percentages/format notes like "(97.20% : N/A)",
            // but keep semantic qualifiers like "(mapQ>=5)".
            if parenContent.contains("%") || parenContent.localizedCaseInsensitiveContains("N/A") {
                category = String(category[..<parenIndex]).trimmingCharacters(in: .whitespaces)
            }
        }
        if category == "in total" || category.hasPrefix("in total ") {
            category = "total"
        }
        return category
    }

    // MARK: - Populate

    /// Parses `samtools idxstats` output and populates chromosome_stats table.
    ///
    /// Each line of idxstats output has: refName\tseqLength\tmappedReads\tunmappedReads
    ///
    /// Malformed rows are tolerated here (skipped) because this path runs during
    /// import where a partial table is better than a failed import. Use
    /// ``parseIdxstats(_:)`` when a format change should be surfaced.
    public func populateFromIdxstats(_ output: String) {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 4 else { continue }
            let chrom = String(fields[0])
            guard chrom != "*" else { continue } // Skip the unmapped summary line
            let length = Int64(fields[1]) ?? 0
            let mapped = Int64(fields[2]) ?? 0
            let unmapped = Int64(fields[3]) ?? 0
            addChromosomeStats(chromosome: chrom, length: length, mapped: mapped, unmapped: unmapped)
        }
    }

    /// Parses `samtools flagstat` output and populates flag_stats table.
    ///
    /// Accepts either the human-readable text form or the `-O json` form.
    /// Unparseable output leaves the table empty rather than failing the import.
    public func populateFromFlagstat(_ output: String) {
        let summary: FlagstatSummary?
        if let fromJSON = try? Self.parseFlagstat(json: output) {
            summary = fromJSON
        } else {
            summary = try? Self.parseFlagstat(output)
        }
        guard let summary else { return }

        // Insert in samtools' own order. `flagStats()` reads the rows back in
        // insertion order, so iterating the dictionary here would give the
        // inspector a different row order on every run over identical input.
        for category in summary.orderedCategories {
            guard let counts = summary.categories[category] else { continue }
            addFlagStat(category: category, qcPass: counts.qcPass, qcFail: counts.qcFail)
        }
    }

    /// Populates read groups from parsed SAM header read groups.
    public func populateFromReadGroups(_ readGroups: [SAMParser.ReadGroup]) {
        for rg in readGroups {
            addReadGroup(
                id: rg.id,
                sample: rg.sample,
                library: rg.library,
                platform: rg.platform,
                platformUnit: rg.platformUnit,
                center: rg.center,
                description: rg.description
            )
        }
    }
}

// MARK: - Error Types

/// Errors from alignment metadata database operations.
public enum AlignmentMetadataError: Error, LocalizedError {
    case openFailed(URL, String)
    case schemaFailed(String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let url, let msg):
            return "Cannot open alignment database at \(url.lastPathComponent): \(msg)"
        case .schemaFailed(let msg):
            return "Failed to create alignment database schema: \(msg)"
        case .importFailed(let msg):
            return "Failed to import alignment metadata: \(msg)"
        }
    }
}
