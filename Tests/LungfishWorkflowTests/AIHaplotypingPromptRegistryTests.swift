import XCTest
@testable import LungfishWorkflow

final class AIHaplotypingPromptRegistryTests: XCTestCase {
    func testCurrentDiscoveryAndRefinementPromptsHaveStableIdentityAndDistinctHashes() throws {
        let registry = AIHaplotypingPromptRegistry.builtIn

        let discovery = try registry.currentTemplate(for: .aiDiscovery)
        let refinement = try registry.currentTemplate(for: .aiRefinement)

        XCTAssertEqual(discovery.id, "lungfish.ai-haplotyping.discovery")
        XCTAssertEqual(refinement.id, "lungfish.ai-haplotyping.refinement")
        XCTAssertEqual(discovery.version, "2026-06-14.1")
        XCTAssertEqual(refinement.version, "2026-06-14.1")
        XCTAssertEqual(discovery.evidenceSchemaVersion, 1)
        XCTAssertEqual(refinement.evidenceSchemaVersion, 1)
        XCTAssertTrue(discovery.hash.hasPrefix("sha256:"))
        XCTAssertEqual(discovery.hash.count, "sha256:".count + 64)
        XCTAssertTrue(refinement.hash.hasPrefix("sha256:"))
        XCTAssertEqual(refinement.hash.count, "sha256:".count + 64)
        XCTAssertNotEqual(discovery.hash, refinement.hash)
        XCTAssertTrue(discovery.systemPrompt.contains("You are reconstructing reviewable haplotype calls"))
        XCTAssertTrue(refinement.systemPrompt.contains("Refine existing haplotype calls"))
        XCTAssertTrue(discovery.userPromptTemplate.contains("{{evidence_registry_json}}"))
        XCTAssertTrue(refinement.userPromptTemplate.contains("{{evidence_registry_json}}"))
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
