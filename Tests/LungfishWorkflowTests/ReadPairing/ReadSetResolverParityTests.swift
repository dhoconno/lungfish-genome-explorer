// ReadSetResolverParityTests.swift - Single-only and pairs-only samples reach a tool as they do today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The contract keeps today's command for a sample that holds only single
// reads or only pairs. A tool that moves onto ReadSetResolver must get the
// same files ResolvedSequenceInputs gives it now, in the same order, the
// same mate pairing, no step and no new provenance key, whatever its
// capability.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadSetResolverParityTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-set-parity")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private static let capabilities: [ReadPairingCapability] = [
        .bothInOneRunAsSeparateFiles,
        .bothInOneRunAsNameInterleavedStream,
        .pairsOrSinglesPerRun,
        .pairsOnlyWhenAllPaired,
        .singleReadsOnly,
    ]

    /// Every fixture that holds only single reads or only pairs, physical
    /// and virtual.
    private var homogeneousInputs: [URL] {
        [
            fixtures.singleRoot,
            fixtures.interleavedRoot,
            fixtures.chunkedRoot,
            fixtures.namedPairChunkedRoot,
            fixtures.fullDerivative,
            fixtures.fullUnlabelled,
            fixtures.pairedDerivative,
            fixtures.fastaDerivative,
            fixtures.subsetOfSingle,
            fixtures.subsetOfInterleaved,
        ]
    }

    func testHomogeneousSamplesGetTodaysFilesWithNoStepForEveryCapability() async throws {
        for input in homogeneousInputs {
            let todayDirectory = root.appendingPathComponent("today-\(input.lastPathComponent)", isDirectory: true)
            let today = try await ResolvedSequenceInputs.resolve(
                inputURLs: [input],
                materializationDirectory: todayDirectory,
                materializer: fixtures.materializer
            )
            for capability in Self.capabilities {
                let directory = root.appendingPathComponent("plan-\(input.lastPathComponent)-\(capability.provenanceName.replacingOccurrences(of: "/", with: "-"))", isDirectory: true)
                let resolver = ReadSetResolver(materializationDirectory: directory, materializer: fixtures.materializer)
                let plan = try await resolver.plan(for: input, capability: capability)
                let label = "\(input.lastPathComponent) \(capability.provenanceName)"

                XCTAssertTrue(plan.steps.isEmpty, label)
                XCTAssertTrue(plan.recordsNothingNew, label)
                XCTAssertEqual(plan.provenanceParameters, [:], label)
                XCTAssertNil(plan.singleReadReason, label)
                XCTAssertEqual(plan.runs.count, 1, label)
                XCTAssertEqual(plan.wasMaterialized, today.didMaterialize, label)
                if today.didMaterialize {
                    // Materialized files have fresh names, so compare reads.
                    XCTAssertEqual(
                        try plan.executionURLs.map(ReadSetFixtures.readNames(in:)),
                        try today.executionInputURLs.map(ReadSetFixtures.readNames(in:)),
                        label
                    )
                } else {
                    XCTAssertEqual(plan.executionURLs, today.executionInputURLs, label)
                }
                let planPairsSeparateFiles = plan.matePairs.contains { if case .separate = $0.files { return true } else { return false } }
                if capability.kind != .singleReadsOnly {
                    XCTAssertEqual(planPairsSeparateFiles, today.resolvedAsMatePair, label)
                }
            }
        }
    }
}
