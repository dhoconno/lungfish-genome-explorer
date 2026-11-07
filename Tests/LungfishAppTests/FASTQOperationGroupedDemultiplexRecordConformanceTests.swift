// FASTQOperationGroupedDemultiplexRecordConformanceTests.swift - The app keeps the record of a real Exact Bare run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane EXACTBARE-WORDS, finding 1, the real-run form. FASTQOperationGroupedDemultiplexRecordTests gives the
// planner a folder it builds by hand. This case runs `lungfish-cli fastq demultiplex --engine exact-bare` for real, so the
// sample bundles, the Unassigned bundle, the manifest and the record are the command's own, takes the bundles the way the
// dispatcher does when the command reports none, and checks that the dispatcher's step leaves the command's record, with
// `chanceCheck: "none"`, as it was.
//
// A real-tool suite: it skips when managed seqkit is missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQOperationGroupedDemultiplexRecordConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "grouped-demux-record")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// 24 reads of 60 bases, 8 led by ATTACTCG, 8 by TCCGGAGA and 8 of random bases.
    private func writeLedReads(to url: URL) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var state: UInt64 = 3
        var text = ""
        for index in 0..<24 {
            var sequence = index < 8 ? "ATTACTCG" : (index < 16 ? "TCCGGAGA" : "")
            while sequence.count < 60 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                sequence.append(bases[Int((state >> 33) % 4)])
            }
            text += "@r\(index)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTheAppKeepsTheCommandLinesRecordOfARealExactBareRun() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("led.fastq")
        try writeLedReads(to: input)
        let sheet = project.appendingPathComponent("sheet.csv")
        try "S1,ATTACTCG\nS2,TCCGGAGA\n".write(to: sheet, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/exact", isDirectory: true)
        let arguments = [input.path, "--kit", sheet.path, "--output", output.path, "--engine", "exact-bare"]
        try await FastqDemultiplexSubcommand.parse(arguments).run()

        let recordURL = output.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let before = try Data(contentsOf: recordURL)
        let bundles = FASTQOperationPlanner.discoverFASTQBundles(in: output)
        XCTAssertGreaterThanOrEqual(bundles.count, 2, "the run made sample bundles: \(bundles.map(\.lastPathComponent))")

        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "custom", customCSVPath: sheet.path, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .exactBareBarcode,
                trimBarcodes: false, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: [input],
            outputMode: .groupedResult
        )
        try FASTQOperationPlanner().ensureGroupedResultProvenance(
            originalRequest: request,
            resolvedRequest: request,
            invocations: [FASTQCLIInvocation(subcommand: "fastq demultiplex", arguments: arguments)],
            invocationOutputs: [bundles],
            outputURLs: bundles,
            outputDirectory: output
        )

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.options.explicit["chanceCheck"], .string("none"), "toolName \(record.toolName)")
        XCTAssertEqual(try Data(contentsOf: recordURL), before, "the dispatcher wrote nothing over the command line's record")
    }
}
