// ViewerFigurePDFNormalizer.swift - Takes the clock and the random file ID out of a figure PDF
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What `ViewerFigurePDFNormalizer` did to a PDF.
enum ViewerFigurePDFNormalization: Sendable, Hashable {
    /// Both dates blanked and the file ID taken from the content, with no byte moved.
    case normalized(Data)
    /// The bytes as the PDF context wrote them, with what was found in place of the layout the
    /// normalizer reads.
    case keptAsWritten(Data, reason: String)
}

/// Rewrites a PDF from the Quartz PDF context so its bytes repeat (QA ruling QA-GFX-mask, QM-2).
///
/// The context writes `/CreationDate` and `/ModDate` from the clock into the Info dictionary and
/// a random trailer `/ID`, and no API sets them (lane 13.28, M2 measure). The normalizer
/// overwrites both date entries with spaces and writes into both `/ID` strings the first 32 hex
/// digits of the SHA-256 of the bytes with the ID digits zeroed. Every byte keeps its offset, so
/// the cross-reference table stays valid. Any other layout keeps the bytes as written and says
/// what it found.
enum ViewerFigurePDFNormalizer {
    static let creationDatePattern = #"/CreationDate \(D:[0-9]{14}[^)]*\)"#
    static let modDatePattern = #"/ModDate \(D:[0-9]{14}[^)]*\)"#
    /// The trailer `/ID`, with each of its two strings captured.
    static let idPattern = #"/ID \[ <([0-9a-f]{32})>\s*<([0-9a-f]{32})> \]"#
    /// The three values the context writes from the clock and a random source, in that order.
    static let volatilePatterns = [creationDatePattern, modDatePattern, idPattern]

    /// The byte ranges each volatile pattern matches anywhere in `data`, one list per pattern.
    static func volatileRanges(_ data: Data) -> [[Range<Int>]] {
        let text = latin1(data)
        return volatilePatterns.map { pattern in
            matches(pattern, in: text).map { $0.range.location ..< NSMaxRange($0.range) }
        }
    }

    /// The PDF with both dates blanked and a file ID taken from its content, or the bytes as
    /// written when the layout is not the one the context writes.
    static func normalize(_ data: Data) -> ViewerFigurePDFNormalization {
        let text = latin1(data)
        let trailer = text.range(of: "trailer", options: .backwards)
        guard trailer.location != NSNotFound else {
            return .keptAsWritten(data, reason: "the PDF has no trailer keyword")
        }
        let trailerRange = NSRange(location: trailer.location, length: text.length - trailer.location)
        let infoReferences = matches(#"/Info ([0-9]+) 0 R"#, in: text, range: trailerRange)
        guard infoReferences.count == 1, let infoReference = infoReferences.first else {
            return .keptAsWritten(data, reason: "the last trailer has \(infoReferences.count) /Info references")
        }
        let ids = matches(idPattern, in: text)
        let idKeys = matches(#"/ID[\s\[]"#, in: text)
        guard ids.count <= 1, idKeys.count == ids.count else {
            return .keptAsWritten(data, reason: "the PDF has \(idKeys.count) /ID entries, \(ids.count) of them as expected")
        }
        if let id = ids.first, id.range.location < trailer.location {
            return .keptAsWritten(data, reason: "the /ID is outside the last trailer")
        }

        let infoNumber = text.substring(with: infoReference.range(at: 1))
        let headers = matches(#"(?<![0-9])\#(infoNumber) 0 obj"#, in: text)
        guard headers.count == 1, let header = headers.first else {
            return .keptAsWritten(data, reason: "the PDF has \(headers.count) objects numbered \(infoNumber), the Info object")
        }
        let afterHeader = NSRange(location: header.range.location, length: text.length - header.range.location)
        let end = text.range(of: "endobj", range: afterHeader)
        guard end.location != NSNotFound else {
            return .keptAsWritten(data, reason: "the Info object \(infoNumber) has no endobj")
        }
        let infoObject = NSRange(location: header.range.location, length: NSMaxRange(end) - header.range.location)

        var blanks: [NSRange] = []
        for (key, pattern) in [("/CreationDate", creationDatePattern), ("/ModDate", modDatePattern)] {
            let dates = matches(pattern, in: text)
            let keys = matches(NSRegularExpression.escapedPattern(for: key) + #"[\s(]"#, in: text)
            guard dates.count <= 1, keys.count == dates.count else {
                return .keptAsWritten(data, reason: "the PDF has \(keys.count) \(key) entries, \(dates.count) of them as expected")
            }
            if let date = dates.first {
                guard NSIntersectionRange(date.range, infoObject).length == date.range.length else {
                    return .keptAsWritten(data, reason: "\(key) is outside the Info object \(infoNumber)")
                }
                blanks.append(date.range)
            }
        }

        var bytes = [UInt8](data)
        for range in blanks {
            for index in range.location ..< NSMaxRange(range) {
                bytes[index] = UInt8(ascii: " ")
            }
        }
        if let id = ids.first {
            let strings = [id.range(at: 1), id.range(at: 2)]
            for string in strings {
                for index in string.location ..< NSMaxRange(string) {
                    bytes[index] = UInt8(ascii: "0")
                }
            }
            let digits = Array(FileDigest.sha256Hex(of: Data(bytes)).utf8.prefix(32))
            for string in strings {
                for (offset, digit) in digits.enumerated() {
                    bytes[string.location + offset] = digit
                }
            }
        }
        return .normalized(Data(bytes))
    }

    /// The bytes as Latin-1, which maps each byte to one UTF-16 unit, so string offsets are byte
    /// offsets.
    private static func latin1(_ data: Data) -> NSString {
        (String(data: data, encoding: .isoLatin1) ?? "") as NSString
    }

    private static func matches(_ pattern: String, in text: NSString, range: NSRange? = nil) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return expression.matches(in: text as String, range: range ?? NSRange(location: 0, length: text.length))
    }
}
