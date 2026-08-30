import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingKnowledgePackError: Error, Equatable, LocalizedError, Sendable {
    case missingBundledPack(String)
    case unknownSourceID(String)
    case duplicateEntityID(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledPack(let name):
            return "Missing bundled AI haplotyping knowledge pack: \(name)."
        case .unknownSourceID(let id):
            return "AI haplotyping knowledge pack references unknown source ID: \(id)."
        case .duplicateEntityID(let id):
            return "AI haplotyping knowledge pack contains duplicate entity ID: \(id)."
        }
    }
}

public struct AIHaplotypingKnowledgePack: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var sources: [AIHaplotypingKnowledgeSource]
    public var populationProfiles: [AIHaplotypingPopulationProfile]
    public var alleleRecords: [AIHaplotypingAlleleRecord]
    public var referenceRecords: [AIHaplotypingReferenceRecord]
    public var haplotypeBlockDefinitions: [AIHaplotypingHaplotypeBlockDefinition]
    public var markerRules: [AIHaplotypingMarkerRule]
    public var analystGuidance: [AIHaplotypingAnalystGuidance]
    public var digest: String

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case sources
        case populationProfiles
        case alleleRecords
        case referenceRecords
        case haplotypeBlockDefinitions
        case markerRules
        case analystGuidance
        case digest
    }

    public init(
        id: String,
        version: String,
        sources: [AIHaplotypingKnowledgeSource],
        populationProfiles: [AIHaplotypingPopulationProfile],
        alleleRecords: [AIHaplotypingAlleleRecord] = [],
        referenceRecords: [AIHaplotypingReferenceRecord] = [],
        haplotypeBlockDefinitions: [AIHaplotypingHaplotypeBlockDefinition],
        markerRules: [AIHaplotypingMarkerRule],
        analystGuidance: [AIHaplotypingAnalystGuidance],
        digest: String? = nil
    ) {
        self.id = id
        self.version = version
        self.sources = sources.sorted { $0.id < $1.id }
        self.populationProfiles = populationProfiles.sorted { $0.id < $1.id }
        self.alleleRecords = alleleRecords.map { $0.normalized() }.sorted { $0.id < $1.id }
        self.referenceRecords = referenceRecords.map { $0.normalized() }.sorted { $0.id < $1.id }
        self.haplotypeBlockDefinitions = haplotypeBlockDefinitions.map { $0.normalized() }.sorted { $0.id < $1.id }
        self.markerRules = markerRules.map { $0.normalized() }.sorted { $0.id < $1.id }
        self.analystGuidance = analystGuidance.map { $0.normalized() }.sorted { $0.id < $1.id }
        self.digest = digest ?? Self.computeDigest(
            id: id,
            version: version,
            sources: self.sources,
            populationProfiles: self.populationProfiles,
            alleleRecords: self.alleleRecords,
            referenceRecords: self.referenceRecords,
            haplotypeBlockDefinitions: self.haplotypeBlockDefinitions,
            markerRules: self.markerRules,
            analystGuidance: self.analystGuidance
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            version: try container.decode(String.self, forKey: .version),
            sources: try container.decode([AIHaplotypingKnowledgeSource].self, forKey: .sources),
            populationProfiles: try container.decode(
                [AIHaplotypingPopulationProfile].self,
                forKey: .populationProfiles
            ),
            alleleRecords: try container.decodeIfPresent(
                [AIHaplotypingAlleleRecord].self,
                forKey: .alleleRecords
            ) ?? [],
            referenceRecords: try container.decodeIfPresent(
                [AIHaplotypingReferenceRecord].self,
                forKey: .referenceRecords
            ) ?? [],
            haplotypeBlockDefinitions: try container.decode(
                [AIHaplotypingHaplotypeBlockDefinition].self,
                forKey: .haplotypeBlockDefinitions
            ),
            markerRules: try container.decode([AIHaplotypingMarkerRule].self, forKey: .markerRules),
            analystGuidance: try container.decode(
                [AIHaplotypingAnalystGuidance].self,
                forKey: .analystGuidance
            ),
            digest: try container.decodeIfPresent(String.self, forKey: .digest)
        )
    }

    public func recomputingDigest() -> AIHaplotypingKnowledgePack {
        AIHaplotypingKnowledgePack(
            id: id,
            version: version,
            sources: sources,
            populationProfiles: populationProfiles,
            alleleRecords: alleleRecords,
            referenceRecords: referenceRecords,
            haplotypeBlockDefinitions: haplotypeBlockDefinitions,
            markerRules: markerRules,
            analystGuidance: analystGuidance
        )
    }

    public func validate() throws {
        let sourceIDs = Set(sources.map(\.id))
        try rejectDuplicateIDs(sources.map(\.id))
        try rejectDuplicateIDs(populationProfiles.map(\.id))
        try rejectDuplicateIDs(alleleRecords.map(\.id))
        try rejectDuplicateIDs(referenceRecords.map(\.id))
        try rejectDuplicateIDs(haplotypeBlockDefinitions.map(\.id))
        try rejectDuplicateIDs(markerRules.map(\.id))
        try rejectDuplicateIDs(analystGuidance.map(\.id))

        for alleleRecord in alleleRecords {
            try validateSourceIDs(alleleRecord.sourceIDs, known: sourceIDs)
        }
        for referenceRecord in referenceRecords {
            try validateSourceIDs(referenceRecord.sourceIDs, known: sourceIDs)
        }
        for definition in haplotypeBlockDefinitions {
            try validateSourceIDs(definition.sourceIDs, known: sourceIDs)
            for marker in definition.definingMarkers {
                try validateSourceIDs(marker.sourceIDs, known: sourceIDs)
            }
        }
        for rule in markerRules {
            try validateSourceIDs(rule.sourceIDs, known: sourceIDs)
        }
        for guidance in analystGuidance {
            try validateSourceIDs(guidance.sourceIDs, known: sourceIDs)
        }
    }

    private func rejectDuplicateIDs(_ ids: [String]) throws {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            throw AIHaplotypingKnowledgePackError.duplicateEntityID(id)
        }
    }

    private func validateSourceIDs(_ ids: [String], known: Set<String>) throws {
        for id in ids where !known.contains(id) {
            throw AIHaplotypingKnowledgePackError.unknownSourceID(id)
        }
    }

    private static func computeDigest(
        id: String,
        version: String,
        sources: [AIHaplotypingKnowledgeSource],
        populationProfiles: [AIHaplotypingPopulationProfile],
        alleleRecords: [AIHaplotypingAlleleRecord],
        referenceRecords: [AIHaplotypingReferenceRecord],
        haplotypeBlockDefinitions: [AIHaplotypingHaplotypeBlockDefinition],
        markerRules: [AIHaplotypingMarkerRule],
        analystGuidance: [AIHaplotypingAnalystGuidance]
    ) -> String {
        AIHaplotypingCanonicalJSON.sha256Digest(of: DigestPayload(
            id: id,
            version: version,
            sources: sources,
            populationProfiles: populationProfiles,
            alleleRecords: alleleRecords,
            referenceRecords: referenceRecords,
            haplotypeBlockDefinitions: haplotypeBlockDefinitions,
            markerRules: markerRules,
            analystGuidance: analystGuidance
        ))
    }

    private struct DigestPayload: Encodable {
        let id: String
        let version: String
        let sources: [AIHaplotypingKnowledgeSource]
        let populationProfiles: [AIHaplotypingPopulationProfile]
        let alleleRecords: [AIHaplotypingAlleleRecord]
        let referenceRecords: [AIHaplotypingReferenceRecord]
        let haplotypeBlockDefinitions: [AIHaplotypingHaplotypeBlockDefinition]
        let markerRules: [AIHaplotypingMarkerRule]
        let analystGuidance: [AIHaplotypingAnalystGuidance]
    }
}

public struct AIHaplotypingAlleleRecord: Codable, Equatable, Sendable {
    public var id: String
    public var officialDesignation: String
    public var accession: String?
    public var haplotypes: [String]
    public var comment: String?
    public var previousName: String?
    public var status: String?
    public var sourceIDs: [String]
    public var locus: String?

    public init(
        id: String,
        officialDesignation: String,
        accession: String?,
        haplotypes: [String],
        comment: String?,
        previousName: String?,
        status: String?,
        sourceIDs: [String],
        locus: String? = nil
    ) {
        self.id = id
        self.officialDesignation = officialDesignation
        self.accession = accession
        self.haplotypes = haplotypes.sorted()
        self.comment = comment
        self.previousName = previousName
        self.status = status
        self.sourceIDs = sourceIDs.sorted()
        self.locus = locus
    }
}

public struct AIHaplotypingReferenceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var primaryName: String
    public var fastaHeader: String
    public var sourceLoci: [String]
    public var haplotypeGroups: [String]
    public var haplotypes: [String]
    public var alleles: [String]
    public var accessions: [String]
    public var length: Int?
    public var evidenceClasses: [String]
    public var maxEvidenceWeight: Double?
    public var evidenceWeightSum: Double?
    public var aliases: [String]
    public var sourceIDs: [String]

    public init(
        id: String,
        primaryName: String,
        fastaHeader: String,
        sourceLoci: [String],
        haplotypeGroups: [String],
        haplotypes: [String],
        alleles: [String],
        accessions: [String],
        length: Int?,
        evidenceClasses: [String],
        maxEvidenceWeight: Double?,
        evidenceWeightSum: Double?,
        aliases: [String],
        sourceIDs: [String]
    ) {
        self.id = id
        self.primaryName = primaryName
        self.fastaHeader = fastaHeader
        self.sourceLoci = sourceLoci
        self.haplotypeGroups = haplotypeGroups
        self.haplotypes = haplotypes
        self.alleles = alleles
        self.accessions = accessions
        self.length = length
        self.evidenceClasses = evidenceClasses
        self.maxEvidenceWeight = maxEvidenceWeight
        self.evidenceWeightSum = evidenceWeightSum
        self.aliases = aliases
        self.sourceIDs = sourceIDs
    }
}

public struct AIHaplotypingKnowledgeSource: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var citation: String
    public var path: String?
    public var notes: String

    public init(id: String, title: String, citation: String, path: String? = nil, notes: String = "") {
        self.id = id
        self.title = title
        self.citation = citation
        self.path = path
        self.notes = notes
    }
}

public struct AIHaplotypingPopulationProfile: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var speciesPrefix: String
    public var speciesName: String
    public var frameworkID: String
    public var haplotypeModel: String
    public var noveltyPrior: String
    public var notes: String

    public init(
        id: String,
        displayName: String,
        speciesPrefix: String,
        speciesName: String,
        frameworkID: String,
        haplotypeModel: String,
        noveltyPrior: String,
        notes: String
    ) {
        self.id = id
        self.displayName = displayName
        self.speciesPrefix = speciesPrefix
        self.speciesName = speciesName
        self.frameworkID = frameworkID
        self.haplotypeModel = haplotypeModel
        self.noveltyPrior = noveltyPrior
        self.notes = notes
    }
}

public struct AIHaplotypingHaplotypeBlockDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var internalID: String
    public var displayLabel: String
    public var reportLabel: String
    public var speciesPrefix: String
    public var populationID: String
    public var frameworkID: String
    public var region: String
    public var assayResolution: String
    public var definitionStatus: String
    public var sourceIDs: [String]
    public var definingMarkers: [AIHaplotypingDefiningMarker]
    public var extendedHaplotype: String?
    public var notes: String

    public init(
        id: String,
        internalID: String,
        displayLabel: String,
        reportLabel: String,
        speciesPrefix: String,
        populationID: String,
        frameworkID: String,
        region: String,
        assayResolution: String,
        definitionStatus: String,
        sourceIDs: [String],
        definingMarkers: [AIHaplotypingDefiningMarker],
        extendedHaplotype: String?,
        notes: String
    ) {
        self.id = id
        self.internalID = internalID
        self.displayLabel = displayLabel
        self.reportLabel = reportLabel
        self.speciesPrefix = speciesPrefix
        self.populationID = populationID
        self.frameworkID = frameworkID
        self.region = region
        self.assayResolution = assayResolution
        self.definitionStatus = definitionStatus
        self.sourceIDs = sourceIDs.sorted()
        self.definingMarkers = definingMarkers.sorted { $0.marker < $1.marker }
        self.extendedHaplotype = extendedHaplotype
        self.notes = notes
    }
}

public struct AIHaplotypingDefiningMarker: Codable, Equatable, Sendable {
    public var marker: String
    public var locus: String
    public var role: String
    public var informativeness: String
    public var resolution: String
    public var sourceIDs: [String]
    public var notes: String

    public init(
        marker: String,
        locus: String,
        role: String,
        informativeness: String,
        resolution: String,
        sourceIDs: [String],
        notes: String = ""
    ) {
        self.marker = marker
        self.locus = locus
        self.role = role
        self.informativeness = informativeness
        self.resolution = resolution
        self.sourceIDs = sourceIDs.sorted()
        self.notes = notes
    }
}

public struct AIHaplotypingMarkerRule: Codable, Equatable, Sendable {
    public var id: String
    public var appliesTo: String
    public var text: String
    public var sourceIDs: [String]

    public init(id: String, appliesTo: String, text: String, sourceIDs: [String]) {
        self.id = id
        self.appliesTo = appliesTo
        self.text = text
        self.sourceIDs = sourceIDs.sorted()
    }
}

public struct AIHaplotypingAnalystGuidance: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var sourceIDs: [String]

    public init(id: String, title: String, text: String, sourceIDs: [String]) {
        self.id = id
        self.title = title
        self.text = text
        self.sourceIDs = sourceIDs.sorted()
    }
}

private extension AIHaplotypingAlleleRecord {
    func normalized() -> AIHaplotypingAlleleRecord {
        let trimmedLocus = locus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mappedLocus = trimmedLocus?.isEmpty == false
            ? GenotypeHaplotypeLocusResolver.haplotypeEvidenceLocusName(trimmedLocus ?? "")
            : GenotypeHaplotypeLocusResolver.haplotypeEvidenceLocusName(officialDesignation)
        return AIHaplotypingAlleleRecord(
            id: id,
            officialDesignation: officialDesignation,
            accession: accession,
            haplotypes: haplotypes,
            comment: comment,
            previousName: previousName,
            status: status,
            sourceIDs: sourceIDs,
            locus: mappedLocus == "Unknown" ? nil : mappedLocus
        )
    }
}

private extension AIHaplotypingReferenceRecord {
    func normalized() -> AIHaplotypingReferenceRecord {
        AIHaplotypingReferenceRecord(
            id: id,
            primaryName: primaryName,
            fastaHeader: fastaHeader,
            sourceLoci: sourceLoci.uniquedAndSorted(),
            haplotypeGroups: haplotypeGroups.uniquedAndSorted(),
            haplotypes: haplotypes.uniquedAndSorted(),
            alleles: alleles.uniquedAndSorted(),
            accessions: accessions.uniquedAndSorted(),
            length: length,
            evidenceClasses: evidenceClasses.uniquedAndSorted(),
            maxEvidenceWeight: maxEvidenceWeight,
            evidenceWeightSum: evidenceWeightSum,
            aliases: aliases.uniquedAndSorted(),
            sourceIDs: sourceIDs.uniquedAndSorted()
        )
    }
}

private extension Array where Element == String {
    func uniquedAndSorted() -> [String] {
        Array(Set(map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

private extension AIHaplotypingHaplotypeBlockDefinition {
    func normalized() -> AIHaplotypingHaplotypeBlockDefinition {
        AIHaplotypingHaplotypeBlockDefinition(
            id: id,
            internalID: internalID,
            displayLabel: displayLabel,
            reportLabel: reportLabel,
            speciesPrefix: speciesPrefix,
            populationID: populationID,
            frameworkID: frameworkID,
            region: region,
            assayResolution: assayResolution,
            definitionStatus: definitionStatus,
            sourceIDs: sourceIDs,
            definingMarkers: definingMarkers.map { $0.normalized() },
            extendedHaplotype: extendedHaplotype,
            notes: notes
        )
    }
}

private extension AIHaplotypingDefiningMarker {
    func normalized() -> AIHaplotypingDefiningMarker {
        AIHaplotypingDefiningMarker(
            marker: marker,
            locus: locus,
            role: role,
            informativeness: informativeness,
            resolution: resolution,
            sourceIDs: sourceIDs,
            notes: notes
        )
    }
}

private extension AIHaplotypingMarkerRule {
    func normalized() -> AIHaplotypingMarkerRule {
        AIHaplotypingMarkerRule(
            id: id,
            appliesTo: appliesTo,
            text: text,
            sourceIDs: sourceIDs
        )
    }
}

private extension AIHaplotypingAnalystGuidance {
    func normalized() -> AIHaplotypingAnalystGuidance {
        AIHaplotypingAnalystGuidance(
            id: id,
            title: title,
            text: text,
            sourceIDs: sourceIDs
        )
    }
}

public enum AIHaplotypingKnowledgePackLoader {
    public static func bundledMacaqueMHC() throws -> AIHaplotypingKnowledgePack {
        try bundledPack(named: "macaque-mhc-v1")
    }

    public static func bundledPack(named name: String) throws -> AIHaplotypingKnowledgePack {
        guard let url = RuntimeResourceLocator.path(
            "AIHaplotyping/\(name).json",
            in: .workflow
        ) else {
            throw AIHaplotypingKnowledgePackError.missingBundledPack(name)
        }
        let decoded = try JSONDecoder().decode(
            AIHaplotypingKnowledgePack.self,
            from: Data(contentsOf: url)
        )
        let recomputed = decoded.recomputingDigest()
        try recomputed.validate()
        return recomputed
    }
}

public extension AIHaplotypingKnowledgePack {
    func canonicalJSONString() -> String {
        String(data: AIHaplotypingCanonicalJSON.canonicalData(of: self), encoding: .utf8) ?? "{}"
    }
}
