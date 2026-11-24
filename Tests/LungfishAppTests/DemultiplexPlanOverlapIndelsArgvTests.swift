// DemultiplexPlanOverlapIndelsArgvTests.swift - The Demux tab's Min Overlap and Allow indels reach the run's argv
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep continuation DEMUX-2, ruling BIO-DEMUX items 4 to 9 (K2 of DEMUXPLAN-LIMITS-S3-GROUP). Demultiplex… set the
// plan step's Min Overlap and Allow indels in the dialog only: the request had no field for them, the builder wrote no
// `--overlap`, and `lungfish-cli fastq demultiplex` had no `--no-indels`, so a plan run took the command's overlap of 3
// with indels allowed whatever the tab showed. Pins (a) to (d) of binding item 9.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class DemultiplexPlanOverlapIndelsArgvTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var dataset: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-plan-overlap-indels")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        dataset = project.appendingPathComponent("reads.fastq")
        try "@r1\nGATTACAGATTACA\n+\nIIIIIIIIIIIIII\n".write(to: dataset, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    private func planLaunch(
        minimumOverlap: Int, allowIndels: Bool, metadata: [String: String] = [:]
    ) throws -> FASTQDemultiplexPlanLaunch {
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "truseq-single-a"))
        let barcode = kit.barcodes[0]
        let row = FASTQSampleBarcodeAssignment(
            sampleID: barcode.id, sampleName: "S1", forwardBarcodeID: barcode.id, forwardSequence: barcode.i7Sequence,
            reverseBarcodeID: barcode.id, reverseSequence: barcode.i7Sequence, metadata: metadata
        )
        let step = DemultiplexStep(
            label: "Plan", barcodeKitID: kit.id, minimumOverlap: minimumOverlap, allowIndels: allowIndels,
            sampleAssignments: [row]
        )
        return try FASTQDemultiplexPlanLaunch.make(
            plan: DemultiplexPlan(steps: [step]), kits: BarcodeKitRegistry.builtinKits(), datasetURL: dataset,
            projectURL: project
        )
    }

    /// The argv the dialog's Run starts, with the dialog opened by the presenter's own `makeState`.
    private func argv(configure: (@MainActor (FASTQOperationDialogState) -> Void)?) throws -> [String] {
        let state = FASTQOperationsDialogPresenter.makeState(
            selectedInputURLs: [dataset],
            initialCategory: FASTQOperationToolID.demultiplexBarcodes.categoryID,
            initialToolID: .demultiplexBarcodes,
            projectURL: project,
            configure: configure
        )
        state.prepareForRun()
        let request = try XCTUnwrap(state.pendingLaunchRequest, "the dialog made no request")
        return try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: request, outputTargetPath: project.appendingPathComponent("Analyses/out").path
        ).arguments
    }

    /// (a) A plan with Min Overlap 7 and Allow indels off writes `--overlap 7` and `--no-indels` right after the error
    /// rate. At the base the argv held neither, so the run searched at overlap 3 with indels allowed.
    func testPlanMinOverlapAndIndelsOffFollowTheErrorRate() throws {
        let launch = try planLaunch(minimumOverlap: 7, allowIndels: false)
        let arguments = try argv(configure: launch.configure)
        let errorRate = try XCTUnwrap(arguments.firstIndex(of: "--error-rate"), "\(arguments)")
        XCTAssertEqual(
            Array(arguments.dropFirst(errorRate + 2).prefix(3)), ["--overlap", "7", "--no-indels"], "\(arguments)"
        )
    }

    /// (a) Allow indels on writes the overlap and no `--no-indels`.
    func testPlanWithIndelsAllowedWritesOnlyTheOverlap() throws {
        let arguments = try argv(configure: try planLaunch(minimumOverlap: 5, allowIndels: true).configure)
        let overlap = try XCTUnwrap(arguments.firstIndex(of: "--overlap"), "\(arguments)")
        XCTAssertEqual(arguments[overlap + 1], "5")
        XCTAssertFalse(arguments.contains("--no-indels"), "\(arguments)")
    }

    /// (b) Demultiplex Barcodes opened without a plan holds no overlap and indels allowed, and writes neither option.
    func testTheDefaultDialogWritesNoOverlapAndNoIndelsOption() throws {
        let arguments = try argv(configure: nil)
        XCTAssertEqual(arguments.first, "demultiplex")
        XCTAssertTrue(arguments.contains("--error-rate"), "\(arguments)")
        XCTAssertFalse(arguments.contains("--overlap"), "\(arguments)")
        XCTAssertFalse(arguments.contains("--no-indels"), "\(arguments)")
    }

    /// (c) A plan whose rows record the read-name route writes `--engine header-index` and no search option, whatever its
    /// Min Overlap and Allow indels.
    func testAReadNamePlanWritesNeitherOption() throws {
        let launch = try planLaunch(
            minimumOverlap: 7, allowIndels: false, metadata: FASTQSampleBarcodeAssignment.readNameIndexMetadata
        )
        let arguments = try argv(configure: launch.configure)
        let engine = try XCTUnwrap(arguments.firstIndex(of: "--engine"), "\(arguments)")
        XCTAssertEqual(arguments[engine + 1], "header-index")
        XCTAssertFalse(arguments.contains("--overlap"), "\(arguments)")
        XCTAssertFalse(arguments.contains("--no-indels"), "\(arguments)")
    }

    /// (d) `lungfish-cli fastq demultiplex` takes `--no-indels`, so the argv of (a) parses. At the base the command
    /// refused it as an unknown option. The run's cutadapt argv is pinned in
    /// `DemultiplexNoIndelsRunConformanceTests`.
    func testTheCommandTakesTheNoIndelsFlag() throws {
        let launch = try planLaunch(minimumOverlap: 7, allowIndels: false)
        let arguments = try argv(configure: launch.configure)
        XCTAssertNoThrow(try FastqDemultiplexSubcommand.parse(Array(arguments.dropFirst())), "\(arguments)")
        XCTAssertNoThrow(try FastqDemultiplexSubcommand.parse([
            dataset.path, "--kit", "truseq-single-a", "-o", project.appendingPathComponent("Analyses/cli").path,
            "--no-indels",
        ]))
    }
}

/// (d) with the real cutadapt: `--no-indels` gives the run's config `useNoIndels`, so the cutadapt step of the record
/// holds `--no-indels` (`DemultiplexingPipeline` `buildCutadaptArguments`), and the record keeps the flag.
final class DemultiplexNoIndelsRunConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-no-indels-run")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    private static let insert = "ACGTTGCAAGCTTCGAGATCCATGGTACCGAATTCTGCAGTCGACGGATCCAAGCTTGCAT"

    func testNoIndelsReachesTheCutadaptStepAndTheRecord() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        let reads = (1...3).map { ("p\($0)", "TGGGCGAA" + "CCCCC" + Self.insert) }
            + (1...3).map { ("q\($0)", "GGCGAAGT" + "CCCCC" + Self.insert) }
        try reads.map { "@\($0.0)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let kit = project.appendingPathComponent("kit.csv")
        try "id,sequence\nP,TGGGCGAA\nQ,GGCGAAGT\n".write(to: kit, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)

        var command = try FastqDemultiplexSubcommand.parse([
            input.path, "--kit", kit.path, "-o", output.path, "--engine", "cutadapt", "--location", "5prime",
            "--error-rate", "0", "--no-indels",
        ])
        try await command.run()

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertTrue(envelope.argv.contains("--no-indels"), "\(envelope.argv)")
        XCTAssertEqual(envelope.options.explicit["noIndels"], .boolean(true))
        XCTAssertEqual(envelope.options.defaults["noIndels"], .boolean(false))
        XCTAssertTrue(envelope.steps.contains { $0.argv.contains("--no-indels") }, "\(envelope.steps.map(\.argv))")
    }

    /// The same run without the flag records and runs as before: no `--no-indels` in the argv or in any step, no explicit
    /// `noIndels`, and the default `false` that every Cutadapt run writes (BIO 3, BIO 4 of the DEMUX review).
    func testARunWithoutTheFlagRecordsNoNoIndelsOption() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        let reads = (1...3).map { ("p\($0)", "TGGGCGAA" + "CCCCC" + Self.insert) }
            + (1...3).map { ("q\($0)", "GGCGAAGT" + "CCCCC" + Self.insert) }
        try reads.map { "@\($0.0)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let kit = project.appendingPathComponent("kit.csv")
        try "id,sequence\nP,TGGGCGAA\nQ,GGCGAAGT\n".write(to: kit, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)

        var command = try FastqDemultiplexSubcommand.parse([
            input.path, "--kit", kit.path, "-o", output.path, "--engine", "cutadapt", "--location", "5prime",
            "--error-rate", "0",
        ])
        try await command.run()

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertFalse(envelope.argv.contains("--no-indels"), "\(envelope.argv)")
        XCTAssertNil(envelope.options.explicit["noIndels"])
        XCTAssertEqual(envelope.options.defaults["noIndels"], .boolean(false))
        XCTAssertFalse(envelope.steps.contains { $0.argv.contains("--no-indels") }, "\(envelope.steps.map(\.argv))")
    }
}
