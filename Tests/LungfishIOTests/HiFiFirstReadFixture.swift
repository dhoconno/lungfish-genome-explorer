// HiFiFirstReadFixture.swift - A FASTQ whose first read holds only high scores (BIO-BIN-QIN 7.2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The file of BIO-BIN-QIN section 7.2. Record 1 has 63 bases whose quality bytes run 64 (`@`) to 126 (`~`), which is Q31
/// to Q93 in Phred+33, as a short HiFi amplicon with no low score can hold. Record 2 has 10 bases, all `I` (Q40). A
/// reader that guessed the encoding from record 1 would call the whole file Phred+64 and read record 1 as Q0 to Q62 and
/// record 2 as Q9, 31 too low.
enum HiFiFirstReadFixture {
    /// The quality bytes of record 1.
    static let firstQualities: [UInt8] = Array(64...126)

    /// The quality bytes of record 2.
    static let secondQualities: [UInt8] = Array(repeating: UInt8(ascii: "I"), count: 10)

    /// The two quality lines, which a reader or writer must carry byte for byte.
    static var qualityLines: [String] {
        [String(decoding: firstQualities, as: UTF8.self), String(decoding: secondQualities, as: UTF8.self)]
    }

    /// The file's text.
    static var text: String {
        let firstBases = String(String(repeating: "ACGT", count: 16).prefix(firstQualities.count))
        return [
            "@hifi1", firstBases, "+", qualityLines[0],
            "@hifi2", "ACGTACGTAC", "+", qualityLines[1],
        ].joined(separator: "\n") + "\n"
    }

    /// Writes the file into `folder` and returns its URL.
    static func write(in folder: URL, name: String = "hifi-first-read.fastq") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
