// ViewerGraphicRegionsFile.swift - The BED file of the bulk form of bundle export-graphic
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The regions of `bundle export-graphic --regions-file`, read as BED (BIO ruling Q-G3, item 4, ARCH ruling B10 3.2).
///
/// Lines are tab-separated with a 0-based start and an exclusive end. Blank lines and lines whose first word is
/// `track` or `browser` or that start with `#` are skipped. Column 4 is the name when present, and further columns
/// are ignored. The bundle checks each contig and end when the leaf resolves the line.
public enum ViewerGraphicRegionsFile {
    /// One region line as the file states it.
    public struct Line: Sendable, Equatable {
        /// The line's number in the file, counting from 1.
        public let number: Int
        public let contig: String
        /// The 0-based start.
        public let start: Int
        /// The exclusive end.
        public let end: Int
        /// Column 4, when present and not empty.
        public let name: String?

        public init(number: Int, contig: String, start: Int, end: Int, name: String?) {
            self.number = number
            self.contig = contig
            self.start = start
            self.end = end
            self.name = name
        }

        /// The figure's file name, the line's name or `<contig>_<start>_<end>` from its own numbers, through the
        /// one file name sanitizer, with the format's extension.
        public func fileName(format: ViewerFigureFormat) -> String {
            var stem = ExtractionBundleNaming.sanitizeFilename(name ?? "\(contig)_\(start)_\(end)")
            while stem.hasPrefix(".") {
                stem.removeFirst()
            }
            if stem.isEmpty {
                stem = ExtractionBundleNaming.sanitizeFilename("\(contig)_\(start)_\(end)")
            }
            return "\(stem).\(format.fileExtension)"
        }
    }

    /// The region lines of the BED file at `url`, or a refusal that names the first line it cannot read.
    public static func lines(of url: URL) throws -> [Line] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ViewerGraphicRefusal("The regions file \(url.path) cannot be read. \(error.localizedDescription)")
        }
        return try lines(text: text, fileName: url.lastPathComponent)
    }

    static func lines(text: String, fileName: String) throws -> [Line] {
        var lines: [Line] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let firstWord = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || firstWord == "track" || firstWord == "browser" {
                continue
            }
            let number = index + 1
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3 else {
                throw ViewerGraphicRefusal(
                    "Line \(number) of \(fileName) has \(columns.count) of the 3 columns a BED line needs. "
                        + "Give the contig, the start and the end, separated by tabs."
                )
            }
            guard let start = Int(columns[1]), let end = Int(columns[2]) else {
                throw ViewerGraphicRefusal(
                    "Line \(number) of \(fileName) has a start or an end that is not a whole number. "
                        + "Give both as whole numbers, such as chr1, 999 and 2000."
                )
            }
            guard start >= 0 else {
                throw ViewerGraphicRefusal("Line \(number) of \(fileName) starts at \(start). A BED start is 0 or more.")
            }
            guard end > start else {
                throw ViewerGraphicRefusal(
                    "Line \(number) of \(fileName) ends at \(end), which is not past its start at \(start). "
                        + "A BED end is past the start, since BED leaves the end out."
                )
            }
            let name = columns.count > 3 && !columns[3].isEmpty ? columns[3] : nil
            lines.append(Line(number: number, contig: columns[0], start: start, end: end, name: name))
        }
        guard !lines.isEmpty else {
            throw ViewerGraphicRefusal(
                "The regions file \(fileName) has no region lines. Give one line for each region, as the contig, "
                    + "the start and the end separated by tabs."
            )
        }
        return lines
    }
}
