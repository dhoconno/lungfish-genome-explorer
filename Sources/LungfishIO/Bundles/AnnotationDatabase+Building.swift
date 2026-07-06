// AnnotationDatabase+Building.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

struct AnnotationDatabaseBuildPlan {
    var schemaSQL: String
    var metadataSQL: String
    var indexSQLStatements: [String]

    static let `default` = AnnotationDatabaseBuildPlan(
        schemaSQL: """
        CREATE TABLE annotations (
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            chromosome TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            strand TEXT NOT NULL DEFAULT '.',
            attributes TEXT,
            block_count INTEGER,
            block_sizes TEXT,
            block_starts TEXT,
            gene_name TEXT
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,
        metadataSQL: "INSERT INTO db_metadata VALUES ('schema_version', '4')",
        indexSQLStatements: [
            "CREATE INDEX idx_annotations_name ON annotations(name COLLATE NOCASE)",
            "CREATE INDEX idx_annotations_type ON annotations(type)",
            "CREATE INDEX idx_annotations_chrom ON annotations(chromosome)",
            "CREATE INDEX idx_annotations_region ON annotations(chromosome, start, end)",
            "CREATE INDEX idx_annotations_gene_name ON annotations(gene_name COLLATE NOCASE)",
        ]
    )
}

extension AnnotationDatabase {

    // MARK: - Attribute Parsing

    /// Parses a GFF3- or GTF-style attributes string into a dictionary.
    ///
    /// Formats: `key1=value1;key2=value2` or `key1 "value1"; key2 "value2";`
    /// Values are URL-decoded (percent-encoded spaces, commas, etc.).
    ///
    /// - Parameter attrs: Raw attributes string
    /// - Returns: Dictionary of key-value pairs
    public static func parseAttributes(_ attrs: String) -> [String: String] {
        parseFlexibleAttributes(attrs)
    }

    private static func withNewSQLiteDatabase<T>(at outputURL: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let rc = sqlite3_open(outputURL.path, &db)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw AnnotationDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func sqliteMessage(db: OpaquePointer, errorMessage: UnsafeMutablePointer<CChar>?) -> String {
        if let errorMessage {
            defer { sqlite3_free(errorMessage) }
            return String(cString: errorMessage)
        }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func executeSQLite(_ db: OpaquePointer, _ sql: String, context: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        guard rc == SQLITE_OK else {
            let msg = sqliteMessage(db: db, errorMessage: errMsg)
            throw AnnotationDatabaseError.createFailed("\(context): \(msg)")
        }
    }

    private static func executeSQLiteStep(_ db: OpaquePointer, statement: OpaquePointer?, context: String) throws {
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE else {
            throw AnnotationDatabaseError.createFailed("\(context): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func rollbackSQLiteTransaction(_ db: OpaquePointer) {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }

    private static func createSchema(in db: OpaquePointer, buildPlan: AnnotationDatabaseBuildPlan) throws {
        try executeSQLite(db, buildPlan.schemaSQL, context: "create annotation schema")
        try executeSQLite(db, buildPlan.metadataSQL, context: "write annotation schema metadata")
    }

    private static func createIndexes(in db: OpaquePointer, buildPlan: AnnotationDatabaseBuildPlan) throws {
        for sql in buildPlan.indexSQLStatements {
            try executeSQLite(db, sql, context: "create annotation index")
        }
    }

    // MARK: - Static Creation (for bundle building)

    /// Creates a new annotation database from BED file content.
    ///
    /// Parses BED lines (tab-separated) extracting: chromosome (col 0), start (col 1),
    /// end (col 2), name (col 3), strand (col 5), feature type (col 12 if present),
    /// and GFF3 attributes (col 13 if present).
    ///
    /// - Parameters:
    ///   - bedURL: URL to the BED file
    ///   - outputURL: URL for the SQLite database to create
    /// - Returns: Number of records inserted
    @discardableResult
    public static func createFromBED(bedURL: URL, outputURL: URL) throws -> Int {
        try createFromBED(bedURL: bedURL, outputURL: outputURL, buildPlan: .default)
    }

    @discardableResult
    static func createFromBED(
        bedURL: URL,
        outputURL: URL,
        buildPlan: AnnotationDatabaseBuildPlan
    ) throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

        do {
            return try withNewSQLiteDatabase(at: outputURL) { db in
                try createSchema(in: db, buildPlan: buildPlan)

                // Begin transaction for bulk insert
                try executeSQLite(db, "BEGIN TRANSACTION", context: "begin annotation import transaction")
                var transactionOpen = true

                do {
                    let insertSQL = "INSERT INTO annotations (name, type, chromosome, start, end, strand, attributes, block_count, block_sizes, block_starts, gene_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                    var insertStmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                        throw AnnotationDatabaseError.createFailed("Failed to prepare INSERT statement: \(String(cString: sqlite3_errmsg(db)))")
                    }
                    defer { sqlite3_finalize(insertStmt) }

                    let content = try String(contentsOf: bedURL, encoding: .utf8)
                    var insertCount = 0

                    for line in content.split(separator: "\n") {
                        guard !line.hasPrefix("#") else { continue }
                        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                        guard fields.count >= 4 else { continue }

                        let chrom = String(fields[0])
                        let start = Int(fields[1]) ?? 0
                        let end = Int(fields[2]) ?? 0
                        let strand = fields.count > 5 ? String(fields[5]) : "."

                        // Extract BED12 block data (columns 9-11, 0-indexed)
                        let blockCount: Int? = fields.count > 9 ? Int(fields[9]) : nil
                        let blockSizes: String? = fields.count > 10 ? String(fields[10]) : nil
                        let blockStarts: String? = fields.count > 11 ? String(fields[11]) : nil

                        // Extract type from column 12 (0-indexed) if present, otherwise infer
                        let type: String
                        if fields.count > 12 {
                            type = String(fields[12])
                        } else {
                            type = "gene"
                        }

                        let rawName = String(fields[3])
                        let name: String
                        if rawName.isEmpty {
                            name = "\(type):\(chrom):\(start)-\(end)"
                        } else {
                            name = rawName
                        }

                        // Extract GFF3 attributes from column 13 if present
                        let attributes: String?
                        if fields.count > 13 {
                            let attr = String(fields[13])
                            attributes = attr.isEmpty ? nil : attr
                        } else {
                            attributes = nil
                        }

                        // Extract gene_name from attributes
                        let geneName: String?
                        if let attributes {
                            let parsed = parseAttributes(attributes)
                            geneName = parsed["gene"]
                        } else {
                            geneName = nil
                        }

                        sqlite3_reset(insertStmt)
                        sqlite3_bind_text(insertStmt, 1, (name as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(insertStmt, 2, (type as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(insertStmt, 3, (chrom as NSString).utf8String, -1, nil)
                        sqlite3_bind_int64(insertStmt, 4, Int64(start))
                        sqlite3_bind_int64(insertStmt, 5, Int64(end))
                        sqlite3_bind_text(insertStmt, 6, (strand as NSString).utf8String, -1, nil)
                        if let attributes {
                            sqlite3_bind_text(insertStmt, 7, (attributes as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 7)
                        }
                        if let blockCount {
                            sqlite3_bind_int64(insertStmt, 8, Int64(blockCount))
                        } else {
                            sqlite3_bind_null(insertStmt, 8)
                        }
                        if let blockSizes {
                            sqlite3_bind_text(insertStmt, 9, (blockSizes as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 9)
                        }
                        if let blockStarts {
                            sqlite3_bind_text(insertStmt, 10, (blockStarts as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 10)
                        }
                        if let geneName {
                            sqlite3_bind_text(insertStmt, 11, (geneName as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 11)
                        }

                        try executeSQLiteStep(db, statement: insertStmt, context: "insert annotation \(name)")
                        insertCount += 1
                    }

                    try createIndexes(in: db, buildPlan: buildPlan)

                    try executeSQLite(db, "COMMIT", context: "commit annotation import transaction")
                    transactionOpen = false

                    dbLogger.info("Created annotation database with \(insertCount) records at \(outputURL.lastPathComponent)")
                    return insertCount
                } catch {
                    if transactionOpen {
                        rollbackSQLiteTransaction(db)
                    }
                    throw error
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    // MARK: - Static Creation from GFF3

    /// Creates a new annotation database directly from a GFF3 file.
    ///
    /// This bypasses the intermediate BED format entirely, parsing GFF3 features
    /// and inserting them into SQLite with parent-child aggregation for transcript
    /// block data. Transcript-level features (mRNA, transcript, etc.) collect exon
    /// children into BED12-style blocks; CDS children define thickStart/thickEnd.
    ///
    /// - Parameters:
    ///   - gffURL: URL to the GFF3 file (must be decompressed)
    ///   - outputURL: URL for the SQLite database to create
    ///   - chromosomeSizes: Optional chromosome size map for coordinate clipping
    /// - Returns: Number of records inserted
    @discardableResult
    public static func createFromGFF3(
        gffURL: URL,
        outputURL: URL,
        chromosomeSizes: [(String, Int64)]? = nil
    ) async throws -> Int {
        try await createFromGFF3(
            gffURL: gffURL,
            outputURL: outputURL,
            chromosomeSizes: chromosomeSizes,
            buildPlan: .default
        )
    }

    @discardableResult
    static func createFromGFF3(
        gffURL: URL,
        outputURL: URL,
        chromosomeSizes: [(String, Int64)]? = nil,
        buildPlan: AnnotationDatabaseBuildPlan
    ) async throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

        let chromSizeMap: [String: Int64]?
        if let sizes = chromosomeSizes {
            chromSizeMap = Dictionary(uniqueKeysWithValues: sizes)
        } else {
            chromSizeMap = nil
        }

        // Transcript-level types whose children get aggregated into blocks
        let transcriptTypes: Set<String> = [
            "mRNA", "transcript", "lnc_RNA", "Lnc_RNA", "rRNA", "tRNA", "snRNA", "snoRNA",
            "miRNA", "ncRNA", "primary_transcript", "V_gene_segment",
            "D_gene_segment", "J_gene_segment", "C_gene_segment",
        ]
        let exonTypes: Set<String> = ["exon"]
        let cdsTypes: Set<String> = ["CDS"]

        // ── Pass 1: Read all features and build parent-child index ──
        struct ParsedFeature {
            let seqid: String
            let featureType: String
            let start: Int        // 1-based
            let end: Int          // 1-based inclusive
            let strand: String
            let id: String?
            let parentID: String?
            let name: String
            let attributes: [String: String]
        }

        var allFeatures: [ParsedFeature] = []
        var childrenByParent: [String: [Int]] = [:]

        for try await line in gffURL.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("##FASTA") { break }
                continue
            }

            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9 else { continue }

            guard let start = Int(fields[3]), let end = Int(fields[4]) else { continue }

            let strand: String
            switch fields[6] {
            case "+": strand = "+"
            case "-": strand = "-"
            default: strand = "."
            }

            var attrs = parseGFF3Attributes(fields[8])
            if fields[2] == "CDS", ["0", "1", "2"].contains(fields[7]) {
                attrs["lungfish_gff_phase"] = fields[7]
            }
            let name = displayName(from: attrs, fallback: fields[2])

            let feature = ParsedFeature(
                seqid: fields[0],
                featureType: fields[2],
                start: start,
                end: end,
                strand: strand,
                id: attrs["ID"],
                parentID: attrs["Parent"],
                name: name,
                attributes: attrs
            )

            let index = allFeatures.count
            allFeatures.append(feature)

            if let parentStr = attrs["Parent"] {
                // GFF3 Parent can be comma-separated (e.g., "mRNA1,mRNA2" for shared exons)
                for parentID in parentStr.split(separator: ",").map(String.init) {
                    childrenByParent[parentID, default: []].append(index)
                }
            }
        }

        dbLogger.info("createFromGFF3: Parsed \(allFeatures.count) features from \(gffURL.lastPathComponent)")

        do {
            return try withNewSQLiteDatabase(at: outputURL) { db in
                try createSchema(in: db, buildPlan: buildPlan)

                // Group features by GFF3 ID for same-ID merging (e.g., CDS with multiple intervals)
                var featuresByID: [String: [Int]] = [:]
                for (index, feature) in allFeatures.enumerated() {
                    if let id = feature.id {
                        featuresByID[id, default: []].append(index)
                    }
                }

                // ── Pass 2: Build database records with parent-child aggregation ──
                try executeSQLite(db, "BEGIN TRANSACTION", context: "begin annotation import transaction")
                var transactionOpen = true

                do {
                    let insertSQL = "INSERT INTO annotations (name, type, chromosome, start, end, strand, attributes, block_count, block_sizes, block_starts, gene_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                    var insertStmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                        throw AnnotationDatabaseError.createFailed("Failed to prepare INSERT statement: \(String(cString: sqlite3_errmsg(db)))")
                    }
                    defer { sqlite3_finalize(insertStmt) }

                    var insertCount = 0
                    var seenKeys = Set<String>()
                    var processedIDs = Set<String>()

                    /// GFF3 type validation here is intentionally syntactic, not ontology-enforcing.
                    /// Column 3 should be a Sequence Ontology term, but scientific review files
                    /// often carry workflow-specific feature types that are still useful tracks.
                    func isImportableFeatureType(_ type: String) -> Bool {
                        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !trimmed.isEmpty && trimmed != "."
                    }

                    /// Helper: serialize GFF3 attributes (excluding ID and Parent) with percent-encoding.
                    func serializeAttributes(_ attrs: [String: String]) -> String? {
                        var attrPairs: [String] = []
                        for (key, value) in attrs.sorted(by: { $0.key < $1.key }) {
                            let encoded = value
                                .replacingOccurrences(of: "%", with: "%25")
                                .replacingOccurrences(of: ";", with: "%3B")
                                .replacingOccurrences(of: "=", with: "%3D")
                                .replacingOccurrences(of: "&", with: "%26")
                                .replacingOccurrences(of: ",", with: "%2C")
                            attrPairs.append("\(key)=\(encoded)")
                        }
                        return attrPairs.isEmpty ? nil : attrPairs.joined(separator: ";")
                    }

                    /// Helper: bind all 11 columns and execute the INSERT.
                    func insertRecord(
                        name: String, type: String, seqid: String,
                        chromStart: Int, chromEnd: Int, strand: String,
                        attrString: String?, blockCount: Int?,
                        blockSizesStr: String?, blockStartsStr: String?,
                        geneName: String?
                    ) throws {
                        sqlite3_reset(insertStmt)
                        sqlite3_bind_text(insertStmt, 1, (name as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(insertStmt, 2, (type as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(insertStmt, 3, (seqid as NSString).utf8String, -1, nil)
                        sqlite3_bind_int64(insertStmt, 4, Int64(chromStart))
                        sqlite3_bind_int64(insertStmt, 5, Int64(chromEnd))
                        sqlite3_bind_text(insertStmt, 6, (strand as NSString).utf8String, -1, nil)
                        if let attrString {
                            sqlite3_bind_text(insertStmt, 7, (attrString as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 7)
                        }
                        if let blockCount {
                            sqlite3_bind_int64(insertStmt, 8, Int64(blockCount))
                        } else {
                            sqlite3_bind_null(insertStmt, 8)
                        }
                        if let blockSizesStr {
                            sqlite3_bind_text(insertStmt, 9, (blockSizesStr as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 9)
                        }
                        if let blockStartsStr {
                            sqlite3_bind_text(insertStmt, 10, (blockStartsStr as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 10)
                        }
                        if let geneName {
                            sqlite3_bind_text(insertStmt, 11, (geneName as NSString).utf8String, -1, nil)
                        } else {
                            sqlite3_bind_null(insertStmt, 11)
                        }

                        try executeSQLiteStep(db, statement: insertStmt, context: "insert annotation \(name)")
                        insertCount += 1
                    }

                    for feature in allFeatures {
                        guard isImportableFeatureType(feature.featureType) else { continue }

                        let geneName = geneName(from: feature.attributes)

                        // ── Same-ID merging: CDS features sharing a GFF3 ID are intervals of one CDS ──
                        if let featureID = feature.id,
                           let siblings = featuresByID[featureID],
                           siblings.count > 1,
                           feature.featureType == "CDS",
                           !transcriptTypes.contains(feature.featureType) {

                            // Already merged this ID? Skip.
                            guard processedIDs.insert(featureID).inserted else { continue }

                            // Merge all same-ID features into a single BED12 entry
                            let siblingFeatures = siblings.map { allFeatures[$0] }

                            // Compute merged span (0-based)
                            let allStarts = siblingFeatures.map { $0.start - 1 }
                            let allEnds = siblingFeatures.map { $0.end }
                            var mergedStart = allStarts.min()!
                            var mergedEnd = allEnds.max()!

                            // Clip to chromosome boundaries
                            if let chromSize = chromSizeMap?[feature.seqid] {
                                mergedStart = max(0, min(mergedStart, Int(chromSize)))
                                mergedEnd = max(mergedStart, min(mergedEnd, Int(chromSize)))
                            }

                            // Build BED12 blocks from sorted intervals
                            let sortedIntervals = zip(allStarts, allEnds)
                                .map { (start: $0, end: $1) }
                                .sorted { $0.start < $1.start }

                            var clippedBlocks: [(size: Int, start: Int)] = []
                            for interval in sortedIntervals {
                                let clippedStart = max(interval.start, mergedStart)
                                let clippedEnd = min(interval.end, mergedEnd)
                                if clippedEnd > clippedStart {
                                    clippedBlocks.append((
                                        size: clippedEnd - clippedStart,
                                        start: clippedStart - mergedStart
                                    ))
                                }
                            }

                            let blockCount: Int?
                            let blockSizesStr: String?
                            let blockStartsStr: String?
                            if clippedBlocks.count > 1 {
                                blockCount = clippedBlocks.count
                                blockSizesStr = clippedBlocks.map { "\($0.size)" }.joined(separator: ",")
                                blockStartsStr = clippedBlocks.map { "\($0.start)" }.joined(separator: ",")
                            } else {
                                blockCount = nil
                                blockSizesStr = nil
                                blockStartsStr = nil
                            }

                            // Use attributes from the first occurrence
                            let attrString = serializeAttributes(feature.attributes)

                            // Deduplicate (using merged coordinates)
                            let key = "\(feature.name)|\(feature.featureType)|\(feature.seqid)|\(mergedStart)|\(mergedEnd)"
                            guard seenKeys.insert(key).inserted else { continue }

                            try insertRecord(
                                name: feature.name, type: feature.featureType, seqid: feature.seqid,
                                chromStart: mergedStart, chromEnd: mergedEnd, strand: feature.strand,
                                attrString: attrString, blockCount: blockCount,
                                blockSizesStr: blockSizesStr, blockStartsStr: blockStartsStr,
                                geneName: geneName
                            )
                            continue
                        }

                        // ── Transcript-level features: aggregate child exons into blocks ──
                        let attrString = serializeAttributes(feature.attributes)

                        var chromStart = feature.start - 1
                        var chromEnd = feature.end
                        if let chromSize = chromSizeMap?[feature.seqid] {
                            chromStart = max(0, min(chromStart, Int(chromSize)))
                            chromEnd = max(chromStart, min(chromEnd, Int(chromSize)))
                        }

                        var blockCount: Int? = nil
                        var blockSizesStr: String? = nil
                        var blockStartsStr: String? = nil

                        if transcriptTypes.contains(feature.featureType),
                           let featureID = feature.id,
                           let childIndices = childrenByParent[featureID] {

                            var exonIntervals: [(start: Int, end: Int)] = []
                            var cdsIntervals: [(start: Int, end: Int)] = []

                            for childIdx in childIndices {
                                let child = allFeatures[childIdx]
                                if exonTypes.contains(child.featureType) {
                                    exonIntervals.append((start: child.start - 1, end: child.end))
                                } else if cdsTypes.contains(child.featureType) {
                                    cdsIntervals.append((start: child.start - 1, end: child.end))
                                }
                            }

                            let blockIntervals = exonIntervals.isEmpty ? cdsIntervals : exonIntervals

                            if blockIntervals.count > 1 {
                                let sortedIntervals = blockIntervals.sorted { $0.start < $1.start }

                                var clippedBlocks: [(size: Int, start: Int)] = []
                                for exon in sortedIntervals {
                                    let clippedStart = max(exon.start, chromStart)
                                    let clippedEnd = min(exon.end, chromEnd)
                                    if clippedEnd > clippedStart {
                                        clippedBlocks.append((size: clippedEnd - clippedStart, start: clippedStart - chromStart))
                                    }
                                }

                                if clippedBlocks.count > 1 {
                                    blockCount = clippedBlocks.count
                                    blockSizesStr = clippedBlocks.map { "\($0.size)" }.joined(separator: ",")
                                    blockStartsStr = clippedBlocks.map { "\($0.start)" }.joined(separator: ",")
                                }
                            }
                        }

                        // Deduplicate
                        let key = "\(feature.name)|\(feature.featureType)|\(feature.seqid)|\(chromStart)|\(chromEnd)"
                        guard seenKeys.insert(key).inserted else { continue }

                        try insertRecord(
                            name: feature.name, type: feature.featureType, seqid: feature.seqid,
                            chromStart: chromStart, chromEnd: chromEnd, strand: feature.strand,
                            attrString: attrString, blockCount: blockCount,
                            blockSizesStr: blockSizesStr, blockStartsStr: blockStartsStr,
                            geneName: geneName
                        )
                    }

                    try createIndexes(in: db, buildPlan: buildPlan)
                    try executeSQLite(db, "COMMIT", context: "commit annotation import transaction")
                    transactionOpen = false

                    dbLogger.info("Created GFF3 annotation database with \(insertCount) records at \(outputURL.lastPathComponent)")
                    return insertCount
                } catch {
                    if transactionOpen {
                        rollbackSQLiteTransaction(db)
                    }
                    throw error
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Parses GFF3 or GTF-style attributes string into a dictionary.
    private static func parseGFF3Attributes(_ attributeString: String) -> [String: String] {
        parseFlexibleAttributes(attributeString)
    }

    private static func parseFlexibleAttributes(_ attributeString: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for pair in attributeString.split(separator: ";") {
            let entry = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            if let equalsIndex = entry.firstIndex(of: "=") {
                let key = String(entry[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(entry[entry.index(after: equalsIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    attributes[key] = decodeAttributeValue(rawValue)
                }
                continue
            }

            guard let spaceIndex = entry.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }

            let key = String(entry[..<spaceIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(entry[entry.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                attributes[key] = decodeAttributeValue(rawValue)
            }
        }
        return attributes
    }

    private static func displayName(from attributes: [String: String], fallback: String) -> String {
        attributes["Name"]
            ?? attributes["gene_name"]
            ?? attributes["gene"]
            ?? attributes["gene_id"]
            ?? attributes["transcript_name"]
            ?? attributes["transcript_id"]
            ?? attributes["ID"]
            ?? fallback
    }

    private static func geneName(from attributes: [String: String]) -> String? {
        attributes["gene"] ?? attributes["gene_name"] ?? attributes["gene_id"]
    }

    private static func decodeAttributeValue(_ value: String) -> String {
        let unquoted: String
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            unquoted = String(value.dropFirst().dropLast())
        } else {
            unquoted = value
        }

        return unquoted.removingPercentEncoding ?? unquoted
    }
}
