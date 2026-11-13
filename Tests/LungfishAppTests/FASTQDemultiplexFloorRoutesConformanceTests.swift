// FASTQDemultiplexFloorRoutesConformanceTests.swift - The floor's words on every route of a real Cutadapt demultiplex
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane FIX-FLOOR, backlog FLOOR-WINDOW-ROUTES-UNPROVEN (ruling BIO-PROBES-ASIF item 2). The window says the
// floor's two lines, the within-chance line and the not-in-pool limit (`FASTQDemultiplexChanceNotice+Floor.swift`), and
// they are the words that make DEMUX-FLOOR-DECOY-MAX and DEMUX-FLOOR-SATURATED-KIT Known limits. This runs the dialog's
// request through `FASTQOperationExecutionService` and the built `lungfish-cli` with managed cutadapt, the way the window
// runs it (`MainSplitViewController+GenomicsDisplay.swift`), on each route the dialog reaches: a FASTQ and a FASTA bundle,
// one input and two, in each output mode the dialog offers (per input and grouped). Each result must give both lines.
// `FASTQDemultiplexFloorRoutesTests` is its stand-in, which needs no tool.
//
// It skips when cutadapt or the built CLI is missing, and fails then under LUNGFISH_REQUIRE_TOOLS=1.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQDemultiplexFloorRoutesConformanceTests: XCTestCase {
    private var root: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        guard let built = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            try ToolAvailability.skipOrFail("no lungfish-cli is built beside the test bundle")
        }
        cli = built
        root = try TestTempDirectory.make(prefix: "floor-routes")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// The two barcodes of the sheet and their reverse complements.
    private static let (s1, s1RC, s2, s2RC) = ("GTATCGTCGT", "ACGACGATAC", "ACGTTGCAAC", "GTTGCAACGT")

    /// 3,000 reads of 60 bases in `format`. 200 carry S1 at the 5' end and its reverse complement at the 3' end, so a
    /// 5', 3' or both-ends search finds them and S1 beats the floor. 2 carry S2 the same way, a count within chance that
    /// the floor names. The rest are random bases from a fixed seed.
    private func writeReads(_ format: SequenceFormat, seed: UInt64, to url: URL) throws {
        var state = seed
        var text = ""
        for index in 0..<3_000 {
            let (head, tail) = index < 200 ? (Self.s1, Self.s1RC) : (index < 202 ? (Self.s2, Self.s2RC) : ("", ""))
            var read = head
            while read.count < 60 - tail.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                read += ["A", "C", "G", "T"][Int((state >> 33) % 4)]
            }
            read += tail
            text += format == .fasta
                ? ">r\(index)\n\(read)\n"
                : "@r\(index)\n\(read)\n+\n\(String(repeating: "I", count: 60))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A reads bundle in `project` that holds one file of `format`, as the sidebar hands it to the dialog.
    private func makeInput(_ name: String, _ format: SequenceFormat, seed: UInt64, in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try writeReads(format, seed: seed, to: bundle.appendingPathComponent(format == .fasta ? "reads.fasta" : "reads.fastq"))
        return bundle
    }

    private struct Route {
        let label: String
        let inputs: [(name: String, format: SequenceFormat)]
        let mode: FASTQOperationOutputMode
    }

    /// Every route the dialog reaches for Demultiplex Barcodes. Its output picker offers per input and grouped
    /// (`FASTQOperationDialogState.outputStrategyOptions`), and it offers the tool on FASTA (`supportsFASTA`).
    private static let routes: [Route] = [
        Route(label: "FASTQ per input", inputs: [("pool", .fastq)], mode: .perInput),
        Route(label: "FASTQ grouped", inputs: [("pool", .fastq)], mode: .groupedResult),
        Route(label: "FASTA per input", inputs: [("pool", .fasta)], mode: .perInput),
        Route(label: "FASTA grouped", inputs: [("pool", .fasta)], mode: .groupedResult),
        Route(label: "two FASTQ per input", inputs: [("poolA", .fastq), ("poolB", .fastq)], mode: .perInput),
        Route(label: "two FASTQ grouped", inputs: [("poolA", .fastq), ("poolB", .fastq)], mode: .groupedResult),
        Route(label: "FASTQ and FASTA grouped", inputs: [("poolA", .fastq), ("poolB", .fasta)], mode: .groupedResult),
    ]

    func testEveryRouteOfARealCutadaptDemultiplexGivesTheFloorsWords() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        let cli = try XCTUnwrap(cli)
        var missed: [String] = []
        for (index, route) in Self.routes.enumerated() {
            let project = root.appendingPathComponent("route-\(index).lungfish", isDirectory: true)
            let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
            try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
            let inputs = try route.inputs.enumerated().map { offset, input in
                try makeInput(input.name, input.format, seed: UInt64(7 + offset), in: project)
            }
            let sheet = project.appendingPathComponent("sheet.csv")
            try "id,sequence\nS1,\(Self.s1)\nS2,\(Self.s2)\n".write(to: sheet, atomically: true, encoding: .utf8)
            let request = FASTQOperationLaunchRequest.derivative(
                request: .demultiplex(
                    kitID: "sheet", customCSVPath: sheet.path, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                    trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
                ),
                inputURLs: inputs, outputMode: route.mode
            )
            let log = Mutex<[String]>([])
            let service = FASTQOperationExecutionService(
                commandRunner: LungfishCLIProcessRunner(cliURLProvider: { cli }),
                directImporter: BundleFASTQOperationImporter(destinationDirectory: analyses)
            )
            let result: FASTQOperationExecutionResult
            do {
                result = try await service.execute(
                    request: request,
                    workingDirectory: analyses.appendingPathComponent("demultiplex-run", isDirectory: true),
                    logHandler: { _, message in log.withLock { $0.append(message) } }
                )
            } catch {
                missed.append("\(route.label): the run failed: \(error.localizedDescription)")
                continue
            }
            let floorLine = FASTQDemultiplexChanceNotice.floorNotice(for: result)
            let limitLine = FASTQDemultiplexChanceNotice.floorLimitLine(for: result)
            let logSaysChance = log.withLock { $0.contains { $0.contains("chance") || $0.contains("not in your pool") } }
            let argvInputs = inputs.filter { input in result.executedInvocations.contains { $0.arguments.contains(input.path) } }
            print(
                "FLOOR-ROUTE \(route.label): invocations=\(result.executedInvocations.count) "
                    + "inputsInArgv=\(argvInputs.count)/\(inputs.count) "
                    + "imported=\(result.importedURLs.map(\.lastPathComponent)) "
                    + "container=\(result.groupedContainerURL?.lastPathComponent ?? "nil") "
                    + "floorLine=\(floorLine != nil) limitLine=\(limitLine != nil) logSaysChance=\(logSaysChance)"
            )
            if floorLine == nil { missed.append("\(route.label): no floor line") }
            if limitLine == nil { missed.append("\(route.label): no limit line") }
        }
        XCTAssertEqual(missed, [], "a route of the dialog misses the floor's words")
    }
}
