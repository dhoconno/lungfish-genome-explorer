// NaoMgsDatabase+Create.swift - Create/streaming-create path for NAO-MGS database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension NaoMgsDatabase {

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
            naoMgsDatabaseLogger.info("Created NAO-MGS database with \(hits.count) hits at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try NaoMgsDatabase(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Streaming Create

    /// In-memory accumulator for computing taxon and accession summaries during
    /// streaming import. Avoids expensive post-insert SQL aggregation queries.
    final class TaxonAccumulator {
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
            naoMgsDatabaseLogger.info("Created NAO-MGS database (streaming) with \(insertedCount) hits at \(url.lastPathComponent)")

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

        naoMgsDatabaseLogger.info("Stored \(globalExtents.count) fallback reference lengths from alignment extents")
    }

    // MARK: - Schema

    static func createSchema(db: OpaquePointer) throws {
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

    static func createIndices(db: OpaquePointer) throws {
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

    static func populateTaxonReadNames(db: OpaquePointer?) throws {
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

    static func populateSampleHitCounts(db: OpaquePointer?) throws {
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
}
