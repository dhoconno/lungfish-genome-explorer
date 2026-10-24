// RecipeStepExitAndTimesTests.swift - Every tool step of a Mac recipe run records its exit status and times (CHTC C4-3 C-1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RecipeStepExitAndTimesTests: XCTestCase {
    /// Runs the two parity recipes through the stand-in tools and hands each one's name, its tools in order, its step
    /// results (the sidecar's half) and the folder it ran in to `check`. VSP2's rRNA step is switched off and listed with
    /// tool `none`, where it would have run.
    private func forEachParityRecipe(
        _ check: (_ name: String, _ tools: [String], _ records: [RecipeStepResult], _ root: URL) throws -> Void
    ) async throws {
        let root = try TestTempDirectory.make(prefix: "RecipeStepExit")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("pair", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pair = [folder.appendingPathComponent("S_R1.fastq"), folder.appendingPathComponent("S_R2.fastq")]
        try "@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: pair[0], atomically: true, encoding: .utf8)
        try "@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n".write(to: pair[1], atomically: true, encoding: .utf8)
        var indexes: [String: URL] = [:]
        for (id, name) in [("test-panhuman", "panhuman-1.k31w15.idx"), ("deacon-ribokmers", "ribokmers.k31w15.idx")] {
            let databaseFolder = root.appendingPathComponent("databases/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: databaseFolder, withIntermediateDirectories: true)
            let index = databaseFolder.appendingPathComponent(name)
            try Data("deacon index \(id)".utf8).write(to: index)
            indexes[id] = index
        }
        let runner = try RecipeToolFakes.runner(root: root)
        let builtin = RecipeRegistryV2.builtinRecipes()
        let expectedTools = [
            "vsp2-target-enrichment": ["fastp", "deacon", "none", "fastp", "seqkit", "fastp"],
            "wastewater-metagenomics": ["fastp", "deacon", "deacon", "fastp", "seqkit", "fastp"],
        ]
        for (name, tools) in expectedTools.sorted(by: { $0.key < $1.key }) {
            var merged = try XCTUnwrap(RecipeResolver.resolve(name, in: builtin), name)
            for index in merged.steps.indices where merged.steps[index].type == "deacon-scrub" {
                merged.steps[index].params?["database"] = .string("test-panhuman")
            }
            let (input, work) = try RecipeToolFakes.layOutWorkRoot(root: root, pair)
            let result = try await RecipeEngine().execute(
                recipe: merged, input: input,
                context: StepContext(workspace: work, threads: 1, sampleName: "sample", runner: runner,
                                     databasePaths: indexes, progress: { _, _ in })
            )
            try check(name, tools, result.stepRecords, root)
        }
    }

    /// Vote C4-3 C-1 (QV-9): the deacon scrub, the deacon rRNA filter and the fastp merge record the exit status, the
    /// standard error and the start and end times of their tool run, as the fused fastp step and the length filters do.
    /// Each result of the two parity recipes, run through the stand-in tools, holds exit status 0, standard error (the
    /// key present, since the tool's text is never compared) and a start no later than its end.
    func testDeaconAndMergeStepResultsRecordExitStatusAndTimes() async throws {
        try await forEachParityRecipe { name, tools, records, _ in
            XCTAssertEqual(records.map(\.tool), tools, name)
            for (index, record) in records.enumerated() where record.tool != "none" {
                let label = "\(name) stepResults[\(index)] \(record.stepName) (\(record.tool))"
                XCTAssertEqual(record.exitStatus, 0, label)
                // AMV2 ARCH fix 1: the key is present. The relative form (`record.stderr == nil` against the fused step's)
                // passed when the fused step held nil as well.
                XCTAssertNotNil(record.stderr, label)
                let started = try XCTUnwrap(record.startedAt, "\(label) startedAt")
                let completed = try XCTUnwrap(record.completedAt, "\(label) completedAt")
                XCTAssertLessThanOrEqual(started, completed, label)
            }
        }
    }

    /// Vote C4-3 C-1 and C4-10's form (AMV2 ARCH fix 1, QA fix 2): the envelope half. `recipeProvenanceSteps` writes each
    /// result into the Mac envelope, where the deacon steps and the fastp merge step gain `exitCode` 0 and `stderr`, both
    /// absent before, and hold the run's clock in `startTime` and `endTime` instead of a time taken at the write. XC-6 B:
    /// the standard error and the times are run-varying, so each is checked present and never compared with the other route's.
    func testDeaconAndMergeEnvelopeStepsCarryExitStatusStderrAndTimes() async throws {
        try await forEachParityRecipe { name, tools, records, root in
            let ran = records.filter { $0.tool != "none" }
            let steps = FASTQBatchImporter.recipeProvenanceSteps(
                recipeStepResults: records, originalInputURLs: [], bundleFASTQURL: root.appendingPathComponent("S.fastq.gz")
            )
            XCTAssertEqual(steps.map(\.toolName), ran.map(\.tool), "\(name): one envelope step for each step that ran")
            XCTAssertEqual(steps.map(\.toolName), tools.filter { $0 != "none" }, name)
            // The merge step is the second fastp step of the recipe, after the fused one.
            let merge = steps.indices.filter { steps[$0].toolName == "fastp" }.dropFirst().first
            XCTAssertNotNil(merge, "\(name): the merge fastp step")
            var checked = 0
            for (index, step) in steps.enumerated() where step.toolName == "deacon" || index == merge {
                let label = "\(name) envelope steps[\(index)] \(step.toolName)"
                XCTAssertEqual(step.exitCode, 0, "\(label) exitCode")
                XCTAssertNotNil(step.stderr, "\(label) stderr")
                let end = try XCTUnwrap(step.endTime, "\(label) endTime")
                XCTAssertLessThanOrEqual(step.startTime, end, label)
                // The times are the sidecar result's own clock, never an estimate taken at the write.
                XCTAssertEqual(step.startTime, ran[index].startedAt, "\(label) startTime is the run's start")
                XCTAssertEqual(end, ran[index].completedAt, "\(label) endTime is the run's end")
                checked += 1
            }
            XCTAssertEqual(checked, tools.filter { $0 == "deacon" }.count + 1, "\(name): every deacon step and the merge step")
        }
    }
}
