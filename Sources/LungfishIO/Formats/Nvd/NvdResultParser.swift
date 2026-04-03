// NvdResultParser.swift - Parser for NVD (Novel Virus Diagnostics) BLAST results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "NvdResultParser")

// MARK: - NvdParserError

/// Errors that can occur during NVD result parsing.
public enum NvdParserError: Error, LocalizedError, Sendable {
    /// The input file was not found.
    case fileNotFound(URL)

    /// The CSV header is missing or does not contain expected columns.
    case invalidHeader(String)

    /// A data row could not be parsed.
    case malformedRow(lineNumber: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "NVD result file not found: \(url.path)"
        case .invalidHeader(let details):
            return "Invalid NVD CSV header: \(details)"
        case .malformedRow(let line, let reason):
            return "Malformed row at line \(line): \(reason)"
        }
    }
}

// MARK: - NvdBlastHit

/// A single BLAST hit from the NVD `*_blast_concatenated.csv` output.
///
/// Each row represents one BLAST alignment of an assembled contig against a
/// reference database. A contig (qseqid) can have up to 5 BLAST hits, ranked
/// by e-value ascending (lower e-value = better hit).
public struct NvdBlastHit: Sendable, Codable, Equatable {

    // MARK: Raw CSV Fields

    /// Experiment identifier (numeric string, e.g. "100").
    public let experiment: String

    /// BLAST task used (e.g. "megablast", "blastn").
    public let blastTask: String

    /// Sample identifier from the workflow run.
    public let sampleId: String

    /// Query sequence ID (assembled contig name, e.g. "NODE_1_length_500_cov_10.0").
    public let qseqid: String

    /// Query sequence length in bases.
    public let qlen: Int

    /// Subject sequence ID, cleaned from the `gi|...|gb|ACCESSION|` format.
    ///
    /// Raw value like `gi|123456|gb|NC_045512.2|` is reduced to `NC_045512.2`.
    public let sseqid: String

    /// Subject sequence title (may contain commas — the CSV field is quoted).
    public let stitle: String

    /// Taxonomic rank of the BLAST hit (e.g. "species:SARS-CoV-2").
    public let taxRank: String

    /// Alignment length in bases.
    public let length: Int

    /// Percent identity of the alignment.
    public let pident: Double

    /// BLAST e-value.
    public let evalue: Double

    /// BLAST bit score.
    public let bitscore: Double

    /// Scientific name(s) of the subject organism.
    public let sscinames: String

    /// NCBI taxonomy ID(s) of the subject.
    public let staxids: String

    /// BLAST database version used.
    public let blastDbVersion: String

    /// Snakemake run identifier.
    public let snakemakeRunId: String

    /// Number of reads that mapped to this contig.
    public let mappedReads: Int

    /// Total reads in the sample used for normalization.
    public let totalReads: Int

    /// Statistics database version.
    public let statDbVersion: String

    /// Adjusted NCBI taxonomy ID (after adjustment_method).
    public let adjustedTaxid: String

    /// Method used for taxonomy adjustment (e.g. "dominant").
    public let adjustmentMethod: String

    /// Name of the adjusted taxon.
    public let adjustedTaxidName: String

    /// Rank of the adjusted taxon (e.g. "species").
    public let adjustedTaxidRank: String

    // MARK: Derived Fields

    /// Rank of this hit among all BLAST hits for the same (sample_id, qseqid) group.
    ///
    /// Hits are ordered by evalue ascending (lower = better). When evalues are equal
    /// (e.g. both 0.0), bitscore descending is used as a tiebreaker. Ranks start at 1.
    public let hitRank: Int

    /// Reads per billion: `mappedReads / totalReads * 1e9`.
    ///
    /// Returns 0.0 when totalReads is zero.
    public let readsPerBillion: Double
}

// MARK: - NvdParseResult

/// Aggregated results from parsing an NVD blast_concatenated.csv file.
public struct NvdParseResult: Sendable {
    /// All parsed BLAST hits, in the order they appear in the file.
    public let hits: [NvdBlastHit]

    /// Experiment identifier from the first row (or empty string if no rows).
    public let experiment: String

    /// Set of distinct sample IDs found in the file.
    public let sampleIds: Set<String>

    public init(hits: [NvdBlastHit], experiment: String, sampleIds: Set<String>) {
        self.hits = hits
        self.experiment = experiment
        self.sampleIds = sampleIds
    }
}

// MARK: - NvdResultParser

/// Parser for NVD (Novel Virus Diagnostics) pipeline BLAST results.
///
/// Parses the `*_blast_concatenated.csv` file produced by the NVD Snakemake
/// pipeline for wastewater viral surveillance. The CSV has 23 columns and
/// the `stitle` field may contain commas (it is quoted).
///
/// ## Usage
///
/// ```swift
/// let parser = NvdResultParser()
/// let result = try await parser.parse(at: csvURL)
/// print("Parsed \(result.hits.count) hits from \(result.sampleIds.count) samples")
/// ```
///
/// ## Derived Fields
///
/// - `hitRank`: 1-based rank per (sample_id, qseqid) group, ordered by evalue
///   ascending. Ties broken by bitscore descending.
/// - `readsPerBillion`: `mappedReads / totalReads * 1e9` for abundance normalization.
public final class NvdResultParser: @unchecked Sendable {

    /// Required column names in the CSV header.
    private static let requiredColumns: Set<String> = [
        "experiment", "blast_task", "sample_id", "qseqid", "qlen",
        "sseqid", "stitle", "tax_rank", "length", "pident", "evalue",
        "bitscore", "sscinames", "staxids", "blast_db_version",
        "snakemake_run_id", "mapped_reads", "total_reads", "stat_db_version",
        "adjusted_taxid", "adjustment_method", "adjusted_taxid_name",
        "adjusted_taxid_rank"
    ]

    public init() {}

    // MARK: - Public API

    /// Parses a `*_blast_concatenated.csv` file into an ``NvdParseResult``.
    ///
    /// - Parameters:
    ///   - url: Path to the blast_concatenated.csv file.
    ///   - lineProgress: Optional callback invoked periodically with the current line number.
    /// - Returns: Parsed result containing all hits, experiment ID, and sample IDs.
    /// - Throws: ``NvdParserError`` if the file is missing, the header is invalid,
    ///   or a required field cannot be parsed.
    public func parse(
        at url: URL,
        lineProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> NvdParseResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NvdParserError.fileNotFound(url)
        }

        logger.info("Parsing NVD BLAST results from \(url.lastPathComponent)")

        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.components(separatedBy: "\n")

        // Remove trailing empty lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        guard !lines.isEmpty else {
            throw NvdParserError.invalidHeader("File is empty")
        }

        // Parse header
        let headerLine = lines[0]
        let headers = parseCSVRow(headerLine)

        // Validate required columns
        let headerSet = Set(headers.map { $0.lowercased() })
        let missing = NvdResultParser.requiredColumns.subtracting(headerSet)
        guard missing.isEmpty else {
            throw NvdParserError.invalidHeader(
                "Missing required columns: \(missing.sorted().joined(separator: ", "))"
            )
        }

        // Build column index map
        var colIndex: [String: Int] = [:]
        for (i, header) in headers.enumerated() {
            colIndex[header.lowercased()] = i
        }

        // If only the header line exists, return empty result
        if lines.count == 1 {
            logger.info("NVD CSV has header only, no data rows")
            return NvdParseResult(hits: [], experiment: "", sampleIds: [])
        }

        // Parse data rows into raw records
        struct RawRecord {
            let experiment: String
            let blastTask: String
            let sampleId: String
            let qseqid: String
            let qlen: Int
            let sseqid: String
            let stitle: String
            let taxRank: String
            let length: Int
            let pident: Double
            let evalue: Double
            let bitscore: Double
            let sscinames: String
            let staxids: String
            let blastDbVersion: String
            let snakemakeRunId: String
            let mappedReads: Int
            let totalReads: Int
            let statDbVersion: String
            let adjustedTaxid: String
            let adjustmentMethod: String
            let adjustedTaxidName: String
            let adjustedTaxidRank: String
        }

        var rawRecords: [RawRecord] = []
        rawRecords.reserveCapacity(lines.count - 1)

        let requiredFieldCount = headers.count

        for (lineOffset, line) in lines.dropFirst().enumerated() {
            let lineNumber = lineOffset + 2  // 1-based, header is line 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let progress = lineProgress, lineOffset % 1000 == 0 {
                progress(lineNumber)
            }

            let fields = parseCSVRow(trimmed)

            guard fields.count >= requiredFieldCount else {
                throw NvdParserError.malformedRow(
                    lineNumber: lineNumber,
                    reason: "Expected \(requiredFieldCount) fields, got \(fields.count)"
                )
            }

            func str(_ col: String) -> String {
                guard let idx = colIndex[col], idx < fields.count else { return "" }
                return fields[idx]
            }

            func intVal(_ col: String) throws -> Int {
                let raw = str(col)
                guard let v = Int(raw) else {
                    throw NvdParserError.malformedRow(
                        lineNumber: lineNumber,
                        reason: "Cannot parse integer for '\(col)': '\(raw)'"
                    )
                }
                return v
            }

            func dblVal(_ col: String) throws -> Double {
                let raw = str(col)
                // Handle scientific notation like "1e-200" and "0.0"
                guard let v = Double(raw) else {
                    throw NvdParserError.malformedRow(
                        lineNumber: lineNumber,
                        reason: "Cannot parse double for '\(col)': '\(raw)'"
                    )
                }
                return v
            }

            // Extract clean accession from gi|...|gb|ACCESSION| format
            let rawSseqid = str("sseqid")
            let cleanSseqid = extractAccession(from: rawSseqid)

            let record = RawRecord(
                experiment: str("experiment"),
                blastTask: str("blast_task"),
                sampleId: str("sample_id"),
                qseqid: str("qseqid"),
                qlen: try intVal("qlen"),
                sseqid: cleanSseqid,
                stitle: str("stitle"),
                taxRank: str("tax_rank"),
                length: try intVal("length"),
                pident: try dblVal("pident"),
                evalue: try dblVal("evalue"),
                bitscore: try dblVal("bitscore"),
                sscinames: str("sscinames"),
                staxids: str("staxids"),
                blastDbVersion: str("blast_db_version"),
                snakemakeRunId: str("snakemake_run_id"),
                mappedReads: try intVal("mapped_reads"),
                totalReads: try intVal("total_reads"),
                statDbVersion: str("stat_db_version"),
                adjustedTaxid: str("adjusted_taxid"),
                adjustmentMethod: str("adjustment_method"),
                adjustedTaxidName: str("adjusted_taxid_name"),
                adjustedTaxidRank: str("adjusted_taxid_rank")
            )
            rawRecords.append(record)
        }

        lineProgress?(lines.count)

        // Compute hit ranks per (sample_id, qseqid) group
        // Group indices by (sampleId, qseqid)
        var groupMap: [String: [Int]] = [:]
        for (i, rec) in rawRecords.enumerated() {
            let key = "\(rec.sampleId)\u{1F}\(rec.qseqid)"
            groupMap[key, default: []].append(i)
        }

        var ranks = Array(repeating: 0, count: rawRecords.count)
        for (_, indices) in groupMap {
            // Sort indices by evalue ascending, then bitscore descending for ties
            let sorted = indices.sorted { a, b in
                let ra = rawRecords[a]
                let rb = rawRecords[b]
                if ra.evalue != rb.evalue {
                    return ra.evalue < rb.evalue
                }
                return ra.bitscore > rb.bitscore
            }
            for (rank, idx) in sorted.enumerated() {
                ranks[idx] = rank + 1
            }
        }

        // Build final hit objects
        var hits: [NvdBlastHit] = []
        hits.reserveCapacity(rawRecords.count)

        var experimentId = ""
        var sampleIds: Set<String> = []

        for (i, rec) in rawRecords.enumerated() {
            if experimentId.isEmpty { experimentId = rec.experiment }
            sampleIds.insert(rec.sampleId)

            let rpb: Double
            if rec.totalReads > 0 {
                rpb = Double(rec.mappedReads) / Double(rec.totalReads) * 1_000_000_000.0
            } else {
                rpb = 0.0
            }

            let hit = NvdBlastHit(
                experiment: rec.experiment,
                blastTask: rec.blastTask,
                sampleId: rec.sampleId,
                qseqid: rec.qseqid,
                qlen: rec.qlen,
                sseqid: rec.sseqid,
                stitle: rec.stitle,
                taxRank: rec.taxRank,
                length: rec.length,
                pident: rec.pident,
                evalue: rec.evalue,
                bitscore: rec.bitscore,
                sscinames: rec.sscinames,
                staxids: rec.staxids,
                blastDbVersion: rec.blastDbVersion,
                snakemakeRunId: rec.snakemakeRunId,
                mappedReads: rec.mappedReads,
                totalReads: rec.totalReads,
                statDbVersion: rec.statDbVersion,
                adjustedTaxid: rec.adjustedTaxid,
                adjustmentMethod: rec.adjustmentMethod,
                adjustedTaxidName: rec.adjustedTaxidName,
                adjustedTaxidRank: rec.adjustedTaxidRank,
                hitRank: ranks[i],
                readsPerBillion: rpb
            )
            hits.append(hit)
        }

        logger.info("Parsed \(hits.count) NVD BLAST hits from \(rawRecords.count) rows, \(sampleIds.count) samples")
        return NvdParseResult(hits: hits, experiment: experimentId, sampleIds: sampleIds)
    }

    // MARK: - CSV Parsing

    /// Parses a single CSV row, handling double-quoted fields that may contain commas.
    ///
    /// Follows RFC 4180 quoting rules: fields may be optionally enclosed in double
    /// quotes; a double-quote inside a quoted field is escaped by doubling it (`""`).
    private func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var idx = line.startIndex

        while idx < line.endIndex {
            let ch = line[idx]

            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: idx)
                    if next < line.endIndex && line[next] == "\"" {
                        // Escaped double-quote inside quoted field
                        current.append("\"")
                        idx = line.index(after: next)
                        continue
                    } else {
                        // End of quoted field
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }

            idx = line.index(after: idx)
        }

        fields.append(current)
        return fields
    }

    // MARK: - Accession Extraction

    /// Extracts a clean GenBank accession from a `gi|...|gb|ACCESSION|` string.
    ///
    /// For example: `gi|123456|gb|NC_045512.2|` → `NC_045512.2`
    ///
    /// If the string doesn't match the `gi|` format, returns the original string.
    private func extractAccession(from sseqid: String) -> String {
        // Split by '|' and look for the accession at index 3
        // Format: gi | GI_NUMBER | db_type | ACCESSION | (optional trailing empty)
        let parts = sseqid.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0) }
        guard parts.count >= 4,
              parts[0].lowercased() == "gi" else {
            return sseqid
        }
        return parts[3]
    }
}
