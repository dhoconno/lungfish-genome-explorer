// NaoMgsDatabase.swift - SQLite-backed database for NAO-MGS virus hits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "NaoMgsDatabase")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
private func naoBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - NaoMgsDatabaseError

/// Errors from NAO-MGS database operations.
public enum NaoMgsDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open NAO-MGS database: \(msg)"
        case .createFailed(let msg): return "Failed to create NAO-MGS database: \(msg)"
        case .queryFailed(let msg): return "NAO-MGS database query failed: \(msg)"
        case .insertFailed(let msg): return "NAO-MGS database insert failed: \(msg)"
        }
    }
}

// MARK: - Result Types

/// A single row in the taxonomy table — one per (sample, taxon) pair.
public struct NaoMgsTaxonSummaryRow: Codable, Sendable {
    public let sample: String
    public let taxId: Int
    public let name: String
    public let hitCount: Int
    public let uniqueReadCount: Int
    public let avgIdentity: Double
    public let avgBitScore: Double
    public let avgEditDistance: Double
    public let pcrDuplicateCount: Int
    public let accessionCount: Int
    public let topAccessions: [String]  // decoded from JSON
    public let bamPath: String?
    public let bamIndexPath: String?
}

/// Per-accession summary within a (sample, taxon) pair.
public struct NaoMgsAccessionSummary: Sendable {
    public let accession: String
    public let readCount: Int
    public let uniqueReadCount: Int
    public let referenceLength: Int
    public let coveredBasePairs: Int
    public let coverageFraction: Double
}

/// A staged per-sample NAO-MGS database to merge into a final summary database.
public struct NaoMgsStageDatabaseInput: Sendable {
    public let sample: String
    public let databaseURL: URL
    public let bamRelativePath: String
    public let bamIndexRelativePath: String?

    public init(
        sample: String,
        databaseURL: URL,
        bamRelativePath: String,
        bamIndexRelativePath: String?
    ) {
        self.sample = sample
        self.databaseURL = databaseURL
        self.bamRelativePath = bamRelativePath
        self.bamIndexRelativePath = bamIndexRelativePath
    }
}

// MARK: - NaoMgsDatabase

/// SQLite-backed storage for NAO-MGS virus hits and taxon summaries.
///
/// Provides fast random-access queries for taxonomy browsing and detail views.
/// Created once during import, then opened read-only for all subsequent access.
///
/// Thread-safe via `@unchecked Sendable` — the underlying SQLite handle uses
/// `SQLITE_OPEN_FULLMUTEX` (serialized mode).
public final class NaoMgsDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }

    // MARK: - Open Existing (Read-Only)

    /// Opens an existing NAO-MGS database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``NaoMgsDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public init(at url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw NaoMgsDatabaseError.openFailed(msg)
        }
        // Schema migration: check which tables/columns need to be added.
        var hasRefLengths = false
        var hasAccessionSummaries = false
        var hasTaxonReadNames = false
        var hasSampleHitCounts = false
        let tableListSQL = "SELECT name FROM sqlite_master WHERE type='table'"
        var tblStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, tableListSQL, -1, &tblStmt, nil) == SQLITE_OK {
            while sqlite3_step(tblStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(tblStmt, 0) {
                    let name = String(cString: namePtr)
                    if name == "reference_lengths" { hasRefLengths = true }
                    if name == "accession_summaries" { hasAccessionSummaries = true }
                    if name == "taxon_read_names" { hasTaxonReadNames = true }
                    if name == "sample_hit_counts" { hasSampleHitCounts = true }
                }
            }
            sqlite3_finalize(tblStmt)
        }

        var hasBamPath = false
        var hasBamIndexPath = false
        let colCheck = "PRAGMA table_info(taxon_summaries)"
        var colStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, colCheck, -1, &colStmt, nil) == SQLITE_OK {
            while sqlite3_step(colStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(colStmt, 1) {
                    let colName = String(cString: namePtr)
                    if colName == "bam_path" { hasBamPath = true }
                    if colName == "bam_index_path" { hasBamIndexPath = true }
                }
            }
            sqlite3_finalize(colStmt)
        }

        let needsMigration = !hasRefLengths || !hasAccessionSummaries || !hasTaxonReadNames || !hasSampleHitCounts || !hasBamPath || !hasBamIndexPath
        if needsMigration {
            sqlite3_close(db)
            self.db = nil

            var rwDB: OpaquePointer?
            if sqlite3_open_v2(url.path, &rwDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                if !hasRefLengths {
                    sqlite3_exec(rwDB, "CREATE TABLE IF NOT EXISTS reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL)", nil, nil, nil)
                }
                if !hasBamPath {
                    sqlite3_exec(rwDB, "ALTER TABLE taxon_summaries ADD COLUMN bam_path TEXT", nil, nil, nil)
                }
                if !hasBamIndexPath {
                    sqlite3_exec(rwDB, "ALTER TABLE taxon_summaries ADD COLUMN bam_index_path TEXT", nil, nil, nil)
                }
                if !hasAccessionSummaries {
                    sqlite3_exec(rwDB, """
                    CREATE TABLE IF NOT EXISTS accession_summaries (
                        sample TEXT NOT NULL,
                        tax_id INTEGER NOT NULL,
                        accession TEXT NOT NULL,
                        read_count INTEGER NOT NULL,
                        unique_read_count INTEGER NOT NULL,
                        reference_length INTEGER NOT NULL,
                        covered_base_pairs INTEGER NOT NULL,
                        coverage_fraction REAL NOT NULL,
                        PRIMARY KEY (sample, tax_id, accession)
                    )
                    """, nil, nil, nil)
                    // Populate from virus_hits if rows exist (pre-migration database)
                    if let rwDB {
                        var countStmt: OpaquePointer?
                        if sqlite3_prepare_v2(rwDB, "SELECT COUNT(*) FROM virus_hits", -1, &countStmt, nil) == SQLITE_OK {
                            if sqlite3_step(countStmt) == SQLITE_ROW, sqlite3_column_int64(countStmt, 0) > 0 {
                                logger.info("Migrating: computing accession_summaries from virus_hits")
                                try? Self.computeAccessionSummaries(db: rwDB)
                            }
                            sqlite3_finalize(countStmt)
                        }
                    }
                }
                if !hasTaxonReadNames {
                    sqlite3_exec(rwDB, """
                    CREATE TABLE IF NOT EXISTS taxon_read_names (
                        sample TEXT NOT NULL,
                        tax_id INTEGER NOT NULL,
                        seq_id TEXT NOT NULL,
                        PRIMARY KEY (sample, tax_id, seq_id)
                    )
                    """, nil, nil, nil)
                    try? Self.populateTaxonReadNames(db: rwDB)
                    sqlite3_exec(rwDB, "CREATE INDEX IF NOT EXISTS idx_taxon_read_names_sample_taxid ON taxon_read_names(sample, tax_id)", nil, nil, nil)
                }
                if !hasSampleHitCounts {
                    sqlite3_exec(rwDB, """
                    CREATE TABLE IF NOT EXISTS sample_hit_counts (
                        sample TEXT PRIMARY KEY,
                        hit_count INTEGER NOT NULL
                    )
                    """, nil, nil, nil)
                    try? Self.populateSampleHitCounts(db: rwDB)
                }
                sqlite3_close(rwDB)
            }

            let rc2 = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard rc2 == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
                sqlite3_close(db)
                self.db = nil
                throw NaoMgsDatabaseError.openFailed(msg)
            }
        }

        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)   // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil) // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        logger.info("Opened NAO-MGS database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Create New Database

    /// Creates a new NAO-MGS database from parsed virus hits.
    ///
    /// Deletes any existing file at `url`, creates the schema, bulk-inserts all hits,
    /// builds indices, and computes taxon summaries via SQL aggregation.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - hits: Parsed virus hits to insert.
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: An `NaoMgsDatabase` opened read-only on the new file.
    /// - Throws: ``NaoMgsDatabaseError`` on failure.
    @discardableResult
    public static func create(
        at url: URL,
        hits: [NaoMgsVirusHit],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> NaoMgsDatabase {
        // Delete existing file
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw NaoMgsDatabaseError.createFailed(msg)
        }

        // Performance pragmas for bulk import
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: db)
            progress?(0.05, "Schema created")

            try bulkInsertHits(db: db, hits: hits, progress: progress)
            try populateTaxonReadNames(db: db)
            try populateSampleHitCounts(db: db)
            progress?(0.70, "Building indices...")

            try createIndices(db: db)
            progress?(0.80, "Computing taxon summaries...")

            try computeTaxonSummaries(db: db)
            progress?(0.90, "Computing accession summaries...")

            try computeAccessionSummaries(db: db)
            progress?(0.95, "Finalizing...")

            sqlite3_close(db)
            logger.info("Created NAO-MGS database with \(hits.count) hits at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try NaoMgsDatabase(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Creates a summary-only NAO-MGS database by merging staged per-sample databases.
    ///
    /// Copies `taxon_summaries`, `accession_summaries`, and `reference_lengths`
    /// from each stage database. `virus_hits` rows are intentionally not copied.
    ///
    /// - Parameters:
    ///   - url: Path for the merged SQLite database file.
    ///   - stageInputs: Per-sample stage databases and bundle-relative BAM metadata.
    public static func createMergedSummaryDatabase(
        at url: URL,
        from stageInputs: [NaoMgsStageDatabaseInput]
    ) throws {
        try? FileManager.default.removeItem(at: url)

        var mergedDB: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &mergedDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let mergedDB else {
            let msg = mergedDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(mergedDB)
            throw NaoMgsDatabaseError.createFailed(msg)
        }

        sqlite3_exec(mergedDB, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(mergedDB, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(mergedDB, "PRAGMA cache_size = -65536", nil, nil, nil)
        sqlite3_exec(mergedDB, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: mergedDB)
            try mergeStageSummaries(into: mergedDB, from: stageInputs)
            try createIndices(db: mergedDB)

            sqlite3_close(mergedDB)
            logger.info("Created merged NAO-MGS summary database from \(stageInputs.count) staged samples at \(url.lastPathComponent)")
        } catch {
            sqlite3_close(mergedDB)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Streaming Import Result

    /// Metadata returned by `createStreaming` after a streaming import.
    public struct StreamingImportResult: Sendable {
        /// Total number of hits inserted (after identity filtering).
        public let hitCount: Int
        /// Sample name (from the first row, or user override).
        public let sampleName: String
        /// Number of distinct (sample, taxId) pairs.
        public let taxonCount: Int
        /// Path to the virus_hits TSV file that was parsed.
        public let virusHitsFile: URL
    }

    // MARK: - Streaming Create

    /// In-memory accumulator for computing taxon and accession summaries during
    /// streaming import. Avoids expensive post-insert SQL aggregation queries.
    private final class TaxonAccumulator {
        var hitCount: Int = 0
        var identitySum: Double = 0
        var bitScoreSum: Double = 0
        var editDistanceSum: Int = 0
        var accessions: Set<String> = []
        var alignmentSignatures: Set<UInt64> = []
        var accessionSignatures: [String: Set<UInt64>] = [:]
        var accessionReadCounts: [String: Int] = [:]
        var accessionIntervals: [String: [(start: Int, end: Int)]] = [:]
        var accessionMaxExtent: [String: Int] = [:]
        var name: String = ""
    }

    /// Creates a new NAO-MGS database by streaming rows from one or more TSV files
    /// directly into SQLite. Never holds the full hit array in memory — O(1) per row.
    ///
    /// Computes taxon and accession summaries in-memory during streaming, avoiding
    /// expensive post-insert SQL aggregation queries.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - tsvURLs: Paths to virus_hits TSV files (single monolithic or per-lane).
    ///   - sampleNameOverride: If non-nil, used as the sample name.
    ///   - minIdentity: Minimum percent identity threshold (0 = no filter).
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: A ``StreamingImportResult`` with metadata.
    public static func createStreaming(
        at url: URL,
        from tsvURLs: [URL],
        sampleNameOverride: String? = nil,
        minIdentity: Double = 0,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> StreamingImportResult {
        guard !tsvURLs.isEmpty else {
            throw NaoMgsDatabaseError.createFailed("No TSV files provided")
        }

        // Delete existing file
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw NaoMgsDatabaseError.createFailed(msg)
        }

        // Performance pragmas for bulk import
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: db)
            progress?(0.02, "Schema created")

            // Prepare insert statement
            let insertSQL = """
            INSERT INTO virus_hits (
                sample, seq_id, tax_id, subject_seq_id, subject_title,
                ref_start, cigar, read_sequence, read_quality,
                percent_identity, bit_score, e_value, edit_distance,
                query_length, is_reverse_complement, pair_status,
                fragment_length, best_alignment_score, ref_start_rev,
                read_sequence_rev, read_quality_rev, edit_distance_rev,
                query_length_rev, is_reverse_complement_rev, best_alignment_score_rev
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.insertFailed("Prepare failed: \(msg)")
            }
            defer { sqlite3_finalize(insertStmt) }

            let insertReadNameSQL = """
            INSERT OR IGNORE INTO taxon_read_names (sample, tax_id, seq_id)
            VALUES (?, ?, ?)
            """
            var insertReadNameStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertReadNameSQL, -1, &insertReadNameStmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.insertFailed("Prepare failed: \(msg)")
            }
            defer { sqlite3_finalize(insertReadNameStmt) }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            var insertedCount = 0
            var firstSampleName: String?
            let identityFloor = max(0, min(100, minIdentity))
            let batchSize = 100_000
            let totalFiles = tsvURLs.count

            // Streaming accumulators — keyed by (sample, taxId)
            var accumulators: [String: [Int: TaxonAccumulator]] = [:]

            // Alignment signature hash for deduplication
            func alignmentHash(
                accession: String,
                refStart: Int,
                isRC: Bool,
                qLen: Int
            ) -> UInt64 {
                var hasher = Hasher()
                hasher.combine(accession)
                hasher.combine(refStart)
                hasher.combine(isRC)
                hasher.combine(qLen)
                return UInt64(bitPattern: Int64(hasher.finalize()))
            }

            // Process each TSV file sequentially
            for (fileIndex, tsvURL) in tsvURLs.enumerated() {
                var columnMap: NaoMgsResultParser.ColumnMap?
                var lineNumber = 0

                let fileProgress = totalFiles > 1
                    ? "[\(fileIndex + 1)/\(totalFiles)] "
                    : ""

                // Set up synchronous line reader from gzip or plain text
                let isGzip = tsvURL.pathExtension.lowercased() == "gz"

                let readHandle: FileHandle
                var gzipProcess: Process?

                if isGzip {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                    process.arguments = ["-dc", tsvURL.path]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    readHandle = pipe.fileHandleForReading
                    gzipProcess = process
                } else {
                    readHandle = try FileHandle(forReadingFrom: tsvURL)
                }
                defer {
                    if isGzip {
                        gzipProcess?.waitUntilExit()
                    }
                }

                // Read in chunks and parse lines synchronously — O(chunk) memory
                let chunkSize = 4_194_304  // 4 MB — larger chunks reduce read syscalls
                var partial = Data()

                // Reusable field buffer to avoid per-row array allocation.
                var fieldBuffer: [Substring] = []
                fieldBuffer.reserveCapacity(32)

                func processLine(_ line: Substring) throws {
                    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
                    if trimmed.isEmpty { return }

                    if columnMap == nil {
                        let headers = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
                            .map { String($0) }
                        columnMap = try NaoMgsResultParser.ColumnMap(headers: headers)
                        return
                    }

                    lineNumber += 1
                    fieldBuffer.removeAll(keepingCapacity: true)
                    for field in trimmed.split(separator: "\t", omittingEmptySubsequences: false) {
                        fieldBuffer.append(field)
                    }
                    let fields = fieldBuffer

                    guard let map = columnMap else { return }
                    let minFields = max(map.sample, map.seqId, map.taxId) + 1
                    guard fields.count >= minFields else { return }

                    let taxIdStr = fields[map.taxId]
                    guard let taxId = Int(taxIdStr) else { return }

                    // Read R1 and R2 data — either or both may be present
                    let readSeq = naoStringField(fields, map.readSequence)
                    let readSeqRev = naoStringField(fields, map.readSequenceRev)
                    let hasR1 = !readSeq.isEmpty && readSeq != "NA"
                    let hasR2 = !readSeqRev.isEmpty && readSeqRev != "NA"

                    // Every row is a classified read — skip only if NEITHER mate has data
                    if !hasR1 && !hasR2 { return }

                    let readQual = naoStringField(fields, map.readQuality)
                    let readQualRev = naoStringField(fields, map.readQualityRev)
                    let subjectSeqId = naoStringField(fields, map.subjectSeqId)
                    let subjectTitle = naoStringField(fields, map.subjectTitle)
                    let pairStat = naoStringField(fields, map.pairStatus)
                    let fragLen = naoIntField(fields, map.fragmentLength)

                    // R1 fields (nullable if R1 is absent)
                    let refStart = naoIntField(fields, map.refStart)
                    let editDist = naoIntField(fields, map.editDistance)
                    let qLen = naoIntField(fields, map.queryLen)
                    let rcStr = naoStringField(fields, map.queryRC).lowercased()
                    let isRC = rcStr == "true" || rcStr == "1"
                    let alignScore = naoDoubleField(fields, map.bestAlignmentScore)

                    var cigar = naoStringField(fields, map.cigar)
                    if cigar.isEmpty && hasR1 {
                        let effectiveQLen = qLen > 0 ? qLen : readSeq.count
                        if effectiveQLen > 0 { cigar = "\(effectiveQLen)M" }
                    }

                    // R2 fields
                    let refStartRev = naoIntField(fields, map.refStartRev)
                    let editDistRev = naoIntField(fields, map.editDistanceRev)
                    let qLenRev = naoIntField(fields, map.queryLenRev)
                    let rcRevStr = naoStringField(fields, map.queryRCRev).lowercased()
                    let isRCRev = rcRevStr == "true" || rcRevStr == "1"
                    let alignScoreRev = naoDoubleField(fields, map.bestAlignmentScoreRev)

                    // Compute percent identity from whichever mate has alignment data
                    let bitScore = naoDoubleField(fields, map.bitScore)
                    let effectiveBitScore = bitScore > 0 ? bitScore : (hasR1 ? alignScore : alignScoreRev)
                    let effectiveEditDist = hasR1 ? editDist : editDistRev
                    let effectiveLen: Int
                    if hasR1 {
                        effectiveLen = qLen > 0 ? qLen : readSeq.count
                    } else {
                        effectiveLen = qLenRev > 0 ? qLenRev : readSeqRev.count
                    }
                    let percentIdentity: Double = {
                        let pident = naoDoubleField(fields, map.percentIdentity)
                        if pident > 0 { return pident }
                        guard effectiveLen > 0 else { return 0 }
                        return max(0, (1.0 - Double(effectiveEditDist) / Double(effectiveLen)) * 100.0)
                    }()

                    if identityFloor > 0, percentIdentity < identityFloor { return }

                    let sampleName = normalizeImportedSampleName(String(fields[map.sample]))
                    if firstSampleName == nil { firstSampleName = sampleName }

                    // --- Bind to SQLite ---
                    sqlite3_reset(insertStmt)
                    sqlite3_clear_bindings(insertStmt)
                    naoBindText(insertStmt, 1, sampleName)
                    naoBindText(insertStmt, 2, String(fields[map.seqId]))
                    sqlite3_bind_int64(insertStmt, 3, Int64(taxId))
                    naoBindText(insertStmt, 4, subjectSeqId)
                    naoBindText(insertStmt, 5, subjectTitle)

                    // R1 fields — NULL if R1 is absent
                    if hasR1 {
                        sqlite3_bind_int64(insertStmt, 6, Int64(refStart))
                        naoBindText(insertStmt, 7, cigar)
                        naoBindText(insertStmt, 8, readSeq)
                        naoBindText(insertStmt, 9, readQual)
                    } else {
                        sqlite3_bind_null(insertStmt, 6)
                        sqlite3_bind_null(insertStmt, 7)
                        sqlite3_bind_null(insertStmt, 8)
                        sqlite3_bind_null(insertStmt, 9)
                    }

                    sqlite3_bind_double(insertStmt, 10, percentIdentity)
                    sqlite3_bind_double(insertStmt, 11, effectiveBitScore)
                    sqlite3_bind_double(insertStmt, 12, naoDoubleField(fields, map.eValue))

                    if hasR1 {
                        sqlite3_bind_int(insertStmt, 13, Int32(editDist))
                        sqlite3_bind_int(insertStmt, 14, Int32(qLen > 0 ? qLen : readSeq.count))
                        sqlite3_bind_int(insertStmt, 15, isRC ? 1 : 0)
                    } else {
                        sqlite3_bind_null(insertStmt, 13)
                        sqlite3_bind_null(insertStmt, 14)
                        sqlite3_bind_null(insertStmt, 15)
                    }

                    naoBindText(insertStmt, 16, pairStat)
                    sqlite3_bind_int(insertStmt, 17, Int32(fragLen))

                    if hasR1 {
                        sqlite3_bind_double(insertStmt, 18, alignScore)
                    } else {
                        sqlite3_bind_null(insertStmt, 18)
                    }

                    // R2 fields
                    if hasR2 {
                        if map.refStartRev != nil, refStartRev > 0 {
                            sqlite3_bind_int64(insertStmt, 19, Int64(refStartRev))
                        } else {
                            sqlite3_bind_null(insertStmt, 19)
                        }
                        naoBindText(insertStmt, 20, readSeqRev)
                        if !readQualRev.isEmpty && readQualRev != "NA" {
                            naoBindText(insertStmt, 21, readQualRev)
                        } else {
                            sqlite3_bind_null(insertStmt, 21)
                        }
                    } else {
                        sqlite3_bind_null(insertStmt, 19)
                        sqlite3_bind_null(insertStmt, 20)
                        sqlite3_bind_null(insertStmt, 21)
                    }
                    if map.editDistanceRev != nil && hasR2 {
                        sqlite3_bind_int(insertStmt, 22, Int32(editDistRev))
                    } else {
                        sqlite3_bind_null(insertStmt, 22)
                    }
                    if map.queryLenRev != nil, qLenRev > 0 {
                        sqlite3_bind_int(insertStmt, 23, Int32(qLenRev))
                    } else {
                        sqlite3_bind_null(insertStmt, 23)
                    }
                    if map.queryRCRev != nil && hasR2 {
                        sqlite3_bind_int(insertStmt, 24, isRCRev ? 1 : 0)
                    } else {
                        sqlite3_bind_null(insertStmt, 24)
                    }
                    if map.bestAlignmentScoreRev != nil && hasR2 {
                        sqlite3_bind_double(insertStmt, 25, alignScoreRev)
                    } else {
                        sqlite3_bind_null(insertStmt, 25)
                    }

                    guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                        let msg = String(cString: sqlite3_errmsg(db))
                        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                        throw NaoMgsDatabaseError.insertFailed("Row \(lineNumber) failed: \(msg)")
                    }

                    sqlite3_reset(insertReadNameStmt)
                    sqlite3_clear_bindings(insertReadNameStmt)
                    naoBindText(insertReadNameStmt, 1, sampleName)
                    sqlite3_bind_int64(insertReadNameStmt, 2, Int64(taxId))
                    naoBindText(insertReadNameStmt, 3, String(fields[map.seqId]))
                    guard sqlite3_step(insertReadNameStmt) == SQLITE_DONE else {
                        let msg = String(cString: sqlite3_errmsg(db))
                        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                        throw NaoMgsDatabaseError.insertFailed("Read-name row \(lineNumber) failed: \(msg)")
                    }

                    insertedCount += 1

                    // --- Update streaming accumulators (class = mutate in-place) ---
                    let acc: TaxonAccumulator
                    if let existing = accumulators[sampleName]?[taxId] {
                        acc = existing
                    } else {
                        acc = TaxonAccumulator()
                        accumulators[sampleName, default: [:]][taxId] = acc
                    }
                    let alignmentCount = (hasR1 ? 1 : 0) + (hasR2 ? 1 : 0)
                    acc.hitCount += alignmentCount
                    acc.identitySum += percentIdentity * Double(alignmentCount)
                    acc.bitScoreSum += effectiveBitScore * Double(alignmentCount)
                    acc.editDistanceSum += effectiveEditDist * alignmentCount
                    acc.accessions.insert(subjectSeqId)
                    if acc.name.isEmpty { acc.name = subjectTitle }

                    if hasR1 {
                        let r1Len = qLen > 0 ? qLen : readSeq.count
                        let r1SigHash = alignmentHash(
                            accession: subjectSeqId,
                            refStart: refStart,
                            isRC: isRC,
                            qLen: r1Len
                        )
                        acc.alignmentSignatures.insert(r1SigHash)
                        acc.accessionSignatures[subjectSeqId, default: []].insert(r1SigHash)
                        acc.accessionReadCounts[subjectSeqId, default: 0] += 1
                    }
                    if hasR2 && refStartRev > 0 {
                        let r2Len = qLenRev > 0 ? qLenRev : readSeqRev.count
                        let r2SigHash = alignmentHash(
                            accession: subjectSeqId,
                            refStart: refStartRev,
                            isRC: isRCRev,
                            qLen: r2Len
                        )
                        acc.alignmentSignatures.insert(r2SigHash)
                        acc.accessionSignatures[subjectSeqId, default: []].insert(r2SigHash)
                        acc.accessionReadCounts[subjectSeqId, default: 0] += 1
                    }

                    // Per-accession coverage intervals
                    if hasR1 {
                        let r1Len = qLen > 0 ? qLen : readSeq.count
                        acc.accessionIntervals[subjectSeqId, default: []].append((start: refStart, end: refStart + r1Len))
                        let r1End = refStart + r1Len
                        acc.accessionMaxExtent[subjectSeqId] = max(acc.accessionMaxExtent[subjectSeqId] ?? 0, r1End)
                    }
                    if hasR2 && refStartRev > 0 {
                        let r2Len = qLenRev > 0 ? qLenRev : readSeqRev.count
                        acc.accessionIntervals[subjectSeqId, default: []].append((start: refStartRev, end: refStartRev + r2Len))
                        let r2End = refStartRev + r2Len
                        acc.accessionMaxExtent[subjectSeqId] = max(acc.accessionMaxExtent[subjectSeqId] ?? 0, r2End)
                    }

                    if insertedCount % batchSize == 0 {
                        sqlite3_exec(db, "COMMIT", nil, nil, nil)
                        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
                        let fraction = 0.02 + 0.63 * Double(fileIndex) / Double(totalFiles)
                            + 0.63 / Double(totalFiles)
                            * Double(insertedCount) / Double(max(1, insertedCount + 1_000_000))
                        progress?(fraction, "\(fileProgress)Inserting hits \(insertedCount)...")
                    }
                }

                // Synchronous chunk-based line reader — no async buffer accumulation
                while true {
                    let chunk = readHandle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }

                    partial.append(chunk)

                    guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else {
                        continue
                    }

                    let completeRange = partial[partial.startIndex...lastNewline]
                    guard let text = String(data: Data(completeRange), encoding: .utf8) else {
                        continue
                    }

                    // Split into lines and process as Substrings (zero-copy).
                    // The processLine closure trims \r internally so we skip
                    // the expensive .replacingOccurrences("\r\n", "\n") allocation.
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        try processLine(line)
                    }

                    let afterNewline = partial.index(after: lastNewline)
                    if afterNewline < partial.endIndex {
                        partial = Data(partial[afterNewline...])
                    } else {
                        partial = Data()
                    }
                }

                // Process remaining partial line
                if !partial.isEmpty, let text = String(data: partial, encoding: .utf8) {
                    let sub = text[text.startIndex...]
                    if !sub.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
                        try processLine(sub)
                    }
                }
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.insertFailed("Commit failed: \(msg)")
            }
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            try populateSampleHitCounts(db: db)

            progress?(0.70, "Building indices...")
            try createIndices(db: db)

            progress?(0.80, "Writing taxon summaries...")
            try bulkInsertTaxonSummaries(db: db, accumulators: accumulators)

            progress?(0.90, "Writing accession summaries...")
            try bulkInsertAccessionSummaries(db: db, accumulators: accumulators)

            progress?(0.93, "Storing reference lengths...")
            try bulkInsertReferenceLengths(db: db, accumulators: accumulators)

            progress?(0.95, "Finalizing...")

            // Get distinct taxon count (not sample×taxon pairs) for user-facing display
            var taxonCount = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT tax_id) FROM taxon_summaries", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    taxonCount = Int(sqlite3_column_int64(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }

            sqlite3_close(db)
            logger.info("Created NAO-MGS database (streaming) with \(insertedCount) hits at \(url.lastPathComponent)")

            progress?(1.0, "Complete")

            let resolvedSampleName = sampleNameOverride
                ?? firstSampleName
                ?? tsvURLs[0].deletingPathExtension().lastPathComponent

            return StreamingImportResult(
                hitCount: insertedCount,
                sampleName: resolvedSampleName,
                taxonCount: taxonCount,
                virusHitsFile: tsvURLs[0]
            )
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Bulk-inserts taxon summaries from streaming accumulators.
    private static func bulkInsertTaxonSummaries(
        db: OpaquePointer,
        accumulators: [String: [Int: TaxonAccumulator]]
    ) throws {
        let sql = """
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count,
            avg_identity, avg_bit_score, avg_edit_distance,
            pcr_duplicate_count, accession_count, top_accessions_json
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Taxon summary prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for (sample, taxonMap) in accumulators {
            for (taxId, acc) in taxonMap {
                let uniqueReads = acc.alignmentSignatures.count
                let avgIdentity = acc.hitCount > 0 ? acc.identitySum / Double(acc.hitCount) : 0
                let avgBitScore = acc.hitCount > 0 ? acc.bitScoreSum / Double(acc.hitCount) : 0
                let avgEditDist = acc.hitCount > 0 ? Double(acc.editDistanceSum) / Double(acc.hitCount) : 0
                let pcrDups = acc.hitCount - uniqueReads

                // Top 5 accessions by unique read count
                let topAccessions = acc.accessionSignatures
                    .map { (accession: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }
                    .prefix(5)
                    .map { $0.accession }
                let topJSON: String
                if let data = try? JSONSerialization.data(withJSONObject: Array(topAccessions)),
                   let str = String(data: data, encoding: .utf8) {
                    topJSON = str
                } else {
                    topJSON = "[]"
                }

                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                naoBindText(stmt, 1, sample)
                sqlite3_bind_int64(stmt, 2, Int64(taxId))
                naoBindText(stmt, 3, acc.name)
                sqlite3_bind_int64(stmt, 4, Int64(acc.hitCount))
                sqlite3_bind_int64(stmt, 5, Int64(uniqueReads))
                sqlite3_bind_double(stmt, 6, avgIdentity)
                sqlite3_bind_double(stmt, 7, avgBitScore)
                sqlite3_bind_double(stmt, 8, avgEditDist)
                sqlite3_bind_int64(stmt, 9, Int64(pcrDups))
                sqlite3_bind_int64(stmt, 10, Int64(acc.accessions.count))
                naoBindText(stmt, 11, topJSON)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    throw NaoMgsDatabaseError.createFailed("Taxon summary insert failed: \(msg)")
                }
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Bulk-inserts accession summaries from streaming accumulators.
    private static func bulkInsertAccessionSummaries(
        db: OpaquePointer,
        accumulators: [String: [Int: TaxonAccumulator]]
    ) throws {
        let sql = """
        INSERT INTO accession_summaries (
            sample, tax_id, accession, read_count, unique_read_count,
            reference_length, covered_base_pairs, coverage_fraction
        ) VALUES (?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Accession summary prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for (sample, taxonMap) in accumulators {
            for (taxId, acc) in taxonMap {
                for accession in acc.accessions {
                    let totalReads = acc.accessionReadCounts[accession] ?? 0
                    let uniqueReads = acc.accessionSignatures[accession]?.count ?? 0
                    let maxExtent = acc.accessionMaxExtent[accession] ?? 0
                    let intervals = acc.accessionIntervals[accession] ?? []
                    let coveredBP = computeCoveredBasePairs(intervals)
                    let coverageFraction = maxExtent > 0
                        ? min(1.0, Double(coveredBP) / Double(maxExtent))
                        : 0.0

                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    naoBindText(stmt, 1, sample)
                    sqlite3_bind_int64(stmt, 2, Int64(taxId))
                    naoBindText(stmt, 3, accession)
                    sqlite3_bind_int64(stmt, 4, Int64(totalReads))
                    sqlite3_bind_int64(stmt, 5, Int64(uniqueReads))
                    sqlite3_bind_int64(stmt, 6, Int64(maxExtent))
                    sqlite3_bind_int64(stmt, 7, Int64(coveredBP))
                    sqlite3_bind_double(stmt, 8, coverageFraction)

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        let msg = String(cString: sqlite3_errmsg(db))
                        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                        throw NaoMgsDatabaseError.createFailed("Accession summary insert failed: \(msg)")
                    }
                }
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Stores alignment-derived reference lengths as fallback values.
    ///
    /// Uses the maximum alignment extent (ref_start + query_length) seen for
    /// each accession across all samples and taxa. These serve as fallback
    /// `@SQ LN:` values in generated BAMs when actual reference FASTAs
    /// are not available.
    ///
    /// Uses `INSERT OR IGNORE` so that actual reference lengths (from
    /// downloaded FASTAs) are never overwritten by alignment extents.
    private static func bulkInsertReferenceLengths(
        db: OpaquePointer,
        accumulators: [String: [Int: TaxonAccumulator]]
    ) throws {
        // Merge max extents across all (sample, taxId) pairs for each accession
        var globalExtents: [String: Int] = [:]
        for (_, taxonMap) in accumulators {
            for (_, acc) in taxonMap {
                for (accession, extent) in acc.accessionMaxExtent {
                    globalExtents[accession] = max(globalExtents[accession] ?? 0, extent)
                }
            }
        }

        guard !globalExtents.isEmpty else { return }

        let sql = "INSERT OR IGNORE INTO reference_lengths (accession, length) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Reference length insert prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for (accession, extent) in globalExtents {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, accession)
            sqlite3_bind_int64(stmt, 2, Int64(extent))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        logger.info("Stored \(globalExtents.count) fallback reference lengths from alignment extents")
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER,
            cigar TEXT,
            read_sequence TEXT,
            read_quality TEXT,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER,
            query_length INTEGER,
            is_reverse_complement INTEGER,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL,
            ref_start_rev INTEGER,
            read_sequence_rev TEXT,
            read_quality_rev TEXT,
            edit_distance_rev INTEGER,
            query_length_rev INTEGER,
            is_reverse_complement_rev INTEGER,
            best_alignment_score_rev REAL
        );

        CREATE TABLE taxon_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            hit_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            avg_identity REAL NOT NULL,
            avg_bit_score REAL NOT NULL,
            avg_edit_distance REAL NOT NULL,
            pcr_duplicate_count INTEGER NOT NULL,
            accession_count INTEGER NOT NULL,
            top_accessions_json TEXT NOT NULL,
            bam_path TEXT,
            bam_index_path TEXT,
            PRIMARY KEY (sample, tax_id)
        );

        CREATE TABLE reference_lengths (
            accession TEXT PRIMARY KEY,
            length INTEGER NOT NULL
        );

        CREATE TABLE accession_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            accession TEXT NOT NULL,
            read_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            reference_length INTEGER NOT NULL,
            covered_base_pairs INTEGER NOT NULL,
            coverage_fraction REAL NOT NULL,
            PRIMARY KEY (sample, tax_id, accession)
        );

        CREATE TABLE sample_hit_counts (
            sample TEXT PRIMARY KEY,
            hit_count INTEGER NOT NULL
        );

        CREATE TABLE taxon_read_names (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            seq_id TEXT NOT NULL,
            PRIMARY KEY (sample, tax_id, seq_id)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Sample Name Normalization

    /// Strips Illumina sequencing metadata (`_S{index}_L{lane}`) from sample names.
    ///
    /// NAO-MGS sample names include Illumina lane/index suffixes like `_S2_L001`.
    /// Stripping these produces the biological sample identity, allowing reads from
    /// multiple lanes/indices to aggregate under one logical sample.
    public static func normalizeImportedSampleName(_ raw: String) -> String {
        if let range = raw.range(of: #"_S\d+_L\d+.*$"#, options: .regularExpression) {
            return String(raw[..<range.lowerBound])
        }
        return raw
    }

    /// Merges staged summary databases into a freshly created summary-only database.
    private static func mergeStageSummaries(
        into mergedDB: OpaquePointer,
        from stageInputs: [NaoMgsStageDatabaseInput]
    ) throws {
        let insertTaxonSQL = """
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count,
            avg_identity, avg_bit_score, avg_edit_distance,
            pcr_duplicate_count, accession_count, top_accessions_json,
            bam_path, bam_index_path
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let insertAccessionSQL = """
        INSERT INTO accession_summaries (
            sample, tax_id, accession, read_count, unique_read_count,
            reference_length, covered_base_pairs, coverage_fraction
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        let insertReadNameSQL = """
        INSERT OR IGNORE INTO taxon_read_names (
            sample, tax_id, seq_id
        ) VALUES (?, ?, ?)
        """
        let insertSampleHitCountSQL = """
        INSERT INTO sample_hit_counts (
            sample, hit_count
        ) VALUES (?, ?)
        """
        let mergeReferenceLengthSQL = """
        INSERT INTO reference_lengths (accession, length)
        VALUES (?, ?)
        ON CONFLICT(accession) DO UPDATE
        SET length = MAX(reference_lengths.length, excluded.length)
        """

        var insertTaxonStmt: OpaquePointer?
        var insertAccessionStmt: OpaquePointer?
        var insertReadNameStmt: OpaquePointer?
        var insertSampleHitCountStmt: OpaquePointer?
        var mergeReferenceLengthStmt: OpaquePointer?

        guard sqlite3_prepare_v2(mergedDB, insertTaxonSQL, -1, &insertTaxonStmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.createFailed("Merged taxon insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, insertAccessionSQL, -1, &insertAccessionStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            throw NaoMgsDatabaseError.createFailed("Merged accession insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, insertReadNameSQL, -1, &insertReadNameStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            throw NaoMgsDatabaseError.createFailed("Merged read-name insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, insertSampleHitCountSQL, -1, &insertSampleHitCountStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            sqlite3_finalize(insertReadNameStmt)
            throw NaoMgsDatabaseError.createFailed("Merged sample-hit insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, mergeReferenceLengthSQL, -1, &mergeReferenceLengthStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            sqlite3_finalize(insertReadNameStmt)
            sqlite3_finalize(insertSampleHitCountStmt)
            throw NaoMgsDatabaseError.createFailed("Merged reference length insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        defer {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            sqlite3_finalize(insertReadNameStmt)
            sqlite3_finalize(insertSampleHitCountStmt)
            sqlite3_finalize(mergeReferenceLengthStmt)
        }

        guard sqlite3_exec(mergedDB, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.createFailed("Failed to start merged summary transaction: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }

        do {
            for stageInput in stageInputs {
                let taxonCount = try appendStageTaxonSummaries(from: stageInput, into: mergedDB, insertStmt: insertTaxonStmt)
                let accessionCount = try appendStageAccessionSummaries(from: stageInput, into: mergedDB, insertStmt: insertAccessionStmt)
                try appendStageTaxonReadNames(from: stageInput, into: mergedDB, insertStmt: insertReadNameStmt)
                try appendStageSampleHitCounts(from: stageInput, into: mergedDB, insertStmt: insertSampleHitCountStmt)
                try mergeStageReferenceLengths(from: stageInput, into: mergedDB, insertStmt: mergeReferenceLengthStmt)

                guard taxonCount > 0 else {
                    throw NaoMgsDatabaseError.createFailed("Staged database \(stageInput.databaseURL.lastPathComponent) contributed no taxon summaries for sample \(stageInput.sample)")
                }
                guard accessionCount > 0 else {
                    throw NaoMgsDatabaseError.createFailed("Staged database \(stageInput.databaseURL.lastPathComponent) contributed no accession summaries for sample \(stageInput.sample)")
                }
            }
            try refreshAccessionSummaryReferenceLengths(db: mergedDB)

            guard sqlite3_exec(mergedDB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Failed to commit merged summary transaction: \(String(cString: sqlite3_errmsg(mergedDB)))")
            }
        } catch {
            sqlite3_exec(mergedDB, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func appendStageTaxonSummaries(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws -> Int {
        let selectSQL = """
        SELECT tax_id, name, hit_count, unique_read_count,
               avg_identity, avg_bit_score, avg_edit_distance,
               pcr_duplicate_count, accession_count, top_accessions_json
        FROM taxon_summaries
        WHERE sample = ?
        """
        return try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage taxon select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            var insertedCount = 0
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)

                naoBindText(insertStmt, 1, stageInput.sample)
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))
                naoBindText(insertStmt, 3, String(cString: sqlite3_column_text(selectStmt, 1)))
                sqlite3_bind_int64(insertStmt, 4, sqlite3_column_int64(selectStmt, 2))
                sqlite3_bind_int64(insertStmt, 5, sqlite3_column_int64(selectStmt, 3))
                sqlite3_bind_double(insertStmt, 6, sqlite3_column_double(selectStmt, 4))
                sqlite3_bind_double(insertStmt, 7, sqlite3_column_double(selectStmt, 5))
                sqlite3_bind_double(insertStmt, 8, sqlite3_column_double(selectStmt, 6))
                sqlite3_bind_int64(insertStmt, 9, sqlite3_column_int64(selectStmt, 7))
                sqlite3_bind_int64(insertStmt, 10, sqlite3_column_int64(selectStmt, 8))
                naoBindText(insertStmt, 11, String(cString: sqlite3_column_text(selectStmt, 9)))
                naoBindText(insertStmt, 12, stageInput.bamRelativePath)
                if let bamIndexRelativePath = stageInput.bamIndexRelativePath {
                    naoBindText(insertStmt, 13, bamIndexRelativePath)
                } else {
                    sqlite3_bind_null(insertStmt, 13)
                }

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged taxon insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
                insertedCount += 1
            }
            return insertedCount
        }
    }

    private static func appendStageAccessionSummaries(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws -> Int {
        let selectSQL = """
        SELECT tax_id, accession, read_count, unique_read_count,
               reference_length, covered_base_pairs, coverage_fraction
        FROM accession_summaries
        WHERE sample = ?
        """
        return try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage accession select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            var insertedCount = 0
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)

                naoBindText(insertStmt, 1, stageInput.sample)
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))
                naoBindText(insertStmt, 3, String(cString: sqlite3_column_text(selectStmt, 1)))
                sqlite3_bind_int64(insertStmt, 4, sqlite3_column_int64(selectStmt, 2))
                sqlite3_bind_int64(insertStmt, 5, sqlite3_column_int64(selectStmt, 3))
                sqlite3_bind_int64(insertStmt, 6, sqlite3_column_int64(selectStmt, 4))
                sqlite3_bind_int64(insertStmt, 7, sqlite3_column_int64(selectStmt, 5))
                sqlite3_bind_double(insertStmt, 8, sqlite3_column_double(selectStmt, 6))

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged accession insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
                insertedCount += 1
            }
            return insertedCount
        }
    }

    private static func mergeStageReferenceLengths(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws {
        let selectSQL = "SELECT accession, length FROM reference_lengths"
        try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage reference length select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)

                naoBindText(insertStmt, 1, String(cString: sqlite3_column_text(selectStmt, 0)))
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 1))

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged reference length insert failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
            }
        }
    }

    private static func appendStageTaxonReadNames(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws {
        let selectSQL = """
        SELECT tax_id, seq_id
        FROM taxon_read_names
        WHERE sample = ?
        """
        try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage read-name select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)
                naoBindText(insertStmt, 1, stageInput.sample)
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))
                naoBindText(insertStmt, 3, String(cString: sqlite3_column_text(selectStmt, 1)))

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged read-name insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
            }
        }
    }

    private static func appendStageSampleHitCounts(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws {
        let selectSQL = """
        SELECT hit_count
        FROM sample_hit_counts
        WHERE sample = ?
        """
        try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage sample-hit select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            guard sqlite3_step(selectStmt) == SQLITE_ROW else {
                throw NaoMgsDatabaseError.createFailed("Staged database \(stageInput.databaseURL.lastPathComponent) contributed no sample hit count for sample \(stageInput.sample)")
            }

            sqlite3_reset(insertStmt)
            sqlite3_clear_bindings(insertStmt)
            naoBindText(insertStmt, 1, stageInput.sample)
            sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))

            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw NaoMgsDatabaseError.createFailed("Merged sample-hit insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
            }
        }
    }

    private static func withReadOnlySQLiteDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw NaoMgsDatabaseError.openFailed("Failed to open staged database \(url.lastPathComponent): \(msg)")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    // MARK: - Bulk Insert

    private static func bulkInsertHits(
        db: OpaquePointer,
        hits: [NaoMgsVirusHit],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        guard !hits.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO virus_hits (
            sample, seq_id, tax_id, subject_seq_id, subject_title,
            ref_start, cigar, read_sequence, read_quality,
            percent_identity, bit_score, e_value, edit_distance,
            query_length, is_reverse_complement, pair_status,
            fragment_length, best_alignment_score, ref_start_rev,
            read_sequence_rev, read_quality_rev, edit_distance_rev,
            query_length_rev, is_reverse_complement_rev, best_alignment_score_rev
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw NaoMgsDatabaseError.insertFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let total = hits.count
        let reportInterval = max(1, total / 20) // ~5% increments

        for (i, hit) in hits.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            naoBindText(stmt, 1, normalizeImportedSampleName(hit.sample))
            naoBindText(stmt, 2, hit.seqId)
            sqlite3_bind_int64(stmt, 3, Int64(hit.taxId))
            naoBindText(stmt, 4, hit.subjectSeqId)
            naoBindText(stmt, 5, hit.subjectTitle)
            sqlite3_bind_int64(stmt, 6, Int64(hit.refStart))
            naoBindText(stmt, 7, hit.cigar)
            naoBindText(stmt, 8, hit.readSequence)
            naoBindText(stmt, 9, hit.readQuality)
            sqlite3_bind_double(stmt, 10, hit.percentIdentity)
            sqlite3_bind_double(stmt, 11, hit.bitScore)
            sqlite3_bind_double(stmt, 12, hit.eValue)
            sqlite3_bind_int(stmt, 13, Int32(hit.editDistance))
            sqlite3_bind_int(stmt, 14, Int32(hit.queryLength))
            sqlite3_bind_int(stmt, 15, hit.isReverseComplement ? 1 : 0)
            naoBindText(stmt, 16, hit.pairStatus)
            sqlite3_bind_int(stmt, 17, Int32(hit.fragmentLength))
            sqlite3_bind_double(stmt, 18, hit.bestAlignmentScore)
            sqlite3_bind_null(stmt, 19)
            sqlite3_bind_null(stmt, 20)
            sqlite3_bind_null(stmt, 21)
            sqlite3_bind_null(stmt, 22)
            sqlite3_bind_null(stmt, 23)
            sqlite3_bind_null(stmt, 24)
            sqlite3_bind_null(stmt, 25)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw NaoMgsDatabaseError.insertFailed("Row \(i) failed: \(msg)")
            }

            if (i + 1) % reportInterval == 0 {
                let fraction = 0.05 + 0.65 * Double(i + 1) / Double(total)
                progress?(fraction, "Inserting hits \(i + 1)/\(total)...")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.insertFailed("Commit failed: \(msg)")
        }
    }

    // MARK: - Indices

    private static func createIndices(db: OpaquePointer) throws {
        let indices = [
            // virus_hits: only idx_hits_sample needed (BAM materializer queries by sample)
            "CREATE INDEX idx_hits_sample ON virus_hits(sample)",
            "CREATE INDEX idx_taxon_read_names_sample_taxid ON taxon_read_names(sample, tax_id)",
            "CREATE INDEX idx_sample_hit_counts_hitcount ON sample_hit_counts(hit_count DESC)",
            // taxon_summaries indices
            "CREATE INDEX idx_summaries_sample ON taxon_summaries(sample)",
            "CREATE INDEX idx_summaries_hitcount ON taxon_summaries(sample, hit_count DESC)",
            // tax_id alone: used by UPDATE taxon_summaries SET name = ? WHERE tax_id = ?
            // during name resolution.
            "CREATE INDEX idx_summaries_taxid ON taxon_summaries(tax_id)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.createFailed("Index creation failed: \(msg)")
            }
        }
    }

    private static func populateTaxonReadNames(db: OpaquePointer?) throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = """
        INSERT OR IGNORE INTO taxon_read_names (sample, tax_id, seq_id)
        SELECT DISTINCT sample, tax_id, seq_id
        FROM virus_hits
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Taxon read-name population failed: \(msg)")
        }
    }

    private static func populateSampleHitCounts(db: OpaquePointer?) throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        guard sqlite3_exec(db, "DELETE FROM sample_hit_counts", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Sample hit-count reset failed: \(msg)")
        }

        let sourceSQL = [
            "INSERT INTO sample_hit_counts (sample, hit_count) SELECT sample, COUNT(*) FROM virus_hits GROUP BY sample",
            "INSERT INTO sample_hit_counts (sample, hit_count) SELECT sample, COUNT(*) FROM taxon_read_names GROUP BY sample",
            "INSERT INTO sample_hit_counts (sample, hit_count) SELECT sample, SUM(hit_count) FROM taxon_summaries GROUP BY sample",
        ]

        for sql in sourceSQL {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                continue
            }

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sample_hit_counts", -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) > 0 {
                    return
                }
            }
        }
    }

    // MARK: - Taxon Summary Computation

    private static func computeTaxonSummaries(db: OpaquePointer) throws {
        // Step 1: Insert basic aggregates with placeholder unique_read_count=0
        let insertAgg = """
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count,
            avg_identity, avg_bit_score, avg_edit_distance,
            pcr_duplicate_count, accession_count, top_accessions_json,
            bam_path, bam_index_path
        )
        SELECT
            sample,
            tax_id,
            MIN(subject_title),
            COUNT(*),
            0,
            AVG(percent_identity),
            AVG(bit_score),
            AVG(edit_distance),
            0,
            COUNT(DISTINCT subject_seq_id),
            '[]',
            NULL,
            NULL
        FROM virus_hits
        GROUP BY sample, tax_id
        """
        guard sqlite3_exec(db, insertAgg, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Summary aggregation failed: \(msg)")
        }

        // Step 2: Update unique_read_count via distinct alignment signatures
        let updateUnique = """
        UPDATE taxon_summaries SET unique_read_count = (
            SELECT COUNT(*) FROM (
                SELECT DISTINCT subject_seq_id, ref_start, is_reverse_complement, query_length,
                       IFNULL(ref_start_rev, -1), IFNULL(is_reverse_complement_rev, -1), IFNULL(query_length_rev, -1)
                FROM virus_hits
                WHERE virus_hits.sample = taxon_summaries.sample
                  AND virus_hits.tax_id = taxon_summaries.tax_id
            )
        )
        """
        guard sqlite3_exec(db, updateUnique, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Unique read count update failed: \(msg)")
        }

        // Step 3: pcr_duplicate_count = hit_count - unique_read_count
        let updateDups = """
        UPDATE taxon_summaries SET pcr_duplicate_count = hit_count - unique_read_count
        """
        guard sqlite3_exec(db, updateDups, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("PCR duplicate count update failed: \(msg)")
        }

        // Step 4: Compute top 5 accessions per (sample, tax_id)
        try computeTopAccessions(db: db)
    }

    private static func computeTopAccessions(db: OpaquePointer) throws {
        // Query all (sample, tax_id) pairs
        let pairSQL = "SELECT sample, tax_id FROM taxon_summaries"
        var pairStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, pairSQL, -1, &pairStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accessions pair query failed: \(msg)")
        }
        defer { sqlite3_finalize(pairStmt) }

        var pairs: [(sample: String, taxId: Int)] = []
        while sqlite3_step(pairStmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(pairStmt, 0))
            let taxId = Int(sqlite3_column_int64(pairStmt, 1))
            pairs.append((sample, taxId))
        }

        // For each pair, compute top 5 accessions by unique read count
        let topSQL = """
        SELECT subject_seq_id,
               COUNT(DISTINCT
                    CAST(ref_start AS TEXT) || '|' ||
                    CAST(is_reverse_complement AS TEXT) || '|' ||
                    CAST(query_length AS TEXT) || '|' ||
                    IFNULL(CAST(ref_start_rev AS TEXT), '') || '|' ||
                    IFNULL(CAST(is_reverse_complement_rev AS TEXT), '') || '|' ||
                    IFNULL(CAST(query_length_rev AS TEXT), '')
               ) as ucount
        FROM virus_hits
        WHERE sample = ? AND tax_id = ?
        GROUP BY subject_seq_id
        ORDER BY ucount DESC
        LIMIT 5
        """
        var topStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, topSQL, -1, &topStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accessions query failed: \(msg)")
        }
        defer { sqlite3_finalize(topStmt) }

        let updateSQL = "UPDATE taxon_summaries SET top_accessions_json = ? WHERE sample = ? AND tax_id = ?"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accessions update prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(updateStmt) }

        for pair in pairs {
            sqlite3_reset(topStmt)
            sqlite3_clear_bindings(topStmt)
            naoBindText(topStmt, 1, pair.sample)
            sqlite3_bind_int64(topStmt, 2, Int64(pair.taxId))

            var accessions: [String] = []
            while sqlite3_step(topStmt) == SQLITE_ROW {
                let acc = String(cString: sqlite3_column_text(topStmt, 0))
                accessions.append(acc)
            }

            // Encode as JSON array
            let jsonData = try JSONSerialization.data(withJSONObject: accessions)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            naoBindText(updateStmt, 1, jsonString)
            naoBindText(updateStmt, 2, pair.sample)
            sqlite3_bind_int64(updateStmt, 3, Int64(pair.taxId))

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.createFailed("Top accessions update failed: \(msg)")
            }
        }
    }

    // MARK: - Accession Summary Pre-Computation

    /// Returns the set of columns present in the given table.
    private static func columnNames(in table: String, db: OpaquePointer) -> Set<String> {
        var names = Set<String>()
        var stmt: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK else {
            return names
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: namePtr))
            }
        }
        return names
    }

    /// Pre-computes per-accession statistics (read count, unique reads, coverage)
    /// and stores them in the `accession_summaries` table. This replaces the
    /// expensive N+1 pileup queries that previously ran at display time.
    private static func computeAccessionSummaries(db: OpaquePointer) throws {
        let virusHitColumns = columnNames(in: "virus_hits", db: db)
        let hasRefStartRev = virusHitColumns.contains("ref_start_rev")
        let hasQueryLengthRev = virusHitColumns.contains("query_length_rev")
        let hasIsReverseComplementRev = virusHitColumns.contains("is_reverse_complement_rev")

        let refStartRevExpr = hasRefStartRev ? "IFNULL(ref_start_rev, -1)" : "-1"
        let queryLengthRevExpr = hasQueryLengthRev ? "IFNULL(query_length_rev, -1)" : "-1"
        let isReverseComplementRevExpr = hasIsReverseComplementRev ? "IFNULL(is_reverse_complement_rev, -1)" : "-1"
        let maxRefEndExpr: String
        if hasRefStartRev && hasQueryLengthRev {
            maxRefEndExpr = "IFNULL(vh.ref_start_rev + IFNULL(vh.query_length_rev, 0), 0)"
        } else {
            maxRefEndExpr = "0"
        }

        // Step 1: Insert read_count, unique_read_count, and reference_length per (sample, tax_id, accession)
        let insertSQL = """
        INSERT INTO accession_summaries (
            sample, tax_id, accession, read_count, unique_read_count,
            reference_length, covered_base_pairs, coverage_fraction
        )
        SELECT
            vh.sample,
            vh.tax_id,
            vh.subject_seq_id,
            COUNT(*) as read_count,
            (SELECT COUNT(*) FROM (
                SELECT DISTINCT ref_start, is_reverse_complement, query_length,
                       \(refStartRevExpr), \(isReverseComplementRevExpr), \(queryLengthRevExpr)
                FROM virus_hits v2
                WHERE v2.sample = vh.sample AND v2.tax_id = vh.tax_id AND v2.subject_seq_id = vh.subject_seq_id
            )) as unique_read_count,
            COALESCE(
                (SELECT length FROM reference_lengths WHERE accession = vh.subject_seq_id),
                MAX(MAX(
                    vh.ref_start + vh.query_length,
                    \(maxRefEndExpr)
                ))
            ) as reference_length,
            0,
            0.0
        FROM virus_hits vh
        GROUP BY vh.sample, vh.tax_id, vh.subject_seq_id
        """
        guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Accession summary insert failed: \(msg)")
        }

        // Step 2: Compute pileup coverage for each accession via interval merging.
        // We iterate all (sample, tax_id, accession) groups and compute covered base pairs.
        let groupSQL = "SELECT sample, tax_id, accession, reference_length FROM accession_summaries"
        var groupStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, groupSQL, -1, &groupStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Accession summary group query failed: \(msg)")
        }
        defer { sqlite3_finalize(groupStmt) }

        var groups: [(sample: String, taxId: Int, accession: String, refLength: Int)] = []
        while sqlite3_step(groupStmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(groupStmt, 0))
            let taxId = Int(sqlite3_column_int64(groupStmt, 1))
            let accession = String(cString: sqlite3_column_text(groupStmt, 2))
            let refLength = Int(sqlite3_column_int64(groupStmt, 3))
            groups.append((sample, taxId, accession, refLength))
        }

        let pileupSQL = """
        SELECT ref_start, query_length, ref_start_rev, query_length_rev
        FROM virus_hits
        WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?
        """
        let legacyPileupSQL = """
        SELECT ref_start, query_length
        FROM virus_hits
        WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?
        """
        let updateSQL = "UPDATE accession_summaries SET covered_base_pairs = ?, coverage_fraction = ? WHERE sample = ? AND tax_id = ? AND accession = ?"

        var pileupStmt: OpaquePointer?
        let pileupSQLToUse = (hasRefStartRev && hasQueryLengthRev) ? pileupSQL : legacyPileupSQL
        guard sqlite3_prepare_v2(db, pileupSQLToUse, -1, &pileupStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Pileup query prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(pileupStmt) }

        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Coverage update prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(updateStmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for group in groups {
            sqlite3_reset(pileupStmt)
            sqlite3_clear_bindings(pileupStmt)
            naoBindText(pileupStmt, 1, group.sample)
            sqlite3_bind_int64(pileupStmt, 2, Int64(group.taxId))
            naoBindText(pileupStmt, 3, group.accession)

            var intervals: [(start: Int, end: Int)] = []
            while sqlite3_step(pileupStmt) == SQLITE_ROW {
                let refStart = Int(sqlite3_column_int64(pileupStmt, 0))
                let queryLen = Int(sqlite3_column_int64(pileupStmt, 1))
                intervals.append((start: refStart, end: refStart + queryLen))
                if hasRefStartRev && hasQueryLengthRev && sqlite3_column_type(pileupStmt, 2) != SQLITE_NULL {
                    let refStartRev = Int(sqlite3_column_int64(pileupStmt, 2))
                    let queryLenRev = sqlite3_column_type(pileupStmt, 3) == SQLITE_NULL
                        ? 0
                        : Int(sqlite3_column_int64(pileupStmt, 3))
                    if queryLenRev > 0 {
                        intervals.append((start: refStartRev, end: refStartRev + queryLenRev))
                    }
                }
            }

            let coveredBP = computeCoveredBasePairs(intervals)
            let coverageFraction = group.refLength > 0
                ? min(1.0, Double(coveredBP) / Double(group.refLength))
                : 0.0

            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            sqlite3_bind_int64(updateStmt, 1, Int64(coveredBP))
            sqlite3_bind_double(updateStmt, 2, coverageFraction)
            naoBindText(updateStmt, 3, group.sample)
            sqlite3_bind_int64(updateStmt, 4, Int64(group.taxId))
            naoBindText(updateStmt, 5, group.accession)
            sqlite3_step(updateStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Taxon Name Updates

    /// Returns the distinct taxon IDs that have empty or placeholder names.
    ///
    /// - Returns: Array of taxon ID integers needing name resolution.
    public func taxonIdsNeedingNames() throws -> [Int] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT DISTINCT tax_id FROM taxon_summaries WHERE name = '' OR name LIKE 'Taxon %'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var ids: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int64(stmt, 0)))
        }
        return ids
    }

    /// Updates taxon names in the summary table. Database must be open read-write.
    ///
    /// - Parameter names: Dictionary mapping taxon ID to resolved scientific name.
    public func updateTaxonNames(_ names: [Int: String]) throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }
        guard !names.isEmpty else { return }

        let sql = "UPDATE taxon_summaries SET name = ? WHERE tax_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Prepare taxon name update failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (taxId, name) in names {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, name)
            sqlite3_bind_int64(stmt, 2, Int64(taxId))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                logger.warning("Failed to update name for taxId \(taxId): \(msg, privacy: .public)")
                continue
            }
        }
    }

    // MARK: - Reference Length Updates

    /// Stores reference sequence lengths. Database must be open read-write.
    ///
    /// - Parameter lengths: Dictionary mapping accession string to sequence length in bases.
    public func updateReferenceLengths(_ lengths: [String: Int]) throws {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }
        let sql = "INSERT OR REPLACE INTO reference_lengths (accession, length) VALUES (?, ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for (accession, length) in lengths {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, accession)
            sqlite3_bind_int64(stmt, 2, Int64(length))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Returns the reference length for an accession, or nil if unknown.
    public func referenceLength(forAccession accession: String) throws -> Int? {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT length FROM reference_lengths WHERE accession = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        naoBindText(stmt, 1, accession)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return nil
    }

    /// Updates `accession_summaries.reference_length` and `coverage_fraction`
    /// from the `reference_lengths` table. Call after storing FASTA-derived
    /// reference lengths so the accession display uses real genome lengths
    /// instead of alignment extents.
    public func refreshAccessionSummaryReferenceLengths() throws {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }
        try Self.refreshAccessionSummaryReferenceLengths(db: db)
    }

    private static func refreshAccessionSummaryReferenceLengths(db: OpaquePointer) throws {
        let sql = """
        UPDATE accession_summaries
        SET reference_length = (
                SELECT rl.length FROM reference_lengths rl
                WHERE rl.accession = accession_summaries.accession
            ),
            coverage_fraction = CASE
                WHEN (SELECT rl.length FROM reference_lengths rl
                      WHERE rl.accession = accession_summaries.accession) > 0
                THEN MIN(1.0, CAST(covered_base_pairs AS REAL)
                     / (SELECT rl.length FROM reference_lengths rl
                        WHERE rl.accession = accession_summaries.accession))
                ELSE coverage_fraction
            END
        WHERE accession IN (SELECT accession FROM reference_lengths)
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Failed to refresh accession summary reference lengths: \(msg)")
        }
    }

    // MARK: - Read-Write Access

    /// Opens an existing NAO-MGS database for reading and writing.
    ///
    /// Used during import to update taxon names after creation.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``NaoMgsDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public static func openReadWrite(at url: URL) throws -> NaoMgsDatabase {
        let instance = NaoMgsDatabase(url: url)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &instance.db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = instance.db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(instance.db)
            instance.db = nil
            throw NaoMgsDatabaseError.openFailed(msg)
        }
        // Schema migrations
        sqlite3_exec(instance.db, "CREATE TABLE IF NOT EXISTS reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL)", nil, nil, nil)
        sqlite3_exec(instance.db, "ALTER TABLE taxon_summaries ADD COLUMN bam_path TEXT", nil, nil, nil)
        sqlite3_exec(instance.db, "ALTER TABLE taxon_summaries ADD COLUMN bam_index_path TEXT", nil, nil, nil)
        sqlite3_exec(instance.db, """
        CREATE TABLE IF NOT EXISTS accession_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            accession TEXT NOT NULL,
            read_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            reference_length INTEGER NOT NULL,
            covered_base_pairs INTEGER NOT NULL,
            coverage_fraction REAL NOT NULL,
            PRIMARY KEY (sample, tax_id, accession)
        )
        """, nil, nil, nil)
        sqlite3_exec(instance.db, """
        CREATE TABLE IF NOT EXISTS taxon_read_names (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            seq_id TEXT NOT NULL,
            PRIMARY KEY (sample, tax_id, seq_id)
        )
        """, nil, nil, nil)
        return instance
    }

    /// Private initializer used by `openReadWrite(at:)`.
    private init(url: URL) {
        self.url = url
    }

    // MARK: - Queries

    /// Returns the total number of virus hits, optionally filtered by sample names.
    ///
    /// Uses `sample_hit_counts` so totals remain raw row counts even when taxon
    /// summaries store alignment counts for paired-end inputs, and still work after
    /// `virus_hits` rows have been purged.
    ///
    /// - Parameter samples: If non-nil, only count hits from these samples.
    /// - Returns: Total hit count.
    public func totalHitCount(samples: [String]? = nil) throws -> Int {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql: String
        if let samples, !samples.isEmpty {
            let placeholders = samples.map { _ in "?" }.joined(separator: ",")
            sql = "SELECT COALESCE(SUM(hit_count), 0) FROM sample_hit_counts WHERE sample IN (\(placeholders))"
        } else {
            sql = "SELECT COALESCE(SUM(hit_count), 0) FROM sample_hit_counts"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        if let samples, !samples.isEmpty {
            for (i, sample) in samples.enumerated() {
                naoBindText(stmt, Int32(i + 1), sample)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NaoMgsDatabaseError.queryFailed("SUM query returned no rows")
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Sample Queries

    /// Returns all distinct samples with their hit counts.
    ///
    /// Uses `sample_hit_counts` so per-sample counts stay raw row-based even when
    /// taxon summaries are alignment-based, and still work after `virus_hits`
    /// rows have been purged.
    ///
    /// - Returns: Array of (sample, hitCount) tuples ordered by sample name.
    public func fetchSamples() throws -> [(sample: String, hitCount: Int)] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT sample, hit_count FROM sample_hit_counts ORDER BY sample"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(sample: String, hitCount: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let hitCount = Int(sqlite3_column_int64(stmt, 1))
            results.append((sample, hitCount))
        }
        return results
    }

    // MARK: - Taxon Summary Queries

    /// Returns taxon summary rows, optionally filtered by sample names.
    ///
    /// - Parameter samples: If non-nil and non-empty, only return rows for these samples.
    /// - Returns: Array of ``NaoMgsTaxonSummaryRow`` sorted by hit count descending.
    public func fetchTaxonSummaryRows(samples: [String]? = nil) throws -> [NaoMgsTaxonSummaryRow] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql: String
        let projection = """
        SELECT sample, tax_id, name, hit_count, unique_read_count,
               avg_identity, avg_bit_score, avg_edit_distance,
               pcr_duplicate_count, accession_count, top_accessions_json,
               bam_path, bam_index_path
        FROM taxon_summaries
        """
        if let samples, !samples.isEmpty {
            let placeholders = samples.map { _ in "?" }.joined(separator: ",")
            sql = "\(projection) WHERE sample IN (\(placeholders)) ORDER BY hit_count DESC"
        } else {
            sql = "\(projection) ORDER BY hit_count DESC"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        if let samples, !samples.isEmpty {
            for (i, sample) in samples.enumerated() {
                naoBindText(stmt, Int32(i + 1), sample)
            }
        }

        var rows: [NaoMgsTaxonSummaryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let taxId = Int(sqlite3_column_int64(stmt, 1))
            let name = String(cString: sqlite3_column_text(stmt, 2))
            let hitCount = Int(sqlite3_column_int64(stmt, 3))
            let uniqueReadCount = Int(sqlite3_column_int64(stmt, 4))
            let avgIdentity = sqlite3_column_double(stmt, 5)
            let avgBitScore = sqlite3_column_double(stmt, 6)
            let avgEditDistance = sqlite3_column_double(stmt, 7)
            let pcrDuplicateCount = Int(sqlite3_column_int64(stmt, 8))
            let accessionCount = Int(sqlite3_column_int64(stmt, 9))
            let topAccessionsJSON = String(cString: sqlite3_column_text(stmt, 10))
            let bamPath: String? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 11))
            let bamIndexPath: String? = sqlite3_column_type(stmt, 12) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 12))

            // Decode top_accessions_json
            let topAccessions: [String]
            if let data = topAccessionsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                topAccessions = parsed
            } else {
                topAccessions = []
            }

            rows.append(NaoMgsTaxonSummaryRow(
                sample: sample,
                taxId: taxId,
                name: name,
                hitCount: hitCount,
                uniqueReadCount: uniqueReadCount,
                avgIdentity: avgIdentity,
                avgBitScore: avgBitScore,
                avgEditDistance: avgEditDistance,
                pcrDuplicateCount: pcrDuplicateCount,
                accessionCount: accessionCount,
                topAccessions: topAccessions,
                bamPath: bamPath,
                bamIndexPath: bamIndexPath
            ))
        }
        return rows
    }

    /// Deletes all rows from the `virus_hits` table and vacuums the database.
    ///
    /// Called after BAMs have been materialized and accession summaries pre-computed.
    /// The table structure is preserved (so schema checks don't break) but all row
    /// data — including read sequences and quality strings — is reclaimed.
    ///
    /// Requires a read-write database connection (use `openReadWrite(at:)`).
    public func deleteVirusHitsAndVacuum() throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }
        guard sqlite3_exec(db, "DELETE FROM virus_hits", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Failed to delete virus_hits: \(msg)")
        }
        // Drop indices on the now-empty table to save space
        sqlite3_exec(db, "DROP INDEX IF EXISTS idx_hits_sample_taxon_accession", nil, nil, nil)
        sqlite3_exec(db, "DROP INDEX IF EXISTS idx_hits_taxon_accession", nil, nil, nil)
        sqlite3_exec(db, "DROP INDEX IF EXISTS idx_hits_sample", nil, nil, nil)
        // Reclaim disk space
        guard sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("VACUUM failed: \(msg)")
        }
        logger.info("Deleted virus_hits rows and vacuumed database")
    }

    /// Updates BAM and index paths for all taxon rows in each sample.
    ///
    /// - Parameter bamPathsBySample: Maps sample ID -> (bam path, optional index path),
    ///   both paths relative to the NAO-MGS result directory.
    public func updateBamPaths(_ bamPathsBySample: [String: (bamPath: String, bamIndexPath: String?)]) throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }
        guard !bamPathsBySample.isEmpty else { return }

        let sql = "UPDATE taxon_summaries SET bam_path = ?, bam_index_path = ? WHERE sample = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Prepare BAM path update failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for (sample, paths) in bamPathsBySample {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, paths.bamPath)
            if let bamIndexPath = paths.bamIndexPath {
                naoBindText(stmt, 2, bamIndexPath)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            naoBindText(stmt, 3, sample)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.queryFailed("BAM path update failed for sample \(sample): \(msg)")
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - MiniBAM Accession Selection

    /// Returns the union of all top accessions from `taxon_summaries.top_accessions_json`,
    /// deduplicated and sorted. Used to select which reference FASTAs to fetch.
    public func allMiniBAMAccessions() throws -> [String] {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }

        let sql = "SELECT top_accessions_json FROM taxon_summaries WHERE top_accessions_json != '[]'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var accessions = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let json = String(cString: sqlite3_column_text(stmt, 0))
            if let data = json.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                accessions.formUnion(parsed)
            }
        }
        return accessions.sorted()
    }

    /// Returns metadata for the manifest: top taxon name and ID.
    public func topTaxon() throws -> (name: String, taxId: Int)? {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }

        let sql = "SELECT name, tax_id FROM taxon_summaries ORDER BY hit_count DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let taxId = Int(sqlite3_column_int64(stmt, 1))
            return (name, taxId)
        }
        return nil
    }

    // MARK: - Accession Summary Queries

    /// Returns per-accession statistics for a given sample and taxon.
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    /// - Returns: Array of ``NaoMgsAccessionSummary`` sorted by read count descending.
    public func fetchAccessionSummaries(sample: String, taxId: Int) throws -> [NaoMgsAccessionSummary] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        // Use pre-computed accession_summaries table (fast path)
        let sql = """
        SELECT accession, read_count, unique_read_count, reference_length,
               covered_base_pairs, coverage_fraction
        FROM accession_summaries
        WHERE sample = ? AND tax_id = ?
        ORDER BY read_count DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        naoBindText(stmt, 1, sample)
        sqlite3_bind_int64(stmt, 2, Int64(taxId))

        var results: [NaoMgsAccessionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(NaoMgsAccessionSummary(
                accession: String(cString: sqlite3_column_text(stmt, 0)),
                readCount: Int(sqlite3_column_int64(stmt, 1)),
                uniqueReadCount: Int(sqlite3_column_int64(stmt, 2)),
                referenceLength: Int(sqlite3_column_int64(stmt, 3)),
                coveredBasePairs: Int(sqlite3_column_int64(stmt, 4)),
                coverageFraction: sqlite3_column_double(stmt, 5)
            ))
        }
        return results
    }

    /// Merges overlapping intervals and returns total covered base pairs.
    private static func computeCoveredBasePairs(_ intervals: [(start: Int, end: Int)]) -> Int {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.start < $1.start }
        var mergedStart = sorted[0].start
        var mergedEnd = sorted[0].end
        var total = 0
        for interval in sorted.dropFirst() {
            if interval.start <= mergedEnd {
                mergedEnd = max(mergedEnd, interval.end)
            } else {
                total += mergedEnd - mergedStart
                mergedStart = interval.start
                mergedEnd = interval.end
            }
        }
        total += mergedEnd - mergedStart
        return total
    }

    // MARK: - Read Queries

    /// Returns aligned reads for a specific accession within a sample and taxon.
    ///
    /// Converts raw virus hit rows into ``AlignedRead`` objects suitable for
    /// the alignment viewer.
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    ///   - accession: The accession (subject_seq_id).
    ///   - maxReads: Maximum number of reads to return (default 500).
    /// - Returns: Array of ``AlignedRead`` objects.
    public func fetchReadsForAccession(
        sample: String,
        taxId: Int,
        accession: String,
        maxReads: Int = 500
    ) throws -> [AlignedRead] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = """
        SELECT seq_id, subject_seq_id, ref_start, cigar, read_sequence, read_quality,
               is_reverse_complement, bit_score, edit_distance, fragment_length
        FROM virus_hits
        WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        naoBindText(stmt, 1, sample)
        sqlite3_bind_int64(stmt, 2, Int64(taxId))
        naoBindText(stmt, 3, accession)
        sqlite3_bind_int(stmt, 4, Int32(clamping: min(maxReads, Int(Int32.max))))

        var reads: [AlignedRead] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seqId = String(cString: sqlite3_column_text(stmt, 0))
            let subjectSeqId = String(cString: sqlite3_column_text(stmt, 1))
            let refStart = Int(sqlite3_column_int64(stmt, 2))
            let cigarStr = String(cString: sqlite3_column_text(stmt, 3))
            let readSequence = String(cString: sqlite3_column_text(stmt, 4))
            let readQuality = String(cString: sqlite3_column_text(stmt, 5))
            let isRC = sqlite3_column_int(stmt, 6) != 0
            let bitScore = sqlite3_column_double(stmt, 7)
            let editDist = Int(sqlite3_column_int(stmt, 8))
            let fragLength = Int(sqlite3_column_int(stmt, 9))

            let flag: UInt16 = isRC ? 0x10 : 0
            // Safe conversion: clamp bitScore/5.0 to UInt8 range to prevent overflow crash
            let rawMapq = bitScore / 5.0
            let mapq = UInt8(clamping: Int(max(0, min(255, rawMapq))))
            let clampedMapq = min(mapq, 60)
            let cigar = CIGAROperation.parse(cigarStr) ?? []
            // Safe conversion: clamp quality values to prevent UInt8 underflow when subtracting 33
            let qualities = readQuality.unicodeScalars.map { scalar -> UInt8 in
                let val = Int(scalar.value) - 33
                return UInt8(clamping: max(0, min(255, val)))
            }

            reads.append(AlignedRead(
                name: seqId,
                flag: flag,
                chromosome: subjectSeqId,
                position: refStart,
                mapq: clampedMapq,
                cigar: cigar,
                sequence: readSequence,
                qualities: qualities,
                insertSize: fragLength,
                editDistance: editDist
            ))
        }
        return reads
    }

    // MARK: - BLAST Read Selection

    /// Fetches full virus hit records for BLAST verification, selecting representative
    /// reads from different genome positions. Returns reads deduplicated by alignment
    /// signature (accession + position + strand + length).
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    ///   - maxReads: Maximum number of reads to return (default 50).
    /// - Returns: Array of ``NaoMgsVirusHit`` suitable for BLAST verification.
    public func fetchVirusHitsForBLAST(
        sample: String,
        taxId: Int,
        maxReads: Int = 50
    ) throws -> [NaoMgsVirusHit] {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }

        let sql = """
            SELECT sample, seq_id, tax_id, subject_seq_id, subject_title,
                   ref_start, cigar, read_sequence, read_quality,
                   percent_identity, bit_score, e_value, edit_distance,
                   query_length, is_reverse_complement, pair_status,
                   fragment_length, best_alignment_score
            FROM virus_hits
            WHERE sample = ? AND tax_id = ?
            GROUP BY subject_seq_id, ref_start, is_reverse_complement, query_length
            ORDER BY edit_distance ASC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        naoBindText(stmt, 1, sample)
        sqlite3_bind_int(stmt, 2, Int32(taxId))
        sqlite3_bind_int(stmt, 3, Int32(maxReads))

        var results: [NaoMgsVirusHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hit = NaoMgsVirusHit(
                sample: String(cString: sqlite3_column_text(stmt, 0)),
                seqId: String(cString: sqlite3_column_text(stmt, 1)),
                taxId: Int(sqlite3_column_int(stmt, 2)),
                bestAlignmentScore: sqlite3_column_double(stmt, 17),
                cigar: String(cString: sqlite3_column_text(stmt, 6)),
                queryStart: 0,
                queryEnd: Int(sqlite3_column_int(stmt, 13)),
                refStart: Int(sqlite3_column_int(stmt, 5)),
                refEnd: Int(sqlite3_column_int(stmt, 5)) + Int(sqlite3_column_int(stmt, 13)),
                readSequence: String(cString: sqlite3_column_text(stmt, 7)),
                readQuality: String(cString: sqlite3_column_text(stmt, 8)),
                subjectSeqId: String(cString: sqlite3_column_text(stmt, 3)),
                subjectTitle: String(cString: sqlite3_column_text(stmt, 4)),
                bitScore: sqlite3_column_double(stmt, 10),
                eValue: sqlite3_column_double(stmt, 11),
                percentIdentity: sqlite3_column_double(stmt, 9),
                editDistance: Int(sqlite3_column_int(stmt, 12)),
                fragmentLength: Int(sqlite3_column_int(stmt, 16)),
                isReverseComplement: sqlite3_column_int(stmt, 14) != 0,
                pairStatus: String(cString: sqlite3_column_text(stmt, 15)),
                queryLength: Int(sqlite3_column_int(stmt, 13))
            )
            results.append(hit)
        }
        return results
    }

    // MARK: - Read Name Queries

    /// Returns the distinct set of read names (seq_id) for a given sample and taxon.
    ///
    /// This is used by the extraction pipeline to filter BAM reads: after
    /// `samtools view` extracts all reads from the accession regions, only reads
    /// whose names appear in this set actually belong to the selected taxon.
    /// Without this filter, reads from other taxa that share the same reference
    /// accessions would be incorrectly included.
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    /// - Returns: A set of read names (seq_id values) belonging to this taxon.
    public func fetchReadNames(sample: String, taxId: Int) throws -> Set<String> {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }

        let sql = """
            SELECT seq_id
            FROM taxon_read_names
            WHERE sample = ? AND tax_id = ?
            UNION
            SELECT DISTINCT seq_id
            FROM virus_hits
            WHERE sample = ? AND tax_id = ?
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        naoBindText(stmt, 1, sample)
        sqlite3_bind_int(stmt, 2, Int32(taxId))
        naoBindText(stmt, 3, sample)
        sqlite3_bind_int(stmt, 4, Int32(taxId))

        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return names
    }
}
