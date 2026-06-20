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
                .mcmMHCmiseqSpecialistDiscovery,
                .mcmMHCmiseqSpecialistRefinement,
            ])
        } catch {
            preconditionFailure("Invalid built-in AI haplotyping prompt registry: \(error)")
        }
    }()

    public func currentTemplate(for mode: AIHaplotypingPromptMode) throws -> AIHaplotypingPromptTemplate {
        let matchingTemplates = templates.filter { $0.mode == mode && $0.isDefaultCandidate }
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
                    userPromptTemplate: $0.userPromptTemplate,
                    isDefaultCandidate: $0.isDefaultCandidate
                )
            }
        ))
    }

    private struct RegistryPayload: Encodable {
        let templates: [AIHaplotypingPromptTemplate.CanonicalPromptTemplate]
    }
}

public extension AIHaplotypingPromptTemplate {
    static let mcmMHCmiseqSpecialistDiscovery: AIHaplotypingPromptTemplate = {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        return AIHaplotypingPromptTemplate(
            id: preset.aiPromptTemplateID(for: .aiDiscovery),
            mode: .aiDiscovery,
            version: preset.aiPromptTemplateVersion,
            evidenceSchemaVersion: 1,
            systemPrompt: """
            You are the bundled MCM MHC miSeq haplotyping specialist for Lungfish Genome Explorer.
            Use the supplied specialist prompt as the authoritative haplotyping rule set for this locked MCM miSeq reference.
            Do not use or request a separate knowledge pack. Cite evidence IDs from the supplied evidence registry for every proposed call.
            Treat the result as analyst-review input, not as an automatically final scientific conclusion.
            """,
            userPromptTemplate: Self.mcmSpecialistUserPromptTemplate(mode: .aiDiscovery),
            isDefaultCandidate: false
        )
    }()

    static let mcmMHCmiseqSpecialistRefinement: AIHaplotypingPromptTemplate = {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        return AIHaplotypingPromptTemplate(
            id: preset.aiPromptTemplateID(for: .aiRefinement),
            mode: .aiRefinement,
            version: preset.aiPromptTemplateVersion,
            evidenceSchemaVersion: 1,
            systemPrompt: """
            You are the bundled MCM MHC miSeq haplotyping specialist for Lungfish Genome Explorer.
            Use the supplied specialist prompt as the authoritative haplotyping rule set for this locked MCM miSeq reference.
            Do not use or request a separate knowledge pack. Cite evidence IDs from the supplied evidence registry for every retained, changed, unresolved, or proposed call.
            Treat the result as analyst-review input, not as an automatically final scientific conclusion.
            """,
            userPromptTemplate: Self.mcmSpecialistUserPromptTemplate(mode: .aiRefinement),
            isDefaultCandidate: false
        )
    }()

    private static func mcmSpecialistUserPromptTemplate(mode: AIHaplotypingPromptMode) -> String {
        let promptMarkdown: String
        do {
            promptMarkdown = try MCMHaplotypingPreset.mcmMHCmiseq.bundledSpecialistPromptMarkdown()
        } catch {
            preconditionFailure("Missing bundled MCM specialist prompt: \(error)")
        }
        let action = mode == .aiRefinement
            ? "Refine current MCM MHC miSeq haplotype calls using this specialist prompt and the runtime evidence."
            : "Review the runtime evidence and propose MCM MHC miSeq haplotype calls using this specialist prompt."
        return """
        \(action)

        Specialist prompt:
        \(promptMarkdown)

        Silent decision checklist:
        - Before choosing h1/h2 for a locus, internally enumerate credible M-family evidence from primary alleles, secondary alleles, read support, and linked-locus context.
        - Apply the overcall guard before choosing best-two haplotypes. If more than two M-family haplotypes have credible nontrivial support at a locus or across the sample, do not force a best-two call; output "?" for affected slots.
        - For MHC-A, apply the overcall guard before choosing the best two haplotypes. Secondary MHC-A-region evidence can make M2/M3/M4 or other multi-family patterns unresolved even when two primary branches are present.
        - For MHC-E, prioritize direct MHC-E evidence over adjacency. Call unique MHC-E targets and shared-marker intersections when present; use adjacency only to resolve incomplete MHC-E evidence and do not erase direct MHC-E calls because adjacent loci are discordant.
        - Keep H1/H2 labels internally consistent across neighboring loci when evidence allows, but never use slot consistency to override direct defining evidence or an overcall-human-curation trigger.
        - After the checklist, return only the minimal JSON object described below.

        Output JSON contract:
        - Return only the minimal haplotype calls JSON required by the schema.
        - Do not include rationale, evidence IDs, run metadata, comments, warnings, prose, markdown, or discovered definitions.
        - Emit one calls[] row for every sample/locus pair that should appear in the haplotype table.
        - For every sample in this chunk, emit exactly one row for each of these six loci: MHC-A, MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP.
        - Each row must use evidenceRegistry.samples[].sample exactly as sample and one of the six report loci exactly as locus.
        - Put the H1 and H2 haplotype labels in h1 and h2. Use concise labels only, such as M4A, M5A, M4/M5A, M7A-provisional, ?, or -.
        - If a locus or slot is unresolved, put "?" or "-" in h1/h2 rather than explaining.
        - If evidence supports an unrealistic number of haplotypes at a locus or across a sample, do not force calls. Set the affected h1/h2 values to "?" or "-" as appropriate.
        - Do not emit MHC-I, MHC-L, MHC-AG, MHC-G, MHC-S, or MHC-V as report-level loci.

        Prompt input JSON:
        {{prompt_input_json}}
        """
    }

    static let builtInDiscovery = AIHaplotypingPromptTemplate(
        id: "lungfish.ai-haplotyping.discovery",
        mode: .aiDiscovery,
        version: "2026-06-18.3",
        evidenceSchemaVersion: 1,
        systemPrompt: """
        You are a macaque MHC immunogenetics analyst reconstructing reviewable haplotype calls from genotyping evidence.
        Use the supplied run context, knowledge pack, and evidence records. Cite evidence IDs for every proposed call.
        Preserve familiar report labels when they describe the evidence, but reason internally about population, species, locus-map neighborhood, and assay resolution.
        Simulate a careful human analyst: weigh marker informativeness, missing data, bleed-through, homozygosity, linked locus neighborhoods, and population history before proposing a call.
        Treat the result as analyst-review input, not as an automatically final scientific conclusion.
        """,
        userPromptTemplate: """
        Review this AI haplotyping prompt input and propose haplotype calls.

        Read the prompt input in this order before assigning calls:
        1. runContext: identify species prefix, population hint, assay resolution, workflow kind, observed regions, and the haplotype framework hint.
        2. knowledgePack.populationProfiles: apply the relevant population novelty prior, but remember haplotypes can overlap across populations and even related macaque species.
        3. knowledgePack.haplotypeBlockDefinitions: reuse established report labels when the observed markers match an existing definition.
        4. knowledgePack.markerRules and knowledgePack.analystGuidance: use these to decide when evidence is linked, collapsed, missing, low-level bleed-through, or too subtle to define a new haplotype.
        5. evidenceRegistry: cite evidence IDs for every call, ambiguity, retained current call, or novel candidate.

        Apply these domain rules:
        - For MCM, use M1-M7 as the default extended-haplotype framework. These seven ancestral haplotypes extend broadly across the MHC, so new whole-MHC haplotypes are unlikely without coherent multi-region evidence.
        - Apply the locus map before interpreting labels: treat AG and G evidence as MHC-A haplotype evidence, and treat I, J, K, S, and V evidence as MHC-B haplotype evidence. Treat MHC-E as its own neighboring evidence context. MHC-L and Mafa-L* evidence lie between MHC-A and MHC-E and must remain interstitial neighborhood evidence, not folded into MHC-A or MHC-E and not emitted as its own report locus.
        - Do not emit MHC-I, MHC-L, MHC-AG, MHC-G, MHC-S, or MHC-V as report-level call loci or discovered-definition loci. Use MHC-L only as contextual support for nearby MHC-A/MHC-E interpretation when helpful. Use the evidenceRegistry ID exactly when citing observations.
        - Use the Karl et al M3 MHC haplotype as an organization landmark: the broad macaque MHC structure has linked class I, DRB, DQ, and DP regions, with DP/DQ linkage especially important for MCM interpretation.
        - In MCM, DP/DQ linkage means DPA/DPB and DQA/DQB discordance is more likely to reflect missing evidence, assay dropout, sample/report artifact, or rare recombination than an ordinary independently inherited DP or DQ haplotype.
        - For MCM, use a strong intact-extended-haplotype prior across MHC-A, MHC-B, MHC-DRB, MHC-DQ, and MHC-DP. If most loci support the same extended family, keep that extended haplotype intact on one slot unless multi-locus counterevidence supports recombination.
        - H1/H2 slot names are local report positions, not biological names. Prefer slot assignments that keep the same MCM family together across loci; the two slots may be swapped consistently across the sample if that preserves an intact extended haplotype.
        - Do not split a coherent MCM family such as M1 between H1 and H2 because one or two loci are missing, weak, collapsed, or locally ambiguous. Treat those cases as dropout, collapsed evidence, or unresolved review unless there is coherent linked evidence for recombination.
        - For MHC-A, prioritize Mafa-A1* evidence when assigning MCM A-region haplotypes, except that Mafa-A1*063 is shared by M1, M2, and M3 in the miSeq amplicon and must be resolved with other MHC-A-neighborhood markers before distinguishing those families.
        - For MHC-B, prioritize ordinary Mafa-B* markers over Mafa-B22* or equivalent B22-like markers when discriminating MCM haplotypes, because multiple B-region alleles can be present on each extended haplotype and B22-like evidence alone is lower weight.
        - For MHC-DP and MHC-DQ, when DP-only or DQ-only sequence evidence cannot distinguish between MCM haplotypes, lean on the adjacent DP or DQ locus as linked class II support before proposing a recombinant or unresolved class-II call.
        - For MHC-DP, a retained shared DP marker is still direct DP evidence. If A/B/DR/DQ context chooses one member of that shared marker, report that member as the second DP family instead of "-" unless there is contradictory DP evidence.
        - For MHC-DP, never substitute a linked-only DP family for a family with direct DPB or DPA evidence; linked evidence can resolve ambiguity, but it cannot erase direct DP evidence.
        - For MHC-DP, if unique evidence supports one family and a separate shared DP marker excludes that unique family, do not collapse to the unique-family homozygote. Use A/B/DR/DQ context to choose which member of the shared marker is the second DP family.
        - For MHC-DQ or MHC-DP markers shared between M2 and M6, use A/B block context plus adjacent DP/DQ linked support to choose M2 versus M6 rather than automatically collapsing to the unambiguous partner.
        - For every MHC-B review, explicitly scan markerKnowledgeEvidence source=dropped and familyEvidence.dropped_unique_count before deciding homozygous.
        - For MHC-B, low-level dropped unique/high-informativeness references from one family outrank retained shared-only families with no unique or dropped support. Choose the family with the coherent unique/dropped signal as the secondary call.
        - For Indian rhesus and other complex populations, regional A, B, DRB, DQ, and DP block calls are usually more appropriate than forced whole-MHC labels.
        - Outside MCM, track DPA/DPB/DQA/DQB separately unless the evidence and population framework justify a larger linked block; do not assume simple M1-M7-style whole-MHC inheritance.
        - Treat short amplicon marker groups as collapsed evidence. Labels such as M1M2M3 represent sequence identity in the interrogated exon segment, not necessarily full-length allele identity.
        - Full-length and cDNA variants add resolution, but do not split a familiar report haplotype on a subtle isolated variant alone. A novel B22-like subtype by itself is lower weight than a coherent multi-locus marker pattern.
        - MHC-AG can support nearby MHC-A interpretation when the evidence coheres. MHC-E may be biologically informative, but is not yet a standard report-level haplotype unless the knowledge pack says otherwise.
        - Missing expected markers can still support a call when the remaining marker pattern is strong. Low-read bleed-through can be ignored when much stronger evidence supports a different haplotype.
        - homozygous or apparent single-haplotype loci are valid outcomes when the evidence supports one haplotype twice or one unambiguous haplotype with no credible second-haplotype signal.
        - Assign novel or provisional labels only when the population novelty prior, marker informativeness, and multi-marker coherence support a true new block rather than dropout, bleed-through, assay resolution, or a minor full-length subtype.

        Output JSON contract:
        - schemaVersion must be the integer 1. Do not write true, false, "1", or any other value for schemaVersion.
        - Copy expectedRun exactly into run, including generationParameters, promptHash, registryDigest, and inputSnapshotDigest.
        - Copy chunkID, registryDigest, and inputSnapshotDigest exactly from the prompt input to the top-level output fields.
        - Use only evidence IDs that appear in evidenceRegistry.evidenceIDs for supportEvidenceRefs and counterevidenceRefs. Never put knowledge-pack, reference, marker, allele, or literature IDs such as reference:* in evidence reference arrays; discuss those only in rationale prose when relevant.
        - Do not shorten evidence IDs at pipe (`|`), comma, or colon delimiters; copy the entire evidenceRegistry ID exactly when citing support or counterevidence.
        - Do not rewrite collapsed marker tokens such as M1M4 as M1, M4, or another component haplotype token. Copy the full observed genotype text inside each evidence ID exactly.
        - For each call, sample must use evidenceRegistry.samples[].sample and locus must use evidenceRegistry.loci[].locus; reserve sample:, locus:, obs:, current:, and manual: IDs for evidence reference arrays.
        - For each call, patchOpID must be non-empty and unique within the chunk. Use a stable format such as patch:<chunkID>:<sample>:<locus>:<slot>:v1.
        - For each call, counterevidenceRefs must contain at least one relevant allowed evidence ID. If there is no direct contradictory observation, cite the corresponding sample or locus evidence ID as reviewed context.
        - haplotypeLabel, alternates, and proposedLabel must be concise labels only, such as M4A, M5A, M4/M5A, M7A-provisional, or "-". Do not put parenthetical explanations or prose in label fields.
        - Put homozygous, dominant, dropout, ambiguity, and uncertainty language only in rationale or rationaleCode, never in haplotypeLabel, alternates, normalizedFamily, proposedLabel, or warnings.
        - If you assign the same haplotypeLabel to both h1 and h2 for a sample/locus, at least one of those calls must explicitly say homozygous or single haplotype in rationaleCode or rationale.
        - Use conflictsCurrent only when the proposed haplotypeLabel differs from a callable current call. When changing a callable current call, set callState to conflictsCurrent, cite the current call as counterevidence, and explain in rationale why observation evidence conflicts with or supersedes the current call. If the proposed label agrees with current evidence, use retainCurrent or called; do not mark conflictsCurrent.
        - Do not mention clinical decisions or clinical interpretation. Do not recommend follow-up, confirmation, downstream testing, or experimental action; if evidence remains ambiguous, set callState to unresolved and state the evidence limit concisely.
        - Do not use phase or phasing language for short-amplicon evidence. Say linked marker support, coherent marker pattern, or heterozygous configuration instead.
        - Do not mention copy number, inheritance, or inherited status in labels, rationale, warnings, or follow-up suggestions. For unresolved assay-resolution questions, set callState to unresolved and state that the supplied evidence does not distinguish the alternatives.
        - Do not use the literal substrings phase, phasing, copy number, inherited, inheritance, clinical, confirmation, or follow-up anywhere in output text; the validator rejects several of these terms. Prefer linked marker support, coherent marker pattern, assay-resolution limit, or unresolved review.
        - Do not emit discoveredDefinitions for known curated labels from knowledgePack.haplotypeBlockDefinitions, such as M1A-M7A, M1B-M7B, M1DR-M7DR, M1DQ-M7DQ, or M1DP-M7DP. Use calls for those labels.
        - discoveredDefinitions are only for genuinely novel or provisional labels not already defined in the knowledge pack; each proposedLabel should appear at most once per chunk.

        Prompt input JSON:
        {{prompt_input_json}}
        """
    )

    static let builtInRefinement = AIHaplotypingPromptTemplate(
        id: "lungfish.ai-haplotyping.refinement",
        mode: .aiRefinement,
        version: "2026-06-18.3",
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
        3. knowledgePack.haplotypeBlockDefinitions: keep curated report labels when they remain biologically and experimentally correct.
        4. knowledgePack.markerRules and knowledgePack.analystGuidance: distinguish missing expected markers, low-read bleed-through, collapsed amplicon labels, linked DP/DQ evidence, MHC-AG support for MHC-A, and MHC-E context.
        5. evidenceRegistry: cite current-call, manual-review, and observation evidence IDs for every retained, changed, or unresolved slot.

        Apply these domain rules:
        - The ruleDraft or current deterministic call is advisory. If an unresolved or no-haplotype current call still has evidence, perform a focused human-style review of the supplied sample/locus evidence rather than treating the current no-call as evidence.
        - For MCM, prefer known M1-M7 calls and known recombination or missing-marker explanations before inventing a novel extended haplotype.
        - Apply the locus map before interpreting labels: treat AG and G evidence as MHC-A haplotype evidence, and treat I, J, K, S, and V evidence as MHC-B haplotype evidence. Treat MHC-E as its own neighboring evidence context. MHC-L and Mafa-L* evidence lie between MHC-A and MHC-E and must remain interstitial neighborhood evidence, not folded into MHC-A or MHC-E and not emitted as its own report locus.
        - Do not emit MHC-I, MHC-L, MHC-AG, MHC-G, MHC-S, or MHC-V as report-level call loci or discovered-definition loci. Use MHC-L only as contextual support for nearby MHC-A/MHC-E interpretation when helpful. Use the evidenceRegistry ID exactly when citing observations.
        - Use the Karl et al M3 organization as a broad landmark. DP/DQ linkage means MCM DP and DQ discordance needs explicit explanation, not routine independent reassignment.
        - For MCM, use a strong intact-extended-haplotype prior across MHC-A, MHC-B, MHC-DRB, MHC-DQ, and MHC-DP. If most loci support the same extended family, keep that extended haplotype intact on one slot unless multi-locus counterevidence supports recombination.
        - H1/H2 slot names are local report positions, not biological names. Prefer slot assignments that keep the same MCM family together across loci; the two slots may be swapped consistently across the sample if that preserves an intact extended haplotype.
        - Do not split a coherent MCM family such as M1 between H1 and H2 because one or two loci are missing, weak, collapsed, or locally ambiguous. Treat those cases as dropout, collapsed evidence, or unresolved review unless there is coherent linked evidence for recombination.
        - For MHC-A, prioritize Mafa-A1* evidence when assigning MCM A-region haplotypes, except that Mafa-A1*063 is shared by M1, M2, and M3 in the miSeq amplicon and must be resolved with other MHC-A-neighborhood markers before distinguishing those families.
        - For MHC-B, prioritize ordinary Mafa-B* markers over Mafa-B22* or equivalent B22-like markers when discriminating MCM haplotypes, because multiple B-region alleles can be present on each extended haplotype and B22-like evidence alone is lower weight.
        - For MHC-DP and MHC-DQ, when DP-only or DQ-only sequence evidence cannot distinguish between MCM haplotypes, lean on the adjacent DP or DQ locus as linked class II support before proposing a recombinant or unresolved class-II call.
        - For MHC-DP, a retained shared DP marker is still direct DP evidence. If A/B/DR context chooses one member of that shared marker, report that member as the second DP family instead of "-" unless there is contradictory DP evidence.
        - For MHC-DP, never substitute a linked-only DP family for a family with direct DPB or DPA evidence; linked evidence can resolve ambiguity, but it cannot erase direct DP evidence.
        - For MHC-DP, if unique evidence supports one family and a separate shared DP marker excludes that unique family, do not collapse to the unique-family homozygote. Use A/B/DR/DQ context to choose which member of the shared marker is the second DP family.
        - For MHC-DQ or MHC-DP markers shared between M2 and M6, use A/B block context plus adjacent DP/DQ linked support to choose M2 versus M6 rather than automatically collapsing to the unambiguous partner.
        - For every MHC-B review, explicitly scan markerKnowledgeEvidence source=dropped and familyEvidence.dropped_unique_count before deciding homozygous.
        - For MHC-B, low-level dropped unique/high-informativeness references from one family outrank retained shared-only families with no unique or dropped support. Choose the family with the coherent unique/dropped signal as the secondary call.
        - For Indian rhesus and other complex populations, refine regional block labels independently unless linked evidence supports a larger call.
        - Preserve curated report labels for downstream research and report users, but use internal reasoning to note when a label is provisional, collapsed, ambiguous, or supported by linked markers.
        - Full-length and cDNA variants can explain subtle allele differences, but do not split a familiar report-level haplotype solely because of an isolated private or low-impact variant.
        - Treat MHC-AG as possible linked support for MHC-A; treat MHC-E as informative context unless an explicit haplotype framework is supplied.
        - Use current calls, manual reviews, low-count bleed-through, missing expected markers, homozygous evidence, and genuine conflicts as separate evidence classes.

        Output JSON contract:
        - schemaVersion must be the integer 1. Do not write true, false, "1", or any other value for schemaVersion.
        - Copy expectedRun exactly into run, including generationParameters, promptHash, registryDigest, and inputSnapshotDigest.
        - Copy chunkID, registryDigest, and inputSnapshotDigest exactly from the prompt input to the top-level output fields.
        - Use only evidence IDs that appear in evidenceRegistry.evidenceIDs for supportEvidenceRefs and counterevidenceRefs. Never put knowledge-pack, reference, marker, allele, or literature IDs such as reference:* in evidence reference arrays; discuss those only in rationale prose when relevant.
        - Do not shorten evidence IDs at pipe (`|`), comma, or colon delimiters; copy the entire evidenceRegistry ID exactly when citing support or counterevidence.
        - Do not rewrite collapsed marker tokens such as M1M4 as M1, M4, or another component haplotype token. Copy the full observed genotype text inside each evidence ID exactly.
        - For each call, sample must use evidenceRegistry.samples[].sample and locus must use evidenceRegistry.loci[].locus; reserve sample:, locus:, obs:, current:, and manual: IDs for evidence reference arrays.
        - For each call, patchOpID must be non-empty and unique within the chunk. Use a stable format such as patch:<chunkID>:<sample>:<locus>:<slot>:v1.
        - For each call, counterevidenceRefs must contain at least one relevant allowed evidence ID. If there is no direct contradictory observation, cite the corresponding sample or locus evidence ID as reviewed context.
        - haplotypeLabel, alternates, and proposedLabel must be concise labels only, such as M4A, M5A, M4/M5A, M7A-provisional, or "-". Do not put parenthetical explanations or prose in label fields.
        - Put homozygous, dominant, dropout, ambiguity, and uncertainty language only in rationale or rationaleCode, never in haplotypeLabel, alternates, normalizedFamily, proposedLabel, or warnings.
        - If you assign the same haplotypeLabel to both h1 and h2 for a sample/locus, at least one of those calls must explicitly say homozygous or single haplotype in rationaleCode or rationale.
        - Use conflictsCurrent only when the proposed haplotypeLabel differs from a callable current call. When changing a callable current call, set callState to conflictsCurrent, cite the current call as counterevidence, and explain in rationale why observation evidence conflicts with or supersedes the current call. If the proposed label agrees with current evidence, use retainCurrent or called; do not mark conflictsCurrent.
        - Do not mention clinical decisions or clinical interpretation. Do not recommend follow-up, confirmation, downstream testing, or experimental action; if evidence remains ambiguous, set callState to unresolved and state the evidence limit concisely.
        - Do not use phase or phasing language for short-amplicon evidence. Say linked marker support, coherent marker pattern, or heterozygous configuration instead.
        - Do not mention copy number, inheritance, or inherited status in labels, rationale, warnings, or follow-up suggestions. For unresolved assay-resolution questions, set callState to unresolved and state that the supplied evidence does not distinguish the alternatives.
        - Do not use the literal substrings phase, phasing, copy number, inherited, inheritance, clinical, confirmation, or follow-up anywhere in output text; the validator rejects several of these terms. Prefer linked marker support, coherent marker pattern, assay-resolution limit, or unresolved review.
        - Do not emit discoveredDefinitions for known curated labels from knowledgePack.haplotypeBlockDefinitions, such as M1A-M7A, M1B-M7B, M1DR-M7DR, M1DQ-M7DQ, or M1DP-M7DP. Use calls for those labels.
        - In refinement mode, leave discoveredDefinitions empty unless the chunk contains a genuinely novel or provisional label not already defined in the knowledge pack; each proposedLabel should appear at most once per chunk.

        Prompt input JSON:
        {{prompt_input_json}}
        """
    )
}
