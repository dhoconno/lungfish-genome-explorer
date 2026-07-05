// VariantDatabase+CreateFromVCF.swift - VCF to SQLite variant database import
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    static func resolveImportProfile(_ requested: VCFImportProfile, inputFileSize: Int64) -> VCFImportProfile {
        guard requested == .auto else { return requested }
        let physicalRAMGiB = Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)
        let inputGiB = Double(max(0, inputFileSize)) / Double(1 << 30)
        // Very large files or large-ish files on limited RAM: ultra-low-memory with
        // upfront indexes to avoid multi-GB sorts during post-insert index creation.
        if inputGiB >= 5.0 || (inputGiB >= 2.0 && physicalRAMGiB <= 16) {
            return .ultraLowMemory
        }
        if physicalRAMGiB <= 12 || inputGiB >= 1.5 {
            return .lowMemory
        }
        return .fast
    }

    /// All index statements used by `createFromVCF`, ordered from cheapest to most
    /// expensive.  The ordering ensures that if index creation is interrupted, the
    /// most important indexes (variants region) will already exist.
    static let allIndexStatements: [(name: String, sql: String)] = [
        ("idx_variants_region", "CREATE INDEX IF NOT EXISTS idx_variants_region ON variants(chromosome, position, end_pos)"),
        ("idx_variants_type", "CREATE INDEX IF NOT EXISTS idx_variants_type ON variants(variant_type)"),
        ("idx_variants_id", "CREATE INDEX IF NOT EXISTS idx_variants_id ON variants(variant_id COLLATE NOCASE)"),
        ("idx_samples_name", "CREATE INDEX IF NOT EXISTS idx_samples_name ON samples(name)"),
        ("idx_genotypes_variant", "CREATE INDEX IF NOT EXISTS idx_genotypes_variant ON genotypes(variant_id)"),
        ("idx_genotypes_sample", "CREATE INDEX IF NOT EXISTS idx_genotypes_sample ON genotypes(sample_name)"),
        ("idx_variant_info_key", "CREATE INDEX IF NOT EXISTS idx_variant_info_key ON variant_info(key)"),
        ("idx_variant_info_key_value", "CREATE INDEX IF NOT EXISTS idx_variant_info_key_value ON variant_info(key, value)"),
    ]

    static func importTuning(for profile: VCFImportProfile) -> ImportTuning {
        switch profile {
        case .lowMemory:
            return ImportTuning(
                workerThreads: 1,
                cacheKB: 4 * 1024,
                pageSizeKB: 4,
                writeBudget: 8_000,
                minWriteBudget: 2_000,
                shrinkEveryCommits: 1,
                shrinkEveryCommit: true,
                memoryProbeVariantInterval: 5_000,
                memoryPressureThresholdFraction: 0.62,
                memoryPressureRelaxFraction: 0.42,
                createIndexesUpFront: false,
                maxVariantInfoKeysPerVariant: 0,
                skipVariantInfo: false,
                connectionResetInterval: 0
            )
        case .fast:
            return ImportTuning(
                workerThreads: max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)),
                cacheKB: 32 * 1024,
                pageSizeKB: 4,
                writeBudget: 80_000,
                minWriteBudget: 8_000,
                shrinkEveryCommits: 6,
                shrinkEveryCommit: false,
                memoryProbeVariantInterval: 10_000,
                memoryPressureThresholdFraction: 0.70,
                memoryPressureRelaxFraction: 0.50,
                createIndexesUpFront: false,
                maxVariantInfoKeysPerVariant: 0,
                skipVariantInfo: false,
                connectionResetInterval: 0
            )
        case .ultraLowMemory:
            // Designed for multi-GB VCFs that produce 50GB+ databases.
            // Key differences from other profiles:
            //  - NO indexes during insert (deferred to a separate phase/process)
            //  - NO variant_info EAV table (raw INFO stored in variants.info)
            //  - synchronous = NORMAL to prevent dirty page accumulation in macOS UBC
            //  - Periodic connection reset to fight malloc fragmentation
            //  - 32KB page size to reduce B-tree depth
            //  - Large write budget (no index overhead = fast commits)
            return ImportTuning(
                workerThreads: 1,
                cacheKB: 4 * 1024,
                pageSizeKB: 32,
                writeBudget: 12_000,
                minWriteBudget: 1_500,
                shrinkEveryCommits: 1,
                shrinkEveryCommit: true,
                memoryProbeVariantInterval: 2_000,
                memoryPressureThresholdFraction: 0.55,
                memoryPressureRelaxFraction: 0.38,
                createIndexesUpFront: false,
                maxVariantInfoKeysPerVariant: 0,
                skipVariantInfo: true,
                connectionResetInterval: 2_000_000
            )
        case .auto:
            // Auto is resolved before this method is called.
            return importTuning(for: .lowMemory)
        }
    }

    /// Optionally parses per-sample genotypes.
    ///
    /// - Parameters:
    ///   - vcfURL: URL to the VCF file (plain text or .vcf.gz)
    ///   - outputURL: URL for the SQLite database to create
    ///   - parseGenotypes: If true, parse and store per-sample genotype data
    ///   - sourceFile: Optional source filename to store in the samples table
    ///   - progressHandler: Optional progress callback (fraction, message)
    /// - Returns: Number of variant records inserted
    @discardableResult
    public static func createFromVCF(
        vcfURL: URL,
        outputURL: URL,
        parseGenotypes: Bool = true,
        sourceFile: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        importSemantics: VCFImportSemantics = .standard,
        importProfile: VCFImportProfile = .auto,
        deferIndexBuild: Bool = false,
        partitionByChromosome: Bool = false,
        onlyChromosome: String? = nil
    ) throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

        let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: vcfURL.path)[.size] as? Int64) ?? 0
        let ext = vcfURL.pathExtension.lowercased()
        let estimatedUncompressedSize = ext == "gz"
            ? estimateGzipUncompressedSize(url: vcfURL, compressedSize: fileSize)
            : 0
        // For compressed VCFs, profile auto-selection should use an estimate of the
        // real parse workload instead of the smaller compressed byte size.
        let profileInputSize = (ext == "gz" && estimatedUncompressedSize > 0)
            ? estimatedUncompressedSize
            : fileSize
        let resolvedProfile = resolveImportProfile(importProfile, inputFileSize: profileInputSize)
        let tuning = importTuning(for: resolvedProfile)

        var db: OpaquePointer?
        let rc = sqlite3_open(outputURL.path, &db)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Performance pragmas — FK enforcement OFF during bulk import (we control insert order;
        // variants are always inserted before genotypes). Enabling FKs here would force SQLite to
        // validate every genotype INSERT against the variants table, adding significant overhead.

        // page_size MUST be set before any tables are created. A larger page size (32KB) reduces
        // B-tree depth by 1-2 levels, which means fewer pages pinned simultaneously during inserts.
        if tuning.pageSizeKB != 4 {
            sqlite3_exec(db, "PRAGMA page_size = \(tuning.pageSizeKB * 1024)", nil, nil, nil)
        }

        // DELETE journal mode provides crash recovery (unlike OFF) without accumulating dirty
        // pages in the macOS Unified Buffer Cache (UBC) the way WAL mode does.  WAL defers
        // writing back to the main DB file, causing the UBC to count those dirty pages against
        // the process RSS — leading to OOM kills on multi-GB imports.  DELETE mode writes
        // directly to the main DB file on each COMMIT.
        sqlite3_exec(db, "PRAGMA journal_mode = DELETE", nil, nil, nil)
        // synchronous = NORMAL forces fsync at each COMMIT, which prevents dirty page accumulation
        // in the macOS Unified Buffer Cache (UBC). With synchronous = OFF on multi-hour imports,
        // the UBC can accumulate tens of GB of dirty pages that the jetsam OOM killer counts
        // against the process, leading to SIGKILL.  NORMAL adds ~5% overhead but bounds memory.
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA threads = \(tuning.workerThreads)", nil, nil, nil)

        sqlite3_exec(db, "PRAGMA cache_size = -\(tuning.cacheKB)", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_spill = ON", nil, nil, nil)
        // Disable memory-mapped I/O — as the DB file grows during import, an mmap region would
        // inflate RSS proportionally. Standard read/write I/O with the small cache above is fine.
        sqlite3_exec(db, "PRAGMA mmap_size = 0", nil, nil, nil)
        // temp_store = FILE (default) — index-building sorts spill to disk instead of consuming
        // unbounded RAM. On SSD the speed penalty is negligible; on low-memory machines this
        // prevents the 8 post-import CREATE INDEX statements from exhausting physical memory.
        sqlite3_exec(db, "PRAGMA temp_store = FILE", nil, nil, nil)

        // Create v3 schema
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
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw VariantDatabaseError.createFailed(msg)
        }

        // Insert metadata flags for v3 import optimizations.
        Self.insertMetadataRow(db, key: "schema_version", value: "3")
        Self.insertMetadataRow(db, key: "omit_homref", value: "true")
        Self.insertMetadataRow(db, key: "import_state", value: "inserting")
        Self.insertMetadataRow(db, key: "import_source", value: vcfURL.lastPathComponent)
        Self.insertMetadataRow(db, key: "import_semantics", value: importSemantics.rawValue)
        Self.insertMetadataRow(db, key: "import_profile", value: resolvedProfile.rawValue)
        if tuning.skipVariantInfo {
            Self.insertMetadataRow(db, key: "skip_variant_info", value: "true")
        }

        // For ultra-low-memory profile: cap SQLite heap and create indexes upfront so
        // they are maintained incrementally during inserts, avoiding multi-GB sorts.
        if resolvedProfile == .ultraLowMemory {
            sqlite3_soft_heap_limit64(256 * 1024 * 1024)
        }

        if tuning.createIndexesUpFront {
            for (name, sql) in Self.allIndexStatements {
                try Self.createRequiredIndex(db: db, name: name, sql: sql, context: "createFromVCF upfront")
            }
            variantDBLogger.info("createFromVCF: Created \(Self.allIndexStatements.count) indexes upfront for incremental maintenance")
        }

        var txnErr: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &txnErr)
        if let txnErr {
            let msg = String(cString: txnErr)
            sqlite3_free(txnErr)
            variantDBLogger.warning("createFromVCF: BEGIN TRANSACTION failed: \(msg)")
        }

        let insertVariantSQL = """
        INSERT INTO variants (chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertVariantStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertVariantSQL, -1, &insertVariantStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare variant INSERT statement")
        }
        defer { sqlite3_finalize(insertVariantStmt) }

        let insertGenotypeSQL = """
        INSERT INTO genotypes (variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertGenotypeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertGenotypeSQL, -1, &insertGenotypeStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare genotype INSERT statement")
        }
        defer { sqlite3_finalize(insertGenotypeStmt) }

        let insertSampleSQL = "INSERT OR IGNORE INTO samples (name, display_name, source_file, metadata) VALUES (?, ?, ?, '{}')"
        var insertSampleStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSampleSQL, -1, &insertSampleStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample INSERT statement")
        }
        defer { sqlite3_finalize(insertSampleStmt) }

        // variant_info statements are only needed when NOT skipping variant_info.
        // For ultraLowMemory, we skip the EAV table entirely and store raw INFO in variants.info.
        var insertInfoDefStmt: OpaquePointer?
        var insertInfoStmt: OpaquePointer?
        if !tuning.skipVariantInfo {
            let insertInfoDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, insertInfoDefSQL, -1, &insertInfoDefStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare info def INSERT statement")
            }

            let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(db, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare info INSERT statement")
            }
        }
        defer {
            sqlite3_finalize(insertInfoDefStmt)
            sqlite3_finalize(insertInfoStmt)
        }

        let updateSampleCountSQL = "UPDATE variants SET sample_count = ? WHERE id = ?"
        var updateSampleCountStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSampleCountSQL, -1, &updateSampleCountStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample_count UPDATE statement")
        }
        defer { sqlite3_finalize(updateSampleCountStmt) }

        var insertCount = 0
        var sampleNames: [String] = []
        var adaptiveWriteBudget = tuning.writeBudget
        let adaptiveWriteBudgetStep = max(500, tuning.writeBudget / 10)
        let shrinkEveryCommits = max(1, tuning.shrinkEveryCommits)
        var wasCancelled = false
        var writesSinceCommit = 0
        var transactionCommitCount = 0

        // Track all structured INFO fields with pipe-delimited sub-fields (key → sub-field names)
        var structuredInfoFields: [String: [String]] = [:]

        // Collect contig lengths from ##contig header lines for chromosome alias mapping
        var contigLengths: [String: Int64] = [:]

        let profileLabel: String = switch resolvedProfile {
        case .lowMemory: "Low Memory"
        case .fast: "Fast"
        case .auto: "Auto"
        case .ultraLowMemory: "Ultra Low Memory"
        }
        progressHandler?(0.05, "Parsing VCF (\(profileLabel) profile)...")

        @inline(__always)
        func isCancelled() -> Bool {
            shouldCancel?() == true
        }

        @inline(__always)
        func releaseSQLiteMemory(forceShrink: Bool = false) {
            _ = sqlite3_db_release_memory(db)
            if forceShrink {
                sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)
            }
        }

        /// Adaptive memory-pressure controller:
        /// - Force COMMIT+shrink when RSS crosses a high watermark.
        /// - Reduce write budget under pressure (more frequent commits).
        /// - Gradually relax budget once RSS drops.
        func memoryPressureFlush() {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return }
            let residentBytes = UInt64(info.resident_size)
            let physicalRAM = ProcessInfo.processInfo.physicalMemory
            let highThreshold = UInt64(Double(physicalRAM) * tuning.memoryPressureThresholdFraction)
            let relaxThreshold = UInt64(Double(physicalRAM) * tuning.memoryPressureRelaxFraction)

            if residentBytes > highThreshold {
                adaptiveWriteBudget = max(tuning.minWriteBudget, adaptiveWriteBudget / 2)
                commitImportTransaction(reopen: true, forceShrink: true)
                variantDBLogger.warning(
                    "createFromVCF: Memory pressure (resident \(residentBytes / (1024 * 1024)) MB / \(physicalRAM / (1024 * 1024)) MB), budget=\(adaptiveWriteBudget), forced commit+shrink"
                )
                return
            }

            if residentBytes < relaxThreshold, adaptiveWriteBudget < tuning.writeBudget {
                adaptiveWriteBudget = min(tuning.writeBudget, adaptiveWriteBudget + adaptiveWriteBudgetStep)
            }
        }

        func commitImportTransaction(reopen: Bool, forceShrink: Bool = false) {
            var commitErr: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, "COMMIT", nil, nil, &commitErr)
            if let commitErr {
                let msg = String(cString: commitErr)
                sqlite3_free(commitErr)
                variantDBLogger.warning("createFromVCF: COMMIT failed: \(msg), issuing ROLLBACK")
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }

            transactionCommitCount += 1
            writesSinceCommit = 0
            let shouldShrinkNow =
                forceShrink ||
                tuning.shrinkEveryCommit ||
                (transactionCommitCount % shrinkEveryCommits == 0)
            releaseSQLiteMemory(forceShrink: shouldShrinkNow)

            if reopen {
                var beginErr: UnsafeMutablePointer<CChar>?
                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &beginErr)
                if let beginErr {
                    let msg = String(cString: beginErr)
                    sqlite3_free(beginErr)
                    variantDBLogger.warning("createFromVCF: BEGIN TRANSACTION failed: \(msg)")
                }
            }
        }

        @inline(__always)
        func rotateImportTransactionIfNeeded() {
            guard writesSinceCommit >= adaptiveWriteBudget else { return }
            commitImportTransaction(reopen: true)
        }

        let maxPartitionChromosomes = 512

        @inline(__always)
        func streamVCFLines(
            onProgress: ((Double) -> Void)? = nil,
            _ handler: (Substring) -> Void
        ) throws -> Bool {
            if ext == "gz" {
                return try streamGzipLines(
                    url: vcfURL,
                    estimatedUncompressedSize: estimatedUncompressedSize,
                    shouldCancel: shouldCancel,
                    onProgress: onProgress,
                    handler
                )
            }
            return try streamPlainLines(
                url: vcfURL,
                totalFileSize: fileSize,
                shouldCancel: shouldCancel,
                onProgress: onProgress,
                handler
            )
        }

        func parseLine(
            _ line: Substring,
            parseHeaders: Bool,
            activeChromosome: String?
        ) {
            guard !line.isEmpty, !wasCancelled else { return }

            if line.first == "#" {
                guard parseHeaders else { return }

                // Parse ##INFO=<...> header lines for structured INFO definitions
                if line.hasPrefix("##INFO=") {
                    // When skipping variant_info, we don't need to parse or store INFO defs
                    if !tuning.skipVariantInfo, let insertInfoDefStmt {
                        let content = line.dropFirst(7)
                        if let def = parseINFODefinition(content) {
                            sqlite3_reset(insertInfoDefStmt)
                            variantDBBindText(insertInfoDefStmt, 1, def.id)
                            variantDBBindText(insertInfoDefStmt, 2, def.type)
                            variantDBBindText(insertInfoDefStmt, 3, def.number)
                            variantDBBindText(insertInfoDefStmt, 4, def.description)
                            sqlite3_step(insertInfoDefStmt)
                            writesSinceCommit += 1

                            // Detect structured fields with pipe-delimited sub-fields from Description
                            // e.g., CSQ: "...Format: Allele|Consequence|IMPACT|SYMBOL|Gene|..."
                            if let formatRange = def.description.range(of: "Format: ", options: .caseInsensitive) {
                                let formatStr = String(def.description[formatRange.upperBound...])
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                                let subFields = formatStr.split(separator: "|").map(String.init)
                                if subFields.count >= 2 {
                                    structuredInfoFields[def.id] = subFields
                                    // Register each sub-field as a separate info def
                                    for subField in subFields {
                                        let subKey = "\(def.id)_\(subField)"
                                        sqlite3_reset(insertInfoDefStmt)
                                        variantDBBindText(insertInfoDefStmt, 1, subKey)
                                        variantDBBindText(insertInfoDefStmt, 2, "String")
                                        variantDBBindText(insertInfoDefStmt, 3, ".")
                                        variantDBBindText(insertInfoDefStmt, 4, "\(def.id) sub-field: \(subField)")
                                        sqlite3_step(insertInfoDefStmt)
                                        writesSinceCommit += 1
                                    }
                                    variantDBLogger.info("createFromVCF: Found structured INFO field '\(def.id)' with \(subFields.count) sub-fields")
                                }
                            }
                        }
                        rotateImportTransactionIfNeeded()
                    }
                    return
                }

                // Parse ##contig=<ID=...,length=...> lines for chromosome length info
                if line.hasPrefix("##contig=") {
                    let content = line.dropFirst(9)
                    // Parse <ID=chr1,length=248956422> format
                    let inner = content.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    var id: String?
                    var length: Int64?
                    for part in inner.split(separator: ",") {
                        let kv = part.split(separator: "=", maxSplits: 1)
                        guard kv.count == 2 else { continue }
                        let key = kv[0].trimmingCharacters(in: .whitespaces)
                        let val = kv[1].trimmingCharacters(in: .whitespaces)
                        if key.lowercased() == "id" { id = val }
                        else if key.lowercased() == "length" { length = Int64(val) }
                    }
                    if let id, let length {
                        contigLengths[id] = length
                    }
                    return
                }

                // Skip other meta-information lines
                if line.hasPrefix("##") { return }

                // Parse header line for sample names
                if line.hasPrefix("#CHROM") {
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    let srcFile = sourceFile ?? vcfURL.lastPathComponent
                    if fields.count > 9 {
                        sampleNames = fields.dropFirst(9).map(String.init)
                        // Insert sample records
                        for sampleName in sampleNames {
                            sqlite3_reset(insertSampleStmt)
                            variantDBBindText(insertSampleStmt, 1, sampleName)
                            variantDBBindText(insertSampleStmt, 2, sampleName)
                            variantDBBindText(insertSampleStmt, 3, srcFile)
                            sqlite3_step(insertSampleStmt)
                            writesSinceCommit += 1
                        }
                        variantDBLogger.info("createFromVCF: Found \(sampleNames.count) samples")
                    } else {
                        switch importSemantics {
                        case .standard:
                            // No sample columns (e.g. LoFreq) — create a synthetic sample
                            // using the VCF filename so multi-file merges can be tracked.
                            let syntheticName = URL(fileURLWithPath: srcFile).deletingPathExtension().lastPathComponent
                            sampleNames = [syntheticName]
                            sqlite3_reset(insertSampleStmt)
                            variantDBBindText(insertSampleStmt, 1, syntheticName)
                            variantDBBindText(insertSampleStmt, 2, syntheticName)
                            variantDBBindText(insertSampleStmt, 3, srcFile)
                            sqlite3_step(insertSampleStmt)
                            writesSinceCommit += 1
                            variantDBLogger.info("createFromVCF: No sample columns — created synthetic sample '\(syntheticName, privacy: .public)'")
                        case .viralFrequency:
                            sampleNames = []
                            variantDBLogger.info("createFromVCF: No sample columns — preserving sample-less viral import semantics")
                        }
                    }

                    // Store contig lengths from ##contig header lines for chromosome alias mapping.
                    // These provide exact chromosome lengths for reliable matching when VCF chromosome
                    // names differ from the reference (e.g., "1" vs "NC_048383.1").
                    if !contigLengths.isEmpty {
                        if let jsonData = try? JSONSerialization.data(withJSONObject: contigLengths.mapValues { NSNumber(value: $0) }),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            Self.insertMetadataRow(db, key: "contig_lengths", value: jsonString, replace: true)
                            writesSinceCommit += 1
                            variantDBLogger.info("createFromVCF: Stored \(contigLengths.count) contig lengths from VCF header")
                        }
                    }

                    rotateImportTransactionIfNeeded()
                    return
                }

                return
            }

            // Parse variant line
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 8 else { return }

            let chromosome = String(fields[0])
            if let activeChromosome, chromosome != activeChromosome {
                return
            }
            guard let pos1based = Int(fields[1]), pos1based >= 1 else { return }
            let position = pos1based - 1  // Convert to 0-based

            let rawID = fields[2]
            let variantID = rawID == "." ? "\(chromosome)_\(pos1based)" : String(rawID)

            let refField = fields[3]
            let altField = fields[4]
            let ref = String(refField)
            let alt = String(altField)
            let qualStr = fields[5]
            let quality: Double? = qualStr == "." ? nil : Double(qualStr)
            let filter = fields[6] == "." ? nil : String(fields[6])

            let variantType = classifyVariant(ref: refField, altField: altField)

            let infoField = fields[7]
            let endPos: Int
            if let endValue = parseINFOEnd(infoField) {
                endPos = endValue
            } else {
                endPos = position + ref.count
            }
            let infoStr: Substring? = fields[7] == "." ? nil : fields[7]

            // Insert variant (sample_count initially 0; updated after genotype pass).
            sqlite3_reset(insertVariantStmt)
            variantDBBindText(insertVariantStmt, 1, chromosome)
            sqlite3_bind_int64(insertVariantStmt, 2, Int64(position))
            sqlite3_bind_int64(insertVariantStmt, 3, Int64(endPos))
            variantDBBindText(insertVariantStmt, 4, variantID)
            variantDBBindText(insertVariantStmt, 5, ref)
            variantDBBindText(insertVariantStmt, 6, alt)
            variantDBBindText(insertVariantStmt, 7, variantType)
            if let q = quality {
                sqlite3_bind_double(insertVariantStmt, 8, q)
            } else {
                sqlite3_bind_null(insertVariantStmt, 8)
            }
            variantDBBindTextOrNull(insertVariantStmt, 9, filter)
            // When skipVariantInfo is true, store raw INFO string in variants.info since
            // the EAV table is not populated.  Otherwise leave NULL (redundant with EAV).
            if tuning.skipVariantInfo, let infoStr {
                variantDBBindText(insertVariantStmt, 10, String(infoStr))
            } else {
                sqlite3_bind_null(insertVariantStmt, 10)
            }
            sqlite3_bind_int(insertVariantStmt, 11, 0)

            guard sqlite3_step(insertVariantStmt) == SQLITE_DONE else {
                variantDBLogger.warning("Failed to insert variant: \(variantID)")
                return
            }
            let variantRowId = sqlite3_last_insert_rowid(db)
            insertCount += 1
            writesSinceCommit += 1

            // Periodic adaptive memory pressure check.
            if insertCount % tuning.memoryProbeVariantInterval == 0 {
                memoryPressureFlush()
            }

            // Periodic deep memory reset to fight malloc fragmentation over long imports.
            // Commits the current transaction, releases all SQLite memory, and asks the OS
            // allocator to return freed pages to the kernel.
            if tuning.connectionResetInterval > 0,
               insertCount % tuning.connectionResetInterval == 0 {
                commitImportTransaction(reopen: false, forceShrink: true)
                // On Darwin, ask all malloc zones to return freed pages to the kernel.
                // This fights heap fragmentation from billions of small alloc/free cycles.
                malloc_zone_pressure_relief(nil, 0)
                variantDBLogger.info("createFromVCF: Deep memory reset at \(insertCount) variants")
                // Reopen transaction.
                var beginErr: UnsafeMutablePointer<CChar>?
                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &beginErr)
                if let beginErr {
                    let msg = String(cString: beginErr)
                    sqlite3_free(beginErr)
                    variantDBLogger.warning("createFromVCF: BEGIN TRANSACTION after reset failed: \(msg)")
                }
            }

            // Insert structured INFO key-value pairs into variant_info EAV table.
            // Skipped entirely for ultraLowMemory — raw INFO is stored in variants.info instead.
            if !tuning.skipVariantInfo, let insertInfoStmt {
                let infoKeyLimit = tuning.maxVariantInfoKeysPerVariant
                if let infoStr, infoStr != "." {
                    var infoKeysInserted = 0
                    for field in infoStr.split(separator: ";") {
                        if infoKeyLimit > 0 && infoKeysInserted >= infoKeyLimit { break }

                        let parts = field.split(separator: "=", maxSplits: 1)
                        let key: String
                        let value: Substring
                        if parts.count == 2 {
                            key = String(parts[0])
                            value = parts[1]
                        } else if parts.count == 1 {
                            key = String(parts[0])
                            value = "true"
                        } else {
                            continue
                        }

                        // Check if this is a structured field with pipe-delimited sub-fields (e.g., CSQ)
                        if let subFieldNames = structuredInfoFields[key] {
                            // Split by comma for multiple entries (e.g., overlapping transcripts/frames)
                            // and aggregate unique values per sub-field so downstream table/hover logic
                            // can surface all possible impacts.
                            let entries = value.split(separator: ",")
                            var aggregatedByField: [String: [String]] = [:]
                            for entry in entries {
                                let subValues = entry.split(separator: "|", omittingEmptySubsequences: false)
                                for (idx, subFieldName) in subFieldNames.enumerated() {
                                    let subValue = idx < subValues.count
                                        ? String(subValues[idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                                        : ""
                                    guard !subValue.isEmpty else { continue }
                                    aggregatedByField[subFieldName, default: []].append(subValue)
                                }
                            }
                            for subFieldName in subFieldNames {
                                guard let values = aggregatedByField[subFieldName], !values.isEmpty else { continue }
                                let deduped = Self.orderedUniqueStrings(values)
                                guard !deduped.isEmpty else { continue }
                                let subKey = "\(key)_\(subFieldName)"
                                sqlite3_reset(insertInfoStmt)
                                sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                                variantDBBindText(insertInfoStmt, 2, subKey)
                                variantDBBindText(insertInfoStmt, 3, deduped.joined(separator: ","))
                                sqlite3_step(insertInfoStmt)
                                writesSinceCommit += 1
                            }
                            // Also store entry count if multiple transcripts
                            if entries.count > 1 {
                                sqlite3_reset(insertInfoStmt)
                                sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                                variantDBBindText(insertInfoStmt, 2, "\(key)_entries")
                                variantDBBindText(insertInfoStmt, 3, String(entries.count))
                                sqlite3_step(insertInfoStmt)
                                writesSinceCommit += 1
                            }
                        } else {
                            // Standard scalar INFO field
                            sqlite3_reset(insertInfoStmt)
                            sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                            variantDBBindText(insertInfoStmt, 2, key)
                            variantDBBindText(insertInfoStmt, 3, String(value))
                            sqlite3_step(insertInfoStmt)
                            writesSinceCommit += 1
                        }
                        infoKeysInserted += 1
                    }
                }
            }

            // Single-pass: parse genotypes, INSERT non-hom-ref, and count called samples.
            if parseGenotypes && fields.count > 9 && !sampleNames.isEmpty {
                let formatStr = fields[8]
                let formatFields = formatStr.split(separator: ":", omittingEmptySubsequences: false)
                let gtIndex = formatFields.firstIndex(where: { $0 == "GT" })
                let dpIndex = formatFields.firstIndex(where: { $0 == "DP" })
                let gqIndex = formatFields.firstIndex(where: { $0 == "GQ" })
                let adIndex = formatFields.firstIndex(where: { $0 == "AD" })
                var calledCount = 0

                for sampleIdx in 0..<sampleNames.count {
                    let fieldIdx = 9 + sampleIdx
                    guard fieldIdx < fields.count else { break }
                    let sampleData = fields[fieldIdx]
                    if sampleData == "." || sampleData == "./." || sampleData == ".|." { continue }

                    let sampleFields = sampleData.split(separator: ":", omittingEmptySubsequences: false)
                    if gtIndex == nil {
                        // FORMAT can omit GT for some callsets; treat non-empty sample payload as called
                        // for sample_count even though we cannot infer zygosity or hom-ref omission.
                        if sampleFields.contains(where: { !$0.isEmpty && $0 != "." }) {
                            calledCount += 1
                        }
                        continue
                    }

                    // Parse GT
                    var allele1 = -1
                    var allele2 = -1
                    var isPhased = false
                    var rawGT: String?
                    if let gtIdx = gtIndex, gtIdx < sampleFields.count {
                        let gt = sampleFields[gtIdx]
                        rawGT = String(gt)
                        let separator: Character = gt.contains("|") ? "|" : "/"
                        isPhased = separator == "|"
                        let alleles = gt.split(separator: separator)
                        if alleles.count >= 1 {
                            allele1 = alleles[0] == "." ? -1 : (Int(alleles[0]) ?? -1)
                        }
                        if alleles.count >= 2 {
                            allele2 = alleles[1] == "." ? -1 : (Int(alleles[1]) ?? -1)
                        } else if alleles.count == 1 {
                            // Haploid calls are rendered as homozygous for display purposes.
                            allele2 = allele1
                        }
                    }

                    // Count called sample (at least one non-missing allele)
                    if allele1 >= 0 || allele2 >= 0 {
                        calledCount += 1
                    } else {
                        continue  // No-call — skip genotype INSERT too
                    }

                    // Skip hom-ref genotypes (0/0) — inferred from absence.
                    // This typically eliminates ~90% of genotype rows.
                    if allele1 == 0 && allele2 == 0 { continue }

                    // Parse DP
                    var depth: Int?
                    if let dpIdx = dpIndex, dpIdx < sampleFields.count {
                        let dpStr = sampleFields[dpIdx]
                        if dpStr != "." { depth = Int(dpStr) }
                    }

                    // Parse GQ
                    var gq: Int?
                    if let gqIdx = gqIndex, gqIdx < sampleFields.count {
                        let gqStr = sampleFields[gqIdx]
                        if gqStr != "." { gq = Int(gqStr) }
                    }

                    // Parse AD
                    var ad: String?
                    if let adIdx = adIndex, adIdx < sampleFields.count {
                        let adStr = sampleFields[adIdx]
                        if adStr != "." { ad = String(adStr) }
                    }

                    sqlite3_reset(insertGenotypeStmt)
                    sqlite3_bind_int64(insertGenotypeStmt, 1, variantRowId)
                    variantDBBindText(insertGenotypeStmt, 2, sampleNames[sampleIdx])
                    variantDBBindTextOrNull(insertGenotypeStmt, 3, rawGT)
                    sqlite3_bind_int(insertGenotypeStmt, 4, Int32(allele1))
                    sqlite3_bind_int(insertGenotypeStmt, 5, Int32(allele2))
                    sqlite3_bind_int(insertGenotypeStmt, 6, isPhased ? 1 : 0)
                    if let dp = depth {
                        sqlite3_bind_int(insertGenotypeStmt, 7, Int32(dp))
                    } else {
                        sqlite3_bind_null(insertGenotypeStmt, 7)
                    }
                    if let g = gq {
                        sqlite3_bind_int(insertGenotypeStmt, 8, Int32(g))
                    } else {
                        sqlite3_bind_null(insertGenotypeStmt, 8)
                    }
                    variantDBBindTextOrNull(insertGenotypeStmt, 9, ad)
                    // v3: Don't store raw_fields (redundant with individual GT/DP/GQ/AD columns).
                    sqlite3_bind_null(insertGenotypeStmt, 10)

                    sqlite3_step(insertGenotypeStmt)
                    writesSinceCommit += 1
                }

                // Update the variant's sample_count now that we know the called count.
                if calledCount > 0 {
                    sqlite3_reset(updateSampleCountStmt)
                    sqlite3_bind_int(updateSampleCountStmt, 1, Int32(calledCount))
                    sqlite3_bind_int64(updateSampleCountStmt, 2, variantRowId)
                    sqlite3_step(updateSampleCountStmt)
                    writesSinceCommit += 1
                }
            } else if parseGenotypes && fields.count <= 9 && !sampleNames.isEmpty {
                // No-sample VCF (e.g. LoFreq): create a synthetic genotype record
                // linking this variant to the synthetic sample so sample filtering works.
                let syntheticName = sampleNames[0]
                sqlite3_reset(insertGenotypeStmt)
                sqlite3_bind_int64(insertGenotypeStmt, 1, variantRowId)
                variantDBBindText(insertGenotypeStmt, 2, syntheticName)
                sqlite3_bind_null(insertGenotypeStmt, 3)   // genotype (no GT field)
                sqlite3_bind_int(insertGenotypeStmt, 4, 1) // allele1 = alt
                sqlite3_bind_int(insertGenotypeStmt, 5, 1) // allele2 = alt
                sqlite3_bind_int(insertGenotypeStmt, 6, 0) // not phased
                sqlite3_bind_null(insertGenotypeStmt, 7)    // depth
                sqlite3_bind_null(insertGenotypeStmt, 8)    // GQ
                sqlite3_bind_null(insertGenotypeStmt, 9)    // AD
                sqlite3_bind_null(insertGenotypeStmt, 10)   // raw_fields
                sqlite3_step(insertGenotypeStmt)
                writesSinceCommit += 1

                // Set sample_count = 1
                sqlite3_reset(updateSampleCountStmt)
                sqlite3_bind_int(updateSampleCountStmt, 1, 1)
                sqlite3_bind_int64(updateSampleCountStmt, 2, variantRowId)
                sqlite3_step(updateSampleCountStmt)
                writesSinceCommit += 1
            }

            rotateImportTransactionIfNeeded()
        }

        var partitionChromosomeOrder: [String] = []
        var importedByChromosome = false

        if partitionByChromosome, onlyChromosome == nil {
            progressHandler?(0.06, "Reading chromosome list from VCF header...")
            partitionChromosomeOrder = try readContigsFromVCFHeader(
                url: vcfURL,
                maxChromosomes: maxPartitionChromosomes
            )
            if partitionChromosomeOrder.isEmpty {
                variantDBLogger.info(
                    "createFromVCF: No usable ##contig chromosome list found; falling back to single-pass import"
                )
            }
        }

        if partitionByChromosome, onlyChromosome == nil, !partitionChromosomeOrder.isEmpty {
            importedByChromosome = true
            var parseHeadersOnThisPass = true
            let totalChromosomes = partitionChromosomeOrder.count

            for (chromIndex, chromosome) in partitionChromosomeOrder.enumerated() {
                if isCancelled() {
                    wasCancelled = true
                    break
                }

                let beforeRatio = Double(chromIndex) / Double(max(1, totalChromosomes))
                let chromWeight = 1.0 / Double(max(1, totalChromosomes))
                let byteProgress: (Double) -> Void = { fraction in
                    let clamped = max(0.0, min(1.0, fraction))
                    let global = 0.15 + (beforeRatio + (chromWeight * clamped)) * 0.75
                    progressHandler?(
                        global,
                        "Importing chromosome \(chromIndex + 1) of \(totalChromosomes): \(chromosome) (\(insertCount) variants)..."
                    )
                }

                wasCancelled = try streamVCFLines(onProgress: byteProgress) { line in
                    parseLine(
                        line,
                        parseHeaders: parseHeadersOnThisPass,
                        activeChromosome: chromosome
                    )
                }
                parseHeadersOnThisPass = false
                wasCancelled = wasCancelled || isCancelled()
                if wasCancelled { break }

                let completedFraction = 0.15 + (Double(chromIndex + 1) / Double(max(1, totalChromosomes))) * 0.75
                progressHandler?(completedFraction, "Imported chromosome \(chromIndex + 1) of \(totalChromosomes): \(chromosome)")

                if chromIndex + 1 < totalChromosomes {
                    commitImportTransaction(reopen: true, forceShrink: true)
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        } else {
            // Read VCF content with byte-based progress tracking.
            // Both plain and .vcf.gz VCFs use line-by-line streaming to avoid large memory spikes.
            let byteProgress: (Double) -> Void = { fraction in
                progressHandler?(0.05 + fraction * 0.85, "Parsing variants (\(insertCount))...")
            }
            wasCancelled = try streamVCFLines(onProgress: byteProgress) { line in
                parseLine(line, parseHeaders: true, activeChromosome: onlyChromosome)
            }
        }

        wasCancelled = wasCancelled || isCancelled()

        if wasCancelled {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.cancelled
        }

        let partitionMode: String
        if importedByChromosome {
            partitionMode = "per-chromosome"
        } else if onlyChromosome != nil {
            partitionMode = "single-chromosome"
        } else {
            partitionMode = "single-pass"
        }
        Self.insertMetadataRow(db, key: "import_partition_mode", value: partitionMode, replace: true)

        // Finalize all parsed rows before index creation, then explicitly release heap/cache.
        commitImportTransaction(reopen: false, forceShrink: true)

        // Record variant count and transition to indexing state.
        Self.insertMetadataRow(db, key: "import_variant_count", value: "\(insertCount)", replace: true)
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'indexing' WHERE key = 'import_state'", nil, nil, nil)

        if deferIndexBuild && resolvedProfile == .ultraLowMemory {
            Self.insertMetadataRow(db, key: "index_build_deferred", value: "true", replace: true)
            progressHandler?(0.92, "Insert phase complete, deferring index build...")
            variantDBLogger.info("createFromVCF: Deferred index build for ultra-low-memory staged import")
            return insertCount
        }

        if !tuning.createIndexesUpFront {
            // Filter out variant_info indexes when the EAV table was skipped.
            let indexesToBuild = tuning.skipVariantInfo
                ? Self.allIndexStatements.filter { !$0.name.contains("variant_info") }
                : Self.allIndexStatements

            if !indexesToBuild.isEmpty {
                progressHandler?(0.92, "Creating indexes...")

                // Reduce cache before bulk index creation to leave more RAM for SQLite's
                // sort algorithm (sorts spill to temp files via temp_store = FILE).
                sqlite3_exec(db, "PRAGMA cache_size = -1024", nil, nil, nil)
                releaseSQLiteMemory(forceShrink: true)

                // Build indexes outside the long-running import transaction and shrink between each.
                // Uses IF NOT EXISTS + ordered cheapest-first so a resume after crash
                // skips already-created indexes and the most important ones exist first.
                for (i, (name, sql)) in indexesToBuild.enumerated() {
                    if isCancelled() {
                        wasCancelled = true
                        break
                    }
                    let indexProgress = 0.92 + (Double(i) / Double(indexesToBuild.count)) * 0.07
                    progressHandler?(indexProgress, "Creating index \(i + 1) of \(indexesToBuild.count)...")
                    try Self.createRequiredIndex(db: db, name: name, sql: sql, context: "createFromVCF")
                    Self.insertMetadataRow(db, key: "idx_\(name)", value: "created", replace: true)
                    releaseSQLiteMemory(forceShrink: true)
                }

                if wasCancelled {
                    throw VariantDatabaseError.cancelled
                }
            }
        }
        releaseSQLiteMemory(forceShrink: true)

        // Build persistent SmartToken filter tables for instant chip loading on open.
        if !wasCancelled {
            progressHandler?(0.99, "Building filter indexes...")
            Self.createSmartTokenTables(
                db: db,
                skipVariantInfo: tuning.skipVariantInfo
            )
            releaseSQLiteMemory(forceShrink: true)
        }

        // Mark import complete.
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'complete' WHERE key = 'import_state'", nil, nil, nil)

        progressHandler?(1.0, "Done (\(insertCount) variants, \(sampleNames.count) samples)")

        variantDBLogger.info("Created variant database with \(insertCount) variants, \(sampleNames.count) samples at \(outputURL.lastPathComponent)")
        return insertCount
    }

    /// Backward-compatible overload retained to preserve cross-module symbol compatibility.
    @discardableResult
    public static func createFromVCF(
        vcfURL: URL,
        outputURL: URL,
        parseGenotypes: Bool,
        sourceFile: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?,
        importSemantics: VCFImportSemantics = .standard,
        importProfile: VCFImportProfile
    ) throws -> Int {
        try createFromVCF(
            vcfURL: vcfURL,
            outputURL: outputURL,
            parseGenotypes: parseGenotypes,
            sourceFile: sourceFile,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel,
            importSemantics: importSemantics,
            importProfile: importProfile,
            deferIndexBuild: false
        )
    }

    /// Backward-compatible overload without genotype parsing or progress.
    @discardableResult
    public static func createFromVCF(vcfURL: URL, outputURL: URL) throws -> Int {
        try createFromVCF(vcfURL: vcfURL, outputURL: outputURL, parseGenotypes: true, progressHandler: nil)
    }

    /// Creates persistent SmartToken filter tables during import.
    ///
    /// Column-based tables (PASS, SNV, Indel, Quality≥30) are always created.
    /// EAV-based tables (DP≥10, Rare, ClinVar, High Impact) are only created when
    /// `variant_info` is populated (i.e. not `skipVariantInfo`).
    static func createSmartTokenTables(db: OpaquePointer, skipVariantInfo: Bool) {
        struct TableDef {
            let name: String
            let sql: String
            let idColumn: String
            let indexSQL: String
        }

        var tables: [TableDef] = [
            TableDef(
                name: "_tok_pass",
                sql: "CREATE TABLE IF NOT EXISTS _tok_pass AS SELECT id FROM variants WHERE filter = 'PASS'",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_pass ON _tok_pass(id)"
            ),
            TableDef(
                name: "_tok_snv",
                sql: "CREATE TABLE IF NOT EXISTS _tok_snv AS SELECT id FROM variants WHERE variant_type IN ('SNV','snv','SNP','snp')",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_snv ON _tok_snv(id)"
            ),
            TableDef(
                name: "_tok_indel",
                sql: "CREATE TABLE IF NOT EXISTS _tok_indel AS SELECT id FROM variants WHERE variant_type IN ('Indel','indel','INS','DEL','Insertion','Deletion')",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_indel ON _tok_indel(id)"
            ),
            TableDef(
                name: "_tok_qual30",
                sql: "CREATE TABLE IF NOT EXISTS _tok_qual30 AS SELECT id FROM variants WHERE quality >= 30",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_qual30 ON _tok_qual30(id)"
            ),
        ]

        if skipVariantInfo {
            tables.append(TableDef(
                name: "_tok_bio_hi",
                sql: "CREATE TABLE IF NOT EXISTS _tok_bio_hi AS \(biologicalHighImpactRawInfoSQL())",
                idColumn: "variant_id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_bio_hi ON _tok_bio_hi(variant_id)"
            ))
        }

        if !skipVariantInfo {
            // Check which INFO keys are available from variant_info_defs
            var availableKeys: Set<String> = []
            var keyStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT key FROM variant_info_defs", -1, &keyStmt, nil) == SQLITE_OK {
                while sqlite3_step(keyStmt!) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(keyStmt!, 0) {
                        availableKeys.insert(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(keyStmt)

            if availableKeys.contains("DP") {
                tables.append(TableDef(
                    name: "_tok_dp10",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_dp10 AS SELECT DISTINCT variant_id FROM variant_info WHERE key = 'DP' AND CAST(value AS REAL) >= 10",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_dp10 ON _tok_dp10(variant_id)"
                ))
            }

            let afKeys = ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF", "MAX_AF"]
            if let afKey = afKeys.first(where: { availableKeys.contains($0) }) {
                tables.append(TableDef(
                    name: "_tok_rare",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_rare AS SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(afKey)' AND CAST(value AS REAL) < 0.01",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_rare ON _tok_rare(variant_id)"
                ))
            }

            let clinvarKeys = ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"]
            if let clinvarKey = clinvarKeys.first(where: { availableKeys.contains($0) }) {
                tables.append(TableDef(
                    name: "_tok_clinvar",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_clinvar AS SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(clinvarKey)' AND value LIKE '%athogenic%'",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_clinvar ON _tok_clinvar(variant_id)"
                ))
            }

            // High impact
            let impactKeys = impactInfoKeys
            let hasImpactKey = !impactKeys.allSatisfy { !availableKeys.contains($0) }
            if hasImpactKey {
                let keyList = impactKeys.map { "'\($0)'" }.joined(separator: ",")
                tables.append(TableDef(
                    name: "_high_impact",
                    sql: "CREATE TABLE IF NOT EXISTS _high_impact AS SELECT DISTINCT variant_id FROM variant_info WHERE key IN (\(keyList)) AND value = 'HIGH'",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx_hi ON _high_impact(variant_id)"
                ))
            }

            // Biologically high-impact variants:
            // IMPACT=HIGH plus severe consequence terms.
            let consequenceKeys = impactConsequenceInfoKeys.filter { availableKeys.contains($0) }
            if hasImpactKey || !consequenceKeys.isEmpty {
                let tokenSQL = biologicalHighImpactTokenSQL(
                    impactKeys: impactKeys,
                    consequenceKeys: consequenceKeys.isEmpty ? impactConsequenceInfoKeys : consequenceKeys
                )
                tables.append(TableDef(
                    name: "_tok_bio_hi",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_bio_hi AS \(tokenSQL)",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_bio_hi ON _tok_bio_hi(variant_id)"
                ))
            }
        }

        for table in tables {
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, table.sql, nil, nil, &err)
            if let err {
                let msg = String(cString: err)
                sqlite3_free(err)
                variantDBLogger.warning("createSmartTokenTables: \(table.name) failed: \(msg)")
                continue
            }
            sqlite3_exec(db, table.indexSQL, nil, nil, nil)
            variantDBLogger.info("createSmartTokenTables: created \(table.name)")
        }
    }

}
