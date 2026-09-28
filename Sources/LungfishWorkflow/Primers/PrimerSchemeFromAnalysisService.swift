import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

/// One saved design result that can become a `.lungfishprimers` scheme, or the reason it cannot.
public struct PrimerSchemeFromAnalysisCandidate: Sendable, Equatable, Identifiable {
    public var id: UUID { resultID }
    public let resultID: UUID
    public let label: String
    /// "PrimalScheme3", "Olivar" or "varVAMP".
    public let engine: String
    /// The BED chromosome and the scheme's canonical accession.
    public let referenceID: String
    /// Which sequence the coordinates belong to and what reads must be mapped to.
    public let referenceStatement: String
    public let primerCount: Int
    public let ampliconCount: Int
    public let poolCount: Int
    public let notes: [String]
    public let refusalReason: String?
    /// Other names the design run used for the same reference sequence.
    public let equivalentReferenceIDs: [String]

    public init(resultID: UUID, label: String, engine: String, referenceID: String, referenceStatement: String,
                primerCount: Int, ampliconCount: Int, poolCount: Int, notes: [String], refusalReason: String?,
                equivalentReferenceIDs: [String] = []) {
        self.resultID = resultID; self.label = label; self.engine = engine; self.referenceID = referenceID
        self.referenceStatement = referenceStatement; self.primerCount = primerCount
        self.ampliconCount = ampliconCount; self.poolCount = poolCount; self.notes = notes
        self.refusalReason = refusalReason; self.equivalentReferenceIDs = equivalentReferenceIDs
    }

    public var isExportable: Bool { refusalReason == nil }
}

public struct PrimerSchemeFromAnalysisRequest: Sendable {
    public let analysisURL: URL
    /// Required when the analysis holds more than one exportable result.
    public let resultID: UUID?
    public let outputURL: URL
    public let projectURL: URL?
    public let displayName: String?
    public let argv: [String]
    public let workflowName: String
    public let toolVersion: String

    public init(analysisURL: URL, resultID: UUID?, outputURL: URL, projectURL: URL?, displayName: String?,
                argv: [String], workflowName: String, toolVersion: String) {
        self.analysisURL = analysisURL; self.resultID = resultID; self.outputURL = outputURL
        self.projectURL = projectURL; self.displayName = displayName; self.argv = argv
        self.workflowName = workflowName; self.toolVersion = toolVersion
    }
}

public enum PrimerSchemeFromAnalysisError: Error, LocalizedError, Sendable, Equatable {
    case noExportableResult(String)
    case ambiguousResult([String])
    case unknownResult(UUID)
    case refused(String)
    case invalidAnalysis(String)

    public var errorDescription: String? {
        switch self {
        case .noExportableResult(let reason):
            return "This analysis has no result that can become a primer scheme. \(reason)"
        case .ambiguousResult(let labels):
            return "Choose one result with --result-id. Exportable results: \(labels.joined(separator: ", "))."
        case .unknownResult(let id):
            return "No exportable result in this analysis has the ID \(id.uuidString)."
        case .refused(let reason):
            return "This result cannot be saved as a primer scheme. \(reason)"
        case .invalidAnalysis(let reason):
            return "The saved analysis could not be read: \(reason)"
        }
    }
}

/// Turns a saved tiled design into a `.lungfishprimers` bundle for primer trimming.
///
/// Every engine designs on a different sequence, so the exported BED keeps the
/// coordinates of that design reference and the bundle carries the reference
/// FASTA as an attachment. Reads must be mapped to that sequence, or to a
/// sequence identical to it, before the scheme can trim them.
public enum PrimerSchemeFromAnalysisService {
    public static let referenceAttachmentPath = "attachments/design-reference.fasta"

    struct Plan: Sendable {
        let candidate: PrimerSchemeFromAnalysisCandidate
        let bed: String
        let primersFASTA: String
        let referenceFASTA: String
        let sourceArtifactPaths: [String]
    }

    public static func candidates(analysisURL: URL) throws -> [PrimerSchemeFromAnalysisCandidate] {
        try plans(analysisURL: analysisURL).map(\.candidate)
    }

    @discardableResult
    public static func export(request: PrimerSchemeFromAnalysisRequest) throws -> PrimerSchemeImportResult {
        let plans = try plans(analysisURL: request.analysisURL)
        let exportable = plans.filter { $0.candidate.isExportable }
        let plan: Plan
        if let resultID = request.resultID {
            guard let chosen = plans.first(where: { $0.candidate.resultID == resultID }) else {
                throw PrimerSchemeFromAnalysisError.unknownResult(resultID)
            }
            if let reason = chosen.candidate.refusalReason { throw PrimerSchemeFromAnalysisError.refused(reason) }
            plan = chosen
        } else if exportable.count == 1 {
            plan = exportable[0]
        } else if exportable.isEmpty {
            if let refused = plans.first?.candidate.refusalReason {
                throw PrimerSchemeFromAnalysisError.refused(refused)
            }
            throw PrimerSchemeFromAnalysisError.noExportableResult(
                "Only PrimalScheme3, Olivar and tiled varVAMP schemes can be saved. Primer3 candidate pairs are not a tiled scheme.")
        } else {
            throw PrimerSchemeFromAnalysisError.ambiguousResult(
                exportable.map { "\($0.candidate.label) (\($0.candidate.resultID.uuidString))" })
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-scheme-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let bedURL = staging.appendingPathComponent("primers.bed")
        let fastaURL = staging.appendingPathComponent("primers.fasta")
        let referenceURL = staging.appendingPathComponent("design-reference.fasta")
        try Data(plan.bed.utf8).write(to: bedURL)
        try Data(plan.primersFASTA.utf8).write(to: fastaURL)
        try Data(plan.referenceFASTA.utf8).write(to: referenceURL)

        let candidate = plan.candidate
        let analysisName = request.analysisURL.deletingPathExtension().lastPathComponent
        let derivation = PrimerSchemeDerivation(
            analysisURL: request.analysisURL, resultID: candidate.resultID, resultLabel: candidate.label,
            engine: candidate.engine, referenceStatement: candidate.referenceStatement,
            sourceArtifactURLs: plan.sourceArtifactPaths.map { request.analysisURL.appendingPathComponent($0) },
            notes: candidate.notes, ampliconCount: candidate.ampliconCount)
        return try PrimerSchemeImportService.importBundle(request: PrimerSchemeImportRequest(
            bedURL: bedURL, fastaURL: fastaURL, attachments: [referenceURL],
            outputURL: request.outputURL, projectURL: request.projectURL,
            displayName: request.displayName ?? "\(analysisName) · \(candidate.label)",
            canonicalAccession: candidate.referenceID,
            equivalentAccessions: candidate.equivalentReferenceIDs,
            argv: request.argv, workflowName: request.workflowName, toolVersion: request.toolVersion,
            description: "\(candidate.engine) design saved from the primer analysis \"\(analysisName)\". "
                + candidate.referenceStatement,
            source: "designed",
            attachmentDescriptions: [referenceURL.lastPathComponent:
                "Design reference the BED coordinates belong to. Map reads to this sequence before primer trimming."],
            derivation: derivation))
    }

    // MARK: - Planning

    static func plans(analysisURL: URL) throws -> [Plan] {
        let bundle: PrimerAnalysisBundle
        do { bundle = try PrimerAnalysisBundle.load(from: analysisURL) } catch {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis(error.localizedDescription)
        }
        let manifest = bundle.manifest
        if manifest.artifacts.contains(where: { $0.relativePath == "results/primer3-normalized-v1.json" }) {
            return []
        }
        if let artifact = manifest.artifacts.first(where: { $0.relativePath == PrimerSchemeResultsDocument.storedRelativePath }) {
            return try normalizedPlans(bundle: bundle, artifact: artifact)
        }
        return try primalSchemePlans(bundle: bundle)
    }

    // MARK: PrimalScheme3

    private static func primalSchemePlans(bundle: PrimerAnalysisBundle) throws -> [Plan] {
        let manifest = bundle.manifest
        var rowMaps: [String: (original: String, inputLabel: String, alignmentPath: String)] = [:]
        struct RowMap: Decodable {
            struct Row: Decodable { let rowIndex: Int; let originalHeader: String; let normalizedHeader: String }
            let schemaVersion: Int
            let inputID: UUID
            let rows: [Row]
        }
        for input in manifest.inputs {
            let mapPath = "inputs/\(input.id.uuidString)-row-map.json"
            let alignmentPath = "inputs/\(input.id.uuidString).fasta"
            guard input.artifactPaths.contains(mapPath), input.artifactPaths.contains(alignmentPath) else { continue }
            let map = try decode(RowMap.self, path: mapPath, in: bundle)
            for row in map.rows {
                rowMaps[row.normalizedHeader] = (row.originalHeader, input.label ?? row.originalHeader, alignmentPath)
            }
        }
        var plans: [Plan] = []
        for result in manifest.results {
            for bedPath in result.artifactPaths where bedPath.hasSuffix("/primer.bed") {
                let prefix = String(bedPath.dropLast("primer.bed".count))
                let referencePath = prefix + "reference.fasta"
                let ampliconPath = prefix + "amplicon.bed"
                guard result.artifactPaths.contains(referencePath) else { continue }
                let label = result.label ?? result.id.uuidString
                do {
                    plans.append(try primalSchemePlan(bundle: bundle, result: result, label: label, bedPath: bedPath,
                        referencePath: referencePath,
                        ampliconPath: result.artifactPaths.contains(ampliconPath) ? ampliconPath : nil,
                        rowMaps: rowMaps))
                } catch let error as PrimerSchemeFromAnalysisError {
                    guard case .refused(let reason) = error else { throw error }
                    plans.append(Plan(candidate: .init(resultID: result.id, label: label, engine: "PrimalScheme3",
                        referenceID: "", referenceStatement: "", primerCount: 0, ampliconCount: 0, poolCount: 0,
                        notes: [], refusalReason: reason), bed: "", primersFASTA: "", referenceFASTA: "",
                        sourceArtifactPaths: []))
                }
            }
        }
        return plans
    }

    private static func primalSchemePlan(
        bundle: PrimerAnalysisBundle, result: PrimerAnalysisResult, label: String, bedPath: String,
        referencePath: String, ampliconPath: String?,
        rowMaps: [String: (original: String, inputLabel: String, alignmentPath: String)]
    ) throws -> Plan {
        let references = try parseFASTA(try verifiedText(path: referencePath, in: bundle))
        let bedText = try verifiedText(path: bedPath, in: bundle)
        var primers: [BEDPrimer] = []
        for line in bedText.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let start = Int(fields[1]), let end = Int(fields[2]), start >= 0, end > start,
                  let pool = Int(fields[4]), pool > 0, ["+", "-"].contains(fields[5]),
                  let reference = references.first(where: { $0.name == fields[0] }), end <= reference.sequence.count,
                  !fields[3].isEmpty, isIUPAC(fields[6]) else {
                throw PrimerSchemeFromAnalysisError.invalidAnalysis("The saved PrimalScheme3 primer BED is malformed.")
            }
            primers.append(.init(reference: fields[0], start: start, end: end, name: fields[3], pool: String(pool),
                strand: fields[5], sequence: fields[6].uppercased()))
        }
        guard !primers.isEmpty else {
            throw PrimerSchemeFromAnalysisError.refused("The saved scheme has no primer records.")
        }
        let chromosomes = Array(Set(primers.map(\.reference))).sorted()
        guard chromosomes.count == 1, let chromosome = chromosomes.first,
              let reference = references.first(where: { $0.name == chromosome }) else {
            throw PrimerSchemeFromAnalysisError.refused(
                "This result places primers on \(chromosomes.count) references. A primer scheme bundle names one reference, so save each single-reference result instead.")
        }
        guard let mapped = rowMaps[chromosome] else {
            throw PrimerSchemeFromAnalysisError.refused(
                "The saved analysis has no row map linking the design reference \(chromosome) to its original alignment row.")
        }
        // PrimalScheme3 writes coordinates on the first alignment row without gaps. Confirm the
        // stored reference is exactly that row before letting its name stand for the coordinates.
        let alignmentRows = try parseFASTA(try verifiedText(path: mapped.alignmentPath, in: bundle))
        guard let first = alignmentRows.first(where: { $0.name == chromosome }) else {
            throw PrimerSchemeFromAnalysisError.refused("The design reference \(chromosome) is not a row of the saved alignment.")
        }
        guard first.sequence.filter({ $0 != "-" && $0 != "." }) == reference.sequence else {
            throw PrimerSchemeFromAnalysisError.refused(
                "The saved reference does not match the ungapped first alignment row, so the coordinates cannot be trusted.")
        }
        guard let originalName = mapped.original.split(whereSeparator: \.isWhitespace).first.map(String.init),
              isSafeSequenceName(originalName) else {
            throw PrimerSchemeFromAnalysisError.refused("The original header of the design row is not a usable sequence name.")
        }
        let ampliconCount: Int
        if let ampliconPath {
            let ampliconText = try verifiedText(path: ampliconPath, in: bundle)
            ampliconCount = ampliconText.split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        } else {
            ampliconCount = Set(primers.map { PrimerSchemeImportService.normalizedAmpliconName($0.name) }).count
        }
        let renamed = primers.map { BEDPrimer(reference: originalName, start: $0.start, end: $0.end, name: $0.name,
            pool: $0.pool, strand: $0.strand, sequence: $0.sequence) }
        let statement = "Coordinates are on the first row of the alignment \(mapped.inputLabel), "
            + "\(originalName), without gaps. PrimalScheme3 designed against that row. "
            + "Map reads to that row's sequence (included in this bundle as design-reference.fasta) or to a sequence identical to it."
        let notes = [
            "Numbered variants such as _LEFT_1 and _LEFT_2 are all selected primers of one amplicon and are trimmed together.",
            equivalentAccessionNote(designRowName: chromosome, recordName: originalName),
        ]
        let candidate = PrimerSchemeFromAnalysisCandidate(resultID: result.id, label: label, engine: "PrimalScheme3",
            referenceID: originalName, referenceStatement: statement, primerCount: renamed.count,
            ampliconCount: ampliconCount, poolCount: Set(renamed.map(\.pool)).count, notes: notes, refusalReason: nil,
            equivalentReferenceIDs: [chromosome])
        return Plan(candidate: candidate, bed: bedLines(renamed), primersFASTA: primersFASTA(renamed),
            referenceFASTA: ">\(originalName)\n\(reference.sequence)\n",
            sourceArtifactPaths: [bedPath, referencePath, mapped.alignmentPath] + (ampliconPath.map { [$0] } ?? []))
    }

    /// The sheet note about the name the design run gave the reference row.
    ///
    /// PrimalScheme3 runs rename each alignment row to an internal id such as
    /// `input_9ABC4783C8474BC0A102A9E03A44D2E4_row_0`. That id is kept as an
    /// equivalent accession so reads mapped under it still match, but it means
    /// nothing to a reader, so the note names the record (`LR699574.1`) instead.
    static func equivalentAccessionNote(designRowName: String, recordName: String) -> String {
        if isInternalDesignRowName(designRowName) {
            return "The scheme also accepts reads mapped to \(recordName) under the internal name the design run gave that row."
        }
        return "The equivalent accession \(designRowName) is the name the design run gave \(recordName)."
    }

    /// True for the `input_<32 hex>_row_<n>` names PrimalScheme3 design runs
    /// give alignment rows.
    static func isInternalDesignRowName(_ name: String) -> Bool {
        name.range(of: #"^input_[0-9A-Fa-f]{32}_row_[0-9]+$"#, options: .regularExpression) != nil
    }

    // MARK: Olivar and varVAMP

    private static func normalizedPlans(bundle: PrimerAnalysisBundle, artifact: PrimerAnalysisArtifact) throws -> [Plan] {
        let document: PrimerSchemeResultsDocument
        do {
            document = try JSONDecoder().decode(PrimerSchemeResultsDocument.self,
                from: try verifiedData(path: artifact.relativePath, in: bundle))
            guard document.analysisID == bundle.manifest.analysisID, document.runID == bundle.manifest.runID else {
                throw PrimerSchemeFromAnalysisError.invalidAnalysis("The normalized result belongs to a different analysis.")
            }
            var projections: [String: PrimerBindingProjection] = [:]
            for path in Set(document.results.flatMap { $0.targets.map(\.bindingProjectionPath) }) {
                projections[path] = try JSONDecoder().decode(PrimerBindingProjection.self,
                    from: try verifiedData(path: path, in: bundle))
            }
            try document.validateStored(knownInputIDs: Set(bundle.manifest.inputs.map(\.id)), projections: projections)
        } catch let error as PrimerSchemeFromAnalysisError {
            throw error
        } catch {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis(error.localizedDescription)
        }
        let engine = document.engine == .olivar ? "Olivar" : "varVAMP"
        return try document.results.map { result in
            let label = bundle.manifest.results.first(where: { $0.id == result.id })?.label
                ?? result.targets.first?.label ?? result.id.uuidString
            func refused(_ reason: String) -> Plan {
                Plan(candidate: .init(resultID: result.id, label: label, engine: engine, referenceID: "",
                    referenceStatement: "", primerCount: 0, ampliconCount: 0, poolCount: 0, notes: [],
                    refusalReason: reason), bed: "", primersFASTA: "", referenceFASTA: "", sourceArtifactPaths: [])
            }
            guard document.mode == .tiled else {
                let mode = document.mode == .qpcr ? "qPCR / dPCR primer-and-probe" : "single-amplicon"
                return refused("Primer trimming needs a tiled amplicon scheme. This varVAMP result is a \(mode) design whose reported assays are alternatives, not one tiled scheme.")
            }
            guard result.targets.count == 1, let target = result.targets.first else {
                return refused("This result places primers on \(result.targets.count) references. A primer scheme bundle names one reference, so save each single-reference result instead.")
            }
            guard isSafeSequenceName(target.referenceID) else {
                return refused("The generated reference name \(target.referenceID) is not a usable sequence name.")
            }
            let referenceRecords = try parseFASTA(try verifiedText(path: target.referencePath, in: bundle))
            guard let reference = referenceRecords.first(where: { $0.name == target.referenceID }),
                  reference.sequence.count == target.referenceLength else {
                throw PrimerSchemeFromAnalysisError.invalidAnalysis("The saved generated reference disagrees with the normalized result.")
            }
            let oligosByID = Dictionary(uniqueKeysWithValues: target.oligos.map { ($0.id, $0) })
            var primers: [BEDPrimer] = []
            var probeCount = 0
            let selected = target.assays.filter { $0.status == .selected }
            for assay in selected {
                for memberID in assay.memberIDs {
                    guard let oligo = oligosByID[memberID] else { continue }
                    if oligo.role == .probe { probeCount += 1; continue }
                    guard let pool = oligo.pool ?? assay.pool else {
                        return refused("A selected primer has no native pool, so an ARTIC-style pool column cannot be written.")
                    }
                    primers.append(.init(reference: target.referenceID, start: oligo.start, end: oligo.end,
                        name: oligo.name, pool: pool, strand: oligo.strand.rawValue, sequence: oligo.sequence.uppercased()))
                }
            }
            guard !primers.isEmpty else { return refused("This result has no selected primers.") }
            guard Set(primers.map(\.name)).count == primers.count else {
                return refused("Selected primer names are not unique, so the BED would be ambiguous.")
            }
            let statement: String
            var notes: [String] = []
            if document.engine == .olivar {
                statement = "Coordinates are on Olivar's generated design reference \(target.referenceID), built from the alignment \(target.label). "
                    + "That sequence is not any single input row. Map reads to the included design-reference.fasta before primer trimming."
            } else {
                statement = "Coordinates are on varVAMP's ambiguous consensus \(target.referenceID) of the alignment \(target.label). "
                    + "It contains IUPAC ambiguity codes and is not any single input row. Map reads to the included design-reference.fasta before primer trimming."
                if reference.sequence.contains(where: { !"ACGT".contains($0) }) {
                    notes.append("The consensus contains ambiguity codes. Mappers score them as mismatches at those positions.")
                }
            }
            if probeCount > 0 {
                notes.append("\(probeCount) probe oligos were left out of the BED because trimming applies to primers only.")
            }
            notes.append("Native pools \(Set(primers.map(\.pool)).sorted().joined(separator: ", ")) are kept as the BED pool column.")
            let candidate = PrimerSchemeFromAnalysisCandidate(resultID: result.id, label: label, engine: engine,
                referenceID: target.referenceID, referenceStatement: statement, primerCount: primers.count,
                ampliconCount: selected.count, poolCount: Set(primers.map(\.pool)).count, notes: notes, refusalReason: nil)
            return Plan(candidate: candidate, bed: bedLines(primers), primersFASTA: primersFASTA(primers),
                referenceFASTA: ">\(target.referenceID)\n\(reference.sequence)\n",
                sourceArtifactPaths: [artifact.relativePath, target.referencePath])
        }
    }

    // MARK: - Helpers

    private struct BEDPrimer {
        let reference: String
        let start: Int
        let end: Int
        let name: String
        let pool: String
        let strand: String
        let sequence: String
    }

    private struct FASTARecord { let name: String; let sequence: String }

    private static func bedLines(_ primers: [BEDPrimer]) -> String {
        primers.map { "\($0.reference)\t\($0.start)\t\($0.end)\t\($0.name)\t\($0.pool)\t\($0.strand)\t\($0.sequence)\n" }.joined()
    }

    private static func primersFASTA(_ primers: [BEDPrimer]) -> String {
        primers.map { ">\($0.name)\n\($0.sequence)\n" }.joined()
    }

    private static func parseFASTA(_ text: String) throws -> [FASTARecord] {
        var records: [FASTARecord] = []
        var name: String?
        var sequence = ""
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(">") {
                if let name { records.append(.init(name: name, sequence: sequence)) }
                name = line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
                sequence = ""
            } else {
                guard name != nil else { throw PrimerSchemeFromAnalysisError.invalidAnalysis("A saved FASTA lacks a header.") }
                sequence += line.filter { !$0.isWhitespace }.uppercased()
            }
        }
        if let name { records.append(.init(name: name, sequence: sequence)) }
        guard records.allSatisfy({ !$0.name.isEmpty && !$0.sequence.isEmpty }) else {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis("A saved FASTA has an empty record.")
        }
        return records
    }

    private static func isIUPAC(_ sequence: String) -> Bool {
        !sequence.isEmpty && sequence.utf8.allSatisfy { "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }
    }

    static func isSafeSequenceName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        }
    }

    private static func verifiedData(path: String, in bundle: PrimerAnalysisBundle) throws -> Data {
        guard let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == path }) else {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis("Missing artifact \(path).")
        }
        let data = try Data(contentsOf: bundle.artifactURL(forRelativePath: path))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard UInt64(data.count) == artifact.byteSize, digest == artifact.sha256.lowercased() else {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis("Artifact \(path) failed its integrity check.")
        }
        return data
    }

    private static func verifiedText(path: String, in bundle: PrimerAnalysisBundle) throws -> String {
        guard let text = String(data: try verifiedData(path: path, in: bundle), encoding: .utf8) else {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis("Artifact \(path) is not UTF-8 text.")
        }
        return text
    }

    private static func decode<T: Decodable>(_ type: T.Type, path: String, in bundle: PrimerAnalysisBundle) throws -> T {
        do { return try JSONDecoder().decode(type, from: try verifiedData(path: path, in: bundle)) } catch {
            throw PrimerSchemeFromAnalysisError.invalidAnalysis("Artifact \(path) could not be decoded: \(error.localizedDescription)")
        }
    }
}
