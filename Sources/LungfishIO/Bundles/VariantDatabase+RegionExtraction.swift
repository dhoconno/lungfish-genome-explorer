// VariantDatabase+RegionExtraction.swift - Region extraction + VCF streaming
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Region Extraction

    /// Extracts variants (and optionally genotypes) from a region into a new database.
    ///
    /// Coordinate transform: positions are shifted by `-extractionStart` so the new
    /// database is zero-based relative to the extracted sub-sequence.
    ///
    /// - Parameters:
    ///   - chromosome: Source chromosome name.
    ///   - chromosomeAliases: Alternate chromosome names to try when source and
    ///     variant-track naming schemes differ (for example `NC_041760.1` vs `7`).
    ///   - start: 0-based start of extraction region.
    ///   - end: 0-based exclusive end of extraction region.
    ///   - outputURL: Where to create the new database.
    ///   - newChromosome: Chromosome name in the new database (defaults to source name).
    ///   - sampleFilter: Optional set of sample names to include. `nil` = all samples.
    /// - Returns: Number of variants written.
    @discardableResult
    public func extractRegion(
        chromosome: String,
        chromosomeAliases: [String] = [],
        start: Int,
        end: Int,
        outputURL: URL,
        newChromosome: String? = nil,
        sampleFilter: Set<String>? = nil
    ) throws -> Int {
        guard let sourceDB = self.db else {
            throw VariantDatabaseError.createFailed("Source database is not open")
        }

        try? FileManager.default.removeItem(at: outputURL)

        var destDB: OpaquePointer?
        guard sqlite3_open(outputURL.path, &destDB) == SQLITE_OK, let destDB else {
            let msg = destDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(destDB)
            throw VariantDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(destDB) }

        sqlite3_exec(destDB, "PRAGMA journal_mode = OFF", nil, nil, nil)
        sqlite3_exec(destDB, "PRAGMA synchronous = OFF", nil, nil, nil)

        let schema = """
        CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chromosome TEXT NOT NULL,
            position INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            variant_id TEXT NOT NULL,
            ref TEXT NOT NULL,
            alt TEXT NOT NULL,
            variant_type TEXT NOT NULL,
            quality REAL,
            filter TEXT,
            info TEXT,
            sample_count INTEGER DEFAULT 0
        );
        CREATE TABLE genotypes (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            sample_name TEXT NOT NULL,
            genotype TEXT,
            allele1 INTEGER,
            allele2 INTEGER,
            is_phased INTEGER DEFAULT 0,
            depth INTEGER,
            genotype_quality INTEGER,
            allele_depths TEXT,
            raw_fields TEXT,
            PRIMARY KEY (variant_id, sample_name)
        );
        CREATE TABLE samples (
            name TEXT PRIMARY KEY,
            display_name TEXT,
            source_file TEXT,
            metadata TEXT
        );
        CREATE TABLE variant_info_defs (
            key TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            number TEXT NOT NULL,
            description TEXT
        );
        CREATE TABLE variant_info (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (variant_id, key)
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(destDB, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw VariantDatabaseError.createFailed(msg)
        }

        try Self.requireMetadataRow(destDB, key: "schema_version", value: "3", context: "extractRegion")
        try Self.requireMetadataRow(destDB, key: "import_state", value: "inserting", context: "extractRegion")
        try Self.requireMetadataRow(
            destDB,
            key: "extracted_from_region",
            value: "\(chromosome):\(start)-\(end)",
            context: "extractRegion"
        )

        sqlite3_exec(destDB, "BEGIN TRANSACTION", nil, nil, nil)

        // Prepare insert statements
        let insertVariantSQL = """
        INSERT INTO variants (chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertVariantStmt: OpaquePointer?
        guard sqlite3_prepare_v2(destDB, insertVariantSQL, -1, &insertVariantStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare variant INSERT")
        }
        defer { sqlite3_finalize(insertVariantStmt) }

        let insertGenotypeSQL = """
        INSERT INTO genotypes (variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertGenotypeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(destDB, insertGenotypeSQL, -1, &insertGenotypeStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare genotype INSERT")
        }
        defer { sqlite3_finalize(insertGenotypeStmt) }

        let updateSampleCountSQL = "UPDATE variants SET sample_count = ? WHERE id = ?"
        var updateSampleCountStmt: OpaquePointer?
        guard sqlite3_prepare_v2(destDB, updateSampleCountSQL, -1, &updateSampleCountStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample_count UPDATE")
        }
        defer { sqlite3_finalize(updateSampleCountStmt) }

        let targetChrom = newChromosome ?? chromosome

        // Build alias-aware chromosome candidates so extraction still works when the
        // source reference and variant track use different chromosome naming schemes.
        let availableChromosomes = Set(allChromosomes())
        var seenChromCandidates = Set<String>()
        var chromosomeCandidates: [String] = []

        func appendChromosomeCandidate(_ token: String) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard availableChromosomes.contains(trimmed) else { return }
            guard seenChromCandidates.insert(trimmed).inserted else { return }
            chromosomeCandidates.append(trimmed)
        }

        func aliasExpansions(for token: String) -> [String] {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            var ordered: [String] = [trimmed]
            var seen = Set<String>(ordered)

            func append(_ value: String) {
                guard !value.isEmpty else { return }
                guard seen.insert(value).inserted else { return }
                ordered.append(value)
            }

            if let dot = trimmed.firstIndex(of: ".") {
                append(String(trimmed[..<dot]))
            }
            if trimmed.hasPrefix("chr") {
                append(String(trimmed.dropFirst(3)))
            } else {
                append("chr" + trimmed)
            }
            return ordered
        }

        for token in [chromosome] + chromosomeAliases {
            for expansion in aliasExpansions(for: token) {
                appendChromosomeCandidate(expansion)
            }
        }

        // Preserve old behavior when no candidate matches the source DB chromosome set.
        if chromosomeCandidates.isEmpty {
            chromosomeCandidates = [chromosome]
        }

        let chromosomePlaceholders = Array(repeating: "?", count: chromosomeCandidates.count).joined(separator: ",")

        // Stream source variants in-region without hard caps so large selections are complete.
        let variantQuerySQL = """
        SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
        FROM variants
        WHERE chromosome IN (\(chromosomePlaceholders)) AND position < ? AND end_pos > ?
        ORDER BY position, id
        """
        var variantQueryStmt: OpaquePointer?
        guard sqlite3_prepare_v2(sourceDB, variantQuerySQL, -1, &variantQueryStmt, nil) == SQLITE_OK, let variantQueryStmt else {
            throw VariantDatabaseError.createFailed("Failed to prepare source variant query")
        }
        defer { sqlite3_finalize(variantQueryStmt) }
        var bindIndex: Int32 = 1
        for queryChromosome in chromosomeCandidates {
            variantDBBindText(variantQueryStmt, bindIndex, queryChromosome)
            bindIndex += 1
        }
        sqlite3_bind_int64(variantQueryStmt, bindIndex, Int64(end))
        bindIndex += 1
        sqlite3_bind_int64(variantQueryStmt, bindIndex, Int64(start))

        var insertCount = 0
        var samplesWithGenotypes = Set<String>()
        var sourceToDestVariantIds: [(Int64, Int64)] = []

        while sqlite3_step(variantQueryStmt) == SQLITE_ROW {
            let sourceVariantId = sqlite3_column_int64(variantQueryStmt, 0)
            let sourcePosition = Int(sqlite3_column_int64(variantQueryStmt, 2))
            let sourceEnd = Int(sqlite3_column_int64(variantQueryStmt, 3))
            let variantID = sqlite3_column_text(variantQueryStmt, 4).map { String(cString: $0) } ?? ""
            let ref = sqlite3_column_text(variantQueryStmt, 5).map { String(cString: $0) } ?? ""
            let alt = sqlite3_column_text(variantQueryStmt, 6).map { String(cString: $0) } ?? ""
            let variantType = sqlite3_column_text(variantQueryStmt, 7).map { String(cString: $0) } ?? "SNP"
            let quality: Double? = sqlite3_column_type(variantQueryStmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(variantQueryStmt, 8)
            let filter = sqlite3_column_text(variantQueryStmt, 9).map { String(cString: $0) }
            let info = sqlite3_column_text(variantQueryStmt, 10).map { String(cString: $0) }

            // Shift coordinates relative to extraction start
            let newPosition = max(0, sourcePosition - start)
            let newEnd = min(end - start, sourceEnd - start)
            guard newEnd > newPosition || (variantType == "SNP" && newEnd == newPosition) else { continue }
            let effectiveEnd = max(newPosition + 1, newEnd)

            sqlite3_reset(insertVariantStmt)
            variantDBBindText(insertVariantStmt, 1, targetChrom)
            sqlite3_bind_int64(insertVariantStmt, 2, Int64(newPosition))
            sqlite3_bind_int64(insertVariantStmt, 3, Int64(effectiveEnd))
            variantDBBindText(insertVariantStmt, 4, variantID)
            variantDBBindText(insertVariantStmt, 5, ref)
            variantDBBindText(insertVariantStmt, 6, alt)
            variantDBBindText(insertVariantStmt, 7, variantType)
            if let q = quality {
                sqlite3_bind_double(insertVariantStmt, 8, q)
            } else {
                sqlite3_bind_null(insertVariantStmt, 8)
            }
            if let f = filter {
                variantDBBindText(insertVariantStmt, 9, f)
            } else {
                sqlite3_bind_null(insertVariantStmt, 9)
            }
            if let info {
                variantDBBindText(insertVariantStmt, 10, info)
            } else {
                sqlite3_bind_null(insertVariantStmt, 10)
            }
            // Set zero first, then update after genotype filtering.
            sqlite3_bind_int(insertVariantStmt, 11, 0)

            guard sqlite3_step(insertVariantStmt) == SQLITE_DONE else { continue }
            let newVariantId = sqlite3_last_insert_rowid(destDB)
            insertCount += 1

            // Track source-to-dest ID mapping for variant_info copy
            sourceToDestVariantIds.append((sourceVariantId, newVariantId))

            // Copy genotypes (filtered by sample if requested)
            let genotypes = self.genotypes(forVariantId: sourceVariantId)
            var insertedGenotypeCount = 0
            for gt in genotypes {
                if let filter = sampleFilter, !filter.contains(gt.sampleName) { continue }

                sqlite3_reset(insertGenotypeStmt)
                sqlite3_bind_int64(insertGenotypeStmt, 1, newVariantId)
                variantDBBindText(insertGenotypeStmt, 2, gt.sampleName)
                if let g = gt.genotype {
                    variantDBBindText(insertGenotypeStmt, 3, g)
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 3)
                }
                sqlite3_bind_int(insertGenotypeStmt, 4, Int32(gt.allele1))
                sqlite3_bind_int(insertGenotypeStmt, 5, Int32(gt.allele2))
                sqlite3_bind_int(insertGenotypeStmt, 6, gt.isPhased ? 1 : 0)
                if let d = gt.depth {
                    sqlite3_bind_int(insertGenotypeStmt, 7, Int32(d))
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 7)
                }
                if let gq = gt.genotypeQuality {
                    sqlite3_bind_int(insertGenotypeStmt, 8, Int32(gq))
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 8)
                }
                if let ad = gt.alleleDepths {
                    variantDBBindText(insertGenotypeStmt, 9, ad)
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 9)
                }
                if let rf = gt.rawFields {
                    variantDBBindText(insertGenotypeStmt, 10, rf)
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 10)
                }
                if sqlite3_step(insertGenotypeStmt) == SQLITE_DONE {
                    insertedGenotypeCount += 1
                    samplesWithGenotypes.insert(gt.sampleName)
                }
            }

            // Keep sample_count consistent with filtered genotype rows in extracted DB.
            sqlite3_reset(updateSampleCountStmt)
            sqlite3_bind_int(updateSampleCountStmt, 1, Int32(insertedGenotypeCount))
            sqlite3_bind_int64(updateSampleCountStmt, 2, newVariantId)
            _ = sqlite3_step(updateSampleCountStmt)
        }

        // Copy variant_info EAV entries for extracted variants
        let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
        var insertInfoStmt: OpaquePointer?
        if sqlite3_prepare_v2(destDB, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK {
            for (sourceId, newId) in sourceToDestVariantIds {
                let infoVals = self.infoValues(variantId: sourceId)
                for (key, value) in infoVals {
                    sqlite3_reset(insertInfoStmt)
                    sqlite3_bind_int64(insertInfoStmt, 1, newId)
                    variantDBBindText(insertInfoStmt, 2, key)
                    variantDBBindText(insertInfoStmt, 3, value)
                    sqlite3_step(insertInfoStmt)
                }
            }
        }
        sqlite3_finalize(insertInfoStmt)

        // Copy variant_info_defs from source
        let insertInfoDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, ?, ?, ?)"
        var insertInfoDefStmt: OpaquePointer?
        if sqlite3_prepare_v2(destDB, insertInfoDefSQL, -1, &insertInfoDefStmt, nil) == SQLITE_OK {
            for def in self.infoKeys() {
                sqlite3_reset(insertInfoDefStmt)
                variantDBBindText(insertInfoDefStmt, 1, def.key)
                variantDBBindText(insertInfoDefStmt, 2, def.type)
                variantDBBindText(insertInfoDefStmt, 3, def.number)
                variantDBBindText(insertInfoDefStmt, 4, def.description)
                sqlite3_step(insertInfoDefStmt)
            }
        }
        sqlite3_finalize(insertInfoDefStmt)

        // Insert sample records (preserve display/source/metadata fields when available).
        let sampleNamesToCopy: [String] = {
            if let sampleFilter {
                return sampleFilter.sorted()
            }
            return sampleNames()
        }()

        let insertSampleSQL = """
        INSERT OR REPLACE INTO samples (name, display_name, source_file, metadata)
        VALUES (?, ?, ?, ?)
        """
        var insertSampleStmt: OpaquePointer?
        let selectSampleSQL = "SELECT name, display_name, source_file, metadata FROM samples WHERE name = ?"
        var selectSampleStmt: OpaquePointer?
        if sqlite3_prepare_v2(destDB, insertSampleSQL, -1, &insertSampleStmt, nil) == SQLITE_OK,
           sqlite3_prepare_v2(sourceDB, selectSampleSQL, -1, &selectSampleStmt, nil) == SQLITE_OK {
            for name in sampleNamesToCopy {
                sqlite3_reset(selectSampleStmt)
                variantDBBindText(selectSampleStmt, 1, name)

                var resolvedName = name
                var displayName: String?
                var sourceFile: String?
                var metadataJSON: String?
                if sqlite3_step(selectSampleStmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(selectSampleStmt, 0) { resolvedName = String(cString: c) }
                    if let c = sqlite3_column_text(selectSampleStmt, 1) { displayName = String(cString: c) }
                    if let c = sqlite3_column_text(selectSampleStmt, 2) { sourceFile = String(cString: c) }
                    if let c = sqlite3_column_text(selectSampleStmt, 3) { metadataJSON = String(cString: c) }
                }

                sqlite3_reset(insertSampleStmt)
                variantDBBindText(insertSampleStmt, 1, resolvedName)
                variantDBBindTextOrNull(insertSampleStmt, 2, displayName)
                variantDBBindTextOrNull(insertSampleStmt, 3, sourceFile)
                variantDBBindTextOrNull(insertSampleStmt, 4, metadataJSON)
                sqlite3_step(insertSampleStmt)
            }
        }
        sqlite3_finalize(selectSampleStmt)
        sqlite3_finalize(insertSampleStmt)

        try Self.executeSQLite(destDB, "COMMIT", context: "extractRegion commit")

        for (name, sql) in Self.allIndexStatements {
            try Self.createRequiredIndex(db: destDB, name: name, sql: sql, context: "extractRegion")
        }
        try Self.requireMetadataRow(
            destDB,
            key: "import_variant_count",
            value: "\(insertCount)",
            replace: true,
            context: "extractRegion"
        )
        try Self.requireMetadataRow(
            destDB,
            key: "import_state",
            value: "complete",
            replace: true,
            context: "extractRegion"
        )

        variantDBLogger.info("extractRegion: Extracted \(insertCount) variants (\(samplesWithGenotypes.count) samples with genotypes) from \(chromosome):\(start)-\(end)")
        return insertCount
    }

    // MARK: - VCF Line Streaming

    /// Reads chromosome IDs from VCF `##contig` header lines without scanning the full file.
    ///
    /// Returns an ordered unique list of contig IDs. If the file has no usable
    /// `##contig` metadata, returns an empty array.
    static func readContigsFromVCFHeader(
        url: URL,
        maxChromosomes: Int = 512
    ) throws -> [String] {
        @inline(__always)
        func parseHeaderLine(
            _ line: String,
            ordered: inout [String],
            seen: inout Set<String>
        ) -> Bool {
            if line.hasPrefix("#CHROM") {
                return false
            }
            if line.hasPrefix("##contig="),
               let contigID = parseContigID(fromContigHeaderLine: line),
               seen.insert(contigID).inserted {
                ordered.append(contigID)
                if ordered.count >= maxChromosomes {
                    // Too many contigs for practical per-chromosome replay.
                    return false
                }
            } else if !line.hasPrefix("#") {
                // First variant row reached before #CHROM (malformed header); stop.
                return false
            }
            return true
        }

        var ordered: [String] = []
        var seen = Set<String>()
        let ext = url.pathExtension.lowercased()

        if ext == "gz" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            let fileHandle = pipe.fileHandleForReading
            defer {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }

            var buffer = Data()
            var keepReading = true
            while keepReading {
                let chunk = fileHandle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                buffer.append(chunk)

                var lineStart = buffer.startIndex
                while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) {
                    let lineData = buffer[lineStart..<newlineIdx]
                    let line = String(decoding: lineData, as: UTF8.self)
                    keepReading = parseHeaderLine(line, ordered: &ordered, seen: &seen)
                    lineStart = buffer.index(after: newlineIdx)
                    if !keepReading { break }
                }
                if lineStart > buffer.startIndex {
                    buffer.removeSubrange(..<lineStart)
                }
            }
            return ordered
        }

        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw VariantDatabaseError.createFailed("Cannot open VCF file: \(url.lastPathComponent)")
        }
        defer { fileHandle.closeFile() }

        var buffer = Data()
        var keepReading = true
        while keepReading {
            let chunk = fileHandle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) {
                let lineData = buffer[lineStart..<newlineIdx]
                let line = String(decoding: lineData, as: UTF8.self)
                keepReading = parseHeaderLine(line, ordered: &ordered, seen: &seen)
                lineStart = buffer.index(after: newlineIdx)
                if !keepReading { break }
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(..<lineStart)
            }
        }
        return ordered
    }

    /// Parses a contig ID from a VCF `##contig=<...>` header line.
    static func parseContigID(fromContigHeaderLine line: String) -> String? {
        guard line.hasPrefix("##contig=") else { return nil }
        let payload = line.dropFirst(9)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !payload.isEmpty else { return nil }

        for part in payload.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.caseInsensitiveCompare("ID") == .orderedSame {
                let raw = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Streams lines from a plain-text VCF file using buffered I/O.
    ///
    /// Avoids loading the entire file into memory, which can fail for multi-GB VCFs.
    /// Reports byte-level progress when `totalFileSize` is provided.
    static func streamPlainLines(
        url: URL,
        totalFileSize: Int64 = 0,
        shouldCancel: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        _ handler: (Substring) -> Void
    ) throws -> Bool {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw VariantDatabaseError.createFailed("Cannot open VCF file: \(url.lastPathComponent)")
        }
        defer { fh.closeFile() }

        var buffer = Data()
        var bytesRead: Int64 = 0
        var lastProgress = -1.0
        var lastEmitTime = Date.distantPast
        var cancelled = false
        let chunkSize = 256 * 1024  // 256 KB read chunks
        while true {
            if shouldCancel?() == true {
                cancelled = true
                break
            }
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            if totalFileSize > 0 {
                emitThrottledProgress(
                    Double(bytesRead) / Double(totalFileSize),
                    onProgress: onProgress,
                    lastProgress: &lastProgress,
                    lastEmitTime: &lastEmitTime
                )
            }

            // Parse all complete lines in-buffer, then drop the consumed prefix once.
            var lineStart = buffer.startIndex
            while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) {
                autoreleasepool {
                    let lineData = buffer[lineStart..<newlineIdx]
                    let line = String(decoding: lineData, as: UTF8.self)
                    handler(Substring(line))
                }
                lineStart = buffer.index(after: newlineIdx)
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(..<lineStart)
            }
        }

        if !cancelled, !buffer.isEmpty {
            autoreleasepool {
                let tail = String(decoding: buffer, as: UTF8.self)
                handler(Substring(tail))
            }
        }

        if !cancelled, totalFileSize > 0 {
            emitThrottledProgress(
                1.0,
                onProgress: onProgress,
                lastProgress: &lastProgress,
                lastEmitTime: &lastEmitTime
            )
        }
        return cancelled
    }

    /// Streams lines from a gzip-compressed VCF using `gzip -dc`.
    ///
    /// Reports approximate progress based on decompressed bytes vs estimated uncompressed size.
    static func streamGzipLines(
        url: URL,
        estimatedUncompressedSize: Int64 = 0,
        shouldCancel: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        _ handler: (Substring) -> Void
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let fileHandle = pipe.fileHandleForReading
        var buffer = Data()
        var bytesRead: Int64 = 0
        var lastProgress = -1.0
        var lastEmitTime = Date.distantPast
        var cancelled = false
        while true {
            if shouldCancel?() == true {
                cancelled = true
                process.terminate()
                break
            }
            let chunk = fileHandle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            if estimatedUncompressedSize > 0 {
                emitThrottledProgress(
                    Double(bytesRead) / Double(estimatedUncompressedSize),
                    onProgress: onProgress,
                    lastProgress: &lastProgress,
                    lastEmitTime: &lastEmitTime
                )
            }

            var lineStart = buffer.startIndex
            while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) { // "\n"
                autoreleasepool {
                    let lineData = buffer[lineStart..<newlineIdx]
                    let line = String(decoding: lineData, as: UTF8.self)
                    handler(Substring(line))
                }
                lineStart = buffer.index(after: newlineIdx)
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(..<lineStart)
            }
        }

        if !cancelled, !buffer.isEmpty {
            autoreleasepool {
                let tail = String(decoding: buffer, as: UTF8.self)
                handler(Substring(tail))
            }
        }

        if !cancelled, estimatedUncompressedSize > 0 {
            emitThrottledProgress(
                1.0,
                onProgress: onProgress,
                lastProgress: &lastProgress,
                lastEmitTime: &lastEmitTime
            )
        }

        process.waitUntilExit()
        if !cancelled, process.terminationStatus != 0 {
            throw VariantDatabaseError.createFailed("Failed to decompress \(url.lastPathComponent) (gzip exit code \(process.terminationStatus))")
        }
        return cancelled
    }

    /// Estimates uncompressed size for a gzip file using ISIZE footer with heuristic fallback.
    static func estimateGzipUncompressedSize(url: URL, compressedSize: Int64) -> Int64 {
        let fallback = max(1, compressedSize * 8)
        guard compressedSize >= 4, let fh = FileHandle(forReadingAtPath: url.path) else {
            return fallback
        }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: UInt64(compressedSize - 4))
        let footer = fh.readData(ofLength: 4)
        guard footer.count == 4 else { return fallback }

        let bytes = [UInt8](footer)
        let isize = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        // Sanity check: ISIZE is uint32 so wraps at 4 GB, and bgzip multi-member
        // files report only the last member's size. If the footer value is smaller
        // than the compressed size, it's almost certainly wrong for text data —
        // fall back to the heuristic.
        guard isize > 0 else { return fallback }
        let estimate = Int64(isize)
        return estimate >= compressedSize ? estimate : fallback
    }

    /// Emits progress updates with simple coalescing to avoid flooding UI callbacks.
    static func emitThrottledProgress(
        _ rawProgress: Double,
        onProgress: ((Double) -> Void)?,
        lastProgress: inout Double,
        lastEmitTime: inout Date
    ) {
        guard let onProgress else { return }
        let progress = max(0.0, min(1.0, rawProgress))
        let now = Date()
        let shouldEmit =
            lastProgress < 0 ||
            progress >= 1.0 ||
            (progress - lastProgress) >= 0.01 ||
            now.timeIntervalSince(lastEmitTime) >= 0.15
        guard shouldEmit else { return }
        lastProgress = max(lastProgress, progress)
        lastEmitTime = now
        onProgress(lastProgress)
    }

}
