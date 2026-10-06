// TaxonomyExtractionPipeline+MatePairs.swift - A taxon's pairs from R1 and R2 files read in step, as kraken2 read them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension TaxonomyExtractionPipeline {

    /// One output per file of `sources`, in order. A pair of files that
    /// starts at an index of `matePairStarts` is read in step
    /// (``extractMatePairInStep(r1:r2:readIDs:to:)``), and its output takes
    /// the R1 file's place with nil in the R2 file's place. Every other file
    /// is read by `extractOne`, seqkit grep, and a file that holds none of
    /// the reads gives nil. Throws when no file holds any.
    func extractWithMatePairs(
        _ readIDs: Set<String>,
        from sources: [URL],
        matePairStarts: Set<Int>,
        outputDirectory: URL,
        baseName: String,
        extractOne: (_ source: URL, _ name: String, _ index: Int) async throws -> ExtractionResult
    ) async throws -> (urls: [URL?], readCount: Int) {
        var urls = [URL?](repeating: nil, count: sources.count)
        var readCount = 0
        var index = 0
        while index < sources.count {
            try Task.checkCancellation()
            let name = "\(baseName)_R\(index + 1)"
            if matePairStarts.contains(index), index + 1 < sources.count {
                let pairsURL = outputDirectory.appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(name)).pairs.fastq")
                let pairs = try Self.extractMatePairInStep(
                    r1: sources[index], r2: sources[index + 1], readIDs: readIDs, to: pairsURL
                )
                if pairs > 0 {
                    urls[index] = pairsURL
                    readCount += 2 * pairs
                } else {
                    try? FileManager.default.removeItem(at: pairsURL)
                }
                index += 2
                continue
            }
            do {
                let result = try await extractOne(sources[index], name, index)
                urls[index] = result.fastqURLs.first
                readCount += result.readCount
            } catch ExtractionError.emptyExtraction {
                // seqkit leaves an empty output behind.
                let empty = outputDirectory.appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(name)).fastq.gz")
                try? FileManager.default.removeItem(at: empty)
            }
            index += 1
        }
        guard readCount > 0 else { throw ExtractionError.emptyExtraction }
        return (urls, readCount)
    }

    /// Writes the pairs of the R1 file `r1` and the R2 file `r2` that hold a
    /// read of the taxon to `output`, each R1 record followed by its R2
    /// record, and returns the number of pairs.
    ///
    /// kraken2 `--paired` reads R1 and R2 by position and names a pair by its
    /// R1 read, so the two files are read in step here too. A pair is taken
    /// when the ID of either record under the fragment-name rule
    /// (``ReadIDMatching/readID(ofHeaderLine:)``) is one of `readIDs`. Its R2
    /// record is the record at the same position, never one found by name,
    /// so mates named `x.1` and `x.2` are found although kraken2 named the
    /// pair `x.1`. The two records of a taken pair must be mates
    /// (``areMatesForExtraction(_:_:)``), and files that hold different
    /// numbers of records throw, so files out of step never pair the wrong
    /// reads. Records are copied unchanged except the `+` line, written bare
    /// as `seqkit grep` writes it.
    static func extractMatePairInStep(
        r1: URL,
        r2: URL,
        readIDs: Set<String>,
        to output: URL
    ) throws -> Int {
        let reader1 = try FASTQRawLineReader(url: r1)
        defer { reader1.close() }
        let reader2 = try FASTQRawLineReader(url: r2)
        defer { reader2.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var buffer: [UInt8] = []
        var position = 0
        var pairs = 0
        while true {
            if position & 0x3FFF == 0 { try Task.checkCancellation() }
            let record1 = try readRecord(from: reader1, file: r1.lastPathComponent, recordNumber: position + 1)
            let record2 = try readRecord(from: reader2, file: r2.lastPathComponent, recordNumber: position + 1)
            guard let record1, let record2 else {
                guard record1 == nil, record2 == nil else {
                    throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                        r1File: r1.lastPathComponent,
                        r1Records: try FASTQPairInterleaver.countRecords(in: r1),
                        r2File: r2.lastPathComponent,
                        r2Records: try FASTQPairInterleaver.countRecords(in: r2)
                    )
                }
                break
            }
            position += 1
            let header1 = String(decoding: record1[0], as: UTF8.self)
            let header2 = String(decoding: record2[0], as: UTF8.self)
            guard readIDs.contains(ReadIDMatching.fragmentName.readID(ofHeaderLine: header1))
                || readIDs.contains(ReadIDMatching.fragmentName.readID(ofHeaderLine: header2)) else { continue }
            let name1 = String(header1.drop { $0 == "@" })
            let name2 = String(header2.drop { $0 == "@" })
            guard areMatesForExtraction(name1, name2) else {
                throw FASTQPairInterleaver.InterleaveError.mateNameMismatch(
                    recordNumber: position,
                    r1File: r1.lastPathComponent, r1Name: name1,
                    r2File: r2.lastPathComponent, r2Name: name2
                )
            }
            append(record1, to: &buffer)
            append(record2, to: &buffer)
            pairs += 1
            if buffer.count >= 4 * 1_048_576 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        return pairs
    }

    /// Whether the R1 record named `name1` and the R2 record named `name2`
    /// at one position of a pair of files are mates. Identical IDs, `/1` and
    /// `/2`, Casava comments, and the `.1` `.2` and `_1` `_2` read ID suffixes
    /// that ``FASTQPairInterleaver/recordedMates(_:_:)`` reads all pass. Names
    /// that carry no mate number and differ do not, since nothing then says
    /// the records belong together.
    static func areMatesForExtraction(_ name1: String, _ name2: String) -> Bool {
        FASTQPairInterleaver.recordedMates(name1, name2) == .mates
    }

    /// The four lines of the next record, or nil at the end of the file.
    private static func readRecord(
        from reader: FASTQRawLineReader,
        file: String,
        recordNumber: Int
    ) throws -> [[UInt8]]? {
        guard let header = try reader.nextLine() else { return nil }
        guard header.first == UInt8(ascii: "@") else {
            throw FASTQPairInterleaver.InterleaveError.malformedRecord(
                file: file, recordNumber: recordNumber, reason: "header line does not start with '@'"
            )
        }
        var lines = [header]
        for _ in 0..<3 {
            guard let line = try reader.nextLine() else {
                throw FASTQPairInterleaver.InterleaveError.malformedRecord(
                    file: file, recordNumber: recordNumber, reason: "file ends inside the record"
                )
            }
            lines.append(line)
        }
        return lines
    }

    private static func append(_ record: [[UInt8]], to buffer: inout [UInt8]) {
        buffer.append(contentsOf: record[0])
        buffer.append(UInt8(ascii: "\n"))
        buffer.append(contentsOf: record[1])
        buffer.append(contentsOf: [UInt8(ascii: "\n"), UInt8(ascii: "+"), UInt8(ascii: "\n")])
        buffer.append(contentsOf: record[3])
        buffer.append(UInt8(ascii: "\n"))
    }
}
