// RecipeIntegrationTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class RecipeIntegrationTests: XCTestCase {

    func testVSP2RecipeLoadsAndValidates() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })
        let engine = RecipeEngine()
        XCTAssertNoThrow(try engine.validate(recipe: vsp2, inputFormat: .pairedR1R2))
    }

    func testVSP2RecipePlanFusesDedupAndTrim() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: vsp2, inputFormat: .pairedR1R2)

        // Expected plan for VSP2 (5 steps in recipe):
        // 1. fusedFastp (dedup + trim) — two consecutive fastp steps fuse
        // 2. singleStep (deacon-scrub)
        // 3. singleStep (fastp-merge)
        // 4. formatConversion (merged → single)
        // 5. singleStep (seqkit-length-filter)
        XCTAssertEqual(plan.count, 5)

        if case .fusedFastp(let args, _, _) = plan[0] {
            XCTAssertTrue(args.contains("--dedup"), "Fused args should include --dedup")
            XCTAssertTrue(args.contains("--detect_adapter_for_pe"), "Should include adapter detection")
            XCTAssertTrue(args.contains("-q"), "Should include quality threshold")
            XCTAssertTrue(args.contains("15"), "Quality should be 15")
        } else {
            XCTFail("First planned step should be fusedFastp, got \(plan[0])")
        }
    }

    func testVSP2RecipeRejectsSingleEndInput() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })
        let engine = RecipeEngine()
        XCTAssertThrowsError(try engine.validate(recipe: vsp2, inputFormat: .single))
    }

    // MARK: - Tool Execution Tests

    /// Check if a tool binary exists.
    private func toolAvailable(_ tool: NativeTool) async -> Bool {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: tool)
            return true
        } catch {
            return false
        }
    }

    /// Locate sarscov2 test fixtures relative to this source file.
    private var fixturesDir: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let testsDir = thisFile
            .deletingLastPathComponent() // Recipes/
            .deletingLastPathComponent() // LungfishWorkflowTests/
            .deletingLastPathComponent() // Tests/
        let dir = testsDir.appendingPathComponent("Fixtures/sarscov2")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Create a temp workspace, returning the workspace URL.
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    func testExecuteFastpDedupOnFixtures() async throws {
        guard await toolAvailable(.fastp) else { throw XCTSkip("fastp not available") }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let step = try FastpDedupStep(params: nil)
        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "sarscov2-test",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })

        let output = try await step.execute(input: input, context: context)
        XCTAssertEqual(output.format, .pairedR1R2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r2!.path))

        // Verify output is valid FASTQ
        let stats = try await NativeToolRunner.shared.run(.seqkit, arguments: ["stats", "--tabular", output.r1.path])
        XCTAssertEqual(stats.exitCode, 0)
    }

    func testExecuteFastpTrimOnFixtures() async throws {
        guard await toolAvailable(.fastp) else { throw XCTSkip("fastp not available") }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let step = try FastpTrimStep(params: ["detectAdapter": .bool(true), "quality": .int(15),
                                               "window": .int(5), "cutMode": .string("right")])
        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "sarscov2-test",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })

        let output = try await step.execute(input: input, context: context)
        XCTAssertEqual(output.format, .pairedR1R2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r1.path))
    }

    func testExecuteFastpMergeOnFixtures() async throws {
        guard await toolAvailable(.fastp) else { throw XCTSkip("fastp not available") }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let step = try FastpMergeStep(params: ["minOverlap": .int(15)])
        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "sarscov2-test",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })

        let output = try await step.execute(input: input, context: context)
        XCTAssertEqual(output.format, .merged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r1.path), "Merged output")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r2!.path), "Unmerged R1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r3!.path), "Unmerged R2")
    }

    func testExecuteSeqkitLengthFilterOnFixtures() async throws {
        guard await toolAvailable(.seqkit) else { throw XCTSkip("seqkit not available") }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let step = try SeqkitLengthFilterStep(params: ["minLength": .int(50)])
        let input = StepInput(r1: r1, format: .single)
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "sarscov2-test",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })

        let output = try await step.execute(input: input, context: context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r1.path))
    }

    func testRecipeEngineExecutionWithoutDeacon() async throws {
        guard await toolAvailable(.fastp), await toolAvailable(.seqkit) else {
            throw XCTSkip("Required tools not available")
        }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let testRecipe = Recipe(
            formatVersion: 1, id: "test-no-deacon", name: "Test Without Deacon",
            platforms: [.illumina], requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-dedup", label: "Dedup"),
                RecipeStep(type: "fastp-trim", label: "Trim",
                           params: ["quality": .int(15), "window": .int(5),
                                    "cutMode": .string("right"), "detectAdapter": .bool(true)]),
                RecipeStep(type: "fastp-merge", label: "Merge", params: ["minOverlap": .int(15)]),
                RecipeStep(type: "seqkit-length-filter", label: "Filter", params: ["minLength": .int(50)]),
            ]
        )

        let engine = RecipeEngine()
        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "sarscov2-e2e",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })

        let result = try await engine.execute(recipe: testRecipe, input: input, context: context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.r1.path), "Final output should exist")

        // Verify output is valid FASTQ
        let stats = try await NativeToolRunner.shared.run(.seqkit, arguments: ["stats", "--tabular", result.output.r1.path])
        XCTAssertEqual(stats.exitCode, 0, "seqkit stats should succeed on final output")
    }

    func testFullVSP2RecipeExecution() async throws {
        guard await toolAvailable(.fastp), await toolAvailable(.seqkit),
              await toolAvailable(.deacon) else {
            throw XCTSkip("Required tools not available")
        }
        guard let _ = await DatabaseRegistry.shared.effectiveDatabasePath(for: "deacon") else {
            throw XCTSkip("Deacon panhuman-1 index not installed")
        }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })
        let engine = RecipeEngine()

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "sarscov2-vsp2",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })

        let result = try await engine.execute(recipe: vsp2, input: input, context: context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.r1.path))

        let stats = try await NativeToolRunner.shared.run(.seqkit, arguments: ["stats", "--tabular", result.output.r1.path])
        XCTAssertEqual(stats.exitCode, 0)
    }
}
