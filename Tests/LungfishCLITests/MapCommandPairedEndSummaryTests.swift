// MapCommandPairedEndSummaryTests.swift - The map summary states the pairing the run used
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Final review A, N6. `lungfish-cli map` printed "Paired-end: no" for a
// sample of merged reads and pairs whose pairs map as pairs, and for an
// interleaved file every mapper pairs. The row read the request's R1 and R2
// flag. It now states the pairing of the run's read layout plan, the value
// the Map Reads window's Run Settings show for the same run.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MapCommandPairedEndSummaryTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "map-paired-end-summary")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testThePairedEndRowStatesThePairingTheRunUsed() async throws {
        let cases: [(label: String, bundle: URL, expected: String)] = [
            ("L1 single", fixtures.singleRoot, "no"),
            ("L5b paired", fixtures.pairedDerivative, "yes"),
            ("L2 interleaved", fixtures.interleavedRoot, "yes (interleaved)"),
            ("L3 merged reads and pairs", fixtures.mixedRoot, "yes (pairs; merged reads mapped as single reads)"),
        ]
        var actual: [String: String] = [:]
        var wanted: [String: String] = [:]
        for (label, bundle, expected) in cases {
            for tool in MappingTool.allCases {
                let key = "\(label) \(tool.rawValue)"
                let request = try await resolvedRequest(bundle, tool: tool)
                actual[key] = MapCommand.pairedEndSummary(for: request)
                wanted[key] = expected
            }
        }
        XCTAssertEqual(actual, wanted)
    }

    /// The request `lungfish-cli map` runs for `bundle`.
    private func resolvedRequest(_ bundle: URL, tool: MappingTool) async throws -> MappingRunRequest {
        let reference = root.appendingPathComponent("reference.fasta")
        if !FileManager.default.fileExists(atPath: reference.path) {
            try ">ref\nACGTACGTACGTACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        }
        let resolved = try await MappingInputResolver.resolve(
            request: MappingRunRequest(
                tool: tool,
                modeID: tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id,
                inputFASTQURLs: [bundle],
                referenceFASTAURL: reference,
                outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
                sampleName: bundle.deletingPathExtension().lastPathComponent,
                threads: 2,
                compatibilityReadClassOverride: .illuminaShortReads
            ),
            materializer: fixtures.materializer
        )
        return resolved.request
    }
}
