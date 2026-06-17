import XCTest
@testable import LungfishWorkflow

final class AIHaplotypingPromptRegistryTests: XCTestCase {
    func testCurrentDiscoveryAndRefinementPromptsHaveStableIdentityAndDistinctHashes() throws {
        let registry = AIHaplotypingPromptRegistry.builtIn

        let discovery = try registry.currentTemplate(for: .aiDiscovery)
        let refinement = try registry.currentTemplate(for: .aiRefinement)

        XCTAssertEqual(discovery.id, "lungfish.ai-haplotyping.discovery")
        XCTAssertEqual(refinement.id, "lungfish.ai-haplotyping.refinement")
        XCTAssertEqual(discovery.version, "2026-06-15.16")
        XCTAssertEqual(refinement.version, "2026-06-15.16")
        XCTAssertEqual(discovery.evidenceSchemaVersion, 1)
        XCTAssertEqual(refinement.evidenceSchemaVersion, 1)
        XCTAssertTrue(discovery.hash.hasPrefix("sha256:"))
        XCTAssertEqual(discovery.hash.count, "sha256:".count + 64)
        XCTAssertTrue(refinement.hash.hasPrefix("sha256:"))
        XCTAssertEqual(refinement.hash.count, "sha256:".count + 64)
        XCTAssertNotEqual(discovery.hash, refinement.hash)
        XCTAssertTrue(discovery.systemPrompt.contains("macaque MHC immunogenetics"))
        XCTAssertTrue(refinement.systemPrompt.contains("macaque MHC immunogenetics"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("DP/DQ linkage"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("MHC-E"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("homozygous"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("population novelty prior"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("curated report labels"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("do not split"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("schemaVersion must be the integer 1"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("schemaVersion must be the integer 1"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Copy expectedRun exactly into run"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Copy expectedRun exactly into run"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Do not shorten evidence IDs at pipe"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Do not shorten evidence IDs at pipe"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Do not rewrite collapsed marker tokens such as M1M4 as M1"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Do not rewrite collapsed marker tokens such as M1M4 as M1"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("counterevidenceRefs must contain at least one"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("counterevidenceRefs must contain at least one"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("patchOpID must be non-empty and unique"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("patchOpID must be non-empty and unique"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("haplotypeLabel, alternates, and proposedLabel must be concise labels only"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("haplotypeLabel, alternates, and proposedLabel must be concise labels only"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Put homozygous, dominant, dropout, ambiguity, and uncertainty language only in rationale or rationaleCode"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Put homozygous, dominant, dropout, ambiguity, and uncertainty language only in rationale or rationaleCode"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("If you assign the same haplotypeLabel to both h1 and h2"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("If you assign the same haplotypeLabel to both h1 and h2"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Use conflictsCurrent only when"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Use conflictsCurrent only when"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("cite the current call as counterevidence"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("cite the current call as counterevidence"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("explain in rationale"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("explain in rationale"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Do not mention clinical decisions"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Do not mention clinical decisions"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Do not use phase or phasing language"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Do not use phase or phasing language"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("the validator rejects them"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("the validator rejects them"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Do not mention copy number"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Do not mention copy number"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("Do not emit discoveredDefinitions for known curated labels"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("Do not emit discoveredDefinitions for known curated labels"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("In refinement mode, leave discoveredDefinitions empty unless"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("{{prompt_input_json}}"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("{{prompt_input_json}}"))
    }

    func testLookupKeepsOldVersionsAddressableAndCurrentUsesHighestLocalizedStandardVersion() throws {
        let oldDiscovery = AIHaplotypingPromptTemplate(
            id: "lungfish.ai-haplotyping.discovery",
            mode: .aiDiscovery,
            version: "2026-06-14.0",
            evidenceSchemaVersion: 1,
            systemPrompt: "old discovery system",
            userPromptTemplate: "old {{evidence_registry_json}}"
        )
        let currentDiscovery = AIHaplotypingPromptTemplate(
            id: "lungfish.ai-haplotyping.discovery",
            mode: .aiDiscovery,
            version: "2026-06-14.2",
            evidenceSchemaVersion: 1,
            systemPrompt: "new discovery system",
            userPromptTemplate: "new {{evidence_registry_json}}"
        )
        let registry = try AIHaplotypingPromptRegistry(templates: [currentDiscovery, oldDiscovery])

        XCTAssertEqual(try registry.currentTemplate(for: .aiDiscovery).version, "2026-06-14.2")
        XCTAssertEqual(
            try registry.template(id: "lungfish.ai-haplotyping.discovery", version: "2026-06-14.0").systemPrompt,
            "old discovery system"
        )
        XCTAssertTrue(
            try registry.template(
                id: "lungfish.ai-haplotyping.discovery",
                version: "2026-06-14.2"
            ).userPromptTemplate.contains("{{evidence_registry_json}}")
        )
    }

    func testTemplateMetadataDoesNotEncodePromptText() throws {
        let template = try AIHaplotypingPromptRegistry.builtIn.currentTemplate(for: .aiDiscovery)
        let metadata = template.metadata(
            registryDigest: AIHaplotypingPromptRegistry.builtIn.registryDigest,
            inputSnapshotDigest: "sha256:\(String(repeating: "a", count: 64))",
            evidenceSnapshotPath: "artifacts/ai/evidence.json"
        )

        XCTAssertEqual(metadata.promptTemplateID, template.id)
        XCTAssertEqual(metadata.promptTemplateVersion, template.version)
        XCTAssertEqual(metadata.promptHash, template.hash)
        XCTAssertEqual(metadata.evidenceSchemaVersion, template.evidenceSchemaVersion)
        XCTAssertEqual(metadata.evidenceSnapshotPath, "artifacts/ai/evidence.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try encoder.encode(metadata), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(template.systemPrompt))
        XCTAssertFalse(encoded.contains("You are reconstructing reviewable haplotype calls"))
        XCTAssertFalse(encoded.contains("{{evidence_registry_json}}"))
    }

    func testPromptRenderingKeepsLegacyEvidencePlaceholderCompatibleWithPromptInputJSON() {
        let legacyTemplate = AIHaplotypingPromptTemplate(
            id: "legacy",
            mode: .aiDiscovery,
            version: "1",
            evidenceSchemaVersion: 1,
            systemPrompt: "system",
            userPromptTemplate: "Evidence registry JSON:\n{{evidence_registry_json}}"
        )
        let rendered = legacyTemplate.render(
            promptInputJSON: "{\"chunkID\":\"chunk-0001\"}",
            evidenceRegistryJSON: "{\"schemaVersion\":1}"
        )

        XCTAssertTrue(rendered.contains("\"chunkID\":\"chunk-0001\""))
        XCTAssertFalse(rendered.contains("\"schemaVersion\":1"))
    }

    func testValidatingRegistryRejectsDuplicateTemplateIDVersionAndKeepsVersionsAddressable() throws {
        let older = AIHaplotypingPromptTemplate(
            id: "template",
            mode: .aiDiscovery,
            version: "1.0",
            evidenceSchemaVersion: 1,
            systemPrompt: "older",
            userPromptTemplate: "{{evidence_registry_json}}"
        )
        let newer = AIHaplotypingPromptTemplate(
            id: "template",
            mode: .aiDiscovery,
            version: "2.0",
            evidenceSchemaVersion: 1,
            systemPrompt: "newer",
            userPromptTemplate: "{{evidence_registry_json}}"
        )
        let duplicate = AIHaplotypingPromptTemplate(
            id: "template",
            mode: .aiRefinement,
            version: "1.0",
            evidenceSchemaVersion: 1,
            systemPrompt: "duplicate",
            userPromptTemplate: "{{evidence_registry_json}}"
        )

        XCTAssertThrowsError(try AIHaplotypingPromptRegistry(templates: [older, duplicate]))

        let registry = try AIHaplotypingPromptRegistry(templates: [newer, older])
        XCTAssertEqual(try registry.currentTemplate(for: .aiDiscovery).version, "2.0")
        XCTAssertEqual(try registry.template(id: "template", version: "1.0"), older)
        XCTAssertEqual(try registry.template(id: "template", version: "2.0"), newer)
    }
}
