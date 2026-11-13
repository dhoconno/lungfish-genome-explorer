// FASTQDemultiplexFloorRoutesTests.swift - The floor's words from every run folder of a demultiplex result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane FIX-FLOOR, backlog FLOOR-WINDOW-ROUTES-UNPROVEN, the stand-in of
// `FASTQDemultiplexFloorRoutesConformanceTests`. The real run measured that a demultiplex of two inputs runs one command
// an input, each writing its record into a folder of its own under the result's folder (`<run>/<input name>`), and that
// the result names only the result's folder. Per input it holds no record, and grouped it holds the app's record, which
// has no `chanceFloor` block. The window read only that folder, so neither floor line reached it. These results have the
// measured shape, with the commands the dialog's builder writes, and need no tool.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

final class FASTQDemultiplexFloorRoutesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floor-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A record in `folder` like the one `fastq demultiplex` writes, with its `chanceFloor` block or none. The app's
    /// own record of a grouped result is one with none.
    private func writeRecord(in folder: URL, chanceFloor: [String: ParameterValue]?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: output, atomically: true, encoding: .utf8)
        var parameters: [String: ParameterValue] = ["engine": .string("cutadapt")]
        if let chanceFloor { parameters["chanceFloor"] = .dictionary(chanceFloor) }
        let argv = ["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--output", folder.path]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq demultiplex", workflowVersion: "2026.11",
            toolName: "lungfish fastq demultiplex", toolVersion: "2026.11"
        )
        .argv(argv)
        .options(explicit: parameters, defaults: [:], resolved: parameters)
        .output(output, format: .fastq, role: .output)
        .step(ProvenanceStep(
            toolName: "lungfish fastq demultiplex", toolVersion: "2026.11", argv: argv,
            outputs: [try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)],
            exitStatus: 0, wallTimeSeconds: 1
        ))
        .runtime(ProvenanceRuntimeIdentity())
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 80), endedAt: Date(timeIntervalSince1970: 81))
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: folder)
    }

    private func floor(null: String, within: [String: Int]) -> [String: ParameterValue] {
        [
            "kitTail": .number(1e-6), "chanceTrials": .integer(2_000), "null": .string(null), "margin": .number(1),
            "compositionReads": .integer(0),
            "barcodesWithinChance": .dictionary(within.mapValues { ParameterValue.integer($0) }),
        ]
    }

    private func demultiplex(_ inputs: [URL], _ mode: FASTQOperationOutputMode) -> FASTQOperationLaunchRequest {
        .derivative(
            request: .demultiplex(
                kitID: "sheet", customCSVPath: root.appendingPathComponent("sheet.csv").path, location: "bothends",
                symmetryMode: nil, maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: inputs, outputMode: mode
        )
    }

    /// The result of a run of `inputs`, one command an input into `<run>/<input name>`, as the service returns it: the
    /// run folder imported, and the container when grouped.
    private func twoCommandResult(_ mode: FASTQOperationOutputMode, run: URL) throws -> FASTQOperationExecutionResult {
        let inputs = ["poolA", "poolB"].map { root.appendingPathComponent("\($0).lungfishfastq", isDirectory: true) }
        let builder = FASTQOperationCLIInvocationBuilder()
        let invocations = try inputs.map { input in
            try builder.buildInvocation(
                for: demultiplex([input], mode),
                outputTargetPath: run.appendingPathComponent(input.deletingPathExtension().lastPathComponent).path
            )
        }
        return FASTQOperationExecutionResult(
            resolvedRequest: demultiplex(inputs, mode), executedInvocations: invocations,
            importedURLs: [run], groupedContainerURL: mode == .groupedResult ? run : nil
        )
    }

    /// The line UX set for the floor's limit, byte for byte.
    private let notInPoolLine = "A barcode that is not in your pool can still pass as a sample. For each such barcode this "
        + "happens in about one run in 1,000, and more often in amplicon files. Check samples with few reads against "
        + "your sample sheet."

    private func withinLine(_ named: String, measuredOn: String) -> String {
        "Could be chance matches: \(named). Reads that carry no barcode match a barcode by chance at this error rate, and "
            + "each of these holds no more reads than chance gives. \(measuredOn) Their files were kept, so check them "
            + "against the samples you expect."
    }

    private let measured = "The chance is measured on the first bases of the Unassigned reads."
    private let random = "The chance is worked out as if A, C, G and T were equally likely, because the Unassigned reads "
        + "could not measure it."

    /// Two inputs per input: the records sit in `<run>/poolA` and `<run>/poolB`, and the run folder holds none. The
    /// line names the barcode with the input whose folder holds it, since both inputs have an S2 folder.
    func testTwoInputsPerInputGiveTheFloorsWordsFromEachInputsFolder() throws {
        let run = root.appendingPathComponent("Analyses/demultiplex-run", isDirectory: true)
        try writeRecord(in: run.appendingPathComponent("poolA"), chanceFloor: floor(null: "start-composition", within: [:]))
        try writeRecord(in: run.appendingPathComponent("poolB"), chanceFloor: floor(null: "start-composition", within: ["S2": 2]))
        let result = try twoCommandResult(.perInput, run: run)

        let expected = withinLine("S2 in poolB (2 reads)", measuredOn: measured)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorNotice(for: result), expected)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorLimitLine(for: result), notInPoolLine)
        let words = FASTQDemultiplexChanceNotice.rowWords(for: result)
        XCTAssertEqual(words.notice?.message, expected)
        XCTAssertEqual(words.floorLimitLine, notInPoolLine)
    }

    /// A FASTQ and a FASTA input grouped: one command a format into `<run>/poolA` and `<run>/poolB`, and the run folder
    /// holds the app's record, with no `chanceFloor` block. Each null keeps its own sentence.
    func testAGroupedResultOfTwoCommandsGivesTheFloorsWordsFromEachCommandsFolder() throws {
        let run = root.appendingPathComponent("Analyses/demultiplex-run", isDirectory: true)
        try writeRecord(in: run, chanceFloor: nil)
        try writeRecord(in: run.appendingPathComponent("poolA"), chanceFloor: floor(null: "start-composition", within: ["S2": 2]))
        try writeRecord(in: run.appendingPathComponent("poolB"), chanceFloor: floor(null: "random-bases", within: ["S2": 3]))
        let result = try twoCommandResult(.groupedResult, run: run)

        let expected = withinLine("S2 in poolA (2 reads)", measuredOn: measured) + " "
            + withinLine("S2 in poolB (3 reads)", measuredOn: random)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorNotice(for: result), expected)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.rowNotice(for: result)?.message, expected)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorLimitLine(for: result), notInPoolLine)
    }

    /// Both commands published a sample and named no barcode within chance: no warning, and the limit line stands.
    func testAGroupedResultOfTwoCommandsWithNoBarcodeWithinChanceStillCarriesTheLimitLine() throws {
        let run = root.appendingPathComponent("Analyses/demultiplex-run", isDirectory: true)
        try writeRecord(in: run, chanceFloor: nil)
        try writeRecord(in: run.appendingPathComponent("poolA"), chanceFloor: floor(null: "start-composition", within: [:]))
        try writeRecord(in: run.appendingPathComponent("poolB"), chanceFloor: floor(null: "start-composition", within: [:]))
        let result = try twoCommandResult(.groupedResult, run: run)

        XCTAssertNil(FASTQDemultiplexChanceNotice.floorNotice(for: result))
        XCTAssertNil(FASTQDemultiplexChanceNotice.rowNotice(for: result))
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorLimitLine(for: result), notInPoolLine)
    }

    /// One command that wrote into the result's folder: the folder is read once and the line names the barcode alone,
    /// word for word as before.
    func testOneCommandIntoTheResultsFolderKeepsTheLineWordForWord() throws {
        let run = root.appendingPathComponent("Analyses/demultiplex-run", isDirectory: true)
        try writeRecord(in: run, chanceFloor: floor(null: "start-composition", within: ["S2": 2]))
        let input = root.appendingPathComponent("pool.lungfishfastq", isDirectory: true)
        let request = demultiplex([input], .groupedResult)
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request, outputTargetPath: run.path)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: request, executedInvocations: [invocation], importedURLs: [run], groupedContainerURL: run
        )

        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorNotice(for: result), withinLine("S2 (2 reads)", measuredOn: measured))
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorLimitLine(for: result), notInPoolLine)
    }
}
