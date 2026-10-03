import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AIHaplotypingInputTableLoader {
    static func loadCalls(
        from url: URL,
        format: AIHaplotypingInputTableFormat
    ) throws -> [ONTGenotypeCall] {
        let resolvedFormat = try resolveFormat(format, url: url)
        switch resolvedFormat {
        case .json:
            return try loadJSONCalls(from: url)
        case .csv:
            return try loadDelimitedCalls(from: url, delimiter: ",")
        case .tsv:
            return try loadDelimitedCalls(from: url, delimiter: "\t")
        case .auto:
            preconditionFailure("auto format should be resolved before loading")
        }
    }

    private static func resolveFormat(
        _ format: AIHaplotypingInputTableFormat,
        url: URL
    ) throws -> AIHaplotypingInputTableFormat {
        guard format == .auto else { return format }
        switch url.pathExtension.lowercased() {
        case "csv":
            return .csv
        case "tsv", "tab":
            return .tsv
        case "json":
            return .json
        default:
            throw ValidationError("Could not infer --input-format from \(url.lastPathComponent); use --input-format csv, tsv, or json.")
        }
    }

    private static func loadJSONCalls(from url: URL) throws -> [ONTGenotypeCall] {
        let data = try Data(contentsOf: url)
        if let calls = try? JSONDecoder().decode([ONTGenotypeCall].self, from: data) {
            return calls
        }
        let rows = try JSONDecoder().decode([LooseJSONRow].self, from: data)
        return try rows.enumerated().compactMap { offset, row in
            try row.call(rowNumber: offset + 1)
        }
    }

    private static func loadDelimitedCalls(from url: URL, delimiter: Character) throws -> [ONTGenotypeCall] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let rows = parseDelimited(content, delimiter: delimiter)
        guard let header = rows.first, !header.isEmpty else {
            throw ValidationError("Input table \(url.path) does not contain a header row.")
        }
        let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { offset, name in
            (normalizedHeader(name), offset)
        })
        let sampleColumn = try requiredColumn(
            aliases: ["sample", "sampleid", "clientid", "gsid", "animal", "animalid"],
            in: headerIndex,
            label: "sample"
        )
        let genotypeColumn = try requiredColumn(
            aliases: ["genotype", "allele", "marker", "sequence", "call", "genotypelabel"],
            in: headerIndex,
            label: "genotype"
        )
        let alignmentsColumn = optionalColumn(
            aliases: ["passedalignments", "alignments", "mappedreadcount", "readcount", "reads", "count"],
            in: headerIndex
        )
        let uniqueColumn = optionalColumn(
            aliases: ["passeduniquereads", "uniquereads", "unique", "observations"],
            in: headerIndex
        )
        let sampleUniqueColumn = optionalColumn(
            aliases: ["sampleuniqueretainedreads", "uniqueretainedreads", "sampleunique"],
            in: headerIndex
        )

        let calls = try rows.dropFirst().enumerated().compactMap { offset, row -> ONTGenotypeCall? in
            let sample = value(at: sampleColumn, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
            let genotype = value(at: genotypeColumn, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty || !genotype.isEmpty else { return nil }
            guard !sample.isEmpty else {
                throw ValidationError("Input table row \(offset + 2) is missing a sample value.")
            }
            guard !genotype.isEmpty else {
                throw ValidationError("Input table row \(offset + 2) is missing a genotype value.")
            }
            let alignments = integerValue(at: alignmentsColumn, in: row) ?? 0
            let uniqueReads = integerValue(at: uniqueColumn, in: row) ?? alignments
            return ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: alignments,
                passedUniqueReads: uniqueReads,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: integerValue(at: sampleUniqueColumn, in: row),
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        guard !calls.isEmpty else {
            throw ValidationError("Input table \(url.path) did not contain any genotype rows.")
        }
        return calls
    }

    private static func requiredColumn(
        aliases: [String],
        in headerIndex: [String: Int],
        label: String
    ) throws -> Int {
        if let column = optionalColumn(aliases: aliases, in: headerIndex) {
            return column
        }
        throw ValidationError("Input table is missing a \(label) column.")
    }

    private static func optionalColumn(aliases: [String], in headerIndex: [String: Int]) -> Int? {
        aliases.compactMap { headerIndex[$0] }.first
    }

    private static func value(at index: Int?, in row: [String]) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index]
    }

    private static func integerValue(at index: Int?, in row: [String]) -> Int? {
        let raw = value(at: index, in: row)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !raw.isEmpty else { return nil }
        return Int(raw)
    }

    private static func normalizedHeader(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func parseDelimited(_ content: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        consume(character: next, delimiter: delimiter, row: &row, field: &field, rows: &rows, inQuotes: &inQuotes)
                    }
                } else {
                    inQuotes.toggle()
                }
            } else {
                consume(character: character, delimiter: delimiter, row: &row, field: &field, rows: &rows, inQuotes: &inQuotes)
            }
        }
        appendField(&field, to: &row)
        appendRow(row, to: &rows)
        return rows
    }

    private static func consume(
        character: Character,
        delimiter: Character,
        row: inout [String],
        field: inout String,
        rows: inout [[String]],
        inQuotes: inout Bool
    ) {
        if character == delimiter && !inQuotes {
            appendField(&field, to: &row)
        } else if character == "\n" && !inQuotes {
            appendField(&field, to: &row)
            appendRow(row, to: &rows)
            row.removeAll()
        } else if character == "\r" && !inQuotes {
            return
        } else {
            field.append(character)
        }
    }

    private static func appendField(_ field: inout String, to row: inout [String]) {
        row.append(field)
        field.removeAll(keepingCapacity: true)
    }

    private static func appendRow(_ row: [String], to rows: inout [[String]]) {
        guard row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return
        }
        rows.append(row)
    }

    private struct LooseJSONRow: Decodable {
        let sample: String?
        let sampleID: String?
        let genotype: String?
        let allele: String?
        let passedAlignments: Int?
        let passedUniqueReads: Int?
        let reads: Int?
        let sampleUniqueRetainedReads: Int?

        func call(rowNumber: Int) throws -> ONTGenotypeCall? {
            let sampleValue = (sample ?? sampleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let genotypeValue = (genotype ?? allele ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sampleValue.isEmpty || !genotypeValue.isEmpty else { return nil }
            guard !sampleValue.isEmpty else {
                throw ValidationError("Input JSON row \(rowNumber) is missing a sample value.")
            }
            guard !genotypeValue.isEmpty else {
                throw ValidationError("Input JSON row \(rowNumber) is missing a genotype value.")
            }
            let alignments = passedAlignments ?? reads ?? 0
            return ONTGenotypeCall(
                sample: sampleValue,
                genotype: genotypeValue,
                passedAlignments: alignments,
                passedUniqueReads: passedUniqueReads ?? alignments,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: sampleUniqueRetainedReads,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
    }
}
