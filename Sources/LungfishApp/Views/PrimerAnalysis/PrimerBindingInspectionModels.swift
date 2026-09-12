import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct PrimerBindingRowComparison: Identifiable, Sendable {
    let id: Int
    let rowName: String
    /// Reference-oriented sequence, not an inferred experimental binding result.
    let alignedSite: String
    let status: String
    let mismatchCount: Int?
    /// Zero-based offsets in alignedSite, including reverse-strand comparisons mapped back to reference orientation.
    let mismatchPositions: [Int]
}

struct PrimerBindingInspectionPrimer: Identifiable, Sendable {
    let id: String
    let name: String
    let sequence: String
    let strand: String
    let alignedStart: Int
    let alignedEnd: Int
    let contiguousReference: Bool
    /// Same saved-output identity used by the Overview and Results selection.
    var reviewPrimerID: String = ""
}

struct PrimerBindingInspectionContext: Identifiable, Sendable {
    let id: String
    let title: String
    let alignedFASTA: String
    let annotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord]
    let primers: [PrimerBindingInspectionPrimer]
    let unavailableReason: String?

    struct Row: Sendable { let name: String; let sequence: [Character] }
    let rows: [Row]

    /// Only the selected primer is compared; no primers × rows result matrix is retained.
    func comparisons(for primer: PrimerBindingInspectionPrimer) throws -> [PrimerBindingRowComparison] {
        try rows.enumerated().map { index, row in
            try Task.checkCancellation()
            return Self.compare(id: index, name: row.name, row: row.sequence,
                lower: primer.alignedStart, upper: primer.alignedEnd, primer: primer.sequence,
                strand: primer.strand, contiguousReference: primer.contiguousReference)
        }
    }
    private struct RowMap: Decodable {
        struct Entry: Decodable { let rowIndex: Int; let originalHeader: String; let normalizedHeader: String }
        let schemaVersion: Int
        let inputID: UUID
        let rows: [Entry]
    }

    static func load(bundle: PrimerAnalysisBundle, schemes: [PrimalSchemeDisplayResult]) throws -> [Self] {
        func read(_ path: String) throws -> Data {
            guard let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == path }) else {
                throw PrimerAnalysisBundleError.invalidArtifact("Missing binding inspection artifact: " + path)
            }
            let bytes = try Data(contentsOf: bundle.artifactURL(forRelativePath: path))
            guard UInt64(bytes.count) == artifact.byteSize,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == artifact.sha256.lowercased() else {
                throw PrimerAnalysisBundleError.integrityMismatch(path)
            }
            return bytes
        }
        var contexts: [Self] = []
        for scheme in schemes {
            let referencePath = String(scheme.id.dropLast("primer.bed".count)) + "reference.fasta"
            let references = try parseFASTA(read(referencePath))
            for input in bundle.manifest.inputs {
                try Task.checkCancellation()
                let alignmentPath = "inputs/\(input.id.uuidString).fasta"
                let mapPath = "inputs/\(input.id.uuidString)-row-map.json"
                guard input.artifactPaths.contains(alignmentPath), input.artifactPaths.contains(mapPath) else { continue }
                let rows = try parseFASTA(read(alignmentPath))
                guard Set(rows.map { $0.sequence.count }).count == 1 else {
                    throw PrimerAnalysisBundleError.invalidArtifact("Binding inspection alignment rows differ in length")
                }
                guard let first = rows.first,
                      let reference = references.first(where: { $0.name == first.name }) else { continue }
                let mapping = try JSONDecoder().decode(RowMap.self, from: read(mapPath))
                guard mapping.schemaVersion == 1, mapping.inputID == input.id,
                      mapping.rows.count == rows.count,
                      mapping.rows.enumerated().allSatisfy({ index, entry in
                          entry.rowIndex == index && entry.normalizedHeader == rows[index].name
                              && isSafeDisplayHeader(entry.originalHeader)
                      }) else { throw PrimerAnalysisBundleError.invalidArtifact("Binding inspection row identities disagree") }
                let displayFASTA = rows.enumerated().map { index, row in
                    ">\(mapping.rows[index].originalHeader)\n\(String(row.sequence))\n"
                }.joined()
                let displayRows = rows.enumerated().map { index, row in
                    Row(name: mapping.rows[index].originalHeader, sequence: row.sequence)
                }
                let contextID = scheme.id + ":" + input.id.uuidString
                let title = (input.label ?? mapping.rows[0].originalHeader)
                let ungappedColumns = first.sequence.indices.filter { first.sequence[$0] != "-" }
                guard reference.sequence == ungappedColumns.map({ first.sequence[$0] }) else {
                    contexts.append(.init(id: contextID, title: title, alignedFASTA: displayFASTA,
                        annotations: [], primers: [], unavailableReason: "Stored reference does not match the first alignment row; primer positions cannot be projected reliably.", rows: displayRows))
                    continue
                }
                var primers: [PrimerBindingInspectionPrimer] = []
                var annotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = []
                for primer in scheme.primers where primer.reference == first.name {
                    guard primer.start >= 0, primer.end > primer.start, primer.end <= ungappedColumns.count else {
                        throw PrimerAnalysisBundleError.invalidArtifact("Binding inspection coordinates exceed the reference")
                    }
                    let columns = Array(ungappedColumns[primer.start..<primer.end])
                    let lower = columns[0], upper = columns[columns.count - 1] + 1
                    var intervals: [AnnotationInterval] = []
                    var intervalStart = lower, previous = lower
                    for column in columns.dropFirst() {
                        if column != previous + 1 {
                            intervals.append(.init(start: intervalStart, end: previous + 1))
                            intervalStart = column
                        }
                        previous = column
                    }
                    intervals.append(.init(start: intervalStart, end: previous + 1))
                    let primerID = contextID + ":" + String(primer.id)
                    annotations.append(.init(id: primerID, origin: .source, rowID: "inspection-row-0",
                        rowName: mapping.rows[0].originalHeader, sourceSequenceName: first.name,
                        sourceFilePath: scheme.id, sourceTrackID: "primer-pool-\(primer.pool)",
                        sourceTrackName: "Primer pool \(primer.pool)", sourceAnnotationID: primerID,
                        name: primer.name, type: "primer_bind", strand: primer.strand,
                        sourceIntervals: [.init(start: primer.start, end: primer.end)], alignedIntervals: intervals,
                        qualifiers: ["sequence_5prime_to_3prime": [primer.sequence]],
                        note: "Stored reference binding footprint projected into the alignment; not evidence of binding on every row.",
                        projection: nil, warnings: []))
                    primers.append(.init(id: primerID, name: primer.name, sequence: primer.sequence,
                        strand: primer.strand, alignedStart: lower, alignedEnd: upper, contiguousReference: intervals.count == 1,
                        reviewPrimerID: "\(scheme.id)-primer-\(primer.id)"))
                }
                contexts.append(.init(id: contextID, title: title, alignedFASTA: displayFASTA,
                    annotations: annotations, primers: primers, unavailableReason: nil, rows: displayRows))
            }
        }
        return contexts
    }

    static func isSafeDisplayHeader(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.union(.newlines).contains($0)
            }
    }

    private static func parseFASTA(_ data: Data) throws -> [Row] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PrimerAnalysisBundleError.invalidArtifact("Binding inspection FASTA is not UTF-8")
        }
        var rows: [Row] = [], name: String?, sequence: [Character] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(">") {
                if let name { rows.append(.init(name: name, sequence: sequence)) }
                name = line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
                sequence = []
            } else {
                guard name != nil else { throw PrimerAnalysisBundleError.invalidArtifact("Missing FASTA row header") }
                sequence += line.uppercased().filter { !$0.isWhitespace }
            }
        }
        if let name { rows.append(.init(name: name, sequence: sequence)) }
        guard !rows.isEmpty, rows.allSatisfy({ !$0.sequence.isEmpty && $0.sequence.allSatisfy { "ACGTRYSWKMBDHVN-".contains($0) } }),
              Set(rows.map(\.name)).count == rows.count else {
            throw PrimerAnalysisBundleError.invalidArtifact("Invalid binding inspection FASTA rows")
        }
        return rows
    }

    /// Conservative positional comparison: indels and unknown bases are not guessed into matches.
    static func compare(id: Int, name: String, row: [Character], lower: Int, upper: Int,
                        primer: String, strand: String, contiguousReference: Bool) -> PrimerBindingRowComparison {
        func result(_ site: String, _ status: String, _ mismatches: Int? = nil, positions: [Int] = []) -> PrimerBindingRowComparison {
            .init(id: id, rowName: name, alignedSite: site, status: status, mismatchCount: mismatches, mismatchPositions: positions)
        }
        guard lower >= 0, upper > lower, upper <= row.count else { return result("", "Unavailable: alignment coordinates disagree") }
        let site = String(row[lower..<upper])
        guard contiguousReference, upper - lower == primer.count else { return result(site, "Unavailable: insertion/deletion in reference mapping") }
        if site.contains("-") {
            let first = row.firstIndex(where: { $0 != "-" }), last = row.lastIndex(where: { $0 != "-" })
            if first == nil || lower < first! || upper - 1 > last! { return result(site, "Unknown: uncovered alignment end") }
            return result(site, "Unavailable: internal alignment gap")
        }
        guard site.allSatisfy({ "ACGT".contains($0) }) else { return result(site, "Unknown: ambiguous sequence bases") }
        let complement: [Character: Character] = ["A":"T", "C":"G", "G":"C", "T":"A"]
        let oriented = strand == "-" ? Array(site.reversed().map { complement[$0]! }) : Array(site)
        let allowed: [Character: Set<Character>] = ["A":["A"], "C":["C"], "G":["G"], "T":["T"],
            "R":["A","G"], "Y":["C","T"], "S":["G","C"], "W":["A","T"], "K":["G","T"], "M":["A","C"],
            "B":["C","G","T"], "D":["A","G","T"], "H":["A","C","T"], "V":["A","C","G"], "N":["A","C","G","T"]]
        guard ["+", "-"].contains(strand), primer.uppercased().allSatisfy({ allowed[$0] != nil }) else {
            return result(site, "Unavailable: unsupported primer representation")
        }
        let positions = zip(primer.uppercased(), oriented).enumerated().compactMap { index, pair -> Int? in
            guard !allowed[pair.0]!.contains(pair.1) else { return nil }
            return strand == "-" ? oriented.count - 1 - index : index
        }.sorted()
        let count = positions.count
        return result(site, count == 0 ? "0 mismatches (IUPAC-compatible)" : "\(count) positional mismatches", count, positions: positions)
    }
}
