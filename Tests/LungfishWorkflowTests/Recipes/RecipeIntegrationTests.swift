// RecipeIntegrationTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
import LungfishIO
@testable import LungfishWorkflow

final class RecipeIntegrationTests: XCTestCase {

    func testDebugUserRecipesDirectoryIsIsolated() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support")

        XCTAssertEqual(
            RecipeRegistryV2.userRecipesDirectoryURL(
                appIdentity: .debug,
                applicationSupportDirectory: applicationSupport
            ),
            applicationSupport.appendingPathComponent("Lungfish Debug/recipes")
        )
        XCTAssertEqual(
            RecipeRegistryV2.userRecipesDirectoryURL(
                appIdentity: .stable,
                applicationSupportDirectory: applicationSupport
            ),
            applicationSupport.appendingPathComponent("Lungfish/recipes")
        )
    }

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

        if case .fusedFastp(let args, _, _, _) = plan[0] {
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

    func testWastewaterMetagenomicsRecipeLoadsAndValidates() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let wastewater = try XCTUnwrap(recipes.first { $0.id == "wastewater-metagenomics" })
        let engine = RecipeEngine()

        XCTAssertEqual(wastewater.name, "Wastewater metagenomics")
        XCTAssertNoThrow(try engine.validate(recipe: wastewater, inputFormat: .pairedR1R2))
        XCTAssertFalse(
            wastewater.steps.contains { $0.type == "fastp-dedup" },
            "Wastewater metagenomics should preserve abundance by default instead of deduplicating reads"
        )
    }

    func testWastewaterMetagenomicsRecipeUsesDeaconRiboFilterBeforeMerge() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let wastewater = try XCTUnwrap(recipes.first { $0.id == "wastewater-metagenomics" })
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: wastewater, inputFormat: .pairedR1R2)

        XCTAssertEqual(plan.count, 6)
        XCTAssertGreaterThan(wastewater.steps.count, 2)
        XCTAssertEqual(wastewater.steps[2].type, "deacon-ribo-filter")
        XCTAssertEqual(wastewater.steps[2].params?["database"]?.stringValue, "deacon-ribokmers")

        guard case .singleStep(let riboFilter, let riboLabel) = plan[2] else {
            return XCTFail("Expected paired Deacon rRNA filter at plan index 2, got \(plan[2])")
        }
        XCTAssertTrue(riboFilter is DeaconRiboFilterStep)
        XCTAssertEqual(riboLabel, "Remove ribosomal RNA")

        guard case .singleStep(let merge, _) = plan[3] else {
            return XCTFail("Expected merge after Deacon rRNA filter, got \(plan[3])")
        }
        XCTAssertTrue(merge is FastpMergeStep)

        guard case .singleStep(let filter, _) = plan[4] else {
            return XCTFail("Expected the length filter on the merged layout, got \(plan[4])")
        }
        XCTAssertTrue(filter is SeqkitLengthFilterStep)

        guard case .formatConversion(let from, let to) = plan[5] else {
            return XCTFail("Expected merged-to-mixed normalization after length filtering, got \(plan[5])")
        }
        XCTAssertEqual(from, .merged)
        XCTAssertEqual(to, .mixed)
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
        guard await toolAvailable(.fastp) else { try ToolAvailability.skipOrFail("fastp not available") }
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
        guard await toolAvailable(.fastp) else { try ToolAvailability.skipOrFail("fastp not available") }
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
        guard await toolAvailable(.fastp) else { try ToolAvailability.skipOrFail("fastp not available") }
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

    func testExecutePairedRiboDetectorOnFixtures() async throws {
        guard await toolAvailable(.ribodetector) else { try ToolAvailability.skipOrFail("RiboDetector not available") }
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let step = try RiboDetectorStep(params: [
            "retain": .string("norrna"),
            "ensure": .string("rrna"),
            "readLength": .int(151),
            "chunkSize": .int(2),
        ])
        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(
            workspace: workspace,
            threads: 2,
            sampleName: "sarscov2-ribodetector",
            runner: NativeToolRunner.shared,
            progress: { _, _ in }
        )

        let output = try await step.execute(input: input, context: context)

        XCTAssertEqual(output.format, .pairedR1R2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.r2!.path))
        XCTAssertEqual(output.tool, .ribodetector)
        let argumentPrefix = output.arguments.map { Array($0.prefix(7)) } ?? []
        XCTAssertEqual(Array(argumentPrefix.dropFirst()), ["-t", "2", "-l", "151", "-i", r1.path])
        XCTAssertTrue(argumentPrefix.first?.hasSuffix("ribodetector_cpu") == true)
    }

    func testExecuteSeqkitLengthFilterOnFixtures() async throws {
        guard await toolAvailable(.seqkit) else { try ToolAvailability.skipOrFail("seqkit not available") }
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
            try ToolAvailability.skipOrFail("Required tools not available")
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

        // The merged reads come first and every unmerged fragment keeps its
        // two mates adjacent; nothing is left as an orphan.
        XCTAssertEqual(result.output.format, .mixed)
        let layout = try XCTUnwrap(result.output.mixedLayout)
        let scan = try FASTQPairInterleaver.countMixed(interleaved: result.output.r1)
        XCTAssertEqual(scan.pairs, layout.pairs)
        XCTAssertEqual(scan.unpaired, layout.mergedReads)
        XCTAssertGreaterThan(layout.pairs, 0, "the fixture has unmerged pairs")
        XCTAssertGreaterThan(layout.mergedReads, 0)
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: result.output.r1), layout.totalRecords)

        let filterRecords = result.stepRecords.filter { $0.stepName.hasPrefix("Filter") }
        XCTAssertEqual(filterRecords.map(\.tool), ["seqkit", "fastp"],
                       "merged reads are filtered by seqkit, the pairs by one paired fastp run")
        XCTAssertEqual(filterRecords.last?.stepName, "Filter (unmerged pairs)")
        XCTAssertTrue(filterRecords.last?.commandArguments?.contains("-l") == true)
    }

    func testLengthFilterOnMergedLayoutDropsBothMatesWhenEitherIsShort() async throws {
        guard await toolAvailable(.fastp), await toolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("Required tools not available")
        }
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        func fastq(_ records: [(String, Int)]) -> String {
            records.map { name, length in
                "@\(name)\n\(String(repeating: "ACGT", count: length / 4 + 1).prefix(length))\n+\n\(String(repeating: "I", count: length))\n"
            }.joined()
        }
        let merged = workspace.appendingPathComponent("merged.fastq")
        let r1 = workspace.appendingPathComponent("unmerged_R1.fastq")
        let r2 = workspace.appendingPathComponent("unmerged_R2.fastq")
        try fastq([("m-long merged_120_30", 120), ("m-short merged_40_10", 40)]).write(to: merged, atomically: true, encoding: .utf8)
        try fastq([("short-mate/1", 150), ("kept/1", 150)]).write(to: r1, atomically: true, encoding: .utf8)
        try fastq([("short-mate/2", 40), ("kept/2", 150)]).write(to: r2, atomically: true, encoding: .utf8)

        let step = try SeqkitLengthFilterStep(params: ["minLength": .int(50)])
        let context = StepContext(workspace: workspace, threads: 2, sampleName: "pairs",
                                  runner: NativeToolRunner.shared, progress: { _, _ in })
        let output = try await step.execute(
            input: StepInput(r1: merged, r2: r1, r3: r2, format: .merged), context: context)

        XCTAssertEqual(output.format, .merged)
        XCTAssertEqual(output.tool, .seqkit)
        XCTAssertEqual(output.supplementaryInvocations.map(\.tool), [.fastp])

        func headers(_ url: URL) throws -> [String] {
            try FASTQReadLayoutClassifier.readHeaders(from: url).headers
        }
        XCTAssertEqual(try headers(output.r1), ["m-long merged_120_30"], "merged reads are judged one by one")
        // The 150 bp R1 of the short-mate pair is NOT kept as an orphan.
        XCTAssertEqual(try headers(try XCTUnwrap(output.r2)), ["kept/1"])
        XCTAssertEqual(try headers(try XCTUnwrap(output.r3)), ["kept/2"])
    }

    func testFullVSP2RecipeExecution() async throws {
        guard await toolAvailable(.fastp), await toolAvailable(.seqkit),
              await toolAvailable(.deacon) else {
            try ToolAvailability.skipOrFail("Required tools not available")
        }
        guard let installedDatabase = await DatabaseRegistry.shared.effectiveDatabasePath(for: "deacon-panhuman") else {
            try ToolAvailability.skipOrFail("Deacon human-read removal index not installed")
        }
        _ = try ConformanceFixtures.installedManagedDatabaseFile(id: "deacon-panhuman", path: installedDatabase)
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

        let mergeStep = try XCTUnwrap(result.stepRecords.first {
            $0.tool == "fastp" && $0.commandArguments?.contains("--merge") == true
        })
        XCTAssertEqual(mergeStep.executionOutputFiles.count, 3)
        XCTAssertEqual(
            Set(mergeStep.executionOutputFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent }),
            Set([
                "sarscov2-vsp2_merged.fq.gz",
                "sarscov2-vsp2_unmerged_R1.fq.gz",
                "sarscov2-vsp2_unmerged_R2.fq.gz",
            ])
        )
        XCTAssertTrue(mergeStep.executionOutputFiles.allSatisfy { !$0.checksumSHA256.isEmpty })
        XCTAssertTrue(mergeStep.executionOutputFiles.allSatisfy { $0.sizeBytes > 0 })
        XCTAssertTrue(mergeStep.executionOutputFiles.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })

        let stats = try await NativeToolRunner.shared.run(.seqkit, arguments: ["stats", "--tabular", result.output.r1.path])
        XCTAssertEqual(stats.exitCode, 0)
    }

    func testFullVSP2RecipeExecutionCapturesDeaconSummaryArtifact() async throws {
        guard await toolAvailable(.fastp), await toolAvailable(.seqkit),
              await toolAvailable(.deacon) else {
            try ToolAvailability.skipOrFail("Required tools not available")
        }
        guard let installedDatabase = await DatabaseRegistry.shared.effectiveDatabasePath(for: "deacon-panhuman") else {
            try ToolAvailability.skipOrFail("Deacon human-read removal index not installed")
        }
        _ = try ConformanceFixtures.installedManagedDatabaseFile(id: "deacon-panhuman", path: installedDatabase)
        guard let fixtures = fixturesDir else { throw XCTSkip("Test fixtures not found") }

        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })
        let engine = RecipeEngine()

        let r1 = fixtures.appendingPathComponent("test_1.fastq.gz")
        let r2 = fixtures.appendingPathComponent("test_2.fastq.gz")
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let input = StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        let context = StepContext(
            workspace: workspace,
            threads: 2,
            sampleName: "sarscov2-vsp2-summary",
            runner: NativeToolRunner.shared,
            progress: { _, _ in }
        )

        let result = try await engine.execute(recipe: vsp2, input: input, context: context)
        let deaconStep = try XCTUnwrap(result.stepRecords.first { $0.tool == "deacon" })
        let summaryPath = try XCTUnwrap(deaconStep.auxiliaryOutputPaths.first)
        let summaryURL = URL(fileURLWithPath: summaryPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        XCTAssertEqual(deaconStep.commandArguments?.contains("--summary"), true)
        XCTAssertTrue(deaconStep.commandArguments?.contains(summaryURL.path) == true)

        let data = try Data(contentsOf: summaryURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["deplete"] as? Bool, true)
        XCTAssertEqual(json["seqs_in"] as? Int, 200)
        XCTAssertNotNil(json["seqs_removed"])
    }
}
