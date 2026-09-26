// AnalysisTemplateExtractorTests.swift - Template extraction from a Kraken2 analysis folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class AnalysisTemplateExtractorTests: XCTestCase {

    private func makeExtractor(recipes: [Recipe] = [AnalysisTemplateTestFixture.sampleRecipe]) -> AnalysisTemplateExtractor {
        AnalysisTemplateExtractor(
            recipeResolver: { id in recipes.first { $0.id == id } },
            appVersion: "Lungfish test (1)"
        )
    }

    func testHappyPathPinsImportAndKraken2Settings() throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }

        let extraction = try makeExtractor().extract(analysisURL: fixture.analysisURL)
        let template = extraction.template

        XCTAssertEqual(extraction.sourceBundleURL.path, fixture.bundleURL.path)
        XCTAssertEqual(template.name, "Kraken2 + Bracken from SRRTEST1")
        XCTAssertEqual(template.origin.sourceAnalysisRelativePath, "Analyses/kraken2-2026-09-25T04-36-28")
        XCTAssertEqual(template.origin.classificationProvenanceID?.uuidString, "34EB0DCF-6C3D-4074-9785-16A316741465")
        XCTAssertNotNil(template.origin.importProvenanceID)
        XCTAssertNotNil(template.origin.importProvenanceSHA256)
        XCTAssertNotNil(template.origin.classificationResultSHA256)
        XCTAssertEqual(template.input, AnalysisTemplate.InputSpec(platform: .illumina, pairing: .paired))

        let importSpec = try XCTUnwrap(template.importStep)
        XCTAssertEqual(importSpec.platform, .illumina)
        XCTAssertEqual(importSpec.pairing, .paired)
        XCTAssertEqual(importSpec.qualityBinning, .illumina4)
        XCTAssertTrue(importSpec.optimizeStorage)
        XCTAssertEqual(importSpec.clumpingTool, .auto)
        XCTAssertEqual(importSpec.compressionLevel, .balanced)
        XCTAssertEqual(importSpec.recipe?.id, "vsp2-target-enrichment")
        XCTAssertEqual(importSpec.recipe?.recipe, AnalysisTemplateTestFixture.sampleRecipe)
        XCTAssertEqual(importSpec.recipe?.sha256, try RecipeSnapshot.sha256(of: AnalysisTemplateTestFixture.sampleRecipe))

        let kraken2 = try XCTUnwrap(template.kraken2Step)
        XCTAssertEqual(kraken2.goal, .profile)
        XCTAssertEqual(kraken2.database, Kraken2StepSpec.DatabaseIdentity(name: "Viral", version: "20260626", catalogID: "kraken2-viral", digest: nil))
        XCTAssertEqual(kraken2.readFormat, .interleaved)
        XCTAssertEqual(kraken2.confidence, 0.2)
        XCTAssertEqual(kraken2.minimumHitGroups, 2)
        XCTAssertEqual(kraken2.bracken, .automaticDefault)
        XCTAssertEqual(kraken2.recordedKraken2Version, "2.17.1")
        XCTAssertEqual(kraken2.recordedBrackenVersion, "3.0.1")

        // Missing digest is a creation warning, not a refusal.
        XCTAssertTrue(template.creationWarnings.contains { $0.contains("payload digest") })

        // No absolute source paths in the template.
        let json = String(decoding: try template.jsonData(), as: UTF8.self)
        XCTAssertFalse(json.contains(fixture.rootURL.path), "template JSON must not pin absolute source paths")
    }

    func testClassifyGoalWithoutBrackenAndExplicitDigest() throws {
        var options = AnalysisTemplateTestFixture.ClassificationOptions()
        options.goal = "classify"
        options.includeBracken = false
        options.databaseDigest = "sha256:abc"
        options.extraArguments = ["--use-names"]
        let fixture = try AnalysisTemplateTestFixture.make(classification: options)
        defer { fixture.cleanup() }

        let template = try makeExtractor().extract(analysisURL: fixture.analysisURL, name: "  My Template ").template
        XCTAssertEqual(template.name, "My Template")
        let kraken2 = try XCTUnwrap(template.kraken2Step)
        XCTAssertEqual(kraken2.goal, .classify)
        XCTAssertNil(kraken2.bracken)
        XCTAssertEqual(kraken2.database.digest, "sha256:abc")
        XCTAssertEqual(kraken2.extraArguments, ["--use-names"])
        XCTAssertFalse(template.creationWarnings.contains { $0.contains("payload digest") })
        XCTAssertTrue(template.creationWarnings.contains { $0.contains("unchecked") })
    }

    func testMissingOriginalInputFilesIsRefused() throws {
        var options = AnalysisTemplateTestFixture.ClassificationOptions()
        options.includeOriginalInputFiles = false
        let fixture = try AnalysisTemplateTestFixture.make(classification: options)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .missingOriginalInputFiles)
        }
    }

    func testExtractGoalIsRefused() throws {
        var options = AnalysisTemplateTestFixture.ClassificationOptions()
        options.goal = "extract"
        let fixture = try AnalysisTemplateTestFixture.make(classification: options)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .unsupportedGoal("extract"))
        }
    }

    func testBatchAnalysisIsRefused() throws {
        var options = AnalysisTemplateTestFixture.ClassificationOptions()
        options.isBatch = true
        let fixture = try AnalysisTemplateTestFixture.make(classification: options)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .batchAnalysis(fixture.analysisURL))
        }
    }

    func testDerivedInputBundleIsRefused() throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }
        try Data("{}".utf8).write(to: FASTQBundle.derivedManifestURL(in: fixture.bundleURL))

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .derivedInput(fixture.bundleURL))
        }
    }

    func testMissingImportRecordIsRefused() throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.writeProvenance = false
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .missingImportRecord(fixture.bundleURL))
        }
    }

    func testNonImportProvenanceIsRefused() throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.workflowName = "lungfish fastq dedup"
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .unsupportedImportRecord(workflowName: "lungfish fastq dedup"))
        }
    }

    func testUnknownRecipeRecordsIdOnlyWithWarning() throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }

        let template = try makeExtractor(recipes: []).extract(analysisURL: fixture.analysisURL).template
        let recipe = try XCTUnwrap(template.importStep?.recipe)
        XCTAssertEqual(recipe.id, "vsp2-target-enrichment")
        XCTAssertNil(recipe.recipe)
        XCTAssertNil(recipe.sha256)
        XCTAssertTrue(template.creationWarnings.contains { $0.contains("not installed") })
    }

    func testRecipeFromBundleMetadataWhenRecordSaysNone() throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.recipe = "none"
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }

        let template = try makeExtractor().extract(analysisURL: fixture.analysisURL).template
        XCTAssertEqual(template.importStep?.recipe?.id, "vsp2-target-enrichment")
        XCTAssertTrue(template.creationWarnings.contains { $0.contains("bundle metadata records recipe") })
    }

    func testNoRecipeWhenNeitherRecordNorMetadataHasOne() throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.recipe = "none"
        importOptions.recipeApplied = nil
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }

        let template = try makeExtractor().extract(analysisURL: fixture.analysisURL).template
        XCTAssertNil(template.importStep?.recipe)
    }

    func testGUIImportCopyStepIsSkippedWithWarning() throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.includeGUIImportStep = true
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }

        let template = try makeExtractor().extract(analysisURL: fixture.analysisURL).template
        XCTAssertEqual(template.steps.count, 2)
        XCTAssertTrue(template.creationWarnings.contains { $0.contains("gui-import") })
    }

    func testAutoPairingOnSingleFilePinsRecordedLayout() throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.pairedEndInput = false
        importOptions.outputPairingMode = "single_end"
        importOptions.platform = "ont"
        importOptions.recipe = "none"
        importOptions.recipeApplied = nil
        var classification = AnalysisTemplateTestFixture.ClassificationOptions()
        classification.interleavedInput = false
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions, classification: classification)
        defer { fixture.cleanup() }

        let template = try makeExtractor().extract(analysisURL: fixture.analysisURL).template
        XCTAssertEqual(template.input.pairing, .single)
        XCTAssertEqual(template.input.platform, .ont)
        XCTAssertEqual(template.kraken2Step?.readFormat, .unpaired)
    }

    func testMovedProjectReResolvesRecordedInputUnderCurrentProject() throws {
        var classification = AnalysisTemplateTestFixture.ClassificationOptions()
        classification.originalInputFiles = ["/Volumes/OldDisk/Old.lungfish/Imports/SRRTEST1.lungfishfastq/SRRTEST1.fastq"]
        let fixture = try AnalysisTemplateTestFixture.make(classification: classification)
        defer { fixture.cleanup() }

        let extraction = try makeExtractor().extract(analysisURL: fixture.analysisURL)
        XCTAssertEqual(extraction.sourceBundleURL.path, fixture.bundleURL.path)
        XCTAssertTrue(extraction.template.creationWarnings.contains { $0.contains("instead of its recorded location") })
    }

    func testMissingInputThatCannotBeReResolvedIsRefused() throws {
        var classification = AnalysisTemplateTestFixture.ClassificationOptions()
        classification.originalInputFiles = ["/Volumes/OldDisk/Old.lungfish/Imports/Other.lungfishfastq/Other.fastq"]
        let fixture = try AnalysisTemplateTestFixture.make(classification: classification)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: fixture.analysisURL)) { error in
            XCTAssertEqual(
                error as? AnalysisTemplateExtractionError,
                .inputNotFound("/Volumes/OldDisk/Old.lungfish/Imports/Other.lungfishfastq/Other.fastq")
            )
        }
    }

    func testAnalysisOutsideProjectNeedsExplicitProject() throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }
        let loose = fixture.rootURL.appendingPathComponent("loose-kraken2", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.analysisURL, to: loose)

        XCTAssertThrowsError(try makeExtractor().extract(analysisURL: loose)) { error in
            XCTAssertEqual(error as? AnalysisTemplateExtractionError, .projectNotFound(loose))
        }
        let template = try makeExtractor().extract(analysisURL: loose, projectURL: fixture.projectURL).template
        XCTAssertEqual(template.origin.sourceAnalysisRelativePath, "loose-kraken2")
    }
}
