// FASTQDemultiplexGroupedInputsConformanceTests.swift - A real cutadapt grouped demultiplex of two datasets holds both
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane FIX-GROUP, backlog DEMUX-GROUPED-DROPS-INPUTS (S1). The smallest input from the review of
// FIX-FLOOR (BIO): two bundles of one 60-base read each, S1 `GTATCGTCGT` at the 5' end and its reverse complement at the
// 3' end, a sheet with S1 only, both ends, error rate 0.15, Output Strategy Grouped Result. It runs the dialog's request
// through `FASTQOperationExecutionService` and the built `lungfish-cli` with managed cutadapt, as the window does
// (`MainSplitViewController+GenomicsDisplay.swift`), and counts the reads of S1 in the result. The base ran one command
// that named poolA, so S1 held 1 read in all. `FASTQDemultiplexGroupedInputsTests` is its stand-in, which needs no tool.
//
// It skips when cutadapt or the built CLI is missing, and fails then under LUNGFISH_REQUIRE_TOOLS=1.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQDemultiplexGroupedInputsConformanceTests: XCTestCase {
    private var root: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        guard let built = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            try ToolAvailability.skipOrFail("no lungfish-cli is built beside the test bundle")
        }
        cli = built
        root = try TestTempDirectory.make(prefix: "demux-grouped-inputs")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
    }

    private static let (s1, s1RC) = ("GTATCGTCGT", "ACGACGATAC")

    /// A reads bundle in `project` of one 60-base read: S1 at the 5' end, random bases from `seed`, S1's reverse
    /// complement at the 3' end, so a 5', 3' or both-ends search finds it.
    private func makePool(_ name: String, seed: UInt64, in project: URL) throws -> URL {
        var state = seed
        var read = Self.s1
        while read.count < 60 - Self.s1RC.count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            read += ["A", "C", "G", "T"][Int((state >> 33) % 4)]
        }
        read += Self.s1RC
        let bundle = project.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let text = "@\(name)-read\n\(read)\n+\n\(String(repeating: "I", count: 60))\n"
        try text.write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// The reads of sample `S1` in the demultiplex result at `folder`, by the folder that holds the manifest, relative
    /// to `run` ("." for the run folder itself). A folder with no manifest is not listed.
    private func s1Reads(under run: URL) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let folders = [run] + (try FileManager.default.contentsOfDirectory(
            at: run, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        for folder in folders {
            guard let manifest = DemultiplexManifest.load(from: folder) else { continue }
            let name = folder == run ? "." : folder.lastPathComponent
            counts[name] = manifest.barcodes.first { $0.barcodeID == "S1" }?.readCount ?? 0
        }
        return counts
    }

    func testAGroupedRealCutadaptDemultiplexOfTwoPoolsHoldsTheReadsOfBoth() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        let cli = try XCTUnwrap(cli)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let pools = [try makePool("poolA", seed: 7, in: project), try makePool("poolB", seed: 8, in: project)]
        let sheet = project.appendingPathComponent("sheet.csv")
        try "id,sequence\nS1,\(Self.s1)\n".write(to: sheet, atomically: true, encoding: .utf8)
        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "sheet", customCSVPath: sheet.path, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: pools, outputMode: .groupedResult
        )
        let run = analyses.appendingPathComponent("demultiplex-run", isDirectory: true)
        let service = FASTQOperationExecutionService(
            commandRunner: LungfishCLIProcessRunner(cliURLProvider: { cli }),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: analyses)
        )

        let result = try await service.execute(request: request, workingDirectory: run)

        XCTAssertEqual(result.executedInvocations.count, 2, "one command for each pool")
        for pool in pools {
            let naming = result.executedInvocations.filter { $0.arguments.contains(pool.path) }
            XCTAssertEqual(naming.count, 1, "\(pool.lastPathComponent) is in \(naming.count) commands")
        }
        let counts = try s1Reads(under: run)
        print("GROUPED-INPUTS s1Reads=\(counts.sorted { $0.key < $1.key }) container=\(result.groupedContainerURL?.lastPathComponent ?? "nil")")
        XCTAssertEqual(counts, ["poolA": 1, "poolB": 1], "S1 holds the read of each pool and nothing else is a result")
        XCTAssertEqual(counts.values.reduce(0, +), 2, "the reads of both pools are in sample S1")

        // The record at the run folder is the shell form of what ran (decision D2 of Phase 2.8): the commands of the
        // plans joined by `&&` on one line, where the Operations row holds a script of one line for each. Each part
        // parses with the real CLI parser and names one pool.
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run))
        let parts = try XCTUnwrap(envelope.reproducibleCommand).components(separatedBy: " && ")
        XCTAssertEqual(parts.count, 2, "one command for each pool: \(envelope.reproducibleCommand ?? "nil")")
        let recorded = try parts.map { try RecordedCLICommand.parse($0) }
        let inputs = recorded.compactMap { ($0 as? FastqDemultiplexSubcommand)?.input }
        XCTAssertEqual(inputs.sorted(), pools.map(\.path).sorted(), "the record names both pools")
    }
}
