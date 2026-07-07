// SRARunInfoCSVParser.swift - Shared parser for NCBI SRA runinfo CSV
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum SRARunInfoCSVParser {
    static func parseRunAccessions(_ csv: String) -> [String] {
        let runPattern = /^[SED]RR\d+$/
        let lines = csv.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }

        return lines.dropFirst().compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let run = fields(in: trimmed).first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !run.isEmpty, run.wholeMatch(of: runPattern) != nil else { return nil }
            return run
        }
    }

    static func parseRows(_ csv: String) -> [SRARunInfo] {
        let lines = csv.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        let firstLine = lines[0]
        let hasHeader = firstLine.hasPrefix("Run,")
        let dataLines = hasHeader ? Array(lines.dropFirst()) : lines

        return dataLines.compactMap { line -> SRARunInfo? in
            guard !line.isEmpty else { return nil }
            let fields = fields(in: line)
            guard let accession = field(fields, 0), !accession.isEmpty else { return nil }

            return SRARunInfo(
                accession: accession,
                experiment: field(fields, 10),
                sample: field(fields, 24),
                study: field(fields, 20),
                bioproject: field(fields, 21),
                biosample: field(fields, 25),
                organism: field(fields, 28),
                platform: field(fields, 18),
                libraryStrategy: field(fields, 12),
                librarySource: field(fields, 14),
                libraryLayout: field(fields, 15),
                spots: Int(field(fields, 3) ?? ""),
                bases: Int(field(fields, 4) ?? ""),
                avgLength: Int(field(fields, 6) ?? ""),
                size: Int(field(fields, 7) ?? ""),
                releaseDate: parseDate(field(fields, 1))
            )
        }
    }

    private static func fields(in line: String) -> [String] {
        DelimitedLineParser.fields(in: line, delimiter: ",")
    }

    private static func field(_ fields: [String], _ index: Int) -> String? {
        guard index >= 0, index < fields.count else { return nil }
        return fields[index]
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        for formatter in makeDateFormatters() {
            if let date = formatter.date(from: rawValue) {
                return date
            }
        }
        return nil
    }

    private static func makeDateFormatters() -> [DateFormatter] {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }
}
