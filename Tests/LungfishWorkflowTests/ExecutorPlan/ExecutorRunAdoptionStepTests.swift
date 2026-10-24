// ExecutorRunAdoptionStepTests.swift - The adopted record's pairing, logical step counts and storage launches as the Mac's (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
@testable import LungfishWorkflow

final class ExecutorRunAdoptionStepTests: XCTestCase {
    private let env = "/opt/conda/envs/bbtools/bin/"
    private let time = "2026-10-24T12:00:00.000Z"

    private func record(_ id: String, tool: String, argv: [String], storage: ExecutorStorageDetails? = nil) -> ExecutorStepRecord {
        ExecutorStepRecord(
            id: id, kind: storage == nil ? .recipe : .storage,
            tool: ExecutorToolRecord(id: tool, version: "1.0", build: "h1", path: argv[0]), outcome: .succeeded, argv: argv,
            environmentNames: ["PATH"], graceSeconds: 30, deadlineSeconds: 7200, toolExitCode: 0, startedAt: time, endedAt: time,
            wallSeconds: 1, qualityCounts: nil, storage: storage
        )
    }

    private func launch(_ tool: String, _ arguments: [String], groups: Int? = nil) -> ExecutorStorageLaunch {
        ExecutorStorageLaunch(
            tool: ExecutorToolRecord(id: tool, version: tool == "bgzip" ? "1.24" : "39.13", build: "h1", path: env + tool),
            argv: [env + tool] + arguments, environmentNames: ["PATH"], outcome: .succeeded, toolExitCode: 0, wallSeconds: 1,
            stderrPath: "work/\(tool).stderr", clumpifyGroups: groups
        )
    }

    /// QV-12 and QV-13: the Mac counts the logical length-filter step over its whole input, the merged reads and each
    /// mate of the unmerged pairs, so the lane's VSP2 record gives 950521 and 950309.
    func testAdoptCountsLogicalStepAsMac() {
        var merged = record("recipe-4", tool: "seqkit", argv: ["/env/seqkit", "seq", "-j", "1", "-m", "50", "work/m.fq.gz", "-o", "work/l.fq.gz"])
        merged.inputReadCount = 750015
        merged.outputReadCount = 749927
        var pairs = record("recipe-4-2", tool: "fastp", argv: ["/env/fastp", "-i", "work/u_R1.fq.gz", "-I", "work/u_R2.fq.gz", "-l", "50"])
        pairs.inputReadCount = 100253
        pairs.outputReadCount = 100191
        XCTAssertEqual(ExecutorRunAdoption.logicalReadCount([merged, pairs]) { $0.inputReadCount.map(Int.init) }, 950521)
        XCTAssertEqual(ExecutorRunAdoption.logicalReadCount([merged, pairs]) { $0.outputReadCount.map(Int.init) }, 950309)
        pairs.outputReadCount = nil
        XCTAssertNil(ExecutorRunAdoption.logicalReadCount([merged, pairs]) { $0.outputReadCount.map(Int.init) })
    }

    /// QV-5: after a merging recipe the adopt records the pairing of the mixed output, as the Mac does.
    func testAdoptRecordsMixedOutputPairingAsMac() {
        let imported = FASTQBatchImporter.RecordedPairing(mode: .interleaved, source: .explicit)
        let mixed = ExecutorRunAdoption.recordedPairing(
            imported: imported, recipeRan: true,
            mixedLayout: RecipeMixedLayoutCounts(mergedReads: 749927, pairs: 100191, unpairedReads: 0)
        )
        XCTAssertEqual(mixed.mode, .singleEnd)
        XCTAssertEqual(mixed.source, .detected)
        let pairsOnly = ExecutorRunAdoption.recordedPairing(
            imported: imported, recipeRan: true, mixedLayout: RecipeMixedLayoutCounts(mergedReads: 0, pairs: 10, unpairedReads: 0)
        )
        XCTAssertEqual(pairsOnly.mode, .interleaved)
        XCTAssertEqual(pairsOnly.source, .detected)
        let noLayout = ExecutorRunAdoption.recordedPairing(imported: imported, recipeRan: true, mixedLayout: nil)
        XCTAssertEqual(noLayout.mode, .interleaved)
        XCTAssertEqual(noLayout.source, .explicit)
    }

    /// QV-14, QV-15, QV-19: the storage step's two clumpify launches and its writer become three envelope steps with the
    /// record's argv and the environment each ran from, the writer probe none, and the command line joins the two
    /// clumpify launches as the Mac's does.
    func testAdoptWritesStorageLaunchesAsMac() throws {
        let pairs = launch("clumpify.sh", ["in=.clumpify-split-X/pairs.fastq", "out=.clumpify-split-X/pairs.clumped.fastq", "interleaved=t"], groups: 1)
        let unpaired = launch("clumpify.sh", ["in=.clumpify-split-X/unpaired.fastq", "out=.clumpify-split-X/unpaired.clumped.fastq", "interleaved=f"], groups: 1)
        let writer = launch("bgzip", ["-@", "1", "-c", ".clumpify-split-X/combined.fastq"])
        let storage = ExecutorStorageDetails(
            clumpingRan: true, qualityBinning: .illumina4, inputBytes: 10, outputBytes: 5,
            launches: [launch("bgzip", ["-h"]), pairs, unpaired, writer]
        )
        let step = record("storage", tool: "clumpify.sh", argv: pairs.argv, storage: storage)
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(step, parent: UUID()))
        XCTAssertEqual(steps.map(\.toolName), ["clumpify.sh", "clumpify.sh", "bgzip"])
        XCTAssertEqual(steps.map(\.command), [pairs.argv, unpaired.argv, writer.argv])
        XCTAssertEqual(steps.map { $0.managedToolID?.rawValue }, ["bbtools", "bbtools", "bbtools"])
        guard case .integer(let groups)? = steps[0].resolvedOptions?["clumpifyGroups"] else {
            return XCTFail("the clumpify step carries no group count: \(String(describing: steps[0].resolvedOptions))")
        }
        XCTAssertEqual(groups, 1)
        XCTAssertEqual(
            ExecutorRunAdoption.processingCommandLine(step),
            pairs.argv.joined(separator: " ") + " && " + unpaired.argv.joined(separator: " ")
        )
        XCTAssertNil(ExecutorRunAdoption.storageLaunchSteps(record("recipe-1", tool: "fastp", argv: ["/env/fastp"]), parent: UUID()))
    }
}
