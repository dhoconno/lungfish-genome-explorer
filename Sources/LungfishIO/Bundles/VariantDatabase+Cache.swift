// VariantDatabase+Cache.swift - High-impact + SmartToken caches
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - High-Impact Variant Cache

    /// Known INFO keys for the IMPACT field.
    static let impactInfoKeys = ["IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT"]

    /// INFO keys that commonly encode VEP/SnpEff consequence terms.
    static let impactConsequenceInfoKeys = [
        "CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence",
    ]

    /// Consequence terms treated as biologically high impact.
    static let biologicalHighImpactConsequenceTerms = [
        "transcript_ablation",
        "splice_acceptor_variant",
        "splice_donor_variant",
        "stop_gained",
        "stop_lost",
        "start_lost",
        "frameshift_variant",
        "exon_loss_variant",
        "rare_amino_acid_variant",
    ]

    static func sqliteStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    static func biologicalHighImpactTokenSQL(
        impactKeys: [String],
        consequenceKeys: [String]
    ) -> String {
        let impactKeyList = impactKeys.map { "'\($0)'" }.joined(separator: ",")
        let consequenceKeyList = consequenceKeys.map { "'\($0)'" }.joined(separator: ",")
        let consequenceMatch = biologicalHighImpactConsequenceTerms
            .map { "INSTR(LOWER(value), '\($0)') > 0" }
            .joined(separator: " OR ")
        return """
        SELECT DISTINCT variant_id FROM (
            SELECT variant_id FROM variant_info
            WHERE key IN (\(impactKeyList)) AND value = 'HIGH'
            UNION
            SELECT variant_id FROM variant_info
            WHERE key IN (\(consequenceKeyList))
              AND (\(consequenceMatch))
        )
        """
    }

    static func biologicalHighImpactRawInfoSQL() -> String {
        let normalizedInfo = "';' || UPPER(info) || ';'"
        let highImpactMatches = Set(impactInfoKeys.map { $0.uppercased() })
            .sorted()
            .map { key in
                "INSTR(\(normalizedInfo), \(sqliteStringLiteral(";\(key)=HIGH;"))) > 0"
            }
            .joined(separator: " OR ")
        let severeConsequenceMatches = biologicalHighImpactConsequenceTerms
            .map { "INSTR(LOWER(info), \(sqliteStringLiteral($0))) > 0" }
            .joined(separator: " OR ")
        return """
        SELECT id AS variant_id FROM variants
        WHERE info IS NOT NULL AND info != ''
          AND (
            \(highImpactMatches)
            OR
            \(severeConsequenceMatches)
          )
        """
    }

    /// Creates a temp table of variant IDs with IMPACT=HIGH for instant filtering.
    /// Runs once per connection; protected by the progress handler timeout.
    /// Returns true if the cache was created successfully.
    @discardableResult
    public func warmHighImpactCache(timeoutSeconds: TimeInterval = 30) -> Bool {
        let alreadyReady = cacheLock.withLock { _highImpactCacheReady }
        guard let db, !alreadyReady else { return alreadyReady }

        // Install a timeout so the initial scan doesn't block forever.
        let ctx = QueryProgressContext(timeoutSeconds: timeoutSeconds)
        let savedCtx = progressContext
        progressContext = ctx
        let rawPtr = Unmanaged.passUnretained(ctx).toOpaque()
        sqlite3_progress_handler(db, 1000, { rawPtr in
            guard let rawPtr else { return 0 }
            let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
            return c.isExpired ? 1 : 0
        }, rawPtr)

        defer {
            // Restore previous progress handler state.
            if let savedCtx {
                progressContext = savedCtx
                let rawPtr = Unmanaged.passUnretained(savedCtx).toOpaque()
                sqlite3_progress_handler(db, 1000, { rawPtr in
                    guard let rawPtr else { return 0 }
                    let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
                    if c.isExpired { return 1 }
                    if c.cancelCheck?() == true { return 1 }
                    return 0
                }, rawPtr)
            } else {
                sqlite3_progress_handler(db, 0, nil, nil)
                progressContext = nil
            }
        }

        let keyList = Self.impactInfoKeys.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        CREATE TABLE IF NOT EXISTS _high_impact AS
        SELECT DISTINCT variant_id FROM variant_info
        WHERE key IN (\(keyList))
        AND value = 'HIGH'
        """
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            let msg = String(cString: err)
            sqlite3_free(err)
            if rc == SQLITE_INTERRUPT {
                variantDBLogger.info("warmHighImpactCache: timed out after \(timeoutSeconds)s")
            } else {
                variantDBLogger.warning("warmHighImpactCache: failed: \(msg)")
            }
            return false
        }
        // Create index on the temp table for fast JOINs.
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS _idx_hi ON _high_impact(variant_id)", nil, nil, nil)
        cacheLock.withLock { _highImpactCacheReady = true }

        var countStmt: OpaquePointer?
        defer { sqlite3_finalize(countStmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM _high_impact", -1, &countStmt, nil) == SQLITE_OK,
           sqlite3_step(countStmt) == SQLITE_ROW {
            let count = sqlite3_column_int64(countStmt, 0)
            variantDBLogger.info("warmHighImpactCache: cached \(count) high-impact variants")
        }
        return true
    }

    /// Whether the high-impact temp table is ready for fast queries.
    public var highImpactCacheReady: Bool { cacheLock.withLock { _highImpactCacheReady } }

    /// Returns the current SmartToken cache state (token rawValue → ready status and count).
    public var tokenCacheState: [String: (ready: Bool, count: Int)] { _tokenCacheState }

    // MARK: - SmartToken Pre-Materialization

    /// Token names used as keys for the cache state dictionary and temp table naming.
    struct TokenDef {
        let name: String
        let tableName: String
        let sql: String
        let idColumn: String  // "id" for variants-table queries, "variant_id" for EAV queries
        let requiresEAV: Bool
    }

    /// Builds the list of token definitions that can be pre-materialized.
    func tokenDefinitions(availableInfoKeys: Set<String>) -> [TokenDef] {
        var defs: [TokenDef] = []

        // Column-based tokens (always available)
        defs.append(TokenDef(
            name: "passOnly",
            tableName: "_tok_pass",
            sql: "SELECT id FROM variants WHERE filter = 'PASS'",
            idColumn: "id",
            requiresEAV: false
        ))
        defs.append(TokenDef(
            name: "snv",
            tableName: "_tok_snv",
            sql: "SELECT id FROM variants WHERE variant_type IN ('SNV','snv','SNP','snp')",
            idColumn: "id",
            requiresEAV: false
        ))
        defs.append(TokenDef(
            name: "indel",
            tableName: "_tok_indel",
            sql: "SELECT id FROM variants WHERE variant_type IN ('Indel','indel','INS','DEL','Insertion','Deletion')",
            idColumn: "id",
            requiresEAV: false
        ))
        defs.append(TokenDef(
            name: "qualityGE30",
            tableName: "_tok_qual30",
            sql: "SELECT id FROM variants WHERE quality >= 30",
            idColumn: "id",
            requiresEAV: false
        ))

        if variantInfoSkipped {
            defs.append(TokenDef(
                name: "highImpactBiological",
                tableName: "_tok_bio_hi",
                sql: Self.biologicalHighImpactRawInfoSQL(),
                idColumn: "variant_id",
                requiresEAV: false
            ))
        }

        // EAV-based tokens (only for databases with variant_info populated)
        if !variantInfoSkipped {
            if availableInfoKeys.contains("DP") {
                defs.append(TokenDef(
                    name: "depthGE10",
                    tableName: "_tok_dp10",
                    sql: "SELECT DISTINCT variant_id FROM variant_info WHERE key = 'DP' AND CAST(value AS REAL) >= 10",
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }

            let afKey = ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF", "MAX_AF", "gnomADe_AF", "gnomADg_AF"]
                .first { availableInfoKeys.contains($0) }
            if let afKey {
                defs.append(TokenDef(
                    name: "rareVariant",
                    tableName: "_tok_rare",
                    sql: "SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(afKey)' AND CAST(value AS REAL) < 0.01",
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }

            // High impact is handled separately by warmHighImpactCache()
            // but we track its state here too.
            let availableConsequenceKeys = Self.impactConsequenceInfoKeys
                .filter { availableInfoKeys.contains($0) }
            let hasImpactKey = !availableInfoKeys.isDisjoint(with: Set(Self.impactInfoKeys))
            if hasImpactKey || !availableConsequenceKeys.isEmpty {
                let tokenSQL = Self.biologicalHighImpactTokenSQL(
                    impactKeys: Self.impactInfoKeys,
                    consequenceKeys: availableConsequenceKeys.isEmpty
                        ? Self.impactConsequenceInfoKeys
                        : availableConsequenceKeys
                )
                defs.append(TokenDef(
                    name: "highImpactBiological",
                    tableName: "_tok_bio_hi",
                    sql: tokenSQL,
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }

            let clinvarKey = ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"]
                .first { availableInfoKeys.contains($0) }
            if let clinvarKey {
                defs.append(TokenDef(
                    name: "clinvarPathogenic",
                    tableName: "_tok_clinvar",
                    sql: "SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(clinvarKey)' AND value LIKE '%athogenic%'",
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }
        }

        return defs
    }

    /// Pre-materializes all applicable SmartToken filters as persistent indexed tables.
    ///
    /// Creates permanent `_tok_*` tables during import so that opening the database
    /// later only needs a fast `loadTokenCacheState()` call (row counts, no scans).
    ///
    /// - Parameters:
    ///   - availableInfoKeys: Set of INFO keys present in this database
    ///   - timeoutPerToken: Maximum seconds allowed per table creation
    /// - Returns: Token cache state dictionary
    @discardableResult
    public func warmSmartTokenCaches(
        availableInfoKeys: Set<String>,
        timeoutPerToken: TimeInterval = 30
    ) -> [String: (ready: Bool, count: Int)] {
        guard let db else { return _tokenCacheState }

        let defs = tokenDefinitions(availableInfoKeys: availableInfoKeys)

        for def in defs {
            // Skip if already cached (e.g. loaded from persistent table)
            if _tokenCacheState[def.name]?.ready == true { continue }

            // Install per-token timeout
            let ctx = QueryProgressContext(timeoutSeconds: timeoutPerToken)
            let savedCtx = progressContext
            progressContext = ctx
            let rawPtr = Unmanaged.passUnretained(ctx).toOpaque()
            sqlite3_progress_handler(db, 1000, { rawPtr in
                guard let rawPtr else { return 0 }
                let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
                return c.isExpired ? 1 : 0
            }, rawPtr)

            // Persistent table (not TEMP) — survives database close/reopen.
            let createSQL = "CREATE TABLE IF NOT EXISTS \(def.tableName) AS \(def.sql)"
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, createSQL, nil, nil, &err)

            // Restore progress handler
            if let savedCtx {
                progressContext = savedCtx
                let rawPtr = Unmanaged.passUnretained(savedCtx).toOpaque()
                sqlite3_progress_handler(db, 1000, { rawPtr in
                    guard let rawPtr else { return 0 }
                    let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
                    if c.isExpired { return 1 }
                    if c.cancelCheck?() == true { return 1 }
                    return 0
                }, rawPtr)
            } else {
                sqlite3_progress_handler(db, 0, nil, nil)
                progressContext = nil
            }

            if let err {
                let msg = String(cString: err)
                sqlite3_free(err)
                if rc == SQLITE_INTERRUPT {
                    variantDBLogger.info("warmSmartTokenCaches: \(def.name) timed out after \(timeoutPerToken)s")
                } else {
                    variantDBLogger.warning("warmSmartTokenCaches: \(def.name) failed: \(msg)")
                }
                _tokenCacheState[def.name] = (ready: false, count: 0)
                continue
            }

            // Create index on the persistent table
            let indexSQL = "CREATE INDEX IF NOT EXISTS _idx_\(def.tableName) ON \(def.tableName)(\(def.idColumn))"
            sqlite3_exec(db, indexSQL, nil, nil, nil)

            // Count rows
            var count = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(def.tableName)", -1, &countStmt, nil) == SQLITE_OK,
               sqlite3_step(countStmt!) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt!, 0))
            }
            sqlite3_finalize(countStmt)

            _tokenCacheState[def.name] = (ready: true, count: count)
            variantDBLogger.info("warmSmartTokenCaches: \(def.name) cached \(count) variants in \(def.tableName)")
        }

        // Also create persistent high-impact table if not already done
        if !cacheLock.withLock({ _highImpactCacheReady }) && !variantInfoSkipped {
            let hasImpactKey = !availableInfoKeys.isDisjoint(with: Set(Self.impactInfoKeys))
            if hasImpactKey {
                warmHighImpactCache(timeoutSeconds: timeoutPerToken)
                if cacheLock.withLock({ _highImpactCacheReady }) {
                    var countStmt: OpaquePointer?
                    var hiCount = 0
                    if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM _high_impact", -1, &countStmt, nil) == SQLITE_OK,
                       sqlite3_step(countStmt!) == SQLITE_ROW {
                        hiCount = Int(sqlite3_column_int64(countStmt!, 0))
                    }
                    sqlite3_finalize(countStmt)
                    _tokenCacheState["highImpact"] = (ready: true, count: hiCount)
                }
            }
        }

        return _tokenCacheState
    }

    /// Loads token cache state from pre-existing persistent `_tok_*` tables.
    ///
    /// This is fast (no full table scans — just checks table existence and reads row counts).
    /// Called during database open so SmartToken chips are available instantly.
    public func loadTokenCacheState() {
        guard let db else { return }

        // All known persistent token tables and their token names.
        let knownTables: [(name: String, tableName: String)] = [
            ("passOnly", "_tok_pass"),
            ("snv", "_tok_snv"),
            ("indel", "_tok_indel"),
            ("qualityGE30", "_tok_qual30"),
            ("depthGE10", "_tok_dp10"),
            ("rareVariant", "_tok_rare"),
            ("clinvarPathogenic", "_tok_clinvar"),
            ("highImpactBiological", "_tok_bio_hi"),
            ("highImpact", "_high_impact"),
        ]

        for (name, tableName) in knownTables {
            // Check if the table exists.
            var checkStmt: OpaquePointer?
            let checkSQL = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?"
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(checkStmt, 1, tableName, -1, sqliteTransientDestructor)
            let exists: Bool
            if sqlite3_step(checkStmt!) == SQLITE_ROW {
                exists = sqlite3_column_int64(checkStmt!, 0) > 0
            } else {
                exists = false
            }
            sqlite3_finalize(checkStmt)
            guard exists else { continue }

            // Read row count (instant — SQLite caches this).
            var countStmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(tableName)", -1, &countStmt, nil) == SQLITE_OK,
               sqlite3_step(countStmt!) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt!, 0))
            }
            sqlite3_finalize(countStmt)

            _tokenCacheState[name] = (ready: true, count: count)
            if name == "highImpact" {
                cacheLock.withLock { _highImpactCacheReady = true }
            }
        }

        if !_tokenCacheState.isEmpty {
            let loadedCount = _tokenCacheState.count
            variantDBLogger.info("loadTokenCacheState: loaded \(loadedCount) pre-built token tables")
        }
    }

    /// Returns the temp table JOIN fragment for a SmartToken, or nil if not cached.
    ///
    /// The JOIN links `variants.id` to the temp table's id/variant_id column.
    /// Used by query methods to replace WHERE/EXISTS clauses with fast JOINs.
    func tokenJoinSQL(for tokenName: String) -> String? {
        guard _tokenCacheState[tokenName]?.ready == true else { return nil }
        // Map token names to their table definitions
        let tableName: String
        let idColumn: String
        switch tokenName {
        case "passOnly": tableName = "_tok_pass"; idColumn = "id"
        case "snv": tableName = "_tok_snv"; idColumn = "id"
        case "indel": tableName = "_tok_indel"; idColumn = "id"
        case "qualityGE30": tableName = "_tok_qual30"; idColumn = "id"
        case "depthGE10": tableName = "_tok_dp10"; idColumn = "variant_id"
        case "rareVariant": tableName = "_tok_rare"; idColumn = "variant_id"
        case "clinvarPathogenic": tableName = "_tok_clinvar"; idColumn = "variant_id"
        case "highImpactBiological": tableName = "_tok_bio_hi"; idColumn = "variant_id"
        case "highImpact": tableName = "_high_impact"; idColumn = "variant_id"
        default: return nil
        }
        let targetColumn = "\(tableName).\(idColumn)"
        return "INNER JOIN \(tableName) ON variants.id = \(targetColumn)"
    }

    /// Detects whether a set of InfoFilters is a sole IMPACT=HIGH filter
    /// that can be served from the pre-cached temp table.
    func isHighImpactOnlyFilter(_ infoFilters: [InfoFilter]) -> Bool {
        guard cacheLock.withLock({ _highImpactCacheReady }) else { return false }
        guard infoFilters.count == 1 else { return false }
        let f = infoFilters[0]
        return f.op == .eq
            && f.value == "HIGH"
            && Self.impactInfoKeys.contains(where: { $0.caseInsensitiveCompare(f.key) == .orderedSame })
    }

    /// Replaces the EXISTS subquery for IMPACT=HIGH with a JOIN on the temp table.
    /// Returns the SQL fragment and whether it was substituted.
    func highImpactJoinSQL() -> String {
        "INNER JOIN _high_impact _hi ON variants.id = _hi.variant_id"
    }

}
