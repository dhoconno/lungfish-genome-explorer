// RecipeEngineTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class RecipeEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeRecipe(
        requiredInput: Recipe.InputRequirement = .paired,
        steps: [RecipeStep]
    ) -> Recipe {
        Recipe(
            formatVersion: 1,
            id: "test-recipe",
            name: "Test Recipe",
            platforms: [.illumina],
            requiredInput: requiredInput,
            steps: steps
        )
    }

    // MARK: - Validation tests

    func testValidateUnknownStepType() throws {
        let recipe = makeRecipe(steps: [RecipeStep(type: "nonexistent-tool")])
        let engine = RecipeEngine()
        XCTAssertThrowsError(try engine.validate(recipe: recipe, inputFormat: .pairedR1R2)) { error in
            guard case RecipeEngineError.unknownStepType("nonexistent-tool") = error else {
                XCTFail("Expected unknownStepType(\"nonexistent-tool\"), got \(error)"); return
            }
        }
    }

    func testValidateInputRequirementMismatch() throws {
        let recipe = makeRecipe(requiredInput: .paired, steps: [RecipeStep(type: "fastp-dedup")])
        let engine = RecipeEngine()
        XCTAssertThrowsError(try engine.validate(recipe: recipe, inputFormat: .single)) { error in
            guard case RecipeEngineError.inputRequirementNotMet = error else {
                XCTFail("Expected inputRequirementNotMet, got \(error)"); return
            }
        }
    }

    func testValidateValidRecipe() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup"),
            RecipeStep(type: "fastp-trim"),
        ])
        let engine = RecipeEngine()
        XCTAssertNoThrow(try engine.validate(recipe: recipe, inputFormat: .pairedR1R2))
    }

    // MARK: - Planning tests

    func testPlanFusesConsecutiveFastpSteps() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup"),
            RecipeStep(
                type: "fastp-trim",
                params: [
                    "quality":  .int(15),
                    "window":   .int(5),
                    "cutMode":  .string("right"),
                ]
            ),
        ])
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // Two fastp steps → 1 fused step
        XCTAssertEqual(plan.count, 1)
        if case .fusedFastp(let args, _, _) = plan[0] {
            XCTAssertTrue(args.contains("--dedup"),
                          "fused args should contain --dedup; got \(args)")
            XCTAssertTrue(args.contains("-q"),
                          "fused args should contain -q; got \(args)")
            XCTAssertTrue(args.contains("15"),
                          "fused args should contain quality value 15; got \(args)")
        } else {
            XCTFail("Expected .fusedFastp, got \(plan[0])")
        }
    }

    func testPlanDoesNotFuseAcrossNonFastp() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup"),
            RecipeStep(type: "deacon-scrub"),
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
        ])
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // 3 separate steps (no fusion)
        XCTAssertEqual(plan.count, 3,
                       "Expected 3 steps but got \(plan.count): \(plan.map { "\($0)" })")
    }

    func testPlanInsertsMergedToSingleConversion() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
            RecipeStep(type: "seqkit-length-filter", params: ["minLength": .int(50)]),
        ])
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // merge + conversion(merged→single) + length-filter = 3
        XCTAssertEqual(plan.count, 3,
                       "Expected 3 plan entries but got \(plan.count)")
        if case .formatConversion(let from, let to) = plan[1] {
            XCTAssertEqual(from, .merged)
            XCTAssertEqual(to, .single)
        } else {
            XCTFail("Expected .formatConversion at index 1, got \(plan[1])")
        }
    }

    func testPlanSupportsPairedRiboDetectorBeforeMerge() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "deacon-scrub"),
            RecipeStep(
                type: "ribodetector-filter",
                label: "Remove ribosomal RNA",
                params: [
                    "retain": .string("norrna"),
                    "ensure": .string("rrna"),
                    "readLength": .int(151),
                    "chunkSize": .int(200),
                ]
            ),
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
        ])
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        XCTAssertEqual(plan.count, 3)
        guard case .singleStep(let executor, let label) = plan[1] else {
            return XCTFail("Expected RiboDetector single step at index 1, got \(plan[1])")
        }
        XCTAssertTrue(executor is RiboDetectorStep)
        XCTAssertEqual(label, "Remove ribosomal RNA")
    }

    func testRecipeToolTimeoutDisablesTimeoutForFullSizeFastpInputs() {
        let timeout = StepContext.recipeToolTimeout(
            for: .fastp,
            inputBytes: 100_000_000_000
        )

        XCTAssertTrue(timeout.isInfinite, "Full-size FASTQ recipe steps should not time out")
    }

    func testRecipeToolTimeoutDisablesTimeoutForSlowRiboDetectorOnLargeInputs() {
        let inputBytes: Int64 = 100_000_000_000
        let riboDetectorTimeout = StepContext.recipeToolTimeout(for: .ribodetector, inputBytes: inputBytes)

        XCTAssertTrue(riboDetectorTimeout.isInfinite, "Large paired RiboDetector jobs should not time out")
    }

    func testRecipeToolTimeoutDisablesTimeoutForLargeSeqkitLengthFilterInputs() {
        let observedTimedOutInputBytes: Int64 = 27_360_000_000
        let timeout = StepContext.recipeToolTimeout(for: .seqkit, inputBytes: observedTimedOutInputBytes)

        XCTAssertTrue(timeout.isInfinite, "Large gzipped seqkit length filters should not time out")
    }

    func testRecipeStreamConcatenationPreservesSourceBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeEngineConcat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = root.appendingPathComponent("first.fq.gz")
        let second = root.appendingPathComponent("second.fq.gz")
        let output = root.appendingPathComponent("combined.fq.gz")

        let firstBytes = Data([0x1f, 0x8b, 0x08, 0x01])
        let secondBytes = Data([0x1f, 0x8b, 0x08, 0x02, 0x03])
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)

        try RecipeEngine.concatenateStreams([first, second], to: output)

        XCTAssertEqual(try Data(contentsOf: output), firstBytes + secondBytes)
    }
}
