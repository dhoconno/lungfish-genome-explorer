import CryptoKit
import Foundation
import LungfishCore
import SQLite3

extension MultipleSequenceAlignmentBundle {
    struct ParsedRow {
        let name: String
        var sequence: String
    }

    static func detectFormat(for url: URL, sourceText: String) throws -> SourceFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "fa", "fasta", "fas", "fna", "faa":
            return .alignedFASTA
        case "aln", "clustal", "clw":
            return .clustal
        case "phy", "phylip":
            return .phylip
        case "nex", "nexus":
            return .nexus
        case "sto", "stockholm":
            return .stockholm
        case "a2m", "a3m":
            return .a2mA3m
        default:
            let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(">") { return .alignedFASTA }
            if trimmed.uppercased().hasPrefix("CLUSTAL") { return .clustal }
            if trimmed.uppercased().hasPrefix("#NEXUS") { return .nexus }
            if trimmed.uppercased().hasPrefix("# STOCKHOLM") { return .stockholm }
            throw ImportError.unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ext)
        }
    }

    static func parse(_ text: String, format: SourceFormat) throws -> [ParsedRow] {
        switch format {
        case .alignedFASTA, .a2mA3m:
            return try parseFASTA(text)
        case .clustal:
            return try parseBlockedRows(text, skip: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty
                    || trimmed.uppercased().hasPrefix("CLUSTAL")
                    || trimmed.hasPrefix("*")
                    || trimmed.hasPrefix(":")
                    || trimmed.hasPrefix(".")
                    || line.first?.isWhitespace == true && trimmed.allSatisfy { "*:. ".contains($0) }
            })
        case .phylip:
            return try parsePHYLIP(text)
        case .nexus:
            return try parseNEXUS(text)
        case .stockholm:
            return try parseBlockedRows(text, skip: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "//"
            })
        }
    }

    private static func parseFASTA(_ text: String) throws -> [ParsedRow] {
        var rows: [ParsedRow] = []
        var currentName: String?
        var currentSequence = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                if let name = currentName {
                    rows.append(ParsedRow(name: name, sequence: currentSequence))
                }
                let name = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ImportError.malformedInput("FASTA row header is empty.") }
                currentName = name
                currentSequence = ""
            } else {
                guard currentName != nil else {
                    throw ImportError.malformedInput("FASTA sequence appears before the first header.")
                }
                currentSequence += line.filter { !$0.isWhitespace }
            }
        }
        if let name = currentName {
            rows.append(ParsedRow(name: name, sequence: currentSequence))
        }
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        guard rows.allSatisfy({ !$0.sequence.isEmpty }) else {
            throw ImportError.malformedInput("FASTA contains an empty aligned row.")
        }
        return rows
    }

    private static func parseBlockedRows(_ text: String, skip: (String) -> Bool) throws -> [ParsedRow] {
        var order: [String] = []
        var sequences: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            if skip(rawLine) { continue }
            let parts = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let segment = parts[1]
            if sequences[name] == nil {
                order.append(name)
                sequences[name] = segment
            } else {
                sequences[name, default: ""] += segment
            }
        }
        let rows = order.compactMap { name in sequences[name].map { ParsedRow(name: name, sequence: $0) } }
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        return rows
    }

    private static func parsePHYLIP(_ text: String) throws -> [ParsedRow] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { throw ImportError.emptyAlignment }
        let headerParts = header.split(whereSeparator: \.isWhitespace)
        guard headerParts.count >= 2,
              let expectedRows = Int(headerParts[0]),
              let expectedLength = Int(headerParts[1]) else {
            throw ImportError.malformedInput("PHYLIP header must contain row count and aligned length.")
        }
        let body = Array(lines.dropFirst())
        var rows: [ParsedRow] = []
        var index = 0
        while rows.count < expectedRows, index < body.count {
            let parts = body[index].split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first else {
                index += 1
                continue
            }

            var sequence = parts.dropFirst().joined()
            index += 1
            while sequence.count < expectedLength, index < body.count {
                sequence += body[index].filter { !$0.isWhitespace }
                index += 1
            }
            rows.append(ParsedRow(name: name, sequence: sequence))
        }

        guard rows.count == expectedRows else {
            throw ImportError.malformedInput("PHYLIP expected \(expectedRows) rows but found \(rows.count).")
        }
        let badLength = rows.first { $0.sequence.count != expectedLength }
        if let badLength {
            throw ImportError.malformedInput("PHYLIP row \(badLength.name) length does not match header nchar \(expectedLength).")
        }
        return rows
    }

    private static func parseNEXUS(_ text: String) throws -> [ParsedRow] {
        var inMatrix = false
        var matrixLines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = rawLine.replacingOccurrences(
                of: #"\[[^\]]*\]"#,
                with: "",
                options: .regularExpression
            )
            let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !inMatrix {
                if trimmed.lowercased().hasPrefix("matrix") {
                    inMatrix = true
                    let remainder = String(trimmed.dropFirst("matrix".count)).trimmingCharacters(in: .whitespaces)
                    if !remainder.isEmpty { matrixLines.append(remainder) }
                }
            } else if trimmed.hasPrefix(";") {
                break
            } else {
                matrixLines.append(trimmed)
                if trimmed.contains(";") { break }
            }
        }

        let rows = matrixLines.compactMap { line -> ParsedRow? in
            let cleaned = line.replacingOccurrences(of: ";", with: "")
            let parts = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return ParsedRow(name: parts[0], sequence: parts.dropFirst().joined())
        }
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        return rows
    }

    static func validateRectangular(_ rows: [ParsedRow]) throws {
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        let lengths = rows.map { ($0.name, $0.sequence.count) }
        guard let expected = lengths.first?.1, lengths.allSatisfy({ $0.1 == expected }) else {
            throw ImportError.unequalAlignedLengths(lengths)
        }
    }
}
