// FASTQClumpingRuleParityTests.swift - The Mac's clumping `auto` and the plan's follow one rule (CHTC C5 lane MOS1, O49, D5, D8 B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
@testable import LungfishWorkflow

/// The Mac's own `auto` follows the plan's rule (O49). Short reads clump with BBTools clumpify at the clumpify heap
/// whatever the size, ONT, PacBio and Unknown reads clump with nothing under `auto`, and a named tool wins. Both routes
/// record the same tool, source, reason and heap, and no estimate or threshold.
final class FASTQClumpingRuleParityTests: XCTestCase {
    private static let gib: Int64 = 1_073_741_824
    private static let mac64 = ExecutorPlanHostFacts(physicalMemoryBytes: 64 * gib, processorCount: 20)
    private static let project = URL(fileURLWithPath: "/tmp/mos1-project", isDirectory: true)

    /// What the pipeline returns for an import that resolved `resolution`.
    private func result(_ resolution: ClumpingToolResolution) -> FASTQIngestionResult {
        let ran = resolution.resolved != .none
        return FASTQIngestionResult(
            outputFile: URL(fileURLWithPath: "/tmp/mos1-out.fastq.gz"), wasClumpified: ran, qualityBinning: .illumina4,
            originalFilenames: ["a.fastq.gz"], originalSizeBytes: 1, finalSizeBytes: 1, pairingMode: .singleEnd,
            requestedClumpingTool: resolution.requested, resolvedClumpingTool: resolution.resolved,
            clumpingResolution: resolution, clumpifyHeapGB: ran ? Int(resolution.clumpifyHeapBytes / Self.gib) : nil
        )
    }

    /// QA 1 red test 1: `auto` over the budget resolves clumpify, the same tool and the same reason as under the budget.
    func testAutoOverTheBudgetResolvesClumpifyAtTheClumpifyHeap() {
        let small = ClumpingTool.auto.resolve(estimatedInputBytes: 10 * Self.gib, physicalMemoryBytes: 64 * Self.gib)
        let large = ClumpingTool.auto.resolve(estimatedInputBytes: 20 * Self.gib, physicalMemoryBytes: 64 * Self.gib)
        XCTAssertEqual(small.resolved, .bbtools)
        XCTAssertEqual(large.resolved, .bbtools, "the half-heap budget no longer decides, clumpify splits a large input into groups")
        XCTAssertEqual(large.reason, small.reason)
        XCTAssertTrue(large.reason.contains("at the clumpify heap"), large.reason)
        XCTAssertEqual(large.clumpifyHeapBytes, 22 * Self.gib)
    }

    /// QA 1 red test 2: an `auto` Mac import and an `auto` plan give equal clumping keys, small and large alike.
    func testAutoMacImportAndAutoPlanGiveEqualClumpingKeys() throws {
        for (label, estimate) in [("small", 10 * Self.gib), ("large", 20 * Self.gib)] {
            let config = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(.illumina))
            let resolution = config.clumpingTool.resolve(estimatedInputBytes: estimate, physicalMemoryBytes: 64 * Self.gib)
            let mac = FASTQBatchImporter.hostChoiceParameters(config: config, ingestionResult: result(resolution))
            let plan = try ExecutorPlanEmitter.clumpingChoice(requested: .auto, heapGB: 22, host: Self.mac64)

            XCTAssertEqual(resolution.requested.rawValue, plan.requested.rawValue, label)
            XCTAssertEqual(resolution.resolved.rawValue, plan.resolved.rawValue, label)
            XCTAssertEqual(mac["resolvedClumpingToolSource"], .string(plan.resolvedSource.rawValue), label)
            XCTAssertEqual(mac["clumpingResolutionReason"], .string(plan.reason), label)
            XCTAssertEqual(mac["clumpingPlanHeapBytes"], .integer(Int(plan.heapBytes)), label)
            XCTAssertEqual(mac["clumpingEstimatedInputBytes"], .null, "\(label): the plan has no estimate")
            XCTAssertEqual(mac["clumpingThresholdBytes"], .null, "\(label): the plan has no threshold")
            XCTAssertEqual(mac["clumpifyHeapSource"], .string("host"), "\(label): the heap keeps its own source")
        }
    }

    /// A named tool keeps the host's measured values on the Mac, and its source is `option`.
    func testNamedToolKeepsItsMeasuredBasisAndOptionSource() {
        let config = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(.illumina), clumpingTool: .bbtools)
        let resolution = config.clumpingTool.resolve(estimatedInputBytes: 10 * Self.gib, physicalMemoryBytes: 64 * Self.gib)
        let mac = FASTQBatchImporter.hostChoiceParameters(config: config, ingestionResult: result(resolution))
        XCTAssertEqual(mac["resolvedClumpingToolSource"], .string("option"))
        XCTAssertEqual(mac["clumpingResolutionReason"], .string("explicit clumping tool selection"))
        XCTAssertEqual(mac["clumpingEstimatedInputBytes"], .integer(Int(10 * Self.gib)))
        XCTAssertEqual(mac["clumpingThresholdBytes"], .integer(Int(11 * Self.gib)))
    }

    /// QA 1 red test 3, the Mac route: ONT, PacBio and Unknown `auto` stay `auto` and clump nothing, short reads clump.
    func testMacAutoForLongReadsAndUnknownClumpsNothingAndShortReadsClump() {
        for platform in [LungfishIO.SequencingPlatform.oxfordNanopore, .pacbio, .unknown] {
            let config = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(platform))
            XCTAssertEqual(config.clumpingTool, .auto, platform.rawValue)
            XCTAssertFalse(config.optimizeStorage, platform.rawValue)
            let asked = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(platform), optimizeStorage: true)
            XCTAssertFalse(asked.optimizeStorage, "\(platform.rawValue): asking for storage optimisation names no tool, so auto decides")
        }
        for platform in [LungfishIO.SequencingPlatform.illumina, .element, .mgi, .ultima] {
            let config = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(platform))
            XCTAssertEqual(config.clumpingTool, .auto, platform.rawValue)
            XCTAssertTrue(config.optimizeStorage, platform.rawValue)
        }
    }

    /// D8 B: a named tool wins on every platform with source `option`, and a refusal stays a refusal.
    func testNamedToolWinsOnLongReadsAndNoOptimizeStorageStillStores() {
        for platform in [LungfishIO.SequencingPlatform.oxfordNanopore, .pacbio, .unknown] {
            let named = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(platform), clumpingTool: .bbtools)
            XCTAssertEqual(named.clumpingTool, .bbtools, platform.rawValue)
            XCTAssertTrue(named.optimizeStorage, platform.rawValue)
            XCTAssertEqual(named.clumpingToolSource, .option, platform.rawValue)
        }
        let refused = FASTQBatchImporter.ImportConfig(projectDirectory: Self.project, platform: .given(.illumina), optimizeStorage: false)
        XCTAssertEqual(refused.clumpingTool, ClumpingTool.none)
        XCTAssertFalse(refused.optimizeStorage)
    }

    /// SW:13, D5: a base record holds both basis values as numbers, a newer one holds none. Absent reads absent, never 0,
    /// and an `auto` resolution encodes neither key.
    func testAResolutionRecordDecodesAbsentBasisValuesAsAbsentAndNeverZero() throws {
        let absent = Data(#"{"requested":"auto","resolved":"bbtools","physicalMemoryBytes":68719476736,"clumpifyHeapBytes":23622320128,"reason":"r"}"#.utf8)
        let newer = try JSONDecoder().decode(ClumpingToolResolution.self, from: absent)
        XCTAssertNil(newer.estimatedInputBytes)
        XCTAssertNil(newer.thresholdBytes)

        let base = Data(#"{"requested":"bbtools","resolved":"bbtools","estimatedInputBytes":5,"physicalMemoryBytes":68719476736,"clumpifyHeapBytes":23622320128,"thresholdBytes":7,"reason":"explicit clumping tool selection"}"#.utf8)
        let decoded = try JSONDecoder().decode(ClumpingToolResolution.self, from: base)
        XCTAssertEqual(decoded.estimatedInputBytes, 5)
        XCTAssertEqual(decoded.thresholdBytes, 7)

        let auto = ClumpingTool.auto.resolve(estimatedInputBytes: 20 * Self.gib, physicalMemoryBytes: 64 * Self.gib)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(auto)) as? [String: Any])
        XCTAssertNil(object["estimatedInputBytes"])
        XCTAssertNil(object["thresholdBytes"])
        XCTAssertEqual(try JSONDecoder().decode(ClumpingToolResolution.self, from: JSONEncoder().encode(auto)), auto)
    }
}
