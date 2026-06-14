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
        version: "2026-06-14.1",
        evidenceSchemaVersion: 1,
        systemPrompt: """
        You are reconstructing reviewable haplotype calls from ONT genotyping evidence.
        Use only supplied evidence records and cite evidence IDs for every proposed call.
        Treat the result as analyst-review input, not as an automatically final scientific conclusion.
        """,
        userPromptTemplate: """
        Review this AI haplotyping evidence registry and propose haplotype calls.

        Evidence registry JSON:
        {{evidence_registry_json}}
        """
    )

    static let builtInRefinement = AIHaplotypingPromptTemplate(
        id: "lungfish.ai-haplotyping.refinement",
        mode: .aiRefinement,
        version: "2026-06-14.1",
        evidenceSchemaVersion: 1,
        systemPrompt: """
        Refine existing haplotype calls using only the supplied review evidence.
        Preserve defensible current calls, identify conflicts with manual review evidence, and cite evidence IDs.
        Return reviewable refinements rather than untraceable final calls.
        """,
        userPromptTemplate: """
        Refine the current haplotype calls using this evidence registry.

        Evidence registry JSON:
        {{evidence_registry_json}}
        """
    )
}
