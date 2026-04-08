// NaoMgsBamMaterializer.swift - Generates BAM files from NAO-MGS SQLite rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "NaoMgsBamMaterializer")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Generates real BAM files from NAO-MGS SQLite virus_hits rows so the
/// miniBAM viewer can use the standard `displayContig(bamURL:...)` code path
/// and benefit from samtools markdup PCR duplicate detection.
///
/// Output location: `<resultURL>/bams/<sample>.bam` (+ `.bai` index)
public enum NaoMgsBamMaterializer {

    /// Materializes BAM files for every sample in a NAO-MGS result directory.
    ///
    /// Idempotent: skips samples whose BAM already exists and is already markdup'd.
    /// After generation, runs MarkdupService.markdup() on each BAM.
    ///
    /// - Parameters:
    ///   - dbPath: Path to the NAO-MGS SQLite database.
    ///   - resultURL: Result directory (BAMs written to `<resultURL>/bams/`).
    ///   - samtoolsPath: Path to samtools binary.
    ///   - force: Regenerate BAMs even if they already exist.
    /// - Returns: URLs of generated (or existing) BAM files.
    public static func materializeAll(
        dbPath: String,
        resultURL: URL,
        samtoolsPath: String,
        force: Bool = false
    ) throws -> [URL] {
        let fm = FileManager.default
        let bamsDir = resultURL.appendingPathComponent("bams")
        try fm.createDirectory(at: bamsDir, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open NAO-MGS database at \(dbPath)"])
        }
        defer { sqlite3_close(db) }

        // 1. Fetch all distinct samples
        let samples = try fetchSamples(db: db)

        // 2. Fetch all reference lengths (shared across samples)
        let allRefLengths = try fetchReferenceLengths(db: db)

        var generated: [URL] = []
        for sample in samples {
            let bamURL = bamsDir.appendingPathComponent("\(sample).bam")

            if !force && fm.fileExists(atPath: bamURL.path) {
                // Already generated; ensure markdup has been run
                _ = try? MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
                generated.append(bamURL)
                continue
            }

            try generateBam(
                db: db,
                sample: sample,
                refLengths: allRefLengths,
                bamURL: bamURL,
                samtoolsPath: samtoolsPath
            )
            _ = try? MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
            generated.append(bamURL)

            logger.info("Materialized NAO-MGS BAM for sample \(sample, privacy: .public)")
        }

        return generated
    }

    // MARK: - Private

    private static func fetchSamples(db: OpaquePointer?) throws -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT sample FROM virus_hits ORDER BY sample"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare sample query"])
        }
        defer { sqlite3_finalize(stmt) }
        var samples: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                samples.append(String(cString: ptr))
            }
        }
        return samples
    }

    private static func fetchReferenceLengths(db: OpaquePointer?) throws -> [String: Int] {
        var stmt: OpaquePointer?
        let sql = "SELECT accession, length FROM reference_lengths"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]  // table may not exist in older databases
        }
        defer { sqlite3_finalize(stmt) }
        var map: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let accPtr = sqlite3_column_text(stmt, 0) {
                let acc = String(cString: accPtr)
                let len = Int(sqlite3_column_int64(stmt, 1))
                map[acc] = len
            }
        }
        return map
    }

    /// Synthesizes SAM text for a single sample's virus_hits rows, then pipes
    /// through `samtools view -bS - | samtools sort -o` to produce a sorted BAM.
    private static func generateBam(
        db: OpaquePointer?,
        sample: String,
        refLengths: [String: Int],
        bamURL: URL,
        samtoolsPath: String
    ) throws {
        // 1. Collect accessions used by this sample to build @SQ header lines
        var usedAccessions: Set<String> = []
        var accStmt: OpaquePointer?
        let accSQL = "SELECT DISTINCT subject_seq_id FROM virus_hits WHERE sample = ?"
        guard sqlite3_prepare_v2(db, accSQL, -1, &accStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare accession query"])
        }
        sample.withCString { cStr in
            sqlite3_bind_text(accStmt, 1, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        }
        while sqlite3_step(accStmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(accStmt, 0) {
                usedAccessions.insert(String(cString: ptr))
            }
        }
        sqlite3_finalize(accStmt)

        guard !usedAccessions.isEmpty else {
            logger.warning("No virus_hits for sample \(sample, privacy: .public); skipping BAM generation")
            return
        }

        // 2. Write SAM text: header + alignment lines
        var sam = "@HD\tVN:1.6\tSO:unsorted\n"
        for accession in usedAccessions.sorted() {
            let length = refLengths[accession] ?? 100000  // fallback when reference_lengths missing
            sam += "@SQ\tSN:\(accession)\tLN:\(length)\n"
        }
        sam += "@PG\tID:lungfish-naomgs-materializer\tPN:lungfish\tVN:1.0\n"

        // 3. Fetch alignment rows and append SAM lines
        var rowStmt: OpaquePointer?
        let rowSQL = """
        SELECT seq_id, subject_seq_id, ref_start, cigar, read_sequence, read_quality, is_reverse_complement
        FROM virus_hits
        WHERE sample = ?
        """
        guard sqlite3_prepare_v2(db, rowSQL, -1, &rowStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare row query"])
        }
        defer { sqlite3_finalize(rowStmt) }
        sample.withCString { cStr in
            sqlite3_bind_text(rowStmt, 1, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        }

        while sqlite3_step(rowStmt) == SQLITE_ROW {
            guard let seqIdPtr = sqlite3_column_text(rowStmt, 0),
                  let subjPtr = sqlite3_column_text(rowStmt, 1),
                  let cigarPtr = sqlite3_column_text(rowStmt, 3),
                  let seqPtr = sqlite3_column_text(rowStmt, 4),
                  let qualPtr = sqlite3_column_text(rowStmt, 5) else { continue }
            let qname = String(cString: seqIdPtr)
            let rname = String(cString: subjPtr)
            let refStart = Int(sqlite3_column_int64(rowStmt, 2))
            let cigar = String(cString: cigarPtr)
            let seq = String(cString: seqPtr)
            let qual = String(cString: qualPtr)
            let isReverse = sqlite3_column_int(rowStmt, 6) != 0
            let flag = isReverse ? 16 : 0
            let pos = refStart + 1  // 0-based to 1-based
            let mapq = 60

            sam += "\(qname)\t\(flag)\t\(rname)\t\(pos)\t\(mapq)\t\(cigar)\t*\t0\t0\t\(seq)\t\(qual)\n"
        }

        // 4. Pipe SAM text through samtools view -bS - | samtools sort -o <bam>
        let cmd = """
        "\(samtoolsPath)" view -bS - | "\(samtoolsPath)" sort -o "\(bamURL.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()

        // Write SAM to the pipe's input handle in a background queue to avoid deadlock
        let samData = sam.data(using: .utf8) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            inPipe.fileHandleForWriting.write(samData)
            try? inPipe.fileHandleForWriting.close()
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "NaoMgsBamMaterializer", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "samtools pipeline failed: \(stderr)"])
        }

        // 5. Index the output BAM
        let indexProc = Process()
        indexProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        indexProc.arguments = ["index", bamURL.path]
        indexProc.standardOutput = FileHandle.nullDevice
        indexProc.standardError = FileHandle.nullDevice
        try indexProc.run()
        indexProc.waitUntilExit()
        guard indexProc.terminationStatus == 0 else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "samtools index failed for \(bamURL.path)"])
        }
    }
}
