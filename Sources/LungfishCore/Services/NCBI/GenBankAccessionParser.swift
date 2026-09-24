import Foundation

/// Imports nucleotide accessions, retaining versions and first-occurrence order.
/// Unlike a free-text search, an accession import must not silently discard bad rows.
public enum GenBankAccessionParser {
    public enum ImportError: LocalizedError, Equatable, Sendable {
        case empty
        case invalidAccession(value: String, line: Int)
        case malformedCSV(line: Int)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "No nucleotide accessions were found. Supply GenBank or RefSeq nucleotide accessions, such as NM_000059.4 or NM_000546.6."
            case let .invalidAccession(value, line):
                let displayed = value.isEmpty ? "(empty)" : String(value.prefix(100))
                return "Invalid nucleotide accession ‘\(displayed)’ on line \(line). Use GenBank or RefSeq nucleotide accessions; assembly, protein, and SRA accessions are not supported. For a table, include an accession column header."
            case let .malformedCSV(line):
                return "Malformed CSV/TSV quoting on line \(line). Close quoted fields and separate them with a comma or tab."
            }
        }
    }

    // INSDC nucleotide formats: https://www.ncbi.nlm.nih.gov/genbank/acc_prefix/
    // NZ_ wraps an INSDC accession; other nucleotide RefSeq prefixes use numeric IDs.
    private static let insdc = "(?:[A-Z][0-9]{5}|[A-Z]{2}(?:[0-9]{6}|[0-9]{8})|(?!SAM[NDE])[A-Z]{4}[0-9]{8,}|[A-Z]{6}[0-9]{9,})"

    public static func isNucleotideAccession(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pattern = "^(?:\(insdc)|NZ_\(insdc)|(?:AC|NC|NG|NM|NR|NT|NW|XM|XR)_(?:[0-9]{6}|[0-9]{9}|[0-9]{12}))(?:\\.[1-9][0-9]*)?$"
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    /// Accepts comma, tab, newline, and whitespace-separated accession lists.
    public static func parseAccessionList(_ input: String) throws -> [String] {
        try parseCSV(input)
    }

    /// Reads UTF-8 CSV, TSV, or plain text. Recognized column headers select only
    /// that column, so titles and other metadata cannot introduce extra accessions.
    public static func parseCSV(_ input: String) throws -> [String] {
        let rows = try readRows(input)
        guard let first = rows.first else { throw ImportError.empty }
        let headers = first.fields.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        let versionHeaders: Set<String> = ["accessionversion", "accver", "accessionwithversion"]
        let accessionHeaders: Set<String> = ["acc", "accession", "accessions", "accessionnumber", "genbankaccession", "nucleotideaccession"]
        let column = headers.firstIndex(where: { versionHeaders.contains($0) })
            ?? headers.firstIndex(where: { accessionHeaders.contains($0) })
        var seen = Set<String>()
        var result: [String] = []
        for row in rows.dropFirst(column == nil ? 0 : 1) {
            let values: [String]
            if let column {
                values = [row.fields.indices.contains(column) ? row.fields[column] : ""]
            } else {
                values = row.fields.flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            }
            for value in values {
                let accession = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard isNucleotideAccession(accession) else {
                    throw ImportError.invalidAccession(value: value, line: row.line)
                }
                if seen.insert(accession).inserted { result.append(accession) }
            }
        }
        guard !result.isEmpty else { throw ImportError.empty }
        return result
    }

    public static func parseCSVFile(at url: URL) throws -> [String] {
        try parseCSV(String(contentsOf: url, encoding: .utf8))
    }

    private struct Row {
        let line: Int
        let fields: [String]
    }

    /// A small CSV reader supporting escaped quotes and embedded newlines. Both
    /// comma and tab delimiters retain the SRA import's mixed-list convenience.
    private static func readRows(_ input: String) throws -> [Row] {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let characters = Array(text)
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var line = 1
        var rowLine = 1
        var index = 0
        func finishRow() {
            fields.append(field)
            if fields.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                rows.append(Row(line: rowLine, fields: fields))
            }
            fields = []
            field = ""
            closedQuote = false
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                        closedQuote = true
                    }
                } else {
                    field.append(character)
                    if character == "\n" { line += 1 }
                }
            } else if character == "," || character == "\t" {
                fields.append(field)
                field = ""
                closedQuote = false
            } else if character == "\n" {
                finishRow()
                line += 1
                rowLine = line
            } else if character == "\"" {
                guard !closedQuote, field.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ImportError.malformedCSV(line: line)
                }
                field = ""
                quoted = true
            } else {
                guard !closedQuote || character.isWhitespace else { throw ImportError.malformedCSV(line: line) }
                field.append(character)
            }
            index += 1
        }
        guard !quoted else { throw ImportError.malformedCSV(line: rowLine) }
        finishRow()
        return rows
    }
}
