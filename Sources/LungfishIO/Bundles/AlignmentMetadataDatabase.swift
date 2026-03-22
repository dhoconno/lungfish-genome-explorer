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

    /// Returns all flag statistics.
    public func flagStats() -> [FlagStatRecord] {
        var result: [FlagStatRecord] = []
        let sql = "SELECT category, qc_pass, qc_fail FROM flag_stats"
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

    /// SQLITE_TRANSIENT tells SQLite to copy the string data immediately,
    /// preventing use-after-free when the NSString temporary is deallocated
    /// before sqlite3_step executes.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, AlignmentMetadataDatabase.sqliteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, AlignmentMetadataDatabase.sqliteTransient)
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

extension AlignmentMetadataDatabase {

    /// Parses `samtools idxstats` output and populates chromosome_stats table.
    ///
    /// Each line of idxstats output has: refName\tseqLength\tmappedReads\tunmappedReads
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
    /// Each line of flagstat output looks like: "12345 + 0 mapped (99.50% : N/A)"
    public func populateFromFlagstat(_ output: String) {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            // Expected pattern: "<pass> + <fail> <category text>"
            // Example: "12345 + 0 mapped (99.50% : N/A)"
            let components = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard components.count >= 4,
                  let qcPass = Int64(components[0]),
                  components[1] == "+",
                  let qcFail = Int64(components[2]) else {
                continue
            }

            var category = String(components[3])
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
            guard !category.isEmpty else { continue }

            addFlagStat(category: category, qcPass: qcPass, qcFail: qcFail)
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
