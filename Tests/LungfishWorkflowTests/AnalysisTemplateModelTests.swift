// AnalysisTemplateModelTests.swift - JSON round trip and schema checks for templates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class AnalysisTemplateModelTests: XCTestCase {

    static func sampleTemplate() throws -> AnalysisTemplate {
        AnalysisTemplate(
            id: UUID(uuidString: "0A4B2C3D-1111-2222-3333-444455556666")!,
            name: "Kraken2 + Bracken from SRRTEST1",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            origin: AnalysisTemplate.Origin(
                appVersion: "Lungfish 2026.9.48 (1)",
                sourceAnalysisRelativePath: "Analyses/kraken2-2026-09-25T04-36-28",
                importProvenanceID: UUID(),
                classificationProvenanceID: UUID(),
                importProvenanceSHA256: "abc",
                classificationResultSHA256: "def"
            ),
            input: AnalysisTemplate.InputSpec(platform: .illumina, pairing: .paired),
            steps: [
                .importFASTQ(ImportFASTQStepSpec(
                    platform: .illumina,
                    pairing: .paired,
                    qualityBinning: .illumina4,
                    optimizeStorage: true,
                    clumpingTool: .auto,
                    compressionLevel: .balanced,
                    recipe: try RecipeSnapshot(recipe: AnalysisTemplateTestFixture.sampleRecipe)
                )),
                .kraken2(Kraken2StepSpec(
                    goal: .profile,
                    database: Kraken2StepSpec.DatabaseIdentity(name: "Viral", version: "20260626", catalogID: "kraken2-viral"),
                    readFormat: .interleaved,
                    confidence: 0.2,
                    minimumHitGroups: 2,
                    memoryMapping: false,
                    quickMode: false,
                    extraArguments: ["--use-names"],
                    bracken: BrackenProfileRequest(rank: .explicit(.genus), readLength: 100, threshold: 5),
                    recordedKraken2Version: "2.17.1",
                    recordedBrackenVersion: "3.0.1"
                )),
            ],
            creationWarnings: ["The Kraken2 database Viral has no recorded payload digest, so only its name and version are checked at run time."]
        )
    }

    func testJSONRoundTripPreservesEverySetting() throws {
        let template = try Self.sampleTemplate()
        let data = try template.jsonData()
        let decoded = try AnalysisTemplate.load(from: data)
        XCTAssertEqual(decoded, template)
        XCTAssertEqual(decoded.importStep?.recipe?.sha256, try RecipeSnapshot.sha256(of: AnalysisTemplateTestFixture.sampleRecipe))
        XCTAssertEqual(decoded.kraken2Step?.bracken, BrackenProfileRequest(rank: .explicit(.genus), readLength: 100, threshold: 5))
        XCTAssertEqual(decoded.input.fileCount, 2)
    }

    func testEncodingIsStableWithSortedKeysAndTypedSteps() throws {
        let template = try Self.sampleTemplate()
        let first = try template.jsonData()
        let second = try template.jsonData()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try template.sha256(), try template.sha256())

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["type"] as? String }, ["importFASTQ", "kraken2"])
        XCTAssertEqual(json["createdAt"] as? String, "2026-09-21T14:13:20Z")
    }

    func testNewerSchemaVersionIsRejected() throws {
        let template = try Self.sampleTemplate()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try template.jsonData()) as? [String: Any])
        json["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try AnalysisTemplate.load(from: data)) { error in
            XCTAssertEqual(error as? AnalysisTemplateError, .unsupportedSchemaVersion(2))
        }
    }

    func testUnknownStepTypeIsRejected() throws {
        let template = try Self.sampleTemplate()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try template.jsonData()) as? [String: Any])
        var steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        steps[1]["type"] = "spades"
        json["steps"] = steps
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try AnalysisTemplate.load(from: data)) { error in
            guard case .invalidTemplate(let reason)? = error as? AnalysisTemplateError else {
                return XCTFail("Expected invalidTemplate, got \(error)")
            }
            XCTAssertTrue(reason.contains("spades"))
        }
    }

    func testSaveAndLoadFile() throws {
        let root = try TestTempDirectory.make(prefix: "template-model")
        defer { TestTempDirectory.cleanup(root) }
        let url = root.appendingPathComponent("Nested/My Template.lungfishtemplate")
        let template = try Self.sampleTemplate()
        try template.save(to: url)
        XCTAssertEqual(try AnalysisTemplate.load(from: url), template)
    }

    func testRecipeHashChangesWhenRecipeContentChanges() throws {
        XCTAssertNotEqual(
            try RecipeSnapshot.sha256(of: AnalysisTemplateTestFixture.sampleRecipe),
            try RecipeSnapshot.sha256(of: AnalysisTemplateTestFixture.changedRecipe)
        )
    }
}
