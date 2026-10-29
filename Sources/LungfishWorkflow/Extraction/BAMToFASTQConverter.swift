// BAMToFASTQConverter.swift — Shared BAM→FASTQ conversion helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(
    subsystem: "com.lungfish.workflow",
    category: "BAMToFASTQConverter"
)

/// The READ1 (0x40) and READ2 (0x80) bits of a SAM FLAG. A record with either bit set goes through `samtools fastq`.
/// A record with neither is written by ``UnflaggedRecordFASTQWriter``.
private let mateFlagBits = 0xC0

// MARK: - Error

/// A reason the shared BAM→FASTQ converter failed. Callers map this to their
/// own error domain (`ExtractionError`, `ClassifierExtractionError`, …).
public enum BAMToFASTQConversionError: Error {
    /// A samtools invocation exited non-zero, or `samtools view` wrote a record the converter cannot read. The captured
    /// stderr, or a sentence that names the fault, is attached.
    case samtoolsFailed(stderr: String)
    /// No record was written and the caller disallowed an empty result.
    case emptySidecarOutputs
}

// MARK: - convertBAMToSingleFASTQ

/// Converts a BAM file into a single FASTQ with one record for each alignment record the flag mask keeps, collecting
/// every read class (READ1, READ2, READ_OTHER, singletons).
///
/// `samtools fastq` is "attempting to reverse the alignment process" one read name at a time. It writes one sequence
/// for each class (READ1, READ2, neither) of a run of consecutive records of one name. Two records of one name with
/// neither flag, the two mates of an SRA-named read that were mapped as single reads, come out as one record, and the
/// other mate is lost with no word (reviews/IDPINS.md R1, one to three mates of a selection). `samtools fastq -o`
/// alone also drops READ_OTHER singletons and `-0` alone drops READ1/READ2, which both caused silent loss before. So
/// the converter splits the records by flag:
///
/// - Records with READ1 or READ2 set (`samtools view --rf 0xC0`) go through `samtools fastq` with the four sidecars
///   (`-0/-1/-2/-s`), as they always did, so every output that was right stays byte for byte.
/// - Records with neither flag (`samtools view -F <mask | 0xC0>`) are written as SAM text by
///   ``UnflaggedRecordFASTQWriter``, one FASTQ record for each SAM record, strand restored and with no `/1` or `/2`.
///   No record is dropped for sharing a name, a sequence or a quality with another, and a record with no sequence is
///   left out.
///
/// The output holds the unflagged records first, in the BAM's order, then the sidecars in the order of the historical
/// implementation (READ_OTHER, singletons, READ1, READ2).
///
/// - Parameters:
///   - inputBAM: BAM file to read from. Must already be filtered/sorted as the
///               caller requires, beyond the `flagFilter` mask applied here.
///   - outputFASTQ: Destination FASTQ path. Overwritten if it exists.
///   - tempDir: Temp directory in which to place the sidecar files, the BAM of the flagged records and the SAM text of
///              the unflagged ones (the last two are removed before the call returns). Must be writable. Caller owns
///              cleanup of `tempDir`.
///   - sidecarPrefix: Stem used for the filenames in `tempDir`
///                    (`<prefix>_other.fastq`, `<prefix>_r1.fastq`,
///                    `<prefix>_r2.fastq`, `<prefix>_singletons.fastq`, `<prefix>_paired.bam`,
///                    `<prefix>_unflagged.sam`).
///                    Must be unique per concurrent call within a shared `tempDir`.
///   - flagFilter: Value to pass to `samtools view -F` and `samtools fastq -F`. `samtools fastq`'s
///                 built-in default is `0x900` (exclude secondary +
///                 supplementary); pass `0x900` to preserve that behavior, or
///                 a caller-specific mask (e.g. `0xD04`) to align the FASTQ
///                 output with a matching `samtools view -c -F <flags>` count.
///                 User-supplied `-F` REPLACES the default — it does not OR
///                 with `0x900`.
///   - timeout: Timeout for each `samtools` invocation, in seconds.
///   - toolRunner: Actor used to run the samtools subprocess. The caller must
///                 already have a reference to the shared runner.
///   - allowStdoutFallback: What an empty result means. `true` leaves an empty output file and returns. `false`
///                 throws ``BAMToFASTQConversionError/emptySidecarOutputs``. The name stays so the callers do not
///                 move. The retry through `samtools fastq` on stdout that it once switched on is gone, since the
///                 unflagged records it was meant to rescue are written by the converter itself and a retry over the
///                 same records can only write fewer.
/// - Throws: ``BAMToFASTQConversionError/samtoolsFailed(stderr:)`` if a samtools invocation
///           exits non-zero or writes a record that cannot be read, plus any `FileHandle` /
///           `FileManager` errors from the merge step.
///
/// This helper is shared by ``ReadExtractionService/convertBAMToFASTQSingleFile``,
/// ``ClassifierReadResolver`` and the Medaka FASTQ reconstruction of ``ViralVariantCallingPipeline``. Do not
/// duplicate the flag split elsewhere.
public func convertBAMToSingleFASTQ(
    inputBAM: URL,
    outputFASTQ: URL,
    tempDir: URL,
    sidecarPrefix: String,
    flagFilter: Int,
    timeout: TimeInterval,
    toolRunner: NativeToolRunner,
    allowStdoutFallback: Bool = true
) async throws {
    let fm = FileManager.default

    let pairedURL = tempDir.appendingPathComponent("\(sidecarPrefix)_paired.bam")
    let unflaggedURL = tempDir.appendingPathComponent("\(sidecarPrefix)_unflagged.sam")
    let otherURL = tempDir.appendingPathComponent("\(sidecarPrefix)_other.fastq")
    let r1URL = tempDir.appendingPathComponent("\(sidecarPrefix)_r1.fastq")
    let r2URL = tempDir.appendingPathComponent("\(sidecarPrefix)_r2.fastq")
    let singletonURL = tempDir.appendingPathComponent("\(sidecarPrefix)_singletons.fastq")
    defer {
        try? fm.removeItem(at: pairedURL)
        try? fm.removeItem(at: unflaggedURL)
    }

    // Records with READ1 or READ2 set go through `samtools fastq` as before.
    let pairedResult = try await toolRunner.run(
        .samtools,
        arguments: [
            "view", "-b", "-F", String(flagFilter), "--rf", String(mateFlagBits),
            "-o", pairedURL.path, inputBAM.path,
        ],
        timeout: timeout
    )
    guard pairedResult.isSuccess else {
        throw BAMToFASTQConversionError.samtoolsFailed(stderr: pairedResult.stderr)
    }
    let fastqResult = try await toolRunner.run(
        .samtools,
        arguments: [
            "fastq",
            "-F", String(flagFilter),
            "-0", otherURL.path,
            "-1", r1URL.path,
            "-2", r2URL.path,
            "-s", singletonURL.path,
            pairedURL.path,
        ],
        timeout: timeout
    )
    guard fastqResult.isSuccess else {
        throw BAMToFASTQConversionError.samtoolsFailed(stderr: fastqResult.stderr)
    }

    // Records with neither flag come out as SAM text, one FASTQ record for each.
    let unflaggedResult = try await toolRunner.run(
        .samtools,
        arguments: [
            "view", "-O", "SAM", "-F", String(flagFilter | mateFlagBits),
            "-o", unflaggedURL.path, inputBAM.path,
        ],
        timeout: timeout
    )
    guard unflaggedResult.isSuccess else {
        throw BAMToFASTQConversionError.samtoolsFailed(stderr: unflaggedResult.stderr)
    }

    if fm.fileExists(atPath: outputFASTQ.path) {
        try fm.removeItem(at: outputFASTQ)
    }
    fm.createFile(atPath: outputFASTQ.path, contents: nil)

    let outHandle = try FileHandle(forWritingTo: outputFASTQ)
    defer { try? outHandle.close() }

    try UnflaggedRecordFASTQWriter.writeRecords(fromSAMText: unflaggedURL, to: outHandle)

    // Order matches the historical ReadExtractionService implementation:
    // singletons + READ_OTHER first, then the paired R1/R2 stream. The unflagged records
    // were READ_OTHER records before, so they stand where READ_OTHER stood.
    let orderedParts = [otherURL, singletonURL, r1URL, r2URL]
    for partURL in orderedParts {
        guard fm.fileExists(atPath: partURL.path) else { continue }
        let attrs = try fm.attributesOfItem(atPath: partURL.path)
        let size = attrs[.size] as? UInt64 ?? 0
        guard size > 0 else { continue }

        let inHandle = try FileHandle(forReadingFrom: partURL)
        defer { try? inHandle.close() }

        while true {
            let chunk = inHandle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            outHandle.write(chunk)
        }
    }

    let mergedSize = (try? fm.attributesOfItem(atPath: outputFASTQ.path)[.size] as? UInt64) ?? 0
    if mergedSize == 0 {
        logger.warning("no alignment record of \(inputBAM.lastPathComponent, privacy: .public) passed the flag mask, so no FASTQ record was written")
        if !allowStdoutFallback {
            throw BAMToFASTQConversionError.emptySidecarOutputs
        }
    }
}

// MARK: - Records with neither mate flag

/// Writes one FASTQ record for each line of a headerless SAM text file whose records carry neither READ1 nor READ2.
///
/// `samtools fastq` writes one record for consecutive records of one name in the same class, so it cannot be the
/// writer of these records (reviews/IDPINS.md R1). This writer does what the tool does for a record it handles
/// right: `@<name>`, the sequence, `+`, the qualities, with no `/1` or `/2` and no tags. A record the reverse strand
/// holds (0x10) is written as the read, the sequence reverse-complemented (IUPAC letters included) and the
/// qualities reversed. A record with no sequence (`*`) is left out, since an empty FASTQ record breaks the tools that
/// read it. A record with no qualities (`*`) gets `B` for each base, the quality `samtools fastq` 1.24 gives it.
///
/// No record is dropped for sharing a name, a sequence or a quality with another one, since two real mates can
/// restore to the same sequence and the same qualities (the estimate `samtools view -c` counts both).
enum UnflaggedRecordFASTQWriter {
    /// The quality of each base of a record that has none, as `samtools fastq` 1.24 writes it.
    static let missingQuality = UInt8(ascii: "B")

    private static let chunkSize = 1 << 20
    private static let flushThreshold = 1 << 20
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let star = UInt8(ascii: "*")
    private static let reverseStrandFlag = 0x10

    /// The complement of each byte. The IUPAC letters pair as in `samtools`' own table (R and Y, K and M, B and V, D
    /// and H) and A, C, G and T in both cases. S, W, N, `=` and every other byte map to themselves.
    private static let complement: [UInt8] = {
        var table = (0...255).map { UInt8($0) }
        let from = Array("ACGTRYKMBVDHacgtrykmbvdh".utf8)
        let to = Array("TGCAYRMKVBHDtgcayrmkvbhd".utf8)
        for (base, mate) in zip(from, to) { table[Int(base)] = mate }
        return table
    }()

    /// Reads the SAM text at `source` a megabyte at a time and writes its FASTQ records to `output`.
    /// - Returns: The number of FASTQ records written.
    @discardableResult
    static func writeRecords(fromSAMText source: URL, to output: FileHandle) throws -> Int {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        var carry: [UInt8] = []
        var buffer: [UInt8] = []
        buffer.reserveCapacity(flushThreshold + (1 << 16))
        var written = 0

        func consume(_ line: ArraySlice<UInt8>) throws {
            if try appendRecord(of: line, to: &buffer) { written += 1 }
            if buffer.count >= flushThreshold {
                try output.write(contentsOf: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            var bytes = carry
            bytes.append(contentsOf: chunk)
            var start = 0
            while let end = bytes[start...].firstIndex(of: newline) {
                try consume(bytes[start..<end])
                start = end + 1
            }
            carry = Array(bytes[start...])
        }
        if !carry.isEmpty { try consume(carry[...]) }
        if !buffer.isEmpty { try output.write(contentsOf: Data(buffer)) }
        return written
    }

    /// Appends the FASTQ record of one SAM line to `buffer`. Returns false for a blank line or a record with no sequence.
    private static func appendRecord(of line: ArraySlice<UInt8>, to buffer: inout [UInt8]) throws -> Bool {
        if line.isEmpty { return false }
        let fields = line.split(separator: tab, maxSplits: 11, omittingEmptySubsequences: false)
        guard fields.count >= 11 else {
            throw BAMToFASTQConversionError.samtoolsFailed(
                stderr: "samtools view wrote a line of \(fields.count) tab-separated fields, and a SAM record has at least 11."
            )
        }
        let name = fields[0]
        let readName = String(decoding: name, as: UTF8.self)
        guard let flag = Int(String(decoding: fields[1], as: UTF8.self)) else {
            throw BAMToFASTQConversionError.samtoolsFailed(
                stderr: "samtools view wrote the record \(readName) with a FLAG that is not a number."
            )
        }
        let sequence = fields[9]
        let quality = fields[10]
        if sequence.count == 1, sequence.first == star { return false }
        let missingQualities = quality.count == 1 && quality.first == star
        guard missingQualities || quality.count == sequence.count else {
            throw BAMToFASTQConversionError.samtoolsFailed(
                stderr: "samtools view wrote the record \(readName) with \(sequence.count) bases and \(quality.count) quality values."
            )
        }

        let reverse = flag & reverseStrandFlag != 0
        buffer.append(UInt8(ascii: "@"))
        buffer.append(contentsOf: name)
        buffer.append(newline)
        if reverse {
            for base in sequence.reversed() { buffer.append(complement[Int(base)]) }
        } else {
            buffer.append(contentsOf: sequence)
        }
        buffer.append(newline)
        buffer.append(UInt8(ascii: "+"))
        buffer.append(newline)
        if missingQualities {
            buffer.append(contentsOf: repeatElement(missingQuality, count: sequence.count))
        } else if reverse {
            buffer.append(contentsOf: quality.reversed())
        } else {
            buffer.append(contentsOf: quality)
        }
        buffer.append(newline)
        return true
    }
}
