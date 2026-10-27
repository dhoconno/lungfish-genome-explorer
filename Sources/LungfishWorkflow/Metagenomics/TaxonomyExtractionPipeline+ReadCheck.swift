// TaxonomyExtractionPipeline+ReadCheck.swift - Whether a taxon's extracted reads are the ones kraken2 classified
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension TaxonomyExtractionPipeline {

    /// The read check of an extraction (BIO-READ-IDENTITY 4.1, Phase 3.0 lane READ-IDENTITY).
    ///
    /// Extract takes a result's reads by name from whatever file sits at the place the result names, and Import
    /// FASTQ's Replace can put other reads under the same names there. This reads every record of `outputs`, one per
    /// file of `files` as ``extractEachFile(config:files:tree:progress:)`` wrote them, and counts every read ID of
    /// `named`, kraken2's lengths by the ID the extraction matched, as found or missing and, when found, with the
    /// lengths kraken2 recorded or another. Found IDs are compared, never raw counts, so a merged or mixed derivative
    /// keeps its mate arithmetic (D7a).
    ///
    /// The output of an R1 file holds that pair of files read in step, each R1 record followed by its R2 record, so
    /// the two are mate 1 and mate 2 of the pair whose ID either names. Every other output holds a file's records as
    /// seqkit found them by `matching`, and a record's mate is the `/1` or `/2` its ID ends with, or the next one in
    /// the order the records come.
    static func checkReads(
        _ outputs: [URL?],
        of files: [KrakenResultReadSources.File],
        named: [String: [KrakenReadLength]],
        matching: ReadIDMatching
    ) throws -> KrakenReadCheck {
        var found: [String: [KrakenReadLength]] = [:]
        for (index, file) in files.enumerated() {
            guard index < outputs.count, let output = outputs[index] else { continue }
            let reader = try FASTQRawLineReader(url: output)
            defer { reader.close() }
            if file.role == .r1 {
                while let mate1 = try nextRecord(reader), let mate2 = try nextRecord(reader) {
                    let id1 = matching.readID(ofHeaderLine: mate1.header)
                    let id = named[id1] != nil ? id1 : matching.readID(ofHeaderLine: mate2.header)
                    found[id, default: []] += [
                        KrakenReadLength(mate: 1, length: mate1.length), KrakenReadLength(mate: 2, length: mate2.length),
                    ]
                }
            } else {
                while let record = try nextRecord(reader) {
                    let id = matching.readID(ofHeaderLine: record.header)
                    guard named[id] != nil else { continue }
                    found[id, default: []].append(KrakenReadLength(mate: mate(of: record.header, matching: matching), length: record.length))
                }
            }
        }
        var check = KrakenReadCheck()
        for (id, expected) in named {
            check.add(expected: expected, found: found[id] ?? [])
        }
        return check
    }

    /// The next FASTQ record of `reader`: its header line and the length of its sequence.
    private static func nextRecord(_ reader: FASTQRawLineReader) throws -> (header: String, length: Int)? {
        var header = try reader.nextLine()
        while let line = header, line.isEmpty { header = try reader.nextLine() }
        guard let header, let sequence = try reader.nextLine() else { return nil }
        _ = try reader.nextLine()
        _ = try reader.nextLine()
        let length = sequence.last == UInt8(ascii: "\r") ? sequence.count - 1 : sequence.count
        return (String(decoding: header, as: UTF8.self), length)
    }

    /// The mate a header names by a final `/1` or `/2` on its first word, which the fragment-name rule drops.
    private static func mate(of header: String, matching: ReadIDMatching) -> Int? {
        guard matching == .fragmentName else { return nil }
        let word = header.dropFirst().prefix { !" \t\r\u{0C}\n".contains($0) }
        guard word.count > 2 else { return nil }
        if word.hasSuffix("/1") { return 1 }
        if word.hasSuffix("/2") { return 2 }
        return nil
    }
}
