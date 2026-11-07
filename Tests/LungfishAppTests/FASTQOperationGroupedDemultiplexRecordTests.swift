// FASTQOperationGroupedDemultiplexRecordTests.swift - The app keeps the command line's record of a demultiplex run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane EXACTBARE-WORDS, finding 1. The Operations row says that a run could not check for chance matches by
// reading the run's record, which `lungfish-cli fastq demultiplex` writes with `chanceCheck` (Exact Bare Barcode) or with
// `chanceFloor` (the other engines). After the command exits the app writes a record of its own over a grouped result's
// folder when the record there does not name every output (`FASTQOperationPlanner.ensureGroupedResultProvenance`), and
// that record has neither key. These cases give the planner the folder as a real demultiplex leaves it, the sample
// bundles, the Unassigned bundle and the manifest, with the record the command writes at `FastqCommand.swift`
// (`CLIProvenanceSupport.recordSingleStepRun` over `[manifest] + the primary file of each bundle`), and check that the
// record on disk is the command line's afterwards.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQOperationGroupedDemultiplexRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQGroupedDemux")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The block `FastqCommand` writes under `chanceFloor` for a run whose engine takes a floor.
    private static let chanceFloor: ParameterValue = .dictionary([
        "kitTail": .number(1e-6), "chanceTrials": .integer(2_000), "null": .string("random-bases"), "margin": .number(1),
        "compositionReads": .integer(0), "barcodesWithinChance": .dictionary(["bc02": .integer(3)]),
    ])

    /// The folder of a demultiplex run, the request that made it and the bundles the app discovers in it.
    private struct DemultiplexRun {
        let request: FASTQOperationLaunchRequest
        let invocation: FASTQCLIInvocation
        let folder: URL
        let bundles: [URL]
    }

    /// Two sample bundles and the Unassigned bundle, the manifest, and the record `fastq demultiplex` writes for them.
    /// `explicit` are the record's options, the keys under test among them.
    private func makeDemultiplexRun(explicit: [String: ParameterValue]) async throws -> DemultiplexRun {
        let input = root.appendingPathComponent("Project.lungfish/reads.fastq")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: input, readCount: 6, readLength: 20)
        let sheet = root.appendingPathComponent("Project.lungfish/sheet.csv")
        try "bc01,ACGTACGT\nbc02,TTGGCCAA\n".write(to: sheet, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Project.lungfish/Analyses/demux-run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var payloads: [URL] = []
        for name in ["bc01", "bc02", "unassigned"] {
            let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: folder)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 2, readLength: 20, idPrefix: name)
            payloads.append(bundle.fastqURL)
        }
        let manifest = folder.appendingPathComponent(DemultiplexManifest.filename)
        try "{}\n".write(to: manifest, atomically: true, encoding: .utf8)

        let arguments = [input.path, "--kit", sheet.path, "--output", folder.path, "--engine", "exact-bare"]
        let parameters = explicit.merging([
            "input": .file(input), "kit": .string(sheet.path), "output": .file(folder), "engine": .string("exact-bare"),
        ]) { current, _ in current }
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq demultiplex",
            parameters: parameters,
            toolName: "lungfish fastq demultiplex",
            toolVersion: "2026.11",
            command: [CLICommandIdentity.executableName, "fastq", "demultiplex"] + arguments,
            inputs: [ProvenanceRecorder.fileRecord(url: input, format: .fastq, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: manifest, format: .json, role: .output)]
                + payloads.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
            exitCode: 0,
            wallTime: 1,
            stderr: nil,
            status: .completed,
            outputDirectory: folder
        )

        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "custom", customCSVPath: sheet.path, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .exactBareBarcode,
                trimBarcodes: false, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: [input],
            outputMode: .groupedResult
        )
        return DemultiplexRun(
            request: request,
            invocation: FASTQCLIInvocation(subcommand: "fastq demultiplex", arguments: arguments),
            folder: folder,
            // The bundles the dispatcher takes from the folder when the command reports none.
            bundles: FASTQOperationPlanner.discoverFASTQBundles(in: folder)
        )
    }

    private func runDispatcherStep(on run: DemultiplexRun) throws {
        try FASTQOperationPlanner().ensureGroupedResultProvenance(
            originalRequest: run.request,
            resolvedRequest: run.request,
            invocations: [run.invocation],
            invocationOutputs: [run.bundles],
            outputURLs: run.bundles,
            outputDirectory: run.folder
        )
    }

    /// Finding 1: the record on disk after the dispatcher's step still holds `chanceCheck` and the `chanceFloor` block.
    func testTheAppKeepsTheCommandLinesRecordOfADemultiplexRunWithItsChanceKeys() async throws {
        let run = try await makeDemultiplexRun(explicit: ["chanceCheck": .string("none"), "chanceFloor": Self.chanceFloor])
        XCTAssertEqual(
            run.bundles.map(\.lastPathComponent),
            ["bc01.\(FASTQBundle.directoryExtension)", "bc02.\(FASTQBundle.directoryExtension)",
             "unassigned.\(FASTQBundle.directoryExtension)"],
            "the folder holds the sample bundles and the Unassigned bundle"
        )
        let recordURL = run.folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let before = try Data(contentsOf: recordURL)

        try runDispatcherStep(on: run)

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.folder))
        XCTAssertEqual(record.toolName, "lungfish fastq demultiplex", "the record on disk is the command line's")
        XCTAssertEqual(record.options.explicit["chanceCheck"], .string("none"))
        XCTAssertEqual(record.options.explicit["chanceFloor"], Self.chanceFloor)
        XCTAssertEqual(try Data(contentsOf: recordURL), before, "the dispatcher wrote nothing over the command line's record")
    }
}
