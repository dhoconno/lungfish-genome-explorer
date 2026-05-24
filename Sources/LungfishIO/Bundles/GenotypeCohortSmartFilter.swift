import Foundation
import LungfishCore

public struct GenotypeCohortSmartFilter: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var scope: String
    public var isStarred: Bool
    public var predicate: SmartCohortPredicate

    public init(name: String, description: String? = nil, scope: String = "bundle",
                isStarred: Bool = false, predicate: SmartCohortPredicate = .all([])) {
        self.name = name
        self.description = description
        self.scope = scope
        self.isStarred = isStarred
        self.predicate = predicate
    }
}

public struct GenotypeCohortSubject: Sendable, Equatable {
    public let animalId: String
    public let gsId: String?
    public let qcStatus: ONTGenotypeQCStatus
    public let totalReads: Int
    public let unmappedPercent: Double
    public let comments: String
    public let metadata: [String: String]
    public let rawGenotypes: [String]
    public let calls: [Call]
    public let hasAnyComment: Bool
    public let hasErrorAtAnyLocus: Bool
    public let isHomozygousAcrossAll: Bool
    public let hasRegionalRecombinant: Bool
    public let hasAtypicalPattern: Bool
    public let statusValue: GenotypeAnnotationSidecar.StatusValue
    public let highlightFills: [String]
    public let highlightBorders: [String]

    public init(animalId: String, gsId: String?, qcStatus: ONTGenotypeQCStatus,
                totalReads: Int, unmappedPercent: Double, comments: String,
                metadata: [String: String] = [:],
                rawGenotypes: [String] = [],
                calls: [Call], hasAnyComment: Bool, hasErrorAtAnyLocus: Bool,
                isHomozygousAcrossAll: Bool, hasRegionalRecombinant: Bool,
                hasAtypicalPattern: Bool,
                statusValue: GenotypeAnnotationSidecar.StatusValue,
                highlightFills: [String], highlightBorders: [String]) {
        self.animalId = animalId
        self.gsId = gsId
        self.qcStatus = qcStatus
        self.totalReads = totalReads
        self.unmappedPercent = unmappedPercent
        self.comments = comments
        self.metadata = metadata
        self.rawGenotypes = rawGenotypes
        self.calls = calls
        self.hasAnyComment = hasAnyComment
        self.hasErrorAtAnyLocus = hasErrorAtAnyLocus
        self.isHomozygousAcrossAll = isHomozygousAcrossAll
        self.hasRegionalRecombinant = hasRegionalRecombinant
        self.hasAtypicalPattern = hasAtypicalPattern
        self.statusValue = statusValue
        self.highlightFills = highlightFills
        self.highlightBorders = highlightBorders
    }

    public struct Call: Sendable, Equatable {
        public let locus: String
        public let slot: HaplotypeSlot
        public let name: String
        public let isHomozygous: Bool
        public let isError: Bool
        public let isRecombinant: Bool
        public let readCount: Int

        public init(locus: String, slot: HaplotypeSlot, name: String,
                    isHomozygous: Bool, isError: Bool, isRecombinant: Bool, readCount: Int) {
            self.locus = locus
            self.slot = slot
            self.name = name
            self.isHomozygous = isHomozygous
            self.isError = isError
            self.isRecombinant = isRecombinant
            self.readCount = readCount
        }
    }
}

public indirect enum SmartCohortPredicate: Codable, Equatable, Sendable {
    case all([SmartCohortPredicate])
    case any([SmartCohortPredicate])
    case not(SmartCohortPredicate)
    case animalIdMatches(String)
    case animalIdIn([String])
    case gsIdMatches(String)
    case commentContains(String)
    case metadataFieldContains(field: String, value: String)
    case textContains(String)
    case hasAnyComment
    case qcStatus(Set<ONTGenotypeQCStatus>)
    case hasErrorAtAnyLocus
    case totalReadsAtLeast(Int)
    case totalReadsAtMost(Int)
    case unmappedPercentAtMost(Double)
    case hasHaplotypeAt(locus: String, slot: HaplotypeSlot?, names: Set<String>)
    case hasErrorAt(locus: String)
    case isHomozygousAt(locus: String)
    case isHomozygousAcrossAll
    case hasRegionalRecombinant
    case hasRegionalRecombinantAt(locus: String)
    case hasAtypicalPattern
    /// Sample carries the named haplotype (exact match) at any locus.
    /// Used by the quick-search syntax `M2A` to find every animal with
    /// the M2A haplotype anywhere across MHC-A/B/DRB/etc.
    case hasHaplotypeAtAnyLocus(name: String)
    /// Sample carries any haplotype whose name starts with `prefix` at
    /// any locus. `M2` matches M2A, M2B, M2DR, M2DQ, M2DP at every
    /// locus — useful for "show me all M2 animals."
    case hasHaplotypePrefixAtAnyLocus(prefix: String)
    /// Sample carries any haplotype whose name starts with `prefix` at
    /// the named locus. `M2@MHC-B` finds animals with M2B, M2Bnov, …
    /// at MHC-B specifically.
    case hasHaplotypePrefixAt(prefix: String, locus: String)
    case hasHighlightFill(String?)
    case hasHighlightBorder(String?)
    case hasAnalystFlag(GenotypeAnnotationSidecar.StatusValue)

    public var visibleTextSearch: String? {
        switch self {
        case .textContains(let text):
            return text
        case .all(let predicates), .any(let predicates):
            return predicates.compactMap(\.visibleTextSearch).first
        case .not(let predicate):
            return predicate.visibleTextSearch
        default:
            return nil
        }
    }

    public func evaluate(_ subject: GenotypeCohortSubject) -> Bool {
        switch self {
        case .all(let predicates):
            return predicates.allSatisfy { $0.evaluate(subject) }
        case .any(let predicates):
            return predicates.contains { $0.evaluate(subject) }
        case .not(let inner):
            return !inner.evaluate(subject)
        case .animalIdMatches(let s):
            return subject.animalId == s
        case .animalIdIn(let ids):
            return ids.contains(subject.animalId)
        case .gsIdMatches(let s):
            return subject.gsId == s
        case .commentContains(let s):
            return subject.comments.localizedCaseInsensitiveContains(s)
        case .metadataFieldContains(let field, let value):
            return subject.metadata.contains { key, metadataValue in
                key.localizedCaseInsensitiveContains(field)
                    && metadataValue.localizedCaseInsensitiveContains(value)
            }
        case .textContains(let s):
            return subject.animalId.localizedCaseInsensitiveContains(s)
                || (subject.gsId?.localizedCaseInsensitiveContains(s) ?? false)
                || subject.comments.localizedCaseInsensitiveContains(s)
                || subject.metadata.contains { key, value in
                    key.localizedCaseInsensitiveContains(s)
                        || value.localizedCaseInsensitiveContains(s)
                }
                || subject.rawGenotypes.contains { $0.localizedCaseInsensitiveContains(s) }
                || subject.calls.contains { call in
                    call.locus.localizedCaseInsensitiveContains(s)
                        || call.name.localizedCaseInsensitiveContains(s)
                }
        case .hasAnyComment:
            return subject.hasAnyComment
        case .qcStatus(let set):
            return set.contains(subject.qcStatus)
        case .hasErrorAtAnyLocus:
            return subject.hasErrorAtAnyLocus
        case .totalReadsAtLeast(let n):
            return subject.totalReads >= n
        case .totalReadsAtMost(let n):
            return subject.totalReads <= n
        case .unmappedPercentAtMost(let p):
            return subject.unmappedPercent <= p
        case .hasHaplotypeAt(let locus, let slot, let names):
            return subject.calls.contains {
                $0.locus == locus &&
                (slot == nil || $0.slot == slot) &&
                names.contains($0.name)
            }
        case .hasErrorAt(let locus):
            return subject.calls.contains { $0.locus == locus && $0.isError }
        case .isHomozygousAt(let locus):
            // The subject carries per-slot calls; the locus is homozygous
            // when both slots are present and share the same call name.
            let locusCalls = subject.calls.filter { $0.locus == locus }
            guard locusCalls.count >= 2 else { return false }
            let names = Set(locusCalls.map(\.name))
            return names.count == 1
        case .isHomozygousAcrossAll:
            return subject.isHomozygousAcrossAll
        case .hasRegionalRecombinant:
            return subject.hasRegionalRecombinant
        case .hasRegionalRecombinantAt(let locus):
            return subject.calls.contains { $0.locus == locus && $0.isRecombinant }
        case .hasAtypicalPattern:
            return subject.hasAtypicalPattern
        case .hasHighlightFill(let hex):
            if let hex = hex { return subject.highlightFills.contains(hex) }
            return !subject.highlightFills.isEmpty
        case .hasHighlightBorder(let hex):
            if let hex = hex { return subject.highlightBorders.contains(hex) }
            return !subject.highlightBorders.isEmpty
        case .hasAnalystFlag(let value):
            return subject.statusValue == value
        case .hasHaplotypeAtAnyLocus(let name):
            return subject.calls.contains { $0.name == name }
        case .hasHaplotypePrefixAtAnyLocus(let prefix):
            return subject.calls.contains { $0.name.hasPrefix(prefix) }
        case .hasHaplotypePrefixAt(let prefix, let locus):
            return subject.calls.contains { $0.locus == locus && $0.name.hasPrefix(prefix) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, children, child, value, field, locus, slot, names, hex, ids, set, prefix
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all(let children):
            try container.encode("all", forKey: .kind)
            try container.encode(children, forKey: .children)
        case .any(let children):
            try container.encode("any", forKey: .kind)
            try container.encode(children, forKey: .children)
        case .not(let child):
            try container.encode("not", forKey: .kind)
            try container.encode(child, forKey: .child)
        case .animalIdMatches(let s):
            try container.encode("animalIdMatches", forKey: .kind)
            try container.encode(s, forKey: .value)
        case .animalIdIn(let ids):
            try container.encode("animalIdIn", forKey: .kind)
            try container.encode(ids, forKey: .ids)
        case .gsIdMatches(let s):
            try container.encode("gsIdMatches", forKey: .kind)
            try container.encode(s, forKey: .value)
        case .commentContains(let s):
            try container.encode("commentContains", forKey: .kind)
            try container.encode(s, forKey: .value)
        case .metadataFieldContains(let field, let value):
            try container.encode("metadataFieldContains", forKey: .kind)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
        case .textContains(let s):
            try container.encode("textContains", forKey: .kind)
            try container.encode(s, forKey: .value)
        case .hasAnyComment:
            try container.encode("hasAnyComment", forKey: .kind)
        case .qcStatus(let set):
            try container.encode("qcStatus", forKey: .kind)
            try container.encode(Array(set).map { $0.rawValue }.sorted(), forKey: .set)
        case .hasErrorAtAnyLocus:
            try container.encode("hasErrorAtAnyLocus", forKey: .kind)
        case .totalReadsAtLeast(let n):
            try container.encode("totalReadsAtLeast", forKey: .kind)
            try container.encode(n, forKey: .value)
        case .totalReadsAtMost(let n):
            try container.encode("totalReadsAtMost", forKey: .kind)
            try container.encode(n, forKey: .value)
        case .unmappedPercentAtMost(let p):
            try container.encode("unmappedPercentAtMost", forKey: .kind)
            try container.encode(p, forKey: .value)
        case .hasHaplotypeAt(let locus, let slot, let names):
            try container.encode("hasHaplotypeAt", forKey: .kind)
            try container.encode(locus, forKey: .locus)
            try container.encodeIfPresent(slot, forKey: .slot)
            try container.encode(Array(names).sorted(), forKey: .names)
        case .hasErrorAt(let locus):
            try container.encode("hasErrorAt", forKey: .kind)
            try container.encode(locus, forKey: .locus)
        case .isHomozygousAt(let locus):
            try container.encode("isHomozygousAt", forKey: .kind)
            try container.encode(locus, forKey: .locus)
        case .isHomozygousAcrossAll:
            try container.encode("isHomozygousAcrossAll", forKey: .kind)
        case .hasRegionalRecombinant:
            try container.encode("hasRegionalRecombinant", forKey: .kind)
        case .hasRegionalRecombinantAt(let locus):
            try container.encode("hasRegionalRecombinantAt", forKey: .kind)
            try container.encode(locus, forKey: .locus)
        case .hasAtypicalPattern:
            try container.encode("hasAtypicalPattern", forKey: .kind)
        case .hasHighlightFill(let hex):
            try container.encode("hasHighlightFill", forKey: .kind)
            try container.encodeIfPresent(hex, forKey: .hex)
        case .hasHighlightBorder(let hex):
            try container.encode("hasHighlightBorder", forKey: .kind)
            try container.encodeIfPresent(hex, forKey: .hex)
        case .hasAnalystFlag(let v):
            try container.encode("hasAnalystFlag", forKey: .kind)
            try container.encode(v.rawValue, forKey: .value)
        case .hasHaplotypeAtAnyLocus(let name):
            try container.encode("hasHaplotypeAtAnyLocus", forKey: .kind)
            try container.encode(name, forKey: .value)
        case .hasHaplotypePrefixAtAnyLocus(let prefix):
            try container.encode("hasHaplotypePrefixAtAnyLocus", forKey: .kind)
            try container.encode(prefix, forKey: .prefix)
        case .hasHaplotypePrefixAt(let prefix, let locus):
            try container.encode("hasHaplotypePrefixAt", forKey: .kind)
            try container.encode(prefix, forKey: .prefix)
            try container.encode(locus, forKey: .locus)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "all":
            self = .all(try container.decode([SmartCohortPredicate].self, forKey: .children))
        case "any":
            self = .any(try container.decode([SmartCohortPredicate].self, forKey: .children))
        case "not":
            self = .not(try container.decode(SmartCohortPredicate.self, forKey: .child))
        case "animalIdMatches":
            self = .animalIdMatches(try container.decode(String.self, forKey: .value))
        case "animalIdIn":
            self = .animalIdIn(try container.decode([String].self, forKey: .ids))
        case "gsIdMatches":
            self = .gsIdMatches(try container.decode(String.self, forKey: .value))
        case "commentContains":
            self = .commentContains(try container.decode(String.self, forKey: .value))
        case "metadataFieldContains":
            self = .metadataFieldContains(
                field: try container.decode(String.self, forKey: .field),
                value: try container.decode(String.self, forKey: .value)
            )
        case "textContains":
            self = .textContains(try container.decode(String.self, forKey: .value))
        case "hasAnyComment":
            self = .hasAnyComment
        case "qcStatus":
            let rawValues = try container.decode([String].self, forKey: .set)
            let statuses = rawValues.compactMap { ONTGenotypeQCStatus(rawValue: $0) }
            self = .qcStatus(Set(statuses))
        case "hasErrorAtAnyLocus":
            self = .hasErrorAtAnyLocus
        case "totalReadsAtLeast":
            self = .totalReadsAtLeast(try container.decode(Int.self, forKey: .value))
        case "totalReadsAtMost":
            self = .totalReadsAtMost(try container.decode(Int.self, forKey: .value))
        case "unmappedPercentAtMost":
            self = .unmappedPercentAtMost(try container.decode(Double.self, forKey: .value))
        case "hasHaplotypeAt":
            let locus = try container.decode(String.self, forKey: .locus)
            let slot = try container.decodeIfPresent(HaplotypeSlot.self, forKey: .slot)
            let names = try container.decode([String].self, forKey: .names)
            self = .hasHaplotypeAt(locus: locus, slot: slot, names: Set(names))
        case "hasErrorAt":
            self = .hasErrorAt(locus: try container.decode(String.self, forKey: .locus))
        case "isHomozygousAt":
            self = .isHomozygousAt(locus: try container.decode(String.self, forKey: .locus))
        case "isHomozygousAcrossAll":
            self = .isHomozygousAcrossAll
        case "hasRegionalRecombinant":
            self = .hasRegionalRecombinant
        case "hasRegionalRecombinantAt":
            self = .hasRegionalRecombinantAt(locus: try container.decode(String.self, forKey: .locus))
        case "hasAtypicalPattern":
            self = .hasAtypicalPattern
        case "hasHighlightFill":
            self = .hasHighlightFill(try container.decodeIfPresent(String.self, forKey: .hex))
        case "hasHighlightBorder":
            self = .hasHighlightBorder(try container.decodeIfPresent(String.self, forKey: .hex))
        case "hasAnalystFlag":
            let raw = try container.decode(String.self, forKey: .value)
            guard let value = GenotypeAnnotationSidecar.StatusValue(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container,
                                                       debugDescription: "Unknown StatusValue: \(raw)")
            }
            self = .hasAnalystFlag(value)
        case "hasHaplotypeAtAnyLocus":
            self = .hasHaplotypeAtAnyLocus(name: try container.decode(String.self, forKey: .value))
        case "hasHaplotypePrefixAtAnyLocus":
            self = .hasHaplotypePrefixAtAnyLocus(prefix: try container.decode(String.self, forKey: .prefix))
        case "hasHaplotypePrefixAt":
            self = .hasHaplotypePrefixAt(
                prefix: try container.decode(String.self, forKey: .prefix),
                locus: try container.decode(String.self, forKey: .locus)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "Unknown predicate kind: \(kind)")
        }
    }
}
