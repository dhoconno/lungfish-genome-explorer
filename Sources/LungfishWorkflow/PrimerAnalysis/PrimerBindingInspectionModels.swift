import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public struct PrimerBindingRowComparison: Identifiable, Sendable {
    public let id: Int
    public let rowName: String
    /// Reference-oriented sequence, not an inferred experimental binding result.
    public let alignedSite: String
    public let status: String
    public let mismatchCount: Int?
    /// Zero-based offsets in alignedSite, including reverse-strand comparisons mapped back to reference orientation.
    public let mismatchPositions: [Int]

    public init(
      id: Int,
      rowName: String,
      alignedSite: String,
      status: String,
      mismatchCount: Int?,
      mismatchPositions: [Int]
    ) {
      self.id = id
      self.rowName = rowName
      self.alignedSite = alignedSite
      self.status = status
      self.mismatchCount = mismatchCount
      self.mismatchPositions = mismatchPositions
    }
}

public struct PrimerBindingInspectionPrimer: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sequence: String
    public let strand: String
    public let alignedStart: Int
    public let alignedEnd: Int
    public let contiguousReference: Bool
    public var unavailableReason: String? = nil
    /// Same saved-output identity used by the Overview and Results selection.
    public var reviewPrimerID: String = ""

    public init(
      id: String,
      name: String,
      sequence: String,
      strand: String,
      alignedStart: Int,
      alignedEnd: Int,
      contiguousReference: Bool,
      unavailableReason: String? = nil,
      reviewPrimerID: String = ""
    ) {
      self.id = id
      self.name = name
      self.sequence = sequence
      self.strand = strand
      self.alignedStart = alignedStart
      self.alignedEnd = alignedEnd
      self.contiguousReference = contiguousReference
      self.unavailableReason = unavailableReason
      self.reviewPrimerID = reviewPrimerID
    }
}

public struct PrimerBindingInspectionContext: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let alignedFASTA: String
    public let annotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord]
    public let primers: [PrimerBindingInspectionPrimer]
    public let unavailableReason: String?

    public struct Row: Sendable {
        public let name: String
        public let sequence: [Character]
        public init(name: String, sequence: [Character]) { self.name = name; self.sequence = sequence }
    }
    public let rows: [Row]

    public init(
      id: String,
      title: String,
      alignedFASTA: String,
      annotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord],
      primers: [PrimerBindingInspectionPrimer],
      unavailableReason: String?,
      rows: [Row]
    ) {
      self.id = id
      self.title = title
      self.alignedFASTA = alignedFASTA
      self.annotations = annotations
      self.primers = primers
      self.unavailableReason = unavailableReason
      self.rows = rows
    }

    /// Only the selected primer is compared; no primers × rows result matrix is retained.
    public func comparisons(for primer: PrimerBindingInspectionPrimer) throws -> [PrimerBindingRowComparison] {
        try rows.enumerated().map { index, row in
            try Task.checkCancellation()
            if let reason = primer.unavailableReason {
                return .init(id: index, rowName: row.name, alignedSite: "",
                    status: "Unavailable: " + reason, mismatchCount: nil, mismatchPositions: [])
            }
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

    public static func load(bundle: PrimerAnalysisBundle, schemes: [PrimalSchemeDisplayResult]) throws -> [Self] {
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

    public static func loadNormalized(
        bundle: PrimerAnalysisBundle, document: PrimerSchemeResultsDocument,
        projections: [String: PrimerBindingProjection]
    ) throws -> [Self] {
        func read(_ path: String) throws -> Data {
            guard let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == path }) else {
                throw PrimerAnalysisBundleError.invalidArtifact(
                    "Missing normalized binding inspection artifact: " + path)
            }
            let bytes = try Data(contentsOf: bundle.artifactURL(forRelativePath: path))
            guard UInt64(bytes.count) == artifact.byteSize,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                    == artifact.sha256.lowercased() else {
                throw PrimerAnalysisBundleError.integrityMismatch(path)
            }
            return bytes
        }
        var contexts: [Self] = []
        for result in document.results {
            for target in result.targets {
                try Task.checkCancellation()
                guard let projection = projections[target.bindingProjectionPath] else {
                    throw PrimerAnalysisBundleError.invalidArtifact(
                        "Normalized binding projection is missing.")
                }
                let sourceRows = try parseFASTA(read(projection.sourcePath))
                guard Set(sourceRows.map { $0.sequence.count }).count == 1,
                      sourceRows.first?.sequence.count == projection.sourceLength else {
                    throw PrimerAnalysisBundleError.invalidArtifact(
                        "Normalized binding source rows disagree with the saved projection length.")
                }
                let generatedReferences = try parseFASTA(read(target.referencePath))
                guard let generatedReference = generatedReferences.first(where: { $0.name == target.referenceID }),
                      generatedReference.sequence.count == target.referenceLength else {
                    throw PrimerAnalysisBundleError.invalidArtifact(
                        "Normalized generated reference identity or length is inconsistent.")
                }
                let generatedReferenceURL = try bundle.artifactURL(forRelativePath: target.referencePath)
                let displayFASTA = sourceRows.map {
                    ">\($0.name)\n\(String($0.sequence))\n"
                }.joined()
                var annotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = []
                var primers: [PrimerBindingInspectionPrimer] = []
                for oligo in target.oligos {
                    let primerID = target.id.uuidString.lowercased() + ":" + oligo.id.uuidString.lowercased()
                    let reviewID = oligo.id.uuidString.lowercased()
                    switch PrimerSchemeViewerAdapter.project(oligo: oligo, through: projection) {
                    case .exact(let start, let end):
                        let interval = AnnotationInterval(start: start, end: end)
                        annotations.append(.init(id: primerID, origin: .source,
                            rowID: "inspection-row-0", rowName: sourceRows[0].name,
                            sourceSequenceName: target.referenceID,
                            sourceFilePath: generatedReferenceURL.path,
                            sourceTrackID: "normalized-" + oligo.role.rawValue,
                            sourceTrackName: oligo.role == .probe ? "Probe" : "Primer",
                            sourceAnnotationID: oligo.id.uuidString.lowercased(),
                            name: oligo.name, type: "primer_bind", strand: oligo.strand.rawValue,
                            sourceIntervals: [.init(start: oligo.start, end: oligo.end)],
                            alignedIntervals: [interval],
                            qualifiers: ["sequence_5prime_to_3prime": [oligo.sequence],
                                         "oligo_role": [oligo.role.rawValue]],
                            note: "Saved generated-reference footprint with an exact one-to-one projection onto the original input rows.",
                            projection: nil, warnings: []))
                        primers.append(.init(id: primerID, name: oligo.name,
                            sequence: oligo.sequence, strand: oligo.strand.rawValue,
                            alignedStart: start, alignedEnd: end, contiguousReference: true,
                            reviewPrimerID: reviewID))
                    case .unavailable(let reason):
                        primers.append(.init(id: primerID, name: oligo.name,
                            sequence: oligo.sequence, strand: oligo.strand.rawValue,
                            alignedStart: 0, alignedEnd: min(oligo.sequence.count, projection.sourceLength),
                            contiguousReference: false, unavailableReason: reason,
                            reviewPrimerID: reviewID))
                    }
                }
                contexts.append(.init(id: target.id.uuidString.lowercased(), title: target.label,
                    alignedFASTA: displayFASTA, annotations: annotations, primers: primers,
                    unavailableReason: nil, rows: sourceRows))
            }
        }
        return contexts
    }

    /// Primer3 templates chosen from an alignment keep the column-to-template map, so each
    /// candidate oligo can be laid over every saved row. Single-sequence templates yield nothing.
    public static func loadPrimer3(bundle: PrimerAnalysisBundle, results: Primer3NormalizedResults) throws -> [Self] {
        func read(_ path: String) throws -> Data {
            guard let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == path }) else {
                throw PrimerAnalysisBundleError.invalidArtifact("Missing Primer3 binding inspection artifact: " + path)
            }
            let bytes = try Data(contentsOf: bundle.artifactURL(forRelativePath: path))
            guard UInt64(bytes.count) == artifact.byteSize,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == artifact.sha256.lowercased() else {
                throw PrimerAnalysisBundleError.integrityMismatch(path)
            }
            return bytes
        }
        var contexts: [Self] = []
        for result in results.results where result.sourceKind == "msa" && !result.pairs.isEmpty {
            try Task.checkCancellation()
            guard let map = result.alignmentToTemplate,
                  let input = bundle.manifest.inputs.first(where: { $0.id == result.inputID }) else { continue }
            let prefix = "source-inputs/\(result.inputID.uuidString)/"
            guard let alignedPath = input.artifactPaths.first(where: {
                      $0.hasPrefix(prefix) && $0.hasSuffix("/alignment/primary.aligned.fasta") }),
                  let rowsPath = input.artifactPaths.first(where: {
                      $0.hasPrefix(prefix) && $0.hasSuffix("/metadata/rows.json") }) else { continue }
            let rows = try parseFASTA(read(alignedPath))
            let metadata = try JSONDecoder().decode([MultipleSequenceAlignmentBundle.Row].self, from: read(rowsPath))
            guard Set(rows.map { $0.sequence.count }).count == 1, rows.count == metadata.count,
                  rows[0].sequence.count == map.count, result.sourceIndex >= 0, result.sourceIndex < rows.count,
                  metadata.allSatisfy({ isSafeDisplayHeader($0.displayName) }) else {
                throw PrimerAnalysisBundleError.invalidArtifact("Primer3 alignment rows disagree with the saved template map")
            }
            let template = rows[result.sourceIndex]
            let ungappedColumns = template.sequence.indices.filter { template.sequence[$0] != "-" && template.sequence[$0] != "." }
            guard ungappedColumns.count == result.templateSequence.utf8.count,
                  ungappedColumns.enumerated().allSatisfy({ map[$0.element] == $0.offset }) else {
                throw PrimerAnalysisBundleError.invalidArtifact("Primer3 template map does not describe the saved template row")
            }
            let displayRows = rows.enumerated().map { index, row in
                Row(name: metadata[index].displayName, sequence: row.sequence)
            }
            let displayFASTA = displayRows.map { ">\($0.name)\n\(String($0.sequence))\n" }.joined()
            let contextID = result.resultID.uuidString.lowercased()
            var primers: [PrimerBindingInspectionPrimer] = []
            var annotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = []
            for (pairIndex, pair) in result.pairs.enumerated() {
                let oligos = [(pair.left, "Forward"), (pair.right, "Reverse")]
                    + (pair.internalOligo.map { [($0, "Probe")] } ?? [])
                for (oligo, role) in oligos {
                    guard oligo.start >= 0, oligo.end > oligo.start, oligo.end <= ungappedColumns.count else {
                        throw PrimerAnalysisBundleError.invalidArtifact("Primer3 oligo coordinates exceed the template")
                    }
                    let columns = Array(ungappedColumns[oligo.start..<oligo.end])
                    var intervals: [AnnotationInterval] = []
                    var intervalStart = columns[0], previous = columns[0]
                    for column in columns.dropFirst() {
                        if column != previous + 1 {
                            intervals.append(.init(start: intervalStart, end: previous + 1))
                            intervalStart = column
                        }
                        previous = column
                    }
                    intervals.append(.init(start: intervalStart, end: previous + 1))
                    let strand = oligo.orientation == .forward ? "+" : "-"
                    let name = "Candidate \(pairIndex + 1) · \(role) primer"
                    let primerID = contextID + ":" + oligo.id.uuidString.lowercased()
                    annotations.append(.init(id: primerID, origin: .source, rowID: "inspection-row-\(result.sourceIndex)",
                        rowName: metadata[result.sourceIndex].displayName, sourceSequenceName: template.name,
                        sourceFilePath: alignedPath, sourceTrackID: "primer3-candidate-\(pairIndex + 1)",
                        sourceTrackName: "Candidate \(pairIndex + 1)", sourceAnnotationID: primerID,
                        name: name, type: "primer_bind", strand: strand,
                        sourceIntervals: [.init(start: oligo.start, end: oligo.end)], alignedIntervals: intervals,
                        qualifiers: ["sequence_5prime_to_3prime": [oligo.sequence]],
                        note: "Saved template binding footprint projected into the alignment; not evidence of binding on every row.",
                        projection: nil, warnings: []))
                    primers.append(.init(id: primerID, name: name, sequence: oligo.sequence, strand: strand,
                        alignedStart: columns[0], alignedEnd: columns[columns.count - 1] + 1,
                        contiguousReference: intervals.count == 1, reviewPrimerID: oligo.id.uuidString))
                }
            }
            contexts.append(.init(id: contextID, title: result.title, alignedFASTA: displayFASTA,
                annotations: annotations, primers: primers, unavailableReason: nil, rows: displayRows))
        }
        return contexts
    }

    public static func isSafeDisplayHeader(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.union(.newlines).contains($0)
            }
    }

    public static func parseFASTA(_ data: Data) throws -> [Row] {
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
                // Rows are nucleotide-only (validated below), so U is uracil. Show and compare it
                // as T, matching the DNA primers, so RNA-alphabet inputs saved before import
                // normalization do not display every U as a difference.
                sequence += line.uppercased().filter { !$0.isWhitespace }.map { $0 == "U" ? "T" : $0 }
            }
        }
        if let name { rows.append(.init(name: name, sequence: sequence)) }
        guard !rows.isEmpty, rows.allSatisfy({ !$0.sequence.isEmpty && $0.sequence.allSatisfy { "ACGTURYSWKMBDHVN-".contains($0) } }),
              Set(rows.map(\.name)).count == rows.count else {
            throw PrimerAnalysisBundleError.invalidArtifact("Invalid binding inspection FASTA rows")
        }
        return rows
    }

    /// Conservative positional comparison: indels and unknown bases are not guessed into matches.
    public static func compare(id: Int, name: String, row: [Character], lower: Int, upper: Int,
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
        guard site.allSatisfy({ "ACGTU".contains($0) }) else { return result(site, "Unknown: ambiguous sequence bases") }
        // RNA-alphabet rows (genomic RNA references) pair with DNA primers exactly as T would.
        let dnaSite = site.map { $0 == "U" ? Character("T") : $0 }
        let complement: [Character: Character] = ["A":"T", "C":"G", "G":"C", "T":"A"]
        let oriented = strand == "-" ? Array(dnaSite.reversed().map { complement[$0]! }) : dnaSite
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
