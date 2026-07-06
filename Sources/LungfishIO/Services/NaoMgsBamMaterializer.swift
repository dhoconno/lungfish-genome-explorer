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

public struct NaoMgsBamMaterializationResult: Sendable {
    public let bamURLs: [URL]
    public let steps: [NaoMgsBamMaterializationStep]

    public init(bamURLs: [URL], steps: [NaoMgsBamMaterializationStep]) {
        self.bamURLs = bamURLs
        self.steps = steps
    }
}

public struct NaoMgsBamMaterializationStep: Sendable {
    public let sample: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let inputURLs: [URL]
    public let outputURLs: [URL]
    public let exitStatus: Int?
    public let wallTimeSeconds: TimeInterval?
    public let stderr: String?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        sample: String,
        toolName: String,
        toolVersion: String = "unknown",
        argv: [String],
        reproducibleCommand: String? = nil,
        inputURLs: [URL] = [],
        outputURLs: [URL] = [],
        exitStatus: Int? = nil,
        wallTimeSeconds: TimeInterval? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.sample = sample
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand ?? argv.map(naoMgsShellEscape).joined(separator: " ")
        self.inputURLs = inputURLs
        self.outputURLs = outputURLs
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Generates real BAM files from NAO-MGS SQLite virus_hits rows so the
/// miniBAM viewer can use the standard `displayContig(bamURL:...)` code path
/// and benefit from samtools markdup PCR duplicate detection.
///
/// Output location: `<resultURL>/bams/<sample>.bam` (+ `.bai` index)
public enum NaoMgsBamMaterializer {

    /// Materializes BAM files for every sample in a NAO-MGS result directory.
    ///
    /// Idempotent: skips samples whose BAM already exists and is already markdup'd.
    /// By default, after generation, runs MarkdupService.markdup() on each BAM.
    ///
    /// - Parameters:
    ///   - dbPath: Path to the NAO-MGS SQLite database.
    ///   - resultURL: Result directory (BAMs written to `<resultURL>/bams/`).
    ///   - samtoolsPath: Path to samtools binary.
    ///   - force: Regenerate BAMs even if they already exist.
    ///   - markDuplicates: Whether to run the legacy materializer markdup/index pass.
    /// - Returns: URLs of generated (or existing) BAM files.
    public static func materializeAll(
        dbPath: String,
        resultURL: URL,
        samtoolsPath: String,
        force: Bool = false,
        markDuplicates: Bool = true
    ) throws -> [URL] {
        try materializeAllWithProvenance(
            dbPath: dbPath,
            resultURL: resultURL,
            samtoolsPath: samtoolsPath,
            force: force,
            markDuplicates: markDuplicates
        ).bamURLs
    }

    /// Materializes BAM files and returns subprocess telemetry suitable for canonical provenance.
    public static func materializeAllWithProvenance(
        dbPath: String,
        resultURL: URL,
        samtoolsPath: String,
        force: Bool = false,
        markDuplicates: Bool = true,
        samtoolsVersion: String? = nil,
        lungfishVersion: String = "unknown"
    ) throws -> NaoMgsBamMaterializationResult {
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
        var steps: [NaoMgsBamMaterializationStep] = []
        let resolvedSamtoolsVersion = samtoolsVersion ?? detectSamtoolsVersion(samtoolsPath: samtoolsPath)
        let databaseURL = URL(fileURLWithPath: dbPath)
        for sample in samples {
            let bamURL = bamsDir.appendingPathComponent("\(sample).bam")

            if !force && fm.fileExists(atPath: bamURL.path) {
                // Already generated; callers may defer markdup to a shared pipeline.
                if markDuplicates {
                    if let step = markdupWithTelemetry(
                        sample: sample,
                        bamURL: bamURL,
                        samtoolsPath: samtoolsPath,
                        samtoolsVersion: resolvedSamtoolsVersion
                    ) {
                        steps.append(step)
                    }
                    if let indexStep = ensureIndex(
                        sample: sample,
                        bamURL: bamURL,
                        samtoolsPath: samtoolsPath,
                        samtoolsVersion: resolvedSamtoolsVersion
                    ) {
                        steps.append(indexStep)
                    }
                }
                generated.append(bamURL)
                continue
            }

            do {
                if let generateStep = try generateBam(
                    db: db,
                    sample: sample,
                    refLengths: allRefLengths,
                    bamURL: bamURL,
                    samtoolsPath: samtoolsPath,
                    samtoolsVersion: resolvedSamtoolsVersion,
                    lungfishVersion: lungfishVersion,
                    databaseURL: databaseURL,
                    createIndex: markDuplicates
                ) {
                    steps.append(generateStep)
                }
                if markDuplicates {
                    if let step = markdupWithTelemetry(
                        sample: sample,
                        bamURL: bamURL,
                        samtoolsPath: samtoolsPath,
                        samtoolsVersion: resolvedSamtoolsVersion
                    ) {
                        steps.append(step)
                    }
                }
                generated.append(bamURL)
                logger.info("Materialized NAO-MGS BAM for sample \(sample, privacy: .public)")
            } catch {
                logger.warning("Failed to materialize BAM for sample \(sample, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Clean up partial BAM so it doesn't block future attempts
                try? fm.removeItem(at: bamURL)
            }
        }

        return NaoMgsBamMaterializationResult(bamURLs: generated, steps: steps)
    }

    // MARK: - Private

    private static func fetchSamples(db: OpaquePointer?) throws -> [String] {
        var stmt: OpaquePointer?
        // Use taxon_summaries (small, pre-computed) instead of virus_hits (millions of rows).
        // Falls back to virus_hits if taxon_summaries is empty (legacy databases).
        let sql = "SELECT DISTINCT sample FROM taxon_summaries ORDER BY sample"
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

        // Fallback to virus_hits if taxon_summaries is empty
        if samples.isEmpty {
            var fallbackStmt: OpaquePointer?
            let fallbackSQL = "SELECT DISTINCT sample FROM virus_hits ORDER BY sample"
            if sqlite3_prepare_v2(db, fallbackSQL, -1, &fallbackStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(fallbackStmt) }
                while sqlite3_step(fallbackStmt) == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(fallbackStmt, 0) {
                        samples.append(String(cString: ptr))
                    }
                }
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

    private static func virusHitsHasPairedColumns(db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(virus_hits)", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: ptr))
            }
        }
        return names.contains("ref_start_rev")
            && names.contains("read_sequence_rev")
            && names.contains("read_quality_rev")
            && names.contains("query_length_rev")
            && names.contains("is_reverse_complement_rev")
    }

    private static func referenceSpan(start: Int, cigar: String, sequence: String, fallbackLength: Int) -> Int {
        let refLength = cigarReferenceLength(cigar)
        if refLength > 0 { return refLength }
        if fallbackLength > 0 { return fallbackLength }
        return max(1, sequence.count)
    }

    private static func cigarReferenceLength(_ cigar: String) -> Int {
        guard !cigar.isEmpty else { return 0 }
        var length = 0
        var current = 0
        for char in cigar {
            if let digit = char.wholeNumberValue {
                current = current * 10 + digit
                continue
            }
            switch char {
            case "M", "=", "X", "D", "N":
                length += current
            default:
                break
            }
            current = 0
        }
        return length
    }

    /// Returns true if a read sequence string represents valid data (not NULL, empty, or "NA").
    private static func isValidSequence(_ ptr: UnsafePointer<UInt8>?) -> Bool {
        guard let ptr = ptr else { return false }
        let str = String(cString: ptr)
        return !str.isEmpty && str != "NA"
    }

    /// Streams SAM records from the database directly into a samtools pipeline
    /// to produce a sorted, indexed BAM file. Never accumulates the full SAM
    /// text in memory -- O(1) memory for the alignment data.
    private static func generateBam(
        db: OpaquePointer?,
        sample: String,
        refLengths: [String: Int],
        bamURL: URL,
        samtoolsPath: String,
        samtoolsVersion: String,
        lungfishVersion: String,
        databaseURL: URL,
        createIndex: Bool
    ) throws -> NaoMgsBamMaterializationStep? {
        // 1. Collect accessions used by this sample to build @SQ header lines.
        //    Uses pre-computed accession_summaries (fast) instead of scanning virus_hits.
        var usedAccessions: Set<String> = []
        var accStmt: OpaquePointer?
        let accSQL = "SELECT DISTINCT accession FROM accession_summaries WHERE sample = ?"
        if sqlite3_prepare_v2(db, accSQL, -1, &accStmt, nil) == SQLITE_OK {
            _ = sample.withCString { cStr in
                sqlite3_bind_text(accStmt, 1, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            while sqlite3_step(accStmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(accStmt, 0) {
                    usedAccessions.insert(String(cString: ptr))
                }
            }
            sqlite3_finalize(accStmt)
        }

        // Fallback to virus_hits if accession_summaries is empty (legacy databases)
        if usedAccessions.isEmpty {
            var fallbackStmt: OpaquePointer?
            let fallbackSQL = "SELECT DISTINCT subject_seq_id FROM virus_hits WHERE sample = ?"
            guard sqlite3_prepare_v2(db, fallbackSQL, -1, &fallbackStmt, nil) == SQLITE_OK else {
                throw NSError(domain: "NaoMgsBamMaterializer", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Could not prepare accession query"])
            }
            _ = sample.withCString { cStr in
                sqlite3_bind_text(fallbackStmt, 1, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            while sqlite3_step(fallbackStmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(fallbackStmt, 0) {
                    usedAccessions.insert(String(cString: ptr))
                }
            }
            sqlite3_finalize(fallbackStmt)
        }

        guard !usedAccessions.isEmpty else {
            logger.warning("No virus_hits for sample \(sample, privacy: .public); skipping BAM generation")
            return nil
        }

        // 2. Build SAM header (small -- just @HD + @SQ lines)
        var header = "@HD\tVN:1.6\tSO:unsorted\n"
        for accession in usedAccessions.sorted() {
            let length = refLengths[accession] ?? 100000
            header += "@SQ\tSN:\(accession)\tLN:\(length)\n"
        }
        header += "@PG\tID:lungfish-naomgs-materializer\tPN:lungfish\tVN:1.0\n"
        let headerText = header

        // 3. Start samtools pipeline BEFORE reading rows -- stream directly into it
        let escapedSamtoolsPath = naoMgsShellEscape(samtoolsPath)
        let cmd = "\(escapedSamtoolsPath) view -bS - | \(escapedSamtoolsPath) sort -m 256M -o \(naoMgsShellEscape(bamURL.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        // Ignore SIGPIPE so broken pipe doesn't kill our process
        signal(SIGPIPE, SIG_IGN)

        let startedAt = Date()
        try process.run()

        // 4. Stream: write header, then iterate rows and write each SAM line.
        //    Uses POSIX write() on the raw file descriptor to avoid
        //    NSFileHandle's uncatchable ObjC exception on broken pipe.
        //    Runs on a background queue to avoid blocking the caller.
        let pipeFD = inPipe.fileHandleForWriting.fileDescriptor
        final class ErrorBox: @unchecked Sendable {
            var value: Error?
        }
        final class DatabaseBox: @unchecked Sendable {
            let value: OpaquePointer?

            init(_ value: OpaquePointer?) {
                self.value = value
            }
        }
        let writeError = ErrorBox()
        let database = DatabaseBox(db)
        let writeGroup = DispatchGroup()
        writeGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(pipeFD)
                writeGroup.leave()
            }

            /// Writes all bytes to the file descriptor, handling partial writes.
            /// Returns false on EPIPE (broken pipe) so the caller can stop.
            func writeAll(_ data: Data) -> Bool {
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return true }
                    var offset = 0
                    while offset < data.count {
                        let written = Darwin.write(pipeFD, baseAddress + offset, data.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }  // interrupted -- retry
                            return false  // EPIPE or other error -- stop
                        }
                        offset += written
                    }
                    return true
                }
            }

            if let headerData = headerText.data(using: .utf8) {
                guard writeAll(headerData) else {
                    writeError.value = NSError(domain: "NaoMgsBamMaterializer", code: 7,
                                               userInfo: [NSLocalizedDescriptionKey: "Broken pipe writing SAM header"])
                    return
                }
            }

            let db = database.value
            let hasPairedColumns = virusHitsHasPairedColumns(db: db)
            var rowStmt: OpaquePointer?
            let rowSQL: String
            if hasPairedColumns {
                rowSQL = """
                SELECT seq_id, subject_seq_id, ref_start, cigar, read_sequence, read_quality, is_reverse_complement,
                       ref_start_rev, read_sequence_rev, read_quality_rev, edit_distance_rev, query_length_rev,
                       is_reverse_complement_rev
                FROM virus_hits
                WHERE sample = ?
                """
            } else {
                rowSQL = """
                SELECT seq_id, subject_seq_id, ref_start, cigar, read_sequence, read_quality, is_reverse_complement
                FROM virus_hits
                WHERE sample = ?
                """
            }
            guard sqlite3_prepare_v2(db, rowSQL, -1, &rowStmt, nil) == SQLITE_OK else {
                writeError.value = NSError(domain: "NaoMgsBamMaterializer", code: 4,
                                           userInfo: [NSLocalizedDescriptionKey: "Could not prepare row query"])
                return
            }
            defer { sqlite3_finalize(rowStmt) }
            _ = sample.withCString { cStr in
                sqlite3_bind_text(rowStmt, 1, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }

            while sqlite3_step(rowStmt) == SQLITE_ROW {
                // seq_id and subject_seq_id are always present (never NULL)
                guard let seqIdPtr = sqlite3_column_text(rowStmt, 0),
                      let subjPtr = sqlite3_column_text(rowStmt, 1) else { continue }
                let qname = String(cString: seqIdPtr)
                let rname = String(cString: subjPtr)

                // Check R1 availability: ref_start not NULL AND read_sequence valid
                let hasR1: Bool = sqlite3_column_type(rowStmt, 2) != SQLITE_NULL
                    && isValidSequence(sqlite3_column_text(rowStmt, 4))

                // Check R2 availability: ref_start_rev not NULL AND read_sequence_rev valid
                let hasR2: Bool = hasPairedColumns
                    && sqlite3_column_type(rowStmt, 7) != SQLITE_NULL
                    && isValidSequence(sqlite3_column_text(rowStmt, 8))

                // Skip rows where neither R1 nor R2 has valid data
                if !hasR1 && !hasR2 { continue }

                // Extract R1 fields (only when hasR1)
                let refStart = hasR1 ? Int(sqlite3_column_int64(rowStmt, 2)) : 0
                let cigar: String = {
                    guard hasR1, let ptr = sqlite3_column_text(rowStmt, 3) else { return "" }
                    let s = String(cString: ptr)
                    return s.isEmpty ? "" : s
                }()
                let seq: String = {
                    guard hasR1, let ptr = sqlite3_column_text(rowStmt, 4) else { return "" }
                    return String(cString: ptr)
                }()
                let qual: String = {
                    guard hasR1, let ptr = sqlite3_column_text(rowStmt, 5) else { return "" }
                    return String(cString: ptr)
                }()
                let isReverse = hasR1 ? sqlite3_column_int(rowStmt, 6) != 0 : false

                // Validate R1 data: if flagged as present but CIGAR empty and seq invalid, downgrade
                let validR1 = hasR1 && !seq.isEmpty && seq != "NA" && !cigar.isEmpty

                // Extract R2 fields (only when hasR2)
                let refStartRev = hasR2 ? Int(sqlite3_column_int64(rowStmt, 7)) : 0
                let seqRev: String = {
                    guard hasR2, let ptr = sqlite3_column_text(rowStmt, 8) else { return "" }
                    return String(cString: ptr)
                }()
                let qualRev: String = {
                    guard hasR2, let ptr = sqlite3_column_text(rowStmt, 9) else { return "" }
                    return String(cString: ptr)
                }()
                let queryLengthRev = hasR2 ? Int(sqlite3_column_int(rowStmt, 11)) : 0
                let isReverseRev = hasR2 ? sqlite3_column_int(rowStmt, 12) != 0 : false
                let validR2 = hasR2 && !seqRev.isEmpty && seqRev != "NA" && !qualRev.isEmpty

                // Skip if neither mate produced valid data after extraction
                if !validR1 && !validR2 { continue }

                func writeSAMLine(_ line: String) -> Bool {
                    guard let lineData = line.data(using: .utf8) else { return true }
                    return writeAll(lineData)
                }

                if validR1 && validR2 {
                    // Case 1: Both R1 + R2 -- emit paired SAM records
                    let mate1Span = referenceSpan(start: refStart, cigar: cigar, sequence: seq, fallbackLength: seq.count)
                    let mate2Cigar = "\(max(1, queryLengthRev > 0 ? queryLengthRev : seqRev.count))M"
                    let mate2Span = referenceSpan(start: refStartRev, cigar: mate2Cigar, sequence: seqRev, fallbackLength: seqRev.count)
                    let leftmostStart = min(refStart, refStartRev)
                    let rightmostEnd = max(refStart + mate1Span, refStartRev + mate2Span)
                    let templateLength = max(1, rightmostEnd - leftmostStart)

                    let properPair = 0x2
                    let mateReverse1 = isReverseRev ? 0x20 : 0
                    let mateReverse2 = isReverse ? 0x20 : 0
                    let firstPos = refStart + 1
                    let secondPos = refStartRev + 1
                    let firstTLen = refStart <= refStartRev ? templateLength : -templateLength
                    let secondTLen = -firstTLen
                    let firstFlag = 0x1 | properPair | 0x40 | mateReverse1 | (isReverse ? 0x10 : 0)
                    let secondFlag = 0x1 | properPair | 0x80 | mateReverse2 | (isReverseRev ? 0x10 : 0)

                    let firstLine = "\(qname)\t\(firstFlag)\t\(rname)\t\(firstPos)\t60\t\(cigar)\t=\t\(secondPos)\t\(firstTLen)\t\(seq)\t\(qual)\n"
                    guard writeSAMLine(firstLine) else {
                        writeError.value = NSError(domain: "NaoMgsBamMaterializer", code: 7,
                                                   userInfo: [NSLocalizedDescriptionKey: "Broken pipe writing mate 1 SAM record for sample \(sample)"])
                        return
                    }

                    let secondLine = "\(qname)\t\(secondFlag)\t\(rname)\t\(secondPos)\t60\t\(mate2Cigar)\t=\t\(firstPos)\t\(secondTLen)\t\(seqRev)\t\(qualRev)\n"
                    guard writeSAMLine(secondLine) else {
                        writeError.value = NSError(domain: "NaoMgsBamMaterializer", code: 7,
                                                   userInfo: [NSLocalizedDescriptionKey: "Broken pipe writing mate 2 SAM record for sample \(sample)"])
                        return
                    }
                } else if validR1 {
                    // Case 2: R1 only -- emit single unpaired SAM record from R1
                    let flag = isReverse ? 16 : 0
                    let pos = refStart + 1
                    let line = "\(qname)\t\(flag)\t\(rname)\t\(pos)\t60\t\(cigar)\t*\t0\t0\t\(seq)\t\(qual)\n"
                    guard writeSAMLine(line) else {
                        writeError.value = NSError(domain: "NaoMgsBamMaterializer", code: 7,
                                                   userInfo: [NSLocalizedDescriptionKey: "Broken pipe writing SAM record for sample \(sample)"])
                        return
                    }
                } else {
                    // Case 3: R2 only -- emit single unpaired SAM record from R2
                    let flag = isReverseRev ? 16 : 0
                    let pos = refStartRev + 1
                    let r2Cigar = "\(max(1, queryLengthRev > 0 ? queryLengthRev : seqRev.count))M"
                    let line = "\(qname)\t\(flag)\t\(rname)\t\(pos)\t60\t\(r2Cigar)\t*\t0\t0\t\(seqRev)\t\(qualRev)\n"
                    guard writeSAMLine(line) else {
                        writeError.value = NSError(domain: "NaoMgsBamMaterializer", code: 7,
                                                   userInfo: [NSLocalizedDescriptionKey: "Broken pipe writing R2-only SAM record for sample \(sample)"])
                        return
                    }
                }
            }
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        writeGroup.wait()
        process.waitUntilExit()
        let completedAt = Date()
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        let step = NaoMgsBamMaterializationStep(
            sample: sample,
            toolName: "lungfish nao-mgs materialize-bam",
            toolVersion: lungfishVersion,
            argv: [
                "lungfish-internal",
                "nao-mgs-materialize-bam",
                "--database", databaseURL.path,
                "--sample", sample,
                "--output", bamURL.path,
                "--samtools", samtoolsPath,
            ],
            reproducibleCommand: "lungfish-cli import nao-mgs <source-virus-hits.tsv> --output-dir <output-dir>",
            inputURLs: [databaseURL],
            outputURLs: [bamURL],
            exitStatus: Int(process.terminationStatus),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderr.isEmpty ? nil : stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )

        if let err = writeError.value { throw err }

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "samtools pipeline failed: \(stderr)"])
        }

        // 5. Index the output BAM when this materializer owns the downstream markdup/index pass.
        if createIndex {
            _ = ensureIndex(
                sample: sample,
                bamURL: bamURL,
                samtoolsPath: samtoolsPath,
                samtoolsVersion: samtoolsVersion
            )
        }
        return step
    }

    /// Ensures a BAM index (.bai) exists, creating one if needed.
    /// Best-effort -- logs a warning on failure but does not throw.
    private static func ensureIndex(
        sample: String,
        bamURL: URL,
        samtoolsPath: String,
        samtoolsVersion: String
    ) -> NaoMgsBamMaterializationStep? {
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        if FileManager.default.fileExists(atPath: baiURL.path) { return nil }

        let indexProc = Process()
        indexProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        indexProc.arguments = ["index", bamURL.path]
        indexProc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        indexProc.standardError = errPipe
        let startedAt = Date()
        do {
            try indexProc.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            indexProc.waitUntilExit()
            let completedAt = Date()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let step = NaoMgsBamMaterializationStep(
                sample: sample,
                toolName: "samtools",
                toolVersion: samtoolsVersion,
                argv: [samtoolsPath, "index", bamURL.path],
                inputURLs: [bamURL],
                outputURLs: FileManager.default.fileExists(atPath: baiURL.path) ? [baiURL] : [],
                exitStatus: Int(indexProc.terminationStatus),
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: stderr.isEmpty ? nil : stderr,
                startedAt: startedAt,
                completedAt: completedAt
            )
            if indexProc.terminationStatus != 0 {
                logger.warning("samtools index failed for \(bamURL.lastPathComponent, privacy: .public)")
            }
            return step
        } catch {
            logger.warning("samtools index could not run for \(bamURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let completedAt = Date()
            return NaoMgsBamMaterializationStep(
                sample: sample,
                toolName: "samtools",
                toolVersion: samtoolsVersion,
                argv: [samtoolsPath, "index", bamURL.path],
                inputURLs: [bamURL],
                outputURLs: [],
                exitStatus: 1,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: error.localizedDescription,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }
    }

    private static func markdupWithTelemetry(
        sample: String,
        bamURL: URL,
        samtoolsPath: String,
        samtoolsVersion: String
    ) -> NaoMgsBamMaterializationStep? {
        let startedAt = Date()
        do {
            let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
            let completedAt = Date()
            let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
            var outputURLs = [bamURL]
            if FileManager.default.fileExists(atPath: baiURL.path) {
                outputURLs.append(baiURL)
            }
            if result.wasAlreadyMarkduped {
                return NaoMgsBamMaterializationStep(
                    sample: sample,
                    toolName: "samtools",
                    toolVersion: samtoolsVersion,
                    argv: [samtoolsPath, "view", "-H", bamURL.path],
                    reproducibleCommand: "\(naoMgsShellEscape(samtoolsPath)) view -H \(naoMgsShellEscape(bamURL.path))",
                    inputURLs: [bamURL],
                    outputURLs: outputURLs,
                    exitStatus: 0,
                    wallTimeSeconds: result.durationSeconds,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            }
            return NaoMgsBamMaterializationStep(
                sample: sample,
                toolName: "samtools",
                toolVersion: samtoolsVersion,
                argv: ["/bin/sh", "-c", markdupReplayCommand(bamURL: bamURL, samtoolsPath: samtoolsPath, threads: 4)],
                inputURLs: [bamURL],
                outputURLs: outputURLs,
                exitStatus: 0,
                wallTimeSeconds: result.durationSeconds,
                startedAt: startedAt,
                completedAt: completedAt
            )
        } catch {
            logger.warning("samtools markdup failed for \(bamURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let completedAt = Date()
            return NaoMgsBamMaterializationStep(
                sample: sample,
                toolName: "samtools",
                toolVersion: samtoolsVersion,
                argv: ["/bin/sh", "-c", markdupReplayCommand(bamURL: bamURL, samtoolsPath: samtoolsPath, threads: 4)],
                inputURLs: [bamURL],
                outputURLs: [],
                exitStatus: 1,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: error.localizedDescription,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }
    }

    private static func markdupReplayCommand(bamURL: URL, samtoolsPath: String, threads: Int) -> String {
        let tempBamPath = bamURL.path + ".markdup.tmp"
        let tempBaiPath = tempBamPath + ".bai"
        let baiPath = bamURL.path + ".bai"
        let csiPath = bamURL.path + ".csi"
        let escapedSamtoolsPath = naoMgsShellEscape(samtoolsPath)
        return [
            "\(escapedSamtoolsPath) sort -n -@ \(threads) \(naoMgsShellEscape(bamURL.path))",
            "\(escapedSamtoolsPath) fixmate -m - -",
            "\(escapedSamtoolsPath) sort -@ \(threads) -",
            "\(escapedSamtoolsPath) markdup - \(naoMgsShellEscape(tempBamPath))",
        ].joined(separator: " | ")
            + " && \(escapedSamtoolsPath) index \(naoMgsShellEscape(tempBamPath))"
            + " && rm -f \(naoMgsShellEscape(baiPath)) \(naoMgsShellEscape(csiPath))"
            + " && mv \(naoMgsShellEscape(tempBamPath)) \(naoMgsShellEscape(bamURL.path))"
            + " && mv \(naoMgsShellEscape(tempBaiPath)) \(naoMgsShellEscape(baiPath))"
    }

    private static func detectSamtoolsVersion(samtoolsPath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let firstLine = output.split(separator: "\n").first {
                return String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.warning("Could not detect samtools version: \(error.localizedDescription, privacy: .public)")
        }
        return "unknown"
    }
}

private func naoMgsShellEscape(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./:=@+,"))
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
