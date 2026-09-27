// RecipeEngineTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

private final class RecipeProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []

    func record(_ label: String) {
        lock.withLock {
            labels.append(label)
        }
    }

    var eventCount: Int {
        lock.withLock { labels.count }
    }
}

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
        if case .fusedFastp(let args, _, _, let components) = plan[0] {
            XCTAssertTrue(args.contains("--dedup"),
                          "fused args should contain --dedup; got \(args)")
            XCTAssertTrue(args.contains("-q"),
                          "fused args should contain -q; got \(args)")
            XCTAssertTrue(args.contains("15"),
                          "fused args should contain quality value 15; got \(args)")
            XCTAssertEqual(
                components,
                [
                    RecipeLogicalComponent(
                        typeID: "fastp-dedup",
                        displayName: "PCR Duplicate Removal"
                    ),
                    RecipeLogicalComponent(
                        typeID: "fastp-trim",
                        displayName: "Adapter + Quality Trim"
                    ),
                ]
            )
        } else {
            XCTFail("Expected .fusedFastp, got \(plan[0])")
        }
    }

    func testPlanFusedFastpUsesRecipeLabelsForLogicalComponents() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup", label: "VSP2 duplicate removal"),
            RecipeStep(type: "fastp-trim", label: "VSP2 adapter trimming"),
        ])

        let plan = try RecipeEngine().plan(recipe: recipe, inputFormat: .pairedR1R2)
        guard case .fusedFastp(_, _, _, let components) = try XCTUnwrap(plan.first) else {
            return XCTFail("Expected a fused fastp plan")
        }

        XCTAssertEqual(
            components,
            [
                RecipeLogicalComponent(typeID: "fastp-dedup", displayName: "VSP2 duplicate removal"),
                RecipeLogicalComponent(typeID: "fastp-trim", displayName: "VSP2 adapter trimming"),
            ]
        )
    }

    func testPlanDoesNotFuseAcrossNonFastp() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup"),
            RecipeStep(type: "deacon-scrub"),
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
        ])
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // 3 separate steps (no fusion), then the merged→mixed normalization
        XCTAssertEqual(plan.count, 4,
                       "Expected 3 steps + normalization but got \(plan.count): \(plan.map { "\($0)" })")
        for entry in plan.prefix(3) {
            guard case .singleStep = entry else { return XCTFail("Expected an unfused step, got \(entry)") }
        }
        guard case .formatConversion(.merged, .mixed) = plan[3] else {
            return XCTFail("Expected merged→mixed normalization last, got \(plan[3])")
        }
    }

    func testPlanKeepsMergedLayoutThroughLengthFilterThenWritesMixedFile() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
            RecipeStep(type: "seqkit-length-filter", params: ["minLength": .int(50)]),
        ])
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // merge + length-filter (on the three-file layout) + conversion(merged→mixed) = 3.
        // Flattening to single BEFORE the filter is the bug: it separates every
        // mate from its partner and the per-record filter then leaves orphans.
        XCTAssertEqual(plan.count, 3,
                       "Expected 3 plan entries but got \(plan.count): \(plan.map { "\($0)" })")
        guard case .singleStep(let filter, _) = plan[1] else {
            return XCTFail("Expected the length filter at index 1, got \(plan[1])")
        }
        XCTAssertTrue(filter is SeqkitLengthFilterStep)
        if case .formatConversion(let from, let to) = plan[2] {
            XCTAssertEqual(from, .merged)
            XCTAssertEqual(to, .mixed)
        } else {
            XCTFail("Expected .formatConversion at index 2, got \(plan[2])")
        }
    }

    func testPlanWritesMixedFileWhenMergeIsTheLastStep() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
        ])
        let plan = try RecipeEngine().plan(recipe: recipe, inputFormat: .pairedR1R2)
        XCTAssertEqual(plan.count, 2)
        guard case .formatConversion(.merged, .mixed) = plan[1] else {
            return XCTFail("Expected merged→mixed normalization, got \(plan[1])")
        }
        XCTAssertEqual(try RecipeEngine().reportableStepCount(recipe: recipe, inputFormat: .pairedR1R2), 1)
    }

    func testPlanKeepsMergeWithoutUnmergedReadsSingle() throws {
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(20), "keepUnmerged": .bool(false)]),
        ])
        let plan = try RecipeEngine().plan(recipe: recipe, inputFormat: .pairedR1R2)
        XCTAssertEqual(plan.count, 1, "single-end merge output needs no normalization")
    }

    func testLengthFilterFormatsFollowTheInputLayout() throws {
        let step = try SeqkitLengthFilterStep(params: ["minLength": .int(50)])
        XCTAssertEqual(step.inputFormat(for: .merged), .merged)
        XCTAssertEqual(step.outputFormat(for: .merged), .merged)
        XCTAssertEqual(step.inputFormat(for: .pairedR1R2), .pairedR1R2)
        XCTAssertEqual(step.outputFormat(for: .pairedR1R2), .pairedR1R2)
        XCTAssertEqual(step.inputFormat(for: .single), .single)
        XCTAssertEqual(step.outputFormat(for: .single), .single)
    }

    func testLengthFilterPairArgumentsJudgeBothMatesTogether() {
        let root = URL(fileURLWithPath: "/tmp/lf")
        let args = SeqkitLengthFilterStep.fastpPairArguments(
            r1: root.appendingPathComponent("R1.fq.gz"),
            r2: root.appendingPathComponent("R2.fq.gz"),
            outR1: root.appendingPathComponent("out_R1.fq.gz"),
            outR2: root.appendingPathComponent("out_R2.fq.gz"),
            minLength: 50, maxLength: 300, threads: 3
        )
        // One paired fastp run: a pair is dropped when either mate fails.
        XCTAssertEqual(Array(args.prefix(8)), ["-i", "/tmp/lf/R1.fq.gz", "-I", "/tmp/lf/R2.fq.gz",
                                              "-o", "/tmp/lf/out_R1.fq.gz", "-O", "/tmp/lf/out_R2.fq.gz"])
        XCTAssertTrue(args.contains("-A") && args.contains("-G") && args.contains("-Q"),
                      "only length may decide: no adapter, poly-G, or quality filtering")
        XCTAssertFalse(args.contains("-L"), "length filtering must stay enabled")
        XCTAssertEqual(args.firstIndex(of: "-l").map { args[$0 + 1] }, "50")
        XCTAssertEqual(args.firstIndex(of: "--length_limit").map { args[$0 + 1] }, "300")
        XCTAssertEqual(args.firstIndex(of: "-w").map { args[$0 + 1] }, "3")
    }

    // MARK: - Mixed layout

    private func writeFASTQ(_ records: [(String, String)], to url: URL) throws {
        let text = records.map { "@\($0.0)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
        try Data(text.utf8).write(to: url)
    }

    private func headers(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .filter { $0.offset % 4 == 0 }
            .map { String($0.element) }
    }

    private func makeMixedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeEngineMixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testMixedLayoutWritesMergedReadsThenEachPairAdjacent() async throws {
        let root = try makeMixedRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let merged = root.appendingPathComponent("merged.fastq")
        let r1 = root.appendingPathComponent("unmerged_R1.fastq")
        let r2 = root.appendingPathComponent("unmerged_R2.fastq")
        let output = root.appendingPathComponent("mixed.fastq")
        try writeFASTQ([("M1 merged_120_30", "ACGTACGT"), ("M2 merged_100_10", "TTTTGGGG")], to: merged)
        try writeFASTQ([("a/1", "AAAA"), ("b/1", "CCCC")], to: r1)
        try writeFASTQ([("a/2", "GGGG"), ("b/2", "TTTT")], to: r2)

        let counts = try await RecipeEngine.writeMixedLayout(
            merged: merged, unmergedR1: r1, unmergedR2: r2, to: output)

        XCTAssertEqual(counts, RecipeMixedLayoutCounts(mergedReads: 2, pairs: 2, unpairedReads: 0))
        XCTAssertEqual(counts.totalRecords, 6)
        XCTAssertEqual(try headers(of: output),
                       ["@M1 merged_120_30", "@M2 merged_100_10", "@a/1", "@a/2", "@b/1", "@b/2"])
        // The storage clumpify plan and every consumer scan this file by name:
        // the old concatenation (M1 M2 a/1 b/1 a/2 b/2) reported 0 pairs + 6 unpaired.
        XCTAssertEqual(try FASTQPairInterleaver.countMixed(interleaved: output),
                       FASTQPairInterleaver.MixedCounts(pairs: 2, unpaired: 2))
    }

    func testMixedLayoutWithoutUnmergedFilesCopiesMergedReadsOnly() async throws {
        let root = try makeMixedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let merged = root.appendingPathComponent("merged.fastq")
        let output = root.appendingPathComponent("mixed.fastq")
        try writeFASTQ([("M1", "ACGT")], to: merged)

        let counts = try await RecipeEngine.writeMixedLayout(
            merged: merged, unmergedR1: nil, unmergedR2: nil, to: output)
        XCTAssertEqual(counts, RecipeMixedLayoutCounts(mergedReads: 1, pairs: 0))
        XCTAssertEqual(try headers(of: output), ["@M1"])
    }

    func testMixedLayoutRejectsUnmergedFilesThatAreOutOfStep() async throws {
        let root = try makeMixedRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let merged = root.appendingPathComponent("merged.fastq")
        let r1 = root.appendingPathComponent("unmerged_R1.fastq")
        let r2 = root.appendingPathComponent("unmerged_R2.fastq")
        let output = root.appendingPathComponent("mixed.fastq")
        try writeFASTQ([("M1", "ACGT")], to: merged)
        try writeFASTQ([("a/1", "AAAA"), ("b/1", "CCCC")], to: r1)
        try writeFASTQ([("b/2", "GGGG"), ("a/2", "TTTT")], to: r2)

        do {
            _ = try await RecipeEngine.writeMixedLayout(merged: merged, unmergedR1: r1, unmergedR2: r2, to: output)
            XCTFail("Out-of-step mates must not be written as a pair")
        } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let recordNumber, _, let r1Name, _, let r2Name) {
            XCTAssertEqual(recordNumber, 1)
            XCTAssertEqual(r1Name, "a/1")
            XCTAssertEqual(r2Name, "b/2")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a rejected layout leaves no partial file")
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

        XCTAssertEqual(plan.count, 4, "three steps plus the merged→mixed normalization")
        guard case .singleStep(let executor, let label) = plan[1] else {
            return XCTFail("Expected RiboDetector single step at index 1, got \(plan[1])")
        }
        XCTAssertTrue(executor is RiboDetectorStep)
        XCTAssertEqual(label, "Remove ribosomal RNA")
    }

    func testReportableStepCountUsesPhysicalVSP2Plan() throws {
        let recipe = try XCTUnwrap(
            RecipeRegistryV2.builtinRecipes().first { $0.id == "vsp2-target-enrichment" }
        )

        XCTAssertEqual(
            try RecipeEngine().reportableStepCount(recipe: recipe, inputFormat: .pairedR1R2),
            4,
            "The fused fastp invocation and three other tools are four physical progress steps"
        )
    }

    func testExecuteFusedFastpRetainsJSONAndActualExecutionEvidence() async throws {
        let root = try makeTemporaryDirectory(prefix: "RecipeEngineFusedFastp")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let (r1, r2) = try writePairedFASTQ(in: root)
        let runner = try makeFakeFastpRunner(in: root, report: .valid)
        let progress = RecipeProgressCollector()
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup"),
            RecipeStep(type: "fastp-trim"),
        ])

        let result = try await RecipeEngine().execute(
            recipe: recipe,
            input: StepInput(r1: r1, r2: r2, format: .pairedR1R2),
            context: StepContext(
                workspace: workspace,
                threads: 2,
                sampleName: "sample",
                runner: runner,
                progress: { _, label in progress.record(label) }
            )
        )

        XCTAssertEqual(progress.eventCount, 1, "Fused fastp should report one physical progress event")
        XCTAssertEqual(result.stepRecords.count, 1)
        let step = try XCTUnwrap(result.stepRecords.first)
        let reportPath = try XCTUnwrap(step.auxiliaryOutputPaths.first)
        let reportURL = URL(fileURLWithPath: reportPath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: reportURL.path))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)))

        let arguments = try XCTUnwrap(step.commandArguments)
        let jsonArgumentIndex = try XCTUnwrap(arguments.firstIndex(of: "-j"))
        XCTAssertEqual(arguments[arguments.index(after: jsonArgumentIndex)], reportURL.path)
        XCTAssertNotEqual(arguments[arguments.index(after: jsonArgumentIndex)], "/dev/null")
        let htmlArgumentIndex = try XCTUnwrap(arguments.firstIndex(of: "-h"))
        XCTAssertEqual(arguments[arguments.index(after: htmlArgumentIndex)], "/dev/null")

        XCTAssertEqual(step.logicalComponents.map(\.typeID), ["fastp-dedup", "fastp-trim"])
        XCTAssertEqual(step.executionOutputFiles.count, 2)
        XCTAssertEqual(
            Set(step.executionOutputFiles.map(\.path)),
            Set([result.output.r1.path, try XCTUnwrap(result.output.r2).path])
        )
        for output in step.executionOutputFiles {
            XCTAssertFalse(output.checksumSHA256.isEmpty)
            XCTAssertGreaterThan(output.sizeBytes, 0)
        }
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertEqual(
            step.stderr?.trimmingCharacters(in: .whitespacesAndNewlines),
            "fastp test stderr"
        )
        XCTAssertNotNil(step.startedAt)
        XCTAssertNotNil(step.completedAt)
        XCTAssertEqual(
            step.durationSeconds,
            step.effectiveDurationSeconds,
            accuracy: 0.001,
            "Timestamp-derived duration should be authoritative for the physical fastp process"
        )
    }

    func testExecuteFusedFastpRejectsSuccessfulProcessWithoutValidJSONReport() async throws {
        for report in [FakeFastpReport.missing, .invalid] {
            let root = try makeTemporaryDirectory(prefix: "RecipeEngineFusedFastp")
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let (r1, r2) = try writePairedFASTQ(in: root)
            let runner = try makeFakeFastpRunner(in: root, report: report)
            let recipe = makeRecipe(steps: [
                RecipeStep(type: "fastp-dedup"),
                RecipeStep(type: "fastp-trim"),
            ])

            do {
                _ = try await RecipeEngine().execute(
                    recipe: recipe,
                    input: StepInput(r1: r1, r2: r2, format: .pairedR1R2),
                    context: StepContext(
                        workspace: workspace,
                        threads: 2,
                        sampleName: "sample",
                        runner: runner,
                        progress: { _, _ in }
                    )
                )
                XCTFail("A successful fastp process with a \(report) JSON report must fail")
            } catch let RecipeEngineError.invalidRequiredReport(tool, path, _, evidence) {
                XCTAssertEqual(tool, "fastp")
                XCTAssertEqual(evidence.exitStatus, 0)
                XCTAssertEqual(
                    evidence.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    "fastp test stderr"
                )
                XCTAssertFalse(evidence.arguments.isEmpty)
                XCTAssertNotNil(evidence.startedAt)
                XCTAssertNotNil(evidence.completedAt)
                XCTAssertGreaterThanOrEqual(evidence.effectiveDurationSeconds, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: path))
                assertGeneratedFastpFilesWereCleaned(arguments: evidence.arguments)
            } catch {
                XCTFail("Expected evidenced JSON-report error, got \(error)")
            }
        }
    }

    func testExecuteFusedFastpNonzeroFailureCarriesEvidenceAndCleansOutputs() async throws {
        let root = try makeTemporaryDirectory(prefix: "RecipeEngineFusedFastpFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let (r1, r2) = try writePairedFASTQ(in: root)
        let runner = try makeFakeFastpRunner(in: root, report: .nonzero)
        let recipe = makeRecipe(steps: [
            RecipeStep(type: "fastp-dedup"),
            RecipeStep(type: "fastp-trim"),
        ])

        do {
            _ = try await RecipeEngine().execute(
                recipe: recipe,
                input: StepInput(r1: r1, r2: r2, format: .pairedR1R2),
                context: StepContext(
                    workspace: workspace,
                    threads: 2,
                    sampleName: "sample",
                    runner: runner,
                    progress: { _, _ in }
                )
            )
            XCTFail("Nonzero fastp must fail")
        } catch let RecipeEngineError.processFailed(tool, step, evidence) {
            XCTAssertEqual(tool, "fastp")
            XCTAssertTrue(step.contains("fused-fastp"))
            XCTAssertEqual(evidence.exitStatus, 23)
            XCTAssertTrue(evidence.stderr.contains("fastp deliberate failure"))
            XCTAssertTrue(evidence.arguments.contains("--dedup"))
            XCTAssertTrue(evidence.arguments.contains("-q"))
            XCTAssertNotNil(evidence.startedAt)
            XCTAssertNotNil(evidence.completedAt)
            XCTAssertGreaterThanOrEqual(evidence.effectiveDurationSeconds, 0)
            assertGeneratedFastpFilesWereCleaned(arguments: evidence.arguments)
        } catch {
            XCTFail("Expected evidenced process failure, got \(error)")
        }
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

    // MARK: - Fused fastp test runner

    private enum FakeFastpReport: CustomStringConvertible {
        case valid
        case missing
        case invalid
        case nonzero

        var description: String {
            switch self {
            case .valid: "valid"
            case .missing: "missing"
            case .invalid: "invalid"
            case .nonzero: "nonzero"
            }
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePairedFASTQ(in directory: URL) throws -> (r1: URL, r2: URL) {
        let r1 = directory.appendingPathComponent("sample_R1.fastq")
        let r2 = directory.appendingPathComponent("sample_R2.fastq")
        let r1Contents = "@pair1/1\nACGT\n+\nIIII\n"
        let r2Contents = "@pair1/2\nTGCA\n+\nIIII\n"
        try r1Contents.write(to: r1, atomically: true, encoding: .utf8)
        try r2Contents.write(to: r2, atomically: true, encoding: .utf8)
        return (r1, r2)
    }

    private func makeFakeFastpRunner(
        in homeDirectory: URL,
        report: FakeFastpReport
    ) throws -> NativeToolRunner {
        let executableDirectory = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/fastp/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("fastp")
        let reportCommand: String
        switch report {
        case .valid:
            reportCommand = #"printf '%s\n' '{"summary":{"before_filtering":{"total_reads":2}}}' > "$report""#
        case .missing:
            reportCommand = ":"
        case .invalid:
            reportCommand = #"printf '%s\n' 'not-json' > "$report""#
        case .nonzero:
            reportCommand = #"echo 'fastp deliberate failure' >&2; exit 23"#
        }
        let script = """
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "fastp 1.2.3"
          exit 0
        fi
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -i) in_r1="$2"; shift 2 ;;
            -I) in_r2="$2"; shift 2 ;;
            -o) out_r1="$2"; shift 2 ;;
            -O) out_r2="$2"; shift 2 ;;
            -j) report="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        /usr/bin/gzip -c "$in_r1" > "$out_r1"
        /usr/bin/gzip -c "$in_r2" > "$out_r2"
        \(reportCommand)
        echo "fastp test stderr" >&2
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory, appIdentity: .preview)
    }

    private func assertGeneratedFastpFilesWereCleaned(
        arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for flag in ["-o", "-O", "-j"] {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return XCTFail("Missing \(flag) in argv", file: file, line: line)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: arguments[index + 1]),
                "Rejected fastp output \(flag) should be cleaned",
                file: file,
                line: line
            )
        }
    }
}
