# NAO-MGS SQLite Data Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace virus_hits.json + BAM with a SQLite database storing per-(sample, taxon) summaries and reads, eliminating samtools crashes and enabling instant per-sample taxonomy browsing with a popover-based sample picker.

**Architecture:** A new `NaoMgsDatabase` class (raw sqlite3 C API, following `VariantDatabase` patterns) handles creation during import and queries during viewing. Import writes hits in bulk + computes per-(sample, taxon) summaries. The viewer reads summaries directly from the DB and renders miniBAMs from SQLite queries instead of samtools. A SwiftUI popover lets users browse and select samples.

**Tech Stack:** Swift 6.2, SQLite3 (Apple-provided C API), SwiftUI (sample picker popover), AppKit (NaoMgsResultViewController)

**Spec:** `docs/superpowers/specs/2026-04-01-naomgs-sqlite-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift` | Create | SQLite database: create, insert, query |
| `Tests/LungfishIntegrationTests/NaoMgsDatabaseTests.swift` | Create | Database unit tests |
| `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift` | Modify | Remove `convertToSAM` method |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift` | Modify | Replace JSON+BAM with SQLite; remove `includeAlignment` |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift` | Modify | Remove "Convert to SAM" toggle |
| `Sources/LungfishApp/App/AppDelegate.swift` | Modify | Remove `convertToSAM` from import call |
| `Sources/LungfishApp/App/MetagenomicsImportHelper.swift` | Modify | Remove `--include-alignment` |
| `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift` | Modify | Remove `includeAlignment` |
| `Sources/LungfishCLI/Commands/ImportCommand.swift` | Modify | Remove `--sam`/`--include-alignment` |
| `Sources/LungfishCLI/Commands/NaoMgsCommand.swift` | Modify | Remove `--sam` |
| `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift` | Modify | Add `displayReads(reads:contig:contigLength:)` |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift` | Create | SwiftUI popover for sample multi-select |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Modify | Use database; per-(sample,taxon) table; sample picker |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | Modify | Load from SQLite instead of JSON |
| `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift` | Modify | Update for SQLite output |
| `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsImportServiceTests.swift` | Modify | Update existing test |

---

## Task 1: NaoMgsDatabase — Schema and Creation

**Files:**
- Create: `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift`
- Create: `Tests/LungfishIntegrationTests/NaoMgsDatabaseTests.swift`

This task creates the database class with `create()` and basic validation. It does NOT yet implement viewer queries (Task 2) or summary computation (Task 3).

- [ ] **Step 1: Write failing test for database creation**

Create `Tests/LungfishIntegrationTests/NaoMgsDatabaseTests.swift`:

```swift
// NaoMgsDatabaseTests.swift — Tests for NAO-MGS SQLite database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
import LungfishCore

struct NaoMgsDatabaseTests {

    @Test
    func createDatabaseInsertsAllHits() async throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let dbURL = workspace.appendingPathComponent("hits.sqlite")
        let hits = syntheticHits()

        let db = try NaoMgsDatabase.create(at: dbURL, hits: hits)

        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(try db.totalHitCount(samples: nil) == hits.count)
    }

    @Test
    func createDatabaseWithEmptyHits() async throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let dbURL = workspace.appendingPathComponent("hits.sqlite")
        let db = try NaoMgsDatabase.create(at: dbURL, hits: [])

        #expect(try db.totalHitCount(samples: nil) == 0)
    }

    @Test
    func openExistingDatabase() async throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let dbURL = workspace.appendingPathComponent("hits.sqlite")
        let hits = syntheticHits()
        _ = try NaoMgsDatabase.create(at: dbURL, hits: hits)

        // Re-open in read-only mode
        let db2 = try NaoMgsDatabase(at: dbURL)
        #expect(try db2.totalHitCount(samples: nil) == hits.count)
    }
}

// MARK: - Test Helpers

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("naomgs-db-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Creates synthetic hits across 2 samples, 2 taxa, 3 accessions.
private func syntheticHits() -> [NaoMgsVirusHit] {
    var hits: [NaoMgsVirusHit] = []
    let samples = ["SAMPLE_A", "SAMPLE_B"]
    let taxa = [(taxId: 111, accessions: ["ACC001", "ACC002", "ACC003"]),
                (taxId: 222, accessions: ["ACC004", "ACC005"])]

    for sample in samples {
        for taxon in taxa {
            for (i, accession) in taxon.accessions.enumerated() {
                for readIdx in 0..<(3 + i) {
                    hits.append(NaoMgsVirusHit(
                        sample: sample,
                        seqId: "\(sample)_\(taxon.taxId)_\(accession)_read\(readIdx)",
                        taxId: taxon.taxId,
                        bestAlignmentScore: 100.0,
                        cigar: "50M",
                        queryStart: 0,
                        queryEnd: 50,
                        refStart: readIdx * 50,
                        refEnd: readIdx * 50 + 50,
                        readSequence: String(repeating: "ACGT", count: 12) + "AC",
                        readQuality: String(repeating: "I", count: 50),
                        subjectSeqId: accession,
                        subjectTitle: "Test virus \(taxon.taxId)",
                        bitScore: 100.0,
                        eValue: 1e-30,
                        percentIdentity: 98.5,
                        editDistance: 1,
                        fragmentLength: 50,
                        isReverseComplement: readIdx % 2 == 1,
                        pairStatus: "CP",
                        queryLength: 50
                    ))
                }
            }
        }
    }
    return hits
}
```

- [ ] **Step 2: Implement NaoMgsDatabase with create + totalHitCount**

Create `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift`. Follow the `VariantDatabase` pattern — raw sqlite3 C API, `@unchecked Sendable`, pragma tuning.

```swift
// NaoMgsDatabase.swift — SQLite-backed data store for NAO-MGS virus hits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "NaoMgsDatabase")

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

/// SQLite-backed data store for NAO-MGS virus hit data.
///
/// Replaces `virus_hits.json` and BAM files. Stores all parsed hits in a
/// `virus_hits` table with indices for fast per-(sample, taxon, accession)
/// queries. Taxon summaries with unique read counts are precomputed per
/// (sample, taxon) pair at import time in a `taxon_summaries` table.
///
/// ## Convention
///
/// Every operation that creates a user-visible directory MUST use
/// ``OperationMarker`` (see `OperationMarker.swift`).
public final class NaoMgsDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    public let url: URL

    /// Opens an existing NAO-MGS database in read-only mode.
    public init(at url: URL) throws {
        self.url = url
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw NaoMgsDatabaseError.openFailed(msg)
        }
        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -32768", nil, nil, nil)   // 32 MB page cache
        sqlite3_exec(db, "PRAGMA mmap_size = 134217728", nil, nil, nil) // 128 MB mmap
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
    }

    /// Creates a new database, bulk-inserts hits, computes summaries, and builds indices.
    ///
    /// - Parameters:
    ///   - url: Path for the new database file.
    ///   - hits: Parsed virus hits to insert.
    ///   - progress: Optional progress callback (0.0–1.0).
    /// - Returns: The opened database (read-write).
    @discardableResult
    public static func create(
        at url: URL,
        hits: [NaoMgsVirusHit],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> NaoMgsDatabase {
        // Delete existing if present
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

        // Write-optimized pragmas
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        progress?(0.01, "Creating database schema\u{2026}")

        // Create tables
        let createVirusHits = """
            CREATE TABLE virus_hits (
                rowid INTEGER PRIMARY KEY,
                sample TEXT NOT NULL,
                seq_id TEXT NOT NULL,
                tax_id INTEGER NOT NULL,
                subject_seq_id TEXT NOT NULL,
                subject_title TEXT NOT NULL,
                ref_start INTEGER NOT NULL,
                cigar TEXT NOT NULL,
                read_sequence TEXT NOT NULL,
                read_quality TEXT NOT NULL,
                percent_identity REAL NOT NULL,
                bit_score REAL NOT NULL,
                e_value REAL NOT NULL,
                edit_distance INTEGER NOT NULL,
                query_length INTEGER NOT NULL,
                is_reverse_complement INTEGER NOT NULL,
                pair_status TEXT NOT NULL,
                fragment_length INTEGER NOT NULL,
                best_alignment_score REAL NOT NULL
            )
            """
        guard sqlite3_exec(db, createVirusHits, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw NaoMgsDatabaseError.createFailed("virus_hits table: \(msg)")
        }

        let createSummaries = """
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
                PRIMARY KEY (sample, tax_id)
            )
            """
        guard sqlite3_exec(db, createSummaries, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw NaoMgsDatabaseError.createFailed("taxon_summaries table: \(msg)")
        }

        // Bulk insert hits
        progress?(0.05, "Inserting \(hits.count) hits\u{2026}")
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
            INSERT INTO virus_hits (
                sample, seq_id, tax_id, subject_seq_id, subject_title,
                ref_start, cigar, read_sequence, read_quality,
                percent_identity, bit_score, e_value, edit_distance,
                query_length, is_reverse_complement, pair_status,
                fragment_length, best_alignment_score
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_close(db)
            throw NaoMgsDatabaseError.insertFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        let progressInterval = max(1, hits.count / 20)
        for (index, hit) in hits.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            bindText(stmt, 1, hit.sample)
            bindText(stmt, 2, hit.seqId)
            sqlite3_bind_int(stmt, 3, Int32(hit.taxId))
            bindText(stmt, 4, hit.subjectSeqId)
            bindText(stmt, 5, hit.subjectTitle)
            sqlite3_bind_int(stmt, 6, Int32(hit.refStart))
            bindText(stmt, 7, hit.cigar)
            bindText(stmt, 8, hit.readSequence)
            bindText(stmt, 9, hit.readQuality)
            sqlite3_bind_double(stmt, 10, hit.percentIdentity)
            sqlite3_bind_double(stmt, 11, hit.bitScore)
            sqlite3_bind_double(stmt, 12, hit.eValue)
            sqlite3_bind_int(stmt, 13, Int32(hit.editDistance))
            sqlite3_bind_int(stmt, 14, Int32(hit.queryLength))
            sqlite3_bind_int(stmt, 15, hit.isReverseComplement ? 1 : 0)
            bindText(stmt, 16, hit.pairStatus)
            sqlite3_bind_int(stmt, 17, Int32(hit.fragmentLength))
            sqlite3_bind_double(stmt, 18, hit.bestAlignmentScore)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                sqlite3_close(db)
                throw NaoMgsDatabaseError.insertFailed("Row \(index): \(msg)")
            }

            if index % progressInterval == 0 {
                let fraction = Double(index) / Double(hits.count)
                progress?(0.05 + fraction * 0.50, "Inserted \(index)/\(hits.count) hits")
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        progress?(0.55, "Committed \(hits.count) hits")

        // Build indices (after insert is faster than during)
        progress?(0.56, "Building indices\u{2026}")
        let indices = [
            "CREATE INDEX idx_hits_sample_taxon_accession ON virus_hits(sample, tax_id, subject_seq_id)",
            "CREATE INDEX idx_hits_taxon_accession ON virus_hits(tax_id, subject_seq_id)",
            "CREATE INDEX idx_hits_sample ON virus_hits(sample)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                logger.warning("Index creation failed: \(msg, privacy: .public)")
                continue
            }
        }
        progress?(0.65, "Indices built")

        // Compute taxon summaries (Task 3 will implement this)
        progress?(0.66, "Computing taxon summaries\u{2026}")
        try computeTaxonSummaries(db: db, progress: progress)
        progress?(0.95, "Summaries computed")

        // Summary indices
        sqlite3_exec(db, "CREATE INDEX idx_summaries_sample ON taxon_summaries(sample)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_summaries_hitcount ON taxon_summaries(sample, hit_count DESC)", nil, nil, nil)

        progress?(1.0, "Database complete")

        let instance = NaoMgsDatabase(privateDB: db, url: url)
        return instance
    }

    /// Private initializer for post-create use.
    private init(privateDB: OpaquePointer, url: URL) {
        self.db = privateDB
        self.url = url
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Queries

    /// Total hit count, optionally filtered by samples.
    public func totalHitCount(samples: [String]?) throws -> Int {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }

        let effectiveSamples = samples?.isEmpty == true ? nil : samples
        let sql: String
        if let effectiveSamples {
            let placeholders = effectiveSamples.map { _ in "?" }.joined(separator: ",")
            sql = "SELECT COUNT(*) FROM virus_hits WHERE sample IN (\(placeholders))"
        } else {
            sql = "SELECT COUNT(*) FROM virus_hits"
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        if let effectiveSamples {
            for (i, sample) in effectiveSamples.enumerated() {
                bindText(stmt, Int32(i + 1), sample)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NaoMgsDatabaseError.queryFailed("No result from COUNT")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Summary Computation (called during create)

    private static func computeTaxonSummaries(
        db: OpaquePointer,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        // Step 1: Get all (sample, tax_id) pairs with basic aggregates
        let aggregateSQL = """
            INSERT INTO taxon_summaries (
                sample, tax_id, name, hit_count, unique_read_count,
                avg_identity, avg_bit_score, avg_edit_distance,
                pcr_duplicate_count, accession_count, top_accessions_json
            )
            SELECT
                sample,
                tax_id,
                MIN(subject_title) AS name,
                COUNT(*) AS hit_count,
                0 AS unique_read_count,
                AVG(percent_identity) AS avg_identity,
                AVG(bit_score) AS avg_bit_score,
                AVG(CAST(edit_distance AS REAL)) AS avg_edit_distance,
                0 AS pcr_duplicate_count,
                COUNT(DISTINCT subject_seq_id) AS accession_count,
                '[]' AS top_accessions_json
            FROM virus_hits
            GROUP BY sample, tax_id
            """
        guard sqlite3_exec(db, aggregateSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Summary aggregation failed: \(msg)")
        }

        progress?(0.72, "Computing unique reads\u{2026}")

        // Step 2: Compute unique read counts per (sample, tax_id)
        // A read is a "PCR duplicate" if another read has the same
        // (sample, tax_id, subject_seq_id, ref_start, is_reverse_complement, query_length).
        // unique_read_count = count of distinct groups.
        let uniqueSQL = """
            UPDATE taxon_summaries SET
                unique_read_count = (
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT subject_seq_id, ref_start, is_reverse_complement, query_length
                        FROM virus_hits vh
                        WHERE vh.sample = taxon_summaries.sample
                          AND vh.tax_id = taxon_summaries.tax_id
                    )
                ),
                pcr_duplicate_count = hit_count - (
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT subject_seq_id, ref_start, is_reverse_complement, query_length
                        FROM virus_hits vh
                        WHERE vh.sample = taxon_summaries.sample
                          AND vh.tax_id = taxon_summaries.tax_id
                    )
                )
            """
        guard sqlite3_exec(db, uniqueSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Unique read computation failed: \(msg)")
        }

        progress?(0.82, "Computing top accessions\u{2026}")

        // Step 3: Compute top 5 accessions by unique reads per (sample, tax_id)
        // Read all (sample, tax_id) pairs, compute top 5 for each, update.
        var pairsStmt: OpaquePointer?
        defer { sqlite3_finalize(pairsStmt) }
        let pairsSQL = "SELECT sample, tax_id FROM taxon_summaries"
        guard sqlite3_prepare_v2(db, pairsSQL, -1, &pairsStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Pairs query failed: \(msg)")
        }

        var updateStmt: OpaquePointer?
        defer { sqlite3_finalize(updateStmt) }
        let updateSQL = "UPDATE taxon_summaries SET top_accessions_json = ? WHERE sample = ? AND tax_id = ?"
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Update prepare failed: \(msg)")
        }

        let topAccSQL = """
            SELECT subject_seq_id, COUNT(DISTINCT ref_start || '|' || is_reverse_complement || '|' || query_length) AS uniq
            FROM virus_hits
            WHERE sample = ? AND tax_id = ?
            GROUP BY subject_seq_id
            ORDER BY uniq DESC
            LIMIT 5
            """
        var topAccStmt: OpaquePointer?
        defer { sqlite3_finalize(topAccStmt) }
        guard sqlite3_prepare_v2(db, topAccSQL, -1, &topAccStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accession query prepare failed: \(msg)")
        }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        while sqlite3_step(pairsStmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(pairsStmt, 0))
            let taxId = sqlite3_column_int(pairsStmt, 1)

            // Query top 5 accessions
            sqlite3_reset(topAccStmt)
            sqlite3_clear_bindings(topAccStmt)
            bindText(topAccStmt, 1, sample)
            sqlite3_bind_int(topAccStmt, 2, taxId)

            var accessions: [String] = []
            while sqlite3_step(topAccStmt) == SQLITE_ROW {
                accessions.append(String(cString: sqlite3_column_text(topAccStmt, 0)))
            }

            // Update summary row
            let json = "[" + accessions.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            bindText(updateStmt, 1, json)
            bindText(updateStmt, 2, sample)
            sqlite3_bind_int(updateStmt, 3, taxId)
            sqlite3_step(updateStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - SQLite Helpers

    /// Binds a Swift String to a sqlite3 statement parameter.
    private static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

/// Module-level bind helper (used by both static and instance methods).
private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter NaoMgsDatabaseTests 2>&1 | tail -20`

Expected: All 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift Tests/LungfishIntegrationTests/NaoMgsDatabaseTests.swift
git commit -m "feat: NaoMgsDatabase with create, bulk insert, and summary computation"
```

---

## Task 2: NaoMgsDatabase — Viewer Queries

**Files:**
- Modify: `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift`
- Modify: `Tests/LungfishIntegrationTests/NaoMgsDatabaseTests.swift`

Add query methods for the viewer: `fetchSamples`, `fetchTaxonSummaryRows`, `fetchAccessionSummaries`, `fetchReadsForAccession`.

- [ ] **Step 1: Write failing tests**

Append to `NaoMgsDatabaseTests.swift`:

```swift
    // MARK: - Sample Queries

    @Test
    func fetchSamplesReturnsDistinctSamplesWithCounts() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: syntheticHits()
        )

        let samples = try db.fetchSamples()
        #expect(samples.count == 2)
        #expect(samples.contains(where: { $0.sample == "SAMPLE_A" }))
        #expect(samples.contains(where: { $0.sample == "SAMPLE_B" }))
        // Each sample should have the same hit count (symmetric fixture)
        #expect(samples[0].hitCount == samples[1].hitCount)
    }

    // MARK: - Taxon Summary Queries

    @Test
    func fetchTaxonSummaryRowsReturnsPerSampleTaxonPairs() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: syntheticHits()
        )

        // All samples: should have 2 samples * 2 taxa = 4 rows
        let allRows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(allRows.count == 4)

        // Single sample filter
        let sampleARows = try db.fetchTaxonSummaryRows(samples: ["SAMPLE_A"])
        #expect(sampleARows.count == 2)
        #expect(sampleARows.allSatisfy { $0.sample == "SAMPLE_A" })

        // Sorted by hit count descending
        #expect(allRows[0].hitCount >= allRows[1].hitCount)
    }

    @Test
    func taxonSummaryHasCorrectUniqueReadCount() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Create hits with known duplicates
        var hits: [NaoMgsVirusHit] = []
        for i in 0..<5 {
            hits.append(NaoMgsVirusHit(
                sample: "S1", seqId: "read\(i)", taxId: 100,
                bestAlignmentScore: 100, cigar: "50M",
                queryStart: 0, queryEnd: 50,
                refStart: i < 3 ? 100 : 200,  // 3 reads at pos 100, 2 at pos 200
                refEnd: (i < 3 ? 100 : 200) + 50,
                readSequence: String(repeating: "A", count: 50),
                readQuality: String(repeating: "I", count: 50),
                subjectSeqId: "ACC1", subjectTitle: "Test",
                bitScore: 100, eValue: 1e-30, percentIdentity: 99,
                editDistance: 0, fragmentLength: 50,
                isReverseComplement: false, pairStatus: "CP", queryLength: 50
            ))
        }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: hits
        )

        let rows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(rows.count == 1)
        #expect(rows[0].hitCount == 5)
        // 2 unique positions (100 and 200), same strand/length = 2 unique reads
        #expect(rows[0].uniqueReadCount == 2)
        #expect(rows[0].pcrDuplicateCount == 3)
    }

    @Test
    func taxonSummaryHasTopAccessions() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: syntheticHits()
        )

        let rows = try db.fetchTaxonSummaryRows(samples: ["SAMPLE_A"])
        for row in rows {
            #expect(!row.topAccessions.isEmpty)
            #expect(row.topAccessions.count <= 5)
        }
    }

    // MARK: - Accession Summary Queries

    @Test
    func fetchAccessionSummariesReturnsPerAccessionData() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: syntheticHits()
        )

        // Taxon 111 has 3 accessions in the synthetic data
        let summaries = try db.fetchAccessionSummaries(sample: "SAMPLE_A", taxId: 111)
        #expect(summaries.count == 3)
        // Sorted by readCount descending
        #expect(summaries[0].readCount >= summaries[1].readCount)
    }

    // MARK: - Read Queries

    @Test
    func fetchReadsForAccessionReturnsAlignedReads() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: syntheticHits()
        )

        let reads = try db.fetchReadsForAccession(
            sample: "SAMPLE_A", taxId: 111, accession: "ACC001"
        )
        #expect(!reads.isEmpty)
        // Verify AlignedRead fields
        let read = reads[0]
        #expect(read.chromosome == "ACC001")
        #expect(!read.sequence.isEmpty)
        #expect(!read.cigar.isEmpty)
        #expect(read.position >= 0)
    }

    @Test
    func fetchReadsRespectsMaxReads() throws {
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let db = try NaoMgsDatabase.create(
            at: workspace.appendingPathComponent("hits.sqlite"),
            hits: syntheticHits()
        )

        let reads = try db.fetchReadsForAccession(
            sample: "SAMPLE_A", taxId: 111, accession: "ACC001", maxReads: 1
        )
        #expect(reads.count == 1)
    }
```

- [ ] **Step 2: Implement query methods**

Add to `NaoMgsDatabase`:

The `NaoMgsTaxonSummaryRow` struct (add to the same file or to `NaoMgsManifest.swift` — same file is simpler):

```swift
/// A single row in the taxonomy table — one per (sample, taxon) pair.
public struct NaoMgsTaxonSummaryRow: Sendable {
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
    public let topAccessions: [String]
}

/// Per-accession summary within a (sample, taxon) pair.
public struct NaoMgsAccessionSummary: Sendable {
    public let accession: String
    public let readCount: Int
    public let uniqueReadCount: Int
    public let estimatedRefLength: Int
    public let coverageFraction: Double
}
```

Add query methods to the class. Each method follows the pattern: prepare statement, bind parameters, step through rows, collect results, finalize.

`fetchSamples()`: `SELECT sample, COUNT(*) FROM virus_hits GROUP BY sample ORDER BY sample`

`fetchTaxonSummaryRows(samples:)`: `SELECT * FROM taxon_summaries WHERE sample IN (?) ORDER BY hit_count DESC` — decode `top_accessions_json` via `JSONDecoder` or simple string splitting.

`fetchAccessionSummaries(sample:taxId:)`: Query `virus_hits` grouped by `subject_seq_id` for the given sample+taxId. Compute unique reads per accession using the same dedup logic. Estimate ref length from `MAX(ref_start + query_length)`. Coverage fraction from count distinct ref_start / estimated length.

`fetchReadsForAccession(sample:taxId:accession:maxReads:)`: Query `virus_hits` rows, convert each to `AlignedRead`. Parse CIGAR via `CIGAROperation.parse()`. Convert quality string (Phred+33) to `[UInt8]`. Set flag to 0x10 for reverse complement. Compute mapq as `min(Int(bitScore / 5), 60)`.

The implementation is long but mechanical — follow the raw sqlite3 pattern from `VariantDatabase`. Read the file to see exact binding/stepping patterns.

- [ ] **Step 3: Run tests**

Run: `swift test --filter NaoMgsDatabaseTests 2>&1 | tail -20`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift Tests/LungfishIntegrationTests/NaoMgsDatabaseTests.swift
git commit -m "feat: NaoMgsDatabase viewer queries — samples, summaries, reads"
```

---

## Task 3: Import Pipeline — Replace JSON+BAM with SQLite

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`
- Modify: `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift` (remove `convertToSAM`)
- Modify: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsImportServiceTests.swift`

- [ ] **Step 1: Update existing tests to expect SQLite instead of JSON/BAM**

In `NaoMgsImportOptimizationTests.swift`, update `importNaoMgsWithFixtureCreatesValidBundle`:
- Replace checks for `virus_hits.json` with check for `hits.sqlite`
- Remove BAM-related assertions
- Replace JSON decode verification with `NaoMgsDatabase(at:)` queries
- Remove `includeAlignment: false` parameter (parameter removed)

In `MetagenomicsImportServiceTests.swift`, update `naoMgsImportCreatesCanonicalBundle`:
- Replace `virus_hits.json` check with `hits.sqlite` check
- Remove `includeAlignment: false` parameter

- [ ] **Step 2: Remove convertToSAM from NaoMgsResultParser**

In `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift`, delete the `convertToSAM` method (lines 649-748). This removes ~100 lines. The method is no longer called.

- [ ] **Step 3: Update MetagenomicsImportService.importNaoMgs**

In `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`, modify `importNaoMgs`:

1. Remove the `includeAlignment` parameter from the function signature
2. Remove the entire SAM/BAM conversion block (the section that calls `convertToSAM`, `samtools sort`, `samtools index`, and deletes the SAM file)
3. Replace the `virus_hits.json` writing section with:

```swift
            progress?(0.20, "Creating NAO-MGS database\u{2026}")
            let hitsDBURL = resultDirectory.appendingPathComponent("hits.sqlite")
            try NaoMgsDatabase.create(at: hitsDBURL, hits: filteredHits) { dbProgress, dbMessage in
                // Map database progress (0-1) into our overall progress range (0.20-0.68)
                progress?(0.20 + dbProgress * 0.48, dbMessage)
            }
```

4. Update `NaoMgsImportResult` usage — `createdBAM` is always false now. Consider removing the field or setting it to false. If other code reads `createdBAM`, set to false. Otherwise remove.

5. Remove the `references/` directory creation (the database doesn't need it unless `fetchReferences` is true — keep the references directory creation only inside the `if fetchReferences` block).

- [ ] **Step 4: Run tests**

Run: `swift test --filter NaoMgsImport 2>&1 | tail -20`
Run: `swift test --filter MetagenomicsImportServiceTests 2>&1 | tail -20`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsImportServiceTests.swift
git commit -m "feat: NAO-MGS import writes SQLite instead of JSON+BAM"
```

---

## Task 4: Remove includeAlignment Parameter Chain

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/App/MetagenomicsImportHelper.swift`
- Modify: `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift`
- Modify: `Sources/LungfishCLI/Commands/ImportCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/NaoMgsCommand.swift`

- [ ] **Step 1: NaoMgsImportSheet — remove toggle and parameter**

In `NaoMgsImportSheet.swift`:
- Remove `@State private var convertToSAM: Bool = true` (line 66)
- Remove the `Toggle("Convert to SAM for alignment view", ...)` from `optionsSection` (line 286-288)
- Change `onImport` callback type from `((URL, String, Bool, Double) -> Void)?` to `((URL, String, Double) -> Void)?` — remove the Bool
- Update `performImport()` to call `onImport?(url, sampleName, minIdentity)` — remove `convertToSAM`

- [ ] **Step 2: AppDelegate — update callback wiring**

In `AppDelegate.swift`, find `launchNaoMgsImport` (around line 3859). Update the `sheet.onImport` closure to match the new 3-parameter signature. Remove `convertToSAM` from the call to `importNaoMgsResultFromURL`.

Update `importNaoMgsResultFromURL` — remove the `includeAlignment` parameter. The `NaoMgsOptions` constructor no longer needs `includeAlignment`.

- [ ] **Step 3: MetagenomicsImportHelperClient — remove includeAlignment**

In `MetagenomicsImportHelperClient.swift`, remove `includeAlignment` from the `NaoMgsOptions` struct and its `init`. Remove the `--include-alignment` argument construction in `runHelper`.

- [ ] **Step 4: MetagenomicsImportHelper — remove argument parsing**

In `MetagenomicsImportHelper.swift`, remove `let includeAlignment = boolValue(for: "--include-alignment", ...)` and remove the parameter from the `MetagenomicsImportService.importNaoMgs` call.

- [ ] **Step 5: CLI commands — remove flags**

In `ImportCommand.swift`, find the `NaoMgsSubcommand`. Remove the `--sam`/`--include-alignment` flag. Remove `includeAlignment` from the `MetagenomicsImportService.importNaoMgs` call.

In `NaoMgsCommand.swift`, find the `ImportSubcommand`. Remove the `--sam` flag and related logic.

- [ ] **Step 6: Build**

Run: `swift build --build-tests 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishApp/App/MetagenomicsImportHelper.swift Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift Sources/LungfishCLI/Commands/ImportCommand.swift Sources/LungfishCLI/Commands/NaoMgsCommand.swift
git commit -m "refactor: remove includeAlignment/convertToSAM from NAO-MGS parameter chain"
```

---

## Task 5: MiniBAMViewController — displayReads Method

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`

- [ ] **Step 1: Add displayReads method**

Add a new public method to `MiniBAMViewController` (after the existing `displayContig` method, around line 517):

```swift
    /// Displays pre-fetched reads directly, without invoking samtools.
    ///
    /// Use this for NAO-MGS results where reads come from a SQLite database
    /// rather than a BAM file. The existing `displayContig(bamURL:...)` method
    /// remains for regular BAM viewing (EsViritu, alignment viewport, etc.).
    ///
    /// - Parameters:
    ///   - reads: Pre-fetched aligned reads.
    ///   - contig: Reference sequence name (accession).
    ///   - contigLength: Length of the reference sequence.
    public func displayReads(reads: [AlignedRead], contig: String, contigLength: Int) {
        loadTask?.cancel()
        self.bamURL = nil
        self.indexURL = nil
        self.contigName = contig
        self.contigLength = contigLength

        self.allReads = reads
        self.allDuplicateIndices = detectDuplicates(in: reads)
        self.pcrDuplicateReadCount = allDuplicateIndices.count
        self.uniqueReadCount = max(0, reads.count - pcrDuplicateReadCount)
        self.applyDuplicateVisibility(rebuildReference: true)

        scrollToTop()
        updateZoomStatus()

        logger.info("Displayed \(reads.count) pre-fetched reads for \(contig, privacy: .public), \(self.pcrDuplicateReadCount) potential duplicates")
    }
```

This method does exactly what the successful path of `displayContig` does (lines 500-510) but without the async fetch.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift
git commit -m "feat: MiniBAMViewController.displayReads for pre-fetched reads"
```

---

## Task 6: Sample Picker Popover (SwiftUI)

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift`

- [ ] **Step 1: Create the SwiftUI sample picker view**

Create `Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift`:

```swift
// NaoMgsSamplePickerView.swift — SwiftUI popover for NAO-MGS sample multi-select
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A sample entry in the picker list.
struct NaoMgsSampleEntry: Identifiable {
    let id: String  // full sample name (used as key)
    let displayName: String  // prefix-stripped name
    let hitCount: Int
}

/// SwiftUI popover content for selecting NAO-MGS samples.
///
/// Shows a searchable, scrollable list of samples with checkboxes and hit counts.
/// Common prefixes shared by all samples are stripped from display names.
struct NaoMgsSamplePickerView: View {

    let samples: [NaoMgsSampleEntry]
    @Binding var selectedSamples: Set<String>
    @State private var searchText: String = ""

    /// The common prefix stripped from display (shown as caption).
    let strippedPrefix: String

    private var filteredSamples: [NaoMgsSampleEntry] {
        if searchText.isEmpty { return samples }
        return samples.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var allVisibleSelected: Bool {
        let visibleIds = Set(filteredSamples.map(\.id))
        return !visibleIds.isEmpty && visibleIds.isSubset(of: selectedSamples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Filter\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Select All toggle
            HStack {
                Toggle(isOn: Binding(
                    get: { allVisibleSelected },
                    set: { newValue in
                        let visibleIds = Set(filteredSamples.map(\.id))
                        if newValue {
                            selectedSamples.formUnion(visibleIds)
                        } else {
                            selectedSamples.subtract(visibleIds)
                        }
                    }
                )) {
                    Text("Select All")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)

                Spacer()

                Text("\(samples.count) total")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if !strippedPrefix.isEmpty {
                Text("Prefix: \(strippedPrefix)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            Divider()

            // Sample list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredSamples) { sample in
                        sampleRow(sample)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 360)
    }

    private func sampleRow(_ sample: NaoMgsSampleEntry) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { selectedSamples.contains(sample.id) },
                set: { newValue in
                    if newValue {
                        selectedSamples.insert(sample.id)
                    } else {
                        selectedSamples.remove(sample.id)
                    }
                }
            )) {
                Text(sample.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)

            Spacer()

            Text(formatNumber(sample.hitCount))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Computes the longest common prefix across all sample names.
    static func commonPrefix(of names: [String]) -> String {
        guard let first = names.first else { return "" }
        var prefix = first
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) && !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        // Only strip if it ends at a word boundary (_, -, or end of string)
        if let lastSep = prefix.lastIndex(where: { $0 == "_" || $0 == "-" }) {
            prefix = String(prefix[...lastSep])
        } else {
            prefix = ""
        }
        return prefix
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift
git commit -m "feat: NaoMgsSamplePickerView — SwiftUI popover for sample multi-select"
```

---

## Task 7: NaoMgsResultViewController — Database Integration + Sample Picker

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

This is the largest task — it rewires the entire viewer to use the database. The implementer should read the existing file thoroughly before making changes.

- [ ] **Step 1: Update MainSplitViewController to load from SQLite**

In `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`, find `displayNaoMgsResultFromSidebar(at:)` (around line 1853). Replace the async loading block that reads `manifest.json` and `virus_hits.json` with:

1. Read `manifest.json` (keep this — it has sample name, source path)
2. Open `hits.sqlite` via `NaoMgsDatabase(at:)` instead of reading `virus_hits.json`
3. Pass the database and manifest to `placeholderVC.configure(database:manifest:bundleURL:)` instead of `configure(result:bundleURL:)`

The new configure signature:

```swift
public func configure(database: NaoMgsDatabase, manifest: NaoMgsManifest, bundleURL: URL)
```

- [ ] **Step 2: Rewrite NaoMgsResultViewController to use database**

Major changes to `NaoMgsResultViewController.swift`:

**Properties to change:**
- Remove `naoMgsResult: NaoMgsResult?` — replaced by `database: NaoMgsDatabase?`
- Remove `hitsByTaxon: [Int: [NaoMgsVirusHit]]` — no longer needed
- Remove `bamURL`, `bamIndexURL` — no BAM file
- Add `database: NaoMgsDatabase?`
- Add `manifest: NaoMgsManifest?`
- Add `allSamples: [(sample: String, hitCount: Int)]` — from `db.fetchSamples()`
- Add `selectedSamples: Set<String>` — for sample filtering
- Add `sampleEntries: [NaoMgsSampleEntry]` — for the picker
- Add `strippedPrefix: String` — common prefix for display
- Replace `sampleFilterField: NSSearchField` with `sampleFilterButton: NSButton`

**configure(database:manifest:bundleURL:):**
- Store database, manifest, bundleURL
- Call `db.fetchSamples()` to populate sample list
- Compute common prefix and create `NaoMgsSampleEntry` array
- Set `selectedSamples` to all samples
- Call `reloadTaxonomyTable()`

**Taxonomy table:**
- Add a "Sample" column to the table
- `displayedSummaries` becomes `displayedRows: [NaoMgsTaxonSummaryRow]`
- Data comes from `db.fetchTaxonSummaryRows(samples: Array(selectedSamples))`
- Apply remaining text filters (taxon name, min hits, etc.) in-memory on the returned rows
- When only 1 sample selected, hide the Sample column

**Sample filter button:**
- Replace `sampleFilterField` with an `NSButton` in the filter bar
- On click, show `NSPopover` containing `NaoMgsSamplePickerView` via `NSHostingView`
- On popover dismiss (or binding change), call `reloadTaxonomyTable()`
- Button title: "All Samples" or "N of M Samples" or single sample name

**Taxon detail / miniBAM:**
- `showTaxonDetail` now receives a `NaoMgsTaxonSummaryRow` (has sample + taxId)
- `buildMiniBAMList` changes:
  - Fetch accession summaries via `db.fetchAccessionSummaries(sample:taxId:)`
  - For each accession, fetch reads via `db.fetchReadsForAccession(sample:taxId:accession:)`
  - Call `miniBAM.displayReads(reads:contig:contigLength:)` instead of `miniBAM.displayContig(bamURL:...)`
  - No `bamURL`/`bamIndexURL` needed

**Remove:**
- `discoverBAMFile(in:sampleName:)` method
- Sample name resolution from hits (`sampleNames`, `sampleLabel(forTaxId:)`)
- In-memory hit grouping, duplicate computation, summary enrichment

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1 | tail -10`

Expected: Build succeeds. Some unused-variable warnings may appear — clean those up.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift
git commit -m "feat: NaoMgsResultViewController uses SQLite database + sample picker"
```

---

## Task 8: Update Toy Fixture for Multi-Sample + Final Tests

**Files:**
- Modify: `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift`

The toy fixture has only 1 sample (`MU-CASPER-2026-03-31-a-Water_20260323_S26_L001`). The sample picker and per-sample summaries need multi-sample data for meaningful testing.

- [ ] **Step 1: Add multi-sample integration test using synthetic data**

Append to `NaoMgsImportOptimizationTests.swift`:

```swift
    // MARK: - Multi-Sample Database Tests

    @Test
    func importNaoMgsWithMultipleSamplesCreatesSQLite() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-multisample-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Create a multi-sample TSV inline
        let tsvContent = """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status
        SAMPLE_A\treadA1\t111\tACGTACGT\tIIIIIIII\tACC001\t10\t0\t8\tFalse\tCP
        SAMPLE_A\treadA2\t111\tACGTACGA\tIIIIIIII\tACC001\t10\t1\t8\tFalse\tCP
        SAMPLE_A\treadA3\t222\tACGTACGG\tIIIIIIII\tACC002\t30\t0\t8\tTrue\tCP
        SAMPLE_B\treadB1\t111\tACGTACGT\tIIIIIIII\tACC001\t50\t0\t8\tFalse\tCP
        SAMPLE_B\treadB2\t333\tACGTACGC\tIIIIIIII\tACC003\t70\t2\t8\tFalse\tUP
        """
        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try tsvContent.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "MULTI_TEST",
            fetchReferences: false
        )

        // Verify SQLite exists, no JSON or BAM
        let bundle = result.resultDirectory
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("hits.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("virus_hits.json").path))

        // Open and query
        let db = try NaoMgsDatabase(at: bundle.appendingPathComponent("hits.sqlite"))

        // 2 samples
        let samples = try db.fetchSamples()
        #expect(samples.count == 2)

        // Sample A: taxon 111 (2 hits), taxon 222 (1 hit)
        let sampleARows = try db.fetchTaxonSummaryRows(samples: ["SAMPLE_A"])
        #expect(sampleARows.count == 2)

        // Sample B: taxon 111 (1 hit), taxon 333 (1 hit)
        let sampleBRows = try db.fetchTaxonSummaryRows(samples: ["SAMPLE_B"])
        #expect(sampleBRows.count == 2)

        // All samples: 3 distinct taxa across both
        let allRows = try db.fetchTaxonSummaryRows(samples: nil)
        // SAMPLE_A has tax 111, 222; SAMPLE_B has tax 111, 333 → 4 rows total (2+2)
        #expect(allRows.count == 4)

        // Unique reads: SAMPLE_A taxon 111 has 2 hits at same position → 1 unique
        let taxA111 = sampleARows.first(where: { $0.taxId == 111 })
        #expect(taxA111 != nil)
        #expect(taxA111?.hitCount == 2)
        #expect(taxA111?.uniqueReadCount == 1, "Two reads at same position should be 1 unique")
    }
```

- [ ] **Step 2: Run all tests**

Run: `swift test --filter NaoMgs 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift
git commit -m "test: multi-sample integration test for SQLite-backed NAO-MGS import"
```

---

## Task 9: Run Full Test Suite

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 2: Check for compilation warnings**

Run: `swift build 2>&1 | grep -i "warning:" | head -20`

Fix any new warnings (unused variables from removed BAM code, etc.).

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: clean up warnings from SQLite migration"
```
