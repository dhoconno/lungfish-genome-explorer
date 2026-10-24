// RecipeStepExitAndTimesTests.swift - Every tool step of a Mac recipe run records its exit status and times (CHTC C4-3 C-1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow

final class RecipeStepExitAndTimesTests: XCTestCase {
    /// Vote C4-3 C-1 (QV-9): the deacon scrub, the deacon rRNA filter and the fastp merge record the exit status, the
    /// standard error and the start and end times of their tool run, as the fused fastp step and the length filters do.
    /// Each result of the two parity recipes, run through the stand-in tools, holds exit status 0, standard error in the
    /// form the fused fastp step holds it, and a start no later than its end.
    func testDeaconAndMergeStepResultsRecordExitStatusAndTimes() async throws {
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
            // VSP2's rRNA step is switched off and listed with tool `none`, where it would have run.
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
            let records = result.stepRecords
            XCTAssertEqual(records.map(\.tool), tools, name)
            let fused = try XCTUnwrap(records.first, name)
            for (index, record) in records.enumerated() where record.tool != "none" {
                let label = "\(name) stepResults[\(index)] \(record.stepName) (\(record.tool))"
                XCTAssertEqual(record.exitStatus, 0, label)
                XCTAssertEqual(record.stderr == nil, fused.stderr == nil, "\(label) holds standard error as the fused fastp step does")
                let started = try XCTUnwrap(record.startedAt, "\(label) startedAt")
                let completed = try XCTUnwrap(record.completedAt, "\(label) completedAt")
                XCTAssertLessThanOrEqual(started, completed, label)
            }
        }
    }
}
