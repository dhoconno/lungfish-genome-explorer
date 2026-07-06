// NaoMgsDatabase+Queries.swift - Read-only queries for NAO-MGS database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension NaoMgsDatabase {

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
