import Foundation
import LungfishIO

/// A deliberately small EMBL flat-file renderer for the same diagnostic
/// sequence records Lungfish publishes as FASTA and GenBank.
struct FullLengthONTMHCEMBLWriter {
    func write(_ records: [GenBankRecord], to url: URL) throws {
        let text = records
            .sorted { recordID($0) < recordID($1) }
            .map(format)
            .joined()
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func format(_ record: GenBankRecord) -> String {
        let identifier = recordID(record)
        let sequence = record.sequence.asString().uppercased()
        let definition = record.definition ?? record.sequence.description ?? identifier
        var lines = [
            "ID   \(identifier); SV 1; linear; genomic DNA; STD; UNC; \(sequence.count) BP.",
            "XX",
            "AC   \(identifier);",
            "XX",
            "DE   \(definition)",
            "XX",
        ]
        for comment in record.recordFields
            .filter({ $0.key.uppercased() == "COMMENT" })
            .sorted(by: { $0.ordinal < $1.ordinal }) {
            lines.append("CC   \(comment.value)")
        }
        if record.recordFields.contains(where: { $0.key.uppercased() == "COMMENT" }) {
            lines.append("XX")
        }
        lines.append("FH   Key             Location/Qualifiers")
        lines.append("FH")
        lines.append("FT   source          1..\(sequence.count)")
        if let source = record.annotations.first(where: { $0.type == .source }) {
            for key in source.qualifiers.keys.sorted() {
                for value in source.qualifiers[key]?.values ?? [] {
                    lines.append(
                        "FT                   /\(key)=\"\(escapedQualifier(value))\""
                    )
                }
            }
        }
        lines.append("XX")
        let counts = nucleotideCounts(sequence)
        lines.append(
            "SQ   Sequence \(sequence.count) BP; \(counts.a) A; \(counts.c) C; "
                + "\(counts.g) G; \(counts.t) T; \(counts.other) other;"
        )
        lines.append(contentsOf: sequenceLines(sequence))
        lines.append("//")
        return lines.joined(separator: "\n") + "\n"
    }

    private func recordID(_ record: GenBankRecord) -> String {
        let value = record.accession ?? record.sequence.name
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }

    private func escapedQualifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private func nucleotideCounts(
        _ sequence: String
    ) -> (a: Int, c: Int, g: Int, t: Int, other: Int) {
        var counts = (a: 0, c: 0, g: 0, t: 0, other: 0)
        for base in sequence {
            switch base {
            case "A": counts.a += 1
            case "C": counts.c += 1
            case "G": counts.g += 1
            case "T": counts.t += 1
            default: counts.other += 1
            }
        }
        return counts
    }

    private func sequenceLines(_ sequence: String) -> [String] {
        var result: [String] = []
        var offset = 0
        while offset < sequence.count {
            let end = min(offset + 60, sequence.count)
            let lower = sequence.index(sequence.startIndex, offsetBy: offset)
            let upper = sequence.index(sequence.startIndex, offsetBy: end)
            let chunk = String(sequence[lower..<upper]).lowercased()
            let groups = stride(from: 0, to: chunk.count, by: 10).map { groupStart in
                let groupEnd = min(groupStart + 10, chunk.count)
                let start = chunk.index(chunk.startIndex, offsetBy: groupStart)
                let stop = chunk.index(chunk.startIndex, offsetBy: groupEnd)
                return String(chunk[start..<stop])
            }
            result.append("     " + groups.joined(separator: " ") + " \(end)")
            offset = end
        }
        return result
    }
}
