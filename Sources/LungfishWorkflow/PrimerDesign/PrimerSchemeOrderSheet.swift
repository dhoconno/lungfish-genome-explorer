import Foundation
import LungfishIO

/// Engine-neutral order rows derived only from a validated normalized result.
/// Native order files remain separate artifacts and are never rewritten.
public enum PrimerSchemeOrderSheet {
    public static let schemaVersion = 1
    public static let filename = "primer-scheme-ordering-v1.csv"

    public enum Selection: Equatable, Sendable {
        case selectedAssays(Set<UUID>)
        case allAssays
    }

    public struct Row: Codable, Equatable, Identifiable, Sendable {
        public var id: String { oligoID.uuidString.lowercased() + ":" + assayID.uuidString.lowercased() }
        public let resultID: UUID
        public let targetID: UUID
        public let assayID: UUID
        public let oligoID: UUID
        public let name: String
        public let role: PrimerOligoRole
        public let sequence: String
        public let strand: PrimerOligoStrand
        public let status: PrimerAssayStatus
        public let rank: Int?
        public let nativePool: String?
        public let start: Int
        public let end: Int

        public init(resultID: UUID, targetID: UUID, assayID: UUID, oligoID: UUID,
                    name: String, role: PrimerOligoRole, sequence: String,
                    strand: PrimerOligoStrand, status: PrimerAssayStatus, rank: Int?,
                    nativePool: String?, start: Int, end: Int) {
            self.resultID = resultID; self.targetID = targetID; self.assayID = assayID
            self.oligoID = oligoID; self.name = name; self.role = role
            self.sequence = sequence; self.strand = strand; self.status = status
            self.rank = rank; self.nativePool = nativePool
            self.start = start; self.end = end
        }
    }

    public static func rows(
        from document: PrimerSchemeResultsDocument,
        selection: Selection
    ) throws -> [Row] {
        let requested: Set<UUID>
        switch selection {
        case .allAssays:
            requested = Set(document.results.flatMap { $0.targets.flatMap { $0.assays.map(\.id) } })
        case .selectedAssays(let IDs):
            guard !IDs.isEmpty else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "Select at least one explicit assay for ordering export.")
            }
            requested = IDs
        }
        var known = Set<UUID>()
        var output: [Row] = []
        for result in document.results {
            for target in result.targets {
                let oligos = Dictionary(uniqueKeysWithValues: target.oligos.map { ($0.id, $0) })
                for assay in target.assays where requested.contains(assay.id) {
                    known.insert(assay.id)
                    for memberID in assay.memberIDs {
                        guard let oligo = oligos[memberID] else {
                            throw PrimerSchemeDesignError.contractViolation(
                                "An order assay refers to a missing oligo.")
                        }
                        output.append(.init(resultID: result.id, targetID: target.id,
                            assayID: assay.id, oligoID: oligo.id, name: oligo.name,
                            role: oligo.role, sequence: oligo.sequence.uppercased(),
                            strand: oligo.strand, status: assay.status, rank: assay.rank,
                            nativePool: oligo.pool ?? assay.pool, start: oligo.start, end: oligo.end))
                    }
                }
            }
        }
        guard known == requested else {
            throw PrimerSchemeDesignError.invalidRequest(
                "The selected ordering assays do not belong to this saved result.")
        }
        let roleOrder: [PrimerOligoRole: Int] = [.forward: 0, .probe: 1, .reverse: 2]
        return output.sorted {
            if $0.resultID != $1.resultID { return $0.resultID.uuidString < $1.resultID.uuidString }
            if $0.targetID != $1.targetID { return $0.targetID.uuidString < $1.targetID.uuidString }
            if $0.status != $1.status { return $0.status == .selected }
            if $0.rank != $1.rank { return ($0.rank ?? Int.max) < ($1.rank ?? Int.max) }
            if $0.assayID != $1.assayID { return $0.assayID.uuidString < $1.assayID.uuidString }
            return roleOrder[$0.role, default: 3] < roleOrder[$1.role, default: 3]
        }
    }

    public static func csv(rows: [Row]) throws -> Data {
        guard !rows.isEmpty, Set(rows.map(\.id)).count == rows.count else {
            throw PrimerSchemeDesignError.invalidRequest(
                "Order rows must be nonempty and uniquely identify each assay oligo.")
        }
        let header = ["Candidate status", "Candidate rank", "Native pool", "Oligo role",
                      "Oligo name", "Sequence (5′–3′)", "Length (nt)", "Strand",
                      "Start (1-based inclusive)", "End (1-based inclusive)",
                      "Assay ID", "Oligo ID", "Target ID", "Result ID"]
        let records = rows.map {
            [$0.status.rawValue, $0.rank.map(String.init) ?? "", $0.nativePool ?? "Unpooled",
             $0.role.rawValue, $0.name, $0.sequence, String($0.sequence.count),
             $0.strand.rawValue, String($0.start + 1), String($0.end),
             $0.assayID.uuidString.lowercased(), $0.oligoID.uuidString.lowercased(),
             $0.targetID.uuidString.lowercased(), $0.resultID.uuidString.lowercased()]
        }
        return Data(([header] + records).map { $0.map(escaped).joined(separator: ",") }
            .joined(separator: "\r\n").appending("\r\n").utf8)
    }

    /// Canonical resolved settings embedded by the app's provenance writer.
    public static func provenanceOptions(
        rows: [Row], selection: Selection, sourceDocumentPath: String
    ) -> [String: ParameterValue] {
        let assayIDs = Set(rows.map(\.assayID)).sorted { $0.uuidString < $1.uuidString }
        return [
            "schemaVersion": .integer(schemaVersion),
            "sourceNormalizedResult": .string(sourceDocumentPath),
            "scope": .string(selection == .allAssays ? "all-reported-assays" : "selected-assays"),
            "selectedAssayIDs": .array(assayIDs.map { .string($0.uuidString.lowercased()) }),
            "rowCount": .integer(rows.count),
            "sequenceOrientation": .string("saved-5prime-to-3prime"),
            "nativePoolsPreserved": .boolean(true),
            "unpooledRowsRemainUnpooled": .boolean(true),
            "alternativeCandidatesPreserved": .boolean(true),
        ]
    }

    private static func escaped(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
