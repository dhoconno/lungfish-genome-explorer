import Foundation

public enum AIHaplotypingPromptRegistryError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTemplate(id: String, version: String)
    case missingTemplate(id: String, version: String)
    case missingCurrentTemplate(AIHaplotypingPromptMode)

    public var errorDescription: String? {
        switch self {
        case .duplicateTemplate(let id, let version):
            return "Duplicate AI haplotyping prompt template \(id) version \(version)."
        case .missingTemplate(let id, let version):
            return "Missing AI haplotyping prompt template \(id) version \(version)."
        case .missingCurrentTemplate(let mode):
            return "Missing current AI haplotyping prompt template for \(mode.rawValue)."
        }
    }
}

public struct AIHaplotypingPromptRegistry: Equatable, Sendable {
    public let templates: [AIHaplotypingPromptTemplate]
    public let registryDigest: String

    public init(templates: [AIHaplotypingPromptTemplate]) throws {
        var seen = Set<String>()
        for template in templates {
            let key = Self.key(id: template.id, version: template.version)
            guard seen.insert(key).inserted else {
                throw AIHaplotypingPromptRegistryError.duplicateTemplate(
                    id: template.id,
                    version: template.version
                )
            }
        }

        let sorted = templates.sorted { lhs, rhs in
            if lhs.id != rhs.id {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.version.localizedStandardCompare(rhs.version) == .orderedAscending
        }
        self.templates = sorted
        self.registryDigest = Self.computeRegistryDigest(templates: sorted)
    }

    public static let builtIn: AIHaplotypingPromptRegistry = {
        do {
            return try AIHaplotypingPromptRegistry(templates: [
                .builtInDiscovery,
                .builtInRefinement,
            ])
        } catch {
            preconditionFailure("Invalid built-in AI haplotyping prompt registry: \(error)")
        }
    }()

    public func currentTemplate(for mode: AIHaplotypingPromptMode) throws -> AIHaplotypingPromptTemplate {
        let matchingTemplates = templates.filter { $0.mode == mode }
        guard let template = matchingTemplates.max(by: {
            $0.version.localizedStandardCompare($1.version) == .orderedAscending
        }) else {
            throw AIHaplotypingPromptRegistryError.missingCurrentTemplate(mode)
        }
        return template
    }

    public func template(id: String, version: String) throws -> AIHaplotypingPromptTemplate {
        guard let template = templates.first(where: { $0.id == id && $0.version == version }) else {
            throw AIHaplotypingPromptRegistryError.missingTemplate(id: id, version: version)
        }
        return template
    }

    private static func key(id: String, version: String) -> String {
        "\(id)\u{0}\(version)"
    }

    private static func computeRegistryDigest(templates: [AIHaplotypingPromptTemplate]) -> String {
        AIHaplotypingCanonicalJSON.sha256Digest(of: RegistryPayload(
            templates: templates.map {
                AIHaplotypingPromptTemplate.CanonicalPromptTemplate(
                    id: $0.id,
                    mode: $0.mode.rawValue,
                    version: $0.version,
                    evidenceSchemaVersion: $0.evidenceSchemaVersion,
                    systemPrompt: $0.systemPrompt,
                    userPromptTemplate: $0.userPromptTemplate
                )
            }
        ))
    }

    private struct RegistryPayload: Encodable {
        let templates: [AIHaplotypingPromptTemplate.CanonicalPromptTemplate]
    }
}

public extension AIHaplotypingPromptTemplate {
    static let builtInDiscovery = AIHaplotypingPromptTemplate(
        id: "lungfish.ai-haplotyping.discovery",
        mode: .aiDiscovery,
        version: "2026-06-15.2",
        evidenceSchemaVersion: 1,
        systemPrompt: """
        You are a macaque MHC immunogenetics analyst reconstructing reviewable haplotype calls from genotyping evidence.
        Use the supplied run context, knowledge pack, and evidence records. Cite evidence IDs for every proposed call.
        Preserve familiar report labels when they describe the evidence, but reason internally about population, species, locus neighborhood, and assay resolution.
        Simulate a careful human analyst: weigh marker informativeness, missing data, bleed-through, homozygosity, linked locus neighborhoods, and population history before proposing a call.
        Treat the result as analyst-review input, not as an automatically final scientific conclusion.
        """,
        userPromptTemplate: """
        Review this AI haplotyping prompt input and propose haplotype calls.

        Read the prompt input in this order before assigning calls:
        1. runContext: identify species prefix, population hint, assay resolution, workflow kind, observed regions, and the haplotype framework hint.
        2. knowledgePack.populationProfiles: apply the relevant population novelty prior, but remember haplotypes can overlap across populations and even related macaque species.
        3. knowledgePack.legacyBlockDefinitions: reuse established report labels when the observed markers match an existing definition.
        4. knowledgePack.markerRules and knowledgePack.analystGuidance: use these to decide when evidence is linked, collapsed, missing, low-level bleed-through, or too subtle to define a new haplotype.
        5. evidenceRegistry: cite evidence IDs for every call, ambiguity, retained current call, or novel candidate.

        Apply these domain rules:
        - For MCM, use M1-M7 as the default extended-haplotype framework. These seven ancestral haplotypes extend broadly across the MHC, so new whole-MHC haplotypes are unlikely without coherent multi-region evidence.
        - Use the Karl et al M3 MHC haplotype as an organization landmark: the broad macaque MHC structure has linked class I, DRB, DQ, and DP regions, with DP/DQ linkage especially important for MCM interpretation.
        - In MCM, DP/DQ linkage means DPA/DPB and DQA/DQB discordance is more likely to reflect missing evidence, assay dropout, sample/report artifact, or rare recombination than an ordinary independently inherited DP or DQ haplotype.
        - For Indian rhesus and other complex populations, regional A, B, DRB, DQ, and DP block calls are usually more appropriate than forced whole-MHC labels.
        - Outside MCM, track DPA/DPB/DQA/DQB separately unless the evidence and population framework justify a larger linked block; do not assume simple M1-M7-style whole-MHC inheritance.
        - Treat short amplicon marker groups as collapsed evidence. Labels such as M1M2M3 represent sequence identity in the interrogated exon segment, not necessarily full-length allele identity.
        - Full-length and cDNA variants add resolution, but do not split a familiar report haplotype on a subtle isolated variant alone. A novel B22-like subtype by itself is lower weight than a coherent multi-locus marker pattern.
        - MHC-AG can support nearby MHC-A interpretation when the evidence coheres. MHC-E may be biologically informative, but is not yet a standard report-level haplotype unless the knowledge pack says otherwise.
        - Missing expected markers can still support a call when the remaining marker pattern is strong. Low-read bleed-through can be ignored when much stronger evidence supports a different haplotype.
        - homozygous or apparent single-haplotype loci are valid outcomes when the evidence supports one haplotype twice or one unambiguous haplotype with no credible second-haplotype signal.
        - Assign novel or provisional labels only when the population novelty prior, marker informativeness, and multi-marker coherence support a true new block rather than dropout, bleed-through, assay resolution, or a minor full-length subtype.

        Prompt input JSON:
        {{prompt_input_json}}
        """
    )

    static let builtInRefinement = AIHaplotypingPromptTemplate(
        id: "lungfish.ai-haplotyping.refinement",
        mode: .aiRefinement,
        version: "2026-06-15.2",
        evidenceSchemaVersion: 1,
        systemPrompt: """
        You are a macaque MHC immunogenetics analyst refining existing haplotype calls using supplied review evidence.
        Preserve defensible current calls, identify conflicts with manual review evidence, and cite evidence IDs.
        Use the supplied run context and knowledge pack to separate MCM extended haplotypes from regional haplotype blocks in more complex populations.
        Simulate a careful human analyst: preserve digestible report labels while reasoning internally with richer linked-region and assay-resolution structure.
        Return reviewable refinements rather than untraceable final calls.
        """,
        userPromptTemplate: """
        Refine the current haplotype calls using this AI haplotyping prompt input.

        Read the prompt input in this order before changing calls:
        1. runContext: identify species prefix, population hint, assay resolution, workflow kind, observed regions, and haplotype framework.
        2. knowledgePack.populationProfiles: apply the relevant population novelty prior and avoid assuming that population labels are absolute species boundaries.
        3. knowledgePack.legacyBlockDefinitions: keep legacy report labels when they remain biologically and experimentally correct.
        4. knowledgePack.markerRules and knowledgePack.analystGuidance: distinguish missing expected markers, low-read bleed-through, collapsed amplicon labels, linked DP/DQ evidence, MHC-AG support for MHC-A, and MHC-E context.
        5. evidenceRegistry: cite current-call, manual-review, and observation evidence IDs for every retained, changed, or unresolved slot.

        Apply these domain rules:
        - For MCM, prefer known M1-M7 calls and known recombination or missing-marker explanations before inventing a novel extended haplotype.
        - Use the Karl et al M3 organization as a broad landmark. DP/DQ linkage means MCM DP and DQ discordance needs explicit explanation, not routine independent reassignment.
        - For Indian rhesus and other complex populations, refine regional block labels independently unless linked evidence supports a larger call.
        - Preserve legacy report labels for outputs consumed by transplantation and infectious-disease researchers, but use internal reasoning to note when a label is provisional, collapsed, ambiguous, or supported by linked markers.
        - Full-length and cDNA variants can explain subtle allele differences, but do not split a familiar report-level haplotype solely because of an isolated private or low-impact variant.
        - Treat MHC-AG as possible linked support for MHC-A; treat MHC-E as informative context unless an explicit haplotype framework is supplied.
        - Use current calls, manual reviews, low-count bleed-through, missing expected markers, homozygous evidence, and genuine conflicts as separate evidence classes.

        Prompt input JSON:
        {{prompt_input_json}}
        """
    )
}
